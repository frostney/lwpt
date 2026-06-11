{ InstallGitHub.E2E.Test — spawn `lwpt install` against a real GitHub
  repo and assert the full pipeline (HTTPS GET → gzip → ustar → write
  modules tree → lockfile → --frozen verification).

  Fixture: octocat/Hello-World @ 7fd1a60b01f91b314f59955a4e4d4e80d8edf11d

    Chosen because it is the most stable public git ref in existence
    (the initial commit of the canonical "Hello World" repo GitHub
    uses in its own tutorials; commit hash is immutable; repo has been
    public since 2011 and is referenced by GitHub's own documentation).
    Archive is tiny (~150 bytes) so the test runs fast even on slow
    connections.

  Skip semantics:
    LWPT_SKIP_NETWORK=1 → all tests in this suite count as pass with
    a "skipped" log line, exit code 0. The CI matrix runs the e2e
    tier with LWPT_SKIP_NETWORK=1 on jobs without internet access.

    Additionally, a clean connect/DNS failure to the host at install
    time (IsNetworkUnavailable) flips the suite to skip — transient
    third-party downtime is not an LWPT defect. A content/hash/parse
    failure still fails hard. See docs/ci.md. }

program InstallGitHub.E2E.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  REPO_SLUG = 'octocat/Hello-World';
  REPO_REF  = '7fd1a60b01f91b314f59955a4e4d4e80d8edf11d';
  DEP_NAME  = 'hello-world';

type
  TInstallGithubE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot: string;
    FSkipped: Boolean;
    FInstallExitCode: Integer;
    FInstallStderr: string;
    procedure WriteFile(const APath, AContent: string);
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestInstallExitsZero;
    procedure TestArchiveDownloadedAndExtracted;
    procedure TestArchiveCachedUnderArchivesDir;
    procedure TestLockfileRecordsArchiveAndTreeHashes;
    procedure TestFrozenVerifiesWithoutNetwork;
    procedure TestFrozenDetectsArchiveTamper;
  end;

procedure TInstallGithubE2E.WriteFile(const APath, AContent: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

function ReadFileText(const APath: string): string;
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(APath);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TInstallGithubE2E.SetupScratchProject;
begin
  ForceDirectories(FRoot + '/source');
  WriteFile(FRoot + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin end.'#10);
  WriteFile(FRoot + '/lwpt.toml',
    '[package]'#10 +
    'name = "github-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    { bare-string shorthand with the commit SHA as the version
      spec. REPO_SLUG defaults to github; REPO_REF is a 40-char SHA
      → ParseVersionSpec returns vkCommitSha, direct fetch. }
    DEP_NAME + ' = "' + REPO_SLUG + '@' + REPO_REF + '"'#10);
end;

procedure TInstallGithubE2E.BeforeAll;
var R: TLwptResult;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/install-github-e2e');
  FRoot    := FScratch + '/root';
  FSkipped := SkipNetworkTests;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  if FSkipped then
  begin
    WriteLn('  [skip] LWPT_SKIP_NETWORK=1 set; live-network tests skipped');
    Exit;
  end;

  RecursiveDelete(FScratch);
  ForceDirectories(FRoot);
  SetupScratchProject;

  R := RunLwpt(['install'], FRoot);
  FInstallExitCode := R.ExitCode;
  FInstallStderr   := R.Stderr;

  { Transient third-party downtime (github.com unreachable at the
    TCP/DNS layer) is not an LWPT defect — skip rather than fail. A
    content/hash/parse failure leaves FSkipped False so the assertions
    below still fail hard. }
  if (not FSkipped) and IsNetworkUnavailable(R) then
  begin
    WriteLn('  [skip] github.com unreachable (transient network); e2e fetch skipped');
    FSkipped := True;
  end;
end;

procedure TInstallGithubE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallGithubE2E.TestInstallExitsZero;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  if FInstallExitCode <> 0 then
    WriteLn('--- install stderr ---'#10, FInstallStderr, #10'---');
  Expect<Integer>(FInstallExitCode).ToBe(0);
end;

procedure TInstallGithubE2E.TestArchiveDownloadedAndExtracted;
var ModuleDir: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  ModuleDir := FRoot + '/.lwpt/modules/' + DEP_NAME;
  Expect<Boolean>(DirectoryExists(ModuleDir)).ToBe(True);
  { Hello-World's README is the canonical content; assert SOMETHING
    landed under the modules dir (we don't pin to specific files
    because GitHub's archive format may evolve). }
  Expect<Boolean>(FileExists(ModuleDir + '/README')
               or FileExists(ModuleDir + '/README.md')).ToBe(True);
end;

procedure TInstallGithubE2E.TestArchiveCachedUnderArchivesDir;
var ArchivePath: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  ArchivePath := FRoot + '/.lwpt/archives/' + DEP_NAME + '-' + REPO_REF + '.tar.gz';
  Expect<Boolean>(FileExists(ArchivePath)).ToBe(True);
end;

procedure TInstallGithubE2E.TestLockfileRecordsArchiveAndTreeHashes;
var Lock: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Lock := ReadFileText(FRoot + '/lwpt.lock');
  Expect<Boolean>(Pos('[package.' + DEP_NAME + ']', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('computedHash = "sha256:', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('archiveHash = "sha256:',  Lock) > 0).ToBe(True);
end;

procedure TInstallGithubE2E.TestFrozenVerifiesWithoutNetwork;
var R: TLwptResult;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  R := RunLwpt(['install', '--frozen'], FRoot);
  if R.ExitCode <> 0 then
    WriteLn('--- frozen stderr ---'#10, R.Stderr, #10'---');
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TInstallGithubE2E.TestFrozenDetectsArchiveTamper;
var
  ArchivePath: string;
  Stream: TFileStream;
  Tamper: TBytes;
  R: TLwptResult;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  ArchivePath := FRoot + '/.lwpt/archives/' + DEP_NAME + '-' + REPO_REF + '.tar.gz';
  { Append a marker byte to the cached archive. The bytes are no
    longer a valid gzip stream end-to-end, but they ARE different
    from what was downloaded — so the archive hash mismatch fires.
    --frozen must reject this state. }
  Stream := TFileStream.Create(ArchivePath, fmOpenWrite);
  try
    Stream.Position := Stream.Size;
    Tamper := BytesOf(#01#02#03'TAMPER');
    Stream.WriteBuffer(Tamper[0], Length(Tamper));
  finally
    Stream.Free;
  end;

  R := RunLwpt(['install', '--frozen'], FRoot);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(
    (Pos('archive hash mismatch', R.Stderr) > 0)
    or (Pos('archive hash mismatch', R.Stdout) > 0)
  ).ToBe(True);

  { Heal the state for any subsequent tests: re-run install (non-
    frozen) to re-fetch the legitimate archive. }
  RunLwpt(['install'], FRoot);
end;

procedure TInstallGithubE2E.SetupTests;
begin
  Test('install exits zero against the live GitHub fixture',
    TestInstallExitsZero);
  Test('archive downloaded + extracted under .lwpt/modules/',
    TestArchiveDownloadedAndExtracted);
  Test('archive cached under .lwpt/archives/<dep>-<ref>.tar.gz',
    TestArchiveCachedUnderArchivesDir);
  Test('lockfile records both archiveHash and computedHash',
    TestLockfileRecordsArchiveAndTreeHashes);
  Test('install --frozen verifies the committed state without hitting network',
    TestFrozenVerifiesWithoutNetwork);
  Test('install --frozen detects an archive byte-tamper',
    TestFrozenDetectsArchiveTamper);
end;

begin
  TestRunnerProgram.AddSuite(TInstallGithubE2E.Create(
    'install: live GitHub fetch (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
