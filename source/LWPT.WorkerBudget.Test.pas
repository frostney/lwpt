{ LWPT.WorkerBudget.Test — cross-process coverage for the per-user worker
  coordinator. The test executable spawns itself from two different working
  directories so contention crosses the same boundary as separate worktrees. }
program LWPT.WorkerBudget.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.Scratch;

const
  CHILD_SWITCH = '--worker-budget-child';
  REACQUIRE_SWITCH = '--worker-budget-reacquire';
  NESTED_PARENT_SWITCH = '--worker-budget-nested-parent';
  NESTED_CHILD_SWITCH = '--worker-budget-nested-child';
  RELEASE_RETRY_SWITCH = '--worker-budget-release-retry';
  THREAD_SWITCH = '--worker-budget-threads';
  CORRUPT_OWNER_SWITCH = '--worker-budget-corrupt-owner';
  FANOUT_SWITCH = '--worker-budget-fanout';
  REUSE_SWITCH = '--worker-budget-token-reuse';
  ORPHAN_PARENT_SWITCH = '--worker-budget-orphan-parent';
  HOLD_CHILD_SWITCH = '--worker-budget-hold-child';
  DELEGATION_CRASH_SWITCH = '--worker-budget-delegation-crash';
  DELEGATION_RELEASE_SWITCH = '--worker-budget-delegation-release';
  SNAPSHOT_SWITCH = '--worker-budget-snapshot';
  REPAIR_SWITCH = '--worker-budget-repair';
  TEST_BUDGET = '1';
  TEST_STALE_SECONDS = '3';
  WAIT_TIMEOUT_MILLISECONDS = 10000;

type
  TLeaseThread = class(TThread)
  private
    FSession : TLWPTWorkerBudgetSession;
    FSuccess : Boolean;
    FError : string;
  protected
    procedure Execute; override;
  public
    constructor Create(ASession: TLWPTWorkerBudgetSession);
    property Success: Boolean read FSuccess;
    property ErrorText: string read FError;
  end;

  TWorkerBudgetProcesses = class(TTestSuite)
  private
    FScratch : string;
    procedure ResetScratch;
    function StartChild(const ASession, AWorktree, AAcquired,
      ARelease: string; ARequestedWorkers: Integer = 1): TProcess;
    function StartReacquirer(const ASession, AWorktree, AAcquiredPrefix,
      AReleasePrefix: string; ACycles: Integer): TProcess;
    procedure RunUtility(const ASwitch, AOutputPath: string);
    procedure RunUtilityWithBudget(const ASwitch, AOutputPath,
      ABudget: string);
    function WaitForSessionState(const ASession, AState: string;
      ATimeoutMilliseconds: Integer): Boolean;
    procedure StopChild(AProcess: TProcess);
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestContendersShareCapacityAndBothProgress;
    procedure TestRequestIsBoundedByMachineCapacity;
    procedure TestCrashedOwnerIsReclaimed;
    procedure TestHeartbeatPreservesLongRunningOwner;
    procedure TestLiveUnreadableRequestsFailClosed;
    procedure TestWaiterPrecedesRepeatedReacquire;
    procedure TestNestedProcessInheritsLease;
    procedure TestOneLeaseCannotFanOutToTwoChildren;
    procedure TestConsumedDelegationTokenCannotBeReused;
    procedure TestDelegatedChildRemainsCountedAfterParentDeath;
    procedure TestDelegatedChildCrashReturnsCapacity;
    procedure TestParentReleaseDoesNotCreateGhostGrant;
    procedure TestReleaseRetriesAfterWriteFailure;
    procedure TestSessionSupportsConcurrentSchedulerThreads;
  end;

constructor TLeaseThread.Create(ASession: TLWPTWorkerBudgetSession);
begin
  FSession := ASession;
  FSuccess := False;
  FError := '';
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TLeaseThread.Execute;
var
  Lease : TLWPTWorkerLease;
begin
  Lease := nil;
  try
    Lease := FSession.Acquire(WAIT_TIMEOUT_MILLISECONDS);
    if Lease = nil then
      raise Exception.Create('timed out acquiring worker lease');
    Sleep(100);
    Lease.Release;
    FSuccess := True;
  except
    on E: Exception do FError := E.Message;
  end;
  Lease.Free;
end;

function EnvName(const AEntry: string): string;
var
  Separator : Integer;
begin
  Separator := Pos('=', AEntry);
  if Separator = 0 then Result := AEntry
  else Result := Copy(AEntry, 1, Separator - 1);
end;

function EnvValue(AEnvironment: TStrings; const AName: string): string;
var
  i, Separator : Integer;
begin
  Result := '';
  for i := 0 to AEnvironment.Count - 1 do
    if SameText(EnvName(AEnvironment[i]), AName) then
    begin
      Separator := Pos('=', AEnvironment[i]);
      Exit(Copy(AEnvironment[i], Separator + 1, MaxInt));
    end;
end;

function IsWorkerOverride(const AEntry: string): Boolean;
begin
  Result := SameText(EnvName(AEntry), WORKER_STATE_DIR_ENV)
         or SameText(EnvName(AEntry), WORKER_BUDGET_ENV)
         or SameText(EnvName(AEntry), WORKER_STALE_SECONDS_ENV)
         or SameText(EnvName(AEntry), WORKER_LEASE_TOKEN_ENV);
end;

procedure WriteMarker(const APath, AText: string);
var
  Lines : TStringList;
  TmpRoot : string;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(AText);
    TmpRoot := ExtractFileDir(APath) + '/tmp-markers';
    AtomicWriteText(APath, TmpRoot, Lines);
  finally
    Lines.Free;
  end;
end;

function WaitForFile(const APath: string;
  ATimeoutMilliseconds: Integer): Boolean;
var
  Started : QWord;
begin
  Started := GetTickCount64;
  repeat
    if FileExists(APath) then Exit(True);
    Sleep(25);
  until GetTickCount64 - Started >= QWord(ATimeoutMilliseconds);
  Result := FileExists(APath);
