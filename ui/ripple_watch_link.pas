unit ripple_watch_link;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, ripple_types;

const
  EP_VERSION = 16;
  EP_APP_MANAGER = 6000;
  EP_APP_FETCH = 6001;
  EP_PUT_BYTES = 48879;
  EP_BLOB_DB = 45531;
  EP_RUN_STATE = 52;

type
  EWatchTimeout = class(Exception);
  EBluetoothConnect = class(Exception)
  private
    FErrorCode: Integer;
  public
    constructor Create(Code: Integer);
    property ErrorCode: Integer read FErrorCode;
  end;
  TWatchLink = class
  public
    procedure Send(Endpoint: Word; const Data: TRippleBytes); virtual; abstract;
    function Wait(Endpoint: Word; TimeoutMS: Integer = 15000): TRippleBytes; virtual; abstract;
    function Identify: TWatchInfo;
  end;
  TWatchConnector = class
  protected
    function ConnectOnce(const Address: string): TWatchLink; virtual;
    procedure RetryDelay; virtual;
  public
    function Connect(const Address: string; Progress: TRippleProgress): TWatchLink;
  end;
  TRFCOMMLink = class(TWatchLink)
  private
    FSocket: LongInt;
    procedure Ready(Writing: Boolean; Deadline: QWord);
    function ReadExact(Count: Integer; Deadline: QWord): TRippleBytes;
  public
    constructor Create(const Address: string);
    destructor Destroy; override;
    procedure Send(Endpoint: Word; const Data: TRippleBytes); override;
    function Wait(Endpoint: Word; TimeoutMS: Integer = 15000): TRippleBytes; override;
  end;

function PlatformForHardware(Hardware: Byte): string;
function ParseWatchInfo(const Data: TRippleBytes): TWatchInfo;
function PhoneVersionReply: TRippleBytes;

implementation

uses Sockets, BaseUnix, Unix, bluetooth, ripple_bytes;

constructor EBluetoothConnect.Create(Code: Integer);
begin
  FErrorCode := Code;
  inherited Create('Bluetooth connection failed: ' + SysErrorMessage(Code));
end;

function TWatchConnector.ConnectOnce(const Address: string): TWatchLink;
begin
  Result := TRFCOMMLink.Create(Address);
end;

procedure TWatchConnector.RetryDelay;
begin
  Sleep(1000);
end;

function TWatchConnector.Connect(const Address: string; Progress: TRippleProgress): TWatchLink;
const MaxAttempts = 8;
var Attempt: Integer;
begin
  for Attempt := 1 to MaxAttempts do
  begin
    try
      Exit(ConnectOnce(Address));
    except
      on E: EBluetoothConnect do
      begin
        if (Attempt = MaxAttempts) or
          ((E.ErrorCode <> ESysEBUSY) and (E.ErrorCode <> ESysEADDRINUSE) and
           (E.ErrorCode <> ESysEALREADY) and (E.ErrorCode <> ESysEAGAIN)) then raise;
        if Assigned(Progress) then Progress(Format(
          'Bluetooth is busy; waiting for connection release (%d/%d)',
          [Attempt, MaxAttempts]), 0);
      end;
    end;
    RetryDelay;
  end;
  Result := nil;
end;

function PlatformForHardware(Hardware: Byte): string;
begin
  case Hardware of
    1..6, 254, 255: Result := 'aplite';
    7, 8, 10, 252, 253: Result := 'basalt';
    9, 11, 251: Result := 'chalk';
    12, 14, 248, 250: Result := 'diorite';
    13, 16..18, 243, 244, 247, 249: Result := 'emery';
    15: Result := 'flint';
    19..21: Result := 'gabbro';
    else Result := '';
  end;
end;

function ParseWatchInfo(const Data: TRippleBytes): TWatchInfo;
var S: string; I: Integer;
begin
  Result := Default(TWatchInfo);
  RequireBytes(Data, 0, 95);
  if Data[0] <> 1 then raise Exception.Create('Invalid watch version response');
  Result.Firmware := FixedText(Data, 5, 32);
  Result.Platform := PlatformForHardware(Data[46]);
  S := Result.Firmware;
  if Copy(S, 1, 1) = 'v' then Delete(S, 1, 1);
  I := Pos('.', S);
  if I > 0 then S := Copy(S, 1, I - 1);
  Result.Major := StrToIntDef(S, 0);
  if Result.Major < 1 then raise Exception.Create('Unknown watch firmware version');
end;

function TWatchLink.Identify: TWatchInfo;
begin
  Send(EP_VERSION, Bytes([0]));
  Result := ParseWatchInfo(Wait(EP_VERSION));
  // Announce app-run-state support before issuing watch app operations.
  Send(17, PhoneVersionReply);
end;

