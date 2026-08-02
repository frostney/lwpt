program InstallGitGraph.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch,
  Tests.TarSynth;

type
  TInstallGitGraph = class(TTestSuite)
  private
    FOriginalDir, FScratch, FFixtureRoot: string;
    procedure WriteRoot(const ARoot, AName, ADependencies: string);
    procedure WriteRefs(const ARepository, AContent: string);
    procedure WriteArchive(const AName, ACommit, AManifest: string);
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

function TInstallGitGraph.RunInstall(const ARoot: string;
  const AArguments: array of string): TLwptResult;
begin
  Result := RunLwpt(AArguments, ARoot,
    ['LWPT_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot]);
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
  RecursiveDelete(FScratch);
  ForceDirectories(FFixtureRoot);
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
end;

begin
  TestRunnerProgram.AddSuite(TInstallGitGraph.Create(
    'install: deterministic git graph'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
