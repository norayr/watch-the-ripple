program test_ripple_gallery;

{$mode objfpc}{$H+}

uses cthreads, Classes, SysUtils, SyncObjs, ripple_types, ripple_bytes,
  ripple_catalog, ripple_gallery, ripple_images, ripple_http;

type
  TCancelCheck = class
    Calls: Integer;
    procedure Cancel(Sender: TObject);
  end;
  TFakePreview = class(TPreviewWorker)
  public
    Started, Released: TEvent;
    Downloads: Integer;
    constructor Create;
    destructor Destroy; override;
    function Fetch(const URL: string): TRippleBytes; override;
  end;

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then raise Exception.Create(Message);
end;

procedure TCancelCheck.Cancel(Sender: TObject);
begin
  Inc(Calls);
  raise EAbort.Create('Cancelled');
end;

function PNGHeader(Width, Height: Cardinal): TRippleBytes;
begin
  Result := Join(Bytes([$89, $50, $4E, $47, 13, 10, 26, 10]),
    Join(U32BE(13), Join(Bytes([$49, $48, $44, $52]), Join(U32BE(Width), U32BE(Height)))));
end;

constructor TFakePreview.Create;
begin
  inherited Create;
  Started := TEvent.Create(nil, False, False, '');
  Released := TEvent.Create(nil, False, False, '');
end;

destructor TFakePreview.Destroy;
begin
  Released.SetEvent;
  Stop;
  WaitFor;
  Started.Free;
  Released.Free;
  inherited Destroy;
end;

function TFakePreview.Fetch(const URL: string): TRippleBytes;
begin
  Inc(Downloads);
  if URL = 'blocked' then
  begin
    Started.SetEvent;
    Check(Released.WaitFor(3000) = wrSignaled, 'blocked preview released');
  end;
  if URL = 'error' then raise Exception.Create('Download failed');
  Result := PNGHeader(144, 168);
  if Copy(URL, 1, 3) = 'big' then SetLength(Result, 2 * 1024 * 1024);
  if URL = 'invalid' then Result := Bytes([0, 1, 2]);
end;

function WaitResults(Worker: TPreviewWorker; Count: Integer): TPreviewResults;
var Deadline: QWord; Batch: TPreviewResults; R: TPreviewResult;
begin
  Result := nil;
  Deadline := GetTickCount64 + 3000;
  repeat
    Batch := Worker.TakeResults;
    for R in Batch do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := R;
    end;
    if Length(Result) >= Count then Exit;
    Sleep(1);
  until GetTickCount64 >= Deadline;
  raise Exception.Create('Preview results timed out');
end;

procedure TestLayout;
var Width, Count, Page, Start: Integer;
begin
  Check(GalleryColumns(360) = 1, 'narrow gallery');
  Check(GalleryColumns(480) = 2, 'medium gallery');
  Check(GalleryColumns(800) = 3, 'wide gallery');
  for Width := 0 to 2000 do
    Check(GalleryColumns(Width) in [1..3], 'column bounds');
  Check(GalleryPageCount(0) = 1, 'empty catalog page');
  Check(GalleryPageCount(9) = 1, 'full page');
  Check(GalleryPageCount(10) = 2, 'partial second page');
  Check(GalleryPageStart(-1, 20) = 0, 'negative page clamped');
  Check(GalleryPageStart(99, 20) = 18, 'last page clamped');
  for Count := 0 to 40 do
    for Page := 0 to GalleryPageCount(Count) - 1 do
    begin
      Start := GalleryPageStart(Page, Count);
      Check((Start >= 0) and ((Count = 0) or (Start < Count)), 'page starts inside catalog');
    end;
end;

procedure TestCatalog;
const Item = '{"objectID":"store-id","title":"Weather","uuid":"AABBCCDD-0011-2233-4455-66778899AABB",' +
  '"capabilities":["location","configurable"],"compatibility":{"aplite":{"supported":false}},' +
  '"asset_collections":[{"hardware_platform":"chalk","screenshots":["https://example.org/round"]},' +
  '{"hardware_platform":"aplite","description":"Monochrome","screenshots":[' +
  '"https://example.org/mono","https://example.org/mono","http://example.org/unsafe"]}],' +
  '"screenshot_images":[{"144x168":"https://example.org/default"}]}';
