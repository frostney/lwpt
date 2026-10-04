{ TestSeamIsolation.Test — release binaries ignore LWPT_TEST_* (ADR-0044).

  The LWPT_TEST_* fetch-redirection and fault-injection seams are compiled
  only into the test-flavoured binary (`lwpt-testing` build entry,
  INSTALL_TESTING). ./build/lwpt is built exactly like a release binary for
  this purpose (no INSTALL_TESTING), so it must ignore every such variable.

  Each case runs one scenario twice: the test-flavoured binary proves the
  variable is effective, and ./build/lwpt proves the same variable changes
  nothing. Dependencies point at a local endpoint that refuses connections,
  so the release binary's ordinary request is refused by the fetch policy
  (ADR-0048) deterministically, without touching the internet. }
program TestSeamIsolation.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.HTTPMockServer,
  Tests.LwptSubprocess,
  Tests.ProcessSupport,
  Tests.Scratch,
  Tests.TarSynth;

type
  TTestSeamIsolation = class(TTestSuite)
  private
    FScratch, FReleaseBinary, FTestingBinary: string;
    function RunWith(const ABinary, ARoot: string;
      const AArguments, AEnvironment: array of string): TLwptResult;
    procedure WriteProject(const ARoot, ADependencies: string);
    function PackageArchive(const AName: string): TBytes;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestGitFixtureDirectoryIsIgnored;
    procedure TestArchiveOriginIsIgnored;
    procedure TestFaultInjectionIsIgnored;
    procedure TestReleaseGuardMarkerIsTestBuildOnly;
    {$IFDEF UNIX}
    procedure TestReleaseGuardFailsClosed;
    {$ENDIF}
  end;

const
  SEAM_COMMIT = '5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed';

function TTestSeamIsolation.RunWith(const ABinary, ARoot: string;
  const AArguments, AEnvironment: array of string): TLwptResult;
begin
  SetLwptBinaryPath(ABinary);
  try
    Result := RunLwpt(AArguments, ARoot, AEnvironment);
  finally
    SetLwptBinaryPath(FReleaseBinary);
  end;
end;

