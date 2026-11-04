unit wtr;

{$mode objfpc}{$H+}
{$linklib bluetooth}

interface

uses
  SysUtils, Classes, ctypes, bluetooth;

const
  WTR_VERSION = '0.1.0';
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
  Sockets, Unix, BaseUnix, IniFiles, DateUtils, Types, SyncObjs, Process,
  notification_filters, event_scanner, database_watch, mail_cache, pebble_protocol,
  wtr_config;

type
  TBytes = TPebbleBytes;
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
  g_ready: Boolean = False;
  g_scan_fallback_seconds: Integer = 30;
  g_filters: TNotificationFilters;
  g_scanner: TEventScanner;
  g_database_watch: TDatabaseWatch;
  g_email_enabled: Boolean = True;
  g_mail_fallback_seconds: Integer = 300;
  g_mail_cache_root: string;
  g_mail_cache: TMailCache;

procedure ShowHelp;
begin
  WriteLn('wtrd ', WTR_VERSION);
  WriteLn('Watch the Ripple - Pebble companion daemon for Maemo Leste');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  wtrd [OPTIONS]');
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
  WriteLn('  ', ConfigFilePath);
  WriteLn('  (legacy fallback: ', LegacyConfigFilePath, ')');
  WriteLn('  (local fallbacks: ./wtr.conf, ./maebble.cfg)');
  WriteLn;
  WriteLn('With no options, connects to the Pebble configured in wtr.conf,');
  WriteLn('sends the VERSION/TIME handshake, then watches the event database');
  WriteLn('for incoming messages and the Modest IMAP inbox cache for email.');
  WriteLn('Notifications are relayed until killed (Ctrl+C).');
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

function DefaultMailCacheRoot: string;
var Home: string;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then Home := '/home/user';
  Result := Home + '/.modest/cache/mail/imap';
end;

procedure Configure;
var
  cfg: TIniFile;
  cfgPath: string;
begin
  g_mail_cache_root := DefaultMailCacheRoot;
  cfgPath := FindConfigFile;
  if cfgPath = '' then
  begin
    WriteLn('No config file found (looked in ', ConfigFilePath, ', ',
      LegacyConfigFilePath, ', ./wtr.conf and ./maebble.cfg)');
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
    g_scan_fallback_seconds := cfg.ReadInteger('notifications', 'fallback_seconds', 30);
    if (g_scan_fallback_seconds < 1) or (g_scan_fallback_seconds > 86400) then
      raise Exception.Create('notifications.fallback_seconds must be 1..86400');
    if (g_connect_sleep < 1) or (g_connect_sleep > 86400) then
      raise Exception.Create('btservice.connect_sleep must be 1..86400');
    g_filters.Load(cfg);
    g_email_enabled := cfg.ReadBool('email', 'enabled', True);
    g_mail_cache_root := cfg.ReadString('email', 'cache_directory', DefaultMailCacheRoot);
    g_mail_fallback_seconds := cfg.ReadInteger('email', 'fallback_seconds', 300);
    if (g_mail_fallback_seconds < 1) or (g_mail_fallback_seconds > 86400) then
      raise Exception.Create('email.fallback_seconds must be 1..86400');
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
    WriteLn('email:         ', g_email_enabled);
    if g_email_enabled then WriteLn('email cache:   ', g_mail_cache_root);
  end;
end;

{ ================= Bluetooth transport ================= }

function SetSocketTimeout(s, Option, Seconds: cint): Boolean;
var
  Timeout: TTimeVal;
  ErrorCode: cint;
begin
  FillChar(Timeout, SizeOf(Timeout), 0);
  Timeout.tv_sec := Seconds;
  Result := fpSetSockOpt(s, SOL_SOCKET, Option, @Timeout, SizeOf(Timeout)) = 0;
  if not Result then
  begin
    ErrorCode := fpGetErrno;
    if g_print_maemo then
      WriteLn('Setting Bluetooth socket timeout failed: ', ErrorCode,
        ' (', SysErrorMessage(ErrorCode), ')');
  end;
end;

