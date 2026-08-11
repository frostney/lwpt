{ LWPT.CompilerDriver.Delphi — Delphi command-line compiler adapter. }
unit LWPT.CompilerDriver.Delphi;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core;

const
  DELPHI_COMPILER_ID = 'delphi';
  DELPHI_MINIMUM_VERSION = '36.0.0';

type
  TLWPTDelphiCompilerDriver = class(TLWPTCompilerDriver)
  private
    FExecutableName: string;
    FVersionConstraint: string;
    function ExecutableTarget: TLWPTTarget;
  protected
    function GeneratedArtifactPath(const ARequest: TLWPTBuildRequest):
      string;
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AOutput: string): Integer; virtual;
  public
    constructor Create(const AExecutableName: string = '';
      const AVersionConstraint: string = '*');
    function CompilerID: string; override;
    function VersionConstraint: string; override;
    function DefaultTarget: TLWPTTarget; override;
    function ProbeCapabilities(const ATarget: TLWPTTarget;
      const ARefresh: Boolean = False): TLWPTCompilerCapabilities; override;
    function BuildArguments(const ARequest: TLWPTBuildRequest;
      const AOptions: TLWPTCompilerInvocationOptions):
      LWPT.Core.TStringArray; override;
    function ExecutableName: string; override;
    function ClassifyFailure(const AExitCode: Integer;
      const ARawOutput: string): TLWPTCompilerFailure; override;
    function NormalizeResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const ARawOutput: string):
      TLWPTBuildResult; override;
  end;

implementation

uses
  Classes,
  Process,
  StrUtils,
  SysUtils,

  LWPT.BuildSession,
  LWPT.ProcessRunner,
  Semver;

const
  DELPHI_HELP_FLAG = '-h';
  DELPHI_HELP_TIMEOUT_MILLISECONDS = 30000;
  DELPHI_PROBE_DIAGNOSTIC_CONTEXT_BYTES = 4096;
  DELPHI_IDENTITY_PREFIX = 'Embarcadero Delphi for ';
  DELPHI_VERSION_MARKER = ' compiler version ';
  DELPHI_DEFAULT_EXECUTABLE = 'dcc32';
  DELPHI_FORCE_REBUILD_FLAG = '-B';
  DELPHI_EXECUTABLE_OUTPUT_FLAG = '-E';
  DELPHI_UNIT_OUTPUT_FLAG = '-NU';
  DELPHI_OBJECT_OUTPUT_FLAG = '-NO';
  DELPHI_UNIT_PATH_FLAG = '-U';
  DELPHI_INCLUDE_PATH_FLAG = '-I';
  DELPHI_RESOURCE_PATH_FLAG = '-R';
  DELPHI_DEFINE_FLAG = '-D';
  DELPHI_EXTENSION_FLAG = '-TX';
  DELPHI_DEV_OPTIMIZATION_FLAG = '-$O-';
  DELPHI_DEV_DEBUG_FLAG = '-$D+';
  DELPHI_DEV_LOCAL_SYMBOL_FLAG = '-$L+';
  DELPHI_DEV_ASSERTION_FLAG = '-$C+';
  DELPHI_DEV_RANGE_FLAG = '-$R+';
  DELPHI_RELEASE_OPTIMIZATION_FLAG = '-$O+';
  DELPHI_RELEASE_DEBUG_FLAG = '-$D-';
  DELPHI_RELEASE_LOCAL_SYMBOL_FLAG = '-$L-';
  DELPHI_RELEASE_ASSERTION_FLAG = '-$C-';
  DELPHI_RELEASE_RANGE_FLAG = '-$R-';

function TargetsEqual(const ALeft, ARight: TLWPTTarget): Boolean;
begin
  Result := SameText(ALeft.OS, ARight.OS)
    and SameText(ALeft.Architecture, ARight.Architecture)
    and ((ALeft.ABI = '') or (ARight.ABI = '')
      or SameText(ALeft.ABI, ARight.ABI))
    and ((ALeft.Environment = '') or (ARight.Environment = '')
      or SameText(ALeft.Environment, ARight.Environment));
