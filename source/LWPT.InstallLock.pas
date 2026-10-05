{ LWPT.InstallLock — the cross-process install lock at .lwpt/install.lock,
  shared by the install transaction and `lwpt repair` (ADR-0053).

  Mutual exclusion is the file's existence: an owner creates it with
  O_CREAT|O_EXCL (Windows: CREATE_NEW), so at most one process holds it, and
  the owner removes it when it finishes. A crashed owner leaves the file
  behind.

  Liveness is an operating-system record lock on the same file: fcntl
  F_SETLK on byte 0 on Unix, LockFileEx on byte 1024 on Windows. After it
  creates the file, an owner takes the record lock, checks that the path
  still names the file it created, and only then writes its owner record:
  its PID, `holder=install|repair`, and INSTALL_LOCK_RECORD_MARKER. It
  removes the file before it releases the record lock. The kernel drops
  the record lock when the owner dies; the lock is not inherited by child
  processes and does not depend on PIDs, so neither a reused PID nor one
  from another PID namespace or host can decide liveness.

  `lwpt install` (Create) fails fast whenever the file exists. `lwpt
  repair` (CreateReclaiming) takes over a lock file only when its owner is
  provably dead, and otherwise fails with EConcurrencyError having changed
  nothing. Repair adopts the file only when all of these hold:

    - it holds the record lock: a held lock means a live owner; a
      filesystem without record locks gives no proof, so repair refuses;
    - its open file is still the one at the path;
    - the owner record is complete and carries the marker, so its owner
      held the record lock and has since died. A record without the marker
      (an older LWPT, a filesystem without record locks) or without any
      owner record (a creator that is still starting, or that died before
      writing one) proves nothing, so repair refuses and names the file to
      delete by hand once no install runs anywhere for the project.

  Adoption rewrites the owner record in place while repair holds the
  record lock, so the path never disappears and no install can create a
  lock meanwhile; a second repair finds the record lock held.

  Descriptor rule (Unix). fcntl record locks belong to the process, and
  closing any descriptor of the file in that process releases them. So a
  process that holds or is taking an install lock never opens the lock file
  a second time: every lock in this process is registered before its file
  is opened, a second acquisition of a registered path fails before it
  opens anything, and the owner record is read and written through the
  locked descriptor. Diagnostic reads by a contender happen only in a
  process that holds no lock on that path.

  Every open of the lock file goes through OpenProtectedDescriptor, never
  SysUtils.FileOpen or TFileStream: those take flock(2), which on Darwin
  shares one lock list with fcntl record locks, so they fail with EAGAIN
  while an owner holds its record lock. }
unit LWPT.InstallLock;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

const
  { The owner-record line written only by an owner that holds the record
    lock. }
  INSTALL_LOCK_RECORD_MARKER = 'lock=record';
  INSTALL_LOCK_HOLDER_INSTALL = 'install';
  INSTALL_LOCK_HOLDER_REPAIR = 'repair';

type
  TLWPTInstallLock = class
  private
    FPath, FHolder: string;
    FRegistered, FReclaimed: Boolean;
    FReclaimedPID: string;
    FHandle: THandle;
    procedure Acquire(const AReclaim: Boolean);
    procedure TakeOwnership;
    function TryReclaimExisting: Boolean;
    procedure WriteOwnerRecord(const ARecordLocked: Boolean);
    procedure ReleaseOwnership;
  public
    { Takes the lock for AHolder (INSTALL_LOCK_HOLDER_*), or raises
      EConcurrencyError naming the recorded holder when the file exists. }
    constructor Create(const APath, AHolder: string);
    { As Create, but takes over a lock file whose owner is provably dead.
      Raises EConcurrencyError, having changed nothing, otherwise. }
    constructor CreateReclaiming(const APath, AHolder: string);
    { Removes the lock file, then releases the record lock. }
    destructor Destroy; override;
    { True when the lock was taken over from a dead owner. }
    property Reclaimed: Boolean read FReclaimed;
    { The PID the dead owner recorded. }
    property ReclaimedPID: string read FReclaimedPID;
  end;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  Unix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes;

