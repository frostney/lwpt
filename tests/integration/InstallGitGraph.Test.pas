program InstallGitGraph.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.HTTPMockServer,
  Tests.LwptSubprocess,
  Tests.Scratch,
  Tests.TarSynth;

type
  TInstallGitGraph = class(TTestSuite)
  private
    FOriginalDir, FScratch, FFixtureRoot, FCacheRoot: string;
    procedure WriteRoot(const ARoot, AName, ADependencies: string);
    procedure WriteRefs(const ARepository, AContent: string);
    procedure WriteArchive(const AName, ACommit, AManifest: string);
    procedure PrepareOfflineSeed(const AScenario: string;
      out ARoot, ALockText: string);
    function RunInstall(const ARoot: string;
      const AArguments: array of string): TLwptResult;
    function RequestCount(const ALine: string): Integer;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestMultiRoundGlobalConflictPublishesNothing;
    procedure TestLateConstraintIsIncludedInTerminalConflict;
    procedure TestMixedTagSHAUsesImmutableFetchAndFrozenIdentity;
    procedure TestSecondRoundReusesRefAndCandidateCaches;
    procedure TestVerifiedArchiveCacheReusesLockedBytesAcrossProjects;
    procedure TestOfflineCommittedArchiveRestoresProjectState;
    procedure TestOfflineMissPreservesCommittedState;
    procedure TestOfflineCorruptArchiveIsNotFetchedAround;
    procedure TestOfflineManifestDriftFailsBeforePublication;
    procedure TestOfflineCompatibleDriftFailsBeforePublication;
    procedure TestOfflineAcceptsUnambiguousEarlyV3Lock;
    procedure TestOfflineAcceptsEarlyV3SHAIdentity;
    procedure TestOfflineRestoresLocalAndWorkspaceDependencies;
    procedure TestOfflineRestoresDirectURLWithoutTransport;
    procedure TestOfflineRequiresExistingLock;
    procedure TestOfflineAndFrozenAreMutuallyExclusive;
    procedure TestMovedTagBehindEarlyLockFailsUntilAccepted;
    procedure TestMovedLockedTagFailsUntilAccepted;
    procedure TestMovedLockedTagFailsManifestMutation;
    procedure TestMovedBranchKeepsFollowing;
    procedure TestAcceptMovedTagsRequiresOnlineInstall;
    procedure TestMovedTagRespelledAsSemverFails;
    procedure TestTagReplacedByBranchFails;
    procedure TestBranchReplacedByTagIsNotAMovedTag;
    procedure TestLockWithoutRefKindFailsClosedForMovedBranch;
    procedure TestLockedCommitMustReproduceLockedArchive;
    procedure TestSharedCandidateCannotBypassLockedArchive;
    procedure TestLegacyTagCannotBecomeMovableBranch;
    procedure TestSurvivingTagWinsOverSameNamedBranch;
    procedure TestOfflineSharedCandidateIsCheckedBeforeExtraction;
    procedure TestDeepProjectRootExtractsArchive;
  end;

const
  PARENT_A_COMMIT = '1111111111111111111111111111111111111111';
  PARENT_B_COMMIT = '2222222222222222222222222222222222222222';
  PARENT_C_COMMIT = '3333333333333333333333333333333333333333';
  SHARED_COMMIT = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  MUTATED_SHARED_COMMIT = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  PARENT_V1_COMMIT = 'cccccccccccccccccccccccccccccccccccccccc';
  PARENT_V2_COMMIT = 'dddddddddddddddddddddddddddddddddddddddd';
  ANCHOR_COMMIT = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
  ARCHIVE_ORIGIN_ENV = PROJECT_NAME + '_TEST_ARCHIVE_ORIGIN';
  ARCHIVE_TIMEOUT_ENV = PROJECT_NAME + '_TEST_ARCHIVE_TIMEOUT_MS';

