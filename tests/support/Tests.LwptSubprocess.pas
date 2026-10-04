{ Tests.LwptSubprocess — spawn ./build/lwpt as a subprocess and capture
  exit code, stdout, stderr.

  Repository-owned E2E programs need this to test the binary as users invoke
  it: argv parsing through the real CLI
  layer, exit codes the shell sees, stdout/stderr the user sees, and
  on-disk side effects in a real CWD. Tests that `uses LWPT.Core`
  link the library and skip the binary surface entirely — which is
  what LWPT's unit and integration groups are for.

  Design choices:

    - Stdout and stderr are captured separately (not merged) so tests
      can assert on each independently. Ordinary completion summaries
      and most LWPT errors land on stderr; silent success alone reports
      its final summary on stdout.
    - The caller's environment is inherited by default; AExtraEnv
      adds or overrides individual variables for that subprocess
      only.
    - cwd defaults to the current directory; AInDir overrides for
      per-test scratch dirs (matches the integration-test pattern
      from InstallLocalDiamond.Test.pas).
    - The binary path is configurable via LwptBinaryPath but defaults
      to ./build/lwpt (resolved relative to the test's CWD, which
      lwpt test sets to the project root before launching each test).
    - Pipes are drained in bounded available-byte snapshots while the child
      runs. A child or descendant can retain a pipe writer after the direct
      process exits, so reading until EOF would make timeout and termination
      handling unreachable.
    - Every run has a deadline. A zero timeout selects
      LWPT_RUN_DEFAULT_TIMEOUT_MILLISECONDS; there is no unbounded run. A
      run past its deadline is ended through TerminateChildProcess and
      raises ELwptRunTimeout naming the command and its captured output.
    - Each child is started through ExecuteOwnedChild
      (Tests.ProcessSupport): on Windows it runs in a kill-on-close Job
      Object of its own, so a timeout ends nested build and test children
      too; on Unix it stays in this program's process group and forwards
      SIGTERM to the groups it owns (ADR-0025). The job is emergency
      cleanup, never evidence: a child that returns while a member of its
      job still runs raises ELwptRunSurvivors naming those processes, so a
      cancellation test cannot pass on this helper's cleanup instead of
      LWPT's.

  Surface — kept minimal:

    function RunLwpt(const AArgs; AInDir; AExtraEnv): TLwptResult;
    function LwptBinaryPath: string;
    function LwptTestingBinaryPath: string;
    function ExpectedExe(const APath: string): string;
    procedure SetLwptBinaryPath(const APath: string);
}

unit Tests.LwptSubprocess;

{$mode delphi}{$H+}

interface

uses
  Classes,
  Process,
  SysUtils,

  Tests.ProcessSupport;

const
  { The deadline of a RunLwpt call that names none. The slowest ordinary
    call measured across the full Linux suite is recorded in
    docs/testing.md; this leaves room for slower Windows and macOS runners
    and stays well inside a CI job's bound. Calls that legitimately need
    longer pass their own timeout. }
  LWPT_RUN_DEFAULT_TIMEOUT_MILLISECONDS = CHILD_COMPLETION_TIMEOUT_MILLISECONDS;

type
  { A RunLwpt child outlived its deadline and was terminated. }
  ELwptRunTimeout = class(Exception);
  { A RunLwpt child returned while descendants it started still ran. }
  ELwptRunSurvivors = class(Exception);

  TLwptResult = record
    ExitCode: Integer;
    ProcessExitCode: Integer;
    ProcessExitStatus: Integer;
    Stdout:   string;
    Stderr:   string;
    TimedOut: Boolean;
  end;

