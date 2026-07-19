unit Platform;

(* Platform — host OS + CPU detection table. LWPT-canonical per ADR-0017
   (descended from GocciaScript's earlier Goccia.Platform.pas; renamed +
   switched to the local Shared.inc include during a namespace
   cleanup).

   The constant value vocabulary is single-sourced across LWPT +
   GocciaScript so the build.os / build.arch placeholder values in LWPT
   manifests and the Goccia.build.os / Goccia.build.arch globals in
   GocciaScript match byte-for-byte. Adding a new platform requires
   changing one constant table in BOTH projects; the diff is
   mechanically obvious. *)

{$I Shared.inc}

interface

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Process,
  SysUtils;

type
  TLWPTProcessTree = class
  private
    FProcess: TProcess;
    {$IFDEF UNIX}
    procedure HandleFork(ASender: TObject);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FJobHandle: THandle;
    procedure TerminateCreatedProcess;
    {$ENDIF}
  public
    constructor Create(AProcess: TProcess);
    destructor Destroy; override;
    procedure Execute;
    procedure Terminate;
  end;

function GetBuildOS: string;
function GetBuildArch: string;

implementation

const
  PROCESS_TREE_TERMINATE_GRACE_MILLISECONDS = 250;
  PROCESS_TREE_TERMINATE_POLL_MILLISECONDS = 10;
  PROCESS_TREE_SETUP_EXIT_CODE = 127;
  PROCESS_GROUP_SETUP_ERROR = 'process tree isolation setup failed'#10;

  {$IFDEF MSWINDOWS}
  JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS_LWPT = 9;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_LWPT = $00002000;
  {$ENDIF}

  {$IF DEFINED(DARWIN)}
  BUILD_OS = 'darwin';
  {$ELSEIF DEFINED(ANDROID)}
  BUILD_OS = 'android';
  {$ELSEIF DEFINED(LINUX)}
  BUILD_OS = 'linux';
  {$ELSEIF DEFINED(MSWINDOWS)}
  BUILD_OS = 'windows';
  {$ELSEIF DEFINED(FREEBSD)}
  BUILD_OS = 'freebsd';
  {$ELSEIF DEFINED(NETBSD)}
  BUILD_OS = 'netbsd';
  {$ELSEIF DEFINED(OPENBSD)}
  BUILD_OS = 'openbsd';
  {$ELSEIF DEFINED(AIX)}
  BUILD_OS = 'aix';
  {$ELSEIF DEFINED(SOLARIS)}
  BUILD_OS = 'solaris';
  {$ELSE}
  BUILD_OS = 'unknown';
  {$ENDIF}

  {$IF DEFINED(CPUX86_64)}
  BUILD_ARCH = 'x86_64';
  {$ELSEIF DEFINED(CPUAARCH64)}
  BUILD_ARCH = 'aarch64';
  {$ELSEIF DEFINED(CPUI386)}
  BUILD_ARCH = 'x86';
  {$ELSEIF DEFINED(CPUARM)}
  BUILD_ARCH = 'arm';
  {$ELSEIF DEFINED(CPUPOWERPC64)}
  BUILD_ARCH = 'powerpc64';
  {$ELSEIF DEFINED(CPUPOWERPC)}
  BUILD_ARCH = 'powerpc';
  {$ELSE}
  BUILD_ARCH = 'unknown';
  {$ENDIF}

