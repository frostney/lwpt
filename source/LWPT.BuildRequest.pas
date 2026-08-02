{ LWPT.BuildRequest — compiler-neutral build intent and result contract. }
unit LWPT.BuildRequest;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

const
  COMPILER_PROBE_REQUEST_SCHEMA_VERSION = 1;
  BUILD_REQUEST_SCHEMA_VERSION = 2;
  BUILD_RESULT_SCHEMA_VERSION = 1;
  COMPILER_CAPABILITIES_SCHEMA_VERSION = 1;

  BUILD_OUTPUT_EXECUTABLE = 'executable';
  BUILD_OUTPUT_LIBRARY = 'library';
  BUILD_OUTPUT_UNIT = 'unit';

  BUILD_MODE_DEV = 'dev';
  BUILD_MODE_RELEASE = 'release';

  DIAGNOSTIC_INFO = 'info';
  DIAGNOSTIC_WARNING = 'warning';
  DIAGNOSTIC_ERROR = 'error';

type
  ELWPTBuildRequestError = class(ELWPTError);

  TLWPTCompilerRequest = record
    ID: string;
    VersionConstraint: string;
    VersionIdentity: string;
  end;

  TLWPTTarget = record
    OS: string;
    Architecture: string;
    ABI: string;
    Environment: string;
  end;
  TLWPTTargetArray = array of TLWPTTarget;

  TLWPTCompilerProbeRequest = record
    SchemaVersion: Integer;
    Compiler: TLWPTCompilerRequest;
    Target: TLWPTTarget;
  end;

  TLWPTBuildInputs = record
    Sources: TStringArray;
    EntryPoint: string;
    Defines: TStringArray;
    ExtraArguments: TStringArray;
    UnitPaths: TStringArray;
    IncludePaths: TStringArray;
    Resources: TStringArray;
  end;

  TLWPTBuildOutputs = record
    Artifact: string;
    ExecutableDirectory: string;
    UnitDirectory: string;
    ObjectDirectory: string;
    ResourceDirectory: string;
  end;

  TLWPTBuildRequest = record
    SchemaVersion: Integer;
    Compiler: TLWPTCompilerRequest;
    Target: TLWPTTarget;
    OutputKind: string;
    Mode: string;
    Inputs: TLWPTBuildInputs;
    Outputs: TLWPTBuildOutputs;
  end;

  TLWPTDiagnostic = record
    Severity: string;
    Code: string;
    MessageText: string;
    Path: string;
    Line: Integer;
    Column: Integer;
  end;
  TLWPTDiagnosticArray = array of TLWPTDiagnostic;

  TLWPTArtifact = record
    Kind: string;
    Path: string;
    Digest: string;
  end;
  TLWPTArtifactArray = array of TLWPTArtifact;

  TLWPTDependencyMetadata = record
    Name: string;
    Version: string;
    Source: string;
  end;
  TLWPTDependencyMetadataArray = array of TLWPTDependencyMetadata;

  TLWPTBuildResult = record
    SchemaVersion: Integer;
    Success: Boolean;
    Diagnostics: TLWPTDiagnosticArray;
    Artifacts: TLWPTArtifactArray;
    Dependencies: TLWPTDependencyMetadataArray;
  end;

  TLWPTCompilerCapabilities = record
    SchemaVersion: Integer;
    CompilerID: string;
    VersionIdentity: string;
    Targets: TLWPTTargetArray;
    OutputKinds: TStringArray;
    Modes: TStringArray;
  end;

function DefaultBuildRequest: TLWPTBuildRequest;
function DefaultBuildResult: TLWPTBuildResult;
function DefaultCompilerCapabilities: TLWPTCompilerCapabilities;
function DefaultCompilerProbeRequest: TLWPTCompilerProbeRequest;
procedure ValidateCompilerProbeRequest(
  const ARequest: TLWPTCompilerProbeRequest);
procedure ValidateBuildRequest(const ARequest: TLWPTBuildRequest);
procedure ValidateBuildResult(const AResult: TLWPTBuildResult);
procedure ValidateCompilerCapabilities(
  const ACapabilities: TLWPTCompilerCapabilities);
