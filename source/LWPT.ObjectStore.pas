{ LWPT.ObjectStore — per-user cache-root resolution and immutable SHA-256
  object storage. The unit knows nothing about dependency resolution or build
  results: callers select a namespace root and supply the expected digest. }
unit LWPT.ObjectStore;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.CacheLifecycle,
  LWPT.Core;

const
  CACHE_DIR_ENV = PROJECT_NAME + '_CACHE_DIR';
  DEPENDENCY_ARCHIVE_NAMESPACE = 'dependency-archives';

type
  ELWPTObjectStoreError = class(ELWPTError);

  TLWPTObjectMaterializeFailure = (
    omfNone,
    omfObjectMissing,
    omfVerificationFailed,
    omfCopyFailed,
    omfStagedHashMismatch
  );

  {$IFDEF OBJECTSTORE_TESTING}
  TLWPTObjectStoreBeforeQuarantineHook = procedure(const APath: string);
  TLWPTObjectStoreAfterStageHook = procedure(const APath: string);
  TLWPTObjectStorePublicationHook = procedure(const AStaged,
    ADestination: string);
  TLWPTObjectStoreMaterializeHook = procedure(const ADigest,
    APath: string);
  TLWPTObjectStoreStagedVerificationOpenHook = procedure(
    const APath: string; const AAttempt: Integer;
    out AErrorCode: Integer);
  TLWPTObjectStoreStagedVerificationRetryHook = procedure(
    const AAttempt, ADelayMilliseconds: Integer);
  {$ENDIF}

  TLWPTImmutableObjectStore = class
  private
    FCacheLifecycle: TLWPTCacheLifecycle;
    FRoot: string;
    function CanonicalDigest(const ADigest: string): string;
    function VerifyObject(const ADigest: string; out APath: string;
      out ACorrupt: Boolean): Boolean;
    function RepairCorruptObjectLocked(const ADigest: string;
      out APath: string): Boolean;
    function LookupWithObjectGuard(const ADigest: string;
      out APath: string; out AFailure:
      TLWPTObjectMaterializeFailure): Boolean;
    function Quarantine(const APath, ADigest: string;
      out AQuarantinePath: string): Boolean;
  public
    constructor Create(const ARoot, ACacheRoot,
      ANamespace: string);
    destructor Destroy; override;
    function ObjectPath(const ADigest: string): string;
    function Lookup(const ADigest: string; out APath: string): Boolean;
    function Admit(const ASourcePath, AExpectedDigest: string): string;
    function AdmitRetained(const ASourcePath, AExpectedDigest: string;
      out ALease: TObject; out AInserted: Boolean): string;
    procedure DiscardRetained(const ADigest: string);
    function Materialize(const ADigest, ADestination,
      ATmpRoot: string): Boolean; overload;
    function Materialize(const ADigest, ADestination,
      ATmpRoot: string; out AFailure:
      TLWPTObjectMaterializeFailure): Boolean; overload;
    function MaterializeRetained(const ADigest, ADestination,
      ATmpRoot: string; out AFailure: TLWPTObjectMaterializeFailure;
      out ALease: TObject): Boolean;
    property Root: string read FRoot;
  end;

function ResolveCacheRoot: string;
function ResolveCacheRootFromValues(const AOverride, AHome,
  AXDGCacheHome, ALocalAppData: string): string;
function DependencyArchiveStoreRoot(const ACacheRoot: string): string;
function ObjectMaterializeFailureName(
  const AFailure: TLWPTObjectMaterializeFailure): string;

{$IFDEF OBJECTSTORE_TESTING}
var
  ObjectStoreBeforeQuarantineTestHook:
    TLWPTObjectStoreBeforeQuarantineHook;
  ObjectStoreAfterStageTestHook: TLWPTObjectStoreAfterStageHook;
  ObjectStoreBeforePublicationTestHook: TLWPTObjectStorePublicationHook;
  ObjectStoreAfterPublicationTestHook: TLWPTObjectStorePublicationHook;
  ObjectStoreBeforeMaterializeCopyTestHook:
    TLWPTObjectStoreMaterializeHook;
  ObjectStoreAfterMaterializeCopyTestHook:
    TLWPTObjectStoreMaterializeHook;
  ObjectStoreStagedVerificationOpenTestHook:
    TLWPTObjectStoreStagedVerificationOpenHook;
  ObjectStoreStagedVerificationRetryTestHook:
    TLWPTObjectStoreStagedVerificationRetryHook;
{$ENDIF}

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes;

