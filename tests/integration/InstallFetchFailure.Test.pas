{ InstallFetchFailure.Test — spawn `lwpt install` against a
  manifest whose dependency cannot be fetched, and assert the binary
  exits cleanly with EFetchError on stderr and no orphans left under
  .lwpt/tmp/.

  Failure modes covered:

    - Local source pointing at a non-existent directory. FetchToCache
      raises EFetchError naming the dep + the missing path; the error-
      error model + recovery hint then prints to stderr.

  HTTP failure modes (500, unreachable port, timeout) are NOT covered
  here because the github / release source kinds build URLs from a
  hardcoded base prefix and cannot be pointed at a mock server
  without an env-var hook. That hook + the live-network HTTP-500
  test land alongside the GitHub/GitLab/Bitbucket suites; the
  fetch-failure CONTRACT (EFetchError raised, exit != 0, tmp clean)
  is exercised by the local-source-missing path here. }

program InstallFetchFailure.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

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

procedure TInstallFetchFailureE2E.SetupScratchProject;
begin
  ForceDirectories(FRoot + '/source');
  { Tiny program file so the manifest parses + units = ["source"]
    resolves to an existing directory. }
  WriteTestFile(FRoot + '/source/main.pas',
    'program main;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''noop'');'#10 +
    'end.'#10);

  { Manifest with one local-source dep pointing at a path that does
    not exist. lwpt install must fail with EFetchError naming the dep
    and the missing path. }
  WriteTestFile(FRoot + '/lwpt.toml',
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
  FScratch := ExpandFileName('build/tests/tmp/install-fetch-failure-e2e');
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

begin
  TestRunnerProgram.AddSuite(TInstallFetchFailureE2E.Create(
    'install: fetch failure (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