end;

function ExecutableBaseName(const APath: string): string;
begin
  Result := LowerCase(ChangeFileExt(ExtractFileName(APath), ''));
end;

function TargetForExecutable(const APath: string;
  out ATarget: TLWPTTarget): Boolean;
var
  BaseName: string;
begin
  ATarget := Default(TLWPTTarget);
  BaseName := ExecutableBaseName(APath);
  if BaseName = 'dcc32' then
  begin
    ATarget.OS := 'win32';
    ATarget.Architecture := 'i386';
  end
  else if BaseName = 'dcc64' then
  begin
    ATarget.OS := 'win64';
    ATarget.Architecture := 'x86_64';
  end
  else if BaseName = 'dcclinux64' then
  begin
    ATarget.OS := 'linux';
    ATarget.Architecture := 'x86_64';
  end
  else if BaseName = 'dccosx64' then
  begin
    ATarget.OS := 'darwin';
    ATarget.Architecture := 'x86_64';
  end
  else if BaseName = 'dccosxarm64' then
  begin
    ATarget.OS := 'darwin';
    ATarget.Architecture := 'aarch64';
  end;
  Result := ATarget.OS <> '';
end;

function TargetForProductLabel(const ALabel: string;
  out ATarget: TLWPTTarget): Boolean;
var
  LabelText: string;
begin
  ATarget := Default(TLWPTTarget);
  LabelText := LowerCase(Trim(ALabel));
  if Pos('win32', LabelText) > 0 then
  begin
    ATarget.OS := 'win32';
    ATarget.Architecture := 'i386';
  end
  else if Pos('win64', LabelText) > 0 then
  begin
    ATarget.OS := 'win64';
    ATarget.Architecture := 'x86_64';
  end
  else if Pos('linux 64', LabelText) > 0 then
  begin
    ATarget.OS := 'linux';
    ATarget.Architecture := 'x86_64';
  end
  else if ((Pos('mac os x', LabelText) > 0)
      or (Pos('macos', LabelText) > 0))
      and (Pos('64', LabelText) > 0) then
  begin
    ATarget.OS := 'darwin';
    if Pos('arm', LabelText) > 0 then
      ATarget.Architecture := 'aarch64'
    else
      ATarget.Architecture := 'x86_64';
  end;
  Result := ATarget.OS <> '';
end;

function NormalizeVersion(const AVersion: string): string;
var
  DotCount, i: Integer;
begin
  Result := Trim(AVersion);
  DotCount := 0;
  for i := 1 to Length(Result) do
    if Result[i] = '.' then Inc(DotCount);
  while DotCount < 2 do
  begin
    Result := Result + '.0';
    Inc(DotCount);
  end;
end;

function ParseProbeOutput(const AOutput: string; out AVersion: string;
  out ATarget: TLWPTTarget): Boolean;
var
  IdentityAt, LineEnd, MarkerAt, VersionEnd: Integer;
  LabelText, OutputText: string;
