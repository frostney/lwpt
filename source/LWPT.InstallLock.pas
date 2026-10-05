{ LWPT.InstallLock — the cross-process install lock at .lwpt/install.lock.

  Mutual exclusion is the file's existence: an owner creates it with
  O_CREAT|O_EXCL (Windows: CREATE_NEW), so at most one process holds it, and
  the owner removes it when it finishes. A crashed owner leaves the file
  behind.

  Liveness is an operating-system record lock on the same file: fcntl
  F_SETLK on byte 0 on Unix, LockFileEx on byte 1024 on Windows. The owner
  takes it before it writes its owner record and holds it until it has
  removed the file, and the kernel drops it when the owner dies. A record
  lock is not inherited by children and does not depend on process
  identifiers, so a reused or foreign-namespace PID cannot keep a dead
  owner's lock alive or make a live one look dead.

  `lwpt install` (Create) fails fast whenever the file exists. `lwpt
  repair` (CreateReclaiming) takes over a lock file only when its owner is
  proven dead, under the record lock, so neither another repair nor an
  install can hold the lock at the same time:

    - the record lock is held: the owner is alive; repair fails and changes
      nothing;
    - the owner record says the owner held the record lock, and the lock is
      free: the owner is dead, whatever process its PID now names;
    - an owner record from an older LWPT, which held no record lock on Unix:
      the owner is dead only when its PID names no process (kill(pid, 0)
      fails with ESRCH; Windows: OpenProcess finds none or the process has
      exited). A reused PID keeps the lock (repair refuses and names it);
    - no complete owner record: an owner that died between creating the file
      and writing it, once the file is older than
      INSTALL_LOCK_INCOMPLETE_GRACE_SECONDS; a younger file is being
      created.

  A reclaiming repair adopts the dead owner's file in place: it rewrites the
  owner record while it holds the record lock, so the path never stops
  existing and no install can create a lock of its own meanwhile. Every
  owner removes the file before it releases the record lock, and a
  contender re-checks that its open file is still the one at the path once
  it holds the record lock, so a released or replaced file is never
  adopted. }
unit LWPT.InstallLock;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

const
  { How old a lock file without a complete owner record must be before
    repair treats it as residue. An owner writes its record immediately
    after it takes the record lock. }
  INSTALL_LOCK_INCOMPLETE_GRACE_SECONDS = 10;
  { The owner-record line written only by an owner that holds the record
    lock. }
  INSTALL_LOCK_RECORD_MARKER = 'lock=record';
  INSTALL_LOCK_HOLDER_INSTALL = 'install';
  INSTALL_LOCK_HOLDER_REPAIR = 'repair';

type
  TLWPTInstallLock = class
  private
    FPath, FHolder: string;
    FReclaimed: Boolean;
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
    { As Create, but takes over a lock file whose owner is proven dead.
      Raises EConcurrencyError, having changed nothing, when the owner may
      still run. }
    constructor CreateReclaiming(const APath, AHolder: string);
    { Removes the lock file, then releases the record lock. }
    destructor Destroy; override;
    { True when the lock was taken over from a dead owner. }
    property Reclaimed: Boolean read FReclaimed;
    { The PID the dead owner recorded, or '' when it recorded none. }
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
    holder, so a concurrent repair examining a dead owner's file is not
    reported as the owner. }
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
  TRecordLockOutcome = (rlAcquired, rlHeld, rlUnsupported);

  TOwnerRecord = record
    PID: string;
    Holder: string;
    Complete, RecordLocked: Boolean;
  end;

const
  NO_HANDLE = THandle(-1);

{$IFDEF INSTALL_TESTING}
var
  LockHoldDone: Boolean = False;

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

{ Holds the first install lock this process takes, after publishing
  <dir>/held, until the test publishes <dir>/release or two minutes pass. }
procedure HoldInstallLockForTesting;
var Directory: string; StartedAt: QWord;
begin
  Directory := TestSeamValue('HOLD_INSTALL_LOCK');
  if LockHoldDone or (Directory = '') then Exit;
  LockHoldDone := True;
  PublishLockSeamPayload(Directory + '/held', IntToStr(GetProcessID));
  StartedAt := GetTickCount64;
  while not FileExists(Directory + '/release.complete')
     and (GetTickCount64 - StartedAt < 120 * 1000) do
    Sleep(20);
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
function OpenLockFile(const APath: string;
  out AHandle: TLockHandle): Boolean;
var ErrorCode: LongInt;
begin
  AHandle := OpenProtectedDescriptor(APath, O_RDWR, 0);
  if AHandle >= 0 then Exit(True);
  ErrorCode := FpGetErrNo;
  if ErrorCode = ESysENOENT then Exit(False);
  raise ELWPTError.CreateFmt('failed to open install lock %s: %s (errno %d)',
    [APath, SysErrorMessage(ErrorCode), ErrorCode]);
