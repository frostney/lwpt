{ TransportSecurityClientOptions.E2E.Test -- loopback coverage of the
  outbound TLS client options (ADR-0050) on every platform.

  A background thread serves each connection through the package's own
  server accept backend (memory-BIO OpenSSL on Unix-not-Darwin, SChannel on
  Windows, Secure Transport on macOS) over a real loopback socket. The client
  side is the production StartTransportSecurity path and HTTPClient, so each
  case exercises the platform's native client backend end to end. Requiring a
  client certificate uses the test-only server seam; nothing else reaches
  past the published API. }

program TransportSecurityClientOptions.E2E.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads, { must come first so the server TThread has a thread driver }
  {$ENDIF}
  Classes,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  Sockets,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  base64,
  HTTPClient,
  TestingPascalLibrary,
  TransportSecurity;

const
  FIXTURES = 'packages/httpclient/source/fixtures/';
  {$IFDEF DARWIN}
  { Apple's SSL policy rejects the ten-year package leaf, so Darwin serves
    the short-lived native identity issued by the same test PKI. }
  SERVER_PKCS12_PATH =
    'tests/fixtures/registry/localhost-native-identity.p12';
  SERVER_LEAF_PATH =
    'tests/fixtures/registry/localhost-native-leaf-cert.pem';
  {$ELSE}
  SERVER_PKCS12_PATH = FIXTURES + 'localhost-test-identity.p12';
  SERVER_LEAF_PATH = FIXTURES + 'localhost-test-leaf-cert.pem';
  {$ENDIF}
  SELF_SIGNED_PKCS12_PATH = FIXTURES + 'localhost-self-signed-dev.p12';
  { A clientAuth leaf under its own client intermediate and root. The
    bundle carries the intermediate but not the root, and the requiring
    server trusts only the client root, so the intermediate must travel in
    the client's Certificate message. }
  CLIENT_PKCS12_PATH = FIXTURES + 'client-identity.p12';
  CLIENT_ROOT_PATH = FIXTURES + 'client-root-cert.pem';
  { A clientAuth leaf from the server hierarchy, which the requiring server
    does not trust. }
  FOREIGN_CLIENT_PKCS12_PATH =
    FIXTURES + 'localhost-wrong-purpose-identity.p12';
  { A public host LWPT's live-network tests already contact. }
  LIVE_HTTPS_URL = 'https://github.com/';
  TEST_ROOT_PATH = FIXTURES + 'test-root-cert.pem';
  UNRELATED_ROOT_PATH = FIXTURES + 'unrelated-root-cert.pem';
  { A leaf served without its issuer, whose AIA, OCSP, and CRL URLs point at
    never-routed TEST-NET-1 (192.0.2.1): a fetch would block for seconds. }
  UNREACHABLE_AIA_PKCS12_PATH =
    FIXTURES + 'localhost-unreachable-aia-identity.p12';
  { Anchor-only evaluation is offline, so it must finish far inside any
    network retrieval timeout (15 s by default on Windows). }
  OFFLINE_VERIFICATION_BUDGET_MILLISECONDS = 8000;
  PKCS12_PASSPHRASE = 'test-only';
  MISMATCHED_HOST = 'mismatch.invalid';
  CLIENT_REQUEST = 'GET / HTTP/1.1'#13#10'Host: localhost'#13#10 +
    'Connection: close'#13#10#13#10;
  RESPONSE_BODY = 'ok';
  OK_RESPONSE = 'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10 +
    'Connection: close'#13#10#13#10 + RESPONSE_BODY;
  STEP_TIMEOUT_MILLISECONDS = 10000;
  SERVER_JOIN_MILLISECONDS = 15000;
  RECEIVE_CHUNK_SIZE = 4096;

type
  TServedConnection = record
    HandshakeSucceeded: Boolean;
    Error: string;
  end;

  { Serves one TLS connection per configured response, in order, through the
    public server API over a nonblocking accepted socket. }
  TLoopbackTLSServer = class(TThread)
  private
    FContext: TTransportSecurityServerContext;
    FListenSocket: TSocket;
    FPort: Word;
    FClientAnchors: TBytes;
    FResponses: array of AnsiString;
    FResults: array of TServedConnection;
    FServed: Integer;
    procedure Flush(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection);
    function Receive(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection): Boolean;
    procedure ServeOne(const ASocket: TSocket; const AIndex: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(const APkcs12Path: string;
      const AValidation: TTransportSecurityServerIdentityValidation;
      const AResponses: array of AnsiString;
      const ARequireClientCertificate: Boolean = False);
    destructor Destroy; override;
    procedure Join;
    procedure WaitServed(const ACount: Integer);
    function Outcome(const AIndex: Integer): TServedConnection;
    property Port: Word read FPort;
    property Served: Integer read FServed;
  end;

  TTransportSecurityClientOptionsE2ETests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAnchorsOnlyVerifiesConfiguredCA;
    procedure TestAnchorsOnlyRejectsUnrelatedCA;
    procedure TestAnchorsOnlyNeverFetchesUnreachableURLs;
    procedure TestSystemAndAnchorsVerifiesConfiguredCA;
    procedure TestSystemAndAnchorsRejectsUnrelatedCA;
    procedure TestPeerCertificateIsServerLeaf;
    procedure TestClientIdentitySatisfiesRequiringServer;
    procedure TestRequiringServerRefusesAnonymousClient;
    procedure TestInsecureSkipVerifyAcceptsSelfSignedServer;
    procedure TestSelfSignedServerFailsWithoutInsecureSkipVerify;
    procedure TestInsecureSkipVerifyAcceptsHostMismatch;
    procedure TestHostMismatchFailsVerification;
    procedure TestHTTPClientTrustsPrivateCA;
    procedure TestHTTPClientSameOriginRedirectKeepsOptions;
    procedure TestHTTPClientCrossOriginRedirectDropsOptions;
    procedure TestHTTPClientRejectsInvalidOptionsBeforeConnecting;
    procedure TestRequiringServerRefusesForeignClientIdentity;
    procedure TestHTTPClientRejectsMalformedAnchorBeforeConnecting;
    procedure TestHTTPClientRejectsCorruptIdentityBeforeConnecting;
    procedure TestHTTPClientRejectsWrongPassphraseBeforeConnecting;
    procedure TestLiveTrustModesDifferOnSystemStore;
    procedure TestHTTPClientSameOriginRedirectKeepsInsecureMode;
    procedure TestHTTPClientCrossOriginRedirectDropsInsecureMode;
    procedure TestHTTPClientSameOriginRedirectKeepsClientIdentity;
    procedure TestHTTPClientCrossOriginRedirectDropsClientIdentity;
  end;

{ ── platform sockets ─────────────────────────────────────────────── }

{$IFDEF MSWINDOWS}
const
  INVALID_TEST_SOCKET = TSocket(INVALID_SOCKET);
{$ELSE}
const
  INVALID_TEST_SOCKET = TSocket(-1);
{$ENDIF}

function TestSocketValid(const ASocket: TSocket): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := ASocket <> TSocket(INVALID_SOCKET);
  {$ELSE}
  Result := ASocket >= 0;
  {$ENDIF}
end;

procedure CloseTestSocket(var ASocket: TSocket);
begin
  if not TestSocketValid(ASocket) then
    Exit;
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(ASocket);
  {$ELSE}
  CloseSocket(ASocket);
  {$ENDIF}
  ASocket := INVALID_TEST_SOCKET;
end;

procedure SetTestSocketNonblocking(const ASocket: TSocket);
{$IFDEF MSWINDOWS}
var
  Mode: u_long;
begin
  Mode := 1;
  if WinSock2.ioctlsocket(ASocket, LongInt(FIONBIO), Mode) <> 0 then
    raise Exception.Create('ioctlsocket(FIONBIO) failed');
end;
{$ELSE}
var
  Flags: LongInt;
begin
  Flags := FpFcntl(ASocket, F_GETFL, 0);
  if (Flags < 0) or (FpFcntl(ASocket, F_SETFL, Flags or O_NONBLOCK) < 0) then
    raise Exception.Create('fcntl(O_NONBLOCK) failed');
end;
{$ENDIF}

function TestSocketWouldBlock: Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.WSAGetLastError = WSAEWOULDBLOCK;
  {$ELSE}
  Result := (FpGetErrno = ESysEAGAIN) or (FpGetErrno = ESysEWOULDBLOCK);
  {$ENDIF}
end;

function TestSend(const ASocket: TSocket; const ABuffer: Pointer;
  const ALength: Integer): Integer;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.send(ASocket, ABuffer^, ALength, 0);
  {$ELSE}
  Result := FpSend(ASocket, ABuffer, ALength, 0);
  {$ENDIF}
end;

function TestReceive(const ASocket: TSocket; const ABuffer: Pointer;
  const ALength: Integer): Integer;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.recv(ASocket, ABuffer^, ALength, 0);
  {$ELSE}
  Result := FpRecv(ASocket, ABuffer, ALength, 0);
  {$ENDIF}
end;

function CreateLoopbackListener(out APort: Word): TSocket;
{$IFDEF MSWINDOWS}
var
  Address: TSockAddrIn;
  AddressLength: LongInt;
begin
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  if not TestSocketValid(Result) then
    raise Exception.Create('socket() failed');
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := 0;
    Address.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
    if WinSock2.bind(Result, PSockAddr(@Address), SizeOf(Address)) <> 0 then
      raise Exception.Create('bind() failed');
    if WinSock2.listen(Result, 4) <> 0 then
      raise Exception.Create('listen() failed');
    AddressLength := SizeOf(Address);
    if WinSock2.getsockname(Result, PSockAddr(@Address)^, AddressLength) <> 0 then
      raise Exception.Create('getsockname() failed');
    APort := WinSock2.ntohs(Address.sin_port);
  except
    CloseTestSocket(Result);
    raise;
  end;
end;
{$ELSE}
var
  Address: TInetSockAddr;
  AddressLength: TSocklen;
begin
  Result := FpSocket(AF_INET, SOCK_STREAM, 0);
  if not TestSocketValid(Result) then
    raise Exception.Create('socket() failed');
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := 0;
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if FpBind(Result, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('bind() failed');
    if FpListen(Result, 4) <> 0 then
      raise Exception.Create('listen() failed');
    AddressLength := SizeOf(Address);
    if FpGetSockName(Result, @Address, @AddressLength) <> 0 then
      raise Exception.Create('getsockname() failed');
    APort := NToHs(Address.sin_port);
  except
    CloseTestSocket(Result);
    raise;
  end;
end;
{$ENDIF}

{ Waits up to ATimeoutMilliseconds for a pending connection. }
function AcceptWithin(const AListenSocket: TSocket;
  const ATimeoutMilliseconds: Integer): TSocket;
var
  ReadSet: TFDSet;
  Ready: Integer;
  {$IFDEF MSWINDOWS}
  Timeout: TTimeVal;
  {$ENDIF}
begin
  Result := INVALID_TEST_SOCKET;
  {$IFDEF MSWINDOWS}
  FillChar(ReadSet, SizeOf(ReadSet), 0);
  ReadSet.fd_count := 1;
  ReadSet.fd_array[0] := AListenSocket;
  Timeout.tv_sec := ATimeoutMilliseconds div 1000;
  Timeout.tv_usec := (ATimeoutMilliseconds mod 1000) * 1000;
  Ready := WinSock2.select(0, @ReadSet, nil, nil, @Timeout);
  if Ready > 0 then
    Result := WinSock2.accept(AListenSocket, nil, nil);
  {$ELSE}
  FpFD_ZERO(ReadSet);
  FpFD_SET(AListenSocket, ReadSet);
  Ready := FpSelect(AListenSocket + 1, @ReadSet, nil, nil,
    ATimeoutMilliseconds);
  if Ready > 0 then
    Result := FpAccept(AListenSocket, nil, nil);
  {$ENDIF}
end;

function ConnectLoopback(const APort: Word): TSocket;
{$IFDEF MSWINDOWS}
var
  Address: TSockAddrIn;
begin
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  if not TestSocketValid(Result) then
    raise Exception.Create('client socket() failed');
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := WinSock2.htons(APort);
  Address.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
  if WinSock2.connect(Result, PSockAddr(@Address), SizeOf(Address)) <> 0 then
  begin
    CloseTestSocket(Result);
    raise Exception.Create('client connect() failed');
  end;
end;
{$ELSE}
var
  Address: TInetSockAddr;
begin
  Result := FpSocket(AF_INET, SOCK_STREAM, 0);
  if not TestSocketValid(Result) then
    raise Exception.Create('client socket() failed');
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := HToNs(APort);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if FpConnect(Result, @Address, SizeOf(Address)) <> 0 then
  begin
    CloseTestSocket(Result);
    raise Exception.Create('client connect() failed');
  end;
end;
{$ENDIF}

{ ── fixtures ─────────────────────────────────────────────────────── }

function LoadFileBytes(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

{ DER bytes of the first CERTIFICATE block in a PEM file. }
function LoadCertificateDER(const APath: string): TBytes;
const
  PEM_BEGIN = '-----BEGIN CERTIFICATE-----';
  PEM_END = '-----END CERTIFICATE-----';
var
  BodyStart, BodyEnd: Integer;
  Decoded: AnsiString;
  Text: AnsiString;
  Raw: TBytes;
begin
  Result := nil;
  Raw := LoadFileBytes(APath);
  SetString(Text, PAnsiChar(@Raw[0]), Length(Raw));
  BodyStart := Pos(PEM_BEGIN, Text);
  BodyEnd := Pos(PEM_END, Text);
  if (BodyStart = 0) or (BodyEnd <= BodyStart) then
    raise Exception.CreateFmt('%s holds no PEM certificate', [APath]);
  Inc(BodyStart, Length(PEM_BEGIN));
  Decoded := DecodeStringBase64(StringReplace(StringReplace(
    Copy(Text, BodyStart, BodyEnd - BodyStart), #13, '', [rfReplaceAll]),
    #10, '', [rfReplaceAll]));
  SetLength(Result, Length(Decoded));
  if Length(Decoded) > 0 then
    Move(Decoded[1], Result[0], Length(Decoded));
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or (CompareByte(A[0], B[0], Length(A)) = 0));
end;

function AnchorsOnly(const APath: string): TTransportSecurityClientOptions;
begin
  Result := DefaultTransportSecurityClientOptions;
  Result.TrustAnchors := LoadFileBytes(APath);
  Result.TrustMode := tstmAnchorsOnly;
end;

function SystemAndAnchors(const APath: string): TTransportSecurityClientOptions;
begin
  Result := DefaultTransportSecurityClientOptions;
  Result.TrustAnchors := LoadFileBytes(APath);
  Result.TrustMode := tstmSystemAndAnchors;
end;

function InsecureOptions: TTransportSecurityClientOptions;
begin
  Result := DefaultTransportSecurityClientOptions;
  Result.InsecureSkipVerify := True;
end;

function ClientIdentityOptions: TTransportSecurityClientOptions;
begin
  Result := AnchorsOnly(TEST_ROOT_PATH);
  Result.ClientPkcs12 := LoadFileBytes(CLIENT_PKCS12_PATH);
  Result.ClientPkcs12Passphrase := PKCS12_PASSPHRASE;
end;

function RedirectResponse(const ALocation: string): AnsiString;
begin
  Result := AnsiString('HTTP/1.1 302 Found'#13#10'Location: ' + ALocation +
    #13#10'Content-Length: 0'#13#10'Connection: close'#13#10#13#10);
end;

{ ── loopback server ──────────────────────────────────────────────── }

constructor TLoopbackTLSServer.Create(const APkcs12Path: string;
  const AValidation: TTransportSecurityServerIdentityValidation;
  const AResponses: array of AnsiString;
  const ARequireClientCertificate: Boolean);
var
  I: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FListenSocket := INVALID_TEST_SOCKET;
  FClientAnchors := nil;
  if ARequireClientCertificate then
    FClientAnchors := LoadFileBytes(CLIENT_ROOT_PATH);
  SetLength(FResponses, Length(AResponses));
  for I := 0 to High(AResponses) do
    FResponses[I] := AResponses[I];
  SetLength(FResults, Length(AResponses));
  FContext := TTransportSecurityServerContext.Create(
    LoadFileBytes(APkcs12Path), PKCS12_PASSPHRASE, AValidation);
  try
    FListenSocket := CreateLoopbackListener(FPort);
  except
    CloseTransportSecurityServerContext(FContext);
    raise;
  end;
  Start;
end;

destructor TLoopbackTLSServer.Destroy;
begin
  Terminate;
  WaitFor;
  CloseTestSocket(FListenSocket);
  CloseTransportSecurityServerContext(FContext);
  inherited Destroy;
end;

procedure TLoopbackTLSServer.Join;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not Finished do
  begin
    if GetTickCount64 - StartedAt > SERVER_JOIN_MILLISECONDS then
    begin
      Terminate;
      raise Exception.Create('loopback TLS server did not finish');
    end;
    Sleep(1);
  end;
  WaitFor;
end;

procedure TLoopbackTLSServer.WaitServed(const ACount: Integer);
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while (FServed < ACount) and not Finished and
        (GetTickCount64 - StartedAt <= SERVER_JOIN_MILLISECONDS) do
    Sleep(1);
end;

function TLoopbackTLSServer.Outcome(const AIndex: Integer): TServedConnection;
begin
  Result := FResults[AIndex];
end;

procedure TLoopbackTLSServer.Flush(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection);
var
  Buffer: Pointer;
  Pending: Integer;
  Sent: Integer;
begin
  Pending := TransportSecurityGetCiphertext(AConnection, Buffer);
  if Pending <= 0 then
    Exit;
  Sent := TestSend(ASocket, Buffer, Pending);
  if Sent > 0 then
    TransportSecurityConsumeCiphertext(AConnection, Sent)
  else if (Sent < 0) and not TestSocketWouldBlock then
    raise Exception.Create('server send() failed');
end;

function TLoopbackTLSServer.Receive(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection): Boolean;
var
  Buffer: array[0..RECEIVE_CHUNK_SIZE - 1] of Byte;
  Flow: TTransportSecurityInputFlow;
  Received: Integer;
  Wanted: Integer;
begin
  Result := True;
  Flow := TransportSecurityServerInputFlow(AConnection);
  Wanted := Flow.HighWatermark - Flow.BufferedBytes;
  if Wanted > Length(Buffer) then
    Wanted := Length(Buffer);
  if Flow.Backpressured or (Wanted <= 0) then
    Exit;
  Received := TestReceive(ASocket, @Buffer[0], Wanted);
  if Received > 0 then
  begin
    if TransportSecurityFeedCiphertext(AConnection, @Buffer[0], Received) <>
       Received then
      raise Exception.Create('server ciphertext feed was partial');
  end
  else if Received = 0 then
    Result := False
  else if not TestSocketWouldBlock then
    raise Exception.Create('server recv() failed');
end;

procedure TLoopbackTLSServer.ServeOne(const ASocket: TSocket;
  const AIndex: Integer);
var
  Buffer: array[0..1023] of Byte;
  Chunk: AnsiString;
  Connection: TTransportSecurityConnection;
  Deadline: QWord;
  ReadResult: TTransportSecurityIOResult;
  Request: AnsiString;
  State: TTransportSecurityState;
  WriteResult: TTransportSecurityIOResult;
begin
  FillChar(Connection, SizeOf(Connection), 0);
  Deadline := GetTickCount64 + STEP_TIMEOUT_MILLISECONDS;
  BeginTransportSecurityServer(Connection, FContext);
  try
    if Length(FClientAnchors) > 0 then
      TransportSecurityTestRequireClientCertificate(Connection,
        FClientAnchors);
    repeat
      if Terminated or (GetTickCount64 > Deadline) then
        raise Exception.Create('server handshake timed out');
      if TransportSecurityPendingCiphertext(Connection) > 0 then
        Flush(ASocket, Connection)
      else
      begin
        State := TransportSecurityServerHandshake(Connection);
        case State of
          tssDone:
            if TransportSecurityPendingCiphertext(Connection) = 0 then
              Break;
          tssWantRead:
            if not Receive(ASocket, Connection) then
              raise Exception.Create('client closed during the handshake');
          tssWantWrite:
            Flush(ASocket, Connection);
        else
          raise Exception.Create('server handshake failed: ' +
            TransportSecurityServerFailureReason);
        end;
      end;
      Sleep(1);
    until False;
    FResults[AIndex].HandshakeSucceeded := True;

    Request := '';
    repeat
      if Terminated or (GetTickCount64 > Deadline) then
        raise Exception.Create('server read timed out');
      if TransportSecurityPendingCiphertext(Connection) > 0 then
        Flush(ASocket, Connection)
      else
      begin
        ReadResult := TransportSecurityServerRead(Connection, Buffer,
          Length(Buffer));
        if ReadResult.BytesProcessed > 0 then
        begin
          SetString(Chunk, PAnsiChar(@Buffer[0]), ReadResult.BytesProcessed);
          Request := Request + Chunk;
          if Pos(#13#10#13#10, Request) > 0 then
            Break;
        end;
        case ReadResult.State of
          tssDone:
            ;
          tssWantRead:
            if not Receive(ASocket, Connection) then
              raise Exception.Create('client closed before its request');
          tssWantWrite:
            Flush(ASocket, Connection);
        else
          raise Exception.Create('server read failed');
        end;
      end;
      Sleep(1);
    until False;

    WriteResult := TransportSecurityServerWrite(Connection,
      @FResponses[AIndex][1], Length(FResponses[AIndex]));
    if WriteResult.BytesProcessed <> Length(FResponses[AIndex]) then
      raise Exception.Create('server write did not take the response');
    while TransportSecurityPendingCiphertext(Connection) > 0 do
    begin
      if Terminated or (GetTickCount64 > Deadline) then
        raise Exception.Create('server write timed out');
      Flush(ASocket, Connection);
      Sleep(1);
    end;
    { Best-effort close_notify: the client may already have closed. }
    try
      if CloseTransportSecurityServerGracefully(Connection) <> tssError then
        Flush(ASocket, Connection);
    except
      on Exception do
        ;
    end;
  finally
    AbortTransportSecurityServer(Connection);
  end;
end;

procedure TLoopbackTLSServer.Execute;
var
  Accepted: TSocket;
  I: Integer;
begin
  for I := 0 to High(FResponses) do
  begin
    Accepted := INVALID_TEST_SOCKET;
    while not Terminated and not TestSocketValid(Accepted) do
      Accepted := AcceptWithin(FListenSocket, 50);
    if Terminated then
    begin
      CloseTestSocket(Accepted);
      Exit;
    end;
    try
      try
        SetTestSocketNonblocking(Accepted);
        ServeOne(Accepted, I);
      except
        on E: Exception do
          FResults[I].Error := E.Message;
      end;
    finally
      CloseTestSocket(Accepted);
      InterlockedIncrement(FServed);
    end;
  end;
end;

{ ── client helpers ───────────────────────────────────────────────── }

{ One request over the production client: returns the response text and the
  peer certificate observed right after the handshake. Raises whatever
  StartTransportSecurity or the transport raises. }
function ClientExchange(const APort: Word; const AHost: string;
  const AOptions: TTransportSecurityClientOptions;
  out APeerCertificate: TBytes): AnsiString;
var
  Buffer: array[0..1023] of Byte;
  Chunk: AnsiString;
  Connection: TTransportSecurityConnection;
  Offset: Integer;
  ReadCount: Integer;
  Request: AnsiString;
  Socket: TSocket;
  Written: Integer;
begin
  Result := '';
  APeerCertificate := nil;
  FillChar(Connection, SizeOf(Connection), 0);
  Socket := ConnectLoopback(APort);
  try
    SetTestSocketNonblocking(Socket);
    StartTransportSecurity(Connection, Socket, AHost, AOptions,
      GetTickCount64 + STEP_TIMEOUT_MILLISECONDS, STEP_TIMEOUT_MILLISECONDS);
    try
      APeerCertificate := TransportSecurityPeerCertificate(Connection);
      Request := CLIENT_REQUEST;
      Offset := 0;
      while Offset < Length(Request) do
      begin
        Written := TransportSecurityWrite(Connection, @Request[Offset + 1],
          Length(Request) - Offset);
        if Written <= 0 then
          raise ETransportSecurityError.Create('client write failed');
        Inc(Offset, Written);
      end;
      repeat
        ReadCount := TransportSecurityRead(Connection, Buffer,
          Length(Buffer));
        if ReadCount > 0 then
        begin
          SetString(Chunk, PAnsiChar(@Buffer[0]), ReadCount);
          Result := Result + Chunk;
        end;
      until (ReadCount <= 0) or (Length(Result) >= Length(OK_RESPONSE));
    finally
      CloseTransportSecurity(Connection);
    end;
  finally
    CloseTestSocket(Socket);
  end;
end;

{ Runs one exchange against a fresh single-connection server and returns
  the client's error message ('' on success) plus the server's record. }
function RunExchange(const APkcs12Path: string;
  const AValidation: TTransportSecurityServerIdentityValidation;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const ARequireClientCertificate: Boolean; out AResponse: AnsiString;
  out APeerCertificate: TBytes; out AServed: TServedConnection): string;
var
  Server: TLoopbackTLSServer;
begin
  Result := '';
  AResponse := '';
  APeerCertificate := nil;
  Server := TLoopbackTLSServer.Create(APkcs12Path, AValidation, [OK_RESPONSE],
    ARequireClientCertificate);
  try
    try
      AResponse := ClientExchange(Server.Port, AHost, AOptions,
        APeerCertificate);
    except
      on E: Exception do
        Result := E.Message;
    end;
    Server.Join;
    AServed := Server.Outcome(0);
  finally
    Server.Free;
  end;
end;

function Contains(const AText, AFragment: string): Boolean;
begin
  Result := Pos(LowerCase(AFragment), LowerCase(AText)) > 0;
end;

{ ── tests ────────────────────────────────────────────────────────── }

procedure TTransportSecurityClientOptionsE2ETests.TestAnchorsOnlyVerifiesConfiguredCA;
var
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  Expect<string>(RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    AnchorsOnly(TEST_ROOT_PATH), False, Response, Peer, Served)).ToBe('');
  Expect<Boolean>(GetTickCount64 - StartedAt <
    OFFLINE_VERIFICATION_BUDGET_MILLISECONDS).ToBe(True);
  Expect<string>(string(Response)).ToBe(OK_RESPONSE);
  Expect<Boolean>(Served.HandshakeSucceeded).ToBe(True);
  Expect<string>(Served.Error).ToBe('');
end;

procedure TTransportSecurityClientOptionsE2ETests.TestAnchorsOnlyRejectsUnrelatedCA;
var
  ErrorMessage: string;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  ErrorMessage := RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    AnchorsOnly(UNRELATED_ROOT_PATH), False, Response, Peer, Served);
  Expect<Boolean>(Contains(ErrorMessage, 'verification')).ToBe(True);
  Expect<string>(string(Response)).ToBe('');
  Expect<Boolean>(GetTickCount64 - StartedAt <
    OFFLINE_VERIFICATION_BUDGET_MILLISECONDS).ToBe(True);
end;

{ The client must reject the incomplete chain from the anchors alone,
  without trying the unreachable issuer, OCSP, or CRL URLs. Windows runs the
  equivalent check without a server (an SChannel server builds its own
  chain for the leaf, so it could fetch the URL itself). }
procedure TTransportSecurityClientOptionsE2ETests.TestAnchorsOnlyNeverFetchesUnreachableURLs;
{$IFNDEF MSWINDOWS}
var
  ErrorMessage: string;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
  StartedAt: QWord;
{$ENDIF}
begin
  {$IFNDEF MSWINDOWS}
  StartedAt := GetTickCount64;
  ErrorMessage := RunExchange(UNREACHABLE_AIA_PKCS12_PATH, tsivPermissive,
    'localhost', AnchorsOnly(TEST_ROOT_PATH), False, Response, Peer, Served);
  Expect<Boolean>(Contains(ErrorMessage, 'verification')).ToBe(True);
  Expect<Boolean>(GetTickCount64 - StartedAt <
    OFFLINE_VERIFICATION_BUDGET_MILLISECONDS).ToBe(True);
  {$ENDIF}
end;

procedure TTransportSecurityClientOptionsE2ETests.TestSystemAndAnchorsVerifiesConfiguredCA;
var
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  Expect<string>(RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    SystemAndAnchors(TEST_ROOT_PATH), False, Response, Peer, Served)).ToBe('');
  Expect<string>(string(Response)).ToBe(OK_RESPONSE);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestSystemAndAnchorsRejectsUnrelatedCA;
var
  ErrorMessage: string;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  ErrorMessage := RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    SystemAndAnchors(UNRELATED_ROOT_PATH), False, Response, Peer, Served);
  Expect<Boolean>(Contains(ErrorMessage, 'verification')).ToBe(True);
  Expect<string>(string(Response)).ToBe('');
end;

procedure TTransportSecurityClientOptionsE2ETests.TestPeerCertificateIsServerLeaf;
var
  Idle: TTransportSecurityConnection;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  FillChar(Idle, SizeOf(Idle), 0);
  Expect<Integer>(Length(TransportSecurityPeerCertificate(Idle))).ToBe(0);
  Expect<string>(RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    AnchorsOnly(TEST_ROOT_PATH), False, Response, Peer, Served)).ToBe('');
  Expect<Boolean>(Length(Peer) > 0).ToBe(True);
  Expect<Boolean>(SameBytes(Peer, LoadCertificateDER(SERVER_LEAF_PATH)))
    .ToBe(True);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestClientIdentitySatisfiesRequiringServer;
var
  ClientError: string;
  Options: TTransportSecurityClientOptions;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  Options := ClientIdentityOptions;
  ClientError := RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    Options, True, Response, Peer, Served);
  { The server's record comes first: it carries the backend's reason. }
  Expect<string>(Served.Error).ToBe('');
  Expect<string>(ClientError).ToBe('');
  Expect<string>(string(Response)).ToBe(OK_RESPONSE);
  Expect<Boolean>(Served.HandshakeSucceeded).ToBe(True);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestRequiringServerRefusesAnonymousClient;
var
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  { Under TLS 1.3 the client finishes its handshake before the server
    judges the empty certificate, so the refusal can surface on the first
    read instead of in StartTransportSecurity. The server's record is the
    authoritative outcome either way. }
  RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost',
    AnchorsOnly(TEST_ROOT_PATH), True, Response, Peer, Served);
  Expect<Boolean>(Served.HandshakeSucceeded).ToBe(False);
  Expect<Boolean>(Served.Error <> '').ToBe(True);
  Expect<Boolean>(Response = OK_RESPONSE).ToBe(False);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestRequiringServerRefusesForeignClientIdentity;
var
  Options: TTransportSecurityClientOptions;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  { The server validates the chain instead of accepting any certificate: a
    well-formed clientAuth identity from another hierarchy is refused. }
  Options := AnchorsOnly(TEST_ROOT_PATH);
  Options.ClientPkcs12 := LoadFileBytes(FOREIGN_CLIENT_PKCS12_PATH);
  Options.ClientPkcs12Passphrase := PKCS12_PASSPHRASE;
  RunExchange(SERVER_PKCS12_PATH, tsivStrict, 'localhost', Options, True,
    Response, Peer, Served);
  Expect<Boolean>(Served.HandshakeSucceeded).ToBe(False);
  Expect<Boolean>(Served.Error <> '').ToBe(True);
  Expect<Boolean>(Response = OK_RESPONSE).ToBe(False);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestInsecureSkipVerifyAcceptsSelfSignedServer;
var
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  Expect<string>(RunExchange(SELF_SIGNED_PKCS12_PATH, tsivPermissive,
    'localhost', InsecureOptions, False, Response, Peer, Served)).ToBe('');
  Expect<string>(string(Response)).ToBe(OK_RESPONSE);
  { The self-signed development identity is the test root itself. }
  Expect<Boolean>(SameBytes(Peer, LoadCertificateDER(TEST_ROOT_PATH)))
    .ToBe(True);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestSelfSignedServerFailsWithoutInsecureSkipVerify;
var
  ErrorMessage: string;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  ErrorMessage := RunExchange(SELF_SIGNED_PKCS12_PATH, tsivPermissive,
    'localhost', DefaultTransportSecurityClientOptions, False, Response, Peer,
    Served);
  Expect<Boolean>(ErrorMessage <> '').ToBe(True);
  Expect<string>(string(Response)).ToBe('');
end;

procedure TTransportSecurityClientOptionsE2ETests.TestInsecureSkipVerifyAcceptsHostMismatch;
var
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  Expect<string>(RunExchange(SERVER_PKCS12_PATH, tsivStrict, MISMATCHED_HOST,
    InsecureOptions, False, Response, Peer, Served)).ToBe('');
  Expect<string>(string(Response)).ToBe(OK_RESPONSE);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHostMismatchFailsVerification;
var
  ErrorMessage: string;
  Peer: TBytes;
  Response: AnsiString;
  Served: TServedConnection;
begin
  { The chain is trusted, so only the host name can fail. }
  ErrorMessage := RunExchange(SERVER_PKCS12_PATH, tsivStrict, MISMATCHED_HOST,
    AnchorsOnly(TEST_ROOT_PATH), False, Response, Peer, Served);
  Expect<Boolean>(Contains(ErrorMessage, 'verification')).ToBe(True);
  Expect<string>(string(Response)).ToBe('');
end;

function BodyText(const AResponse: THTTPResponse): string;
var
  Text: AnsiString;
begin
  Text := '';
  if Length(AResponse.Body) > 0 then
    SetString(Text, PAnsiChar(@AResponse.Body[0]), Length(AResponse.Body));
  Result := string(Text);
end;

function HTTPSOptions(const ATLS: TTransportSecurityClientOptions):
  THTTPRequestOptions;
begin
  Result := DefaultHTTPRequestOptions;
  Result.RequestTimeoutMilliseconds := STEP_TIMEOUT_MILLISECONDS;
  Result.ConnectAddress := '127.0.0.1';
  Result.TLS := ATLS;
end;

{ Runs HTTPGet against a server that expects one connection and returns the
  EHTTPError message ('' on success) and the number of connections the
  server accepted. }
function HTTPClientErrorAndConnections(
  const ATLS: TTransportSecurityClientOptions; out AAccepted: Integer):
  string;
var
  Server: TLoopbackTLSServer;
begin
  Result := '';
  Server := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [OK_RESPONSE]);
  try
    try
      HTTPGet('https://localhost:' + IntToStr(Server.Port) + '/', nil,
        HTTPSOptions(ATLS));
    except
      on E: EHTTPError do
        Result := E.Message;
    end;
    { Give a stray connection time to land before counting. }
    Sleep(100);
    AAccepted := Server.Served;
  finally
    Server.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientTrustsPrivateCA;
var
  Response: THTTPResponse;
  Server: TLoopbackTLSServer;
begin
  Server := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [OK_RESPONSE]);
  try
    Response := HTTPGet('https://localhost:' + IntToStr(Server.Port) + '/',
      nil, HTTPSOptions(AnchorsOnly(TEST_ROOT_PATH)));
    Server.Join;
    Expect<Integer>(Response.StatusCode).ToBe(200);
    Expect<string>(BodyText(Response)).ToBe(RESPONSE_BODY);
  finally
    Server.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientSameOriginRedirectKeepsOptions;
var
  Response: THTTPResponse;
  Server: TLoopbackTLSServer;
begin
  Server := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [RedirectResponse('/next'), OK_RESPONSE]);
  try
    { ConnectAddress pins only the first hop; the relative redirect keeps
      the origin, resolves localhost, and must still trust the private CA. }
    Response := HTTPGet('https://localhost:' + IntToStr(Server.Port) + '/',
      nil, HTTPSOptions(AnchorsOnly(TEST_ROOT_PATH)));
    Server.Join;
    Expect<Integer>(Response.StatusCode).ToBe(200);
    Expect<Boolean>(Response.Redirected).ToBe(True);
    Expect<Boolean>(Server.Outcome(1).HandshakeSucceeded).ToBe(True);
  finally
    Server.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientCrossOriginRedirectDropsOptions;
var
  Failed: Boolean;
  Origin, Target: TLoopbackTLSServer;
begin
  Target := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [OK_RESPONSE]);
  try
    Origin := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
      [RedirectResponse('https://localhost:' + IntToStr(Target.Port) + '/')]);
    try
      Failed := False;
      try
        HTTPGet('https://localhost:' + IntToStr(Origin.Port) + '/', nil,
          HTTPSOptions(AnchorsOnly(TEST_ROOT_PATH)));
      except
        on EHTTPError do
          Failed := True;
      end;
      Origin.Join;
      Target.Join;
      { The same private CA serves both ports; only the dropped anchors can
        make the second hop fail. The target never receives a request: its
        handshake fails, or (on backends that finish the handshake before
        judging the peer) the client closes before sending one. }
      Expect<Boolean>(Failed).ToBe(True);
      Expect<Boolean>(Origin.Outcome(0).HandshakeSucceeded).ToBe(True);
      Expect<Integer>(Target.Served).ToBe(1);
      Expect<Boolean>(Target.Outcome(0).Error <> '').ToBe(True);
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientRejectsInvalidOptionsBeforeConnecting;
var
  ErrorMessage: string;
  Options: THTTPRequestOptions;
  Server: TLoopbackTLSServer;