function SerializeBuildRequest(const ARequest: TLWPTBuildRequest): string;
function ParseBuildRequest(const AText: string): TLWPTBuildRequest;
function SerializeCompilerProbeRequest(
  const ARequest: TLWPTCompilerProbeRequest): string;
function ParseCompilerProbeRequest(
  const AText: string): TLWPTCompilerProbeRequest;
function SerializeBuildResult(const AResult: TLWPTBuildResult): string;
function ParseBuildResult(const AText: string): TLWPTBuildResult;
function SerializeCompilerCapabilities(
  const ACapabilities: TLWPTCompilerCapabilities): string;
function ParseCompilerCapabilities(
  const AText: string): TLWPTCompilerCapabilities;
function BuildRequestIsCompatible(const ARequest: TLWPTBuildRequest;
  const ACapabilities: TLWPTCompilerCapabilities;
  out AReason: string): Boolean;

implementation

uses
  Classes,

  Semver,
  TOML;

function DefaultBuildRequest: TLWPTBuildRequest;
begin
  Result := Default(TLWPTBuildRequest);
  Result.SchemaVersion := BUILD_REQUEST_SCHEMA_VERSION;
end;

function DefaultBuildResult: TLWPTBuildResult;
begin
  Result := Default(TLWPTBuildResult);
  Result.SchemaVersion := BUILD_RESULT_SCHEMA_VERSION;
end;

function DefaultCompilerCapabilities: TLWPTCompilerCapabilities;
begin
  Result := Default(TLWPTCompilerCapabilities);
  Result.SchemaVersion := COMPILER_CAPABILITIES_SCHEMA_VERSION;
end;

function DefaultCompilerProbeRequest: TLWPTCompilerProbeRequest;
begin
  Result := Default(TLWPTCompilerProbeRequest);
  Result.SchemaVersion := COMPILER_PROBE_REQUEST_SCHEMA_VERSION;
end;

procedure RequireSupportedSchema(const AName: string;
  const AActual, ASupported: Integer);
begin
  if AActual <> ASupported then
    raise ELWPTBuildRequestError.CreateFmt(
      'unsupported %s schema version %d; this %s supports version %d',
      [AName, AActual, PROGRAM_NAME, ASupported]);
end;

procedure RequireValue(const AName, AValue: string);
begin
  if AValue = '' then
    raise ELWPTBuildRequestError.CreateFmt(
      'build request field %s must not be empty', [AName]);
end;

function StringArrayContains(const AValues: array of string;
  const AValue: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AValues) do
    if AValues[i] = AValue then Exit(True);
  Result := False;
end;

procedure ValidateTarget(const ATarget: TLWPTTarget;
  const AContext: string);
begin
  if ATarget.OS = '' then
    raise ELWPTBuildRequestError.CreateFmt(
      '%s target OS must not be empty', [AContext]);
  if ATarget.Architecture = '' then
    raise ELWPTBuildRequestError.CreateFmt(
      '%s target architecture must not be empty', [AContext]);
end;

procedure ValidateCompilerProbeRequest(
  const ARequest: TLWPTCompilerProbeRequest);
begin
  RequireSupportedSchema('compiler probe request', ARequest.SchemaVersion,
    COMPILER_PROBE_REQUEST_SCHEMA_VERSION);
  RequireValue('compiler.id', ARequest.Compiler.ID);
  if (ARequest.Compiler.VersionConstraint = '')
     and (ARequest.Compiler.VersionIdentity = '') then
    raise ELWPTBuildRequestError.Create(
      'compiler probe request needs compiler.version_constraint or '
      + 'compiler.version_identity');
  if (ARequest.Target.OS = '') xor (ARequest.Target.Architecture = '') then
    raise ELWPTBuildRequestError.Create(
      'compiler probe target needs both OS and architecture or neither');
end;

procedure ValidateBuildRequest(const ARequest: TLWPTBuildRequest);
var
  i: Integer;
