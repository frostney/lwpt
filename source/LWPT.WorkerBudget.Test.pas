{ LWPT.WorkerBudget.Test — cross-process coverage for the per-user worker
  coordinator. The test executable spawns itself from two different working
  directories so contention crosses the same boundary as separate worktrees. }
program LWPT.WorkerBudget.Test;

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
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
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
  PENDING_CHILD_SWITCH = '--worker-budget-pending-child';
  UNCONSUMED_CHILD_SWITCH = '--worker-budget-unconsumed-child';
  DELEGATION_CRASH_SWITCH = '--worker-budget-delegation-crash';
  DELEGATION_RELEASE_SWITCH = '--worker-budget-delegation-release';
  DELEGATED_CHILD_SESSION = 'orphan-child';
  SNAPSHOT_SWITCH = '--worker-budget-snapshot';
  REPAIR_SWITCH = '--worker-budget-repair';
  STATE_ROOT_FALLBACK_SWITCH = '--worker-state-root-fallback';
  STATE_ROOT_EXISTING_LOCK_FALLBACK_SWITCH =
    '--worker-state-root-existing-lock-fallback';
  STATE_ROOT_UNWRITABLE_FALLBACK_SWITCH =
    '--worker-state-root-unwritable-fallback';
  STATE_ROOT_FALLBACK_DELEGATION_SWITCH =
    '--worker-state-root-fallback-delegation';
  STATE_ROOT_EXPLICIT_SWITCH = '--worker-state-root-explicit';
  STATE_ROOT_PROBE_SWITCH = '--worker-state-root-probe';
  STATE_ROOT_RETRY_PROBE_SWITCH = '--worker-state-root-retry-probe';
  STATE_ROOT_CAPTURE_SWITCH = '--worker-state-root-capture';
  TRANSACTION_LOCK_NAME = 'transaction.lock';
  TEST_BUDGET = '1';
  TEST_STALE_SECONDS = '3';
  CAPTURE_OUTPUT_SIZE = 128 * 1024;
  CAPTURE_EXIT_CODE = 23;
  CAPTURE_STDOUT_PREFIX = 'stdout-begin:';
  CAPTURE_STDOUT_SUFFIX = ':stdout-end';
  CAPTURE_STDERR_PREFIX = 'stderr-begin:';
  CAPTURE_STDERR_SUFFIX = ':stderr-end';
  WAIT_TIMEOUT_MILLISECONDS = 10000;
  SCRATCH_DELETE_TIMEOUT_MILLISECONDS = 2000;
  SCRATCH_DELETE_RETRY_MILLISECONDS = 25;
  MARKER_COMPLETE_SUFFIX = '.complete';

type
  TStateRootUtilityResult = record
    ExitCode : Integer;
    Stdout : string;
    Stderr : string;
  end;

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
    procedure DeleteScratch;
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
    procedure TestConcurrentFirstProbesUseDefaultRoot;
    procedure TestFirstTransactionRetriesInterruptedRootCreation;
    procedure TestStateRootUtilityDrainsOutputWhileRunning;
    {$IFDEF UNIX}
    procedure TestDelegationPreservesFallbackRootAcrossWorkingDirectories;
    procedure TestUnwritableDefaultFallsBackOnce;
    procedure TestExistingLockDoesNotMaskUnwritableDefault;
    procedure TestUnwritableFallbackRequiresExplicitOverride;
    procedure TestUnwritableExplicitRootFails;
    {$ENDIF}
  end;

var
  RootCreateReadyPath : string = '';
  RootCreateReleasePath : string = '';

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

procedure PublishReadableMarker(const APath, AText: string);
begin
  WriteMarker(APath, AText);
  { Path visibility alone does not mean a Windows writer has returned from
    its atomic replacement. Publish a separate existence-only marker after
    the payload write completes, transferring read ownership to the parent. }
  WriteMarker(APath + MARKER_COMPLETE_SUFFIX, 'complete');
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

function ReadMarkerText(const APath: string): string;
var
  Lines : TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Result := Trim(Lines.Text);
  finally
    Lines.Free;
  end;
end;

function WaitForReadableMarker(const APath: string;
  ATimeoutMilliseconds: Integer; out AText: string): Boolean;
begin
  Result := WaitForFile(APath + MARKER_COMPLETE_SUFFIX,
    ATimeoutMilliseconds);
  if not Result then Exit;
  AText := ReadMarkerText(APath);
end;

function InterruptFirstWorkerStateRootCreate(
  const ARoot: string): Boolean;
begin
  WorkerStateRootCreateTestHook := nil;
  if DirectoryExists(ARoot) then
    raise Exception.CreateFmt(
      'worker-root test expected the root to be absent: %s', [ARoot]);
  WriteMarker(RootCreateReadyPath, 'ready');
  if not WaitForFile(RootCreateReleasePath,
    WAIT_TIMEOUT_MILLISECONDS) then
    raise Exception.CreateFmt(
      'timed out waiting for worker-root test release marker at %s',
      [RootCreateReleasePath]);
  Result := False;
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
  AcquiredPath, ReleasePath, OutputPath, ChildOutput, ChildMarker, TmpPath,
    DelegationToken, RequestPath, OwnerPath, Kind, ParentOutput,
    ChildRelease, ChildConsume, ChildAcquired, CancellationError : string;
  Snapshot : TLWPTWorkerBudgetSnapshot;
  Lines, RequestLines, FirstEnvironment, SecondEnvironment : TStringList;
  Reclaimed : Integer;
  Child, FirstChild, SecondChild : TProcess;
  FirstThread, SecondThread : TLeaseThread;
  {$IFDEF UNIX}
  DefaultRoot, FallbackRoot, FallbackSessionId : string;
  ExistingTransactionLock : Boolean;
  {$ENDIF}
