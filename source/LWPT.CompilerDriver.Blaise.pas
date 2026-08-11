{ LWPT.CompilerDriver.Blaise — graemeg/blaise CLI adapter. }
unit LWPT.CompilerDriver.Blaise;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core;

const
  BLAISE_COMPILER_ID = 'blaise';
  BLAISE_MINIMUM_VERSION = '0.13.0';

type
  TLWPTBlaiseCompilerDriver = class(TLWPTCompilerDriver)
  private
    FExecutableName: string;
    FVersionConstraint: string;
    function ProbeHelp(out AStandardOutput, AStandardError: string): Integer;
  protected
    function ExecuteProbe(out AStandardOutput, AStandardError: string):
      Integer; virtual;
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
  BLAISE_DEFAULT_EXECUTABLE = BLAISE_COMPILER_ID;
  BLAISE_HELP_FLAG = '--help';
  BLAISE_SOURCE_FLAG = '--source';
  BLAISE_OUTPUT_FLAG = '--output';
  BLAISE_TARGET_FLAG = '--target';
  BLAISE_UNIT_PATH_FLAG = '--unit-path';
  BLAISE_DEFINE_FLAG = '--define';
  BLAISE_BACKEND_FLAG = '--backend';
  BLAISE_NATIVE_BACKEND = 'native';
  BLAISE_DEBUG_FLAG = '--debug';
  BLAISE_UNIT_CACHE_FLAG = '--unit-cache';
  BLAISE_NO_INCREMENTAL_FLAG = '--no-incremental';
  BLAISE_PROBE_TIMEOUT_MILLISECONDS = 30000;
  BLAISE_VERSION_PREFIX = 'Blaise Compiler v';
  BLAISE_DEFAULT_TARGET_PREFIX = 'Cross-compile target (default: ';
  BLAISE_DEFAULT_TARGET_SUFFIX = ', the host).';
  BLAISE_LINUX_TARGET = 'linux-x86_64';
  BLAISE_FREEBSD_TARGET = 'freebsd-x86_64';

function TargetName(const ATarget: TLWPTTarget): string;
begin
  Result := ATarget.OS + '-' + ATarget.Architecture;
end;

function TargetFromName(const AName: string): TLWPTTarget;
var
  Separator: Integer;
begin
  Result := Default(TLWPTTarget);
  Separator := Pos('-', AName);
  if Separator <= 1 then Exit;
  Result.OS := Copy(AName, 1, Separator - 1);
  Result.Architecture := Copy(AName, Separator + 1, MaxInt);
end;

function SupportedTargetName(const AName: string): Boolean;
begin
  Result := (AName = BLAISE_LINUX_TARGET)
    or (AName = BLAISE_FREEBSD_TARGET);
end;

function ExtractVersion(const AHelp: string; out AVersion: string): Boolean;
var
  FirstLine, Remaining: string;
  LineEnd: Integer;