begin
  RequireSupportedSchema('build request', ARequest.SchemaVersion,
    BUILD_REQUEST_SCHEMA_VERSION);
  RequireValue('compiler.id', ARequest.Compiler.ID);
  if (ARequest.Compiler.VersionConstraint = '')
     and (ARequest.Compiler.VersionIdentity = '') then
    raise ELWPTBuildRequestError.Create(
      'build request needs compiler.version_constraint or '
      + 'compiler.version_identity');
  ValidateTarget(ARequest.Target, 'build request');
  if not StringArrayContains([
    BUILD_OUTPUT_EXECUTABLE, BUILD_OUTPUT_LIBRARY, BUILD_OUTPUT_UNIT],
    ARequest.OutputKind) then
    raise ELWPTBuildRequestError.CreateFmt(
      'unsupported build output kind "%s"', [ARequest.OutputKind]);
  if not StringArrayContains([BUILD_MODE_DEV, BUILD_MODE_RELEASE],
    ARequest.Mode) then
    raise ELWPTBuildRequestError.CreateFmt(
      'unsupported build mode "%s"', [ARequest.Mode]);
  RequireValue('inputs.entry_point', ARequest.Inputs.EntryPoint);
  if Length(ARequest.Inputs.Sources) = 0 then
    raise ELWPTBuildRequestError.Create(
      'build request needs at least one source');
  for i := 0 to High(ARequest.Inputs.Sources) do
    if ARequest.Inputs.Sources[i] = '' then
      raise ELWPTBuildRequestError.CreateFmt(
        'build request source %d must not be empty', [i]);
  for i := 0 to High(ARequest.Inputs.ExtraArguments) do
    if ARequest.Inputs.ExtraArguments[i] = '' then
      raise ELWPTBuildRequestError.CreateFmt(
        'build request extra argument %d must not be empty', [i]);
  if not StringArrayContains(ARequest.Inputs.Sources,
    ARequest.Inputs.EntryPoint) then
    raise ELWPTBuildRequestError.Create(
      'build request entry point must be present in the source set');
  RequireValue('outputs.artifact', ARequest.Outputs.Artifact);
end;

procedure ValidateBuildResult(const AResult: TLWPTBuildResult);
var
  i: Integer;
begin
  RequireSupportedSchema('build result', AResult.SchemaVersion,
    BUILD_RESULT_SCHEMA_VERSION);
  for i := 0 to High(AResult.Diagnostics) do
  begin
    if not StringArrayContains([
      DIAGNOSTIC_INFO, DIAGNOSTIC_WARNING, DIAGNOSTIC_ERROR],
      AResult.Diagnostics[i].Severity) then
      raise ELWPTBuildRequestError.CreateFmt(
        'unsupported diagnostic severity "%s"',
        [AResult.Diagnostics[i].Severity]);
    if AResult.Diagnostics[i].MessageText = '' then
      raise ELWPTBuildRequestError.Create(
        'diagnostic message must not be empty');
  end;
  for i := 0 to High(AResult.Artifacts) do
  begin
    if AResult.Artifacts[i].Kind = '' then
      raise ELWPTBuildRequestError.Create(
        'artifact kind must not be empty');
    if AResult.Artifacts[i].Path = '' then
      raise ELWPTBuildRequestError.Create(
        'artifact path must not be empty');
  end;
  for i := 0 to High(AResult.Dependencies) do
    if AResult.Dependencies[i].Name = '' then
      raise ELWPTBuildRequestError.Create(
        'dependency name must not be empty');
end;

procedure ValidateCompilerCapabilities(
  const ACapabilities: TLWPTCompilerCapabilities);
var
  i: Integer;
