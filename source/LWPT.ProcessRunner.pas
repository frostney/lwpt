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
    FInputHandle: THandle;
    FStartAttempted: Boolean;
    FStarted: Boolean;
    FText: string;
    FErrorMessage: string;
    procedure CloseOwnedInput;
    procedure RequestCancellation;
    function WaitUntilFinished(const ATimeoutMilliseconds: QWord): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProcess: TProcess;
      const AText: string);
    destructor Destroy; override;
    function CancelAndJoin: Boolean;
    function StartWriting: Boolean;
    property ErrorMessage: string read FErrorMessage;
  end;

  TLWPTProcessTerminationThread = class(TThread)
  private
    FProcessTree: TLWPTProcessTree;
    FErrorMessage: string;
    FDone: Boolean;
    FStarted: Boolean;
    FCriticalSection: TRTLCriticalSection;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProcessTree: TLWPTProcessTree);
    destructor Destroy; override;
    function ErrorMessage: string;
    function IsDone: Boolean;
    procedure StartTermination;
    procedure WaitForCompletion;
  end;

var
  AbandonedPipeWriters: TList;
  AbandonedPipeWritersCriticalSection: TRTLCriticalSection;

function DuplicatePipeHandle(const AHandle: THandle): THandle;
{$IFDEF MSWINDOWS}
var
  Duplicated: THandle;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := FpDup(AHandle);
  if Result < 0 then RaiseLastOSError;
  {$ELSE}
  Duplicated := 0;
  if not Windows.DuplicateHandle(Windows.GetCurrentProcess, AHandle,
    Windows.GetCurrentProcess, @Duplicated, 0, False,
    DUPLICATE_SAME_ACCESS) then
    RaiseLastOSError;
  Result := Duplicated;
  {$ENDIF}
end;

procedure ClosePipeHandle(var AHandle: THandle);
var
  HandleToClose: THandle;
begin
  HandleToClose := AHandle;
  AHandle := THandle(-1);
  if HandleToClose = THandle(-1) then Exit;
  {$IFDEF UNIX}
  FpClose(HandleToClose);
  {$ELSE}
  Windows.CloseHandle(HandleToClose);
  {$ENDIF}
end;

