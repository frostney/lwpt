{ LWPT.Registry.Server — foreground HTTP service for an origin store. }
unit LWPT.Registry.Server;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Registry.Store;

type
  TLWPTRegistryHTTPResponse = record
    Status: Integer;
    Reason: string;
    ContentType: string;
    CacheControl: string;
    ETag: string;
    Body: TBytes;
  end;

  TLWPTRegistryServer = class
  private
    FStore: TLWPTRegistryStore;
  public
    constructor Create(AStore: TLWPTRegistryStore);
    procedure Run;
  end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string): TLWPTRegistryHTTPResponse;
function RegistryHTTPWireResponse(const AResponse: TLWPTRegistryHTTPResponse;
  const AIncludeBody: Boolean): TBytes;

implementation

uses
  Classes,
  StrUtils,
  Sockets,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}

  LWPT.Core,
  {$IFDEF DARWIN}
  LWPT.Registry.Server.NetworkFramework,
  {$ENDIF}
  TransportSecurity;

const
  MAX_REQUEST_HEADER_BYTES = 32 * 1024;
  CLIENT_READ_TIMEOUT_MILLISECONDS = 10000;
  TLS_CIPHERTEXT_BUDGET_BYTES = 1024 * 1024;

type
  TLWPTRegistryClientThread = class(TThread)
  private
    FSocket: TSocket;
    FStore: TLWPTRegistryStore;
    FTLSServerContext: TTransportSecurityServerContext;
    FTLSCiphertextReceived: QWord;
    procedure ExecutePlain;
    procedure ExecuteTLS;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: TSocket; AStore: TLWPTRegistryStore;
      ATLSServerContext: TTransportSecurityServerContext);
  end;

function Bytes(const AValue: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(AValue);
end;

function Text(const ABytes: TBytes): string;
begin
  Result := TEncoding.UTF8.GetString(ABytes);
end;

function IsLowerHex64(const AValue: string): Boolean;
var
  Character: Char;
begin
  if Length(AValue) <> 64 then Exit(False);
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
  Result := True;
end;

function BasePath(const ABaseURL: string): string;
var
  AuthorityEnd, SchemeEnd: Integer;
begin
  SchemeEnd := Pos('://', ABaseURL);
  AuthorityEnd := PosEx('/', ABaseURL, SchemeEnd + 3);
  if AuthorityEnd = 0 then Exit('');
  Result := Copy(ABaseURL, AuthorityEnd, MaxInt);
end;

function ErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string): TLWPTRegistryHTTPResponse;
begin
  Result.Status := AStatus;
  Result.Reason := AReason;
  Result.ContentType := 'application/vnd.' + PROGRAM_NAME
    + '.registry-error+toml';
  Result.CacheControl := 'no-store';
  Result.ETag := '';
  Result.Body := Bytes('schema = "' + PROGRAM_NAME
    + '-registry-error-v1"' + #10 + 'code = "' + ACode + '"' + #10
    + 'message = "' + AMessage + '"' + #10 + 'retryable = false' + #10);
end;

function ImmutableResponse(AStore: TLWPTRegistryStore;
  const ARelative, AContentType, AETag: string): TLWPTRegistryHTTPResponse;
begin
  try
    Result.Body := AStore.LoadResource(ARelative);
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := AContentType;
    Result.CacheControl := 'public, max-age=31536000, immutable';
    Result.ETag := AETag;
  except
    on ELWPTRegistryError do
      Result := ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found');
  end;
end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string): TLWPTRegistryHTTPResponse;
var
  APIPath, Digest, KeyID, Prefix, Relative: string;
  State: TLWPTRegistryState;
