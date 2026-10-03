{ InstallRegistry.Test -- online installs of registry dependencies (ADR-0051).

  Every case drives the test-flavoured binary against synthetic signed
  registries served on loopback contacts. Per-user registry state and the
  dependency archive cache are isolated per case. Failure cases compare a
  fingerprint of the lock, the cfg, the modules and archives trees (which
  include committed proof documents), and per-user state before and after. }
program InstallRegistry.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.ProducerLease,
  LWPT.Registry.Consumer,
  LWPT.Registry.ConsumerStore,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.PayloadHandoff,
  Tests.RegistryConsumer,
  Tests.Scratch,
  Tests.TarSynth;

const
  DAY = 24 * 60 * 60;
  IDENTITY = 'https://packages.example.com';
  OTHER_IDENTITY = 'https://other.example.com';

type
  TTamper = procedure(ARegistry: TSyntheticRegistry;
    AContact: TSyntheticContact) of object;

  TInstallRegistry = class(TTestSuite)
  private
    FScratch, FReleaseBinary, FCurrentCase: string;
    FCount: Integer;
    procedure DumpCase(const ALabel: string);
    procedure ExpectUnchanged(const ACase, ABefore: string);
    function NewCase(const AName: string): string;
    procedure WriteProject(const ACase, ARegistries, ADependencies: string;
      const AExtra: string = '');
    function Install(const ACase: string;
      const AArguments: array of string): TLwptResult;
    function InstallWith(const ACase: string;
      const AArguments, AEnvironment: array of string): TLwptResult;
    function StateField(const ACase, AField: string): string;
    procedure WriteMember(const ACase, AContent: string);
    function ProjectFingerprint(const ACase: string): string;
    function StateSequenceOf(const ACase, AIdentity, AKeyID: string): Integer;
    function Declaration(const AAlias: string; ARegistry: TSyntheticRegistry;
      const AOrigin: string; const AMirrors: array of string;
      const AWithIdentity: Boolean = True): string;
    function Fingerprint(const ACase: string): string;
    function LockText(const ACase: string): string;
    function StateSequence(const ACase: string): Integer;
    function Output(const ARun: TLwptResult): string;
    procedure ExpectSuccess(const ALabel: string; const ARun: TLwptResult);
    procedure ExpectFailure(const ARun: TLwptResult; const AText: string);
    function NewRegistry(const AIdentity: string; out AContact: TSyntheticContact;
      const ASeed: Byte = 7): TSyntheticRegistry;
    procedure Window(ARegistry: TSyntheticRegistry);
    procedure RunTamper(const AName: string; ATamper: TTamper;
      const AExpected: string);
    { Tampers applied after a baseline install at sequence 1. }
    procedure TamperSignature(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperRecord(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperArchive(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperManifestIdentity(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperLifetime(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperFuture(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperEquivocation(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperDiscoveryOrigin(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperProtocol(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperCapability(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
    procedure TamperDowngrade(ARegistry: TSyntheticRegistry; AContact: TSyntheticContact);
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestExplicitOriginInstall;
    procedure TestAdvertisedIdentityIsLockedAndNeverReplaced;
    procedure TestUndeclaredRecordOriginFails;
    procedure TestDiamondSelectsCommonVersion;
    procedure TestUnsatisfiableSetFails;
    procedure TestRegistryAndLocalSourceConflict;
    procedure TestContactChangesKeepIdentity;
    procedure TestBadSignatureFails;
    procedure TestRecordHashMismatchFails;
    procedure TestArchiveHashMismatchFails;
    procedure TestManifestIdentityMismatchFails;
    procedure TestOverlongCheckpointFails;
    procedure TestFutureCheckpointFails;
    procedure TestEquivocationFails;
    procedure TestDiscoveryNamingAnotherOriginFails;
    procedure TestUnsupportedProtocolFails;
    procedure TestMissingCapabilityFails;
    procedure TestOlderThanLockIsStale;
    procedure TestYankedExactVersionIsNotSelected;
    procedure TestLockedYankedVersionStays;
    procedure TestRequestFailuresAdvance;
    procedure TestStaleMirrorAdvances;
    procedure TestTrustFailureAborts;
    procedure TestAllUnreachableReusesLock;
    procedure TestAllUnreachableWithoutLockFails;
    procedure TestUnreachableReuseUnderAdvertisedIdentity;
    procedure TestClockBehindFloorAbortsBeforeRequests;
    procedure TestArchiveOnlyFromProofContact;
    procedure TestNoChurnAndEmptyStateRestoration;
    procedure TestMirrorInstallKeepsOriginIdentity;
    procedure TestWorkspaceMemberUsesRootRegistries;
    procedure TestPackageManifestCannotDeclareRegistryDependency;
    procedure TestReleaseBinaryRejectsLocalhostHTTP;
    procedure TestPerUserStateIsSharedAndCorruptionNamed;
    procedure TestWorkspaceOnlyBindingsSurviveSharedPin;
    procedure TestTwoAliasesCannotShareAnOrigin;
    procedure TestMemberIdentityConstrainsAdvertisedRoot;
    procedure TestCheckpointPublishedDuringAcquisitionIsAccepted;
    procedure TestCheckpointExpiringBeforePublicationFails;
    procedure TestStateWriteFailureFailsUnchangedInstall;
    procedure TestStateLeaseTimeoutFailsUnchangedInstall;
    procedure TestLaggingPreRotationMirrorIsStale;
    procedure TestDecision8RejectsForgedSignature;
    procedure TestFirstInstallRollsBackAfterLockWrite;
    procedure TestProofReplacementAndPruningRollBack;
    procedure TestLockFloorNeverReachesPerUserState;
    procedure TestLaggingMirrorLackingHistoryIsStale;
    procedure TestEarlierOriginAdvanceSurvivesLaterFailure;
    procedure TestConcurrentProcessesMergeSharedState;
    procedure TestOfflineRestoreSurvivesEvictionPressure;
    procedure TestInvalidStateBudgetFailsBeforeRequests;
    procedure TestRepairReportsDocumentStore;
  end;

  { One install process run from a test thread, so two can overlap. }
  TInstallProcess = class(TThread)
  protected
    procedure Execute; override;
  public
    Project, Error: string;
    Environment: array of string;
    Run: TLwptResult;
  end;

function ReadText(const APath: string): string;
begin
  if not FileExists(APath) then Exit('');
  Result := ReadBinaryFile(APath);
end;

function BytesText(const ABytes: TBytes): string;
begin
  SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;

{ The value of AField in the [package.<AName>] entry of a lock. }
function EntryField(const ALock, AName, AField: string): string;
var Rest: string; Start: Integer;
begin
  Result := '';
  { The lock uses the platform line ending. }
  Rest := StringReplace(ALock, #13#10, #10, [rfReplaceAll]);
  Start := Pos('[package.' + AName + ']'#10, Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start, MaxInt);
  Start := Pos(#10 + AField + ' = "', Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start + Length(AField) + 5, MaxInt);
  Result := Copy(Rest, 1, Pos('"', Rest) - 1);
end;

function TreeFingerprint(const APath: string): string;
begin
  if DirectoryExists(APath) then Result := HashTree(APath)
  else Result := 'absent';
end;

procedure TInstallRegistry.BeforeAll;
begin
  FReleaseBinary := ExpandFileName('build/lwpt');
  SetLwptBinaryPath(FReleaseBinary);
  FScratch := CreateScratchRoot('install-registry');
end;

procedure TInstallRegistry.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

function TInstallRegistry.NewCase(const AName: string): string;
begin
  Inc(FCount);
  { Short directory names keep the deepest transaction paths (a retained
    proof below the journaled rollback root) inside the legacy Windows
    MAX_PATH on CI runners with deep workspaces. The name is kept in a file. }
  Result := FScratch + '/c' + IntToStr(FCount);
  FCurrentCase := Result;
  ForceDirectories(Result);
  WriteTextFile(Result + '/CASE', AName + #10);
  ForceDirectories(Result + '/project/source');
  ForceDirectories(Result + '/state');
  ForceDirectories(Result + '/cache');
  WriteTextFile(Result + '/project/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
end;

procedure TInstallRegistry.WriteProject(const ACase, ARegistries,
  ADependencies, AExtra: string);
begin
  WriteTextFile(ACase + '/project/lwpt.toml', '[package]'#10
    + 'name = "consumer"'#10 + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + ARegistries + AExtra + '[dependencies]'#10 + ADependencies);
end;

function TInstallRegistry.Install(const ACase: string;
  const AArguments: array of string): TLwptResult;
begin
  Result := RunLwptTesting(AArguments, ACase + '/project',
    [PROJECT_NAME + '_REGISTRY_STATE_DIR=' + ACase + '/state',
     PROJECT_NAME + '_CACHE_DIR=' + ACase + '/cache']);
end;

function TInstallRegistry.Declaration(const AAlias: string;
  ARegistry: TSyntheticRegistry; const AOrigin: string;
  const AMirrors: array of string; const AWithIdentity: Boolean): string;
var Index: Integer;
begin
  Result := '[registries.' + AAlias + ']'#10;
  if AWithIdentity then
    Result := Result + 'identity = "' + ARegistry.Identity + '"'#10;
  Result := Result + 'key-id = "' + ARegistry.KeyID + '"'#10
    + 'public-key = "' + ARegistry.PublicKey + '"'#10
    + 'origin = "' + AOrigin + '"'#10;
  if Length(AMirrors) > 0 then
  begin
    Result := Result + 'mirrors = [';
    for Index := 0 to High(AMirrors) do
    begin
      if Index > 0 then Result := Result + ', ';
      Result := Result + '"' + AMirrors[Index] + '"';
    end;
    Result := Result + ']'#10;
  end;
end;

function TInstallRegistry.Fingerprint(const ACase: string): string;
begin
  Result := SHA256Hex(BytesOf(ReadText(ACase + '/project/lwpt.lock')))
    + '|' + SHA256Hex(BytesOf(ReadText(ACase + '/project/lwpt.cfg')))
    + '|' + TreeFingerprint(ACase + '/project/.lwpt/modules')
    + '|' + TreeFingerprint(ACase + '/project/.lwpt/archives')
    + '|' + TreeFingerprint(ACase + '/state/origins');
end;

function TInstallRegistry.LockText(const ACase: string): string;
begin
  Result := ReadText(ACase + '/project/lwpt.lock');
end;

function TInstallRegistry.StateSequence(const ACase: string): Integer;
var Search: TSearchRec; Text: string; Start: Integer;
begin
  Result := 0;
  if FindFirst(ACase + '/state/origins/*.toml', faAnyFile, Search) <> 0 then Exit;
  try
    Text := ReadText(ACase + '/state/origins/' + Search.Name);
  finally
    FindClose(Search);
  end;
  Start := Pos(#10'sequence = ', Text);
  if Start = 0 then Exit;
  Text := Copy(Text, Start + Length(#10'sequence = '), MaxInt);
  Result := StrToIntDef(Copy(Text, 1, Pos(#10, Text) - 1), 0);
end;

function TInstallRegistry.Output(const ARun: TLwptResult): string;
begin
  Result := ARun.Stdout + ARun.Stderr;
end;

{ Lists the case's project and state files, so a native-only failure shows
  what the install left behind. }
procedure TInstallRegistry.DumpCase(const ALabel: string);

  procedure Walk(const ADirectory, APrefix: string; var ALines: Integer);
  var Entry: TSearchRec;
  begin
    if FindFirst(ADirectory + '/*', faAnyFile, Entry) <> 0 then Exit;
    try
      repeat
        if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
        Inc(ALines);
        if ALines > 80 then Exit;
        if (Entry.Attr and faDirectory) <> 0 then
        begin
          WriteLn('  ', APrefix, Entry.Name, '/');
          Walk(ADirectory + '/' + Entry.Name, APrefix + Entry.Name + '/', ALines);
        end
        else WriteLn('  ', APrefix, Entry.Name, ' (', Entry.Size, ' bytes, path ',
          Length(ADirectory + '/' + Entry.Name), ' chars)');
      until FindNext(Entry) <> 0;
    finally
      FindClose(Entry);
    end;
  end;

var Lines: Integer;
begin
  if FCurrentCase = '' then Exit;
  WriteLn('--- ', ALabel, ': case ', FCurrentCase, ' (', Trim(ReadText(FCurrentCase
    + '/CASE')), ') ---');
  WriteLn('  lwpt.lock exists: ', FileExists(FCurrentCase + '/project/lwpt.lock'));
  Lines := 0;
  Walk(FCurrentCase + '/project/.lwpt', '.lwpt/', Lines);
  Walk(FCurrentCase + '/state', 'state/', Lines);
end;

procedure TInstallRegistry.ExpectUnchanged(const ACase, ABefore: string);
var After: string;
begin
  After := Fingerprint(ACase);
  if After <> ABefore then
  begin
    WriteLn('--- state changed: lock|cfg|modules|archives|state ---');
    WriteLn('  before ', ABefore);
    WriteLn('  after  ', After);
    DumpCase('state changed');
  end;
  Expect<string>(After).ToBe(ABefore);
end;

procedure TInstallRegistry.ExpectSuccess(const ALabel: string;
  const ARun: TLwptResult);
begin
  if ARun.ExitCode <> 0 then
  begin
    WriteLn('--- ', ALabel, ' ---'#10, Output(ARun), '---');
    DumpCase(ALabel);
  end;
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

procedure TInstallRegistry.ExpectFailure(const ARun: TLwptResult;
  const AText: string);
begin
  if (ARun.ExitCode = 0) or (Pos(AText, Output(ARun)) = 0) then
  begin
    WriteLn('--- expected failure containing "', AText, '" ---'#10,
      Output(ARun), '---');
    DumpCase('expected failure');
  end;
  Expect<Boolean>(ARun.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos(AText, Output(ARun)) > 0).ToBe(True);
end;

function TInstallRegistry.NewRegistry(const AIdentity: string;
  out AContact: TSyntheticContact; const ASeed: Byte): TSyntheticRegistry;
begin
  Result := TSyntheticRegistry.Create(AIdentity, ASeed);
  AContact := TSyntheticContact.Create(Result, '/origin');
end;

procedure TInstallRegistry.Window(ARegistry: TSyntheticRegistry);
begin
  ARegistry.Publish(RegistryStamp(-120), RegistryStamp(6 * DAY));
end;

{ ---------------------------------------------------------------------------
  Selection, identity, and precedence
  --------------------------------------------------------------------------- }

procedure TInstallRegistry.TestExplicitOriginInstall;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Lock, Cfg: string;
begin
  CaseRoot := NewCase('explicit');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Registry.AddPackage('json', '1.2.0', RegistryPackageArchive('json', '1.2.0'),
      ['util@^1.0.0']);
    Registry.AddPackage('json', '1.3.0', RegistryPackageArchive('json', '1.3.0'),
      ['util@^1.0.0']);
    Registry.AddPackage('json', '2.0.0', RegistryPackageArchive('json', '2.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:corp/json@^1"'#10);
    ExpectSuccess('explicit', Install(CaseRoot, ['install']));
    Lock := LockText(CaseRoot);
    Expect<Boolean>(Pos('source = "registry:corp/json"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('resolvedRef = "1.3.0"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('registryOrigin = "' + IDENTITY + '"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('registryRecord = "' + Registry.RecordHash('json', '1.3.0')
      + '"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('sourceIdentity = "registry|' + IDENTITY + '|json"', Lock) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('archiveHash = "' + Registry.ArchiveHashOf('json', '1.3.0')
      + '"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('source = "registry:util"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('[registry."' + IDENTITY + '"]', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('trustKeyId = "' + Registry.KeyID + '"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('acceptedSequence = 1', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('resolvedCommit', Lock) = 0).ToBe(True);
    Cfg := ReadText(CaseRoot + '/project/lwpt.cfg');
    Expect<Boolean>(Pos('-Fu.lwpt/modules/json/source', Cfg) > 0).ToBe(True);
    Expect<Boolean>(Pos('-Fu.lwpt/modules/util/source', Cfg) > 0).ToBe(True);
    Expect<Boolean>(FileExists(CaseRoot + '/project/.lwpt/archives/registry-proofs/sha256/'
      + Copy(Registry.RecordHash('json', '1.3.0'), 8, 64) + '.toml')).ToBe(True);
    Expect<Boolean>(FileExists(CaseRoot + '/project/.lwpt/archives/json-1.3.0.tar.gz'))
      .ToBe(True);
    Expect<Integer>(StateSequence(CaseRoot)).ToBe(1);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestAdvertisedIdentityIsLockedAndNeverReplaced;
var
  Registry, Other: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('advertised');
  Registry := NewRegistry(IDENTITY, Origin);
  Other := TSyntheticRegistry.Create(OTHER_IDENTITY);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    Other.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Other);
    { No identity: the pinned key authenticates the advertised one. }
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, [], False),
      'json = "registry:json"'#10);
    ExpectSuccess('advertised', Install(CaseRoot, ['install']));
    Expect<Boolean>(Pos('registryOrigin = "' + IDENTITY + '"', LockText(CaseRoot)) > 0)
      .ToBe(True);
    ExpectSuccess('advertised again', Install(CaseRoot, ['install']));
    Before := Fingerprint(CaseRoot);
    { The same pin now advertises a different origin. }
    Origin.Registry := Other;
    ExpectFailure(Install(CaseRoot, ['install']), 'registry_identity_changed');
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Other.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestUndeclaredRecordOriginFails;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('undeclared-origin');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.2.0', RegistryPackageArchive('json', '1.2.0'),
      ['https://elsewhere.example.com|util@^1.0.0']);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectFailure(Install(CaseRoot, ['install']),
      '"util" is required by json@1.2.0 from ' + IDENTITY
      + ', but origin https://elsewhere.example.com is not declared');
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestDiamondSelectsCommonVersion;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Lock: string;
begin
  CaseRoot := NewCase('diamond');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.2.0', RegistryPackageArchive('json', '1.2.0'), []);
    Registry.AddPackage('json', '1.2.5', RegistryPackageArchive('json', '1.2.5'), []);
    Registry.AddPackage('json', '1.3.0', RegistryPackageArchive('json', '1.3.0'), []);
    Registry.AddPackage('app', '2.0.0', RegistryPackageArchive('app', '2.0.0'),
      ['json@<1.3.0']);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1"'#10 + 'app = "registry:app@^2.0.0"'#10);
    ExpectSuccess('diamond', Install(CaseRoot, ['install']));
    Lock := LockText(CaseRoot);
    Expect<string>(EntryField(Lock, 'json', 'resolvedRef')).ToBe('1.2.5');
    Expect<string>(EntryField(Lock, 'app', 'resolvedRef')).ToBe('2.0.0');
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestUnsatisfiableSetFails;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('unsatisfiable');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.3.0', RegistryPackageArchive('json', '1.3.0'), []);
    Registry.AddPackage('app', '2.0.0', RegistryPackageArchive('app', '2.0.0'),
      ['json@<1.3.0']);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.3.0"'#10 + 'app = "registry:app@^2.0.0"'#10);
    Run := Install(CaseRoot, ['install']);
    ExpectFailure(Run, 'unresolvable version conflict on "json"');
    Expect<Boolean>(Pos('consumer wants "^1.3.0"', Output(Run)) > 0).ToBe(True);
    Expect<Boolean>(Pos('app wants "<1.3.0"', Output(Run)) > 0).ToBe(True);
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestRegistryAndLocalSourceConflict;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('source-conflict');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.AddPackage('app', '1.0.0', RegistryPackageArchive('app', '1.0.0'),
      ['json@^1.0.0']);
    Window(Registry);
    ForceDirectories(CaseRoot + '/project/vendor/json/source');
    WriteTextFile(CaseRoot + '/project/vendor/json/lwpt.toml',
      '[package]'#10 + 'name = "json"'#10 + 'version = "1.0.0"'#10);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "./vendor/json"'#10 + 'app = "registry:app"'#10);
    ExpectFailure(Install(CaseRoot, ['install']),
      'unresolvable source conflict on "json"');
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestContactChangesKeepIdentity;
var
  Registry: TSyntheticRegistry;
  Origin, Moved, Mirror: TSyntheticContact;
  CaseRoot, Before: string;
  OriginRequests: Integer;
begin
  CaseRoot := NewCase('contacts-move');
  Registry := NewRegistry(IDENTITY, Origin);
  Moved := TSyntheticContact.Create(Registry, '/moved');
  Mirror := TSyntheticContact.Create(Registry, '/mirror', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('before move', Install(CaseRoot, ['install']));
    Before := LockText(CaseRoot);
    Origin.Mode := scmFail;
    OriginRequests := Origin.Requests;
    WriteProject(CaseRoot, Declaration('corp', Registry, Moved.BaseURL,
      [Mirror.BaseURL]), 'json = "registry:json"'#10);
    ExpectSuccess('after move', Install(CaseRoot, ['install']));
    { sourceIdentity, registryOrigin, registryRecord, resolvedURL: every
      byte of the lock is unchanged. }
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
    Expect<Integer>(Origin.Requests).ToBe(OriginRequests);
    Expect<Boolean>(Mirror.RequestedCount('checkpoints/latest.toml') > 0).ToBe(True);
  finally
    Mirror.Free;
    Moved.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Tamper matrix: every failure leaves project and per-user state unchanged
  --------------------------------------------------------------------------- }

procedure TInstallRegistry.RunTamper(const AName: string; ATamper: TTamper;
  const AExpected: string);
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('tamper-' + AName);
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-3600), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('baseline ' + AName, Install(CaseRoot, ['install']));
    Before := Fingerprint(CaseRoot);
    ATamper(Registry, Origin);
    ExpectFailure(Install(CaseRoot, ['install']), AExpected);
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TamperSignature(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
var Signature: TBytes; Current: TSyntheticCheckpoint;
begin
  ARegistry.AddPackage('json', '1.4.0', RegistryPackageArchive('json', '1.4.0'), []);
  Window(ARegistry);
  Current := ARegistry.Checkpoint(-1);
  Signature := Copy(Current.Signature);
  { Flip one hex digit inside the signature value. }
  if Signature[Length(Signature) - 3] = Ord('0') then
    Signature[Length(Signature) - 3] := Ord('1')
  else Signature[Length(Signature) - 3] := Ord('0');
  AContact.Override('checkpoints/latest.sig.toml', Signature);
end;

procedure TInstallRegistry.TamperRecord(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
var Bytes: TBytes; Path: string;
begin
  ARegistry.AddPackage('json', '1.4.0', RegistryPackageArchive('json', '1.4.0'), []);
  Window(ARegistry);
  Path := 'records/sha256/' + Copy(ARegistry.RecordHash('json', '1.4.0'), 8, 64) + '.toml';
  ARegistry.Document(Path, Bytes);
  Bytes := Copy(Bytes);
  Bytes[Pos('1.4.0', BytesText(Bytes)) + 3] := Ord('9');
  AContact.Override(Path, Bytes);
end;

procedure TInstallRegistry.TamperArchive(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  ARegistry.AddPackage('json', '1.4.0', RegistryPackageArchive('json', '1.4.0'), []);
  Window(ARegistry);
  AContact.Override('objects/sha256/' + Copy(ARegistry.ArchiveHashOf('json', '1.4.0'),
    8, 64), RegistryPackageArchive('json', '6.6.6'));
end;

procedure TInstallRegistry.TamperManifestIdentity(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  ARegistry.AddPackage('json', '1.4.0',
    RegistryPackageArchive('json', '1.4.0', 'json', '9.9.9'), []);
  Window(ARegistry);
end;

procedure TInstallRegistry.TamperLifetime(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  ARegistry.AddPackage('json', '1.4.0', RegistryPackageArchive('json', '1.4.0'), []);
  ARegistry.Publish(RegistryStamp(-60), RegistryStamp(8 * DAY));
end;

procedure TInstallRegistry.TamperFuture(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  ARegistry.AddPackage('json', '1.4.0', RegistryPackageArchive('json', '1.4.0'), []);
  ARegistry.Publish(RegistryStamp(3600), RegistryStamp(2 * DAY));
end;

procedure TInstallRegistry.TamperEquivocation(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  { Sequence 1 again, naming a different snapshot. }
  ARegistry.SignRaw(1, 'sha256:' + StringOfChar('e', 64), RegistryStamp(-30),
    RegistryStamp(DAY));
end;

procedure TInstallRegistry.TamperDiscoveryOrigin(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  AContact.AdvertisedOrigin := OTHER_IDENTITY;
end;

procedure TInstallRegistry.TamperProtocol(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  AContact.AdvertisedProtocol := 2;
end;

procedure TInstallRegistry.TamperCapability(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  AContact.Override('capabilities', BytesOf(
    'schema = "lwpt-registry-capabilities-v1"'#10 + 'protocol = 1'#10
    + 'hashes = ["sha256"]'#10 + 'signatures = ["ed25519"]'#10
    + 'schemas = ["lwpt-registry-capabilities-v1", "lwpt-registry-checkpoint-v1", '
    + '"lwpt-registry-discovery-v1", "lwpt-registry-error-v1", '
    + '"lwpt-registry-key-v1", "lwpt-registry-package-v1", '
    + '"lwpt-registry-signature-v1", "lwpt-registry-snapshot-v1"]'#10
    + 'features = []'#10 + 'auth_schemes = []'#10 + 'max_page_size = 100'#10));
end;

procedure TInstallRegistry.TamperDowngrade(ARegistry: TSyntheticRegistry;
  AContact: TSyntheticContact);
begin
  { Serves nothing newer; the baseline lock recorded sequence 2. }
  AContact.CheckpointIndex := 0;
end;

procedure TInstallRegistry.TestBadSignatureFails;
begin
  RunTamper('signature', TamperSignature, 'signature_invalid');
end;

procedure TInstallRegistry.TestRecordHashMismatchFails;
begin
  RunTamper('record', TamperRecord, 'registry_record_hash_mismatch');
end;

procedure TInstallRegistry.TestArchiveHashMismatchFails;
begin
  RunTamper('archive', TamperArchive, 'object_hash_mismatch');
end;

procedure TInstallRegistry.TestManifestIdentityMismatchFails;
begin
  RunTamper('manifest', TamperManifestIdentity,
    'registry_manifest_identity_mismatch');
end;

procedure TInstallRegistry.TestOverlongCheckpointFails;
begin
  RunTamper('lifetime', TamperLifetime, 'checkpoint_lifetime_exceeded');
end;

procedure TInstallRegistry.TestFutureCheckpointFails;
begin
  RunTamper('future', TamperFuture, 'checkpoint_from_future');
end;

procedure TInstallRegistry.TestEquivocationFails;
begin
  RunTamper('equivocation', TamperEquivocation, 'checkpoint_equivocation');
end;

procedure TInstallRegistry.TestDiscoveryNamingAnotherOriginFails;
begin
  RunTamper('discovery', TamperDiscoveryOrigin, 'registry_origin_mismatch');
end;

procedure TInstallRegistry.TestUnsupportedProtocolFails;
begin
  RunTamper('protocol', TamperProtocol, 'unsupported_registry_protocol');
end;

procedure TInstallRegistry.TestMissingCapabilityFails;
begin
  RunTamper('capability', TamperCapability, 'registry_capability_missing');
end;

procedure TInstallRegistry.TestOlderThanLockIsStale;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('older-than-lock');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    Registry.AddPackage('json', '1.1.0', RegistryPackageArchive('json', '1.1.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('older baseline', Install(CaseRoot, ['install']));
    Before := Fingerprint(CaseRoot);
    TamperDowngrade(Registry, Origin);
    ExpectFailure(Install(CaseRoot, ['install']), 'checkpoint_downgrade');
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Yanked versions
  --------------------------------------------------------------------------- }

procedure TInstallRegistry.TestYankedExactVersionIsNotSelected;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('yanked-exact');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.AddPackage('json', '1.1.0', RegistryPackageArchive('json', '1.1.0'), [], True);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@1.1.0"'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'yanked');
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('yanked range', Install(CaseRoot, ['install']));
    Expect<Boolean>(Pos('resolvedRef = "1.0.0"', LockText(CaseRoot)) > 0).ToBe(True);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestLockedYankedVersionStays;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Lock: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('yanked-locked');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.AddPackage('json', '1.1.0', RegistryPackageArchive('json', '1.1.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('before yank', Install(CaseRoot, ['install']));
    Registry.SetYanked('json', '1.1.0', True);
    Window(Registry);
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('after yank', Run);
    Expect<Boolean>(Pos('is yanked upstream; it stays locked', Output(Run)) > 0)
      .ToBe(True);
    Lock := LockText(CaseRoot);
    Expect<Boolean>(Pos('resolvedRef = "1.1.0"', Lock) > 0).ToBe(True);
    { The entry takes the new record of the same identity. }
    Expect<Boolean>(Pos('registryRecord = "' + Registry.RecordHash('json', '1.1.0')
      + '"', Lock) > 0).ToBe(True);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Contact selection and failover
  --------------------------------------------------------------------------- }

procedure TInstallRegistry.TestRequestFailuresAdvance;
var
  Registry: TSyntheticRegistry;
  Origin, Down, Redirecting: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('request-failures');
  Registry := NewRegistry(IDENTITY, Origin);
  Down := TSyntheticContact.Create(Registry, '/down', 'mirror');
  Redirecting := TSyntheticContact.Create(Registry, '/redirect', 'mirror');
  try
    Down.Mode := scmFail;
    Redirecting.Mode := scmRedirect;
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Down.BaseURL, Redirecting.BaseURL]), 'json = "registry:json"'#10);
    ExpectSuccess('request failures', Install(CaseRoot, ['install']));
    Expect<Integer>(Down.Requests).ToBe(1);
    Expect<Integer>(Redirecting.Requests).ToBe(1);
    Expect<Boolean>(Pos('resolvedURL = "' + Origin.BaseURL + '/v1/objects/',
      LockText(CaseRoot)) > 0).ToBe(True);
  finally
    Redirecting.Free;
    Down.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestStaleMirrorAdvances;
var
  Registry: TSyntheticRegistry;
  Origin, Stale, Second: TSyntheticContact;
  CaseRoot: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('stale-mirror');
  Registry := NewRegistry(IDENTITY, Origin);
  Stale := TSyntheticContact.Create(Registry, '/stale', 'mirror');
  Second := TSyntheticContact.Create(Registry, '/second', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    Registry.AddPackage('json', '1.1.0', RegistryPackageArchive('json', '1.1.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('stale baseline', Install(CaseRoot, ['install']));
    Stale.CheckpointIndex := 0;
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Stale.BaseURL]), 'json = "registry:json@^1.0.0"'#10);
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('stale mirror', Run);
    Expect<Boolean>(Pos('is stale', Output(Run)) > 0).ToBe(True);
    { Every contact stale: the stale diagnostic lists each contact. }
    Origin.CheckpointIndex := 0;
    Second.CheckpointIndex := 0;
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Stale.BaseURL, Second.BaseURL]), 'json = "registry:json@^1.0.0"'#10);
    Run := Install(CaseRoot, ['install']);
    ExpectFailure(Run, 'registry_contacts_stale');
    Expect<Boolean>(Pos(Second.BaseURL + ': stale', Output(Run)) > 0).ToBe(True);
    Expect<Boolean>(Pos(Origin.BaseURL + ': stale', Output(Run)) > 0).ToBe(True);
  finally
    Second.Free;
    Stale.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestTrustFailureAborts;
var
  Registry: TSyntheticRegistry;
  Origin, Hostile: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('trust-failure');
  Registry := NewRegistry(IDENTITY, Origin);
  Hostile := TSyntheticContact.Create(Registry, '/hostile', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    Hostile.AdvertisedOrigin := OTHER_IDENTITY;
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Hostile.BaseURL]), 'json = "registry:json"'#10);
    ExpectFailure(Install(CaseRoot, ['install']),
      'A trust failure never tries another contact');
    Expect<Integer>(Origin.Requests).ToBe(0);
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Hostile.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestAllUnreachableReusesLock;
var
  Registry: TSyntheticRegistry;
  Origin, Mirror: TSyntheticContact;
  CaseRoot, Before: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('unreachable-lock');
  Registry := NewRegistry(IDENTITY, Origin);
  Mirror := TSyntheticContact.Create(Registry, '/mirror', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Mirror.BaseURL]), 'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('unreachable baseline', Install(CaseRoot, ['install']));
    Before := LockText(CaseRoot);
    Origin.Mode := scmFail;
    Mirror.Mode := scmFail;
    RecursiveDelete(CaseRoot + '/project/.lwpt/modules');
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('unreachable reuse', Run);
    Expect<Boolean>(Pos('reusing the locked selection json@1.0.0', Output(Run)) > 0)
      .ToBe(True);
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
    Expect<Boolean>(FileExists(CaseRoot + '/project/.lwpt/modules/json/lwpt.toml'))
      .ToBe(True);
    { A requirement the locked version no longer satisfies cannot reuse it. }
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Mirror.BaseURL]), 'json = "registry:json@^2.0.0"'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'no longer satisfies');
    { A corrupted committed proof is never trusted. }
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Mirror.BaseURL]), 'json = "registry:json@^1.0.0"'#10);
    WriteTextFile(CaseRoot + '/project/.lwpt/archives/registry-proofs/sha256/'
      + Copy(Registry.RecordHash('json', '1.0.0'), 8, 64) + '.toml', 'tampered'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'registry_proof_corrupt');
  finally
    Mirror.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestAllUnreachableWithoutLockFails;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('unreachable-fresh');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Origin.Mode := scmFail;
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'unreachable');
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestUnreachableReuseUnderAdvertisedIdentity;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('unreachable-advertised');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, [], False),
      'json = "registry:json"'#10);
    ExpectSuccess('advertised baseline', Install(CaseRoot, ['install']));
    Before := LockText(CaseRoot);
    Origin.Mode := scmFail;
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('advertised reuse', Run);
    Expect<Boolean>(Pos('reusing the locked selection json@1.0.0', Output(Run)) > 0)
      .ToBe(True);
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestClockBehindFloorAbortsBeforeRequests;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Lock, Future: string;
  Requests: Integer;
begin
  CaseRoot := NewCase('clock-floor');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('floor baseline', Install(CaseRoot, ['install']));
    { Fresh CI: no per-user state, and a lock whose floor is ahead. }
    RecursiveDelete(CaseRoot + '/state');
    ForceDirectories(CaseRoot + '/state');
    Future := RegistryStamp(2 * DAY);
    Lock := LockText(CaseRoot);
    Lock := Copy(Lock, 1, Pos('clockFloor = "', Lock) + Length('clockFloor = "') - 1)
      + Future + '"'#10;
    WriteTextFile(CaseRoot + '/project/lwpt.lock', Lock);
    Requests := Origin.Requests;
    ExpectFailure(Install(CaseRoot, ['install']), 'local_clock_behind_accepted_state');
    Expect<Integer>(Origin.Requests).ToBe(Requests);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestArchiveOnlyFromProofContact;
var
  Registry: TSyntheticRegistry;
  Origin, Mirror: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('archive-contact');
  Registry := NewRegistry(IDENTITY, Origin);
  Mirror := TSyntheticContact.Create(Registry, '/mirror', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    Mirror.Hide('objects/sha256/' + Copy(Registry.ArchiveHashOf('json', '1.0.0'), 8, 64));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Mirror.BaseURL]), 'json = "registry:json"'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'registry_transport_failed');
    Expect<Integer>(Origin.Requests).ToBe(0);
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Mirror.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Lock stability and accepted state (decision 11)
  --------------------------------------------------------------------------- }

procedure TInstallRegistry.TestNoChurnAndEmptyStateRestoration;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('no-churn');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-9000), RegistryStamp(6 * DAY));
    Registry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('no-churn baseline', Install(CaseRoot, ['install']));
    Before := LockText(CaseRoot);
    Expect<Boolean>(Pos('acceptedSequence = 2', Before) > 0).ToBe(True);
    { An unrelated publication advances acquisition, not the lock. }
    Registry.AddPackage('other', '1.0.0', RegistryPackageArchive('other', '1.0.0'), []);
    Window(Registry);
    ExpectSuccess('no-churn advance', Install(CaseRoot, ['install']));
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
    Expect<Integer>(StateSequence(CaseRoot)).ToBe(3);
    { Empty per-user state: the lock's recorded state is the prior. A
      checkpoint below the per-user high-water mark but at the recorded
      sequence is accepted; one below it is stale. }
    RecursiveDelete(CaseRoot + '/state');
    ForceDirectories(CaseRoot + '/state');
    Origin.CheckpointIndex := 1;
    ExpectSuccess('recorded state accepts sequence 2', Install(CaseRoot, ['install']));
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
    Origin.CheckpointIndex := 0;
    ExpectFailure(Install(CaseRoot, ['install']), 'checkpoint_downgrade');
    { Any lock change carries the merged maximum. }
    Origin.CheckpointIndex := -1;
    ExpectSuccess('restore high-water mark', Install(CaseRoot, ['install']));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10 + 'util = "registry:util"'#10);
    ExpectSuccess('lock change', Install(CaseRoot, ['install']));
    Expect<Boolean>(Pos('acceptedSequence = 3', LockText(CaseRoot)) > 0).ToBe(True);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestMirrorInstallKeepsOriginIdentity;
var
  Registry: TSyntheticRegistry;
  Origin, Mirror: TSyntheticContact;
  CaseRoot, Lock, Hex: string;
  Found: Boolean;

  function FindObject(const ADirectory: string): Boolean;
  var Entry: TSearchRec;
  begin
    Result := False;
    if FindFirst(ADirectory + '/*', faAnyFile, Entry) <> 0 then Exit;
    try
      repeat
        if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
        if Pos(Copy(Hex, 3, MaxInt), Entry.Name) > 0 then Exit(True);
        if (Entry.Attr and faDirectory) <> 0 then
          if FindObject(ADirectory + '/' + Entry.Name) then Exit(True);
      until FindNext(Entry) <> 0;
    finally
      FindClose(Entry);
    end;
  end;

begin
  CaseRoot := NewCase('mirror');
  Registry := NewRegistry(IDENTITY, Origin);
  Mirror := TSyntheticContact.Create(Registry, '/mirror', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    Origin.Mode := scmFail;
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Mirror.BaseURL]), 'json = "registry:json"'#10);
    ExpectSuccess('mirror', Install(CaseRoot, ['install']));
    Lock := LockText(CaseRoot);
    Expect<Boolean>(Pos('registryOrigin = "' + IDENTITY + '"', Lock) > 0).ToBe(True);
    Expect<Boolean>(Pos('resolvedURL = "' + Mirror.BaseURL + '/v1/objects/', Lock) > 0)
      .ToBe(True);
    Expect<Integer>(Origin.Requests).ToBe(0);
    Hex := Copy(Registry.ArchiveHashOf('json', '1.0.0'), 8, 64);
    Expect<Boolean>(Pos('archiveHash = "sha256:' + Hex + '"', Lock) > 0).ToBe(True);
    { The CAS object key is the record's archive digest and the lock's
      archiveHash. }
    Found := FileExists(CaseRoot + '/cache/dependency-archives/sha256/'
      + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt));
    if not Found then Found := FindObject(CaseRoot + '/cache');
    Expect<Boolean>(Found).ToBe(True);
  finally
    Mirror.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Where registry dependencies may be declared (decision 5)
  --------------------------------------------------------------------------- }

procedure TInstallRegistry.TestWorkspaceMemberUsesRootRegistries;
var
  Registry, Other: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('workspace');
  Registry := NewRegistry(IDENTITY, Origin);
  Other := TSyntheticRegistry.Create(IDENTITY, 9);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    ForceDirectories(CaseRoot + '/project/packages/member/source');
    WriteTextFile(CaseRoot + '/project/packages/member/lwpt.toml',
      '[package]'#10 + 'name = "member"'#10 + 'version = "1.0.0"'#10
      + 'units = ["source"]'#10 + '[dependencies]'#10
      + 'json = "registry:corp/json@^1.0.0"'#10);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []), '',
      '[workspaces]'#10 + 'include = ["packages/*"]'#10);
    ExpectSuccess('workspace member', Install(CaseRoot, ['install']));
    Expect<Boolean>(Pos('[package.json]', LockText(CaseRoot)) > 0).ToBe(True);
    { A member alias with a different pin fails. }
    WriteTextFile(CaseRoot + '/project/packages/member/lwpt.toml',
      '[package]'#10 + 'name = "member"'#10 + 'version = "1.0.0"'#10
      + 'units = ["source"]'#10 + Declaration('corp', Other, Origin.BaseURL, [])
      + '[dependencies]'#10 + 'json = "registry:corp/json@^1.0.0"'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'different identity or pin');
  finally
    Origin.Free;
    Other.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestPackageManifestCannotDeclareRegistryDependency;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('package-declares');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    ForceDirectories(CaseRoot + '/project/vendor/lib/source');
    WriteTextFile(CaseRoot + '/project/vendor/lib/lwpt.toml',
      '[package]'#10 + 'name = "lib"'#10 + 'version = "1.0.0"'#10
      + '[dependencies]'#10 + 'json = "registry:json"'#10);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'lib = "./vendor/lib"'#10);
    ExpectFailure(Install(CaseRoot, ['install']),
      'registry dependencies may be declared only in the root manifest and '
      + 'workspace members');
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
    Expect<Boolean>(DirectoryExists(CaseRoot + '/project/.lwpt/modules/lib')).ToBe(False);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestReleaseBinaryRejectsLocalhostHTTP;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('release-http');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    Run := RunLwpt(['install'], CaseRoot + '/project',
      [PROJECT_NAME + '_REGISTRY_STATE_DIR=' + CaseRoot + '/state',
       PROJECT_NAME + '_CACHE_DIR=' + CaseRoot + '/cache']);
    ExpectFailure(Run, 'insecure_transport');
    Expect<Integer>(Origin.Requests).ToBe(0);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestPerUserStateIsSharedAndCorruptionNamed;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  First, Second: string;
  Search: TSearchRec;
  StatePath, Corrupt: string;
begin
  First := NewCase('shared-state-a');
  Second := NewCase('shared-state-b');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    Registry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Window(Registry);
    WriteProject(First, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('first project', Install(First, ['install']));
    { The second project shares the first's per-user state directory, so
      its prior is sequence 2 even though it has no lock. }
    WriteProject(Second, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    Origin.CheckpointIndex := 0;
    ExpectFailure(RunLwptTesting(['install'], Second + '/project',
      [PROJECT_NAME + '_REGISTRY_STATE_DIR=' + First + '/state',
       PROJECT_NAME + '_CACHE_DIR=' + Second + '/cache']), 'checkpoint_downgrade');
    Expect<Integer>(StateSequence(First)).ToBe(2);
    Origin.CheckpointIndex := -1;
    { Corrupt state fails and names its file; it is never reset. }
    Expect<Integer>(FindFirst(First + '/state/origins/*.toml', faAnyFile, Search)).ToBe(0);
    StatePath := First + '/state/origins/' + Search.Name;
    FindClose(Search);
    WriteTextFile(StatePath, 'schema = "garbage"'#10);
    Corrupt := ReadText(StatePath);
    ExpectFailure(Install(First, ['install']), 'registry_state_corrupt');
    Expect<Boolean>(Pos(Search.Name, Output(Install(First, ['install']))) > 0)
      .ToBe(True);
    Expect<string>(ReadText(StatePath)).ToBe(Corrupt);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Review follow-ups: identity binding, freshness, persistence, rotation,
  locked-proof signatures, rollback, and floor isolation
  --------------------------------------------------------------------------- }

function TInstallRegistry.InstallWith(const ACase: string;
  const AArguments, AEnvironment: array of string): TLwptResult;
var Environment: array of string; Index: Integer;
begin
  SetLength(Environment, 2 + Length(AEnvironment));
  Environment[0] := PROJECT_NAME + '_REGISTRY_STATE_DIR=' + ACase + '/state';
  Environment[1] := PROJECT_NAME + '_CACHE_DIR=' + ACase + '/cache';
  for Index := 0 to High(AEnvironment) do
    Environment[2 + Index] := AEnvironment[Index];
  Result := RunLwptTesting(AArguments, ACase + '/project', Environment);
end;

function TInstallRegistry.StateField(const ACase, AField: string): string;
var Search: TSearchRec; Text: string; Start: Integer;
begin
  Result := '';
  if FindFirst(ACase + '/state/origins/*.toml', faAnyFile, Search) <> 0 then Exit;
  try
    Text := ReadText(ACase + '/state/origins/' + Search.Name);
  finally
    FindClose(Search);
  end;
  Start := Pos(#10 + AField + ' = "', Text);
  if Start = 0 then Exit;
  Text := Copy(Text, Start + Length(AField) + 5, MaxInt);
  Result := Copy(Text, 1, Pos('"', Text) - 1);
end;

procedure TInstallRegistry.WriteMember(const ACase, AContent: string);
begin
  ForceDirectories(ACase + '/project/packages/member/source');
  WriteTextFile(ACase + '/project/packages/member/lwpt.toml',
    '[package]'#10 + 'name = "member"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + AContent);
end;

procedure TInstallRegistry.TestWorkspaceOnlyBindingsSurviveSharedPin;
var
  First, Second, Third: TSyntheticRegistry;
  FirstContact, SecondContact: TSyntheticContact;
  CaseRoot, Before, Lock: string;
begin
  CaseRoot := NewCase('workspace-bindings');
  First := NewRegistry(IDENTITY, FirstContact);
  Second := NewRegistry(OTHER_IDENTITY, SecondContact);
  Third := TSyntheticRegistry.Create('https://third.example.com');
  try
    First.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(First);
    Second.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Window(Second);
    Third.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Third);
    { Two identity-less aliases share one pin, and only a workspace member
      declares registry dependencies. }
    WriteMember(CaseRoot, '[dependencies]'#10 + 'json = "registry:corp/json"'#10
      + 'util = "registry:oss/util"'#10);
    WriteProject(CaseRoot,
      Declaration('corp', First, FirstContact.BaseURL, [], False)
      + Declaration('oss', Second, SecondContact.BaseURL, [], False), '',
      '[workspaces]'#10 + 'include = ["packages/*"]'#10);
    ExpectSuccess('shared pin baseline', Install(CaseRoot, ['install']));
    Lock := LockText(CaseRoot);
    Expect<string>(EntryField(Lock, 'json', 'registryOrigin')).ToBe(IDENTITY);
    Expect<string>(EntryField(Lock, 'util', 'registryOrigin')).ToBe(OTHER_IDENTITY);
    Before := Fingerprint(CaseRoot);
    { A third origin under the same key is never a first discovery. }
    FirstContact.Registry := Third;
    ExpectFailure(Install(CaseRoot, ['install']), 'registry_identity_changed');
    ExpectUnchanged(CaseRoot, Before);
    { With no locked dependency binding the alias, two unclaimed tables under
      its key are ambiguous: the install fails before any request. }
    FirstContact.Registry := First;
    WriteMember(CaseRoot, '[dependencies]'#10 + 'extra = "registry:corp/extra"'#10);
    ExpectFailure(Install(CaseRoot, ['install']),
      'records several origins pinned to the key of [registries.corp]');
    ExpectUnchanged(CaseRoot, Before);
  finally
    FirstContact.Free;
    SecondContact.Free;
    Third.Free;
    Second.Free;
    First.Free;
  end;
end;

procedure TInstallRegistry.TestTwoAliasesCannotShareAnOrigin;
var
  Registry: TSyntheticRegistry;
  Origin, Copy: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('duplicate-identity');
  Registry := NewRegistry(IDENTITY, Origin);
  Copy := TSyntheticContact.Create(Registry, '/copy');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot,
      Declaration('corp', Registry, Origin.BaseURL, [], False)
      + Declaration('copy', Registry, Copy.BaseURL, [], False),
      'json = "registry:corp/json"'#10 + 'util = "registry:copy/util"'#10);
    ExpectFailure(Install(CaseRoot, ['install']), 'both resolve to origin '
      + IDENTITY);
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
  finally
    Copy.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestMemberIdentityConstrainsAdvertisedRoot;
var
  Declared, Advertised: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('member-identity');
  { The same pin signs both origins; the root's contact advertises one. }
  Declared := TSyntheticRegistry.Create(IDENTITY);
  Advertised := NewRegistry(OTHER_IDENTITY, Origin);
  try
    Advertised.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Advertised);
    WriteMember(CaseRoot, Declaration('corp', Declared, Origin.BaseURL, [])
      + '[dependencies]'#10 + 'json = "registry:corp/json"'#10);
    WriteProject(CaseRoot, Declaration('corp', Advertised, Origin.BaseURL, [], False),
      '', '[workspaces]'#10 + 'include = ["packages/*"]'#10);
    ExpectFailure(Install(CaseRoot, ['install']),
      'workspace member "member" declares [registries.corp] with identity '
      + IDENTITY);
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
    { The member naming the advertised identity agrees and installs. }
    WriteMember(CaseRoot, Declaration('corp', Advertised, Origin.BaseURL, [])
      + '[dependencies]'#10 + 'json = "registry:corp/json"'#10);
    ExpectSuccess('member agrees', Install(CaseRoot, ['install']));
  finally
    Origin.Free;
    Advertised.Free;
    Declared.Free;
  end;
end;

procedure TInstallRegistry.TestCheckpointPublishedDuringAcquisitionIsAccepted;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('published-during');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    { Published two seconds from now; discovery answers after four. }
    Registry.Publish(RegistryStamp(2), RegistryStamp(DAY));
    Origin.Delay('.well-known', 4000);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('published during acquisition', Install(CaseRoot, ['install']));
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestCheckpointExpiringBeforePublicationFails;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('expires-before-publication');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    { Fresh when verified, expired once the delayed archive arrives. }
    Registry.Publish(RegistryStamp(-60), RegistryStamp(3));
    Origin.Delay('/objects/', 5000);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    Before := Fingerprint(CaseRoot);
    ExpectFailure(Install(CaseRoot, ['install']), 'before the install could publish');
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestStateWriteFailureFailsUnchangedInstall;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('state-write-failure');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('state baseline', Install(CaseRoot, ['install']));
    { Acquisition advances without changing the selection: per-user state
      is then the only record of sequence 2. }
    Registry.AddPackage('other', '1.0.0', RegistryPackageArchive('other', '1.0.0'), []);
    Window(Registry);
    Before := Fingerprint(CaseRoot);
    ExpectFailure(InstallWith(CaseRoot, ['install'],
      [PROJECT_NAME + '_TEST_FAIL_REGISTRY_STATE_WRITE=1']),
      'registry_state_not_persisted');
    ExpectUnchanged(CaseRoot, Before);
    Expect<Integer>(StateSequence(CaseRoot)).ToBe(1);
    ExpectSuccess('state recovers', Install(CaseRoot, ['install']));
    Expect<Integer>(StateSequence(CaseRoot)).ToBe(2);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestStateLeaseTimeoutFailsUnchangedInstall;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
begin
  CaseRoot := NewCase('state-lease-timeout');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('lease baseline', Install(CaseRoot, ['install']));
    Registry.AddPackage('other', '1.0.0', RegistryPackageArchive('other', '1.0.0'), []);
    Window(Registry);
    Before := Fingerprint(CaseRoot);
    Coordinator := TLWPTProducerLeaseCoordinator.Create(CaseRoot + '/state/locks');
    try
      Lease := Coordinator.TryAcquire('registry-state:' + ExtractFileName(
        RegistryStatePathAt(CaseRoot + '/state', IDENTITY, Registry.KeyID)),
        'test holder');
      Expect<Boolean>(Lease <> nil).ToBe(True);
      try
        ExpectFailure(InstallWith(CaseRoot, ['install'],
          [PROJECT_NAME + '_TEST_REGISTRY_STATE_LEASE_MS=300']),
          'registry_state_locked');
      finally
        Lease.Free;
      end;
    finally
      Coordinator.Free;
    end;
    ExpectUnchanged(CaseRoot, Before);
    Expect<Integer>(StateSequence(CaseRoot)).ToBe(1);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestLaggingPreRotationMirrorIsStale;
var
  Registry: TSyntheticRegistry;
  Origin, Lagging: TSyntheticContact;
  CaseRoot, Before: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('rotation-lagging');
  Registry := NewRegistry(IDENTITY, Origin);
  Lagging := TSyntheticContact.Create(Registry, '/lagging', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    Registry.Rotate(11);
    Registry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Window(Registry);
    Expect<Boolean>(Registry.CurrentKeyID <> Registry.KeyID).ToBe(True);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    { Acquisition follows the rotation chain from the pin. }
    ExpectSuccess('rotated origin', Install(CaseRoot, ['install']));
    Expect<Boolean>(Pos('keyId = "' + Registry.CurrentKeyID + '"',
      LockText(CaseRoot)) > 0).ToBe(True);
    Before := LockText(CaseRoot);
    { A lagging mirror serves the authentic pre-rotation checkpoint. }
    Lagging.CheckpointIndex := 0;
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Lagging.BaseURL]), 'json = "registry:json"'#10);
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('lagging mirror with per-user chain', Run);
    Expect<Boolean>(Pos(Lagging.BaseURL + ' is stale', Output(Run)) > 0).ToBe(True);
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
    { Fresh CI: the committed proof supplies the accepted chain. }
    RecursiveDelete(CaseRoot + '/state');
    ForceDirectories(CaseRoot + '/state');
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('lagging mirror with committed chain', Run);
    Expect<Boolean>(Pos(Lagging.BaseURL + ' is stale', Output(Run)) > 0).ToBe(True);
    Expect<string>(LockText(CaseRoot)).ToBe(Before);
  finally
    Lagging.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestDecision8RejectsForgedSignature;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Lock, OldHash, NewHash, ProofRoot, Text, Before: string;
  Bytes: TBytes;
  Position: Integer;
begin
  CaseRoot := NewCase('forged-signature');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('forged baseline', Install(CaseRoot, ['install']));
    { Replace the committed signature envelope with a canonical one whose key
      id and payload hash are right but whose signature is not, keeping the
      proof file name and the lock's hash consistent. }
    Lock := LockText(CaseRoot);
    Text := Copy(Lock, Pos(#10'signature = "', Lock) + 14, MaxInt);
    OldHash := Copy(Text, 1, Pos('"', Text) - 1);
    ProofRoot := CaseRoot + '/project/.lwpt/archives/registry-proofs/sha256/';
    Text := ReadText(ProofRoot + Copy(OldHash, 8, 64) + '.toml');
    Position := Pos('signature = "hex:', Text) + Length('signature = "hex:') + 20;
    if Text[Position] = '0' then Text[Position] := '1' else Text[Position] := '0';
    Bytes := BytesOf(Text);
    NewHash := SHA256BytesPrefixed(Bytes);
    DeleteFile(ProofRoot + Copy(OldHash, 8, 64) + '.toml');
    { Exact bytes: the file name is the hash of its content. }
    WriteBytesToFile(ProofRoot + Copy(NewHash, 8, 64) + '.toml', Bytes);
    WriteTextFile(CaseRoot + '/project/lwpt.lock',
      StringReplace(Lock, 'signature = "' + OldHash + '"',
        'signature = "' + NewHash + '"', []));
    Before := Fingerprint(CaseRoot);
    Origin.Mode := scmFail;
    ExpectFailure(Install(CaseRoot, ['install']), 'signature_invalid');
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestFirstInstallRollsBackAfterLockWrite;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot: string;
begin
  CaseRoot := NewCase('rollback-first');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectFailure(InstallWith(CaseRoot, ['install'],
      [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']),
      'injected failure after lockfile publication');
    Expect<Boolean>(FileExists(CaseRoot + '/project/lwpt.lock')).ToBe(False);
    Expect<Boolean>(DirectoryExists(CaseRoot + '/project/.lwpt/modules/json'))
      .ToBe(False);
    Expect<Boolean>(DirectoryExists(
      CaseRoot + '/project/.lwpt/archives/registry-proofs')).ToBe(False);
    Expect<Boolean>(DirectoryExists(CaseRoot + '/state/origins')).ToBe(False);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestProofReplacementAndPruningRollBack;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('rollback-proofs');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1.0.0"'#10);
    ExpectSuccess('rollback baseline', Install(CaseRoot, ['install']));
    Before := Fingerprint(CaseRoot);
    { A new selection replaces the proof set; the failure restores it. }
    Registry.AddPackage('json', '1.1.0', RegistryPackageArchive('json', '1.1.0'), []);
    Window(Registry);
    ExpectFailure(InstallWith(CaseRoot, ['install'],
      [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']),
      'injected failure after lockfile publication');
    ExpectUnchanged(CaseRoot, Before);
    { Dropping the dependency prunes every proof; the failure restores them. }
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []), '');
    ExpectFailure(InstallWith(CaseRoot, ['install'],
      [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']),
      'injected failure after lockfile publication');
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestLockFloorNeverReachesPerUserState;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Lock, Published, Edited: string;
begin
  CaseRoot := NewCase('floor-isolation');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('floor baseline', Install(CaseRoot, ['install']));
    Published := StateField(CaseRoot, 'published_at');
    Expect<string>(StateField(CaseRoot, 'clock_floor')).ToBe(Published);
    { An unsigned lock floor later than anything signed, but not ahead of
      the clock, stays project state. }
    Edited := RegistryStamp(-5);
    Lock := LockText(CaseRoot);
    Lock := Copy(Lock, 1, Pos('clockFloor = "', Lock) + Length('clockFloor = "') - 1)
      + Edited + '"'#10;
    WriteTextFile(CaseRoot + '/project/lwpt.lock', Lock);
    RecursiveDelete(CaseRoot + '/state');
    ForceDirectories(CaseRoot + '/state');
    ExpectSuccess('floor edited', Install(CaseRoot, ['install']));
    Expect<string>(StateField(CaseRoot, 'clock_floor')).ToBe(Published);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

function TInstallRegistry.ProjectFingerprint(const ACase: string): string;
begin
  Result := SHA256Hex(BytesOf(ReadText(ACase + '/project/lwpt.lock')))
    + '|' + SHA256Hex(BytesOf(ReadText(ACase + '/project/lwpt.cfg')))
    + '|' + TreeFingerprint(ACase + '/project/.lwpt/modules')
    + '|' + TreeFingerprint(ACase + '/project/.lwpt/archives');
end;

function TInstallRegistry.StateSequenceOf(const ACase, AIdentity,
  AKeyID: string): Integer;
var Text: string; Start: Integer;
begin
  Result := 0;
  Text := ReadText(RegistryStatePathAt(ACase + '/state', AIdentity, AKeyID));
  Start := Pos(#10'sequence = ', Text);
  if Start = 0 then Exit;
  Text := Copy(Text, Start + Length(#10'sequence = '), MaxInt);
  Result := StrToIntDef(Copy(Text, 1, Pos(#10, Text) - 1), 0);
end;

procedure TInstallRegistry.TestLaggingMirrorLackingHistoryIsStale;
var
  Registry: TSyntheticRegistry;
  Origin, Lagging: TSyntheticContact;
  CaseRoot, Before: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('lagging-history');
  Registry := NewRegistry(IDENTITY, Origin);
  Lagging := TSyntheticContact.Create(Registry, '/lagging', 'mirror');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    Registry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('history baseline', Install(CaseRoot, ['install']));
    { The mirror stopped at sequence 1: it lacks sequence 2's snapshot. }
    Lagging.CheckpointIndex := 0;
    Expect<Integer>(Registry.VisibleFrom('snapshots/sha256/'
      + Copy(Registry.Head, 8, 64) + '.toml')).ToBe(2);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL,
      [Lagging.BaseURL]), 'json = "registry:json"'#10);
    Before := Fingerprint(CaseRoot);
    { A healthy next contact: the lagging one is stale, not unreachable. }
    Run := Install(CaseRoot, ['install']);
    ExpectSuccess('lagging then healthy', Run);
    Expect<Boolean>(Pos(Lagging.BaseURL + ' is stale', Output(Run)) > 0).ToBe(True);
    Expect<Integer>(Lagging.RequestedCount('snapshots/')).ToBe(0);
    { No healthy contact: the stale diagnostic, never the locked fallback. }
    Origin.Mode := scmFail;
    Before := Fingerprint(CaseRoot);
    Run := Install(CaseRoot, ['install']);
    ExpectFailure(Run, 'registry_contacts_stale');
    Expect<Boolean>(Pos('reusing the locked selection', Output(Run)) = 0).ToBe(True);
    ExpectUnchanged(CaseRoot, Before);
    { Fresh CI: the committed proof holds the accepted snapshot. }
    RecursiveDelete(CaseRoot + '/state');
    ForceDirectories(CaseRoot + '/state');
    ExpectFailure(Install(CaseRoot, ['install']), 'registry_contacts_stale');
  finally
    Lagging.Free;
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestEarlierOriginAdvanceSurvivesLaterFailure;
var
  First, Second: TSyntheticRegistry;
  FirstContact, SecondContact: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('partial-persistence');
  First := NewRegistry(IDENTITY, FirstContact);
  Second := NewRegistry(OTHER_IDENTITY, SecondContact, 9);
  try
    First.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    First.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    Second.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
    Second.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', First, FirstContact.BaseURL, [])
      + Declaration('oss', Second, SecondContact.BaseURL, []),
      'json = "registry:corp/json"'#10 + 'util = "registry:oss/util"'#10);
    ExpectSuccess('partial baseline', Install(CaseRoot, ['install']));
    First.AddPackage('a', '1.0.0', RegistryPackageArchive('a', '1.0.0'), []);
    Window(First);
    Second.AddPackage('b', '1.0.0', RegistryPackageArchive('b', '1.0.0'), []);
    Window(Second);
    Before := ProjectFingerprint(CaseRoot);
    { The second origin's state fails after the first advanced: the install
      fails and project state rolls back, while the first origin's
      authenticated, monotonic advance is retained, not undone. }
    ExpectFailure(InstallWith(CaseRoot, ['install'],
      [PROJECT_NAME + '_TEST_FAIL_REGISTRY_STATE_WRITE=' + OTHER_IDENTITY]),
      'registry_state_not_persisted');
    Expect<string>(ProjectFingerprint(CaseRoot)).ToBe(Before);
    Expect<Integer>(StateSequenceOf(CaseRoot, IDENTITY, First.KeyID)).ToBe(2);
    Expect<Integer>(StateSequenceOf(CaseRoot, OTHER_IDENTITY, Second.KeyID)).ToBe(1);
    ExpectSuccess('partial recovers', Install(CaseRoot, ['install']));
    Expect<Integer>(StateSequenceOf(CaseRoot, OTHER_IDENTITY, Second.KeyID)).ToBe(2);
  finally
    FirstContact.Free;
    SecondContact.Free;
    Second.Free;
    First.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Per-user document store: shared merges and eviction (#345)
  --------------------------------------------------------------------------- }

procedure TInstallProcess.Execute;
begin
  try
    Run := RunLwptTesting(['install'], Project, Environment);
  except
    on E: Exception do Error := E.Message;
  end;
end;

function StartInstall(const AProject: string;
  const AEnvironment: array of string): TInstallProcess;
var Index: Integer;
begin
  Result := TInstallProcess.Create(True);
  Result.Project := AProject;
  SetLength(Result.Environment, Length(AEnvironment));
  for Index := 0 to High(AEnvironment) do
    Result.Environment[Index] := AEnvironment[Index];
  Result.Start;
end;

{ Waits for APath's completion marker, or for AProcess to end first. }
function AwaitPayload(const APath: string; AProcess: TInstallProcess): Boolean;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not PayloadIsReadable(APath) and not AProcess.Finished
     and (GetTickCount64 - StartedAt < 120 * 1000) do
    Sleep(20);
  Result := PayloadIsReadable(APath);
end;

{ The value of AKey in a lock's single [registry."<identity>"] table. }
function LockTableValue(const ALock, AKey: string): string;
var Rest: string; Start: Integer;
begin
  Rest := StringReplace(ALock, #13#10, #10, [rfReplaceAll]);
  Start := Pos(#10 + AKey + ' = "', Rest);
  if Start = 0 then Exit('');
  Rest := Copy(Rest, Start + Length(AKey) + 5, MaxInt);
  Result := Copy(Rest, 1, Pos('"', Rest) - 1);
end;

function PlantOrphan(const AStateRoot, ALabel: string; const ASize: Integer): string;
var Bytes: TBytes;
begin
  Bytes := BytesOf(ALabel + StringOfChar('.', ASize - Length(ALabel)));
  Result := SHA256BytesPrefixed(Bytes);
  ForceDirectories(RegistryStateDocumentsDirectory(AStateRoot));
  WriteBytesToFile(RegistryStateDocumentPath(AStateRoot, Result), Bytes);
end;

function StoreHolds(const AStateRoot, AHash: string): Boolean;
begin
  Result := LoadRegistryStateDocument(AStateRoot, AHash) <> nil;
end;

function DirectoryIsEmpty(const APath: string): Boolean;
var Entry: TSearchRec;
begin
  Result := True;
  if FindFirst(APath + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name <> '.') and (Entry.Name <> '..') then Exit(False);
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

procedure TInstallRegistry.TestConcurrentProcessesMergeSharedState;
var
  First, Second: TSyntheticRegistry;
  FirstOrigin, SecondOrigin: TSyntheticContact;
  FirstCase, SecondCase, State, Signals, Orphan, Lock, HeldBy, WaitingBy: string;
  Holder, Waiter: TInstallProcess;
  Loaded: TLWPTRegistryConsumerState;
  Released: Boolean;

  procedure ExpectLockedDocumentsStored(const ACase, AName: string);
  begin
    Lock := LockText(ACase);
    Expect<Boolean>(StoreHolds(State, LockTableValue(Lock, 'checkpoint'))).ToBe(True);
    Expect<Boolean>(StoreHolds(State, LockTableValue(Lock, 'signature'))).ToBe(True);
    Expect<Boolean>(StoreHolds(State, LockTableValue(Lock, 'snapshot'))).ToBe(True);
    Expect<Boolean>(StoreHolds(State, EntryField(Lock, AName, 'registryRecord')))
      .ToBe(True);
  end;

begin
  FirstCase := NewCase('concurrent-first');
  SecondCase := NewCase('concurrent-second');
  State := FirstCase + '/state';
  Signals := FirstCase + '/signals';
  First := NewRegistry(IDENTITY, FirstOrigin);
  Second := NewRegistry(OTHER_IDENTITY, SecondOrigin, 9);
  Holder := nil;
  Waiter := nil;
  Released := False;
  try
    First.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(First);
    Second.AddPackage('http', '1.0.0', RegistryPackageArchive('http', '1.0.0'), []);
    Window(Second);
    WriteProject(FirstCase, Declaration('corp', First, FirstOrigin.BaseURL, []),
      'json = "registry:json"'#10);
    WriteProject(SecondCase, Declaration('corp', Second, SecondOrigin.BaseURL, []),
      'http = "registry:http"'#10);
    { Evictable, and evicted by whichever process passes first. }
    Orphan := PlantOrphan(State, 'orphan', 4096);
    try
      { Two independent processes share one per-user state directory, each
        merging a different origin under a zero budget. The first holds the
        store lease inside its merge until the second is seen waiting. }
      Holder := StartInstall(FirstCase + '/project',
        [PROJECT_NAME + '_REGISTRY_STATE_DIR=' + State,
         PROJECT_NAME + '_CACHE_DIR=' + FirstCase + '/cache',
         REGISTRY_STATE_MAX_BYTES_ENV + '=0',
         PROJECT_NAME + '_TEST_REGISTRY_STATE_HOLD=' + Signals + '/first']);
      Expect<Boolean>(AwaitPayload(Signals + '/first/held', Holder)).ToBe(True);
      HeldBy := ReadPayloadText(Signals + '/first/held');
      Waiter := StartInstall(SecondCase + '/project',
        [PROJECT_NAME + '_REGISTRY_STATE_DIR=' + State,
         PROJECT_NAME + '_CACHE_DIR=' + SecondCase + '/cache',
         REGISTRY_STATE_MAX_BYTES_ENV + '=0',
         PROJECT_NAME + '_TEST_REGISTRY_STATE_CONTENDED=' + Signals + '/second']);
      Expect<Boolean>(AwaitPayload(Signals + '/second/waiting', Waiter)).ToBe(True);
      WaitingBy := ReadPayloadText(Signals + '/second/waiting');
      Expect<Boolean>(StrToIntDef(HeldBy, 0) > 0).ToBe(True);
      Expect<Boolean>(StrToIntDef(WaitingBy, 0) > 0).ToBe(True);
      Expect<Boolean>(HeldBy <> WaitingBy).ToBe(True);
      { The second origin's state is written only under the store lease. }
      Expect<Boolean>(FileExists(RegistryStatePathAt(State, OTHER_IDENTITY,
        Second.KeyID))).ToBe(False);
      Expect<Boolean>(Holder.Finished).ToBe(False);
      PublishPayloadCompletion(Signals + '/first/release');
      Released := True;
      Holder.WaitFor;
      Waiter.WaitFor;
      Expect<string>(Holder.Error).ToBe('');
      Expect<string>(Waiter.Error).ToBe('');
      ExpectSuccess('holding install', Holder.Run);
      ExpectSuccess('waiting install', Waiter.Run);
    finally
      if not Released then PublishPayloadCompletion(Signals + '/first/release');
      if Holder <> nil then
      begin
        Holder.WaitFor;
        Holder.Free;
      end;
      if Waiter <> nil then
      begin
        Waiter.WaitFor;
        Waiter.Free;
      end;
    end;
    Expect<Boolean>(LoadRegistryConsumerStateAt(State, IDENTITY, First.KeyID,
      Loaded)).ToBe(True);
    Expect<Int64>(Loaded.State.Sequence).ToBe(1);
    Expect<Boolean>(LoadRegistryConsumerStateAt(State, OTHER_IDENTITY,
      Second.KeyID, Loaded)).ToBe(True);
    Expect<Int64>(Loaded.State.Sequence).ToBe(1);
    { Each origin's accepted documents survived the other's eviction. }
    ExpectLockedDocumentsStored(FirstCase, 'json');
    ExpectLockedDocumentsStored(SecondCase, 'http');
    Expect<Boolean>(FileExists(RegistryStateDocumentPath(State, Orphan))).ToBe(False);
    { Every write landed atomically: no staging file remains. }
    Expect<Boolean>(DirectoryIsEmpty(State + '/tmp')).ToBe(True);
  finally
    SecondOrigin.Free;
    Second.Free;
    FirstOrigin.Free;
    First.Free;
  end;
end;

procedure TInstallRegistry.TestOfflineRestoreSurvivesEvictionPressure;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, State, Lock, Orphan, Checkpoint, Signature, Snapshot, RecordHash: string;
  CheckpointBytes, SnapshotBytes, RecordBytes: string;

  function Committed(const AHash: string): string;
  begin
    Result := RegistryProofPath(CaseRoot + '/project/.lwpt/archives', AHash);
  end;

begin
  CaseRoot := NewCase('offline-eviction');
  State := CaseRoot + '/state';
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-7200), RegistryStamp(6 * DAY));
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json@^1"'#10);
    { First seen by the seed install, so it is the least recently used. }
    Orphan := PlantOrphan(State, 'stale', 64 * 1024);
    ExpectSuccess('eviction seed', Install(CaseRoot, ['install']));
    Lock := LockText(CaseRoot);
    Checkpoint := LockTableValue(Lock, 'checkpoint');
    Signature := LockTableValue(Lock, 'signature');
    Snapshot := LockTableValue(Lock, 'snapshot');
    RecordHash := EntryField(Lock, 'json', 'registryRecord');
    CheckpointBytes := ReadText(Committed(Checkpoint));
    SnapshotBytes := ReadText(Committed(Snapshot));
    RecordBytes := ReadText(Committed(RecordHash));
    { The origin advances without changing the selection: the lock keeps its
      older proof, whose checkpoint the per-user head now supersedes. }
    Registry.AddPackage('other', '1.0.0', RegistryPackageArchive('other', '1.0.0'), []);
    Window(Registry);
    ExpectSuccess('advance under pressure', InstallWith(CaseRoot, ['install'],
      [REGISTRY_STATE_MAX_BYTES_ENV + '=4096']));
    Expect<Integer>(StateSequence(CaseRoot)).ToBe(2);
    Expect<string>(LockText(CaseRoot)).ToBe(Lock);
    { The oldest evictable document left; the lock's superseded checkpoint
      was used by this install and fits the budget. }
    Expect<Boolean>(FileExists(RegistryStateDocumentPath(State, Orphan))).ToBe(False);
    Expect<Boolean>(StoreHolds(State, Checkpoint)).ToBe(True);
    Expect<Boolean>(StoreHolds(State, Signature)).ToBe(True);
    Expect<Boolean>(DeleteFile(Committed(Checkpoint))).ToBe(True);
    Expect<Boolean>(DeleteFile(Committed(Snapshot))).ToBe(True);
    Expect<Boolean>(DeleteFile(Committed(RecordHash))).ToBe(True);
    Origin.Mode := scmFail;
    ExpectSuccess('offline restore', Install(CaseRoot, ['install', '--offline']));
    Expect<string>(ReadText(Committed(Checkpoint))).ToBe(CheckpointBytes);
    Expect<string>(ReadText(Committed(Snapshot))).ToBe(SnapshotBytes);
    Expect<string>(ReadText(Committed(RecordHash))).ToBe(RecordBytes);
    Expect<string>(LockText(CaseRoot)).ToBe(Lock);
    { A zero budget evicts the superseded checkpoint, never the history the
      lock's snapshot and record lie on. }
    Origin.Mode := scmServe;
    ExpectSuccess('zero budget', InstallWith(CaseRoot, ['install'],
      [REGISTRY_STATE_MAX_BYTES_ENV + '=0']));
    Expect<Boolean>(StoreHolds(State, Checkpoint)).ToBe(False);
    Expect<Boolean>(StoreHolds(State, Signature)).ToBe(False);
    Expect<Boolean>(StoreHolds(State, Snapshot)).ToBe(True);
    Expect<Boolean>(StoreHolds(State, RecordHash)).ToBe(True);
    Expect<Boolean>(DeleteFile(Committed(Snapshot))).ToBe(True);
    Expect<Boolean>(DeleteFile(Committed(RecordHash))).ToBe(True);
    Origin.Mode := scmFail;
    ExpectSuccess('offline restore after a zero budget', Install(CaseRoot,
      ['install', '--offline']));
    Expect<string>(ReadText(Committed(Snapshot))).ToBe(SnapshotBytes);
    Expect<string>(ReadText(Committed(RecordHash))).ToBe(RecordBytes);
    Expect<string>(LockText(CaseRoot)).ToBe(Lock);
    ExpectSuccess('frozen after restore', Install(CaseRoot, ['install', '--frozen']));
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestInvalidStateBudgetFailsBeforeRequests;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  CaseRoot := NewCase('invalid-budget');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    Before := Fingerprint(CaseRoot);
    ExpectFailure(InstallWith(CaseRoot, ['install'],
      [REGISTRY_STATE_MAX_BYTES_ENV + '=64MiB']), REGISTRY_STATE_MAX_BYTES_ENV
      + ' must be an integer from 0 through');
    Expect<Integer>(Origin.Requests).ToBe(0);
    ExpectUnchanged(CaseRoot, Before);
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.TestRepairReportsDocumentStore;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, State, Orphan, Before, Text: string;
  Run: TLwptResult;
begin
  CaseRoot := NewCase('repair-store');
  State := CaseRoot + '/state';
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('repair seed', Install(CaseRoot, ['install']));
    Orphan := PlantOrphan(State, 'orphan', 1000);
    WriteTextFile(RegistryStateDocumentsDirectory(State) + '/README', 'foreign');
    Before := TreeFingerprint(State);
    Run := InstallWith(CaseRoot, ['repair'],
      [PROJECT_NAME + '_WORKER_STATE_DIR=' + CaseRoot + '/workers']);
    ExpectSuccess('repair report', Run);
    Text := Output(Run);
    { The seed stored a checkpoint, its signature, a snapshot, and a record. }
    Expect<Boolean>(Pos('per-user registry document store ' + ExpandFileName(State)
      + ' holds 5 document(s), ', Text) > 0).ToBe(True);
    Expect<Boolean>(Pos('for 1 origin state file(s)', Text) > 0).ToBe(True);
    Expect<Boolean>(Pos('repair: 4 live document(s) (', Text) > 0).ToBe(True);
    Expect<Boolean>(Pos('; 1 evictable (1000 byte(s)) under a budget of 67108864 '
      + 'byte(s) (' + REGISTRY_STATE_MAX_BYTES_ENV + ')', Text) > 0).ToBe(True);
    Expect<Boolean>(Pos('ignored 1 foreign entry(ies)', Text) > 0).ToBe(True);
    Expect<Boolean>(Pos('removed nothing from per-user registry state', Text) > 0)
      .ToBe(True);
    { Repair is read-only here, even beyond the budget. }
    Run := InstallWith(CaseRoot, ['repair'],
      [PROJECT_NAME + '_WORKER_STATE_DIR=' + CaseRoot + '/workers',
       REGISTRY_STATE_MAX_BYTES_ENV + '=0']);
    ExpectSuccess('repair under a zero budget', Run);
    Expect<string>(TreeFingerprint(State)).ToBe(Before);
    Expect<Boolean>(FileExists(RegistryStateDocumentPath(State, Orphan))).ToBe(True);
    ExpectFailure(InstallWith(CaseRoot, ['repair'],
      [PROJECT_NAME + '_WORKER_STATE_DIR=' + CaseRoot + '/workers',
       REGISTRY_STATE_MAX_BYTES_ENV + '=-1']), 'registry_state_budget_invalid');
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

procedure TInstallRegistry.SetupTests;
begin
  Test('#62: a dependency selects a protocol-v1 origin explicitly',
    TestExplicitOriginInstall);
  Test('#62: an omitted identity records the advertised one, and a later '
    + 'different advertisement fails without writing state',
    TestAdvertisedIdentityIsLockedAndNeverReplaced);
  Test('#62: a record dependency on an undeclared origin fails with the '
    + 'declaration hint', TestUndeclaredRecordOriginFails);
  Test('#62: a diamond selects the highest common registry version',
    TestDiamondSelectsCommonVersion);
  Test('#62: an unsatisfiable registry set gives the complete diagnostic',
    TestUnsatisfiableSetFails);
  Test('#62: registry and local sources sharing a name conflict',
    TestRegistryAndLocalSourceConflict);
  Test('#62: origin and mirror URL changes keep identity and lock bytes',
    TestContactChangesKeepIdentity);
  Test('tamper: a bad checkpoint signature changes nothing',
    TestBadSignatureFails);
  Test('tamper: record bytes that do not match their hash change nothing',
    TestRecordHashMismatchFails);
  Test('tamper: archive bytes that do not match their hash change nothing',
    TestArchiveHashMismatchFails);
  Test('tamper: an extracted manifest with the wrong identity changes nothing',
    TestManifestIdentityMismatchFails);
  Test('tamper: a checkpoint lifetime over the limit changes nothing',
    TestOverlongCheckpointFails);
  Test('tamper: a checkpoint from the future changes nothing',
    TestFutureCheckpointFails);
  Test('tamper: same-sequence equivocation changes nothing',
    TestEquivocationFails);
  Test('tamper: discovery naming another origin changes nothing',
    TestDiscoveryNamingAnotherOriginFails);
  Test('tamper: an unsupported protocol changes nothing',
    TestUnsupportedProtocolFails);
  Test('tamper: a missing capability changes nothing',
    TestMissingCapabilityFails);
  Test('tamper: a checkpoint older than the lock is stale and changes nothing',
    TestOlderThanLockIsStale);
  Test('yank: a yanked version is never newly selected, even exactly',
    TestYankedExactVersionIsNotSelected);
  Test('yank: a locked yanked version stays with a warning and a new record',
    TestLockedYankedVersionStays);
  Test('#55: request failures and redirects advance to the next contact',
    TestRequestFailuresAdvance);
  Test('#55: a stale contact advances; all stale gives the stale diagnostic',
    TestStaleMirrorAdvances);
  Test('#55: a trust failure aborts before the next contact is asked',
    TestTrustFailureAborts);
  Test('#55: all request failures reuse a satisfying locked selection',
    TestAllUnreachableReusesLock);
  Test('#55: all request failures without a lock fail',
    TestAllUnreachableWithoutLockFails);
  Test('#55: an advertised identity recorded in the lock verifies a reused '
    + 'selection', TestUnreachableReuseUnderAdvertisedIdentity);
  Test('#55: a clock behind the recorded floor aborts before any request',
    TestClockBehindFloorAbortsBeforeRequests);
  Test('#55: archives come only from the contact that produced the proof',
    TestArchiveOnlyFromProofContact);
  Test('decision 11: acquisition alone never rewrites the lock; empty state '
    + 'restores from the recorded accepted state',
    TestNoChurnAndEmptyStateRestoration);
  Test('#62 and #55: a mirror install keeps the origin identity',
    TestMirrorInstallKeepsOriginIdentity);
  Test('decision 5: a workspace member resolves through the root registries',
    TestWorkspaceMemberUsesRootRegistries);
  Test('decision 5: a package manifest declaring a registry dependency fails',
    TestPackageManifestCannotDeclareRegistryDependency);
  Test('a release binary rejects an http://localhost contact at load',
    TestReleaseBinaryRejectsLocalhostHTTP);
  Test('per-user state is shared across projects and corruption names the '
    + 'file', TestPerUserStateIsSharedAndCorruptionNamed);
  Test('decision 2: workspace-only bindings survive two origins sharing a '
    + 'pin, and an ambiguous binding fails', TestWorkspaceOnlyBindingsSurviveSharedPin);
  Test('two aliases cannot resolve to one origin', TestTwoAliasesCannotShareAnOrigin);
  Test('a workspace member identity constrains an advertised root identity',
    TestMemberIdentityConstrainsAdvertisedRoot);
  Test('freshness: a checkpoint published during acquisition is accepted',
    TestCheckpointPublishedDuringAcquisitionIsAccepted);
  Test('freshness: a checkpoint expiring before publication changes nothing',
    TestCheckpointExpiringBeforePublicationFails);
  Test('decision 11: a per-user state write failure fails an unchanged install',
    TestStateWriteFailureFailsUnchangedInstall);
  Test('decision 11: a per-user state lease timeout fails an unchanged install',
    TestStateLeaseTimeoutFailsUnchangedInstall);
  Test('#55: a lagging pre-rotation contact is stale and fails over',
    TestLaggingPreRotationMirrorIsStale);
  Test('decision 8: a forged committed signature is never reused',
    TestDecision8RejectsForgedSignature);
  Test('rollback: a first install failing after the lock write leaves nothing',
    TestFirstInstallRollsBackAfterLockWrite);
  Test('rollback: proof replacement and pruning are restored on failure',
    TestProofReplacementAndPruningRollBack);
  Test('an unsigned lock floor never reaches per-user state',
    TestLockFloorNeverReachesPerUserState);
  Test('#55: a lagging contact lacking newer history is stale, with a healthy '
    + 'next contact and with none', TestLaggingMirrorLackingHistoryIsStale);
  Test('per-user state failure contract: an earlier origin''s authenticated '
    + 'advance survives a later origin''s failure',
    TestEarlierOriginAdvanceSurvivesLaterFailure);
  Test('#345: two install processes merge one per-user state directory under '
    + 'the store lease, and neither evicts the other''s accepted documents',
    TestConcurrentProcessesMergeSharedState);
  Test('#345: --offline restores locked proof documents from the store after '
    + 'eviction pressure', TestOfflineRestoreSurvivesEvictionPressure);
  Test('#345: an invalid document budget fails before any request',
    TestInvalidStateBudgetFailsBeforeRequests);
  Test('#345: repair reports the document store and removes nothing',
    TestRepairReportsDocumentStore);
end;

begin
  TestRunnerProgram.AddSuite(TInstallRegistry.Create(
    'install: registry dependencies'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
