program LWPT.CompilerDriver.External.Test;

{$I Shared.inc}
{$J-}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.Command.Build,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.External,
  LWPT.Core,
  LWPT.ProcessRunner,
  TestingPascalLibrary;

const
  PROXY_COMPILER_ID = 'test-driver';
  PROXY_STATE_ROOT = 'build/tests/external-driver';

type
  TLWPTExternalCompilerDriverTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestProbeAndCompileProtocol;
    procedure TestProbeRefreshObservesMutation;
    procedure TestMalformedProtocolRetainsStderr;
    procedure TestExtraArtifactOutsideRootsIsRejected;
    procedure TestForcedRebuildIsRejectedExplicitly;
    procedure TestTimeoutKillsNonReadingProxy;
    procedure TestTimeoutDoesNotWaitForEscapedStdinHolder;
    procedure TestCaptureOverflowRetainsBoundedPrefixAndTerminates;
    procedure TestStreamedOutputCanBeDiscardedWithoutOverflow;
  end;

var
  StreamedOutputBytes: Integer = 0;

procedure CountStreamedOutput(const AData: RawByteString;
  const AStandardError: Boolean);
begin
  if not AStandardError then Inc(StreamedOutputBytes, Length(AData));
end;

function ReadStandardInput: string;
var
  Line: string;
begin
  Result := '';
  while not EOF(Input) do
  begin
    ReadLn(Line);
    Result := Result + Line + #10;
  end;
end;

{$IFDEF UNIX}
procedure RunEscapedStdinHolder(const APIDFile: string);
var
  ChildPID: TPid;
  Deadline: QWord;
  Lines: TStringList;
begin
  ChildPID := FpFork;
  if ChildPID < 0 then Halt(2);
  if ChildPID = 0 then
  begin
    if FpSetSid < 0 then Halt(3);
    Lines := TStringList.Create;
    try
      Lines.Text := IntToStr(FpGetPID);
      Lines.SaveToFile(APIDFile);
    finally
      Lines.Free;
    end;
    Sleep(30000);
    Halt(0);
  end;
  Deadline := GetTickCount64 + 1000;
  while (not FileExists(APIDFile)) and (GetTickCount64 < Deadline) do Sleep(1);
  if not FileExists(APIDFile) then Halt(4);
  Sleep(30000);
end;
{$ENDIF}

procedure TLWPTExternalCompilerDriverTests.
  TestCaptureOverflowRetainsBoundedPrefixAndTerminates;
const
  CAPTURE_LIMIT = 1024;
var
  ErrorMessage: string;
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
  StandardError, StandardOutput: string;
  StartedAt: QWord;
begin
  P := TProcess.Create(nil);
  Runner := nil;
  try
    P.Executable := ParamStr(0);
    P.Parameters.Add('flood-output');
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('flooding proxy');
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds := 5000;
    Options.MaximumStandardOutputBytes := CAPTURE_LIMIT;
    ErrorMessage := '';
    StartedAt := GetTickCount64;
    try
      Runner.Run('', Options, StandardOutput, StandardError);
    except
      on E: ELWPTProcessRunnerError do ErrorMessage := E.Message;
    end;
    Expect<Boolean>(Pos('standard output exceeded its 1024-byte capture limit',
      ErrorMessage) > 0).ToBe(True);
    Expect<Integer>(Length(StandardOutput)).ToBe(CAPTURE_LIMIT);
    Expect<Boolean>(GetTickCount64 - StartedAt < 5000).ToBe(True);
    Expect<Boolean>(P.Running).ToBe(False);
  finally
    Runner.Free;
    P.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.
  TestStreamedOutputCanBeDiscardedWithoutOverflow;
const
  CAPTURE_LIMIT = 1024;
var
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
  StandardError, StandardOutput: string;