constructor TLWPTPipeWriter.Create(const AProcess: TProcess;
  const AText: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FInputHandle := THandle(-1);
  FInputHandle := DuplicatePipeHandle(AProcess.Input.Handle);
  FText := AText;
end;

procedure TLWPTPipeWriter.CloseOwnedInput;
begin
  ClosePipeHandle(FInputHandle);
end;

procedure TLWPTPipeWriter.Execute;
{$IFDEF UNIX}
var
  ErrorCode, InputFlags, InputHandle, Offset, WriteCount, Written: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode, Offset, WriteCount: Integer;
  Written: DWORD;
{$ENDIF}
begin
  try
    try
      if Terminated then Exit;
      {$IFDEF UNIX}
      InputHandle := FInputHandle;
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
      Offset := 1;
      while (Offset <= Length(FText)) and (not Terminated) do
      begin
        WriteCount := Length(FText) - Offset + 1;
        if WriteCount > PROCESS_OUTPUT_BUFFER_SIZE then
          WriteCount := PROCESS_OUTPUT_BUFFER_SIZE;
        Written := 0;
        if Windows.WriteFile(FInputHandle, FText[Offset], WriteCount, Written,
          nil) then
        begin
          if Written > 0 then Inc(Offset, Written)
          else Sleep(PROCESS_RUNNER_POLL_MILLISECONDS);
        end
        else if not Terminated then
        begin
          ErrorCode := Windows.GetLastError;
          raise EOSError.Create(SysErrorMessage(ErrorCode));
        end;
      end
      {$ENDIF}
    except
      on E: Exception do
        if not Terminated then FErrorMessage := E.Message;
    end;
  finally
    CloseOwnedInput;
  end;
end;

function TLWPTPipeWriter.StartWriting: Boolean;
begin
  FStartAttempted := True;
  try
    Start;
    FStarted := True;
    Result := True;
  except
    on E: Exception do
    begin
      FStartAttempted := False;
      FErrorMessage := 'could not start standard-input writer: ' + E.Message;
      Terminate;
      CloseOwnedInput;
      Result := False;
    end;
  end;
end;

procedure QuarantinePipeWriter(const AWriter: TLWPTPipeWriter);
begin
  EnterCriticalSection(AbandonedPipeWritersCriticalSection);
  try
    AbandonedPipeWriters.Add(AWriter);
  finally
    LeaveCriticalSection(AbandonedPipeWritersCriticalSection);
  end;
end;

procedure ReapFinishedPipeWriters;
var
  Index: Integer;
  Writer: TLWPTPipeWriter;
begin
  EnterCriticalSection(AbandonedPipeWritersCriticalSection);
  try
    Index := AbandonedPipeWriters.Count - 1;
    while Index >= 0 do
    begin
      Writer := TLWPTPipeWriter(AbandonedPipeWriters[Index]);
      if Writer.Finished then
      begin
        AbandonedPipeWriters.Delete(Index);
        Writer.Free;
      end;
      Dec(Index);
    end;
  finally
    LeaveCriticalSection(AbandonedPipeWritersCriticalSection);
  end;
end;

procedure TLWPTPipeWriter.RequestCancellation;
begin
  Terminate;
  {$IFDEF MSWINDOWS}
  { Anonymous-pipe writes are synchronous on Windows. Cancel the writer's
    pending I/O so a surviving descendant cannot pin thread destruction. }
  if FStartAttempted and (not Finished) then
    LWPTCancelSynchronousIo(Handle);
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

function TLWPTPipeWriter.CancelAndJoin: Boolean;
begin
  if not FStartAttempted then
  begin
    Terminate;
    CloseOwnedInput;
    Exit(True);
  end;
  if not Finished then RequestCancellation;
  if not WaitUntilFinished(PROCESS_RUNNER_WRITER_EXIT_MILLISECONDS) then
  begin
    FErrorMessage :=
      'standard-input writer did not stop after cancellation';
    { The writer exclusively owns a duplicated pipe handle and no process
      object. Quarantine it instead of blocking this invocation or destroying
      a live thread. }
    Exit(False);
  end;
  WaitFor;
  Result := True;
end;

destructor TLWPTPipeWriter.Destroy;
begin
  { Startup and exception cleanup use the same bounded cancellation contract
    as the normal communication path. }
  try
    if not FStarted then
    begin
      Terminate;
      CloseOwnedInput;
    end
    else if not Finished then
      WaitFor;
  finally
    inherited Destroy;
  end;
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
  try
    if FStarted then WaitFor
    else Terminate;
    inherited Destroy;
  finally
    DoneCriticalSection(FCriticalSection);
  end;
end;

procedure TLWPTProcessTerminationThread.Execute;
begin
  try
    if Terminated then Exit;
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

procedure TLWPTProcessTerminationThread.StartTermination;
begin
  try
    Start;
    FStarted := True;
  except
    on E: Exception do
    begin
      EnterCriticalSection(FCriticalSection);
      try
        FErrorMessage := 'termination worker did not start: ' + E.Message;
        FDone := True;
      finally
        LeaveCriticalSection(FCriticalSection);
      end;
      Terminate;
    end;
  end;
end;

procedure TLWPTProcessTerminationThread.WaitForCompletion;
begin
  if FStarted then WaitFor;
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
  WriterAbandoned: Boolean;
  Writer: TLWPTPipeWriter;
begin
  if not FStarted then
    raise ELWPTProcessRunnerError.Create('process runner is not started');
  ReapFinishedPipeWriters;
  AStandardOutput := '';
  AStandardError := '';
  FailureMessage := '';
  TerminationFailure := '';
  TimedOut := False;
  StandardOutputExceeded := False;
  StandardErrorExceeded := False;
  WriterAbandoned := False;
  Writer := nil;
  TerminationThread := nil;
  try
    try
      Writer := TLWPTPipeWriter.Create(FProcess, AStandardInput);
    except
      on E: Exception do
      begin
        FailureMessage := 'could not prepare standard-input writer: '
          + E.Message;
        try
          FProcessTree.Terminate;
        except
          on TerminationError: Exception do
            FailureMessage := FailureMessage + '; process-tree termination: '
              + TerminationError.Message;
        end;
        raise ELWPTProcessRunnerError.Create(FailureMessage);
      end;
    end;
    StartedAt := GetTickCount64;
    try
      if not Writer.StartWriting then
        FailureMessage := Writer.ErrorMessage;
      { The writer owns a duplicated handle. Close TProcess's original copy
        now so child EOF depends only on the process-independent writer. }
      try
        FProcess.CloseInput;
      except
        on E: Exception do
          if FailureMessage = '' then
            FailureMessage := 'could not close original standard-input '
              + 'handle: ' + E.Message;
      end;
      while FProcess.Running do
      begin
        if FailureMessage <> '' then Break;
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
        TerminationThread.StartTermination;
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
        TerminationThread.WaitForCompletion;
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
      WriterAbandoned := not Writer.CancelAndJoin;
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
    if WriterAbandoned then
    begin
      QuarantinePipeWriter(Writer);
      Writer := nil;
    end;
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
  AbandonedPipeWriters := TList.Create;
  InitCriticalSection(AbandonedPipeWritersCriticalSection);
  {$IFDEF UNIX}
  { A timed-out child may close stdin while the writer thread is blocked.
    Treat that as an ordinary write error instead of terminating LWPT. }
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}

finalization
  { Never wait during unit shutdown. Finished quarantined writers are reaped;
    a still-blocked writer and its private OS handle are left for process exit. }
  ReapFinishedPipeWriters;
  AbandonedPipeWriters.Free;
  DoneCriticalSection(AbandonedPipeWritersCriticalSection);

end.
