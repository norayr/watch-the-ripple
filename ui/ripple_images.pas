unit ripple_images;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, SyncObjs, ripple_types;

type
  TPreviewResult = record
    Generation, Index: Integer;
    Data: TRippleBytes;
    ErrorText: string;
  end;
  TPreviewResults = array of TPreviewResult;
  TPreviewWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FURLs: TRippleStrings;
    FGeneration, FPosition, FActiveGeneration: Integer;
    FResults: TPreviewResults;
    FStopped: Boolean;
    FCache: array of record URL: string; Data: TRippleBytes; end;
    FCacheBytes: Int64;
    procedure CheckCurrent(Sender: TObject);
    function Download(const URL: string): TRippleBytes;
  protected
    function Fetch(const URL: string): TRippleBytes; virtual;
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Request(const URLs: TRippleStrings; Generation: Integer);
    function TakeResults: TPreviewResults;
    procedure Stop;
    function Stopped: Boolean;
  end;

function SafePreview(const Data: TRippleBytes): Boolean;

implementation

uses ripple_http, ripple_bytes;

function GIFDimensions(const Data: TRippleBytes; out Width, Height: Integer): Boolean;
var Pos, Size: Integer;
begin
  Result := False;
  if Length(Data) < 13 then Exit;
  if (Read16LE(Data, 6) > 1024) or (Read16LE(Data, 8) > 1024) then Exit;
  Pos := 13;
  if Data[10] and $80 <> 0 then Inc(Pos, 3 * (1 shl ((Data[10] and 7) + 1)));
  while Pos < Length(Data) do
  begin
    case Data[Pos] of
      $2C:
        begin
          if Pos + 10 > Length(Data) then Exit;
          // FPC's GIF reader allocates from the first image descriptor, not the screen size.
          Width := Read16LE(Data, Pos + 5);
          Height := Read16LE(Data, Pos + 7);
          Exit(True);
        end;
      $21:
        begin
          Inc(Pos, 2);
          repeat
            if Pos >= Length(Data) then Exit;
            Size := Data[Pos];
            Inc(Pos, Size + 1);
          until Size = 0;
        end;
      else Exit;
    end;
  end;
end;

function SafePreview(const Data: TRippleBytes): Boolean;
var Width, Height, Pos, Marker, Size: Integer;
begin
  Result := False;
  Width := 0; Height := 0;
  if Length(Data) > 2 * 1024 * 1024 then Exit;
  if (Length(Data) >= 24) and (Data[0] = $89) and (Data[1] = $50) and
    (Data[2] = $4E) and (Data[3] = $47) and (Read32BE(Data, 4) = $0D0A1A0A) and
    (Read32BE(Data, 8) = 13) and (Read32BE(Data, 12) = $49484452) then
  begin
    if (Read32BE(Data, 16) > 1024) or (Read32BE(Data, 20) > 1024) then Exit;
    Width := Read32BE(Data, 16); Height := Read32BE(Data, 20);
  end
  else if (Length(Data) >= 10) and
    ((FixedText(Data, 0, 6) = 'GIF87a') or (FixedText(Data, 0, 6) = 'GIF89a')) then
  begin
    if not GIFDimensions(Data, Width, Height) then Exit;
  end
  else if (Length(Data) >= 4) and (Data[0] = $FF) and (Data[1] = $D8) then
  begin
    Pos := 2;
    while Pos + 4 <= Length(Data) do
    begin
      if Data[Pos] <> $FF then Exit;
      while (Pos < Length(Data)) and (Data[Pos] = $FF) do Inc(Pos);
      if Pos >= Length(Data) then Exit;
      Marker := Data[Pos]; Inc(Pos);
      if Marker in [$D9, $DA] then Exit;
      if Marker in [$D0..$D8, $01] then Continue;
      if Pos + 2 > Length(Data) then Exit;
      Size := Read16BE(Data, Pos);
      if (Size < 2) or (Pos + Size > Length(Data)) then Exit;
      if Marker in [$C0..$C3, $C5..$C7, $C9..$CB, $CD..$CF] then
      begin
        if Size < 7 then Exit;
        Height := Read16BE(Data, Pos + 3); Width := Read16BE(Data, Pos + 5);
        Break;
      end;
      Inc(Pos, Size);
    end;
  end;
  Result := (Width > 0) and (Width <= 1024) and (Height > 0) and (Height <= 1024);
