{ LWPT.ProcessTree — isolated subprocess ownership and cascading cancellation.
  See ADR-0025 for the process-group, nested-job, signal-forwarding, and
  reap-until-empty contracts. }
unit LWPT.ProcessTree;

{$I Shared.inc}
{$J-}

interface

uses
  Process,
  SysUtils,

  LWPT.Core;

type
  TLWPTProcessTree = class
  private
    FProcess: TProcess;
    FPlatformState: Pointer;
    FRegistered: Boolean;
    FImmediateTerminationRequested: LongInt;
    FTerminationCriticalSection: TRTLCriticalSection;
    {$IFDEF UNIX}
    procedure HandleFork(ASender: TObject);
    {$ENDIF}
    procedure RegisterActive;
    procedure UnregisterActive;
    procedure MarkManagedChild;
    procedure BeginForwardedTermination;
    procedure WaitForForwardedTermination(const ADeadline: QWord);
    procedure TryTerminateDirectChild;
    {$IFDEF MSWINDOWS}
    procedure TerminateCreatedProcess;
    {$ENDIF}
  public
    constructor Create(const AProcess: TProcess);
    destructor Destroy; override;
    procedure Execute;
    procedure Terminate;
  end;

procedure InstallProcessTreeSignalForwarding;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF};

{$if not declared(FD_CLOEXEC)}
{ POSIX fixes FD_CLOEXEC at 1; Darwin's BaseUnix declares it but Linux
  FPC's does not, so define it where the RTL omits it. }
const
  FD_CLOEXEC = 1;
{$endif}

const
  ProcessTreeTerminateGraceMilliseconds = 250;
  ProcessTreeTerminatePollMilliseconds = 10;
  ProcessTreeReapTimeoutMilliseconds = 3000;
  ForwardedReapTimeoutMilliseconds = 100;
  ProcessTreeSetupExitCode = 127;
  ProcessTreeCancellationExitCode = 1;
  SignalExitCodeBase = 128;
  ProcessGroupSetupError = 'process tree isolation setup failed'#10;
  ManagedProcessTreeEnvironment = PROJECT_NAME + '_PROCESS_TREE_PARENT';

  {$IFDEF MSWINDOWS}
  JobObjectBasicAccountingInformationClass = 1;
  NestedJobRequirement = '; nested Job Objects require Windows 8 or later';
  {$ENDIF}

var
  ActiveProcessTrees: TList;
  ActiveProcessTreesCriticalSection: TRTLCriticalSection;
  SignalForwardingInstalled: Boolean = False;

{$IFDEF UNIX}
const
  SignalPipeReadEnd = 0;
  SignalPipeWriteEnd = 1;

type
  TLWPTSignalForwarder = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  SignalForwarder: TLWPTSignalForwarder = nil;
  SignalPipe: TFilDes;

function CSetProcessGroup(const APID,
  AProcessGroupID: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setpgid';
  {$ELSE}
  external name 'setpgid';
  {$ENDIF}

function CSignal(const ASignal: LongInt;
  const AHandler: Pointer): Pointer; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'signal';
  {$ELSE}
  external name 'signal';
  {$ENDIF}

function CRaise(const ASignal: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'raise';
  {$ELSE}
  external name 'raise';
  {$ENDIF}

function SignalHandlerFailed(const AHandler: Pointer): Boolean; inline;
begin
  Result := PtrUInt(AHandler) = High(PtrUInt);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
{$PACKRECORDS C}
type
  PLWPTWindowsProcessTreeState = ^TLWPTWindowsProcessTreeState;
  TLWPTWindowsProcessTreeState = record
    JobHandle: THandle;
  end;

  TLWPTJobObjectBasicAccountingInformation = record
    TotalUserTime: Int64;
    TotalKernelTime: Int64;
    ThisPeriodTotalUserTime: Int64;
    ThisPeriodTotalKernelTime: Int64;
    TotalPageFaultCount: DWORD;
    TotalProcesses: DWORD;
    ActiveProcesses: DWORD;
    TotalTerminatedProcesses: DWORD;
  end;
{$PACKRECORDS DEFAULT}

function LWPTCreateJobObject(const ASecurityAttributes: Pointer;
  const AName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';
function LWPTAssignProcessToJobObject(const AJob,
  AProcess: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';
function LWPTTerminateJobObject(const AJob: THandle;
  const AExitCode: UINT): BOOL; stdcall;
  external 'kernel32.dll' name 'TerminateJobObject';
function LWPTQueryInformationJobObject(const AJob: THandle;
  const AInformationClass: DWORD; const AInformation: Pointer;
  const AInformationLength: DWORD; const AReturnLength: PDWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryInformationJobObject';

function WindowsProcessTreeState(
  const APlatformState: Pointer): PLWPTWindowsProcessTreeState; inline;
begin
  Result := PLWPTWindowsProcessTreeState(APlatformState);
end;
{$ENDIF}

{$IFDEF UNIX}
function ProcessGroupExists(const AProcessGroupID: LongInt;
  out AErrorCode: Integer): Boolean; forward;
{$ENDIF}

{$IFDEF MSWINDOWS}
function JobHasActiveProcesses(const AJobHandle: THandle): Boolean; forward;
{$ENDIF}

procedure TLWPTProcessTree.RegisterActive;
begin
  EnterCriticalSection(ActiveProcessTreesCriticalSection);
  try
    if FRegistered then Exit;
    ActiveProcessTrees.Add(Self);
    FRegistered := True;
  finally
    LeaveCriticalSection(ActiveProcessTreesCriticalSection);
  end;
end;

procedure TLWPTProcessTree.UnregisterActive;
begin
  EnterCriticalSection(ActiveProcessTreesCriticalSection);
  try
    if not FRegistered then Exit;
    ActiveProcessTrees.Remove(Self);
    FRegistered := False;
  finally
    LeaveCriticalSection(ActiveProcessTreesCriticalSection);
  end;
end;

constructor TLWPTProcessTree.Create(const AProcess: TProcess);
{$IFDEF MSWINDOWS}
var
  State: PLWPTWindowsProcessTreeState;
{$ENDIF}
begin
  inherited Create;
  InitCriticalSection(FTerminationCriticalSection);
  if not Assigned(AProcess) then
    raise EArgumentNilException.Create('process');
  FProcess := AProcess;
  FPlatformState := nil;
  FRegistered := False;
  FImmediateTerminationRequested := 0;
  {$IFDEF UNIX}
  FProcess.OnForkEvent := HandleFork;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  New(State);
  State^.JobHandle := LWPTCreateJobObject(nil, nil);
  if State^.JobHandle = 0 then
  begin
    Dispose(State);
    RaiseLastOSError;
  end;
  FPlatformState := State;
  { Windows 8+ permits the suspended child to join this inner job while
    retaining inherited membership in an enclosing LWPT or host job. }
  FProcess.Options := FProcess.Options + [poRunSuspended];
  {$ENDIF}
end;

function EnvironmentEntryName(const AEntry: string): string;
var
  Separator: Integer;
begin
  Separator := Pos('=', AEntry);
  if Separator = 0 then Result := AEntry
  else Result := Copy(AEntry, 1, Separator - 1);
end;

function EnvironmentNamesEqual(const ALeft, ARight: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ALeft, ARight);
  {$ELSE}
  Result := ALeft = ARight;
  {$ENDIF}
end;

procedure TLWPTProcessTree.MarkManagedChild;
var
  EnvironmentIndex: Integer;
begin
  if FProcess.Environment.Count = 0 then
    for EnvironmentIndex := 1 to GetEnvironmentVariableCount do
      FProcess.Environment.Add(GetEnvironmentString(EnvironmentIndex));
  for EnvironmentIndex := FProcess.Environment.Count - 1 downto 0 do
    if EnvironmentNamesEqual(
      EnvironmentEntryName(FProcess.Environment[EnvironmentIndex]),
      ManagedProcessTreeEnvironment) then
      FProcess.Environment.Delete(EnvironmentIndex);
  FProcess.Environment.Add(ManagedProcessTreeEnvironment + '=1');
end;

destructor TLWPTProcessTree.Destroy;
{$IFDEF MSWINDOWS}
var
  State: PLWPTWindowsProcessTreeState;
{$ENDIF}
begin
  UnregisterActive;
  {$IFDEF UNIX}
  if Assigned(FProcess) then FProcess.OnForkEvent := nil;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  State := WindowsProcessTreeState(FPlatformState);
  if Assigned(State) then
  begin
    if State^.JobHandle <> 0 then Windows.CloseHandle(State^.JobHandle);
    Dispose(State);
    FPlatformState := nil;
  end;
  {$ENDIF}
  DoneCriticalSection(FTerminationCriticalSection);
  inherited Destroy;
end;

{$IFDEF UNIX}
procedure TLWPTProcessTree.HandleFork(ASender: TObject);
begin
  { A forked child resets the forwarding handlers before exec. setpgid(2)
    and signal(3) are async-signal-safe in this post-fork path. }
  if (CSetProcessGroup(0, 0) = 0)
     and not SignalHandlerFailed(CSignal(SIGTERM, nil))
     and not SignalHandlerFailed(CSignal(SIGINT, nil)) then Exit;
  FpWrite(StdErrorHandle, ProcessGroupSetupError[1],
    Length(ProcessGroupSetupError));
  FpExit(ProcessTreeSetupExitCode);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure TLWPTProcessTree.TerminateCreatedProcess;
var
  ErrorCode: DWORD;
begin
  if not Windows.TerminateProcess(FProcess.ProcessHandle,
    ProcessTreeSetupExitCode) then
  begin
    ErrorCode := Windows.GetLastError;
    if Windows.WaitForSingleObject(FProcess.ProcessHandle, 0)
      <> Windows.WAIT_OBJECT_0 then
      raise EOSError.CreateFmt('could not terminate isolated process: %s',
        [SysErrorMessage(ErrorCode)]);
  end;
  Windows.WaitForSingleObject(FProcess.ProcessHandle, Windows.INFINITE);
end;
{$ENDIF}

procedure TLWPTProcessTree.Execute;
{$IFDEF UNIX}
var
  ErrorCode: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
  ErrorSuffix: string;
  State: PLWPTWindowsProcessTreeState;
{$ENDIF}
begin
  { Registration precedes the spawn. The termination lock then makes a signal
    arriving during Execute wait until the new group/job is fully addressable. }
  MarkManagedChild;
  RegisterActive;
  try
    EnterCriticalSection(FTerminationCriticalSection);
    try
      FProcess.Execute;
      {$IFDEF UNIX}
      { Close the parent/child race: either this call creates the group, or
        EACCES proves the child has passed the pre-exec fork handler. }
      if CSetProcessGroup(FProcess.ProcessID, FProcess.ProcessID) <> 0 then
      begin
        ErrorCode := FpGetErrNo;
        if not (ErrorCode in [ESysEACCES, ESysESRCH]) then
        begin
          FProcess.Terminate(ProcessTreeSetupExitCode);
          FProcess.WaitOnExit;
          raise EOSError.CreateFmt('could not isolate process tree: %s',
            [SysErrorMessage(ErrorCode)]);
        end;
      end;
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      State := WindowsProcessTreeState(FPlatformState);
      if not LWPTAssignProcessToJobObject(State^.JobHandle,
        FProcess.ProcessHandle) then
      begin
        ErrorCode := Windows.GetLastError;
        TerminateCreatedProcess;
        ErrorSuffix := '';
        if ErrorCode = Windows.ERROR_ACCESS_DENIED then
          ErrorSuffix := NestedJobRequirement;
        raise EOSError.CreateFmt('could not assign process to Job Object: %s%s',
          [SysErrorMessage(ErrorCode), ErrorSuffix]);
      end;
      if Windows.ResumeThread(FProcess.ThreadHandle) = DWORD(-1) then
      begin
        ErrorCode := Windows.GetLastError;
        TerminateCreatedProcess;
        raise EOSError.CreateFmt('could not resume isolated process: %s',
          [SysErrorMessage(ErrorCode)]);
      end;
      {$ENDIF}
    finally
      LeaveCriticalSection(FTerminationCriticalSection);
    end;
  except
    UnregisterActive;
    raise;
  end;
end;

procedure TLWPTProcessTree.BeginForwardedTermination;
{$IFDEF UNIX}
var
  ErrorCode, ProcessGroupID: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
  State: PLWPTWindowsProcessTreeState;
{$ENDIF}
begin
  InterlockedExchange(FImmediateTerminationRequested, 1);
  EnterCriticalSection(FTerminationCriticalSection);
  try
    {$IFDEF UNIX}
    ProcessGroupID := FProcess.ProcessID;
    if ProcessGroupID <= 0 then Exit;
    if FpKill(-ProcessGroupID, SIGKILL) <> 0 then
    begin
      ErrorCode := FpGetErrNo;
      if ErrorCode = ESysESRCH then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not kill process tree: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    State := WindowsProcessTreeState(FPlatformState);
    if not Assigned(State) or (State^.JobHandle = 0) then Exit;
    if not JobHasActiveProcesses(State^.JobHandle) then Exit;
    if not LWPTTerminateJobObject(State^.JobHandle,
      ProcessTreeCancellationExitCode) then
    begin
      ErrorCode := Windows.GetLastError;
      if not JobHasActiveProcesses(State^.JobHandle) then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not terminate process Job Object: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
end;

procedure TLWPTProcessTree.WaitForForwardedTermination(
  const ADeadline: QWord);
{$IFDEF UNIX}
var
  ErrorCode, ProcessGroupID: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  State: PLWPTWindowsProcessTreeState;
{$ENDIF}
begin
  EnterCriticalSection(FTerminationCriticalSection);
  try
    {$IFDEF UNIX}
    ProcessGroupID := FProcess.ProcessID;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    State := WindowsProcessTreeState(FPlatformState);
    {$ENDIF}
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  {$IFDEF UNIX}
  if ProcessGroupID <= 0 then Exit;
  while ProcessGroupExists(ProcessGroupID, ErrorCode)
    and (GetTickCount64 < ADeadline) do
    Sleep(ProcessTreeTerminatePollMilliseconds);
  if ProcessGroupExists(ProcessGroupID, ErrorCode) then
  begin
    TryTerminateDirectChild;
    raise EOSError.CreateFmt(
      'process group %d still had members after forwarded termination',
      [ProcessGroupID]);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not Assigned(State) or (State^.JobHandle = 0) then Exit;
  while JobHasActiveProcesses(State^.JobHandle)
    and (GetTickCount64 < ADeadline) do
    Sleep(ProcessTreeTerminatePollMilliseconds);
  if JobHasActiveProcesses(State^.JobHandle) then
  begin
    TryTerminateDirectChild;
    raise EOSError.Create(
      'process Job Object still had active processes after forwarded termination');
  end;
  {$ENDIF}
end;

procedure TLWPTProcessTree.TryTerminateDirectChild;
begin
  if (not Assigned(FProcess)) or (FProcess.ProcessID <= 0) then Exit;
  {$IFDEF UNIX}
  FpKill(FProcess.ProcessID, SIGKILL);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows.TerminateProcess(FProcess.ProcessHandle,
    ProcessTreeCancellationExitCode);
  {$ENDIF}
end;

{$IFDEF UNIX}
function ProcessGroupExists(const AProcessGroupID: LongInt;
  out AErrorCode: Integer): Boolean;
begin
  AErrorCode := 0;
  if FpKill(-AProcessGroupID, 0) = 0 then Exit(True);
  AErrorCode := FpGetErrNo;
  if AErrorCode = ESysEPERM then Exit(True);
  if AErrorCode = ESysESRCH then Exit(False);
  raise EOSError.CreateFmt('could not inspect process tree: %s',
    [SysErrorMessage(AErrorCode)]);
end;

procedure WaitForProcessGroupEmpty(const AProcessGroupID: LongInt;
  const ATimeoutMilliseconds: Integer);
var
  ErrorCode, WaitedMilliseconds: Integer;
begin
  WaitedMilliseconds := 0;
  while ProcessGroupExists(AProcessGroupID, ErrorCode)
    and (WaitedMilliseconds < ATimeoutMilliseconds) do
  begin
    Sleep(ProcessTreeTerminatePollMilliseconds);
    Inc(WaitedMilliseconds, ProcessTreeTerminatePollMilliseconds);
  end;
  if ProcessGroupExists(AProcessGroupID, ErrorCode) then
    raise EOSError.CreateFmt(
      'process group %d still had members after termination',
      [AProcessGroupID]);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function JobHasActiveProcesses(const AJobHandle: THandle): Boolean;
var
  Accounting: TLWPTJobObjectBasicAccountingInformation;
  ErrorCode: DWORD;
begin
  FillChar(Accounting, SizeOf(Accounting), 0);
  if not LWPTQueryInformationJobObject(AJobHandle,
    JobObjectBasicAccountingInformationClass, @Accounting,
    SizeOf(Accounting), nil) then
  begin
    ErrorCode := Windows.GetLastError;
    raise EOSError.CreateFmt('could not inspect process Job Object: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  Result := Accounting.ActiveProcesses > 0;
end;

procedure WaitForJobEmpty(const AJobHandle: THandle;
  const ATimeoutMilliseconds: Integer);
var
  WaitedMilliseconds: Integer;
begin
  WaitedMilliseconds := 0;
  while JobHasActiveProcesses(AJobHandle)
    and (WaitedMilliseconds < ATimeoutMilliseconds) do
  begin
    Sleep(ProcessTreeTerminatePollMilliseconds);
    Inc(WaitedMilliseconds, ProcessTreeTerminatePollMilliseconds);
  end;
  if JobHasActiveProcesses(AJobHandle) then
    raise EOSError.Create(
      'process Job Object still had active processes after termination');
end;
{$ENDIF}

procedure TLWPTProcessTree.Terminate;
{$IFDEF UNIX}
var
  ErrorCode, ProcessGroupID, ReapTimeoutMilliseconds,
    WaitedMilliseconds: Integer;
  ImmediateTermination: Boolean;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
  State: PLWPTWindowsProcessTreeState;
{$ENDIF}
begin
  EnterCriticalSection(FTerminationCriticalSection);
  try
    {$IFDEF UNIX}
    ProcessGroupID := FProcess.ProcessID;
    if ProcessGroupID <= 0 then Exit;
    ImmediateTermination := FImmediateTerminationRequested <> 0;
    if (not ImmediateTermination)
       and (FpKill(-ProcessGroupID, SIGTERM) <> 0) then
    begin
      ErrorCode := FpGetErrNo;
      if ErrorCode = ESysESRCH then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not terminate process tree: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    State := WindowsProcessTreeState(FPlatformState);
    if not Assigned(State) or (State^.JobHandle = 0) then Exit;
    if not JobHasActiveProcesses(State^.JobHandle) then Exit;
    if not LWPTTerminateJobObject(State^.JobHandle,
      ProcessTreeCancellationExitCode) then
    begin
      ErrorCode := Windows.GetLastError;
      if not JobHasActiveProcesses(State^.JobHandle) then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not terminate process Job Object: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  {$IFDEF UNIX}
  WaitedMilliseconds := 0;
  while (FImmediateTerminationRequested = 0)
    and ProcessGroupExists(ProcessGroupID, ErrorCode)
    and (WaitedMilliseconds < ProcessTreeTerminateGraceMilliseconds) do
  begin
    Sleep(ProcessTreeTerminatePollMilliseconds);
    Inc(WaitedMilliseconds, ProcessTreeTerminatePollMilliseconds);
  end;
  if not ProcessGroupExists(ProcessGroupID, ErrorCode) then Exit;

  EnterCriticalSection(FTerminationCriticalSection);
  try
    if FpKill(-ProcessGroupID, SIGKILL) <> 0 then
    begin
      ErrorCode := FpGetErrNo;
      if ErrorCode = ESysESRCH then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not kill process tree: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  ReapTimeoutMilliseconds := ProcessTreeReapTimeoutMilliseconds;
  if FImmediateTerminationRequested <> 0 then
    ReapTimeoutMilliseconds := ForwardedReapTimeoutMilliseconds;
  try
    WaitForProcessGroupEmpty(ProcessGroupID, ReapTimeoutMilliseconds);
  except
    TryTerminateDirectChild;
    raise;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  try
    WaitForJobEmpty(State^.JobHandle, ProcessTreeReapTimeoutMilliseconds);
  except
    TryTerminateDirectChild;
    raise;
  end;
  {$ENDIF}
end;

procedure TerminateRegisteredProcessTrees(const AImmediate: Boolean);
var
  Deadline: QWord;
  FirstFailure: string;
  Index: Integer;

  procedure RecordFailure(const AMessage: string);
  begin
    if FirstFailure = '' then FirstFailure := AMessage;
  end;
begin
  FirstFailure := '';
  { This runs on a dedicated forwarding thread, not in an async Unix handler.
    Holding the registry lock pins each object until bounded termination ends.
    Forwarded teardown kills every tree before polling any one of them, and all
    polls share one deadline shorter than the ancestor's graceful window. }
  EnterCriticalSection(ActiveProcessTreesCriticalSection);
  try
    if AImmediate then
    begin
      Deadline := GetTickCount64 + ForwardedReapTimeoutMilliseconds;
      for Index := 0 to ActiveProcessTrees.Count - 1 do
        try
          TLWPTProcessTree(ActiveProcessTrees[Index])
            .BeginForwardedTermination;
        except
          on E: Exception do RecordFailure(E.Message);
        end;
      for Index := 0 to ActiveProcessTrees.Count - 1 do
        try
          TLWPTProcessTree(ActiveProcessTrees[Index])
            .WaitForForwardedTermination(Deadline);
        except
          on E: Exception do RecordFailure(E.Message);
        end;
    end
    else
      for Index := 0 to ActiveProcessTrees.Count - 1 do
        try
          TLWPTProcessTree(ActiveProcessTrees[Index]).Terminate;
        except
          on E: Exception do RecordFailure(E.Message);
        end;
  finally
    LeaveCriticalSection(ActiveProcessTreesCriticalSection);
  end;
  if FirstFailure <> '' then
    raise EOSError.Create(FirstFailure);
end;

procedure ReportForwardingFailure(const AMessage: string);
{$IFDEF UNIX}
var
  OutputLine: string;
{$ENDIF}
begin
  {$IFDEF UNIX}
  OutputLine := 'process-tree signal forwarding failed: ' + AMessage
    + LineEnding;
  FpWrite(StdErrorHandle, OutputLine[1], Length(OutputLine));
  {$ENDIF}
end;

{$IFDEF UNIX}
procedure TLWPTSignalForwarder.Execute;
var
  BytesRead, ReceivedSignal: LongInt;
  SignalSet: sigset_t;
begin
  repeat
    BytesRead := FpRead(SignalPipe[SignalPipeReadEnd], ReceivedSignal,
      SizeOf(ReceivedSignal));
  until BytesRead = SizeOf(ReceivedSignal);
  try
    TerminateRegisteredProcessTrees(
      SysUtils.GetEnvironmentVariable(ManagedProcessTreeEnvironment) = '1');
  except
    on E: Exception do
    begin
      ReportForwardingFailure(E.Message);
      FpExit(ProcessTreeCancellationExitCode);
    end;
  end;
  { Restore the default disposition before re-sending the original signal so
    shells and ancestor schedulers observe the original form of death. }
  FpSigEmptySet(SignalSet);
  FpSigAddSet(SignalSet, ReceivedSignal);
  FpSigProcMask(SIG_UNBLOCK, @SignalSet, nil);
  CSignal(ReceivedSignal, nil);
  CRaise(ReceivedSignal);
  FpExit(SignalExitCodeBase + ReceivedSignal);
end;

procedure ProcessTreeSignalHandler(ASignal: LongInt); cdecl;
begin
  { write(2) is async-signal-safe. The pipe is nonblocking, and one complete
    LongInt write is below PIPE_BUF; if repeated signals fill it, an earlier
    queued signal already guarantees that forwarding will run. }
  FpWrite(SignalPipe[SignalPipeWriteEnd], ASignal, SizeOf(ASignal));
end;
{$ENDIF}

procedure InstallProcessTreeSignalForwarding;
{$IFDEF UNIX}
var
  PreviousInterruptHandler, PreviousTerminateHandler: Pointer;
  ErrorCode: Integer;
  InterruptHandlerInstalled, TerminateHandlerInstalled: Boolean;
{$ENDIF}
begin
  {$IFDEF UNIX}
  if SignalForwardingInstalled then Exit;
  InterruptHandlerInstalled := False;
  TerminateHandlerInstalled := False;
  if FpPipe(SignalPipe) <> 0 then
  begin
    ErrorCode := FpGetErrNo;
    raise EOSError.CreateFmt(
      'could not create process-tree signal pipe: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  try
    if (FpFcntl(SignalPipe[SignalPipeReadEnd], F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(SignalPipe[SignalPipeWriteEnd], F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(SignalPipe[SignalPipeWriteEnd], F_SetFl, O_NONBLOCK) < 0) then
    begin
      ErrorCode := FpGetErrNo;
      raise EOSError.CreateFmt(
        'could not configure process-tree signal pipe: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    PreviousTerminateHandler := CSignal(SIGTERM,
      @ProcessTreeSignalHandler);
    if SignalHandlerFailed(PreviousTerminateHandler) then RaiseLastOSError;
    TerminateHandlerInstalled := True;
    PreviousInterruptHandler := CSignal(SIGINT,
      @ProcessTreeSignalHandler);
    if SignalHandlerFailed(PreviousInterruptHandler) then RaiseLastOSError;
    InterruptHandlerInstalled := True;
    SignalForwarder := TLWPTSignalForwarder.Create(True);
    SignalForwarder.FreeOnTerminate := False;
    SignalForwarder.Start;
    SignalForwardingInstalled := True;
  except
    if InterruptHandlerInstalled then
      CSignal(SIGINT, PreviousInterruptHandler);
    if TerminateHandlerInstalled then
      CSignal(SIGTERM, PreviousTerminateHandler);
    FpClose(SignalPipe[SignalPipeReadEnd]);
    FpClose(SignalPipe[SignalPipeWriteEnd]);
    raise;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  { Console-control forwarding is deferred. Scheduler cancellation continues
    to terminate each registered Job Object directly. }
  Exit;
  {$ENDIF}
end;

initialization
  ActiveProcessTrees := TList.Create;
  InitCriticalSection(ActiveProcessTreesCriticalSection);

end.
