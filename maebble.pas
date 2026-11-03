unit maebble;

{$mode objfpc}{$H+}
{$linklib bluetooth}

interface

uses
  SysUtils, Classes, ctypes, bluetooth;

const
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
  Sockets, Unix, BaseUnix, IniFiles, DateUtils, Types;

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
begin
  if g_sock < 0 then Exit;
  BtSendAll(g_sock, BuildMessage(endpoint, payload));
end;

{ ================= external command helpers ================= }

function RunCapture(const cmd: string; out output: string): Boolean;
var
  f: Text;
  s, tmpFile: string;
begin
  output  := '';
  tmpFile := '/tmp/.maebble.out.' + IntToStr(fpGetPid);
  fpSystem(PChar(cmd + ' > ' + tmpFile + ' 2>/dev/null'));
  Result := False;
  if not FileExists(tmpFile) then Exit;
  AssignFile(f, tmpFile);
  {$I-} Reset(f); {$I+}
  if IOResult <> 0 then
  begin
    DeleteFile(tmpFile);
    Exit;
  end;
  while not EOF(f) do
  begin
    ReadLn(f, s);
    output := output + s + #10;
  end;
  CloseFile(f);
  DeleteFile(tmpFile);
  Result := True;
end;

{ ================= contact lookup (sqlite3 CLI) ================= }

function LookupContact(const number: string): string;
var
  outStr, s: string;
begin
  Result := number;
  if not FileExists(CONTACTS_DB) then Exit;
  s := StringReplace(number, '''', '''''', [rfReplaceAll]);
  if RunCapture('sqlite3 ' + CONTACTS_DB +
                ' "SELECT remote_name FROM remotes WHERE remote_uid=''' + s + '''"',
                outStr) then
  begin
    outStr := Trim(StringReplace(outStr, #10, '', [rfReplaceAll]));
    if outStr <> '' then Result := outStr;
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

  RunCapture('dbus-send --print-reply=literal ' +
             '--dest=' + DBUS_MAFW_DEST + ' ' +
             DBUS_MAFW_PATH + ' ' +
             DBUS_MAFW_IFACE + '.get_status', outStr);
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
  g_sock := BtConnect(g_bt_address);
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
    NotificationSMS('Pascal', 'Hello from maebble.pas');


    while True do
    begin
      if not ProcessOneMessage(g_sock) then
        Break;
    end;
    Result := True;
  finally
    if g_sock >= 0 then
    begin
      CloseSocket(g_sock);
      g_sock := -1;
    end;
  end;
end;

procedure Main;
begin
  Randomize;
  g_print_maemo := (ParamCount >= 1) and (ParamStr(1) = '--print_maemo');

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


end.