end;

function WaitForPathGone(const APath: string;
  ATimeoutMilliseconds: Integer): Boolean;
var
  Started : QWord;
begin
  Started := GetTickCount64;
  repeat
    if not FileExists(APath) and not DirectoryExists(APath) then Exit(True);
    Sleep(25);
  until GetTickCount64 - Started >= QWord(ATimeoutMilliseconds);
  Result := not FileExists(APath) and not DirectoryExists(APath);
end;

procedure AddWorkerEnvironment(AProcess: TProcess;
  const AStateRoot: string; const ABudget: string = TEST_BUDGET); forward;

function RunChildMode: Boolean;
var
  i, GrantedTotal, Cycles : Integer;
  HasProcess, HasLease, FailedRelease, Refused : Boolean;
  Session : TLWPTWorkerBudgetSession;
  Lease : TLWPTWorkerLease;
  AcquiredPath, ReleasePath, OutputPath, ChildOutput, TmpPath,
    DelegationToken, RequestPath, Kind, ParentOutput, ChildRelease : string;
  Snapshot : TLWPTWorkerBudgetSnapshot;
  Lines, RequestLines, FirstEnvironment, SecondEnvironment : TStringList;
  Reclaimed : Integer;
  Child, FirstChild, SecondChild : TProcess;
  FirstThread, SecondThread : TLeaseThread;
