{ LWPT.Command.Health — health subcommand orchestration and reporting. }
unit LWPT.Command.Health;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.Core,
  LWPT.Health;

function BuildHealthReport(const AManifestPath: string;
  const AIncludeHotspots: Boolean; out AHuman, AJSON: string;
  out AFiles: TLWPTHealthFileArray;
  out AViolations: TLWPTHealthViolationArray): Boolean;
function CmdHealth(const AManifestPath: string; const AJSON,
  AIncludeHotspots: Boolean): Integer;

implementation

uses
  Classes,
  Process,
  SysUtils,

  LWPT.Analysis.JSON,
  LWPT.Analysis.Pascal,
  LWPT.Analysis.Scope,
  LWPT.Manifest,
  LWPT.ProcessRunner;

const
  HEALTH_GIT_TIMEOUT_MILLISECONDS = 30000;

type
  TLWPTHealthProjectConfiguration = record
    Name: string;
    Limits: TLWPTHealthLimits;
  end;
  TLWPTHealthProjectConfigurationArray =
    array of TLWPTHealthProjectConfiguration;

function ReadTextFile(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function RunCaptured(const AExecutable: string;
  const AArguments: array of string; out AOutput: string): Integer; forward;

function TryRunCaptured(const AExecutable: string;
  const AArguments: array of string; out AOutput: string;
  out AExitCode: Integer): Boolean;
begin
  Result := False;
  AOutput := '';
  AExitCode := -1;
  try
    AExitCode := RunCaptured(AExecutable, AArguments, AOutput);
    Result := True;
  except
    on Exception do;
  end;
end;

function RunCaptured(const AExecutable: string;
  const AArguments: array of string; out AOutput: string): Integer;
var
  ArgumentIndex: Integer;
  Options: TLWPTProcessRunOptions;
  ProcessInstance: TProcess;
  ProcessRunner: TLWPTDuplexProcessRunner;
  StandardError: string;
begin
  AOutput := '';
  ProcessInstance := TProcess.Create(nil);
  ProcessRunner := nil;
  try
    ProcessInstance.Executable := AExecutable;
    for ArgumentIndex := Low(AArguments) to High(AArguments) do
      ProcessInstance.Parameters.Add(AArguments[ArgumentIndex]);
    Options := DefaultProcessRunOptions('health Git query');
    Options.TimeoutMilliseconds := HEALTH_GIT_TIMEOUT_MILLISECONDS;
    ProcessRunner := TLWPTDuplexProcessRunner.Create(ProcessInstance);
    Result := ProcessRunner.Run('', Options, AOutput, StandardError);
  finally
    ProcessRunner.Free;
    ProcessInstance.Free;
  end;
end;

function CanonicalRelativePath(const ARoot, APath: string): string;
begin
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(
    ExpandFileName(ARoot)), ExpandFileName(APath));
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  if Copy(Result, 1, 2) = './' then Delete(Result, 1, 2);
end;

function ParseNumStat(const AOutput: string; out AChangedLines: Int64):
  Boolean;
var
  Added, Deleted: Int64;
  FirstTab, LineIndex, SecondTab: Integer;
  Lines: TStringList;
  LineText: string;
