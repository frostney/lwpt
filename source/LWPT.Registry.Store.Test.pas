program LWPT.Registry.Store.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  {$IFDEF MSWINDOWS}
  Process,
  Windows,
  {$ENDIF}
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}

  LWPT.Core,
  LWPT.ProducerLease,
  LWPT.Registry.Filesystem,
  LWPT.Registry.Server,
  LWPT.Registry.Server.NetworkFramework,
  LWPT.Registry.Store,
  TransportSecurity,
  TestingPascalLibrary,
  Tests.Scratch;

const
  INITIAL_TIME = '2026-08-23T10:00:00Z';
  SECOND_TIME = '2026-08-23T11:00:00Z';

type
  TReaderThread = class(TThread)
  private
    FStore: TLWPTRegistryStore;
    FFailure: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AStore: TLWPTRegistryStore);
    property Failure: string read FFailure;
  end;

  TPublisherThread = class(TThread)
  private
    FStore: TLWPTRegistryStore;
    FFailure: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AStore: TLWPTRegistryStore);
    property Failure: string read FFailure;
  end;

  TRecoveryThread = class(TThread)
  private
    FFailure: string;
    FRoot: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARoot: string);
    property Failure: string read FFailure;
  end;

procedure SetFailurePoint(const AValue: string);
begin
  SetRegistryFailurePointForTesting(AValue);
end;

procedure ReplaceFileWithSameLength(const APath: string;
  const AByte: Byte);
var
  Buffer: TBytes;
  Existing, Replacement: TFileStream;
  ReplacementPath: string;
begin
  Existing := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if Existing.Size > MaxInt then
      raise Exception.Create('test replacement exceeds addressable memory');
    SetLength(Buffer, Integer(Existing.Size));
  finally
    Existing.Free;
  end;
  if Length(Buffer) > 0 then FillChar(Buffer[0], Length(Buffer), AByte);
  ReplacementPath := APath + '.same-length-replacement';
  Replacement := TFileStream.Create(ReplacementPath, fmCreate);
  try
    if Length(Buffer) > 0 then
      Replacement.WriteBuffer(Buffer[0], Length(Buffer));
  finally
    Replacement.Free;
  end;
  if not AtomicReplaceFile(ReplacementPath, APath) then
    raise Exception.Create('could not install same-length test replacement');
end;

procedure ReplaceFileWithSize(const APath: string; const ASize: Int64);
var
  Replacement: TFileStream;
  ReplacementPath: string;
begin
  ReplacementPath := APath + '.sized-replacement';
  Replacement := TFileStream.Create(ReplacementPath, fmCreate);
  try
    Replacement.Size := ASize;
  finally
    Replacement.Free;
  end;
  if not AtomicReplaceFile(ReplacementPath, APath) then
    raise Exception.Create('could not install sized test replacement');
end;

{$IFDEF MSWINDOWS}
const
  FSCTL_SET_SPARSE_LWPT = $000900C4;

procedure MarkTestFileSparse(AStream: TFileStream);
var
  ErrorCode, Returned: DWORD;
begin
  if Windows.DeviceIoControl(AStream.Handle, FSCTL_SET_SPARSE_LWPT, nil, 0,
    nil, 0, Returned, nil) then Exit;
  ErrorCode := Windows.GetLastError;
  raise Exception.CreateFmt('failed to mark oversized fixture sparse (%d)',
    [ErrorCode]);
end;

function TryCreateWindowsJunction(const ALinkDirectory,
  ALinkTarget: string): Boolean;
var
  CommandInterpreter: string;
  ProcessInstance: TProcess;
