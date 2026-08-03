{ LWPT.ProgressReporter — shared host-side progress and log policy.

  Build and test feed typed observability events into this reporter. It owns
  their established human rendering, heartbeat cadence, active-job assembly,
  and per-job log persistence; LWPT.Observability remains output-neutral. }
unit LWPT.ProgressReporter;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Core,
  LWPT.Observability,
  LWPT.OutputRenderer;

const
  ObservabilityHeartbeatIntervalEnvironment = PROJECT_NAME
    + '_HEARTBEAT_INTERVAL_MS';
  ObservabilityBuildIdentityNamespace = 'build:';
  ObservabilityTestIdentityNamespace = 'test:';

type
  TLWPTProgressStyle = (lpsBuild, lpsTest);

  TLWPTProgressReporter = class
  private
    FHeartbeatInterval: QWord;
    FHeartbeatStartedAt: QWord;
    FJobs: TList;
    FLastHeartbeatAt: QWord;
    FSession: TLWPTBuildSession;
    FStyle: TLWPTProgressStyle;
    function FindJob(const AIdentity: string): TObject;
    function JobDisplayName(const AIdentity: string): string;
    procedure WriteCapturedOutput(const AOutput: string);
  public
    constructor Create(const ASession: TLWPTBuildSession;
      const AStyle: TLWPTProgressStyle);
    destructor Destroy; override;
    procedure RegisterJob(const AIdentity, ADisplayName: string);
    procedure MarkJobInactive(const AIdentity: string);
    procedure StartHeartbeatClock(const AInvocationStartedAt,
      ALastHeartbeatAt: QWord);
    function HeartbeatDue(const ANow: QWord): Boolean;
    function ActiveJobSummary(const ANow: QWord): string;
    procedure ReportHeartbeat(const AEvent: TLWPTHeartbeatEvent);
    procedure ReportWaitHeartbeat(const AEvent: TLWPTHeartbeatEvent;
      const AMessage: string; const AObservedAt: QWord);
    procedure ReportJob(const AEvent: TLWPTJobEvent;
      const AOutput, AErrorMessage: string; const AVerbose: Boolean;
      const AStartedAt: QWord = 0);
    property HeartbeatIntervalMilliseconds: QWord read FHeartbeatInterval;
  end;

function ObservabilityHeartbeatIntervalMilliseconds: QWord;
function FormatElapsedMilliseconds(const AElapsed: QWord): string;

implementation

const
  DefaultObservabilityHeartbeatIntervalMilliseconds = 30000;
  ObservabilityStartEvent = 'START ';
  ObservabilityHeartbeatEvent = 'HEARTBEAT ';
  ObservabilityPassEvent = 'PASS ';
  ObservabilityFailEvent = 'FAIL ';
  ObservabilitySkipEvent = 'SKIP ';

type
  TLWPTProgressJob = class
  public
    Active: Boolean;
    DisplayName: string;
    Identity: string;
    StartedAt: QWord;
    Terminal: Boolean;
  end;

function ObservabilityHeartbeatIntervalMilliseconds: QWord;
var
  Raw: string;
  Parsed: Int64;
begin
  Raw := SysUtils.GetEnvironmentVariable(
    ObservabilityHeartbeatIntervalEnvironment);
  if (Raw <> '') and TryStrToInt64(Raw, Parsed) and (Parsed > 0) then
  begin
    Result := QWord(Parsed);
    { The override may only shorten the cadence; longer values retain the
      bounded default heartbeat interval. }
    if Result > DefaultObservabilityHeartbeatIntervalMilliseconds then
      Result := DefaultObservabilityHeartbeatIntervalMilliseconds;
    Exit;
  end;
  Result := DefaultObservabilityHeartbeatIntervalMilliseconds;
end;

function FormatElapsedMilliseconds(const AElapsed: QWord): string;
begin
  Result := UIntToStr(AElapsed) + ' ms';
end;

constructor TLWPTProgressReporter.Create(const ASession: TLWPTBuildSession;
  const AStyle: TLWPTProgressStyle);