{ Spawn the lwpt binary with the given arguments. Stdout + stderr are
  captured separately. AInDir defaults to '' which means "inherit the
  caller's CWD". AExtraEnv is an array of "KEY=value" strings; each is
  added to the inherited environment, replacing any existing value
  with the same key. ATimeoutMilliseconds bounds the run; zero (and the
  overloads without it) selects LWPT_RUN_DEFAULT_TIMEOUT_MILLISECONDS. A
  run past its deadline raises ELwptRunTimeout after its child has been
  terminated, and a child that returns while processes it started still
  run raises ELwptRunSurvivors, so a caller in a thread must catch both. }
function RunLwpt(const AArgs: array of string;
  const AInDir: string = ''): TLwptResult; overload;
function RunLwpt(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string): TLwptResult; overload;
function RunLwpt(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string;
  const ATimeoutMilliseconds: QWord): TLwptResult; overload;

{ RunLwpt against the test-flavoured binary (LwptTestingBinaryPath) for this
  one call; the configured binary is restored afterwards. Use it only for
  runs that set an LWPT_TEST_* variable, so every other case keeps
  exercising the binary users run. }
function RunLwptTesting(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string): TLwptResult; overload;
function RunLwptTesting(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string;
  const ATimeoutMilliseconds: QWord): TLwptResult; overload;

{ Path to the lwpt binary. Defaults to './build/lwpt' resolved at the
  point of the call. Override via SetLwptBinaryPath when running
  from a non-standard layout (e.g. a side-by-side comparison). }
function LwptBinaryPath: string;
{ Path to the test-flavoured binary (ADR-0044), built by the root manifest's
  `lwpt-testing` [build] entry with INSTALL_TESTING and refreshed by its
  [pretest] hook. Only that binary honours the LWPT_TEST_* fetch-redirection
  and fault-injection variables; ./build/lwpt, like a release binary,
  ignores them. Runs that set those variables go through RunLwptTesting. }
function LwptTestingBinaryPath: string;
function ExpectedExe(const APath: string): string;
procedure SetLwptBinaryPath(const APath: string);
procedure ConfigureProcessEnvironment(const AProcess: TProcess;
  const AOverrides: array of string);

{ When a nested LWPT run exits with an unexpected code, its captured
  output is the only evidence of why. Call this before the exit-code
  assertion: on mismatch it appends the captured stdout/stderr to
  ADiagnostics when supplied, allowing the caller to include it in an
  assertion failure. Existing callers without a diagnostic buffer retain
  the direct stderr fallback. No-op when the exit code matches. }
procedure DumpRunFailure(const ALabel: string; const ARun: TLwptResult;
  const AExpectedExit: Integer; const ADiagnostics: TStrings = nil);

{ LWPT's repository policy makes live network access opt-in. Tests that
  touch the live internet should consult this and self-skip unless their
  userland route explicitly enables network access. }
function SkipNetworkTests: Boolean;

{ Did a non-zero `lwpt` result fail purely because the network / host
  was unreachable — as opposed to LWPT producing wrong output? E2E
  tests call this after their install run and SKIP (rather than FAIL)
  when it returns True: a TCP connect failure or DNS resolution
  failure to a third-party host (bitbucket.org, github.com, gitlab.com)
  is transient infrastructure flakiness, not an LWPT defect.

  Detection is deliberately NARROW — only HTTPClient's two clean
  pre-transfer failures:
    - "Failed to connect to <host>:<port>"   (TCP connect failed)
    - "Failed to resolve host: <host>"        (DNS lookup failed)
  Both fire before any byte is fetched or parsed. Errors that indicate
  a real LWPT bug — "truncated chunked body", "no header terminator",
  a hash mismatch, a missing extracted file — are intentionally NOT
  matched, so the e2e assertions still fail HARD on those. The split
  is the whole point: third-party downtime skips; LWPT regressions
  fail. }
function IsNetworkUnavailable(const AResult: TLwptResult): Boolean;

implementation

uses
  Pipes;

{$IFDEF MSWINDOWS}
{ Declared here rather than through the Windows unit, which would shadow
  SysUtils routines this unit uses. }
