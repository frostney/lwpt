{ LWPT.CompilerDriver.Lakon — frostney/lakon CLI adapter. }
unit LWPT.CompilerDriver.Lakon;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core;

const
  LAKON_COMPILER_ID = 'lakon';
  LAKON_MINIMUM_VERSION = '0.1.0';

type
  TLWPTLakonCompilerDriver = class(TLWPTCompilerDriver)
  private
    FExecutableName: string;
    FVersionConstraint: string;
    function ProbeDocument(const AArgument, ADescription: string): string;
  protected
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AStandardOutput, AStandardError: string): Integer; virtual;
    function ProbeTimeoutMilliseconds: QWord; virtual;
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
    function SeparateStandardError: Boolean; override;
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
  LAKON_DEFAULT_EXECUTABLE = LAKON_COMPILER_ID;
  LAKON_VERSION_FLAG = '--version';
  LAKON_HELP_FLAG = '--help';
  LAKON_COMPILE_VERB = 'compile';
  LAKON_OUTPUT_FLAG = '-o';
  LAKON_UNIT_PATH_FLAG = '-Fu';
  LAKON_DEFINE_FLAG = '-d';
  LAKON_NO_CACHE_FLAG = '--no-cache';
  LAKON_VERBOSE_UNITS_FLAG = '--verbose-units';
  LAKON_NO_INLINE_FLAG = '--no-inline';
  LAKON_INLINE_STATS_FLAG = '--inline-stats';
  LAKON_PROBE_TIMEOUT_MILLISECONDS = 30000;
  LAKON_TARGET_OS = 'wasi';
  LAKON_TARGET_ARCHITECTURE = 'wasm32';
  LAKON_TARGET_ENVIRONMENT = 'wasip1';

function FirstLine(const AText: string): string;
var
  LineEnd: Integer;
begin
  Result := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  LineEnd := Pos(#10, Result);
  if LineEnd > 0 then Result := Copy(Result, 1, LineEnd - 1);
  Result := Trim(Result);
end;

function ExtractVersion(const AOutput: string; out AVersion: string): Boolean;
var
  Prefix, VersionLine: string;
begin
  Prefix := LAKON_COMPILER_ID + ' ';
  VersionLine := FirstLine(AOutput);
  Result := StartsStr(Prefix, VersionLine);
  if not Result then Exit;
  AVersion := Trim(Copy(VersionLine, Length(Prefix) + 1, MaxInt));
  Result := Valid(AVersion, DefaultSemverOptions) <> '';
end;

function HelpMatchesReleasedContract(const AHelp: string): Boolean;
begin
  Result := (Pos('usage: ' + LAKON_COMPILER_ID, AHelp) > 0)
    and (Pos(LAKON_COMPILER_ID + ' ' + LAKON_COMPILE_VERB, AHelp) > 0)
    and (Pos('WebAssembly', AHelp) > 0)
    and (Pos(LAKON_OUTPUT_FLAG + ' ', AHelp) > 0)
    and (Pos(LAKON_UNIT_PATH_FLAG + ' <dir>', AHelp) > 0)
    and (Pos(LAKON_DEFINE_FLAG + ' <sym>', AHelp) > 0)
    and (Pos(LAKON_NO_CACHE_FLAG, AHelp) > 0)
    and (Pos(LAKON_VERBOSE_UNITS_FLAG, AHelp) > 0)
    and (Pos(LAKON_NO_INLINE_FLAG, AHelp) > 0)
    and (Pos(LAKON_INLINE_STATS_FLAG, AHelp) > 0);
end;

function TargetIsSupported(const ATarget: TLWPTTarget): Boolean;
begin
  Result := (ATarget.OS = LAKON_TARGET_OS)
    and (ATarget.Architecture = LAKON_TARGET_ARCHITECTURE)
    and (ATarget.ABI = '')
    and ((ATarget.Environment = '')
      or (ATarget.Environment = LAKON_TARGET_ENVIRONMENT));
end;

function PathsEqual(const ALeft, ARight: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ExpandFileName(ALeft), ExpandFileName(ARight));
  {$ELSE}
  Result := ExpandFileName(ALeft) = ExpandFileName(ARight);
  {$ENDIF}
end;

function ArrayContainsPath(const AValues: LWPT.Core.TStringArray;
  const AValue: string): Boolean;
var
  ValueIndex: Integer;
begin
  for ValueIndex := 0 to High(AValues) do
    if PathsEqual(AValues[ValueIndex], AValue) then Exit(True);
  Result := False;
end;

function AllowedExtraArgument(const AArgument: string): Boolean;
begin
  Result := (AArgument = LAKON_VERBOSE_UNITS_FLAG)
    or (AArgument = LAKON_NO_INLINE_FLAG)
    or (AArgument = LAKON_INLINE_STATS_FLAG);
end;

procedure AddValueArgument(const AFlag, AValue: string;
  const AArguments: TStrings);
begin
  AArguments.Add(AFlag);
  AArguments.Add(AValue);
end;

constructor TLWPTLakonCompilerDriver.Create(const AExecutableName: string;
  const AVersionConstraint: string);
begin
  inherited Create;
  if AExecutableName = '' then
    FExecutableName := LAKON_DEFAULT_EXECUTABLE
  else
    FExecutableName := AExecutableName;
  FVersionConstraint := AVersionConstraint;
end;

function TLWPTLakonCompilerDriver.CompilerID: string;
begin
  Result := LAKON_COMPILER_ID;
end;

function TLWPTLakonCompilerDriver.VersionConstraint: string;
begin
  Result := FVersionConstraint;
end;

function TLWPTLakonCompilerDriver.ProbeTimeoutMilliseconds: QWord;
begin
  Result := LAKON_PROBE_TIMEOUT_MILLISECONDS;
end;

function TLWPTLakonCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AStandardOutput,
  AStandardError: string): Integer;
