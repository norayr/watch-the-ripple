unit ripple_catalog;

{$mode objfpc}{$H+}

interface

uses ripple_types;

function ParseCatalog(const Text: string; const Platform: string = ''): TRippleItems;
function FetchCatalog(Watchfaces: Boolean; const Platform: string): TRippleItems;
function BrowseCatalogURL(Watchfaces: Boolean; const Platform: string; Page: Integer): string;
function ParseCatalogPage(const Text, Platform: string; Page: Integer;
  out HasMore: Boolean): TRippleItems;
function BrowseCatalog(Watchfaces: Boolean; const Platform: string; Page: Integer;
  out HasMore: Boolean): TRippleItems;
function SearchCatalog(const Query: string; Watchfaces: Boolean; const Platform: string;
  Page: Integer; out HasMore: Boolean): TRippleItems;
function FetchAppDetails(const StoreID, Platform: string): TRippleItem;

implementation

uses Classes, SysUtils, fpjson, jsonparser, fphttpclient, ripple_http, ripple_gallery;

function ImageURL(Data: TJSONData): string;
const Sizes: array[0..6] of string = ('orig', '144x168', '180x180', '200x228', '144x144', '80x80', 'url');
var I: Integer; D: TJSONData;
begin
  Result := '';
  if Data = nil then Exit;
  if Data.JSONType = jtString then
  begin
    if Copy(LowerCase(Data.AsString), 1, 8) = 'https://' then Result := Data.AsString;
  end
  else if Data is TJSONObject then
  begin
    for I := 0 to High(Sizes) do
    begin
      D := Data.FindPath(Sizes[I]);
      if (D <> nil) and (D.JSONType = jtString) then
      begin
        Result := ImageURL(D);
        if Result <> '' then Exit;
      end;
    end;
    for I := 0 to Data.Count - 1 do
      if Data.Items[I].JSONType = jtString then
      begin
        Result := ImageURL(Data.Items[I]);
        if Result <> '' then Exit;
      end;
  end;
end;

procedure AddScreenshot(var Item: TRippleItem; const URL: string);
var I: Integer;
begin
  if URL = '' then Exit;
  for I := 0 to High(Item.Screenshots) do if Item.Screenshots[I] = URL then Exit;
  if Length(Item.Screenshots) >= 12 then Exit;
  SetLength(Item.Screenshots, Length(Item.Screenshots) + 1);
  Item.Screenshots[High(Item.Screenshots)] := URL;
end;

procedure AddImages(var Item: TRippleItem; Data: TJSONData);
var I: Integer;
begin
  if Data is TJSONArray then
    for I := 0 to Data.Count - 1 do AddScreenshot(Item, ImageURL(Data.Items[I]));
end;

function ParseItem(O: TJSONObject; const Platform: string; Details: Boolean): TRippleItem;
var Release, A, D: TJSONData; I: Integer; S: string;
begin
  Result := Default(TRippleItem);
  Result.Title := O.Get('title', 'Untitled');
  Result.Author := O.Get('author', '');
  Result.UUID := LowerCase(O.Get('uuid', ''));
  Result.StoreID := O.Get('id', O.Get('objectID', ''));
  if Result.StoreID <> '' then
    Result.StoreURL := 'https://apps.rebble.io/application/' + EncodeURLElement(Result.StoreID);
  Result.Description := O.Get('description', '');
  if Platform <> '' then
  begin
    D := O.FindPath('compatibility.' + Platform);
    if D is TJSONObject then Result.Incompatible := not TJSONObject(D).Get('supported', True);
  end;
  Release := O.FindPath('latest_release');
  if Release is TJSONObject then
  begin
    Result.DownloadURL := TJSONObject(Release).Get('pbw_file', '');
    Result.Version := TJSONObject(Release).Get('version', '');
  end;
  A := O.FindPath('capabilities');
  if A is TJSONArray then
    for I := 0 to A.Count - 1 do
    begin
      if A.Items[I].JSONType <> jtString then Continue;
      S := A.Items[I].AsString;
      if Result.Capabilities <> '' then Result.Capabilities := Result.Capabilities + ', ';
      Result.Capabilities := Result.Capabilities + S;
      if S = 'configurable' then Result.Configurable := True;
      if S = 'location' then Result.UsesLocation := True;
    end;
  A := O.FindPath('asset_collections');
  if (Platform <> '') and (A is TJSONArray) then
    for I := 0 to A.Count - 1 do
    begin
      D := A.Items[I];
      if (D is TJSONObject) and (TJSONObject(D).Get('hardware_platform', '') = Platform) then
      begin
        AddImages(Result, D.FindPath('screenshots'));
        Result.Description := TJSONObject(D).Get('description', Result.Description);
        Break;
      end;
    end;
  if (Length(Result.Screenshots) = 0) and Details then
    AddImages(Result, O.FindPath('screenshot_images'));
  A := O.FindPath('hardware_platforms');
  if (Platform <> '') and (A is TJSONArray) then
    for I := 0 to A.Count - 1 do
    begin
      D := A.Items[I];
      if (D is TJSONObject) and (TJSONObject(D).Get('name', '') = Platform) then
      begin
        if Length(Result.Screenshots) = 0 then
          AddScreenshot(Result, ImageURL(D.FindPath('images.screenshot')));
        Result.Description := TJSONObject(D).Get('description', Result.Description);
        Break;
      end;
    end;
  if Length(Result.Screenshots) = 0 then AddImages(Result, O.FindPath('screenshot_images'));
  if Length(Result.Screenshots) = 0 then AddScreenshot(Result, ImageURL(O.FindPath('list_image')));
