{ LWPT.Manifest — manifest model, intake, and source/version parsing. }
unit LWPT.Manifest;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.Core,
  TOML;

const
  MANIFEST_DUPLICATION_DEFAULT_MINIMUM_TOKENS = 100;
  MANIFEST_DUPLICATION_MINIMUM_TOKEN_FLOOR = 25;

type
  TLWPTRunnableCommand = record
    Command: string;
    Args: TStringArray;
  end;

  TLWPTCompilerProfile = record
    Name: string;
    Driver: string;
    Runnable: TLWPTRunnableCommand;
    VersionConstraint: string;
  end;
  TLWPTCompilerProfileArray = array of TLWPTCompilerProfile;

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


  { A single lifecycle hook entry (ADR-0011). The command is
    required; Args is optional (and may be empty). The Inputs/Output
    pair is the staleness gate — both present => skip when output is
    fresher than every input; both absent => run unconditionally;
    exactly one present => manifest-load error. The Name is the
    free-form hook key from the manifest (TOML bare-key syntax) and
    drives log lines like "  running [prebuild] embed-testing-library". }
  THook = record
    Name   : string;
    Runnable: TLWPTRunnableCommand;
    { The command exactly as declared in the manifest, before
      placeholder interpolation. Surface-rendering consumers (the
      agents block) use this so generated docs stay identical across
      platforms; execution always uses the interpolated command. }
    RawCommand : string;
    RawArgs : TStringArray;
    Inputs : array of string;
    Output : string;
  end;
  THookArray = array of THook;

  TLWPTBuildEntry = record
    Name      : string;            { logical name, e.g. "cli" }
    Source    : string;            { entry-point .pas/.dpr path }
    Output    : string;            { optional output binary path }
    Depends   : TStringArray;      { prerequisite entry names (ADR-0023) }
    Flags     : TStringArray;      { ordered compiler-driver arguments }
    CompilerProfile: string;       { named root [compiler] profile }
    HasTarget : Boolean;
    Target    : TLWPTTarget;       { optional explicit compiler target }
    PreBuild  : THookArray;        { per-entry prebuild hooks (ADR-0011) }
    PostBuild : THookArray;        { per-entry postbuild hooks (ADR-0011) }
  end;

  TManifest = record
    Name    : string;
    Version : string;
    Units   : array of string;   { source/unit dirs to expose as -Fu }
    Includes: array of string;   { -Fi dirs }
    FpcFlags: array of string;
    Deps    : array of TDependency;
    BuildEntries : array of TLWPTBuildEntry; { [build] entries for `lwpt build` }
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
    { [test] compiler and scheduler policy. Flags are ordered compiler-driver
      arguments for every test compile and are loaded only from the root
      manifest. Zero bail means run the complete queue even after failures;
      positive values stop at that failure count. }
    TestFlags   : TStringArray;
    TestBail    : Integer;
    { Compiler configuration is executable policy and root-owned. }
    CompilerDefault: string;
    CompilerProfiles: TLWPTCompilerProfileArray;
    { User-defined run tasks (ADR-0013). Any unrecognised top-
      level section with a `command` field becomes callable through
      `lwpt run <section-name>`. The structural shape is identical
      to a hook (command/args/inputs/output), so
      we reuse THook. Section names matching any LWPT subcommand
      are a hard error at manifest load; bare unrecognised sections
      without `command` keep the warn-and-drop policy. Root-only,
      same as hooks. }
    RunTasks    : THookArray;
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
    { [analysis] owns only the shared source scope. Command-specific
      thresholds and policy remain in their command sections. A workspace
      that declares this section replaces the root defaults; otherwise the
      root scope configuration is inherited. }
    AnalysisConfigured  : Boolean;
    AnalysisIncludes    : TStringArray;
    AnalysisExcludes    : TStringArray;
    { [health] owns command-specific limits. -1 means absent. Workspaces
      inherit the root limits unless they declare their own [health] table. }
    HealthConfigured          : Boolean;
    HealthMaxRoutineCyclomatic: Integer;
    HealthMaxRoutineCognitive : Integer;
    HealthMaxFileCyclomatic   : Integer;
    HealthMaxFileCognitive    : Integer;
    HealthMaxHotspotScore     : Integer;
    { [duplication] owns clone-policy settings. A workspace with its own
      section replaces the inherited root settings; otherwise callers apply
      the root configuration. Zero MaximumPercent is meaningful, so the
      separate flag records whether a threshold was authored. }
    DuplicationConfigured: Boolean;
    DuplicationMinimumTokens: Integer;
    DuplicationMaximumPercentConfigured: Boolean;
    DuplicationMaximumPercent: Integer;
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

  TManifestContext = record
    Path        : string;
    ProjectRoot : string;
    Manifest    : TManifest;
  end;

