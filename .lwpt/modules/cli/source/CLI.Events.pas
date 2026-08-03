{ CLI.Events — output-neutral, sequenced event delivery.

  The CLI package assigns stable sequence numbers and synchronously delivers
  opaque typed payloads. It does not know what payloads mean or how a host
  renders, retains, or serializes them. }
unit CLI.Events;

{$I Shared.inc}

interface

uses
  SysUtils;

type
  { Host-owned payloads provide only a stable discriminator to the generic
    delivery layer. The dispatcher owns every payload passed to Publish and
    frees it after synchronous delivery, including when delivery fails. }
  TCLIEventPayload = class abstract
  public
    function EventName: string; virtual; abstract;
  end;

  { Payload is borrowed for the duration of ICLIEventSink.Deliver. A sink that
    needs longer retention must copy or serialize it before returning. Deliver
    runs while the dispatcher holds its ordering lock, so sink implementations
    must return within a bounded interval and must not perform unbounded I/O. }
  TCLIEventEnvelope = record
    Sequence: QWord;
    Payload: TCLIEventPayload;
  end;

  ICLIEventSink = interface
    ['{ED52F94F-8A49-402F-879E-59993E605213}']
    procedure Deliver(const AEvent: TCLIEventEnvelope);
  end;

  { Sequence assignment and sink calls share one critical section so multiple
    producers observe the same delivery order as the envelope sequence. Sink
    exceptions are reported as False and never escape into command dispatch. }
  TCLIEventDispatcher = class
  private
    FSink: ICLIEventSink;
    FNextSequence: QWord;
    FCriticalSection: TRTLCriticalSection;
  public
    constructor Create(const ASink: ICLIEventSink);
    destructor Destroy; override;
    function Publish(APayload: TCLIEventPayload): Boolean;
  end;

implementation

constructor TCLIEventDispatcher.Create(const ASink: ICLIEventSink);
begin
  inherited Create;
  FSink := ASink;
  FNextSequence := 0;
  InitCriticalSection(FCriticalSection);
end;

destructor TCLIEventDispatcher.Destroy;
begin
  { The owner must stop and join every publisher before destruction begins;
    this class does not coordinate shutdown with concurrent Publish calls. }
  DoneCriticalSection(FCriticalSection);
  FSink := nil;
  inherited Destroy;
end;

function TCLIEventDispatcher.Publish(APayload: TCLIEventPayload): Boolean;
var
  Event: TCLIEventEnvelope;
begin
  if not Assigned(APayload) then
    raise EArgumentNilException.Create('event payload cannot be nil');

  EnterCriticalSection(FCriticalSection);
  try
    Inc(FNextSequence);
    Event.Sequence := FNextSequence;
    Event.Payload := APayload;
    Result := False;
    if Assigned(FSink) then
      try
        FSink.Deliver(Event);
        Result := True;
      except
        { Event delivery is an observer boundary. A renderer or retention
          failure must not replace the command result. }
      end;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
  { The dispatcher owns the payload and releases it outside the ordering
    lock, so a raising destructor cannot strand the lock. }
  APayload.Free;
end;

end.