begin
  AVersion := '';
  ATarget := Default(TLWPTTarget);
  OutputText := StringReplace(AOutput, #13, '', [rfReplaceAll]);
  IdentityAt := Pos(DELPHI_IDENTITY_PREFIX, OutputText);
  if IdentityAt = 0 then Exit(False);
  LineEnd := PosEx(#10, OutputText, IdentityAt);
  if LineEnd = 0 then LineEnd := Length(OutputText) + 1;
  MarkerAt := PosEx(DELPHI_VERSION_MARKER, OutputText, IdentityAt);
  if (MarkerAt = 0) or (MarkerAt >= LineEnd) then Exit(False);
  LabelText := Copy(OutputText, IdentityAt + Length(DELPHI_IDENTITY_PREFIX),
    MarkerAt - IdentityAt - Length(DELPHI_IDENTITY_PREFIX));
  VersionEnd := MarkerAt + Length(DELPHI_VERSION_MARKER);
  while (VersionEnd < LineEnd)
    and (OutputText[VersionEnd] > ' ') do Inc(VersionEnd);
  AVersion := NormalizeVersion(Copy(OutputText,
    MarkerAt + Length(DELPHI_VERSION_MARKER),
    VersionEnd - MarkerAt - Length(DELPHI_VERSION_MARKER)));
  Result := (AVersion <> '') and TargetForProductLabel(LabelText, ATarget);
end;

function BoundedProbeDiagnosticContext(const AOutput: string): string;
begin
  Result := Trim(AOutput);
  if Length(Result) > DELPHI_PROBE_DIAGNOSTIC_CONTEXT_BYTES then
    Result := Copy(Result,
      Length(Result) - DELPHI_PROBE_DIAGNOSTIC_CONTEXT_BYTES + 1,
      DELPHI_PROBE_DIAGNOSTIC_CONTEXT_BYTES);
  if Result <> '' then Result := '; output: ' + Result;
end;

function DiscoverDelphiExecutable: string;
var
  BinDirectory, Candidate, InstallDirectory: string;
begin
  BinDirectory := GetEnvironmentVariable('BDSBIN');
  if BinDirectory <> '' then
  begin
    Candidate := IncludeTrailingPathDelimiter(BinDirectory)
      + DELPHI_DEFAULT_EXECUTABLE + '.exe';
    if FileExists(Candidate) then Exit(Candidate);
  end;
  InstallDirectory := GetEnvironmentVariable('BDS');
  if InstallDirectory <> '' then
  begin
    Candidate := IncludeTrailingPathDelimiter(InstallDirectory)
      + 'bin' + PathDelim + DELPHI_DEFAULT_EXECUTABLE + '.exe';
    if FileExists(Candidate) then Exit(Candidate);
  end;
  Result := DELPHI_DEFAULT_EXECUTABLE;
end;

constructor TLWPTDelphiCompilerDriver.Create(const AExecutableName: string;
  const AVersionConstraint: string);
begin
  inherited Create;
  if AExecutableName = '' then
    FExecutableName := DiscoverDelphiExecutable
  else
    FExecutableName := AExecutableName;
  FVersionConstraint := AVersionConstraint;
end;

function TLWPTDelphiCompilerDriver.CompilerID: string;
begin
  Result := DELPHI_COMPILER_ID;
end;

function TLWPTDelphiCompilerDriver.VersionConstraint: string;
begin
  Result := FVersionConstraint;
end;

function TLWPTDelphiCompilerDriver.ExecutableTarget: TLWPTTarget;
var
  i: Integer;
  CommandName: string;
begin
  CommandName := ConfiguredCommand(FExecutableName);
  if TargetForExecutable(CommandName, Result) then Exit;
  for i := 0 to CommandArgumentCount - 1 do
    if TargetForExecutable(CommandArgument(i), Result) then Exit;
  raise ELWPTCompilerDriverError.CreateFmt(
    'compiler "%s" executable "%s" is not a verified Delphi command-line '
    + 'compiler; expected dcc32, dcc64, dcclinux64, dccosx64, or '
    + 'dccosxarm64', [DELPHI_COMPILER_ID, CommandName]);
end;

function TLWPTDelphiCompilerDriver.DefaultTarget: TLWPTTarget;
begin
  Result := ExecutableTarget;
end;

function TLWPTDelphiCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AOutput: string): Integer;
var
  i: Integer;
  Options: TLWPTProcessRunOptions;
  ProcessRunner: TLWPTDuplexProcessRunner;
  StandardError: string;
  CompilerProcess: TProcess;
begin
  CompilerProcess := TProcess.Create(nil);
  try
    CompilerProcess.Executable := ConfiguredCommand(FExecutableName);
    if WorkingDirectory <> '' then
      CompilerProcess.CurrentDirectory := WorkingDirectory;
    AppendCommandArguments(CompilerProcess.Parameters);
    for i := 0 to High(AArguments) do
      CompilerProcess.Parameters.Add(AArguments[i]);
    ProcessRunner := TLWPTDuplexProcessRunner.Create(CompilerProcess);
    try
      Options := DefaultProcessRunOptions('Delphi compiler probe');
      Options.TimeoutMilliseconds := DELPHI_HELP_TIMEOUT_MILLISECONDS;
      Result := ProcessRunner.Run('', Options, AOutput, StandardError);
      if StandardError <> '' then
      begin
        if (AOutput <> '') and not (AOutput[Length(AOutput)] in [#10, #13]) then
          AOutput := AOutput + LineEnding;
        AOutput := AOutput + StandardError;
      end;
    finally
      ProcessRunner.Free;
    end;
  finally
    CompilerProcess.Free;
  end;
end;

function TLWPTDelphiCompilerDriver.ProbeCapabilities(
  const ATarget: TLWPTTarget; const ARefresh: Boolean):
  TLWPTCompilerCapabilities;
var
  ActualTarget, ExpectedTarget: TLWPTTarget;
  Arguments: LWPT.Core.TStringArray;
  ExitCode: Integer;
  Output, Version: string;
begin
  ExpectedTarget := ExecutableTarget;
  SetLength(Arguments, 1);
  Arguments[0] := DELPHI_HELP_FLAG;
  try
    ExitCode := ExecuteProbe(Arguments, Output);
  except
    on E: Exception do
      raise ELWPTCompilerDriverError.CreateFmt(
        'could not execute Delphi compiler probe via "%s": %s',
        [FExecutableName, E.Message]);
  end;
  if ExitCode <> 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'Delphi compiler probe via "%s" failed with exit %d%s',
      [FExecutableName, ExitCode, BoundedProbeDiagnosticContext(Output)]);
  if not ParseProbeOutput(Output, Version, ActualTarget) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'Delphi compiler probe via "%s" did not report a supported '
      + 'Embarcadero Delphi identity, version, and target%s',
      [FExecutableName, BoundedProbeDiagnosticContext(Output)]);
  if not TargetsEqual(ExpectedTarget, ActualTarget) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'Delphi compiler executable "%s" identifies target "%s/%s", '
      + 'but its executable name selects "%s/%s"',
      [FExecutableName, ActualTarget.OS, ActualTarget.Architecture,
       ExpectedTarget.OS, ExpectedTarget.Architecture]);
  try
    if not Satisfies(Version, '>=' + DELPHI_MINIMUM_VERSION,
      DefaultSemverOptions) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'Delphi compiler version "%s" is unsupported; %s requires Delphi '
        + '12 Athens (%s) or newer',
        [Version, PROJECT_NAME, DELPHI_MINIMUM_VERSION]);
  except
    on E: ESemverError do
      raise ELWPTCompilerDriverError.CreateFmt(
        'Delphi compiler probe returned invalid version "%s": %s',
        [Version, E.Message]);
  end;
  if not TargetsEqual(ATarget, ActualTarget) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" executable "%s" supports target "%s/%s", not '
      + 'requested target "%s/%s"; select a profile with the matching '
      + 'Delphi compiler executable',
      [DELPHI_COMPILER_ID, FExecutableName, ActualTarget.OS,
       ActualTarget.Architecture, ATarget.OS, ATarget.Architecture]);
  Result := DefaultCompilerCapabilities;
  Result.CompilerID := DELPHI_COMPILER_ID;
  Result.VersionIdentity := Version;
  SetLength(Result.Targets, 1);
  Result.Targets[0] := ActualTarget;
  SetLength(Result.OutputKinds, 2);
  Result.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
  Result.OutputKinds[1] := BUILD_OUTPUT_LIBRARY;
  SetLength(Result.Modes, 2);
  Result.Modes[0] := BUILD_MODE_DEV;
  Result.Modes[1] := BUILD_MODE_RELEASE;
  ValidateCompilerCapabilities(Result);
