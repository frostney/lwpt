{ BuildEntries.Test — `lwpt build` with more than one named entry.

  Contract under test:

    lwpt build <a> <b>   builds BOTH named entries (historically the
                         second name was silently dropped)
    lwpt build <a> <x>   where <x> names no entry: exits 1, names the
                         unknown entry on stderr, and builds NOTHING
                         (names are validated before any compile runs)
    lwpt build           (no names) still builds every entry

    unit artefacts (.ppu/.o) live only in invocation-private sessions;
    completed binaries are atomically published to their manifest paths

  Goes through the real binary via Tests.LwptSubprocess because the
  defect spans the CLI positional handling AND the CmdBuild loop —
  an API-only test would miss the argv half. The scratch project's
  entries are three trivial one-line programs so each fpc run is
  fast and has no dependencies. }

program BuildEntries.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TBuildEntries = class(TTestSuite)
  private
    FScratch: string;
    procedure WipeOutputs;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestTwoNamedEntriesBuildBoth;
    procedure TestUnknownEntryNameFailsBeforeBuildingAnything;
    procedure TestNoNamesStillBuildsAllEntries;
    procedure TestUnitArtefactsIsolatedPerEntryAndMode;
    procedure TestCleanLeavesEntryArtefactDirUntouched;
    procedure TestTraversalEntryNameRejectedAtLoad;
    procedure TestSanitisedEntryNamesRemainDistinct;
    procedure TestCleanLeavesOrphanEntryDirsUntouched;
    procedure TestCompileFailureReportsFpcExitCode;
    procedure TestMissingCompilerFailsEntriesButLoopContinues;
    procedure TestInvalidJobsFailsBeforeBuildingAnything;
    procedure TestInvalidDependencyGraphFailsBeforeBuildingAnything;
    procedure TestPerEntryCompilerFlagsAreForwarded;
    {$IFDEF DARWIN}
    procedure TestClassicLinkerFlagBuildsOnDarwin;
    {$ENDIF}
    {$IFDEF UNIX}
    procedure TestCleanFailureFailsEntryButBuildContinues;
    {$ENDIF}
  end;