begin
  Server := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [OK_RESPONSE]);
  try
    Options := HTTPSOptions(DefaultTransportSecurityClientOptions);
    Options.TLS.TrustMode := tstmAnchorsOnly;
    ErrorMessage := '';
    try
      HTTPGet('https://localhost:' + IntToStr(Server.Port) + '/', nil,
        Options);
    except
      on E: EHTTPError do
        ErrorMessage := E.Message;
    end;
    Expect<Boolean>(Contains(ErrorMessage, 'anchors-only')).ToBe(True);
    Expect<Integer>(Server.Served).ToBe(0);
  finally
    Server.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientRejectsMalformedAnchorBeforeConnecting;
var
  Accepted: Integer;
  ErrorMessage: string;
  Options: TTransportSecurityClientOptions;
begin
  { An empty SEQUENCE passes the structural DER check; only a native parse
    rejects it. }
  Options := DefaultTransportSecurityClientOptions;
  SetLength(Options.TrustAnchors, 2);
  Options.TrustAnchors[0] := $30;
  Options.TrustAnchors[1] := $00;
  Options.TrustMode := tstmAnchorsOnly;
  ErrorMessage := HTTPClientErrorAndConnections(Options, Accepted);
  Expect<Boolean>(Contains(ErrorMessage, 'not a valid X.509 certificate'))
    .ToBe(True);
  Expect<Integer>(Accepted).ToBe(0);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientRejectsCorruptIdentityBeforeConnecting;
