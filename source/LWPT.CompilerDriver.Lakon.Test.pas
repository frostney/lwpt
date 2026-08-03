program LWPT.CompilerDriver.Lakon.Test;

{$I Shared.inc}
{$J-}

uses
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.Lakon,
  LWPT.Core,
  TestingPascalLibrary;

const
  FIXTURE_ROOT = 'tests/fixtures/compiler-drivers/lakon/0.1.0/';

type
  TMockLakonCompilerDriver = class(TLWPTLakonCompilerDriver)
  public
    HelpOutput: string;
    ProbeCount: Integer;
    ProbeError: string;
    ProbeExitCode: Integer;
    VersionOutput: string;
  protected
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AStandardOutput, AStandardError: string): Integer; override;
  end;

  TLWPTLakonCompilerDriverTests = class(TTestSuite)
  private
    function FixtureArguments(const AName: string): TStringArray;
    function FixtureText(const AName: string): string;
    function NewDriver: TMockLakonCompilerDriver;
    function Request: TLWPTBuildRequest;
    procedure ExpectArguments(const AActual, AExpected: TStringArray);
    procedure ExpectProbeError(const ADriver: TMockLakonCompilerDriver;
      const ATarget: TLWPTTarget; const AMessagePart: string);
  public
    procedure SetupTests; override;
    procedure TestDefaultTargetIsReleasedWasiTuple;
    procedure TestProbeAdvertisesOnlyReleasedContract;
    procedure TestProbeRunsVersionAndHelpEveryTime;
    procedure TestProbeRejectsWrongIdentity;
    procedure TestProbeRejectsOldVersion;
    procedure TestProbeRejectsIncompleteCommandSurface;
    procedure TestProbeRejectsUnsupportedTarget;
    procedure TestBuildTranslationMatchesPinnedFixture;
    procedure TestConfigurationUnitPathsAreAddedOnce;
    procedure TestCleanTranslationRemainsSessionPrivate;
    procedure TestReleaseModeFailsExplicitly;
    procedure TestNativeTestExecutionFailsExplicitly;
    procedure TestUnsupportedSourcesFailExplicitly;
    procedure TestUnsupportedResourcesFailExplicitly;
    procedure TestUnsupportedIncludePathFailsExplicitly;
    procedure TestUnverifiedExtraArgumentFailsExplicitly;
    procedure TestNormalizedDiagnosticsAndArtifact;
  end;

function TMockLakonCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AStandardOutput,
  AStandardError: string): Integer;
begin
  Inc(ProbeCount);
  if (Length(AArguments) = 1) and (AArguments[0] = '--version') then
    AStandardOutput := VersionOutput
  else if (Length(AArguments) = 1) and (AArguments[0] = '--help') then
    AStandardOutput := HelpOutput
  else
    AStandardOutput := '';
  AStandardError := ProbeError;
  Result := ProbeExitCode;
end;

function TLWPTLakonCompilerDriverTests.FixtureText(
  const AName: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FIXTURE_ROOT + AName);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function TLWPTLakonCompilerDriverTests.FixtureArguments(
  const AName: string): TStringArray;
var
  LineIndex: Integer;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FIXTURE_ROOT + AName);
    SetLength(Result, Lines.Count);
    for LineIndex := 0 to Lines.Count - 1 do
      Result[LineIndex] := Lines[LineIndex];
  finally
    Lines.Free;
  end;
end;

function TLWPTLakonCompilerDriverTests.NewDriver:
  TMockLakonCompilerDriver;
begin
  Result := TMockLakonCompilerDriver.Create('lakon-under-test', '*');
  Result.VersionOutput := FixtureText('version.txt');
  Result.HelpOutput := FixtureText('help.txt');
end;