begin
  if (ParamCount = 1) and (ParamStr(1) = UNCONSUMED_CHILD_SWITCH) then
  begin
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2) and (ParamStr(1) = STATE_ROOT_CAPTURE_SWITCH) then
  begin
    Write(CAPTURE_STDOUT_PREFIX);
    Write(StringOfChar('o', CAPTURE_OUTPUT_SIZE));
    Write(CAPTURE_STDOUT_SUFFIX);
    Write(ErrOutput, CAPTURE_STDERR_PREFIX);
    Write(ErrOutput, StringOfChar('e', CAPTURE_OUTPUT_SIZE));
    Write(ErrOutput, CAPTURE_STDERR_SUFFIX);
    ExitCode := CAPTURE_EXIT_CODE;
    Exit(True);
  end;

  if (ParamCount = 4) and (ParamStr(1) = STATE_ROOT_PROBE_SWITCH) then
  begin
    ForceDirectories(GetAppConfigDir(False));
    WriteMarker(ParamStr(3), 'ready');
    while not FileExists(ParamStr(4)) do Sleep(25);
    Lines := TStringList.Create;
    Session := nil;
    Lease := nil;
    try
      Session := TLWPTWorkerBudgetSession.Create(NewWorkerSessionId, 1);
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Lines.Add('root=' + WorkerStateRoot);
      Lines.Add('acquired=' + BoolToStr(Assigned(Lease), True));
      Lines.SaveToFile(ParamStr(2));
    finally
      Lease.Free;
      Session.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 4)
     and (ParamStr(1) = STATE_ROOT_RETRY_PROBE_SWITCH) then
  begin
    RootCreateReadyPath := ParamStr(3);
    RootCreateReleasePath := ParamStr(4);
    WorkerStateRootCreateTestHook :=
      @InterruptFirstWorkerStateRootCreate;
    Lines := TStringList.Create;
    Session := nil;
    Lease := nil;
    try
      Session := TLWPTWorkerBudgetSession.Create(NewWorkerSessionId, 1);
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Lines.Add('root=' + WorkerStateRoot);
      Lines.Add('acquired=' + BoolToStr(Assigned(Lease), True));
      Lines.SaveToFile(ParamStr(2));
    finally
      Lease.Free;
      Session.Free;
      Lines.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  {$IFDEF UNIX}
  if (ParamCount = 2)
     and (ParamStr(1) = STATE_ROOT_UNWRITABLE_FALLBACK_SWITCH) then
  begin
    DefaultRoot := ExcludeTrailingPathDelimiter(ExpandFileName(
      IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'workers'));
    FallbackRoot := ExcludeTrailingPathDelimiter(
      ExpandFileName(WORKER_STATE_FALLBACK_DIR));
    if not ForceDirectories(DefaultRoot) then
      raise Exception.CreateFmt(
        'could not create default worker-state test root %s', [DefaultRoot]);
    if not ForceDirectories(FallbackRoot) then
      raise Exception.CreateFmt(
        'could not create fallback worker-state test root %s',
        [FallbackRoot]);
    if FpChmod(DefaultRoot, &555) <> 0 then
      raise Exception.CreateFmt(
        'could not make default worker-state test root read-only: %s',
        [DefaultRoot]);
    if FpChmod(FallbackRoot, &555) <> 0 then
    begin
      FpChmod(DefaultRoot, &755);
      raise Exception.CreateFmt(
        'could not make fallback worker-state test root read-only: %s',
        [FallbackRoot]);
    end;
    try
      WorkerStateRoot;
    finally
      FpChmod(FallbackRoot, &755);
      FpChmod(DefaultRoot, &755);
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 2)
     and ((ParamStr(1) = STATE_ROOT_FALLBACK_SWITCH)
       or (ParamStr(1) = STATE_ROOT_EXISTING_LOCK_FALLBACK_SWITCH)) then
  begin
    ExistingTransactionLock :=
      ParamStr(1) = STATE_ROOT_EXISTING_LOCK_FALLBACK_SWITCH;
    DefaultRoot := ExcludeTrailingPathDelimiter(ExpandFileName(
      IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'workers'));
    if not ForceDirectories(DefaultRoot) then
      raise Exception.CreateFmt(
        'could not create default worker-state test root %s', [DefaultRoot]);
    if ExistingTransactionLock then
      WriteMarker(IncludeTrailingPathDelimiter(DefaultRoot)
        + TRANSACTION_LOCK_NAME, 'existing writable lock');
    if FpChmod(DefaultRoot, &555) <> 0 then
      raise Exception.CreateFmt(
        'could not make default worker-state test root read-only: %s',
        [DefaultRoot]);
    if ExistingTransactionLock then
      FallbackSessionId := 'fallback-existing-lock'
    else
      FallbackSessionId := 'fallback-root';
    Session := nil;
    Lease := nil;
    Lines := TStringList.Create;
    try
      Lines.Add('root-first=' + WorkerStateRoot);
      Lines.Add('root-second=' + WorkerStateRoot);
      Session := TLWPTWorkerBudgetSession.Create(FallbackSessionId, 1);
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Lines.Add('acquired=' + BoolToStr(Lease <> nil, True));
      Lines.Add('default-root=' + DefaultRoot);
      Lines.Add('default-request-exists=' + BoolToStr(FileExists(
        IncludeTrailingPathDelimiter(DefaultRoot) + FallbackSessionId
        + '.request'), True));
      Lines.Add('default-owner-exists=' + BoolToStr(FileExists(
        IncludeTrailingPathDelimiter(DefaultRoot) + FallbackSessionId
        + '.owner'), True));
      Lines.Add('default-budget-exists=' + BoolToStr(FileExists(
        IncludeTrailingPathDelimiter(DefaultRoot) + 'budget'), True));
      Lines.Add('default-queue-exists=' + BoolToStr(FileExists(
        IncludeTrailingPathDelimiter(DefaultRoot) + 'queue-sequence'), True));
      Lines.SaveToFile(ParamStr(2));
    finally
      Lease.Free;
      Session.Free;
      Lines.Free;
      FpChmod(DefaultRoot, &755);
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 3)
     and (ParamStr(1) = STATE_ROOT_FALLBACK_DELEGATION_SWITCH) then
  begin
    DefaultRoot := ExcludeTrailingPathDelimiter(ExpandFileName(
      IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'workers'));
    if not ForceDirectories(DefaultRoot) then
      raise Exception.CreateFmt(
        'could not create default worker-state test root %s', [DefaultRoot]);
    if FpChmod(DefaultRoot, &555) <> 0 then
      raise Exception.CreateFmt(
        'could not make default worker-state test root read-only: %s',
        [DefaultRoot]);
    Session := nil;
    Lease := nil;
    Child := nil;
    Lines := TStringList.Create;
    try
      Session := TLWPTWorkerBudgetSession.Create(
        'fallback-delegation-parent', 1);
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      ChildOutput := ParamStr(2) + '.child';
      Child := TProcess.Create(nil);
      Child.Executable := ExpandFileName(ParamStr(0));
      Child.Parameters.Add(NESTED_CHILD_SWITCH);
      Child.Parameters.Add(ChildOutput);
      Child.CurrentDirectory := ParamStr(3);
      AppendProcessEnvironment(Child.Environment);
      Child.Environment.Add(WORKER_STATE_DIR_ENV + '=stale-root');
      AppendWorkerLeaseEnvironment(Child.Environment, Lease);
      Lines.Add('parent-root=' + WorkerStateRoot);
      Lines.Add('child-environment-root=' + EnvValue(
        Child.Environment, WORKER_STATE_DIR_ENV));
      Child.Options := [poWaitOnExit];
      Child.Execute;
      Lines.Add('child-exit=' + IntToStr(Child.ExitStatus));
      Lines.Add('child-output=' + ChildOutput);
      Lines.SaveToFile(ParamStr(2));
    finally
      Child.Free;
      Lease.Free;
      Session.Free;
      Lines.Free;
      FpChmod(DefaultRoot, &755);
    end;
    ExitCode := 0;
    Exit(True);
  end;
  {$ENDIF}

  if (ParamCount = 2) and (ParamStr(1) = STATE_ROOT_EXPLICIT_SWITCH) then
  begin
    Session := TLWPTWorkerBudgetSession.Create('explicit-root', 1);
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Lease.Free;
    finally
      Session.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

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
    Session := TLWPTWorkerBudgetSession.Create(DELEGATED_CHILD_SESSION, 1);
    Lease := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      if Lease = nil then
      begin
        ExitCode := 3;
        Exit(True);
      end;
      PublishReadableMarker(ParamStr(2),
        'pid=' + IntToStr(GetProcessID));
      while not FileExists(ParamStr(3)) do Sleep(25);
    finally
      Lease.Free;
      Session.Free;
    end;
    ExitCode := 0;
    Exit(True);
  end;

  if (ParamCount = 5) and (ParamStr(1) = PENDING_CHILD_SWITCH) then
  begin
    PublishReadableMarker(ParamStr(2), 'ready-to-consume');
    while not FileExists(ParamStr(3)) do Sleep(25);
    Session := TLWPTWorkerBudgetSession.Create(DELEGATED_CHILD_SESSION, 1);
    Lease := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      WriteMarker(ParamStr(4), 'acquired');
      while not FileExists(ParamStr(5)) do Sleep(25);
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
    ChildConsume := OutputPath + '.consume';
    ChildAcquired := OutputPath + '.acquired';
    Lines := TStringList.Create;
    Session := TLWPTWorkerBudgetSession.Create('delegation-parent', 1);
    Lease := nil;
    Child := nil;
    try
      Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
      Child := TProcess.Create(nil);
      Child.Executable := ExpandFileName(ParamStr(0));
      if ParamStr(1) = DELEGATION_RELEASE_SWITCH then
      begin
        Child.Parameters.Add(PENDING_CHILD_SWITCH);
        Child.Parameters.Add(ChildOutput);
        Child.Parameters.Add(ChildConsume);
        Child.Parameters.Add(ChildAcquired);
        Child.Parameters.Add(ChildRelease);
      end
      else
      begin
        Child.Parameters.Add(HOLD_CHILD_SWITCH);
        Child.Parameters.Add(ChildOutput);
        Child.Parameters.Add(ChildRelease);
      end;
      AddWorkerEnvironment(Child, WorkerStateRoot);
      AppendWorkerLeaseEnvironment(Child.Environment, Lease);
      Lines.Add('parent-granted-after-delegation='
        + IntToStr(Session.GrantedWorkers));
      Child.Execute;
      if not WaitForReadableMarker(ChildOutput,
        WAIT_TIMEOUT_MILLISECONDS, ChildMarker) then
        raise Exception.Create(
          'delegated child did not publish its readiness marker');
      Lines.Add('spawned-child-pid=' + IntToStr(Child.ProcessID));
      Lines.Add('ready-marker=' + ChildMarker);

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
        RequestPath := WorkerStateRoot + '/'
          + DELEGATED_CHILD_SESSION + '.request';
        OwnerPath := WorkerStateRoot + '/'
          + DELEGATED_CHILD_SESSION + '.owner';
        Lines.Add('child-running-before-snapshot='
          + BoolToStr(Child.Running, True));
        Lines.Add('child-request-before-snapshot='
          + BoolToStr(FileExists(RequestPath), True));
        Lines.Add('child-owner-before-snapshot='
          + BoolToStr(FileExists(OwnerPath), True));
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('active-before-consumption='
          + IntToStr(Snapshot.ActiveWorkers));
        WriteMarker(ChildConsume, 'consume');
        if not WaitForFile(ChildAcquired, WAIT_TIMEOUT_MILLISECONDS) then
          raise Exception.Create('delegated child did not consume its lease');
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('active-during-child='
          + IntToStr(Snapshot.ActiveWorkers));
        Lines.Add('entries-during-child='
          + IntToStr(Length(Snapshot.Entries)));
        Lines.Add('child-request-after-snapshot='
          + BoolToStr(FileExists(RequestPath), True));
        Lines.Add('child-owner-after-snapshot='
          + BoolToStr(FileExists(OwnerPath), True));
        WriteMarker(ChildRelease, 'release');
        Child.WaitOnExit;
        Lines.Add('child-exit-status=' + IntToStr(Child.ExitStatus));
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('active-after-child='
          + IntToStr(Snapshot.ActiveWorkers));

        FreeAndNil(Child);
        Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
        Child := TProcess.Create(nil);
        Child.Executable := ExpandFileName(ParamStr(0));
        Child.Parameters.Add(UNCONSUMED_CHILD_SWITCH);
        AddWorkerEnvironment(Child, WorkerStateRoot);
        AppendWorkerLeaseEnvironment(Child.Environment, Lease);
        Child.Options := [poWaitOnExit];
        Child.Execute;
        Lines.Add('unconsumed-child-exit='
          + IntToStr(Child.ExitStatus));
        Lease.CancelPendingDelegation;
        Lease.Release;
        FreeAndNil(Lease);
        Snapshot := GetWorkerBudgetSnapshot;
        Lines.Add('active-after-unconsumed-child='
          + IntToStr(Snapshot.ActiveWorkers));
        Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
        Lines.Add('reacquired-after-unconsumed-child='
          + BoolToStr(Lease <> nil, True));
        Lease.Release;
        FreeAndNil(Lease);

        Lease := Session.Acquire(WAIT_TIMEOUT_MILLISECONDS);
        FirstEnvironment := TStringList.Create;
        try
          AppendWorkerLeaseEnvironment(FirstEnvironment, Lease);
          Lease.Release;
          Refused := False;
          CancellationError := '';
          try
            Lease.CancelPendingDelegation;
          except
            on E: ELWPTWorkerBudgetError do
            begin
              Refused := True;
              CancellationError := E.Message;
            end;
          end;
          Lines.Add('late-cancel-refused=' + BoolToStr(Refused, True));
          Lines.Add('late-cancel-error=' + CancellationError);
          Snapshot := GetWorkerBudgetSnapshot;
          Lines.Add('active-after-late-cancel='
            + IntToStr(Snapshot.ActiveWorkers));
        finally
          FirstEnvironment.Free;
          FreeAndNil(Lease);
        end;
      end;
      Lines.SaveToFile(OutputPath);
    finally
      if (Child <> nil) and Child.Running then
      begin
        WriteMarker(ChildConsume, 'consume');
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
      Lines.Add('root=' + WorkerStateRoot);
      Lines.Add('token-cleared=' + BoolToStr(
        GetEnvironmentVariable(WORKER_LEASE_TOKEN_ENV) = '', True));
      Lease.Release;
      FreeAndNil(Lease);
      Lease := Session.Acquire(2000);
      Snapshot := GetWorkerBudgetSnapshot;
      Lines.Add('reacquired=' + BoolToStr(Lease <> nil, True));
      Lines.Add('active-after-reacquire='
        + IntToStr(Snapshot.ActiveWorkers));
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

