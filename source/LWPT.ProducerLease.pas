{ LWPT.ProducerLease — per-object local producer coordination.

  A lease holds an operating-system file lock for the producer lifetime and
  publishes heartbeat metadata only for diagnostics. The guard, rather than
  process identifiers or timestamps, is the liveness authority: a crashed
  process releases it automatically, while a healthy long-running producer
  cannot be displaced because a heartbeat write was delayed. }
unit LWPT.ProducerLease;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core;

const
  PRODUCER_LEASE_STALE_SECONDS_ENV = PROJECT_NAME
    + '_PRODUCER_LEASE_STALE_SECONDS';
  PRODUCER_LEASE_POLL_MILLISECONDS = 100;
  PRODUCER_LEASE_PROGRESS_MILLISECONDS = 5000;

type
  ELWPTProducerLeaseError = class(ELWPTError);

  TLWPTProducerLeaseSnapshot = record
    ObjectKey: string;
    Description: string;
    ProcessId: Integer;
    StartedAt: Int64;
    HeartbeatAt: Int64;
    HeartbeatStale: Boolean;
  end;

  TLWPTProducerLease = class
  private
    FDescription: string;
    FGuard: TObject;
    FHeartbeat: TThread;
    FKeyDigest: string;
    FObjectKey: string;
    FRoot: string;
    FStartedAt: Int64;
    FToken: string;
    FClosed: Boolean;
    FCriticalSection: TRTLCriticalSection;
    FCriticalSectionReady: Boolean;
    function IsClosed: Boolean;
    procedure TouchHeartbeat;
    procedure WriteState(const AHeartbeatAt: Int64);
  public
    destructor Destroy; override;
    property Description: string read FDescription;
    property ObjectKey: string read FObjectKey;
  end;

  TLWPTProducerLeaseCoordinator = class
  private
    FRoot: string;
    function KeyDigest(const AObjectKey: string): string;
    function KeyRoot(const AKeyDigest: string): string;
  public
    constructor Create(const ARoot: string);
    function TryAcquireGuard(const AObjectKey: string): TObject;
    function TryAcquire(const AObjectKey,
      ADescription: string): TLWPTProducerLease;
    function Snapshot(const AObjectKey: string;
      out ASnapshot: TLWPTProducerLeaseSnapshot): Boolean;
    property Root: string read FRoot;
  end;

function ProducerLeaseRoot(const ACacheRoot: string): string;
function RepairProducerLeases(const ACacheRoot: string;
  out ALivePreserved: Integer): Integer;

implementation

uses
  DateUtils,
  {$IFDEF UNIX}
  BaseUnix,
  Unix
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows
  {$ENDIF};

const
  PRODUCER_LEASE_NAMESPACE = 'producer-leases';
  GUARD_FILE = 'owner.guard';
  STATE_FILE = 'state';
  STATE_SCHEMA = 1;
  STATE_MAX_BYTES = 64 * 1024;
  DEFAULT_STALE_SECONDS = 30;
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  FD_CLOEXEC_LWPT = 1;
  F_WRLCK_LWPT = 1;
  F_UNLCK_LWPT = 2;
  {$ELSE}
  FD_CLOEXEC_LWPT = FD_CLOEXEC;
  F_WRLCK_LWPT = F_WRLCK;
  F_UNLCK_LWPT = F_UNLCK;
  {$ENDIF}
  {$ENDIF}

type
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  TLWPTFlock = BaseUnix.FLock;
  {$ELSE}
  TLWPTFlock = TFlock;
  {$ENDIF}
  {$ENDIF}

  TLWPTProducerGuard = class
  private
    FPath: string;
    FRegistered: Boolean;
    {$IFDEF UNIX}
    FDescriptor: LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    {$ENDIF}
  public
    class function TryCreate(const APath: string;
      out AGuard: TLWPTProducerGuard): Boolean;
    destructor Destroy; override;
  end;

  TLWPTProducerHeartbeat = class(TThread)
  private
    FOwner: TLWPTProducerLease;
    FIntervalMilliseconds: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLWPTProducerLease;
      AIntervalMilliseconds: Integer);
  end;