begin
  Remaining := StringReplace(AHelp, #13#10, #10, [rfReplaceAll]);
  LineEnd := Pos(#10, Remaining);
  if LineEnd > 0 then FirstLine := Copy(Remaining, 1, LineEnd - 1)
  else FirstLine := Remaining;
  FirstLine := Trim(FirstLine);
  Result := StartsStr(BLAISE_VERSION_PREFIX, FirstLine);
  if Result then
  begin
    AVersion := Trim(Copy(FirstLine, Length(BLAISE_VERSION_PREFIX) + 1,
      MaxInt));
    Result := Valid(AVersion, DefaultSemverOptions) <> '';
  end;
end;

function ExtractDefaultTarget(const AHelp: string;
  out ATarget: TLWPTTarget): Boolean;
var
  LineEnd, PrefixAt, TargetStart: Integer;
  TargetText: string;
begin
  ATarget := Default(TLWPTTarget);
  PrefixAt := Pos(BLAISE_DEFAULT_TARGET_PREFIX, AHelp);
  if PrefixAt = 0 then Exit(False);
  TargetStart := PrefixAt + Length(BLAISE_DEFAULT_TARGET_PREFIX);
  LineEnd := PosEx(BLAISE_DEFAULT_TARGET_SUFFIX, AHelp, TargetStart);
  if LineEnd = 0 then Exit(False);
  TargetText := Trim(Copy(AHelp, TargetStart, LineEnd - TargetStart));
  if not SupportedTargetName(TargetText) then Exit(False);
  ATarget := TargetFromName(TargetText);
  Result := (ATarget.OS <> '') and (ATarget.Architecture <> '');
end;

function HelpAdvertisesTarget(const AHelp, ATargetName: string): Boolean;
begin
  Result := Pos(ATargetName, AHelp) > 0;
end;

function DiagnosticSeverity(const ALine: string; out AMarker: string): string;
const
  MarkerCount = 8;
  Markers: array[0..MarkerCount - 1] of string = (
    'Error:', 'Parse error:', 'Semantic error:', 'Unit not found:',
    'Circular dependency:', 'Compiler error', 'Code generation error:',
    'Warning:');
var
  MarkerIndex: Integer;
begin
  Result := '';
  AMarker := '';
  for MarkerIndex := 0 to MarkerCount - 1 do
    if StartsStr(Markers[MarkerIndex], Trim(ALine)) then
    begin
      AMarker := Markers[MarkerIndex];
      if MarkerIndex = MarkerCount - 1 then
        Result := DIAGNOSTIC_WARNING
      else
        Result := DIAGNOSTIC_ERROR;
      Exit;
    end;
end;

function ArrayContainsPath(const AValues: LWPT.Core.TStringArray;
  const AValue: string): Boolean;
var
  ValueIndex: Integer;
begin
  for ValueIndex := 0 to High(AValues) do
    if ExpandFileName(AValues[ValueIndex]) = ExpandFileName(AValue) then
      Exit(True);
  Result := False;
end;

function ManagedArgument(const AArgument: string): Boolean;
const
  ManagedCount = 18;
  Managed: array[0..ManagedCount - 1] of string = (
    BLAISE_SOURCE_FLAG, BLAISE_OUTPUT_FLAG, BLAISE_TARGET_FLAG,
    BLAISE_UNIT_PATH_FLAG, BLAISE_DEFINE_FLAG, BLAISE_BACKEND_FLAG,
    BLAISE_DEBUG_FLAG, BLAISE_UNIT_CACHE_FLAG,
    BLAISE_NO_INCREMENTAL_FLAG, BLAISE_HELP_FLAG, '-h', '--emit-asm',
    '--dump-ast', '--rtl-src', '--emit-ir', '--emit-iface',
    '--skip-dep-codegen', '-d');
var
  ManagedIndex: Integer;
begin
  for ManagedIndex := 0 to ManagedCount - 1 do
    if (AArgument = Managed[ManagedIndex])
       or StartsStr(Managed[ManagedIndex] + '=', AArgument) then
      Exit(True);
  Result := False;
end;

procedure AddValueArgument(const AFlag, AValue: string;
  const AArguments: TStrings);
begin
  AArguments.Add(AFlag);
  AArguments.Add(AValue);
end;

constructor TLWPTBlaiseCompilerDriver.Create(const AExecutableName: string;
  const AVersionConstraint: string);
begin
  inherited Create;
  if AExecutableName = '' then
    FExecutableName := BLAISE_DEFAULT_EXECUTABLE
  else
    FExecutableName := AExecutableName;
  FVersionConstraint := AVersionConstraint;
end;

function TLWPTBlaiseCompilerDriver.CompilerID: string;
begin
  Result := BLAISE_COMPILER_ID;
end;

function TLWPTBlaiseCompilerDriver.VersionConstraint: string;
begin
  Result := FVersionConstraint;
end;

function TLWPTBlaiseCompilerDriver.ProbeTimeoutMilliseconds: QWord;
begin
  Result := BLAISE_PROBE_TIMEOUT_MILLISECONDS;
end;

function TLWPTBlaiseCompilerDriver.ExecuteProbe(out AStandardOutput,
  AStandardError: string): Integer;
var
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
    ProbeProcess.Parameters.Add(BLAISE_HELP_FLAG);
    Options := DefaultProcessRunOptions('compiler "' + BLAISE_COMPILER_ID
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

function TLWPTBlaiseCompilerDriver.ProbeHelp(out AStandardOutput,
  AStandardError: string): Integer;
begin
  try
    Result := ExecuteProbe(AStandardOutput, AStandardError);
  except
    on E: Exception do
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "%s" could not execute "%s" for a live capability '
        + 'probe: %s', [BLAISE_COMPILER_ID, FExecutableName, E.Message]);
  end;
end;

function TLWPTBlaiseCompilerDriver.DefaultTarget: TLWPTTarget;
var
  StandardError, StandardOutput, Version: string;
  ExitCode: Integer;
begin
  ExitCode := ProbeHelp(StandardOutput, StandardError);
  if ExitCode <> 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" live capability probe failed with exit %d: %s',
      [BLAISE_COMPILER_ID, ExitCode, Trim(StandardError)]);
  if not ExtractVersion(StandardOutput, Version) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" probe did not identify a Blaise semantic version',
      [BLAISE_COMPILER_ID]);
  if not Satisfies(Version, '>=' + BLAISE_MINIMUM_VERSION,
    DefaultSemverOptions) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" is older than supported minimum "%s"',
      [BLAISE_COMPILER_ID, Version, BLAISE_MINIMUM_VERSION]);
  if not ExtractDefaultTarget(StandardOutput, Result) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" probe did not report a verified default target',
      [BLAISE_COMPILER_ID]);