function StagedVerificationHash(const APath: string): string;
const
  OPEN_ATTEMPTS = 6;
  OPEN_RETRY_INITIAL_MILLISECONDS = 1;
var
  Attempt: Integer;
  {$IFDEF UNIX}
  DelayMilliseconds: Integer;
  {$ENDIF}
  ErrorCode: Integer;
begin
  for Attempt := 1 to OPEN_ATTEMPTS do
  begin
    ErrorCode := 0;
    {$IFDEF OBJECTSTORE_TESTING}
    if Assigned(ObjectStoreStagedVerificationOpenTestHook) then
      ObjectStoreStagedVerificationOpenTestHook(APath, Attempt, ErrorCode);
    {$ENDIF}
    if ErrorCode = 0 then
    begin
      if not FileExists(APath) then Exit('');
      if TrySHA256FileOpen(APath, Result, ErrorCode) then Exit;
    end;
    {$IFDEF UNIX}
    if (ErrorCode in [ESysEAGAIN, ESysEINTR])
       and (Attempt < OPEN_ATTEMPTS) then
    begin
      DelayMilliseconds := OPEN_RETRY_INITIAL_MILLISECONDS shl (Attempt - 1);
      {$IFDEF OBJECTSTORE_TESTING}
      if Assigned(ObjectStoreStagedVerificationRetryTestHook) then
        ObjectStoreStagedVerificationRetryTestHook(Attempt,
          DelayMilliseconds);
      {$ENDIF}
      Sleep(DelayMilliseconds);
      Continue;
    end;
    {$ENDIF}
    raise EFOpenError.CreateFmt('Unable to open file "%s": %s',
      [APath, SysErrorMessage(ErrorCode)]);
  end;
  Result := '';
end;

function ObjectMaterializeFailureName(
  const AFailure: TLWPTObjectMaterializeFailure): string;
begin
  case AFailure of
    omfNone: Result := 'none';
    omfObjectMissing: Result := 'object-missing';
    omfVerificationFailed: Result := 'verification-failed';
    omfCopyFailed: Result := 'copy-failed';
    omfStagedHashMismatch: Result := 'staged-hash-mismatch';
  else
    Result := 'unknown';
  end;
end;

