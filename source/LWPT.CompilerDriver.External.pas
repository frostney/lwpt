{ LWPT.CompilerDriver.External — short-lived root-owned driver protocol. }
unit LWPT.CompilerDriver.External;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core;

type
  TLWPTExternalCompilerDriver = class(TLWPTCompilerDriver)
  private
    FCompilerID: string;
    FExecutableName: string;
    FPrefixArgument: string;
    FVersionConstraint: string;
    FProbeCache: TList;
    FProbeCriticalSection: TRTLCriticalSection;
    function ExecuteProtocolOperation(const AOperation, AInput: string;
      out AStandardOutput, AStandardError: string): Integer;
    function FindProbe(const ATarget: TLWPTTarget): Integer;
  public
    constructor Create(const ACompilerID, AExecutableName,
      APrefixArgument, AVersionConstraint: string);
    destructor Destroy; override;
    function CompilerID: string; override;
    function VersionConstraint: string; override;
    function DefaultTarget: TLWPTTarget; override;
    function ProbeCapabilities(const ATarget: TLWPTTarget;
      const ARefresh: Boolean = False): TLWPTCompilerCapabilities; override;
    function BuildArguments(const ARequest: TLWPTBuildRequest;
      const AOptions: TLWPTCompilerInvocationOptions):
      LWPT.Core.TStringArray; override;
    function ExecutableName: string; override;
    function BuildStandardInput(const ARequest: TLWPTBuildRequest): string;
      override;
    function SeparateStandardError: Boolean; override;
    function ClassifyFailure(const AExitCode: Integer;
      const ARawOutput: string): TLWPTCompilerFailure; override;
    function NormalizeResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const ARawOutput: string):
      TLWPTBuildResult; override;
    function NormalizeExecutionResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const AStandardOutput,
      AStandardError: string): TLWPTBuildResult; override;
    function DisplayOutput(const AStandardOutput,
      AStandardError: string): string; override;
  end;

implementation

uses
  Process,
  SysUtils,

  LWPT.ProcessRunner;

const
  EXTERNAL_DRIVER_PROBE_TIMEOUT_MILLISECONDS = 30000;
  EXTERNAL_DRIVER_DIAGNOSTIC_CONTEXT_BYTES = 4096;

type
  TLWPTExternalProbeCacheEntry = class
  public
    Target: TLWPTTarget;
    Capabilities: TLWPTCompilerCapabilities;
  end;

function TargetsEqual(const ALeft, ARight: TLWPTTarget): Boolean;
begin
  Result := (ALeft.OS = ARight.OS)
    and (ALeft.Architecture = ARight.Architecture)
    and (ALeft.ABI = ARight.ABI)
    and (ALeft.Environment = ARight.Environment);
end;

function CopyCapabilities(const ACapabilities: TLWPTCompilerCapabilities):
  TLWPTCompilerCapabilities;
begin
  Result := ACapabilities;
  Result.Targets := Copy(ACapabilities.Targets, 0,
    Length(ACapabilities.Targets));
  Result.OutputKinds := Copy(ACapabilities.OutputKinds, 0,
    Length(ACapabilities.OutputKinds));
  Result.Modes := Copy(ACapabilities.Modes, 0,
    Length(ACapabilities.Modes));
end;

function BoundedDiagnosticContext(const AStandardError: string): string;
begin
  Result := Trim(AStandardError);
  if Length(Result) > EXTERNAL_DRIVER_DIAGNOSTIC_CONTEXT_BYTES then
    Result := Copy(Result,
      Length(Result) - EXTERNAL_DRIVER_DIAGNOSTIC_CONTEXT_BYTES + 1,
      EXTERNAL_DRIVER_DIAGNOSTIC_CONTEXT_BYTES);
  if Result <> '' then Result := '; stderr: ' + Result;
end;

constructor TLWPTExternalCompilerDriver.Create(const ACompilerID,
  AExecutableName, APrefixArgument, AVersionConstraint: string);
