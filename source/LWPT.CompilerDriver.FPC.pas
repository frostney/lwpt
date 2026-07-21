{ LWPT.CompilerDriver.FPC — FreePascal compiler-driver implementation. }
unit LWPT.CompilerDriver.FPC;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core;

const
  FPC_COMPILER_ID = 'fpc';

type
  TLWPTFPCCompilerDriver = class(TLWPTCompilerDriver)
  private
    FExecutableName: string;
    FDefaultTarget: TLWPTTarget;
    FDefaultTargetError: string;
    FDefaultTargetProbed: Boolean;
    FDefaultVersion: string;
    FProbeCache: TList;
    FProbeCriticalSection: TRTLCriticalSection;
    function FindProbe(const ATarget: TLWPTTarget): Integer;
    function ProbeArguments(const ATarget: TLWPTTarget;
      const ADispatch: Boolean):
      LWPT.Core.TStringArray;
    function TargetRequiresDispatch(const ATarget: TLWPTTarget): Boolean;
  protected
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AOutput: string): Integer; virtual;
  public
    constructor Create(const AExecutableName: string = '');
    destructor Destroy; override;
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

function CreateFPCBuildRequest(const ASource, AArtifact: string;
  const ADriver: TLWPTCompilerDriver): TLWPTBuildRequest;

implementation

uses
  Process,
  StrUtils,
  SysUtils;

const
  FPC_PROCESSOR_X86 = 'x86';
  FPC_PROCESSOR_I386 = 'i386';
  FPC_PROCESSOR_X86_64 = 'x86_64';
  FPC_PROCESSOR_AARCH64 = 'aarch64';
  FPC_OS_WINDOWS = 'windows';
  FPC_OS_WIN32 = 'win32';
  FPC_OS_WIN64 = 'win64';
  FPC_PROCESSOR_FLAG = '-P';
  FPC_OPERATING_SYSTEM_FLAG = '-T';
  FPC_PROBE_VERSION_FLAG = '-iV';
  FPC_PROBE_OS_FLAG = '-iTO';
  FPC_PROBE_PROCESSOR_FLAG = '-iTP';
  FPC_SHARED_STRING_FLAG = '-Sh';
  FPC_RELEASE_OPTIMIZATION_FLAG = '-O4';
  FPC_RELEASE_STRIP_FLAG = '-Xs';
  FPC_RELEASE_SMART_LINK_FLAG = '-CX';
  FPC_RELEASE_SMART_LINK_UNITS_FLAG = '-XX';
  FPC_DEV_OPTIMIZATION_FLAG = '-O-';
  FPC_DEV_DEBUG_INFO_FLAG = '-gw';
  FPC_DEV_DWARF_SETS_FLAG = '-godwarfsets';
  FPC_DEV_LINE_INFO_FLAG = '-gl';
  FPC_DEV_STACK_CHECK_FLAG = '-Ct';
  FPC_DEV_RANGE_CHECK_FLAG = '-Cr';
  FPC_DEV_ASSERTIONS_FLAG = '-Sa';
  FPC_FORCE_REBUILD_FLAG = '-B';
  FPC_OUTPUT_FLAG = '-o';
  FPC_STALE_COMPILATION_SIGNATURE = 'compilation raised exception internally';
  FPC_STALE_RESOURCE_SIGNATURE = 'error while compiling resources';
  FPC_RESOURCE_LIST_EXTENSION = '.reslst';
  FPC_CANNOT_OPEN_SIGNATURE = 'cannot open';
  FPC_NOT_FOUND_SIGNATURE = 'not found';
  FPC_NO_SUCH_FILE_SIGNATURE = 'no such file';

type
  TLWPTFPCProbeCacheEntry = class
  private
    FTarget: TLWPTTarget;
    FCapabilities: TLWPTCompilerCapabilities;
    FDispatchRequired: Boolean;
    FErrorMessage: string;
  public
    constructor Create(const ATarget: TLWPTTarget);
    function CopyCapabilities: TLWPTCompilerCapabilities;
    procedure StoreCapabilities(const ACapabilities: TLWPTCompilerCapabilities);
    property DispatchRequired: Boolean read FDispatchRequired
      write FDispatchRequired;
    property ErrorMessage: string read FErrorMessage write FErrorMessage;
    property Target: TLWPTTarget read FTarget;
  end;

function CopyCapabilities(const ACapabilities: TLWPTCompilerCapabilities):
  TLWPTCompilerCapabilities;
