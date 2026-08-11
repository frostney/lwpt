{ LWPT.CompilerDriver — compiler-neutral invocation seam. }
unit LWPT.CompilerDriver;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,

  LWPT.BuildRequest,
  LWPT.Core;

const
  COMPILER_TIMEOUT_ENVIRONMENT = PROJECT_NAME + '_COMPILER_TIMEOUT_MS';
  DEFAULT_COMPILER_TIMEOUT_MILLISECONDS = 30 * 60 * 1000;

type
  ELWPTCompilerDriverError = class(ELWPTError);

  TLWPTCompilerFailureKind = (cfkNone, cfkCompilation,
    cfkStaleArtefact);

  TLWPTCompilerFailure = record
    Kind: TLWPTCompilerFailureKind;
    Summary: string;
    Recovery: string;
  end;

  TLWPTCompilerArgumentProfile = (capBuild, capPascalSource);
  TLWPTCompilerRebuildPolicy = (crpIncremental, crpForce);

  TLWPTCompilerInvocationOptions = record
    ConfigurationFile: string;
    ArgumentProfile: TLWPTCompilerArgumentProfile;
    RebuildPolicy: TLWPTCompilerRebuildPolicy;
  end;

  { Implementations are shared across build/test workers. Every operation,
    including capability probing and cache publication, must be safe for
    concurrent calls on one driver instance. }
  TLWPTCompilerDriver = class
  private
    FCommandArguments: LWPT.Core.TStringArray;
    FCommandOverride: string;
    FCommandWorkingDirectory: string;
  protected
    function ConfiguredCommand(const ADefault: string): string;
    function CommandArgumentCount: Integer;
    function CommandArgument(const AIndex: Integer): string;
    procedure AppendCommandArguments(const AParameters: TStrings);
    function PrependCommandArguments(
      const AArguments: LWPT.Core.TStringArray): LWPT.Core.TStringArray;
  public
    procedure ConfigureCommand(const ACommand: string;
      const AArguments: array of string;
      const AWorkingDirectory: string = '');
    function InvocationArguments(
      const AArguments: LWPT.Core.TStringArray): LWPT.Core.TStringArray;
    function WorkingDirectory: string;
    function CompilerID: string; virtual; abstract;
    function VersionConstraint: string; virtual;
    function CreateBuildRequest(const ASource, AArtifact: string):
      TLWPTBuildRequest; virtual;
    function CreateBuildRequestForTarget(const ASource, AArtifact: string;
      const ATarget: TLWPTTarget): TLWPTBuildRequest; virtual;
    function DefaultTarget: TLWPTTarget; virtual; abstract;
    function ProbeCapabilities(const ATarget: TLWPTTarget;
      const ARefresh: Boolean = False): TLWPTCompilerCapabilities; virtual;
      abstract;
    function BuildArguments(const ARequest: TLWPTBuildRequest;
      const AOptions: TLWPTCompilerInvocationOptions):
      LWPT.Core.TStringArray; virtual; abstract;
    function ExecutableName: string; virtual; abstract;
    function BuildStandardInput(const ARequest: TLWPTBuildRequest): string;
      virtual;
    function SeparateStandardError: Boolean; virtual;
    function CompilationTimeoutMilliseconds: QWord; virtual;
    function ClassifyFailure(const AExitCode: Integer;
      const ARawOutput: string): TLWPTCompilerFailure; virtual; abstract;
    function NormalizeResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const ARawOutput: string):
      TLWPTBuildResult; virtual; abstract;
    function NormalizeExecutionResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const AStandardOutput,
      AStandardError: string): TLWPTBuildResult; virtual;
    function DisplayOutput(const AStandardOutput,
      AStandardError: string): string; virtual;
  end;

function BuildCompilerInvocationOptions(const AConfigurationFile: string;
  const AForceRebuild: Boolean): TLWPTCompilerInvocationOptions;
function PascalSourceCompilerInvocationOptions(
  const AConfigurationFile: string): TLWPTCompilerInvocationOptions;
procedure EnsureBuildRequestCompatible(const ARequest: TLWPTBuildRequest;
  const ACapabilities: TLWPTCompilerCapabilities);
function BuildResultErrorMessage(const AResult: TLWPTBuildResult): string;
procedure ValidateReportedArtifacts(const ACompilerID: string;
  const ARequest: TLWPTBuildRequest; const AResult: TLWPTBuildResult;
  const AErrorContext: string = '');

implementation

uses
  SysUtils;

procedure TLWPTCompilerDriver.ConfigureCommand(const ACommand: string;
  const AArguments: array of string; const AWorkingDirectory: string);
var
  i: Integer;
begin
  FCommandOverride := ACommand;
  FCommandWorkingDirectory := AWorkingDirectory;
  SetLength(FCommandArguments, Length(AArguments));
  for i := 0 to High(AArguments) do FCommandArguments[i] := AArguments[i];
end;