var
  ArgumentIndex: Integer;
  Options: TLWPTProcessRunOptions;
  ProbeProcess: TProcess;
  Runner: TLWPTDuplexProcessRunner;
begin
  ProbeProcess := TProcess.Create(nil);
  Runner := nil;
  try
    ProbeProcess.Executable := ConfiguredCommand(FExecutableName);
    if WorkingDirectory <> '' then
      ProbeProcess.CurrentDirectory := WorkingDirectory;
    AppendCommandArguments(ProbeProcess.Parameters);
    for ArgumentIndex := 0 to High(AArguments) do
      ProbeProcess.Parameters.Add(AArguments[ArgumentIndex]);
    Options := DefaultProcessRunOptions('compiler "' + LAKON_COMPILER_ID
      + '" capability probe');
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds := ProbeTimeoutMilliseconds;
    Runner := TLWPTDuplexProcessRunner.Create(ProbeProcess);
    Result := Runner.Run('', Options, AStandardOutput, AStandardError);
  finally
    Runner.Free;
    ProbeProcess.Free;
  end;
end;

function TLWPTLakonCompilerDriver.ProbeDocument(const AArgument,
  ADescription: string): string;
var
  Arguments: LWPT.Core.TStringArray;
  ExitCode: Integer;
  StandardError: string;
begin
  SetLength(Arguments, 1);
  Arguments[0] := AArgument;
  try
    ExitCode := ExecuteProbe(Arguments, Result, StandardError);
  except
    on E: Exception do
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "%s" could not execute "%s" for its live %s probe: %s',
        [LAKON_COMPILER_ID, FExecutableName, ADescription, E.Message]);
  end;
  if ExitCode <> 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" live %s probe failed with exit %d: %s',
      [LAKON_COMPILER_ID, ADescription, ExitCode, Trim(StandardError)]);
end;

