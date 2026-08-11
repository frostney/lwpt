{ TransportSecuritySocket.E2E.Test -- Linux loopback coverage for the
  caller-owned nonblocking memory-BIO server reactor. }

program TransportSecuritySocket.E2E.Test;

{$mode delphi}{$H+}

{$IFDEF LINUX}
uses
  {$IFDEF UNIX}
  cthreads, { must come first so the server TThread has a thread driver }
  {$ENDIF}
  BaseUnix,
  Classes,
  SysUtils,

  DynLibs,
  OpenSSL,
  Sockets,
  TestingPascalLibrary,
  TransportSecurity;

const
  CLIENT_REQUEST = 'fragmented loopback request';
  SERVER_RESPONSE = 'short-write loopback response';
  PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-test-identity.p12';
  PKCS12_PASSPHRASE = 'test-only';
  ROOT_CERTIFICATE_PATH =
    'packages/httpclient/source/fixtures/test-root-cert.pem';
  RECEIVE_FRAGMENT_SIZE = 3;
  SEND_FRAGMENT_SIZE = 7;
  MAX_REACTOR_STEPS = 20000;
  HANDSHAKE_TIMEOUT_MILLISECONDS = 3000;
  HANDSHAKE_INPUT_BYTE_BUDGET = 64 * 1024;
  BUDGET_PROBE_INPUT_BYTE_BUDGET = 2;
  SERVER_COMPLETION_GRACE_MILLISECONDS = 1000;
  SERVER_STOP_TIMEOUT_MILLISECONDS = 1000;
  { MSG_NOSIGNAL keeps send() to an already-closed peer from raising SIGPIPE;
    the production client closes as soon as it has the full response, so the
    server can legitimately meet a gone peer while flushing close_notify. }
  SEND_NOSIGNAL_FLAG = $4000;

type
  TBIONewFile = function(AFilename, AMode: PAnsiChar): Pointer; cdecl;

  EHandshakeDeadlineExceeded = class(Exception);
  EHandshakeInputBudgetExceeded = class(Exception);

  TServerScenario = (
    ssRoundTrip,
    ssStalledHandshake,
    ssInputBudgetExceeded
  );

  TLoopbackTLSServer = class(TThread)
  private
    FContext: TTransportSecurityServerContext;
    FContextOwned: Boolean;
    FCiphertextBytesFed: QWord;
    FCiphertextBytesRead: QWord;
    FErrorMessage: string;
    FHandshakeElapsed: QWord;
    FHandshakeCiphertextBytesRead: QWord;
    FHandshakeInputByteBudget: QWord;
    FHandshakeInputBudgetExceeded: Boolean;
    FHandshakeStartedAt: QWord;
    FHandshakeTimedOut: Boolean;
    FClientSocket: TSocket;
    FListenSocket: TSocket;
    FPeerGone: Boolean;
    FPort: Word;
    FRequest: string;
    FScenario: TServerScenario;
    FStarted: Boolean;
    FSawFragmentedInput: Boolean;
    FSawShortWrite: Boolean;
    function FlushOneCiphertextFragment(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection;
      const AAllowPeerClosed: Boolean = False): Boolean;
    function ReceiveOneCiphertextFragment(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection): Boolean;
    procedure DriveClose(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection);
    procedure DriveHandshake(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection);
    procedure DriveRead(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection);
    procedure DriveWrite(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection);
    procedure Stop;
    function WaitUntilFinished(const ATimeoutMilliseconds: QWord): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AScenario: TServerScenario = ssRoundTrip);
    destructor Destroy; override;
    procedure Start; reintroduce;
    procedure WaitForCompletion(const ATimeoutMilliseconds: QWord);
    property CiphertextBytesFed: QWord read FCiphertextBytesFed;
    property CiphertextBytesRead: QWord read FCiphertextBytesRead;
    property ErrorMessage: string read FErrorMessage;
    property HandshakeElapsed: QWord read FHandshakeElapsed;
    property HandshakeCiphertextBytesRead: QWord
      read FHandshakeCiphertextBytesRead;
    property HandshakeInputBudgetExceeded: Boolean
      read FHandshakeInputBudgetExceeded;
    property HandshakeTimedOut: Boolean read FHandshakeTimedOut;
    property Port: Word read FPort;
    property Request: string read FRequest;
    property SawFragmentedInput: Boolean read FSawFragmentedInput;
    property SawShortWrite: Boolean read FSawShortWrite;
  end;

  TTransportSecuritySocketE2ETests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestHandshakeInputBudgetAbortsBeforeFeed;
    procedure TestLoopbackAcceptReadWriteClose;
    procedure TestStalledHandshakeAbortsWithinDeadline;
  end;

