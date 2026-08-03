program LWPT.CompilerDriver.FPC.Test;

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
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  LWPT.BuildRequest,
  LWPT.Command.Common,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.FPC,
  LWPT.Core,
  Platform,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  IsolatedCompilerDriverOption = '--' + PROGRAM_NAME
    + '-isolated-compiler-driver';
  IsolatedDefaultTargetCase = 'default-target';
  IsolatedExplicitProcessorCase = 'explicit-processor';
  IsolatedUnitPathsCase = 'unit-paths';
  ProbeTimeoutGrandchildOption = '--' + PROGRAM_NAME
    + '-probe-timeout-grandchild';
  ProbeTimeoutProxyName = PROGRAM_NAME + '-probe-timeout-proxy';
  ProbeTimeoutSleepMilliseconds = 30000;
  TestProbeTimeoutMilliseconds = 1000;
  TestProbeCompletionTimeoutSeconds = 10;
  ProbeTimeoutProxyReleaseMilliseconds = 5000;

type
  TMockFPCCompilerDriver = class(TLWPTFPCCompilerDriver)
  private
    FProbeCount: Integer;
    FProbeExitCode: Integer;
    FProbeOutput: string;
    FBareProbeOutput: string;
    FDispatchedProbeOutput: string;
    FLastArguments: LWPT.Core.TStringArray;
  protected
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AOutput: string): Integer; override;
  public
    property BareProbeOutput: string read FBareProbeOutput
      write FBareProbeOutput;
    property DispatchedProbeOutput: string read FDispatchedProbeOutput
      write FDispatchedProbeOutput;
    property LastArguments: LWPT.Core.TStringArray read FLastArguments;
    property ProbeCount: Integer read FProbeCount;
    property ProbeExitCode: Integer read FProbeExitCode
      write FProbeExitCode;
    property ProbeOutput: string read FProbeOutput write FProbeOutput;
  end;

  TTimeoutFPCCompilerDriver = class(TLWPTFPCCompilerDriver)
  protected
    function ProbeTimeoutMilliseconds: QWord; override;
  end;

  TLWPTFPCCompilerDriverTests = class(TTestSuite)
  private
    function FixtureRequest(const ASource, AArtifact: string):
      TLWPTBuildRequest;
    procedure ExpectArguments(const AActual: LWPT.Core.TStringArray;
      const AExpected: array of string);
    function ArgumentsContain(const AArguments: LWPT.Core.TStringArray;
      const AExpected: string): Boolean;
    function RunCompiler(const ADriver: TLWPTCompilerDriver;
      const ARequest: TLWPTBuildRequest; out AOutput: string): Integer;
    procedure RunIsolatedCase(const ACase: string);
    procedure AssertDefaultBuildRequestUsesBareProbeTarget;
    procedure AssertExplicitProcessorOverrideStillDispatches;
    procedure AssertBuildArgumentsPreserveTestCompileFlagSet;
  public
    procedure SetupTests; override;
    procedure TestProbeCachesPerTargetAndRefreshesOnDemand;
    procedure TestProbeDispatchesOperatingSystemAndMapsWindows;
    procedure TestBareProbeSatisfactionLeavesDispatchOut;
    procedure TestDefaultBuildRequestUsesBareProbeTarget;
    procedure TestExplicitProcessorOverrideStillDispatches;
    procedure TestProbeFailureNamesCompilerAndTargetRequirement;
    procedure TestProbeTimeoutTerminatesProcessTree;
    procedure TestProbeRejectsUnexpectedTargetTuple;
    procedure TestCapabilitiesAreDefensiveAndDoNotAdvertiseUnits;
    procedure TestBuildArgumentsPreserveBuildFlagSet;
    procedure TestExtraArgumentValidation;
    procedure TestBuildArgumentsPreserveTestCompileFlagSet;
    procedure TestIncompatibleVersionNamesCompilerAndRequirement;
    procedure TestFailureClassification;
    procedure TestFailingCompileProducesStructuredErrorDiagnostic;
    procedure TestSuccessfulCompileProducesNoErrorDiagnostics;
    procedure TestDiagnosticGrammarRejectsSeverityFalsePositives;
    procedure TestWindowsExecutableArtifactPathIsNormalized;
    procedure TestNilDriverBuildRequestIsRejected;
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

procedure DeleteProbeTimeoutScratch(const AScratch, AProxyPath: string);
{$IFDEF MSWINDOWS}
var
  StartedAt: QWord;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  { TerminateProcess has completed before the driver returns, but Windows can
    retain the executable image briefly while the process object is reaped.
    Retry only this known proxy instead of weakening RecursiveDelete for every
    test fixture. }
  StartedAt := GetTickCount64;
  while FileExists(AProxyPath) and not SysUtils.DeleteFile(AProxyPath) do
  begin
    if GetTickCount64 - StartedAt >= ProbeTimeoutProxyReleaseMilliseconds then
      raise Exception.CreateFmt(
        'probe-timeout proxy remained locked after %d ms: %s',
        [ProbeTimeoutProxyReleaseMilliseconds, AProxyPath]);
    Sleep(10);
  end;
  {$ENDIF}
  RecursiveDelete(AScratch);
end;

function RunProbeTimeoutGrandchild: Integer;
begin
  {$IFDEF UNIX}
  FpSignal(SIGTERM, SignalHandler(SIG_IGN));
  {$ENDIF}
  WriteTextFile(ParamStr(2), IntToStr(GetProcessID));
  Sleep(ProbeTimeoutSleepMilliseconds);
  Result := 0;
end;

function RunProbeTimeoutProxy: Integer;
var
  Grandchild: TProcess;
  GrandchildPIDPath: string;