end;

function TryRecordLock(AHandle: TLockHandle): TRecordLockOutcome;
var Spec: TLWPTFlock; ErrorCode: LongInt;
begin
  FillChar(Spec, SizeOf(Spec), 0);
  Spec.l_type := F_WRLCK_LWPT;
  Spec.l_whence := SEEK_SET;
  Spec.l_start := 0;
  Spec.l_len := 1;
  if FpFcntl(AHandle, F_SetLk, Spec) = 0 then Exit(rlAcquired);
  ErrorCode := FpGetErrNo;
  if (ErrorCode = ESysEAGAIN) or (ErrorCode = ESysEACCES)
     or (ErrorCode = ESysEINTR) then
    Exit(rlHeld);
  { ENOLCK and friends: the filesystem keeps no record locks. }
  Result := rlUnsupported;
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
  removed or replaced after it was opened. }
function HandleNamesPath(AHandle: TLockHandle; const APath: string): Boolean;
var Opened, Named: Stat;
begin
  Result := (FpFStat(AHandle, Opened) = 0) and (FpLStat(APath, Named) = 0)
    and (Opened.st_dev = Named.st_dev) and (Opened.st_ino = Named.st_ino);
end;

function OwnerRecordAgeSeconds(AHandle: TLockHandle): Int64;
var Info: Stat;
begin
  if FpFStat(AHandle, Info) <> 0 then Exit(0);
  Result := Int64(FpTime) - Int64(Info.st_mtime);
end;

function RemoveLockPath(const APath: string): Boolean;
begin
  Result := FpUnlink(PChar(APath)) = 0;
end;

{ Conservative: only a PID that provably names no process is dead. }
function RecordedProcessRuns(const APID: LongInt): Boolean;
begin
  if APID <= 0 then Exit(False);
  if FpKill(APID, 0) = 0 then Exit(True);
  Result := FpGetErrNo <> ESysESRCH;
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

function OpenLockFile(const APath: string;
  out AHandle: TLockHandle): Boolean;
var ErrorCode: DWORD;
begin
  AHandle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)),
    Windows.GENERIC_READ or Windows.GENERIC_WRITE, SHARE_ALL, nil,
    Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if AHandle <> NO_HANDLE then Exit(True);
  ErrorCode := Windows.GetLastError;
  if (ErrorCode = Windows.ERROR_FILE_NOT_FOUND)
     or (ErrorCode = Windows.ERROR_PATH_NOT_FOUND)
     or (ErrorCode = Windows.ERROR_ACCESS_DENIED) then
    Exit(False);
  raise ELWPTError.CreateFmt('failed to open install lock %s: %s (code %d)',
    [APath, SysErrorMessage(ErrorCode), ErrorCode]);
end;

function TryRecordLock(AHandle: TLockHandle): TRecordLockOutcome;
var Overlapped: TOverlapped; ErrorCode: DWORD;
begin
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.Offset := LOCK_OFFSET;
  if Windows.LockFileEx(AHandle,
    LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
    0, 1, 0, Overlapped) then
    Exit(rlAcquired);
  ErrorCode := Windows.GetLastError;
  if (ErrorCode = Windows.ERROR_LOCK_VIOLATION)
     or (ErrorCode = Windows.ERROR_IO_PENDING) then
    Exit(rlHeld);
  Result := rlUnsupported;
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

function FileTimeTicks(const ATime: TFileTime): Int64;
begin
  Result := (Int64(ATime.dwHighDateTime) shl 32) or Int64(ATime.dwLowDateTime);
end;

function OwnerRecordAgeSeconds(AHandle: TLockHandle): Int64;
var Written, Current: TFileTime;
begin
  if not Windows.GetFileTime(AHandle, nil, nil, @Written) then Exit(0);
  Windows.GetSystemTimeAsFileTime(Current);
  { FILETIME counts 100-nanosecond intervals. }
  Result := (FileTimeTicks(Current) - FileTimeTicks(Written)) div 10000000;
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

{ Conservative: only a PID that provably names no running process is dead.
  The process object, not an exit code, decides: a process may exit with
  STILL_ACTIVE (259). }
function RecordedProcessRuns(const APID: LongInt): Boolean;
var Process: THandle;
begin
  if APID <= 0 then Exit(False);
  Process := Windows.OpenProcess(Windows.SYNCHRONIZE, False, DWORD(APID));
  if Process = 0 then
    Exit(Windows.GetLastError <> Windows.ERROR_INVALID_PARAMETER);
  try
    Result := Windows.WaitForSingleObject(Process, 0) = Windows.WAIT_TIMEOUT;
  finally
    Windows.CloseHandle(Process);
  end;