procedure TWorkerBudgetProcesses.DeleteScratch;
var
  Started : QWord;
  Elapsed : QWord;
  Remaining : QWord;
begin
  Started := GetTickCount64;
  repeat
    try
      RecursiveDelete(FScratch);
      Exit;
    except
      on Exception do
      begin
        { A reaped Windows process can briefly retain its working-directory
          handle. Retry that teardown window, but keep persistent leaks fatal. }
        Elapsed := GetTickCount64 - Started;
        if Elapsed >= QWord(SCRATCH_DELETE_TIMEOUT_MILLISECONDS) then
          raise;
        Remaining := QWord(SCRATCH_DELETE_TIMEOUT_MILLISECONDS) - Elapsed;
        if Remaining > QWord(SCRATCH_DELETE_RETRY_MILLISECONDS) then
          Sleep(SCRATCH_DELETE_RETRY_MILLISECONDS)
        else
          Sleep(Integer(Remaining));
        if GetTickCount64 - Started
           >= QWord(SCRATCH_DELETE_TIMEOUT_MILLISECONDS) then
          raise;
      end;
    end;
  until False;
end;

procedure TWorkerBudgetProcesses.ResetScratch;
begin
  DeleteScratch;
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

function ReadProcessStream(AStream: TStream;
  AAvailableBytes: Integer): string;
