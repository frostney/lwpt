{ TransportSecurity.Test -- deterministic memory-BIO TLS server coverage.

  Darwin deliberately runs only the shared read-bounds regression and the
  actionable server stub. Windows and Unix-not-Darwin pair the production
  server API with an in-memory raw OpenSSL client; no sockets or network are
  involved. }

program TransportSecurity.Test;

{$mode delphi}{$H+}{$codepage utf8}

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
  EMPTY_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-empty-passphrase.p12';
  UTF8_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-utf8-passphrase.p12';
  PKCS12_PASSPHRASE = 'test-only';
  UTF8_PKCS12_PASSPHRASE = 'pässword';
  SCRATCH_DIRECTORY = 'build/tests/tmp/transport-security';
  CLIENT_REQUEST = 'hello from the memory-BIO client';
  SERVER_RESPONSE = 'hello from TransportSecurity server';
  DARWIN_SKIP_REASON =
    'OpenSSL server accept is intentionally unsupported on Darwin; ' +
    'duetto uses Network.framework there';
  OPENSSL_RUNTIME_SKIP_REASON =
    'OpenSSL runtime not available on this host';

type
  TTransportSecurityServerTests = class(TTestSuite)
  private
    FServerBackendAvailable: Boolean;
    procedure ServerTest(const AName: string; const AMethod: TTestMethod);
  public
    procedure SetupTests; override;
    procedure TestActiveOnlyAfterHandshake;
    procedure TestBoundsClamp;
    procedure TestCertificateChainDelivered;
    procedure TestDarwinReportsUnsupportedServerTLS;
    procedure TestEmptyAndUTF8Passphrases;
    procedure TestEmbeddedNULPassphraseRejected;
    procedure TestFatalHandshakePoisonsConnection;
    procedure TestFatalShutdownPoisonsBeforeOutput;
    procedure TestGracefulCloseProducesCloseNotify;
    procedure TestHandshakeTransitionsAndContextReuse;
    procedure TestMissingPKCS12FailsWithoutPathDisclosure;
    procedure TestPeerCloseNotifyReportsPeerClosed;
    procedure TestPendingCiphertextPointerIsStable;
    procedure TestPKCS12LoadFailures;
    procedure TestPKCS12SizeLimit;
    procedure TestPlaintextRoundtripAndPartialCiphertextConsumption;
    procedure TestRenegotiationIsRefused;
    procedure TestStaleErrorQueueIsCleared;
    procedure TestSyscallErrorPoisonsConnection;
    procedure TestTLSFloorRejectsTLS11;
    procedure TestWriteWantRetryRetainsPlaintext;
  end;

function CaptureContextError(const APath: string;
  const APassphrase: UnicodeString): string;
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
  TBIONewFile = function(AFilename, AMode: PAnsiChar): Pointer; cdecl;
  TOpenSSLStackNum = function(AStack: Pointer): LongInt; cdecl;
  TOpenSSLStackValue = function(AStack: Pointer;
    AIndex: LongInt): Pointer; cdecl;
  TSSLContextSetSecurityLevel = procedure(AContext: PSSL_CTX;
    ALevel: LongInt); cdecl;
  TSSLDoHandshake = function(ASSL: PSSL): LongInt; cdecl;
  TSSLGetPeerCertChain = function(ASSL: PSSL): Pointer; cdecl;
  TSSLMethodGetter = function: Pointer; cdecl;
  TSSLRenegotiate = function(ASSL: PSSL): LongInt; cdecl;
  TSSLSetBIO = procedure(ASSL: PSSL; AReadBIO, AWriteBIO: Pointer); cdecl;
  TSSLSetConnectState = procedure(ASSL: PSSL); cdecl;
  TX509GetSubjectName = function(ACertificate: Pointer): Pointer; cdecl;
  TX509NameOneline = function(AName, ABuffer: Pointer;
    ASize: Integer): PAnsiChar; cdecl;

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
  TLS1_2_VERSION = $0303;

