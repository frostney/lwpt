{ LWPT.Observability — typed payload boundary for LWPT event delivery.

  This unit names LWPT's observable facts without deciding how they are
  rendered or retained. CLI.Events owns only sequencing and delivery; the
  executable host and later reporters own output policy. }
unit LWPT.Observability;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  CLI.Events;

const
  ObservabilityJobEventName = 'job';
  ObservabilityHeartbeatEventName = 'heartbeat';
  ObservabilityDiagnosticEventName = 'diagnostic';
  ObservabilityChildOutputEventName = 'child-output';
  ObservabilityCommandTerminalEventName = 'command-terminal';
  ObservabilityTruncationEventName = 'truncation';
  ObservabilityCaptureDegradedEventName = 'capture-degraded';
  { Internal scheduler/observer failures have no child-process status to
    preserve. Use the command's generic nonzero failure outcome instead. }
  ObservabilityInternalErrorExitCode = 1;

type
  TLWPTEventRetention = (oerOrdinary, oerProtected, oerTerminal);
  TLWPTJobState = (ojsStarted, ojsPassed, ojsFailed, ojsSkipped);
  TLWPTDiagnosticSeverity = (odsInformation, odsWarning, odsError);
  TLWPTChildOutputStream = (ocosStdout, ocosStderr);

  TLWPTObservabilityPayload = class abstract(TCLIEventPayload)
  private
    FCorrelationID: string;
    FRetention: TLWPTEventRetention;
    FSource: string;
  public
    constructor Create(const ASource, ACorrelationID: string;
      const ARetention: TLWPTEventRetention);
    property CorrelationID: string read FCorrelationID;
    property Retention: TLWPTEventRetention read FRetention;
    property Source: string read FSource;
  end;

  TLWPTJobEvent = class(TLWPTObservabilityPayload)
  private
    FDetail: string;
    FElapsedMilliseconds: QWord;
    FExitCode: Integer;
    FLogReference: string;
    FState: TLWPTJobState;
  public
    constructor Create(const ASource, ACorrelationID: string;
      const AState: TLWPTJobState; const AElapsedMilliseconds: QWord;
      const AExitCode: Integer; const ADetail, ALogReference: string);
    function EventName: string; override;
    property Detail: string read FDetail;
    property ElapsedMilliseconds: QWord read FElapsedMilliseconds;
    property ExitCode: Integer read FExitCode;
    property LogReference: string read FLogReference;
    property State: TLWPTJobState read FState;
  end;

  TLWPTHeartbeatEvent = class(TLWPTObservabilityPayload)
  private
    FElapsedMilliseconds: QWord;
  public
    constructor Create(const ASource, ACorrelationID: string;
      const AElapsedMilliseconds: QWord);
    function EventName: string; override;
    property ElapsedMilliseconds: QWord read FElapsedMilliseconds;
  end;

  TLWPTDiagnosticEvent = class(TLWPTObservabilityPayload)
  private
    FMessage: string;
    FSeverity: TLWPTDiagnosticSeverity;
  public
    constructor Create(const ASource, ACorrelationID: string;
      const ASeverity: TLWPTDiagnosticSeverity; const AMessage: string);
    function EventName: string; override;
    property MessageText: string read FMessage;
    property Severity: TLWPTDiagnosticSeverity read FSeverity;
  end;

  TLWPTChildOutputEvent = class(TLWPTObservabilityPayload)
  private
    FData: RawByteString;
    FStream: TLWPTChildOutputStream;
  public
    constructor Create(const ASource, ACorrelationID: string;
      const AStream: TLWPTChildOutputStream; const AData: RawByteString);
    function EventName: string; override;
    property Data: RawByteString read FData;
    property Stream: TLWPTChildOutputStream read FStream;
  end;

  TLWPTCommandTerminalEvent = class(TLWPTObservabilityPayload)
  private
    FElapsedMilliseconds: QWord;
    FExitCode: Integer;
  public
    constructor Create(const ACommandName, ACorrelationID: string;
      const AExitCode: Integer; const AElapsedMilliseconds: QWord);
    function EventName: string; override;
    property ElapsedMilliseconds: QWord read FElapsedMilliseconds;
    property ExitCode: Integer read FExitCode;
  end;

  TLWPTTruncationEvent = class(TLWPTObservabilityPayload)
  private
    FDroppedBytes: QWord;
    FDroppedEvents: QWord;
  public
    constructor Create(const ASource, ACorrelationID: string;
      const ADroppedEvents, ADroppedBytes: QWord);
    function EventName: string; override;
    property DroppedBytes: QWord read FDroppedBytes;
    property DroppedEvents: QWord read FDroppedEvents;
  end;

  TLWPTCaptureDegradedEvent = class(TLWPTObservabilityPayload)
  private
    FReason: string;
  public
    constructor Create(const ASource, ACorrelationID, AReason: string);
    function EventName: string; override;
    property Reason: string read FReason;
  end;

implementation

constructor TLWPTObservabilityPayload.Create(
  const ASource, ACorrelationID: string;
  const ARetention: TLWPTEventRetention);
begin
  inherited Create;
  FSource := ASource;
  FCorrelationID := ACorrelationID;
  FRetention := ARetention;
end;

constructor TLWPTJobEvent.Create(const ASource, ACorrelationID: string;
  const AState: TLWPTJobState; const AElapsedMilliseconds: QWord;
  const AExitCode: Integer; const ADetail, ALogReference: string);
var
  Retention: TLWPTEventRetention;
begin
  if (AState = ojsFailed) and (AExitCode = 0) then
    raise EArgumentException.Create(
      'failed job event requires a nonzero exit outcome');
  if AState = ojsStarted then
    Retention := oerOrdinary
  else
    Retention := oerTerminal;
  inherited Create(ASource, ACorrelationID, Retention);
  FState := AState;
  FElapsedMilliseconds := AElapsedMilliseconds;
  FExitCode := AExitCode;
  FDetail := ADetail;
  FLogReference := ALogReference;
end;

function TLWPTJobEvent.EventName: string;
begin
  Result := ObservabilityJobEventName;
end;

constructor TLWPTHeartbeatEvent.Create(const ASource, ACorrelationID: string;
  const AElapsedMilliseconds: QWord);
begin
  inherited Create(ASource, ACorrelationID, oerOrdinary);
  FElapsedMilliseconds := AElapsedMilliseconds;
end;

function TLWPTHeartbeatEvent.EventName: string;
begin
  Result := ObservabilityHeartbeatEventName;
end;

constructor TLWPTDiagnosticEvent.Create(const ASource, ACorrelationID: string;
  const ASeverity: TLWPTDiagnosticSeverity; const AMessage: string);
begin
  inherited Create(ASource, ACorrelationID, oerProtected);
  FSeverity := ASeverity;
  FMessage := AMessage;
end;

function TLWPTDiagnosticEvent.EventName: string;
begin
  Result := ObservabilityDiagnosticEventName;
end;

constructor TLWPTChildOutputEvent.Create(
  const ASource, ACorrelationID: string;
  const AStream: TLWPTChildOutputStream; const AData: RawByteString);
begin
  inherited Create(ASource, ACorrelationID, oerOrdinary);
  FStream := AStream;
  FData := AData;
end;

function TLWPTChildOutputEvent.EventName: string;
begin
  Result := ObservabilityChildOutputEventName;
end;

constructor TLWPTCommandTerminalEvent.Create(
  const ACommandName, ACorrelationID: string; const AExitCode: Integer;
  const AElapsedMilliseconds: QWord);
begin
  inherited Create(ACommandName, ACorrelationID, oerTerminal);
  FExitCode := AExitCode;
  FElapsedMilliseconds := AElapsedMilliseconds;
end;

function TLWPTCommandTerminalEvent.EventName: string;
begin
  Result := ObservabilityCommandTerminalEventName;
end;

constructor TLWPTTruncationEvent.Create(const ASource, ACorrelationID: string;
  const ADroppedEvents, ADroppedBytes: QWord);
begin
  inherited Create(ASource, ACorrelationID, oerProtected);
  FDroppedEvents := ADroppedEvents;
  FDroppedBytes := ADroppedBytes;
end;

function TLWPTTruncationEvent.EventName: string;
begin
  Result := ObservabilityTruncationEventName;
end;

constructor TLWPTCaptureDegradedEvent.Create(
  const ASource, ACorrelationID, AReason: string);
begin
  inherited Create(ASource, ACorrelationID, oerProtected);
  FReason := AReason;
end;

function TLWPTCaptureDegradedEvent.EventName: string;
begin
  Result := ObservabilityCaptureDegradedEventName;
end;

end.