begin
  Result := ACapabilities;
  Result.Targets := Copy(ACapabilities.Targets, 0,
    Length(ACapabilities.Targets));
  Result.OutputKinds := Copy(ACapabilities.OutputKinds, 0,
    Length(ACapabilities.OutputKinds));
  Result.Modes := Copy(ACapabilities.Modes, 0, Length(ACapabilities.Modes));
end;

constructor TLWPTFPCProbeCacheEntry.Create(const ATarget: TLWPTTarget);
begin
  inherited Create;
  FTarget := ATarget;
  FCapabilities := DefaultCompilerCapabilities;
end;

function TLWPTFPCProbeCacheEntry.CopyCapabilities:
  TLWPTCompilerCapabilities;
begin
  Result := LWPT.CompilerDriver.FPC.CopyCapabilities(FCapabilities);
end;

procedure TLWPTFPCProbeCacheEntry.StoreCapabilities(
  const ACapabilities: TLWPTCompilerCapabilities);
begin
  FCapabilities := LWPT.CompilerDriver.FPC.CopyCapabilities(ACapabilities);
end;

function TargetsEqual(const ALeft, ARight: TLWPTTarget): Boolean;
begin
  Result := (ALeft.OS = ARight.OS)
    and (ALeft.Architecture = ARight.Architecture)
    and (ALeft.ABI = ARight.ABI)
    and (ALeft.Environment = ARight.Environment);
end;

function EquivalentProcessor(const ARequested, AActual: string): Boolean;
begin
  Result := (ARequested = AActual)
    or (((ARequested = FPC_PROCESSOR_X86)
      or (ARequested = FPC_PROCESSOR_I386))
      and ((AActual = FPC_PROCESSOR_X86)
        or (AActual = FPC_PROCESSOR_I386)));
end;

{ The neutral "windows" OS accepts only the concrete OS its architecture
  maps to (win32 for x86/i386, win64 for x86_64/aarch64) -- a win32 probe
  answer must not satisfy a windows/x86_64 request. }
function EquivalentOperatingSystem(const ATarget: TLWPTTarget;
  const AActual: string): Boolean;
begin
  Result := ATarget.OS = AActual;
  if Result or (ATarget.OS <> FPC_OS_WINDOWS) then Exit;
  if (ATarget.Architecture = FPC_PROCESSOR_X86)
     or (ATarget.Architecture = FPC_PROCESSOR_I386) then
    Result := AActual = FPC_OS_WIN32
  else if (ATarget.Architecture = FPC_PROCESSOR_X86_64)
     or (ATarget.Architecture = FPC_PROCESSOR_AARCH64) then
    Result := AActual = FPC_OS_WIN64;
end;

function IsWindowsOperatingSystem(const AOS: string): Boolean;
begin
  Result := (AOS = FPC_OS_WINDOWS) or (AOS = FPC_OS_WIN32)
    or (AOS = FPC_OS_WIN64);
end;

function FPCOperatingSystemName(const ATarget: TLWPTTarget): string;
begin
  if ATarget.OS <> FPC_OS_WINDOWS then Exit(ATarget.OS);
  if (ATarget.Architecture = FPC_PROCESSOR_X86)
     or (ATarget.Architecture = FPC_PROCESSOR_I386) then
    Exit(FPC_OS_WIN32);
  if (ATarget.Architecture = FPC_PROCESSOR_X86_64)
     or (ATarget.Architecture = FPC_PROCESSOR_AARCH64) then
    Exit(FPC_OS_WIN64);
  raise ELWPTCompilerDriverError.CreateFmt(
    'compiler "%s" does not support neutral Windows target architecture "%s"',
    [FPC_COMPILER_ID, ATarget.Architecture]);
end;

procedure AddDispatchArguments(const ATarget: TLWPTTarget;
  const AArguments: TStrings);
begin
  if ATarget.Architecture = FPC_PROCESSOR_X86 then
    AArguments.Add(FPC_PROCESSOR_FLAG + FPC_PROCESSOR_I386)
  else
    AArguments.Add(FPC_PROCESSOR_FLAG + ATarget.Architecture);
  AArguments.Add(FPC_OPERATING_SYSTEM_FLAG
    + FPCOperatingSystemName(ATarget));
end;

function CreateFPCBuildRequest(const ASource, AArtifact: string;
  const ADriver: TLWPTCompilerDriver): TLWPTBuildRequest;
var
  DefaultTarget: TLWPTTarget;
