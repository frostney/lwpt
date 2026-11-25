{ TestInputChange.Test — a test run whose compiler inputs change after it
  starts is void instead of reporting results from two source states. }
program TestInputChange.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch,

  LWPT.ObjectStore,
  LWPT.WorkerBudget;

const
  SHARED_ONE = 'unit Shared; interface const V = 1; implementation end.';
  SHARED_TWO = 'unit Shared; interface const V = 2; implementation end.';
  SHARED_HALF_EDITED = 'unit Shared; interface const V = ';

type
  TTestInputChange = class(TTestSuite)
  private
    FScratch: string;
    function Environment(const ACacheRoot: string): TStringArray;
    function MarkerPath(const AProjectRoot, AName: string): string;
    procedure WriteProject(const AProjectRoot, AInitialShared,
      AEditedShared: string; const AEditedPath: string = 'source/Shared.pas');
    procedure RequireExit(const ALabel: string; const ARun: TLwptResult;
      const AExpected: Integer);
    procedure RequireStableB(const AProjectRoot, ACacheName: string);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestEditDuringRunVoidsLaterJobs;
    procedure TestHalfEditedInputIsVoidNotCompileFailure;
    procedure TestCacheHitAfterEditIsVoid;
    procedure TestUnchangedContentRunsAsBefore;
    procedure TestNewProjectRootFileVoidsRun;
    procedure TestRootLevelProgramDoesNotWatchWholeProject;
    procedure TestFlagSearchDirectoryEditVoidsRun;
    procedure TestConfigurationIncludeDirectoryEditVoidsRun;
    procedure TestDeclaredRootOutputsDoNotVoidRun;
    procedure TestFlagMacroSearchDirectoryEditVoidsRun;
    procedure TestProfileIncludeDirectoryEditVoidsRun;
  end;

function PascalString(const AValue: string): string;
begin
  Result := '''' + StringReplace(AValue, '''', '''''', [rfReplaceAll])
    + '''';
end;

{ A fixture test program that leaves an existence marker when it runs. }
function MarkerStatements(const AMarker: string): string;
begin
  Result := '  TFileStream.Create(' + PascalString(AMarker)
    + ', fmCreate).Free;'#10;
end;

procedure TTestInputChange.BeforeAll;
begin
  FScratch := CreateScratchRoot('test-input-change');
end;

function TTestInputChange.Environment(const ACacheRoot: string): TStringArray;
begin
  SetLength(Result, 4);
  Result[0] := CACHE_DIR_ENV + '=' + ACacheRoot;
  Result[1] := WORKER_STATE_DIR_ENV + '=' + FScratch + '/worker-state';
  Result[2] := WORKER_BUDGET_ENV + '=2';
  Result[3] := WORKER_LEASE_TOKEN_ENV + '=';
end;

function TTestInputChange.MarkerPath(const AProjectRoot,
  AName: string): string;
begin
  Result := AProjectRoot + '-markers/' + AName;
end;

{ Three programs that --jobs=1 runs in source order. A writes AEditedShared
  to AEditedPath (the shared unit by default) once it runs, so B and C always
  compile after the edit: the regression needs no timing. B and C use the
  unit and leave markers, which prove whether they ran. }
procedure TTestInputChange.WriteProject(const AProjectRoot, AInitialShared,
  AEditedShared: string; const AEditedPath: string);
