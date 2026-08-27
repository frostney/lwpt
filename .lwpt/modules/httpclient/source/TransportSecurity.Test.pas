{ TransportSecurity.Test -- deterministic in-memory TLS server coverage.

  Darwin exercises the public Secure Transport server lifecycle directly.
  Unix-not-Darwin pairs the production server API with a raw in-memory OpenSSL client;
  Windows pairs it with a raw in-memory SChannel client, because the Windows
  server backend is native SChannel and pulls in no OpenSSL at all. Identity,
  flow-configuration, and fatal-handshake coverage is backend-neutral and runs
  everywhere a server backend exists. No sockets or network are involved. }

program TransportSecurity.Test;

{$mode delphi}{$H+}{$codepage utf8}

{ Mirrors TransportSecurity's own backend selection so the suite gates on the
  backend under test rather than on the platform. Windows drives the native
  SChannel server with an in-memory SChannel client and links no OpenSSL;
  Unix-not-Darwin drives the memory-BIO OpenSSL server with a raw in-memory
  OpenSSL client. }
{$IFDEF MSWINDOWS}
{$DEFINE TRANSPORT_SECURITY_SCHANNEL_SERVER}
{$DEFINE TRANSPORT_SECURITY_SERVER}
{$ENDIF}
{$IFDEF DARWIN}
{$DEFINE TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
{$DEFINE TRANSPORT_SECURITY_SERVER}
{$ENDIF}
{$IFDEF UNIX}
{$IFNDEF DARWIN}
{$DEFINE TRANSPORT_SECURITY_OPENSSL}
{$DEFINE TRANSPORT_SECURITY_SERVER}
{$ENDIF}
{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads, { must come first so TThread has a thread driver }
  {$ENDIF}
  Classes,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF DARWIN}
  Process,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Process,
  Windows,
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  DynLibs,
  OpenSSL,
  {$ENDIF}
  TestingPascalLibrary,
  TransportSecurity;

const
  {$IFDEF DARWIN}
  PKCS12_PATH =
    'tests/fixtures/registry/localhost-native-identity.p12';
  {$ELSE}
  PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-test-identity.p12';
  {$ENDIF}
  EMPTY_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-empty-passphrase.p12';
  UTF8_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-utf8-passphrase.p12';
  FUTURE_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-future-identity.p12';
  CYCLIC_CHAIN_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-cycle-identity.p12';
  INCOHERENT_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-incoherent-identity.p12';
  LEAF_CA_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-leaf-ca-identity.p12';
  LEAF_NO_BASIC_CONSTRAINTS_PKCS12_PATH =
    'packages/httpclient/source/fixtures/' +
    'localhost-no-basic-constraints-identity.p12';
  NON_CA_ISSUER_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-non-ca-issuer-identity.p12';
  NO_CERTSIGN_ISSUER_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-no-certsign-identity.p12';
  PATH_LENGTH_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-pathlen-identity.p12';
  SELF_SIGNED_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-self-signed-dev.p12';
  WRONG_PURPOSE_PKCS12_PATH =
    'packages/httpclient/source/fixtures/localhost-wrong-purpose-identity.p12';
  PKCS12_PASSPHRASE = 'test-only';
  UTF8_PKCS12_PASSPHRASE = 'pässword';
  SCRATCH_DIRECTORY = 'build/tests/tmp/transport-security';
  CLIENT_REQUEST = 'hello from the memory-BIO client';
  SERVER_RESPONSE = 'hello from TransportSecurity server';
  DARWIN_SKIP_REASON =
    'the raw in-memory Secure Transport client is not built for this case';
  OPENSSL_RUNTIME_SKIP_REASON =
    'OpenSSL runtime not available on this host';
  OPENSSL_CLIENT_SKIP_REASON =
    'the raw in-memory OpenSSL loopback client is not built on this backend';
  SCHANNEL_CLIENT_SKIP_REASON =
    'the raw in-memory SChannel loopback client is Windows-only';

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
    procedure TestDarwinConcurrentSecureTransportFirstUse;
    procedure TestDarwinSecureTransportCleanupFailures;
    procedure TestDarwinSecureTransportNetworkFetchDisabled;
    procedure TestDarwinSecureTransportServerLifecycle;
    procedure TestDarwinSecureTransportRoundTrip;
    procedure TestEmptyAndUTF8Passphrases;
    procedure TestEmbeddedNULPassphraseRejected;
    procedure TestFatalHandshakePoisonsConnection;
    procedure TestFatalShutdownPoisonsBeforeOutput;
    procedure TestInputFlowConfiguration;
    procedure TestInputFlowPrefixAdmissionAndCounters;
    procedure TestGracefulCloseProducesCloseNotify;
    procedure TestHandshakeTransitionsAndContextReuse;
    procedure TestMissingPKCS12FailsWithoutPathDisclosure;
    procedure TestPeerCloseNotifyReportsPeerClosed;
    procedure TestPendingCiphertextPointerIsStable;
    procedure TestPKCS12LoadFailures;
    procedure TestPKCS12SizeLimit;
    procedure TestPKCS12BytesArePrimaryInput;
    procedure TestPKCS12PathRefusesSymbolicLink;
    procedure TestPlaintextRoundtripAndPartialCiphertextConsumption;
    procedure TestRenegotiationIsRefused;
    procedure TestSChannelCertificateChainDelivered;
    procedure TestSChannelGracefulCloseProducesCloseNotify;
    procedure TestSChannelIdentityImportsIsolatedKeyContainers;
    procedure TestSChannelHandshakeRoundtripAndContextReuse;
    procedure TestSChannelInputFlowPrefixAdmissionAndCounters;
    procedure TestSChannelPeerCloseNotifyReportsPeerClosed;
    procedure TestSChannelProtocolCeilingFollowsOperatingSystem;
    procedure TestSChannelReloadRetainsPreviousKeyContainer;
    procedure TestSChannelPendingCiphertextPointerAndPartialConsumption;
    procedure TestSChannelWriteWantRetryRetainsPlaintext;
    procedure TestStaleErrorQueueIsCleared;
    procedure TestStrictIdentityAllowsLeafWithoutBasicConstraints;
    procedure TestStrictIdentityValidation;
    procedure TestSyscallErrorPoisonsConnection;
    procedure TestTLSFloorRejectsTLS11;
    procedure TestWriteWantRetryRetainsPlaintext;
    procedure TestReloadRetainsSnapshotsAndFailedReloadKeepsActive;
  end;

{$IFDEF DARWIN}
type
  TTestSSLContextRef = Pointer;
  TTestSSLConnectionRef = Pointer;
  TTestSSLReadFunc = function(AConnection: TTestSSLConnectionRef;
    AData: Pointer; var ADataLength: PtrUInt): LongInt; cdecl;
  TTestSSLWriteFunc = function(AConnection: TTestSSLConnectionRef;
    AData: Pointer; var ADataLength: PtrUInt): LongInt; cdecl;
  TRawSecureTransportClient = record
    Context: TTestSSLContextRef;
    Input: TBytes;
    Output: TBytes;
  end;

  TSecureTransportContextWorker = class(TThread)
  private
    FErrorMessage: string;
  protected
    procedure Execute; override;
  public
    constructor Create;
    property ErrorMessage: string read FErrorMessage;
  end;

const
  TEST_ERR_SEC_SUCCESS = 0;
  TEST_ERR_SSL_WOULD_BLOCK = -9803;
  TEST_K_SSL_CLIENT_SIDE = 1;
  TEST_K_SSL_STREAM_TYPE = 0;
  TEST_K_TLS_PROTOCOL_11 = 7;
  TEST_K_TLS_PROTOCOL_12 = 8;

function TestSSLCreateContext(AAllocator: Pointer; AProtocolSide,
  AConnectionType: Integer): TTestSSLContextRef; cdecl;
  external name 'SSLCreateContext';
function TestSSLSetIOFuncs(AContext: TTestSSLContextRef;
  AReadFunc: TTestSSLReadFunc; AWriteFunc: TTestSSLWriteFunc): LongInt; cdecl;
  external name 'SSLSetIOFuncs';
function TestSSLSetConnection(AContext: TTestSSLContextRef;
  AConnection: TTestSSLConnectionRef): LongInt; cdecl;
  external name 'SSLSetConnection';
function TestSSLSetEnableCertVerify(AContext: TTestSSLContextRef;
  AEnable: ByteBool): LongInt; cdecl;
  external name 'SSLSetEnableCertVerify';
function TestSSLSetProtocolVersionMin(AContext: TTestSSLContextRef;
  AVersion: Integer): LongInt; cdecl;
  external name 'SSLSetProtocolVersionMin';
function TestSSLSetProtocolVersionMax(AContext: TTestSSLContextRef;
  AVersion: Integer): LongInt; cdecl;
  external name 'SSLSetProtocolVersionMax';
function TestSSLCopyPeerTrust(AContext: TTestSSLContextRef;
  out ATrust: Pointer): LongInt; cdecl;
  external name 'SSLCopyPeerTrust';
function TestSecTrustGetCertificateCount(ATrust: Pointer): NativeInt; cdecl;
  external name 'SecTrustGetCertificateCount';
function TestSSLHandshake(AContext: TTestSSLContextRef): LongInt; cdecl;
  external name 'SSLHandshake';
function TestSSLRead(AContext: TTestSSLContextRef; AData: Pointer;
  ADataLength: PtrUInt; var AProcessed: PtrUInt): LongInt; cdecl;
  external name 'SSLRead';
function TestSSLWrite(AContext: TTestSSLContextRef; AData: Pointer;
  ADataLength: PtrUInt; var AProcessed: PtrUInt): LongInt; cdecl;
  external name 'SSLWrite';
procedure TestCFRelease(AObject: Pointer); cdecl; external name 'CFRelease';

function RawSecureTransportRead(AConnection: TTestSSLConnectionRef;
  AData: Pointer; var ADataLength: PtrUInt): LongInt; cdecl;
var
  Available, Requested, Taken: Integer;
  Client: ^TRawSecureTransportClient;
begin
  Client := AConnection;
  Available := Length(Client^.Input);
  Requested := Integer(ADataLength);
  Taken := Requested;
  if Taken > Available then Taken := Available;
  if Taken > 0 then
  begin
    Move(Client^.Input[0], AData^, Taken);
    if Taken < Available then
      Move(Client^.Input[Taken], Client^.Input[0], Available - Taken);
    SetLength(Client^.Input, Available - Taken);
  end;
  ADataLength := Taken;
  if Taken = Requested then Result := TEST_ERR_SEC_SUCCESS
  else Result := TEST_ERR_SSL_WOULD_BLOCK;
end;

function RawSecureTransportWrite(AConnection: TTestSSLConnectionRef;
  AData: Pointer; var ADataLength: PtrUInt): LongInt; cdecl;
var
  Client: ^TRawSecureTransportClient;
  Existing: Integer;
begin
  Client := AConnection;
  Existing := Length(Client^.Output);
  SetLength(Client^.Output, Existing + Integer(ADataLength));
  if ADataLength > 0 then
    Move(AData^, Client^.Output[Existing], ADataLength);
  Result := TEST_ERR_SEC_SUCCESS;
end;

procedure CreateRawSecureTransportClientWithRange(
  var AClient: TRawSecureTransportClient; const AMinimum,
  AMaximum: Integer);
begin
  FillChar(AClient, SizeOf(AClient), 0);
  AClient.Context := TestSSLCreateContext(nil, TEST_K_SSL_CLIENT_SIDE,
    TEST_K_SSL_STREAM_TYPE);
  if (AClient.Context = nil)
    or (TestSSLSetIOFuncs(AClient.Context, RawSecureTransportRead,
      RawSecureTransportWrite) <> TEST_ERR_SEC_SUCCESS)
    or (TestSSLSetConnection(AClient.Context, @AClient)
      <> TEST_ERR_SEC_SUCCESS)
    or (TestSSLSetEnableCertVerify(AClient.Context, False)
      <> TEST_ERR_SEC_SUCCESS)
    or (TestSSLSetProtocolVersionMin(AClient.Context, AMinimum)
      <> TEST_ERR_SEC_SUCCESS)
    or ((AMaximum <> 0) and (TestSSLSetProtocolVersionMax(AClient.Context,
      AMaximum) <> TEST_ERR_SEC_SUCCESS)) then
    raise Exception.Create('Raw Secure Transport client setup failed');
end;

procedure CreateRawSecureTransportClient(
  var AClient: TRawSecureTransportClient);
begin
  CreateRawSecureTransportClientWithRange(AClient,
    TEST_K_TLS_PROTOCOL_12, 0);
end;

procedure FreeRawSecureTransportClient(
  var AClient: TRawSecureTransportClient);
begin
  if AClient.Context <> nil then TestCFRelease(AClient.Context);
  AClient.Context := nil;
  SetLength(AClient.Input, 0);
  SetLength(AClient.Output, 0);
end;

procedure PumpRawSecureTransportClient(
  var AClient: TRawSecureTransportClient;
  var AConnection: TTransportSecurityConnection);
var
  Accepted: Integer;
begin
  if Length(AClient.Output) = 0 then Exit;
  Accepted := TransportSecurityFeedCiphertext(AConnection,
    @AClient.Output[0], Length(AClient.Output));
  if Accepted <> Length(AClient.Output) then
    raise Exception.Create('Secure Transport server rejected client output');
  SetLength(AClient.Output, 0);
end;

procedure PumpRawSecureTransportServer(
  var AConnection: TTransportSecurityConnection;
  var AClient: TRawSecureTransportClient);
var
  Buffer: Pointer;
  Existing, Pending: Integer;
begin
  Pending := TransportSecurityGetCiphertext(AConnection, Buffer);
  if Pending <= 0 then Exit;
  Existing := Length(AClient.Input);
  SetLength(AClient.Input, Existing + Pending);
  Move(Buffer^, AClient.Input[Existing], Pending);
  TransportSecurityConsumeCiphertext(AConnection, Pending);
end;

procedure WriteRawSecureTransportClientPlaintext(
  var AClient: TRawSecureTransportClient; const AText: AnsiString);
var
  Processed: PtrUInt;
  Status: LongInt;
begin
  Processed := 0;
  Status := TestSSLWrite(AClient.Context, @AText[1], Length(AText), Processed);
  if (Status <> TEST_ERR_SEC_SUCCESS) or (Processed <> PtrUInt(Length(AText))) then
    raise Exception.CreateFmt(
      'Raw Secure Transport client plaintext write failed: %d/%d',
      [Status, Processed]);
end;

function ReadRawSecureTransportClientPlaintext(
  var AClient: TRawSecureTransportClient): string;
var
  Buffer: array[0..255] of Byte;
  Processed: PtrUInt;
  Status: LongInt;
begin
  Processed := 0;
  Status := TestSSLRead(AClient.Context, @Buffer[0], Length(Buffer), Processed);
  if (Status <> TEST_ERR_SEC_SUCCESS) or (Processed = 0) then
    raise Exception.CreateFmt(
      'Raw Secure Transport client plaintext read failed: %d/%d',
      [Status, Processed]);
  Result := Copy(PAnsiChar(@Buffer[0]), 1, Processed);
end;

function RawSecureTransportPeerCertificateCount(
  const AClient: TRawSecureTransportClient): NativeInt;
var
  Status: LongInt;
  Trust: Pointer;
begin
  Trust := nil;
  Status := TestSSLCopyPeerTrust(AClient.Context, Trust);
  if (Status <> TEST_ERR_SEC_SUCCESS) or (Trust = nil) then
    raise Exception.CreateFmt(
      'Raw Secure Transport client peer trust failed: %d', [Status]);
  try
    Result := TestSecTrustGetCertificateCount(Trust);
  finally
    TestCFRelease(Trust);
  end;
end;

procedure DriveRawSecureTransportHandshake(
  var AConnection: TTransportSecurityConnection;
  var AClient: TRawSecureTransportClient);
var
  ClientDone, ServerDone: Boolean;
  ClientStatus: LongInt;
  ServerState: TTransportSecurityState;
  Step: Integer;
begin
  ClientDone := False;
  ServerDone := False;
  for Step := 1 to 100 do
  begin
    if not ClientDone then
    begin
      ClientStatus := TestSSLHandshake(AClient.Context);
      if ClientStatus = TEST_ERR_SEC_SUCCESS then ClientDone := True
      else if ClientStatus <> TEST_ERR_SSL_WOULD_BLOCK then
        raise Exception.CreateFmt('Raw Secure Transport client handshake failed: %d',
          [ClientStatus]);
    end;
    PumpRawSecureTransportClient(AClient, AConnection);
    if not ServerDone then
    begin
      ServerState := TransportSecurityServerHandshake(AConnection);
      if ServerState = tssDone then ServerDone := True
      else if not (ServerState in [tssWantRead, tssWantWrite]) then
        raise Exception.Create('Secure Transport server handshake failed');
    end;
    PumpRawSecureTransportServer(AConnection, AClient);
    if ClientDone and ServerDone
      and (Length(AClient.Output) = 0)
      and (TransportSecurityPendingCiphertext(AConnection) = 0) then Exit;
  end;
  raise Exception.Create('Secure Transport in-memory handshake timed out');
end;

constructor TSecureTransportContextWorker.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FErrorMessage := '';
end;

procedure TSecureTransportContextWorker.Execute;
var
  Context: TTransportSecurityServerContext;
begin
  Context := nil;
  try
    try
      Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
        PKCS12_PASSPHRASE);
    except
      on E: Exception do FErrorMessage := E.Message;
    end;
  finally
    try
      CloseTransportSecurityServerContext(Context);
    except
      on E: Exception do
        if FErrorMessage = '' then FErrorMessage := E.Message;
    end;
  end;
