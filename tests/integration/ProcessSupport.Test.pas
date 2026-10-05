{ ProcessSupport.Test — the bounded child waits of Tests.ProcessSupport
  against real children of this executable.

  Each case re-runs this program in a child mode: one that writes past pipe
  capacity to both streams, one that sleeps, one that leaves a descendant
  running after it returns, one that leaves a descendant that ends shortly
  after it, and one that holds a sleeping descendant. The survivor cases
  are the falsification of process-tree ownership: an owned child that
  returns while a descendant still runs must fail its wait, never pass on
  the helper's own kill-on-close or group cleanup. Their descendant sleeps
  far past the survivor settle period, while the brief descendant ends well
  inside it and must not be reported. They need a Job Object (Windows) or
  Linux procfs; Darwin skips them. Under Wine the Job Object cases do not
  exercise native Windows job semantics. }
program ProcessSupport.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.PayloadHandoff,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  FloodSwitch = '--process-support-flood';
  SleepSwitch = '--process-support-sleep';
  SurvivorSwitch = '--process-support-spawn-survivor';
  BriefSwitch = '--process-support-spawn-brief';
  HolderSwitch = '--process-support-hold-descendant';
  { Past every platform's anonymous-pipe capacity (64 KiB on Linux and
    macOS, a few KiB to 64 KiB on Windows). }
  FloodBytes = 1024 * 1024;
  { A survivor must outlive the settle period by far, so a slow runner
    cannot let it end inside the period and pass unreported. }
  DescendantSleepMilliseconds = 60000;
  { A trailing member that ends well inside the settle period. }
  BriefDescendantMilliseconds = 500;
  CaseTimeoutMilliseconds = 60000;
  ShortDeadlineMilliseconds = 300;
  DescendantGoneMilliseconds = 5000;

type
  TProcessSupportTests = class(TTestSuite)
  private
    FScratch: string;
    function SelfChild(const AArguments: array of string;
      const AOptions: TProcessOptions): TProcess;
    function WaitForDescendantPID(const APath: string): Integer;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestDrainingWaitTakesBothOverfullPipes;
    procedure TestWaitsWithoutOutputStillDrain;
    procedure TestTimedOutChildIsTerminatedAndReported;
    procedure TestZeroAllowanceDoesNotBlock;
    procedure TestOwnedTreeIsTerminatedWithItsDescendants;
    procedure TestFinishChildReportsASurvivingDescendant;
    procedure TestFinishChildToleratesADescendantEndingWithinTheSettle;
    procedure TestReapChildEndsAnOwnedTreesSurvivor;
    procedure TestRunLwptReportsASurvivingDescendant;
  end;

procedure WriteFlood(const AHandle: THandle);
var
  Chunk: string;
  Stream: THandleStream;
  Written: Integer;
begin
  Chunk := StringOfChar('x', 4096);
  Stream := THandleStream.Create(AHandle);
  try
    Written := 0;
    while Written < FloodBytes do
    begin
      Stream.WriteBuffer(Chunk[1], Length(Chunk));
      Inc(Written, Length(Chunk));
    end;
  finally
    Stream.Free;
  end;
end;

{$IF DescendantSleepMilliseconds < 6 * OWNED_TREE_SETTLE_MILLISECONDS}
{$ERROR the survivor descendant must sleep far past the settle period}
{$ENDIF}
{$IF 4 * BriefDescendantMilliseconds > OWNED_TREE_SETTLE_MILLISECONDS}
{$ERROR the brief descendant must end well inside the settle period}
{$ENDIF}

{ Starts a copy of this program sleeping AMilliseconds and returns it; the
  caller decides whether to wait for it. }
