{ InstallNestedManifest.Test — integration test for dependency trees
  whose lwpt.toml is NOT at the module root.

  This is the layout produced by include-filtered git-host deps
  (e.g. include = ["packages/httpclient/**"] against a monorepo
  release tarball): the filter preserves the repo-relative path
  prefix, so after extraction the dep's manifest sits at
  .lwpt/modules/<dep>/packages/<name>/lwpt.toml — not at the module
  root. The graph walker must discover that nested manifest (the
  shallowest lwpt.toml in the tree), emit -Fu/-Fi for its units
  dirs RELATIVE TO THE MODULE ROOT, and enqueue its transitive deps.

  The fixture uses local-path sources (no network): the same
  child-manifest discovery code path runs for every source kind.

  Layout built into a per-test scratch:

    depsrc/packages/leaf/lwpt.toml      nested manifest, units=["src"],
                                        depends on leaf2
    depsrc/packages/leaf/src/NestedLeaf.pas
    ambigsrc/packages/x/lwpt.toml       TWO manifests at equal depth —
    ambigsrc/packages/y/lwpt.toml       ambiguous, falls back to the
                                        module root (no subdirs)
    leafdep/lwpt.toml                   plain root-level manifest,
                                        pulled in transitively
    root/lwpt.toml                      nested-leaf = "../depsrc"
                                        ambig       = "../ambigsrc"  }

program InstallNestedManifest.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  LWPT.Command.Install,
  LWPT.Core,
  TestingPascalLibrary,
  Tests.Scratch;

type
  TInstallNestedManifest = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestModuleTreeKeepsRepoRelativePrefix;
    procedure TestCfgPointsAtNestedUnitsDir;
    procedure TestTransitiveDepOfNestedManifestResolved;
    procedure TestAmbiguousManifestsFallBackToModuleRoot;
  end;

  { Issue #347: a local dependency whose nested manifest fits MAX_PATH
    where it is installed, but not in the resolver staging copy below
    .lwpt/tmp, which adds the plan directory to every path. Discovery and
    the manifest read both go through the Core long-path helpers there. }
  TDeepStagedManifest = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot, FNested: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestStagedManifestPastMaxPathIsRead;
  end;

const
  { Win32 MAX_PATH, including the terminating NUL. }
  LEGACY_WINDOWS_MAX_PATH = 260;
  { The installed manifest's length: inside MAX_PATH, and inside the
    247-character directory budget for its parent. }
  INSTALLED_MANIFEST_LENGTH = 245;
  { The shortest resolver plan directory MakeTmpPath can name
    ('resolver-plan.<pid>.<8 base36 stamp digits>.<sequence>.tmp'), as the
    staging copy inserts it below .lwpt/tmp. }
  SHORTEST_PLAN_INSERT = '/tmp/resolver-plan.0.00000000.0.tmp';

function ReadFileText(const APath: string): string;
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(APath);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ── lifecycle ─────────────────────────────────────────────────────── }