begin
  RequireSupportedSchema('compiler capabilities',
    ACapabilities.SchemaVersion, COMPILER_CAPABILITIES_SCHEMA_VERSION);
  if ACapabilities.CompilerID = '' then
    raise ELWPTBuildRequestError.Create(
      'compiler capabilities need a compiler ID');
  if ACapabilities.VersionIdentity = '' then
    raise ELWPTBuildRequestError.Create(
      'compiler capabilities need a version identity');
  if Length(ACapabilities.Targets) = 0 then
    raise ELWPTBuildRequestError.Create(
      'compiler capabilities need at least one target');
  for i := 0 to High(ACapabilities.Targets) do
    ValidateTarget(ACapabilities.Targets[i], 'compiler capability');
  if Length(ACapabilities.OutputKinds) = 0 then
    raise ELWPTBuildRequestError.Create(
      'compiler capabilities need at least one output kind');
  for i := 0 to High(ACapabilities.OutputKinds) do
    if not StringArrayContains([
      BUILD_OUTPUT_EXECUTABLE, BUILD_OUTPUT_LIBRARY, BUILD_OUTPUT_UNIT],
      ACapabilities.OutputKinds[i]) then
      raise ELWPTBuildRequestError.CreateFmt(
        'unsupported compiler capability output kind "%s"',
        [ACapabilities.OutputKinds[i]]);
  if Length(ACapabilities.Modes) = 0 then
    raise ELWPTBuildRequestError.Create(
      'compiler capabilities need at least one build mode');
  for i := 0 to High(ACapabilities.Modes) do
    if not StringArrayContains([BUILD_MODE_DEV, BUILD_MODE_RELEASE],
      ACapabilities.Modes[i]) then
      raise ELWPTBuildRequestError.CreateFmt(
        'unsupported compiler capability build mode "%s"',
        [ACapabilities.Modes[i]]);
end;

function TomlArray(const AValues: TStringArray): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(AValues) do
  begin
    if i > 0 then Result := Result + ', ';
    Result := Result + '"' + TomlEscape(AValues[i]) + '"';
  end;
  Result := Result + ']';
end;

function SerializeBuildRequest(const ARequest: TLWPTBuildRequest): string;
var
  Lines: TStringList;
begin
  ValidateBuildRequest(ARequest);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema = ' + IntToStr(ARequest.SchemaVersion));
    Lines.Add('output_kind = "' + TomlEscape(ARequest.OutputKind) + '"');
    Lines.Add('mode = "' + TomlEscape(ARequest.Mode) + '"');
    Lines.Add('');
    Lines.Add('[compiler]');
    Lines.Add('id = "' + TomlEscape(ARequest.Compiler.ID) + '"');
    Lines.Add('version_constraint = "'
      + TomlEscape(ARequest.Compiler.VersionConstraint) + '"');
    Lines.Add('version_identity = "'
      + TomlEscape(ARequest.Compiler.VersionIdentity) + '"');
    Lines.Add('');
    Lines.Add('[target]');
    Lines.Add('os = "' + TomlEscape(ARequest.Target.OS) + '"');
    Lines.Add('architecture = "'
      + TomlEscape(ARequest.Target.Architecture) + '"');
    Lines.Add('abi = "' + TomlEscape(ARequest.Target.ABI) + '"');
    Lines.Add('environment = "'
      + TomlEscape(ARequest.Target.Environment) + '"');
    Lines.Add('');
    Lines.Add('[inputs]');
    Lines.Add('entry_point = "'
      + TomlEscape(ARequest.Inputs.EntryPoint) + '"');
    Lines.Add('sources = ' + TomlArray(ARequest.Inputs.Sources));
    Lines.Add('defines = ' + TomlArray(ARequest.Inputs.Defines));
    Lines.Add('extra_arguments = '
      + TomlArray(ARequest.Inputs.ExtraArguments));
    Lines.Add('unit_paths = ' + TomlArray(ARequest.Inputs.UnitPaths));
    Lines.Add('include_paths = ' + TomlArray(ARequest.Inputs.IncludePaths));
    Lines.Add('resources = ' + TomlArray(ARequest.Inputs.Resources));
    Lines.Add('');
    Lines.Add('[outputs]');
    Lines.Add('artifact = "' + TomlEscape(ARequest.Outputs.Artifact) + '"');
    Lines.Add('executable_directory = "'
      + TomlEscape(ARequest.Outputs.ExecutableDirectory) + '"');
    Lines.Add('unit_directory = "'
      + TomlEscape(ARequest.Outputs.UnitDirectory) + '"');
    Lines.Add('object_directory = "'
      + TomlEscape(ARequest.Outputs.ObjectDirectory) + '"');
    Lines.Add('resource_directory = "'
      + TomlEscape(ARequest.Outputs.ResourceDirectory) + '"');
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure ReadStringArray(ANode: TTOMLNode; const AKey: string;
  var AValues: TStringArray);
