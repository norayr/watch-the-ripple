unit ripple_pbw;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, zipper, ripple_types;

type
  TPBW = class
  private
    FZip: TUnZipper;
    FStream: TMemoryStream;
    procedure CreateStream(Sender: TObject; var Stream: TStream; Item: TFullZipFileEntry);
    procedure DoneStream(Sender: TObject; var Stream: TStream; Item: TFullZipFileEntry);
    function Extract(const Name: string): TRippleBytes;
    function HasEntry(const Name: string): Boolean;
  public
    Binary, Resources, Worker, Metadata: TRippleBytes;
    Item: TRippleItem;
    constructor Create(const Filename, Platform: string);
    destructor Destroy; override;
  end;

implementation

uses fpjson, jsonparser, ripple_bytes, ripple_crc;

type
  TPBWStream = class(TMemoryStream)
    function Write(const Buffer; Count: LongInt): LongInt; override;
  end;

function TPBWStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  if (Count < 0) or (Position + Count > 16 * 1024 * 1024) then
    raise Exception.Create('PBW entry exceeds the size limit');
  Result := inherited Write(Buffer, Count);
end;

procedure TPBW.CreateStream(Sender: TObject; var Stream: TStream; Item: TFullZipFileEntry);
begin
  if Item.Size > 16 * 1024 * 1024 then raise Exception.Create('PBW entry too large');
  FreeAndNil(FStream);
  FStream := TPBWStream.Create;
  Stream := FStream;
end;

procedure TPBW.DoneStream(Sender: TObject; var Stream: TStream; Item: TFullZipFileEntry);
begin
  Stream := nil;
end;

function TPBW.HasEntry(const Name: string): Boolean;
var I: Integer;
begin
  for I := 0 to FZip.Entries.Count - 1 do
    if FZip.Entries[I].ArchiveFileName = Name then Exit(True);
  Result := False;
end;

function TPBW.Extract(const Name: string): TRippleBytes;
begin
  Result := nil;
  if not HasEntry(Name) then raise Exception.Create('Missing PBW entry: ' + Name);
  FreeAndNil(FStream);
  FZip.UnZipFile(FZip.FileName, Name);
  if FStream = nil then raise Exception.Create('Cannot read PBW entry: ' + Name);
  if FStream.Size > 16 * 1024 * 1024 then raise Exception.Create('PBW entry too large');
  SetLength(Result, FStream.Size);
  FStream.Position := 0;
  if Length(Result) > 0 then FStream.ReadBuffer(Result[0], Length(Result));
end;

constructor TPBW.Create(const Filename, Platform: string);
var Prefix, S, Name: string; Manifest, Part: TJSONData; B: TRippleBytes; I: Integer;

  function ReadPart(const Key: string; Required: Boolean): TRippleBytes;
  var O: TJSONObject; Size, CRC: Int64;
  begin
    Result := nil;
    Part := Manifest.FindPath(Key);
    if not (Part is TJSONObject) then
    begin
      if Required or ((Part <> nil) and (Part.JSONType <> jtNull)) then
        raise Exception.Create('Invalid PBW manifest entry: ' + Key);
      Exit;
    end;
    O := TJSONObject(Part);
    Name := O.Get('name', '');
    if (Name = '') or (Pos('/', Name) > 0) or (Pos('\', Name) > 0) or
      (Name = '..') then raise Exception.Create('Invalid PBW entry name');
    Result := Extract(Prefix + Name);
    Size := O.Get('size', Int64(-1));
    CRC := O.Get('crc', Int64(-1));
    if (Size <> Length(Result)) or (CRC < 0) or
      (CRC <> Int64(PebbleCRC(Result))) then
      raise Exception.Create('PBW size or CRC mismatch: ' + Name);
  end;

begin
  inherited Create;
  if Platform = '' then raise Exception.Create('Cannot select a PBW for unknown watch hardware');
  FZip := TUnZipper.Create;
  FZip.FileName := Filename;
  FZip.OnCreateStream := @CreateStream;
  FZip.OnDoneStream := @DoneStream;
  FZip.Examine;
  Prefix := Platform + '/';
  if not HasEntry(Prefix + 'manifest.json') then
  begin
    if (Platform <> 'aplite') or not HasEntry('manifest.json') then
      raise Exception.Create('PBW has no build for ' + Platform);
    Prefix := '';
  end;
  B := Extract(Prefix + 'manifest.json');
  if Length(B) > 65536 then raise Exception.Create('PBW manifest too large');
  SetLength(S, Length(B));
  if Length(B) > 0 then Move(B[0], S[1], Length(B));
  Manifest := GetJSON(S);
  try
    Binary := ReadPart('application', True);
    Resources := ReadPart('resources', False);
    Worker := ReadPart('worker', False);
  finally
    Manifest.Free;
  end;
  RequireBytes(Binary, 0, 124);
  if FixedText(Binary, 0, 8) <> 'PBLAPP' then raise Exception.Create('Invalid Pebble app binary');
  Item.Title := FixedText(Binary, 24, 32);
  Item.Author := FixedText(Binary, 56, 32);
  Item.UUID := UUIDText(Binary, 108);
  Item.Flags := Read32LE(Binary, 96);
  Item.Version := IntToStr(Binary[12]) + '.' + IntToStr(Binary[13]);
  Metadata := UUIDBytes(Item.UUID);
  Metadata := Join(Metadata, Copy(Binary, 96, 4));
  Metadata := Join(Metadata, Copy(Binary, 88, 4));
  Metadata := Join(Metadata, Bytes([Binary[12], Binary[13], Binary[10], Binary[11], 0, 0]));
  SetLength(Metadata, 126);
  for I := 30 to 125 do Metadata[I] := 0;
  if Item.Title <> '' then Move(Item.Title[1], Metadata[30], Length(Item.Title));
end;

destructor TPBW.Destroy;
begin
  FZip.Free;
  FStream.Free;
  inherited Destroy;
end;

end.