function SetEnvironmentVariable(const AName, AValue: PAnsiChar;
  const AOverwrite: Integer): Integer; cdecl; external 'c' name 'setenv';

procedure SetNonblocking(const ASocket: TSocket);
var
  Flags: LongInt;
begin
  Flags := FpFcntl(ASocket, F_GETFL, 0);
  if (Flags < 0) or (FpFcntl(ASocket, F_SETFL, Flags or O_NONBLOCK) < 0) then
    raise Exception.Create('fcntl(O_NONBLOCK) failed');
end;

function SocketWouldBlock: Boolean; inline;
begin
  Result := (FpGetErrno = ESysEAGAIN) or (FpGetErrno = ESysEWOULDBLOCK);
end;

{ The production client (CloseTransportSecurity) sends its own close_notify and
  closes the socket without waiting for the server's. A server flush that lands
  after that close sees EPIPE/ECONNRESET -- a benign end-of-connection here, not
  a transport failure. }
function SocketPeerClosed: Boolean; inline;
begin
  Result := (FpGetErrno = ESysEPIPE) or (FpGetErrno = ESysECONNRESET);
end;

procedure CloseOwnedSocket(var ASocket: TSocket);
var
  Socket: TSocket;
begin
  Socket := InterlockedExchange(ASocket, TSocket(-1));
  if Socket < 0 then
    Exit;
  FpShutdown(Socket, 2);
  CloseSocket(Socket);
end;