var
  LocalGuardCriticalSection: TRTLCriticalSection;
  LocalGuardPaths: TStringList;
  TokenCounter: LongInt = 0;

function NowMilliseconds: Int64;
var
  Current: TDateTime;
begin
  Current := Now;
  Result := DateTimeToUnix(Current, False) * 1000
    + MilliSecondOfTheSecond(Current);
end;

function StaleSeconds: Integer;
var
  Raw: string;
begin
  Raw := Trim(SysUtils.GetEnvironmentVariable(
    PRODUCER_LEASE_STALE_SECONDS_ENV));
  if Raw = '' then Exit(DEFAULT_STALE_SECONDS);
  Result := StrToIntDef(Raw, 0);
  if Result < 3 then
    raise ELWPTProducerLeaseError.CreateFmt(
      '%s must be at least 3 seconds, got "%s"',
      [PRODUCER_LEASE_STALE_SECONDS_ENV, Raw]);
end;

function EnsureDirectory(const APath: string): Boolean;
var
  Attempt, Index, MaxAttempts: Integer;
begin
  MaxAttempts := 2;
  for Index := 1 to Length(APath) do
    if IsPathDelimiter(APath, Index) then Inc(MaxAttempts);
  for Attempt := 1 to MaxAttempts do
    if ForceDirectories(APath) or DirectoryExists(APath) then Exit(True);
  Result := False;
end;

