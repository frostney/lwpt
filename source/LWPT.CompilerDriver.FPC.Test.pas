program LWPT.CompilerDriver.FPC.Test;

{$I Shared.inc}
{$J-}

uses
  Classes,
  Process,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.Command.Common,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.FPC,
  LWPT.Core,
  Platform,
  TestingPascalLibrary,
  Tests.Scratch;

type
  TMockFPCCompilerDriver = class(TLWPTFPCCompilerDriver)
  private
    FProbeCount: Integer;
    FProbeExitCode: Integer;
    FProbeOutput: string;
    FLastArguments: LWPT.Core.TStringArray;
  protected
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AOutput: string): Integer; override;
  public
    property LastArguments: LWPT.Core.TStringArray read FLastArguments;
    property ProbeCount: Integer read FProbeCount;
    property ProbeExitCode: Integer read FProbeExitCode
      write FProbeExitCode;
    property ProbeOutput: string read FProbeOutput write FProbeOutput;
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
  public
    procedure SetupTests; override;
    procedure TestProbeCachesPerTargetAndRefreshesOnDemand;
    procedure TestProbeDispatchesOperatingSystemAndMapsWindows;
    procedure TestProbeFailureNamesCompilerAndTargetRequirement;
    procedure TestProbeRejectsUnexpectedTargetTuple;
    procedure TestCapabilitiesAreDefensiveAndDoNotAdvertiseUnits;
    procedure TestBuildArgumentsPreserveBuildFlagSet;
    procedure TestBuildArgumentsPreserveTestCompileFlagSet;
    procedure TestIncompatibleVersionNamesCompilerAndRequirement;
    procedure TestFailureClassification;
    procedure TestFailingCompileProducesStructuredErrorDiagnostic;
    procedure TestSuccessfulCompileProducesNoErrorDiagnostics;
    procedure TestDiagnosticGrammarRejectsSeverityFalsePositives;
    procedure TestWindowsExecutableArtifactPathIsNormalized;
  end;

function TMockFPCCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AOutput: string): Integer;
begin
  Inc(FProbeCount);
  FLastArguments := Copy(AArguments, 0, Length(AArguments));
  AOutput := FProbeOutput;
  Result := FProbeExitCode;
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
    Driver.ProbeOutput := '3.2.2 ' + Target.OS + ' '
      + Target.Architecture;
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<string>(Capabilities.VersionIdentity).ToBe('3.2.2');
    Capabilities.Targets[0].Architecture := 'mutated';
    Capabilities.OutputKinds[0] := BUILD_OUTPUT_UNIT;
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
    Expect<string>(Capabilities.Targets[0].Architecture).ToBe(
      Target.Architecture);
    Expect<string>(Capabilities.OutputKinds[0]).ToBe(BUILD_OUTPUT_EXECUTABLE);
    Driver.ProbeOutput := '3.3.1 ' + Target.OS + ' '
      + Target.Architecture;
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
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockFPCCompilerDriver;
  OtherOperatingSystem: string;
  Raised: Boolean;
  Target: TLWPTTarget;
