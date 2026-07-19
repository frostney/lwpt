{ TransportSecurity.Test -- deterministic memory-BIO TLS server coverage.

  Darwin deliberately runs only the shared read-bounds regression and the
  actionable server stub. Windows and Unix-not-Darwin pair the production
  server API with an in-memory raw OpenSSL client; no sockets or network are
  involved. }

program TransportSecurity.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,
  {$IFNDEF DARWIN}
  DynLibs,
  OpenSSL,
  {$ENDIF}
  TestingPascalLibrary,
  TransportSecurity;

const
  PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-test-identity.p12';
  PKCS12_PASSPHRASE = 'lwpt-test-only';
  SCRATCH_DIRECTORY = 'build/tests/tmp/transport-security';
  CLIENT_REQUEST = 'hello from the memory-BIO client';
  SERVER_RESPONSE = 'hello from TransportSecurity server';
  DARWIN_SKIP_REASON =
    'OpenSSL server accept is intentionally unsupported on Darwin; ' +
    'duetto uses Network.framework there';

type
  TTransportSecurityServerTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBoundsClamp;
    procedure TestDarwinReportsUnsupportedServerTLS;
    procedure TestFatalHandshakePoisonsConnection;
    procedure TestGracefulCloseProducesCloseNotify;
    procedure TestHandshakeTransitionsAndContextReuse;
    procedure TestMissingPKCS12FailsWithoutPathDisclosure;
    procedure TestPKCS12LoadFailures;
    procedure TestPlaintextRoundtripAndPartialCiphertextConsumption;
    procedure TestTLSFloorRejectsTLS11;
  end;

function CaptureContextError(const APath, APassphrase: string): string;
var
  Context: TTransportSecurityServerContext;
begin
  Result := '';
  Context := nil;
  try
    try
      Context := TTransportSecurityServerContext.Create(APath, APassphrase);
    except
      on E: ETransportSecurityError do
        Result := E.Message;
    end;
  finally
    CloseTransportSecurityServerContext(Context);
  end;
  if Result = '' then
    raise Exception.Create('Expected TLS server context creation to fail');
end;