const
  CHUNK_SIZE = 4096;
var
  Buffer : array[0..CHUNK_SIZE - 1] of Byte;
  Count, Requested, Total : Integer;
begin
  Result := '';
  Total := 0;
  while Total < AAvailableBytes do
  begin
    Requested := AAvailableBytes - Total;
    if Requested > SizeOf(Buffer) then Requested := SizeOf(Buffer);
    Count := AStream.Read(Buffer, Requested);
    if Count > 0 then
    begin
      SetLength(Result, Total + Count);
      Move(Buffer, Result[Total + 1], Count);
      Inc(Total, Count);
    end;
    if Count <= 0 then Break;
  end;
end;

function RunStateRootUtility(const ASwitch, AOutputPath, AWorktree,
  AConfigHome, AExplicitRoot: string;
  const AExtraArgument: string = ''): TStateRootUtilityResult;
var
  Utility : TProcess;
  AvailableBytes : Integer;
begin
  Result.ExitCode := -1;
  Result.Stdout := '';
  Result.Stderr := '';
  Utility := TProcess.Create(nil);
  try
    Utility.Executable := ExpandFileName(ParamStr(0));
    Utility.Parameters.Add(ASwitch);
    Utility.Parameters.Add(AOutputPath);
    if AExtraArgument <> '' then
      Utility.Parameters.Add(AExtraArgument);
    Utility.CurrentDirectory := AWorktree;
    ConfigureProcessEnvironment(Utility, [
      'HOME=' + AConfigHome,
      'XDG_CONFIG_HOME=' + AConfigHome,
      WORKER_STATE_DIR_ENV + '=' + AExplicitRoot,
      WORKER_BUDGET_ENV + '=' + TEST_BUDGET,
      WORKER_STALE_SECONDS_ENV + '=' + TEST_STALE_SECONDS,
      WORKER_LEASE_TOKEN_ENV + '=']);
    Utility.Options := [poUsePipes];
    Utility.Execute;
    while Utility.Running do
    begin
      AvailableBytes := Utility.Output.NumBytesAvailable;
      if AvailableBytes > 0 then
        Result.Stdout := Result.Stdout
          + ReadProcessStream(Utility.Output, AvailableBytes);
      AvailableBytes := Utility.Stderr.NumBytesAvailable;
      if AvailableBytes > 0 then
        Result.Stderr := Result.Stderr
          + ReadProcessStream(Utility.Stderr, AvailableBytes);
      Sleep(10);
    end;
    AvailableBytes := Utility.Output.NumBytesAvailable;
    if AvailableBytes > 0 then
      Result.Stdout := Result.Stdout
        + ReadProcessStream(Utility.Output, AvailableBytes);
    AvailableBytes := Utility.Stderr.NumBytesAvailable;
    if AvailableBytes > 0 then
      Result.Stderr := Result.Stderr
        + ReadProcessStream(Utility.Stderr, AvailableBytes);
    Result.ExitCode := Utility.ExitCode;
    if (Result.ExitCode = 0) and (Utility.ExitStatus <> 0) then
      Result.ExitCode := Utility.ExitStatus;
  finally
    Utility.Free;
  end;
