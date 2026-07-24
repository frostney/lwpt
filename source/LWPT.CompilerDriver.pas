{ LWPT.CompilerDriver — compiler-neutral invocation seam. }
unit LWPT.CompilerDriver;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.BuildRequest,
  LWPT.Core;

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
  public
    function DefaultTarget: TLWPTTarget; virtual; abstract;
    function ProbeCapabilities(const ATarget: TLWPTTarget;
      const ARefresh: Boolean = False): TLWPTCompilerCapabilities; virtual;
      abstract;
    function BuildArguments(const ARequest: TLWPTBuildRequest;
      const AOptions: TLWPTCompilerInvocationOptions):
      LWPT.Core.TStringArray; virtual; abstract;
    function ExecutableName: string; virtual; abstract;
    function ClassifyFailure(const AExitCode: Integer;
      const ARawOutput: string): TLWPTCompilerFailure; virtual; abstract;
    function NormalizeResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const ARawOutput: string):
      TLWPTBuildResult; virtual; abstract;
  end;

function BuildCompilerInvocationOptions(const AConfigurationFile: string;
  const AForceRebuild: Boolean): TLWPTCompilerInvocationOptions;
function PascalSourceCompilerInvocationOptions(
  const AConfigurationFile: string): TLWPTCompilerInvocationOptions;
procedure EnsureBuildRequestCompatible(const ARequest: TLWPTBuildRequest;
  const ACapabilities: TLWPTCompilerCapabilities);
function BuildResultErrorMessage(const AResult: TLWPTBuildResult): string;

implementation

uses
  SysUtils;

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

end.