end;
{$ENDIF}

{ ── Owner records ───────────────────────────────────────────────────── }

function RecordLockWithin(AHandle: TLockHandle;
  const AMilliseconds: QWord): TRecordLockOutcome;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    Result := TryRecordLock(AHandle);
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

{ The owner record of the lock file at APath, read without locking it. }
function ReadOwnerRecordAt(const APath: string): TOwnerRecord;
var Handle: TLockHandle;
begin
  Result := ParseOwnerRecord('');
  try
    if not OpenLockFile(APath, Handle) then Exit;
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

function PIDText(const ARecord: TOwnerRecord): string;
begin
  if ARecord.PID <> '' then Result := ARecord.PID
  else Result := 'unknown';
end;

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
begin
  ReleaseOwnership;
  inherited Destroy;
end;

procedure TLWPTInstallLock.Acquire(const AReclaim: Boolean);
var
  Attempt: Integer;
  Handle: TLockHandle;
  Directory: string;
  Existing: TOwnerRecord;
begin
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
        + 'lock only once its owner has exited.',
        [HolderDescription(Existing), PIDText(Existing), PROGRAM_NAME]);
    end;
    if TryReclaimExisting then Exit;
    Sleep(RECORD_LOCK_POLL_MILLISECONDS);
  end;
  raise EConcurrencyError.CreateFmt(
    'the install lock %s kept changing while it was examined; nothing was '
    + 'changed. Run the command again.', [FPath]);
end;

procedure TLWPTInstallLock.TakeOwnership;
var Outcome: TRecordLockOutcome;
begin
  Outcome := RecordLockWithin(FHandle, OWNER_RECORD_LOCK_WAIT_MILLISECONDS);
  if Outcome = rlHeld then
  begin
    { Only a repair that found this file abandoned holds its record lock
      this long, and the file is then no longer this process's to remove. }
    CloseLockHandle(FHandle);
    FHandle := NO_HANDLE;
    raise EConcurrencyError.CreateFmt(
      'another process took over the install lock %s while this %s %s '
      + 'was creating it', [FPath, PROGRAM_NAME, FHolder]);
  end;
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
  RecordedPID: LongInt;
begin
  Result := False;
  if not OpenLockFile(FPath, Handle) then Exit;
  try
    Outcome := RecordLockWithin(Handle, PROBE_RECORD_LOCK_WAIT_MILLISECONDS);
    Existing := ParseOwnerRecord(ReadOwnerText(Handle));
    if Outcome = rlHeld then
      raise EConcurrencyError.CreateFmt(
        'the install lock %s is held by a running %s (PID %s); repair '
        + 'changed nothing. Run it again once that process has finished.',
        [FPath, HolderDescription(Existing), PIDText(Existing)]);
    { Released or replaced since it was opened: start over. }
    if not HandleNamesPath(Handle, FPath) then Exit;
    RecordedPID := StrToIntDef(Existing.PID, 0);
    if not Existing.Complete then
    begin
      if OwnerRecordAgeSeconds(Handle) < INSTALL_LOCK_INCOMPLETE_GRACE_SECONDS
      then
        raise EConcurrencyError.CreateFmt(
          'the install lock %s is being created by another process; repair '
          + 'changed nothing. Run it again.', [FPath]);
    end
    else if RecordedPID = GetProcessID then
      raise EConcurrencyError.CreateFmt(
        'the install lock %s is held by this process', [FPath])
    else if not (Existing.RecordLocked and (Outcome = rlAcquired))
      and RecordedProcessRuns(RecordedPID) then
      { An owner that held no record lock (an older LWPT on Unix, or a
        filesystem without record locks) is dead only when its PID names
        no process. A reused PID therefore keeps the lock. }
      raise EConcurrencyError.CreateFmt(
        'the install lock %s names PID %s, which is still running, and '
        + 'holds no lock that would show whether that process owns it; '
        + 'repair changed nothing. If PID %s is not an %s install or '
        + 'repair (its PID was reused), delete %s and run repair again.',
        [FPath, Existing.PID, Existing.PID, PROGRAM_NAME, FPath]);
    { The owner is dead. Adopt its file under the record lock: the path
      never stops existing, so no install can create a lock meanwhile. }
    FReclaimed := True;
    FReclaimedPID := Existing.PID;
    FHandle := Handle;
    Handle := NO_HANDLE;
    WriteOwnerRecord(Outcome = rlAcquired);
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

end.
