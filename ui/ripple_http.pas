unit ripple_http;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, fphttpclient, ssockets;

type
  TRippleHTTP = class
  private
    FLimit: Int64;
    FDeadline: QWord;
    FClient: TFPHTTPClient;
    procedure CreateSocket(Sender: TObject; const UseSSL: Boolean; out Handler: TSocketHandler);
    procedure Redirect(Sender: TObject; const Source: string; var Dest: string);
    procedure Received(Sender: TObject; const ContentLength, CurrentPos: Int64);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Get(const URL: string; Stream: TStream; Limit: Int64);
  end;

procedure RequireHTTPS(const URL: string);

implementation

uses gnutlssockets, gnutls, URIParser;

type
  TRippleTLSHandler = class(TGNUTLSSocketHandler)
  protected
    function DoVerifyCert: Boolean; override;
  public
    function Recv(const Buffer; Count: Integer): Integer; override;
    function Send(const Buffer; Count: Integer): Integer; override;
  end;

function TRippleTLSHandler.DoVerifyCert: Boolean;
begin
  Result := inherited DoVerifyCert;
  {$IF FPC_FULLVERSION < 30301}
  // FPC 3.2.2 inverts this callback after GnuTLS has verified the chain and hostname.
  Result := not Result;
  {$ENDIF}
end;

function TRippleTLSHandler.Recv(const Buffer; Count: Integer): Integer;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 20000;
  repeat
    Result := inherited Recv(Buffer, Count);
    // TLS session-ticket records can require another receive without application data.
  until (Result >= 0) or ((GNUTLSLastError <> GNUTLS_E_AGAIN) and
    (GNUTLSLastError <> GNUTLS_E_INTERRUPTED)) or
    (GetTickCount64 >= Deadline);
end;

function TRippleTLSHandler.Send(const Buffer; Count: Integer): Integer;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 20000;
  repeat
    Result := inherited Send(Buffer, Count);
  until (Result >= 0) or ((GNUTLSLastError <> GNUTLS_E_AGAIN) and
    (GNUTLSLastError <> GNUTLS_E_INTERRUPTED)) or
    (GetTickCount64 >= Deadline);
end;

procedure RequireHTTPS(const URL: string);
var U: TURI;
begin
  U := ParseURI(URL);
  if (LowerCase(U.Protocol) <> 'https') or (U.Host = '') or
    (U.Username <> '') or (U.Password <> '') then
    raise Exception.Create('An HTTPS download URL is required');
end;

constructor TRippleHTTP.Create;
begin
  inherited Create;
  FClient := TFPHTTPClient.Create(nil);
  FClient.ConnectTimeout := 15000;
  FClient.IOTimeout := 20000;
  FClient.AllowRedirect := True;
  FClient.MaxRedirects := 5;
  FClient.OnGetSocketHandler := @CreateSocket;
  FClient.OnRedirect := @Redirect;
  FClient.OnDataReceived := @Received;
  FClient.AddHeader('User-Agent', 'Ripple/0.1');
end;

destructor TRippleHTTP.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

procedure TRippleHTTP.CreateSocket(Sender: TObject; const UseSSL: Boolean; out Handler: TSocketHandler);
var SSL: TRippleTLSHandler;
begin
  if not UseSSL then raise Exception.Create('TLS is required');
  SSL := TRippleTLSHandler.Create;
  Handler := SSL;
  SSL.VerifyPeerCert := True;
  SSL.CertificateData.CertCA.FileName := '/etc/ssl/certs/ca-certificates.crt';
end;

procedure TRippleHTTP.Redirect(Sender: TObject; const Source: string; var Dest: string);
var Resolved: string;
begin
  if not IsAbsoluteURI(Dest) then
  begin
    if not ResolveRelativeURI(Source, Dest, Resolved) then
      raise Exception.Create('Invalid download redirect');
    Dest := Resolved;
  end;
  RequireHTTPS(Dest);
end;

procedure TRippleHTTP.Received(Sender: TObject; const ContentLength, CurrentPos: Int64);
begin
  if GetTickCount64 > FDeadline then raise Exception.Create('Download timed out');
  if (ContentLength > FLimit) or (CurrentPos > FLimit) then
    raise Exception.Create('Download exceeds the size limit');
end;

procedure TRippleHTTP.Get(const URL: string; Stream: TStream; Limit: Int64);
begin
  RequireHTTPS(URL);
  FLimit := Limit;
  FDeadline := GetTickCount64 + 120000;
  FClient.Get(URL, Stream);
  if FClient.ResponseStatusCode <> 200 then
    raise Exception.CreateFmt('HTTP error %d', [FClient.ResponseStatusCode]);
  if Stream.Size > Limit then raise Exception.Create('Download exceeds the size limit');
  Stream.Position := 0;
end;

end.
