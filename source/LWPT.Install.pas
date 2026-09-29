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
    RefKind      : string;       { RefKindTag / RefKindBranch for a named
                                   ref; '' for SHA pins and non-Git sources }
    ReachableFrom: string;       { ref that proved a commit-SHA pin
                                   reachable (ADR-0047); '' otherwise }
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
    { skRegistry only (ADR-0051): the origin identity and the sha256 of the
      selected signed record. }
    RegistryOrigin : string;
    RegistryRecord : string;
  end;
  TResolvedArray = array of TResolved;

  TInstallTransactionMode = (
    itmMaterialize,
    itmFrozenVerify,
    itmOfflineMaterialize
  );

  TInstallTransactionResult = record
    PackageCount : Integer;
    LockfilePath : string;
    CfgPath      : string;
    Resolved     : TResolvedArray;  { the materialized/verified graph }
  end;

  { A single package node in the resolver's constraint graph. Exposed —
    with ConstraintFingerprintForNode below — so the fingerprint regression
    test can pin the node-level fold (line shapes, source-line position, and
    the ordinal sort) directly, on every platform including the Windows
    `lwpt test` leg. Only the fingerprint-relevant fields are populated by
    that test; the resolver fills the rest during a real install. }
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
    RefKind     : string;            { RefKindTag / RefKindBranch or '' }
    ReachableFrom: string;           { proving ref of a SHA pin or '' }
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
    RegistryOrigin : string;         { skRegistry: origin identity }
    RegistryRecord : string;         { skRegistry: selected record hash }
  end;

{$IFDEF INSTALL_TESTING}
const
  { Test-only archive-fetch redirection. ARCHIVE_FETCH_ORIGIN_ENV is read
    at the archive-fetch boundary AFTER canonical URL construction, so the
    manifest, the host templates in FetchURL, and the resolved path are all
    exercised exactly as in production; only the origin is swapped. Absent
    or empty, the canonical URL is used byte for byte.

    The accepted value is a bare `http://<numeric IPv4 loopback>:<port>`
    origin. On Windows only, the non-routable limited-broadcast address is
    also accepted as a preflighted immediate-failure fallback. Everything
    else is refused: a remote host, a name that would need DNS (including
    `localhost`), a missing port, a path, user information, and any non-http
    scheme. That keeps the seam unable to express an arbitrary insecure
    download even in a test build. Per ADR-0044 the seam exists only in
    test builds (INSTALL_TESTING); a release binary compiles none of it and
    ignores the variable.

    ARCHIVE_FETCH_TIMEOUT_ENV bounds the loopback archive request and is honoured
    only while the origin override is active, so it cannot become a
    production knob by itself. }
  ARCHIVE_FETCH_ORIGIN_ENV  = PROJECT_NAME + '_TEST_ARCHIVE_ORIGIN';
  ARCHIVE_FETCH_TIMEOUT_ENV = PROJECT_NAME + '_TEST_ARCHIVE_TIMEOUT_MS';
  DEFAULT_ARCHIVE_FETCH_TIMEOUT = 5000;
  MAXIMUM_ARCHIVE_FETCH_TIMEOUT = 600000;
{$ENDIF}

const
  { Kind of the named ref a Git-host dependency was selected from, recorded
    as `resolvedRefKind` in lwpt.lock (ADR-0048). }
  RefKindTag    = 'tag';
  RefKindBranch = 'branch';

  { The terminator written after every constraint line before hashing —
    including the last, reproducing TStrings.Text's trailing line break.
    Named and pinned because the fingerprint is compared across machines:
    see ConstraintFingerprintForLines. It is a per-line terminator, not a
    between-lines join; dropping the final one changes every existing
    fingerprint and invalidates every committed lockfile. }
  CONSTRAINT_FINGERPRINT_SEPARATOR = #10;

function  LoadLockfile(const APath: string): TResolvedArray;
function  ConstraintFingerprintForLines(const ALines: TStrings): string;
function  ConstraintFingerprintForNode(const ANode: TResolveNode; const AProjectRoot: string): string;
{$IFDEF INSTALL_TESTING}
function  ApplyArchiveFetchOrigin(const ACanonicalURL, AOverride: string): string;
function  ResolveArchiveFetchTimeout(const ARawMilliseconds: string): Integer;
{$ENDIF}
function  ExtractArchive(const AArchivePath, ADest: string; const ASubDir: string = ''): Integer;
procedure VerifyAgainstLockfile(const AResolved: array of TResolved; const ALockEntries: array of TResolved);
function  PruneOrphanedPackages(const AOldLock, ANewLock: array of TResolved; const AModulesRoot, AArchivesRoot: string): Integer;
function  RunInstallTransaction(const AContext: TManifestContext; const AMode: TInstallTransactionMode; const AAcceptMovedTags: Boolean = False): TInstallTransactionResult;
function  RunManifestMutationTransaction(const AContext: TManifestContext; const AManifestLines: TStringList): TInstallTransactionResult;
procedure RecoverInterruptedInstall(const AContext: TManifestContext);

implementation

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  HTTPClient,
  LWPT.FetchPolicy,
  LWPT.GitPack,
  LWPT.GitProtocol,
  LWPT.Gzip,
  LWPT.ObjectStore,
  LWPT.ProducerLease,
  LWPT.Registry.Consumer,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  LWPT.Resolver,
  Semver,
  TOML;

const
  MAX_ARCHIVE_RESPONSE_BYTES = Int64(256) * 1024 * 1024;
  ARCHIVE_REQUEST_TIMEOUT_MILLISECONDS = 5 * 60 * 1000;

{$IFDEF INSTALL_TESTING}
{ Test-only crash injection. A real crash runs no unit finalization, and
  Halt does: finalizing the RTL while a producer-lease heartbeat thread is
  still writing state crashed the child with an access violation instead
  of the expected exit code. End the process at once, as a crash would. }
procedure TerminateAbruptlyForTesting(const AExitCode: Integer);
begin
  {$IFDEF MSWINDOWS}
  Windows.TerminateProcess(Windows.GetCurrentProcess, UINT(AExitCode));
  {$ENDIF}
  {$IFDEF UNIX}
  FpExit(AExitCode);
  {$ENDIF}
end;
{$ENDIF}

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
          Result := BuiltInForgeOrigin(hkGitHub) + ADep.SrcLocator +
                    '/archive/' + AResolvedRef + '.tar.gz';
        hkGitLab:
          Result := BuiltInForgeOrigin(hkGitLab) + ADep.SrcLocator +
                    '/-/archive/' + AResolvedRef + '/'
                    + Repo + '-' + AResolvedRef + '.tar.gz';
        hkBitbucket:
          Result := BuiltInForgeOrigin(hkBitbucket) + ADep.SrcLocator +
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

{$IFDEF INSTALL_TESTING}
{ ───────────────────────────────────────────────────────────────────
  Test-only archive-fetch redirection. See the ARCHIVE_FETCH_*
  declarations in the interface for the contract this enforces.

  Deliberately NOT a proxy, a mirror, or an origin-selection feature:
  it rewrites nothing but the origin, refuses every value that is not a
  numeric loopback plain-HTTP endpoint, and is inert when unset.
  Compiled only into test builds (ADR-0044).
  ─────────────────────────────────────────────────────────────────── }
const
  LOOPBACK_FIRST_OCTET = 127;
  IPV4_GROUP_COUNT     = 4;
  MAXIMUM_PORT_NUMBER  = 65535;

{ Split "<scheme>://<authority><path>" into its three parts. The path
  keeps its leading '/' and is '' when the URL carries none. }
function SplitURLParts(const AURL: string;
  out AScheme, AAuthority, APath: string): Boolean;
var
  SchemeEnd, PathStart: Integer;
begin
  AScheme := '';
  AAuthority := '';
  APath := '';
  SchemeEnd := Pos('://', AURL);
  Result := SchemeEnd > 1;
  if not Result then Exit;
  AScheme := LowerCase(Copy(AURL, 1, SchemeEnd - 1));
  AAuthority := Copy(AURL, SchemeEnd + 3, MaxInt);
  PathStart := Pos('/', AAuthority);
  if PathStart > 0 then
  begin
    APath := Copy(AAuthority, PathStart, MaxInt);
    AAuthority := Copy(AAuthority, 1, PathStart - 1);
  end;
end;

{ Dotted-quad check with the loopback range baked in. Names are refused
  on purpose: resolving one would need DNS, and "localhost" is exactly
  the value that could silently point somewhere else on a given host. }
function IsNumericLoopbackAddress(const AHost: string): Boolean;
var
  Groups, Value, DigitCount, i: Integer;
  Current: Char;
begin
  Result := False;
  Groups := 0;
  Value := 0;
  DigitCount := 0;
  for i := 1 to Length(AHost) + 1 do
  begin
    if i <= Length(AHost) then Current := AHost[i] else Current := '.';
    if Current = '.' then
    begin
      if (DigitCount = 0) or (DigitCount > 3) or (Value > 255) then Exit;
      Inc(Groups);
      if (Groups = 1) and (Value <> LOOPBACK_FIRST_OCTET) then Exit;
      Value := 0;
      DigitCount := 0;
    end
    else if Current in ['0'..'9'] then
    begin
      Value := Value * 10 + (Ord(Current) - Ord('0'));
      Inc(DigitCount);
    end
    else
      Exit;
  end;
  Result := Groups = IPV4_GROUP_COUNT;
end;

