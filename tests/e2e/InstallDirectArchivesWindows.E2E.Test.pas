{ InstallDirectArchivesWindows.E2E.Test — Windows-only live archive fetch
  through the real lwpt binary.

  This complements the host-shorthand GitHub/GitLab E2E suites by bypassing
  tag/source URL construction and exercising the SChannel archive-body read
  path directly against stable archive endpoints. It exists for the Windows
  SChannel archive-fetch failure: corrupted SECBUFFER_EXTRA handling can turn
  the next TLS record into SEC_E_INVALID_TOKEN or an access violation. }

program InstallDirectArchivesWindows.E2E.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess;

const
  GITHUB_DEP_NAME = 'github-archive';
  GITLAB_DEP_NAME = 'gitlab-archive';
  GITHUB_ARCHIVE_URL =
    'https://codeload.github.com/octocat/Hello-World/tar.gz/' +
    '7fd1a60b01f91b314f59955a4e4d4e80d8edf11d';
  GITLAB_ARCHIVE_URL =
    'https://gitlab.com/gitlab-org/release-cli/-/archive/v0.16.0/' +
    'release-cli-v0.16.0.tar.gz';

type
  TInstallDirectArchivesWindowsE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot: string;
    FSkipped: Boolean;
    FInstallExitCode: Integer;
    FInstallStderr: string;
    procedure WriteFile(const APath, AContent: string);
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestInstallExitsZero;
    procedure TestArchivesDownloadedAndExtracted;
    procedure TestLockfileRecordsDirectArchiveURLs;
  end;

procedure RecursiveDelete(const APath: string);
var
  SR: TSearchRec;
  Base: string;
begin
  if not DirectoryExists(APath) then
    Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
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
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(APath);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TInstallDirectArchivesWindowsE2E.WriteFile(const APath,
  AContent: string);
var
  SL: TStringList;
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

procedure TInstallDirectArchivesWindowsE2E.SetupScratchProject;
begin
  ForceDirectories(FRoot + '/source');
  WriteFile(FRoot + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin end.'#10);
  WriteFile(FRoot + '/lwpt.toml',
    '[package]'#10 +
    'name = "direct-archives-windows-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    GITHUB_DEP_NAME + ' = "' + GITHUB_ARCHIVE_URL + '"'#10 +
    GITLAB_DEP_NAME + ' = "' + GITLAB_ARCHIVE_URL + '"'#10);
end;

procedure TInstallDirectArchivesWindowsE2E.BeforeAll;
var
  R: TLwptResult;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/install-direct-archives-windows-e2e');
  FRoot := FScratch + '/root';
  FSkipped := SkipNetworkTests;
  {$IFNDEF MSWINDOWS}
  FSkipped := True;
  {$ENDIF}
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  if FSkipped then
  begin
    WriteLn('  [skip] Windows SChannel live-network test skipped');
    Exit;
  end;

  RecursiveDelete(FScratch);
  ForceDirectories(FRoot);
  SetupScratchProject;

  R := RunLwpt(['install'], FRoot);
  FInstallExitCode := R.ExitCode;
  FInstallStderr := R.Stderr;
end;

procedure TInstallDirectArchivesWindowsE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInstallDirectArchivesWindowsE2E.TestInstallExitsZero;
begin
  if FSkipped then
  begin
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  if FInstallExitCode <> 0 then
    WriteLn('--- install stderr ---'#10, FInstallStderr, #10'---');
  Expect<Integer>(FInstallExitCode).ToBe(0);
end;

procedure TInstallDirectArchivesWindowsE2E.TestArchivesDownloadedAndExtracted;
begin
  if FSkipped then
  begin
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  Expect<Boolean>(
    FileExists(FRoot + '/.lwpt/archives/' + GITHUB_DEP_NAME + '-url.tar.gz')
  ).ToBe(True);
  Expect<Boolean>(
    FileExists(FRoot + '/.lwpt/archives/' + GITLAB_DEP_NAME + '-url.tar.gz')
  ).ToBe(True);
  Expect<Boolean>(
    FileExists(FRoot + '/.lwpt/modules/' + GITHUB_DEP_NAME + '/README') or
    FileExists(FRoot + '/.lwpt/modules/' + GITHUB_DEP_NAME + '/README.md')
  ).ToBe(True);
  Expect<Boolean>(
    FileExists(FRoot + '/.lwpt/modules/' + GITLAB_DEP_NAME + '/README.md') or
    FileExists(FRoot + '/.lwpt/modules/' + GITLAB_DEP_NAME + '/Makefile')
  ).ToBe(True);
end;

procedure TInstallDirectArchivesWindowsE2E.TestLockfileRecordsDirectArchiveURLs;
var
  Lock: string;
begin
  if FSkipped then
  begin
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  Lock := ReadFileText(FRoot + '/lwpt.lock');
  Expect<Boolean>(Pos('source = "' + GITHUB_ARCHIVE_URL + '"', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('source = "' + GITLAB_ARCHIVE_URL + '"', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('archiveHash = "sha256:', Lock) > 0).ToBe(True);
end;

procedure TInstallDirectArchivesWindowsE2E.SetupTests;
begin
  Test('install exits zero against direct archive URLs',
    TestInstallExitsZero);
  Test('direct archives are downloaded and extracted',
    TestArchivesDownloadedAndExtracted);
  Test('lockfile records direct archive URLs and hashes',
    TestLockfileRecordsDirectArchiveURLs);
end;

begin
  TestRunnerProgram.AddSuite(TInstallDirectArchivesWindowsE2E.Create(
    'install: direct archives via Windows SChannel (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
