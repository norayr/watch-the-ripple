program test_ripple_ui;

{$mode objfpc}{$H+}

uses Classes, SysUtils, Process, BaseUnix, ripple_types, ripple_bytes, ripple_crc, ripple_catalog,
  ripple_http, ripple_watch_link, ripple_watch_apps, ripple_pbw, ripple_settings,
  ripple_daemon, ripple_watch_access, ripple_temp;

const AppUUID = '00112233-4455-6677-8899-aabbccddeeff';
  ObjectTypes: array[1..3] of Byte = (5, 4, 7);

type
  TLaunchReply = (lrRunning, lrDelayed, lrNoResponse, lrOtherThenTimeout,
    lrStoppedThenTimeout, lrMalformed);
  TFakeLink = class(TWatchLink)
    Last: TRippleBytes;
    LastEP: Word;
    Initializations, Commits, Completes, Chunks, Aborts: Integer;
    Modern, RejectChunk, MetadataWritten, Refreshed, CompletionEchoesToken: Boolean;
    WrongTokenCommand, ZeroTokenCommand, RejectCommand, ShortReplyCommand: Byte;
    RunStateQueries: Integer;
    LaunchReply: TLaunchReply;
    procedure Send(Endpoint: Word; const Data: TRippleBytes); override;
    function Wait(Endpoint: Word; TimeoutMS: Integer = 15000): TRippleBytes; override;
  end;
  TFakeConnector = class(TWatchConnector)
    Attempts, Delays, BusyCount, Failure: Integer;
    function ConnectOnce(const Address: string): TWatchLink; override;
    procedure RetryDelay; override;
  end;

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then raise Exception.Create(Message);
end;

function TFakeConnector.ConnectOnce(const Address: string): TWatchLink;
begin
  Inc(Attempts);
  if Attempts <= BusyCount then raise EBluetoothConnect.Create(ESysEBUSY);
  if Failure <> 0 then raise EBluetoothConnect.Create(Failure);
  Result := TFakeLink.Create;
end;

procedure TFakeConnector.RetryDelay;
begin
  Inc(Delays);
end;

procedure TFakeLink.Send(Endpoint: Word; const Data: TRippleBytes);
begin
  LastEP := Endpoint;
  Last := Copy(Data);
  if Endpoint = EP_BLOB_DB then
  begin
    Check((Data[3] = 2) and (Data[4] = 16), 'BlobDB app database/key');
    Check(UUIDText(Data, 5) = AppUUID, 'BlobDB UUID');
    if Data[0] = 1 then
    begin
      Check(Read16LE(Data, 21) = 126, 'metadata length');
      Check(UUIDText(Data, 23) = AppUUID, 'metadata UUID');
      MetadataWritten := True;
    end;
  end;
  if Endpoint = EP_PUT_BYTES then
  begin
    if Data[0] <> 1 then
      Check(Read32BE(Data, 1) = $12345678, 'requests retain the transfer token');
    case Data[0] of
      1:
        begin
          Inc(Initializations);
          if Modern then
          begin
            Check(Length(Data) = 10, 'modern PutBytes init size');
            Check(Data[5] = ($80 or ObjectTypes[Initializations]),
              'modern PutBytes object type');
            Check(Read32BE(Data, 6) = $01020304, 'PutBytes app ID converted from AppFetch byte order');
          end
          else Check(Length(Data) = 7, 'legacy PutBytes init size');
        end;
      2:
        begin
          Inc(Chunks);
          Check(Read32BE(Data, 5) <= 2000, 'chunk limit');
          Check(Read32BE(Data, 5) = Cardinal(Length(Data) - 9), 'chunk size');
        end;
      3: Inc(Commits);
      4: Inc(Aborts);
      5: Inc(Completes);
    end;
  end;
  if (Endpoint = EP_APP_MANAGER) and (Data[0] = 3) then Refreshed := True;
  if (Endpoint = EP_RUN_STATE) and (Data[0] = 3) then
  begin
    Check(Modern and (Completes = 3), 'launch queried after all app files are installed');
    Inc(RunStateQueries);
  end;
end;

