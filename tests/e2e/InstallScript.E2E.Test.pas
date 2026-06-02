{ InstallScript.E2E.Test — exercise scripts/install.sh end-to-end
  against a published GitHub release.

  This is the test that would have caught the macOS .zip regression:
  release.yml shipped macOS archives as .zip while install.sh downloads
  .tar.gz (the `*win*` substring matched `darwin`). PR #8 fixed it, but
  nothing caught it first. This test runs the real install script
  against a real release — the script constructs the asset URL, curls
  it from GitHub Releases, verifies the checksum, extracts the archive,
  and installs the binary — then asserts the installed binary reports
  the expected version. An asset-name mismatch (the .zip bug class)
  surfaces as a 404, which fails hard here.

  Fixture: a fixed published pre-release (INSTALL_VERSION below). The
  pin is an immutable fixture, mirroring how the GitHub/GitLab/Bitbucket
  suites pin commit SHAs. When 0.1.0 final ships, bump INSTALL_VERSION
  to it — a stable release won't be garbage-collected the way a
  pre-release tag can be.

  Unix-only: install.sh is /bin/sh. The Windows install.ps1 smoke test
  is a separate future addition.

  Skip semantics (each logs a "[skip]" line and passes):
    - non-Unix host                  → skip (install.sh is sh)
    - LWPT_SKIP_NETWORK=1             → skip
    - curl unavailable               → skip (environment, not a defect)
    - clean connect/DNS failure to
      github.com (transient downtime) → skip
  A 404 / checksum mismatch / missing binary is NOT a network outage
  and fails hard — that's the regression class this guards. }

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
  Tests.LwptSubprocess;

const
  { The released tag this test installs. Bump to the stable tag when
    0.1.0 ships (pre-releases can be deleted; a stable release is the
    durable fixture). No leading `v` per ADR-0009. }
  INSTALL_VERSION = '0.1.0-rc.2';

  { What the installed binary's `lwpt --version` is expected to print.
    For releases built BEFORE release.yml's stamp-from-tag landed, the
    binary reports the *manifest* version, which diverges from the tag:
    0.1.0-rc.2 was cut while [package].version was "0.1.0", so its
    binary says "lwpt 0.1.0". Once a stamp-from-tag release exists
    (rc.3 / 0.1.0 final), bump INSTALL_VERSION to it AND set this equal
    to it — they converge (binary == tag) from that release onward. }
  EXPECTED_REPORTED_VERSION = '0.1.0';

type
  TInstallScriptE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FBinDir, FRepoRoot: string;
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

procedure RecursiveDelete(const APath: string);
var SR: TSearchRec; Base: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
          RecursiveDelete(Base + SR.Name)
        else
          DeleteFile(Base + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
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

{ Run `sh <script>` with the given env additions, capturing exit code
  + stderr. Self-contained (does not go through RunLwpt, which targets
  the lwpt binary) so this PR touches only this file. }
function RunInstallScript(const AScriptPath, AVersion, AInstallDir,
  AInDir: string; out AStderr: string): Integer;
var
  P: TProcess;
  i: Integer;
  Outp, Errp: string;
begin
  Result := -1;
  AStderr := '';
  Outp := '';
  Errp := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add(AScriptPath);
    P.Options := [poUsePipes];
    if AInDir <> '' then P.CurrentDirectory := AInDir;

    for i := 1 to GetEnvironmentVariableCount do
      P.Environment.Add(GetEnvironmentString(i));
    P.Environment.Add('LWPT_VERSION=' + AVersion);
    P.Environment.Add('INSTALL_DIR=' + AInstallDir);

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
  AStderr := Errp;
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

  RecursiveDelete(FScratch);
  ForceDirectories(FBinDir);

  FInstallExitCode := RunInstallScript(
    FRepoRoot + '/scripts/install.sh',
    INSTALL_VERSION,
    FBinDir,
    FRepoRoot,
    FInstallStderr);

  if (FInstallExitCode <> 0) and InstallFailureIsSkippable(FInstallStderr) then
  begin
    WriteLn('  [skip] github.com unreachable or curl missing (transient/env); '
          + 'install-script test skipped');
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
    Asserts the exact string the pinned release reports — proving the
    installed binary is the right architecture, not corrupt, and
    runnable. See EXPECTED_REPORTED_VERSION on why this can differ from
    the installed tag for pre-stamp-from-tag releases. }
  SetLwptBinaryPath(FBinDir + '/lwpt');
  R := RunLwpt(['--version']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(Trim(R.Stdout)).ToBe('lwpt ' + EXPECTED_REPORTED_VERSION);
end;

procedure TInstallScriptE2E.SetupTests;
begin
  Test('install.sh exits zero installing the published release',
    TestInstallScriptExitsZero);
  Test('binary lands in INSTALL_DIR and is executable',
    TestBinaryInstalledAndExecutable);
  Test('installed binary reports the expected version',
    TestInstalledBinaryReportsVersion);
end;

begin
  TestRunnerProgram.AddSuite(TInstallScriptE2E.Create(
    'install.sh: published-release smoke (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
