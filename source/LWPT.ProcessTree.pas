{ LWPT.ProcessTree — isolated subprocess ownership and cascading cancellation.
  See ADR-0025 for the process-group, nested-job, signal-forwarding, and
  reap-until-empty contracts. }
unit LWPT.ProcessTree;

{$I Shared.inc}
{$J-}

interface

uses
  Process,
  SysUtils,

  LWPT.Core;

type
  TLWPTProtocolReadResult = (prrPending, prrFrame, prrRejected);

  TLWPTProcessTree = class
  private
    {$IFDEF MSWINDOWS}
    type
      TWindowsState = class
      private
        FJobHandle: THandle;
      public
        constructor Create;
        destructor Destroy; override;
        function HasActiveProcesses: Boolean;
        function TryAssignProcess(const AProcessHandle: THandle;
          out AErrorCode: LongWord): Boolean;
        function TryTerminate(const AExitCode: LongWord;
          out AErrorCode: LongWord): Boolean;
        function WaitUntilEmptyBefore(const ADeadline: QWord): Boolean;
      end;
    {$ENDIF}
  private
    FProcess: TProcess;
    {$IFDEF MSWINDOWS}
    FWindowsState: TWindowsState;
    {$ENDIF}
    FRegistered: Boolean;
    FImmediateTerminationRequested: LongInt;
    FTerminationCriticalSection: TRTLCriticalSection;
    FCriticalSectionInitialized: Boolean;
    FStatusReadHandle: PtrInt;
    FChildStatusWriteHandle: PtrInt;
    FControlWriteHandle: PtrInt;
    FChildControlReadHandle: PtrInt;
    FChannelToken: string;
    FStatusBuffer: string;
    FAcknowledgementRegistered: Boolean;
    FAcknowledgementFinished: Boolean;
    FAcknowledgementSucceeded: Boolean;
    FCancellationStarted: Boolean;
    FCancellationAcknowledgementRequired: Boolean;
    FCancellationAcknowledgementDeadline: QWord;
    {$IFDEF UNIX}
    procedure HandleFork(ASender: TObject);
    {$ENDIF}
    procedure RegisterActive;
    procedure UnregisterActive;
    procedure CreateAcknowledgementChannels;
    procedure CloseAcknowledgementChannels;
    procedure CloseChildAcknowledgementHandles;
    procedure MarkManagedChild;
    procedure DrainAcknowledgementFrames;
    function HasActiveOwnedProcesses: Boolean;
    function SendCancellationFrame(const ADescendantDeadline,
      AAcknowledgementDeadline: QWord): Boolean;
    procedure BeginForwardedTermination(const ADescendantDeadline,
      AAcknowledgementDeadline: QWord);
    procedure WaitForForwardedTermination(const ADeadline,
      AFinalReapDeadline: QWord);
    procedure TryTerminateDirectChild;
    {$IFDEF MSWINDOWS}
    procedure TerminateCreatedProcess;
    {$ENDIF}
  public
    class procedure NewTerminationDeadlines(out ADescendantDeadline,
      AAcknowledgementDeadline: QWord); static;
    constructor Create(const AProcess: TProcess);
    destructor Destroy; override;
    procedure BeginTermination(const ADescendantDeadline,
      AAcknowledgementDeadline: QWord);
    procedure CompleteTermination;
    procedure Execute;
    procedure Terminate;
  end;

procedure InstallProcessTreeSignalForwarding;
procedure ExecuteUnmanagedProcess(const AProcess: TProcess);
function FeedProcessTreeProtocol(var ABuffer: string;
  const ABytes: string; out ALine: string): TLWPTProtocolReadResult;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF};