function TFakeLink.Wait(Endpoint: Word; TimeoutMS: Integer): TRippleBytes;
var Version: string;
begin
  Result := nil;
  case Endpoint of
    EP_VERSION:
      begin
        SetLength(Result, 95);
        Result[0] := 1;
        Result[46] := 5;
        Version := 'v3.13.3-rbl';
        Move(Version[1], Result[5], Length(Version));
      end;
    EP_BLOB_DB: Result := Join(Copy(Last, 1, 2), Bytes([1]));
    EP_APP_FETCH: Result := Join(Bytes([1]), Join(UUIDBytes(AppUUID), Bytes([4, 3, 2, 1])));
    EP_RUN_STATE:
      begin
        Check(RunStateQueries > 0, 'fresh launch-state query sent');
        if (LaunchReply = lrNoResponse) or
          ((LaunchReply in [lrOtherThenTimeout, lrStoppedThenTimeout]) and (RunStateQueries > 1)) then
          raise EWatchTimeout.Create('No watch launch response');
        if LaunchReply = lrMalformed then Exit(Bytes([1]));
        if LaunchReply = lrStoppedThenTimeout then Exit(Join(Bytes([2]), UUIDBytes(AppUUID)));
        if (RunStateQueries = 1) and (LaunchReply in [lrDelayed, lrOtherThenTimeout]) then
          Exit(Join(Bytes([1]), UUIDBytes('ffffffff-ffff-ffff-ffff-ffffffffffff')));
        Result := Join(Bytes([1]), UUIDBytes(AppUUID));
      end;
    EP_PUT_BYTES:
      if (RejectChunk and (Last[0] = 2)) or (RejectCommand = Last[0]) then
        Result := Join(Bytes([2]), U32BE(0))
      else if ShortReplyCommand = Last[0] then Result := Bytes([1])
      else if WrongTokenCommand = Last[0] then Result := Join(Bytes([1]), U32BE($87654321))
      else if (ZeroTokenCommand = Last[0]) or ((Last[0] = 5) and not CompletionEchoesToken) then
        Result := Join(Bytes([1]), U32BE(0))
      else Result := Join(Bytes([1]), U32BE($12345678));
    EP_APP_MANAGER:
      case Last[0] of
        5:
          if Refreshed then Result := Join(Bytes([5]), Join(U32BE(1), UUIDBytes(AppUUID)))
          else Result := Join(Bytes([5]), U32BE(0));
        1:
          if Refreshed then
          begin
            Result := Join(Bytes([1]), Join(U32BE(8), U32BE(1)));
            SetLength(Result, 9 + 78);
          end
          else Result := Join(Bytes([1]), Join(U32BE(8), U32BE(0)));
        2: Result := Join(Bytes([2]), U32BE(1));
      end;
    else raise Exception.Create('Unexpected endpoint');
  end;
end;

procedure TestBytesAndCRC;
const InitPacket: array[0..9] of Byte = (1, $11, $22, $33, $44, $85, 1, 2, 3, 4);
var B: TRippleBytes; Failed: Boolean; I: Integer;
begin
  Check(UUIDText(UUIDBytes(AppUUID), 0) = AppUUID, 'UUID round trip');
  Check(Read32BE(U32BE($89ABCDEF), 0) = $89ABCDEF, 'big endian');
  Check(Read32LE(U32LE($89ABCDEF), 0) = $89ABCDEF, 'little endian');
  Failed := False;
  try Read32BE(Bytes([1]), 0); except Failed := True; end;
  Check(Failed, 'truncated bytes rejected');
  Check(PebbleCRC(nil) = $FFFFFFFF, 'empty CRC');
  B := Bytes([1, 2, 3, 4]);
  Check(PebbleCRC(B) = $1DABE74F, 'word CRC');
  Check(PebbleCRC(Bytes([1, 2, 3])) = $6B6DC92A, 'partial-word CRC');
  B := PutBytesInit($11223344, 5, $01020304, True);
  Check(Length(B) = Length(InitPacket), 'PutBytes app-init packet length');
  for I := 0 to High(InitPacket) do
    Check(B[I] = InitPacket[I], 'PutBytes app-init wire bytes');
end;