end;

function ParseCatalog(const Text: string; const Platform: string): TRippleItems;
var Root, A, D: TJSONData; I: Integer;
begin
  Result := nil;
  Root := GetJSON(Text);
  try
    A := Root.FindPath('applications');
    if A = nil then A := Root.FindPath('hits');
    if A = nil then A := Root.FindPath('data');
    if not (A is TJSONArray) then raise Exception.Create('Invalid Rebble catalog');
    SetLength(Result, A.Count);
    for I := 0 to A.Count - 1 do
    begin
      D := A.Items[I];
      if not (D is TJSONObject) then raise Exception.Create('Invalid catalog entry');
      Result[I] := ParseItem(TJSONObject(D), Platform, Root.FindPath('data') = A);
    end;
  finally Root.Free; end;
end;

function FetchText(const URL: string): string;
var HTTP: TRippleHTTP; S: TStringStream;
begin
  HTTP := TRippleHTTP.Create;
  try
    S := TStringStream.Create('');
    try
      HTTP.Get(URL, S, 8 * 1024 * 1024);
      Result := S.DataString;
    finally S.Free; end;
  finally HTTP.Free; end;
end;

function FetchCatalog(Watchfaces: Boolean; const Platform: string): TRippleItems;
var URL: string;
begin
  URL := 'https://appstore-api.rebble.io/api/v1/home/';
  if Watchfaces then URL := URL + 'watchfaces' else URL := URL + 'apps';
  URL := URL + '?firmware_version=3';
  if Platform <> '' then URL := URL + '&hardware=' + EncodeURLElement(Platform) + '&filter_hardware=true';
  Result := ParseCatalog(FetchText(URL), Platform);
end;

function PageOffset(Page: Integer): Integer;
begin
  if (Page < 0) or (Page > High(Integer) div GalleryPageSize) then
    raise Exception.Create('Invalid catalog page');
  Result := Page * GalleryPageSize;
end;

function BrowseCatalogURL(Watchfaces: Boolean; const Platform: string; Page: Integer): string;
begin
  Result := 'https://appstore-api.rebble.io/api/v1/apps/collection/all/';
  if Watchfaces then Result := Result + 'watchfaces' else Result := Result + 'apps';
  Result := Result + '?limit=' + IntToStr(GalleryPageSize) + '&offset=' +
    IntToStr(PageOffset(Page)) + '&firmware_version=3';
  if Platform <> '' then Result := Result + '&hardware=' + EncodeURLElement(Platform) +
    '&filter_hardware=true';
end;

function ParseCatalogPage(const Text, Platform: string; Page: Integer;
  out HasMore: Boolean): TRippleItems;
var Root, Next: TJSONData; Offset: Integer;
begin
  HasMore := False;
  Offset := PageOffset(Page);
  Result := ParseCatalog(Text, Platform);
  Root := GetJSON(Text);
  try
    if not (Root is TJSONObject) then raise Exception.Create('Invalid paged catalog');
    if Root.FindPath('hits') is TJSONArray then
    begin
      if TJSONObject(Root).Get('page', -1) <> Page then
        raise Exception.Create('Unexpected search page');
      HasMore := Page + 1 < TJSONObject(Root).Get('nbPages', 0);
    end
    else if Root.FindPath('data') is TJSONArray then
    begin
      if TJSONObject(Root).Get('offset', -1) <> Offset then
        raise Exception.Create('Unexpected catalog offset');
      Next := Root.FindPath('links.nextPage');
      HasMore := (Next <> nil) and (Next.JSONType = jtString) and (Next.AsString <> '');
    end
    else raise Exception.Create('Invalid paged catalog');
  finally Root.Free; end;
end;

function BrowseCatalog(Watchfaces: Boolean; const Platform: string; Page: Integer;
  out HasMore: Boolean): TRippleItems;
begin
  Result := ParseCatalogPage(FetchText(BrowseCatalogURL(Watchfaces, Platform, Page)),
    Platform, Page, HasMore);
end;

function SearchCatalog(const Query: string; Watchfaces: Boolean; const Platform: string;
  Page: Integer; out HasMore: Boolean): TRippleItems;
var URL, Kind: string;
begin
  if Page < 0 then raise Exception.Create('Invalid search page');
  if Watchfaces then Kind := 'watchface' else Kind := 'watchapp';
  URL := 'https://7683ow76eq-dsn.algolia.net/1/indexes/rebble-appstore-production?' +
    'x-algolia-application-id=7683OW76EQ&x-algolia-api-key=252f4938082b8693a8a9fc0157d1d24f' +
    '&query=' + EncodeURLElement(Query) + '&tagFilters=' + EncodeURLElement('(' + Kind + ')') +
    '&hitsPerPage=' + IntToStr(GalleryPageSize) + '&page=' + IntToStr(Page);
  Result := ParseCatalogPage(FetchText(URL), Platform, Page, HasMore);
end;

function FetchAppDetails(const StoreID, Platform: string): TRippleItem;
var Items: TRippleItems;
begin
  if StoreID = '' then raise Exception.Create('No Rebble store ID is available');
  Items := ParseCatalog(FetchText('https://appstore-api.rebble.io/api/v1/apps/id/' +
    EncodeURLElement(StoreID) + '?hardware=' + EncodeURLElement(Platform)), Platform);
  if Length(Items) <> 1 then raise Exception.Create('Invalid Rebble app details');
  Result := Items[0];
  if Result.StoreID <> StoreID then raise Exception.Create('App details store ID does not match');
end;

end.