var
  ArrayNode: TTOMLNode;
  i: Integer;
begin
  SetLength(AValues, 0);
  ArrayNode := TomlGet(ANode, AKey);
  if not TomlIsArray(ArrayNode) then Exit;
  SetLength(AValues, ArrayNode.Items.Count);
  for i := 0 to ArrayNode.Items.Count - 1 do
  begin
    if not TomlIsString(ArrayNode.Items[i]) then
      raise ELWPTBuildRequestError.CreateFmt(
        'build request %s[%d] must be a string', [AKey, i]);
    AValues[i] := ArrayNode.Items[i].ScalarText;
  end;
end;

function ParseBuildRequest(const AText: string): TLWPTBuildRequest;
var
  Parser: TTOMLParser;
  Root, Section: TTOMLNode;
begin
  Result := DefaultBuildRequest;
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    try
      Root := Parser.ParseDocument(AText);
    except
      on E: ETOMLParseError do
        raise ELWPTBuildRequestError.Create(
          'invalid build request TOML: ' + E.Message);
    end;
  finally
    Parser.Free;
  end;
  try
    Result.SchemaVersion := TomlInt(Root, 'schema', 0);
    Result.OutputKind := TomlStr(Root, 'output_kind', '');
    Result.Mode := TomlStr(Root, 'mode', '');

    Section := TomlGet(Root, 'compiler');
    Result.Compiler.ID := TomlStr(Section, 'id', '');
    Result.Compiler.VersionConstraint :=
      TomlStr(Section, 'version_constraint', '');
    Result.Compiler.VersionIdentity :=
      TomlStr(Section, 'version_identity', '');

    Section := TomlGet(Root, 'target');
    Result.Target.OS := TomlStr(Section, 'os', '');
    Result.Target.Architecture := TomlStr(Section, 'architecture', '');
    Result.Target.ABI := TomlStr(Section, 'abi', '');
    Result.Target.Environment := TomlStr(Section, 'environment', '');

    Section := TomlGet(Root, 'inputs');
    Result.Inputs.EntryPoint := TomlStr(Section, 'entry_point', '');
    ReadStringArray(Section, 'sources', Result.Inputs.Sources);
    ReadStringArray(Section, 'defines', Result.Inputs.Defines);
    ReadStringArray(Section, 'extra_arguments',
      Result.Inputs.ExtraArguments);
    ReadStringArray(Section, 'unit_paths', Result.Inputs.UnitPaths);
    ReadStringArray(Section, 'include_paths', Result.Inputs.IncludePaths);
    ReadStringArray(Section, 'resources', Result.Inputs.Resources);

    Section := TomlGet(Root, 'outputs');
    Result.Outputs.Artifact := TomlStr(Section, 'artifact', '');
    Result.Outputs.ExecutableDirectory :=
      TomlStr(Section, 'executable_directory', '');
    Result.Outputs.UnitDirectory :=
      TomlStr(Section, 'unit_directory', '');
    Result.Outputs.ObjectDirectory :=
      TomlStr(Section, 'object_directory', '');
    Result.Outputs.ResourceDirectory :=
      TomlStr(Section, 'resource_directory', '');
    ValidateBuildRequest(Result);
  finally
    Root.Free;
  end;
end;

function ParseProtocolDocument(const AText, AName: string): TTOMLNode;
var
  Parser: TTOMLParser;
begin
  Parser := TTOMLParser.Create;
  try
    try
      Result := Parser.ParseDocument(AText);
    except
      on E: ETOMLParseError do
        raise ELWPTBuildRequestError.Create(
          'invalid ' + AName + ' TOML: ' + E.Message);
    end;
  finally
    Parser.Free;
  end;