begin
  RecursiveDelete(AProjectRoot);
  RecursiveDelete(AProjectRoot + '-markers');
  ForceDirectories(AProjectRoot + '-markers');
  WriteTextFile(AProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-input-change-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(AProjectRoot + '/source/Shared.pas', AInitialShared + #10);
  WriteTextFile(AProjectRoot + '/tests/A.Test.pas',
      'program A;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.Text := ' + PascalString(AEditedShared) + ';'#10
    + '    Lines.SaveToFile('
    + PascalString(AProjectRoot + '/' + AEditedPath) + ');'#10
    + '  finally'#10
    + '    Lines.Free;'#10
    + '  end;'#10
    + 'end.'#10);
  WriteTextFile(AProjectRoot + '/tests/B.Test.pas',
      'program B;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, Shared;'#10
    + 'begin'#10
    + '  WriteLn(''B V='', V);'#10
    + MarkerStatements(MarkerPath(AProjectRoot, 'b-ran'))
    + 'end.'#10);
  WriteTextFile(AProjectRoot + '/tests/C.Test.pas',
      'program C;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, Shared;'#10
    + 'begin'#10
    + MarkerStatements(MarkerPath(AProjectRoot, 'c-ran'))
    + 'end.'#10);
end;

procedure TTestInputChange.RequireExit(const ALabel: string;
  const ARun: TLwptResult; const AExpected: Integer);
var
  Diagnostics: TStringList;
begin
  if ARun.ExitCode = AExpected then Exit;
  Diagnostics := TStringList.Create;
  try
    DumpRunFailure(ALabel, ARun, AExpected, Diagnostics);
    Fail(Diagnostics.Text);
  finally
    Diagnostics.Free;
  end;
end;

{ Result lines print native separators; compare them in canonical form. }
function Contains(const ANeedle, AText: string): Boolean; forward;

{ Before an edit run, B alone in a stable run must compile through the
  search path under test and print W=1, so a VOID result proves the watch
  rather than a fixture the compiler never resolved. }
procedure TTestInputChange.RequireStableB(const AProjectRoot,
  ACacheName: string);
var
  Run: TLwptResult;
begin
  Run := RunLwpt(['test', 'tests/B.Test.pas', '--verbose', '--no-cache'],
    AProjectRoot, Environment(FScratch + '/' + ACacheName));
  RequireExit('stable B run', Run, 0);
  Expect<Boolean>(Contains('B W=1', Run.Stdout)).ToBe(True);
  RecursiveDelete(AProjectRoot + '-markers');
  ForceDirectories(AProjectRoot + '-markers');
end;

function Contains(const ANeedle, AText: string): Boolean;
begin
  Result := Pos(ANeedle, StringReplace(AText, '\', '/', [rfReplaceAll])) > 0;
end;

procedure TTestInputChange.TestEditDuringRunVoidsLaterJobs;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/edit';
  WriteProject(ProjectRoot, SHARED_ONE, SHARED_TWO);
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/edit-cache'));
  RequireExit('edited run', Run, 1);
  Expect<Boolean>(Contains('tests/A.Test.pas ... pass', Run.Stdout))
    .ToBe(True);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID (compiler inputs '
    + 'changed after this test run started (source/Shared.pas)', Run.Stdout))
    .ToBe(True);
  Expect<Boolean>(Contains(
    'tests/C.Test.pas ... cancelled (run void: inputs changed)', Run.Stdout))
    .ToBe(True);
  Expect<Boolean>(Contains('summary: 1 passed, 0 failed, 0 did not compile, '
    + '1 cancelled, 1 void; run void: compiler inputs changed after it '
    + 'started (source/Shared.pas); elapsed ', Run.Stdout)).ToBe(True);
  Expect<Boolean>(Contains('its results are void; rerun lwpt test',
    Run.Stderr)).ToBe(True);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'b-ran'))).ToBe(False);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'c-ran'))).ToBe(False);
end;

procedure TTestInputChange.TestHalfEditedInputIsVoidNotCompileFailure;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/half-edited';
  WriteProject(ProjectRoot, SHARED_ONE, SHARED_HALF_EDITED);
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/half-edited-cache'));
  RequireExit('half-edited run', Run, 1);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID', Run.Stdout))
    .ToBe(True);
  Expect<Boolean>(Contains('COMPILE FAILED', Run.Stdout)).ToBe(False);
  Expect<Boolean>(Contains('0 did not compile, 1 cancelled, 1 void',
    Run.Stdout)).ToBe(True);
end;

procedure TTestInputChange.TestCacheHitAfterEditIsVoid;
var
  CacheRoot, ProjectRoot: string;
  Seed, Run: TLwptResult;
