{ InstallScript.E2E.Test — exercise scripts/install.sh end-to-end
  against the current published GitHub release.

  This is the test that would have caught the macOS .zip regression:
  release.yml shipped macOS archives as .zip while install.sh downloads
  .tar.gz (the `*win*` substring matched `darwin`). PR #8 fixed it, but
  nothing caught it first. This test runs the real install script
  against a real release — the script constructs the asset URL, curls
  it from GitHub Releases, verifies the checksum, extracts the archive,
  and installs the binary — then asserts the installed binary reports
  the resolved tag. An asset-name mismatch (the .zip bug class) surfaces
  as a 404 against a release we know exists, which fails hard here.

  No pinned version constant. The test resolves "latest" the same way
  install.sh does — GET /releases/latest, which returns the newest
  release NOT flagged `prerelease: true` (see CONTEXT.md "Prerelease":
  the GitHub flag is orthogonal to pre-1.0; `0.1.0` published without a
  hyphen IS a normal release and IS returned). The resolved tag is the
  single source of truth: it is passed to install.sh AND the expected
  `lwpt --version` is derived from it (binary == tag). Because release
  binaries stamp the version from the git tag (ADR-0026), that equality
  holds for every stamp-from-tag release; the assertion is *relative*
  (the install path works and the binary self-reports its tag), so it
  never breaks on version drift — only on a genuine install.sh defect.

  Until the first normal (non-prerelease-flagged) release exists, an
  explicit 404 from /releases/latest skips the live smoke; the
  per-release install check in release.yml covers prerelease-flagged
  rc.x meanwhile. Connectivity failures matching the narrow transient
  matcher also skip. GitHub API 403/429 responses skip only when their
  diagnostic identifies a rate limit. Other curl failures, HTTP errors,
  and malformed successful responses fail.

  Unix-only: install.sh is /bin/sh. The Windows install.ps1 smoke test
  is a separate future addition.

  Skip semantics (each logs a "[skip]" line and passes):
    - non-Unix host                  → skip (install.sh is sh)
    - LWPT_ENABLE_NETWORK unset or not 1 → skip
    - curl unavailable               → skip (environment, not a defect)
    - no normal release published    → skip (nothing to smoke yet)
    - GitHub API rate limit          → skip (distinct from connectivity)
    - clean connect/DNS failure to
      github.com (transient downtime) → skip
  Resolve-time HTTP/API errors, unclassified curl failures, and empty
  or malformed successful responses fail hard.
  A 404 / checksum mismatch / missing binary AFTER a tag resolved is NOT
  a network outage and fails hard — that's the regression class this
  guards. }

program InstallScript.E2E.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  fpjson,
  jsonparser,
  Process,
  SysUtils,

  TestingPascalLibrary,
  Tests.Scratch,
  Tests.LwptSubprocess;

type
  TLatestTagOutcome = (
    ltoResolved,
    ltoNoRelease,
    ltoTransientFailure,
    ltoRateLimited,
    ltoFailure
  );

  TLatestTagResolution = record
    CurlExitCode: Integer;
    HTTPStatus: string;
    ResponseBody: string;
    Tag: string;
    Stderr: string;
  end;

  TLatestTagResolutionTests = class(TTestSuite)
  private
    FBinDir, FCurlPath, FScratch: string;
    FSkipped: Boolean;
    function ResolveMode(const AMode: string): TLatestTagResolution;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestSuccessfulResponseResolves;
    procedure TestExplicitNotFoundSkips;
    procedure TestConnectivityFailureSkips;
    procedure TestRateLimitFailuresSkipDistinctly;
    procedure TestHTTPFailuresFail;
    procedure TestUnclassifiedCurlFailureFails;
    procedure TestInvalidSuccessfulResponseFails;
  end;

  TInstallScriptVerificationTests = class(TTestSuite)
  private
    FBinDir, FInstallPath, FScratch: string;
    FSkipped: Boolean;
    function RunMode(const AMode: string; out AStderr: string): Integer;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestMissingChecksumsFileFails;
    procedure TestMissingChecksumEntryFails;
    procedure TestStalledDownloadIsTerminatedWithItsDescendants;
  end;

  TInstallScriptE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FBinDir, FRepoRoot, FResolvedTag: string;
    FSkipped: Boolean;
    FInstallExitCode: Integer;
    FInstallStderr, FResolveFailure: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestLatestReleaseResolved;
    procedure TestInstallScriptExitsZero;
    procedure TestBinaryInstalledAndExecutable;
    procedure TestInstalledBinaryReportsVersion;
  end;

{ Executable-bit check. Unix uses access(2) X_OK; the test self-skips
  on non-Unix so the fallback is only there to compile. }