end;

procedure AddNonEmptyPaths(const AFlag: string; const APaths: TStringArray;
  const AArguments: TStrings);
var
  i: Integer;
begin
  for i := 0 to High(APaths) do
    if APaths[i] <> '' then AArguments.Add(AFlag + APaths[i]);
end;

procedure AddConfigurationUnitPaths(const AConfigurationFile: string;
  const AArguments: TStrings);
var
  Paths: TStringArray;
begin
  SetLength(Paths, 0);
  AppendUnitDirsFromCfg(AConfigurationFile, Paths);
  AddNonEmptyPaths(DELPHI_UNIT_PATH_FLAG, Paths, AArguments);
end;

procedure AddResourcePaths(const AResources: TStringArray;
  const AArguments: TStrings);
var
  Directories: TStringList;
  DirectoryName: string;
  i: Integer;
begin
  Directories := TStringList.Create;
  try
    Directories.CaseSensitive := False;
    Directories.Duplicates := dupIgnore;
    Directories.Sorted := True;
    for i := 0 to High(AResources) do
    begin
      DirectoryName := ExtractFileDir(AResources[i]);
      if DirectoryName = '' then DirectoryName := '.';
      Directories.Add(DirectoryName);
    end;
    if Directories.Count > 0 then
    begin
      DirectoryName := Directories[0];
      for i := 1 to Directories.Count - 1 do
        DirectoryName := DirectoryName + ';' + Directories[i];
      AArguments.Add(DELPHI_RESOURCE_PATH_FLAG + DirectoryName);
    end;
  finally
    Directories.Free;
  end;