function TLWPTLakonCompilerDriver.DefaultTarget: TLWPTTarget;
begin
  Result := Default(TLWPTTarget);
  Result.OS := LAKON_TARGET_OS;
  Result.Architecture := LAKON_TARGET_ARCHITECTURE;
  Result.Environment := LAKON_TARGET_ENVIRONMENT;
end;

function TLWPTLakonCompilerDriver.ProbeCapabilities(
  const ATarget: TLWPTTarget; const ARefresh: Boolean):
  TLWPTCompilerCapabilities;
var
  HelpOutput, Version, VersionOutput: string;
begin
  { The adapter deliberately has no capability cache. Every selection and
    concrete compile rechecks the executable that will perform the work. }
  VersionOutput := ProbeDocument(LAKON_VERSION_FLAG, 'version');
  HelpOutput := ProbeDocument(LAKON_HELP_FLAG, 'command-surface');
  if not ExtractVersion(VersionOutput, Version) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" probe did not identify the released %s CLI',
      [LAKON_COMPILER_ID, LAKON_COMPILER_ID]);
  if not Satisfies(Version, '>=' + LAKON_MINIMUM_VERSION,
    DefaultSemverOptions) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" is older than supported minimum "%s"',
      [LAKON_COMPILER_ID, Version, LAKON_MINIMUM_VERSION]);
  if not Satisfies(Version, FVersionConstraint, DefaultSemverOptions) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" does not satisfy configured version '
      + 'constraint "%s"',
      [LAKON_COMPILER_ID, Version, FVersionConstraint]);
  if not HelpMatchesReleasedContract(HelpOutput) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" does not advertise the verified '
      + 'WebAssembly compile contract', [LAKON_COMPILER_ID, Version]);
  if not TargetIsSupported(ATarget) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" does not support requested target "%s/%s" '
      + '(ABI "%s", environment "%s"); verified target is '
      + '"%s/%s" with environment "%s"',
      [LAKON_COMPILER_ID, ATarget.OS, ATarget.Architecture, ATarget.ABI,
       ATarget.Environment, LAKON_TARGET_OS, LAKON_TARGET_ARCHITECTURE,
       LAKON_TARGET_ENVIRONMENT]);

  Result := DefaultCompilerCapabilities;
  Result.CompilerID := LAKON_COMPILER_ID;
  Result.VersionIdentity := Version;
  SetLength(Result.Targets, 1);
  Result.Targets[0] := DefaultTarget;
  SetLength(Result.OutputKinds, 1);
  Result.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
  SetLength(Result.Modes, 1);
  Result.Modes[0] := BUILD_MODE_DEV;
  ValidateCompilerCapabilities(Result);
end;

function TLWPTLakonCompilerDriver.BuildArguments(
  const ARequest: TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions):
  LWPT.Core.TStringArray;
var
  Arguments: TStringList;
  ArgumentIndex, PathIndex: Integer;
  AddedConfigurationUnitPaths,
    ConfigurationUnitPaths: LWPT.Core.TStringArray;