procedure TInstallNestedManifest.BeforeAll;
begin
  FOrigDir  := GetCurrentDir;
  FScratch  := CreateScratchRoot('install-nested-manifest');
  FRoot     := FScratch + '/root';

  RecursiveDelete(FScratch);

  { Dep whose manifest lives at packages/leaf/ inside the tree —
    exactly the shape an include-filtered monorepo tarball leaves
    behind. Declares a transitive dep to prove the nested manifest's
    [dependencies] are walked too. }
  WriteTextFile(FScratch + '/depsrc/packages/leaf/lwpt.toml',
      '[package]'#10
    + 'name = "nested-leaf"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[dependencies]'#10
    + 'leaf2 = "../leafdep"'#10);
  WriteTextFile(FScratch + '/depsrc/packages/leaf/src/NestedLeaf.pas',
    'unit NestedLeaf;'#10'interface'#10'implementation'#10'end.'#10);

  { Two manifests at the same (minimal) depth — ambiguous; the walker
    must fall back to the module root rather than guess. }
  WriteTextFile(FScratch + '/ambigsrc/packages/x/lwpt.toml',
      '[package]'#10
    + 'name = "ambig-x"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10);
  WriteTextFile(FScratch + '/ambigsrc/packages/x/src/AmbigX.pas',
    'unit AmbigX;'#10'interface'#10'implementation'#10'end.'#10);
  WriteTextFile(FScratch + '/ambigsrc/packages/y/lwpt.toml',
      '[package]'#10
    + 'name = "ambig-y"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10);
  WriteTextFile(FScratch + '/ambigsrc/packages/y/src/AmbigY.pas',
    'unit AmbigY;'#10'interface'#10'implementation'#10'end.'#10);

  { Ordinary root-level-manifest dep, reached only via nested-leaf's
    [dependencies]. Path resolves relative to the install-time CWD
    (the root project), matching the diamond fixture convention. }
  WriteTextFile(FScratch + '/leafdep/lwpt.toml',
      '[package]'#10
    + 'name = "leaf2"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10);
  WriteTextFile(FScratch + '/leafdep/src/Leaf2.pas',
    'unit Leaf2;'#10'interface'#10'implementation'#10'end.'#10);

  WriteTextFile(FRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "nested-root"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[dependencies]'#10
    + 'nested-leaf = "../depsrc"'#10
    + 'ambig = "../ambigsrc"'#10);
  WriteTextFile(FRoot + '/src/RootMain.pas',
    'unit RootMain;'#10'interface'#10'implementation'#10'end.'#10);

  SetCurrentDir(FRoot);
  CmdInstall('lwpt.toml', False);
end;

procedure TInstallNestedManifest.AfterAll;
begin
  SetCurrentDir(FOrigDir);
  { Leave FScratch in place on failure so artefacts are inspectable. }
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TInstallNestedManifest.TestModuleTreeKeepsRepoRelativePrefix;
begin
  { The module tree is installed as-is — the repo-relative prefix is
    preserved, NOT re-rooted. Committed zero-install state must stay
    byte-identical to what the filter produced. }
  Expect<Boolean>(FileExists(FRoot
    + '/.lwpt/modules/nested-leaf/packages/leaf/src/NestedLeaf.pas'))
    .ToBe(True);
  Expect<Boolean>(FileExists(FRoot
    + '/.lwpt/modules/nested-leaf/packages/leaf/lwpt.toml'))
    .ToBe(True);
end;

procedure TInstallNestedManifest.TestCfgPointsAtNestedUnitsDir;
var Cfg: string;
begin
  Expect<Boolean>(FileExists(FRoot + '/lwpt.cfg')).ToBe(True);
  Cfg := ReadFileText(FRoot + '/lwpt.cfg');
  { The nested manifest declares units = ["src"]; the emitted search
    path must be that dir under the manifest's own subtree — not the
    bare module root, where FPC finds nothing. }
  Expect<Boolean>(
    Pos('-Fu.lwpt/modules/nested-leaf/packages/leaf/src', Cfg) > 0)
    .ToBe(True);
  Expect<Boolean>(
    Pos('-Fi.lwpt/modules/nested-leaf/packages/leaf/src', Cfg) > 0)
    .ToBe(True);
end;

procedure TInstallNestedManifest.TestTransitiveDepOfNestedManifestResolved;
var Cfg, Lock: string;
begin
  { nested-leaf's own [dependencies] live in the nested manifest; if
    discovery only looks at the module root they are silently lost. }
  Expect<Boolean>(FileExists(FRoot
    + '/.lwpt/modules/leaf2/src/Leaf2.pas')).ToBe(True);
  Cfg := ReadFileText(FRoot + '/lwpt.cfg');
  Expect<Boolean>(Pos('-Fu.lwpt/modules/leaf2/src', Cfg) > 0).ToBe(True);
  Lock := ReadFileText(FRoot + '/lwpt.lock');
  Expect<Boolean>(Pos('[package.leaf2]', Lock) > 0).ToBe(True);
end;

procedure TInstallNestedManifest.TestAmbiguousManifestsFallBackToModuleRoot;
var Cfg: string;
begin
  Cfg := ReadFileText(FRoot + '/lwpt.cfg');
  { Two manifests at equal minimal depth → no unique winner. The
    walker must not pick one arbitrarily; it falls back to emitting
    the module root (pre-existing no-manifest behavior). }
  Expect<Boolean>(Pos('-Fu.lwpt/modules/ambig', Cfg) > 0).ToBe(True);
  Expect<Boolean>(Pos('-Fu.lwpt/modules/ambig/packages', Cfg) > 0)
    .ToBe(False);
end;

{ ── deep staged manifest ─────────────────────────────────────────── }

procedure TDeepStagedManifest.BeforeAll;
var Installed: string; Remaining: Integer;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('install-deep-manifest');
  FRoot := FScratch + '/root';
  FNested := '';
  Installed := ExpandFileName(FRoot) + '/.lwpt/modules/deep-leaf';
  repeat
    Remaining := INSTALLED_MANIFEST_LENGTH - Length(Installed + FNested)
      - Length('/lwpt.toml') - 1;
    if Remaining < 1 then Break;
    if Remaining > 48 then Remaining := 48;
    FNested := FNested + '/' + StringOfChar('n', Remaining);
  until False;
  Delete(FNested, 1, 1);

  { The source tree stays shallow; only toolkit staging is deep. }
  WriteTextFile(FScratch + '/deepsrc/' + FNested + '/lwpt.toml',
      '[package]'#10
    + 'name = "deep-leaf"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[dependencies]'#10
    + 'deep-child = "../deepchild"'#10);
  WriteTextFile(FScratch + '/deepsrc/' + FNested + '/src/DeepLeaf.pas',
    'unit DeepLeaf;'#10'interface'#10'implementation'#10'end.'#10);
  WriteTextFile(FScratch + '/deepchild/lwpt.toml',
      '[package]'#10
    + 'name = "deep-child"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10);
  WriteTextFile(FScratch + '/deepchild/src/DeepChild.pas',
    'unit DeepChild;'#10'interface'#10'implementation'#10'end.'#10);
  WriteTextFile(FRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "deep-root"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[dependencies]'#10
    + 'deep-leaf = "../deepsrc"'#10);
  WriteTextFile(FRoot + '/src/RootMain.pas',
    'unit RootMain;'#10'interface'#10'implementation'#10'end.'#10);
end;

procedure TDeepStagedManifest.AfterAll;
begin
  SetCurrentDir(FOrigDir);
  { The RTL scratch cleanup cannot remove a tree past MAX_PATH. }
  if LongPathDirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TDeepStagedManifest.TestStagedManifestPastMaxPathIsRead;
var Installed, Cfg: string;
begin
  Installed := ExpandFileName(FRoot) + '/.lwpt/modules/deep-leaf/' + FNested
    + '/lwpt.toml';
  Expect<Boolean>(Length(Installed) < LEGACY_WINDOWS_MAX_PATH).ToBe(True);
  Expect<Boolean>(Length(Installed) + Length(SHORTEST_PLAN_INSERT)
    > LEGACY_WINDOWS_MAX_PATH).ToBe(True);

  SetCurrentDir(FRoot);
  CmdInstall('lwpt.toml', False);

  Expect<Boolean>(FileExists(Installed)).ToBe(True);
  Cfg := ReadFileText(FRoot + '/lwpt.cfg');
  { The nested manifest was read from staging: its units dir and its own
    dependency both reached the cfg. }
  Expect<Boolean>(Pos('-Fu.lwpt/modules/deep-leaf/' + FNested + '/src', Cfg)
    > 0).ToBe(True);
  Expect<Boolean>(Pos('-Fu.lwpt/modules/deep-child/src', Cfg) > 0).ToBe(True);
end;

procedure TDeepStagedManifest.SetupTests;
begin
  Test('install: a nested manifest read from staging past MAX_PATH',
    TestStagedManifestPastMaxPathIsRead);
end;

procedure TInstallNestedManifest.SetupTests;
begin
  Test('install: filtered module tree keeps its repo-relative prefix',
    TestModuleTreeKeepsRepoRelativePrefix);
  Test('install: cfg -Fu/-Fi point at the nested manifest''s units dir',
    TestCfgPointsAtNestedUnitsDir);
  Test('install: nested manifest''s own dependencies are resolved',
    TestTransitiveDepOfNestedManifestResolved);
  Test('install: ambiguous equal-depth manifests fall back to module root',
    TestAmbiguousManifestsFallBackToModuleRoot);
end;

begin
  TestRunnerProgram.AddSuite(TInstallNestedManifest.Create(
    'install: nested dep manifest discovery'));
  TestRunnerProgram.AddSuite(TDeepStagedManifest.Create(
    'install: deep staged dependency manifest'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
