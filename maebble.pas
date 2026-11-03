unit maebble;

{$mode objfpc}{$H+}
{$linklib bluetooth}

interface

uses
  SysUtils, Classes, ctypes, bluetooth;

const
  MAEBBLE_VERSION = '0.1.0';
  ENDPOINT_FIRMWARE        = 1;
  ENDPOINT_TIME            = 11;
  ENDPOINT_VERSION         = 16;
  ENDPOINT_PHONE_VERSION   = 17;
  ENDPOINT_SYSTEM_MESSAGE  = 18;
  ENDPOINT_MUSIC_CONTROL   = 32;
  ENDPOINT_PHONE_CONTROL   = 33;
  ENDPOINT_APPLICATION     = 48;
  ENDPOINT_LOGS            = 2000;
  ENDPOINT_PING            = 2001;
  ENDPOINT_NOTIFICATION    = 3000;
  ENDPOINT_BLOB            = 45531;

  CONFIG_FILE          = '/home/user/.config/maebble/maebble.cfg';
  DEFAULT_BT_ADDRESS   = '';

  NOTIF_SOURCE_EMAIL   = 19;
  NOTIF_SOURCE_SMS     = 45;

  MEDIA_STATUS_STOPPED = 0;
  MEDIA_STATUS_PLAYING = 1;
  MEDIA_STATUS_PAUSED  = 2;

  OSCP_NOW_PLAYING     = '/tmp/oscp-user/oscp-now-playing.txt';
  OSCP_SLAVE           = '/tmp/oscp-user/oscp.slave';

  DBUS_MAFW_DEST       = 'com.nokia.mafw.renderer.Mafw-Gst-Renderer-Plugin.gstrenderer';
  DBUS_MAFW_PATH       = '/com/nokia/mafw/renderer/gstrenderer';
  DBUS_MAFW_IFACE      = 'com.nokia.mafw.renderer';

  CONTACTS_DB          = '/home/user/.rtcom-eventlogger/el-v1.db';

procedure Main;

procedure NotificationSMS(const sender, body: AnsiString);
procedure NotificationEmail(const sender, subject, body: AnsiString);
procedure SetNowPlayingMetadata(const track, album, artist: AnsiString);
function  LookupContact(const number: string): string;

implementation

uses
  Sockets, Unix, BaseUnix, IniFiles, DateUtils, Types, SyncObjs, Process;

type
  TBytes = array of Byte;
  TUUID  = array[0..15] of Byte;

var
  g_bt_address:    string  = DEFAULT_BT_ADDRESS;
  g_process_sleep: Double  = 0.25;
  g_connect_sleep: Integer = 30;
  g_time_sleep:    Integer = 4;
  g_use_oscp:      Boolean = True;
  g_watch_version: string  = 'v1.00.0';
  g_print_maemo:   Boolean = False;
  g_sock:          cint    = -1;
  g_sock_lock:     TCriticalSection = nil;
  g_initial_watermark: Integer = 0;

procedure ShowHelp;
begin
  WriteLn('maebbled ', MAEBBLE_VERSION);
  WriteLn('Pebble companion daemon for Maemo');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  maebbled [OPTIONS]');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  -h, --help                     Show this help and exit');
  WriteLn('      --version                  Show version and exit');
  WriteLn('  -v, --verbose                  Verbose / debug output');
  WriteLn('      --print_maemo              Alias for --verbose (legacy)');
  WriteLn('      --test-sms SENDER BODY');
  WriteLn('                                     Send one SMS notification and exit');
  WriteLn('      --test-email SENDER SUBJECT BODY');
  WriteLn('                                     Send one email notification and exit');
  WriteLn;
  WriteLn('Config file:');
  WriteLn('  ', CONFIG_FILE);
  WriteLn('  (fallback: ./maebble.cfg in the current directory)');
  WriteLn;
  WriteLn('With no options, connects to the Pebble configured in maebble.cfg,');
  WriteLn('sends VERSION/TIME/PING handshake, then listens on D-Bus for');
  WriteLn('incoming SMS and relays them to the watch until killed (Ctrl+C).');
end;


function GetLocalTimeUnix: Cardinal; forward;


{ ================= byte / string helpers ================= }

function Bytes(const Values: array of Byte): TBytes;
var i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Values));
  for i := 0 to High(Values) do Result[i] := Values[i];
end;