const
  { How long an owner waits for the record lock on the file it has just
    created: a repair examining the file holds it for milliseconds. }
  OWNER_RECORD_LOCK_WAIT_MILLISECONDS = 2000;
  { How long repair waits for the record lock before it reports a live
    holder, so a concurrent repair examining the file is not reported as
    its owner. }
  PROBE_RECORD_LOCK_WAIT_MILLISECONDS = 500;
  RECORD_LOCK_POLL_MILLISECONDS = 10;
  { A path that keeps changing between open and lock is contended by
    something other than LWPT; give up rather than loop. }
  RECLAIM_ATTEMPTS = 50;
  OWNER_RECORD_MAX_BYTES = 512;
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  F_WRLCK_LWPT = 1;
  F_UNLCK_LWPT = 2;
  {$ELSE}
  F_WRLCK_LWPT = F_WRLCK;
  F_UNLCK_LWPT = F_UNLCK;
  {$ENDIF}
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  LOCKFILE_EXCLUSIVE_LOCK_LWPT = $00000002;
  LOCKFILE_FAIL_IMMEDIATELY_LWPT = $00000001;
  { Byte-range lock offset: past the owner record, so readers of the record
    never touch the locked range. }
  LOCK_OFFSET = 1024;
  FILE_READ_ATTRIBUTES_LWPT = $0080;
  {$ENDIF}

type
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  TLWPTFlock = BaseUnix.FLock;
  {$ELSE}
  TLWPTFlock = TFlock;
  {$ENDIF}
  {$ENDIF}
  TLockHandle = THandle;

  TCreateOutcome = (coCreated, coExists);
  { rlUnsupported: the filesystem keeps no record locks. rlFailed: any
    other error, reported with its code. }
  TRecordLockOutcome = (rlAcquired, rlHeld, rlUnsupported, rlFailed);

  TOwnerRecord = record
    PID: string;
    Holder: string;
    Complete, RecordLocked: Boolean;
  end;

const
  NO_HANDLE = THandle(-1);

var
  { Install-lock paths this process holds or is taking (see the descriptor
    rule above). }
  HeldPaths: TStringList;
  HeldPathsLock: TRTLCriticalSection;

function HeldPathKey(const APath: string): string;
begin
  Result := ExpandFileName(APath);
  {$IFDEF MSWINDOWS}
  Result := AnsiLowerCase(Result);
  {$ENDIF}
end;

{ ── Test seams (ADR-0044) ───────────────────────────────────────────── }

{$IFDEF INSTALL_TESTING}
var
  LockHoldDone, CreatePauseDone, OwnPIDDone: Boolean;

{ The writer half of Tests.PayloadHandoff: the payload is written and its
  handle closed before the existence-only <path>.complete marker appears. }
procedure PublishLockSeamPayload(const APath, AContent: string);
var Stream: TFileStream; Bytes: TBytes;
begin
  ForceDirectories(ExtractFileDir(APath));
  Bytes := BytesOf(AContent);
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  TFileStream.Create(APath + '.complete', fmCreate).Free;
end;

{ Publishes <dir>/<AName> with this PID, then waits until the test
  publishes <dir>/<ARelease> or two minutes pass. }
procedure PauseForTesting(const ADirectory, AName, ARelease: string);
var StartedAt: QWord;
begin
  PublishLockSeamPayload(ADirectory + '/' + AName, IntToStr(GetProcessID));
  StartedAt := GetTickCount64;
  while not FileExists(ADirectory + '/' + ARelease + '.complete')
     and (GetTickCount64 - StartedAt < 120 * 1000) do
    Sleep(20);
end;

{ Holds the first install lock this process takes, after its owner record
  is written. }
procedure HoldInstallLockForTesting;
var Directory: string;
begin
  Directory := TestSeamValue('HOLD_INSTALL_LOCK');
  if LockHoldDone or (Directory = '') then Exit;
  LockHoldDone := True;
  PauseForTesting(Directory, 'held', 'release');