constructor TLoopbackTLSServer.Create(const AScenario: TServerScenario);
var
  Address: TInetSockAddr;
  AddressLength: TSocklen;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FScenario := AScenario;
  FHandshakeInputByteBudget := HANDSHAKE_INPUT_BYTE_BUDGET;
  if FScenario = ssInputBudgetExceeded then
    FHandshakeInputByteBudget := BUDGET_PROBE_INPUT_BYTE_BUDGET;
  FClientSocket := -1;
  FListenSocket := -1;
  FContext := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FContextOwned := True;
  try
    FListenSocket := FpSocket(AF_INET, SOCK_STREAM, 0);
    if FListenSocket < 0 then
      raise Exception.Create('socket() failed');
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := 0;
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if FpBind(FListenSocket, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('bind() failed');
    if FpListen(FListenSocket, 1) <> 0 then
      raise Exception.Create('listen() failed');
    AddressLength := SizeOf(Address);
    if FpGetSockName(FListenSocket, @Address, @AddressLength) <> 0 then
      raise Exception.Create('getsockname() failed');
    FPort := NToHs(Address.sin_port);
  except
    if FListenSocket >= 0 then
      CloseSocket(FListenSocket);
    FListenSocket := -1;
    CloseTransportSecurityServerContext(FContext);
    FContextOwned := False;
    raise;
  end;
end;

destructor TLoopbackTLSServer.Destroy;
var
  StopFailed: Boolean;
begin
  StopFailed := False;
  if FStarted then
  begin
    Stop;
    StopFailed := not WaitUntilFinished(SERVER_STOP_TIMEOUT_MILLISECONDS);
    if StopFailed then
    begin
      WriteLn(ErrOutput, 'TLS server thread failed to stop during cleanup');
      Halt(1);
    end;
    WaitFor;
  end
  else if FListenSocket >= 0 then
    CloseOwnedSocket(FListenSocket);
  if FContextOwned then
  begin
    CloseTransportSecurityServerContext(FContext);
    FContextOwned := False;
  end;
  inherited Destroy;
end;

procedure TLoopbackTLSServer.Start;
begin
  inherited Start;
  FStarted := True;
end;

procedure TLoopbackTLSServer.Stop;
var
  ClientSocket: TSocket;
begin
  Terminate;
  CloseOwnedSocket(FListenSocket);
  ClientSocket := InterlockedExchange(FClientSocket, -1);
  if ClientSocket >= 0 then
    FpShutdown(ClientSocket, 2);
end;

function TLoopbackTLSServer.WaitUntilFinished(
  const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    Result := Finished;
    if Result then
      Exit;
    Sleep(1);
  until GetTickCount64 - StartedAt >= ATimeoutMilliseconds;
  Result := Finished;
end;

procedure TLoopbackTLSServer.WaitForCompletion(
  const ATimeoutMilliseconds: QWord);
begin
  if WaitUntilFinished(ATimeoutMilliseconds) then
  begin
    WaitFor;
    Exit;
  end;
  Stop;
  if not WaitUntilFinished(SERVER_STOP_TIMEOUT_MILLISECONDS) then
    raise Exception.Create('TLS server thread failed to stop after timeout');
  WaitFor;
  raise Exception.Create('TLS server thread exceeded its completion deadline');
end;

function TLoopbackTLSServer.FlushOneCiphertextFragment(
  const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection;
  const AAllowPeerClosed: Boolean): Boolean;
var
  Buffer: Pointer;
  Pending: Integer;
  SendLength: Integer;
  Sent: Integer;
begin
  Result := False;
  Pending := TransportSecurityGetCiphertext(AConnection, Buffer);
  if Pending <= 0 then
    Exit;
  SendLength := Pending;
  if SendLength > SEND_FRAGMENT_SIZE then
    SendLength := SEND_FRAGMENT_SIZE;
  Sent := FpSend(ASocket, Buffer, SendLength, SEND_NOSIGNAL_FLAG);
  if Sent > 0 then
  begin
    TransportSecurityConsumeCiphertext(AConnection, Sent);
    FSawShortWrite := FSawShortWrite or (Sent < Pending);
    Result := True;
  end
  else if Sent < 0 then
  begin
    { Peer-gone tolerance is close-phase-only: the client cannot have read
      the full response until every response byte was flushed, so EPIPE
      during handshake, read, or write still marks a real failure. }
    if SocketPeerClosed and AAllowPeerClosed then
      FPeerGone := True
    else if not SocketWouldBlock then
      raise Exception.Create('send() failed');
  end;
end;

function TLoopbackTLSServer.ReceiveOneCiphertextFragment(
  const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection): Boolean;
var
  Buffer: array[0..RECEIVE_FRAGMENT_SIZE - 1] of Byte;
  FeedLength: Integer;
  Flow: TTransportSecurityInputFlow;
  Received: Integer;
  ReceiveLength: Integer;
begin
  Result := False;
  Flow := TransportSecurityServerInputFlow(AConnection);
  if Flow.Backpressured then
    Exit;
  ReceiveLength := Flow.HighWatermark - Flow.BufferedBytes;
  if ReceiveLength > Length(Buffer) then
    ReceiveLength := Length(Buffer);
  if ReceiveLength <= 0 then
    Exit;
  Received := FpRecv(ASocket, @Buffer[0], ReceiveLength, 0);
  if Received > 0 then
  begin
    Inc(FCiphertextBytesRead, QWord(Received));
    if not AConnection.Active then
    begin
      Inc(FHandshakeCiphertextBytesRead, QWord(Received));
      if FHandshakeCiphertextBytesRead > FHandshakeInputByteBudget then
        raise EHandshakeInputBudgetExceeded.Create(
          'TLS server handshake byte budget exceeded');
    end;
    FeedLength := TransportSecurityFeedCiphertext(AConnection, @Buffer[0],
      Received);
    if FeedLength <> Received then
      raise Exception.Create('TLS ciphertext feed was partial');
    Inc(FCiphertextBytesFed, QWord(FeedLength));
    FSawFragmentedInput := True;
    Result := True;
  end
  else if Received = 0 then
    raise Exception.Create('peer closed without TLS close_notify')
  else if not SocketWouldBlock then
    raise Exception.Create('recv() failed');
end;

procedure TLoopbackTLSServer.DriveHandshake(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection);
var
  State: TTransportSecurityState;
  Step: Integer;
begin
  FHandshakeStartedAt := GetTickCount64;
  for Step := 1 to MAX_REACTOR_STEPS do
  begin
    if Terminated then
      Exit;
    FHandshakeElapsed := GetTickCount64 - FHandshakeStartedAt;
    if FHandshakeElapsed >= HANDSHAKE_TIMEOUT_MILLISECONDS then
      raise EHandshakeDeadlineExceeded.Create(
        'TLS server handshake deadline exceeded');
    if TransportSecurityPendingCiphertext(AConnection) > 0 then
      FlushOneCiphertextFragment(ASocket, AConnection)
    else
    begin
      State := TransportSecurityServerHandshake(AConnection);
      case State of
        tssDone:
          if TransportSecurityPendingCiphertext(AConnection) = 0 then
            Exit;
        tssWantRead:
          ReceiveOneCiphertextFragment(ASocket, AConnection);
        tssWantWrite:
          FlushOneCiphertextFragment(ASocket, AConnection);
      else
        raise Exception.Create('TLS server handshake failed');
      end;
    end;
    Sleep(1);
  end;
  raise Exception.Create('TLS server handshake timed out');
end;

procedure TLoopbackTLSServer.DriveRead(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection);
var
  Buffer: array[0..255] of Byte;
  Chunk: string;
  ReadResult: TTransportSecurityIOResult;
  Step: Integer;
begin
  FRequest := '';
  for Step := 1 to MAX_REACTOR_STEPS do
  begin
    if Terminated then
      Exit;
    if TransportSecurityPendingCiphertext(AConnection) > 0 then
      FlushOneCiphertextFragment(ASocket, AConnection)
    else
    begin
      ReadResult := TransportSecurityServerRead(AConnection, Buffer,
        Length(Buffer));
      if ReadResult.BytesProcessed > 0 then
      begin
        SetString(Chunk, PAnsiChar(@Buffer[0]), ReadResult.BytesProcessed);
        FRequest := FRequest + Chunk;
        if Length(FRequest) >= Length(CLIENT_REQUEST) then
          Exit;
      end;
      case ReadResult.State of
        tssDone:
          ;
        tssWantRead:
          ReceiveOneCiphertextFragment(ASocket, AConnection);
        tssWantWrite:
          FlushOneCiphertextFragment(ASocket, AConnection);
      else
        raise Exception.Create('TLS server read failed');
      end;
    end;
    Sleep(1);
  end;
  raise Exception.Create('TLS server read timed out');
end;

procedure TLoopbackTLSServer.DriveWrite(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection);
var
  Step: Integer;
  WriteResult: TTransportSecurityIOResult;
begin
  WriteResult := TransportSecurityServerWrite(AConnection,
    @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
  if WriteResult.BytesProcessed <> Length(SERVER_RESPONSE) then
    raise Exception.Create('TLS server write did not consume the response');
  for Step := 1 to MAX_REACTOR_STEPS do
  begin
    if Terminated then
      Exit;
    if TransportSecurityPendingCiphertext(AConnection) = 0 then
      Exit;
    FlushOneCiphertextFragment(ASocket, AConnection);
    Sleep(1);
  end;
  raise Exception.Create('TLS server write timed out');
end;

procedure TLoopbackTLSServer.DriveClose(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection);
var
  State: TTransportSecurityState;
  Step: Integer;
begin
  for Step := 1 to MAX_REACTOR_STEPS do
  begin
    if Terminated then
      Exit;
    if FPeerGone then
      Exit;
    if TransportSecurityPendingCiphertext(AConnection) > 0 then
      FlushOneCiphertextFragment(ASocket, AConnection, True)
    else
    begin
      State := CloseTransportSecurityServerGracefully(AConnection);
      case State of
        tssDone:
          if TransportSecurityPendingCiphertext(AConnection) = 0 then
            Exit;
        tssWantRead:
          ReceiveOneCiphertextFragment(ASocket, AConnection);
        tssWantWrite:
          FlushOneCiphertextFragment(ASocket, AConnection, True);
      else
        raise Exception.Create('TLS server close failed');
      end;
    end;
    Sleep(1);
  end;
  raise Exception.Create('TLS server close timed out');
end;

procedure TLoopbackTLSServer.Execute;
var
  Address: TInetSockAddr;
  AddressLength: TSocklen;
  AcceptedSocket: TSocket;
  ClientSocket: TSocket;
  Connection: TTransportSecurityConnection;
  OwnedSocket: TSocket;
begin
  AcceptedSocket := -1;
  ClientSocket := -1;
  FillChar(Connection, SizeOf(Connection), 0);
  try
    try
      AddressLength := SizeOf(Address);
      AcceptedSocket := FpAccept(FListenSocket, @Address, @AddressLength);
      if AcceptedSocket < 0 then
      begin
        if Terminated then
          Exit;
        raise Exception.Create('accept() failed');
      end;
      if Terminated then
      begin
        CloseSocket(AcceptedSocket);
        AcceptedSocket := -1;
        Exit;
      end;
      InterlockedExchange(FClientSocket, AcceptedSocket);
      ClientSocket := AcceptedSocket;
      AcceptedSocket := -1;
      if Terminated then
        Exit;
      SetNonblocking(ClientSocket);
      BeginTransportSecurityServer(Connection, FContext);
      try
        DriveHandshake(ClientSocket, Connection);
      except
        on EHandshakeDeadlineExceeded do
          if FScenario = ssStalledHandshake then
          begin
            FHandshakeTimedOut := True;
            Exit;
          end
          else
            raise;
        on EHandshakeInputBudgetExceeded do
          if FScenario = ssInputBudgetExceeded then
          begin
            FHandshakeInputBudgetExceeded := True;
            Exit;
          end
          else
            raise;
      end;
      if FScenario <> ssRoundTrip then
        raise Exception.Create('adversarial TLS handshake unexpectedly completed');
      DriveRead(ClientSocket, Connection);
      DriveWrite(ClientSocket, Connection);
      DriveClose(ClientSocket, Connection);
    except
      on E: Exception do
        FErrorMessage := E.Message;
    end;
  finally
    AbortTransportSecurityServer(Connection);
    if AcceptedSocket >= 0 then
      CloseSocket(AcceptedSocket);
    OwnedSocket := InterlockedExchange(FClientSocket, -1);
    if OwnedSocket >= 0 then
      CloseSocket(OwnedSocket)
    else if ClientSocket >= 0 then
      CloseSocket(ClientSocket);
  end;
end;

procedure QueueStaleOpenSSLError;
const
  MISSING_FILE =
    'build/tests/tmp/transport-security/e2e-stale-error.pem';
  READ_MODE = 'rb';
var
  BIONewFile: TBIONewFile;
begin
  BIONewFile := TBIONewFile(GetProcedureAddress(SSLUtilHandle,
    'BIO_new_file'));
  if not Assigned(BIONewFile) then
    raise Exception.Create('OpenSSL runtime lacks BIO_new_file');
  if Assigned(BIONewFile(PAnsiChar(AnsiString(MISSING_FILE)),
     PAnsiChar(AnsiString(READ_MODE)))) or
     Assigned(BIONewFile(PAnsiChar(AnsiString(MISSING_FILE)),
     PAnsiChar(AnsiString(READ_MODE)))) then
    raise Exception.Create('Expected missing-file BIO creation to fail');
  if ErrGetError = 0 then
    raise Exception.Create('Failed to seed the OpenSSL error queue');
end;

procedure TTransportSecuritySocketE2ETests.TestLoopbackAcceptReadWriteClose;
var
  Address: TInetSockAddr;
  Buffer: array[0..255] of Byte;
  Chunk: string;
  ClientSocket: TSocket;
  Connection: TTransportSecurityConnection;
  ReadCount: Integer;
  Response: string;
  Server: TLoopbackTLSServer;
begin
  if SetEnvironmentVariable('SSL_CERT_FILE',
    PAnsiChar(AnsiString(ExpandFileName(ROOT_CERTIFICATE_PATH))), 1) <> 0 then
    raise Exception.Create('setenv(SSL_CERT_FILE) failed');
  Server := TLoopbackTLSServer.Create;
  ClientSocket := -1;
  FillChar(Connection, SizeOf(Connection), 0);
  try
    Server.Start;
    ClientSocket := FpSocket(AF_INET, SOCK_STREAM, 0);
    if ClientSocket < 0 then
      raise Exception.Create('client socket() failed');
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(Server.Port);
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if FpConnect(ClientSocket, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('client connect() failed');

    StartTransportSecurity(Connection, ClientSocket, 'localhost');
    QueueStaleOpenSSLError;
    Expect<Integer>(TransportSecurityWrite(Connection, @CLIENT_REQUEST[1],
      Length(CLIENT_REQUEST))).ToBe(Length(CLIENT_REQUEST));
    Expect<Int64>(Int64(ErrGetError)).ToBe(0);

    Response := '';
    repeat
      ReadCount := TransportSecurityRead(Connection, Buffer, Length(Buffer));
      if ReadCount <= 0 then
        raise Exception.Create('production TLS client read failed');
      SetString(Chunk, PAnsiChar(@Buffer[0]), ReadCount);
      Response := Response + Chunk;
    until Length(Response) >= Length(SERVER_RESPONSE);
    Expect<string>(Response).ToBe(SERVER_RESPONSE);
    CloseTransportSecurity(Connection);
    CloseSocket(ClientSocket);
    ClientSocket := -1;
    Server.WaitForCompletion(HANDSHAKE_TIMEOUT_MILLISECONDS +
      SERVER_COMPLETION_GRACE_MILLISECONDS);

    Expect<string>(Server.ErrorMessage).ToBe('');
    Expect<string>(Server.Request).ToBe(CLIENT_REQUEST);
    Expect<Boolean>(Server.SawFragmentedInput).ToBe(True);
    Expect<Boolean>(Server.SawShortWrite).ToBe(True);
    Expect<Boolean>(Server.CiphertextBytesRead > 0).ToBe(True);
    Expect<Int64>(Int64(Server.CiphertextBytesFed)).ToBe(
      Int64(Server.CiphertextBytesRead));
    Expect<Boolean>(Server.HandshakeCiphertextBytesRead <
      HANDSHAKE_INPUT_BYTE_BUDGET).ToBe(True);
  finally
    CloseTransportSecurity(Connection);
    if ClientSocket >= 0 then
      CloseSocket(ClientSocket);
    Server.Free;
  end;
end;

procedure TTransportSecuritySocketE2ETests.TestStalledHandshakeAbortsWithinDeadline;
var
  Address: TInetSockAddr;
  ClientSocket: TSocket;
  Sent: Integer;
  Server: TLoopbackTLSServer;
  SlowLorisByte: Byte;
begin
  Server := TLoopbackTLSServer.Create(ssStalledHandshake);
  ClientSocket := -1;
  try
    Server.Start;
    ClientSocket := FpSocket(AF_INET, SOCK_STREAM, 0);
    if ClientSocket < 0 then
      raise Exception.Create('slow-loris client socket() failed');
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(Server.Port);
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if FpConnect(ClientSocket, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('slow-loris client connect() failed');
    SlowLorisByte := $16;
    Sent := FpSend(ClientSocket, @SlowLorisByte, 1, SEND_NOSIGNAL_FLAG);
    if Sent <> 1 then
      raise Exception.Create('slow-loris client send() failed');

    Server.WaitForCompletion(HANDSHAKE_TIMEOUT_MILLISECONDS +
      SERVER_COMPLETION_GRACE_MILLISECONDS);
    Expect<string>(Server.ErrorMessage).ToBe('');
    Expect<Boolean>(Server.HandshakeTimedOut).ToBe(True);
    Expect<Boolean>(Server.HandshakeElapsed >=
      HANDSHAKE_TIMEOUT_MILLISECONDS).ToBe(True);
    Expect<Boolean>(Server.HandshakeElapsed <
      HANDSHAKE_TIMEOUT_MILLISECONDS + 500).ToBe(True);
    Expect<Int64>(Int64(Server.CiphertextBytesRead)).ToBe(1);
    Expect<Int64>(Int64(Server.CiphertextBytesFed)).ToBe(1);
  finally
    if ClientSocket >= 0 then
      CloseSocket(ClientSocket);
    Server.Free;
  end;
end;

procedure TTransportSecuritySocketE2ETests.TestHandshakeInputBudgetAbortsBeforeFeed;
var
  Address: TInetSockAddr;
  BudgetProbe: array[1..BUDGET_PROBE_INPUT_BYTE_BUDGET + 1] of Byte;
  ClientSocket: TSocket;
  Sent: Integer;
  Server: TLoopbackTLSServer;
begin
  Server := TLoopbackTLSServer.Create(ssInputBudgetExceeded);
  ClientSocket := -1;
  try
    Server.Start;
    ClientSocket := FpSocket(AF_INET, SOCK_STREAM, 0);
    if ClientSocket < 0 then
      raise Exception.Create('budget-probe client socket() failed');
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(Server.Port);
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if FpConnect(ClientSocket, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('budget-probe client connect() failed');
    FillChar(BudgetProbe, SizeOf(BudgetProbe), $16);
    Sent := FpSend(ClientSocket, @BudgetProbe[1], Length(BudgetProbe),
      SEND_NOSIGNAL_FLAG);
    if Sent <> Length(BudgetProbe) then
      raise Exception.Create('budget-probe client send() failed');

    Server.WaitForCompletion(HANDSHAKE_TIMEOUT_MILLISECONDS +
      SERVER_COMPLETION_GRACE_MILLISECONDS);
    Expect<string>(Server.ErrorMessage).ToBe('');
    Expect<Boolean>(Server.HandshakeInputBudgetExceeded).ToBe(True);
    Expect<Boolean>(Server.HandshakeTimedOut).ToBe(False);
    Expect<Boolean>(Server.HandshakeElapsed <
      HANDSHAKE_TIMEOUT_MILLISECONDS).ToBe(True);
    Expect<Boolean>(Server.CiphertextBytesRead >
      BUDGET_PROBE_INPUT_BYTE_BUDGET).ToBe(True);
    Expect<Boolean>(Server.CiphertextBytesFed <=
      BUDGET_PROBE_INPUT_BYTE_BUDGET).ToBe(True);
    Expect<Boolean>(Server.CiphertextBytesFed <
      Server.CiphertextBytesRead).ToBe(True);
  finally
    if ClientSocket >= 0 then
      CloseSocket(ClientSocket);
    Server.Free;
  end;
end;

procedure TTransportSecuritySocketE2ETests.SetupTests;
begin
  Test('nonblocking loopback accept-read-write-close handles fragments',
    TestLoopbackAcceptReadWriteClose);
  Test('handshake input byte budget aborts before ciphertext feed',
    TestHandshakeInputBudgetAbortsBeforeFeed);
  Test('stalled handshake aborts within its deadline',
    TestStalledHandshakeAbortsWithinDeadline);
end;

begin
  TestRunnerProgram.AddSuite(TTransportSecuritySocketE2ETests.Create(
    'TransportSecurity: Linux socket E2E'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
{$ELSE}
uses
  SysUtils,

  TestingPascalLibrary.Protocol;

begin
  if CurrentTestInventoryMode <> '' then
    WriteLn(TEST_INVENTORY_PREFIX, '0', #9, '0');
  if CurrentTestInventoryMode <> TEST_INVENTORY_MODE_ONLY then
    WriteLn('TransportSecurity socket E2E skipped: Linux-only');
  ExitCode := 0;
end.
{$ENDIF}
