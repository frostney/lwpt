{ LWPT.Command.Build.Test — unit-tier coverage for the stale-artefact
  failure heuristic behind the `--clean` retry hint.

  Non-destructive clean rebuild behaviour is covered end-to-end by
  tests/integration/BuildClean.Test.pas through the real binary; this
  file stays at the unit level: string classification plus the
  TLWPTCompilerProcess contract (cancellation reaping, exit-code
  reporting), exercised by re-invoking this test binary as a proxy
  child instead of launching a full build. }

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
  LWPT.ProcessTree,
  TestingPascalLibrary,
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
  TStaleArtefactSignature = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestInternalCompilerExceptionMatches;
    procedure TestResourceCompileErrorMatches;
    procedure TestMissingReslstMatches;
    procedure TestOrdinarySourceErrorDoesNotMatch;
    procedure TestReslstMentionAloneDoesNotMatch;
    procedure TestEmptyOutputDoesNotMatch;
    procedure TestCompilerCancellationCapturesAndReaps;
    procedure TestCompilerNormalExitLeavesDescendantAlive;
    procedure TestCompilerNonZeroExitIsReported;
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

procedure TStaleArtefactSignature.TestInternalCompilerExceptionMatches;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'Fatal: Compilation raised exception internally')).ToBe(True);
end;

procedure TStaleArtefactSignature.TestResourceCompileErrorMatches;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'Error while compiling resources -> compile with -vd for more details'))
    .ToBe(True);
end;

procedure TStaleArtefactSignature.TestMissingReslstMatches;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'fpcres: Error: Cannot open file build/app.reslst')).ToBe(True);
end;

procedure TStaleArtefactSignature.TestOrdinarySourceErrorDoesNotMatch;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'bad.pas(3,3) Error: Identifier not found "ThisDoesNotExist"'#10
    + 'Fatal: Compilation aborted')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestReslstMentionAloneDoesNotMatch;
begin
  { .reslst only signals staleness together with an open/read failure }
  Expect<Boolean>(HasStaleArtefactSignature(
    'Writing resource list build/app.reslst')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestEmptyOutputDoesNotMatch;
begin
  Expect<Boolean>(HasStaleArtefactSignature('')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestCompilerCancellationCapturesAndReaps;
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
    Expect<Boolean>(FileExists(GrandchildPIDPath)).ToBe(True);
    GrandchildPID := StrToInt(Trim(ReadBinaryFile(GrandchildPIDPath)));
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

procedure TStaleArtefactSignature.TestCompilerNonZeroExitIsReported;
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

procedure TStaleArtefactSignature.TestCompilerNormalExitLeavesDescendantAlive;
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
    Expect<Boolean>(FileExists(DescendantPIDPath)).ToBe(True);
    DescendantPID := StrToInt(Trim(ReadBinaryFile(DescendantPIDPath)));
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

procedure TStaleArtefactSignature.SetupTests;
begin
  Test('internal compiler exception matches',
    TestInternalCompilerExceptionMatches);
  Test('resource-compile error matches', TestResourceCompileErrorMatches);
  Test('missing .reslst matches', TestMissingReslstMatches);
  Test('ordinary source error does not match',
    TestOrdinarySourceErrorDoesNotMatch);
  Test('.reslst mention alone does not match',
    TestReslstMentionAloneDoesNotMatch);
  Test('empty output does not match', TestEmptyOutputDoesNotMatch);
  Test('compiler cancellation captures output and reaps the child',
    TestCompilerCancellationCapturesAndReaps);
  Test('compiler normal exit leaves a live descendant alone',
    TestCompilerNormalExitLeavesDescendantAlive);
  Test('nonzero compiler exit is reported, not dropped to 0',
    TestCompilerNonZeroExitIsReported);
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
  while not FileExists(GrandchildPIDPath) do
    Sleep(ProcessPollMilliseconds);
  WriteTextFile(ParamStr(2), 'ready');
  Sleep(CompilerProxySleepMilliseconds);
  Result := 0;
end;

function RunCompilerGrandchildProxy: Integer;
begin
  WriteTextFile(ParamStr(2), IntToStr(GetProcessID));
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
    while (not FileExists(ParamStr(2))) and Descendant.Running
      and ((Now - Started) * SecondsPerDay
        < ProcessStartupTimeoutSeconds) do
      Sleep(ProcessPollMilliseconds);
    if not FileExists(ParamStr(2)) then
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
  WriteTextFile(ParamStr(2), IntToStr(GetProcessID));
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
  TestRunnerProgram.AddSuite(TStaleArtefactSignature.Create(
    'build: stale-artefact failure signature'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