end;

function IsManagedDelphiArgument(const AArgument: string): Boolean;
var
  ArgumentText: string;
begin
  ArgumentText := UpperCase(AArgument);
  if (ArgumentText <> '') and (ArgumentText[1] = '/') then
    ArgumentText[1] := '-';
  Result := StartsStr(DELPHI_EXECUTABLE_OUTPUT_FLAG, ArgumentText)
    or StartsStr(DELPHI_UNIT_OUTPUT_FLAG, ArgumentText)
    or StartsStr(DELPHI_OBJECT_OUTPUT_FLAG, ArgumentText)
    or StartsStr(DELPHI_UNIT_PATH_FLAG, ArgumentText)
    or StartsStr(DELPHI_INCLUDE_PATH_FLAG, ArgumentText)
    or StartsStr(DELPHI_RESOURCE_PATH_FLAG, ArgumentText)
    or StartsStr(DELPHI_DEFINE_FLAG, ArgumentText)
    or StartsStr(DELPHI_EXTENSION_FLAG, ArgumentText)
    or StartsStr('-$O', ArgumentText)
    or StartsStr('-$D', ArgumentText)
    or StartsStr('-$L', ArgumentText)
    or StartsStr('-$C', ArgumentText)
    or StartsStr('-$R', ArgumentText)
    or (ArgumentText = DELPHI_FORCE_REBUILD_FLAG);
end;

procedure AddExtraArguments(const AArguments: TStringArray;
  const AOutput: TStrings);
var
  i: Integer;
begin
  for i := 0 to High(AArguments) do
  begin
    if (AArguments[i] = '')
       or not (AArguments[i][1] in ['-', '/']) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "%s" extra argument %d must be an option; positional '
        + 'and response-file arguments are not allowed',
        [DELPHI_COMPILER_ID, i]);
    if IsManagedDelphiArgument(AArguments[i]) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "%s" extra argument "%s" is managed by %s and cannot '
        + 'override request inputs or private compiler outputs',
        [DELPHI_COMPILER_ID, AArguments[i], PROJECT_NAME]);
    AOutput.Add(AArguments[i]);
  end;
end;

function TLWPTDelphiCompilerDriver.BuildArguments(
  const ARequest: TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions):
  LWPT.Core.TStringArray;
var
  Arguments: TStringList;
  DefineIndex, i: Integer;
  ExtensionText: string;
