{ LWPT.ProcessRunner — bounded duplex child-process communication. }
unit LWPT.ProcessRunner;

{$I Shared.inc}
{$J-}

interface

uses
  Process,

  LWPT.Core,
  LWPT.ProcessTree;

const
  PROCESS_RUNNER_DEFAULT_CAPTURE_BYTES = 16 * 1024 * 1024;

type
  ELWPTProcessRunnerError = class(ELWPTError);
  ELWPTProcessRunnerTimeout = class(ELWPTProcessRunnerError);

  TLWPTProcessRunOptions = record
    SeparateStandardError: Boolean;
    TimeoutMilliseconds: QWord;
    MaximumStandardOutputBytes: QWord;
    MaximumStandardErrorBytes: QWord;
    OperationName: string;
  end;

  TLWPTDuplexProcessRunner = class
  private
    FProcess: TProcess;
    FProcessTree: TLWPTProcessTree;
    FStarted: Boolean;
  public
    constructor Create(const AProcess: TProcess);
    destructor Destroy; override;
    procedure Start(const AOptions: TLWPTProcessRunOptions);
    function Communicate(const AStandardInput: string;
      const AOptions: TLWPTProcessRunOptions; out AStandardOutput,
      AStandardError: string): Integer;
    function Run(const AStandardInput: string;
      const AOptions: TLWPTProcessRunOptions; out AStandardOutput,
      AStandardError: string): Integer;
    procedure Cancel;
  end;

function DefaultProcessRunOptions(const AOperationName: string):
  TLWPTProcessRunOptions;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Command.Common,
  Pipes;

const
  PROCESS_RUNNER_POLL_MILLISECONDS = 10;
  PROCESS_RUNNER_DIRECT_CHILD_EXIT_MILLISECONDS = 1000;
  PROCESS_RUNNER_WRITER_EXIT_MILLISECONDS = 1000;

{$IFDEF MSWINDOWS}
function LWPTCancelSynchronousIo(const AThreadHandle: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'CancelSynchronousIo';
{$ENDIF}

type
  TLWPTPipeWriter = class(TThread)
  private
    FProcess: TProcess;
    FText: string;
    FErrorMessage: string;
    procedure RequestCancellation;
    function WaitUntilFinished(const ATimeoutMilliseconds: QWord): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProcess: TProcess;
      const AText: string);
    destructor Destroy; override;
    procedure CancelAndJoin;
    property ErrorMessage: string read FErrorMessage;
  end;

  TLWPTProcessTerminationThread = class(TThread)
  private
    FProcessTree: TLWPTProcessTree;
    FErrorMessage: string;
    FDone: Boolean;
    FCriticalSection: TRTLCriticalSection;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProcessTree: TLWPTProcessTree);
    destructor Destroy; override;
    function ErrorMessage: string;
    function IsDone: Boolean;
  end;

