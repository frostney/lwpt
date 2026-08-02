{ LWPT.Install — install transaction, resolver, lockfile/cfg, fetch, and extraction. }
unit LWPT.Install;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Manifest;

type
  TResolved = record
    Name         : string;
    Version      : string;       { concrete tag / SHA / branch; '' for local + url }
    CommitSHA    : string;       { authoritative fetched commit identity }
    SourceIdentity: string;      { canonical source + extraction policy identity }
    ConstraintFingerprint: string; { complete graph requirements for frozen }
    SrcOriginal  : string;       { the manifest's source string, verbatim }
    SrcKind      : TSourceKind;
    SrcHost      : THostKind;    { skGitHost only }
    SrcHostName  : string;       { hkCustom only — the [sources.<name>] key }
    SrcLocator   : string;       { owner/repo, URL, or path (post-prefix-strip) }
    ResolvedURL  : string;       { the actual archive URL; '' for skLocal }
    Hash         : string;       { sha256 of extracted tree (computedHash) }
    ArchiveHash  : string;       { sha256 of the .tar.gz; '' for skLocal }
    UnitDir      : string;       { the dep's modules root }
    UnitSubdirs  : array of string;  { from dep's lwpt.toml `units = [...]`;
                                       relative paths under UnitDir where its
                                       .pas files live. Drives -Fu / -Fi
                                       emission so consumers find the units. }
    Archive      : string;       { path to the committed .tar.gz; '' for skLocal }
    IncludeDir   : string;       { -Fi (explicit, separate from units) }
    RequiredBy   : string;       { first requirer, for conflict messages }
  end;
  TResolvedArray = array of TResolved;

  TInstallTransactionMode = (itmMaterialize, itmFrozenVerify);

  TInstallTransactionResult = record
    PackageCount : Integer;
    LockfilePath : string;
    CfgPath      : string;
    Resolved     : TResolvedArray;  { the materialized/verified graph }
  end;

function  LoadLockfile(const APath: string): TResolvedArray;
function  ExtractArchive(const AArchivePath, ADest: string; const ASubDir: string = ''): Integer;
procedure VerifyAgainstLockfile(const AResolved: array of TResolved; const ALockEntries: array of TResolved);
function  PruneOrphanedPackages(const AOldLock, ANewLock: array of TResolved; const AModulesRoot, AArchivesRoot: string): Integer;
function  RunInstallTransaction(const AContext: TManifestContext; const AMode: TInstallTransactionMode): TInstallTransactionResult;
function  RunManifestMutationTransaction(const AContext: TManifestContext; const AManifestLines: TStringList): TInstallTransactionResult;
procedure RecoverInterruptedInstall(const AContext: TManifestContext);

implementation

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  HTTPClient,
  LWPT.GitProtocol,
  LWPT.Resolver,
  Semver,
  TOML,
  zstream;

const
  MAX_ARCHIVE_RESPONSE_BYTES = Int64(256) * 1024 * 1024;
  ARCHIVE_REQUEST_TIMEOUT_MILLISECONDS = 5 * 60 * 1000;

type
  TInstallLock = class
  private
    FPath: string;
    {$IFDEF UNIX}
    FFD: LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    {$ENDIF}
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
  end;

{ Semver is provided by the vendored Semver unit — a full
  node-semver port (ParseRange, Satisfies, MaxSatisfying, RangeIntersects).
  gpm uses DefaultSemverOptions for all calls. }

{ ===========================================================================
  Source fetchers — HTTPS GET via the HTTPClient package (raw sockets +
  per-platform TLS backend per ADR-0016). Each source kind has its own
  URL template in FetchURL below; the actual GET goes through HTTPGet.
  =========================================================================== }
{ Like IncludeTrailingPathDelimiter but for URLs (always '/'). }
function IncludeHTTPPathDelimiter(const S: string): string;
begin
  if (S <> '') and (S[Length(S)] <> '/') then Result := S + '/'
  else Result := S;
end;

{ Repo basename from an owner/repo slug — needed for GitLab's archive URL,
  which embeds the repo name in the filename. }
function RepoBasename(const ASlug: string): string;
var P: Integer;
begin
  Result := ASlug;
  P := Length(Result);
  while (P > 0) and (Result[P] <> '/') do Dec(P);
  if P > 0 then Result := Copy(Result, P + 1, MaxInt);
end;

{ Split a slug like "owner/repo" into its two halves. Used by the
  custom-host renderer to fill the {user} + {repository}
  placeholders. Returns False if the slug doesn't have exactly one
  forward slash. }
function SplitOwnerRepo(const ASlug: string;
  out AUser, ARepo: string): Boolean;
var Slash: Integer;
begin
  Slash := Pos('/', ASlug);
  Result := (Slash > 1) and (Slash < Length(ASlug));
  if not Result then Exit;
  AUser := Copy(ASlug, 1, Slash - 1);
  ARepo := Copy(ASlug, Slash + 1, MaxInt);
end;

{ Substitute the {user} / {repository} / {ref} placeholders. Used
  for hkCustom URL assembly. The actual placeholder strings live in
  the PLACEHOLDER_* constants in the interface — if the syntax ever
  changes (escape rules, brace style, etc.) it changes in one spot. }
function RenderURLTemplate(const ATemplate, AUser, ARepo,
  AResolvedRef: string): string;
begin
  Result := StringReplace(ATemplate, PLACEHOLDER_USER,       AUser,        [rfReplaceAll]);
  Result := StringReplace(Result,    PLACEHOLDER_REPOSITORY, ARepo,        [rfReplaceAll]);
  Result := StringReplace(Result,    PLACEHOLDER_REF,        AResolvedRef, [rfReplaceAll]);
end;

{ Custom-source lookup that errors if the dep references an undeclared
  prefix. Should not happen for manifest-derived deps (LoadManifest
  validates the prefix), but the resolver also touches deps from
  child manifests so the validation is a belt-and-braces check. }
function ResolveCustomSourceOrDie(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray;
  out AOut: TCustomSource): Boolean;
begin
  Result := FindCustomSource(ACustomSources, ADep.SrcHostName, AOut);
  if not Result then
    raise EManifestError.CreateFmt(
      'dependency "%s" uses custom prefix "%s:" but no [sources.%s] '
      + 'table is declared in lwpt.toml', [ADep.Name, ADep.SrcHostName,
      ADep.SrcHostName]);
end;

{ Build the archive URL for a network-sourced dep at a resolved ref.
  Called from the resolver AFTER tag resolution — AResolvedRef is the
  concrete tag name (as-on-wire), a commit SHA, or '' for skURL.
  ACustomSources is the manifest's [sources] table; needed for
  hkCustom dispatch. }
function FetchURL(const ADep: TDependency; const AResolvedRef: string;
  const ACustomSources: TCustomSourceArray): string;
var Custom: TCustomSource; Repo, User, RepoName: string;
begin
  case ADep.SrcKind of
    skURL:
      Result := ADep.SrcLocator;     { the URL IS the locator, verbatim }
    skGitHost:
    begin
      Repo := RepoBasename(ADep.SrcLocator);
      case ADep.SrcHost of
        hkGitHub:
          Result := 'https://github.com/' + ADep.SrcLocator +
                    '/archive/' + AResolvedRef + '.tar.gz';
        hkGitLab:
          Result := 'https://gitlab.com/' + ADep.SrcLocator +
                    '/-/archive/' + AResolvedRef + '/'
                    + Repo + '-' + AResolvedRef + '.tar.gz';
        hkBitbucket:
          Result := 'https://bitbucket.org/' + ADep.SrcLocator +
                    '/get/' + AResolvedRef + '.tar.gz';
        hkCustom:
        begin
          ResolveCustomSourceOrDie(ADep, ACustomSources, Custom);
          if not SplitOwnerRepo(ADep.SrcLocator, User, RepoName) then
            raise EManifestError.CreateFmt(
              'dependency "%s": custom source locator "%s" must be '
              + '"user/repository" shape (got %d slash-separated parts)',
              [ADep.Name, ADep.SrcLocator, 0]);
          Result := RenderURLTemplate(Custom.ArchiveTemplate,
            User, RepoName, AResolvedRef);
        end;
      end;
    end;
  else
    Result := '';   { skLocal handled outside this function (no URL) }
  end;
end;

{ Build the git smart-HTTP base URL for tag listing. Same host
  templates as the archive endpoints but pointing at the .git
  endpoint that serves info/refs. For hkCustom we use the user's
  GitTemplate with {user} / {repository} substituted ({ref} is
  meaningless here — info/refs lists ALL refs). }
function GitRepoURL(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray): string;
var Custom: TCustomSource; User, RepoName: string;
begin
  case ADep.SrcHost of
    hkGitHub    : Result := 'https://github.com/'    + ADep.SrcLocator + '.git';
    hkGitLab    : Result := 'https://gitlab.com/'    + ADep.SrcLocator + '.git';
    hkBitbucket : Result := 'https://bitbucket.org/' + ADep.SrcLocator + '.git';
    hkCustom:
    begin
      ResolveCustomSourceOrDie(ADep, ACustomSources, Custom);
      if not SplitOwnerRepo(ADep.SrcLocator, User, RepoName) then
        raise EManifestError.CreateFmt(
          'dependency "%s": custom source locator "%s" must be '
          + '"user/repository" shape', [ADep.Name, ADep.SrcLocator]);
      Result := RenderURLTemplate(Custom.GitTemplate,
        User, RepoName, '');
    end;
  else
    Result := '';
  end;
end;

{ ───────────────────────────────────────────────────────────────────
  Tag resolution — turn a (VersionKind, VersionSpec) pair into
  a concrete wire-name git ref. Behavior per ADR-0009 §"Spec parsing":

    vkNone        → '' (caller treats local sources outside this path)
    vkSemverRange → ListRemoteRefs + MaxSatisfying, with v-prefix
                    stripped on the tag-list side for comparison.
                    Returns the matched tag's wire name (with or
                    without v as the repo published it).
    vkSemverExact → try the spec verbatim AND v<spec> against the
                    tag list; first match wins.
    vkCommitSha   → returned verbatim (no tag lookup needed).
    vkLiteralTag  → returned verbatim (no SemVer logic). If the tag
                    isn't actually present in the repo, the eventual
                    fetch will 404 — we surface that as EFetchError.
  ─────────────────────────────────────────────────────────────────── }
function StripVPrefix(const S: string): string;
begin
  if (Length(S) > 0) and ((S[1] = 'v') or (S[1] = 'V')) then
    Result := Copy(S, 2, MaxInt)
  else
    Result := S;
end;

{ ===========================================================================
  Registry version negotiation (http source) — tracked in GitHub issue #29

  The skHttp source kind and the registry consumer (NegotiateVersion,
  PickFromIndex) were removed from v1 per ADR-0004. The spike code is
  archived at docs/spikes/http-registry-spike.md as prior art for issue #29,
  which will spec the registry format and re-derive the
  consumer against the spec.
  =========================================================================== }

{ ===========================================================================
  Hardening helpers — atomic writes via .lwpt/tmp/ with EXDEV fallback.

  The contract from AGENTS.md Hard Constraints: every multi-step write
  to a committed path goes through .lwpt/tmp/ + atomic rename. A crash
  mid-write leaves the orphan in tmp (cleaned up by lwpt repair or by
  the next lwpt install's startup pass), never a half-written archive
  / module tree / lockfile / cfg.

  Atomic-rename across filesystems fails with EXDEV on POSIX (28 on
  Darwin/Linux; the constant differs between RTL builds). The fallback
  is byte-copy then delete — still safer than direct overwrite because
  the source remains untouched until the copy completes. ADR-0002
  consequences mentions this; docs/tooling.md is the canonical reference.
  =========================================================================== }
const
  LOCKFILE_SCHEMA_VERSION = 3;

{ ── TInstallLock ──────────────────────────────────────────────────── }

{ Cross-process install lock. Uses O_CREAT|O_EXCL for atomic create-
  if-not-exists — the kernel guarantees only one process wins the
  create. If the file already exists, we read its PID for diagnostics
  and raise EConcurrencyError pointing the user at `lwpt repair` for
  stale locks (e.g. a crashed previous install).

  Unlike flock-based locking, the file is NOT auto-released on process
  crash — the file persists until explicitly deleted. `lwpt repair`
  removes it, as does the destructor of a normally-completing lock.
  The recovery message is explicit about this. }

{$IFDEF UNIX}
constructor TInstallLock.Create(const APath: string);
var
  Holder: AnsiString;
  Buf: array[0..63] of AnsiChar;
  N, i: LongInt;
  PidLine: AnsiString;
  DstDir: string;
begin
  FPath := APath;
  DstDir := ExtractFileDir(APath);
  if DstDir <> '' then ForceDirectories(DstDir);

  { Atomic create-if-not-exists. O_EXCL turns this into a kernel-level
    test-and-set: at most one process wins. Mode 0644 (readable by
    others for diagnostics). }
  FFD := FpOpen(PChar(APath), O_RDWR or O_CREAT or O_EXCL, &644);
  if FFD < 0 then
  begin
    { File exists. Read the PID for the diagnostic. The lock is held
      by either a live concurrent install or a crashed previous one;
      we can't tell the difference cheaply, so we point the user at
      `lwpt repair`. }
    Holder := 'unknown';
    FFD := FpOpen(PChar(APath), O_RDONLY, 0);
    if FFD >= 0 then
    begin
      N := FpRead(FFD, Buf[0], SizeOf(Buf) - 1);
      FpClose(FFD);
      if N > 0 then
      begin
        for i := 0 to N - 1 do
          if (Buf[i] = #10) or (Buf[i] = #13) then
          begin N := i; Break; end;
        if N > 0 then
        begin
          SetLength(Holder, N);
          Move(Buf[0], Holder[1], N);
        end;
      end;
    end;
    FFD := -1;
    raise EConcurrencyError.CreateFmt(
      'another lwpt install is in progress (lock holder PID: %s) — '
      + 'or the previous install crashed without releasing the lock. '
      + 'If you''re certain no other process is running, '
      + 'run `lwpt repair` to clear the stale lock.',
      [string(Holder)]);
  end;

  { Write our PID so a concurrent contender gets a useful diagnostic. }
  PidLine := AnsiString(IntToStr(GetProcessID)) + AnsiChar(#10);
  FpWrite(FFD, PidLine[1], Length(PidLine));
end;

destructor TInstallLock.Destroy;
begin
  if FFD >= 0 then
  begin
    FpClose(FFD);
    FFD := -1;
    SysUtils.DeleteFile(FPath);   { release: file existence == lock held }
  end;
  inherited Destroy;
end;
{$ELSE}
constructor TInstallLock.Create(const APath: string);
const
  LOCKFILE_EXCLUSIVE_LOCK_LWPT = $00000002;
  LOCKFILE_FAIL_IMMEDIATELY_LWPT = $00000001;
  LOCKFILE_LOCK_OFFSET_LWPT = 1024;
var
  Holder, DstDir: string;
  SL: TStringList;
  PidLine: AnsiString;
  BytesWritten: DWORD;
  LastErr: DWORD;
  Ov: TOverlapped;
begin
  FPath := APath;
  FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
  DstDir := ExtractFileDir(APath);
  if DstDir <> '' then ForceDirectories(DstDir);

  FHandle := Windows.CreateFileW(PWideChar(UnicodeString(APath)),
    Windows.GENERIC_READ or Windows.GENERIC_WRITE,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE, nil, Windows.CREATE_NEW,
    Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    LastErr := Windows.GetLastError;
    if (LastErr <> Windows.ERROR_FILE_EXISTS)
      and (LastErr <> Windows.ERROR_ALREADY_EXISTS) then
      raise ELWPTError.CreateFmt(
        'failed to create install lock %s: %s (code %d)',
        [APath, SysErrorMessage(LastErr), LastErr]);

    Holder := 'unknown';
    if FileExists(APath) then
    begin
      SL := TStringList.Create;
      try
        SL.LoadFromFile(APath);
        if SL.Count > 0 then Holder := Trim(SL[0]);
      finally
        SL.Free;
      end;
    end;
    raise EConcurrencyError.CreateFmt(
      'another ' + PROGRAM_NAME
      + ' install is in progress (lock holder PID: %s) — '
      + 'or the previous install crashed without releasing the lock. '
      + 'If you''re certain no other process is running, '
      + 'run `' + PROGRAM_NAME + ' repair` to clear the stale lock.',
      [Holder]);
  end;

  PidLine := AnsiString(IntToStr(GetProcessID)) + AnsiChar(#10);
  if Length(PidLine) > 0 then
    Windows.WriteFile(FHandle, PidLine[1], Length(PidLine),
      BytesWritten, nil);
  Windows.CloseHandle(FHandle);
  FHandle := Windows.CreateFileW(PWideChar(UnicodeString(APath)),
    Windows.GENERIC_READ,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE, nil, Windows.OPEN_EXISTING,
    Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
    raise EConcurrencyError.CreateFmt(
      'failed to reopen %s after creating the install lock', [APath]);

  FillChar(Ov, SizeOf(Ov), 0);
  Ov.Offset := LOCKFILE_LOCK_OFFSET_LWPT;
  if not Windows.LockFileEx(FHandle,
    LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
    0, 1, 0, Ov) then
  begin
    Windows.CloseHandle(FHandle);
    FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
    SysUtils.DeleteFile(FPath);
    raise EConcurrencyError.Create(
      'another ' + PROGRAM_NAME
      + ' install is in progress. Try again when it finishes.');
  end;
end;

destructor TInstallLock.Destroy;
const
  LOCKFILE_LOCK_OFFSET_LWPT = 1024;
var
  Ov: TOverlapped;
begin
  if FHandle <> THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    FillChar(Ov, SizeOf(Ov), 0);
    Ov.Offset := LOCKFILE_LOCK_OFFSET_LWPT;
    Windows.UnlockFileEx(FHandle, 0, 1, 0, Ov);
    Windows.CloseHandle(FHandle);
    FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
    SysUtils.DeleteFile(FPath);
  end;
  inherited Destroy;
end;
{$ENDIF}

{ FetchToCache writes the archive atomically into
  ArchivesRoot/<name>-<version>.tar.gz via the tmp dir, and sets
  UnitDir = ModulesRoot/<name>. The graph resolver is responsible
  for the subsequent ExtractArchive call. Returns the archive's sha256
  in AArchiveHash so the resolver can record it in the lockfile.

  Local sources do not produce an archive (skLocal copies the source
  tree directly); AArchive is '' and AArchiveHash is '' in that case. }
function ExpandLocalPath(const APath: string): string;
begin
  if (Length(APath) >= 2) and (APath[1] = '~') and (APath[2] = '/') then
    Result := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('HOME'))
              + Copy(APath, 3, MaxInt)
  else
    Result := APath;
end;

function IsAbsoluteFilesystemPath(const APath: string): Boolean; inline;
begin
  Result := False;
  if APath = '' then Exit;
  if APath[1] in ['/', '\'] then Exit(True);
  if (Length(APath) >= 3)
     and (APath[2] = ':')
     and (APath[3] in ['/', '\']) then
    Exit(True);
end;

function ResolveProjectPath(const AProjectRoot, APath: string): string;
var
  Root : string;
begin
  if APath = '' then Exit('');
  if (Length(APath) >= 2) and (APath[1] = '~') and (APath[2] = '/') then
    Exit(ExpandFileName(ExpandLocalPath(APath)));
  if IsAbsoluteFilesystemPath(APath) then
    Exit(ExpandFileName(APath));

  Root := AProjectRoot;
  if Root = '' then Root := GetCurrentDir;
  Result := ExpandFileName(IncludeTrailingPathDelimiter(Root) + APath);
end;

function IsPathInside(const AParent, AChild: string): Boolean;
var
  ParentAbs, ChildAbs: string;
begin
  ParentAbs := IncludeTrailingPathDelimiter(ExpandFileName(AParent));
  ChildAbs := IncludeTrailingPathDelimiter(ExpandFileName(AChild));
  {$IFDEF MSWINDOWS}
  Result := SameText(Copy(ChildAbs, 1, Length(ParentAbs)), ParentAbs);
  {$ELSE}
  Result := Copy(ChildAbs, 1, Length(ParentAbs)) = ParentAbs;
  {$ENDIF}
end;

function SafeArchiveTag(const ARef: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(ARef) do
    if (ARef[i] in ['a'..'z']) or (ARef[i] in ['A'..'Z'])
       or (ARef[i] in ['0'..'9']) or (ARef[i] in ['.', '_', '-']) then
      Result := Result + ARef[i]
    else
      Result := Result + '_';
  if Result = '' then
    Result := 'ref';
end;

function ArchivePathForRef(const AArchivesRoot, AName: string;
  ASrcKind: TSourceKind; const AResolvedRef: string): string;
var ArchiveTag: string;
begin
  if ASrcKind = skURL then
    ArchiveTag := 'url'
  else
    ArchiveTag := SafeArchiveTag(AResolvedRef);
  Result := IncludeTrailingPathDelimiter(AArchivesRoot)
          + AName + '-' + ArchiveTag + '.tar.gz';
end;

function LoadTestFixtureArchive(const ARoot, AName, ARef: string;
  out ABody: TBytes): Boolean;
var ArchivePath, RequestPath: string; Stream: TFileStream;
  RequestBytes: RawByteString;
begin
  Result := False;
  ArchivePath := IncludeTrailingPathDelimiter(ARoot) + 'archives/'
    + AName + '/' + SafeArchiveTag(ARef) + '.tar.gz';
  if not FileExists(ArchivePath) then
    raise EFetchError.CreateFmt(
      'test git fixture has no immutable archive for %s@%s (%s)',
      [AName, ARef, ArchivePath]);
  Stream := TFileStream.Create(ArchivePath, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > MAX_ARCHIVE_RESPONSE_BYTES then
      raise EFetchError.CreateFmt(
        'test git fixture archive exceeds response bound: %s',
        [ArchivePath]);
    SetLength(ABody, Stream.Size);
    if Length(ABody) > 0 then Stream.ReadBuffer(ABody[0], Length(ABody));
  finally
    Stream.Free;
  end;
  RequestPath := IncludeTrailingPathDelimiter(ARoot) + 'requests.log';
  ForceDirectories(ExtractFileDir(RequestPath));
  if FileExists(RequestPath) then
    Stream := TFileStream.Create(RequestPath,
      fmOpenReadWrite or fmShareDenyNone)
  else
    Stream := TFileStream.Create(RequestPath, fmCreate or fmShareDenyNone);
  try
    Stream.Seek(0, soEnd);
    RequestBytes := RawByteString('archive|' + AName + '|' + ARef
      + LineEnding);
    if Length(RequestBytes) > 0 then
      Stream.WriteBuffer(RequestBytes[1], Length(RequestBytes));
  finally
    Stream.Free;
  end;
  Result := True;
end;

function FetchToCache(const ADep: TDependency;
  const AResolvedRef, AModulesRoot, AArchivesRoot, ATmpRoot,
    AProjectRoot: string;
  const ACustomSources: TCustomSourceArray;
  const AWorkspaces: TWorkspaceArray;
  out AUnitDir, AArchive, AArchiveHash, AResolvedURL: string): Boolean;
var
  URL, LocalPath : string;
  Resp : THTTPResponse;
  NoHeaders : THTTPHeaders;
  HTTPOptions : THTTPRequestOptions;
  EffectiveDep : TDependency;
  k : Integer;
  WSPath : string;
  AvailableNames : string;
  StagePath, FixtureRoot : string;

  procedure StageLocalCopy(const AMessage: string);
  begin
    StagePath := MakeTmpPath(ATmpRoot, 'local-' + ADep.Name);
    ForceDirectories(StagePath);
    try
      CopyDirTree(LocalPath, StagePath);
      if not AtomicMoveDir(StagePath, AUnitDir) then
        raise EFetchError.CreateFmt(
          'failed to commit local source "%s" into %s',
          [LocalPath, AUnitDir]);
    except
      on E: Exception do
      begin
        if DirectoryExists(StagePath) then
          WipeDir(StagePath);
        raise;
      end;
    end;
    WriteLn('  copied ', ADep.Name, AMessage);
  end;
begin
  Result := False;
  AUnitDir := IncludeTrailingPathDelimiter(AModulesRoot) + ADep.Name;
  AArchive := '';
  AArchiveHash := '';
  AResolvedURL := '';
  ForceDirectories(AModulesRoot);

  { workspace: protocol resolution (ADR-0014 amendment "Workspaces"
    Q20=a strict semantics). Look up the dep by name in the root's
    discovered workspace set; if found, treat as a skLocal install
    against the workspace's resolved path. If not found, hard error
    naming the available workspaces — never fall through to a
    registry / git-host lookup (strict workspace-only). }
  if ADep.SrcKind = skWorkspace then
  begin
    WSPath := '';
    for k := 0 to High(AWorkspaces) do
      if AWorkspaces[k].Name = ADep.Name then
      begin
        WSPath := AWorkspaces[k].Path; Break;
      end;
    if WSPath = '' then
    begin
      AvailableNames := '';
      for k := 0 to High(AWorkspaces) do
      begin
        if k > 0 then AvailableNames := AvailableNames + ', ';
        AvailableNames := AvailableNames + AWorkspaces[k].Name;
      end;
      if AvailableNames = '' then AvailableNames := '(none — no [workspaces] declared in root manifest)';
      raise EFetchError.CreateFmt(
        'workspace:%s for dependency "%s" not found; available: %s',
        [ADep.VersionSpec, ADep.Name, AvailableNames]);
    end;
    { Rewrite the dep to a synthetic skLocal entry pointing at the
      workspace's path; falls through into the skLocal branch below. }
    EffectiveDep := ADep;
    EffectiveDep.SrcKind    := skLocal;
    EffectiveDep.SrcLocator := WSPath;
    Result := FetchToCache(EffectiveDep, AResolvedRef,
      AModulesRoot, AArchivesRoot, ATmpRoot, AProjectRoot,
      ACustomSources, AWorkspaces,
      AUnitDir, AArchive, AArchiveHash, AResolvedURL);
    Exit;
  end;

  if ADep.SrcKind = skLocal then
  begin
    LocalPath := ResolveProjectPath(AProjectRoot, ADep.SrcLocator);
    if not DirectoryExists(LocalPath) then
      raise EFetchError.CreateFmt(
        'local source for "%s" not found: %s', [ADep.Name, LocalPath]);
    { Every local/workspace dependency is a private copied candidate. The
      fixed-point resolver filters and validates these exact bytes before
      publication; no caller can opt back into a live project link. }
    StageLocalCopy('');
    Exit(True);
  end;

  { Network sources (skGitHost / skURL) go through HTTPGet. The URL
    is whatever FetchURL builds — already host-aware for skGitHost,
    or the verbatim URL for skURL. }
  URL := FetchURL(ADep, AResolvedRef, ACustomSources);
  if URL = '' then Exit(False);
  AResolvedURL := URL;

  FixtureRoot := SysUtils.GetEnvironmentVariable(
    PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR');
  if (FixtureRoot <> '') and (ADep.SrcKind = skGitHost) then
  begin
    Resp := Default(THTTPResponse);
    LoadTestFixtureArchive(FixtureRoot, ADep.Name, AResolvedRef,
      Resp.Body);
    Resp.StatusCode := 200;
  end
  else
  begin
    NoHeaders := nil;
    HTTPOptions := DefaultHTTPRequestOptions;
    HTTPOptions.MaxResponseBodyBytes := MAX_ARCHIVE_RESPONSE_BYTES;
    HTTPOptions.RequestTimeoutMilliseconds :=
      ARCHIVE_REQUEST_TIMEOUT_MILLISECONDS;
    try
      Resp := HTTPGet(URL, NoHeaders, HTTPOptions);
    except
      on E: EHTTPError do
        raise EFetchError.CreateFmt('fetch %s failed: %s',
          [URL, E.Message]);
    end;
    if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
      raise EFetchError.CreateFmt('fetch %s failed: HTTP %d %s',
        [URL, Resp.StatusCode, Resp.StatusText]);
  end;

  { Archive filename uses an escaped resolved ref for git-host sources,
    or the stable "url" tag for direct archive URLs. }
  AArchive := ArchivePathForRef(AArchivesRoot, ADep.Name, ADep.SrcKind,
    AResolvedRef);
  AArchiveHash := SHA256BytesPrefixed(Resp.Body);
  AtomicWriteBytes(AArchive, ATmpRoot, Resp.Body);
  Result := True;
end;

{ ===========================================================================
  Archive extraction — gunzip (zstream) then untar (libtar).
  GitHub serves .tar.gz; libtar reads plain tar, so this is a two-step:
  decompress to a temp .tar, then walk entries and write files under Dest.
  GitHub archives wrap everything in a single top-level dir
  (e.g. GocciaScript-main/...); StripComponents=1 removes it so Dest holds
  the package contents directly, which keeps -Fu paths clean.
  =========================================================================== }
function StripFirstComponent(const AName: string): string;
var P: Integer;
begin
  Result := StringReplace(AName, '\', '/', [rfReplaceAll]);
  P := Pos('/', Result);
  if P > 0 then
    Result := Copy(Result, P + 1, MaxInt)
  else
    Result := '';   { the top-level dir entry itself — skip }
end;

{ Parse an octal field from a tar header (NUL/space terminated). }
function TarOctal(const ABlock: array of Byte; AOffset, ALen: Integer): Int64;
var i: Integer; C: Byte;
begin
  Result := 0;
  for i := AOffset to AOffset + ALen - 1 do
  begin
    C := ABlock[i];
    if (C = 0) or (C = Ord(' ')) then
    begin
      if Result = 0 then Continue else Break;
    end;
    if (C >= Ord('0')) and (C <= Ord('7')) then
      Result := (Result shl 3) or Int64(C - Ord('0'));
  end;
end;

{ Read a NUL-terminated string from a tar header field. }
function TarStr(const ABlock: array of Byte; AOffset, ALen: Integer): string;
var i: Integer;
begin
  Result := '';
  for i := AOffset to AOffset + ALen - 1 do
  begin
    if ABlock[i] = 0 then Break;
    Result := Result + Chr(ABlock[i]);
  end;
end;

{ ===========================================================================
  Archive extraction — gunzip (zstream) then a direct ustar/POSIX tar reader.

  This replaces FPC's libtar, which has an incomplete ustar reader: it
  ignores the 155-byte `prefix` field (header offset 345). GitHub tarballs
  routinely split long paths as prefix + '/' + name (the standard ustar
  way to encode paths up to 255 chars), so libtar silently truncated and
  dropped every entry whose path exceeded 100 bytes. This reader joins
  prefix+name correctly and also follows GNU 'L'/'K' long-name entries.

  Header layout (512-byte block, POSIX 1003.1 ustar):
    0   name      100      124  size       12
    100 mode      8        136  mtime      12
    108 uid       8        148  checksum   8
    116 gid       8        156  typeflag   1
                           157  linkname   100
                           257  magic      6 ("ustar")
                           345  prefix     155
  GitHub archives wrap everything in one top-level dir; StripFirstComponent
  removes it so Dest holds package contents directly (clean -Fu paths).
  =========================================================================== }
{ Re-root a stripped path to a subsection. Given a path already past the
  top-level dir, and a SubDir prefix, returns the path relative to SubDir,
  or '' if the entry is not inside SubDir. SubDir='' means whole archive. }
function ReRootToSubDir(const AStrippedPath, ASubDir: string): string;
var Pfx: string;
begin
  if ASubDir = '' then Exit(AStrippedPath);
  Pfx := ASubDir;
  if (Pfx <> '') and (Pfx[Length(Pfx)] <> '/') then Pfx := Pfx + '/';
  if Copy(AStrippedPath, 1, Length(Pfx)) = Pfx then
    Result := Copy(AStrippedPath, Length(Pfx) + 1, MaxInt)
  else
    Result := '';   { outside the requested subsection — skip }
end;

function LooksLikeAbsoluteArchivePath(const APath: string): Boolean;
begin
  Result := (APath <> '') and ((APath[1] = '/') or (APath[1] = '\'));
  if Result then Exit;
  Result := (Length(APath) >= 2)
        and (APath[1] in ['a'..'z', 'A'..'Z'])
        and (APath[2] = ':');
end;

function PathIsInsideRoot(const ARoot, APath: string): Boolean;
var
  Root, Candidate: string;
begin
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ARoot));
  Candidate := ExpandFileName(APath);
  {$IFDEF MSWINDOWS}
  Result := SameText(Copy(Candidate, 1, Length(Root)), Root);
  {$ELSE}
  Result := Copy(Candidate, 1, Length(Root)) = Root;
  {$ENDIF}
end;

function ArchiveRelPathHasParentSegment(const ARelPath: string): Boolean;
var
  S, Part: string;
  StartAt, i: Integer;
begin
  Result := False;
  S := StringReplace(ARelPath, '\', '/', [rfReplaceAll]);
  StartAt := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = '/') then
    begin
      Part := Copy(S, StartAt, i - StartAt);
      if Part = '..' then Exit(True);
      StartAt := i + 1;
    end;
end;

function ResolveArchiveOutputPath(const ADest, ARelName: string): string;
var
  Rel, Candidate: string;
begin
  Rel := StringReplace(ARelName, '\', '/', [rfReplaceAll]);
  if (Rel = '') or LooksLikeAbsoluteArchivePath(Rel)
     or ArchiveRelPathHasParentSegment(Rel) then
    raise EExtractError.CreateFmt(
      'archive entry path escapes extraction root: %s', [ARelName]);
  Candidate := ExpandFileName(IncludeTrailingPathDelimiter(ADest) + Rel);
  if not PathIsInsideRoot(ADest, Candidate) then
    raise EExtractError.CreateFmt(
      'archive entry path escapes extraction root: %s', [ARelName]);
  Result := NativePath(Candidate);
end;

function ResolveArchiveLinkTarget(const ADest, ALinkPath,
  ATargetName, AFromRel: string): string;
var
  Target, Candidate: string;
begin
  Target := StringReplace(ATargetName, '\', '/', [rfReplaceAll]);
  if LooksLikeAbsoluteArchivePath(Target) then
    raise EExtractError.CreateFmt(
      'archive link target escapes extraction root: %s -> %s',
      [AFromRel, ATargetName]);
  Candidate := ExpandFileName(
    IncludeTrailingPathDelimiter(ExtractFileDir(ALinkPath)) + Target);
  if not PathIsInsideRoot(ADest, Candidate) then
    raise EExtractError.CreateFmt(
      'archive link target escapes extraction root: %s -> %s',
      [AFromRel, ATargetName]);
  Result := NativePath(Candidate);
end;

function ExtractArchive(const AArchivePath, ADest: string;
  const ASubDir: string = ''): Integer;
type
  TPendingLink = record
    LinkPath, TargetName, FromRel: string;
  end;
var
  GZ      : TGZFileStream;
  TarPath : string;
  TarOut  : TFileStream;
  TarIn   : TFileStream;
  Buf     : array[0..65535] of Byte;
  Hdr     : array[0..511] of Byte;
  N       : Integer;
  Name, Prefix, LinkName, RelName, OutName, OutDir : string;
  TypeFlag : Byte;
  Size, Remaining, ToRead : Int64;
  Pad     : Integer;
  FileOut : TFileStream;
  PendingLinks : array of TPendingLink;
  li      : Integer;
  ResolvedTarget : string;
  PendingLongName : string;
  ZeroBlocks : Integer;
  AllZero : Boolean;
  i       : Integer;
begin
  Result := 0;
  PendingLinks := nil;
  PendingLongName := '';
  if not FileExists(AArchivePath) then
    raise EExtractError.CreateFmt('archive not found: %s', [AArchivePath]);

  { step 1: gunzip AArchivePath -> TarPath }
  TarPath := AArchivePath + '.tar';
  GZ := TGZFileStream.Create(AArchivePath, gzopenread);
  try
    TarOut := TFileStream.Create(TarPath, fmCreate);
    try
      repeat
        N := GZ.Read(Buf, SizeOf(Buf));
        if N > 0 then TarOut.WriteBuffer(Buf, N);
      until N <= 0;
    finally
      TarOut.Free;
    end;
  finally
    GZ.Free;
  end;

  { step 2: walk the tar 512-byte blocks directly }
  ForceDirectories(ADest);
  TarIn := TFileStream.Create(TarPath, fmOpenRead or fmShareDenyNone);
  try
    ZeroBlocks := 0;
    while TarIn.Read(Hdr, 512) = 512 do
    begin
      { two consecutive all-zero blocks mark end of archive }
      AllZero := True;
      for i := 0 to 511 do
        if Hdr[i] <> 0 then begin AllZero := False; Break; end;
      if AllZero then
      begin
        Inc(ZeroBlocks);
        if ZeroBlocks >= 2 then Break;
        Continue;
      end;
      ZeroBlocks := 0;

      Name     := TarStr(Hdr, 0, 100);
      Size     := TarOctal(Hdr, 124, 12);
      TypeFlag := Hdr[156];
      LinkName := TarStr(Hdr, 157, 100);
      Prefix   := TarStr(Hdr, 345, 155);

      { GNU long-name ('L') / long-link ('K'): body holds the real name }
      if (TypeFlag = Ord('L')) or (TypeFlag = Ord('K')) then
      begin
        SetLength(PendingLongName, Size);
        if Size > 0 then
          TarIn.ReadBuffer(PendingLongName[1], Size);
        PendingLongName := Trim(StringReplace(PendingLongName, #0, '',
                             [rfReplaceAll]));
        Pad := (512 - (Size mod 512)) mod 512;
        if Pad > 0 then TarIn.Seek(Pad, soCurrent);
        Continue;   { real entry follows }
      end;

      { full path = prefix + '/' + name, unless a pending GNU long name }
      if PendingLongName <> '' then
      begin
        Name := PendingLongName;
        PendingLongName := '';
      end
      else if Prefix <> '' then
        Name := Prefix + '/' + Name;

      RelName := StripFirstComponent(Name);
      { if a subsection was requested, keep only entries inside it }
      if ASubDir <> '' then
        RelName := ReRootToSubDir(RelName, ASubDir);
      Pad := Integer((512 - (Size mod 512)) mod 512);

      if RelName = '' then
      begin
        { top-level dir entry, outside-subdir entry, or skipped —
          still must consume any data payload }
        if Size > 0 then TarIn.Seek(Size + Pad, soCurrent)
        else if Pad > 0 then TarIn.Seek(Pad, soCurrent);
        Continue;
      end;

      OutName := ResolveArchiveOutputPath(ADest, RelName);

      case Chr(TypeFlag) of
        '5':   { directory }
          ForceDirectories(OutName);
        '1', '2':   { hardlink ('1') / symlink ('2') — resolve later }
          begin
            SetLength(PendingLinks, Length(PendingLinks) + 1);
            PendingLinks[High(PendingLinks)].LinkPath   := OutName;
            PendingLinks[High(PendingLinks)].TargetName := LinkName;
            PendingLinks[High(PendingLinks)].FromRel    := RelName;
          end;
      else
        { '0', #0, or anything else: a regular file }
        begin
          OutDir := ExtractFileDir(OutName);
          if OutDir <> '' then ForceDirectories(OutDir);
          FileOut := TFileStream.Create(OutName, fmCreate);
          try
            Remaining := Size;
            while Remaining > 0 do
            begin
              ToRead := Remaining;
              if ToRead > SizeOf(Buf) then ToRead := SizeOf(Buf);
              N := TarIn.Read(Buf, ToRead);
              if N <= 0 then Break;
              FileOut.WriteBuffer(Buf, N);
              Dec(Remaining, N);
            end;
          finally
            FileOut.Free;
          end;
          Inc(Result);
        end;
      end;

      { skip the data payload + padding for non-file entries; for files
        we already consumed Size, so only padding remains }
      if Chr(TypeFlag) in ['5', '1', '2'] then
      begin
        if Size > 0 then TarIn.Seek(Size, soCurrent);
      end;
      if Pad > 0 then TarIn.Seek(Pad, soCurrent);
    end;
  finally
    TarIn.Free;
  end;

  { Deferred pass: resolve links now that all real files exist. }
  for li := 0 to High(PendingLinks) do
  begin
    ResolvedTarget := ResolveArchiveLinkTarget(ADest,
      PendingLinks[li].LinkPath, PendingLinks[li].TargetName,
      PendingLinks[li].FromRel);
    if FileExists(ResolvedTarget) then
    begin
      OutDir := ExtractFileDir(PendingLinks[li].LinkPath);
      if OutDir <> '' then ForceDirectories(OutDir);
      if not CopyFileContent(ResolvedTarget, PendingLinks[li].LinkPath) then
        WriteLn(ErrOutput, '  warning: failed to copy link target for ',
                PendingLinks[li].FromRel)
      else
        Inc(Result);
    end
    else if DirectoryExists(ResolvedTarget) then
    begin
      { A directory link whose target is its own parent (or any
        ancestor) would copy the directory into its own subtree and
        recurse until the path-length limit. The escape check in
        ResolveArchiveLinkTarget cannot catch this shape — the target
        is still inside the extraction root. Skip it — the link is
        unmaterializable junk, and skipping keeps the extracted tree
        (and so its computedHash) deterministic. }
      if PathContains(ResolvedTarget, PendingLinks[li].LinkPath) then
        WriteLn(ErrOutput,
                '  warning: link target contains the link itself, skipped: ',
                PendingLinks[li].FromRel, ' -> ', PendingLinks[li].TargetName)
      else
      begin
        SysUtils.DeleteFile(PendingLinks[li].LinkPath);
        CopyDirTree(ResolvedTarget, PendingLinks[li].LinkPath);
      end;
    end
    else
      WriteLn(ErrOutput, '  warning: link target missing, skipped: ',
              PendingLinks[li].FromRel, ' -> ', PendingLinks[li].TargetName);
  end;

  SysUtils.DeleteFile(TarPath);   { temp .tar no longer needed }
end;

{ ===========================================================================
  Lockfile  (TOML; one [package.NAME] table per entry, machine-written.
  Mirrors skills-lock.json field names. Round-trips through the TOML reader
  above, so `gpm install --frozen` can re-read it with no extra parser.)
  =========================================================================== }
{ TomlEscape lives in LWPT.Core — shared with LWPT.ManifestEdit so the
  lockfile writer and the manifest editor can't drift apart. }

procedure WriteLock(const APath, ATmpRoot: string;
  const AResolved: array of TResolved);
var
  SL : TStringList;
  i  : Integer;

  procedure KV(const AKey, AValue: string);
  begin
    SL.Add(AKey + ' = "' + TomlEscape(AValue) + '"');
  end;

begin
  SL := TStringList.Create;
  try
    SL.Add('# ' + LWPT.Core.LOCKFILE + ' - generated by ' + PROGRAM_NAME
           + '; do not edit by hand.');
    SL.Add('version = ' + IntToStr(LOCKFILE_SCHEMA_VERSION));
    for i := 0 to High(AResolved) do
    begin
      SL.Add('');
      SL.Add('[package.' + AResolved[i].Name + ']');
      { Schema v3 (ADR-0009 / ADR-0010):
          locator       = the manifest's source string, verbatim. The
                          host + kind are inferable from this string
                          via ParseDependencySource — no separate
                          sourceType field needed.
          resolvedRef   = the concrete git ref (tag/SHA/branch); ''
                          for skLocal + skURL.
          resolvedURL   = the actual archive URL fetched; '' for skLocal.
          computedHash  = sha256 of the extracted tree.
          archiveHash   = sha256 of the cached tarball; '' for skLocal. }
      KV('source',       AResolved[i].SrcOriginal);
      KV('resolvedRef',  AResolved[i].Version);
      KV('resolvedCommit', AResolved[i].CommitSHA);
      KV('sourceIdentity', AResolved[i].SourceIdentity);
      KV('constraintFingerprint', AResolved[i].ConstraintFingerprint);
      KV('resolvedURL',  AResolved[i].ResolvedURL);
      KV('computedHash', AResolved[i].Hash);
      KV('archiveHash',  AResolved[i].ArchiveHash);
    end;
    AtomicWriteText(APath, ATmpRoot, SL);
  finally
    SL.Free;
  end;
end;

{ ===========================================================================
  cfg emitter — FPC response fragment
  =========================================================================== }
function CfgDisplayPath(const AProjectRoot, APath: string): string;
var
  RootAbs, PathAbs : string;
begin
  if APath = '' then Exit('');
  if AProjectRoot = '' then Exit(APath);

  RootAbs := IncludeTrailingPathDelimiter(ExpandFileName(AProjectRoot));
  PathAbs := ExpandFileName(APath);
  if IsPathInside(RootAbs, PathAbs) then
  begin
    Result := ExtractRelativePath(RootAbs, PathAbs);
    Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
    Exit;
  end;

  Result := APath;
end;

procedure WriteCfg(const APath, ATmpRoot: string;
  const AResolved: array of TResolved; const AMan: TManifest;
  const AProjectRoot: string);
var SL: TStringList; i, j: Integer; SubPath: string;
begin
  SL := TStringList.Create;
  try
    SL.Add('# ' + CFG_FILE + ' - generated by ' + PROGRAM_NAME
           + '; do not edit. Use:  fpc @' + CFG_FILE + ' <program>.pas');
    { Pascal's convention is that .inc files live next to the .pas
      units that include them. Each dir we expose as a unit search
      path (-Fu) is therefore also exposed as an include search
      path (-Fi). The IncludeDir branch below stays for deps that
      explicitly carve out a separate include tree. }
    for i := 0 to High(AMan.Units) do
    begin
      SL.Add('-Fu' + AMan.Units[i]);
      SL.Add('-Fi' + AMan.Units[i]);
    end;
    for i := 0 to High(AResolved) do
    begin
      if AResolved[i].UnitDir = '' then Continue;
      { Each dep declares its own unit subdirs (typically ["source"])
        in its lwpt.toml. We emit -Fu / -Fi for each subdir UNDER
        the dep's modules root so FPC actually finds the .pas files.
        Pre-2026-05 bug: only the modules root was emitted, missing
        every dep that organised its code under source/ or src/.
        Fallback: when a dep declares no units array (old-style flat
        layout), we emit the modules root itself. }
      if Length(AResolved[i].UnitSubdirs) > 0 then
      begin
        for j := 0 to High(AResolved[i].UnitSubdirs) do
        begin
          SubPath := IncludeTrailingPathDelimiter(AResolved[i].UnitDir)
                   + AResolved[i].UnitSubdirs[j];
          SL.Add('-Fu' + CfgDisplayPath(AProjectRoot, SubPath));
          SL.Add('-Fi' + CfgDisplayPath(AProjectRoot, SubPath));
        end;
      end
      else
      begin
        SL.Add('-Fu' + CfgDisplayPath(AProjectRoot, AResolved[i].UnitDir));
        SL.Add('-Fi' + CfgDisplayPath(AProjectRoot, AResolved[i].UnitDir));
      end;
      if AResolved[i].IncludeDir <> '' then
        SL.Add('-Fi' + CfgDisplayPath(AProjectRoot, AResolved[i].IncludeDir));
    end;
    AtomicWriteText(APath, ATmpRoot, SL);
  finally
    SL.Free;
  end;
end;

{ ===========================================================================
  LoadLockfile — used by `lwpt install --frozen` to recover the recorded
  hashes for verification. Rejects v1 lockfiles with a clear migration
  hint; the user runs `lwpt install` (no --frozen) to regenerate.
  =========================================================================== }
function LoadLockfile(const APath: string): TResolvedArray;
var
  SL : TStringList;
  Parser : TTOMLParser;
  Root, PkgTable, EntryNode, VersionNode : TTOMLNode;
  Pair : TTOMLNodeMap.TKeyValuePair;
  n, SchemaVer : Integer;
  Entry : TResolved;
  Empty : TCustomSourceArray;
begin
  if not FileExists(APath) then
    raise ELockfileError.CreateFmt(
      'lockfile not found at %s. Run `lwpt install` to generate it.',
      [APath]);

  SL := TStringList.Create;
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    SL.LoadFromFile(APath);
    try
      Root := Parser.ParseDocument(SL.Text);
    except
      on E: ETOMLParseError do
        raise ELockfileError.CreateFmt(
          'lockfile %s is corrupt: %s. Delete it and run `lwpt install` '
          + 'to regenerate from the manifest.', [APath, E.Message]);
    end;
  finally
    SL.Free;
    Parser.Free;
  end;

  try
    { Schema check. Older lockfiles bail with a clear migration hint
      rather than silently accepting them. }
    VersionNode := TomlGet(Root, 'version');
    if not TomlIsInt(VersionNode) then
      raise ELockfileError.CreateFmt(
        'lockfile %s has no schema version. Delete and re-run `lwpt install`.',
        [APath]);
    SchemaVer := StrToIntDef(VersionNode.ScalarText, -1);
    if SchemaVer <> LOCKFILE_SCHEMA_VERSION then
      raise ELockfileError.CreateFmt(
        'lockfile %s is schema v%d; this lwpt expects v%d. '
        + 'Delete %s and run `lwpt install` to regenerate.',
        [APath, SchemaVer, LOCKFILE_SCHEMA_VERSION, APath]);

    PkgTable := TomlGet(Root, 'package');
    SetLength(Result, 0);
    if not TomlIsTable(PkgTable) then Exit;

    for Pair in PkgTable.Children do
    begin
      EntryNode := Pair.Value;
      if not TomlIsTable(EntryNode) then Continue;
      Entry := Default(TResolved);
      Entry.Name        := Pair.Key;
      Entry.SrcOriginal := TomlStr(EntryNode, 'source',      '');
      Entry.Version     := TomlStr(EntryNode, 'resolvedRef', '');
      Entry.CommitSHA   := TomlStr(EntryNode, 'resolvedCommit', '');
      Entry.SourceIdentity := TomlStr(EntryNode, 'sourceIdentity', '');
      Entry.ConstraintFingerprint := TomlStr(EntryNode,
        'constraintFingerprint', '');
      Entry.ResolvedURL := TomlStr(EntryNode, 'resolvedURL', '');
      Entry.Hash        := TomlStr(EntryNode, 'computedHash', '');
      Entry.ArchiveHash := TomlStr(EntryNode, 'archiveHash',  '');
      { Infer the source kind + host from the verbatim source string
        in permissive mode — LoadLockfile doesn't have the manifest's
        [sources] context, so unknown prefixes are treated as
        hkCustom without rejection. The resolvedURL carries the
        actual fetch URL, and verification only cares about the
        kind (skLocal vs not) for the archive-hash skip rule. }
      if Entry.SrcOriginal <> '' then
      begin
        SetLength(Empty, 0);
        ParseDependencySourceCore(Entry.SrcOriginal, Empty, True,
          Entry.SrcKind, Entry.SrcHost, Entry.SrcHostName,
          Entry.SrcLocator);
      end;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := Entry;
    end;
  finally
    Root.Free;
  end;
end;

{ ===========================================================================
  Resolver — flat graph, highest-compatible selection, hard conflict error.

  SPIKE NOTE: a full resolver walks each fetched package's own lwpt.toml to
  discover transitive deps. Here we resolve only the root manifest's direct
  deps and demonstrate the conflict check on the (name, range) pairs. The
  transitive walk is structurally a queue over FetchToCache results.
  =========================================================================== }

{ ---------------------------------------------------------------------------
  Transitive BFS resolver.

  Walks the dependency graph breadth-first starting from the root manifest.
  For each not-yet-seen package: fetch + extract it, read its own lwpt.toml,
  record the version constraint, and enqueue its dependencies. Every
  constraint seen for a given package name is accumulated; after the walk
  each package's constraints must be jointly satisfiable by one concrete
  version (FPC's single global unit namespace forbids coexistence), else a
  hard conflict naming both requirers.

  SPIKE SCOPE: concrete version selection from a registry is not modelled —
  for github/release sources the ref IS the concrete version, so the check
  is "do all requirers point at a compatible ref/range". A flat HTTP
  registry with multiple published versions would add a selection step
  here; the constraint-accumulation and conflict logic is the reusable core.
  --------------------------------------------------------------------------- }
type
  TResolveNode = record
    Name        : string;
    Specs       : array of string;   { every VersionSpec seen for this name }
    Kinds       : array of TVersionKind;
    Requirers   : array of string;   { parallel to Specs }
    SourceIdentities: array of string; { canonical source for each requirement }
    Dep         : TDependency;       { the first source spec seen }
    CustomSources: TCustomSourceArray;
    Version     : string;            { concrete (resolved ref or SHA) }
    CommitSHA   : string;            { authoritative advertised identity }
    SourceIdentity: string;
    ConstraintFingerprint: string;
    ResolvedURL : string;            { actual archive URL fetched }
    UnitDir     : string;            { the dep's modules root (.lwpt/modules/<name>) }
    UnitSubdirs : array of string;   { from ChildMan.Units — relative paths
                                       under UnitDir where the dep's .pas
                                       files actually live (typically
                                       ["source"]). Drives -Fu emission. }
    Hash        : string;            { tree hash of UnitDir contents }
    ArchiveHash : string;            { sha256 of the .tar.gz; '' for skLocal }
    Archive     : string;            { path to the committed archive; '' for skLocal }
    PublishedUnit, PublishedArchive: string;
    UnitBackup, ArchiveBackup: string;
  end;

  TResolution = record
    Nodes : array of TResolveNode;
  end;

  TPathRollback = record
    OriginalPath: string;
    BackupPath: string;
  end;
  TPathRollbackArray = array of TPathRollback;

procedure AppendRollbackFailure(var AFailures: string;
  const AMessage: string);
begin
  if AMessage = '' then Exit;
  if AFailures <> '' then AFailures := AFailures + LineEnding;
  AFailures := AFailures + AMessage;
end;

function TryRollbackRestore(const ABackupPath, ADestination,
  AFailureMessage: string; var AFailures: string): Boolean;
begin
  Result := False;
  try
    Result := AtomicRestorePath(ABackupPath, ADestination);
    if not Result then AppendRollbackFailure(AFailures, AFailureMessage);
  except
    on E: Exception do
      AppendRollbackFailure(AFailures,
        AFailureMessage + ': ' + E.Message);
  end;
end;

procedure WriteTransactionState(const ARollbackRoot, AState: string);
var Lines: TStringList;
begin
  ForceDirectories(ARollbackRoot);
  Lines := TStringList.Create;
  try
    Lines.Add(AState);
    AtomicWriteText(ARollbackRoot + '/transaction.state',
      ARollbackRoot, Lines);
  finally
    Lines.Free;
  end;
end;

procedure MarkTransactionCommitted(const ARollbackRoot: string);
var Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('committed');
    AtomicWriteText(ARollbackRoot + '/transaction.committed',
      ARollbackRoot, Lines);
  finally
    Lines.Free;
  end;
end;

function RollbackRootHasMarkers(const ARollbackRoot: string): Boolean;
var SR: TSearchRec;
begin
  Result := SysUtils.FindFirst(ARollbackRoot + '/*.rollback',
    faAnyFile, SR) = 0;
  if Result then SysUtils.FindClose(SR);
end;

function RecoverRollbackRoot(const ARollbackRoot: string): string;
var
  SR: TSearchRec;
  BackupPath, Destination: string;
  MarkerIndex: Integer;
  Markers: TStringList;
begin
  Result := '';
  if FileExists(ARollbackRoot + '/transaction.committed') then
  begin
    WipeDir(ARollbackRoot);
    Exit;
  end;
  Markers := TStringList.Create;
  try
    Markers.Sorted := True;
    if SysUtils.FindFirst(ARollbackRoot + '/*.rollback', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          Markers.Add(ARollbackRoot + '/'
            + Copy(SR.Name, 1, Length(SR.Name) - Length('.rollback')));
        until SysUtils.FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
    for MarkerIndex := 0 to Markers.Count - 1 do
    begin
      BackupPath := Markers[MarkerIndex];
      try
        Destination := AtomicRetainedDestination(BackupPath);
        if Destination = '' then
          AppendRollbackFailure(Result,
            'rollback metadata is unreadable: ' + BackupPath)
        else
          TryRollbackRestore(BackupPath, Destination,
            'failed to recover "' + Destination + '" from '
            + BackupPath, Result);
      except
        on E: Exception do
          AppendRollbackFailure(Result,
            'failed to inspect rollback entry "' + BackupPath
            + '": ' + E.Message);
      end;
    end;
  finally
    Markers.Free;
  end;
  if Result = '' then WipeDir(ARollbackRoot);
end;

function RecoverPendingTransactions(const ATmpRoot: string): string;
var SR: TSearchRec; Candidate, Failures: string;
begin
  Result := '';
  if not DirectoryExists(ATmpRoot) then Exit;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(ATmpRoot) + '*',
       faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) = 0 then Continue;
        Candidate := IncludeTrailingPathDelimiter(ATmpRoot) + SR.Name;
        if not FileExists(Candidate + '/transaction.state') then Continue;
        Failures := RecoverRollbackRoot(Candidate);
        if Failures <> '' then
          AppendRollbackFailure(Result, Failures);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
end;

function CollectOrphanedPackagePaths(
  const AOldLock, ANewLock: array of TResolved;
  const AModulesRoot, AArchivesRoot: string;
  out APaths: TStringArray): Integer; forward;

function CanonicalDependencyIdentity(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray;
  const AProjectRoot: string): string;
var Custom: TCustomSource; Policy: TStringList; k: Integer;
  LocalPath, RootPath: string;
begin
  case ADep.SrcKind of
    skLocal:
    begin
      LocalPath := ResolveProjectPath(AProjectRoot, ADep.SrcLocator);
      RootPath := ExpandFileName(AProjectRoot);
      { Workspace discovery normalizes its local paths to absolute paths.
        Preserve a checkout-independent identity for every source below the
        project root regardless of how the dependency was spelled. }
      if (RootPath <> '') and IsPathInside(RootPath, LocalPath) then
        LocalPath := ExtractRelativePath(
          IncludeTrailingPathDelimiter(RootPath), LocalPath);
      Result := 'local|' + StringReplace(LocalPath, '\', '/', [rfReplaceAll]);
    end;
    skWorkspace:
      Result := 'workspace|' + LowerCase(ADep.Name);
    skURL:
      Result := 'url|' + ADep.SrcLocator;
    skGitHost:
    begin
      Result := 'git|' + GitRepoURL(ADep, ACustomSources);
      if ADep.SrcHost = hkCustom then
      begin
        ResolveCustomSourceOrDie(ADep, ACustomSources, Custom);
        Result := Result + '|' + Custom.ArchiveTemplate;
      end;
    end;
  end;
  Policy := TStringList.Create;
  try
    Policy.Sorted := True;
    Policy.CaseSensitive := True;
    { Manifest intake canonicalizes each extraction-policy set once. Keep
      that exact case-sensitive representation for artifact identity. }
    Policy.Duplicates := dupIgnore;
    for k := 0 to High(ADep.IncludeGlobs) do
      Policy.Add('include=' + ADep.IncludeGlobs[k]);
    for k := 0 to High(ADep.ExcludeGlobs) do
      Policy.Add('exclude=' + ADep.ExcludeGlobs[k]);
    for k := 0 to Policy.Count - 1 do Result := Result + '|' + Policy[k];
  finally
    Policy.Free;
  end;
end;

function FindWorkspace(const AWorkspaces: TWorkspaceArray;
  const AName: string; out AWorkspace: TWorkspace): Boolean;
var k: Integer;
begin
  for k := 0 to High(AWorkspaces) do
    if SameText(AWorkspaces[k].Name, AName) then
    begin
      AWorkspace := AWorkspaces[k];
      Exit(True);
    end;
  AWorkspace := Default(TWorkspace);
  Result := False;
end;

function WorkspaceNames(const AWorkspaces: TWorkspaceArray): string;
var k: Integer;
begin
  Result := '';
  for k := 0 to High(AWorkspaces) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + AWorkspaces[k].Name;
  end;
  if Result = '' then Result := '(none - no [workspaces] declared)';
end;

procedure NormalizeWorkspaceDependency(const ADep: TDependency;
  const ARequiredBy: string; const AWorkspaces: TWorkspaceArray;
  out ANormalized: TDependency);
var Workspace: TWorkspace;
begin
  ANormalized := ADep;
  if ADep.SrcKind <> skWorkspace then Exit;
  if not FindWorkspace(AWorkspaces, ADep.Name, Workspace) then
    raise EManifestError.CreateFmt(
      'workspace dependency "%s" required by %s was not found; '
      + 'available workspaces: %s',
      [ADep.Name, ARequiredBy, WorkspaceNames(AWorkspaces)]);
  case ADep.VersionKind of
    vkNone:;
    vkSemverRange, vkSemverExact:
      if (Valid(Workspace.Version, DefaultSemverOptions) = '')
         or not Satisfies(Workspace.Version, ADep.VersionSpec,
           DefaultSemverOptions) then
        raise EManifestError.CreateFmt(
          'workspace dependency "%s" required by %s wants "%s", '
          + 'but discovered workspace version is "%s"',
          [ADep.Name, ARequiredBy, ADep.VersionSpec, Workspace.Version]);
  else
    raise EManifestError.CreateFmt(
      'workspace dependency "%s" required by %s uses unsupported '
      + 'version requirement "%s"',
      [ADep.Name, ARequiredBy, ADep.VersionSpec]);
  end;
  { A workspace requirement and its auto-discovered root node describe one
    candidate. Preserve the requirement fields for diagnostics/fingerprints,
    but normalize the source to the discovered local path before identity
    comparison, selection, and staging. }
  ANormalized.SrcKind := skLocal;
  ANormalized.SrcLocator := Workspace.Path;
end;

function ConstraintFingerprintForNode(const ANode: TResolveNode;
  const AProjectRoot: string): string;
var Lines: TStringList; k: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Sorted := True;
    Lines.Duplicates := dupAccept;
    for k := 0 to High(ANode.Specs) do
      Lines.Add(IntToStr(Ord(ANode.Kinds[k])) + '|' + ANode.Specs[k]
        + '|' + ANode.Requirers[k]);
    Lines.Add('source|' + CanonicalDependencyIdentity(ANode.Dep,
      ANode.CustomSources, AProjectRoot));
    Result := 'sha256:' + SHA256Hex(BytesOf(Lines.Text));
  finally
    Lines.Free;
  end;
end;

function FindNode(var R: TResolution; const AName: string): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to High(R.Nodes) do
    if SameText(R.Nodes[i].Name, AName) then Exit(i);
end;

{ Record a constraint on a package, creating its node if new.
  Returns the node index and whether the node was newly created. }
function TouchNode(var R: TResolution; const ADep: TDependency;
  const ARequiredBy, ASourceIdentity: string;
  out AIsNew: Boolean): Integer;
var idx, n: Integer;
begin
  idx := FindNode(R, ADep.Name);
  AIsNew := idx < 0;
  if AIsNew then
  begin
    n := Length(R.Nodes);
    SetLength(R.Nodes, n + 1);
    R.Nodes[n] := Default(TResolveNode);
    R.Nodes[n].Name := ADep.Name;
    R.Nodes[n].Dep  := ADep;
    idx := n;
  end;
  n := Length(R.Nodes[idx].Specs);
  SetLength(R.Nodes[idx].Specs, n + 1);
  SetLength(R.Nodes[idx].Kinds, n + 1);
  SetLength(R.Nodes[idx].Requirers, n + 1);
  SetLength(R.Nodes[idx].SourceIdentities, n + 1);
  R.Nodes[idx].Specs[n]     := ADep.VersionSpec;
  R.Nodes[idx].Kinds[n]     := ADep.VersionKind;
  R.Nodes[idx].Requirers[n] := ARequiredBy;
  R.Nodes[idx].SourceIdentities[n] := ASourceIdentity;
  Result := idx;
end;

{ Locate a module's own manifest inside its extracted/copied tree.

  Include-filtered deps keep their repo-relative path prefix (the
  filter never re-roots the tree — committed zero-install state stays
  byte-identical to what the filter produced), so a monorepo package
  fetched via include = ["packages/<name>/**"] carries its lwpt.toml
  at <UnitDir>/packages/<name>/lwpt.toml, not at the module root.

  The module's manifest is the SHALLOWEST lwpt.toml in the tree
  (breadth-first; the root wins outright when present). Two manifests
  at the same minimal depth are ambiguous — there is no defensible
  winner, so we return False and the caller falls back to the
  manifest-less behavior (emit the module root, walk no deps).
  Hidden dirs (leading '.') and directory symlinks are not descended
  into — skLocal trees can contain links, and walking through one
  invites cycles plus duplicate (falsely "ambiguous") sightings of the
  same manifest. Depth is additionally capped at MAX_MANIFEST_SCAN_DEPTH
  as a backstop for link flavors FindFirst does not report (past the cap
  the module falls back to manifest-less behavior). On success, ARelDir
  is the manifest's directory relative to AUnitDir with '/' separators
  ('' when the manifest sits at the module root). }
function FindModuleManifest(const AUnitDir: string;
  out ARelDir: string): Boolean;
const
  MAX_MANIFEST_SCAN_DEPTH = 16;
var
  Current, Next, Hits: TStringList;
  SR: TSearchRec;
  i, Depth: Integer;
  Base, RelPrefix: string;
begin
  Result := False;
  ARelDir := '';
  if not DirectoryExists(AUnitDir) then Exit;

  Current := TStringList.Create;
  Next    := TStringList.Create;
  Hits    := TStringList.Create;
  try
    Current.Add('');
    Depth := 0;
    while (Current.Count > 0) and (Depth < MAX_MANIFEST_SCAN_DEPTH) do
    begin
      Hits.Clear;
      Next.Clear;
      for i := 0 to Current.Count - 1 do
      begin
        Base := IncludeTrailingPathDelimiter(AUnitDir);
        RelPrefix := Current[i];
        if RelPrefix <> '' then
          Base := Base + RelPrefix + '/';
        if FileExists(Base + MANIFEST_FILE) then
          Hits.Add(RelPrefix);
        if SysUtils.FindFirst(Base + '*', faAnyFile or faSymLink, SR) = 0 then
          try
            repeat
              { leading '.' also covers the '.' and '..' entries }
              if (SR.Name <> '') and (SR.Name[1] = '.') then Continue;
              if (SR.Attr and faSymLink) <> 0 then Continue;
              if (SR.Attr and faDirectory) = 0 then Continue;
              if RelPrefix = '' then
                Next.Add(SR.Name)
              else
                Next.Add(RelPrefix + '/' + SR.Name);
            until SysUtils.FindNext(SR) <> 0;
          finally
            SysUtils.FindClose(SR);
          end;
      end;
      if Hits.Count = 1 then
      begin
        ARelDir := Hits[0];
        Exit(True);
      end;
      if Hits.Count > 1 then Exit(False);
      Current.Assign(Next);
      Inc(Depth);
    end;
  finally
    Current.Free;
    Next.Free;
    Hits.Free;
  end;
end;

{ Frozen graph walk. If the dep's modules dir is already present
  (zero-install committed state), proceed using
  it as-is — caller (CmdInstall) then does the hash verification pass.
  Missing modules dir → EFetchError naming the dep + recovery hint. }
procedure ResolveGraphFrozen(const ARootMan: TManifest; var R: TResolution;
  const AModulesRoot, AProjectRoot: string;
  const AWorkspaces: TWorkspaceArray);
type
  TWorkItem = record
    Dep: TDependency;
    RequiredBy: string;
    CustomSources: TCustomSourceArray;
  end;
var
  Queue : array of TWorkItem;
  Head  : Integer;
  i, idx: Integer;
  IsNew : Boolean;
  Item  : TWorkItem;
  NormalizedDep: TDependency;
  ItemSourceIdentity: string;
  UnitDir, Archive, ArchiveHash, ResolvedURL, ChildManifestPath,
    ManifestRelDir: string;
  ChildMan : TManifest;

  procedure CopyCustomSources(const ASrc: TCustomSourceArray;
    out ADst: TCustomSourceArray);
  var
    k: Integer;
  begin
    SetLength(ADst, Length(ASrc));
    for k := 0 to High(ASrc) do
      ADst[k] := ASrc[k];
  end;

  procedure Enqueue(const D: TDependency; const ABy: string;
    const ACustomSources: TCustomSourceArray);
  var q: Integer;
  begin
    q := Length(Queue);
    SetLength(Queue, q + 1);
    Queue[q].Dep := D;
    Queue[q].RequiredBy := ABy;
    CopyCustomSources(ACustomSources, Queue[q].CustomSources);
  end;

begin
  { seed the queue with the root manifest's direct deps }
  for i := 0 to High(ARootMan.Deps) do
    Enqueue(ARootMan.Deps[i], ARootMan.Name, ARootMan.CustomSources);

  Head := 0;
  while Head < Length(Queue) do
  begin
    Item := Queue[Head];
    Inc(Head);

    NormalizeWorkspaceDependency(Item.Dep, Item.RequiredBy,
      AWorkspaces, NormalizedDep);
    Item.Dep := NormalizedDep;
    ItemSourceIdentity := CanonicalDependencyIdentity(Item.Dep,
      Item.CustomSources, AProjectRoot);
    idx := TouchNode(R, Item.Dep, Item.RequiredBy,
      ItemSourceIdentity, IsNew);
    if not IsNew then
    begin
      if CanonicalDependencyIdentity(R.Nodes[idx].Dep,
           R.Nodes[idx].CustomSources, AProjectRoot)
         <> CanonicalDependencyIdentity(Item.Dep,
           Item.CustomSources, AProjectRoot) then
        raise EVerifyError.CreateFmt(
          '[frozen] requirements for "%s" name different canonical '
          + 'sources. Run `lwpt install` without --frozen to resolve '
          + 'the graph again.', [Item.Dep.Name]);
      Continue;   { already expanded; constraint recorded above }
    end;
    CopyCustomSources(Item.CustomSources, R.Nodes[idx].CustomSources);

    UnitDir := IncludeTrailingPathDelimiter(AModulesRoot) + Item.Dep.Name;
    Archive := '';
    ArchiveHash := '';
    ResolvedURL := '';

    if not DirectoryExists(UnitDir) then
      raise EFetchError.CreateFmt(
        '[frozen] missing extracted module for "%s" at %s '
        + '(required by %s). Run `lwpt install` without --frozen to '
        + 'fetch, or restore the committed .lwpt/modules tree.',
        [Item.Dep.Name, UnitDir, Item.RequiredBy]);
    WriteLn('  [frozen] ', Item.Dep.Name,
            '  (required by ', Item.RequiredBy, ')');
    { Archive metadata is recovered from the lockfile during verification. }

    R.Nodes[idx].UnitDir     := UnitDir;
    R.Nodes[idx].Archive     := Archive;
    R.Nodes[idx].ArchiveHash := ArchiveHash;
    R.Nodes[idx].ResolvedURL := ResolvedURL;
    if DirectoryExists(UnitDir) then
      R.Nodes[idx].Hash := HashTree(UnitDir);

    { read the fetched package's own manifest and enqueue ITS deps.
      The manifest is the shallowest lwpt.toml in the module tree —
      include-filtered deps keep their repo-relative prefix, so it
      may sit below the module root (see FindModuleManifest). }
    if FindModuleManifest(UnitDir, ManifestRelDir) then
    begin
      ChildManifestPath := IncludeTrailingPathDelimiter(UnitDir);
      if ManifestRelDir <> '' then
        ChildManifestPath := ChildManifestPath + ManifestRelDir + '/';
      ChildManifestPath := ChildManifestPath + MANIFEST_FILE;
      { AIsRoot=False — supply-chain defense per ADR-0011 §"Supply-
        chain posture". Dep manifests' hook sections are silently
        dropped; unknown-section warnings are suppressed (CI noise
        without a user fix); placeholder expansion is skipped (no
        per-entry context applies to dep-graph traversal). }
      ChildMan := LoadManifest(ChildManifestPath, False);
      { Copy the dep's units list into the resolved node so the cfg
        emitter knows which subdirs hold the .pas files. Without
        this, -Fu would point at UnitDir's top level and miss the
        units in <UnitDir>/source/ (or wherever the dep declared).
        A nested manifest's units dirs are relative to ITS directory,
        so the emitted subdirs carry the manifest's prefix. }
      SetLength(R.Nodes[idx].UnitSubdirs, Length(ChildMan.Units));
      for i := 0 to High(ChildMan.Units) do
        if ManifestRelDir = '' then
          R.Nodes[idx].UnitSubdirs[i] := ChildMan.Units[i]
        else
          R.Nodes[idx].UnitSubdirs[i] :=
            ManifestRelDir + '/' + ChildMan.Units[i];
      for i := 0 to High(ChildMan.Deps) do
        Enqueue(ChildMan.Deps[i], Item.Dep.Name, ChildMan.CustomSources);
    end;
  end;
end;

{ Materializing resolution is deliberately separate from the frozen walk.
  Every discovery candidate lives below APlanRoot. A round expands exactly
  one selected candidate per package, then recomputes selections from the
  complete accumulated constraint set. Changed selections start a fresh
  round; a repeated selection vector is an ambiguous oscillation, not an
  invitation to backtrack through lower parent versions. }
procedure ResolveGraphFixedPoint(const ARootMan: TManifest;
  var R: TResolution; const AModulesRoot, AArchivesRoot, ATmpRoot,
  ARollbackRoot, AProjectRoot: string;
  const AWorkspaces: TWorkspaceArray);
type
  TSelectionState = record
    Name, SourceIdentity, RefName, CommitSHA: string;
  end;
  TSelectionStateArray = array of TSelectionState;
  TRefCacheEntry = record
    RepoURL: string;
    Refs: TGitRefArray;
  end;
  TRefCache = array of TRefCacheEntry;
var
  Previous, Desired: TSelectionStateArray;
  RefCache: TRefCache;
  SeenSignatures: TStringList;
  PlanRoot, PlanModules, PlanArchives, PlanScratch: string;
  Round, i, j, idx, Head: Integer;
  Queue: array of Integer;
  ChildMan: TManifest;
  ChildManifestPath, ManifestRelDir, ExtractTmp: string;
  UnitDir, Archive, ArchiveHash, ResolvedURL, CacheArchive: string;
  FetchRef, RollbackFailures: string;
  SelectionDeferred, Stable: Boolean;

  procedure CopyCustomSources(const ASrc: TCustomSourceArray;
    out ADst: TCustomSourceArray);
  var k: Integer;
  begin
    SetLength(ADst, Length(ASrc));
    for k := 0 to High(ASrc) do ADst[k] := ASrc[k];
  end;

  function SourceKey(const ADep: TDependency;
    const ACustomSources: TCustomSourceArray): string;
  begin
    Result := CanonicalDependencyIdentity(ADep, ACustomSources,
      AProjectRoot);
  end;

  function NodeConstraintFingerprint(const ANode: TResolveNode): string;
  begin
    Result := ConstraintFingerprintForNode(ANode, AProjectRoot);
  end;

  procedure RaiseNodeConflict(const ANode: TResolveNode;
    const AExtraRequirer, AExtraSpec, AReason: string);
  var k: Integer; MessageText: string;
  begin
    MessageText := 'unresolvable version conflict on "' + ANode.Name
      + '":' + LineEnding
      + '  canonical source: '
      + SourceKey(ANode.Dep, ANode.CustomSources) + LineEnding;
    for k := 0 to High(ANode.Specs) do
      MessageText := MessageText + '  ' + ANode.Requirers[k] + ' wants "'
        + ANode.Specs[k] + '"' + LineEnding;
    if AExtraRequirer <> '' then
      MessageText := MessageText + '  ' + AExtraRequirer + ' wants "'
        + AExtraSpec + '"' + LineEnding;
    raise EManifestError.Create(MessageText + '  ' + AReason);
  end;

  function NodeHasSourceConflict(const ANode: TResolveNode): Boolean;
  var k: Integer;
  begin
    Result := False;
    for k := 1 to High(ANode.SourceIdentities) do
      if ANode.SourceIdentities[k] <> ANode.SourceIdentities[0] then
        Exit(True);
  end;

  procedure RaiseSourceConflict(const ANode: TResolveNode);
  var k: Integer; MessageText: string;
  begin
    MessageText := 'unresolvable source conflict on "' + ANode.Name
      + '":' + LineEnding;
    for k := 0 to High(ANode.Specs) do
      MessageText := MessageText + '  ' + ANode.Requirers[k] + ' wants "'
        + ANode.Specs[k] + '" from canonical source: '
        + ANode.SourceIdentities[k] + LineEnding;
    raise EManifestError.Create(MessageText
      + '  requirements name different canonical sources; source '
      + 'equivalence is never guessed');
  end;

  function AddRequirement(var AResolution: TResolution;
    const ADep: TDependency; const ARequiredBy: string;
    const ACustomSources: TCustomSourceArray): Integer;
  var IsNew: Boolean; NormalizedDep: TDependency; Identity: string;
  begin
    NormalizeWorkspaceDependency(ADep, ARequiredBy, AWorkspaces,
      NormalizedDep);
    Identity := SourceKey(NormalizedDep, ACustomSources);
    Result := TouchNode(AResolution, NormalizedDep, ARequiredBy,
      Identity, IsNew);
    if IsNew then
      CopyCustomSources(ACustomSources,
        AResolution.Nodes[Result].CustomSources);
  end;

  function CachedRefs(const ANode: TResolveNode): TGitRefArray;
  var RepoURL: string; k, n: Integer;
  begin
    RepoURL := GitRepoURL(ANode.Dep, ANode.CustomSources);
    for k := 0 to High(RefCache) do
      if RefCache[k].RepoURL = RepoURL then Exit(RefCache[k].Refs);
    WriteLn('  resolving tags for ', ANode.Name, '...');
    n := Length(RefCache);
    SetLength(RefCache, n + 1);
    RefCache[n].RepoURL := RepoURL;
    RefCache[n].Refs := ListRemoteRefs(RepoURL);
    Result := RefCache[n].Refs;
  end;

  function FindSelection(const AStates: TSelectionStateArray;
    const AName: string): Integer;
  var k: Integer;
  begin
    Result := -1;
    for k := 0 to High(AStates) do
      if SameText(AStates[k].Name, AName) then Exit(k);
  end;

  function NodeWorkspaceVersion(const ANode: TResolveNode;
    out AVersion: string): Boolean;
  var Workspace: TWorkspace; NodePath, WorkspacePath: string;
  begin
    AVersion := '';
    Result := False;
    if (ANode.Dep.SrcKind <> skLocal)
       or not FindWorkspace(AWorkspaces, ANode.Name, Workspace) then
      Exit;
    NodePath := ExcludeTrailingPathDelimiter(
      ResolveProjectPath(AProjectRoot, ANode.Dep.SrcLocator));
    WorkspacePath := ExcludeTrailingPathDelimiter(
      ExpandFileName(Workspace.Path));
    {$IFDEF MSWINDOWS}
    Result := SameText(NodePath, WorkspacePath);
    {$ELSE}
    Result := NodePath = WorkspacePath;
    {$ENDIF}
    if Result then AVersion := Workspace.Version;
  end;

  function SelectNode(const ANode: TResolveNode): TSelectionState;
  var
    Requirements: TResolverRequirementArray;
    Refs: TGitRefArray;
    Selection: TResolverSelection;
    k, Longest: Integer;
    AllSHA, HasWorkspaceConstraint: Boolean;
    WorkspaceVersion: string;
  begin
    Result := Default(TSelectionState);
    Result.Name := ANode.Name;
    Result.SourceIdentity := SourceKey(ANode.Dep, ANode.CustomSources);
    if ANode.Dep.SrcKind <> skGitHost then
    begin
      HasWorkspaceConstraint := False;
      if NodeWorkspaceVersion(ANode, WorkspaceVersion) then
      begin
        for k := 0 to High(ANode.Kinds) do
          HasWorkspaceConstraint := HasWorkspaceConstraint
            or (ANode.Kinds[k] <> vkNone);
        if HasWorkspaceConstraint then Result.RefName := WorkspaceVersion;
        Exit;
      end;
      for k := 0 to High(ANode.Kinds) do
        if ANode.Kinds[k] <> vkNone then
          RaiseNodeConflict(ANode, '', '',
            'only git-host sources support version constraints');
      Exit;
    end;

    AllSHA := Length(ANode.Kinds) > 0;
    Longest := 0;
    for k := 0 to High(ANode.Kinds) do
    begin
      AllSHA := AllSHA and (ANode.Kinds[k] = vkCommitSha);
      if Length(ANode.Specs[k]) > Length(ANode.Specs[Longest]) then
        Longest := k;
    end;
    if AllSHA then
    begin
      for k := 0 to High(ANode.Specs) do
        if not SameText(ANode.Specs[k],
             Copy(ANode.Specs[Longest], 1, Length(ANode.Specs[k]))) then
          RaiseNodeConflict(ANode, '', '',
            'SHA requirements do not identify the same commit');
      Result.RefName := ANode.Specs[Longest];
      Result.CommitSHA := ANode.Specs[Longest];
      Exit;
    end;

    SetLength(Requirements, Length(ANode.Specs));
    for k := 0 to High(Requirements) do
    begin
      Requirements[k].Spec := ANode.Specs[k];
      Requirements[k].Kind := ANode.Kinds[k];
      Requirements[k].Requirer := ANode.Requirers[k];
    end;
    Refs := CachedRefs(ANode);
    try
      Selection := SelectHighestRef(ANode.Name, Requirements, Refs);
    except
      on E: EResolverConflict do
        raise EManifestError.Create(E.Message + LineEnding
          + '  canonical source: '
          + SourceKey(ANode.Dep, ANode.CustomSources));
    end;
    Result.RefName := Selection.RefName;
    Result.CommitSHA := Selection.CommitSHA;
  end;

  procedure EnqueueNode(AIndex: Integer);
  var n: Integer;
  begin
    for n := 0 to High(Queue) do
      if Queue[n] = AIndex then Exit;
    n := Length(Queue);
    SetLength(Queue, n + 1);
    Queue[n] := AIndex;
  end;

  function SelectionSignature(const AStates: TSelectionStateArray): string;
  var k: Integer;
  begin
    Result := '';
    for k := 0 to High(AStates) do
      Result := Result + LowerCase(AStates[k].Name) + '='
        + AStates[k].RefName + '@' + AStates[k].CommitSHA + ';';
  end;

  function RollbackPublished: string;
  var k: Integer;
  begin
    Result := '';
    for k := High(R.Nodes) downto 0 do
    begin
      if R.Nodes[k].PublishedUnit <> '' then
      begin
        if TryRollbackRestore(R.Nodes[k].UnitBackup,
             R.Nodes[k].PublishedUnit,
             'failed to roll back module "' + R.Nodes[k].Name + '"',
             Result) then
          R.Nodes[k].UnitBackup := '';
      end;
      if R.Nodes[k].PublishedArchive <> '' then
      begin
        if TryRollbackRestore(R.Nodes[k].ArchiveBackup,
             R.Nodes[k].PublishedArchive,
             'failed to roll back archive "' + R.Nodes[k].Name + '"',
             Result) then
          R.Nodes[k].ArchiveBackup := '';
      end;
    end;
  end;

  procedure PublishPlan;
  var
    k, w: Integer;
    FinalUnitDir, FinalArchive, LivePath, RecheckPath: string;
  begin
    { Revalidate every mutable local/workspace input immediately before
      the first committed move. A changed source restarts at the command
      level without exposing a plan built from mixed snapshots. }
    for k := 0 to High(R.Nodes) do
      if R.Nodes[k].Dep.SrcKind in [skLocal, skWorkspace] then
      begin
        if R.Nodes[k].Dep.SrcKind = skLocal then
          LivePath := ResolveProjectPath(AProjectRoot,
            R.Nodes[k].Dep.SrcLocator)
        else
        begin
          LivePath := '';
          for w := 0 to High(AWorkspaces) do
            if SameText(AWorkspaces[w].Name, R.Nodes[k].Name) then
            begin
              LivePath := AWorkspaces[w].Path;
              Break;
            end;
        end;
        RecheckPath := MakeTmpPath(PlanScratch,
          'preflight-' + R.Nodes[k].Name);
        ForceDirectories(RecheckPath);
        CopyDirTree(LivePath, RecheckPath);
        ApplyIncludeExclude(RecheckPath,
          R.Nodes[k].Dep.IncludeGlobs, R.Nodes[k].Dep.ExcludeGlobs);
        try
      if SameText(SysUtils.GetEnvironmentVariable(
               PROJECT_NAME + '_TEST_STALE_LOCAL_SNAPSHOT'),
             R.Nodes[k].Name) then
            R.Nodes[k].Hash := 'sha256:injected-stale-snapshot';
          if HashTree(RecheckPath) <> R.Nodes[k].Hash then
            raise EFetchError.CreateFmt(
              'local/workspace source "%s" changed during resolution; '
              + 'no dependency state was published, retry install',
              [R.Nodes[k].Name]);
        finally
          WipeDir(RecheckPath);
        end;
      end;

    for k := 0 to High(R.Nodes) do
    begin
      FinalUnitDir := IncludeTrailingPathDelimiter(AModulesRoot)
        + R.Nodes[k].Name;
      R.Nodes[k].PublishedUnit := FinalUnitDir;
      if not AtomicRetainPath(FinalUnitDir, ARollbackRoot,
           'module-' + R.Nodes[k].Name, R.Nodes[k].UnitBackup) then
        raise EFetchError.CreateFmt(
          'failed to retain rollback copy for module "%s"',
          [R.Nodes[k].Name]);
      if SameText(SysUtils.GetEnvironmentVariable(
           PROJECT_NAME + '_TEST_HALT_AFTER_MODULE_RETAIN'),
         R.Nodes[k].Name) then
        Halt(87);
      FinalArchive := '';
      if not (R.Nodes[k].Dep.SrcKind in [skLocal, skWorkspace]) then
      begin
        FinalArchive := ArchivePathForRef(AArchivesRoot, R.Nodes[k].Name,
          R.Nodes[k].Dep.SrcKind, R.Nodes[k].Version);
        R.Nodes[k].PublishedArchive := FinalArchive;
        if not AtomicRetainPath(FinalArchive, ARollbackRoot,
             'archive-' + R.Nodes[k].Name,
             R.Nodes[k].ArchiveBackup) then
          raise EFetchError.CreateFmt(
            'failed to retain rollback copy for archive "%s"',
            [R.Nodes[k].Name]);
        if (R.Nodes[k].Archive <> '')
           and not AtomicMoveFile(R.Nodes[k].Archive, FinalArchive) then
          raise EFetchError.CreateFmt(
            'failed to publish archive for "%s"', [R.Nodes[k].Name]);
      end;
      { Publish the exact candidate tree whose filtered bytes and child
        manifest drove resolution and preflight validation. Never reread a
        mutable live local/workspace source during the commit phase. }
      if not AtomicMoveDir(R.Nodes[k].UnitDir, FinalUnitDir) then
        raise EFetchError.CreateFmt(
          'failed to publish module tree for "%s"', [R.Nodes[k].Name]);
      R.Nodes[k].UnitDir := FinalUnitDir;
      if R.Nodes[k].Dep.SrcKind in [skLocal, skWorkspace] then
        R.Nodes[k].Archive := ''
      else
        R.Nodes[k].Archive := FinalArchive;
      R.Nodes[k].Hash := HashTree(FinalUnitDir);
      if (SysUtils.GetEnvironmentVariable(
          PROJECT_NAME + '_TEST_FAIL_PUBLISH_AFTER') <>
          '') and (StrToIntDef(SysUtils.GetEnvironmentVariable(
          PROJECT_NAME + '_TEST_FAIL_PUBLISH_AFTER'), -1) = k + 1) then
        raise EFetchError.CreateFmt(
          'injected publication failure after package %d', [k + 1]);
      if (SysUtils.GetEnvironmentVariable(
          PROJECT_NAME + '_TEST_HALT_PUBLISH_AFTER') <>
          '') and (StrToIntDef(SysUtils.GetEnvironmentVariable(
          PROJECT_NAME + '_TEST_HALT_PUBLISH_AFTER'), -1) = k + 1) then
        Halt(86);
    end;
  end;

begin
  PlanRoot := MakeTmpPath(ATmpRoot, 'resolver-plan');
  PlanModules := PlanRoot + '/modules';
  PlanArchives := PlanRoot + '/archives';
  PlanScratch := PlanRoot + '/scratch';
  Previous := nil;
  RefCache := nil;
  SeenSignatures := TStringList.Create;
  try
    Round := 0;
    repeat
      Inc(Round);
      if Round > 128 then
        raise EManifestError.Create(
          'dependency resolution did not reach a fixed point');
      if DirectoryExists(PlanModules) then WipeDir(PlanModules);
      if DirectoryExists(PlanArchives) then WipeDir(PlanArchives);
      if DirectoryExists(PlanScratch) then WipeDir(PlanScratch);
      ForceDirectories(PlanModules);
      ForceDirectories(PlanArchives);
      ForceDirectories(PlanScratch);
      R := Default(TResolution);
      Queue := nil;

      { Collect all root requirements before selecting any root candidate. }
      for i := 0 to High(ARootMan.Deps) do
        AddRequirement(R, ARootMan.Deps[i], ARootMan.Name,
          ARootMan.CustomSources);
      for i := 0 to High(R.Nodes) do EnqueueNode(i);

      Head := 0;
      while Head < Length(Queue) do
      begin
        idx := Queue[Head];
        Inc(Head);
        SelectionDeferred := False;
        if NodeHasSourceConflict(R.Nodes[idx]) then
          SelectionDeferred := True;
        try
          if not SelectionDeferred then
          begin
            j := FindSelection(Previous, R.Nodes[idx].Name);
            if (j >= 0) and (Previous[j].SourceIdentity =
                 SourceKey(R.Nodes[idx].Dep,
                   R.Nodes[idx].CustomSources)) then
            begin
              R.Nodes[idx].Version := Previous[j].RefName;
              R.Nodes[idx].CommitSHA := Previous[j].CommitSHA;
            end
            else
            begin
              Desired := nil;
              SetLength(Desired, 1);
              Desired[0] := SelectNode(R.Nodes[idx]);
              R.Nodes[idx].Version := Desired[0].RefName;
              R.Nodes[idx].CommitSHA := Desired[0].CommitSHA;
            end;
          end;
        except
          on E: EManifestError do
            SelectionDeferred := True;
        end;
        { A terminal selection error must be emitted only after the rest of
          the reachable queue has contributed its requirements. This node
          cannot become satisfiable as constraints accumulate, so it needs no
          candidate expansion; the complete-set SelectNode pass below emits
          the final diagnostic after every independent node was visited. }
        if SelectionDeferred then Continue;

        WriteLn('  staging ', R.Nodes[idx].Name, ' @ ',
          R.Nodes[idx].Version, ' for resolver round ', Round);
        FetchRef := R.Nodes[idx].CommitSHA;
        if FetchRef = '' then FetchRef := R.Nodes[idx].Version;
        CacheArchive := PlanRoot + '/candidate-cache/'
          + SHA256Hex(BytesOf(SourceKey(R.Nodes[idx].Dep,
          R.Nodes[idx].CustomSources) + '|'
          + FetchRef)) + '.tar.gz';
        if (R.Nodes[idx].Dep.SrcKind in [skGitHost, skURL])
           and FileExists(CacheArchive) then
        begin
          UnitDir := IncludeTrailingPathDelimiter(PlanModules)
            + R.Nodes[idx].Name;
          Archive := ArchivePathForRef(PlanArchives, R.Nodes[idx].Name,
            R.Nodes[idx].Dep.SrcKind, FetchRef);
          ForceDirectories(ExtractFileDir(Archive));
          if not CopyFileContent(CacheArchive, Archive) then
            raise EFetchError.CreateFmt(
              'failed to restore cached resolver candidate "%s"',
              [R.Nodes[idx].Name]);
          ArchiveHash := 'sha256:' + SHA256File(Archive);
          ResolvedURL := FetchURL(R.Nodes[idx].Dep, FetchRef,
            R.Nodes[idx].CustomSources);
        end
        else
        begin
          FetchToCache(R.Nodes[idx].Dep, FetchRef,
            PlanModules, PlanArchives, PlanScratch, AProjectRoot,
            R.Nodes[idx].CustomSources, AWorkspaces,
            UnitDir, Archive, ArchiveHash, ResolvedURL);
          if (Archive <> '') and FileExists(Archive) then
          begin
            ForceDirectories(ExtractFileDir(CacheArchive));
            if not CopyFileContent(Archive, CacheArchive) then
              raise EFetchError.CreateFmt(
                'failed to cache resolver candidate "%s"',
                [R.Nodes[idx].Name]);
          end;
        end;
        if (Archive <> '') and FileExists(Archive) then
        begin
          ExtractTmp := MakeTmpPath(PlanScratch,
            'extract-' + R.Nodes[idx].Name);
          ForceDirectories(ExtractTmp);
          try
            ExtractArchive(Archive, ExtractTmp, '');
            ApplyIncludeExclude(ExtractTmp,
              R.Nodes[idx].Dep.IncludeGlobs,
              R.Nodes[idx].Dep.ExcludeGlobs);
            if not AtomicMoveDir(ExtractTmp, UnitDir) then
              raise EExtractError.CreateFmt(
                'failed to stage module tree for "%s"',
                [R.Nodes[idx].Name]);
          except
            on E: Exception do
            begin
              if DirectoryExists(ExtractTmp) then WipeDir(ExtractTmp);
              raise EExtractError.CreateFmt(
                'extract failed for "%s" from %s: %s',
                [R.Nodes[idx].Name, Archive, E.Message]);
            end;
          end;
        end;
        if (Archive = '') and DirectoryExists(UnitDir)
           and ((Length(R.Nodes[idx].Dep.IncludeGlobs) > 0)
             or (Length(R.Nodes[idx].Dep.ExcludeGlobs) > 0)) then
          ApplyIncludeExclude(UnitDir,
            R.Nodes[idx].Dep.IncludeGlobs,
            R.Nodes[idx].Dep.ExcludeGlobs);
        R.Nodes[idx].UnitDir := UnitDir;
        R.Nodes[idx].Archive := Archive;
        R.Nodes[idx].ArchiveHash := ArchiveHash;
        R.Nodes[idx].ResolvedURL := ResolvedURL;
        if DirectoryExists(UnitDir) then
          R.Nodes[idx].Hash := HashTree(UnitDir);

        if FindModuleManifest(UnitDir, ManifestRelDir) then
        begin
          ChildManifestPath := IncludeTrailingPathDelimiter(UnitDir);
          if ManifestRelDir <> '' then
            ChildManifestPath := ChildManifestPath + ManifestRelDir + '/';
          ChildManifestPath := ChildManifestPath + MANIFEST_FILE;
          ChildMan := LoadManifest(ChildManifestPath, False);
          SetLength(R.Nodes[idx].UnitSubdirs, Length(ChildMan.Units));
          for i := 0 to High(ChildMan.Units) do
            if ManifestRelDir = '' then
              R.Nodes[idx].UnitSubdirs[i] := ChildMan.Units[i]
            else
              R.Nodes[idx].UnitSubdirs[i] := ManifestRelDir + '/'
                + ChildMan.Units[i];
          for i := 0 to High(ChildMan.Deps) do
          begin
            j := AddRequirement(R, ChildMan.Deps[i], R.Nodes[idx].Name,
              ChildMan.CustomSources);
            EnqueueNode(j);
          end;
        end;
      end;

      SetLength(Desired, Length(R.Nodes));
      Stable := True;
      for i := 0 to High(R.Nodes) do
      begin
        if NodeHasSourceConflict(R.Nodes[i]) then
          RaiseSourceConflict(R.Nodes[i]);
        Desired[i] := SelectNode(R.Nodes[i]);
        R.Nodes[i].SourceIdentity := Desired[i].SourceIdentity;
        R.Nodes[i].ConstraintFingerprint :=
          NodeConstraintFingerprint(R.Nodes[i]);
        Stable := Stable
          and (Desired[i].RefName = R.Nodes[i].Version)
          and SameText(Desired[i].CommitSHA, R.Nodes[i].CommitSHA);
      end;
      if not Stable then
      begin
        if SeenSignatures.IndexOf(SelectionSignature(Desired)) >= 0 then
          raise EManifestError.Create(
            'dependency resolution oscillates between highest-version '
            + 'candidate graphs; backtracking is intentionally disabled');
        SeenSignatures.Add(SelectionSignature(Desired));
        Previous := Desired;
      end;
    until Stable;

    try
      PublishPlan;
    except
      on E: Exception do
      begin
        RollbackFailures := RollbackPublished;
        if RollbackFailures <> '' then
          raise EExtractError.Create(E.Message + LineEnding
            + 'rollback failures:' + LineEnding + RollbackFailures);
        raise;
      end;
    end;
  finally
    SeenSignatures.Free;
    if DirectoryExists(PlanRoot) then WipeDir(PlanRoot);
  end;
end;

function RollbackResolutionPublication(var R: TResolution): string;
var i: Integer;
begin
  Result := '';
  for i := High(R.Nodes) downto 0 do
  begin
    if R.Nodes[i].PublishedUnit <> '' then
    begin
      if TryRollbackRestore(R.Nodes[i].UnitBackup,
           R.Nodes[i].PublishedUnit,
           'failed to roll back module "' + R.Nodes[i].Name + '"',
           Result) then
        R.Nodes[i].UnitBackup := '';
    end;
    if R.Nodes[i].PublishedArchive <> '' then
    begin
      if TryRollbackRestore(R.Nodes[i].ArchiveBackup,
           R.Nodes[i].PublishedArchive,
           'failed to roll back archive "' + R.Nodes[i].Name + '"',
           Result) then
        R.Nodes[i].ArchiveBackup := '';
    end;
  end;
end;

procedure FinalizeResolutionPublication(var R: TResolution);
var i: Integer;
begin
  for i := 0 to High(R.Nodes) do
  begin
    if R.Nodes[i].UnitBackup <> '' then
      AtomicDiscardRetainedPath(R.Nodes[i].UnitBackup);
    if R.Nodes[i].ArchiveBackup <> '' then
      AtomicDiscardRetainedPath(R.Nodes[i].ArchiveBackup);
    R.Nodes[i].UnitBackup := '';
    R.Nodes[i].ArchiveBackup := '';
  end;
end;

procedure RetainOrphanedPackagePaths(
  const AOldLock, ANewLock: array of TResolved;
  const AModulesRoot, AArchivesRoot, ATmpRoot: string;
  out ARollbacks: TPathRollbackArray);
var Paths: TStringArray; i, n: Integer; Backup: string;
begin
  ARollbacks := nil;
  CollectOrphanedPackagePaths(AOldLock, ANewLock,
    AModulesRoot, AArchivesRoot, Paths);
  for i := 0 to High(Paths) do
  begin
    Backup := '';
    if not AtomicRetainPath(Paths[i], ATmpRoot,
         'orphan-' + IntToStr(i + 1), Backup) then
      raise EExtractError.CreateFmt(
        'failed to retain rollback copy for orphan "%s"', [Paths[i]]);
    if Backup = '' then Continue;
    n := Length(ARollbacks);
    SetLength(ARollbacks, n + 1);
    ARollbacks[n].OriginalPath := Paths[i];
    ARollbacks[n].BackupPath := Backup;
    if not AtomicRemovePath(Paths[i]) then
      raise EExtractError.CreateFmt(
        'failed to prune retained orphan "%s"', [Paths[i]]);
    WriteLn('pruned ', Paths[i]);
  end;
end;

function RollbackRetainedPaths(var ARollbacks: TPathRollbackArray): string;
var i: Integer;
begin
  Result := '';
  for i := High(ARollbacks) downto 0 do
    if TryRollbackRestore(ARollbacks[i].BackupPath,
         ARollbacks[i].OriginalPath,
         'failed to restore pruned path "'
         + ARollbacks[i].OriginalPath + '"', Result) then
      ARollbacks[i].BackupPath := '';
  if Result = '' then ARollbacks := nil;
end;

procedure DiscardRetainedPaths(var ARollbacks: TPathRollbackArray);
var i: Integer;
begin
  for i := 0 to High(ARollbacks) do
    if ARollbacks[i].BackupPath <> '' then
      AtomicDiscardRetainedPath(ARollbacks[i].BackupPath);
  ARollbacks := nil;
end;

{ Size of a file by path, as a string; '0' if absent. }
function FileSizeBytes(const APath: string): string;
var SR: TSearchRec;
begin
  Result := '0';
  if SysUtils.FindFirst(APath, faAnyFile, SR) = 0 then
  begin
    Result := IntToStr(SR.Size);
    SysUtils.FindClose(SR);
  end;
end;


{ ===========================================================================
  CLI
  =========================================================================== }
{ Cross-reference a resolution graph against the lockfile entries; raise
  EVerifyError on any mismatch. Both directions matter: a lockfile entry
  without a graph node means the modules tree has been pruned vs the
  lock, and a graph node without a lockfile entry means a new dep was
  added without re-running install (manifest drift). }
procedure VerifyAgainstLockfile(const AResolved: array of TResolved;
  const ALockEntries: array of TResolved);

  function FindLockEntry(const AName: string; out AOut: TResolved): Boolean;
  var k: Integer;
  begin
    for k := 0 to High(ALockEntries) do
      if SameText(ALockEntries[k].Name, AName) then
      begin
        AOut := ALockEntries[k];
        Exit(True);
      end;
    Result := False;
  end;

  function GraphHasEntry(const AName: string): Boolean;
  var k: Integer;
  begin
    for k := 0 to High(AResolved) do
      if SameText(AResolved[k].Name, AName) then Exit(True);
    Result := False;
  end;

var
  i: Integer;
  Lock: TResolved;
begin
  { graph -> lockfile direction }
  for i := 0 to High(AResolved) do
  begin
    if not FindLockEntry(AResolved[i].Name, Lock) then
      raise EVerifyError.CreateFmt(
        '[frozen] manifest declares "%s" but lockfile has no entry. '
        + 'Run `lwpt install` (without --frozen) to regenerate the lockfile.',
        [AResolved[i].Name]);

    if AResolved[i].Hash <> Lock.Hash then
      raise EVerifyError.CreateFmt(
        '[frozen] tree hash mismatch for "%s": disk=%s lockfile=%s. '
        + 'The modules tree was modified after install. Restore from '
        + 'the committed .lwpt/modules/ or re-run `lwpt install`.',
        [AResolved[i].Name, AResolved[i].Hash, Lock.Hash]);

    { Archive hash check, but only when both sides have one. Local
      sources legitimately have no archive; mismatch on one side
      means the lockfile and the on-disk archives disagree. }
    if (AResolved[i].ArchiveHash <> '') or (Lock.ArchiveHash <> '') then
      if AResolved[i].ArchiveHash <> Lock.ArchiveHash then
        raise EVerifyError.CreateFmt(
          '[frozen] archive hash mismatch for "%s": disk=%s lockfile=%s. '
          + 'The .lwpt/archives/ tarball was modified after install. '
          + 'Restore it from version control or re-run `lwpt install`.',
          [AResolved[i].Name, AResolved[i].ArchiveHash, Lock.ArchiveHash]);
  end;

  { lockfile -> graph direction }
  for i := 0 to High(ALockEntries) do
    if not GraphHasEntry(ALockEntries[i].Name) then
      raise EVerifyError.CreateFmt(
        '[frozen] lockfile has "%s" but no manifest dep + child manifest '
        + 'reaches it. The dep was removed from the manifest tree but '
        + 'the lockfile not regenerated. Run `lwpt install` without --frozen.',
        [ALockEntries[i].Name]);
end;

{ Frozen-mode archive-hash recovery helper. The resolver doesn't know
  the archive filename in frozen mode (the resolved ref lives in the
  lockfile, not the manifest); look the entry up and re-hash. }
procedure FillFrozenArchiveHash(var AGraphEntry: TResolved;
  const ALockEntries: array of TResolved; const AArchivesRoot: string);
var
  k: Integer;
  Lock: TResolved;
  Archive: string;
begin
  for k := 0 to High(ALockEntries) do
    if SameText(ALockEntries[k].Name, AGraphEntry.Name) then
    begin
      Lock := ALockEntries[k];
      if Lock.SrcKind = skLocal then Exit;
      Archive := ArchivePathForRef(AArchivesRoot, AGraphEntry.Name,
        Lock.SrcKind, Lock.Version);
      if FileExists(Archive) then
        AGraphEntry.ArchiveHash := 'sha256:' + SHA256File(Archive);
      Exit;
    end;
end;

{ Lockfile-diff pruning (ADR-0019). The install transaction regenerates
  lwpt.lock + lwpt.cfg from the manifest but never deletes module trees,
  so a dep leaving the graph would otherwise stay in the committed
  .lwpt/ state forever. `lwpt add` / `lwpt remove` call this after their
  transaction with the previous + freshly written lockfile entries:
  a name present before and absent now loses its modules tree and its
  cached archive; a name whose resolved ref changed loses the stale old
  archive. Lives here (not in the command units) because the archive
  naming scheme is ArchivePathForRef's private knowledge. }
function CollectOrphanedPackagePaths(
  const AOldLock, ANewLock: array of TResolved;
  const AModulesRoot, AArchivesRoot: string;
  out APaths: TStringArray): Integer;

  function FindNewEntry(const AName: string; out AOut: TResolved): Boolean;
  var k: Integer;
  begin
    for k := 0 to High(ANewLock) do
      if SameText(ANewLock[k].Name, AName) then
      begin
        AOut := ANewLock[k];
        Exit(True);
      end;
    Result := False;
  end;

  procedure AddPath(const APath: string);
  var k, n: Integer;
  begin
    if APath = '' then Exit;
    for k := 0 to High(APaths) do
      if APaths[k] = APath then Exit;
    n := Length(APaths);
    SetLength(APaths, n + 1);
    APaths[n] := APath;
  end;

var
  i: Integer;
  Kept: TResolved;
  ModDir, OldArchive, NewArchive: string;
begin
  APaths := nil;
  Result := 0;
  for i := 0 to High(AOldLock) do
  begin
    { The names steer WipeDir/DeleteFile under .lwpt/. lwpt.lock is
      machine-written, but it sits on disk and is committed — a
      crafted key like "../.." must never become a deletion path.
      A name outside the package grammar was not written by LWPT:
      refuse loudly rather than skip silently. }
    if not ValidPackageName(AOldLock[i].Name) then
      raise ELockfileError.CreateFmt(
        'lockfile contains unsafe package key "%s"; refusing to prune',
        [AOldLock[i].Name]);

    if FindNewEntry(AOldLock[i].Name, Kept) then
    begin
      { Still in the graph — but an updated spec may have moved it to a
        new resolved ref (or to a local path, which has no archive at
        all), leaving the old version's archive behind. Only the OLD
        side must be non-local for there to be anything to reap. }
      if AOldLock[i].SrcKind = skLocal then Continue;
      OldArchive := ArchivePathForRef(AArchivesRoot, AOldLock[i].Name,
        AOldLock[i].SrcKind, AOldLock[i].Version);
      if Kept.SrcKind = skLocal then
        NewArchive := ''
      else
        NewArchive := ArchivePathForRef(AArchivesRoot, Kept.Name,
          Kept.SrcKind, Kept.Version);
      if OldArchive <> NewArchive then
        AddPath(OldArchive);
      Continue;
    end;

    { Gone from the graph — reap the extracted snapshot + cached archive. }
    ModDir := IncludeTrailingPathDelimiter(AModulesRoot) + AOldLock[i].Name;
    AddPath(ModDir);
    if AOldLock[i].SrcKind <> skLocal then
      AddPath(ArchivePathForRef(AArchivesRoot, AOldLock[i].Name,
        AOldLock[i].SrcKind, AOldLock[i].Version));
    Inc(Result);
  end;
end;

function PruneOrphanedPackages(const AOldLock, ANewLock: array of TResolved;
  const AModulesRoot, AArchivesRoot: string): Integer;
var Paths: TStringArray; i: Integer;
begin
  Result := CollectOrphanedPackagePaths(AOldLock, ANewLock,
    AModulesRoot, AArchivesRoot, Paths);
  for i := 0 to High(Paths) do
    if FileExists(Paths[i]) or DirectoryExists(Paths[i])
       or IsDirSymlinkOrJunction(Paths[i]) then
    begin
      if not AtomicRemovePath(Paths[i]) then
        raise EExtractError.CreateFmt(
          'failed to prune committed package path "%s"', [Paths[i]]);
      WriteLn('pruned ', Paths[i]);
    end;
end;

{ The shared transaction body. AManifestLines <> nil is the manifest-
  mutation flow (ADR-0019, `lwpt add` / `lwpt remove`): the previous
  lockfile is snapshotted right after the lock is acquired, the edited
  lwpt.toml is committed (atomically) after lockfile + cfg, and the
  lockfile diff prunes orphaned module trees + archives — all INSIDE
  the cross-process install lock, so a concurrent install can neither
  observe a manifest/lockfile mismatch nor race the prune deletions.
  AManifestLines = nil is the plain `lwpt install` flow. }
function RunInstallTransactionCore(const AContext: TManifestContext;
  const AMode: TInstallTransactionMode;
  const AManifestLines: TStringList): TInstallTransactionResult;
var
  Man : TManifest;
  R   : TResolution;
  Resolved : TResolvedArray;
  LockEntries, OldLock : TResolvedArray;
  Lock : TInstallLock;
  ModulesRoot, ArchivesRoot, TmpRoot, CfgPath, LockPath, LockfilePath,
    ManifestPath, RollbackRoot, RecoveryFailures, RollbackFailures : string;
  i, j, k : Integer;
  Frozen : Boolean;
  FrozenLock: TResolved;
  LockFound: Boolean;
  LockedVersionKind: TVersionKind;
  LockedVersionValue, CurrentSourceIdentity,
    CurrentConstraintFingerprint: string;
  HasCommitConstraint: Boolean;
  PublicationPending: Boolean;
  LockfileBackup, CfgBackup, ManifestBackup: string;
  OrphanRollbacks: TPathRollbackArray;
  TestCorruption: TStringList;
begin
  Man := AContext.Manifest;
  Frozen := AMode = itmFrozenVerify;

  ModulesRoot  := ResolveProjectPath(AContext.ProjectRoot, ResolveModulesDir(Man));
  ArchivesRoot := ResolveProjectPath(AContext.ProjectRoot, ResolveArchivesDir(Man));
  TmpRoot      := ResolveProjectPath(AContext.ProjectRoot, ResolveTmpDir(Man));
  CfgPath      := ResolveProjectPath(AContext.ProjectRoot, ResolveCfgFile(Man));
  LockPath     := ResolveProjectPath(AContext.ProjectRoot, INSTALL_LOCK);
  LockfilePath := ResolveProjectPath(AContext.ProjectRoot, LWPT.Core.LOCKFILE);
  ManifestPath := ResolveProjectPath(AContext.ProjectRoot, AContext.Path);

  Lock := TInstallLock.Create(LockPath);
  try
    PublicationPending := False;
    LockfileBackup := '';
    CfgBackup := '';
    ManifestBackup := '';
    RollbackRoot := '';
    OrphanRollbacks := nil;
    try
    if not Frozen then
    begin
      { Recover an interrupted writer before deleting any tmp state. Frozen
        verification is strictly read-only and never enters this path. }
      RecoveryFailures := RecoverPendingTransactions(TmpRoot);
      if RecoveryFailures <> '' then
        raise EExtractError.Create('could not recover interrupted install:'
          + LineEnding + RecoveryFailures);
      if DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
      ForceDirectories(TmpRoot);
      RollbackRoot := MakeTmpPath(TmpRoot, 'install-transaction');
      WriteTransactionState(RollbackRoot, 'pending');
      { Every rollback snapshot belongs to one journaled transaction root.
        Retention copies and validates the old value without removing it. }
      if not AtomicRetainPath(LockfilePath, RollbackRoot,
           'lockfile', LockfileBackup) then
        raise ELockfileError.Create(
          'failed to retain lockfile rollback copy');
      if not AtomicRetainPath(CfgPath, RollbackRoot,
           'cfg', CfgBackup) then
        raise EExtractError.Create('failed to retain cfg rollback copy');
      if AManifestLines <> nil then
        if not AtomicRetainPath(ManifestPath, RollbackRoot,
             'manifest', ManifestBackup) then
          raise EManifestError.Create(
            'failed to retain manifest rollback copy');
    end;

    { Mutation flow: snapshot the pre-transaction lock entries for the
      orphan diff before WriteLock overwrites them. }
    OldLock := nil;
    if (AManifestLines <> nil) and FileExists(LockfilePath) then
      OldLock := LoadLockfile(LockfilePath);

    R := Default(TResolution);
    WriteLn('resolving dependency graph (', Length(Man.Deps), ' direct)...');
    if Frozen then
    begin
      ResolveGraphFrozen(Man, R, ModulesRoot, AContext.ProjectRoot,
                         Man.Workspaces);
    end
    else
    begin
      ResolveGraphFixedPoint(Man, R, ModulesRoot, ArchivesRoot, TmpRoot,
                             RollbackRoot, AContext.ProjectRoot,
                             Man.Workspaces);
      PublicationPending := True;
    end;
    WriteLn('resolved ', Length(R.Nodes), ' packages, no conflicts.');

    SetLength(Resolved, Length(R.Nodes));
    for i := 0 to High(R.Nodes) do
    begin
      Resolved[i] := Default(TResolved);
      Resolved[i].Name        := R.Nodes[i].Name;
      Resolved[i].Version     := R.Nodes[i].Version;
      Resolved[i].CommitSHA   := R.Nodes[i].CommitSHA;
      Resolved[i].SourceIdentity := R.Nodes[i].SourceIdentity;
      Resolved[i].ConstraintFingerprint :=
        R.Nodes[i].ConstraintFingerprint;
      Resolved[i].SrcOriginal := R.Nodes[i].Dep.SrcOriginal;
      Resolved[i].SrcKind     := R.Nodes[i].Dep.SrcKind;
      Resolved[i].SrcHost     := R.Nodes[i].Dep.SrcHost;
      Resolved[i].SrcHostName := R.Nodes[i].Dep.SrcHostName;
      Resolved[i].SrcLocator  := R.Nodes[i].Dep.SrcLocator;
      Resolved[i].ResolvedURL := R.Nodes[i].ResolvedURL;
      Resolved[i].UnitDir     := R.Nodes[i].UnitDir;
      SetLength(Resolved[i].UnitSubdirs, Length(R.Nodes[i].UnitSubdirs));
      for j := 0 to High(R.Nodes[i].UnitSubdirs) do
        Resolved[i].UnitSubdirs[j] := R.Nodes[i].UnitSubdirs[j];
      Resolved[i].Archive     := R.Nodes[i].Archive;
      Resolved[i].ArchiveHash := R.Nodes[i].ArchiveHash;
      if R.Nodes[i].Hash <> '' then
        Resolved[i].Hash := R.Nodes[i].Hash
      else
        Resolved[i].Hash := 'sha256:(unfetched)';
    end;

    if Frozen then
    begin
      LockEntries := LoadLockfile(LockfilePath);
      for i := 0 to High(Resolved) do
      begin
        LockFound := False;
        FrozenLock := Default(TResolved);
        for k := 0 to High(LockEntries) do
          if SameText(LockEntries[k].Name, Resolved[i].Name) then
          begin
            FrozenLock := LockEntries[k];
            LockFound := True;
            Break;
          end;
        if not LockFound then Continue;
        CurrentSourceIdentity := CanonicalDependencyIdentity(
          R.Nodes[i].Dep, R.Nodes[i].CustomSources,
          AContext.ProjectRoot);
        CurrentConstraintFingerprint := ConstraintFingerprintForNode(
          R.Nodes[i], AContext.ProjectRoot);
        Resolved[i].SourceIdentity := CurrentSourceIdentity;
        Resolved[i].ConstraintFingerprint := CurrentConstraintFingerprint;
        if FrozenLock.SourceIdentity <> '' then
        begin
          if CurrentSourceIdentity <> FrozenLock.SourceIdentity then
            raise EVerifyError.CreateFmt(
              '[frozen] source or extraction policy changed for "%s". '
              + 'Run `lwpt install` without --frozen to resolve again.',
              [Resolved[i].Name]);
        end
        else if FrozenLock.SrcOriginal <> Resolved[i].SrcOriginal then
          raise EVerifyError.CreateFmt(
            '[frozen] legacy v3 source evidence is ambiguous for "%s". '
            + 'Run `lwpt install` without --frozen to regenerate the '
            + 'machine-written lockfile; do not edit it.',
            [Resolved[i].Name]);
        if (FrozenLock.ConstraintFingerprint <> '')
           and (CurrentConstraintFingerprint <>
             FrozenLock.ConstraintFingerprint) then
          raise EVerifyError.CreateFmt(
            '[frozen] accumulated constraints changed for "%s". '
            + 'Run `lwpt install` without --frozen to resolve again.',
            [Resolved[i].Name]);
        Resolved[i].Version := FrozenLock.Version;
        Resolved[i].CommitSHA := FrozenLock.CommitSHA;
        HasCommitConstraint := False;
        for j := 0 to High(R.Nodes[i].Kinds) do
          HasCommitConstraint := HasCommitConstraint
            or (R.Nodes[i].Kinds[j] = vkCommitSha);
        if (Resolved[i].SrcKind = skGitHost)
           and (Resolved[i].CommitSHA = '') then
        begin
          ParseVersionSpec(FrozenLock.Version, LockedVersionKind,
            LockedVersionValue);
          if LockedVersionKind = vkCommitSha then
            Resolved[i].CommitSHA := LockedVersionValue
          else if HasCommitConstraint then
            raise EVerifyError.CreateFmt(
              '[frozen] legacy v3 lock entry "%s" combines a mutable '
              + 'or named ref with a SHA constraint but records no '
              + 'authoritative commit identity. Run `lwpt install` '
              + 'without --frozen to regenerate the machine-written '
              + 'lockfile; do not edit it.', [Resolved[i].Name]);
        end;
        for j := 0 to High(R.Nodes[i].Kinds) do
          case R.Nodes[i].Kinds[j] of
            vkSemverRange:
              if not Satisfies(StripVPrefix(FrozenLock.Version),
                   R.Nodes[i].Specs[j], DefaultSemverOptions) then
                raise EVerifyError.CreateFmt(
                  '[frozen] locked ref "%s" no longer satisfies "%s" '
                  + 'for "%s"', [FrozenLock.Version,
                  R.Nodes[i].Specs[j], Resolved[i].Name]);
            vkSemverExact:
              if (FrozenLock.Version <> R.Nodes[i].Specs[j])
                 and (FrozenLock.Version <> 'v' + R.Nodes[i].Specs[j]) then
                raise EVerifyError.CreateFmt(
                  '[frozen] locked ref "%s" does not satisfy exact "%s" '
                  + 'for "%s"', [FrozenLock.Version,
                  R.Nodes[i].Specs[j], Resolved[i].Name]);
            vkCommitSha:
              if not SameText(R.Nodes[i].Specs[j],
                   Copy(Resolved[i].CommitSHA, 1,
                     Length(R.Nodes[i].Specs[j]))) then
                raise EVerifyError.CreateFmt(
                  '[frozen] locked commit does not satisfy SHA "%s" '
                  + 'for "%s"', [R.Nodes[i].Specs[j], Resolved[i].Name]);
            vkLiteralTag:
              if (FrozenLock.ConstraintFingerprint = '')
                 and (FrozenLock.Version <> R.Nodes[i].Specs[j]) then
                raise EVerifyError.CreateFmt(
                  '[frozen] legacy v3 locked ref "%s" does not prove '
                  + 'literal ref "%s" for "%s". Run `lwpt install` '
                  + 'without --frozen to regenerate authoritative '
                  + 'identity evidence.', [FrozenLock.Version,
                  R.Nodes[i].Specs[j], Resolved[i].Name]);
            vkNone:;
          end;
        if Resolved[i].SrcKind <> skLocal then
          FillFrozenArchiveHash(Resolved[i], LockEntries, ArchivesRoot);
      end;
      VerifyAgainstLockfile(Resolved, LockEntries);
      WriteLn('[frozen] ', Length(Resolved),
              ' packages verified against ', LWPT.Core.LOCKFILE,
              ' (archive + tree hashes both match).');
      Result.PackageCount := Length(Resolved);
      Result.LockfilePath := LockfilePath;
      Result.CfgPath := CfgPath;
      Result.Resolved := Resolved;
      Exit;
    end;

    WriteLock(LockfilePath, TmpRoot, Resolved);
    if SysUtils.GetEnvironmentVariable(
      PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE') = '1' then
    begin
      if SysUtils.GetEnvironmentVariable(
        PROJECT_NAME + '_TEST_CORRUPT_ROLLBACK_FOR') <> '' then
        for i := 0 to High(R.Nodes) do
          if SameText(R.Nodes[i].Name,
               SysUtils.GetEnvironmentVariable(
                 PROJECT_NAME + '_TEST_CORRUPT_ROLLBACK_FOR'))
             and (R.Nodes[i].UnitBackup <> '') then
          begin
            ForceDirectories(R.Nodes[i].UnitBackup);
            TestCorruption := TStringList.Create;
            try
              TestCorruption.Add('corrupt');
              TestCorruption.SaveToFile(
                R.Nodes[i].UnitBackup + '/corrupt.txt');
            finally
              TestCorruption.Free;
            end;
          end;
      raise ELockfileError.Create(
        'injected failure after lockfile publication');
    end;
    WriteCfg(CfgPath, TmpRoot, Resolved, Man, AContext.ProjectRoot);
    WriteLn('wrote ', LWPT.Core.LOCKFILE, ' (', Length(Resolved),
            ' packages) and ', CfgPath);

    if AManifestLines <> nil then
    begin
      { Retain stale committed graph paths before publishing the manifest.
        The manifest is the last fallible publication step: after it lands,
        only best-effort tmp cleanup remains. }
      RetainOrphanedPackagePaths(OldLock, Resolved, ModulesRoot,
        ArchivesRoot, RollbackRoot, OrphanRollbacks);
      if SysUtils.GetEnvironmentVariable(
           PROJECT_NAME + '_TEST_FAIL_AFTER_ORPHAN_RETAIN') = '1' then
        raise EExtractError.Create(
          'injected failure after orphan retention');
      AtomicWriteText(ManifestPath, TmpRoot, AManifestLines);
    end;

    Result.PackageCount := Length(Resolved);
    Result.LockfilePath := LockfilePath;
    Result.CfgPath := CfgPath;
    Result.Resolved := Resolved;
    MarkTransactionCommitted(RollbackRoot);
    FinalizeResolutionPublication(R);
    PublicationPending := False;
    DiscardRetainedPaths(OrphanRollbacks);
    AtomicDiscardRetainedPath(LockfileBackup);
    AtomicDiscardRetainedPath(CfgBackup);
    if ManifestBackup <> '' then
      AtomicDiscardRetainedPath(ManifestBackup);
    if DirectoryExists(RollbackRoot) then WipeDir(RollbackRoot);
    except
      on E: Exception do
      begin
        RollbackFailures := '';
        if PublicationPending then
          AppendRollbackFailure(RollbackFailures,
            RollbackResolutionPublication(R));
        AppendRollbackFailure(RollbackFailures,
          RollbackRetainedPaths(OrphanRollbacks));
        if LockfileBackup <> '' then
          TryRollbackRestore(LockfileBackup, LockfilePath,
            'failed to restore lockfile', RollbackFailures);
        if CfgBackup <> '' then
          TryRollbackRestore(CfgBackup, CfgPath,
            'failed to restore cfg', RollbackFailures);
        if ManifestBackup <> '' then
          TryRollbackRestore(ManifestBackup, ManifestPath,
            'failed to restore manifest', RollbackFailures);
        if (RollbackRoot <> '') and DirectoryExists(RollbackRoot)
           and not RollbackRootHasMarkers(RollbackRoot) then
          WipeDir(RollbackRoot);
        if RollbackFailures <> '' then
          raise EExtractError.Create(E.Message + LineEnding
            + 'rollback failures:' + LineEnding + RollbackFailures
            + LineEnding + 'validated recovery state retained under '
            + RollbackRoot);
        raise;
      end;
    end;
  finally
    Lock.Free;
  end;
end;

function RunInstallTransaction(const AContext: TManifestContext; const AMode: TInstallTransactionMode): TInstallTransactionResult;
begin
  Result := RunInstallTransactionCore(AContext, AMode, nil);
end;

procedure RecoverInterruptedInstall(const AContext: TManifestContext);
var TmpRoot, Failures: string;
begin
  TmpRoot := ResolveProjectPath(AContext.ProjectRoot,
    ResolveTmpDir(AContext.Manifest));
  Failures := RecoverPendingTransactions(TmpRoot);
  if Failures <> '' then
    raise EExtractError.Create('could not recover interrupted install:'
      + LineEnding + Failures);
end;

function RunManifestMutationTransaction(const AContext: TManifestContext; const AManifestLines: TStringList): TInstallTransactionResult;
begin
  Result := RunInstallTransactionCore(AContext, itmMaterialize, AManifestLines);
end;

end.
