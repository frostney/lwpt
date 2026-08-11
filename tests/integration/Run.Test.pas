{ Run.Test — pins lwpt run subcommand semantics (ADR-0013).

  `lwpt run <name>` resolves <name> against either:
    (a) a user-declared run task in the consumer's manifest (any
        top-level section with a `command` field that isn't a reserved
        subcommand name), or
    (b) a built-in subcommand — `lwpt run install --frozen` aliases to
        `lwpt install --frozen`.

  Four assertions:
    1. User-task invocation propagates the command's exit code.
    2. Aliased built-in subcommand runs the subcommand correctly.
    3. Aliased built-in with flag passthrough works (--frozen).
    4. Unknown name exits non-zero with a useful message.

  Scratch project: a minimal manifest with one user-defined run task
  section (`[hello] command = "instantfpc"`) plus a tiny InstantFPC
  script that writes a sentinel marker the test then asserts on. }

program Run.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TRunE2E = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestUserTaskInvokesAndPropagatesExitCode;
    procedure TestAliasInstallSubcommand;
    procedure TestAliasWithFlagPassthrough;
    procedure TestListModeOmitsRetiredExport;
    procedure TestExportCanBeUserTaskName;
    procedure TestUnknownNameExitsNonZero;
    procedure TestRunTaskStalenessSkipsFreshOutput;
    procedure TestRunTaskUnmatchedInputFails;
    procedure TestRunTaskRejectsInvocationArguments;
  end;

const
  FileAgeOrderingTimeoutMilliseconds = 10000;

procedure WriteUntilFileAgeAfter(const APath, AContent: string;
  const AOlderPaths: array of string);
var
  CandidateAge, OlderAge: LongInt;
  Deadline: QWord;
  i: Integer;
  Ordered: Boolean;
  BlockingPath: string;
begin
  Deadline := GetTickCount64 + FileAgeOrderingTimeoutMilliseconds;
  repeat
    WriteTextFile(APath, AContent);
    CandidateAge := FileAge(APath);
    Ordered := CandidateAge >= 0;
    BlockingPath := '';
    OlderAge := -1;
    for i := Low(AOlderPaths) to High(AOlderPaths) do
    begin
      OlderAge := FileAge(AOlderPaths[i]);
      if (OlderAge < 0) or (CandidateAge <= OlderAge) then
      begin
        Ordered := False;
        BlockingPath := AOlderPaths[i];
        Break;
      end;
    end;
    if Ordered then Exit;
    Sleep(100);
  until GetTickCount64 >= Deadline;
  raise Exception.CreateFmt(
    'timed out establishing file-age order: %s (%d) after %s (%d)',
    [APath, CandidateAge, BlockingPath, OlderAge]);
end;

