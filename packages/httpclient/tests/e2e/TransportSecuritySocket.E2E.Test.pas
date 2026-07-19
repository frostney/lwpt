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

type
  TBIONewFile = function(AFilename, AMode: PAnsiChar): Pointer; cdecl;

  TLoopbackTLSServer = class(TThread)
  private
    FContext: TTransportSecurityServerContext;
    FErrorMessage: string;
    FListenSocket: TSocket;
    FPort: Word;
    FRequest: string;
    FSawFragmentedInput: Boolean;
    FSawShortWrite: Boolean;
    function FlushOneCiphertextFragment(const ASocket: TSocket;
      var AConnection: TTransportSecurityConnection): Boolean;
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
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    property ErrorMessage: string read FErrorMessage;
    property Port: Word read FPort;
    property Request: string read FRequest;
    property SawFragmentedInput: Boolean read FSawFragmentedInput;
    property SawShortWrite: Boolean read FSawShortWrite;
  end;

  TTransportSecuritySocketE2ETests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestLoopbackAcceptReadWriteClose;
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

constructor TLoopbackTLSServer.Create;
var
  Address: TInetSockAddr;
  AddressLength: TSocklen;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FListenSocket := -1;
  FContext := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
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
    raise;
  end;
end;

destructor TLoopbackTLSServer.Destroy;
begin
  if FListenSocket >= 0 then
  begin
    FpShutdown(FListenSocket, 2);
    CloseSocket(FListenSocket);
    FListenSocket := -1;
  end;
  WaitFor;
  CloseTransportSecurityServerContext(FContext);
  inherited Destroy;
end;

function TLoopbackTLSServer.FlushOneCiphertextFragment(
  const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection): Boolean;
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
  Sent := FpSend(ASocket, Buffer, SendLength, 0);
  if Sent > 0 then
  begin
    TransportSecurityConsumeCiphertext(AConnection, Sent);
    FSawShortWrite := FSawShortWrite or (Sent < Pending);
    Result := True;
  end
  else if (Sent < 0) and not SocketWouldBlock then
    raise Exception.Create('send() failed');
end;

function TLoopbackTLSServer.ReceiveOneCiphertextFragment(
  const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection): Boolean;
var
  Buffer: array[0..RECEIVE_FRAGMENT_SIZE - 1] of Byte;
  Received: Integer;
begin
  Result := False;
  Received := FpRecv(ASocket, @Buffer[0], Length(Buffer), 0);
  if Received > 0 then
  begin
    if TransportSecurityFeedCiphertext(AConnection, @Buffer[0],
      Received) <> Received then
      raise Exception.Create('TLS ciphertext feed was partial');
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
  for Step := 1 to MAX_REACTOR_STEPS do
  begin
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
    if TransportSecurityPendingCiphertext(AConnection) > 0 then
      FlushOneCiphertextFragment(ASocket, AConnection)
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
          FlushOneCiphertextFragment(ASocket, AConnection);
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
  ClientSocket: TSocket;
  Connection: TTransportSecurityConnection;
begin
  ClientSocket := -1;
  FillChar(Connection, SizeOf(Connection), 0);
  try
    try
      AddressLength := SizeOf(Address);
      ClientSocket := FpAccept(FListenSocket, @Address, @AddressLength);
      if ClientSocket < 0 then
        raise Exception.Create('accept() failed');
      SetNonblocking(ClientSocket);
      BeginTransportSecurityServer(Connection, FContext);
      DriveHandshake(ClientSocket, Connection);
      DriveRead(ClientSocket, Connection);
      DriveWrite(ClientSocket, Connection);
      DriveClose(ClientSocket, Connection);
    except
      on E: Exception do
        FErrorMessage := E.Message;
    end;
  finally
    AbortTransportSecurityServer(Connection);
    if ClientSocket >= 0 then
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
    Server.WaitFor;

    Expect<string>(Server.ErrorMessage).ToBe('');
    Expect<string>(Server.Request).ToBe(CLIENT_REQUEST);
    Expect<Boolean>(Server.SawFragmentedInput).ToBe(True);
    Expect<Boolean>(Server.SawShortWrite).ToBe(True);
  finally
    CloseTransportSecurity(Connection);
    if ClientSocket >= 0 then
      CloseSocket(ClientSocket);
    Server.Free;
  end;
end;

procedure TTransportSecuritySocketE2ETests.SetupTests;
begin
  Test('nonblocking loopback accept-read-write-close handles fragments',
    TestLoopbackAcceptReadWriteClose);
end;

begin
  TestRunnerProgram.AddSuite(TTransportSecuritySocketE2ETests.Create(
    'TransportSecurity: Linux socket E2E'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
{$ELSE}
uses
  SysUtils;

begin
  WriteLn('TransportSecurity socket E2E skipped: Linux-only');
  ExitCode := 0;
end.
{$ENDIF}
