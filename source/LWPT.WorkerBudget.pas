{ LWPT.WorkerBudget — per-user machine-wide worker coordination.

  This module deliberately does not schedule builds or tests. It provides
  the reclaimable capacity leases those schedulers consume. State is shared
  between worktrees through the user's application-config directory and every
  mutation is protected by a short OS-released transaction lock. }
unit LWPT.WorkerBudget;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core;

const
  WORKER_BUDGET_ENV = PROJECT_NAME + '_WORKER_BUDGET';
  WORKER_STATE_DIR_ENV = PROJECT_NAME + '_WORKER_STATE_DIR';
  WORKER_STALE_SECONDS_ENV = PROJECT_NAME
    + '_WORKER_LEASE_STALE_SECONDS';
  WORKER_LEASE_TOKEN_ENV = PROJECT_NAME + '_WORKER_LEASE_TOKEN';

type
  ELWPTWorkerBudgetError = class(ELWPTError);

  TLWPTWorkerBudgetEntry = record
    SessionId : string;
    ProcessId : Integer;
    Requested : Integer;
    Granted : Integer;
    Waiting : Boolean;
    StartedAt : Int64;
    HeartbeatAt : Int64;
    LeaseStartedAt : Int64;
    WaitTicket : Int64;
    LeaseTokens : string;
    Delegations : string;
    Uncertain : Boolean;
  end;
  TLWPTWorkerBudgetEntryArray = array of TLWPTWorkerBudgetEntry;

  TLWPTWorkerBudgetSnapshot = record
    StateRoot : string;
    EffectiveBudget : Integer;
    ActiveWorkers : Integer;
    WaitingInvocations : Integer;
    Entries : TLWPTWorkerBudgetEntryArray;
  end;

  TLWPTWorkerBudgetSession = class;

  TLWPTWorkerLease = class
  private
    FOwner : TLWPTWorkerBudgetSession;
    FReleased : Boolean;
    FToken : string;
    FDelegated : Boolean;
    procedure Detach;
  public
    constructor Create(AOwner: TLWPTWorkerBudgetSession; const AToken: string);
    destructor Destroy; override;
    procedure Release;
  end;

  TLWPTWorkerBudgetSession = class
  private
    FSessionId : string;
    FRequested : Integer;
    FEffectiveBudget : Integer;
    FLocalGranted : Integer;
    FHeartbeat : TThread;
    FOwnerGuard : TObject;
    FLeases : TList;
    FRegistered : Boolean;
    FClosed : Boolean;
    FInherited : Boolean;
    FInheritedToken : string;
    FLocalCriticalSection : TRTLCriticalSection;
    FAcquireCriticalSection : TRTLCriticalSection;
    FLocalCriticalSectionReady : Boolean;
    FAcquireCriticalSectionReady : Boolean;
    procedure TouchHeartbeat;
    procedure ReleaseLease(ALease: TLWPTWorkerLease);
    procedure AbandonLease(ALease: TLWPTWorkerLease);
    function CreateDelegation(ALease: TLWPTWorkerLease): string;
    function IsClosed: Boolean;
    function GetGrantedWorkers: Integer;
  public
    constructor Create(const ASessionId: string; ARequestedWorkers: Integer);
    destructor Destroy; override;
    function Acquire(ATimeoutMilliseconds: Integer = -1): TLWPTWorkerLease;
    property SessionId: string read FSessionId;
    property RequestedWorkers: Integer read FRequested;
    property EffectiveBudget: Integer read FEffectiveBudget;
    property GrantedWorkers: Integer read GetGrantedWorkers;
  end;

function NewWorkerSessionId: string;
function WorkerStateRoot: string;
function GetWorkerBudgetSnapshot: TLWPTWorkerBudgetSnapshot;
function RepairWorkerBudget: Integer;
procedure AppendWorkerBudgetDiagnostics(AOutput: TStrings;
  const ASnapshot: TLWPTWorkerBudgetSnapshot);
procedure AppendWorkerLeaseEnvironment(AEnvironment: TStrings;
  ALease: TLWPTWorkerLease);
procedure ClearWorkerLeaseEnvironment;

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
  REQUEST_EXTENSION = '.request';
  OWNER_EXTENSION = '.owner';
  TRANSACTION_LOCK_FILE = 'transaction.lock';
  BUDGET_FILE = 'budget';
  QUEUE_FILE = 'queue-sequence';
  STATE_TMP_DIR = 'tmp';
  REQUEST_SCHEMA = 3;
  DEFAULT_STALE_SECONDS = 30;
  ACQUIRE_POLL_MILLISECONDS = 50;
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

  TLWPTWorkerStateTransaction = class
  private
    FCriticalEntered : Boolean;
    FFileLocked : Boolean;
    {$IFDEF UNIX}
    FDescriptor : LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle : THandle;
    {$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TLWPTWorkerOwnerGuard = class
  private
    FPath : string;
    FLocked : Boolean;
    FRegistered : Boolean;
    {$IFDEF UNIX}
    FDescriptor : LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle : THandle;
    {$ENDIF}
  public
    constructor Create(const ASessionId: string);
    destructor Destroy; override;
  end;

  TLWPTWorkerHeartbeat = class(TThread)
  private
    FOwner : TLWPTWorkerBudgetSession;
    FIntervalMilliseconds : Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLWPTWorkerBudgetSession;
      AIntervalMilliseconds: Integer);
  end;

var
  WorkerStateCriticalSection : TRTLCriticalSection;
  LocalOwnerCriticalSection : TRTLCriticalSection;
  LocalOwnerSessions : TStringList;
  SessionCounter : Integer = 0;

function LocalOwnerHeld(const ASessionId: string): Boolean;
begin
  EnterCriticalSection(LocalOwnerCriticalSection);
  try
    Result := LocalOwnerSessions.IndexOf(ASessionId) >= 0;
  finally
    LeaveCriticalSection(LocalOwnerCriticalSection);
  end;
end;

procedure RegisterLocalOwner(const ASessionId: string);
begin
  EnterCriticalSection(LocalOwnerCriticalSection);
  try
    if LocalOwnerSessions.IndexOf(ASessionId) >= 0 then
      raise ELWPTWorkerBudgetError.CreateFmt(
        'worker session "%s" already has a live owner', [ASessionId]);
    LocalOwnerSessions.Add(ASessionId);
  finally
    LeaveCriticalSection(LocalOwnerCriticalSection);
  end;
end;

procedure UnregisterLocalOwner(const ASessionId: string);
var
  Index : Integer;
begin
  EnterCriticalSection(LocalOwnerCriticalSection);
  try
    Index := LocalOwnerSessions.IndexOf(ASessionId);
    if Index >= 0 then LocalOwnerSessions.Delete(Index);
  finally
    LeaveCriticalSection(LocalOwnerCriticalSection);
  end;
end;

{$IFDEF UNIX}
function AcquireDescriptorLock(ADescriptor: LongInt;
  AWait: Boolean): Boolean;
var
  LockSpec : TLWPTFlock;
  ErrorCode : Integer;
begin
  repeat
    FillChar(LockSpec, SizeOf(LockSpec), 0);
    LockSpec.l_type := F_WRLCK_LWPT;
    LockSpec.l_whence := SEEK_SET;
    LockSpec.l_start := 0;
    LockSpec.l_len := 1;
    if FpFcntl(ADescriptor, F_SetLk, LockSpec) = 0 then Exit(True);
    ErrorCode := FpGetErrNo;
    if (not AWait)
       or not (ErrorCode in [ESysEACCES, ESysEAGAIN]) then
      Exit(False);
    Sleep(10);
  until False;
end;

procedure ReleaseDescriptorLock(ADescriptor: LongInt);
var
  LockSpec : TLWPTFlock;
