{ BuildMultiTarget.Test — `lwpt build` with more than one named target.

  Contract under test:

    lwpt build <a> <b>   builds BOTH named targets (historically the
                         second name was silently dropped)
    lwpt build <a> <x>   where <x> names no target: exits 1, names the
                         unknown target on stderr, and builds NOTHING
                         (names are validated before any compile runs)
    lwpt build           (no names) still builds every target

    unit artefacts (.ppu/.o) land in build/targets/<name>/<mode>/,
    never in the shared build/ root — one target's (or one mode's)
    units must not poison another's; --clean wipes the target's
    whole artefact dir

  Goes through the real binary via Tests.LwptSubprocess because the
  defect spans the CLI positional handling AND the CmdBuild loop —
  an API-only test would miss the argv half. The scratch project's
  targets are three trivial one-line programs so each fpc run is
  fast and has no dependencies. }

program BuildMultiTarget.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

type
  TBuildMultiTarget = class(TTestSuite)
  private
    FScratch: string;
    procedure WipeOutputs;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestTwoNamedTargetsBuildBoth;
    procedure TestUnknownTargetNameFailsBeforeBuildingAnything;
    procedure TestNoNamesStillBuildsAllTargets;
    procedure TestUnitArtefactsIsolatedPerTargetAndMode;
    procedure TestCleanWipesTargetArtefactDir;
    procedure TestTraversalTargetNameRejectedAtLoad;
    procedure TestCollidingArtefactDirsRejected;
    procedure TestCleanPrunesOrphanTargetDirs;
    procedure TestMissingCompilerFailsTargetsButLoopContinues;
    {$IFDEF UNIX}
    procedure TestCleanFailureFailsTargetButBuildContinues;
    {$ENDIF}
  end;