function SanitizeDescription(const AValue: string): string;
begin
  Result := StringReplace(AValue, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
end;

function NewToken(const AKeyDigest: string): string;
var
  Sequence: LongInt;
begin
  Sequence := InterlockedIncrement(TokenCounter);
  Result := SHA256Hex(BytesOf(AKeyDigest + ':' + IntToStr(GetProcessID)
    + ':' + IntToStr(NowMilliseconds) + ':' + IntToStr(Sequence)));
end;

function RegisterLocalGuard(const APath: string): Boolean;
begin
  EnterCriticalSection(LocalGuardCriticalSection);
  try
    Result := LocalGuardPaths.IndexOf(APath) < 0;
    if Result then LocalGuardPaths.Add(APath);
  finally
    LeaveCriticalSection(LocalGuardCriticalSection);
  end;
end;

procedure UnregisterLocalGuard(const APath: string);
var
  Index: Integer;
begin
  EnterCriticalSection(LocalGuardCriticalSection);
  try
    Index := LocalGuardPaths.IndexOf(APath);
    if Index >= 0 then LocalGuardPaths.Delete(Index);
  finally
    LeaveCriticalSection(LocalGuardCriticalSection);
  end;
end;

{$IFDEF UNIX}
function AcquireDescriptorLock(const ADescriptor: LongInt;
  const APath: string): Boolean;
var
  ErrorCode: Integer;
  LockSpec: TLWPTFlock;
begin
  FillChar(LockSpec, SizeOf(LockSpec), 0);
  LockSpec.l_type := F_WRLCK_LWPT;
  LockSpec.l_whence := SEEK_SET;
  LockSpec.l_start := 0;
  LockSpec.l_len := 1;
  if FpFcntl(ADescriptor, F_SetLk, LockSpec) = 0 then Exit(True);
  ErrorCode := FpGetErrNo;
  if ErrorCode in [ESysEACCES, ESysEAGAIN] then Exit(False);
  raise ELWPTProducerLeaseError.CreateFmt(
    'failed to acquire producer guard at %s (system error %d)',
    [APath, ErrorCode]);
end;

procedure ReleaseDescriptorLock(const ADescriptor: LongInt);
var
  LockSpec: TLWPTFlock;
begin
  FillChar(LockSpec, SizeOf(LockSpec), 0);
  LockSpec.l_type := F_UNLCK_LWPT;
  LockSpec.l_whence := SEEK_SET;
  LockSpec.l_start := 0;
  LockSpec.l_len := 1;
  FpFcntl(ADescriptor, F_SetLk, LockSpec);
end;
{$ENDIF}

class function TLWPTProducerGuard.TryCreate(const APath: string;
  out AGuard: TLWPTProducerGuard): Boolean;
{$IFDEF MSWINDOWS}
var
  ErrorCode: DWORD;
  Overlapped: TOverlapped;
{$ENDIF}
begin
  Result := False;
  AGuard := nil;
  if not RegisterLocalGuard(APath) then Exit;
  AGuard := TLWPTProducerGuard.Create;
  AGuard.FPath := APath;
  AGuard.FRegistered := True;
  {$IFDEF UNIX}
  AGuard.FDescriptor := -1;
  AGuard.FDescriptor := FpOpen(PChar(APath), O_RDWR or O_CREAT, &600);
  if AGuard.FDescriptor < 0 then
  begin
    AGuard.Free;
    AGuard := nil;
    raise ELWPTProducerLeaseError.CreateFmt(
      'failed to open producer guard at %s', [APath]);
  end;
  if FpFcntl(AGuard.FDescriptor, F_SETFD, FD_CLOEXEC_LWPT) <> 0 then
  begin
    AGuard.Free;
    AGuard := nil;
    raise ELWPTProducerLeaseError.CreateFmt(
      'failed to protect producer guard from child inheritance at %s',
      [APath]);
  end;
  try
    Result := AcquireDescriptorLock(AGuard.FDescriptor, APath);
  except
    AGuard.Free;
    AGuard := nil;
    raise;
  end;
  if not Result then
  begin
    AGuard.Free;
    AGuard := nil;
    Exit;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  AGuard.FHandle := THandle(INVALID_HANDLE_VALUE);
  AGuard.FHandle := CreateFileW(PWideChar(UnicodeString(APath)),
    GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if AGuard.FHandle = THandle(INVALID_HANDLE_VALUE) then
  begin
    AGuard.Free;
    AGuard := nil;
    raise ELWPTProducerLeaseError.CreateFmt(
      'failed to open producer guard at %s', [APath]);
  end;
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  if not LockFileEx(AGuard.FHandle,
    LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY,
    0, 1, 0, Overlapped) then
  begin
    ErrorCode := GetLastError;
    AGuard.Free;
    AGuard := nil;
    if ErrorCode = ERROR_LOCK_VIOLATION then Exit;
    raise ELWPTProducerLeaseError.CreateFmt(
      'failed to acquire producer guard at %s (system error %d)',
      [APath, ErrorCode]);
  end;
  {$ENDIF}
  Result := True;
end;

destructor TLWPTProducerGuard.Destroy;
{$IFDEF MSWINDOWS}
var
  Overlapped: TOverlapped;
{$ENDIF}
begin
  {$IFDEF UNIX}
  if FDescriptor >= 0 then
  begin
    ReleaseDescriptorLock(FDescriptor);
    FpClose(FDescriptor);
    FDescriptor := -1;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if FHandle <> THandle(INVALID_HANDLE_VALUE) then
  begin
    FillChar(Overlapped, SizeOf(Overlapped), 0);
    UnlockFileEx(FHandle, 0, 1, 0, Overlapped);
    CloseHandle(FHandle);
    FHandle := THandle(INVALID_HANDLE_VALUE);
  end;
  {$ENDIF}
  if FRegistered then UnregisterLocalGuard(FPath);
  FRegistered := False;
  inherited Destroy;
end;

constructor TLWPTProducerHeartbeat.Create(AOwner: TLWPTProducerLease;
  AIntervalMilliseconds: Integer);
begin
  FOwner := AOwner;
  FIntervalMilliseconds := AIntervalMilliseconds;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TLWPTProducerHeartbeat.Execute;
var
  Waited: Integer;
begin
  while not Terminated do
  begin
    Waited := 0;
    while (not Terminated) and (Waited < FIntervalMilliseconds) do
    begin
      Sleep(100);
      Inc(Waited, 100);
    end;
    if Terminated then Break;
    try
      FOwner.TouchHeartbeat;
    except
      { Heartbeat metadata is diagnostic. A transient write failure cannot
        surrender the OS-held ownership guard. }
    end;
  end;
end;

function ProducerLeaseRoot(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + PRODUCER_LEASE_NAMESPACE;
end;

function TryDetachAbandonedKey(const AKeyRootPath, AQuarantinePath: string;
  var AGuard: TLWPTProducerGuard): Boolean;
{$IFDEF MSWINDOWS}
const
  MAX_RENAME_ATTEMPTS = 2;
var
  Attempt: Integer;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := SysUtils.RenameFile(AKeyRootPath, AQuarantinePath);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  { Windows refuses to rename a directory while its locked guard child is
    open. Releasing the guard is still race-safe: a producer that acquires it
    first keeps the directory rename from succeeding; a successful rename
    atomically detaches the old key before a producer can recreate its path. }
  AGuard.Free;
  AGuard := nil;
  for Attempt := 1 to MAX_RENAME_ATTEMPTS do
  begin
    if SysUtils.RenameFile(AKeyRootPath, AQuarantinePath) then Exit(True);
    if not TLWPTProducerGuard.TryCreate(
         IncludeTrailingPathDelimiter(AKeyRootPath) + GUARD_FILE,
         AGuard) then Exit(False);
    if Attempt < MAX_RENAME_ATTEMPTS then
    begin
      AGuard.Free;
      AGuard := nil;
    end;
  end;
  Result := False;
  {$ENDIF}
end;

function RepairProducerLeases(const ACacheRoot: string;
  out ALivePreserved: Integer): Integer;
var
  Guard: TLWPTProducerGuard;
  KeyRootPath, LeaseNamespaceRoot, LeaseRoot, PrefixPath,
    QuarantinePath: string;
  PrefixSearch, KeySearch: TSearchRec;
begin
  Result := 0;
  ALivePreserved := 0;
  LeaseNamespaceRoot := ProducerLeaseRoot(ACacheRoot);
  if IsDirSymlinkOrJunction(LeaseNamespaceRoot) then
  begin
    WipeDir(LeaseNamespaceRoot);
    Inc(Result);
    Exit;
  end;
  if FileExists(LeaseNamespaceRoot) then
  begin
    if not SysUtils.DeleteFile(LeaseNamespaceRoot) then
      raise ELWPTProducerLeaseError.CreateFmt(
        'failed to remove invalid producer lease namespace at %s',
        [LeaseNamespaceRoot]);
    Inc(Result);
    Exit;
  end;
  LeaseRoot := IncludeTrailingPathDelimiter(LeaseNamespaceRoot)
    + 'sha256';
  if IsDirSymlinkOrJunction(LeaseRoot) then
  begin
    WipeDir(LeaseRoot);
    Inc(Result);
    Exit;
  end;
  if FileExists(LeaseRoot) then
  begin
    if not SysUtils.DeleteFile(LeaseRoot) then
      raise ELWPTProducerLeaseError.CreateFmt(
        'failed to remove invalid producer lease root at %s', [LeaseRoot]);
    Inc(Result);
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(LeaseRoot) + '*',
       faAnyFile or faSymLink,
       PrefixSearch) <> 0 then Exit;
  try
    repeat
      if (PrefixSearch.Name = '.') or (PrefixSearch.Name = '..') then Continue;
      if ((PrefixSearch.Attr and faSymLink) <> 0)
         or IsDirSymlinkOrJunction(IncludeTrailingPathDelimiter(LeaseRoot)
           + PrefixSearch.Name) then
      begin
        WipeDir(IncludeTrailingPathDelimiter(LeaseRoot) + PrefixSearch.Name);
        Inc(Result);
        Continue;
      end;
      if (PrefixSearch.Attr and faDirectory) = 0 then Continue;
      PrefixPath := IncludeTrailingPathDelimiter(LeaseRoot)
        + PrefixSearch.Name;
      if FindFirst(IncludeTrailingPathDelimiter(PrefixPath) + '*',
           faAnyFile or faSymLink, KeySearch) <> 0 then Continue;
      try
        repeat
          if (KeySearch.Name = '.') or (KeySearch.Name = '..') then Continue;
          if ((KeySearch.Attr and faSymLink) <> 0)
             or IsDirSymlinkOrJunction(
               IncludeTrailingPathDelimiter(PrefixPath) + KeySearch.Name) then
          begin
            WipeDir(IncludeTrailingPathDelimiter(PrefixPath) + KeySearch.Name);
            Inc(Result);
            Continue;
          end;
          if (KeySearch.Attr and faDirectory) = 0 then Continue;
          KeyRootPath := IncludeTrailingPathDelimiter(PrefixPath)
            + KeySearch.Name;
          Guard := nil;
          if not TLWPTProducerGuard.TryCreate(
               IncludeTrailingPathDelimiter(KeyRootPath) + GUARD_FILE,
               Guard) then
          begin
            Inc(ALivePreserved);
            Continue;
          end;
          try
            QuarantinePath := KeyRootPath + '.repair-'
              + NewToken(KeySearch.Name);
            if not TryDetachAbandonedKey(KeyRootPath, QuarantinePath,
                 Guard) then
            begin
              if Guard = nil then
              begin
                Inc(ALivePreserved);
                Continue;
              end;
              raise ELWPTProducerLeaseError.CreateFmt(
                'failed to isolate abandoned producer state at %s',
                [KeyRootPath]);
            end;
            if IsDirSymlinkOrJunction(QuarantinePath)
               or DirectoryExists(QuarantinePath) then
              WipeDir(QuarantinePath)
            else if FileExists(QuarantinePath)
               and not SysUtils.DeleteFile(QuarantinePath) then
              raise ELWPTProducerLeaseError.CreateFmt(
                'failed to remove isolated producer state at %s',
                [QuarantinePath]);
            Inc(Result);
          finally
            Guard.Free;
          end;
        until FindNext(KeySearch) <> 0;
      finally
        SysUtils.FindClose(KeySearch);
      end;
    until FindNext(PrefixSearch) <> 0;
  finally
    SysUtils.FindClose(PrefixSearch);
  end;
end;

constructor TLWPTProducerLeaseCoordinator.Create(const ARoot: string);
begin
  inherited Create;
  if ARoot = '' then
    raise ELWPTProducerLeaseError.Create(
      'producer-lease root cannot be empty');
  FRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
  if IsDirSymlinkOrJunction(FRoot) then
    raise ELWPTProducerLeaseError.Create(
      'producer-lease namespace root must not be a link');
end;

function TLWPTProducerLeaseCoordinator.KeyDigest(
  const AObjectKey: string): string;
begin
  if AObjectKey = '' then
    raise ELWPTProducerLeaseError.Create(
      'producer object key cannot be empty');
  Result := SHA256Hex(BytesOf(AObjectKey));
end;

function TLWPTProducerLeaseCoordinator.KeyRoot(
  const AKeyDigest: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + 'sha256/'
    + Copy(AKeyDigest, 1, 2) + '/' + Copy(AKeyDigest, 3, MaxInt);
end;

procedure EnsureLeaseDirectory(const ARoot, ADigest: string;
  out AKeyDirectory: string);
var
  PrefixDirectory, SHA256Directory: string;
begin
  SHA256Directory := IncludeTrailingPathDelimiter(ARoot) + 'sha256';
  PrefixDirectory := IncludeTrailingPathDelimiter(SHA256Directory)
    + Copy(ADigest, 1, 2);
  AKeyDirectory := IncludeTrailingPathDelimiter(PrefixDirectory)
    + Copy(ADigest, 3, MaxInt);
  if IsDirSymlinkOrJunction(ARoot)
     or IsDirSymlinkOrJunction(SHA256Directory)
     or IsDirSymlinkOrJunction(PrefixDirectory)
     or IsDirSymlinkOrJunction(AKeyDirectory) then
    raise ELWPTProducerLeaseError.Create(
      'producer-lease state must not traverse a link');
  if not EnsureDirectory(AKeyDirectory) then
    raise ELWPTProducerLeaseError.CreateFmt(
      'failed to create producer-lease directory at %s', [AKeyDirectory]);
  if IsDirSymlinkOrJunction(ARoot)
     or IsDirSymlinkOrJunction(SHA256Directory)
     or IsDirSymlinkOrJunction(PrefixDirectory)
     or IsDirSymlinkOrJunction(AKeyDirectory) then
    raise ELWPTProducerLeaseError.Create(
      'producer-lease state became a link');
end;

function TLWPTProducerLeaseCoordinator.TryAcquireGuard(
  const AObjectKey: string): TObject;
var
  Guard: TLWPTProducerGuard;
  Digest, KeyDirectory: string;
begin
  Result := nil;
  Digest := KeyDigest(AObjectKey);
  EnsureLeaseDirectory(FRoot, Digest, KeyDirectory);
  Guard := nil;
  if TLWPTProducerGuard.TryCreate(
       IncludeTrailingPathDelimiter(KeyDirectory) + GUARD_FILE,
       Guard) then
    Result := Guard;
end;

function TLWPTProducerLeaseCoordinator.TryAcquire(const AObjectKey,
  ADescription: string): TLWPTProducerLease;
var
  Guard: TLWPTProducerGuard;
  KeyDirectory, Digest: string;
  Interval: Integer;
begin
  Result := nil;
  Digest := KeyDigest(AObjectKey);
  EnsureLeaseDirectory(FRoot, Digest, KeyDirectory);
  Guard := nil;
  if not TLWPTProducerGuard.TryCreate(
       IncludeTrailingPathDelimiter(KeyDirectory) + GUARD_FILE,
       Guard) then Exit;
  Result := TLWPTProducerLease.Create;
  try
    Result.FRoot := KeyDirectory;
    Result.FKeyDigest := Digest;
    Result.FObjectKey := AObjectKey;
    Result.FDescription := SanitizeDescription(ADescription);
    Result.FGuard := Guard;
    Guard := nil;
    Result.FStartedAt := NowMilliseconds;
    Result.FToken := NewToken(Digest);
    Result.FClosed := False;
    InitCriticalSection(Result.FCriticalSection);
    Result.FCriticalSectionReady := True;
    Result.WriteState(Result.FStartedAt);
    Interval := (StaleSeconds * 1000) div 3;
    if Interval < 1000 then Interval := 1000;
    Result.FHeartbeat := TLWPTProducerHeartbeat.Create(Result, Interval);
    Result.FHeartbeat.Start;
  except
    Result.Free;
    Result := nil;
    Guard.Free;
    raise;
  end;
end;

function ReadSmallTextFile(const APath: string; out AText: string): Boolean;
var
  Bytes: TBytes;
  Stream: TFileStream;
begin
  Result := False;
  AText := '';
  if not FileExists(APath) then Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > STATE_MAX_BYTES then Exit;
    SetLength(Bytes, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Bytes[0], Stream.Size);
  finally
    Stream.Free;
  end;
  SetLength(AText, Length(Bytes));
  if Length(Bytes) > 0 then Move(Bytes[0], AText[1], Length(Bytes));
  Result := True;
end;

function TLWPTProducerLeaseCoordinator.Snapshot(const AObjectKey: string;
  out ASnapshot: TLWPTProducerLeaseSnapshot): Boolean;
var
  Digest, StateText: string;
  Lines: TStringList;
begin
  Result := False;
  ASnapshot := Default(TLWPTProducerLeaseSnapshot);
  Digest := KeyDigest(AObjectKey);
  if not ReadSmallTextFile(IncludeTrailingPathDelimiter(KeyRoot(Digest))
       + STATE_FILE, StateText) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := StateText;
    if StrToIntDef(Lines.Values['schema'], 0) <> STATE_SCHEMA then Exit;
    if Lines.Values['key'] <> Digest then Exit;
    ASnapshot.ObjectKey := AObjectKey;
    ASnapshot.Description := Lines.Values['description'];
    ASnapshot.ProcessId := StrToIntDef(Lines.Values['pid'], 0);
    ASnapshot.StartedAt := StrToInt64Def(Lines.Values['started'], 0);
    ASnapshot.HeartbeatAt := StrToInt64Def(
      Lines.Values['heartbeat'], 0);
    if (ASnapshot.ProcessId <= 0) or (ASnapshot.StartedAt <= 0)
       or (ASnapshot.HeartbeatAt <= 0) then Exit;
    ASnapshot.HeartbeatStale := NowMilliseconds
      - ASnapshot.HeartbeatAt > Int64(StaleSeconds) * 1000;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function TLWPTProducerLease.IsClosed: Boolean;
begin
  if not FCriticalSectionReady then Exit(FClosed);
  EnterCriticalSection(FCriticalSection);
  try
    Result := FClosed;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TLWPTProducerLease.WriteState(const AHeartbeatAt: Int64);
var
  Lines: TStringList;
  TemporaryRoot: string;
begin
  TemporaryRoot := IncludeTrailingPathDelimiter(FRoot) + 'tmp';
  EnsureDirectory(TemporaryRoot);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema=' + IntToStr(STATE_SCHEMA));
    Lines.Add('key=' + FKeyDigest);
    Lines.Add('description=' + FDescription);
    Lines.Add('pid=' + IntToStr(GetProcessID));
    Lines.Add('started=' + IntToStr(FStartedAt));
    Lines.Add('heartbeat=' + IntToStr(AHeartbeatAt));
    Lines.Add('token=' + FToken);
    AtomicWriteText(IncludeTrailingPathDelimiter(FRoot) + STATE_FILE,
      TemporaryRoot, Lines);
  finally
    Lines.Free;
  end;
end;

procedure TLWPTProducerLease.TouchHeartbeat;
begin
  if IsClosed then Exit;
  WriteState(NowMilliseconds);
end;

destructor TLWPTProducerLease.Destroy;
begin
  if FCriticalSectionReady then
  begin
    EnterCriticalSection(FCriticalSection);
    try
      FClosed := True;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
  end
  else
    FClosed := True;
  if FHeartbeat <> nil then
  begin
    FHeartbeat.Terminate;
    FHeartbeat.WaitFor;
    FHeartbeat.Free;
    FHeartbeat := nil;
  end;
  if FRoot <> '' then
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FRoot) + STATE_FILE);
  FGuard.Free;
  FGuard := nil;
  if FCriticalSectionReady then
  begin
    DoneCriticalSection(FCriticalSection);
    FCriticalSectionReady := False;
  end;
  inherited Destroy;
end;

initialization
  InitCriticalSection(LocalGuardCriticalSection);
  LocalGuardPaths := TStringList.Create;
  LocalGuardPaths.CaseSensitive := {$IFDEF MSWINDOWS}False{$ELSE}True{$ENDIF};
  LocalGuardPaths.Sorted := True;

finalization
  LocalGuardPaths.Free;
  DoneCriticalSection(LocalGuardCriticalSection);

end.