begin
  Result := False;
  AChangedLines := 0;
  Lines := TStringList.Create;
  try
    Lines.Text := AOutput;
    for LineIndex := 0 to Lines.Count - 1 do
    begin
      LineText := Lines[LineIndex];
      FirstTab := Pos(#9, LineText);
      if FirstTab = 0 then Continue;
      SecondTab := Pos(#9, Copy(LineText, FirstTab + 1, MaxInt));
      if SecondTab = 0 then Continue;
      Inc(SecondTab, FirstTab);
      if (Copy(LineText, 1, FirstTab - 1) = '-')
        or (Copy(LineText, FirstTab + 1, SecondTab - FirstTab - 1) = '-') then
        Continue;
      if not TryStrToInt64(Copy(LineText, 1, FirstTab - 1), Added) then
        Exit;
      if not TryStrToInt64(Copy(LineText, FirstTab + 1,
        SecondTab - FirstTab - 1), Deleted) then Exit;
      Inc(AChangedLines, Added + Deleted);
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function EnrichGitHotspots(const ARoot: string;
  const AScopeFiles: TLWPTAnalysisFileArray; var AFiles: TLWPTHealthFileArray;
  out ADiagnostic: string): Boolean;
var
  ChangedLines: Int64;
  ExitCode, FileIndex: Integer;
  GitOutput, GitRoot, RelativePath: string;

  procedure ClearHotspots;
  var
    ClearIndex: Integer;
  begin
    for ClearIndex := 0 to High(AFiles) do
    begin
      AFiles[ClearIndex].ChangedLines := 0;
      AFiles[ClearIndex].HotspotScore := 0;
    end;
  end;

begin
  ADiagnostic := '';
  GitOutput := '';
  if not TryRunCaptured('git',
    ['-C', ARoot, 'rev-parse', '--show-toplevel'], GitOutput, ExitCode)
    or (ExitCode <> 0) then
  begin
    ADiagnostic := 'Git history unavailable; reporting complexity-only mode';
    ClearHotspots;
    Exit(False);
  end;
  GitRoot := Trim(GitOutput);
  if GitRoot = '' then
  begin
    ADiagnostic := 'Git history unavailable; reporting complexity-only mode';
    ClearHotspots;
    Exit(False);
  end;
  for FileIndex := 0 to High(AFiles) do
  begin
    RelativePath := CanonicalRelativePath(GitRoot,
      AScopeFiles[FileIndex].AbsolutePath);
    GitOutput := '';
    if not TryRunCaptured('git', ['-C', GitRoot, 'log', '--follow',
      '--find-renames', '--format=', '--numstat',
      '-n', IntToStr(HEALTH_GIT_HISTORY_COMMITS), '--', RelativePath],
      GitOutput, ExitCode) or (ExitCode <> 0) then
    begin
      ADiagnostic := 'Git history could not be read consistently; '
        + 'reporting complexity-only mode';
      ClearHotspots;
      Exit(False);
    end;
    if not ParseNumStat(GitOutput, ChangedLines) then
    begin
      ADiagnostic := 'Git changed-line history was malformed; '
        + 'reporting complexity-only mode';
      ClearHotspots;
      Exit(False);
    end;
    AFiles[FileIndex].ChangedLines := ChangedLines;
  end;
  NormalizeHotspots(AFiles);
  Result := True;
end;

function LimitsFromManifest(const AManifest: TManifest): TLWPTHealthLimits;
begin
  Result := DefaultHealthLimits;
  Result.MaxRoutineCyclomatic := AManifest.HealthMaxRoutineCyclomatic;
  Result.MaxRoutineCognitive := AManifest.HealthMaxRoutineCognitive;
  Result.MaxFileCyclomatic := AManifest.HealthMaxFileCyclomatic;
  Result.MaxFileCognitive := AManifest.HealthMaxFileCognitive;
  Result.MaxHotspotScore := AManifest.HealthMaxHotspotScore;
end;

function ResolveProjectConfigurations(const AScope: TLWPTAnalysisScope):
  TLWPTHealthProjectConfigurationArray;
var
  ProjectIndex: Integer;
  ProjectManifest, RootManifest: TManifest;
begin
  RootManifest := LoadManifest(AScope.ManifestPath);
  Result := nil;
  SetLength(Result, Length(AScope.Projects));
  for ProjectIndex := 0 to High(AScope.Projects) do
  begin
    ProjectManifest := LoadManifest(AScope.Projects[ProjectIndex].ManifestPath);
    Result[ProjectIndex].Name := AScope.Projects[ProjectIndex].Name;
    if (ProjectIndex = 0) or ProjectManifest.HealthConfigured then
      Result[ProjectIndex].Limits := LimitsFromManifest(ProjectManifest)
    else
      Result[ProjectIndex].Limits := LimitsFromManifest(RootManifest);
  end;
end;

function FindProjectLimits(
  const AConfigurations: TLWPTHealthProjectConfigurationArray;
  const AProjectName: string): TLWPTHealthLimits;
var
  ProjectIndex: Integer;
begin
  for ProjectIndex := 0 to High(AConfigurations) do
    if AConfigurations[ProjectIndex].Name = AProjectName then
      Exit(AConfigurations[ProjectIndex].Limits);
  Result := DefaultHealthLimits;
end;

function LimitsConfigured(const ALimits: TLWPTHealthLimits): Boolean;
begin
  Result := (ALimits.MaxRoutineCyclomatic >= 0)
    or (ALimits.MaxRoutineCognitive >= 0)
    or (ALimits.MaxFileCyclomatic >= 0)
    or (ALimits.MaxFileCognitive >= 0)
    or (ALimits.MaxHotspotScore >= 0);
end;

function AnyHotspotLimit(
  const AConfigurations: TLWPTHealthProjectConfigurationArray): Boolean;
var
  ProjectIndex: Integer;
begin
  for ProjectIndex := 0 to High(AConfigurations) do
    if AConfigurations[ProjectIndex].Limits.MaxHotspotScore >= 0 then
      Exit(True);
  Result := False;
end;

function HealthRegionKindName(const AKind: TLWPTHealthRegionKind): string;
begin
  case AKind of
    hrRoutine: Result := 'routine';
    hrProgram: Result := 'program';
    hrInitialization: Result := 'initialization';
    hrFinalization: Result := 'finalization';
  end;
end;

function StableFloat(const AValue: Double): string;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := FormatFloat('0.0000', AValue, Settings);
end;

function SerializeHealthPayload(const AFiles: TLWPTHealthFileArray;
  const AViolations: TLWPTHealthViolationArray;
  const AGitEnriched: Boolean): string;
var
  FileIndex, MetricIndex, ViolationIndex: Integer;
begin
  Result := '{"mode":';
  if AGitEnriched then Result := Result + '"git-enriched"'
  else Result := Result + '"complexity-only"';
  Result := Result + ',"git":{"historyCommits":'
    + IntToStr(HEALTH_GIT_HISTORY_COMMITS) + '},"files":[';
  for FileIndex := 0 to High(AFiles) do
  begin
    if FileIndex > 0 then Result := Result + ',';
    Result := Result + '{"project":' + JSONString(AFiles[FileIndex].ProjectName)
      + ',"path":' + JSONString(AFiles[FileIndex].Path)
      + ',"cyclomatic":' + IntToStr(AFiles[FileIndex].Cyclomatic)
      + ',"cognitive":' + IntToStr(AFiles[FileIndex].Cognitive)
      + ',"changedLines":' + IntToStr(AFiles[FileIndex].ChangedLines)
      + ',"hotspotScore":' + StableFloat(AFiles[FileIndex].HotspotScore)
      + ',"regions":[';
    for MetricIndex := 0 to High(AFiles[FileIndex].Metrics) do
    begin
      if MetricIndex > 0 then Result := Result + ',';
      Result := Result + '{"name":'
        + JSONString(AFiles[FileIndex].Metrics[MetricIndex].Name)
        + ',"kind":'
        + JSONString(HealthRegionKindName(
          AFiles[FileIndex].Metrics[MetricIndex].Kind))
        + ',"line":' + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Line)
        + ',"column":'
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Column)
        + ',"cyclomatic":'
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Cyclomatic)
        + ',"cognitive":'
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Cognitive) + '}';
    end;
    Result := Result + ']}';
  end;
  Result := Result + '],"violations":[';
  for ViolationIndex := 0 to High(AViolations) do
  begin
    if ViolationIndex > 0 then Result := Result + ',';
    Result := Result + '{"project":'
      + JSONString(AViolations[ViolationIndex].ProjectName)
      + ',"path":' + JSONString(AViolations[ViolationIndex].Path)
      + ',"region":' + JSONString(AViolations[ViolationIndex].RegionName)
      + ',"limit":' + JSONString(AViolations[ViolationIndex].LimitName)
      + ',"observed":' + StableFloat(AViolations[ViolationIndex].Observed)
      + ',"maximum":' + StableFloat(AViolations[ViolationIndex].Limit) + '}';
  end;
  Result := Result + ']}';