var
  RawBIONew: TBIONew;
  RawBIONewFile: TBIONewFile;
  RawBIORead: TBIORead;
  RawBIOSMemory: TBIOSMemory;
  RawBIOWrite: TBIOWrite;
  RawOpenSSLStackNum: TOpenSSLStackNum;
  RawOpenSSLStackValue: TOpenSSLStackValue;
  RawSSLContextSetSecurityLevel: TSSLContextSetSecurityLevel;
  RawSSLDoHandshake: TSSLDoHandshake;
  RawSSLGetPeerCertChain: TSSLGetPeerCertChain;
  RawSSLRenegotiate: TSSLRenegotiate;
  RawSSLSetBIO: TSSLSetBIO;
  RawSSLSetConnectState: TSSLSetConnectState;
  RawX509GetSubjectName: TX509GetSubjectName;
  RawX509NameOneline: TX509NameOneline;

procedure ResolveRawOpenSSLProcedures;
begin
  if Assigned(RawSSLSetBIO) then
    Exit;
  RawBIONew := TBIONew(GetProcedureAddress(SSLUtilHandle, 'BIO_new'));
  RawBIONewFile := TBIONewFile(GetProcedureAddress(SSLUtilHandle,
    'BIO_new_file'));
  RawBIORead := TBIORead(GetProcedureAddress(SSLUtilHandle, 'BIO_read'));
  RawBIOSMemory := TBIOSMemory(GetProcedureAddress(SSLUtilHandle,
    'BIO_s_mem'));
  RawBIOWrite := TBIOWrite(GetProcedureAddress(SSLUtilHandle, 'BIO_write'));
  RawOpenSSLStackNum := TOpenSSLStackNum(GetProcedureAddress(SSLUtilHandle,
    'OPENSSL_sk_num'));
  RawOpenSSLStackValue := TOpenSSLStackValue(GetProcedureAddress(
    SSLUtilHandle, 'OPENSSL_sk_value'));
  RawSSLContextSetSecurityLevel := TSSLContextSetSecurityLevel(
    GetProcedureAddress(SSLLibHandle, 'SSL_CTX_set_security_level'));
  RawSSLDoHandshake := TSSLDoHandshake(GetProcedureAddress(SSLLibHandle,
    'SSL_do_handshake'));
  RawSSLSetBIO := TSSLSetBIO(GetProcedureAddress(SSLLibHandle,
    'SSL_set_bio'));
  RawSSLGetPeerCertChain := TSSLGetPeerCertChain(GetProcedureAddress(
    SSLLibHandle, 'SSL_get_peer_cert_chain'));
  RawSSLRenegotiate := TSSLRenegotiate(GetProcedureAddress(SSLLibHandle,
    'SSL_renegotiate'));
  RawSSLSetConnectState := TSSLSetConnectState(GetProcedureAddress(
    SSLLibHandle, 'SSL_set_connect_state'));
  RawX509GetSubjectName := TX509GetSubjectName(GetProcedureAddress(
    SSLUtilHandle, 'X509_get_subject_name'));
  RawX509NameOneline := TX509NameOneline(GetProcedureAddress(SSLUtilHandle,
    'X509_NAME_oneline'));
  if not Assigned(RawBIONew) or not Assigned(RawBIORead) or
     not Assigned(RawBIOSMemory) or not Assigned(RawBIOWrite) or
     not Assigned(RawOpenSSLStackNum) or
     not Assigned(RawOpenSSLStackValue) or
     not Assigned(RawSSLGetPeerCertChain) or
     not Assigned(RawSSLSetBIO) or not Assigned(RawSSLSetConnectState) or
     not Assigned(RawX509GetSubjectName) or
     not Assigned(RawX509NameOneline) then
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

procedure WriteRawClientPlaintext(var AClient: TRawOpenSSLClient;
  const AText: AnsiString);
var
  Written: Integer;
begin
  ErrClearError;
  Written := SslWrite(AClient.SSL, @AText[1], Length(AText));
  if Written <> Length(AText) then
    raise Exception.CreateFmt('Raw client plaintext write failed: %d',
      [SslGetError(AClient.SSL, Written)]);
end;

function ReadRawClientPlaintext(var AClient: TRawOpenSSLClient): string;
var
  Buffer: array[0..255] of Byte;
  ReadCount: Integer;
begin
  ErrClearError;
  ReadCount := SslRead(AClient.SSL, @Buffer[0], Length(Buffer));
  if ReadCount <= 0 then
    raise Exception.CreateFmt('Raw client plaintext read failed: %d',
      [SslGetError(AClient.SSL, ReadCount)]);
  Result := Copy(PAnsiChar(@Buffer[0]), 1, ReadCount);