var
  Accepted: Integer;
  ErrorMessage: string;
  Options: TTransportSecurityClientOptions;
begin
  Options := ClientIdentityOptions;
  SetLength(Options.ClientPkcs12, Length(Options.ClientPkcs12) div 2);
  ErrorMessage := HTTPClientErrorAndConnections(Options, Accepted);
  Expect<Boolean>(ErrorMessage <> '').ToBe(True);
  Expect<Integer>(Accepted).ToBe(0);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientRejectsWrongPassphraseBeforeConnecting;
var
  Accepted: Integer;
  ErrorMessage: string;
  Options: TTransportSecurityClientOptions;
begin
  Options := ClientIdentityOptions;
  Options.ClientPkcs12Passphrase := 'not-the-passphrase';
  ErrorMessage := HTTPClientErrorAndConnections(Options, Accepted);
  Expect<Boolean>(Contains(ErrorMessage, 'passphrase')).ToBe(True);
  Expect<Integer>(Accepted).ToBe(0);
end;

{ Live network: a publicly trusted host is the only way to show that
  anchors-only ignores the platform store while system-plus-anchors keeps
  it. Self-skips unless LWPT_ENABLE_NETWORK=1, and on a clean resolve or
  connect failure, like the other live-network programs. }
procedure TTransportSecurityClientOptionsE2ETests.TestLiveTrustModesDifferOnSystemStore;
var
  AnchorsOnlyError: string;
  Options: THTTPRequestOptions;
  Unreachable: string;
