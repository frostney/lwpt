{ TestScheduling.Test — parallel test scheduling and numeric bail policy. }
program TestScheduling.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  Platform,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.ProcessSupport,
  Tests.Scratch,

  LWPT.BuildSession,
  LWPT.Core,
  LWPT.ProcessTree,
  LWPT.ProgressReporter,
  LWPT.WorkerBudget;

const
  CancellationCompletionCeilingSeconds = 12;
  AcknowledgementSuccessExitDelayMilliseconds = 300;
  CompilerExecutableEnvironment = PROJECT_NAME + '_FPC';
  IgnoreTerminateCompilerProxyMode = 'ignore-term';
  LongRunningFixtureMilliseconds = 15000;
  MarkerWaitCeilingSeconds = 5;
  ProcessExitCeilingSeconds = 8;
  ProcessStartupCeilingSeconds = 10;
  WindowsControllerCompletionCeilingSeconds =
    ProcessStartupCeilingSeconds + ProcessExitCeilingSeconds + 2;
  ProcessCaptureOverflowBytes = 16 * 1024 * 1024 + 64 * 1024;
  ProcessCaptureOverflowHoldMilliseconds = 2000;
  SiblingFanoutCeilingMilliseconds = 1500;
  { Scheduling speed is not part of the fanout contract. This ceiling only
    diagnoses a sibling that genuinely never reaches the startup barrier. }
  SiblingStartupBarrierCeilingSeconds = ProcessStartupCeilingSeconds * 3;
  ProcessTreeProxyModeEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_TEST_PROXY_MODE';
  ProcessTreeProxyPIDFileEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_TEST_PID_FILE';
  ManagedProcessTreeEnvironment = PROJECT_NAME + '_PROCESS_TREE_PARENT';
  ProcessTreeStatusHandleEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_STATUS_HANDLE';
  ProcessTreeControlHandleEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_CONTROL_HANDLE';
  ProcessTreeChannelTokenEnvironment = PROJECT_NAME
    + '_PROCESS_TREE_CHANNEL_TOKEN';
  ProcessTreeAcknowledgementProtocol = PROJECT_NAME + '-ACK/1';
  SiblingCancellationStartedSuffix = '-cancellation-started';
  NestedCompilerNaturalExitSuffix = '-natural-exit';
  SiblingSlowSources: array[0..5] of string = (
    'A.Slow.Test.pas', 'C.Slow.Test.pas', 'D.Slow.Test.pas',
    'E.Slow.Test.pas', 'F.Slow.Test.pas', 'G.Slow.Test.pas');
  SlowCompilerProxyMode = 'slow';
  WorkerErrorCompilerProxyMode = 'worker-error';
  SuccessfulAcknowledgementCompilerProxyMode = 'successful-acknowledgement';
  FailedAcknowledgementCompilerProxyMode = 'failed-acknowledgement';
  CleanAcknowledgementExitProxyMode = 'clean-acknowledgement-exit';
  MissingAcknowledgementCompilerProxyMode = 'missing-acknowledgement';
  MissingAcknowledgementSiblingCompilerProxyMode =
    'missing-acknowledgement-siblings';
  ImmediateAcknowledgementLeafProxyMode = 'immediate-acknowledgement-leaf';
  InheritedChannelProbeProxyMode = 'inherited-channel-probe';
  SuccessfulAcknowledgementLeafProxyMode = 'successful-acknowledgement-leaf';
  FailedAcknowledgementLeafProxyMode = 'failed-acknowledgement-leaf';
  {$IFDEF MSWINDOWS}
  WindowsConsoleControllerOption = '--' + PROGRAM_NAME
    + '-console-controller';
  WindowsControlExitCode = DWORD($C000013A);
  WindowsIgnoreControlCompilerProxyMode = 'ignore-control';
  {$ENDIF}
  TestHeartbeatIntervalMilliseconds = 75;
  TestHeartbeatJobDurationMilliseconds =
    TestHeartbeatIntervalMilliseconds * 4;

type
  TProcessWaitThread = class(TThread)
  private
    FProcess: TProcess;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProcess: TProcess);
  end;

  TBlockingProcess = class(TProcess)
  private
    FCriticalSection: TRTLCriticalSection;
    FEntered: Boolean;
    FReleased: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
    function Entered: Boolean;
    procedure Release;
  end;

  TNotifyingProcess = class(TProcess)
  private
    FCriticalSection: TRTLCriticalSection;
    FEntered: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
    function Entered: Boolean;
  end;

  TSpawnThread = class(TThread)
  private
    FCriticalSection: TRTLCriticalSection;
    FErrorMessage: string;
    FAttempted: Boolean;
    FProcess: TProcess;
    FProcessTree: TLWPTProcessTree;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProcess: TProcess;
      const AProcessTree: TLWPTProcessTree);
    destructor Destroy; override;
    function Attempted: Boolean;
    property ErrorMessage: string read FErrorMessage;
  end;

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
      const AProxyMode, APIDFile: string;
      const ABudget: Integer = 2): TLwptResult;
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
    procedure TestSuccessfulTerminationAcknowledgementCompletesCancellation;
    procedure TestSuccessfulAcknowledgementHasSeparateReapWindow;
    procedure TestManagedAndUnmanagedSpawnsShareCriticalSection;
    procedure TestExitedRegisteredProcessTreeIsSuccessfulNoOp;
    procedure TestFailedNestedTerminationAcknowledgementFailsCancellation;
    procedure TestMissingTerminationAcknowledgementFailsCancellation;
    procedure TestSiblingTerminationAcknowledgementsShareFanout;
    procedure TestProtocolFramingIsBoundedAndIncremental;
    procedure TestProcessFailureSurvivesDelegationCleanupFailure;
    {$IFDEF UNIX}
    procedure TestSIGINTTerminatesActiveProcessTree;
    procedure TestSIGTERMTerminatesActiveProcessTree;
    procedure TestInheritedChannelRejectsRegularFiles;
    procedure TestInheritedChannelRejectsWrongPipeDirection;
    procedure TestAcknowledgementControlReadIsBounded;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    procedure RunWindowsConsoleForwardingTest(const AControlType: DWORD;
      const AProjectName: string);
    procedure TestCtrlCTerminatesActiveProcessTree;
    procedure TestCtrlBreakTerminatesActiveProcessTree;
    {$ENDIF}
    procedure TestSilentJobEmitsHeartbeatAndProgress;
    procedure TestFailureReplaysAndPreservesIsolatedLog;
    procedure TestVerboseSuccessLogsNeverInterleave;
  end;

function PascalString(const AValue: string): string;
begin
  Result := '''' + StringReplace(AValue, '''', '''''', [rfReplaceAll]) + '''';
end;

constructor TProcessWaitThread.Create(const AProcess: TProcess);
begin
  inherited Create(True);
  FProcess := AProcess;
end;

procedure TProcessWaitThread.Execute;
begin
  FProcess.WaitOnExit;
end;

constructor TBlockingProcess.Create;
begin
  inherited Create(nil);
  InitCriticalSection(FCriticalSection);
end;

destructor TBlockingProcess.Destroy;
begin
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

function TBlockingProcess.Entered: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FEntered;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TBlockingProcess.Execute;
var
  Released: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    FEntered := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
  repeat
    EnterCriticalSection(FCriticalSection);
    try
      Released := FReleased;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    if not Released then Sleep(ProcessPollMilliseconds);
  until Released;
end;

procedure TBlockingProcess.Release;
begin
  EnterCriticalSection(FCriticalSection);
  try
    FReleased := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

constructor TNotifyingProcess.Create;
begin
  inherited Create(nil);
  InitCriticalSection(FCriticalSection);
end;

destructor TNotifyingProcess.Destroy;
begin
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

