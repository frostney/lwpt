program LWPT.Registry.Store.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}

  LWPT.Core,
  LWPT.ProducerLease,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
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

procedure SetFailurePoint(const AValue: string);
begin
  SetRegistryFailurePointForTesting(AValue);
end;

type
  TRegistryStoreContract = class(TTestSuite)
  private
    FScratch: string;
    function DefaultConfig: TLWPTRegistryConfig;
    function InitializeStore: TLWPTRegistryStore;
    function PublishExample(AStore: TLWPTRegistryStore;
      const AByte: Byte): TLWPTRegistryState;
  protected
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestDefaultIdentityIsDeterministic;
    procedure TestExplicitIdentitySurvivesReconfiguration;
    procedure TestPlainHTTPRejectsRemoteBinding;
    procedure TestInitialCheckpointVerifiesAfterRestart;
    procedure TestPublicationIsImmutableAndIdempotent;
    procedure TestVersionIndexRetainsEveryPublishedVersion;
    procedure TestIncompleteInitializationIsRecovered;
    procedure TestCallerOwnedRootIsPreserved;
    procedure TestInitializationUsesAnOperatingSystemLease;
    procedure TestRecoveryClearsIncompleteStaging;
    procedure TestCheckpointCrashDoesNotActivatePublication;
    procedure TestActivationCrashRebuildsDerivedIndex;
    procedure TestCheckpointRenewsWithoutNewSequence;
    procedure TestRegistryPathsRejectLinks;
    procedure TestCanonicalURLValidation;
    procedure TestSigningSeedIsPrivateFromCreation;
    procedure TestServerRejectsCorruptContentAddressedBytes;
    procedure TestServerDiscoveryIsTruthful;
    procedure TestCheckpointResponsesRequireRevalidation;
    procedure TestReadersObserveCompleteStateDuringPublication;
    procedure TestTamperedSignatureHasStableDiagnostic;
  end;

constructor TReaderThread.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStore := AStore;
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
  FindClose(Search);
  Store := TLWPTRegistryStore.Create(FScratch);
  Store.Free;
  Expect<Integer>(FindFirst(FScratch + '/keys/ed25519-*.toml', faAnyFile,
    Search)).ToBe(0);
  SecondKey := Search.Name;
  FindClose(Search);
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
    IndexText := ReadBinaryFile(FScratch + '/indexes/example-lib.toml');
    Expect<Boolean>(Pos('1.0.0=sha256:', IndexText) > 0).ToBe(True);
    Expect<Boolean>(Pos('2.0.0=sha256:', IndexText) > 0).ToBe(True);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(3);
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestIncompleteInitializationIsRecovered;
var
  Store: TLWPTRegistryStore;
begin
  WriteTextFile(FScratch + '/.initializing',
    'registry initialization in progress' + #10);
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
    Expect<Boolean>(FileExists(FScratch + '/indexes/example-lib.toml'))
      .ToBe(False);
  finally
    SetFailurePoint('');
    Store.Free;
  end;
  Store := TLWPTRegistryStore.Create(FScratch);
  try
    Expect<Boolean>(FileExists(FScratch + '/indexes/example-lib.toml'))
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
  Diagnostic: string;
begin
  Expect<string>(CanonicalRegistryURL(
    'https://[2001:0db8:0:0:0:0:0:1]:443/a/../b', False))
    .ToBe('https://[2001:db8::1]/b');
  Diagnostic := '';
  try
    CanonicalRegistryURL('https://example.com/"bad"', False);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_url:', Diagnostic) = 1).ToBe(True);
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
  ObjectName: string;
  Response: TLWPTRegistryHTTPResponse;
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
    FindClose(Search);
    WriteTextFile(FScratch + '/objects/sha256/' + ObjectName, 'tampered');
    Response := RegistryHTTPResponse(Store, 'GET',
      '/v1/objects/sha256/' + ObjectName);
    Expect<Integer>(Response.Status).ToBe(500);
    Expect<Boolean>(Pos('resource_hash_mismatch',
      TEncoding.UTF8.GetString(Response.Body)) > 0).ToBe(True);
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
    Expect<Boolean>(Pos('rotation-chain-v1', Body) = 0).ToBe(True);
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
  Response: TLWPTRegistryHTTPResponse;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    Response := RegistryHTTPResponse(Store, 'GET',
      '/v1/checkpoints/latest.toml');
    Expect<string>(Response.CacheControl).ToBe('no-cache, must-revalidate');
    Response := RegistryHTTPResponse(Store, 'GET', '/v1/checkpoints/1.toml');
    Expect<string>(Response.CacheControl).ToBe('no-cache, must-revalidate');
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
end;

procedure TRegistryStoreContract.TestReadersObserveCompleteStateDuringPublication;
var
  Index: Integer;
  Readers: array[0..3] of TReaderThread;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  try
    for Index := 0 to High(Readers) do
    begin
      Readers[Index] := TReaderThread.Create(Store);
      Readers[Index].Start;
    end;
    PublishExample(Store, $51);
    for Index := 0 to High(Readers) do
    begin
      Readers[Index].WaitFor;
      Expect<string>(Readers[Index].Failure).ToBe('');
      Readers[Index].Free;
    end;
  finally
    Store.Free;
  end;
end;

procedure TRegistryStoreContract.TestTamperedSignatureHasStableDiagnostic;
var
  Diagnostic: string;
  Reopened: TLWPTRegistryStore;
  SignaturePath, SignatureText: string;
  State: TLWPTRegistryState;
  Store: TLWPTRegistryStore;
begin
  Store := InitializeStore;
  State := Store.LoadCurrentState;
  Store.Free;
  SignaturePath := FScratch + '/' + State.SignaturePath;
  SignatureText := ReadBinaryFile(SignaturePath);
  SignatureText[Pos('signature = "hex:', SignatureText) + 20] := '0';
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
  Test('explicit identity survives reconfiguration',
    TestExplicitIdentitySurvivesReconfiguration);
  Test('plain HTTP rejects a remote binding',
    TestPlainHTTPRejectsRemoteBinding);
  Test('initial checkpoint verifies after restart',
    TestInitialCheckpointVerifiesAfterRestart);
  Test('publication is immutable and idempotent',
    TestPublicationIsImmutableAndIdempotent);
  Test('version index retains every published version',
    TestVersionIndexRetainsEveryPublishedVersion);
  Test('incomplete initialization is recovered',
    TestIncompleteInitializationIsRecovered);
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
  Test('signing seed is private from creation',
    TestSigningSeedIsPrivateFromCreation);
  Test('server rejects corrupt content-addressed bytes',
    TestServerRejectsCorruptContentAddressedBytes);
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