begin
  if GetEnvironmentVariable('LWPT_ENABLE_NETWORK') <> '1' then
  begin
    WriteLn('  [skip] LWPT_ENABLE_NETWORK=1 not set; live trust-mode check skipped');
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  Options := DefaultHTTPRequestOptions;
  Options.RequestTimeoutMilliseconds := 30000;
  Options.MaximumRedirects := 0;
  Unreachable := '';
  try
    HTTPHead(LIVE_HTTPS_URL, nil, Options);
  except
    on E: EHTTPError do
      if Contains(E.Message, 'resolve') or Contains(E.Message, 'connect') or
         Contains(E.Message, 'deadline') then
        Unreachable := E.Message
      else
        raise;
  end;
  if Unreachable <> '' then
  begin
    WriteLn('  [skip] ', LIVE_HTTPS_URL, ' unreachable: ', Unreachable);
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;

  Options.TLS := SystemAndAnchors(UNRELATED_ROOT_PATH);
  HTTPHead(LIVE_HTTPS_URL, nil, Options);

  AnchorsOnlyError := '';
  Options.TLS := AnchorsOnly(UNRELATED_ROOT_PATH);
  try
    HTTPHead(LIVE_HTTPS_URL, nil, Options);
  except
    on E: EHTTPError do
      AnchorsOnlyError := E.Message;
  end;
  Expect<Boolean>(Contains(AnchorsOnlyError, 'verification')).ToBe(True);
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientSameOriginRedirectKeepsInsecureMode;
var
  Response: THTTPResponse;
  Server: TLoopbackTLSServer;
