unit ripple_watch_apps;

{$mode objfpc}{$H+}

interface

uses ripple_types, ripple_watch_link, ripple_pbw;

function ParseAppBanks(const Data, UUIDs: TRippleBytes; out Banks: Cardinal): TRippleItems;
function ListWatchApps(Link: TWatchLink; out Banks: Cardinal): TRippleItems;
procedure RemoveWatchApp(Link: TWatchLink; const Item: TRippleItem; Modern: Boolean);
procedure InstallWatchApp(Link: TWatchLink; PBW: TPBW; Modern: Boolean;
  Progress: TRippleProgress; Registered: TRippleRegistered = nil);
function PutBytesInit(Size: Cardinal; Kind: Byte; AppID: Cardinal; Modern: Boolean): TRippleBytes;

implementation

uses SysUtils, ripple_bytes, ripple_crc;

function ManagerResponse(Link: TWatchLink; Command: Byte): TRippleBytes;
var Deadline, Now: QWord;
begin
  Deadline := GetTickCount64 + 15000;
  repeat
    Now := GetTickCount64;
    if Now >= Deadline then raise Exception.Create('App manager response timed out');
    Result := Link.Wait(EP_APP_MANAGER, Deadline - Now);
    RequireBytes(Result, 0, 1);
  until Result[0] = Command;
end;

function ParseAppBanks(const Data, UUIDs: TRippleBytes; out Banks: Cardinal): TRippleItems;
var Used, UUIDCount: Cardinal; I, Offset: Integer;
begin
  Result := nil;
  RequireBytes(Data, 0, 9);
  RequireBytes(UUIDs, 0, 5);
  if (Data[0] <> 1) or (UUIDs[0] <> 5) then
    raise Exception.Create('Invalid watch app inventory');
  Banks := Read32BE(Data, 1);
  Used := Read32BE(Data, 5);
  UUIDCount := Read32BE(UUIDs, 1);
  if (Banks > 256) or (Used > Banks) or (Used <> UUIDCount) or
    (QWord(Used) * 78 + 9 <> QWord(Length(Data))) or
    (QWord(Used) * 16 + 5 <> QWord(Length(UUIDs))) then
    raise Exception.Create('Watch inventory changed or is malformed; refresh again');
  SetLength(Result, Used);
  for I := 0 to Integer(Used) - 1 do
  begin
    Offset := 9 + I * 78;
    Result[I].AppID := Read32BE(Data, Offset);
    Result[I].Bank := Read32BE(Data, Offset + 4);
    if Result[I].Bank >= Banks then raise Exception.Create('Invalid app bank');
    Result[I].Title := FixedText(Data, Offset + 8, 32);
    Result[I].Author := FixedText(Data, Offset + 40, 32);
    Result[I].Flags := Read32BE(Data, Offset + 72);
    Result[I].Version := IntToStr(Read16BE(Data, Offset + 76));
    Result[I].UUID := UUIDText(UUIDs, 5 + I * 16);
  end;
end;

function ListWatchApps(Link: TWatchLink; out Banks: Cardinal): TRippleItems;
var UUIDs, Data: TRippleBytes;
begin
  Link.Send(EP_APP_MANAGER, Bytes([5]));
  UUIDs := ManagerResponse(Link, 5);
  Link.Send(EP_APP_MANAGER, Bytes([1]));
  Data := ManagerResponse(Link, 1);
  Result := ParseAppBanks(Data, UUIDs, Banks);
end;

procedure BlobCommand(Link: TWatchLink; Command: Byte; const UUID: string;
  const Value: TRippleBytes);
var Token: Word; Data, Response: TRippleBytes; Deadline, Now: QWord;
begin
  Token := Word(GetTickCount64 and $FFFF);
  Data := Join(Join(Bytes([Command]), U16LE(Token)), Bytes([2, 16]));
  Data := Join(Data, UUIDBytes(UUID));
  if Command = 1 then Data := Join(Data, Join(U16LE(Length(Value)), Value));
  Link.Send(EP_BLOB_DB, Data);
  Deadline := GetTickCount64 + 15000;
  repeat
    Now := GetTickCount64;
    if Now >= Deadline then raise Exception.Create('BlobDB response timed out');
    Response := Link.Wait(EP_BLOB_DB, Deadline - Now);
    RequireBytes(Response, 0, 3);
  until Read16LE(Response, 0) = Token;
  if (Response[2] <> 1) and not ((Command = 4) and (Response[2] = 6)) then
    raise Exception.CreateFmt('Watch rejected app metadata (BlobDB status %d)', [Response[2]]);
end;

procedure RemoveWatchApp(Link: TWatchLink; const Item: TRippleItem; Modern: Boolean);
var Response: TRippleBytes;
begin
  if Modern then BlobCommand(Link, 4, Item.UUID, nil)
  else
  begin
    Link.Send(EP_APP_MANAGER, Join(Bytes([2]), UUIDBytes(Item.UUID)));
    Response := ManagerResponse(Link, 2);
    RequireBytes(Response, 0, 5);
    if (Response[0] <> 2) or (Read32BE(Response, 1) <> 1) then
      raise Exception.Create('Watch refused app removal');
  end;
end;