end;

function StartStateRootProbe(const AOutputPath, AReadyPath, AReleasePath,
  AWorktree, AConfigHome: string;
  const AExplicitRoot: string = ''): TProcess;
begin
  Result := TProcess.Create(nil);
  try
    Result.Executable := ExpandFileName(ParamStr(0));
    Result.Parameters.Add(STATE_ROOT_PROBE_SWITCH);
    Result.Parameters.Add(AOutputPath);
    Result.Parameters.Add(AReadyPath);
    Result.Parameters.Add(AReleasePath);
    Result.CurrentDirectory := AWorktree;
    ConfigureProcessEnvironment(Result, [
      'HOME=' + AConfigHome,
      'XDG_CONFIG_HOME=' + AConfigHome,
      WORKER_STATE_DIR_ENV + '=' + AExplicitRoot,
      WORKER_BUDGET_ENV + '=' + TEST_BUDGET,
      WORKER_STALE_SECONDS_ENV + '=' + TEST_STALE_SECONDS,
      WORKER_LEASE_TOKEN_ENV + '=']);
    Result.Execute;
  except
    Result.Free;
    raise;
  end;
end;

function StartStateRootRetryProbe(const AOutputPath, ACreateReadyPath,
  ACreateReleasePath, AWorktree, AConfigHome,
  AExplicitRoot: string): TProcess;
begin
  Result := TProcess.Create(nil);
  try
    Result.Executable := ExpandFileName(ParamStr(0));
    Result.Parameters.Add(STATE_ROOT_RETRY_PROBE_SWITCH);
    Result.Parameters.Add(AOutputPath);
    Result.Parameters.Add(ACreateReadyPath);
    Result.Parameters.Add(ACreateReleasePath);
    Result.CurrentDirectory := AWorktree;
    ConfigureProcessEnvironment(Result, [
      'HOME=' + AConfigHome,
      'XDG_CONFIG_HOME=' + AConfigHome,
      WORKER_STATE_DIR_ENV + '=' + AExplicitRoot,
      WORKER_BUDGET_ENV + '=' + TEST_BUDGET,
      WORKER_STALE_SECONDS_ENV + '=' + TEST_STALE_SECONDS,
      WORKER_LEASE_TOKEN_ENV + '=']);
    Result.Execute;
  except
    Result.Free;
    raise;
  end;