begin
  FillChar(LockSpec, SizeOf(LockSpec), 0);
  LockSpec.l_type := F_UNLCK_LWPT;
  LockSpec.l_whence := SEEK_SET;
  LockSpec.l_start := 0;
  LockSpec.l_len := 1;
  FpFcntl(ADescriptor, F_SetLk, LockSpec);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function BCryptGenRandom(AAlgorithm: THandle; ABuffer: Pointer;
  ALength, AFlags: ULONG): LongInt; stdcall;
  external 'bcrypt.dll' name 'BCryptGenRandom';
{$ENDIF}
{$IFDEF UNIX}
function CUnsetEnvironmentVariable(AName: PAnsiChar): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'unsetenv';
  {$ELSE}
  external name 'unsetenv';
  {$ENDIF}
{$ENDIF}

procedure ClearWorkerLeaseEnvironment;
{$IFDEF UNIX}
var
  Name: AnsiString;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Name: UnicodeString;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Name := AnsiString(WORKER_LEASE_TOKEN_ENV);
  if CUnsetEnvironmentVariable(PAnsiChar(Name)) <> 0 then
    raise ELWPTWorkerBudgetError.CreateFmt(
      'failed to clear consumed %s from the process environment',
      [WORKER_LEASE_TOKEN_ENV]);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Name := UnicodeString(WORKER_LEASE_TOKEN_ENV);
  if not Windows.SetEnvironmentVariableW(PWideChar(Name), nil) then
    raise ELWPTWorkerBudgetError.CreateFmt(
      'failed to clear consumed %s from the process environment',
      [WORKER_LEASE_TOKEN_ENV]);
  {$ENDIF}
end;

function NowMilliseconds: Int64;
var
  Current : TDateTime;
begin
  Current := Now;
  Result := DateTimeToUnix(Current, False) * 1000
          + MilliSecondOfTheSecond(Current);
end;

function WorkerStateRoot: string;
begin
  Result := SysUtils.GetEnvironmentVariable(WORKER_STATE_DIR_ENV);
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'workers';
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Result));
end;

function StatePath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(WorkerStateRoot) + AName;
end;

function RequestPath(const ASessionId: string): string;
begin
  Result := StatePath(ASessionId + REQUEST_EXTENSION);
end;

function OwnerPath(const ASessionId: string): string;
begin
  Result := StatePath(ASessionId + OWNER_EXTENSION);
end;

procedure RemoveRequestPath(const ASessionId: string);
var
  Path : string;
begin
  Path := RequestPath(ASessionId);
  if DirectoryExists(Path) then WipeDir(Path)
  else SysUtils.DeleteFile(Path);
end;

function ValidSessionId(const AValue: string): Boolean;
var
  i : Integer;
