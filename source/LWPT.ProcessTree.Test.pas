{ Unix process-group isolation contract for managed process trees. The same
  executable acts as the spawned child and reports the process group it runs
  in, so the spawn cases observe the real kernel state after LWPT's setup.
  Scripted setpgid(2) outcomes and raw group-query results replay the Darwin
  race from #299 beneath the production classification, and pin the bounded
  retry and its pauses on both sides.

  On every platform, shutdown cases spawn the same executable as a child that
  installs signal forwarding and returns from its main program at once. The
  Tests.ShutdownProbe unit finalizes after every LWPT unit and fails the
  child if a forwarder thread is still alive, pinning #330: a forwarder left
  running while the runtime finalized crashed or hung short-lived commands.
  A clean child must print the probe's marker, which only a completed probe
  writes, so an emergency exit that skips finalization cannot pass; a
  falsification case holds the forwarders unstarted to prove it fails.
  Cancellation cases hold forwarder startup until a cancellation and the
  shutdown are both pending, and require the cancellation to be forwarded
  with its exit status rather than dropped by the stop. }
program LWPT.ProcessTree.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Tests.ShutdownProbe, { before Classes, SysUtils and LWPT units: finalizes after them }
  Classes,
  Pipes,
  Process,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.ProcessRunner,
  LWPT.ProcessTree,
  TestingPascalLibrary,
  Tests.ProcessSupport;