begin
  if (ParamCount = 2) and (ParamStr(1) = SNAPSHOT_SWITCH) then
  begin
    Snapshot := GetWorkerBudgetSnapshot;
    Lines := TStringList.Create;
    try
      GrantedTotal := 0;
      HasProcess := False;
      HasLease := False;
      for i := 0 to High(Snapshot.Entries) do
      begin
        Inc(GrantedTotal, Snapshot.Entries[i].Granted);
        HasProcess := HasProcess or (Snapshot.Entries[i].ProcessId > 0);
        HasLease := HasLease
          or (Snapshot.Entries[i].LeaseStartedAt > 0);
      end;
      Lines.Add('budget=' + IntToStr(Snapshot.EffectiveBudget));
      Lines.Add('active=' + IntToStr(Snapshot.ActiveWorkers));
      Lines.Add('waiting=' + IntToStr(Snapshot.WaitingInvocations));
      Lines.Add('entries=' + IntToStr(Length(Snapshot.Entries)));
      Lines.Add('granted-total=' + IntToStr(GrantedTotal));
      Lines.Add('has-process=' + BoolToStr(HasProcess, True));
      Lines.Add('has-lease=' + BoolToStr(HasLease, True));
      AppendWorkerBudgetDiagnostics(Lines, Snapshot);
      Lines.SaveToFile(ParamStr(2));
    finally
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;
  if (ParamCount = 2) and (ParamStr(1) = REPAIR_SWITCH) then
  begin
    Reclaimed := RepairWorkerBudget;
    WriteMarker(ParamStr(2), IntToStr(Reclaimed));
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 5) and (ParamStr(1) = CORRUPT_OWNER_SWITCH) then
  begin
    Session := TLWPTWorkerBudgetSession.Create(ParamStr(2), 1);
    Lease := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      RequestPath := WorkerStateRoot + '/' + ParamStr(2) + '.request';
      Kind := ParamStr(3);
      if Kind = 'unreadable' then
      begin
        DeleteFile(RequestPath);
        ForceDirectories(RequestPath);
      end
      else if Kind = 'malformed' then
        WriteTextFile(RequestPath, 'not a worker request'#10)
      else if Kind = 'unknown' then
        WriteTextFile(RequestPath, 'schema=999'#10)
      else
        raise Exception.CreateFmt('unknown corruption kind "%s"', [Kind]);
      WriteMarker(ParamStr(4), 'ready');
      while not FileExists(ParamStr(5)) do Sleep(25);
    finally
      Lease.Free;
      Session.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2) and (ParamStr(1) = FANOUT_SWITCH) then
  begin
    Lines := TStringList.Create;
    FirstEnvironment := TStringList.Create;
    SecondEnvironment := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('fanout-parent', 1);
    Lease := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      AppendWorkerLeaseEnvironment(FirstEnvironment, Lease);
      Refused := False;
      try
        AppendWorkerLeaseEnvironment(SecondEnvironment, Lease);
      except
        on ELWPTWorkerBudgetError do Refused := True;
      end;
      Lines.Add('first-token-present=' + BoolToStr(EnvValue(
        FirstEnvironment, WORKER_LEASE_TOKEN_ENV) <> '', True));
      Lines.Add('second-refused=' + BoolToStr(Refused, True));
      Lines.Add('second-token=' + EnvValue(
        SecondEnvironment, WORKER_LEASE_TOKEN_ENV));
      Lines.SaveToFile(ParamStr(2));
    finally
      Lease.Free;
      Session.Free;
      SecondEnvironment.Free;
      FirstEnvironment.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2) and (ParamStr(1) = REUSE_SWITCH) then
  begin
    Lines := TStringList.Create;
    FirstEnvironment := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('reuse-parent', 1);
    Lease := nil;
    FirstChild := nil;
    SecondChild := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      AppendWorkerLeaseEnvironment(FirstEnvironment, Lease);
      DelegationToken := EnvValue(
        FirstEnvironment, WORKER_LEASE_TOKEN_ENV);

      FirstChild := TProcess.Create(nil);
      FirstChild.Executable := ExpandFileName(ParamStr(0));
      FirstChild.Parameters.Add(NESTED_CHILD_SWITCH);
      FirstChild.Parameters.Add(ParamStr(2) + '.first');
      AddWorkerEnvironment(FirstChild, WorkerStateRoot);
      FirstChild.Environment.Add(
        WORKER_LEASE_TOKEN_ENV + '=' + DelegationToken);
      FirstChild.Options := [poWaitOnExit];
      FirstChild.Execute;

      SecondChild := TProcess.Create(nil);
      SecondChild.Executable := ExpandFileName(ParamStr(0));
      SecondChild.Parameters.Add(NESTED_CHILD_SWITCH);
      SecondChild.Parameters.Add(ParamStr(2) + '.second');
      AddWorkerEnvironment(SecondChild, WorkerStateRoot);
      SecondChild.Environment.Add(
        WORKER_LEASE_TOKEN_ENV + '=' + DelegationToken);
      SecondChild.Options := [poWaitOnExit];
      SecondChild.Execute;

      Lines.Add('first-exit=' + IntToStr(FirstChild.ExitStatus));
      Lines.Add('second-exit=' + IntToStr(SecondChild.ExitStatus));
      Lines.SaveToFile(ParamStr(2));
    finally
      SecondChild.Free;
      FirstChild.Free;
      Lease.Free;
      Session.Free;
      FirstEnvironment.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 3) and (ParamStr(1) = HOLD_CHILD_SWITCH) then
  begin
    Session := TLWPTWorkerBudgetSession.Create('orphan-child', 1);
    Lease := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      WriteMarker(ParamStr(2), 'ready');
      while not FileExists(ParamStr(3)) do Sleep(25);
    finally
      Lease.Free;
      Session.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2)
     and ((ParamStr(1) = DELEGATION_CRASH_SWITCH)
       or (ParamStr(1) = DELEGATION_RELEASE_SWITCH)) then
  begin
    OutputPath := ParamStr(2);
    ChildOutput := OutputPath + '.child';
    ChildRelease := OutputPath + '.release';
    Lines := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('delegation-parent', 1);
    Lease := nil;
    Child := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Child := TProcess.Create(nil);
      Child.Executable := ExpandFileName(ParamStr(0));
      Child.Parameters.Add(HOLD_CHILD_SWITCH);
      Child.Parameters.Add(ChildOutput);
      Child.Parameters.Add(ChildRelease);
      AddWorkerEnvironment(Child, WorkerStateRoot);
      AppendWorkerLeaseEnvironment(Child.Environment, Lease);
      Lines.Add('parent-granted-after-delegation='
        + IntToStr(Session.GrantedWorkers));
      Child.Execute;
      if not WaitForFile(ChildOutput, WAIT_TIMEOUT_MILLISECONDS) then
        raise Exception.Create('delegated child did not acquire its lease');

      Lease.Release;
      Lease.Free;
      Lease := nil;
      if ParamStr(1) = DELEGATION_CRASH_SWITCH then
      begin
        Child.Terminate(9);
        Child.WaitOnExit;
        Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('reacquired=' + BoolToStr(Lease <> nil, True));
        Lines.Add('active-after-reacquire='
          + IntToStr(Snapshot.ActiveWorkers));
      end
      else
      begin
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('active-during-child='
          + IntToStr(Snapshot.ActiveWorkers));
        WriteMarker(ChildRelease, 'release');
        Child.WaitOnExit;
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('active-after-child='
          + IntToStr(Snapshot.ActiveWorkers));
      end;
      Lines.SaveToFile(OutputPath);
    finally
      if (Child <> nil) and Child.Running then
      begin
        WriteMarker(ChildRelease, 'release');
        Child.WaitOnExit;
      end;
      Child.Free;
      Lease.Free;
      Session.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 4) and (ParamStr(1) = ORPHAN_PARENT_SWITCH) then
  begin
    ParentOutput := ParamStr(2);
    ChildOutput := ParamStr(3);
    ChildRelease := ParamStr(4);
    Session := TLWPTWorkerBudgetSession.Create('orphan-parent', 1);
    Lease := nil;
    Child := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Child := TProcess.Create(nil);
      Child.Executable := ExpandFileName(ParamStr(0));
      Child.Parameters.Add(HOLD_CHILD_SWITCH);
      Child.Parameters.Add(ChildOutput);
      Child.Parameters.Add(ChildRelease);
      AddWorkerEnvironment(Child, WorkerStateRoot);
      AppendWorkerLeaseEnvironment(Child.Environment, Lease);
      Child.Execute;
      if not WaitForFile(ChildOutput, WAIT_TIMEOUT_MILLISECONDS) then
        raise Exception.Create('delegated child did not acquire its lease');
      WriteMarker(ParentOutput, 'ready');
      while True do Sleep(100);
    finally
      Child.Free;
      Lease.Free;
      Session.Free;
    end;
  end;

  if (ParamCount = 2) and (ParamStr(1) = THREAD_SWITCH) then
  begin
    Lines := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('threaded-session', 2);
    FirstThread := TLeaseThread.Create(Session);
    SecondThread := TLeaseThread.Create(Session);
    try
      FirstThread.Start;
      SecondThread.Start;
      FirstThread.WaitFor;
      SecondThread.WaitFor;
      Snapshot := GetWorkerBudgetSnapshot;
      Lines.Add('first=' + BoolToStr(FirstThread.Success, True));
      Lines.Add('second=' + BoolToStr(SecondThread.Success, True));
      Lines.Add('first-error=' + FirstThread.ErrorText);
      Lines.Add('second-error=' + SecondThread.ErrorText);
      Lines.Add('active=' + IntToStr(Snapshot.ActiveWorkers));
      Lines.SaveToFile(ParamStr(2));
    finally
      SecondThread.Free;
      FirstThread.Free;
      Session.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2) and (ParamStr(1) = RELEASE_RETRY_SWITCH) then
  begin
    OutputPath := ParamStr(2);
    Lines := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('release-retry', 1);
    Lease := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      TmpPath := WorkerStateRoot + '/tmp';
      RecursiveDelete(TmpPath);
      WriteMarker(TmpPath, 'block atomic writes');
      FailedRelease := False;
      try
        Lease.Release;
      except
        FailedRelease := True;
      end;
      Snapshot := GetWorkerBudgetSnapshot;
      Lines.Add('failed=' + BoolToStr(FailedRelease, True));
      Lines.Add('active-after-failure='
        + IntToStr(Snapshot.ActiveWorkers));
      DeleteFile(TmpPath);
      ForceDirectories(TmpPath);
      Lease.Release;
      Snapshot := GetWorkerBudgetSnapshot;
      Lines.Add('active-after-retry='
        + IntToStr(Snapshot.ActiveWorkers));
      Lines.SaveToFile(OutputPath);
    finally
      Lease.Free;
      Session.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2) and (ParamStr(1) = NESTED_CHILD_SWITCH) then
  begin
    Lines := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('nested-child', 1);
    Lease := nil;
    try
      Lease := Session.Acquire(2000);
      Snapshot := GetWorkerBudgetSnapshot;
      Lines.Add('acquired=' + BoolToStr(Lease <> nil, True));
      Lines.Add('active=' + IntToStr(Snapshot.ActiveWorkers));
      Lines.Add('entries=' + IntToStr(Length(Snapshot.Entries)));
      Lines.Add('token-cleared=' + BoolToStr(
        GetEnvironmentVariable(WORKER_LEASE_TOKEN_ENV) = '', True));
      Lines.SaveToFile(ParamStr(2));
    finally
      Lease.Free;
      Session.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2) and (ParamStr(1) = NESTED_PARENT_SWITCH) then
  begin
    OutputPath := ParamStr(2);
    ChildOutput := OutputPath + '.child';
    Lines := TStringList.Create;
    RequestLines := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('nested-parent', 1);
    Lease := nil;
    Child := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Child := TProcess.Create(nil);
      Child.Executable := ExpandFileName(ParamStr(0));
      Child.Parameters.Add(NESTED_CHILD_SWITCH);
      Child.Parameters.Add(ChildOutput);
      AddWorkerEnvironment(Child, WorkerStateRoot);
      AppendWorkerLeaseEnvironment(Child.Environment, Lease);
      DelegationToken := EnvValue(
        Child.Environment, WORKER_LEASE_TOKEN_ENV);
      RequestLines.LoadFromFile(
        WorkerStateRoot + '/nested-parent.request');
      Child.Options := [poWaitOnExit];
      Child.Execute;
      Lease.Release;
      Lease.Free;
      Lease := nil;
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Snapshot := GetWorkerBudgetSnapshot;
      Lines.Add('child-exit=' + IntToStr(Child.ExitStatus));
      Lines.Add('active=' + IntToStr(Snapshot.ActiveWorkers));
      Lines.Add('entries=' + IntToStr(Length(Snapshot.Entries)));
      Lines.Add('raw-token-persisted=' + BoolToStr(
        Pos(DelegationToken, RequestLines.Text) > 0, True));
      Lines.Add('child-output=' + ChildOutput);
      Lines.SaveToFile(OutputPath);
    finally
      Child.Free;
      Lease.Free;
      Session.Free;
      RequestLines.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 6) and (ParamStr(1) = REACQUIRE_SWITCH) then
  begin
    Result := True;
    AcquiredPath := ParamStr(4);
    ReleasePath := ParamStr(5);
    Cycles := StrToIntDef(ParamStr(6), 0);
    Session := TLWPTWorkerBudgetSession.Create(ParamStr(2), 1);
    try
      for i := 1 to Cycles do
      begin
        Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
        if Lease = nil then
        begin
          ExitCode := 3;
          Exit;
        end;
        try
          WriteMarker(AcquiredPath + '-' + IntToStr(i), 'acquired');
          while not FileExists(ReleasePath + '-' + IntToStr(i)) do
            Sleep(25);
        finally
          Lease.Free;
        end;
      end;
    finally
      Session.Free;
    end;
    ExitCode := 0;
    Exit;
  end;

  Result := (ParamCount >= 6) and (ParamStr(1) = CHILD_SWITCH);
  if not Result then Exit;

  AcquiredPath := ParamStr(4);
  ReleasePath := ParamStr(5);
  Session := TLWPTWorkerBudgetSession.Create(ParamStr(2),
    StrToIntDef(ParamStr(6), 0));
  try
    Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
    if Lease = nil then
    begin
      ExitCode := 3;
      Exit;
    end;
    try
      WriteMarker(AcquiredPath,
        'pid=' + IntToStr(GetProcessID) + #10
        + 'budget=' + IntToStr(Session.EffectiveBudget) + #10
        + 'requested=' + IntToStr(Session.RequestedWorkers));
      while not FileExists(ReleasePath) do Sleep(25);
    finally
      Lease.Free;
    end;
  finally
    Session.Free;
  end;
  ExitCode := 0;