end;

{ Pauses the first owner between creating the lock file and taking its
  record lock. }
procedure PauseBeforeRecordLockForTesting;
var Directory: string;
begin
  Directory := TestSeamValue('PAUSE_BEFORE_RECORD_LOCK');
  if CreatePauseDone or (Directory = '') then Exit;
  CreatePauseDone := True;
  PauseForTesting(Directory, 'created', 'resume');
end;
{$ENDIF}

{ ── Platform primitives ─────────────────────────────────────────────── }

{$IFDEF UNIX}
function CreateLockFile(const APath: string;
  out AHandle: TLockHandle): TCreateOutcome;
var ErrorCode: LongInt;
begin
  AHandle := OpenProtectedDescriptor(APath, O_RDWR or O_CREAT or O_EXCL, &644);
  if AHandle >= 0 then Exit(coCreated);
  ErrorCode := FpGetErrNo;
  if ErrorCode = ESysEEXIST then Exit(coExists);
  raise ELWPTError.CreateFmt('failed to create install lock %s: %s (errno %d)',
    [APath, SysErrorMessage(ErrorCode), ErrorCode]);
end;

{ False when the path no longer exists. }
function OpenLockFile(const APath: string; const AWritable: Boolean;
  out AHandle: TLockHandle): Boolean;
var ErrorCode, Flags: LongInt;
begin
  if AWritable then Flags := O_RDWR else Flags := O_RDONLY;
  AHandle := OpenProtectedDescriptor(APath, Flags, 0);
  if AHandle >= 0 then Exit(True);
  ErrorCode := FpGetErrNo;
  if ErrorCode = ESysENOENT then Exit(False);
  raise ELWPTError.CreateFmt('failed to open install lock %s: %s (errno %d)',
    [APath, SysErrorMessage(ErrorCode), ErrorCode]);
end;

function TryRecordLock(AHandle: TLockHandle;
  out AErrorCode: LongInt): TRecordLockOutcome;
var Spec: TLWPTFlock;
begin
  AErrorCode := 0;
  {$IFDEF INSTALL_TESTING}
  if TestSeamValue('RECORD_LOCK_UNSUPPORTED') = '1' then
  begin
    AErrorCode := ESysENOLCK;
    Exit(rlUnsupported);
  end;
  {$ENDIF}
  FillChar(Spec, SizeOf(Spec), 0);
  Spec.l_type := F_WRLCK_LWPT;
  Spec.l_whence := SEEK_SET;
  Spec.l_start := 0;
  Spec.l_len := 1;
  if FpFcntl(AHandle, F_SetLk, Spec) = 0 then Exit(rlAcquired);
  AErrorCode := FpGetErrNo;
  if (AErrorCode = ESysEAGAIN) or (AErrorCode = ESysEACCES)
     or (AErrorCode = ESysEINTR) then
    Result := rlHeld
  else if AErrorCode = ESysENOLCK then
    Result := rlUnsupported
  else
    Result := rlFailed;
end;

procedure CloseLockHandle(AHandle: TLockHandle);
var Spec: TLWPTFlock;
begin
  if AHandle < 0 then Exit;
  FillChar(Spec, SizeOf(Spec), 0);
  Spec.l_type := F_UNLCK_LWPT;
  Spec.l_whence := SEEK_SET;
  Spec.l_start := 0;
  Spec.l_len := 1;
  FpFcntl(AHandle, F_SetLk, Spec);
  FpClose(AHandle);
end;

function ReadOwnerText(AHandle: TLockHandle): string;
var Buffer: array[0..OWNER_RECORD_MAX_BYTES - 1] of AnsiChar; Count: TSsize;
begin
  Result := '';
  if FpLseek(AHandle, 0, SEEK_SET) <> 0 then Exit;
  Count := FpRead(AHandle, Buffer[0], SizeOf(Buffer));
  if Count > 0 then SetString(Result, PAnsiChar(@Buffer[0]), Count);