end;

function BuildHumanReport(const AFiles: TLWPTHealthFileArray;
  const AViolations: TLWPTHealthViolationArray;
  const AGitEnriched: Boolean): string;
var
  FileIndex, MetricIndex, ViolationIndex: Integer;
begin
  Result := 'Health: ' + IntToStr(Length(AFiles)) + ' files (';
  if AGitEnriched then Result := Result + 'git-enriched'
  else Result := Result + 'complexity-only';
  Result := Result + ')'#10;
  for FileIndex := 0 to High(AFiles) do
  begin
    Result := Result + AFiles[FileIndex].Path + ': cyclomatic '
      + IntToStr(AFiles[FileIndex].Cyclomatic) + ', cognitive '
      + IntToStr(AFiles[FileIndex].Cognitive);
    if AGitEnriched then
      Result := Result + ', changed lines '
        + IntToStr(AFiles[FileIndex].ChangedLines) + ', hotspot '
        + StableFloat(AFiles[FileIndex].HotspotScore);
    Result := Result + #10;
    for MetricIndex := 0 to High(AFiles[FileIndex].Metrics) do
      Result := Result + '  '
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Line) + ':'
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Column) + ' '
        + AFiles[FileIndex].Metrics[MetricIndex].Name + ': cyclomatic '
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Cyclomatic)
        + ', cognitive '
        + IntToStr(AFiles[FileIndex].Metrics[MetricIndex].Cognitive) + #10;
  end;
  if Length(AViolations) > 0 then
  begin
    Result := Result + 'Threshold violations:'#10;
    for ViolationIndex := 0 to High(AViolations) do
    begin
      Result := Result + '  ' + AViolations[ViolationIndex].Path;
      if AViolations[ViolationIndex].RegionName <> '' then
        Result := Result + ':' + AViolations[ViolationIndex].RegionName;
      Result := Result + ' ' + AViolations[ViolationIndex].LimitName
        + ' observed ' + StableFloat(AViolations[ViolationIndex].Observed)
        + ' > ' + StableFloat(AViolations[ViolationIndex].Limit) + #10;
    end;
  end;