end;
{$ENDIF}

{$IFDEF DARWIN}
function DarwinTemporaryServerKeychainCount: Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(GetTempDir) +
    'secure-transport-server-' + IntToStr(GetProcessID) + '-*.keychain',
    faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function DarwinDeadProcessID: LongInt;
var
  ProcessInstance: TProcess;
begin
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := '/usr/bin/true';
    ProcessInstance.Options := [poWaitOnExit];
    ProcessInstance.Execute;
    Result := ProcessInstance.ProcessID;
    if (ProcessInstance.ExitStatus <> 0)
      or (FpKill(Result, 0) = 0)
      or (FpGetErrNo <> ESysESRCH) then
      raise Exception.Create('Could not create a dead process ID fixture');
  finally
    ProcessInstance.Free;
  end;
end;
{$ENDIF}

  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  TBeginAbortWorker = class(TThread)
  private
    FContext: TTransportSecurityServerContext;
    FErrorMessage: string;
    FOperations: LongInt;
    FStarted: LongInt;
    FStopRequested: LongInt;
    function GetOperations: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(const AContext: TTransportSecurityServerContext);
    procedure RequestStop;
    function WaitForOperations(const AMinimum: LongInt;
      const ATimeoutMilliseconds: QWord): Boolean;
    function WaitUntilStarted(const ATimeoutMilliseconds: QWord): Boolean;
    property ErrorMessage: string read FErrorMessage;
    property Operations: LongInt read GetOperations;
  end;
  {$ENDIF}

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

function LoadFixtureBytes(const APath: string): TBytes;
var
  Input: TFileStream;
begin
  Result := nil;
  Input := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Input.Size);
    if Length(Result) > 0 then
      Input.ReadBuffer(Result[0], Length(Result));
  finally
    Input.Free;
  end;
end;

{$IFDEF MSWINDOWS}
function TryCreateWindowsJunction(const ALinkDirectory,
  ALinkTarget: string): Boolean;
var
  CommandInterpreter: string;
  ProcessInstance: TProcess;