function TNotifyingProcess.Entered: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FEntered;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TNotifyingProcess.Execute;
begin
  EnterCriticalSection(FCriticalSection);
  try
    FEntered := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
  inherited Execute;
end;

constructor TSpawnThread.Create(const AProcess: TProcess;
  const AProcessTree: TLWPTProcessTree);
begin
  inherited Create(True);
  InitCriticalSection(FCriticalSection);
  FProcess := AProcess;
  FProcessTree := AProcessTree;
end;

destructor TSpawnThread.Destroy;
begin
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

function TSpawnThread.Attempted: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FAttempted;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TSpawnThread.Execute;
begin
  EnterCriticalSection(FCriticalSection);
  try
    FAttempted := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
  try
    if Assigned(FProcessTree) then FProcessTree.Execute
    else ExecuteUnmanagedProcess(FProcess);
  except
    on E: Exception do FErrorMessage := E.Message;
  end;
end;

{$IFDEF UNIX}
function ReadAcknowledgementControlBefore(const AHandle: PtrInt;
  const ADeadline: QWord): Boolean;
var
  Buffer: array[0..511] of Byte;
  BytesRead, ControlFlags, ErrorCode: LongInt;
begin
  Result := False;
  ControlFlags := FpFcntl(AHandle, F_GetFl);
  if (ControlFlags < 0)
     or (FpFcntl(AHandle, F_SetFl,
       ControlFlags or O_NONBLOCK) < 0) then Exit;
  repeat
    BytesRead := FpRead(AHandle, Buffer, SizeOf(Buffer));
    if BytesRead > 0 then Exit(True);
    if BytesRead = 0 then Exit;
    ErrorCode := FpGetErrNo;
    if not (ErrorCode in [ESysEINTR, ESysEAGAIN]) then Exit;
    if GetTickCount64 >= ADeadline then Exit;
    Sleep(ProcessPollMilliseconds);
  until False;
end;
{$ENDIF}

{ Scheduler progress lines print discovered test paths with the native
  separator (tests\A.Test.pas on Windows); normalise so assertions can be
  written with '/' on every platform. }
function SlashNorm(const AOutput: string): string;
begin
  Result := StringReplace(AOutput, '\', '/', [rfReplaceAll]);
end;

function HasProcessArgument(const AValue: string): Boolean;
var
  ArgumentIndex: Integer;
begin
  for ArgumentIndex := 1 to ParamCount do
    if ParamStr(ArgumentIndex) = AValue then Exit(True);
  Result := False;
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
  APIDFile: string; const ABudget: Integer): TLwptResult;
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
  Environment[2] := WORKER_BUDGET_ENV + '=' + IntToStr(ABudget);
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
  DumpRunFailure('silent heartbeat run', RunResult, 0);
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
  DumpRunFailure('quiet output run', RunResult, 0);
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
  DumpRunFailure('verbose output run', RunResult, 0);
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
  DumpRunFailure('default overlap run', CommandResult, 0);
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
  DumpRunFailure('jobs=1 sequential run', CommandResult, 0);
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
  Attempt: Integer;
  CompilerPID: Integer;
  NestedProject, PIDFile: string;
  NaturalExitObserved: Boolean;
  CommandResult: TLwptResult;
