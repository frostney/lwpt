program LWPT.Registry.Store.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
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
    procedure TestRecoveryClearsIncompleteStaging;
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
  WriteTextFile(FScratch + '/.initializing', 'interrupted');
  WriteTextFile(FScratch + '/partial', 'uncommitted');
  Store := InitializeStore;
  try
    Expect<Boolean>(FileExists(FScratch + '/partial')).ToBe(False);
    Expect<Boolean>(FileExists(FScratch + '/.initializing')).ToBe(False);
    Expect<Int64>(Store.LoadCurrentState.Sequence).ToBe(1);
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
  Test('recovery clears incomplete staging',
    TestRecoveryClearsIncompleteStaging);
  Test('readers observe complete state during publication',
    TestReadersObserveCompleteStateDuringPublication);
  Test('tampered signature has a stable diagnostic',
    TestTamperedSignatureHasStableDiagnostic);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryStoreContract.Create('registry store'));
  TestRunnerProgram.Run;
end.