function TLWPTLakonCompilerDriverTests.Request: TLWPTBuildRequest;
begin
  Result := DefaultBuildRequest;
  Result.Compiler.ID := LAKON_COMPILER_ID;
  Result.Compiler.VersionConstraint := '>=' + LAKON_MINIMUM_VERSION;
  Result.Target.OS := 'wasi';
  Result.Target.Architecture := 'wasm32';
  Result.Target.Environment := 'wasip1';
  Result.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.Mode := BUILD_MODE_DEV;
  Result.Inputs.EntryPoint := 'source dir/main file.pas';
  SetLength(Result.Inputs.Sources, 1);
  Result.Inputs.Sources[0] := Result.Inputs.EntryPoint;
  SetLength(Result.Inputs.UnitPaths, 2);
  Result.Inputs.UnitPaths[0] := 'source dir';
  Result.Inputs.UnitPaths[1] := '.lwpt/modules/example package';
  SetLength(Result.Inputs.IncludePaths, 2);
  Result.Inputs.IncludePaths[0] := Result.Inputs.UnitPaths[0];
  Result.Inputs.IncludePaths[1] := Result.Inputs.UnitPaths[1];
  SetLength(Result.Inputs.Defines, 1);
  Result.Inputs.Defines[0] := 'FEATURE';
  SetLength(Result.Inputs.ExtraArguments, 1);
  Result.Inputs.ExtraArguments[0] := '--no-inline';
  Result.Outputs.Artifact := 'build/private dir/app name.wasm';
  Result.Outputs.ExecutableDirectory := 'build/private dir';
  Result.Outputs.UnitDirectory := 'build/private dir/units';
  Result.Outputs.ObjectDirectory := Result.Outputs.UnitDirectory;
end;

procedure TLWPTLakonCompilerDriverTests.ExpectArguments(
  const AActual, AExpected: TStringArray);
var
  ArgumentIndex: Integer;
begin
  Expect<Integer>(Length(AActual)).ToBe(Length(AExpected));
  if Length(AActual) <> Length(AExpected) then Exit;
  for ArgumentIndex := 0 to High(AExpected) do
    Expect<string>(AActual[ArgumentIndex]).ToBe(AExpected[ArgumentIndex]);
end;

