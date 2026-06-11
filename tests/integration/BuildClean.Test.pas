{ BuildClean.Test — `lwpt build --clean` artefact sweep.

  Contract under test:

    build --clean   sweeps FPC intermediate artefacts (.ppu/.o/.or/
                    .res/.reslst) out of the WHOLE build/ tree —
                    including nested dirs and artefacts belonging to
                    units other than the target's own source —
                    before compiling, and still builds successfully
    build --clean   leaves non-artefact files under build/ alone
    build --clean   with no build/ dir at all succeeds (nothing to
                    clean is not an error)
    build --clean   treats symlinks as leaves — the sweep must never
                    delete artefacts outside build/ through a link

  Goes through the real binary via Tests.LwptSubprocess so the flag
  parsing AND the sweep ordering inside CmdBuild are both covered.
  The planted artefact files are empty decoys: FPC never reads them
  because -B forces a full rebuild — the test only checks they are
  gone afterwards. }

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
    procedure TestCleanSweepsArtefactsEverywhereUnderBuild;
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

{ Stale artefacts a previous FPC run could have left: the target's own,
  a dependency unit's, and one in a nested dir — the old per-target
  delete only ever caught the first. }
procedure TBuildClean.PlantDecoys;
begin
  WriteTextFile(FScratch + '/build/alpha.ppu', '');
  WriteTextFile(FScratch + '/build/SomeDep.ppu', '');
  WriteTextFile(FScratch + '/build/SomeDep.o', '');
  WriteTextFile(FScratch + '/build/nested/Other.or', '');
  WriteTextFile(FScratch + '/build/nested/Other.reslst', '');
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TBuildClean.TestCleanSweepsArtefactsEverywhereUnderBuild;
var R: TLwptResult;
begin
  WipeOutputs;
  PlantDecoys;
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  { every planted decoy is gone, not just the target's own }
  Expect<Boolean>(FileExists(FScratch + '/build/SomeDep.ppu')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/build/SomeDep.o')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/build/nested/Other.or'))
    .ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/build/nested/Other.reslst'))
    .ToBe(False);
  { the sweep reports itself }
  Expect<Boolean>(Pos('clean: removed', R.Stdout) > 0).ToBe(True);
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
  Expect<Boolean>(Pos('clean: no FPC artefacts', R.Stdout) > 0).ToBe(True);
end;

{ The sweep must treat a symlink as a leaf: following one would delete
  artefacts OUTSIDE build/ (or loop forever on a cyclic link). Unix
  only — Windows symlink creation needs privileges and the sweep's
  link handling is byte-identical across platforms. Compiled out
  rather than an empty body: the test runner counts a test that runs
  zero assertions as a failure ("Test has no assertions"), which is
  exactly what reddened the Windows CI legs after this test landed. }
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
  { the artefact behind the link survives — the sweep stayed inside
    build/ }
  Expect<Boolean>(FileExists(FScratch + '/outside/Precious.ppu'))
    .ToBe(True);
end;
{$ENDIF}

procedure TBuildClean.SetupTests;
begin
  Test('build --clean sweeps artefacts across the whole build/ tree',
    TestCleanSweepsArtefactsEverywhereUnderBuild);
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
    'build: --clean artefact sweep'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