function TLWPTCompilerDriver.WorkingDirectory: string;
begin
  Result := FCommandWorkingDirectory;
end;

function TLWPTCompilerDriver.ConfiguredCommand(
  const ADefault: string): string;
begin
  if FCommandOverride <> '' then Result := FCommandOverride
  else Result := ADefault;
end;

function TLWPTCompilerDriver.CommandArgumentCount: Integer;
begin
  Result := Length(FCommandArguments);
end;

function TLWPTCompilerDriver.CommandArgument(const AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex >= Length(FCommandArguments)) then Exit('');
  Result := FCommandArguments[AIndex];
end;

procedure TLWPTCompilerDriver.AppendCommandArguments(
  const AParameters: TStrings);
var
  i: Integer;
begin
  for i := 0 to High(FCommandArguments) do
    AParameters.Add(FCommandArguments[i]);
end;

function TLWPTCompilerDriver.PrependCommandArguments(
  const AArguments: LWPT.Core.TStringArray): LWPT.Core.TStringArray;
var
  i: Integer;
begin
  SetLength(Result, Length(FCommandArguments) + Length(AArguments));
  for i := 0 to High(FCommandArguments) do Result[i] := FCommandArguments[i];
  for i := 0 to High(AArguments) do
    Result[Length(FCommandArguments) + i] := AArguments[i];
end;

function TLWPTCompilerDriver.InvocationArguments(
  const AArguments: LWPT.Core.TStringArray): LWPT.Core.TStringArray;
begin
  Result := PrependCommandArguments(AArguments);
end;

function TLWPTCompilerDriver.VersionConstraint: string;
begin
  Result := '*';
end;

function TLWPTCompilerDriver.CreateBuildRequest(const ASource,
  AArtifact: string): TLWPTBuildRequest;
begin
  Result := CreateBuildRequestForTarget(ASource, AArtifact, DefaultTarget);
end;

function TLWPTCompilerDriver.CreateBuildRequestForTarget(const ASource,
  AArtifact: string; const ATarget: TLWPTTarget): TLWPTBuildRequest;
begin
  Result := DefaultBuildRequest;
  Result.Compiler.ID := CompilerID;
  Result.Compiler.VersionConstraint := VersionConstraint;
  Result.Target := ATarget;
  Result.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.Mode := BUILD_MODE_DEV;
  Result.Inputs.EntryPoint := ASource;
  SetLength(Result.Inputs.Sources, 1);
  Result.Inputs.Sources[0] := ASource;
  Result.Outputs.Artifact := AArtifact;
  if IsWindowsOperatingSystem(Result.Target.OS)
     and (ExtractFileExt(Result.Outputs.Artifact) = '') then
    Result.Outputs.Artifact := Result.Outputs.Artifact + '.exe';
end;

function TLWPTCompilerDriver.BuildStandardInput(
  const ARequest: TLWPTBuildRequest): string;
begin
  Result := '';
end;

function TLWPTCompilerDriver.SeparateStandardError: Boolean;
begin
  Result := False;
end;

function TLWPTCompilerDriver.CompilationTimeoutMilliseconds: QWord;
var
  Configured: Int64;
  Value: string;
begin
  Value := GetEnvironmentVariable(COMPILER_TIMEOUT_ENVIRONMENT);
  if Value = '' then Exit(DEFAULT_COMPILER_TIMEOUT_MILLISECONDS);
  if not TryStrToInt64(Value, Configured) or (Configured <= 0) then
    raise ELWPTCompilerDriverError.CreateFmt(
      '%s must be a positive integer number of milliseconds',
      [COMPILER_TIMEOUT_ENVIRONMENT]);
  Result := QWord(Configured);
end;

function TLWPTCompilerDriver.NormalizeExecutionResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const AStandardOutput, AStandardError: string): TLWPTBuildResult;
begin
  Result := NormalizeResult(ARequest, AExitCode,
    DisplayOutput(AStandardOutput, AStandardError));
end;

function TLWPTCompilerDriver.DisplayOutput(const AStandardOutput,
  AStandardError: string): string;