end;

function RawClientReceivedIntermediate(
  const AClient: TRawOpenSSLClient): Boolean;
const
  INTERMEDIATE_COMMON_NAME = 'TransportSecurity Test Intermediate CA';
var
  Certificate: Pointer;
  Chain: Pointer;
  I: Integer;
  Name: Pointer;
  Subject: array[0..255] of AnsiChar;
begin
  Result := False;
  Chain := RawSSLGetPeerCertChain(AClient.SSL);
  if not Assigned(Chain) then
    Exit;
  for I := 0 to RawOpenSSLStackNum(Chain) - 1 do
  begin
    Certificate := RawOpenSSLStackValue(Chain, I);
    Name := RawX509GetSubjectName(Certificate);
    if not Assigned(Name) then
      Continue;
    FillChar(Subject, SizeOf(Subject), 0);
    if Assigned(RawX509NameOneline(Name, @Subject[0], Length(Subject))) and
       (Pos(INTERMEDIATE_COMMON_NAME, StrPas(@Subject[0])) > 0) then
      Exit(True);
  end;
end;

procedure QueueStaleOpenSSLError;
const
  MISSING_FILE =
    'build/tests/tmp/transport-security/stale-error-does-not-exist.pem';
  READ_MODE = 'rb';
var
  FirstBIO: Pointer;
  SecondBIO: Pointer;
begin
  if not Assigned(RawBIONewFile) then
    raise Exception.Create('OpenSSL runtime lacks BIO_new_file');
  FirstBIO := RawBIONewFile(PAnsiChar(AnsiString(MISSING_FILE)),
    PAnsiChar(AnsiString(READ_MODE)));
  SecondBIO := RawBIONewFile(PAnsiChar(AnsiString(MISSING_FILE)),
    PAnsiChar(AnsiString(READ_MODE)));
  if Assigned(FirstBIO) or Assigned(SecondBIO) then
    raise Exception.Create('Expected missing-file BIO creation to fail');
  if ErrGetError = 0 then
    raise Exception.Create('Failed to seed the OpenSSL error queue');
end;
{$ENDIF}