function ReadText(const APath: string): string;
var Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TInstallGitGraph.TestSecondRoundReusesRefAndCandidateCaches;
var Root, LockText, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/second-round';
  WriteRoot(Root, 'second-round',
    'parent = "fixture/parent@>=1.0.0 <3.0.0"'#10
    + 'anchor = "fixture/anchor@1.0.0"'#10);
  WriteRefs('parent',
    'tag|v1.0.0|' + PARENT_V1_COMMIT + '|'#10
    + 'tag|v2.0.0|' + PARENT_V2_COMMIT + '|'#10);
  WriteRefs('anchor', 'tag|v1.0.0|' + ANCHOR_COMMIT + '|'#10);
  WriteArchive('parent', PARENT_V1_COMMIT,
    '[package]'#10 + 'name = "parent"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteArchive('parent', PARENT_V2_COMMIT,
    '[package]'#10 + 'name = "parent"'#10 + 'version = "2.0.0"'#10
    + 'units = ["source"]'#10);
  WriteArchive('anchor', ANCHOR_COMMIT,
    '[package]'#10 + 'name = "anchor"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'parent = "fixture/parent@<2.0.0"'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  if Run.ExitCode <> 0 then
    WriteLn('--- second round ---'#10, Combined, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('resolver round 2', Combined) > 0).ToBe(True);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedRef = "v1.0.0"', LockText) > 0)
    .ToBe(True);
  Expect<Integer>(RequestCount('refs|parent')).ToBe(1);
  Expect<Integer>(RequestCount('refs|anchor')).ToBe(1);
  Expect<Integer>(RequestCount(
    'archive|parent|' + PARENT_V2_COMMIT)).ToBe(1);
  Expect<Integer>(RequestCount(
    'archive|parent|' + PARENT_V1_COMMIT)).ToBe(1);
  Expect<Integer>(RequestCount(
    'archive|anchor|' + ANCHOR_COMMIT)).ToBe(1);
end;

procedure RemoveAdditiveIdentityFields(const APath: string);
var Lines: TStringList; i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    for i := Lines.Count - 1 downto 0 do
      if (Pos('resolvedCommit = ', Lines[i]) = 1)
         or (Pos('sourceIdentity = ', Lines[i]) = 1)
         or (Pos('constraintFingerprint = ', Lines[i]) = 1) then
        Lines.Delete(i);
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

procedure RemoveLockKey(const APath, AKey: string);
var Lines: TStringList; LineIndex: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    for LineIndex := Lines.Count - 1 downto 0 do
      if Pos(AKey + ' = ', Lines[LineIndex]) = 1 then Lines.Delete(LineIndex);
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

procedure RemoveResolvedCommit(const APath: string);
var Lines: TStringList; i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    for i := Lines.Count - 1 downto 0 do
      if Pos('resolvedCommit = ', Lines[i]) = 1 then Lines.Delete(i);
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

procedure TInstallGitGraph.WriteRoot(const ARoot, AName,
  ADependencies: string);
begin
  ForceDirectories(ARoot + '/source');
  WriteTextFile(ARoot + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteTextFile(ARoot + '/lwpt.toml',
    '[package]'#10 + 'name = "' + AName + '"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + '[dependencies]'#10 + ADependencies);
end;

procedure TInstallGitGraph.WriteRefs(const ARepository, AContent: string);
begin
  ForceDirectories(FFixtureRoot + '/refs');
  WriteTextFile(FFixtureRoot + '/refs/' + ARepository + '.refs', AContent);
end;

procedure TInstallGitGraph.WriteArchive(const AName, ACommit,
  AManifest: string);
var Entries: TByteArrays; UnitName, RootName, Path: string;
begin
  RootName := AName + '-fixture';
  UnitName := StringReplace(AName, '-', '_', [rfReplaceAll]);
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry(RootName + '/lwpt.toml',
    BytesOf(AManifest));
  Entries[1] := MakeRegularFileEntry(
    RootName + '/source/' + UnitName + '.pas',
    BytesOf('unit ' + UnitName + ';'#10 + 'interface'#10
      + 'implementation'#10 + 'end.'#10));
  Path := FFixtureRoot + '/archives/' + AName + '/' + ACommit + '.tar.gz';
  ForceDirectories(ExtractFileDir(Path));
  WriteBytesToFile(Path, Gzip(BuildTar(Entries)));
end;

procedure TInstallGitGraph.PrepareOfflineSeed(const AScenario: string;
  out ARoot, ALockText: string);
var Run: TLwptResult;
begin
  FCacheRoot := FScratch + '/' + AScenario + '-cache';
  RecursiveDelete(FCacheRoot);
  ARoot := FScratch + '/' + AScenario + '-seed';
  WriteRoot(ARoot, AScenario,
    'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');
  Run := RunInstall(ARoot, ['install']);
  DumpRunFailure('offline seed ' + AScenario, Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  ALockText := ReadBinaryFile(ARoot + '/lwpt.lock');
end;

function TInstallGitGraph.RunInstall(const ARoot: string;
  const AArguments: array of string): TLwptResult;
begin
  Result := RunLwptTesting(AArguments, ARoot,
    [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot,
     PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot]);
end;

function TInstallGitGraph.RequestCount(const ALine: string): Integer;
var Lines: TStringList; i: Integer;
begin
  Result := 0;
  if not FileExists(FFixtureRoot + '/requests.log') then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FFixtureRoot + '/requests.log');
    for i := 0 to Lines.Count - 1 do
      if Lines[i] = ALine then Inc(Result);
  finally
    Lines.Free;
  end;
end;

procedure TInstallGitGraph.BeforeAll;
begin
  FOriginalDir := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('install-git-graph');
  FFixtureRoot := FScratch + '/git-fixture';
  FCacheRoot := FScratch + '/user-cache';
  RecursiveDelete(FScratch);
  ForceDirectories(FFixtureRoot);
end;

procedure TInstallGitGraph.
  TestVerifiedArchiveCacheReusesLockedBytesAcrossProjects;
var
  FirstRoot, SecondRoot, ArchivePath, LockText, LockBytes, Combined,
    OriginalLockBytes: string;
  Run: TLwptResult;
begin
  FirstRoot := FScratch + '/cache-first-project';
  SecondRoot := FScratch + '/cache-second-project';
  WriteRoot(FirstRoot, 'cache-project',
    'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(FirstRoot, ['install']);
  if Run.ExitCode <> 0 then
    WriteLn('--- first cache install ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(1);
  OriginalLockBytes := ReadBinaryFile(FirstRoot + '/lwpt.lock');

  { A second checkout has the same committed manifest + lock identity but its
    project archive/module state is deliberately absent. Remove the fixture
    archive too: success can now come only from the verified per-user object. }
  ForceDirectories(SecondRoot + '/source');
  CopyFileContent(FirstRoot + '/lwpt.toml', SecondRoot + '/lwpt.toml');
  CopyFileContent(FirstRoot + '/lwpt.lock', SecondRoot + '/lwpt.lock');
  WriteTextFile(SecondRoot + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(SecondRoot, ['install', '--offline']);
  Combined := Run.Stdout + Run.Stderr;
  if Run.ExitCode <> 0 then
    WriteLn('--- second cache install ---'#10, Combined, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('reused verified archive for shared', Combined) > 0)
    .ToBe(True);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(0);
  ArchivePath := SecondRoot + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  Expect<Boolean>(FileExists(ArchivePath)).ToBe(True);
  LockBytes := ReadBinaryFile(SecondRoot + '/lwpt.lock');
  Expect<string>(LockBytes).ToBe(OriginalLockBytes);
  LockText := ReadText(SecondRoot + '/lwpt.lock');
  Expect<Boolean>(Pos('archiveHash = "sha256:' + SHA256File(ArchivePath)
    + '"', LockText) > 0).ToBe(True);

  Run := RunInstall(SecondRoot, ['install', '--frozen']);
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineCommittedArchiveRestoresProjectState;
var Root, LockText, ArchivePath: string; Run: TLwptResult;
begin
  PrepareOfflineSeed('offline-project-archive', Root, LockText);
  ArchivePath := Root + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  RecursiveDelete(FCacheRoot);
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  DumpRunFailure('offline committed archive restore', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ArchivePath)).ToBe(True);
  Expect<Boolean>(FileExists(Root
    + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineMissPreservesCommittedState;
var SeedRoot, Root, LockText, Combined, OriginalCfg,
  OriginalSentinel: string; Run: TLwptResult;
begin
  PrepareOfflineSeed('offline-miss', SeedRoot, LockText);
  Root := FScratch + '/offline-miss-recovery';
  ForceDirectories(Root + '/.lwpt/modules/sentinel');
  CopyFileContent(SeedRoot + '/lwpt.toml', Root + '/lwpt.toml');
  CopyFileContent(SeedRoot + '/lwpt.lock', Root + '/lwpt.lock');
  WriteTextFile(Root + '/.lwpt/modules/sentinel/keep.txt', 'keep'#10);
  WriteTextFile(Root + '/lwpt.cfg', 'existing cfg'#10);
  OriginalCfg := ReadBinaryFile(Root + '/lwpt.cfg');
  OriginalSentinel := ReadBinaryFile(Root
    + '/.lwpt/modules/sentinel/keep.txt');
  RecursiveDelete(FCacheRoot);
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('[offline]', Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.cfg')).ToBe(OriginalCfg);
  Expect<string>(ReadBinaryFile(Root
    + '/.lwpt/modules/sentinel/keep.txt')).ToBe(OriginalSentinel);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(False);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineCorruptArchiveIsNotFetchedAround;
var Root, LockText, ArchivePath, Combined, OriginalArchive: string;
  Run: TLwptResult;
begin
  PrepareOfflineSeed('offline-corrupt', Root, LockText);
  ArchivePath := Root + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  WriteTextFile(ArchivePath, 'corrupt committed archive'#10);
  OriginalArchive := ReadBinaryFile(ArchivePath);
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('archive hash mismatch', Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(ArchivePath)).ToBe(OriginalArchive);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(False);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineManifestDriftFailsBeforePublication;
var Root, LockText, ArchivePath, ArchiveHash, Combined: string;
  Run: TLwptResult;
begin
  PrepareOfflineSeed('offline-drift', Root, LockText);
  ArchivePath := Root + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  ArchiveHash := SHA256File(ArchivePath);
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  WriteRoot(Root, 'offline-drift',
    'shared = "fixture/shared@^2.0.0"'#10);
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('[offline]', Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<string>(SHA256File(ArchivePath)).ToBe(ArchiveHash);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(False);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
end;

procedure TInstallGitGraph.
  TestOfflineCompatibleDriftFailsBeforePublication;
var
  Root, LockText, ModuleHash, ArchiveHash, CfgBytes, Combined: string;
  Run: TLwptResult;
begin
  PrepareOfflineSeed('offline-compatible-drift', Root, LockText);
  ModuleHash := HashTree(Root + '/.lwpt/modules/shared');
  ArchiveHash := SHA256File(Root
    + '/.lwpt/archives/shared-v1.0.0.tar.gz');
  CfgBytes := ReadBinaryFile(Root + '/lwpt.cfg');
  WriteRoot(Root, 'offline-compatible-drift',
    'shared = "fixture/shared@>=1.0.0 <2.0.0"'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunLwptTesting(['install', '--offline'], Root,
    [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot,
     PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot,
     PROJECT_NAME + '_TEST_HALT_AFTER_MODULE_RETAIN=shared']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>((Run.ExitCode <> 0) and (Run.ExitCode <> 87)).ToBe(True);
  Expect<Boolean>(Pos('accumulated constraints changed', Combined) > 0)
    .ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.cfg')).ToBe(CfgBytes);
  Expect<string>(HashTree(Root + '/.lwpt/modules/shared')).ToBe(ModuleHash);
  Expect<string>(SHA256File(Root
    + '/.lwpt/archives/shared-v1.0.0.tar.gz')).ToBe(ArchiveHash);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineAcceptsUnambiguousEarlyV3Lock;
var Root, LockText: string; Run: TLwptResult;
begin
  PrepareOfflineSeed('offline-early-v3', Root, LockText);
  RemoveAdditiveIdentityFields(Root + '/lwpt.lock');
  LockText := ReadBinaryFile(Root + '/lwpt.lock');
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  RecursiveDelete(FCacheRoot);
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  DumpRunFailure('offline early v3 restore', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<Boolean>(FileExists(Root
    + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(True);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineAcceptsEarlyV3SHAIdentity;
var Root, LockText: string; Run: TLwptResult;
begin
  FCacheRoot := FScratch + '/offline-early-v3-sha-cache';
  RecursiveDelete(FCacheRoot);
  Root := FScratch + '/offline-early-v3-sha';
  WriteRoot(Root, 'offline-early-v3-sha',
    'shared = "fixture/shared@' + SHARED_COMMIT + '"'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('offline early v3 SHA seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  RemoveAdditiveIdentityFields(Root + '/lwpt.lock');
  LockText := ReadBinaryFile(Root + '/lwpt.lock');
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  RecursiveDelete(FCacheRoot);
  SysUtils.DeleteFile(FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  DumpRunFailure('offline early v3 SHA restore', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<Boolean>(FileExists(Root
    + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(True);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineRestoresLocalAndWorkspaceDependencies;
var Root, LockText: string; Run: TLwptResult;
begin
  FCacheRoot := FScratch + '/offline-local-cache';
  Root := FScratch + '/offline-local-workspace';
  WriteRoot(Root + '/local-dep', 'local-dep', '');
  WriteRoot(Root + '/packages/workspace-dep', 'workspace-dep', '');
  ForceDirectories(Root + '/source');
  WriteTextFile(Root + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteTextFile(Root + '/lwpt.toml',
    '[package]'#10 + 'name = "offline-local-workspace"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + '[dependencies]'#10 + 'local-dep = "./local-dep"'#10
    + 'workspace-dep = "workspace:^1.0.0"'#10
    + '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('offline local/workspace seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockText := ReadBinaryFile(Root + '/lwpt.lock');
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  DumpRunFailure('offline local/workspace restore', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(Root
    + '/.lwpt/modules/local-dep/source/main.pas')).ToBe(True);
  Expect<Boolean>(FileExists(Root
    + '/.lwpt/modules/workspace-dep/source/main.pas')).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
end;

procedure TInstallGitGraph.TestOfflineRestoresDirectURLWithoutTransport;
var
  Root, LockText, ArchivePath: string;
  Entries: TByteArrays;
  ArchiveBytes: TBytes;
  Mock: TMockHTTPServer;
  Refused: TMockRefusedEndpoint;
  Run: TLwptResult;
begin
  FCacheRoot := FScratch + '/offline-direct-url-cache';
  RecursiveDelete(FCacheRoot);
  Root := FScratch + '/offline-direct-url';
  WriteRoot(Root, 'offline-direct-url',
    'direct = "https://example.invalid/direct.tar.gz"'#10);
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry('direct-fixture/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "direct"'#10
      + 'version = "1.0.0"'#10 + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry(
    'direct-fixture/source/direct.pas',
    BytesOf('unit direct;'#10 + 'interface'#10
      + 'implementation'#10 + 'end.'#10));
  ArchiveBytes := Gzip(BuildTar(Entries));
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(ArchiveBytes));
  try
    Mock.Start;
    Run := RunLwptTesting(['install'], Root,
      [PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot,
       ARCHIVE_ORIGIN_ENV + '=http://127.0.0.1:'
         + IntToStr(Mock.Port),
       ARCHIVE_TIMEOUT_ENV + '=5000']);
    Expect<Boolean>(Mock.WaitDone(5000)).ToBe(True);
    DumpRunFailure('offline direct URL seed', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
  finally
    Mock.Free;
  end;
  LockText := ReadBinaryFile(Root + '/lwpt.lock');
  ArchivePath := Root + '/.lwpt/archives/direct-url.tar.gz';
  Expect<Boolean>(FileExists(ArchivePath)).ToBe(True);
  RecursiveDelete(Root + '/.lwpt/modules');
  SysUtils.DeleteFile(Root + '/lwpt.cfg');
  RecursiveDelete(FCacheRoot);

  Refused := TMockRefusedEndpoint.Create;
  try
    Run := RunLwptTesting(['install', '--offline'], Root,
      [PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot,
       ARCHIVE_ORIGIN_ENV + '=http://' + Refused.Host + ':'
         + IntToStr(Refused.Port),
       ARCHIVE_TIMEOUT_ENV + '=5000']);
  finally
    Refused.Free;
  end;
  DumpRunFailure('offline direct URL restore', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(Root
    + '/.lwpt/modules/direct/source/direct.pas')).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockText);
end;

procedure TInstallGitGraph.TestOfflineAndFrozenAreMutuallyExclusive;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/offline-frozen-conflict';
  WriteRoot(Root, 'offline-frozen-conflict', '');
  Run := RunLwpt(['install', '--offline', '--frozen'], Root);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('--offline cannot be combined with --frozen',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(False);
end;

procedure TInstallGitGraph.TestOfflineRequiresExistingLock;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/offline-no-lock';
  WriteRoot(Root, 'offline-no-lock', 'shared = "fixture/shared@^1.0.0"'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install', '--offline']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('[offline] lockfile not found', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(False);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(False);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
end;

procedure TInstallGitGraph.
  TestMovedTagBehindEarlyLockFailsUntilAccepted;
var
  Root, ArchivePath, LockText, LockBefore, Combined: string;
  Run: TLwptResult;
begin
  Root := FScratch + '/moved-tag-with-early-lock';
  WriteRoot(Root, 'moved-tag-with-early-lock',
    'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  if Run.ExitCode <> 0 then
    WriteLn('--- original tag install ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  RemoveResolvedCommit(Root + '/lwpt.lock');
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');

  { An early schema-v3 lock records no commit, so the move is caught by the
    archive it pinned: the new commit serves different bytes. }
  WriteRefs('shared', 'tag|v1.0.0|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('dependency "shared": tag "v1.0.0" moved upstream '
    + 'since it was locked: its archive no longer matches lwpt.lock',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('install --accept-moved-tags', Combined) > 0)
    .ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);

  WriteTextFile(FFixtureRoot + '/requests.log', '');
  Run := RunInstall(Root, ['install', '--accept-moved-tags']);
  Combined := Run.Stdout + Run.Stderr;
  if Run.ExitCode <> 0 then
    WriteLn('--- moved tag install ---'#10, Combined, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + MUTATED_SHARED_COMMIT)).ToBe(1);
  ArchivePath := Root + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedCommit = "' + MUTATED_SHARED_COMMIT + '"',
    LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedRefKind = "tag"', LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('archiveHash = "sha256:' + SHA256File(ArchivePath)
    + '"', LockText) > 0).ToBe(True);
end;

procedure TInstallGitGraph.TestMovedTagRespelledAsSemverFails;
var Root, LockBefore, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/moved-tag-respelled';
  WriteRoot(Root, 'moved-tag-respelled', 'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('respelled tag seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');

  { v1.0.0 is deleted and the same version is re-published as 1.0.0 at a
    different commit: the same SemVer tag moved. }
  WriteRefs('shared', 'tag|1.0.0|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('tag "1.0.0" moved upstream since it was locked '
    + '(locked commit ' + SHARED_COMMIT + ', now advertised at '
    + MUTATED_SHARED_COMMIT + ')', Combined) > 0).ToBe(True);
  Expect<Integer>(RequestCount(
    'archive|shared|' + MUTATED_SHARED_COMMIT)).ToBe(0);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
end;

procedure TInstallGitGraph.TestTagReplacedByBranchFails;
var Root, LockBefore, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/tag-replaced-by-branch';
  WriteRoot(Root, 'tag-replaced-by-branch',
    'shared = "fixture/shared@release"'#10);
  WriteRefs('shared', 'tag|release|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('tag seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('resolvedRefKind = "tag"',
    ReadText(Root + '/lwpt.lock')) > 0).ToBe(True);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');

  WriteRefs('shared', 'branch|release|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('locked tag "release" (commit ' + SHARED_COMMIT
    + ') is now advertised only as branch "release" at '
    + MUTATED_SHARED_COMMIT, Combined) > 0).ToBe(True);
  Expect<Integer>(RequestCount(
    'archive|shared|' + MUTATED_SHARED_COMMIT)).ToBe(0);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
end;

procedure TInstallGitGraph.TestBranchReplacedByTagIsNotAMovedTag;
var Root, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/branch-replaced-by-tag';
  WriteRoot(Root, 'branch-replaced-by-tag', 'shared = "fixture/shared@main"'#10);
  WriteRefs('shared', 'branch|main|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('branch seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);

  WriteRefs('shared', 'tag|main|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('branch replaced by tag', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedCommit = "' + MUTATED_SHARED_COMMIT + '"',
    LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedRefKind = "tag"', LockText) > 0).ToBe(True);
end;

procedure TInstallGitGraph.TestLockWithoutRefKindFailsClosedForMovedBranch;
var Root, LockBefore, Combined, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/moved-branch-without-kind';
  WriteRoot(Root, 'moved-branch-without-kind',
    'shared = "fixture/shared@main"'#10);
  WriteRefs('shared', 'branch|main|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('branch seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  { A lock written before ref kinds were recorded. }
  RemoveLockKey(Root + '/lwpt.lock', 'resolvedRefKind');
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');

  WriteRefs('shared', 'branch|main|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('cannot prove "main" was a branch that may move',
    Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);

  Run := RunInstall(Root, ['install', '--accept-moved-tags']);
  DumpRunFailure('accept moved branch', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedRefKind = "branch"', LockText) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('resolvedCommit = "' + MUTATED_SHARED_COMMIT + '"',
    LockText) > 0).ToBe(True);
end;

procedure TInstallGitGraph.TestLockedCommitMustReproduceLockedArchive;
var Root, LockBefore, Combined, OtherCache: string; Run: TLwptResult;
begin
  Root := FScratch + '/locked-archive-identity';
  FCacheRoot := FScratch + '/locked-archive-identity-cache';
  RecursiveDelete(FCacheRoot);
  WriteRoot(Root, 'locked-archive-identity',
    'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('archive identity seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');

  { The forge now serves different bytes for the same locked commit, and
    the per-user cache that held the verified bytes is gone. }
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "6.6.6"'#10
    + 'units = ["source"]'#10);
  OtherCache := FScratch + '/locked-archive-identity-cold-cache';
  RecursiveDelete(OtherCache);
  FCacheRoot := OtherCache;
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('the archive served for locked commit ' + SHARED_COMMIT
    + ' no longer matches lwpt.lock', Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);

  { An unreachable ref advertisement falls back to the locked identity; the
    fallback must still reproduce the locked bytes. }
  SysUtils.DeleteFile(FFixtureRoot + '/refs/shared.refs');
  RecursiveDelete(OtherCache);
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('reusing verified lockfile identity', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('the archive served for locked commit ' + SHARED_COMMIT
    + ' no longer matches lwpt.lock', Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
  Expect<Boolean>(Pos('version = "1.0.0"',
    ReadText(Root + '/.lwpt/modules/shared/lwpt.toml')) > 0).ToBe(True);

  { Later cases share the fixture root and the default cache. }
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  FCacheRoot := FScratch + '/user-cache';
end;

procedure TInstallGitGraph.TestMovedLockedTagFailsUntilAccepted;
var
  Root, LockBefore, CfgBefore, ModuleBefore, Combined, LockText,
    ArchivePath: string;
  Run: TLwptResult;
begin
  Root := FScratch + '/moved-locked-tag';
  WriteRoot(Root, 'moved-locked-tag', 'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('locked tag seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');
  CfgBefore := ReadBinaryFile(Root + '/lwpt.cfg');
  ModuleBefore := ReadBinaryFile(Root + '/.lwpt/modules/shared/lwpt.toml');

  { Upstream force-moves v1.0.0; the manifest requirement is unchanged. }
  WriteRefs('shared', 'tag|v1.0.0|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('dependency "shared": tag "v1.0.0" moved upstream',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('locked commit ' + SHARED_COMMIT, Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('now advertised at ' + MUTATED_SHARED_COMMIT,
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('install --accept-moved-tags', Combined) > 0)
    .ToBe(True);
  { Nothing was fetched or published for the moved commit. }
  Expect<Integer>(RequestCount(
    'archive|shared|' + MUTATED_SHARED_COMMIT)).ToBe(0);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.cfg')).ToBe(CfgBefore);
  Expect<string>(ReadBinaryFile(Root + '/.lwpt/modules/shared/lwpt.toml'))
    .ToBe(ModuleBefore);

  Run := RunInstall(Root, ['install', '--accept-moved-tags']);
  DumpRunFailure('accept moved tag', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + MUTATED_SHARED_COMMIT)).ToBe(1);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedRef = "v1.0.0"', LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedCommit = "' + MUTATED_SHARED_COMMIT + '"',
    LockText) > 0).ToBe(True);
  ArchivePath := Root + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  Expect<Boolean>(Pos('archiveHash = "sha256:' + SHA256File(ArchivePath)
    + '"', LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('version = "1.0.1"',
    ReadText(Root + '/.lwpt/modules/shared/lwpt.toml')) > 0).ToBe(True);

  { Once accepted, the new commit is the locked identity again. }
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('install after acceptance', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TInstallGitGraph.TestMovedLockedTagFailsManifestMutation;
var Root, ManifestBefore, LockBefore, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/moved-tag-mutation';
  WriteRoot(Root, 'moved-tag-mutation', 'shared = "fixture/shared@^1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('mutation seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  ManifestBefore := ReadBinaryFile(Root + '/lwpt.toml');
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');
  ForceDirectories(Root + '/vendor/leaf/source');
  WriteTextFile(Root + '/vendor/leaf/lwpt.toml',
    '[package]'#10 + 'name = "leaf"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(Root + '/vendor/leaf/source/leaf.pas',
    'unit leaf;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);

  WriteRefs('shared', 'tag|v1.0.0|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);

  { add runs the same install transaction: it refuses the moved tag and
    leaves the manifest untouched. Acceptance stays an explicit install. }
  Run := RunInstall(Root, ['add', './vendor/leaf']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('tag "v1.0.0" moved upstream', Combined) > 0)
    .ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.toml')).ToBe(ManifestBefore);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
end;

procedure TInstallGitGraph.TestMovedBranchKeepsFollowing;
var Root, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/moved-branch';
  WriteRoot(Root, 'moved-branch', 'shared = "fixture/shared@main"'#10);
  WriteRefs('shared', 'branch|main|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('branch seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);

  WriteRefs('shared', 'branch|main|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('moved branch', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedRef = "main"', LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedRefKind = "branch"', LockText) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('resolvedCommit = "' + MUTATED_SHARED_COMMIT + '"',
    LockText) > 0).ToBe(True);
end;

procedure TInstallGitGraph.TestAcceptMovedTagsRequiresOnlineInstall;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/accept-moved-tags-modes';
  WriteRoot(Root, 'accept-moved-tags-modes', '');
  Run := RunLwpt(['install', '--frozen', '--accept-moved-tags'], Root);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('--accept-moved-tags cannot be combined with --frozen '
    + 'or --offline', Run.Stderr) > 0).ToBe(True);
  Run := RunLwpt(['install', '--offline', '--accept-moved-tags'], Root);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('--accept-moved-tags cannot be combined with --frozen '
    + 'or --offline', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
end;

{ Two dependencies can name the same repository and commit. The first one
  fetched becomes the resolver candidate that the second reuses, so the
  reuse must still reproduce the second one's locked archive. }
procedure TInstallGitGraph.TestSharedCandidateCannotBypassLockedArchive;
var Root, LockBefore, Combined, SavedCache: string; Run: TLwptResult;
begin
  SavedCache := FCacheRoot;
  Root := FScratch + '/shared-candidate';
  FCacheRoot := FScratch + '/shared-candidate-cache';
  RecursiveDelete(FCacheRoot);
  WriteRoot(Root, 'shared-candidate', 'z = "fixture/shared@v1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('z', SHARED_COMMIT,
    '[package]'#10 + 'name = "z"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('shared candidate seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');

  { A new dependency, resolved first, fetches different bytes for the same
    repository and commit; the verified cache is cold. }
  WriteRoot(Root, 'shared-candidate', 'a = "fixture/shared@v1.0.0"'#10
    + 'z = "fixture/shared@v1.0.0"'#10);
  WriteArchive('a', SHARED_COMMIT,
    '[package]'#10 + 'name = "a"'#10 + 'version = "6.6.6"'#10
    + 'units = ["source"]'#10);
  FCacheRoot := FScratch + '/shared-candidate-cold-cache';
  RecursiveDelete(FCacheRoot);
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  FCacheRoot := SavedCache;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('dependency "z": the archive served for locked commit '
    + SHARED_COMMIT + ' no longer matches lwpt.lock', Combined) > 0)
    .ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
end;

{ A lock written before ref kinds were recorded cannot prove whether a ref
  was a tag. Seeing it as a branch at the same commit must not quietly
  grant it permission to move later. }
procedure TInstallGitGraph.TestLegacyTagCannotBecomeMovableBranch;
var Root, LockText, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/legacy-tag-to-branch';
  WriteRoot(Root, 'legacy-tag-to-branch',
    'shared = "fixture/shared@release"'#10);
  WriteRefs('shared', 'tag|release|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('legacy tag seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  RemoveLockKey(Root + '/lwpt.lock', 'resolvedRefKind');

  { Same commit, now advertised as a branch: the install may proceed, but
    the lock keeps the kind unknown. }
  WriteRefs('shared', 'branch|release|' + SHARED_COMMIT + '|'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('legacy ref now a branch', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedRefKind', LockText) > 0).ToBe(False);

  { The branch then moves: still unproven, so it fails closed. }
  WriteRefs('shared', 'branch|release|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteArchive('shared', MUTATED_SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.1"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('cannot prove "release" was a branch that may move',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedCommit = "' + SHARED_COMMIT + '"',
    ReadText(Root + '/lwpt.lock')) > 0).ToBe(True);
end;

{ A locked tag that is still advertised is not replaced just because a
  same-named branch at the same commit is listed first. }
procedure TInstallGitGraph.TestSurvivingTagWinsOverSameNamedBranch;
var Root, LockText: string; Run: TLwptResult; Order: Integer;
begin
  for Order := 0 to 1 do
  begin
    Root := FScratch + '/surviving-tag-' + IntToStr(Order);
    WriteRoot(Root, 'surviving-tag', 'shared = "fixture/shared@release"'#10);
    WriteRefs('shared', 'tag|release|' + SHARED_COMMIT + '|'#10);
    WriteArchive('shared', SHARED_COMMIT,
      '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
      + 'units = ["source"]'#10);
    Run := RunInstall(Root, ['install']);
    DumpRunFailure('surviving tag seed', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);

    if Order = 0 then
      WriteRefs('shared', 'branch|release|' + SHARED_COMMIT + '|'#10
        + 'tag|release|' + SHARED_COMMIT + '|'#10)
    else
      WriteRefs('shared', 'tag|release|' + SHARED_COMMIT + '|'#10
        + 'branch|release|' + SHARED_COMMIT + '|'#10);
    Run := RunInstall(Root, ['install']);
    DumpRunFailure('surviving tag with branch', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    LockText := ReadText(Root + '/lwpt.lock');
    Expect<Boolean>(Pos('resolvedRefKind = "tag"', LockText) > 0).ToBe(True);
  end;
end;

{ Replaces the archiveHash of one lock entry, simulating a lock whose two
  aliases of one repository and commit record different archive bytes. }
procedure SetLockArchiveHash(const APath, APackage, AHash: string);
var Lines: TStringList; LineIndex: Integer; InPackage: Boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    InPackage := False;
    for LineIndex := 0 to Lines.Count - 1 do
    begin
      if Pos('[', Lines[LineIndex]) = 1 then
        InPackage := Lines[LineIndex] = '[package.' + APackage + ']'
      else if InPackage and (Pos('archiveHash = ', Lines[LineIndex]) = 1) then
        Lines[LineIndex] := 'archiveHash = "' + AHash + '"';
    end;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

{ Offline, the first alias of a repository and commit stages its verified
  committed archive as the resolver candidate. A second alias whose lock
  records different bytes must be refused before those bytes are copied or
  extracted for it, not only at the final offline lock comparison. }
procedure TInstallGitGraph.TestOfflineSharedCandidateIsCheckedBeforeExtraction;
var
  Root, LockBefore, Combined, OtherArchive, OtherHash, SavedCache: string;
  Run: TLwptResult;
begin
  SavedCache := FCacheRoot;
  Root := FScratch + '/offline-shared-candidate';
  FCacheRoot := FScratch + '/offline-shared-candidate-cache';
  RecursiveDelete(FCacheRoot);
  WriteRoot(Root, 'offline-shared-candidate',
    'a = "fixture/shared@v1.0.0"'#10 + 'z = "fixture/shared@v1.0.0"'#10);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('a', SHARED_COMMIT,
    '[package]'#10 + 'name = "a"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Run := RunInstall(Root, ['install']);
  DumpRunFailure('offline shared candidate seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);

  { z's committed archive and lock entry agree with each other but not with
    a's bytes for the same commit. }
  WriteArchive('z', SHARED_COMMIT,
    '[package]'#10 + 'name = "z"'#10 + 'version = "6.6.6"'#10
    + 'units = ["source"]'#10);
  OtherArchive := FFixtureRoot + '/archives/z/' + SHARED_COMMIT + '.tar.gz';
  Expect<Boolean>(CopyFileContent(OtherArchive,
    Root + '/.lwpt/archives/z-v1.0.0.tar.gz')).ToBe(True);
  OtherHash := 'sha256:' + SHA256File(OtherArchive);
  SetLockArchiveHash(Root + '/lwpt.lock', 'z', OtherHash);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');
  RecursiveDelete(Root + '/.lwpt/modules');
  FCacheRoot := FScratch + '/offline-shared-candidate-cold-cache';
  RecursiveDelete(FCacheRoot);

  Run := RunInstall(Root, ['install', '--offline']);
  Combined := Run.Stdout + Run.Stderr;
  FCacheRoot := SavedCache;
  if Pos('by another dependency', Combined) = 0 then
    WriteLn('--- offline shared candidate ---'#10, Combined, '---');
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('dependency "z": [offline] the archive staged for '
    + 'locked commit ' + SHARED_COMMIT + ' by another dependency does not '
    + 'match lwpt.lock (locked archive ' + OtherHash, Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('online', Combined) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/z')).ToBe(False);
end;

procedure TInstallGitGraph.AfterAll;
begin
  SetCurrentDir(FOriginalDir);
end;

procedure TInstallGitGraph.TestMultiRoundGlobalConflictPublishesNothing;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/global-conflict';
  WriteRoot(Root, 'global-conflict',
    'branch-a = "fixture/branch-a@1.0.0"'#10
    + 'branch-b = "fixture/branch-b@1.0.0"'#10
    + 'branch-c = "fixture/branch-c@1.0.0"'#10);
  WriteRefs('branch-a', 'tag|v1.0.0|' + PARENT_A_COMMIT + '|'#10);
  WriteRefs('branch-b', 'tag|v1.0.0|' + PARENT_B_COMMIT + '|'#10);
  WriteRefs('branch-c', 'tag|v1.0.0|' + PARENT_C_COMMIT + '|'#10);
  WriteRefs('shared',
    'tag|v1.5.0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1|'#10
    + 'tag|v2.5.0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2|'#10
    + 'tag|v3.5.0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3|'#10);
  WriteArchive('branch-a', PARENT_A_COMMIT,
    '[package]'#10 + 'name = "branch-a"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@<2.0.0 || >=3.0.0"'#10);
  WriteArchive('branch-b', PARENT_B_COMMIT,
    '[package]'#10 + 'name = "branch-b"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@>=1.0.0 <3.0.0"'#10);
  WriteArchive('branch-c', PARENT_C_COMMIT,
    '[package]'#10 + 'name = "branch-c"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@>=2.0.0"'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('canonical source: '
    + 'git|https://github.com/fixture/shared.git', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('branch-a wants "<2.0.0 || >=3.0.0"',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('branch-b wants ">=1.0.0 <3.0.0"',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('branch-c wants ">=2.0.0"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/branch-a'))
    .ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(False);
  Expect<Integer>(RequestCount(
    'archive|branch-a|' + PARENT_A_COMMIT)).ToBe(1);
  Expect<Integer>(RequestCount(
    'archive|branch-b|' + PARENT_B_COMMIT)).ToBe(1);
  Expect<Integer>(RequestCount(
    'archive|branch-c|' + PARENT_C_COMMIT)).ToBe(1);
end;

procedure TInstallGitGraph.TestLateConstraintIsIncludedInTerminalConflict;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/late-constraint-conflict';
  WriteRoot(Root, 'late-constraint-conflict',
    'a = "fixture/queue-a@1.0.0"'#10
    + 'b = "fixture/queue-b@1.0.0"'#10);
  WriteRefs('queue-a', 'tag|v1.0.0|' + PARENT_A_COMMIT + '|'#10);
  WriteRefs('queue-b', 'tag|v1.0.0|' + PARENT_B_COMMIT + '|'#10);
  WriteRefs('queue-x', 'tag|v1.0.0|' + PARENT_C_COMMIT + '|'#10);
  WriteRefs('shared',
    'tag|v1.0.0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1|'#10
    + 'tag|v2.0.0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2|'#10);
  WriteArchive('a', PARENT_A_COMMIT,
    '[package]'#10 + 'name = "a"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@<1.0.0"'#10);
  WriteArchive('b', PARENT_B_COMMIT,
    '[package]'#10 + 'name = "b"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'x = "fixture/queue-x@1.0.0"'#10);
  WriteArchive('x', PARENT_C_COMMIT,
    '[package]'#10 + 'name = "x"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@>=2.0.0"'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('a wants "<1.0.0"', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('x wants ">=2.0.0"', Combined) > 0).ToBe(True);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(1);
  Expect<Integer>(RequestCount(
    'archive|x|' + PARENT_C_COMMIT)).ToBe(1);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.cfg')).ToBe(False);
end;

procedure TInstallGitGraph.TestMixedTagSHAUsesImmutableFetchAndFrozenIdentity;
var Root, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/mixed-identity';
  WriteRoot(Root, 'mixed-identity',
    'branch-a = "fixture/branch-a@1.0.0"'#10
    + 'branch-b = "fixture/branch-b@1.0.0"'#10);
  WriteRefs('branch-a', 'tag|v1.0.0|' + PARENT_A_COMMIT + '|'#10);
  WriteRefs('branch-b', 'tag|v1.0.0|' + PARENT_B_COMMIT + '|'#10);
  WriteRefs('shared', 'tag|stable|' + SHARED_COMMIT + '|'#10);
  WriteArchive('branch-a', PARENT_A_COMMIT,
    '[package]'#10 + 'name = "branch-a"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@stable"'#10);
  WriteArchive('branch-b', PARENT_B_COMMIT,
    '[package]'#10 + 'name = "branch-b"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'shared = "fixture/shared@' + SHARED_COMMIT + '"'#10);
  WriteArchive('shared', SHARED_COMMIT,
    '[package]'#10 + 'name = "shared"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');

  Run := RunInstall(Root, ['install']);
  if Run.ExitCode <> 0 then
    WriteLn('--- mixed install ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('resolvedRef = "stable"', LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedCommit = "' + SHARED_COMMIT + '"',
    LockText) > 0).ToBe(True);
  Expect<Boolean>(Pos('/archive/' + SHARED_COMMIT + '.tar.gz',
    LockText) > 0).ToBe(True);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(1);
  Expect<Integer>(RequestCount('archive|shared|stable')).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|branch-a|' + PARENT_A_COMMIT)).ToBe(1);

  { Mutating the advertised tag after materialization must not affect the
    network-free frozen proof, which is bound to the recorded commit. }
  WriteRefs('shared', 'tag|stable|' + MUTATED_SHARED_COMMIT + '|'#10);
  WriteTextFile(FFixtureRoot + '/requests.log', '');
  Run := RunInstall(Root, ['install', '--frozen']);
  if Run.ExitCode <> 0 then
    WriteLn('--- mixed frozen ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RequestCount('refs|shared')).ToBe(0);
  Expect<Integer>(RequestCount(
    'archive|shared|' + SHARED_COMMIT)).ToBe(0);

  { The same graph is genuinely ambiguous in an early v3 lock: its named
    ref and SHA constraint cannot be proven equivalent without the additive
    authoritative commit field. Frozen mode must explain regeneration. }
  RemoveAdditiveIdentityFields(Root + '/lwpt.lock');
  Run := RunInstall(Root, ['install', '--frozen']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('records no authoritative commit identity',
    Run.Stdout + Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('without --frozen', Run.Stdout + Run.Stderr) > 0)
    .ToBe(True);
end;

function LockValue(const ALockText, AKey: string): string;
var Lines: TStringList; LineIndex: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := ALockText;
    for LineIndex := 0 to Lines.Count - 1 do
      if Pos(AKey + ' = ', Lines[LineIndex]) = 1 then
        Exit(Copy(Lines[LineIndex], Length(AKey) + 4, MaxInt));
  finally
    Lines.Free;
  end;
end;

procedure TInstallGitGraph.TestDeepProjectRootExtractsArchive;
{ Issue #309: archives were opened through paszlib's gzopen, whose
  shortstring path truncated anything over 255 characters, so every
  archive-backed install from a deep checkout failed with "Could not open
  gzip compressed file". }
var
  ShallowRoot, ShallowLock, Root, ArchivePath: string;
  Run: TLwptResult;
begin
  {$IFDEF MSWINDOWS}
  { This root exceeds legacy Windows MAX_PATH before LWPT runs. }
  Expect<Boolean>(True).ToBe(True);
  Exit;
  {$ENDIF}
  PrepareOfflineSeed('deep-root-reference', ShallowRoot, ShallowLock);
  Expect<Boolean>(LockValue(ShallowLock, 'computedHash') <> '').ToBe(True);

  FCacheRoot := FScratch + '/deep-root-cache';
  RecursiveDelete(FCacheRoot);
  Root := ExpandFileName(FScratch + '/deep-root/' + StringOfChar('d', 100)
    + '/' + StringOfChar('e', 100) + '/project');
  ArchivePath := Root + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  { Fixture precondition: even the committed archive path, the shortest
    one install extracts from, is past the old limit. }
  Expect<Boolean>(Length(ArchivePath) > 255).ToBe(True);
  WriteRoot(Root, 'deep-root', 'shared = "fixture/shared@^1.0.0"'#10);

  Run := RunInstall(Root, ['install']);
  DumpRunFailure('deep project root install', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ArchivePath)).ToBe(True);
  Expect<string>(ReadBinaryFile(Root
    + '/.lwpt/modules/shared/source/shared.pas')).ToBe(
    'unit shared;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  Expect<string>(LockValue(ReadBinaryFile(Root + '/lwpt.lock'),
    'computedHash')).ToBe(LockValue(ShallowLock, 'computedHash'));

  Run := RunInstall(Root, ['install', '--frozen']);
  DumpRunFailure('deep project root frozen install', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TInstallGitGraph.SetupTests;
begin
  Test('multi-round SemVer graph rejects pairwise overlap with '
    + 'globally empty intersection before publication',
    TestMultiRoundGlobalConflictPublishesNothing);
  Test('terminal conflict includes requirements discovered later in the queue',
    TestLateConstraintIsIncludedInTerminalConflict);
  Test('mixed tag/SHA materialization fetches one immutable archive and '
    + 'frozen ignores later ref mutation',
    TestMixedTagSHAUsesImmutableFetchAndFrozenIdentity);
  Test('a changed transitive constraint forces round two while ref and '
    + 'unchanged-candidate caches are reused',
    TestSecondRoundReusesRefAndCandidateCaches);
  Test('verified archive objects are reused across projects from lock identity',
    TestVerifiedArchiveCacheReusesLockedBytesAcrossProjects);
  Test('offline restores missing modules and cfg from the committed archive',
    TestOfflineCommittedArchiveRestoresProjectState);
  Test('offline archive and cache misses preserve committed project state',
    TestOfflineMissPreservesCommittedState);
  Test('offline rejects a corrupt committed archive without cache fallback',
    TestOfflineCorruptArchiveIsNotFetchedAround);
  Test('offline rejects manifest drift before publishing locked state',
    TestOfflineManifestDriftFailsBeforePublication);
  Test('offline rejects compatible manifest drift before publication starts',
    TestOfflineCompatibleDriftFailsBeforePublication);
  Test('offline accepts an unambiguous early schema-v3 lock',
    TestOfflineAcceptsUnambiguousEarlyV3Lock);
  Test('offline derives an early schema-v3 SHA identity from the locked ref',
    TestOfflineAcceptsEarlyV3SHAIdentity);
  Test('offline restores local and workspace dependencies from their paths',
    TestOfflineRestoresLocalAndWorkspaceDependencies);
  Test('offline restores a direct URL archive without touching transport',
    TestOfflineRestoresDirectURLWithoutTransport);
  Test('offline requires an existing compatible lock before resolution',
    TestOfflineRequiresExistingLock);
  Test('offline and frozen install modes are mutually exclusive',
    TestOfflineAndFrozenAreMutuallyExclusive);
  Test('a tag moved behind a lock without commit identity fails on its '
    + 'archive until accepted',
    TestMovedTagBehindEarlyLockFailsUntilAccepted);
  Test('a locked tag moved upstream fails until explicitly accepted',
    TestMovedLockedTagFailsUntilAccepted);
  Test('a manifest mutation refuses a moved locked tag and keeps the manifest',
    TestMovedLockedTagFailsManifestMutation);
  Test('a branch requirement keeps following its moving tip',
    TestMovedBranchKeepsFollowing);
  Test('accepting moved tags requires an online install',
    TestAcceptMovedTagsRequiresOnlineInstall);
  Test('a locked tag re-published under another SemVer spelling fails',
    TestMovedTagRespelledAsSemverFails);
  Test('a locked tag replaced by a same-named branch fails',
    TestTagReplacedByBranchFails);
  Test('a locked branch replaced by a same-named tag is not a moved tag',
    TestBranchReplacedByTagIsNotAMovedTag);
  Test('a moved ref behind a lock without ref kinds fails closed until '
    + 'accepted', TestLockWithoutRefKindFailsClosedForMovedBranch);
  Test('a locked commit must reproduce its locked archive, including after '
    + 'a failed ref listing', TestLockedCommitMustReproduceLockedArchive);
  Test('a resolver candidate shared by another dependency must reproduce '
    + 'the locked archive', TestSharedCandidateCannotBypassLockedArchive);
  Test('a ref locked without a kind never silently becomes a movable branch',
    TestLegacyTagCannotBecomeMovableBranch);
  Test('a surviving locked tag is kept when a same-named branch is '
    + 'advertised in either order', TestSurvivingTagWinsOverSameNamedBranch);
  Test('offline reuse of another dependency''s staged archive is checked '
    + 'against the lock before extraction',
    TestOfflineSharedCandidateIsCheckedBeforeExtraction);
  Test('a project root whose archive path exceeds 255 characters installs '
    + 'the same tree as a shallow root', TestDeepProjectRootExtractsArchive);
end;

begin
  TestRunnerProgram.AddSuite(TInstallGitGraph.Create(
    'install: deterministic git graph'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