{ Digits only, because StrToIntDef would otherwise accept '$7f' and '+80'. }
function ParseWholeNumber(const AText: string; out AValue: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  AValue := 0;
  if (AText = '') or (Length(AText) > 9) then Exit;
  for i := 1 to Length(AText) do
  begin
    if not (AText[i] in ['0'..'9']) then Exit;
    AValue := AValue * 10 + (Ord(AText[i]) - Ord('0'));
  end;
  Result := True;
end;

procedure RejectArchiveFetchOrigin(const AOverride, AReason: string);
begin
  raise EFetchError.CreateFmt(
    '%s is a test-only archive-fetch override and was refused: %s (got "%s")',
    [ARCHIVE_FETCH_ORIGIN_ENV, AReason, AOverride]);
end;

procedure ValidateArchiveFetchOrigin(const AOverride: string);
var
  Scheme, Authority, Path, Host, PortText: string;
  ColonAt, Port: Integer;
begin
  if not SplitURLParts(AOverride, Scheme, Authority, Path) then
    RejectArchiveFetchOrigin(AOverride,
      'it is not a <scheme>://<host>:<port> origin');
  if Scheme <> 'http' then
    RejectArchiveFetchOrigin(AOverride,
      'only the http scheme is accepted');
  if (Path <> '') and (Path <> '/') then
    RejectArchiveFetchOrigin(AOverride,
      'it must be a bare origin carrying no path');
  if Pos('@', Authority) > 0 then
    RejectArchiveFetchOrigin(AOverride,
      'user information is not accepted');
  ColonAt := Pos(':', Authority);
  if ColonAt = 0 then
    RejectArchiveFetchOrigin(AOverride,
      'an explicit port is required');
  Host := Copy(Authority, 1, ColonAt - 1);
  PortText := Copy(Authority, ColonAt + 1, MaxInt);
  {$IFDEF MSWINDOWS}
  if (Host <> '255.255.255.255') and not IsNumericLoopbackAddress(Host) then
  {$ELSE}
  if not IsNumericLoopbackAddress(Host) then
  {$ENDIF}
    RejectArchiveFetchOrigin(AOverride,
      'the host must be a numeric IPv4 loopback address inside 127.0.0.0/8'
      {$IFDEF MSWINDOWS} + ' or the Windows limited-broadcast test target'
      {$ENDIF});
  if (not ParseWholeNumber(PortText, Port))
     or (Port < 1) or (Port > MAXIMUM_PORT_NUMBER) then
    RejectArchiveFetchOrigin(AOverride, Format(
      'the port must be a number between 1 and %d', [MAXIMUM_PORT_NUMBER]));
end;

function ApplyArchiveFetchOrigin(const ACanonicalURL,
  AOverride: string): string;
var
  Scheme, Authority, Path, Origin: string;
begin
  { The whole production contract is this early exit: with no override
    the canonical URL is returned byte for byte. }
  if AOverride = '' then Exit(ACanonicalURL);

  ValidateArchiveFetchOrigin(AOverride);

  { Fail closed. A canonical URL we cannot split is a bug upstream of
    here, and returning it unchanged would let a fixture reach the real
    network instead of the loopback server it asked for. }
  if not SplitURLParts(ACanonicalURL, Scheme, Authority, Path) then
    raise EFetchError.CreateFmt(
      '%s is set but the canonical archive URL "%s" carries no scheme to '
      + 'redirect', [ARCHIVE_FETCH_ORIGIN_ENV, ACanonicalURL]);

  Origin := AOverride;
  if (Origin <> '') and (Origin[Length(Origin)] = '/') then
    Origin := Copy(Origin, 1, Length(Origin) - 1);
  if Path = '' then Path := '/';
  Result := Origin + Path;
end;

function ResolveArchiveFetchTimeout(const ARawMilliseconds: string): Integer;
begin
  if ARawMilliseconds = '' then Exit(DEFAULT_ARCHIVE_FETCH_TIMEOUT);
  if (not ParseWholeNumber(ARawMilliseconds, Result))
     or (Result < 1) or (Result > MAXIMUM_ARCHIVE_FETCH_TIMEOUT) then
    raise EFetchError.CreateFmt(
      '%s must be a whole number of milliseconds between 1 and %d (got "%s")',
      [ARCHIVE_FETCH_TIMEOUT_ENV, MAXIMUM_ARCHIVE_FETCH_TIMEOUT,
       ARawMilliseconds]);
end;
{$ENDIF}

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
    hkGitHub, hkGitLab, hkBitbucket:
      Result := BuiltInForgeOrigin(ADep.SrcHost) + ADep.SrcLocator + '.git';
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
    vkCommitSha   → returned verbatim once proven reachable from an
                    advertised branch or tag (ADR-0047).
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

{$IFDEF INSTALL_TESTING}
{ Test-build-only archive fixture (ADR-0044), paired with the ref fixture in
  LWPT.GitProtocol: <root>/archives/<name>/<ref>.tar.gz stands in for the
  git-host archive endpoint. }
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
{$ENDIF}

{ A locked identity must reproduce its locked bytes (ADR-0048). AExpected is
  '' when the selection is not a locked identity. Every path that supplies
  archive bytes for a dependency -- a fresh download or a resolver candidate
  another dependency already fetched -- calls this before using them. }
procedure EnsureLockedArchiveIdentity(const ADependency, AContext,
  AExpected, AActual, ARecovery: string); overload;
begin
  if (AExpected <> '') and not SameText(AActual, AExpected) then
    raise EVerifyError.CreateFmt(
      'dependency "%s": %s (locked archive %s, received %s). Nothing was '
      + 'published. %s',
      [ADependency, AContext, AExpected, AActual, ARecovery]);
end;

{ The online form: the recovery is a reviewed `--accept-moved-tags`. }
procedure EnsureLockedArchiveIdentity(const ADependency, AContext,
  AExpected, AActual: string); overload;
begin
  EnsureLockedArchiveIdentity(ADependency, AContext, AExpected, AActual,
    'Review the upstream change, then run `' + PROGRAM_NAME + ' install '
    + '--accept-moved-tags` to accept it.');
end;

{ AVerifyArchiveHash, when set, is the locked content identity the downloaded
  bytes must reproduce (ADR-0048); a mismatch raises EVerifyError naming
  AVerifyContext before the bytes are written, cached, or extracted. }
function FetchToCache(const ADep: TDependency;
  const AResolvedRef, AModulesRoot, AArchivesRoot, ATmpRoot,
    AProjectRoot, AExpectedArchiveHash: string;
  const ACustomSources: TCustomSourceArray;
  const AWorkspaces: TWorkspaceArray;
  const AObjectStore: TLWPTImmutableObjectStore;
  const AVerifyArchiveHash, AVerifyContext: string;
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
  StagePath : string;
  ProducerLease: TLWPTProducerLease;
  {$IFDEF INSTALL_TESTING}
  OriginOverride, FixtureRoot : string;
  {$ENDIF}

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

  function WaitForSharedArchive: Boolean;
  var
    Coordinator: TLWPTProducerLeaseCoordinator;
    Snapshot: TLWPTProducerLeaseSnapshot;
    LastProgressAt, WaitNow, WaitStartedAt: QWord;
  begin
    Result := False;
    if (AObjectStore = nil) or (AExpectedArchiveHash = '') then Exit;
    Coordinator := TLWPTProducerLeaseCoordinator.Create(
      ProducerLeaseRoot(ExtractFileDir(AObjectStore.Root)));
    try
      ProducerLease := Coordinator.TryAcquire(
        'dependency:' + LowerCase(AExpectedArchiveHash),
        'dependency archive "' + ADep.Name + '" '
          + LowerCase(AExpectedArchiveHash));
      if not Assigned(ProducerLease) then
      begin
        WaitStartedAt := GetTickCount64;
        LastProgressAt := WaitStartedAt;
        WriteLn('  waiting for dependency archive ', ADep.Name, ' ',
          LowerCase(AExpectedArchiveHash));
        repeat
          Sleep(PRODUCER_LEASE_POLL_MILLISECONDS);
          if AObjectStore.Materialize(AExpectedArchiveHash,
               AArchive, ATmpRoot) then
          begin
            AArchiveHash := AExpectedArchiveHash;
            WriteLn('  reused verified archive for ', ADep.Name,
              ' after waiting for its producer');
            Exit(True);
          end;
          ProducerLease := Coordinator.TryAcquire(
            'dependency:' + LowerCase(AExpectedArchiveHash),
            'dependency archive "' + ADep.Name + '" '
              + LowerCase(AExpectedArchiveHash));
          if Assigned(ProducerLease) then Break;
          WaitNow := GetTickCount64;
          if WaitNow - LastProgressAt >=
             PRODUCER_LEASE_PROGRESS_MILLISECONDS then
          begin
            if Coordinator.Snapshot(
                 'dependency:' + LowerCase(AExpectedArchiveHash),
                 Snapshot) then
              WriteLn('  waiting for ', Snapshot.Description,
                ' (owner ', Snapshot.ProcessId, ', ',
                WaitNow - WaitStartedAt, 'ms)')
            else
              WriteLn('  waiting for dependency archive ', ADep.Name,
                ' (', WaitNow - WaitStartedAt, 'ms)');
            LastProgressAt := WaitNow;
          end;
        until False;
      end;

      { A producer can publish immediately before releasing the guard.
        Revalidate the desired content hash after takeover. }
      if AObjectStore.Materialize(AExpectedArchiveHash,
           AArchive, ATmpRoot) then
      begin
        AArchiveHash := AExpectedArchiveHash;
        FreeAndNil(ProducerLease);
        WriteLn('  reused verified archive for ', ADep.Name,
          ' after producer handoff');
        Exit(True);
      end;
    finally
      Coordinator.Free;
    end;
  end;
begin
  Result := False;
  ProducerLease := nil;
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
      AExpectedArchiveHash,
      ACustomSources, AWorkspaces,
      AObjectStore, AVerifyArchiveHash, AVerifyContext,
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

  { Project archives keep their existing human/provenance name. The shared
    store is addressed only by the expected raw-content digest from an
    authoritative prior lock entry. }
  AArchive := ArchivePathForRef(AArchivesRoot, ADep.Name, ADep.SrcKind,
    AResolvedRef);
  AResolvedURL := URL;
  if (AObjectStore <> nil) and (AExpectedArchiveHash <> '') then
    try
      if AObjectStore.Materialize(AExpectedArchiveHash, AArchive,
           ATmpRoot) then
      begin
        AArchiveHash := AExpectedArchiveHash;
        WriteLn('  reused verified archive for ', ADep.Name,
          ' from the per-user cache');
        Exit(True);
      end;
    except
      on E: Exception do
        WriteLn(ErrOutput, 'warning: dependency archive cache lookup for ',
          ADep.Name, ' failed: ', E.Message, '; fetching from source');
    end;

  try
    if WaitForSharedArchive then Exit(True);
  except
    on E: Exception do
    begin
      FreeAndNil(ProducerLease);
      WriteLn(ErrOutput, 'warning: dependency archive producer lease for ',
        ADep.Name, ' failed: ', E.Message, '; fetching from source');
    end;
  end;

  { Test-only crash injection after this process has become the producer but
    before it can touch the origin or publish bytes. Abrupt termination skips
    all cleanup so the cross-process integration test observes the same
    operating-system guard release as a producer death. }
  {$IFDEF INSTALL_TESTING}
  if Assigned(ProducerLease)
     and (TestSeamValue('CRASH_DEPENDENCY_PRODUCER') = '1') then
    TerminateAbruptlyForTesting(88);
  {$ENDIF}

  try
  {$IFDEF INSTALL_TESTING}
  { The archive-fetch boundary, and the only place the test-only origin
    override applies: canonical construction above is untouched, and the
    redirect below is inert unless the environment asks for it.
    Record the canonical URL in the lockfile, captured before the redirect.
    The override only aims the fetch at a loopback mock server; the
    loopback origin must never persist into lwpt.lock, so AResolvedURL
    keeps the URL as constructed while URL below carries the rewrite. }
  OriginOverride := SysUtils.GetEnvironmentVariable(ARCHIVE_FETCH_ORIGIN_ENV);
  FixtureRoot := SysUtils.GetEnvironmentVariable(
    PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR');
  { The ref fixture and archive-origin seams compose deliberately. A fixture
    root alone remains a completely file-backed git-host fixture; an explicit
    loopback archive origin keeps ref discovery deterministic while driving
    the real archive transport boundary. }
  if (FixtureRoot <> '') and (OriginOverride = '')
     and (ADep.SrcKind = skGitHost) then
  begin
    Resp := Default(THTTPResponse);
    LoadTestFixtureArchive(FixtureRoot, ADep.Name, AResolvedRef,
      Resp.Body);
    Resp.StatusCode := 200;
  end
  else
  {$ENDIF}
  begin
    NoHeaders := nil;
    { The dependency's destination policy (host allowlist and private-address
      refusal) is enforced on the request and every redirect hop. }
    HTTPOptions := DependencyFetchOptions(ADep, ACustomSources,
      DefaultHTTPRequestOptions);
    HTTPOptions.MaxResponseBodyBytes := MAX_ARCHIVE_RESPONSE_BYTES;
    HTTPOptions.RequestTimeoutMilliseconds :=
      ARCHIVE_REQUEST_TIMEOUT_MILLISECONDS;
    {$IFDEF INSTALL_TESTING}
    URL := ApplyArchiveFetchOrigin(URL, OriginOverride);
    if OriginOverride <> '' then
    begin
      HTTPOptions.RequestTimeoutMilliseconds := ResolveArchiveFetchTimeout(
        SysUtils.GetEnvironmentVariable(ARCHIVE_FETCH_TIMEOUT_ENV));
      { A loopback fixture must not escape through a remote Location header,
        and the validated loopback origin replaces the source's hosts. }
      HTTPOptions.MaximumRedirects := 0;
      HTTPOptions.Destination := Default(THTTPDestinationPolicy);
    end;
    {$ENDIF}
    { Every transport failure below the client (refused connection, read
      timeout, truncated body, malformed response) arrives here as some
      HTTPClient-shaped exception whose text names neither the dependency
      nor what was being attempted. Normalising to EFetchError gives the
      caller one exception type and one message shape to rely on. The
      underlying text is appended rather than replaced so the narrow
      connect/DNS detection the e2e suites use still matches. }
    try
      Resp := HTTPGet(URL, NoHeaders, HTTPOptions);
    except
      on E: EFetchError do
        raise;
      on E: Exception do
        raise EFetchError.CreateFmt(
          'dependency "%s": archive fetch from %s failed: %s',
          [ADep.Name, URL, E.Message]);
    end;
    if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
      raise EFetchError.CreateFmt(
        'dependency "%s": archive fetch from %s failed: HTTP %d %s',
        [ADep.Name, URL, Resp.StatusCode, Resp.StatusText]);
  end;

  { Archive filename uses an escaped resolved ref for git-host sources,
    or the stable "url" tag for direct archive URLs. }
  AArchiveHash := SHA256BytesPrefixed(Resp.Body);
  { Checked before the archive is written, admitted to the shared cache, or
    extracted, so a mismatch leaves no trace in the project or the cache. }
  EnsureLockedArchiveIdentity(ADep.Name, AVerifyContext, AVerifyArchiveHash,
    AArchiveHash);
  AtomicWriteBytes(AArchive, ATmpRoot, Resp.Body);
  if AObjectStore <> nil then
    try
      AObjectStore.Admit(AArchive, AArchiveHash);
    except
      on E: Exception do
        WriteLn(ErrOutput, 'warning: dependency archive cache admission for ',
          ADep.Name, ' failed: ', E.Message,
          '; the project archive remains authoritative');
    end;
    Result := True;
  finally
    ProducerLease.Free;
  end;
end;

{ ===========================================================================
  Archive extraction — gunzip (LWPT.Gzip) then untar.
  GitHub serves .tar.gz; the tar reader reads plain tar, so this is a two-step:
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
  Archive extraction — gunzip (LWPT.Gzip) then a direct ustar/POSIX tar reader.

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

{ Opens the archive through the protected stream helper rather than
  TGZFileStream, whose paszlib gzopen truncates paths over 255 characters
  (issue #309). A partial tar is removed when decoding fails. }
procedure GunzipArchive(const AArchivePath, ATarPath: string);
var
  ArchiveIn, TarOut: TStream;
begin
  ArchiveIn := OpenProtectedFileStream(AArchivePath,
    fmOpenRead or fmShareDenyNone);
  try
    TarOut := OpenProtectedFileStream(ATarPath, fmCreate);
    try
      GunzipStream(ArchiveIn, TarOut);
    except
      TarOut.Free;
      SysUtils.DeleteFile(ATarPath);
      raise;
    end;
    TarOut.Free;
  finally
    ArchiveIn.Free;
  end;
end;

type
  { One tar entry header, with any GNU long name or ustar prefix folded in
    and the name re-rooted below the extraction root. RelName is '' for an
    entry that is not extracted; its payload must still be skipped. }
  TLWPTTarEntry = record
    TypeFlag: Byte;
    Size: Int64;
    Pad: Integer;
    LinkName, RelName: string;
  end;

{ Reads the next entry header from ATar, leaving the stream at the entry's
  payload. False at the end of the archive. }
function ReadTarEntry(const ATar: TStream; const ASubDir: string;
  out AEntry: TLWPTTarEntry): Boolean;
var
  Hdr: array[0..511] of Byte;
  Name, Prefix, PendingLongName: string;
  ZeroBlocks, Pad, i: Integer;
  AllZero: Boolean;
begin
  AEntry := Default(TLWPTTarEntry);
  PendingLongName := '';
  ZeroBlocks := 0;
  while ATar.Read(Hdr, 512) = 512 do
  begin
    { two consecutive all-zero blocks mark end of archive }
    AllZero := True;
    for i := 0 to 511 do
      if Hdr[i] <> 0 then begin AllZero := False; Break; end;
    if AllZero then
    begin
      Inc(ZeroBlocks);
      if ZeroBlocks >= 2 then Exit(False);
      Continue;
    end;
    ZeroBlocks := 0;

    Name            := TarStr(Hdr, 0, 100);
    AEntry.Size     := TarOctal(Hdr, 124, 12);
    AEntry.TypeFlag := Hdr[156];
    AEntry.LinkName := TarStr(Hdr, 157, 100);
    Prefix          := TarStr(Hdr, 345, 155);

    { GNU long-name ('L') / long-link ('K'): body holds the real name }
    if (AEntry.TypeFlag = Ord('L')) or (AEntry.TypeFlag = Ord('K')) then
    begin
      SetLength(PendingLongName, AEntry.Size);
      if AEntry.Size > 0 then
        ATar.ReadBuffer(PendingLongName[1], AEntry.Size);
      PendingLongName := Trim(StringReplace(PendingLongName, #0, '',
                           [rfReplaceAll]));
      Pad := (512 - (AEntry.Size mod 512)) mod 512;
      if Pad > 0 then ATar.Seek(Pad, soCurrent);
      Continue;   { real entry follows }
    end;

    { full path = prefix + '/' + name, unless a pending GNU long name }
    if PendingLongName <> '' then
      Name := PendingLongName
    else if Prefix <> '' then
      Name := Prefix + '/' + Name;

    AEntry.RelName := StripFirstComponent(Name);
    { if a subsection was requested, keep only entries inside it }
    if ASubDir <> '' then
      AEntry.RelName := ReRootToSubDir(AEntry.RelName, ASubDir);
    AEntry.Pad := Integer((512 - (AEntry.Size mod 512)) mod 512);
    Exit(True);
  end;
  Result := False;
end;

const
  {$IFDEF MSWINDOWS}
  { LWPT is not long-path aware, so the Win32 file APIs keep the legacy
    MAX_PATH budget: 259 characters for a file, and 247 for a directory,
    whose creation reserves room for an 8.3 file name. }
  ArchiveFilePathLimit = MAX_PATH - 1;
  ArchiveDirectoryPathLimit = MAX_PATH - 13;
  {$ELSE}
  { PATH_MAX, which counts the terminating NUL. }
  ArchiveFilePathLimit = MaxPathLen - 1;
  ArchiveDirectoryPathLimit = MaxPathLen - 1;
  {$ENDIF}
  { NAME_MAX on Unix; the per-component limit on Windows. }
  ArchiveNameComponentLimit = 255;

function PlatformPathLength(const APath: string): Integer;
begin
  {$IFDEF MSWINDOWS}
  { Win32 limits count UTF-16 code units. }
  Result := Length(UnicodeString(APath));
  {$ELSE}
  Result := Length(APath);
  {$ENDIF}
end;

{ Raises when writing APath would exceed the platform's path limit. The
  operating system would otherwise fail part-way through extraction with an
  error such as "No such file or directory" that does not name the cause. }
procedure EnsureArchivePathFits(const APath, AEntryName, ADest: string;
  const AIsDirectory: Boolean);
var
  PathLength, ParentLength, Limit, Excess: Integer;
  Kind: string;
begin
  PathLength := PlatformPathLength(ExcludeTrailingPathDelimiter(APath));
  if AIsDirectory then
  begin
    Kind := 'directory';
    Limit := ArchiveDirectoryPathLimit;
    Excess := PathLength - Limit;
  end
  else
  begin
    Kind := 'file';
    Limit := ArchiveFilePathLimit;
    Excess := PathLength - Limit;
    { A file also needs its parent directory created, and on Windows the
      directory budget is the tighter one. }
    ParentLength := PlatformPathLength(
      ExtractFileDir(ExcludeTrailingPathDelimiter(APath)));
    if ParentLength - ArchiveDirectoryPathLimit > Excess then
    begin
      Kind := 'directory';
      PathLength := ParentLength;
      Limit := ArchiveDirectoryPathLimit;
      Excess := PathLength - Limit;
    end;
  end;
  if Excess <= 0 then Exit;
  raise EExtractError.CreateFmt(
    'archive path is too long: entry "%s" needs a %d-character %s path '
    + 'below "%s", but this platform limits %s paths to %d characters; '
    + 'move the project to a path at least %d characters shorter',
    [AEntryName, PathLength, Kind, ADest, Kind, Limit, Excess]);
end;

{ Raises when a component of an entry's relative name is longer than any
  file system accepts. Moving the project cannot fix this. }
procedure EnsureArchiveNameComponentsFit(const AEntryName: string);
var
  Parts: TStringArray;
  i: Integer;
begin
  Parts := StringReplace(AEntryName, '\', '/', [rfReplaceAll]).Split(['/']);
  for i := 0 to High(Parts) do
    if PlatformPathLength(Parts[i]) > ArchiveNameComponentLimit then
      raise EExtractError.CreateFmt(
        'archive entry name is too long: "%s" has a %d-character name '
        + 'component, but this platform limits file names to %d characters; '
        + 'the entry cannot be extracted here',
        [AEntryName, PlatformPathLength(Parts[i]),
         ArchiveNameComponentLimit]);
end;

type
  { The destinations extraction will create, as absolute paths, so that
    directory-link copies can be checked before anything is written. }
  TLWPTArchivePlan = class
  private
    FDest: string;
    FFiles, FDirectories: TStringList;
    procedure AddDirectoryChain(const APath: string);
    procedure CheckAndAdd(const APath, AEntryName: string;
      const AIsDirectory: Boolean);
  public
    constructor Create(const ADest: string);
    destructor Destroy; override;
    procedure AddEntry(const APath, AEntryName: string;
      const AIsDirectory: Boolean);
    procedure AddLink(const ALinkPath, ATargetName, AFromRel: string);
  end;

const
  { Windows file systems resolve names case-insensitively, so the deferred
    link pass finds a target however the link spells it. }
  {$IFDEF MSWINDOWS}
  ArchivePathsCaseSensitive = False;
  {$ELSE}
  ArchivePathsCaseSensitive = True;
  {$ENDIF}

function NewPathList: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Result.CaseSensitive := ArchivePathsCaseSensitive;
end;

function ArchivePathHasPrefix(const APath, APrefix: string): Boolean;
begin
  if ArchivePathsCaseSensitive then
    Result := Copy(APath, 1, Length(APrefix)) = APrefix
  else
    Result := SameText(Copy(APath, 1, Length(APrefix)), APrefix);
end;

constructor TLWPTArchivePlan.Create(const ADest: string);
begin
  inherited Create;
  FDest := ExcludeTrailingPathDelimiter(ExpandFileName(ADest));
  FFiles := NewPathList;
  FDirectories := NewPathList;
end;

destructor TLWPTArchivePlan.Destroy;
begin
  FFiles.Free;
  FDirectories.Free;
  inherited Destroy;
end;

procedure TLWPTArchivePlan.AddDirectoryChain(const APath: string);
var
  Dir: string;
begin
  Dir := ExcludeTrailingPathDelimiter(APath);
  while (Length(Dir) > Length(FDest)) and (FDirectories.IndexOf(Dir) < 0) do
  begin
    FDirectories.Add(Dir);
    Dir := ExtractFileDir(Dir);
  end;
end;

procedure TLWPTArchivePlan.CheckAndAdd(const APath, AEntryName: string;
  const AIsDirectory: Boolean);
begin
  EnsureArchivePathFits(APath, AEntryName, FDest, AIsDirectory);
  if AIsDirectory then
    AddDirectoryChain(APath)
  else
  begin
    AddDirectoryChain(ExtractFileDir(APath));
    FFiles.Add(APath);
  end;
end;

procedure TLWPTArchivePlan.AddEntry(const APath, AEntryName: string;
  const AIsDirectory: Boolean);
begin
  EnsureArchiveNameComponentsFit(AEntryName);
  CheckAndAdd(ExcludeTrailingPathDelimiter(APath), AEntryName, AIsDirectory);
end;

{ Mirrors the deferred link pass: a file link becomes a copy of its target,
  and a directory link becomes a copy of the target's tree as it stands
  after the links resolved before it. }
procedure TLWPTArchivePlan.AddLink(const ALinkPath, ATargetName,
  AFromRel: string);
var
  Target, LinkPath, Prefix: string;
  Copies: TStringList;
  i: Integer;
begin
  EnsureArchiveNameComponentsFit(AFromRel);
  LinkPath := ExcludeTrailingPathDelimiter(ALinkPath);
  EnsureArchivePathFits(LinkPath, AFromRel, FDest, False);
  Target := ExcludeTrailingPathDelimiter(
    ResolveArchiveLinkTarget(FDest, LinkPath, ATargetName, AFromRel));
  if FFiles.IndexOf(Target) >= 0 then
  begin
    CheckAndAdd(LinkPath, AFromRel, False);
    Exit;
  end;
  if (FDirectories.IndexOf(Target) < 0)
     or PathContains(Target, LinkPath) then
    Exit;
  Prefix := IncludeTrailingPathDelimiter(Target);
  Copies := TStringList.Create;
  try
    { Collected first: CheckAndAdd grows the lists being scanned. }
    for i := 0 to FDirectories.Count - 1 do
      if ArchivePathHasPrefix(FDirectories[i], Prefix) then
        Copies.AddObject(LinkPath + PathDelim
          + Copy(FDirectories[i], Length(Prefix) + 1, MaxInt), TObject(1));
    for i := 0 to FFiles.Count - 1 do
      if ArchivePathHasPrefix(FFiles[i], Prefix) then
        Copies.AddObject(LinkPath + PathDelim
          + Copy(FFiles[i], Length(Prefix) + 1, MaxInt), nil);
    { The deferred pass deletes a file at the link path before copying the
      tree there, so later links must see a directory. }
    i := FFiles.IndexOf(LinkPath);
    if i >= 0 then FFiles.Delete(i);
    CheckAndAdd(LinkPath, AFromRel, True);
    for i := 0 to Copies.Count - 1 do
      CheckAndAdd(Copies[i], AFromRel, Copies.Objects[i] <> nil);
  finally
    Copies.Free;
  end;
end;

function ExtractArchive(const AArchivePath, ADest: string;
  const ASubDir: string = ''): Integer;
type
  TPendingLink = record
    LinkPath, TargetName, FromRel: string;
  end;
var
  TarPath : string;
  TarIn   : TStream;
  Buf     : array[0..65535] of Byte;
  N       : Integer;
  Entry   : TLWPTTarEntry;
  OutName, OutDir : string;
  TypeFlag : Byte;
  Size, Remaining, ToRead : Int64;
  Pad     : Integer;
  FileOut : TFileStream;
  PendingLinks : array of TPendingLink;
  li      : Integer;
  ResolvedTarget : string;
  Plan    : TLWPTArchivePlan;
  Links   : TStringList;
  LinkFields : TStringArray;
begin
  Result := 0;
  PendingLinks := nil;
  if not FileExists(AArchivePath) then
    raise EExtractError.CreateFmt('archive not found: %s', [AArchivePath]);

  { step 1: gunzip AArchivePath -> TarPath }
  TarPath := AArchivePath + '.tar';
  EnsureArchivePathFits(TarPath, ExtractFileName(TarPath),
    ExtractFileDir(TarPath), False);
  GunzipArchive(AArchivePath, TarPath);

  TarIn := OpenProtectedFileStream(TarPath, fmOpenRead or fmShareDenyNone);
  try
    { step 2: check every destination, including directory-link copies,
      before writing any of them, so a traversal or an over-long path fails
      before extraction starts }
    Plan := TLWPTArchivePlan.Create(ADest);
    try
      Links := TStringList.Create;
      try
        while ReadTarEntry(TarIn, ASubDir, Entry) do
        begin
          if Entry.RelName <> '' then
          begin
            OutName := ResolveArchiveOutputPath(ADest, Entry.RelName);
            if Chr(Entry.TypeFlag) in ['1', '2'] then
              Links.Add(OutName + #0 + Entry.LinkName + #0 + Entry.RelName)
            else
              Plan.AddEntry(OutName, Entry.RelName, Chr(Entry.TypeFlag) = '5');
          end;
          TarIn.Seek(Entry.Size + Entry.Pad, soCurrent);
        end;
        for li := 0 to Links.Count - 1 do
        begin
          LinkFields := Links[li].Split([#0]);
          Plan.AddLink(LinkFields[0], LinkFields[1], LinkFields[2]);
        end;
      finally
        Links.Free;
      end;
    finally
      Plan.Free;
    end;
    TarIn.Position := 0;

    { step 3: walk the tar 512-byte blocks directly }
    ForceDirectories(ADest);
    while ReadTarEntry(TarIn, ASubDir, Entry) do
    begin
      Size     := Entry.Size;
      Pad      := Entry.Pad;
      TypeFlag := Entry.TypeFlag;

      if Entry.RelName = '' then
      begin
        { top-level dir entry, outside-subdir entry, or skipped —
          still must consume any data payload }
        if Size > 0 then TarIn.Seek(Size + Pad, soCurrent)
        else if Pad > 0 then TarIn.Seek(Pad, soCurrent);
        Continue;
      end;

      OutName := ResolveArchiveOutputPath(ADest, Entry.RelName);

      case Chr(TypeFlag) of
        '5':   { directory }
          ForceDirectories(OutName);
        '1', '2':   { hardlink ('1') / symlink ('2') — resolve later }
          begin
            SetLength(PendingLinks, Length(PendingLinks) + 1);
            PendingLinks[High(PendingLinks)].LinkPath   := OutName;
            PendingLinks[High(PendingLinks)].TargetName := Entry.LinkName;
            PendingLinks[High(PendingLinks)].FromRel    := Entry.RelName;
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

{ Frozen and offline installs never contact the host, so they cannot prove
  a commit-SHA pin. A lock entry without a valid `reachableFrom` (a ref
  under refs/heads/ or refs/tags/) was written before proofs existed, or by
  hand; it is still installed from its hashes, but the user is told it is
  unproven (ADR-0047). }
procedure WarnUnprovenPin(const AMode, AName: string;
  const AKinds: array of TVersionKind; ASrcKind: TSourceKind;
  const AEntry: TResolved);
var k: Integer; HasCommitPin: Boolean; Commit: string;
begin
  if (ASrcKind <> skGitHost) or IsProvingRefName(AEntry.ReachableFrom) then
    Exit;
  Commit := AEntry.CommitSHA;
  if Commit = '' then Commit := AEntry.Version;
  { Any SHA requirement, alone or beside a named one, needs a proof. }
  HasCommitPin := False;
  for k := 0 to High(AKinds) do
    HasCommitPin := HasCommitPin or (AKinds[k] = vkCommitSha);
  if not HasCommitPin then Exit;
  WriteLn(ErrOutput, 'warning: ', AMode, ' lock entry for "', AName,
    '" pins commit ', LowerCase(Commit), ' without a ',
    'reachability proof; run `', PROGRAM_NAME, ' install` online to prove ',
    'it belongs to the repository''s branches or tags');
end;

procedure RenderLock(ASL: TStringList; const AResolved: array of TResolved;
  const ARegistryTables: TLWPTRegistryLockTableArray);
var
  i  : Integer;

  procedure KV(const AKey, AValue: string);
  begin
    ASL.Add(AKey + ' = "' + TomlEscape(AValue) + '"');
  end;

begin
  ASL.Add('# ' + LWPT.Core.LOCKFILE + ' - generated by ' + PROGRAM_NAME
         + '; do not edit by hand.');
  ASL.Add('version = ' + IntToStr(LOCKFILE_SCHEMA_VERSION));
  for i := 0 to High(AResolved) do
  begin
    ASL.Add('');
    ASL.Add('[package.' + AResolved[i].Name + ']');
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
    { Additive v3 registry evidence (ADR-0051): the origin identity and the
      selected signed record replace the Git commit fields. }
    if AResolved[i].SrcKind = skRegistry then
    begin
      KV('registryOrigin', AResolved[i].RegistryOrigin);
      KV('registryRecord', AResolved[i].RegistryRecord);
    end
    else
      KV('resolvedCommit', AResolved[i].CommitSHA);
    { Additive v3 evidence (ADR-0048), written only for named Git refs. }
    if AResolved[i].RefKind <> '' then
      KV('resolvedRefKind', AResolved[i].RefKind);
    { Additive v3 evidence (ADR-0047): the ref that proved a commit-SHA
      pin reachable. Its absence means the pin was never proven. }
    if AResolved[i].ReachableFrom <> '' then
      KV('reachableFrom', AResolved[i].ReachableFrom);
    KV('sourceIdentity', AResolved[i].SourceIdentity);
    KV('constraintFingerprint', AResolved[i].ConstraintFingerprint);
    KV('resolvedURL',  AResolved[i].ResolvedURL);
    KV('computedHash', AResolved[i].Hash);
    KV('archiveHash',  AResolved[i].ArchiveHash);
  end;
  RenderRegistryLockTables(ARegistryTables, ASL);
end;

function ReadFileText(const APath: string): string;
var Stream: TFileStream;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

function RenderedLockText(const AResolved: array of TResolved;
  const ARegistryTables: TLWPTRegistryLockTableArray): string;
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    RenderLock(SL, AResolved, ARegistryTables);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ Writes the lock unless its bytes are already current; a byte-identical
  lock is never rewritten (ADR-0051 decision 11). }
procedure WriteLock(const APath, ATmpRoot: string;
  const AResolved: array of TResolved;
  const ARegistryTables: TLWPTRegistryLockTableArray);
var
  SL : TStringList;
begin
  SL := TStringList.Create;
  try
    RenderLock(SL, AResolved, ARegistryTables);
    if FileExists(APath) and (ReadFileText(APath) = SL.Text) then Exit;
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
      Entry.RefKind     := TomlStr(EntryNode, 'resolvedRefKind', '');
      Entry.ReachableFrom := TomlStr(EntryNode, 'reachableFrom', '');
      Entry.SourceIdentity := TomlStr(EntryNode, 'sourceIdentity', '');
      Entry.ConstraintFingerprint := TomlStr(EntryNode,
        'constraintFingerprint', '');
      Entry.ResolvedURL := TomlStr(EntryNode, 'resolvedURL', '');
      Entry.Hash        := TomlStr(EntryNode, 'computedHash', '');
      Entry.ArchiveHash := TomlStr(EntryNode, 'archiveHash',  '');
      Entry.RegistryOrigin := TomlStr(EntryNode, 'registryOrigin', '');
      Entry.RegistryRecord := TomlStr(EntryNode, 'registryRecord', '');
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
  { TResolveNode is declared in the interface (exposed for the fingerprint
    regression test); the resolver's own aggregate stays here. }
  TResolution = record
    Nodes : array of TResolveNode;
  end;

  TPathRollback = record
    OriginalPath: string;
    BackupPath: string;
  end;
  TPathRollbackArray = array of TPathRollback;

procedure ResolutionToResolved(const AResolution: TResolution;
  out AResolved: TResolvedArray);
var i, j: Integer;
begin
  SetLength(AResolved, Length(AResolution.Nodes));
  for i := 0 to High(AResolution.Nodes) do
  begin
    AResolved[i] := Default(TResolved);
    AResolved[i].Name := AResolution.Nodes[i].Name;
    AResolved[i].Version := AResolution.Nodes[i].Version;
    AResolved[i].CommitSHA := AResolution.Nodes[i].CommitSHA;
    AResolved[i].RefKind := AResolution.Nodes[i].RefKind;
    AResolved[i].ReachableFrom := AResolution.Nodes[i].ReachableFrom;
    AResolved[i].SourceIdentity := AResolution.Nodes[i].SourceIdentity;
    AResolved[i].ConstraintFingerprint :=
      AResolution.Nodes[i].ConstraintFingerprint;
    AResolved[i].SrcOriginal := AResolution.Nodes[i].Dep.SrcOriginal;
    AResolved[i].SrcKind := AResolution.Nodes[i].Dep.SrcKind;
    AResolved[i].SrcHost := AResolution.Nodes[i].Dep.SrcHost;
    AResolved[i].SrcHostName := AResolution.Nodes[i].Dep.SrcHostName;
    AResolved[i].SrcLocator := AResolution.Nodes[i].Dep.SrcLocator;
    AResolved[i].ResolvedURL := AResolution.Nodes[i].ResolvedURL;
    AResolved[i].UnitDir := AResolution.Nodes[i].UnitDir;
    SetLength(AResolved[i].UnitSubdirs,
      Length(AResolution.Nodes[i].UnitSubdirs));
    for j := 0 to High(AResolution.Nodes[i].UnitSubdirs) do
      AResolved[i].UnitSubdirs[j] :=
        AResolution.Nodes[i].UnitSubdirs[j];
    AResolved[i].Archive := AResolution.Nodes[i].Archive;
    AResolved[i].ArchiveHash := AResolution.Nodes[i].ArchiveHash;
    AResolved[i].RegistryOrigin := AResolution.Nodes[i].RegistryOrigin;
    AResolved[i].RegistryRecord := AResolution.Nodes[i].RegistryRecord;
    if AResolution.Nodes[i].Hash <> '' then
      AResolved[i].Hash := AResolution.Nodes[i].Hash
    else
      AResolved[i].Hash := 'sha256:(unfetched)';
  end;
end;

procedure VerifyOfflineAgainstLockfile(const AResolved: array of TResolved;
  const ALockEntries: array of TResolved); forward;

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
    { Identity is (origin identity, name); no alias and no contact URL
      (ADR-0051), so moving an origin or its mirrors changes nothing. }
    skRegistry:
      Result := 'registry|' + ADep.RegistryOrigin + '|' + ADep.Name;
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

{ Fold an ordered constraint-line set into the fingerprint the frozen
  verifier compares.

  Every line — including the last — is followed by
  CONSTRAINT_FINGERPRINT_SEPARATOR, reproducing TStrings.Text's trailing
  line break. This is a per-line terminator, not a between-lines join:
  tidying it to a join would drop the final separator and silently change
  every committed fingerprint.

  The digest input must be byte-identical on every platform: a lockfile is
  written on one machine and verified on another. TStrings.Text joins with
  the PLATFORM line ending (LF on Unix, CRLF on Windows), so hashing it made
  a lockfile written on POSIX fail `--frozen` on Windows with "accumulated
  constraints changed" on identical constraints — the tree-hash separator
  bug (#78) in a second guise. The separator is therefore pinned rather than
  inherited, exactly like TREE_HASH_PATH_SEPARATOR.

  Pinning to LF keeps every fingerprint ever computed on an LF platform
  byte-identical (committed lockfiles stay valid); only Windows-written
  digests change, and those could never verify anywhere else. }
function ConstraintFingerprintForLines(const ALines: TStrings): string;
var Folded: string; k: Integer;
begin
  Folded := '';
  for k := 0 to ALines.Count - 1 do
    Folded := Folded + ALines[k] + CONSTRAINT_FINGERPRINT_SEPARATOR;
  Result := 'sha256:' + SHA256Hex(BytesOf(Folded));
end;

{ Order the constraint lines by 8-bit ordinal value, byte for byte.
  CompareStr is ordinal on every platform; the locale collations
  (AnsiCompareText, which a default TStringList.Sort applies, and
  AnsiCompareStr, which CaseSensitive := True would apply) both route
  through CompareStringW on Windows, where '-' and ''' are
  primary-ignorable. A dep accumulating two requirement lines that differ
  only in such a character would then sort differently on Windows and
  recompute the fingerprint there — the very cross-platform drift this
  digest exists to prevent, in the ordering rather than the separator. The
  sibling identity folds pin case (CanonicalDependencyIdentity,
  CanonicalizePathGlobs set CaseSensitive := True); this one goes further to
  a fully ordinal comparator because its inputs carry package-name
  punctuation those word-sorts fold away. }
function CompareConstraintLinesOrdinal(AList: TStringList;
  AIndex1, AIndex2: Integer): Integer;
begin
  Result := CompareStr(AList[AIndex1], AList[AIndex2]);
end;

function ConstraintFingerprintForNode(const ANode: TResolveNode;
  const AProjectRoot: string): string;
var Lines: TStringList; k: Integer;
begin
  Lines := TStringList.Create;
  try
    for k := 0 to High(ANode.Specs) do
      Lines.Add(IntToStr(Ord(ANode.Kinds[k])) + '|' + ANode.Specs[k]
        + '|' + ANode.Requirers[k]);
    Lines.Add('source|' + CanonicalDependencyIdentity(ANode.Dep,
      ANode.CustomSources, AProjectRoot));
    Lines.CustomSort(@CompareConstraintLinesOrdinal);
    Result := ConstraintFingerprintForLines(Lines);
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
    { The locked selection proof of a registry dependency is verified by a
      later slice of ADR-0051; until then frozen verification fails closed
      rather than trusting unsigned lock fields. }
    if D.SrcKind = skRegistry then
      raise EVerifyError.CreateFmt(
        '[frozen] registry dependency "%s" (required by %s) cannot yet be '
        + 'verified by --frozen; run `%s install` online',
        [D.Name, ABy, PROGRAM_NAME]);
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

{ One committed proof document, which must hash to its name. }
function ReadRegistryProofDocument(const AArchivesRoot, AHash: string): TBytes;
var Path: string; Stream: TFileStream;
begin
  Result := nil;
  if not RegistryHashIsCanonical(AHash) then
    raise ELWPTRegistryError.CreateStable('registry_proof_missing',
      'lock names an invalid proof document hash "' + AHash + '"');
  Path := RegistryProofPath(AArchivesRoot, AHash);
  if not FileExists(Path) then
    raise ELWPTRegistryError.CreateStable('registry_proof_missing',
      'committed proof document ' + Path + ' is missing');
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES * 4 then
      raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
        'committed proof document ' + Path + ' is oversized');
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
  if SHA256BytesPrefixed(Result) <> AHash then
    raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
      'committed proof document ' + Path + ' does not match its hash');
end;

{ Verifies a lock table's committed selection proof and returns the
  authenticated records for ARecords, in order (ADR-0051 decision 4). }
function VerifyCommittedRegistryProof(const AArchivesRoot: string;
  const ATable: TLWPTRegistryLockTable; const ATrust: TLWPTRegistryTrust;
  const ARecords: array of string;
  out AVerified: TLWPTVerifiedRegistrySelection; out AReason: string): Boolean;
var
  Selection: TLWPTRegistryLockedSelection;
  Index: Integer;
begin
  Result := False;
  AReason := '';
  AVerified := Default(TLWPTVerifiedRegistrySelection);
  try
    if ATable.TrustKeyId <> ATrust.KeyId then
      raise ELWPTRegistryError.CreateStable('registry_pin_changed',
        'trust pin for ' + ATable.Identity + ' changed');
    if (Length(ATable.Rotations) mod 3) <> 0 then
      raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
        'lock rotation hashes are incomplete');
    Selection := Default(TLWPTRegistryLockedSelection);
    Selection.Checkpoint := ReadRegistryProofDocument(AArchivesRoot, ATable.Checkpoint);
    Selection.Signature := ReadRegistryProofDocument(AArchivesRoot, ATable.Signature);
    Selection.Snapshot := ReadRegistryProofDocument(AArchivesRoot, ATable.Snapshot);
    SetLength(Selection.Rotations, Length(ATable.Rotations) div 3);
    for Index := 0 to High(Selection.Rotations) do
    begin
      Selection.Rotations[Index].Document :=
        ReadRegistryProofDocument(AArchivesRoot, ATable.Rotations[3 * Index]);
      Selection.Rotations[Index].OldSignature :=
        ReadRegistryProofDocument(AArchivesRoot, ATable.Rotations[3 * Index + 1]);
      Selection.Rotations[Index].NewSignature :=
        ReadRegistryProofDocument(AArchivesRoot, ATable.Rotations[3 * Index + 2]);
    end;
    SetLength(Selection.Records, Length(ARecords));
    for Index := 0 to High(ARecords) do
      Selection.Records[Index] := ReadRegistryProofDocument(AArchivesRoot,
        ARecords[Index]);
    AVerified := VerifyRegistryLockedSelection(Selection, ATrust,
      ATable.Checkpoint);
    if (AVerified.Sequence <> ATable.Sequence)
       or (AVerified.Snapshot <> ATable.Snapshot)
       or (AVerified.KeyId <> ATable.KeyId) then
      raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
        'committed checkpoint differs from the recorded selection proof');
    Result := True;
  except
    on E: Exception do AReason := E.Message;
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
  const AWorkspaces: TWorkspaceArray;
  const APriorLock: TResolvedArray;
  const AObjectStore: TLWPTImmutableObjectStore;
  const AOffline, AAcceptMovedTags: Boolean;
  const AConsumer: TLWPTRegistryConsumer);
type
  TSelectionState = record
    Name, SourceIdentity, RefName, CommitSHA, RefKind, ReachableFrom: string;
    RegistryOrigin, RegistryRecord: string;
  end;
  TSelectionStateArray = array of TSelectionState;
  TRefCacheEntry = record
    RepoURL: string;
    Refs: TGitRefArray;
  end;
  TRefCache = array of TRefCacheEntry;
var
  Previous, Desired: TSelectionStateArray;
  OfflineResolved: TResolvedArray;
  RefCache: TRefCache;
  VerifiedPins: TStringList;
  SeenSignatures: TStringList;
  PlanRoot, PlanModules, PlanArchives, PlanScratch: string;
  Round, i, j, idx, Head: Integer;
  Queue: array of Integer;
  ChildMan: TManifest;
  LockedEntry: TResolved;
  ChildManifestPath, ManifestRelDir, ExtractTmp: string;
  UnitDir, Archive, ArchiveHash, ResolvedURL, CacheArchive,
    ExpectedArchiveHash, VerifyArchiveHash, VerifyContext: string;
  FetchRef, RollbackFailures, StagedRefLabel: string;
  SelectionDeferred, Stable, IsMember: Boolean;
  MemberVersion: string;
  RegistryPackages: TLWPTRegistryPackageArray;
  RegistryWarnings: TStringList;

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

  function LockSourceMatches(const ANode: TResolveNode;
    const AEntry: TResolved): Boolean;
  begin
    if AEntry.SourceIdentity <> '' then
      Result := AEntry.SourceIdentity = SourceKey(ANode.Dep,
        ANode.CustomSources)
    else
      Result := AEntry.SrcOriginal = ANode.Dep.SrcOriginal;
  end;

  function LockedCommitIdentity(const AEntry: TResolved): string;
  var Kind: TVersionKind; Value: string;
  begin
    Result := AEntry.CommitSHA;
    if Result <> '' then Exit;
    ParseVersionSpec(AEntry.Version, Kind, Value);
    if Kind = vkCommitSha then Result := Value;
  end;

  function FindPriorLock(const ANode: TResolveNode;
    out AEntry: TResolved): Boolean;
  var k: Integer;
  begin
    AEntry := Default(TResolved);
    for k := 0 to High(APriorLock) do
      if SameText(APriorLock[k].Name, ANode.Name)
         and LockSourceMatches(ANode, APriorLock[k]) then
      begin
        AEntry := APriorLock[k];
        Exit(True);
      end;
    Result := False;
  end;

  function PriorSelectionSatisfies(const ANode: TResolveNode;
    const AEntry: TResolved): Boolean;
  var k: Integer; CommitIdentity: string;
  begin
    CommitIdentity := LockedCommitIdentity(AEntry);
    Result := True;
    for k := 0 to High(ANode.Kinds) do
      case ANode.Kinds[k] of
        vkSemverRange:
          Result := Result and Satisfies(StripVPrefix(AEntry.Version),
            ANode.Specs[k], DefaultSemverOptions);
        vkSemverExact:
          Result := Result and ((AEntry.Version = ANode.Specs[k])
            or (AEntry.Version = 'v' + ANode.Specs[k]));
        vkCommitSha:
          Result := Result and (CommitIdentity <> '')
            and SameText(ANode.Specs[k], Copy(CommitIdentity, 1,
              Length(ANode.Specs[k])));
        vkLiteralTag:
          Result := Result and (AEntry.Version = ANode.Specs[k]);
        vkNone:;
      end;
  end;

  function ExpectedHashForSelection(const ANode: TResolveNode): string;
  var Entry: TResolved;
  begin
    Result := '';
    if not FindPriorLock(ANode, Entry) then Exit;
    if Entry.ArchiveHash = '' then Exit;
    if Entry.Version <> ANode.Version then Exit;
    if (ANode.CommitSHA <> '')
       and ((Entry.CommitSHA = '')
         or not SameText(Entry.CommitSHA, ANode.CommitSHA)) then Exit;
    Result := Entry.ArchiveHash;
  end;

  function IsNetworkBacked(const ANode: TResolveNode): Boolean;
  begin
    Result := not (ANode.Dep.SrcKind in [skLocal, skWorkspace]);
  end;

  procedure SelectLockedNode(const ANode: TResolveNode;
    var AState: TSelectionState);
  var Entry: TResolved;
  begin
    if not FindPriorLock(ANode, Entry) then
      raise EVerifyError.CreateFmt(
        '[offline] dependency "%s" has no compatible lock entry for '
        + 'its current source. Run `lwpt install` online to resolve it.',
        [ANode.Name]);
    if not PriorSelectionSatisfies(ANode, Entry) then
      raise EVerifyError.CreateFmt(
        '[offline] locked version "%s" no longer satisfies the manifest '
        + 'requirements for "%s". Run `lwpt install` online to resolve '
        + 'the changed graph.', [Entry.Version, ANode.Name]);
    if Entry.ArchiveHash = '' then
      raise EVerifyError.CreateFmt(
        '[offline] lock entry for "%s" has no archive hash. Run '
        + '`lwpt install` online to regenerate compatible locked evidence.',
        [ANode.Name]);
    AState.RefName := Entry.Version;
    AState.CommitSHA := LockedCommitIdentity(Entry);
    AState.RefKind := Entry.RefKind;
    AState.ReachableFrom := Entry.ReachableFrom;
    WarnUnprovenPin('[offline]', ANode.Name, ANode.Kinds, ANode.Dep.SrcKind,
      Entry);
  end;

  procedure StageLockedArchive(const ANode: TResolveNode;
    const AFetchRef: string; out AUnitDir, AArchive, AArchiveHash,
    AResolvedURL: string);
  var
    Entry: TResolved;
    ProjectArchive, ActualHash: string;
    Failure: TLWPTObjectMaterializeFailure;
  begin
    if not FindPriorLock(ANode, Entry) then
      raise EVerifyError.CreateFmt(
        '[offline] dependency "%s" has no compatible lock entry',
        [ANode.Name]);
    AUnitDir := IncludeTrailingPathDelimiter(PlanModules) + ANode.Name;
    AArchive := ArchivePathForRef(PlanArchives, ANode.Name,
      ANode.Dep.SrcKind, AFetchRef);
    AArchiveHash := '';
    AResolvedURL := Entry.ResolvedURL;
    ForceDirectories(ExtractFileDir(AArchive));
    ProjectArchive := ArchivePathForRef(AArchivesRoot, ANode.Name,
      ANode.Dep.SrcKind, Entry.Version);
    if FileExists(ProjectArchive) then
    begin
      ActualHash := 'sha256:' + SHA256File(ProjectArchive);
      if ActualHash <> Entry.ArchiveHash then
        raise EVerifyError.CreateFmt(
          '[offline] archive hash mismatch for "%s": disk=%s lockfile=%s. '
          + 'Restore the committed archive or run `lwpt install` online.',
          [ANode.Name, ActualHash, Entry.ArchiveHash]);
      if not CopyFileContent(ProjectArchive, AArchive) then
        raise EFetchError.CreateFmt(
          '[offline] failed to stage committed archive for "%s"',
          [ANode.Name]);
      AArchiveHash := Entry.ArchiveHash;
      WriteLn('  reused committed archive for ', ANode.Name);
      Exit;
    end;
    Failure := omfObjectMissing;
    if AObjectStore <> nil then
      try
        if AObjectStore.Materialize(Entry.ArchiveHash, AArchive,
             PlanScratch, Failure) then
        begin
          AArchiveHash := Entry.ArchiveHash;
          WriteLn('  reused verified archive for ', ANode.Name,
            ' from the per-user cache');
          Exit;
        end;
      except
        on E: Exception do
          raise EFetchError.CreateFmt(
            '[offline] dependency archive cache failed for "%s": %s',
            [ANode.Name, E.Message]);
      end;
    raise EFetchError.CreateFmt(
      '[offline] verified archive for "%s" is unavailable '
      + '(expected %s; cache result: %s). Restore the committed archive '
      + 'or run `lwpt install` online to seed the cache.',
      [ANode.Name, Entry.ArchiveHash,
       ObjectMaterializeFailureName(Failure)]);
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

  procedure WarnOnce(const AKey, AMessage: string);
  begin
    if RegistryWarnings.IndexOf(AKey) >= 0 then Exit;
    RegistryWarnings.Add(AKey);
    WriteLn(ErrOutput, 'warning: ', AMessage);
  end;

  function FindRegistryPackage(const ARecord: string;
    out APackage: TLWPTRegistryPackage): Boolean;
  var k: Integer;
  begin
    for k := 0 to High(RegistryPackages) do
      if RegistryPackages[k].RecordHash = ARecord then
      begin
        APackage := RegistryPackages[k];
        Exit(True);
      end;
    APackage := Default(TLWPTRegistryPackage);
    Result := False;
  end;

  procedure RememberRegistryPackage(const APackage: TLWPTRegistryPackage);
  var Existing: TLWPTRegistryPackage;
  begin
    if FindRegistryPackage(APackage.RecordHash, Existing) then Exit;
    SetLength(RegistryPackages, Length(RegistryPackages) + 1);
    RegistryPackages[High(RegistryPackages)] := APackage;
  end;

  function RegistrySession(const ANode: TResolveNode): TLWPTRegistrySession;
  begin
    Result := AConsumer.SessionForIdentity(ANode.Dep.RegistryOrigin,
      ANode.Name, ANode.Requirers[0], '');
  end;

  { A manifest dependency names an alias; its source identity is the
    alias's origin identity: declared, recorded in the lock, or advertised
    under the pin (ADR-0051 precedence). A record dependency already
    carries its origin. }
  procedure ResolveRegistryOrigin(var ADep: TDependency;
    const ARequiredBy: string);
  var Session: TLWPTRegistrySession;
  begin
    { --offline must reach its locked path before any registry client
      exists; restoring registry dependencies offline is a later slice. }
    if AOffline then
      raise EVerifyError.CreateFmt(
        '[offline] registry dependency "%s" (required by %s) cannot yet be '
        + 'restored by --offline; run `%s install` online',
        [ADep.Name, ARequiredBy, PROGRAM_NAME]);
    if ADep.RegistryOrigin <> '' then Exit;
    Session := AConsumer.SessionForAlias(RegistryAliasFor(ARootMan, ADep));
    if (Session.Identity = '') and (Session.LockedIdentity = '') then
      Session.Acquire;
    if Session.Identity <> '' then
      ADep.RegistryOrigin := Session.Identity
    else if Session.LockedIdentity <> '' then
      ADep.RegistryOrigin := Session.LockedIdentity
    else
      raise EFetchError.CreateFmt(
        'registry %s declares no identity and none is recorded in %s, and '
        + 'every contact is unreachable:%s', [Session.Alias,
        LWPT.Core.LOCKFILE, Session.Failures]);
  end;

  { An alias a workspace member shares with the root names the same
    identity and pin (ADR-0051); the member's own table is otherwise used
    only when it is published. }
  procedure CheckMemberRegistries(const AMember: TManifest;
    const AMemberName: string);
  var
    k: Integer;
    RootDeclaration: TLWPTRegistryDeclaration;
    Session: TLWPTRegistrySession;
    Established: string;

    procedure Mismatch;
    begin
      raise EManifestError.CreateFmt(
        'workspace member "%s" declares [registries.%s] with a different '
        + 'identity or pin than the root %s; an alias shared with the root '
        + 'must name the same identity and pin',
        [AMemberName, AMember.Registries[k].Alias, MANIFEST_FILE]);
    end;

  begin
    for k := 0 to High(AMember.Registries) do
    begin
      if not FindRegistryDeclaration(ARootMan.Registries,
           AMember.Registries[k].Alias, RootDeclaration) then Continue;
      if (AMember.Registries[k].KeyId <> RootDeclaration.KeyId)
         or (AMember.Registries[k].PublicKey <> RootDeclaration.PublicKey)
         or ((AMember.Registries[k].Identity <> '')
           and (RootDeclaration.Identity <> '')
           and (AMember.Registries[k].Identity <> RootDeclaration.Identity)) then
        Mismatch;
      if (AMember.Registries[k].Identity <> '')
         and (RootDeclaration.Identity = '') then
      begin
        Session := AConsumer.SessionForAlias(RootDeclaration.Alias);
        Established := Session.Identity;
        if Established = '' then Established := Session.LockedIdentity;
        if (Established <> '')
           and (Established <> AMember.Registries[k].Identity) then
          Mismatch;
      end;
    end;
  end;

  function AddRequirement(var AResolution: TResolution;
    const ADep: TDependency; const ARequiredBy: string;
    const ACustomSources: TCustomSourceArray): Integer;
  var IsNew: Boolean; NormalizedDep: TDependency; Identity: string;
  begin
    NormalizeWorkspaceDependency(ADep, ARequiredBy, AWorkspaces,
      NormalizedDep);
    if NormalizedDep.SrcKind = skRegistry then
      ResolveRegistryOrigin(NormalizedDep, ARequiredBy);
    Identity := SourceKey(NormalizedDep, ACustomSources);
    Result := TouchNode(AResolution, NormalizedDep, ARequiredBy,
      Identity, IsNew);
    if IsNew then
      CopyCustomSources(ACustomSources,
        AResolution.Nodes[Result].CustomSources);
  end;

  function CachedRefs(const ANode: TResolveNode): TGitRefArray;
  var RepoURL: string; Refs: TGitRefArray; k, n: Integer;
  begin
    RepoURL := GitRepoURL(ANode.Dep, ANode.CustomSources);
    for k := 0 to High(RefCache) do
      if RefCache[k].RepoURL = RepoURL then Exit(RefCache[k].Refs);
    WriteLn('  resolving tags for ', ANode.Name, '...');
    { A failed advertisement is not a reusable empty advertisement. Resolve
      before extending the cache so a later complete-set selection can take
      the same lock-identity fallback as the discovery pass. }
    Refs := ListRemoteRefs(RepoURL, DependencyFetchOptions(ANode.Dep,
      ANode.CustomSources, DefaultHTTPRequestOptions));
    n := Length(RefCache);
    SetLength(RefCache, n + 1);
    RefCache[n].RepoURL := RepoURL;
    RefCache[n].Refs := Refs;
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

  { The kind of the selected ref. A tag and a branch may share a name and
    commit; advertisement order then must not decide the kind. The lock's
    recorded branch is kept; otherwise the tag wins, as the stricter kind. }
  function SelectedRefKind(const ANode: TResolveNode;
    const ARefs: TGitRefArray; const ASelection: TResolverSelection): string;
  var
    Entry: TResolved;
    RefIndex: Integer;
    HasTag, HasBranch: Boolean;
  begin
    HasTag := False;
    HasBranch := False;
    for RefIndex := 0 to High(ARefs) do
      if (ARefs[RefIndex].Name = ASelection.RefName)
         and SameText(RefCommitSHA(ARefs[RefIndex]), ASelection.CommitSHA) then
        if ARefs[RefIndex].Kind = rkTag then HasTag := True
        else HasBranch := True;
    if HasTag and HasBranch then
    begin
      if FindPriorLock(ANode, Entry) and (Entry.RefKind = RefKindBranch)
         and (Entry.Version = ASelection.RefName) then
        Exit(RefKindBranch);
      Exit(RefKindTag);
    end;
    if ASelection.RefKind = rkTag then Result := RefKindTag
    else Result := RefKindBranch;
  end;

  { Two ref names identify the same tag when they are equal, or when both
    are SemVer spellings of one version (`v1.0.0` and `1.0.0`). }
  function SameRefName(const ALocked, ASelected: string): Boolean;
  var LockedVersion: string;
  begin
    if ALocked = ASelected then Exit(True);
    LockedVersion := Valid(StripVPrefix(ALocked), DefaultSemverOptions);
    Result := (LockedVersion <> '')
      and (LockedVersion = Valid(StripVPrefix(ASelected),
        DefaultSemverOptions));
  end;

  procedure RaiseMovedRef(const ANode: TResolveNode; const AMessage: string);
  begin
    raise EVerifyError.Create('dependency "' + ANode.Name + '": ' + AMessage
      + ' Review the upstream change, then run `' + PROGRAM_NAME
      + ' install --accept-moved-tags` to accept it.');
  end;

  { A locked tag is an immutable name for a reviewed commit (ADR-0048).
    Whenever resolution selects the same tag again -- under any manifest
    requirement, deliberately -- it must still be a tag at the locked
    commit. A tag that moved, or that was replaced by a same-named branch,
    fails until the caller accepts it. Branches keep moving, and a branch
    replaced by a same-named tag is not a moved tag. A lock that predates
    `resolvedRefKind` cannot prove a ref was a branch, so a changed commit
    behind a ref that now resolves as a branch also fails closed. A lock
    that predates `resolvedCommit` is checked by archive identity instead
    (ExpectedVerifyHash). }
  procedure RejectMovedRef(const ANode: TResolveNode;
    var ASelection: TSelectionState);
  var Entry: TResolved; LockedCommit: string;
  begin
    if AAcceptMovedTags or not FindPriorLock(ANode, Entry) then Exit;
    if not SameRefName(Entry.Version, ASelection.RefName) then Exit;
    if Entry.RefKind = RefKindBranch then Exit;
    { An unknown locked kind is never promoted to branch without explicit
      acceptance: seeing a branch at the locked commit proves nothing about
      what the ref was, so the lock keeps the kind unknown and a later move
      still fails closed. Promotion to tag only tightens the rule. }
    if (Entry.RefKind = '') and (ASelection.RefKind = RefKindBranch) then
      ASelection.RefKind := '';
    LockedCommit := LockedCommitIdentity(Entry);
    if (Entry.RefKind = RefKindTag)
       and (ASelection.RefKind = RefKindBranch) then
      RaiseMovedRef(ANode, Format('locked tag "%s" (commit %s) is now '
        + 'advertised only as branch "%s" at %s.', [Entry.Version,
        LowerCase(LockedCommit), ASelection.RefName,
        LowerCase(ASelection.CommitSHA)]));
    if (LockedCommit = '')
       or SameText(LockedCommit, ASelection.CommitSHA) then Exit;
    if (Entry.RefKind = RefKindTag)
       or (ASelection.RefKind = RefKindTag) then
      RaiseMovedRef(ANode, Format('tag "%s" moved upstream since it was '
        + 'locked (locked commit %s, now advertised at %s).',
        [ASelection.RefName, LowerCase(LockedCommit),
         LowerCase(ASelection.CommitSHA)]));
    RaiseMovedRef(ANode, Format('ref "%s" now resolves to branch commit %s, '
      + 'but %s pinned commit %s before ref kinds were recorded, so it '
      + 'cannot prove "%s" was a branch that may move.',
      [ASelection.RefName, LowerCase(ASelection.CommitSHA), LWPT.Core.LOCKFILE,
       LowerCase(LockedCommit), ASelection.RefName]));
  end;

  { The locked archive digest that a fresh download for ANode must
    reproduce, or '' when the selection is not the locked identity. Same
    commit means same bytes. A lock without a recorded commit is compared by
    ref name, which is how a tag moved behind an early schema-v3 lock is
    caught. }
  function ExpectedVerifyHash(const ANode: TResolveNode;
    out AContext: string): string;
  var Entry: TResolved; LockedCommit: string;
  begin
    Result := '';
    AContext := '';
    if AAcceptMovedTags or (ANode.Dep.SrcKind <> skGitHost) then Exit;
    if not FindPriorLock(ANode, Entry) or (Entry.ArchiveHash = '') then Exit;
    LockedCommit := LockedCommitIdentity(Entry);
    if LockedCommit <> '' then
    begin
      if (ANode.CommitSHA = '')
         or not SameText(LockedCommit, ANode.CommitSHA) then Exit;
      AContext := Format('the archive served for locked commit %s no longer '
        + 'matches %s', [LowerCase(LockedCommit), LWPT.Core.LOCKFILE]);
    end
    else
    begin
      if not SameRefName(Entry.Version, ANode.Version) then Exit;
      if ANode.RefKind = RefKindTag then
        AContext := Format('tag "%s" moved upstream since it was locked: its '
          + 'archive no longer matches %s', [ANode.Version, LWPT.Core.LOCKFILE])
      else
        AContext := Format('ref "%s" changed upstream since it was locked, '
          + 'and %s records no commit that would allow it to move: its '
          + 'archive no longer matches', [ANode.Version, LWPT.Core.LOCKFILE]);
    end;
    Result := Entry.ArchiveHash;
  end;

  function NewUploadPackTransport(
    const ANode: TResolveNode): TGitUploadPackTransport;
  {$IFDEF INSTALL_TESTING}
  var FixtureRoot: string;
  {$ENDIF}
  begin
    {$IFDEF INSTALL_TESTING}
    FixtureRoot := SysUtils.GetEnvironmentVariable(
      PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR');
    if FixtureRoot <> '' then
      Exit(TGitFixtureUploadPackTransport.Create(FixtureRoot, 0, True));
    {$ENDIF}
    { The same destination policy as ref listing and archive fetches. }
    Result := THTTPGitUploadPackTransport.Create(DependencyFetchOptions(
      ANode.Dep, ANode.CustomSources, DefaultHTTPRequestOptions));
  end;

  { A commit-SHA pin is accepted only when the commit is reachable from an
    advertised refs/heads/* or refs/tags/* tip (ADR-0047): the archive
    endpoint also serves commits that exist only in forks or pull requests.
    The proof runs when the lock entry is created, when its commit changes,
    and when a locked entry lacks `reachableFrom`. An entry for the same
    source at the same commit that records its proving ref is trusted like
    the committed archive it names. Returns the proving ref. }
  function VerifyCommitPin(const ANode: TResolveNode;
    const ACommit: string): string;
  var
    RepoURL: string;
    Entry: TResolved;
    Refs: TGitRefArray;
    Transport: TGitUploadPackTransport;
    Outcome: TGitReachabilityResult;
  begin
    RepoURL := GitRepoURL(ANode.Dep, ANode.CustomSources);
    Result := VerifiedPins.Values[RepoURL + '@' + LowerCase(ACommit)];
    if Result <> '' then Exit;
    { Only an entry that records its proof is trusted; a v3 entry without
      `reachableFrom` predates proofs and is proven now. }
    if FindPriorLock(ANode, Entry)
       and SameText(LockedCommitIdentity(Entry), ACommit)
       and IsProvingRefName(Entry.ReachableFrom) then
      Exit(Entry.ReachableFrom);
    Refs := CachedRefs(ANode);
    WriteLn('  verifying commit ', LowerCase(ACommit), ' for ', ANode.Name,
      '...');
    Transport := NewUploadPackTransport(ANode);
    try
      try
        Outcome := ProveCommitReachable(Transport, RepoURL, ACommit, Refs);
      except
        on E: ELWPTError do
          raise;
        on E: Exception do
          raise EFetchError.CreateFmt(
            'dependency "%s": cannot verify that commit %s belongs to %s: '
            + '%s. Pin a tag or branch instead, or a commit that is an '
            + 'advertised branch or tag tip.',
            [ANode.Name, LowerCase(ACommit), RepoURL, E.Message]);
      end;
    finally
      Transport.Free;
    end;
    if not Outcome.Known then
      raise EVerifyError.CreateFmt(
        'dependency "%s": commit %s does not exist in %s',
        [ANode.Name, LowerCase(ACommit), RepoURL]);
    if not Outcome.Reachable then
      raise EVerifyError.CreateFmt(
        'dependency "%s": commit %s is not reachable from any branch or tag '
        + 'of %s. It may exist only in a fork or a pull request, or the '
        + 'branch that contained it was deleted or force-pushed. Pin a '
        + 'commit from the repository''s own history.',
        [ANode.Name, LowerCase(ACommit), RepoURL]);
    WriteLn('  verified commit ', LowerCase(ACommit), ' for ', ANode.Name,
      ': reachable from ', Outcome.ProvingRef, ' (', Outcome.Requests,
      ' requests, ', Outcome.BytesReceived, ' bytes)');
    Result := Outcome.ProvingRef;
    VerifiedPins.Values[RepoURL + '@' + LowerCase(ACommit)] := Result;
  end;

  function NodeHasCommitPin(const ANode: TResolveNode): Boolean;
  var k: Integer;
  begin
    Result := False;
    for k := 0 to High(ANode.Kinds) do
      Result := Result or (ANode.Kinds[k] = vkCommitSha);
  end;

  { Decision 8: every contact failed at the request layer. The locked
    selection is reused only while it satisfies every requirement and its
    committed proof verifies from the manifest pin. }
  function ReuseLockedRegistrySelection(const ANode: TResolveNode;
    const ASession: TLWPTRegistrySession; var AState: TSelectionState): string;
  var
    Entry: TResolved;
    k: Integer;
    Table: TLWPTRegistryLockTable;
    Found: Boolean;
    Verified: TLWPTVerifiedRegistrySelection;
    Package: TLWPTRegistryPackage;
  begin
    Result := '';
    if not FindPriorLock(ANode, Entry) then
      Exit('no compatible lock entry exists');
    if not PriorSelectionSatisfies(ANode, Entry) then
      Exit('locked version ' + Entry.Version
        + ' no longer satisfies every requirement');
    if (Entry.RegistryOrigin <> ANode.Dep.RegistryOrigin)
       or (Entry.RegistryRecord = '') then
      Exit('the lock entry records no registry selection for this origin');
    Found := False;
    for k := 0 to High(AConsumer.LockTables) do
      if AConsumer.LockTables[k].Identity = Entry.RegistryOrigin then
      begin
        Table := AConsumer.LockTables[k];
        Found := True;
        Break;
      end;
    if not Found then
      Exit('the lock has no [registry."' + Entry.RegistryOrigin + '"] table');
    if not VerifyCommittedRegistryProof(AArchivesRoot, Table, ASession.Trust,
         [Entry.RegistryRecord], Verified, Result) then
      Exit;
    Package := Verified.Packages[0];
    if (Package.Name <> ANode.Name) or (Package.Version <> Entry.Version)
       or (Package.ArchiveHash <> Entry.ArchiveHash) then
      Exit('the committed record differs from the lock entry');
    RememberRegistryPackage(Package);
    AState.RefName := Entry.Version;
    AState.RegistryRecord := Entry.RegistryRecord;
    WarnOnce('unreachable:' + ANode.Name, 'every contact for registry '
      + ASession.Alias + ' failed at the request layer; reusing the locked '
      + 'selection ' + ANode.Name + '@' + Entry.Version
      + ', verified from the committed proof:' + ASession.Failures);
  end;

  procedure SelectRegistryNode(const ANode: TResolveNode;
    var AState: TSelectionState);
  var
    Session: TLWPTRegistrySession;
    Requirements: TResolverRequirementArray;
    Candidates: TResolverVersionCandidateArray;
    Packages: TLWPTRegistryPackageArray;
    Package: TLWPTRegistryPackage;
    PriorEntry: TResolved;
    k, Chosen: Integer;
    LockedVersion, Reason: string;
  begin
    Session := RegistrySession(ANode);
    Session.Acquire;
    AState.RegistryOrigin := ANode.Dep.RegistryOrigin;
    if Session.Unreachable then
    begin
      Reason := ReuseLockedRegistrySelection(ANode, Session, AState);
      if Reason = '' then Exit;
      raise EFetchError.CreateFmt(
        'registry dependency "%s": every contact for registry %s is '
        + 'unreachable, and the locked selection cannot be reused (%s):%s',
        [ANode.Name, Session.Alias, Reason, Session.Failures]);
    end;
    SetLength(Requirements, Length(ANode.Specs));
    for k := 0 to High(Requirements) do
    begin
      Requirements[k].Spec := ANode.Specs[k];
      Requirements[k].Kind := ANode.Kinds[k];
      Requirements[k].Requirer := ANode.Requirers[k];
    end;
    Candidates := nil;
    Packages := nil;
    { The verified head snapshot is the index; package lists are never
      consulted for selection. }
    for k := 0 to High(Session.Verified.Packages) do
      if (Session.Verified.Packages[k].Name = ANode.Name)
         and (Session.Verified.Packages[k].Origin = Session.Identity) then
      begin
        SetLength(Candidates, Length(Candidates) + 1);
        Candidates[High(Candidates)].Version := Session.Verified.Packages[k].Version;
        Candidates[High(Candidates)].Key := Session.Verified.Packages[k].RecordHash;
        Candidates[High(Candidates)].Yanked := Session.Verified.Packages[k].Yanked;
        SetLength(Packages, Length(Packages) + 1);
        Packages[High(Packages)] := Session.Verified.Packages[k];
      end;
    LockedVersion := '';
    if FindPriorLock(ANode, PriorEntry)
       and (PriorEntry.RegistryOrigin = Session.Identity) then
      LockedVersion := PriorEntry.Version;
    try
      Chosen := SelectHighestVersion(ANode.Name, Requirements, Candidates,
        LockedVersion);
    except
      on E: EResolverConflict do
        raise EManifestError.Create(E.Message + LineEnding
          + '  canonical source: ' + SourceKey(ANode.Dep, ANode.CustomSources));
    end;
    Package := Packages[Chosen];
    RememberRegistryPackage(Package);
    AState.RefName := Package.Version;
    AState.RegistryRecord := Package.RecordHash;
    if Package.Yanked then
      WarnOnce('yanked:' + ANode.Name, 'locked version ' + ANode.Name + '@'
        + Package.Version + ' is yanked upstream; it stays locked, but it is '
        + 'never newly selected');
  end;

  { The extracted manifest must name the signed record's package and
    version before any of its bytes are used. }
  procedure RequireRegistryManifestIdentity(const ANode: TResolveNode;
    const ATree: string);
  var RelDir, Path: string; Manifest: TManifest;
  begin
    if not FindModuleManifest(ATree, RelDir) then
      raise ELWPTRegistryError.CreateStable(
        'registry_manifest_identity_mismatch', 'archive of ' + ANode.Name
        + '@' + ANode.Version + ' contains no ' + MANIFEST_FILE);
    Path := IncludeTrailingPathDelimiter(ATree);
    if RelDir <> '' then Path := Path + RelDir + '/';
    Manifest := LoadManifest(Path + MANIFEST_FILE, False);
    if (Manifest.Name <> ANode.Name) or (Manifest.Version <> ANode.Version) then
      raise ELWPTRegistryError.CreateStable(
        'registry_manifest_identity_mismatch', 'archive manifest declares '
        + Manifest.Name + '@' + Manifest.Version + ', but the signed record '
        + 'is ' + ANode.Name + '@' + ANode.Version);
  end;

  { Archive sources, in order: this install's candidate, the committed
    project archive, the per-user CAS by the signed digest, then the contact
    that produced the accepted proof. Every source is verified against the
    signed record before it is extracted. }
  procedure StageRegistryNode(const ANode: TResolveNode;
    const ACacheArchive: string; out AUnitDir, AArchive, AArchiveHash,
    AResolvedURL: string);
  var
    Package: TLWPTRegistryPackage;
    Session: TLWPTRegistrySession;
    ProjectArchive: string;
    Staged: Boolean;
    Bytes: TBytes;
    Stream: TFileStream;
    PriorEntry: TResolved;
  begin
    if not FindRegistryPackage(ANode.RegistryRecord, Package) then
      raise EFetchError.CreateFmt(
        'registry dependency "%s": selected record %s is unavailable',
        [ANode.Name, ANode.RegistryRecord]);
    Session := RegistrySession(ANode);
    AUnitDir := IncludeTrailingPathDelimiter(PlanModules) + ANode.Name;
    AArchive := ArchivePathForRef(PlanArchives, ANode.Name, skRegistry,
      ANode.Version);
    ForceDirectories(ExtractFileDir(AArchive));
    ProjectArchive := ArchivePathForRef(AArchivesRoot, ANode.Name, skRegistry,
      ANode.Version);
    Staged := False;
    if FileExists(ACacheArchive) then
      Staged := CopyFileContent(ACacheArchive, AArchive)
    else if FileExists(ProjectArchive)
       and ('sha256:' + SHA256File(ProjectArchive) = Package.ArchiveHash) then
    begin
      Staged := CopyFileContent(ProjectArchive, AArchive);
      if Staged then WriteLn('  reused committed archive for ', ANode.Name);
    end;
    if not Staged and (AObjectStore <> nil) then
      try
        Staged := AObjectStore.Materialize(Package.ArchiveHash, AArchive,
          PlanScratch);
        if Staged then
          WriteLn('  reused verified archive for ', ANode.Name,
            ' from the per-user cache');
      except
        on E: Exception do
          WriteLn(ErrOutput, 'warning: dependency archive cache lookup for ',
            ANode.Name, ' failed: ', E.Message, '; fetching from the registry');
      end;
    if not Staged then
    begin
      WriteLn('  fetching ', ANode.Name, '@', ANode.Version, ' from ',
        Session.Contact);
      Bytes := Session.FetchArchive(Package);
      AtomicWriteBytes(AArchive, PlanScratch, Bytes);
      if AObjectStore <> nil then
        try
          AObjectStore.Admit(AArchive, Package.ArchiveHash);
        except
          on E: Exception do
            WriteLn(ErrOutput, 'warning: dependency archive cache admission '
              + 'for ', ANode.Name, ' failed: ', E.Message,
              '; the project archive remains authoritative');
        end;
    end;
    Stream := TFileStream.Create(AArchive, fmOpenRead or fmShareDenyNone);
    try
      VerifyRegistryArtifact(Package, Stream);
    finally
      Stream.Free;
    end;
    AArchiveHash := Package.ArchiveHash;
    if not FileExists(ACacheArchive) then
    begin
      ForceDirectories(ExtractFileDir(ACacheArchive));
      if not CopyFileContent(AArchive, ACacheArchive) then
        raise EFetchError.CreateFmt(
          'failed to cache resolver candidate "%s"', [ANode.Name]);
    end;
    { The recorded URL is informational and kept while the record is. }
    if FindPriorLock(ANode, PriorEntry)
       and (PriorEntry.RegistryRecord = ANode.RegistryRecord)
       and (PriorEntry.ResolvedURL <> '') then
      AResolvedURL := PriorEntry.ResolvedURL
    else if Session.Acquired then
      AResolvedURL := Session.ArchiveURL(Package)
    else
      AResolvedURL := '';
  end;

  function SelectNode(const ANode: TResolveNode): TSelectionState;
  var
    Requirements: TResolverRequirementArray;
    Refs: TGitRefArray;
    Selection: TResolverSelection;
    k, Longest: Integer;
    AllSHA, HasWorkspaceConstraint: Boolean;
    WorkspaceVersion: string;
    PriorEntry: TResolved;
  begin
    Result := Default(TSelectionState);
    Result.Name := ANode.Name;
    Result.SourceIdentity := SourceKey(ANode.Dep, ANode.CustomSources);
    if AOffline and IsNetworkBacked(ANode) then
    begin
      SelectLockedNode(ANode, Result);
      Exit;
    end;
    if ANode.Dep.SrcKind = skRegistry then
    begin
      SelectRegistryNode(ANode, Result);
      Exit;
    end;
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

    { Only a full id can be proven or unambiguously compared: an
      abbreviated one could name a different, fork-only commit on a host
      that resolves prefixes. This holds beside named requirements too. }
    for k := 0 to High(ANode.Kinds) do
      if (ANode.Kinds[k] = vkCommitSha)
         and (Length(ANode.Specs[k]) <> GIT_OBJECT_ID_LENGTH) then
        raise EManifestError.CreateFmt(
          'dependency "%s": commit pin "%s" (required by %s) is abbreviated. '
          + '%s verifies that a pinned commit belongs to the repository and '
          + 'needs the full %d-character SHA.', [ANode.Name, ANode.Specs[k],
          ANode.Requirers[k], PROGRAM_NAME, GIT_OBJECT_ID_LENGTH]);

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
      Result.ReachableFrom := VerifyCommitPin(ANode, ANode.Specs[Longest]);
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
    try
      Refs := CachedRefs(ANode);
    except
      on E: Exception do
      begin
        if FindPriorLock(ANode, PriorEntry)
           and PriorSelectionSatisfies(ANode, PriorEntry) then
        begin
          { The fetch that follows must reproduce the locked archive bytes
            (ExpectedVerifyHash), so an unreachable advertisement cannot be
            used to smuggle different content in under the locked identity. }
          { A SHA requirement cannot fall back on an entry that never
            recorded a proof: without the listing it cannot be proven. }
          if NodeHasCommitPin(ANode)
             and not IsProvingRefName(PriorEntry.ReachableFrom) then
            raise;
          Result.RefName := PriorEntry.Version;
          Result.CommitSHA := PriorEntry.CommitSHA;
          Result.RefKind := PriorEntry.RefKind;
          Result.ReachableFrom := PriorEntry.ReachableFrom;
          WriteLn(ErrOutput, 'warning: tag resolution for ', ANode.Name,
            ' failed: ', E.Message, '; reusing verified lockfile identity');
          Exit;
        end;
        raise;
      end;
    end;
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
    Result.RefKind := SelectedRefKind(ANode, Refs, Selection);
    RejectMovedRef(ANode, Result);
    { A SHA requirement beside named ones selects the same commit as the
      named ref, but only through the listing's (possibly peeled) claim.
      It is proven exactly like a lone pin (ADR-0047). }
    for k := 0 to High(ANode.Kinds) do
      if ANode.Kinds[k] = vkCommitSha then
      begin
        Result.ReachableFrom := VerifyCommitPin(ANode, ANode.Specs[k]);
        Break;
      end;
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

  { A registry package's edges come from its signed record, never from the
    archive manifest (ADR-0051). }
  procedure AddRegistryRecordEdges(AIndex: Integer);
  var
    Package: TLWPTRegistryPackage;
    k, Target: Integer;
    Requirement: TDependency;
    Requirer: string;
  begin
    if not FindRegistryPackage(R.Nodes[AIndex].RegistryRecord, Package) then Exit;
    Requirer := R.Nodes[AIndex].Name + '@' + R.Nodes[AIndex].Version;
    for k := 0 to High(Package.Dependencies) do
    begin
      if not ValidRegistryPackageName(Package.Dependencies[k].Name) then
        raise EManifestError.CreateFmt(
          '"%s" requires registry package "%s", whose name cannot be '
          + 'installed: consumers accept only [a-z0-9][a-z0-9_-]{0,127}',
          [Requirer, Package.Dependencies[k].Name]);
      AConsumer.SessionForIdentity(Package.Dependencies[k].Origin,
        Package.Dependencies[k].Name, Requirer, Package.Origin);
      Requirement := Default(TDependency);
      Requirement.Name := Package.Dependencies[k].Name;
      Requirement.SrcOriginal := REGISTRY_SOURCE_PREFIX + ':'
        + Package.Dependencies[k].Name;
      Requirement.SrcKind := skRegistry;
      Requirement.SrcLocator := Package.Dependencies[k].Name;
      Requirement.RegistryOrigin := Package.Dependencies[k].Origin;
      Requirement.VersionSpec := Package.Dependencies[k].Version;
      if Valid(Requirement.VersionSpec, DefaultSemverOptions)
         = Requirement.VersionSpec then
        Requirement.VersionKind := vkSemverExact
      else
        Requirement.VersionKind := vkSemverRange;
      Target := AddRequirement(R, Requirement, R.Nodes[AIndex].Name, nil);
      EnqueueNode(Target);
    end;
  end;


  function SelectionSignature(const AStates: TSelectionStateArray): string;
  var k: Integer;
  begin
    Result := '';
    for k := 0 to High(AStates) do
      Result := Result + LowerCase(AStates[k].Name) + '='
        + AStates[k].RefName + '@' + AStates[k].CommitSHA
        + AStates[k].RegistryRecord + ';';
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
          {$IFDEF INSTALL_TESTING}
          if SameText(TestSeamValue('STALE_LOCAL_SNAPSHOT'),
             R.Nodes[k].Name) then
            R.Nodes[k].Hash := 'sha256:injected-stale-snapshot';
          {$ENDIF}
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
      {$IFDEF INSTALL_TESTING}
      if SameText(TestSeamValue('HALT_AFTER_MODULE_RETAIN'),
         R.Nodes[k].Name) then
        TerminateAbruptlyForTesting(87);
      {$ENDIF}
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
      {$IFDEF INSTALL_TESTING}
      if StrToIntDef(TestSeamValue('FAIL_PUBLISH_AFTER'), -1) = k + 1 then
        raise EFetchError.CreateFmt(
          'injected publication failure after package %d', [k + 1]);
      if StrToIntDef(TestSeamValue('HALT_PUBLISH_AFTER'), -1) = k + 1 then
        TerminateAbruptlyForTesting(86);
      {$ENDIF}
    end;
  end;

begin
  PlanRoot := MakeTmpPath(ATmpRoot, 'resolver-plan');
  PlanModules := PlanRoot + '/modules';
  PlanArchives := PlanRoot + '/archives';
  PlanScratch := PlanRoot + '/scratch';
  Previous := nil;
  RefCache := nil;
  VerifiedPins := TStringList.Create;
  SeenSignatures := TStringList.Create;
  RegistryWarnings := TStringList.Create;
  RegistryPackages := nil;
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
              R.Nodes[idx].RefKind := Previous[j].RefKind;
              R.Nodes[idx].ReachableFrom := Previous[j].ReachableFrom;
              R.Nodes[idx].RegistryOrigin := Previous[j].RegistryOrigin;
              R.Nodes[idx].RegistryRecord := Previous[j].RegistryRecord;
            end
            else
            begin
              Desired := nil;
              SetLength(Desired, 1);
              Desired[0] := SelectNode(R.Nodes[idx]);
              R.Nodes[idx].Version := Desired[0].RefName;
              R.Nodes[idx].CommitSHA := Desired[0].CommitSHA;
              R.Nodes[idx].RefKind := Desired[0].RefKind;
              R.Nodes[idx].ReachableFrom := Desired[0].ReachableFrom;
              R.Nodes[idx].RegistryOrigin := Desired[0].RegistryOrigin;
              R.Nodes[idx].RegistryRecord := Desired[0].RegistryRecord;
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
        if R.Nodes[idx].Dep.SrcKind = skRegistry then
          StageRegistryNode(R.Nodes[idx], CacheArchive, UnitDir, Archive,
            ArchiveHash, ResolvedURL)
        else if AOffline and IsNetworkBacked(R.Nodes[idx]) then
        begin
          if FileExists(CacheArchive) then
          begin
            { The candidate was staged for another dependency naming the same
              source and ref, so this node's own locked archive identity is
              checked before its bytes are copied or extracted (ADR-0048). }
            if not FindPriorLock(R.Nodes[idx], LockedEntry) then
              raise EVerifyError.CreateFmt(
                '[offline] dependency "%s" has no compatible lock entry',
                [R.Nodes[idx].Name]);
            if R.Nodes[idx].CommitSHA <> '' then
              StagedRefLabel := 'commit ' + LowerCase(FetchRef)
            else
              StagedRefLabel := 'ref ' + FetchRef;
            EnsureLockedArchiveIdentity(R.Nodes[idx].Name,
              Format('[offline] the archive staged for locked %s by '
                + 'another dependency does not match %s',
                [StagedRefLabel, LWPT.Core.LOCKFILE]),
              LockedEntry.ArchiveHash, 'sha256:' + SHA256File(CacheArchive),
              'Restore the committed archives, or run `' + PROGRAM_NAME
              + ' install` online to resolve the dependency again.');
            UnitDir := IncludeTrailingPathDelimiter(PlanModules)
              + R.Nodes[idx].Name;
            Archive := ArchivePathForRef(PlanArchives, R.Nodes[idx].Name,
              R.Nodes[idx].Dep.SrcKind, FetchRef);
            ForceDirectories(ExtractFileDir(Archive));
            if not CopyFileContent(CacheArchive, Archive) then
              raise EFetchError.CreateFmt(
                '[offline] failed to restore staged candidate "%s"',
                [R.Nodes[idx].Name]);
            ArchiveHash := 'sha256:' + SHA256File(Archive);
            ResolvedURL := LockedEntry.ResolvedURL;
          end
          else
          begin
            StageLockedArchive(R.Nodes[idx], FetchRef, UnitDir, Archive,
              ArchiveHash, ResolvedURL);
            ForceDirectories(ExtractFileDir(CacheArchive));
            if not CopyFileContent(Archive, CacheArchive) then
              raise EFetchError.CreateFmt(
                '[offline] failed to retain staged candidate "%s"',
                [R.Nodes[idx].Name]);
          end;
        end
        else if (R.Nodes[idx].Dep.SrcKind in [skGitHost, skURL])
           and FileExists(CacheArchive) then
        begin
          { The candidate may have been fetched for another dependency that
            names the same source and commit but has no locked identity of
            its own, so this node's lock is checked before the bytes are
            used. }
          ArchiveHash := 'sha256:' + SHA256File(CacheArchive);
          VerifyArchiveHash := ExpectedVerifyHash(R.Nodes[idx],
            VerifyContext);
          EnsureLockedArchiveIdentity(R.Nodes[idx].Name, VerifyContext,
            VerifyArchiveHash, ArchiveHash);
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
          ExpectedArchiveHash := ExpectedHashForSelection(R.Nodes[idx]);
          VerifyArchiveHash := ExpectedVerifyHash(R.Nodes[idx],
            VerifyContext);
          FetchToCache(R.Nodes[idx].Dep, FetchRef,
            PlanModules, PlanArchives, PlanScratch, AProjectRoot,
            ExpectedArchiveHash,
            R.Nodes[idx].CustomSources, AWorkspaces,
            AObjectStore,
            VerifyArchiveHash, VerifyContext,
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
            if R.Nodes[idx].Dep.SrcKind = skRegistry then
              RequireRegistryManifestIdentity(R.Nodes[idx], ExtractTmp);
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
          { A registry package's archive manifest contributes units only. }
          if R.Nodes[idx].Dep.SrcKind <> skRegistry then
          begin
            IsMember := NodeWorkspaceVersion(R.Nodes[idx], MemberVersion);
            if IsMember and (AConsumer <> nil) then
              CheckMemberRegistries(ChildMan, R.Nodes[idx].Name);
            for i := 0 to High(ChildMan.Deps) do
            begin
              { ADR-0051 decision 5: only the root and workspace members,
                whose trust roots the root owns, declare registry
                dependencies in this version. }
              if (ChildMan.Deps[i].SrcKind = skRegistry) and not IsMember then
                raise EManifestError.CreateFmt(
                  'dependency "%s" (%s source) declares registry dependency '
                  + '"%s" in its %s; registry dependencies may be declared '
                  + 'only in the root manifest and workspace members. '
                  + 'Declare "%s" in the root %s instead',
                  [R.Nodes[idx].Name, SourceKindToStr(R.Nodes[idx].Dep.SrcKind),
                   ChildMan.Deps[i].Name, MANIFEST_FILE,
                   ChildMan.Deps[i].Name, MANIFEST_FILE]);
              j := AddRequirement(R, ChildMan.Deps[i], R.Nodes[idx].Name,
                ChildMan.CustomSources);
              EnqueueNode(j);
            end;
          end;
        end;
        if R.Nodes[idx].Dep.SrcKind = skRegistry then
          AddRegistryRecordEdges(idx);
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
          and SameText(Desired[i].CommitSHA, R.Nodes[i].CommitSHA)
          and (Desired[i].RegistryRecord = R.Nodes[i].RegistryRecord);
        { The node may have been staged before a later round added a SHA
          requirement; the proof belongs to the complete requirement set. }
        if SameText(Desired[i].CommitSHA, R.Nodes[i].CommitSHA) then
          R.Nodes[i].ReachableFrom := Desired[i].ReachableFrom;
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

    if AOffline then
    begin
      ResolutionToResolved(R, OfflineResolved);
      VerifyOfflineAgainstLockfile(OfflineResolved, APriorLock);
    end;

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
    RegistryWarnings.Free;
    SeenSignatures.Free;
    VerifiedPins.Free;
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

procedure VerifyOfflineAgainstLockfile(const AResolved: array of TResolved;
  const ALockEntries: array of TResolved);

  function LockedCommitIdentity(const AEntry: TResolved): string;
  var Kind: TVersionKind; Value: string;
  begin
    Result := AEntry.CommitSHA;
    if Result <> '' then Exit;
    ParseVersionSpec(AEntry.Version, Kind, Value);
    if Kind = vkCommitSha then Result := Value;
  end;

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
  LockCommit: string;
begin
  for i := 0 to High(AResolved) do
  begin
    if not FindLockEntry(AResolved[i].Name, Lock) then
      raise EVerifyError.CreateFmt(
        '[offline] manifest graph reaches "%s" but the lockfile has no '
        + 'entry. Run `lwpt install` online to resolve the changed graph.',
        [AResolved[i].Name]);
    if ((Lock.SourceIdentity <> '')
        and (AResolved[i].SourceIdentity <> Lock.SourceIdentity))
       or ((Lock.SourceIdentity = '')
        and (AResolved[i].SrcOriginal <> Lock.SrcOriginal)) then
      raise EVerifyError.CreateFmt(
        '[offline] source or extraction policy changed for "%s". Run '
        + '`lwpt install` online to resolve the changed graph.',
        [AResolved[i].Name]);
    if (Lock.ConstraintFingerprint <> '')
       and (AResolved[i].ConstraintFingerprint <>
         Lock.ConstraintFingerprint) then
      raise EVerifyError.CreateFmt(
        '[offline] accumulated constraints changed for "%s". Run '
        + '`lwpt install` online to resolve the changed graph.',
        [AResolved[i].Name]);
    LockCommit := LockedCommitIdentity(Lock);
    if (AResolved[i].Version <> Lock.Version)
       or not SameText(AResolved[i].CommitSHA, LockCommit) then
      raise EVerifyError.CreateFmt(
        '[offline] locked resolution identity changed for "%s". Run '
        + '`lwpt install` online to resolve the changed graph.',
        [AResolved[i].Name]);
    if AResolved[i].Hash <> Lock.Hash then
      raise EVerifyError.CreateFmt(
        '[offline] tree hash mismatch for "%s": staged=%s lockfile=%s. '
        + 'The available source does not reconstruct the locked module tree.',
        [AResolved[i].Name, AResolved[i].Hash, Lock.Hash]);
    if AResolved[i].ArchiveHash <> Lock.ArchiveHash then
      raise EVerifyError.CreateFmt(
        '[offline] archive hash mismatch for "%s": staged=%s '
        + 'lockfile=%s. Restore verified locked content.',
        [AResolved[i].Name, AResolved[i].ArchiveHash, Lock.ArchiveHash]);
  end;
  for i := 0 to High(ALockEntries) do
    if not GraphHasEntry(ALockEntries[i].Name) then
      raise EVerifyError.CreateFmt(
        '[offline] lockfile has "%s" but the manifest graph does not '
        + 'reach it. Run `lwpt install` online to resolve the changed graph.',
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

{ ===========================================================================
  Registry lock state and committed proof documents (ADR-0051)
  =========================================================================== }
type
  TRegistryProofDocument = record
    Hash: string;
    Bytes: TBytes;
  end;
  TRegistryProofDocumentArray = array of TRegistryProofDocument;
  TRegistryConsumerStateArray = array of TLWPTRegistryConsumerState;

procedure AddRegistryProofDocument(var ADocuments: TRegistryProofDocumentArray;
  const ABytes: TBytes);
var Hash: string; k: Integer;
begin
  Hash := SHA256BytesPrefixed(ABytes);
  for k := 0 to High(ADocuments) do
    if ADocuments[k].Hash = Hash then Exit;
  SetLength(ADocuments, Length(ADocuments) + 1);
  ADocuments[High(ADocuments)].Hash := Hash;
  ADocuments[High(ADocuments)].Bytes := ABytes;
end;

function SortedRegistryRecords(const AEntries: array of TResolved;
  const AIdentity: string): TStringArray;
var Records: TStringList; k: Integer;
begin
  Records := TStringList.Create;
  try
    Records.Sorted := True;
    Records.Duplicates := dupIgnore;
    Records.CaseSensitive := True;
    for k := 0 to High(AEntries) do
      if (AEntries[k].SrcKind = skRegistry)
         and (AEntries[k].RegistryOrigin = AIdentity)
         and (AEntries[k].RegistryRecord <> '') then
        Records.Add(AEntries[k].RegistryRecord);
    SetLength(Result, Records.Count);
    for k := 0 to Records.Count - 1 do Result[k] := Records[k];
  finally
    Records.Free;
  end;
end;

function SameStringArrays(const ALeft, ARight: TStringArray): Boolean;
var k: Integer;
begin
  Result := Length(ALeft) = Length(ARight);
  if not Result then Exit;
  for k := 0 to High(ALeft) do
    if ALeft[k] <> ARight[k] then Exit(False);
end;

{ One per-origin table for every origin with selected packages. A selection
  proof and its documents are carried forward byte for byte unless the set
  of selected records changed, the pin changed, or the retained proof fails
  verification. Tables carry the lock's previous recorded accepted state;
  AMerged holds the merged maximum written when the lock changes. }
procedure PlanRegistryLockState(AConsumer: TLWPTRegistryConsumer;
  const AResolved, AOldLock: TResolvedArray; const AArchivesRoot: string;
  out ATables: TLWPTRegistryLockTableArray;
  out AMerged: TRegistryConsumerStateArray;
  out ADocuments: TRegistryProofDocumentArray);
var
  SessionIndex, k, n: Integer;
  Session: TLWPTRegistrySession;
  Identity, Reason: string;
  Records, OldRecords: TStringArray;
  OldTable, Table: TLWPTRegistryLockTable;
  HasOld, Carry: Boolean;
  Verified: TLWPTVerifiedRegistrySelection;
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
  UserState, Merged: TLWPTRegistryConsumerState;
  Bytes: TBytes;

  procedure AddCommitted(const AHash: string);
  begin
    AddRegistryProofDocument(ADocuments,
      ReadRegistryProofDocument(AArchivesRoot, AHash));
  end;

  procedure AddVerified(const APath: string);
  begin
    if not Session.DocumentBytes(APath, Bytes) then
      raise EFetchError.CreateFmt(
        'registry %s: verified proof document %s is unavailable',
        [Session.Alias, APath]);
    AddRegistryProofDocument(ADocuments, Bytes);
  end;

begin
  ATables := nil;
  AMerged := nil;
  ADocuments := nil;
  if AConsumer = nil then Exit;
  for SessionIndex := 0 to AConsumer.Count - 1 do
  begin
    Session := AConsumer.Sessions[SessionIndex];
    Identity := Session.Identity;
    if Identity = '' then Identity := Session.LockedIdentity;
    if Identity = '' then Continue;
    Records := SortedRegistryRecords(AResolved, Identity);
    if Length(Records) = 0 then Continue;
    OldRecords := SortedRegistryRecords(AOldLock, Identity);
    HasOld := False;
    OldTable := Default(TLWPTRegistryLockTable);
    for k := 0 to High(AConsumer.LockTables) do
      if (AConsumer.LockTables[k].Identity = Identity)
         and (AConsumer.LockTables[k].TrustKeyId = Session.Declaration.KeyId) then
      begin
        OldTable := AConsumer.LockTables[k];
        HasOld := True;
        Break;
      end;
    Carry := HasOld and SameStringArrays(Records, OldRecords)
      and VerifyCommittedRegistryProof(AArchivesRoot, OldTable, Session.Trust,
        Records, Verified, Reason);
    if Carry then
    begin
      Table := OldTable;
      AddCommitted(Table.Checkpoint);
      AddCommitted(Table.Signature);
      for k := 0 to High(Table.Rotations) do AddCommitted(Table.Rotations[k]);
      AddCommitted(Table.Snapshot);
      for k := 0 to High(Records) do AddCommitted(Records[k]);
    end
    else
    begin
      if not Session.Acquired then
        raise EFetchError.CreateFmt(
          'registry %s: the selection for %s changed, but no contact could '
          + 'be verified to prove it:%s', [Session.Alias, Identity,
          Session.Failures]);
      Checkpoint := InspectRegistryCheckpoint(Session.Verified.Proof.Checkpoint);
      Table := Default(TLWPTRegistryLockTable);
      Table.Identity := Identity;
      Table.TrustKeyId := Session.Declaration.KeyId;
      Table.KeyId := Checkpoint.KeyId;
      Table.Sequence := Checkpoint.Sequence;
      Table.Snapshot := Checkpoint.Snapshot;
      Table.Checkpoint := SHA256BytesPrefixed(Session.Verified.Proof.Checkpoint);
      Table.Signature := SHA256BytesPrefixed(Session.Verified.Proof.Signature);
      Table.PublishedAt := Checkpoint.PublishedAt;
      Table.ExpiresAt := Checkpoint.ExpiresAt;
      Table.Rotations := RegistryRotationHashes(Session.ProofRotations);
      AddRegistryProofDocument(ADocuments, Session.Verified.Proof.Checkpoint);
      AddRegistryProofDocument(ADocuments, Session.Verified.Proof.Signature);
      for k := 0 to High(Session.ProofRotations) do
      begin
        AddRegistryProofDocument(ADocuments, Session.ProofRotations[k].Document);
        AddRegistryProofDocument(ADocuments, Session.ProofRotations[k].OldSignature);
        AddRegistryProofDocument(ADocuments, Session.ProofRotations[k].NewSignature);
      end;
      AddVerified('snapshots/sha256/' + RegistryDigestHex(Table.Snapshot) + '.toml');
      for k := 0 to High(Records) do
        AddVerified('records/sha256/' + RegistryDigestHex(Records[k]) + '.toml');
      if HasOld then Table.Accepted := OldTable.Accepted;
    end;
    { AMerged is the maximum of the old lock, per-user state, and this
      install's acquisition; it is written only when the lock changes. }
    UserState := Default(TLWPTRegistryConsumerState);
    LoadRegistryConsumerState(Identity, Session.Declaration.KeyId, UserState);
    Merged := MergeRegistryAcceptedStates(UserState, Session.Accepted);
    if HasOld then Merged := MergeRegistryAcceptedStates(OldTable.Accepted, Merged);
    { The recorded accepted state is never behind the selection proof. }
    if Merged.State.Sequence < Table.Sequence then
    begin
      Merged.State.Origin := Identity;
      Merged.State.KeyId := Table.KeyId;
      Merged.State.Sequence := Table.Sequence;
      Merged.State.Snapshot := Table.Snapshot;
      Merged.State.CheckpointHash := Table.Checkpoint;
      Merged.State.PublishedAt := Table.PublishedAt;
      Merged.State.ExpiresAt := Table.ExpiresAt;
      Merged.State.ClockFloor := RegistryLaterTimestamp(Merged.State.ClockFloor,
        Table.PublishedAt);
      Merged.Rotations := Table.Rotations;
    end;
    if not HasOld or (Table.Accepted.State.Sequence = 0) then
      Table.Accepted := Merged;
    n := Length(ATables);
    SetLength(ATables, n + 1);
    ATables[n] := Table;
    SetLength(AMerged, n + 1);
    AMerged[n] := Merged;
  end;
end;

{ True when ARoot holds exactly ADocuments, each under its own hash. }
function RegistryProofsCurrent(const ARoot: string;
  const ADocuments: TRegistryProofDocumentArray): Boolean;
var
  Search: TSearchRec;
  Count, k: Integer;
  Known: Boolean;
begin
  if not DirectoryExists(ARoot) then Exit(Length(ADocuments) = 0);
  Count := 0;
  if SysUtils.FindFirst(ARoot + '/sha256/*', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        Known := False;
        for k := 0 to High(ADocuments) do
          if RegistryDigestHex(ADocuments[k].Hash) + '.toml' = Search.Name then
          begin
            Known := True;
            Break;
          end;
        if not Known then Exit(False);
        if SHA256File(ARoot + '/sha256/' + Search.Name)
           <> Copy(Search.Name, 1, 64) then Exit(False);
        Inc(Count);
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
  Result := Count = Length(ADocuments);
end;

{ Stages exactly the referenced proof set and publishes it in place of the
  committed directory, retaining the old one for rollback. Unreferenced
  documents leave with the old directory. }
procedure PublishRegistryProofs(const AArchivesRoot, ATmpRoot,
  ARollbackRoot: string; const ADocuments: TRegistryProofDocumentArray;
  out ABackup, APublishedPath: string);
var Root, Staged: string; k: Integer;
begin
  ABackup := '';
  APublishedPath := '';
  Root := IncludeTrailingPathDelimiter(AArchivesRoot) + REGISTRY_PROOFS_DIR;
  if RegistryProofsCurrent(Root, ADocuments) then Exit;
  if not AtomicRetainPath(Root, ARollbackRoot, 'registry-proofs', ABackup) then
    raise EExtractError.Create('failed to retain registry proof rollback copy');
  APublishedPath := Root;
  if Length(ADocuments) = 0 then
  begin
    if not AtomicRemovePath(Root) then
      raise EExtractError.Create('failed to remove unreferenced registry proofs');
    Exit;
  end;
  Staged := MakeTmpPath(ATmpRoot, 'registry-proofs');
  ForceDirectories(Staged + '/sha256');
  for k := 0 to High(ADocuments) do
    AtomicWriteBytes(Staged + '/sha256/' + RegistryDigestHex(ADocuments[k].Hash)
      + '.toml', ATmpRoot, ADocuments[k].Bytes);
  if not AtomicMoveDir(Staged, Root) then
    raise EExtractError.Create('failed to publish registry proof documents');
end;

{ A declaration without identity keeps the identity its contacts advertised
  when it was locked: taken from the lock entries of root dependencies that
  use the alias, else from the only lock table pinned to its key. }
procedure AssignLockedRegistryIdentities(AConsumer: TLWPTRegistryConsumer;
  const AMan: TManifest; const AOldLock: TResolvedArray);
var
  DeclarationIndex, DepIndex, LockIndex, Matches: Integer;
  Declaration: TLWPTRegistryDeclaration;
  Identity, Candidate: string;
begin
  for DeclarationIndex := 0 to High(AMan.Registries) do
  begin
    Declaration := AMan.Registries[DeclarationIndex];
    if Declaration.Identity <> '' then Continue;
    Identity := '';
    for DepIndex := 0 to High(AMan.Deps) do
    begin
      if (AMan.Deps[DepIndex].SrcKind <> skRegistry)
         or (RegistryAliasFor(AMan, AMan.Deps[DepIndex]) <> Declaration.Alias) then
        Continue;
      for LockIndex := 0 to High(AOldLock) do
        if SameText(AOldLock[LockIndex].Name, AMan.Deps[DepIndex].Name)
           and (AOldLock[LockIndex].SrcKind = skRegistry)
           and (AOldLock[LockIndex].RegistryOrigin <> '') then
          Identity := AOldLock[LockIndex].RegistryOrigin;
      if Identity <> '' then Break;
    end;
    if Identity = '' then
    begin
      Matches := 0;
      Candidate := '';
      for LockIndex := 0 to High(AConsumer.LockTables) do
        if AConsumer.LockTables[LockIndex].TrustKeyId = Declaration.KeyId then
        begin
          Inc(Matches);
          Candidate := AConsumer.LockTables[LockIndex].Identity;
        end;
      if Matches = 1 then Identity := Candidate;
    end;
    if Identity <> '' then
      AConsumer.SessionForAlias(Declaration.Alias).LockedIdentity := Identity;
  end;
end;

{ The shared transaction body. AManifestLines <> nil is the manifest-
  mutation flow (ADR-0019, `lwpt add` / `lwpt remove`): the previous
  lockfile is snapshotted right after the lock is acquired, the edited
  lwpt.toml is committed (atomically) after lockfile + cfg, and the
  lockfile diff prunes orphaned module trees + archives — all INSIDE
  the cross-process install lock, so a concurrent install can neither
  observe a manifest/lockfile mismatch nor race the prune deletions.
  AManifestLines = nil is the plain `lwpt install` flow.
  AAcceptMovedTags lets resolution re-pin a locked tag that the host now
  advertises at a different commit (`install --accept-moved-tags`). }
function RunInstallTransactionCore(const AContext: TManifestContext;
  const AMode: TInstallTransactionMode;
  const AManifestLines: TStringList;
  const AAcceptMovedTags: Boolean): TInstallTransactionResult;
var
  Man : TManifest;
  R   : TResolution;
  Resolved : TResolvedArray;
  LockEntries, OldLock : TResolvedArray;
  Lock : TInstallLock;
  ObjectStore : TLWPTImmutableObjectStore;
  ModulesRoot, ArchivesRoot, TmpRoot, CfgPath, LockPath, LockfilePath,
    ManifestPath, RollbackRoot, RecoveryFailures, RollbackFailures : string;
  i, j, k : Integer;
  Frozen, Offline : Boolean;
  FrozenLock: TResolved;
  LockFound: Boolean;
  LockedVersionKind: TVersionKind;
  LockedVersionValue, CurrentSourceIdentity,
    CurrentConstraintFingerprint: string;
  HasCommitConstraint: Boolean;
  PublicationPending: Boolean;
  LockfileBackup, CfgBackup, ManifestBackup: string;
  OrphanRollbacks: TPathRollbackArray;
  Consumer: TLWPTRegistryConsumer;
  RegistryTables: TLWPTRegistryLockTableArray;
  RegistryMerged: TRegistryConsumerStateArray;
  RegistryDocuments: TRegistryProofDocumentArray;
  ProofsBackup, ProofsPublished: string;
  RegistrySession: TLWPTRegistrySession;
  LockChanged: Boolean;
  {$IFDEF INSTALL_TESTING}
  TestCorruption: TStringList;
  {$ENDIF}
begin
  Man := AContext.Manifest;
  Frozen := AMode = itmFrozenVerify;
  Offline := AMode = itmOfflineMaterialize;

  ModulesRoot  := ResolveProjectPath(AContext.ProjectRoot, ResolveModulesDir(Man));
  ArchivesRoot := ResolveProjectPath(AContext.ProjectRoot, ResolveArchivesDir(Man));
  TmpRoot      := ResolveProjectPath(AContext.ProjectRoot, ResolveTmpDir(Man));
  CfgPath      := ResolveProjectPath(AContext.ProjectRoot, ResolveCfgFile(Man));
  LockPath     := ResolveProjectPath(AContext.ProjectRoot, INSTALL_LOCK);
  LockfilePath := ResolveProjectPath(AContext.ProjectRoot, LWPT.Core.LOCKFILE);
  ManifestPath := ResolveProjectPath(AContext.ProjectRoot, AContext.Path);

  Lock := TInstallLock.Create(LockPath);
  ObjectStore := nil;
  Consumer := nil;
  try
    PublicationPending := False;
    ProofsBackup := '';
    ProofsPublished := '';
    LockChanged := False;
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

    { A prior lock supplies content identity for cache lookup and a safe
      offline selection fallback. Mutation flows also use the same snapshot
      for their orphan diff after WriteLock replaces it. }
    OldLock := nil;
    if FileExists(LockfilePath) then
      OldLock := LoadLockfile(LockfilePath);
    if Offline and not FileExists(LockfilePath) then
      raise ELockfileError.CreateFmt(
        '[offline] lockfile not found at %s. Run `lwpt install` online '
        + 'to resolve and lock dependencies first.', [LockfilePath]);

    if not Frozen then
    begin
      Consumer := TLWPTRegistryConsumer.Create(Man,
        LoadRegistryLockTables(LockfilePath));
      AssignLockedRegistryIdentities(Consumer, Man, OldLock);
    end;

    if not Frozen then
      try
        ObjectStore := TLWPTImmutableObjectStore.Create(
          DependencyArchiveStoreRoot(ResolveCacheRoot), ResolveCacheRoot,
          DEPENDENCY_ARCHIVE_NAMESPACE);
      except
        on E: Exception do
          WriteLn(ErrOutput,
            'warning: per-user dependency archive cache is unavailable: ',
            E.Message, '; continuing with project-owned archives');
      end;

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
                             Man.Workspaces, OldLock, ObjectStore, Offline,
                             AAcceptMovedTags, Consumer);
      PublicationPending := True;
    end;
    WriteLn('resolved ', Length(R.Nodes), ' packages, no conflicts.');

    ResolutionToResolved(R, Resolved);

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
        Resolved[i].RefKind := FrozenLock.RefKind;
        Resolved[i].ReachableFrom := FrozenLock.ReachableFrom;
        WarnUnprovenPin('[frozen]', Resolved[i].Name, R.Nodes[i].Kinds,
          Resolved[i].SrcKind, FrozenLock);
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

    if Offline then
      VerifyOfflineAgainstLockfile(Resolved, OldLock)
    else
    begin
      PlanRegistryLockState(Consumer, Resolved, OldLock, ArchivesRoot,
        RegistryTables, RegistryMerged, RegistryDocuments);
      { Decision 11: acquisition progress alone never rewrites the lock.
        Any lock change carries every origin's merged accepted state. }
      LockChanged := RenderedLockText(Resolved, RegistryTables)
        <> ReadFileText(LockfilePath);
      if LockChanged then
      begin
        for i := 0 to High(RegistryTables) do
          RegistryTables[i].Accepted := RegistryMerged[i];
        WriteLock(LockfilePath, TmpRoot, Resolved, RegistryTables);
      end;
      PublishRegistryProofs(ArchivesRoot, TmpRoot, RollbackRoot,
        RegistryDocuments, ProofsBackup, ProofsPublished);
    end;
    {$IFDEF INSTALL_TESTING}
    if (not Offline) and (TestSeamValue('FAIL_AFTER_LOCK_WRITE') = '1') then
    begin
      if TestSeamValue('CORRUPT_ROLLBACK_FOR') <> '' then
        for i := 0 to High(R.Nodes) do
          if SameText(R.Nodes[i].Name,
               TestSeamValue('CORRUPT_ROLLBACK_FOR'))
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
    {$ENDIF}
    WriteCfg(CfgPath, TmpRoot, Resolved, Man, AContext.ProjectRoot);
    if Offline then
      WriteLn('[offline] restored ', Length(Resolved),
        ' packages and wrote ', CfgPath, '; ', LWPT.Core.LOCKFILE,
        ' was left unchanged')
    else if LockChanged then
      WriteLn('wrote ', LWPT.Core.LOCKFILE, ' (', Length(Resolved),
              ' packages) and ', CfgPath)
    else
      WriteLn(LWPT.Core.LOCKFILE, ' is current (', Length(Resolved),
              ' packages); wrote ', CfgPath);

    if AManifestLines <> nil then
    begin
      { Retain stale committed graph paths before publishing the manifest.
        The manifest is the last fallible publication step: after it lands,
        only best-effort tmp cleanup remains. }
      RetainOrphanedPackagePaths(OldLock, Resolved, ModulesRoot,
        ArchivesRoot, RollbackRoot, OrphanRollbacks);
      {$IFDEF INSTALL_TESTING}
      if TestSeamValue('FAIL_AFTER_ORPHAN_RETAIN') = '1' then
        raise EExtractError.Create(
          'injected failure after orphan retention');
      {$ENDIF}
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
    if ProofsBackup <> '' then AtomicDiscardRetainedPath(ProofsBackup);
    { Per-user accepted state advances on every successful acquisition,
      whether or not the lock changed. }
    if Consumer <> nil then
      for i := 0 to Consumer.Count - 1 do
      begin
        RegistrySession := Consumer.Sessions[i];
        if not RegistrySession.Acquired then Continue;
        try
          MergeRegistryConsumerState(RegistrySession.Identity,
            RegistrySession.Declaration.KeyId, RegistrySession.Accepted);
        except
          on E: Exception do
            WriteLn(ErrOutput, 'warning: per-user registry state for ',
              RegistrySession.Identity, ' was not updated: ', E.Message);
        end;
      end;
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
        if ProofsBackup <> '' then
          TryRollbackRestore(ProofsBackup, ProofsPublished,
            'failed to restore registry proofs', RollbackFailures);
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
    Consumer.Free;
    ObjectStore.Free;
    Lock.Free;
  end;
end;

function RunInstallTransaction(const AContext: TManifestContext; const AMode: TInstallTransactionMode; const AAcceptMovedTags: Boolean): TInstallTransactionResult;
begin
  Result := RunInstallTransactionCore(AContext, AMode, nil, AAcceptMovedTags);
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
  Result := RunInstallTransactionCore(AContext, itmMaterialize, AManifestLines,
    False);
end;

end.