var Items: TRippleItems; Failed: Boolean;
begin
  Items := ParseCatalog('{"hits":[' + Item + ']}', 'aplite');
  Check((Length(Items) = 1) and (Items[0].StoreID = 'store-id'), 'search store ID');
  Check(Items[0].UUID = 'aabbccdd-0011-2233-4455-66778899aabb', 'UUID normalized');
  Check(Items[0].Incompatible and Items[0].Configurable and Items[0].UsesLocation,
    'compatibility and phone support flags');
  Check((Length(Items[0].Screenshots) = 1) and
    (Items[0].Screenshots[0] = 'https://example.org/mono'), 'hardware screenshots deduplicated');
  Check(Items[0].Description = 'Monochrome', 'hardware description');
  Check(Items[0].DownloadURL = '', 'search without PBW needs details');
  Items := ParseCatalog('{"applications":[' + Item + ']}');
  Check(not Items[0].Incompatible, 'unknown watch not assumed incompatible');
  Check(Items[0].Screenshots[0] = 'https://example.org/default', 'generic screenshot fallback');
  Items := ParseCatalog('{"data":[{"id":"details","latest_release":{"pbw_file":' +
    '"https://example.org/app.pbw","version":"1.2"},"hardware_platforms":[' +
    '{"name":"chalk","images":{"screenshot":"https://example.org/round"}},' +
    '{"name":"aplite","images":{"screenshot":"https://example.org/rect"}}]}]}', 'aplite');
  Check((Items[0].Version = '1.2') and (Items[0].DownloadURL <> ''), 'detail release');
  Check(Items[0].Screenshots[0] = 'https://example.org/rect', 'hardware-platform screenshot');
  Items := ParseCatalog('{"data":[{"hardware_platforms":[{"name":"aplite",' +
    '"description":"Watch description","images":{"screenshot":"https://example.org/first"}}],' +
    '"screenshot_images":["https://example.org/first","https://example.org/second"]}]}', 'aplite');
  Check((Length(Items[0].Screenshots) = 2) and
    (Items[0].Description = 'Watch description'), 'details retain hardware-filtered screenshot sequence');
  Items := ParseCatalog('{"applications":[{"screenshot_images":[' +
    '{"orig":"https://example.org/orig","144x168":"https://example.org/small"},' +
    '"https://example.org/second",null,{}]}]}');
  Check((Length(Items[0].Screenshots) = 2) and
    (Items[0].Screenshots[0] = 'https://example.org/orig'), 'image object and string variants');
  Items := ParseCatalog('{"applications":[{"list_image":{"80x80":"https://example.org/icon"}}]}');
  Check(Items[0].Screenshots[0] = 'https://example.org/icon', 'list image fallback');
  Failed := False;
  try ParseCatalog('{"applications":[null]}'); except Failed := True; end;
  Check(Failed, 'malformed catalog entry rejected');
  Failed := False;
  try ParseCatalog('{"error":"missing"}'); except Failed := True; end;
  Check(Failed, 'missing catalog array rejected');
end;

procedure TestBounds;
var Data: TRippleBytes;
begin
  Check(SafePreview(PNGHeader(144, 168)), 'PNG dimensions');
  Check(SafePreview(PNGHeader(1024, 1024)), 'maximum preview dimensions');
  Check(not SafePreview(PNGHeader(0, 168)), 'zero width');
  Check(not SafePreview(PNGHeader(1025, 168)), 'oversized PNG');
  Check(not SafePreview(PNGHeader($FFFFFFFF, 168)), 'untrusted unsigned PNG dimension');
  Check(not SafePreview(nil), 'empty preview');
  Data := PNGHeader(144, 168);
  Data[4] := 0;
  Check(not SafePreview(Data), 'PNG signature checked');
  Data := PNGHeader(144, 168);
  SetLength(Data, 2 * 1024 * 1024 + 1);
  Check(not SafePreview(Data), 'preview byte limit');
  Data := Join(Bytes([71, 73, 70, 56, 57, 97]), Join(U16LE(144), U16LE(168)));
  Data := Join(Data, Bytes([0, 0, 0, $21, $F9, 4, 0, 0, 0, 0, 0, $2C, 0, 0, 0, 0,
    144, 0, 168, 0, 0]));
  Check(SafePreview(Data), 'GIF dimensions');
  Data[29] := 8;
  Check(not SafePreview(Data), 'oversized GIF');
  Check(not SafePreview(Copy(Data, 0, 13)), 'GIF without image descriptor');
  Data := Bytes([$FF, $D8, $FF, $E0, 0, 4, 1, 2, $FF, $C0, 0, 7, 8, 0, 168, 0, 144]);
  Check(SafePreview(Data), 'JPEG dimensions after metadata');
  Data[15] := 8;
  Check(not SafePreview(Data), 'oversized JPEG');
  Check(not SafePreview(Bytes([$FF, $D8, $FF, $C0, 0])), 'truncated JPEG');
  Check(not SafePreview(Bytes([$FF, $D8, $FF, $E0, 0, 0])), 'invalid JPEG segment length');