end;

procedure AddHealthConfiguration(var AMetadata: TLWPTAnalysisMetadata;
  const AProjectName: string; const ALimits: TLWPTHealthLimits);
begin
  if ALimits.MaxRoutineCyclomatic >= 0 then
    AddAnalysisConfigurationValue(AMetadata, AProjectName,
      'health.max-routine-cyclomatic',
      IntToStr(ALimits.MaxRoutineCyclomatic));
  if ALimits.MaxRoutineCognitive >= 0 then
    AddAnalysisConfigurationValue(AMetadata, AProjectName,
      'health.max-routine-cognitive', IntToStr(ALimits.MaxRoutineCognitive));
  if ALimits.MaxFileCyclomatic >= 0 then
    AddAnalysisConfigurationValue(AMetadata, AProjectName,
      'health.max-file-cyclomatic', IntToStr(ALimits.MaxFileCyclomatic));
  if ALimits.MaxFileCognitive >= 0 then
    AddAnalysisConfigurationValue(AMetadata, AProjectName,
      'health.max-file-cognitive', IntToStr(ALimits.MaxFileCognitive));
  if ALimits.MaxHotspotScore >= 0 then
    AddAnalysisConfigurationValue(AMetadata, AProjectName,
      'health.max-hotspot-score', IntToStr(ALimits.MaxHotspotScore));
end;

function BuildHealthReport(const AManifestPath: string;
  const AIncludeHotspots: Boolean; out AHuman, AJSON: string;
  out AFiles: TLWPTHealthFileArray;
  out AViolations: TLWPTHealthViolationArray): Boolean;