begin
  P := TProcess.Create(nil);
  Runner := nil;
  try
    P.Executable := ParamStr(0);
    P.Parameters.Add('stream-output');
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('streaming proxy');
    Options.SeparateStandardError := True;
    Options.MaximumStandardOutputBytes := CAPTURE_LIMIT;
    Options.DiscardCapturedOutput := True;
    Options.OnOutputChunk := @CountStreamedOutput;
    StreamedOutputBytes := 0;
    Expect<Integer>(Runner.Run('', Options, StandardOutput,
      StandardError)).ToBe(0);
    Expect<string>(StandardOutput).ToBe('');
    Expect<string>(StandardError).ToBe('');
    Expect<Integer>(StreamedOutputBytes).ToBe(64 * 1024);
  finally
    Runner.Free;
    P.Free;
  end;
end;

procedure RunProxy(const AOperation: string);
var
  Artifact: TStringList;
  BuildResult: TLWPTBuildResult;
  Capabilities: TLWPTCompilerCapabilities;
  Request: TLWPTBuildRequest;
  State: TStringList;
  Mode, VersionIdentity: string;
begin
  if AOperation = 'probe' then
  begin
    ParseCompilerProbeRequest(ReadStandardInput);
    Mode := '';
    VersionIdentity := '1.0.0';
    State := TStringList.Create;
    try
      if FileExists(PROXY_STATE_ROOT + '/probe-mode') then
      begin
        State.LoadFromFile(PROXY_STATE_ROOT + '/probe-mode');
        Mode := Trim(State.Text);
      end;
      if FileExists(PROXY_STATE_ROOT + '/probe-version') then
      begin
        State.LoadFromFile(PROXY_STATE_ROOT + '/probe-version');
        VersionIdentity := Trim(State.Text);
      end;
    finally
      State.Free;
    end;
    WriteLn(ErrOutput, 'bounded proxy diagnostic');
    if Mode = 'malformed' then
    begin
      Write('not = [valid');
      Exit;
    end;
    Capabilities := DefaultCompilerCapabilities;
    if Mode = 'wrong-identity' then Capabilities.CompilerID := 'wrong'
    else Capabilities.CompilerID := PROXY_COMPILER_ID;
    Capabilities.VersionIdentity := VersionIdentity;
    SetLength(Capabilities.Targets, 1);
    Capabilities.Targets[0].OS := 'darwin';
    Capabilities.Targets[0].Architecture := 'aarch64';
    SetLength(Capabilities.OutputKinds, 1);
    Capabilities.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
    SetLength(Capabilities.Modes, 1);
    Capabilities.Modes[0] := BUILD_MODE_DEV;
    Write(SerializeCompilerCapabilities(Capabilities));
    Exit;
  end;
  if AOperation <> 'compile' then Halt(2);
  Request := ParseBuildRequest(ReadStandardInput);
  ForceDirectories(ExtractFileDir(Request.Outputs.Artifact));
  Artifact := TStringList.Create;
  try
    Artifact.Text := 'external compiler artifact';
    Artifact.SaveToFile(Request.Outputs.Artifact);
  finally
    Artifact.Free;
  end;
  BuildResult := DefaultBuildResult;
  BuildResult.Success := True;
  SetLength(BuildResult.Artifacts, 1);
  BuildResult.Artifacts[0].Kind := Request.OutputKind;
  BuildResult.Artifacts[0].Path := Request.Outputs.Artifact;
  WriteLn(ErrOutput, 'external compiler diagnostic');
  Write(SerializeBuildResult(BuildResult));
end;

procedure WriteState(const AName, AValue: string);
var
  State: TStringList;
begin
  ForceDirectories(PROXY_STATE_ROOT);
  State := TStringList.Create;
  try
    State.Text := AValue;
    State.SaveToFile(PROXY_STATE_ROOT + '/' + AName);
  finally
    State.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.TestProbeAndCompileProtocol;
var
  Arguments: LWPT.Core.TStringArray;
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TLWPTExternalCompilerDriver;
  Options: TLWPTCompilerInvocationOptions;
  ProcessRunner: TLWPTCompilerProcess;
  Request: TLWPTBuildRequest;
  BuildResult: TLWPTBuildResult;
  StandardOutput, StandardError: string;
  ExitCode: Integer;