procedure TRunE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/scripts');

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "run-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[hello]'#10 +
    'command = "instantfpc"'#10 +
    'args = ["scripts/hello.pas", "first", "two words"]'#10);

  { InstantFPC script: writes a sentinel marker + exits 7. The test
    asserts on both. The marker proves the script ran; the exit code
    proves `lwpt run` propagates it. }
  WriteTextFile(FScratch + '/scripts/hello.pas',
    'program Hello;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'uses SysUtils, Classes;'#10 +
    'var SL: TStringList;'#10 +
    'begin'#10 +
    '  if (ParamCount <> 2) or (ParamStr(1) <> ''first'')'#10 +
    '     or (ParamStr(2) <> ''two words'') then'#10 +
    '    Halt(6);'#10 +
    '  SL := TStringList.Create;'#10 +
    '  try'#10 +
    '    SL.Add(''ran'');'#10 +
    '    SL.SaveToFile(''marker.txt'');'#10 +
    '  finally'#10 +
    '    SL.Free;'#10 +
    '  end;'#10 +
    '  Halt(7);'#10 +
    'end.'#10);
end;

procedure TRunE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('run-e2e');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;

  RunLwpt(['install'], FScratch);
end;

procedure TRunE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TRunE2E.TestUserTaskInvokesAndPropagatesExitCode;
var R: TLwptResult;
begin
  { Remove any sentinel from a prior test run so its absence is meaningful. }
  DeleteFile(FScratch + '/marker.txt');

  R := RunLwpt(['run', 'hello'], FScratch);
  { Script exits 7; lwpt run must propagate that exit code. }
  Expect<Integer>(R.ExitCode).ToBe(7);
  Expect<Boolean>(FileExists(FScratch + '/marker.txt')).ToBe(True);
end;

procedure TRunE2E.TestAliasInstallSubcommand;
var R: TLwptResult;
begin
  { `lwpt run install` should dispatch to the built-in install
    subcommand identically to `lwpt install`. }
  R := RunLwpt(['run', 'install'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TRunE2E.TestAliasWithFlagPassthrough;
var R: TLwptResult;
begin
  { `lwpt run install --frozen` aliases to `lwpt install --frozen`.
    With a clean lockfile that matches the manifest, this exits 0. }
  R := RunLwpt(['run', 'install', '--frozen'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TRunE2E.TestListModeOmitsRetiredExport;
var R: TLwptResult;
begin
  { The alias list is rendered from the live subcommand registry, so
    every registered subcommand — including the ADR-0019 manifest
    editors add/remove — must appear, and the retired export
    subcommand must not. }
  R := RunLwpt(['run'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('install', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('add', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('remove', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('export', R.Stdout) = 0).ToBe(True);
end;

procedure TRunE2E.TestExportCanBeUserTaskName;
var
  R: TLwptResult;
  ExportScratch: string;
begin
  ExportScratch := FScratch + '-export-script';
  RecursiveDelete(ExportScratch);
  ForceDirectories(ExportScratch + '/scripts');

  WriteTextFile(ExportScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "run-export-script"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[export]'#10 +
    'command = "instantfpc"'#10 +
    'args = ["scripts/export.pas"]'#10);

  WriteTextFile(ExportScratch + '/scripts/export.pas',
    'program ExportScript;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'uses SysUtils, Classes;'#10 +
    'var SL: TStringList;'#10 +
    'begin'#10 +
    '  SL := TStringList.Create;'#10 +
    '  try'#10 +
    '    SL.Add(''export-script-ran'');'#10 +
    '    SL.SaveToFile(''export-marker.txt'');'#10 +
    '  finally'#10 +
    '    SL.Free;'#10 +
    '  end;'#10 +
    'end.'#10);

  R := RunLwpt(['run', 'export'], ExportScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExportScratch + '/export-marker.txt')).ToBe(True);
end;

procedure TRunE2E.TestRunTaskStalenessSkipsFreshOutput;
var
  R: TLwptResult;
begin
  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 + 'name = "run-e2e"'#10 + 'version = "0.0.0"'#10 +
    '[fresh]'#10 +
    'command = "instantfpc"'#10 +
    'args = ["scripts/fresh.pas"]'#10 +
    'inputs = ["scripts/*.pas"]'#10 +
    'output = "fresh-marker.txt"'#10);
  WriteTextFile(FScratch + '/scripts/fresh.pas',
    'program Fresh;'#10 + '{$mode delphi}{$H+}'#10 +
    'uses Classes;'#10 + 'var L: TStringList;'#10 + 'begin'#10 +
    '  L := TStringList.Create; try L.Add(''once'');'#10 +
    '  L.SaveToFile(''fresh-marker.txt''); finally L.Free; end;'#10 +
    'end.'#10);
  DeleteFile(FScratch + '/fresh-marker.txt');
  R := RunLwpt(['run', 'fresh'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/fresh-marker.txt')).ToBe(True);
  WriteUntilFileAgeAfter(FScratch + '/fresh-marker.txt', 'fresh-preserved',
    [FScratch + '/scripts/fresh.pas', FScratch + '/scripts/hello.pas']);
  R := RunLwpt(['run', 'fresh'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(Trim(ReadBinaryFile(FScratch + '/fresh-marker.txt')))
    .ToBe('fresh-preserved');

  WriteUntilFileAgeAfter(FScratch + '/scripts/fresh.pas',
    ReadBinaryFile(FScratch + '/scripts/fresh.pas') + #10,
    [FScratch + '/fresh-marker.txt']);
  R := RunLwpt(['run', 'fresh'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(Trim(ReadBinaryFile(FScratch + '/fresh-marker.txt')))
    .ToBe('once');
  SetupScratchProject;
end;

procedure TRunE2E.TestRunTaskUnmatchedInputFails;
var
  R: TLwptResult;
  OutsidePath: string;
begin
  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 + 'name = "run-e2e"'#10 + 'version = "0.0.0"'#10 +
    '[missing]'#10 + 'command = "instantfpc"'#10 +
    'args = ["scripts/hello.pas"]'#10 +
    'inputs = ["missing/**/*.proto"]'#10 +
    'output = "generated.out"'#10);
  R := RunLwpt(['run', 'missing'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('runnable "missing"', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('missing/**/*.proto', R.Stderr) > 0).ToBe(True);

  OutsidePath := FScratch + '-outside-input.txt';
  WriteTextFile(OutsidePath, 'outside');
  try
    WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10 + 'name = "run-e2e"'#10 + 'version = "0.0.0"'#10 +
      '[escape]'#10 + 'command = "instantfpc"'#10 +
      'args = ["scripts/hello.pas"]'#10 +
      'inputs = ["nested/../../' + ExtractFileName(OutsidePath) + '"]'#10 +
      'output = "generated.out"'#10);
    R := RunLwpt(['run', 'escape'], FScratch);
    Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos('must be project-root-relative', R.Stderr) > 0)
      .ToBe(True);
  finally
    DeleteFile(OutsidePath);
  end;
  SetupScratchProject;
end;

procedure TRunE2E.TestRunTaskRejectsInvocationArguments;
var
  R: TLwptResult;
begin
  R := RunLwpt(['run', 'hello', 'unexpected'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('declare args in lwpt.toml', R.Stderr) > 0).ToBe(True);
end;

procedure TRunE2E.TestUnknownNameExitsNonZero;
var R: TLwptResult;
begin
  R := RunLwpt(['run', 'absolutely-not-a-thing'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
end;

procedure TRunE2E.SetupTests;
begin
  Test('run <task> invokes its direct command and propagates its exit code',
    TestUserTaskInvokesAndPropagatesExitCode);
  Test('run install aliases to the built-in install subcommand',
    TestAliasInstallSubcommand);
  Test('run install --frozen passes flags through to the aliased subcommand',
    TestAliasWithFlagPassthrough);
  Test('run lists every registered alias without the retired export subcommand',
    TestListModeOmitsRetiredExport);
  Test('export is available as a user-declared run-task name',
    TestExportCanBeUserTaskName);
  Test('run <unknown> exits non-zero with a useful error',
    TestUnknownNameExitsNonZero);
  Test('run-task glob staleness skips a fresh output successfully',
    TestRunTaskStalenessSkipsFreshOutput);
  Test('run task reports its name and unmatched input expression',
    TestRunTaskUnmatchedInputFails);
  Test('run task rejects invocation-time arguments',
    TestRunTaskRejectsInvocationArguments);
end;

begin
  TestRunnerProgram.AddSuite(TRunE2E.Create('lwpt run: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