begin
  Server := TLoopbackTLSServer.Create(SELF_SIGNED_PKCS12_PATH, tsivPermissive,
    [RedirectResponse('/next'), OK_RESPONSE]);
  try
    Response := HTTPGet('https://localhost:' + IntToStr(Server.Port) + '/',
      nil, HTTPSOptions(InsecureOptions));
    Server.Join;
    Expect<Integer>(Response.StatusCode).ToBe(200);
    Expect<Boolean>(Response.Redirected).ToBe(True);
    Expect<string>(Server.Outcome(1).Error).ToBe('');
  finally
    Server.Free;
  end;
end;

{ Cross-origin cases assert on the target server, which never receives a
  request when the option was dropped. On OpenSSL the option-less client
  completes the handshake before judging the peer, so the target's record
  distinguishes a dropped option from a carried one. }
procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientCrossOriginRedirectDropsInsecureMode;
var
  Failed: Boolean;
  Origin, Target: TLoopbackTLSServer;
begin
  Target := TLoopbackTLSServer.Create(SELF_SIGNED_PKCS12_PATH, tsivPermissive,
    [OK_RESPONSE]);
  try
    Origin := TLoopbackTLSServer.Create(SELF_SIGNED_PKCS12_PATH,
      tsivPermissive,
      [RedirectResponse('https://localhost:' + IntToStr(Target.Port) + '/')]);
    try
      Failed := False;
      try
        HTTPGet('https://localhost:' + IntToStr(Origin.Port) + '/', nil,
          HTTPSOptions(InsecureOptions));
      except
        on EHTTPError do
          Failed := True;
      end;
      Origin.Join;
      Target.Join;
      Expect<Boolean>(Failed).ToBe(True);
      Expect<string>(Origin.Outcome(0).Error).ToBe('');
      Expect<Integer>(Target.Served).ToBe(1);
      Expect<Boolean>(Target.Outcome(0).Error <> '').ToBe(True);
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientSameOriginRedirectKeepsClientIdentity;
var
  ClientError: string;
  Response: THTTPResponse;
  Server: TLoopbackTLSServer;