function PeekWindowsPipe(APipe: THandle; ABuffer: Pointer;
  ABufferSize: LongWord; ABytesRead, ATotalBytesAvailable,
  ABytesLeftThisMessage: PLongWord): LongBool; stdcall;
  external 'kernel32.dll' name 'PeekNamedPipe';

const
  { Bound on the normal-completion EOF barrier for inherited pipe writers. }
  EXITED_DRAIN_MILLISECONDS = 10000;
{$ENDIF}

var
  GLwptBinaryPath: string = '';
  { The test program's starting directory, which lwpt test sets to the
    project root; programs may change directory afterwards. }
  GStartDirectory: string = '';
  GForwardWorkerLease: Boolean = True;

function LwptBinaryPath: string;
begin
  if GLwptBinaryPath <> '' then Exit(GLwptBinaryPath);
  Result := ExpandFileName('build/lwpt');
end;

function LwptTestingBinaryPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GStartDirectory) + 'build'
    + PathDelim + 'lwpt-testing';
  if not FileExists(ExpectedExe(Result)) then
    raise Exception.Create(ExpectedExe(Result) + ' is missing; run '
      + '`./build/lwpt build lwpt-testing` (the [pretest] hook does this '
      + 'before every `lwpt test`)');
end;

function RunLwptTesting(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string): TLwptResult;
begin
  Result := RunLwptTesting(AArgs, AInDir, AExtraEnv,
    LWPT_RUN_DEFAULT_TIMEOUT_MILLISECONDS);
end;

function RunLwptTesting(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string;
  const ATimeoutMilliseconds: QWord): TLwptResult;
var
  SavedBinaryPath: string;
begin
  SavedBinaryPath := GLwptBinaryPath;
  GLwptBinaryPath := LwptTestingBinaryPath;
  try
    Result := RunLwpt(AArgs, AInDir, AExtraEnv, ATimeoutMilliseconds);
  finally
    GLwptBinaryPath := SavedBinaryPath;
  end;
end;

function ExpectedExe(const APath: string): string;
begin
  Result := APath;
  {$IFDEF MSWINDOWS}
  if ExtractFileExt(Result) = '' then Result := Result + '.exe';
  {$ENDIF}
end;

function ArgumentsContain(const AArgs: array of string;
  const AValue: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AArgs) do
    if SameText(AArgs[i], AValue) then Exit(True);
  Result := False;
end;

procedure SetLwptBinaryPath(const APath: string);
begin
  GLwptBinaryPath := APath;
end;

function SkipNetworkTests: Boolean;
begin
  Result := GetEnvironmentVariable('LWPT_ENABLE_NETWORK') <> '1';
end;

function IsNetworkUnavailable(const AResult: TLwptResult): Boolean;
var
  Err: string;
begin
  if AResult.ExitCode = 0 then Exit(False);
  Err := LowerCase(AResult.Stderr);
  Result := (Pos('failed to connect to', Err) > 0)
         or (Pos('failed to resolve host', Err) > 0);
end;

{$IFDEF MSWINDOWS}
{ Windows does not permit a process working directory to be removed. Existing
  integration fixtures therefore rely on a normal child completion retaining
  the final EOF barrier until inherited pipe writers have exited. Keep that
  established Windows cleanup behavior without using it in the running or
  timeout paths, where an EOF read would make polling and termination
  unreachable. The barrier is bounded: it polls for data or the writer's
  close and gives up at ADeadline, so a descendant that keeps the pipe open
  cannot hang the caller. Darwin and other Unix hosts must never use this
  helper: an orphaned writer is the scheduling hang fixed by
  DrainAvailableStream. }
function DrainExitedStream(AStream: TInputPipeStream;
  const ADeadline: QWord): string;
const
  CHUNK = 4 * 1024;
var
  Buf: array[0..CHUNK - 1] of Byte;
  Available: LongWord;
  N, ReadSize, Total: Integer;
