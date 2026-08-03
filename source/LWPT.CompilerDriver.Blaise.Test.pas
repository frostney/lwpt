program LWPT.CompilerDriver.Blaise.Test;

{$I Shared.inc}
{$J-}

uses
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.Blaise,
  LWPT.Core,
  TestingPascalLibrary;

const
  FixtureRoot = 'tests/fixtures/compiler-drivers/blaise/v0.13.0/';

type
  TMockBlaiseCompilerDriver = class(TLWPTBlaiseCompilerDriver)
  public
    ProbeCount: Integer;
    ProbeError: string;
    ProbeExitCode: Integer;
    ProbeOutput: string;
  protected
    function ExecuteProbe(out AStandardOutput, AStandardError: string):
      Integer; override;
  end;

  TLWPTBlaiseCompilerDriverTests = class(TTestSuite)
  private
    function FixtureText(const AName: string): string;
    function FixtureArguments(const AName: string): TStringArray;
    function NewDriver: TMockBlaiseCompilerDriver;
    function Request: TLWPTBuildRequest;
    procedure ExpectArguments(const AActual, AExpected: TStringArray);
    procedure ExpectDriverError(const ADriver: TMockBlaiseCompilerDriver;
      const ATarget: TLWPTTarget; const AMessagePart: string);
  public
    procedure SetupTests; override;
    procedure TestDefaultTargetUsesLivePinnedCLIContract;
    procedure TestProbeAdvertisesOnlyVerifiedTargets;
    procedure TestProbeRunsEveryTime;
    procedure TestProbeRejectsWrongIdentity;
    procedure TestProbeRejectsOldVersion;
    procedure TestProbeRejectsIncompleteTargetContract;
    procedure TestProbeRejectsUnsupportedTarget;
    procedure TestBuildTranslationMatchesPinnedFixture;
    procedure TestReleaseCleanTranslation;
    procedure TestUnsupportedSourcesFailExplicitly;
    procedure TestUnsupportedResourcesFailExplicitly;
    procedure TestUnsupportedIncludePathFailsExplicitly;
    procedure TestManagedExtraArgumentFailsExplicitly;
    procedure TestOutputSuppressingExtraArgumentsFailExplicitly;
    procedure TestNormalizedDiagnosticsAndArtifact;
  end;

function TMockBlaiseCompilerDriver.ExecuteProbe(out AStandardOutput,
  AStandardError: string): Integer;
begin
  Inc(ProbeCount);
  AStandardOutput := ProbeOutput;
  AStandardError := ProbeError;
  Result := ProbeExitCode;
end;

function TLWPTBlaiseCompilerDriverTests.FixtureText(
  const AName: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureRoot + AName);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function TLWPTBlaiseCompilerDriverTests.FixtureArguments(
  const AName: string): TStringArray;
var
  Lines: TStringList;
  LineIndex: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureRoot + AName);
    SetLength(Result, Lines.Count);
    for LineIndex := 0 to Lines.Count - 1 do Result[LineIndex] :=
      Lines[LineIndex];
  finally
    Lines.Free;
  end;
end;

function TLWPTBlaiseCompilerDriverTests.NewDriver:
  TMockBlaiseCompilerDriver;
begin
  Result := TMockBlaiseCompilerDriver.Create('blaise-under-test', '*');
  Result.ProbeOutput := FixtureText('help-linux.txt');
end;

function TLWPTBlaiseCompilerDriverTests.Request: TLWPTBuildRequest;
begin
  Result := DefaultBuildRequest;
  Result.Compiler.ID := BLAISE_COMPILER_ID;
  Result.Compiler.VersionConstraint := '>=' + BLAISE_MINIMUM_VERSION;
  Result.Target.OS := 'linux';
  Result.Target.Architecture := 'x86_64';
  Result.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.Mode := BUILD_MODE_DEV;
  Result.Inputs.EntryPoint := 'source/main.pas';
  SetLength(Result.Inputs.Sources, 1);
  Result.Inputs.Sources[0] := Result.Inputs.EntryPoint;
  SetLength(Result.Inputs.UnitPaths, 2);
  Result.Inputs.UnitPaths[0] := 'source';
  Result.Inputs.UnitPaths[1] := '.lwpt/modules/example';
  SetLength(Result.Inputs.Defines, 1);
  Result.Inputs.Defines[0] := 'FEATURE';
  SetLength(Result.Inputs.ExtraArguments, 1);
  Result.Inputs.ExtraArguments[0] := '--static';
  Result.Outputs.Artifact := 'build/private/app';
  Result.Outputs.ExecutableDirectory := 'build/private';
  Result.Outputs.UnitDirectory := 'build/private/units';
  Result.Outputs.ObjectDirectory := Result.Outputs.UnitDirectory;
end;

procedure TLWPTBlaiseCompilerDriverTests.ExpectArguments(
  const AActual, AExpected: TStringArray);
var
  ArgumentIndex: Integer;