function BtConnect(const addr: string): cint;
var
  s: cint;
  ErrorCode: cint;
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
    ErrorCode := fpGetErrno;
    if g_print_maemo then
      WriteLn('fpConnect failed: ', ErrorCode, ' (', SysErrorMessage(ErrorCode), ')');
    CloseSocket(s);
    Exit(-1);
  end;

  // Bound blocked writes so a stalled peer cannot hold the notification lock forever.
  if not SetSocketTimeout(s, SO_SNDTIMEO, 15) then
  begin
    CloseSocket(s);
    Exit(-1);
  end;
  Result := s;
end;

function BtSendAll(s: cint; const buf: TBytes): Boolean;
var sent, n, ErrorCode: Integer;
begin
  sent := 0;
  while sent < Length(buf) do
  begin
    n := fpSend(s, @buf[sent], Length(buf) - sent, MSG_NOSIGNAL);
    if n <= 0 then
    begin
      ErrorCode := fpGetErrno;
      if (n < 0) and (ErrorCode = ESysEINTR) then Continue;
      if g_print_maemo then
      begin
        if n = 0 then WriteLn('Bluetooth send made no progress')
        else WriteLn('Bluetooth send failed: ', ErrorCode, ' (', SysErrorMessage(ErrorCode), ')');
        WriteLn('Bluetooth write stopped after ', sent, '/', Length(buf), ' bytes');
      end;
      Exit(False);
    end;
    Inc(sent, n);
  end;
  Result := True;
end;

function BtRecvExact(s: cint; var buf: TBytes; count: Integer): Boolean;
var got, n, ErrorCode: Integer;
begin
  SetLength(buf, count);
  got := 0;
  while got < count do
  begin
    n := fpRecv(s, @buf[got], count - got, 0);
    if n <= 0 then
    begin
      ErrorCode := fpGetErrno;
      if (n < 0) and (ErrorCode = ESysEINTR) then Continue;
      if g_print_maemo then
      begin
        if n = 0 then WriteLn('Bluetooth receive: end of stream (connection closed)')
        else WriteLn('Bluetooth receive failed: ', ErrorCode, ' (', SysErrorMessage(ErrorCode), ')');
        WriteLn('Bluetooth read stopped after ', got, '/', count, ' bytes');
      end;
      Exit(False);
    end;
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
    if g_sock < 0 then raise Exception.Create('Watch is disconnected');
    msg := BuildMessage(endpoint, payload);
    if not BtSendAll(g_sock, msg) then
    begin
      g_ready := False;
      fpShutdown(g_sock, 2);
      raise Exception.Create('Bluetooth send failed');
    end;
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

{ ================= event database listener ================= }

function HandleMessageEvent(const Event: TMessageEvent): Boolean;
var
  RuleIndex: Integer;
begin
  Result := False;
  g_sock_lock.Enter;
  try
    if not g_ready then Exit;
    if not g_filters.ShouldShow(Event.Sender, Event.Channel, Event.Body, RuleIndex) then
    begin
      if g_print_maemo then WriteLn('Filtered event ', Event.Id, ' from ', Event.Sender);
      Exit(True);
    end;
    NotificationSMS(Event.Contact, Event.Body);
    g_filters.MarkShown(RuleIndex, Event.Sender, Event.Channel);
    if g_print_maemo then
      WriteLn('Message from ', Event.Contact, ' [', Event.Channel, ']: ', Event.Body);
    Result := True;
  finally
    g_sock_lock.Leave;
  end;
end;

function ScannerThreadFunc(Param: Pointer): PtrInt;
var
  Ready: Boolean;
  Count: Integer;
begin
  Result := 0;
  if g_print_maemo then
    WriteLn('Scanner: inotify watch=', g_database_watch.Active,
      ', fallback=', g_scan_fallback_seconds, 's');
  while True do
  begin
    g_sock_lock.Enter;
    try
      Ready := g_ready;
    finally
      g_sock_lock.Leave;
    end;
    if not Ready then
    begin
      // Connection completion wakes this without polling while offline.
      g_database_watch.Wait(g_scan_fallback_seconds * 1000);
      Continue;
    end;
    Count := 0;
    try
      Count := g_scanner.Scan(@HandleMessageEvent);
    except
      on E: Exception do WriteLn('scan error: ', E.Message);
    end;
    if Count = EVENT_BATCH_SIZE then Continue;
    g_database_watch.Wait(g_scan_fallback_seconds * 1000);
  end;