end;

procedure AddWorkerEnvironment(AProcess: TProcess;
  const AStateRoot: string; const ABudget: string);
var
  i : Integer;
  Entry : string;
begin
  for i := 1 to GetEnvironmentVariableCount do
  begin
    Entry := GetEnvironmentString(i);
    if not IsWorkerOverride(Entry) then AProcess.Environment.Add(Entry);
  end;
  AProcess.Environment.Add(WORKER_STATE_DIR_ENV + '=' + AStateRoot);
  AProcess.Environment.Add(WORKER_BUDGET_ENV + '=' + ABudget);
  AProcess.Environment.Add(
    WORKER_STALE_SECONDS_ENV + '=' + TEST_STALE_SECONDS);
end;

procedure TWorkerBudgetProcesses.ResetScratch;
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch + '/state');
  ForceDirectories(FScratch + '/worktree-a');
  ForceDirectories(FScratch + '/worktree-b');
end;

function TWorkerBudgetProcesses.StartChild(const ASession, AWorktree,
  AAcquired, ARelease: string; ARequestedWorkers: Integer): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ExpandFileName(ParamStr(0));
  Result.Parameters.Add(CHILD_SWITCH);
  Result.Parameters.Add(ASession);
  Result.Parameters.Add(AWorktree);
  Result.Parameters.Add(AAcquired);
  Result.Parameters.Add(ARelease);
  Result.Parameters.Add(IntToStr(ARequestedWorkers));
  Result.CurrentDirectory := AWorktree;
  AddWorkerEnvironment(Result, FScratch + '/state');
  Result.Execute;