begin
  Result := nil;
  ValidateBuildRequest(ARequest);
  if not SameText(ARequest.Compiler.ID, LAKON_COMPILER_ID) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" cannot translate a request for compiler "%s"',
      [LAKON_COMPILER_ID, ARequest.Compiler.ID]);
  if not TargetIsSupported(ARequest.Target) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" supports only target "%s/%s" with environment "%s"',
      [LAKON_COMPILER_ID, LAKON_TARGET_OS, LAKON_TARGET_ARCHITECTURE,
       LAKON_TARGET_ENVIRONMENT]);
  if ARequest.OutputKind <> BUILD_OUTPUT_EXECUTABLE then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" supports only executable WebAssembly output',
      [LAKON_COMPILER_ID]);
  if ARequest.Mode <> BUILD_MODE_DEV then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" has no released translation for mode "%s"',
      [LAKON_COMPILER_ID, ARequest.Mode]);
  if AOptions.ArgumentProfile = capPascalSource then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" produces WASI modules that %s cannot execute as '
      + 'native test programs; a Lakon embedding host must own its WASI '
      + 'execution path', [LAKON_COMPILER_ID, PROJECT_NAME]);
  if (Length(ARequest.Inputs.Sources) <> 1)
     or not PathsEqual(ARequest.Inputs.Sources[0],
       ARequest.Inputs.EntryPoint) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" supports one explicit entry source; dependency '
      + 'units must be reachable through unit paths', [LAKON_COMPILER_ID]);
  if Length(ARequest.Inputs.Resources) <> 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" does not support neutral resource inputs',
      [LAKON_COMPILER_ID]);
  for PathIndex := 0 to High(ARequest.Inputs.IncludePaths) do
    if (ARequest.Inputs.IncludePaths[PathIndex] <> '')
       and not ArrayContainsPath(ARequest.Inputs.UnitPaths,
         ARequest.Inputs.IncludePaths[PathIndex]) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "%s" does not support include-only search path "%s"',
        [LAKON_COMPILER_ID, ARequest.Inputs.IncludePaths[PathIndex]]);

  Arguments := TStringList.Create;
  try
    Arguments.Add(LAKON_COMPILE_VERB);
    Arguments.Add(ARequest.Inputs.EntryPoint);
    AddValueArgument(LAKON_OUTPUT_FLAG, ARequest.Outputs.Artifact, Arguments);
    for PathIndex := 0 to High(ARequest.Inputs.UnitPaths) do
      if ARequest.Inputs.UnitPaths[PathIndex] <> '' then
        AddValueArgument(LAKON_UNIT_PATH_FLAG,
          ARequest.Inputs.UnitPaths[PathIndex], Arguments);
    SetLength(ConfigurationUnitPaths, 0);
    SetLength(AddedConfigurationUnitPaths, 0);
    AppendUnitDirsFromCfg(AOptions.ConfigurationFile,
      ConfigurationUnitPaths);
    for PathIndex := 0 to High(ConfigurationUnitPaths) do
      if (ConfigurationUnitPaths[PathIndex] <> '')
         and not ArrayContainsPath(ARequest.Inputs.UnitPaths,
           ConfigurationUnitPaths[PathIndex])
         and not ArrayContainsPath(AddedConfigurationUnitPaths,
           ConfigurationUnitPaths[PathIndex]) then
      begin
        AddValueArgument(LAKON_UNIT_PATH_FLAG,
          ConfigurationUnitPaths[PathIndex], Arguments);
        SetLength(AddedConfigurationUnitPaths,
          Length(AddedConfigurationUnitPaths) + 1);
        AddedConfigurationUnitPaths[High(AddedConfigurationUnitPaths)] :=
          ConfigurationUnitPaths[PathIndex];
      end;
    for PathIndex := 0 to High(ARequest.Inputs.Defines) do
      if ARequest.Inputs.Defines[PathIndex] <> '' then
        AddValueArgument(LAKON_DEFINE_FLAG,
          ARequest.Inputs.Defines[PathIndex], Arguments);
    { Lakon's released cache path is rooted at build/cache rather than the
      neutral private output roots. Disabling it on every LWPT invocation
      preserves session isolation and also satisfies forced rebuilds. }
    Arguments.Add(LAKON_NO_CACHE_FLAG);
    for ArgumentIndex := 0 to High(ARequest.Inputs.ExtraArguments) do
    begin
      if not AllowedExtraArgument(ARequest.Inputs.ExtraArguments[
        ArgumentIndex]) then
        raise ELWPTCompilerDriverError.CreateFmt(
          'compiler "%s" extra argument "%s" is not in the verified '
          + 'released CLI contract or is managed by %s',
          [LAKON_COMPILER_ID, ARequest.Inputs.ExtraArguments[ArgumentIndex],
           PROJECT_NAME]);
      Arguments.Add(ARequest.Inputs.ExtraArguments[ArgumentIndex]);
    end;
    SetLength(Result, Arguments.Count);
    for ArgumentIndex := 0 to Arguments.Count - 1 do
      Result[ArgumentIndex] := Arguments[ArgumentIndex];
  finally
    Arguments.Free;
  end;