procedure TTestSeamIsolation.WriteProject(const ARoot, ADependencies: string);
begin
  RecursiveDelete(ARoot);
  ForceDirectories(ARoot + '/source');
  WriteTextFile(ARoot + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteTextFile(ARoot + '/lwpt.toml',
    '[package]'#10 + 'name = "seam-isolation"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10 + ADependencies);
end;

function TTestSeamIsolation.PackageArchive(const AName: string): TBytes;
var Entries: TByteArrays;
begin
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry(AName + '-fixture/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "' + AName + '"'#10
      + 'version = "1.0.0"'#10 + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry(AName + '-fixture/source/' + AName
    + '.pas', BytesOf('unit ' + AName + ';'#10 + 'interface'#10
      + 'implementation'#10 + 'end.'#10));
  Result := Gzip(BuildTar(Entries));
end;

procedure TTestSeamIsolation.TestGitFixtureDirectoryIsIgnored;
var
  Root, FixtureRoot, Origin: string;
  Refused: TMockRefusedEndpoint;
  Run: TLwptResult;
begin
  Root := FScratch + '/git-fixture';
  FixtureRoot := FScratch + '/git-fixture-data';
  RecursiveDelete(FixtureRoot);
  ForceDirectories(FixtureRoot + '/refs');
  WriteTextFile(FixtureRoot + '/refs/seam.refs',
    'tag|v1.0.0|' + SEAM_COMMIT + '|'#10);
  ForceDirectories(FixtureRoot + '/archives/seam');
  WriteBytesToFile(FixtureRoot + '/archives/seam/' + SEAM_COMMIT
    + '.tar.gz', PackageArchive('seam'));

  Refused := TMockRefusedEndpoint.Create;
  try
    Origin := 'https://' + Refused.Host + ':' + IntToStr(Refused.Port);
    WriteProject(Root,
      '[sources.refused]'#10
      + 'archive = "' + Origin + '/{user}/{repository}/{ref}.tar.gz"'#10
      + 'git = "' + Origin + '/{user}/{repository}.git"'#10
      + '[dependencies]'#10
      + 'seam = "refused:fixture/seam@^1.0.0"'#10);

    Run := RunWith(FTestingBinary, Root, ['install'],
      [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FixtureRoot]);
    DumpRunFailure('test-flavoured fixture install', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(Root + '/.lwpt/modules/seam/source/seam.pas'))
      .ToBe(True);

    WriteProject(Root,
      '[sources.refused]'#10
      + 'archive = "' + Origin + '/{user}/{repository}/{ref}.tar.gz"'#10
      + 'git = "' + Origin + '/{user}/{repository}.git"'#10
      + '[dependencies]'#10
      + 'seam = "refused:fixture/seam@^1.0.0"'#10);
    SysUtils.DeleteFile(FixtureRoot + '/requests.log');
    Run := RunWith(FReleaseBinary, Root, ['install'],
      [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FixtureRoot]);
  finally
    Refused.Free;
  end;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  { The ordinary request path is taken, and the fetch policy refuses the
    loopback endpoint (ADR-0048) instead of reading the fixture. }
  Expect<Boolean>(Pos('fetch destination not allowed', Run.Stderr) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(FixtureRoot + '/requests.log')).ToBe(False);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/seam')).ToBe(False);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
end;

procedure TTestSeamIsolation.TestArchiveOriginIsIgnored;
var
  Root, Dependencies: string;
  Refused: TMockRefusedEndpoint;
  Mock: TMockHTTPServer;
  Run: TLwptResult;
begin
  Root := FScratch + '/archive-origin';
  Refused := TMockRefusedEndpoint.Create;
  try
    Dependencies := '[dependencies]'#10 + 'seam = "https://'
      + Refused.Host + ':' + IntToStr(Refused.Port) + '/seam.tar.gz"'#10;

    WriteProject(Root, Dependencies);
    Mock := TMockHTTPServer.Create(BuildSimpleResponse(
      PackageArchive('seam')));
    try
      Mock.Start;
      Run := RunWith(FTestingBinary, Root, ['install'],
        [PROJECT_NAME + '_TEST_ARCHIVE_ORIGIN=http://127.0.0.1:'
           + IntToStr(Mock.Port),
         PROJECT_NAME + '_TEST_ARCHIVE_TIMEOUT_MS=5000']);
      Expect<Boolean>(Mock.WaitDone(5000)).ToBe(True);
    finally
      Mock.Free;
    end;
    DumpRunFailure('test-flavoured archive-origin install', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(Root + '/.lwpt/modules/seam/source/seam.pas'))
      .ToBe(True);

    WriteProject(Root, Dependencies);
    Mock := TMockHTTPServer.Create(BuildSimpleResponse(
      PackageArchive('seam')));
    try
      Mock.Start;
      Run := RunWith(FReleaseBinary, Root, ['install'],
        [PROJECT_NAME + '_TEST_ARCHIVE_ORIGIN=http://127.0.0.1:'
           + IntToStr(Mock.Port),
         PROJECT_NAME + '_TEST_ARCHIVE_TIMEOUT_MS=5000']);
      { The redirected origin is never contacted. }
      Expect<Boolean>(Mock.WaitDone(200)).ToBe(False);
    finally
      Mock.Free;
    end;
  finally
    Refused.Free;
  end;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('fetch destination not allowed', Run.Stderr) > 0)
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/seam')).ToBe(False);
end;

procedure TTestSeamIsolation.TestFaultInjectionIsIgnored;
var Root, Dependencies: string; Run: TLwptResult;
begin
  Root := FScratch + '/fault-injection';
  Dependencies := '[dependencies]'#10 + 'leaf = "./vendor/leaf"'#10;
  WriteProject(Root, Dependencies);
  ForceDirectories(Root + '/vendor/leaf/source');
  WriteTextFile(Root + '/vendor/leaf/lwpt.toml',
    '[package]'#10 + 'name = "leaf"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(Root + '/vendor/leaf/source/leaf.pas',
    'unit leaf;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);

  Run := RunWith(FTestingBinary, Root, ['install'],
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('injected failure after lockfile publication',
    Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);

  Run := RunWith(FReleaseBinary, Root, ['install'],
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']);
  DumpRunFailure('release-flavoured install with fault seam set', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/.lwpt/modules/leaf/source/leaf.pas'))
    .ToBe(True);
end;

{ release.yml refuses to publish a binary containing any marker listed in
  tests/test-seam-markers.txt. This is the guard's positive canary: every
  marker is compiled into the test build and absent from a binary built
  without INSTALL_TESTING, so the list can neither go stale nor match
  release code. }
procedure TTestSeamIsolation.TestReleaseGuardMarkerIsTestBuildOnly;
var
  Markers: TStringList;
  TestingBytes, ReleaseBytes: string;
  MarkerIndex: Integer;
begin
  TestingBytes := ReadBinaryFile(ExpectedExe(FTestingBinary));
  ReleaseBytes := ReadBinaryFile(ExpectedExe(FReleaseBinary));
  Markers := TStringList.Create;
  try
    Markers.LoadFromFile(ExpandFileName('tests/test-seam-markers.txt'));
    Expect<Boolean>(Markers.Count > 0).ToBe(True);
    Expect<Boolean>(Markers.IndexOf(PROJECT_NAME + '_TEST_') >= 0)
      .ToBe(True);
    for MarkerIndex := 0 to Markers.Count - 1 do
    begin
      Expect<Boolean>(Markers[MarkerIndex] <> '').ToBe(True);
      if Pos(Markers[MarkerIndex], TestingBytes) = 0 then
        WriteLn('marker missing from test build: ', Markers[MarkerIndex]);
      Expect<Boolean>(Pos(Markers[MarkerIndex], TestingBytes) > 0)
        .ToBe(True);
      if Pos(Markers[MarkerIndex], ReleaseBytes) > 0 then
        WriteLn('marker present in release build: ', Markers[MarkerIndex]);
      Expect<Boolean>(Pos(Markers[MarkerIndex], ReleaseBytes) > 0)
        .ToBe(False);
    end;
  finally
    Markers.Free;
  end;
end;

{$IFDEF UNIX}
{ The run: block of release.yml's test-seam guard step, dedented, so the
  test exercises exactly the shell the release job runs. }
function ReleaseGuardScript: string;
const
  StepName = '- name: Check test seams are compiled out';
var
  Workflow: TStringList;
  LineIndex, RunIndent, BodyIndent: Integer;
  Line: string;

  function Indent(const AText: string): Integer;
  begin
    Result := 0;
    while (Result < Length(AText)) and (AText[Result + 1] = ' ') do
      Inc(Result);
  end;

begin
  Result := '';
  Workflow := TStringList.Create;
  try
    Workflow.LoadFromFile(ExpandFileName('.github/workflows/release.yml'));
    LineIndex := 0;
    while (LineIndex < Workflow.Count)
          and (Trim(Workflow[LineIndex]) <> StepName) do
      Inc(LineIndex);
    Expect<Boolean>(LineIndex < Workflow.Count).ToBe(True);
    while (LineIndex < Workflow.Count)
          and (Trim(Workflow[LineIndex]) <> 'run: |') do
      Inc(LineIndex);
    Expect<Boolean>(LineIndex < Workflow.Count).ToBe(True);
    RunIndent := Indent(Workflow[LineIndex]);
    BodyIndent := -1;
    Inc(LineIndex);
    while LineIndex < Workflow.Count do
    begin
      Line := Workflow[LineIndex];
      if Trim(Line) <> '' then
      begin
        if Indent(Line) <= RunIndent then Break;
        if BodyIndent < 0 then BodyIndent := Indent(Line);
        Line := Copy(Line, BodyIndent + 1, MaxInt);
      end;
      Result := Result + Line + #10;
      Inc(LineIndex);
    end;
  finally
    Workflow.Free;
  end;
end;

{ Runs the guard in AWorkDir, returning its exit code and output. }
function RunReleaseGuard(const AWorkDir, AScript: string;
  out AOutput: string): Integer;
var ScriptPath: string;
begin
  ScriptPath := AWorkDir + '/guard.sh';
  WriteTextFile(ScriptPath, AScript);
  Result := RunChildCommand(AWorkDir, '/bin/sh',
    ['-c', 'bash ./guard.sh 2>&1'], AOutput);
end;

{ Clean staged binaries pass; a test build fails; a binary the scanner
  cannot read fails too instead of passing as "no markers". }
procedure TTestSeamIsolation.TestReleaseGuardFailsClosed;
var
  Script, WorkDir, Output: string;
  ExitStatus: Integer;
begin
  Script := ReleaseGuardScript;
  Expect<Boolean>(Pos('grep', Script) > 0).ToBe(True);
  WorkDir := FScratch + '/release-guard';
  RecursiveDelete(WorkDir);
  ForceDirectories(WorkDir + '/tests');
  ForceDirectories(WorkDir + '/staged');
  Expect<Boolean>(CopyFileContent(ExpandFileName(
    'tests/test-seam-markers.txt'), WorkDir + '/tests/test-seam-markers.txt'))
    .ToBe(True);

  Expect<Boolean>(CopyFileContent(ExpectedExe(FReleaseBinary),
    WorkDir + '/staged/lwpt')).ToBe(True);
  ExitStatus := RunReleaseGuard(WorkDir, Script, Output);
  Expect<Integer>(ExitStatus).ToBe(0);
  Expect<Boolean>(Pos('no test seam markers in staged binaries', Output) > 0)
    .ToBe(True);

  Expect<Boolean>(CopyFileContent(ExpectedExe(FTestingBinary),
    WorkDir + '/staged/lwpt')).ToBe(True);
  ExitStatus := RunReleaseGuard(WorkDir, Script, Output);
  Expect<Boolean>(ExitStatus <> 0).ToBe(True);
  Expect<Boolean>(Pos('contains test seam markers', Output) > 0).ToBe(True);

  SysUtils.DeleteFile(WorkDir + '/staged/lwpt');
  Expect<Integer>(fpSymlink(PChar(WorkDir + '/missing-binary'),
    PChar(WorkDir + '/staged/lwpt'))).ToBe(0);
  ExitStatus := RunReleaseGuard(WorkDir, Script, Output);
  Expect<Boolean>(ExitStatus <> 0).ToBe(True);
  Expect<Boolean>(Pos('cannot scan staged/lwpt', Output) > 0).ToBe(True);
end;
{$ENDIF}

procedure TTestSeamIsolation.BeforeAll;
begin
  FReleaseBinary := ExpandFileName('build/lwpt');
  FTestingBinary := LwptTestingBinaryPath;
  SetLwptBinaryPath(FReleaseBinary);
  FScratch := CreateScratchRoot('test-seam-isolation');
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
end;

procedure TTestSeamIsolation.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

procedure TTestSeamIsolation.SetupTests;
begin
  Test('the release binary ignores the git fixture directory',
    TestGitFixtureDirectoryIsIgnored);
  Test('the release binary ignores the archive origin override',
    TestArchiveOriginIsIgnored);
  Test('the release binary ignores fault-injection variables',
    TestFaultInjectionIsIgnored);
  Test('every release guard marker exists only in the test build',
    TestReleaseGuardMarkerIsTestBuildOnly);
  {$IFDEF UNIX}
  Test('the release guard passes clean binaries and fails contaminated or '
    + 'unreadable ones', TestReleaseGuardFailsClosed);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TTestSeamIsolation.Create(
    'test seams: release binaries ignore ' + PROJECT_NAME + '_TEST_*'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
