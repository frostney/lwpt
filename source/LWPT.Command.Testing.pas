{ LWPT.Command.Testing — test subcommand entrypoint. }
unit LWPT.Command.Testing;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

function CmdTest(const AManifestPath: string; AIncludeE2E: Boolean;
  AJobs, ABail: Integer): Integer;

implementation

uses
  Classes,
  Process,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest,
  LWPT.WorkerBudget;

type
  TTestJobStatus = (tjsPending, tjsCompiling, tjsRunning, tjsPassed,
    tjsCompileFailed, tjsRunFailed, tjsSkipped, tjsCancelled,
    tjsWorkerError);

  TTestJob = record
    Source: string;
    Binary: string;
    CompileOutput: string;
    RunOutput: string;
    ErrorMessage: string;
    ExitCode: Integer;
    Status: TTestJobStatus;
    ActiveProcess: TProcess;
  end;

  TTestScheduler = class;

  TTestWorker = class(TThread)
  private
    FScheduler: TTestScheduler;
  protected
    procedure Execute; override;
  public
    constructor Create(AScheduler: TTestScheduler);
  end;

  TTestScheduler = class
  private
    FJobs: array of TTestJob;
    FUnitPaths: TStringArray;
    FBuildRoot: string;
    FBail: Integer;
    FNextIndex: Integer;
    FFailureCount: Integer;
    FCancelled: Boolean;
    FInternalError: string;
    FCriticalSection: TRTLCriticalSection;
    FBudgetSession: TLWPTWorkerBudgetSession;
    FWorkers: TList;
    function ClaimJob(out AIndex: Integer): Boolean;
    function AcquireLease: TLWPTWorkerLease;
    function StartProcess(AIndex: Integer; AProcess: TProcess): Boolean;
    procedure FinishProcess(AIndex: Integer; AProcess: TProcess);
    function RunProcess(AIndex: Integer; AProcess: TProcess;
      out AOutput: string): Integer;
    procedure SetJobStage(AIndex: Integer; AStatus: TTestJobStatus;
      const ABinary: string = '');
    procedure SetJobOutput(AIndex: Integer; ACompileStage: Boolean;
      const AOutput: string);
    procedure CompleteJob(AIndex: Integer; AStatus: TTestJobStatus;
      AExitCode: Integer = 0);
    procedure FailJob(AIndex: Integer; AStatus: TTestJobStatus;
      AExitCode: Integer; const AMessage: string = '');
    procedure AbortWithError(AIndex: Integer; const AMessage: string);
    procedure CancelPendingAndActiveLocked;
    function IsCancelled: Boolean;
    procedure RunOne(AIndex: Integer; ALease: TLWPTWorkerLease);
  public
    constructor Create(ATests: TStringList; AIncludeE2E: Boolean;
      const AUnitPaths: TStringArray; const ABuildRoot: string;
      AJobs, ABail: Integer);
    destructor Destroy; override;
    procedure Run;
    procedure PrintResults(const AProjectRoot: string; out APassed,
      AFailed, ACompileFailed, ASkipped, ACancelled: Integer);
    property InternalError: string read FInternalError;
  end;

{ Standard set of directories the discovery walks must NOT descend into. }
function IsExcludedDir(const AName: string): Boolean; inline;
begin
  Result := (AName = LWPT_DIR) or (AName = 'build') or (AName = '.git');
end;

procedure CollectTestFiles(const ADir: string; AList: TStringList);
var
  Search: TSearchRec;
  Base: string;