end;

function OccurrenceCount(const ANeedle, AText: string): Integer;
var
  Offset, FoundAt : Integer;
begin
  Result := 0;
  Offset := 1;
  repeat
    FoundAt := Pos(ANeedle, Copy(AText, Offset, MaxInt));
    if FoundAt = 0 then Exit;
    Inc(Result);
    Inc(Offset, FoundAt + Length(ANeedle) - 1);
  until False;
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
  DeleteScratch;
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
    Expect<string>(ChildValues.Values['reacquired']).ToBe('True');
    Expect<Integer>(StrToIntDef(
      ChildValues.Values['active-after-reacquire'], 0)).ToBe(1);
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
    if (StrToIntDef(
      Values.Values['parent-granted-after-delegation'], -1) <> 0)
       or (StrToIntDef(Values.Values['active-during-child'], 0) <> 1)
       or (StrToIntDef(Values.Values['active-after-child'], -1) <> 0) then
      Fail('worker delegation evidence:' + LineEnding + Values.Text);
    Expect<Integer>(StrToIntDef(
      Values.Values['parent-granted-after-delegation'], -1)).ToBe(0);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-before-consumption'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-during-child'], 0)).ToBe(1);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-child'], -1)).ToBe(0);
    Expect<Integer>(StrToIntDef(
      Values.Values['child-exit-status'], -1)).ToBe(0);
    Expect<Integer>(StrToIntDef(
      Values.Values['unconsumed-child-exit'], -1)).ToBe(0);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-unconsumed-child'], -1)).ToBe(0);
    Expect<string>(Values.Values[
      'reacquired-after-unconsumed-child']).ToBe('True');
    Expect<string>(Values.Values['late-cancel-refused']).ToBe('True');
    Expect<Boolean>(Pos('must cancel before Release',
      Values.Values['late-cancel-error']) > 0).ToBe(True);
    Expect<Integer>(StrToIntDef(
      Values.Values['active-after-late-cancel'], 0)).ToBe(1);
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

procedure TWorkerBudgetProcesses.TestConcurrentFirstProbesUseDefaultRoot;
var
  ConfigHome, FirstOutput, SecondOutput, FirstReady, SecondReady,
    ReleasePath, FirstFallback, SecondFallback : string;
  FirstProcess, SecondProcess : TProcess;
  FirstValues, SecondValues : TStringList;