begin
  Result := False;
  CommandInterpreter := SysUtils.GetEnvironmentVariable('COMSPEC');
  if CommandInterpreter = '' then
    CommandInterpreter := 'cmd.exe';
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := CommandInterpreter;
    ProcessInstance.Parameters.Add('/C');
    ProcessInstance.Parameters.Add('mklink /J "' +
      StringReplace(ALinkDirectory, '/', '\', [rfReplaceAll]) + '" "' +
      StringReplace(ALinkTarget, '/', '\', [rfReplaceAll]) + '"');
    ProcessInstance.Options := [poWaitOnExit];
    try
      ProcessInstance.Execute;
      Result := ProcessInstance.ExitStatus = 0;
    except
      Result := False;
    end;
  finally
    ProcessInstance.Free;
  end;
end;

procedure RemoveWindowsJunctionIfPresent(const ALinkDirectory: string);
var
  ErrorCode: DWORD;
begin
  if Windows.RemoveDirectoryW(PWideChar(UnicodeString(ALinkDirectory))) then
    Exit;
  ErrorCode := Windows.GetLastError;
  if ErrorCode in [Windows.ERROR_FILE_NOT_FOUND,
     Windows.ERROR_PATH_NOT_FOUND] then
    Exit;
  raise Exception.CreateFmt(
    'Failed to remove PKCS#12 junction fixture (%d)', [ErrorCode]);
end;

function WindowsJunctionTestAvailable: Boolean;
var
  LinkDirectory: string;
  LinkTarget: string;
begin
  ForceDirectories(SCRATCH_DIRECTORY);
  LinkDirectory := SCRATCH_DIRECTORY + '/identity-junction-preflight';
  LinkTarget := ExtractFileDir(ExpandFileName(PKCS12_PATH));
  RemoveWindowsJunctionIfPresent(LinkDirectory);
  Result := TryCreateWindowsJunction(LinkDirectory, LinkTarget);
  if not Result then
  begin
    RemoveWindowsJunctionIfPresent(LinkDirectory);
    Exit;
  end;
  if not Windows.RemoveDirectoryW(
     PWideChar(UnicodeString(LinkDirectory))) then
    raise Exception.CreateFmt(
      'Failed to clean up PKCS#12 junction preflight (%d)',
      [Windows.GetLastError]);
end;
{$ENDIF}

{$IFDEF TRANSPORT_SECURITY_OPENSSL}
constructor TBeginAbortWorker.Create(
  const AContext: TTransportSecurityServerContext);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FContext := AContext;
  FErrorMessage := '';
  FOperations := 0;
  FStarted := 0;
  FStopRequested := 0;
end;

procedure TBeginAbortWorker.Execute;
var
  Connection: TTransportSecurityConnection;
begin
  InterlockedExchange(FStarted, 1);
  try
    while InterlockedCompareExchange(FStopRequested, 0, 0) = 0 do
    begin
      FillChar(Connection, SizeOf(Connection), 0);
      try
        BeginTransportSecurityServer(Connection, FContext);
      finally
        AbortTransportSecurityServer(Connection);
      end;
      InterlockedIncrement(FOperations);
    end;
  except
    on E: Exception do
      FErrorMessage := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TBeginAbortWorker.RequestStop;
begin
  InterlockedExchange(FStopRequested, 1);
end;

function TBeginAbortWorker.GetOperations: LongInt;
begin
  Result := InterlockedCompareExchange(FOperations, 0, 0);
end;

function TBeginAbortWorker.WaitForOperations(const AMinimum: LongInt;
  const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while Operations < AMinimum do
  begin
    if GetTickCount64 - StartedAt >= ATimeoutMilliseconds then
      Exit(False);
    Sleep(1);
  end;
  Result := True;
end;

function TBeginAbortWorker.WaitUntilStarted(
  const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while InterlockedCompareExchange(FStarted, 0, 0) = 0 do
  begin
    if GetTickCount64 - StartedAt >= ATimeoutMilliseconds then
      Exit(False);
    Sleep(1);
  end;
  Result := True;
end;
{$ENDIF}

function CaptureFlowContextError(const AHighWatermark, ALowWatermark,
  AOutputCapacity: Integer): string;
var
  Context: TTransportSecurityServerContext;
begin
  Result := '';
  Context := nil;
  try
    try
      Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
        PKCS12_PASSPHRASE, AHighWatermark, ALowWatermark,
        AOutputCapacity);
    except
      on E: ETransportSecurityError do
        Result := E.Message;
    end;
  finally
    CloseTransportSecurityServerContext(Context);
  end;
  if Result = '' then
    raise Exception.Create('Expected TLS flow configuration to fail');
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

{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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

procedure DrainClientCiphertext(var AClient: TRawOpenSSLClient;
  out ABuffer: TBytes);
var
  ExistingLength: Integer;
  Pending: Int64;
  ReadCount: Integer;
begin
  SetLength(ABuffer, 0);
  repeat
    Pending := BIO_ctrl(AClient.WriteBIO, BIO_CTRL_PENDING_COMMAND, 0, nil);
    if Pending <= 0 then
      Exit;
    ExistingLength := Length(ABuffer);
    SetLength(ABuffer, ExistingLength + Integer(Pending));
    ReadCount := RawBIORead(AClient.WriteBIO, @ABuffer[ExistingLength],
      Integer(Pending));
    if ReadCount <= 0 then
      raise Exception.Create('Raw client ciphertext drain failed');
    SetLength(ABuffer, ExistingLength + ReadCount);
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

{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
{ Raw in-memory SChannel client. The Windows server backend is native
  SChannel, so the loopback peer must be native too: the Windows test legs
  have no OpenSSL 3 runtime at all (and win32 has none available anywhere).
  This client owns its own SSPI credential and drives the same buffer
  hand-off the OpenSSL raw client provides on Unix. }
type
  SECURITY_STATUS = LongInt;
  SECURITY_INTEGER = Int64;
  PSecurityInteger = ^SECURITY_INTEGER;

  PSecHandle = ^TSecHandle;
  TSecHandle = record
    Lower: PtrUInt;
    Upper: PtrUInt;
  end;

  PCredHandle = PSecHandle;
  PCtxtHandle = PSecHandle;

  PSecBuffer = ^TSecBuffer;
  TSecBuffer = record
    cbBuffer: LongWord;
    BufferType: LongWord;
    pvBuffer: Pointer;
  end;

  PSecBufferDesc = ^TSecBufferDesc;
  TSecBufferDesc = record
    ulVersion: LongWord;
    cBuffers: LongWord;
    pBuffers: PSecBuffer;
  end;

  TSecPkgContextStreamSizes = record
    cbHeader: LongWord;
    cbTrailer: LongWord;
    cbMaximumMessage: LongWord;
    cBuffers: LongWord;
    cbBlockSize: LongWord;
  end;

  TSchannelCred = record
    dwVersion: LongWord;
    cCreds: LongWord;
    paCred: Pointer;
    hRootStore: Pointer;
    cMappers: LongWord;
    aphMappers: Pointer;
    cSupportedAlgs: LongWord;
    palgSupportedAlgs: Pointer;
    grbitEnabledProtocols: LongWord;
    dwMinimumCipherStrength: LongWord;
    dwMaximumCipherStrength: LongWord;
    dwSessionLifespan: LongWord;
    dwFlags: LongWord;
    dwCredFormat: LongWord;
  end;

  PTlsParameters = ^TTlsParameters;
  TTlsParameters = record
    cAlpnIds: LongWord;
    rgstrAlpnIds: Pointer;
    grbitDisabledProtocols: LongWord;
    cDisabledCrypto: LongWord;
    pDisabledCrypto: Pointer;
    dwFlags: LongWord;
  end;

  TSchCredentials = record
    dwVersion: LongWord;
    dwCredFormat: LongWord;
    cCreds: LongWord;
    paCred: Pointer;
    hRootStore: Pointer;
    cMappers: LongWord;
    aphMappers: Pointer;
    dwSessionLifespan: LongWord;
    dwFlags: LongWord;
    cTlsParameters: LongWord;
    pTlsParameters: PTlsParameters;
  end;

  TRtlOsVersionInfoW = record
    dwOSVersionInfoSize: LongWord;
    dwMajorVersion: LongWord;
    dwMinorVersion: LongWord;
    dwBuildNumber: LongWord;
    dwPlatformId: LongWord;
    szCSDVersion: array[0..127] of WideChar;
  end;

  TRtlOsVersionInfoExW = record
    dwOSVersionInfoSize: LongWord;
    dwMajorVersion: LongWord;
    dwMinorVersion: LongWord;
    dwBuildNumber: LongWord;
    dwPlatformId: LongWord;
    szCSDVersion: array[0..127] of WideChar;
    wServicePackMajor: Word;
    wServicePackMinor: Word;
    wSuiteMask: Word;
    wProductType: Byte;
    wReserved: Byte;
  end;

  TSecPkgContextConnectionInfo = record
    dwProtocol: LongWord;
    aiCipher: LongWord;
    dwCipherStrength: LongWord;
    aiHash: LongWord;
    dwHashStrength: LongWord;
    aiExch: LongWord;
    dwExchStrength: LongWord;
  end;

{$IFDEF CPU64}
  {$IF SizeOf(TSchCredentials) <> 72}
    {$FATAL Test SCH_CREDENTIALS v5 layout mismatch on 64-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TTlsParameters) <> 40}
    {$FATAL Test TLS_PARAMETERS layout mismatch on 64-bit Windows}
  {$ENDIF}
{$ELSE}
  {$IF SizeOf(TSchCredentials) <> 44}
    {$FATAL Test SCH_CREDENTIALS v5 layout mismatch on 32-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TTlsParameters) <> 24}
    {$FATAL Test TLS_PARAMETERS layout mismatch on 32-bit Windows}
  {$ENDIF}
{$ENDIF}
  {$IF SizeOf(TRtlOsVersionInfoW) <> 276}
    {$FATAL Test RTL_OSVERSIONINFOW layout mismatch on Windows}
  {$ENDIF}
  {$IF SizeOf(TRtlOsVersionInfoExW) <> 284}
    {$FATAL Test RTL_OSVERSIONINFOEXW layout mismatch on Windows}
  {$ENDIF}

  PCertContext = ^TCertContext;
  TCertContext = record
    dwCertEncodingType: LongWord;
    pbCertEncoded: PByte;
    cbCertEncoded: LongWord;
    pCertInfo: Pointer;
    hCertStore: Pointer;
  end;

  TSChannelTestClient = record
    Context: TSecHandle;
    Credential: TSecHandle;
    Done: Boolean;
    HasContext: Boolean;
    HasCredential: Boolean;
    Incoming: TBytes;
    Outgoing: TBytes;
    PeerClosed: Boolean;
    Plaintext: TBytes;
    StreamSizes: TSecPkgContextStreamSizes;
  end;

  THandshakeObservations = record
    SawWantRead: Boolean;
    SawWantWrite: Boolean;
  end;

const
  SECBUFFER_VERSION = 0;
  SECBUFFER_EMPTY = 0;
  SECBUFFER_DATA = 1;
  SECBUFFER_TOKEN = 2;
  SECBUFFER_EXTRA = 5;
  SECBUFFER_STREAM_TRAILER = 6;
  SECBUFFER_STREAM_HEADER = 7;
  SECBUFFER_ATTRMASK = $F0000000;
  SECPKG_ATTR_STREAM_SIZES = 4;
  SECPKG_ATTR_CONNECTION_INFO = $5A;
  SECPKG_ATTR_REMOTE_CERT_CONTEXT = $53;
  CERT_NAME_SIMPLE_DISPLAY_TYPE = 4;
  SECPKG_CRED_OUTBOUND = 2;
  SEC_E_OK = SECURITY_STATUS($00000000);
  SEC_I_CONTINUE_NEEDED = SECURITY_STATUS($00090312);
  SEC_I_CONTEXT_EXPIRED = SECURITY_STATUS($00090317);
  SEC_I_RENEGOTIATE = SECURITY_STATUS($00090321);
  SEC_E_INCOMPLETE_MESSAGE = SECURITY_STATUS($80090318);
  ISC_REQ_REPLAY_DETECT = $00000004;
  ISC_REQ_SEQUENCE_DETECT = $00000008;
  ISC_REQ_CONFIDENTIALITY = $00000010;
  ISC_REQ_ALLOCATE_MEMORY = $00000100;
  ISC_REQ_EXTENDED_ERROR = $00004000;
  ISC_REQ_STREAM = $00008000;
  ISC_REQ_MANUAL_CRED_VALIDATION = $00080000;
  SCHANNEL_CRED_VERSION = 4;
  SCH_CREDENTIALS_VERSION = 5;
  SCHANNEL_SHUTDOWN = 1;
  SCH_CRED_MANUAL_CRED_VALIDATION = $00000008;
  SCH_CRED_NO_DEFAULT_CREDS = $00000010;
  SCH_USE_STRONG_CRYPTO = $00400000;
  SP_PROT_TLS1_2_CLIENT = $00000800;
  SP_PROT_TLS1_3_CLIENT = $00002000;
  SP_PROT_SSL2_CLIENT = $00000008;
  SP_PROT_SSL3_CLIENT = $00000020;
  SP_PROT_TLS1_0_CLIENT = $00000080;
  SP_PROT_TLS1_1_CLIENT = $00000200;
  SECURITY_NATIVE_DREP = $00000010;
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';
  SCHANNEL_TARGET_NAME = 'localhost';
  WINDOWS_10_1809_BUILD = 17763;
  WINDOWS_SERVER_2022_BUILD = 20348;
  WINDOWS_11_BUILD = 22000;
  VER_NT_WORKSTATION = 1;

function AcquireCredentialsHandleW(APrincipal: PWideChar;
  APackage: PWideChar; ACredentialUse: LongWord; ALogonId: Pointer;
  AAuthData: Pointer; AGetKeyFn: Pointer; AGetKeyArgument: Pointer;
  ACredential: PCredHandle;
  AExpiry: PSecurityInteger): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'AcquireCredentialsHandleW';
function InitializeSecurityContextW(ACredential: PCredHandle;
  AContext: PCtxtHandle; ATargetName: PWideChar;
  AContextRequirements: LongWord; AReserved: LongWord;
  ATargetDataRepresentation: LongWord; AInput: PSecBufferDesc;
  AReservedTwo: LongWord; ANewContext: PCtxtHandle; AOutput: PSecBufferDesc;
  AContextAttributes: PLongWord;
  AExpiry: PSecurityInteger): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'InitializeSecurityContextW';
function QueryContextAttributesW(AContext: PCtxtHandle; AAttribute: LongWord;
  ABuffer: Pointer): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'QueryContextAttributesW';
function EncryptMessage(AContext: PCtxtHandle;
  AQualityOfProtection: LongWord; AMessage: PSecBufferDesc;
  AMessageSequenceNumber: LongWord): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'EncryptMessage';
function DecryptMessage(AContext: PCtxtHandle; AMessage: PSecBufferDesc;
  AMessageSequenceNumber: LongWord;
  AQualityOfProtection: PLongWord): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'DecryptMessage';
function ApplyControlToken(AContext: PCtxtHandle;
  AInput: PSecBufferDesc): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'ApplyControlToken';
function FreeContextBuffer(ABuffer: Pointer): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'FreeContextBuffer';
function DeleteSecurityContext(AContext: PCtxtHandle): SECURITY_STATUS;
  stdcall; external 'secur32.dll' name 'DeleteSecurityContext';
function FreeCredentialsHandle(ACredential: PCredHandle): SECURITY_STATUS;
  stdcall; external 'secur32.dll' name 'FreeCredentialsHandle';
function CertEnumCertificatesInStore(AStore: Pointer;
  APreviousContext: PCertContext): PCertContext; stdcall;
  external 'crypt32.dll' name 'CertEnumCertificatesInStore';
function CertFreeCertificateContext(ACertificate: PCertContext): LongBool;
  stdcall; external 'crypt32.dll' name 'CertFreeCertificateContext';
function CertGetNameStringA(ACertificate: PCertContext; AType: LongWord;
  AFlags: LongWord; ATypeParameter: Pointer; AName: PAnsiChar;
  ANameLength: LongWord): LongWord; stdcall;
  external 'crypt32.dll' name 'CertGetNameStringA';
function RtlGetVersion(AVersion: Pointer): LongInt; stdcall;
  external 'ntdll.dll' name 'RtlGetVersion';

function TestSChannelSupportsTlsParameters: Boolean;
var
  Version: TRtlOsVersionInfoW;
begin
  FillChar(Version, SizeOf(Version), 0);
  Version.dwOSVersionInfoSize := SizeOf(Version);
  Result := (RtlGetVersion(@Version) = 0) and
    ((Version.dwMajorVersion > 10) or
     ((Version.dwMajorVersion = 10) and
      (Version.dwBuildNumber >= WINDOWS_10_1809_BUILD)));
end;

function TestSChannelSupportsTls13: Boolean;
var
  Version: TRtlOsVersionInfoExW;
begin
  FillChar(Version, SizeOf(Version), 0);
  Version.dwOSVersionInfoSize := SizeOf(Version);
  Result := (RtlGetVersion(@Version) = 0) and
    ((Version.dwMajorVersion > 10) or
     ((Version.dwMajorVersion = 10) and
      (((Version.wProductType = VER_NT_WORKSTATION) and
        (Version.dwBuildNumber >= WINDOWS_11_BUILD)) or
       ((Version.wProductType <> VER_NT_WORKSTATION) and
        (Version.dwBuildNumber >= WINDOWS_SERVER_2022_BUILD)))));
end;

function TestSecBufferKind(const ABufferType: LongWord): LongWord;
begin
  Result := ABufferType and not SECBUFFER_ATTRMASK;
end;

procedure AppendTestBytes(var ATarget: TBytes; const ASource: Pointer;
  const ALength: Integer);
var
  PreviousLength: Integer;
begin
  if ALength <= 0 then
    Exit;
  if not Assigned(ASource) then
    raise Exception.Create('SChannel returned a buffer without a pointer');
  PreviousLength := Length(ATarget);
  SetLength(ATarget, PreviousLength + ALength);
  Move(ASource^, ATarget[PreviousLength], ALength);
end;

procedure PreserveTestExtraBytes(var ATarget: TBytes; const ASource: Pointer;
  const ALength: Integer);
var
  Temporary: TBytes;
begin
  if ALength <= 0 then
  begin
    SetLength(ATarget, 0);
    Exit;
  end;
  SetLength(Temporary, ALength);
  if Assigned(ASource) then
    Move(ASource^, Temporary[0], ALength)
  else
  begin
    if ALength > Length(ATarget) then
      raise Exception.Create('SChannel reported extra bytes outside the input');
    Move(ATarget[Length(ATarget) - ALength], Temporary[0], ALength);
  end;
  ATarget := Temporary;
end;

procedure CreateSChannelClient(out AClient: TSChannelTestClient);
var
  AuthenticationData: Pointer;
  Expiry: SECURITY_INTEGER;
  LegacyCredentials: TSchannelCred;
  ModernCredentials: TSchCredentials;
  Status: SECURITY_STATUS;
  TlsParameters: TTlsParameters;
begin
  FillChar(AClient, SizeOf(AClient), 0);
  FillChar(LegacyCredentials, SizeOf(LegacyCredentials), 0);
  FillChar(ModernCredentials, SizeOf(ModernCredentials), 0);
  FillChar(TlsParameters, SizeOf(TlsParameters), 0);
  if TestSChannelSupportsTlsParameters then
  begin
    TlsParameters.grbitDisabledProtocols := SP_PROT_SSL2_CLIENT or
      SP_PROT_SSL3_CLIENT or SP_PROT_TLS1_0_CLIENT or
      SP_PROT_TLS1_1_CLIENT;
    ModernCredentials.dwVersion := SCH_CREDENTIALS_VERSION;
    ModernCredentials.dwFlags := SCH_CRED_MANUAL_CRED_VALIDATION or
      SCH_CRED_NO_DEFAULT_CREDS or SCH_USE_STRONG_CRYPTO;
    ModernCredentials.cTlsParameters := 1;
    ModernCredentials.pTlsParameters := @TlsParameters;
    AuthenticationData := @ModernCredentials;
  end
  else
  begin
    LegacyCredentials.dwVersion := SCHANNEL_CRED_VERSION;
    LegacyCredentials.grbitEnabledProtocols := SP_PROT_TLS1_2_CLIENT;
    LegacyCredentials.dwFlags := SCH_CRED_MANUAL_CRED_VALIDATION or
      SCH_CRED_NO_DEFAULT_CREDS or SCH_USE_STRONG_CRYPTO;
    AuthenticationData := @LegacyCredentials;
  end;
  Status := AcquireCredentialsHandleW(nil, PWideChar(WideString(UNISP_NAME)),
    SECPKG_CRED_OUTBOUND, nil, AuthenticationData, nil, nil,
    @AClient.Credential,
    @Expiry);
  if Status <> SEC_E_OK then
    raise Exception.CreateFmt(
      'Raw SChannel client credential acquisition failed: 0x%x',
      [LongWord(Status)]);
  AClient.HasCredential := True;
end;

function SChannelClientProtocol(
  const AClient: TSChannelTestClient): LongWord;
var
  ConnectionInfo: TSecPkgContextConnectionInfo;
begin
  FillChar(ConnectionInfo, SizeOf(ConnectionInfo), 0);
  if QueryContextAttributesW(@AClient.Context, SECPKG_ATTR_CONNECTION_INFO,
    @ConnectionInfo) <> SEC_E_OK then
    raise Exception.Create('Raw SChannel client protocol is unavailable');
  Result := ConnectionInfo.dwProtocol;
end;

procedure FreeSChannelClient(var AClient: TSChannelTestClient);
begin
  if AClient.HasContext then
    DeleteSecurityContext(@AClient.Context);
  if AClient.HasCredential then
    FreeCredentialsHandle(@AClient.Credential);
  { Release the managed fields before blanking the record: FillChar over a
    dynamic array drops the reference without decrementing it. }
  SetLength(AClient.Incoming, 0);
  SetLength(AClient.Outgoing, 0);
  SetLength(AClient.Plaintext, 0);
  FillChar(AClient, SizeOf(AClient), 0);
end;

function StepSChannelClientHandshake(
  var AClient: TSChannelTestClient): TTransportSecurityState;
var
  ContextAttributes: LongWord;
  ExistingContext: PCtxtHandle;
  Expiry: SECURITY_INTEGER;
  InputBuffers: array[0..1] of TSecBuffer;
  InputDescriptor: TSecBufferDesc;
  InputPointer: PSecBufferDesc;
  OutputBuffer: TSecBuffer;
  OutputDescriptor: TSecBufferDesc;
  Status: SECURITY_STATUS;
  TargetName: WideString;
begin
  if AClient.Done then
  begin
    Result := tssDone;
    Exit;
  end;
  if AClient.HasContext and (Length(AClient.Incoming) = 0) then
  begin
    Result := tssWantRead;
    Exit;
  end;

  FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
  OutputBuffer.BufferType := SECBUFFER_TOKEN;
  FillChar(OutputDescriptor, SizeOf(OutputDescriptor), 0);
  OutputDescriptor.ulVersion := SECBUFFER_VERSION;
  OutputDescriptor.cBuffers := 1;
  OutputDescriptor.pBuffers := @OutputBuffer;

  InputPointer := nil;
  FillChar(InputBuffers, SizeOf(InputBuffers), 0);
  FillChar(InputDescriptor, SizeOf(InputDescriptor), 0);
  if Length(AClient.Incoming) > 0 then
  begin
    InputBuffers[0].BufferType := SECBUFFER_TOKEN;
    InputBuffers[0].cbBuffer := Length(AClient.Incoming);
    InputBuffers[0].pvBuffer := @AClient.Incoming[0];
    InputBuffers[1].BufferType := SECBUFFER_EMPTY;
    InputDescriptor.ulVersion := SECBUFFER_VERSION;
    InputDescriptor.cBuffers := 2;
    InputDescriptor.pBuffers := @InputBuffers[0];
    InputPointer := @InputDescriptor;
  end;

  if AClient.HasContext then
    ExistingContext := @AClient.Context
  else
    ExistingContext := nil;

  TargetName := WideString(SCHANNEL_TARGET_NAME);
  Status := InitializeSecurityContextW(@AClient.Credential, ExistingContext,
    PWideChar(TargetName), ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or
    ISC_REQ_CONFIDENTIALITY or ISC_REQ_EXTENDED_ERROR or
    ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_STREAM or
    ISC_REQ_MANUAL_CRED_VALIDATION, 0, SECURITY_NATIVE_DREP, InputPointer, 0,
    @AClient.Context, @OutputDescriptor, @ContextAttributes, @Expiry);
  if Status >= 0 then
    AClient.HasContext := True;

  if Status = SEC_E_INCOMPLETE_MESSAGE then
  begin
    if Assigned(OutputBuffer.pvBuffer) then
      FreeContextBuffer(OutputBuffer.pvBuffer);
    Result := tssWantRead;
    Exit;
  end;

  if Assigned(InputPointer) and
     (TestSecBufferKind(InputBuffers[1].BufferType) = SECBUFFER_EXTRA) then
    PreserveTestExtraBytes(AClient.Incoming, InputBuffers[1].pvBuffer,
      InputBuffers[1].cbBuffer)
  else
    SetLength(AClient.Incoming, 0);

  try
    if (Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) then
      AppendTestBytes(AClient.Outgoing, OutputBuffer.pvBuffer,
        OutputBuffer.cbBuffer);
  finally
    if Assigned(OutputBuffer.pvBuffer) then
      FreeContextBuffer(OutputBuffer.pvBuffer);
  end;

  if Status = SEC_E_OK then
  begin
    if QueryContextAttributesW(@AClient.Context, SECPKG_ATTR_STREAM_SIZES,
      @AClient.StreamSizes) <> SEC_E_OK then
      raise Exception.Create('Raw SChannel client stream sizes unavailable');
    AClient.Done := True;
    Result := tssDone;
    Exit;
  end;
  if Status = SEC_I_CONTINUE_NEEDED then
  begin
    Result := tssWantRead;
    Exit;
  end;
  Result := tssError;
end;

procedure ConsumeSChannelClientOutgoing(var AClient: TSChannelTestClient;
  const ALength: Integer);
begin
  if ALength <= 0 then
    Exit;
  if ALength >= Length(AClient.Outgoing) then
  begin
    SetLength(AClient.Outgoing, 0);
    Exit;
  end;
  AClient.Outgoing := Copy(AClient.Outgoing, ALength,
    Length(AClient.Outgoing) - ALength);
end;

procedure PumpSChannelClientCiphertext(var AClient: TSChannelTestClient;
  var AServer: TTransportSecurityConnection);
var
  Fed: Integer;
  Offset: Integer;
begin
  Offset := 0;
  while Offset < Length(AClient.Outgoing) do
  begin
    Fed := TransportSecurityFeedCiphertext(AServer, @AClient.Outgoing[Offset],
      Length(AClient.Outgoing) - Offset);
    if Fed < 0 then
      raise Exception.Create('Server ciphertext feed failed');
    if Fed = 0 then
      Break;
    Inc(Offset, Fed);
  end;
  ConsumeSChannelClientOutgoing(AClient, Offset);
end;

procedure DrainSChannelClientCiphertext(var AClient: TSChannelTestClient;
  out ABuffer: TBytes);
begin
  ABuffer := AClient.Outgoing;
  AClient.Outgoing := nil;
end;

procedure PumpSChannelServerCiphertext(
  var AServer: TTransportSecurityConnection;
  var AClient: TSChannelTestClient);
var
  Buffer: Pointer;
  Pending: Integer;
begin
  repeat
    Pending := TransportSecurityGetCiphertext(AServer, Buffer);
    if Pending <= 0 then
      Exit;
    AppendTestBytes(AClient.Incoming, Buffer, Pending);
    TransportSecurityConsumeCiphertext(AServer, Pending);
  until False;
end;

procedure DriveSChannelHandshake(var AServer: TTransportSecurityConnection;
  var AClient: TSChannelTestClient; out AObserved: THandshakeObservations);
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
    ClientState := StepSChannelClientHandshake(AClient);
    if ClientState = tssError then
      raise Exception.Create('Raw SChannel client handshake failed');
    PumpSChannelClientCiphertext(AClient, AServer);

    ServerState := TransportSecurityServerHandshake(AServer);
    AObserved.SawWantRead := AObserved.SawWantRead or
      (ServerState = tssWantRead);
    AObserved.SawWantWrite := AObserved.SawWantWrite or
      (ServerState = tssWantWrite);
    if ServerState = tssError then
      raise Exception.Create('TransportSecurity server handshake failed');
    PumpSChannelServerCiphertext(AServer, AClient);

    if AClient.Done and (ServerState = tssDone) and
       (TransportSecurityPendingCiphertext(AServer) = 0) then
      Exit;
  end;
  raise Exception.Create('In-memory SChannel handshake exceeded 128 steps');
end;

procedure CreateSChannelHandshakenPair(
  const AContext: TTransportSecurityServerContext;
  out AServer: TTransportSecurityConnection;
  out AClient: TSChannelTestClient; out AObserved: THandshakeObservations);
begin
  FillChar(AServer, SizeOf(AServer), 0);
  FillChar(AClient, SizeOf(AClient), 0);
  BeginTransportSecurityServer(AServer, AContext);
  try
    CreateSChannelClient(AClient);
    DriveSChannelHandshake(AServer, AClient, AObserved);
  except
    AbortTransportSecurityServer(AServer);
    FreeSChannelClient(AClient);
    raise;
  end;
end;

procedure WriteSChannelClientPlaintext(var AClient: TSChannelTestClient;
  const ABuffer: Pointer; const ALength: Integer);
var
  BufferDescriptor: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  ChunkLength: Integer;
  MessageBytes: TBytes;
  Offset: Integer;
  Status: SECURITY_STATUS;
  TotalLength: Integer;
begin
  Offset := 0;
  while Offset < ALength do
  begin
    ChunkLength := ALength - Offset;
    if ChunkLength > Integer(AClient.StreamSizes.cbMaximumMessage) then
      ChunkLength := Integer(AClient.StreamSizes.cbMaximumMessage);
    TotalLength := Integer(AClient.StreamSizes.cbHeader) + ChunkLength +
      Integer(AClient.StreamSizes.cbTrailer);
    SetLength(MessageBytes, TotalLength);
    Move(Pointer(PtrUInt(ABuffer) + PtrUInt(Offset))^,
      MessageBytes[AClient.StreamSizes.cbHeader], ChunkLength);

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_STREAM_HEADER;
    Buffers[0].cbBuffer := AClient.StreamSizes.cbHeader;
    Buffers[0].pvBuffer := @MessageBytes[0];
    Buffers[1].BufferType := SECBUFFER_DATA;
    Buffers[1].cbBuffer := ChunkLength;
    Buffers[1].pvBuffer := @MessageBytes[AClient.StreamSizes.cbHeader];
    Buffers[2].BufferType := SECBUFFER_STREAM_TRAILER;
    Buffers[2].cbBuffer := AClient.StreamSizes.cbTrailer;
    Buffers[2].pvBuffer :=
      @MessageBytes[Integer(AClient.StreamSizes.cbHeader) + ChunkLength];
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    FillChar(BufferDescriptor, SizeOf(BufferDescriptor), 0);
    BufferDescriptor.ulVersion := SECBUFFER_VERSION;
    BufferDescriptor.cBuffers := 4;
    BufferDescriptor.pBuffers := @Buffers[0];

    Status := EncryptMessage(@AClient.Context, 0, @BufferDescriptor, 0);
    if Status <> SEC_E_OK then
      raise Exception.CreateFmt('Raw SChannel client encrypt failed: 0x%x',
        [LongWord(Status)]);
    TotalLength := Integer(Buffers[0].cbBuffer) +
      Integer(Buffers[1].cbBuffer) + Integer(Buffers[2].cbBuffer);
    AppendTestBytes(AClient.Outgoing, @MessageBytes[0], TotalLength);
    Inc(Offset, ChunkLength);
  end;
end;

procedure WriteSChannelClientText(var AClient: TSChannelTestClient;
  const AText: AnsiString);
begin
  WriteSChannelClientPlaintext(AClient, @AText[1], Length(AText));
end;

function ReadSChannelClientPlaintext(var AClient: TSChannelTestClient;
  var ABuffer: TBytes): TTransportSecurityState;
var
  BufferDescriptor: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  ExtraInput: TBytes;
  I: Integer;
  QualityOfProtection: LongWord;
  Status: SECURITY_STATUS;
begin
  SetLength(ABuffer, 0);
  repeat
    if Length(AClient.Plaintext) > 0 then
    begin
      ABuffer := AClient.Plaintext;
      AClient.Plaintext := nil;
      Result := tssDone;
      Exit;
    end;
    if AClient.PeerClosed then
    begin
      Result := tssPeerClosed;
      Exit;
    end;
    if Length(AClient.Incoming) = 0 then
    begin
      Result := tssWantRead;
      Exit;
    end;

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_DATA;
    Buffers[0].cbBuffer := Length(AClient.Incoming);
    Buffers[0].pvBuffer := @AClient.Incoming[0];
    Buffers[1].BufferType := SECBUFFER_EMPTY;
    Buffers[2].BufferType := SECBUFFER_EMPTY;
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    FillChar(BufferDescriptor, SizeOf(BufferDescriptor), 0);
    BufferDescriptor.ulVersion := SECBUFFER_VERSION;
    BufferDescriptor.cBuffers := 4;
    BufferDescriptor.pBuffers := @Buffers[0];
    QualityOfProtection := 0;

    Status := DecryptMessage(@AClient.Context, @BufferDescriptor, 0,
      @QualityOfProtection);
    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      Result := tssWantRead;
      Exit;
    end;
    if Status = SEC_I_RENEGOTIATE then
    begin
      { SChannel ordinarily returns the complete post-handshake token and
        following ciphertext as SECBUFFER_EXTRA. Microsoft documents that
        EXTRA is not guaranteed, in which case the same modified input buffer
        must be relabelled as the token. Copy before the handshake mutates the
        descriptor again. }
      SetLength(ExtraInput, 0);
      for I := 0 to High(Buffers) do
        if TestSecBufferKind(Buffers[I].BufferType) = SECBUFFER_EXTRA then
          AppendTestBytes(ExtraInput, Buffers[I].pvBuffer,
            Buffers[I].cbBuffer);
      if Length(ExtraInput) = 0 then
        ExtraInput := Copy(AClient.Incoming, 0, Length(AClient.Incoming));
      AClient.Incoming := ExtraInput;
      AClient.Done := False;
      Result := StepSChannelClientHandshake(AClient);
      if Result <> tssDone then
        Exit;
      Continue;
    end;
    if (Status <> SEC_E_OK) and (Status <> SEC_I_CONTEXT_EXPIRED) then
    begin
      Result := tssError;
      Exit;
    end;

    { Copy plaintext while Incoming still owns the in-place DecryptMessage
      spans. Replacing Incoming with the preserved tail first would leave the
      returned DATA pointer dangling. From index 1: on
      SEC_I_CONTEXT_EXPIRED buffer 0 still carries the caller's label. }
    if Status = SEC_E_OK then
      for I := 1 to High(Buffers) do
        if TestSecBufferKind(Buffers[I].BufferType) = SECBUFFER_DATA then
          AppendTestBytes(AClient.Plaintext, Buffers[I].pvBuffer,
            Buffers[I].cbBuffer);

    SetLength(ExtraInput, 0);
    for I := 1 to High(Buffers) do
      if TestSecBufferKind(Buffers[I].BufferType) = SECBUFFER_EXTRA then
        AppendTestBytes(ExtraInput, Buffers[I].pvBuffer, Buffers[I].cbBuffer);
    AClient.Incoming := ExtraInput;
    if Status = SEC_I_CONTEXT_EXPIRED then
      AClient.PeerClosed := True;
  until False;
end;

function ReadSChannelClientText(var AClient: TSChannelTestClient): string;
var
  Buffer: TBytes;
begin
  if ReadSChannelClientPlaintext(AClient, Buffer) <> tssDone then
    raise Exception.Create('Raw SChannel client plaintext read failed');
  SetLength(Result, Length(Buffer));
  if Length(Buffer) > 0 then
    Move(Buffer[0], Result[1], Length(Buffer));
end;

{ What the peer actually put on the wire: the subject names and how many
  certificates there were, both from one walk of the store SChannel attaches
  to SECPKG_ATTR_REMOTE_CERT_CONTEXT. That store is documented to hold the
  certificates the peer supplied, and taking both numbers from the same
  enumeration means the two can never disagree.

  It is also the measurement that cannot be contaminated by the issuer this
  process publishes into the user's CA store. Round 3 of the Windows CI proved
  that empirically: before publication existed the same walk returned exactly
  "localhost", where a walk that consulted local stores would have listed the
  runner's whole CA store. }
procedure SChannelClientDeliveredChain(var AClient: TSChannelTestClient;
  out ANames: string; out ACount: Integer);
var
  Certificate: PCertContext;
  Enumerated: PCertContext;
  Name: array[0..255] of AnsiChar;
begin
  ANames := '';
  ACount := 0;
  Certificate := nil;
  if QueryContextAttributesW(@AClient.Context,
    SECPKG_ATTR_REMOTE_CERT_CONTEXT, @Certificate) <> SEC_E_OK then
    raise Exception.Create('Raw SChannel client has no remote certificate');
  try
    if not Assigned(Certificate) or not Assigned(Certificate^.hCertStore) then
      Exit;
    Enumerated := CertEnumCertificatesInStore(Certificate^.hCertStore, nil);
    while Assigned(Enumerated) do
    begin
      FillChar(Name, SizeOf(Name), 0);
      CertGetNameStringA(Enumerated, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil,
        @Name[0], Length(Name));
      if ANames <> '' then
        ANames := ANames + ', ';
      ANames := ANames + StrPas(@Name[0]);
      Inc(ACount);
      Enumerated := CertEnumCertificatesInStore(Certificate^.hCertStore,
        Enumerated);
    end;
  finally
    if Assigned(Certificate) then
      CertFreeCertificateContext(Certificate);
  end;
end;

procedure ShutdownSChannelClient(var AClient: TSChannelTestClient);
var
  ContextAttributes: LongWord;
  Expiry: SECURITY_INTEGER;
  OutputBuffer: TSecBuffer;
  OutputDescriptor: TSecBufferDesc;
  ShutdownBuffer: TSecBuffer;
  ShutdownDescriptor: TSecBufferDesc;
  ShutdownToken: LongWord;
  Status: SECURITY_STATUS;
  TargetName: WideString;
begin
  ShutdownToken := SCHANNEL_SHUTDOWN;
  FillChar(ShutdownBuffer, SizeOf(ShutdownBuffer), 0);
  ShutdownBuffer.cbBuffer := SizeOf(ShutdownToken);
  ShutdownBuffer.BufferType := SECBUFFER_TOKEN;
  ShutdownBuffer.pvBuffer := @ShutdownToken;
  FillChar(ShutdownDescriptor, SizeOf(ShutdownDescriptor), 0);
  ShutdownDescriptor.ulVersion := SECBUFFER_VERSION;
  ShutdownDescriptor.cBuffers := 1;
  ShutdownDescriptor.pBuffers := @ShutdownBuffer;
  if ApplyControlToken(@AClient.Context, @ShutdownDescriptor) <> SEC_E_OK then
    raise Exception.Create('Raw SChannel client shutdown token failed');

  FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
  OutputBuffer.BufferType := SECBUFFER_TOKEN;
  FillChar(OutputDescriptor, SizeOf(OutputDescriptor), 0);
  OutputDescriptor.ulVersion := SECBUFFER_VERSION;
  OutputDescriptor.cBuffers := 1;
  OutputDescriptor.pBuffers := @OutputBuffer;
  TargetName := WideString(SCHANNEL_TARGET_NAME);
  Status := InitializeSecurityContextW(@AClient.Credential, @AClient.Context,
    PWideChar(TargetName), ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or
    ISC_REQ_CONFIDENTIALITY or ISC_REQ_EXTENDED_ERROR or
    ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_STREAM or
    ISC_REQ_MANUAL_CRED_VALIDATION, 0, SECURITY_NATIVE_DREP, nil, 0,
    @AClient.Context, @OutputDescriptor, @ContextAttributes, @Expiry);
  try
    if (Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) or
       (Status = SEC_I_CONTEXT_EXPIRED) then
      AppendTestBytes(AClient.Outgoing, OutputBuffer.pvBuffer,
        OutputBuffer.cbBuffer)
    else
      raise Exception.CreateFmt('Raw SChannel client shutdown failed: 0x%x',
        [LongWord(Status)]);
  finally
    if Assigned(OutputBuffer.pvBuffer) then
      FreeContextBuffer(OutputBuffer.pvBuffer);
  end;
end;
{$ENDIF}

procedure TTransportSecurityServerTests.TestActiveOnlyAfterHandshake;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  State: TTransportSecurityState;
{$ENDIF}
{$IFDEF DARWIN}
var
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF DARWIN}
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
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    Expect<Boolean>(Connection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestBoundsClamp;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Buffer: array[0..0] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
{$ENDIF}
{$IFDEF DARWIN}
var
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF DARWIN}
  FillChar(Client, SizeOf(Client), 0);
  FillChar(Connection, SizeOf(Connection), 0);
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    Expect<Boolean>(RawSecureTransportPeerCertificateCount(Client) >= 2)
      .ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestDarwinConcurrentSecureTransportFirstUse;
{$IFDEF DARWIN}
const
  WORKER_COUNT = 8;
var
  Index: Integer;
  Workers: array[0..WORKER_COUNT - 1] of TSecureTransportContextWorker;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  for Index := Low(Workers) to High(Workers) do
    Workers[Index] := TSecureTransportContextWorker.Create;
  try
    for Index := Low(Workers) to High(Workers) do Workers[Index].Start;
    for Index := Low(Workers) to High(Workers) do Workers[Index].WaitFor;
    for Index := Low(Workers) to High(Workers) do
      Expect<string>(Workers[Index].ErrorMessage).ToBe('');
  finally
    for Index := Low(Workers) to High(Workers) do Workers[Index].Free;
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestDarwinSecureTransportCleanupFailures;
{$IFDEF DARWIN}
const
  TEST_CLEANUP_STATUS = -50;
var
  CleanupOnlyRaised, PrimaryPreserved: Boolean;
  Context: TTransportSecurityServerContext;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  CleanupOnlyRaised := False;
  TransportSecurityTestForceSecureTransportCleanupFailures(
    TEST_CLEANUP_STATUS, True);
  try
    try
      CloseTransportSecurityServerContext(Context);
    except
      on E: ETransportSecurityError do
      begin
        Context := nil;
        CleanupOnlyRaised := Pos('temporary TLS keychain storage',
          E.Message) > 0;
      end;
    end;
  finally
    Context := nil;
    TransportSecurityTestForceSecureTransportCleanupFailures(0, False);
  end;
  Expect<Boolean>(CleanupOnlyRaised).ToBe(True);

  PrimaryPreserved := False;
  TransportSecurityTestForceSecureTransportCleanupFailures(
    TEST_CLEANUP_STATUS, True);
  try
    try
      Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
        'wrong-passphrase');
    except
      on E: ETransportSecurityError do
        PrimaryPreserved := Pos('Failed to parse configured TLS PKCS#12',
          E.Message) = 1;
    end;
  finally
    Context := nil;
    TransportSecurityTestForceSecureTransportCleanupFailures(0, False);
  end;
  Expect<Boolean>(PrimaryPreserved).ToBe(True);
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestDarwinSecureTransportNetworkFetchDisabled;
{$IFDEF DARWIN}
const
  TEST_FETCH_POLICY_STATUS = -50;
var
  Context: TTransportSecurityServerContext;
  FailedClosed: Boolean;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  Context := nil;
  FailedClosed := False;
  TransportSecurityTestForceSecureTransportNetworkFetchStatus(
    TEST_FETCH_POLICY_STATUS);
  try
    try
      Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
        PKCS12_PASSPHRASE);
    except
      on E: ETransportSecurityError do
        FailedClosed := E.Message =
          'Configured TLS identity does not form a valid bundled server chain';
    end;
    Expect<Boolean>(
      TransportSecurityTestSecureTransportNetworkFetchWasDisabled).ToBe(True);
    Expect<Boolean>(FailedClosed).ToBe(True);
  finally
    TransportSecurityTestForceSecureTransportNetworkFetchStatus(0);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestDarwinSecureTransportServerLifecycle;
{$IFDEF DARWIN}
var
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  KeychainsBefore: Integer;
  StaleKeychain: TFileStream;
  StaleKeychainPath: string;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  KeychainsBefore := DarwinTemporaryServerKeychainCount;
  Context := nil;
  FillChar(Connection, SizeOf(Connection), 0);
  StaleKeychainPath := IncludeTrailingPathDelimiter(GetTempDir)
    + 'secure-transport-server-' + IntToStr(DarwinDeadProcessID)
    + '-00000000000000000000000000000000.keychain';
  SysUtils.DeleteFile(StaleKeychainPath);
  try
    StaleKeychain := TFileStream.Create(StaleKeychainPath, fmCreate);
    StaleKeychain.Free;
    Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
      PKCS12_PASSPHRASE);
    Expect<Boolean>(FileExists(StaleKeychainPath)).ToBe(False);
    StaleKeychain := TFileStream.Create(StaleKeychainPath, fmCreate);
    StaleKeychain.Free;
    TransportSecurityTestForceSecureTransportRecoveryUnlinkRace(True);
    Context.Reload(PKCS12_PATH, PKCS12_PASSPHRASE);
    Expect<Boolean>(FileExists(StaleKeychainPath)).ToBe(False);
    Expect<Boolean>(TransportSecurityServerBackendAvailable).ToBe(True);
    BeginTransportSecurityServer(Connection, Context);
    Expect<Boolean>(Connection.Active).ToBe(False);
    State := TransportSecurityServerHandshake(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantRead));
    Expect<Boolean>(Connection.Active).ToBe(False);
  finally
    TransportSecurityTestForceSecureTransportRecoveryUnlinkRace(False);
    AbortTransportSecurityServer(Connection);
    CloseTransportSecurityServerContext(Context);
    SysUtils.DeleteFile(StaleKeychainPath);
  end;
  Expect<Integer>(DarwinTemporaryServerKeychainCount).ToBe(KeychainsBefore);
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestDarwinSecureTransportRoundTrip;
{$IFDEF DARWIN}
const
  REQUEST = 'secure transport request';
  RESPONSE = 'secure transport response';
var
  Buffer: array[0..255] of Byte;
  Client: TRawSecureTransportClient;
  ClientProcessed: PtrUInt;
  ClientStatus: LongInt;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  IOResult: TTransportSecurityIOResult;
  Received: string;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  FillChar(Client, SizeOf(Client), 0);
  FillChar(Connection, SizeOf(Connection), 0);
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    Expect<Boolean>(Connection.Active).ToBe(True);

    ClientProcessed := 0;
    ClientStatus := TestSSLWrite(Client.Context, @REQUEST[1],
      Length(REQUEST), ClientProcessed);
    Expect<Boolean>((ClientStatus = TEST_ERR_SEC_SUCCESS)
      or (ClientStatus = TEST_ERR_SSL_WOULD_BLOCK)).ToBe(True);
    Expect<Integer>(Integer(ClientProcessed)).ToBe(Length(REQUEST));
    PumpRawSecureTransportClient(Client, Connection);
    IOResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(IOResult.BytesProcessed).ToBe(Length(REQUEST));
    SetString(Received, PAnsiChar(@Buffer[0]), IOResult.BytesProcessed);
    Expect<string>(Received).ToBe(REQUEST);

    IOResult := TransportSecurityServerWrite(Connection, @RESPONSE[1],
      Length(RESPONSE));
    Expect<Integer>(IOResult.BytesProcessed).ToBe(Length(RESPONSE));
    PumpRawSecureTransportServer(Connection, Client);
    ClientProcessed := 0;
    ClientStatus := TestSSLRead(Client.Context, @Buffer[0], Length(Buffer),
      ClientProcessed);
    Expect<Boolean>((ClientStatus = TEST_ERR_SEC_SUCCESS)
      or (ClientStatus = TEST_ERR_SSL_WOULD_BLOCK)).ToBe(True);
    SetString(Received, PAnsiChar(@Buffer[0]), ClientProcessed);
    Expect<string>(Received).ToBe(RESPONSE);

    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Boolean>(TransportSecurityPendingCiphertext(Connection) > 0).ToBe(
      True);
    PumpRawSecureTransportServer(Connection, Client);
    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Boolean>(State in [tssDone, tssPeerClosed]).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestEmptyAndUTF8Passphrases;
{$IFDEF TRANSPORT_SECURITY_SERVER}
var
  EmptyContext: TTransportSecurityServerContext;
  UTF8Context: TTransportSecurityServerContext;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
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
{$IFDEF TRANSPORT_SECURITY_SERVER}
var
  EmbeddedNULPassphrase: UnicodeString;
  ErrorMessage: string;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
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

procedure TTransportSecurityServerTests.TestInputFlowConfiguration;
{$IFDEF TRANSPORT_SECURITY_SERVER}
var
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ErrorMessage: string;
  Flow: TTransportSecurityInputFlow;
  Identity: TBytes;
  OutputFlow: TTransportSecurityOutputFlow;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  FillChar(Connection, SizeOf(Connection), 0);
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  try
    BeginTransportSecurityServer(Connection, Context);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Integer>(Flow.HighWatermark).ToBe(
      TLS_SERVER_DEFAULT_INPUT_CAPACITY);
    Expect<Integer>(Flow.LowWatermark).ToBe(
      TLS_SERVER_DEFAULT_INPUT_CAPACITY div 2);
    Expect<Integer>(Flow.BufferedBytes).ToBe(0);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(0);
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(0);
    Expect<Boolean>(Flow.Backpressured).ToBe(False);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(0);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  finally
    AbortTransportSecurityServer(Connection);
    CloseTransportSecurityServerContext(Context);
  end;

  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_MIN_INPUT_CAPACITY,
    TLS_SERVER_MAX_OUTPUT_CAPACITY);
  try
    BeginTransportSecurityServer(Connection, Context);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Integer>(Flow.HighWatermark).ToBe(
      TLS_SERVER_MIN_INPUT_CAPACITY);
    Expect<Integer>(Flow.LowWatermark).ToBe(
      TLS_SERVER_MIN_INPUT_CAPACITY div 2);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(
      TLS_SERVER_MAX_OUTPUT_CAPACITY);
  finally
    AbortTransportSecurityServer(Connection);
    CloseTransportSecurityServerContext(Context);
  end;

  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_MAX_INPUT_CAPACITY, 0,
    TLS_SERVER_MIN_OUTPUT_CAPACITY);
  try
    BeginTransportSecurityServer(Connection, Context);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Integer>(Flow.HighWatermark).ToBe(
      TLS_SERVER_MAX_INPUT_CAPACITY);
    Expect<Integer>(Flow.LowWatermark).ToBe(0);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(
      TLS_SERVER_MIN_OUTPUT_CAPACITY);
  finally
    AbortTransportSecurityServer(Connection);
    CloseTransportSecurityServerContext(Context);
  end;

  Identity := LoadFixtureBytes(SELF_SIGNED_PKCS12_PATH);
  try
    Context := TTransportSecurityServerContext.Create(Identity,
      PKCS12_PASSPHRASE, TLS_SERVER_MAX_INPUT_CAPACITY, 0,
      TLS_SERVER_MIN_OUTPUT_CAPACITY, tsivPermissive);
    try
      BeginTransportSecurityServer(Connection, Context);
      Flow := TransportSecurityServerInputFlow(Connection);
      Expect<Integer>(Flow.HighWatermark).ToBe(
        TLS_SERVER_MAX_INPUT_CAPACITY);
      Expect<Integer>(Flow.LowWatermark).ToBe(0);
      OutputFlow := TransportSecurityServerOutputFlow(Connection);
      Expect<Integer>(OutputFlow.Capacity).ToBe(
        TLS_SERVER_MIN_OUTPUT_CAPACITY);
    finally
      AbortTransportSecurityServer(Connection);
      CloseTransportSecurityServerContext(Context);
    end;
  finally
    if Length(Identity) > 0 then
      FillChar(Identity[0], Length(Identity), 0);
  end;

  ErrorMessage := CaptureFlowContextError(
    TLS_SERVER_MIN_INPUT_CAPACITY - 1, 0,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  Expect<Boolean>(Pos('between', ErrorMessage) > 0).ToBe(True);
  ErrorMessage := CaptureFlowContextError(
    TLS_SERVER_MAX_INPUT_CAPACITY + 1, 0,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  Expect<Boolean>(Pos('between', ErrorMessage) > 0).ToBe(True);
  ErrorMessage := CaptureFlowContextError(
    TLS_SERVER_MIN_INPUT_CAPACITY, -1,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  Expect<Boolean>(Pos('nonnegative', ErrorMessage) > 0).ToBe(True);
  ErrorMessage := CaptureFlowContextError(
    TLS_SERVER_MIN_INPUT_CAPACITY, TLS_SERVER_MIN_INPUT_CAPACITY,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  Expect<Boolean>(Pos('below capacity', ErrorMessage) > 0).ToBe(True);
  ErrorMessage := CaptureFlowContextError(
    TLS_SERVER_DEFAULT_INPUT_CAPACITY,
    TLS_SERVER_DEFAULT_INPUT_CAPACITY div 2,
    TLS_SERVER_MIN_OUTPUT_CAPACITY - 1);
  Expect<Boolean>(Pos('output capacity', ErrorMessage) > 0).ToBe(True);
  ErrorMessage := CaptureFlowContextError(
    TLS_SERVER_DEFAULT_INPUT_CAPACITY,
    TLS_SERVER_DEFAULT_INPUT_CAPACITY div 2,
    TLS_SERVER_MAX_OUTPUT_CAPACITY + 1);
  Expect<Boolean>(Pos('output capacity', ErrorMessage) > 0).ToBe(True);
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestInputFlowPrefixAdmissionAndCounters;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
const
  PAYLOAD_LENGTH = 16000;
var
  Accepted: Integer;
  BaselineAccepted: QWord;
  BaselineConsumed: QWord;
  Buffer: array[0..PAYLOAD_LENGTH - 1] of Byte;
  Ciphertext: TBytes;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Flow: TTransportSecurityInputFlow;
  Observed: THandshakeObservations;
  Payload: AnsiString;
  ReadResult: TTransportSecurityIOResult;
  Remainder: Integer;
{$ENDIF}
{$IFDEF DARWIN}
const
  DARWIN_PAYLOAD_LENGTH = 16000;
var
  Accepted: Integer;
  BaselineAccepted: QWord;
  BaselineConsumed: QWord;
  Buffer: array[0..DARWIN_PAYLOAD_LENGTH - 1] of Byte;
  Ciphertext: TBytes;
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Flow: TTransportSecurityInputFlow;
  Payload: AnsiString;
  ReadResult: TTransportSecurityIOResult;
  Remainder: Integer;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_MIN_INPUT_CAPACITY, 0,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateHandshakenPair(Context, Connection, Client, Observed);
    Flow := TransportSecurityServerInputFlow(Connection);
    BaselineAccepted := Flow.AcceptedBytes;
    BaselineConsumed := Flow.ConsumedBytes;
    Expect<Int64>(Int64(BaselineAccepted)).ToBe(Int64(BaselineConsumed));
    Expect<Integer>(Flow.BufferedBytes).ToBe(0);
    SetLength(Payload, PAYLOAD_LENGTH);
    FillChar(Payload[1], Length(Payload), Ord('a'));
    WriteRawClientPlaintext(Client, Payload);
    FillChar(Payload[1], Length(Payload), Ord('b'));
    WriteRawClientPlaintext(Client, Payload);
    DrainClientCiphertext(Client, Ciphertext);
    Expect<Boolean>(Length(Ciphertext) >
      TLS_SERVER_MIN_INPUT_CAPACITY).ToBe(True);

    Accepted := TransportSecurityFeedCiphertext(Connection, @Ciphertext[0],
      Length(Ciphertext));
    Expect<Integer>(Accepted).ToBe(TLS_SERVER_MIN_INPUT_CAPACITY);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Integer>(Flow.BufferedBytes).ToBe(
      TLS_SERVER_MIN_INPUT_CAPACITY);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(
      Int64(BaselineAccepted + TLS_SERVER_MIN_INPUT_CAPACITY));
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(Int64(BaselineConsumed));
    Expect<Boolean>(Flow.Backpressured).ToBe(True);
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Ciphertext[Accepted], Length(Ciphertext) - Accepted)).ToBe(0);

    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(PAYLOAD_LENGTH);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Boolean>(Flow.BufferedBytes > 0).ToBe(True);
    Expect<Boolean>(Flow.ConsumedBytes > 0).ToBe(True);
    Expect<Boolean>(Flow.Backpressured).ToBe(True);

    Remainder := Length(Ciphertext) - Accepted;
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Ciphertext[Accepted], Remainder)).ToBe(Remainder);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(PAYLOAD_LENGTH);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(
      Int64(BaselineAccepted + QWord(Length(Ciphertext))));
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(
      Int64(BaselineConsumed + QWord(Length(Ciphertext))));
    Expect<Integer>(Flow.BufferedBytes).ToBe(0);
    Expect<Boolean>(Flow.Backpressured).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_MIN_INPUT_CAPACITY, 0,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    Flow := TransportSecurityServerInputFlow(Connection);
    BaselineAccepted := Flow.AcceptedBytes;
    BaselineConsumed := Flow.ConsumedBytes;
    Expect<Int64>(Int64(BaselineAccepted)).ToBe(Int64(BaselineConsumed));
    SetLength(Payload, DARWIN_PAYLOAD_LENGTH);
    FillChar(Payload[1], Length(Payload), Ord('a'));
    WriteRawSecureTransportClientPlaintext(Client, Payload);
    FillChar(Payload[1], Length(Payload), Ord('b'));
    WriteRawSecureTransportClientPlaintext(Client, Payload);
    Ciphertext := Copy(Client.Output);
    SetLength(Client.Output, 0);
    Expect<Boolean>(Length(Ciphertext) > TLS_SERVER_MIN_INPUT_CAPACITY)
      .ToBe(True);
    Accepted := TransportSecurityFeedCiphertext(Connection, @Ciphertext[0],
      Length(Ciphertext));
    Expect<Integer>(Accepted).ToBe(TLS_SERVER_MIN_INPUT_CAPACITY);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Integer>(Flow.BufferedBytes).ToBe(TLS_SERVER_MIN_INPUT_CAPACITY);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(
      Int64(BaselineAccepted + QWord(Accepted)));
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(Int64(BaselineConsumed));
    Expect<Boolean>(Flow.Backpressured).ToBe(True);
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Ciphertext[Accepted], Length(Ciphertext) - Accepted)).ToBe(0);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(DARWIN_PAYLOAD_LENGTH);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Boolean>(Flow.ConsumedBytes > BaselineConsumed).ToBe(True);
    Expect<Boolean>(Flow.BufferedBytes < TLS_SERVER_MIN_INPUT_CAPACITY)
      .ToBe(True);
    Remainder := Length(Ciphertext) - Accepted;
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Ciphertext[Accepted], Remainder)).ToBe(Remainder);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(DARWIN_PAYLOAD_LENGTH);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(
      Int64(BaselineAccepted + QWord(Length(Ciphertext))));
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(
      Int64(BaselineConsumed + QWord(Length(Ciphertext))));
    Expect<Integer>(Flow.BufferedBytes).ToBe(0);
    Expect<Boolean>(Flow.Backpressured).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestPeerCloseNotifyReportsPeerClosed;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Buffer: array[0..0] of Byte;
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
  ShutdownResult: Integer;
{$ENDIF}
{$IFDEF DARWIN}
var
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    State := TransportSecurityTestInjectSecureTransportPeerClose(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssPeerClosed));
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestPendingCiphertextPointerIsStable;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF DARWIN}
var
  Buffer: array[0..255] of Byte;
  Ciphertext: Pointer;
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  OriginalCiphertext: Pointer;
  Pending: Integer;
  ReadResult: TTransportSecurityIOResult;
  RetryText: AnsiString;
  State: TTransportSecurityState;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
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
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
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
{$IFDEF TRANSPORT_SECURITY_SERVER}
const
  OVERSIZED_PKCS12_LENGTH = 16 * 1024 * 1024 + 1;
