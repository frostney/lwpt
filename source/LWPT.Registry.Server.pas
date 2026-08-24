{ LWPT.Registry.Server — foreground HTTP service for an origin store. }
unit LWPT.Registry.Server;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Registry.Store,
  Sockets;

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
    FClients: TThreadList;
    FStopping: Boolean;
    procedure DrainClients;
    procedure ReapClients;
  public
    constructor Create(AStore: TLWPTRegistryStore);
    destructor Destroy; override;
    procedure RequestStop;
    procedure Run;
  end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string): TLWPTRegistryHTTPResponse;
function RegistryErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string; const ARequestID: string = ''):
  TLWPTRegistryHTTPResponse;
function RegistryHTTPWireResponse(const AResponse: TLWPTRegistryHTTPResponse;
  const AIncludeBody: Boolean): TBytes;

implementation

uses
  StrUtils,
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
  MAX_ACTIVE_CLIENTS = 32;

var
  RegistryRequestSequence: LongInt;

type
  TLWPTRegistryClientThread = class(TThread)
  private
    FSocket: TSocket;
    FStore: TLWPTRegistryStore;
    FTLSServerContext: TTransportSecurityServerContext;
    FTLSCiphertextReceived: QWord;
    FDeadline: QWord;
    FDone: Boolean;
    procedure CheckDeadline;
    procedure ExecutePlain;
    procedure ExecuteTLS;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: TSocket; AStore: TLWPTRegistryStore;
      ATLSServerContext: TTransportSecurityServerContext);
    procedure Cancel;
    property Done: Boolean read FDone;
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

function NewRegistryRequestID: string;
var
  Identity: string;
begin
  Identity := RegistryTimestampNow + ':' + IntToStr(GetTickCount64) + ':'
    + IntToStr(InterlockedIncrement(RegistryRequestSequence));
  Result := Copy(SHA256Hex(Bytes(Identity)), 1, 26);
end;

function RegistryErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string; const ARequestID: string):
  TLWPTRegistryHTTPResponse;
var
  RequestID: string;
begin
  RequestID := ARequestID;
  if RequestID = '' then RequestID := NewRegistryRequestID;
  Result.Status := AStatus;
  Result.Reason := AReason;
  Result.ContentType := 'application/vnd.' + PROGRAM_NAME
    + '.registry-error+toml';
  Result.CacheControl := 'no-store';
  Result.ETag := '';
  Result.Body := Bytes('schema = '
    + RegistryTOMLQuote(PROGRAM_NAME + '-registry-error-v1') + #10
    + 'code = ' + RegistryTOMLQuote(ACode) + #10
    + 'message = ' + RegistryTOMLQuote(AMessage) + #10
    + 'request_id = ' + RegistryTOMLQuote(RequestID) + #10
    + 'retryable = false' + #10);
end;

function ErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string): TLWPTRegistryHTTPResponse;
begin
  Result := RegistryErrorResponse(AStatus, AReason, ACode, AMessage);
end;

function ResourceResponse(AStore: TLWPTRegistryStore;
  const ARelative, AContentType, AETag, AExpectedDigest: string;
  const AImmutable: Boolean): TLWPTRegistryHTTPResponse;
begin
  try
    Result.Body := AStore.LoadResource(ARelative);
    if (AExpectedDigest <> '') and (SHA256BytesPrefixed(Result.Body)
      <> AExpectedDigest) then
      raise ELWPTRegistryError.CreateStable('resource_hash_mismatch',
        'content-addressed resource bytes do not match the request path');
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := AContentType;
    if AImmutable then
      Result.CacheControl := 'public, max-age=31536000, immutable'
    else Result.CacheControl := 'no-cache, must-revalidate';
    Result.ETag := AETag;
  except
    on E: ELWPTRegistryError do
      if Pos('resource_hash_mismatch:', E.Message) = 1 then
        Result := ErrorResponse(500, 'Internal Server Error',
          'resource_hash_mismatch',
          'stored registry resource failed content verification')
      else Result := ErrorResponse(404, 'Not Found', 'not_found',
          'registry resource was not found');
  end;
