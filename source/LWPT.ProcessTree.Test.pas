{ Unix process-group isolation contract for managed process trees. The same
  executable acts as the spawned child and reports the process group it runs
  in, so the spawn cases observe the real kernel state after LWPT's setup.
  Scripted setpgid(2) outcomes and raw group-query results replay the Darwin
  race from #299 beneath the production classification, and pin the bounded
  retry and its pauses on both sides. }
program LWPT.ProcessTree.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.ProcessRunner,
  LWPT.ProcessTree,
  TestingPascalLibrary;

const
  ReportGroupSwitch = '--process-tree-report-group';
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

{$IFDEF UNIX}
type
  TSpawnResult = record
    ExitCode: Integer;
    Stdout: string;
    Stderr: string;
    ErrorMessage: string;
  end;

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
  {$IFDEF UNIX}
  if ParamStr(1) = ReportGroupSwitch then
  begin
    WriteLn(FpGetpid, ' ', FpGetpgrp);
    Halt(0);
  end;
  TestRunnerProgram.AddSuite(TProcessTreeIsolation.Create(
    PROJECT_NAME + '.ProcessTree: Unix process-group isolation'));
  {$ENDIF}
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
