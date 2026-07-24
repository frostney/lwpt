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
  matcher also skip. Other curl failures, HTTP errors, and malformed
  successful responses fail.

  Unix-only: install.sh is /bin/sh. The Windows install.ps1 smoke test
  is a separate future addition.

  Skip semantics (each logs a "[skip]" line and passes):
    - non-Unix host                  → skip (install.sh is sh)
    - LWPT_SKIP_NETWORK=1             → skip
    - curl unavailable               → skip (environment, not a defect)
    - no normal release published    → skip (nothing to smoke yet)
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
    ltoFailure
  );

  TLatestTagResolution = record
    CurlExitCode: Integer;
    HTTPStatus: string;
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
    procedure TestHTTPFailuresFail;
    procedure TestUnclassifiedCurlFailureFails;
    procedure TestInvalidSuccessfulResponseFails;
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

{ Drain a stream into a string. Assumes the child has exited. }
function DrainStream(AStream: TStream): string;
const CHUNK = 4 * 1024;
var Buf: array of Byte; N, Total: Integer;
begin
  Result := '';
  SetLength(Buf, CHUNK);
  Total := 0;
  while True do
  begin
    N := AStream.Read(Buf[0], CHUNK);
    if N <= 0 then Break;
    SetLength(Result, Total + N);
    Move(Buf[0], Result[Total + 1], N);
    Inc(Total, N);
  end;
end;

{ Run a /bin/sh program (script file or `-c` command), capturing exit
  code + stderr + stdout. Self-contained (does not go through RunLwpt,
  which targets the lwpt binary). AArgs are the args after /bin/sh. }
function RunSh(const AArgs: array of string; const AInDir: string;
  const AExtraEnv: array of string; out AStdout, AStderr: string): Integer;
var
  P: TProcess;
  i: Integer;
  Outp, Errp: string;
begin
  Result := -1;
  Outp := '';
  Errp := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    for i := Low(AArgs) to High(AArgs) do P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes];
    if AInDir <> '' then P.CurrentDirectory := AInDir;

    ConfigureProcessEnvironment(P, AExtraEnv);

    P.Execute;
    while P.Running do
    begin
      if P.Output.NumBytesAvailable > 0 then Outp := Outp + DrainStream(P.Output);
      if P.Stderr.NumBytesAvailable > 0 then Errp := Errp + DrainStream(P.Stderr);
      Sleep(10);
    end;
    if P.Output.NumBytesAvailable > 0 then Outp := Outp + DrainStream(P.Output);
    if P.Stderr.NumBytesAvailable > 0 then Errp := Errp + DrainStream(P.Stderr);
    Result := P.ExitCode;
  finally
    P.Free;
  end;
  AStdout := Outp;
  AStderr := Errp;
end;

{ Extract tag_name from the GitHub API's JSON response. The release tags
  LWPT publishes are plain SemVer strings, so an escaped or incomplete
  JSON string is invalid rather than something to guess through. }
function ExtractLatestTag(const AResponse: string): string;
const
  TAG_PROPERTY = '"tag_name"';
var
  PropertyPosition, ValuePosition, ValueStart: Integer;