const
  ReportGroupSwitch = '--process-tree-report-group';
  ShutdownChildSwitch = '--process-tree-shutdown-child';
  { The child returns from its main program the moment forwarding is
    installed, racing the forwarder's startup, or after the forwarder has had
    time to block. }
  ShutdownImmediately = 'immediate';
  ShutdownAfterSettling = 'settled';
  ShutdownSettleMilliseconds = 50;
  { Holds the forwarders unstarted for good, so shutdown's bounded join
    expires and the child takes the emergency exit. }
  ShutdownAbandoned = 'abandoned';
  { Queues a cancellation while forwarder startup is held until shutdown. }
  ShutdownWithPendingCancellation = 'pending-cancellation';
  {$IFDEF MSWINDOWS}
  { Managed child: waits for its parent's CANCEL frame while startup is held. }
  ShutdownWithPendingCancelFrame = 'pending-cancel-frame';
  ShutdownReadyLine = 'shutdown child ready';
  WindowsControlExitCode = Integer(LongWord($C000013A));
  CtrlBreakEvent = 1;
  CancelDescendantMilliseconds = 5000;
  CancelAcknowledgementMilliseconds = 10000;
  {$ENDIF}
  ShutdownChildExitCode = 42;
  ShutdownRunsPerMode = 10;
  ShutdownChildTimeoutMilliseconds = 30000;
  ShutdownPollMilliseconds = 10;
  ReporterTimeoutMilliseconds = 30000;
  ScriptedRejections = 2;
  AlwaysScripted = High(Integer);
  { The retry contract, stated independently of the production constants so
    a change on either side fails here. }
  RequiredGroupSetupAttempts = 5;
  RequiredRetryPauseMilliseconds = 1;
  MicrosecondsPerMillisecond = 1000;
  RequiredRetryPauseMicroseconds = RequiredRetryPauseMilliseconds
    * MicrosecondsPerMillisecond;
  { A process group no test process can lead: the system's first process. }
  ForeignProcessGroupID = 1;
  FailedQueryResult = -1;
  IsolationFailure = 'could not isolate process tree';

type
  TSpawnResult = record
    ExitCode: Integer;
    ExitStatus: Integer;
    Stdout: string;
    Stderr: string;
    ErrorMessage: string;
  end;

  TProcessTreeShutdown = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestUnmanagedChildJoinsForwarders;
    procedure TestManagedChildJoinsForwarders;
    procedure TestEmergencyExitFailsTheShutdownCheck;
    procedure TestPendingCancellationSurvivesShutdown;
    {$IFDEF MSWINDOWS}
    procedure TestPendingCancelFrameSurvivesShutdown;
    {$ENDIF}
  end;

{$IFDEF UNIX}
function CRaise(const ASignal: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'raise';
  {$ELSE}
  external name 'raise';
  {$ENDIF}
{$ENDIF}

function DrainPipe(const AStream: TInputPipeStream): string;
var
  Buffer: array[0..PROCESS_OUTPUT_BUFFER_SIZE - 1] of Byte;
  BytesRead: Integer;
begin
  Result := '';
  while AStream.NumBytesAvailable > 0 do
  begin
    BytesRead := AStream.Read(Buffer[0], SizeOf(Buffer));
    if BytesRead <= 0 then Break;
    AppendRawBytes(Result, Buffer[0], BytesRead);
  end;
end;

{ Runs an unmanaged child under a deadline. Its merged output is drained
  while it runs; a child that outlives the deadline is killed and reported
  with what it wrote, so a hung shutdown fails the case instead of hanging
  the runner. }
procedure RunUnmanagedChild(const P: TProcess; var AResult: TSpawnResult);
var
  StartedAt: QWord;
begin
  P.Options := [poUsePipes, poStderrToOutPut];
  ExecuteUnmanagedProcess(P);
  StartedAt := GetTickCount64;
  while P.Running do
  begin
    AResult.Stdout := AResult.Stdout + DrainPipe(P.Output);
    if GetTickCount64 - StartedAt >= ShutdownChildTimeoutMilliseconds then
    begin
      TerminateChildProcess(P, AResult.Stdout, AResult.Stderr);
      AResult.ErrorMessage := Format(
        'shutdown child did not exit within %d ms; output: %s',
        [ShutdownChildTimeoutMilliseconds, AResult.Stdout]);
      Exit;
    end;
    Sleep(ShutdownPollMilliseconds);
  end;
  AResult.Stdout := AResult.Stdout + DrainPipe(P.Output);
  AResult.ExitCode := NormalisedExitCode(P);
  AResult.ExitStatus := P.ExitStatus;
end;

{ Spawns this executable in shutdown-child mode. A managed child runs under
  a process tree and inherits its acknowledgement channel, which on Windows
  adds the inherited-control forwarder; an unmanaged child has only the
  console-control or signal forwarder. }
function SpawnShutdownChild(const AManaged: Boolean;
  const AMode: string): TSpawnResult;
var
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
begin
  Result := Default(TSpawnResult);
  Result.ExitCode := -1;
  Result.ExitStatus := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := ExpandFileName(ParamStr(0));
    P.Parameters.Add(ShutdownChildSwitch);
    P.Parameters.Add(AMode);
    if AManaged then
    begin
      Runner := TLWPTDuplexProcessRunner.Create(P);
      try
        Options := DefaultProcessRunOptions('process-tree shutdown child');
        Options.SeparateStandardError := True;
        Options.TimeoutMilliseconds := ShutdownChildTimeoutMilliseconds;
        try
          Result.ExitCode := Runner.Run('', Options, Result.Stdout,
            Result.Stderr);
        except
          on E: Exception do Result.ErrorMessage := E.Message;
        end;
      finally
        Runner.Free;
      end;
    end
    else
      RunUnmanagedChild(P, Result);
  finally
    P.Free;
  end;
end;

{ The regression's verdict: the child returned its own exit code, and the
  shutdown probe ran after every LWPT unit finalized and found no live
  forwarder. The marker is the positive evidence; an exit that skipped
  finalization keeps the exit code but never prints it. }
function ShutdownWasClean(const AResult: TSpawnResult): Boolean;
begin
  Result := (AResult.ErrorMessage = '')
    and (AResult.ExitCode = ShutdownChildExitCode)
    and (Pos(ShutdownProbeFailure, AResult.Stdout + AResult.Stderr) = 0)
    and (Trim(AResult.Stdout) = ShutdownProbeCleanMarker);
end;

procedure ExpectCleanShutdown(const AManaged: Boolean);
var
  ModeIndex, Run: Integer;
  R: TSpawnResult;
const
  Modes: array[0..1] of string = (ShutdownImmediately, ShutdownAfterSettling);
begin
  for ModeIndex := Low(Modes) to High(Modes) do
    for Run := 1 to ShutdownRunsPerMode do
    begin
      R := SpawnShutdownChild(AManaged, Modes[ModeIndex]);
      Expect<string>(R.ErrorMessage).ToBe('');
      Expect<string>(Trim(R.Stderr)).ToBe('');
      Expect<string>(Trim(R.Stdout)).ToBe(ShutdownProbeCleanMarker);
      Expect<Integer>(R.ExitCode).ToBe(ShutdownChildExitCode);
      if not ShutdownWasClean(R) then Exit;
    end;
end;

procedure TProcessTreeShutdown.TestUnmanagedChildJoinsForwarders;
begin
  ExpectCleanShutdown(False);
end;

procedure TProcessTreeShutdown.TestManagedChildJoinsForwarders;
begin
  ExpectCleanShutdown(True);
end;

{ Falsifies the verdict: a child whose forwarders never stop takes the
  emergency exit, which keeps its exit code and writes nothing, and the
  regression must reject exactly that outcome. }
procedure TProcessTreeShutdown.TestEmergencyExitFailsTheShutdownCheck;
var
  R: TSpawnResult;
begin
  R := SpawnShutdownChild(False, ShutdownAbandoned);
  Expect<string>(R.ErrorMessage).ToBe('');
  Expect<Integer>(R.ExitCode).ToBe(ShutdownChildExitCode);
  Expect<string>(Trim(R.Stdout)).ToBe('');
  Expect<Boolean>(ShutdownWasClean(R)).ToBe(False);
end;

{ A cancellation accepted before shutdown must still be forwarded even when
  the forwarder only starts after the stop was requested. }
procedure TProcessTreeShutdown.TestPendingCancellationSurvivesShutdown;
var
  R: TSpawnResult;
begin
  R := SpawnShutdownChild(False, ShutdownWithPendingCancellation);
  Expect<string>(R.ErrorMessage).ToBe('');
  Expect<Boolean>(Pos(ShutdownProbeCleanMarker, R.Stdout) > 0).ToBe(False);
  {$IFDEF UNIX}
  { The forwarder re-raises SIGTERM with the default disposition. }
  Expect<Boolean>(wifsignaled(R.ExitStatus)).ToBe(True);
  Expect<Integer>(wtermsig(R.ExitStatus)).ToBe(SIGTERM);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Expect<Integer>(R.ExitCode).ToBe(WindowsControlExitCode);
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
{ The managed variant: the parent's CANCEL frame is waiting when shutdown
  starts, so the inherited-control forwarder must still read it, report
  REAPED within the frame's deadline, and end with the control exit code. }
procedure TProcessTreeShutdown.TestPendingCancelFrameSurvivesShutdown;
var
  Output, CancelFailure: string;
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
  StartedAt: QWord;
begin
  Output := '';
  CancelFailure := '';
  P := TProcess.Create(nil);
  try
    P.Executable := ExpandFileName(ParamStr(0));
    P.Parameters.Add(ShutdownChildSwitch);
    P.Parameters.Add(ShutdownWithPendingCancelFrame);
    Runner := TLWPTDuplexProcessRunner.Create(P);
    try
      Options := DefaultProcessRunOptions('process-tree shutdown child');
      Options.SeparateStandardError := True;
      Runner.Start(Options);
      StartedAt := GetTickCount64;
      while (Pos(ShutdownReadyLine, Output) = 0) and P.Running
        and (GetTickCount64 - StartedAt < ShutdownChildTimeoutMilliseconds) do
      begin
        Output := Output + DrainPipe(P.Output);
        Sleep(ShutdownPollMilliseconds);
      end;
      Expect<Boolean>(Pos(ShutdownReadyLine, Output) > 0).ToBe(True);
      try
        Runner.BeginCancel(GetTickCount64 + CancelDescendantMilliseconds,
          GetTickCount64 + CancelAcknowledgementMilliseconds);
        Runner.CompleteCancel;
      except
        on E: Exception do CancelFailure := E.Message;
      end;
      if P.Running then TerminateChildProcess(P);
      Expect<string>(CancelFailure).ToBe('');
      Expect<Integer>(NormalisedExitCode(P)).ToBe(WindowsControlExitCode);
    finally
      Runner.Free;
    end;
  finally
    P.Free;
  end;
end;
{$ENDIF}

procedure TProcessTreeShutdown.SetupTests;
begin
  Test('unmanaged child joins its forwarders before the runtime finalizes',
    TestUnmanagedChildJoinsForwarders);
  Test('managed child joins its forwarders before the runtime finalizes',
    TestManagedChildJoinsForwarders);
  Test('an emergency exit fails the shutdown check',
    TestEmergencyExitFailsTheShutdownCheck);
  Test('a cancellation pending at shutdown is still forwarded',
    TestPendingCancellationSurvivesShutdown);
  {$IFDEF MSWINDOWS}
  Test('a CANCEL frame pending at shutdown is still acknowledged',
    TestPendingCancelFrameSurvivesShutdown);
  {$ENDIF}
end;

procedure RunShutdownChild;
{$IFDEF MSWINDOWS}
var
  StartedAt: QWord;
{$ENDIF}
begin
  ArmShutdownProbe(ProcessTreeLiveForwardersForTesting);
  if (ParamStr(2) = ShutdownWithPendingCancellation)
     {$IFDEF MSWINDOWS}
     or (ParamStr(2) = ShutdownWithPendingCancelFrame)
     {$ENDIF} then
    ProcessTreeForwarderStartForTesting := fstAtShutdown
  else if ParamStr(2) = ShutdownAbandoned then
    ProcessTreeForwarderStartForTesting := fstNever;
  InstallProcessTreeSignalForwarding;
  if ParamStr(2) = ShutdownAfterSettling then
    Sleep(ShutdownSettleMilliseconds);
  if ParamStr(2) = ShutdownWithPendingCancellation then
  begin
    {$IFDEF UNIX}
    { raise(3) runs the handler on this thread before it returns, so the
      signal is admitted and queued before shutdown begins. }
    CRaise(SIGTERM);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    ProcessTreeDeliverConsoleControlForTesting(CtrlBreakEvent);
    {$ENDIF}
  end;
  {$IFDEF MSWINDOWS}
  if ParamStr(2) = ShutdownWithPendingCancelFrame then
  begin
    WriteLn(ShutdownReadyLine);
    Flush(Output);
    StartedAt := GetTickCount64;
    while not ProcessTreeInheritedControlPendingForTesting
      and (GetTickCount64 - StartedAt < ShutdownChildTimeoutMilliseconds) do
      Sleep(1);
  end;
  {$ENDIF}
  ExitCode := ShutdownChildExitCode;
end;

{$IFDEF UNIX}
type
  TProcessTreeIsolation = class(TTestSuite)
  public
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure SetupTests; override;
    procedure TestChildLeadsItsOwnGroup;
    procedure TestChildToleratesEPERMAfterItsCallApplied;
    procedure TestParentToleratesEPERMAfterItsCallApplied;
    procedure TestParentRetriesUntilTheGroupExists;
    procedure TestParentAcceptsAQueriedLeader;
    procedure TestParentAcceptsAChildThatAlreadyExited;
    procedure TestParentRejectsOtherQueryFailures;
    procedure TestParentStopsAfterTheRequiredAttempts;
    procedure TestChildRetriesUntilItLeadsItsGroup;
    procedure TestChildAcceptsAQueriedLeader;
    procedure TestChildStopsAfterTheRequiredAttempts;
    procedure TestParentRaisesWhenTheGroupNeverAppears;
    procedure TestChildExitsWithSetupCodeWhenItCannotIsolate;
    procedure TestIneffectiveIsolationFails;
  end;

function SpawnReporter: TSpawnResult;
var
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
begin
  Result := Default(TSpawnResult);
  Result.ExitCode := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := ExpandFileName(ParamStr(0));
    P.Parameters.Add(ReportGroupSwitch);
    Runner := TLWPTDuplexProcessRunner.Create(P);
    try
      Options := DefaultProcessRunOptions('process-tree isolation probe');
      Options.SeparateStandardError := True;
      Options.TimeoutMilliseconds := ReporterTimeoutMilliseconds;
      try
        Result.ExitCode := Runner.Run('', Options, Result.Stdout,
          Result.Stderr);
      except
        on E: Exception do Result.ErrorMessage := E.Message;
      end;
    finally
      Runner.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure ExpectIsolatedChild(const AResult: TSpawnResult);
var
  Fields: TStringList;
begin
  Expect<string>(AResult.ErrorMessage).ToBe('');
  Expect<Integer>(AResult.ExitCode).ToBe(0);
  Fields := TStringList.Create;
  try
    Fields.Delimiter := ' ';
    Fields.DelimitedText := Trim(AResult.Stdout);
    Expect<Integer>(Fields.Count).ToBe(2);
    if Fields.Count = 2 then
      Expect<string>(Fields[1]).ToBe(Fields[0]);
  finally
    Fields.Free;
  end;
end;

{ In-process cases apply the child and parent sides to this test process,
  which LWPT's own runner already isolated, so the real setpgid(2) calls a
  script lets through leave its group unchanged. }
procedure ExpectLeadsOwnGroup;
begin
  Expect<Boolean>(FpGetpgrp = FpGetpid).ToBe(True);
end;

{ Rejects the first ACount setpgid(2) calls without effect, and reports the
  first ACount raw group queries as a group the target does not lead. }
procedure ScriptForeignGroup(var AScript: TLWPTProcessGroupScript;
  const ACount: Integer);
begin
  AScript.RejectedCalls := ACount;
  AScript.ScriptedQueries := ACount;
  AScript.QueryResult := ForeignProcessGroupID;
end;

procedure ScriptQueryFailure(var AScript: TLWPTProcessGroupScript;
  const AErrorCode: Integer);
begin
  AScript.RejectedCalls := AlwaysScripted;
  AScript.ScriptedQueries := AlwaysScripted;
  AScript.QueryResult := FailedQueryResult;
  AScript.QueryErrorCode := AErrorCode;
end;

{ Pauses occur only between attempts: one before each retry, none before the
  first call or after the last, each for the required timeout. }
procedure ExpectPausesBetween(const AScript: TLWPTProcessGroupScript;
  const ACalls: Integer);
var
  PauseIndex: Integer;
begin
  Expect<Integer>(AScript.Pauses).ToBe(ACalls - 1);
  for PauseIndex := 0 to AScript.Pauses - 1 do
    Expect<Integer>(AScript.PauseAfterCalls[PauseIndex]).ToBe(PauseIndex + 1);
  if AScript.Pauses > 0 then
    Expect<Integer>(AScript.PauseMicroseconds)
      .ToBe(RequiredRetryPauseMicroseconds);
end;

procedure ResetGroupScripts;
begin
  ProcessTreeChildGroupScript := Default(TLWPTProcessGroupScript);
  ProcessTreeParentGroupScript := Default(TLWPTProcessGroupScript);
end;

{ The runner skips AfterEach when a case raises, so each case also starts
  from real kernel behavior. }
procedure TProcessTreeIsolation.BeforeEach;
begin
  ResetGroupScripts;
end;

procedure TProcessTreeIsolation.AfterEach;
begin
  ResetGroupScripts;
end;

procedure TProcessTreeIsolation.TestChildLeadsItsOwnGroup;
begin
  ExpectIsolatedChild(SpawnReporter);
end;

procedure TProcessTreeIsolation.TestChildToleratesEPERMAfterItsCallApplied;
begin
  ProcessTreeChildGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeChildGroupScript.RejectionTakesEffect := True;
  ExpectIsolatedChild(SpawnReporter);
end;

procedure TProcessTreeIsolation.TestParentToleratesEPERMAfterItsCallApplied;
begin
  ProcessTreeParentGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeParentGroupScript.RejectionTakesEffect := True;
  ExpectIsolatedChild(SpawnReporter);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls).ToBe(1);
  Expect<Integer>(ProcessTreeParentGroupScript.Queries).ToBe(1);
end;

procedure TProcessTreeIsolation.TestParentRetriesUntilTheGroupExists;
var
  ErrorCode: Integer;
begin
  ExpectLeadsOwnGroup;
  ScriptForeignGroup(ProcessTreeParentGroupScript, ScriptedRejections);
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(ScriptedRejections + 1);
  Expect<Integer>(ProcessTreeParentGroupScript.Queries)
    .ToBe(ScriptedRejections);
  ExpectPausesBetween(ProcessTreeParentGroupScript, ScriptedRejections + 1);
end;

procedure TProcessTreeIsolation.TestParentAcceptsAQueriedLeader;
var
  ErrorCode: Integer;
begin
  ProcessTreeParentGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeParentGroupScript.ScriptedQueries := AlwaysScripted;
  ProcessTreeParentGroupScript.QueryResult := FpGetpid;
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls).ToBe(1);
  ExpectPausesBetween(ProcessTreeParentGroupScript, 1);
end;

procedure TProcessTreeIsolation.TestParentAcceptsAChildThatAlreadyExited;
var
  ErrorCode: Integer;
begin
  ScriptQueryFailure(ProcessTreeParentGroupScript, ESysESRCH);
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls).ToBe(1);
  ExpectPausesBetween(ProcessTreeParentGroupScript, 1);
end;

procedure TProcessTreeIsolation.TestParentRejectsOtherQueryFailures;
var
  ErrorCode: Integer;
begin
  ScriptQueryFailure(ProcessTreeParentGroupScript, ESysEINVAL);
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(False);
  Expect<Integer>(ErrorCode).ToBe(ESysEPERM);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(RequiredGroupSetupAttempts);
end;

procedure TProcessTreeIsolation.TestParentStopsAfterTheRequiredAttempts;
var
  ErrorCode: Integer;
begin
  ScriptForeignGroup(ProcessTreeParentGroupScript, AlwaysScripted);
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(False);
  Expect<Integer>(ErrorCode).ToBe(ESysEPERM);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(RequiredGroupSetupAttempts);
  Expect<Integer>(ProcessTreeParentGroupScript.Queries)
    .ToBe(RequiredGroupSetupAttempts);
  ExpectPausesBetween(ProcessTreeParentGroupScript,
    RequiredGroupSetupAttempts);
end;

procedure TProcessTreeIsolation.TestChildRetriesUntilItLeadsItsGroup;
begin
  ExpectLeadsOwnGroup;
  ScriptForeignGroup(ProcessTreeChildGroupScript, ScriptedRejections);
  Expect<Boolean>(LeadOwnProcessGroupAfterFork).ToBe(True);
  Expect<Integer>(ProcessTreeChildGroupScript.Calls)
    .ToBe(ScriptedRejections + 1);
  Expect<Integer>(ProcessTreeChildGroupScript.Queries)
    .ToBe(ScriptedRejections);
  ExpectPausesBetween(ProcessTreeChildGroupScript, ScriptedRejections + 1);
end;

procedure TProcessTreeIsolation.TestChildAcceptsAQueriedLeader;
begin
  ProcessTreeChildGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeChildGroupScript.ScriptedQueries := AlwaysScripted;
  ProcessTreeChildGroupScript.QueryResult := FpGetpid;
  Expect<Boolean>(LeadOwnProcessGroupAfterFork).ToBe(True);
  Expect<Integer>(ProcessTreeChildGroupScript.Calls).ToBe(1);
  ExpectPausesBetween(ProcessTreeChildGroupScript, 1);
end;

procedure TProcessTreeIsolation.TestChildStopsAfterTheRequiredAttempts;
begin
  ScriptForeignGroup(ProcessTreeChildGroupScript, AlwaysScripted);
  Expect<Boolean>(LeadOwnProcessGroupAfterFork).ToBe(False);
  Expect<Integer>(ProcessTreeChildGroupScript.Calls)
    .ToBe(RequiredGroupSetupAttempts);
  Expect<Integer>(ProcessTreeChildGroupScript.Queries)
    .ToBe(RequiredGroupSetupAttempts);
  ExpectPausesBetween(ProcessTreeChildGroupScript,
    RequiredGroupSetupAttempts);
end;

procedure TProcessTreeIsolation.TestParentRaisesWhenTheGroupNeverAppears;
var
  R: TSpawnResult;
begin
  ScriptForeignGroup(ProcessTreeParentGroupScript, AlwaysScripted);
  R := SpawnReporter;
  Expect<Boolean>(Pos(IsolationFailure, R.ErrorMessage) > 0).ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(RequiredGroupSetupAttempts);
end;

procedure TProcessTreeIsolation.TestChildExitsWithSetupCodeWhenItCannotIsolate;
var
  R: TSpawnResult;
begin
  ScriptForeignGroup(ProcessTreeChildGroupScript, AlwaysScripted);
  R := SpawnReporter;
  Expect<string>(R.ErrorMessage).ToBe('');
  Expect<Integer>(R.ExitCode).ToBe(ProcessTreeSetupExitCode);
  Expect<Boolean>(Pos(ProcessTreeSetupFailure, R.Stderr) > 0).ToBe(True);
  Expect<string>(Trim(R.Stdout)).ToBe('');
end;

procedure TProcessTreeIsolation.TestIneffectiveIsolationFails;
var
  R: TSpawnResult;
begin
  { Both sides are rejected without effect and query the real kernel, so
    the group genuinely never exists. Whichever side notices first reports
    it: the parent raises, or the child exits with the setup code. }
  ProcessTreeChildGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeParentGroupScript.RejectedCalls := AlwaysScripted;
  R := SpawnReporter;
  Expect<Boolean>((Pos(IsolationFailure, R.ErrorMessage) > 0)
    or ((R.ExitCode = ProcessTreeSetupExitCode)
      and (Pos(ProcessTreeSetupFailure, R.Stderr) > 0))).ToBe(True);
  Expect<string>(Trim(R.Stdout)).ToBe('');
end;

procedure TProcessTreeIsolation.SetupTests;
begin
  Test('managed child leads its own process group',
    TestChildLeadsItsOwnGroup);
  Test('child accepts EPERM when its own call took effect',
    TestChildToleratesEPERMAfterItsCallApplied);
  Test('parent accepts EPERM when its own call took effect',
    TestParentToleratesEPERMAfterItsCallApplied);
  Test('parent retries until the child group exists',
    TestParentRetriesUntilTheGroupExists);
  Test('parent accepts EPERM once getpgid shows the child leading',
    TestParentAcceptsAQueriedLeader);
  Test('parent accepts a child whose getpgid fails with ESRCH',
    TestParentAcceptsAChildThatAlreadyExited);
  Test('parent rejects other getpgid failures',
    TestParentRejectsOtherQueryFailures);
  Test('parent stops after exactly five attempts with pauses between',
    TestParentStopsAfterTheRequiredAttempts);
  Test('child retries until it leads its group',
    TestChildRetriesUntilItLeadsItsGroup);
  Test('child accepts EPERM once getpgrp shows it leading',
    TestChildAcceptsAQueriedLeader);
  Test('child stops after exactly five attempts with pauses between',
    TestChildStopsAfterTheRequiredAttempts);
  Test('parent raises when the child group never appears',
    TestParentRaisesWhenTheGroupNeverAppears);
  Test('child exits with the setup code when it cannot isolate',
    TestChildExitsWithSetupCodeWhenItCannotIsolate);
  Test('ineffective isolation on both sides fails',
    TestIneffectiveIsolationFails);
end;
{$ENDIF}

begin
  { The child returns from here, like the lwpt program, so unit
    finalization runs exactly as it does after a fast command failure. }
  if ParamStr(1) = ShutdownChildSwitch then
  begin
    RunShutdownChild;
    Exit;
  end;
  {$IFDEF UNIX}
  if ParamStr(1) = ReportGroupSwitch then
  begin
    WriteLn(FpGetpid, ' ', FpGetpgrp);
    Halt(0);
  end;
  TestRunnerProgram.AddSuite(TProcessTreeIsolation.Create(
    PROJECT_NAME + '.ProcessTree: Unix process-group isolation'));
  {$ENDIF}
  TestRunnerProgram.AddSuite(TProcessTreeShutdown.Create(
    PROJECT_NAME + '.ProcessTree: forwarder shutdown'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