end;

function HandleMailEvent(const Event: TMailEvent): Boolean;
var
  RuleIndex: Integer;
  Channel: string;
begin
  Result := False;
  Channel := 'email:' + Event.Account;
  g_sock_lock.Enter;
  try
    if not g_ready then Exit;
    // Cached email notifications show headers only, so text filters match the subject.
    if not g_filters.ShouldShow(Event.Sender, Channel, Event.Subject, RuleIndex) then
    begin
      if g_print_maemo then WriteLn('Filtered email UID ', Event.UID, ' [', Event.Account, ']');
      Exit(True);
    end;
    NotificationEmail(Event.DisplaySender, Event.Subject, '');
    g_filters.MarkShown(RuleIndex, Event.Sender, Channel);
    if g_print_maemo then
      WriteLn('Email from ', Event.DisplaySender, ' [', Event.Account, ']: ', Event.Subject);
    Result := True;
  finally
    g_sock_lock.Leave;
  end;
end;

function MailThreadFunc(Param: Pointer): PtrInt;
var
  Ready: Boolean;
  Count: Integer;
begin
  Result := 0;
  if g_print_maemo then
    WriteLn('Email scanner: inotify watch=', g_mail_cache.Watch.Active,
      ', inboxes=', g_mail_cache.MailboxCount,
      ', fallback=', g_mail_fallback_seconds, 's');
  while True do
  begin
    g_sock_lock.Enter;
    try
      Ready := g_ready;
    finally
      g_sock_lock.Leave;
    end;
    Count := 0;
    if Ready then
    try
      Count := g_mail_cache.Scan(@HandleMailEvent);
    except
      on E: Exception do WriteLn('email scan error: ', E.Message);
    end;
    if Count = MAIL_BATCH_SIZE then Continue;
    g_mail_cache.Wait(g_mail_fallback_seconds * 1000);
  end;
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
  unixTs := Cardinal(StrToQWordDef(ts, 0) div 1000);

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
var
  cookie: Cardinal;
  reply: TBytes;