begin
  Result := '';
  PropertyPosition := Pos(TAG_PROPERTY, AResponse);
  if PropertyPosition = 0 then Exit;
  ValuePosition := PropertyPosition + Length(TAG_PROPERTY);
  while (ValuePosition <= Length(AResponse))
    and (AResponse[ValuePosition] in [' ', #9, #10, #13]) do
    Inc(ValuePosition);
  if (ValuePosition > Length(AResponse))
    or (AResponse[ValuePosition] <> ':') then Exit;
  Inc(ValuePosition);
  while (ValuePosition <= Length(AResponse))
    and (AResponse[ValuePosition] in [' ', #9, #10, #13]) do
    Inc(ValuePosition);
  if (ValuePosition > Length(AResponse))
    or (AResponse[ValuePosition] <> '"') then Exit;
  Inc(ValuePosition);
  ValueStart := ValuePosition;
  while (ValuePosition <= Length(AResponse))
    and (AResponse[ValuePosition] <> '"') do
  begin
    if AResponse[ValuePosition] = '\' then Exit;
    Inc(ValuePosition);
  end;
  if (ValuePosition > Length(AResponse))
    or (ValuePosition = ValueStart) then Exit;
  Result := Copy(AResponse, ValueStart, ValuePosition - ValueStart);
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

{ Resolve the newest non-prerelease-flagged release tag while keeping
  curl's transport exit, HTTP status, response body, and stderr distinct.
  Positional shell parameters keep the scratch path and repository URL
  out of shell syntax. }
function ResolveLatestTag(const AResponsePath: string;
  const AExtraEnv: array of string): TLatestTagResolution;
var
  Cmd, HTTPOutput, Response: string;
begin
  Result.CurlExitCode := -1;
  Result.HTTPStatus := '';
  Result.Tag := '';
  Result.Stderr := '';

  Cmd := 'command -v curl >/dev/null 2>&1 '
       + '|| { printf ''curl is required\n'' >&2; exit 127; }; '
       + 'curl -fsSL -o "$1" -w ''%{http_code}'' "$2"';
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
    Response := ReadBinaryFile(AResponsePath);
    Result.Tag := ExtractLatestTag(Response);
  end;
end;

function LatestTagOutcome(
  const AResolution: TLatestTagResolution): TLatestTagOutcome;
begin
  if AResolution.HTTPStatus = '404' then Exit(ltoNoRelease);
  if AResolution.CurlExitCode <> 0 then
  begin
    if InstallFailureIsSkippable(AResolution.Stderr) then
      Exit(ltoTransientFailure);
    Exit(ltoFailure);
  end;
  if AResolution.HTTPStatus <> '200' then Exit(ltoFailure);
  if AResolution.Tag = '' then Exit(ltoFailure);
  Result := ltoResolved;
end;

function LatestTagFailureMessage(
  const AResolution: TLatestTagResolution): string;
begin
  if (AResolution.HTTPStatus <> '')
    and (AResolution.HTTPStatus <> '000')
    and (AResolution.HTTPStatus <> '200') then
    Result := 'latest-release API returned HTTP ' + AResolution.HTTPStatus
  else if AResolution.CurlExitCode <> 0 then
    Result := Format('curl exited %d while resolving the latest release',
      [AResolution.CurlExitCode])
  else if (AResolution.HTTPStatus = '')
    or (AResolution.HTTPStatus = '000') then
    Result := 'curl did not report an HTTP status for the latest release'
  else
    Result := 'latest-release API returned HTTP 200 without a valid tag_name';
  if Trim(AResolution.Stderr) <> '' then
    Result := Result + LineEnding + Trim(AResolution.Stderr);
end;

function TLatestTagResolutionTests.ResolveMode(
  const AMode: string): TLatestTagResolution;
begin
  Result := ResolveLatestTag(
    FScratch + '/response-' + AMode + '.json',
    ['PATH=' + FBinDir + ':' + GetEnvironmentVariable('PATH'),
     'INSTALL_RESOLVE_MODE=' + AMode]);
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
    'while [ "$#" -gt 0 ]; do'#10 +
    '  case "$1" in'#10 +
    '    -o) Output="$2"; shift 2 ;;'#10 +
    '    -w) shift 2 ;;'#10 +
    '    *) shift ;;'#10 +
    '  esac'#10 +
    'done'#10 +
    ': > "$Output"'#10 +
    'case "${INSTALL_RESOLVE_MODE:-success}" in'#10 +
    '  success)'#10 +
    '    printf ''%s'' ''{"tag_name":"v1.2.3"}'' > "$Output"'#10 +
    '    printf ''200'' ;;'#10 +
    '  not-found)'#10 +
    '    printf ''%s'' ''{"message":"Not Found"}'' > "$Output"'#10 +
    '    printf ''404'''#10 +
    '    printf ''curl: (22) The requested URL returned error: 404\n'' >&2'#10 +
    '    exit 22 ;;'#10 +
    '  forbidden)'#10 +
    '    printf ''%s'' ''{"message":"rate limit"}'' > "$Output"'#10 +
    '    printf ''403'''#10 +
    '    printf ''curl: (22) The requested URL returned error: 403\n'' >&2'#10 +
    '    exit 22 ;;'#10 +
    '  server-error)'#10 +
    '    printf ''%s'' ''{"message":"server error"}'' > "$Output"'#10 +
    '    printf ''500'''#10 +
    '    printf ''curl: (22) The requested URL returned error: 500\n'' >&2'#10 +
    '    exit 22 ;;'#10 +
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
  Resolution := ResolveMode('success');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoResolved));
  Expect<string>(Resolution.Tag).ToBe('v1.2.3');
end;

procedure TLatestTagResolutionTests.TestExplicitNotFoundSkips;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('not-found');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoNoRelease));
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

procedure TLatestTagResolutionTests.TestHTTPFailuresFail;
var Resolution: TLatestTagResolution;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Resolution := ResolveMode('forbidden');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('HTTP 403',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Expect<Boolean>(Pos('returned error: 403',
    LatestTagFailureMessage(Resolution)) > 0).ToBe(True);
  Resolution := ResolveMode('server-error');
  Expect<Integer>(Ord(LatestTagOutcome(Resolution))).ToBe(Ord(ltoFailure));
  Expect<Boolean>(Pos('HTTP 500',
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
end;

procedure TLatestTagResolutionTests.SetupTests;
begin
  Test('HTTP 200 with a valid tag resolves',
    TestSuccessfulResponseResolves);
  Test('explicit latest-release 404 is no release',
    TestExplicitNotFoundSkips);
  Test('narrow connectivity failure is transient',
    TestConnectivityFailureSkips);
  Test('HTTP 403 and 500 fail resolution',
    TestHTTPFailuresFail);
  Test('unclassified curl failure fails with stderr',
    TestUnclassifiedCurlFailureFails);
  Test('empty or malformed HTTP 200 fails resolution',
    TestInvalidSuccessfulResponseFails);
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
    WriteLn('  [skip] LWPT_SKIP_NETWORK=1 set; install-script test skipped');
    {$ENDIF}
    Exit;
  end;

  { Resolve "latest" — the single source of truth. Only an explicit 404
    or a narrowly classified connectivity failure skips. }
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
  TestRunnerProgram.AddSuite(TLatestTagResolutionTests.Create(
    'latest-release resolution classification (E2E)'));
  TestRunnerProgram.AddSuite(TInstallScriptE2E.Create(
    'install.sh: latest-release smoke (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
