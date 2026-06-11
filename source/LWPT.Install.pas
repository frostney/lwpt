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
  end;

function  LoadLockfile(const APath: string): TResolvedArray;
function  ExtractArchive(const AArchivePath, ADest: string; const ASubDir: string = ''): Integer;
procedure VerifyAgainstLockfile(const AResolved: array of TResolved; const ALockEntries: array of TResolved);
function  RunInstallTransaction(const AContext: TManifestContext; const AMode: TInstallTransactionMode): TInstallTransactionResult;

implementation

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  HTTPClient,
  LWPT.GitProtocol,
  Semver,
  TOML,
  zstream;

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

function FindTagInRefs(const ARefs: TGitRefArray;
  const AName: string): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to High(ARefs) do
    if (ARefs[i].Kind = rkTag) and (ARefs[i].Name = AName) then
      Exit(i);
end;

function ResolveDepRef(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray): string;
var
  Refs : TGitRefArray;
  Candidates : array of string;
  TagToWire : array of string;
  i, MatchIdx : Integer;
  Stripped, Chosen : string;
begin
  case ADep.VersionKind of
    vkNone:
      Exit('');
    vkCommitSha:
      Exit(ADep.VersionSpec);
    vkLiteralTag:
      { No tag-list verification — we hand the literal to FetchURL
        and let the fetch fail with EFetchError if the tag is
        absent. Keeps this path one-round-trip (the fetch IS the
        verification). }
      Exit(ADep.VersionSpec);
  end;

  { vkSemverRange / vkSemverExact both need the tag list. }
  if ADep.SrcKind <> skGitHost then
    raise EFetchError.CreateFmt(
      'dependency "%s": SemVer version spec "%s" requires a git-host '
      + 'source; skURL and skLocal sources do not support SemVer '
      + 'resolution', [ADep.Name, ADep.VersionSpec]);

  WriteLn('  resolving tags for ', ADep.Name, '...');
  Refs := ListRemoteRefs(GitRepoURL(ADep, ACustomSources));

  if ADep.VersionKind = vkSemverExact then
  begin
    { Try the spec verbatim, then v<spec>. First match wins. }
    MatchIdx := FindTagInRefs(Refs, ADep.VersionSpec);
    if MatchIdx >= 0 then Exit(Refs[MatchIdx].Name);
    MatchIdx := FindTagInRefs(Refs, 'v' + ADep.VersionSpec);
    if MatchIdx >= 0 then Exit(Refs[MatchIdx].Name);
    raise EFetchError.CreateFmt(
      'dependency "%s": no tag matching "%s" or "v%s" found in '
      + 'remote repo (looked at %d tag entries)',
      [ADep.Name, ADep.VersionSpec, ADep.VersionSpec, Length(Refs)]);
  end;

  { vkSemverRange — build a parallel array of (stripped-tag, wire-tag)
    pairs so we can MaxSatisfying on the stripped form and recover
    the wire name for the URL. }
  SetLength(Candidates, 0);
  SetLength(TagToWire, 0);
  for i := 0 to High(Refs) do
    if Refs[i].Kind = rkTag then
    begin
      Stripped := StripVPrefix(Refs[i].Name);
      if Valid(Stripped, DefaultSemverOptions) = '' then Continue;
      SetLength(Candidates,  Length(Candidates) + 1);
      SetLength(TagToWire,   Length(TagToWire) + 1);
      Candidates[High(Candidates)] := Stripped;
      TagToWire[High(TagToWire)]   := Refs[i].Name;
    end;

  if Length(Candidates) = 0 then
    raise EFetchError.CreateFmt(
      'dependency "%s": no SemVer-shaped tags found in remote repo '
      + '(version spec was "%s"; %d total refs)',
      [ADep.Name, ADep.VersionSpec, Length(Refs)]);

  Chosen := MaxSatisfying(Candidates, ADep.VersionSpec,
    DefaultSemverOptions);
  if Chosen = '' then
    raise EFetchError.CreateFmt(
      'dependency "%s": no tag satisfies "%s" (looked at %d SemVer '
      + 'tags)', [ADep.Name, ADep.VersionSpec, Length(Candidates)]);

  for i := 0 to High(Candidates) do
    if Candidates[i] = Chosen then Exit(TagToWire[i]);
  Result := Chosen;  { fall-through shouldn't happen but be safe }
end;

{ ===========================================================================
  Registry version negotiation (http source) — DEFERRED TO v2

  The skHttp source kind and the registry consumer (NegotiateVersion,
  PickFromIndex) were removed from v1 per ADR-0004. The spike code is
  archived at docs/spikes/http-registry-spike.md as prior art for the
  v2 work that will spec the registry format and re-derive the
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

{ Sha256 of a TBytes for the [resolved].archiveHash field. The same hex
  shape as HashTree ('sha256:<hex>') so callers can compare directly. }
function SHA256BytesPrefixed(const ABytes: TBytes): string;
begin
  Result := 'sha256:' + SHA256Hex(ABytes);
end;

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
  UnitDir = ModulesRoot/<name>. The caller (ResolveGraph) is responsible
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

{ ===========================================================================
  Monorepo link helpers (ADR-0014 amendment "Symlink/junction for monorepo
  deps"). Local-path deps whose resolved path is INSIDE the project root
  install via symlink (Unix) or NTFS junction (Windows native), saving disk
  + propagating edits to packages/<name>/source/ immediately. Outside-the-
  project local-path deps (../../X, /abs/path/X) install via the existing
  recursive copy — the link target could disappear / move and we don't
  want to track that.
  =========================================================================== }

function IsPathInside(const AParent, AChild: string): Boolean;
var
  ParentAbs, ChildAbs: string;
begin
  ParentAbs := IncludeTrailingPathDelimiter(ExpandFileName(AParent));
  ChildAbs  := IncludeTrailingPathDelimiter(ExpandFileName(AChild));
  {$IFDEF MSWINDOWS}
  Result := SameText(Copy(ChildAbs, 1, Length(ParentAbs)), ParentAbs);
  {$ELSE}
  Result := Copy(ChildAbs, 1, Length(ParentAbs)) = ParentAbs;
  {$ENDIF}
end;

{ Native junction creation on Windows — no `mklink /J` shell-out, no
  Developer Mode required (junctions need only write permission to the
  parent dir). Uses CreateFileW with FILE_FLAG_OPEN_REPARSE_POINT +
  FILE_FLAG_BACKUP_SEMANTICS, then DeviceIoControl with
  FSCTL_SET_REPARSE_POINT + IO_REPARSE_TAG_MOUNT_POINT. The substitute
  name needs the "\??\" NT-namespace prefix; the print name is the
  display path without the prefix. The REPARSE_DATA_BUFFER layout for
  mount points is the standard one — see SDK winioctl.h. }
{$IFDEF MSWINDOWS}
const
  FSCTL_SET_REPARSE_POINT_LWPT  = $000900A4;
  IO_REPARSE_TAG_MOUNT_POINT_LWPT = $A0000003;
  FILE_FLAG_OPEN_REPARSE_POINT_LWPT = $00200000;
  FILE_FLAG_BACKUP_SEMANTICS_LWPT   = $02000000;
type
  TLwptMountPointReparseBuffer = packed record
    ReparseTag           : DWORD;
    ReparseDataLength    : Word;
    Reserved             : Word;
    SubstituteNameOffset : Word;
    SubstituteNameLength : Word;
    PrintNameOffset      : Word;
    PrintNameLength      : Word;
    PathBuffer           : array[0..(16 * 1024) div SizeOf(WideChar) - 16] of WideChar;
  end;
{$ENDIF}

function CreateDirLink(const ALink, ATarget: string): Boolean;
{$IFDEF UNIX}
var
  LinkParent, RelativeTarget: string;
begin
  LinkParent := IncludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(ALink)));
  RelativeTarget := ExtractRelativePath(LinkParent, ExpandFileName(ATarget));
  Result := FpSymlink(PChar(RelativeTarget), PChar(ALink)) = 0;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Buf: TLwptMountPointReparseBuffer;
  H: THandle;
  SubstW, PrintW: UnicodeString;
  SubstBytes, PrintBytes: Word;
  Returned: Cardinal;
begin
  Result := False;
  PrintW := UnicodeString(ExpandFileName(ATarget));
  SubstW := UnicodeString('\??\') + PrintW;
  SubstBytes := Length(SubstW) * SizeOf(WideChar);
  PrintBytes := Length(PrintW) * SizeOf(WideChar);
  { Layout: substitute-name + null-terminator + print-name + null-terminator.
    Total buffer needs (SubstBytes + 2 + PrintBytes + 2) bytes. Bail early
    if it doesn't fit (very long path). }
  if SubstBytes + PrintBytes + 4 > SizeOf(Buf.PathBuffer) then Exit;

  { Junctions go on top of an EXISTING empty dir; create it first. }
  if not Windows.CreateDirectoryW(PWideChar(UnicodeString(ALink)), nil) then
    Exit;

  H := Windows.CreateFileW(PWideChar(UnicodeString(ALink)),
    Windows.GENERIC_WRITE, 0, nil, Windows.OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS_LWPT or FILE_FLAG_OPEN_REPARSE_POINT_LWPT,
    0);
  if H = THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    Windows.RemoveDirectoryW(PWideChar(UnicodeString(ALink)));
    Exit;
  end;

  FillChar(Buf, SizeOf(Buf), 0);
  Buf.ReparseTag           := IO_REPARSE_TAG_MOUNT_POINT_LWPT;
  Buf.SubstituteNameOffset := 0;
  Buf.SubstituteNameLength := SubstBytes;
  Buf.PrintNameOffset      := SubstBytes + SizeOf(WideChar);
  Buf.PrintNameLength      := PrintBytes;
  Move(SubstW[1], Buf.PathBuffer[0], SubstBytes);
  Move(PrintW[1],
    Buf.PathBuffer[(SubstBytes div SizeOf(WideChar)) + 1],
    PrintBytes);
  { ReparseDataLength = the four USHORT fields (8 bytes) + the path
    buffer payload (subst + null + print + null). }
  Buf.ReparseDataLength := 8 + SubstBytes + SizeOf(WideChar)
                            + PrintBytes + SizeOf(WideChar);
  try
    Result := Windows.DeviceIoControl(H, FSCTL_SET_REPARSE_POINT_LWPT,
      @Buf, Buf.ReparseDataLength + 8,  { + 8 for ReparseTag/Len/Reserved }
      nil, 0, Returned, nil);
    if not Result then
      Windows.RemoveDirectoryW(PWideChar(UnicodeString(ALink)));
  finally
    Windows.CloseHandle(H);
  end;
end;
{$ENDIF}

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
  EffectiveDep : TDependency;
  k : Integer;
  WSPath : string;
  AvailableNames : string;
  StagePath : string;

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
    { Monorepo deps (resolved path INSIDE AProjectRoot) install via
      symlink / junction — edits to packages/<name>/source/X.pas are
      visible immediately under .lwpt/modules/<name>/source/X.pas.
      External-path deps (../../X, /abs/X) install via the existing
      recursive copy because the link target could disappear / move
      independently. Per-dep decision; AProjectRoot is the dir of the
      root manifest. See ADR-0014 amendment §"Symlink/junction for
      monorepo deps". }
    if (AProjectRoot <> '')
       and IsPathInside(AProjectRoot, LocalPath) then
    begin
      StagePath := MakeTmpPath(ATmpRoot, 'link-' + ADep.Name);
      if CreateDirLink(StagePath, LocalPath) then
      begin
        if AtomicMoveDir(StagePath, AUnitDir) then
          WriteLn('  linked ', ADep.Name)
        else
        begin
          WipeDir(StagePath);
          WriteLn(ErrOutput, '  warning: link commit failed for ', ADep.Name,
            '; falling back to copy');
          StageLocalCopy(' (link commit fallback)');
        end;
      end
      else
      begin
        { Link creation failed (rare — Windows without junction
          permission, FS that doesn't support links, etc). Fall back
          to copy so the install still completes. The user sees both
          the failure cue and the recovery. }
        WriteLn(ErrOutput, '  warning: link failed for ', ADep.Name,
          '; falling back to copy');
        if DirectoryExists(StagePath) then
          WipeDir(StagePath);
        StageLocalCopy(' (link fallback)');
      end;
    end
    else
    begin
      { External-path dep — always copy. }
      StageLocalCopy('');
    end;
    Exit(True);
  end;

  { Network sources (skGitHost / skURL) go through HTTPGet. The URL
    is whatever FetchURL builds — already host-aware for skGitHost,
    or the verbatim URL for skURL. }
  URL := FetchURL(ADep, AResolvedRef, ACustomSources);
  if URL = '' then Exit(False);
  AResolvedURL := URL;

  NoHeaders := nil;
  Resp := HTTPGet(URL, NoHeaders);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    raise EFetchError.CreateFmt('fetch %s failed: HTTP %d %s',
      [URL, Resp.StatusCode, Resp.StatusText]);

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
      SysUtils.DeleteFile(PendingLinks[li].LinkPath);
      CopyDirTree(ResolvedTarget, PendingLinks[li].LinkPath);
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
function TomlEscape(const S: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '"' : Result := Result + '\"';
      '\' : Result := Result + '\\';
      #9  : Result := Result + '\t';
      #10 : Result := Result + '\n';
      #13 : Result := Result + '\r';
    else
      Result := Result + S[i];
    end;
end;

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
{ ===========================================================================
  SHA-256  (self-contained, public-domain algorithm)

  FPC 3.2.2's `hash` package ships md5 and sha1 but NOT sha256, and the
  spike must run on 3.2.2. SHA-1 was rejected: it is dated for content
  integrity and skills-lock.json's `computedHash` field already commits to
  SHA-256-shaped values. So SHA-256 is inlined here. Validated below
  against the canonical "abc" test vector.
  =========================================================================== }
type
  TSHA256Digest = array[0..31] of Byte;

{ SHA-256 performs intentional modular arithmetic on 32-bit values
  (Cardinals): the compression loop's `temp1 := h + s1 + ch + K[t] + W[t]`
  and `W[t] := W[t-16] + s0 + W[t-7] + s1` deliberately wrap on
  overflow — that's how the algorithm produces correct hashes. FPC's
  range check ({$R+}) detects the intermediate Int64-promoted sums
  exceeding Cardinal's range and raises EangeError. Disable range
  checking inside this function so the modular arithmetic runs as
  written. The unit tests (NIST vectors) don't catch this because
  the test compiler doesn't pass -Cr; lwpt's dev build does, and the
  network-source archive-hash path was the first call site to hit
  it after the matching ADR. }
{$PUSH}{$R-}{$Q-}
function SHA256Bytes(const AData: TBytes): TSHA256Digest;
const
  K: array[0..63] of Cardinal = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);
var
  HV: array[0..7] of Cardinal;
  W: array[0..63] of Cardinal;
  Msg: TBytes;
  BitLen: QWord;
  i, t, ChunkStart: Integer;
  a,b,c,d,e,f,g,h, s0,s1, ch, maj, temp1, temp2: Cardinal;

  function RotR(x: Cardinal; n: Byte): Cardinal; inline;
  begin
    Result := (x shr n) or (x shl (32 - n));
  end;

begin
  HV[0]:=$6a09e667; HV[1]:=$bb67ae85; HV[2]:=$3c6ef372; HV[3]:=$a54ff53a;
  HV[4]:=$510e527f; HV[5]:=$9b05688c; HV[6]:=$1f83d9ab; HV[7]:=$5be0cd19;

  BitLen := QWord(Length(AData)) * 8;
  { pad: 0x80, then zeros, then 64-bit big-endian length }
  Msg := Copy(AData, 0, Length(AData));
  SetLength(Msg, Length(Msg) + 1);
  Msg[High(Msg)] := $80;
  while (Length(Msg) mod 64) <> 56 do
    SetLength(Msg, Length(Msg) + 1);
  SetLength(Msg, Length(Msg) + 8);
  for i := 0 to 7 do
    Msg[Length(Msg) - 1 - i] := Byte((BitLen shr (8 * i)) and $FF);

  ChunkStart := 0;
  while ChunkStart < Length(Msg) do
  begin
    for t := 0 to 15 do
      W[t] := (Cardinal(Msg[ChunkStart + t*4    ]) shl 24) or
              (Cardinal(Msg[ChunkStart + t*4 + 1]) shl 16) or
              (Cardinal(Msg[ChunkStart + t*4 + 2]) shl 8) or
              (Cardinal(Msg[ChunkStart + t*4 + 3]));
    for t := 16 to 63 do
    begin
      s0 := RotR(W[t-15],7) xor RotR(W[t-15],18) xor (W[t-15] shr 3);
      s1 := RotR(W[t-2],17) xor RotR(W[t-2],19) xor (W[t-2] shr 10);
      W[t] := W[t-16] + s0 + W[t-7] + s1;
    end;

    a:=HV[0]; b:=HV[1]; c:=HV[2]; d:=HV[3];
    e:=HV[4]; f:=HV[5]; g:=HV[6]; h:=HV[7];

    for t := 0 to 63 do
    begin
      s1   := RotR(e,6) xor RotR(e,11) xor RotR(e,25);
      ch   := (e and f) xor ((not e) and g);
      temp1:= h + s1 + ch + K[t] + W[t];
      s0   := RotR(a,2) xor RotR(a,13) xor RotR(a,22);
      maj  := (a and b) xor (a and c) xor (b and c);
      temp2:= s0 + maj;
      h:=g; g:=f; f:=e; e:=d + temp1;
      d:=c; c:=b; b:=a; a:=temp1 + temp2;
    end;

    Inc(HV[0],a); Inc(HV[1],b); Inc(HV[2],c); Inc(HV[3],d);
    Inc(HV[4],e); Inc(HV[5],f); Inc(HV[6],g); Inc(HV[7],h);
    Inc(ChunkStart, 64);
  end;

  for i := 0 to 7 do
  begin
    Result[i*4    ] := Byte((HV[i] shr 24) and $FF);
    Result[i*4 + 1] := Byte((HV[i] shr 16) and $FF);
    Result[i*4 + 2] := Byte((HV[i] shr 8) and $FF);
    Result[i*4 + 3] := Byte( HV[i]         and $FF);
  end;
end;
{$POP}

function SHA256Hex(const AData: TBytes): string;
var D: TSHA256Digest; i: Integer;
begin
  D := SHA256Bytes(AData);
  Result := '';
  for i := 0 to 31 do
    Result := Result + LowerCase(IntToHex(D[i], 2));
end;

function SHA256File(const APath: string): string;
var FS: TFileStream; Buf: TBytes;
begin
  if not FileExists(APath) then Exit('');
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Buf[0], FS.Size);
  finally
    FS.Free;
  end;
  Result := SHA256Hex(Buf);
end;

{ Hash of an installed package: SHA-256 over every extracted file's bytes,
  visited in sorted relative-path order so the digest is stable regardless
  of filesystem enumeration order or which mirror served the archive.
  This is the value that goes in lwpt.lock's computedHash.

  Directory symlinks are never descended into: a link cycle would recurse
  forever, and the linked bytes are hashed where they really live. File
  symlinks still contribute (their target's bytes are read through the
  link, as before) — but only when the target resolves: a dangling link
  was invisible to the old faAnyFile-only enumeration, so it must stay
  excluded or HashTree fails opening it. faSymLink must be in the
  FindFirst mask or the attribute is not reported and links look like
  plain directories (or, dangling, vanish entirely).
  MUST stay in lockstep with LWPT.Core's CollectFiles — install writes
  computedHash with this copy, and the two may not disagree. }
procedure CollectFiles(const ARoot, ARel: string; AList: TStringList);
var SR: TSearchRec; Path, RelPath: string;
begin
  Path := IncludeTrailingPathDelimiter(ARoot + ARel);
  if SysUtils.FindFirst(Path + '*', faAnyFile or faSymLink, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      RelPath := ARel + SR.Name;
      if (SR.Attr and faSymLink) <> 0 then
      begin
        if ((SR.Attr and faDirectory) = 0)
           and FileExists(Path + SR.Name) then
          AList.Add(RelPath);
      end
      else if (SR.Attr and faDirectory) <> 0 then
        CollectFiles(ARoot, RelPath + PathDelim, AList)
      else
        AList.Add(RelPath);
    until SysUtils.FindNext(SR) <> 0;
    SysUtils.FindClose(SR);
  end;
end;

function HashTree(const APathOrArchive: string): string;
var
  Files : TStringList;
  Acc   : TBytes;
  i, n  : Integer;
  Chunk : TBytes;
  FS    : TFileStream;
  FullPath : string;
begin
  { directory: hash the sorted file tree }
  if DirectoryExists(APathOrArchive) then
  begin
    Files := TStringList.Create;
    try
      CollectFiles(IncludeTrailingPathDelimiter(APathOrArchive), '', Files);
      Files.Sort;
      SetLength(Acc, 0);
      for i := 0 to Files.Count - 1 do
      begin
        { fold the relative path in too, so renames change the hash }
        Chunk := BytesOf(Files[i] + #10);
        n := Length(Acc);
        SetLength(Acc, n + Length(Chunk));
        if Length(Chunk) > 0 then Move(Chunk[0], Acc[n], Length(Chunk));

        FullPath := IncludeTrailingPathDelimiter(APathOrArchive) + Files[i];
        FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
        try
          n := Length(Acc);
          SetLength(Acc, n + FS.Size);
          if FS.Size > 0 then FS.ReadBuffer(Acc[n], FS.Size);
        finally
          FS.Free;
        end;
      end;
      Result := 'sha256:' + SHA256Hex(Acc);
    finally
      Files.Free;
    end;
  end
  { file (e.g. the archive itself): hash its bytes }
  else if FileExists(APathOrArchive) then
    Result := 'sha256:' + SHA256File(APathOrArchive)
  else
    Result := 'sha256:' + SHA256Hex(BytesOf(APathOrArchive));
end;

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
    Requirers   : array of string;   { parallel to Specs }
    Dep         : TDependency;       { the first source spec seen }
    Version     : string;            { concrete (resolved ref or SHA) }
    ResolvedURL : string;            { actual archive URL fetched }
    UnitDir     : string;            { the dep's modules root (.lwpt/modules/<name>) }
    UnitSubdirs : array of string;   { from ChildMan.Units — relative paths
                                       under UnitDir where the dep's .pas
                                       files actually live (typically
                                       ["source"]). Drives -Fu emission. }
    Hash        : string;            { tree hash of UnitDir contents }
    ArchiveHash : string;            { sha256 of the .tar.gz; '' for skLocal }
    Archive     : string;            { path to the committed archive; '' for skLocal }
  end;

  TResolution = record
    Nodes : array of TResolveNode;
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
  const ARequiredBy: string; out AIsNew: Boolean): Integer;
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
  SetLength(R.Nodes[idx].Requirers, n + 1);
  R.Nodes[idx].Specs[n]     := ADep.VersionSpec;
  R.Nodes[idx].Requirers[n] := ARequiredBy;
  Result := idx;
end;

{ Conflict check — FPC has one global unit namespace; two
  different concrete versions of the same package cannot coexist.

  Currently we use a conservative rule: every constraint pair on the
  same package must be jointly satisfiable. The check is delegated
  to SemVer when both sides are SemVer-shaped (range / exact), and
  falls back to identical-string match for literal tags + SHAs.
  A smarter resolver (mixed bucket support, multi-version selection)
  is v1.x work; the conservative rule errs on the side of failing
  loudly so projects don't silently get the wrong version. }
procedure CheckNodeConstraints(const ANode: TResolveNode);

  procedure Conflict(i, j: Integer; const AReason: string);
  begin
    Flush(Output);
    WriteLn(ErrOutput);
    WriteLn(ErrOutput, 'CONFLICT on package "', ANode.Name, '":');
    WriteLn(ErrOutput, '  ', ANode.Requirers[i], ' wants "',
            ANode.Specs[i], '"');
    WriteLn(ErrOutput, '  ', ANode.Requirers[j], ' wants "',
            ANode.Specs[j], '"');
    WriteLn(ErrOutput, '  ', AReason);
    WriteLn(ErrOutput,
      '  FPC has one global unit namespace — both cannot coexist.');
    raise EManifestError.CreateFmt(
      'unresolvable version conflict on "%s"', [ANode.Name]);
  end;

  function IsSemverShaped(const S: string): Boolean;
  begin
    Result := (ValidRange(S, DefaultSemverOptions) <> '')
           or ((S <> '') and (S[1] <> 'v') and (S[1] <> 'V')
               and (Valid(S, DefaultSemverOptions) <> ''));
  end;

var i, j: Integer;
begin
  for i := 0 to High(ANode.Specs) do
    for j := i + 1 to High(ANode.Specs) do
    begin
      { Empty spec (vkNone — local sources) always agrees with itself. }
      if (ANode.Specs[i] = '') and (ANode.Specs[j] = '') then Continue;
      if (ANode.Specs[i] = '') or (ANode.Specs[j] = '') then
        Conflict(i, j,
          'one side is unversioned (local source) and one is not');

      if IsSemverShaped(ANode.Specs[i]) and IsSemverShaped(ANode.Specs[j]) then
      begin
        if not RangeIntersects(ANode.Specs[i], ANode.Specs[j],
                               DefaultSemverOptions) then
          Conflict(i, j, 'SemVer specs do not intersect.');
      end
      else
      begin
        { Non-SemVer specs (literal tag / SHA / mixed). Require
          identical strings — anything else is ambiguous. }
        if ANode.Specs[i] <> ANode.Specs[j] then
          Conflict(i, j,
            'literal-tag / SHA / mixed specs must match exactly.');
      end;
    end;
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

{ The BFS itself. Mutates R; fetches+extracts each new package unless
  Frozen. ModulesRoot is where extracted dep trees land
  (.lwpt/modules/<dep>/ by default); ArchivesRoot is where the source
  .tar.gz files land (.lwpt/archives/<dep>-<version>.tar.gz by default);
  TmpRoot is the Atomic-write staging dir (.lwpt/tmp/ by default).

  Frozen behavior (post-amendment): skip network fetch. If the dep's modules
  dir is already present (zero-install committed state), proceed using
  it as-is — caller (CmdInstall) then does the hash verification pass.
  Missing modules dir → EFetchError naming the dep + recovery hint. }
procedure ResolveGraph(const ARootMan: TManifest; var R: TResolution;
  const AModulesRoot, AArchivesRoot, ATmpRoot, AProjectRoot: string;
  const AWorkspaces: TWorkspaceArray;
  AFrozen: Boolean);
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
  UnitDir, Archive, ArchiveHash, ResolvedURL, ChildManifestPath,
    ManifestRelDir, ExtractTmp : string;
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

    idx := TouchNode(R, Item.Dep, Item.RequiredBy, IsNew);
    if not IsNew then
      Continue;   { already fetched & expanded; constraint recorded above }

    UnitDir := IncludeTrailingPathDelimiter(AModulesRoot) + Item.Dep.Name;
    Archive := '';
    ArchiveHash := '';
    ResolvedURL := '';

    if AFrozen then
    begin
      if not DirectoryExists(UnitDir) then
        raise EFetchError.CreateFmt(
          '[frozen] missing extracted module for "%s" at %s '
          + '(required by %s). Run `lwpt install` without --frozen to '
          + 'fetch, or restore the committed .lwpt/modules tree.',
          [Item.Dep.Name, UnitDir, Item.RequiredBy]);
      WriteLn('  [frozen] ', Item.Dep.Name,
              '  (required by ', Item.RequiredBy, ')');
      { Read back the committed archive path/hash so the caller's
        verification pass can compare to the lockfile. Local-source
        deps have no archive; ArchiveHash stays ''. The frozen path
        does not do tag resolution — it trusts the committed
        modules tree + lockfile pairing. }
      if Item.Dep.SrcKind <> skLocal then
      begin
        { We can't reconstruct the archive name without the resolved
          ref; in frozen mode we look up the only matching file under
          the archives dir. }
        // For now: derive from lockfile during verification
        // (CmdInstall.VerifyAgainstLockfile does the hash compare).
      end;
    end
    else
    begin
      { Resolve the concrete ref before fetching. For vkNone (local
        sources), ResolveDepRef returns ''. Custom prefixes are looked
        up against the [sources] table from the manifest that declared
        this dependency. }
      R.Nodes[idx].Version := ResolveDepRef(Item.Dep,
        Item.CustomSources);
      WriteLn('  fetching ', Item.Dep.Name, ' @ ', R.Nodes[idx].Version,
              '  (required by ', Item.RequiredBy, ')');
      FetchToCache(Item.Dep, R.Nodes[idx].Version,
                   AModulesRoot, AArchivesRoot, ATmpRoot, AProjectRoot,
                   Item.CustomSources, AWorkspaces,
                   UnitDir, Archive, ArchiveHash, ResolvedURL);
      if (Archive <> '') and FileExists(Archive) then
      begin
        if (Length(Item.Dep.IncludeGlobs) > 0)
           or (Length(Item.Dep.ExcludeGlobs) > 0) then
          WriteLn('    filtering files via include/exclude globs');
        { Extract into a per-dep tmp dir, then atomic-move the whole
          extracted tree to .lwpt/modules/<dep>/. A crash mid-extract
          leaves the orphan in tmp (reaped by lwpt repair or the
          next install's startup pass), never a half-populated
          modules tree. include/exclude globs are applied AFTER
          extraction but BEFORE the atomic move so the modules dir
          only ever contains the filtered file set. }
        ExtractTmp := MakeTmpPath(ATmpRoot, 'extract-' + Item.Dep.Name);
        ForceDirectories(ExtractTmp);
        try
          ExtractArchive(Archive, ExtractTmp, '');
          ApplyIncludeExclude(ExtractTmp,
            Item.Dep.IncludeGlobs, Item.Dep.ExcludeGlobs);
          AtomicMoveDir(ExtractTmp, UnitDir);
        except
          { Leave the partial in tmp so it's inspectable + clean it
            up via repair / next install startup. Re-raise as
            EExtractError with context. }
          on E: Exception do
          begin
            WipeDir(ExtractTmp);
            raise EExtractError.CreateFmt(
              'extract failed for "%s" from %s: %s',
              [Item.Dep.Name, Archive, E.Message]);
          end;
        end;
      end;
    end;

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
        per-target context applies to dep-graph traversal). }
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

function RunInstallTransaction(const AContext: TManifestContext; const AMode: TInstallTransactionMode): TInstallTransactionResult;
var
  Man : TManifest;
  R   : TResolution;
  Resolved : array of TResolved;
  LockEntries : TResolvedArray;
  Lock : TInstallLock;
  ModulesRoot, ArchivesRoot, TmpRoot, CfgPath, LockPath, LockfilePath : string;
  i, j : Integer;
  Frozen : Boolean;
begin
  Man := AContext.Manifest;
  Frozen := AMode = itmFrozenVerify;

  ModulesRoot  := ResolveProjectPath(AContext.ProjectRoot, ResolveModulesDir(Man));
  ArchivesRoot := ResolveProjectPath(AContext.ProjectRoot, ResolveArchivesDir(Man));
  TmpRoot      := ResolveProjectPath(AContext.ProjectRoot, ResolveTmpDir(Man));
  CfgPath      := ResolveProjectPath(AContext.ProjectRoot, ResolveCfgFile(Man));
  LockPath     := ResolveProjectPath(AContext.ProjectRoot, INSTALL_LOCK);
  LockfilePath := ResolveProjectPath(AContext.ProjectRoot, LWPT.Core.LOCKFILE);

  Lock := TInstallLock.Create(LockPath);
  try
    if DirectoryExists(TmpRoot) then
      WipeDir(TmpRoot);

    R := Default(TResolution);
    WriteLn('resolving dependency graph (', Length(Man.Deps), ' direct)...');
    ResolveGraph(Man, R, ModulesRoot, ArchivesRoot, TmpRoot,
                 AContext.ProjectRoot, Man.Workspaces, Frozen);

    for i := 0 to High(R.Nodes) do
      CheckNodeConstraints(R.Nodes[i]);
    WriteLn('resolved ', Length(R.Nodes), ' packages, no conflicts.');

    SetLength(Resolved, Length(R.Nodes));
    for i := 0 to High(R.Nodes) do
    begin
      Resolved[i] := Default(TResolved);
      Resolved[i].Name        := R.Nodes[i].Name;
      Resolved[i].Version     := R.Nodes[i].Version;
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
        if Resolved[i].SrcKind = skLocal then Continue;
        FillFrozenArchiveHash(Resolved[i], LockEntries, ArchivesRoot);
      end;
      VerifyAgainstLockfile(Resolved, LockEntries);
      WriteLn('[frozen] ', Length(Resolved),
              ' packages verified against ', LWPT.Core.LOCKFILE,
              ' (archive + tree hashes both match).');
      Result.PackageCount := Length(Resolved);
      Result.LockfilePath := LockfilePath;
      Result.CfgPath := CfgPath;
      Exit;
    end;

    WriteLock(LockfilePath, TmpRoot, Resolved);
    WriteCfg(CfgPath, TmpRoot, Resolved, Man, AContext.ProjectRoot);
    WriteLn('wrote ', LWPT.Core.LOCKFILE, ' (', Length(Resolved),
            ' packages) and ', CfgPath);
    Result.PackageCount := Length(Resolved);
    Result.LockfilePath := LockfilePath;
    Result.CfgPath := CfgPath;
  finally
    Lock.Free;
  end;
end;

end.