procedure TTransportSecurityServerTests.TestActiveOnlyAfterHandshake;
{$IFNDEF DARWIN}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    Expect<Boolean>(Connection.Active).ToBe(False);
    State := TransportSecurityServerHandshake(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantRead));
    Expect<Boolean>(Connection.Active).ToBe(False);
    CreateRawClient(Client);
    DriveHandshake(Connection, Client, Observed);
    Expect<Boolean>(Connection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestBoundsClamp;
{$IFNDEF DARWIN}
var
  Buffer: array[0..0] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateHandshakenPair(Context, Connection, Client, Observed);
    WriteRawClientPlaintext(Client, 'Z');
    PumpClientCiphertext(Client, Connection);
    Buffer[0] := 0;
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      High(Integer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(1);
    Expect<Integer>(Buffer[0]).ToBe(Ord('Z'));
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestCertificateChainDelivered;
{$IFNDEF DARWIN}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateHandshakenPair(Context, Connection, Client, Observed);
    Expect<Boolean>(RawClientReceivedIntermediate(Client)).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestDarwinReportsUnsupportedServerTLS;
var
  ErrorMessage: string;
begin
  ErrorMessage := CaptureContextError(PKCS12_PATH, PKCS12_PASSPHRASE);
  Expect<Boolean>(Pos('not supported on macOS', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('Network.framework', ErrorMessage) > 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestEmptyAndUTF8Passphrases;
{$IFNDEF DARWIN}
var
  EmptyContext: TTransportSecurityServerContext;
  UTF8Context: TTransportSecurityServerContext;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  EmptyContext := nil;
  UTF8Context := nil;
  try
    try
      EmptyContext := TTransportSecurityServerContext.Create(
        EMPTY_PKCS12_PATH, '');
    except
      on E: Exception do
        raise Exception.Create('Empty PKCS#12 passphrase failed: ' +
          E.Message);
    end;
    try
      UTF8Context := TTransportSecurityServerContext.Create(
        UTF8_PKCS12_PATH, UTF8_PKCS12_PASSPHRASE);
    except
      on E: Exception do
        raise Exception.Create('UTF-8 PKCS#12 passphrase failed: ' +
          E.Message);
    end;
    Expect<Boolean>(Assigned(EmptyContext)).ToBe(True);
    Expect<Boolean>(Assigned(UTF8Context)).ToBe(True);
  finally
    CloseTransportSecurityServerContext(EmptyContext);
    CloseTransportSecurityServerContext(UTF8Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestEmbeddedNULPassphraseRejected;
{$IFNDEF DARWIN}
var
  EmbeddedNULPassphrase: UnicodeString;
  ErrorMessage: string;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  EmbeddedNULPassphrase := PKCS12_PASSPHRASE + #0 + 'hidden-suffix';
  ErrorMessage := CaptureContextError(PKCS12_PATH, EmbeddedNULPassphrase);
  Expect<Boolean>(Pos('NUL', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('hidden-suffix', ErrorMessage) = 0).ToBe(True);
  {$ENDIF}
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

procedure TTransportSecurityServerTests.TestPeerCloseNotifyReportsPeerClosed;
{$IFNDEF DARWIN}
var
  Buffer: array[0..0] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
  ShutdownResult: Integer;
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
    ShutdownResult := SslShutdown(Client.SSL);
    if ShutdownResult < 0 then
      raise Exception.CreateFmt('Raw client shutdown failed: %d',
        [SslGetError(Client.SSL, ShutdownResult)]);
    PumpClientCiphertext(Client, Connection);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(Ord(ReadResult.State)).ToBe(Ord(tssPeerClosed));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(0);
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestPendingCiphertextPointerIsStable;
{$IFNDEF DARWIN}
var
  Buffer: array[0..255] of Byte;
  Ciphertext: Pointer;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  OriginalCiphertext: Pointer;
  Pending: Integer;
  ReadResult: TTransportSecurityIOResult;
  RetryText: AnsiString;
  State: TTransportSecurityState;
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
    WriteRawClientPlaintext(Client, CLIENT_REQUEST);
    PumpClientCiphertext(Client, Connection);

    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Pending := TransportSecurityGetCiphertext(Connection, OriginalCiphertext);
    Expect<Boolean>(Pending > 0).ToBe(True);

    State := TransportSecurityServerHandshake(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(Ord(ReadResult.State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(0);
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    RetryText := 'write waits without consuming caller plaintext';
    WriteResult := TransportSecurityServerWrite(Connection, @RetryText[1],
      Length(RetryText));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(0);
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    PumpServerCiphertext(Connection, Client);
    Expect<string>(ReadRawClientPlaintext(Client)).ToBe(SERVER_RESPONSE);

    WriteResult := TransportSecurityServerWrite(Connection, @RetryText[1],
      Length(RetryText));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    PumpServerCiphertext(Connection, Client);
    Expect<string>(ReadRawClientPlaintext(Client)).ToBe(RetryText);

    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(Length(CLIENT_REQUEST));
    Expect<string>(Copy(PAnsiChar(@Buffer[0]), 1,
      ReadResult.BytesProcessed)).ToBe(CLIENT_REQUEST);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestPKCS12LoadFailures;
var
  Context: TTransportSecurityServerContext;
  ErrorMessage: string;
  GarbagePath: string;
begin
  Context := nil;
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

  try
    Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
      PKCS12_PASSPHRASE);
    Expect<Boolean>(Assigned(Context)).ToBe(True);
  finally
    CloseTransportSecurityServerContext(Context);
  end;
end;

procedure TTransportSecurityServerTests.TestPKCS12SizeLimit;
{$IFNDEF DARWIN}
const
  OVERSIZED_PKCS12_LENGTH = 16 * 1024 * 1024 + 1;
var
  ErrorMessage: string;
  Identity: TFileStream;
  OversizedPath: string;
  Passphrase: UnicodeString;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  ForceDirectories(SCRATCH_DIRECTORY);
  OversizedPath := SCRATCH_DIRECTORY + '/oversized-private-identity.p12';
  Identity := TFileStream.Create(OversizedPath, fmCreate);
  try
    Identity.Size := OVERSIZED_PKCS12_LENGTH;
  finally
    Identity.Free;
  end;
  Passphrase := 'oversized-secret-passphrase';
  ErrorMessage := CaptureContextError(OversizedPath, Passphrase);
  Expect<Boolean>(Pos('16 MiB limit', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos(OversizedPath, ErrorMessage) = 0).ToBe(True);
  Expect<Boolean>(Pos(Passphrase, ErrorMessage) = 0).ToBe(True);
  {$ENDIF}
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

procedure TTransportSecurityServerTests.TestRenegotiationIsRefused;
{$IFNDEF DARWIN}
var
  Buffer: array[0..0] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ErrorCode: Integer;
  I: Integer;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
  RenegotiationRefused: Boolean;
  StepResult: Integer;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  ResolveRawOpenSSLProcedures;
  if not Assigned(RawSSLRenegotiate) then
    raise Exception.Create('OpenSSL runtime lacks SSL_renegotiate');
  if not Assigned(RawSSLDoHandshake) then
    raise Exception.Create('OpenSSL runtime lacks SSL_do_handshake');
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawClient(Client, TLS1_2_VERSION);
    DriveHandshake(Connection, Client, Observed);
    ErrClearError;
    Expect<Integer>(RawSSLRenegotiate(Client.SSL)).ToBe(1);
    RenegotiationRefused := False;
    for I := 1 to 32 do
    begin
      if RenegotiationRefused then
        Break;
      ErrClearError;
      StepResult := RawSSLDoHandshake(Client.SSL);
      if StepResult <= 0 then
      begin
        ErrorCode := SslGetError(Client.SSL, StepResult);
        RenegotiationRefused := (ErrorCode <> SSL_ERROR_WANT_READ) and
          (ErrorCode <> SSL_ERROR_WANT_WRITE);
      end;
      PumpClientCiphertext(Client, Connection);
      ReadResult := TransportSecurityServerRead(Connection, Buffer,
        Length(Buffer));
      RenegotiationRefused := RenegotiationRefused or
        (ReadResult.State = tssError) or
        (ReadResult.State = tssPeerClosed);
      PumpServerCiphertext(Connection, Client);
    end;
    Expect<Boolean>(RenegotiationRefused).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestStaleErrorQueueIsCleared;
{$IFNDEF DARWIN}
var
  Buffer: array[0..255] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
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
    WriteRawClientPlaintext(Client, CLIENT_REQUEST);
    PumpClientCiphertext(Client, Connection);

    QueueStaleOpenSSLError;
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(Length(CLIENT_REQUEST));
    Expect<Int64>(Int64(ErrGetError)).ToBe(0);

    QueueStaleOpenSSLError;
    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(SERVER_RESPONSE));
    Expect<Int64>(Int64(ErrGetError)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestSyscallErrorPoisonsConnection;
{$IFNDEF DARWIN}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ObservedError: Integer;
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
    { OpenSSL 3 classifies ordinary unexpected EOF as SSL_ERROR_SSL, while
      a memory BIO has no operating-system syscall. The dev-only hook clears
      the BIO retry flags between SSL_read and SSL_get_error so this test can
      observe the otherwise unreachable SSL_ERROR_SYSCALL classification and
      route it through the production poison path. }
    State := TransportSecurityTestInjectSyscallError(Connection,
      ObservedError);
    Expect<Integer>(ObservedError).ToBe(SSL_ERROR_SYSCALL);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssError));
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestWriteWantRetryRetainsPlaintext;
{$IFNDEF DARWIN}
const
  LARGE_WRITE_SIZE = 64 * 1024 + 137;
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Expected: TBytes;
  I: Integer;
  Observed: THandshakeObservations;
  Offset: Integer;
  Payload: TBytes;
  ReadCount: Integer;
  Received: TBytes;
  Step: Integer;
  WriteCompleted: Boolean;
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
    SetLength(Payload, LARGE_WRITE_SIZE);
    for I := 0 to High(Payload) do
      Payload[I] := Byte((I * 31 + 17) and $FF);
    Expected := Copy(Payload, 0, Length(Payload));

    WriteResult := TransportSecurityServerWrite(Connection, @Payload[0],
      Length(Payload));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(0);
    FillChar(Payload[0], Length(Payload), $A5);

    WriteCompleted := False;
    for Step := 1 to 128 do
    begin
      PumpServerCiphertext(Connection, Client);
      WriteResult := TransportSecurityServerWrite(Connection, nil, 0);
      if WriteResult.BytesProcessed > 0 then
      begin
        Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(Expected));
        WriteCompleted := True;
      end;
      if WriteResult.State = tssError then
        raise Exception.Create('Retained OpenSSL write retry failed');
      if WriteCompleted and
         (TransportSecurityPendingCiphertext(Connection) = 0) then
        Break;
    end;
    PumpServerCiphertext(Connection, Client);
    Expect<Boolean>(WriteCompleted).ToBe(True);

    SetLength(Received, Length(Expected));
    Offset := 0;
    while Offset < Length(Received) do
    begin
      ErrClearError;
      ReadCount := SslRead(Client.SSL, @Received[Offset],
        Length(Received) - Offset);
      if ReadCount <= 0 then
        raise Exception.CreateFmt('Raw client large read failed: %d',
          [SslGetError(Client.SSL, ReadCount)]);
      Inc(Offset, ReadCount);
    end;
    Expect<Boolean>(CompareByte(Expected[0], Received[0],
      Length(Expected)) = 0).ToBe(True);
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

procedure TTransportSecurityServerTests.TestFatalShutdownPoisonsBeforeOutput;
{$IFNDEF DARWIN}
var
  Buffer: array[0..16383] of Byte;
  Client: TRawOpenSSLClient;
  ClientReadResult: Integer;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ErrorCode: Integer;
  Observed: THandshakeObservations;
  Pending: Int64;
  ReadCount: Integer;
  ShutdownResult: Integer;
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
    ErrClearError;
    ShutdownResult := SslShutdown(Client.SSL);
    if ShutdownResult < 0 then
      raise Exception.CreateFmt('Raw client shutdown failed: %d',
        [SslGetError(Client.SSL, ShutdownResult)]);
    Pending := BIO_ctrl(Client.WriteBIO, BIO_CTRL_PENDING_COMMAND, 0, nil);
    if (Pending <= 0) or (Pending > Length(Buffer)) then
      raise Exception.Create('Raw client did not emit a bounded close_notify');
    ReadCount := RawBIORead(Client.WriteBIO, @Buffer[0], Integer(Pending));
    if ReadCount <= 0 then
      raise Exception.Create('Raw client close_notify drain failed');
    Buffer[ReadCount - 1] := Buffer[ReadCount - 1] xor $01;
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection, @Buffer[0],
      ReadCount)).ToBe(ReadCount);

    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    PumpServerCiphertext(Connection, Client);
    ErrClearError;
    ClientReadResult := SslRead(Client.SSL, @Buffer[0], 1);
    ErrorCode := SslGetError(Client.SSL, ClientReadResult);
    Expect<Integer>(ClientReadResult).ToBe(0);
    Expect<Integer>(ErrorCode).ToBe(SSL_ERROR_ZERO_RETURN);

    { The first shutdown step above emitted the legitimate close_notify. The
      corrupted peer alert is classified by this second step; fatal output
      must be discarded instead of surfacing another WANT-write. }
    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssError));
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
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

procedure TTransportSecurityServerTests.ServerTest(const AName: string;
  const AMethod: TTestMethod);
begin
  if FServerBackendAvailable then
    Test(AName, AMethod)
  else
    Skip(AName, AMethod, OPENSSL_RUNTIME_SKIP_REASON);
end;

procedure TTransportSecurityServerTests.SetupTests;
begin
  {$IFDEF DARWIN}
  Skip('Active becomes true only after the server handshake',
    TestActiveOnlyAfterHandshake, DARWIN_SKIP_REASON);
  Skip('server read clamps oversized lengths on a handshaken connection',
    TestBoundsClamp, DARWIN_SKIP_REASON);
  Skip('PKCS#12 chain delivers the intermediate certificate',
    TestCertificateChainDelivered, DARWIN_SKIP_REASON);
  Test('Darwin server API reports Network.framework alternative',
    TestDarwinReportsUnsupportedServerTLS);
  Skip('empty and UTF-8 PKCS#12 passphrases load',
    TestEmptyAndUTF8Passphrases, DARWIN_SKIP_REASON);
  Skip('embedded-NUL PKCS#12 passphrase is rejected',
    TestEmbeddedNULPassphraseRejected, DARWIN_SKIP_REASON);
  Skip('missing PKCS#12 fails without disclosing path',
    TestMissingPKCS12FailsWithoutPathDisclosure, DARWIN_SKIP_REASON);
  Skip('peer close_notify reports peer-closed and poisons the connection',
    TestPeerCloseNotifyReportsPeerClosed, DARWIN_SKIP_REASON);
  Skip('pending ciphertext pointer stays stable across protocol calls',
    TestPendingCiphertextPointerIsStable, DARWIN_SKIP_REASON);
  Skip('garbage and wrong-pass PKCS#12 fail actionably',
    TestPKCS12LoadFailures, DARWIN_SKIP_REASON);
  Skip('PKCS#12 identities above 16 MiB fail without disclosure',
    TestPKCS12SizeLimit, DARWIN_SKIP_REASON);
  Skip('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse, DARWIN_SKIP_REASON);
  Skip('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption,
    DARWIN_SKIP_REASON);
  Skip('fatal handshake poisons connection',
    TestFatalHandshakePoisonsConnection, DARWIN_SKIP_REASON);
  Skip('fatal shutdown poisons before retaining alert output',
    TestFatalShutdownPoisonsBeforeOutput, DARWIN_SKIP_REASON);
  Skip('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify, DARWIN_SKIP_REASON);
  Skip('TLS 1.2 renegotiation is refused', TestRenegotiationIsRefused,
    DARWIN_SKIP_REASON);
  Skip('stale OpenSSL error queue is cleared before server operations',
    TestStaleErrorQueueIsCleared, DARWIN_SKIP_REASON);
  Skip('SSL_ERROR_SYSCALL poisons the connection',
    TestSyscallErrorPoisonsConnection, DARWIN_SKIP_REASON);
  Skip('TLS floor rejects TLS 1.1', TestTLSFloorRejectsTLS11,
    DARWIN_SKIP_REASON);
  Skip('SSL_write WANT retry retains the original plaintext',
    TestWriteWantRetryRetainsPlaintext, DARWIN_SKIP_REASON);
  {$ELSE}
  FServerBackendAvailable := TransportSecurityServerBackendAvailable;
  ServerTest('Active becomes true only after the server handshake',
    TestActiveOnlyAfterHandshake);
  ServerTest('server read clamps oversized lengths on a handshaken connection',
    TestBoundsClamp);
  ServerTest('PKCS#12 chain delivers the intermediate certificate',
    TestCertificateChainDelivered);
  Skip('Darwin server API reports Network.framework alternative',
    TestDarwinReportsUnsupportedServerTLS, 'Darwin-only behavior');
  ServerTest('empty and UTF-8 PKCS#12 passphrases load',
    TestEmptyAndUTF8Passphrases);
  ServerTest('embedded-NUL PKCS#12 passphrase is rejected',
    TestEmbeddedNULPassphraseRejected);
  ServerTest('missing PKCS#12 fails without disclosing path',
    TestMissingPKCS12FailsWithoutPathDisclosure);
  ServerTest('peer close_notify reports peer-closed and poisons the connection',
    TestPeerCloseNotifyReportsPeerClosed);
  ServerTest('pending ciphertext pointer stays stable across protocol calls',
    TestPendingCiphertextPointerIsStable);
  ServerTest('garbage and wrong-pass PKCS#12 fail actionably',
    TestPKCS12LoadFailures);
  ServerTest('PKCS#12 identities above 16 MiB fail without disclosure',
    TestPKCS12SizeLimit);
  ServerTest('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse);
  ServerTest('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption);
  ServerTest('fatal handshake poisons connection',
    TestFatalHandshakePoisonsConnection);
  ServerTest('fatal shutdown poisons before retaining alert output',
    TestFatalShutdownPoisonsBeforeOutput);
  ServerTest('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify);
  ServerTest('TLS 1.2 renegotiation is refused', TestRenegotiationIsRefused);
  ServerTest('stale OpenSSL error queue is cleared before server operations',
    TestStaleErrorQueueIsCleared);
  ServerTest('SSL_ERROR_SYSCALL poisons the connection',
    TestSyscallErrorPoisonsConnection);
  ServerTest('TLS floor rejects TLS 1.1', TestTLSFloorRejectsTLS11);
  ServerTest('SSL_write WANT retry retains the original plaintext',
    TestWriteWantRetryRetainsPlaintext);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TTransportSecurityServerTests.Create(
    'TransportSecurity: TLS server accept'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
