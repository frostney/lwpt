program LWPT.Observability.Test;

{$I Shared.inc}

uses
  SysUtils,

  CLI.Events,
  LWPT.Core,
  LWPT.Observability,
  TestingPascalLibrary;

type
  TLWPTObservabilitySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestJobLifecycleRetentionIsTyped;
    procedure TestFailedJobRequiresNonZeroExitOutcome;
    procedure TestHeartbeatAndDiagnosticRetentionIsTyped;
    procedure TestChildOutputPreservesRawBytesAndTags;
    procedure TestCommandTerminalCarriesOutcome;
    procedure TestJournalStateEventsRemainProtected;
  end;

procedure TLWPTObservabilitySuite.TestJobLifecycleRetentionIsTyped;
var
  Started, Failed: TLWPTJobEvent;
begin
  Started := TLWPTJobEvent.Create('compile:app', 'invocation-1', ojsStarted,
    0, 0, '', 'session/logs/app.log');
  Failed := TLWPTJobEvent.Create('compile:app', 'invocation-1', ojsFailed,
    42, 7, 'compiler failed', 'session/logs/app.log');
  try
    Expect<string>(Started.EventName).ToBe(ObservabilityJobEventName);
    Expect<TLWPTJobState>(Started.State).ToBe(ojsStarted);
    Expect<TLWPTEventRetention>(Started.Retention).ToBe(oerOrdinary);
    Expect<TLWPTEventRetention>(Failed.Retention).ToBe(oerTerminal);
    Expect<Integer>(Failed.ExitCode).ToBe(7);
    Expect<string>(Failed.Detail).ToBe('compiler failed');
  finally
    Started.Free;
    Failed.Free;
  end;
end;

procedure TLWPTObservabilitySuite.TestFailedJobRequiresNonZeroExitOutcome;
var
  Event: TLWPTJobEvent;
  RejectedZero: Boolean;
begin
  RejectedZero := False;
  Event := nil;
  try
    try
      Event := TLWPTJobEvent.Create('test:scheduler', 'invocation-1',
        ojsFailed, 1, 0, 'scheduler error', 'session/logs/test.log');
    except
      on EArgumentException do RejectedZero := True;
    end;
    Expect<Boolean>(RejectedZero).ToBe(True);
    Expect<Boolean>(ObservabilityInternalErrorExitCode <> 0).ToBe(True);
    Expect<Integer>(NormalizeFailureExitCode(0)).ToBe(
      ObservabilityInternalErrorExitCode);
    Expect<Integer>(NormalizeFailureExitCode(17)).ToBe(17);
  finally
    Event.Free;
  end;
end;

procedure TLWPTObservabilitySuite.
  TestHeartbeatAndDiagnosticRetentionIsTyped;
var
  Heartbeat: TLWPTHeartbeatEvent;
  Diagnostic: TLWPTDiagnosticEvent;
begin
  Heartbeat := TLWPTHeartbeatEvent.Create('build', 'invocation-2', 30000);
  Diagnostic := TLWPTDiagnosticEvent.Create('build', 'invocation-2',
    odsError, 'publication failed');
  try
    Expect<string>(Heartbeat.EventName).ToBe(ObservabilityHeartbeatEventName);
    Expect<TLWPTEventRetention>(Heartbeat.Retention).ToBe(oerOrdinary);
    Expect<QWord>(Heartbeat.ElapsedMilliseconds).ToBe(30000);
    Expect<string>(Diagnostic.EventName).ToBe(
      ObservabilityDiagnosticEventName);
    Expect<TLWPTEventRetention>(Diagnostic.Retention).ToBe(oerProtected);
    Expect<TLWPTDiagnosticSeverity>(Diagnostic.Severity).ToBe(odsError);
  finally
    Heartbeat.Free;
    Diagnostic.Free;
  end;
end;

procedure TLWPTObservabilitySuite.TestChildOutputPreservesRawBytesAndTags;
var
  Event: TLWPTChildOutputEvent;
  Bytes: RawByteString;
begin
  Bytes := 'before' + #0 + 'after';
  Event := TLWPTChildOutputEvent.Create('compiler:app', 'invocation-3',
    ocosStderr, Bytes);
  try
    Expect<string>(Event.EventName).ToBe(ObservabilityChildOutputEventName);
    Expect<string>(Event.Source).ToBe('compiler:app');
    Expect<string>(Event.CorrelationID).ToBe('invocation-3');
    Expect<TLWPTChildOutputStream>(Event.Stream).ToBe(ocosStderr);
    Expect<Integer>(Length(Event.Data)).ToBe(Length(Bytes));
    Expect<Integer>(Ord(Event.Data[7])).ToBe(0);
  finally
    Event.Free;
  end;
end;

procedure TLWPTObservabilitySuite.TestCommandTerminalCarriesOutcome;
var
  Event: TLWPTCommandTerminalEvent;
begin
  Event := TLWPTCommandTerminalEvent.Create('build', 'invocation-4', 1, 25);
  try
    Expect<string>(Event.EventName).ToBe(
      ObservabilityCommandTerminalEventName);
    Expect<string>(Event.Source).ToBe('build');
    Expect<TLWPTEventRetention>(Event.Retention).ToBe(oerTerminal);
    Expect<Integer>(Event.ExitCode).ToBe(1);
    Expect<QWord>(Event.ElapsedMilliseconds).ToBe(25);
  finally
    Event.Free;
  end;
end;

procedure TLWPTObservabilitySuite.TestJournalStateEventsRemainProtected;
var
  Truncation: TLWPTTruncationEvent;
  Degraded: TLWPTCaptureDegradedEvent;
begin
  Truncation := TLWPTTruncationEvent.Create('journal', 'invocation-5',
    3, 4096);
  Degraded := TLWPTCaptureDegradedEvent.Create('journal', 'invocation-5',
    'temporary journal write failed');
  try
    Expect<TLWPTEventRetention>(Truncation.Retention).ToBe(oerProtected);
    Expect<QWord>(Truncation.DroppedEvents).ToBe(3);
    Expect<QWord>(Truncation.DroppedBytes).ToBe(4096);
    Expect<TLWPTEventRetention>(Degraded.Retention).ToBe(oerProtected);
    Expect<string>(Degraded.Reason).ToBe('temporary journal write failed');
  finally
    Truncation.Free;
    Degraded.Free;
  end;
end;

procedure TLWPTObservabilitySuite.SetupTests;
begin
  Test('job lifecycle events distinguish ordinary starts from terminals',
    TestJobLifecycleRetentionIsTyped);
  Test('failed job events require a nonzero exit outcome',
    TestFailedJobRequiresNonZeroExitOutcome);
  Test('heartbeats are ordinary while diagnostics are protected',
    TestHeartbeatAndDiagnosticRetentionIsTyped);
  Test('child output preserves raw bytes plus source and correlation tags',
    TestChildOutputPreservesRawBytesAndTags);
  Test('command terminal events carry the final outcome',
    TestCommandTerminalCarriesOutcome);
  Test('truncation and capture degradation events remain protected',
    TestJournalStateEventsRemainProtected);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTObservabilitySuite.Create(
    PROJECT_NAME + '.Observability: typed payload boundary'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