end;

function TWorkerBudgetProcesses.StartReacquirer(const ASession, AWorktree,
  AAcquiredPrefix, AReleasePrefix: string; ACycles: Integer): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ExpandFileName(ParamStr(0));
  Result.Parameters.Add(REACQUIRE_SWITCH);
  Result.Parameters.Add(ASession);
  Result.Parameters.Add(AWorktree);
  Result.Parameters.Add(AAcquiredPrefix);
  Result.Parameters.Add(AReleasePrefix);
  Result.Parameters.Add(IntToStr(ACycles));
  Result.CurrentDirectory := AWorktree;
  AddWorkerEnvironment(Result, FScratch + '/state');
  Result.Execute;
end;

function ReadUtilityValues(const APath: string): TStringList;
begin
  Result := TStringList.Create;
  try
    Result.LoadFromFile(APath);
  except
    Result.Free;
    raise;
  end;
end;

procedure TWorkerBudgetProcesses.RunUtility(const ASwitch,
  AOutputPath: string);
begin
  RunUtilityWithBudget(ASwitch, AOutputPath, TEST_BUDGET);
end;

procedure TWorkerBudgetProcesses.RunUtilityWithBudget(const ASwitch,
  AOutputPath, ABudget: string);
var
  Utility : TProcess;
begin
  Utility := TProcess.Create(nil);
  try
    Utility.Executable := ExpandFileName(ParamStr(0));
    Utility.Parameters.Add(ASwitch);
    Utility.Parameters.Add(AOutputPath);
    AddWorkerEnvironment(Utility, FScratch + '/state', ABudget);
    Utility.Options := [poWaitOnExit];
    Utility.Execute;
    if Utility.ExitStatus <> 0 then
      raise Exception.CreateFmt(
        'worker-budget utility %s exited %d',
        [ASwitch, Utility.ExitStatus]);
  finally
    Utility.Free;
  end;
end;

function TWorkerBudgetProcesses.WaitForSessionState(const ASession,
  AState: string; ATimeoutMilliseconds: Integer): Boolean;
var
  Started : QWord;
  SnapshotPath, SessionPrefix, StateText : string;
  Values : TStringList;
  i : Integer;
begin
  Started := GetTickCount64;
  SnapshotPath := FScratch + '/wait-state-snapshot';
  SessionPrefix := '  ' + ASession + ':';
  StateText := ', ' + AState + ',';
  repeat
    RunUtility(SNAPSHOT_SWITCH, SnapshotPath);
    Values := ReadUtilityValues(SnapshotPath);
    try
      for i := 0 to Values.Count - 1 do
        if (Pos(SessionPrefix, Values[i]) = 1)
           and (Pos(StateText, Values[i]) > 0) then
          Exit(True);
    finally
      Values.Free;
    end;
    Sleep(25);
  until GetTickCount64 - Started >= QWord(ATimeoutMilliseconds);
  Result := False;
end;

procedure TWorkerBudgetProcesses.StopChild(AProcess: TProcess);
begin
  if AProcess = nil then Exit;
  try
    if AProcess.Running then
      AProcess.Terminate(1);
    { Always reap the child. On Windows a process that has begun exiting can
      retain its current-directory handle after Running changes state; the
      next test must not wipe that worktree until the handle is closed. }
    AProcess.WaitOnExit;
  finally
    AProcess.Free;
  end;
end;

procedure TWorkerBudgetProcesses.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/worker-budget');
end;

procedure TWorkerBudgetProcesses.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

procedure TWorkerBudgetProcesses.BeforeEach;
begin
  ResetScratch;
end;

procedure TWorkerBudgetProcesses.TestContendersShareCapacityAndBothProgress;
var
  FirstProcess, SecondProcess : TProcess;
  FirstAcquired, SecondAcquired, FirstRelease, SecondRelease,
    SnapshotPath : string;
  Values : TStringList;