end;

procedure AddCompilerAndTarget(const ACompiler: TLWPTCompilerRequest;
  const ATarget: TLWPTTarget; const ALines: TStrings);
begin
  ALines.Add('[compiler]');
  ALines.Add('id = "' + TomlEscape(ACompiler.ID) + '"');
  ALines.Add('version_constraint = "'
    + TomlEscape(ACompiler.VersionConstraint) + '"');
  ALines.Add('version_identity = "'
    + TomlEscape(ACompiler.VersionIdentity) + '"');
  ALines.Add('');
  ALines.Add('[target]');
  ALines.Add('os = "' + TomlEscape(ATarget.OS) + '"');
  ALines.Add('architecture = "'
    + TomlEscape(ATarget.Architecture) + '"');
  ALines.Add('abi = "' + TomlEscape(ATarget.ABI) + '"');
  ALines.Add('environment = "' + TomlEscape(ATarget.Environment) + '"');
end;

function SerializeCompilerProbeRequest(
  const ARequest: TLWPTCompilerProbeRequest): string;
var
  Lines: TStringList;
begin
  ValidateCompilerProbeRequest(ARequest);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema = ' + IntToStr(ARequest.SchemaVersion));
    Lines.Add('');
    AddCompilerAndTarget(ARequest.Compiler, ARequest.Target, Lines);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function ParseCompilerProbeRequest(
  const AText: string): TLWPTCompilerProbeRequest;
var
  Root, Section: TTOMLNode;
begin
  Result := DefaultCompilerProbeRequest;
  Root := ParseProtocolDocument(AText, 'compiler probe request');
  try
    Result.SchemaVersion := TomlInt(Root, 'schema', 0);
    Section := TomlGet(Root, 'compiler');
    Result.Compiler.ID := TomlStr(Section, 'id', '');
    Result.Compiler.VersionConstraint := TomlStr(Section,
      'version_constraint', '');
    Result.Compiler.VersionIdentity := TomlStr(Section,
      'version_identity', '');
    Section := TomlGet(Root, 'target');
    Result.Target.OS := TomlStr(Section, 'os', '');
    Result.Target.Architecture := TomlStr(Section, 'architecture', '');
    Result.Target.ABI := TomlStr(Section, 'abi', '');
    Result.Target.Environment := TomlStr(Section, 'environment', '');
    ValidateCompilerProbeRequest(Result);
  finally
    Root.Free;
  end;
end;

function TomlBoolean(ANode: TTOMLNode; const AKey: string;
  const ADefault: Boolean): Boolean;
var
  ValueNode: TTOMLNode;
begin
  ValueNode := TomlGet(ANode, AKey);
  if (ValueNode = nil) or (ValueNode.Kind <> tnkScalar)
     or (ValueNode.ScalarKind <> tskBool) then Exit(ADefault);
  Result := ValueNode.ScalarText = 'true';
end;

function SerializeCompilerCapabilities(
  const ACapabilities: TLWPTCompilerCapabilities): string;
var
  Lines: TStringList;
  i: Integer;
begin
  ValidateCompilerCapabilities(ACapabilities);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema = ' + IntToStr(ACapabilities.SchemaVersion));
    Lines.Add('compiler_id = "' + TomlEscape(ACapabilities.CompilerID) + '"');
    Lines.Add('version_identity = "'
      + TomlEscape(ACapabilities.VersionIdentity) + '"');
    Lines.Add('output_kinds = ' + TomlArray(ACapabilities.OutputKinds));
    Lines.Add('modes = ' + TomlArray(ACapabilities.Modes));
    for i := 0 to High(ACapabilities.Targets) do
    begin
      Lines.Add('');
      Lines.Add('[[targets]]');
      Lines.Add('os = "' + TomlEscape(ACapabilities.Targets[i].OS) + '"');
      Lines.Add('architecture = "'
        + TomlEscape(ACapabilities.Targets[i].Architecture) + '"');
      Lines.Add('abi = "' + TomlEscape(ACapabilities.Targets[i].ABI) + '"');
      Lines.Add('environment = "'
        + TomlEscape(ACapabilities.Targets[i].Environment) + '"');
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function ParseCompilerCapabilities(
  const AText: string): TLWPTCompilerCapabilities;