end;

function TLWPTLakonCompilerDriver.ExecutableName: string;
begin
  Result := ConfiguredCommand(FExecutableName);
end;

function TLWPTLakonCompilerDriver.SeparateStandardError: Boolean;
begin
  Result := True;
end;

function TLWPTLakonCompilerDriver.ClassifyFailure(
  const AExitCode: Integer; const ARawOutput: string):
  TLWPTCompilerFailure;
begin
  Result := Default(TLWPTCompilerFailure);
  if AExitCode = 0 then Exit;
  Result.Kind := cfkCompilation;
  Result.Summary := 'FAILED (' + LAKON_COMPILER_ID + ' exit '
    + IntToStr(AExitCode) + ')';
end;

procedure ParseDiagnostic(const AText: string; out ADiagnostic:
  TLWPTDiagnostic);
var
  ColumnSeparator, LocationAt, MessageSeparator: Integer;
  Location, Remaining: string;
begin
  ADiagnostic := Default(TLWPTDiagnostic);
  ADiagnostic.Severity := DIAGNOSTIC_ERROR;
  Remaining := Trim(Copy(AText, Length(LAKON_COMPILER_ID) + 3, MaxInt));
  LocationAt := RPos(' at ', Remaining);
  if LocationAt > 0 then
  begin
    Location := Copy(Remaining, LocationAt + 4, MaxInt);
    ColumnSeparator := Pos(':', Location);
    if ColumnSeparator > 0 then
      if TryStrToInt(Copy(Location, 1, ColumnSeparator - 1),
        ADiagnostic.Line)
         and TryStrToInt(Copy(Location, ColumnSeparator + 1, MaxInt),
           ADiagnostic.Column) then
        Delete(Remaining, LocationAt, MaxInt)
      else
      begin
        ADiagnostic.Line := 0;
        ADiagnostic.Column := 0;
      end;
  end;
  MessageSeparator := Pos(': ', Remaining);
  if MessageSeparator > 0 then
  begin
    ADiagnostic.Path := Copy(Remaining, 1, MessageSeparator - 1);
    ADiagnostic.MessageText := Copy(Remaining, MessageSeparator + 2, MaxInt);
  end
  else
    ADiagnostic.MessageText := Remaining;
end;

function TLWPTLakonCompilerDriver.NormalizeResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const ARawOutput: string): TLWPTBuildResult;
var
  DiagnosticCount, LineIndex: Integer;
  Lines: TStringList;
  Text: string;
begin
  Result := DefaultBuildResult;
  Lines := TStringList.Create;
  try
    if AExitCode <> 0 then
    begin
      Lines.Text := ARawOutput;
      for LineIndex := 0 to Lines.Count - 1 do
      begin
        Text := Trim(Lines[LineIndex]);
        if not StartsStr(LAKON_COMPILER_ID + ': ', Text) then Continue;
        DiagnosticCount := Length(Result.Diagnostics);
        SetLength(Result.Diagnostics, DiagnosticCount + 1);
        ParseDiagnostic(Text, Result.Diagnostics[DiagnosticCount]);
      end;
    end;
  finally
    Lines.Free;
  end;
  Result.Success := (AExitCode = 0) and (Length(Result.Diagnostics) = 0);
  if (not Result.Success) and (Length(Result.Diagnostics) = 0) then
  begin
    SetLength(Result.Diagnostics, 1);
    Result.Diagnostics[0].Severity := DIAGNOSTIC_ERROR;
    Result.Diagnostics[0].MessageText := ClassifyFailure(AExitCode,
      ARawOutput).Summary;
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