procedure TestInfo(const Root: string);
var B: TRippleBytes; Info: TWatchInfo; S: string; Stream: TFileStream; Link: TFakeLink;
begin
  Check(PlatformForHardware(5) = 'aplite', 'Pebble Steel hardware');
  Check(PlatformForHardware(10) = 'basalt', 'Pebble Time Steel hardware');
  Check(PlatformForHardware(11) = 'chalk', 'Pebble Time Round hardware');
  Check(PlatformForHardware(14) = 'diorite', 'Pebble 2 hardware');
  Check(PlatformForHardware(13) = 'emery', 'Pebble Time 2 hardware');
  Check(PlatformForHardware(15) = 'flint', 'Pebble 2 Duo hardware');
  Check(PlatformForHardware(21) = 'gabbro', 'Pebble Round 2 hardware');
  Check(PlatformForHardware(100) = '', 'unknown hardware');
  B := PhoneVersionReply;
  Check((Length(B) = 25) and (Read32LE(B, 17) = 1), 'app-run-state capability');
  B := nil;
  SetLength(B, 95);
  B[0] := 1;
  B[45] := 0;
  B[46] := 8;
  S := 'v4.3.1';
  Move(S[1], B[5], Length(S));
  Info := ParseWatchInfo(B);
  Check((Info.Major = 4) and (Info.Platform = 'basalt'), 'firmware version parsing');
  B[45] := 1;
  Check(ParseWatchInfo(B).Platform = 'basalt', 'firmware flags do not select hardware');
  Stream := TFileStream.Create(Root + '/version.bin', fmOpenRead);
  try
    SetLength(B, Stream.Size);
    Stream.ReadBuffer(B[0], Length(B));
  finally Stream.Free; end;
  Info := ParseWatchInfo(B);
  Check((Info.Firmware = 'v3.13.3-rbl') and (Info.Major = 3) and
    (Info.Platform = 'aplite'), 'packed firmware-3 version response');
  Link := TFakeLink.Create;
  try
    Info := Link.Identify;
    Check((Info.Platform = 'aplite') and (Link.LastEP = 17), 'identification advertises phone capabilities');
    Check((Length(Link.Last) = 25) and (Read32LE(Link.Last, 17) = 1),
      'identification advertises app-run-state support');
  finally Link.Free; end;
end;

procedure TestTempPBW(const Root: string);
var Temp, Other: TTempPBWFile; Source: TFileStream; PBW: TPBW;
  Filename: string; Details: Stat; Failed: Boolean;
begin
  Temp := TTempPBWFile.Create(Root);
  Filename := Temp.Filename;
  try
    Check(FileExists(Filename), 'temporary PBW file created before download');
    Check(fpStat(Filename, Details) = 0, 'temporary PBW file stat');
    Check((Details.st_mode and &777) = &600, 'temporary PBW file private permissions');
    Source := TFileStream.Create(Root + '/test.pbw', fmOpenRead);
    try
      Temp.CopyFrom(Source, 0);
      Check(Temp.Size = Source.Size, 'temporary PBW stream size');
    finally Source.Free; end;
    Other := TTempPBWFile.Create(Root);
    try Check(Other.Filename <> Filename, 'separate downloads have separate files');
    finally Other.Free; end;
    PBW := TPBW.Create(Filename, 'basalt');
    try Check(PBW.Item.UUID = AppUUID, 'downloaded PBW parsed while temporary stream is open');
    finally PBW.Free; end;
  finally Temp.Free; end;
  Check(not FileExists(Filename), 'temporary PBW removed after download');
  Temp := TTempPBWFile.Create(Root);
  Filename := Temp.Filename;
  try
    try raise Exception.Create('Download failed');
    finally FreeAndNil(Temp); end;
  except end;
  Check(not FileExists(Filename), 'temporary PBW removed after failure');
  Failed := False;
  try Temp := TTempPBWFile.Create(Root + '/missing-directory'); Temp.Free;
  except Failed := True; end;
  Check(Failed, 'unavailable temporary directory reported');
end;