end;

function TLWPTBlaiseCompilerDriver.ProbeCapabilities(
  const ATarget: TLWPTTarget; const ARefresh: Boolean):
  TLWPTCompilerCapabilities;
var
  RequestedTarget, StandardError, StandardOutput, Version: string;
  ExitCode: Integer;
begin
  { Blaise is deliberately probed on every operation. ARefresh is accepted
    for the common interface but never permits a cached answer. }
  ExitCode := ProbeHelp(StandardOutput, StandardError);
  if ExitCode <> 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" live capability probe failed with exit %d: %s',
      [BLAISE_COMPILER_ID, ExitCode, Trim(StandardError)]);
  if not ExtractVersion(StandardOutput, Version) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" probe did not identify the Blaise CLI',
      [BLAISE_COMPILER_ID]);
  if not Satisfies(Version, '>=' + BLAISE_MINIMUM_VERSION,
    DefaultSemverOptions) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" is older than supported minimum "%s"',
      [BLAISE_COMPILER_ID, Version, BLAISE_MINIMUM_VERSION]);
  if not HelpAdvertisesTarget(StandardOutput, BLAISE_LINUX_TARGET)
     or not HelpAdvertisesTarget(StandardOutput, BLAISE_FREEBSD_TARGET) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" does not advertise both verified '
      + 'target tuples "%s" and "%s"', [BLAISE_COMPILER_ID, Version,
        BLAISE_LINUX_TARGET, BLAISE_FREEBSD_TARGET]);

  RequestedTarget := TargetName(ATarget);
  if (ATarget.OS <> '') or (ATarget.Architecture <> '') then
    if not SupportedTargetName(RequestedTarget) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "%s" does not support requested target "%s/%s"; '
        + 'verified targets are "linux/x86_64" and "freebsd/x86_64"',
        [BLAISE_COMPILER_ID, ATarget.OS, ATarget.Architecture]);

  Result := DefaultCompilerCapabilities;
  Result.CompilerID := BLAISE_COMPILER_ID;
  Result.VersionIdentity := Version;
  SetLength(Result.Targets, 2);
  Result.Targets[0] := TargetFromName(BLAISE_LINUX_TARGET);
  Result.Targets[1] := TargetFromName(BLAISE_FREEBSD_TARGET);
  SetLength(Result.OutputKinds, 1);
  Result.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
  SetLength(Result.Modes, 2);
  Result.Modes[0] := BUILD_MODE_DEV;
  Result.Modes[1] := BUILD_MODE_RELEASE;
  ValidateCompilerCapabilities(Result);