begin
  if not SameText(AMethod, 'GET') and not SameText(AMethod, 'HEAD') then
    Exit(ErrorResponse(405, 'Method Not Allowed', 'method_not_allowed',
      'only GET and HEAD are supported'));
  if (Pos('?', ATarget) > 0) or (Pos('#', ATarget) > 0)
    or (Pos('..', ATarget) > 0) or (Pos('%', ATarget) > 0) then
    Exit(ErrorResponse(400, 'Bad Request', 'invalid_request_target',
      'request target is not canonical'));
  Prefix := BasePath(AStore.Config.BaseURL);
  if Prefix = '' then Prefix := '';
  if not StartsStr(Prefix + '/', ATarget) then
    Exit(ErrorResponse(404, 'Not Found', 'not_found',
      'request target is outside the configured registry base path'));
  APIPath := Copy(ATarget, Length(Prefix) + 1, MaxInt);
  if APIPath = '/.well-known/' + PROGRAM_NAME + '-registry' then
  begin
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := 'application/vnd.' + PROGRAM_NAME
      + '.registry-discovery+toml';
    Result.CacheControl := 'no-cache';
    Result.ETag := '';
    Result.Body := Bytes('schema = "' + PROGRAM_NAME
      + '-registry-discovery-v1"' + #10 + 'protocol = 1' + #10
      + 'origin = "' + AStore.Config.Identity + '"' + #10
      + 'base_url = "' + AStore.Config.BaseURL + '"' + #10
      + 'role = "origin"' + #10 + 'api = "' + AStore.Config.BaseURL
      + '/v1"' + #10 + 'capabilities = "' + AStore.Config.BaseURL
      + '/v1/capabilities"' + #10 + 'checkpoint = "'
      + AStore.Config.BaseURL + '/v1/checkpoints/latest.toml"' + #10
      + 'rotations = "' + AStore.Config.BaseURL + '/v1/rotations"' + #10);
    Exit;
  end;
  if APIPath = '/v1/capabilities' then
  begin
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := 'application/vnd.' + PROGRAM_NAME
      + '.registry-capabilities+toml';
    Result.CacheControl := 'no-cache';
    Result.ETag := '';
    Result.Body := Bytes('schema = "' + PROGRAM_NAME
      + '-registry-capabilities-v1"' + #10 + 'protocol = 1' + #10
      + 'hashes = ["sha256"]' + #10 + 'signatures = ["ed25519"]' + #10
      + 'schemas = ["' + PROGRAM_NAME + '-registry-capabilities-v1", "'
      + PROGRAM_NAME + '-registry-checkpoint-v1", "' + PROGRAM_NAME
      + '-registry-discovery-v1", "' + PROGRAM_NAME
      + '-registry-error-v1", "' + PROGRAM_NAME
      + '-registry-key-rotation-v1", "' + PROGRAM_NAME
      + '-registry-key-v1", "' + PROGRAM_NAME
      + '-registry-package-v1", "' + PROGRAM_NAME
      + '-registry-page-v1", "' + PROGRAM_NAME
      + '-registry-rotation-page-v1", "' + PROGRAM_NAME
      + '-registry-signature-v1", "' + PROGRAM_NAME
      + '-registry-snapshot-v1"]' + #10
      + 'features = ["package-list-v1", "rotation-chain-v1", '
      + '"snapshot-sync-v1"]' + #10 + 'auth_schemes = []' + #10
      + 'max_page_size = 100' + #10);
    Exit;
  end;
  State := AStore.LoadCurrentState;
  if APIPath = '/v1/checkpoints/latest.toml' then
    Exit(ImmutableResponse(AStore, State.CheckpointPath,
      'application/vnd.' + PROGRAM_NAME + '.registry-checkpoint+toml', ''));
  if APIPath = '/v1/checkpoints/latest.sig.toml' then
    Exit(ImmutableResponse(AStore, State.SignaturePath,
      'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml', ''));
  if StartsStr('/v1/objects/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/objects/sha256/') + 1, MaxInt);
    if not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Exit(ImmutableResponse(AStore, Relative, 'application/gzip',
      '"sha256:' + Digest + '"'));
  end;
  if StartsStr('/v1/records/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/records/sha256/') + 1,
      Length(APIPath) - Length('/v1/records/sha256/') - Length('.toml'));
    if not EndsStr('.toml', APIPath) or not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Exit(ImmutableResponse(AStore, Relative,
      'application/vnd.' + PROGRAM_NAME + '.registry-package+toml',
      '"sha256:' + Digest + '"'));
  end;
  if StartsStr('/v1/snapshots/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/snapshots/sha256/') + 1,
      Length(APIPath) - Length('/v1/snapshots/sha256/') - Length('.toml'));
    if not EndsStr('.toml', APIPath) or not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Exit(ImmutableResponse(AStore, Relative,
      'application/vnd.' + PROGRAM_NAME + '.registry-snapshot+toml',
      '"sha256:' + Digest + '"'));
  end;
  if StartsStr('/v1/keys/ed25519:', APIPath) then
  begin
    KeyID := Copy(APIPath, Length('/v1/keys/') + 1,
      Length(APIPath) - Length('/v1/keys/') - Length('.toml'));
    if not EndsStr('.toml', APIPath) or not StartsStr('ed25519:', KeyID)
      or not IsLowerHex64(Copy(KeyID, Length('ed25519:') + 1,
        MaxInt)) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := RegistryKeyStoragePath(KeyID);
    Exit(ImmutableResponse(AStore, Relative,
      'application/vnd.' + PROGRAM_NAME + '.registry-key+toml', ''));
  end;
  if StartsStr('/v1/checkpoints/', APIPath) then
  begin
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    if EndsStr('.sig.toml', APIPath) then
      Exit(ImmutableResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml', ''));
    if EndsStr('.toml', APIPath) then
      Exit(ImmutableResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-checkpoint+toml', ''));
  end;
  Result := ErrorResponse(404, 'Not Found', 'not_found',
    'registry resource was not found');
end;

function RegistryHTTPWireResponse(const AResponse: TLWPTRegistryHTTPResponse;
  const AIncludeBody: Boolean): TBytes;
var
  Header: string;
  HeaderBytes: TBytes;
begin
  Header := 'HTTP/1.1 ' + IntToStr(AResponse.Status) + ' '
    + AResponse.Reason + #13#10 + 'Content-Type: ' + AResponse.ContentType
    + #13#10 + 'Content-Length: ' + IntToStr(Length(AResponse.Body)) + #13#10
    + 'Cache-Control: ' + AResponse.CacheControl + #13#10;
  if AResponse.ETag <> '' then Header := Header + 'ETag: ' + AResponse.ETag
    + #13#10;
  Header := Header + 'Connection: close' + #13#10 + #13#10;
  HeaderBytes := Bytes(Header);
  if not AIncludeBody then Exit(HeaderBytes);
  SetLength(Result, Length(HeaderBytes) + Length(AResponse.Body));
  if Length(HeaderBytes) > 0 then Move(HeaderBytes[0], Result[0],
    Length(HeaderBytes));
  if Length(AResponse.Body) > 0 then Move(AResponse.Body[0],
    Result[Length(HeaderBytes)], Length(AResponse.Body));
end;

constructor TLWPTRegistryClientThread.Create(const ASocket: TSocket;
  AStore: TLWPTRegistryStore;
  ATLSServerContext: TTransportSecurityServerContext);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FSocket := ASocket;
  FStore := AStore;
  FTLSServerContext := ATLSServerContext;
  FTLSCiphertextReceived := 0;
end;

procedure SendAll(const ASocket: TSocket; const ABytes: TBytes);
var
  Offset, Sent: Integer;
begin
  Offset := 0;
  while Offset < Length(ABytes) do
  begin
    Sent := fpSend(ASocket, @ABytes[Offset], Length(ABytes) - Offset, 0);
    if Sent <= 0 then Exit;
    Inc(Offset, Sent);
  end;
end;

procedure TLWPTRegistryClientThread.ExecutePlain;
var
  Buffer: array[0..4095] of Byte;
  HeaderEnd, Received, Space: Integer;
  IncludeBody: Boolean;
  Method, Request, RequestLine, Target: string;
  Response: TLWPTRegistryHTTPResponse;
  Wire: TBytes;
begin
  try
    Request := '';
    repeat
      Received := fpRecv(FSocket, @Buffer[0], Length(Buffer), 0);
      if Received <= 0 then Exit;
      if Length(Request) + Received > MAX_REQUEST_HEADER_BYTES then
      begin
        Response := ErrorResponse(431, 'Request Header Fields Too Large',
          'request_headers_too_large', 'request headers exceed 32 KiB');
        SendAll(FSocket, RegistryHTTPWireResponse(Response, True));
        Exit;
      end;
      SetString(RequestLine, PAnsiChar(@Buffer[0]), Received);
      Request := Request + RequestLine;
      HeaderEnd := Pos(#13#10#13#10, Request);
    until HeaderEnd > 0;
    RequestLine := Copy(Request, 1, Pos(#13#10, Request) - 1);
    Space := Pos(' ', RequestLine);
    if Space = 0 then
      Response := ErrorResponse(400, 'Bad Request', 'invalid_request',
        'request line is invalid')
    else
    begin
      Method := Copy(RequestLine, 1, Space - 1);
      Delete(RequestLine, 1, Space);
      Space := Pos(' ', RequestLine);
      if Space = 0 then
        Response := ErrorResponse(400, 'Bad Request', 'invalid_request',
          'request line is invalid')
      else
      begin
        Target := Copy(RequestLine, 1, Space - 1);
        Response := RegistryHTTPResponse(FStore, Method, Target);
      end;
    end;
    IncludeBody := not SameText(Method, 'HEAD');
    Wire := RegistryHTTPWireResponse(Response, IncludeBody);
    SendAll(FSocket, Wire);
  except
    { A malformed client must not end the foreground server. }
  end;
end;

procedure FlushTLSCiphertext(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection);
var
  Buffer: Pointer;
  Pending, Sent: Integer;
begin
  while TransportSecurityPendingCiphertext(AConnection) > 0 do
  begin
    Pending := TransportSecurityGetCiphertext(AConnection, Buffer);
    if Pending <= 0 then Exit;
    Sent := fpSend(ASocket, Buffer, Pending, 0);
    if Sent <= 0 then
      raise ELWPTRegistryError.CreateStable('tls_io_failed',
        'could not send TLS ciphertext');
    TransportSecurityConsumeCiphertext(AConnection, Sent);
  end;
end;

procedure ReceiveTLSCiphertext(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection;
  var AReceivedTotal: QWord);
var
  Buffer: array[0..16383] of Byte;
  Accepted, Received: Integer;
begin
  Received := fpRecv(ASocket, @Buffer[0], Length(Buffer), 0);
  if Received <= 0 then
    raise ELWPTRegistryError.CreateStable('tls_io_failed',
      'TLS peer closed before completing the request');
  Inc(AReceivedTotal, Received);
  if AReceivedTotal > TLS_CIPHERTEXT_BUDGET_BYTES then
    raise ELWPTRegistryError.CreateStable('tls_input_limit',
      'TLS connection exceeded its ciphertext byte budget');
  Accepted := TransportSecurityFeedCiphertext(AConnection, @Buffer[0],
    Received);
  if Accepted <> Received then
    raise ELWPTRegistryError.CreateStable('tls_input_limit',
      'TLS ciphertext exceeded the configured input capacity');
end;

procedure TLWPTRegistryClientThread.ExecuteTLS;
var
  Buffer: array[0..4095] of Byte;
  Connection: TTransportSecurityConnection;
  HeaderEnd, Offset, Space: Integer;
  IncludeBody: Boolean;
  Method, Request, RequestChunk, RequestLine, Target: string;
  Response: TLWPTRegistryHTTPResponse;
  ResultState: TTransportSecurityState;
  IOResult: TTransportSecurityIOResult;
  HandshakeDeadline: QWord;
  Wire: TBytes;
begin
  FillChar(Connection, SizeOf(Connection), 0);
  BeginTransportSecurityServer(Connection, FTLSServerContext);
  try
    HandshakeDeadline := GetTickCount64 + CLIENT_READ_TIMEOUT_MILLISECONDS;
    repeat
      if GetTickCount64 > HandshakeDeadline then
        raise ELWPTRegistryError.CreateStable('tls_handshake_timeout',
          'TLS server handshake exceeded its deadline');
      FlushTLSCiphertext(FSocket, Connection);
      ResultState := TransportSecurityServerHandshake(Connection);
      case ResultState of
        tssDone:;
        tssWantRead: ReceiveTLSCiphertext(FSocket, Connection,
          FTLSCiphertextReceived);
        tssWantWrite: FlushTLSCiphertext(FSocket, Connection);
        else raise ELWPTRegistryError.CreateStable('tls_handshake_failed',
          'TLS server handshake failed');
      end;
    until (ResultState = tssDone)
      and (TransportSecurityPendingCiphertext(Connection) = 0);
    Request := '';
    repeat
      IOResult := TransportSecurityServerRead(Connection, Buffer,
        Length(Buffer));
      if IOResult.BytesProcessed > 0 then
      begin
        SetString(RequestChunk, PAnsiChar(@Buffer[0]),
          IOResult.BytesProcessed);
        Request := Request + RequestChunk;
        if Length(Request) > MAX_REQUEST_HEADER_BYTES then
          raise ELWPTRegistryError.CreateStable('request_headers_too_large',
            'request headers exceed 32 KiB');
      end;
      HeaderEnd := Pos(#13#10#13#10, Request);
      if HeaderEnd > 0 then Break;
      case IOResult.State of
        tssDone:;
        tssWantRead: ReceiveTLSCiphertext(FSocket, Connection,
          FTLSCiphertextReceived);
        tssWantWrite: FlushTLSCiphertext(FSocket, Connection);
        else raise ELWPTRegistryError.CreateStable('tls_io_failed',
          'TLS request read failed');
      end;
    until False;
    RequestLine := Copy(Request, 1, Pos(#13#10, Request) - 1);
    Space := Pos(' ', RequestLine);
    if Space = 0 then Exit;
    Method := Copy(RequestLine, 1, Space - 1);
    Delete(RequestLine, 1, Space);
    Space := Pos(' ', RequestLine);
    if Space = 0 then Exit;
    Target := Copy(RequestLine, 1, Space - 1);
    Response := RegistryHTTPResponse(FStore, Method, Target);
    IncludeBody := not SameText(Method, 'HEAD');
    Wire := RegistryHTTPWireResponse(Response, IncludeBody);
    Offset := 0;
    while Offset < Length(Wire) do
    begin
      IOResult := TransportSecurityServerWrite(Connection, @Wire[Offset],
        Length(Wire) - Offset);
      Inc(Offset, IOResult.BytesProcessed);
      FlushTLSCiphertext(FSocket, Connection);
      if (IOResult.BytesProcessed = 0) and (IOResult.State = tssWantRead) then
        ReceiveTLSCiphertext(FSocket, Connection, FTLSCiphertextReceived)
      else if (IOResult.BytesProcessed = 0) and not
        (IOResult.State in [tssDone, tssWantWrite]) then
        raise ELWPTRegistryError.CreateStable('tls_io_failed',
          'TLS response write failed');
    end;
    FlushTLSCiphertext(FSocket, Connection);
    repeat
      ResultState := CloseTransportSecurityServerGracefully(Connection);
      FlushTLSCiphertext(FSocket, Connection);
      if ResultState = tssWantRead then
        ReceiveTLSCiphertext(FSocket, Connection, FTLSCiphertextReceived);
    until (ResultState = tssDone) or (ResultState = tssPeerClosed);
  finally
    AbortTransportSecurityServer(Connection);
  end;
end;

procedure TLWPTRegistryClientThread.Execute;
begin
  try
    if Assigned(FTLSServerContext) then ExecuteTLS
    else ExecutePlain;
  except
    { Connection-scoped protocol and I/O failures do not stop the listener. }
  end;
  fpShutdown(FSocket, 2);
  CloseSocket(FSocket);
end;

constructor TLWPTRegistryServer.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create;
  FStore := AStore;
end;

procedure TLWPTRegistryServer.Run;
var
  Address: TInetSockAddr;
  AddressLength: TSocklen;
  ClientSocket, ListenSocket: TSocket;
  Client: TLWPTRegistryClientThread;
  ListenHost: string;
  Reuse: LongInt;
  {$IFDEF UNIX}
  Timeout: TTimeVal;
  {$ELSE}
  Timeout: LongInt;
  {$ENDIF}
  TLSServerContext: TTransportSecurityServerContext;
begin
  TLSServerContext := nil;
  if StartsText('https://', FStore.Config.BaseURL) then
  begin
    {$IFDEF DARWIN}
    RunNetworkFrameworkRegistryServer(FStore, FStore.Config.TLSPKCS12Path,
      SysUtils.GetEnvironmentVariable(FStore.Config.TLSPasswordEnvironment));
    Exit;
    {$ELSE}
    TLSServerContext := TTransportSecurityServerContext.Create(
      FStore.Config.TLSPKCS12Path,
      UnicodeString(SysUtils.GetEnvironmentVariable(
        FStore.Config.TLSPasswordEnvironment)));
    {$ENDIF}
  end;
  ListenHost := FStore.Config.ListenAddress;
  if SameText(ListenHost, 'localhost') then ListenHost := '127.0.0.1';
  ListenSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  if ListenSocket < 0 then
  begin
    TLSServerContext.Free;
    raise ELWPTRegistryError.CreateStable('listen_failed',
      'could not create the registry socket');
  end;
  try
    Reuse := 1;
    fpSetSockOpt(ListenSocket, SOL_SOCKET, SO_REUSEADDR, @Reuse,
      SizeOf(Reuse));
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(FStore.Config.Port);
    Address.sin_addr := StrToNetAddr(ListenHost);
    if Address.sin_addr.s_addr = LongWord(-1) then
      raise ELWPTRegistryError.CreateStable('invalid_listen_address',
        'listen address must be localhost or an IPv4 address');
    if fpBind(ListenSocket, @Address, SizeOf(Address)) <> 0 then
      raise ELWPTRegistryError.CreateStable('listen_failed',
        'could not bind ' + FStore.Config.ListenAddress + ':'
        + IntToStr(FStore.Config.Port));
    if fpListen(ListenSocket, 128) <> 0 then
      raise ELWPTRegistryError.CreateStable('listen_failed',
        'could not listen on the configured registry socket');
    WriteLn('registry origin ', FStore.Config.Identity, ' listening at ',
      FStore.Config.BaseURL);
    while True do
    begin
      AddressLength := SizeOf(Address);
      ClientSocket := fpAccept(ListenSocket, @Address, @AddressLength);
      if ClientSocket < 0 then
        raise ELWPTRegistryError.CreateStable('accept_failed',
          'registry listener could not accept a connection');
      {$IFDEF UNIX}
      Timeout.tv_sec := CLIENT_READ_TIMEOUT_MILLISECONDS div 1000;
      Timeout.tv_usec := (CLIENT_READ_TIMEOUT_MILLISECONDS mod 1000) * 1000;
      {$ELSE}
      Timeout := CLIENT_READ_TIMEOUT_MILLISECONDS;
      {$ENDIF}
      fpSetSockOpt(ClientSocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout,
        SizeOf(Timeout));
      fpSetSockOpt(ClientSocket, SOL_SOCKET, SO_SNDTIMEO, @Timeout,
        SizeOf(Timeout));
      Client := TLWPTRegistryClientThread.Create(ClientSocket, FStore,
        TLSServerContext);
      Client.Start;
    end;
  finally
    CloseSocket(ListenSocket);
    TLSServerContext.Free;
  end;
end;

end.