begin
  for Attempt := 1 to 8 do
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
    + '    Child.Parameters.Add(''--no-cache'');'#10
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
    + PascalString(ProcessTreeProxyPIDFileEnvironment + '=') + '))'#10
    + '        and (not SameText(Copy(Entry, 1, Length('
    + PascalString(ManagedProcessTreeEnvironment + '=') + ')), '
    + PascalString(ManagedProcessTreeEnvironment + '=') + ')) then'#10
    + '        Child.Environment.Add(Entry);'#10
    + '    end;'#10
    + '    { Delegate the inherited acknowledgement channel to the direct'#10
    + '      child with the parent identity it will validate. }'#10
    + '    Child.Environment.Add('
    + PascalString(ManagedProcessTreeEnvironment + '=')
    + ' + IntToStr(GetProcessID));'#10
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
  NaturalExitObserved := FileExists(
    PIDFile + NestedCompilerNaturalExitSuffix);
  if NaturalExitObserved then
  begin
    WriteLn(ErrOutput, '[DEBUG-50 no-cache] nested compiler reached natural '
      + 'exit on attempt ', Attempt);
    WriteLn(ErrOutput, '[DEBUG-50 no-cache] captured stdout:');
    WriteLn(ErrOutput, CommandResult.Stdout);
    WriteLn(ErrOutput, '[DEBUG-50 no-cache] captured stderr:');
    WriteLn(ErrOutput, CommandResult.Stderr);
  end;
  Expect<Boolean>(NaturalExitObserved).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/control/nested-pending-ran'))
    .ToBe(False);
  Expect<Boolean>(Pos('A.Nested.Test.pas ... cancelled',
    CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('B.Fail.Test.pas ... FAIL (exit 1)',
    CommandResult.Stdout) > 0)
    .ToBe(True);
  end;
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
  { AbortWithError must assign the documented internal failure outcome before
    the reporter accepts the typed terminal event. }
  Expect<Boolean>(Pos('FAIL tests/B.Error.Test.pas (scheduler error;',
    SlashNorm(CommandResult.Stdout)) > 0).ToBe(True);
  Expect<Boolean>(Pos('B.Error.Test.pas ... ERROR', CommandResult.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('scheduler error:', CommandResult.Stderr) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestMissingTerminationAcknowledgementFailsCancellation;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
  Child: TProcess;
  ChildReaped: Boolean;
  ChildTree: TLWPTProcessTree;
  CleanupAbandoned: Boolean;
  CompilerPID: Integer;
  Environment: array of string;
  PIDFile: string;
  Raised: Boolean;
  Started: TDateTime;
  WaitThread: TProcessWaitThread;
  WaitThreadStarted: Boolean;
  {$IFDEF MSWINDOWS}
  ChildProcessHandle: THandle;
  {$ENDIF}

  procedure JoinWaitThreadAfterBoundedExit;
  var
    ExitStarted: TDateTime;
    NativeTerminationAttempted, NativeTerminationSucceeded: Boolean;
  begin
    ExitStarted := Now;
    while ProcessIsRunning(CompilerPID)
      and ((Now - ExitStarted) * SecondsPerDay
        < ProcessExitCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    if ProcessIsRunning(CompilerPID) then
    begin
      try
        ChildTree.Terminate;
      except
        { Native termination below is the cleanup fallback. }
      end;
      NativeTerminationAttempted := False;
      NativeTerminationSucceeded := False;
      if ProcessIsRunning(CompilerPID) then
      begin
        NativeTerminationAttempted := True;
        {$IFDEF UNIX}
        NativeTerminationSucceeded := FpKill(CompilerPID, SIGKILL) = 0;
        {$ENDIF}
        {$IFDEF MSWINDOWS}
        if ChildProcessHandle <> 0 then
          NativeTerminationSucceeded :=
            Windows.TerminateProcess(ChildProcessHandle, 1);
        {$ENDIF}
      end;
      ExitStarted := Now;
      while ProcessIsRunning(CompilerPID)
        and ((Now - ExitStarted) * SecondsPerDay
          < ProcessExitCeilingSeconds) do
        Sleep(ProcessPollMilliseconds);
      if ProcessIsRunning(CompilerPID) then
      begin
        { WaitThread still owns Child, so a bounded test failure must leave
          both objects alive rather than enter an unbounded join or free an
          object that the thread can still access. }
        CleanupAbandoned := True;
        Fail('missing-acknowledgement child remained alive after forced cleanup'
          + ' (native termination attempted: '
          + BoolToStr(NativeTerminationAttempted, True)
          + '; succeeded: '
          + BoolToStr(NativeTerminationSucceeded, True) + ')');
      end;
    end;
    WaitThread.WaitFor;
    ChildReaped := True;
  end;
begin
  PIDFile := FScratch + '/control/missing-acknowledgement-compiler-pid';
  SetLength(Environment, 2);
  Environment[0] := ProcessTreeProxyModeEnvironment + '='
    + MissingAcknowledgementCompilerProxyMode;
  Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + PIDFile;
  Child := TProcess.Create(nil);
  ChildTree := TLWPTProcessTree.Create(Child);
  ChildReaped := False;
  CleanupAbandoned := False;
  CompilerPID := 0;
  WaitThread := nil;
  WaitThreadStarted := False;
  {$IFDEF MSWINDOWS}
  ChildProcessHandle := 0;
  {$ENDIF}
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    Child.Parameters.Add('A.Slow.Test.pas');
    ConfigureProcessEnvironment(Child, Environment);
    ChildTree.Execute;
    Started := Now;
    while (not FileExists(PIDFile)) and Child.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    if not FileExists(PIDFile) then
      Fail('missing-acknowledgement child did not publish its PID');
    CompilerPID := StrToInt(Trim(ReadBinaryFile(PIDFile)));
    {$IFDEF MSWINDOWS}
    ChildProcessHandle := Child.ProcessHandle;
    {$ENDIF}

    WaitThread := TProcessWaitThread.Create(Child);
    WaitThread.Start;
    WaitThreadStarted := True;
    TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
      AcknowledgementDeadline);
    ChildTree.BeginTermination(DescendantDeadline,
      AcknowledgementDeadline);
    Raised := False;
    try
      ChildTree.CompleteTermination;
    except
      on E: EOSError do
        Raised := Pos('termination acknowledgement was not received',
          E.Message) > 0;
    end;
    JoinWaitThreadAfterBoundedExit;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Boolean>(ProcessIsRunning(CompilerPID)).ToBe(False);
  finally
    if not CleanupAbandoned then
    begin
      if WaitThreadStarted and not ChildReaped then
        JoinWaitThreadAfterBoundedExit
      else if Child.Running then Child.Terminate(1);
      WaitThread.Free;
      ChildTree.Free;
      Child.Free;
    end;
  end;
end;

procedure TTestScheduling.TestSuccessfulTerminationAcknowledgementCompletesCancellation;
var
  DescendantPID, OwnerPID: Integer;
  PIDFile: string;
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  PIDFile := FScratch + '/control/successful-acknowledgement-compiler-pid';
  WriteTextFile(FScratch + '/tests/A.Slow.Test.pas',
    'program SlowCompilerInput; begin end.'#10);
  WriteTextFile(FScratch + '/tests/B.Error.Test.pas',
    'program MissingRuntimeBinaryInput; begin end.'#10);

  CommandResult := RunTestsWithCompilerProxy(['--jobs=2'],
    SuccessfulAcknowledgementCompilerProxyMode, PIDFile);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(PIDFile + '-owner')).ToBe(True);
  Expect<Boolean>(FileExists(PIDFile + '-descendant')).ToBe(True);
  OwnerPID := StrToInt(Trim(ReadBinaryFile(PIDFile + '-owner')));
  DescendantPID := StrToInt(Trim(ReadBinaryFile(PIDFile + '-descendant')));
  Expect<Boolean>(ProcessIsRunning(OwnerPID)).ToBe(False);
  Expect<Boolean>(ProcessIsRunning(DescendantPID)).ToBe(False);
  Expect<Boolean>(Pos('process-tree termination failed',
    CommandResult.Stdout) = 0).ToBe(True);
end;

procedure TTestScheduling.TestSuccessfulAcknowledgementHasSeparateReapWindow;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
  Child: TProcess;
  ChildProcessID: Integer;
  ChildTree: TLWPTProcessTree;
  Environment: array of string;
  Marker: string;
  Started: TDateTime;
  TerminationCompleted: Boolean;
  WaitThread: TProcessWaitThread;
  WaitThreadStarted: Boolean;
  {$IFDEF MSWINDOWS}
  ChildProcessHandle: THandle;
  {$ENDIF}
begin
  Marker := FScratch + '/control/delayed-successful-acknowledgement';
  SetLength(Environment, 2);
  Environment[0] := ProcessTreeProxyModeEnvironment + '='
    + SuccessfulAcknowledgementLeafProxyMode;
  Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + Marker;
  Child := TProcess.Create(nil);
  ChildTree := TLWPTProcessTree.Create(Child);
  ChildProcessID := 0;
  TerminationCompleted := False;
  WaitThread := nil;
  WaitThreadStarted := False;
  {$IFDEF MSWINDOWS}
  ChildProcessHandle := 0;
  {$ENDIF}
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    ConfigureProcessEnvironment(Child, Environment);
    ChildTree.Execute;
    ChildProcessID := Child.ProcessID;
    {$IFDEF MSWINDOWS}
    ChildProcessHandle := Child.ProcessHandle;
    {$ENDIF}
    Started := Now;
    while (not FileExists(Marker + '-descendant')) and Child.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(FileExists(Marker + '-descendant')).ToBe(True);

    { Reap the direct child concurrently, as the production runner does. The
      process tree can then distinguish its delayed exit from a live member. }
    WaitThread := TProcessWaitThread.Create(Child);
    WaitThread.Start;
    WaitThreadStarted := True;
    TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
      AcknowledgementDeadline);
    ChildTree.BeginTermination(DescendantDeadline,
      AcknowledgementDeadline);
    ChildTree.CompleteTermination;
    TerminationCompleted := True;
    WaitThread.WaitFor;
    Expect<Integer>(Child.ExitStatus).ToBe(0);
  finally
    if WaitThreadStarted then
    begin
      if not TerminationCompleted then
        try
          ChildTree.Terminate;
        except
          {$IFDEF UNIX}
          if ChildProcessID > 0 then FpKill(ChildProcessID, SIGKILL);
          {$ENDIF}
          {$IFDEF MSWINDOWS}
          if ChildProcessHandle <> 0 then
            Windows.TerminateProcess(ChildProcessHandle, 1);
          {$ENDIF}
        end;
      WaitThread.WaitFor;
      WaitThread.Free;
      WaitThread := nil;
    end
    else
    begin
      WaitThread.Free;
      WaitThread := nil;
      if Child.Running then Child.Terminate(1);
    end;
    ChildTree.Free;
    Child.Free;
  end;
end;

procedure TTestScheduling.TestManagedAndUnmanagedSpawnsShareCriticalSection;
var
  Blocker: TBlockingProcess;
  BlockerThread, ManagedThread: TSpawnThread;
  Environment: array of string;
  ManagedProcess: TNotifyingProcess;
  ManagedTree: TLWPTProcessTree;
  Marker: string;
  Started: TDateTime;
  BlockerThreadStarted, ManagedThreadStarted: Boolean;
begin
  Marker := FScratch + '/control/serialized-managed-spawn';
  Blocker := TBlockingProcess.Create;
  ManagedProcess := TNotifyingProcess.Create;
  ManagedTree := TLWPTProcessTree.Create(ManagedProcess);
  BlockerThread := TSpawnThread.Create(Blocker, nil);
  ManagedThread := TSpawnThread.Create(ManagedProcess, ManagedTree);
  BlockerThreadStarted := False;
  ManagedThreadStarted := False;
  try
    SetLength(Environment, 2);
    Environment[0] := ProcessTreeProxyModeEnvironment + '='
      + CleanAcknowledgementExitProxyMode;
    Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + Marker;
    ManagedProcess.Executable := ExpandFileName(ParamStr(0));
    ConfigureProcessEnvironment(ManagedProcess, Environment);

    BlockerThread.Start;
    BlockerThreadStarted := True;
    Started := Now;
    while (not Blocker.Entered)
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(Blocker.Entered).ToBe(True);
    ManagedThread.Start;
    ManagedThreadStarted := True;
    Started := Now;
    while (not ManagedThread.Attempted)
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(ManagedThread.Attempted).ToBe(True);
    Expect<Boolean>(ManagedProcess.Entered).ToBe(False);

    Blocker.Release;
    BlockerThread.WaitFor;
    ManagedThread.WaitFor;
    Expect<string>(BlockerThread.ErrorMessage).ToBe('');
    Expect<string>(ManagedThread.ErrorMessage).ToBe('');
    Expect<Boolean>(ManagedProcess.Entered).ToBe(True);
    ManagedProcess.WaitOnExit;
    Expect<Boolean>(FileExists(Marker)).ToBe(True);
  finally
    Blocker.Release;
    if BlockerThreadStarted then BlockerThread.WaitFor;
    if ManagedThreadStarted then ManagedThread.WaitFor;
    if ManagedThreadStarted and ManagedProcess.Running then
      ManagedProcess.Terminate(1);
    BlockerThread.Free;
    ManagedThread.Free;
    ManagedTree.Free;
    ManagedProcess.Free;
    Blocker.Free;
  end;
end;

procedure TTestScheduling.TestExitedRegisteredProcessTreeIsSuccessfulNoOp;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
  Child: TProcess;
  ChildTree: TLWPTProcessTree;
  Environment: array of string;
  Marker: string;
  Started: TDateTime;
begin
  Marker := FScratch + '/control/clean-acknowledgement-exit';
  SetLength(Environment, 2);
  Environment[0] := ProcessTreeProxyModeEnvironment + '='
    + CleanAcknowledgementExitProxyMode;
  Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + Marker;
  Child := TProcess.Create(nil);
  ChildTree := TLWPTProcessTree.Create(Child);
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    ConfigureProcessEnvironment(Child, Environment);
    ChildTree.Execute;
    Started := Now;
    while Child.Running and ((Now - Started) * SecondsPerDay
      < ProcessExitCeilingSeconds) do Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(Child.Running).ToBe(False);
    Child.WaitOnExit;
    Expect<Integer>(Child.ExitStatus).ToBe(0);
    Expect<Boolean>(FileExists(Marker)).ToBe(True);

    TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
      AcknowledgementDeadline);
    ChildTree.BeginTermination(DescendantDeadline,
      AcknowledgementDeadline);
    ChildTree.CompleteTermination;
  finally
    if Child.Running then Child.Terminate(1);
    ChildTree.Free;
    Child.Free;
  end;
end;

procedure TTestScheduling.TestFailedNestedTerminationAcknowledgementFailsCancellation;
var
  DescendantPID, OwnerPID: Integer;
  PIDFile: string;
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  PIDFile := FScratch + '/control/failed-acknowledgement-compiler-pid';
  WriteTextFile(FScratch + '/tests/A.Slow.Test.pas',
    'program SlowCompilerInput; begin end.'#10);
  WriteTextFile(FScratch + '/tests/B.Error.Test.pas',
    'program MissingRuntimeBinaryInput; begin end.'#10);

  CommandResult := RunTestsWithCompilerProxy(['--jobs=2'],
    FailedAcknowledgementCompilerProxyMode, PIDFile);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(PIDFile + '-owner')).ToBe(True);
  Expect<Boolean>(FileExists(PIDFile + '-descendant')).ToBe(True);
  OwnerPID := StrToInt(Trim(ReadBinaryFile(PIDFile + '-owner')));
  DescendantPID := StrToInt(Trim(ReadBinaryFile(PIDFile + '-descendant')));
  Expect<Boolean>(ProcessIsRunning(OwnerPID)).ToBe(False);
  Expect<Boolean>(ProcessIsRunning(DescendantPID)).ToBe(False);
  Expect<Boolean>(Pos('nested process reported failed process-tree '
    + 'termination', CommandResult.Stdout) > 0).ToBe(True);
end;

procedure TTestScheduling.TestSiblingTerminationAcknowledgementsShareFanout;
var
  CompilerPID, SourceIndex: Integer;
  CancellationStartedAt, ElapsedMilliseconds: QWord;
  PIDFile: string;
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  PIDFile := FScratch + '/control/sibling-ack-compiler-pid';
  WriteTextFile(FScratch + '/tests/B.Error.Test.pas',
    'program MissingRuntimeBinaryInput; begin end.'#10);
  for SourceIndex := Low(SiblingSlowSources) to High(SiblingSlowSources) do
    WriteTextFile(FScratch + '/tests/' + SiblingSlowSources[SourceIndex],
      'program SlowCompilerInput; begin end.'#10);

  CommandResult := RunTestsWithCompilerProxy(['--jobs=7'],
    MissingAcknowledgementSiblingCompilerProxyMode, PIDFile, 7);
  Expect<Boolean>(FileExists(PIDFile + SiblingCancellationStartedSuffix))
    .ToBe(True);
  CancellationStartedAt := StrToQWord(Trim(ReadBinaryFile(PIDFile
    + SiblingCancellationStartedSuffix)));
  ElapsedMilliseconds := GetTickCount64 - CancellationStartedAt;
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  for SourceIndex := Low(SiblingSlowSources) to High(SiblingSlowSources) do
  begin
    Expect<Boolean>(FileExists(PIDFile + '-'
      + SiblingSlowSources[SourceIndex])).ToBe(True);
    CompilerPID := StrToInt(Trim(ReadBinaryFile(PIDFile + '-'
      + SiblingSlowSources[SourceIndex])));
    Expect<Boolean>(ProcessIsRunning(CompilerPID)).ToBe(False);
  end;
  Expect<Boolean>(Pos('A.Slow.Test.pas ... ERROR',
    CommandResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('C.Slow.Test.pas ... ERROR',
    CommandResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(ElapsedMilliseconds < SiblingFanoutCeilingMilliseconds)
    .ToBe(True);
end;

procedure TTestScheduling.TestProtocolFramingIsBoundedAndIncremental;
var
  Buffer, Line: string;
begin
  Buffer := '';
  Expect<TLWPTProtocolReadResult>(FeedProcessTreeProtocol(Buffer,
    ProcessTreeAcknowledgementProtocol + ' token ', Line)).ToBe(prrPending);
  Expect<TLWPTProtocolReadResult>(FeedProcessTreeProtocol(Buffer,
    'CANCEL 100 250'#10'TRAILING'#10, Line)).ToBe(prrFrame);
  Expect<string>(Line).ToBe(ProcessTreeAcknowledgementProtocol
    + ' token CANCEL 100 250');
  Expect<TLWPTProtocolReadResult>(FeedProcessTreeProtocol(Buffer, '', Line))
    .ToBe(prrFrame);
  Expect<string>(Line).ToBe('TRAILING');
  Expect<TLWPTProtocolReadResult>(FeedProcessTreeProtocol(Buffer,
    StringOfChar('x', 4097), Line)).ToBe(prrRejected);
  Expect<string>(Buffer).ToBe('');
end;

procedure TTestScheduling.TestProcessFailureSurvivesDelegationCleanupFailure;
var
  CommandResult: TLwptResult;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.OutputLimit.Test.pas',
      'program OutputLimitFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var BlockedTmp, OutputChunk: string;'#10
    + '  Remaining, Written: Integer;'#10
    + 'begin'#10
    + '  BlockedTmp := IncludeTrailingPathDelimiter(GetEnvironmentVariable('
    + PascalString(WORKER_STATE_DIR_ENV) + ')) + ''tmp'';'#10
    + '  if DirectoryExists(BlockedTmp) and not RemoveDir(BlockedTmp) then'
    + ' Halt(2);'#10
    + '  TFileStream.Create(BlockedTmp, fmCreate).Free;'#10
    + '  OutputChunk := StringOfChar(''x'', 64 * 1024);'#10
    + '  Remaining := ' + IntToStr(ProcessCaptureOverflowBytes) + ';'#10
    + '  while Remaining > 0 do begin'#10
    + '    Written := Length(OutputChunk);'#10
    + '    if Written > Remaining then Written := Remaining;'#10
    + '    Written := FileWrite(StdOutputHandle, OutputChunk[1], Written);'#10
    + '    if Written <= 0 then Halt(3);'#10
    + '    Dec(Remaining, Written);'#10
    + '  end;'#10
    + '  Sleep(' + IntToStr(ProcessCaptureOverflowHoldMilliseconds) + ');'#10
    + 'end.'#10);

  CommandResult := RunTests(['--jobs=1', '--bail=0']);
  if (CommandResult.ExitCode <> 1)
     or (Pos('standard output exceeded its 16777216-byte capture limit',
       CommandResult.Stderr) = 0)
     or (Pos('Unable to create file', CommandResult.Stderr) > 0) then
    Fail('delegation-cleanup failure evidence:' + LineEnding
      + 'stdout:' + LineEnding + CommandResult.Stdout + LineEnding
      + 'stderr:' + LineEnding + CommandResult.Stderr);
  Expect<Integer>(CommandResult.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('standard output exceeded its 16777216-byte capture '
    + 'limit', CommandResult.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('Unable to create file', CommandResult.Stderr) = 0)
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

procedure TTestScheduling.TestInheritedChannelRejectsRegularFiles;
const
  ChannelToken = '0123456789abcdef0123456789abcdef';
var
  ChannelFile: TFileStream;
  Child: TProcess;
  Environment: array of string;
  Marker: string;
  Started: TDateTime;
begin
  Marker := FScratch + '/control/regular-channel-probe';
  ChannelFile := TFileStream.Create(Marker + '.channel', fmCreate);
  Child := TProcess.Create(nil);
  try
    SetLength(Environment, 6);
    Environment[0] := ProcessTreeProxyModeEnvironment + '='
      + InheritedChannelProbeProxyMode;
    Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + Marker;
    Environment[2] := ManagedProcessTreeEnvironment + '='
      + IntToStr(GetProcessID);
    Environment[3] := ProcessTreeStatusHandleEnvironment + '='
      + IntToStr(ChannelFile.Handle);
    Environment[4] := ProcessTreeControlHandleEnvironment + '='
      + IntToStr(ChannelFile.Handle);
    Environment[5] := ProcessTreeChannelTokenEnvironment + '=' + ChannelToken;
    Child.Executable := ExpandFileName(ParamStr(0));
    ConfigureProcessEnvironment(Child, Environment);
    Child.Execute;
    Started := Now;
    while (not FileExists(Marker)) and Child.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(FileExists(Marker)).ToBe(True);
    Expect<Int64>(ChannelFile.Size).ToBe(0);
  finally
    if Child.Running then Child.Terminate(1);
    Child.WaitOnExit;
    Child.Free;
    ChannelFile.Free;
  end;
end;

procedure TTestScheduling.TestInheritedChannelRejectsWrongPipeDirection;
const
  ChannelToken = '0123456789abcdef0123456789abcdef';
var
  Buffer: array[0..255] of Byte;
  BytesRead, OpenFlags: LongInt;
  Child: TProcess;
  ControlPipe, StatusPipe: TFilDes;
  Environment: array of string;
  Marker: string;
  Started: TDateTime;
begin
  StatusPipe[0] := -1;
  StatusPipe[1] := -1;
  ControlPipe[0] := -1;
  ControlPipe[1] := -1;
  Child := TProcess.Create(nil);
  try
    if FpPipe(StatusPipe) <> 0 then RaiseLastOSError;
    if FpPipe(ControlPipe) <> 0 then RaiseLastOSError;
    Marker := FScratch + '/control/direction-channel-probe';
    SetLength(Environment, 6);
    Environment[0] := ProcessTreeProxyModeEnvironment + '='
      + InheritedChannelProbeProxyMode;
    Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + Marker;
    Environment[2] := ManagedProcessTreeEnvironment + '='
      + IntToStr(GetProcessID);
    Environment[3] := ProcessTreeStatusHandleEnvironment + '='
      + IntToStr(StatusPipe[1]);
    { The status end is valid, but a control write end cannot receive CANCEL. }
    Environment[4] := ProcessTreeControlHandleEnvironment + '='
      + IntToStr(ControlPipe[1]);
    Environment[5] := ProcessTreeChannelTokenEnvironment + '=' + ChannelToken;
    Child.Executable := ExpandFileName(ParamStr(0));
    ConfigureProcessEnvironment(Child, Environment);
    Child.Execute;
    Started := Now;
    while (not FileExists(Marker)) and Child.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(FileExists(Marker)).ToBe(True);
    OpenFlags := FpFcntl(StatusPipe[0], F_GetFl);
    if (OpenFlags < 0)
       or (FpFcntl(StatusPipe[0], F_SetFl,
         OpenFlags or O_NONBLOCK) < 0) then RaiseLastOSError;
    BytesRead := FpRead(StatusPipe[0], Buffer, SizeOf(Buffer));
    Expect<Boolean>(BytesRead <= 0).ToBe(True);
  finally
    if Child.Running then Child.Terminate(1);
    Child.WaitOnExit;
    Child.Free;
    if StatusPipe[0] >= 0 then FpClose(StatusPipe[0]);
    if StatusPipe[1] >= 0 then FpClose(StatusPipe[1]);
    if ControlPipe[0] >= 0 then FpClose(ControlPipe[0]);
    if ControlPipe[1] >= 0 then FpClose(ControlPipe[1]);
  end;
end;

procedure TTestScheduling.TestAcknowledgementControlReadIsBounded;
var
  ByteValue: Byte;
  ControlPipe: TFilDes;
  StartedAt: QWord;
begin
  ControlPipe[0] := -1;
  ControlPipe[1] := -1;
  try
    if FpPipe(ControlPipe) <> 0 then RaiseLastOSError;
    FpClose(ControlPipe[1]);
    ControlPipe[1] := -1;
    StartedAt := GetTickCount64;
    Expect<Boolean>(ReadAcknowledgementControlBefore(ControlPipe[0],
      StartedAt + 50)).ToBe(False);
    Expect<Boolean>(GetTickCount64 - StartedAt < 500).ToBe(True);
    FpClose(ControlPipe[0]);
    ControlPipe[0] := -1;

    if FpPipe(ControlPipe) <> 0 then RaiseLastOSError;
    StartedAt := GetTickCount64;
    Expect<Boolean>(ReadAcknowledgementControlBefore(ControlPipe[0],
      StartedAt + 50)).ToBe(False);
    Expect<Boolean>(GetTickCount64 - StartedAt < 500).ToBe(True);

    ByteValue := 1;
    Expect<Int64>(FpWrite(ControlPipe[1], ByteValue,
      SizeOf(ByteValue))).ToBe(SizeOf(ByteValue));
    Expect<Boolean>(ReadAcknowledgementControlBefore(ControlPipe[0],
      GetTickCount64 + 50)).ToBe(True);
  finally
    if ControlPipe[0] >= 0 then FpClose(ControlPipe[0]);
    if ControlPipe[1] >= 0 then FpClose(ControlPipe[1]);
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function TryReadWindowsProcessID(const APath: string;
  out APID: Integer): Boolean;
var
  CandidatePID: Integer;
begin
  APID := -1;
  Result := False;
  try
    if not FileExists(APath) then Exit;
    if not TryStrToInt(Trim(ReadBinaryFile(APath)), CandidatePID) then Exit;
    APID := CandidatePID;
    Result := True;
  except
    { Cleanup is best-effort; the owning Job Object remains authoritative. }
    APID := -1;
  end;
end;

procedure TerminateWindowsProcess(const APID: Integer);
var
  ProcessHandle: THandle;
begin
  if not ProcessIsRunning(APID) then Exit;
  ProcessHandle := Windows.OpenProcess(Windows.PROCESS_TERMINATE, False,
    DWORD(APID));
  if ProcessHandle = 0 then Exit;
  try
    Windows.TerminateProcess(ProcessHandle, 1);
  finally
    Windows.CloseHandle(ProcessHandle);
  end;
end;

function IgnoreWindowsConsoleControl(AControlType: DWORD): BOOL; stdcall;
begin
  Result := (AControlType = Windows.CTRL_C_EVENT)
    or (AControlType = Windows.CTRL_BREAK_EVENT);
end;

procedure TTestScheduling.RunWindowsConsoleForwardingTest(
  const AControlType: DWORD; const AProjectName: string);
var
  CompilerPID: Integer;
  Controller: TProcess;
  ControllerTree: TLWPTProcessTree;
  PIDFile, ProjectRoot: string;
  Started: TDateTime;
begin
  CompilerPID := -1;
  ProjectRoot := FScratch + '/' + AProjectName;
  PIDFile := FScratch + '/control/' + AProjectName + '-compiler-pid';
  WriteBuildProject(ProjectRoot);
  Controller := TProcess.Create(nil);
  ControllerTree := nil;
  try
    ControllerTree := TLWPTProcessTree.Create(Controller);
    Controller.Executable := ExpandFileName(ParamStr(0));
    Controller.Parameters.Add(WindowsConsoleControllerOption);
    Controller.Parameters.Add(IntToStr(AControlType));
    Controller.Parameters.Add(LwptBinaryPath);
    Controller.Parameters.Add(ProjectRoot);
    Controller.Parameters.Add(PIDFile);
    Controller.Parameters.Add(FScratch + '/' + AProjectName + '-worker-state');
    Controller.Options := [poNewConsole];
    ControllerTree.Execute;
    Started := Now;
    while Controller.Running
      and ((Now - Started) * SecondsPerDay
        < WindowsControllerCompletionCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(Controller.Running).ToBe(False);
    Controller.WaitOnExit;
    Expect<Integer>(Controller.ExitStatus).ToBe(0);
    Expect<Boolean>(FileExists(PIDFile)).ToBe(True);
    CompilerPID := StrToInt(Trim(ReadBinaryFile(PIDFile)));
    Expect<Boolean>(ProcessIsRunning(CompilerPID)).ToBe(False);
  finally
    if CompilerPID < 0 then
      TryReadWindowsProcessID(PIDFile, CompilerPID);
    try
      if Assigned(ControllerTree) then ControllerTree.Terminate;
    finally
      TerminateWindowsProcess(CompilerPID);
      ControllerTree.Free;
      Controller.Free;
    end;
  end;
end;

procedure TTestScheduling.TestCtrlCTerminatesActiveProcessTree;
begin
  RunWindowsConsoleForwardingTest(Windows.CTRL_C_EVENT, 'console-control-c');
end;

procedure TTestScheduling.TestCtrlBreakTerminatesActiveProcessTree;
begin
  RunWindowsConsoleForwardingTest(Windows.CTRL_BREAK_EVENT,
    'console-control-break');
end;

function RunWindowsConsoleController: Integer;
var
  CompilerPID: Integer;
  ControlType: DWORD;
  Environment: array of string;
  LwptProcess: TProcess;
  WrongReadHandle, WrongWriteHandle: THandle;
  SecurityAttributes: Windows.TSecurityAttributes;
  Started: TDateTime;
begin
  Result := 1;
  CompilerPID := -1;
  WrongReadHandle := 0;
  WrongWriteHandle := 0;
  { Controller failures: 2 invalid control type; 3 missing compiler PID;
    4 acknowledgement pipe creation; 5 inherited Ctrl-C-ignore setup;
    6 controller ignore handler; 7 control broadcast; 8 LWPT exit timeout;
    9 unexpected LWPT exit status; 10 compiler process still active. }
  ControlType := DWORD(StrToInt(ParamStr(2)));
  if (ControlType <> Windows.CTRL_C_EVENT)
     and (ControlType <> Windows.CTRL_BREAK_EVENT) then Exit(2);
  SetLength(Environment, 10);
  Environment[0] := WORKER_LEASE_TOKEN_ENV + '=';
  Environment[1] := WORKER_STATE_DIR_ENV + '=' + ParamStr(6);
  Environment[2] := WORKER_BUDGET_ENV + '=1';
  Environment[3] := CompilerExecutableEnvironment + '='
    + ExpandFileName(ParamStr(0));
  Environment[4] := ProcessTreeProxyModeEnvironment + '='
    + WindowsIgnoreControlCompilerProxyMode;
  Environment[5] := ProcessTreeProxyPIDFileEnvironment + '=' + ParamStr(5);
  FillChar(SecurityAttributes, SizeOf(SecurityAttributes), 0);
  SecurityAttributes.nLength := SizeOf(SecurityAttributes);
  SecurityAttributes.bInheritHandle := True;
  if not Windows.CreatePipe(WrongReadHandle, WrongWriteHandle,
    @SecurityAttributes, 4096) then Exit(4);
  { Both handles are valid, inheritable pipes, but their directions are
    deliberately reversed. LWPT must reject them and use console fallback. }
  Environment[6] := ProcessTreeStatusHandleEnvironment + '='
    + IntToStr(PtrInt(WrongReadHandle));
  Environment[7] := ProcessTreeControlHandleEnvironment + '='
    + IntToStr(PtrInt(WrongWriteHandle));
  Environment[8] := ProcessTreeChannelTokenEnvironment
    + '=0123456789abcdef0123456789abcdef';
  Environment[9] := ManagedProcessTreeEnvironment + '='
    + IntToStr(GetProcessID);
  LwptProcess := TProcess.Create(nil);
  try
    { Pin the inherited Ctrl-C-ignore case explicitly. Production LWPT must
      restore Ctrl-C delivery before installing its forwarding handler. }
    if not Windows.SetConsoleCtrlHandler(nil, True) then Exit(5);
    LwptProcess.Executable := ParamStr(3);
    LwptProcess.Parameters.Add('build');
    LwptProcess.CurrentDirectory := ParamStr(4);
    ConfigureProcessEnvironment(LwptProcess, Environment);
    LwptProcess.InheritHandles := True;
    LwptProcess.Execute;
    Windows.CloseHandle(WrongReadHandle);
    WrongReadHandle := 0;
    Windows.CloseHandle(WrongWriteHandle);
    WrongWriteHandle := 0;
    Started := Now;
    while (not FileExists(ParamStr(5))) and LwptProcess.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    if not FileExists(ParamStr(5)) then Exit(3);
    CompilerPID := StrToInt(Trim(ReadBinaryFile(ParamStr(5))));
    { SetConsoleCtrlHandler(nil, True) already makes this controller ignore
      Ctrl-C. Register the Pascal callback only for Ctrl-Break, which ignores
      that inherited flag; avoiding a redundant operating-system callback
      keeps the Ctrl-C controller on its single main-thread fixture path. The
      compiler proxy installs its handler before publishing its PID, leaving
      LWPT as the only process that performs cancellation. }
    if (ControlType = Windows.CTRL_BREAK_EVENT)
       and not Windows.SetConsoleCtrlHandler(@IgnoreWindowsConsoleControl,
         True) then Exit(6);
    if not Windows.GenerateConsoleCtrlEvent(ControlType, 0) then Exit(7);
    Started := Now;
    while LwptProcess.Running
      and ((Now - Started) * SecondsPerDay < ProcessExitCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    if LwptProcess.Running then Exit(8);
    LwptProcess.WaitOnExit;
    if DWORD(LwptProcess.ExitStatus) <> WindowsControlExitCode then Exit(9);
    if ProcessIsRunning(CompilerPID) then Exit(10);
    Result := 0;
  finally
    if LwptProcess.Running then LwptProcess.Terminate(1);
    TerminateWindowsProcess(CompilerPID);
    if WrongReadHandle <> 0 then Windows.CloseHandle(WrongReadHandle);
    if WrongWriteHandle <> 0 then Windows.CloseHandle(WrongWriteHandle);
    LwptProcess.Free;
  end;
end;
{$ENDIF}

function RunAcknowledgementLeaf(const AMode, APIDFile: string): Integer;
var
  ChannelToken, ControlHandleText, Frame, StatusHandleText: string;
  ControlHandle, StatusHandle: PtrInt;
  {$IFDEF MSWINDOWS}
  Buffer: array[0..511] of Byte;
  BytesRead, BytesWritten: DWORD;
  {$ENDIF}
begin
  StatusHandleText := GetEnvironmentVariable(
    ProcessTreeStatusHandleEnvironment);
  ControlHandleText := GetEnvironmentVariable(
    ProcessTreeControlHandleEnvironment);
  ChannelToken := GetEnvironmentVariable(
    ProcessTreeChannelTokenEnvironment);
  StatusHandle := StrToInt64(StatusHandleText);
  ControlHandle := StrToInt64(ControlHandleText);
  Frame := ProcessTreeAcknowledgementProtocol + ' ' + ChannelToken
    + ' HELLO' + LineEnding;
  {$IFDEF UNIX}
  FpSignal(SIGTERM, SignalHandler(SIG_IGN));
  if FpWrite(StatusHandle, Frame[1], Length(Frame)) <> Length(Frame) then
    Exit(2);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  BytesWritten := 0;
  if not Windows.WriteFile(THandle(StatusHandle), Frame[1], Length(Frame),
    BytesWritten, nil) or (BytesWritten <> DWORD(Length(Frame))) then
    Exit(2);
  {$ENDIF}
  if AMode = CleanAcknowledgementExitProxyMode then
  begin
    { This fixture needs only to register before a clean exit. Starting the
      production forwarding threads here races immediate process shutdown on
      Win32 and is unrelated to the already-empty Job Object contract. }
    WriteTextFile(APIDFile, IntToStr(GetProcessID));
    Exit(0);
  end;
  WriteTextFile(APIDFile + '-descendant', IntToStr(GetProcessID));
  {$IFDEF UNIX}
  if not ReadAcknowledgementControlBefore(ControlHandle,
    GetTickCount64 + QWord(ProcessExitCeilingSeconds) * 1000) then Exit(3);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  BytesRead := 0;
  if not Windows.ReadFile(THandle(ControlHandle), Buffer[0], SizeOf(Buffer),
    BytesRead, nil) or (BytesRead = 0) then Exit(3);
  {$ENDIF}
  if (AMode = SuccessfulAcknowledgementLeafProxyMode)
     or (AMode = ImmediateAcknowledgementLeafProxyMode) then
    Frame := ProcessTreeAcknowledgementProtocol + ' ' + ChannelToken
      + ' REAPED' + LineEnding
  else
    Frame := ProcessTreeAcknowledgementProtocol + ' ' + ChannelToken
      + ' FAILED' + LineEnding;
  {$IFDEF UNIX}
  if FpWrite(StatusHandle, Frame[1], Length(Frame)) <> Length(Frame) then
    Exit(4);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  BytesWritten := 0;
  if not Windows.WriteFile(THandle(StatusHandle), Frame[1], Length(Frame),
    BytesWritten, nil) or (BytesWritten <> DWORD(Length(Frame))) then
    Exit(4);
  {$ENDIF}
  if AMode = SuccessfulAcknowledgementLeafProxyMode then
  begin
    { A successful terminal frame precedes process exit. Keep the leaf alive
      past the acknowledgement deadline to pin the separate final reap window. }
    Sleep(AcknowledgementSuccessExitDelayMilliseconds);
  end
  else if AMode <> ImmediateAcknowledgementLeafProxyMode then
    Exit(1);
  Result := 0;
end;

procedure CloseInheritedStatusHandle;
var
  StatusHandleText: string;
begin
  StatusHandleText := GetEnvironmentVariable(
    ProcessTreeStatusHandleEnvironment);
  if StatusHandleText <> '' then
  begin
    {$IFDEF UNIX}
    FpClose(StrToInt(StatusHandleText));
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Windows.CloseHandle(THandle(StrToInt64(StatusHandleText)));
    {$ENDIF}
  end;
end;

function RunAcknowledgementOwner(const AMode, APIDFile: string): Integer;
var
  Child: TProcess;
  ChildTree: TLWPTProcessTree;
  Environment: array of string;
  Started: TDateTime;
begin
  Result := 1;
  InstallProcessTreeSignalForwarding;
  SetLength(Environment, 2);
  if AMode = SuccessfulAcknowledgementCompilerProxyMode then
    Environment[0] := ProcessTreeProxyModeEnvironment + '='
      + ImmediateAcknowledgementLeafProxyMode
  else
    Environment[0] := ProcessTreeProxyModeEnvironment + '='
      + FailedAcknowledgementLeafProxyMode;
  Environment[1] := ProcessTreeProxyPIDFileEnvironment + '=' + APIDFile;
  Child := TProcess.Create(nil);
  ChildTree := TLWPTProcessTree.Create(Child);
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    ConfigureProcessEnvironment(Child, Environment);
    ChildTree.Execute;
    Started := Now;
    while (not FileExists(APIDFile + '-descendant')) and Child.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    if not FileExists(APIDFile + '-descendant') then Exit(2);
    WriteTextFile(APIDFile + '-owner', IntToStr(GetProcessID));
    while Child.Running do Sleep(ProcessPollMilliseconds);
    Child.WaitOnExit;
    { The forwarding thread owns the cancellation decision, while this main
      thread reaps the fixture child so Unix process-group membership can
      become empty before the inherited absolute deadline. }
    Sleep(LongRunningFixtureMilliseconds);
    Result := 0;
  finally
    if Child.Running then
      try
        ChildTree.Terminate;
      except
        Child.Terminate(1);
      end;
    ChildTree.Free;
    Child.Free;
  end;
end;

function SiblingAcknowledgementMarkersReady(const APIDFile: string): Boolean;
var
  SourceIndex: Integer;
begin
  for SourceIndex := Low(SiblingSlowSources) to High(SiblingSlowSources) do
    if not FileExists(APIDFile + '-'
      + SiblingSlowSources[SourceIndex]) then
      Exit(False);
  Result := True;
end;

function WaitForSiblingAcknowledgementMarkers(
  const APIDFile: string): Boolean;
var
  Started: TDateTime;
begin
  Started := Now;
  while not SiblingAcknowledgementMarkersReady(APIDFile)
    and ((Now - Started) * SecondsPerDay
      < SiblingStartupBarrierCeilingSeconds) do
    Sleep(ProcessPollMilliseconds);
  Result := SiblingAcknowledgementMarkersReady(APIDFile);
end;

function RunProcessTreeCompilerProxy: Integer;
var
  Mode, PIDFile, SiblingPIDFile, SourceFile: string;
  Started: TDateTime;
begin
  if HasProcessArgument('-iV') and HasProcessArgument('-iTO')
     and HasProcessArgument('-iTP') then
  begin
    WriteLn('3.2.2 ', GetBuildOS, ' ', GetBuildArch);
    Exit(0);
  end;
  Mode := GetEnvironmentVariable(ProcessTreeProxyModeEnvironment);
  PIDFile := GetEnvironmentVariable(ProcessTreeProxyPIDFileEnvironment);
  if ParamCount > 0 then SourceFile := ExtractFileName(ParamStr(ParamCount))
  else SourceFile := '';

  if (Mode = SuccessfulAcknowledgementLeafProxyMode)
     or (Mode = ImmediateAcknowledgementLeafProxyMode)
     or (Mode = FailedAcknowledgementLeafProxyMode)
     or (Mode = CleanAcknowledgementExitProxyMode) then
    Exit(RunAcknowledgementLeaf(Mode, PIDFile));
  if Mode = InheritedChannelProbeProxyMode then
  begin
    InstallProcessTreeSignalForwarding;
    WriteTextFile(PIDFile, IntToStr(GetProcessID));
    Sleep(LongRunningFixtureMilliseconds);
    Exit(0);
  end;
  if ((Mode = SuccessfulAcknowledgementCompilerProxyMode)
      or (Mode = FailedAcknowledgementCompilerProxyMode))
     and SameText(SourceFile, 'A.Slow.Test.pas') then
    Exit(RunAcknowledgementOwner(Mode, PIDFile));
  if (Mode = SuccessfulAcknowledgementCompilerProxyMode)
     or (Mode = FailedAcknowledgementCompilerProxyMode) then
  begin
    Started := Now;
    while ((not FileExists(PIDFile + '-owner'))
      or (not FileExists(PIDFile + '-descendant')))
      and ((Now - Started) * SecondsPerDay
        < MarkerWaitCeilingSeconds) do
      Sleep(ProcessPollMilliseconds);
    Exit(0);
  end;

  {$IFDEF UNIX}
  if Mode = IgnoreTerminateCompilerProxyMode then
    FpSignal(SIGTERM, SignalHandler(SIG_IGN));
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if Mode = WindowsIgnoreControlCompilerProxyMode then
    if not Windows.SetConsoleCtrlHandler(@IgnoreWindowsConsoleControl,
      True) then Exit(2);
  {$ENDIF}
  if (Mode = MissingAcknowledgementCompilerProxyMode)
     or (Mode = MissingAcknowledgementSiblingCompilerProxyMode) then
  begin
    InstallProcessTreeSignalForwarding;
    CloseInheritedStatusHandle;
  end;
  if (Mode = SlowCompilerProxyMode)
     or (Mode = IgnoreTerminateCompilerProxyMode)
     or ((Mode = MissingAcknowledgementCompilerProxyMode)
       and SameText(SourceFile, 'A.Slow.Test.pas'))
     or ((Mode = MissingAcknowledgementSiblingCompilerProxyMode)
       and not SameText(SourceFile, 'B.Error.Test.pas'))
     {$IFDEF MSWINDOWS}
     or (Mode = WindowsIgnoreControlCompilerProxyMode)
     {$ENDIF}
     or ((Mode = WorkerErrorCompilerProxyMode)
       and SameText(SourceFile, 'A.Slow.Test.pas')) then
  begin
    if Mode = MissingAcknowledgementSiblingCompilerProxyMode then
    begin
      SiblingPIDFile := PIDFile;
      PIDFile := SiblingPIDFile + '-' + SourceFile;
    end;
    WriteTextFile(PIDFile, IntToStr(GetProcessID));
    if Mode = MissingAcknowledgementSiblingCompilerProxyMode then
    begin
      { Start the safety lifetime only after every sibling reaches the
        fixture barrier, so process-startup skew cannot trigger the failure. }
      if not WaitForSiblingAcknowledgementMarkers(SiblingPIDFile) then
      begin
        WriteLn(StdErr, 'sibling compiler startup barrier timed out');
        Exit(2);
      end;
    end;
    Sleep(LongRunningFixtureMilliseconds);
    if Mode = IgnoreTerminateCompilerProxyMode then
      { Reaching the safety exit means cancellation failed to reap the proxy. }
      WriteTextFile(PIDFile + NestedCompilerNaturalExitSuffix,
        UIntToStr(GetTickCount64));
    Exit(0);
  end;

  if (Mode = WorkerErrorCompilerProxyMode)
     or (Mode = MissingAcknowledgementCompilerProxyMode)
     or (Mode = MissingAcknowledgementSiblingCompilerProxyMode) then
  begin
    { Returning compiler success without creating B.Error's binary makes its
      runtime TProcess.Execute raise, driving AbortWithError while A is live. }
    Started := Now;
    if Mode = MissingAcknowledgementSiblingCompilerProxyMode then
    begin
      if not WaitForSiblingAcknowledgementMarkers(PIDFile) then
      begin
        WriteLn(StdErr, 'sibling compiler startup barrier timed out');
        Exit(2);
      end;
      WriteTextFile(PIDFile + SiblingCancellationStartedSuffix,
        UIntToStr(GetTickCount64));
    end
    else
      while not FileExists(PIDFile)
        and ((Now - Started) * SecondsPerDay
          < MarkerWaitCeilingSeconds) do
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
  Test('worker error terminates another active process tree',
    TestWorkerErrorTerminatesActiveProcessTree);
  Test('successful nested termination acknowledgement completes cancellation',
    TestSuccessfulTerminationAcknowledgementCompletesCancellation);
  Test('successful acknowledgement has a separate final reap window',
    TestSuccessfulAcknowledgementHasSeparateReapWindow);
  Test('managed and unmanaged spawns share one critical section',
    TestManagedAndUnmanagedSpawnsShareCriticalSection);
  Test('already-exited registered process tree is a successful no-op',
    TestExitedRegisteredProcessTreeIsSuccessfulNoOp);
  Test('failed descendant termination acknowledgement propagates to ancestor',
    TestFailedNestedTerminationAcknowledgementFailsCancellation);
  Test('missing nested termination acknowledgement fails cancellation',
    TestMissingTerminationAcknowledgementFailsCancellation);
  Test('registered sibling cancellations share one fanout',
    TestSiblingTerminationAcknowledgementsShareFanout);
  Test('process-tree protocol framing is bounded and incremental',
    TestProtocolFramingIsBoundedAndIncremental);
  Test('process failure survives delegation cleanup failure',
    TestProcessFailureSurvivesDelegationCleanupFailure);
  {$IFDEF UNIX}
  Test('SIGINT reaps the active compiler tree',
    TestSIGINTTerminatesActiveProcessTree);
  Test('SIGTERM reaps the active compiler tree',
    TestSIGTERMTerminatesActiveProcessTree);
  Test('inherited acknowledgement channel rejects regular files',
    TestInheritedChannelRejectsRegularFiles);
  Test('inherited acknowledgement channel rejects wrong pipe direction',
    TestInheritedChannelRejectsWrongPipeDirection);
  Test('acknowledgement control read is bounded for EOF and no data',
    TestAcknowledgementControlReadIsBounded);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Test('Ctrl-C reaps the active compiler Job Object',
    TestCtrlCTerminatesActiveProcessTree);
  Test('Ctrl-Break reaps the active compiler Job Object',
    TestCtrlBreakTerminatesActiveProcessTree);
  {$ENDIF}
  Test('silent jobs emit heartbeat and serialized progress',
    TestSilentJobEmitsHeartbeatAndProgress);
  Test('failures replay output and preserve isolated logs',
    TestFailureReplaysAndPreservesIsolatedLog);
  Test('verbose success logs never interleave',
    TestVerboseSuccessLogsNeverInterleave);
  Test('bail reaps nested ' + PROJECT_NAME
    + ' compiler that ignores SIGTERM',
    TestBailTerminatesNestedLWPTCompilerIgnoringSIGTERM);
end;

begin
  {$IFDEF MSWINDOWS}
  if (ParamCount = 6)
     and (ParamStr(1) = WindowsConsoleControllerOption) then
    Halt(RunWindowsConsoleController);
  {$ENDIF}
  if GetEnvironmentVariable(ProcessTreeProxyModeEnvironment) <> '' then
    Halt(RunProcessTreeCompilerProxy);
  TestRunnerProgram.AddSuite(TTestScheduling.Create('TestScheduling'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