begin
  if GetBuildOS = 'linux' then OtherOperatingSystem := 'darwin'
  else OtherOperatingSystem := 'linux';
  Target := Default(TLWPTTarget);
  Target.OS := OtherOperatingSystem;
  Target.Architecture := GetBuildArch;
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := '3.2.2 ' + OtherOperatingSystem + ' '
      + Target.Architecture;
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<string>(Capabilities.Targets[0].OS).ToBe(OtherOperatingSystem);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments,
      '-T' + OtherOperatingSystem)).ToBe(True);

    Target.OS := 'windows';
    Target.Architecture := 'x86';
    Driver.ProbeOutput := '3.2.2 win32 i386';
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Twin32'))
      .ToBe(True);

    Target.Architecture := 'x86_64';
    Driver.ProbeOutput := '3.2.2 win64 x86_64';
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<Boolean>(ArgumentsContain(Driver.LastArguments, '-Twin64'))
      .ToBe(True);

    Target.Architecture := 'arm';
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

  { The neutral windows OS is architecture-constrained: a win32 probe
    answer must not satisfy a windows/x86_64 request. A fresh driver
    avoids the (correct) per-target probe cache from the cases above. }
  Target.OS := 'windows';
  Target.Architecture := 'x86_64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := '3.2.2 win32 x86_64';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('returned target "win32/x86_64"', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
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
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do;
    end;
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
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
  Target.OS := GetBuildOS;
  Target.Architecture := GetBuildArch;
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := '3.2.2 unexpected-os ' + Target.Architecture;
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('compiler "' + FPC_COMPILER_ID + '"', E.Message) > 0)
          and (Pos(Target.OS + '/' + Target.Architecture, E.Message) > 0)
          and (Pos('returned target "unexpected-os/'
            + Target.Architecture + '"', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);

  finally
    Driver.Free;
  end;

  { The neutral windows OS is architecture-constrained: a win32 probe
    answer must not satisfy a windows/x86_64 request. A fresh driver
    avoids the (correct) per-target probe cache from the cases above. }
  Target.OS := 'windows';
  Target.Architecture := 'x86_64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := '3.2.2 win32 x86_64';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('returned target "win32/x86_64"', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
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
    Driver.ProbeOutput := '3.2.2 ' + Target.OS + ' ' + Target.Architecture;
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

  { The neutral windows OS is architecture-constrained: a win32 probe
    answer must not satisfy a windows/x86_64 request. A fresh driver
    avoids the (correct) per-target probe cache from the cases above. }
  Target.OS := 'windows';
  Target.Architecture := 'x86_64';
  Driver := TMockFPCCompilerDriver.Create('mock-fpc');
  try
    Driver.ProbeOutput := '3.2.2 win32 x86_64';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('returned target "win32/x86_64"', E.Message) > 0;
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
  Driver: TLWPTFPCCompilerDriver;
  InvocationOptions: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
begin
  Request := FixtureRequest('source/app.pas', 'session/bin/app');
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
  InvocationOptions := BuildCompilerInvocationOptions('lwpt.cfg', False);
  Driver := TLWPTFPCCompilerDriver.Create('fpc-under-test');
  try
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    ExpectArguments(Arguments, ['-P' + CrossProcessor, '-FEsession/bin',
      '-FUsession/bin/units', '@lwpt.cfg', '-Fusource', '-Fiinclude', '-Sh',
      '-O4', '-dPRODUCTION', '-Xs', '-CX', '-XX', '-B', '-osession/bin/app',
      'source/app.pas']);

    Request.Target.Architecture := GetBuildArch;
    Request.Mode := BUILD_MODE_DEV;
    SetLength(Request.Inputs.Defines, 0);
    InvocationOptions := BuildCompilerInvocationOptions('lwpt.cfg', True);
    Arguments := Driver.BuildArguments(Request, InvocationOptions);
    ExpectArguments(Arguments, ['-FEsession/bin', '-FUsession/bin/units',
      '@lwpt.cfg', '-Fusource', '-Fiinclude', '-Sh', '-O-', '-gw',
      '-godwarfsets', '-gl', '-Ct', '-Cr', '-Sa', '-B', '-osession/bin/app',
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

procedure TLWPTFPCCompilerDriverTests.
  TestBuildArgumentsPreserveTestCompileFlagSet;
var
  Arguments: LWPT.Core.TStringArray;
  ConfigurationPath, Scratch: string;
  Driver: TLWPTFPCCompilerDriver;
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
  Driver := TLWPTFPCCompilerDriver.Create('fpc-under-test');
  try
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
  ErrorDiagnosticFound, OriginFound: Boolean;
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
    Expect<Boolean>(BuildResult.Success).ToBe(False);
    ErrorDiagnosticFound := False;
    OriginFound := False;
    for DiagnosticIndex := 0 to High(BuildResult.Diagnostics) do
      if BuildResult.Diagnostics[DiagnosticIndex].Severity
        = DIAGNOSTIC_ERROR then
      begin
        ErrorDiagnosticFound := True;
        if Pos('Broken.pas', BuildResult.Diagnostics[DiagnosticIndex].Path)
          > 0 then
        begin
          OriginFound := True;
          Expect<Boolean>(BuildResult.Diagnostics[DiagnosticIndex].Line > 0)
            .ToBe(True);
          Expect<Boolean>(
            BuildResult.Diagnostics[DiagnosticIndex].MessageText <> '')
            .ToBe(True);
        end;
      end;
    Expect<Boolean>(ErrorDiagnosticFound).ToBe(True);
    Expect<Boolean>(OriginFound).ToBe(True);
    Expect<Boolean>(Pos('Free Pascal Compiler', Output) > 0).ToBe(True);
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
      Request.Outputs.Artifact);
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

procedure TLWPTFPCCompilerDriverTests.SetupTests;
begin
  Test('capability probes cache per target and refresh on demand',
    TestProbeCachesPerTargetAndRefreshesOnDemand);
  Test('capability probes dispatch operating systems and map Windows',
    TestProbeDispatchesOperatingSystemAndMapsWindows);
  Test('probe failure names compiler and target requirement',
    TestProbeFailureNamesCompilerAndTargetRequirement);
  Test('probe rejects a successful response for the wrong target tuple',
    TestProbeRejectsUnexpectedTargetTuple);
  Test('capabilities are defensive and do not advertise unit outputs',
    TestCapabilitiesAreDefensiveAndDoNotAdvertiseUnits);
  Test('build argument translation preserves the build flag set',
    TestBuildArgumentsPreserveBuildFlagSet);
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
end;

begin
  TestRunnerProgram.AddSuite(TLWPTFPCCompilerDriverTests.Create(
    'FPC compiler driver'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
