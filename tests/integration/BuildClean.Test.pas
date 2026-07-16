{ BuildClean.Test — non-destructive `lwpt build --clean`.

  Contract under test:

    build --clean   compiles in a fresh private session and forces
                    source recompilation without deleting shared files
                    under build/
    build --clean   leaves non-artefact files under build/ alone
    build --clean   with no build/ dir at all succeeds (nothing to
                    clean is not an error)
    build --clean   never follows or modifies paths it does not own

  Goes through the real binary via Tests.LwptSubprocess so flag parsing
  and the non-destructive clean path inside CmdBuild are both covered.
  The planted artefact files are empty decoys: FPC never reads them
  because private output paths plus -B force a full rebuild — the test
  checks they remain untouched. }

program BuildClean.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TBuildClean = class(TTestSuite)
  private
    FScratch: string;
    procedure WipeOutputs;
    procedure PlantDecoys;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestCleanLeavesSharedArtefactsUntouched;
    procedure TestCleanKeepsNonArtefactFiles;
    procedure TestCleanWithoutBuildDirSucceeds;
    {$IFDEF UNIX}
    procedure TestCleanDoesNotFollowSymlinkedDirs;
    {$ENDIF}
  end;

procedure TBuildClean.BeforeAll;
const
  TRIVIAL = 'begin'#10'end.'#10;
begin
  FScratch := ExpandFileName(
    GetCurrentDir + '/build/tests/tmp/build-clean');
  RecursiveDelete(FScratch);

  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "buildclean"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "src/alpha.pas", output = "build/alpha" }'#10);
  WriteTextFile(FScratch + '/src/alpha.pas', 'program alpha;'#10 + TRIVIAL);
end;

procedure TBuildClean.WipeOutputs;
begin
  RecursiveDelete(FScratch + '/build');
end;

{ Shared artefacts a previous FPC run could have left: the target's own,
  a dependency unit's, and one in a nested dir. A session-safe clean
  cannot assume it owns any of them. }
procedure TBuildClean.PlantDecoys;
begin
  WriteTextFile(FScratch + '/build/alpha.ppu', '');
  WriteTextFile(FScratch + '/build/SomeDep.ppu', '');
  WriteTextFile(FScratch + '/build/SomeDep.o', '');
  WriteTextFile(FScratch + '/build/nested/Other.or', '');
  WriteTextFile(FScratch + '/build/nested/Other.reslst', '');
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TBuildClean.TestCleanLeavesSharedArtefactsUntouched;
var R: TLwptResult;
begin
  WipeOutputs;
  PlantDecoys;
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  { Shared paths belong to neither this session nor its clean operation. }
  Expect<Boolean>(FileExists(FScratch + '/build/SomeDep.ppu')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/build/SomeDep.o')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/build/nested/Other.or'))
    .ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/build/nested/Other.reslst'))
    .ToBe(True);
end;

procedure TBuildClean.TestCleanKeepsNonArtefactFiles;
var R: TLwptResult;
begin
  WipeOutputs;
  WriteTextFile(FScratch + '/build/keep.txt', 'not an artefact'#10);
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/build/keep.txt')).ToBe(True);
end;

procedure TBuildClean.TestCleanWithoutBuildDirSucceeds;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(Pos('build mode: dev, clean', R.Stdout) > 0).ToBe(True);
end;

{ Clean must not traverse build/ at all, including through a symlink.
  Unix only because Windows symlink creation needs privileges. Compiled
  out rather than an empty body: the test runner counts a test that runs
  zero assertions as a failure ("Test has no assertions"). }
{$IFDEF UNIX}
procedure TBuildClean.TestCleanDoesNotFollowSymlinkedDirs;
var R: TLwptResult;
begin
  WipeOutputs;
  RecursiveDelete(FScratch + '/outside');
  WriteTextFile(FScratch + '/outside/Precious.ppu', '');
  ForceDirectories(FScratch + '/build');
  Expect<Boolean>(fpSymlink(
    PAnsiChar(FScratch + '/outside'),
    PAnsiChar(FScratch + '/build/escape')) = 0).ToBe(True);
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { The build does not traverse shared build/ state at all. }
  Expect<Boolean>(FileExists(FScratch + '/outside/Precious.ppu'))
    .ToBe(True);
end;
{$ENDIF}

procedure TBuildClean.SetupTests;
begin
  Test('build --clean leaves shared artefacts untouched',
    TestCleanLeavesSharedArtefactsUntouched);
  Test('build --clean keeps non-artefact files under build/',
    TestCleanKeepsNonArtefactFiles);
  Test('build --clean with no build/ dir still succeeds',
    TestCleanWithoutBuildDirSucceeds);
  {$IFDEF UNIX}
  Test('build --clean does not follow symlinked dirs out of build/',
    TestCleanDoesNotFollowSymlinkedDirs);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TBuildClean.Create(
    'build: non-destructive --clean'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