var
  ErrorMessage: string;
  Identity: TFileStream;
  OversizedPath: string;
  Passphrase: UnicodeString;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
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

procedure TTransportSecurityServerTests.TestPKCS12BytesArePrimaryInput;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  I: Integer;
  Identity: TBytes;
  Observed: THandshakeObservations;
  OriginalIdentity: TBytes;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Identity := LoadFixtureBytes(PKCS12_PATH);
  OriginalIdentity := Copy(Identity, 0, Length(Identity));
  Context := TTransportSecurityServerContext.Create(Identity,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    Expect<Integer>(Length(Identity)).ToBe(Length(OriginalIdentity));
    for I := 0 to High(Identity) do
      if Identity[I] <> OriginalIdentity[I] then
        raise Exception.Create('PKCS#12 byte input was modified by construction');
    FillChar(Identity[0], Length(Identity), 0);
    CreateHandshakenPair(Context, Connection, Client, Observed);
    Expect<Boolean>(Connection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestPKCS12PathRefusesSymbolicLink;
{$IFDEF UNIX}
var
  Context: TTransportSecurityServerContext;
  ErrorMessage: string;
  FifoPath: string;
  LinkDirectory: string;
  LinkPath: string;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorMessage: string;
  LinkDirectory: string;
  LinkTarget: string;
  RemovalSucceeded: Boolean;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  CloseTransportSecurityServerContext(Context);
  ForceDirectories(SCRATCH_DIRECTORY);
  LinkPath := SCRATCH_DIRECTORY + '/identity-link.p12';
  SysUtils.DeleteFile(LinkPath);
  if fpSymlink(PChar(ExpandFileName(PKCS12_PATH)), PChar(LinkPath)) <> 0 then
    raise Exception.Create('Failed to create PKCS#12 symlink fixture');
  try
    ErrorMessage := CaptureContextError(LinkPath, PKCS12_PASSPHRASE);
    Expect<Boolean>(Pos('without following links', ErrorMessage) > 0).ToBe(True);
    Expect<Boolean>(Pos(LinkPath, ErrorMessage) = 0).ToBe(True);
  finally
    SysUtils.DeleteFile(LinkPath);
  end;

  LinkDirectory := SCRATCH_DIRECTORY + '/identity-parent';
  SysUtils.DeleteFile(LinkDirectory);
  if fpSymlink(PChar(ExtractFileDir(ExpandFileName(PKCS12_PATH))),
     PChar(LinkDirectory)) <> 0 then
    raise Exception.Create('Failed to create PKCS#12 parent symlink fixture');
  try
    ErrorMessage := CaptureContextError(LinkDirectory + '/' +
      ExtractFileName(PKCS12_PATH), PKCS12_PASSPHRASE);
    Expect<Boolean>(Pos('without following links', ErrorMessage) > 0).ToBe(True);
    Expect<Boolean>(Pos(LinkDirectory, ErrorMessage) = 0).ToBe(True);
  finally
    SysUtils.DeleteFile(LinkDirectory);
  end;

  FifoPath := SCRATCH_DIRECTORY + '/identity-fifo.p12';
  SysUtils.DeleteFile(FifoPath);
  if fpMkFifo(PChar(FifoPath), &600) <> 0 then
    raise Exception.Create('Failed to create PKCS#12 FIFO fixture');
  try
    ErrorMessage := CaptureContextError(FifoPath, PKCS12_PASSPHRASE);
    Expect<Boolean>(Pos('must be a regular file', ErrorMessage) > 0).ToBe(True);
    Expect<Boolean>(Pos(FifoPath, ErrorMessage) = 0).ToBe(True);
  finally
    SysUtils.DeleteFile(FifoPath);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ForceDirectories(SCRATCH_DIRECTORY);
  LinkDirectory := SCRATCH_DIRECTORY + '/identity-parent-junction';
  LinkTarget := ExtractFileDir(ExpandFileName(PKCS12_PATH));
  RemoveWindowsJunctionIfPresent(LinkDirectory);
  if not TryCreateWindowsJunction(LinkDirectory, LinkTarget) then
    raise Exception.Create(
      'PKCS#12 parent junction creation failed after a successful preflight');
  RemovalSucceeded := False;
  try
    ErrorMessage := CaptureContextError(LinkDirectory + '/' +
      ExtractFileName(PKCS12_PATH), PKCS12_PASSPHRASE);
    Expect<Boolean>(Pos('without following reparse points',
      ErrorMessage) > 0).ToBe(True);
    Expect<Boolean>(Pos(LinkDirectory, ErrorMessage) = 0).ToBe(True);
  finally
    RemovalSucceeded := Windows.RemoveDirectoryW(
      PWideChar(UnicodeString(LinkDirectory)));
  end;
  if not RemovalSucceeded then
    raise Exception.Create('Failed to remove PKCS#12 parent junction fixture');
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestStrictIdentityAllowsLeafWithoutBasicConstraints;
{$IFDEF TRANSPORT_SECURITY_SERVER}
var
  Context: TTransportSecurityServerContext;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  Context := nil;
  try
    Context := TTransportSecurityServerContext.Create(
      LEAF_NO_BASIC_CONSTRAINTS_PKCS12_PATH, PKCS12_PASSPHRASE);
    Expect<Boolean>(Assigned(Context)).ToBe(True);
  finally
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestStrictIdentityValidation;
{$IFDEF TRANSPORT_SECURITY_SERVER}
var
  Context: TTransportSecurityServerContext;
  ErrorMessage: string;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  {$IFNDEF DARWIN}
  ErrorMessage := CaptureContextError(FUTURE_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('validity window', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected future-certificate error: ' +
      ErrorMessage);

  ErrorMessage := CaptureContextError(WRONG_PURPOSE_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('server authentication', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected wrong-purpose error: ' + ErrorMessage);

  ErrorMessage := CaptureContextError(INCOHERENT_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('structurally or cryptographically incoherent', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected incoherent-chain error: ' + ErrorMessage);

  ErrorMessage := CaptureContextError(CYCLIC_CHAIN_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('certificate cycle', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected cyclic-chain error: ' + ErrorMessage);

  ErrorMessage := CaptureContextError(LEAF_CA_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('leaf certificate must assert CA:FALSE', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected leaf-basic-constraints error: ' +
      ErrorMessage);

  ErrorMessage := CaptureContextError(NON_CA_ISSUER_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('chain certificate 1 must assert CA:TRUE', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected issuer-basic-constraints error: ' +
      ErrorMessage);

  ErrorMessage := CaptureContextError(NO_CERTSIGN_ISSUER_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('key usage must permit certificate signing', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected issuer-key-usage error: ' +
      ErrorMessage);

  ErrorMessage := CaptureContextError(PATH_LENGTH_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('path-length constraint', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected issuer-path-length error: ' +
      ErrorMessage);

  ErrorMessage := CaptureContextError(SELF_SIGNED_PKCS12_PATH,
    PKCS12_PASSPHRASE);
  if Pos('permissive validation', ErrorMessage) = 0 then
    raise Exception.Create('Unexpected self-signed error: ' + ErrorMessage);

  Context := TTransportSecurityServerContext.Create(SELF_SIGNED_PKCS12_PATH,
    PKCS12_PASSPHRASE, tsivPermissive);
  try
    Expect<Boolean>(Assigned(Context)).ToBe(True);
  finally
    CloseTransportSecurityServerContext(Context);
  end;
  {$ELSE}
  Context := nil;
  TransportSecurityTestForceSecureTransportTrustEvaluationFailure(True);
  try
    ErrorMessage := CaptureContextError(PKCS12_PATH, PKCS12_PASSPHRASE);
    Expect<string>(ErrorMessage).ToBe(
      'Configured TLS identity does not form a valid bundled server chain');
  finally
    TransportSecurityTestForceSecureTransportTrustEvaluationFailure(False);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestReloadRetainsSnapshotsAndFailedReloadKeepsActive;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ErrorMessage: string;
  I: Integer;
  Identity: TBytes;
  Observed: THandshakeObservations;
  SecondClient: TRawOpenSSLClient;
  SecondConnection: TTransportSecurityConnection;
  SecondObserved: THandshakeObservations;
  Worker: TBeginAbortWorker;
  WorkerError: string;
  WorkerOperations: LongInt;
  WorkerOperationsBeforeReload: LongInt;
  WorkerStarted: Boolean;
{$ENDIF}
{$IFDEF DARWIN}
var
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ErrorMessage: string;
  Identity: TBytes;
  SecondClient: TRawSecureTransportClient;
  SecondConnection: TTransportSecurityConnection;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  FillChar(SecondConnection, SizeOf(SecondConnection), 0);
  FillChar(SecondClient, SizeOf(SecondClient), 0);
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  try
    BeginTransportSecurityServer(Connection, Context);
    Identity := LoadFixtureBytes(PKCS12_PATH);
    Context.Reload(Identity, PKCS12_PASSPHRASE);
    FillChar(Identity[0], Length(Identity), 0);

    ErrorMessage := '';
    try
      Context.Reload(FUTURE_PKCS12_PATH, PKCS12_PASSPHRASE);
    except
      on E: ETransportSecurityError do
        ErrorMessage := E.Message;
    end;
    Expect<Boolean>(Pos('validity window', ErrorMessage) > 0).ToBe(True);

    CreateHandshakenPair(Context, SecondConnection, SecondClient,
      SecondObserved);
    Expect<Boolean>(SecondConnection.Active).ToBe(True);

    Worker := TBeginAbortWorker.Create(Context);
    WorkerStarted := False;
    WorkerError := '';
    WorkerOperations := 0;
    try
      Worker.Start;
      WorkerStarted := True;
      if not Worker.WaitUntilStarted(5000) then
        raise Exception.Create(
          'Concurrent TLS begin/abort worker did not start in time');
      if not Worker.WaitForOperations(1, 5000) then
        raise Exception.Create(
          'Concurrent TLS begin/abort worker made no progress');
      WorkerOperationsBeforeReload := Worker.Operations;
      Identity := LoadFixtureBytes(PKCS12_PATH);
      try
        for I := 1 to 64 do
          Context.Reload(Identity, PKCS12_PASSPHRASE);
      finally
        FillChar(Identity[0], Length(Identity), 0);
      end;
    finally
      Worker.RequestStop;
      if WorkerStarted then
        Worker.WaitFor;
      WorkerError := Worker.ErrorMessage;
      WorkerOperations := Worker.Operations;
      Worker.Free;
    end;
    if WorkerError <> '' then
      raise Exception.Create('Concurrent TLS begin/abort failed: ' +
        WorkerError);
    Expect<Boolean>(WorkerOperations > WorkerOperationsBeforeReload).ToBe(True);

    CloseTransportSecurityServerContext(Context);

    CreateRawClient(Client);
    DriveHandshake(Connection, Client, Observed);
    Expect<Boolean>(Connection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawClient(Client);
    AbortTransportSecurityServer(SecondConnection);
    FreeRawClient(SecondClient);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  FillChar(SecondConnection, SizeOf(SecondConnection), 0);
  FillChar(SecondClient, SizeOf(SecondClient), 0);
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  try
    BeginTransportSecurityServer(Connection, Context);
    Identity := LoadFixtureBytes(PKCS12_PATH);
    try
      Context.Reload(Identity, PKCS12_PASSPHRASE);
    finally
      FillChar(Identity[0], Length(Identity), 0);
    end;
    ErrorMessage := '';
    try
      Context.Reload(PKCS12_PATH, 'wrong-passphrase');
    except
      on E: ETransportSecurityError do ErrorMessage := E.Message;
    end;
    Expect<Boolean>(Pos('Failed to parse configured TLS PKCS#12',
      ErrorMessage) = 1).ToBe(True);
    BeginTransportSecurityServer(SecondConnection, Context);
    CloseTransportSecurityServerContext(Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    CreateRawSecureTransportClient(SecondClient);
    DriveRawSecureTransportHandshake(SecondConnection, SecondClient);
    Expect<Boolean>(Connection.Active).ToBe(True);
    Expect<Boolean>(SecondConnection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    AbortTransportSecurityServer(SecondConnection);
    FreeRawSecureTransportClient(SecondClient);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestHandshakeTransitionsAndContextReuse;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Buffer: array[0..255] of Byte;
  Ciphertext: Pointer;
  Client: TRawOpenSSLClient;
  ClientRead: Integer;
  ClientWritten: Integer;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  OutputFlow: TTransportSecurityOutputFlow;
  Partial: Integer;
  Pending: Integer;
  ReadResult: TTransportSecurityIOResult;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
{$IFDEF DARWIN}
var
  Buffer: array[0..255] of Byte;
  Client: TRawSecureTransportClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  OutputFlow: TTransportSecurityOutputFlow;
  Partial: Integer;
  Pending: Integer;
  ReadResult: TTransportSecurityIOResult;
  ServerCiphertext: Pointer;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(Pending);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY - Pending);
    Partial := Pending div 2;
    Expect<Integer>(RawBIOWrite(Client.ReadBIO, Ciphertext,
      Partial)).ToBe(Partial);
    TransportSecurityConsumeCiphertext(Connection, Partial);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(
      Pending - Partial);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(Pending - Partial);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY - Pending + Partial);
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
  {$IFDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    WriteRawSecureTransportClientPlaintext(Client, CLIENT_REQUEST);
    Expect<Boolean>(Length(Client.Output) > 1).ToBe(True);
    Partial := Length(Client.Output) div 2;
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Client.Output[0], Partial)).ToBe(Partial);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(Ord(ReadResult.State)).ToBe(Ord(tssWantRead));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(0);
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Client.Output[Partial], Length(Client.Output) - Partial)).ToBe(
      Length(Client.Output) - Partial);
    SetLength(Client.Output, 0);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(Length(CLIENT_REQUEST));
    Expect<string>(Copy(PAnsiChar(@Buffer[0]), 1,
      ReadResult.BytesProcessed)).ToBe(CLIENT_REQUEST);
    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(SERVER_RESPONSE));
    Pending := TransportSecurityGetCiphertext(Connection, ServerCiphertext);
    Expect<Boolean>(Pending > 1).ToBe(True);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(Pending);
    Partial := Pending div 2;
    SetLength(Client.Input, Partial);
    Move(ServerCiphertext^, Client.Input[0], Partial);
    TransportSecurityConsumeCiphertext(Connection, Partial);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(
      Pending - Partial);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(Pending - Partial);
    PumpRawSecureTransportServer(Connection, Client);
    Expect<string>(ReadRawSecureTransportClientPlaintext(Client)).ToBe(
      SERVER_RESPONSE);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestRenegotiationIsRefused;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Client: TRawOpenSSLClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ObservedError: Integer;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  OutputFlow: TTransportSecurityOutputFlow;
  Payload: TBytes;
  ReadCount: Integer;
  Received: TBytes;
  Step: Integer;
  WriteCompleted: Boolean;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_DEFAULT_INPUT_CAPACITY,
    TLS_SERVER_MIN_OUTPUT_CAPACITY);
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
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(
      TLS_SERVER_MIN_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(
      TLS_SERVER_MIN_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(0);
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
{$IFDEF TRANSPORT_SECURITY_SERVER}
{$IFNDEF DARWIN}
const
  INVALID_HANDSHAKE = #$16#$03#$03#$00#$01#$00;
{$ENDIF}
var
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  {$IFNDEF DARWIN}
  I: Integer;
  {$ENDIF}
  State: TTransportSecurityState;
  {$IFDEF DARWIN}
  Client: TRawSecureTransportClient;
  WriteResult: TTransportSecurityIOResult;
  {$ENDIF}
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  {$IFDEF DARWIN}
  FillChar(Client, SizeOf(Client), 0);
  {$ENDIF}
  try
    BeginTransportSecurityServer(Connection, Context);
    {$IFDEF DARWIN}
    CreateRawSecureTransportClient(Client);
    DriveRawSecureTransportHandshake(Connection, Client);
    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(SERVER_RESPONSE));
    Expect<Boolean>(TransportSecurityPendingCiphertext(Connection) > 0).ToBe(
      True);
    State := TransportSecurityTestInjectSecureTransportFatalStatus(Connection);
    {$ELSE}
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @INVALID_HANDSHAKE[1], Length(INVALID_HANDSHAKE))).ToBe(
      Length(INVALID_HANDSHAKE));
    State := tssWantRead;
    for I := 1 to 3 do
    begin
      State := TransportSecurityServerHandshake(Connection);
      if State <> tssWantRead then
        Break;
    end;
    {$ENDIF}
    Expect<Integer>(Ord(State)).ToBe(Ord(tssError));
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    {$IFDEF DARWIN}
    FreeRawSecureTransportClient(Client);
    {$ENDIF}
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestFatalShutdownPoisonsBeforeOutput;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Client: TRawOpenSSLClient;
  ClientState: TTransportSecurityState;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  I: Integer;
  ServerState: TTransportSecurityState;
{$ENDIF}
{$IFDEF DARWIN}
var
  Client: TRawSecureTransportClient;
  ClientStatus: LongInt;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  I: Integer;
  ServerState: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
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
  {$IFDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    CreateRawSecureTransportClientWithRange(Client,
      TEST_K_TLS_PROTOCOL_11, TEST_K_TLS_PROTOCOL_11);
    ServerState := tssWantRead;
    for I := 1 to 100 do
    begin
      ClientStatus := TestSSLHandshake(Client.Context);
      PumpRawSecureTransportClient(Client, Connection);
      ServerState := TransportSecurityServerHandshake(Connection);
      if ServerState = tssError then Break;
      PumpRawSecureTransportServer(Connection, Client);
      if (ClientStatus <> TEST_ERR_SEC_SUCCESS)
        and (ClientStatus <> TEST_ERR_SSL_WOULD_BLOCK)
        and (Length(Client.Output) = 0) then Break;
    end;
    Expect<Integer>(Ord(ServerState)).ToBe(Ord(tssError));
    Expect<Boolean>(Connection.Active).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeRawSecureTransportClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelHandshakeRoundtripAndContextReuse;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Buffer: array[0..255] of Byte;
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
  SecondClient: TSChannelTestClient;
  SecondConnection: TTransportSecurityConnection;
  SecondObserved: THandshakeObservations;
  State: TTransportSecurityState;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  FillChar(SecondConnection, SizeOf(SecondConnection), 0);
  FillChar(SecondClient, SizeOf(SecondClient), 0);
  try
    BeginTransportSecurityServer(Connection, Context);
    Expect<Boolean>(Connection.Active).ToBe(False);
    State := TransportSecurityServerHandshake(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantRead));
    Expect<Boolean>(Connection.Active).ToBe(False);

    CreateSChannelClient(Client);
    DriveSChannelHandshake(Connection, Client, Observed);
    Expect<Boolean>(Connection.Active).ToBe(True);
    Expect<Boolean>(Observed.SawWantRead).ToBe(True);
    Expect<Boolean>(Observed.SawWantWrite).ToBe(True);

    WriteSChannelClientText(Client, CLIENT_REQUEST);
    PumpSChannelClientCiphertext(Client, Connection);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(Length(CLIENT_REQUEST));
    Expect<string>(Copy(PAnsiChar(@Buffer[0]), 1,
      ReadResult.BytesProcessed)).ToBe(CLIENT_REQUEST);

    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(SERVER_RESPONSE));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    PumpSChannelServerCiphertext(Connection, Client);
    Expect<string>(ReadSChannelClientText(Client)).ToBe(SERVER_RESPONSE);

    CreateSChannelHandshakenPair(Context, SecondConnection, SecondClient,
      SecondObserved);
    Expect<Boolean>(SecondConnection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    AbortTransportSecurityServer(SecondConnection);
    FreeSChannelClient(SecondClient);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelProtocolCeilingFollowsOperatingSystem;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  ExpectedProtocol: LongWord;
  Observed: THandshakeObservations;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    if TestSChannelSupportsTls13 then
      ExpectedProtocol := SP_PROT_TLS1_3_CLIENT
    else
      ExpectedProtocol := SP_PROT_TLS1_2_CLIENT;
    Expect<LongWord>(SChannelClientProtocol(Client)).ToBe(ExpectedProtocol);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelInputFlowPrefixAdmissionAndCounters;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
const
  PAYLOAD_LENGTH = 16000;
var
  Accepted: Integer;
  BaselineAccepted: QWord;
  BaselineConsumed: QWord;
  Buffer: array[0..PAYLOAD_LENGTH - 1] of Byte;
  Ciphertext: TBytes;
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Flow: TTransportSecurityInputFlow;
  Observed: THandshakeObservations;
  Payload: AnsiString;
  ReadResult: TTransportSecurityIOResult;
  Remainder: Integer;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_MIN_INPUT_CAPACITY, 0,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    Flow := TransportSecurityServerInputFlow(Connection);
    BaselineAccepted := Flow.AcceptedBytes;
    BaselineConsumed := Flow.ConsumedBytes;
    Expect<Int64>(Int64(BaselineAccepted)).ToBe(Int64(BaselineConsumed));
    Expect<Integer>(Flow.BufferedBytes).ToBe(0);

    SetLength(Payload, PAYLOAD_LENGTH);
    FillChar(Payload[1], Length(Payload), Ord('a'));
    WriteSChannelClientText(Client, Payload);
    FillChar(Payload[1], Length(Payload), Ord('b'));
    WriteSChannelClientText(Client, Payload);
    DrainSChannelClientCiphertext(Client, Ciphertext);
    Expect<Boolean>(Length(Ciphertext) >
      TLS_SERVER_MIN_INPUT_CAPACITY).ToBe(True);

    Accepted := TransportSecurityFeedCiphertext(Connection, @Ciphertext[0],
      Length(Ciphertext));
    Expect<Integer>(Accepted).ToBe(TLS_SERVER_MIN_INPUT_CAPACITY);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Integer>(Flow.BufferedBytes).ToBe(TLS_SERVER_MIN_INPUT_CAPACITY);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(
      Int64(BaselineAccepted + TLS_SERVER_MIN_INPUT_CAPACITY));
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(Int64(BaselineConsumed));
    Expect<Boolean>(Flow.Backpressured).ToBe(True);
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Ciphertext[Accepted], Length(Ciphertext) - Accepted)).ToBe(0);

    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(PAYLOAD_LENGTH);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Boolean>(Flow.BufferedBytes > 0).ToBe(True);
    Expect<Boolean>(Flow.ConsumedBytes > 0).ToBe(True);
    Expect<Boolean>(Flow.Backpressured).ToBe(True);

    Remainder := Length(Ciphertext) - Accepted;
    Expect<Integer>(TransportSecurityFeedCiphertext(Connection,
      @Ciphertext[Accepted], Remainder)).ToBe(Remainder);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(PAYLOAD_LENGTH);
    Flow := TransportSecurityServerInputFlow(Connection);
    Expect<Int64>(Int64(Flow.AcceptedBytes)).ToBe(
      Int64(BaselineAccepted + QWord(Length(Ciphertext))));
    Expect<Int64>(Int64(Flow.ConsumedBytes)).ToBe(
      Int64(BaselineConsumed + QWord(Length(Ciphertext))));
    Expect<Integer>(Flow.BufferedBytes).ToBe(0);
    Expect<Boolean>(Flow.Backpressured).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelPendingCiphertextPointerAndPartialConsumption;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Buffer: array[0..255] of Byte;
  Ciphertext: Pointer;
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  OriginalCiphertext: Pointer;
  OutputFlow: TTransportSecurityOutputFlow;
  Partial: Integer;
  Pending: Integer;
  ReadResult: TTransportSecurityIOResult;
  RetryText: AnsiString;
  State: TTransportSecurityState;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    WriteSChannelClientText(Client, CLIENT_REQUEST);
    PumpSChannelClientCiphertext(Client, Connection);

    WriteResult := TransportSecurityServerWrite(Connection,
      @SERVER_RESPONSE[1], Length(SERVER_RESPONSE));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Pending := TransportSecurityGetCiphertext(Connection, OriginalCiphertext);
    Expect<Boolean>(Pending > 1).ToBe(True);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(Pending);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY - Pending);

    State := TransportSecurityServerHandshake(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(Ord(ReadResult.State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(0);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    RetryText := 'write waits without consuming caller plaintext';
    WriteResult := TransportSecurityServerWrite(Connection, @RetryText[1],
      Length(RetryText));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(0);

    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending);
    Expect<Boolean>(Ciphertext = OriginalCiphertext).ToBe(True);

    Partial := Pending div 2;
    AppendTestBytes(Client.Incoming, OriginalCiphertext, Partial);
    TransportSecurityConsumeCiphertext(Connection, Partial);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(
      Pending - Partial);
    Expect<Integer>(TransportSecurityGetCiphertext(Connection,
      Ciphertext)).ToBe(Pending - Partial);
    Expect<Boolean>(Ciphertext =
      Pointer(PtrUInt(OriginalCiphertext) + PtrUInt(Partial))).ToBe(True);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(Pending - Partial);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(
      TLS_SERVER_DEFAULT_OUTPUT_CAPACITY - Pending + Partial);
    PumpSChannelServerCiphertext(Connection, Client);
    Expect<string>(ReadSChannelClientText(Client)).ToBe(SERVER_RESPONSE);

    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(Length(CLIENT_REQUEST));
    Expect<string>(Copy(PAnsiChar(@Buffer[0]), 1,
      ReadResult.BytesProcessed)).ToBe(CLIENT_REQUEST);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelWriteWantRetryRetainsPlaintext;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
const
  LARGE_WRITE_SIZE = 64 * 1024 + 137;
var
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Expected: TBytes;
  I: Integer;
  Observed: THandshakeObservations;
  Offset: Integer;
  OutputFlow: TTransportSecurityOutputFlow;
  Payload: TBytes;
  Received: TBytes;
  Segment: TBytes;
  Step: Integer;
  WriteCompleted: Boolean;
  WriteResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE, TLS_SERVER_DEFAULT_INPUT_CAPACITY,
    TLS_SERVER_MIN_OUTPUT_CAPACITY);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    SetLength(Payload, LARGE_WRITE_SIZE);
    for I := 0 to High(Payload) do
      Payload[I] := Byte((I * 31 + 17) and $FF);
    Expected := Copy(Payload, 0, Length(Payload));

    WriteResult := TransportSecurityServerWrite(Connection, @Payload[0],
      Length(Payload));
    Expect<Integer>(Ord(WriteResult.State)).ToBe(Ord(tssWantWrite));
    Expect<Integer>(WriteResult.BytesProcessed).ToBe(0);
    OutputFlow := TransportSecurityServerOutputFlow(Connection);
    Expect<Integer>(OutputFlow.Capacity).ToBe(TLS_SERVER_MIN_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.PendingBytes).ToBe(
      TLS_SERVER_MIN_OUTPUT_CAPACITY);
    Expect<Integer>(OutputFlow.RemainingBytes).ToBe(0);
    FillChar(Payload[0], Length(Payload), $A5);

    WriteCompleted := False;
    for Step := 1 to 128 do
    begin
      PumpSChannelServerCiphertext(Connection, Client);
      WriteResult := TransportSecurityServerWrite(Connection, nil, 0);
      if WriteResult.BytesProcessed > 0 then
      begin
        Expect<Integer>(WriteResult.BytesProcessed).ToBe(Length(Expected));
        WriteCompleted := True;
      end;
      if WriteResult.State = tssError then
        raise Exception.Create('Retained SChannel write retry failed');
      if WriteCompleted and
         (TransportSecurityPendingCiphertext(Connection) = 0) then
        Break;
    end;
    PumpSChannelServerCiphertext(Connection, Client);
    if not WriteCompleted then
      raise Exception.Create(
        'Retained SChannel write did not complete after 128 drain steps');

    SetLength(Received, 0);
    Offset := 0;
    while Offset < Length(Expected) do
    begin
      if ReadSChannelClientPlaintext(Client, Segment) <> tssDone then
        raise Exception.Create('Raw SChannel client large read failed');
      SetLength(Received, Offset + Length(Segment));
      Move(Segment[0], Received[Offset], Length(Segment));
      Inc(Offset, Length(Segment));
    end;
    if Length(Received) <> Length(Expected) then
      raise Exception.CreateFmt(
        'Retained SChannel plaintext length differs: expected %d, got %d',
        [Length(Expected), Length(Received)]);
    if CompareByte(Expected[0], Received[0], Length(Expected)) <> 0 then
      for I := 0 to High(Expected) do
        if Expected[I] <> Received[I] then
          raise Exception.CreateFmt(
            'Retained SChannel plaintext differs at %d: expected %d, got %d',
            [I, Expected[I], Received[I]]);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.TestSChannelCertificateChainDelivered;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
const
  INTERMEDIATE_COMMON_NAME = 'TransportSecurity Test Intermediate CA';
var
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Delivered: string;
  DeliveredCount: Integer;
  Observed: THandshakeObservations;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    SChannelClientDeliveredChain(Client, Delivered, DeliveredCount);
    if Pos(INTERMEDIATE_COMMON_NAME, Delivered) = 0 then
      raise Exception.CreateFmt(
        'Server flight omitted the bundled intermediate; ' +
        'flight certificates: %d; delivered: %s',
        [DeliveredCount, Delivered]);
    Expect<Boolean>(Pos(INTERMEDIATE_COMMON_NAME, Delivered) > 0).ToBe(True);
    { Exactly the bundle: leaf plus its one intermediate, no root and nothing
      swept in from a local store. }
    if DeliveredCount <> 2 then
      raise Exception.CreateFmt(
        'Server flight carried %d certificates instead of the bundled 2: %s',
        [DeliveredCount, Delivered]);
    Expect<Integer>(DeliveredCount).ToBe(2);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelGracefulCloseProducesCloseNotify;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  Segment: TBytes;
  State: TTransportSecurityState;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    State := CloseTransportSecurityServerGracefully(Connection);
    Expect<Integer>(Ord(State)).ToBe(Ord(tssWantWrite));
    Expect<Boolean>(TransportSecurityPendingCiphertext(Connection) > 0).ToBe(
      True);
    PumpSChannelServerCiphertext(Connection, Client);
    Expect<Integer>(Ord(ReadSChannelClientPlaintext(Client, Segment))).ToBe(
      Ord(tssPeerClosed));
    Expect<Boolean>(Connection.Active).ToBe(True);
    AbortTransportSecurityServer(Connection);
    Expect<Boolean>(Connection.Active).ToBe(False);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelPeerCloseNotifyReportsPeerClosed;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Buffer: array[0..0] of Byte;
  Client: TSChannelTestClient;
  Connection: TTransportSecurityConnection;
  Context: TTransportSecurityServerContext;
  Observed: THandshakeObservations;
  ReadResult: TTransportSecurityIOResult;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
    PKCS12_PASSPHRASE);
  FillChar(Connection, SizeOf(Connection), 0);
  FillChar(Client, SizeOf(Client), 0);
  try
    CreateSChannelHandshakenPair(Context, Connection, Client, Observed);
    ShutdownSChannelClient(Client);
    PumpSChannelClientCiphertext(Client, Connection);
    ReadResult := TransportSecurityServerRead(Connection, Buffer,
      Length(Buffer));
    Expect<Integer>(Ord(ReadResult.State)).ToBe(Ord(tssPeerClosed));
    Expect<Integer>(ReadResult.BytesProcessed).ToBe(0);
    Expect<Boolean>(Connection.Active).ToBe(False);
    Expect<Integer>(TransportSecurityPendingCiphertext(Connection)).ToBe(0);
  finally
    AbortTransportSecurityServer(Connection);
    FreeSChannelClient(Client);
    CloseTransportSecurityServerContext(Context);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelIdentityImportsIsolatedKeyContainers;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
const
  INTERMEDIATE_COMMON_NAME = 'TransportSecurity Test Intermediate CA';
var
  Delivered: string;
  DeliveredCount: Integer;
  FirstClient: TSChannelTestClient;
  FirstConnection: TTransportSecurityConnection;
  FirstContext: TTransportSecurityServerContext;
  FirstName: UnicodeString;
  Observed: THandshakeObservations;
  SecondClient: TSChannelTestClient;
  SecondConnection: TTransportSecurityConnection;
  SecondContext: TTransportSecurityServerContext;
  SecondName: UnicodeString;
  SurvivorClient: TSChannelTestClient;
  SurvivorConnection: TTransportSecurityConnection;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  FirstContext := nil;
  SecondContext := nil;
  FillChar(FirstConnection, SizeOf(FirstConnection), 0);
  FillChar(SecondConnection, SizeOf(SecondConnection), 0);
  FillChar(SurvivorConnection, SizeOf(SurvivorConnection), 0);
  FillChar(FirstClient, SizeOf(FirstClient), 0);
  FillChar(SecondClient, SizeOf(SecondClient), 0);
  FillChar(SurvivorClient, SizeOf(SurvivorClient), 0);
  try
    FirstContext := TTransportSecurityServerContext.Create(PKCS12_PATH,
      PKCS12_PASSPHRASE);
    SecondContext := TTransportSecurityServerContext.Create(PKCS12_PATH,
      PKCS12_PASSPHRASE);
    FirstName := TransportSecurityTestServerKeyContainer(FirstContext);
    SecondName := TransportSecurityTestServerKeyContainer(SecondContext);
    Expect<Boolean>(FirstName <> '').ToBe(True);
    Expect<Boolean>(FirstName <> SecondName).ToBe(True);

    CreateSChannelHandshakenPair(FirstContext, FirstConnection, FirstClient,
      Observed);
    Expect<Boolean>(FirstConnection.Active).ToBe(True);
    CreateSChannelHandshakenPair(SecondContext, SecondConnection, SecondClient,
      Observed);
    Expect<Boolean>(SecondConnection.Active).ToBe(True);

    { Closing the first context deletes its persisted container. The second
      identity was imported from the same bundle, so this is where a shared
      container would show up as a dead key. }
    AbortTransportSecurityServer(FirstConnection);
    FreeSChannelClient(FirstClient);
    CloseTransportSecurityServerContext(FirstContext);
    CreateSChannelHandshakenPair(SecondContext, SurvivorConnection,
      SurvivorClient, Observed);
    Expect<Boolean>(SurvivorConnection.Active).ToBe(True);
    SChannelClientDeliveredChain(SurvivorClient, Delivered, DeliveredCount);
    Expect<Boolean>(Pos(INTERMEDIATE_COMMON_NAME, Delivered) > 0).ToBe(True);
    Expect<Integer>(DeliveredCount).ToBe(2);
  finally
    AbortTransportSecurityServer(FirstConnection);
    AbortTransportSecurityServer(SecondConnection);
    AbortTransportSecurityServer(SurvivorConnection);
    FreeSChannelClient(FirstClient);
    FreeSChannelClient(SecondClient);
    FreeSChannelClient(SurvivorClient);
    CloseTransportSecurityServerContext(FirstContext);
    CloseTransportSecurityServerContext(SecondContext);
  end;
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.
  TestSChannelReloadRetainsPreviousKeyContainer;
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Context: TTransportSecurityServerContext;
  FreshClient: TSChannelTestClient;
  FreshConnection: TTransportSecurityConnection;
  NameAfterReload: UnicodeString;
  NameBeforeReload: UnicodeString;
  Observed: THandshakeObservations;
  RetainedClient: TSChannelTestClient;
  RetainedConnection: TTransportSecurityConnection;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Context := nil;
  FillChar(RetainedConnection, SizeOf(RetainedConnection), 0);
  FillChar(FreshConnection, SizeOf(FreshConnection), 0);
  FillChar(RetainedClient, SizeOf(RetainedClient), 0);
  FillChar(FreshClient, SizeOf(FreshClient), 0);
  try
    Context := TTransportSecurityServerContext.Create(PKCS12_PATH,
      PKCS12_PASSPHRASE);
    { Begin before the reload so this connection retains the old snapshot. }
    BeginTransportSecurityServer(RetainedConnection, Context);
    NameBeforeReload := TransportSecurityTestServerKeyContainer(Context);
    Context.Reload(PKCS12_PATH, PKCS12_PASSPHRASE);
    NameAfterReload := TransportSecurityTestServerKeyContainer(Context);
    Expect<Boolean>(NameBeforeReload <> '').ToBe(True);
    Expect<Boolean>(NameAfterReload <> '').ToBe(True);
    Expect<Boolean>(NameBeforeReload <> NameAfterReload).ToBe(True);

    { The reloaded-away snapshot still holds a reference, so its container
      must outlive the reload and complete this handshake. }
    CreateSChannelClient(RetainedClient);
    DriveSChannelHandshake(RetainedConnection, RetainedClient, Observed);
    Expect<Boolean>(RetainedConnection.Active).ToBe(True);

    CreateSChannelHandshakenPair(Context, FreshConnection, FreshClient,
      Observed);
    Expect<Boolean>(FreshConnection.Active).ToBe(True);
  finally
    AbortTransportSecurityServer(RetainedConnection);
    AbortTransportSecurityServer(FreshConnection);
    FreeSChannelClient(RetainedClient);
    FreeSChannelClient(FreshClient);
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
  FServerBackendAvailable := TransportSecurityServerBackendAvailable;
  Test('Darwin Secure Transport resolves server symbols concurrently once',
    TestDarwinConcurrentSecureTransportFirstUse);
  Test('Darwin Secure Transport cleanup failures preserve primary errors',
    TestDarwinSecureTransportCleanupFailures);
  Test('Darwin Secure Transport disables trust network fetching',
    TestDarwinSecureTransportNetworkFetchDisabled);
  Test('Darwin Secure Transport server begins and aborts cleanly',
    TestDarwinSecureTransportServerLifecycle);
  Test('Darwin Secure Transport handshake and IO round-trip in memory',
    TestDarwinSecureTransportRoundTrip);
  Skip('empty and UTF-8 PKCS#12 passphrases load',
    TestEmptyAndUTF8Passphrases,
    'the existing OpenSSL-generated fixtures use PKCS#12 algorithms unsupported by Security.framework');
  ServerTest('embedded-NUL PKCS#12 passphrase is rejected',
    TestEmbeddedNULPassphraseRejected);
  ServerTest('missing PKCS#12 fails without disclosing path',
    TestMissingPKCS12FailsWithoutPathDisclosure);
  ServerTest('server input flow validates and publishes watermarks',
    TestInputFlowConfiguration);
  ServerTest('garbage and wrong-pass PKCS#12 fail actionably',
    TestPKCS12LoadFailures);
  ServerTest('PKCS#12 identities above 16 MiB fail without disclosure',
    TestPKCS12SizeLimit);
  ServerTest('strict identity policy rejects invalid production certificates',
    TestStrictIdentityValidation);
  Skip('strict identity allows a leaf without basic constraints',
    TestStrictIdentityAllowsLeafWithoutBasicConstraints,
    DARWIN_SKIP_REASON);
  ServerTest('fatal handshake poisons connection',
    TestFatalHandshakePoisonsConnection);
  ServerTest('PKCS#12 path loading refuses links in every component',
    TestPKCS12PathRefusesSymbolicLink);
  ServerTest('Active becomes true only after the server handshake',
    TestActiveOnlyAfterHandshake);
  Skip('server read clamps oversized lengths on a handshaken connection',
    TestBoundsClamp,
    DARWIN_SKIP_REASON);
  ServerTest('PKCS#12 chain delivers the intermediate certificate',
    TestCertificateChainDelivered);
  ServerTest('server input flow accepts bounded prefixes and counts consumption',
    TestInputFlowPrefixAdmissionAndCounters);
  ServerTest('peer close_notify reports peer-closed and poisons the connection',
    TestPeerCloseNotifyReportsPeerClosed);
  ServerTest('pending ciphertext pointer stays stable across protocol calls',
    TestPendingCiphertextPointerIsStable);
  Skip('caller PKCS#12 bytes are copied before synchronous parsing',
    TestPKCS12BytesArePrimaryInput,
    DARWIN_SKIP_REASON);
  ServerTest('identity reload retains immutable connection snapshots',
    TestReloadRetainsSnapshotsAndFailedReloadKeepsActive);
  Skip('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse,
    DARWIN_SKIP_REASON);
  ServerTest('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption);
  Skip('fatal shutdown poisons before retaining alert output',
    TestFatalShutdownPoisonsBeforeOutput,
    DARWIN_SKIP_REASON);
  Skip('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify,
    DARWIN_SKIP_REASON);
  Skip('TLS 1.2 renegotiation is refused',
    TestRenegotiationIsRefused,
    DARWIN_SKIP_REASON);
  Skip('stale OpenSSL error queue is cleared before server operations',
    TestStaleErrorQueueIsCleared,
    DARWIN_SKIP_REASON);
  Skip('SSL_ERROR_SYSCALL poisons the connection',
    TestSyscallErrorPoisonsConnection,
    DARWIN_SKIP_REASON);
  ServerTest('TLS floor rejects TLS 1.1',
    TestTLSFloorRejectsTLS11);
  Skip('SSL_write WANT retry retains the original plaintext',
    TestWriteWantRetryRetainsPlaintext,
    DARWIN_SKIP_REASON);
  Skip('SChannel handshake round-trips plaintext and reuses the context',
    TestSChannelHandshakeRoundtripAndContextReuse,
    DARWIN_SKIP_REASON);
  Skip('SChannel PKCS#12 chain delivers the intermediate certificate',
    TestSChannelCertificateChainDelivered,
    DARWIN_SKIP_REASON);
  Skip('SChannel input flow accepts bounded prefixes and counts consumption',
    TestSChannelInputFlowPrefixAdmissionAndCounters,
    DARWIN_SKIP_REASON);
  Skip('SChannel pending ciphertext pointer survives partial consumption',
    TestSChannelPendingCiphertextPointerAndPartialConsumption,
    DARWIN_SKIP_REASON);
  Skip('SChannel write WANT retry retains the original plaintext',
    TestSChannelWriteWantRetryRetainsPlaintext,
    DARWIN_SKIP_REASON);
  Skip('SChannel graceful close emits close_notify',
    TestSChannelGracefulCloseProducesCloseNotify,
    DARWIN_SKIP_REASON);
  Skip('SChannel peer close_notify reports peer-closed',
    TestSChannelPeerCloseNotifyReportsPeerClosed,
    DARWIN_SKIP_REASON);
  Skip('SChannel protocol ceiling follows operating-system capability',
    TestSChannelProtocolCeilingFollowsOperatingSystem,
    DARWIN_SKIP_REASON);
  Skip('SChannel identities import into isolated key containers',
    TestSChannelIdentityImportsIsolatedKeyContainers,
    DARWIN_SKIP_REASON);
  Skip('SChannel reload retains the previous key container',
    TestSChannelReloadRetainsPreviousKeyContainer,
    DARWIN_SKIP_REASON);
  {$ELSE}
  FServerBackendAvailable := TransportSecurityServerBackendAvailable;
  Skip('Darwin Secure Transport server begins and aborts cleanly',
    TestDarwinSecureTransportServerLifecycle, 'Darwin-only behavior');
  Skip('Darwin Secure Transport handshake and IO round-trip in memory',
    TestDarwinSecureTransportRoundTrip, 'Darwin-only behavior');
  Skip('Darwin Secure Transport resolves server symbols concurrently once',
    TestDarwinConcurrentSecureTransportFirstUse, 'Darwin-only behavior');
  Skip('Darwin Secure Transport cleanup failures preserve primary errors',
    TestDarwinSecureTransportCleanupFailures, 'Darwin-only behavior');
  Skip('Darwin Secure Transport disables trust network fetching',
    TestDarwinSecureTransportNetworkFetchDisabled, 'Darwin-only behavior');

  { Backend-neutral coverage: identity policy, flow configuration, and
    fatal-handshake poisoning need no loopback peer, so every platform
    that has a server backend runs them. }
  ServerTest('empty and UTF-8 PKCS#12 passphrases load',
    TestEmptyAndUTF8Passphrases);
  ServerTest('embedded-NUL PKCS#12 passphrase is rejected',
    TestEmbeddedNULPassphraseRejected);
  ServerTest('missing PKCS#12 fails without disclosing path',
    TestMissingPKCS12FailsWithoutPathDisclosure);
  ServerTest('server input flow validates and publishes watermarks',
    TestInputFlowConfiguration);
  ServerTest('garbage and wrong-pass PKCS#12 fail actionably',
    TestPKCS12LoadFailures);
  ServerTest('PKCS#12 identities above 16 MiB fail without disclosure',
    TestPKCS12SizeLimit);
  ServerTest('strict identity policy rejects invalid production certificates',
    TestStrictIdentityValidation);
  ServerTest('strict identity allows a leaf without basic constraints',
    TestStrictIdentityAllowsLeafWithoutBasicConstraints);
  ServerTest('fatal handshake poisons connection',
    TestFatalHandshakePoisonsConnection);
  {$IFDEF MSWINDOWS}
  if not FServerBackendAvailable then
    ServerTest('PKCS#12 path loading refuses links in every component',
      TestPKCS12PathRefusesSymbolicLink)
  else if WindowsJunctionTestAvailable then
    Test('PKCS#12 path loading refuses links in every component',
      TestPKCS12PathRefusesSymbolicLink)
  else
    Skip('PKCS#12 path loading refuses links in every component',
      TestPKCS12PathRefusesSymbolicLink,
      'Windows junction creation is unavailable under host policy');
  {$ELSE}
  ServerTest('PKCS#12 path loading refuses links in every component',
    TestPKCS12PathRefusesSymbolicLink);
  {$ENDIF}

  { Cases that need the raw in-memory OpenSSL loopback client. }
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  ServerTest('Active becomes true only after the server handshake',
    TestActiveOnlyAfterHandshake);
  ServerTest('server read clamps oversized lengths on a handshaken connection',
    TestBoundsClamp);
  ServerTest('PKCS#12 chain delivers the intermediate certificate',
    TestCertificateChainDelivered);
  ServerTest('server input flow accepts bounded prefixes and counts consumption',
    TestInputFlowPrefixAdmissionAndCounters);
  ServerTest('peer close_notify reports peer-closed and poisons the connection',
    TestPeerCloseNotifyReportsPeerClosed);
  ServerTest('pending ciphertext pointer stays stable across protocol calls',
    TestPendingCiphertextPointerIsStable);
  ServerTest('caller PKCS#12 bytes are copied before synchronous parsing',
    TestPKCS12BytesArePrimaryInput);
  ServerTest('identity reload retains immutable connection snapshots',
    TestReloadRetainsSnapshotsAndFailedReloadKeepsActive);
  ServerTest('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse);
  ServerTest('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption);
  ServerTest('fatal shutdown poisons before retaining alert output',
    TestFatalShutdownPoisonsBeforeOutput);
  ServerTest('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify);
  ServerTest('TLS 1.2 renegotiation is refused',
    TestRenegotiationIsRefused);
  ServerTest('stale OpenSSL error queue is cleared before server operations',
    TestStaleErrorQueueIsCleared);
  ServerTest('SSL_ERROR_SYSCALL poisons the connection',
    TestSyscallErrorPoisonsConnection);
  ServerTest('TLS floor rejects TLS 1.1',
    TestTLSFloorRejectsTLS11);
  ServerTest('SSL_write WANT retry retains the original plaintext',
    TestWriteWantRetryRetainsPlaintext);
  {$ELSE}
  Skip('Active becomes true only after the server handshake',
    TestActiveOnlyAfterHandshake,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('server read clamps oversized lengths on a handshaken connection',
    TestBoundsClamp,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('PKCS#12 chain delivers the intermediate certificate',
    TestCertificateChainDelivered,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('server input flow accepts bounded prefixes and counts consumption',
    TestInputFlowPrefixAdmissionAndCounters,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('peer close_notify reports peer-closed and poisons the connection',
    TestPeerCloseNotifyReportsPeerClosed,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('pending ciphertext pointer stays stable across protocol calls',
    TestPendingCiphertextPointerIsStable,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('caller PKCS#12 bytes are copied before synchronous parsing',
    TestPKCS12BytesArePrimaryInput,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('identity reload retains immutable connection snapshots',
    TestReloadRetainsSnapshotsAndFailedReloadKeepsActive,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('memory-BIO handshake exposes want states and reuses context',
    TestHandshakeTransitionsAndContextReuse,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('plaintext roundtrip retains partial ciphertext',
    TestPlaintextRoundtripAndPartialCiphertextConsumption,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('fatal shutdown poisons before retaining alert output',
    TestFatalShutdownPoisonsBeforeOutput,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('graceful close emits close_notify',
    TestGracefulCloseProducesCloseNotify,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('TLS 1.2 renegotiation is refused',
    TestRenegotiationIsRefused,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('stale OpenSSL error queue is cleared before server operations',
    TestStaleErrorQueueIsCleared,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('SSL_ERROR_SYSCALL poisons the connection',
    TestSyscallErrorPoisonsConnection,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('TLS floor rejects TLS 1.1',
    TestTLSFloorRejectsTLS11,
    OPENSSL_CLIENT_SKIP_REASON);
  Skip('SSL_write WANT retry retains the original plaintext',
    TestWriteWantRetryRetainsPlaintext,
    OPENSSL_CLIENT_SKIP_REASON);
  {$ENDIF}

  { Cases that need the raw in-memory SChannel loopback client. }
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  ServerTest('SChannel handshake round-trips plaintext and reuses the context',
    TestSChannelHandshakeRoundtripAndContextReuse);
  ServerTest('SChannel PKCS#12 chain delivers the intermediate certificate',
    TestSChannelCertificateChainDelivered);
  ServerTest('SChannel input flow accepts bounded prefixes and counts consumption',
    TestSChannelInputFlowPrefixAdmissionAndCounters);
  ServerTest('SChannel pending ciphertext pointer survives partial consumption',
    TestSChannelPendingCiphertextPointerAndPartialConsumption);
  ServerTest('SChannel write WANT retry retains the original plaintext',
    TestSChannelWriteWantRetryRetainsPlaintext);
  ServerTest('SChannel graceful close emits close_notify',
    TestSChannelGracefulCloseProducesCloseNotify);
  ServerTest('SChannel peer close_notify reports peer-closed',
    TestSChannelPeerCloseNotifyReportsPeerClosed);
  ServerTest('SChannel protocol ceiling follows operating-system capability',
    TestSChannelProtocolCeilingFollowsOperatingSystem);
  ServerTest('SChannel identities import into isolated key containers',
    TestSChannelIdentityImportsIsolatedKeyContainers);
  ServerTest('SChannel reload retains the previous key container',
    TestSChannelReloadRetainsPreviousKeyContainer);
  {$ELSE}
  Skip('SChannel handshake round-trips plaintext and reuses the context',
    TestSChannelHandshakeRoundtripAndContextReuse,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel PKCS#12 chain delivers the intermediate certificate',
    TestSChannelCertificateChainDelivered,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel input flow accepts bounded prefixes and counts consumption',
    TestSChannelInputFlowPrefixAdmissionAndCounters,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel pending ciphertext pointer survives partial consumption',
    TestSChannelPendingCiphertextPointerAndPartialConsumption,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel write WANT retry retains the original plaintext',
    TestSChannelWriteWantRetryRetainsPlaintext,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel graceful close emits close_notify',
    TestSChannelGracefulCloseProducesCloseNotify,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel peer close_notify reports peer-closed',
    TestSChannelPeerCloseNotifyReportsPeerClosed,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel protocol ceiling follows operating-system capability',
    TestSChannelProtocolCeilingFollowsOperatingSystem,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel identities import into isolated key containers',
    TestSChannelIdentityImportsIsolatedKeyContainers,
    SCHANNEL_CLIENT_SKIP_REASON);
  Skip('SChannel reload retains the previous key container',
    TestSChannelReloadRetainsPreviousKeyContainer,
    SCHANNEL_CLIENT_SKIP_REASON);
  {$ENDIF}
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TTransportSecurityServerTests.Create(
    'TransportSecurity: TLS server accept'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