procedure TBuildMultiTarget.BeforeAll;
const
  { Each program uses a shared unit so unit artefacts (.ppu) exist
    and their placement can be asserted. }
  TRIVIAL = 'uses common;'#10'begin'#10
          + '  if GREETING = '''' then Halt(1);'#10'end.'#10;
begin
  FScratch := ExpandFileName(
    GetCurrentDir + '/build/tests/tmp/build-multi-target');
  RecursiveDelete(FScratch);

  WriteTestFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "multitarget"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "src/alpha.pas", output = "build/alpha" }'#10
    + 'beta = { source = "src/beta.pas", output = "build/beta" }'#10
    + 'gamma = { source = "src/gamma.pas", output = "build/gamma" }'#10);
  WriteTestFile(FScratch + '/src/common.pas',
      'unit common;'#10'{$mode delphi}{$H+}'#10'interface'#10
    + 'const GREETING = ''hi'';'#10'implementation'#10'end.'#10);
  WriteTestFile(FScratch + '/src/alpha.pas', 'program alpha;'#10 + TRIVIAL);
  WriteTestFile(FScratch + '/src/beta.pas',  'program beta;'#10  + TRIVIAL);
  WriteTestFile(FScratch + '/src/gamma.pas', 'program gamma;'#10 + TRIVIAL);
end;

procedure TBuildMultiTarget.WipeOutputs;
begin
  RecursiveDelete(FScratch + '/build');
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TBuildMultiTarget.TestTwoNamedTargetsBuildBoth;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'beta'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  { The un-named third target stays un-built. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/gamma')))
    .ToBe(False);
end;

procedure TBuildMultiTarget.TestUnknownTargetNameFailsBeforeBuildingAnything;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'no-such-target'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('no-such-target', R.Stderr) > 0).ToBe(True);
  { Names are validated up front — a typo must not half-build. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(False);
end;

procedure TBuildMultiTarget.TestNoNamesStillBuildsAllTargets;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/gamma')))
    .ToBe(True);
end;

procedure TBuildMultiTarget.TestUnitArtefactsIsolatedPerTargetAndMode;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { The shared unit's artefacts land in the target's dev dir... }
  Expect<Boolean>(
    FileExists(FScratch + '/build/targets/alpha/dev/common.ppu'))
    .ToBe(True);
  { ...not in the shared build/ root, and not in any other target's. }
  Expect<Boolean>(FileExists(FScratch + '/build/common.ppu')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/build/targets/beta'))
    .ToBe(False);

  { Release builds of the same target get their own dir; dev's stays. }
  R := RunLwpt(['build', 'alpha', '--mode', 'release'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(
    FileExists(FScratch + '/build/targets/alpha/release/common.ppu'))
    .ToBe(True);
  Expect<Boolean>(
    FileExists(FScratch + '/build/targets/alpha/dev/common.ppu'))
    .ToBe(True);
end;

procedure TBuildMultiTarget.TestCleanWipesTargetArtefactDir;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { Plant a stale file inside the target's artefact dir; --clean must
    wipe the whole dir (both modes) before rebuilding. }
  WriteTestFile(FScratch + '/build/targets/alpha/dev/stale.sentinel', 'x');
  R := RunLwpt(['build', '--clean', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(
    FileExists(FScratch + '/build/targets/alpha/dev/stale.sentinel'))
    .ToBe(False);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
end;

procedure TBuildMultiTarget.TestTraversalTargetNameRejectedAtLoad;
var
  Bad : string;
  R   : TLwptResult;
begin
  { A quoted TOML key ".." would make build/targets/.. resolve to
    build/ itself — --clean would wipe every target's artefacts and
    the binary. The manifest loader must reject it before any build
    (or wipe) runs. }
  Bad := ExpandFileName(
    GetCurrentDir + '/build/tests/tmp/build-traversal-name');
  RecursiveDelete(Bad);
  WriteTestFile(Bad + '/lwpt.toml',
      '[package]'#10
    + 'name = "traversal"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + '".." = { source = "src/alpha.pas", output = "build/alpha" }'#10);
  WriteTestFile(Bad + '/src/alpha.pas',
    'program alpha;'#10'begin'#10'end.'#10);
  WriteTestFile(Bad + '/build/survivor.txt', 'must not be wiped');

  R := RunLwpt(['build', '--clean'], Bad);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('invalid [build] target name', R.Stderr) > 0)
    .ToBe(True);
  { The whole point: nothing under build/ was touched. }
  Expect<Boolean>(FileExists(Bad + '/build/survivor.txt')).ToBe(True);
end;

procedure TBuildMultiTarget.TestCollidingArtefactDirsRejected;
var
  Bad : string;
  R   : TLwptResult;
begin
  { Sanitisation maps "a:b" and "a_b" onto the same artefact dir —
    silently sharing unit output would reintroduce the cross-target
    poisoning the per-target split prevents. Rejected before any
    hook or compile runs. }
  Bad := ExpandFileName(
    GetCurrentDir + '/build/tests/tmp/build-colliding-names');
  RecursiveDelete(Bad);
  WriteTestFile(Bad + '/lwpt.toml',
      '[package]'#10
    + 'name = "colliding"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + '"a:b" = { source = "src/alpha.pas", output = "build/one" }'#10
    + 'a_b = { source = "src/alpha.pas", output = "build/two" }'#10);
  WriteTestFile(Bad + '/src/alpha.pas',
    'program alpha;'#10'begin'#10'end.'#10);

  R := RunLwpt(['build'], Bad);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('same artefact dir', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(Bad + '/build/one'))).ToBe(False);
  Expect<Boolean>(FileExists(ExpectedExe(Bad + '/build/two'))).ToBe(False);
end;

procedure TBuildMultiTarget.TestCleanPrunesOrphanTargetDirs;
var
  R     : TLwptResult;
  Ghost : string;
begin
  { build/targets/<name>/ dirs of renamed or deleted targets are
    reclaimed on --clean — and only on --clean. }
  WipeOutputs;
  Ghost := FScratch + '/build/targets/ghost';
  WriteTestFile(Ghost + '/dev/stale.ppu', 'x');

  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { A plain build leaves unknown dirs alone. }
  Expect<Boolean>(DirectoryExists(Ghost)).ToBe(True);

  R := RunLwpt(['build', '--clean', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(DirectoryExists(Ghost)).ToBe(False);
  { Live targets' dirs survive the prune. }
  Expect<Boolean>(
    FileExists(FScratch + '/build/targets/alpha/dev/common.ppu'))
    .ToBe(True);
end;

procedure TBuildMultiTarget.TestMissingCompilerFailsTargetsButLoopContinues;
var R: TLwptResult;
begin
  { An exception out of the compile step (here: EProcess because the
    compiler binary doesn't exist) must fail each target individually,
    not abort the loop — the summary line still prints. }
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'beta'], FScratch,
    ['LWPT_FPC=' + FScratch + '/no-such-fpc']);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('target "alpha" failed:', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('target "beta" failed:', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('0 built, 2 failed', R.Stdout) > 0).ToBe(True);
end;

{$IFDEF UNIX}
procedure TBuildMultiTarget.TestCleanFailureFailsTargetButBuildContinues;
var
  R      : TLwptResult;
  Locked : string;
begin
  { A wipe failure (locked file, permissions) must fail that target
    only — postbuild hooks and the remaining targets keep going
    (ADR-0011). Simulated by making alpha's artefact dir undeletable. }
  WipeOutputs;
  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Locked := FScratch + '/build/targets/alpha/dev';
  FpChmod(Locked, &555);
  try
    R := RunLwpt(['build', '--clean', 'alpha', 'beta'], FScratch);
  finally
    FpChmod(Locked, &755);
  end;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('target "alpha" failed:', R.Stderr) > 0).ToBe(True);
  { beta still built, and the summary line still printed. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  Expect<Boolean>(Pos('1 built, 1 failed', R.Stdout) > 0).ToBe(True);
end;
{$ENDIF}

procedure TBuildMultiTarget.SetupTests;
begin
  Test('build alpha beta: both named targets are built',
    TestTwoNamedTargetsBuildBoth);
  Test('build alpha no-such-target: fails fast, builds nothing',
    TestUnknownTargetNameFailsBeforeBuildingAnything);
  Test('build with no names builds every target',
    TestNoNamesStillBuildsAllTargets);
  Test('unit artefacts isolated per target and mode',
    TestUnitArtefactsIsolatedPerTargetAndMode);
  Test('--clean wipes the target artefact dir',
    TestCleanWipesTargetArtefactDir);
  Test('traversal target name ".." is rejected at manifest load',
    TestTraversalTargetNameRejectedAtLoad);
  Test('target names colliding after sanitisation are rejected',
    TestCollidingArtefactDirsRejected);
  Test('--clean prunes orphaned target artefact dirs',
    TestCleanPrunesOrphanTargetDirs);
  Test('missing compiler fails targets individually, loop continues',
    TestMissingCompilerFailsTargetsButLoopContinues);
  {$IFDEF UNIX}
  Test('clean failure fails the target, build continues',
    TestCleanFailureFailsTargetButBuildContinues);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TBuildMultiTarget.Create(
    'build: multiple named targets'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