begin
  Expect<Integer>(Length(AActual)).ToBe(Length(AExpected));
  if Length(AActual) <> Length(AExpected) then Exit;
  for ArgumentIndex := 0 to High(AExpected) do
    Expect<string>(AActual[ArgumentIndex]).ToBe(AExpected[ArgumentIndex]);
end;

procedure TLWPTBlaiseCompilerDriverTests.ExpectDriverError(
  const ADriver: TMockBlaiseCompilerDriver; const ATarget: TLWPTTarget;
  const AMessagePart: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ADriver.ProbeCapabilities(ATarget);
  except
    on E: ELWPTCompilerDriverError do
      Raised := Pos(AMessagePart, E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestDefaultTargetUsesLivePinnedCLIContract;
var
  Driver: TMockBlaiseCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := NewDriver;
  try
    Target := Driver.DefaultTarget;
    Expect<string>(Target.OS).ToBe('linux');
    Expect<string>(Target.Architecture).ToBe('x86_64');
    Expect<Integer>(Driver.ProbeCount).ToBe(1);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestProbeAdvertisesOnlyVerifiedTargets;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockBlaiseCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := NewDriver;
  try
    Target := Request.Target;
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<string>(Capabilities.CompilerID).ToBe(BLAISE_COMPILER_ID);
    Expect<string>(Capabilities.VersionIdentity).ToBe('0.13.0');
    Expect<Integer>(Length(Capabilities.Targets)).ToBe(2);
    Expect<string>(Capabilities.Targets[0].OS).ToBe('linux');
    Expect<string>(Capabilities.Targets[0].Architecture).ToBe('x86_64');
    Expect<string>(Capabilities.Targets[1].OS).ToBe('freebsd');
    Expect<string>(Capabilities.Targets[1].Architecture).ToBe('x86_64');
    Expect<Integer>(Length(Capabilities.OutputKinds)).ToBe(1);
    Expect<string>(Capabilities.OutputKinds[0]).ToBe(
      BUILD_OUTPUT_EXECUTABLE);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestProbeRunsEveryTime;
var
  Driver: TMockBlaiseCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := NewDriver;
  try
    Target := Request.Target;
    Driver.ProbeCapabilities(Target);
    Driver.ProbeCapabilities(Target);
    Driver.ProbeCapabilities(Target, True);
    Expect<Integer>(Driver.ProbeCount).ToBe(3);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestProbeRejectsWrongIdentity;
var
  Driver: TMockBlaiseCompilerDriver;
begin
  Driver := NewDriver;
  try
    Driver.ProbeOutput := 'Not Blaise 0.13.0' + LineEnding;
    ExpectDriverError(Driver, Request.Target, 'identify the Blaise CLI');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestProbeRejectsOldVersion;
var
  Driver: TMockBlaiseCompilerDriver;
begin
  Driver := NewDriver;
  try
    Driver.ProbeOutput := StringReplace(Driver.ProbeOutput, 'v0.13.0',
      'v0.12.0', []);
    ExpectDriverError(Driver, Request.Target, 'older than supported minimum');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestProbeRejectsIncompleteTargetContract;
var
  Driver: TMockBlaiseCompilerDriver;
begin
  Driver := NewDriver;
  try
    Driver.ProbeOutput := StringReplace(Driver.ProbeOutput,
      'freebsd-x86_64', 'freebsd-i386', [rfReplaceAll]);
    ExpectDriverError(Driver, Request.Target, 'does not advertise both');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestProbeRejectsUnsupportedTarget;
var
  Driver: TMockBlaiseCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := NewDriver;
  try
    Target := Default(TLWPTTarget);
    Target.OS := 'darwin';
    Target.Architecture := 'aarch64';
    ExpectDriverError(Driver, Target, 'verified targets are');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestBuildTranslationMatchesPinnedFixture;
var
  Actual, Expected: TStringArray;
  Driver: TMockBlaiseCompilerDriver;
  Options: TLWPTCompilerInvocationOptions;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    Options := BuildCompilerInvocationOptions(FixtureRoot + 'lwpt.cfg',
      False);
    Actual := Driver.BuildArguments(BuildRequest, Options);
    Expected := FixtureArguments('dev-arguments.txt');
    ExpectArguments(Actual, Expected);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestReleaseCleanTranslation;
var
  Arguments: TStringArray;
  ArgumentIndex: Integer;
  Driver: TMockBlaiseCompilerDriver;
  HasDebug, HasNoIncremental: Boolean;
  Options: TLWPTCompilerInvocationOptions;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    BuildRequest.Mode := BUILD_MODE_RELEASE;
    Options := BuildCompilerInvocationOptions('lwpt.cfg', True);
    Arguments := Driver.BuildArguments(BuildRequest, Options);
    HasDebug := False;
    HasNoIncremental := False;
    for ArgumentIndex := 0 to High(Arguments) do
    begin
      HasDebug := HasDebug or (Arguments[ArgumentIndex] = '--debug');
      HasNoIncremental := HasNoIncremental
        or (Arguments[ArgumentIndex] = '--no-incremental');
    end;
    Expect<Boolean>(HasDebug).ToBe(False);
    Expect<Boolean>(HasNoIncremental).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.TestUnsupportedSourcesFailExplicitly;
var
  Driver: TMockBlaiseCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    SetLength(BuildRequest.Inputs.Sources, 2);
    BuildRequest.Inputs.Sources[1] := 'source/other.pas';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('one explicit entry source', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestUnsupportedResourcesFailExplicitly;
var
  Driver: TMockBlaiseCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    SetLength(BuildRequest.Inputs.Resources, 1);
    BuildRequest.Inputs.Resources[0] := 'app.rc';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('resource inputs', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestUnsupportedIncludePathFailsExplicitly;
var
  Driver: TMockBlaiseCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    SetLength(BuildRequest.Inputs.IncludePaths, 1);
    BuildRequest.Inputs.IncludePaths[0] := 'includes';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('include-only search path', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestManagedExtraArgumentFailsExplicitly;
var
  Driver: TMockBlaiseCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    BuildRequest.Inputs.ExtraArguments[0] := '--target=freebsd-x86_64';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('managed by ' + PROJECT_NAME, E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestOutputSuppressingExtraArgumentsFailExplicitly;
const
  ArgumentCount = 8;
  Arguments: array[0..ArgumentCount - 1] of string = (
    '--help', '-h', '--emit-asm', '--dump-ast', '--emit-ir', '--emit-iface',
    '--skip-dep-codegen', '-d');
var
  ArgumentIndex: Integer;
  Driver: TMockBlaiseCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    for ArgumentIndex := 0 to ArgumentCount - 1 do
    begin
      BuildRequest := Request;
      BuildRequest.Inputs.ExtraArguments[0] := Arguments[ArgumentIndex];
      Raised := False;
      try
        Driver.BuildArguments(BuildRequest,
          BuildCompilerInvocationOptions('', False));
      except
        on E: ELWPTCompilerDriverError do
          Raised := Pos('managed by ' + PROJECT_NAME, E.Message) > 0;
      end;
      Expect<Boolean>(Raised).ToBe(True);
    end;
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.
  TestNormalizedDiagnosticsAndArtifact;
var
  Driver: TMockBlaiseCompilerDriver;
  Result: TLWPTBuildResult;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := NewDriver;
  try
    BuildRequest := Request;
    Result := Driver.NormalizeResult(BuildRequest, 1,
      'Parse error: expected END' + LineEnding
      + 'Warning: experimental syntax' + LineEnding);
    Expect<Boolean>(Result.Success).ToBe(False);
    Expect<Integer>(Length(Result.Diagnostics)).ToBe(2);
    Expect<string>(Result.Diagnostics[0].Severity).ToBe(DIAGNOSTIC_ERROR);
    Expect<string>(Result.Diagnostics[0].MessageText).ToBe('expected END');
    Expect<string>(Result.Diagnostics[1].Severity).ToBe(DIAGNOSTIC_WARNING);
    Result := Driver.NormalizeResult(BuildRequest, 0, '');
    Expect<Boolean>(Result.Success).ToBe(True);
    Expect<Integer>(Length(Result.Artifacts)).ToBe(1);
    Expect<string>(Result.Artifacts[0].Path).ToBe(
      BuildRequest.Outputs.Artifact);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBlaiseCompilerDriverTests.SetupTests;
begin
  Test('default target comes from the live pinned CLI contract',
    TestDefaultTargetUsesLivePinnedCLIContract);
  Test('probe advertises only upstream-verified target tuples',
    TestProbeAdvertisesOnlyVerifiedTargets);
  Test('probe executes for every invocation without a cache',
    TestProbeRunsEveryTime);
  Test('probe rejects a different executable identity',
    TestProbeRejectsWrongIdentity);
  Test('probe rejects Blaise below the pinned minimum release',
    TestProbeRejectsOldVersion);
  Test('probe rejects an incomplete verified target contract',
    TestProbeRejectsIncompleteTargetContract);
  Test('probe rejects unsupported targets without fallback',
    TestProbeRejectsUnsupportedTarget);
  Test('build translation matches the pinned v0.13.0 fixture',
    TestBuildTranslationMatchesPinnedFixture);
  Test('release clean translation disables incremental compilation',
    TestReleaseCleanTranslation);
  Test('additional explicit sources fail rather than being ignored',
    TestUnsupportedSourcesFailExplicitly);
  Test('resource inputs fail rather than being ignored',
    TestUnsupportedResourcesFailExplicitly);
  Test('include-only search paths fail rather than being ignored',
    TestUnsupportedIncludePathFailsExplicitly);
  Test('managed extra arguments cannot replace neutral selections',
    TestManagedExtraArgumentFailsExplicitly);
  Test('output-suppressing arguments cannot replace binary production',
    TestOutputSuppressingExtraArgumentsFailExplicitly);
  Test('diagnostics and primary artifacts are normalized',
    TestNormalizedDiagnosticsAndArtifact);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTBlaiseCompilerDriverTests.Create(
    'Blaise compiler driver'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
