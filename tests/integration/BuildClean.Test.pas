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

  LWPT.ObjectStore,
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
    procedure TestNoCacheBypassesReusableBuildResult;
    procedure TestPrerequisiteOutputChangeInvalidatesDependentResult;
    {$IFDEF UNIX}
    procedure TestCleanDoesNotFollowSymlinkedDirs;
    {$ENDIF}
  end;

procedure TBuildClean.BeforeAll;
const
  TRIVIAL = 'begin'#10'end.'#10;
begin
  FScratch := CreateScratchRoot('build-clean');
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

procedure TBuildClean.TestNoCacheBypassesReusableBuildResult;
var
  CacheRoot: string;
  Environment: array of string;
  First, Hit, Bypassed, CleanBypassed: TLwptResult;
begin
  WipeOutputs;
  CacheRoot := FScratch + '/cache';
  RecursiveDelete(CacheRoot);
  SetLength(Environment, 1);
  Environment[0] := CACHE_DIR_ENV + '=' + CacheRoot;

  First := RunLwpt(['build', '--verbose'], FScratch, Environment);
  Expect<Integer>(First.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('cache miss: no-result', First.Stdout) > 0).ToBe(True);

  Hit := RunLwpt(['build', '--verbose'], FScratch, Environment);
  Expect<Integer>(Hit.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('cache hit:', Hit.Stdout) > 0).ToBe(True);

  Bypassed := RunLwpt(['build', '--verbose', '--no-cache'], FScratch,
    Environment);
  Expect<Integer>(Bypassed.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('cache miss: disabled', Bypassed.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('cache hit:', Bypassed.Stdout) = 0).ToBe(True);

  CleanBypassed := RunLwpt(
    ['build', '--verbose', '--clean', '--no-cache'], FScratch, Environment);
  Expect<Integer>(CleanBypassed.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('cache miss: disabled', CleanBypassed.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('cache hit:', CleanBypassed.Stdout) = 0).ToBe(True);
end;

procedure TBuildClean.TestPrerequisiteOutputChangeInvalidatesDependentResult;
var
  CacheRoot: string;
  Environment: array of string;
  First, Second, Changed: TLwptResult;
  procedure RequireSuccessfulRun(const ALabel: string;
    const ARun: TLwptResult);
  var
    Diagnostics: TStringList;
  begin
    if ARun.ExitCode = 0 then Exit;
    Diagnostics := TStringList.Create;
    try
      DumpRunFailure(ALabel, ARun, 0, Diagnostics);
      Fail(Diagnostics.Text);
    finally
      Diagnostics.Free;
    end;
  end;
begin
  WipeOutputs;
  CacheRoot := FScratch + '/graph-cache';
  RecursiveDelete(CacheRoot);
  SetLength(Environment, 1);
  Environment[0] := CACHE_DIR_ENV + '=' + CacheRoot;
  WriteTextFile(FScratch + '/alpha-src/value.inc',
    'const GENERATED_VALUE = ''ONE'';'#10);
  WriteTextFile(FScratch + '/alpha-src/alpha.pas',
    'program alpha;'#10'begin end.'#10);
  WriteTextFile(FScratch + '/app-src/app.pas',
    'program app;'#10
    + '{$I ../build/alpha}'#10
    + 'begin WriteLn(GENERATED_VALUE); end.'#10);
  WriteTextFile(FScratch + '/scripts/publish-include.pas',
    'program PublishInclude;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.LoadFromFile(ParamStr(1));'#10
    + '    Lines.SaveToFile(ParamStr(2));'#10
    + '  finally'#10
    + '    Lines.Free;'#10
    + '  end;'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "buildcachegraph"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["alpha-src", "app-src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "alpha-src/alpha.pas", output = "build/alpha", '
    + 'postbuild = { publish = { command = "instantfpc", '
    + 'args = ["scripts/publish-include.pas", "alpha-src/value.inc", '
    + '"{item.output}"] } } }'#10
    + 'app = { source = "app-src/app.pas", output = "build/app", '
    + 'depends = ["alpha"] }'#10);

  First := RunLwpt(['build', '--verbose'], FScratch, Environment);
  RequireSuccessfulRun('first prerequisite build', First);
  Expect<Boolean>(Pos('cache hit:', First.Stdout) = 0).ToBe(True);
  Second := RunLwpt(['build', '--verbose'], FScratch, Environment);
  RequireSuccessfulRun('second prerequisite build', Second);
  Expect<Boolean>(Pos('cache hit:', Second.Stdout) > 0).ToBe(True);

  WriteTextFile(FScratch + '/alpha-src/value.inc',
    'const GENERATED_VALUE = ''TWO'';'#10);
  Changed := RunLwpt(['build', '--verbose'], FScratch, Environment);
  RequireSuccessfulRun('changed prerequisite build', Changed);
  Expect<Boolean>(Pos('cache hit:', Changed.Stdout) = 0).ToBe(True);
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
  Test('build --no-cache bypasses a reusable result',
    TestNoCacheBypassesReusableBuildResult);
  {$IFDEF UNIX}
  Test('build --clean does not follow symlinked dirs out of build/',
    TestCleanDoesNotFollowSymlinkedDirs);
  {$ENDIF}
  Test('prerequisite output changes invalidate dependent results',
    TestPrerequisiteOutputChangeInvalidatesDependentResult);
end;

begin
  TestRunnerProgram.AddSuite(TBuildClean.Create(
    'build: non-destructive --clean'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