begin
  {$IFDEF UNIX}
  FpSignal(SIGTERM, SignalHandler(SIG_IGN));
  {$ENDIF}
  GrandchildPIDPath := ExtractFileDir(ParamStr(0)) + '/grandchild-pid';
  Grandchild := TProcess.Create(nil);
  try
    Grandchild.Executable := ExpandFileName(ParamStr(0));
    Grandchild.Parameters.Add(ProbeTimeoutGrandchildOption);
    Grandchild.Parameters.Add(GrandchildPIDPath);
    Grandchild.Execute;
    while not FileExists(GrandchildPIDPath) and Grandchild.Running do
      Sleep(ProcessPollMilliseconds);
    Sleep(ProbeTimeoutSleepMilliseconds);
  finally
    Grandchild.Free;
  end;
  Result := 0;
end;

function FixtureFPCOperatingSystem(const ATarget: TLWPTTarget): string;
begin
  Result := ATarget.OS;
  if ATarget.OS <> 'windows' then Exit;
  if (ATarget.Architecture = 'x86')
     or (ATarget.Architecture = 'i386') then
    Result := 'win32'
  else
    Result := 'win64';
end;

function FixtureFPCProcessor(const ATarget: TLWPTTarget): string;
begin
  Result := ATarget.Architecture;
  if Result = 'x86' then Result := 'i386';
end;

function FixtureProbeOutput(const AVersion: string;
  const ATarget: TLWPTTarget): string;
begin
  Result := AVersion + ' ' + FixtureFPCOperatingSystem(ATarget) + ' '
    + FixtureFPCProcessor(ATarget);
end;

function FixtureArtifactPath(const ARequest: TLWPTBuildRequest): string;
begin
  Result := ARequest.Outputs.Artifact;
  if (ARequest.Target.OS = 'windows') or (ARequest.Target.OS = 'win32')
     or (ARequest.Target.OS = 'win64') then
    if ExtractFileExt(Result) = '' then Result := Result + '.exe';
end;

function TMockFPCCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AOutput: string): Integer;
begin
  Inc(FProbeCount);
  FLastArguments := Copy(AArguments, 0, Length(AArguments));
  if (Length(AArguments) > 3) and (FDispatchedProbeOutput <> '') then
    AOutput := FDispatchedProbeOutput
  else if (Length(AArguments) = 3) and (FBareProbeOutput <> '') then
    AOutput := FBareProbeOutput
  else
    AOutput := FProbeOutput;
  Result := FProbeExitCode;
end;

function TTimeoutFPCCompilerDriver.ProbeTimeoutMilliseconds: QWord;
begin
  Result := TestProbeTimeoutMilliseconds;
end;

function TLWPTFPCCompilerDriverTests.ArgumentsContain(
  const AArguments: LWPT.Core.TStringArray;
  const AExpected: string): Boolean;
var
  ArgumentIndex: Integer;
begin
  for ArgumentIndex := 0 to High(AArguments) do
    if AArguments[ArgumentIndex] = AExpected then Exit(True);
  Result := False;
end;

function TLWPTFPCCompilerDriverTests.FixtureRequest(
  const ASource, AArtifact: string): TLWPTBuildRequest;
begin
  Result := DefaultBuildRequest;
  Result.Compiler.ID := FPC_COMPILER_ID;
  Result.Compiler.VersionConstraint := '*';
  Result.Target.OS := GetBuildOS;
  Result.Target.Architecture := GetBuildArch;
  Result.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.Mode := BUILD_MODE_DEV;
  Result.Inputs.EntryPoint := ASource;
  SetLength(Result.Inputs.Sources, 1);
  Result.Inputs.Sources[0] := ASource;
  Result.Outputs.Artifact := AArtifact;
  Result.Outputs.ExecutableDirectory := ExtractFileDir(AArtifact);
  Result.Outputs.UnitDirectory := ExtractFileDir(AArtifact) + '/units';
  Result.Outputs.ObjectDirectory := Result.Outputs.UnitDirectory;
end;

procedure TLWPTFPCCompilerDriverTests.ExpectArguments(
  const AActual: LWPT.Core.TStringArray;
  const AExpected: array of string);
var
  ArgumentIndex: Integer;
begin
  Expect<Integer>(Length(AActual)).ToBe(Length(AExpected));
  for ArgumentIndex := 0 to High(AExpected) do
    Expect<string>(AActual[ArgumentIndex]).ToBe(AExpected[ArgumentIndex]);
end;

function TLWPTFPCCompilerDriverTests.RunCompiler(
  const ADriver: TLWPTCompilerDriver; const ARequest: TLWPTBuildRequest;
  out AOutput: string): Integer;
var
  Arguments: LWPT.Core.TStringArray;
  Buffer: array[0..PROCESS_OUTPUT_BUFFER_SIZE - 1] of Byte;
  BytesRead, ArgumentIndex: Integer;
  CompilerProcess: TProcess;
begin
  Arguments := ADriver.BuildArguments(ARequest,
    PascalSourceCompilerInvocationOptions(''));
  AOutput := '';
  CompilerProcess := TProcess.Create(nil);
  try
    CompilerProcess.Executable := ADriver.ExecutableName;
    for ArgumentIndex := 0 to High(Arguments) do
      CompilerProcess.Parameters.Add(Arguments[ArgumentIndex]);
    CompilerProcess.Options := [poUsePipes, poStderrToOutPut];
    CompilerProcess.Execute;
    repeat
      BytesRead := CompilerProcess.Output.Read(Buffer[0], SizeOf(Buffer));
      if BytesRead > 0 then
        AppendRawBytes(AOutput, Buffer[0], BytesRead);
    until BytesRead <= 0;
    CompilerProcess.WaitOnExit;
    Result := NormalisedExitCode(CompilerProcess);
  finally
    CompilerProcess.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.RunIsolatedCase(const ACase: string);
var
  Run: TLwptResult;