begin
  Result := False;
  CommandInterpreter := SysUtils.GetEnvironmentVariable('COMSPEC');
  if CommandInterpreter = '' then CommandInterpreter := 'cmd.exe';
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := CommandInterpreter;
    ProcessInstance.Parameters.Add('/C');
    ProcessInstance.Parameters.Add('mklink /J "'
      + StringReplace(ALinkDirectory, '/', '\', [rfReplaceAll]) + '" "'
      + StringReplace(ALinkTarget, '/', '\', [rfReplaceAll]) + '"');
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
     Windows.ERROR_PATH_NOT_FOUND] then Exit;
  raise Exception.CreateFmt('failed to remove registry junction fixture (%d)',
    [ErrorCode]);
end;
{$ENDIF}

type
  TRegistryStoreContract = class(TTestSuite)
  private
    FScratch: string;
    FResourceProgressCalls: Integer;
    procedure CheckResourceProgress;
    procedure CheckStateProgress;
    function DefaultConfig: TLWPTRegistryConfig;
    function IndexPath(const AName: string): string;
    function InitializeStore: TLWPTRegistryStore;
    function PublishExample(AStore: TLWPTRegistryStore;
      const AByte: Byte): TLWPTRegistryState;
  protected
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestDefaultIdentityIsDeterministic;
    procedure TestDefaultIdentitySurvivesHTTPSReconfiguration;
    procedure TestExplicitIdentitySurvivesReconfiguration;
    procedure TestPlainHTTPRejectsRemoteBinding;
    procedure TestInvalidConfigurationLeavesFreshRootUncommitted;
    procedure TestCommittedInitializationMarkerIsReconciled;
    procedure TestInitialCheckpointVerifiesAfterRestart;
    procedure TestPublicationIsImmutableAndIdempotent;
    procedure TestVersionIndexRetainsEveryPublishedVersion;
    procedure TestReservedPackageNameUsesPortableIndexKey;
    procedure TestIncompleteInitializationIsRecovered;
    procedure TestOversizedInitializationMarkerIsRejected;
    procedure TestPlainResourceSendChecksDeadlineAfterShortWrites;
    procedure TestCallerOwnedRootIsPreserved;
    procedure TestInitializationUsesAnOperatingSystemLease;
    procedure TestRecoveryClearsIncompleteStaging;
    procedure TestCheckpointCrashDoesNotActivatePublication;
    procedure TestActivationCrashRebuildsDerivedIndex;
    procedure TestCheckpointRenewsWithoutNewSequence;
    procedure TestRegistryPathsRejectLinks;
    procedure TestCanonicalURLValidation;
    procedure TestConfiguredEncodedBasePathRoutes;
    procedure TestUnsupportedListenerFamilyFailsDuringInitialization;
    procedure TestSigningSeedIsPrivateFromCreation;
    procedure TestServerRejectsCorruptContentAddressedBytes;
    procedure TestLargeResourceUsesStreamedDescriptor;
    procedure TestOversizedResourceIsRejectedBeforeHashing;
    procedure TestResourceOpenRejectsUnsafeFilesystemKinds;
    procedure TestNetworkFrameworkBlockABI;
    procedure TestNetworkFrameworkTeardownOrdering;
    procedure TestNetworkFrameworkCleanupFailureSemantics;
    procedure TestDarwinTLSTransportSelection;
    procedure TestDarwinStructuredOperatingSystemVersion;
    procedure TestDarwinListenerCapabilitySelection;
    procedure TestServerErrorsConformToWireContract;
    procedure TestRenewalErrorDoesNotDiscloseStorePath;
    procedure TestServerDiscoveryIsTruthful;
    procedure TestCheckpointResponsesRequireRevalidation;
    procedure TestReadersObserveCompleteStateDuringPublication;
    procedure TestTamperedSignatureHasStableDiagnostic;
  end;

procedure TRegistryStoreContract.TestDarwinTLSTransportSelection;
begin
  Expect<TRegistryDarwinTLSTransport>(
    RegistryDarwinTLSTransportForMajorVersion(15)).ToBe(
      rdttSecureTransport);
  Expect<TRegistryDarwinTLSTransport>(
    RegistryDarwinTLSTransportForMajorVersion(25)).ToBe(
      rdttSecureTransport);
  Expect<TRegistryDarwinTLSTransport>(
    RegistryDarwinTLSTransportForMajorVersion(26)).ToBe(
      rdttNetworkFramework);
  Expect<TRegistryDarwinTLSTransport>(
    RegistryDarwinTLSTransportForMajorVersion(30)).ToBe(
      rdttNetworkFramework);
end;

procedure TRegistryStoreContract.TestDarwinStructuredOperatingSystemVersion;
var
  Diagnostic: string;
  {$IFDEF DARWIN}
  RuntimeMajor: Cardinal;
  {$ENDIF}
begin
  Expect<Cardinal>(RegistryDarwinOperatingSystemVersionMajorForTesting(
    15)).ToBe(15);
  Expect<Cardinal>(RegistryDarwinOperatingSystemVersionMajorForTesting(
    26)).ToBe(26);
  Diagnostic := '';
  try
    RegistryDarwinOperatingSystemVersionMajorForTesting(0);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('tls_configuration:', Diagnostic) = 1).ToBe(True);
  {$IFDEF DARWIN}
  RuntimeMajor := RegistryDarwinOperatingSystemMajorVersion;
  Expect<Boolean>(RuntimeMajor >= 15).ToBe(True);
  if RuntimeMajor >= 26 then
    Expect<TRegistryDarwinTLSTransport>(
      RegistryDarwinTLSTransportForMajorVersion(RuntimeMajor)).ToBe(
        rdttNetworkFramework)
  else
    Expect<TRegistryDarwinTLSTransport>(
      RegistryDarwinTLSTransportForMajorVersion(RuntimeMajor)).ToBe(
        rdttSecureTransport);
  {$ENDIF}
end;

procedure TRegistryStoreContract.TestDarwinListenerCapabilitySelection;
begin
  Expect<Boolean>(RegistryDarwinListenAddressSupportedForMajorVersion(
    'localhost', 15)).ToBe(True);
  Expect<Boolean>(RegistryDarwinListenAddressSupportedForMajorVersion(
    '127.0.0.1', 15)).ToBe(True);
  Expect<Boolean>(RegistryDarwinListenAddressSupportedForMajorVersion(
    '::1', 15)).ToBe(False);
  Expect<Boolean>(RegistryDarwinListenAddressSupportedForMajorVersion(
    'registry.example.com', 15)).ToBe(False);
  Expect<Boolean>(RegistryDarwinListenAddressSupportedForMajorVersion(
    '::1', 26)).ToBe(True);
end;

constructor TReaderThread.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStore := AStore;
end;

constructor TPublisherThread.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStore := AStore;
end;

constructor TRecoveryThread.Create(const ARoot: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRoot := ARoot;
end;

procedure TRecoveryThread.Execute;
var
  Store: TLWPTRegistryStore;
begin
  Store := nil;
  try
    Store := TLWPTRegistryStore.Create(FRoot);
  except
    on E: Exception do FFailure := E.Message;
  end;
  Store.Free;
end;

procedure TRegistryStoreContract.CheckResourceProgress;
begin
  Inc(FResourceProgressCalls);
  if FResourceProgressCalls > 2 then
    raise ELWPTRegistryError.CreateStable('test_resource_cancelled',
      'resource verification cancellation was observed');
end;

procedure TRegistryStoreContract.CheckStateProgress;
begin
  Inc(FResourceProgressCalls);
  if FResourceProgressCalls > 4 then
    raise ELWPTRegistryError.CreateStable('connection_deadline',
      'test deadline expired during committed-state verification');
end;

procedure TPublisherThread.Execute;
var
  Publication: TLWPTRegistryPublication;
begin
  try
    Publication.Name := 'example-lib';
    Publication.Version := '1.0.0';
    Publication.PublishedAt := SECOND_TIME;
    SetLength(Publication.Archive, 1024 * 1024);
    FillChar(Publication.Archive[0], Length(Publication.Archive), $51);
    FStore.Publish(Publication);
  except
    on E: Exception do FFailure := E.Message;
  end;
end;

procedure TReaderThread.Execute;
var
  Index: Integer;
  State: TLWPTRegistryState;
begin
  try
    for Index := 1 to 25 do
    begin
      State := FStore.LoadCurrentState;
      FStore.LoadResource('snapshots/sha256/'
        + Copy(State.SnapshotHash, Length('sha256:') + 1, MaxInt)
        + '.toml');
      FStore.LoadResource(State.CheckpointPath);
      FStore.LoadResource(State.SignaturePath);
    end;
  except
    on E: Exception do FFailure := E.Message;
  end;
end;

function TRegistryStoreContract.DefaultConfig: TLWPTRegistryConfig;
begin
  Result := RegistryConfiguration('', REGISTRY_DEFAULT_BASE_URL,
    REGISTRY_DEFAULT_LISTEN_ADDRESS, REGISTRY_DEFAULT_PORT, '', '');
end;

function TRegistryStoreContract.IndexPath(const AName: string): string;
begin
  Result := FScratch + '/indexes/sha256/'
    + SHA256Hex(TEncoding.UTF8.GetBytes(AName)) + '.toml';
end;

function TRegistryStoreContract.InitializeStore: TLWPTRegistryStore;
begin
  Result := TLWPTRegistryStore.Initialize(FScratch, DefaultConfig,
    INITIAL_TIME);
end;

function TRegistryStoreContract.PublishExample(AStore: TLWPTRegistryStore;
  const AByte: Byte): TLWPTRegistryState;
var
  Publication: TLWPTRegistryPublication;
begin
  Publication.Name := 'example-lib';
  Publication.Version := '1.0.0';
  Publication.PublishedAt := SECOND_TIME;
  SetLength(Publication.Archive, 1024 * 1024);
  FillChar(Publication.Archive[0], Length(Publication.Archive), AByte);
  AStore.Publish(Publication);
  Result := AStore.LoadCurrentState;
end;

procedure TRegistryStoreContract.BeforeEach;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
  FScratch := CreateScratchRoot('registry-store');
end;

procedure TRegistryStoreContract.AfterAll;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
end;

procedure TRegistryStoreContract.TestDefaultIdentityIsDeterministic;
var
  FirstState: TLWPTRegistryState;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    Expect<string>(Store.Config.Identity).ToBe(REGISTRY_DEFAULT_BASE_URL);
    FirstState := Store.LoadCurrentState;
    Expect<Int64>(FirstState.Sequence).ToBe(1);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestDefaultIdentitySurvivesHTTPSReconfiguration;
var
  Config: TLWPTRegistryConfig;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  Store.Free;
  Config := RegistryConfiguration('', 'https://moved.example', 'localhost',
    8443, FScratch + '/identity.p12', 'REGISTRY_PASSWORD');
  Store := TLWPTRegistryStore.Initialize(FScratch, Config, SECOND_TIME);
  try
    Expect<string>(Store.Config.Identity).ToBe(REGISTRY_DEFAULT_BASE_URL);
    Expect<string>(Store.Config.BaseURL).ToBe('https://moved.example');
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestExplicitIdentitySurvivesReconfiguration;
var
  Config: TLWPTRegistryConfig;
  Store: TLWPTRegistryStore;
begin
  Config := RegistryConfiguration('https://identity.example',
    'https://origin.example', '0.0.0.0', 8443, 'identity.p12',
    'REGISTRY_PASSWORD');
  Store := TLWPTRegistryStore.Initialize(FScratch, Config, INITIAL_TIME);
  Store.Free;
  Config.Identity := '';
  Config.BaseURL := 'https://moved.example';
  Config.Port := 9443;
  Store := TLWPTRegistryStore.Initialize(FScratch, Config, SECOND_TIME);
  try
    Expect<string>(Store.Config.Identity).ToBe('https://identity.example');
    Expect<string>(Store.Config.BaseURL).ToBe('https://moved.example');
    Expect<Integer>(Store.Config.Port).ToBe(9443);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestPlainHTTPRejectsRemoteBinding;
var
  Config: TLWPTRegistryConfig;
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  Config := RegistryConfiguration('', REGISTRY_DEFAULT_BASE_URL,
    '0.0.0.0', REGISTRY_DEFAULT_PORT, '', '');
  Diagnostic := '';
  Store := nil;
  try
    Store := TLWPTRegistryStore.Initialize(FScratch, Config, INITIAL_TIME);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('insecure_transport:', Diagnostic) = 1).ToBe(True);
end;

procedure TRegistryStoreContract.TestInvalidConfigurationLeavesFreshRootUncommitted;
var
  Config: TLWPTRegistryConfig;
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  Config := RegistryConfiguration('', 'https://localhost:9417',
    REGISTRY_DEFAULT_LISTEN_ADDRESS, REGISTRY_DEFAULT_PORT,
    ExpandFileName(FScratch + '/certificate.p12'), 'TLS_PASSWORD' + #1);
  Diagnostic := '';
  Store := nil;
  try
    Store := TLWPTRegistryStore.Initialize(FScratch, Config, INITIAL_TIME);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('invalid_configuration:', Diagnostic) = 1).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/registry.toml')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/keys/root.seed')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/keys')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/snapshots')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/checkpoints')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/state')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/.initializing')).ToBe(False);
  Store := TLWPTRegistryStore.Initialize(FScratch, DefaultConfig,
    INITIAL_TIME);
  Store.Free;
  Store := TLWPTRegistryStore.Create(FScratch);
  try
    Expect<string>(Store.Config.Identity).ToBe(REGISTRY_DEFAULT_BASE_URL);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestCommittedInitializationMarkerIsReconciled;
var
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  SetFailurePoint('initialization-activation');
  Diagnostic := '';
  Store := nil;
  try
    Store := TLWPTRegistryStore.Initialize(FScratch, DefaultConfig,
      INITIAL_TIME);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  SetFailurePoint('');
  Expect<Boolean>(Pos('injected_registry_failure:', Diagnostic) = 1)
    .ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/registry.toml')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/.initializing')).ToBe(True);
  Store := TLWPTRegistryStore.Initialize(FScratch, DefaultConfig,
    SECOND_TIME);
  try
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
    Expect<Boolean>(FileExists(FScratch + '/.initializing')).ToBe(False);
  finally
    Store.Free;
    SetFailurePoint('');
  end;
end;

procedure TRegistryStoreContract.TestInitialCheckpointVerifiesAfterRestart;
var
  FirstKey, SecondKey: string;
  Search: TSearchRec;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  Store.Free;
  Expect<Integer>(FindFirst(FScratch + '/keys/ed25519-*.toml', faAnyFile,
    Search)).ToBe(0);
  FirstKey := Search.Name;
  SysUtils.FindClose(Search);
  Store := TLWPTRegistryStore.Create(FScratch);
  Store.Free;
  Expect<Integer>(FindFirst(FScratch + '/keys/ed25519-*.toml', faAnyFile,
    Search)).ToBe(0);
  SecondKey := Search.Name;
  SysUtils.FindClose(Search);
  Expect<string>(SecondKey).ToBe(FirstKey);
end;

procedure TRegistryStoreContract.TestVersionIndexRetainsEveryPublishedVersion;
var
  IndexText: string;
  Publication: TLWPTRegistryPublication;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    PublishExample(Store, $41);
    Publication.Name := 'example-lib';
    Publication.Version := '2.0.0';
    Publication.PublishedAt := '2026-08-23T12:00:00Z';
    SetLength(Publication.Archive, 128);
    FillChar(Publication.Archive[0], Length(Publication.Archive), $42);
    Store.Publish(Publication);
    IndexText := ReadBinaryFile(IndexPath('example-lib'));
    Expect<Boolean>(Pos('1.0.0=sha256:', IndexText) > 0).ToBe(True);
    Expect<Boolean>(Pos('2.0.0=sha256:', IndexText) > 0).ToBe(True);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(3);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestReservedPackageNameUsesPortableIndexKey;
var
  IndexText: string;
  Publication: TLWPTRegistryPublication;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  Publication.Name := 'con';
  Publication.Version := '1.0.0';
  Publication.PublishedAt := SECOND_TIME;
  SetLength(Publication.Archive, 32);
  FillChar(Publication.Archive[0], Length(Publication.Archive), $43);
  try
    Store.Publish(Publication);
    Expect<Boolean>(FileExists(IndexPath(Publication.Name))).ToBe(True);
    Expect<Boolean>(FileExists(FScratch + '/indexes/con.toml')).ToBe(False);
  finally
    Store.Free;
  end;
  Store := TLWPTRegistryStore.Create(FScratch);
  try
    IndexText := ReadBinaryFile(IndexPath(Publication.Name));
    Expect<Boolean>(Pos('name = "con"', IndexText) > 0).ToBe(True);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(2);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestIncompleteInitializationIsRecovered;
var
  Store: TLWPTRegistryStore;
begin
  AtomicWriteBytes(FScratch + '/.initializing', FScratch + '/tmp',
    TEncoding.UTF8.GetBytes('registry initialization in progress' + #10));
  WriteTextFile(FScratch + '/tmp/uncommitted', 'partial');
  Store := InitializeStore;
  try
    Expect<Boolean>(FileExists(FScratch + '/tmp/uncommitted')).ToBe(False);
    Expect<Boolean>(FileExists(FScratch + '/.initializing')).ToBe(False);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestOversizedInitializationMarkerIsRejected;
var
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  WriteTextFile(FScratch + '/.initializing',
    'registry initialization in progress' + #10);
  ReplaceFileWithSize(FScratch + '/.initializing',
    Int64(MAX_REGISTRY_CONTROL_DOCUMENT_BYTES) + 1);
  Diagnostic := '';
  Store := nil;
  try
    Store := InitializeStore;
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('state_corrupt:', Diagnostic) = 1).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/.initializing')).ToBe(True);
end;

procedure TRegistryStoreContract.
  TestPlainResourceSendChecksDeadlineAfterShortWrites;
var
  Data: array[0..7] of Byte;
  SendCalls: Integer;
  Stream: TMemoryStream;
begin
  FillChar(Data, SizeOf(Data), $5a);
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Data[0], SizeOf(Data));
    Stream.Position := 0;
    SendCalls := RegistrySendResourcePlainForTesting(Stream, 3, 0, 1, 1);
  finally
    Stream.Free;
  end;
  Expect<Integer>(SendCalls).ToBe(3);
end;

procedure TRegistryStoreContract.TestCallerOwnedRootIsPreserved;
var
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  WriteTextFile(FScratch + '/caller-data', 'keep me');
  Diagnostic := '';
  Store := nil;
  try
    Store := InitializeStore;
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('origin_directory_not_empty:', Diagnostic) = 1)
    .ToBe(True);
  Expect<string>(Trim(ReadBinaryFile(FScratch + '/caller-data'))).ToBe('keep me');
end;