function StartSleepingDescendant(
  const AMilliseconds: Integer = DescendantSleepMilliseconds): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ExpandFileName(ParamStr(0));
  Result.Parameters.Add(SleepSwitch);
  Result.Parameters.Add(IntToStr(AMilliseconds));
  { The descendant must not keep the parent's pipe writers open. }
  Result.InheritHandles := False;
  Result.Execute;
end;

function RunChildMode: Boolean;
var
  Descendant: TProcess;
begin
  Result := True;
  if (ParamCount = 1) and (ParamStr(1) = FloodSwitch) then
  begin
    WriteFlood(StdOutputHandle);
    WriteFlood(StdErrorHandle);
    Halt(0);
  end;
  if (ParamCount = 2) and (ParamStr(1) = SleepSwitch) then
  begin
    Sleep(StrToInt(ParamStr(2)));
    Halt(0);
  end;
  if (ParamCount = 2) and (ParamStr(1) = SurvivorSwitch) then
  begin
    { Returns at once, leaving its descendant running: the defect an
      owned child's wait must report. }
    Descendant := StartSleepingDescendant;
    PublishReadablePayload(ParamStr(2), IntToStr(Descendant.ProcessID));
    Descendant.Free;
    Halt(0);
  end;
  if (ParamCount = 2) and (ParamStr(1) = BriefSwitch) then
  begin
    { Returns at once; its descendant ends shortly after, like a console
      host or a member still being torn down. }
    Descendant := StartSleepingDescendant(BriefDescendantMilliseconds);
    PublishReadablePayload(ParamStr(2), IntToStr(Descendant.ProcessID));
    Descendant.Free;
    Halt(0);
  end;
  if (ParamCount = 2) and (ParamStr(1) = HolderSwitch) then
  begin
    Descendant := StartSleepingDescendant;
    PublishReadablePayload(ParamStr(2), IntToStr(Descendant.ProcessID));
    Sleep(DescendantSleepMilliseconds);
    Descendant.Free;
    Halt(0);
  end;
  Result := False;
end;

function DescendantGone(const APID: Integer): Boolean;
var
  StartedAt: QWord;
begin
  { An ended descendant can linger as a zombie until its adopter reaps it,
    which ProcessIsLive counts as gone. }
  StartedAt := GetTickCount64;
  while ProcessIsLive(APID)
    and (GetTickCount64 - StartedAt < DescendantGoneMilliseconds) do
    Sleep(ProcessPollMilliseconds);
  Result := not ProcessIsLive(APID);
end;

procedure TProcessSupportTests.BeforeAll;
begin
  FScratch := CreateScratchRoot('process-support');
end;

procedure TProcessSupportTests.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

function TProcessSupportTests.SelfChild(const AArguments: array of string;
  const AOptions: TProcessOptions): TProcess;
var
  Index: Integer;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ExpandFileName(ParamStr(0));
  for Index := 0 to High(AArguments) do
    Result.Parameters.Add(AArguments[Index]);
  Result.Options := AOptions;
end;

function TProcessSupportTests.WaitForDescendantPID(
  const APath: string): Integer;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not PayloadIsReadable(APath)
    and (GetTickCount64 - StartedAt < CaseTimeoutMilliseconds) do
    Sleep(ProcessPollMilliseconds);
  Expect<Boolean>(PayloadIsReadable(APath)).ToBe(True);
  Result := StrToInt(Trim(ReadPayloadText(APath)));
end;

procedure TProcessSupportTests.TestDrainingWaitTakesBothOverfullPipes;
var
  Child: TProcess;
  Stdout, Stderr: string;
begin
  Child := SelfChild([FloodSwitch], [poUsePipes]);
  try
    Child.Execute;
    Stdout := '';
    Stderr := '';
    Expect<Integer>(FinishChild(Child, Stdout, Stderr,
      CaseTimeoutMilliseconds, 'flood')).ToBe(0);
    Expect<Integer>(Length(Stdout)).ToBe(FloodBytes);
    Expect<Integer>(Length(Stderr)).ToBe(FloodBytes);
  finally
    ReapChild(Child, CHILD_KILL_MILLISECONDS);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestWaitsWithoutOutputStillDrain;
var
  Child: TProcess;
begin
  { Without draining, the child would block on a full pipe and these waits
    would end it at their deadline instead of seeing it exit. }
  Child := SelfChild([FloodSwitch], [poUsePipes]);
  try
    Child.Execute;
    Expect<Integer>(FinishChild(Child, CaseTimeoutMilliseconds, 'flood'))
      .ToBe(0);
  finally
    Child.Free;
  end;
  Child := SelfChild([FloodSwitch], [poUsePipes]);
  try
    Child.Execute;
    Expect<Boolean>(ReapChild(Child, CaseTimeoutMilliseconds)).ToBe(True);
    Expect<Integer>(ChildProcessExitCode(Child)).ToBe(0);
  finally
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestTimedOutChildIsTerminatedAndReported;
var
  Child: TProcess;
  Failure: string;
begin
  Child := SelfChild([SleepSwitch, IntToStr(DescendantSleepMilliseconds)],
    []);
  try
    Child.Execute;
    Failure := '';
    try
      FinishChild(Child, ShortDeadlineMilliseconds, 'sleeper');
    except
      on E: EChildProcessTimeout do Failure := E.Message;
    end;
    Expect<Boolean>(Pos('sleeper exceeded its '
      + IntToStr(ShortDeadlineMilliseconds) + ' ms deadline and was '
      + 'terminated', Failure) = 1).ToBe(True);
    Expect<Boolean>(Child.Running).ToBe(False);
  finally
    ReapChild(Child, CHILD_KILL_MILLISECONDS);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestZeroAllowanceDoesNotBlock;
var
  Child: TProcess;
  StartedAt: QWord;
begin
  Child := SelfChild([SleepSwitch, IntToStr(DescendantSleepMilliseconds)],
    []);
  try
    ExecuteOwnedChild(Child);
    StartedAt := GetTickCount64;
    Expect<Boolean>(WaitForChildExit(Child, 0)).ToBe(False);
    Expect<Boolean>(GetTickCount64 - StartedAt < 1000).ToBe(True);
    Expect<Boolean>(TerminateChildProcess(Child)).ToBe(True);
    { An exited child answers a zero allowance without waiting. }
    StartedAt := GetTickCount64;
    Expect<Boolean>(WaitForChildExit(Child, 0)).ToBe(True);
    Expect<Boolean>(GetTickCount64 - StartedAt < 1000).ToBe(True);
  finally
    ReapChild(Child, CHILD_KILL_MILLISECONDS);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestOwnedTreeIsTerminatedWithItsDescendants;
var
  Child: TProcess;
  DescendantPID: Integer;
  PIDPath: string;
begin
  PIDPath := FScratch + '/holder-descendant-pid';
  Child := SelfChild([HolderSwitch, PIDPath], []);
  DescendantPID := 0;
  try
    { The holder forwards nothing, so Unix needs its own process group. }
    ExecuteOwnedChild(Child, True);
    DescendantPID := WaitForDescendantPID(PIDPath);
    Expect<Boolean>(ProcessIsLive(DescendantPID)).ToBe(True);
    Expect<Boolean>(TerminateChildProcess(Child)).ToBe(True);
    Expect<Boolean>(DescendantGone(DescendantPID)).ToBe(True);
  finally
    { The whole owned tree, whatever an assertion above left running. }
    TerminateChildProcess(Child);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestFinishChildReportsASurvivingDescendant;
var
  Child: TProcess;
  DescendantPID: Integer;
  Failure, PIDPath: string;
begin
  PIDPath := FScratch + '/finish-survivor-pid';
  Child := SelfChild([SurvivorSwitch, PIDPath], []);
  try
    ExecuteOwnedChild(Child, True);
    Failure := '';
    try
      FinishChild(Child, CaseTimeoutMilliseconds, 'survivor spawner');
    except
      on E: EChildProcessSurvivors do Failure := E.Message;
    end;
    DescendantPID := WaitForDescendantPID(PIDPath);
    Expect<Boolean>(Pos('pid ' + IntToStr(DescendantPID) + ' (', Failure) > 0)
      .ToBe(True);
    { Reported first, then ended by the owned tree. }
    Expect<Boolean>(TerminateChildProcess(Child)).ToBe(True);
    Expect<Boolean>(DescendantGone(DescendantPID)).ToBe(True);
  finally
    { The whole owned tree, unconditionally: a failed assertion above must
      not leave the surviving sleeper running in its own group. }
    TerminateChildProcess(Child);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.
  TestFinishChildToleratesADescendantEndingWithinTheSettle;
var
  Child: TProcess;
  DescendantPID, ExitCode: Integer;
  Failure, PIDPath: string;
begin
  { The settle period's other half: a member that ends shortly after the
    child returned is not a survivor, so it neither fails the wait nor
    needs the helper's cleanup. }
  PIDPath := FScratch + '/brief-descendant-pid';
  Child := SelfChild([BriefSwitch, PIDPath], []);
  try
    ExecuteOwnedChild(Child, True);
    Failure := '';
    ExitCode := -1;
    try
      ExitCode := FinishChild(Child, CaseTimeoutMilliseconds,
        'brief spawner');
    except
      on E: EChildProcessSurvivors do Failure := E.Message;
    end;
    Expect<string>(Failure).ToBe('');
    Expect<Integer>(ExitCode).ToBe(0);
    DescendantPID := WaitForDescendantPID(PIDPath);
    Expect<Boolean>(DescendantGone(DescendantPID)).ToBe(True);
  finally
    TerminateChildProcess(Child);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestReapChildEndsAnOwnedTreesSurvivor;
var
  Child: TProcess;
  DescendantPID: Integer;
  PIDPath: string;
begin
  { Cleanup must not rely on listing survivors, which Darwin cannot: the
    parent has exited, its descendant still runs in the owned tree, and
    ReapChild has to end it on every platform. }
  PIDPath := FScratch + '/reap-survivor-pid';
  Child := SelfChild([SurvivorSwitch, PIDPath], []);
  try
    ExecuteOwnedChild(Child, True);
    DescendantPID := WaitForDescendantPID(PIDPath);
    Expect<Boolean>(WaitForChildExit(Child, CaseTimeoutMilliseconds))
      .ToBe(True);
    Expect<Boolean>(ProcessIsLive(DescendantPID)).ToBe(True);
    Expect<Boolean>(ReapChild(Child, CaseTimeoutMilliseconds)).ToBe(True);
    Expect<Boolean>(DescendantGone(DescendantPID)).ToBe(True);
  finally
    TerminateChildProcess(Child);
    Child.Free;
  end;
end;

procedure TProcessSupportTests.TestRunLwptReportsASurvivingDescendant;
var
  DescendantPID: Integer;
  Failure, PIDPath, SavedBinary: string;
begin
  { RunLwpt owns its child through a Job Object on Windows; a descendant
    that outlives it must fail the run instead of dying with the job. }
  PIDPath := FScratch + '/run-survivor-pid';
  SavedBinary := LwptBinaryPath;
  SetLwptBinaryPath(ExpandFileName(ParamStr(0)));
  Failure := '';
  try
    try
      RunLwpt([SurvivorSwitch, PIDPath], '');
    except
      on E: ELwptRunSurvivors do Failure := E.Message;
    end;
  finally
    SetLwptBinaryPath(SavedBinary);
  end;
  DescendantPID := WaitForDescendantPID(PIDPath);
  Expect<Boolean>(Pos('pid ' + IntToStr(DescendantPID) + ' (', Failure) > 0)
    .ToBe(True);
  { Freeing the child closed its kill-on-close job. }
  Expect<Boolean>(DescendantGone(DescendantPID)).ToBe(True);
end;

procedure TProcessSupportTests.SetupTests;
begin
  Test('a draining wait takes both overfull pipes',
    TestDrainingWaitTakesBothOverfullPipes);
  Test('FinishChild and ReapChild without output still drain',
    TestWaitsWithoutOutputStillDrain);
  Test('a timed-out child is terminated and reported',
    TestTimedOutChildIsTerminatedAndReported);
  Test('a zero allowance does not block', TestZeroAllowanceDoesNotBlock);
  Test('an owned tree is terminated with its descendants',
    TestOwnedTreeIsTerminatedWithItsDescendants);
  {$IF DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  Test('FinishChild reports a descendant that outlives an owned child',
    TestFinishChildReportsASurvivingDescendant);
  Test('FinishChild tolerates a descendant that ends within the settle '
    + 'period', TestFinishChildToleratesADescendantEndingWithinTheSettle);
  {$ELSE}
  Skip('FinishChild reports a descendant that outlives an owned child',
    TestFinishChildReportsASurvivingDescendant,
    'survivors are listed from a Job Object or Linux procfs');
  Skip('FinishChild tolerates a descendant that ends within the settle '
    + 'period', TestFinishChildToleratesADescendantEndingWithinTheSettle,
    'survivors are listed from a Job Object or Linux procfs');
  {$ENDIF}
  Test('ReapChild ends the surviving descendant of an exited owned child',
    TestReapChildEndsAnOwnedTreesSurvivor);
  {$IFDEF MSWINDOWS}
  Test('RunLwpt reports a descendant that outlives its child',
    TestRunLwptReportsASurvivingDescendant);
  {$ELSE}
  Skip('RunLwpt reports a descendant that outlives its child',
    TestRunLwptReportsASurvivingDescendant,
    'RunLwpt owns its child through a Job Object only on Windows');
  {$ENDIF}
end;

begin
  if RunChildMode then Exit;
  TestRunnerProgram.AddSuite(TProcessSupportTests.Create(
    'process support: bounded child waits'));
  TestRunnerProgram.Run;
end.