function PhoneVersionReply: TRippleBytes;
begin
  Result := Join(Bytes([1, $FF, $FF, $FF, $FF]), Join(U32BE($80000000), U32BE(50)));
  // The trailing capability word advertises the app-run-state endpoint only.
  Result := Join(Result, Bytes([2, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TRFCOMMLink.Ready(Writing: Boolean; Deadline: QWord);
var FDs: TFDSet; TV: TTimeVal; Remaining: Int64; N: LongInt;
begin
  repeat
    Remaining := Int64(Deadline) - Int64(GetTickCount64);
    if Remaining <= 0 then raise EWatchTimeout.Create('Bluetooth operation timed out');
    fpFD_ZERO(FDs);
    fpFD_SET(FSocket, FDs);
    TV.tv_sec := Remaining div 1000;
    TV.tv_usec := (Remaining mod 1000) * 1000;
    if Writing then N := fpSelect(FSocket + 1, nil, @FDs, nil, @TV)
    else N := fpSelect(FSocket + 1, @FDs, nil, nil, @TV);
    if N > 0 then Exit;
    if N = 0 then raise EWatchTimeout.Create('Bluetooth operation timed out');
  until fpGetErrno <> ESysEINTR;
  raise Exception.Create('Bluetooth socket error: ' + SysErrorMessage(fpGetErrno));
end;

constructor TRFCOMMLink.Create(const Address: string);
var A: sockaddr_rc; I, V, Code, N: LongInt; Size: TSockLen;
begin
  inherited Create;
  FSocket := -1;
  if Length(Address) <> 17 then raise Exception.Create('Set the watch address in wtr.conf');
  FillChar(A, SizeOf(A), 0);
  A.rc_family := AF_BLUETOOTH;
  A.rc_channel := 1;
  for I := 0 to 5 do
  begin
    if (I < 5) and (Address[I * 3 + 3] <> ':') then
      raise Exception.Create('Invalid Bluetooth address');
    if not TryStrToInt('$' + Copy(Address, I * 3 + 1, 2), V) then
      raise Exception.Create('Invalid Bluetooth address');
    A.rc_bdaddr.b[5 - I] := V;
  end;
  FSocket := fpSocket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
  if FSocket < 0 then raise Exception.Create('Cannot create Bluetooth socket');
  if fpFcntl(FSocket, F_SETFL, O_NONBLOCK) < 0 then
    raise Exception.Create('Cannot configure Bluetooth socket');
  N := fpConnect(FSocket, @A, SizeOf(A));
  if N < 0 then
  begin
    Code := fpGetErrno;
    if Code <> ESysEINPROGRESS then
      raise EBluetoothConnect.Create(Code);
    Ready(True, GetTickCount64 + 20000);
    Size := SizeOf(Code);
    if fpGetSockOpt(FSocket, SOL_SOCKET, SO_ERROR, @Code, @Size) <> 0 then
      raise Exception.Create('Cannot read Bluetooth connection status');
    if Code <> 0 then
      raise EBluetoothConnect.Create(Code);
  end;
end;

destructor TRFCOMMLink.Destroy;
begin
  if FSocket >= 0 then CloseSocket(FSocket);
  inherited Destroy;
end;

procedure TRFCOMMLink.Send(Endpoint: Word; const Data: TRippleBytes);
var Packet: TRippleBytes; Sent, N: Integer; Deadline: QWord;
begin
  if Length(Data) > 65535 then raise Exception.Create('Pebble packet too large');
  Packet := Join(Join(U16BE(Length(Data)), U16BE(Endpoint)), Data);
  Deadline := GetTickCount64 + 15000;
  Sent := 0;
  while Sent < Length(Packet) do
  begin
    Ready(True, Deadline);
    N := fpSend(FSocket, @Packet[Sent], Length(Packet) - Sent, MSG_NOSIGNAL);
    if (N < 0) and (fpGetErrno in [ESysEINTR, ESysEAGAIN]) then Continue;
    if N <= 0 then raise Exception.Create('Bluetooth write failed');
    Inc(Sent, N);
  end;
end;

function TRFCOMMLink.ReadExact(Count: Integer; Deadline: QWord): TRippleBytes;
var Got, N: Integer;
begin
  Result := nil;
  SetLength(Result, Count);
  Got := 0;
  while Got < Count do
  begin
    Ready(False, Deadline);
    N := fpRecv(FSocket, @Result[Got], Count - Got, 0);
    if (N < 0) and (fpGetErrno in [ESysEINTR, ESysEAGAIN]) then Continue;
    if N <= 0 then raise Exception.Create('Watch connection closed');
    Inc(Got, N);
  end;
end;

function TRFCOMMLink.Wait(Endpoint: Word; TimeoutMS: Integer): TRippleBytes;
var Header, Data, Reply: TRippleBytes; EP: Word; Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(TimeoutMS);
  repeat
    Header := ReadExact(4, Deadline);
    EP := Read16BE(Header, 2);
    Data := ReadExact(Read16BE(Header, 0), Deadline);
    if EP = Endpoint then Exit(Data);
    if (EP = 2001) and (Length(Data) = 5) and (Data[0] = 0) then
    begin
      Reply := Copy(Data);
      Reply[0] := 1;
      Send(EP, Reply);
    end;
    if EP = 17 then
      Send(17, PhoneVersionReply);
  until False;
end;

end.