function FileIsExecutable(const APath: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := fpAccess(APath, X_OK) = 0;
  {$ELSE}
  Result := FileExists(APath);
  {$ENDIF}
end;

{ The GitHub repo install.sh + this test resolve releases from. Honors
  LWPT_REPO for symmetry with install.sh (default frostney/lwpt). }
function ReleasesRepo: string;
begin
  Result := GetEnvironmentVariable('LWPT_REPO');
  if Result = '' then Result := 'frostney/lwpt';
end;

{ SemVer 2.0.0 has no leading `v`; release tags may carry one for git
  convention (ADR-0009). Strip it so the derived expected matches what
  the stamped binary prints. }
function StripLeadingV(const ATag: string): string;
begin
  Result := ATag;
  if (Length(Result) > 1) and (Result[1] = 'v')
     and (Result[2] >= '0') and (Result[2] <= '9') then
    Result := Copy(Result, 2, Length(Result));
end;

const
  { install.sh downloads a release archive; this leaves room for a slow
    network while keeping a hung curl from outliving the test. }
  SH_RUN_TIMEOUT_MILLISECONDS = 300000;

{$IFDEF UNIX}
function SetProcessGroup(APid, AGroup: TPid): LongInt; cdecl;
  external 'c' name 'setpgid';

type
  { Puts a forked shell in a process group of its own before exec, so its
    descendants (curl, sleep) share a group that can be signalled as a
    whole: the shell forwards no signal to them. }
  TShellGroupBinder = class
  public
    procedure ChildForked(ASender: TObject);
  end;

procedure TShellGroupBinder.ChildForked(ASender: TObject);
begin
  SetProcessGroup(0, 0);
end;

var
  ShellGroupBinder: TShellGroupBinder;

{ Polls, bounded, until the shell is reaped and no process remains in its
  group, draining the shell's pipes meanwhile. }
function WaitForShellGroup(P: TProcess; const AGroup: TPid;
  var AStdout, AStderr: string; const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    AStdout := AStdout + DrainAvailableStream(P.Output);
    AStderr := AStderr + DrainAvailableStream(P.Stderr);
    { Running reaps the shell; kill(-group, 0) then fails with ESRCH once
      every descendant has exited. }
    Result := not P.Running and (FpKill(-AGroup, 0) <> 0);
    if Result or (GetTickCount64 - StartedAt >= ATimeoutMilliseconds) then
      Exit;
    Sleep(10);
  until False;
end;

{ Ends the shell and every descendant in its group: SIGTERM, a bounded
  wait, SIGKILL, a bounded wait. True when the group is empty. }
function TerminateShellGroup(P: TProcess; const AGroup: TPid;
  var AStdout, AStderr: string): Boolean;
begin
  FpKill(-AGroup, SIGTERM);
  Result := WaitForShellGroup(P, AGroup, AStdout, AStderr,
    CHILD_TERMINATION_GRACE_MILLISECONDS);
  if Result then Exit;
  FpKill(-AGroup, SIGKILL);
  Result := WaitForShellGroup(P, AGroup, AStdout, AStderr,
    CHILD_KILL_MILLISECONDS);
end;
{$ENDIF}

{ Run a /bin/sh program (script file or `-c` command), capturing exit
  code + stderr + stdout. Self-contained (does not go through RunLwpt,
  which targets the lwpt binary). AArgs are the args after /bin/sh. The
  run is bounded: output is drained in available-byte snapshots, so a
  stalled writer never blocks the deadline check, and past
  ATimeoutMilliseconds the shell and its descendants are ended and the
  run raises with its output. On Unix the shell leads its own process
  group, so its curl is signalled with it; that group is outside the test
  runner's own, so if this program itself is killed the group is not
  (process-tree ownership for spawning callers is tracked in #365). }
function RunSh(const AArgs: array of string; const AInDir: string;
  const AExtraEnv: array of string; out AStdout, AStderr: string;
  const ATimeoutMilliseconds: QWord = SH_RUN_TIMEOUT_MILLISECONDS): Integer;
var
  P: TProcess;
  i: Integer;
  Outp, Errp: string;
  StartedAt: QWord;
  TimedOut, Terminated: Boolean;
begin
  Result := -1;
  Outp := '';
  Errp := '';
  TimedOut := False;
  Terminated := True;
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    for i := Low(AArgs) to High(AArgs) do P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes];
    if AInDir <> '' then P.CurrentDirectory := AInDir;

    ConfigureProcessEnvironment(P, AExtraEnv);
    {$IFDEF UNIX}
    P.OnForkEvent := ShellGroupBinder.ChildForked;
    {$ENDIF}

    P.Execute;
    {$IFDEF UNIX}
    { Both sides set the group, so it exists before either proceeds;
      failure after the child's exec is harmless. }
    SetProcessGroup(P.ProcessID, P.ProcessID);
    {$ENDIF}
    StartedAt := GetTickCount64;
    while P.Running
      and (GetTickCount64 - StartedAt < ATimeoutMilliseconds) do
    begin
      Outp := Outp + DrainAvailableStream(P.Output);
      Errp := Errp + DrainAvailableStream(P.Stderr);
      Sleep(10);
    end;
    TimedOut := P.Running;
    if TimedOut then
    begin
      {$IFDEF UNIX}
      Terminated := TerminateShellGroup(P, P.ProcessID, Outp, Errp);
      {$ELSE}
      Terminated := TerminateChildProcess(P, Outp, Errp);
      {$ENDIF}
    end
    else
    begin
      Outp := Outp + DrainAvailableStream(P.Output);
      Errp := Errp + DrainAvailableStream(P.Stderr);
      Result := P.ExitCode;
    end;
  finally
    P.Free;
  end;
  AStdout := Outp;
  AStderr := Errp;
  if TimedOut then
    raise Exception.Create('/bin/sh ' + AArgs[0] + ' exceeded its '
      + IntToStr(ATimeoutMilliseconds) + ' ms deadline and was '
      + BoolToStr(Terminated, 'terminated with its process group',
        'NOT terminated') + '; stdout: ' + Outp + '; stderr: ' + Errp);
end;

{ Extract tag_name only from a complete JSON object. Parsing the whole
  response prevents a valid-looking property in a truncated document from
  turning a malformed HTTP 200 into a resolved release. }
function ExtractLatestTag(const AResponse: string): string;
var
  JSONData, TagData: TJSONData;
begin
  Result := '';
  JSONData := nil;
  try
    try
      JSONData := GetJSON(AResponse);
    except
      Exit;
    end;
    if JSONData = nil then Exit;
    if JSONData.JSONType <> jtObject then Exit;
    TagData := TJSONObject(JSONData).Find('tag_name');
    if (TagData = nil) or (TagData.JSONType <> jtString) then Exit;
    Result := TagData.AsString;
  finally
    JSONData.Free;
  end;
end;

{ Did the install fail because the host was unreachable / curl missing,
  as opposed to a real install.sh defect (404 asset mismatch, checksum
  mismatch, missing binary)? Narrow on transient/environment signals
  only — a 404 ("returned error: 404") is deliberately NOT matched so
  the asset-naming regression class fails hard. }
function InstallFailureIsSkippable(const AStderr: string): Boolean;
var E: string;
begin
  E := LowerCase(AStderr);
  Result := (Pos('could not resolve host', E) > 0)
         or (Pos('could not resolve', E) > 0)
         or (Pos('failed to connect', E) > 0)
         or (Pos('connection refused', E) > 0)
         or (Pos('connection timed out', E) > 0)
         or (Pos('could not connect', E) > 0)
         or (Pos('curl is required', E) > 0)
         or (Pos('resolving timed out', E) > 0);
end;

{ GitHub documents rate-limit failures as 403 or 429 plus a primary or
  secondary rate-limit diagnostic. Keep this separate from the general
  transient matcher so an unrelated permission failure still fails. }
function ResolutionIsRateLimited(
  const AResolution: TLatestTagResolution): Boolean;
var E: string;
begin
  if (AResolution.HTTPStatus <> '403')
    and (AResolution.HTTPStatus <> '429') then Exit(False);
  E := LowerCase(AResolution.ResponseBody);
  Result := (Pos('api rate limit exceeded', E) > 0)
         or (Pos('secondary rate limit', E) > 0);
end;

{ Resolve the newest non-prerelease-flagged release tag while keeping
  curl's transport exit, HTTP status, response body, and stderr distinct.
  Positional shell parameters keep the scratch path and repository URL
  out of shell syntax. }
function ResolveLatestTag(const AResponsePath: string;
  const AExtraEnv: array of string): TLatestTagResolution;
var
  Cmd, HTTPOutput: string;
begin
  Result.CurlExitCode := -1;
  Result.HTTPStatus := '';
  Result.ResponseBody := '';
  Result.Tag := '';
  Result.Stderr := '';

  Cmd := 'command -v curl >/dev/null 2>&1 '
       + '|| { printf ''curl is required\n'' >&2; exit 127; }; '
       + 'github_request() { '
       + 'if [ -n "${GITHUB_TOKEN:-}" ]; then '
       + 'curl -sSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"; '
       + 'else curl -sSL "$@"; fi; }; '
       + 'HTTPStatus=$(github_request -o "$1" '
       + '-w ''%{http_code}'' "$2"); CurlExit=$?; '
       + 'printf ''%s'' "$HTTPStatus"; '
       + 'exit "$CurlExit"';
  Result.CurlExitCode := RunSh(
    ['-c', Cmd, 'resolve-latest', AResponsePath,
     'https://api.github.com/repos/' + ReleasesRepo + '/releases/latest'],
    '',
    AExtraEnv,
    HTTPOutput,
    Result.Stderr);
  Result.HTTPStatus := Trim(HTTPOutput);
  if FileExists(AResponsePath) then
  begin
    Result.ResponseBody := ReadBinaryFile(AResponsePath);
    Result.Tag := ExtractLatestTag(Result.ResponseBody);
  end;
end;

function LatestTagOutcome(
  const AResolution: TLatestTagResolution): TLatestTagOutcome;
begin
  if AResolution.CurlExitCode <> 0 then
  begin
    if InstallFailureIsSkippable(AResolution.Stderr) then
      Exit(ltoTransientFailure);
    Exit(ltoFailure);
  end;
  if AResolution.HTTPStatus = '404' then Exit(ltoNoRelease);
  if ResolutionIsRateLimited(AResolution) then Exit(ltoRateLimited);
  if AResolution.HTTPStatus <> '200' then Exit(ltoFailure);
  if AResolution.Tag = '' then Exit(ltoFailure);
  Result := ltoResolved;
end;

function LatestTagFailureMessage(
  const AResolution: TLatestTagResolution): string;
begin
  if AResolution.CurlExitCode <> 0 then
    Result := Format('curl exited %d while resolving the latest release',
      [AResolution.CurlExitCode])
  else if (AResolution.HTTPStatus <> '')
    and (AResolution.HTTPStatus <> '000')
    and (AResolution.HTTPStatus <> '200') then
    Result := 'latest-release API returned HTTP ' + AResolution.HTTPStatus
  else if (AResolution.HTTPStatus = '')
    or (AResolution.HTTPStatus = '000') then
    Result := 'curl did not report an HTTP status for the latest release'
  else
    Result := 'latest-release API returned HTTP 200 without a valid tag_name';
  if Trim(AResolution.ResponseBody) <> '' then
    Result := Result + LineEnding + Trim(AResolution.ResponseBody);
  if Trim(AResolution.Stderr) <> '' then
    Result := Result + LineEnding + Trim(AResolution.Stderr);
end;

function TLatestTagResolutionTests.ResolveMode(
  const AMode: string): TLatestTagResolution;
begin
  Result := ResolveLatestTag(
    FScratch + '/response-' + AMode + '.json',
    ['PATH=' + FBinDir + ':' + GetEnvironmentVariable('PATH'),
     'INSTALL_RESOLVE_MODE=' + AMode,
     'GITHUB_TOKEN=',
     'EXPECTED_AUTHORIZATION=']);
end;

procedure TLatestTagResolutionTests.BeforeAll;
begin
  FSkipped := False;
  {$IFNDEF UNIX}
  FSkipped := True;
  WriteLn('  [skip] latest-release resolver classification requires /bin/sh; '
        + 'skipped on non-Unix');
  Exit;
  {$ENDIF}

  FScratch := CreateScratchRoot('latest-tag-resolution');
  FBinDir := FScratch + '/bin';
  FCurlPath := FBinDir + '/curl';
  ForceDirectories(FBinDir);
  WriteTextFile(FCurlPath,
    '#!/bin/sh'#10 +
    'Output=""'#10 +
    'Authorization=""'#10 +
    'while [ "$#" -gt 0 ]; do'#10 +
    '  case "$1" in'#10 +
    '    -H) Authorization="$2"; shift 2 ;;'#10 +
    '    -o) Output="$2"; shift 2 ;;'#10 +
    '    -w) shift 2 ;;'#10 +
    '    *) shift ;;'#10 +
    '  esac'#10 +
    'done'#10 +
    'if [ "${EXPECTED_AUTHORIZATION+x}" = x ] '
      + '&& [ "$Authorization" != "$EXPECTED_AUTHORIZATION" ]; then'#10 +
    '  printf ''unexpected Authorization header: %s\n'' '
      + '"$Authorization" >&2'#10 +
    '  exit 97'#10 +
    'fi'#10 +
    ': > "$Output"'#10 +
    'case "${INSTALL_RESOLVE_MODE:-success}" in'#10 +
    '  success)'#10 +
    '    printf ''%s'' ''{"tag_name":"v1.2.3"}'' > "$Output"'#10 +
    '    printf ''200'' ;;'#10 +
    '  not-found)'#10 +
    '    printf ''%s'' ''{"message":"Not Found"}'' > "$Output"'#10 +
    '    printf ''404'' ;;'#10 +
    '  not-found-curl-error)'#10 +
    '    printf ''%s'' ''{"message":"Not Found"}'' > "$Output"'#10 +
    '    printf ''404'''#10 +
    '    printf ''curl: (23) Failure writing output\n'' >&2'#10 +
    '    exit 23 ;;'#10 +
    '  forbidden)'#10 +
    '    printf ''%s'' ''{"message":"Resource not accessible by integration"}'' '
      + '> "$Output"'#10 +
    '    printf ''403'' ;;'#10 +
    '  unauthorized)'#10 +
    '    printf ''%s'' ''{"message":"Bad credentials"}'' > "$Output"'#10 +
    '    printf ''401'' ;;'#10 +
    '  unprocessable)'#10 +
    '    printf ''%s'' ''{"message":"Validation Failed"}'' > "$Output"'#10 +
    '    printf ''422'' ;;'#10 +
    '  primary-rate-limit)'#10 +
    '    printf ''%s'' ''{"message":"API rate limit exceeded for 192.0.2.1."}'' '
      + '> "$Output"'#10 +
    '    printf ''403'' ;;'#10 +
    '  rate-limit-curl-error)'#10 +
    '    printf ''%s'' ''{"message":"API rate limit exceeded for 192.0.2.1."}'' '
      + '> "$Output"'#10 +
    '    printf ''403'''#10 +
    '    printf ''curl: (23) Failure writing output\n'' >&2'#10 +
    '    exit 23 ;;'#10 +
    '  secondary-rate-limit)'#10 +
    '    printf ''%s'' ''{"message":"You have exceeded a secondary rate limit."}'' '
      + '> "$Output"'#10 +
    '    printf ''429'' ;;'#10 +
    '  server-error)'#10 +
    '    printf ''%s'' ''{"message":"server error"}'' > "$Output"'#10 +
    '    printf ''500'' ;;'#10 +
    '  connectivity)'#10 +
    '    printf ''000'''#10 +
    '    printf ''curl: (6) Could not resolve host: api.github.com\n'' >&2'#10 +
    '    exit 6 ;;'#10 +
    '  curl-error)'#10 +
    '    printf ''000'''#10 +
    '    printf ''curl: (23) Failure writing output\n'' >&2'#10 +
    '    exit 23 ;;'#10 +
    '  malformed)'#10 +
    '    printf ''%s'' ''{"tag_name":'' > "$Output"'#10 +
    '    printf ''200'' ;;'#10 +
    '  truncated-object)'#10 +
    '    printf ''%s'' ''{"tag_name":"v1.2.3"'' > "$Output"'#10 +
    '    printf ''200'' ;;'#10 +
    '  empty)'#10 +
    '    printf ''%s'' ''{}'' > "$Output"'#10 +
    '    printf ''200'' ;;'#10 +
    'esac'#10);
  {$IFDEF UNIX}
  if FpChmod(PChar(FCurlPath), &755) <> 0 then RaiseLastOSError;
  {$ENDIF}
end;

procedure TLatestTagResolutionTests.AfterAll;
begin
  if not FSkipped then RecursiveDelete(FScratch);
end;

procedure TLatestTagResolutionTests.TestSuccessfulResponseResolves;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveLatestTag(
    FScratch + '/response-success.json',
    ['PATH=' + FBinDir + ':' + GetEnvironmentVariable('PATH'),
     'INSTALL_RESOLVE_MODE=success',
     'GITHUB_TOKEN=test-token',
     'EXPECTED_AUTHORIZATION=Authorization: Bearer test-token']);
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoResolved));
  Expect<string>(Resolution.ResponseBody).ToBe('{"tag_name":"v1.2.3"}');
  Expect<string>(Resolution.Tag).ToBe('v1.2.3');
  Expect<string>(Resolution.Stderr).ToBe('');
end;

procedure TLatestTagResolutionTests.TestExplicitNotFoundSkips;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('not-found');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoNoRelease));
  Resolution := ResolveMode('not-found-curl-error');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('curl exited 23',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('Not Found',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('Failure writing output',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
end;

procedure TLatestTagResolutionTests.TestConnectivityFailureSkips;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('connectivity');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(
    Ord(ltoTransientFailure));
  Expect<Boolean>(Pos('Could not resolve host', Resolution.Stderr) > 0).ToBe(
    True);
  Resolution := ResolveLatestTag(
    FScratch + '/response-missing-curl.json',
    ['PATH=' + FScratch + '/missing']);
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(
    Ord(ltoTransientFailure));
  Expect<Boolean>(Pos('curl is required', Resolution.Stderr) > 0).ToBe(True);
end;

procedure TLatestTagResolutionTests.TestRateLimitFailuresSkipDistinctly;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('primary-rate-limit');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(
    Ord(ltoRateLimited));
  Expect<Boolean>(Pos('API rate limit exceeded',
    Resolution.ResponseBody) > 0).ToBe(True);
  Expect<string>(Resolution.Stderr).ToBe('');
  Resolution := ResolveMode('secondary-rate-limit');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(
    Ord(ltoRateLimited));
  Resolution := ResolveMode('rate-limit-curl-error');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('curl exited 23',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('API rate limit exceeded',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('Failure writing output',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
end;

procedure TLatestTagResolutionTests.TestHTTPFailuresFail;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('forbidden');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('Resource not accessible',
    Resolution.ResponseBody) > 0).ToBe(True);
  Expect<string>(Resolution.Stderr).ToBe('');
  Expect<Boolean>(Pos('HTTP 403',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('Resource not accessible',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Resolution := ResolveMode('unauthorized');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('Bad credentials',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Resolution := ResolveMode('unprocessable');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('Validation Failed',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Resolution := ResolveMode('server-error');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('HTTP 500',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('server error',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
end;

procedure TLatestTagResolutionTests.TestUnclassifiedCurlFailureFails;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('curl-error');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('Failure writing output',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
end;

procedure TLatestTagResolutionTests.TestInvalidSuccessfulResponseFails;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('malformed');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('valid tag_name',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Resolution := ResolveMode('empty');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Resolution := ResolveMode('truncated-object');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
end;

procedure TLatestTagResolutionTests.SetupTests;
begin
  Test('HTTP 200 with a valid tag resolves',
    TestSuccessfulResponseResolves);
  Test('explicit latest-release 404 is no release',
    TestExplicitNotFoundSkips);
  Test('narrow connectivity failure is transient',
    TestConnectivityFailureSkips);
  Test('GitHub API rate limits are a distinct skip',
    TestRateLimitFailuresSkipDistinctly);
  Test('non-rate-limit HTTP errors fail with API details',
    TestHTTPFailuresFail);
  Test('unclassified curl failure fails with stderr',
    TestUnclassifiedCurlFailureFails);
  Test('empty or malformed HTTP 200 fails resolution',
    TestInvalidSuccessfulResponseFails);
end;

function TInstallScriptVerificationTests.RunMode(const AMode: string;
  out AStderr: string): Integer;
var InstallOut: string;
begin
  Result := RunSh(
    [FInstallPath],
    FScratch,
    ['PATH=' + FBinDir + ':/usr/bin:/bin',
     'LWPT_VERSION=v1.2.3',
     'INSTALL_DIR=' + FScratch + '/install',
     'INSTALL_CHECKSUM_MODE=' + AMode],
    InstallOut,
    AStderr);
end;

procedure TInstallScriptVerificationTests.BeforeAll;
var CurlPath: string;
begin
  FSkipped := False;
  {$IFNDEF UNIX}
  FSkipped := True;
  WriteLn('  [skip] install.sh checksum fixtures require /bin/sh; '
        + 'skipped on non-Unix');
  Exit;
  {$ENDIF}

  FScratch := CreateScratchRoot('install-script-verification');
  FBinDir := FScratch + '/bin';
  FInstallPath := GetCurrentDir + '/scripts/install.sh';
  ForceDirectories(FBinDir);
  CurlPath := FBinDir + '/curl';
  WriteTextFile(CurlPath,
    '#!/bin/sh'#10 +
    'Output=""'#10 +
    'URL=""'#10 +
    'while [ "$#" -gt 0 ]; do'#10 +
    '  case "$1" in'#10 +
    '    -o) Output="$2"; shift 2 ;;'#10 +
    '    -*) shift ;;'#10 +
    '    *) URL="$1"; shift ;;'#10 +
    '  esac'#10 +
    'done'#10 +
    { A stalled transfer: report this curl and its child, then block. }
    'if [ "$INSTALL_CHECKSUM_MODE" = stalled ]; then'#10 +
    '  sleep 300 &'#10 +
    '  printf ''stalled-pid %s\nstalled-pid %s\n'' "$$" "$!" >&2'#10 +
    '  wait'#10 +
    '  exit 1'#10 +
    'fi'#10 +
    'case "$URL" in'#10 +
    '  *-checksums.txt)'#10 +
    '    case "$INSTALL_CHECKSUM_MODE" in'#10 +
    '      missing-file)'#10 +
    '        printf ''curl: (22) The requested URL returned error: 404\n'' >&2'#10 +
    '        exit 22 ;;'#10 +
    '      missing-entry)'#10 +
    '        printf ''deadbeef  another-asset.tar.gz\n'' > "$Output" ;;'#10 +
    '    esac ;;'#10 +
    '  *) printf ''not-an-archive'' > "$Output" ;;'#10 +
    'esac'#10);
  {$IFDEF UNIX}
  if FpChmod(PChar(CurlPath), &755) <> 0 then RaiseLastOSError;
  {$ENDIF}
end;

procedure TInstallScriptVerificationTests.AfterAll;
begin
  if not FSkipped then RecursiveDelete(FScratch);
end;

procedure TInstallScriptVerificationTests.TestMissingChecksumsFileFails;
var InstallStderr: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Expect<Boolean>(RunMode('missing-file', InstallStderr) <> 0).ToBe(True);
  Expect<Boolean>(Pos('could not download checksums file',
    InstallStderr) > 0).ToBe(True);
end;

procedure TInstallScriptVerificationTests.TestMissingChecksumEntryFails;
var InstallStderr: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Expect<Boolean>(RunMode('missing-entry', InstallStderr) <> 0).ToBe(True);
  Expect<Boolean>(Pos('checksums file has no entry',
    InstallStderr) > 0).ToBe(True);
end;

{ Linux reports an exited but unreaped process as state Z; it no longer
  runs. Elsewhere kill(pid, 0) is the probe. }
function ProcessIsLive(const APid: LongInt): Boolean;
{$IFDEF LINUX}
var
  Stat: string;
  StatFile: TextFile;
{$ENDIF}
begin
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  { procfs reports a zero size, so read it as text rather than by length. }
  Stat := '';
  AssignFile(StatFile, '/proc/' + IntToStr(APid) + '/stat');
  {$I-}
  Reset(StatFile);
  {$I+}
  if IOResult <> 0 then Exit(False);
  {$I-}
  ReadLn(StatFile, Stat);
  {$I+}
  { A process that exits mid-read leaves an empty or failed read. }
  if IOResult <> 0 then Stat := '';
  CloseFile(StatFile);
  { pid (comm) S ...: the state follows the last closing parenthesis. }
  Stat := Copy(Stat, LastDelimiter(')', Stat) + 2, 1);
  Result := (Stat <> '') and (Stat <> 'Z') and (Stat <> 'X');
  {$ELSE}
  Result := FpKill(APid, 0) = 0;
  {$ENDIF}
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{ install.sh prints "Downloading" and then waits on curl, which forwards
  nothing: a stalled transfer must not hold the test past its deadline,
  and neither the shell nor the curl it started may survive it. }
procedure TInstallScriptVerificationTests.TestStalledDownloadIsTerminatedWithItsDescendants;
const
  DEADLINE_MILLISECONDS = 1500;
var
  InstallOut, InstallStderr, Failure, Line: string;
  Lines: TStringList;
  StartedAt, Elapsed: QWord;
  Pids: array of LongInt;
  Pid: LongInt;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Failure := '';
  StartedAt := GetTickCount64;
  try
    RunSh([FInstallPath], FScratch,
      ['PATH=' + FBinDir + ':/usr/bin:/bin', 'LWPT_VERSION=v1.2.3',
       'INSTALL_DIR=' + FScratch + '/install',
       'INSTALL_CHECKSUM_MODE=stalled'],
      InstallOut, InstallStderr, DEADLINE_MILLISECONDS);
  except
    on E: Exception do Failure := E.Message;
  end;
  Elapsed := GetTickCount64 - StartedAt;
  Expect<Boolean>(Pos('exceeded its ' + IntToStr(DEADLINE_MILLISECONDS)
    + ' ms deadline and was terminated with its process group', Failure) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('Downloading', Failure) > 0).ToBe(True);
  Expect<Boolean>(Elapsed < DEADLINE_MILLISECONDS
    + CHILD_TERMINATION_GRACE_MILLISECONDS + CHILD_KILL_MILLISECONDS + 3000)
    .ToBe(True);
  Pids := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(Failure, '; ', LineEnding, [rfReplaceAll]);
    for Line in Lines do
      if Pos('stalled-pid ', Line) > 0 then
      begin
        SetLength(Pids, Length(Pids) + 1);
        Pids[High(Pids)] := StrToInt(Trim(Copy(Line,
          Pos('stalled-pid ', Line) + 12, MaxInt)));
      end;
  finally
    Lines.Free;
  end;
  { The fake curl and the sleep it started. }
  Expect<Boolean>(Length(Pids) >= 2).ToBe(True);
  for Pid in Pids do Expect<Boolean>(ProcessIsLive(Pid)).ToBe(False);
end;

procedure TInstallScriptVerificationTests.SetupTests;
begin
  Test('missing checksums file fails closed',
    TestMissingChecksumsFileFails);
  Test('missing asset entry fails closed',
    TestMissingChecksumEntryFails);
  Test('a stalled download is terminated with its descendants',
    TestStalledDownloadIsTerminatedWithItsDescendants);
end;

procedure TInstallScriptE2E.BeforeAll;
var
  InstallOut: string;
  Resolution: TLatestTagResolution;
begin
  FOrigDir  := GetCurrentDir;
  FRepoRoot := GetCurrentDir;   { lwpt test sets CWD to the project root }
  FScratch  := CreateScratchRoot('install-script-e2e');
  FBinDir   := FScratch + '/bin';

  FSkipped := SkipNetworkTests;
  FInstallExitCode := -1;
  FInstallStderr := '';
  FResolveFailure := '';
  {$IFNDEF UNIX}
  FSkipped := True;
  {$ENDIF}

  if FSkipped then
  begin
    {$IFNDEF UNIX}
    WriteLn('  [skip] install.sh is Unix-only; Windows install.ps1 smoke is separate');
    {$ELSE}
    WriteLn('  [skip] LWPT_ENABLE_NETWORK=1 not set; install-script test skipped');
    {$ENDIF}
    Exit;
  end;

  { Resolve "latest" — the single source of truth. Only an explicit 404,
    a documented GitHub rate-limit response, or a narrowly classified
    connectivity failure skips. }
  Resolution := ResolveLatestTag(FScratch + '/latest-release.json', []);
  case LatestTagOutcome(Resolution) of
    ltoNoRelease:
      begin
        WriteLn('  [skip] no normal (non-prerelease) release published yet; '
              + 'release.yml''s per-release install check covers prereleases');
        FSkipped := True;
        Exit;
      end;
    ltoTransientFailure:
      begin
        WriteLn('  [skip] github.com unreachable or curl missing (transient/env); '
              + 'install-script test skipped');
        FSkipped := True;
        Exit;
      end;
    ltoRateLimited:
      begin
        WriteLn('  [skip] GitHub latest-release API rate limit reached; '
              + 'install-script test skipped');
        FSkipped := True;
        Exit;
      end;
    ltoFailure:
      begin
        FResolveFailure := LatestTagFailureMessage(Resolution);
        Exit;
      end;
    ltoResolved:
      FResolvedTag := Resolution.Tag;
  end;

  if FResolvedTag = '' then
  begin
    FResolveFailure := 'latest-release resolution produced no tag';
    Exit;
  end;

  RecursiveDelete(FScratch);
  ForceDirectories(FBinDir);

  { Pass the resolved tag explicitly so install.sh installs exactly what
    we resolved (no re-resolution race) and we know the expected version. }
  FInstallExitCode := RunSh(
    [FRepoRoot + '/scripts/install.sh'],
    FRepoRoot,
    ['LWPT_VERSION=' + FResolvedTag, 'INSTALL_DIR=' + FBinDir],
    InstallOut,
    FInstallStderr);

  if (FInstallExitCode <> 0) and InstallFailureIsSkippable(FInstallStderr) then
  begin
    WriteLn('  [skip] github.com unreachable (transient); install-script test skipped');
    FSkipped := True;
  end;
end;

procedure TInstallScriptE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallScriptE2E.TestLatestReleaseResolved;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  if FResolveFailure <> '' then
    WriteLn('--- latest-release resolution failure ---'#10,
      FResolveFailure, #10'---');
  Expect<string>(FResolveFailure).ToBe('');
end;

procedure TInstallScriptE2E.TestInstallScriptExitsZero;
begin
  if FSkipped or (FResolveFailure <> '') then
    begin Expect<Boolean>(True).ToBe(True); Exit; end;
  if FInstallExitCode <> 0 then
    WriteLn('--- install.sh stderr ---'#10, FInstallStderr, #10'---');
  Expect<Integer>(FInstallExitCode).ToBe(0);
end;

procedure TInstallScriptE2E.TestBinaryInstalledAndExecutable;
var BinPath: string;
begin
  if FSkipped or (FResolveFailure <> '') then
    begin Expect<Boolean>(True).ToBe(True); Exit; end;
  BinPath := FBinDir + '/lwpt';
  Expect<Boolean>(FileExists(BinPath)).ToBe(True);
  Expect<Boolean>(FileIsExecutable(BinPath)).ToBe(True);
end;

procedure TInstallScriptE2E.TestInstalledBinaryReportsVersion;
var R: TLwptResult;
begin
  if FSkipped or (FResolveFailure <> '') then
    begin Expect<Boolean>(True).ToBe(True); Exit; end;
  { Point RunLwpt at the freshly-installed binary + ask its version.
    Expected is DERIVED from the resolved tag (binary == tag, per the
    stamp-from-tag policy in ADR-0026) — one source of truth, no second
    constant to drift. Proves the binary is the right architecture, not
    corrupt, and runnable. }
  SetLwptBinaryPath(FBinDir + '/lwpt');
  R := RunLwpt(['--version']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(Trim(R.Stdout)).ToBe('lwpt ' + StripLeadingV(FResolvedTag));
end;

procedure TInstallScriptE2E.SetupTests;
begin
  Test('latest published release resolves without hidden failure',
    TestLatestReleaseResolved);
  Test('install.sh exits zero installing the latest published release',
    TestInstallScriptExitsZero);
  Test('binary lands in INSTALL_DIR and is executable',
    TestBinaryInstalledAndExecutable);
  Test('installed binary reports the resolved tag as its version',
    TestInstalledBinaryReportsVersion);
end;

begin
  {$IFDEF UNIX}
  ShellGroupBinder := TShellGroupBinder.Create;
  {$ENDIF}
  TestRunnerProgram.AddSuite(TLatestTagResolutionTests.Create(
    'latest-release resolution classification (E2E)'));
  TestRunnerProgram.AddSuite(TInstallScriptVerificationTests.Create(
    'install.sh: checksum verification (E2E)'));
  TestRunnerProgram.AddSuite(TInstallScriptE2E.Create(
    'install.sh: latest-release smoke (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