procedure TestInventory;
var Data, UUIDs: TRippleBytes; Items: TRippleItems; Banks: Cardinal; Failed: Boolean;
begin
  Data := Join(Bytes([1]), Join(U32BE(8), U32BE(1)));
  Data := Join(Data, Join(U32BE(42), U32BE(2)));
  SetLength(Data, 9 + 78);
  Data[17] := Ord('A');
  UUIDs := Join(Bytes([5]), Join(U32BE(1), UUIDBytes(AppUUID)));
  Items := ParseAppBanks(Data, UUIDs, Banks);
  Check((Banks = 8) and (Length(Items) = 1), 'app inventory count');
  Check((Items[0].Bank = 2) and (Items[0].AppID = 42), 'app bank/id');
  Check((Items[0].Title = 'A') and (Items[0].UUID = AppUUID), 'app name/UUID');
  Failed := False;
  try ParseAppBanks(Copy(Data, 0, Length(Data) - 1), UUIDs, Banks);
  except Failed := True; end;
  Check(Failed, 'truncated app inventory rejected');
  UUIDs[4] := 0;
  Failed := False;
  try ParseAppBanks(Data, UUIDs, Banks); except Failed := True; end;
  Check(Failed, 'inconsistent UUID inventory rejected');
end;

procedure TestTLS;
var Failed: Boolean;
begin
  RequireHTTPS('https://example.org/app.pbw');
  Failed := False;
  try RequireHTTPS('http://example.org/app.pbw'); except Failed := True; end;
  Check(Failed, 'HTTP downgrade rejected');
  Failed := False;
  try RequireHTTPS('file:///etc/passwd'); except Failed := True; end;
  Check(Failed, 'local download rejected');
  Failed := False;
  try RequireHTTPS('https://user:password@example.org/app.pbw'); except Failed := True; end;
  Check(Failed, 'embedded credentials rejected');
end;

procedure TestPBW(const Root: string);
var PBW: TPBW; L: TFakeLink; Failed: Boolean;
begin
  PBW := TPBW.Create(Root + '/test.pbw', 'basalt');
  try
    Check(PBW.Item.UUID = AppUUID, 'PBW UUID');
    Check(PBW.Item.Title = 'Test app', 'PBW title');
    Check((Length(PBW.Metadata) = 126) and (Read32LE(PBW.Metadata, 16) = 9), 'PBW flags');
    L := TFakeLink.Create;
    try
      L.Modern := True;
      InstallWatchApp(L, PBW, True, nil);
      Check(L.MetadataWritten, 'modern metadata written');
      Check((L.Initializations = 3) and (L.Commits = 3) and
        (L.Completes = 3) and (L.Chunks = 5), 'modern upload stages');
      RemoveWatchApp(L, PBW.Item, True);
      Check((L.LastEP = EP_BLOB_DB) and (L.Last[0] = 4), 'modern remove');
    finally L.Free; end;
    L := TFakeLink.Create;
    try
      InstallWatchApp(L, PBW, False, nil);
      Check(L.Refreshed, 'legacy free bank registration');
      RemoveWatchApp(L, PBW.Item, False);
      Check((Length(L.Last) = 17) and (UUIDText(L.Last, 1) = AppUUID), 'legacy remove UUID');
    finally L.Free; end;
    L := TFakeLink.Create;
    try
      L.Modern := True;
      L.RejectChunk := True;
      Failed := False;
      try InstallWatchApp(L, PBW, True, nil); except Failed := True; end;
      Check(Failed and (L.Aborts = 1) and (L.Commits = 0), 'failed transfer aborted');
    finally L.Free; end;
  finally PBW.Free; end;
  PBW := TPBW.Create(Root + '/legacy.pbw', 'aplite');
  try Check(PBW.Item.UUID = AppUUID, 'legacy app header UUID and root manifest');
  finally PBW.Free; end;
  Failed := False;
  try PBW := TPBW.Create(Root + '/bad.pbw', 'basalt'); PBW.Free;
  except Failed := True; end;
  Check(Failed, 'bad PBW CRC rejected');
  Failed := False;
  try PBW := TPBW.Create(Root + '/test.pbw', 'chalk'); PBW.Free;
  except Failed := True; end;
  Check(Failed, 'wrong PBW hardware rejected');