begin
  inherited Create;
  FCompilerID := ACompilerID;
  FExecutableName := AExecutableName;
  FPrefixArgument := APrefixArgument;
  FVersionConstraint := AVersionConstraint;
  FProbeCache := TList.Create;
  InitCriticalSection(FProbeCriticalSection);
end;

destructor TLWPTExternalCompilerDriver.Destroy;
var
  i: Integer;
begin
  for i := 0 to FProbeCache.Count - 1 do
    TLWPTExternalProbeCacheEntry(FProbeCache[i]).Free;
  FProbeCache.Free;
  DoneCriticalSection(FProbeCriticalSection);
  inherited Destroy;
end;

function TLWPTExternalCompilerDriver.CompilerID: string;
begin
  Result := FCompilerID;
end;

function TLWPTExternalCompilerDriver.VersionConstraint: string;
begin
  Result := FVersionConstraint;
end;

function TLWPTExternalCompilerDriver.FindProbe(
  const ATarget: TLWPTTarget): Integer;
begin
  for Result := 0 to FProbeCache.Count - 1 do
    if TargetsEqual(TLWPTExternalProbeCacheEntry(
      FProbeCache[Result]).Target, ATarget) then Exit;
  Result := -1;
end;

function TLWPTExternalCompilerDriver.ExecuteProtocolOperation(
  const AOperation, AInput: string; out AStandardOutput,
  AStandardError: string): Integer;
var
  DriverProcess: TProcess;
  Options: TLWPTProcessRunOptions;
  ProcessRunner: TLWPTDuplexProcessRunner;
begin
  AStandardOutput := '';
  AStandardError := '';
  DriverProcess := TProcess.Create(nil);
  ProcessRunner := nil;
  try
    DriverProcess.Executable := FExecutableName;
    if FPrefixArgument <> '' then
      DriverProcess.Parameters.Add(FPrefixArgument);
    DriverProcess.Parameters.Add(AOperation);
    Options := DefaultProcessRunOptions('compiler driver "'
      + FCompilerID + '" ' + AOperation);
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds :=
      EXTERNAL_DRIVER_PROBE_TIMEOUT_MILLISECONDS;
    ProcessRunner := TLWPTDuplexProcessRunner.Create(DriverProcess);
    Result := ProcessRunner.Run(AInput, Options, AStandardOutput,
      AStandardError);
  finally
    ProcessRunner.Free;
    DriverProcess.Free;
  end;
end;

function TLWPTExternalCompilerDriver.DefaultTarget: TLWPTTarget;
var
  Capabilities: TLWPTCompilerCapabilities;
begin
  Capabilities := ProbeCapabilities(Default(TLWPTTarget));
  if Length(Capabilities.Targets) = 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler driver "%s" advertised no default target', [FCompilerID]);
  Result := Capabilities.Targets[0];
end;

function TLWPTExternalCompilerDriver.ProbeCapabilities(
  const ATarget: TLWPTTarget; const ARefresh: Boolean):
  TLWPTCompilerCapabilities;
var
  CacheIndex, ExitCode: Integer;
  CacheEntry: TLWPTExternalProbeCacheEntry;
  ProbeRequest: TLWPTCompilerProbeRequest;
  StandardOutput, StandardError: string;
