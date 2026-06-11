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
  binaries stamp the version from the git tag (ADR-0018), that equality
  holds for every stamp-from-tag release; the assertion is *relative*
  (the install path works and the binary self-reports its tag), so it
  never breaks on version drift — only on a genuine install.sh defect.

  Until the first normal (non-prerelease-flagged) release exists,
  /releases/latest yields nothing and the test skips; the per-release
  install check in release.yml covers prerelease-flagged rc.x meanwhile.

  Unix-only: install.sh is /bin/sh. The Windows install.ps1 smoke test
  is a separate future addition.

  Skip semantics (each logs a "[skip]" line and passes):
    - non-Unix host                  → skip (install.sh is sh)
    - LWPT_SKIP_NETWORK=1             → skip
    - curl unavailable               → skip (environment, not a defect)
    - no normal release published    → skip (nothing to smoke yet)
    - clean connect/DNS failure to
      github.com (transient downtime) → skip
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
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TInstallScriptE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FBinDir, FRepoRoot, FResolvedTag: string;
    FSkipped: Boolean;
    FInstallExitCode: Integer;
    FInstallStderr: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
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

    for i := 1 to GetEnvironmentVariableCount do
      P.Environment.Add(GetEnvironmentString(i));
    for i := Low(AExtraEnv) to High(AExtraEnv) do
      P.Environment.Add(AExtraEnv[i]);

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

{ Resolve the newest non-prerelease-flagged release tag, mirroring
  install.sh's pipeline exactly. Returns '' when no such release exists
  (404 from /releases/latest) or the host is unreachable — both skip. }
function ResolveLatestTag(out AStderr: string): string;
var Cmd, Outp: string;
begin
  Cmd := 'curl -fsSL "https://api.github.com/repos/' + ReleasesRepo
       + '/releases/latest" | grep -E ''"tag_name":'' | head -n1 '
       + '| sed -E ''s/.*"([^"]+)".*/\1/''';
  RunSh(['-c', Cmd], '', [], Outp, AStderr);
  Result := Trim(Outp);
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

procedure TInstallScriptE2E.BeforeAll;
var ResolveErr, InstallOut: string;
begin
  FOrigDir  := GetCurrentDir;
  FRepoRoot := GetCurrentDir;   { lwpt test sets CWD to the project root }
  FScratch  := ExpandFileName('build/tests/tmp/install-script-e2e');
  FBinDir   := FScratch + '/bin';

  FSkipped := SkipNetworkTests;
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

  { Resolve "latest" — the single source of truth. Empty means either no
    normal release exists yet or the host is unreachable; both skip. }
  FResolvedTag := ResolveLatestTag(ResolveErr);
  if FResolvedTag = '' then
  begin
    if InstallFailureIsSkippable(ResolveErr) then
      WriteLn('  [skip] github.com unreachable or curl missing (transient/env); '
            + 'install-script test skipped')
    else
      WriteLn('  [skip] no normal (non-prerelease) release published yet; '
            + 'release.yml''s per-release install check covers prereleases');
    FSkipped := True;
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

procedure TInstallScriptE2E.TestInstallScriptExitsZero;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  if FInstallExitCode <> 0 then
    WriteLn('--- install.sh stderr ---'#10, FInstallStderr, #10'---');
  Expect<Integer>(FInstallExitCode).ToBe(0);
end;

procedure TInstallScriptE2E.TestBinaryInstalledAndExecutable;
var BinPath: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  BinPath := FBinDir + '/lwpt';
  Expect<Boolean>(FileExists(BinPath)).ToBe(True);
  Expect<Boolean>(FileIsExecutable(BinPath)).ToBe(True);
end;

procedure TInstallScriptE2E.TestInstalledBinaryReportsVersion;
var R: TLwptResult;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  { Point RunLwpt at the freshly-installed binary + ask its version.
    Expected is DERIVED from the resolved tag (binary == tag, per the
    stamp-from-tag policy in ADR-0018) — one source of truth, no second
    constant to drift. Proves the binary is the right architecture, not
    corrupt, and runnable. }
  SetLwptBinaryPath(FBinDir + '/lwpt');
  R := RunLwpt(['--version']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(Trim(R.Stdout)).ToBe('lwpt ' + StripLeadingV(FResolvedTag));
end;

procedure TInstallScriptE2E.SetupTests;
begin
  Test('install.sh exits zero installing the latest published release',
    TestInstallScriptExitsZero);
  Test('binary lands in INSTALL_DIR and is executable',
    TestBinaryInstalledAndExecutable);
  Test('installed binary reports the resolved tag as its version',
    TestInstalledBinaryReportsVersion);
end;

begin
  TestRunnerProgram.AddSuite(TInstallScriptE2E.Create(
    'install.sh: latest-release smoke (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