end;

function TLWPTBlaiseCompilerDriver.BuildArguments(
  const ARequest: TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions):
  LWPT.Core.TStringArray;
var
  Arguments: TStringList;
  ArgumentIndex, PathIndex: Integer;
  ConfigurationUnitPaths: LWPT.Core.TStringArray;
begin
  Result := nil;
  ValidateBuildRequest(ARequest);
  if Length(ARequest.Inputs.Sources) <> 1 then
    raise ELWPTCompilerDriverError.Create(
      'compiler "blaise" supports one explicit entry source; dependency '
      + 'units must be reachable through unit paths');
  if Length(ARequest.Inputs.Resources) <> 0 then
    raise ELWPTCompilerDriverError.Create(
      'compiler "blaise" does not support neutral resource inputs');
  for PathIndex := 0 to High(ARequest.Inputs.IncludePaths) do
    if (ARequest.Inputs.IncludePaths[PathIndex] <> '')
       and not ArrayContainsPath(ARequest.Inputs.UnitPaths,
         ARequest.Inputs.IncludePaths[PathIndex]) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler "blaise" does not support include-only search path "%s"',
        [ARequest.Inputs.IncludePaths[PathIndex]]);
  if (ARequest.Outputs.UnitDirectory <> '')
     and (ARequest.Outputs.ObjectDirectory <> '')
     and (ExpandFileName(ARequest.Outputs.UnitDirectory)
       <> ExpandFileName(ARequest.Outputs.ObjectDirectory)) then
    raise ELWPTCompilerDriverError.Create(
      'compiler "blaise" requires one shared unit/object cache directory');

  Arguments := TStringList.Create;
  try
    AddValueArgument(BLAISE_SOURCE_FLAG, ARequest.Inputs.EntryPoint,
      Arguments);
    AddValueArgument(BLAISE_OUTPUT_FLAG, ARequest.Outputs.Artifact,
      Arguments);
    AddValueArgument(BLAISE_TARGET_FLAG, TargetName(ARequest.Target),
      Arguments);
    AddValueArgument(BLAISE_BACKEND_FLAG, BLAISE_NATIVE_BACKEND, Arguments);
    for PathIndex := 0 to High(ARequest.Inputs.UnitPaths) do
      if ARequest.Inputs.UnitPaths[PathIndex] <> '' then
        AddValueArgument(BLAISE_UNIT_PATH_FLAG,
          ARequest.Inputs.UnitPaths[PathIndex], Arguments);
    SetLength(ConfigurationUnitPaths, 0);
    AppendUnitDirsFromCfg(AOptions.ConfigurationFile,
      ConfigurationUnitPaths);
    for PathIndex := 0 to High(ConfigurationUnitPaths) do
      if (ConfigurationUnitPaths[PathIndex] <> '')
         and not ArrayContainsPath(ARequest.Inputs.UnitPaths,
           ConfigurationUnitPaths[PathIndex]) then
        AddValueArgument(BLAISE_UNIT_PATH_FLAG,
          ConfigurationUnitPaths[PathIndex], Arguments);
    for PathIndex := 0 to High(ARequest.Inputs.Defines) do
      if ARequest.Inputs.Defines[PathIndex] <> '' then
        AddValueArgument(BLAISE_DEFINE_FLAG,
          ARequest.Inputs.Defines[PathIndex], Arguments);
    if ARequest.Outputs.UnitDirectory <> '' then
      AddValueArgument(BLAISE_UNIT_CACHE_FLAG,
        ARequest.Outputs.UnitDirectory, Arguments)
    else if ARequest.Outputs.ObjectDirectory <> '' then
      AddValueArgument(BLAISE_UNIT_CACHE_FLAG,
        ARequest.Outputs.ObjectDirectory, Arguments);
    if ARequest.Mode = BUILD_MODE_DEV then Arguments.Add(BLAISE_DEBUG_FLAG);
    if AOptions.RebuildPolicy = crpForce then
      Arguments.Add(BLAISE_NO_INCREMENTAL_FLAG);
    for ArgumentIndex := 0 to High(ARequest.Inputs.ExtraArguments) do
    begin
      if not StartsStr('-', ARequest.Inputs.ExtraArguments[ArgumentIndex]) then
        raise ELWPTCompilerDriverError.CreateFmt(
          'compiler "blaise" extra argument %d must be an option; '
          + 'positional arguments are not supported', [ArgumentIndex]);
      if ManagedArgument(ARequest.Inputs.ExtraArguments[ArgumentIndex]) then
        raise ELWPTCompilerDriverError.CreateFmt(
          'compiler "blaise" extra argument "%s" is managed by %s and '
          + 'cannot override the selected backend, target, inputs, mode, '
          + 'or private outputs', [ARequest.Inputs.ExtraArguments[
            ArgumentIndex], PROJECT_NAME]);
      Arguments.Add(ARequest.Inputs.ExtraArguments[ArgumentIndex]);
    end;
    SetLength(Result, Arguments.Count);
    for ArgumentIndex := 0 to Arguments.Count - 1 do
      Result[ArgumentIndex] := Arguments[ArgumentIndex];
  finally
    Arguments.Free;
  end;