function BytesOf(const S: AnsiString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function Cat(const A, B: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function PackU16LE(v: Word): TBytes; inline;
begin Result := Bytes([v and $FF, (v shr 8) and $FF]); end;

function PackU16BE(v: Word): TBytes; inline;
begin Result := Bytes([(v shr 8) and $FF, v and $FF]); end;

function PackU32LE(v: Cardinal): TBytes; inline;
begin Result := Bytes([v and $FF, (v shr 8) and $FF,
                       (v shr 16) and $FF, (v shr 24) and $FF]); end;

function PackU32BE(v: Cardinal): TBytes; inline;
begin Result := Bytes([(v shr 24) and $FF, (v shr 16) and $FF,
                       (v shr 8) and $FF, v and $FF]); end;

function UnpackU16BE(const B: TBytes; off: Integer): Word; inline;
begin Result := (Word(B[off]) shl 8) or Word(B[off+1]); end;

function UnpackU32BE(const B: TBytes; off: Integer): Cardinal; inline;
begin Result := (Cardinal(B[off]) shl 24) or (Cardinal(B[off+1]) shl 16)
              or (Cardinal(B[off+2]) shl 8) or Cardinal(B[off+3]); end;

function PackPascalString(const S: AnsiString): TBytes;
var n: Integer;
begin
  Result := nil;
  n := Length(S);
  if n > 255 then n := 255;
  SetLength(Result, n + 1);
  Result[0] := Byte(n);
  if n > 0 then Move(S[1], Result[1], n);
end;

function PackMessageData(lead: Byte; const Parts: array of AnsiString): TBytes;
var i: Integer;
begin
  Result := Bytes([lead]);
  for i := 0 to High(Parts) do
    Result := Cat(Result, PackPascalString(Parts[i]));
end;

function BuildMessage(endpoint: Word; const payload: TBytes): TBytes;
begin
  Result := Cat(Cat(PackU16BE(Length(payload)), PackU16BE(endpoint)), payload);
end;

function BytesOfTrunc(const S: AnsiString; maxLen: Integer): TBytes;
begin
  Result := BytesOf(Copy(S, 1, maxLen));
end;

{ ================= configuration ================= }

function FindConfigFile: string;
begin
  if FileExists(CONFIG_FILE) then
    Result := CONFIG_FILE
  else if FileExists('maebble.cfg') then
    Result := 'maebble.cfg'
  else
    Result := '';
end;

procedure Configure;
var
  cfg: TIniFile;
  cfgPath: string;
begin
  cfgPath := FindConfigFile;
  if cfgPath = '' then
  begin
    WriteLn('No config file found (looked in ', CONFIG_FILE, ' and ./maebble.cfg)');
    Exit;
  end;

  cfg := TIniFile.Create(cfgPath);
  try
    g_bt_address    := cfg.ReadString ('btservice','address',       DEFAULT_BT_ADDRESS);
    g_process_sleep := cfg.ReadFloat  ('btservice','process_sleep', 0.25);
    g_connect_sleep := cfg.ReadInteger('btservice','connect_sleep', 30);
    g_time_sleep    := cfg.ReadInteger('btservice','time_sleep',    4);
    g_use_oscp      := LowerCase(Trim(
                         cfg.ReadString('media','use_oscp','true'))) = 'true';
  finally
    cfg.Free;
  end;
  if g_print_maemo then
  begin
    WriteLn('config:        ', cfgPath);
    WriteLn('BT address:    ', g_bt_address);
    WriteLn('process_sleep: ', g_process_sleep:0:2);
    WriteLn('connect_sleep: ', g_connect_sleep);
    WriteLn('time_sleep:    ', g_time_sleep);
    WriteLn('use_oscp:      ', g_use_oscp);
  end;
end;

{ ================= Bluetooth transport ================= }

function BtConnect(const addr: string): cint;
var
  s: cint;
  a: sockaddr_rc;
begin
  if addr = '' then
  begin
    WriteLn('No BT address configured');
    Exit(-1);
  end;
  s := fpSocket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
  if s < 0 then
  begin
    if g_print_maemo then WriteLn('fpSocket failed: ', fpgeterrno);
    Exit(-1);
  end;

  FillChar(a, SizeOf(a), 0);
  a.rc_family  := AF_BLUETOOTH;
  a.rc_channel := 1;
  if str2ba(pcchar(PChar(addr)), @a.rc_bdaddr) <> 0 then
  begin
    if g_print_maemo then WriteLn('Bad BT address: ', addr);
    CloseSocket(s);
    Exit(-1);
  end;

  if fpConnect(s, @a, SizeOf(a)) < 0 then
  begin
    if g_print_maemo then WriteLn('fpConnect failed: ', fpgeterrno);
    CloseSocket(s);
    Exit(-1);
  end;

  Result := s;
end;

function BtSendAll(s: cint; const buf: TBytes): Boolean;
var sent, n: Integer;
begin
  sent := 0;
  while sent < Length(buf) do
  begin
    n := fpSend(s, @buf[sent], Length(buf) - sent, 0);
    if n <= 0 then Exit(False);
    Inc(sent, n);
  end;
  Result := True;
end;

function BtRecvExact(s: cint; var buf: TBytes; count: Integer): Boolean;
var got, n: Integer;
begin
  SetLength(buf, count);
  got := 0;
  while got < count do
  begin
    n := fpRecv(s, @buf[got], count - got, 0);
    if n <= 0 then Exit(False);
    Inc(got, n);
  end;
  Result := True;
end;

procedure Send(endpoint: Word; const payload: TBytes);
var
  msg: TBytes;
begin
  g_sock_lock.Enter;
  try
    if g_sock < 0 then Exit;
    msg := BuildMessage(endpoint, payload);
    BtSendAll(g_sock, msg);
  finally
    g_sock_lock.Leave;
  end;
end;

{ ================= external command helpers ================= }

function RunCapture(const exe: string; const args: array of string; out output: string): Boolean;
var
  p: TProcess;
  buf: array[0..1023] of Byte;
  n: LongInt;
  ms: TMemoryStream;
  i: Integer;
begin
  Result := False;
  output := '';
  p := TProcess.Create(nil);
  ms := TMemoryStream.Create;
  try
    p.Executable := exe;
    for i := 0 to High(args) do
      p.Parameters.Add(args[i]);
    p.Options := [poUsePipes];
    try
      p.Execute;
    except
      Exit;
    end;
    repeat
      n := p.Output.Read(buf, SizeOf(buf));
      if n > 0 then ms.Write(buf, n);
    until n <= 0;
    SetLength(output, ms.Size);
    if ms.Size > 0 then
    begin
      ms.Position := 0;
      ms.Read(output[1], ms.Size);
    end;
    p.WaitOnExit;
    Result := p.ExitStatus = 0;
  finally
    ms.Free;
    p.Free;
  end;
end;


function ContactsDbFile: string;
var
  home: string;
begin
  home := GetEnvironmentVariable('HOME');
  if home <> '' then
    Result := home + '/.rtcom-eventlogger/el-v1.db'
  else
    Result := CONTACTS_DB;
end;

function QueryMaxEventId: Integer;
var
  outStr: string;
begin
  Result := 0;
  if RunCapture('sqlite3',
       [ContactsDbFile, 'SELECT MAX(id) FROM Events'], outStr) then
  begin
    outStr := Trim(StringReplace(outStr, #10, '', [rfReplaceAll]));
    Result := StrToIntDef(outStr, 0);
  end;
end;


{ ================= contact lookup (sqlite3 CLI) ================= }

function LookupContact(const number: string): string;
var
  outStr: string;
begin
  Result := number;
  if not FileExists(ContactsDbFile) then Exit;
  if RunCapture('sqlite3',
       [ContactsDbFile,
        'SELECT remote_name FROM remotes WHERE remote_uid=' + QuotedStr(number)],
       outStr) then
  begin
    outStr := Trim(StringReplace(outStr, #10, '', [rfReplaceAll]));
    if outStr <> '' then Result := outStr;
  end;
end;


{ ================= PDU decoding (SMS) ================= }

const
  GSM7_CODEPOINTS: array[0..127] of Word = (
    $0040, $00A3, $0024, $00A5, $00E8, $00E9, $00F9, $00EC, $00F2, $00C7, $000A, $00D8, $00F8, $000D, $00C5, $00E5,
    $0394, $005F, $03A6, $0393, $039B, $03A9, $03A0, $03A8, $03A3, $0398, $039E, $0020, $00C6, $00E6, $00DF, $00C9,
    $0020, $0021, $0022, $0023, $00A4, $0025, $0026, $0027, $0028, $0029, $002A, $002B, $002C, $002D, $002E, $002F,
    $0030, $0031, $0032, $0033, $0034, $0035, $0036, $0037, $0038, $0039, $003A, $003B, $003C, $003D, $003E, $003F,
    $00A1, $0041, $0042, $0043, $0044, $0045, $0046, $0047, $0048, $0049, $004A, $004B, $004C, $004D, $004E, $004F,
    $0050, $0051, $0052, $0053, $0054, $0055, $0056, $0057, $0058, $0059, $005A, $00C4, $00D6, $00D1, $00DC, $00A7,
    $00BF, $0061, $0062, $0063, $0064, $0065, $0066, $0067, $0068, $0069, $006A, $006B, $006C, $006D, $006E, $006F,
    $0070, $0071, $0072, $0073, $0074, $0075, $0076, $0077, $0078, $0079, $007A, $00E4, $00F6, $00F1, $00FC, $00E0
  );

function HexToBytes(const S: string): TBytes;
  function HexVal(C: Char): Byte;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      else Result := 0;
    end;
  end;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  SetLength(Result, Length(S) div 2);
  i := 1;
  while i < Length(S) do
  begin
    if not (S[i] in ['0'..'9','A'..'F','a'..'f']) or
       not (S[i+1] in ['0'..'9','A'..'F','a'..'f']) then
    begin
      Inc(i);
      Continue;
    end;
    Result[n] := (HexVal(S[i]) shl 4) or HexVal(S[i+1]);
    Inc(n);
    Inc(i, 2);
  end;
  SetLength(Result, n);
end;

function DecodeUCS2(const Data: TBytes): AnsiString;
var
  i, N: Integer;
  U: UnicodeString;
begin
  N := Length(Data) div 2;
  SetLength(U, N);
  for i := 0 to N - 1 do
    U[i+1] := WideChar((Word(Data[i*2]) shl 8) or Word(Data[i*2+1]));
  Result := UTF8Encode(U);
end;

function DecodeGSM7(const compressed: TBytes; NumSeptets: Integer): AnsiString;
var
  i, bit, byteIdx, bitInByte, septet: Integer;
  U: UnicodeString;
begin
  if NumSeptets <= 0 then Exit('');
  SetLength(U, NumSeptets);
  for i := 0 to NumSeptets - 1 do
  begin
    bit := i * 7;
    byteIdx := bit div 8;
    bitInByte := bit mod 8;
    if byteIdx >= Length(compressed) then
    begin
      SetLength(U, i);
      Break;
    end;
    septet := compressed[byteIdx] shr bitInByte;
    if (bitInByte > 1) and (byteIdx + 1 < Length(compressed)) then
      septet := septet or (compressed[byteIdx + 1] shl (8 - bitInByte));
    septet := septet and $7F;
    U[i+1] := WideChar(GSM7_CODEPOINTS[septet]);
  end;
  Result := UTF8Encode(U);
end;

function DecodeSMSDeliverPDU(const PDU: TBytes; out Body: AnsiString): Boolean;
var
  FirstOctet, AddrBytes, Ptr, TpDcs, Udl: Integer;
  Ud: TBytes;
begin
  Result := False;
  Body := '';
  if Length(PDU) < 4 then Exit;
  FirstOctet := PDU[0];
  if (FirstOctet and $03) <> 0 then Exit;  // not SMS-DELIVER

  AddrBytes := (PDU[1] + 1) div 2;
  Ptr := 3 + AddrBytes;
  if Length(PDU) < Ptr + 10 then Exit;

  TpDcs := PDU[Ptr + 1];
  Udl   := PDU[Ptr + 9];

  SetLength(Ud, Length(PDU) - (Ptr + 10));
  if Length(Ud) > 0 then
    Move(PDU[Ptr + 10], Ud[0], Length(Ud));

  if (TpDcs and $08) <> 0 then
  begin
    if Udl > 0 then
      Body := DecodeUCS2(Copy(Ud, 0, Udl * 2))
    else
      Body := DecodeUCS2(Ud);
  end
  else
  begin
    if Udl > 0 then
      Body := DecodeGSM7(Ud, Udl)
    else
      Body := DecodeGSM7(Ud, (Length(Ud) * 8) div 7);
  end;
  Result := True;
end;

{ ================= D-Bus SMS listener ================= }

function QueryEventDetails(eventId: Integer;
  out sender, channel, body: AnsiString; out outgoing: Boolean): Boolean;
const
  SEP = #31;   // ASCII unit separator — won't appear in real text
var
  outStr: string;
  parts: TStringArray;
begin
  Result := False;
  sender := ''; channel := ''; body := ''; outgoing := False;

  if not RunCapture('sqlite3',
       ['-separator', SEP, ContactsDbFile,
        Format('SELECT COALESCE(remote_uid,''''), ' +
               'COALESCE(channel,''''), ' +
               'COALESCE(free_text,''''), ' +
               'COALESCE(outgoing,0) ' +
               'FROM Events WHERE id=%d', [eventId])], outStr) then
    Exit;

  // Strip only the trailing newline(s) that sqlite3 appends
  if (Length(outStr) > 0) and (outStr[Length(outStr)] = #10) then
    Delete(outStr, Length(outStr), 1);
  if (Length(outStr) > 0) and (outStr[Length(outStr)] = #13) then
    Delete(outStr, Length(outStr), 1);

  if outStr = '' then Exit;

  parts := outStr.Split([SEP]);
  if Length(parts) < 4 then Exit;

  sender   := parts[0];
  channel  := parts[1];
  body     := parts[2];
  outgoing := (Trim(parts[3]) = '1') or (LowerCase(Trim(parts[3])) = 'true');
  Result := True;
end;

function DbusThreadFunc(Param: Pointer): PtrInt;
var
  pipeFds: array[0..1] of cint;
  childPid: TPid;
  buf: array[0..2047] of Char;
  n, i, status: Integer;
  partial, line, t: string;
  inSignal: Boolean;
  eventId: Integer;
  argStrings: array[0..7] of string;
  argCount: Integer;
  lastNotifiedId: Integer;
  channel, sender, body: AnsiString;
  contact: AnsiString;
  outgoing: Boolean;
  argv: array[0..4] of PChar;
  lastQueryId: Integer;

  procedure DispatchEvent;
  var
    retries: Integer;
    ok: Boolean;
  begin
    if not inSignal then Exit;
    inSignal := False;
    if eventId <= lastNotifiedId then Exit;
    if eventId <= 0 then Exit;

    // Retry: on `NewEvent` the DB write may not have committed yet.
    ok := False;
    for retries := 1 to 5 do
    begin
      if QueryEventDetails(eventId, sender, channel, body, outgoing) then
      begin
        if outgoing then
        begin
          lastNotifiedId := eventId;
          Exit;
        end;
        if body <> '' then
        begin
          ok := True;
          Break;
        end;
      end;
      Sleep(100);
    end;

    if not ok then
    begin
      if g_print_maemo then
        WriteLn('[dbus] event ', eventId, ' no body after retries, skipped');
      Exit;   // leave lastNotifiedId alone so a future EventUpdated retries
    end;

    if g_print_maemo then
      WriteLn('[dbus] event ', eventId, ' from "', sender,
              '" channel="', channel, '" bodylen=', Length(body));

    contact := LookupContact(sender);
    WriteLn('Message from ', contact, ' [', channel, ']: ', body);
    try
      NotificationSMS(contact, body);
      lastNotifiedId := eventId;
    except
      on E: Exception do WriteLn('notify error: ', E.Message);
    end;
  end;


  procedure ProcessLine(const L: string);
  var
    j: Integer;
  begin
    if g_print_maemo then
      WriteLn('[raw] ', L);

    if Pos('signal', L) = 1 then
    begin
      DispatchEvent;
      if (Pos('member=NewEvent', L) > 0) or
         (Pos('member=EventUpdated', L) > 0) then
      begin
        inSignal := True;
        eventId  := 0;
        argCount := 0;
        for j := 0 to 7 do argStrings[j] := '';
      end
      else
        inSignal := False;
      Exit;
    end;

    if not inSignal then Exit;
    t := Trim(L);

    if Pos('int32 ', t) = 1 then
    begin
      eventId := StrToIntDef(Trim(Copy(t, 7, Length(t))), 0);
      Exit;
    end;

    if Pos('string "', t) = 1 then
    begin
      t := Copy(t, 9, Length(t) - 8);
      if (Length(t) > 0) and (t[Length(t)] = '"') then
        Delete(t, Length(t), 1);
      if argCount < 8 then argStrings[argCount] := t;
      Inc(argCount);
      Exit;
    end;
  end;

begin
  Result := 0;
  lastNotifiedId := g_initial_watermark;
  lastQueryId    := -1;
  if g_print_maemo then
    WriteLn('D-Bus thread: watermark = ', lastNotifiedId);

  if fpPipe(pipeFds) <> 0 then Exit;
  childPid := fpFork;
  if childPid = 0 then
  begin
    fpClose(pipeFds[0]);
    fpDup2(pipeFds[1], 1);
    fpClose(pipeFds[1]);
    argv[0] := 'dbus-monitor';
    argv[1] := '--session';
    argv[2] := 'type=''signal'',interface=''rtcomeventlogger.signal''';
    argv[3] := nil;
    fpExecv('/usr/bin/dbus-monitor', @argv);
    fpExit(127);
  end;
  fpClose(pipeFds[1]);
  if g_print_maemo then
    WriteLn('dbus-monitor spawned, pid=', childPid);

  inSignal := False;
  eventId  := 0;
  argCount := 0;
  partial  := '';
  while True do
  begin
    n := fpRead(pipeFds[0], buf[0], SizeOf(buf));
    if n <= 0 then Break;
    partial := partial + Copy(buf, 1, n);
    while True do
    begin
      i := Pos(#10, partial);
      if i = 0 then Break;
      line := Copy(partial, 1, i - 1);
      Delete(partial, 1, i);
      ProcessLine(line);
    end;
  end;
  if g_print_maemo then
    WriteLn('dbus-monitor pipe closed');

  DispatchEvent;
  fpClose(pipeFds[0]);
  fpWaitPid(childPid, status, 0);
end;

{ ================= notification v3 ================= }

procedure ZeroUUID(out U: TUUID);
begin FillChar(U, 16, 0); end;

procedure RandomUUID(out U: TUUID);
var i: Integer;
begin
  for i := 0 to 15 do U[i] := Random(256);
  U[6] := (U[6] and $0F) or $40;
  U[8] := (U[8] and $3F) or $80;
end;

procedure NotificationV3(source: Byte; const sender, subject, data, ts: AnsiString);
var
  senderBytes, subjectBytes, dataBytes: TBytes;
  itemId, parentId: TUUID;
  attributes, actions, item, blob: TBytes;
  count, token, totalLen: Integer;
  unixTs: Cardinal;
  i: Integer;
begin
  RandomUUID(itemId);
  ZeroUUID(parentId);
  unixTs := Cardinal(StrToQWordDef(ts, 0)) div 1000;

  // Attribute 0x01: sender (length LE, content)
  senderBytes := BytesOfTrunc(sender, 64);
  count := 1;
  attributes := Cat(Bytes([$01]), Cat(PackU16LE(Length(senderBytes)), senderBytes));

  // Attribute 0x04: source (type=04, len=0004 LE, value=source+3 zeros)
  attributes := Cat(attributes, Bytes([$04, $04, $00, source, $00, $00, $00]));
  Inc(count);

  // Attribute 0x03: data/body (length LE, content)
  if Length(data) > 0 then
  begin
    dataBytes := BytesOfTrunc(data, 512);
    attributes := Cat(attributes,
                   Cat(Bytes([$03]),
                       Cat(PackU16LE(Length(dataBytes)), dataBytes)));
    Inc(count);
  end;

  // Attribute 0x02: subject (length LE, content)
  if Length(subject) > 0 then
  begin
    subjectBytes := BytesOfTrunc(subject, 64);
    attributes := Cat(attributes,
                   Cat(Bytes([$02]),
                       Cat(PackU16LE(Length(subjectBytes)), subjectBytes)));
    Inc(count);
  end;

  // Actions: <BBBBH(7)> + "Dismiss" = 00 04 01 01 07 00 | 44 69 73 6d 69 73 73
  actions := Cat(Bytes([$00, $04, $01, $01, $07, $00]), BytesOf('Dismiss'));

  totalLen := Length(attributes) + Length(actions);

  // Item = item_id(16) + parent_id(16) + ts(4 LE) + 00 00 01 00 00 01 + ...
  item := Cat(itemId, parentId);
  item := Cat(item, PackU32LE(unixTs));
  item := Cat(item, Bytes([$00, $00, $01, $00, $00, $01]));
  // length(2 LE) + count(1) + 01(1) + attributes + actions
  item := Cat(item, PackU16LE(totalLen));
  item := Cat(item, Bytes([count, $01]));
  item := Cat(item, attributes);
  item := Cat(item, actions);

  // Blob = 01 + token(2 LE) + 04 + 10 + item_id(16) + len(item)(2 LE) + item
  token := Random(65536);
  blob := Bytes([$01]);
  blob := Cat(blob, PackU16LE(token));
  blob := Cat(blob, Bytes([$04, $10]));
  blob := Cat(blob, itemId);
  blob := Cat(blob, PackU16LE(Length(item)));
  blob := Cat(blob, item);
  if g_print_maemo then
  begin
    Write('BLOB: ');
    for i := 0 to High(blob) do
      Write(IntToHex(blob[i], 2), ' ');
    WriteLn;
  end;

  Send(ENDPOINT_BLOB, blob);
end;

{ ================= public notification API ================= }

procedure NotificationSMS(const sender, body: AnsiString);
var ts: QWord;
begin
  ts := QWord(GetLocalTimeUnix) * 1000;
  if g_watch_version < 'v3' then
    Send(ENDPOINT_NOTIFICATION,
         PackMessageData(1, [sender, body, IntToStr(ts)]))
  else
    NotificationV3(NOTIF_SOURCE_SMS, sender, body, '', IntToStr(ts));
end;

procedure NotificationEmail(const sender, subject, body: AnsiString);
var ts: QWord;
begin
  ts := QWord(GetLocalTimeUnix) * 1000;
  if g_watch_version < 'v3' then
    Send(ENDPOINT_NOTIFICATION,
         PackMessageData(0, [sender, body, IntToStr(ts), subject]))
  else
    NotificationV3(NOTIF_SOURCE_EMAIL, sender, subject, body, IntToStr(ts));
end;

{ ================= music metadata ================= }

procedure SetNowPlayingMetadata(const track, album, artist: AnsiString);
var
  parts: array[0..2] of AnsiString;
  msg: TBytes;
begin
  parts[0] := Copy(artist, 1, 30);
  parts[1] := Copy(album,  1, 30);
  parts[2] := Copy(track,  1, 30);
  msg := Cat(PackMessageData(16, parts), Bytes([0,0,0,0,0,0,0,0]));
  Send(ENDPOINT_MUSIC_CONTROL, msg);
end;

{ ================= media (OSCP + dbus-send) ================= }

function MediaStatusOSCP(out track: AnsiString): Boolean;
var
  f: Text;
  s: string;
begin
  track := '';
  AssignFile(f, OSCP_NOW_PLAYING);
  {$I-} Reset(f); {$I+}
  if IOResult <> 0 then Exit(False);
  try
    ReadLn(f, s);
    track := s;
  finally
    CloseFile(f);
  end;
  Result := True;
end;

procedure MediaStatus(out status: Integer; out artist, album, track: AnsiString);
var
  outStr, tmp: string;
  lines: TStringList;
  parts: TStringArray;
begin
  status := MEDIA_STATUS_STOPPED;
  artist := 'Unknown';
  album  := 'Unknown';
  track  := 'Unknown';

  if g_use_oscp then
  begin
    if MediaStatusOSCP(track) then
      status := MEDIA_STATUS_PLAYING;
    Exit;
  end;

  if not RunCapture('dbus-send',
       ['--print-reply=literal',
        '--dest=' + DBUS_MAFW_DEST,
        DBUS_MAFW_PATH,
        DBUS_MAFW_IFACE + '.get_status'], outStr) then
    Exit;
  if outStr = '' then Exit;

  lines := TStringList.Create;
  try
    lines.Text := outStr;
    if lines.Count < 4 then Exit;
    tmp := StringReplace(lines[2], 'int32', '', [rfReplaceAll]);
    tmp := StringReplace(tmp, ' ', '', [rfReplaceAll]);
    status := StrToIntDef(tmp, MEDIA_STATUS_STOPPED);
    tmp := StringReplace(lines[3], ' ', '%20', [rfReplaceAll]);
    tmp := StringReplace(tmp, #10, '', [rfReplaceAll]);
    tmp := StringReplace(tmp, '%20', ' ', [rfReplaceAll]);
    tmp := StringReplace(tmp, '%2F', '/', [rfReplaceAll]);
    parts := tmp.Split(['/']);
    if Length(parts) >= 3 then
    begin
      artist := parts[High(parts)-2];
      album  := parts[High(parts)-1];
      track  := parts[High(parts)];
    end;
  finally
    lines.Free;
  end;
end;

procedure MediaPrevious;
begin
  if g_use_oscp then
  begin
    fpSystem(PChar('echo PREV > ' + OSCP_SLAVE));
    Sleep(1000);
  end
  else
    fpSystem(PChar('dbus-send --dest=' + DBUS_MAFW_DEST + ' ' +
                   DBUS_MAFW_PATH + ' ' +
                   DBUS_MAFW_IFACE + '.previous'));
end;

procedure MediaNext;
begin
  if g_use_oscp then
  begin
    fpSystem(PChar('echo NEXT > ' + OSCP_SLAVE));
    Sleep(1000);
  end
  else
    fpSystem(PChar('dbus-send --dest=' + DBUS_MAFW_DEST + ' ' +
                   DBUS_MAFW_PATH + ' ' +
                   DBUS_MAFW_IFACE + '.next'));
end;

procedure MediaPlayPause;
var
  status: Integer;
  artist, album, track: AnsiString;
begin
  if g_use_oscp then
  begin
    fpSystem(PChar('echo PAUSE > ' + OSCP_SLAVE));
    Exit;
  end;

  MediaStatus(status, artist, album, track);
  case status of
    MEDIA_STATUS_PLAYING:
      fpSystem(PChar('dbus-send --dest=' + DBUS_MAFW_DEST + ' ' +
                     DBUS_MAFW_PATH + ' ' +
                     DBUS_MAFW_IFACE + '.pause'));
    MEDIA_STATUS_PAUSED:
      fpSystem(PChar('dbus-send --dest=' + DBUS_MAFW_DEST + ' ' +
                     DBUS_MAFW_PATH + ' ' +
                     DBUS_MAFW_IFACE + '.resume'));
    else
      fpSystem(PChar('dbus-send --dest=' + DBUS_MAFW_DEST + ' ' +
                     DBUS_MAFW_PATH + ' ' +
                     DBUS_MAFW_IFACE + '.play'));
  end;
end;

{ ================= endpoint handlers ================= }

function HandlePing(endpoint: Word; const data: TBytes; s: cint): TBytes;
var cookie: Cardinal;
begin
  if Length(data) >= 5 then
    cookie := UnpackU32BE(data, 1)
  else
    cookie := 0;
  if g_print_maemo then
    WriteLn(Format('PING received, cookie=$%.8x', [cookie]));
  //BtSendAll(s, BuildMessage(ENDPOINT_PING, data));
  Result := data;
end;

function HandlePhoneVersion(endpoint: Word; const data: TBytes; s: cint): TBytes;
var
  msg: TBytes;
  session, remote: Cardinal;
begin
  if g_print_maemo then
    WriteLn('PHONE_VERSION request received');
  session := $80000000;      // GAMMA_RAY
  remote  := 16 or 32 or 2;  // TELEPHONY | SMS | ANDROID = 50
  msg := Bytes([1]);
  msg := Cat(msg, Bytes([$FF, $FF, $FF, $FF]));  // -1 as signed int32, big-endian
  msg := Cat(msg, PackU32BE(session));
  msg := Cat(msg, PackU32BE(remote));
  BtSendAll(s, BuildMessage(ENDPOINT_PHONE_VERSION, msg));
  Result := data;
end;

function HandleSystemMessage(endpoint: Word; const data: TBytes; s: cint): TBytes;
begin
  if (Length(data) >= 2) and g_print_maemo then
    WriteLn(Format('SYSTEM_MESSAGE: type=$%.2x code=$%.2x', [data[0], data[1]]));
  Result := data;
end;

function HandleVersion(endpoint: Word; const data: TBytes; s: cint): TBytes;
var
  normal_fw, recovery_fw: AnsiString;
begin
  if Length(data) >= 48 + 47 then
  begin
    SetLength(normal_fw, 32);
    Move(data[1 + 4], normal_fw[1], 32);
    SetLength(recovery_fw, 32);
    Move(data[48 + 4], recovery_fw[1], 32);
    normal_fw   := StringReplace(normal_fw,   #0, '', [rfReplaceAll]);
    recovery_fw := StringReplace(recovery_fw, #0, '', [rfReplaceAll]);
    g_watch_version := string(normal_fw);
    WriteLn('watch_version: ', g_watch_version);
    if g_print_maemo then
      WriteLn('recovery_fw: ', recovery_fw);
  end;
  Result := data;
end;

function HandleTime(endpoint: Word; const data: TBytes; s: cint): TBytes;
begin
  if (Length(data) >= 5) and g_print_maemo then
    WriteLn('TIME response: ', UnpackU32BE(data, 1));
  Result := data;
end;

function HandleMusicControl(endpoint: Word; const data: TBytes; s: cint): TBytes;
var
  ev: Byte;
  status: Integer;
  artist, album, track: AnsiString;
begin
  if Length(data) < 1 then Exit(data);
  ev := data[0];
  if g_print_maemo then WriteLn('MUSIC_CONTROL event ', ev);
  case ev of
    1, 2, 3: MediaPlayPause;
    4:       MediaNext;
    5:       MediaPrevious;
    8, 10:
      begin
        MediaStatus(status, artist, album, track);
        SetNowPlayingMetadata(track, album, artist);
      end;
  end;
  Result := data;
end;

{ ================= protocol loop ================= }

function SyncEndpoint(s: cint; endpoint_name: Word; out resp: TBytes): Boolean;
var
  hdr: TBytes;
  size, ep: Word;
  tries: Integer;
begin
  resp := nil;
  for tries := 1 to 10 do
  begin
    if not BtRecvExact(s, hdr, 4) then
    begin
      Sleep(1000);
      Continue;
    end;
    size := UnpackU16BE(hdr, 0);
    ep   := UnpackU16BE(hdr, 2);
    if size > 0 then
    begin
      if not BtRecvExact(s, resp, size) then Continue;
    end
    else
      resp := nil;

    if ep = endpoint_name then Exit(True);

    case ep of
      ENDPOINT_PING:           HandlePing(ep, resp, s);
      ENDPOINT_VERSION:        HandleVersion(ep, resp, s);
      ENDPOINT_PHONE_VERSION:  HandlePhoneVersion(ep, resp, s);
      ENDPOINT_SYSTEM_MESSAGE: HandleSystemMessage(ep, resp, s);
      ENDPOINT_TIME:           HandleTime(ep, resp, s);
      ENDPOINT_MUSIC_CONTROL:  HandleMusicControl(ep, resp, s);
    end;

  end;
  Result := False;
end;

function ProcessOneMessage(s: cint): Boolean;
var
  hdr, data: TBytes;
  size, ep: Word;
begin
  if not BtRecvExact(s, hdr, 4) then Exit(False);
  size := UnpackU16BE(hdr, 0);
  ep   := UnpackU16BE(hdr, 2);
  if size > 0 then
  begin
    if not BtRecvExact(s, data, size) then Exit(False);
  end
  else
    data := nil;

  case ep of
    ENDPOINT_PING:           HandlePing(ep, data, s);
    ENDPOINT_VERSION:        HandleVersion(ep, data, s);
    ENDPOINT_PHONE_VERSION:  HandlePhoneVersion(ep, data, s);
    ENDPOINT_SYSTEM_MESSAGE: HandleSystemMessage(ep, data, s);
    ENDPOINT_TIME:           HandleTime(ep, data, s);
    ENDPOINT_MUSIC_CONTROL:  HandleMusicControl(ep, data, s);
  end;

  Result := True;
end;

function Ping(s: cint): Boolean;
var msg, resp: TBytes;
begin
  msg := BuildMessage(ENDPOINT_PING, Cat(Bytes([0]), PackU32BE($DEC0DE)));
  if not BtSendAll(s, msg) then Exit(False);
  if not SyncEndpoint(s, ENDPOINT_PING, resp) then Exit(False);
  Result := True;
end;

function GetVersions(s: cint): Boolean;
var msg, resp: TBytes;
begin
  msg := BuildMessage(ENDPOINT_VERSION, Bytes([0]));
  if not BtSendAll(s, msg) then Exit(False);
  if not SyncEndpoint(s, ENDPOINT_VERSION, resp) then Exit(False);
  if resp <> nil then HandleVersion(ENDPOINT_VERSION, resp, s);
  Result := True;
end;

function SetTime(s: cint; unixtime: Cardinal): Boolean;
var msg: TBytes;
begin
  msg := BuildMessage(ENDPOINT_TIME, Cat(Bytes([$02]), PackU32BE(unixtime)));
  Result := BtSendAll(s, msg);
end;

{ ================= main loop ================= }

function GetLocalTimeUnix: Cardinal;
begin
  // Python sends local time "as if it were UTC". DateTimeToUnix(Now)
  // gives exactly that: unix seconds for the local clock reading.
  Result := Cardinal(DateTimeToUnix(Now));
end;

function RunOnce: Boolean;
begin
  Configure;
  g_sock_lock.Enter;
  try
    g_sock := BtConnect(g_bt_address);
  finally
    g_sock_lock.Leave;
  end;
  if g_sock < 0 then
  begin
    WriteLn('Could not connect to ', g_bt_address);
    Exit(False);
  end;

  try
    WriteLn('Connected to ', g_bt_address);
    if not GetVersions(g_sock) then
    begin
      WriteLn('GetVersions failed.');
      Exit(False);
    end;
    WriteLn('Connected, watch version: ', g_watch_version);

    SetTime(g_sock, GetLocalTimeUnix);

    // SMOKE TEST — comment this out once you've seen it on the watch
    // NotificationSMS('Pascal', 'Hello from maebble.pas');


    while True do
    begin
      if not ProcessOneMessage(g_sock) then
        Break;
    end;
    Result := True;
  finally
    g_sock_lock.Enter;
    try
      if g_sock >= 0 then
      begin
        CloseSocket(g_sock);
        g_sock := -1;
      end;
    finally
      g_sock_lock.Leave;
    end;
  end;
end;

procedure Main;
var
  dbusTid: TThreadID;
  i: Integer;
begin
  Randomize;
  g_print_maemo := False;

  { Flag pre-scan — everything that doesn't need a BT connection }
  for i := 1 to ParamCount do
    case ParamStr(i) of
      '-h', '--help':
        begin
          ShowHelp;
          Halt(0);
        end;
      '--version':
        begin
          WriteLn('maebbled ', MAEBBLE_VERSION);
          Halt(0);
        end;
      '-v', '--verbose', '--print_maemo':
        g_print_maemo := True;
    end;

  // One-shot notification test mode:
  //   ./maebbled --test-sms "sender" "body"
  //   ./maebbled --test-email "sender" "subject" "body"
  if (ParamCount >= 2) and (ParamStr(1) = '--test-sms') then
  begin
    Configure;
    g_sock := BtConnect(g_bt_address);
    if g_sock < 0 then
    begin
      WriteLn('Could not connect');
      Halt(1);
    end;
    try
      //Ping(g_sock);
      GetVersions(g_sock);   // needed so g_watch_version is set
      SetTime(g_sock, GetLocalTimeUnix);
      if ParamCount >= 3 then
        NotificationSMS(ParamStr(2), ParamStr(3))
      else
        NotificationSMS('Pascal', 'Test notification');
      WriteLn('Notification sent.');
      Sleep(2000);           // let the BT stack flush
    finally
      CloseSocket(g_sock);
      g_sock := -1;
    end;
    Halt(0);
  end;

 if (ParamCount >= 2) and (ParamStr(1) = '--test-email') then
  begin
    Configure;
    g_sock := BtConnect(g_bt_address);
    if g_sock < 0 then
    begin
      WriteLn('Could not connect');
      Halt(1);
    end;
    try
      GetVersions(g_sock);
      SetTime(g_sock, GetLocalTimeUnix);
      if ParamCount >= 5 then
        NotificationEmail(ParamStr(2), ParamStr(3), ParamStr(4))
      else
        NotificationEmail('Pascal', 'Test subject', 'Test body');
      WriteLn('Email notification sent.');
      Sleep(2000);
    finally
      CloseSocket(g_sock);
      g_sock := -1;
    end;
    Halt(0);
  end;

  g_initial_watermark := QueryMaxEventId;
  if g_print_maemo then
    WriteLn('Initial watermark: ', g_initial_watermark);

  { Daemon mode }
  BeginThread(@DbusThreadFunc, nil, dbusTid);

  while True do
  begin
    try
      if not RunOnce then
        Sleep(g_connect_sleep * 1000);
    except
      on E: Exception do
      begin
        WriteLn('Exception: ', E.Message);
        Sleep(g_connect_sleep * 1000);
      end;
    end;
  end;
end;

initialization
  g_sock_lock := TCriticalSection.Create;
finalization
  g_sock_lock.Free;
end.
