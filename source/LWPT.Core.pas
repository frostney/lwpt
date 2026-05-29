{ LWPT.Core — toolkit core: project identity constants, error hierarchy,
  manifest model, TOML reader/writer, semver-driven resolver, HTTPS
  fetch + tar extract, cfg emitter, build, test, format wrapper,
  export, repair. Every LWPT subcommand consumes this unit. }
unit LWPT.Core;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}
(* Nested-comment scanning lets documentation prose contain
   PLACEHOLDER_* literals (the values "{user}", "{repository}",
   "{ref}" — quoted here in the comment itself with the
   bracketed-name form preserved) inside Pascal { ... } blocks
   without prematurely closing them. The prior {$mode objfpc}
   tolerated this implicitly; delphi mode requires the explicit
   modeswitch directive above. *)

interface

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  Classes,
  Generics.Collections,
  Process,
  SysUtils,

  CLI.Prompts,
  HTTPClient,
  LWPT.Format,
  LWPT.GitProtocol,
  OrderedStringMap,
  Platform,
  StrUtils,
  TOML,
  zstream,

  Semver;

{ Project identity. Threaded through every site where the name appears
  on disk (filenames, dir names) or in prose (banners, error messages).
  See ADR-0001. Forward slashes in path constants are FPC-safe on
  every supported platform — FPC accepts them in path APIs on Windows. }
const
  PROGRAM_NAME    = 'lwpt';
  PROJECT_NAME    = 'LWPT';
  { Single source of truth for the version string. Derived at compile
    time from [package].version in the root lwpt.toml via the
    [prebuild] stamp-version hook (see scripts/stamp-version.pas).
    Drift between the binary's --version output and the manifest is
    structurally impossible: the include below IS the manifest's
    value at compile time. }
  {$I Version.inc}

  MANIFEST_FILE = PROGRAM_NAME + '.toml';
  LOCKFILE      = PROGRAM_NAME + '.lock';
  CFG_FILE      = PROGRAM_NAME + '.cfg';

  LWPT_DIR      = '.' + PROGRAM_NAME;
  MODULES_DIR   = LWPT_DIR + '/modules';
  ARCHIVES_DIR  = LWPT_DIR + '/archives';
  TMP_DIR       = LWPT_DIR + '/tmp';
  INSTALL_LOCK  = LWPT_DIR + '/install.lock';

  GITIGNORE_LINE = LWPT_DIR + '/tmp/';   { line written into .gitignore }

  { ADR-0009 placeholder strings for custom [sources] URL templates.
    Defined as constants so the syntax is changeable in one spot and
    doesn't get re-spelled in error messages / tests / docs out of
    sync with the renderer. }
  PLACEHOLDER_USER       = '{user}';
  PLACEHOLDER_REPOSITORY = '{repository}';
  PLACEHOLDER_REF        = '{ref}';

{ Error class hierarchy. Skeleton for v1; the full hardening pass
  uses these classes consistently across every multi-step operation
  and wraps them with atomic-via-tmp writes + file-lock concurrency
  control + crash-recovery. See ADR-0002 consequences. }
type
  ELWPTError = class(Exception)
  public
    Operation: string;
    Recovery: string;
  end;
  EFetchError       = class(ELWPTError);  { network / HTTP failures }
  EVerifyError      = class(ELWPTError);  { hash mismatches }
  EExtractError     = class(ELWPTError);  { archive parse / disk failures }
  ELockfileError    = class(ELWPTError);  { corrupt / missing lockfile }
  EManifestError    = class(ELWPTError);  { TOML errors, missing keys }
  EConcurrencyError = class(ELWPTError);  { install-lock contention }

