program CLI.Events.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Events,
  TestingPascalLibrary;

type
  TTestPayload = class(TCLIEventPayload)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    function EventName: string; override;
  end;

  TRecordingSink = class(TInterfacedObject, ICLIEventSink)
  public
    Sequences: array of QWord;
    Names: array of string;
    FailName: string;
    procedure Deliver(const AEvent: TCLIEventEnvelope);
  end;

  TPublishThread = class(TThread)
  private
    FDispatcher: TCLIEventDispatcher;
    FNamePrefix: string;
    FPublishFailed: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADispatcher: TCLIEventDispatcher;
      const ANamePrefix: string);
    property PublishFailed: Boolean read FPublishFailed;
  end;

  TCLIEventSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDispatchAssignsStableSequenceAndType;
    procedure TestConcurrentProducersDeliverInSequence;
    procedure TestSinkFailureDoesNotEscapeOrStopSequence;
    procedure TestMissingSinkStillReleasesPayload;
    procedure TestNilPayloadIsRejected;
  end;

var
  DestroyedPayloads: Integer = 0;

constructor TTestPayload.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

destructor TTestPayload.Destroy;
begin
  InterlockedIncrement(DestroyedPayloads);
  inherited Destroy;
end;

function TTestPayload.EventName: string;
begin
  Result := FName;
end;

procedure TRecordingSink.Deliver(const AEvent: TCLIEventEnvelope);
var
  Index: Integer;
begin
  Index := Length(Sequences);
  SetLength(Sequences, Index + 1);
  SetLength(Names, Index + 1);
  Sequences[Index] := AEvent.Sequence;
  Names[Index] := AEvent.Payload.EventName;
  if AEvent.Payload.EventName = FailName then
    raise Exception.Create('fixture delivery failure');
end;

constructor TPublishThread.Create(const ADispatcher: TCLIEventDispatcher;
  const ANamePrefix: string);
begin
  inherited Create(True);
  FDispatcher := ADispatcher;
  FNamePrefix := ANamePrefix;
  FPublishFailed := False;
end;

procedure TPublishThread.Execute;
var
  Index: Integer;
begin
  for Index := 1 to 25 do
    if not FDispatcher.Publish(TTestPayload.Create(
      FNamePrefix + IntToStr(Index))) then
      FPublishFailed := True;
end;

procedure TCLIEventSuite.TestDispatchAssignsStableSequenceAndType;
var
  Dispatcher: TCLIEventDispatcher;
  Sink: ICLIEventSink;
  RecordingSink: TRecordingSink;
begin
  DestroyedPayloads := 0;
  RecordingSink := TRecordingSink.Create;
  Sink := RecordingSink;
  Dispatcher := TCLIEventDispatcher.Create(Sink);
  try
    Expect<Boolean>(Dispatcher.Publish(TTestPayload.Create('first'))).
      ToBe(True);
    Expect<Boolean>(Dispatcher.Publish(TTestPayload.Create('second'))).
      ToBe(True);
    Expect<Integer>(Length(RecordingSink.Sequences)).ToBe(2);
    Expect<QWord>(RecordingSink.Sequences[0]).ToBe(1);
    Expect<QWord>(RecordingSink.Sequences[1]).ToBe(2);
    Expect<string>(RecordingSink.Names[0]).ToBe('first');
    Expect<string>(RecordingSink.Names[1]).ToBe('second');
    Expect<Integer>(DestroyedPayloads).ToBe(2);
  finally
    Dispatcher.Free;
    Sink := nil;
  end;
end;

procedure TCLIEventSuite.TestConcurrentProducersDeliverInSequence;
var
  Dispatcher: TCLIEventDispatcher;
  Index, SequenceIndex: Integer;
  Sink: ICLIEventSink;
  RecordingSink: TRecordingSink;
  Threads: array[0..3] of TPublishThread;