procedure TRegistryStoreContract.TestInitializationUsesAnOperatingSystemLease;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  Diagnostic: string;
  Lease: TLWPTProducerLease;
  Store: TLWPTRegistryStore;
begin
  Coordinator := TLWPTProducerLeaseCoordinator.Create(
    IncludeTrailingPathDelimiter(GetTempDir) + PROGRAM_NAME
    + '-registry-initialization-leases');
  Lease := Coordinator.TryAcquire(ExpandFileName(FScratch), 'test holder');
  try
    Expect<Boolean>(Assigned(Lease)).ToBe(True);
    Diagnostic := '';
    Store := nil;
    try
      Store := InitializeStore;
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    Store.Free;
    Expect<Boolean>(Pos('initialization_locked:', Diagnostic) = 1).ToBe(True);
  finally
    Lease.Free;
    Coordinator.Free;
  end;
  Store := InitializeStore;
  Store.Free;
end;

procedure TRegistryStoreContract.TestCheckpointCrashDoesNotActivatePublication;
var
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    SetFailurePoint('checkpoint');
    Diagnostic := '';
    try
      PublishExample(Store, $61);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    SetFailurePoint('');
    Expect<Boolean>(Pos('injected_registry_failure:', Diagnostic) = 1)
      .ToBe(True);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
  finally
    SetFailurePoint('');
    Store.Free;
  end;
  Store := TLWPTRegistryStore.Create(FScratch);
  try
    Expect<Boolean>(FileExists(FScratch + '/checkpoints/2.toml')).ToBe(False);
    Expect<Int64>(PublishExample(Store, $61).Sequence).ToBe(2);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestActivationCrashRebuildsDerivedIndex;
var
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    SetFailurePoint('activation');
    Diagnostic := '';
    try
      PublishExample(Store, $62);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    SetFailurePoint('');
    Expect<Boolean>(Pos('injected_registry_failure:', Diagnostic) = 1)
      .ToBe(True);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(2);
    Expect<Boolean>(FileExists(IndexPath('example-lib')))
      .ToBe(False);
  finally
    SetFailurePoint('');
    Store.Free;
  end;
  Store := TLWPTRegistryStore.Create(FScratch);
  try
    Expect<Boolean>(FileExists(IndexPath('example-lib')))
      .ToBe(True);
    Expect<Int64>(PublishExample(Store, $62).Sequence).ToBe(2);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestCheckpointRenewsWithoutNewSequence;
var
  Historical, Renewed: string;
  State: TLWPTRegistryState;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    Historical := ReadBinaryFile(FScratch + '/checkpoints/1.toml');
    Store.EnsureFreshCheckpoint('2026-08-29T11:00:00Z');
    State := Store.LoadCurrentState;
    Expect<Int64>(State.Sequence).ToBe(1);
    Expect<Boolean>(Pos('checkpoints/renewals/sha256/',
      State.CheckpointPath) = 1).ToBe(True);
    Renewed := ReadBinaryFile(FScratch + '/' + State.CheckpointPath);
    Expect<Boolean>(Pos('expires_at = "2026-09-05T11:00:00Z"',
      Renewed) > 0).ToBe(True);
    Expect<string>(ReadBinaryFile(FScratch + '/checkpoints/1.toml'))
      .ToBe(Historical);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestRegistryPathsRejectLinks;
{$IFDEF UNIX}
var
  Diagnostic, RealRoot, SymlinkRoot: string;
  Store: TLWPTRegistryStore;
{$ENDIF}
begin
  {$IFDEF UNIX}
  RealRoot := FScratch + '/real';
  SymlinkRoot := FScratch + '/linked';
  ForceDirectories(RealRoot);
  if FpSymlink(PChar(RealRoot), PChar(SymlinkRoot)) <> 0 then RaiseLastOSError;
  Diagnostic := '';
  Store := nil;
  try
    Store := TLWPTRegistryStore.Initialize(SymlinkRoot, DefaultConfig,
      INITIAL_TIME);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('registry_path_link:', Diagnostic) = 1).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TRegistryStoreContract.TestCanonicalURLValidation;
var
  Diagnostic, Host: string;
begin
  Expect<string>(CanonicalRegistryURL(
    'https://[2001:0db8:0:0:0:0:0:1]:443/a/../b', False))
    .ToBe('https://[2001:db8::1]/b');
  Expect<string>(CanonicalRegistryURL(
    'https://127.000.000.001:443/a', False))
    .ToBe('https://127.0.0.1/a');
  Expect<string>(CanonicalRegistryURL(
    'https://[::ffff:192.0.2.128]/a', False))
    .ToBe('https://[::ffff:c000:280]/a');
  Expect<string>(CanonicalRegistryURL(
    'https://example.com/a//b/%2f/c', False))
    .ToBe('https://example.com/a//b/%2F/c');
  Expect<string>(CanonicalRegistryURL(
    'https://example.com/a!$&''()*+,;=:@/b', False))
    .ToBe('https://example.com/a!$&''()*+,;=:@/b');
  Expect<string>(CanonicalRegistryURL('https://example.com/a/', False))
    .ToBe('https://example.com/a');
  Expect<string>(CanonicalRegistryURL('https://example.com/', False))
    .ToBe('https://example.com');
  Host := StringOfChar('a', 63) + '.' + StringOfChar('b', 63) + '.'
    + StringOfChar('c', 63) + '.' + StringOfChar('d', 61);
  Expect<string>(CanonicalRegistryURL('https://' + Host, False))
    .ToBe('https://' + Host);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://' + Host + 'd', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://example.com/{package}', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://example.com/' + #$C3 + #$A9, False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://example.com/"bad"', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://example.com:+443/a', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://:443/a', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://example.com:/a', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://[::1]:/a', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://[1:2:3:4:5:6:7:8:]/a', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
end;

procedure TRegistryStoreContract.TestConfiguredEncodedBasePathRoutes;
var
  Config: TLWPTRegistryConfig;
  Response: TLWPTRegistryHTTPResponse;
  Store: TLWPTRegistryStore;
begin
  Config := DefaultConfig;
  Config.BaseURL := 'http://localhost:8080/registry%2Fstable//instance';
  Store := TLWPTRegistryStore.Initialize(FScratch, Config, INITIAL_TIME);
  try
    Response := RegistryHTTPResponse(Store, 'GET',
      '/registry%2Fstable//instance/v1/capabilities');
    Expect<Integer>(Response.Status).ToBe(200);
    Response := RegistryHTTPResponse(Store, 'GET',
      '/registry/stable//instance/v1/capabilities');
    Expect<Integer>(Response.Status).ToBe(404);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestUnsupportedListenerFamilyFailsDuringInitialization;
var
  Config: TLWPTRegistryConfig;
  Diagnostic: string;
  Store: TLWPTRegistryStore;
begin
  {$IFDEF DARWIN}
  SetRegistryDarwinOperatingSystemMajorVersionForTesting(15);
  {$ENDIF}
  try
  Config := RegistryConfiguration('', 'https://[::1]:9417', '::1', 9417,
    ExpandFileName(FScratch + '/certificate.p12'), 'TLS_PASSWORD');
  Diagnostic := '';
  Store := nil;
  try
    Store := TLWPTRegistryStore.Initialize(FScratch, Config, INITIAL_TIME);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('invalid_listen_address:', Diagnostic) = 1).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/registry.toml')).ToBe(False);
  Config := RegistryConfiguration('', 'https://10.0.0.1:9417',
    '010.000.000.001', 9417,
    ExpandFileName(FScratch + '/certificate.p12'), 'TLS_PASSWORD');
  Diagnostic := '';
  Store := nil;
  try
    Store := TLWPTRegistryStore.Initialize(FScratch, Config, INITIAL_TIME);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Store.Free;
  Expect<Boolean>(Pos('invalid_listen_address:', Diagnostic) = 1).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/registry.toml')).ToBe(False);
  finally
    {$IFDEF DARWIN}
    SetRegistryDarwinOperatingSystemMajorVersionForTesting(0);
    {$ENDIF}
  end;