var
  Root, Targets, TargetNode: TTOMLNode;
  i: Integer;
begin
  Result := DefaultCompilerCapabilities;
  Root := ParseProtocolDocument(AText, 'compiler capabilities');
  try
    Result.SchemaVersion := TomlInt(Root, 'schema', 0);
    Result.CompilerID := TomlStr(Root, 'compiler_id', '');
    Result.VersionIdentity := TomlStr(Root, 'version_identity', '');
    ReadStringArray(Root, 'output_kinds', Result.OutputKinds);
    ReadStringArray(Root, 'modes', Result.Modes);
    Targets := TomlGet(Root, 'targets');
    if TomlIsArray(Targets) then
    begin
      SetLength(Result.Targets, Targets.Items.Count);
      for i := 0 to Targets.Items.Count - 1 do
      begin
        TargetNode := Targets.Items[i];
        Result.Targets[i].OS := TomlStr(TargetNode, 'os', '');
        Result.Targets[i].Architecture := TomlStr(TargetNode,
          'architecture', '');
        Result.Targets[i].ABI := TomlStr(TargetNode, 'abi', '');
        Result.Targets[i].Environment := TomlStr(TargetNode,
          'environment', '');
      end;
    end;
    ValidateCompilerCapabilities(Result);
  finally
    Root.Free;
  end;
end;

function SerializeBuildResult(const AResult: TLWPTBuildResult): string;
var
  Lines: TStringList;
  i: Integer;
begin
  ValidateBuildResult(AResult);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema = ' + IntToStr(AResult.SchemaVersion));
    if AResult.Success then Lines.Add('success = true')
    else Lines.Add('success = false');
    for i := 0 to High(AResult.Diagnostics) do
    begin
      Lines.Add('');
      Lines.Add('[[diagnostics]]');
      Lines.Add('severity = "'
        + TomlEscape(AResult.Diagnostics[i].Severity) + '"');
      Lines.Add('code = "' + TomlEscape(AResult.Diagnostics[i].Code) + '"');
      Lines.Add('message = "'
        + TomlEscape(AResult.Diagnostics[i].MessageText) + '"');
      Lines.Add('path = "' + TomlEscape(AResult.Diagnostics[i].Path) + '"');
      Lines.Add('line = ' + IntToStr(AResult.Diagnostics[i].Line));
      Lines.Add('column = ' + IntToStr(AResult.Diagnostics[i].Column));
    end;
    for i := 0 to High(AResult.Artifacts) do
    begin
      Lines.Add('');
      Lines.Add('[[artifacts]]');
      Lines.Add('kind = "' + TomlEscape(AResult.Artifacts[i].Kind) + '"');
      Lines.Add('path = "' + TomlEscape(AResult.Artifacts[i].Path) + '"');
      Lines.Add('digest = "' + TomlEscape(AResult.Artifacts[i].Digest) + '"');
    end;
    for i := 0 to High(AResult.Dependencies) do
    begin
      Lines.Add('');
      Lines.Add('[[dependencies]]');
      Lines.Add('name = "'
        + TomlEscape(AResult.Dependencies[i].Name) + '"');
      Lines.Add('version = "'
        + TomlEscape(AResult.Dependencies[i].Version) + '"');
      Lines.Add('source = "'
        + TomlEscape(AResult.Dependencies[i].Source) + '"');
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function ParseBuildResult(const AText: string): TLWPTBuildResult;
var
  Root, Values, ValueNode: TTOMLNode;
  i: Integer;