procedure WriteTextFile(const APath, AText: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

{$IFNDEF DARWIN}
type
  TBIONew = function(AMethod: Pointer): Pointer; cdecl;
  TBIORead = function(ABIO, ABuffer: Pointer;
    ALength: LongInt): LongInt; cdecl;
  TBIOSMemory = function: Pointer; cdecl;
  TBIOWrite = function(ABIO, ABuffer: Pointer;
    ALength: LongInt): LongInt; cdecl;
  TSSLContextSetSecurityLevel = procedure(AContext: PSSL_CTX;
    ALevel: LongInt); cdecl;
  TSSLMethodGetter = function: Pointer; cdecl;
  TSSLSetBIO = procedure(ASSL: PSSL; AReadBIO, AWriteBIO: Pointer); cdecl;
  TSSLSetConnectState = procedure(ASSL: PSSL); cdecl;

  TRawOpenSSLClient = record
    Context: PSSL_CTX;
    Done: Boolean;
    ReadBIO: Pointer;
    SSL: PSSL;
    WriteBIO: Pointer;
  end;

  THandshakeObservations = record
    SawWantRead: Boolean;
    SawWantWrite: Boolean;
  end;

const
  BIO_C_SET_BUF_MEM_EOF_RETURN = 130;
  BIO_CTRL_PENDING_COMMAND = 10;
  SSL_CTRL_SET_MAX_PROTO_VERSION = 124;
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  TLS1_VERSION = $0301;
  TLS1_1_VERSION = $0302;

var
  RawBIONew: TBIONew;
  RawBIORead: TBIORead;
  RawBIOSMemory: TBIOSMemory;
  RawBIOWrite: TBIOWrite;
  RawSSLContextSetSecurityLevel: TSSLContextSetSecurityLevel;
  RawSSLSetBIO: TSSLSetBIO;
  RawSSLSetConnectState: TSSLSetConnectState;

procedure ResolveRawOpenSSLProcedures;
begin
  if Assigned(RawSSLSetBIO) then
    Exit;
  RawBIONew := TBIONew(GetProcedureAddress(SSLUtilHandle, 'BIO_new'));
  RawBIORead := TBIORead(GetProcedureAddress(SSLUtilHandle, 'BIO_read'));
  RawBIOSMemory := TBIOSMemory(GetProcedureAddress(SSLUtilHandle,
    'BIO_s_mem'));
  RawBIOWrite := TBIOWrite(GetProcedureAddress(SSLUtilHandle, 'BIO_write'));
  RawSSLContextSetSecurityLevel := TSSLContextSetSecurityLevel(
    GetProcedureAddress(SSLLibHandle, 'SSL_CTX_set_security_level'));
  RawSSLSetBIO := TSSLSetBIO(GetProcedureAddress(SSLLibHandle,
    'SSL_set_bio'));
  RawSSLSetConnectState := TSSLSetConnectState(GetProcedureAddress(
    SSLLibHandle, 'SSL_set_connect_state'));
  if not Assigned(RawBIONew) or not Assigned(RawBIORead) or
     not Assigned(RawBIOSMemory) or not Assigned(RawBIOWrite) or
     not Assigned(RawSSLSetBIO) or not Assigned(RawSSLSetConnectState) then
    raise Exception.Create(
      'Raw OpenSSL client lacks the required memory-BIO procedures');
end;

procedure CreateRawClient(out AClient: TRawOpenSSLClient;
  const AMaximumTLSVersion: Integer = 0);
var
  GetMethod: TSSLMethodGetter;
begin
  FillChar(AClient, SizeOf(AClient), 0);
  ResolveRawOpenSSLProcedures;
  GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
    'TLS_client_method'));
  if not Assigned(GetMethod) then
    GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
      'TLS_method'));
  if not Assigned(GetMethod) then
    raise Exception.Create('Raw OpenSSL client has no TLS method');

  AClient.Context := SslCtxNew(GetMethod());
  if not Assigned(AClient.Context) then
    raise Exception.Create('Raw OpenSSL client context creation failed');
  try
    SslCtxSetVerify(AClient.Context, SSL_VERIFY_NONE,
      TSSLCTXVerifyCallback(nil));
    if AMaximumTLSVersion > 0 then
    begin
      if Assigned(RawSSLContextSetSecurityLevel) then
        RawSSLContextSetSecurityLevel(AClient.Context, 0);
      if SslCTXCtrl(AClient.Context, SSL_CTRL_SET_MIN_PROTO_VERSION,
        TLS1_VERSION, nil) <= 0 then
        raise Exception.Create('Raw client minimum TLS version failed');
      if SslCTXCtrl(AClient.Context, SSL_CTRL_SET_MAX_PROTO_VERSION,
        AMaximumTLSVersion, nil) <= 0 then
        raise Exception.Create('Raw client maximum TLS version failed');
    end;

    AClient.SSL := SslNew(AClient.Context);
    if not Assigned(AClient.SSL) then
      raise Exception.Create('Raw OpenSSL client session creation failed');
    AClient.ReadBIO := RawBIONew(RawBIOSMemory());
    AClient.WriteBIO := RawBIONew(RawBIOSMemory());
    if not Assigned(AClient.ReadBIO) or not Assigned(AClient.WriteBIO) then
      raise Exception.Create('Raw OpenSSL client memory BIO creation failed');
    if BIO_ctrl(AClient.ReadBIO, BIO_C_SET_BUF_MEM_EOF_RETURN,
      -1, nil) <= 0 then
      raise Exception.Create('Raw OpenSSL client read BIO setup failed');
    RawSSLSetBIO(AClient.SSL, AClient.ReadBIO, AClient.WriteBIO);
    RawSSLSetConnectState(AClient.SSL);
  except
    if Assigned(AClient.SSL) then
      SslFree(AClient.SSL);
    if Assigned(AClient.Context) then
      SslCtxFree(AClient.Context);
    FillChar(AClient, SizeOf(AClient), 0);
    raise;
  end;
end;

procedure FreeRawClient(var AClient: TRawOpenSSLClient);
begin
  if Assigned(AClient.SSL) then
    SslFree(AClient.SSL);
  if Assigned(AClient.Context) then
    SslCtxFree(AClient.Context);
  FillChar(AClient, SizeOf(AClient), 0);
end;

function StepRawClientHandshake(
  var AClient: TRawOpenSSLClient): TTransportSecurityState;
var
  ErrorCode: Integer;
  StepResult: Integer;