begin
  DestroyedPayloads := 0;
  for Index := 0 to High(Threads) do
    Threads[Index] := nil;
  RecordingSink := TRecordingSink.Create;
  Sink := RecordingSink;
  Dispatcher := TCLIEventDispatcher.Create(Sink);
  try
    for Index := 0 to High(Threads) do
      Threads[Index] := TPublishThread.Create(Dispatcher,
        'producer-' + IntToStr(Index) + '-');
    for Index := 0 to High(Threads) do
      Threads[Index].Start;
    for Index := 0 to High(Threads) do
      Threads[Index].WaitFor;

    Expect<Integer>(Length(RecordingSink.Sequences)).ToBe(100);
    for SequenceIndex := 0 to High(RecordingSink.Sequences) do
      Expect<QWord>(RecordingSink.Sequences[SequenceIndex]).ToBe(
        QWord(SequenceIndex + 1));
    for Index := 0 to High(Threads) do
      Expect<Boolean>(Threads[Index].PublishFailed).ToBe(False);
    Expect<Integer>(DestroyedPayloads).ToBe(100);
  finally
    for Index := 0 to High(Threads) do
      Threads[Index].Free;
    Dispatcher.Free;
    Sink := nil;
  end;
end;

procedure TCLIEventSuite.TestSinkFailureDoesNotEscapeOrStopSequence;
var
  Dispatcher: TCLIEventDispatcher;
  Sink: ICLIEventSink;
  RecordingSink: TRecordingSink;
begin
  DestroyedPayloads := 0;
  RecordingSink := TRecordingSink.Create;
  RecordingSink.FailName := 'fail';
  Sink := RecordingSink;
  Dispatcher := TCLIEventDispatcher.Create(Sink);
  try
    Expect<Boolean>(Dispatcher.Publish(TTestPayload.Create('fail'))).
      ToBe(False);
    Expect<Boolean>(Dispatcher.Publish(TTestPayload.Create('recover'))).
      ToBe(True);
    Expect<Integer>(Length(RecordingSink.Sequences)).ToBe(2);
    Expect<QWord>(RecordingSink.Sequences[0]).ToBe(1);
    Expect<QWord>(RecordingSink.Sequences[1]).ToBe(2);
    Expect<Integer>(DestroyedPayloads).ToBe(2);
  finally
    Dispatcher.Free;
    Sink := nil;
  end;
end;

procedure TCLIEventSuite.TestMissingSinkStillReleasesPayload;
var
  Dispatcher: TCLIEventDispatcher;
begin
  DestroyedPayloads := 0;
  Dispatcher := TCLIEventDispatcher.Create(nil);
  try
    Expect<Boolean>(Dispatcher.Publish(TTestPayload.Create('unobserved'))).
      ToBe(False);
    Expect<Integer>(DestroyedPayloads).ToBe(1);
  finally
    Dispatcher.Free;
  end;
end;

procedure TCLIEventSuite.TestNilPayloadIsRejected;
var
  Dispatcher: TCLIEventDispatcher;
  Raised: Boolean;
begin
  Raised := False;
  Dispatcher := TCLIEventDispatcher.Create(nil);
  try
    try
      Dispatcher.Publish(nil);
    except
      on EArgumentNilException do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Boolean>(Dispatcher.Publish(TTestPayload.Create('after'))).
      ToBe(False);
  finally
    Dispatcher.Free;
  end;
end;

procedure TCLIEventSuite.SetupTests;
begin
  Test('dispatch assigns stable sequence numbers and preserves payload type',
    TestDispatchAssignsStableSequenceAndType);
  Test('concurrent producers deliver in stable envelope sequence',
    TestConcurrentProducersDeliverInSequence);
  Test('sink failure does not escape or stop the sequence',
    TestSinkFailureDoesNotEscapeOrStopSequence);
  Test('missing sink still releases dispatcher-owned payloads',
    TestMissingSinkStillReleasesPayload);
  Test('nil payloads are rejected without stranding the dispatcher',
    TestNilPayloadIsRejected);
end;

begin
  TestRunnerProgram.AddSuite(TCLIEventSuite.Create(
    'CLI.Events: sequenced output-neutral delivery'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