procedure TLWPTLakonCompilerDriverTests.ExpectProbeError(
  const ADriver: TMockLakonCompilerDriver; const ATarget: TLWPTTarget;
  const AMessagePart: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ADriver.ProbeCapabilities(ATarget, True);
  except
    on E: ELWPTCompilerDriverError do
      Raised := Pos(AMessagePart, E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTLakonCompilerDriverTests.TestDefaultTargetIsReleasedWasiTuple;
var
  Driver: TLWPTLakonCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    Target := Driver.DefaultTarget;
    Expect<string>(Target.OS).ToBe('wasi');
    Expect<string>(Target.Architecture).ToBe('wasm32');
    Expect<string>(Target.Environment).ToBe('wasip1');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestProbeAdvertisesOnlyReleasedContract;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockLakonCompilerDriver;
begin
  Driver := NewDriver;
  try
    Capabilities := Driver.ProbeCapabilities(Driver.DefaultTarget, True);
    Expect<string>(Capabilities.CompilerID).ToBe(LAKON_COMPILER_ID);
    Expect<string>(Capabilities.VersionIdentity).ToBe('0.1.0');
    Expect<Integer>(Length(Capabilities.Targets)).ToBe(1);
    Expect<string>(Capabilities.Targets[0].OS).ToBe('wasi');
    Expect<string>(Capabilities.Targets[0].Architecture).ToBe('wasm32');
    Expect<string>(Capabilities.Targets[0].Environment).ToBe('wasip1');
    Expect<Integer>(Length(Capabilities.OutputKinds)).ToBe(1);
    Expect<string>(Capabilities.OutputKinds[0])
      .ToBe(BUILD_OUTPUT_EXECUTABLE);
    Expect<Integer>(Length(Capabilities.Modes)).ToBe(1);
    Expect<string>(Capabilities.Modes[0]).ToBe(BUILD_MODE_DEV);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestProbeRunsVersionAndHelpEveryTime;
var
  Driver: TMockLakonCompilerDriver;
begin
  Driver := NewDriver;
  try
    Driver.ProbeCapabilities(Driver.DefaultTarget);
    Driver.ProbeCapabilities(Driver.DefaultTarget, True);
    Expect<Integer>(Driver.ProbeCount).ToBe(4);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.TestProbeRejectsWrongIdentity;
var
  Driver: TMockLakonCompilerDriver;
begin
  Driver := NewDriver;
  try
    Driver.VersionOutput := 'other 0.1.0';
    ExpectProbeError(Driver, Driver.DefaultTarget,
      'did not identify the released');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.TestProbeRejectsOldVersion;
var
  ConfiguredDriver, Driver: TMockLakonCompilerDriver;
begin
  Driver := NewDriver;
  ConfiguredDriver := TMockLakonCompilerDriver.Create('lakon-under-test',
    '>=0.2.0');
  try
    Driver.VersionOutput := 'lakon 0.0.9';
    ExpectProbeError(Driver, Driver.DefaultTarget,
      'older than supported minimum');
    ConfiguredDriver.VersionOutput := FixtureText('version.txt');
    ConfiguredDriver.HelpOutput := FixtureText('help.txt');
    ExpectProbeError(ConfiguredDriver, ConfiguredDriver.DefaultTarget,
      'does not satisfy configured version constraint ">=0.2.0"');
  finally
    ConfiguredDriver.Free;
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestProbeRejectsIncompleteCommandSurface;
var
  Driver: TMockLakonCompilerDriver;
begin
  Driver := NewDriver;
  try
    Driver.HelpOutput := StringReplace(Driver.HelpOutput,
      '  --inline-stats', '  --removed-inline-stats', []);
    ExpectProbeError(Driver, Driver.DefaultTarget,
      'does not advertise the verified WebAssembly compile contract');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.TestProbeRejectsUnsupportedTarget;
var
  Driver: TMockLakonCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := NewDriver;
  try
    Target := Driver.DefaultTarget;
    Target.OS := 'darwin';
    Target.Architecture := 'aarch64';
    Target.Environment := '';
    ExpectProbeError(Driver, Target,
      'verified target is "wasi/wasm32"');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestBuildTranslationMatchesPinnedFixture;
var
  Arguments, Expected: TStringArray;
  Driver: TLWPTLakonCompilerDriver;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    Arguments := Driver.BuildArguments(Request,
      BuildCompilerInvocationOptions(FIXTURE_ROOT + 'lwpt.cfg', False));
    Expected := FixtureArguments('arguments.txt');
    ExpectArguments(Arguments, Expected);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestConfigurationUnitPathsAreAddedOnce;
var
  Arguments: TStringArray;
  Driver: TLWPTLakonCompilerDriver;
  Index, ModulePathCount, CfgPathCount: Integer;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    Arguments := Driver.BuildArguments(Request,
      BuildCompilerInvocationOptions(FIXTURE_ROOT + 'lwpt.cfg', False));
    ModulePathCount := 0;
    CfgPathCount := 0;
    for Index := 0 to High(Arguments) do
    begin
      if Arguments[Index] = '.lwpt/modules/example package' then
        Inc(ModulePathCount);
      if Arguments[Index] = 'cfg only dependency' then Inc(CfgPathCount);
    end;
    Expect<Integer>(ModulePathCount).ToBe(1);
    Expect<Integer>(CfgPathCount).ToBe(1);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestCleanTranslationRemainsSessionPrivate;
var
  Arguments: TStringArray;
  Driver: TLWPTLakonCompilerDriver;
  Index, NoCacheCount: Integer;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    Arguments := Driver.BuildArguments(Request,
      BuildCompilerInvocationOptions('lwpt.cfg', True));
    NoCacheCount := 0;
    for Index := 0 to High(Arguments) do
      if Arguments[Index] = '--no-cache' then Inc(NoCacheCount);
    Expect<Integer>(NoCacheCount).ToBe(1);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.TestReleaseModeFailsExplicitly;
var
  Driver: TLWPTLakonCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    BuildRequest := Request;
    BuildRequest.Mode := BUILD_MODE_RELEASE;
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('no released translation for mode "release"',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestNativeTestExecutionFailsExplicitly;
var
  Driver: TLWPTLakonCompilerDriver;
  Raised: Boolean;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    Raised := False;
    try
      Driver.BuildArguments(Request,
        PascalSourceCompilerInvocationOptions('lwpt.cfg'));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('cannot execute as native test programs',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestUnsupportedSourcesFailExplicitly;
var
  Driver: TLWPTLakonCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
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

procedure TLWPTLakonCompilerDriverTests.
  TestUnsupportedResourcesFailExplicitly;
var
  Driver: TLWPTLakonCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    BuildRequest := Request;
    SetLength(BuildRequest.Inputs.Resources, 1);
    BuildRequest.Inputs.Resources[0] := 'resource/app.res';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('does not support neutral resource inputs',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestUnsupportedIncludePathFailsExplicitly;
var
  Driver: TLWPTLakonCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    BuildRequest := Request;
    SetLength(BuildRequest.Inputs.IncludePaths, 1);
    BuildRequest.Inputs.IncludePaths[0] := 'include-only';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('does not support include-only search path',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestUnverifiedExtraArgumentFailsExplicitly;
var
  Driver: TLWPTLakonCompilerDriver;
  Raised: Boolean;
  BuildRequest: TLWPTBuildRequest;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    BuildRequest := Request;
    BuildRequest.Inputs.ExtraArguments[0] := '-o';
    Raised := False;
    try
      Driver.BuildArguments(BuildRequest,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('is not in the verified', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.
  TestNormalizedDiagnosticsAndArtifact;
var
  BuildRequest: TLWPTBuildRequest;
  Driver: TLWPTLakonCompilerDriver;
  BuildResult: TLWPTBuildResult;
begin
  Driver := TLWPTLakonCompilerDriver.Create;
  try
    BuildRequest := Request;
    BuildResult := Driver.NormalizeResult(BuildRequest, 1,
      'lakon: source/Widget.pas: Undeclared identifier ''Thing'' at 12:7');
    Expect<Boolean>(BuildResult.Success).ToBe(False);
    Expect<Integer>(Length(BuildResult.Diagnostics)).ToBe(1);
    Expect<string>(BuildResult.Diagnostics[0].Severity)
      .ToBe(DIAGNOSTIC_ERROR);
    Expect<string>(BuildResult.Diagnostics[0].Path)
      .ToBe('source/Widget.pas');
    Expect<Integer>(BuildResult.Diagnostics[0].Line).ToBe(12);
    Expect<Integer>(BuildResult.Diagnostics[0].Column).ToBe(7);
    Expect<string>(BuildResult.Diagnostics[0].MessageText)
      .ToBe('Undeclared identifier ''Thing''');

    BuildResult := Driver.NormalizeResult(BuildRequest, 0,
      'lakon: unit cache skipped (read-only cache directory)');
    Expect<Boolean>(BuildResult.Success).ToBe(True);
    Expect<Integer>(Length(BuildResult.Artifacts)).ToBe(1);
    Expect<string>(BuildResult.Artifacts[0].Kind)
      .ToBe(BUILD_OUTPUT_EXECUTABLE);
    Expect<string>(BuildResult.Artifacts[0].Path)
      .ToBe(BuildRequest.Outputs.Artifact);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTLakonCompilerDriverTests.SetupTests;
begin
  Test('default target is the released WASI tuple',
    TestDefaultTargetIsReleasedWasiTuple);
  Test('probe advertises only the released contract',
    TestProbeAdvertisesOnlyReleasedContract);
  Test('version and help probes run on every capability request',
    TestProbeRunsVersionAndHelpEveryTime);
  Test('probe rejects a different compiler identity',
    TestProbeRejectsWrongIdentity);
  Test('probe rejects versions below the released floor',
    TestProbeRejectsOldVersion);
  Test('probe rejects an incomplete command surface',
    TestProbeRejectsIncompleteCommandSurface);
  Test('probe rejects unsupported target tuples',
    TestProbeRejectsUnsupportedTarget);
  Test('neutral request translation matches the release fixture',
    TestBuildTranslationMatchesPinnedFixture);
  Test('configuration unit paths are added without duplicates',
    TestConfigurationUnitPathsAreAddedOnce);
  Test('clean translation keeps the cache session-private',
    TestCleanTranslationRemainsSessionPrivate);
  Test('unreleased release-mode translation fails explicitly',
    TestReleaseModeFailsExplicitly);
  Test('native test execution without a WASI host fails explicitly',
    TestNativeTestExecutionFailsExplicitly);
  Test('multiple explicit sources fail explicitly',
    TestUnsupportedSourcesFailExplicitly);
  Test('resource inputs fail explicitly',
    TestUnsupportedResourcesFailExplicitly);
  Test('include-only paths fail explicitly',
    TestUnsupportedIncludePathFailsExplicitly);
  Test('unverified extra arguments fail explicitly',
    TestUnverifiedExtraArgumentFailsExplicitly);
  Test('diagnostics and artifacts normalize deterministically',
    TestNormalizedDiagnosticsAndArtifact);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTLakonCompilerDriverTests.Create(
    'Lakon compiler driver'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