begin
  if AClient.Done then
  begin
    Result := tssDone;
    Exit;
  end;
  ErrClearError;
  StepResult := SslConnect(AClient.SSL);
  if StepResult = 1 then
  begin
    AClient.Done := True;
    Result := tssDone;
    Exit;
  end;
  ErrorCode := SslGetError(AClient.SSL, StepResult);
  case ErrorCode of
    SSL_ERROR_WANT_READ:
      Result := tssWantRead;
    SSL_ERROR_WANT_WRITE:
      Result := tssWantWrite;
  else
    Result := tssError;
  end;
end;

procedure PumpClientCiphertext(var AClient: TRawOpenSSLClient;
  var AServer: TTransportSecurityConnection);
var
  Buffer: array[0..16383] of Byte;
  Fed: Integer;
  Offset: Integer;
  Pending: Int64;
  ReadCount: Integer;
begin
  repeat
    Pending := BIO_ctrl(AClient.WriteBIO, BIO_CTRL_PENDING_COMMAND, 0, nil);
    if Pending <= 0 then
      Exit;
    if Pending > Length(Buffer) then
      ReadCount := Length(Buffer)
    else
      ReadCount := Integer(Pending);
    ReadCount := RawBIORead(AClient.WriteBIO, @Buffer[0], ReadCount);
    if ReadCount <= 0 then
      raise Exception.Create('Raw client ciphertext drain failed');
    Offset := 0;
    while Offset < ReadCount do
    begin
      Fed := TransportSecurityFeedCiphertext(AServer, @Buffer[Offset],
        ReadCount - Offset);
      if Fed <= 0 then
        raise Exception.Create('Server ciphertext feed failed');
      Inc(Offset, Fed);
    end;
  until False;
end;

procedure PumpServerCiphertext(var AServer: TTransportSecurityConnection;
  var AClient: TRawOpenSSLClient);
var
  Buffer: Pointer;
  Pending: Integer;
  Written: Integer;
begin
  repeat
    Pending := TransportSecurityGetCiphertext(AServer, Buffer);
    if Pending <= 0 then
      Exit;
    Written := RawBIOWrite(AClient.ReadBIO, Buffer, Pending);
    if Written <= 0 then
      raise Exception.Create('Raw client ciphertext feed failed');
    TransportSecurityConsumeCiphertext(AServer, Written);
  until False;
end;

procedure DriveHandshake(var AServer: TTransportSecurityConnection;
  var AClient: TRawOpenSSLClient; out AObserved: THandshakeObservations);
var
  ClientState: TTransportSecurityState;
  I: Integer;
  ServerState: TTransportSecurityState;
begin
  FillChar(AObserved, SizeOf(AObserved), 0);
  ServerState := TransportSecurityServerHandshake(AServer);
  AObserved.SawWantRead := ServerState = tssWantRead;
  for I := 1 to 128 do
  begin
    ClientState := StepRawClientHandshake(AClient);
    if ClientState = tssError then
      raise Exception.Create('Raw client handshake failed');
    PumpClientCiphertext(AClient, AServer);

    ServerState := TransportSecurityServerHandshake(AServer);
    AObserved.SawWantRead := AObserved.SawWantRead or
      (ServerState = tssWantRead);
    AObserved.SawWantWrite := AObserved.SawWantWrite or
      (ServerState = tssWantWrite);
    if ServerState = tssError then
      raise Exception.Create('TransportSecurity server handshake failed');
    PumpServerCiphertext(AServer, AClient);

    if AClient.Done and (ServerState = tssDone) and
       (TransportSecurityPendingCiphertext(AServer) = 0) then
      Exit;
  end;
  raise Exception.Create('Memory-BIO TLS handshake exceeded 128 steps');
end;

procedure CreateHandshakenPair(const AContext: TTransportSecurityServerContext;
  out AServer: TTransportSecurityConnection; out AClient: TRawOpenSSLClient;
  out AObserved: THandshakeObservations);
begin
  FillChar(AServer, SizeOf(AServer), 0);
  FillChar(AClient, SizeOf(AClient), 0);
  BeginTransportSecurityServer(AServer, AContext);
  try
    CreateRawClient(AClient);
    DriveHandshake(AServer, AClient, AObserved);
  except
    AbortTransportSecurityServer(AServer);
    FreeRawClient(AClient);
    raise;
  end;
end;
{$ENDIF}

procedure TTransportSecurityServerTests.TestBoundsClamp;
var
  Buffer: array[0..0] of Byte;
  Connection: TTransportSecurityConnection;
begin
  FillChar(Connection, SizeOf(Connection), 0);
  Buffer[0] := 42;
  Expect<Integer>(TransportSecurityRead(Connection, Buffer,
    High(Integer))).ToBe(0);
  Expect<Integer>(Buffer[0]).ToBe(42);