begin
  Result := nil;
  ValidateBuildRequest(ARequest);
  if not TargetsEqual(ARequest.Target, ExecutableTarget) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" cannot translate target "%s/%s" for executable "%s"',
      [DELPHI_COMPILER_ID, ARequest.Target.OS,
       ARequest.Target.Architecture, FExecutableName]);
  if ARequest.OutputKind = BUILD_OUTPUT_UNIT then
    raise ELWPTCompilerDriverError.Create(
      'compiler "delphi" does not publish neutral unit outputs');
  Arguments := TStringList.Create;
  try
    if ARequest.Outputs.ExecutableDirectory <> '' then
      Arguments.Add(DELPHI_EXECUTABLE_OUTPUT_FLAG
        + ARequest.Outputs.ExecutableDirectory);
    if ARequest.Outputs.UnitDirectory <> '' then
      Arguments.Add(DELPHI_UNIT_OUTPUT_FLAG
        + ARequest.Outputs.UnitDirectory);
    if ARequest.Outputs.ObjectDirectory <> '' then
      Arguments.Add(DELPHI_OBJECT_OUTPUT_FLAG
        + ARequest.Outputs.ObjectDirectory);
    AddConfigurationUnitPaths(AOptions.ConfigurationFile, Arguments);
    AddNonEmptyPaths(DELPHI_UNIT_PATH_FLAG, ARequest.Inputs.UnitPaths,
      Arguments);
    AddNonEmptyPaths(DELPHI_INCLUDE_PATH_FLAG, ARequest.Inputs.IncludePaths,
      Arguments);
    AddResourcePaths(ARequest.Inputs.Resources, Arguments);
    for DefineIndex := 0 to High(ARequest.Inputs.Defines) do
      if ARequest.Inputs.Defines[DefineIndex] <> '' then
        Arguments.Add(DELPHI_DEFINE_FLAG
          + ARequest.Inputs.Defines[DefineIndex]);
    if ARequest.Mode = BUILD_MODE_RELEASE then
    begin
      Arguments.Add(DELPHI_RELEASE_OPTIMIZATION_FLAG);
      Arguments.Add(DELPHI_RELEASE_DEBUG_FLAG);
      Arguments.Add(DELPHI_RELEASE_LOCAL_SYMBOL_FLAG);
      Arguments.Add(DELPHI_RELEASE_ASSERTION_FLAG);
      Arguments.Add(DELPHI_RELEASE_RANGE_FLAG);
    end
    else
    begin
      Arguments.Add(DELPHI_DEV_OPTIMIZATION_FLAG);
      Arguments.Add(DELPHI_DEV_DEBUG_FLAG);
      Arguments.Add(DELPHI_DEV_LOCAL_SYMBOL_FLAG);
      Arguments.Add(DELPHI_DEV_ASSERTION_FLAG);
      Arguments.Add(DELPHI_DEV_RANGE_FLAG);
    end;
    if AOptions.RebuildPolicy = crpForce then
      Arguments.Add(DELPHI_FORCE_REBUILD_FLAG);
    ExtensionText := ExtractFileExt(ARequest.Outputs.Artifact);
    if ExtensionText <> '' then
      Arguments.Add(DELPHI_EXTENSION_FLAG + ExtensionText);
    AddExtraArguments(ARequest.Inputs.ExtraArguments, Arguments);
    Arguments.Add(ARequest.Inputs.EntryPoint);
    SetLength(Result, Arguments.Count);
    for i := 0 to Arguments.Count - 1 do Result[i] := Arguments[i];
  finally
    Arguments.Free;
  end;
end;

function TLWPTDelphiCompilerDriver.ExecutableName: string;
begin
  Result := ConfiguredCommand(FExecutableName);
end;

function TLWPTDelphiCompilerDriver.ClassifyFailure(
  const AExitCode: Integer; const ARawOutput: string):
  TLWPTCompilerFailure;
begin
  Result := Default(TLWPTCompilerFailure);
  if AExitCode = 0 then Exit;
  Result.Kind := cfkCompilation;
  Result.Summary := 'FAILED (' + DELPHI_COMPILER_ID + ' exit '
    + IntToStr(AExitCode) + ')';