begin
  inherited Create;
  FSession := ASession;
  FStyle := AStyle;
  FHeartbeatInterval := ObservabilityHeartbeatIntervalMilliseconds;
  FJobs := TList.Create;
end;

destructor TLWPTProgressReporter.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FJobs.Count - 1 do TObject(FJobs[Index]).Free;
  FJobs.Free;
  inherited Destroy;
end;

function TLWPTProgressReporter.FindJob(const AIdentity: string): TObject;
var
  Index: Integer;
begin
  for Index := 0 to FJobs.Count - 1 do
    if TLWPTProgressJob(FJobs[Index]).Identity = AIdentity then
      Exit(TObject(FJobs[Index]));
  Result := nil;
end;

function TLWPTProgressReporter.JobDisplayName(
  const AIdentity: string): string;
var
  Job: TLWPTProgressJob;
begin
  Job := TLWPTProgressJob(FindJob(AIdentity));
  if Assigned(Job) then Result := Job.DisplayName
  else Result := AIdentity;
end;

procedure TLWPTProgressReporter.RegisterJob(
  const AIdentity, ADisplayName: string);
var
  Job: TLWPTProgressJob;
begin
  Job := TLWPTProgressJob(FindJob(AIdentity));
  if Assigned(Job) then
  begin
    Job.DisplayName := ADisplayName;
    Exit;
  end;
  Job := TLWPTProgressJob.Create;
  Job.Identity := AIdentity;
  Job.DisplayName := ADisplayName;
  Job.Active := True;
  FJobs.Add(Job);
end;

procedure TLWPTProgressReporter.MarkJobInactive(const AIdentity: string);
var
  Job: TLWPTProgressJob;
begin
  Job := TLWPTProgressJob(FindJob(AIdentity));
  if Assigned(Job) then Job.Active := False;
end;

procedure TLWPTProgressReporter.StartHeartbeatClock(
  const AInvocationStartedAt, ALastHeartbeatAt: QWord);
begin
  FHeartbeatStartedAt := AInvocationStartedAt;
  FLastHeartbeatAt := ALastHeartbeatAt;
end;

function TLWPTProgressReporter.HeartbeatDue(const ANow: QWord): Boolean;
begin
  Result := ANow - FLastHeartbeatAt >= FHeartbeatInterval;
end;

function TLWPTProgressReporter.ActiveJobSummary(
  const ANow: QWord): string;
var
  Index: Integer;
  Job: TLWPTProgressJob;
begin
  Result := '';
  for Index := 0 to FJobs.Count - 1 do
  begin
    Job := TLWPTProgressJob(FJobs[Index]);
    if Job.Terminal or not Job.Active then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + Job.DisplayName;
    if Job.StartedAt = 0 then Result := Result + ' (queued)'
    else Result := Result + ' (' + FormatElapsedMilliseconds(
      ANow - Job.StartedAt) + ')';
  end;
end;

procedure TLWPTProgressReporter.ReportHeartbeat(
  const AEvent: TLWPTHeartbeatEvent);
var
  ObservedAt: QWord;
begin
  ObservedAt := FHeartbeatStartedAt + AEvent.ElapsedMilliseconds;
  WriteLn(ObservabilityHeartbeatEvent, AEvent.Source, ' elapsed ',
    FormatElapsedMilliseconds(AEvent.ElapsedMilliseconds), '; active: ',
    ActiveJobSummary(ObservedAt));
  FLastHeartbeatAt := ObservedAt;
end;

procedure TLWPTProgressReporter.ReportWaitHeartbeat(
  const AEvent: TLWPTHeartbeatEvent; const AMessage: string;
  const AObservedAt: QWord);
begin
  WriteLn(ObservabilityHeartbeatEvent, AMessage, ' ',
    FormatElapsedMilliseconds(AEvent.ElapsedMilliseconds));
  FLastHeartbeatAt := AObservedAt;
end;