begin
  WriteState('probe-mode', '');
  WriteState('probe-version', '1.0.0');
  Driver := TLWPTExternalCompilerDriver.Create(PROXY_COMPILER_ID,
    ParamStr(0), '', '^1.0.0');
  try
    Capabilities := Driver.ProbeCapabilities(Default(TLWPTTarget));
    Expect<string>(Capabilities.CompilerID).ToBe(PROXY_COMPILER_ID);
    Expect<string>(Capabilities.VersionIdentity).ToBe('1.0.0');
    Request := Driver.CreateBuildRequest('ignored.pas',
      ExpandFileName('build/tests/external-driver/artifact'));
    Options := BuildCompilerInvocationOptions('', False);
    Arguments := Driver.BuildArguments(Request, Options);
    ProcessRunner := TLWPTCompilerProcess.Create(Driver.ExecutableName);
    try
      ExitCode := ProcessRunner.Run(Arguments,
        Driver.BuildStandardInput(Request), Driver.SeparateStandardError,
        StandardOutput, StandardError);
    finally
      ProcessRunner.Free;
    end;
    BuildResult := Driver.NormalizeExecutionResult(Request, ExitCode,
      StandardOutput, StandardError);
    Expect<Boolean>(BuildResult.Success).ToBe(True);
    Expect<Boolean>(FileExists(Request.Outputs.Artifact)).ToBe(True);
    Expect<string>(Driver.DisplayOutput(StandardOutput, StandardError))
      .ToBe('external compiler diagnostic' + LineEnding);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.TestProbeRefreshObservesMutation;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TLWPTExternalCompilerDriver;
begin
  WriteState('probe-mode', '');
  WriteState('probe-version', '1.0.0');
  Driver := TLWPTExternalCompilerDriver.Create(UpperCase(PROXY_COMPILER_ID),
    ParamStr(0), '', '*');
  try
    Capabilities := Driver.ProbeCapabilities(Default(TLWPTTarget));
    Expect<string>(Capabilities.CompilerID).ToBe(PROXY_COMPILER_ID);
    Expect<string>(Capabilities.VersionIdentity).ToBe('1.0.0');
    WriteState('probe-version', '2.0.0');
    Capabilities := Driver.ProbeCapabilities(Default(TLWPTTarget), True);
    Expect<string>(Capabilities.VersionIdentity).ToBe('2.0.0');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.TestMalformedProtocolRetainsStderr;
var
  BuildResult: TLWPTBuildResult;
  Driver: TLWPTExternalCompilerDriver;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