var
  Configurations: TLWPTHealthProjectConfigurationArray;
  Diagnostic: string;
  Document: TLWPTPascalDocument;
  EffectiveHotspots, GitEnriched, HasThresholds: Boolean;
  FileIndex, ProjectIndex: Integer;
  Limits: TLWPTHealthLimits;
  Metadata: TLWPTAnalysisMetadata;
  Scope: TLWPTAnalysisScope;
begin
  Scope := ResolveAnalysisScope(AManifestPath);
  Configurations := ResolveProjectConfigurations(Scope);
  SetLength(AFiles, Length(Scope.Files));
  SetLength(AViolations, 0);
  for FileIndex := 0 to High(Scope.Files) do
  begin
    Document := AnalyzePascal(ReadTextFile(Scope.Files[FileIndex].AbsolutePath),
      Scope.Files[FileIndex].RootRelativePath);
    AFiles[FileIndex] := AnalyzeHealthDocument(Document,
      Scope.Files[FileIndex].ProjectName,
      Scope.Files[FileIndex].RootRelativePath);
  end;
  EffectiveHotspots := AIncludeHotspots or AnyHotspotLimit(Configurations);
  GitEnriched := False;
  Diagnostic := '';
  if EffectiveHotspots then
    GitEnriched := EnrichGitHotspots(Scope.Root, Scope.Files, AFiles,
      Diagnostic);
  if EffectiveHotspots and not GitEnriched and AnyHotspotLimit(Configurations)
    then
    raise ELWPTError.Create(
      'hotspot threshold is configured but Git enrichment is unavailable');

  HasThresholds := False;
  for ProjectIndex := 0 to High(Configurations) do
    if LimitsConfigured(Configurations[ProjectIndex].Limits) then
      HasThresholds := True;
  for FileIndex := 0 to High(AFiles) do
  begin
    Limits := FindProjectLimits(Configurations, AFiles[FileIndex].ProjectName);
    CollectHealthViolations(AFiles[FileIndex], Limits, AViolations);
  end;

  Metadata := AnalysisMetadataFromScope('health',
    HEALTH_COMMAND_SCHEMA_VERSION, Scope);
  for ProjectIndex := 0 to High(Configurations) do
    AddHealthConfiguration(Metadata, Configurations[ProjectIndex].Name,
      Configurations[ProjectIndex].Limits);
  AddAnalysisConfigurationValue(Metadata, Scope.ProjectName,
    'health.hotspots', BoolToStr(EffectiveHotspots, True));
  AddAnalysisConfigurationValue(Metadata, Scope.ProjectName,
    'health.git-history-commits', IntToStr(HEALTH_GIT_HISTORY_COMMITS));
  if Diagnostic <> '' then AddAnalysisDiagnostic(Metadata, Diagnostic);
  if not HasThresholds then Metadata.ThresholdOutcome := atoNotConfigured
  else if Length(AViolations) = 0 then Metadata.ThresholdOutcome := atoPassed
  else Metadata.ThresholdOutcome := atoFailed;

  AHuman := BuildHumanReport(AFiles, AViolations, GitEnriched);
  if Diagnostic <> '' then AHuman := AHuman + 'Diagnostic: ' + Diagnostic + #10;
  AJSON := SerializeAnalysisEnvelope(Metadata,
    SerializeHealthPayload(AFiles, AViolations, GitEnriched));
  Result := Length(AViolations) = 0;
end;

function CmdHealth(const AManifestPath: string; const AJSON,
  AIncludeHotspots: Boolean): Integer;
var
  Files: TLWPTHealthFileArray;
  HumanReport, JSONReport: string;
  Violations: TLWPTHealthViolationArray;
begin
  if BuildHealthReport(AManifestPath, AIncludeHotspots, HumanReport,
    JSONReport, Files, Violations) then Result := 0
  else Result := 1;
  if AJSON then Write(JSONReport)
  else Write(HumanReport);
end;

end.