end;

function WriteOwnerText(AHandle: TLockHandle; const AText: string): Boolean;
var Raw: RawByteString;
begin
  Raw := RawByteString(AText);
  Result := (FpFtruncate(AHandle, 0) = 0)
    and (FpLseek(AHandle, 0, SEEK_SET) = 0)
    and (FpWrite(AHandle, Raw[1], Length(Raw)) = Length(Raw));
end;

{ Whether AHandle is still the file at APath, rather than one that was
  removed or replaced after it was opened. lstat opens nothing, so it
  cannot release a record lock. }
function HandleNamesPath(AHandle: TLockHandle; const APath: string): Boolean;
var Opened, Named: Stat;
begin
  Result := (FpFStat(AHandle, Opened) = 0) and (FpLStat(APath, Named) = 0)
    and (Opened.st_dev = Named.st_dev) and (Opened.st_ino = Named.st_ino);
end;

function RemoveLockPath(const APath: string): Boolean;
begin
  Result := FpUnlink(PChar(APath)) = 0;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
const
  SHARE_ALL = Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
    or Windows.FILE_SHARE_DELETE;

function CreateLockFile(const APath: string;
  out AHandle: TLockHandle): TCreateOutcome;
var ErrorCode: DWORD;
begin
  AHandle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)),
    Windows.GENERIC_READ or Windows.GENERIC_WRITE, SHARE_ALL, nil,
    Windows.CREATE_NEW, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if AHandle <> NO_HANDLE then Exit(coCreated);
  ErrorCode := Windows.GetLastError;
  { A lock file that its owner has deleted but still holds open is
    delete-pending, and refuses a new create with access denied until the
    owner closes it. }
  if (ErrorCode = Windows.ERROR_FILE_EXISTS)
     or (ErrorCode = Windows.ERROR_ALREADY_EXISTS)
     or ((ErrorCode = Windows.ERROR_ACCESS_DENIED)
       and LongPathFileExists(APath)) then
    Exit(coExists);
  raise ELWPTError.CreateFmt('failed to create install lock %s: %s (code %d)',
    [APath, SysErrorMessage(ErrorCode), ErrorCode]);
end;

function OpenLockFile(const APath: string; const AWritable: Boolean;
  out AHandle: TLockHandle): Boolean;
var ErrorCode, Access: DWORD;
begin
  Access := Windows.GENERIC_READ;
  if AWritable then Access := Access or Windows.GENERIC_WRITE;
  AHandle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)),
    Access, SHARE_ALL, nil, Windows.OPEN_EXISTING,
    Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if AHandle <> NO_HANDLE then Exit(True);
  ErrorCode := Windows.GetLastError;
  if (ErrorCode = Windows.ERROR_FILE_NOT_FOUND)
     or (ErrorCode = Windows.ERROR_PATH_NOT_FOUND)
     or (ErrorCode = Windows.ERROR_ACCESS_DENIED) then
    Exit(False);
  raise ELWPTError.CreateFmt('failed to open install lock %s: %s (code %d)',
    [APath, SysErrorMessage(ErrorCode), ErrorCode]);
end;

function TryRecordLock(AHandle: TLockHandle;
  out AErrorCode: LongInt): TRecordLockOutcome;
var Overlapped: TOverlapped;
begin
  AErrorCode := 0;
  {$IFDEF INSTALL_TESTING}
  if TestSeamValue('RECORD_LOCK_UNSUPPORTED') = '1' then
  begin
    AErrorCode := Windows.ERROR_NOT_SUPPORTED;
    Exit(rlUnsupported);
  end;
  {$ENDIF}
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.Offset := LOCK_OFFSET;
  if Windows.LockFileEx(AHandle,
    LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
    0, 1, 0, Overlapped) then
    Exit(rlAcquired);
  AErrorCode := LongInt(Windows.GetLastError);
  if (AErrorCode = Windows.ERROR_LOCK_VIOLATION)
     or (AErrorCode = Windows.ERROR_IO_PENDING) then
    Result := rlHeld
  else if (AErrorCode = Windows.ERROR_NOT_SUPPORTED)
     or (AErrorCode = Windows.ERROR_INVALID_FUNCTION) then
    Result := rlUnsupported
  else
    Result := rlFailed;
