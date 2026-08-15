{ LWPT.ObjectStore — per-user cache-root resolution and immutable SHA-256
  object storage. The unit knows nothing about dependency resolution or build
  results: callers select a namespace root and supply the expected digest. }
unit LWPT.ObjectStore;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

const
  CACHE_DIR_ENV = PROJECT_NAME + '_CACHE_DIR';
  DEPENDENCY_ARCHIVE_NAMESPACE = 'dependency-archives';

type
  ELWPTObjectStoreError = class(ELWPTError);

  {$IFDEF OBJECTSTORE_TESTING}
  TLWPTObjectStoreBeforeQuarantineHook = procedure(const APath: string);
  {$ENDIF}

  TLWPTImmutableObjectStore = class
  private
    FRoot: string;
    function CanonicalDigest(const ADigest: string): string;
    function Quarantine(const APath, ADigest: string;
      out AQuarantinePath: string): Boolean;
  public
    constructor Create(const ARoot: string);
    function ObjectPath(const ADigest: string): string;
    function Lookup(const ADigest: string; out APath: string): Boolean;
    function Admit(const ASourcePath, AExpectedDigest: string): string;
    function Materialize(const ADigest, ADestination,
      ATmpRoot: string): Boolean;
    property Root: string read FRoot;
  end;

function ResolveCacheRoot: string;
function ResolveCacheRootFromValues(const AOverride, AHome,
  AXDGCacheHome, ALocalAppData: string): string;
function DependencyArchiveStoreRoot(const ACacheRoot: string): string;

{$IFDEF OBJECTSTORE_TESTING}
var
  ObjectStoreBeforeQuarantineTestHook:
    TLWPTObjectStoreBeforeQuarantineHook;
{$ENDIF}

implementation

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

constructor TLWPTImmutableObjectStore.Create(const ARoot: string);
begin
  inherited Create;
  if ARoot = '' then
    raise ELWPTObjectStoreError.Create('object-store root cannot be empty');
  FRoot := NormalizeRoot(ARoot);
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
  ForceDirectories(QuarantineRoot);
  AQuarantinePath := MakeTmpPath(QuarantineRoot,
    Copy(CanonicalDigest(ADigest), 8, 12) + '-corrupt');
  Result := AtomicMoveFile(APath, AQuarantinePath);
  if not Result then AQuarantinePath := '';
end;

function TLWPTImmutableObjectStore.Lookup(const ADigest: string;
  out APath: string): Boolean;
var
  Expected, Actual, QuarantinePath: string;
begin
  Expected := CanonicalDigest(ADigest);
  APath := ObjectPath(Expected);
  if not FileExists(APath) then Exit(False);
  Actual := 'sha256:' + SHA256File(APath);
  if Actual = Expected then Exit(True);
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

function TLWPTImmutableObjectStore.Admit(const ASourcePath,
  AExpectedDigest: string): string;
var
  Expected, Existing, TmpRoot, Staged, Actual: string;
begin
  Expected := CanonicalDigest(AExpectedDigest);
  if not FileExists(ASourcePath) then
    raise ELWPTObjectStoreError.CreateFmt(
      'object admission source does not exist: %s', [ASourcePath]);
  Actual := 'sha256:' + SHA256File(ASourcePath);
  if Actual <> Expected then
    raise ELWPTObjectStoreError.CreateFmt(
      'object admission hash mismatch: expected %s, got %s',
      [Expected, Actual]);
  if Lookup(Expected, Existing) then Exit(Existing);

  Result := ObjectPath(Expected);
  TmpRoot := IncludeTrailingPathDelimiter(FRoot) + 'tmp';
  ForceDirectories(TmpRoot);
  Staged := MakeTmpPath(TmpRoot, 'object');
  if not CopyFileContent(ASourcePath, Staged) then
    raise ELWPTObjectStoreError.CreateFmt(
      'failed to stage object %s', [Expected]);
  try
    Actual := 'sha256:' + SHA256File(Staged);
    if Actual <> Expected then
      raise ELWPTObjectStoreError.CreateFmt(
        'staged object hash mismatch: expected %s, got %s',
        [Expected, Actual]);
    ForceDirectories(ExtractFileDir(Result));
    { Replacement is safe because every competing writer must prove the same
      digest before reaching this point. AtomicReplaceFile keeps readers from
      observing a partial object; a Windows sharing race accepts the already
      published verified winner. }
    if not AtomicReplaceFile(Staged, Result) then
    begin
      if Lookup(Expected, Existing) then
      begin
        SysUtils.DeleteFile(Staged);
        Exit(Existing);
      end;
      raise ELWPTObjectStoreError.CreateFmt(
        'failed to publish object %s', [Expected]);
    end;
  except
    if FileExists(Staged) then SysUtils.DeleteFile(Staged);
    raise;
  end;
end;

function TLWPTImmutableObjectStore.Materialize(const ADigest,
  ADestination, ATmpRoot: string): Boolean;
var
  Expected, SourcePath, Staged, Actual: string;
begin
  Expected := CanonicalDigest(ADigest);
  if not Lookup(Expected, SourcePath) then Exit(False);
  ForceDirectories(ATmpRoot);
  Staged := MakeTmpPath(ATmpRoot, 'cache-object');
  if not CopyFileContent(SourcePath, Staged) then
  begin
    if FileExists(Staged) then SysUtils.DeleteFile(Staged);
    Exit(False);
  end;
  try
    Actual := 'sha256:' + SHA256File(Staged);
    if Actual <> Expected then
    begin
      SysUtils.DeleteFile(Staged);
      Exit(False);
    end;
    if not AtomicMoveFile(Staged, ADestination) then
      raise ELWPTObjectStoreError.CreateFmt(
        'failed to materialize object %s at %s',
        [Expected, ADestination]);
    Result := True;
  except
    if FileExists(Staged) then SysUtils.DeleteFile(Staged);
    raise;
  end;
end;

end.
