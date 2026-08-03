{ LWPT.OutputRenderer — executable-host terminal and retention policy.

  The reusable CLI package owns only option/dispatch and sequenced event
  delivery. This host unit routes terminal writes into LWPT's typed events,
  retains them in a bounded temporary journal, and decides what reaches the
  user's stdout/stderr in silent mode. }
unit LWPT.OutputRenderer;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  CLI.Events;

const
  SilentJournalMaximumBytes = QWord(64) * 1024 * 1024;
  SilentEmergencyReserveBytes = QWord(1) * 1024 * 1024;

type
  ELWPTOutputRendererError = class(Exception);

  { Fixed-capacity byte ring used after the normal event journal degrades.
    Append performs no allocation after construction. }
  TLWPTEmergencyRing = class
  private
    FAllocation: RawByteString;
    FLength: SizeInt;
    FStart: SizeInt;
  public
    constructor Create(const ACapacity: SizeInt);
    procedure Append(const AData: RawByteString);
    function Tail: RawByteString;
  end;

  TLWPTOutputRenderer = class
  private
    FCapturing: Boolean;
    FCommandName: string;
    FCorrelationID: string;
    FDispatcher: TObject;
    FErrorStream: TObject;
    FJournal: TObject;
    FJournalSink: ICLIEventSink;
    FOriginalError: TextRec;
    FOriginalOutput: TextRec;
    FOutputStream: TObject;
    procedure ClearInvocation;
    procedure PublishChild(const AStandardOutput,
      AStandardError: RawByteString);
    procedure RestoreStandardFiles;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginSilent(const ACommandName: string);
    procedure FinishSilent(const AExitCode: Integer;
      const AElapsedMilliseconds: QWord);
    property Capturing: Boolean read FCapturing;
  end;

procedure CaptureSilentChildOutput(const AStandardOutput,
  AStandardError: RawByteString);
procedure BeginSilentChildOperation;
procedure FinishSilentChildOperation(const AFailed: Boolean);
function SilentOutputActive: Boolean;
procedure SetActiveOutputRenderer(ARenderer: TLWPTOutputRenderer);
procedure WriteCommandResult(const AText: string);
procedure WriteCommandResultLine(const AText: string);

implementation

uses
  Classes,

  LWPT.Core,
  LWPT.Observability,
  StreamIO;

type
  TLWPTJournalEntry = record
    DataLength: LongInt;
    DataOffset: Int64;
    OperationID: QWord;
    Retention: TLWPTEventRetention;
    Sequence: QWord;
    Stream: TLWPTChildOutputStream;
  end;

  TLWPTSilentJournal = class(TInterfacedObject, ICLIEventSink)
  private
    FDegraded: Boolean;
    FDegradedReason: string;
    FEmergencyRing: TLWPTEmergencyRing;
    FEntries: array of TLWPTJournalEntry;
    FJournalPath: string;
    FNextOperationID: QWord;
    FStream: TFileStream;
    procedure AppendEmergency(const AData: RawByteString);
    procedure Degrade(const AReason: string);
    procedure Retain(const ASequence: QWord;
      const AStream: TLWPTChildOutputStream;
      const ARetention: TLWPTEventRetention;
      const AOperationID: QWord; const AData: RawByteString);
  public
    constructor Create;
    destructor Destroy; override;
    function BeginChildOperation: QWord;
    procedure Deliver(const AEvent: TCLIEventEnvelope);
    procedure FinishChildOperation(const AOperationID: QWord;
      const AFailed: Boolean);
    procedure ReplayFailure;
  end;

  TLWPTEventTextStream = class(TStream)
  private
    FCorrelationID: string;
    FDispatcher: TCLIEventDispatcher;
    FRetention: TLWPTEventRetention;
    FSource: string;
    FStream: TLWPTChildOutputStream;
  public
    constructor Create(const ADispatcher: TCLIEventDispatcher;
      const ASource, ACorrelationID: string;
      const AStream: TLWPTChildOutputStream;
      const ARetention: TLWPTEventRetention);
    function Read(var ABuffer; ACount: LongInt): LongInt; override;
    function Seek(const AOffset: Int64; AOrigin: TSeekOrigin): Int64; override;
    function Write(const ABuffer; ACount: LongInt): LongInt; override;
  end;

var
  ActiveRenderer: TLWPTOutputRenderer = nil;

threadvar
  ActiveSilentChildOperationID: QWord;

procedure SetActiveOutputRenderer(ARenderer: TLWPTOutputRenderer);
begin
  ActiveRenderer := ARenderer;
end;

function SilentOutputActive: Boolean;
begin
  Result := Assigned(ActiveRenderer) and ActiveRenderer.Capturing;
end;

procedure BeginSilentChildOperation;
begin
  if not SilentOutputActive then Exit;
  if ActiveSilentChildOperationID <> 0 then
    raise ELWPTOutputRendererError.Create(
      'silent child-output operation is already active');
  ActiveSilentChildOperationID :=
    TLWPTSilentJournal(ActiveRenderer.FJournal).BeginChildOperation;
end;

procedure FinishSilentChildOperation(const AFailed: Boolean);
var
  OperationID: QWord;
begin
  OperationID := ActiveSilentChildOperationID;
  if OperationID = 0 then Exit;
  try
    if SilentOutputActive then
      TLWPTSilentJournal(ActiveRenderer.FJournal).FinishChildOperation(
        OperationID, AFailed);
  finally
    ActiveSilentChildOperationID := 0;
  end;
end;

procedure WriteCommandResult(const AText: string);
begin
  if SilentOutputActive then
  begin
    Flush(Output);
    Flush(ErrOutput);
    ActiveRenderer.PublishChild(RawByteString(AText), '');
  end
  else
    Write(Output, AText);
end;

procedure WriteCommandResultLine(const AText: string);
begin
  WriteCommandResult(AText + LineEnding);
end;

constructor TLWPTEmergencyRing.Create(const ACapacity: SizeInt);
begin
  inherited Create;
  if ACapacity <= 0 then
    raise EArgumentOutOfRangeException.Create(
      'emergency ring capacity must be positive');
  SetLength(FAllocation, ACapacity);
  if Length(FAllocation) <> ACapacity then
    raise ELWPTOutputRendererError.Create(
      'cannot reserve silent-output recovery buffer');
end;

procedure TLWPTEmergencyRing.Append(const AData: RawByteString);
var
  Capacity, DropCount, FirstCount, IncomingLength, WriteAt: SizeInt;
begin
  IncomingLength := Length(AData);
  if IncomingLength = 0 then Exit;
  Capacity := Length(FAllocation);
  if IncomingLength >= Capacity then
  begin
    Move(AData[IncomingLength - Capacity + 1], FAllocation[1], Capacity);
    FStart := 0;
    FLength := Capacity;
    Exit;
  end;

  if FLength + IncomingLength > Capacity then
  begin
    DropCount := FLength + IncomingLength - Capacity;
    FStart := (FStart + DropCount) mod Capacity;
    Dec(FLength, DropCount);
  end;
  WriteAt := (FStart + FLength) mod Capacity;
  FirstCount := Capacity - WriteAt;
  if FirstCount > IncomingLength then FirstCount := IncomingLength;
  Move(AData[1], FAllocation[WriteAt + 1], FirstCount);
  if FirstCount < IncomingLength then
    Move(AData[FirstCount + 1], FAllocation[1],
      IncomingLength - FirstCount);
  Inc(FLength, IncomingLength);
end;

function TLWPTEmergencyRing.Tail: RawByteString;
var
  Capacity, FirstCount: SizeInt;
begin
  Result := '';
  if FLength = 0 then Exit;
  SetLength(Result, FLength);
  Capacity := Length(FAllocation);
  FirstCount := Capacity - FStart;
  if FirstCount > FLength then FirstCount := FLength;
  Move(FAllocation[FStart + 1], Result[1], FirstCount);
  if FirstCount < FLength then
    Move(FAllocation[1], Result[FirstCount + 1], FLength - FirstCount);
end;

procedure CaptureSilentChildOutput(const AStandardOutput,
  AStandardError: RawByteString);
begin
  if SilentOutputActive then
    ActiveRenderer.PublishChild(AStandardOutput, AStandardError);
end;

constructor TLWPTSilentJournal.Create;
begin
  inherited Create;
  try
    FEmergencyRing := TLWPTEmergencyRing.Create(
      SizeInt(SilentEmergencyReserveBytes));
  except
    on E: Exception do
      raise ELWPTOutputRendererError.Create(
        'cannot reserve silent-output recovery buffer: ' + E.Message);
  end;
  try
    FJournalPath := GetTempFileName(GetTempDir(False), PROGRAM_NAME);
    FStream := TFileStream.Create(FJournalPath, fmCreate or fmShareDenyWrite);
  except
    on E: Exception do Degrade('temporary journal unavailable: ' + E.Message);
  end;
end;

destructor TLWPTSilentJournal.Destroy;
begin
  FStream.Free;
  if FJournalPath <> '' then DeleteFile(FJournalPath);
  FEmergencyRing.Free;
  inherited Destroy;
end;

procedure TLWPTSilentJournal.AppendEmergency(const AData: RawByteString);
begin
  FEmergencyRing.Append(AData);
end;

procedure TLWPTSilentJournal.Degrade(const AReason: string);
begin
  if FDegraded then Exit;
  FDegraded := True;
  FDegradedReason := AReason;
  FreeAndNil(FStream);
  if FJournalPath <> '' then DeleteFile(FJournalPath);
  FJournalPath := '';
  SetLength(FEntries, 0);
end;

procedure TLWPTSilentJournal.Retain(const ASequence: QWord;
  const AStream: TLWPTChildOutputStream;
  const ARetention: TLWPTEventRetention; const AOperationID: QWord;
  const AData: RawByteString);
var
  EntryIndex: Integer;
begin
  if AData = '' then Exit;
  AppendEmergency(AData);
  if FDegraded then Exit;
  if QWord(FStream.Size) + QWord(Length(AData))
     > SilentJournalMaximumBytes then
  begin
    Degrade('temporary journal reached its 64 MiB retention cap');
    Exit;
  end;
  try
    EntryIndex := Length(FEntries);
    SetLength(FEntries, EntryIndex + 1);
    FEntries[EntryIndex].Sequence := ASequence;
    FEntries[EntryIndex].Stream := AStream;
    FEntries[EntryIndex].Retention := ARetention;
    FEntries[EntryIndex].OperationID := AOperationID;
    FEntries[EntryIndex].DataOffset := FStream.Position;
    FEntries[EntryIndex].DataLength := Length(AData);
    FStream.WriteBuffer(AData[1], Length(AData));
  except
    on E: Exception do Degrade('temporary journal write failed: ' + E.Message);
  end;
end;

function TLWPTSilentJournal.BeginChildOperation: QWord;
begin
  Inc(FNextOperationID);
  if FNextOperationID = 0 then Inc(FNextOperationID);
  Result := FNextOperationID;
end;

procedure TLWPTSilentJournal.FinishChildOperation(
  const AOperationID: QWord; const AFailed: Boolean);
var
  EntryIndex: Integer;
begin
  if not AFailed then Exit;
  for EntryIndex := 0 to High(FEntries) do
    if (FEntries[EntryIndex].OperationID = AOperationID)
       and (FEntries[EntryIndex].Retention = oerOrdinary) then
      FEntries[EntryIndex].Retention := oerProtected;
end;

procedure TLWPTSilentJournal.Deliver(const AEvent: TCLIEventEnvelope);
var
  Child: TLWPTChildOutputEvent;
  Diagnostic: TLWPTDiagnosticEvent;
begin
  try
    if AEvent.Payload is TLWPTChildOutputEvent then
    begin
      Child := TLWPTChildOutputEvent(AEvent.Payload);
      Retain(AEvent.Sequence, Child.Stream, Child.Retention,
        ActiveSilentChildOperationID, Child.Data);
    end
    else if AEvent.Payload is TLWPTDiagnosticEvent then
    begin
      Diagnostic := TLWPTDiagnosticEvent(AEvent.Payload);
      Retain(AEvent.Sequence, ocosStderr, Diagnostic.Retention,
        0, RawByteString(Diagnostic.MessageText));
    end;
  except
    on E: Exception do
      Degrade('event retention failed: ' + E.Message);
  end;
end;

procedure TLWPTSilentJournal.ReplayFailure;
var
  Data: RawByteString;
  EntryIndex: Integer;
  LastByte: AnsiChar;
  WroteData: Boolean;
begin
  if FDegraded then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME,
      ': silent capture degraded; replaying emergency output tail (',
      FDegradedReason, ')');
    Data := FEmergencyRing.Tail;
    if Data <> '' then Write(ErrOutput, Data);
    if (Data <> '') and not (Data[Length(Data)] in [#10, #13]) then
      WriteLn(ErrOutput);
    Exit;
  end;

  WroteData := False;
  LastByte := #0;
  try
    for EntryIndex := 0 to High(FEntries) do
      { Only protected evidence survives normal silent failure replay.
        Failed child operations are promoted after their exit status is known;
        successful child output and ordinary progress remain suppressed. }
      if FEntries[EntryIndex].Retention <> oerOrdinary then
      begin
        FStream.Position := FEntries[EntryIndex].DataOffset;
        SetLength(Data, FEntries[EntryIndex].DataLength);
        if Data <> '' then FStream.ReadBuffer(Data[1], Length(Data));
        if Data <> '' then
        begin
          Write(ErrOutput, Data);
          WroteData := True;
          LastByte := Data[Length(Data)];
        end;
      end;
    if WroteData and not (LastByte in [#10, #13]) then WriteLn(ErrOutput);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, PROGRAM_NAME,
        ': silent capture degraded; replaying emergency output tail (',
        E.Message, ')');
      Data := FEmergencyRing.Tail;
      if Data <> '' then Write(ErrOutput, Data);
      if (Data <> '') and not (Data[Length(Data)] in [#10, #13]) then
        WriteLn(ErrOutput);
    end;
  end;
end;

constructor TLWPTEventTextStream.Create(const ADispatcher: TCLIEventDispatcher;
  const ASource, ACorrelationID: string;
  const AStream: TLWPTChildOutputStream;
  const ARetention: TLWPTEventRetention);
begin
  inherited Create;
  FDispatcher := ADispatcher;
  FSource := ASource;
  FCorrelationID := ACorrelationID;
  FStream := AStream;
  FRetention := ARetention;
end;

function TLWPTEventTextStream.Read(var ABuffer; ACount: LongInt): LongInt;
begin
  Result := 0;
end;

function TLWPTEventTextStream.Seek(const AOffset: Int64;
  AOrigin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

function TLWPTEventTextStream.Write(const ABuffer; ACount: LongInt): LongInt;
var
  Data: RawByteString;
begin
  Result := ACount;
  if ACount <= 0 then Exit;
  try
    SetLength(Data, ACount);
    Move(ABuffer, Data[1], ACount);
    { Observer delivery is best effort by contract. A retention failure must
      never replace or interrupt the command being observed. }
    FDispatcher.Publish(TLWPTChildOutputEvent.Create(FSource,
      FCorrelationID, FStream, Data, FRetention));
  except
    { Text output remains successful even when event allocation fails. }
  end;
end;

constructor TLWPTOutputRenderer.Create;
begin
  inherited Create;
end;

destructor TLWPTOutputRenderer.Destroy;
begin
  if FCapturing then
  begin
    try
      Flush(Output);
      Flush(ErrOutput);
      Close(Output);
      Close(ErrOutput);
    except
      { Restore the real terminal even after an observer failure. }
    end;
    RestoreStandardFiles;
  end;
  ClearInvocation;
  if ActiveRenderer = Self then ActiveRenderer := nil;
  inherited Destroy;
end;

procedure TLWPTOutputRenderer.ClearInvocation;
begin
  FOutputStream.Free;
  FOutputStream := nil;
  FErrorStream.Free;
  FErrorStream := nil;
  FDispatcher.Free;
  FDispatcher := nil;
  FJournalSink := nil;
  FJournal := nil;
  FCommandName := '';
  FCorrelationID := '';
end;

procedure TLWPTOutputRenderer.BeginSilent(const ACommandName: string);
var
  Dispatcher: TCLIEventDispatcher;
  Journal: TLWPTSilentJournal;
begin
  if FCapturing then
    raise ELWPTOutputRendererError.Create(
      'silent-output journal is already active');
  FCommandName := ACommandName;
  FCorrelationID := ACommandName + ':' + UIntToStr(GetTickCount64);
  Journal := TLWPTSilentJournal.Create;
  FJournal := Journal;
  FJournalSink := Journal as ICLIEventSink;
  Dispatcher := TCLIEventDispatcher.Create(FJournalSink);
  FDispatcher := Dispatcher;
  FOutputStream := TLWPTEventTextStream.Create(Dispatcher, ACommandName,
    FCorrelationID, ocosStdout, oerOrdinary);
  FErrorStream := TLWPTEventTextStream.Create(Dispatcher, ACommandName,
    FCorrelationID, ocosStderr, oerProtected);

  Flush(Output);
  Flush(ErrOutput);
  FOriginalOutput := TextRec(Output);
  FOriginalError := TextRec(ErrOutput);
  try
    AssignStream(Output, TStream(FOutputStream));
    Rewrite(Output);
    AssignStream(ErrOutput, TStream(FErrorStream));
    Rewrite(ErrOutput);
    FCapturing := True;
  except
    RestoreStandardFiles;
    ClearInvocation;
    raise ELWPTOutputRendererError.Create(
      'cannot initialize silent-output event streams');
  end;
end;

procedure TLWPTOutputRenderer.RestoreStandardFiles;
begin
  TextRec(Output) := FOriginalOutput;
  TextRec(ErrOutput) := FOriginalError;
  FCapturing := False;
end;

procedure TLWPTOutputRenderer.PublishChild(const AStandardOutput,
  AStandardError: RawByteString);
var
  Dispatcher: TCLIEventDispatcher;
  Retention: TLWPTEventRetention;
begin
  if not FCapturing then Exit;
  { TextRec buffers direct host writes. Drain both before a child/result event
    so the dispatcher sequence reflects the execution boundary. }
  Flush(Output);
  Flush(ErrOutput);
  Dispatcher := TCLIEventDispatcher(FDispatcher);
  if ActiveSilentChildOperationID = 0 then Retention := oerProtected
  else Retention := oerOrdinary;
  try
    if AStandardOutput <> '' then
      Dispatcher.Publish(TLWPTChildOutputEvent.Create(FCommandName,
        FCorrelationID, ocosStdout, AStandardOutput, Retention));
    if AStandardError <> '' then
      Dispatcher.Publish(TLWPTChildOutputEvent.Create(FCommandName,
        FCorrelationID, ocosStderr, AStandardError, Retention));
  except
    { Child drainage and its exit result are authoritative. }
  end;
end;

procedure TLWPTOutputRenderer.FinishSilent(const AExitCode: Integer;
  const AElapsedMilliseconds: QWord);
var
  CloseError: string;
begin
  if not FCapturing then Exit;
  CloseError := '';
  try
    try
      Flush(Output);
      Flush(ErrOutput);
    except
      on E: Exception do CloseError := E.Message;
    end;
    try
      TCLIEventDispatcher(FDispatcher).Publish(
        TLWPTCommandTerminalEvent.Create(FCommandName, FCorrelationID,
          AExitCode, AElapsedMilliseconds));
    except
      { Terminal-event observation cannot replace the command result. }
    end;
    try
      Close(Output);
      Close(ErrOutput);
    except
      on E: Exception do
        if CloseError = '' then CloseError := E.Message;
    end;
  finally
    RestoreStandardFiles;
  end;
  try
    try
      if AExitCode <> 0 then
      begin
        if CloseError <> '' then
          WriteLn(ErrOutput, PROGRAM_NAME,
            ': silent capture degraded while closing event streams: ',
            CloseError);
        TLWPTSilentJournal(FJournal).ReplayFailure;
      end;
    except
      { Replay is diagnostic policy. Its failure cannot replace the command
        outcome or prevent the host from writing the canonical final result. }
    end;
  finally
    ClearInvocation;
  end;
end;

end.
