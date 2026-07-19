{ TestScheduling.Test — parallel test scheduling and numeric bail policy. }
program TestScheduling.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.BuildSession,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  CancellationCompletionCeilingSeconds = 12;
  CompilerExecutableEnvironment = PROJECT_NAME + '_FPC';
  IgnoreTerminateCompilerProxyMode = 'ignore-term';
  LongRunningFixtureMilliseconds = 15000;
  MarkerWaitCeilingSeconds = 5;
  ProcessExitCeilingSeconds = 8;
  ProcessStartupCeilingSeconds = 10;
  ProcessTreeProxyModeEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_TEST_PROXY_MODE';
  ProcessTreeProxyPIDFileEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_TEST_PID_FILE';
  SlowCompilerProxyMode = 'slow';
  WorkerErrorCompilerProxyMode = 'worker-error';
  TestHeartbeatIntervalMilliseconds = 75;
  TestHeartbeatJobDurationMilliseconds =
    TestHeartbeatIntervalMilliseconds * 4;

type
  TTestScheduling = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetProject(const ABail: Integer);
    procedure WriteMarkerProgram(const AFileName, AMarker: string;
      const AExitCode: Integer);
    procedure WriteOverlapProgram(const AFileName, AOwnMarker,
      AOtherMarker: string);
    procedure WriteBuildProject(const AProjectRoot: string);
    function RunTests(const AArgs: array of string): TLwptResult;
    function RunTestsWithCompilerProxy(const AArgs: array of string;
      const AProxyMode, APIDFile: string): TLwptResult;
    {$IFDEF UNIX}
    procedure RunSignalForwardingTest(const ASignal: Integer;
      const AProjectName: string);
    {$ENDIF}
    function RunTestsWithHeartbeat(const AArgs: array of string;
      const AHeartbeatMilliseconds: Integer): TLwptResult;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestDefaultJobsOverlap;
    procedure TestJobsOneRunsInSourceOrder;
    procedure TestBailZeroOverridesManifestAndRunsAll;
    procedure TestCompileFailureCountsTowardBail;
    procedure TestBailTerminatesActiveAndLeavesPendingUnstarted;
    procedure TestBailTerminatesNestedLWPTCompilerIgnoringSIGTERM;
    procedure TestWorkerErrorTerminatesActiveProcessTree;
    {$IFDEF UNIX}
    procedure TestSIGINTTerminatesActiveProcessTree;
    procedure TestSIGTERMTerminatesActiveProcessTree;
    {$ENDIF}
    procedure TestSilentJobEmitsHeartbeatAndProgress;
    procedure TestFailureReplaysAndPreservesIsolatedLog;
    procedure TestVerboseSuccessLogsNeverInterleave;
  end;

function PascalString(const AValue: string): string;
begin
  Result := '''' + StringReplace(AValue, '''', '''''', [rfReplaceAll]) + '''';
end;

{ Scheduler progress lines print discovered test paths with the native
  separator (tests\A.Test.pas on Windows); normalise so assertions can be
  written with '/' on every platform. }
function SlashNorm(const AOutput: string): string;
begin
  Result := StringReplace(AOutput, '\', '/', [rfReplaceAll]);
end;

procedure TTestScheduling.BeforeAll;
begin
  FScratch := CreateScratchRoot('test-scheduling');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure TTestScheduling.BeforeEach;
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch + '/tests');
  ForceDirectories(FScratch + '/control');
end;

