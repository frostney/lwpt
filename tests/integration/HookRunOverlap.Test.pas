{ HookRunOverlap.Test — concurrent runs of one staleness-gated output (#442).

  Two LWPT invocations in one checkout can run the same gated generator at
  the same time. Neither may leave a run record that makes the output look
  fresh when it was generated from other inputs, and no invocation may wait
  on another across a command, so nested delegation and a machine budget of
  one worker cannot deadlock.

  This program doubles as the generator and as the hook commands: run with
  ChildArgument, it acts as one of them. The interleavings are forced with
  existence-only marker files in a control directory; no step depends on
  timing. }
program HookRunOverlap.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.ProcessTree,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  ChildArgument = '--hook-run-overlap-child';
  { Selects the generator's barriers in one invocation's process tree. }
  RoleEnvironment = 'HOOK_RUN_OVERLAP_ROLE';
  RoleFirst = 'first';
  RoleSecond = 'second';
  BarrierMilliseconds = 60000;
  ChildMilliseconds = 120000;
  PollMilliseconds = 10;
  NoMarker = '-';
  { Explicit times keep the time rule out of every check below: the input
    two whole seconds older than the output is older at any timestamp
    precision, so only the run record decides whether a run is skipped. }
  OutputStampSeconds = 1700000000;
  InputStampSeconds = OutputStampSeconds - 2;

type
  TChild = class
  private
    FProcess: TProcess;
    FTree: TLWPTProcessTree;
    FOutput: string;
  public
    constructor Create(const ADirectory, AState, ARole: string;
      const AArguments: array of string);
    destructor Destroy; override;
    procedure Drain;
    function Running: Boolean;
    function Status: Integer;
    property Output: string read FOutput;
  end;

  THookRunOverlap = class(TTestSuite)
  private
    FScratch, FProject, FControl, FWorkerState: string;
    procedure WriteProject(const ABody: string);
    procedure DateInputBeforeOutput;
    function ReadOutput: string;
    function RunCount: Integer;
    function ChildEnvironment(const ARole: string): TStringArray;
    function WaitForExit(AChild: TChild; const AName: string): Integer;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestOverlappingRunsLeaveOutputStale;
    procedure TestNestedDelegationRecordsWithoutDeadlock;
    procedure TestBudgetOfOneOverlapCompletes;
  end;

function TomlString(const AValue: string): string;
begin
  Result := '"' + StringReplace(StringReplace(AValue, '\', '\\',
    [rfReplaceAll]), '"', '\"', [rfReplaceAll]) + '"';
end;

procedure Mark(const ARoot, AName: string);
begin
  { Existence-only barriers: no process reads an open payload. }
  WriteTextFile(ARoot + '/' + AName, '');
end;

function Marked(const ARoot, AName: string): Boolean;
begin
  Result := FileExists(ARoot + '/' + AName);
end;

function WaitForRelease(const ARoot, AName: string): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    if Marked(ARoot, AName) then Exit(True);
    Sleep(PollMilliseconds);
  until GetTickCount64 - StartedAt >= ChildMilliseconds;
  WriteLn(StdErr, 'Timed out waiting for ', AName);
  Result := False;
end;

function ReadWholeFile(const APath: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Result := Trim(Lines.Text);
  finally
    Lines.Free;
  end;
end;

procedure WriteWholeFile(const APath, AText: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

{ The generator: out.txt from in.txt, in the project directory. It appends
  each run's input to runs.log in the control directory. The first role
  holds between reading the input and writing the output; the second holds
  after writing it, before its command returns to LWPT. }
function RunGenerator(const AControl: string): Integer;
var
  Input, Role: string;
  Log: TStringList;
begin
  Input := ReadWholeFile('in.txt');
  Log := TStringList.Create;
  try
    if FileExists(AControl + '/runs.log') then
      Log.LoadFromFile(AControl + '/runs.log');
    Log.Add(Input);
    Log.SaveToFile(AControl + '/runs.log');
  finally
    Log.Free;
  end;
  Role := GetEnvironmentVariable(RoleEnvironment);
  if Role = RoleFirst then
  begin
    Mark(AControl, 'first-read');
    if not WaitForRelease(AControl, 'first-go') then Exit(1);
  end;
  WriteWholeFile('out.txt', 'generated from ' + Input);
  if Role = RoleSecond then
  begin
    Mark(AControl, 'second-wrote');
    if not WaitForRelease(AControl, 'second-go') then Exit(1);
  end;
  Result := 0;
end;

{ A gated hook that delegates to a nested LWPT command: it marks that it is
  running, optionally waits for AWaitMarker, then runs the nested command
  and returns its exit code. }
function RunOuter(const AControl, AWaitMarker: string): Integer;
var
  Nested: TProcess;
  i: Integer;
begin
  Mark(AControl, 'outer-entered');
  if (AWaitMarker <> NoMarker)
     and not WaitForRelease(AControl, AWaitMarker) then Exit(1);
  Nested := TProcess.Create(nil);
  try
    Nested.Executable := ParamStr(5);
    for i := 6 to ParamCount do Nested.Parameters.Add(ParamStr(i));
    Nested.Execute;
    Result := FinishChild(Nested, ChildMilliseconds, 'nested LWPT command');
  finally
    Nested.Free;
  end;
end;

{ An ungated per-entry prebuild hook. It runs while its build holds a
  worker, so its marker proves that the only worker is taken. }
function RunHold(const AControl: string): Integer;
begin
  Mark(AControl, 'worker-held');
  if not WaitForRelease(AControl, 'outer-entered') then Exit(1);
  Result := 0;
end;

constructor TChild.Create(const ADirectory, AState, ARole: string;
  const AArguments: array of string);
var
  Argument: string;
begin
  inherited Create;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := LwptBinaryPath;
  FProcess.CurrentDirectory := ADirectory;
  FProcess.Options := [poUsePipes, poStderrToOutPut];
  for Argument in AArguments do FProcess.Parameters.Add(Argument);
  ConfigureProcessEnvironment(FProcess, [WORKER_STATE_DIR_ENV + '=' + AState,
    WORKER_BUDGET_ENV + '=1', WORKER_LEASE_TOKEN_ENV + '=',
    WORKER_STALE_SECONDS_ENV + '=300', RoleEnvironment + '=' + ARole]);
  FTree := TLWPTProcessTree.Create(FProcess);
  FTree.Execute;
end;

destructor TChild.Destroy;
begin
  if Assigned(FTree) and Assigned(FProcess) and FProcess.Running then
    FTree.Terminate;
  Drain;
  FTree.Free;
  FProcess.Free;
  inherited Destroy;
end;

procedure TChild.Drain;
var
  Buffer: array[0..4095] of Byte;
  Available, Count: LongInt;
  Chunk: RawByteString;
begin
  if not Assigned(FProcess) or not Assigned(FProcess.Output) then Exit;
  { Drain a bounded available-byte snapshot, never wait for pipe EOF. }
  Available := FProcess.Output.NumBytesAvailable;
  while Available > 0 do
  begin
    Count := Available;
    if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
    Count := FProcess.Output.Read(Buffer, Count);
    if Count <= 0 then Break;
    SetString(Chunk, PAnsiChar(@Buffer[0]), Count);
    FOutput := FOutput + string(Chunk);
    Dec(Available, Count);
  end;
end;

function TChild.Running: Boolean;
begin
  Drain;
  Result := FProcess.Running;
  { See BuildFairness.Test: on Windows the exit status is published before
    the child's handles are run down, so wait for the process handle. }
  if not Result then
    Result := not WaitForChildExit(FProcess, CHILD_KILL_MILLISECONDS);
end;

function TChild.Status: Integer;
begin
  Drain;
  Result := ChildProcessExitCode(FProcess);
end;

procedure WaitForMarker(const ARoot, AName: string; AChild: TChild);
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not Marked(ARoot, AName) do
  begin
    if not AChild.Running then
      raise Exception.Create('Child exited before ' + AName + ': '
        + AChild.Output);
    if GetTickCount64 - StartedAt >= BarrierMilliseconds then
      raise Exception.Create('Timed out waiting for ' + AName + ': '
        + AChild.Output);
    Sleep(PollMilliseconds);
  end;
end;

procedure THookRunOverlap.BeforeEach;
begin
  FScratch := CreateScratchRoot('hook-run-overlap');
  RecursiveDelete(FScratch);
  FProject := FScratch + '/project';
  FControl := FScratch + '/control';
  FWorkerState := FScratch + '/worker-state';
  ForceDirectories(FProject + '/source');
  ForceDirectories(FControl);
  ForceDirectories(FWorkerState);
end;

procedure THookRunOverlap.AfterEach;
begin
  RecursiveDelete(FScratch);
end;

procedure THookRunOverlap.WriteProject(const ABody: string);
begin
  WriteTextFile(FProject + '/source/app.pas',
    'program app; begin end.' + LineEnding);
  WriteTextFile(FProject + '/source/nested.pas',
    'program nested; begin end.' + LineEnding);
  WriteTextFile(FProject + '/' + PROGRAM_NAME + '.toml',
    '[package]' + LineEnding
    + 'name = "hook-run-overlap"' + LineEnding
    + 'version = "0.0.0"' + LineEnding
    + 'units = ["source"]' + LineEnding
    + ABody);
  WriteWholeFile(FProject + '/in.txt', 'v1');
end;

{ Dates the input older than the output, as an untouched checkout would. }
procedure THookRunOverlap.DateInputBeforeOutput;
begin
  SetFileModificationTime(FProject + '/in.txt', InputStampSeconds, 0);
  SetFileModificationTime(FProject + '/out.txt', OutputStampSeconds, 0);
end;

function THookRunOverlap.ReadOutput: string;
begin
  if not FileExists(FProject + '/out.txt') then Exit('');
  Result := ReadWholeFile(FProject + '/out.txt');
end;

function THookRunOverlap.RunCount: Integer;
var
  Log: TStringList;
begin
  if not FileExists(FControl + '/runs.log') then Exit(0);
  Log := TStringList.Create;
  try
    Log.LoadFromFile(FControl + '/runs.log');
    Result := Log.Count;
  finally
    Log.Free;
  end;
end;

function THookRunOverlap.ChildEnvironment(const ARole: string): TStringArray;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := WORKER_STATE_DIR_ENV + '=' + FWorkerState;
  Result[1] := RoleEnvironment + '=' + ARole;
end;

function THookRunOverlap.WaitForExit(AChild: TChild;
  const AName: string): Integer;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while AChild.Running do
  begin
    if GetTickCount64 - StartedAt >= ChildMilliseconds then
      raise Exception.Create(AName + ' did not exit within '
        + IntToStr(ChildMilliseconds) + ' ms (deadlock?): '
        + AChild.Output);
    Sleep(PollMilliseconds);
  end;
  Result := AChild.Status;
  if Result <> 0 then
    WriteLn(AName, ' exited ', Result, ':', LineEnding, AChild.Output);
end;

function GeneratorHook(const AControl: string): string;
begin
  Result := '{ command = ' + TomlString(ExpandFileName(ParamStr(0)))
    + ', args = [' + TomlString(ChildArgument) + ', "gen", '
    + TomlString(AControl) + '], inputs = ["in.txt"], output = "out.txt" }';
end;

{ Run A reads input v1 and holds. The input becomes v2 and run B writes
  v2's output, then holds before its command returns. A then writes v1's
  output over it and finishes, and B finishes after it. B's record, taken
  after its command, would pair v2's inputs with A's output, so the next
  invocation would skip the generator and keep v1's output. Neither run may
  record: the next invocation regenerates. }
procedure THookRunOverlap.TestOverlappingRunsLeaveOutputStale;
var
  First, Second: TChild;
  Third: TLwptResult;
begin
  WriteProject('[gen]' + LineEnding
    + 'command = ' + TomlString(ExpandFileName(ParamStr(0))) + LineEnding
    + 'args = [' + TomlString(ChildArgument) + ', "gen", '
    + TomlString(FControl) + ']' + LineEnding
    + 'inputs = ["in.txt"]' + LineEnding
    + 'output = "out.txt"' + LineEnding);
  First := nil;
  Second := nil;
  try
    First := TChild.Create(FProject, FWorkerState, RoleFirst, ['run', 'gen']);
    WaitForMarker(FControl, 'first-read', First);
    WriteWholeFile(FProject + '/in.txt', 'v2');
    Second := TChild.Create(FProject, FWorkerState, RoleSecond,
      ['run', 'gen']);
    WaitForMarker(FControl, 'second-wrote', Second);
    Mark(FControl, 'first-go');
    Expect<Integer>(WaitForExit(First, 'first run')).ToBe(0);
    Mark(FControl, 'second-go');
    Expect<Integer>(WaitForExit(Second, 'second run')).ToBe(0);
  finally
    Mark(FControl, 'first-go');
    Mark(FControl, 'second-go');
    Second.Free;
    First.Free;
  end;
  { The interleaving happened: the output is v1's, the input v2. }
  Expect<string>(ReadOutput).ToBe('generated from v1');
  Expect<Integer>(RunCount).ToBe(2);
  DateInputBeforeOutput;

  Third := RunLwpt(['run', 'gen'], FProject, ChildEnvironment(''));
  DumpRunFailure('third run', Third, 0);
  Expect<Integer>(Third.ExitCode).ToBe(0);
  Expect<Integer>(RunCount).ToBe(3);
  Expect<string>(ReadOutput).ToBe('generated from v2');
end;

{ A gated run task whose command runs a nested `lwpt run` for the same
  output. The nested run is part of its ancestor's run, not a competitor:
  the invocation finishes, and its record lets the next one skip. }
procedure THookRunOverlap.TestNestedDelegationRecordsWithoutDeadlock;
var
  Run: TLwptResult;
begin
  WriteProject('[outer]' + LineEnding
    + 'command = ' + TomlString(ExpandFileName(ParamStr(0))) + LineEnding
    + 'args = [' + TomlString(ChildArgument) + ', "outer", '
    + TomlString(FControl) + ', "' + NoMarker + '", '
    + TomlString(ExpandFileName(LwptBinaryPath)) + ', "run", "gen"]'
    + LineEnding
    + 'inputs = ["in.txt"]' + LineEnding
    + 'output = "out.txt"' + LineEnding
    + LineEnding
    + '[gen]' + LineEnding
    + 'command = ' + TomlString(ExpandFileName(ParamStr(0))) + LineEnding
    + 'args = [' + TomlString(ChildArgument) + ', "gen", '
    + TomlString(FControl) + ']' + LineEnding
    + 'inputs = ["in.txt"]' + LineEnding
    + 'output = "out.txt"' + LineEnding);

  Run := RunLwpt(['run', 'outer'], FProject, ChildEnvironment(''),
    ChildMilliseconds);
  DumpRunFailure('nested run', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadOutput).ToBe('generated from v1');
  Expect<Integer>(RunCount).ToBe(1);
  DateInputBeforeOutput;

  Run := RunLwpt(['run', 'outer'], FProject, ChildEnvironment(''),
    ChildMilliseconds);
  DumpRunFailure('repeated nested run', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RunCount).ToBe(1);
end;

{ The interleaving that deadlocks a per-output lock held across commands
  under a budget of one worker. Run task X holds its gated run of out.txt
  and waits until build Y holds the only worker; Y's per-entry prebuild then
  runs its own gated hook for out.txt, while X's command starts a nested
  build that needs Y's worker. Nothing may wait across a command: Y's hook
  runs, Y returns the worker, and X's nested build takes it. The nested
  build compiles another entry: two builds of one entry refuse to publish
  over each other's output (ADR-0020), which would make the result depend
  on timing. }
procedure THookRunOverlap.TestBudgetOfOneOverlapCompletes;
var
  Outer, Build: TChild;
begin
  WriteProject('[build.app]' + LineEnding
    + 'source = "source/app.pas"' + LineEnding
    + 'output = "build/app"' + LineEnding
    + '[build.app.prebuild]' + LineEnding
    + 'a-hold = { command = ' + TomlString(ExpandFileName(ParamStr(0)))
    + ', args = [' + TomlString(ChildArgument) + ', "hold", '
    + TomlString(FControl) + '] }' + LineEnding
    + 'b-gen = ' + GeneratorHook(FControl) + LineEnding
    + '[build.nested]' + LineEnding
    + 'source = "source/nested.pas"' + LineEnding
    + 'output = "build/nested"' + LineEnding
    + LineEnding
    + '[outer]' + LineEnding
    + 'command = ' + TomlString(ExpandFileName(ParamStr(0))) + LineEnding
    + 'args = [' + TomlString(ChildArgument) + ', "outer", '
    + TomlString(FControl) + ', "worker-held", '
    + TomlString(ExpandFileName(LwptBinaryPath))
    + ', "build", "--no-cache", "nested"]' + LineEnding
    + 'inputs = ["in.txt"]' + LineEnding
    + 'output = "out.txt"' + LineEnding);
  Outer := nil;
  Build := nil;
  try
    Outer := TChild.Create(FProject, FWorkerState, '', ['run', 'outer']);
    WaitForMarker(FControl, 'outer-entered', Outer);
    Build := TChild.Create(FProject, FWorkerState, '',
      ['build', '--no-cache', 'app']);
    Expect<Integer>(WaitForExit(Build, 'build')).ToBe(0);
    Expect<Integer>(WaitForExit(Outer, 'outer run')).ToBe(0);
  finally
    Build.Free;
    Outer.Free;
  end;
  Expect<string>(ReadOutput).ToBe('generated from v1');
  Expect<Boolean>(FileExists(FProject + '/' + ExpectedExe('build/app')))
    .ToBe(True);
  Expect<Boolean>(FileExists(FProject + '/' + ExpectedExe('build/nested')))
    .ToBe(True);
end;

procedure THookRunOverlap.SetupTests;
begin
  Test('overlapping runs of one gated output leave it stale',
    TestOverlappingRunsLeaveOutputStale);
  Test('nested delegation for the same output records without deadlock',
    TestNestedDelegationRecordsWithoutDeadlock);
  Test('a budget of one completes overlapping gated runs',
    TestBudgetOfOneOverlapCompletes);
end;

begin
  if (ParamCount >= 3) and (ParamStr(1) = ChildArgument) then
  begin
    if ParamStr(2) = 'gen' then Halt(RunGenerator(ParamStr(3)));
    if ParamStr(2) = 'hold' then Halt(RunHold(ParamStr(3)));
    if (ParamStr(2) = 'outer') and (ParamCount >= 5) then
      Halt(RunOuter(ParamStr(3), ParamStr(4)));
    Halt(2);
  end;
  TestRunnerProgram.AddSuite(THookRunOverlap.Create(
    'concurrent runs of one gated output'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