begin
  ConfigHome := FScratch + '/probe-config-home';
  FirstOutput := FScratch + '/probe-first-result';
  SecondOutput := FScratch + '/probe-second-result';
  FirstReady := FScratch + '/probe-first-ready';
  SecondReady := FScratch + '/probe-second-ready';
  ReleasePath := FScratch + '/probe-release';
  FirstFallback := FScratch + '/worktree-a/' + WORKER_STATE_FALLBACK_DIR;
  SecondFallback := FScratch + '/worktree-b/' + WORKER_STATE_FALLBACK_DIR;
  ForceDirectories(ConfigHome);
  FirstProcess := nil;
  SecondProcess := nil;
  FirstValues := nil;
  SecondValues := nil;
  try
    FirstProcess := StartStateRootProbe(FirstOutput, FirstReady, ReleasePath,
      FScratch + '/worktree-a', ConfigHome);
    SecondProcess := StartStateRootProbe(SecondOutput, SecondReady, ReleasePath,
      FScratch + '/worktree-b', ConfigHome);
    Expect<Boolean>(WaitForFile(FirstReady,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    Expect<Boolean>(WaitForFile(SecondReady,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    WriteMarker(ReleasePath, 'probe');
    FirstProcess.WaitOnExit;
    SecondProcess.WaitOnExit;
    Expect<Integer>(FirstProcess.ExitStatus).ToBe(0);
    Expect<Integer>(SecondProcess.ExitStatus).ToBe(0);
    FirstValues := ReadUtilityValues(FirstOutput);
    SecondValues := ReadUtilityValues(SecondOutput);
    Expect<string>(FirstValues.Values['root']).ToBe(
      SecondValues.Values['root']);
    Expect<string>(FirstValues.Values['acquired']).ToBe('True');
    Expect<string>(SecondValues.Values['acquired']).ToBe('True');
    Expect<Boolean>(DirectoryExists(
      FirstValues.Values['root'])).ToBe(True);
    Expect<Boolean>(DirectoryExists(FirstFallback)).ToBe(False);
    Expect<Boolean>(DirectoryExists(SecondFallback)).ToBe(False);
  finally
    SecondValues.Free;
    FirstValues.Free;
    StopChild(SecondProcess);
    StopChild(FirstProcess);
  end;
end;

procedure TWorkerBudgetProcesses
  .TestFirstTransactionRetriesInterruptedRootCreation;
var
  OutputPath, RootCreateReady, RootCreateRelease, StateRoot : string;
  Probe : TProcess;
  Values : TStringList;
begin
  StateRoot := ExpandFileName(
    FScratch + '/interrupted-root/a/b/c/d/e/f/g/h/i/j');
  OutputPath := FScratch + '/interrupted-root-result';
  RootCreateReady := FScratch + '/root-create-ready';
  RootCreateRelease := FScratch + '/root-create-release';
  Probe := nil;
  Values := nil;
  try
    Probe := StartStateRootRetryProbe(OutputPath, RootCreateReady,
      RootCreateRelease, FScratch + '/worktree-a',
      FScratch + '/config-home', StateRoot);
    Expect<Boolean>(WaitForFile(RootCreateReady,
      WAIT_TIMEOUT_MILLISECONDS)).ToBe(True);
    Expect<Boolean>(DirectoryExists(StateRoot)).ToBe(False);
    WriteMarker(RootCreateRelease, 'retry');
    Probe.WaitOnExit;
    Expect<Integer>(Probe.ExitStatus).ToBe(0);
    Values := ReadUtilityValues(OutputPath);
    Expect<string>(Values.Values['root']).ToBe(StateRoot);
    Expect<string>(Values.Values['acquired']).ToBe('True');
    Expect<Boolean>(FileExists(StateRoot + '/' +
      TRANSACTION_LOCK_NAME)).ToBe(True);
  finally
    Values.Free;
    StopChild(Probe);
  end;
end;

procedure TWorkerBudgetProcesses
  .TestStateRootUtilityDrainsOutputWhileRunning;
var
  UtilityResult : TStateRootUtilityResult;
begin
  UtilityResult := RunStateRootUtility(STATE_ROOT_CAPTURE_SWITCH,
    FScratch + '/capture-result', FScratch + '/worktree-a',
    FScratch + '/config-home', '');
  Expect<Integer>(UtilityResult.ExitCode).ToBe(CAPTURE_EXIT_CODE);
  Expect<Boolean>(Pos(CAPTURE_STDOUT_PREFIX,
    UtilityResult.Stdout) = 1).ToBe(True);
  Expect<Boolean>(Pos(CAPTURE_STDOUT_SUFFIX,
    UtilityResult.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos(CAPTURE_STDERR_PREFIX,
    UtilityResult.Stderr) = 1).ToBe(True);
  Expect<Boolean>(Pos(CAPTURE_STDERR_SUFFIX,
    UtilityResult.Stderr) > 0).ToBe(True);
end;

{$IFDEF UNIX}
procedure TWorkerBudgetProcesses
  .TestDelegationPreservesFallbackRootAcrossWorkingDirectories;
var
  OutputPath, Worktree, ChildWorktree, ConfigHome, ExpectedRoot : string;
  UtilityResult : TStateRootUtilityResult;
  ParentValues, ChildValues : TStringList;
begin
  OutputPath := FScratch + '/fallback-delegation-result';
  Worktree := FScratch + '/worktree-a';
  ChildWorktree := FScratch + '/worktree-b';
  ConfigHome := FScratch + '/config-home';
  ForceDirectories(ConfigHome);
  UtilityResult := RunStateRootUtility(
    STATE_ROOT_FALLBACK_DELEGATION_SWITCH, OutputPath, Worktree,
    ConfigHome, '', ChildWorktree);
  Expect<Integer>(UtilityResult.ExitCode).ToBe(0);
  ParentValues := nil;
  ChildValues := nil;
  try
    ParentValues := ReadUtilityValues(OutputPath);
    ChildValues := ReadUtilityValues(ParentValues.Values['child-output']);
    ExpectedRoot := ExpandFileName(Worktree + '/'
      + WORKER_STATE_FALLBACK_DIR);
    Expect<string>(ParentValues.Values['parent-root']).ToBe(ExpectedRoot);
    Expect<string>(ParentValues.Values['child-environment-root']).ToBe(
      ExpectedRoot);
    Expect<Integer>(StrToIntDef(
      ParentValues.Values['child-exit'], -1)).ToBe(0);
    Expect<string>(ChildValues.Values['root']).ToBe(ExpectedRoot);
    Expect<string>(ChildValues.Values['acquired']).ToBe('True');
    Expect<Boolean>(DirectoryExists(ChildWorktree + '/'
      + WORKER_STATE_FALLBACK_DIR)).ToBe(False);
  finally
    ChildValues.Free;
    ParentValues.Free;
  end;
end;

procedure TWorkerBudgetProcesses.TestUnwritableDefaultFallsBackOnce;
var
  OutputPath, Worktree, ConfigHome, ExpectedRoot : string;
  UtilityResult : TStateRootUtilityResult;
  Values : TStringList;
begin
  OutputPath := FScratch + '/fallback-result';
  Worktree := FScratch + '/worktree-a';
  ConfigHome := FScratch + '/config-home';
  ForceDirectories(ConfigHome);
  UtilityResult := RunStateRootUtility(STATE_ROOT_FALLBACK_SWITCH,
    OutputPath, Worktree, ConfigHome, '');
  Expect<Integer>(UtilityResult.ExitCode).ToBe(0);
  Values := ReadUtilityValues(OutputPath);
  try
    ExpectedRoot := ExpandFileName(Worktree + '/'
      + WORKER_STATE_FALLBACK_DIR);
    Expect<string>(Values.Values['root-first']).ToBe(ExpectedRoot);
    Expect<string>(Values.Values['root-second']).ToBe(ExpectedRoot);
    Expect<string>(Values.Values['acquired']).ToBe('True');
    Expect<Boolean>(DirectoryExists(ExpectedRoot)).ToBe(True);
    Expect<Integer>(OccurrenceCount(
      'cross-worktree budget sharing is forfeited for this invocation',
      UtilityResult.Stderr)).ToBe(1);
    Expect<Boolean>(Pos(ExpectedRoot, UtilityResult.Stderr) > 0).ToBe(True);
    Expect<Boolean>(Pos(WORKER_STATE_DIR_ENV,
      UtilityResult.Stderr) > 0).ToBe(True);
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses
  .TestExistingLockDoesNotMaskUnwritableDefault;
var
  OutputPath, Worktree, ConfigHome, ExpectedRoot : string;
  UtilityResult : TStateRootUtilityResult;
  Values : TStringList;
begin
  OutputPath := FScratch + '/existing-lock-fallback-result';
  Worktree := FScratch + '/worktree-a';
  ConfigHome := FScratch + '/config-home';
  ForceDirectories(ConfigHome);
  UtilityResult := RunStateRootUtility(
    STATE_ROOT_EXISTING_LOCK_FALLBACK_SWITCH,
    OutputPath, Worktree, ConfigHome, '');
  Expect<Integer>(UtilityResult.ExitCode).ToBe(0);
  Values := ReadUtilityValues(OutputPath);
  try
    ExpectedRoot := ExpandFileName(Worktree + '/'
      + WORKER_STATE_FALLBACK_DIR);
    Expect<string>(Values.Values['root-first']).ToBe(ExpectedRoot);
    Expect<string>(Values.Values['acquired']).ToBe('True');
    Expect<Boolean>(FileExists(Values.Values['default-root'] + '/'
      + TRANSACTION_LOCK_NAME)).ToBe(True);
    Expect<string>(Values.Values['default-request-exists']).ToBe('False');
    Expect<string>(Values.Values['default-owner-exists']).ToBe('False');
    Expect<string>(Values.Values['default-budget-exists']).ToBe('False');
    Expect<string>(Values.Values['default-queue-exists']).ToBe('False');
  finally
    Values.Free;
  end;
end;

procedure TWorkerBudgetProcesses
  .TestUnwritableFallbackRequiresExplicitOverride;
var
  UtilityResult : TStateRootUtilityResult;
  OutputPath, Worktree, ConfigHome, ExpectedRoot : string;
begin
  OutputPath := FScratch + '/unwritable-fallback-result';
  Worktree := FScratch + '/worktree-a';
  ConfigHome := FScratch + '/config-home';
  ForceDirectories(ConfigHome);
  UtilityResult := RunStateRootUtility(
    STATE_ROOT_UNWRITABLE_FALLBACK_SWITCH,
    OutputPath, Worktree, ConfigHome, '');
  ExpectedRoot := ExpandFileName(Worktree + '/'
    + WORKER_STATE_FALLBACK_DIR);
  Expect<Boolean>(UtilityResult.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos(
    'worker state default and repository fallback at ' + ExpectedRoot
    + ' are unwritable', UtilityResult.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('set ' + WORKER_STATE_DIR_ENV
    + ' to a writable directory', UtilityResult.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('cross-worktree budget sharing is forfeited',
    UtilityResult.Stderr) = 0).ToBe(True);
end;

procedure TWorkerBudgetProcesses.TestUnwritableExplicitRootFails;
var
  OutputPath, Worktree, ConfigHome, ExplicitRoot : string;
  UtilityResult : TStateRootUtilityResult;
begin
  OutputPath := FScratch + '/explicit-result';
  Worktree := FScratch + '/worktree-a';
  ConfigHome := FScratch + '/config-home';
  ExplicitRoot := FScratch + '/explicit-read-only';
  ForceDirectories(ConfigHome);
  ForceDirectories(ExplicitRoot);
  if FpChmod(ExplicitRoot, &555) <> 0 then
    raise Exception.CreateFmt(
      'could not make explicit worker-state test root read-only: %s',
      [ExplicitRoot]);
  try
    UtilityResult := RunStateRootUtility(STATE_ROOT_EXPLICIT_SWITCH,
      OutputPath, Worktree, ConfigHome, ExplicitRoot);
  finally
    FpChmod(ExplicitRoot, &755);
  end;
  Expect<Boolean>(UtilityResult.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('failed to open worker-budget transaction lock at '
    + ExplicitRoot, UtilityResult.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('cross-worktree budget sharing is forfeited',
    UtilityResult.Stderr) = 0).ToBe(True);
  Expect<Boolean>(DirectoryExists(Worktree + '/'
    + WORKER_STATE_FALLBACK_DIR)).ToBe(False);
end;
{$ENDIF}

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
  Test('concurrent first probes keep the shared default root',
    TestConcurrentFirstProbesUseDefaultRoot);
  Test('first transaction retries interrupted state-root creation',
    TestFirstTransactionRetriesInterruptedRootCreation);
  Test('state-root utility drains subprocess output while it runs',
    TestStateRootUtilityDrainsOutputWhileRunning);
  {$IFDEF UNIX}
  Test('delegation preserves fallback root across working directories',
    TestDelegationPreservesFallbackRootAcrossWorkingDirectories);
  Test('an unwritable default state root falls back once per process',
    TestUnwritableDefaultFallsBackOnce);
  Test('an existing transaction lock does not mask an unwritable default',
    TestExistingLockDoesNotMaskUnwritableDefault);
  Test('an unwritable fallback requires an explicit writable override',
    TestUnwritableFallbackRequiresExplicitOverride);
  Test('an unwritable explicit state root remains a hard failure',
    TestUnwritableExplicitRootFails);
  {$ENDIF}
end;

begin
  if RunChildMode then Exit;
  TestRunnerProgram.AddSuite(TWorkerBudgetProcesses.Create(
    'worker budget: cross-process leases'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