begin
  SetLwptBinaryPath(ExpandFileName(ParamStr(0)));
  Run := RunLwpt([IsolatedCompilerDriverOption, ACase], '',
    ['FPC_TARGET_OS=', 'FPC_TARGET_CPU=',
      PROJECT_NAME + '_FPC_UNIT_PATHS=',
      PROJECT_NAME + '_WORKER_LEASE_TOKEN=']);
  if Run.ExitCode <> 0 then
  begin
    WriteLn('ISOLATED COMPILER-DRIVER TEST FAILURE: ', ACase);
    if Run.Stdout <> '' then WriteLn(Run.Stdout);
    if Run.Stderr <> '' then WriteLn(Run.Stderr);
  end;
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TLWPTFPCCompilerDriverTests.
  TestProbeCachesPerTargetAndRefreshesOnDemand;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockFPCCompilerDriver;
  Target: TLWPTTarget;
begin
  Target := Default(TLWPTTarget);
  Target.OS := GetBuildOS;
  Target.Architecture := GetBuildArch;
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := FixtureProbeOutput('3.2.2', Target);
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<string>(Capabilities.VersionIdentity).ToBe('3.2.2');
    Capabilities.Targets[0].Architecture := 'mutated';
    Capabilities.OutputKinds[0] := BUILD_OUTPUT_UNIT;
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
    Expect<string>(Capabilities.Targets[0].Architecture).ToBe(
      Target.Architecture);
    Expect<string>(Capabilities.OutputKinds[0]).ToBe(BUILD_OUTPUT_EXECUTABLE);
    Driver.ProbeOutput := FixtureProbeOutput('3.3.1', Target);
    Capabilities := Driver.ProbeCapabilities(Target, True);
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
    Expect<string>(Capabilities.VersionIdentity).ToBe('3.3.1');
    Expect<string>(Capabilities.Targets[0].Architecture).ToBe(
      Target.Architecture);
    Expect<string>(Driver.LastArguments[
      High(Driver.LastArguments) - 2]).ToBe('-iV');
    Expect<string>(Driver.LastArguments[
      High(Driver.LastArguments) - 1]).ToBe('-iTO');
    Expect<string>(Driver.LastArguments[
      High(Driver.LastArguments)]).ToBe('-iTP');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestProbeDispatchesOperatingSystemAndMapsWindows;
var
  Arguments: LWPT.Core.TStringArray;
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockFPCCompilerDriver;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
  Target: TLWPTTarget;
begin
  Target := Default(TLWPTTarget);
  Target.OS := 'windows';
  Target.Architecture := 'x86_64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.BareProbeOutput := '3.2.2 win32 i386';
    Driver.DispatchedProbeOutput := '3.2.2 win64 x86_64';
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<string>(Capabilities.Targets[0].OS).ToBe('windows');
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Px86_64'))
      .ToBe(True);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Twin64'))
      .ToBe(True);
    Request := FixtureRequest('source/example.pas', 'build/example');
    Request.Target := Target;
    InvocationOptions := BuildCompilerInvocationOptions('', False);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Px86_64')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Twin64')).ToBe(True);
    Expect<Integer>(Driver.ProbeCount).ToBe(2);

    Target.OS := 'windows';
    Target.Architecture := 'x86';
    Driver.BareProbeOutput := '3.2.2 linux x86_64';
    Driver.DispatchedProbeOutput := '3.2.2 win32 i386';
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Pi386'))
      .ToBe(True);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Twin32'))
      .ToBe(True);

    Target.Architecture := 'arm';
    Driver.BareProbeOutput := '3.2.2 linux x86_64';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('Windows target architecture "arm"', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);

  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestBareProbeSatisfactionLeavesDispatchOut;
var
  Arguments: LWPT.Core.TStringArray;
  Driver: TMockFPCCompilerDriver;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
  Target: TLWPTTarget;
begin
  Target := Default(TLWPTTarget);
  Target.OS := 'windows';
  Target.Architecture := 'x86_64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.BareProbeOutput := '3.2.2 win64 x86_64';
    Driver.ProbeCapabilities(Target);
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Px86_64'))
      .ToBe(False);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Twin64'))
      .ToBe(False);
    Request := FixtureRequest('source/example.pas', 'build/example');
    Request.Target := Target;
    InvocationOptions := BuildCompilerInvocationOptions('', False);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Px86_64')).ToBe(False);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Twin64')).ToBe(False);
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestDefaultBuildRequestUsesBareProbeTarget;
begin
  RunIsolatedCase(IsolatedDefaultTargetCase);
end;

procedure TLWPTFPCCompilerDriverTests.
  AssertDefaultBuildRequestUsesBareProbeTarget;
var
  Arguments: LWPT.Core.TStringArray;
  Driver: TMockFPCCompilerDriver;
  ExpectedOperatingSystem, ExpectedProcessor: string;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
begin
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    if (GetBuildOS = 'windows') and ((GetBuildArch = 'x86')
       or (GetBuildArch = 'i386')) then
    begin
      ExpectedOperatingSystem := 'linux';
      ExpectedProcessor := 'x86_64';
    end
    else
    begin
      ExpectedOperatingSystem := 'win32';
      ExpectedProcessor := 'i386';
    end;
    Driver.BareProbeOutput := '3.2.2 ' + ExpectedOperatingSystem + ' '
      + ExpectedProcessor;
    Request := CreateFPCBuildRequest('source/example.pas',
      'build/example', Driver);
    Expect<Boolean>((Request.Target.OS <> GetBuildOS)
      or (Request.Target.Architecture <> GetBuildArch)).ToBe(True);
    Expect<string>(Request.Target.OS).ToBe(ExpectedOperatingSystem);
    Expect<string>(Request.Target.Architecture).ToBe(ExpectedProcessor);
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
    InvocationOptions := BuildCompilerInvocationOptions('', False);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    Expect<Boolean>(ArgumentsContain(Arguments,
      '-P' + Request.Target.Architecture)).ToBe(False);
    Expect<Boolean>(ArgumentsContain(Arguments,
      '-T' + Request.Target.OS)).ToBe(False);
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestExplicitProcessorOverrideStillDispatches;
begin
  RunIsolatedCase(IsolatedExplicitProcessorCase);