begin
  if not Assigned(ADriver) then
    raise ELWPTCompilerDriverError.Create('compiler driver is required');
  Result := DefaultBuildRequest;
  Result.Compiler.ID := FPC_COMPILER_ID;
  Result.Compiler.VersionConstraint := '*';
  Result.Target.OS := SysUtils.GetEnvironmentVariable('FPC_TARGET_OS');
  Result.Target.Architecture := SysUtils.GetEnvironmentVariable(
    'FPC_TARGET_CPU');
  if (Result.Target.OS = '') or (Result.Target.Architecture = '') then
  begin
    DefaultTarget := ADriver.DefaultTarget;
    if Result.Target.OS = '' then Result.Target.OS := DefaultTarget.OS;
    if Result.Target.Architecture = '' then
      Result.Target.Architecture := DefaultTarget.Architecture;
  end;
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

function FirstOutputLine(const AOutput: string): string;
var
  LineEnd: Integer;
begin
  Result := Trim(AOutput);
  LineEnd := Pos(#10, Result);
  if LineEnd > 0 then Result := Trim(Copy(Result, 1, LineEnd - 1));
end;

function ParseProbeOutput(const AOutput: string; out AVersion,
  AOperatingSystem, AProcessor: string): Boolean;
var
  Fields: TStringList;
  Normalized: string;
  FieldIndex: Integer;
begin
  AVersion := '';
  AOperatingSystem := '';
  AProcessor := '';
  Normalized := StringReplace(Trim(AOutput), #13, ' ', [rfReplaceAll]);
  Normalized := StringReplace(Normalized, #10, ' ', [rfReplaceAll]);
  Fields := TStringList.Create;
  try
    Fields.Delimiter := ' ';
    Fields.StrictDelimiter := True;
    Fields.DelimitedText := Normalized;
    FieldIndex := 0;
    while (FieldIndex < Fields.Count) and (Fields[FieldIndex] = '') do
      Inc(FieldIndex);
    if FieldIndex < Fields.Count then AVersion := Fields[FieldIndex];
    Inc(FieldIndex);
    while (FieldIndex < Fields.Count) and (Fields[FieldIndex] = '') do
      Inc(FieldIndex);
    if FieldIndex < Fields.Count then AOperatingSystem := Fields[FieldIndex];
    Inc(FieldIndex);
    while (FieldIndex < Fields.Count) and (Fields[FieldIndex] = '') do
      Inc(FieldIndex);
    if FieldIndex < Fields.Count then AProcessor := Fields[FieldIndex];
  finally
    Fields.Free;
  end;
  Result := (AVersion <> '') and (AOperatingSystem <> '')
    and (AProcessor <> '');
end;

procedure AddConfigurationArguments(const APath: string;
  const AExpand: Boolean; const AArguments: TStrings);
var
  ConfigurationLines: TStringList;
  ConfigurationLine: string;
  LineIndex: Integer;
begin
  if (APath = '') or (not FileExists(APath)) then Exit;
  if not AExpand then
  begin
    AArguments.Add('@' + APath);
    Exit;
  end;
  ConfigurationLines := TStringList.Create;
  try
    ConfigurationLines.LoadFromFile(APath);
    for LineIndex := 0 to ConfigurationLines.Count - 1 do
    begin
      ConfigurationLine := Trim(ConfigurationLines[LineIndex]);
      if (ConfigurationLine = '') or (ConfigurationLine[1] = '#') then
        Continue;
      AArguments.Add(ConfigurationLine);
    end;
  finally
    ConfigurationLines.Free;
  end;
end;

procedure AddBuildModeArguments(const ARequest: TLWPTBuildRequest;
  const AArguments: TStrings);
var
  DefineIndex: Integer;
begin
  AArguments.Add(FPC_SHARED_STRING_FLAG);
  if ARequest.Mode = BUILD_MODE_RELEASE then
  begin
    AArguments.Add(FPC_RELEASE_OPTIMIZATION_FLAG);
  end
  else
    AArguments.Add(FPC_DEV_OPTIMIZATION_FLAG);
  for DefineIndex := 0 to High(ARequest.Inputs.Defines) do
    if ARequest.Inputs.Defines[DefineIndex] <> '' then
      AArguments.Add('-d' + ARequest.Inputs.Defines[DefineIndex]);
  if ARequest.Mode = BUILD_MODE_RELEASE then
  begin
    AArguments.Add(FPC_RELEASE_STRIP_FLAG);
    AArguments.Add(FPC_RELEASE_SMART_LINK_FLAG);
    AArguments.Add(FPC_RELEASE_SMART_LINK_UNITS_FLAG);
    AArguments.Add(FPC_FORCE_REBUILD_FLAG);
  end
  else
  begin
    AArguments.Add(FPC_DEV_DEBUG_INFO_FLAG);
    AArguments.Add(FPC_DEV_DWARF_SETS_FLAG);
    AArguments.Add(FPC_DEV_LINE_INFO_FLAG);
    AArguments.Add(FPC_DEV_STACK_CHECK_FLAG);
    AArguments.Add(FPC_DEV_RANGE_CHECK_FLAG);
    AArguments.Add(FPC_DEV_ASSERTIONS_FLAG);
  end;
end;

function FindLastCharacter(const AValue: string; const ACharacter: Char):
  Integer;
begin
  for Result := Length(AValue) downto 1 do
    if AValue[Result] = ACharacter then Exit;
  Result := 0;
end;

function ParseDiagnosticOrigin(const APrefix: string; out APath: string;
  out ALine, AColumn: Integer): Boolean;
var
  ClosingParenthesis, Comma, OpeningParenthesis: Integer;
  Coordinates: string;
begin
  Result := False;
  APath := '';
  ALine := 0;
  AColumn := 0;
  ClosingParenthesis := Length(APrefix);
  if (ClosingParenthesis = 0)
     or (APrefix[ClosingParenthesis] <> ')') then Exit;
  OpeningParenthesis := FindLastCharacter(APrefix, '(');
  if OpeningParenthesis <= 1 then Exit;
  Coordinates := Copy(APrefix, OpeningParenthesis + 1,
    ClosingParenthesis - OpeningParenthesis - 1);
  Comma := Pos(',', Coordinates);
  if Comma > 0 then
  begin
    if not TryStrToInt(Trim(Copy(Coordinates, 1, Comma - 1)), ALine)
       or not TryStrToInt(Trim(Copy(Coordinates, Comma + 1,
         MaxInt)), AColumn) then Exit;
  end
  else if not TryStrToInt(Trim(Coordinates), ALine) then Exit;
  APath := Trim(Copy(APrefix, 1, OpeningParenthesis - 1));
  Result := APath <> '';
end;

function DiagnosticSeverity(const ALine: string; out AMarker: string;
  out AMarkerAt: Integer): string;
const
  MarkerCount = 5;
  Markers: array[0..MarkerCount - 1] of string = (
    'Fatal:', 'Error:', 'Warning:', 'Note:', 'Hint:');
var
  CandidateAt, MarkerIndex, Position: Integer;
  CandidatePrefix, ParsedPath: string;
  CandidateLine, CandidateColumn: Integer;
begin
  Result := '';
  AMarker := '';
  AMarkerAt := 0;
  CandidateAt := MaxInt;
  for MarkerIndex := 0 to MarkerCount - 1 do
  begin
    Position := Pos(Markers[MarkerIndex], ALine);
    while Position > 0 do
    begin
      CandidatePrefix := Trim(Copy(ALine, 1, Position - 1));
      if (Position = 1) or ParseDiagnosticOrigin(CandidatePrefix,
        ParsedPath, CandidateLine, CandidateColumn) then
      begin
        if Position < CandidateAt then
        begin
          CandidateAt := Position;
          AMarker := Markers[MarkerIndex];
          AMarkerAt := Position;
          if MarkerIndex <= 1 then Result := DIAGNOSTIC_ERROR
          else if MarkerIndex = 2 then Result := DIAGNOSTIC_WARNING
          else Result := DIAGNOSTIC_INFO;
        end;
        Break;
      end;
      Position := PosEx(Markers[MarkerIndex], ALine, Position + 1);
    end;
  end;
end;

function OutputHasErrorDiagnostic(
  const ADiagnostics: TLWPTDiagnosticArray): Boolean;
var
  DiagnosticIndex: Integer;
begin
  for DiagnosticIndex := 0 to High(ADiagnostics) do
    if ADiagnostics[DiagnosticIndex].Severity = DIAGNOSTIC_ERROR then
      Exit(True);
  Result := False;
end;

function OutputHasStaleArtefactSignature(const AOutput: string): Boolean;
var
  LowercaseOutput: string;
begin
  LowercaseOutput := LowerCase(AOutput);
  Result :=
    (Pos(FPC_STALE_COMPILATION_SIGNATURE, LowercaseOutput) > 0) or
    (Pos(FPC_STALE_RESOURCE_SIGNATURE, LowercaseOutput) > 0) or
    ((Pos(FPC_RESOURCE_LIST_EXTENSION, LowercaseOutput) > 0) and
     ((Pos(FPC_CANNOT_OPEN_SIGNATURE, LowercaseOutput) > 0) or
      (Pos(FPC_NOT_FOUND_SIGNATURE, LowercaseOutput) > 0) or
      (Pos(FPC_NO_SUCH_FILE_SIGNATURE, LowercaseOutput) > 0)));
end;

constructor TLWPTFPCCompilerDriver.Create(const AExecutableName: string);
begin
  inherited Create;
  if AExecutableName <> '' then
    FExecutableName := AExecutableName
  else
    FExecutableName := FPCExecutable;
  FProbeCache := TList.Create;
  InitCriticalSection(FProbeCriticalSection);
end;

destructor TLWPTFPCCompilerDriver.Destroy;
var
  CacheIndex: Integer;
begin
  for CacheIndex := 0 to FProbeCache.Count - 1 do
    TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).Free;
  FProbeCache.Free;
  DoneCriticalSection(FProbeCriticalSection);
  inherited Destroy;
end;

function TLWPTFPCCompilerDriver.FindProbe(const ATarget: TLWPTTarget):
  Integer;
begin
  for Result := 0 to FProbeCache.Count - 1 do
    if TargetsEqual(TLWPTFPCProbeCacheEntry(FProbeCache[Result]).Target,
      ATarget) then Exit;
  Result := -1;
end;

function TLWPTFPCCompilerDriver.ProbeArguments(const ATarget: TLWPTTarget;
  const ADispatch: Boolean): LWPT.Core.TStringArray;
var
  Arguments: TStringList;
  ArgumentIndex: Integer;
begin
  Result := nil;
  Arguments := TStringList.Create;
  try
    if ADispatch then AddDispatchArguments(ATarget, Arguments);
    Arguments.Add(FPC_PROBE_VERSION_FLAG);
    Arguments.Add(FPC_PROBE_OS_FLAG);
    Arguments.Add(FPC_PROBE_PROCESSOR_FLAG);
    SetLength(Result, Arguments.Count);
    for ArgumentIndex := 0 to Arguments.Count - 1 do
      Result[ArgumentIndex] := Arguments[ArgumentIndex];
  finally
    Arguments.Free;
  end;
end;

function TLWPTFPCCompilerDriver.TargetRequiresDispatch(
  const ATarget: TLWPTTarget): Boolean;
var
  CacheIndex: Integer;
begin
  ProbeCapabilities(ATarget);
  EnterCriticalSection(FProbeCriticalSection);
  try
    { Read dispatch and error state from one locked snapshot: a
      concurrent failed refresh between the probe above and this read
      can rewrite the entry, and a silently-cleared DispatchRequired
      would drop the -P/-T flags from the build invocation. }
    CacheIndex := FindProbe(ATarget);
    if TLWPTFPCProbeCacheEntry(
      FProbeCache[CacheIndex]).ErrorMessage <> '' then
      raise ELWPTCompilerDriverError.Create(TLWPTFPCProbeCacheEntry(
        FProbeCache[CacheIndex]).ErrorMessage);
    Result := TLWPTFPCProbeCacheEntry(
      FProbeCache[CacheIndex]).DispatchRequired;
  finally
    LeaveCriticalSection(FProbeCriticalSection);
  end;
end;

function TLWPTFPCCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AOutput: string): Integer;
var
  ArgumentIndex, BytesRead: Integer;
  Buffer: array[0..PROCESS_OUTPUT_BUFFER_SIZE - 1] of Byte;
  CompilerProcess: TProcess;
begin
  AOutput := '';
  CompilerProcess := TProcess.Create(nil);
  try
    CompilerProcess.Executable := FExecutableName;
    for ArgumentIndex := 0 to High(AArguments) do
      CompilerProcess.Parameters.Add(AArguments[ArgumentIndex]);
    CompilerProcess.Options := [poUsePipes, poStderrToOutPut];
    CompilerProcess.Execute;
    repeat
      BytesRead := CompilerProcess.Output.Read(Buffer[0], SizeOf(Buffer));
      if BytesRead > 0 then
        AppendRawBytes(AOutput, Buffer[0], BytesRead);
    until BytesRead <= 0;
    CompilerProcess.WaitOnExit;
    Result := CompilerProcess.ExitCode;
    if (Result = 0) and (CompilerProcess.ExitStatus <> 0) then
      Result := CompilerProcess.ExitStatus;
  finally
    CompilerProcess.Free;
  end;
end;

function TLWPTFPCCompilerDriver.DefaultTarget: TLWPTTarget;
var
  Arguments: LWPT.Core.TStringArray;
  CacheIndex, ExitCode: Integer;
  Capabilities: TLWPTCompilerCapabilities;
  Output: string;
begin
  EnterCriticalSection(FProbeCriticalSection);
  try
    if not FDefaultTargetProbed then
    begin
      FDefaultTargetProbed := True;
      Arguments := ProbeArguments(Default(TLWPTTarget), False);
      try
        ExitCode := ExecuteProbe(Arguments, Output);
        if ExitCode <> 0 then
          FDefaultTargetError := 'probe via "' + FExecutableName
            + '" failed (exit ' + IntToStr(ExitCode) + '): '
            + FirstOutputLine(Output)
        else if not ParseProbeOutput(Output, FDefaultVersion,
          FDefaultTarget.OS, FDefaultTarget.Architecture) then
          FDefaultTargetError := 'probe via "' + FExecutableName
            + '" returned incomplete capability output: '
            + FirstOutputLine(Output);
      except
        on E: Exception do
          FDefaultTargetError := 'could not execute "' + FExecutableName
            + '": ' + E.Message;
      end;
      if FDefaultTargetError = '' then
      begin
        Capabilities := DefaultCompilerCapabilities;
        Capabilities.CompilerID := FPC_COMPILER_ID;
        Capabilities.VersionIdentity := FDefaultVersion;
        SetLength(Capabilities.Targets, 1);
        Capabilities.Targets[0] := FDefaultTarget;
        SetLength(Capabilities.OutputKinds, 2);
        Capabilities.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
        Capabilities.OutputKinds[1] := BUILD_OUTPUT_LIBRARY;
        SetLength(Capabilities.Modes, 2);
        Capabilities.Modes[0] := BUILD_MODE_DEV;
        Capabilities.Modes[1] := BUILD_MODE_RELEASE;
        ValidateCompilerCapabilities(Capabilities);
        CacheIndex := FindProbe(FDefaultTarget);
        if CacheIndex < 0 then
        begin
          CacheIndex := FProbeCache.Count;
          FProbeCache.Add(TLWPTFPCProbeCacheEntry.Create(FDefaultTarget));
        end;
        TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).StoreCapabilities(
          Capabilities);
        TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).DispatchRequired :=
          False;
        TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).ErrorMessage := '';
      end;
    end;
    Result := FDefaultTarget;
  finally
    LeaveCriticalSection(FProbeCriticalSection);
  end;
  if FDefaultTargetError <> '' then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" cannot determine its default target: %s',
      [FPC_COMPILER_ID, FDefaultTargetError]);