end;

procedure TestCatalogAndSettings;
var Items: TRippleItems; Info: TWatchInfo; Item: TRippleItem;
begin
  Items := ParseCatalog('{"applications":[{"title":"Clock","author":"A","uuid":"' +
    AppUUID + '","latest_release":{"pbw_file":"https://example.org/a.pbw","version":"1.0"}}]}');
  Check((Length(Items) = 1) and (Items[0].Title = 'Clock') and
    (Items[0].DownloadURL = 'https://example.org/a.pbw'), 'catalog fields');
  Info := Default(TWatchInfo);
  Info.Address := '00:11:22:33:44:55';
  Info.Platform := 'basalt'; Info.Firmware := 'v4.3.1'; Info.Major := 4;
  SaveWatchInfo(Info);
  Check(LoadWatchInfo(Info.Address).Platform = 'basalt', 'saved platform');
  Check(LoadWatchInfo('AA:BB:CC:DD:EE:FF').Platform = '', 'platform scoped to watch');
  Item := Items[0];
  SaveManagedApp(Info.Address, Item, False);
  Items := LoadManagedApps(Info.Address);
  Check((Length(Items) = 1) and (Items[0].UUID = AppUUID), 'saved app record');
  Check(Pos('launch has not been confirmed', Items[0].Description) > 0,
    'registration alone does not confirm installation');
  SaveManagedApp(Info.Address, Item, False, True);
  Items := LoadManagedApps(Info.Address);
  Check(Pos('launch was confirmed', Items[0].Description) > 0, 'confirmed launch recorded');
  SaveManagedApp(Info.Address, Item, False);
  Items := LoadManagedApps(Info.Address);
  Check(Pos('launch has not been confirmed', Items[0].Description) > 0,
    'new registration resets prior launch confirmation');
  Check(Length(LoadManagedApps('AA:BB:CC:DD:EE:FF')) = 0, 'app records scoped to watch');
  SaveManagedApp(Info.Address, Item, True);
  Check(Length(LoadManagedApps(Info.Address)) = 0, 'removed saved record');
end;

procedure TestLaunchConfirmation(const Root: string);
var PBW: TPBW; Link: TFakeLink; Mode: TLaunchReply; ErrorText: string;
begin
  PBW := TPBW.Create(Root + '/test.pbw', 'basalt');
  try
    for Mode := Low(TLaunchReply) to High(TLaunchReply) do
    begin
      Link := TFakeLink.Create;
      try
        Link.Modern := True;
        Link.LaunchReply := Mode;
        ErrorText := '';
        try InstallWatchApp(Link, PBW, True, nil);
        except on E: Exception do ErrorText := E.Message; end;
        Check((Link.Completes = 3) and (Link.RunStateQueries > 0),
          'transfer ACKs followed by launch verification');
        if Mode in [lrRunning, lrDelayed] then
        begin
          Check(ErrorText = '', 'target launch confirmed');
          if Mode = lrDelayed then Check(Link.RunStateQueries = 2, 'old app state queried again');
        end
        else if Mode = lrMalformed then
          Check(Pos('installation is unconfirmed', ErrorText) > 0, 'malformed launch state rejected')
        else
          Check(Pos('watch did not confirm launch', ErrorText) > 0,
            'successful transfer without target launch not reported as installed');
        if Mode = lrOtherThenTimeout then
          Check(Pos('ffffffff-ffff-ffff-ffff-ffffffffffff', ErrorText) > 0,
            'last reported watch app included in failure');
        Check(Link.Aborts = 0, 'completed transfers not aborted after unconfirmed launch');
      finally Link.Free; end;
    end;
  finally PBW.Free; end;
end;

procedure TestTransferAcknowledgements(const Root: string);
const Commands: array[0..2] of Byte = (2, 3, 5);
  Stages: array[0..2] of string = ('data', 'commit', 'completion');
