{ InstallFetchFailure.Test — spawn `lwpt install` against a
  manifest whose dependency cannot be fetched, and assert the binary
  exits cleanly with EFetchError on stderr and no orphans left under
  .lwpt/tmp/.

  Failure modes covered:

    - Local source pointing at a non-existent directory. FetchToCache
      raises EFetchError naming the dep + the missing path; the error-
      error model + recovery hint then prints to stderr.

    - The archive-fetch override contract itself: which values
      LWPT_TEST_ARCHIVE_ORIGIN accepts, which it refuses, and the
      identity guarantee that keeps production URL construction
      untouched when it is absent. Pure, so it runs on every platform.

    - HTTP 500, refused connection, a stalled peer bounded by the
      request budget, and a fixed-length body cut short mid-transfer.
      Each is produced by a loopback mock server and driven through the
      real `lwpt install` subprocess on Unix and native Windows.

  Every HTTP case asserts the same transactional contract as the local
  one: a failed install leaves no lockfile, no cfg, no cached archive,
  no module tree, and an empty .lwpt/tmp/. }

program InstallFetchFailure.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,   { must come first so TThread has a driver before
                Tests.HTTPMockServer's background server starts }
  {$ENDIF}
  Classes,
  SysUtils,

  Tests.HTTPMockServer,

  LWPT.Core,
  LWPT.Install,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TInstallFetchFailureE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot, FMissingDep: string;
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestMissingLocalSourceExitsNonZero;
    procedure TestMissingLocalSourceMessageNamesTheDepAndPath;
    procedure TestMissingLocalSourceLeavesTmpEmpty;
  end;

  { The override is the one seam that lets an offline fixture stand in
    for a git host, so what it refuses matters as much as what it
    accepts: anything reaching past loopback would turn a test knob
    into a way to redirect a real install. }
  TArchiveFetchOriginContract = class(TTestSuite)
  private
    function Refuses(const AOverride: string): Boolean;
  public
    procedure SetupTests; override;
    procedure TestAbsentOverrideReturnsTheCanonicalURLUnchanged;
    procedure TestLoopbackOverrideReplacesOnlyTheOrigin;
    procedure TestOverrideTrailingSlashDoesNotDoubleTheSeparator;
    procedure TestRemoteHostIsRefused;
    procedure TestLocalhostNameIsRefused;
    procedure TestNonLoopbackNumericAddressIsRefused;
    procedure TestHTTPSOverrideIsRefused;
    procedure TestMissingPortIsRefused;
    procedure TestOverrideCarryingAPathIsRefused;
    procedure TestUserInformationIsRefused;
    procedure TestTimeoutDefaultsAndBounds;
  end;

  TInstallHTTPFetchFailure = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    function NewProjectRoot(const AName: string): string;
    function InstallAgainstPort(const ARoot: string; const APort: Word;
      const ATimeoutMilliseconds: string): TLwptResult;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestServerErrorNamesTheDependencyAndStatus;
    procedure TestServerErrorLeavesTheProjectUntouched;
    procedure TestRefusedConnectionIsReportedAsAFetchFailure;
    procedure TestTruncatedArchiveIsRejectedNotCached;
    procedure TestStalledServerFailsInsideTheRequestBudget;
  end;

function DirIsEmpty(const APath: string): Boolean;
var R: TSearchRec;
begin
  Result := True;
  if not DirectoryExists(APath) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, R) = 0 then
  begin
    try
      repeat
        if (R.Name <> '.') and (R.Name <> '..') then Exit(False);
      until FindNext(R) <> 0;
    finally
      FindClose(R);
    end;
  end;
end;

procedure ExpectFailedInstallLeavesCommittedStateUntouched(
  const ARoot: string);