end;

function TLWPTFPCCompilerDriver.ProbeCapabilities(
  const ATarget: TLWPTTarget; const ARefresh: Boolean):
  TLWPTCompilerCapabilities;
var
  ActualOperatingSystem, ActualProcessor, ErrorMessage, Output,
    Version: string;
  CacheIndex, ExitCode: Integer;
  Arguments: LWPT.Core.TStringArray;
  DispatchRequired, TargetSatisfied: Boolean;
begin
  ErrorMessage := '';
  EnterCriticalSection(FProbeCriticalSection);
  try
    CacheIndex := FindProbe(ATarget);
    if (CacheIndex >= 0) and (not ARefresh) then
    begin
      Result := TLWPTFPCProbeCacheEntry(
        FProbeCache[CacheIndex]).CopyCapabilities;
      ErrorMessage := TLWPTFPCProbeCacheEntry(
        FProbeCache[CacheIndex]).ErrorMessage;
    end
    else
    begin
      if CacheIndex < 0 then
      begin
        CacheIndex := FProbeCache.Count;
        FProbeCache.Add(TLWPTFPCProbeCacheEntry.Create(ATarget));
      end;
      TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).StoreCapabilities(
        DefaultCompilerCapabilities);
      TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).DispatchRequired :=
        False;
      TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).ErrorMessage := '';
      TargetSatisfied := False;
      Arguments := ProbeArguments(ATarget, False);
      try
        ExitCode := ExecuteProbe(Arguments, Output);
        TargetSatisfied := (ExitCode = 0)
          and ParseProbeOutput(Output, Version, ActualOperatingSystem,
            ActualProcessor)
          and EquivalentOperatingSystem(ATarget, ActualOperatingSystem)
          and EquivalentProcessor(ATarget.Architecture, ActualProcessor);
      except
        on E: Exception do TargetSatisfied := False;
      end;
      DispatchRequired := not TargetSatisfied;
      if DispatchRequired then
      try
        Arguments := ProbeArguments(ATarget, True);
        ExitCode := ExecuteProbe(Arguments, Output);
        if ExitCode <> 0 then
          ErrorMessage := 'probe via "' + FExecutableName
            + '" failed (exit ' + IntToStr(ExitCode) + '): '
            + FirstOutputLine(Output)
        else if not ParseProbeOutput(Output, Version,
          ActualOperatingSystem, ActualProcessor) then
          ErrorMessage := 'probe via "' + FExecutableName
            + '" returned incomplete capability output: '
            + FirstOutputLine(Output)
        else if not EquivalentOperatingSystem(ATarget,
          ActualOperatingSystem) or not EquivalentProcessor(
          ATarget.Architecture, ActualProcessor) then
          ErrorMessage := 'probe via "' + FExecutableName + '" returned target "'
            + ActualOperatingSystem + '/' + ActualProcessor + '"';
      except
        on E: Exception do
          ErrorMessage := 'could not execute "' + FExecutableName
            + '": ' + E.Message;
      end;
      if ErrorMessage = '' then
      begin
        Result := DefaultCompilerCapabilities;
        Result.CompilerID := FPC_COMPILER_ID;
        Result.VersionIdentity := Version;
        SetLength(Result.Targets, 1);
        Result.Targets[0].OS := ATarget.OS;
        Result.Targets[0].Architecture := ATarget.Architecture;
        SetLength(Result.OutputKinds, 2);
        Result.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
        Result.OutputKinds[1] := BUILD_OUTPUT_LIBRARY;
        SetLength(Result.Modes, 2);
        Result.Modes[0] := BUILD_MODE_DEV;
        Result.Modes[1] := BUILD_MODE_RELEASE;
        ValidateCompilerCapabilities(Result);
        TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).StoreCapabilities(
          Result);
        TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).DispatchRequired :=
          DispatchRequired;
      end;
      TLWPTFPCProbeCacheEntry(FProbeCache[CacheIndex]).ErrorMessage :=
        ErrorMessage;
      Result := TLWPTFPCProbeCacheEntry(
        FProbeCache[CacheIndex]).CopyCapabilities;
    end;
  finally
    LeaveCriticalSection(FProbeCriticalSection);
  end;
  if ErrorMessage <> '' then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" cannot satisfy required target "%s/%s": %s',
      [FPC_COMPILER_ID, ATarget.OS, ATarget.Architecture, ErrorMessage]);