function PutBytesInit(Size: Cardinal; Kind: Byte; AppID: Cardinal; Modern: Boolean): TRippleBytes;
begin
  Result := Join(Bytes([1]), U32BE(Size));
  if Modern then Result := Join(Result, Join(Bytes([Kind or $80]), U32LE(AppID)))
  else
  begin
    if AppID > 255 then raise Exception.Create('Invalid app bank');
    Result := Join(Result, Bytes([Kind, AppID]));
  end;
end;

procedure Upload(Link: TWatchLink; const Data: TRippleBytes; Kind: Byte;
  AppID: Cardinal; Modern: Boolean; Base, Total: Int64; Progress: TRippleProgress);
var Response, Packet: TRippleBytes; Cookie: Cardinal; Pos, Count: Integer;

  procedure Ack;
  begin
    Response := Link.Wait(EP_PUT_BYTES);
    RequireBytes(Response, 0, 1);
    if Response[0] <> 1 then raise Exception.Create('Watch rejected file transfer');
    if (Length(Response) >= 5) and (Read32BE(Response, 1) <> Cookie) then
      raise Exception.Create('Unexpected file transfer token');
  end;

begin
  Link.Send(EP_PUT_BYTES, PutBytesInit(Length(Data), Kind, AppID, Modern));
  Response := Link.Wait(EP_PUT_BYTES);
  RequireBytes(Response, 0, 5);
  if Response[0] <> 1 then raise Exception.Create('Watch refused file transfer');
  Cookie := Read32BE(Response, 1);
  try
    Pos := 0;
    while Pos < Length(Data) do
    begin
      Count := Length(Data) - Pos;
      if Count > 2000 then Count := 2000;
      Packet := Join(Bytes([2]), Join(U32BE(Cookie), U32BE(Count)));
      Link.Send(EP_PUT_BYTES, Join(Packet, Copy(Data, Pos, Count)));
      Ack;
      Inc(Pos, Count);
      if Assigned(Progress) then Progress('Sending app to watch', (Base + Pos) * 100 div Total);
    end;
    Link.Send(EP_PUT_BYTES, Join(Bytes([3]), Join(U32BE(Cookie), U32BE(PebbleCRC(Data)))));
    Ack;
    Link.Send(EP_PUT_BYTES, Join(Bytes([5]), U32BE(Cookie)));
    Ack;
  except
    try Link.Send(EP_PUT_BYTES, Join(Bytes([4]), U32BE(Cookie))); except end;
    raise;
  end;
end;

procedure InstallWatchApp(Link: TWatchLink; PBW: TPBW; Modern: Boolean;
  Progress: TRippleProgress; Registered: TRippleRegistered);
var Apps: TRippleItems; Banks, Bank, AppID: Cardinal; I: Integer;
  Busy: array[0..255] of Boolean; Response: TRippleBytes; Total: Int64;
begin
  if Modern then
  begin
    BlobCommand(Link, 1, PBW.Item.UUID, PBW.Metadata);
    if Assigned(Registered) then Registered(PBW.Item);
    Link.Send(EP_RUN_STATE, Join(Bytes([1]), UUIDBytes(PBW.Item.UUID)));
    Response := Link.Wait(EP_APP_FETCH, 30000);
    RequireBytes(Response, 0, 21);
    if (Response[0] <> 1) or (UUIDText(Response, 1) <> PBW.Item.UUID) then
    begin
      Link.Send(EP_APP_FETCH, Bytes([1, 3]));
      raise Exception.Create('Watch requested a different app; try installing again');
    end;
    AppID := Read32LE(Response, 17);
    Link.Send(EP_APP_FETCH, Bytes([1, 1]));
  end
  else
  begin
    Apps := ListWatchApps(Link, Banks);
    for I := 0 to High(Apps) do
      if Apps[I].UUID = PBW.Item.UUID then
        raise Exception.Create('This app is installed already; remove it before reinstalling');
    FillChar(Busy, SizeOf(Busy), 0);
    for I := 0 to High(Apps) do Busy[Apps[I].Bank] := True;
    Bank := 0;
    while (Bank < Banks) and Busy[Bank] do Inc(Bank);
    if Bank >= Banks then raise Exception.Create('All watch app banks are full');
    AppID := Bank;
  end;
  Total := Int64(Length(PBW.Binary)) + Length(PBW.Resources) + Length(PBW.Worker);
  Upload(Link, PBW.Binary, 5, AppID, Modern, 0, Total, Progress);
  if Length(PBW.Resources) > 0 then
    Upload(Link, PBW.Resources, 4, AppID, Modern, Length(PBW.Binary), Total, Progress);
  if Length(PBW.Worker) > 0 then
    Upload(Link, PBW.Worker, 7, AppID, Modern,
      Int64(Length(PBW.Binary)) + Length(PBW.Resources), Total, Progress);
  if not Modern then
  begin
    Link.Send(EP_APP_MANAGER, Join(Bytes([3]), U32BE(AppID)));
    Apps := ListWatchApps(Link, Banks);
    I := 0;
    while (I < Length(Apps)) and (Apps[I].UUID <> PBW.Item.UUID) do Inc(I);
    if I = Length(Apps) then raise Exception.Create('App transferred but watch registration failed');
  end;
  if Assigned(Progress) then Progress('App transfer completed', 100);
end;

end.
