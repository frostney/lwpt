{ InstallGitLab.E2E.Test — spawn `lwpt install` against a real GitLab
  repo. Validates the GitLab archive-URL pattern in FetchURL (the
  pattern was wired from GitLab's docs in a later cycle but never live-tested
  per the handoff's "honest gaps" item).

  Fixture: gitlab-examples/ci-debug-trace @ commit
  dd648b2e48ce6518303b0bb580b2ee32fadaf045

    GitLab's CI debug-trace example project. Tiny (< 1 KB archive),
    public, and pinned to an immutable commit SHA so the archive's
    contents stay stable. URL pattern:

      https://gitlab.com/<slug>/-/archive/<ref>/<repo>-<ref>.tar.gz

    (Note the repo basename in the filename — that's what
    RepoBasename in LWPT.Core constructs.)

  Skip semantics: LWPT_SKIP_NETWORK=1, OR a clean connect/DNS failure
  to the host at install time (IsNetworkUnavailable — transient
  third-party downtime, not an LWPT defect), → tests pass with a "skipped"
  log line. }

program InstallGitLab.E2E.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess;

const
  REPO_SLUG = 'gitlab-examples/ci-debug-trace';
  REPO_REF  = 'dd648b2e48ce6518303b0bb580b2ee32fadaf045';
  DEP_NAME  = 'ci-debug-trace';

type
  TInstallGitLabE2E = class(TTestSuite)
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
    procedure TestLockfileRecordsArchiveAndTreeHashes;
    procedure TestFrozenVerifiesWithoutNetwork;
  end;

procedure TInstallGitLabE2E.WriteFile(const APath, AContent: string);
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

procedure TInstallGitLabE2E.SetupScratchProject;
begin
  ForceDirectories(FRoot + '/source');
  WriteFile(FRoot + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin end.'#10);
  WriteFile(FRoot + '/lwpt.toml',
    '[package]'#10 +
    'name = "gitlab-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    { gitlab: prefix shape. REPO_REF is a full commit SHA, so the
      resolver treats it as a direct immutable ref. }
    DEP_NAME + ' = "gitlab:' + REPO_SLUG + '@' + REPO_REF + '"'#10);
end;

procedure TInstallGitLabE2E.BeforeAll;
var R: TLwptResult;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/install-gitlab-e2e');
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

  { Transient third-party downtime (gitlab.com unreachable at the
    TCP/DNS layer) is not an LWPT defect — skip rather than fail. A
    content/hash/parse failure leaves FSkipped False so the assertions
    below still fail hard. }
  if (not FSkipped) and IsNetworkUnavailable(R) then
  begin
    WriteLn('  [skip] gitlab.com unreachable (transient network); e2e fetch skipped');
    FSkipped := True;
  end;
end;

procedure TInstallGitLabE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallGitLabE2E.TestInstallExitsZero;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  if FInstallExitCode <> 0 then
    WriteLn('--- install stderr ---'#10, FInstallStderr, #10'---');
  Expect<Integer>(FInstallExitCode).ToBe(0);
end;

procedure TInstallGitLabE2E.TestArchiveDownloadedAndExtracted;
var ModuleDir: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  ModuleDir := FRoot + '/.lwpt/modules/' + DEP_NAME;
  Expect<Boolean>(DirectoryExists(ModuleDir)).ToBe(True);
  { ci-debug-trace ships a README.md + .gitlab-ci.yml in its archive root;
    we don't pin to specific filenames (GitLab may evolve), just
    assert SOMETHING extracted under the modules dir. }
  Expect<Boolean>(FileExists(ModuleDir + '/README.md')
               or FileExists(ModuleDir + '/.gitlab-ci.yml')).ToBe(True);
end;

procedure TInstallGitLabE2E.TestLockfileRecordsArchiveAndTreeHashes;
var Lock: string;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  Lock := ReadFileText(FRoot + '/lwpt.lock');
  Expect<Boolean>(Pos('[package.' + DEP_NAME + ']', Lock) > 0).ToBe(True);
  { Schema v3: the `source` field is the verbatim manifest
    string ("gitlab:gitlab-examples/ci-debug-trace") — the gitlab: prefix
    encodes the host. No more lossy `sourceType = "github"` for all
    three hosts. The host is also recoverable from the resolvedURL. }
  Expect<Boolean>(Pos('source = "gitlab:' + REPO_SLUG + '"', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('resolvedURL = "https://gitlab.com/', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('computedHash = "sha256:', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('archiveHash = "sha256:',  Lock) > 0).ToBe(True);
end;

procedure TInstallGitLabE2E.TestFrozenVerifiesWithoutNetwork;
var R: TLwptResult;
begin
  if FSkipped then begin Expect<Boolean>(True).ToBe(True); Exit; end;
  R := RunLwpt(['install', '--frozen'], FRoot);
  if R.ExitCode <> 0 then
    WriteLn('--- frozen stderr ---'#10, R.Stderr, #10'---');
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TInstallGitLabE2E.SetupTests;
begin
  Test('install exits zero against the live GitLab fixture',
    TestInstallExitsZero);
  Test('archive downloaded + extracted under .lwpt/modules/',
    TestArchiveDownloadedAndExtracted);
  Test('lockfile records sourceType "gitlab" + both hashes',
    TestLockfileRecordsArchiveAndTreeHashes);
  Test('install --frozen verifies the committed state without hitting network',
    TestFrozenVerifiesWithoutNetwork);
end;

begin
  TestRunnerProgram.AddSuite(TInstallGitLabE2E.Create(
    'install: live GitLab fetch (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
