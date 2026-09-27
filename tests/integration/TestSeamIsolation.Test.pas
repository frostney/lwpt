{ TestSeamIsolation.Test — release binaries ignore LWPT_TEST_* (ADR-0044).

  The LWPT_TEST_* fetch-redirection and fault-injection seams are compiled
  only into the test-flavoured binary (`lwpt-testing` build entry,
  INSTALL_TESTING). ./build/lwpt is built exactly like a release binary for
  this purpose (no INSTALL_TESTING), so it must ignore every such variable.

  Each case runs one scenario twice: the test-flavoured binary proves the
  variable is effective, and ./build/lwpt proves the same variable changes
  nothing. Dependencies point at a local endpoint that refuses connections,
  so the release binary's ordinary request is refused by the fetch policy
  (ADR-0045) deterministically, without touching the internet. }
program TestSeamIsolation.Test;

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
    loopback endpoint (ADR-0045) instead of reading the fixture. }
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
end;

begin
  TestRunnerProgram.AddSuite(TTestSeamIsolation.Create(
    'test seams: release binaries ignore ' + PROJECT_NAME + '_TEST_*'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