end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string): TLWPTRegistryHTTPResponse;
var
  APIPath, Digest, KeyID, Prefix, Relative: string;
  State: TLWPTRegistryState;
begin
  try
    AStore.EnsureFreshCheckpoint(RegistryTimestampNow);
  except
    on E: ELWPTRegistryError do
      Exit(ErrorResponse(500, 'Internal Server Error',
        'checkpoint_renewal_failed', E.Message));
  end;
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
      + AStore.Config.BaseURL + '/v1/checkpoints/latest.toml"' + #10);
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
      + '-registry-key-v1", "' + PROGRAM_NAME
      + '-registry-package-v1", "' + PROGRAM_NAME
      + '-registry-signature-v1", "' + PROGRAM_NAME
      + '-registry-snapshot-v1"]' + #10
      + 'features = ["snapshot-sync-v1"]' + #10
      + 'auth_schemes = []' + #10
      + 'max_page_size = 100' + #10);
    Exit;
  end;
  State := AStore.LoadCurrentState;
  if APIPath = '/v1/checkpoints/latest.toml' then
    Exit(ResourceResponse(AStore, State.CheckpointPath,
      'application/vnd.' + PROGRAM_NAME + '.registry-checkpoint+toml', '',
      '', False));
  if APIPath = '/v1/checkpoints/latest.sig.toml' then
    Exit(ResourceResponse(AStore, State.SignaturePath,
      'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml', '',
      '', False));
  if StartsStr('/v1/objects/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/objects/sha256/') + 1, MaxInt);
    if not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Exit(ResourceResponse(AStore, Relative, 'application/gzip',
      '"sha256:' + Digest + '"', 'sha256:' + Digest, True));
  end;
  if StartsStr('/v1/records/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/records/sha256/') + 1,
      Length(APIPath) - Length('/v1/records/sha256/') - Length('.toml'));
    if not EndsStr('.toml', APIPath) or not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Exit(ResourceResponse(AStore, Relative,
      'application/vnd.' + PROGRAM_NAME + '.registry-package+toml',
      '"sha256:' + Digest + '"', 'sha256:' + Digest, True));
  end;
  if StartsStr('/v1/snapshots/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/snapshots/sha256/') + 1,
      Length(APIPath) - Length('/v1/snapshots/sha256/') - Length('.toml'));
    if not EndsStr('.toml', APIPath) or not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Exit(ResourceResponse(AStore, Relative,
      'application/vnd.' + PROGRAM_NAME + '.registry-snapshot+toml',
      '"sha256:' + Digest + '"', 'sha256:' + Digest, True));
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
    Exit(ResourceResponse(AStore, Relative,
      'application/vnd.' + PROGRAM_NAME + '.registry-key+toml', '', '',
      True));
  end;
  if StartsStr('/v1/checkpoints/', APIPath) then
  begin
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    if EndsStr('.sig.toml', APIPath) then
      Exit(ResourceResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml', '',
        '', False));
    if EndsStr('.toml', APIPath) then
      Exit(ResourceResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-checkpoint+toml', '',
        '', False));
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
  FreeOnTerminate := False;
  FSocket := ASocket;
  FStore := AStore;
  FTLSServerContext := ATLSServerContext;
  FTLSCiphertextReceived := 0;
  FDeadline := GetTickCount64 + CLIENT_READ_TIMEOUT_MILLISECONDS;
  FDone := False;
end;

procedure TLWPTRegistryClientThread.CheckDeadline;
begin
  if Terminated or (GetTickCount64 >= FDeadline) then
    raise ELWPTRegistryError.CreateStable('connection_deadline',
      'registry connection exceeded its total deadline');
end;

procedure TLWPTRegistryClientThread.Cancel;
begin
  Terminate;
  fpShutdown(FSocket, 2);
end;

procedure ApplyDeadlineTimeout(const ASocket: TSocket;
  const ADeadline: QWord);
var
  Remaining: QWord;
  {$IFDEF UNIX}
  Timeout: TTimeVal;
  {$ELSE}
  Timeout: LongInt;
  {$ENDIF}