procedure TLWPTProgressReporter.WriteCapturedOutput(const AOutput: string);
begin
  if AOutput = '' then Exit;
  if SilentOutputActive then
  begin
    CaptureSilentChildOutput(RawByteString(AOutput), '');
    Exit;
  end;
  Write(AOutput);
  if not (AOutput[Length(AOutput)] in [#10, #13]) then WriteLn;
end;

procedure TLWPTProgressReporter.ReportJob(const AEvent: TLWPTJobEvent;
  const AOutput, AErrorMessage: string; const AVerbose: Boolean;
  const AStartedAt: QWord);
var
  DisplayName, LogOutput, Metadata, TerminalLine: string;
  Job: TLWPTProgressJob;
begin
  DisplayName := JobDisplayName(AEvent.Source);
  Job := TLWPTProgressJob(FindJob(AEvent.Source));
  if AEvent.State = ojsStarted then
  begin
    if Assigned(Job) then
    begin
      Job.StartedAt := AStartedAt;
      Job.Active := True;
    end;
    FSession.WriteJobLog(AEvent.Source, '');
    if AEvent.Detail = '' then
      WriteLn(ObservabilityStartEvent, DisplayName, ' (log: ',
        AEvent.LogReference, ')')
    else
      WriteLn(ObservabilityStartEvent, DisplayName, ' (', AEvent.Detail,
        '; log: ', AEvent.LogReference, ')');
    Exit;
  end;

  if Assigned(Job) then
  begin
    Job.Active := False;
    Job.Terminal := True;
  end;
  { A skipped state covers terminal skips whose diagnostics are persisted and
    tests skipped or cancelled before start. Producers omit LogReference only
    for the latter no-log case; state alone cannot select rendering policy. }
  if AEvent.LogReference = '' then
  begin
    WriteLn(ObservabilitySkipEvent, DisplayName, ' (', AEvent.Detail, ')');
    Exit;
  end;

  LogOutput := AOutput;
  if (LogOutput = '') and (AErrorMessage <> '') then
    LogOutput := AErrorMessage + LineEnding;
  FSession.WriteJobLog(AEvent.Source, LogOutput);
  Metadata := FormatElapsedMilliseconds(AEvent.ElapsedMilliseconds)
    + '; log: ' + AEvent.LogReference;
  case AEvent.State of
    ojsPassed:
      if (FStyle = lpsBuild) and (AEvent.Detail <> '') then
        WriteLn(ObservabilityPassEvent, DisplayName, ' -> ', AEvent.Detail,
          ' (', Metadata, ')')
      else
        WriteLn(ObservabilityPassEvent, DisplayName, ' (', Metadata, ')');
    ojsFailed:
      begin
        if AEvent.Detail <> '' then Metadata := AEvent.Detail + '; ' + Metadata;
        TerminalLine := ObservabilityFailEvent + DisplayName + ' ('
          + Metadata + ')';
        if SilentOutputActive then WriteCommandResultLine(TerminalLine)
        else WriteLn(TerminalLine);
      end;
    ojsSkipped:
      begin
        if AEvent.Detail <> '' then Metadata := AEvent.Detail + '; ' + Metadata;
        WriteLn(ObservabilitySkipEvent, DisplayName, ' (', Metadata, ')');
      end;
  end;
  if (AEvent.State = ojsFailed)
     or (AVerbose and (AEvent.State = ojsPassed)) then
    WriteCapturedOutput(LogOutput);
  if (AErrorMessage <> '') and (Pos(AErrorMessage, LogOutput) = 0) then
    WriteLn('  error: ', AErrorMessage);
  if (FStyle = lpsBuild) and (AErrorMessage <> '') then
    case AEvent.State of
      ojsFailed:
        WriteLn(ErrOutput, '  build entry "', DisplayName, '" failed: ',
          AErrorMessage);
      ojsSkipped:
        WriteLn(ErrOutput, '  build entry "', DisplayName, '" skipped: ',
          AErrorMessage);
    end;
end;

end.
