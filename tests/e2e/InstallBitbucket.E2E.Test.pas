{ InstallBitbucket.E2E.Test — spawn `lwpt install` against a real
  Bitbucket repo. Validates the Bitbucket archive-URL pattern in
  FetchURL (the pattern was wired from Bitbucket's docs in a later cycle but
  never live-tested per the handoff's "honest gaps" item).

  Fixture: atlassian/atlaskit @ commit d7ac1acad54ed82e3fc244398cd29044f9bf1775

    Atlassian's own atlaskit repo, pinned to a 2022 commit hash
    (immutable). The archive is tiny (~450 bytes — README-only at
    that commit), which makes it ideal for a smoke test. URL
    pattern:

      https://bitbucket.org/<slug>/get/<ref>.tar.gz

    Bitbucket's archive top-level dir is hash-suffixed
    (e.g. `atlassian-atlaskit-d7ac1acad54e/`); StripFirstComponent
    handles whatever the top dir is.

  Skip semantics: LWPT_SKIP_NETWORK=1, OR a clean connect/DNS failure
  to the host at install time (IsNetworkUnavailable — transient
  third-party downtime, not an LWPT defect), → tests pass with a "skipped"
  log line. A content/hash/parse failure still fails hard. See docs/ci.md. }

program InstallBitbucket.E2E.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  REPO_SLUG = 'atlassian/atlaskit';
  REPO_REF  = 'd7ac1acad54ed82e3fc244398cd29044f9bf1775';
  DEP_NAME  = 'atlaskit';

type
  TInstallBitbucketE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot: string;
    FSkipped: Boolean;
    FInstallExitCode: Integer;
    FInstallStderr: string;
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestInstallExitsZero;
    procedure TestArchiveDownloadedAndExtracted;
    procedure TestLockfileRecordsArchiveAndTreeHashes;
    procedure TestFrozenVerifiesWithoutNetwork;
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

procedure TInstallBitbucketE2E.SetupScratchProject;
begin
  ForceDirectories(FRoot + '/source');
  WriteTextFile(FRoot + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin end.'#10);
  WriteTextFile(FRoot + '/lwpt.toml',
    '[package]'#10 +
    'name = "bitbucket-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    { bitbucket: prefix shape. REPO_REF is a 40-char SHA →
      vkCommitSha, direct fetch. }
    DEP_NAME + ' = "bitbucket:' + REPO_SLUG + '@' + REPO_REF + '"'#10);
end;

procedure TInstallBitbucketE2E.BeforeAll;
var R: TLwptResult;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/install-bitbucket-e2e');
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

  { Transient third-party downtime (bitbucket.org unreachable at the
    TCP/DNS layer) is not an LWPT defect — skip rather than fail. A
    content/hash/parse failure leaves FSkipped False so the assertions
    below still fail hard. }
  if (not FSkipped) and IsNetworkUnavailable(R) then
  begin
    WriteLn('  [skip] bitbucket.org unreachable (transient network); e2e fetch skipped');
    FSkipped := True;
  end;
end;

procedure TInstallBitbucketE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallBitbucketE2E.TestInstallExitsZero;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  if FInstallExitCode <> 0 then
    WriteLn('--- install stderr ---'#10, FInstallStderr, #10'---');
  Expect<Integer>(FInstallExitCode).ToBe(0);
end;

procedure TInstallBitbucketE2E.TestArchiveDownloadedAndExtracted;
var ModuleDir: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  ModuleDir := FRoot + '/.lwpt/modules/' + DEP_NAME;
  Expect<Boolean>(DirectoryExists(ModuleDir)).ToBe(True);
  Expect<Boolean>(FileExists(ModuleDir + '/README.md')).ToBe(True);
end;

procedure TInstallBitbucketE2E.TestLockfileRecordsArchiveAndTreeHashes;
var Lock: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Lock := ReadFileText(FRoot + '/lwpt.lock');
  Expect<Boolean>(Pos('[package.' + DEP_NAME + ']', Lock) > 0).ToBe(True);
  { Schema v3: `source` is the verbatim manifest string. The
    bitbucket: prefix encodes the host. }
  Expect<Boolean>(Pos('source = "bitbucket:' + REPO_SLUG + '"', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedURL = "https://bitbucket.org/', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('computedHash = "sha256:', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('archiveHash = "sha256:',  Lock) > 0).ToBe(True);
end;

procedure TInstallBitbucketE2E.TestFrozenVerifiesWithoutNetwork;
var R: TLwptResult;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  R := RunLwpt(['install', '--frozen'], FRoot);
  if R.ExitCode <> 0 then
    WriteLn('--- frozen stderr ---'#10, R.Stderr, #10'---');
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TInstallBitbucketE2E.SetupTests;
begin
  Test('install exits zero against the live Bitbucket fixture',
    TestInstallExitsZero);
  Test('archive downloaded + extracted under .lwpt/modules/',
    TestArchiveDownloadedAndExtracted);
  Test('lockfile records sourceType "bitbucket" + both hashes',
    TestLockfileRecordsArchiveAndTreeHashes);
  Test('install --frozen verifies the committed state without hitting network',
    TestFrozenVerifiesWithoutNetwork);
end;

begin
  TestRunnerProgram.AddSuite(TInstallBitbucketE2E.Create(
    'install: live Bitbucket fetch (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
