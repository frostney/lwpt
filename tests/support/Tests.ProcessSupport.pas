{ Tests.ProcessSupport — cross-platform process-liveness assertions and the
  bounded child-process waits that test code uses instead of FPC's
  unbounded ones.

  Test code never waits for a child without a deadline. A parameterless
  TProcess.WaitOnExit, poWaitOnExit, and TProcess.Terminate (whose Unix
  implementation ends in an untimed WaitOnExit, fcl-process/src/unix/
  process.inc in FPC 3.2.2) all hang a test program until CI's job bound
  when a child never exits. ChildWaitGuard.Test enforces the rule.

  The waits here poll TProcess.Running, a nonblocking status query that also
  reaps an exited child on Unix. That reap stores the raw waitpid(2) status,
  so read the result with ChildProcessExitCode, never ExitStatus alone: on
  Unix ExitStatus then holds the raw status (an exit code shifted left by
  eight bits), where after FPC's WaitOnExit it held the decoded code.

  Process-tree ownership. TerminateChildProcess signals the direct child.
  That suffices for children that work in-process, and for Unix LWPT
  children, which forward SIGTERM to the process groups they own (ADR-0025).
  A child started with ExecuteOwnedChild is owned with its descendants:

    - on Windows it runs in a Job Object of its own, created
      kill-on-close and assigned before the child's first instruction, so
      termination ends nested LWPT children and compiler proxies that
      TerminateProcess would leave behind, and freeing the TProcess ends any
      survivor;
    - on Unix, with AOwnProcessGroup, it leads a process group of its own and
      termination signals the whole group. Use this only for children that
      forward no signal to their descendants (shells, proxies): the group is
      outside the test program's own, so the test runner's cancellation no
      longer reaches it. On Linux the direct child also receives SIGKILL
      when this program dies. Without AOwnProcessGroup the child stays in
      this program's group. }
unit Tests.ProcessSupport;

{$mode delphi}{$H+}

interface

uses
  Classes,
  Process,
  SysUtils,

  Pipes;

const
  ProcessPollMilliseconds = 10;
  SecondsPerDay = 86400;
  { How long a child gets to exit after SIGTERM (Windows: TerminateProcess
    or TerminateJobObject) before SIGKILL, and how long after SIGKILL
    before cleanup gives up. }
  CHILD_TERMINATION_GRACE_MILLISECONDS = 2000;
  CHILD_KILL_MILLISECONDS = 2000;
  { The deadline of a child wait that names none. It matches the RunLwpt
    default (Tests.LwptSubprocess), whose measured basis is recorded in
    docs/testing.md, and stays well inside a CI job's bound. }
  CHILD_COMPLETION_TIMEOUT_MILLISECONDS = 300000;

type
  { A child outlived the deadline of a FinishChild call and was terminated. }
  EChildProcessTimeout = class(Exception);
  { A child started with ExecuteOwnedChild finished while members of its
    Job Object or process group still ran; see OwnedChildSurvivors. }
  EChildProcessSurvivors = class(Exception);

function ProcessIsRunning(const APID: Integer): Boolean;
{ ProcessIsRunning that treats an exited process as gone even before its
  parent reaps it: on Linux a process in state Z or X (procfs) no longer
  runs, although kill(pid, 0) still succeeds for it, which a subreaper that
  defers reaping makes last. Elsewhere it is ProcessIsRunning. }
function ProcessIsLive(const APID: Integer): Boolean;

{ Drains only the bytes reported available at entry. A child can stay live
  after one progress line, and descendants can inherit its pipe writer, so
  reading until EOF would make deadlines unreachable. }
function DrainAvailableStream(AStream: TInputPipeStream;
  const AMaximumBytes: Integer = High(Integer)): string;
{ Appends what a poUsePipes child has written so far; no-op without pipes. }
procedure DrainChildPipes(AProcess: TProcess; var AStdout, AStderr: string);

{ Polls, bounded, until AProcess has exited. On Windows an exited child is
  then waited for, within what remains of the allowance, until its handle
  rundown completes, so its working directory and files are released; a
  zero allowance is a nonblocking check. True when it exited. The variant
  with output drains a poUsePipes child meanwhile. The other never reads
  the pipes: use it only for a child without pipes or one whose pipes
  another reader owns (a reader thread), because a child that fills an
  unread pipe cannot exit. }
function WaitForChildExit(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord): Boolean; overload;
function WaitForChildExit(AProcess: TProcess; var AStdout, AStderr: string;
  const ATimeoutMilliseconds: QWord): Boolean; overload;

{ Ends a started child without TProcess.Terminate: SIGTERM (Windows:
  TerminateProcess), AGraceMilliseconds to exit, then SIGKILL and
  AKillMilliseconds more, reaping it through WaitForChildExit. A child
  started with ExecuteOwnedChild is ended with its process group or Job
  Object, and True then also means that no member survives. A poUsePipes
  child has its pipes drained into AStdout and AStderr meanwhile, or
  discarded by the variant without them. Returns False when it still had
  not exited; the caller owns and frees AProcess. }
function TerminateChildProcess(AProcess: TProcess; var AStdout,
  AStderr: string;
  const AGraceMilliseconds: QWord = CHILD_TERMINATION_GRACE_MILLISECONDS;
  const AKillMilliseconds: QWord = CHILD_KILL_MILLISECONDS): Boolean;
  overload;
function TerminateChildProcess(AProcess: TProcess;
  const AGraceMilliseconds: QWord = CHILD_TERMINATION_GRACE_MILLISECONDS;
  const AKillMilliseconds: QWord = CHILD_KILL_MILLISECONDS): Boolean;
  overload;

{ Ends a started child at once, like a host crash or a cancelled CI job:
  SIGKILL (Windows: TerminateProcess), to its process group or Job Object
  when ExecuteOwnedChild owns it. It does not wait; follow it with a
  bounded wait such as WaitForChildExit. }
procedure KillChildProcess(AProcess: TProcess);

{ The exit code of a child reaped by these waits: ExitCode, or ExitStatus
  when ExitCode reads 0 but the child did not exit cleanly (a signal on
  Unix). Mirrors LWPT.Command.Common.NormalisedExitCode without linking it. }
function ChildProcessExitCode(AProcess: TProcess): Integer;

{ Waits for a started child to finish within ATimeoutMilliseconds and
  returns ChildProcessExitCode. A child past its deadline is ended through
  TerminateChildProcess and EChildProcessTimeout is raised, naming
  ADescription, the command line, and any drained output. A poUsePipes
  child is drained while it runs, into AStdout and AStderr or, by the
  variant without them, discarded, so a full pipe never blocks it; a caller
  whose pipes another reader owns uses WaitForChildExit instead. An owned
  child that finishes while members of its tree still run raises
  EChildProcessSurvivors naming them, before freeing it would end them. }
function FinishChild(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord = CHILD_COMPLETION_TIMEOUT_MILLISECONDS;
  const ADescription: string = ''): Integer; overload;
function FinishChild(AProcess: TProcess; var AStdout, AStderr: string;
  const ATimeoutMilliseconds: QWord = CHILD_COMPLETION_TIMEOUT_MILLISECONDS;
  const ADescription: string = ''): Integer; overload;

{ The executable and quoted parameters, for diagnostics. }
function QuotedChildCommandLine(AProcess: TProcess): string;
{ The last 8 KiB of captured output, noting how much was omitted. }
function CapturedOutputTail(const AText: string): string;

{ Cleanup: gives a started child ATimeoutMilliseconds to exit, then ends it
  through TerminateChildProcess, draining and discarding a poUsePipes
  child's output throughout. An owned child whose tree still has running
  members after it exited has them ended too. Never raises for a child that
  will not stop; True when it and its owned tree are gone. A nil or
  never-started AProcess is gone. }

{ Runs AExecutable with AArguments in ADirectory (the current directory when
  empty) and returns its exit code, its standard output and error merged
  into AOutput: the bounded replacement for RunCommand and RunCommandInDir,
  which wait without a deadline. A child past ATimeoutMilliseconds is ended
  and EChildProcessTimeout is raised; a child that cannot start raises
  EProcess. }
function RunChildCommand(const ADirectory, AExecutable: string;
  const AArguments: array of string; out AOutput: string;
  const ATimeoutMilliseconds: QWord = CHILD_COMPLETION_TIMEOUT_MILLISECONDS):
  Integer;

{ After a child started with ExecuteOwnedChild has exited: the members of
  its Job Object (Windows) or of its own process group (Linux) that still
  run, as 'pid 123, pid 456', or '' when none do. A survivor is evidence that
  the child returned while descendants it started still ran, which kill-on
  close and group termination would otherwise end without trace. Other
  children, and other platforms, report ''. }
function OwnedChildSurvivors(AProcess: TProcess): string;
function ReapChild(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord = CHILD_COMPLETION_TIMEOUT_MILLISECONDS):
  Boolean;

{ Executes AProcess and owns it with its descendants; see the unit header.
  AProcess must not have been executed and must not run suspended. }
procedure ExecuteOwnedChild(AProcess: TProcess;
  const AOwnProcessGroup: Boolean = False);

{$IFDEF LINUX}
{ Reads a process's state, parent, and process group from procfs. False
  when it no longer exists. }
function ReadProcessStat(const APid: LongInt; out AState: Char;
  out AParent, AGroup: LongInt): Boolean;
{ True while any member of AGroup still runs. Exited members that wait for
  an adopting parent that defers reaping (a subreaper) are zombies: SIGKILL
  cannot change them, so they do not count. Those that are this process's
  own children, other than AReapedElsewhere (which TProcess reaps), are
  reaped here. }
function ProcessGroupHasLiveMembers(const AGroup,
  AReapedElsewhere: LongInt): Boolean;
{$ENDIF}

implementation

uses
  {$IFDEF UNIX}
  BaseUnix
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows
  {$ENDIF};

{$IFDEF MSWINDOWS}
const
  JobObjectBasicAccountingInformationClass = 1;
  JobObjectBasicProcessIdListClass = 3;
  JobObjectExtendedLimitInformationClass = 9;
  JobObjectLimitKillOnJobClose = $00002000;
  { JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 112 bytes on Win32 and 144 on
    Win64; LimitFlags sits at offset 16 in both, so the limit is written
    into a zeroed buffer of the exact size rather than a mirrored record. }
  ExtendedLimitInformationBytes = 112 + 32 * (SizeOf(Pointer) div 8);
  ExtendedLimitFlagsOffset = 16;

{$PACKRECORDS C}
type
  TJobAccountingInformation = record
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

function CreateTestJobObject(const ASecurityAttributes: Pointer;
  const AName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';
function SetTestJobInformation(const AJob: THandle;
  const AInformationClass: DWORD; const AInformation: Pointer;
  const AInformationLength: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetInformationJobObject';
function AssignTestJobProcess(const AJob, AProcess: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';
function TerminateTestJob(const AJob: THandle;
  const AExitCode: UINT): BOOL; stdcall;
  external 'kernel32.dll' name 'TerminateJobObject';
function QueryTestJobInformation(const AJob: THandle;
  const AInformationClass: DWORD; const AInformation: Pointer;
  const AInformationLength: DWORD; const AReturnLength: PDWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'QueryInformationJobObject';
{$ENDIF}

{$IFDEF UNIX}
function SetChildProcessGroup(APid, AGroup: TPid): LongInt; cdecl;
  external 'c' name 'setpgid';
{$ENDIF}

{$IFDEF LINUX}
const
  PR_SET_PDEATHSIG = 1;

function prctl(AOption: LongInt; AArgument: PtrUInt): LongInt; cdecl;
  external 'c' name 'prctl';
{$ENDIF}

type
  { The process group or Job Object that owns a child and its descendants.
    It is a component of the child's TProcess, so it lives exactly as long
    as the TProcess does. }
  TChildProcessTree = class(TComponent)
  private
    FOwnProcessGroup: Boolean;
    {$IFDEF UNIX}
    FParentPID: TPid;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FJob: THandle;
    {$ENDIF}
    {$IFDEF UNIX}
    procedure ChildForked(ASender: TObject);
    {$ENDIF}
  public
    destructor Destroy; override;
  end;

function ProcessIsRunning(const APID: Integer): Boolean;
{$IFDEF UNIX}
begin
  Result := (APID > 0)
    and ((FpKill(APID, 0) = 0) or (FpGetErrNo = ESysEPERM));
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ExitCode: DWORD;
  Handle: THandle;
begin
  if APID <= 0 then Exit(False);
  Handle := Windows.OpenProcess(Windows.PROCESS_QUERY_INFORMATION,
    False, DWORD(APID));
  if Handle = 0 then Exit(False);
  try
    Result := Windows.GetExitCodeProcess(Handle, ExitCode)
      and (ExitCode = Windows.STILL_ACTIVE);
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ENDIF}

function DrainAvailableStream(AStream: TInputPipeStream;
  const AMaximumBytes: Integer): string;
const
  CHUNK = 4 * 1024;
var
  Available, N, ReadSize, Total: Integer;
  Buf: array[0..CHUNK - 1] of Byte;
begin
  Result := '';
  Available := AStream.NumBytesAvailable;
  if Available > AMaximumBytes then Available := AMaximumBytes;
  Total := 0;
  while Available > 0 do
  begin
    ReadSize := CHUNK;
    if Available < ReadSize then ReadSize := Available;
    N := AStream.Read(Buf[0], ReadSize);
    if N <= 0 then Break;
    SetLength(Result, Total + N);
    Move(Buf[0], Result[Total + 1], N);
    Inc(Total, N);
    Dec(Available, N);
  end;
end;

procedure DrainChildPipes(AProcess: TProcess; var AStdout, AStderr: string);
begin
  if not (poUsePipes in AProcess.Options) then Exit;
  if AProcess.Output.NumBytesAvailable > 0 then
    AStdout := AStdout + DrainAvailableStream(AProcess.Output);
  if (AProcess.Stderr <> nil) and (AProcess.Stderr <> AProcess.Output)
     and (AProcess.Stderr.NumBytesAvailable > 0) then
    AStderr := AStderr + DrainAvailableStream(AProcess.Stderr);
end;

function ChildTreeOf(AProcess: TProcess): TChildProcessTree;
var
  Index: Integer;
begin
  for Index := 0 to AProcess.ComponentCount - 1 do
    if AProcess.Components[Index] is TChildProcessTree then
      Exit(TChildProcessTree(AProcess.Components[Index]));
  Result := nil;
end;

{ What is left of ATimeoutMilliseconds since AStartedAt; zero once spent. }
function RemainingMilliseconds(const AStartedAt,
  ATimeoutMilliseconds: QWord): DWord;
var
  Elapsed: QWord;
begin
  Elapsed := GetTickCount64 - AStartedAt;
  if Elapsed >= ATimeoutMilliseconds then Exit(0);
  if ATimeoutMilliseconds - Elapsed > High(DWord) then Exit(High(DWord));
  Result := DWord(ATimeoutMilliseconds - Elapsed);
end;

{ Polls Running, draining when ADrain, until the child exits or the
  allowance passes, then (Windows) waits for the handle rundown within what
  remains of it. }
function PollChildExit(AProcess: TProcess; const ADrain: Boolean;
  var AStdout, AStderr: string; const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  { A child that was never started has nothing to wait for. }
  if AProcess.ProcessID <= 0 then Exit(True);
  StartedAt := GetTickCount64;
  while AProcess.Running
    and (GetTickCount64 - StartedAt < ATimeoutMilliseconds) do
  begin
    if ADrain then DrainChildPipes(AProcess, AStdout, AStderr);
    Sleep(ProcessPollMilliseconds);
  end;
  if ADrain then DrainChildPipes(AProcess, AStdout, AStderr);
  Result := not AProcess.Running;
  {$IFDEF MSWINDOWS}
  { The handle is signalled only after the exited child's rundown. }
  if Result then
    Result := AProcess.WaitOnExit(RemainingMilliseconds(StartedAt,
      ATimeoutMilliseconds));
  {$ENDIF}
end;

function WaitForChildExit(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord): Boolean;
var
  Unused: string;
begin
  Unused := '';
  Result := PollChildExit(AProcess, False, Unused, Unused,
    ATimeoutMilliseconds);
end;

function WaitForChildExit(AProcess: TProcess; var AStdout, AStderr: string;
  const ATimeoutMilliseconds: QWord): Boolean;
begin
  Result := PollChildExit(AProcess, True, AStdout, AStderr,
    ATimeoutMilliseconds);
end;

function ChildProcessExitCode(AProcess: TProcess): Integer;
begin
  Result := AProcess.ExitCode;
  if (Result = 0) and (AProcess.ExitStatus <> 0) then
    Result := AProcess.ExitStatus;
end;

{$IFDEF LINUX}
function ReadProcessStat(const APid: LongInt; out AState: Char;
  out AParent, AGroup: LongInt): Boolean;
var
  Stat: string;
  StatFile: TextFile;
  Fields: TStringList;
begin
  Result := False;
  AState := #0;
  AParent := 0;
  AGroup := 0;
  Stat := '';
  { procfs reports a zero size, so the file is read as text. }
  AssignFile(StatFile, '/proc/' + IntToStr(APid) + '/stat');
  {$I-}
  Reset(StatFile);
  {$I+}
  if IOResult <> 0 then Exit;
  {$I-}
  ReadLn(StatFile, Stat);
  {$I+}
  { A process that exits mid-read leaves an empty or failed read. }
  if IOResult <> 0 then Stat := '';
  CloseFile(StatFile);
  { pid (comm) state ppid pgrp ...: the fields follow the last ')'. }
  Fields := TStringList.Create;
  try
    Fields.Delimiter := ' ';
    Fields.StrictDelimiter := True;
    Fields.DelimitedText := Trim(Copy(Stat, LastDelimiter(')', Stat) + 1,
      MaxInt));
    if (Fields.Count < 3) or (Length(Fields[0]) <> 1) then Exit;
    AState := Fields[0][1];
    AParent := StrToIntDef(Fields[1], 0);
    AGroup := StrToIntDef(Fields[2], 0);
    Result := True;
  finally
    Fields.Free;
  end;
end;

function ProcessGroupHasLiveMembers(const AGroup,
  AReapedElsewhere: LongInt): Boolean;
var
  Search: TSearchRec;
  Pid, Parent, Group: LongInt;
  State: Char;
begin
  Result := False;
  if FindFirst('/proc/*', faDirectory, Search) <> 0 then Exit;
  try
    repeat
      Pid := StrToIntDef(Search.Name, 0);
      if (Pid <= 0)
        or not ReadProcessStat(Pid, State, Parent, Group)
        or (Group <> AGroup) then Continue;
      { State Z (or X while being removed) no longer runs. }
      if (State <> 'Z') and (State <> 'X') then Exit(True);
      if (Parent = FpGetpid) and (Pid <> AReapedElsewhere) then
        FpWaitpid(Pid, nil, WNOHANG);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;
{$ENDIF}

{$IFDEF UNIX}
{ Running reaps the direct child. On Linux the group is then finished when
  every remaining member is a zombie; elsewhere (macOS) orphans go to
  launchd, which reaps them promptly, so kill(-group, 0) fails with ESRCH
  soon after every descendant has exited. }
function ProcessGroupFinished(AProcess: TProcess): Boolean;
begin
  {$IFDEF LINUX}
  Result := not AProcess.Running
    and not ProcessGroupHasLiveMembers(AProcess.ProcessID,
      AProcess.ProcessID);
  {$ELSE}
  Result := not AProcess.Running and (FpKill(-AProcess.ProcessID, 0) <> 0);
  {$ENDIF}
end;

function WaitForProcessGroup(AProcess: TProcess; var AStdout,
  AStderr: string; const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    DrainChildPipes(AProcess, AStdout, AStderr);
    Result := ProcessGroupFinished(AProcess);
    if Result or (GetTickCount64 - StartedAt >= ATimeoutMilliseconds) then
      Exit;
    Sleep(ProcessPollMilliseconds);
  until False;
end;

procedure TChildProcessTree.ChildForked(ASender: TObject);
begin
  { Runs in the forked child before exec, where only async-signal-safe
    calls belong. FPC forks, prepares the child, and only then calls this,
    so the parent may already have died and the death signal would never
    arrive: exit at once when the request fails or the child has been
    reparented. }
  SetChildProcessGroup(0, 0);
  {$IFDEF LINUX}
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) <> 0)
    or (FpGetppid <> FParentPID) then
    FpExit(127);
  {$ENDIF}
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function JobHasActiveProcesses(const AJob: THandle): Boolean;
var
  Accounting: TJobAccountingInformation;
begin
  FillChar(Accounting, SizeOf(Accounting), 0);
  { An unreadable job counts as still occupied: the caller then reports
    the child as not terminated instead of trusting an unproven result. }
  if not QueryTestJobInformation(AJob,
    JobObjectBasicAccountingInformationClass, @Accounting,
    SizeOf(Accounting), nil) then Exit(True);
  Result := Accounting.ActiveProcesses > 0;
end;

function WaitForEmptyJob(AProcess: TProcess; const AJob: THandle;
  var AStdout, AStderr: string; const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    DrainChildPipes(AProcess, AStdout, AStderr);
    Result := not JobHasActiveProcesses(AJob) and not AProcess.Running;
    if Result or (GetTickCount64 - StartedAt >= ATimeoutMilliseconds) then
      Break;
    Sleep(ProcessPollMilliseconds);
  until False;
  if Result then
    Result := AProcess.WaitOnExit(RemainingMilliseconds(StartedAt,
      ATimeoutMilliseconds));
end;
{$ENDIF}

destructor TChildProcessTree.Destroy;
begin
  {$IFDEF MSWINDOWS}
  { Kill-on-close: a member that survives its TProcess ends here. }
  if FJob <> 0 then Windows.CloseHandle(FJob);
  FJob := 0;
  {$ENDIF}
  inherited Destroy;
end;

procedure ExecuteOwnedChild(AProcess: TProcess;
  const AOwnProcessGroup: Boolean);
var
  Tree: TChildProcessTree;
  {$IFDEF MSWINDOWS}
  Limits: array[0..ExtendedLimitInformationBytes - 1] of Byte;
  ErrorCode: DWORD;
  {$ENDIF}
begin
  if poRunSuspended in AProcess.Options then
    raise EArgumentException.Create(
      'an owned child must not be configured to run suspended');
  Tree := TChildProcessTree.Create(AProcess);
  Tree.FOwnProcessGroup := AOwnProcessGroup;
  {$IFDEF UNIX}
  if AOwnProcessGroup then
  begin
    Tree.FParentPID := FpGetpid;
    AProcess.OnForkEvent := Tree.ChildForked;
  end;
  AProcess.Execute;
  { Both sides set the group, so it exists before either proceeds; failure
    after the child's exec is harmless. }
  if AOwnProcessGroup then
    SetChildProcessGroup(AProcess.ProcessID, AProcess.ProcessID);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Tree.FJob := CreateTestJobObject(nil, nil);
  if Tree.FJob = 0 then RaiseLastOSError;
  FillChar(Limits, SizeOf(Limits), 0);
  PDWORD(@Limits[ExtendedLimitFlagsOffset])^ := JobObjectLimitKillOnJobClose;
  if not SetTestJobInformation(Tree.FJob,
    JobObjectExtendedLimitInformationClass, @Limits[0],
    SizeOf(Limits)) then RaiseLastOSError;
  { Assigned before its first instruction, so no descendant escapes. }
  AProcess.Options := AProcess.Options + [poRunSuspended];
  try
    AProcess.Execute;
  finally
    AProcess.Options := AProcess.Options - [poRunSuspended];
  end;
  if not AssignTestJobProcess(Tree.FJob, AProcess.ProcessHandle) then
  begin
    ErrorCode := Windows.GetLastError;
    Windows.TerminateProcess(AProcess.ProcessHandle, 1);
    AProcess.WaitOnExit(CHILD_KILL_MILLISECONDS);
    raise EOSError.CreateFmt('could not assign a test child to its Job '
      + 'Object: %s', [SysErrorMessage(ErrorCode)]);
  end;
  if Windows.ResumeThread(AProcess.ThreadHandle) = DWORD(-1) then
  begin
    ErrorCode := Windows.GetLastError;
    TerminateTestJob(Tree.FJob, 1);
    raise EOSError.CreateFmt('could not resume a test child: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  {$ENDIF}
end;

procedure SignalChild(AProcess: TProcess; const ATree: TChildProcessTree;
  const AForce: Boolean);
begin
  {$IFDEF UNIX}
  if Assigned(ATree) and ATree.FOwnProcessGroup then
  begin
    if AForce then FpKill(-AProcess.ProcessID, SIGKILL)
    else FpKill(-AProcess.ProcessID, SIGTERM);
  end
  { A reaped child's PID may already name another process. }
  else if not AProcess.Running then Exit
  else if AForce then FpKill(AProcess.ProcessID, SIGKILL)
  else FpKill(AProcess.ProcessID, SIGTERM);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if Assigned(ATree) and (ATree.FJob <> 0) then
    TerminateTestJob(ATree.FJob, 1)
  else
    Windows.TerminateProcess(AProcess.ProcessHandle, 1);
  {$ENDIF}
end;

{ True when the child and, for an owned tree, every member have gone. }
function WaitForTermination(AProcess: TProcess; const ATree: TChildProcessTree;
  var AStdout, AStderr: string; const ATimeoutMilliseconds: QWord): Boolean;
begin
  {$IFDEF UNIX}
  if Assigned(ATree) and ATree.FOwnProcessGroup then
    Exit(WaitForProcessGroup(AProcess, AStdout, AStderr,
      ATimeoutMilliseconds));
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if Assigned(ATree) and (ATree.FJob <> 0) then
    Exit(WaitForEmptyJob(AProcess, ATree.FJob, AStdout, AStderr,
      ATimeoutMilliseconds));
  {$ENDIF}
  Result := PollChildExit(AProcess, True, AStdout, AStderr,
    ATimeoutMilliseconds);
end;

function TerminateChildProcess(AProcess: TProcess; var AStdout,
  AStderr: string; const AGraceMilliseconds,
  AKillMilliseconds: QWord): Boolean;
var
  Tree: TChildProcessTree;
begin
  if AProcess.ProcessID <= 0 then Exit(True);
  Tree := ChildTreeOf(AProcess);
  if WaitForTermination(AProcess, Tree, AStdout, AStderr, 0) then Exit(True);
  SignalChild(AProcess, Tree, False);
  Result := WaitForTermination(AProcess, Tree, AStdout, AStderr,
    AGraceMilliseconds);
  if Result then Exit;
  SignalChild(AProcess, Tree, True);
  Result := WaitForTermination(AProcess, Tree, AStdout, AStderr,
    AKillMilliseconds);
end;

procedure KillChildProcess(AProcess: TProcess);
begin
  if AProcess.ProcessID > 0 then
    SignalChild(AProcess, ChildTreeOf(AProcess), True);
end;

function TerminateChildProcess(AProcess: TProcess; const AGraceMilliseconds,
  AKillMilliseconds: QWord): Boolean;
var
  Unused: string;
begin
  Unused := '';
  Result := TerminateChildProcess(AProcess, Unused, Unused,
    AGraceMilliseconds, AKillMilliseconds);
end;

function QuotedChildCommandLine(AProcess: TProcess): string;
var
  Index: Integer;
begin
  Result := AProcess.Executable;
  for Index := 0 to AProcess.Parameters.Count - 1 do
    Result := Result + ' ' + AnsiQuotedStr(AProcess.Parameters[Index], '''');
end;

function CapturedOutputTail(const AText: string): string;
const
  TAIL_BYTES = 8192;
begin
  if Length(AText) <= TAIL_BYTES then Exit(AText);
  Result := '[' + IntToStr(Length(AText) - TAIL_BYTES)
    + ' earlier bytes omitted]'
    + Copy(AText, Length(AText) - TAIL_BYTES + 1, TAIL_BYTES);
end;

procedure RaiseChildTimeout(AProcess: TProcess; var AStdout,
  AStderr: string; const ATimeoutMilliseconds: QWord;
  const ADescription: string);
var
  Description: string;
  Terminated: Boolean;
begin
  Terminated := TerminateChildProcess(AProcess, AStdout, AStderr);
  Description := ADescription;
  if Description = '' then Description := 'child process';
  raise EChildProcessTimeout.Create(Description + ' exceeded its '
    + UIntToStr(ATimeoutMilliseconds) + ' ms deadline and was '
    + BoolToStr(Terminated, 'terminated', 'NOT terminated (still running '
      + 'after SIGKILL)') + ': ' + QuotedChildCommandLine(AProcess)
    + LineEnding + '--- captured stdout ---' + LineEnding
    + CapturedOutputTail(AStdout) + LineEnding + '--- captured stderr ---'
    + LineEnding + CapturedOutputTail(AStderr) + LineEnding
    + '--- end captured output ---');
end;

function FinishChild(AProcess: TProcess; var AStdout, AStderr: string;
  const ATimeoutMilliseconds: QWord; const ADescription: string): Integer;
var
  Description, Survivors: string;
begin
  if not WaitForChildExit(AProcess, AStdout, AStderr,
    ATimeoutMilliseconds) then
    RaiseChildTimeout(AProcess, AStdout, AStderr, ATimeoutMilliseconds,
      ADescription);
  Survivors := OwnedChildSurvivors(AProcess);
  if Survivors <> '' then
  begin
    Description := ADescription;
    if Description = '' then Description := 'child process';
    raise EChildProcessSurvivors.Create(Description + ' finished while '
      + 'processes it started still ran (' + Survivors + '): '
      + QuotedChildCommandLine(AProcess));
  end;
  Result := ChildProcessExitCode(AProcess);
end;

function FinishChild(AProcess: TProcess; const ATimeoutMilliseconds: QWord;
  const ADescription: string): Integer;
var
  Stdout, Stderr: string;
begin
  { Output is drained so a full pipe cannot block the child, and only
    reported, as a tail, when it times out. }
  Stdout := '';
  Stderr := '';
  Result := FinishChild(AProcess, Stdout, Stderr, ATimeoutMilliseconds,
    ADescription);
end;

function ReapChild(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord): Boolean;
var
  Discarded: string;
begin
  if (AProcess = nil) or (AProcess.ProcessID <= 0) then Exit(True);
  Discarded := '';
  Result := (WaitForChildExit(AProcess, Discarded, Discarded,
    ATimeoutMilliseconds) and (OwnedChildSurvivors(AProcess) = ''))
    or TerminateChildProcess(AProcess, Discarded, Discarded);
end;

function RunChildCommand(const ADirectory, AExecutable: string;
  const AArguments: array of string; out AOutput: string;
  const ATimeoutMilliseconds: QWord): Integer;
var
  Index: Integer;
  MergedIntoOutput: string;
  Process: TProcess;
begin
  AOutput := '';
  Process := TProcess.Create(nil);
  try
    Process.Executable := AExecutable;
    for Index := 0 to High(AArguments) do
      Process.Parameters.Add(AArguments[Index]);
    if ADirectory <> '' then Process.CurrentDirectory := ADirectory;
    Process.Options := [poUsePipes, poStderrToOutPut];
    Process.Execute;
    MergedIntoOutput := '';
    Result := FinishChild(Process, AOutput, MergedIntoOutput,
      ATimeoutMilliseconds, ExtractFileName(AExecutable));
  finally
    Process.Free;
  end;
end;

function OwnedChildSurvivors(AProcess: TProcess): string;
{$IFDEF MSWINDOWS}
const
  ListCapacity = 256;
var
  Tree: TChildProcessTree;
  { JOBOBJECT_BASIC_PROCESS_ID_LIST: two DWORD counts, then ULONG_PTR IDs
    at offset 8 on Win32 and Win64 alike. }
  List: array[0..1 + ListCapacity * (SizeOf(PtrUInt) div 4)] of DWord;
  Count, Index: Integer;
  Id: PtrUInt;
begin
  Result := '';
  Tree := ChildTreeOf(AProcess);
  if (Tree = nil) or (Tree.FJob = 0)
     or not JobHasActiveProcesses(Tree.FJob) then Exit;
  FillChar(List, SizeOf(List), 0);
  if not QueryTestJobInformation(Tree.FJob,
    JobObjectBasicProcessIdListClass, @List[0], SizeOf(List), nil)
     and (List[1] = 0) then
    Exit('job members that could not be listed');
  Count := List[1];
  for Index := 0 to Count - 1 do
  begin
    Move(PByte(@List[0])[8 + Index * SizeOf(PtrUInt)], Id, SizeOf(Id));
    if Result <> '' then Result := Result + ', ';
    Result := Result + 'pid ' + IntToStr(Id);
  end;
  if List[0] > DWord(Count) then
    Result := Result + ' and ' + IntToStr(List[0] - DWord(Count)) + ' more';
  if Result = '' then Result := 'job members that could not be listed';
end;
{$ELSE}
{$IFDEF LINUX}
var
  Tree: TChildProcessTree;
  Search: TSearchRec;
  Pid, Parent, Group: LongInt;
  State: Char;
begin
  Result := '';
  Tree := ChildTreeOf(AProcess);
  if (Tree = nil) or not Tree.FOwnProcessGroup then Exit;
  if FindFirst('/proc/*', faDirectory, Search) <> 0 then Exit;
  try
    repeat
      Pid := StrToIntDef(Search.Name, 0);
      if (Pid <= 0) or not ReadProcessStat(Pid, State, Parent, Group)
         or (Group <> AProcess.ProcessID)
         or (State = 'Z') or (State = 'X') then Continue;
      if Result <> '' then Result := Result + ', ';
      Result := Result + 'pid ' + IntToStr(Pid);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;
{$ELSE}
begin
  Result := '';
end;
{$ENDIF}
{$ENDIF}

function ProcessIsLive(const APID: Integer): Boolean;
{$IFDEF LINUX}
var
  State: Char;
  Parent, Group: LongInt;
begin
  Result := (APID > 0) and ReadProcessStat(APID, State, Parent, Group)
    and (State <> 'Z') and (State <> 'X');
end;
{$ELSE}
begin
  Result := ProcessIsRunning(APID);
end;
{$ENDIF}

end.