begin
  Expect<Boolean>(FileExists(ARoot + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(FileExists(ARoot + '/lwpt.cfg')).ToBe(False);
  Expect<Boolean>(DirIsEmpty(ARoot + '/.lwpt/archives')).ToBe(True);
  Expect<Boolean>(DirIsEmpty(ARoot + '/.lwpt/tmp')).ToBe(True);
  Expect<Boolean>(DirectoryExists(ARoot + '/.lwpt/modules/mock-dep'))
    .ToBe(False);
end;

procedure TInstallFetchFailureE2E.SetupScratchProject;
begin
  ForceDirectories(FRoot + '/source');
  { Tiny program file so the manifest parses + units = ["source"]
    resolves to an existing directory. }
  WriteTextFile(FRoot + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''noop'');'#10 +
    'end.'#10);

  { Manifest with one local-source dep pointing at a path that does
    not exist. lwpt install must fail with EFetchError naming the dep
    and the missing path. }
  WriteTextFile(FRoot + '/lwpt.toml',
    '[package]'#10 +
    'name = "fetch-failure-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    { absolute-path local source via the bare-string shorthand.
      Path starts with '/' so it goes through the implicit-local
      detection in ParseDependencySource (no need for local: prefix). }
    'orphan-dep = "' + FMissingDep + '"'#10);
end;

procedure TInstallFetchFailureE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('install-fetch-failure-e2e');
  FRoot    := FScratch + '/root';
  FMissingDep := FScratch + '/this-path-does-not-exist';
  {$IFDEF MSWINDOWS}
  FMissingDep := StringReplace(FMissingDep, '\', '/', [rfReplaceAll]);
  {$ENDIF}
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;
end;

procedure TInstallFetchFailureE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallFetchFailureE2E.TestMissingLocalSourceExitsNonZero;
var R: TLwptResult;
begin
  R := RunLwpt(['install'], FRoot);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
end;

procedure TInstallFetchFailureE2E.TestMissingLocalSourceMessageNamesTheDepAndPath;
var R: TLwptResult; Combined: string;
begin
  R := RunLwpt(['install'], FRoot);
  Combined := R.Stdout + R.Stderr;
  { The error message must name BOTH the dep ("orphan-dep") and the
    missing path. That's the entire point of the EFetchError message
    — telling the user what failed without grepping the source. }
  Expect<Boolean>(Pos('orphan-dep', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('this-path-does-not-exist', Combined) > 0).ToBe(True);
end;

procedure TInstallFetchFailureE2E.TestMissingLocalSourceLeavesTmpEmpty;
var R: TLwptResult; TmpDir: string;
begin
  R := RunLwpt(['install'], FRoot);
  { After a failed install, .lwpt/tmp/ MUST be either non-existent
    or empty. Orphans here would mean the failed-fetch path left
    half-written content behind, defeating the atomic-rename
    contract. (R is consumed for the exit code's sake; the orphan
    check is the real assertion.) }
  TmpDir := FRoot + '/.lwpt/tmp';
  Expect<Boolean>(DirIsEmpty(TmpDir)).ToBe(True);
  if R.ExitCode = 0 then;   { quiet unused-result warning }
end;

procedure TInstallFetchFailureE2E.SetupTests;
begin
  Test('install with missing local source exits non-zero',
    TestMissingLocalSourceExitsNonZero);
  Test('error message names both the dep and the missing source path',
    TestMissingLocalSourceMessageNamesTheDepAndPath);
  Test('failed install leaves .lwpt/tmp/ empty (no orphans)',
    TestMissingLocalSourceLeavesTmpEmpty);
end;

{ ===========================================================================
  The override contract
  =========================================================================== }

const
  CANONICAL_ARCHIVE_URL =
    'https://github.com/example/mock-dep/archive/v1.0.0.tar.gz';
  CANONICAL_ARCHIVE_PATH = '/example/mock-dep/archive/v1.0.0.tar.gz';

function TArchiveFetchOriginContract.Refuses(const AOverride: string): Boolean;
begin
  Result := False;
  try
    ApplyArchiveFetchOrigin(CANONICAL_ARCHIVE_URL, AOverride);
  except
    on E: EFetchError do
      { The message has to name the variable. A bare "invalid value"
        leaves the reader guessing which knob they set wrong. }
      Result := Pos(ARCHIVE_FETCH_ORIGIN_ENV, E.Message) > 0;
  end;
end;

procedure TArchiveFetchOriginContract.
  TestAbsentOverrideReturnsTheCanonicalURLUnchanged;
begin
  { The production guarantee, stated as an assertion: with the seam
    unset the fetch URL is the canonically constructed one, byte for
    byte. Everything else in this suite is about refusing values; this
    is the one that says the feature costs production nothing. }
  Expect<string>(ApplyArchiveFetchOrigin(CANONICAL_ARCHIVE_URL, ''))
    .ToBe(CANONICAL_ARCHIVE_URL);
end;

procedure TArchiveFetchOriginContract.TestLoopbackOverrideReplacesOnlyTheOrigin;
begin
  { The path is what the host templates in FetchURL produced, so it has
    to survive intact. Otherwise the fixture stops exercising the URL
    construction it is supposed to cover. }
  Expect<string>(ApplyArchiveFetchOrigin(CANONICAL_ARCHIVE_URL,
    'http://127.0.0.1:39501'))
    .ToBe('http://127.0.0.1:39501' + CANONICAL_ARCHIVE_PATH);
end;

procedure TArchiveFetchOriginContract.
  TestOverrideTrailingSlashDoesNotDoubleTheSeparator;
begin
  Expect<string>(ApplyArchiveFetchOrigin(CANONICAL_ARCHIVE_URL,
    'http://127.0.0.1:39501/'))
    .ToBe('http://127.0.0.1:39501' + CANONICAL_ARCHIVE_PATH);
end;

procedure TArchiveFetchOriginContract.TestRemoteHostIsRefused;
begin
  Expect<Boolean>(Refuses('http://example.com:8080')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestLocalhostNameIsRefused;
begin
  { Refused on purpose even though it usually resolves to loopback:
    accepting a name means accepting whatever the host's resolver says
    it means, which is exactly the property the numeric-only rule buys. }
  Expect<Boolean>(Refuses('http://localhost:39501')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestNonLoopbackNumericAddressIsRefused;
begin
  Expect<Boolean>(Refuses('http://10.0.0.1:39501')).ToBe(True);
  Expect<Boolean>(Refuses('http://128.0.0.1:39501')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestHTTPSOverrideIsRefused;
begin
  Expect<Boolean>(Refuses('https://127.0.0.1:39501')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestMissingPortIsRefused;
begin
  Expect<Boolean>(Refuses('http://127.0.0.1')).ToBe(True);
  Expect<Boolean>(Refuses('http://127.0.0.1:')).ToBe(True);
  Expect<Boolean>(Refuses('http://127.0.0.1:0')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestOverrideCarryingAPathIsRefused;
begin
  { A bare origin only. A path would make the override a rewrite rule
    rather than a redirect, and the canonical path is the part the
    fixture is meant to preserve. }
  Expect<Boolean>(Refuses('http://127.0.0.1:39501/mirror')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestUserInformationIsRefused;
begin
  Expect<Boolean>(Refuses('http://user@127.0.0.1:39501')).ToBe(True);
end;

procedure TArchiveFetchOriginContract.TestTimeoutDefaultsAndBounds;
var Refused: Boolean;
begin
  Expect<Integer>(ResolveArchiveFetchTimeout(''))
    .ToBe(DEFAULT_ARCHIVE_FETCH_TIMEOUT);
  Expect<Integer>(ResolveArchiveFetchTimeout('250')).ToBe(250);
  Refused := False;
  try
    ResolveArchiveFetchTimeout('0');
  except
    on E: EFetchError do Refused := True;
  end;
  Expect<Boolean>(Refused).ToBe(True);
  Refused := False;
  try
    ResolveArchiveFetchTimeout('not-a-number');
  except
    on E: EFetchError do Refused := True;
  end;
  Expect<Boolean>(Refused).ToBe(True);
end;

procedure TArchiveFetchOriginContract.SetupTests;
begin
  Test('an absent override leaves the canonical URL byte for byte',
    TestAbsentOverrideReturnsTheCanonicalURLUnchanged);
  Test('a loopback override replaces the origin and keeps the path',
    TestLoopbackOverrideReplacesOnlyTheOrigin);
  Test('a trailing slash on the override does not double the separator',
    TestOverrideTrailingSlashDoesNotDoubleTheSeparator);
  Test('a remote host is refused', TestRemoteHostIsRefused);
  Test('the name localhost is refused', TestLocalhostNameIsRefused);
  Test('a numeric address outside 127.0.0.0/8 is refused',
    TestNonLoopbackNumericAddressIsRefused);
  Test('an https override is refused', TestHTTPSOverrideIsRefused);
  Test('an override without an explicit port is refused',
    TestMissingPortIsRefused);
  Test('an override carrying a path is refused',
    TestOverrideCarryingAPathIsRefused);
  Test('an override carrying user information is refused',
    TestUserInformationIsRefused);
  Test('the request budget defaults and refuses out-of-range values',
    TestTimeoutDefaultsAndBounds);
end;

{ ===========================================================================
  HTTP failure modes through the real subprocess
  =========================================================================== }

const
  CRLF = #13#10;
  { The stall case alone needs a short request budget, so a peer that never
    answers fails the test quickly rather than blocking; 250 ms sits well
    under the 60 s ceiling that case asserts. }
  STALL_BUDGET = '250';
  { The other failure cases answer or close at once, so they need no tight
    budget. A roomier value keeps a loaded runner from tripping the read
    timeout before the real response lands, which would surface as a
    "timed out" message and mask the failure each case actually asserts. }
  HEALTHY_BUDGET = '5000';

{ Response bytes built by hand: BuildSimpleResponse always declares a
  truthful Content-Length, and these shapes are the point. }
function RawResponse(const AStatusLine: string; const ADeclaredLength: Integer;
  const ASentBody: TBytes): TBytes;
var
  Head: TBytes;
begin
  Head := BytesOf(AStatusLine + CRLF
    + 'Content-Type: application/octet-stream' + CRLF
    + 'Content-Length: ' + IntToStr(ADeclaredLength) + CRLF
    + 'Connection: close' + CRLF
    + CRLF);
  SetLength(Result, Length(Head) + Length(ASentBody));
  if Length(Head) > 0 then Move(Head[0], Result[0], Length(Head));
  if Length(ASentBody) > 0 then
    Move(ASentBody[0], Result[Length(Head)], Length(ASentBody));
end;

function GzipPrefix: TBytes;
begin
  { A plausible archive opening, so the failure cannot be mistaken for
    "the bytes were obviously not an archive". }
  SetLength(Result, 10);
  Result[0] := $1F; Result[1] := $8B; Result[2] := $08; Result[3] := $00;
  Result[4] := $00; Result[5] := $00; Result[6] := $00; Result[7] := $00;
  Result[8] := $00; Result[9] := $03;
end;

function ClosedLoopbackPort: Word;
var
  Mock: TMockHTTPServer;
begin
  { Bind an ephemeral port, learn its number, release it. Nothing is
    listening afterwards, so the connect is refused immediately rather
    than waiting on anything. }
  Mock := TMockHTTPServer.Create(nil);
  try
    Result := Mock.Port;
  finally
    Mock.Free;
  end;
end;

function TInstallHTTPFetchFailure.NewProjectRoot(const AName: string): string;
begin
  { One project per case: each mock server serves a single connection,
    so cases must not share fetch state. }
  Result := FScratch + '/' + AName;
  ForceDirectories(Result + '/source');
  WriteTextFile(Result + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''noop'');'#10 +
    'end.'#10);
  { A git-host dep pinned to a literal tag. Literal tags skip remote ref
    resolution, so the install makes exactly one HTTP request, the
    archive fetch, which is what a single-connection mock can serve. }
  WriteTextFile(Result + '/lwpt.toml',
    '[package]'#10 +
    'name = "http-fetch-failure"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'mock-dep = "example/mock-dep@v1.0.0"'#10);
end;

function TInstallHTTPFetchFailure.InstallAgainstPort(const ARoot: string;
  const APort: Word; const ATimeoutMilliseconds: string): TLwptResult;
begin
  Result := RunLwpt(['install'], ARoot,
    [ARCHIVE_FETCH_ORIGIN_ENV + '=http://127.0.0.1:' + IntToStr(APort),
     ARCHIVE_FETCH_TIMEOUT_ENV + '=' + ATimeoutMilliseconds]);
end;

procedure TInstallHTTPFetchFailure.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('install-http-fetch-failure');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
end;

procedure TInstallHTTPFetchFailure.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallHTTPFetchFailure.TestServerErrorNamesTheDependencyAndStatus;
var
  Mock: TMockHTTPServer;
  Root, Combined: string;
  Run: TLwptResult;
begin
  Root := NewProjectRoot('server-error');
  Mock := TMockHTTPServer.Create(RawResponse(
    'HTTP/1.1 500 Internal Server Error', 0, nil));
  try
    Mock.Start;
    Run := InstallAgainstPort(Root, Mock.Port, HEALTHY_BUDGET);
    Mock.WaitDone;
  finally
    Mock.Free;
  end;
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  { Dependency, operation, and status: enough to act on without
    reading the source or re-running under a debugger. }
  Expect<Boolean>(Pos('mock-dep', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('archive fetch', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('500', Combined) > 0).ToBe(True);
end;

procedure TInstallHTTPFetchFailure.TestServerErrorLeavesTheProjectUntouched;
var
  Mock: TMockHTTPServer;
  Root: string;
  Run: TLwptResult;
begin
  Root := NewProjectRoot('server-error-state');
  Mock := TMockHTTPServer.Create(RawResponse(
    'HTTP/1.1 500 Internal Server Error', 0, nil));
  try
    Mock.Start;
    Run := InstallAgainstPort(Root, Mock.Port, HEALTHY_BUDGET);
    Mock.WaitDone;
  finally
    Mock.Free;
  end;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  { A failed fetch commits nothing: no lockfile, no cfg, no cached
    archive, no module tree, and no residue in tmp. }
  ExpectFailedInstallLeavesCommittedStateUntouched(Root);
end;

procedure TInstallHTTPFetchFailure.TestRefusedConnectionIsReportedAsAFetchFailure;
var
  Root, Combined: string;
  Run: TLwptResult;
begin
  Root := NewProjectRoot('refused');
  Run := InstallAgainstPort(Root, ClosedLoopbackPort, HEALTHY_BUDGET);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('mock-dep', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('archive fetch', Combined) > 0).ToBe(True);
  { The connect-failure text survives the EFetchError wrapping, which
    is what keeps the e2e tier's transient-downtime skip working. }
  Expect<Boolean>(Pos('Failed to connect to', Combined) > 0).ToBe(True);
  ExpectFailedInstallLeavesCommittedStateUntouched(Root);
end;

procedure TInstallHTTPFetchFailure.TestTruncatedArchiveIsRejectedNotCached;
var
  Mock: TMockHTTPServer;
  Root, Combined: string;
  Run: TLwptResult;
begin
  { The fixture the issue asks for: Content-Length declares far more
    than the peer sends, then the peer closes. Left unchecked the
    client returns a zero-padded buffer that hashes and caches like a
    real archive, so the assertion that matters is the empty archives
    directory. The failure has to happen before anything is committed. }
  Root := NewProjectRoot('truncated');
  Mock := TMockHTTPServer.Create(RawResponse('HTTP/1.1 200 OK', 65536,
    GzipPrefix));
  try
    Mock.Start;
    Run := InstallAgainstPort(Root, Mock.Port, HEALTHY_BUDGET);
    Mock.WaitDone;
  finally
    Mock.Free;
  end;
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('mock-dep', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('archive fetch', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('truncated fixed-length body', Combined) > 0).ToBe(True);
  ExpectFailedInstallLeavesCommittedStateUntouched(Root);
end;

procedure TInstallHTTPFetchFailure.TestStalledServerFailsInsideTheRequestBudget;
var
  Mock: TMockHTTPServer;
  Root, Combined: string;
  Run: TLwptResult;
  Elapsed: QWord;
const
  { Bounded, not precise: the claim under test is that the install
    stops on its own rather than blocking forever. }
  CEILING_MS = 10000;
begin
  { Create binds and listens; Start is deliberately never called, so
    the connect lands in the kernel backlog and nothing is ever
    accepted or answered. Without a request budget this install hangs. }
  Mock := TMockHTTPServer.Create(nil);
  try
    Root := NewProjectRoot('stalled');
    Elapsed := GetTickCount64;
    Run := InstallAgainstPort(Root, Mock.Port, STALL_BUDGET);
    Elapsed := GetTickCount64 - Elapsed;
  finally
    Mock.Free;
  end;
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('mock-dep', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('deadline exceeded', Combined) > 0).ToBe(True);
  Expect<Boolean>(Elapsed < CEILING_MS).ToBe(True);
  ExpectFailedInstallLeavesCommittedStateUntouched(Root);
end;

procedure TInstallHTTPFetchFailure.SetupTests;
begin
  Test('an HTTP 500 names the dependency, the operation, and the status',
    TestServerErrorNamesTheDependencyAndStatus);
  Test('a failed fetch commits no lockfile, cfg, archive, or module tree',
    TestServerErrorLeavesTheProjectUntouched);
  Test('a refused connection is reported as an archive-fetch failure',
    TestRefusedConnectionIsReportedAsAFetchFailure);
  Test('a truncated fixed-length archive is refused and never cached',
    TestTruncatedArchiveIsRejectedNotCached);
  Test('a stalled server fails inside the request budget',
    TestStalledServerFailsInsideTheRequestBudget);
end;

begin
  TestRunnerProgram.AddSuite(TInstallFetchFailureE2E.Create(
    'install: fetch failure (E2E)'));
  TestRunnerProgram.AddSuite(TArchiveFetchOriginContract.Create(
    'install: archive-fetch origin override contract'));
  TestRunnerProgram.AddSuite(TInstallHTTPFetchFailure.Create(
    'install: HTTP archive-fetch failure'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
