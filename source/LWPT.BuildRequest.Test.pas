program LWPT.BuildRequest.Test;

{$I Shared.inc}
{$J-}

uses
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.Core,
  TestingPascalLibrary;

type
  TLWPTBuildRequestTests = class(TTestSuite)
  private
    function FixtureRequest: TLWPTBuildRequest;
    function NativeCapabilities(const ACompilerID,
      AVersion: string): TLWPTCompilerCapabilities;
  public
    procedure SetupTests; override;
    procedure TestSerializationMatchesVersionedFixture;
    procedure TestFixtureParsesAndRoundTrips;
    procedure TestUnsupportedSchemaFailsClearly;
    procedure TestTargetTupleWorksAcrossCompatibleCompilers;
    procedure TestCompilerCanAdvertiseMultipleTargets;
    procedure TestCompatibilityRejectsUnsupportedDimensions;
    procedure TestNormalisedBuildResultValidates;
  end;

function ReadFixture(const APath: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Lines.LineBreak := #10;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function TLWPTBuildRequestTests.FixtureRequest: TLWPTBuildRequest;
begin
  Result := DefaultBuildRequest;
  Result.Compiler.ID := 'fpc';
  Result.Compiler.VersionConstraint := '^3.2.0';
  Result.Compiler.VersionIdentity := '3.2.2';
  Result.Target.OS := 'darwin';
  Result.Target.Architecture := 'aarch64';
  Result.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.Mode := BUILD_MODE_RELEASE;
  Result.Inputs.EntryPoint := 'source/app.pas';
  SetLength(Result.Inputs.Sources, 2);
  Result.Inputs.Sources[0] := 'source/app.pas';
  Result.Inputs.Sources[1] := 'source/generated.pas';
  SetLength(Result.Inputs.Defines, 1);
  Result.Inputs.Defines[0] := 'PRODUCTION';
  SetLength(Result.Inputs.UnitPaths, 2);
  Result.Inputs.UnitPaths[0] := 'source';
  Result.Inputs.UnitPaths[1] := '.lwpt/modules/example/source';
  SetLength(Result.Inputs.IncludePaths, 1);
  Result.Inputs.IncludePaths[0] := 'source';
  SetLength(Result.Inputs.Resources, 1);
  Result.Inputs.Resources[0] := 'resources/app.res';
  Result.Outputs.Artifact := '.lwpt/sessions/example/bin/app';
  Result.Outputs.ExecutableDirectory := '.lwpt/sessions/example/bin';
  Result.Outputs.UnitDirectory := '.lwpt/sessions/example/units';
  Result.Outputs.ObjectDirectory := '.lwpt/sessions/example/objects';
  Result.Outputs.ResourceDirectory := '.lwpt/sessions/example/resources';
end;

function TLWPTBuildRequestTests.NativeCapabilities(
  const ACompilerID, AVersion: string): TLWPTCompilerCapabilities;
begin
  Result := DefaultCompilerCapabilities;
  Result.CompilerID := ACompilerID;
  Result.VersionIdentity := AVersion;
  SetLength(Result.Targets, 1);
  Result.Targets[0].OS := 'darwin';
  Result.Targets[0].Architecture := 'aarch64';
  SetLength(Result.OutputKinds, 1);
  Result.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
  SetLength(Result.Modes, 2);
  Result.Modes[0] := BUILD_MODE_DEV;
  Result.Modes[1] := BUILD_MODE_RELEASE;
end;

procedure TLWPTBuildRequestTests.TestSerializationMatchesVersionedFixture;
var
  Actual, Expected: string;
begin
  Actual := SerializeBuildRequest(FixtureRequest);
  Expected := ReadFixture(
    'tests/fixtures/build-request/v1/native-executable.toml');
  Expect<string>(Actual).ToBe(Expected);
end;

procedure TLWPTBuildRequestTests.TestFixtureParsesAndRoundTrips;
var
  Parsed: TLWPTBuildRequest;
  Fixture: string;
begin
  Fixture := ReadFixture(
    'tests/fixtures/build-request/v1/native-executable.toml');
  Parsed := ParseBuildRequest(Fixture);
  Expect<Integer>(Parsed.SchemaVersion).ToBe(BUILD_REQUEST_SCHEMA_VERSION);
  Expect<string>(Parsed.Compiler.ID).ToBe('fpc');
  Expect<string>(Parsed.Target.OS).ToBe('darwin');
  Expect<string>(Parsed.Target.Architecture).ToBe('aarch64');
  Expect<string>(SerializeBuildRequest(Parsed)).ToBe(Fixture);
end;

procedure TLWPTBuildRequestTests.TestUnsupportedSchemaFailsClearly;
var
  Raised: Boolean;
  Invalid: string;
  Capabilities: TLWPTCompilerCapabilities;
  BuildResult: TLWPTBuildResult;
begin
  Invalid := StringReplace(SerializeBuildRequest(FixtureRequest),
    'schema = 1', 'schema = 99', []);
  Raised := False;
  try
    ParseBuildRequest(Invalid);
  except
    on E: ELWPTBuildRequestError do
    begin
      Raised := True;
      if Pos('unsupported build request schema version 99', E.Message) = 0 then
        Fail('unexpected schema error: ' + E.Message);
    end;
  end;
  if not Raised then Fail('unsupported schema did not raise');
  Expect<Boolean>(Raised).ToBe(True);

  Capabilities := DefaultCompilerCapabilities;
  Capabilities.SchemaVersion := 99;
  Raised := False;
  try
    ValidateCompilerCapabilities(Capabilities);
  except
    on E: ELWPTBuildRequestError do
      Raised := Pos('unsupported compiler capabilities schema version 99',
        E.Message) > 0;
  end;
  if not Raised then Fail('unsupported capability schema did not raise');
  Expect<Boolean>(Raised).ToBe(True);

  BuildResult := DefaultBuildResult;
  BuildResult.SchemaVersion := 99;
  Raised := False;
  try
    ValidateBuildResult(BuildResult);
  except
    on E: ELWPTBuildRequestError do
      Raised := Pos('unsupported build result schema version 99',
        E.Message) > 0;
  end;
  if not Raised then Fail('unsupported build-result schema did not raise');
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTBuildRequestTests.TestTargetTupleWorksAcrossCompatibleCompilers;
var
  Request: TLWPTBuildRequest;
  FPC, Lakon: TLWPTCompilerCapabilities;
  Reason: string;
begin
  Request := FixtureRequest;
  Request.Compiler.VersionConstraint := '*';
  Request.Compiler.VersionIdentity := '';
  FPC := NativeCapabilities('fpc', '3.2.2');
  Expect<Boolean>(BuildRequestIsCompatible(Request, FPC, Reason)).ToBe(True);

  Request.Compiler.ID := 'lakon';
  Lakon := NativeCapabilities('lakon', '1.4.0');
  Expect<Boolean>(BuildRequestIsCompatible(Request, Lakon, Reason)).ToBe(True);
  Expect<string>(Request.Target.OS).ToBe('darwin');
  Expect<string>(Request.Target.Architecture).ToBe('aarch64');
end;

procedure TLWPTBuildRequestTests.TestCompilerCanAdvertiseMultipleTargets;
var
  Request: TLWPTBuildRequest;
  Capabilities: TLWPTCompilerCapabilities;
  Reason: string;
begin
  Request := FixtureRequest;
  Request.Compiler.VersionIdentity := '';
  Request.Compiler.VersionConstraint := '^3.2.0';
  Request.Target.OS := 'linux';
  Request.Target.Architecture := 'x86_64';
  Capabilities := NativeCapabilities('fpc', '3.2.2');
  SetLength(Capabilities.Targets, 2);
  Capabilities.Targets[1].OS := 'linux';
  Capabilities.Targets[1].Architecture := 'x86_64';
  Expect<Boolean>(BuildRequestIsCompatible(
    Request, Capabilities, Reason)).ToBe(True);
end;

procedure TLWPTBuildRequestTests.TestCompatibilityRejectsUnsupportedDimensions;
var
  Request: TLWPTBuildRequest;
  Capabilities: TLWPTCompilerCapabilities;
  Reason: string;
begin
  Request := FixtureRequest;
  Request.Compiler.VersionIdentity := '';
  Capabilities := NativeCapabilities('fpc', '3.2.2');
  Request.Target.Architecture := 'x86_64';
  Expect<Boolean>(BuildRequestIsCompatible(
    Request, Capabilities, Reason)).ToBe(False);
  Expect<string>(Reason).ToBe('target tuple is not supported');

  Request.Target.Architecture := 'aarch64';
  Request.OutputKind := BUILD_OUTPUT_LIBRARY;
  Expect<Boolean>(BuildRequestIsCompatible(
    Request, Capabilities, Reason)).ToBe(False);
  Expect<string>(Reason).ToBe('output kind is not supported');
end;

procedure TLWPTBuildRequestTests.TestNormalisedBuildResultValidates;
var
  BuildResult: TLWPTBuildResult;
begin
  BuildResult := DefaultBuildResult;
  BuildResult.Success := True;
  SetLength(BuildResult.Diagnostics, 1);
  BuildResult.Diagnostics[0].Severity := DIAGNOSTIC_WARNING;
  BuildResult.Diagnostics[0].Code := 'W100';
  BuildResult.Diagnostics[0].MessageText := 'example warning';
  BuildResult.Diagnostics[0].Path := 'source/app.pas';
  BuildResult.Diagnostics[0].Line := 4;
  BuildResult.Diagnostics[0].Column := 2;
  SetLength(BuildResult.Artifacts, 1);
  BuildResult.Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
  BuildResult.Artifacts[0].Path := 'build/app';
  SetLength(BuildResult.Dependencies, 1);
  BuildResult.Dependencies[0].Name := 'example';
  BuildResult.Dependencies[0].Version := '1.0.0';
  BuildResult.Dependencies[0].Source := 'example/project';
  ValidateBuildResult(BuildResult);
  Expect<Boolean>(BuildResult.Success).ToBe(True);
end;

procedure TLWPTBuildRequestTests.SetupTests;
begin
  Test('serialization matches the versioned fixture',
    TestSerializationMatchesVersionedFixture);
  Test('fixture parses and serializes deterministically',
    TestFixtureParsesAndRoundTrips);
  Test('unsupported request schema fails clearly',
    TestUnsupportedSchemaFailsClearly);
  Test('one target tuple works across compatible compilers',
    TestTargetTupleWorksAcrossCompatibleCompilers);
  Test('one compiler advertises native and cross targets',
    TestCompilerCanAdvertiseMultipleTargets);
  Test('unsupported compatibility dimensions are explicit',
    TestCompatibilityRejectsUnsupportedDimensions);
  Test('normalised diagnostics, artifacts, and dependencies validate',
    TestNormalisedBuildResultValidates);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTBuildRequestTests.Create(
    'compiler-neutral build request'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