end;

procedure TLWPTFPCCompilerDriverTests.
  AssertExplicitProcessorOverrideStillDispatches;
var
  Arguments: LWPT.Core.TStringArray;
  Driver: TMockFPCCompilerDriver;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
begin
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.BareProbeOutput := '3.2.2 linux x86_64';
    Driver.DispatchedProbeOutput := '3.2.2 linux aarch64';
    { The env-to-request wiring is one GetEnvironmentVariable line,
      integration-covered by BuildEntries with real subprocess
      environment; faking process env here is not portable (on Linux
      the RTL reads its startup snapshot, so setenv is invisible).
      Apply the override to the request directly -- the exact value an
      explicit FPC_TARGET_CPU produces -- and assert the driver
      validates and dispatches it. }
    Request := CreateFPCBuildRequest('source/example.pas',
      'build/example', Driver);
    Expect<string>(Request.Target.OS).ToBe('linux');
    Expect<string>(Request.Target.Architecture).ToBe('x86_64');
    Request.Target.Architecture := 'aarch64';
    InvocationOptions := BuildCompilerInvocationOptions('', False);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Paarch64')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Tlinux')).ToBe(True);
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.TestProbeTimeoutTerminatesProcessTree;
var
  Driver: TTimeoutFPCCompilerDriver;
  ElapsedMilliseconds, StartedAt: QWord;
  GrandchildPID: Integer;
  ErrorMessage, GrandchildPIDPath, ProxyPath, Scratch: string;
  Raised: Boolean;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-driver-probe-timeout');
  GrandchildPIDPath := Scratch + '/grandchild-pid';
  ProxyPath := Scratch + '/' + ProbeTimeoutProxyName
    + ExtractFileExt(ParamStr(0));
  RecursiveDelete(Scratch);
  ForceDirectories(Scratch);
  if not CopyFileContent(ExpandFileName(ParamStr(0)), ProxyPath) then
    raise Exception.Create('could not create probe-timeout proxy');
  {$IFDEF UNIX}
  if FpChmod(PChar(ProxyPath), &755) <> 0 then RaiseLastOSError;
  {$ENDIF}
  Driver := TTimeoutFPCCompilerDriver.Create(ProxyPath);
  GrandchildPID := 0;
  try
    Raised := False;
    ErrorMessage := '';
    StartedAt := GetTickCount64;
    try
      Driver.DefaultTarget;
    except
      on E: ELWPTCompilerDriverError do
      begin
        ErrorMessage := E.Message;
        Raised := (Pos('failed (exit 124)', E.Message) > 0)
          and (Pos('probe timed out after '
            + IntToStr(TestProbeTimeoutMilliseconds) + ' ms', E.Message) > 0);
      end;
    end;
    ElapsedMilliseconds := GetTickCount64 - StartedAt;
    if not Raised then
      WriteLn('PROBE-TIMEOUT TEST FAILURE: elapsed=', ElapsedMilliseconds,
        ' error="', ErrorMessage, '" proxy="', ProxyPath, '" pidFile=',
        FileExists(GrandchildPIDPath));
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Boolean>(ElapsedMilliseconds
      < QWord(TestProbeCompletionTimeoutSeconds * 1000)).ToBe(True);
    Expect<Boolean>(FileExists(GrandchildPIDPath)).ToBe(True);
    if FileExists(GrandchildPIDPath) then
    begin
      GrandchildPID := StrToInt(Trim(ReadBinaryFile(GrandchildPIDPath)));
      Expect<Boolean>(ProcessIsRunning(GrandchildPID)).ToBe(False);
    end;
  finally
    Driver.Free;
    TerminateTestProcess(GrandchildPID);
    DeleteProbeTimeoutScratch(Scratch, ProxyPath);
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestProbeFailureNamesCompilerAndTargetRequirement;
var
  Driver: TMockFPCCompilerDriver;
  Raised: Boolean;
  Target: TLWPTTarget;
begin
  Target := Default(TLWPTTarget);
  Target.OS := GetBuildOS;
  if GetBuildArch = 'aarch64' then
    Target.Architecture := 'x86_64'
  else
    Target.Architecture := 'aarch64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeExitCode := 1;
    Driver.ProbeOutput := 'cross compiler is unavailable';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
      begin
        Raised := (Pos('compiler "' + FPC_COMPILER_ID + '"', E.Message) > 0)
          and (Pos(Target.OS + '/' + Target.Architecture, E.Message) > 0)
          and (Pos('cross compiler is unavailable', E.Message) > 0);
      end;
    end;
    if not Raised then Fail('probe failure did not name its requirement');
    Expect<string>(Driver.LastArguments[0]).ToBe(
      '-P' + Target.Architecture);
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do;
    end;
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.TestProbeRejectsUnexpectedTargetTuple;
var
  Driver: TMockFPCCompilerDriver;
  Raised: Boolean;
  Target: TLWPTTarget;