end;

procedure TTransportSecurityServerTests.TestDarwinReportsUnsupportedServerTLS;
var
  ErrorMessage: string;
begin
  ErrorMessage := CaptureContextError(PKCS12_PATH, PKCS12_PASSPHRASE);
  Expect<Boolean>(Pos('not supported on macOS', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('Network.framework', ErrorMessage) > 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestMissingPKCS12FailsWithoutPathDisclosure;
var
  ErrorMessage: string;
  MissingPath: string;
begin
  MissingPath := SCRATCH_DIRECTORY + '/private/identity-does-not-exist.p12';
  ErrorMessage := CaptureContextError(MissingPath, 'secret-passphrase');
  Expect<Boolean>(Pos('does not exist', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos(MissingPath, ErrorMessage) = 0).ToBe(True);
  Expect<Boolean>(Pos('secret-passphrase', ErrorMessage) = 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestPKCS12LoadFailures;
var
  ErrorMessage: string;
  GarbagePath: string;
begin
  ForceDirectories(SCRATCH_DIRECTORY);
  GarbagePath := SCRATCH_DIRECTORY + '/garbage-identity.p12';
  WriteTextFile(GarbagePath, 'not a PKCS#12 bundle');
  ErrorMessage := CaptureContextError(GarbagePath, PKCS12_PASSPHRASE);
  Expect<Boolean>(Pos('verify the bundle and passphrase',
    ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos(GarbagePath, ErrorMessage) = 0).ToBe(True);

  ErrorMessage := CaptureContextError(PKCS12_PATH, 'wrong-passphrase');
  Expect<Boolean>(Pos('verify the bundle and passphrase',
    ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('wrong-passphrase', ErrorMessage) = 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestHandshakeTransitionsAndContextReuse;
{$IFNDEF DARWIN}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  SecondClient: TRawOpenSSLClient;
  SecondConnection: TTransportSecurityConnection;
  SecondObserved: THandshakeObservations;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  FillChar(SecondConnection, SizeOf(SecondConnection), 0);
  FillChar(SecondClient, SizeOf(SecondClient), 0);
  try
    CreateHandshakenPair(Context, Connection, Client, Observed);
    CreateHandshakenPair(Context, SecondConnection, SecondClient,
      SecondObserved);
    Expect<Boolean>(Connection.Active).ToBe(True);
    Expect<Boolean>(SecondConnection.Active).ToBe(True);
    Expect<Boolean>(Observed.SawWantRead).ToBe(True);
    Expect<Boolean>(Observed.SawWantWrite).ToBe(True);
    Expect<Boolean>(SecondObserved.SawWantRead).ToBe(True);
    Expect<Boolean>(SecondObserved.SawWantWrite).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    AbortTransportSecurityServer(SecondConnection);
    FreeRawClient(Client);
    FreeRawClient(SecondClient);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestPlaintextRoundtripAndPartialCiphertextConsumption;
{$IFNDEF DARWIN}
var
  Buffer: array[0..255] of Byte;
  Ciphertext: Pointer;
  Client: TRawOpenSSLClient;
  ClientRead: Integer;
  ClientWritten: Integer;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  Partial: Integer;
  Pending: Integer;
  ReadResult: TTransportSecurityIOResult;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateHandshakenPair(Context, Connection, Client, Observed);

    ErrClearError;
    ClientWritten := SslWrite(Client.SSL, @CLIENT_REQUEST[1],
      Length(CLIENT_REQUEST));
    if ClientWritten <= 0 then
      raise Exception.CreateFmt('Raw client plaintext write failed: %d',
        [SslGetError(Client.SSL, ClientWritten)]);
    PumpClientCiphertext(Client, Connection);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(Length(CLIENT_REQUEST));
    Expect<string>(Copy(PAnsiChar(@Buffer[0]), 1,
      ReadResult.BytesProcessed)).ToBe(CLIENT_REQUEST);

    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(SERVER_RESPONSE));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Pending := TransportSecurityGetCiphertext(Connection, Ciphertext);
    Expect<Boolean>(Pending > 1).ToBe(True);
    Partial := Pending div 2;
    Expect<Integer>(RawBIOWrite(Client.ReadBIO, Ciphertext,
      Partial)).ToBe(Partial);
    TransportSecurityConsumeCiphertext(Connection, Partial);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(
      Pending - Partial);
    PumpServerCiphertext(Connection, Client);

    ErrClearError;
    ClientRead := SslRead(Client.SSL, @Buffer[0], Length(Buffer));
    if ClientRead <= 0 then
      raise Exception.CreateFmt('Raw client plaintext read failed: %d',
        [SslGetError(Client.SSL, ClientRead)]);
    Expect<string>(Copy(PAnsiChar(@Buffer[0]), 1, ClientRead)).ToBe(
      SERVER_RESPONSE);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestFatalHandshakePoisonsConnection;
{$IFNDEF DARWIN}
const
  INVALID_HANDSHAKE = 'GET / HTTP/1.0'#13#10#13#10;
var
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @INVALID_HANDSHAKE[1], Length(INVALID_HANDSHAKE))).ToBe(
      Length(INVALID_HANDSHAKE));
    State := TransportSecurityServerHandshake(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssError));
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestGracefulCloseProducesCloseNotify;
{$IFNDEF DARWIN}
var
  Buffer: array[0..0] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ErrorCode: Integer;
  Observed: THandshakeObservations;
  ReadResult: Integer;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateHandshakenPair(Context, Connection, Client, Observed);
    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Boolean>(TransportSecurityPendingCiphertext(Connection) > 0).ToBe(
      True);
    PumpServerCiphertext(Connection, Client);

    ErrClearError;
    ReadResult := SslRead(Client.SSL, @Buffer[0], Length(Buffer));
    ErrorCode := SslGetError(Client.SSL, ReadResult);
    Expect<Integer>(ReadResult).ToBe(0);
    Expect<Integer>(ErrorCode).ToBe(SSL_ERROR_ZERO_RETURN);
    Expect<Boolean>(Connection.Active).ToBe(True);
    AbortTransportSecurityServer(Connection);
    Expect<Boolean>(Connection.Active).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestTLSFloorRejectsTLS11;
{$IFNDEF DARWIN}
var
  Client: TRawOpenSSLClient;
  ClientState: TTransportSecurityState;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  I: Integer;
  ServerState: TTransportSecurityState;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawClient(Client, TLS1_1_VERSION);
    ServerState := tssWantRead;
    for I := 1 to 16 do
    begin
      ClientState := StepRawClientHandshake(Client);
      PumpClientCiphertext(Client, Connection);
      ServerState := TransportSecurityServerHandshake(Connection);
      if ServerState = tssError then
        Break;
      if ClientState = tssError then
        Break;
      PumpServerCiphertext(Connection, Client);
    end;
    Expect<Integer>(Ord(ServerState)).ToBe(Ord(tssError));
    Expect<Boolean>(Connection.Active).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.SetupTests;
begin
  Test('TransportSecurityRead clamps oversized lengths', TestBoundsClamp);
  {$IFDEF DARWIN}
  Test('Darwin server API reports Network.framework alternative',
    TestDarwinReportsUnsupportedServerTLS);
  Skip('missing PKCS#12 fails without disclosing path',
    TestMissingPKCS12FailsWithoutPathDisclosure, DARWIN_SKIP_REASON);
  Skip('garbage and wrong-pass PKCS#12 fail actionably',
    TestPKCS12LoadFailures, DARWIN_SKIP_REASON);
  Skip('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse, DARWIN_SKIP_REASON);
  Skip('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption,
    DARWIN_SKIP_REASON);
  Skip('fatal handshake poisons connection',
    TestFatalHandshakePoisonsConnection, DARWIN_SKIP_REASON);
  Skip('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify, DARWIN_SKIP_REASON);
  Skip('TLS floor rejects TLS 1.1', TestTLSFloorRejectsTLS11,
    DARWIN_SKIP_REASON);
  {$ELSE}
  Skip('Darwin server API reports Network.framework alternative',
    TestDarwinReportsUnsupportedServerTLS, 'Darwin-only behavior');
  Test('missing PKCS#12 fails without disclosing path',
    TestMissingPKCS12FailsWithoutPathDisclosure);
  Test('garbage and wrong-pass PKCS#12 fail actionably',
    TestPKCS12LoadFailures);
  Test('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse);
  Test('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption);
  Test('fatal handshake poisons connection',
    TestFatalHandshakePoisonsConnection);
  Test('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify);
  Test('TLS floor rejects TLS 1.1', TestTLSFloorRejectsTLS11);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TTransportSecurityServerTests.Create(
    'TransportSecurity: TLS server accept'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