{ Domain model. Exposed in interface so tests under source/*.Test.pas
  and tests/integration/ can construct + inspect parsed manifests and
  resolution graphs without going through Cmd* side-effects. Outside
  the project itself, consumers should still go through Cmd*. }
type
  TStringArray = array of string;

  { Source taxonomy after the matching ADR (ADR-0009).
      skGitHost — a git-host archive endpoint; SrcHost selects which
                  host's URL template to use (github / gitlab /
                  bitbucket). The slug shape is "owner/repo".
      skURL     — an arbitrary HTTPS tarball URL; LWPT GETs it and
                  pipes it through the standard gzip + ustar extract.
                  No tag resolution (the URL is already the locator).
      skLocal   — a filesystem path; recursively copied into the
                  modules tree. No version resolution.

    The earlier skRelease + skHttp kinds are removed: release assets
    are reachable via the URL form; tag resolution via git smart-HTTP
    works against ALL git hosts uniformly. }
  TSourceKind = (skGitHost, skURL, skLocal, skWorkspace);

  { Git-host identity. The string-based design (rather than an enum)
    is what lets users declare custom hosts in [sources] without a
    code change. Built-in identities are the three lower-case names
    'github' / 'gitlab' / 'bitbucket'; custom ones are whatever the
    user picked in [sources.<name>]. FetchURL + GitRepoURL look up
    the identity to find the base URL + URL template. }
  THostKind = (hkGitHub, hkGitLab, hkBitbucket, hkCustom);

  { A user-declared custom git host (ADR-0009 [sources] table). Both
    URL templates are full URLs with placeholders substituted at
    fetch time. The placeholder strings are PLACEHOLDER_USER,
    PLACEHOLDER_REPOSITORY, and PLACEHOLDER_REF (see the constants
    above) — `{user}`, `{repository}`, `{ref}`:

      {user}        — the owner/group part of "owner/repo"
      {repository}  — the repo part of "owner/repo"
      {ref}         — the resolved tag, branch, or commit SHA
                      (empty for the git template, which doesn't
                      need a ref to list info/refs)

    ArchiveTemplate is the .tar.gz download URL; GitTemplate is the
    base of the smart-HTTP info/refs endpoint (LWPT appends
    /info/refs?service=git-upload-pack to it for the tag listing). }
  TCustomSource = record
    Name            : string;    { e.g. 'gitea' }
    ArchiveTemplate : string;    { e.g. 'https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz' }
    GitTemplate     : string;    { e.g. 'https://git.example.com/{user}/{repository}.git' }
  end;
  TCustomSourceArray = array of TCustomSource;

  { A discovered workspace (ADR-0014 amendment "Workspaces"). The
    root manifest's [workspaces] include / exclude globs are expanded
    + matched against dirs containing their own lwpt.toml; each match
    becomes a TWorkspace keyed by its [package].name. The set is
    consulted at resolve-time for skWorkspace deps + auto-added to
    Result.Deps as virtual skLocal entries (per Q21 = auto-install). }
  TWorkspace = record
    Name    : string;     { from [package].name in the workspace's lwpt.toml }
    Path    : string;     { resolved absolute path to the workspace dir }
    Version : string;     { [package].version, used for `workspace:^X.Y.Z` checks }
  end;
  TWorkspaceArray = array of TWorkspace;

  { How a dep's version spec was authored (ADR-0009 §"Spec parsing"):
      vkSemverRange  — npm-style range like ^1.0.0, ~1.0, >=1.0,<2.0.
                       Resolves via ListRemoteTags + MaxSatisfying.
      vkSemverExact  — SemVer 2.0.0 version like 1.0.0 or 2.3.4-beta.
                       Resolves via tag-list lookup, trying both
                       <spec> and v<spec> to cover both repo
                       tagging conventions.
      vkCommitSha    — 7-40 hex chars. Fetched at the archive-at-sha
                       endpoint for the host. No tag lookup.
      vkLiteralTag   — anything else, including v1.0.0 (which is NOT
                       a SemVer 2.0.0 version — it's a Git tag string
                       that happens to contain one). Literal tag-list
                       lookup, no SemVer logic.
      vkNone         — no version spec (legal for skLocal + skURL). }
  TVersionKind = (vkNone, vkSemverRange, vkSemverExact,
                  vkCommitSha, vkLiteralTag);

  TDependency = record
    Name        : string;
    SrcOriginal : string;        { the manifest's source string, verbatim
                                   (e.g. "gitlab:org/repo", "../c") }
    SrcKind     : TSourceKind;
    SrcHost     : THostKind;     { skGitHost only }
    SrcHostName : string;        { hkCustom only — the [sources.<name>] key }
    SrcLocator  : string;        { owner/repo (git-host), full URL, or path
                                   (post-prefix-strip) }
    VersionSpec : string;        { raw spec authored by the user; '' for vkNone }
    VersionKind : TVersionKind;
    { Per-dep file selection — formatter-mirror semantics
      mirroring ADR-0007's [format].include / [format].exclude.
      Both arrays are post-extraction globs relative to the dep's
      modules dir. Neither set → keep every file. Replaces the
      earlier single-subdir field (the SrcSubDir = "src/foo" form
      becomes IncludeGlobs = ["src/foo/**"] under the new design). }
    IncludeGlobs : TStringArray;
    ExcludeGlobs : TStringArray;
  end;

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

  { A single lifecycle hook entry (ADR-0011). The Script field is
    required; Args is optional (and may be empty). The Inputs/Output
    pair is the staleness gate — both present => skip when output is
    fresher than every input; both absent => run unconditionally;
    exactly one present => manifest-load error. The Name is the
    free-form hook key from the manifest (TOML bare-key syntax) and
    drives log lines like "  running [prebuild] embed-testing-library". }
  THook = record
    Name   : string;
    Script : string;
    Args   : array of string;
    Inputs : array of string;
    Output : string;
  end;
  THookArray = array of THook;

  TBuildTarget = record
    Name      : string;            { logical name, e.g. "cli" }
    Source    : string;            { entry-point .pas/.dpr path }
    Output    : string;            { optional output binary path }
    PreBuild  : THookArray;        { per-target prebuild hooks (ADR-0011) }
    PostBuild : THookArray;        { per-target postbuild hooks (ADR-0011) }
  end;

  TManifest = record
    Name    : string;
    Version : string;
    Units   : array of string;   { source/unit dirs to expose as -Fu }
    Includes: array of string;   { -Fi dirs }
    FpcFlags: array of string;
    Deps    : array of TDependency;
    Targets : array of TBuildTarget;  { [targets] entries for `lwpt build` }
    VersionIncOut : string;      { [version] output: generated .inc path }
    VersionPrefix : string;      { [version] constant prefix, default BAKED }
    { Whole-build/run lifecycle hooks (ADR-0011). Each pair fires
      around its named subcommand: PreInstall + PostInstall around
      `lwpt install`, etc. Loaded ONLY from root manifests; dep
      manifests' hook sections are silently dropped (supply-chain
      defense per ADR-0011 §"Supply-chain posture"). }
    PreInstall  : THookArray;
    PostInstall : THookArray;
    PreBuild    : THookArray;
    PostBuild   : THookArray;
    PreTest     : THookArray;
    PostTest    : THookArray;
    { User-defined run-scripts (ADR-0013). Any unrecognised top-
      level section with a `script` field becomes a callable
      script — `lwpt run <section-name>` invokes it. The structural
      shape is identical to a hook (script/args/inputs/output), so
      we reuse THook. Section names matching any LWPT subcommand
      are a hard error at manifest load; bare unrecognised sections
      without `script` keep the warn-and-drop policy. Root-only,
      same as hooks. }
    Scripts     : THookArray;
    { [lwpt] overrides; empty string means "use the default from the
      LWPT_DIR/MODULES_DIR/... constants in interface". }
    ModulesDirOverride  : string;
    ArchivesDirOverride : string;
    TmpDirOverride      : string;
    CfgFileOverride     : string;
    { [format] include / exclude — see ADR-0007. Both are arrays of
      globs (`*` / `**` / `?` plus literal paths). include is additive
      to [package].units; exclude subtracts from the resolved set. }
    FormatIncludes      : array of string;
    FormatExcludes      : array of string;
    { [sources.<name>] entries — user-declared custom git hosts that
      extend the built-in github/gitlab/bitbucket prefixes. See
      ADR-0009 §"Custom hosts". Empty for projects that only use the
      built-in hosts. }
    CustomSources       : TCustomSourceArray;
    { [workspaces] include / exclude — glob arrays defining the
      monorepo workspace globs. Same syntax as [format] globs
      (`*` / `**` / `?` + literal paths). Root-manifest only;
      dep manifests' [workspaces] are silently dropped (supply-
      chain stance). After discovery, Workspaces holds the resolved
      set; each matched workspace is also auto-added to Deps as a
      virtual skLocal entry. See ADR-0014 amendment "Workspaces". }
    WorkspaceIncludes   : array of string;
    WorkspaceExcludes   : array of string;
    Workspaces          : TWorkspaceArray;
  end;

{ Public API consumed by LWPT subcommands. Each subcommand wraps these
  in source/lwpt.pas, catching ELWPTError specifically for the formatted
  "<program> <subcommand>: ..." prefix + recovery hint. }
procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean);
function  CmdTest(const AManifestPath: string; AIncludeE2E: Boolean): Integer;
function  CmdBuild(const AManifestPath, ATargetName: string;
  ARelease, AClean: Boolean): Integer;
function  CmdFormat(const AManifestPath: string; ACheckOnly: Boolean): Integer;
procedure CmdRepair(const AManifestPath: string);
{ CmdInit (ADR-0010) — scaffolds a new LWPT project in the current
  directory. AYes skips interactive prompts and uses defaults derived
  from the directory name (npm init -y semantics). AForce overwrites
  an existing lwpt.toml; absent + manifest exists \u2192 hard error. }
procedure CmdInit(AYes, AForce: Boolean);
{ CmdRun (ADR-0013) — invokes a user-declared run-script from the
  manifest. AName is the section name (e.g. "deploy" for [deploy]
  script = "scripts/deploy.pas"). Empty AName lists all callable
  scripts. Subcommand-aliasing (`lwpt run install`) is handled by
  the CLI dispatcher and never reaches CmdRun. }
function  CmdRun(const AManifestPath, AName: string): Integer;

{ Testable internals. Pure (or close to it) and exposed for unit tests
  in source/LWPT.Core.Test.pas plus the integration tests under
  tests/integration/. NOT part of the consumer contract — callers outside
  the project should still go through Cmd*. Exposed in a later cycle; before that
  all internals were private and only observable via Cmd* side-effects,
  which is closer to integration-testing than unit-testing. }
function  LoadManifest(const APath: string): TManifest; overload;
{ AIsRoot=False is used by the resolver when reading a dependency
  manifest — hook sections + format scope + version-bake are read
  only from the root, because dep-declared hooks are the npm
  supply-chain attack vector and the other root-only sections
  describe project-level intent (ADR-0011 §"Supply-chain posture"). }
function  LoadManifest(const APath: string; AIsRoot: Boolean): TManifest; overload;
function  LoadLockfile(const APath: string): TResolvedArray;
{ — path-vs-glob matcher used for [dependencies].<name>.include /
  .exclude post-extraction file pruning. `**` consumes 0+ path
  segments; `*` and `?` are single-segment wildcards. Exposed for
  unit tests. }
function  MatchPathGlob(const APath, APattern: string): Boolean;
{ — apply include / exclude globs to a directory tree, deleting
  files outside the include set or inside the exclude set + reaping
  newly-empty subdirectories. ARoot itself is never removed.
  Neither set provided → no-op (the dep keeps every file). }
procedure ApplyIncludeExclude(const ARoot: string;
  const AIncludes, AExcludes: TStringArray);
{ source-spec parsers (ADR-0009). Exposed for unit tests in
  source/LWPT.Core.Test.pas; consumers of LWPT should not call these
  directly — go through LoadManifest. }
procedure ParseDependencySource(const ASource: string;
  out AKind: TSourceKind; out AHost: THostKind; out ALocator: string);
procedure ParseVersionSpec(const ASpec: string;
  out AKind: TVersionKind; out AValue: string);
function  ExtractArchive(const AArchivePath, ADest: string;
  const ASubDir: string = ''): Integer;
function  SHA256Hex(const AData: TBytes): string;
{ lockfile <-> resolution-graph cross-check. The same function
  CmdInstall --frozen runs after a fresh resolve; exposed so unit
  tests can exercise mismatch paths without standing up a network
  source. Raises EVerifyError on the first mismatch, with a message
  that names the dep and which side mismatched. }
procedure VerifyAgainstLockfile(const AResolved: array of TResolved;
  const ALockEntries: array of TResolved);

{ Cross-process install lock (ADR-0002 idempotency consequences).
  Construct at the top of a write-sensitive operation; destroy releases.
  EConcurrencyError if another process holds the lock.

  The lock file holds the holder's PID as a single line of text for
  diagnostics. File existence is also the stale-lock signal after a crash;
  `lwpt repair` clears it. }
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

{ Expand one [format] include/exclude pattern (literal path or glob)
  against the current working directory, appending matching files to
  AList. See ADR-0007 for the resolution algorithm. Exposed in v1 for
  unit tests; the full CmdFormat scope-composition (include + exclude
  + dedup) stays internal. }
procedure ExpandFormatPattern(const APattern: string; AList: TStringList;
  AErrorOnMissingLiteral: Boolean);

implementation

function FPCExecutable: string;
begin
  Result := GetEnvironmentVariable('LWPT_FPC');
  if Result = '' then
    Result := GetEnvironmentVariable('FPC');
  if Result <> '' then
    Exit;
  {$IFDEF MSWINDOWS}
  Result := 'fpc.exe';
  {$ELSE}
  Result := 'fpc';
  {$ENDIF}
end;

function InstantFPCExecutable: string;
begin
  Result := GetEnvironmentVariable('LWPT_INSTANTFPC');
  if Result = '' then
    Result := GetEnvironmentVariable('INSTANTFPC');
  if Result <> '' then
    Exit;
  {$IFDEF MSWINDOWS}
  Result := 'instantfpc.exe';
  {$ELSE}
  Result := 'instantfpc';
  {$ENDIF}
end;

procedure AddEnvUnitPathParameters(AParameters: TStrings);
var
  Raw, Part : string;
  StartAt, i : Integer;
begin
  Raw := GetEnvironmentVariable('LWPT_FPC_UNIT_PATHS');
  if Raw = '' then
    Exit;

  StartAt := 1;
  for i := 1 to Length(Raw) + 1 do
    if (i > Length(Raw)) or (Raw[i] = PathSeparator) then
    begin
      Part := Copy(Raw, StartAt, i - StartAt);
      if Part <> '' then
      begin
        AParameters.Add('-Fu' + Part);
        AParameters.Add('-Fi' + Part);
      end;
      StartAt := i + 1;
    end;
end;

function NativePath(const APath: string): string;
begin
  Result := APath;
  {$IFDEF MSWINDOWS}
  Result := StringReplace(Result, '/', DirectorySeparator, [rfReplaceAll]);
  {$ENDIF}
end;

{ ===========================================================================
  TOML helpers — manifest + lockfile readers used to drive their
  own partial reader (TTomlReader / TTomlNode record); after the
  TOML.pas conversion (port of GocciaScript's full TOML 1.1 parser)
  the readers go through TTOMLParser + the TTOMLNode class hierarchy.

  Helpers below provide the same conveniences as the old TomlGet /
  TomlStr but operate on TTOMLNode (class) instead of PTomlNode
  (record pointer). Lookup uses TOrderedStringMap.TryGetValue which
  is O(1) average and preserves insertion order for iteration.
  =========================================================================== }
function TomlGet(ANode: TTOMLNode; const AKey: string): TTOMLNode;
begin
  Result := nil;
  if (ANode = nil) or (ANode.Kind <> tnkTable) then Exit;
  if not ANode.Children.TryGetValue(AKey, Result) then Result := nil;
end;

function TomlIsString(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and (ANode.Kind = tnkScalar)
        and (ANode.ScalarKind = tskString);
end;

function TomlIsInt(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and (ANode.Kind = tnkScalar)
        and (ANode.ScalarKind = tskInteger);
end;

function TomlIsTable(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil) and (ANode.Kind = tnkTable);
end;

function TomlIsArray(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and ((ANode.Kind = tnkArray) or (ANode.Kind = tnkArrayOfTables));
end;

function TomlStr(ANode: TTOMLNode;
  const AKey, ADefault: string): string;
var N: TTOMLNode;
begin
  N := TomlGet(ANode, AKey);
  if TomlIsString(N) then Result := N.ScalarText
  else Result := ADefault;
end;

function TomlInt(ANode: TTOMLNode; const AKey: string;
  ADefault: Int64): Int64;
var N: TTOMLNode;
begin
  N := TomlGet(ANode, AKey);
  if TomlIsInt(N) then Result := StrToInt64Def(N.ScalarText, ADefault)
  else Result := ADefault;
end;

{ ===========================================================================
  Domain model — types live in the interface above (exposed for
  testability); this section just adds helpers.
  =========================================================================== }
function SourceKindToStr(K: TSourceKind): string;
begin
  case K of
    skGitHost : Result := 'githost';
    skURL     : Result := 'url';
    skLocal   : Result := 'local';
  end;
end;

function HostKindToStr(H: THostKind): string;
begin
  case H of
    hkGitHub    : Result := 'github';
    hkGitLab    : Result := 'gitlab';
    hkBitbucket : Result := 'bitbucket';
    hkCustom    : Result := 'custom';
  end;
end;

{ Look up a custom source by name. Returns True + populates AOut on
  match; False otherwise. Linear scan — there's at most a handful of
  custom sources per project so the cost is irrelevant. }
function FindCustomSource(const ASources: TCustomSourceArray;
  const AName: string; out AOut: TCustomSource): Boolean;
var i: Integer;
begin
  for i := 0 to High(ASources) do
    if ASources[i].Name = AName then
    begin
      AOut := ASources[i];
      Exit(True);
    end;
  Result := False;
end;

{ Manifest-driven overrides; fall back to the default constants when
  the override slot is empty. The full path inside the project is
  always relative to the manifest's directory; callers that change
  the working directory (e.g. lwpt test compiling test binaries)
  must resolve these to absolute paths first. }
function ResolveModulesDir(const AMan: TManifest): string;
begin
  if AMan.ModulesDirOverride <> '' then Result := AMan.ModulesDirOverride
  else Result := MODULES_DIR;
end;

function ResolveArchivesDir(const AMan: TManifest): string;
begin
  if AMan.ArchivesDirOverride <> '' then Result := AMan.ArchivesDirOverride
  else Result := ARCHIVES_DIR;
end;

function ResolveTmpDir(const AMan: TManifest): string;
begin
  if AMan.TmpDirOverride <> '' then Result := AMan.TmpDirOverride
  else Result := TMP_DIR;
end;

function ResolveCfgFile(const AMan: TManifest): string;
begin
  if AMan.CfgFileOverride <> '' then Result := AMan.CfgFileOverride
  else Result := CFG_FILE;
end;

{ ───────────────────────────────────────────────────────────────────
  ParseDependencySource — turn the manifest's `source` string
  into (kind, host, locator). Rules per ADR-0009 §"Source parsing":

    "https://..."           → skURL, locator = the URL verbatim
    "./..." / "../..."      → skLocal, locator = the path
    "/..." (absolute)       → skLocal, locator = the path
    "~/..."                 → skLocal, locator = the path (HOME-relative)
    "local:..."             → skLocal, locator = the part after the colon
    "gitlab:owner/repo"     → skGitHost + hkGitLab, locator = "owner/repo"
    "bitbucket:owner/repo"  → skGitHost + hkBitbucket, locator = "owner/repo"
    "owner/repo"            → skGitHost + hkGitHub (default), locator = "owner/repo"
    anything else           → EManifestError naming the input + the expected shapes
  ─────────────────────────────────────────────────────────────────── }
function StartsWithStr(const AHaystack, ANeedle: string): Boolean; inline;
begin
  Result := (Length(AHaystack) >= Length(ANeedle))
        and (Copy(AHaystack, 1, Length(ANeedle)) = ANeedle);
end;

function LooksLikeWindowsAbsolutePath(const S: string): Boolean; inline;
begin
  Result := (Length(S) >= 3)
        and (S[1] in ['a'..'z', 'A'..'Z'])
        and (S[2] = ':')
        and ((S[3] = '/') or (S[3] = '\'));
end;

function LooksLikeOwnerRepo(const S: string): Boolean;
var i, Slashes: Integer;
begin
  Slashes := 0;
  for i := 1 to Length(S) do
    if S[i] = '/' then Inc(Slashes);
  Result := (Slashes = 1)
        and (Length(S) >= 3)
        and (S[1] <> '/') and (S[Length(S)] <> '/');
end;

{ Internal worker: parses a source string against the given custom-
  sources list. ACustomSources may be empty (no custom prefixes
  declared). APermissive controls what happens for an unknown prefix:
   - APermissive=False (LoadManifest): hard-error.
   - APermissive=True  (LoadLockfile): treat as hkCustom + carry
     the prefix as AHostName. Lockfile readers don't have manifest
     context but still need to round-trip — the resolvedURL carries
     the real fetch URL anyway. }
procedure ParseDependencySourceCore(const ASource: string;
  const ACustomSources: TCustomSourceArray; APermissive: Boolean;
  out AKind: TSourceKind; out AHost: THostKind;
  out AHostName: string; out ALocator: string);
var Colon: Integer; Prefix: string; Custom: TCustomSource;
begin
  AKind := skGitHost; AHost := hkGitHub; AHostName := ''; ALocator := '';
  if ASource = '' then
    raise EManifestError.Create('dependency source is empty');

  if StartsWithStr(ASource, 'https://')
     or StartsWithStr(ASource, 'http://') then
  begin
    AKind := skURL; ALocator := ASource; Exit;
  end;

  if StartsWithStr(ASource, './')
     or StartsWithStr(ASource, '../')
     or StartsWithStr(ASource, '/')
     or StartsWithStr(ASource, '~/')
     or LooksLikeWindowsAbsolutePath(ASource) then
  begin
    AKind := skLocal; ALocator := ASource; Exit;
  end;

  Colon := Pos(':', ASource);
  if Colon > 0 then
  begin
    Prefix := Copy(ASource, 1, Colon - 1);
    ALocator := Copy(ASource, Colon + 1, MaxInt);
    if Prefix = 'local' then
    begin
      AKind := skLocal; Exit;
    end
    else if Prefix = 'workspace' then
    begin
      { workspace:* / workspace:^X.Y.Z / workspace:X.Y.Z protocol per
        ADR-0014 amendment "Workspaces" (Q20=a, strict). The locator
        is the version spec (* | semver-range | exact). Resolved at
        BFS time against the root manifest's discovered workspaces;
        a workspace: ref with no matching workspace is a hard error
        ("workspace 'X' not found; available: ..."). Mirrors
        yarn / pnpm / bun's workspace: protocol. }
      AKind := skWorkspace; Exit;
    end
    else if Prefix = 'gitlab' then
    begin
      if not LooksLikeOwnerRepo(ALocator) then
        raise EManifestError.CreateFmt(
          'gitlab source "%s": expected "gitlab:owner/repo"', [ASource]);
      AKind := skGitHost; AHost := hkGitLab; Exit;
    end
    else if Prefix = 'bitbucket' then
    begin
      if not LooksLikeOwnerRepo(ALocator) then
        raise EManifestError.CreateFmt(
          'bitbucket source "%s": expected "bitbucket:owner/repo"', [ASource]);
      AKind := skGitHost; AHost := hkBitbucket; Exit;
    end
    else if Prefix = 'github' then
    begin
      { explicit github: prefix is accepted but redundant — owner/repo
        alone defaults to github (per ADR-0009). Accept it for users
        who want symmetry with the other prefixes. }
      if not LooksLikeOwnerRepo(ALocator) then
        raise EManifestError.CreateFmt(
          'github source "%s": expected "github:owner/repo" or "owner/repo"',
          [ASource]);
      AKind := skGitHost; AHost := hkGitHub; Exit;
    end
    else if FindCustomSource(ACustomSources, Prefix, Custom) then
    begin
      if not LooksLikeOwnerRepo(ALocator) then
        raise EManifestError.CreateFmt(
          'custom source "%s" (declared in [sources.%s]): '
          + 'locator must be "owner/repo" shape', [ASource, Prefix]);
      AKind := skGitHost; AHost := hkCustom; AHostName := Prefix; Exit;
    end
    else if APermissive then
    begin
      { LoadLockfile path: trust the recorded source string + URL.
        We don't have the manifest's [sources] context here, so we
        can't validate the prefix; record it for round-trip and let
        the verification step rely on hashes (which it does). }
      AKind := skGitHost; AHost := hkCustom; AHostName := Prefix; Exit;
    end
    else
      raise EManifestError.CreateFmt(
        'unknown source prefix "%s:" in "%s"; '
        + 'expected gitlab:/bitbucket:/local:, a [sources.<name>] '
        + 'entry in lwpt.toml, or no prefix (default github)',
        [Prefix, ASource]);
  end;

  { No colon, no path prefix, no URL — must be owner/repo on github. }
  if not LooksLikeOwnerRepo(ASource) then
    raise EManifestError.CreateFmt(
      'cannot parse dependency source "%s": expected "owner/repo", '
      + 'a prefix shape (gitlab:owner/repo, bitbucket:owner/repo, '
      + 'local:./path), an https:// URL, or a filesystem path '
      + '(./foo, ../foo, /abs/foo, ~/foo)', [ASource]);
  AKind := skGitHost; AHost := hkGitHub; ALocator := ASource;
end;

{ Public 4-arg form: backward-compatible signature used by tests +
  legacy callers that don't have a [sources] context. Equivalent
  to passing an empty custom-source list, strict mode. }
procedure ParseDependencySource(const ASource: string;
  out AKind: TSourceKind; out AHost: THostKind; out ALocator: string);
var HostName: string; Empty: TCustomSourceArray;
begin
  SetLength(Empty, 0);
  ParseDependencySourceCore(ASource, Empty, False,
    AKind, AHost, HostName, ALocator);
end;

{ ───────────────────────────────────────────────────────────────────
  ParseVersionSpec — classify a version spec from the manifest.
  Order of attempt per ADR-0009 §"Spec parsing":
    1. SemVer range (npm-style: ^ ~ > < = * etc., or contains space, ',', '||')
    2. SemVer 2.0.0 version (X.Y.Z[-pre][+build]); NO leading 'v'
    3. Commit SHA (7-40 hex chars)
    4. Literal tag/branch — anything else, INCLUDING v-prefixed strings
       (per semver.org, "v1.2.3" is not a SemVer; it's a Git tag string).
  Empty spec → vkNone.
  ─────────────────────────────────────────────────────────────────── }
function IsHexString(const S: string): Boolean;
var i: Integer;
begin
  Result := False;
  if (Length(S) < 7) or (Length(S) > 40) then Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9','a'..'f','A'..'F']) then Exit;
  Result := True;
end;

function LooksLikeSemverRange(const S: string): Boolean;
var i: Integer; First: Char;
begin
  if S = '' then Exit(False);
  First := S[1];
  if (First = '^') or (First = '~') or (First = '>') or (First = '<')
     or (First = '=') or (First = '*') then Exit(True);
  for i := 1 to Length(S) do
    if (S[i] = ' ') or (S[i] = ',') then Exit(True);
  Result := Pos('||', S) > 0;
end;

procedure ParseVersionSpec(const ASpec: string;
  out AKind: TVersionKind; out AValue: string);
begin
  AValue := ASpec;
  if ASpec = '' then begin AKind := vkNone; Exit; end;

  if LooksLikeSemverRange(ASpec) then
  begin
    if ValidRange(ASpec, DefaultSemverOptions) = '' then
      raise EManifestError.CreateFmt(
        'version spec "%s" looks like a SemVer range but does not parse',
        [ASpec]);
    AKind := vkSemverRange; Exit;
  end;

  { Pure SemVer 2.0.0 exact version: parses cleanly AND does not start
    with 'v'. The leading-'v' guard is the load-bearing distinction
    from a literal tag named "v1.0.0" (per semver.org, "v1.2.3" is
    NOT a SemVer). }
  if (Length(ASpec) > 0) and (ASpec[1] <> 'v') and (ASpec[1] <> 'V')
     and (Valid(ASpec, DefaultSemverOptions) <> '') then
  begin
    AKind := vkSemverExact; Exit;
  end;

  if IsHexString(ASpec) then
  begin
    AKind := vkCommitSha; Exit;
  end;

  AKind := vkLiteralTag;
end;

{ ===========================================================================
  Manifest loading
  =========================================================================== }
{ ───────────────────────────────────────────────────────────────────
  Manifest dep readers — both the bare-string shorthand
  `name = "<source>@<spec>"` AND the inline-table form
  `name = { source = "...", version = "...", subdir = "..." }`
  go through ParseDependencySource + ParseVersionSpec for consistency.
  The earlier inline-table shape (source = "github|gitlab|..." +
  separate repo/ref/tag/asset keys) is rejected with a migration
  hint pointing at ADR-0009.
  ─────────────────────────────────────────────────────────────────── }
procedure SplitBareDepString(const ABare: string;
  out ASource, ASpec: string);
var Last, i: Integer;
begin
  { Split on the LAST '@' so https://user:pass@host/x.tar.gz still
    parses correctly (URL form has no '@<spec>' tail). For non-URL
    shapes (slug, path), an '@' in the source itself is rare; the
    last-@ rule errs on the side of "spec is whatever's after the
    final @". }
  Last := 0;
  for i := Length(ABare) downto 1 do
    if ABare[i] = '@' then begin Last := i; Break; end;
  if Last = 0 then
  begin
    ASource := ABare;
    ASpec   := '';
  end
  else
  begin
    { URL form: the '@' is part of user-info, not a spec separator.
      Detect by scheme prefix — if the bare string starts with
      http(s)://, treat the whole thing as the source. }
    if StartsWithStr(ABare, 'https://') or StartsWithStr(ABare, 'http://') then
    begin
      ASource := ABare; ASpec := '';
    end
    else
    begin
      ASource := Copy(ABare, 1, Last - 1);
      ASpec   := Copy(ABare, Last + 1, MaxInt);
    end;
  end;
end;

procedure ParseBareDepString(const ABare: string;
  const ACustomSources: TCustomSourceArray; var ADep: TDependency);
var SrcStr, SpecStr: string;
begin
  SplitBareDepString(ABare, SrcStr, SpecStr);
  ADep.SrcOriginal := SrcStr;
  ParseDependencySourceCore(SrcStr, ACustomSources, False,
    ADep.SrcKind, ADep.SrcHost, ADep.SrcHostName, ADep.SrcLocator);
  ParseVersionSpec(SpecStr, ADep.VersionKind, ADep.VersionSpec);
  if (ADep.SrcKind = skLocal) and (SpecStr <> '') then
    raise EManifestError.CreateFmt(
      'dependency "%s": local source "%s" cannot have a version spec '
      + '("@%s" not allowed for local paths)',
      [ADep.Name, SrcStr, SpecStr]);
  { workspace:<spec> per ADR-0014 amendment "Workspaces". The
    ParseDependencySourceCore call above set SrcKind=skWorkspace and
    parked the trailing spec (`*`, `^0.1.0`, etc) in SrcLocator. Move
    it into the conventional VersionSpec field so the resolver's
    version-check logic finds it; SrcLocator is filled at resolve
    time with the discovered workspace's path. }
  if ADep.SrcKind = skWorkspace then
  begin
    if ADep.SrcLocator = '' then
      raise EManifestError.CreateFmt(
        'dependency "%s": workspace source needs a spec '
        + '(`workspace:*` or `workspace:^X.Y.Z`)', [ADep.Name]);
    ADep.VersionSpec := ADep.SrcLocator;
    if ADep.VersionSpec = '*' then
      ADep.VersionKind := vkNone
    else
      ParseVersionSpec(ADep.VersionSpec,
        ADep.VersionKind, ADep.VersionSpec);
    ADep.SrcLocator := '';  { filled by ResolveGraph }
  end;
end;

{ Read an array-of-strings TOML field from an inline-table node into
  the target dynamic array (cleared first). Skips non-string entries
  silently; defensive against future reader changes that might admit
  mixed-type arrays. Used by ParseTableDep for include / exclude. }
{ Forward-declare MatchSegment (defined further down with the
  formatter's glob walker) so the dep-pruning glob matcher above
  can use it. Same algorithm: `*` / `?` single-segment wildcards. }
function MatchSegment(const APattern, AName: string): Boolean; forward;

procedure ReadGlobArray(ANode: TTOMLNode; const AKey: string;
  var ATarget: TStringArray);
var
  ArrNode, Item: TTOMLNode;
  i, n: Integer;
begin
  SetLength(ATarget, 0);
  ArrNode := TomlGet(ANode, AKey);
  if not TomlIsArray(ArrNode) then Exit;
  for i := 0 to ArrNode.Items.Count - 1 do
  begin
    Item := ArrNode.Items[i];
    if TomlIsString(Item) then
    begin
      n := Length(ATarget);
      SetLength(ATarget, n + 1);
      ATarget[n] := Item.ScalarText;
    end;
  end;
end;

{ ─── Path-vs-glob matching for dep include/exclude ──────────────
  Splits both path and pattern at '/', then walks segment-by-segment.
  `**` consumes zero or more path segments (recursive matcher);
  `*` / `?` are single-segment wildcards via MatchSegment. Used by
  ApplyIncludeExclude below; the formatter's glob engine walks the
  filesystem and so isn't directly reusable here (we have the path
  in hand and just want a yes/no match). }
function SplitPathSegments(const APath: string): TStringArray;
var i, Start, n: Integer;
begin
  SetLength(Result, 0);
  Start := 1;
  for i := 1 to Length(APath) do
    if APath[i] = '/' then
    begin
      if i > Start then
      begin
        n := Length(Result); SetLength(Result, n + 1);
        Result[n] := Copy(APath, Start, i - Start);
      end;
      Start := i + 1;
    end;
  if Start <= Length(APath) then
  begin
    n := Length(Result); SetLength(Result, n + 1);
    Result[n] := Copy(APath, Start, MaxInt);
  end;
end;

function MatchPathGlob(const APath, APattern: string): Boolean;
var
  PathSegs, PatSegs: TStringArray;

  function DoMatch(APathIdx, APatIdx: Integer): Boolean;
  var i: Integer;
  begin
    while (APatIdx < Length(PatSegs))
          and (PathSegs <> nil) and (APathIdx <= High(PathSegs)) do
    begin
      if PatSegs[APatIdx] = '**' then
      begin
        { ** at the end of the pattern matches every remaining path
          segment unconditionally. Otherwise try matching it against
          0..N path segments and recurse on the rest. }
        if APatIdx = High(PatSegs) then Exit(True);
        for i := APathIdx to Length(PathSegs) do
          if DoMatch(i, APatIdx + 1) then Exit(True);
        Exit(False);
      end;
      if not MatchSegment(PatSegs[APatIdx], PathSegs[APathIdx]) then
        Exit(False);
      Inc(APathIdx); Inc(APatIdx);
    end;
    { Trailing ** in the pattern matches a zero-segment tail. }
    while (APatIdx < Length(PatSegs)) and (PatSegs[APatIdx] = '**') do
      Inc(APatIdx);
    Result := (APathIdx >= Length(PathSegs))
          and (APatIdx >= Length(PatSegs));
  end;

begin
  PathSegs := SplitPathSegments(APath);
  PatSegs  := SplitPathSegments(APattern);
  Result := DoMatch(0, 0);
end;

{ Apply [dependencies].<name>.include / .exclude globs against the
  freshly-extracted modules tree under ARoot. Files outside the
  include set OR inside the exclude set are deleted; empty dirs are
  reaped after the file pass. ARoot itself is never deleted. }
function PathMatchesAny(const ARelPath: string;
  const AGlobs: TStringArray): Boolean;
var i: Integer;
begin
  for i := 0 to High(AGlobs) do
    if MatchPathGlob(ARelPath, AGlobs[i]) then Exit(True);
  Result := False;
end;

procedure ApplyIncludeExclude(const ARoot: string;
  const AIncludes, AExcludes: TStringArray);

  function ShouldKeep(const ARelPath: string): Boolean;
  begin
    Result := True;
    if (Length(AIncludes) > 0) and not PathMatchesAny(ARelPath, AIncludes) then
      Exit(False);
    if PathMatchesAny(ARelPath, AExcludes) then
      Exit(False);
  end;

  function WalkAndPrune(const ADir, ARelDir: string): Integer;
  var SR: TSearchRec; Base, RelPath, Full: string;
  begin
    Result := 0;
    Base := IncludeTrailingPathDelimiter(ADir);
    if FindFirst(Base + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if ARelDir = '' then RelPath := SR.Name
          else RelPath := ARelDir + '/' + SR.Name;
          Full := Base + SR.Name;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if WalkAndPrune(Full, RelPath) = 0 then
              RemoveDir(Full)
            else
              Inc(Result);
          end
          else if ShouldKeep(RelPath) then
            Inc(Result)
          else
            DeleteFile(Full);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
  end;

begin
  if (Length(AIncludes) = 0) and (Length(AExcludes) = 0) then Exit;
  WalkAndPrune(ARoot, '');
end;

function HasAnyKey(ANode: TTOMLNode; const AKeys: array of string): string;
var i: Integer;
begin
  for i := 0 to High(AKeys) do
    if TomlGet(ANode, AKeys[i]) <> nil then
      Exit(AKeys[i]);
  Result := '';
end;

procedure ParseTableDep(ANode: TTOMLNode;
  const ACustomSources: TCustomSourceArray; var ADep: TDependency);
var SrcStr, SpecStr, Legacy: string;
begin
  { Detect the earlier schema before doing anything else. The migration
    hint points at the ADR; the old shape is irrecoverable since
    "github"/"gitlab"/"bitbucket"/"release"/"local" as a literal
    source value has different semantics per the current schema (everything but
    "local" is now ambiguous with the new locator-as-source design). }
  Legacy := HasAnyKey(ANode, ['repo', 'ref', 'tag', 'asset', 'path']);
  if Legacy <> '' then
    raise EManifestError.CreateFmt(
      'dependency "%s": the earlier manifest shape (separate "%s" key '
      + 'alongside source) is no longer supported. The source string '
      + 'itself now carries the locator. Rewrite as a bare shorthand '
      + '"name = ''<source>@<version>''" or an inline table with just '
      + '{ source = "...", version = "...", subdir = "..." }. '
      + 'See ADR-0009 for the syntax reference.',
      [ADep.Name, Legacy]);

  SrcStr := TomlStr(ANode, 'source', '');
  if SrcStr = '' then
    raise EManifestError.CreateFmt(
      'dependency "%s": missing required "source" key', [ADep.Name]);

  { Detect the earlier source-kind literal values too — they're now
    invalid as a source string because they don't match any locator
    shape. The error message names the current replacement. }
  if (SrcStr = 'github') or (SrcStr = 'gitlab') or (SrcStr = 'bitbucket')
     or (SrcStr = 'release') or (SrcStr = 'http') then
    raise EManifestError.CreateFmt(
      'dependency "%s": source = "%s" is the earlier kind selector. '
      + 'In a later cycle the source value IS the locator. Rewrite as e.g. '
      + '"owner/repo" (github), "gitlab:owner/repo", '
      + '"bitbucket:owner/repo", or "https://example.com/x.tar.gz". '
      + 'See ADR-0009.',
      [ADep.Name, SrcStr]);

  SpecStr := TomlStr(ANode, 'version', '');
  ADep.SrcOriginal := SrcStr;
  ParseDependencySourceCore(SrcStr, ACustomSources, False,
    ADep.SrcKind, ADep.SrcHost, ADep.SrcHostName, ADep.SrcLocator);
  ParseVersionSpec(SpecStr, ADep.VersionKind, ADep.VersionSpec);
  if (ADep.SrcKind = skLocal) and (SpecStr <> '') then
    raise EManifestError.CreateFmt(
      'dependency "%s": local source "%s" cannot have a version spec '
      + '(got version = "%s")', [ADep.Name, SrcStr, SpecStr]);

  { earlier had a single `subdir` string for re-rooting extraction;
    that form is rejected with a migration hint. The new include /
    exclude shape covers the same use case and more (multiple
    subdirs, exclude patterns) and mirrors [format] semantics. }
  if TomlGet(ANode, 'subdir') <> nil then
    raise EManifestError.CreateFmt(
      'dependency "%s": the `subdir = "..."` field was removed in a later cycle. '
      + 'Use `include = ["<subdir>/**"]` instead. See ADR-0009.',
      [ADep.Name]);

  ReadGlobArray(ANode, 'include', ADep.IncludeGlobs);
  ReadGlobArray(ANode, 'exclude', ADep.ExcludeGlobs);
end;

{ ===========================================================================
  Build-lifecycle hooks (ADR-0011) — parse hook tables + execute them.

  Two surface shapes that produce one record type. Bare-string shorthand:
    build-version-inc = "scripts/stamp-version.pas"
  Inline-table form:
    build-version-inc = { script = "scripts/stamp-version.pas",
                          args   = ["--flag", "v"],
                          inputs = ["VERSION", "CHANGELOG.md"],
                          output = "source/Version.inc" }

  Inputs/Output are a paired option (both or neither) — declaring exactly
  one is a manifest-load error so the staleness gate has well-defined
  semantics. Hook keys are TOML bare keys (used in log lines, never become
  Pascal identifiers).
  =========================================================================== }
procedure ParseHookEntry(ANode: TTOMLNode; const AName, AContext: string;
  out AHook: THook);
var
  ArgsNode, InputsNode: TTOMLNode;
  i, n: Integer;
begin
  AHook := Default(THook);
  AHook.Name := AName;

  if TomlIsString(ANode) then
  begin
    { Bare-string shorthand: name = "scripts/foo.pas" }
    AHook.Script := ANode.ScalarText;
    Exit;
  end;

  if not TomlIsTable(ANode) then
    raise EManifestError.CreateFmt(
      '%s "%s": expected a script path (string) or an inline table '
      + '{ script = "..." [, args, inputs, output] }', [AContext, AName]);

  AHook.Script := TomlStr(ANode, 'script', '');
  if AHook.Script = '' then
    raise EManifestError.CreateFmt(
      '%s "%s": "script" field is required (path to InstantFPC '
      + 'script). See ADR-0011.', [AContext, AName]);

  ArgsNode := TomlGet(ANode, 'args');
  if TomlIsArray(ArgsNode) then
  begin
    SetLength(AHook.Args, ArgsNode.Items.Count);
    for i := 0 to ArgsNode.Items.Count - 1 do
      if TomlIsString(ArgsNode.Items[i]) then
        AHook.Args[i] := ArgsNode.Items[i].ScalarText
      else
        raise EManifestError.CreateFmt(
          '%s "%s": args[%d] must be a string', [AContext, AName, i]);
  end;

  InputsNode := TomlGet(ANode, 'inputs');
  if TomlIsArray(InputsNode) then
  begin
    n := InputsNode.Items.Count;
    SetLength(AHook.Inputs, n);
    for i := 0 to n - 1 do
      if TomlIsString(InputsNode.Items[i]) then
        AHook.Inputs[i] := InputsNode.Items[i].ScalarText
      else
        raise EManifestError.CreateFmt(
          '%s "%s": inputs[%d] must be a string', [AContext, AName, i]);
  end;

  AHook.Output := TomlStr(ANode, 'output', '');

  { Staleness-pair invariant: inputs + output are both present or
    both absent. Mismatched declaration is a hard error to keep the
    semantics unambiguous. }
  if (Length(AHook.Inputs) > 0) xor (AHook.Output <> '') then
    raise EManifestError.CreateFmt(
      '%s "%s": "inputs" and "output" are a paired option — both '
      + 'must be present (staleness-gated) or both absent '
      + '(always-run). See ADR-0011.', [AContext, AName]);
end;

procedure ParseHookSection(ANode: TTOMLNode; const ASectionName: string;
  out AHooks: THookArray);
var
  Pair: TTOMLNodeMap.TKeyValuePair;
  H: THook;
  n: Integer;
begin
  AHooks := nil;
  if not TomlIsTable(ANode) then Exit;
  for Pair in ANode.Children do
  begin
    ParseHookEntry(Pair.Value, Pair.Key, '[' + ASectionName + ']', H);
    n := Length(AHooks);
    SetLength(AHooks, n + 1);
    AHooks[n] := H;
  end;
end;

{ ===========================================================================
  Placeholder interpolation (ADR-0012) — expand {name} tokens in manifest
  string fields after parsing. Two-pass: (1) project + build context
  everywhere; (2) per-target context inside per-target hook fields.

  Syntax: single {ident} braces; doubled {{ }} escapes to a literal { }.
  Unknown placeholder name is a manifest-load error with the field path,
  the unknown name, and the available namespace listed in the message.
  =========================================================================== }
type
  { Placeholder namespace (ADR-0012, revised by ADR-0013):

      {package.name}   {package.version}    — always available, from [package]
      {item.name}      {item.source}        {item.output}
                                            — bindable inside [build].<entry> +
                                              per-entry hook fields ONLY
      {platform.os}    {platform.arch}      — always available, host platform

    Per ADR-0012 §"Resolution order": pass 1 expands item.Source +
    item.Output with HasItemName=True (the item's key is a static
    lookup; no circularity) but HasItemFields=False (source/output
    haven't been resolved yet, so they're not bindable in their OWN
    field). Pass 2 expands per-item hook fields with both flags
    True. Whole-build hooks set both flags False. }
  TPlaceholderCtx = record
    HasItemName   : Boolean;
    HasItemFields : Boolean;
    PackageName  : string;
    PackageVer   : string;
    ItemName     : string;
    ItemSource   : string;
    ItemOutput   : string;
    PlatformOS   : string;
    PlatformArch : string;
  end;

function PlaceholderNamespace(const ACtx: TPlaceholderCtx): string;
begin
  Result := '{package.name}, {package.version}, '
          + '{platform.os}, {platform.arch}';
  if ACtx.HasItemName   then Result := Result + ', {item.name}';
  if ACtx.HasItemFields then Result := Result
    + ', {item.source}, {item.output}';
end;

function ResolvePlaceholder(const AKey: string;
  const ACtx: TPlaceholderCtx; out AValue: string): Boolean;
begin
  Result := True;
  if AKey = 'package.name' then         AValue := ACtx.PackageName
  else if AKey = 'package.version' then AValue := ACtx.PackageVer
  else if AKey = 'platform.os' then     AValue := ACtx.PlatformOS
  else if AKey = 'platform.arch' then   AValue := ACtx.PlatformArch
  else if ACtx.HasItemName   and (AKey = 'item.name')   then AValue := ACtx.ItemName
  else if ACtx.HasItemFields and (AKey = 'item.source') then AValue := ACtx.ItemSource
  else if ACtx.HasItemFields and (AKey = 'item.output') then AValue := ACtx.ItemOutput
  else
    Result := False;
end;

function ExpandPlaceholders(const AInput: string;
  const ACtx: TPlaceholderCtx; const AFieldPath: string): string;
var
  i, n: Integer;
  Key, Value, Buf: string;
  CloseIdx: Integer;
begin
  Buf := '';
  i := 1;
  n := Length(AInput);
  while i <= n do
  begin
    { Doubled braces escape to a literal brace. {{name}} prints
      "{name}" verbatim — useful when documenting placeholder
      syntax inside a manifest comment-equivalent (a string). }
    if (i < n) and (AInput[i] = '{') and (AInput[i + 1] = '{') then
    begin
      Buf := Buf + '{'; Inc(i, 2); Continue;
    end;
    if (i < n) and (AInput[i] = '}') and (AInput[i + 1] = '}') then
    begin
      Buf := Buf + '}'; Inc(i, 2); Continue;
    end;

    if AInput[i] = '{' then
    begin
      CloseIdx := PosEx('}', AInput, i + 1);
      if CloseIdx = 0 then
        raise EManifestError.CreateFmt(
          '%s: unterminated placeholder near position %d in "%s". '
          + 'Use {{ to escape a literal "{".',
          [AFieldPath, i, AInput]);
      Key := Copy(AInput, i + 1, CloseIdx - i - 1);
      if not ResolvePlaceholder(Key, ACtx, Value) then
      begin
        if (not ACtx.HasItemName)
           and (Copy(Key, 1, 5) = 'item.') then
          raise EManifestError.CreateFmt(
            '%s: placeholder {%s} is only valid inside [build].<entry> '
            + 'fields or per-entry hook fields (whole-build / whole-run '
            + 'hooks have no build item in scope). Available here: %s.',
            [AFieldPath, Key, PlaceholderNamespace(ACtx)])
        else
          raise EManifestError.CreateFmt(
            '%s: unknown placeholder {%s} — available: %s.',
            [AFieldPath, Key, PlaceholderNamespace(ACtx)]);
      end;
      Buf := Buf + Value;
      i := CloseIdx + 1;
      Continue;
    end;

    Buf := Buf + AInput[i];
    Inc(i);
  end;
  Result := Buf;
end;

procedure ExpandStringArray(var A: array of string;
  const ACtx: TPlaceholderCtx; const AFieldPath: string);
var i: Integer;
begin
  for i := 0 to High(A) do
    A[i] := ExpandPlaceholders(A[i], ACtx, AFieldPath + '[' + IntToStr(i) + ']');
end;

procedure ExpandHookArray(var AHooks: THookArray;
  const ACtx: TPlaceholderCtx; const AFieldPath: string);
var
  i: Integer;
  HookPath: string;
begin
  for i := 0 to High(AHooks) do
  begin
    HookPath := AFieldPath + '.' + AHooks[i].Name;
    AHooks[i].Script := ExpandPlaceholders(AHooks[i].Script, ACtx,
      HookPath + '.script');
    AHooks[i].Output := ExpandPlaceholders(AHooks[i].Output, ACtx,
      HookPath + '.output');
    ExpandStringArray(AHooks[i].Args,   ACtx, HookPath + '.args');
    ExpandStringArray(AHooks[i].Inputs, ACtx, HookPath + '.inputs');
  end;
end;

{ Forward declaration: RunHooks is defined late in the file (next to
  the other build-cycle helpers) but is called from CmdInstall /
  CmdBuild / CmdTest, which sit above it. }
procedure RunHooks(const APhase: string; const AHooks: THookArray); forward;

function LoadManifest(const APath: string): TManifest;
begin
  { Public wrapper: most callers want root-manifest semantics (full
    parse, hook sections, unknown-section warnings, placeholder pass).
    The two-arg overload is for the resolver's dep-manifest walk
    (AIsRoot=False — supply-chain defense per ADR-0011 Q5). }
  Result := LoadManifest(APath, True);
end;

{ ===========================================================================
  Workspace discovery (ADR-0014 amendment "Workspaces"). Walks the root
  manifest's include / exclude globs, finds dirs that contain their own
  lwpt.toml, and reads each one's [package].name + [package].version. The
  caller (LoadManifest, root only) consumes the result for two purposes:
  (1) auto-adding each workspace as a virtual local-path dep on Result.Deps,
  (2) populating Result.Workspaces for resolve-time `workspace:` protocol
  lookups in child manifests.

  Duplicate workspace names are a hard error — two workspaces with the
  same [package].name would race for the same .lwpt/modules/<name>/ slot.
  =========================================================================== }
procedure CollectWorkspaceCandidates(const APattern, ABaseDir: string;
  ACandidates: TStringList); forward;
procedure DiscoverWorkspaces(const AIncludes, AExcludes: array of string;
  const ABaseDir: string; out AWorkspaces: TWorkspaceArray); forward;

{ Glob → candidate-dir expansion. The patterns are RELATIVE to ABaseDir
  (the dir of the root manifest). A pattern like "packages/*" matches
  every immediate child of packages/. Recursion via `**` is supported
  via the existing MatchPathGlob primitive. Implementation: enumerate
  every dir under ABaseDir, test each against the pattern. Slow for
  huge trees, fine for typical monorepos (tens of packages). }
procedure CollectWorkspaceCandidates(const APattern, ABaseDir: string;
  ACandidates: TStringList);
  procedure Walk(const ARel, AAbs: string);
  var SR: TSearchRec; Base, Child, Rel: string;
  begin
    Base := IncludeTrailingPathDelimiter(AAbs);
    if FindFirst(Base + '*', faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..')
           or ((SR.Attr and faDirectory) = 0)
           or (Length(SR.Name) = 0)
           or (SR.Name[1] = '.') then Continue;
        Child := Base + SR.Name;
        if ARel = '' then Rel := SR.Name else Rel := ARel + '/' + SR.Name;
        if MatchPathGlob(Rel, APattern) then
          ACandidates.Add(Child);
        { Recurse — the glob may match deeper (e.g. "apps/*/widgets"). }
        Walk(Rel, Child);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
begin
  Walk('', ABaseDir);
end;

procedure DiscoverWorkspaces(const AIncludes, AExcludes: array of string;
  const ABaseDir: string; out AWorkspaces: TWorkspaceArray);
var
  Candidates : TStringList;
  i, j, n : Integer;
  Manifest : string;
  Excluded : Boolean;
  RelPath : string;
  WS : TWorkspace;
  WSManifest : TManifest;
  k : Integer;
begin
  AWorkspaces := nil;
  Candidates := TStringList.Create;
  try
    for i := Low(AIncludes) to High(AIncludes) do
      CollectWorkspaceCandidates(AIncludes[i], ABaseDir, Candidates);
    { Dedupe + sort for deterministic ordering across runs. }
    Candidates.Sorted := True;
    Candidates.Duplicates := dupIgnore;
    { Re-add via temp list to apply dedupe. }
    n := Candidates.Count;

    for i := 0 to n - 1 do
    begin
      { Only dirs containing a lwpt.toml are workspaces. Silently skip
        others (a parallel directory tree, fixture, etc, that happened
        to match the glob but doesn't carry a manifest). }
      Manifest := IncludeTrailingPathDelimiter(Candidates[i]) + MANIFEST_FILE;
      if not FileExists(Manifest) then Continue;

      { Exclude check — same glob format, relative to ABaseDir. }
      RelPath := Copy(Candidates[i],
        Length(IncludeTrailingPathDelimiter(ABaseDir)) + 1, MaxInt);
      RelPath := StringReplace(RelPath, '\', '/', [rfReplaceAll]);
      Excluded := False;
      for j := Low(AExcludes) to High(AExcludes) do
        if MatchPathGlob(RelPath, AExcludes[j]) then
        begin
          Excluded := True; Break;
        end;
      if Excluded then Continue;

      { Read the workspace's own manifest to pick up its name +
        version. AIsRoot=False — supply-chain stance applies the same
        way as transitive dep manifest reads. }
      try
        WSManifest := LoadManifest(Manifest, False);
      except
        on E: Exception do
          raise EManifestError.CreateFmt(
            '[workspaces] candidate %s: failed to load manifest (%s)',
            [Candidates[i], E.Message]);
      end;

      WS := Default(TWorkspace);
      WS.Name    := WSManifest.Name;
      WS.Path    := IncludeTrailingPathDelimiter(Candidates[i]);
      WS.Version := WSManifest.Version;

      if WS.Name = '' then
        raise EManifestError.CreateFmt(
          '[workspaces] candidate %s: lwpt.toml has no [package].name',
          [Candidates[i]]);

      { Duplicate-name detection — two workspaces with the same
        [package].name would race for .lwpt/modules/<name>/. }
      for k := 0 to High(AWorkspaces) do
        if AWorkspaces[k].Name = WS.Name then
          raise EManifestError.CreateFmt(
            '[workspaces] duplicate name "%s" found at %s and %s — '
            + 'workspace names must be unique', [WS.Name,
            AWorkspaces[k].Path, WS.Path]);

      n := Length(AWorkspaces);
      SetLength(AWorkspaces, n + 1);
      AWorkspaces[n] := WS;
    end;
  finally
    Candidates.Free;
  end;
end;

function LoadManifest(const APath: string; AIsRoot: Boolean): TManifest;
const
  { Recognised top-level sections — anything else either becomes a
    run-script (ADR-0013) when it carries a `script` field, OR
    fires a single warning to stderr otherwise. The list is the
    source of truth for "what does LWPT consume?".
    NOTE: 'generated' + 'targets' are NOT in this list — both were
    removed in earlier waves and now join the unknown-section
    policy on equal footing with [teddybear]. }
  KNOWN_SECTIONS: array[0..13] of string = (
    'package', 'dependencies', 'sources', 'build', 'version',
    'lwpt', 'format', 'workspaces',
    'preinstall', 'postinstall', 'prebuild', 'postbuild',
    'pretest', 'posttest');
  { Reserved section names — names that, if declared as a top-level
    section carrying a `script` field, raise a hard error at manifest
    load. Two classes:
      - LWPT subcommands (ADR-0013) — would make `lwpt run <name>`
        ambiguous with the built-in subcommand;
      - Known configuration section names — already first-class
        sections; using them as script names would be confusing
        (and structurally they never reach the script-detection path
        anyway because KNOWN_SECTIONS is checked first, but this
        list makes the intent explicit). 'run' itself is included
        because `lwpt run run` is the nonsense case. }
  RESERVED_SUBCOMMAND_NAMES: array[0..15] of string = (
    { subcommands }
    'install', 'build', 'format', 'test',
    'export', 'repair', 'init', 'run',
    { configuration section names — defensive: ensure 'workspaces',
      'package', 'dependencies' etc can NEVER end up registered as
      run-scripts even if a future refactor reorders KNOWN_SECTIONS
      checks. Per the ADR-0014 amendment "Workspaces" clarification:
      [workspaces] follows the same mechanism as [package] +
      [dependencies] (recognised, parsed for all manifests, never
      runnable). }
    'package', 'dependencies', 'sources', 'workspaces',
    'version', 'lwpt', 'format', 'generated');
var
  SL       : TStringList;
  Root, Deps, DepNode, ArrNode : TTOMLNode;
  TgtsNode, TgtNode, VerNode   : TTOMLNode;
  LwptCfgNode, FmtNode, ExclArr : TTOMLNode;
  SourcesNode, SourceEntry     : TTOMLNode;
  Parser   : TTOMLParser;
  Pair     : TTOMLNodeMap.TKeyValuePair;
  i, j, n  : Integer;
  D        : TDependency;
  T        : TBuildTarget;
  CS       : TCustomSource;
  Hook     : THook;
  Ctx      : TPlaceholderCtx;
  IsKnown  : Boolean;
  k        : Integer;
  TgtCtx   : TPlaceholderCtx;
  TgtPath  : string;
begin
  { Reset Result explicitly. Pascal's `function F: TRecord` returns
    by value via a hidden var argument in FPC's calling convention;
    when called as `ChildMan := LoadManifest(...)`, Result IS
    ChildMan's storage. Without this reset, dynamic-array fields
    like Result.Units accumulate across calls (the previous call's
    contents survive + the new parse appends on top). Bites
    transitive-resolver walks that load N child manifests. }
  Result := Default(TManifest);
  if not FileExists(APath) then
    raise EManifestError.CreateFmt('no manifest at %s', [APath]);

  SL := TStringList.Create;
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    SL.LoadFromFile(APath);
    Root := Parser.ParseDocument(SL.Text);
  finally
    SL.Free;
    Parser.Free;
  end;

  try
    Result.Name    := TomlStr(TomlGet(Root, 'package'), 'name', '');
    Result.Version := TomlStr(TomlGet(Root, 'package'), 'version', '0.0.0');
    if Result.Name = '' then
      Result.Name := TomlStr(Root, 'name', 'unnamed');

    { [package] units/includes arrays }
    ArrNode := TomlGet(TomlGet(Root, 'package'), 'units');
    if TomlIsArray(ArrNode) then
      for i := 0 to ArrNode.Items.Count - 1 do
        if TomlIsString(ArrNode.Items[i]) then
        begin
          n := Length(Result.Units);
          SetLength(Result.Units, n + 1);
          Result.Units[n] := ArrNode.Items[i].ScalarText;
        end;

    { [sources] — user-declared custom git hosts (ADR-0009). Each
      entry is an inline-table value:

        [sources]
        gitea = { archive = "...", git = "..." }

      Read BEFORE [dependencies] so dep parsing can reference them.
      Both URL templates are required; placeholders are {user},
      {repository}, {ref}. No prefab template-name shortcuts —
      spell out the URLs explicitly so there's one concept to learn. }
    SourcesNode := TomlGet(Root, 'sources');
    if TomlIsTable(SourcesNode) then
      for Pair in SourcesNode.Children do
      begin
        SourceEntry := Pair.Value;
        if not TomlIsTable(SourceEntry) then Continue;
        CS := Default(TCustomSource);
        CS.Name            := Pair.Key;
        CS.ArchiveTemplate := TomlStr(SourceEntry, 'archive', '');
        CS.GitTemplate     := TomlStr(SourceEntry, 'git',     '');
        if (CS.ArchiveTemplate = '') or (CS.GitTemplate = '') then
          raise EManifestError.CreateFmt(
            '[sources] %s: both "archive" and "git" URL templates '
            + 'are required. Templates use the placeholders %s, %s, '
            + '%s. See ADR-0009.',
            [CS.Name, PLACEHOLDER_USER, PLACEHOLDER_REPOSITORY,
             PLACEHOLDER_REF]);
        { The archive template needs {ref} (the git template doesn't
          — it points at the smart-HTTP info/refs endpoint, which
          we then list to discover refs). Catch missing {user} /
          {repository} / {ref} at manifest-load time so the error
          surfaces before a fetch attempt. }
        if (Pos(PLACEHOLDER_USER,       CS.ArchiveTemplate) = 0)
           or (Pos(PLACEHOLDER_REPOSITORY, CS.ArchiveTemplate) = 0)
           or (Pos(PLACEHOLDER_REF,        CS.ArchiveTemplate) = 0) then
          raise EManifestError.CreateFmt(
            '[sources] %s: archive template "%s" must contain all of '
            + '%s, %s, and %s placeholders',
            [CS.Name, CS.ArchiveTemplate,
             PLACEHOLDER_USER, PLACEHOLDER_REPOSITORY, PLACEHOLDER_REF]);
        if (Pos(PLACEHOLDER_USER,       CS.GitTemplate) = 0)
           or (Pos(PLACEHOLDER_REPOSITORY, CS.GitTemplate) = 0) then
          raise EManifestError.CreateFmt(
            '[sources] %s: git template "%s" must contain both '
            + '%s and %s placeholders',
            [CS.Name, CS.GitTemplate,
             PLACEHOLDER_USER, PLACEHOLDER_REPOSITORY]);
        { Reject names that would shadow the built-in prefixes; the
          built-ins win unconditionally to keep behavior predictable. }
        if (CS.Name = 'github') or (CS.Name = 'gitlab')
           or (CS.Name = 'bitbucket') or (CS.Name = 'local') then
          raise EManifestError.CreateFmt(
            '[sources] %s: name shadows a built-in prefix '
            + '(github / gitlab / bitbucket / local) and is rejected',
            [CS.Name]);
        n := Length(Result.CustomSources);
        SetLength(Result.CustomSources, n + 1);
        Result.CustomSources[n] := CS;
      end;

    { [dependencies] — each child is either a bare string in the
      ADR-0009 shorthand form `name = "<source>@<spec>"`, or an
      inline table `name = { source = "...", version = "...",
      subdir = "..." }`. The earlier shape (separate source/repo/ref
      keys with source = "github|gitlab|...") is hard-errored with
      a migration hint. }
    Deps := TomlGet(Root, 'dependencies');
    if TomlIsTable(Deps) then
      for Pair in Deps.Children do
      begin
        DepNode := Pair.Value;
        D := Default(TDependency);
        D.Name := Pair.Key;
        if TomlIsString(DepNode) then
          ParseBareDepString(DepNode.ScalarText, Result.CustomSources, D)
        else if TomlIsTable(DepNode) then
          ParseTableDep(DepNode, Result.CustomSources, D);
        j := Length(Result.Deps);
        SetLength(Result.Deps, j + 1);
        Result.Deps[j] := D;
      end;

    (* [build] — replaces the legacy [targets] section (ADR-0011 §
       "build-section rename"). Two recognised shapes:

         (1) Multi-entry: each child is one build item.
             [build.cli]
             source = "src/app.pas"
             output = "bin/app"
             prebuild  = { stamp-version = "scripts/stamp.pas" }
             postbuild = { sign = "scripts/sign.pas" }

         (2) Single-entry shorthand: [build] carries `source` (and
             optional `output`) DIRECTLY, no nested item name. The
             item defaults to [package].name; the single binary
             output defaults to "build/<package-name>" if absent.
             [build]
             source = "src/main.pas"

       Detection: if [build] has a child named `source`, we treat
       it as shorthand. Otherwise every child is a build item. *)
    { [workspaces] — monorepo workspace declaration (ADR-0014
      amendment "Workspaces"). Parsed for ALL manifests just like
      [package] and [dependencies] so a workspace's own lwpt.toml
      can declare its own nested workspaces (yarn-berry-style
      worktrees). Glob shape mirrors [format]'s include / exclude
      — same parser. Discovery walks the globs relative to the
      manifest's directory, intersects with dirs containing a valid
      lwpt.toml, then auto-adds each match as a virtual local-path
      dep on Result.Deps (Q21=auto-install). Explicit entries
      already-present in [dependencies] with the same name take
      precedence (skip auto-add for those — the user has overriden).

      Supply-chain note: unlike hooks (which fire arbitrary code on
      install + so are root-only), workspaces are code-organisation
      (local paths only, no arbitrary execution). Parsing them in
      child manifests is safe; the resolver enqueues their auto-
      added virtual deps the same way it would any explicit dep. }
    FmtNode := TomlGet(Root, 'workspaces');
    if TomlIsTable(FmtNode) then
    begin
      ExclArr := TomlGet(FmtNode, 'include');
      if TomlIsArray(ExclArr) then
        for i := 0 to ExclArr.Items.Count - 1 do
          if TomlIsString(ExclArr.Items[i]) then
          begin
            n := Length(Result.WorkspaceIncludes);
            SetLength(Result.WorkspaceIncludes, n + 1);
            Result.WorkspaceIncludes[n] := ExclArr.Items[i].ScalarText;
          end;
      ExclArr := TomlGet(FmtNode, 'exclude');
      if TomlIsArray(ExclArr) then
        for i := 0 to ExclArr.Items.Count - 1 do
          if TomlIsString(ExclArr.Items[i]) then
          begin
            n := Length(Result.WorkspaceExcludes);
            SetLength(Result.WorkspaceExcludes, n + 1);
            Result.WorkspaceExcludes[n] := ExclArr.Items[i].ScalarText;
          end;
      if Length(Result.WorkspaceIncludes) > 0 then
      begin
        DiscoverWorkspaces(Result.WorkspaceIncludes,
          Result.WorkspaceExcludes,
          ExtractFilePath(ExpandFileName(APath)),
          Result.Workspaces);
        { Auto-add: each discovered workspace becomes a virtual
          local-path dep on Result.Deps, UNLESS an explicit entry
          with the same name is already present (the explicit wins).
          Virtual entries get SrcOriginal='workspace:auto' for
          traceability + so the lockfile / log show the provenance. }
        for k := 0 to High(Result.Workspaces) do
        begin
          IsKnown := False;  { reusing IsKnown as 'already-in-deps' here }
          for j := 0 to High(Result.Deps) do
            if Result.Deps[j].Name = Result.Workspaces[k].Name then
            begin
              IsKnown := True; Break;
            end;
          if IsKnown then Continue;

          D := Default(TDependency);
          D.Name          := Result.Workspaces[k].Name;
          D.SrcOriginal   := 'workspace:auto';
          D.SrcKind       := skLocal;
          D.SrcLocator    := Result.Workspaces[k].Path;
          D.VersionKind   := vkNone;
          j := Length(Result.Deps);
          SetLength(Result.Deps, j + 1);
          Result.Deps[j] := D;
        end;
      end;
    end;

    TgtsNode := TomlGet(Root, 'build');
    if TomlIsTable(TgtsNode) then
    begin
      if TomlIsString(TomlGet(TgtsNode, 'source')) then
      begin
        { Single-entry shorthand. The item gets name = package
          name; output defaults to "build/<name>" when absent. }
        T := Default(TBuildTarget);
        T.Name   := Result.Name;
        T.Source := TomlStr(TgtsNode, 'source', '');
        T.Output := TomlStr(TgtsNode, 'output', '');
        if T.Output = '' then T.Output := 'build/' + Result.Name;
        ParseHookSection(TomlGet(TgtsNode, 'prebuild'),
          'build.prebuild', T.PreBuild);
        ParseHookSection(TomlGet(TgtsNode, 'postbuild'),
          'build.postbuild', T.PostBuild);
        SetLength(Result.Targets, 1);
        Result.Targets[0] := T;
      end
      else
        for Pair in TgtsNode.Children do
        begin
          TgtNode := Pair.Value;
          T := Default(TBuildTarget);
          T.Name := Pair.Key;
          if TomlIsString(TgtNode) then
            T.Source := TgtNode.ScalarText  { item-name = "path.pas" }
          else if TomlIsTable(TgtNode) then
          begin
            T.Source := TomlStr(TgtNode, 'source', '');
            T.Output := TomlStr(TgtNode, 'output', '');
            ParseHookSection(TomlGet(TgtNode, 'prebuild'),
              'build.' + T.Name + '.prebuild', T.PreBuild);
            ParseHookSection(TomlGet(TgtNode, 'postbuild'),
              'build.' + T.Name + '.postbuild', T.PostBuild);
          end;
          j := Length(Result.Targets);
          SetLength(Result.Targets, j + 1);
          Result.Targets[j] := T;
        end;
    end;

    { [version] — optional version-baking config }
    VerNode := TomlGet(Root, 'version');
    if TomlIsTable(VerNode) then
    begin
      Result.VersionIncOut := TomlStr(VerNode, 'output', '');
      Result.VersionPrefix := TomlStr(VerNode, 'prefix', 'BAKED');
    end
    else
      Result.VersionPrefix := 'BAKED';

    { [lwpt] — toolkit-state overrides. Empty string in the slot means
      "use the default" from the LWPT_DIR / MODULES_DIR / ... constants. }
    LwptCfgNode := TomlGet(Root, 'lwpt');
    if TomlIsTable(LwptCfgNode) then
    begin
      Result.ModulesDirOverride  := TomlStr(LwptCfgNode, 'modules-dir', '');
      Result.ArchivesDirOverride := TomlStr(LwptCfgNode, 'archives-dir', '');
      Result.TmpDirOverride      := TomlStr(LwptCfgNode, 'tmp-dir', '');
      Result.CfgFileOverride     := TomlStr(LwptCfgNode, 'cfg-file', '');
    end;

    { [format] — formatter scoping per ADR-0007. include adds globs to
      the format scope on top of [package].units; exclude subtracts.
      Both are glob arrays (`*` / `**` / `?` plus literal paths). }
    FmtNode := TomlGet(Root, 'format');
    if TomlIsTable(FmtNode) then
    begin
      ExclArr := TomlGet(FmtNode, 'include');
      if TomlIsArray(ExclArr) then
        for i := 0 to ExclArr.Items.Count - 1 do
          if TomlIsString(ExclArr.Items[i]) then
          begin
            n := Length(Result.FormatIncludes);
            SetLength(Result.FormatIncludes, n + 1);
            Result.FormatIncludes[n] := ExclArr.Items[i].ScalarText;
          end;
      ExclArr := TomlGet(FmtNode, 'exclude');
      if TomlIsArray(ExclArr) then
        for i := 0 to ExclArr.Items.Count - 1 do
          if TomlIsString(ExclArr.Items[i]) then
          begin
            n := Length(Result.FormatExcludes);
            SetLength(Result.FormatExcludes, n + 1);
            Result.FormatExcludes[n] := ExclArr.Items[i].ScalarText;
          end;
    end;

    { Whole-build/run hook sections (ADR-0011). Root manifests only —
      a dep manifest's hook sections are silently dropped to close the
      supply-chain attack vector (npm postinstall etc). The resolver
      still reads [dependencies] from dep manifests; everything below
      this point is root-only. }
    if AIsRoot then
    begin
      ParseHookSection(TomlGet(Root, 'preinstall'),  'preinstall',
        Result.PreInstall);
      ParseHookSection(TomlGet(Root, 'postinstall'), 'postinstall',
        Result.PostInstall);
      ParseHookSection(TomlGet(Root, 'prebuild'),    'prebuild',
        Result.PreBuild);
      ParseHookSection(TomlGet(Root, 'postbuild'),   'postbuild',
        Result.PostBuild);
      ParseHookSection(TomlGet(Root, 'pretest'),     'pretest',
        Result.PreTest);
      ParseHookSection(TomlGet(Root, 'posttest'),    'posttest',
        Result.PostTest);

      { Unrecognised-section policy (ADR-0011 / ADR-0013).
        Anything at the top level we don't recognise as a known
        section is either:
          (a) a run-script (ADR-0013) — when the section is a table
              with a `script` field. The section name becomes the
              `lwpt run <name>` invocation. Reserved subcommand
              names (install/build/format/test/export/repair/init/
              run) are a hard error here.
          (b) a typo / dead config — anything else. One-line warning
              to stderr; section silently dropped (the [teddybear]
              case). Includes the legacy [generated] + [targets]
              names removed in earlier waves. }
      for Pair in Root.Children do
      begin
        IsKnown := False;
        for k := Low(KNOWN_SECTIONS) to High(KNOWN_SECTIONS) do
          if Pair.Key = KNOWN_SECTIONS[k] then begin IsKnown := True; Break; end;
        if IsKnown then Continue;

        { Run-script detection: section is a table carrying a
          `script` field. Bare-string sections aren't possible in
          TOML (section values are always tables). }
        if TomlIsTable(Pair.Value)
           and TomlIsString(TomlGet(Pair.Value, 'script')) then
        begin
          for k := Low(RESERVED_SUBCOMMAND_NAMES) to High(RESERVED_SUBCOMMAND_NAMES) do
            if Pair.Key = RESERVED_SUBCOMMAND_NAMES[k] then
              raise EManifestError.CreateFmt(
                'section [%s] shadows the built-in subcommand and '
                + 'cannot be used as a run-script. Rename the section '
                + '(e.g. [%s-task]) or invoke the subcommand directly '
                + '(`lwpt %s`). See ADR-0013.',
                [Pair.Key, Pair.Key, Pair.Key]);
          { Parse as a script using the same shape as a hook entry. }
          ParseHookEntry(Pair.Value, Pair.Key,
            '[' + Pair.Key + ']', Hook);
          n := Length(Result.Scripts);
          SetLength(Result.Scripts, n + 1);
          Result.Scripts[n] := Hook;
        end
        else
          WriteLn(ErrOutput, 'warning: unrecognised section [',
            Pair.Key, '] — ignored');
      end;

      { Placeholder pass (ADR-0012). Two stages: project + build
        vars first across targets + whole-build hooks; then per-
        target vars across each target's per-target hook fields. The
        per-target source/output gets the project-only namespace
        (no recursive {target.*} placeholder in its own value). }
      Ctx := Default(TPlaceholderCtx);
      Ctx.PackageName  := Result.Name;
      Ctx.PackageVer   := Result.Version;
      Ctx.PlatformOS   := Platform.GetBuildOS;
      Ctx.PlatformArch := Platform.GetBuildArch;

      { Pass 1 over build items: item.Source / item.Output get
        access to {item.name} (the item's key is static) but NOT
        to {item.source} / {item.output} (those would be circular
        references to the field being resolved). The whole-build
        hooks below get neither. }
      for i := 0 to High(Result.Targets) do
      begin
        TgtCtx := Ctx;
        TgtCtx.HasItemName := True;
        TgtCtx.ItemName    := Result.Targets[i].Name;
        TgtPath := 'build.' + Result.Targets[i].Name;
        Result.Targets[i].Source :=
          ExpandPlaceholders(Result.Targets[i].Source, TgtCtx, TgtPath + '.source');
        Result.Targets[i].Output :=
          ExpandPlaceholders(Result.Targets[i].Output, TgtCtx, TgtPath + '.output');
      end;

      ExpandHookArray(Result.PreInstall,  Ctx, 'preinstall');
      ExpandHookArray(Result.PostInstall, Ctx, 'postinstall');
      ExpandHookArray(Result.PreBuild,    Ctx, 'prebuild');
      ExpandHookArray(Result.PostBuild,   Ctx, 'postbuild');
      ExpandHookArray(Result.PreTest,     Ctx, 'pretest');
      ExpandHookArray(Result.PostTest,    Ctx, 'posttest');
      { Run-scripts (ADR-0013). Same namespace as whole-build hooks:
        no item context. The script path / args may use {package.*}
        and {platform.*}; {item.*} is a hard error (no item in scope). }
      ExpandHookArray(Result.Scripts,     Ctx, 'run');

      { Pass 2 over build items: per-item hook fields get the
        FULL item namespace ({item.name} + {item.source} +
        {item.output} all bound to post-pass-1 values). Whole-
        build hooks ran with HasItemName=False so {item.*} was
        a hard error there. }
      for i := 0 to High(Result.Targets) do
      begin
        TgtCtx := Ctx;
        TgtCtx.HasItemName   := True;
        TgtCtx.HasItemFields := True;
        TgtCtx.ItemName      := Result.Targets[i].Name;
        TgtCtx.ItemSource    := Result.Targets[i].Source;
        TgtCtx.ItemOutput    := Result.Targets[i].Output;
        TgtPath := 'build.' + Result.Targets[i].Name;
        ExpandHookArray(Result.Targets[i].PreBuild,  TgtCtx,
          TgtPath + '.prebuild');
        ExpandHookArray(Result.Targets[i].PostBuild, TgtCtx,
          TgtPath + '.postbuild');
      end;
    end;
  finally
    Root.Free;
  end;
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

{ Build the download URL for a network-sourced dependency. }
{ Byte-for-byte file copy. Returns False on failure. }
function CopyFileContent(const ASrc, ADst: string): Boolean;
var SrcS, DstS: TFileStream;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  try
    SrcS := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
    try
      DstS := TFileStream.Create(ADst, fmCreate);
      try
        if SrcS.Size > 0 then DstS.CopyFrom(SrcS, SrcS.Size);
      finally
        DstS.Free;
      end;
    finally
      SrcS.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

{ Recursive directory copy. Used for the local source and for resolving
  directory symlinks during extraction. }
procedure CopyDirTree(const ASrc, ADst: string);
var SR: TSearchRec; S, D: string;
begin
  ForceDirectories(ADst);
  S := IncludeTrailingPathDelimiter(ASrc);
  D := IncludeTrailingPathDelimiter(ADst);
  if FindFirst(S + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        CopyDirTree(S + SR.Name, D + SR.Name)
      else
        CopyFileContent(S + SR.Name, D + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
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

function ProcessIdStr: string;
begin
  Result := IntToStr(GetProcessID);
end;

function MakeTmpPath(const ATmpRoot, AHint: string): string;
var Counter: Int64;
begin
  ForceDirectories(ATmpRoot);
  Counter := Round(Now * 1000000);   { microseconds since epoch-ish; unique enough }
  Result := IncludeTrailingPathDelimiter(ATmpRoot)
          + AHint + '.' + ProcessIdStr + '.' + IntToStr(Counter) + '.tmp';
end;

procedure WipeDir(const APath: string);
var SR: TSearchRec; Base, Full: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Full := Base + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          WipeDir(Full)
        else
          DeleteFile(Full);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
end;

function AtomicMoveFile(const ASrc, ADst: string): Boolean;
var DstDir: string;
begin
  if not FileExists(ASrc) then Exit(False);
  if FileExists(ADst) then DeleteFile(ADst);
  DstDir := ExtractFileDir(ADst);
  if DstDir <> '' then ForceDirectories(DstDir);
  Result := RenameFile(ASrc, ADst);
  if Result then Exit;
  { Rename failed — most commonly EXDEV (cross-filesystem). Fall back
    to copy-then-delete; the source is untouched until the copy is
    fully written, so a crash mid-copy still leaves the source intact
    for retry. }
  if CopyFileContent(ASrc, ADst) then
  begin
    DeleteFile(ASrc);
    Result := True;
  end;
end;

function AtomicMoveDir(const ASrc, ADst: string): Boolean;
var DstDir: string;
begin
  if not DirectoryExists(ASrc) then Exit(False);
  WipeDir(ADst);   { idempotent: tolerates the dst not existing }
  DstDir := ExtractFileDir(ExcludeTrailingPathDelimiter(ADst));
  if DstDir <> '' then ForceDirectories(DstDir);
  Result := RenameFile(ASrc, ADst);
  if Result then Exit;
  { EXDEV path: recursive copy + wipe-source. Slower, not strictly
    atomic against crashes mid-copy, but the partial-state isn't worse
    than what we started with — repair recovers. }
  ForceDirectories(ADst);
  CopyDirTree(ASrc, ADst);
  WipeDir(ASrc);
  Result := DirectoryExists(ADst);
end;

procedure EnsureDstDir(const ADst: string);
var D: string;
begin
  D := ExtractFileDir(ADst);
  if D <> '' then ForceDirectories(D);
end;

procedure AtomicWriteText(const ADst: string;
  const ATmpRoot: string; const AContent: TStringList);
var Tmp: string;
begin
  Tmp := MakeTmpPath(ATmpRoot, 'write-' + ExtractFileName(ADst));
  EnsureDstDir(ADst);
  AContent.SaveToFile(Tmp);
  if not AtomicMoveFile(Tmp, ADst) then
  begin
    DeleteFile(Tmp);
    raise EExtractError.CreateFmt(
      'atomic write of "%s" failed (could not commit tmp file)', [ADst]);
  end;
end;

procedure AtomicWriteBytes(const ADst, ATmpRoot: string; const ABytes: TBytes);
var Tmp: string; Stream: TFileStream;
begin
  Tmp := MakeTmpPath(ATmpRoot, 'write-' + ExtractFileName(ADst));
  EnsureDstDir(ADst);
  Stream := TFileStream.Create(Tmp, fmCreate);
  try
    if Length(ABytes) > 0 then Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
  if not AtomicMoveFile(Tmp, ADst) then
  begin
    DeleteFile(Tmp);
    raise EExtractError.CreateFmt(
      'atomic write of "%s" failed (could not commit tmp file)', [ADst]);
  end;
end;

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
    DeleteFile(FPath);   { release: file existence == lock held }
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
      'another lwpt install is in progress (lock holder PID: %s) — '
      + 'or the previous install crashed without releasing the lock. '
      + 'If you''re certain no other process is running, '
      + 'run `lwpt repair` to clear the stale lock.',
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
    DeleteFile(FPath);
    raise EConcurrencyError.Create(
      'another lwpt install is in progress. Try again when it finishes.');
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
    DeleteFile(FPath);
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
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'))
              + Copy(APath, 3, MaxInt)
  else
    Result := APath;
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

{ Detect: is APath a symlink (Unix) / junction or symlink (Windows)?
  Used by WipeInstalledDep to choose unlink-the-link vs recurse-and-delete. }
function IsDirSymlinkOrJunction(const APath: string): Boolean;
{$IFDEF UNIX}
var Info: BaseUnix.Stat;
begin
  if FpLstat(APath, Info) <> 0 then Exit(False);
  Result := FpS_ISLNK(Info.st_mode);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var Attrs: Cardinal;
begin
  Attrs := Windows.GetFileAttributesW(PWideChar(UnicodeString(APath)));
  if Attrs = $FFFFFFFF then Exit(False);  { INVALID_FILE_ATTRIBUTES }
  Result := (Attrs and $400) <> 0;  { FILE_ATTRIBUTE_REPARSE_POINT }
end;
{$ENDIF}

{ Remove the link itself; never follow into the target. }
function RemoveDirLink(const APath: string): Boolean;
{$IFDEF UNIX}
begin
  Result := FpUnlink(APath) = 0;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
begin
  { RemoveDirectoryW on a junction removes the reparse point (the link
    itself), NOT the target — this is the documented + safe call. }
  Result := Windows.RemoveDirectoryW(PWideChar(UnicodeString(APath)));
end;
{$ENDIF}

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

{ Wipe a previously-installed dep before re-installing. CRITICAL: if the
  prior install was a link (symlink/junction), we must unlink — never
  recurse, which would delete the link's TARGET (i.e. the source
  packages/ tree). pnpm's well-publicised data-loss incident was caused
  by exactly this footgun applied externally (PowerShell rm -rf on a
  junctioned node_modules). }
procedure WipeInstalledDep(const APath: string);
begin
  if IsDirSymlinkOrJunction(APath) then
  begin
    if not RemoveDirLink(APath) then
      raise EFetchError.CreateFmt(
        'failed to remove existing link at %s before re-install', [APath]);
    Exit;
  end;
  if not DirectoryExists(APath) then Exit;
  WipeDir(APath);
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
  ArchiveTag : string;
  EffectiveDep : TDependency;
  k : Integer;
  WSPath : string;
  AvailableNames : string;
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
    LocalPath := ExpandLocalPath(ADep.SrcLocator);
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
    WipeInstalledDep(AUnitDir);
    if (AProjectRoot <> '')
       and IsPathInside(AProjectRoot, LocalPath) then
    begin
      if not CreateDirLink(AUnitDir, LocalPath) then
      begin
        { Link creation failed (rare — Windows without junction
          permission, FS that doesn't support links, etc). Fall back
          to copy so the install still completes. The user sees both
          the failure cue and the recovery. }
        WriteLn(ErrOutput, '  warning: link failed for ', ADep.Name,
          '; falling back to copy');
        ForceDirectories(AUnitDir);
        CopyDirTree(LocalPath, AUnitDir);
        WriteLn('  copied ', ADep.Name, ' (link fallback)');
      end
      else
        WriteLn('  linked ', ADep.Name);
    end
    else
    begin
      { External-path dep — always copy. }
      ForceDirectories(AUnitDir);
      CopyDirTree(LocalPath, AUnitDir);
      WriteLn('  copied ', ADep.Name);
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

  { Archive filename uses the resolved ref for git-host sources, or
    a derived tag for URL sources (the URL's basename without the
    .tar.gz / .zip extension). }
  if ADep.SrcKind = skGitHost then
    ArchiveTag := AResolvedRef
  else
    ArchiveTag := 'url';
  AArchive := IncludeTrailingPathDelimiter(AArchivesRoot)
             + ADep.Name + '-' + ArchiveTag + '.tar.gz';
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

      OutName := NativePath(IncludeTrailingPathDelimiter(ADest) + RelName);

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
    ResolvedTarget := ExpandFileName(
      IncludeTrailingPathDelimiter(ExtractFileDir(PendingLinks[li].LinkPath))
      + PendingLinks[li].TargetName);
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
      DeleteFile(PendingLinks[li].LinkPath);
      CopyDirTree(ResolvedTarget, PendingLinks[li].LinkPath);
    end
    else
      WriteLn(ErrOutput, '  warning: link target missing, skipped: ',
              PendingLinks[li].FromRel, ' -> ', PendingLinks[li].TargetName);
  end;

  DeleteFile(TarPath);   { temp .tar no longer needed }
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
    SL.Add('# ' + LOCKFILE + ' - generated by ' + PROGRAM_NAME
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
procedure WriteCfg(const APath, ATmpRoot: string;
  const AResolved: array of TResolved; const AMan: TManifest);
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
          SL.Add('-Fu' + SubPath);
          SL.Add('-Fi' + SubPath);
        end;
      end
      else
      begin
        SL.Add('-Fu' + AResolved[i].UnitDir);
        SL.Add('-Fi' + AResolved[i].UnitDir);
      end;
      if AResolved[i].IncludeDir <> '' then
        SL.Add('-Fi' + AResolved[i].IncludeDir);
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
  This is the value that goes in lwpt.lock's computedHash. }
procedure CollectFiles(const ARoot, ARel: string; AList: TStringList);
var SR: TSearchRec; Path, RelPath: string;
begin
  Path := IncludeTrailingPathDelimiter(ARoot + ARel);
  if FindFirst(Path + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      RelPath := ARel + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        CollectFiles(ARoot, RelPath + PathDelim, AList)
      else
        AList.Add(RelPath);
    until FindNext(SR) <> 0;
    FindClose(SR);
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
  TWorkItem = record Dep: TDependency; RequiredBy: string; end;
var
  Queue : array of TWorkItem;
  Head  : Integer;
  i, idx: Integer;
  IsNew : Boolean;
  Item  : TWorkItem;
  UnitDir, Archive, ArchiveHash, ResolvedURL, ChildManifestPath,
    ExtractTmp : string;
  ChildMan : TManifest;

  procedure Enqueue(const D: TDependency; const ABy: string);
  var q: Integer;
  begin
    q := Length(Queue);
    SetLength(Queue, q + 1);
    Queue[q].Dep := D;
    Queue[q].RequiredBy := ABy;
  end;

begin
  { seed the queue with the root manifest's direct deps }
  for i := 0 to High(ARootMan.Deps) do
    Enqueue(ARootMan.Deps[i], ARootMan.Name);

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
        sources), ResolveDepRef returns ''. Custom prefixes are
        looked up against the ROOT manifest's [sources] table;
        child manifests declaring their own [sources] is a v1.x
        consideration. }
      R.Nodes[idx].Version := ResolveDepRef(Item.Dep,
        ARootMan.CustomSources);
      WriteLn('  fetching ', Item.Dep.Name, ' @ ', R.Nodes[idx].Version,
              '  (required by ', Item.RequiredBy, ')');
      FetchToCache(Item.Dep, R.Nodes[idx].Version,
                   AModulesRoot, AArchivesRoot, ATmpRoot, AProjectRoot,
                   ARootMan.CustomSources, AWorkspaces,
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

    { read the fetched package's own manifest and enqueue ITS deps }
    ChildManifestPath := IncludeTrailingPathDelimiter(UnitDir) + MANIFEST_FILE;
    if FileExists(ChildManifestPath) then
    begin
      { AIsRoot=False — supply-chain defense per ADR-0011 §"Supply-
        chain posture". Dep manifests' hook sections are silently
        dropped; unknown-section warnings are suppressed (CI noise
        without a user fix); placeholder expansion is skipped (no
        per-target context applies to dep-graph traversal). }
      ChildMan := LoadManifest(ChildManifestPath, False);
      { Copy the dep's units list into the resolved node so the cfg
        emitter knows which subdirs hold the .pas files. Without
        this, -Fu would point at UnitDir's top level and miss the
        units in <UnitDir>/source/ (or wherever the dep declared). }
      SetLength(R.Nodes[idx].UnitSubdirs, Length(ChildMan.Units));
      for i := 0 to High(ChildMan.Units) do
        R.Nodes[idx].UnitSubdirs[i] := ChildMan.Units[i];
      for i := 0 to High(ChildMan.Deps) do
        Enqueue(ChildMan.Deps[i], Item.Dep.Name);
    end;
  end;
end;

{ Size of a file by path, as a string; '0' if absent. }
function FileSizeBytes(const APath: string): string;
var SR: TSearchRec;
begin
  Result := '0';
  if FindFirst(APath, faAnyFile, SR) = 0 then
  begin
    Result := IntToStr(SR.Size);
    FindClose(SR);
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
      Archive := IncludeTrailingPathDelimiter(AArchivesRoot)
               + AGraphEntry.Name + '-';
      if Lock.SrcKind = skURL then
        Archive := Archive + 'url.tar.gz'
      else
        Archive := Archive + Lock.Version + '.tar.gz';
      if FileExists(Archive) then
        AGraphEntry.ArchiveHash := 'sha256:' + SHA256File(Archive);
      Exit;
    end;
end;

procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean);
var
  Man : TManifest;
  R   : TResolution;
  Resolved : array of TResolved;
  LockEntries : TResolvedArray;
  Lock : TInstallLock;
  ModulesRoot, ArchivesRoot, TmpRoot, CfgPath : string;
  i, j : Integer;
begin
  Man := LoadManifest(AManifestPath);
  WriteLn('package: ', Man.Name, ' ', Man.Version);

  { [preinstall] hooks fire before the lock is taken — they run from
    the user's process, so concurrent installs share the same hook
    work (idempotent by convention). ADR-0011. }
  RunHooks('preinstall', Man.PreInstall);

  ModulesRoot  := ResolveModulesDir(Man);
  ArchivesRoot := ResolveArchivesDir(Man);
  TmpRoot      := ResolveTmpDir(Man);
  CfgPath      := ResolveCfgFile(Man);

  { Cross-process install lock: prevents two concurrent installs from
    racing on the same project. Flock-based on Unix (lock auto-releases
    on FD close, so a crashed process doesn't leave a stale lock). The
    lock encompasses the crash-recovery cleanup below + the entire
    resolve/fetch/extract/write pipeline. }
  Lock := TInstallLock.Create(INSTALL_LOCK);
  try
    { Crash recovery: wipe any orphans left by a previous interrupted
      install. Safe to do under the lock — no other process is
      concurrently writing to tmp. }
    if DirectoryExists(TmpRoot) then
      WipeDir(TmpRoot);

    { transitive BFS: fetch + extract each package, read its child
      manifest, accumulate constraints across the whole graph.
      AProjectRoot = dir holding the root manifest; used by the
      skLocal install branch to decide link-vs-copy per dep (see
      ADR-0014 amendment §"Symlink/junction for monorepo deps"). }
    R := Default(TResolution);
    WriteLn('resolving dependency graph (', Length(Man.Deps), ' direct)...');
    ResolveGraph(Man, R, ModulesRoot, ArchivesRoot, TmpRoot,
                 ExtractFilePath(ExpandFileName(AManifestPath)),
                 Man.Workspaces, AFrozen);

    { every package's accumulated constraints must be jointly satisfiable }
    for i := 0 to High(R.Nodes) do
      CheckNodeConstraints(R.Nodes[i]);
    WriteLn('resolved ', Length(R.Nodes), ' packages, no conflicts.');

    { project the resolution graph into lockfile rows }
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

    if AFrozen then
    begin
      { Frozen mode verifies against the lockfile and does NOT rewrite
        anything. ELockfileError on missing/corrupt lockfile;
        EVerifyError on any hash mismatch (archive OR tree);
        EFetchError on missing module trees (raised earlier in
        ResolveGraph). The resolver only re-hashed the modules tree
        (Resolved[i].Hash); we re-hash the archive HERE because the
        resolved ref (needed to find the archive filename) is in the
        lockfile entry, not in the manifest dep. }
      LockEntries := LoadLockfile(LOCKFILE);
      for i := 0 to High(Resolved) do
      begin
        if Resolved[i].SrcKind = skLocal then Continue;
        FillFrozenArchiveHash(Resolved[i], LockEntries, ArchivesRoot);
      end;
      VerifyAgainstLockfile(Resolved, LockEntries);
      WriteLn('[frozen] ', Length(Resolved),
              ' packages verified against ', LOCKFILE,
              ' (archive + tree hashes both match).');
      Exit;
    end;

    WriteLock(LOCKFILE, TmpRoot, Resolved);
    WriteCfg(CfgPath, TmpRoot, Resolved, Man);
    WriteLn('wrote ', LOCKFILE, ' (', Length(Resolved),
            ' packages) and ', CfgPath);
  finally
    Lock.Free;
  end;

  { [postinstall] hooks fire after the lock releases — the user-
    visible state is fully written, downstream tooling (e.g. a
    devtool that reads lwpt.cfg) sees a coherent install. }
  RunHooks('postinstall', Man.PostInstall);
end;



{ ===========================================================================
  Test runner — discover *.Test.pas units, compile each, run, aggregate.

  A *.Test.pas file is a self-contained program: it uses TestingPascalLibrary,
  defines TTestSuite subclasses, and its begin..end block runs them and sets
  ExitCode via TestResultToExitCode. So LWPT does not parse test output — it
  compiles each file and reads the process exit code (0 = pass).

  Per ADR-0015 the TestingPascalLibrary unit lives in the `testing`
  workspace package (graduated from an embedded binary blob + the
  `lwpt export testing` extrude-on-demand model that preceded it).
  `lwpt install` symlinks `packages/testing/` into `.lwpt/modules/testing/`;
  the cfg emitter wires `-Fu` / `-Fi` to it like any other workspace dep.
  CmdTest itself adds nothing to the search path beyond what the
  manifest's units + the modules dir already provide — the testing
  library is just a dep.
  =========================================================================== }

{ Standard set of directories the discovery walks must NOT descend into.
  .lwpt holds toolkit state; build is FPC output (per the build-system
  contract); .git is version control. Add to this list with care — every
  exclusion is a place where tests / sources can hide silently. }
function IsExcludedDir(const AName: string): Boolean; inline;
begin
  Result := (AName = LWPT_DIR) or (AName = 'build') or (AName = '.git');
end;

procedure CollectTestFiles(const ADir: string; AList: TStringList);
var SR: TSearchRec; Base: string;
begin
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if not IsExcludedDir(SR.Name) then
          CollectTestFiles(Base + SR.Name, AList);
      end
      else if (Length(SR.Name) > 9)
        and SameText(Copy(SR.Name, Length(SR.Name) - 8, 9), '.Test.pas') then
        AList.Add(Base + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ Per-test-source build dir. Avoids dumping .o / .ppu / executables
  next to the .Test.pas under source/ or tests/. Each test gets its
  own dir so siblings with the same filename in different paths
  (source/Foo.Test.pas vs tests/integration/Foo.Test.pas) cannot
  collide. The dir name is the relative path with separators flattened. }
function TestBuildDir(const ASrcFile: string): string;
var Sanitised: string;
begin
  Sanitised := ChangeFileExt(ASrcFile, '');
  Sanitised := StringReplace(Sanitised, ':', '_', [rfReplaceAll]);
  Sanitised := StringReplace(Sanitised, '/', '_', [rfReplaceAll]);
  Sanitised := StringReplace(Sanitised, '\', '_', [rfReplaceAll]);
  Result := 'build/tests/' + Sanitised;
end;

function CompilePascal(const ASrcFile: string; const AUnitPaths: array of string;
  out AOutBin: string): Boolean;
var
  P : TProcess;
  BuildDir : string;
  i : Integer;

  procedure AddCfgParameters(const APath: string);
  var
    Lines : TStringList;
    Line : string;
    j : Integer;
  begin
    if not FileExists(APath) then
      Exit;

    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(APath);
      for j := 0 to Lines.Count - 1 do
      begin
        Line := Trim(Lines[j]);
        if Line = '' then
          Continue;
        if Line[1] = '#' then
          Continue;
        P.Parameters.Add(Line);
      end;
    finally
      Lines.Free;
    end;
  end;
begin
  BuildDir := TestBuildDir(ASrcFile);
  ForceDirectories(BuildDir);
  AOutBin := IncludeTrailingPathDelimiter(BuildDir)
           + ChangeFileExt(ExtractFileName(ASrcFile), '');

  P := TProcess.Create(nil);
  try
    P.Executable := FPCExecutable;
    (* Deliberately NOT forcing -M<mode>: each source sets its own mode
       via {$I Shared.inc} or an explicit {$mode delphi}{$H+} header.
       Forcing a mode here would conflict with future vendored test
       files that ship their own directives. -Sh stays — it is a
       delphi/objfpc-compatible string-handling switch, not a mode.
       (Nested-comment support is per-file via {$MODESWITCH
       NESTEDCOMMENTS+}; FPC has no command-line equivalent.) *)
    P.Parameters.Add('-Sh');
    P.Parameters.Add('-FE' + BuildDir);   { all intermediates land here }
    { Inherit dep search paths from lwpt.cfg when present. After
      ADR-0014 (packages extraction), deps' unit subdirs live at
      .lwpt/modules/<name>/source/ and CmdTest's per-test compile
      needs them on -Fu / -Fi — without this, every test that
      transitively uses HTTPClient / CLI / Semver / TOML fails to
      compile with "can't find unit". Expand the response fragment
      directly here so test compilation is independent of per-platform
      FPC response-file parsing. The explicit AUnitPaths
      additions stay for the AUnitPaths-driven callers (preserves
      backwards-compat with non-cfg-based invocations). }
    AddCfgParameters(CFG_FILE);
    AddEnvUnitPathParameters(P.Parameters);
    for i := 0 to High(AUnitPaths) do
      if AUnitPaths[i] <> '' then
      begin
        P.Parameters.Add('-Fu' + AUnitPaths[i]);
        P.Parameters.Add('-Fi' + AUnitPaths[i]);
      end;
    P.Parameters.Add('-o' + AOutBin);
    P.Parameters.Add(ASrcFile);
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
  end;
end;

function RunBinary(const ABinPath: string): Integer;
var P: TProcess;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := ABinPath;
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

{ Test discovery + run policy.

  Default tier skips anything under tests/e2e/ (network-touching). The
  --tier=e2e flag passed to lwpt test wires AIncludeE2E=True, which
  bypasses the skip. The other tiers (unit + integration) always run.
  See docs/testing.md for the policy table. }
function IsE2ETestPath(const APath: string): Boolean; inline;
var Normalised: string;
begin
  Normalised := StringReplace(APath, '\', '/', [rfReplaceAll]);
  Result := (Pos('/tests/e2e/', Normalised) > 0)
         or (Pos('tests/e2e/', Normalised) = 1);
end;

function CmdTest(const AManifestPath: string; AIncludeE2E: Boolean): Integer;
const
  TESTS_SUPPORT_DIR = 'tests/support';
var
  Man : TManifest;
  Tests : TStringList;
  UnitPaths : array of string;
  ModulesRoot : string;
  i, n, Passed, Failed, Skipped, CompileFailed, Code : Integer;
  Bin : string;
begin
  Man := LoadManifest(AManifestPath);

  { [pretest] hooks fire before test discovery. Same conceptual
    role as [prebuild] but tied to test compilation; ADR-0011 lets
    an entry be authored in BOTH [prebuild] AND [pretest] when a
    project-level prep step needs to run for either phase (the
    staleness gate ensures it runs at most once per source edit). }
  RunHooks('pretest', Man.PreTest);

  { Per ADR-0015, TestingPascalLibrary is consumed via the `testing`
    workspace package — no extrude step here. The modules dir + each
    workspace package's source/ are already on the cfg's -Fu / -Fi
    paths courtesy of CmdInstall + WriteCfg. }
  ModulesRoot := ResolveModulesDir(Man);

  SetLength(UnitPaths, 0);
  for i := 0 to High(Man.Units) do
  begin
    n := Length(UnitPaths); SetLength(UnitPaths, n + 1);
    UnitPaths[n] := Man.Units[i];
  end;
  n := Length(UnitPaths); SetLength(UnitPaths, n + 1);
  UnitPaths[n] := ModulesRoot;
  if DirectoryExists(TESTS_SUPPORT_DIR) then
  begin
    n := Length(UnitPaths); SetLength(UnitPaths, n + 1);
    UnitPaths[n] := TESTS_SUPPORT_DIR;
  end;

  Tests := TStringList.Create;
  try
    for i := 0 to High(Man.Units) do
      CollectTestFiles(Man.Units[i], Tests);
    CollectTestFiles('.', Tests);

    { dedupe: a unit dir under '.' is walked twice — collapse by
      canonical absolute path }
    for i := 0 to Tests.Count - 1 do
      Tests[i] := ExpandFileName(Tests[i]);
    Tests.Sort;
    i := Tests.Count - 1;
    while i > 0 do
    begin
      if Tests[i] = Tests[i - 1] then Tests.Delete(i);
      Dec(i);
    end;

    if Tests.Count = 0 then
    begin
      WriteLn('no *.Test.pas files found');
      Exit(0);
    end;

    WriteLn('discovered ', Tests.Count, ' test file(s)');
    if not AIncludeE2E then
      WriteLn('  (e2e tier skipped; pass --tier=e2e to include)');
    Passed := 0; Failed := 0; Skipped := 0; CompileFailed := 0;
    for i := 0 to Tests.Count - 1 do
    begin
      if (not AIncludeE2E) and IsE2ETestPath(Tests[i]) then
      begin
        WriteLn('  ', ExtractFileName(Tests[i]), ' ... skipped (e2e tier)');
        Inc(Skipped);
        Continue;
      end;
      Write('  ', ExtractFileName(Tests[i]), ' ... ');
      if not CompilePascal(Tests[i], UnitPaths, Bin) then
      begin
        WriteLn('COMPILE FAILED');
        Inc(CompileFailed);
        Continue;
      end;
      Code := RunBinary(Bin);
      if Code = 0 then
      begin
        WriteLn('pass');
        Inc(Passed);
      end
      else
      begin
        WriteLn('FAIL (exit ', Code, ')');
        Inc(Failed);
      end;
    end;

    WriteLn;
    Write(Passed, ' passed, ', Failed, ' failed, ',
          CompileFailed, ' did not compile');
    if Skipped > 0 then
      Write(', ', Skipped, ' skipped');
    WriteLn;
    if (Failed = 0) and (CompileFailed = 0) then
      Result := 0
    else
      Result := 1;
  finally
    Tests.Free;
  end;

  { [posttest] hooks fire after the test suite finishes regardless
    of pass/fail — handy for coverage upload, test-result archival,
    etc. The function's Result (0 = all pass) is set above and
    propagates to the caller's exit code unmodified. }
  RunHooks('posttest', Man.PostTest);
end;


{ ===========================================================================
  Build — compile manifest targets.

  Generalises GocciaScript build.pas: its eight hardcoded BuildXxx procedures
  (each = RunCommand fpc FPCArgs(literal-path)) collapse into one loop over
  the manifest's [targets]. FPCArgs' dev/prod flag sets are kept as-is (good
  defaults); @config.cfg becomes @lwpt.cfg, the file `lwpt install` emits.
  GenerateVersionInclude becomes the optional [version] manifest section.
  =========================================================================== }

{ Dev / production FPC flag sets — lifted verbatim from build.pas FPCArgs. }
procedure AddBuildModeFlags(AArgs: TStrings; ARelease: Boolean);
begin
  { -Sh applies in both modes: ansistrings + H+ string default.
    Mode + nested-comment support are set per-file via directives. }
  AArgs.Add('-Sh');
  if ARelease then
  begin
    AArgs.Add('-O4'); AArgs.Add('-dPRODUCTION'); AArgs.Add('-Xs');
    AArgs.Add('-CX'); AArgs.Add('-XX');          AArgs.Add('-B');
  end
  else
  begin
    AArgs.Add('-O-');  AArgs.Add('-gw'); AArgs.Add('-godwarfsets');
    AArgs.Add('-gl');  AArgs.Add('-Ct'); AArgs.Add('-Cr'); AArgs.Add('-Sa');
  end;
end;

{ Optional version-baking: write a generated .inc with the manifest version.
  Mirrors build.pas GenerateVersionInclude but path + constant prefix come
  from the [version] manifest section. }

{ ===========================================================================
  Build-lifecycle hook executor (ADR-0011).

  Sequential, stop-on-first-failure, manifest-insertion-order (preserved
  through TOML → OrderedStringMap). Hooks with a paired inputs/output
  field gate-skip when the output is newer than every input; hooks
  without that pair always run. InstantFPC is the only execution channel
  (cross-platform without shell-vs-bat-vs-sh hell — scripts shell out
  to other tools via TProcess if they need to).

  Phase failure aborts the rest of the section: a non-zero exit code
  (or a TProcess spawn failure) raises ELWPTError naming the hook +
  the phase + the exit status, and the caller propagates that as the
  subcommand's exit code. =========================================================================== }
function HookIsStale(const AHook: THook): Boolean;
var
  OutputAge: LongInt;
  i: Integer;
begin
  { Always-run hooks (no inputs/output declared) never short-circuit. }
  if (AHook.Output = '') or (Length(AHook.Inputs) = 0) then Exit(True);
  if not FileExists(AHook.Output) then Exit(True);
  OutputAge := FileAge(AHook.Output);
  for i := 0 to High(AHook.Inputs) do
    if FileExists(AHook.Inputs[i])
       and (FileAge(AHook.Inputs[i]) > OutputAge) then
      Exit(True);
  Result := False;
end;

function RunPascalScript(const AHook: THook; out AError: string): Integer;
var
  P: TProcess;
  j: Integer;
  {$IFDEF MSWINDOWS}
  Bin: string;
  {$ENDIF}
begin
  AError := '';
  {$IFDEF MSWINDOWS}
  if not CompilePascal(AHook.Script, [], Bin) then
  begin
    AError := 'fpc failed to compile ' + AHook.Script;
    Exit(1);
  end;
  if (not FileExists(Bin)) and FileExists(Bin + '.exe') then
    Bin := Bin + '.exe';
  Bin := NativePath(ExpandFileName(Bin));
  {$ENDIF}

  P := TProcess.Create(nil);
  try
    {$IFDEF MSWINDOWS}
    P.Executable := Bin;
    {$ELSE}
    P.Executable := InstantFPCExecutable;
    P.Parameters.Add(AHook.Script);
    {$ENDIF}
    for j := 0 to High(AHook.Args) do
      P.Parameters.Add(AHook.Args[j]);
    P.Options := [poWaitOnExit];
    try
      P.Execute;
    except
      on E: Exception do
      begin
        {$IFDEF MSWINDOWS}
        AError := 'compiled script unavailable (' + E.Message + ')';
        {$ELSE}
        AError := 'instantfpc unavailable (' + E.Message + ')';
        {$ENDIF}
        Exit(127);
      end;
    end;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

procedure RunHooks(const APhase: string; const AHooks: THookArray);
var
  i, Code: Integer;
  H: THook;
  ScriptError: string;
begin
  if Length(AHooks) = 0 then Exit;
  for i := 0 to High(AHooks) do
  begin
    H := AHooks[i];

    if not HookIsStale(H) then
    begin
      WriteLn('  [', APhase, '] ', H.Name, ' (skipped — output fresh)');
      Continue;
    end;

    WriteLn('  [', APhase, '] ', H.Name);

    if not FileExists(H.Script) then
      raise EManifestError.CreateFmt(
        '[%s] %s: script not found at %s', [APhase, H.Name, H.Script]);

    Code := RunPascalScript(H, ScriptError);
    if ScriptError <> '' then
      raise ELWPTError.CreateFmt(
        '[%s] %s: %s while running %s',
        [APhase, H.Name, ScriptError, H.Script]);

    if Code <> 0 then
      raise ELWPTError.CreateFmt(
        '[%s] %s: script exited %d while running %s',
        [APhase, H.Name, Code, H.Script]);
  end;
end;

procedure GenerateVersionInclude(const AMan: TManifest);
var F: TextFile; Pfx: string;
begin
  if AMan.VersionIncOut = '' then Exit;   { [version] not configured }
  Pfx := AMan.VersionPrefix;
  if Pfx = '' then Pfx := 'BAKED';
  ForceDirectories(ExtractFileDir(AMan.VersionIncOut));
  AssignFile(F, AMan.VersionIncOut);
  Rewrite(F);
  try
    WriteLn(F, '// Auto-generated by ', PROGRAM_NAME,
            ' build — do not edit');
    WriteLn(F, 'const');
    WriteLn(F, '  ', Pfx, '_VERSION = ''', AMan.Version, ''';');
    WriteLn(F, '  ', Pfx, '_BUILD_DATE = ''',
      FormatDateTime('yyyy-mm-dd', Now), ''';');
  finally
    CloseFile(F);
  end;
  WriteLn('  generated ', AMan.VersionIncOut);
end;

{ Compile one build target. Returns True on success. }
function BuildOneTarget(const AMan: TManifest; const T: TBuildTarget;
  ARelease, AClean: Boolean): Boolean;
var
  P : TProcess;
  Arch, OutBin : string;
  i : Integer;
begin
  if T.Source = '' then
  begin
    WriteLn(ErrOutput, '  target "', T.Name, '" has no source — skipped');
    Exit(False);
  end;

  OutBin := T.Output;
  if OutBin = '' then
    OutBin := ChangeFileExt(T.Source, '');
  {$IFDEF MSWINDOWS}
  if ExtractFileExt(OutBin) = '' then OutBin := OutBin + '.exe';
  {$ENDIF}
  if ExtractFileDir(OutBin) <> '' then
    ForceDirectories(ExtractFileDir(OutBin));

  { clean build: remove the stale binary and the FPC artefacts next to the
    source so nothing is reused }
  if AClean then
  begin
    if FileExists(OutBin) then DeleteFile(OutBin);
    DeleteFile(ChangeFileExt(T.Source, '.o'));
    DeleteFile(ChangeFileExt(T.Source, '.ppu'));
  end;

  Write('  building ', T.Name, ' (', T.Source, ') ... ');

  P := TProcess.Create(nil);
  try
    P.Executable := FPCExecutable;
    { cross-compile target CPU via env var, same hook as build.pas }
    Arch := GetEnvironmentVariable('FPC_TARGET_CPU');
    if Arch <> '' then P.Parameters.Add('-P' + Arch);

    P.Parameters.Add('-Sh');
    { resolved dependency search paths: the manifest-resolved cfg path,
      if install has run (zero-install repos commit it, so this should
      almost always be present). }
    if FileExists(ResolveCfgFile(AMan)) then
      P.Parameters.Add('@' + ResolveCfgFile(AMan));
    AddEnvUnitPathParameters(P.Parameters);
    { manifest's own unit dirs — both as unit (-Fu) and include
      (-Fi) search paths. .inc files conventionally live next to
      .pas units, so the same dir serves both. }
    for i := 0 to High(AMan.Units) do
      if AMan.Units[i] <> '' then
      begin
        P.Parameters.Add('-Fu' + AMan.Units[i]);
        P.Parameters.Add('-Fi' + AMan.Units[i]);
      end;
    AddBuildModeFlags(P.Parameters, ARelease);
    { -B forces a full rebuild, ignoring up-to-date units. Release mode
      already adds -B; only add it here for a clean dev build. }
    if AClean and (not ARelease) then
      P.Parameters.Add('-B');
    P.Parameters.Add('-o' + OutBin);
    P.Parameters.Add(T.Source);

    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus = 0;
    if Result then
      WriteLn('ok -> ', OutBin)
    else
      WriteLn('FAILED (fpc exit ', P.ExitStatus, ')');
  finally
    P.Free;
  end;
end;

function CmdBuild(const AManifestPath, ATargetName: string;
  ARelease, AClean: Boolean): Integer;
var
  Man : TManifest;
  i, Built, Failed : Integer;
  Matched : Boolean;
  ModeStr : string;
begin
  Man := LoadManifest(AManifestPath);

  if Length(Man.Targets) = 0 then
  begin
    WriteLn('no [build] entries defined in ', AManifestPath);
    Exit(1);
  end;

  if ARelease then ModeStr := 'release' else ModeStr := 'dev';
  if AClean then ModeStr := ModeStr + ', clean';
  WriteLn('build mode: ', ModeStr);

  { Whole-build prebuild hooks (ADR-0011). Fires once before the
    target loop. Replaces the old RunGenerators call — staleness-
    gated entries fold in unchanged via the inputs/output pair. }
  RunHooks('prebuild', Man.PreBuild);

  GenerateVersionInclude(Man);

  Built := 0; Failed := 0; Matched := False;
  for i := 0 to High(Man.Targets) do
  begin
    { if a target name was given, build only that one }
    if (ATargetName <> '')
       and (not SameText(ATargetName, Man.Targets[i].Name)) then
      Continue;
    Matched := True;
    { Per-target prebuild — fires immediately before this target's
      fpc invocation (e.g. version-stamp, codegen for this target). }
    RunHooks('prebuild:' + Man.Targets[i].Name,
      Man.Targets[i].PreBuild);
    if BuildOneTarget(Man, Man.Targets[i], ARelease, AClean) then
      Inc(Built)
    else
      Inc(Failed);
    { Per-target postbuild fires regardless of compile success;
      we want sign/strip/package even on a stale binary. }
    RunHooks('postbuild:' + Man.Targets[i].Name,
      Man.Targets[i].PostBuild);
  end;

  if (ATargetName <> '') and (not Matched) then
  begin
    WriteLn(ErrOutput, 'no target named "', ATargetName, '" in ', AManifestPath);
    Exit(1);
  end;

  { Whole-build postbuild — last thing before we exit. Fires even
    if some targets failed (mirrors the per-target postbuild
    semantics; let users notify/upload regardless). }
  RunHooks('postbuild', Man.PostBuild);

  WriteLn;
  WriteLn(Built, ' built, ', Failed, ' failed');
  if Failed = 0 then Result := 0 else Result := 1;
end;


{ ===========================================================================
  Format — uses-clause and identifier formatting over the project's sources.

  Wraps the LWPT.Format unit (converted from GocciaScript format.pas).
  `lwpt format`         rewrites files in place
  `lwpt format --check` reports files that need formatting, exits 1 if any
  =========================================================================== }

{ ===========================================================================
  Format scope resolution — ADR-0007.

  The scope is composed declaratively from the manifest:
    seed     = [package].units (each as plain dir, non-recursive)
    add      = [format].include (globs)
    subtract = [format].exclude (globs)

  Glob syntax:
    *   matches one path segment (no /)
    **  matches any depth (recursion is explicit)
    ?   matches one non-/ character
    literal (no glob chars) → either a file or a dir-shorthand expansion

  Plain dir shorthand: `tests` ≡ `tests/` ≡ `tests/*.{pas,inc,dpr,lpr}`
  (top-level only). Hidden files / dirs (leading `.`) are always skipped.

  Missing literal paths → EManifestError. Missing glob matches → silent.
  =========================================================================== }
const
  FORMATTABLE_EXTS: array[0..3] of string = ('.pas', '.inc', '.dpr', '.lpr');

function IsFormattableExt(const AName: string): Boolean; inline;
var
  Ext: string;
  i: Integer;
begin
  Ext := LowerCase(ExtractFileExt(AName));
  for i := Low(FORMATTABLE_EXTS) to High(FORMATTABLE_EXTS) do
    if Ext = FORMATTABLE_EXTS[i] then Exit(True);
  Result := False;
end;

function IsHiddenName(const AName: string): Boolean; inline;
begin
  Result := (Length(AName) > 0) and (AName[1] = '.');
end;

function PatternHasGlobChars(const APattern: string): Boolean; inline;
begin
  Result := (Pos('*', APattern) > 0) or (Pos('?', APattern) > 0);
end;

{ Single-segment glob match: * matches any sequence of non-'/' chars,
  ? matches exactly one non-'/' char, anything else is literal. The
  segment has no '/' by construction (we split first). Case-sensitive
  per ADR-0007. Standard iterative-star-backtracking algorithm — no
  recursion, O(N*M) worst case but the M (pattern length) is tiny. }
function MatchSegment(const APattern, AName: string): Boolean;
var
  P, N, StarP, StarN: Integer;
begin
  P := 1; N := 1;
  StarP := 0; StarN := 0;
  while N <= Length(AName) do
  begin
    if (P <= Length(APattern)) and (APattern[P] = '?') then
    begin Inc(P); Inc(N); end
    else if (P <= Length(APattern)) and (APattern[P] = '*') then
    begin StarP := P; Inc(P); StarN := N; end
    else if (P <= Length(APattern)) and (APattern[P] = AName[N]) then
    begin Inc(P); Inc(N); end
    else if StarP <> 0 then
    begin P := StarP + 1; Inc(StarN); N := StarN; end
    else
      Exit(False);
  end;
  while (P <= Length(APattern)) and (APattern[P] = '*') do Inc(P);
  Result := P > Length(APattern);
end;

procedure SplitGlobSegments(const APattern: string; ASegments: TStringList);
var
  i, Start: Integer;
begin
  ASegments.Clear;
  Start := 1;
  for i := 1 to Length(APattern) do
    if APattern[i] = '/' then
    begin
      if i > Start then
        ASegments.Add(Copy(APattern, Start, i - Start));
      Start := i + 1;
    end;
  if Start <= Length(APattern) then
    ASegments.Add(Copy(APattern, Start, MaxInt));
end;

{ Non-recursive walk: add formattable files at the top level of ADir.
  Used by the [package].units seed and by plain-dir-shorthand expansion. }
procedure CollectFormattableInDir(const ADir: string; AList: TStringList);
var SR: TSearchRec; Base: string;
begin
  if not DirectoryExists(ADir) then Exit;
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if IsHiddenName(SR.Name) then Continue;
        if (SR.Attr and faDirectory) <> 0 then Continue;
        if IsFormattableExt(SR.Name) then
          AList.Add(ExpandFileName(Base + SR.Name));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
end;

{ Recursive glob walker. ASegments is the glob split on '/'. AIndex is
  the current segment index. ABase is the current directory. Adds every
  matching file to AList (only files, only formattable extensions).
  Handles `**` as zero-or-more directory levels. }
procedure WalkSegments(const ABase: string; ASegments: TStringList;
  AIndex: Integer; AList: TStringList);
var
  SR: TSearchRec;
  Seg, EntryPath: string;
  IsDir: Boolean;
begin
  if AIndex >= ASegments.Count then
  begin
    { Pattern exhausted at ABase — add all formattable files at this
      level. Reached only via `tests/**` style patterns where the
      trailing ** has matched zero+ segments. }
    CollectFormattableInDir(ABase, AList);
    Exit;
  end;

  Seg := ASegments[AIndex];

  if Seg = '**' then
  begin
    { ** matches zero levels (advance to next segment at this base) ... }
    WalkSegments(ABase, ASegments, AIndex + 1, AList);
    { ... or one+ levels (descend into each subdir, ** still here). }
    if FindFirst(IncludeTrailingPathDelimiter(ABase) + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if IsHiddenName(SR.Name) then Continue;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            EntryPath := IncludeTrailingPathDelimiter(ABase) + SR.Name;
            WalkSegments(EntryPath, ASegments, AIndex, AList);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    Exit;
  end;

  { Plain segment (may contain * / ?). Match against entries at ABase. }
  if FindFirst(IncludeTrailingPathDelimiter(ABase) + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if IsHiddenName(SR.Name) then Continue;
        if not MatchSegment(Seg, SR.Name) then Continue;
        EntryPath := IncludeTrailingPathDelimiter(ABase) + SR.Name;
        IsDir := (SR.Attr and faDirectory) <> 0;
        if AIndex = ASegments.Count - 1 then
        begin
          { Last segment — only files at this position contribute. }
          if not IsDir and IsFormattableExt(SR.Name) then
            AList.Add(ExpandFileName(EntryPath));
        end
        else if IsDir then
          WalkSegments(EntryPath, ASegments, AIndex + 1, AList);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
end;

{ Expand one [format] include/exclude entry into AList. Literal paths
  either resolve to a file (added if formattable) or a dir (expanded
  via the plain-dir shorthand). Glob patterns are walked via the
  algorithm above. AErrorOnMissingLiteral controls behavior when the
  entry has no glob chars and resolves to nothing (per ADR-0007:
  literals assert presence; globs are silent on zero match). }
procedure ExpandFormatPattern(const APattern: string; AList: TStringList;
  AErrorOnMissingLiteral: Boolean);
var
  Cleaned: string;
  Segments: TStringList;
begin
  if APattern = '' then Exit;

  Cleaned := APattern;
  if Cleaned[Length(Cleaned)] = '/' then
    Delete(Cleaned, Length(Cleaned), 1);
  if Cleaned = '' then Exit;

  if not PatternHasGlobChars(Cleaned) then
  begin
    if FileExists(Cleaned) then
    begin
      if IsFormattableExt(Cleaned) then
        AList.Add(ExpandFileName(Cleaned));
    end
    else if DirectoryExists(Cleaned) then
      CollectFormattableInDir(Cleaned, AList)
    else if AErrorOnMissingLiteral then
      raise EManifestError.CreateFmt(
        '[format] literal path "%s" does not exist', [APattern]);
    Exit;
  end;

  Segments := TStringList.Create;
  try
    SplitGlobSegments(Cleaned, Segments);
    if Segments.Count > 0 then
      WalkSegments('.', Segments, 0, AList);
  finally
    Segments.Free;
  end;
end;

procedure DedupAbsolutePaths(AList: TStringList);
var i: Integer;
begin
  AList.Sort;
  i := AList.Count - 1;
  while i > 0 do
  begin
    if AList[i] = AList[i - 1] then AList.Delete(i);
    Dec(i);
  end;
end;

function CmdFormat(const AManifestPath: string; ACheckOnly: Boolean): Integer;
var
  Man : TManifest;
  Files, ExcludeSet, FinalFiles : TStringList;
  i, Changed : Integer;
  Path : string;
  RunMode : TRunMode;
begin
  Man := LoadManifest(AManifestPath);

  if ACheckOnly then
    RunMode := rmCheck
  else
    RunMode := rmFormat;

  Files       := TStringList.Create;
  ExcludeSet  := TStringList.Create;
  FinalFiles  := TStringList.Create;
  try
    { Seed: [package].units (non-recursive — see ADR-0007). }
    for i := 0 to High(Man.Units) do
      CollectFormattableInDir(Man.Units[i], Files);

    { Add: [format].include. Literal-path-missing is a hard error. }
    for i := 0 to High(Man.FormatIncludes) do
      ExpandFormatPattern(Man.FormatIncludes[i], Files, True);

    { Fallback: both sources empty → walk cwd non-recursively. Lets
      single-file scripts work without manifest ceremony. }
    if (Length(Man.Units) = 0) and (Length(Man.FormatIncludes) = 0) then
      CollectFormattableInDir('.', Files);

    { Subtract: [format].exclude. Same expansion rules as include. }
    for i := 0 to High(Man.FormatExcludes) do
      ExpandFormatPattern(Man.FormatExcludes[i], ExcludeSet, True);

    DedupAbsolutePaths(Files);
    DedupAbsolutePaths(ExcludeSet);

    for i := 0 to Files.Count - 1 do
    begin
      Path := Files[i];
      if ExcludeSet.IndexOf(Path) < 0 then
        FinalFiles.Add(Path);
    end;

    if FinalFiles.Count = 0 then
    begin
      WriteLn('no source files in scope');
      Exit(0);
    end;

    Changed := 0;
    for i := 0 to FinalFiles.Count - 1 do
      if FormatFile(FinalFiles[i], RunMode) then
      begin
        Inc(Changed);
        if ACheckOnly then
          WriteLn('  needs formatting: ', ExtractFileName(FinalFiles[i]))
        else
          WriteLn('  formatted: ', ExtractFileName(FinalFiles[i]));
      end;

    WriteLn;
    if ExcludeSet.Count > 0 then
      WriteLn(ExcludeSet.Count, ' file(s) skipped via [format] exclude');
    if ACheckOnly then
    begin
      if Changed > 0 then
      begin
        WriteLn(Changed, ' of ', FinalFiles.Count,
                ' file(s) need formatting');
        Result := 1;
      end
      else
      begin
        WriteLn(FinalFiles.Count,
                ' file(s) checked — all correctly formatted');
        Result := 0;
      end;
    end
    else
    begin
      WriteLn(Changed, ' of ', FinalFiles.Count,
              ' file(s) formatted');
      Result := 0;
    end;
  finally
    Files.Free;
    ExcludeSet.Free;
    FinalFiles.Free;
  end;
end;


{ ===========================================================================
  Repair — clean .lwpt/tmp/ and stale install lock.

  Recover from a crashed `lwpt install` by removing the workspace dir
  and any leftover install lock file. The committed state under
  .lwpt/modules/ and .lwpt/archives/ is never touched; restoring those
  is the user's responsibility (re-fetch via plain `lwpt install` if
  they're damaged).

  Scope: deletion + reporting only. The full hardening pass
  adds liveness check on the install lock's PID before reaping. }
procedure WipeDirContents(const ADir: string);
var SR: TSearchRec; Base, FullPath: string;
begin
  if not DirectoryExists(ADir) then Exit;
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      FullPath := Base + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        WipeDirContents(FullPath);
        RemoveDir(FullPath);
      end
      else
        DeleteFile(FullPath);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

procedure CmdRepair(const AManifestPath: string);
var
  Man : TManifest;
  TmpRoot : string;
begin
  Man := LoadManifest(AManifestPath);
  TmpRoot := ResolveTmpDir(Man);

  if DirectoryExists(TmpRoot) then
  begin
    WipeDirContents(TmpRoot);
    WriteLn('repair: cleaned ', TmpRoot, '/');
  end
  else
    WriteLn('repair: no ', TmpRoot, '/ to clean');

  if FileExists(INSTALL_LOCK) then
  begin
    DeleteFile(INSTALL_LOCK);
    WriteLn('repair: removed stale ', INSTALL_LOCK);
  end
  else
    WriteLn('repair: no install lock to remove');

  WriteLn('repair complete. Committed state under ', LWPT_DIR,
          '/modules/ and ', LWPT_DIR, '/archives/ was not modified.');
end;

{ ===========================================================================
  CmdInit (ADR-0010) — scaffold a new LWPT project. Interactive by
  default; --yes (-y) uses defaults derived from the CWD's basename
  (npm-init-y style). Refuses to overwrite an existing lwpt.toml
  unless --force is also passed.
  =========================================================================== }
procedure WriteScaffoldManifest(const APath, AName, AVersion,
  ASourceDir, ABuildDir, AEntryName: string);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('# ' + PROGRAM_NAME + '.toml — generated by `' + PROGRAM_NAME
           + ' init`. Edit me.');
    SL.Add('');
    SL.Add('[package]');
    SL.Add('name = "' + AName + '"');
    SL.Add('version = "' + AVersion + '"');
    SL.Add('units = ["' + ASourceDir + '"]');
    SL.Add('');
    SL.Add('[build]');
    SL.Add(AEntryName + ' = { source = "' + ASourceDir + '/'
           + AEntryName + '.pas", output = "' + ABuildDir + '/'
           + AEntryName + '" }');
    SL.Add('');
    SL.Add('# [dependencies]');
    SL.Add('# horse = "HashLoad/horse@^4.0.0"               # GitHub by default');
    SL.Add('# release-cli = "gitlab:gitlab-org/release-cli@v0.16.0"');
    SL.Add('# leaf = "../leaf"                               # local path');
    SL.Add('# See ADR-0009 for the full source-spec syntax.');
    SL.Add('');
    SL.Add('# [sources]   — custom git-host prefixes; see ADR-0009.');
    SL.Add('# gitea = { archive = "https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz", git = "https://git.example.com/{user}/{repository}.git" }');
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

{ Pascal identifiers can't contain hyphens, but package names + entry
  names happily do (npm convention; LWPT inherits it). The `program
  X;` declaration must be a valid identifier, so we sanitise by
  replacing hyphens with underscores. The filename + target name +
  greeting text keep the original spelling — FPC doesn't require the
  program name to match the filename, so this stays out of the user's
  way. }
function SanitisePascalIdent(const S: string): string;
var i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] = '-' then Result[i] := '_';
end;

procedure WriteHelloProgram(const APath, AEntryName: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Add('program ' + SanitisePascalIdent(AEntryName) + ';');
    SL.Add('');
    SL.Add('{$mode delphi}{$H+}');
    SL.Add('');
    SL.Add('begin');
    SL.Add('  WriteLn(''hello from ' + AEntryName + ''');');
    SL.Add('end.');
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure EnsureGitignoreEntries(const APath: string;
  const ABuildDir: string);
var
  Wanted: TStringArray;
  SL: TStringList;
  i, j: Integer;
  Existed, HasEntry: Boolean;
  Added: Integer;
begin
  SetLength(Wanted, 3);
  Wanted[0] := '.lwpt/tmp/';
  Wanted[1] := '.lwpt/install.lock';
  Wanted[2] := StringReplace(IncludeTrailingPathDelimiter(ABuildDir),
    DirectorySeparator, '/', [rfReplaceAll]);
  Existed := FileExists(APath);
  SL := TStringList.Create;
  try
    if Existed then SL.LoadFromFile(APath);
    Added := 0;
    for i := 0 to High(Wanted) do
    begin
      HasEntry := False;
      for j := 0 to SL.Count - 1 do
        if Trim(SL[j]) = Wanted[i] then begin HasEntry := True; Break; end;
      if not HasEntry then
      begin
        if (SL.Count > 0) and (Trim(SL[SL.Count - 1]) <> '') then
          SL.Add('');
        if not Existed and (Added = 0) then
          SL.Add('# generated by `' + PROGRAM_NAME + ' init`');
        SL.Add(Wanted[i]);
        Inc(Added);
      end;
    end;
    if Added > 0 then SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

function ValidPackageName(const S: string): Boolean;
var i: Integer;
begin
  Result := False;
  if S = '' then Exit;
  for i := 1 to Length(S) do
    if not ((S[i] in ['a'..'z']) or (S[i] in ['A'..'Z'])
            or (S[i] in ['0'..'9']) or (S[i] = '-') or (S[i] = '_')) then
      Exit;
  Result := True;
end;

procedure CmdInit(AYes, AForce: Boolean);
const
  DEFAULT_VERSION    = '0.1.0';
  DEFAULT_SOURCE_DIR = 'source';
  DEFAULT_BUILD_DIR  = 'build';
var
  Name, Version, SourceDir, BuildDir, EntryName, CWD, EntryPath: string;
begin
  CWD := GetCurrentDir;
  if FileExists(MANIFEST_FILE) and not AForce then
    raise EManifestError.CreateFmt(
      '%s already exists in %s. Pass --force to overwrite, or '
      + 'remove the file first if you really mean to re-init.',
      [MANIFEST_FILE, CWD]);

  { Defaults derived from the CWD basename. Stripping a trailing
    path delimiter handles "/Users/foo/myproj/" → "myproj". }
  Name := ExtractFileName(ExcludeTrailingPathDelimiter(CWD));
  if (Name = '') or not ValidPackageName(Name) then Name := 'lwpt-project';
  Version   := DEFAULT_VERSION;
  SourceDir := DEFAULT_SOURCE_DIR;
  BuildDir  := DEFAULT_BUILD_DIR;
  EntryName := Name;

  if not AYes then
  begin
    WriteLn('initialising new ', PROJECT_NAME, ' project in ', CWD);
    WriteLn('press <enter> to accept the default in parentheses.');
    WriteLn;
    Name      := ReadPromptLine('package name',        Name);
    if not ValidPackageName(Name) then
      raise EManifestError.CreateFmt(
        'package name "%s" is not a valid identifier (must be ASCII '
        + 'letters/digits/hyphen/underscore)', [Name]);
    Version   := ReadPromptLine('version',             Version);
    SourceDir := ReadPromptLine('source folder',       SourceDir);
    BuildDir  := ReadPromptLine('build folder',        BuildDir);
    { Entry name default tracks the (possibly edited) package name —
      if you typed a new name in the first prompt, the entry should
      follow unless explicitly overridden. }
    if EntryName <> Name then EntryName := Name;
    EntryName := ReadPromptLine('project entry name',  EntryName);
    if not ValidPackageName(EntryName) then
      raise EManifestError.CreateFmt(
        'entry name "%s" is not a valid identifier (must be ASCII '
        + 'letters/digits/hyphen/underscore)', [EntryName]);
  end;

  EntryPath := SourceDir + '/' + EntryName + '.pas';
  WriteScaffoldManifest(MANIFEST_FILE, Name, Version,
    SourceDir, BuildDir, EntryName);
  WriteHelloProgram(EntryPath, EntryName);
  EnsureGitignoreEntries('.gitignore', BuildDir);

  WriteLn;
  WriteLn('initialized ', Name, ' v', Version);
  WriteLn('  ', MANIFEST_FILE, '   (manifest)');
  WriteLn('  ', EntryPath,     '   (hello-world entry)');
  WriteLn('  .gitignore       (entries appended)');
  WriteLn;

  { Post-init install + build chain. Interactive mode prompts (Y
    default) before running them so the user can opt out; --yes
    SKIPS the prompt + skips the actions (just the scaffold, the
    user runs install/build themselves). The lockfile is created
    by `lwpt install`, not by init — no need for an empty stub. }
  if AYes then
  begin
    WriteLn('next: `', PROGRAM_NAME, ' install` then `',
            PROGRAM_NAME, ' build` to fetch deps + compile.');
    Exit;
  end;

  if PromptYesNo('run `lwpt install` and `lwpt build` now?', True) then
  begin
    WriteLn;
    WriteLn('--- lwpt install ---');
    CmdInstall(MANIFEST_FILE, False);
    WriteLn;
    WriteLn('--- lwpt build ---');
    CmdBuild(MANIFEST_FILE, '', False, False);
    WriteLn;
    WriteLn('Run ./', BuildDir, '/', EntryName, ' to try it.');
  end
  else
    WriteLn('skipped install + build. Run `', PROGRAM_NAME,
            ' install` then `', PROGRAM_NAME, ' build` when ready.');
end;

{ ===========================================================================
  CmdRun — invoke a user-declared run-script (ADR-0013).

  AName is the section name (the manifest key for the script). When
  AName is empty, prints a list of every callable name (subcommands
  first, then user scripts). When AName matches no script and no
  subcommand, exits 1 with a hint listing both sets.

  Subcommand-aliasing (`lwpt run install` → `lwpt install`) is handled
  upstream in the CLI dispatcher (CLI.Subcommands.Run) — CmdRun is
  only reached for genuine user scripts. }
function RunUserScript(const AHook: THook): Integer; forward;

function CmdRun(const AManifestPath, AName: string): Integer;
var
  Man : TManifest;
  i   : Integer;
  Found : THook;
  Hit : Boolean;
begin
  Man := LoadManifest(AManifestPath);

  { Empty name → list mode (npm-run convention). }
  if AName = '' then
  begin
    WriteLn('available scripts:');
    if Length(Man.Scripts) = 0 then
      WriteLn('  (none — declare a top-level section with a `script` field)')
    else
      for i := 0 to High(Man.Scripts) do
        WriteLn('  ', Man.Scripts[i].Name, '  ',
                Man.Scripts[i].Script);
    WriteLn;
    WriteLn('subcommand aliases (also valid via `', PROGRAM_NAME, ' run <name>`):');
    WriteLn('  install  build  format  test  export  repair  init');
    Exit(0);
  end;

  { Look up by name. Scripts are root-only and already validated
    against subcommand-name collisions at manifest load. }
  Hit := False;
  for i := 0 to High(Man.Scripts) do
    if Man.Scripts[i].Name = AName then
    begin
      Found := Man.Scripts[i];
      Hit := True;
      Break;
    end;

  if not Hit then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: no script named "',
      AName, '"');
    if Length(Man.Scripts) > 0 then
    begin
      Write(ErrOutput, '  available scripts: ');
      for i := 0 to High(Man.Scripts) do
      begin
        if i > 0 then Write(ErrOutput, ', ');
        Write(ErrOutput, Man.Scripts[i].Name);
      end;
      WriteLn(ErrOutput);
    end
    else
      WriteLn(ErrOutput, '  (no scripts declared in ', AManifestPath, ')');
    Exit(1);
  end;

  { Execute the script directly and propagate its exit code (npm-run
    convention). Differs from lifecycle hooks (which raise on non-zero
    to abort the phase): a user-invoked script's exit code is the
    *answer* the user is asking for, so any propagation other than
    "what the script returned" loses information. }
  Result := RunUserScript(Found);
end;

function RunUserScript(const AHook: THook): Integer;
var
  ScriptError: string;
begin
  if not FileExists(AHook.Script) then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: script not found at ',
      AHook.Script);
    Exit(127);
  end;
  Result := RunPascalScript(AHook, ScriptError);
  if ScriptError <> '' then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: ', ScriptError, '.');
    if Result = 0 then Result := 1;
  end;
end;

end.