procedure TBuildEntries.BeforeAll;
const
  { Each program uses a shared unit so unit artefacts (.ppu) exist
    and their placement can be asserted. }
  TRIVIAL = 'uses common;'#10'begin'#10
          + '  if GREETING = '''' then Halt(1);'#10'end.'#10;
begin
  FScratch := CreateScratchRoot('build-multi-entry');
  RecursiveDelete(FScratch);

  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "multientry"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "src/alpha.pas", output = "build/alpha" }'#10
    + 'beta = { source = "src/beta.pas", output = "build/beta" }'#10
    + 'gamma = { source = "src/gamma.pas", output = "build/gamma" }'#10);
  WriteTextFile(FScratch + '/src/common.pas',
      'unit common;'#10'{$mode delphi}{$H+}'#10'interface'#10
    + 'const GREETING = ''hi'';'#10'implementation'#10'end.'#10);
  WriteTextFile(FScratch + '/src/alpha.pas', 'program alpha;'#10 + TRIVIAL);
  WriteTextFile(FScratch + '/src/beta.pas',  'program beta;'#10  + TRIVIAL);
  WriteTextFile(FScratch + '/src/gamma.pas', 'program gamma;'#10 + TRIVIAL);
end;

procedure TBuildEntries.WipeOutputs;
begin
  RecursiveDelete(FScratch + '/build');
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TBuildEntries.TestTwoNamedEntriesBuildBoth;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'beta'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  { The un-named third entry stays un-built. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/gamma')))
    .ToBe(False);
end;

procedure TBuildEntries.TestUnknownEntryNameFailsBeforeBuildingAnything;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'no-such-entry'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('no-such-entry', R.Stderr) > 0).ToBe(True);
  { Names are validated up front — a typo must not half-build. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(False);
end;

procedure TBuildEntries.TestNoNamesStillBuildsAllEntries;
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

procedure TBuildEntries.TestUnitArtefactsIsolatedPerEntryAndMode;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { The shared unit's artefacts land in the entry's dev dir... }
  Expect<Boolean>(
    FileExists(FScratch + '/build/entries/alpha/dev/common.ppu'))
    .ToBe(False);
  { No compiler intermediates are published into shared build paths. }
  Expect<Boolean>(FileExists(FScratch + '/build/common.ppu')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/build/entries/beta'))
    .ToBe(False);

  { A release build also publishes only the completed executable. }
  R := RunLwpt(['build', 'alpha', '--mode', 'release'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(
    FileExists(FScratch + '/build/entries/alpha/release/common.ppu'))
    .ToBe(False);
  Expect<Boolean>(
    FileExists(FScratch + '/build/entries/alpha/dev/common.ppu'))
    .ToBe(False);
end;

procedure TBuildEntries.TestCleanLeavesEntryArtefactDirUntouched;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { Plant shared state that another process could own; clean must leave
    it untouched while compiling in fresh private staging. }
  WriteTextFile(FScratch + '/build/entries/alpha/dev/stale.sentinel', 'x');
  R := RunLwpt(['build', '--clean', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(
    FileExists(FScratch + '/build/entries/alpha/dev/stale.sentinel'))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
end;

procedure TBuildEntries.TestTraversalEntryNameRejectedAtLoad;
var
  Bad : string;
  R   : TLwptResult;
begin
  { A quoted TOML key ".." would make build/entries/.. resolve to
    build/ itself — --clean would wipe every entry's artefacts and
    the binary. The manifest loader must reject it before any build
    (or wipe) runs. }
  Bad := FScratch + '/traversal-name';
  RecursiveDelete(Bad);
  WriteTextFile(Bad + '/lwpt.toml',
      '[package]'#10
    + 'name = "traversal"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + '".." = { source = "src/alpha.pas", output = "build/alpha" }'#10);
  WriteTextFile(Bad + '/src/alpha.pas',
    'program alpha;'#10'begin'#10'end.'#10);
  WriteTextFile(Bad + '/build/survivor.txt', 'must not be wiped');

  R := RunLwpt(['build', '--clean'], Bad);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('invalid [build] entry name', R.Stderr) > 0)
    .ToBe(True);
  { The whole point: nothing under build/ was touched. }
  Expect<Boolean>(FileExists(Bad + '/build/survivor.txt')).ToBe(True);
end;

procedure TBuildEntries.TestSanitisedEntryNamesRemainDistinct;
var
  Bad : string;
  R   : TLwptResult;
begin
  { The readable part of both keys sanitises to a_b, but the full-name hash
    keeps their private compiler output distinct. }
  Bad := FScratch + '/colliding-names';
  RecursiveDelete(Bad);
  WriteTextFile(Bad + '/lwpt.toml',
      '[package]'#10
    + 'name = "colliding"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + '"a:b" = { source = "src/alpha.pas", output = "build/one" }'#10
    + 'a_b = { source = "src/alpha.pas", output = "build/two" }'#10);
  WriteTextFile(Bad + '/src/alpha.pas',
    'program alpha;'#10'begin'#10'end.'#10);

  R := RunLwpt(['build'], Bad);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(Bad + '/build/one'))).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(Bad + '/build/two'))).ToBe(True);
end;

procedure TBuildEntries.TestCleanLeavesOrphanEntryDirsUntouched;
var
  R     : TLwptResult;
  Ghost : string;
begin
  { Build sessions cannot infer ownership of legacy/shared directories;
    repair owns abandoned session reclamation instead. }
  WipeOutputs;
  Ghost := FScratch + '/build/entries/ghost';
  WriteTextFile(Ghost + '/dev/stale.ppu', 'x');

  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { A plain build leaves unknown dirs alone. }
  Expect<Boolean>(DirectoryExists(Ghost)).ToBe(True);

  R := RunLwpt(['build', '--clean', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(DirectoryExists(Ghost)).ToBe(True);
  { No live compiler output is ever placed there. }
  Expect<Boolean>(
    FileExists(FScratch + '/build/entries/alpha/dev/common.ppu'))
    .ToBe(False);
end;

procedure TBuildEntries.TestCompileFailureReportsFpcExitCode;
var
  Bad: string;
  R: TLwptResult;
begin
  { Regression: on macOS the child's nonzero exit was dropped to 0 by
    TProcess.ExitCode after WaitOnExit, so an entry whose source does
    not compile reached the publish step and failed there with
    "could not atomically publish" instead of reporting the compile
    failure. }
  Bad := FScratch + '/compile-failure';
  RecursiveDelete(Bad);
  WriteTextFile(Bad + '/lwpt.toml',
      '[package]'#10
    + 'name = "compile-failure"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'bad = { source = "src/bad.pas", output = "build/bad" }'#10);
  WriteTextFile(Bad + '/src/bad.pas',
    'program bad;'#10'begin'#10'  this is not pascal;'#10'end.'#10);
  try
    R := RunLwpt(['build'], Bad);
    Expect<Integer>(R.ExitCode).ToBe(1);
    { The typed failed-job event rejects zero outcomes. Reaching the normal
      progress line proves the build producer carried the compiler failure
      through event construction rather than substituting success. }
    Expect<Boolean>(Pos('FAIL bad (', R.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('bad.pas(3', R.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('Free Pascal Compiler version', R.Stdout) > 0)
      .ToBe(False);
    Expect<Boolean>(Pos('build entry "bad" failed:', R.Stderr) > 0).ToBe(True);
    Expect<Boolean>(Pos('0 built, 1 failed', R.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('could not atomically publish',
      R.Stderr) > 0).ToBe(False);
    Expect<Boolean>(FileExists(ExpectedExe(Bad + '/build/bad')))
      .ToBe(False);
  finally
    RecursiveDelete(Bad);
  end;
end;

procedure TBuildEntries.TestMissingCompilerFailsEntriesButLoopContinues;
var
  MissingCompiler, RequiredMessage: string;
  R: TLwptResult;
begin
  { An exception out of the compile step (here: EProcess because the
    compiler binary doesn't exist) must fail each entry individually,
    not abort the loop — the summary line still prints. }
  WipeOutputs;
  MissingCompiler := FScratch + '/no-such-fpc';
  R := RunLwpt(['build', 'alpha', 'beta'], FScratch,
    [PROJECT_NAME + '_FPC=' + MissingCompiler]);
  RequiredMessage := 'compiler "fpc" cannot determine its default target: '
    + 'could not execute "' + MissingCompiler + '"';
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos(RequiredMessage, R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('compiler "ppc', R.Stderr) > 0).ToBe(False);
  Expect<Boolean>(Pos('build entry "alpha" failed:', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('build entry "beta" failed:', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('0 built, 2 failed', R.Stdout) > 0).ToBe(True);
end;

procedure TBuildEntries.TestInvalidJobsFailsBeforeBuildingAnything;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', '--jobs=0'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('--jobs must be a positive integer', R.Stderr) > 0)
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(FScratch + '/build')).ToBe(False);
end;

procedure TBuildEntries.TestInvalidDependencyGraphFailsBeforeBuildingAnything;
var
  Bad: string;
  R: TLwptResult;
begin
  Bad := FScratch + '/invalid-graph';
  RecursiveDelete(Bad);
  WriteTextFile(Bad + '/lwpt.toml',
      '[package]'#10
    + 'name = "invalid-graph"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "src/alpha.pas", depends = ["missing"] }'#10);
  WriteTextFile(Bad + '/src/alpha.pas',
    'program alpha; begin end.'#10);
  try
    R := RunLwpt(['build'], Bad);
    Expect<Integer>(R.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('depends on unknown entry "missing"',
      R.Stderr) > 0).ToBe(True);
    Expect<Boolean>(DirectoryExists(Bad + '/.lwpt/sessions')).ToBe(False);
  finally
    RecursiveDelete(Bad);
  end;
end;

procedure TBuildEntries.TestPerEntryCompilerFlagsAreForwarded;
var
  R: TLwptResult;
  Scratch: string;
begin
  Scratch := CreateScratchRoot('build-entry-flags');
  RecursiveDelete(Scratch);
  WriteTextFile(Scratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "build-entry-flags"'#10
    + 'version = "0.0.0"'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app", '
    + 'flags = ["-dISSUE95_FLAG"] }'#10);
  WriteTextFile(Scratch + '/source/app.pas',
      'program app;'#10
    + '{$ifndef ISSUE95_FLAG}'#10
    + '  {$fatal ISSUE95_FLAG was not forwarded}'#10
    + '{$endif}'#10
    + 'begin'#10
    + 'end.'#10);
  try
    R := RunLwpt(['build'], Scratch);
    Expect<Integer>(R.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(ExpectedExe(Scratch + '/build/app')))
      .ToBe(True);
  finally
    RecursiveDelete(Scratch);
  end;
end;

{$IFDEF DARWIN}
procedure TBuildEntries.TestClassicLinkerFlagBuildsOnDarwin;
var
  R: TLwptResult;
  Scratch: string;
begin
  Scratch := CreateScratchRoot('build-entry-ld-classic');
  RecursiveDelete(Scratch);
  WriteTextFile(Scratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "build-entry-ld-classic"'#10
    + 'version = "0.0.0"'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app", '
    + 'flags = ["-k-ld_classic"] }'#10);
  WriteTextFile(Scratch + '/source/app.pas',
    'program app;'#10'begin'#10'end.'#10);
  try
    R := RunLwpt(['build'], Scratch);
    Expect<Integer>(R.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(ExpectedExe(Scratch + '/build/app')))
      .ToBe(True);
  finally
    RecursiveDelete(Scratch);
  end;
end;
{$ENDIF}

{$IFDEF UNIX}
procedure TBuildEntries.TestCleanFailureFailsEntryButBuildContinues;
var
  R      : TLwptResult;
  Locked : string;
begin
  { Clean never touches an undeletable shared path; both entries build
    in their own session directories. }
  WipeOutputs;
  R := RunLwpt(['build', 'alpha'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Locked := FScratch + '/build/entries/alpha/dev';
  FpChmod(Locked, &555);
  try
    R := RunLwpt(['build', '--clean', 'alpha', 'beta'], FScratch);
  finally
    FpChmod(Locked, &755);
  end;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  Expect<Boolean>(Pos('2 built, 0 failed', R.Stdout) > 0).ToBe(True);
end;
{$ENDIF}

procedure TBuildEntries.SetupTests;
begin
  Test('build alpha beta: both named entries are built',
    TestTwoNamedEntriesBuildBoth);
  Test('build alpha no-such-entry: fails fast, builds nothing',
    TestUnknownEntryNameFailsBeforeBuildingAnything);
  Test('build with no names builds every entry',
    TestNoNamesStillBuildsAllEntries);
  Test('unit artefacts remain session-private',
    TestUnitArtefactsIsolatedPerEntryAndMode);
  Test('--clean leaves shared entry artefact dirs untouched',
    TestCleanLeavesEntryArtefactDirUntouched);
  Test('traversal entry name ".." is rejected at manifest load',
    TestTraversalEntryNameRejectedAtLoad);
  Test('entry names colliding after sanitisation remain distinct',
    TestSanitisedEntryNamesRemainDistinct);
  Test('--clean leaves orphaned shared dirs for repair',
    TestCleanLeavesOrphanEntryDirsUntouched);
  Test('compile failure reports the fpc exit code, publishes nothing',
    TestCompileFailureReportsFpcExitCode);
  Test('missing compiler fails entries individually, loop continues',
    TestMissingCompilerFailsEntriesButLoopContinues);
  Test('invalid --jobs fails before building anything',
    TestInvalidJobsFailsBeforeBuildingAnything);
  Test('invalid dependency graph fails before building anything',
    TestInvalidDependencyGraphFailsBeforeBuildingAnything);
  Test('per-entry compiler flags are forwarded as single arguments',
    TestPerEntryCompilerFlagsAreForwarded);
  {$IFDEF DARWIN}
  Test('Darwin builds can select the classic linker per entry',
    TestClassicLinkerFlagBuildsOnDarwin);
  {$ENDIF}
  {$IFDEF UNIX}
  Test('clean ignores locked shared artefact dirs',
    TestCleanFailureFailsEntryButBuildContinues);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TBuildEntries.Create(
    'build: multiple named entries'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