end;

procedure TRegistryStoreContract.TestSigningSeedIsPrivateFromCreation;
{$IFDEF UNIX}
var
  Info: Stat;
  Store: TLWPTRegistryStore;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Store := InitializeStore;
  Store.Free;
  if FpStat(FScratch + '/keys/root.seed', Info) <> 0 then RaiseLastOSError;
  Expect<Integer>(Info.st_mode and &777).ToBe(&600);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TRegistryStoreContract.TestServerRejectsCorruptContentAddressedBytes;
var
  Diagnostic: string;
  HashDiagnostic: string;
  {$IFDEF UNIX}
  LinkTarget: string;
  {$ENDIF}
  ObjectName: string;
  Response: TLWPTRegistryHTTPResponse;
  ResourceStream: TStream;
  Search: TSearchRec;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    PublishExample(Store, $71);
    Expect<Integer>(FindFirst(FScratch + '/objects/sha256/*', faAnyFile,
      Search)).ToBe(0);
    while (Search.Name = '.') or (Search.Name = '..')
      or ((Search.Attr and faDirectory) <> 0) do
      if FindNext(Search) <> 0 then
        raise Exception.Create('published object was not found');
    ObjectName := Search.Name;
    SysUtils.FindClose(Search);
    WriteTextFile(FScratch + '/objects/sha256/' + ObjectName, 'tampered');
    Response := RegistryHTTPResponse(Store, 'GET',
      '/v1/objects/sha256/' + ObjectName);
    Expect<Integer>(Response.Status).ToBe(200);
    Diagnostic := '';
    ResourceStream := nil;
    try
      ResourceStream := OpenRegistryHTTPResource(Response);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    ResourceStream.Free;
    Expect<Boolean>(Pos('resource_hash_mismatch:', Diagnostic) = 1)
      .ToBe(True);
    HashDiagnostic := Diagnostic;
    {$IFDEF UNIX}
    LinkTarget := Response.ResourcePath + '.target';
    WriteTextFile(LinkTarget, 'tampered');
    Expect<Boolean>(DeleteFile(Response.ResourcePath)).ToBe(True);
    Expect<Integer>(FpSymlink(PChar(LinkTarget),
      PChar(Response.ResourcePath))).ToBe(0);
    Diagnostic := '';
    ResourceStream := nil;
    try
      ResourceStream := OpenRegistryHTTPResource(Response);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    ResourceStream.Free;
    Expect<Boolean>(Pos('resource_changed:', Diagnostic) = 1).ToBe(True);
    {$ENDIF}
    Response := RegistryResourceFailureResponse(HashDiagnostic);
    Expect<Integer>(Response.Status).ToBe(500);
    Expect<Boolean>(Pos('code = "resource_hash_mismatch"',
      TEncoding.UTF8.GetString(Response.Body)) > 0).ToBe(True);
    Expect<Boolean>(Pos(FScratch,
      TEncoding.UTF8.GetString(Response.Body)) = 0).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestLargeResourceUsesStreamedDescriptor;
var
  ObjectName: string;
  Publication: TLWPTRegistryPublication;
  Response: TLWPTRegistryHTTPResponse;
  Diagnostic: string;
  ReplacementPath: string;
  ResourceStream: TStream;
  Search: TSearchRec;
  Store: TLWPTRegistryStore;
  Wire: TBytes;
begin
  Store := InitializeStore;
  try
    Publication.Name := 'large-lib';
    Publication.Version := '1.0.0';
    Publication.PublishedAt := SECOND_TIME;
    SetLength(Publication.Archive, 8 * 1024 * 1024);
    FillChar(Publication.Archive[0], Length(Publication.Archive), $5A);
    Store.Publish(Publication);
    Expect<Integer>(FindFirst(FScratch + '/objects/sha256/*', faAnyFile,
      Search)).ToBe(0);
    while (Search.Name = '.') or (Search.Name = '..')
      or ((Search.Attr and faDirectory) <> 0) do
      if FindNext(Search) <> 0 then
        raise Exception.Create('published object was not found');
    ObjectName := Search.Name;
    SysUtils.FindClose(Search);
    Response := RegistryHTTPResponse(Store, 'GET',
      '/v1/objects/sha256/' + ObjectName);
    Expect<Integer>(Response.Status).ToBe(200);
    Expect<Integer>(Length(Response.Body)).ToBe(0);
    Expect<Int64>(Response.ResourceLength).ToBe(8 * 1024 * 1024);
    Expect<Boolean>(Response.ResourcePath <> '').ToBe(True);
    Wire := RegistryHTTPWireResponse(Response, True);
    Expect<Boolean>(Length(Wire) < 1024).ToBe(True);
    Expect<Boolean>(Pos('Content-Length: 8388608',
      TEncoding.UTF8.GetString(Wire)) > 0).ToBe(True);
    FResourceProgressCalls := 0;
    Diagnostic := '';
    ResourceStream := nil;
    try
      ResourceStream := OpenRegistryHTTPResource(Response,
        CheckResourceProgress);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    ResourceStream.Free;
    Expect<Boolean>(Pos('test_resource_cancelled:', Diagnostic) = 1)
      .ToBe(True);
    ResourceStream := OpenRegistryHTTPResource(Response);
    try
      ReplacementPath := Response.ResourcePath + '.replacement';
      WriteTextFile(ReplacementPath, 'replacement');
      Expect<Boolean>(AtomicReplaceFile(ReplacementPath,
        Response.ResourcePath)).ToBe(True);
      Expect<string>('sha256:' + SHA256Stream(ResourceStream))
        .ToBe(Response.ResourceDigest);
    finally
      ResourceStream.Free;
    end;
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestOversizedResourceIsRejectedBeforeHashing;
const
  OBJECT_NAME =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
var
  ObjectPath: string;
  Response: TLWPTRegistryHTTPResponse;
  Store: TLWPTRegistryStore;
  Stream: TFileStream;
begin
  Store := InitializeStore;
  try
    ForceDirectories(FScratch + '/objects/sha256');
    ObjectPath := FScratch + '/objects/sha256/' + OBJECT_NAME;
    Stream := TFileStream.Create(ObjectPath, fmCreate);
    try
      {$IFDEF MSWINDOWS}
      MarkTestFileSparse(Stream);
      {$ENDIF}
      Stream.Size := Int64(MAX_REGISTRY_RESOURCE_BYTES) + 1;
    finally
      Stream.Free;
    end;
    Response := RegistryHTTPResponse(Store, 'GET',
      '/v1/objects/sha256/' + OBJECT_NAME);
    Expect<Integer>(Response.Status).ToBe(500);
    Expect<Boolean>(Pos('resource_too_large',
      TEncoding.UTF8.GetString(Response.Body)) > 0).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestResourceOpenRejectsUnsafeFilesystemKinds;
var
  Diagnostic, ObjectName, ParentPath, RealParentPath, ResourcePath: string;
  Elapsed, Started: QWord;
  Response, RoutedResponse: TLWPTRegistryHTTPResponse;
  ResourceStream: TStream;
  Search: TSearchRec;
  Store: TLWPTRegistryStore;
  {$IFDEF UNIX}
  StatePath: string;
  State: TLWPTRegistryState;
  {$ENDIF}