var PBW: TPBW; Link: TFakeLink; I: Integer; ErrorText: string;
begin
  PBW := TPBW.Create(Root + '/test.pbw', 'basalt');
  try
    Link := TFakeLink.Create;
    try
      Link.Modern := True;
      Link.CompletionEchoesToken := True;
      InstallWatchApp(Link, PBW, True, nil);
      Check((Link.Completes = 3) and (Link.Aborts = 0), 'completion ACK with matching token');
    finally Link.Free; end;
    Link := TFakeLink.Create;
    try
      Link.Modern := True;
      InstallWatchApp(Link, PBW, True, nil);
      Check((Link.Completes = 3) and (Link.Aborts = 0), 'completion ACK with cleared token');
    finally Link.Free; end;
    for I := 0 to High(Commands) do
    begin
      Link := TFakeLink.Create;
      try
        Link.Modern := True;
        Link.WrongTokenCommand := Commands[I];
        ErrorText := '';
        try InstallWatchApp(Link, PBW, True, nil);
        except on E: Exception do ErrorText := E.Message; end;
        Check((Pos('during ' + Stages[I], ErrorText) > 0) and
          (Pos('expected 12345678, received 87654321', ErrorText) > 0),
          'wrong token reported with stage and values');
        Check(Link.Aborts = 1, 'wrong transfer token aborts upload');
      finally Link.Free; end;
    end;
    for I := 0 to 1 do
    begin
      Link := TFakeLink.Create;
      try
        Link.Modern := True;
        Link.ZeroTokenCommand := Commands[I];
        ErrorText := '';
        try InstallWatchApp(Link, PBW, True, nil);
        except on E: Exception do ErrorText := E.Message; end;
        Check((Pos('during ' + Stages[I], ErrorText) > 0) and
          (Pos('expected 12345678, received 00000000', ErrorText) > 0),
          'cleared token rejected before completion');
        Check((Link.Aborts = 1) and (Link.Completes = 0), 'premature token clearing stops upload');
      finally Link.Free; end;
    end;
    Link := TFakeLink.Create;
    try
      Link.Modern := True;
      Link.RejectCommand := 5;
      ErrorText := '';
      try InstallWatchApp(Link, PBW, True, nil);
      except on E: Exception do ErrorText := E.Message; end;
      Check(Pos('rejected file transfer during completion', ErrorText) > 0,
        'completion NACK with zero token rejected');
      Check((Link.Initializations = 1) and (Link.Aborts = 1), 'completion failure stops remaining files');
    finally Link.Free; end;
    Link := TFakeLink.Create;
    try
      Link.Modern := True;
      Link.ShortReplyCommand := 5;
      ErrorText := '';
      try InstallWatchApp(Link, PBW, True, nil);
      except on E: Exception do ErrorText := E.Message; end;
      Check(Pos('Truncated file transfer acknowledgement during completion', ErrorText) > 0,
        'truncated completion ACK rejected');
      Check(Link.Aborts = 1, 'truncated response aborts upload');
    finally Link.Free; end;
  finally PBW.Free; end;
end;

procedure TestDaemon(const Root: string);
var D: TDaemonPause; Log: TStringList; F: TFileStream;
begin
  Log := TStringList.Create;
  D := TDaemonPause.Create(Root + '/control');
  try
    F := TFileStream.Create(Root + '/running', fmCreate);
    F.Free;
    try
      D.Pause;
      Check(not FileExists(Root + '/running'), 'running daemon paused');
      raise Exception.Create('Watch operation failed');
    except
      D.Resume;
    end;
    Check(FileExists(Root + '/running'), 'daemon restored after failure');
    D.Resume;
    Log.LoadFromFile(Root + '/control.log');
    Check(Log.Text = 'status' + LineEnding + 'stop' + LineEnding +
      'status' + LineEnding + 'start' + LineEnding,
      'daemon restored exactly once');
    DeleteFile(Root + '/running');
    D.Pause;
    D.Resume;
    Check(not FileExists(Root + '/running'), 'stopped daemon remains stopped');
    Log.LoadFromFile(Root + '/control.log');
    Check(Log.Count = 5, 'no restart for stopped daemon');
  finally D.Free; Log.Free; end;
end;