end;

procedure CloseLockHandle(AHandle: TLockHandle);
var Overlapped: TOverlapped;
begin
  if AHandle = NO_HANDLE then Exit;
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.Offset := LOCK_OFFSET;
  Windows.UnlockFileEx(AHandle, 0, 1, 0, Overlapped);
  Windows.CloseHandle(AHandle);
end;

function ReadOwnerText(AHandle: TLockHandle): string;
var Buffer: array[0..OWNER_RECORD_MAX_BYTES - 1] of AnsiChar; Count: DWORD;
begin
  Result := '';
  if Windows.SetFilePointer(AHandle, 0, nil, Windows.FILE_BEGIN) <> 0 then
    Exit;
  Count := 0;
  if Windows.ReadFile(AHandle, Buffer[0], SizeOf(Buffer), Count, nil)
     and (Count > 0) then
    SetString(Result, PAnsiChar(@Buffer[0]), Count);
end;

function WriteOwnerText(AHandle: TLockHandle; const AText: string): Boolean;
var Raw: RawByteString; Written: DWORD;
begin
  Raw := RawByteString(AText);
  Written := 0;
  Result := (Windows.SetFilePointer(AHandle, 0, nil, Windows.FILE_BEGIN) = 0)
    and Windows.SetEndOfFile(AHandle)
    and Windows.WriteFile(AHandle, Raw[1], Length(Raw), Written, nil)
    and (Written = DWORD(Length(Raw)));
end;

{ Windows byte-range locks belong to the handle, so this second handle
  cannot release one. }
function HandleNamesPath(AHandle: TLockHandle; const APath: string): Boolean;
var Named: THandle; OpenedInfo, NamedInfo: BY_HANDLE_FILE_INFORMATION;
begin
  Result := False;
  if not Windows.GetFileInformationByHandle(AHandle, OpenedInfo) then Exit;
  { A delete-pending file refuses this open. }
  Named := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)),
    FILE_READ_ATTRIBUTES_LWPT, SHARE_ALL, nil, Windows.OPEN_EXISTING,
    Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if Named = NO_HANDLE then Exit;
  try
    Result := Windows.GetFileInformationByHandle(Named, NamedInfo)
      and (OpenedInfo.dwVolumeSerialNumber = NamedInfo.dwVolumeSerialNumber)
      and (OpenedInfo.nFileIndexHigh = NamedInfo.nFileIndexHigh)
      and (OpenedInfo.nFileIndexLow = NamedInfo.nFileIndexLow);
  finally
    Windows.CloseHandle(Named);
  end;
end;

function RemoveLockPath(const APath: string): Boolean;
var StartedAt: QWord;
begin
  { Another handle without delete sharing, such as a scanner's, can hold
    the file briefly. }
  StartedAt := GetTickCount64;
  repeat
    if LongPathDeleteFile(APath) then Exit(True);
    Sleep(RECORD_LOCK_POLL_MILLISECONDS);
  until GetTickCount64 - StartedAt >= 1000;
  Result := False;
end;
{$ENDIF}

{$IFDEF INSTALL_TESTING}
{ Rewrites the PID of the first lock file this process reclaims to its own
  PID, as when a crashed install and the repair after it both run as PID 1
  of separate containers. Runs before this process takes any record lock on
  the file, so closing this descriptor releases nothing. }