begin
  CacheRoot := FScratch + '/cache-hit-cache';
  ProjectRoot := FScratch + '/cache-hit';
  RecursiveDelete(CacheRoot);
  { Seed B's cached executable for the edited state: A rewrites the unit
    with the bytes it already has, so this run passes and stores B. }
  WriteProject(ProjectRoot, SHARED_TWO, SHARED_TWO);
  Seed := RunLwpt(['test', '--jobs=1', '--verbose'], ProjectRoot,
    Environment(CacheRoot));
  RequireExit('cache seed run', Seed, 0);
  Expect<Boolean>(Contains('cache stored:', Seed.Stdout)).ToBe(True);

  { Start from the original state; after A's edit, B's fingerprint matches
    the seeded entry, so B reuses it instead of compiling. }
  WriteTextFile(ProjectRoot + '/source/Shared.pas', SHARED_ONE + #10);
  RecursiveDelete(ProjectRoot + '-markers');
  ForceDirectories(ProjectRoot + '-markers');
  Run := RunLwpt(['test', '--jobs=1', '--verbose'], ProjectRoot,
    Environment(CacheRoot));
  RequireExit('cache hit after edit', Run, 1);
  Expect<Boolean>(Contains('cache hit:', Run.Stdout)).ToBe(True);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID', Run.Stdout))
    .ToBe(True);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'b-ran'))).ToBe(False);
end;

procedure TTestInputChange.TestUnchangedContentRunsAsBefore;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/unchanged';
  { A rewrites the unit with identical bytes: content, not timestamps,
    decides whether inputs changed. }
  WriteProject(ProjectRoot, SHARED_ONE, SHARED_ONE);
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/unchanged-cache'));
  RequireExit('unchanged run', Run, 0);
  Expect<Boolean>(Contains('summary: 3 passed, 0 failed, 0 did not compile, '
    + '0 cancelled; elapsed ', Run.Stdout)).ToBe(True);
  Expect<Boolean>(Contains('void', Run.Stdout + Run.Stderr)).ToBe(False);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'b-ran'))).ToBe(True);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'c-ran'))).ToBe(True);
end;

procedure TTestInputChange.TestNewProjectRootFileVoidsRun;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/new-root-file';
  { Project-root files are implicit compiler inputs, so one that appears
    during the run is a change even though no recorded file changed. }
  WriteProject(ProjectRoot, SHARED_ONE, 'const RootAdded = 1;',
    'RootAdded.inc');
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/new-root-file-cache'));
  RequireExit('new root file run', Run, 1);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID (compiler inputs '
    + 'changed after this test run started (RootAdded.inc)', Run.Stdout))
    .ToBe(True);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'b-ran'))).ToBe(False);
end;