constructor TLWPTPipeWriter.Create(const AProcess: TProcess;
  const AText: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProcess := AProcess;
  FText := AText;
end;

procedure TLWPTPipeWriter.Execute;
{$IFDEF UNIX}
var
  ErrorCode, InputFlags, InputHandle, Offset, WriteCount, Written: Integer;
{$ENDIF}
begin
  try
    if Terminated then Exit;
    {$IFDEF UNIX}
    InputHandle := FProcess.Input.Handle;
    InputFlags := FpFcntl(InputHandle, F_GETFL, 0);
    if InputFlags < 0 then RaiseLastOSError;
    if FpFcntl(InputHandle, F_SETFL, InputFlags or O_NONBLOCK) < 0 then
      RaiseLastOSError;
    Offset := 1;
    while (Offset <= Length(FText)) and (not Terminated) do
    begin
      WriteCount := Length(FText) - Offset + 1;
      if WriteCount > PROCESS_OUTPUT_BUFFER_SIZE then
        WriteCount := PROCESS_OUTPUT_BUFFER_SIZE;
      Written := FpWrite(InputHandle, FText[Offset], WriteCount);
      if Written > 0 then
        Inc(Offset, Written)
      else if Written = 0 then
        Sleep(PROCESS_RUNNER_POLL_MILLISECONDS)
      else
      begin
        ErrorCode := FpGetErrNo;
        if (ErrorCode = ESysEAGAIN) or (ErrorCode = ESysEWOULDBLOCK)
           or (ErrorCode = ESysEINTR) then
          Sleep(PROCESS_RUNNER_POLL_MILLISECONDS)
        else if not Terminated then
          raise EOSError.Create(SysErrorMessage(ErrorCode));
      end;
    end;
    {$ELSE}
    if (FText <> '') and (not Terminated) then
      FProcess.Input.WriteBuffer(FText[1], Length(FText));
    {$ENDIF}
    if not Terminated then FProcess.CloseInput;
  except
    on E: Exception do
      if not Terminated then FErrorMessage := E.Message;
  end;
end;

procedure TLWPTPipeWriter.RequestCancellation;
begin
  Terminate;
  {$IFDEF MSWINDOWS}
  { Anonymous-pipe writes are synchronous on Windows. Cancel the writer's
    pending I/O so a surviving descendant cannot pin thread destruction. }
  if not Finished then LWPTCancelSynchronousIo(Handle);
  {$ENDIF}
end;

function TLWPTPipeWriter.WaitUntilFinished(
  const ATimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMilliseconds;
  while (not Finished) and (GetTickCount64 < Deadline) do
  begin
    {$IFDEF MSWINDOWS}
    { Cancellation may have raced just ahead of the synchronous write. Keep
      cancelling until the writer acknowledges completion. }
    if Terminated then LWPTCancelSynchronousIo(Handle);
    {$ENDIF}
    Sleep(PROCESS_RUNNER_POLL_MILLISECONDS);
  end;
  Result := Finished;
end;

procedure TLWPTPipeWriter.CancelAndJoin;
begin
  if not Finished then RequestCancellation;
  if not WaitUntilFinished(PROCESS_RUNNER_WRITER_EXIT_MILLISECONDS) then
    raise ELWPTProcessRunnerError.Create(
      'standard-input writer did not stop after cancellation');
  WaitFor;
  try
    FProcess.CloseInput;
  except
  end;
end;

destructor TLWPTPipeWriter.Destroy;
begin
  { Startup and exception cleanup use the same bounded cancellation contract
    as the normal communication path. }
  if not Finished then CancelAndJoin;
  inherited Destroy;
end;

constructor TLWPTProcessTerminationThread.Create(
  const AProcessTree: TLWPTProcessTree);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProcessTree := AProcessTree;
  InitCriticalSection(FCriticalSection);
end;

destructor TLWPTProcessTerminationThread.Destroy;
begin
  WaitFor;
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

procedure TLWPTProcessTerminationThread.Execute;
begin
  try
    try
      FProcessTree.Terminate;
    except
      on E: Exception do
      begin
        EnterCriticalSection(FCriticalSection);
        try
          FErrorMessage := E.Message;
        finally
          LeaveCriticalSection(FCriticalSection);
        end;
      end;
    end;
  finally
    EnterCriticalSection(FCriticalSection);
    try
      FDone := True;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
  end;
end;

function TLWPTProcessTerminationThread.ErrorMessage: string;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FErrorMessage;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TLWPTProcessTerminationThread.IsDone: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FDone;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function DefaultProcessRunOptions(const AOperationName: string):
  TLWPTProcessRunOptions;
begin
  Result := Default(TLWPTProcessRunOptions);
  Result.OperationName := AOperationName;
  Result.MaximumStandardOutputBytes := PROCESS_RUNNER_DEFAULT_CAPTURE_BYTES;
  Result.MaximumStandardErrorBytes := PROCESS_RUNNER_DEFAULT_CAPTURE_BYTES;
end;

constructor TLWPTDuplexProcessRunner.Create(const AProcess: TProcess);
begin
  inherited Create;
  if not Assigned(AProcess) then
    raise ELWPTProcessRunnerError.Create('process runner needs a process');
  FProcess := AProcess;
  FProcessTree := TLWPTProcessTree.Create(FProcess);
end;

destructor TLWPTDuplexProcessRunner.Destroy;
begin
  FProcessTree.Free;
  inherited Destroy;
end;

procedure TLWPTDuplexProcessRunner.Start(
  const AOptions: TLWPTProcessRunOptions);
begin
  if FStarted then
    raise ELWPTProcessRunnerError.Create('process runner already started');
  FProcess.Options := [poUsePipes];
  if not AOptions.SeparateStandardError then
    FProcess.Options := FProcess.Options + [poStderrToOutPut];
  FProcessTree.Execute;
  FStarted := True;
end;

procedure DrainPipe(const APipe: TInputPipeStream; var AOutput: string;
  const AMaximumBytes: QWord; var AExceeded: Boolean);
var
  Buffer: array[0..PROCESS_OUTPUT_BUFFER_SIZE - 1] of Byte;
  Available, Count, ReadSize, RetainedCount: Integer;
  Remaining: QWord;
begin
  { Drain a bounded snapshot so a child that emits faster than the parent can
    read cannot trap the runner inside this procedure before timeout/overflow
    handling gets a turn. Later bytes are consumed on the next poll. }
  Available := APipe.NumBytesAvailable;
  while Available > 0 do
  begin
    ReadSize := SizeOf(Buffer);
    if Available < ReadSize then ReadSize := Available;
    Count := APipe.Read(Buffer[0], ReadSize);
    if Count <= 0 then Exit;
    Dec(Available, Count);
    RetainedCount := Count;
    if AExceeded then
      RetainedCount := 0
    else if AMaximumBytes > 0 then
    begin
      if QWord(Length(AOutput)) >= AMaximumBytes then
      begin
        RetainedCount := 0;
        AExceeded := True;
      end
      else
      begin
        Remaining := AMaximumBytes - QWord(Length(AOutput));
        if QWord(Count) > Remaining then
        begin
          RetainedCount := Integer(Remaining);
          AExceeded := True;
        end;
      end;
    end;
    if RetainedCount > 0 then
      AppendRawBytes(AOutput, Buffer[0], RetainedCount);
  end;
end;

function TLWPTDuplexProcessRunner.Communicate(
  const AStandardInput: string; const AOptions: TLWPTProcessRunOptions;
  out AStandardOutput, AStandardError: string): Integer;
var
  FailureMessage, TerminationFailure: string;
  DirectChildDeadline, StartedAt: QWord;
  StandardErrorExceeded, StandardOutputExceeded: Boolean;
  TerminationThread: TLWPTProcessTerminationThread;
  TimedOut: Boolean;
  Writer: TLWPTPipeWriter;
begin
  if not FStarted then
    raise ELWPTProcessRunnerError.Create('process runner is not started');
  AStandardOutput := '';
  AStandardError := '';
  FailureMessage := '';
  TerminationFailure := '';
  TimedOut := False;
  StandardOutputExceeded := False;
  StandardErrorExceeded := False;
  Writer := TLWPTPipeWriter.Create(FProcess, AStandardInput);
  TerminationThread := nil;
  try
    StartedAt := GetTickCount64;
    Writer.Start;
    try
      while FProcess.Running do
      begin
        DrainPipe(FProcess.Output, AStandardOutput,
          AOptions.MaximumStandardOutputBytes, StandardOutputExceeded);
        if AOptions.SeparateStandardError then
          DrainPipe(FProcess.Stderr, AStandardError,
            AOptions.MaximumStandardErrorBytes, StandardErrorExceeded);
        if StandardOutputExceeded then
        begin
          FailureMessage := Format(
            'standard output exceeded its %d-byte capture limit',
            [AOptions.MaximumStandardOutputBytes]);
          Break;
        end;
        if StandardErrorExceeded then
        begin
          FailureMessage := Format(
            'standard error exceeded its %d-byte capture limit',
            [AOptions.MaximumStandardErrorBytes]);
          Break;
        end;
        if (AOptions.TimeoutMilliseconds > 0)
           and (GetTickCount64 - StartedAt
             >= AOptions.TimeoutMilliseconds) then
        begin
          TimedOut := True;
          Break;
        end;
        Sleep(PROCESS_RUNNER_POLL_MILLISECONDS);
      end;
      if TimedOut or (FailureMessage <> '') then
      begin
        Writer.RequestCancellation;
        TerminationThread := TLWPTProcessTerminationThread.Create(
          FProcessTree);
        TerminationThread.Start;
        while FProcess.Running do
        begin
          DrainPipe(FProcess.Output, AStandardOutput,
            AOptions.MaximumStandardOutputBytes, StandardOutputExceeded);
          if AOptions.SeparateStandardError then
            DrainPipe(FProcess.Stderr, AStandardError,
              AOptions.MaximumStandardErrorBytes, StandardErrorExceeded);
          if TerminationThread.IsDone then
          begin
            TerminationFailure := TerminationThread.ErrorMessage;
            { Terminate normally leaves no direct child. If it returned an
              error while that child is still live, make one direct bounded
              fallback instead of polling forever. The writer was already
              cancelled and closes stdin after its bounded join. }
            try
              FProcess.Terminate(1);
            except
              on E: Exception do
                if TerminationFailure = '' then
                  TerminationFailure := E.Message;
            end;
            DirectChildDeadline := GetTickCount64
              + PROCESS_RUNNER_DIRECT_CHILD_EXIT_MILLISECONDS;
            while FProcess.Running
              and (GetTickCount64 < DirectChildDeadline) do
            begin
              DrainPipe(FProcess.Output, AStandardOutput,
                AOptions.MaximumStandardOutputBytes,
                StandardOutputExceeded);
              if AOptions.SeparateStandardError then
                DrainPipe(FProcess.Stderr, AStandardError,
                  AOptions.MaximumStandardErrorBytes,
                  StandardErrorExceeded);
              Sleep(PROCESS_RUNNER_POLL_MILLISECONDS);
            end;
            if FProcess.Running then
              raise ELWPTProcessRunnerError.Create(
                'direct child remained live after process-tree termination');
            Break;
          end;
          Sleep(PROCESS_RUNNER_POLL_MILLISECONDS);
        end;
        TerminationThread.WaitFor;
        if TerminationFailure = '' then
          TerminationFailure := TerminationThread.ErrorMessage;
      end;
      DrainPipe(FProcess.Output, AStandardOutput,
        AOptions.MaximumStandardOutputBytes, StandardOutputExceeded);
      if AOptions.SeparateStandardError then
        DrainPipe(FProcess.Stderr, AStandardError,
          AOptions.MaximumStandardErrorBytes, StandardErrorExceeded);
      if not FProcess.Running then FProcess.WaitOnExit;
    finally
      Writer.CancelAndJoin;
    end;
    if TimedOut then
      raise ELWPTProcessRunnerTimeout.CreateFmt('%s timed out after %d ms',
        [AOptions.OperationName, AOptions.TimeoutMilliseconds]);
    if FailureMessage <> '' then
    begin
      if TerminationFailure <> '' then
        FailureMessage := FailureMessage + '; process-tree termination: '
          + TerminationFailure;
      raise ELWPTProcessRunnerError.Create(FailureMessage);
    end;
    if TerminationFailure <> '' then
      raise ELWPTProcessRunnerError.Create(
        'could not terminate process tree: ' + TerminationFailure);
    if Writer.ErrorMessage <> '' then
      raise ELWPTProcessRunnerError.Create(
        'could not write process standard input: ' + Writer.ErrorMessage);
    Result := NormalisedExitCode(FProcess);
  finally
    TerminationThread.Free;
    Writer.Free;
  end;
end;

function TLWPTDuplexProcessRunner.Run(const AStandardInput: string;
  const AOptions: TLWPTProcessRunOptions; out AStandardOutput,
  AStandardError: string): Integer;
begin
  Start(AOptions);
  Result := Communicate(AStandardInput, AOptions, AStandardOutput,
    AStandardError);
end;

procedure TLWPTDuplexProcessRunner.Cancel;
begin
  if FStarted then FProcessTree.Terminate;
end;

initialization
  {$IFDEF UNIX}
  { A timed-out child may close stdin while the writer thread is blocked.
    Treat that as an ordinary write error instead of terminating LWPT. }
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}

end.