begin
  Result := '';
  Total := 0;
  { The deadline holds on every iteration, including ones that read: a
    surviving descendant that keeps writing cannot extend the barrier. }
  while GetTickCount64 < ADeadline do
  begin
    Available := 0;
    { Fails with a broken pipe once every writer has closed: EOF. }
    if not PeekWindowsPipe(AStream.Handle, nil, 0, nil, @Available, nil) then
      Break;
    if Available = 0 then
    begin
      Sleep(10);
      Continue;
    end;
    ReadSize := CHUNK;
    if Available < LongWord(ReadSize) then ReadSize := Available;
    N := AStream.Read(Buf[0], ReadSize);
    if N <= 0 then Break;
    SetLength(Result, Total + N);
    Move(Buf[0], Result[Total + 1], N);
    Inc(Total, N);
  end;
end;
{$ENDIF}

{ Name part of a NAME=value environment entry. Windows env blocks can
  contain entries starting with '=' (drive-letter cwd entries); those
  yield an empty name and never match an override. }
function EnvironmentEntryName(const AEntry: string): string;
var EqPos: Integer;
begin
  EqPos := Pos('=', AEntry);
  if EqPos = 0 then
    Result := AEntry
  else
    Result := Copy(AEntry, 1, EqPos - 1);
end;

function EnvironmentNamesEqual(const ALeft, ARight: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ALeft, ARight);
  {$ELSE}
  Result := ALeft = ARight;
  {$ENDIF}
end;

function EnvironmentEntryIsOverridden(const AEntry: string;
  const AOverrides: array of string): Boolean;
var
  EnvironmentIndex: Integer;
begin
  for EnvironmentIndex := 0 to High(AOverrides) do
    if EnvironmentNamesEqual(EnvironmentEntryName(AEntry),
      EnvironmentEntryName(AOverrides[EnvironmentIndex])) then
      Exit(True);
  Result := False;
end;

procedure ConfigureProcessEnvironment(const AProcess: TProcess;
  const AOverrides: array of string);
var
  EnvironmentIndex: Integer;
begin
  for EnvironmentIndex := 1 to GetEnvironmentVariableCount do
    if not EnvironmentEntryIsOverridden(
      GetEnvironmentString(EnvironmentIndex), AOverrides) then
      AProcess.Environment.Add(GetEnvironmentString(EnvironmentIndex));
  for EnvironmentIndex := 0 to High(AOverrides) do
    AProcess.Environment.Add(AOverrides[EnvironmentIndex]);
end;

{ Discover the one-shot worker token by its protocol suffix so this shared
  subprocess helper stays link-safe for E2E programs. The owning LWPT binary
  remains the only source of the project-prefixed environment name. }
function FindWorkerLeaseTokenEnvironment: string;
const
  TOKEN_SUFFIX = '_WORKER_LEASE_TOKEN';
var
  i: Integer;
  Name: string;
begin
  Result := '';
  for i := 1 to GetEnvironmentVariableCount do
  begin
    Name := EnvironmentEntryName(GetEnvironmentString(i));
    if (Length(Name) >= Length(TOKEN_SUFFIX))
       and EnvironmentNamesEqual(Copy(Name,
         Length(Name) - Length(TOKEN_SUFFIX) + 1,
         Length(TOKEN_SUFFIX)), TOKEN_SUFFIX)
       and (GetEnvironmentVariable(Name) <> '') then
      Exit(Name);
  end;
end;

function RunLwpt(const AArgs: array of string;
  const AInDir: string): TLwptResult;
var Empty: array of string;
begin
  SetLength(Empty, 0);
  Result := RunLwpt(AArgs, AInDir, Empty);
end;

function RunLwpt(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string): TLwptResult;
begin
  Result := RunLwpt(AArgs, AInDir, AExtraEnv,
    LWPT_RUN_DEFAULT_TIMEOUT_MILLISECONDS);
end;

function RunLwpt(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string;
  const ATimeoutMilliseconds: QWord): TLwptResult;