begin
  Result := AStandardOutput;
  if AStandardError = '' then Exit;
  if (Result <> '') and not (Result[Length(Result)] in [#10, #13]) then
    Result := Result + LineEnding;
  Result := Result + AStandardError;
end;

function BuildCompilerInvocationOptions(const AConfigurationFile: string;
  const AForceRebuild: Boolean): TLWPTCompilerInvocationOptions;
begin
  Result := Default(TLWPTCompilerInvocationOptions);
  Result.ConfigurationFile := AConfigurationFile;
  Result.ArgumentProfile := capBuild;
  if AForceRebuild then Result.RebuildPolicy := crpForce
  else Result.RebuildPolicy := crpIncremental;
end;

function PascalSourceCompilerInvocationOptions(
  const AConfigurationFile: string): TLWPTCompilerInvocationOptions;
begin
  Result := Default(TLWPTCompilerInvocationOptions);
  Result.ConfigurationFile := AConfigurationFile;
  Result.ArgumentProfile := capPascalSource;
  Result.RebuildPolicy := crpIncremental;
end;

function CompilerRequirement(const ARequest: TLWPTBuildRequest): string;
begin
  if ARequest.Compiler.VersionIdentity <> '' then
    Result := 'version identity "' + ARequest.Compiler.VersionIdentity + '"'
  else
    Result := 'version "' + ARequest.Compiler.VersionConstraint + '"';
  Result := Result + ', target "' + ARequest.Target.OS + '/'
    + ARequest.Target.Architecture + '", output "' + ARequest.OutputKind
    + '", mode "' + ARequest.Mode + '"';
end;

procedure EnsureBuildRequestCompatible(const ARequest: TLWPTBuildRequest;
  const ACapabilities: TLWPTCompilerCapabilities);
var
  Reason: string;
begin
  if BuildRequestIsCompatible(ARequest, ACapabilities, Reason) then Exit;
  raise ELWPTCompilerDriverError.CreateFmt(
    'compiler "%s" does not satisfy requirement %s: %s',
    [ARequest.Compiler.ID, CompilerRequirement(ARequest), Reason]);
end;

function BuildResultErrorMessage(const AResult: TLWPTBuildResult): string;
var
  DiagnosticIndex: Integer;
begin
  Result := '';
  for DiagnosticIndex := 0 to High(AResult.Diagnostics) do
    if AResult.Diagnostics[DiagnosticIndex].Severity = DIAGNOSTIC_ERROR then
    begin
      if AResult.Diagnostics[DiagnosticIndex].Path <> '' then
      begin
        Result := AResult.Diagnostics[DiagnosticIndex].Path;
        if AResult.Diagnostics[DiagnosticIndex].Line > 0 then
        begin
          Result := Result + '(' + IntToStr(
            AResult.Diagnostics[DiagnosticIndex].Line);
          if AResult.Diagnostics[DiagnosticIndex].Column > 0 then
            Result := Result + ',' + IntToStr(
              AResult.Diagnostics[DiagnosticIndex].Column);
          Result := Result + ')';
        end;
        Result := Result + ': ';
      end;
      Result := Result + AResult.Diagnostics[DiagnosticIndex].MessageText;
      Exit;
    end;
end;

function PathsEqual(const ALeft, ARight: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ExpandFileName(ALeft), ExpandFileName(ARight));
  {$ELSE}
  Result := ExpandFileName(ALeft) = ExpandFileName(ARight);
  {$ENDIF}
end;

function PathWithinRoot(const APath, ARoot: string): Boolean;
var
  FullPath, FullRoot: string;
begin
  if ARoot = '' then Exit(False);
  FullPath := ExpandFileName(APath);
  FullRoot := IncludeTrailingPathDelimiter(ExpandFileName(ARoot));
  {$IFDEF MSWINDOWS}
  Result := SameText(Copy(FullPath, 1, Length(FullRoot)), FullRoot);
  {$ELSE}
  Result := Copy(FullPath, 1, Length(FullRoot)) = FullRoot;
  {$ENDIF}
end;

procedure ValidateReportedArtifacts(const ACompilerID: string;
  const ARequest: TLWPTBuildRequest; const AResult: TLWPTBuildResult;
  const AErrorContext: string);
var
  ArtifactIndex: Integer;
  FoundPrimary, InPrivateRoot: Boolean;
begin
  FoundPrimary := False;
  for ArtifactIndex := 0 to High(AResult.Artifacts) do
  begin
    if PathsEqual(AResult.Artifacts[ArtifactIndex].Path,
      ARequest.Outputs.Artifact) then
    begin
      if AResult.Artifacts[ArtifactIndex].Kind = ARequest.OutputKind then
        FoundPrimary := True;
      Continue;
    end;
    InPrivateRoot := PathWithinRoot(AResult.Artifacts[ArtifactIndex].Path,
      ARequest.Outputs.ExecutableDirectory)
      or PathWithinRoot(AResult.Artifacts[ArtifactIndex].Path,
        ARequest.Outputs.UnitDirectory)
      or PathWithinRoot(AResult.Artifacts[ArtifactIndex].Path,
        ARequest.Outputs.ObjectDirectory)
      or PathWithinRoot(AResult.Artifacts[ArtifactIndex].Path,
        ARequest.Outputs.ResourceDirectory);
    if not InPrivateRoot then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler driver "%s" reported artifact outside the declared '
        + 'private output roots: %s%s',
        [ACompilerID, AResult.Artifacts[ArtifactIndex].Path, AErrorContext]);
  end;
  if AResult.Success and not FoundPrimary then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler driver "%s" did not report the requested primary artifact '
      + '%s%s', [ACompilerID, ARequest.Outputs.Artifact, AErrorContext]);
end;

end.