end;

function ParseOrigin(const AValue: string; out APath: string;
  out ALine, AColumn: Integer): Boolean;
var
  ClosingAt, CommaAt, OpeningAt: Integer;
  Coordinates: string;
begin
  Result := False;
  APath := '';
  ALine := 0;
  AColumn := 0;
  ClosingAt := Length(AValue);
  if (ClosingAt = 0) or (AValue[ClosingAt] <> ')') then Exit;
  OpeningAt := RPos('(', AValue);
  if OpeningAt <= 1 then Exit;
  Coordinates := Copy(AValue, OpeningAt + 1,
    ClosingAt - OpeningAt - 1);
  CommaAt := Pos(',', Coordinates);
  if CommaAt > 0 then
  begin
    if not TryStrToInt(Trim(Copy(Coordinates, 1, CommaAt - 1)), ALine)
       or not TryStrToInt(Trim(Copy(Coordinates, CommaAt + 1, MaxInt)),
         AColumn) then Exit;
  end
  else if not TryStrToInt(Coordinates, ALine) then Exit;
  APath := Trim(Copy(AValue, 1, OpeningAt - 1));
  Result := APath <> '';
end;

function ParseDiagnosticLine(const ALine: string;
  out ADiagnostic: TLWPTDiagnostic): Boolean;
const
  SeverityCount = 4;
  SeverityNames: array[0..SeverityCount - 1] of string = (
    'Fatal', 'Error', 'Warning', 'Hint');
var
  CodeEnd, i, MarkerAt: Integer;
  LineText, Prefix, Rest, SeverityText: string;
begin
  ADiagnostic := Default(TLWPTDiagnostic);
  LineText := Trim(ALine);
  Result := False;
  for i := 0 to SeverityCount - 1 do
  begin
    MarkerAt := Pos(' ' + SeverityNames[i] + ':', LineText);
    if MarkerAt > 0 then
    begin
      Prefix := Trim(Copy(LineText, 1, MarkerAt - 1));
      Rest := Trim(Copy(LineText, MarkerAt + 1, MaxInt));
    end
    else if StartsText(SeverityNames[i] + ':', LineText) then
    begin
      Prefix := '';
      Rest := LineText;
    end
    else Continue;
    ParseOrigin(Prefix, ADiagnostic.Path,
      ADiagnostic.Line, ADiagnostic.Column);
    SeverityText := SeverityNames[i];
    if StartsText(SeverityText, Rest) then
      Delete(Rest, 1, Length(SeverityText));
    Rest := Trim(Rest);
    if (Rest <> '') and (Rest[1] = ':') then
    begin
      Delete(Rest, 1, 1);
      Rest := Trim(Rest);
    end;
    if (Length(Rest) >= 2) and (Rest[1] in ['E', 'F', 'W', 'H'])
       and (Rest[2] in ['0'..'9']) then
    begin
      CodeEnd := 1;
      while (CodeEnd <= Length(Rest))
        and (Rest[CodeEnd] > ' ') do Inc(CodeEnd);
      ADiagnostic.Code := Copy(Rest, 1, CodeEnd - 1);
      Rest := Trim(Copy(Rest, CodeEnd, MaxInt));
      if (Rest <> '') and (Rest[1] = ':') then
      begin
        Delete(Rest, 1, 1);
        Rest := Trim(Rest);
      end;
    end;
    ADiagnostic.MessageText := Rest;
    if i <= 1 then ADiagnostic.Severity := DIAGNOSTIC_ERROR
    else if i = 2 then ADiagnostic.Severity := DIAGNOSTIC_WARNING
    else ADiagnostic.Severity := DIAGNOSTIC_INFO;
    if ADiagnostic.MessageText = '' then
      ADiagnostic.MessageText := SeverityText;
    Exit(True);
  end;
end;

function HasErrorDiagnostic(const ADiagnostics: TLWPTDiagnosticArray):
  Boolean;
var
  i: Integer;
