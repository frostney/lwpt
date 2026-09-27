{ Unix process-group isolation contract for managed process trees. The same
  executable acts as the spawned child and reports the process group it runs
  in, so every case observes the real kernel state after LWPT's setup. }
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
  REPORT_GROUP_SWITCH = '--process-tree-report-group';

{$IFDEF UNIX}
type
  TProcessTreeIsolation = class(TTestSuite)
  public
    procedure AfterEach; override;
    procedure SetupTests; override;
    procedure TestChildLeadsItsOwnGroup;
    procedure TestChildToleratesEPERMAfterParentIsolatedIt;
    procedure TestParentToleratesEPERMAfterChildIsolatedItself;
    procedure TestIneffectiveSetupStillFails;
  end;

function CSetProcessGroup(const APID,
  AProcessGroupID: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setpgid';
  {$ELSE}
  external name 'setpgid';
  {$ENDIF}

function CErrnoLocation: PInteger; cdecl;
  {$IFDEF LINUX}
  external 'c' name '__errno_location';
  {$ELSE}
  external name '__error';
  {$ENDIF}

{ Darwin can apply one side of the parent/child setpgid(2) race and still
  report EPERM to the other side (#299). These hooks reproduce that outcome
  deterministically: the group change takes effect, the caller sees EPERM. }
function EffectiveButRejectedInChild(const APID,
  AProcessGroupID: LongInt): LongInt;
begin
  Result := CSetProcessGroup(APID, AProcessGroupID);
  if APID <> 0 then Exit;
  CErrnoLocation()^ := ESysEPERM;
  Result := -1;
end;

function EffectiveButRejectedInParent(const APID,
  AProcessGroupID: LongInt): LongInt;
begin
  Result := CSetProcessGroup(APID, AProcessGroupID);
  if APID = 0 then Exit;
  CErrnoLocation()^ := ESysEPERM;
  Result := -1;
end;

function IneffectiveAndRejected(const APID,
  AProcessGroupID: LongInt): LongInt;
begin
  CErrnoLocation()^ := ESysEPERM;
  Result := -1;
end;

type
  TSpawnResult = record
    ExitCode: Integer;
    Stdout: string;
    Stderr: string;
    ErrorMessage: string;
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
    P.Parameters.Add(REPORT_GROUP_SWITCH);
    Runner := TLWPTDuplexProcessRunner.Create(P);
    try
      Options := DefaultProcessRunOptions('process-tree isolation probe');
      Options.SeparateStandardError := True;
      Options.TimeoutMilliseconds := 30000;
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

procedure TProcessTreeIsolation.AfterEach;
begin
  ProcessTreeSetProcessGroupTestHook := nil;
end;

procedure TProcessTreeIsolation.TestChildLeadsItsOwnGroup;
begin
  ExpectIsolatedChild(SpawnReporter);
end;

procedure TProcessTreeIsolation.TestChildToleratesEPERMAfterParentIsolatedIt;
begin
  ProcessTreeSetProcessGroupTestHook := EffectiveButRejectedInChild;
  ExpectIsolatedChild(SpawnReporter);
end;

procedure TProcessTreeIsolation.TestParentToleratesEPERMAfterChildIsolatedItself;
begin
  ProcessTreeSetProcessGroupTestHook := EffectiveButRejectedInParent;
  ExpectIsolatedChild(SpawnReporter);
end;

procedure TProcessTreeIsolation.TestIneffectiveSetupStillFails;
var
  R: TSpawnResult;
begin
  ProcessTreeSetProcessGroupTestHook := IneffectiveAndRejected;
  R := SpawnReporter;
  { Whichever side observes the failure first reports it: the parent raises,
    or the child exits with the setup code before exec. }
  Expect<Boolean>((Pos('could not isolate process tree', R.ErrorMessage) > 0)
    or ((R.ExitCode = 127)
      and (Pos('process tree isolation setup failed', R.Stderr) > 0)))
    .ToBe(True);
end;

procedure TProcessTreeIsolation.SetupTests;
begin
  Test('managed child leads its own process group',
    TestChildLeadsItsOwnGroup);
  Test('child accepts EPERM once the parent has isolated it',
    TestChildToleratesEPERMAfterParentIsolatedIt);
  Test('parent accepts EPERM once the child has isolated itself',
    TestParentToleratesEPERMAfterChildIsolatedItself);
  Test('ineffective process-group setup still fails',
    TestIneffectiveSetupStillFails);
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  if ParamStr(1) = REPORT_GROUP_SWITCH then
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