begin
  EnterCriticalSection(FProbeCriticalSection);
  try
    CacheIndex := FindProbe(ATarget);
    if (CacheIndex >= 0) and not ARefresh then
      Exit(CopyCapabilities(TLWPTExternalProbeCacheEntry(
        FProbeCache[CacheIndex]).Capabilities));

    ProbeRequest := DefaultCompilerProbeRequest;
    ProbeRequest.Compiler.ID := FCompilerID;
    ProbeRequest.Compiler.VersionConstraint := FVersionConstraint;
    ProbeRequest.Target := ATarget;
    ExitCode := ExecuteProtocolOperation('probe',
      SerializeCompilerProbeRequest(ProbeRequest), StandardOutput,
      StandardError);
    if ExitCode <> 0 then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler driver "%s" probe failed with exit %d%s',
        [FCompilerID, ExitCode,
         BoundedDiagnosticContext(StandardError)]);
    try
      Result := ParseCompilerCapabilities(StandardOutput);
    except
      on E: Exception do
        raise ELWPTCompilerDriverError.CreateFmt(
          'compiler driver "%s" probe returned an invalid capability '
          + 'document: %s%s', [FCompilerID, E.Message,
            BoundedDiagnosticContext(StandardError)]);
    end;
    if not SameText(Result.CompilerID, FCompilerID) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler driver "%s" probe returned compiler identity "%s"%s',
        [FCompilerID, Result.CompilerID,
         BoundedDiagnosticContext(StandardError)]);
    if CacheIndex < 0 then
    begin
      CacheEntry := TLWPTExternalProbeCacheEntry.Create;
      CacheEntry.Target := ATarget;
      FProbeCache.Add(CacheEntry);
    end
    else
      CacheEntry := TLWPTExternalProbeCacheEntry(FProbeCache[CacheIndex]);
    CacheEntry.Capabilities := CopyCapabilities(Result);
  finally
    LeaveCriticalSection(FProbeCriticalSection);
  end;
end;

function TLWPTExternalCompilerDriver.BuildArguments(
  const ARequest: TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions):
  LWPT.Core.TStringArray;
begin
  if AOptions.RebuildPolicy = crpForce then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler driver "%s" does not support forced rebuilds requested '
      + 'by --clean', [FCompilerID]);
  SetLength(Result, 1 + Ord(FPrefixArgument <> ''));
  if FPrefixArgument <> '' then
  begin
    Result[0] := FPrefixArgument;
    Result[1] := 'compile';
  end
  else
    Result[0] := 'compile';
end;

function TLWPTExternalCompilerDriver.ExecutableName: string;
begin
  Result := FExecutableName;
end;

function TLWPTExternalCompilerDriver.BuildStandardInput(
  const ARequest: TLWPTBuildRequest): string;
begin
  Result := SerializeBuildRequest(ARequest);
end;

function TLWPTExternalCompilerDriver.SeparateStandardError: Boolean;
begin
  Result := True;
end;

function TLWPTExternalCompilerDriver.ClassifyFailure(
  const AExitCode: Integer; const ARawOutput: string): TLWPTCompilerFailure;
begin
  Result := Default(TLWPTCompilerFailure);
  if AExitCode = 0 then Exit;
  Result.Kind := cfkCompilation;
  Result.Summary := 'FAILED (' + FCompilerID + ' driver exit '
    + IntToStr(AExitCode) + ')';
end;

function TLWPTExternalCompilerDriver.NormalizeResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const ARawOutput: string): TLWPTBuildResult;
begin
  Result := NormalizeExecutionResult(ARequest, AExitCode, ARawOutput, '');
end;

function TLWPTExternalCompilerDriver.NormalizeExecutionResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const AStandardOutput, AStandardError: string): TLWPTBuildResult;
begin
  if Trim(AStandardOutput) = '' then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler driver "%s" returned no build-result document%s',
      [FCompilerID, BoundedDiagnosticContext(AStandardError)]);
  try
    Result := ParseBuildResult(AStandardOutput);
  except
    on E: Exception do
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler driver "%s" returned an invalid build-result document: '
        + '%s%s', [FCompilerID, E.Message,
          BoundedDiagnosticContext(AStandardError)]);
  end;
  if (AExitCode = 0) <> Result.Success then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler driver "%s" exit %d disagrees with build result success=%s%s',
      [FCompilerID, AExitCode, BoolToStr(Result.Success, True),
       BoundedDiagnosticContext(AStandardError)]);
  ValidateReportedArtifacts(FCompilerID, ARequest, Result,
    BoundedDiagnosticContext(AStandardError));
end;

function TLWPTExternalCompilerDriver.DisplayOutput(const AStandardOutput,
  AStandardError: string): string;
begin
  { stdout is the machine protocol and is never replayed as compiler output. }
  Result := AStandardError;
end;

end.
