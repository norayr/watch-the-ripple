unit ripple_catalog;

{$mode objfpc}{$H+}

interface

uses ripple_types;

function ParseCatalog(const Text: string): TRippleItems;
function FetchCatalog(Watchfaces: Boolean; const Platform: string): TRippleItems;

implementation

uses Classes, SysUtils, fpjson, jsonparser, ripple_http;

function ParseCatalog(const Text: string): TRippleItems;
var Root, D, Release, A: TJSONData; I: Integer; O: TJSONObject;
begin
  Result := nil;
  Root := GetJSON(Text);
  try
    A := Root.FindPath('applications');
    if not (A is TJSONArray) then raise Exception.Create('Invalid Rebble catalog');
    SetLength(Result, A.Count);
    for I := 0 to A.Count - 1 do
    begin
      D := A.Items[I];
      if not (D is TJSONObject) then raise Exception.Create('Invalid catalog entry');
      O := TJSONObject(D);
      Result[I].Title := O.Get('title', 'Untitled');
      Result[I].Author := O.Get('author', '');
      Result[I].UUID := LowerCase(O.Get('uuid', ''));
      Result[I].Description := O.Get('description', '');
      Release := O.FindPath('latest_release');
      if Release is TJSONObject then
      begin
        Result[I].DownloadURL := TJSONObject(Release).Get('pbw_file', '');
        Result[I].Version := TJSONObject(Release).Get('version', '');
      end;
    end;
  finally
    Root.Free;
  end;
end;

function FetchCatalog(Watchfaces: Boolean; const Platform: string): TRippleItems;
var URL: string; HTTP: TRippleHTTP; S: TStringStream;
begin
  URL := 'https://appstore-api.rebble.io/api/v1/home/';
  if Watchfaces then URL := URL + 'watchfaces' else URL := URL + 'apps';
  URL := URL + '?firmware_version=3';
  if Platform <> '' then
    URL := URL + '&hardware=' + Platform + '&filter_hardware=true';
  HTTP := TRippleHTTP.Create;
  S := TStringStream.Create('');
  try
    HTTP.Get(URL, S, 8 * 1024 * 1024);
    Result := ParseCatalog(S.DataString);
  finally
    S.Free;
    HTTP.Free;
  end;
end;

end.