function  SourceKindToStr(K: TSourceKind): string;
function  HostKindToStr(H: THostKind): string;
function  FindCustomSource(const ASources: TCustomSourceArray; const AName: string; out AOut: TCustomSource): Boolean;
function  ResolveModulesDir(const AMan: TManifest): string;
function  ResolveArchivesDir(const AMan: TManifest): string;
function  ResolveTmpDir(const AMan: TManifest): string;
function  ResolveCfgFile(const AMan: TManifest): string;
procedure ParseDependencySourceCore(const ASource: string; const ACustomSources: TCustomSourceArray; APermissive: Boolean; out AKind: TSourceKind; out AHost: THostKind; out AHostName: string; out ALocator: string);
procedure ParseDependencySource(const ASource: string; out AKind: TSourceKind; out AHost: THostKind; out ALocator: string);
procedure ParseVersionSpec(const ASpec: string; out AKind: TVersionKind; out AValue: string);
procedure ParseBareDepString(const ABare: string; const ACustomSources: TCustomSourceArray; var ADep: TDependency);
function  ValidPackageName(const S: string): Boolean;
function  LoadManifest(const APath: string): TManifest; overload;
function  LoadManifest(const APath: string; AIsRoot: Boolean): TManifest; overload;
function  LoadManifestSnapshot(const APath: string;
  out AContentHash: string): TManifest;
function  LoadManifestContext(const APath: string): TManifestContext;

implementation

uses
  StrUtils,

  LWPT.Manifest.Schema,
  OrderedStringMap,
  Platform,
  Semver;

function SourceKindToStr(K: TSourceKind): string;
begin
  case K of
    skGitHost : Result := 'githost';
    skURL     : Result := 'url';
    skLocal   : Result := 'local';
    skWorkspace : Result := 'workspace';
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

  if StartsWithStr(ASource, 'http://') then
    raise EManifestError.CreateFmt(
      'dependency source "%s" uses plain HTTP; use an https:// URL',
      [ASource]);

  if StartsWithStr(ASource, 'https://') then
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

procedure NormalizeWorkspaceSource(var ADep: TDependency);
var
  WorkspaceSpec: string;
begin
  if ADep.SrcKind <> skWorkspace then Exit;
  if ADep.SrcLocator = '' then
    raise EManifestError.CreateFmt(
      'dependency "%s": workspace source needs a spec '
      + '(`workspace:*` or `workspace:^X.Y.Z`)', [ADep.Name]);
  if ADep.VersionSpec <> '' then
    raise EManifestError.CreateFmt(
      'dependency "%s": workspace source carries its version spec; '
      + 'remove the separate version spec "%s"',
      [ADep.Name, ADep.VersionSpec]);
  WorkspaceSpec := ADep.SrcLocator;
  ADep.VersionSpec := WorkspaceSpec;
  if WorkspaceSpec = '*' then
    ADep.VersionKind := vkNone
  else
    ParseVersionSpec(WorkspaceSpec, ADep.VersionKind, ADep.VersionSpec);
  ADep.SrcLocator := '';  { filled by the resolver }
end;

{ The package-name grammar — one definition for every consumer:
  `lwpt init`'s prompts, `lwpt add`'s derived/--name validation, and
  the installer's refuse-to-prune guard against unsafe lockfile keys.
  Deliberately path-hostile: no separators, no dots, so a name can
  never traverse out of .lwpt/modules/ or .lwpt/archives/. }
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