begin
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        if not IsExcludedDir(Search.Name) then
          CollectTestFiles(Base + Search.Name, AList);
      end
      else if (Length(Search.Name) > 9)
        and SameText(Copy(Search.Name, Length(Search.Name) - 8, 9),
          '.Test.pas') then
        AList.Add(Base + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function IsE2ETestPath(const APath: string): Boolean; inline;
var
  Normalised: string;
begin
  Normalised := StringReplace(APath, '\', '/', [rfReplaceAll]);
  Result := (Pos('/tests/e2e/', Normalised) > 0)
         or (Pos('tests/e2e/', Normalised) = 1);
end;

function DrainProcessOutput(AProcess: TProcess): string;
var
  Buffer: array[0..4095] of Char;
  Count: LongInt;
  Chunk: string;
begin
  Result := '';
  while AProcess.Output.NumBytesAvailable > 0 do
  begin
    Count := AProcess.Output.Read(Buffer[0], SizeOf(Buffer));
    if Count <= 0 then Break;
    SetString(Chunk, PChar(@Buffer[0]), Count);
    Result := Result + Chunk;
  end;
end;

procedure CopyCurrentEnvironment(AEnvironment: TStrings);
var
  i: Integer;
begin
  for i := 1 to GetEnvironmentVariableCount do
    AEnvironment.Add(GetEnvironmentString(i));
end;

constructor TTestWorker.Create(AScheduler: TTestScheduler);
begin
  FScheduler := AScheduler;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TTestWorker.Execute;
var
  Index: Integer;
  Lease: TLWPTWorkerLease;
begin
  Index := -1;
  try
    while FScheduler.ClaimJob(Index) do
    begin
      Lease := FScheduler.AcquireLease;
      if Lease = nil then
      begin
        FScheduler.CompleteJob(Index, tjsCancelled);
        Break;
      end;
      try
        FScheduler.RunOne(Index, Lease);
      finally
        Lease.Free;
      end;
      Index := -1;
    end;
  except
    on E: Exception do
      FScheduler.AbortWithError(Index, E.Message);
  end;
end;

constructor TTestScheduler.Create(ATests: TStringList;
  AIncludeE2E: Boolean; const AUnitPaths: TStringArray;
  const ABuildRoot: string; AJobs, ABail: Integer);
var
  i, Runnable, RequestedWorkers: Integer;
begin
  inherited Create;
  InitCriticalSection(FCriticalSection);
  FWorkers := TList.Create;
  FBuildRoot := ABuildRoot;
  FBail := ABail;
  FNextIndex := 0;
  FFailureCount := 0;
  FCancelled := False;
  SetLength(FUnitPaths, Length(AUnitPaths));
  for i := 0 to High(AUnitPaths) do FUnitPaths[i] := AUnitPaths[i];
  SetLength(FJobs, ATests.Count);
  Runnable := 0;
  for i := 0 to ATests.Count - 1 do
  begin
    FJobs[i].Source := ATests[i];
    if (not AIncludeE2E) and IsE2ETestPath(ATests[i]) then
      FJobs[i].Status := tjsSkipped
    else
    begin
      FJobs[i].Status := tjsPending;
      Inc(Runnable);
    end;
  end;
  if Runnable = 0 then Exit;
  if AJobs = 0 then RequestedWorkers := Runnable
  else if AJobs < Runnable then RequestedWorkers := AJobs
  else RequestedWorkers := Runnable;
  FBudgetSession := TLWPTWorkerBudgetSession.Create(NewWorkerSessionId,
    RequestedWorkers);
  for i := 1 to FBudgetSession.RequestedWorkers do
    FWorkers.Add(TTestWorker.Create(Self));
end;

destructor TTestScheduler.Destroy;
var
  i: Integer;
begin
  for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).Free;
  FWorkers.Free;
  FBudgetSession.Free;
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

function TTestScheduler.ClaimJob(out AIndex: Integer): Boolean;
begin
  Result := False;
  AIndex := -1;
  EnterCriticalSection(FCriticalSection);
  try
    if FCancelled then Exit;
    while FNextIndex <= High(FJobs) do
    begin
      AIndex := FNextIndex;
      Inc(FNextIndex);
      if FJobs[AIndex].Status = tjsPending then
      begin
        FJobs[AIndex].Status := tjsCompiling;
        Exit(True);
      end;
    end;
    AIndex := -1;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.AcquireLease: TLWPTWorkerLease;
begin
  Result := nil;
  while not IsCancelled do
  begin
    Result := FBudgetSession.Acquire(100);
    if Result <> nil then Exit;
  end;
end;

function TTestScheduler.StartProcess(AIndex: Integer;
  AProcess: TProcess): Boolean;
begin
  Result := False;
  EnterCriticalSection(FCriticalSection);
  try
    if FCancelled then Exit;
    FJobs[AIndex].ActiveProcess := AProcess;
    try
      AProcess.Execute;
    except
      FJobs[AIndex].ActiveProcess := nil;
      raise;
    end;
    Result := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.FinishProcess(AIndex: Integer;
  AProcess: TProcess);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if FJobs[AIndex].ActiveProcess = AProcess then
      FJobs[AIndex].ActiveProcess := nil;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.RunProcess(AIndex: Integer; AProcess: TProcess;
  out AOutput: string): Integer;
begin
  Result := 1;
  AOutput := '';
  AProcess.Options := [poUsePipes, poStderrToOutPut];
  if not StartProcess(AIndex, AProcess) then Exit;
  try
    while AProcess.Running do
    begin
      if AProcess.Output.NumBytesAvailable > 0 then
        AOutput := AOutput + DrainProcessOutput(AProcess);
      Sleep(10);
    end;
    if AProcess.Output.NumBytesAvailable > 0 then
      AOutput := AOutput + DrainProcessOutput(AProcess);
    AProcess.WaitOnExit;
    { The Running poll above usually reaps the child with the raw
      status, where ExitCode decodes correctly — but a signal death
      still reads as 0 there, and losing the race to WaitOnExit drops
      nonzero exits too (see NormalisedExitCode). A crashed test
      binary must never count as a pass. }
    Result := NormalisedExitCode(AProcess);
  finally
    FinishProcess(AIndex, AProcess);
  end;
end;

procedure TTestScheduler.SetJobStage(AIndex: Integer;
  AStatus: TTestJobStatus; const ABinary: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if FCancelled then
      FJobs[AIndex].Status := tjsCancelled
    else
    begin
      FJobs[AIndex].Status := AStatus;
      if ABinary <> '' then FJobs[AIndex].Binary := ABinary;
    end;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.SetJobOutput(AIndex: Integer;
  ACompileStage: Boolean; const AOutput: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if ACompileStage then FJobs[AIndex].CompileOutput := AOutput
    else FJobs[AIndex].RunOutput := AOutput;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.CompleteJob(AIndex: Integer;
  AStatus: TTestJobStatus; AExitCode: Integer);
begin
  if AIndex < 0 then Exit;
  EnterCriticalSection(FCriticalSection);
  try
    FJobs[AIndex].Status := AStatus;
    FJobs[AIndex].ExitCode := AExitCode;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.CancelPendingAndActiveLocked;
var
  i: Integer;
begin
  FCancelled := True;
  for i := 0 to High(FJobs) do
  begin
    if FJobs[i].Status = tjsPending then
      FJobs[i].Status := tjsCancelled;
    if FJobs[i].ActiveProcess <> nil then
      try
        FJobs[i].ActiveProcess.Terminate(1);
      except
        on E: Exception do
          if FJobs[i].ErrorMessage = '' then
            FJobs[i].ErrorMessage := 'termination failed: ' + E.Message;
      end;
  end;
end;

procedure TTestScheduler.FailJob(AIndex: Integer;
  AStatus: TTestJobStatus; AExitCode: Integer; const AMessage: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    FJobs[AIndex].Status := AStatus;
    FJobs[AIndex].ExitCode := AExitCode;
    FJobs[AIndex].ErrorMessage := AMessage;
    Inc(FFailureCount);
    if (FBail > 0) and (FFailureCount >= FBail) then
      CancelPendingAndActiveLocked;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.AbortWithError(AIndex: Integer;
  const AMessage: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if (AIndex >= 0) and (AIndex <= High(FJobs)) then
    begin
      FJobs[AIndex].Status := tjsWorkerError;
      FJobs[AIndex].ErrorMessage := AMessage;
    end;
    if FInternalError = '' then FInternalError := AMessage;
    CancelPendingAndActiveLocked;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.IsCancelled: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FCancelled;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.RunOne(AIndex: Integer;
  ALease: TLWPTWorkerLease);
var
  CompilerProcess, TestProcess: TProcess;
  Binary, Output: string;
  Code: Integer;
begin
  try
    CompilerProcess := CreatePascalCompilerProcess(FJobs[AIndex].Source,
      FUnitPaths, Binary, FBuildRoot);
  except
    { A staging path over the compiler's budget fails this one test with
      the explanatory message instead of aborting the whole scheduler. }
    on E: ELWPTError do
    begin
      SetJobOutput(AIndex, True, E.Message);
      FailJob(AIndex, tjsCompileFailed, 1, E.Message);
      Exit;
    end;
  end;
  try
    Code := RunProcess(AIndex, CompilerProcess, Output);
  finally
    CompilerProcess.Free;
  end;
  SetJobOutput(AIndex, True, Output);
  if IsCancelled then
  begin
    CompleteJob(AIndex, tjsCancelled);
    Exit;
  end;
  if Code <> 0 then
  begin
    FailJob(AIndex, tjsCompileFailed, Code);
    Exit;
  end;

  {$IFDEF MSWINDOWS}
  if (not FileExists(Binary)) and FileExists(Binary + '.exe') then
    Binary := Binary + '.exe';
  {$ENDIF}
  SetJobStage(AIndex, tjsRunning, Binary);
  if IsCancelled then
  begin
    CompleteJob(AIndex, tjsCancelled);
    Exit;
  end;
  TestProcess := TProcess.Create(nil);
  try
    TestProcess.Executable := Binary;
    CopyCurrentEnvironment(TestProcess.Environment);
    AppendWorkerLeaseEnvironment(TestProcess.Environment, ALease);
    Code := RunProcess(AIndex, TestProcess, Output);
  finally
    TestProcess.Free;
  end;
  SetJobOutput(AIndex, False, Output);
  if IsCancelled then
    CompleteJob(AIndex, tjsCancelled)
  else if Code = 0 then
    CompleteJob(AIndex, tjsPassed)
  else
    FailJob(AIndex, tjsRunFailed, Code);
end;

procedure TTestScheduler.Run;
var
  i: Integer;
begin
  for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).Start;
  for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).WaitFor;
end;

procedure WriteCapturedOutput(const AOutput: string);
begin
  if AOutput = '' then Exit;
  Write(AOutput);
  if not (AOutput[Length(AOutput)] in [#10, #13]) then WriteLn;
end;

procedure TTestScheduler.PrintResults(const AProjectRoot: string;
  out APassed, AFailed, ACompileFailed, ASkipped, ACancelled: Integer);
var
  i: Integer;
  DisplayPath: string;
begin
  APassed := 0;
  AFailed := 0;
  ACompileFailed := 0;
  ASkipped := 0;
  ACancelled := 0;
  for i := 0 to High(FJobs) do
  begin
    DisplayPath := ExtractRelativePath(
      IncludeTrailingPathDelimiter(AProjectRoot), FJobs[i].Source);
    Write('  ', DisplayPath, ' ... ');
    case FJobs[i].Status of
      tjsPassed:
        begin
          WriteLn('pass');
          Inc(APassed);
        end;
      tjsCompileFailed:
        begin
          WriteLn('COMPILE FAILED');
          Inc(ACompileFailed);
        end;
      tjsRunFailed:
        begin
          WriteLn('FAIL (exit ', FJobs[i].ExitCode, ')');
          Inc(AFailed);
        end;
      tjsSkipped:
        begin
          WriteLn('skipped (e2e tier)');
          Inc(ASkipped);
        end;
      tjsCancelled:
        begin
          WriteLn('cancelled (bail threshold reached)');
          Inc(ACancelled);
        end;
      tjsWorkerError:
        begin
          WriteLn('ERROR (', FJobs[i].ErrorMessage, ')');
          Inc(AFailed);
        end;
    else
      begin
        WriteLn('cancelled');
        Inc(ACancelled);
      end;
    end;
    if FJobs[i].Status = tjsCompileFailed then
      WriteCapturedOutput(FJobs[i].CompileOutput);
    if FJobs[i].RunOutput <> '' then
      WriteCapturedOutput(FJobs[i].RunOutput);
    if FJobs[i].ErrorMessage <> '' then
      WriteLn('    ', FJobs[i].ErrorMessage);
  end;
end;

{ Test sources become session staging keys the same way build targets do.
  Distinct sources sharing one key would silently share compiler staging —
  the interference the private-session design exists to rule out — so the
  scheduler refuses the run before any worker starts, mirroring the build
  path's FindArtefactDirCollision. }
function FindTestStagingKeyCollision(const ATests: TStringList;
  out AFirst, ASecond: string): Boolean;
var
  i, j: Integer;
begin
  for i := 0 to ATests.Count - 1 do
    for j := i + 1 to ATests.Count - 1 do
      if SameText(BuildSessionPathKey(ATests[i]),
                  BuildSessionPathKey(ATests[j])) then
      begin
        AFirst := ATests[i];
        ASecond := ATests[j];
        Exit(True);
      end;
  Result := False;
end;

function CmdTest(const AManifestPath: string; AIncludeE2E: Boolean;
  AJobs, ABail: Integer): Integer;
const
  TESTS_SUPPORT_DIR = 'tests/support';
var
  Man: TManifest;
  Tests: TStringList;
  UnitPaths: TStringArray;
  ModulesRoot, ProjectRoot, CollisionFirst, CollisionSecond: string;
  i, n, Passed, Failed, Skipped, CompileFailed, Cancelled: Integer;
  Session: TLWPTBuildSession;
  Scheduler: TTestScheduler;
begin
  Man := LoadManifest(AManifestPath);
  if ABail < 0 then ABail := Man.TestBail;
  ProjectRoot := ExtractFileDir(ExpandFileName(AManifestPath));
  Session := TLWPTBuildSession.Create(ProjectRoot);
  try
    WriteLn('test session: ', Session.SessionID);
    RunHooks('pretest', Man.PreTest, Session.HookRoot);

    ModulesRoot := ResolveModulesDir(Man);
    SetLength(UnitPaths, 0);
    for i := 0 to High(Man.Units) do
    begin
      n := Length(UnitPaths);
      SetLength(UnitPaths, n + 1);
      UnitPaths[n] := Man.Units[i];
    end;
    n := Length(UnitPaths);
    SetLength(UnitPaths, n + 1);
    UnitPaths[n] := ModulesRoot;
    if DirectoryExists(TESTS_SUPPORT_DIR) then
    begin
      n := Length(UnitPaths);
      SetLength(UnitPaths, n + 1);
      UnitPaths[n] := TESTS_SUPPORT_DIR;
    end;

    Tests := TStringList.Create;
    try
      for i := 0 to High(Man.Units) do CollectTestFiles(Man.Units[i], Tests);
      CollectTestFiles('.', Tests);
      for i := 0 to Tests.Count - 1 do Tests[i] := ExpandFileName(Tests[i]);
      Tests.Sort;
      i := Tests.Count - 1;
      while i > 0 do
      begin
        if Tests[i] = Tests[i - 1] then Tests.Delete(i);
        Dec(i);
      end;

      if Tests.Count = 0 then
      begin
        WriteLn('no *.Test.pas files found');
        Result := 0;
        RunHooks('posttest', Man.PostTest, Session.HookRoot);
        Session.Finish(True);
        Exit;
      end;

      if FindTestStagingKeyCollision(Tests, CollisionFirst,
        CollisionSecond) then
      begin
        WriteLn(ErrOutput, PROGRAM_NAME, ' test: test sources "',
          CollisionFirst, '" and "', CollisionSecond,
          '" map to the same session staging key ',
          BuildSessionPathKey(CollisionFirst), ' — rename one');
        Result := 1;
        { Mirror the other exit paths: posttest cleanup/reporting hooks
          run even when the scheduler never starts. }
        RunHooks('posttest', Man.PostTest, Session.HookRoot);
        Session.Finish(False, 'test staging key collision');
        Exit;
      end;

      WriteLn('discovered ', Tests.Count, ' test file(s)');
      if not AIncludeE2E then
        WriteLn('  (e2e tier skipped; pass --tier=e2e to include)');
      Scheduler := TTestScheduler.Create(Tests, AIncludeE2E, UnitPaths,
        Session.JobRoot('tests'), AJobs, ABail);
      try
        Scheduler.Run;
        Scheduler.PrintResults(ProjectRoot, Passed, Failed, CompileFailed,
          Skipped, Cancelled);
        if Scheduler.InternalError <> '' then
          WriteLn(ErrOutput, PROGRAM_NAME, ' test: scheduler error: ',
            Scheduler.InternalError);
      finally
        Scheduler.Free;
      end;

      WriteLn;
      Write(Passed, ' passed, ', Failed, ' failed, ', CompileFailed,
        ' did not compile');
      if Skipped > 0 then Write(', ', Skipped, ' skipped');
      if Cancelled > 0 then Write(', ', Cancelled, ' cancelled');
      WriteLn;
      if (Failed = 0) and (CompileFailed = 0) and (Cancelled = 0) then
        Result := 0
      else
        Result := 1;
    finally
      Tests.Free;
    end;

    RunHooks('posttest', Man.PostTest, Session.HookRoot);
    Session.Finish(Result = 0, IntToStr(Failed) + ' failed, '
      + IntToStr(CompileFailed) + ' did not compile, '
      + IntToStr(Cancelled) + ' cancelled');
  finally
    Session.Free;
  end;
end;

end.