begin
  Result := AValue <> '';
  if not Result then Exit;
  for i := 1 to Length(AValue) do
    if not (AValue[i] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.']) then
      Exit(False);
end;

function ValidLeaseToken(const AValue: string): Boolean;
var
  i : Integer;
begin
  Result := Length(AValue) = 64;
  if not Result then Exit;
  for i := 1 to Length(AValue) do
    if not (AValue[i] in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function NewOpaqueToken: string;
var
  Bytes : TBytes;
  {$IFDEF UNIX}
  Stream : TFileStream;
  {$ENDIF}
begin
  SetLength(Bytes, 32);
  {$IFDEF UNIX}
  Stream := TFileStream.Create('/dev/urandom',
    fmOpenRead or fmShareDenyNone);
  try
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if BCryptGenRandom(0, @Bytes[0], Length(Bytes), $00000002) <> 0 then
    raise ELWPTWorkerBudgetError.Create(
      'failed to obtain secure randomness for worker lease');
  {$ENDIF}
  Result := SHA256Hex(Bytes);
end;

function NextComma(const AValue: string; AStartAt: Integer): Integer;
begin
  Result := Pos(',', Copy(AValue, AStartAt, MaxInt));
  if Result > 0 then Inc(Result, AStartAt - 1);
end;

function LeaseTokenCount(const AValue: string): Integer;
var
  StartAt, Separator : Integer;
  Token : string;
begin
  Result := 0;
  if AValue = '' then Exit;
  StartAt := 1;
  repeat
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then
      Token := Copy(AValue, StartAt, MaxInt)
    else
      Token := Copy(AValue, StartAt, Separator - StartAt);
    if not ValidLeaseToken(Token) then Exit(-1);
    Inc(Result);
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  until False;
end;

function LeaseTokenDigest(const AToken: string): string;
begin
  if not ValidLeaseToken(AToken) then
    raise ELWPTWorkerBudgetError.Create('invalid worker lease token');
  Result := SHA256Hex(BytesOf(AToken));
end;

function HasLeaseToken(const AValue, AToken: string): Boolean;
begin
  Result := Pos(',' + LeaseTokenDigest(AToken) + ',',
    ',' + AValue + ',') > 0;
end;

procedure AddLeaseToken(var AValue: string; const AToken: string);
var
  Digest : string;
begin
  Digest := LeaseTokenDigest(AToken);
  if Pos(',' + Digest + ',', ',' + AValue + ',') > 0 then
    raise ELWPTWorkerBudgetError.Create('duplicate worker lease token');
  if AValue = '' then AValue := Digest
  else AValue := AValue + ',' + Digest;
end;

function RemoveLeaseToken(var AValue: string; const AToken: string): Boolean;
var
  StartAt, Separator : Integer;
  Token, Updated, Digest : string;
begin
  Result := False;
  Digest := LeaseTokenDigest(AToken);
  Updated := '';
  StartAt := 1;
  while (AValue <> '') and (StartAt <= Length(AValue)) do
  begin
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then
      Token := Copy(AValue, StartAt, MaxInt)
    else
      Token := Copy(AValue, StartAt, Separator - StartAt);
    if Token = Digest then
      Result := True
    else if Updated = '' then
      Updated := Token
    else
      Updated := Updated + ',' + Token;
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  end;
  if Result then AValue := Updated;
end;

function ValidDelegations(const AValue: string): Boolean;
var
  StartAt, Separator, EqualsAt : Integer;
  Item, DelegationDigest, LeaseDigest : string;
begin
  Result := True;
  if AValue = '' then Exit;
  StartAt := 1;
  while StartAt <= Length(AValue) do
  begin
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then Item := Copy(AValue, StartAt, MaxInt)
    else Item := Copy(AValue, StartAt, Separator - StartAt);
    EqualsAt := Pos('=', Item);
    if EqualsAt <> 65 then Exit(False);
    DelegationDigest := Copy(Item, 1, EqualsAt - 1);
    LeaseDigest := Copy(Item, EqualsAt + 1, MaxInt);
    if not ValidLeaseToken(DelegationDigest)
       or not ValidLeaseToken(LeaseDigest) then Exit(False);
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  end;
end;

function FindDelegation(const AValue, ADelegationToken: string;
  out ALeaseDigest: string): Boolean;
var
  StartAt, Separator, EqualsAt : Integer;
  Item, Wanted : string;
begin
  Result := False;
  ALeaseDigest := '';
  Wanted := LeaseTokenDigest(ADelegationToken);
  StartAt := 1;
  while (AValue <> '') and (StartAt <= Length(AValue)) do
  begin
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then Item := Copy(AValue, StartAt, MaxInt)
    else Item := Copy(AValue, StartAt, Separator - StartAt);
    EqualsAt := Pos('=', Item);
    if (EqualsAt > 0) and (Copy(Item, 1, EqualsAt - 1) = Wanted) then
    begin
      ALeaseDigest := Copy(Item, EqualsAt + 1, MaxInt);
      Exit(True);
    end;
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  end;
end;

function LeaseHasDelegation(const AValue,
  ALeaseDigest: string): Boolean;
begin
  Result := Pos('=' + ALeaseDigest + ',', AValue + ',') > 0;
end;

procedure AddDelegation(var AValue: string;
  const ADelegationToken, ALeaseDigest: string);
var
  Item : string;
begin
  if not ValidLeaseToken(ALeaseDigest) then
    raise ELWPTWorkerBudgetError.Create('invalid delegated lease verifier');
  Item := LeaseTokenDigest(ADelegationToken) + '=' + ALeaseDigest;
  if AValue = '' then AValue := Item
  else AValue := AValue + ',' + Item;
end;

function RemoveDelegation(var AValue: string;
  const ADelegationToken: string): Boolean;
var
  StartAt, Separator, EqualsAt : Integer;
  Item, Updated, Wanted : string;
begin
  Result := False;
  Updated := '';
  Wanted := LeaseTokenDigest(ADelegationToken);
  StartAt := 1;
  while (AValue <> '') and (StartAt <= Length(AValue)) do
  begin
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then Item := Copy(AValue, StartAt, MaxInt)
    else Item := Copy(AValue, StartAt, Separator - StartAt);
    EqualsAt := Pos('=', Item);
    if (EqualsAt > 0) and (Copy(Item, 1, EqualsAt - 1) = Wanted) then
      Result := True
    else if Updated = '' then
      Updated := Item
    else
      Updated := Updated + ',' + Item;
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  end;
  if Result then AValue := Updated;
end;

procedure RemoveDelegationsForLease(var AValue: string;
  const ALeaseDigest: string);
var
  StartAt, Separator, EqualsAt : Integer;
  Item, Updated : string;
begin
  Updated := '';
  StartAt := 1;
  while (AValue <> '') and (StartAt <= Length(AValue)) do
  begin
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then Item := Copy(AValue, StartAt, MaxInt)
    else Item := Copy(AValue, StartAt, Separator - StartAt);
    EqualsAt := Pos('=', Item);
    if (EqualsAt = 0)
       or (Copy(Item, EqualsAt + 1, MaxInt) <> ALeaseDigest) then
    begin
      if Updated = '' then Updated := Item
      else Updated := Updated + ',' + Item;
    end;
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  end;
  AValue := Updated;
end;

function NewWorkerSessionId: string;
begin
  EnterCriticalSection(WorkerStateCriticalSection);
  try
    Inc(SessionCounter);
    Result := IntToStr(GetProcessID) + '-' + IntToStr(NowMilliseconds)
            + '-' + IntToStr(SessionCounter);
  finally
    LeaveCriticalSection(WorkerStateCriticalSection);
  end;
end;

function ConfiguredBudget: Integer;
var
  Raw : string;
begin
  Raw := Trim(SysUtils.GetEnvironmentVariable(WORKER_BUDGET_ENV));
  if Raw <> '' then
  begin
    Result := StrToIntDef(Raw, 0);
    if Result < 1 then
      raise ELWPTWorkerBudgetError.CreateFmt(
        '%s must be a positive integer, got "%s"',
        [WORKER_BUDGET_ENV, Raw]);
    Exit;
  end;
  Result := TThread.ProcessorCount;
  if Result < 1 then Result := 1;
end;

function StaleSeconds: Integer;
var
  Raw : string;
begin
  Raw := Trim(SysUtils.GetEnvironmentVariable(WORKER_STALE_SECONDS_ENV));
  if Raw = '' then
    Exit(DEFAULT_STALE_SECONDS);
  Result := StrToIntDef(Raw, 0);
  if Result < 3 then
    raise ELWPTWorkerBudgetError.CreateFmt(
      '%s must be at least 3 seconds, got "%s"',
      [WORKER_STALE_SECONDS_ENV, Raw]);
end;

constructor TLWPTWorkerStateTransaction.Create;
var
  LockPath : string;
  {$IFDEF MSWINDOWS}
  Overlapped : TOverlapped;
  {$ENDIF}
begin
  inherited Create;
  FCriticalEntered := False;
  FFileLocked := False;
  {$IFDEF UNIX}
  FDescriptor := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := THandle(INVALID_HANDLE_VALUE);
  {$ENDIF}
  EnterCriticalSection(WorkerStateCriticalSection);
  FCriticalEntered := True;
  try
    ForceDirectories(WorkerStateRoot);
    LockPath := StatePath(TRANSACTION_LOCK_FILE);
    {$IFDEF UNIX}
    FDescriptor := FpOpen(PChar(LockPath), O_RDWR or O_CREAT, &600);
    if FDescriptor < 0 then
      raise ELWPTWorkerBudgetError.CreateFmt(
        'failed to open worker-budget transaction lock at %s',
        [LockPath]);
    if FpFcntl(FDescriptor, F_SETFD, FD_CLOEXEC_LWPT) <> 0 then
    begin
      FpClose(FDescriptor);
      FDescriptor := -1;
      raise ELWPTWorkerBudgetError.CreateFmt(
        'failed to protect worker-budget transaction lock from child '
        + 'inheritance at %s', [LockPath]);
    end;
    if not AcquireDescriptorLock(FDescriptor, True) then
    begin
      FpClose(FDescriptor);
      FDescriptor := -1;
      raise ELWPTWorkerBudgetError.CreateFmt(
        'failed to acquire worker-budget transaction lock at %s',
        [LockPath]);
    end;
    FFileLocked := True;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle := CreateFileW(PWideChar(UnicodeString(LockPath)),
      GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if FHandle = THandle(INVALID_HANDLE_VALUE) then
      raise ELWPTWorkerBudgetError.CreateFmt(
        'failed to open worker-budget transaction lock at %s',
        [LockPath]);
    FillChar(Overlapped, SizeOf(Overlapped), 0);
    if not LockFileEx(FHandle, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0,
      Overlapped) then
    begin
      CloseHandle(FHandle);
      FHandle := THandle(INVALID_HANDLE_VALUE);
      raise ELWPTWorkerBudgetError.CreateFmt(
        'failed to acquire worker-budget transaction lock at %s',
        [LockPath]);
    end;
    FFileLocked := True;
    {$ENDIF}
  except
    {$IFDEF UNIX}
    if FDescriptor >= 0 then
    begin
      if FFileLocked then ReleaseDescriptorLock(FDescriptor);
      FpClose(FDescriptor);
      FDescriptor := -1;
    end;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    if FHandle <> THandle(INVALID_HANDLE_VALUE) then
    begin
      if FFileLocked then
      begin
        FillChar(Overlapped, SizeOf(Overlapped), 0);
        UnlockFileEx(FHandle, 0, 1, 0, Overlapped);
      end;
      CloseHandle(FHandle);
      FHandle := THandle(INVALID_HANDLE_VALUE);
    end;
    {$ENDIF}
    FFileLocked := False;
    if FCriticalEntered then
    begin
      LeaveCriticalSection(WorkerStateCriticalSection);
      FCriticalEntered := False;
    end;
    raise;
  end;
end;

destructor TLWPTWorkerStateTransaction.Destroy;
{$IFDEF MSWINDOWS}
var
  Overlapped : TOverlapped;
{$ENDIF}
begin
  {$IFDEF UNIX}
  if FDescriptor >= 0 then
  begin
    if FFileLocked then ReleaseDescriptorLock(FDescriptor);
    FpClose(FDescriptor);
    FDescriptor := -1;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if FHandle <> THandle(INVALID_HANDLE_VALUE) then
  begin
    if FFileLocked then
    begin
      FillChar(Overlapped, SizeOf(Overlapped), 0);
      UnlockFileEx(FHandle, 0, 1, 0, Overlapped);
    end;
    CloseHandle(FHandle);
    FHandle := THandle(INVALID_HANDLE_VALUE);
  end;
  {$ENDIF}
  FFileLocked := False;
  if FCriticalEntered then
  begin
    LeaveCriticalSection(WorkerStateCriticalSection);
    FCriticalEntered := False;
  end;
  inherited Destroy;
end;

constructor TLWPTWorkerOwnerGuard.Create(const ASessionId: string);
{$IFDEF MSWINDOWS}
var
  Overlapped : TOverlapped;
{$ENDIF}
begin
  inherited Create;
  FPath := OwnerPath(ASessionId);
  FLocked := False;
  FRegistered := False;
  {$IFDEF UNIX}
  FDescriptor := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := THandle(INVALID_HANDLE_VALUE);
  {$ENDIF}
  ForceDirectories(WorkerStateRoot);
  {$IFDEF UNIX}
  FDescriptor := FpOpen(PChar(FPath), O_RDWR or O_CREAT, &600);
  if FDescriptor < 0 then
    raise ELWPTWorkerBudgetError.CreateFmt(
      'failed to open worker owner guard at %s', [FPath]);
  if FpFcntl(FDescriptor, F_SETFD, FD_CLOEXEC_LWPT) <> 0 then
  begin
    FpClose(FDescriptor);
    FDescriptor := -1;
    raise ELWPTWorkerBudgetError.CreateFmt(
      'failed to protect worker owner guard from child inheritance at %s',
      [FPath]);
  end;
  if not AcquireDescriptorLock(FDescriptor, False) then
  begin
    FpClose(FDescriptor);
    FDescriptor := -1;
    raise ELWPTWorkerBudgetError.CreateFmt(
      'worker session "%s" already has a live owner', [ASessionId]);
  end;
  FLocked := True;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := CreateFileW(PWideChar(UnicodeString(FPath)),
    GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = THandle(INVALID_HANDLE_VALUE) then
    raise ELWPTWorkerBudgetError.CreateFmt(
      'failed to open worker owner guard at %s', [FPath]);
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  if not LockFileEx(FHandle,
    LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY,
    0, 1, 0, Overlapped) then
  begin
    CloseHandle(FHandle);
    FHandle := THandle(INVALID_HANDLE_VALUE);
    raise ELWPTWorkerBudgetError.CreateFmt(
      'worker session "%s" already has a live owner', [ASessionId]);
  end;
  FLocked := True;
  {$ENDIF}
  RegisterLocalOwner(ASessionId);
  FRegistered := True;
end;

destructor TLWPTWorkerOwnerGuard.Destroy;
{$IFDEF MSWINDOWS}
var
  Overlapped : TOverlapped;
{$ENDIF}
begin
  if FRegistered then UnregisterLocalOwner(
    ChangeFileExt(ExtractFileName(FPath), ''));
  {$IFDEF UNIX}
  if FDescriptor >= 0 then
  begin
    if FRegistered then
    begin
      SysUtils.DeleteFile(FPath);
    end;
    if FLocked then
    begin
      ReleaseDescriptorLock(FDescriptor);
    end;
    FpClose(FDescriptor);
    FDescriptor := -1;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if FHandle <> THandle(INVALID_HANDLE_VALUE) then
  begin
    if FRegistered then
    begin
      SysUtils.DeleteFile(FPath);
    end;
    if FLocked then
    begin
      FillChar(Overlapped, SizeOf(Overlapped), 0);
      UnlockFileEx(FHandle, 0, 1, 0, Overlapped);
    end;
    CloseHandle(FHandle);
    FHandle := THandle(INVALID_HANDLE_VALUE);
  end;
  {$ENDIF}
  FRegistered := False;
  FLocked := False;
  inherited Destroy;
end;

function OwnerGuardHeld(const ASessionId: string): Boolean;
{$IFDEF UNIX}
var
  Descriptor : LongInt;
  ErrorCode : Integer;
begin
  if LocalOwnerHeld(ASessionId) then Exit(True);
  Descriptor := FpOpen(PChar(OwnerPath(ASessionId)), O_RDWR);
  if Descriptor < 0 then
  begin
    ErrorCode := FpGetErrNo;
    Exit(ErrorCode <> ESysENOENT);
  end;
  try
    if AcquireDescriptorLock(Descriptor, False) then
    begin
      ReleaseDescriptorLock(Descriptor);
      Exit(False);
    end;
    Result := True;
  finally
    FpClose(Descriptor);
  end;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Handle : THandle;
  Overlapped : TOverlapped;
  ErrorCode : DWORD;
begin
  if LocalOwnerHeld(ASessionId) then Exit(True);
  Handle := CreateFileW(PWideChar(UnicodeString(OwnerPath(ASessionId))),
    GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = THandle(INVALID_HANDLE_VALUE) then
  begin
    ErrorCode := GetLastError;
    Exit(not (ErrorCode in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]));
  end;
  try
    FillChar(Overlapped, SizeOf(Overlapped), 0);
    if LockFileEx(Handle,
      LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY,
      0, 1, 0, Overlapped) then
    begin
      UnlockFileEx(Handle, 0, 1, 0, Overlapped);
      Exit(False);
    end;
    Result := True;
  finally
    CloseHandle(Handle);
  end;
end;
{$ENDIF}

function BoolText(AValue: Boolean): string;
begin
  if AValue then Result := '1' else Result := '0';
end;

function ReadEntry(const APath: string; out AEntry: TLWPTWorkerBudgetEntry): Boolean;
var
  Lines : TStringList;
begin
  Result := False;
  AEntry := Default(TLWPTWorkerBudgetEntry);
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(APath);
    except
      Exit;
    end;
    if StrToIntDef(Lines.Values['schema'], 0) <> REQUEST_SCHEMA then Exit;
    AEntry.SessionId := Lines.Values['session'];
    AEntry.ProcessId := StrToIntDef(Lines.Values['pid'], 0);
    AEntry.Requested := StrToIntDef(Lines.Values['requested'], 0);
    AEntry.Granted := StrToIntDef(Lines.Values['granted'], 0);
    AEntry.Waiting := Lines.Values['waiting'] = '1';
    AEntry.StartedAt := StrToInt64Def(Lines.Values['started'], 0);
    AEntry.HeartbeatAt := StrToInt64Def(Lines.Values['heartbeat'], 0);
    AEntry.LeaseStartedAt := StrToInt64Def(
      Lines.Values['lease-started'], 0);
    AEntry.WaitTicket := StrToInt64Def(Lines.Values['wait-ticket'], 0);
    AEntry.LeaseTokens := Lines.Values['lease-tokens'];
    AEntry.Delegations := Lines.Values['delegations'];
    Result := ValidSessionId(AEntry.SessionId)
          and (AEntry.ProcessId > 0)
          and (AEntry.Requested > 0)
          and (AEntry.Granted >= 0)
          and (AEntry.Granted <= AEntry.Requested)
          and (AEntry.StartedAt > 0)
          and (AEntry.HeartbeatAt > 0)
          and (LeaseTokenCount(AEntry.LeaseTokens) = AEntry.Granted)
          and ValidDelegations(AEntry.Delegations)
          and ((AEntry.Waiting and (AEntry.WaitTicket > 0))
            or ((not AEntry.Waiting) and (AEntry.WaitTicket = 0)));
  finally
    Lines.Free;
  end;
end;

procedure WriteEntry(const AEntry: TLWPTWorkerBudgetEntry);
var
  Lines : TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('schema=' + IntToStr(REQUEST_SCHEMA));
    Lines.Add('session=' + AEntry.SessionId);
    Lines.Add('pid=' + IntToStr(AEntry.ProcessId));
    Lines.Add('requested=' + IntToStr(AEntry.Requested));
    Lines.Add('granted=' + IntToStr(AEntry.Granted));
    Lines.Add('waiting=' + BoolText(AEntry.Waiting));
    Lines.Add('started=' + IntToStr(AEntry.StartedAt));
    Lines.Add('heartbeat=' + IntToStr(AEntry.HeartbeatAt));
    Lines.Add('lease-started=' + IntToStr(AEntry.LeaseStartedAt));
    Lines.Add('wait-ticket=' + IntToStr(AEntry.WaitTicket));
    Lines.Add('lease-tokens=' + AEntry.LeaseTokens);
    Lines.Add('delegations=' + AEntry.Delegations);
    AtomicWriteText(RequestPath(AEntry.SessionId),
      StatePath(STATE_TMP_DIR), Lines);
  finally
    Lines.Free;
  end;
end;

function ReadBudget: Integer; forward;

function ConservativeUnreadableEntry(
  const ASessionId: string): TLWPTWorkerBudgetEntry;
var
  Budget : Integer;
begin
  Result := Default(TLWPTWorkerBudgetEntry);
  Budget := ReadBudget;
  if Budget < 1 then Budget := ConfiguredBudget;
  Result.SessionId := ASessionId;
  Result.Requested := Budget;
  Result.Granted := Budget;
  Result.StartedAt := NowMilliseconds;
  Result.HeartbeatAt := Result.StartedAt;
  Result.LeaseStartedAt := Result.StartedAt;
  Result.Uncertain := True;
end;

function LoadEntriesWithReclaimed(
  out AReclaimed: Integer): TLWPTWorkerBudgetEntryArray;
var
  Search : TSearchRec;
  Entry : TLWPTWorkerBudgetEntry;
  Count : Integer;
  SessionId : string;
  EntryValid : Boolean;
begin
  AReclaimed := 0;
  SetLength(Result, 0);
  if FindFirst(StatePath('*' + REQUEST_EXTENSION), faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      SessionId := Copy(Search.Name, 1,
        Length(Search.Name) - Length(REQUEST_EXTENSION));
      EntryValid := (Search.Attr and faDirectory) = 0;
      if EntryValid then
        EntryValid := ReadEntry(StatePath(Search.Name), Entry);
      if EntryValid then
        EntryValid := Entry.SessionId = SessionId;
      if not EntryValid then
      begin
        if ValidSessionId(SessionId) and OwnerGuardHeld(SessionId) then
          Entry := ConservativeUnreadableEntry(SessionId)
        else
        begin
          if ValidSessionId(SessionId) then
            RemoveRequestPath(SessionId)
          else
            SysUtils.DeleteFile(StatePath(Search.Name));
          if ValidSessionId(SessionId) then
            SysUtils.DeleteFile(OwnerPath(SessionId));
          Inc(AReclaimed);
          Continue;
        end;
      end;
      Count := Length(Result);
      SetLength(Result, Count + 1);
      Result[Count] := Entry;
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function LoadEntries: TLWPTWorkerBudgetEntryArray;
var
  Ignored : Integer;
begin
  Result := LoadEntriesWithReclaimed(Ignored);
end;

function EntryReclaimable(const AEntry: TLWPTWorkerBudgetEntry): Boolean;
begin
  { Heartbeat age is diagnostic only. Without enforceable fencing, freeing
    capacity while the owner guard remains held could exceed the budget if
    that process resumes work. }
  Result := not OwnerGuardHeld(AEntry.SessionId);
end;

function PruneEntries(var AEntries: TLWPTWorkerBudgetEntryArray): Integer;
var
  i, Kept : Integer;
begin
  Result := 0;
  Kept := 0;
  for i := 0 to High(AEntries) do
  begin
    if EntryReclaimable(AEntries[i]) then
    begin
      RemoveRequestPath(AEntries[i].SessionId);
      if not OwnerGuardHeld(AEntries[i].SessionId) then
        SysUtils.DeleteFile(OwnerPath(AEntries[i].SessionId));
      Inc(Result);
      Continue;
    end;
    AEntries[Kept] := AEntries[i];
    Inc(Kept);
  end;
  SetLength(AEntries, Kept);
end;

function FindEntry(const AEntries: TLWPTWorkerBudgetEntryArray;
  const ASessionId: string): Integer;
var
  i : Integer;
begin
  for i := 0 to High(AEntries) do
    if AEntries[i].SessionId = ASessionId then Exit(i);
  Result := -1;
end;

function FindLeaseTokenEntry(const AEntries: TLWPTWorkerBudgetEntryArray;
  const AToken: string): Integer;
var
  i : Integer;
begin
  for i := 0 to High(AEntries) do
    if HasLeaseToken(AEntries[i].LeaseTokens, AToken) then Exit(i);
  Result := -1;
end;

function FindDelegationEntry(const AEntries: TLWPTWorkerBudgetEntryArray;
  const ADelegationToken: string; out ALeaseDigest: string): Integer;
var
  i : Integer;
begin
  ALeaseDigest := '';
  for i := 0 to High(AEntries) do
    if FindDelegation(AEntries[i].Delegations,
      ADelegationToken, ALeaseDigest) then Exit(i);
  Result := -1;
end;

function RemoveLeaseDigest(var AValue: string;
  const ADigest: string): Boolean;
var
  StartAt, Separator : Integer;
  Item, Updated : string;
begin
  Result := False;
  Updated := '';
  StartAt := 1;
  while (AValue <> '') and (StartAt <= Length(AValue)) do
  begin
    Separator := NextComma(AValue, StartAt);
    if Separator = 0 then Item := Copy(AValue, StartAt, MaxInt)
    else Item := Copy(AValue, StartAt, Separator - StartAt);
    if Item = ADigest then
      Result := True
    else if Updated = '' then
      Updated := Item
    else
      Updated := Updated + ',' + Item;
    if Separator = 0 then Break;
    StartAt := Separator + 1;
  end;
  if Result then AValue := Updated;
end;

function ActiveWorkerCount(const AEntries: TLWPTWorkerBudgetEntryArray): Integer;
var
  i : Integer;
begin
  Result := 0;
  for i := 0 to High(AEntries) do Inc(Result, AEntries[i].Granted);
end;

function WaitingCount(const AEntries: TLWPTWorkerBudgetEntryArray): Integer;
var
  i : Integer;
begin
  Result := 0;
  for i := 0 to High(AEntries) do
    if AEntries[i].Waiting then Inc(Result);
end;

function ReadBudget: Integer;
var
  Lines : TStringList;
begin
  Result := 0;
  if not FileExists(StatePath(BUDGET_FILE)) then Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(StatePath(BUDGET_FILE));
      if Lines.Count > 0 then Result := StrToIntDef(Trim(Lines[0]), 0);
    except
      Result := 0;
    end;
  finally
    Lines.Free;
  end;
end;

procedure WriteBudget(AValue: Integer);
var
  Lines : TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(IntToStr(AValue));
    AtomicWriteText(StatePath(BUDGET_FILE), StatePath(STATE_TMP_DIR), Lines);
  finally
    Lines.Free;
  end;
end;

function ReadQueueSequence: Int64;
var
  Lines : TStringList;
begin
  Result := 0;
  if not FileExists(StatePath(QUEUE_FILE)) then Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(StatePath(QUEUE_FILE));
      if Lines.Count > 0 then
        Result := StrToInt64Def(Trim(Lines[0]), 0);
    except
      Result := 0;
    end;
  finally
    Lines.Free;
  end;
end;

procedure WriteQueueSequence(AValue: Int64);
var
  Lines : TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(IntToStr(AValue));
    AtomicWriteText(StatePath(QUEUE_FILE), StatePath(STATE_TMP_DIR), Lines);
  finally
    Lines.Free;
  end;
end;

function NextWaitTicket(
  const AEntries: TLWPTWorkerBudgetEntryArray): Int64;
var
  i : Integer;
begin
  Result := ReadQueueSequence;
  for i := 0 to High(AEntries) do
    if AEntries[i].WaitTicket > Result then
      Result := AEntries[i].WaitTicket;
  if Result = High(Int64) then
    raise ELWPTWorkerBudgetError.Create('worker wait-ticket sequence exhausted');
  Inc(Result);
  WriteQueueSequence(Result);
end;

function ResolveEffectiveBudget(
  const AEntries: TLWPTWorkerBudgetEntryArray): Integer;
begin
  Result := ReadBudget;
  if (Length(AEntries) = 0) or (Result < 1) then
  begin
    Result := ConfiguredBudget;
    WriteBudget(Result);
  end;
end;

function BetterCandidate(const ACandidate,
  ACurrent: TLWPTWorkerBudgetEntry): Boolean;
begin
  if ACandidate.WaitTicket <> ACurrent.WaitTicket then
    Exit(ACandidate.WaitTicket < ACurrent.WaitTicket);
  Result := ACandidate.SessionId < ACurrent.SessionId;
end;

function BestWaitingEntry(const AEntries: TLWPTWorkerBudgetEntryArray): Integer;
var
  i : Integer;
begin
  Result := -1;
  for i := 0 to High(AEntries) do
    if AEntries[i].Waiting
       and (AEntries[i].Granted < AEntries[i].Requested) then
    begin
      if Result < 0 then
        Result := i
      else if BetterCandidate(AEntries[i], AEntries[Result]) then
        Result := i;
    end;
end;

constructor TLWPTWorkerHeartbeat.Create(AOwner: TLWPTWorkerBudgetSession;
  AIntervalMilliseconds: Integer);
begin
  FOwner := AOwner;
  FIntervalMilliseconds := AIntervalMilliseconds;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TLWPTWorkerHeartbeat.Execute;
var
  Waited : Integer;
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
      { A transient state-directory or lock error must not terminate the
        owner process. The next interval retries; the stale window is at
        least three times the heartbeat interval. }
    end;
  end;
end;

constructor TLWPTWorkerBudgetSession.Create(const ASessionId: string;
  ARequestedWorkers: Integer);
var
  Transaction : TLWPTWorkerStateTransaction;
  Entries : TLWPTWorkerBudgetEntryArray;
  Entry : TLWPTWorkerBudgetEntry;
  Index : Integer;
  Current : Int64;
  Interval : Integer;
  InheritedToken, LeaseDigest : string;
begin
  inherited Create;
  FHeartbeat := nil;
  FOwnerGuard := nil;
  FLeases := nil;
  FRegistered := False;
  FClosed := False;
  FInherited := False;
  FInheritedToken := '';
  FLocalCriticalSectionReady := False;
  FAcquireCriticalSectionReady := False;
  if not ValidSessionId(ASessionId) then
    raise ELWPTWorkerBudgetError.CreateFmt(
      'invalid worker session identity "%s"', [ASessionId]);
  if ARequestedWorkers < 1 then
    raise ELWPTWorkerBudgetError.Create(
      'requested worker count must be a positive integer');

  FSessionId := ASessionId;
  FRequested := ARequestedWorkers;
  FLocalGranted := 0;
  InitCriticalSection(FLocalCriticalSection);
  FLocalCriticalSectionReady := True;
  InitCriticalSection(FAcquireCriticalSection);
  FAcquireCriticalSectionReady := True;
  FLeases := TList.Create;

  InheritedToken := Trim(
    SysUtils.GetEnvironmentVariable(WORKER_LEASE_TOKEN_ENV));
  Transaction := TLWPTWorkerStateTransaction.Create;
  try
    Entries := LoadEntries;
    PruneEntries(Entries);
    FEffectiveBudget := ResolveEffectiveBudget(Entries);
    if FindEntry(Entries, FSessionId) >= 0 then
      raise ELWPTWorkerBudgetError.CreateFmt(
        'worker session "%s" is already active', [FSessionId]);
    FOwnerGuard := TLWPTWorkerOwnerGuard.Create(FSessionId);
    if InheritedToken <> '' then
    begin
      if not ValidLeaseToken(InheritedToken) then
        raise ELWPTWorkerBudgetError.CreateFmt(
          '%s contains an invalid opaque lease token',
          [WORKER_LEASE_TOKEN_ENV]);
      Index := FindDelegationEntry(Entries, InheritedToken, LeaseDigest);
      if Index < 0 then
        raise ELWPTWorkerBudgetError.Create(
          'worker lease delegation is invalid, already consumed, or expired');
      if not RemoveLeaseDigest(Entries[Index].LeaseTokens, LeaseDigest) then
        raise ELWPTWorkerBudgetError.Create(
          'delegated worker lease is no longer active');
      if not RemoveDelegation(Entries[Index].Delegations,
        InheritedToken) then
        raise ELWPTWorkerBudgetError.Create(
          'worker lease delegation disappeared during consumption');
      if Entries[Index].Granted > 0 then Dec(Entries[Index].Granted);
      if Entries[Index].Granted = 0 then
        Entries[Index].LeaseStartedAt := 0;
      Entries[Index].HeartbeatAt := NowMilliseconds;

      FRequested := 1;
      FInherited := True;
      FInheritedToken := InheritedToken;
      Current := NowMilliseconds;
      Entry := Default(TLWPTWorkerBudgetEntry);
      Entry.SessionId := FSessionId;
      Entry.ProcessId := GetProcessID;
      Entry.Requested := 1;
      Entry.Granted := 1;
      Entry.StartedAt := Current;
      Entry.HeartbeatAt := Current;
      Entry.LeaseStartedAt := Current;
      Entry.LeaseTokens := LeaseTokenDigest(InheritedToken);
      WriteEntry(Entry);
      WriteEntry(Entries[Index]);
      FRegistered := True;
    end
    else
    begin
      if FRequested > FEffectiveBudget then
        FRequested := FEffectiveBudget;
      Current := NowMilliseconds;
      Entry := Default(TLWPTWorkerBudgetEntry);
      Entry.SessionId := FSessionId;
      Entry.ProcessId := GetProcessID;
      Entry.Requested := FRequested;
      Entry.StartedAt := Current;
      Entry.HeartbeatAt := Current;
      WriteEntry(Entry);
      FRegistered := True;
    end;
  finally
    Transaction.Free;
  end;
  if FInherited then ClearWorkerLeaseEnvironment;

  Interval := (StaleSeconds * 1000) div 3;
  if Interval < 1000 then Interval := 1000;
  FHeartbeat := TLWPTWorkerHeartbeat.Create(Self, Interval);
  FHeartbeat.Start;
end;

destructor TLWPTWorkerBudgetSession.Destroy;
var
  i : Integer;
  Transaction : TLWPTWorkerStateTransaction;
begin
  if FLocalCriticalSectionReady then
  begin
    EnterCriticalSection(FLocalCriticalSection);
    try
      FClosed := True;
    finally
      LeaveCriticalSection(FLocalCriticalSection);
    end;
  end
  else
    FClosed := True;

  if FAcquireCriticalSectionReady then
    EnterCriticalSection(FAcquireCriticalSection);
  if FHeartbeat <> nil then
  begin
    FHeartbeat.Terminate;
    FHeartbeat.WaitFor;
    FHeartbeat.Free;
    FHeartbeat := nil;
  end;
  if FRegistered then
  begin
    try
      Transaction := TLWPTWorkerStateTransaction.Create;
      try
        RemoveRequestPath(FSessionId);
      finally
        Transaction.Free;
      end;
    except
      { Destruction must remain safe if the state root becomes unavailable.
        The request remains reserved until this owner process exits. }
    end;
    FRegistered := False;
  end;
  if FLeases <> nil then
  begin
    if FLocalCriticalSectionReady then
      EnterCriticalSection(FLocalCriticalSection);
    for i := 0 to FLeases.Count - 1 do
      TLWPTWorkerLease(FLeases[i]).Detach;
    FLeases.Free;
    FLeases := nil;
    FLocalGranted := 0;
    if FLocalCriticalSectionReady then
      LeaveCriticalSection(FLocalCriticalSection);
  end;
  if FOwnerGuard <> nil then
  begin
    FOwnerGuard.Free;
    FOwnerGuard := nil;
  end;
  if FAcquireCriticalSectionReady then
  begin
    LeaveCriticalSection(FAcquireCriticalSection);
    DoneCriticalSection(FAcquireCriticalSection);
    FAcquireCriticalSectionReady := False;
  end;
  if FLocalCriticalSectionReady then
  begin
    DoneCriticalSection(FLocalCriticalSection);
    FLocalCriticalSectionReady := False;
  end;
  inherited Destroy;
end;

function TLWPTWorkerBudgetSession.IsClosed: Boolean;
begin
  if not FLocalCriticalSectionReady then Exit(FClosed);
  EnterCriticalSection(FLocalCriticalSection);
  try
    Result := FClosed;
  finally
    LeaveCriticalSection(FLocalCriticalSection);
  end;
end;

function TLWPTWorkerBudgetSession.GetGrantedWorkers: Integer;
begin
  if not FLocalCriticalSectionReady then Exit(FLocalGranted);
  EnterCriticalSection(FLocalCriticalSection);
  try
    Result := FLocalGranted;
  finally
    LeaveCriticalSection(FLocalCriticalSection);
  end;
end;

procedure TLWPTWorkerBudgetSession.TouchHeartbeat;
var
  Transaction : TLWPTWorkerStateTransaction;
  Entries : TLWPTWorkerBudgetEntryArray;
  Index : Integer;
begin
  if IsClosed then Exit;
  Transaction := TLWPTWorkerStateTransaction.Create;
  try
    Entries := LoadEntries;
    Index := FindEntry(Entries, FSessionId);
    if Index < 0 then Exit;
    Entries[Index].HeartbeatAt := NowMilliseconds;
    WriteEntry(Entries[Index]);
  finally
    Transaction.Free;
  end;
end;

function TLWPTWorkerBudgetSession.Acquire(
  ATimeoutMilliseconds: Integer): TLWPTWorkerLease;
var
  Started : QWord;
  Transaction : TLWPTWorkerStateTransaction;
  Entries : TLWPTWorkerBudgetEntryArray;
  Index, Candidate, Active : Integer;
  Granted : Boolean;
  LeaseToken : string;
begin
  Result := nil;
  EnterCriticalSection(FAcquireCriticalSection);
  try
    if IsClosed then
      raise ELWPTWorkerBudgetError.Create('cannot acquire from a closed session');
    if GetGrantedWorkers >= FRequested then
      raise ELWPTWorkerBudgetError.CreateFmt(
        'session "%s" already holds its requested %d worker(s)',
        [FSessionId, FRequested]);

    if FInherited then
    begin
      Transaction := TLWPTWorkerStateTransaction.Create;
      try
        Entries := LoadEntries;
        PruneEntries(Entries);
        Index := FindLeaseTokenEntry(Entries, FInheritedToken);
        if Index < 0 then
          raise ELWPTWorkerBudgetError.Create(
            'inherited worker lease is no longer active');
      finally
        Transaction.Free;
      end;
      Result := TLWPTWorkerLease.Create(Self, FInheritedToken);
      EnterCriticalSection(FLocalCriticalSection);
      try
        FLeases.Add(Result);
        Inc(FLocalGranted);
      finally
        LeaveCriticalSection(FLocalCriticalSection);
      end;
      Exit;
    end;

    LeaseToken := NewOpaqueToken;
    Started := GetTickCount64;
    repeat
      if IsClosed then
        raise ELWPTWorkerBudgetError.Create('cannot acquire from a closed session');
      Granted := False;
      Transaction := TLWPTWorkerStateTransaction.Create;
      try
        Entries := LoadEntries;
        PruneEntries(Entries);
        Index := FindEntry(Entries, FSessionId);
        if Index < 0 then
          raise ELWPTWorkerBudgetError.CreateFmt(
            'worker session "%s" disappeared from coordinator state',
            [FSessionId]);
        Entries[Index].HeartbeatAt := NowMilliseconds;
        if not Entries[Index].Waiting then
        begin
          Entries[Index].Waiting := True;
          Entries[Index].WaitTicket := NextWaitTicket(Entries);
        end;
        WriteEntry(Entries[Index]);

        Active := ActiveWorkerCount(Entries);
        Candidate := BestWaitingEntry(Entries);
        if (Active < FEffectiveBudget) and (Candidate = Index) then
        begin
          AddLeaseToken(Entries[Index].LeaseTokens, LeaseToken);
          Inc(Entries[Index].Granted);
          Entries[Index].Waiting := False;
          Entries[Index].WaitTicket := 0;
          if Entries[Index].LeaseStartedAt = 0 then
            Entries[Index].LeaseStartedAt := NowMilliseconds;
          Entries[Index].HeartbeatAt := NowMilliseconds;
          WriteEntry(Entries[Index]);
          Granted := True;
        end;
      finally
        Transaction.Free;
      end;
      if Granted then
      begin
        Result := TLWPTWorkerLease.Create(Self, LeaseToken);
        EnterCriticalSection(FLocalCriticalSection);
        try
          FLeases.Add(Result);
          Inc(FLocalGranted);
        finally
          LeaveCriticalSection(FLocalCriticalSection);
        end;
        Exit;
      end;

      if (ATimeoutMilliseconds >= 0)
         and (GetTickCount64 - Started >= QWord(ATimeoutMilliseconds)) then
      begin
        Transaction := TLWPTWorkerStateTransaction.Create;
        try
          Entries := LoadEntries;
          Index := FindEntry(Entries, FSessionId);
          if Index >= 0 then
          begin
            Entries[Index].Waiting := False;
            Entries[Index].WaitTicket := 0;
            Entries[Index].HeartbeatAt := NowMilliseconds;
            WriteEntry(Entries[Index]);
          end;
        finally
          Transaction.Free;
        end;
        Exit(nil);
      end;
      Sleep(ACQUIRE_POLL_MILLISECONDS);
    until False;
  finally
    LeaveCriticalSection(FAcquireCriticalSection);
  end;
end;

procedure TLWPTWorkerBudgetSession.ReleaseLease(ALease: TLWPTWorkerLease);
var
  Transaction : TLWPTWorkerStateTransaction;
  Entries : TLWPTWorkerBudgetEntryArray;
  Index : Integer;
  Removed, LocallyGranted : Boolean;
begin
  if ALease = nil then Exit;
  Transaction := TLWPTWorkerStateTransaction.Create;
  try
    Entries := LoadEntries;
    PruneEntries(Entries);
    Index := FindEntry(Entries, FSessionId);
    if (Index >= 0)
       and HasLeaseToken(Entries[Index].LeaseTokens, ALease.FToken) then
    begin
      RemoveDelegationsForLease(Entries[Index].Delegations,
        LeaseTokenDigest(ALease.FToken));
      RemoveLeaseToken(Entries[Index].LeaseTokens, ALease.FToken);
      if Entries[Index].Granted > 0 then Dec(Entries[Index].Granted);
      if Entries[Index].Granted = 0 then
        Entries[Index].LeaseStartedAt := 0;
      Entries[Index].HeartbeatAt := NowMilliseconds;
      WriteEntry(Entries[Index]);
    end;

    { Keep the coordinator transaction held until the matching local state is
      updated, so another scheduler thread cannot observe a half-release. }
    EnterCriticalSection(FLocalCriticalSection);
    try
      LocallyGranted := not ALease.FDelegated;
      Removed := (FLeases <> nil) and (FLeases.Remove(ALease) >= 0);
      if Removed and LocallyGranted and (FLocalGranted > 0) then
        Dec(FLocalGranted);
      if Removed and FInherited
         and (ALease.FToken = FInheritedToken) then
      begin
        { The transferred grant has now completed. Further work in this
          still-live nested invocation must rejoin the ordinary FIFO rather
          than trying to reuse the consumed one-shot token. }
        FInherited := False;
        FInheritedToken := '';
      end;
    finally
      LeaveCriticalSection(FLocalCriticalSection);
    end;
  finally
    Transaction.Free;
  end;
end;

function TLWPTWorkerBudgetSession.CreateDelegation(
  ALease: TLWPTWorkerLease): string;
var
  Transaction : TLWPTWorkerStateTransaction;
  Entries : TLWPTWorkerBudgetEntryArray;
  Index : Integer;
  LeaseDigest : string;
begin
  if (ALease = nil) or ALease.FReleased or ALease.FDelegated
     or (ALease.FOwner <> Self) then
    raise ELWPTWorkerBudgetError.Create(
      'only an active owned worker lease can be delegated');
  LeaseDigest := LeaseTokenDigest(ALease.FToken);
  Result := NewOpaqueToken;
  Transaction := TLWPTWorkerStateTransaction.Create;
  try
    Entries := LoadEntries;
    PruneEntries(Entries);
    Index := FindEntry(Entries, FSessionId);
    if (Index < 0)
       or not HasLeaseToken(Entries[Index].LeaseTokens, ALease.FToken) then
      raise ELWPTWorkerBudgetError.Create(
        'worker lease is no longer active');
    if LeaseHasDelegation(Entries[Index].Delegations, LeaseDigest) then
      raise ELWPTWorkerBudgetError.Create(
        'worker lease already has a pending child delegation');
    AddDelegation(Entries[Index].Delegations, Result, LeaseDigest);
    Entries[Index].HeartbeatAt := NowMilliseconds;
    WriteEntry(Entries[Index]);

    { Publish the durable delegation and its local ownership transition as one
      scheduler-visible operation. }
    EnterCriticalSection(FLocalCriticalSection);
    try
      ALease.FDelegated := True;
      if FLocalGranted > 0 then Dec(FLocalGranted);
    finally
      LeaveCriticalSection(FLocalCriticalSection);
    end;
  finally
    Transaction.Free;
  end;
end;

procedure TLWPTWorkerBudgetSession.AbandonLease(ALease: TLWPTWorkerLease);
begin
  if not FLocalCriticalSectionReady then Exit;
  EnterCriticalSection(FLocalCriticalSection);
  try
    if FLeases <> nil then FLeases.Remove(ALease);
    { Keep FLocalGranted unchanged. The coordinator still owns that capacity,
      so this session must not replace the abandoned lease. }
  finally
    LeaveCriticalSection(FLocalCriticalSection);
  end;
end;

constructor TLWPTWorkerLease.Create(AOwner: TLWPTWorkerBudgetSession;
  const AToken: string);
begin
  inherited Create;
  FOwner := AOwner;
  FReleased := False;
  FToken := AToken;
  FDelegated := False;
end;

destructor TLWPTWorkerLease.Destroy;
begin
  try
    Release;
  except
    { Explicit Release remains retryable. Destruction cannot keep this object
      alive, so detach the pointer while leaving the coordinator grant counted
      until the owning session or process exits. }
    if FOwner <> nil then FOwner.AbandonLease(Self);
    FOwner := nil;
    FReleased := True;
  end;
  inherited Destroy;
end;

procedure TLWPTWorkerLease.Release;
begin
  if FReleased then Exit;
  if FOwner <> nil then FOwner.ReleaseLease(Self);
  FReleased := True;
  FOwner := nil;
end;

procedure TLWPTWorkerLease.Detach;
begin
  FOwner := nil;
  FReleased := True;
end;

function EnvironmentName(const AEntry: string): string;
var
  Separator : Integer;
begin
  Separator := Pos('=', AEntry);
  if Separator = 0 then Result := AEntry
  else Result := Copy(AEntry, 1, Separator - 1);
end;

procedure AppendWorkerLeaseEnvironment(AEnvironment: TStrings;
  ALease: TLWPTWorkerLease);
var
  i : Integer;
  Token : string;
begin
  if AEnvironment = nil then
    raise ELWPTWorkerBudgetError.Create(
      'worker lease environment target is required');
  for i := AEnvironment.Count - 1 downto 0 do
    if SameText(EnvironmentName(AEnvironment[i]), WORKER_LEASE_TOKEN_ENV) then
      AEnvironment.Delete(i);
  if (ALease = nil) or (ALease.FOwner = nil) then
    raise ELWPTWorkerBudgetError.Create(
      'active worker lease is required for delegation');
  Token := ALease.FOwner.CreateDelegation(ALease);
  AEnvironment.Add(WORKER_LEASE_TOKEN_ENV + '=' + Token);
end;

function GetWorkerBudgetSnapshot: TLWPTWorkerBudgetSnapshot;
var
  Transaction : TLWPTWorkerStateTransaction;
begin
  Result := Default(TLWPTWorkerBudgetSnapshot);
  Transaction := TLWPTWorkerStateTransaction.Create;
  try
    Result.StateRoot := WorkerStateRoot;
    Result.Entries := LoadEntries;
    PruneEntries(Result.Entries);
    Result.EffectiveBudget := ResolveEffectiveBudget(Result.Entries);
    Result.ActiveWorkers := ActiveWorkerCount(Result.Entries);
    Result.WaitingInvocations := WaitingCount(Result.Entries);
  finally
    Transaction.Free;
  end;
end;

function RepairWorkerBudget: Integer;
var
  Transaction : TLWPTWorkerStateTransaction;
  Entries : TLWPTWorkerBudgetEntryArray;
  TmpRoot : string;
  LoadedReclaimed : Integer;
begin
  Transaction := TLWPTWorkerStateTransaction.Create;
  try
    Entries := LoadEntriesWithReclaimed(LoadedReclaimed);
    Result := LoadedReclaimed + PruneEntries(Entries);
    TmpRoot := StatePath(STATE_TMP_DIR);
    if DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
  finally
    Transaction.Free;
  end;
end;

procedure AppendWorkerBudgetDiagnostics(AOutput: TStrings;
  const ASnapshot: TLWPTWorkerBudgetSnapshot);
var
  i : Integer;
  Age, HeartbeatAge : Int64;
  State, HeartbeatState : string;
begin
  AOutput.Add(Format('worker budget: %d total, %d active, %d waiting',
    [ASnapshot.EffectiveBudget, ASnapshot.ActiveWorkers,
     ASnapshot.WaitingInvocations]));
  AOutput.Add('worker state: ' + ASnapshot.StateRoot);
  for i := 0 to High(ASnapshot.Entries) do
  begin
    if ASnapshot.Entries[i].Uncertain then State := 'uncertain-live-owner'
    else if ASnapshot.Entries[i].Waiting then State := 'waiting'
    else if ASnapshot.Entries[i].Granted > 0 then State := 'active'
    else State := 'idle';
    HeartbeatAge := (NowMilliseconds
      - ASnapshot.Entries[i].HeartbeatAt) div 1000;
    if ASnapshot.Entries[i].LeaseStartedAt > 0 then
      Age := (NowMilliseconds
        - ASnapshot.Entries[i].LeaseStartedAt) div 1000
    else
      Age := 0;
    if HeartbeatAge > StaleSeconds then
      HeartbeatState := ' (stale)'
    else
      HeartbeatState := '';
    AOutput.Add(Format(
      '  %s: pid %d, %d/%d granted, %s, lease age %ds, heartbeat %ds ago%s',
      [ASnapshot.Entries[i].SessionId, ASnapshot.Entries[i].ProcessId,
       ASnapshot.Entries[i].Granted, ASnapshot.Entries[i].Requested,
       State, Age, HeartbeatAge, HeartbeatState]));
  end;
end;

initialization
  InitCriticalSection(WorkerStateCriticalSection);
  InitCriticalSection(LocalOwnerCriticalSection);
  LocalOwnerSessions := TStringList.Create;

finalization
  LocalOwnerSessions.Free;
  DoneCriticalSection(LocalOwnerCriticalSection);
  DoneCriticalSection(WorkerStateCriticalSection);

end.