procedure RecordOwnPIDForTesting(const APath: string);
var Directory, Text: string; Handle: TLockHandle; Ending: Integer;
begin
  Directory := TestSeamValue('RECORD_OWN_PID');
  if OwnPIDDone or (Directory = '') then Exit;
  OwnPIDDone := True;
  if not OpenLockFile(APath, True, Handle) then Exit;
  try
    Text := ReadOwnerText(Handle);
    Ending := Pos(#10, Text);
    if Ending = 0 then Ending := Length(Text) + 1;
    WriteOwnerText(Handle, IntToStr(GetProcessID)
      + Copy(Text, Ending, MaxInt));
  finally
    {$IFDEF UNIX}
    FpClose(Handle);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Windows.CloseHandle(Handle);
    {$ENDIF}
  end;
  PublishLockSeamPayload(Directory + '/pid', IntToStr(GetProcessID));
end;
{$ENDIF}

{ ── Owner records ───────────────────────────────────────────────────── }

function RecordLockWithin(AHandle: TLockHandle; const AMilliseconds: QWord;
  out AErrorCode: LongInt): TRecordLockOutcome;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    Result := TryRecordLock(AHandle, AErrorCode);
    if Result <> rlHeld then Exit;
    Sleep(RECORD_LOCK_POLL_MILLISECONDS);
  until GetTickCount64 - StartedAt >= AMilliseconds;
end;

{ Line 1 is the PID, which every LWPT has written; later lines are
  key=value. }
function ParseOwnerRecord(const AText: string): TOwnerRecord;
var Lines: TStringList; i: Integer; Line: string;
begin
  Result.PID := '';
  Result.Holder := '';
  Result.Complete := False;
  Result.RecordLocked := False;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    if Lines.Count = 0 then Exit;
    Line := Trim(Lines[0]);
    if StrToIntDef(Line, 0) <= 0 then Exit;
    Result.PID := Line;
    Result.Complete := True;
    for i := 1 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if Line = INSTALL_LOCK_RECORD_MARKER then
        Result.RecordLocked := True
      else if Copy(Line, 1, Length('holder=')) = 'holder=' then
        Result.Holder := Copy(Line, Length('holder=') + 1, MaxInt);
    end;
  finally
    Lines.Free;
  end;
end;

function HolderDescription(const ARecord: TOwnerRecord): string;
begin
  if ARecord.Holder <> '' then
    Result := PROGRAM_NAME + ' ' + ARecord.Holder
  else
    Result := 'process';
end;

function PIDText(const ARecord: TOwnerRecord): string;
begin
  if ARecord.PID <> '' then Result := ARecord.PID
  else Result := 'unknown';
end;

function ManualRecovery(const APath: string): string;
begin
  Result := 'repair changed nothing. Once no ' + PROGRAM_NAME + ' install '
    + 'or repair runs for this project anywhere (other hosts and containers '
    + 'sharing it included), delete ' + APath + ' by hand and run repair '
    + 'again.';
end;

{ The owner record of the lock file at APath for a diagnostic, read through
  a read-only open in a process that holds no lock on it. }
function ReadOwnerRecordAt(const APath: string): TOwnerRecord;
var Handle: TLockHandle;
begin
  Result := ParseOwnerRecord('');
  try
    if not OpenLockFile(APath, False, Handle) then Exit;
  except
    on ELWPTError do Exit;
  end;
  try
    Result := ParseOwnerRecord(ReadOwnerText(Handle));
  finally
    {$IFDEF UNIX}
    FpClose(Handle);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Windows.CloseHandle(Handle);
    {$ENDIF}
  end;
end;

{ ── TLWPTInstallLock ────────────────────────────────────────────────── }

constructor TLWPTInstallLock.Create(const APath, AHolder: string);
begin
  inherited Create;
  FPath := APath;
  FHolder := AHolder;
  FHandle := NO_HANDLE;
  Acquire(False);
end;

constructor TLWPTInstallLock.CreateReclaiming(const APath, AHolder: string);
begin
  inherited Create;
  FPath := APath;
  FHolder := AHolder;
  FHandle := NO_HANDLE;
  Acquire(True);
end;

destructor TLWPTInstallLock.Destroy;
var Index: Integer;
begin
  ReleaseOwnership;
  if FRegistered then
  begin
    EnterCriticalSection(HeldPathsLock);
    try
      Index := HeldPaths.IndexOf(HeldPathKey(FPath));
      if Index >= 0 then HeldPaths.Delete(Index);
    finally
      LeaveCriticalSection(HeldPathsLock);
    end;
    FRegistered := False;
  end;
  inherited Destroy;
end;

procedure TLWPTInstallLock.Acquire(const AReclaim: Boolean);
var
  Attempt: Integer;
  Handle: TLockHandle;
  Directory: string;
  Existing: TOwnerRecord;
begin
  { Registered before the file is opened, so this process never opens a
    lock file it already holds (see the descriptor rule above). }
  EnterCriticalSection(HeldPathsLock);
  try
    if HeldPaths.IndexOf(HeldPathKey(FPath)) >= 0 then
      raise EConcurrencyError.CreateFmt(
        'this process already holds the install lock %s', [FPath]);
    HeldPaths.Add(HeldPathKey(FPath));
    FRegistered := True;
  finally
    LeaveCriticalSection(HeldPathsLock);
  end;
  Directory := ExtractFileDir(FPath);
  if Directory <> '' then LongPathForceDirectories(Directory);
  for Attempt := 1 to RECLAIM_ATTEMPTS do
  begin
    if CreateLockFile(FPath, Handle) = coCreated then
    begin
      FHandle := Handle;
      TakeOwnership;
      Exit;
    end;
    if not AReclaim then
    begin
      Existing := ReadOwnerRecordAt(FPath);
      if Existing.Holder = '' then
        Existing.Holder := INSTALL_LOCK_HOLDER_INSTALL;
      raise EConcurrencyError.CreateFmt(
        'another %s is in progress (lock holder PID: %s), or it crashed '
        + 'without releasing the lock. Run `%s repair`, which clears the '
        + 'lock only once it can prove its owner has exited.',
        [HolderDescription(Existing), PIDText(Existing), PROGRAM_NAME]);
    end;
    {$IFDEF INSTALL_TESTING}
    RecordOwnPIDForTesting(FPath);
    {$ENDIF}
    if TryReclaimExisting then Exit;
    Sleep(RECORD_LOCK_POLL_MILLISECONDS);
  end;
  raise EConcurrencyError.CreateFmt(
    'the install lock %s kept changing while it was examined; nothing was '
    + 'changed. Run the command again.', [FPath]);
end;

procedure TLWPTInstallLock.TakeOwnership;
var Outcome: TRecordLockOutcome; ErrorCode: LongInt;
begin
  {$IFDEF INSTALL_TESTING}
  PauseBeforeRecordLockForTesting;
  {$ENDIF}
  Outcome := RecordLockWithin(FHandle, OWNER_RECORD_LOCK_WAIT_MILLISECONDS,
    ErrorCode);
  if (Outcome = rlHeld) or (Outcome = rlFailed)
     or not HandleNamesPath(FHandle, FPath) then
  begin
    { The file this process created was taken over, removed, or replaced
      while it started, so it is no longer this process's to remove or
      write. A file adopted by repair is held by it; a replaced path names
      another owner's file. }
    CloseLockHandle(FHandle);
    FHandle := NO_HANDLE;
    if Outcome = rlFailed then
      raise ELWPTError.CreateFmt(
        'could not lock the install lock %s: %s (code %d)',
        [FPath, SysErrorMessage(ErrorCode), ErrorCode]);
    raise EConcurrencyError.CreateFmt(
      'the install lock %s was taken over, removed, or replaced while this '
      + '%s %s was creating it; nothing was changed. Run it again.',
      [FPath, PROGRAM_NAME, FHolder]);
  end;
  { Without record locks the owner still runs, but its record carries no
    marker, so repair never reclaims it automatically. }
  WriteOwnerRecord(Outcome = rlAcquired);
  {$IFDEF INSTALL_TESTING}
  HoldInstallLockForTesting;
  {$ENDIF}
end;

function TLWPTInstallLock.TryReclaimExisting: Boolean;
var
  Handle: TLockHandle;
  Outcome: TRecordLockOutcome;
  Existing: TOwnerRecord;
  ErrorCode: LongInt;
begin
  Result := False;
  if not OpenLockFile(FPath, True, Handle) then Exit;
  try
    Outcome := RecordLockWithin(Handle, PROBE_RECORD_LOCK_WAIT_MILLISECONDS,
      ErrorCode);
    Existing := ParseOwnerRecord(ReadOwnerText(Handle));
    case Outcome of
      rlHeld:
        raise EConcurrencyError.CreateFmt(
          'the install lock %s is held by a running %s (PID %s); repair '
          + 'changed nothing. Run it again once that process has finished.',
          [FPath, HolderDescription(Existing), PIDText(Existing)]);
      rlUnsupported:
        raise EConcurrencyError.CreateFmt(
          'the filesystem holding the install lock %s (PID %s) keeps no '
          + 'record locks, so repair can neither prove that its owner has '
          + 'exited nor keep a second repair out; %s',
          [FPath, PIDText(Existing), ManualRecovery(FPath)]);
      rlFailed:
        raise ELWPTError.CreateFmt(
          'could not lock the install lock %s: %s (code %d); repair '
          + 'changed nothing', [FPath, SysErrorMessage(ErrorCode), ErrorCode]);
    end;
    { Released or replaced since it was opened: start over. }
    if not HandleNamesPath(Handle, FPath) then Exit;
    if not Existing.Complete then
      raise EConcurrencyError.CreateFmt(
        'the install lock %s has no owner record: its creator is still '
        + 'starting or exited before writing one, and only a lock its owner '
        + 'recorded can be reclaimed; %s', [FPath, ManualRecovery(FPath)]);
    if not Existing.RecordLocked then
      raise EConcurrencyError.CreateFmt(
        'the install lock %s (PID %s) was written by an older %s or on a '
        + 'filesystem without record locks, so repair cannot prove that its '
        + 'owner has exited; %s',
        [FPath, Existing.PID, PROGRAM_NAME, ManualRecovery(FPath)]);
    { Its owner held the record lock when it wrote this record and holds it
      no more: it has exited, whatever process its PID names now. Adopt the
      file under the record lock: the path never stops existing, so no
      install can create a lock meanwhile. }
    FReclaimed := True;
    FReclaimedPID := Existing.PID;
    FHandle := Handle;
    Handle := NO_HANDLE;
    WriteOwnerRecord(True);
    {$IFDEF INSTALL_TESTING}
    HoldInstallLockForTesting;
    {$ENDIF}
    Result := True;
  finally
    if Handle <> NO_HANDLE then CloseLockHandle(Handle);
  end;
end;

procedure TLWPTInstallLock.WriteOwnerRecord(const ARecordLocked: Boolean);
var Text: string;
begin
  Text := IntToStr(GetProcessID) + #10 + 'holder=' + FHolder + #10;
  if ARecordLocked then Text := Text + INSTALL_LOCK_RECORD_MARKER + #10;
  if not WriteOwnerText(FHandle, Text) then
  begin
    ReleaseOwnership;
    raise ELWPTError.CreateFmt('failed to write the install lock %s',
      [FPath]);
  end;
end;

procedure TLWPTInstallLock.ReleaseOwnership;
begin
  if FHandle = NO_HANDLE then Exit;
  try
    { Remove the path while the record lock is still held, so no contender
      can find the file unlocked under its name. A file that is no longer
      at the path belongs to someone else. }
    if HandleNamesPath(FHandle, FPath) then RemoveLockPath(FPath);
  finally
    CloseLockHandle(FHandle);
    FHandle := NO_HANDLE;
  end;
end;

initialization
  InitCriticalSection(HeldPathsLock);
  HeldPaths := TStringList.Create;

finalization
  HeldPaths.Free;
  DoneCriticalSection(HeldPathsLock);

end.