begin
  Driver := TLWPTExternalCompilerDriver.Create(PROXY_COMPILER_ID,
    ParamStr(0), '', '*');
  try
    WriteState('probe-mode', 'malformed');
    Raised := False;
    try
      Driver.ProbeCapabilities(Default(TLWPTTarget), True);
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('invalid capability document', E.Message) > 0)
          and (Pos('bounded proxy diagnostic', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Request := DefaultBuildRequest;
    Request.Compiler.ID := PROXY_COMPILER_ID;
    Request.Compiler.VersionConstraint := '*';
    Request.Target.OS := 'darwin';
    Request.Target.Architecture := 'aarch64';
    Request.OutputKind := BUILD_OUTPUT_EXECUTABLE;
    Request.Mode := BUILD_MODE_DEV;
    Request.Inputs.EntryPoint := 'source.pas';
    SetLength(Request.Inputs.Sources, 1);
    Request.Inputs.Sources[0] := 'source.pas';
    Request.Outputs.Artifact := ExpandFileName(
      PROXY_STATE_ROOT + '/private/app');
    Request.Outputs.ExecutableDirectory := ExpandFileName(
      PROXY_STATE_ROOT + '/private');
    BuildResult := DefaultBuildResult;
    BuildResult.Success := True;
    Raised := False;
    try
      Driver.NormalizeExecutionResult(Request, 1,
        SerializeBuildResult(BuildResult), 'exit raw context');
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('disagrees with build result', E.Message) > 0)
          and (Pos('exit raw context', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Raised := False;
    try
      Driver.NormalizeExecutionResult(Request, 0, 'not = [valid',
        'build-result raw context');
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('invalid build-result document', E.Message) > 0)
          and (Pos('build-result raw context', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);

    SetLength(BuildResult.Artifacts, 1);
    BuildResult.Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
    BuildResult.Artifacts[0].Path := ExpandFileName(
      PROXY_STATE_ROOT + '/private/not-the-primary');
    Raised := False;
    try
      Driver.NormalizeExecutionResult(Request, 0,
        SerializeBuildResult(BuildResult), 'primary raw context');
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('did not report the requested primary artifact',
          E.Message) > 0) and (Pos('primary raw context', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    WriteState('probe-mode', '');
    Driver.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.TestExtraArtifactOutsideRootsIsRejected;
var
  BuildResult: TLWPTBuildResult;
  Driver: TLWPTExternalCompilerDriver;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
begin
  Driver := TLWPTExternalCompilerDriver.Create(PROXY_COMPILER_ID,
    ParamStr(0), '', '*');
  try
    Request := Driver.CreateBuildRequest('source.pas', ExpandFileName(
      PROXY_STATE_ROOT + '/private/app'));
    Request.Outputs.ExecutableDirectory := ExpandFileName(
      PROXY_STATE_ROOT + '/private');
    BuildResult := DefaultBuildResult;
    BuildResult.Success := True;
    SetLength(BuildResult.Artifacts, 2);
    BuildResult.Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
    BuildResult.Artifacts[0].Path := Request.Outputs.Artifact;
    BuildResult.Artifacts[1].Kind := 'debug';
    BuildResult.Artifacts[1].Path := ExpandFileName(
      PROXY_STATE_ROOT + '/outside.map');
    Raised := False;
    try
      Driver.NormalizeExecutionResult(Request, 0,
        SerializeBuildResult(BuildResult), 'artifact raw context');
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('outside the declared private output roots',
          E.Message) > 0) and (Pos('artifact raw context', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.TestForcedRebuildIsRejectedExplicitly;
var
  Driver: TLWPTExternalCompilerDriver;
  Options: TLWPTCompilerInvocationOptions;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
begin
  Driver := TLWPTExternalCompilerDriver.Create(PROXY_COMPILER_ID,
    ParamStr(0), '', '*');
  try
    Request := DefaultBuildRequest;
    Options := BuildCompilerInvocationOptions('', True);
    Raised := False;
    try
      Driver.BuildArguments(Request, Options);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('does not support forced rebuilds requested by --clean',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.TestTimeoutKillsNonReadingProxy;
var
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Raised: Boolean;
  Runner: TLWPTDuplexProcessRunner;
  StandardError, StandardOutput: string;
begin
  P := TProcess.Create(nil);
  Runner := nil;
  try
    P.Executable := ParamStr(0);
    P.Parameters.Add('sleep-noread');
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('non-reading proxy');
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds := 100;
    Raised := False;
    try
      Runner.Run(StringOfChar('x', 1024 * 1024), Options,
        StandardOutput, StandardError);
    except
      on E: ELWPTProcessRunnerTimeout do
        Raised := Pos('timed out after 100 ms', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Runner.Free;
    P.Free;
  end;
end;

procedure TLWPTExternalCompilerDriverTests.
  TestTimeoutDoesNotWaitForEscapedStdinHolder;
{$IFDEF UNIX}
const
  ESCAPED_PID_FILE = PROXY_STATE_ROOT + '/escaped-stdin.pid';
var
  EscapedPID: TPid;
  Lines: TStringList;
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Raised: Boolean;
  Runner: TLWPTDuplexProcessRunner;
  StandardError, StandardOutput: string;
  StartedAt: QWord;
begin
  ForceDirectories(PROXY_STATE_ROOT);
  if FileExists(ESCAPED_PID_FILE) then DeleteFile(ESCAPED_PID_FILE);
  EscapedPID := 0;
  P := TProcess.Create(nil);
  Runner := nil;
  try
    P.Executable := ParamStr(0);
    P.Parameters.Add('escape-stdin');
    P.Parameters.Add(ExpandFileName(ESCAPED_PID_FILE));
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('escaped stdin proxy');
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds := 500;
    Raised := False;
    StartedAt := GetTickCount64;
    try
      Runner.Run(StringOfChar('x', 1024 * 1024), Options,
        StandardOutput, StandardError);
    except
      on E: ELWPTProcessRunnerTimeout do
        Raised := Pos('timed out after 500 ms', E.Message) > 0;
    end;
    Lines := TStringList.Create;
    try
      if FileExists(ESCAPED_PID_FILE) then
      begin
        Lines.LoadFromFile(ESCAPED_PID_FILE);
        EscapedPID := StrToIntDef(Trim(Lines.Text), 0);
      end;
    finally
      Lines.Free;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    { The retained read end must not turn the 500 ms operation deadline into
      an unbounded writer join. Leave room for process-tree and writer cleanup
      while pinning the complete failure path below three seconds. }
    Expect<Boolean>(GetTickCount64 - StartedAt < 3000).ToBe(True);
    Expect<Boolean>(P.Running).ToBe(False);
    Expect<Boolean>(EscapedPID > 0).ToBe(True);
    if EscapedPID > 0 then
      Expect<Boolean>(FpKill(EscapedPID, 0) = 0).ToBe(True);
  finally
    if EscapedPID > 0 then FpKill(EscapedPID, SIGKILL);
    Runner.Free;
    P.Free;
  end;
end;
{$ELSE}
begin
  { Windows Job Objects do not permit this Unix setsid escape pattern. The
    Windows writer uses CancelSynchronousIo for the equivalent retained pipe. }
  Expect<Boolean>(True).ToBe(True);
end;
{$ENDIF}

procedure TLWPTExternalCompilerDriverTests.SetupTests;
begin
  Test('short-lived probe and compile use canonical TOML and split stderr',
    TestProbeAndCompileProtocol);
  Test('refresh observes a capability mutation',
    TestProbeRefreshObservesMutation);
  Test('malformed protocol failures retain bounded stderr context',
    TestMalformedProtocolRetainsStderr);
  Test('an extra artifact outside private roots is rejected',
    TestExtraArtifactOutsideRootsIsRejected);
  Test('--clean fails explicitly for the external protocol',
    TestForcedRebuildIsRejectedExplicitly);
  Test('timeout kills a sleeping proxy that never reads stdin',
    TestTimeoutKillsNonReadingProxy);
  Test('timeout does not wait for an escaped descendant retaining stdin',
    TestTimeoutDoesNotWaitForEscapedStdinHolder);
  Test('capture overflow retains a bounded prefix and terminates the proxy',
    TestCaptureOverflowRetainsBoundedPrefixAndTerminates);
  Test('stream callback drains output without retaining or overflowing',
    TestStreamedOutputCanBeDiscardedWithoutOverflow);
end;

begin
  if (ParamCount = 1) and (ParamStr(1) = 'sleep-noread') then
  begin
    Sleep(30000);
    Halt(0);
  end;
  if (ParamCount = 1) and (ParamStr(1) = 'flood-output') then
  begin
    Write(StringOfChar('x', 64 * 1024));
    Flush(Output);
    Sleep(30000);
    Halt(0);
  end;
  if (ParamCount = 1) and (ParamStr(1) = 'stream-output') then
  begin
    Write(StringOfChar('x', 64 * 1024));
    Flush(Output);
    Halt(0);
  end;
  {$IFDEF UNIX}
  if (ParamCount = 2) and (ParamStr(1) = 'escape-stdin') then
  begin
    RunEscapedStdinHolder(ParamStr(2));
    Halt(0);
  end;
  {$ENDIF}
  if (ParamCount = 1)
     and ((ParamStr(1) = 'probe') or (ParamStr(1) = 'compile')) then
  begin
    RunProxy(ParamStr(1));
    Halt(0);
  end;
  TestRunnerProgram.AddSuite(TLWPTExternalCompilerDriverTests.Create(
    'external compiler driver'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
