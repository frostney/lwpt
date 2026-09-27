{ Unix process-group isolation contract for managed process trees. The same
  executable acts as the spawned child and reports the process group it runs
  in, so the spawn cases observe the real kernel state after LWPT's setup.
  Scripted setpgid(2) outcomes replay the Darwin race from #299 and pin the
  bounded retry on both sides. }
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
    procedure AfterEach; override;
    procedure SetupTests; override;
    procedure TestChildLeadsItsOwnGroup;
    procedure TestChildToleratesEPERMAfterItsCallApplied;
    procedure TestParentToleratesEPERMAfterItsCallApplied;
    procedure TestParentRetriesUntilTheGroupExists;
    procedure TestParentStopsAfterExactAttemptBudget;
    procedure TestParentAcceptsAChildThatAlreadyExited;
    procedure TestChildRetriesUntilItLeadsItsGroup;
    procedure TestChildStopsAfterExactAttemptBudget;
    procedure TestParentFailsWhenTheGroupNeverAppears;
    procedure TestChildExitsWithSetupCodeWhenItCannotIsolate;
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

procedure TProcessTreeIsolation.AfterEach;
begin
  ProcessTreeChildGroupScript := Default(TLWPTProcessGroupScript);
  ProcessTreeParentGroupScript := Default(TLWPTProcessGroupScript);
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
  ProcessTreeParentGroupScript.RejectedCalls := ScriptedRejections;
  ProcessTreeParentGroupScript.HiddenQueries := ScriptedRejections;
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(ScriptedRejections + 1);
  Expect<Integer>(ProcessTreeParentGroupScript.Queries)
    .ToBe(ScriptedRejections);
end;

procedure TProcessTreeIsolation.TestParentStopsAfterExactAttemptBudget;
var
  ErrorCode: Integer;
begin
  ProcessTreeParentGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeParentGroupScript.HiddenQueries := AlwaysScripted;
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(False);
  Expect<Integer>(ErrorCode).ToBe(ESysEPERM);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(ProcessTreeGroupSetupAttempts);
  Expect<Integer>(ProcessTreeParentGroupScript.Queries)
    .ToBe(ProcessTreeGroupSetupAttempts);
end;

procedure TProcessTreeIsolation.TestParentAcceptsAChildThatAlreadyExited;
var
  ErrorCode: Integer;
begin
  ProcessTreeParentGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeParentGroupScript.HiddenQueries := AlwaysScripted;
  ProcessTreeParentGroupScript.HiddenQueriesReportExit := True;
  Expect<Boolean>(IsolateChildProcessGroup(FpGetpid, ErrorCode)).ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls).ToBe(1);
end;

procedure TProcessTreeIsolation.TestChildRetriesUntilItLeadsItsGroup;
begin
  ExpectLeadsOwnGroup;
  ProcessTreeChildGroupScript.RejectedCalls := ScriptedRejections;
  ProcessTreeChildGroupScript.HiddenQueries := ScriptedRejections;
  Expect<Boolean>(LeadOwnProcessGroupAfterFork).ToBe(True);
  Expect<Integer>(ProcessTreeChildGroupScript.Calls)
    .ToBe(ScriptedRejections + 1);
  Expect<Integer>(ProcessTreeChildGroupScript.Queries)
    .ToBe(ScriptedRejections);
end;

procedure TProcessTreeIsolation.TestChildStopsAfterExactAttemptBudget;
var
  Started: QWord;
begin
  ProcessTreeChildGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeChildGroupScript.HiddenQueries := AlwaysScripted;
  Started := GetTickCount64;
  Expect<Boolean>(LeadOwnProcessGroupAfterFork).ToBe(False);
  Expect<Integer>(ProcessTreeChildGroupScript.Calls)
    .ToBe(ProcessTreeGroupSetupAttempts);
  Expect<Integer>(ProcessTreeChildGroupScript.Queries)
    .ToBe(ProcessTreeGroupSetupAttempts);
  { The pre-exec pause really waits between attempts. The bound allows one
    millisecond of tick truncation. }
  Expect<Boolean>(GetTickCount64 - Started
    >= QWord((ProcessTreeGroupSetupAttempts - 2)
      * ProcessTreeGroupSetupRetryMilliseconds)).ToBe(True);
end;

procedure TProcessTreeIsolation.TestParentFailsWhenTheGroupNeverAppears;
var
  R: TSpawnResult;
begin
  ProcessTreeParentGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeParentGroupScript.HiddenQueries := AlwaysScripted;
  R := SpawnReporter;
  Expect<Boolean>(Pos('could not isolate process tree', R.ErrorMessage) > 0)
    .ToBe(True);
  Expect<Integer>(ProcessTreeParentGroupScript.Calls)
    .ToBe(ProcessTreeGroupSetupAttempts);
end;

procedure TProcessTreeIsolation.TestChildExitsWithSetupCodeWhenItCannotIsolate;
var
  R: TSpawnResult;
begin
  ProcessTreeChildGroupScript.RejectedCalls := AlwaysScripted;
  ProcessTreeChildGroupScript.HiddenQueries := AlwaysScripted;
  R := SpawnReporter;
  Expect<string>(R.ErrorMessage).ToBe('');
  Expect<Integer>(R.ExitCode).ToBe(ProcessTreeSetupExitCode);
  Expect<Boolean>(Pos(ProcessTreeSetupFailure, R.Stderr) > 0).ToBe(True);
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
  Test('parent stops after the exact attempt budget',
    TestParentStopsAfterExactAttemptBudget);
  Test('parent accepts a child that exited before the group check',
    TestParentAcceptsAChildThatAlreadyExited);
  Test('child retries until it leads its group',
    TestChildRetriesUntilItLeadsItsGroup);
  Test('child stops after the exact attempt budget with real pauses',
    TestChildStopsAfterExactAttemptBudget);
  Test('parent fails when the child group never appears',
    TestParentFailsWhenTheGroupNeverAppears);
  Test('child exits with the setup code when it cannot isolate',
    TestChildExitsWithSetupCodeWhenItCannotIsolate);
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