end;

procedure TestWorker;
var Worker: TFakePreview; URLs: TRippleStrings; Results: TPreviewResults;
  Generation, I, Before: Integer; Deadline: QWord;
begin
  Worker := TFakePreview.Create;
  try
    SetLength(URLs, 2);
    URLs[0] := 'one'; URLs[1] := 'one';
    Worker.Request(URLs, 1);
    Results := WaitResults(Worker, 2);
    Check((Results[0].Index = 0) and (Results[1].Index = 1), 'result indexes');
    Check((Worker.Downloads = 1) and SafePreview(Results[0].Data), 'preview cache hit');
    URLs[0] := 'blocked'; URLs[1] := 'obsolete';
    Worker.Request(URLs, 2);
    Check(Worker.Started.WaitFor(3000) = wrSignaled, 'old page download started');
    SetLength(URLs, 1); URLs[0] := 'new';
    Worker.Request(URLs, 3);
    URLs[0] := 'changed-after-request';
    Worker.Released.SetEvent;
    Results := WaitResults(Worker, 1);
    Check((Length(Results) = 1) and (Results[0].Generation = 3), 'stale page result discarded');
    Check(Worker.Downloads = 3, 'obsolete queued preview skipped');
    URLs[0] := 'new'; Worker.Request(URLs, 4);
    Results := WaitResults(Worker, 1);
    Check(Worker.Downloads = 3, 'request URL array copied');
    URLs[0] := 'error'; Worker.Request(URLs, 5);
    Results := WaitResults(Worker, 1);
    Check((Results[0].ErrorText = 'Download failed') and (Length(Results[0].Data) = 0), 'preview error returned');
    URLs[0] := 'invalid'; Worker.Request(URLs, 6);
    Results := WaitResults(Worker, 1);
    Check(Results[0].ErrorText <> '', 'invalid preview not cached');
    Generation := 6;
    for I := 1 to 25 do
    begin
      Inc(Generation); URLs[0] := 'entry-' + IntToStr(I);
      Worker.Request(URLs, Generation); Results := WaitResults(Worker, 1);
    end;
    Before := Worker.Downloads;
    Inc(Generation); URLs[0] := 'entry-1';
    Worker.Request(URLs, Generation); Results := WaitResults(Worker, 1);
    Check(Worker.Downloads = Before + 1, 'cache entry limit evicts oldest');
    for I := 1 to 9 do
    begin
      Inc(Generation); URLs[0] := 'big-' + IntToStr(I);
      Worker.Request(URLs, Generation); Results := WaitResults(Worker, 1);
    end;
    Before := Worker.Downloads;
    Inc(Generation); URLs[0] := 'big-1';
    Worker.Request(URLs, Generation); Results := WaitResults(Worker, 1);
    Check(Worker.Downloads = Before + 1, 'cache byte limit evicts oldest');
    Inc(Generation); URLs[0] := 'blocked';
    Worker.Request(URLs, Generation);
    Check(Worker.Started.WaitFor(3000) = wrSignaled, 'active download before shutdown');
    Worker.Stop;
    Worker.Released.SetEvent;
    Deadline := GetTickCount64 + 3000;
    while not Worker.Stopped and (GetTickCount64 < Deadline) do Sleep(1);
    Check(Worker.Stopped, 'worker stops after active download');
    Check(Length(Worker.TakeResults) = 0, 'shutdown discards result');
  finally Worker.Free; end;
  Worker := TFakePreview.Create;
  Worker.Free;
end;

procedure TestHTTPCancellation;
var HTTP: TRippleHTTP; Stream: TMemoryStream; Cancel: TCancelCheck; Aborted: Boolean;
begin
  HTTP := TRippleHTTP.Create(5000, 5000);
  Stream := TMemoryStream.Create;
  Cancel := TCancelCheck.Create;
  try
    HTTP.OnCheck := @Cancel.Cancel;
    Aborted := False;
    try HTTP.Get('https://example.org/preview.png', Stream, 1024);
    except on E: EAbort do Aborted := True; end;
    Check(Aborted and (Cancel.Calls = 1) and (Stream.Size = 0),
      'cancelled HTTP request stops before connecting');
  finally Cancel.Free; Stream.Free; HTTP.Free; end;
end;

begin
  TestLayout;
  TestCatalog;
  TestBounds;
  TestWorker;
  TestHTTPCancellation;
  WriteLn('Ripple gallery tests passed');
end.
