{ StampVersion.Test — pins that scripts/stamp-version.pas, LWPT's own
  [prebuild] hook, is safe when several self-builds run it at once
  (issue #361).

  The script is copied into a scratch tool project (minus its InstantFPC
  shebang line) and compiled once with `lwpt build`, so every platform's
  toolchain configuration applies. Concurrent writers start together:
  each runs behind a gate (this program, re-entered with GATE_ARGUMENT)
  that announces itself with an existence-only ready file and starts the
  script only once the existence-only release file appears. Neither file
  carries content, so neither is a payload handoff. Every child is awaited
  to real completion under a deadline. An overrun child is killed with a
  native signal (on Unix with its whole process group, which holds a
  gate's script), then awaited for a bounded grace period; if it is still
  running when the grace expires, the test fails rather than waiting on.
  Each gate gets one absolute deadline from its parent and starts killing
  its own script a fixed margin before it. In the normal observation loop
  the parent kills a gate only after that deadline plus the grace; when a
  test fails earlier (a barrier timeout, for instance), exceptional
  cleanup processes the children sequentially, using an immediate deadline
  for each unfinished child. These are ordered thresholds, not a
  guarantee of completion order: a gate that is badly delayed by the
  scheduler can still be killed before its own cleanup finishes.
  TProcess.Terminate and the untimed WaitOnExit are never used: in FPC
  3.2.2 the untimed WaitOnExit waits without a bound, and on Unix so does
  Terminate, which ends with one (on Windows Terminate calls
  TerminateProcess without waiting). Six assertions:

    1. Concurrent runs across changing versions all exit 0. This program
       reads the include continuously from before the release until every
       gate has exited or the observation deadline is reached; every read
       sees the complete previous or new text, never a truncated or partial
       file, and the final file holds exactly
       the new text, with SaveToFile's bytes (each line followed by
       LineEnding). Neither source/ nor .lwpt/tmp keeps a temporary file.
       That reads overlap a publication is not asserted, because the
       reader cannot see the scripts themselves, only their gates; the
       number of rounds whose reads saw the old text after the release and
       then the new text while a gate still ran is printed as a
       diagnostic. As evidence rather than a guaranteed property: on Linux
       a mutation that rewrites the file in place produced hundreds of
       torn reads per run, and the pre-#361 script failed outright with
       "Unable to create file" when its runs collided.
    2. Concurrent runs whose expected text is already present leave the
       file untouched: its modification time stays at a value set in the
       past.
    3. An end-to-end smoke: concurrent `lwpt build` runs of a project
       whose [prebuild] hook is the script all succeed, none reports
       changed inputs, and the built program reports the new version. It
       does not prove that the hooks overlapped.
    4. An unusable .lwpt/tmp (a regular file named .lwpt) fails with a
       message naming the staging path, leaves Version.inc unchanged, and
       leaves nothing behind.
    5. A target without a source/ directory fails after the temporary file
       is written and removes it.
    6. A destination that is a directory fails after the temporary file is
       written, and the temporary file is removed. }

program StampVersion.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,

  LWPT.Core,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  SCRIPT_PATH = 'scripts/stamp-version.pas';
  GATE_ARGUMENT = '--stamp-version-gate';
  INCLUDE_NAME = 'Version.inc';
  TEMP_PREFIX = 'stamp-version-';
  WRITER_COUNT = 6;
  ROUND_COUNT = 8;
  BUILD_COUNT = 3;
  BUILD_ROUND_COUNT = 3;
  { Deadlines are generous for slow Windows runners; none is unbounded. }
  TERMINATION_GRACE_MILLISECONDS = 10000;
  BARRIER_MILLISECONDS = 60000;
  CHILD_MILLISECONDS = 120000;
  { A gate's whole life, barrier included, is budgeted against one absolute
    deadline its parent passes as an argument. In FPC 3.2.2 GetTickCount64 reads
    CLOCK_MONOTONIC on Linux, the system-wide tick count on Windows, and
    gettimeofday on macOS, so parent and gate read the same clock; on macOS
    that clock is the wall clock and a clock adjustment during a run shifts
    the deadline. The gate starts killing its script this margin
    before the deadline, a budget of twice the configured kill-and-reap
    grace, and in the normal observation loop the parent kills a gate only
    after the deadline plus the grace (exceptional cleanup after an
    earlier failure processes the children sequentially, using an
    immediate deadline for each unfinished child). These are configured
    budgets, not guaranteed
    completion bounds. }
  GATE_LIFETIME_MILLISECONDS = BARRIER_MILLISECONDS + CHILD_MILLISECONDS;
  GATE_CLEANUP_MARGIN_MILLISECONDS = 2 * TERMINATION_GRACE_MILLISECONDS;
  BUILD_MILLISECONDS = 600000;
  POLL_MILLISECONDS = 1;
  { A past modification time that no run can reproduce by rewriting. }
  PAST_AGE_DAYS = 2;
  { How far an input's modification time is set past its hook output's.
    Hook staleness compares FileAge stamps strictly: whole seconds on Unix,
    2-second DOS time on Windows. Four seconds clears either bucket. }
  NEWER_INPUT_SECONDS = 4;
  {$IFDEF MSWINDOWS}
  { The one open failure a Windows reader may meet while a replacement
    holds the path: ERROR_SHARING_VIOLATION. }
  READ_SHARING_VIOLATION = 32;
  {$ENDIF}

type
  { A child process awaited to real completion under a deadline. }
  TChild = class
  private
    FProcess: TProcess;
    FOutput: string;
    FExitCode: Integer;
    FFinished: Boolean;
    FOwnGroup: Boolean;
    {$IFDEF UNIX}
    procedure ChildForked(ASender: TObject);
    function GroupAlive: Boolean;
    {$ENDIF}
    procedure Kill;
  public
    { AOwnGroup puts the child, and everything it starts, in a new Unix
      process group that Kill signals as a whole. }
    constructor Create(const AExecutable, ADirectory: string;
      const AArguments, AEnvironment: array of string;
      const AOwnGroup: Boolean);
    destructor Destroy; override;
    procedure Drain;
    function Running: Boolean;
    procedure Finish(const ADeadline: QWord);
    property ExitCode: Integer read FExitCode;
    property Output: string read FOutput;
  end;
  TChildren = array of TChild;

  TReadStats = record
    Observations: Integer;
    { The old text (AAllowed[0]) was read after the release. }
    SawOld: Boolean;
    { After that, the new text (AAllowed[1]) was read while a gate still
      ran. Diagnostic only: a gate can remain running after its script
      exits. }
    Straddled: Boolean;
    Torn: Integer;
    TornSample: string;
  end;

  TStampVersionTest = class(TTestSuite)
  private
    FOrigDir, FScratch, FTool, FTarget, FStampExe: string;
    FBarrier: Integer;
    procedure ResetTarget(const AWithSource: Boolean);
    procedure WriteTargetManifest(const AVersion: string;
      const AExtra: string = '');
    function IncludePath: string;
    function ExpectedText(const AVersion: string): string;
    function Observe(const AAllowed: array of string;
      var AStats: TReadStats): Integer;
    function RunWriters(const AAllowed: array of string;
      out AStats: TReadStats): TChildren;
    procedure ExpectSucceeded(const AChildren: TChildren);
    procedure FreeChildren(var AChildren: TChildren);
    function RunStamp(const ADirectory: string): TChild;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestConcurrentRunsPublishCompleteText;
    procedure TestCurrentTextIsLeftUntouched;
    procedure TestConcurrentBuildsSmoke;
    procedure TestUnusableStagingDirectoryFailsCleanly;
    procedure TestMissingSourceDirectoryFailsCleanly;
    procedure TestFailedReplacementRemovesTemporaryFile;
  end;

{$IFDEF UNIX}
{ setpgid(2); FPC 3.2.2's BaseUnix does not bind it. }
function CSetProcessGroup(const APID,
  AProcessGroupID: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setpgid';
  {$ELSE}
  external name 'setpgid';
  {$ENDIF}
{$ENDIF}

function VersionOverrideCleared: string;
begin
  { The release-tag override would change the expected text. }
  Result := PROJECT_NAME + '_VERSION_OVERRIDE=';
end;

constructor TChild.Create(const AExecutable, ADirectory: string;
  const AArguments, AEnvironment: array of string;
  const AOwnGroup: Boolean);
var
  Argument: string;
begin
  inherited Create;
  FExitCode := -1;
  FOwnGroup := AOwnGroup;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := AExecutable;
  FProcess.CurrentDirectory := ADirectory;
  FProcess.Options := [poUsePipes, poStderrToOutPut];
  for Argument in AArguments do FProcess.Parameters.Add(Argument);
  ConfigureProcessEnvironment(FProcess, AEnvironment);
  {$IFDEF UNIX}
  if FOwnGroup then FProcess.OnForkEvent := ChildForked;
  {$ENDIF}
  FProcess.Execute;
  {$IFDEF UNIX}
  { Both sides set the group, so it exists whichever runs first; the
    parent's call fails harmlessly once the child has exec'd. }
  if FOwnGroup then CSetProcessGroup(FProcess.ProcessID, FProcess.ProcessID);
  {$ENDIF}
end;

destructor TChild.Destroy;
begin
  if not FFinished then
    try
      Finish(GetTickCount64);
    except
      on Exception do;
    end;
  FProcess.Free;
  inherited Destroy;
end;

{$IFDEF UNIX}
procedure TChild.ChildForked(ASender: TObject);
begin
  { Runs in the forked child before exec. }
  CSetProcessGroup(0, 0);
end;

function TChild.GroupAlive: Boolean;
begin
  Result := (FpKill(-FProcess.ProcessID, 0) = 0)
    or (FpGetErrNo = ESysEPERM);
end;
{$ENDIF}

{ Signals without waiting; the caller then waits under its own budget. }
procedure TChild.Kill;
begin
  if FProcess.ProcessID <= 0 then Exit;
  {$IFDEF UNIX}
  if FOwnGroup and (FpKill(-FProcess.ProcessID, SIGKILL) = 0) then Exit;
  FpKill(FProcess.ProcessID, SIGKILL);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows.TerminateProcess(FProcess.ProcessHandle, 1);
  {$ENDIF}
end;

procedure TChild.Drain;
begin
  if FProcess.Output.NumBytesAvailable > 0 then
    FOutput := FOutput + DrainAvailableStream(FProcess.Output);
end;

function TChild.Running: Boolean;
begin
  Drain;
  { Nonblocking: waitpid(WNOHANG) on Unix, GetExitCodeProcess on Windows. }
  Result := FProcess.Running;
end;

{ Waits until the child has exited and, on Windows, until its process
  handle is signalled: GetExitCodeProcess reports the exit before the kernel
  runs down the child's handles, including its working directory. Past
  ADeadline the child (with its process group) is killed and awaited for a
  grace period; the overrun raises, and so does a child still running when
  the grace expires. }
procedure TChild.Finish(const ADeadline: QWord);
var
  TimedOut: Boolean;
  GraceEnd: QWord;
begin
  if FFinished then Exit;
  TimedOut := False;
  while Running do
  begin
    if GetTickCount64 >= ADeadline then
    begin
      TimedOut := True;
      Kill;
      Break;
    end;
    Sleep(POLL_MILLISECONDS);
  end;
  GraceEnd := GetTickCount64 + TERMINATION_GRACE_MILLISECONDS;
  while Running do
  begin
    if GetTickCount64 >= GraceEnd then
      raise Exception.CreateFmt('child %s did not exit after it was killed',
        [FProcess.Executable]);
    Sleep(POLL_MILLISECONDS);
  end;
  {$IFDEF UNIX}
  { Reaping orphaned descendants is the adopting process's responsibility;
    this helper only attempts to await the group's disappearance within
    the grace budget, so that none
    outlives the test's directories; if it is still alive when the budget
    expires, this raises. }
  if TimedOut and FOwnGroup then
    while GroupAlive do
    begin
      if GetTickCount64 >= GraceEnd then
        raise Exception.CreateFmt('process group of %s outlived its kill',
          [FProcess.Executable]);
      Sleep(POLL_MILLISECONDS);
    end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not FProcess.WaitOnExit(TERMINATION_GRACE_MILLISECONDS) then
    raise Exception.CreateFmt('child %s exited but its handle never '
      + 'signalled', [FProcess.Executable]);
  {$ENDIF}
  Drain;
  { Mirrors RunLwpt: trust ExitStatus when ExitCode claims success. }
  FExitCode := FProcess.ExitCode;
  if (FExitCode = 0) and (FProcess.ExitStatus <> 0) then
    FExitCode := FProcess.ExitStatus;
  FFinished := True;
  if TimedOut then
    raise Exception.CreateFmt('child %s overran its deadline; output: %s',
      [FProcess.Executable, FOutput]);
end;

{ Child mode: ParamStr(2) is the ready file, 3 the release file, 4 the
  script executable, 5 the absolute GetTickCount64 deadline. Termination of
  the script starts at the deadline minus the cleanup margin, followed by a
  wait budget of the termination grace that can end in failure.

  On Windows a killed gate cannot take its script with it. This ordering
  gives the gate the first opportunity to clean up its script, but a gate
  the scheduler delays badly can still be killed before it does, leaving
  the script running. Owning descendants through a Job object is out of
  scope here (#365). }
function RunGate: Integer;
var
  KillAt: QWord;
  Child: TChild;
begin
  try
    KillAt := StrToQWord(ParamStr(5)) - GATE_CLEANUP_MARGIN_MILLISECONDS;
    WriteTextFile(ParamStr(2), '');
    while not FileExists(ParamStr(3)) do
    begin
      if GetTickCount64 >= KillAt then
      begin
        WriteLn('gate: never released');
        Exit(3);
      end;
      Sleep(POLL_MILLISECONDS);
    end;
    { The script stays in the gate's process group. }
    Child := TChild.Create(ParamStr(4), GetCurrentDir, [], [], False);
    try
      Child.Finish(KillAt);
      Write(Child.Output);
      Result := Child.ExitCode;
    finally
      Child.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('gate: ', E.Message);
      Result := 4;
    end;
  end;
end;

{ Reads APath to its end in chunks. It never trusts a size taken before the
  read, because an in-place writer can change the file between the two. }
function TryReadWhole(const APath: string; out AText: string;
  out AError: Integer): Boolean;
var
  Handle: THandle;
  Chunk: array[0..4095] of Byte;
  Got, Have: Integer;
begin
  AText := '';
  AError := 0;
  Handle := FileOpen(APath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
  begin
    AError := GetLastOSError;
    Exit(False);
  end;
  try
    repeat
      Got := FileRead(Handle, Chunk, SizeOf(Chunk));
      if Got > 0 then
      begin
        Have := Length(AText);
        SetLength(AText, Have + Got);
        Move(Chunk, AText[Have + 1], Got);
      end;
    until Got <= 0;
    if Got < 0 then
    begin
      AError := GetLastOSError;
      Exit(False);
    end;
  finally
    FileClose(Handle);
  end;
  Result := True;
end;

{ Every name in ADirectory, sorted and comma-joined; '' when absent. }
function DirectoryEntries(const ADirectory: string): string;
var
  SR: TSearchRec;
  Names: TStringList;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    if SysUtils.FindFirst(ADirectory + '/*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then Names.Add(SR.Name);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
    Names.Delimiter := ',';
    Names.StrictDelimiter := True;
    Result := Names.DelimitedText;
  finally
    Names.Free;
  end;
end;

function TimeLeft(const ADeadline: QWord): Boolean;
begin
  Result := GetTickCount64 < ADeadline;
end;

procedure TStampVersionTest.BeforeAll;
var
  R: TLwptResult;
  Script: string;
begin
  FOrigDir := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('stamp-version');
  FTool := FScratch + '/tool';
  FTarget := FScratch + '/target';
  FBarrier := 0;
  ForceDirectories(FTool);
  { InstantFPC skips the shebang line; the compiler does not. }
  Script := ReadBinaryFile(SCRIPT_PATH);
  if Copy(Script, 1, 2) = '#!' then
    Script := Copy(Script, Pos(#10, Script), MaxInt);
  WriteTextFile(FTool + '/stamp-version.pas', Script);
  WriteTextFile(FTool + '/lwpt.toml',
    '[package]'#10 +
    'name = "stamp-tool"'#10 +
    'version = "0.0.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'stamp = { source = "stamp-version.pas", output = "build/stamp-version" }'#10);
  R := RunLwpt(['build'], FTool, [], BUILD_MILLISECONDS);
  DumpRunFailure('build stamp-version', R, 0);
  if R.TimedOut or (R.ExitCode <> 0) then
    raise Exception.Create('could not compile ' + SCRIPT_PATH);
  FStampExe := ExpandFileName(ExpectedExe(FTool + '/build/stamp-version'));
end;

procedure TStampVersionTest.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TStampVersionTest.ResetTarget(const AWithSource: Boolean);
begin
  RecursiveDelete(FTarget);
  ForceDirectories(FTarget);
  if AWithSource then ForceDirectories(FTarget + '/source');
end;

procedure TStampVersionTest.WriteTargetManifest(const AVersion: string;
  const AExtra: string);
begin
  WriteTextFile(FTarget + '/lwpt.toml',
    '[package]'#10 +
    'name = "stamp-target"'#10 +
    'version = "' + AVersion + '"'#10 +
    AExtra);
end;

function TStampVersionTest.IncludePath: string;
begin
  Result := FTarget + '/source/' + INCLUDE_NAME;
end;

function TStampVersionTest.ExpectedText(const AVersion: string): string;
begin
  { TStringList.SaveToFile's bytes, which the script must keep. }
  Result :=
    '{ Auto-generated by scripts/stamp-version.pas. Do not hand-edit. }'
    + LineEnding
    + '{ Source: [package].version in lwpt.toml. }' + LineEnding
    + LineEnding
    + '  PROGRAM_VERSION = ''' + AVersion + ''';' + LineEnding;
end;

{ Reads the include once and returns the index of the AAllowed text it
  held; -1 when a Windows sharing violation kept the read from happening,
  or when the read failed otherwise or held anything else (torn). }
function TStampVersionTest.Observe(const AAllowed: array of string;
  var AStats: TReadStats): Integer;
var
  Seen: string;
  Error, Allowed: Integer;
begin
  Result := -1;
  if not TryReadWhole(IncludePath, Seen, Error) then
  begin
    {$IFDEF MSWINDOWS}
    if Error = READ_SHARING_VIOLATION then Exit;
    {$ENDIF}
    Inc(AStats.Torn);
    if AStats.TornSample = '' then
      AStats.TornSample := Format('read failed with OS error %d', [Error]);
    Exit;
  end;
  Inc(AStats.Observations);
  for Allowed := 0 to High(AAllowed) do
    if Seen = AAllowed[Allowed] then Exit(Allowed);
  Inc(AStats.Torn);
  if AStats.TornSample = '' then
    AStats.TornSample := Format('%d bytes: %s', [Length(Seen), Seen]);
end;

{ Starts WRITER_COUNT gated runs, releases them together, and reads the
  include until all have exited or the observation deadline is reached.
  Finishes the writers before returning them; on failure, frees them and
  raises. }
function TStampVersionTest.RunWriters(const AAllowed: array of string;
  out AStats: TReadStats): TChildren;
var
  Index: Integer;
  Release, GatePrefix: string;
  Ready: array of string;
  AllReady, AnyRunning: Boolean;
  Seen: Integer;
  Deadline, GateDeadline: QWord;
begin
  AStats.Observations := 0;
  AStats.SawOld := False;
  AStats.Straddled := False;
  AStats.Torn := 0;
  AStats.TornSample := '';
  Inc(FBarrier);
  GatePrefix := FScratch + '/gate-' + IntToStr(FBarrier);
  Release := GatePrefix + '-release';
  SetLength(Ready, WRITER_COUNT);
  Result := nil;
  SetLength(Result, WRITER_COUNT);
  for Index := 0 to High(Result) do Result[Index] := nil;
  GateDeadline := GetTickCount64 + GATE_LIFETIME_MILLISECONDS;
  try
    for Index := 0 to High(Result) do
    begin
      Ready[Index] := GatePrefix + '-ready-' + IntToStr(Index);
      Result[Index] := TChild.Create(ExpandFileName(ParamStr(0)), FTarget,
        [GATE_ARGUMENT, Ready[Index], Release, FStampExe,
         IntToStr(GateDeadline)],
        [VersionOverrideCleared], True);
    end;

    Deadline := GetTickCount64 + BARRIER_MILLISECONDS;
    repeat
      AllReady := True;
      for Index := 0 to High(Result) do
      begin
        if not Result[Index].Running then
          raise Exception.Create('a gate exited before its release: '
            + Result[Index].Output);
        if not FileExists(Ready[Index]) then AllReady := False;
      end;
      if not AllReady then
      begin
        if not TimeLeft(Deadline) then
          raise Exception.Create('gates did not become ready in time');
        Sleep(POLL_MILLISECONDS);
      end;
    until AllReady;

    { The reader is running before any writer starts. }
    Observe(AAllowed, AStats);
    WriteTextFile(Release, '');
    { Only after the gates' own cleanup window has passed. }
    Deadline := GateDeadline + TERMINATION_GRACE_MILLISECONDS;
    repeat
      Seen := Observe(AAllowed, AStats);
      AnyRunning := False;
      for Index := 0 to High(Result) do
        if Result[Index].Running then AnyRunning := True;
      if Seen = 0 then AStats.SawOld := True
      else if (Seen = 1) and AStats.SawOld and AnyRunning then
        AStats.Straddled := True;
      {$IFDEF MSWINDOWS}
      { Let replacements land between reads. }
      Sleep(2);
      {$ENDIF}
      if AnyRunning and not TimeLeft(Deadline) then Break;
    until not AnyRunning;

    for Index := 0 to High(Result) do Result[Index].Finish(Deadline);
  except
    FreeChildren(Result);
    raise;
  end;
end;

procedure TStampVersionTest.ExpectSucceeded(const AChildren: TChildren);
var
  Index: Integer;
begin
  for Index := 0 to High(AChildren) do
  begin
    if AChildren[Index].ExitCode <> 0 then
      WriteLn(ErrOutput, 'child ', Index, ' exited ',
        AChildren[Index].ExitCode, ': ', AChildren[Index].Output);
    Expect<Integer>(AChildren[Index].ExitCode).ToBe(0);
  end;
end;

procedure TStampVersionTest.FreeChildren(var AChildren: TChildren);
var
  Index: Integer;
begin
  for Index := 0 to High(AChildren) do FreeAndNil(AChildren[Index]);
  SetLength(AChildren, 0);
end;

function TStampVersionTest.RunStamp(const ADirectory: string): TChild;
begin
  Result := TChild.Create(FStampExe, ADirectory, [],
    [VersionOverrideCleared], True);
  try
    Result.Finish(GetTickCount64 + CHILD_MILLISECONDS);
  except
    Result.Free;
    raise;
  end;
end;

procedure TStampVersionTest.TestConcurrentRunsPublishCompleteText;
var
  Round, Straddled, Torn: Integer;
  Previous, Current, FirstTornSample: string;
  Stats: TReadStats;
  Writers: TChildren;
begin
  ResetTarget(True);
  Previous := ExpectedText('1.0.0');
  WriteTextFile(IncludePath, Previous);
  Straddled := 0;
  Torn := 0;
  FirstTornSample := '';
  for Round := 1 to ROUND_COUNT do
  begin
    WriteTargetManifest('1.0.' + IntToStr(Round));
    Current := ExpectedText('1.0.' + IntToStr(Round));
    Writers := RunWriters([Previous, Current], Stats);
    try
      ExpectSucceeded(Writers);
    finally
      FreeChildren(Writers);
    end;
    if Stats.Straddled then Inc(Straddled);
    Inc(Torn, Stats.Torn);
    if FirstTornSample = '' then FirstTornSample := Stats.TornSample;
    Expect<string>(ReadBinaryFile(IncludePath)).ToBe(Current);
    Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
    Expect<string>(DirectoryEntries(FTarget + '/.lwpt/tmp')).ToBe('');
    Previous := Current;
  end;
  if Torn <> 0 then
    WriteLn(ErrOutput, 'torn reads: ', Torn, '; first: ', FirstTornSample);
  WriteLn('diagnostic: ', Straddled, ' of ', ROUND_COUNT, ' rounds read '
    + 'the old text after the release and then the new text while a gate '
    + 'still ran');
  Expect<Integer>(Torn).ToBe(0);
end;

procedure TStampVersionTest.TestCurrentTextIsLeftUntouched;
var
  Past: LongInt;
  Current: string;
  Stats: TReadStats;
  Writers: TChildren;
  Index: Integer;
begin
  ResetTarget(True);
  WriteTargetManifest('2.0.0');
  Current := ExpectedText('2.0.0');
  WriteTextFile(IncludePath, Current);
  Past := DateTimeToFileDate(Now - PAST_AGE_DAYS);
  Expect<Integer>(FileSetDate(IncludePath, Past)).ToBe(0);

  Writers := RunWriters([Current], Stats);
  try
    ExpectSucceeded(Writers);
    for Index := 0 to High(Writers) do
      Expect<Boolean>(Pos('already current', Writers[Index].Output) > 0)
        .ToBe(True);
  finally
    FreeChildren(Writers);
  end;
  Expect<Integer>(Stats.Torn).ToBe(0);
  Expect<LongInt>(FileAge(IncludePath)).ToBe(Past);
  Expect<string>(ReadBinaryFile(IncludePath)).ToBe(Current);
  Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
end;

{ An end-to-end smoke, not a proof that the hooks overlapped. }
procedure TStampVersionTest.TestConcurrentBuildsSmoke;
var
  Round, Index: Integer;
  Version, StampCommand, WorkerState: string;
  Builds: TChildren;
  App: TChild;
  Deadline: QWord;
begin
  ResetTarget(True);
  WorkerState := FScratch + '/workers';
  ForceDirectories(WorkerState);
  StampCommand := StringReplace(FStampExe, '\', '/', [rfReplaceAll]);
  WriteTextFile(FTarget + '/source/app.pas',
    'program app;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'const'#10 +
    '{$I Version.inc}'#10 +
    'begin'#10 +
    '  WriteLn(PROGRAM_VERSION);'#10 +
    'end.'#10);
  for Round := 1 to BUILD_ROUND_COUNT do
  begin
    Version := '4.0.' + IntToStr(Round);
    WriteTargetManifest(Version,
      'units = ["source"]'#10 +
      ''#10 +
      '[prebuild]'#10 +
      'stamp-version = { command = "' + StampCommand + '", '
      + 'inputs = ["lwpt.toml"], output = "source/' + INCLUDE_NAME + '" }'#10 +
      ''#10 +
      '[build]'#10 +
      'app = { source = "source/app.pas", output = "build/app" }'#10);
    { The staleness gate cannot see an edit made in the same FileAge tick
      as the previous round's output, so date the manifest past it
      explicitly instead of relying on elapsed time. The first round has
      no output yet, so its hook runs regardless. }
    if Round > 1 then
    begin
      Expect<Integer>(FileSetDate(FTarget + '/lwpt.toml',
        DateTimeToFileDate(FileDateToDateTime(FileAge(IncludePath))
          + NEWER_INPUT_SECONDS / SecsPerDay))).ToBe(0);
      Expect<Boolean>(FileAge(FTarget + '/lwpt.toml') > FileAge(IncludePath))
        .ToBe(True);
    end;
    SetLength(Builds, BUILD_COUNT);
    for Index := 0 to High(Builds) do Builds[Index] := nil;
    try
      for Index := 0 to High(Builds) do
        Builds[Index] := TChild.Create(LwptBinaryPath, FTarget, ['build'],
          [VersionOverrideCleared,
           WORKER_STATE_DIR_ENV + '=' + WorkerState,
           WORKER_BUDGET_ENV + '=' + IntToStr(BUILD_COUNT),
           WORKER_LEASE_TOKEN_ENV + '='], True);
      Deadline := GetTickCount64 + BUILD_MILLISECONDS;
      for Index := 0 to High(Builds) do Builds[Index].Finish(Deadline);
      ExpectSucceeded(Builds);
      for Index := 0 to High(Builds) do
        Expect<Boolean>(Pos('inputs changed', Builds[Index].Output) = 0)
          .ToBe(True);
    finally
      FreeChildren(Builds);
    end;
    Expect<string>(ReadBinaryFile(IncludePath)).ToBe(ExpectedText(Version));
    Expect<string>(DirectoryEntries(FTarget + '/source'))
      .ToBe('app.pas,' + INCLUDE_NAME);
    Expect<Boolean>(Pos(TEMP_PREFIX,
      DirectoryEntries(FTarget + '/.lwpt/tmp')) = 0).ToBe(True);
    App := TChild.Create(ExpandFileName(ExpectedExe(FTarget + '/build/app')),
      FTarget, [], [], True);
    try
      App.Finish(GetTickCount64 + CHILD_MILLISECONDS);
      Expect<Integer>(App.ExitCode).ToBe(0);
      Expect<string>(Trim(App.Output)).ToBe(Version);
    finally
      App.Free;
    end;
  end;
end;

procedure TStampVersionTest.TestUnusableStagingDirectoryFailsCleanly;
var
  Stamp: TChild;
  Past: LongInt;
begin
  ResetTarget(True);
  WriteTargetManifest('5.0.0');
  WriteTextFile(IncludePath, ExpectedText('4.9.9'));
  Past := DateTimeToFileDate(Now - PAST_AGE_DAYS);
  Expect<Integer>(FileSetDate(IncludePath, Past)).ToBe(0);
  { A regular file named .lwpt keeps .lwpt/tmp from ever being created. }
  WriteTextFile(FTarget + '/.lwpt', 'not a directory');
  Stamp := RunStamp(FTarget);
  try
    Expect<Boolean>(Stamp.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos('cannot create staging directory', Stamp.Output) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('tmp', Stamp.Output) > 0).ToBe(True);
  finally
    Stamp.Free;
  end;
  Expect<string>(ReadBinaryFile(IncludePath)).ToBe(ExpectedText('4.9.9'));
  Expect<LongInt>(FileAge(IncludePath)).ToBe(Past);
  Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
  Expect<string>(DirectoryEntries(FTarget)).ToBe('.lwpt,lwpt.toml,source');
end;

procedure TStampVersionTest.TestMissingSourceDirectoryFailsCleanly;
var
  Stamp: TChild;
begin
  ResetTarget(False);
  WriteTargetManifest('3.0.0');
  Stamp := RunStamp(FTarget);
  try
    Expect<Boolean>(Stamp.ExitCode <> 0).ToBe(True);
  finally
    Stamp.Free;
  end;
  { The temporary file was written to .lwpt/tmp before the rename failed;
    nothing may be left there. }
  Expect<string>(DirectoryEntries(FTarget + '/.lwpt/tmp')).ToBe('');
  Expect<Boolean>(DirectoryExists(FTarget + '/source')).ToBe(False);
end;

procedure TStampVersionTest.TestFailedReplacementRemovesTemporaryFile;
var
  Stamp: TChild;
begin
  ResetTarget(True);
  WriteTargetManifest('6.0.0');
  { A directory at the destination makes the replacement fail only after
    the temporary file is complete. }
  ForceDirectories(IncludePath + '/occupied');
  Stamp := RunStamp(FTarget);
  try
    Expect<Boolean>(Stamp.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos(TEMP_PREFIX, Stamp.Output) > 0).ToBe(True);
  finally
    Stamp.Free;
  end;
  Expect<string>(DirectoryEntries(FTarget + '/.lwpt/tmp')).ToBe('');
  Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
  Expect<string>(DirectoryEntries(IncludePath)).ToBe('occupied');
end;

procedure TStampVersionTest.SetupTests;
begin
  Test('concurrent runs across changing versions publish complete text '
    + 'and leave no temporary file', TestConcurrentRunsPublishCompleteText);
  Test('concurrent runs whose text is already present leave the file '
    + 'untouched', TestCurrentTextIsLeftUntouched);
  Test('smoke: concurrent lwpt builds using the hook all succeed',
    TestConcurrentBuildsSmoke);
  Test('an unusable .lwpt/tmp fails cleanly and leaves the destination '
    + 'unchanged', TestUnusableStagingDirectoryFailsCleanly);
  Test('a target without source/ fails and removes its temporary file',
    TestMissingSourceDirectoryFailsCleanly);
  Test('a failed replacement removes its written temporary file',
    TestFailedReplacementRemovesTemporaryFile);
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = GATE_ARGUMENT) then
  begin
    ExitCode := RunGate;
    Exit;
  end;
  TestRunnerProgram.AddSuite(TStampVersionTest.Create(
    'stamp-version: concurrent runs'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