begin
  Result := data;
  if Length(data) < 5 then
  begin
    if g_print_maemo then WriteLn('Ignoring short PING packet: ', Length(data), ' bytes');
    Exit;
  end;
  cookie := UnpackU32BE(data, 1);
  if g_print_maemo then
    WriteLn(Format('PING endpoint: command=%d, cookie=$%.8x', [data[0], cookie]));
  reply := PongForPing(data);
  if reply <> nil then
  begin
    Send(ENDPOINT_PING, reply);
    if g_print_maemo then WriteLn('PONG sent');
  end;
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
  Send(ENDPOINT_PHONE_VERSION, msg);
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
      Exit(False);
    size := UnpackU16BE(hdr, 0);
    ep   := UnpackU16BE(hdr, 2);
    if size > 0 then
    begin
      if not BtRecvExact(s, resp, size) then Exit(False);
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
  Result := False;
  if not SetSocketTimeout(s, SO_RCVTIMEO, 15) then Exit;
  try
    msg := BuildMessage(ENDPOINT_VERSION, Bytes([0]));
    if not BtSendAll(s, msg) then Exit;
    if not SyncEndpoint(s, ENDPOINT_VERSION, resp) then Exit;
    if (Length(resp) < 95) or (resp[0] <> 1) then
    begin
      if g_print_maemo then WriteLn('Invalid VERSION response: ', Length(resp), ' bytes');
      Exit;
    end;
    HandleVersion(ENDPOINT_VERSION, resp, s);
    Result := True;
  finally
    // Idle established connections must keep sleeping without a receive timeout.
    if not SetSocketTimeout(s, SO_RCVTIMEO, 0) then Result := False;
  end;
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

    if not SetTime(g_sock, GetLocalTimeUnix) then Exit(False);

    g_sock_lock.Enter;
    try
      g_ready := True;
    finally
      g_sock_lock.Leave;
    end;
    g_database_watch.Wake;
    if g_mail_cache <> nil then g_mail_cache.Wake;

    while True do
    begin
      if not ProcessOneMessage(g_sock) then
      begin
        WriteLn('Watch connection lost; retrying in ', g_connect_sleep, ' seconds');
        Break;
      end;
    end;
    Result := True;
  finally
    g_sock_lock.Enter;
    try
      g_ready := False;
      if g_sock >= 0 then
      begin
        fpShutdown(g_sock, 2);
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
  scannerTid, mailTid: TThreadID;
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
          WriteLn('wtrd ', WTR_VERSION);
          Halt(0);
        end;
      '-v', '--verbose', '--print_maemo':
        g_print_maemo := True;
    end;

  // One-shot notification test mode:
  //   ./wtrd --test-sms "sender" "body"
  //   ./wtrd --test-email "sender" "subject" "body"
  Configure;

  if (ParamCount >= 2) and (ParamStr(1) = '--test-sms') then
  begin
    g_sock := BtConnect(g_bt_address);
    if g_sock < 0 then
    begin
      WriteLn('Could not connect');
      Halt(1);
    end;
    try
      //Ping(g_sock);
      if not GetVersions(g_sock) then raise Exception.Create('GetVersions failed');
      if not SetTime(g_sock, GetLocalTimeUnix) then raise Exception.Create('SetTime failed');
      if ParamCount >= 3 then
        NotificationSMS(ParamStr(2), ParamStr(3))
      else
        NotificationSMS('Pascal', 'Test notification');
      WriteLn('Notification sent.');
      Sleep(2000);           // let the BT stack flush
    finally
      fpShutdown(g_sock, 2);
      CloseSocket(g_sock);
      g_sock := -1;
    end;
    Halt(0);
  end;

 if (ParamCount >= 2) and (ParamStr(1) = '--test-email') then
  begin
    g_sock := BtConnect(g_bt_address);
    if g_sock < 0 then
    begin
      WriteLn('Could not connect');
      Halt(1);
    end;
    try
      if not GetVersions(g_sock) then raise Exception.Create('GetVersions failed');
      if not SetTime(g_sock, GetLocalTimeUnix) then raise Exception.Create('SetTime failed');
      if ParamCount >= 4 then
        NotificationEmail(ParamStr(2), ParamStr(3), ParamStr(4))
      else
        NotificationEmail('Pascal', 'Test subject', 'Test body');
      WriteLn('Email notification sent.');
      Sleep(2000);
    finally
      fpShutdown(g_sock, 2);
      CloseSocket(g_sock);
      g_sock := -1;
    end;
    Halt(0);
  end;

  g_database_watch := TDatabaseWatch.Create(ContactsDbFile);
  g_scanner := TEventScanner.Create(ContactsDbFile);
  try
    g_scanner.Initialize;
  except
    on E: Exception do WriteLn('Initial database scan failed: ', E.Message);
  end;
  if g_print_maemo then WriteLn('Initial watermark: ', g_scanner.Watermark);

  if g_email_enabled then
  begin
    g_mail_cache := TMailCache.Create(g_mail_cache_root);
    g_mail_cache.Initialize;
  end;

  { Daemon mode }
  if BeginThread(@ScannerThreadFunc, nil, scannerTid) = 0 then
    raise Exception.Create('Could not start scanner thread');
  if g_email_enabled then
    if BeginThread(@MailThreadFunc, nil, mailTid) = 0 then
      raise Exception.Create('Could not start email scanner thread');

  while True do
  begin
    try
      RunOnce;
    except
      on E: Exception do
      begin
        WriteLn('Exception: ', E.Message);
      end;
    end;
    Sleep(g_connect_sleep * 1000);
  end;
end;

initialization
  g_sock_lock := TCriticalSection.Create;
  g_filters := TNotificationFilters.Create;
finalization
  g_filters.Free;
  g_sock_lock.Free;
end.