{$IFDEF UNIX}
function CSetProcessGroup(APID, AProcessGroupID: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setpgid';
  {$ELSE}
  external name 'setpgid';
  {$ENDIF}
{$ENDIF}

{$IFDEF MSWINDOWS}
{$PACKRECORDS C}
type
  TLWPTJobObjectBasicLimitInformation = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: PtrUInt;
    MaximumWorkingSetSize: PtrUInt;
    ActiveProcessLimit: DWORD;
    Affinity: PtrUInt;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  TLWPTIOCounters = record
    ReadOperationCount: QWord;
    WriteOperationCount: QWord;
    OtherOperationCount: QWord;
    ReadTransferCount: QWord;
    WriteTransferCount: QWord;
    OtherTransferCount: QWord;
  end;

  TLWPTJobObjectExtendedLimitInformation = record
    BasicLimitInformation: TLWPTJobObjectBasicLimitInformation;
    IOInfo: TLWPTIOCounters;
    ProcessMemoryLimit: PtrUInt;
    JobMemoryLimit: PtrUInt;
    PeakProcessMemoryUsed: PtrUInt;
    PeakJobMemoryUsed: PtrUInt;
  end;
{$PACKRECORDS DEFAULT}

function LWPTCreateJobObject(ASecurityAttributes: Pointer;
  AName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';
function LWPTSetInformationJobObject(AJob: THandle;
  AInformationClass: DWORD; AInformation: Pointer;
  AInformationLength: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetInformationJobObject';
function LWPTAssignProcessToJobObject(AJob, AProcess: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';
function LWPTTerminateJobObject(AJob: THandle; AExitCode: UINT): BOOL; stdcall;
  external 'kernel32.dll' name 'TerminateJobObject';
{$ENDIF}

constructor TLWPTProcessTree.Create(AProcess: TProcess);
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
  LimitInformation: TLWPTJobObjectExtendedLimitInformation;
{$ENDIF}
begin
  inherited Create;
  if not Assigned(AProcess) then
    raise EArgumentNilException.Create('process');
  FProcess := AProcess;
  {$IFDEF UNIX}
  FProcess.OnForkEvent := HandleFork;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FJobHandle := LWPTCreateJobObject(nil, nil);
  if FJobHandle = 0 then RaiseLastOSError;
  FillChar(LimitInformation, SizeOf(LimitInformation), 0);
  LimitInformation.BasicLimitInformation.LimitFlags :=
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_LWPT;
  if not LWPTSetInformationJobObject(FJobHandle,
    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS_LWPT, @LimitInformation,
    SizeOf(LimitInformation)) then
  begin
    ErrorCode := Windows.GetLastError;
    Windows.CloseHandle(FJobHandle);
    FJobHandle := 0;
    raise EOSError.CreateFmt('could not configure process Job Object: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  FProcess.Options := FProcess.Options + [poRunSuspended];
  {$ENDIF}
end;

destructor TLWPTProcessTree.Destroy;
begin
  {$IFDEF UNIX}
  if Assigned(FProcess) then FProcess.OnForkEvent := nil;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if FJobHandle <> 0 then
  begin
    Windows.CloseHandle(FJobHandle);
    FJobHandle := 0;
  end;
  {$ENDIF}
  inherited Destroy;
end;

{$IFDEF UNIX}
procedure TLWPTProcessTree.HandleFork(ASender: TObject);
begin
  if CSetProcessGroup(0, 0) = 0 then Exit;
  FpWrite(StdErrorHandle, PROCESS_GROUP_SETUP_ERROR[1],
    Length(PROCESS_GROUP_SETUP_ERROR));
  FpExit(PROCESS_TREE_SETUP_EXIT_CODE);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure TLWPTProcessTree.TerminateCreatedProcess;
var
  ErrorCode: DWORD;
begin
  if not Windows.TerminateProcess(FProcess.ProcessHandle,
    PROCESS_TREE_SETUP_EXIT_CODE) then
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

procedure TLWPTProcessTree.Execute;
{$IFDEF UNIX}
var
  ErrorCode: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
{$ENDIF}
begin
  FProcess.Execute;
  {$IFDEF UNIX}
  { Close the parent/child race: either this call creates the group, or
    EACCES proves the child has already passed the pre-exec fork handler. }
  if CSetProcessGroup(FProcess.ProcessID, FProcess.ProcessID) = 0 then Exit;
  ErrorCode := FpGetErrNo;
  if ErrorCode in [ESysEACCES, ESysESRCH] then Exit;
  FProcess.Terminate(PROCESS_TREE_SETUP_EXIT_CODE);
  FProcess.WaitOnExit;
  raise EOSError.CreateFmt('could not isolate process tree: %s',
    [SysErrorMessage(ErrorCode)]);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not LWPTAssignProcessToJobObject(FJobHandle,
    FProcess.ProcessHandle) then
  begin
    ErrorCode := Windows.GetLastError;
    TerminateCreatedProcess;
    raise EOSError.CreateFmt('could not assign process to Job Object: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  if Windows.ResumeThread(FProcess.ThreadHandle) = DWORD(-1) then
  begin
    ErrorCode := Windows.GetLastError;
    TerminateCreatedProcess;
    raise EOSError.CreateFmt('could not resume isolated process: %s',
      [SysErrorMessage(ErrorCode)]);
  end;
  {$ENDIF}
end;

procedure TLWPTProcessTree.Terminate;
{$IFDEF UNIX}
var
  ErrorCode, Waited: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
{$ENDIF}
begin
  {$IFDEF UNIX}
  if (FProcess.ProcessID <= 0)
     or (FpKill(-FProcess.ProcessID, SIGTERM) = 0) then
  begin
    Waited := 0;
    while (FProcess.ProcessID > 0)
      and ((FpKill(-FProcess.ProcessID, 0) = 0)
        or (FpGetErrNo = ESysEPERM))
      and (Waited < PROCESS_TREE_TERMINATE_GRACE_MILLISECONDS) do
    begin
      Sleep(PROCESS_TREE_TERMINATE_POLL_MILLISECONDS);
      Inc(Waited, PROCESS_TREE_TERMINATE_POLL_MILLISECONDS);
    end;
    if (FProcess.ProcessID > 0)
      and ((FpKill(-FProcess.ProcessID, 0) = 0)
        or (FpGetErrNo = ESysEPERM))
      and (FpKill(-FProcess.ProcessID, SIGKILL) <> 0)
      and (FpGetErrNo <> ESysESRCH) then
      raise EOSError.CreateFmt('could not kill process tree: %s',
        [SysErrorMessage(FpGetErrNo)]);
    Exit;
  end;
  ErrorCode := FpGetErrNo;
  if ErrorCode <> ESysESRCH then
    raise EOSError.CreateFmt('could not terminate process tree: %s',
      [SysErrorMessage(ErrorCode)]);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if LWPTTerminateJobObject(FJobHandle, 1) then Exit;
  ErrorCode := Windows.GetLastError;
  raise EOSError.CreateFmt('could not terminate process Job Object: %s',
    [SysErrorMessage(ErrorCode)]);
  {$ENDIF}
end;

function GetBuildOS: string;
begin
  Result := BUILD_OS;
end;

function GetBuildArch: string;
begin
  Result := BUILD_ARCH;
end;

end.