end;

function TLWPTFPCCompilerDriver.BuildArguments(
  const ARequest: TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions):
  LWPT.Core.TStringArray;
var
  Arguments: TStringList;
  ArgumentIndex, PathIndex: Integer;
  ForceRebuildAdded: Boolean;
begin
  Result := nil;
  ValidateBuildRequest(ARequest);
  Arguments := TStringList.Create;
  try
    if TargetRequiresDispatch(ARequest.Target) then
      AddDispatchArguments(ARequest.Target, Arguments);
    ForceRebuildAdded := False;
    if AOptions.ArgumentProfile = capPascalSource then
      Arguments.Add(FPC_SHARED_STRING_FLAG);
    if ARequest.Outputs.ExecutableDirectory <> '' then
      Arguments.Add('-FE' + ARequest.Outputs.ExecutableDirectory);
    if ARequest.Outputs.UnitDirectory <> '' then
      Arguments.Add('-FU' + ARequest.Outputs.UnitDirectory);
    AddConfigurationArguments(AOptions.ConfigurationFile,
      AOptions.ArgumentProfile = capPascalSource, Arguments);
    if AOptions.ArgumentProfile = capPascalSource then
      AddEnvUnitPathParameters(Arguments);
    for PathIndex := 0 to High(ARequest.Inputs.UnitPaths) do
      if ARequest.Inputs.UnitPaths[PathIndex] <> '' then
        Arguments.Add('-Fu' + ARequest.Inputs.UnitPaths[PathIndex]);
    for PathIndex := 0 to High(ARequest.Inputs.IncludePaths) do
      if ARequest.Inputs.IncludePaths[PathIndex] <> '' then
        Arguments.Add('-Fi' + ARequest.Inputs.IncludePaths[PathIndex]);
    if AOptions.ArgumentProfile = capBuild then
    begin
      AddBuildModeArguments(ARequest, Arguments);
      ForceRebuildAdded := ARequest.Mode = BUILD_MODE_RELEASE;
    end;
    if (AOptions.RebuildPolicy = crpForce) and (not ForceRebuildAdded) then
      Arguments.Add(FPC_FORCE_REBUILD_FLAG);
    Arguments.Add(FPC_OUTPUT_FLAG + ARequest.Outputs.Artifact);
    Arguments.Add(ARequest.Inputs.EntryPoint);
    SetLength(Result, Arguments.Count);
    for ArgumentIndex := 0 to Arguments.Count - 1 do
      Result[ArgumentIndex] := Arguments[ArgumentIndex];
  finally
    Arguments.Free;
  end;