function IsAbsolutePath(const APath: string): Boolean;
begin
  Result := False;
  if APath = '' then Exit;
  {$IFDEF MSWINDOWS}
  Result := ((Length(APath) >= 3) and (APath[1] in ['A'..'Z', 'a'..'z'])
    and (APath[2] = ':') and (APath[3] in ['/', '\']))
    or ((Length(APath) >= 2) and (APath[1] in ['/', '\'])
      and (APath[2] in ['/', '\']));
  {$ELSE}
  Result := APath[1] = '/';
  {$ENDIF}
end;

function NormalizeRoot(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
end;

procedure EnsureUnlinkedDirectory(const APath, ADescription: string);
const
  DIRECTORY_CREATE_ATTEMPTS = 32;
var
  Attempt: Integer;
begin
  if IsDirSymlinkOrJunction(APath) then
    raise ELWPTObjectStoreError.CreateFmt(
      '%s must not be a link: %s', [ADescription, APath]);
  for Attempt := 1 to DIRECTORY_CREATE_ATTEMPTS do
  begin
    if DirectoryExists(APath) then Break;
    try
      ForceDirectories(APath);
    except
      on E: EInOutError do
        if (Attempt = DIRECTORY_CREATE_ATTEMPTS)
           and not DirectoryExists(APath) then raise;
    end;
    if DirectoryExists(APath) then Break;
    Sleep(1);
  end;
  if not DirectoryExists(APath) then
    raise ELWPTObjectStoreError.CreateFmt(
      'failed to create %s at %s', [ADescription, APath]);
  if IsDirSymlinkOrJunction(APath) then
    raise ELWPTObjectStoreError.CreateFmt(
      '%s became a link: %s', [ADescription, APath]);
end;

function ResolveCacheRootFromValues(const AOverride, AHome,
  AXDGCacheHome, ALocalAppData: string): string;
var
  Base: string;
begin
  if AOverride <> '' then Exit(NormalizeRoot(AOverride));

  {$IFDEF MSWINDOWS}
  Base := ALocalAppData;
  if Base = '' then Base := AHome;
  if Base = '' then
    raise ELWPTObjectStoreError.CreateFmt(
      'cannot resolve the per-user cache root; set %s', [CACHE_DIR_ENV]);
  Result := NormalizeRoot(IncludeTrailingPathDelimiter(Base)
    + LowerCase(PROJECT_NAME) + '/cache');
  {$ELSE}
  {$IFDEF DARWIN}
  Base := AHome;
  if Base = '' then
    raise ELWPTObjectStoreError.CreateFmt(
      'cannot resolve the per-user cache root; set %s', [CACHE_DIR_ENV]);
  Result := NormalizeRoot(IncludeTrailingPathDelimiter(Base)
    + 'Library/Caches/' + LowerCase(PROJECT_NAME));
  {$ELSE}
  Base := AXDGCacheHome;
  { XDG Base Directory 0.8 says relative values are invalid and must be
    ignored. Falling back keeps an inherited bad value from relocating cache
    state relative to whichever worktree invoked LWPT. }
  if (Base = '') or not IsAbsolutePath(Base) then
  begin
    if AHome = '' then
      raise ELWPTObjectStoreError.CreateFmt(
        'cannot resolve the per-user cache root; set %s', [CACHE_DIR_ENV]);
    Base := IncludeTrailingPathDelimiter(AHome) + '.cache';
  end;
  Result := NormalizeRoot(IncludeTrailingPathDelimiter(Base)
    + LowerCase(PROJECT_NAME));
  {$ENDIF}
  {$ENDIF}
end;

function ResolveCacheRoot: string;
var
  UserHome: string;
begin
  UserHome := SysUtils.GetEnvironmentVariable('HOME');
  {$IFDEF MSWINDOWS}
  if UserHome = '' then
    UserHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  {$ENDIF}
  Result := ResolveCacheRootFromValues(
    SysUtils.GetEnvironmentVariable(CACHE_DIR_ENV),
    UserHome,
    SysUtils.GetEnvironmentVariable('XDG_CACHE_HOME'),
    SysUtils.GetEnvironmentVariable('LOCALAPPDATA'));
end;

function DependencyArchiveStoreRoot(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + DEPENDENCY_ARCHIVE_NAMESPACE;
end;

constructor TLWPTImmutableObjectStore.Create(const ARoot, ACacheRoot,
  ANamespace: string);
var
  CacheRoot, NamespaceRoot: string;
begin
  inherited Create;
  if ARoot = '' then
    raise ELWPTObjectStoreError.Create('object-store root cannot be empty');
  FRoot := NormalizeRoot(ARoot);
  CacheRoot := NormalizeRoot(ACacheRoot);
  NamespaceRoot := IncludeTrailingPathDelimiter(CacheRoot) + ANamespace;
  if IsDirSymlinkOrJunction(NamespaceRoot)
     or IsDirSymlinkOrJunction(FRoot) then
    raise ELWPTObjectStoreError.Create(
      'shared-cache namespace roots must not be links');
  FCacheLifecycle := TLWPTCacheLifecycle.Create(ACacheRoot, ANamespace);
end;

destructor TLWPTImmutableObjectStore.Destroy;
begin
  FCacheLifecycle.Free;
  inherited Destroy;
end;

function TLWPTImmutableObjectStore.CanonicalDigest(
  const ADigest: string): string;
var
  Hex: string;
  i: Integer;
begin
  if not SameText(Copy(ADigest, 1, 7), 'sha256:') then
    raise ELWPTObjectStoreError.CreateFmt(
      'object digest must use sha256:<64 lowercase hex> (got "%s")',
      [ADigest]);
  Hex := LowerCase(Copy(ADigest, 8, MaxInt));
  if Length(Hex) <> 64 then
    raise ELWPTObjectStoreError.CreateFmt(
      'object digest must use sha256:<64 lowercase hex> (got "%s")',
      [ADigest]);
  for i := 1 to Length(Hex) do
    if not (Hex[i] in ['0'..'9', 'a'..'f']) then
      raise ELWPTObjectStoreError.CreateFmt(
        'object digest must use sha256:<64 lowercase hex> (got "%s")',
        [ADigest]);
  Result := 'sha256:' + Hex;
end;

function TLWPTImmutableObjectStore.ObjectPath(
  const ADigest: string): string;
var
  Hex: string;
begin
  Hex := Copy(CanonicalDigest(ADigest), 8, MaxInt);
  Result := IncludeTrailingPathDelimiter(FRoot) + 'sha256/'
    + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
end;

function TLWPTImmutableObjectStore.Quarantine(const APath,
  ADigest: string; out AQuarantinePath: string): Boolean;
var
  QuarantineRoot: string;
begin
  AQuarantinePath := '';
  Result := not FileExists(APath);
  if Result then Exit;
  QuarantineRoot := IncludeTrailingPathDelimiter(FRoot) + 'quarantine';
  EnsureUnlinkedDirectory(QuarantineRoot, 'object quarantine');
  AQuarantinePath := MakeTmpPath(QuarantineRoot,
    Copy(CanonicalDigest(ADigest), 8, 12) + '-corrupt');
  Result := AtomicMoveFile(APath, AQuarantinePath);
  if not Result then AQuarantinePath := '';
end;

function TLWPTImmutableObjectStore.VerifyObject(const ADigest: string;
  out APath: string; out ACorrupt: Boolean): Boolean;
var
  Expected, Actual: string;
begin
  Expected := CanonicalDigest(ADigest);
  ACorrupt := False;
  APath := ObjectPath(Expected);
  if not FileExists(APath) then Exit(False);
  Actual := 'sha256:' + SHA256File(APath);
  if Actual = Expected then Exit(True);
  ACorrupt := True;
  Result := False;
end;

function TLWPTImmutableObjectStore.RepairCorruptObjectLocked(
  const ADigest: string; out APath: string): Boolean;
var
  Expected, QuarantinePath: string;
begin
  Expected := CanonicalDigest(ADigest);
  APath := ObjectPath(Expected);
  {$IFDEF OBJECTSTORE_TESTING}
  if Assigned(ObjectStoreBeforeQuarantineTestHook) then
    ObjectStoreBeforeQuarantineTestHook(APath);
  {$ENDIF}
  if not Quarantine(APath, Expected, QuarantinePath) then
    raise ELWPTObjectStoreError.CreateFmt(
      'corrupt object %s could not be quarantined', [Expected]);
  { A verified replacement may have won the pathname after the stale hash
    above. Hash the object actually moved, and restore that proven winner
    atomically instead of leaving the content-addressed entry missing. }
  if (QuarantinePath <> '')
     and (('sha256:' + SHA256File(QuarantinePath)) = Expected) then
  begin
    if not AtomicMoveFile(QuarantinePath, APath) then
      raise ELWPTObjectStoreError.CreateFmt(
        'verified object %s could not be restored after quarantine',
        [Expected]);
    Exit(True);
  end;
  APath := '';
  Result := False;
end;

function TLWPTImmutableObjectStore.LookupWithObjectGuard(
  const ADigest: string; out APath: string; out AFailure:
  TLWPTObjectMaterializeFailure): Boolean;
var
  Corrupt: Boolean;
  MutationLease: TObject;
begin
  AFailure := omfNone;
  Result := VerifyObject(ADigest, APath, Corrupt);
  if not Result and not Corrupt then
  begin
    AFailure := omfObjectMissing;
    Exit;
  end;
  MutationLease := FCacheLifecycle.AcquireMutation;
  try
    if Corrupt then
    begin
      Result := RepairCorruptObjectLocked(ADigest, APath);
      if not Result then
        AFailure := omfVerificationFailed;
    end;
    if Result then FCacheLifecycle.TouchObjectLocked(ADigest);
  finally
    MutationLease.Free;
  end;
end;

function TLWPTImmutableObjectStore.Lookup(const ADigest: string;
  out APath: string): Boolean;
var
  Digest: string;
  Failure: TLWPTObjectMaterializeFailure;
  ObjectLease: TObject;
begin
  Digest := CanonicalDigest(ADigest);
  ObjectLease := FCacheLifecycle.AcquireObject(Digest);
  try
    Result := LookupWithObjectGuard(Digest, APath, Failure);
  finally
    ObjectLease.Free;
  end;
end;

function TLWPTImmutableObjectStore.Admit(const ASourcePath,
  AExpectedDigest: string): string;
var
  Inserted: Boolean;
  Lease: TObject;
begin
  Result := AdmitRetained(ASourcePath, AExpectedDigest, Lease, Inserted);
  Lease.Free;
end;

function TLWPTImmutableObjectStore.AdmitRetained(const ASourcePath,
  AExpectedDigest: string; out ALease: TObject;
  out AInserted: Boolean): string;
var
  Expected, Existing, TmpRoot, Staged, Actual: string;
  Failure: TLWPTObjectMaterializeFailure;
  {$IFDEF OBJECTSTORE_TESTING}
  PublishedStaged: string;
  {$ENDIF}
  MutationLease, ObjectLease: TObject;
  Published: Boolean;
begin
  ALease := nil;
  AInserted := False;
  ObjectLease := nil;
  MutationLease := nil;
  Published := False;
  Staged := '';
  TmpRoot := '';
  Expected := CanonicalDigest(AExpectedDigest);
  if not FileExists(ASourcePath) then
    raise ELWPTObjectStoreError.CreateFmt(
      'object admission source does not exist: %s', [ASourcePath]);
  Actual := 'sha256:' + SHA256File(ASourcePath);
  if Actual <> Expected then
    raise ELWPTObjectStoreError.CreateFmt(
      'object admission hash mismatch: expected %s, got %s',
      [Expected, Actual]);
  Result := ObjectPath(Expected);
  ObjectLease := FCacheLifecycle.AcquireObject(Expected);
  try
    try
      if LookupWithObjectGuard(Expected, Existing, Failure) then
      begin
        ALease := ObjectLease;
        ObjectLease := nil;
        Exit(Existing);
      end;

      { Each digest owns a staging directory under its object-use guard.
        Repair can reclaim abandoned directories while skipping this one,
        without serializing unrelated large copies behind the index guard. }
      TmpRoot := IncludeTrailingPathDelimiter(FRoot) + 'tmp/'
        + Copy(Expected, 8, MaxInt);
      EnsureUnlinkedDirectory(IncludeTrailingPathDelimiter(FRoot) + 'tmp',
        'object staging root');
      EnsureUnlinkedDirectory(TmpRoot, 'object staging directory');
      Staged := MakeTmpPath(TmpRoot, 'object');
      if not CopyFileContent(ASourcePath, Staged) then
        raise ELWPTObjectStoreError.CreateFmt(
          'failed to stage object %s', [Expected]);
      Actual := 'sha256:' + SHA256File(Staged);
      if Actual <> Expected then
        raise ELWPTObjectStoreError.CreateFmt(
          'staged object hash mismatch: expected %s, got %s',
          [Expected, Actual]);
      {$IFDEF OBJECTSTORE_TESTING}
      if Assigned(ObjectStoreAfterStageTestHook) then
        ObjectStoreAfterStageTestHook(Staged);
      {$ENDIF}

      MutationLease := FCacheLifecycle.AcquireMutation;
      try
        EnsureUnlinkedDirectory(IncludeTrailingPathDelimiter(FRoot)
          + 'sha256', 'object digest root');
        EnsureUnlinkedDirectory(ExtractFileDir(Result),
          'object digest shard');
        {$IFDEF OBJECTSTORE_TESTING}
        if Assigned(ObjectStoreBeforePublicationTestHook) then
          ObjectStoreBeforePublicationTestHook(Staged, Result);
        {$ENDIF}
        { Replacement is safe because every competing writer must prove the
          same digest before reaching this point. The object-use guard keeps
          eviction and materialization outside the publication interval. }
        if not AtomicReplaceFile(Staged, Result) then
          raise ELWPTObjectStoreError.CreateFmt(
            'failed to publish object %s', [Expected]);
        {$IFDEF OBJECTSTORE_TESTING}
        PublishedStaged := Staged;
        {$ENDIF}
        Staged := '';
        Published := True;
        {$IFDEF OBJECTSTORE_TESTING}
        if Assigned(ObjectStoreAfterPublicationTestHook) then
          ObjectStoreAfterPublicationTestHook(PublishedStaged, Result);
        {$ENDIF}
        FCacheLifecycle.RecordObjectLocked(Expected, Result);
        if not FCacheLifecycle.MakeRoomLocked(0) then
        begin
          FCacheLifecycle.DiscardObjectLocked(Expected, Result);
          Published := False;
          Result := '';
          Exit;
        end;
        AInserted := True;
        ALease := ObjectLease;
        ObjectLease := nil;
      finally
        MutationLease.Free;
        MutationLease := nil;
      end;
    except
      if (Staged <> '') and FileExists(Staged) then
        SysUtils.DeleteFile(Staged);
      if Published then
      begin
        try
          MutationLease := FCacheLifecycle.AcquireMutation;
          try
            FCacheLifecycle.DiscardObjectLocked(Expected, Result);
            Published := False;
          finally
            MutationLease.Free;
            MutationLease := nil;
          end;
        except
          { Preserve the publication failure. Repair owns any residue left by
            a rollback failure, and replacing the original exception would
            hide the operation that made the object incomplete. }
          Published := True;
        end;
      end;
      if (TmpRoot <> '') and DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
      raise;
    end;
  finally
    if (TmpRoot <> '') and DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
    ObjectLease.Free;
  end;
end;

procedure TLWPTImmutableObjectStore.DiscardRetained(
  const ADigest: string);
var
  Digest: string;
  MutationLease: TObject;
begin
  Digest := CanonicalDigest(ADigest);
  MutationLease := FCacheLifecycle.AcquireMutation;
  try
    FCacheLifecycle.DiscardObjectLocked(Digest, ObjectPath(Digest));
  finally
    MutationLease.Free;
  end;
end;

function TLWPTImmutableObjectStore.Materialize(const ADigest,
  ADestination, ATmpRoot: string): Boolean;
var
  Failure: TLWPTObjectMaterializeFailure;
begin
  Result := Materialize(ADigest, ADestination, ATmpRoot, Failure);
end;

function TLWPTImmutableObjectStore.Materialize(const ADigest,
  ADestination, ATmpRoot: string; out AFailure:
  TLWPTObjectMaterializeFailure): Boolean;
var
  Lease: TObject;
begin
  Lease := nil;
  try
    Result := MaterializeRetained(ADigest, ADestination, ATmpRoot,
      AFailure, Lease);
  finally
    Lease.Free;
  end;
end;

function TLWPTImmutableObjectStore.MaterializeRetained(const ADigest,
  ADestination, ATmpRoot: string; out AFailure:
  TLWPTObjectMaterializeFailure; out ALease: TObject): Boolean;
var
  Expected, SourcePath, Staged, Actual: string;
  ObjectLease: TObject;
begin
  Result := False;
  AFailure := omfNone;
  ALease := nil;
  Expected := CanonicalDigest(ADigest);
  ObjectLease := FCacheLifecycle.AcquireObject(Expected);
  try
    try
      try
        if not LookupWithObjectGuard(Expected, SourcePath, AFailure) then Exit;
        ForceDirectories(ATmpRoot);
        Staged := MakeTmpPath(ATmpRoot, 'cache-object');
        {$IFDEF OBJECTSTORE_TESTING}
        if Assigned(ObjectStoreBeforeMaterializeCopyTestHook) then
          ObjectStoreBeforeMaterializeCopyTestHook(Expected, SourcePath);
        {$ENDIF}
        if not CopyFileContent(SourcePath, Staged) then
        begin
          if FileExists(Staged) then SysUtils.DeleteFile(Staged);
          AFailure := omfCopyFailed;
          Exit;
        end;
        try
          {$IFDEF OBJECTSTORE_TESTING}
          if Assigned(ObjectStoreAfterMaterializeCopyTestHook) then
            ObjectStoreAfterMaterializeCopyTestHook(Expected, Staged);
          {$ENDIF}
          Actual := 'sha256:' + StagedVerificationHash(Staged);
          if Actual <> Expected then
          begin
            SysUtils.DeleteFile(Staged);
            AFailure := omfStagedHashMismatch;
            Exit;
          end;
          if not AtomicMoveFile(Staged, ADestination) then
            raise ELWPTObjectStoreError.CreateFmt(
              'failed to materialize object %s at %s',
              [Expected, ADestination]);
          AFailure := omfNone;
          Result := True;
        except
          if FileExists(Staged) then SysUtils.DeleteFile(Staged);
          raise;
        end;
      finally
        ALease := ObjectLease;
        ObjectLease := nil;
      end;
    except
      ALease.Free;
      ALease := nil;
      raise;
    end;
  finally
    ObjectLease.Free;
  end;
end;

end.