begin
  Store := InitializeStore;
  try
    PublishExample(Store, $73);
    Expect<Integer>(FindFirst(FScratch + '/objects/sha256/*', faAnyFile,
      Search)).ToBe(0);
    while (Search.Name = '.') or (Search.Name = '..')
      or ((Search.Attr and faDirectory) <> 0) do
      if FindNext(Search) <> 0 then
        raise Exception.Create('published object was not found');
    ObjectName := Search.Name;
    SysUtils.FindClose(Search);
    Response := RegistryHTTPResponse(Store, 'GET',
      '/v1/objects/sha256/' + ObjectName);
    Expect<Integer>(Response.Status).ToBe(200);
    ResourcePath := Response.ResourcePath;
    ParentPath := FScratch + '/objects';
    RealParentPath := FScratch + '/objects-real';
    Expect<Boolean>(RenameFile(ParentPath, RealParentPath)).ToBe(True);
    {$IFDEF UNIX}
    Expect<Integer>(FpSymlink(PChar(RealParentPath), PChar(ParentPath)))
      .ToBe(0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    if not TryCreateWindowsJunction(ParentPath, RealParentPath) then
    begin
      Expect<Boolean>(RenameFile(RealParentPath, ParentPath)).ToBe(True);
      raise Exception.Create('registry parent junction creation failed');
    end;
    {$ENDIF}
    try
      Started := GetTickCount64;
      RoutedResponse := RegistryHTTPResponse(Store, 'GET',
        '/v1/objects/sha256/' + ObjectName);
      Elapsed := GetTickCount64 - Started;
      Expect<Integer>(RoutedResponse.Status).ToBe(404);
      Expect<Boolean>(Elapsed < 1000).ToBe(True);
      Diagnostic := '';
      ResourceStream := nil;
      try
        ResourceStream := OpenRegistryHTTPResource(Response);
      except
        on E: Exception do Diagnostic := E.Message;
      end;
      ResourceStream.Free;
      Expect<Boolean>(Pos('resource_changed:', Diagnostic) = 1).ToBe(True);
    finally
      {$IFDEF UNIX}
      Expect<Boolean>(DeleteFile(ParentPath)).ToBe(True);
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      RemoveWindowsJunctionIfPresent(ParentPath);
      {$ENDIF}
      Expect<Boolean>(RenameFile(RealParentPath, ParentPath)).ToBe(True);
    end;

    {$IFDEF UNIX}
    Expect<Boolean>(DeleteFile(ResourcePath)).ToBe(True);
    Expect<Integer>(FpMkFifo(PChar(ResourcePath), &600)).ToBe(0);
    Started := GetTickCount64;
    RoutedResponse := RegistryHTTPResponse(Store, 'GET',
      '/v1/objects/sha256/' + ObjectName);
    Elapsed := GetTickCount64 - Started;
    Expect<Integer>(RoutedResponse.Status).ToBe(404);
    Expect<Boolean>(Elapsed < 1000).ToBe(True);
    Diagnostic := '';
    ResourceStream := nil;
    try
      ResourceStream := OpenRegistryHTTPResource(Response);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    ResourceStream.Free;
    Expect<Boolean>(Pos('resource_changed:', Diagnostic) = 1).ToBe(True);
    Expect<Boolean>(DeleteFile(ResourcePath)).ToBe(True);

    StatePath := FScratch + '/state/current.toml';
    Expect<Boolean>(DeleteFile(StatePath)).ToBe(True);
    Expect<Integer>(FpMkFifo(PChar(StatePath), &600)).ToBe(0);
    Diagnostic := '';
    Started := GetTickCount64;
    try
      State := Store.LoadCurrentState;
      if State.Sequence = 0 then Diagnostic := '';
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    Elapsed := GetTickCount64 - Started;
    Expect<Boolean>(Pos('state_missing:', Diagnostic) = 1).ToBe(True);
    Expect<Boolean>(Elapsed < 1000).ToBe(True);
    Expect<Boolean>(DeleteFile(StatePath)).ToBe(True);
    {$ENDIF}
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestServerErrorsConformToWireContract;
var
  Body, ExpectedBody, Wire: string;
  Character: Char;
  RequestID: string;
  RequestIDStart: SizeInt;
  Response: TLWPTRegistryHTTPResponse;
  Store: TLWPTRegistryStore;
begin
  Expect<Integer>(RegistryDeadlineTimeoutForTesting(100, 99)).ToBe(1);
  Expect<Integer>(RegistryDeadlineTimeoutForTesting(100, 100)).ToBe(1);
  Expect<Integer>(RegistryDeadlineTimeoutForTesting(100, 101)).ToBe(1);
  Expect<Integer>(RegistryDeadlineTimeoutForTesting(250, 100)).ToBe(150);
  Expect<Boolean>(RegistryTLSShutdownStateIsTerminalForTesting(
    Ord(tssDone))).ToBe(True);
  Expect<Boolean>(RegistryTLSShutdownStateIsTerminalForTesting(
    Ord(tssError))).ToBe(True);
  Expect<Boolean>(RegistryTLSShutdownStateIsTerminalForTesting(
    Ord(tssPeerClosed))).ToBe(True);
  Expect<Boolean>(RegistryTLSShutdownStateIsTerminalForTesting(
    Ord(tssWantRead))).ToBe(False);
  Expect<Boolean>(RegistryTLSShutdownStateIsTerminalForTesting(
    Ord(tssWantWrite))).ToBe(False);
  ExpectedBody := 'schema = "' + PROGRAM_NAME + '-registry-error-v1"' + #10
    + 'code = "bad\"code"' + #10
    + 'message = "path\\failed\t\u0001"' + #10
    + 'request_id = "request\\\"\u007f"' + #10
    + 'retryable = false' + #10;
  Response := RegistryErrorResponse(400, 'Bad Request', 'bad"code',
    'path\failed' + #9 + #1, 'request\"' + #127);
  Body := TEncoding.UTF8.GetString(Response.Body);
  Expect<string>(Body).ToBe(ExpectedBody);
  Expect<Boolean>((Pos(#1, Body) = 0) and (Pos(#127, Body) = 0)).ToBe(True);
  Wire := TEncoding.UTF8.GetString(RegistryHTTPWireResponse(Response, True));
  Expect<Boolean>(Pos('Content-Length: ' + IntToStr(Length(Response.Body))
    + #13#10, Wire) > 0).ToBe(True);
  Expect<Boolean>(Pos(#13#10#13#10 + ExpectedBody, Wire) > 0).ToBe(True);

  Store := InitializeStore;
  try
    Response := RegistryHTTPResponse(Store, 'POST', '/');
    Body := TEncoding.UTF8.GetString(Response.Body);
    Expect<Integer>(Response.Status).ToBe(405);
    RequestIDStart := Pos('request_id = "', Body);
    Expect<Boolean>(RequestIDStart > 0).ToBe(True);
    Expect<Boolean>(Pos('request_id = ""', Body) = 0).ToBe(True);
    RequestID := Copy(Body, RequestIDStart + Length('request_id = "'), 26);
    Expect<Integer>(Length(RequestID)).ToBe(26);
    for Character in RequestID do
      Expect<Boolean>(Character in ['0'..'9', 'a'..'f']).ToBe(True);
    Expect<Boolean>(Body[RequestIDStart + Length('request_id = "') + 26]
      = '"').ToBe(True);
    Expect<Boolean>(RequestIDStart
      < Pos('retryable = false', Body)).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestNetworkFrameworkTeardownOrdering;
begin
  Expect<Boolean>(NetworkFrameworkTeardownOrderingIsSafeForTesting).ToBe(True);
end;

procedure TRegistryStoreContract.TestNetworkFrameworkBlockABI;
begin
  Expect<Boolean>(NetworkFrameworkBlockABIIsCompleteForTesting).ToBe(True);
end;

procedure TRegistryStoreContract.TestNetworkFrameworkCleanupFailureSemantics;
begin
  Expect<Boolean>(NetworkFrameworkCleanupFailureSemanticsAreSafeForTesting)
    .ToBe(True);
  Expect<Boolean>(NetworkFrameworkRecoveryConcurrentUnlinkIsSafeForTesting)
    .ToBe(True);
end;

procedure TRegistryStoreContract.TestRenewalErrorDoesNotDiscloseStorePath;
var
  Body: string;
  Response: TLWPTRegistryHTTPResponse;
  State: TLWPTRegistryState;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    State := Store.LoadCurrentState;
    SysUtils.DeleteFile(FScratch + '/' + State.CheckpointPath);
    Response := RegistryHTTPResponse(Store, 'GET', '/v1/capabilities');
    Body := TEncoding.UTF8.GetString(Response.Body);
    Expect<Integer>(Response.Status).ToBe(500);
    Expect<Boolean>(Pos('checkpoint_renewal_failed', Body) > 0).ToBe(True);
    Expect<Boolean>(Pos(FScratch, Body) = 0).ToBe(True);
    Expect<Boolean>(Pos('the active checkpoint could not be renewed', Body)
      > 0).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestServerDiscoveryIsTruthful;
var
  Body: string;
  Response: TLWPTRegistryHTTPResponse;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    Response := RegistryHTTPResponse(Store, 'GET', '/v1/capabilities');
    Body := TEncoding.UTF8.GetString(Response.Body);
    Expect<Boolean>(Pos('package-list-v1', Body) = 0).ToBe(True);
    Expect<Boolean>(Pos('publication-v1', Body) = 0).ToBe(True);
    Expect<Boolean>(Pos('rotation-chain-v1', Body) = 0).ToBe(True);
    Expect<Boolean>(Pos('auth_schemes = []', Body) > 0).ToBe(True);
    Response := RegistryHTTPResponse(Store, 'GET',
      '/.well-known/' + PROGRAM_NAME + '-registry');
    Body := TEncoding.UTF8.GetString(Response.Body);
    Expect<Boolean>(Pos('rotations =', Body) = 0).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestCheckpointResponsesRequireRevalidation;
var
  CheckpointResponse, KeyResponse, Response: TLWPTRegistryHTTPResponse;
  Diagnostic, KeyID: string;
  ResourceStream: TStream;
  Search: TSearchRec;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    FResourceProgressCalls := 0;
    Diagnostic := '';
    try
      RegistryHTTPResponse(Store, 'GET', '/v1/capabilities',
        CheckStateProgress);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('connection_deadline:', Diagnostic) = 1)
      .ToBe(True);
    Expect<Boolean>(FResourceProgressCalls > 4).ToBe(True);

    CheckpointResponse := RegistryHTTPResponse(Store, 'GET',
      '/v1/checkpoints/latest.toml');
    Expect<string>(CheckpointResponse.CacheControl)
      .ToBe('no-cache, must-revalidate');
    Expect<Boolean>(CheckpointResponse.ResourceDigest <> '').ToBe(True);
    Response := RegistryHTTPResponse(Store, 'GET', '/v1/checkpoints/1.toml');
    Expect<string>(Response.CacheControl).ToBe('no-cache, must-revalidate');
    Expect<Boolean>(Response.ResourceDigest <> '').ToBe(True);

    Expect<Integer>(FindFirst(FScratch + '/keys/ed25519-*.toml', faAnyFile,
      Search)).ToBe(0);
    KeyID := 'ed25519:' + Copy(Search.Name, Length('ed25519-') + 1,
      Length(Search.Name) - Length('ed25519-') - Length('.toml'));
    SysUtils.FindClose(Search);
    KeyResponse := RegistryHTTPResponse(Store, 'GET', '/v1/keys/' + KeyID
      + '.toml');
    Expect<Integer>(KeyResponse.Status).ToBe(200);
    Expect<Boolean>(KeyResponse.ResourceDigest <> '').ToBe(True);
    ReplaceFileWithSameLength(KeyResponse.ResourcePath, $4B);
    Diagnostic := '';
    ResourceStream := nil;
    try
      ResourceStream := OpenRegistryHTTPResource(KeyResponse);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    ResourceStream.Free;
    Expect<Boolean>(Pos('resource_hash_mismatch:', Diagnostic) = 1)
      .ToBe(True);

    ReplaceFileWithSameLength(CheckpointResponse.ResourcePath, $43);
    Diagnostic := '';
    ResourceStream := nil;
    try
      ResourceStream := OpenRegistryHTTPResource(CheckpointResponse);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    ResourceStream.Free;
    Expect<Boolean>(Pos('resource_hash_mismatch:', Diagnostic) = 1)
      .ToBe(True);

    ReplaceFileWithSize(CheckpointResponse.ResourcePath,
      Int64(MAX_REGISTRY_CONTROL_DOCUMENT_BYTES) + 1);
    Diagnostic := '';
    try
      Store.LoadCurrentState;
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('state_corrupt:', Diagnostic) = 1).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestPublicationIsImmutableAndIdempotent;
var
  Diagnostic: string;
  Publication: TLWPTRegistryPublication;
  State: TLWPTRegistryState;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    State := PublishExample(Store, $41);
    Expect<Int64>(State.Sequence).ToBe(2);
    State := PublishExample(Store, $41);
    Expect<Int64>(State.Sequence).ToBe(2);
    Publication.Name := 'example-lib';
    Publication.Version := '1.0.0';
    Publication.PublishedAt := SECOND_TIME;
    SetLength(Publication.Archive, 1024 * 1024);
    FillChar(Publication.Archive[0], Length(Publication.Archive), $42);
    Diagnostic := '';
    try
      Store.Publish(Publication);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('identity_conflict:', Diagnostic) = 1).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestRecoveryClearsIncompleteStaging;
var
  Recovery: TRecoveryThread;
  ReadyPath, ReleasePath: string;
  State: TLWPTRegistryState;
  StartedAt: QWord;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  Store.Free;
  WriteTextFile(FScratch + '/tmp/incomplete/publication', 'partial');
  Store := TLWPTRegistryStore.Create(FScratch);
  try
    Expect<Boolean>(FileExists(FScratch + '/tmp/incomplete/publication'))
      .ToBe(False);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
  finally
    Store.Free;
  end;
  Store := TLWPTRegistryStore.Create(FScratch);
  Recovery := nil;
  ReadyPath := FScratch + '-recovery-ready';
  ReleasePath := FScratch + '-recovery-release';
  try
    SetRegistryRecoveryBarrierForTesting(ReadyPath, ReleasePath);
    Recovery := TRecoveryThread.Create(FScratch);
    Recovery.Start;
    StartedAt := GetTickCount64;
    while not FileExists(ReadyPath) do
    begin
      if GetTickCount64 - StartedAt >= 5000 then
        raise Exception.Create('recovery did not reach pre-lease barrier');
      Sleep(10);
    end;
    State := PublishExample(Store, $51);
    Expect<Int64>(State.Sequence).ToBe(2);
    WriteTextFile(ReleasePath, 'release');
    Recovery.WaitFor;
    Expect<string>(Recovery.Failure).ToBe('');
    State := Store.LoadCurrentState;
    Expect<Int64>(State.Sequence).ToBe(2);
    Expect<Boolean>(FileExists(FScratch + '/' + State.CheckpointPath))
      .ToBe(True);
  finally
    if not FileExists(ReleasePath) then WriteTextFile(ReleasePath, 'release');
    if Assigned(Recovery) then
    begin
      Recovery.WaitFor;
      Recovery.Free;
    end;
    SetRegistryRecoveryBarrierForTesting('', '');
    SysUtils.DeleteFile(ReadyPath);
    SysUtils.DeleteFile(ReleasePath);
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestReadersObserveCompleteStateDuringPublication;
var
  Index: Integer;
  Publisher: TPublisherThread;
  ReadyPath, ReleasePath: string;
  Readers: array[0..3] of TReaderThread;
  StartedAt: QWord;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  Publisher := nil;
  ReadyPath := FScratch + '-publication-ready';
  ReleasePath := FScratch + '-publication-release';
  try
    SetRegistryPublicationBarrierForTesting(ReadyPath, ReleasePath);
    Publisher := TPublisherThread.Create(Store);
    Publisher.Start;
    StartedAt := GetTickCount64;
    while not FileExists(ReadyPath) do
    begin
      if GetTickCount64 - StartedAt >= 5000 then
        raise Exception.Create('publication did not reach activation barrier');
      Sleep(10);
    end;
    for Index := 0 to High(Readers) do
    begin
      Readers[Index] := TReaderThread.Create(Store);
      Readers[Index].Start;
    end;
    for Index := 0 to High(Readers) do
    begin
      Readers[Index].WaitFor;
      Expect<string>(Readers[Index].Failure).ToBe('');
      Readers[Index].Free;
    end;
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
    WriteTextFile(ReleasePath, 'release');
    Publisher.WaitFor;
    Expect<string>(Publisher.Failure).ToBe('');
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(2);
  finally
    if not FileExists(ReleasePath) then WriteTextFile(ReleasePath, 'release');
    if Assigned(Publisher) then
    begin
      Publisher.WaitFor;
      Publisher.Free;
    end;
    SetRegistryPublicationBarrierForTesting('', '');
    SysUtils.DeleteFile(ReadyPath);
    SysUtils.DeleteFile(ReleasePath);
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestTamperedSignatureHasStableDiagnostic;
var
  Diagnostic: string;
  Reopened: TLWPTRegistryStore;
  SignatureNibble: SizeInt;
  SignaturePath, SignatureText: string;
  State: TLWPTRegistryState;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  State := Store.LoadCurrentState;
  Store.Free;
  SignaturePath := FScratch + '/' + State.SignaturePath;
  SignatureText := ReadBinaryFile(SignaturePath);
  SignatureNibble := Pos('signature = "hex:', SignatureText)
    + Length('signature = "hex:');
  if SignatureText[SignatureNibble] = '0' then
    SignatureText[SignatureNibble] := '1'
  else SignatureText[SignatureNibble] := '0';
  WriteTextFile(SignaturePath, SignatureText);
  Diagnostic := '';
  Reopened := nil;
  try
    Reopened := TLWPTRegistryStore.Create(FScratch);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Reopened.Free;
  Expect<Boolean>(Pos('signature_invalid:', Diagnostic) = 1).ToBe(True);
end;

procedure TRegistryStoreContract.SetupTests;
begin
  Test('default identity is deterministic', TestDefaultIdentityIsDeterministic);
  Test('default identity survives HTTPS reconfiguration',
    TestDefaultIdentitySurvivesHTTPSReconfiguration);
  Test('explicit identity survives reconfiguration',
    TestExplicitIdentitySurvivesReconfiguration);
  Test('plain HTTP rejects a remote binding',
    TestPlainHTTPRejectsRemoteBinding);
  Test('invalid configuration leaves a fresh root uncommitted',
    TestInvalidConfigurationLeavesFreshRootUncommitted);
  Test('committed initialization marker is reconciled',
    TestCommittedInitializationMarkerIsReconciled);
  Test('initial checkpoint verifies after restart',
    TestInitialCheckpointVerifiesAfterRestart);
  Test('publication is immutable and idempotent',
    TestPublicationIsImmutableAndIdempotent);
  Test('version index retains every published version',
    TestVersionIndexRetainsEveryPublishedVersion);
  Test('reserved package name uses a portable index key',
    TestReservedPackageNameUsesPortableIndexKey);
  Test('incomplete initialization is recovered',
    TestIncompleteInitializationIsRecovered);
  Test('oversized initialization marker is rejected before recovery',
    TestOversizedInitializationMarkerIsRejected);
  Test('plain resource short writes obey the monotonic deadline',
    TestPlainResourceSendChecksDeadlineAfterShortWrites);
  Test('caller-owned root is preserved', TestCallerOwnedRootIsPreserved);
  Test('initialization uses an operating-system lease',
    TestInitializationUsesAnOperatingSystemLease);
  Test('recovery clears incomplete staging',
    TestRecoveryClearsIncompleteStaging);
  Test('checkpoint crash does not activate publication',
    TestCheckpointCrashDoesNotActivatePublication);
  Test('activation crash rebuilds derived index',
    TestActivationCrashRebuildsDerivedIndex);
  Test('checkpoint renews without new sequence',
    TestCheckpointRenewsWithoutNewSequence);
  Test('registry paths reject links', TestRegistryPathsRejectLinks);
  Test('canonical URL validation', TestCanonicalURLValidation);
  Test('configured encoded base path routes',
    TestConfiguredEncodedBasePathRoutes);
  Test('unsupported listener family fails during initialization',
    TestUnsupportedListenerFamilyFailsDuringInitialization);
  Test('signing seed is private from creation',
    TestSigningSeedIsPrivateFromCreation);
  Test('server rejects corrupt content-addressed bytes',
    TestServerRejectsCorruptContentAddressedBytes);
  Test('large resource uses a streamed descriptor',
    TestLargeResourceUsesStreamedDescriptor);
  Test('oversized resource is rejected before hashing',
    TestOversizedResourceIsRejectedBeforeHashing);
  Test('resource open rejects unsafe filesystem kinds',
    TestResourceOpenRejectsUnsafeFilesystemKinds);
  Test('Network.framework blocks expose the compiler ABI',
    TestNetworkFrameworkBlockABI);
  Test('Network.framework teardown waits for callback completion',
    TestNetworkFrameworkTeardownOrdering);
  Test('Network.framework cleanup preserves an active primary failure',
    TestNetworkFrameworkCleanupFailureSemantics);
  Test('Darwin TLS transport selection follows product version',
    TestDarwinTLSTransportSelection);
  Test('Darwin structured product version query is deterministic',
    TestDarwinStructuredOperatingSystemVersion);
  Test('Darwin listener capability follows the runtime TLS transport',
    TestDarwinListenerCapabilitySelection);
  Test('server errors conform to the wire contract',
    TestServerErrorsConformToWireContract);
  Test('renewal error does not disclose the store path',
    TestRenewalErrorDoesNotDiscloseStorePath);
  Test('server discovery is truthful', TestServerDiscoveryIsTruthful);
  Test('checkpoint responses require revalidation',
    TestCheckpointResponsesRequireRevalidation);
  Test('readers observe complete state during publication',
    TestReadersObserveCompleteStateDuringPublication);
  Test('tampered signature has a stable diagnostic',
    TestTamperedSignatureHasStableDiagnostic);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryStoreContract.Create('registry store'));
  TestRunnerProgram.Run;
end.
