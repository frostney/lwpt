{ LWPT.Command.Build.Test — TLWPTCompilerProcess cancellation, reaping,
  and exit-code coverage below the compiler-driver seam, plus concurrent
  version-include generation. }

program LWPT.Command.Build.Test;

{$mode delphi}{$H+}
{$modeswitch nestedcomments+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Command.Build,
  LWPT.Core,
  LWPT.Manifest,
  LWPT.ProcessTree,
  TestingPascalLibrary,
  Tests.PayloadHandoff,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  CompilerProcessProxyOption = '--' + PROGRAM_NAME
    + '-compiler-process-proxy';
  CompilerGrandchildProxyOption = '--' + PROGRAM_NAME
    + '-compiler-grandchild-proxy';
  CompilerExitProxyOption = '--' + PROGRAM_NAME
    + '-compiler-exit-proxy';
  CompilerNormalExitProxyOption = '--' + PROGRAM_NAME
    + '-compiler-normal-exit-proxy';
  CompilerProxySleepMilliseconds = 30000;
  CompilerSurvivingDescendantProxyOption = '--' + PROGRAM_NAME
    + '-compiler-surviving-descendant-proxy';
  ProcessStartupTimeoutSeconds = 10;
  ProcessExitTimeoutSeconds = 3;

type
  TLWPTCompilerProcessTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCompilerCancellationCapturesAndReaps;
    procedure TestCompilerNormalExitLeavesDescendantAlive;
    procedure TestCompilerNonZeroExitIsReported;
    procedure TestProcessTreeStateReleasesOwnedResources;
  end;

  { One build's version-include generation, repeated. }
  TVersionIncludeThread = class(TThread)
  private
    FErrorText: string;
    FManifest: TManifest;
    FProjectRoot: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProjectRoot: string;
      const AManifest: TManifest);
    property ErrorText: string read FErrorText;
  end;

  TLWPTVersionIncludeTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestConcurrentGenerationNeverAborts;
  end;

  TCompilerRunnerThread = class(TThread)
  private
    FRunner: TLWPTCompilerProcess;
    FMarker: string;
  protected
    procedure Execute; override;
  public
    Output: string;
    ErrorMessage: string;
    ExitCode: Integer;
    constructor Create(const ARunner: TLWPTCompilerProcess;
      const AMarker: string);
  end;

{$IFDEF MSWINDOWS}
function LWPTGetProcessHandleCount(const AProcess: THandle;
  var AHandleCount: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetProcessHandleCount';
{$ENDIF}

function CurrentProcessHandleCount: Integer;
{$IFDEF MSWINDOWS}
var
  HandleCount: DWORD;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if not LWPTGetProcessHandleCount(Windows.GetCurrentProcess,
    HandleCount) then
    RaiseLastOSError;
  Result := HandleCount;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

constructor TCompilerRunnerThread.Create(const ARunner: TLWPTCompilerProcess;
  const AMarker: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRunner := ARunner;
  FMarker := AMarker;
  ExitCode := -1;
end;

procedure TerminateTestProcess(const APID: Integer);
{$IFDEF MSWINDOWS}
var
  ProcessHandle: THandle;
{$ENDIF}
begin
  if not ProcessIsRunning(APID) then Exit;
  {$IFDEF UNIX}
  FpKill(APID, SIGKILL);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ProcessHandle := Windows.OpenProcess(Windows.PROCESS_TERMINATE, False,
    DWORD(APID));
  if ProcessHandle = 0 then Exit;
  try
    Windows.TerminateProcess(ProcessHandle, 1);
  finally
    Windows.CloseHandle(ProcessHandle);
  end;
  {$ENDIF}
end;

procedure TCompilerRunnerThread.Execute;
begin
  try
    ExitCode := FRunner.Run([CompilerProcessProxyOption, FMarker], Output);
  except
    on E: Exception do ErrorMessage := E.Message;
  end;
end;

procedure TLWPTCompilerProcessTests.
  TestCompilerCancellationCapturesAndReaps;
var
  Runner: TLWPTCompilerProcess;
  Worker: TCompilerRunnerThread;
  Scratch, Marker, GrandchildPIDPath: string;
  GrandchildPID: Integer;
  Started: TDateTime;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-process-cancel');
  Marker := Scratch + '/ready';
  GrandchildPIDPath := Scratch + '/grandchild-pid';
  RecursiveDelete(Scratch);
  Runner := TLWPTCompilerProcess.Create(ExpandFileName(ParamStr(0)));
  Worker := TCompilerRunnerThread.Create(Runner, Marker);
  try
    Worker.Start;
    Started := Now;
    while not FileExists(Marker) do
    begin
      if (Now - Started) * SecondsPerDay
        > ProcessStartupTimeoutSeconds then Break;
      Sleep(ProcessPollMilliseconds);
    end;
    Expect<Boolean>(FileExists(Marker)).ToBe(True);
    Expect<Boolean>(PayloadIsReadable(GrandchildPIDPath)).ToBe(True);
    GrandchildPID := StrToInt(Trim(ReadPayloadText(GrandchildPIDPath)));
    Runner.Cancel;
    Worker.WaitFor;
    Expect<string>(Worker.ErrorMessage).ToBe('');
    Expect<Boolean>(Worker.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos('captured-output-', Worker.Output) > 0).ToBe(True);
    Expect<Boolean>(Length(Worker.Output) > 65536).ToBe(True);
    Started := Now;
    while ProcessIsRunning(GrandchildPID)
      and ((Now - Started) * SecondsPerDay < ProcessExitTimeoutSeconds) do
      Sleep(ProcessPollMilliseconds);
    Expect<Boolean>(ProcessIsRunning(GrandchildPID)).ToBe(False);
  finally
    Runner.Cancel;
    Worker.WaitFor;
    Worker.Free;
    Runner.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TLWPTCompilerProcessTests.TestCompilerNonZeroExitIsReported;
var
  Runner: TLWPTCompilerProcess;
  OutText: string;
begin
  { Regression: on Unix, TProcess.ExitCode reads 0 when WaitOnExit
    itself reaps the child (FPC 3.2.2 stores the decoded code and
    ExitCode re-applies wifexited to it), so a failed fpc run was
    treated as a successful target and publication of a non-existent
    candidate binary was attempted. Run must surface the child's real
    exit code no matter which call reaped it. }
  Runner := TLWPTCompilerProcess.Create(ExpandFileName(ParamStr(0)));
  try
    Expect<Integer>(Runner.Run([CompilerExitProxyOption, '7'],
      OutText)).ToBe(7);
    Expect<Boolean>(Pos('exit-proxy-output', OutText) > 0).ToBe(True);
    { 128 is the nastiest edge: its low seven bits are zero, so the
      double-decode also mistakes it for a clean wifexited status. }
    Expect<Integer>(Runner.Run([CompilerExitProxyOption, '128'],
      OutText)).ToBe(128);
    Expect<Integer>(Runner.Run([CompilerExitProxyOption, '0'],
      OutText)).ToBe(0);
  finally
    Runner.Free;
  end;
end;

procedure TLWPTCompilerProcessTests.
  TestCompilerNormalExitLeavesDescendantAlive;
var
  Child: TProcess;
  ProcessTree: TLWPTProcessTree;
  Scratch, DescendantPIDPath: string;
  DescendantPID: Integer;
  Started: TDateTime;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-process-normal-exit');
  DescendantPIDPath := Scratch + '/descendant-pid';
  DescendantPID := -1;
  RecursiveDelete(Scratch);
  ForceDirectories(Scratch);
  Child := TProcess.Create(nil);
  ProcessTree := TLWPTProcessTree.Create(Child);
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    Child.Parameters.Add(CompilerNormalExitProxyOption);
    Child.Parameters.Add(DescendantPIDPath);
    ProcessTree.Execute;
    Child.WaitOnExit;
    Expect<Integer>(Child.ExitStatus).ToBe(0);
    Expect<Boolean>(PayloadIsReadable(DescendantPIDPath)).ToBe(True);
    DescendantPID := StrToInt(Trim(ReadPayloadText(DescendantPIDPath)));
    FreeAndNil(ProcessTree);
    { Closing a successful tree's Windows Job handle must not act like
      cancellation; Unix process-group ownership has the same contract. }
    Expect<Boolean>(ProcessIsRunning(DescendantPID)).ToBe(True);
  finally
    ProcessTree.Free;
    Child.Free;
    TerminateTestProcess(DescendantPID);
    Started := Now;
    while ProcessIsRunning(DescendantPID)
      and ((Now - Started) * SecondsPerDay < ProcessExitTimeoutSeconds) do
      Sleep(ProcessPollMilliseconds);
    RecursiveDelete(Scratch);
  end;
end;

procedure TLWPTCompilerProcessTests.
  TestProcessTreeStateReleasesOwnedResources;
const
  LifecycleCount = 16;
var
  BaselineHandleCount, FinalHandleCount, LifecycleIndex: Integer;
  Child: TProcess;
  ProcessTree: TLWPTProcessTree;
begin
  { The Windows state owns one Job Object handle. Repeated construction and
    teardown must return the process to its original handle count. The same
    lifecycle runs on Unix to keep the platform-neutral owner path covered. }
  Child := TProcess.Create(nil);
  ProcessTree := TLWPTProcessTree.Create(Child);
  ProcessTree.Free;
  Child.Free;
  BaselineHandleCount := CurrentProcessHandleCount;
  for LifecycleIndex := 1 to LifecycleCount do
  begin
    Child := TProcess.Create(nil);
    ProcessTree := TLWPTProcessTree.Create(Child);
    try
      Expect<Boolean>(Assigned(ProcessTree)).ToBe(True);
    finally
      ProcessTree.Free;
      Child.Free;
    end;
  end;
  FinalHandleCount := CurrentProcessHandleCount;
  Expect<Integer>(FinalHandleCount).ToBe(BaselineHandleCount);
end;

procedure TLWPTCompilerProcessTests.SetupTests;
begin
  Test('compiler cancellation captures output and reaps the child',
    TestCompilerCancellationCapturesAndReaps);
  Test('compiler normal exit leaves a live descendant alone',
    TestCompilerNormalExitLeavesDescendantAlive);
  Test('nonzero compiler exit is reported, not dropped to 0',
    TestCompilerNonZeroExitIsReported);
  Test('process-tree state releases its owned resources',
    TestProcessTreeStateReleasesOwnedResources);
end;

const
  VersionIncludeThreadCount = 4;
  VersionIncludeGenerations = 50;

constructor TVersionIncludeThread.Create(const AProjectRoot: string;
  const AManifest: TManifest);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProjectRoot := AProjectRoot;
  FManifest := AManifest;
end;

procedure TVersionIncludeThread.Execute;
var
  Generation: Integer;
begin
  try
    for Generation := 1 to VersionIncludeGenerations do
      GenerateVersionInclude(FProjectRoot, FManifest);
  except
    on E: Exception do FErrorText := E.Message;
  end;
end;

function CountDirectoryEntries(const APath: string): Integer;
var
  Found: TSearchRec;
begin
  Result := 0;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(APath) + '*',
      faAnyFile, Found) = 0 then
    try
      repeat
        if (Found.Name <> '.') and (Found.Name <> '..') then Inc(Result);
      until SysUtils.FindNext(Found) <> 0;
    finally
      SysUtils.FindClose(Found);
    end;
end;

procedure TLWPTVersionIncludeTests.TestConcurrentGenerationNeverAborts;
var
  Include, Project: string;
  Index: Integer;
  Manifest, WriterManifest: TManifest;
  Threads: array[0..VersionIncludeThreadCount - 1] of TVersionIncludeThread;
begin
  { Concurrent builds of one project each regenerate the version include.
    Unserialized, Windows ReplaceFileW error 1177 let a peer publish into
    the path one writer had emptied, and that writer aborted its build
    (PR #355's BuildSessions failure). Generation now serializes on the
    project's build-coordination lock. Each writer bakes its own version,
    so every generation replaces the include instead of finding its text
    already there: no writer fails, the include holds one writer's text,
    and no staging or backup file is left beside it. }
  Project := ExpandFileName('build/tests/tmp/version-include-concurrency');
  RecursiveDelete(Project);
  ForceDirectories(Project + '/source');
  WriteTextFile(Project + '/lwpt.toml',
      '[package]'#10
    + 'name = "version-concurrency"'#10
    + 'version = "1.2.3"'#10
    + #10
    + '[version]'#10
    + 'output = "source/Version.Generated.inc"'#10);
  Manifest := LoadManifest(Project + '/lwpt.toml');
  for Index := 0 to High(Threads) do Threads[Index] := nil;
  try
    for Index := 0 to High(Threads) do
    begin
      WriterManifest := Manifest;
      WriterManifest.Version := '1.2.' + IntToStr(Index);
      Threads[Index] := TVersionIncludeThread.Create(Project,
        WriterManifest);
    end;
    for Index := 0 to High(Threads) do Threads[Index].Start;
    for Index := 0 to High(Threads) do Threads[Index].WaitFor;
    for Index := 0 to High(Threads) do
      Expect<string>(Threads[Index].ErrorText).ToBe('');
    Include := ReadBinaryFile(Project + '/source/Version.Generated.inc');
    Expect<Boolean>(Pos('BAKED_VERSION = ''1.2.', Include) > 0).ToBe(True);
    Expect<Integer>(CountDirectoryEntries(Project + '/source')).ToBe(1);
  finally
    for Index := 0 to High(Threads) do Threads[Index].Free;
    RecursiveDelete(Project);
  end;
end;

procedure TLWPTVersionIncludeTests.SetupTests;
begin
  Test('concurrent version-include generation never aborts',
    TestConcurrentGenerationNeverAborts);
end;

function RunCompilerProcessProxy: Integer;
var
  Child: TProcess;
  OutputIndex: Integer;
  GrandchildPIDPath: string;
begin
  for OutputIndex := 1 to 6000 do Write('captured-output-');
  Flush(Output);
  GrandchildPIDPath := ExtractFileDir(ParamStr(2)) + '/grandchild-pid';
  Child := TProcess.Create(nil);
  Child.Executable := ExpandFileName(ParamStr(0));
  Child.Parameters.Add(CompilerGrandchildProxyOption);
  Child.Parameters.Add(GrandchildPIDPath);
  Child.Execute;
  while not PayloadIsReadable(GrandchildPIDPath) do
    Sleep(ProcessPollMilliseconds);
  WriteTextFile(ParamStr(2), 'ready');
  Sleep(CompilerProxySleepMilliseconds);
  Result := 0;
end;

function RunCompilerGrandchildProxy: Integer;
begin
  PublishReadablePayload(ParamStr(2), IntToStr(GetProcessID));
  Sleep(CompilerProxySleepMilliseconds);
  Result := 0;
end;

function RunCompilerNormalExitProxy: Integer;
var
  Descendant: TProcess;
  Started: TDateTime;
begin
  Result := 2;
  Descendant := TProcess.Create(nil);
  try
    Descendant.Executable := ExpandFileName(ParamStr(0));
    Descendant.Parameters.Add(CompilerSurvivingDescendantProxyOption);
    Descendant.Parameters.Add(ParamStr(2));
    Descendant.Execute;
    Started := Now;
    while (not PayloadIsReadable(ParamStr(2))) and Descendant.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupTimeoutSeconds) do
      Sleep(ProcessPollMilliseconds);
    if not PayloadIsReadable(ParamStr(2)) then
    begin
      if Descendant.Running then Descendant.Terminate(1);
      Exit;
    end;
    Result := 0;
  finally
    Descendant.Free;
  end;
end;

function RunCompilerSurvivingDescendantProxy: Integer;
begin
  PublishReadablePayload(ParamStr(2), IntToStr(GetProcessID));
  Sleep(CompilerProxySleepMilliseconds);
  Result := 0;
end;

{ Emit a marker (so output capture is asserted alongside the exit
  code) and terminate with the requested status. }
function RunCompilerExitProxy: Integer;
begin
  WriteLn('exit-proxy-output');
  Flush(Output);
  Result := StrToInt(ParamStr(2));
end;

begin
  if (ParamCount >= 2)
     and (ParamStr(1) = CompilerProcessProxyOption) then
    Halt(RunCompilerProcessProxy);
  if (ParamCount >= 2)
     and (ParamStr(1) = CompilerGrandchildProxyOption) then
    Halt(RunCompilerGrandchildProxy);
  if (ParamCount >= 2)
     and (ParamStr(1) = CompilerExitProxyOption) then
    Halt(RunCompilerExitProxy);
  if (ParamCount >= 2)
     and (ParamStr(1) = CompilerNormalExitProxyOption) then
    Halt(RunCompilerNormalExitProxy);
  if (ParamCount >= 2)
     and (ParamStr(1) = CompilerSurvivingDescendantProxyOption) then
    Halt(RunCompilerSurvivingDescendantProxy);
  TestRunnerProgram.AddSuite(TLWPTCompilerProcessTests.Create(
    'build: compiler process'));
  TestRunnerProgram.AddSuite(TLWPTVersionIncludeTests.Create(
    'build: version include'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