begin
  if GetTickCount64 >= ADeadline then Remaining := 1
  else Remaining := ADeadline - GetTickCount64;
  if Remaining > High(LongInt) then Remaining := High(LongInt);
  {$IFDEF UNIX}
  Timeout.tv_sec := Remaining div 1000;
  Timeout.tv_usec := (Remaining mod 1000) * 1000;
  {$ELSE}
  Timeout := Remaining;
  {$ENDIF}
  fpSetSockOpt(ASocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));
  fpSetSockOpt(ASocket, SOL_SOCKET, SO_SNDTIMEO, @Timeout, SizeOf(Timeout));
end;

procedure SendAll(const ASocket: TSocket; const ABytes: TBytes;
  const ADeadline: QWord);
var
  Offset, Sent: Integer;
begin
  Offset := 0;
  while Offset < Length(ABytes) do
  begin
    if GetTickCount64 >= ADeadline then Exit;
    ApplyDeadlineTimeout(ASocket, ADeadline);
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
      CheckDeadline;
      ApplyDeadlineTimeout(FSocket, FDeadline);
      Received := fpRecv(FSocket, @Buffer[0], Length(Buffer), 0);
      if Received <= 0 then Exit;
      if Length(Request) + Received > MAX_REQUEST_HEADER_BYTES then
      begin
        Response := ErrorResponse(431, 'Request Header Fields Too Large',
          'request_headers_too_large', 'request headers exceed 32 KiB');
        SendAll(FSocket, RegistryHTTPWireResponse(Response, True), FDeadline);
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
    CheckDeadline;
    SendAll(FSocket, Wire, FDeadline);
  except
    { A malformed client must not end the foreground server. }
  end;
end;

procedure FlushTLSCiphertext(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection; const ADeadline: QWord);
var
  Buffer: Pointer;
  Pending, Sent: Integer;
begin
  while TransportSecurityPendingCiphertext(AConnection) > 0 do
  begin
    if GetTickCount64 >= ADeadline then
      raise ELWPTRegistryError.CreateStable('connection_deadline',
        'registry connection exceeded its total deadline');
    ApplyDeadlineTimeout(ASocket, ADeadline);
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
  var AReceivedTotal: QWord; const ADeadline: QWord);
var
  Buffer: array[0..16383] of Byte;
  Accepted, Received: Integer;
begin
  if GetTickCount64 >= ADeadline then
    raise ELWPTRegistryError.CreateStable('connection_deadline',
      'registry connection exceeded its total deadline');
  ApplyDeadlineTimeout(ASocket, ADeadline);
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
  Wire: TBytes;
begin
  FillChar(Connection, SizeOf(Connection), 0);
  BeginTransportSecurityServer(Connection, FTLSServerContext);
  try
    repeat
      CheckDeadline;
      FlushTLSCiphertext(FSocket, Connection, FDeadline);
      ResultState := TransportSecurityServerHandshake(Connection);
      case ResultState of
        tssDone:;
        tssWantRead: ReceiveTLSCiphertext(FSocket, Connection,
          FTLSCiphertextReceived, FDeadline);
        tssWantWrite: FlushTLSCiphertext(FSocket, Connection, FDeadline);
        else raise ELWPTRegistryError.CreateStable('tls_handshake_failed',
          'TLS server handshake failed');
      end;
    until (ResultState = tssDone)
      and (TransportSecurityPendingCiphertext(Connection) = 0);
    Request := '';
    repeat
      CheckDeadline;
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
          FTLSCiphertextReceived, FDeadline);
        tssWantWrite: FlushTLSCiphertext(FSocket, Connection, FDeadline);
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
      CheckDeadline;
      IOResult := TransportSecurityServerWrite(Connection, @Wire[Offset],
        Length(Wire) - Offset);
      Inc(Offset, IOResult.BytesProcessed);
      FlushTLSCiphertext(FSocket, Connection, FDeadline);
      if (IOResult.BytesProcessed = 0) and (IOResult.State = tssWantRead) then
        ReceiveTLSCiphertext(FSocket, Connection, FTLSCiphertextReceived,
          FDeadline)
      else if (IOResult.BytesProcessed = 0) and not
        (IOResult.State in [tssDone, tssWantWrite]) then
        raise ELWPTRegistryError.CreateStable('tls_io_failed',
          'TLS response write failed');
    end;
    FlushTLSCiphertext(FSocket, Connection, FDeadline);
    repeat
      ResultState := CloseTransportSecurityServerGracefully(Connection);
      CheckDeadline;
      FlushTLSCiphertext(FSocket, Connection, FDeadline);
      if ResultState = tssWantRead then
        ReceiveTLSCiphertext(FSocket, Connection, FTLSCiphertextReceived,
          FDeadline);
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
  FDone := True;