{$if not declared(FD_CLOEXEC)}
{ POSIX fixes FD_CLOEXEC at 1; Darwin's BaseUnix declares it but Linux
  FPC's does not, so define it where the RTL omits it. }
const
  FD_CLOEXEC = 1;
{$endif}

const
  ProcessTreeTerminateGraceMilliseconds = 250;
  ProcessTreeTerminatePollMilliseconds = 10;
  ProcessTreeReapTimeoutMilliseconds = 3000;
  ForwardedReapTimeoutMilliseconds = 100;
  ProcessTreeSetupExitCode = 127;
  ProcessTreeCancellationExitCode = 1;
  SignalExitCodeBase = 128;
  ProcessGroupSetupError = 'process tree isolation setup failed'#10;
  ManagedProcessTreeEnvironment = PROJECT_NAME + '_PROCESS_TREE_PARENT';
  StatusHandleEnvironment = PROJECT_NAME + '_PROCESS_TREE_STATUS_HANDLE';
  ControlHandleEnvironment = PROJECT_NAME + '_PROCESS_TREE_CONTROL_HANDLE';
  ChannelTokenEnvironment = PROJECT_NAME + '_PROCESS_TREE_CHANNEL_TOKEN';
  AcknowledgementProtocol = PROJECT_NAME + '-ACK/1';
  AcknowledgementHello = 'HELLO';
  AcknowledgementCancel = 'CANCEL';
  AcknowledgementReaped = 'REAPED';
  AcknowledgementFailed = 'FAILED';
  ProtocolBufferCapacity = 4096;

  {$IFDEF MSWINDOWS}
  JobObjectBasicAccountingInformationClass = 1;
  NestedJobRequirement = '; nested Job Objects require Windows 8 or later';
  ToolhelpSnapshotAttempts = 3;
  {$ENDIF}

var
  ActiveProcessTrees: TList;
  ActiveProcessTreesCriticalSection: TRTLCriticalSection;
  ProcessSpawnCriticalSection: TRTLCriticalSection;
  SignalForwardingInstalled: Boolean = False;
  InheritedStatusWriteHandle: PtrInt = -1;
  InheritedControlReadHandle: PtrInt = -1;
  InheritedChannelToken: string = '';
  InheritedControlBuffer: string = '';
  InheritedManagedProcessTree: Boolean = False;

{$IFDEF UNIX}
const
  SignalPipeReadEnd = 0;
  SignalPipeWriteEnd = 1;

type
  TLWPTSignalForwarder = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  SignalForwarder: TLWPTSignalForwarder = nil;
  SignalPipe: TFilDes;

function CSetProcessGroup(const APID,
  AProcessGroupID: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setpgid';
  {$ELSE}
  external name 'setpgid';
  {$ENDIF}

function CSignal(const ASignal: LongInt;
  const AHandler: Pointer): Pointer; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'signal';
  {$ELSE}
  external name 'signal';
  {$ENDIF}

function CRaise(const ASignal: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'raise';
  {$ELSE}
  external name 'raise';
  {$ENDIF}

{ Failures of the libc externals above land in libc's errno. On Linux that
  is a different threadvar from the one FpGetErrNo reads (the RTL maintains
  its own for its raw-syscall wrappers), so libc errors must be read
  through libc's accessor -- FpGetErrNo there returns whatever stale code
  the last RTL call left behind. }
function CErrnoLocation: PInteger; cdecl;
  {$IFDEF LINUX}
  external 'c' name '__errno_location';
  {$ELSE}
  external name '__error';
  {$ENDIF}

function SignalHandlerFailed(const AHandler: Pointer): Boolean; inline;
begin
  Result := PtrUInt(AHandler) = High(PtrUInt);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
{$PACKRECORDS C}
type
  TLWPTJobObjectBasicAccountingInformation = record
    TotalUserTime: Int64;
    TotalKernelTime: Int64;
    ThisPeriodTotalUserTime: Int64;
    ThisPeriodTotalKernelTime: Int64;
    TotalPageFaultCount: DWORD;
    TotalProcesses: DWORD;
    ActiveProcesses: DWORD;
    TotalTerminatedProcesses: DWORD;
  end;
{$PACKRECORDS DEFAULT}

type
  TLWPTConsoleControlForwarder = class(TThread)
  protected
    procedure Execute; override;
  end;

  TLWPTInheritedControlForwarder = class(TThread)
  protected
    procedure Execute; override;
  end;

const
  WindowsControlExitCode = DWORD($C000013A);
  ToolhelpSnapshotProcesses = DWORD($00000002);

{$PACKRECORDS C}
type
  { FPC 3.2.2's Win64 Windows unit omits the Toolhelp process-enumeration
    surface, so keep the SDK ABI local just like the Job Object imports below. }
  TLWPTProcessEntry32W = record
    Size: DWORD;
    UsageCount: DWORD;
    ProcessID: DWORD;
    DefaultHeapID: PtrUInt;
    ModuleID: DWORD;
    ThreadCount: DWORD;
    ParentProcessID: DWORD;
    BasePriority: LongInt;
    Flags: DWORD;
    ExecutableFile: array[0..259] of WideChar;
  end;
{$PACKRECORDS DEFAULT}

var
  ConsoleControlEvent: THandle = 0;
  ConsoleControlForwarder: TLWPTConsoleControlForwarder = nil;
  InheritedControlForwarder: TLWPTInheritedControlForwarder = nil;

function LWPTCreateJobObject(const ASecurityAttributes: Pointer;
  const AName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';
function LWPTAssignProcessToJobObject(const AJob,
  AProcess: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';
function LWPTTerminateJobObject(const AJob: THandle;
  const AExitCode: UINT): BOOL; stdcall;
  external 'kernel32.dll' name 'TerminateJobObject';
function LWPTQueryInformationJobObject(const AJob: THandle;
  const AInformationClass: DWORD; const AInformation: Pointer;
  const AInformationLength: DWORD; const AReturnLength: PDWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryInformationJobObject';
function LWPTCreateToolhelp32Snapshot(const AFlags,
  AProcessID: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateToolhelp32Snapshot';
function LWPTProcess32FirstW(const ASnapshot: THandle;
  var AEntry: TLWPTProcessEntry32W): BOOL; stdcall;
  external 'kernel32.dll' name 'Process32FirstW';
function LWPTProcess32NextW(const ASnapshot: THandle;
  var AEntry: TLWPTProcessEntry32W): BOOL; stdcall;
  external 'kernel32.dll' name 'Process32NextW';

constructor TLWPTProcessTree.TWindowsState.Create;
begin
  inherited Create;
  FJobHandle := LWPTCreateJobObject(nil, nil);
  if FJobHandle = 0 then RaiseLastOSError;
end;

destructor TLWPTProcessTree.TWindowsState.Destroy;
begin
  if FJobHandle <> 0 then Windows.CloseHandle(FJobHandle);
  inherited Destroy;
end;

function TLWPTProcessTree.TWindowsState.HasActiveProcesses: Boolean;
var
  Accounting: TLWPTJobObjectBasicAccountingInformation;
  ErrorCode: DWORD;
begin
  FillChar(Accounting, SizeOf(Accounting), 0);
  if not LWPTQueryInformationJobObject(FJobHandle,
    JobObjectBasicAccountingInformationClass, @Accounting,
    SizeOf(Accounting), nil) then
  begin
    ErrorCode := Windows.GetLastError;
    raise EOSError.CreateFmt('could not inspect process Job Object: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  Result := Accounting.ActiveProcesses > 0;
end;

function TLWPTProcessTree.TWindowsState.TryAssignProcess(
  const AProcessHandle: THandle; out AErrorCode: LongWord): Boolean;
begin
  Result := LWPTAssignProcessToJobObject(FJobHandle, AProcessHandle);
  if Result then AErrorCode := 0
  else AErrorCode := Windows.GetLastError;
end;

function TLWPTProcessTree.TWindowsState.TryTerminate(
  const AExitCode: LongWord; out AErrorCode: LongWord): Boolean;
begin
  Result := LWPTTerminateJobObject(FJobHandle, AExitCode);
  if Result then AErrorCode := 0
  else AErrorCode := Windows.GetLastError;
end;

function TLWPTProcessTree.TWindowsState.WaitUntilEmptyBefore(
  const ADeadline: QWord): Boolean;
begin
  while HasActiveProcesses and (GetTickCount64 < ADeadline) do
    Sleep(ProcessTreeTerminatePollMilliseconds);
  Result := not HasActiveProcesses;
end;

function ProcessExitedBefore(const AProcessHandle: THandle;
  const ADeadline: QWord): Boolean;
var
  CurrentTick: QWord;
  RemainingMilliseconds: QWord;
begin
  if AProcessHandle = 0 then Exit(True);
  CurrentTick := GetTickCount64;
  if CurrentTick >= ADeadline then
    Exit(Windows.WaitForSingleObject(AProcessHandle, 0)
      = Windows.WAIT_OBJECT_0);
  RemainingMilliseconds := ADeadline - CurrentTick;
  if RemainingMilliseconds > High(DWORD) then
    RemainingMilliseconds := High(DWORD);
  Result := Windows.WaitForSingleObject(AProcessHandle,
    DWORD(RemainingMilliseconds)) = Windows.WAIT_OBJECT_0;
end;
{$ENDIF}

function ProtocolFrame(const AToken, AKind: string): string;
begin
  Result := AcknowledgementProtocol + ' ' + AToken + ' ' + AKind
    + LineEnding;
end;

function CancellationFrame(const AToken: string;
  const ADescendantDeadline, AAcknowledgementDeadline: QWord): string;
begin
  Result := AcknowledgementProtocol + ' ' + AToken + ' '
    + AcknowledgementCancel + ' ' + UIntToStr(ADescendantDeadline) + ' '
    + UIntToStr(AAcknowledgementDeadline) + LineEnding;
end;

function WriteProtocolFrame(const AHandle: PtrInt;
  const AFrame: string): Boolean;
{$IFDEF MSWINDOWS}
var
  BytesWritten: DWORD;
{$ENDIF}
begin
  if (AHandle < 0) or (AFrame = '') then Exit(False);
  {$IFDEF UNIX}
  Result := FpWrite(AHandle, AFrame[1], Length(AFrame)) = Length(AFrame);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  BytesWritten := 0;
  Result := Windows.WriteFile(THandle(AHandle), AFrame[1], Length(AFrame),
    BytesWritten, nil) and (BytesWritten = DWORD(Length(AFrame)));
  {$ENDIF}
end;

procedure CloseProtocolHandle(var AHandle: PtrInt);
begin
  if AHandle < 0 then Exit;
  {$IFDEF UNIX}
  FpClose(AHandle);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows.CloseHandle(THandle(AHandle));
  {$ENDIF}
  AHandle := -1;
end;

function NewChannelToken: string;
var
  ChannelID: TGUID;
begin
  if CreateGUID(ChannelID) <> 0 then
    raise EOSError.Create('could not create process-tree channel token');
  Result := GUIDToString(ChannelID);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

{$IFDEF UNIX}
function ProcessGroupExists(const AProcessGroupID: LongInt;
  out AErrorCode: Integer): Boolean; forward;
{$ENDIF}

function TryReadProtocolBytes(const AHandle: PtrInt;
  out ABytes: string): Boolean;
const
  ReadCapacity = 512;
{$IFDEF UNIX}
var
  Buffer: array[0..ReadCapacity - 1] of Byte;
  BytesRead: LongInt;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Available, BytesRead: DWORD;
  Buffer: array[0..ReadCapacity - 1] of Byte;
{$ENDIF}
begin
  Result := False;
  ABytes := '';
  if AHandle < 0 then Exit;
  {$IFDEF UNIX}
  BytesRead := FpRead(AHandle, Buffer, SizeOf(Buffer));
  if BytesRead <= 0 then Exit;
  SetLength(ABytes, BytesRead);
  Move(Buffer[0], ABytes[1], BytesRead);
  Result := True;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Available := 0;
  if not Windows.PeekNamedPipe(THandle(AHandle), nil, 0, nil,
    @Available, nil) then Exit;
  if Available = 0 then Exit;
  if Available > SizeOf(Buffer) then Available := SizeOf(Buffer);
  BytesRead := 0;
  if not Windows.ReadFile(THandle(AHandle), Buffer[0], Available,
    BytesRead, nil) or (BytesRead = 0) then Exit;
  SetLength(ABytes, BytesRead);
  Move(Buffer[0], ABytes[1], BytesRead);
  Result := True;
  {$ENDIF}
end;

function FeedProcessTreeProtocol(var ABuffer: string;
  const ABytes: string; out ALine: string): TLWPTProtocolReadResult;
var
  NewlinePosition: Integer;
begin
  ALine := '';
  ABuffer := ABuffer + ABytes;
  if Length(ABuffer) > ProtocolBufferCapacity then
  begin
    ABuffer := '';
    Exit(prrRejected);
  end;
  NewlinePosition := Pos(#10, ABuffer);
  if NewlinePosition = 0 then Exit(prrPending);
  ALine := Trim(Copy(ABuffer, 1, NewlinePosition - 1));
  Delete(ABuffer, 1, NewlinePosition);
  Result := prrFrame;
end;

function ReadProtocolLineBefore(const AHandle: PtrInt;
  const ADeadline: QWord; var ABuffer: string;
  out ALine: string): Boolean;
var
  Bytes: string;
  ReadResult: TLWPTProtocolReadResult;
begin
  ReadResult := FeedProcessTreeProtocol(ABuffer, '', ALine);
  if ReadResult <> prrPending then Exit(True);
  repeat
    if TryReadProtocolBytes(AHandle, Bytes) then
      ReadResult := FeedProcessTreeProtocol(ABuffer, Bytes, ALine)
    else
    begin
      Sleep(ProcessTreeTerminatePollMilliseconds);
      ReadResult := prrPending;
    end;
  until (ReadResult <> prrPending) or (GetTickCount64 >= ADeadline);
  Result := ReadResult <> prrPending;
end;

function ParseCancellationFrame(const ALine, AToken: string;
  out ADescendantDeadline, AAcknowledgementDeadline: QWord): Boolean;
var
  Fields: TStringList;
begin
  Result := False;
  ADescendantDeadline := 0;
  AAcknowledgementDeadline := 0;
  Fields := TStringList.Create;
  try
    Fields.Delimiter := ' ';
    Fields.StrictDelimiter := True;
    Fields.DelimitedText := ALine;
    if (Fields.Count <> 5)
       or (Fields[0] <> AcknowledgementProtocol)
       or (Fields[1] <> AToken)
       or (Fields[2] <> AcknowledgementCancel) then Exit;
    if not TryStrToQWord(Fields[3], ADescendantDeadline) then Exit;
    if not TryStrToQWord(Fields[4], AAcknowledgementDeadline) then Exit;
    Result := (ADescendantDeadline > 0)
      and (AAcknowledgementDeadline >= ADescendantDeadline);
  finally
    Fields.Free;
  end;
end;

procedure TLWPTProcessTree.CreateAcknowledgementChannels;
{$IFDEF UNIX}
var
  ControlPipe, StatusPipe: TFilDes;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ControlRead, ControlWrite, StatusRead, StatusWrite: THandle;
  SecurityAttributes: Windows.TSecurityAttributes;
{$ENDIF}
begin
  FStatusReadHandle := -1;
  FChildStatusWriteHandle := -1;
  FControlWriteHandle := -1;
  FChildControlReadHandle := -1;
  {$IFDEF UNIX}
  if FpPipe(StatusPipe) <> 0 then RaiseLastOSError;
  FStatusReadHandle := StatusPipe[0];
  FChildStatusWriteHandle := StatusPipe[1];
  try
    if FpPipe(ControlPipe) <> 0 then RaiseLastOSError;
    FChildControlReadHandle := ControlPipe[0];
    FControlWriteHandle := ControlPipe[1];
    if (FpFcntl(FStatusReadHandle, F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(FChildStatusWriteHandle, F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(FControlWriteHandle, F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(FChildControlReadHandle, F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(FStatusReadHandle, F_SetFl, O_NONBLOCK) < 0)
       or (FpFcntl(FControlWriteHandle, F_SetFl, O_NONBLOCK) < 0) then
      RaiseLastOSError;
  except
    CloseAcknowledgementChannels;
    raise;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FillChar(SecurityAttributes, SizeOf(SecurityAttributes), 0);
  SecurityAttributes.nLength := SizeOf(SecurityAttributes);
  SecurityAttributes.bInheritHandle := True;
  if not Windows.CreatePipe(StatusRead, StatusWrite, @SecurityAttributes,
    4096) then RaiseLastOSError;
  FStatusReadHandle := PtrInt(StatusRead);
  FChildStatusWriteHandle := PtrInt(StatusWrite);
  try
    if not Windows.CreatePipe(ControlRead, ControlWrite,
      @SecurityAttributes, 4096) then RaiseLastOSError;
    FChildControlReadHandle := PtrInt(ControlRead);
    FControlWriteHandle := PtrInt(ControlWrite);
    if not Windows.SetHandleInformation(StatusRead,
      Windows.HANDLE_FLAG_INHERIT, 0)
       or not Windows.SetHandleInformation(ControlWrite,
      Windows.HANDLE_FLAG_INHERIT, 0) then RaiseLastOSError;
  except
    CloseAcknowledgementChannels;
    raise;
  end;
  {$ENDIF}
end;

procedure TLWPTProcessTree.CloseChildAcknowledgementHandles;
begin
  CloseProtocolHandle(FChildStatusWriteHandle);
  CloseProtocolHandle(FChildControlReadHandle);
end;

procedure TLWPTProcessTree.CloseAcknowledgementChannels;
begin
  CloseProtocolHandle(FStatusReadHandle);
  CloseProtocolHandle(FChildStatusWriteHandle);
  CloseProtocolHandle(FControlWriteHandle);
  CloseProtocolHandle(FChildControlReadHandle);
end;

procedure TLWPTProcessTree.RegisterActive;
begin
  EnterCriticalSection(ActiveProcessTreesCriticalSection);
  try
    if FRegistered then Exit;
    ActiveProcessTrees.Add(Self);
    FRegistered := True;
  finally
    LeaveCriticalSection(ActiveProcessTreesCriticalSection);
  end;
end;

procedure TLWPTProcessTree.UnregisterActive;
begin
  EnterCriticalSection(ActiveProcessTreesCriticalSection);
  try
    if not FRegistered then Exit;
    ActiveProcessTrees.Remove(Self);
    FRegistered := False;
  finally
    LeaveCriticalSection(ActiveProcessTreesCriticalSection);
  end;
end;

constructor TLWPTProcessTree.Create(const AProcess: TProcess);
begin
  inherited Create;
  FProcess := nil;
  FStatusReadHandle := -1;
  FChildStatusWriteHandle := -1;
  FControlWriteHandle := -1;
  FChildControlReadHandle := -1;
  FCriticalSectionInitialized := False;
  if not Assigned(AProcess) then
    raise EArgumentNilException.Create('process');
  FProcess := AProcess;
  FChannelToken := NewChannelToken;
  InitCriticalSection(FTerminationCriticalSection);
  FCriticalSectionInitialized := True;
  FRegistered := False;
  FImmediateTerminationRequested := 0;
  FAcknowledgementRegistered := False;
  FAcknowledgementFinished := False;
  FAcknowledgementSucceeded := False;
  FCancellationStarted := False;
  FCancellationAcknowledgementRequired := False;
  FCancellationAcknowledgementDeadline := 0;
  {$IFDEF UNIX}
  FProcess.OnForkEvent := HandleFork;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FWindowsState := TWindowsState.Create;
  { Windows 8+ permits the suspended child to join this inner job while
    retaining inherited membership in an enclosing LWPT or host job. }
  FProcess.InheritHandles := True;
  FProcess.Options := FProcess.Options + [poRunSuspended];
  {$ENDIF}
end;

function EnvironmentEntryName(const AEntry: string): string;
var
  Separator: Integer;
begin
  Separator := Pos('=', AEntry);
  if Separator = 0 then Result := AEntry
  else Result := Copy(AEntry, 1, Separator - 1);
end;

function EnvironmentNamesEqual(const ALeft, ARight: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ALeft, ARight);
  {$ELSE}
  Result := ALeft = ARight;
  {$ENDIF}
end;

procedure SetProcessEnvironmentEntry(const AEnvironment: TStrings;
  const AName, AValue: string);
var
  EnvironmentIndex: Integer;
begin
  for EnvironmentIndex := AEnvironment.Count - 1 downto 0 do
    if EnvironmentNamesEqual(
      EnvironmentEntryName(AEnvironment[EnvironmentIndex]), AName) then
      AEnvironment.Delete(EnvironmentIndex);
  AEnvironment.Add(AName + '=' + AValue);
end;

procedure TLWPTProcessTree.MarkManagedChild;
begin
  { AppendProcessEnvironment, not a direct sweep: concurrent job threads
    materialising here raced the RTL's unsynchronised lazy env count and
    could truncate a child's environment (see LWPT.Core). }
  if FProcess.Environment.Count = 0 then
    AppendProcessEnvironment(FProcess.Environment);
  SetProcessEnvironmentEntry(FProcess.Environment,
    ManagedProcessTreeEnvironment, IntToStr(GetProcessID));
  SetProcessEnvironmentEntry(FProcess.Environment,
    StatusHandleEnvironment, IntToStr(FChildStatusWriteHandle));
  SetProcessEnvironmentEntry(FProcess.Environment,
    ControlHandleEnvironment, IntToStr(FChildControlReadHandle));
  SetProcessEnvironmentEntry(FProcess.Environment,
    ChannelTokenEnvironment, FChannelToken);
end;

destructor TLWPTProcessTree.Destroy;
begin
  UnregisterActive;
  CloseAcknowledgementChannels;
  {$IFDEF UNIX}
  if Assigned(FProcess) then FProcess.OnForkEvent := nil;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FreeAndNil(FWindowsState);
  {$ENDIF}
  if FCriticalSectionInitialized then
  begin
    DoneCriticalSection(FTerminationCriticalSection);
    FCriticalSectionInitialized := False;
  end;
  inherited Destroy;
end;

{$IFDEF UNIX}
procedure TLWPTProcessTree.HandleFork(ASender: TObject);
begin
  { A forked child resets the forwarding handlers before exec. setpgid(2)
    signal(3), and fcntl(2) are async-signal-safe in this post-fork path. Only
    this tree's child channel ends may survive exec; every unrelated process
    inherits them as close-on-exec. }
  if (CSetProcessGroup(0, 0) = 0)
     and (FpFcntl(FChildStatusWriteHandle, F_SetFD, 0) = 0)
     and (FpFcntl(FChildControlReadHandle, F_SetFD, 0) = 0)
     and not SignalHandlerFailed(CSignal(SIGTERM, nil))
     and not SignalHandlerFailed(CSignal(SIGINT, nil))
     and not SignalHandlerFailed(CSignal(SIGPIPE, nil)) then Exit;
  FpWrite(StdErrorHandle, ProcessGroupSetupError[1],
    Length(ProcessGroupSetupError));
  FpExit(ProcessTreeSetupExitCode);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure TLWPTProcessTree.TerminateCreatedProcess;
var
  ErrorCode: DWORD;
begin
  if not Windows.TerminateProcess(FProcess.ProcessHandle,
    ProcessTreeSetupExitCode) then
  begin
    ErrorCode := Windows.GetLastError;
    if Windows.WaitForSingleObject(FProcess.ProcessHandle, 0)
      <> Windows.WAIT_OBJECT_0 then
      raise EOSError.CreateFmt('could not terminate isolated process: %s',
        [SysErrorMessage(ErrorCode)]);
  end;
  Windows.WaitForSingleObject(FProcess.ProcessHandle, Windows.INFINITE);
end;
{$ENDIF}

procedure ExecuteUnmanagedProcess(const AProcess: TProcess);
begin
  if not Assigned(AProcess) then
    raise EArgumentNilException.Create('process');
  { Windows TProcess can only inherit all inheritable handles. Raw production
    spawns therefore share the managed-spawn window; Unix also participates as
    defence in depth alongside close-on-exec acknowledgement descriptors. }
  EnterCriticalSection(ProcessSpawnCriticalSection);
  try
    AProcess.Execute;
  finally
    LeaveCriticalSection(ProcessSpawnCriticalSection);
  end;
end;

procedure TLWPTProcessTree.Execute;
{$IFDEF UNIX}
var
  ErrorCode: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
  ErrorSuffix: string;
{$ENDIF}
begin
  { Registration precedes the spawn. The termination lock then makes a signal
    arriving during Execute wait until the new group/job is fully addressable.
    Channel creation through child-handle closure is process-serialised because
    FPC cannot restrict inheritance to an explicit descriptor/handle list. }
  EnterCriticalSection(ProcessSpawnCriticalSection);
  try
    CreateAcknowledgementChannels;
    try
      MarkManagedChild;
      RegisterActive;
      try
        EnterCriticalSection(FTerminationCriticalSection);
        try
          {$IFDEF MSWINDOWS}
          { Keep assignment-before-resume an Execute-time invariant even when
            a caller configures additional TProcess options after construction. }
          FProcess.Options := FProcess.Options + [poRunSuspended];
          {$ENDIF}
          FProcess.Execute;
          CloseChildAcknowledgementHandles;
          {$IFDEF UNIX}
          { Close the parent/child race: either this call creates the group, or
            EACCES proves the child has passed the pre-exec fork handler. }
          if CSetProcessGroup(FProcess.ProcessID, FProcess.ProcessID) <> 0 then
          begin
            { CSetProcessGroup is a libc call: read libc's errno, not
              FpGetErrNo, or the benign post-exec EACCES race reads as a
              stale unrelated code and kills a healthy child. }
            ErrorCode := CErrnoLocation()^;
            if not (ErrorCode in [ESysEACCES, ESysESRCH]) then
            begin
              FProcess.Terminate(ProcessTreeSetupExitCode);
              FProcess.WaitOnExit;
              raise EOSError.CreateFmt('could not isolate process tree: %s',
                [SysErrorMessage(ErrorCode)]);
            end;
          end;
          {$ENDIF}
          {$IFDEF MSWINDOWS}
          if not FWindowsState.TryAssignProcess(FProcess.ProcessHandle,
            ErrorCode) then
          begin
            TerminateCreatedProcess;
            ErrorSuffix := '';
            if ErrorCode = Windows.ERROR_ACCESS_DENIED then
              ErrorSuffix := NestedJobRequirement;
            raise EOSError.CreateFmt(
              'could not assign process to Job Object: %s%s',
              [SysErrorMessage(ErrorCode), ErrorSuffix]);
          end;
          if Windows.ResumeThread(FProcess.ThreadHandle) = DWORD(-1) then
          begin
            ErrorCode := Windows.GetLastError;
            TerminateCreatedProcess;
            raise EOSError.CreateFmt('could not resume isolated process: %s',
              [SysErrorMessage(ErrorCode)]);
          end;
          {$ENDIF}
        finally
          LeaveCriticalSection(FTerminationCriticalSection);
        end;
      except
        CloseChildAcknowledgementHandles;
        UnregisterActive;
        raise;
      end;
    except
      if not FRegistered then
      begin
        CloseAcknowledgementChannels;
        raise;
      end;
      raise;
    end;
  finally
    LeaveCriticalSection(ProcessSpawnCriticalSection);
  end;
end;

procedure TLWPTProcessTree.DrainAcknowledgementFrames;
var
  Bytes, ExpectedPrefix, FrameKind, Line: string;
  NewlinePosition, ReadCount: Integer;
begin
  ReadCount := 0;
  while (ReadCount < 8)
    and TryReadProtocolBytes(FStatusReadHandle, Bytes) do
  begin
    FStatusBuffer := FStatusBuffer + Bytes;
    Inc(ReadCount);
  end;
  if Length(FStatusBuffer) > ProtocolBufferCapacity then
    Delete(FStatusBuffer, 1,
      Length(FStatusBuffer) - ProtocolBufferCapacity);
  ExpectedPrefix := AcknowledgementProtocol + ' ' + FChannelToken + ' ';
  NewlinePosition := Pos(#10, FStatusBuffer);
  while NewlinePosition > 0 do
  begin
    Line := Trim(Copy(FStatusBuffer, 1, NewlinePosition - 1));
    Delete(FStatusBuffer, 1, NewlinePosition);
    if Copy(Line, 1, Length(ExpectedPrefix)) = ExpectedPrefix then
    begin
      FrameKind := Copy(Line, Length(ExpectedPrefix) + 1, MaxInt);
      if FrameKind = AcknowledgementHello then
        FAcknowledgementRegistered := True
      else if FAcknowledgementRegistered
        and (FrameKind = AcknowledgementReaped) then
      begin
        FAcknowledgementFinished := True;
        FAcknowledgementSucceeded := True;
      end
      else if FAcknowledgementRegistered
        and (FrameKind = AcknowledgementFailed) then
      begin
        FAcknowledgementFinished := True;
        FAcknowledgementSucceeded := False;
      end;
    end;
    NewlinePosition := Pos(#10, FStatusBuffer);
  end;
end;

function TLWPTProcessTree.SendCancellationFrame(
  const ADescendantDeadline, AAcknowledgementDeadline: QWord): Boolean;
begin
  if FCancellationStarted then
  begin
    if (FCancellationAcknowledgementDeadline = 0)
       or (AAcknowledgementDeadline
         < FCancellationAcknowledgementDeadline) then
      FCancellationAcknowledgementDeadline := AAcknowledgementDeadline;
    Exit(False);
  end;
  FCancellationStarted := True;
  { Registration is a property of this cancellation transaction. A HELLO that
    races in after Begin must not turn an already hard-killed arbitrary child
    into an ACK-gated child that never received CANCEL. }
  FCancellationAcknowledgementRequired := FAcknowledgementRegistered;
  FCancellationAcknowledgementDeadline := AAcknowledgementDeadline;
  FAcknowledgementFinished := False;
  FAcknowledgementSucceeded := False;
  if FCancellationAcknowledgementRequired
     and not WriteProtocolFrame(FControlWriteHandle,
    CancellationFrame(FChannelToken, ADescendantDeadline,
      AAcknowledgementDeadline)) then
  begin
    FAcknowledgementFinished := True;
    FAcknowledgementSucceeded := False;
  end;
  Result := True;
end;

function TLWPTProcessTree.HasActiveOwnedProcesses: Boolean;
{$IFDEF UNIX}
var
  ErrorCode, ProcessGroupID: Integer;
{$ENDIF}
begin
  {$IFDEF UNIX}
  ProcessGroupID := FProcess.ProcessID;
  Result := (ProcessGroupID > 0)
    and ProcessGroupExists(ProcessGroupID, ErrorCode);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := Assigned(FWindowsState) and FWindowsState.HasActiveProcesses;
  {$ENDIF}
end;

procedure TLWPTProcessTree.BeginForwardedTermination(
  const ADescendantDeadline, AAcknowledgementDeadline: QWord);
{$IFDEF UNIX}
var
  ErrorCode, ProcessGroupID: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
{$ENDIF}
begin
  InterlockedExchange(FImmediateTerminationRequested, 1);
  EnterCriticalSection(FTerminationCriticalSection);
  try
    if not FCancellationStarted and not HasActiveOwnedProcesses then Exit;
    DrainAcknowledgementFrames;
    if not SendCancellationFrame(ADescendantDeadline,
      AAcknowledgementDeadline) then Exit;
    {$IFDEF UNIX}
    ProcessGroupID := FProcess.ProcessID;
    if ProcessGroupID <= 0 then Exit;
    if FCancellationAcknowledgementRequired then
    begin
      if FpKill(-ProcessGroupID, SIGTERM) = 0 then Exit;
    end
    else if FpKill(-ProcessGroupID, SIGKILL) = 0 then Exit;
    ErrorCode := FpGetErrNo;
    if ErrorCode = ESysESRCH then Exit;
    TryTerminateDirectChild;
    raise EOSError.CreateFmt('could not signal process tree: %s',
      [SysErrorMessage(ErrorCode)]);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    if not Assigned(FWindowsState) then Exit;
    if not FWindowsState.HasActiveProcesses then Exit;
    if FCancellationAcknowledgementRequired then Exit;
    if not FWindowsState.TryTerminate(ProcessTreeCancellationExitCode,
      ErrorCode) then
    begin
      if not FWindowsState.HasActiveProcesses then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not terminate process Job Object: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
end;

procedure TLWPTProcessTree.WaitForForwardedTermination(
  const ADeadline, AFinalReapDeadline: QWord);
var
  AcknowledgementDeadline: QWord;
  AcknowledgementFailure: string;
  AcknowledgementFinished, AcknowledgementRegistered,
    AcknowledgementSucceeded: Boolean;
  EffectiveDeadline: QWord;
{$IFDEF UNIX}
  ErrorCode, ProcessGroupID: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
  ErrorCode: DWORD;
  State: TWindowsState;
{$ENDIF}
begin
  AcknowledgementFailure := '';
  EffectiveDeadline := ADeadline;
  EnterCriticalSection(FTerminationCriticalSection);
  try
    DrainAcknowledgementFrames;
    AcknowledgementRegistered := FCancellationAcknowledgementRequired;
    AcknowledgementFinished := FAcknowledgementFinished;
    AcknowledgementSucceeded := FAcknowledgementSucceeded;
    AcknowledgementDeadline := FCancellationAcknowledgementDeadline;
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  if AcknowledgementRegistered then
  begin
    while (not AcknowledgementFinished)
      and (GetTickCount64 < AcknowledgementDeadline) do
    begin
      Sleep(ProcessTreeTerminatePollMilliseconds);
      EnterCriticalSection(FTerminationCriticalSection);
      try
        DrainAcknowledgementFrames;
        AcknowledgementFinished := FAcknowledgementFinished;
        AcknowledgementSucceeded := FAcknowledgementSucceeded;
        AcknowledgementDeadline := FCancellationAcknowledgementDeadline;
      finally
        LeaveCriticalSection(FTerminationCriticalSection);
      end;
    end;
    if not AcknowledgementFinished then
      AcknowledgementFailure :=
        'nested process termination acknowledgement was not received'
    else if not AcknowledgementSucceeded then
      AcknowledgementFailure :=
        'nested process reported failed process-tree termination';
    EffectiveDeadline := AFinalReapDeadline;
    if AcknowledgementFailure <> '' then
    begin
      EnterCriticalSection(FTerminationCriticalSection);
      try
        {$IFDEF UNIX}
        ProcessGroupID := FProcess.ProcessID;
        if (ProcessGroupID > 0) and (FpKill(-ProcessGroupID, SIGKILL) <> 0)
           and (FpGetErrNo <> ESysESRCH) then
          TryTerminateDirectChild;
        {$ENDIF}
        {$IFDEF MSWINDOWS}
        State := FWindowsState;
        if Assigned(State) and State.HasActiveProcesses
           and not State.TryTerminate(ProcessTreeCancellationExitCode,
             ErrorCode) then
          TryTerminateDirectChild;
        {$ENDIF}
      finally
        LeaveCriticalSection(FTerminationCriticalSection);
      end;
    end;
  end;
  EnterCriticalSection(FTerminationCriticalSection);
  try
    {$IFDEF UNIX}
    ProcessGroupID := FProcess.ProcessID;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    State := FWindowsState;
    {$ENDIF}
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  {$IFDEF UNIX}
  if ProcessGroupID <= 0 then Exit;
  while ProcessGroupExists(ProcessGroupID, ErrorCode)
    and (GetTickCount64 < EffectiveDeadline) do
    Sleep(ProcessTreeTerminatePollMilliseconds);
  if ProcessGroupExists(ProcessGroupID, ErrorCode) then
  begin
    TryTerminateDirectChild;
    raise EOSError.CreateFmt(
      'process group %d still had members after forwarded termination',
      [ProcessGroupID]);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not Assigned(State) then Exit;
  if not State.WaitUntilEmptyBefore(EffectiveDeadline) then
  begin
    TryTerminateDirectChild;
    raise EOSError.Create(
      'process Job Object still had active processes after forwarded termination');
  end;
  { ActiveProcesses reaching zero is membership evidence, not a completion
    barrier for the direct child's process object. Wait for the process handle
    too, so callers cannot observe STILL_ACTIVE or retained file handles after
    the forwarding process exits. }
  if not ProcessExitedBefore(FProcess.ProcessHandle, EffectiveDeadline) then
  begin
    TryTerminateDirectChild;
    raise EOSError.Create(
      'direct child was still active after forwarded Job Object termination');
  end;
  {$ENDIF}
  if AcknowledgementFailure <> '' then
    raise EOSError.Create(AcknowledgementFailure);
end;

procedure TLWPTProcessTree.TryTerminateDirectChild;
begin
  if (not Assigned(FProcess)) or (FProcess.ProcessID <= 0) then Exit;
  {$IFDEF UNIX}
  FpKill(FProcess.ProcessID, SIGKILL);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows.TerminateProcess(FProcess.ProcessHandle,
    ProcessTreeCancellationExitCode);
  {$ENDIF}
end;

{$IFDEF UNIX}
function ProcessGroupExists(const AProcessGroupID: LongInt;
  out AErrorCode: Integer): Boolean;
begin
  AErrorCode := 0;
  if FpKill(-AProcessGroupID, 0) = 0 then Exit(True);
  AErrorCode := FpGetErrNo;
  if AErrorCode = ESysEPERM then Exit(True);
  if AErrorCode = ESysESRCH then Exit(False);
  raise EOSError.CreateFmt('could not inspect process tree: %s',
    [SysErrorMessage(AErrorCode)]);
end;

procedure WaitForProcessGroupEmpty(const AProcessGroupID: LongInt;
  const ATimeoutMilliseconds: Integer);
var
  ErrorCode, WaitedMilliseconds: Integer;
begin
  WaitedMilliseconds := 0;
  while ProcessGroupExists(AProcessGroupID, ErrorCode)
    and (WaitedMilliseconds < ATimeoutMilliseconds) do
  begin
    Sleep(ProcessTreeTerminatePollMilliseconds);
    Inc(WaitedMilliseconds, ProcessTreeTerminatePollMilliseconds);
  end;
  if ProcessGroupExists(AProcessGroupID, ErrorCode) then
    raise EOSError.CreateFmt(
      'process group %d still had members after termination',
      [AProcessGroupID]);
end;
{$ENDIF}

class procedure TLWPTProcessTree.NewTerminationDeadlines(
  out ADescendantDeadline, AAcknowledgementDeadline: QWord);
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  ADescendantDeadline := StartedAt + ForwardedReapTimeoutMilliseconds;
  AAcknowledgementDeadline := StartedAt
    + ProcessTreeTerminateGraceMilliseconds;
end;

procedure TLWPTProcessTree.BeginTermination(const ADescendantDeadline,
  AAcknowledgementDeadline: QWord);
{$IFDEF UNIX}
var
  ErrorCode, ProcessGroupID: Integer;
  ImmediateTermination: Boolean;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
{$ENDIF}
begin
  EnterCriticalSection(FTerminationCriticalSection);
  try
    if not FCancellationStarted and not HasActiveOwnedProcesses then Exit;
    DrainAcknowledgementFrames;
    if not SendCancellationFrame(ADescendantDeadline,
      AAcknowledgementDeadline) then Exit;
    {$IFDEF UNIX}
    ProcessGroupID := FProcess.ProcessID;
    if ProcessGroupID <= 0 then Exit;
    ImmediateTermination := FImmediateTerminationRequested <> 0;
    if (not ImmediateTermination)
       and (FpKill(-ProcessGroupID, SIGTERM) <> 0) then
    begin
      ErrorCode := FpGetErrNo;
      if ErrorCode = ESysESRCH then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not terminate process tree: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    if not Assigned(FWindowsState) then Exit;
    if not FWindowsState.HasActiveProcesses then Exit;
    if (not FCancellationAcknowledgementRequired)
       and not FWindowsState.TryTerminate(ProcessTreeCancellationExitCode,
         ErrorCode) then
    begin
      if not FWindowsState.HasActiveProcesses then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not terminate process Job Object: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    {$ENDIF}
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
end;

procedure TLWPTProcessTree.CompleteTermination;
var
  AcknowledgementDeadline, FinalReapDeadline: QWord;
  AcknowledgementRegistered: Boolean;
{$IFDEF UNIX}
  ErrorCode, ProcessGroupID, ReapTimeoutMilliseconds,
    WaitedMilliseconds: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
  ReapDeadline: QWord;
{$ENDIF}
begin
  EnterCriticalSection(FTerminationCriticalSection);
  try
    AcknowledgementRegistered := FCancellationAcknowledgementRequired;
    AcknowledgementDeadline := FCancellationAcknowledgementDeadline;
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  if AcknowledgementRegistered then
  begin
    FinalReapDeadline := AcknowledgementDeadline
      + ProcessTreeReapTimeoutMilliseconds;
    WaitForForwardedTermination(AcknowledgementDeadline,
      FinalReapDeadline);
    Exit;
  end;
  {$IFDEF UNIX}
  ProcessGroupID := FProcess.ProcessID;
  if ProcessGroupID <= 0 then Exit;
  WaitedMilliseconds := 0;
  while (FImmediateTerminationRequested = 0)
    and ProcessGroupExists(ProcessGroupID, ErrorCode)
    and (WaitedMilliseconds < ProcessTreeTerminateGraceMilliseconds) do
  begin
    Sleep(ProcessTreeTerminatePollMilliseconds);
    Inc(WaitedMilliseconds, ProcessTreeTerminatePollMilliseconds);
  end;
  if not ProcessGroupExists(ProcessGroupID, ErrorCode) then Exit;

  EnterCriticalSection(FTerminationCriticalSection);
  try
    if FpKill(-ProcessGroupID, SIGKILL) <> 0 then
    begin
      ErrorCode := FpGetErrNo;
      if ErrorCode = ESysESRCH then Exit;
      TryTerminateDirectChild;
      raise EOSError.CreateFmt('could not kill process tree: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
  finally
    LeaveCriticalSection(FTerminationCriticalSection);
  end;
  ReapTimeoutMilliseconds := ProcessTreeReapTimeoutMilliseconds;
  if FImmediateTerminationRequested <> 0 then
    ReapTimeoutMilliseconds := ForwardedReapTimeoutMilliseconds;
  try
    WaitForProcessGroupEmpty(ProcessGroupID, ReapTimeoutMilliseconds);
  except
    TryTerminateDirectChild;
    raise;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ReapDeadline := GetTickCount64 + ProcessTreeReapTimeoutMilliseconds;
  if not FWindowsState.WaitUntilEmptyBefore(ReapDeadline) then
  begin
    TryTerminateDirectChild;
    raise EOSError.Create(
      'process Job Object still had active processes after termination');
  end;
  if not ProcessExitedBefore(FProcess.ProcessHandle, ReapDeadline) then
  begin
    TryTerminateDirectChild;
    raise EOSError.Create(
      'direct child was still active after Job Object termination');
  end;
  {$ENDIF}
end;

procedure TLWPTProcessTree.Terminate;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
begin
  NewTerminationDeadlines(DescendantDeadline, AcknowledgementDeadline);
  BeginTermination(DescendantDeadline, AcknowledgementDeadline);
  CompleteTermination;
end;

procedure TerminateRegisteredProcessTrees(const AImmediate: Boolean;
  const AInheritedDescendantDeadline: QWord = 0;
  const AInheritedAcknowledgementDeadline: QWord = 0);
var
  AcknowledgementDeadline, DescendantDeadline, FinalReapDeadline: QWord;
  FirstFailure: string;
  Index: Integer;

  procedure RecordFailure(const AMessage: string);
  begin
    if FirstFailure = '' then FirstFailure := AMessage;
  end;
begin
  FirstFailure := '';
  { This runs on a dedicated forwarding thread, not in an async Unix handler.
    Holding the registry lock pins each object until bounded termination ends.
    Forwarded teardown kills every tree before polling any one of them, and all
    polls share one deadline shorter than the ancestor's graceful window. }
  EnterCriticalSection(ActiveProcessTreesCriticalSection);
  try
    if AImmediate then
    begin
      DescendantDeadline := AInheritedDescendantDeadline;
      if DescendantDeadline = 0 then
        DescendantDeadline := GetTickCount64
          + ForwardedReapTimeoutMilliseconds;
      AcknowledgementDeadline := AInheritedAcknowledgementDeadline;
      if AcknowledgementDeadline = 0 then
        AcknowledgementDeadline := GetTickCount64
          + ProcessTreeTerminateGraceMilliseconds;
      for Index := 0 to ActiveProcessTrees.Count - 1 do
        try
          TLWPTProcessTree(ActiveProcessTrees[Index])
            .BeginForwardedTermination(DescendantDeadline,
              AcknowledgementDeadline);
        except
          on E: Exception do RecordFailure(E.Message);
        end;
      FinalReapDeadline := AcknowledgementDeadline
        + ProcessTreeReapTimeoutMilliseconds;
      for Index := 0 to ActiveProcessTrees.Count - 1 do
        try
          TLWPTProcessTree(ActiveProcessTrees[Index])
            .WaitForForwardedTermination(DescendantDeadline,
              FinalReapDeadline);
        except
          on E: Exception do RecordFailure(E.Message);
        end;
    end
    else
      for Index := 0 to ActiveProcessTrees.Count - 1 do
        try
          TLWPTProcessTree(ActiveProcessTrees[Index]).Terminate;
        except
          on E: Exception do RecordFailure(E.Message);
        end;
  finally
    LeaveCriticalSection(ActiveProcessTreesCriticalSection);
  end;
  if FirstFailure <> '' then
    raise EOSError.Create(FirstFailure);
end;

procedure ReportForwardingFailure(const AMessage: string);
var
  OutputLine: string;
{$IFDEF MSWINDOWS}
  BytesWritten: DWORD;
  StandardError: THandle;
{$ENDIF}
begin
  {$IFDEF UNIX}
  OutputLine := 'process-tree signal forwarding failed: ' + AMessage
    + LineEnding;
  FpWrite(StdErrorHandle, OutputLine[1], Length(OutputLine));
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  OutputLine := 'process-tree console-control forwarding failed: '
    + AMessage + LineEnding;
  StandardError := Windows.GetStdHandle(Windows.STD_ERROR_HANDLE);
  if (StandardError <> 0)
     and (StandardError <> Windows.INVALID_HANDLE_VALUE) then
  begin
    BytesWritten := 0;
    Windows.WriteFile(StandardError, OutputLine[1], Length(OutputLine),
      BytesWritten, nil);
  end;
  {$ENDIF}
end;

function ValidChannelToken(const AToken: string): Boolean;
var
  CharacterIndex: Integer;
begin
  Result := Length(AToken) = 32;
  if not Result then Exit;
  for CharacterIndex := 1 to Length(AToken) do
    if not (AToken[CharacterIndex] in ['0'..'9', 'A'..'F', 'a'..'f']) then
      Exit(False);
end;

procedure ClearInheritedAcknowledgementChannel;
begin
  InheritedStatusWriteHandle := -1;
  InheritedControlReadHandle := -1;
  InheritedChannelToken := '';
  InheritedControlBuffer := '';
  InheritedManagedProcessTree := False;
end;

function CurrentParentProcessID: QWord;
{$IFDEF MSWINDOWS}
var
  Attempt: Integer;
  Entry: TLWPTProcessEntry32W;
  Snapshot: THandle;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := QWord(FpGetppid);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := 0;
  Snapshot := Windows.INVALID_HANDLE_VALUE;
  for Attempt := 1 to ToolhelpSnapshotAttempts do
  begin
    Snapshot := LWPTCreateToolhelp32Snapshot(ToolhelpSnapshotProcesses, 0);
    if Snapshot <> Windows.INVALID_HANDLE_VALUE then Break;
    if Windows.GetLastError <> Windows.ERROR_BAD_LENGTH then Exit;
    Sleep(ProcessTreeTerminatePollMilliseconds);
  end;
  if Snapshot = Windows.INVALID_HANDLE_VALUE then Exit;
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.Size := SizeOf(Entry);
    if not LWPTProcess32FirstW(Snapshot, Entry) then Exit;
    repeat
      if Entry.ProcessID = Windows.GetCurrentProcessId then
        Exit(Entry.ParentProcessID);
    until not LWPTProcess32NextW(Snapshot, Entry);
  finally
    Windows.CloseHandle(Snapshot);
  end;
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
function ValidInheritedPipeHandle(const AHandle: PtrInt;
  const ARequiredAccess: DWORD): Boolean;
var
  Duplicate: THandle;
  HandleFlags: DWORD;
  PipeFlags: DWORD;
begin
  Duplicate := 0;
  if not Windows.GetHandleInformation(THandle(AHandle), @HandleFlags) then
    Exit(False);
  if (HandleFlags and Windows.HANDLE_FLAG_INHERIT) = 0 then Exit(False);
  if not Windows.GetNamedPipeInfo(THandle(AHandle), @PipeFlags, nil, nil,
    nil) then
    Exit(False);
  if (PipeFlags and Windows.PIPE_TYPE_MESSAGE) <> 0 then Exit(False);
  { Narrow file-data access cannot be added when duplicating a handle. This
    metadata-only probe stays bounded while distinguishing the status write
    end from the control read end. }
  if not Windows.DuplicateHandle(Windows.GetCurrentProcess, THandle(AHandle),
    Windows.GetCurrentProcess, @Duplicate, ARequiredAccess, False, 0) then
    Exit(False);
  Windows.CloseHandle(Duplicate);
  Result := True;
end;
{$ENDIF}

{$IFDEF UNIX}
function ValidInheritedPipeHandle(const AHandle: PtrInt;
  const ARequiredAccess: LongInt; out AOpenFlags: LongInt): Boolean;
const
  OpenAccessModeMask = O_WrOnly or O_RdWr;
var
  AccessMode: LongInt;
  FileStatus: Stat;
begin
  AOpenFlags := FpFcntl(AHandle, F_GetFl);
  if AOpenFlags < 0 then
    Exit(False);
  AccessMode := AOpenFlags and OpenAccessModeMask;
  if (AccessMode <> ARequiredAccess) and (AccessMode <> O_RdWr) then
    Exit(False);
  Result := (FpFStat(AHandle, FileStatus) = 0)
    and FpS_ISFIFO(FileStatus.st_mode);
end;
{$ENDIF}

procedure LoadInheritedAcknowledgementChannel;
var
  ManagedParentProcessID: QWord;
  ParsedHandle: Int64;
  {$IFDEF UNIX}
  ControlOpenFlags, StatusOpenFlags: LongInt;
  {$ENDIF}
begin
  ClearInheritedAcknowledgementChannel;
  if not TryStrToQWord(SysUtils.GetEnvironmentVariable(
    ManagedProcessTreeEnvironment), ManagedParentProcessID)
     or (ManagedParentProcessID = 0)
     or (ManagedParentProcessID <> CurrentParentProcessID) then Exit;
  InheritedChannelToken := SysUtils.GetEnvironmentVariable(
    ChannelTokenEnvironment);
  if not ValidChannelToken(InheritedChannelToken) then
  begin
    ClearInheritedAcknowledgementChannel;
    Exit;
  end;
  if not TryStrToInt64(SysUtils.GetEnvironmentVariable(
    StatusHandleEnvironment), ParsedHandle) or (ParsedHandle < 0) then
  begin
    ClearInheritedAcknowledgementChannel;
    Exit;
  end;
  InheritedStatusWriteHandle := PtrInt(ParsedHandle);
  if not TryStrToInt64(SysUtils.GetEnvironmentVariable(
    ControlHandleEnvironment), ParsedHandle) or (ParsedHandle < 0) then
  begin
    ClearInheritedAcknowledgementChannel;
    Exit;
  end;
  InheritedControlReadHandle := PtrInt(ParsedHandle);
  {$IFDEF MSWINDOWS}
  { Environment strings outlive inherited handles when an intermediate
    process forwards its environment without the matching channel. Require
    inheritable pipe handles with the exact access direction before suppressing
    this process's own console handler. }
  if not ValidInheritedPipeHandle(InheritedStatusWriteHandle,
       Windows.FILE_WRITE_DATA)
     or not ValidInheritedPipeHandle(InheritedControlReadHandle,
       Windows.FILE_READ_DATA) then
    ClearInheritedAcknowledgementChannel;
  {$ENDIF}
  {$IFDEF UNIX}
  if not ValidInheritedPipeHandle(InheritedStatusWriteHandle, O_WrOnly,
       StatusOpenFlags)
     or not ValidInheritedPipeHandle(InheritedControlReadHandle, O_RdOnly,
       ControlOpenFlags)
     or (FpFcntl(InheritedControlReadHandle, F_SetFl,
       ControlOpenFlags or O_NONBLOCK) < 0) then
    ClearInheritedAcknowledgementChannel;
  {$ENDIF}
  InheritedManagedProcessTree := InheritedControlReadHandle >= 0;
end;

function SendInheritedAcknowledgement(const AKind: string): Boolean;
begin
  Result := (InheritedStatusWriteHandle >= 0)
    and WriteProtocolFrame(InheritedStatusWriteHandle,
      ProtocolFrame(InheritedChannelToken, AKind));
end;

procedure IncomingCancellationDeadlines(out ADescendantDeadline,
  AAcknowledgementDeadline: QWord);
var
  CancellationLine: string;
  ParsedAcknowledgementDeadline, ParsedDescendantDeadline: QWord;
begin
  ADescendantDeadline := GetTickCount64
    + ForwardedReapTimeoutMilliseconds;
  AAcknowledgementDeadline := GetTickCount64
    + ProcessTreeTerminateGraceMilliseconds;
  if (InheritedControlReadHandle >= 0)
     and ReadProtocolLineBefore(InheritedControlReadHandle,
       GetTickCount64 + ProcessTreeTerminatePollMilliseconds,
       InheritedControlBuffer, CancellationLine) then
    if ParseCancellationFrame(CancellationLine, InheritedChannelToken,
      ParsedDescendantDeadline, ParsedAcknowledgementDeadline) then
    begin
      ADescendantDeadline := ParsedDescendantDeadline;
      AAcknowledgementDeadline := ParsedAcknowledgementDeadline;
    end;
end;

{$IFDEF UNIX}
procedure TLWPTSignalForwarder.Execute;
var
  BytesRead, ReceivedSignal: LongInt;
  AcknowledgementDeadline, DescendantDeadline: QWord;
  SignalSet: sigset_t;
begin
  repeat
    BytesRead := FpRead(SignalPipe[SignalPipeReadEnd], ReceivedSignal,
      SizeOf(ReceivedSignal));
  until BytesRead = SizeOf(ReceivedSignal);
  IncomingCancellationDeadlines(DescendantDeadline,
    AcknowledgementDeadline);
  try
    TerminateRegisteredProcessTrees(
      InheritedManagedProcessTree,
      DescendantDeadline, AcknowledgementDeadline);
  except
    on E: Exception do
    begin
      SendInheritedAcknowledgement(AcknowledgementFailed);
      ReportForwardingFailure(E.Message);
      FpExit(ProcessTreeCancellationExitCode);
    end;
  end;
  if (InheritedStatusWriteHandle >= 0)
     and not SendInheritedAcknowledgement(AcknowledgementReaped) then
  begin
    ReportForwardingFailure(
      'could not send process-tree termination acknowledgement');
    FpExit(ProcessTreeCancellationExitCode);
  end;
  { Restore the default disposition before re-sending the original signal so
    shells and ancestor schedulers observe the original form of death. }
  FpSigEmptySet(SignalSet);
  FpSigAddSet(SignalSet, ReceivedSignal);
  FpSigProcMask(SIG_UNBLOCK, @SignalSet, nil);
  CSignal(ReceivedSignal, nil);
  CRaise(ReceivedSignal);
  FpExit(SignalExitCodeBase + ReceivedSignal);
end;

procedure ProcessTreeSignalHandler(ASignal: LongInt); cdecl;
begin
  { write(2) is async-signal-safe. The pipe is nonblocking, and one complete
    LongInt write is below PIPE_BUF; if repeated signals fill it, an earlier
    queued signal already guarantees that forwarding will run. }
  FpWrite(SignalPipe[SignalPipeWriteEnd], ASignal, SizeOf(ASignal));
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure TLWPTInheritedControlForwarder.Execute;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
  CancellationBuffer, CancellationLine: string;
begin
  CancellationBuffer := '';
  repeat
    if Terminated then Exit;
    if ReadProtocolLineBefore(InheritedControlReadHandle,
      GetTickCount64 + ProcessTreeTerminatePollMilliseconds,
      CancellationBuffer, CancellationLine)
       and ParseCancellationFrame(CancellationLine, InheritedChannelToken,
         DescendantDeadline, AcknowledgementDeadline) then Break;
  until False;
  try
    TerminateRegisteredProcessTrees(True, DescendantDeadline,
      AcknowledgementDeadline);
  except
    on E: Exception do
    begin
      SendInheritedAcknowledgement(AcknowledgementFailed);
      ReportForwardingFailure(E.Message);
      Windows.ExitProcess(ProcessTreeCancellationExitCode);
    end;
  end;
  if not SendInheritedAcknowledgement(AcknowledgementReaped) then
  begin
    ReportForwardingFailure(
      'could not send process-tree termination acknowledgement');
    Windows.ExitProcess(ProcessTreeCancellationExitCode);
  end;
  Windows.ExitProcess(WindowsControlExitCode);
end;

procedure TLWPTConsoleControlForwarder.Execute;
begin
  Windows.WaitForSingleObject(ConsoleControlEvent, Windows.INFINITE);
  if Terminated then Exit;
  try
    TerminateRegisteredProcessTrees(InheritedManagedProcessTree);
  except
    on E: Exception do
    begin
      ReportForwardingFailure(E.Message);
      Windows.ExitProcess(ProcessTreeCancellationExitCode);
    end;
  end;
  Windows.ExitProcess(WindowsControlExitCode);
end;

function ProcessTreeConsoleControlHandler(AControlType: DWORD): BOOL; stdcall;
begin
  Result := False;
  if (AControlType <> Windows.CTRL_C_EVENT)
     and (AControlType <> Windows.CTRL_BREAK_EVENT) then Exit;
  if InheritedControlReadHandle >= 0 then Exit(True);
  { Windows invokes this callback on an operating-system thread. It may only
    wake the FPC-owned forwarder; registry traversal, Job Object work,
    reporting, and process exit all remain on that dedicated thread. }
  if ConsoleControlEvent <> 0 then
    Result := Windows.SetEvent(ConsoleControlEvent);
end;
{$ENDIF}

procedure InstallProcessTreeSignalForwarding;
{$IFDEF UNIX}
var
  PreviousInterruptHandler, PreviousPipeHandler,
    PreviousTerminateHandler: Pointer;
  ErrorCode: Integer;
  InterruptHandlerInstalled, SignalPipeCreated,
    TerminateHandlerInstalled: Boolean;
{$ENDIF}
begin
  if SignalForwardingInstalled then Exit;
  LoadInheritedAcknowledgementChannel;
  {$IFDEF UNIX}
  InterruptHandlerInstalled := False;
  SignalPipeCreated := False;
  TerminateHandlerInstalled := False;
  { POSIX fixes SIG_IGN at address 1. Protocol writes report EPIPE instead of
    allowing a vanished nested reader to terminate its ancestor with SIGPIPE. }
  PreviousPipeHandler := CSignal(SIGPIPE, Pointer(1));
  if SignalHandlerFailed(PreviousPipeHandler) then RaiseLastOSError;
  try
    if FpPipe(SignalPipe) <> 0 then
    begin
      ErrorCode := FpGetErrNo;
      raise EOSError.CreateFmt(
        'could not create process-tree signal pipe: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    SignalPipeCreated := True;
    if (FpFcntl(SignalPipe[SignalPipeReadEnd], F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(SignalPipe[SignalPipeWriteEnd], F_SetFD, FD_CLOEXEC) < 0)
       or (FpFcntl(SignalPipe[SignalPipeWriteEnd], F_SetFl, O_NONBLOCK) < 0) then
    begin
      ErrorCode := FpGetErrNo;
      raise EOSError.CreateFmt(
        'could not configure process-tree signal pipe: %s',
        [SysErrorMessage(ErrorCode)]);
    end;
    PreviousTerminateHandler := CSignal(SIGTERM,
      @ProcessTreeSignalHandler);
    if SignalHandlerFailed(PreviousTerminateHandler) then RaiseLastOSError;
    TerminateHandlerInstalled := True;
    PreviousInterruptHandler := CSignal(SIGINT,
      @ProcessTreeSignalHandler);
    if SignalHandlerFailed(PreviousInterruptHandler) then RaiseLastOSError;
    InterruptHandlerInstalled := True;
    SignalForwarder := TLWPTSignalForwarder.Create(True);
    SignalForwarder.FreeOnTerminate := False;
    SignalForwarder.Start;
    SignalForwardingInstalled := True;
    if InheritedStatusWriteHandle >= 0 then
      SendInheritedAcknowledgement(AcknowledgementHello);
  except
    if InterruptHandlerInstalled then
      CSignal(SIGINT, PreviousInterruptHandler);
    if TerminateHandlerInstalled then
      CSignal(SIGTERM, PreviousTerminateHandler);
    if SignalPipeCreated then
    begin
      FpClose(SignalPipe[SignalPipeReadEnd]);
      FpClose(SignalPipe[SignalPipeWriteEnd]);
    end;
    CSignal(SIGPIPE, PreviousPipeHandler);
    raise;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if SignalForwardingInstalled then Exit;
  { CREATE_NEW_PROCESS_GROUP and SetConsoleCtrlHandler(nil, True) both leave
    an inheritable Ctrl-C-ignore attribute on descendants. LWPT owns its
    cancellation policy, so restore Ctrl-C delivery before registering the
    forwarding handler; Ctrl-Break is delivered regardless of this flag. }
  if not Windows.SetConsoleCtrlHandler(nil, False) then RaiseLastOSError;
  ConsoleControlEvent := Windows.CreateEvent(nil, False, False, nil);
  if ConsoleControlEvent = 0 then RaiseLastOSError;
  if not Windows.SetConsoleCtrlHandler(@ProcessTreeConsoleControlHandler,
    True) then
  begin
    Windows.CloseHandle(ConsoleControlEvent);
    ConsoleControlEvent := 0;
    RaiseLastOSError;
  end;
  try
    ConsoleControlForwarder := TLWPTConsoleControlForwarder.Create(True);
    ConsoleControlForwarder.FreeOnTerminate := False;
    ConsoleControlForwarder.Start;
    if InheritedControlReadHandle >= 0 then
    begin
      InheritedControlForwarder := TLWPTInheritedControlForwarder.Create(True);
      InheritedControlForwarder.FreeOnTerminate := False;
      InheritedControlForwarder.Start;
    end;
    SignalForwardingInstalled := True;
    if InheritedStatusWriteHandle >= 0 then
      SendInheritedAcknowledgement(AcknowledgementHello);
  except
    Windows.SetConsoleCtrlHandler(@ProcessTreeConsoleControlHandler, False);
    if Assigned(InheritedControlForwarder) then
    begin
      InheritedControlForwarder.Terminate;
      FreeAndNil(InheritedControlForwarder);
    end;
    if Assigned(ConsoleControlForwarder) then
    begin
      ConsoleControlForwarder.Terminate;
      Windows.SetEvent(ConsoleControlEvent);
      FreeAndNil(ConsoleControlForwarder);
    end;
    Windows.CloseHandle(ConsoleControlEvent);
    ConsoleControlEvent := 0;
    raise;
  end;
  {$ENDIF}
end;

initialization
  ActiveProcessTrees := TList.Create;
  InitCriticalSection(ActiveProcessTreesCriticalSection);
  InitCriticalSection(ProcessSpawnCriticalSection);

end.