begin
  Result := DefaultBuildResult;
  Root := ParseProtocolDocument(AText, 'build result');
  try
    Result.SchemaVersion := TomlInt(Root, 'schema', 0);
    Result.Success := TomlBoolean(Root, 'success', False);
    Values := TomlGet(Root, 'diagnostics');
    if TomlIsArray(Values) then
    begin
      SetLength(Result.Diagnostics, Values.Items.Count);
      for i := 0 to Values.Items.Count - 1 do
      begin
        ValueNode := Values.Items[i];
        Result.Diagnostics[i].Severity := TomlStr(ValueNode, 'severity', '');
        Result.Diagnostics[i].Code := TomlStr(ValueNode, 'code', '');
        Result.Diagnostics[i].MessageText := TomlStr(ValueNode, 'message', '');
        Result.Diagnostics[i].Path := TomlStr(ValueNode, 'path', '');
        Result.Diagnostics[i].Line := TomlInt(ValueNode, 'line', 0);
        Result.Diagnostics[i].Column := TomlInt(ValueNode, 'column', 0);
      end;
    end;
    Values := TomlGet(Root, 'artifacts');
    if TomlIsArray(Values) then
    begin
      SetLength(Result.Artifacts, Values.Items.Count);
      for i := 0 to Values.Items.Count - 1 do
      begin
        ValueNode := Values.Items[i];
        Result.Artifacts[i].Kind := TomlStr(ValueNode, 'kind', '');
        Result.Artifacts[i].Path := TomlStr(ValueNode, 'path', '');
        Result.Artifacts[i].Digest := TomlStr(ValueNode, 'digest', '');
      end;
    end;
    Values := TomlGet(Root, 'dependencies');
    if TomlIsArray(Values) then
    begin
      SetLength(Result.Dependencies, Values.Items.Count);
      for i := 0 to Values.Items.Count - 1 do
      begin
        ValueNode := Values.Items[i];
        Result.Dependencies[i].Name := TomlStr(ValueNode, 'name', '');
        Result.Dependencies[i].Version := TomlStr(ValueNode, 'version', '');
        Result.Dependencies[i].Source := TomlStr(ValueNode, 'source', '');
      end;
    end;
    ValidateBuildResult(Result);
  finally
    Root.Free;
  end;
end;

function TargetMatches(const ARequested, AAvailable: TLWPTTarget): Boolean;
begin
  Result := (ARequested.OS = AAvailable.OS)
    and (ARequested.Architecture = AAvailable.Architecture)
    and ((ARequested.ABI = '') or (ARequested.ABI = AAvailable.ABI))
    and ((ARequested.Environment = '')
      or (ARequested.Environment = AAvailable.Environment));
end;

function BuildRequestIsCompatible(const ARequest: TLWPTBuildRequest;
  const ACapabilities: TLWPTCompilerCapabilities;
  out AReason: string): Boolean;
var
  i: Integer;
begin
  ValidateBuildRequest(ARequest);
  ValidateCompilerCapabilities(ACapabilities);
  AReason := '';
  if ARequest.Compiler.ID <> ACapabilities.CompilerID then
    AReason := 'compiler ID is not supported'
  else if (ARequest.Compiler.VersionIdentity <> '')
    and (ARequest.Compiler.VersionIdentity
      <> ACapabilities.VersionIdentity) then
    AReason := 'compiler version identity is not supported'
  else if (ARequest.Compiler.VersionConstraint <> '') then
  begin
    try
      if not Satisfies(ACapabilities.VersionIdentity,
        ARequest.Compiler.VersionConstraint, DefaultSemverOptions) then
        AReason := 'compiler version constraint is not satisfied';
    except
      on E: ESemverError do
        raise ELWPTBuildRequestError.Create(
          'invalid compiler version constraint: ' + E.Message);
    end;
  end;
  if AReason = '' then
  begin
    AReason := 'target tuple is not supported';
    for i := 0 to High(ACapabilities.Targets) do
      if TargetMatches(ARequest.Target, ACapabilities.Targets[i]) then
      begin
        AReason := '';
        Break;
      end;
  end;
  if (AReason = '') and (not StringArrayContains(
    ACapabilities.OutputKinds, ARequest.OutputKind)) then
    AReason := 'output kind is not supported';
  if (AReason = '') and (not StringArrayContains(
    ACapabilities.Modes, ARequest.Mode)) then
    AReason := 'build mode is not supported';
  Result := AReason = '';
end;

end.