begin
  Target := Default(TLWPTTarget);
  Target.OS := 'windows';
  Target.Architecture := 'x86_64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.BareProbeOutput := '3.2.2 win32 i386';
    Driver.DispatchedProbeOutput := '3.2.2 win32 i386';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('compiler "' + FPC_COMPILER_ID + '"', E.Message) > 0)
          and (Pos(Target.OS + '/' + Target.Architecture, E.Message) > 0)
          and (Pos('returned target "win32/i386"', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestCapabilitiesAreDefensiveAndDoNotAdvertiseUnits;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockFPCCompilerDriver;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
  Target: TLWPTTarget;
begin
  Target := Default(TLWPTTarget);
  Target.OS := GetBuildOS;
  Target.Architecture := GetBuildArch;
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := FixtureProbeOutput('3.2.2', Target);
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<Integer>(Length(Capabilities.OutputKinds)).ToBe(2);
    Expect<Boolean>(ArgumentsContain(Capabilities.OutputKinds,
      BUILD_OUTPUT_UNIT)).ToBe(False);
    Request := FixtureRequest('source/example.pas', 'build/example');
    Request.OutputKind := BUILD_OUTPUT_UNIT;
    Raised := False;
    try
      EnsureBuildRequestCompatible(Request, Capabilities);
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('output "unit"', E.Message) > 0)
          and (Pos('output kind is not supported', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);

  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.TestBuildArgumentsPreserveBuildFlagSet;
var
  Arguments: LWPT.Core.TStringArray;
  BootstrapSource, CrossProcessor: string;
  Driver: TMockFPCCompilerDriver;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
  NativeTarget: TLWPTTarget;
begin
  Request := FixtureRequest('source/app.pas', 'session/bin/app');
  NativeTarget := Request.Target;
  if GetBuildArch = 'aarch64' then CrossProcessor := 'x86_64'
  else CrossProcessor := 'aarch64';
  Request.Target.Architecture := CrossProcessor;
  Request.Mode := BUILD_MODE_RELEASE;
  SetLength(Request.Inputs.Defines, 1);
  Request.Inputs.Defines[0] := 'PRODUCTION';
  SetLength(Request.Inputs.UnitPaths, 1);
  Request.Inputs.UnitPaths[0] := 'source';
  SetLength(Request.Inputs.IncludePaths, 1);
  Request.Inputs.IncludePaths[0] := 'include';
  SetLength(Request.Inputs.ExtraArguments, 2);
  Request.Inputs.ExtraArguments[0] := '-dISSUE95_FLAG';
  Request.Inputs.ExtraArguments[1] := '-k-ld_classic';
  InvocationOptions := BuildCompilerInvocationOptions('lwpt.cfg', False);
  Driver := TMockFPCCompilerDriver.Create('fpc-under-test');
  try
    Driver.BareProbeOutput := FixtureProbeOutput('3.2.2', NativeTarget);
    Driver.DispatchedProbeOutput := FixtureProbeOutput('3.2.2',
      Request.Target);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    ExpectArguments(Arguments, ['-P' + CrossProcessor,
      '-T' + FixtureFPCOperatingSystem(Request.Target),
      '-FEsession/bin', '-FUsession/bin/units',
      '@lwpt.cfg', '-Fusource', '-Fiinclude',
      '-Sh', '-O4', '-dPRODUCTION', '-Xs', '-CX', '-XX', '-B',
      '-dISSUE95_FLAG', '-k-ld_classic',
      '-osession/bin/app', 'source/app.pas']);

    Request.Target.Architecture := GetBuildArch;
    Request.Mode := BUILD_MODE_DEV;
    SetLength(Request.Inputs.Defines, 0);
    InvocationOptions := BuildCompilerInvocationOptions('lwpt.cfg', True);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    ExpectArguments(Arguments, ['-FEsession/bin', '-FUsession/bin/units',
      '@lwpt.cfg', '-Fusource', '-Fiinclude', '-Sh', '-O-', '-gw',
      '-godwarfsets', '-gl', '-Ct', '-Cr', '-Sa', '-B',
      '-dISSUE95_FLAG', '-k-ld_classic', '-osession/bin/app',
      'source/app.pas']);
    BootstrapSource := ReadBinaryFile('scripts/bootstrap.pas');
    Expect<Boolean>(Pos('''-O-''', BootstrapSource) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('''-gw''', BootstrapSource) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('''-godwarfsets''', BootstrapSource) > 0).ToBe(True);
    Expect<Boolean>(Pos('''-gl''', BootstrapSource) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('''-Ct''', BootstrapSource) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('''-Cr''', BootstrapSource) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('''-Sa''', BootstrapSource) > 0)
      .ToBe(True);

    Request.Mode := BUILD_MODE_RELEASE;
    InvocationOptions := PascalSourceCompilerInvocationOptions('');
    InvocationOptions.RebuildPolicy := crpForce;
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    Expect<Boolean>(ArgumentsContain(Arguments, '-B')).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.TestExtraArgumentValidation;
const
  ManagedOverrideArguments: array[0..7] of string = (
    '-FUshared-output',
    '-Vunprobed',
    '-CaEABI',
    '-FCalternate-rc',
    '-FDalternate-tools',
    '-FLalternate-linker',
    '-FRalternate-resource-linker',
    '-XPalternate-prefix-'
  );
var
  Arguments: LWPT.Core.TStringArray;
  ArgumentIndex: Integer;
  Driver: TMockFPCCompilerDriver;
  ErrorMessage: string;
  Request: TLWPTBuildRequest;
begin
  Request := FixtureRequest('source/app.pas', 'session/bin/app');
  Driver := TMockFPCCompilerDriver.Create('fpc-under-test');
  try
    Driver.ProbeOutput := FixtureProbeOutput('3.2.2', Request.Target);
    SetLength(Request.Inputs.ExtraArguments, 1);
    Request.Inputs.ExtraArguments[0] := '@project.fpc.cfg';
    ErrorMessage := '';
    try
      Arguments := Driver.BuildArguments(Request,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        ErrorMessage := E.Message;
    end;
    Expect<string>(ErrorMessage).ToBe(
      'compiler "fpc" extra argument 0 must be an option beginning with "-"; '
      + 'positional and response-file arguments are not allowed');

    for ArgumentIndex := Low(ManagedOverrideArguments) to
      High(ManagedOverrideArguments) do
    begin
      Request.Inputs.ExtraArguments[0] :=
        ManagedOverrideArguments[ArgumentIndex];
      ErrorMessage := '';
      try
        Arguments := Driver.BuildArguments(Request,
          BuildCompilerInvocationOptions('', False));
      except
        on E: ELWPTCompilerDriverError do
          ErrorMessage := E.Message;
      end;
      Expect<string>(ErrorMessage).ToBe(
        'compiler "fpc" extra argument "'
        + ManagedOverrideArguments[ArgumentIndex] + '" is managed by LWPT '
        + 'and cannot override the selected compiler, requested target, or '
        + 'private compiler outputs');
    end;
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestBuildArgumentsPreserveTestCompileFlagSet;
begin
  RunIsolatedCase(IsolatedUnitPathsCase);
end;

procedure TLWPTFPCCompilerDriverTests.
  AssertBuildArgumentsPreserveTestCompileFlagSet;
var
  Arguments: LWPT.Core.TStringArray;
  ConfigurationPath, Scratch: string;
  Driver: TMockFPCCompilerDriver;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-driver-arguments');
  RecursiveDelete(Scratch);
  ForceDirectories(Scratch);
  ConfigurationPath := Scratch + '/test.cfg';
  WriteTextFile(ConfigurationPath, '# comment' + LineEnding
    + '-Fuconfig/unit' + LineEnding + '-Ficonfig/include' + LineEnding);
  Request := FixtureRequest('source/example.pas', 'session/example');
  SetLength(Request.Inputs.UnitPaths, 1);
  Request.Inputs.UnitPaths[0] := 'source';
  SetLength(Request.Inputs.IncludePaths, 1);
  Request.Inputs.IncludePaths[0] := 'source';
  InvocationOptions := PascalSourceCompilerInvocationOptions(
    ConfigurationPath);
  Driver := TMockFPCCompilerDriver.Create('fpc-under-test');
  try
    Driver.ProbeOutput := FixtureProbeOutput('3.2.2', Request.Target);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    ExpectArguments(Arguments, ['-Sh', '-FEsession',
      '-FUsession/units', '-Fuconfig/unit', '-Ficonfig/include', '-Fusource',
      '-Fisource', '-osession/example', 'source/example.pas']);
  finally
    Driver.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestIncompatibleVersionNamesCompilerAndRequirement;
var
  Capabilities: TLWPTCompilerCapabilities;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
begin
  Request := FixtureRequest('source/example.pas', 'build/example');
  Request.Compiler.VersionConstraint := '^4.0.0';
  Capabilities := DefaultCompilerCapabilities;
  Capabilities.CompilerID := FPC_COMPILER_ID;
  Capabilities.VersionIdentity := '3.2.2';
  SetLength(Capabilities.Targets, 1);
  Capabilities.Targets[0] := Request.Target;
  SetLength(Capabilities.OutputKinds, 1);
  Capabilities.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
  SetLength(Capabilities.Modes, 1);
  Capabilities.Modes[0] := BUILD_MODE_DEV;
  Raised := False;
  try
    EnsureBuildRequestCompatible(Request, Capabilities);
  except
    on E: ELWPTCompilerDriverError do
      Raised := (Pos('compiler "' + FPC_COMPILER_ID + '"', E.Message) > 0)
        and (Pos('version "^4.0.0"', E.Message) > 0)
        and (Pos('compiler version constraint is not satisfied',
          E.Message) > 0);
  end;
  if not Raised then
    Fail('version incompatibility did not name compiler and requirement');
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTFPCCompilerDriverTests.TestFailureClassification;
var
  Driver: TLWPTFPCCompilerDriver;
  Failure: TLWPTCompilerFailure;
begin
  Driver := TLWPTFPCCompilerDriver.Create;
  try
    Failure := Driver.ClassifyFailure(1,
      'Fatal: Compilation raised exception internally');
    Expect<Integer>(Ord(Failure.Kind)).ToBe(Ord(cfkStaleArtefact));
    Expect<string>(Failure.Summary).ToBe('FAILED (fpc exit 1)');
    Expect<Boolean>(Pos('stale FPC build artefacts', Failure.Recovery) > 0)
      .ToBe(True);

    Failure := Driver.ClassifyFailure(1,
      'bad.pas(3,3) Error: Identifier not found');
    Expect<Integer>(Ord(Failure.Kind)).ToBe(Ord(cfkCompilation));
    Expect<string>(Failure.Recovery).ToBe('');

    Failure := Driver.ClassifyFailure(1,
      'Error while compiling resources -> compile with -vd');
    Expect<Integer>(Ord(Failure.Kind)).ToBe(Ord(cfkStaleArtefact));

    Failure := Driver.ClassifyFailure(1,
      'fpcres: Error: Cannot open file build/app.reslst');
    Expect<Integer>(Ord(Failure.Kind)).ToBe(Ord(cfkStaleArtefact));

    Failure := Driver.ClassifyFailure(1,
      'Writing resource list build/app.reslst');
    Expect<Integer>(Ord(Failure.Kind)).ToBe(Ord(cfkCompilation));

    Failure := Driver.ClassifyFailure(0, '');
    Expect<Integer>(Ord(Failure.Kind)).ToBe(Ord(cfkNone));
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestFailingCompileProducesStructuredErrorDiagnostic;
var
  BuildResult: TLWPTBuildResult;
  Driver: TLWPTFPCCompilerDriver;
  ErrorDiagnosticFound, OriginExpected, OriginFound,
    OriginSound: Boolean;
  ExitCode, DiagnosticIndex: Integer;
  Output, Scratch, SourcePath: string;
  Request: TLWPTBuildRequest;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-driver-failure');
  RecursiveDelete(Scratch);
  ForceDirectories(Scratch + '/bin/units');
  SourcePath := Scratch + '/Broken.pas';
  WriteTextFile(SourcePath, 'program Broken;' + LineEnding + LineEnding
    + '{$mode delphi}{$H+}' + LineEnding + LineEnding + 'begin' + LineEnding
    + '  MissingIdentifier;' + LineEnding + 'end.' + LineEnding);
  Request := FixtureRequest(SourcePath, Scratch + '/bin/broken');
  Driver := TLWPTFPCCompilerDriver.Create;
  try
    ExitCode := RunCompiler(Driver, Request, Output);
    BuildResult := Driver.NormalizeResult(Request, ExitCode, Output);
    ErrorDiagnosticFound := False;
    OriginFound := False;
    OriginSound := True;
    for DiagnosticIndex := 0 to High(BuildResult.Diagnostics) do
      if BuildResult.Diagnostics[DiagnosticIndex].Severity
        = DIAGNOSTIC_ERROR then
      begin
        ErrorDiagnosticFound := True;
        if Pos('Broken.pas', BuildResult.Diagnostics[DiagnosticIndex].Path)
          > 0 then
        begin
          OriginFound := True;
          OriginSound := OriginSound
            and (BuildResult.Diagnostics[DiagnosticIndex].Line > 0)
            and (BuildResult.Diagnostics[DiagnosticIndex].MessageText <> '');
        end;
      end;
    { The file-origin expectation holds only when the compiler reached the
      semantic error; a config-level Fatal without a source origin is an
      environment shape, not a parser defect. }
    { No banner assertion: verbosity config (e.g. choco's fpc.cfg on
      Windows) legitimately suppresses the compiler banner; the exit
      code and parsed diagnostics already prove the real compiler ran. }
    OriginExpected := Pos('Broken.pas(', Output) > 0;
    if (not BuildResult.Success) and ErrorDiagnosticFound
       and ((not OriginExpected) or (OriginFound and OriginSound)) then
      Expect<Boolean>(True).ToBe(True)
    else
    begin
      { Self-diagnose: name the failed condition and dump the evidence. }
      WriteLn('STRUCTURED-DIAGNOSTIC TEST FAILURE: success=',
        BuildResult.Success, ' errorFound=', ErrorDiagnosticFound,
        ' originExpected=', OriginExpected, ' originFound=', OriginFound,
        ' originSound=', OriginSound, ' exit=', ExitCode);
      WriteLn('parsed diagnostics (', Length(BuildResult.Diagnostics), '):');
      for DiagnosticIndex := 0 to High(BuildResult.Diagnostics) do
        WriteLn('  [', BuildResult.Diagnostics[DiagnosticIndex].Severity,
          '] path="', BuildResult.Diagnostics[DiagnosticIndex].Path,
          '" line=', BuildResult.Diagnostics[DiagnosticIndex].Line,
          ' message="',
          BuildResult.Diagnostics[DiagnosticIndex].MessageText, '"');
      WriteLn('raw compiler output follows:');
      WriteLn(Output);
      Expect<Boolean>(False).ToBe(True);
    end;
  finally
    Driver.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestSuccessfulCompileProducesNoErrorDiagnostics;
var
  BuildResult: TLWPTBuildResult;
  Driver: TLWPTFPCCompilerDriver;
  ExitCode, DiagnosticIndex: Integer;
  Output, Scratch, SourcePath: string;
  Request: TLWPTBuildRequest;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-driver-success');
  RecursiveDelete(Scratch);
  ForceDirectories(Scratch + '/bin/units');
  SourcePath := Scratch + '/Works.pas';
  WriteTextFile(SourcePath, 'program Works;' + LineEnding + LineEnding
    + '{$mode delphi}{$H+}' + LineEnding + LineEnding + 'begin' + LineEnding
    + 'end.' + LineEnding);
  Request := FixtureRequest(SourcePath, Scratch + '/bin/works');
  Driver := TLWPTFPCCompilerDriver.Create;
  try
    ExitCode := RunCompiler(Driver, Request, Output);
    BuildResult := Driver.NormalizeResult(Request, ExitCode, Output);
    Expect<Boolean>(BuildResult.Success).ToBe(True);
    for DiagnosticIndex := 0 to High(BuildResult.Diagnostics) do
      Expect<Boolean>(BuildResult.Diagnostics[DiagnosticIndex].Severity
        = DIAGNOSTIC_ERROR).ToBe(False);
    Expect<Integer>(Length(BuildResult.Artifacts)).ToBe(1);
    Expect<string>(BuildResult.Artifacts[0].Path).ToBe(
      FixtureArtifactPath(Request));
  finally
    Driver.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestDiagnosticGrammarRejectsSeverityFalsePositives;
var
  BuildResult: TLWPTBuildResult;
  Driver: TLWPTFPCCompilerDriver;
  Request: TLWPTBuildRequest;
begin
  Request := FixtureRequest('source/works.pas', 'build/works');
  Driver := TLWPTFPCCompilerDriver.Create('fpc-under-test');
  try
    BuildResult := Driver.NormalizeResult(Request, 0,
      '/tmp/Error: directory/works.pas(4,2) Note: compiled despite path text'
      + LineEnding
      + 'works.pas(5,3) Note: message mentions Error: as plain text'
      + LineEnding
      + 'ordinary output contains Warning: but has no diagnostic origin');
    Expect<Boolean>(BuildResult.Success).ToBe(True);
    Expect<Integer>(Length(BuildResult.Diagnostics)).ToBe(2);
    Expect<string>(BuildResult.Diagnostics[0].Severity).ToBe(DIAGNOSTIC_INFO);
    Expect<Boolean>(Pos('/tmp/Error: directory/works.pas',
      BuildResult.Diagnostics[0].Path) > 0).ToBe(True);
    Expect<string>(BuildResult.Diagnostics[1].Severity).ToBe(DIAGNOSTIC_INFO);
    Expect<string>(BuildResult.Diagnostics[1].MessageText).ToBe(
      'message mentions Error: as plain text');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.
  TestWindowsExecutableArtifactPathIsNormalized;
var
  BuildResult: TLWPTBuildResult;
  Driver: TLWPTFPCCompilerDriver;
  Request: TLWPTBuildRequest;
begin
  Request := FixtureRequest('source/works.pas', 'build/works');
  Request.Target.OS := 'windows';
  Request.Target.Architecture := 'x86_64';
  Driver := TLWPTFPCCompilerDriver.Create('fpc-under-test');
  try
    BuildResult := Driver.NormalizeResult(Request, 0, '');
    Expect<Boolean>(BuildResult.Success).ToBe(True);
    Expect<string>(BuildResult.Artifacts[0].Path).ToBe('build/works.exe');

    { Concrete FPC OS names get the same normalization as the neutral
      "windows" -- a direct win64/win32 cross-build must not record a
      nonexistent extensionless artifact. }
    Request.Target.OS := 'win64';
    BuildResult := Driver.NormalizeResult(Request, 0, '');
    Expect<string>(BuildResult.Artifacts[0].Path).ToBe('build/works.exe');
    Request.Target.OS := 'win32';
    Request.Target.Architecture := 'i386';
    BuildResult := Driver.NormalizeResult(Request, 0, '');
    Expect<string>(BuildResult.Artifacts[0].Path).ToBe('build/works.exe');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTFPCCompilerDriverTests.TestNilDriverBuildRequestIsRejected;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    CreateFPCBuildRequest('source/app.pas', 'build/app', nil);
  except
    on E: ELWPTCompilerDriverError do
      Raised := Pos('without a compiler driver', E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTFPCCompilerDriverTests.SetupTests;
begin
  Test('capability probes cache per target and refresh on demand',
    TestProbeCachesPerTargetAndRefreshesOnDemand);
  Test('capability probes dispatch operating systems and map Windows',
    TestProbeDispatchesOperatingSystemAndMapsWindows);
  Test('a satisfying bare probe leaves dispatch flags out',
    TestBareProbeSatisfactionLeavesDispatchOut);
  Test('default build request uses the compiler bare-probe target',
    TestDefaultBuildRequestUsesBareProbeTarget);
  Test('explicit processor override still validates and dispatches',
    TestExplicitProcessorOverrideStillDispatches);
  Test('probe failure names compiler and target requirement',
    TestProbeFailureNamesCompilerAndTargetRequirement);
  Test('probe timeout terminates the isolated process tree',
    TestProbeTimeoutTerminatesProcessTree);
  Test('probe rejects a successful response for the wrong target tuple',
    TestProbeRejectsUnexpectedTargetTuple);
  Test('capabilities are defensive and do not advertise unit outputs',
    TestCapabilitiesAreDefensiveAndDoNotAdvertiseUnits);
  Test('build argument translation preserves the build flag set',
    TestBuildArgumentsPreserveBuildFlagSet);
  Test('extra arguments cannot replace driver-owned request fields',
    TestExtraArgumentValidation);
  Test('build argument translation preserves the test-compile flag set',
    TestBuildArgumentsPreserveTestCompileFlagSet);
  Test('version mismatch names compiler and requirement',
    TestIncompatibleVersionNamesCompilerAndRequirement);
  Test('failure classification owns stale-artifact and exit shaping',
    TestFailureClassification);
  Test('failing compile produces a structured error diagnostic',
    TestFailingCompileProducesStructuredErrorDiagnostic);
  Test('successful compile produces no error diagnostics',
    TestSuccessfulCompileProducesNoErrorDiagnostics);
  Test('diagnostic grammar rejects path and message false positives',
    TestDiagnosticGrammarRejectsSeverityFalsePositives);
  Test('Windows executable artifact paths include the emitted extension',
    TestWindowsExecutableArtifactPathIsNormalized);
  Test('nil FPC drivers fail with the compiler-driver error contract',
    TestNilDriverBuildRequestIsRejected);
end;

function RunIsolatedCompilerDriverCase(const ACase: string): Integer;
var
  Suite: TLWPTFPCCompilerDriverTests;
begin
  Result := 1;
  Suite := TLWPTFPCCompilerDriverTests.Create('isolated FPC compiler driver');
  try
    try
      if ACase = IsolatedDefaultTargetCase then
        Suite.AssertDefaultBuildRequestUsesBareProbeTarget
      else if ACase = IsolatedExplicitProcessorCase then
        Suite.AssertExplicitProcessorOverrideStillDispatches
      else if ACase = IsolatedUnitPathsCase then
        Suite.AssertBuildArgumentsPreserveTestCompileFlagSet
      else
        raise Exception.Create('unknown isolated compiler-driver case "'
          + ACase + '"');
      Result := 0;
    except
      on E: Exception do
        WriteLn('isolated compiler-driver case "', ACase, '" failed: ',
          E.Message);
    end;
  finally
    Suite.Free;
  end;
end;

begin
  if (ParamCount >= 2)
     and (ParamStr(1) = IsolatedCompilerDriverOption) then
    Halt(RunIsolatedCompilerDriverCase(ParamStr(2)));
  if (ParamCount >= 2)
     and (ParamStr(1) = ProbeTimeoutGrandchildOption) then
    Halt(RunProbeTimeoutGrandchild);
  if SameText(ChangeFileExt(ExtractFileName(ParamStr(0)), ''),
    ProbeTimeoutProxyName) then
    Halt(RunProbeTimeoutProxy);
  TestRunnerProgram.AddSuite(TLWPTFPCCompilerDriverTests.Create(
    'FPC compiler driver'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