procedure TTestScheduling.ResetProject(const ABail: Integer);
begin
  RecursiveDelete(FScratch + '/tests');
  RecursiveDelete(FScratch + '/.lwpt');
  RecursiveDelete(FScratch + '/worker-state');
  RecursiveDelete(FScratch + '/control');
  ForceDirectories(FScratch + '/tests');
  ForceDirectories(FScratch + '/control');
  WriteTextFile(FScratch + '/' + MANIFEST_FILE,
      '[package]'#10
    + 'name = "scheduler-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["tests"]'#10
    + #10
    + '[test]'#10
    + 'bail = ' + IntToStr(ABail) + #10);
end;

procedure TTestScheduling.WriteMarkerProgram(const AFileName,
  AMarker: string; const AExitCode: Integer);
begin
  WriteTextFile(FScratch + '/tests/' + AFileName,
      'program MarkerFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + 'begin'#10
    + '  TFileStream.Create(' + PascalString(FScratch + '/control/' + AMarker)
    + ', fmCreate).Free;'#10
    + '  Halt(' + IntToStr(AExitCode) + ');'#10
    + 'end.'#10);
end;

procedure TTestScheduling.WriteOverlapProgram(const AFileName,
  AOwnMarker, AOtherMarker: string);
begin
  WriteTextFile(FScratch + '/tests/' + AFileName,
      'program OverlapFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Started: TDateTime;'#10
    + 'begin'#10
    + '  TFileStream.Create(' + PascalString(FScratch + '/control/' + AOwnMarker)
    + ', fmCreate).Free;'#10
    + '  Started := Now;'#10
    + '  while (not FileExists('
    + PascalString(FScratch + '/control/' + AOtherMarker) + '))'#10
    + '    and ((Now - Started) * ' + IntToStr(SecondsPerDay) + ' < '
    + IntToStr(MarkerWaitCeilingSeconds) + ') do Sleep('
    + IntToStr(ProcessPollMilliseconds) + ');'#10
    + '  if not FileExists('
    + PascalString(FScratch + '/control/' + AOtherMarker) + ') then Halt(2);'#10
    + 'end.'#10);
end;

procedure TTestScheduling.WriteBuildProject(const AProjectRoot: string);
begin
  ForceDirectories(AProjectRoot + '/source');
  WriteTextFile(AProjectRoot + '/' + MANIFEST_FILE,
      '[package]'#10
    + 'name = "process-tree-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app" }'#10);
  WriteTextFile(AProjectRoot + '/source/app.pas',
      'program ProcessTreeFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin'#10
    + 'end.'#10);
end;

function TTestScheduling.RunTests(const AArgs: array of string): TLwptResult;
begin
  Result := RunTestsWithHeartbeat(AArgs, 0);
end;

function TTestScheduling.RunTestsWithHeartbeat(
  const AArgs: array of string;
  const AHeartbeatMilliseconds: Integer): TLwptResult;
var
  Args, Environment: array of string;
  ArgumentIndex: Integer;
begin
  SetLength(Args, Length(AArgs) + 1);
  Args[0] := 'test';
  for ArgumentIndex := 0 to High(AArgs) do
    Args[ArgumentIndex + 1] := AArgs[ArgumentIndex];
  if AHeartbeatMilliseconds > 0 then SetLength(Environment, 4)
  else SetLength(Environment, 3);
  Environment[0] := WORKER_LEASE_TOKEN_ENV + '=';
  Environment[1] := WORKER_STATE_DIR_ENV + '='
    + FScratch + '/worker-state';
  Environment[2] := WORKER_BUDGET_ENV + '=2';
  if AHeartbeatMilliseconds > 0 then
    Environment[3] := ObservabilityHeartbeatIntervalEnvironment + '='
      + IntToStr(AHeartbeatMilliseconds);
  Result := RunLwpt(Args, FScratch, Environment);
end;

function TTestScheduling.RunTestsWithCompilerProxy(
  const AArgs: array of string; const AProxyMode,
  APIDFile: string): TLwptResult;
var
  Args, Environment: array of string;
  ArgumentIndex: Integer;
begin
  SetLength(Args, Length(AArgs) + 1);
  Args[0] := 'test';
  for ArgumentIndex := 0 to High(AArgs) do
    Args[ArgumentIndex + 1] := AArgs[ArgumentIndex];
  SetLength(Environment, 6);
  Environment[0] := WORKER_LEASE_TOKEN_ENV + '=';
  Environment[1] := WORKER_STATE_DIR_ENV + '='
    + FScratch + '/worker-state';
  Environment[2] := WORKER_BUDGET_ENV + '=2';
  Environment[3] := CompilerExecutableEnvironment + '='
    + ExpandFileName(ParamStr(0));
  Environment[4] := ProcessTreeProxyModeEnvironment + '=' + AProxyMode;
  Environment[5] := ProcessTreeProxyPIDFileEnvironment + '=' + APIDFile;
  Result := RunLwpt(Args, FScratch, Environment);
end;

procedure TTestScheduling.TestSilentJobEmitsHeartbeatAndProgress;
var
  RunResult: TLwptResult;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Silent.Test.pas',
      'program SilentFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'begin Sleep(' + IntToStr(TestHeartbeatJobDurationMilliseconds)
    + ') end.'#10);
  WriteTextFile(FScratch + '/tests/e2e/B.Skip.Test.pas',
      'program SkipFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin end.'#10);
  RunResult := RunTestsWithHeartbeat([], TestHeartbeatIntervalMilliseconds);
  Expect<Integer>(RunResult.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('test session: ', RunResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('(.lwpt/sessions/', RunResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('discovered 2 test file(s)', RunResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('effective workers: 1', RunResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('START tests/A.Silent.Test.pas',
    SlashNorm(RunResult.Stdout)) > 0).ToBe(True);
  Expect<Boolean>(Pos('HEARTBEAT test elapsed ', RunResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('active: tests/A.Silent.Test.pas',
    SlashNorm(RunResult.Stdout)) > 0).ToBe(True);
  Expect<Boolean>(Pos('PASS tests/A.Silent.Test.pas',
    SlashNorm(RunResult.Stdout)) > 0).ToBe(True);
  Expect<Boolean>(Pos('SKIP tests/e2e/B.Skip.Test.pas (e2e tier)',
    SlashNorm(RunResult.Stdout)) > 0).ToBe(True);
  Expect<Boolean>(Pos('summary: 1 passed, 0 failed, 0 did not compile, '
    + '1 skipped, 0 cancelled; elapsed ', RunResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos(' ms', RunResult.Stdout) > 0).ToBe(True);
end;

procedure TTestScheduling.TestFailureReplaysAndPreservesIsolatedLog;
var
  RunResult: TLwptResult;
  SessionSearch, LogSearch: TSearchRec;
  LogPath: string;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Fail.Test.pas',
      'program FailingFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin Write(''failure-detail-41''); Halt(7) end.'#10);
  RunResult := RunTests([]);
  Expect<Integer>(RunResult.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('FAIL tests/A.Fail.Test.pas (exit 7;',
    SlashNorm(RunResult.Stdout)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('failure-detail-41', SlashNorm(RunResult.Stdout))
    > Pos('FAIL tests/A.Fail.Test.pas', SlashNorm(RunResult.Stdout)))
    .ToBe(True);
  LogPath := '';
  if FindFirst(FScratch + '/.lwpt/sessions/s-*', faDirectory,
    SessionSearch) = 0 then
  try
    repeat
      if (SessionSearch.Attr and faDirectory) = 0 then Continue;
      if FindFirst(FScratch + '/.lwpt/sessions/' + SessionSearch.Name
        + '/logs/*.log', faAnyFile, LogSearch) = 0 then
      try
        LogPath := FScratch + '/.lwpt/sessions/' + SessionSearch.Name
          + '/logs/' + LogSearch.Name;
      finally
        FindClose(LogSearch);
      end;
    until (LogPath <> '') or (FindNext(SessionSearch) <> 0);
  finally
    FindClose(SessionSearch);
  end;
  Expect<Boolean>(LogPath <> '').ToBe(True);
  Expect<Boolean>(Pos('failure-detail-41', ReadBinaryFile(LogPath)) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestVerboseSuccessLogsNeverInterleave;
var
  RunResult: TLwptResult;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Output.Test.pas',
      'program OutputA;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'begin Write(''alpha-1|''); Flush(Output); Sleep(120); '
    + 'Write(''alpha-2|'') end.'#10);
  WriteTextFile(FScratch + '/tests/B.Output.Test.pas',
      'program OutputB;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'begin Write(''beta-1|''); Flush(Output); Sleep(80); '
    + 'Write(''beta-2|'') end.'#10);
  RunResult := RunTests([]);
  Expect<Integer>(RunResult.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('alpha-1|', RunResult.Stdout) = 0).ToBe(True);
  Expect<Boolean>(Pos('beta-1|', RunResult.Stdout) = 0).ToBe(True);
  Expect<Boolean>(Pos('HEARTBEAT ', RunResult.Stdout) = 0).ToBe(True);

  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Output.Test.pas',
      'program OutputA;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'begin Write(''alpha-1|''); Flush(Output); Sleep(120); '
    + 'Write(''alpha-2|'') end.'#10);
  WriteTextFile(FScratch + '/tests/B.Output.Test.pas',
      'program OutputB;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'begin Write(''beta-1|''); Flush(Output); Sleep(80); '
    + 'Write(''beta-2|'') end.'#10);
  RunResult := RunTests(['--verbose']);
  Expect<Integer>(RunResult.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('alpha-1|alpha-2|', RunResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('beta-1|beta-2|', RunResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('summary: 2 passed, 0 failed, 0 did not compile, '
    + '0 skipped, 0 cancelled; elapsed ', RunResult.Stdout) > 0).ToBe(True);
end;

procedure TTestScheduling.TestDefaultJobsOverlap;
var
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  WriteOverlapProgram('A.First.Test.pas', 'first-started', 'second-started');
  WriteOverlapProgram('B.Second.Test.pas', 'second-started', 'first-started');
  CommandResult := RunTests([]);
  Expect<Integer>(CommandResult.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/control/first-started')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/second-started')).ToBe(True);
end;

procedure TTestScheduling.TestJobsOneRunsInSourceOrder;
var
  CommandResult: TLwptResult;
  Lines: TStringList;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.First.Test.pas',
      'program FirstFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.Add(''first'');'#10
    + '    Lines.SaveToFile('
    + PascalString(FScratch + '/control/order') + ');'#10
    + '  finally Lines.Free end;'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/tests/B.Second.Test.pas',
      'program SecondFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.LoadFromFile('
    + PascalString(FScratch + '/control/order') + ');'#10
    + '    Lines.Add(''second'');'#10
    + '    Lines.SaveToFile('
    + PascalString(FScratch + '/control/order') + ');'#10
    + '  finally Lines.Free end;'#10
    + 'end.'#10);
  CommandResult := RunTests(['--jobs=1']);
  Expect<Integer>(CommandResult.ExitCode).ToBe(0);
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/control/order');
    Expect<Integer>(Lines.Count).ToBe(2);
    Expect<string>(Lines[0]).ToBe('first');
    Expect<string>(Lines[1]).ToBe('second');
  finally
    Lines.Free;
  end;
end;

procedure TTestScheduling.TestBailZeroOverridesManifestAndRunsAll;
var
  CommandResult: TLwptResult;
begin
  ResetProject(1);
  WriteMarkerProgram('A.Fail.Test.pas', 'failed-ran', 1);
  WriteMarkerProgram('B.Pass.Test.pas', 'pass-ran', 0);
  CommandResult := RunTests(['--jobs=1', '--bail=0']);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(FScratch + '/control/failed-ran')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/pass-ran')).ToBe(True);
  Expect<Boolean>(Pos('1 passed, 1 failed', CommandResult.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestCompileFailureCountsTowardBail;
var
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Bad.Test.pas',
    'program BadFixture; begin this is not valid pascal end.'#10);
  WriteMarkerProgram('B.Pending.Test.pas', 'pending-ran', 0);
  CommandResult := RunTests(['--jobs=1', '--bail=1']);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(FScratch + '/control/pending-ran')).ToBe(False);
  Expect<Boolean>(Pos('A.Bad.Test.pas ... COMPILE FAILED',
    CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('B.Pending.Test.pas ... cancelled',
    CommandResult.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestBailTerminatesActiveAndLeavesPendingUnstarted;
var
  CommandResult: TLwptResult;
  Started: TDateTime;
  GrandchildPID: Integer;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Slow.Test.pas',
      'program SlowFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, Process, SysUtils;'#10
    + 'var Child: TProcess; PIDFile: TStringList;'#10
    + 'begin'#10
    + '  if (ParamCount = 1) and (ParamStr(1) = ''--grandchild'') then'#10
    + '  begin Sleep(' + IntToStr(LongRunningFixtureMilliseconds)
    + '); Halt(0) end;'#10
    + '  Child := TProcess.Create(nil);'#10
    + '  Child.Executable := ParamStr(0);'#10
    + '  Child.Parameters.Add(''--grandchild'');'#10
    + '  Child.Execute;'#10
    + '  PIDFile := TStringList.Create;'#10
    + '  try'#10
    + '    PIDFile.Text := IntToStr(Child.ProcessID);'#10
    + '    PIDFile.SaveToFile('
    + PascalString(FScratch + '/control/grandchild-pid') + ');'#10
    + '  finally PIDFile.Free end;'#10
    + '  TFileStream.Create('
    + PascalString(FScratch + '/control/slow-started')
    + ', fmCreate).Free;'#10
    + '  Sleep(' + IntToStr(LongRunningFixtureMilliseconds) + ');'#10
    + '  TFileStream.Create('
    + PascalString(FScratch + '/control/slow-completed')
    + ', fmCreate).Free;'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/tests/B.Fail.Test.pas',
      'program FailFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'var Started: TDateTime;'#10
    + 'begin'#10
    + '  Started := Now;'#10
    + '  while (not FileExists('
    + PascalString(FScratch + '/control/slow-started') + '))'#10
    + '    and ((Now - Started) * ' + IntToStr(SecondsPerDay) + ' < '
    + IntToStr(MarkerWaitCeilingSeconds) + ') do Sleep('
    + IntToStr(ProcessPollMilliseconds) + ');'#10
    + '  if not FileExists('
    + PascalString(FScratch + '/control/slow-started') + ') then Halt(2);'#10
    + '  Halt(1);'#10
    + 'end.'#10);
  WriteMarkerProgram('C.Pending.Test.pas', 'pending-ran', 0);
  Started := Now;
  CommandResult := RunTests(['--jobs=2', '--bail=1']);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>((Now - Started) * SecondsPerDay
    < CancellationCompletionCeilingSeconds).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/slow-started')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/slow-completed')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/control/pending-ran')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/control/grandchild-pid')).ToBe(True);
  GrandchildPID := StrToInt(Trim(ReadBinaryFile(
    FScratch + '/control/grandchild-pid')));
  Started := Now;
  while ProcessIsRunning(GrandchildPID)
    and ((Now - Started) * SecondsPerDay < ProcessExitCeilingSeconds) do
    Sleep(ProcessPollMilliseconds);
  Expect<Boolean>(ProcessIsRunning(GrandchildPID)).ToBe(False);
  Expect<Boolean>(Pos('A.Slow.Test.pas ... cancelled',
    CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('B.Fail.Test.pas ... FAIL (exit 1)',
    CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('C.Pending.Test.pas ... cancelled',
    CommandResult.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestBailTerminatesNestedLWPTCompilerIgnoringSIGTERM;
var
  CompilerPID: Integer;
  NestedProject, PIDFile: string;
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  NestedProject := FScratch + '/nested-build';
  PIDFile := FScratch + '/control/nested-compiler-pid';
  WriteBuildProject(NestedProject);
  WriteTextFile(FScratch + '/tests/A.Nested.Test.pas',
      'program Nested' + PROJECT_NAME + 'Fixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Process, SysUtils;'#10
    + 'var Child: TProcess; Entry: string; Index: Integer;'#10
    + 'begin'#10
    + '  Child := TProcess.Create(nil);'#10
    + '  try'#10
    + '    Child.Executable := '
    + PascalString(LwptBinaryPath) + ';'#10
    + '    Child.Parameters.Add(''build'');'#10
    + '    Child.CurrentDirectory := ' + PascalString(NestedProject) + ';'#10
    + '    for Index := 1 to GetEnvironmentVariableCount do'#10
    + '    begin'#10
    + '      Entry := GetEnvironmentString(Index);'#10
    + '      if (not SameText(Copy(Entry, 1, Length('
    + PascalString(CompilerExecutableEnvironment + '=') + ')), '
    + PascalString(CompilerExecutableEnvironment + '=') + '))'#10
    + '        and (not SameText(Copy(Entry, 1, Length('
    + PascalString(ProcessTreeProxyModeEnvironment + '=') + ')), '
    + PascalString(ProcessTreeProxyModeEnvironment + '=') + '))'#10
    + '        and (not SameText(Copy(Entry, 1, Length('
    + PascalString(ProcessTreeProxyPIDFileEnvironment + '=') + ')), '
    + PascalString(ProcessTreeProxyPIDFileEnvironment + '=') + ')) then'#10
    + '        Child.Environment.Add(Entry);'#10
    + '    end;'#10
    + '    Child.Environment.Add('
    + PascalString(CompilerExecutableEnvironment + '='
      + ExpandFileName(ParamStr(0))) + ');'#10
    + '    Child.Environment.Add('
    + PascalString(ProcessTreeProxyModeEnvironment + '='
      + IgnoreTerminateCompilerProxyMode) + ');'#10
    + '    Child.Environment.Add('
    + PascalString(ProcessTreeProxyPIDFileEnvironment + '=' + PIDFile)
    + ');'#10
    + '    Child.Execute;'#10
    + '    Child.WaitOnExit;'#10
    + '  finally'#10
    + '    Child.Free;'#10
    + '  end;'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/tests/B.Fail.Test.pas',
      'program FailAfterNestedCompilerStarts;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'var Started: TDateTime;'#10
    + 'begin'#10
    + '  Started := Now;'#10
    + '  while (not FileExists(' + PascalString(PIDFile) + '))'#10
    + '    and ((Now - Started) * ' + IntToStr(SecondsPerDay) + ' < '
    + IntToStr(MarkerWaitCeilingSeconds) + ') do Sleep('
    + IntToStr(ProcessPollMilliseconds) + ');'#10
    + '  if not FileExists(' + PascalString(PIDFile) + ') then Halt(2);'#10
    + '  Halt(1);'#10
    + 'end.'#10);
  WriteMarkerProgram('C.Pending.Test.pas', 'nested-pending-ran', 0);

  CommandResult := RunTests(['--jobs=2', '--bail=1']);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(PIDFile)).ToBe(True);
  CompilerPID := StrToInt(Trim(ReadBinaryFile(PIDFile)));
  { Reap-until-empty is part of the command-return contract: no retry loop. }
  Expect<Boolean>(ProcessIsRunning(CompilerPID)).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/control/nested-pending-ran'))
    .ToBe(False);
  Expect<Boolean>(Pos('A.Nested.Test.pas ... cancelled',
    CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('B.Fail.Test.pas ... FAIL (exit 1)',
    CommandResult.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestWorkerErrorTerminatesActiveProcessTree;
var
  CompilerPID: Integer;
  PIDFile: string;
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  PIDFile := FScratch + '/control/worker-error-compiler-pid';
  WriteTextFile(FScratch + '/tests/A.Slow.Test.pas',
    'program SlowCompilerInput; begin end.'#10);
  WriteTextFile(FScratch + '/tests/B.Error.Test.pas',
    'program MissingRuntimeBinaryInput; begin end.'#10);

  CommandResult := RunTestsWithCompilerProxy(['--jobs=2'],
    WorkerErrorCompilerProxyMode, PIDFile);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(PIDFile)).ToBe(True);
  CompilerPID := StrToInt(Trim(ReadBinaryFile(PIDFile)));
  Expect<Boolean>(ProcessIsRunning(CompilerPID)).ToBe(False);
  Expect<Boolean>(Pos('B.Error.Test.pas ... ERROR', CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('scheduler error:', CommandResult.Stderr) > 0)
    .ToBe(True);
end;

{$IFDEF UNIX}
procedure TTestScheduling.RunSignalForwardingTest(const ASignal: Integer;
  const AProjectName: string);
var
  CompilerPID: Integer;
  Environment: array of string;
  PIDFile, ProjectRoot: string;
  Process: TProcess;
  Started: TDateTime;
begin
  ProjectRoot := FScratch + '/' + AProjectName;
  PIDFile := FScratch + '/control/' + AProjectName + '-compiler-pid';
  WriteBuildProject(ProjectRoot);
  SetLength(Environment, 6);
  Environment[0] := WORKER_LEASE_TOKEN_ENV + '=';
  Environment[1] := WORKER_STATE_DIR_ENV + '=' + FScratch
    + '/' + AProjectName + '-worker-state';
  Environment[2] := WORKER_BUDGET_ENV + '=1';
  Environment[3] := CompilerExecutableEnvironment + '='
    + ExpandFileName(ParamStr(0));
  Environment[4] := ProcessTreeProxyModeEnvironment + '='
    + SlowCompilerProxyMode;
  Environment[5] := ProcessTreeProxyPIDFileEnvironment + '=' + PIDFile;

  CompilerPID := -1;
  Process := TProcess.Create(nil);
  try
    Process.Executable := LwptBinaryPath;
    Process.Parameters.Add('build');
    Process.CurrentDirectory := ProjectRoot;
    ConfigureProcessEnvironment(Process, Environment);
    Process.Execute;
    Started := Now;
    while (not FileExists(PIDFile))
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(FileExists(PIDFile)).ToBe(True);
    CompilerPID := StrToInt(Trim(ReadBinaryFile(PIDFile)));
    Expect<Integer>(FpKill(Process.ProcessID, ASignal)).ToBe(0);
    Started := Now;
    while Process.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessExitCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(Process.Running).ToBe(False);
    Process.WaitOnExit;
    Expect<Integer>(Process.ExitStatus).ToBe(ASignal);
    Expect<Boolean>(ProcessIsRunning(CompilerPID)).ToBe(False);
  finally
    if Process.Running then FpKill(Process.ProcessID, SIGKILL);
    if ProcessIsRunning(CompilerPID) then FpKill(CompilerPID, SIGKILL);
    Process.Free;
  end;
end;

procedure TTestScheduling.TestSIGINTTerminatesActiveProcessTree;
begin
  RunSignalForwardingTest(SIGINT, 'signal-int');
end;

procedure TTestScheduling.TestSIGTERMTerminatesActiveProcessTree;
begin
  RunSignalForwardingTest(SIGTERM, 'signal-term');
end;
{$ENDIF}

function RunProcessTreeCompilerProxy: Integer;
var
  Mode, PIDFile, SourceFile: string;
  Started: TDateTime;
begin
  if (ParamCount = 1) and (ParamStr(1) = '-iV') then
  begin
    WriteLn('3.2.2');
    Exit(0);
  end;
  Mode := GetEnvironmentVariable(ProcessTreeProxyModeEnvironment);
  PIDFile := GetEnvironmentVariable(ProcessTreeProxyPIDFileEnvironment);
  if ParamCount > 0 then SourceFile := ExtractFileName(ParamStr(ParamCount))
  else SourceFile := '';

  {$IFDEF UNIX}
  if Mode = IgnoreTerminateCompilerProxyMode then
    FpSignal(SIGTERM, SignalHandler(SIG_IGN));
  {$ENDIF}
  if (Mode = SlowCompilerProxyMode)
     or (Mode = IgnoreTerminateCompilerProxyMode)
     or ((Mode = WorkerErrorCompilerProxyMode)
       and SameText(SourceFile, 'A.Slow.Test.pas')) then
  begin
    WriteTextFile(PIDFile, IntToStr(GetProcessID));
    Sleep(LongRunningFixtureMilliseconds);
    Exit(0);
  end;

  if Mode = WorkerErrorCompilerProxyMode then
  begin
    { Returning compiler success without creating B.Error's binary makes its
      runtime TProcess.Execute raise, driving AbortWithError while A is live. }
    Started := Now;
    while (not FileExists(PIDFile))
      and ((Now - Started) * SecondsPerDay < MarkerWaitCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Exit(0);
  end;
  Result := 1;
end;

procedure TTestScheduling.SetupTests;
begin
  Test('default jobs overlap', TestDefaultJobsOverlap);
  Test('--jobs=1 runs in source order', TestJobsOneRunsInSourceOrder);
  Test('--bail=0 overrides manifest and runs all',
    TestBailZeroOverridesManifestAndRunsAll);
  Test('compile failure counts toward bail',
    TestCompileFailureCountsTowardBail);
  Test('bail terminates active and leaves pending unstarted',
    TestBailTerminatesActiveAndLeavesPendingUnstarted);
  Test('bail reaps nested ' + PROJECT_NAME
    + ' compiler that ignores SIGTERM',
    TestBailTerminatesNestedLWPTCompilerIgnoringSIGTERM);
  Test('worker error terminates another active process tree',
    TestWorkerErrorTerminatesActiveProcessTree);
  {$IFDEF UNIX}
  Test('SIGINT reaps the active compiler tree',
    TestSIGINTTerminatesActiveProcessTree);
  Test('SIGTERM reaps the active compiler tree',
    TestSIGTERMTerminatesActiveProcessTree);
  {$ENDIF}
  Test('silent jobs emit heartbeat and serialized progress',
    TestSilentJobEmitsHeartbeatAndProgress);
  Test('failures replay output and preserve isolated logs',
    TestFailureReplaysAndPreservesIsolatedLog);
  Test('verbose success logs never interleave',
    TestVerboseSuccessLogsNeverInterleave);
end;

begin
  if GetEnvironmentVariable(ProcessTreeProxyModeEnvironment) <> '' then
    Halt(RunProcessTreeCompilerProxy);
  TestRunnerProgram.AddSuite(TTestScheduling.Create('TestScheduling'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