procedure TTestInputChange.TestRootLevelProgramDoesNotWatchWholeProject;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/root-level-program';
  { A writes into a subdirectory that no compile reads. A program at the
    project root must not make that directory an input: like the cache
    fingerprint, its source directory is the root's own files only. }
  WriteProject(ProjectRoot, SHARED_ONE, 'second', 'scratch/out.txt');
  WriteTextFile(ProjectRoot + '/scratch/out.txt', 'first');
  WriteTextFile(ProjectRoot + '/Root.Test.pas',
    'program Root;'#10'begin'#10'end.'#10);
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/root-level-program-cache'));
  RequireExit('root-level program run', Run, 0);
  Expect<Boolean>(Contains('summary: 4 passed, 0 failed, 0 did not compile, '
    + '0 cancelled; elapsed ', Run.Stdout)).ToBe(True);
end;

procedure TTestInputChange.TestFlagSearchDirectoryEditVoidsRun;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/flag-search-directory';
  { A unit directory that only a [test] flag names is a compiler input, also
    when the flag lists several directories and uses a wildcard. }
  WriteProject(ProjectRoot, SHARED_ONE,
    'unit Extra; interface const W = 2; implementation end.',
    'extra/one/Extra.pas');
  WriteTextFile(ProjectRoot + '/extra/one/Extra.pas',
    'unit Extra; interface const W = 1; implementation end.'#10);
  WriteTextFile(ProjectRoot + '/tests/B.Test.pas',
      'program B;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, Extra;'#10
    + 'begin'#10
    + '  WriteLn(''B W='', W);'#10
    + MarkerStatements(MarkerPath(ProjectRoot, 'b-ran'))
    + 'end.'#10);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-input-change-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[test]'#10
    + 'flags = ["-Fumissing;extra/*"]'#10);
  RequireStableB(ProjectRoot, 'flag-search-directory-stable-cache');
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/flag-search-directory-cache'));
  RequireExit('flag search directory run', Run, 1);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID (compiler inputs '
    + 'changed after this test run started (extra/one/Extra.pas)',
    Run.Stdout)).ToBe(True);
  Expect<Boolean>(FileExists(MarkerPath(ProjectRoot, 'b-ran'))).ToBe(False);
end;

procedure TTestInputChange.TestConfigurationIncludeDirectoryEditVoidsRun;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/cfg-include-directory';
  { An include directory that only the compiler configuration file names
    is a compiler input. }
  WriteProject(ProjectRoot, SHARED_ONE, 'const W = 2;', 'incs/Value.inc');
  WriteTextFile(ProjectRoot + '/incs/Value.inc', 'const W = 1;'#10);
  WriteTextFile(ProjectRoot + '/custom.cfg', '-Fiincs'#10);
  WriteTextFile(ProjectRoot + '/tests/B.Test.pas',
      'program B;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + '{$I Value.inc}'#10
    + 'begin'#10
    + '  WriteLn(''B W='', W);'#10
    + MarkerStatements(MarkerPath(ProjectRoot, 'b-ran'))
    + 'end.'#10);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-input-change-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[lwpt]'#10
    + 'cfg-file = "custom.cfg"'#10);
  RequireStableB(ProjectRoot, 'cfg-include-directory-stable-cache');
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/cfg-include-directory-cache'));
  RequireExit('configuration include directory run', Run, 1);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID (compiler inputs '
    + 'changed after this test run started (incs/Value.inc)', Run.Stdout))
    .ToBe(True);
end;

procedure TTestInputChange.TestDeclaredRootOutputsDoNotVoidRun;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/declared-root-outputs';
  { Declared build outputs at the project root are published by builds,
    not read by compiles: replacing one or creating another mid-run keeps
    the run valid. }
  WriteProject(ProjectRoot, SHARED_ONE, SHARED_ONE);
  WriteTextFile(ProjectRoot + '/source/app.pas', 'program app; begin end.'#10);
  WriteTextFile(ProjectRoot + '/source/tool.pas',
    'program tool; begin end.'#10);
  WriteTextFile(ProjectRoot + '/app.bin', 'first');
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-input-change-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "app.bin" }'#10
    + 'tool = { source = "source/tool.pas", output = "tool.bin" }'#10);
  WriteTextFile(ProjectRoot + '/tests/A.Test.pas',
      'program A;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.Text := ''second'';'#10
    + '    Lines.SaveToFile('
    + PascalString(ProjectRoot + '/app.bin') + ');'#10
    + '    Lines.SaveToFile('
    + PascalString(ProjectRoot + '/tool.bin') + ');'#10
    + '  finally'#10
    + '    Lines.Free;'#10
    + '  end;'#10
    + 'end.'#10);
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/declared-root-outputs-cache'));
  RequireExit('declared root outputs run', Run, 0);
  Expect<Boolean>(Contains('summary: 3 passed, 0 failed, 0 did not compile, '
    + '0 cancelled; elapsed ', Run.Stdout)).ToBe(True);
end;

procedure TTestInputChange.TestFlagMacroSearchDirectoryEditVoidsRun;
var
  ProjectRoot, Target: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/flag-macro-directory';
  { FPC expands $FPCTARGET to "<cpu>-<os>" of the target it compiles for,
    the same compiler and target that compiled this program. The include
    lives where the macro resolves, so the stable run proves FPC read it
    there, and the watch must cover it. }
  Target := LowerCase({$I %FPCTARGETCPU%}) + '-'
    + LowerCase({$I %FPCTARGETOS%});
  WriteProject(ProjectRoot, SHARED_ONE, 'const W = 2;',
    'extra/' + Target + '/Value.inc');
  WriteTextFile(ProjectRoot + '/extra/' + Target + '/Value.inc',
    'const W = 1;'#10);
  WriteTextFile(ProjectRoot + '/tests/B.Test.pas',
      'program B;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + '{$I Value.inc}'#10
    + 'begin'#10
    + '  WriteLn(''B W='', W);'#10
    + MarkerStatements(MarkerPath(ProjectRoot, 'b-ran'))
    + 'end.'#10);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-input-change-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[test]'#10
    + 'flags = ["-Fiextra/$FPCTARGET"]'#10);
  RequireStableB(ProjectRoot, 'flag-macro-directory-stable-cache');
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/flag-macro-directory-cache'));
  RequireExit('flag macro directory run', Run, 1);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID (compiler inputs '
    + 'changed after this test run started (extra/' + Target
    + '/Value.inc)', Run.Stdout)).ToBe(True);
end;

procedure TTestInputChange.TestProfileIncludeDirectoryEditVoidsRun;
var
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/profile-include-directory';
  { The selected compiler profile's own arguments reach the compiler too. }
  WriteProject(ProjectRoot, SHARED_ONE, 'const W = 2;', 'incs/Value.inc');
  WriteTextFile(ProjectRoot + '/incs/Value.inc', 'const W = 1;'#10);
  WriteTextFile(ProjectRoot + '/tests/B.Test.pas',
      'program B;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + '{$I Value.inc}'#10
    + 'begin'#10
    + '  WriteLn(''B W='', W);'#10
    + MarkerStatements(MarkerPath(ProjectRoot, 'b-ran'))
    + 'end.'#10);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-input-change-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[compiler]'#10
    + 'default = "pinned"'#10
    + '[compiler.profiles.pinned]'#10
    + 'driver = "fpc"'#10
    + 'args = ["-Fiincs"]'#10);
  RequireStableB(ProjectRoot, 'profile-include-directory-stable-cache');
  Run := RunLwpt(['test', '--jobs=1', '--no-cache'], ProjectRoot,
    Environment(FScratch + '/profile-include-directory-cache'));
  RequireExit('profile include directory run', Run, 1);
  Expect<Boolean>(Contains('tests/B.Test.pas ... VOID (compiler inputs '
    + 'changed after this test run started (incs/Value.inc)', Run.Stdout))
    .ToBe(True);
end;

procedure TTestInputChange.SetupTests;
begin
  Test('an input edited during the run voids later jobs and stops the run',
    TestEditDuringRunVoidsLaterJobs);
  Test('a half-edited input is void, not a compile failure',
    TestHalfEditedInputIsVoidNotCompileFailure);
  Test('a cache hit taken after an edit is void',
    TestCacheHitAfterEditIsVoid);
  Test('rewriting identical content keeps the run unchanged',
    TestUnchangedContentRunsAsBefore);
  Test('a file added at the project root voids the run',
    TestNewProjectRootFileVoidsRun);
  Test('a program at the project root does not watch the whole project',
    TestRootLevelProgramDoesNotWatchWholeProject);
  Test('a search directory named by a test flag is watched',
    TestFlagSearchDirectoryEditVoidsRun);
  Test('an include directory named by the compiler configuration is watched',
    TestConfigurationIncludeDirectoryEditVoidsRun);
  Test('declared build outputs at the project root do not void the run',
    TestDeclaredRootOutputsDoNotVoidRun);
  Test('a search directory behind a compiler macro is watched',
    TestFlagMacroSearchDirectoryEditVoidsRun);
  Test('an include directory named by the compiler profile is watched',
    TestProfileIncludeDirectoryEditVoidsRun);
end;

begin
  TestRunnerProgram.AddSuite(TTestInputChange.Create('test input change'));
  TestRunnerProgram.Run;
end.