end;

constructor TPreviewWorker.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  Start;
end;

destructor TPreviewWorker.Destroy;
begin
  Stop;
  WaitFor;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPreviewWorker.Request(const URLs: TRippleStrings; Generation: Integer);
begin
  FLock.Acquire;
  try
    FURLs := Copy(URLs);
    FGeneration := Generation;
    FPosition := 0;
    FResults := nil;
  finally FLock.Release; end;
  FWake.SetEvent;
end;

procedure TPreviewWorker.CheckCurrent(Sender: TObject);
begin
  if Terminated then raise EAbort.Create('Preview loading stopped');
  FLock.Acquire;
  try
    if FActiveGeneration <> FGeneration then raise EAbort.Create('Preview page changed');
  finally FLock.Release; end;
end;

function TPreviewWorker.Fetch(const URL: string): TRippleBytes;
var HTTP: TRippleHTTP; Stream: TMemoryStream;
begin
  Result := nil;
  HTTP := TRippleHTTP.Create(5000, 5000);
  try
    HTTP.OnCheck := @CheckCurrent;
    Stream := TMemoryStream.Create;
    try
      HTTP.Get(URL, Stream, 2 * 1024 * 1024);
      SetLength(Result, Stream.Size);
      if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
    finally Stream.Free; end;
  finally HTTP.Free; end;
end;

function TPreviewWorker.Download(const URL: string): TRippleBytes;
var I, Width: Integer;
begin
  if URL = '' then raise Exception.Create('No screenshot');
  for I := 0 to High(FCache) do
    if FCache[I].URL = URL then Exit(FCache[I].Data);
  Result := Fetch(URL);
  CheckCurrent(nil);
  if not SafePreview(Result) then raise Exception.Create('Unsupported or oversized screenshot');
  while (Length(FCache) > 0) and ((Length(FCache) >= 24) or
    (FCacheBytes + Length(Result) > 16 * 1024 * 1024)) do
  begin
    Dec(FCacheBytes, Length(FCache[0].Data));
    for I := 1 to High(FCache) do FCache[I - 1] := FCache[I];
    SetLength(FCache, Length(FCache) - 1);
  end;
  Width := Length(FCache);
  SetLength(FCache, Width + 1);
  FCache[Width].URL := URL;
  FCache[Width].Data := Result;
  Inc(FCacheBytes, Length(Result));
end;

procedure TPreviewWorker.Execute;
var URL: string; R: TPreviewResult; HasRequest: Boolean;
begin
  try
    while not Terminated do
    begin
      FLock.Acquire;
      try
        HasRequest := FPosition < Length(FURLs);
        if HasRequest then
        begin
          R := Default(TPreviewResult);
          R.Index := FPosition;
          R.Generation := FGeneration;
          FActiveGeneration := FGeneration;
          URL := FURLs[FPosition];
          Inc(FPosition);
        end;
      finally FLock.Release; end;
      if not HasRequest then
      begin
        FWake.WaitFor(250);
        Continue;
      end;
      try
        CheckCurrent(nil);
        R.Data := Download(URL);
      except on E: Exception do R.ErrorText := E.Message; end;
      FLock.Acquire;
      try
        if not Terminated and (R.Generation = FGeneration) then
        begin
          SetLength(FResults, Length(FResults) + 1);
          FResults[High(FResults)] := R;
        end;
      finally FLock.Release; end;
    end;
  finally
    FLock.Acquire;
    try FStopped := True;
    finally FLock.Release; end;
  end;
end;

function TPreviewWorker.TakeResults: TPreviewResults;
begin
  FLock.Acquire;
  try Result := FResults; FResults := nil;
  finally FLock.Release; end;
end;

procedure TPreviewWorker.Stop;
begin
  Terminate;
  if FWake <> nil then FWake.SetEvent;
end;

function TPreviewWorker.Stopped: Boolean;
begin
  FLock.Acquire;
  try Result := FStopped;
  finally FLock.Release; end;
end;

end.