begin
  FirstProcess := nil;
  SecondProcess := nil;
  FirstAcquired := FScratch + '/first-acquired';
  SecondAcquired := FScratch + '/second-acquired';
  FirstRelease := FScratch + '/first-release';
  SecondRelease := FScratch + '/second-release';
  SnapshotPath := FScratch + '/snapshot';
  Values := nil;
  try
    FirstProcess := StartChild('first', FScratch + '/worktree-a',
      FirstAcquired, FirstRelease);
    Expect<Boolean>(WaitForFile(FirstAcquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);

    SecondProcess := StartChild('second', FScratch + '/worktree-b',
      SecondAcquired, SecondRelease);
    Expect<Boolean>(WaitForFile(FScratch + '/state/second.request',
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    Expect<Boolean>(FileExists(SecondAcquired)).ToBe(False);

    RunUtility(SNAPSHOT_SWITCH, SnapshotPath);
    Values := ReadUtilityValues(SnapshotPath);
    Expect<Integer>(StrToIntDef(Values.Values['budget'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(Values.Values['active'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(Values.Values['entries'], 0)).ToBe(2);
    Expect<Integer>(StrToIntDef(
      Values.Values['granted-total'], 0)).ToBe(1);
    Expect<string>(Values.Values['has-process']).ToBe('True');
    Expect<string>(Values.Values['has-lease']).ToBe('True');
    Expect<Boolean>(Pos('lease age ', Values.Text) > 0).ToBe(True);

    WriteMarker(FirstRelease, 'release');
    Expect<Boolean>(WaitForFile(SecondAcquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    WriteMarker(SecondRelease, 'release');
  finally
    Values.Free;
    StopChild(SecondProcess);
    StopChild(FirstProcess);
  end;
end;

procedure TWorkerBudgetProcesses.TestRequestIsBoundedByMachineCapacity;
var
  Process : TProcess;
  Acquired, ReleasePath : string;
  Values : TStringList;
begin
  Process := nil;
  Acquired := FScratch + '/bounded-acquired';
  ReleasePath := FScratch + '/bounded-release';
  Values := nil;
  try
    Process := StartChild('bounded-request', FScratch + '/worktree-a',
      Acquired, ReleasePath, 4);
    Expect<Boolean>(WaitForFile(Acquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    Values := ReadUtilityValues(Acquired);
    Expect<Integer>(StrToIntDef(Values.Values['budget'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(Values.Values['requested'], 0)).ToBe(1);
    WriteMarker(ReleasePath, 'release');
  finally
    Values.Free;
    StopChild(Process);
  end;
end;

procedure TWorkerBudgetProcesses.TestCrashedOwnerIsReclaimed;
var
  FirstProcess, SecondProcess : TProcess;
  FirstAcquired, SecondAcquired, FirstRelease, SecondRelease,
    RepairPath : string;
  Values : TStringList;
  Reclaimed : Integer;
begin
  FirstProcess := nil;
  SecondProcess := nil;
  FirstAcquired := FScratch + '/crash-first-acquired';
  SecondAcquired := FScratch + '/crash-second-acquired';
  FirstRelease := FScratch + '/crash-first-release';
  SecondRelease := FScratch + '/crash-second-release';
  RepairPath := FScratch + '/repair-result';
  Values := nil;
  try
    FirstProcess := StartChild('crashed-owner', FScratch + '/worktree-a',
      FirstAcquired, FirstRelease);
    Expect<Boolean>(WaitForFile(FirstAcquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    FirstProcess.Terminate(9);
    FirstProcess.WaitOnExit;

    RunUtility(REPAIR_SWITCH, RepairPath);
    Values := ReadUtilityValues(RepairPath);
    Reclaimed := StrToIntDef(Trim(Values.Text), 0);
    Expect<Integer>(Reclaimed).ToBe(1);

    SecondProcess := StartChild('replacement', FScratch + '/worktree-b',
      SecondAcquired, SecondRelease);
    Expect<Boolean>(WaitForFile(SecondAcquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    WriteMarker(SecondRelease, 'release');
  finally
    Values.Free;
    StopChild(SecondProcess);
    StopChild(FirstProcess);
  end;
end;

procedure TWorkerBudgetProcesses.TestHeartbeatPreservesLongRunningOwner;
var
  FirstProcess, SecondProcess : TProcess;
  FirstAcquired, SecondAcquired, FirstRelease, SecondRelease,
    SnapshotPath : string;
  Values : TStringList;
begin
  FirstProcess := nil;
  SecondProcess := nil;
  FirstAcquired := FScratch + '/live-first-acquired';
  SecondAcquired := FScratch + '/live-second-acquired';
  FirstRelease := FScratch + '/live-first-release';
  SecondRelease := FScratch + '/live-second-release';
  SnapshotPath := FScratch + '/live-snapshot';
  Values := nil;
  try
    FirstProcess := StartChild('long-running', FScratch + '/worktree-a',
      FirstAcquired, FirstRelease);
    Expect<Boolean>(WaitForFile(FirstAcquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    SecondProcess := StartChild('waiting', FScratch + '/worktree-b',
      SecondAcquired, SecondRelease);
    Expect<Boolean>(WaitForFile(FScratch + '/state/waiting.request',
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);

    { Wait longer than the configured stale threshold. The first process's
      heartbeat must preserve its grant, so the contender remains queued. }
    Sleep(4000);
    Expect<Boolean>(FileExists(SecondAcquired)).ToBe(False);
    RunUtility(SNAPSHOT_SWITCH, SnapshotPath);
    Values := ReadUtilityValues(SnapshotPath);
    Expect<Integer>(StrToIntDef(Values.Values['active'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(Values.Values['waiting'], 0)).ToBe(1);

    WriteMarker(FirstRelease, 'release');
    Expect<Boolean>(WaitForFile(SecondAcquired,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    WriteMarker(SecondRelease, 'release');
  finally
    Values.Free;
    StopChild(SecondProcess);
    StopChild(FirstProcess);
  end;
end;

procedure TWorkerBudgetProcesses.TestLiveUnreadableRequestsFailClosed;
var
  Process, Contender : TProcess;
  Kind, SessionId, RequestPath, ReadyPath, ReleasePath, SnapshotPath,
    RepairPath, ContenderAcquired, ContenderRelease : string;
  Values : TStringList;
  KindIndex : Integer;
const
  Kinds : array[0..2] of string = ('unreadable', 'malformed', 'unknown');
begin
  for KindIndex := Low(Kinds) to High(Kinds) do
  begin
    ResetScratch;
    Kind := Kinds[KindIndex];
    SessionId := 'corrupt-' + Kind;
    RequestPath := FScratch + '/state/' + SessionId + '.request';
    ReadyPath := FScratch + '/' + Kind + '-ready';
    ReleasePath := FScratch + '/' + Kind + '-release';
    SnapshotPath := FScratch + '/' + Kind + '-snapshot';
    RepairPath := FScratch + '/' + Kind + '-repair';
    ContenderAcquired := FScratch + '/' + Kind + '-contender-acquired';
    ContenderRelease := FScratch + '/' + Kind + '-contender-release';
    Values := nil;
    Contender := nil;
    Process := TProcess.Create(nil);
    try
      Process.Executable := ExpandFileName(ParamStr(0));
      Process.Parameters.Add(CORRUPT_OWNER_SWITCH);
      Process.Parameters.Add(SessionId);
      Process.Parameters.Add(Kind);
      Process.Parameters.Add(ReadyPath);
      Process.Parameters.Add(ReleasePath);
      AddWorkerEnvironment(Process, FScratch + '/state');
      Process.Execute;
      Expect<Boolean>(WaitForFile(ReadyPath,
        WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);

      RunUtility(SNAPSHOT_SWITCH, SnapshotPath);
      Values := ReadUtilityValues(SnapshotPath);
      Expect<Integer>(StrToIntDef(Values.Values['active'], 0)).ToBe(1);
      Expect<Integer>(StrToIntDef(Values.Values['entries'], 0)).ToBe(1);
      Expect<Boolean>(Pos('uncertain-live-owner', Values.Text) > 0).ToBe(True);
      Values.Free;
      Values := nil;

      RunUtility(REPAIR_SWITCH, RepairPath);
      Values := ReadUtilityValues(RepairPath);
      Expect<Integer>(StrToIntDef(Trim(Values.Text), -1)).ToBe(0);
      Expect<Boolean>(FileExists(RequestPath)
        or DirectoryExists(RequestPath)).ToBe(True);

      Contender := StartChild('contender-' + Kind,
        FScratch + '/worktree-b', ContenderAcquired, ContenderRelease);
      Expect<Boolean>(WaitForFile(
        FScratch + '/state/contender-' + Kind + '.request',
        WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
      Sleep(250);
      Expect<Boolean>(FileExists(ContenderAcquired)).ToBe(False);

      WriteMarker(ReleasePath, 'release');
      Process.WaitOnExit;
      Expect<Integer>(Process.ExitStatus).ToBe(0);
      Expect<Boolean>(WaitForFile(ContenderAcquired,
        WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
      WriteMarker(ContenderRelease, 'release');
    finally
      Values.Free;
      StopChild(Contender);
      StopChild(Process);
    end;
  end;
end;

procedure TWorkerBudgetProcesses.TestWaiterPrecedesRepeatedReacquire;
var
  Reacquirer, Waiter : TProcess;
  AcquiredPrefix, ReleasePrefix, WaiterAcquired, WaiterRelease : string;
  Round : Integer;
begin
  Reacquirer := nil;
  Waiter := nil;
  AcquiredPrefix := FScratch + '/reacquired';
  ReleasePrefix := FScratch + '/reacquire-release';
  try
    Reacquirer := StartReacquirer('older-session',
      FScratch + '/worktree-a', AcquiredPrefix, ReleasePrefix, 4);
    Expect<Boolean>(WaitForFile(AcquiredPrefix + '-1',
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);

    for Round := 1 to 3 do
    begin
      WaiterAcquired := FScratch + '/waiter-acquired-'
        + IntToStr(Round);
      WaiterRelease := FScratch + '/waiter-release-' + IntToStr(Round);
      Waiter := StartChild('waiter-' + IntToStr(Round),
        FScratch + '/worktree-b', WaiterAcquired, WaiterRelease);
      try
        Expect<Boolean>(WaitForSessionState('waiter-' + IntToStr(Round),
          'waiting', WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
        WriteMarker(ReleasePrefix + '-' + IntToStr(Round), 'release');
        Expect<Boolean>(WaitForFile(WaiterAcquired,
          WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
        Expect<Boolean>(FileExists(AcquiredPrefix + '-'
          + IntToStr(Round + 1))).ToBe(False);
        WriteMarker(WaiterRelease, 'release');
        Expect<Boolean>(WaitForFile(AcquiredPrefix + '-'
          + IntToStr(Round + 1), WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
      finally
        StopChild(Waiter);
        Waiter := nil;
      end;
    end;
    WriteMarker(ReleasePrefix + '-4', 'release');
    Reacquirer.WaitOnExit;
    Expect<Integer>(Reacquirer.ExitStatus).ToBe(0);
  finally
    StopChild(Waiter);
    StopChild(Reacquirer);
  end;
end;

procedure TWorkerBudgetProcesses.TestNestedProcessInheritsLease;
var
  ParentOutput, ChildOutput : string;
  ParentValues, ChildValues : TStringList;
begin
  ParentOutput := FScratch + '/nested-parent';
  ParentValues := nil;
  ChildValues := nil;
  try
    RunUtility(NESTED_PARENT_SWITCH, ParentOutput);
    ParentValues := ReadUtilityValues(ParentOutput);
    ChildOutput := ParentValues.Values['child-output'];
    ChildValues := ReadUtilityValues(ChildOutput);
    Expect<Integer>(StrToIntDef(
      ParentValues.Values['child-exit'], -1)).ToBe(0);
    Expect<Integer>(StrToIntDef(ParentValues.Values['active'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(ParentValues.Values['entries'], 0)).ToBe(1);
    Expect<string>(
      ParentValues.Values['raw-token-persisted']).ToBe('False');
    Expect<string>(ChildValues.Values['acquired']).ToBe('True');
    Expect<Integer>(StrToIntDef(ChildValues.Values['active'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(ChildValues.Values['entries'], 0)).ToBe(2);
    Expect<string>(ChildValues.Values['token-cleared']).ToBe('True');
  finally
    ChildValues.Free;
    ParentValues.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestOneLeaseCannotFanOutToTwoChildren;
var
  OutputPath : string;
  Values : TStringList;
begin
  OutputPath := FScratch + '/fanout-result';
  Values := nil;
  try
    RunUtility(FANOUT_SWITCH, OutputPath);
    Values := ReadUtilityValues(OutputPath);
    Expect<string>(Values.Values['first-token-present']).ToBe('True');
    Expect<string>(Values.Values['second-refused']).ToBe('True');
    Expect<string>(Values.Values['second-token']).ToBe('');
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestConsumedDelegationTokenCannotBeReused;
var
  OutputPath : string;
  Values : TStringList;
begin
  OutputPath := FScratch + '/reuse-result';
  Values := nil;
  try
    RunUtility(REUSE_SWITCH, OutputPath);
    Values := ReadUtilityValues(OutputPath);
    Expect<Integer>(StrToIntDef(Values.Values['first-exit'], -1)).ToBe(0);
    Expect<Boolean>(StrToIntDef(
      Values.Values['second-exit'], 0) <> 0).ToBe(True);
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestDelegatedChildRemainsCountedAfterParentDeath;
var
  Parent : TProcess;
  ParentOutput, ChildOutput, ChildRelease, ChildRequest,
    SnapshotPath : string;
  Values : TStringList;
begin
  Parent := nil;
  Values := nil;
  ParentOutput := FScratch + '/orphan-parent-ready';
  ChildOutput := FScratch + '/orphan-child-ready';
  ChildRelease := FScratch + '/orphan-child-release';
  ChildRequest := FScratch + '/state/orphan-child.request';
  SnapshotPath := FScratch + '/orphan-snapshot';
  try
    Parent := TProcess.Create(nil);
    Parent.Executable := ExpandFileName(ParamStr(0));
    Parent.Parameters.Add(ORPHAN_PARENT_SWITCH);
    Parent.Parameters.Add(ParentOutput);
    Parent.Parameters.Add(ChildOutput);
    Parent.Parameters.Add(ChildRelease);
    AddWorkerEnvironment(Parent, FScratch + '/state');
    Parent.Execute;
    Expect<Boolean>(WaitForFile(ParentOutput,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    Expect<Boolean>(WaitForFile(ChildOutput,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);

    Parent.Terminate(9);
    Parent.WaitOnExit;
    RunUtility(SNAPSHOT_SWITCH, SnapshotPath);
    Values := ReadUtilityValues(SnapshotPath);
    Expect<Integer>(StrToIntDef(Values.Values['active'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(Values.Values['entries'], 0)).ToBe(1);
    Expect<Boolean>(Pos('orphan-child:', Values.Text) > 0).ToBe(True);

    WriteMarker(ChildRelease, 'release');
    Expect<Boolean>(WaitForPathGone(ChildRequest,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
  finally
    Values.Free;
    StopChild(Parent);
    if not FileExists(ChildRelease) then
      WriteMarker(ChildRelease, 'release');
    WaitForPathGone(ChildRequest, WAIT_TIMEOUT_MILLISECONDS);
  end;
end;

procedure TWorkerBudgetProcesses.TestDelegatedChildCrashReturnsCapacity;
var
  OutputPath : string;
  Values : TStringList;
begin
  OutputPath := FScratch + '/delegation-crash-result';
  Values := nil;
  try
    RunUtility(DELEGATION_CRASH_SWITCH, OutputPath);
    Values := ReadUtilityValues(OutputPath);
    Expect<Integer>(StrToIntDef(
      Values.Values['parent-granted-after-delegation'], -1)).ToBe(0);
    Expect<string>(Values.Values['reacquired']).ToBe('True');
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-reacquire'], 0)).ToBe(1);
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestParentReleaseDoesNotCreateGhostGrant;
var
  OutputPath : string;
  Values : TStringList;
begin
  OutputPath := FScratch + '/delegation-release-result';
  Values := nil;
  try
    RunUtility(DELEGATION_RELEASE_SWITCH, OutputPath);
    Values := ReadUtilityValues(OutputPath);
    Expect<Integer>(StrToIntDef(
      Values.Values['parent-granted-after-delegation'], -1)).ToBe(0);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-during-child'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-child'], -1)).ToBe(0);
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestReleaseRetriesAfterWriteFailure;
var
  OutputPath : string;
  Values : TStringList;
begin
  OutputPath := FScratch + '/release-retry-result';
  Values := nil;
  try
    RunUtility(RELEASE_RETRY_SWITCH, OutputPath);
    Values := ReadUtilityValues(OutputPath);
    Expect<string>(Values.Values['failed']).ToBe('True');
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-failure'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-retry'], -1)).ToBe(0);
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestSessionSupportsConcurrentSchedulerThreads;
var
  OutputPath : string;
  Values : TStringList;
begin
  OutputPath := FScratch + '/thread-result';
  Values := nil;
  try
    RunUtilityWithBudget(THREAD_SWITCH, OutputPath, '2');
    Values := ReadUtilityValues(OutputPath);
    Expect<string>(Values.Values['first']).ToBe('True');
    Expect<string>(Values.Values['second']).ToBe('True');
    Expect<string>(Values.Values['first-error']).ToBe('');
    Expect<string>(Values.Values['second-error']).ToBe('');
    Expect<Integer>(StrToIntDef(Values.Values['active'], -1)).ToBe(0);
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses.SetupTests;
begin
  Test('separate worktrees share one budget and both contenders progress',
    TestContendersShareCapacityAndBothProgress);
  Test('an invocation request is bounded by machine capacity',
    TestRequestIsBoundedByMachineCapacity);
  Test('a crashed owner is reclaimed without leaking capacity',
    TestCrashedOwnerIsReclaimed);
  Test('heartbeats preserve a live long-running owner',
    TestHeartbeatPreservesLongRunningOwner);
  Test('unreadable live-owner requests fail closed',
    TestLiveUnreadableRequestsFailClosed);
  Test('existing waiters precede repeated reacquisition by an older session',
    TestWaiterPrecedesRepeatedReacquire);
  Test('nested LWPT processes inherit one lease at a machine budget of one',
    TestNestedProcessInheritsLease);
  Test('one worker lease cannot fan out to two children',
    TestOneLeaseCannotFanOutToTwoChildren);
  Test('a consumed worker delegation token cannot be reused',
    TestConsumedDelegationTokenCannotBeReused);
  Test('a delegated child stays counted after its parent dies',
    TestDelegatedChildRemainsCountedAfterParentDeath);
  Test('a delegated child crash returns capacity to the parent queue',
    TestDelegatedChildCrashReturnsCapacity);
  Test('parent release during delegation does not create a ghost grant',
    TestParentReleaseDoesNotCreateGhostGrant);
  Test('release remains retryable after a coordinator write failure',
    TestReleaseRetriesAfterWriteFailure);
  Test('one session supports concurrent scheduler threads',
    TestSessionSupportsConcurrentSchedulerThreads);
end;

begin
  if RunChildMode then Exit;
  TestRunnerProgram.AddSuite(TWorkerBudgetProcesses.Create(
    'worker budget: cross-process leases'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