procedure CheckChildDescriptors(const Filename: string);
var Entry: TSearchRec; Line: string;
begin
  if FindFirst('/proc/self/fd/*', faAnyFile, Entry) = 0 then
  try
    repeat
      Check(fpReadLink('/proc/self/fd/' + Entry.Name) <> Filename,
        'watch lock leaked into control child');
    until FindNext(Entry) <> 0;
  finally FindClose(Entry); end;
  WriteLn('ready');
  Flush(Output);
  ReadLn(Line);
end;

procedure TestWatchAccess(const Root: string);
var Access, Second: TWatchAccess; Child: TProcess; Filename: string;
  Ready: array[0..5] of Char; Failed: Boolean;
begin
  Filename := Root + '/watch-access.lock';
  Access := TWatchAccess.Create(Filename);
  try
    Failed := False;
    try Second := TWatchAccess.Create(Filename); Second.Free;
    except Failed := True; end;
    Check(Failed, 'second watch operation excluded');
    Child := TProcess.Create(nil);
    try
      Child.Executable := ExpandFileName(ParamStr(0));
      Child.Parameters.Add('--check-lock-child');
      Child.Parameters.Add(Filename);
      Child.Options := [poUsePipes];
      Child.Execute;
      Check(Child.Output.Read(Ready, SizeOf(Ready)) = SizeOf(Ready), 'control child ready');
      Check(Copy(string(Ready), 1, 5) = 'ready', 'control child descriptor check');
      FreeAndNil(Access);
      Second := TWatchAccess.Create(Filename);
      Second.Free;
      Check(Child.Running, 'watch lock released while control child stays running');
      Child.CloseInput;
      Child.WaitOnExit;
      Check(Child.ExitStatus = 0, 'control child completed');
    finally
      if Child.Running then
      begin
        Child.CloseInput;
        Child.WaitOnExit;
      end;
      Child.Free;
    end;
  finally Access.Free; end;
  Access := TWatchAccess.Create(Filename);
  try
    try raise Exception.Create('Watch operation failed');
    finally FreeAndNil(Access); end;
  except end;
  Access := TWatchAccess.Create(Filename);
  Access.Free;
end;

procedure TestConnectionRetry;
var Connector: TFakeConnector; Link: TWatchLink; Failed: Boolean;
begin
  Connector := TFakeConnector.Create;
  try
    Connector.BusyCount := 2;
    Link := Connector.Connect('00:11:22:33:44:55', nil);
    Link.Free;
    Check((Connector.Attempts = 3) and (Connector.Delays = 2), 'busy connection retried');
  finally Connector.Free; end;
  Connector := TFakeConnector.Create;
  try
    Connector.BusyCount := 100;
    Failed := False;
    try Link := Connector.Connect('00:11:22:33:44:55', nil); Link.Free;
    except on E: EBluetoothConnect do Failed := E.ErrorCode = ESysEBUSY; end;
    Check(Failed and (Connector.Attempts = 8) and (Connector.Delays = 7), 'bounded busy retries');
  finally Connector.Free; end;
  Connector := TFakeConnector.Create;
  try
    Connector.Failure := ESysEACCES;
    Failed := False;
    try Link := Connector.Connect('00:11:22:33:44:55', nil); Link.Free;
    except on E: EBluetoothConnect do Failed := E.ErrorCode = ESysEACCES; end;
    Check(Failed and (Connector.Attempts = 1) and (Connector.Delays = 0), 'permanent error not retried');
  finally Connector.Free; end;
end;

begin
  if ParamStr(1) = '--check-lock-child' then
  begin
    CheckChildDescriptors(ParamStr(2));
    Halt(0);
  end;
  if ParamStr(1) = '--check-lock-parent' then
  begin
    TestWatchAccess(ParamStr(2));
    Halt(0);
  end;
  TestBytesAndCRC;
  TestInfo(ParamStr(1));
  TestInventory;
  TestTLS;
  TestPBW(ParamStr(1));
  TestTransferAcknowledgements(ParamStr(1));
  TestLaunchConfirmation(ParamStr(1));
  TestTempPBW(ParamStr(1));
  TestCatalogAndSettings;
  TestDaemon(ParamStr(1));
  TestWatchAccess(ParamStr(1));
  TestConnectionRetry;
  WriteLn('Ripple UI logic tests passed');
end.