var
  P: TProcess;
  i: Integer;
  SavedDir: string;
  WorkerLeaseTokenEnvironment: string;
  ForwardedWorkerLease, Terminated: Boolean;
  Survivors: string;
  StartedAt, Deadline: QWord;
  {$IFDEF MSWINDOWS}
  ExitedDrainDeadline: QWord;
  {$ENDIF}
begin
  Deadline := ATimeoutMilliseconds;
  if Deadline = 0 then Deadline := LWPT_RUN_DEFAULT_TIMEOUT_MILLISECONDS;
  Result.ExitCode := -1;
  Result.ProcessExitCode := -1;
  Result.ProcessExitStatus := -1;
  Result.Stdout   := '';
  Result.Stderr   := '';
  Result.TimedOut := False;

  P := TProcess.Create(nil);
  try
    P.Executable := LwptBinaryPath;
    for i := 0 to High(AArgs) do P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes];
    if AInDir <> '' then P.CurrentDirectory := AInDir;

    { Always materialise the child environment so a consumed one-shot worker
      token can be omitted from later LWPT children without mutating this test
      process's own environment. Extras replace matching parent entries. }
    WorkerLeaseTokenEnvironment := FindWorkerLeaseTokenEnvironment;
    ForwardedWorkerLease := GForwardWorkerLease
      and (WorkerLeaseTokenEnvironment <> '')
      and not EnvironmentEntryIsOverridden(
        WorkerLeaseTokenEnvironment + '=', AExtraEnv);
    for i := 1 to GetEnvironmentVariableCount do
      if not EnvironmentEntryIsOverridden(GetEnvironmentString(i), AExtraEnv)
         and (GForwardWorkerLease
           or (WorkerLeaseTokenEnvironment = '')
           or not EnvironmentNamesEqual(
             EnvironmentEntryName(GetEnvironmentString(i)),
             WorkerLeaseTokenEnvironment)) then
        P.Environment.Add(GetEnvironmentString(i));
    for i := 0 to High(AExtraEnv) do
      P.Environment.Add(AExtraEnv[i]);

    { Run + drain. We do NOT use poWaitOnExit with poUsePipes; on
      Linux+macOS that pair can deadlock when the child blocks
      writing past the pipe buffer because the parent isn't reading.
      Instead: Execute, then drain both streams while the child runs,
      polling its exit until the deadline. }
    SavedDir := GetCurrentDir;
    try
      ExecuteOwnedChild(P);
      StartedAt := GetTickCount64;
      Result.TimedOut := not WaitForChildExit(P, Result.Stdout,
        Result.Stderr, Deadline);
      if Result.TimedOut then
      begin
        Terminated := TerminateChildProcess(P, Result.Stdout, Result.Stderr);
        raise ELwptRunTimeout.Create('lwpt subprocess exceeded its '
          + UIntToStr(Deadline) + ' ms deadline after '
          + UIntToStr(GetTickCount64 - StartedAt) + ' ms and was '
          + BoolToStr(Terminated, 'terminated', 'NOT terminated (still running '
          + 'after SIGKILL)') + ': ' + QuotedChildCommandLine(P) + ' (in '
          + AInDir + ')' + LineEnding + '--- captured stdout ---' + LineEnding
          + CapturedOutputTail(Result.Stdout) + LineEnding
          + '--- captured stderr ---' + LineEnding
          + CapturedOutputTail(Result.Stderr) + LineEnding
          + '--- end captured output ---');
      end;
      { Checked at once: anything the child started has had to end before
        it returned. }
      Survivors := OwnedChildSurvivors(P);
      { Final drain after exit. Normal Windows completion keeps its
        historical EOF barrier, bounded, because live descendants can lock
        fixture working directories; Unix completion stays nonblocking
        because an orphaned writer is the Darwin scheduling failure this
        helper fixes. }
      {$IFDEF MSWINDOWS}
      ExitedDrainDeadline := GetTickCount64 + EXITED_DRAIN_MILLISECONDS;
      Result.Stdout := Result.Stdout + DrainExitedStream(P.Output,
        ExitedDrainDeadline);
      Result.Stderr := Result.Stderr + DrainExitedStream(P.Stderr,
        ExitedDrainDeadline);
      {$ELSE}
      DrainChildPipes(P, Result.Stdout, Result.Stderr);
      {$ENDIF}
      { Mirrors LWPT.Command.Common.NormalisedExitCode (this unit must
        not link LWPT units): on Unix, ExitCode decodes correctly only
        when the Running poll reaped the raw waitpid(2) status; if
        WaitOnExit reaps instead it stores the already-decoded code and
        ExitCode collapses most failures to 0. ExitStatus is nonzero on
        genuine failure either way, so trust it when ExitCode claims
        success. }
      if Survivors <> '' then
        raise ELwptRunSurvivors.Create('lwpt subprocess returned while '
          + 'processes it started still ran (' + Survivors + '): '
          + QuotedChildCommandLine(P) + ' (in ' + AInDir + ')' + LineEnding
          + '--- captured stdout ---' + LineEnding
          + CapturedOutputTail(Result.Stdout) + LineEnding
          + '--- captured stderr ---' + LineEnding
          + CapturedOutputTail(Result.Stderr) + LineEnding
          + '--- end captured output ---');
      Result.ProcessExitCode := P.ExitCode;
      Result.ProcessExitStatus := P.ExitStatus;
      Result.ExitCode := Result.ProcessExitCode;
      if (Result.ExitCode = 0) and (Result.ProcessExitStatus <> 0) then
        Result.ExitCode := Result.ProcessExitStatus;
      { A test process may invoke LWPT more than once. Once a nested build or
        test scheduler starts, it has consumed the one-shot worker delegation;
        stop forwarding that stale token so the next command can join the
        worker queue normally. Validation failures before scheduler creation
        deliberately leave the still-live delegation available. }
      if ForwardedWorkerLease
         and (((Length(AArgs) > 0) and SameText(AArgs[0], 'build')
           and ((Pos('START ', Result.Stdout) > 0)
             or ((Result.ExitCode = 0)
               and not ArgumentsContain(AArgs, '--help'))))
         or ((Length(AArgs) > 0) and SameText(AArgs[0], 'test')
           and (Pos('discovered ', Result.Stdout) > 0))) then
        GForwardWorkerLease := False;
    finally
      SetCurrentDir(SavedDir);
    end;
  finally
    P.Free;
  end;
end;

procedure WriteRunDiagnostic(const ALine: string;
  const ADiagnostics: TStrings);
begin
  if Assigned(ADiagnostics) then ADiagnostics.Add(ALine)
  else WriteLn(ErrOutput, ALine);
end;

procedure DumpRunFailure(const ALabel: string; const ARun: TLwptResult;
  const AExpectedExit: Integer; const ADiagnostics: TStrings);
begin
  if ARun.ExitCode = AExpectedExit then Exit;
  WriteRunDiagnostic('RUN FAILURE [' + ALabel + '] exit='
    + IntToStr(ARun.ExitCode) + ' expected=' + IntToStr(AExpectedExit)
    + ' process-exit-code=' + IntToStr(ARun.ProcessExitCode)
    + ' process-exit-status=' + IntToStr(ARun.ProcessExitStatus),
    ADiagnostics);
  WriteRunDiagnostic('--- captured stdout ---', ADiagnostics);
  WriteRunDiagnostic(ARun.Stdout, ADiagnostics);
  WriteRunDiagnostic('--- captured stderr ---', ADiagnostics);
  WriteRunDiagnostic(ARun.Stderr, ADiagnostics);
  WriteRunDiagnostic('--- end captured output ---', ADiagnostics);
end;

initialization
  GStartDirectory := GetCurrentDir;

end.