begin
  Server := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [RedirectResponse('/next'), OK_RESPONSE], True);
  try
    ClientError := '';
    try
      Response := HTTPGet('https://localhost:' + IntToStr(Server.Port) +
        '/', nil, HTTPSOptions(ClientIdentityOptions));
    except
      on E: EHTTPError do
        ClientError := E.Message;
    end;
    if ClientError <> '' then
    begin
      { The first hop failed, so the second connection never comes. }
      Server.WaitServed(1);
      Server.Terminate;
      Expect<string>(Server.Outcome(0).Error).ToBe('');
      Expect<string>(ClientError).ToBe('');
    end;
    Server.Join;
    Expect<Integer>(Response.StatusCode).ToBe(200);
    Expect<Boolean>(Response.Redirected).ToBe(True);
    Expect<Boolean>(Server.Outcome(1).HandshakeSucceeded).ToBe(True);
  finally
    Server.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.TestHTTPClientCrossOriginRedirectDropsClientIdentity;
var
  Failed: Boolean;
  Origin, Target: TLoopbackTLSServer;
begin
  Target := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
    [OK_RESPONSE], True);
  try
    Origin := TLoopbackTLSServer.Create(SERVER_PKCS12_PATH, tsivStrict,
      [RedirectResponse('https://localhost:' + IntToStr(Target.Port) + '/')],
      True);
    try
      Failed := False;
      try
        HTTPGet('https://localhost:' + IntToStr(Origin.Port) + '/', nil,
          HTTPSOptions(ClientIdentityOptions));
      except
        on EHTTPError do
          Failed := True;
      end;
      Origin.Join;
      { The origin hop must succeed with the identity before the target's
        outcome means anything; its record carries the backend's reason. }
      Expect<string>(Origin.Outcome(0).Error).ToBe('');
      Expect<Boolean>(Origin.Outcome(0).HandshakeSucceeded).ToBe(True);
      Target.Join;
      { A carried identity would let the target's handshake succeed on
        every backend where the client finishes before judging the peer;
        without it the requiring target refuses the handshake itself. }
      Expect<Boolean>(Failed).ToBe(True);
      Expect<Integer>(Target.Served).ToBe(1);
      Expect<Boolean>(Target.Outcome(0).HandshakeSucceeded).ToBe(False);
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

procedure TTransportSecurityClientOptionsE2ETests.SetupTests;
begin
  Test('anchors-only trust verifies a server issued by the configured CA',
    TestAnchorsOnlyVerifiesConfiguredCA);
  Test('anchors-only trust rejects an unrelated CA as a verification failure',
    TestAnchorsOnlyRejectsUnrelatedCA);
  {$IFDEF MSWINDOWS}
  Skip('anchors-only verification never fetches unreachable certificate URLs',
    TestAnchorsOnlyNeverFetchesUnreachableURLs,
    'covered server-less by TransportSecurity.Test on Windows');
  {$ELSE}
  Test('anchors-only verification never fetches unreachable certificate URLs',
    TestAnchorsOnlyNeverFetchesUnreachableURLs);
  {$ENDIF}
  Test('system-plus-anchors trust verifies the configured CA',
    TestSystemAndAnchorsVerifiesConfiguredCA);
  Test('system-plus-anchors trust still rejects an unrelated CA',
    TestSystemAndAnchorsRejectsUnrelatedCA);
  Test('peer certificate query returns the server leaf DER',
    TestPeerCertificateIsServerLeaf);
  Test('client identity satisfies a server that requires a certificate',
    TestClientIdentitySatisfiesRequiringServer);
  Test('a server that requires a certificate refuses an anonymous client',
    TestRequiringServerRefusesAnonymousClient);
  Test('InsecureSkipVerify connects to a self-signed server',
    TestInsecureSkipVerifyAcceptsSelfSignedServer);
  Test('a self-signed server fails without InsecureSkipVerify',
    TestSelfSignedServerFailsWithoutInsecureSkipVerify);
  Test('InsecureSkipVerify tolerates a host-name mismatch',
    TestInsecureSkipVerifyAcceptsHostMismatch);
  Test('a host-name mismatch fails verification without InsecureSkipVerify',
    TestHostMismatchFailsVerification);
  Test('HTTPClient trusts a private CA through request TLS options',
    TestHTTPClientTrustsPrivateCA);
  Test('HTTPClient keeps TLS options across a same-origin redirect',
    TestHTTPClientSameOriginRedirectKeepsOptions);
  Test('HTTPClient drops TLS options on a cross-origin redirect',
    TestHTTPClientCrossOriginRedirectDropsOptions);
  Test('HTTPClient rejects invalid TLS options before connecting',
    TestHTTPClientRejectsInvalidOptionsBeforeConnecting);
  Test('a validating server refuses a client identity from another hierarchy',
    TestRequiringServerRefusesForeignClientIdentity);
  Test('HTTPClient rejects a natively malformed anchor before connecting',
    TestHTTPClientRejectsMalformedAnchorBeforeConnecting);
  Test('HTTPClient rejects a corrupt client identity before connecting',
    TestHTTPClientRejectsCorruptIdentityBeforeConnecting);
  Test('HTTPClient rejects a wrong identity passphrase before connecting',
    TestHTTPClientRejectsWrongPassphraseBeforeConnecting);
  Test('live: anchors-only ignores the system store, system-plus-anchors keeps it',
    TestLiveTrustModesDifferOnSystemStore);
  Test('HTTPClient keeps InsecureSkipVerify across a same-origin redirect',
    TestHTTPClientSameOriginRedirectKeepsInsecureMode);
  Test('HTTPClient drops InsecureSkipVerify on a cross-origin redirect',
    TestHTTPClientCrossOriginRedirectDropsInsecureMode);
  Test('HTTPClient keeps the client identity across a same-origin redirect',
    TestHTTPClientSameOriginRedirectKeepsClientIdentity);
  Test('HTTPClient drops the client identity on a cross-origin redirect',
    TestHTTPClientCrossOriginRedirectDropsClientIdentity);
end;

{$IFDEF MSWINDOWS}
var
  WSAData: TWSAData;
{$ENDIF}
begin
  {$IFDEF UNIX}
  { A peer that closes first must surface as EPIPE, not kill the runner. }
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if WinSock2.WSAStartup($0202, WSAData) <> 0 then
    raise Exception.Create('WSAStartup failed');
  {$ENDIF}
  TestRunnerProgram.AddSuite(TTransportSecurityClientOptionsE2ETests.Create(
    'TransportSecurity: client options E2E'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