end;

constructor TLWPTRegistryServer.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create;
  FStore := AStore;
  FClients := TThreadList.Create;
  FStopping := False;
end;

destructor TLWPTRegistryServer.Destroy;
begin
  RequestStop;
  DrainClients;
  FClients.Free;
  inherited Destroy;
end;

procedure TLWPTRegistryServer.RequestStop;
begin
  FStopping := True;
end;

procedure TLWPTRegistryServer.ReapClients;
var
  Clients: TList;
  Client: TLWPTRegistryClientThread;
  Index: Integer;
begin
  Clients := FClients.LockList;
  try
    for Index := Clients.Count - 1 downto 0 do
    begin
      Client := TLWPTRegistryClientThread(Clients[Index]);
      if Client.Done then
      begin
        Clients.Delete(Index);
        Client.WaitFor;
        Client.Free;
      end;
    end;
  finally
    FClients.UnlockList;
  end;
end;

procedure TLWPTRegistryServer.DrainClients;
var
  Clients: TList;
  Client: TLWPTRegistryClientThread;
  Index: Integer;
begin
  Clients := FClients.LockList;
  try
    for Index := 0 to Clients.Count - 1 do
      TLWPTRegistryClientThread(Clients[Index]).Cancel;
  finally
    FClients.UnlockList;
  end;
  while True do
  begin
    Clients := FClients.LockList;
    try
      if Clients.Count = 0 then Exit;
      Client := TLWPTRegistryClientThread(Clients[0]);
      Clients.Delete(0);
    finally
      FClients.UnlockList;
    end;
    Client.WaitFor;
    Client.Free;
  end;
end;

procedure TLWPTRegistryServer.Run;
var
  Address: TInetSockAddr;
  AddressLength: TSocklen;
  ClientSocket, ListenSocket: TSocket;
  Client: TLWPTRegistryClientThread;
  Clients: TList;
  ListenHost: string;
  ReadSet: TFDSet;
  Reuse: LongInt;
  SelectResult: Integer;
  SelectTimeout: TTimeVal;
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
      SysUtils.GetEnvironmentVariable(FStore.Config.TLSPasswordEnvironment),
      @FStopping);
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
    while not FStopping do
    begin
      ReapClients;
      fpFD_ZERO(ReadSet);
      fpFD_SET(ListenSocket, ReadSet);
      SelectTimeout.tv_sec := 0;
      SelectTimeout.tv_usec := 100000;
      SelectResult := fpSelect(ListenSocket + 1, @ReadSet, nil, nil,
        @SelectTimeout);
      if SelectResult < 0 then
      begin
        if FStopping then Break;
        Continue;
      end;
      if SelectResult = 0 then Continue;
      AddressLength := SizeOf(Address);
      ClientSocket := fpAccept(ListenSocket, @Address, @AddressLength);
      if ClientSocket < 0 then
      begin
        if FStopping then Break;
        Continue;
      end;
      Clients := FClients.LockList;
      try
        if Clients.Count >= MAX_ACTIVE_CLIENTS then
        begin
          fpShutdown(ClientSocket, 2);
          CloseSocket(ClientSocket);
          Continue;
        end;
      finally
        FClients.UnlockList;
      end;
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
      Clients := FClients.LockList;
      try
        Clients.Add(Client);
      finally
        FClients.UnlockList;
      end;
      Client.Start;
    end;
  finally
    FStopping := True;
    CloseSocket(ListenSocket);
    DrainClients;
    TLSServerContext.Free;
  end;
end;

end.