begin
  for i := 0 to High(ADiagnostics) do
    if ADiagnostics[i].Severity = DIAGNOSTIC_ERROR then Exit(True);
  Result := False;
end;

function TLWPTDelphiCompilerDriver.GeneratedArtifactPath(
  const ARequest: TLWPTBuildRequest): string;
var
  DirectoryName, ExtensionText: string;
begin
  DirectoryName := ARequest.Outputs.ExecutableDirectory;
  if DirectoryName = '' then
    DirectoryName := ExtractFileDir(ARequest.Outputs.Artifact);
  ExtensionText := ExtractFileExt(ARequest.Outputs.Artifact);
  if (ExtensionText = '') and IsWindowsOperatingSystem(ARequest.Target.OS)
     and (ARequest.OutputKind = BUILD_OUTPUT_EXECUTABLE) then
    ExtensionText := '.exe';
  Result := ChangeFileExt(ExtractFileName(ARequest.Inputs.EntryPoint),
    ExtensionText);
  if DirectoryName <> '' then
    Result := IncludeTrailingPathDelimiter(DirectoryName) + Result;
end;

function TLWPTDelphiCompilerDriver.NormalizeResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const ARawOutput: string): TLWPTBuildResult;
var
  Diagnostic: TLWPTDiagnostic;
  GeneratedPath: string;
  i: Integer;
  Lines: TStringList;
begin
  Result := DefaultBuildResult;
  Lines := TStringList.Create;
  try
    Lines.Text := ARawOutput;
    for i := 0 to Lines.Count - 1 do
      if ParseDiagnosticLine(Lines[i], Diagnostic) then
      begin
        SetLength(Result.Diagnostics, Length(Result.Diagnostics) + 1);
        Result.Diagnostics[High(Result.Diagnostics)] := Diagnostic;
      end;
  finally
    Lines.Free;
  end;
  Result.Success := (AExitCode = 0)
    and not HasErrorDiagnostic(Result.Diagnostics);
  if Result.Success then
  begin
    GeneratedPath := GeneratedArtifactPath(ARequest);
    if not SameFileName(ExpandFileName(GeneratedPath),
      ExpandFileName(ARequest.Outputs.Artifact)) then
    begin
      if not AtomicMoveFile(GeneratedPath, ARequest.Outputs.Artifact) then
      begin
        Result.Success := False;
        SetLength(Result.Diagnostics, Length(Result.Diagnostics) + 1);
        Result.Diagnostics[High(Result.Diagnostics)].Severity :=
          DIAGNOSTIC_ERROR;
        Result.Diagnostics[High(Result.Diagnostics)].MessageText :=
          'Delphi compiler did not produce expected artifact "'
          + GeneratedPath + '"';
      end;
    end
    else if not FileExists(ARequest.Outputs.Artifact) then
    begin
      Result.Success := False;
      SetLength(Result.Diagnostics, Length(Result.Diagnostics) + 1);
      Result.Diagnostics[High(Result.Diagnostics)].Severity :=
        DIAGNOSTIC_ERROR;
      Result.Diagnostics[High(Result.Diagnostics)].MessageText :=
        'Delphi compiler did not produce requested artifact "'
        + ARequest.Outputs.Artifact + '"';
    end;
  end;
  if (not Result.Success) and not HasErrorDiagnostic(Result.Diagnostics) then
  begin
    SetLength(Result.Diagnostics, Length(Result.Diagnostics) + 1);
    Result.Diagnostics[High(Result.Diagnostics)].Severity := DIAGNOSTIC_ERROR;
    Result.Diagnostics[High(Result.Diagnostics)].MessageText :=
      ClassifyFailure(AExitCode, ARawOutput).Summary;
  end;
  if Result.Success then
  begin
    SetLength(Result.Artifacts, 1);
    Result.Artifacts[0].Kind := ARequest.OutputKind;
    Result.Artifacts[0].Path := ARequest.Outputs.Artifact;
  end;
  ValidateBuildResult(Result);
end;

end.
