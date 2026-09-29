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
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryConsumer,
  Tests.Scratch;

const
  DAY = 24 * 60 * 60;
  IDENTITY = 'https://packages.example.com';
  OTHER_IDENTITY = 'https://other.example.com';

type
  TTamper = procedure(ARegistry: TSyntheticRegistry;
    AContact: TSyntheticContact) of object;

  TInstallRegistry = class(TTestSuite)
  private
    FScratch, FReleaseBinary: string;
    FCount: Integer;
    function NewCase(const AName: string): string;
    procedure WriteProject(const ACase, ARegistries, ADependencies: string;
      const AExtra: string = '');
    function Install(const ACase: string;
      const AArguments: array of string): TLwptResult;
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
    procedure TestFrozenAndOfflineFailClosed;
    procedure TestPerUserStateIsSharedAndCorruptionNamed;
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
  Result := FScratch + '/' + IntToStr(FCount) + '-' + AName;
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

procedure TInstallRegistry.ExpectSuccess(const ALabel: string;
  const ARun: TLwptResult);
begin
  if ARun.ExitCode <> 0 then
    WriteLn('--- ', ALabel, ' ---'#10, Output(ARun), '---');
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

procedure TInstallRegistry.ExpectFailure(const ARun: TLwptResult;
  const AText: string);
begin
  if (ARun.ExitCode = 0) or (Pos(AText, Output(ARun)) = 0) then
    WriteLn('--- expected failure containing "', AText, '" ---'#10,
      Output(ARun), '---');
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
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
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
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
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
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
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

procedure TInstallRegistry.TestFrozenAndOfflineFailClosed;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, Before: string;
  Requests: Integer;
begin
  CaseRoot := NewCase('frozen-offline');
  Registry := NewRegistry(IDENTITY, Origin);
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Window(Registry);
    WriteProject(CaseRoot, Declaration('corp', Registry, Origin.BaseURL, []),
      'json = "registry:json"'#10);
    ExpectSuccess('frozen baseline', Install(CaseRoot, ['install']));
    Before := Fingerprint(CaseRoot);
    Requests := Origin.Requests;
    ExpectFailure(Install(CaseRoot, ['install', '--frozen']), 'cannot yet be verified');
    ExpectFailure(Install(CaseRoot, ['install', '--offline']), 'cannot yet be restored');
    Expect<Integer>(Origin.Requests).ToBe(Requests);
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
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
  Test('--frozen and --offline fail closed on registry dependencies without '
    + 'a request', TestFrozenAndOfflineFailClosed);
  Test('per-user state is shared across projects and corruption names the '
    + 'file', TestPerUserStateIsSharedAndCorruptionNamed);
end;

begin
  TestRunnerProgram.AddSuite(TInstallRegistry.Create(
    'install: registry dependencies'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