end;

function TLWPTFPCCompilerDriver.ExecutableName: string;
begin
  Result := FExecutableName;
end;

function TLWPTFPCCompilerDriver.ClassifyFailure(const AExitCode: Integer;
  const ARawOutput: string): TLWPTCompilerFailure;
begin
  Result := Default(TLWPTCompilerFailure);
  if AExitCode = 0 then Exit;
  Result.Kind := cfkCompilation;
  Result.Summary := 'FAILED (' + FPC_COMPILER_ID + ' exit '
    + IntToStr(AExitCode) + ')';
  if OutputHasStaleArtefactSignature(ARawOutput) then
  begin
    Result.Kind := cfkStaleArtefact;
    Result.Recovery := 'hint: stale FPC build artefacts can cause this error.';
  end;
end;

function TLWPTFPCCompilerDriver.NormalizeResult(
  const ARequest: TLWPTBuildRequest; const AExitCode: Integer;
  const ARawOutput: string): TLWPTBuildResult;
var
  Diagnostic: TLWPTDiagnostic;
  DiagnosticCount, LineIndex, MarkerAt: Integer;
  Failure: TLWPTCompilerFailure;
  Lines: TStringList;
  Marker, Prefix, Severity: string;
begin
  Result := DefaultBuildResult;
  Lines := TStringList.Create;
  try
    Lines.Text := ARawOutput;
    for LineIndex := 0 to Lines.Count - 1 do
    begin
      Severity := DiagnosticSeverity(Lines[LineIndex], Marker, MarkerAt);
      if Severity = '' then Continue;
      Diagnostic := Default(TLWPTDiagnostic);
      Diagnostic.Severity := Severity;
      Diagnostic.MessageText := Trim(Copy(Lines[LineIndex],
        MarkerAt + Length(Marker), MaxInt));
      if Diagnostic.MessageText = '' then
        Diagnostic.MessageText := Trim(Lines[LineIndex]);
      Prefix := Trim(Copy(Lines[LineIndex], 1, MarkerAt - 1));
      ParseDiagnosticOrigin(Prefix, Diagnostic.Path,
        Diagnostic.Line, Diagnostic.Column);
      DiagnosticCount := Length(Result.Diagnostics);
      SetLength(Result.Diagnostics, DiagnosticCount + 1);
      Result.Diagnostics[DiagnosticCount] := Diagnostic;
    end;
  finally
    Lines.Free;
  end;
  Result.Success := (AExitCode = 0)
    and (not OutputHasErrorDiagnostic(Result.Diagnostics));
  if (not Result.Success)
     and (not OutputHasErrorDiagnostic(Result.Diagnostics)) then
  begin
    Failure := ClassifyFailure(AExitCode, ARawOutput);
    SetLength(Result.Diagnostics, Length(Result.Diagnostics) + 1);
    Result.Diagnostics[High(Result.Diagnostics)].Severity := DIAGNOSTIC_ERROR;
    Result.Diagnostics[High(Result.Diagnostics)].MessageText := Failure.Summary;
  end;
  if Result.Success then
  begin
    SetLength(Result.Artifacts, 1);
    Result.Artifacts[0].Kind := ARequest.OutputKind;
    Result.Artifacts[0].Path := ARequest.Outputs.Artifact;
    if IsWindowsOperatingSystem(ARequest.Target.OS)
       and (ARequest.OutputKind = BUILD_OUTPUT_EXECUTABLE)
       and (ExtractFileExt(Result.Artifacts[0].Path) = '') then
      Result.Artifacts[0].Path := Result.Artifacts[0].Path + '.exe';
  end;
  ValidateBuildResult(Result);
end;

end.