end;

function TLWPTBlaiseCompilerDriver.ExecutableName: string;
begin
  Result := ConfiguredCommand(FExecutableName);
end;

function TLWPTBlaiseCompilerDriver.SeparateStandardError: Boolean;
begin
  Result := True;
end;

function TLWPTBlaiseCompilerDriver.ClassifyFailure(
  const AExitCode: Integer; const ARawOutput: string):
  TLWPTCompilerFailure;
begin
  Result := Default(TLWPTCompilerFailure);
  if AExitCode = 0 then Exit;
  Result.Kind := cfkCompilation;
  Result.Summary := 'FAILED (' + BLAISE_COMPILER_ID + ' exit '
    + IntToStr(AExitCode) + ')';
end;

function TLWPTBlaiseCompilerDriver.NormalizeResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const ARawOutput: string): TLWPTBuildResult;
var
  Diagnostic: TLWPTDiagnostic;
  DiagnosticCount, LineIndex: Integer;
  Lines: TStringList;
  Marker, Severity, Text: string;
begin
  Result := DefaultBuildResult;
  Lines := TStringList.Create;
  try
    Lines.Text := ARawOutput;
    for LineIndex := 0 to Lines.Count - 1 do
    begin
      Text := Trim(Lines[LineIndex]);
      Severity := DiagnosticSeverity(Text, Marker);
      if Severity = '' then Continue;
      Diagnostic := Default(TLWPTDiagnostic);
      Diagnostic.Severity := Severity;
      Diagnostic.MessageText := Trim(Copy(Text, Length(Marker) + 1,
        MaxInt));
      if Diagnostic.MessageText = '' then Diagnostic.MessageText := Text;
      DiagnosticCount := Length(Result.Diagnostics);
      SetLength(Result.Diagnostics, DiagnosticCount + 1);
      Result.Diagnostics[DiagnosticCount] := Diagnostic;
    end;
  finally
    Lines.Free;
  end;
  Result.Success := AExitCode = 0;
  for DiagnosticCount := 0 to High(Result.Diagnostics) do
    if Result.Diagnostics[DiagnosticCount].Severity = DIAGNOSTIC_ERROR then
      Result.Success := False;
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