{ ===========================================================================
  Manifest loading
  =========================================================================== }
{ ───────────────────────────────────────────────────────────────────
  Manifest dep readers — both the bare-string shorthand
  `name = "<source>@<spec>"` AND the inline-table form
  `name = { source = "...", version = "...", include = [...],
            exclude = [...] }`
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
  NormalizeWorkspaceSource(ADep);
end;

{ Read an array-of-strings TOML field from an inline-table node into
  the output dynamic array (cleared first). Skips non-string entries
  silently; defensive against future reader changes that might admit
  mixed-type arrays. Used by ParseTableDep for include / exclude. }
procedure ReadGlobArray(ANode: TTOMLNode; const AKey: string;
  var AValues: TStringArray);
var
  ArrNode, Item: TTOMLNode;
  i, n: Integer;
begin
  SetLength(AValues, 0);
  ArrNode := TomlGet(ANode, AKey);
  if not TomlIsArray(ArrNode) then Exit;
  for i := 0 to ArrNode.Items.Count - 1 do
  begin
    Item := ArrNode.Items[i];
    if TomlIsString(Item) then
    begin
      n := Length(AValues);
      SetLength(AValues, n + 1);
      AValues[n] := Item.ScalarText;
    end;
  end;
end;

{ Structural validation has already checked the registry's declared kind and
  item policy. This reader only projects the validated TOML array. }
procedure ReadValidatedStringArray(ANode: TTOMLNode; const AKey: string;
  var AValues: TStringArray);
var
  ArrNode: TTOMLNode;
  i: Integer;
begin
  SetLength(AValues, 0);
  ArrNode := TomlGet(ANode, AKey);
  if not TomlIsArray(ArrNode) then Exit;
  SetLength(AValues, ArrNode.Items.Count);
  for i := 0 to ArrNode.Items.Count - 1 do
    AValues[i] := ArrNode.Items[i].ScalarText;
end;

procedure ReadValidatedNonEmptyStringArray(ANode: TTOMLNode;
  const AKey: string; var AValues: TStringArray);
begin
  ReadValidatedStringArray(ANode, AKey, AValues);
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
      + '{ source = "...", version = "...", include = [...], '
      + 'exclude = [...] }. '
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
  NormalizeWorkspaceSource(ADep);
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
  CanonicalizePathGlobs(ADep.IncludeGlobs);
  CanonicalizePathGlobs(ADep.ExcludeGlobs);
end;

{ ===========================================================================
  Build-lifecycle hooks (ADR-0011) — parse hook tables + execute them.

  Two surface shapes that produce one record type. Bare-string shorthand:
    generate = "tools/generate"
  Inline-table form:
    build-version-inc = { command = "instantfpc",
                          args   = ["scripts/stamp-version.pas", "--flag", "v"],
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
    AHook.Runnable.Command := ANode.ScalarText;
    AHook.RawCommand := AHook.Runnable.Command;
    if AHook.Runnable.Command = '' then
      raise EManifestError.CreateFmt(
        '%s "%s": command must not be empty', [AContext, AName]);
    Exit;
  end;

  if TomlGet(ANode, 'script') <> nil then
    raise EManifestError.CreateFmt(
      '%s "%s": legacy "script" is no longer supported; use '
      + '"command" and explicit "args" (for Pascal, command = '
      + '"instantfpc"). See ADR-0011.', [AContext, AName]);
  if (TomlGet(ANode, 'command') <> nil)
     and not TomlIsString(TomlGet(ANode, 'command')) then
    raise EManifestError.CreateFmt(
      '%s "%s": command must be a string', [AContext, AName]);
  AHook.Runnable.Command := TomlStr(ANode, 'command', '');
  AHook.RawCommand := AHook.Runnable.Command;
  if AHook.Runnable.Command = '' then
    raise EManifestError.CreateFmt(
      '%s "%s": "command" field is required. See ADR-0011.',
      [AContext, AName]);

  ArgsNode := TomlGet(ANode, 'args');
  if TomlIsArray(ArgsNode) then
  begin
    SetLength(AHook.Runnable.Args, ArgsNode.Items.Count);
    for i := 0 to ArgsNode.Items.Count - 1 do
      AHook.Runnable.Args[i] := ArgsNode.Items[i].ScalarText;
    AHook.RawArgs := Copy(AHook.Runnable.Args, 0,
      Length(AHook.Runnable.Args));
  end;

  InputsNode := TomlGet(ANode, 'inputs');
  if TomlIsArray(InputsNode) then
  begin
    n := InputsNode.Items.Count;
    SetLength(AHook.Inputs, n);
    for i := 0 to n - 1 do
      AHook.Inputs[i] := InputsNode.Items[i].ScalarText;
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
  everywhere; (2) per-entry context inside per-entry hook fields.

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
    AHooks[i].Runnable.Command := ExpandPlaceholders(
      AHooks[i].Runnable.Command, ACtx, HookPath + '.command');
    AHooks[i].Output := ExpandPlaceholders(AHooks[i].Output, ACtx,
      HookPath + '.output');
    ExpandStringArray(AHooks[i].Runnable.Args, ACtx, HookPath + '.args');
    ExpandStringArray(AHooks[i].Inputs, ACtx, HookPath + '.inputs');
  end;
end;


function ParseManifestContent(const APath, AContent: string;
  AIsRoot: Boolean): TManifest; forward;

procedure ReadManifestSnapshot(const APath: string; out AContent,
  AContentHash: string);
var
  Bytes: TBytes;
  ContentSize: SizeInt;
  Stream: TFileStream;
begin
  if not FileExists(APath) then
    raise EManifestError.CreateFmt('no manifest at %s', [APath]);
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    ContentSize := Stream.Size;
    SetLength(Bytes, ContentSize);
    if ContentSize > 0 then Stream.ReadBuffer(Bytes[0], ContentSize);
  finally
    Stream.Free;
  end;
  AContentHash := SHA256Hex(Bytes);
  if Length(Bytes) = 0 then
    AContent := ''
  else
    SetString(AContent, PAnsiChar(@Bytes[0]), Length(Bytes));
end;

function LoadManifest(const APath: string): TManifest;
begin
  { Public wrapper: most callers want root-manifest semantics (full
    parse, hook sections, unknown-section warnings, placeholder pass).
    The two-arg overload is for the resolver's dep-manifest walk
    (AIsRoot=False — supply-chain defense per ADR-0011 Q5). }
  Result := LoadManifest(APath, True);
end;

function LoadManifest(const APath: string; AIsRoot: Boolean): TManifest;
var
  Content, ContentHash: string;
begin
  ReadManifestSnapshot(APath, Content, ContentHash);
  Result := ParseManifestContent(APath, Content, AIsRoot);
end;

function LoadManifestSnapshot(const APath: string;
  out AContentHash: string): TManifest;
var
  Content: string;
begin
  ReadManifestSnapshot(APath, Content, AContentHash);
  Result := ParseManifestContent(APath, Content, True);
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
  Candidates, UniqueCandidates : TStringList;
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
    UniqueCandidates := TStringList.Create;
    try
      UniqueCandidates.Sorted := True;
      UniqueCandidates.Duplicates := dupIgnore;
      for i := 0 to Candidates.Count - 1 do
        UniqueCandidates.Add(Candidates[i]);
      Candidates.Assign(UniqueCandidates);
    finally
      UniqueCandidates.Free;
    end;
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

{ [build] entry names become path segments inside private build
  sessions. Quoted TOML keys can be any string, so reject empty and
  dot segments before staging. Root manifests only: a dependency's
  [build] entries are never built by the consumer. }
procedure ValidateBuildEntryName(const AName: string);
begin
  if (AName = '') or (AName = '.') or (AName = '..') then
    raise EManifestError.CreateFmt(
      'invalid [build] entry name "%s" — an entry name must not be '
      + 'empty, ".", or ".."', [AName]);
end;

function CompilerProfileDeclared(
  const AProfiles: TLWPTCompilerProfileArray;
  const AName: string): Boolean;
var
  ProfileIndex: Integer;
begin
  for ProfileIndex := 0 to High(AProfiles) do
    if SameText(AProfiles[ProfileIndex].Name, AName) then Exit(True);
  Result := False;
end;

procedure ParseBuildTarget(ANode: TTOMLNode; var AEntry: TLWPTBuildEntry);
begin
  if ANode = nil then Exit;
  AEntry.HasTarget := True;
  AEntry.Target.OS := TomlStr(ANode, 'os', '');
  AEntry.Target.Architecture := TomlStr(ANode, 'architecture', '');
  AEntry.Target.ABI := TomlStr(ANode, 'abi', '');
  AEntry.Target.Environment := TomlStr(ANode, 'environment', '');
end;

function ParseManifestContent(const APath, AContent: string;
  AIsRoot: Boolean): TManifest;
var
  Root, Deps, DepNode, ArrNode : TTOMLNode;
  BuildNode, EntryNode, VerNode   : TTOMLNode;
  LwptCfgNode, FmtNode, AnalysisNode, HealthNode, DuplicationNode,
    MinimumTokensNode, MaximumPercentNode, TestNode, BailNode,
    ExclArr : TTOMLNode;
  SourcesNode, SourceEntry     : TTOMLNode;
  CompilerNode, ProfilesNode, ProfileNode: TTOMLNode;
  Parser   : TTOMLParser;
  Pair     : TTOMLNodeMap.TKeyValuePair;
  i, j, n  : Integer;
  D        : TDependency;
  Entry        : TLWPTBuildEntry;
  CompilerProfile: TLWPTCompilerProfile;
  CS       : TCustomSource;
  Hook     : THook;
  Ctx      : TPlaceholderCtx;
  IsKnown  : Boolean;
  BailValue, DuplicationValue: Int64;
  k        : Integer;
  EntryCtx   : TPlaceholderCtx;
  EntryPath  : string;
begin
  { Reset Result explicitly. Pascal's `function F: TRecord` returns
    by value via a hidden var argument in FPC's calling convention;
    when called as `ChildMan := LoadManifest(...)`, Result IS
    ChildMan's storage. Without this reset, dynamic-array fields
    like Result.Units accumulate across calls (the previous call's
    contents survive + the new parse appends on top). Bites
    transitive-resolver walks that load N child manifests. }
  Result := Default(TManifest);
  Result.HealthMaxRoutineCyclomatic := -1;
  Result.HealthMaxRoutineCognitive := -1;
  Result.HealthMaxFileCyclomatic := -1;
  Result.HealthMaxFileCognitive := -1;
  Result.HealthMaxHotspotScore := -1;
  Result.DuplicationMinimumTokens :=
    MANIFEST_DUPLICATION_DEFAULT_MINIMUM_TOKENS;
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    Root := Parser.ParseDocument(AContent);
  finally
    Parser.Free;
  end;

  try
    ValidateManifestStructure(Root, AIsRoot);
    Result.Name    := TomlStr(TomlGet(Root, 'package'), 'name', '');
    Result.Version := TomlStr(TomlGet(Root, 'package'), 'version',
      MANIFEST_DEFAULT_PACKAGE_VERSION);
    if Result.Name = '' then
      Result.Name := TomlStr(Root, 'name', MANIFEST_DEFAULT_NAME);

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
        if not StartsWithStr(CS.ArchiveTemplate, 'https://') then
          raise EManifestError.CreateFmt(
            '[sources] %s: archive template "%s" must use https://',
            [CS.Name, CS.ArchiveTemplate]);
        if not StartsWithStr(CS.GitTemplate, 'https://') then
          raise EManifestError.CreateFmt(
            '[sources] %s: git template "%s" must use https://',
            [CS.Name, CS.GitTemplate]);
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
      include = [...], exclude = [...] }`. The earlier shape (separate
      source/repo/ref
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

    { [analysis] is deliberately limited to shared source selection. The
      duplication and health commands own their payloads and thresholds in
      their own sections. Parse this for root and workspace manifests so the
      scope resolver can apply root defaults unless a workspace opts out with
      an explicit section. }
    AnalysisNode := TomlGet(Root, 'analysis');
    if TomlIsTable(AnalysisNode) then
    begin
      Result.AnalysisConfigured := True;
      ReadValidatedStringArray(AnalysisNode, 'include',
        Result.AnalysisIncludes);
      ReadValidatedStringArray(AnalysisNode, 'exclude',
        Result.AnalysisExcludes);
    end;

    { [health] limits are strict non-negative integers. Limits are optional;
      absent values preserve report-only behavior. Hotspot scores use the
      documented 0..100 normalized scale. }
    HealthNode := TomlGet(Root, 'health');
    if TomlIsTable(HealthNode) then
    begin
      Result.HealthConfigured := True;

      BailNode := TomlGet(HealthNode, 'max-routine-cyclomatic');
      BailValue := TomlInt(HealthNode, 'max-routine-cyclomatic', -1);
      if ((BailNode <> nil) and (BailValue < 0))
        or (BailValue > High(Integer)) then
        raise EManifestError.Create(
          '[health] max-routine-cyclomatic must be a non-negative integer');
      Result.HealthMaxRoutineCyclomatic := Integer(BailValue);

      BailNode := TomlGet(HealthNode, 'max-routine-cognitive');
      BailValue := TomlInt(HealthNode, 'max-routine-cognitive', -1);
      if ((BailNode <> nil) and (BailValue < 0))
        or (BailValue > High(Integer)) then
        raise EManifestError.Create(
          '[health] max-routine-cognitive must be a non-negative integer');
      Result.HealthMaxRoutineCognitive := Integer(BailValue);

      BailNode := TomlGet(HealthNode, 'max-file-cyclomatic');
      BailValue := TomlInt(HealthNode, 'max-file-cyclomatic', -1);
      if ((BailNode <> nil) and (BailValue < 0))
        or (BailValue > High(Integer)) then
        raise EManifestError.Create(
          '[health] max-file-cyclomatic must be a non-negative integer');
      Result.HealthMaxFileCyclomatic := Integer(BailValue);

      BailNode := TomlGet(HealthNode, 'max-file-cognitive');
      BailValue := TomlInt(HealthNode, 'max-file-cognitive', -1);
      if ((BailNode <> nil) and (BailValue < 0))
        or (BailValue > High(Integer)) then
        raise EManifestError.Create(
          '[health] max-file-cognitive must be a non-negative integer');
      Result.HealthMaxFileCognitive := Integer(BailValue);

      BailNode := TomlGet(HealthNode, 'max-hotspot-score');
      BailValue := TomlInt(HealthNode, 'max-hotspot-score', -1);
      if ((BailNode <> nil) and (BailValue < 0)) or (BailValue > 100) then
        raise EManifestError.Create(
          '[health] max-hotspot-score must be an integer from 0 to 100');
      Result.HealthMaxHotspotScore := Integer(BailValue);
    end;

    { [duplication] — command-owned clone floor and optional quality gate.
      The shared [analysis] section continues to own file inclusion and
      exclusion. Integer percentages keep comparison and serialization
      deterministic on every supported RTL. }
    DuplicationNode := TomlGet(Root, 'duplication');
    if TomlIsTable(DuplicationNode) then
    begin
      Result.DuplicationConfigured := True;
      MinimumTokensNode := TomlGet(DuplicationNode, 'minimum-tokens');
      if MinimumTokensNode <> nil then
      begin
        DuplicationValue := TomlInt(DuplicationNode, 'minimum-tokens', -1);
        if (DuplicationValue < MANIFEST_DUPLICATION_MINIMUM_TOKEN_FLOOR)
          or (DuplicationValue > High(Integer)) then
          raise EManifestError.CreateFmt(
            '[duplication] minimum-tokens must be an integer of at least %d',
            [MANIFEST_DUPLICATION_MINIMUM_TOKEN_FLOOR]);
        Result.DuplicationMinimumTokens := Integer(DuplicationValue);
      end;
      MaximumPercentNode := TomlGet(DuplicationNode, 'maximum-percent');
      if MaximumPercentNode <> nil then
      begin
        DuplicationValue := TomlInt(DuplicationNode, 'maximum-percent', -1);
        if (DuplicationValue < 0) or (DuplicationValue > 100) then
          raise EManifestError.Create(
            '[duplication] maximum-percent must be an integer from 0 to 100');
        Result.DuplicationMaximumPercentConfigured := True;
        Result.DuplicationMaximumPercent := Integer(DuplicationValue);
      end;
    end;

    { [test] — scheduler policy. Configuration supplies the project
      default; the command-line --bail option can override it. }
    TestNode := TomlGet(Root, 'test');
    if TomlIsTable(TestNode) then
    begin
      if AIsRoot then
        ReadValidatedNonEmptyStringArray(TestNode, 'flags',
          Result.TestFlags);
      BailNode := TomlGet(TestNode, 'bail');
      if BailNode <> nil then
      begin
        BailValue := TomlInt(TestNode, 'bail', -1);
        if (BailValue < 0) or (BailValue > High(Integer)) then
          raise EManifestError.Create(
            '[test] bail must be a non-negative integer');
        Result.TestBail := Integer(BailValue);
      end;
    end;

    { [compiler] profiles can execute root-selected code, so dependency
      manifests never contribute them. }
    if AIsRoot then
    begin
      CompilerNode := TomlGet(Root, 'compiler');
      if TomlIsTable(CompilerNode) then
      begin
        Result.CompilerDefault := TomlStr(CompilerNode, 'default', '');
        ProfilesNode := TomlGet(CompilerNode, 'profiles');
        if TomlIsTable(ProfilesNode) then
          for Pair in ProfilesNode.Children do
          begin
            ProfileNode := Pair.Value;
            CompilerProfile := Default(TLWPTCompilerProfile);
            CompilerProfile.Name := Pair.Key;
            if CompilerProfileDeclared(Result.CompilerProfiles,
              CompilerProfile.Name) then
              raise EManifestError.CreateFmt(
                '[compiler.profiles] duplicate profile name "%s" '
                + '(profile names are case-insensitive)', [Pair.Key]);
            if TomlGet(ProfileNode, 'executable') <> nil then
              raise EManifestError.CreateFmt(
                '[compiler.profiles.%s] legacy executable is no longer '
                + 'supported; use command and args', [Pair.Key]);
            if TomlGet(ProfileNode, 'script') <> nil then
              raise EManifestError.CreateFmt(
                '[compiler.profiles.%s] legacy script is no longer '
                + 'supported; use command = "instantfpc" and put the '
                + 'script path first in args', [Pair.Key]);
            CompilerProfile.Driver := TomlStr(ProfileNode, 'driver', '');
            CompilerProfile.Runnable.Command := TomlStr(ProfileNode,
              'command', '');
            ReadValidatedStringArray(ProfileNode, 'args',
              CompilerProfile.Runnable.Args);
            CompilerProfile.VersionConstraint := TomlStr(ProfileNode,
              'version', MANIFEST_DEFAULT_COMPILER_VERSION);
            if CompilerProfile.Name = '' then
              raise EManifestError.Create(
                '[compiler.profiles] profile name must not be empty');
            n := Length(Result.CompilerProfiles);
            SetLength(Result.CompilerProfiles, n + 1);
            Result.CompilerProfiles[n] := CompilerProfile;
          end;
      end;
    end;

    BuildNode := TomlGet(Root, 'build');
    if TomlIsTable(BuildNode) then
    begin
      if TomlIsString(TomlGet(BuildNode, 'source')) then
      begin
        { Single-entry shorthand. The item gets name = package
          name; output defaults to "build/<name>" when absent. }
        Entry := Default(TLWPTBuildEntry);
        Entry.Name   := Result.Name;
        if AIsRoot then ValidateBuildEntryName(Entry.Name);
        Entry.Source := TomlStr(BuildNode, 'source', '');
        Entry.Output := TomlStr(BuildNode, 'output', '');
        ReadValidatedStringArray(BuildNode, 'depends',
          Entry.Depends);
        if AIsRoot then
        begin
          ReadValidatedNonEmptyStringArray(BuildNode, 'flags',
            Entry.Flags);
          Entry.CompilerProfile := TomlStr(BuildNode, 'compiler', '');
          ParseBuildTarget(TomlGet(BuildNode, 'target'), Entry);
        end;
        if Entry.Output = '' then Entry.Output := 'build/' + Result.Name;
        ParseHookSection(TomlGet(BuildNode, 'prebuild'),
          'build.prebuild', Entry.PreBuild);
        ParseHookSection(TomlGet(BuildNode, 'postbuild'),
          'build.postbuild', Entry.PostBuild);
        SetLength(Result.BuildEntries, 1);
        Result.BuildEntries[0] := Entry;
      end
      else
        for Pair in BuildNode.Children do
        begin
          EntryNode := Pair.Value;
          Entry := Default(TLWPTBuildEntry);
          Entry.Name := Pair.Key;
          if AIsRoot then ValidateBuildEntryName(Entry.Name);
          if TomlIsString(EntryNode) then
            Entry.Source := EntryNode.ScalarText  { item-name = "path.pas" }
          else if TomlIsTable(EntryNode) then
          begin
            Entry.Source := TomlStr(EntryNode, 'source', '');
            Entry.Output := TomlStr(EntryNode, 'output', '');
            ReadValidatedStringArray(EntryNode, 'depends', Entry.Depends);
            if AIsRoot then
            begin
              ReadValidatedNonEmptyStringArray(EntryNode, 'flags', Entry.Flags);
              Entry.CompilerProfile := TomlStr(EntryNode, 'compiler', '');
              ParseBuildTarget(TomlGet(EntryNode, 'target'), Entry);
            end;
            ParseHookSection(TomlGet(EntryNode, 'prebuild'),
              'build.' + Entry.Name + '.prebuild', Entry.PreBuild);
            ParseHookSection(TomlGet(EntryNode, 'postbuild'),
              'build.' + Entry.Name + '.postbuild', Entry.PostBuild);
          end;
          j := Length(Result.BuildEntries);
          SetLength(Result.BuildEntries, j + 1);
          Result.BuildEntries[j] := Entry;
        end;
    end;

    if AIsRoot then
    begin
      if (Result.CompilerDefault <> '')
         and not CompilerProfileDeclared(Result.CompilerProfiles,
           Result.CompilerDefault) then
        raise EManifestError.CreateFmt(
          '[compiler] default names undeclared compiler profile "%s"',
          [Result.CompilerDefault]);
      for i := 0 to High(Result.BuildEntries) do
        if (Result.BuildEntries[i].CompilerProfile <> '')
           and not CompilerProfileDeclared(Result.CompilerProfiles,
             Result.BuildEntries[i].CompilerProfile) then
          raise EManifestError.CreateFmt(
            'build.%s.compiler names undeclared compiler profile "%s"',
            [Result.BuildEntries[i].Name,
             Result.BuildEntries[i].CompilerProfile]);
    end;

    { [version] — optional version-baking config }
    VerNode := TomlGet(Root, 'version');
    if TomlIsTable(VerNode) then
    begin
      Result.VersionIncOut := TomlStr(VerNode, 'output', '');
      Result.VersionPrefix := TomlStr(VerNode, 'prefix',
        MANIFEST_DEFAULT_VERSION_PREFIX);
    end
    else
      Result.VersionPrefix := MANIFEST_DEFAULT_VERSION_PREFIX;

    { [lwpt] — toolkit-state overrides. Empty string in the slot means
      "use the default" from the LWPT_DIR / MODULES_DIR / ... constants. }
    LwptCfgNode := TomlGet(Root, PROGRAM_NAME);
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
          (a) a run task (ADR-0013) — when the section is a table
              with a `command` field. The section name becomes the
              `lwpt run <name>` invocation. Reserved subcommand
              names (install/build/format/test/repair/init/
              run) are a hard error here.
          (b) a typo / dead config — anything else. One-line warning
              to stderr; section silently dropped (the [teddybear]
              case). Includes the legacy [generated] + [targets]
              names removed in earlier waves. }
      for Pair in Root.Children do
      begin
        if IsKnownManifestSection(Pair.Key) then Continue;

        { Run-task detection: section is a table carrying a
          `command` field. Bare-string sections aren't possible in
          TOML (section values are always tables). }
        if TomlIsTable(Pair.Value)
           and (TomlGet(Pair.Value, 'script') <> nil) then
          raise EManifestError.CreateFmt(
            'section [%s]: legacy "script" is no longer supported; '
            + 'use "command" and explicit "args" (for Pascal, command '
            + '= "instantfpc")', [Pair.Key]);
        if TomlIsTable(Pair.Value)
           and (TomlGet(Pair.Value, 'command') <> nil) then
        begin
          { SameText, not `=`: subcommand dispatch is case-insensitive
            (the CLI lowercases argv and Find uses SameText), so a
            case-variant section like [Agents] would list as a task
            yet be unreachable — `lwpt run Agents` dispatches the
            built-in. The reservation must match dispatch semantics. }
          if IsReservedManifestTaskName(Pair.Key) then
            raise EManifestError.CreateFmt(
              'section [%s] shadows the built-in subcommand and '
              + 'cannot be used as a run task. Rename the section '
              + '(e.g. [%s-task]) or invoke the subcommand directly '
              + '(`%s %s`). See ADR-0013.',
              [Pair.Key, Pair.Key, PROGRAM_NAME, Pair.Key]);
          { Parse as a run task using the same shape as a hook entry. }
          ParseHookEntry(Pair.Value, Pair.Key,
            '[' + Pair.Key + ']', Hook);
          n := Length(Result.RunTasks);
          SetLength(Result.RunTasks, n + 1);
          Result.RunTasks[n] := Hook;
        end
        else
          WriteLn(ErrOutput, 'warning: unrecognised section [',
            Pair.Key, '] — ignored');
      end;

      { Placeholder pass (ADR-0012). Two stages: project + build
        variables first across entries + whole-build hooks; then per-entry
        variables across each entry's hook fields. The per-entry
        source/output gets only {item.name}; its other item fields would be
        recursive. }
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
      for i := 0 to High(Result.BuildEntries) do
      begin
        EntryCtx := Ctx;
        EntryCtx.HasItemName := True;
        EntryCtx.ItemName    := Result.BuildEntries[i].Name;
        EntryPath := 'build.' + Result.BuildEntries[i].Name;
        Result.BuildEntries[i].Source :=
          ExpandPlaceholders(Result.BuildEntries[i].Source, EntryCtx, EntryPath + '.source');
        Result.BuildEntries[i].Output :=
          ExpandPlaceholders(Result.BuildEntries[i].Output, EntryCtx, EntryPath + '.output');
      end;

      ExpandHookArray(Result.PreInstall,  Ctx, 'preinstall');
      ExpandHookArray(Result.PostInstall, Ctx, 'postinstall');
      ExpandHookArray(Result.PreBuild,    Ctx, 'prebuild');
      ExpandHookArray(Result.PostBuild,   Ctx, 'postbuild');
      ExpandHookArray(Result.PreTest,     Ctx, 'pretest');
      ExpandHookArray(Result.PostTest,    Ctx, 'posttest');
      { Run tasks (ADR-0013). Same namespace as whole-build hooks:
        no item context. The command / args may use {package.*}
        and {platform.*}; {item.*} is a hard error (no item in scope). }
      ExpandHookArray(Result.RunTasks, Ctx, 'run');

      { Pass 2 over build items: per-item hook fields get the
        FULL item namespace ({item.name} + {item.source} +
        {item.output} all bound to post-pass-1 values). Whole-
        build hooks ran with HasItemName=False so {item.*} was
        a hard error there. }
      for i := 0 to High(Result.BuildEntries) do
      begin
        EntryCtx := Ctx;
        EntryCtx.HasItemName   := True;
        EntryCtx.HasItemFields := True;
        EntryCtx.ItemName      := Result.BuildEntries[i].Name;
        EntryCtx.ItemSource    := Result.BuildEntries[i].Source;
        EntryCtx.ItemOutput    := Result.BuildEntries[i].Output;
        EntryPath := 'build.' + Result.BuildEntries[i].Name;
        ExpandHookArray(Result.BuildEntries[i].PreBuild,  EntryCtx,
          EntryPath + '.prebuild');
        ExpandHookArray(Result.BuildEntries[i].PostBuild, EntryCtx,
          EntryPath + '.postbuild');
      end;
    end;
  finally
    Root.Free;
  end;
end;

function LoadManifestContext(const APath: string): TManifestContext;
begin
  Result.Path := APath;
  Result.ProjectRoot := ExtractFilePath(ExpandFileName(APath));
  Result.Manifest := LoadManifest(APath);
end;

end.
