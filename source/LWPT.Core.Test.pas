{ LWPT.Core.Test — unit-tier coverage for the testable internals
  exposed in a later cycle: SHA256Hex against NIST vectors, LoadManifest happy
  and error paths, plus per-section parsing for [lwpt], [format],
  hook sections (ADR-0011), and placeholder interpolation (ADR-0012).

  Integration-style tests that exercise the resolver + extractor + cfg
  emission live under tests/integration/. This file stays at the unit
  level: in-memory data, pure functions, temp manifests written out
  inline. }

program LWPT.Core.Test;

{$mode delphi}{$H+}
{$modeswitch nestedcomments+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.GitProtocol,
  LWPT.Install,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  TSHA256NISTVectors = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmptyString;
    procedure TestAbc;
    procedure TestExactlyOneBlock;
    procedure TestSpansTwoBlocks;
  end;

  TLoadManifestHappy = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMinimalManifestNameAndVersion;
    procedure TestPackageUnitsArrayParsed;
    procedure TestTargetsTable;
    procedure TestVersionSection;
  end;

  TLoadManifestValidation = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBareStringDepShorthandRejected;
    procedure TestDepWithoutSourceRejected;
    procedure TestDepWithHttpSourceRejected;
    procedure TestUnknownSourceKindRejected;
    procedure TestMissingManifestRejected;
  end;

  TLoadManifestExtensions = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestLwptOverridesParsed;
    procedure TestFormatExcludesParsed;
    procedure TestPrebuildHookEntriesParsed;
    procedure TestHookShorthandStringForm;
    procedure TestHookPairedInputsOutputRequired;
    procedure TestPerTargetHooksParsed;
    procedure TestUnknownSectionEmitsWarning;
  end;

  { LoadLockfile + schema-versioning + corruption recovery. }
  TLockfileLoading = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMissingLockfileRaisesELockfileError;
    procedure TestCorruptTOMLRaisesELockfileError;
    procedure TestMissingSchemaVersionRaisesELockfileError;
    procedure TestSchemaV1RaisesWithMigrationHint;
    procedure TestEmptyPackageTableReturnsEmptyArray;
    procedure TestPackageEntriesRoundTripFields;
  end;

  { VerifyAgainstLockfile cross-checks. Exercises every mismatch
    path that --frozen guards against, without requiring a network
    source. Local-source diamond's frozen-tamper integration test
    covers the tree-hash path end-to-end; these unit tests cover the
    archive-hash + missing-entry paths that the diamond can't reach
    (local source = no archive). }
  TVerifyAgainstLockfile = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMatchingEntriesPass;
    procedure TestTreeHashMismatchRaises;
    procedure TestArchiveHashMismatchRaises;
    procedure TestManifestDepWithoutLockEntryRaises;
    procedure TestLockEntryWithoutGraphNodeRaises;
    procedure TestLocalSourceWithEmptyArchiveHashPasses;
  end;

  { ParseDependencySource: every prefix shape + default github +
    path forms + the unambiguous-error path. }
  TParseDependencySource = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBareOwnerRepoDefaultsToGitHub;
    procedure TestGitLabPrefix;
    procedure TestBitbucketPrefix;
    procedure TestGithubPrefixExplicit;
    procedure TestUnknownPrefixRejected;
    procedure TestHttpsURLIsURLKind;
    procedure TestHttpURLRejected;
    procedure TestLocalDotSlashPath;
    procedure TestLocalParentSlashPath;
    procedure TestLocalAbsolutePath;
    procedure TestLocalWindowsAbsolutePath;
    procedure TestLocalTildeSlashPath;
    procedure TestLocalExplicitPrefix;
    procedure TestEmptyStringRejected;
    procedure TestNoSlashRejected;
  end;

  { ParseVersionSpec: the four buckets + the load-bearing
    v-prefix-as-literal-tag rule. }
  TParseVersionSpec = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmptySpecIsNone;
    procedure TestSemverRangeCaret;
    procedure TestSemverRangeTilde;
    procedure TestSemverRangeGtLt;
    procedure TestSemverExactSimple;
    procedure TestSemverExactPrerelease;
    procedure TestVPrefixedIsLiteralTagNotSemver;
    procedure TestCommitShaShort;
    procedure TestCommitShaFull;
    procedure TestLiteralBranchName;
    procedure TestLiteralReleaseTag;
  end;

  { pkt-line + ParseInfoRefs against captured GitHub fixture-shape
    payloads. Exercises the service-announce skip, the capability NUL
    stripping, the peel-suffix discard (annotated tags), and the
    tags/heads classification. }
  TGitProtocolParsing = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmptyPayloadReturnsEmpty;
    procedure TestServiceAnnounceIsSkipped;
    procedure TestHeadWithCapabilitiesIsRecognised;
    procedure TestTagsAndBranchesAreSeparated;
    procedure TestPeelSuffixIsDiscarded;
    procedure TestMultipleTags;
  end;

  { ApplyIncludeExclude against synthesised file trees.
    Covers the formatter-mirror semantics: neither set \u2192 keep all;
    include-only \u2192 keep only matching files; exclude-only \u2192 drop
    matching files; both \u2192 include first, then exclude from that
    set; empty directories are reaped. }
  TApplyIncludeExclude = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
    procedure PlantTree;
    function  Exists(const ARel: string): Boolean;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestNeitherSetKeepsEverything;
    procedure TestIncludeOnlyKeepsMatches;
    procedure TestExcludeOnlyDropsMatches;
    procedure TestBothCombines;
    procedure TestEmptyDirectoriesReaped;
    procedure TestExcludeOverridesInclude;
  end;

  { CopyDirTree's recursion guards: directory symlinks are never
    followed (a link cycle would recurse until the OS path-length
    limit), file symlinks are copied through, and a destination
    inside the source raises instead of recursing forever. The link
    fixtures are Unix-only (FpSymlink); the dst-inside-src cases run
    everywhere. }
  TCopyDirTreeGuards = class(TTestSuite)
  private
    FScratch: string;
    function  Src: string;
    function  Dst: string;
    procedure ResetScratch;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestCopiesNestedTree;
    procedure TestDirSymlinkCycleTerminatesAndIsNotCopied;
    procedure TestFileSymlinkCopiedThrough;
    procedure TestDstInsideSrcRaises;
    procedure TestDstEqualsSrcRaises;
  end;

  { WipeDir against symlink entries. The dangling case is the
    regression: without faSymLink in the FindFirst mask a dangling
    link (including one whose target the wipe itself just deleted)
    is invisible to the enumeration, survives, and the final
    RemoveDir fails. Links must also never be followed — a link to a
    directory outside the wiped tree must lose the link, not the
    target's contents. Unix-only fixtures (FpSymlink). }
  TWipeDirSymlinks = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestDanglingLinkIsRemoved;
    procedure TestLinkTargetOutsideTreeSurvives;
  end;

  { MatchPathGlob: path-vs-glob matching for [dependencies]
    include / exclude. Covers single-segment wildcards (`*`, `?`),
    recursive wildcard (`**`), and the edge cases that trip naive
    implementations (trailing `**`, leading `**`, `**` matching zero
    segments). }
  TPathGlobMatching = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestExactPathMatch;
    procedure TestSingleStarMatchesOneSegment;
    procedure TestSingleStarRejectsSlash;
    procedure TestDoubleStarMatchesAnyDepth;
    procedure TestDoubleStarMatchesZeroSegments;
    procedure TestQuestionMatchesOneChar;
    procedure TestExtensionGlob;
    procedure TestTrailingDoubleStar;
    procedure TestLeadingDoubleStar;
    procedure TestNoMatchOnDifferentFile;
  end;

  { [sources] custom-prefix declaration with placeholder URL
    templates + LoadManifest validation + dep parsing against
    custom-source context + URL rendering. Per ADR-0009: each entry
    declares an `archive` URL template and a `git` URL template with
    [user]/[repository]/[ref] placeholders. No template-name shortcut. }
  TCustomSources = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmptyManifestHasNoCustomSources;
    procedure TestSingleCustomSourceParsed;
    procedure TestMissingArchiveTemplateRejected;
    procedure TestMissingGitTemplateRejected;
    procedure TestArchiveTemplateMissingRefPlaceholderRejected;
    procedure TestArchiveTemplateMissingUserPlaceholderRejected;
    procedure TestGitTemplateMissingRepositoryPlaceholderRejected;
    procedure TestArchiveTemplateHttpRejected;
    procedure TestGitTemplateHttpRejected;
    procedure TestShadowingBuiltinPrefixRejected;
    procedure TestDepWithCustomPrefixRoutes;
    procedure TestDepWithUndeclaredCustomPrefixRejected;
    procedure TestLockfilePermissiveOnUnknownPrefix;
  end;

const
  TMP_DIR = 'build/tests/fixtures/core';

{ ── helpers ───────────────────────────────────────────────────────── }

function WriteManifest(const ASuffix, AContent: string): string;
var
  SL: TStringList;
begin
  ForceDirectories(TMP_DIR);
  Result := TMP_DIR + '/' + ASuffix + '.toml';
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

function StringAsBytes(const S: string): TBytes;
var i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i - 1] := Ord(S[i]);
end;

function RepeatBytes(const AByte: Byte; const ACount: Integer): TBytes;
var i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do Result[i] := AByte;
end;

{ Assert that loading APath raises EManifestError whose message
  contains AMessageContains. Inlined here (not a helper that takes a
  proc reference) because FPC 3.2.2 + delphi mode is fussy about TProc
  visibility and anonymous-method syntax. The bookkeeping is small
  enough to read at each call site. }
procedure ExpectManifestLoadError(const APath, AMessageContains: string;
  ASuite: TTestSuite);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    LoadManifest(APath);
  except
    on E: EManifestError do
    begin
      Raised := True;
      if Pos(AMessageContains, E.Message) = 0 then
        ASuite.Fail(Format(
          'Expected EManifestError message to contain "%s"; got: %s',
          [AMessageContains, E.Message]));
    end;
  end;
  if not Raised then
    ASuite.Fail(Format(
      'Expected EManifestError loading %s; nothing was raised', [APath]));
  { Satisfy the framework's "test had an assertion" gate. }
  Expect<Boolean>(Raised).ToBe(True);
end;

{ ── TSHA256NISTVectors ────────────────────────────────────────────── }

{ NIST FIPS 180-4 test vectors. Catches drift in the inlined SHA-256
  the resolver uses for tree-hash + for archive verification. }

procedure TSHA256NISTVectors.TestEmptyString;
const EXPECTED = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
begin
  Expect<string>(SHA256Hex(StringAsBytes(''))).ToBe(EXPECTED);
end;

procedure TSHA256NISTVectors.TestAbc;
const EXPECTED = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
begin
  Expect<string>(SHA256Hex(StringAsBytes('abc'))).ToBe(EXPECTED);
end;

procedure TSHA256NISTVectors.TestExactlyOneBlock;
const
  { 448-bit string (56 bytes) — the boundary case where the 0x80 pad
    fits in the same block as the message but the length doesn't,
    forcing a second padding block. }
  EXPECTED = '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1';
begin
  Expect<string>(SHA256Hex(StringAsBytes(
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))).ToBe(EXPECTED);
end;

procedure TSHA256NISTVectors.TestSpansTwoBlocks;
const
  EXPECTED = 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';
begin
  { 1,000,000 repetitions of "a" — the standard "long message" NIST
    vector. Exercises the multi-block iteration path proper. }
  Expect<string>(SHA256Hex(RepeatBytes(Ord('a'), 1000000))).ToBe(EXPECTED);
end;

procedure TSHA256NISTVectors.SetupTests;
begin
  Test('empty string vector',                  TestEmptyString);
  Test('"abc" vector',                         TestAbc);
  Test('56-byte vector (block-boundary pad)',  TestExactlyOneBlock);
  Test('1,000,000 "a" vector (multi-block)',   TestSpansTwoBlocks);
end;

{ ── TLoadManifestHappy ────────────────────────────────────────────── }

procedure TLoadManifestHappy.TestMinimalManifestNameAndVersion;
const
  INPUT =
    '[package]'#10 +
    'name = "minimal"'#10 +
    'version = "0.1.2"'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('minimal', INPUT));
  Expect<string>(Man.Name).ToBe('minimal');
  Expect<string>(Man.Version).ToBe('0.1.2');
  Expect<Integer>(Length(Man.Deps)).ToBe(0);
  Expect<Integer>(Length(Man.Targets)).ToBe(0);
end;

procedure TLoadManifestHappy.TestPackageUnitsArrayParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "with-units"'#10 +
    'version = "0.1.0"'#10 +
    'units = ["src", "shared", "tools"]'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('units', INPUT));
  Expect<Integer>(Length(Man.Units)).ToBe(3);
  Expect<string>(Man.Units[0]).ToBe('src');
  Expect<string>(Man.Units[1]).ToBe('shared');
  Expect<string>(Man.Units[2]).ToBe('tools');
end;

procedure TLoadManifestHappy.TestTargetsTable;
const
  INPUT =
    '[package]'#10 +
    'name = "with-build-items"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'cli = { source = "src/cli.pas", output = "bin/cli" }'#10 +
    'tool = { source = "src/tool.pas" }'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('build-items', INPUT));
  Expect<Integer>(Length(Man.Targets)).ToBe(2);
  Expect<string>(Man.Targets[0].Name).ToBe('cli');
  Expect<string>(Man.Targets[0].Source).ToBe('src/cli.pas');
  Expect<string>(Man.Targets[0].Output).ToBe('bin/cli');
  Expect<string>(Man.Targets[1].Name).ToBe('tool');
  Expect<string>(Man.Targets[1].Source).ToBe('src/tool.pas');
  Expect<string>(Man.Targets[1].Output).ToBe('');
end;

procedure TLoadManifestHappy.TestVersionSection;
const
  INPUT =
    '[package]'#10 +
    'name = "with-version-baking"'#10 +
    'version = "2.0.0"'#10 +
    ''#10 +
    '[version]'#10 +
    'output = "src/Version.Generated.inc"'#10 +
    'prefix = "APP"'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('version', INPUT));
  Expect<string>(Man.VersionIncOut).ToBe('src/Version.Generated.inc');
  Expect<string>(Man.VersionPrefix).ToBe('APP');
end;

procedure TLoadManifestHappy.SetupTests;
begin
  Test('minimal manifest: name + version',  TestMinimalManifestNameAndVersion);
  Test('[package] units array parsed',      TestPackageUnitsArrayParsed);
  Test('[build] table with output + bare-source entries', TestTargetsTable);
  Test('[version] section parsed',          TestVersionSection);
end;

{ ── TLoadManifestValidation ───────────────────────────────────────── }

procedure TLoadManifestValidation.TestBareStringDepShorthandRejected;
const
  INPUT =
    '[package]'#10 +
    'name = "bare-shorthand"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'horse = "^1.0.0"'#10;
begin
  { bare-string shorthand IS valid now, but "^1.0.0" doesn't parse
    as a source string (it looks like a SemVer range, not a locator). }
  ExpectManifestLoadError(
    WriteManifest('bare-shorthand', INPUT),
    'cannot parse dependency source',
    Self);
end;

procedure TLoadManifestValidation.TestDepWithoutSourceRejected;
const
  INPUT =
    '[package]'#10 +
    'name = "no-source"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'horse = { version = "^1.0.0" }'#10;
begin
  ExpectManifestLoadError(
    WriteManifest('no-source', INPUT),
    'missing required "source"',
    Self);
end;

procedure TLoadManifestValidation.TestDepWithHttpSourceRejected;
const
  INPUT =
    '[package]'#10 +
    'name = "http-source"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'horse = { version = "^1.0.0", source = "http" }'#10;
begin
  { "http" as a source literal is the earlier kind selector;
    rejected with a migration hint pointing at ADR-0009. }
  ExpectManifestLoadError(
    WriteManifest('http-source', INPUT),
    'earlier kind selector',
    Self);
end;

procedure TLoadManifestValidation.TestUnknownSourceKindRejected;
const
  INPUT =
    '[package]'#10 +
    'name = "unknown-source"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'horse = { version = "^1.0.0", source = "svn:owner/horse" }'#10;
begin
  { unknown source prefix surfaces from ParseDependencySource. }
  ExpectManifestLoadError(
    WriteManifest('unknown-source', INPUT),
    'unknown source prefix',
    Self);
end;

procedure TLoadManifestValidation.TestMissingManifestRejected;
begin
  ExpectManifestLoadError(
    TMP_DIR + '/does-not-exist.toml',
    'no manifest at',
    Self);
end;

procedure TLoadManifestValidation.SetupTests;
begin
  Test('bare-string dep shorthand rejected (ADR-0004 migration)',
    TestBareStringDepShorthandRejected);
  Test('dep without "source" key rejected', TestDepWithoutSourceRejected);
  Test('dep with source = "http" rejected (ADR-0004)',
    TestDepWithHttpSourceRejected);
  Test('unknown source kind rejected',      TestUnknownSourceKindRejected);
  Test('missing manifest path rejected',    TestMissingManifestRejected);
end;

{ ── TLoadManifestExtensions ───────────────────────────────────────── }

procedure TLoadManifestExtensions.TestLwptOverridesParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "lwpt-overrides"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[lwpt]'#10 +
    'modules-dir = "vendor/modules"'#10 +
    'archives-dir = "vendor/archives"'#10 +
    'tmp-dir = ".cache/lwpt-tmp"'#10 +
    'cfg-file = "fpc.cfg"'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('lwpt-overrides', INPUT));
  Expect<string>(Man.ModulesDirOverride).ToBe('vendor/modules');
  Expect<string>(Man.ArchivesDirOverride).ToBe('vendor/archives');
  Expect<string>(Man.TmpDirOverride).ToBe('.cache/lwpt-tmp');
  Expect<string>(Man.CfgFileOverride).ToBe('fpc.cfg');
end;

procedure TLoadManifestExtensions.TestFormatExcludesParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "format-excludes"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[format]'#10 +
    'exclude = ["src/legacy/Vendored.pas", "src/legacy/Other.pas"]'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('format-excludes', INPUT));
  Expect<Integer>(Length(Man.FormatExcludes)).ToBe(2);
  Expect<string>(Man.FormatExcludes[0]).ToBe('src/legacy/Vendored.pas');
  Expect<string>(Man.FormatExcludes[1]).ToBe('src/legacy/Other.pas');
end;

procedure TLoadManifestExtensions.TestPrebuildHookEntriesParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "prebuild-test"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[prebuild]'#10 +
    'embed = { script = "scripts/stamp-version.pas", inputs = ["src/Source.pas"], output = "src/Embedded.inc" }'#10 +
    'codegen = { script = "scripts/other.pas", args = ["--flag", "v"], inputs = ["a.pas", "b.pas"], output = "src/Other.inc" }'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('prebuild', INPUT));
  Expect<Integer>(Length(Man.PreBuild)).ToBe(2);

  { Insertion order preserved via OrderedStringMap (ADR-0011). }
  Expect<string>(Man.PreBuild[0].Name).ToBe('embed');
  Expect<string>(Man.PreBuild[0].Script).ToBe('scripts/stamp-version.pas');
  Expect<Integer>(Length(Man.PreBuild[0].Inputs)).ToBe(1);
  Expect<string>(Man.PreBuild[0].Inputs[0]).ToBe('src/Source.pas');
  Expect<string>(Man.PreBuild[0].Output).ToBe('src/Embedded.inc');

  Expect<string>(Man.PreBuild[1].Name).ToBe('codegen');
  Expect<string>(Man.PreBuild[1].Script).ToBe('scripts/other.pas');
  Expect<Integer>(Length(Man.PreBuild[1].Args)).ToBe(2);
  Expect<string>(Man.PreBuild[1].Args[0]).ToBe('--flag');
  Expect<string>(Man.PreBuild[1].Args[1]).ToBe('v');
  Expect<Integer>(Length(Man.PreBuild[1].Inputs)).ToBe(2);
end;

procedure TLoadManifestExtensions.TestHookShorthandStringForm;
const
  { Bare-string shorthand: equivalent to { script = "..." } per
    ADR-0011 §"Entry shape". }
  INPUT =
    '[package]'#10 +
    'name = "hook-shorthand"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[postinstall]'#10 +
    'notify = "scripts/notify.pas"'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('hook-shorthand', INPUT));
  Expect<Integer>(Length(Man.PostInstall)).ToBe(1);
  Expect<string>(Man.PostInstall[0].Name).ToBe('notify');
  Expect<string>(Man.PostInstall[0].Script).ToBe('scripts/notify.pas');
  Expect<Integer>(Length(Man.PostInstall[0].Inputs)).ToBe(0);
  Expect<string>(Man.PostInstall[0].Output).ToBe('');
end;

procedure TLoadManifestExtensions.TestHookPairedInputsOutputRequired;
const
  { Mismatched declaration: inputs without output (or vice versa) is
    a hard error so the staleness gate stays unambiguous. ADR-0011. }
  INPUT =
    '[package]'#10 +
    'name = "hook-half-pair"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[prebuild]'#10 +
    'half = { script = "scripts/x.pas", inputs = ["a.pas"] }'#10;
begin
  ExpectManifestLoadError(
    WriteManifest('hook-half-pair', INPUT),
    'paired option',
    Self);
end;

procedure TLoadManifestExtensions.TestPerTargetHooksParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "per-item-hooks"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'cli = { source = "src/cli.pas", output = "build/cli",'#10 +
    '        prebuild  = { stamp = "scripts/stamp.pas" },'#10 +
    '        postbuild = { sign = { script = "scripts/sign.pas", args = ["{item.output}"] } } }'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('per-item-hooks', INPUT));
  Expect<Integer>(Length(Man.Targets)).ToBe(1);
  Expect<Integer>(Length(Man.Targets[0].PreBuild)).ToBe(1);
  Expect<string>(Man.Targets[0].PreBuild[0].Name).ToBe('stamp');
  Expect<string>(Man.Targets[0].PreBuild[0].Script).ToBe('scripts/stamp.pas');
  Expect<Integer>(Length(Man.Targets[0].PostBuild)).ToBe(1);
  Expect<string>(Man.Targets[0].PostBuild[0].Name).ToBe('sign');
  Expect<string>(Man.Targets[0].PostBuild[0].Script).ToBe('scripts/sign.pas');
  Expect<Integer>(Length(Man.Targets[0].PostBuild[0].Args)).ToBe(1);
  { {item.output} interpolates to the resolved output value. }
  Expect<string>(Man.Targets[0].PostBuild[0].Args[0]).ToBe('build/cli');
end;

procedure TLoadManifestExtensions.TestUnknownSectionEmitsWarning;
const
  { [generated] joins the unknown-section policy on equal footing
    with [teddybear] — silently dropped, single warning to stderr
    (ADR-0011 §"[generated] migration" Q10). We can't easily capture
    stderr in-process here, so we just assert that the manifest
    load *succeeds* (the warning is non-fatal). }
  INPUT =
    '[package]'#10 +
    'name = "unknown-sections"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[generated]'#10 +
    '"old.inc" = { generator = "scripts/old.pas", inputs = ["a.pas"] }'#10 +
    ''#10 +
    '[teddybear]'#10 +
    'fluffy = true'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('unknown-sections', INPUT));
  Expect<string>(Man.Name).ToBe('unknown-sections');
  { No fields on TManifest carry [generated] or [teddybear] —
    they're silently dropped. The warning to stderr is best-effort
    user feedback. }
end;

procedure TLoadManifestExtensions.SetupTests;
begin
  Test('[lwpt] overrides parsed into TManifest', TestLwptOverridesParsed);
  Test('[format] exclude list parsed',           TestFormatExcludesParsed);
  Test('[prebuild] hook entries parsed (ADR-0011)',
    TestPrebuildHookEntriesParsed);
  Test('hook bare-string shorthand expands to { script = "..." }',
    TestHookShorthandStringForm);
  Test('hook inputs/output is a paired option (half-pair rejected)',
    TestHookPairedInputsOutputRequired);
  Test('[build].<entry>.prebuild / postbuild parsed + {item.output} expanded',
    TestPerTargetHooksParsed);
  Test('unknown top-level section dropped silently with stderr warning',
    TestUnknownSectionEmitsWarning);
end;

{ ── TLockfileLoading ──────────────────────────────────────────── }

const
  LOCK_TMP_DIR = 'build/tests/fixtures/core/lockfiles';

function WriteLockfileContent(const ASuffix, AContent: string): string;
var SL: TStringList;
begin
  ForceDirectories(LOCK_TMP_DIR);
  Result := LOCK_TMP_DIR + '/' + ASuffix + '.lock';
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

procedure ExpectLockfileLoadError(const APath, AMessageContains: string;
  ASuite: TTestSuite);
var Raised: Boolean;
begin
  Raised := False;
  try
    LoadLockfile(APath);
  except
    on E: ELockfileError do
    begin
      Raised := True;
      if Pos(AMessageContains, E.Message) = 0 then
        ASuite.Fail(Format(
          'Expected ELockfileError to contain "%s"; got: %s',
          [AMessageContains, E.Message]));
    end;
  end;
  if not Raised then
    ASuite.Fail(Format(
      'Expected ELockfileError loading %s; nothing was raised', [APath]));
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLockfileLoading.TestMissingLockfileRaisesELockfileError;
begin
  ExpectLockfileLoadError(LOCK_TMP_DIR + '/no-such-file.lock',
    'lockfile not found', Self);
end;

procedure TLockfileLoading.TestCorruptTOMLRaisesELockfileError;
begin
  ExpectLockfileLoadError(
    WriteLockfileContent('corrupt',
      'this is { not = valid TOML at [all'#10),
    'corrupt', Self);
end;

procedure TLockfileLoading.TestMissingSchemaVersionRaisesELockfileError;
begin
  ExpectLockfileLoadError(
    WriteLockfileContent('no-schema',
      '[package.foo]'#10 +
      'version = "1.0.0"'#10),
    'no schema version', Self);
end;

procedure TLockfileLoading.TestSchemaV1RaisesWithMigrationHint;
begin
  ExpectLockfileLoadError(
    WriteLockfileContent('schema-v1',
      'version = 1'#10 +
      '[package.foo]'#10 +
      'version = "1.0.0"'#10),
    'schema v1', Self);
  ExpectLockfileLoadError(
    WriteLockfileContent('schema-v2',
      'version = 2'#10 +
      '[package.foo]'#10 +
      'version = "1.0.0"'#10 +
      'source = "owner/repo"'#10 +
      'sourceType = "github"'#10 +
      'computedHash = "sha256:abc"'#10 +
      'archiveHash = "sha256:def"'#10),
    'schema v2', Self);
end;

procedure TLockfileLoading.TestEmptyPackageTableReturnsEmptyArray;
var Entries: TResolvedArray;
begin
  Entries := LoadLockfile(
    WriteLockfileContent('empty',
      'version = 3'#10));
  Expect<Integer>(Length(Entries)).ToBe(0);
end;

procedure TLockfileLoading.TestPackageEntriesRoundTripFields;
var Entries: TResolvedArray;
begin
  Entries := LoadLockfile(
    WriteLockfileContent('three-pkgs',
      'version = 3'#10 +
      ''#10 +
      '[package.alpha]'#10 +
      'source = "owner/alpha"'#10 +
      'resolvedRef = "v1.2.3"'#10 +
      'resolvedURL = "https://github.com/owner/alpha/archive/v1.2.3.tar.gz"'#10 +
      'computedHash = "sha256:aaa"'#10 +
      'archiveHash = "sha256:bbb"'#10 +
      ''#10 +
      '[package.beta]'#10 +
      'source = "../local-beta"'#10 +
      'resolvedRef = ""'#10 +
      'resolvedURL = ""'#10 +
      'computedHash = "sha256:ccc"'#10 +
      'archiveHash = ""'#10));
  Expect<Integer>(Length(Entries)).ToBe(2);
  Expect<string>(Entries[0].Name).ToBe('alpha');
  Expect<string>(Entries[0].Version).ToBe('v1.2.3');
  Expect<string>(Entries[0].SrcOriginal).ToBe('owner/alpha');
  Expect<string>(Entries[0].SrcLocator).ToBe('owner/alpha');
  Expect<string>(Entries[0].Hash).ToBe('sha256:aaa');
  Expect<string>(Entries[0].ArchiveHash).ToBe('sha256:bbb');
  Expect<string>(Entries[1].Name).ToBe('beta');
  Expect<string>(Entries[1].SrcOriginal).ToBe('../local-beta');
  Expect<string>(Entries[1].ArchiveHash).ToBe('');
end;

procedure TLockfileLoading.SetupTests;
begin
  Test('missing lockfile raises ELockfileError naming the recovery',
    TestMissingLockfileRaisesELockfileError);
  Test('corrupt TOML raises ELockfileError naming the corruption',
    TestCorruptTOMLRaisesELockfileError);
  Test('missing schema version raises ELockfileError',
    TestMissingSchemaVersionRaisesELockfileError);
  Test('schema v1 raises with migration hint',
    TestSchemaV1RaisesWithMigrationHint);
  Test('empty [package] table returns empty array (legal: 0 deps)',
    TestEmptyPackageTableReturnsEmptyArray);
  Test('package entries round-trip every field',
    TestPackageEntriesRoundTripFields);
end;

{ ── TVerifyAgainstLockfile ────────────────────────────────────── }

function MakeResolved(const AName, AVersion, ATreeHash, AArchiveHash: string;
  const ASrcKind: TSourceKind = skLocal): TResolved;
begin
  Result := Default(TResolved);
  Result.Name        := AName;
  Result.Version     := AVersion;
  Result.SrcKind     := ASrcKind;
  Result.Hash        := ATreeHash;
  Result.ArchiveHash := AArchiveHash;
  if ASrcKind = skGitHost then
    Result.SrcOriginal := AName + '/repo'
  else if ASrcKind = skURL then
    Result.SrcOriginal := 'https://example.com/' + AName + '.tar.gz'
  else
    Result.SrcOriginal := '../' + AName;
end;

procedure ExpectVerifyError(const AGraph, ALock: TResolvedArray;
  const AMessageContains: string; ASuite: TTestSuite);
var Raised: Boolean;
begin
  Raised := False;
  try
    VerifyAgainstLockfile(AGraph, ALock);
  except
    on E: EVerifyError do
    begin
      Raised := True;
      if Pos(AMessageContains, E.Message) = 0 then
        ASuite.Fail(Format(
          'Expected EVerifyError to contain "%s"; got: %s',
          [AMessageContains, E.Message]));
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TVerifyAgainstLockfile.TestMatchingEntriesPass;
var Graph, Lock: TResolvedArray;
begin
  SetLength(Graph, 1);
  SetLength(Lock,  1);
  Graph[0] := MakeResolved('alpha', '1.0.0', 'sha256:abc', 'sha256:def', skGitHost);
  Lock[0]  := MakeResolved('alpha', '1.0.0', 'sha256:abc', 'sha256:def', skGitHost);
  { No raise expected; this is the happy-path assertion. }
  VerifyAgainstLockfile(Graph, Lock);
  Expect<Boolean>(True).ToBe(True);
end;

procedure TVerifyAgainstLockfile.TestTreeHashMismatchRaises;
var Graph, Lock: TResolvedArray;
begin
  SetLength(Graph, 1);
  SetLength(Lock,  1);
  Graph[0] := MakeResolved('alpha', '1.0.0', 'sha256:NEW', 'sha256:def', skGitHost);
  Lock[0]  := MakeResolved('alpha', '1.0.0', 'sha256:OLD', 'sha256:def', skGitHost);
  ExpectVerifyError(Graph, Lock, 'tree hash mismatch', Self);
end;

procedure TVerifyAgainstLockfile.TestArchiveHashMismatchRaises;
var Graph, Lock: TResolvedArray;
begin
  SetLength(Graph, 1);
  SetLength(Lock,  1);
  Graph[0] := MakeResolved('beta', '2.0.0', 'sha256:abc', 'sha256:NEW', skGitHost);
  Lock[0]  := MakeResolved('beta', '2.0.0', 'sha256:abc', 'sha256:OLD', skGitHost);
  ExpectVerifyError(Graph, Lock, 'archive hash mismatch', Self);
end;

procedure TVerifyAgainstLockfile.TestManifestDepWithoutLockEntryRaises;
var Graph, Lock: TResolvedArray;
begin
  SetLength(Graph, 1);
  SetLength(Lock,  0);
  Graph[0] := MakeResolved('orphan', '1.0.0', 'sha256:abc', '', skLocal);
  ExpectVerifyError(Graph, Lock,
    'manifest declares "orphan" but lockfile has no entry', Self);
end;

procedure TVerifyAgainstLockfile.TestLockEntryWithoutGraphNodeRaises;
var Graph, Lock: TResolvedArray;
begin
  SetLength(Graph, 0);
  SetLength(Lock,  1);
  Lock[0] := MakeResolved('stale', '1.0.0', 'sha256:abc', '', skLocal);
  ExpectVerifyError(Graph, Lock,
    'lockfile has "stale" but no manifest dep', Self);
end;

procedure TVerifyAgainstLockfile.TestLocalSourceWithEmptyArchiveHashPasses;
var Graph, Lock: TResolvedArray;
begin
  { Both sides have ArchiveHash = '' (legitimate for skLocal). The
    verifier must skip the archive check, not flag a mismatch. }
  SetLength(Graph, 1);
  SetLength(Lock,  1);
  Graph[0] := MakeResolved('local', '*', 'sha256:abc', '', skLocal);
  Lock[0]  := MakeResolved('local', '*', 'sha256:abc', '', skLocal);
  VerifyAgainstLockfile(Graph, Lock);
  Expect<Boolean>(True).ToBe(True);
end;

procedure TVerifyAgainstLockfile.SetupTests;
begin
  Test('matching graph + lock entries: passes silently',
    TestMatchingEntriesPass);
  Test('tree hash mismatch raises EVerifyError naming the dep',
    TestTreeHashMismatchRaises);
  Test('archive hash mismatch raises EVerifyError naming the dep',
    TestArchiveHashMismatchRaises);
  Test('manifest dep without lockfile entry raises EVerifyError',
    TestManifestDepWithoutLockEntryRaises);
  Test('lockfile entry not reached by the graph raises EVerifyError',
    TestLockEntryWithoutGraphNodeRaises);
  Test('skLocal with empty ArchiveHash on both sides: no false mismatch',
    TestLocalSourceWithEmptyArchiveHashPasses);
end;

{ ── TParseDependencySource ────────────────────────────────────── }

procedure ExpectSource(const AInput: string;
  AExpectedKind: TSourceKind; AExpectedHost: THostKind;
  const AExpectedLocator: string; ASuite: TTestSuite);
var K: TSourceKind; H: THostKind; L: string;
begin
  ParseDependencySource(AInput, K, H, L);
  if K <> AExpectedKind then
    ASuite.Fail(Format('Source "%s": kind mismatch (got %d, want %d)',
      [AInput, Ord(K), Ord(AExpectedKind)]));
  if (K = skGitHost) and (H <> AExpectedHost) then
    ASuite.Fail(Format('Source "%s": host mismatch (got %d, want %d)',
      [AInput, Ord(H), Ord(AExpectedHost)]));
  if L <> AExpectedLocator then
    ASuite.Fail(Format('Source "%s": locator mismatch (got "%s", want "%s")',
      [AInput, L, AExpectedLocator]));
  Expect<Boolean>(True).ToBe(True);
end;

procedure ExpectSourceRejected(const AInput, AMessagePart: string;
  ASuite: TTestSuite);
var K: TSourceKind; H: THostKind; L: string; Raised: Boolean;
begin
  Raised := False;
  try
    ParseDependencySource(AInput, K, H, L);
  except
    on E: EManifestError do
    begin
      Raised := True;
      if Pos(AMessagePart, E.Message) = 0 then
        ASuite.Fail(Format(
          'Source "%s": expected EManifestError containing "%s"; got: %s',
          [AInput, AMessagePart, E.Message]));
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TParseDependencySource.TestBareOwnerRepoDefaultsToGitHub;
begin
  ExpectSource('octocat/Hello-World', skGitHost, hkGitHub,
    'octocat/Hello-World', Self);
end;

procedure TParseDependencySource.TestGitLabPrefix;
begin
  ExpectSource('gitlab:gitlab-org/release-cli', skGitHost, hkGitLab,
    'gitlab-org/release-cli', Self);
end;

procedure TParseDependencySource.TestBitbucketPrefix;
begin
  ExpectSource('bitbucket:atlassian/atlaskit', skGitHost, hkBitbucket,
    'atlassian/atlaskit', Self);
end;

procedure TParseDependencySource.TestGithubPrefixExplicit;
begin
  ExpectSource('github:owner/repo', skGitHost, hkGitHub,
    'owner/repo', Self);
end;

procedure TParseDependencySource.TestUnknownPrefixRejected;
begin
  ExpectSourceRejected('svn:owner/repo', 'unknown source prefix', Self);
end;

procedure TParseDependencySource.TestHttpsURLIsURLKind;
begin
  ExpectSource('https://example.com/foo.tar.gz', skURL, hkGitHub,
    'https://example.com/foo.tar.gz', Self);
end;

procedure TParseDependencySource.TestHttpURLRejected;
begin
  ExpectSourceRejected('http://internal/foo.tar.gz', 'plain HTTP', Self);
end;

procedure TParseDependencySource.TestLocalDotSlashPath;
begin
  ExpectSource('./relative', skLocal, hkGitHub, './relative', Self);
end;

procedure TParseDependencySource.TestLocalParentSlashPath;
begin
  ExpectSource('../sibling', skLocal, hkGitHub, '../sibling', Self);
end;

procedure TParseDependencySource.TestLocalAbsolutePath;
begin
  ExpectSource('/abs/path', skLocal, hkGitHub, '/abs/path', Self);
end;

procedure TParseDependencySource.TestLocalWindowsAbsolutePath;
begin
  ExpectSource('C:/work/dep', skLocal, hkGitHub, 'C:/work/dep', Self);
  ExpectSource('C:\work\dep', skLocal, hkGitHub, 'C:\work\dep', Self);
end;

procedure TParseDependencySource.TestLocalTildeSlashPath;
begin
  ExpectSource('~/lib/foo', skLocal, hkGitHub, '~/lib/foo', Self);
end;

procedure TParseDependencySource.TestLocalExplicitPrefix;
begin
  ExpectSource('local:./relative', skLocal, hkGitHub, './relative', Self);
end;

procedure TParseDependencySource.TestEmptyStringRejected;
begin
  ExpectSourceRejected('', 'empty', Self);
end;

procedure TParseDependencySource.TestNoSlashRejected;
begin
  ExpectSourceRejected('justaword',
    'cannot parse dependency source', Self);
end;

procedure TParseDependencySource.SetupTests;
begin
  Test('bare "owner/repo" defaults to GitHub',
    TestBareOwnerRepoDefaultsToGitHub);
  Test('"gitlab:owner/repo" prefix routes to hkGitLab', TestGitLabPrefix);
  Test('"bitbucket:owner/repo" prefix routes to hkBitbucket',
    TestBitbucketPrefix);
  Test('"github:owner/repo" explicit prefix accepted',
    TestGithubPrefixExplicit);
  Test('unknown "svn:" prefix rejected with clear error',
    TestUnknownPrefixRejected);
  Test('"https://..." is skURL with the URL as locator',
    TestHttpsURLIsURLKind);
  Test('"http://..." is rejected; dependency URLs must use HTTPS',
    TestHttpURLRejected);
  Test('"./path" implicit local', TestLocalDotSlashPath);
  Test('"../path" implicit local', TestLocalParentSlashPath);
  Test('"/abs/path" absolute implicit local', TestLocalAbsolutePath);
  Test('"C:/path" Windows absolute implicit local',
    TestLocalWindowsAbsolutePath);
  Test('"~/path" HOME-relative implicit local', TestLocalTildeSlashPath);
  Test('"local:./path" explicit prefix', TestLocalExplicitPrefix);
  Test('empty string rejected', TestEmptyStringRejected);
  Test('bare non-slash word rejected (not owner/repo, not a path)',
    TestNoSlashRejected);
end;

{ ── TParseVersionSpec ──────────────────────────────────────────── }

procedure ExpectVersionKind(const AInput: string;
  AExpectedKind: TVersionKind; ASuite: TTestSuite);
var K: TVersionKind; V: string;
begin
  ParseVersionSpec(AInput, K, V);
  if K <> AExpectedKind then
    ASuite.Fail(Format('Spec "%s": kind mismatch (got %d, want %d)',
      [AInput, Ord(K), Ord(AExpectedKind)]));
  Expect<Boolean>(True).ToBe(True);
end;

procedure TParseVersionSpec.TestEmptySpecIsNone;
begin
  ExpectVersionKind('', vkNone, Self);
end;

procedure TParseVersionSpec.TestSemverRangeCaret;
begin
  ExpectVersionKind('^1.0.0', vkSemverRange, Self);
end;

procedure TParseVersionSpec.TestSemverRangeTilde;
begin
  ExpectVersionKind('~1.2', vkSemverRange, Self);
end;

procedure TParseVersionSpec.TestSemverRangeGtLt;
begin
  { node-semver canonical form uses space, not comma. }
  ExpectVersionKind('>=1.0.0 <2.0.0', vkSemverRange, Self);
end;

procedure TParseVersionSpec.TestSemverExactSimple;
begin
  ExpectVersionKind('1.0.0', vkSemverExact, Self);
end;

procedure TParseVersionSpec.TestSemverExactPrerelease;
begin
  ExpectVersionKind('2.3.4-beta.1', vkSemverExact, Self);
end;

procedure TParseVersionSpec.TestVPrefixedIsLiteralTagNotSemver;
begin
  { Load-bearing per ADR-0009 / SemVer 2.0.0: "v1.0.0" is NOT a
    SemVer; it's a Git tag string. Goes through the literal-tag
    path, not the SemVer-exact path. }
  ExpectVersionKind('v1.0.0', vkLiteralTag, Self);
  ExpectVersionKind('v0.16.0', vkLiteralTag, Self);
end;

procedure TParseVersionSpec.TestCommitShaShort;
begin
  ExpectVersionKind('7fd1a60', vkCommitSha, Self);
end;

procedure TParseVersionSpec.TestCommitShaFull;
begin
  ExpectVersionKind('7fd1a60b01f91b314f59955a4e4d4e80d8edf11d',
    vkCommitSha, Self);
end;

procedure TParseVersionSpec.TestLiteralBranchName;
begin
  ExpectVersionKind('main', vkLiteralTag, Self);
  ExpectVersionKind('develop', vkLiteralTag, Self);
end;

procedure TParseVersionSpec.TestLiteralReleaseTag;
begin
  ExpectVersionKind('release-2024-01', vkLiteralTag, Self);
end;

procedure TParseVersionSpec.SetupTests;
begin
  Test('empty spec is vkNone',                     TestEmptySpecIsNone);
  Test('"^1.0.0" parses as vkSemverRange',         TestSemverRangeCaret);
  Test('"~1.2" parses as vkSemverRange',           TestSemverRangeTilde);
  Test('">=1.0.0,<2.0.0" parses as vkSemverRange', TestSemverRangeGtLt);
  Test('"1.0.0" parses as vkSemverExact',          TestSemverExactSimple);
  Test('"2.3.4-beta.1" parses as vkSemverExact',   TestSemverExactPrerelease);
  Test('"v1.0.0" parses as vkLiteralTag (NOT vkSemverExact)',
    TestVPrefixedIsLiteralTagNotSemver);
  Test('short SHA (7 hex chars) parses as vkCommitSha',
    TestCommitShaShort);
  Test('full SHA (40 hex chars) parses as vkCommitSha',
    TestCommitShaFull);
  Test('branch names parse as vkLiteralTag',       TestLiteralBranchName);
  Test('arbitrary release-style tags parse as vkLiteralTag',
    TestLiteralReleaseTag);
end;

{ ── TGitProtocolParsing ────────────────────────────────────────── }

procedure TGitProtocolParsing.TestEmptyPayloadReturnsEmpty;
begin
  Expect<Integer>(Length(ParseInfoRefs(''))).ToBe(0);
end;

procedure TGitProtocolParsing.TestServiceAnnounceIsSkipped;
const
  PAYLOAD =
    '001e# service=git-upload-pack'#10 +
    '0000';
begin
  { Service-announce line + flush packet; no refs. Should yield
    an empty array, not error out. }
  Expect<Integer>(Length(ParseInfoRefs(PAYLOAD))).ToBe(0);
end;

procedure TGitProtocolParsing.TestHeadWithCapabilitiesIsRecognised;
const
  { 4-char hex length + payload. 40-char SHA + space + "HEAD"
    + NUL + capability string + LF. Total payload = 56 chars,
    +4 prefix = 60 = $003c. HEAD is dropped by the filter, so
    the result is still empty. }
  PAYLOAD =
    '003c0123456789012345678901234567890123456789 HEAD'#0 +
    'multi_ack thin-pack'#10 +
    '0000';
begin
  Expect<Integer>(Length(ParseInfoRefs(PAYLOAD))).ToBe(0);
end;

procedure TGitProtocolParsing.TestTagsAndBranchesAreSeparated;
const
  PAYLOAD =
    { 0x3d = 61: 4 prefix + 40 sha + 1 space + "refs/heads/main" (15) + 1 LF }
    '003daaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main'#10 +
    { 0x3e = 62: 4 prefix + 40 sha + 1 space + "refs/tags/v1.0.0" (16) + 1 LF }
    '003ebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/v1.0.0'#10 +
    '0000';
var Refs: TGitRefArray;
begin
  Refs := ParseInfoRefs(PAYLOAD);
  Expect<Integer>(Length(Refs)).ToBe(2);
  Expect<Integer>(Ord(Refs[0].Kind)).ToBe(Ord(rkBranch));
  Expect<string>(Refs[0].Name).ToBe('main');
  Expect<Integer>(Ord(Refs[1].Kind)).ToBe(Ord(rkTag));
  Expect<string>(Refs[1].Name).ToBe('v1.0.0');
end;

procedure TGitProtocolParsing.TestPeelSuffixIsDiscarded;
const
  (* Both lines refer to the same tag; the ^{} line is the peeled
     commit SHA. Our parser drops the peel-suffix line so the result
     contains the tag exactly once. *)
  PAYLOAD =
    '003ebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/v1.0.0'#10 +
    (* 0x41 = 65: 4 prefix + 40 sha + 1 space + 19-char peel-suffix
       ref name + 1 LF *)
    '0041cccccccccccccccccccccccccccccccccccccccc refs/tags/v1.0.0^{}'#10 +
    '0000';
var Refs: TGitRefArray;
begin
  Refs := ParseInfoRefs(PAYLOAD);
  Expect<Integer>(Length(Refs)).ToBe(1);
  Expect<string>(Refs[0].Name).ToBe('v1.0.0');
end;

procedure TGitProtocolParsing.TestMultipleTags;
const
  PAYLOAD =
    '003eaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/tags/v1.0.0'#10 +
    '003ebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/v1.1.0'#10 +
    '003ecccccccccccccccccccccccccccccccccccccccc refs/tags/v2.0.0'#10 +
    '0000';
var Refs: TGitRefArray;
begin
  Refs := ParseInfoRefs(PAYLOAD);
  Expect<Integer>(Length(Refs)).ToBe(3);
  Expect<string>(Refs[0].Name).ToBe('v1.0.0');
  Expect<string>(Refs[2].Name).ToBe('v2.0.0');
end;

procedure TGitProtocolParsing.SetupTests;
begin
  Test('empty payload returns empty array',
    TestEmptyPayloadReturnsEmpty);
  Test('service-announce line is skipped (not a ref)',
    TestServiceAnnounceIsSkipped);
  Test('HEAD entry with capabilities is recognised + dropped',
    TestHeadWithCapabilitiesIsRecognised);
  Test('refs/heads/ and refs/tags/ are classified correctly',
    TestTagsAndBranchesAreSeparated);
  Test('peel-suffix lines are discarded (the unsuffixed line wins)',
    TestPeelSuffixIsDiscarded);
  Test('multiple tags are returned in order',
    TestMultipleTags);
end;

{ ── TApplyIncludeExclude ───────────────────────────────────────── }

procedure TApplyIncludeExclude.ResetScratch;

  procedure WipeRec(const ADir: string);
  var SR: TSearchRec; Base: string;
  begin
    if not DirectoryExists(ADir) then Exit;
    Base := IncludeTrailingPathDelimiter(ADir);
    if FindFirst(Base + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if (SR.Attr and faDirectory) <> 0 then WipeRec(Base + SR.Name)
          else DeleteFile(Base + SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    RemoveDir(ADir);
  end;

begin
  WipeRec(FScratch);
  ForceDirectories(FScratch);
end;

procedure TApplyIncludeExclude.PlantTree;

  procedure W(const ARel: string);
  var SL: TStringList;
  begin
    ForceDirectories(ExtractFileDir(FScratch + '/' + ARel));
    SL := TStringList.Create;
    try
      SL.Text := 'placeholder content for ' + ARel;
      SL.SaveToFile(FScratch + '/' + ARel);
    finally
      SL.Free;
    end;
  end;

begin
  { Synthesised tree:
      src/main.pas
      src/middleware/horse.pas
      src/middleware/jhonson.pas
      src/utils/foo.pas
      tests/a.pas
      tests/b.pas
      docs/readme.md }
  W('src/main.pas');
  W('src/middleware/horse.pas');
  W('src/middleware/jhonson.pas');
  W('src/utils/foo.pas');
  W('tests/a.pas');
  W('tests/b.pas');
  W('docs/readme.md');
end;

function TApplyIncludeExclude.Exists(const ARel: string): Boolean;
begin
  Result := FileExists(FScratch + '/' + ARel);
end;

procedure TApplyIncludeExclude.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/apply-include-exclude');
end;

procedure TApplyIncludeExclude.TestNeitherSetKeepsEverything;
var Empty: TStringArray;
begin
  ResetScratch; PlantTree;
  SetLength(Empty, 0);
  ApplyIncludeExclude(FScratch, Empty, Empty);
  Expect<Boolean>(Exists('src/main.pas')).ToBe(True);
  Expect<Boolean>(Exists('docs/readme.md')).ToBe(True);
end;

procedure TApplyIncludeExclude.TestIncludeOnlyKeepsMatches;
var Include, ExcludeEmpty: TStringArray;
begin
  ResetScratch; PlantTree;
  SetLength(Include, 1); Include[0] := 'src/middleware/**';
  SetLength(ExcludeEmpty, 0);
  ApplyIncludeExclude(FScratch, Include, ExcludeEmpty);
  Expect<Boolean>(Exists('src/middleware/horse.pas')).ToBe(True);
  Expect<Boolean>(Exists('src/middleware/jhonson.pas')).ToBe(True);
  Expect<Boolean>(Exists('src/main.pas')).ToBe(False);
  Expect<Boolean>(Exists('src/utils/foo.pas')).ToBe(False);
  Expect<Boolean>(Exists('tests/a.pas')).ToBe(False);
  Expect<Boolean>(Exists('docs/readme.md')).ToBe(False);
end;

procedure TApplyIncludeExclude.TestExcludeOnlyDropsMatches;
var IncludeEmpty, Exclude: TStringArray;
begin
  ResetScratch; PlantTree;
  SetLength(IncludeEmpty, 0);
  SetLength(Exclude, 2);
  Exclude[0] := 'tests/**';
  Exclude[1] := 'docs/**';
  ApplyIncludeExclude(FScratch, IncludeEmpty, Exclude);
  Expect<Boolean>(Exists('src/main.pas')).ToBe(True);
  Expect<Boolean>(Exists('src/middleware/horse.pas')).ToBe(True);
  Expect<Boolean>(Exists('tests/a.pas')).ToBe(False);
  Expect<Boolean>(Exists('docs/readme.md')).ToBe(False);
end;

procedure TApplyIncludeExclude.TestBothCombines;
var Include, Exclude: TStringArray;
begin
  ResetScratch; PlantTree;
  { Include only src/**, then drop src/utils/**. Result: src/main +
    src/middleware/*, nothing else. }
  SetLength(Include, 1); Include[0] := 'src/**';
  SetLength(Exclude, 1); Exclude[0] := 'src/utils/**';
  ApplyIncludeExclude(FScratch, Include, Exclude);
  Expect<Boolean>(Exists('src/main.pas')).ToBe(True);
  Expect<Boolean>(Exists('src/middleware/horse.pas')).ToBe(True);
  Expect<Boolean>(Exists('src/utils/foo.pas')).ToBe(False);
  Expect<Boolean>(Exists('tests/a.pas')).ToBe(False);
end;

procedure TApplyIncludeExclude.TestEmptyDirectoriesReaped;
var Include, ExcludeEmpty: TStringArray;
begin
  ResetScratch; PlantTree;
  SetLength(Include, 1); Include[0] := 'src/main.pas';
  SetLength(ExcludeEmpty, 0);
  ApplyIncludeExclude(FScratch, Include, ExcludeEmpty);
  Expect<Boolean>(Exists('src/main.pas')).ToBe(True);
  { Sibling dirs that became empty after pruning should be gone. }
  Expect<Boolean>(DirectoryExists(FScratch + '/tests')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/docs')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/src/middleware')).ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/src/utils')).ToBe(False);
end;

procedure TApplyIncludeExclude.TestExcludeOverridesInclude;
var Include, Exclude: TStringArray;
begin
  ResetScratch; PlantTree;
  SetLength(Include, 1); Include[0] := '**/*.pas';
  SetLength(Exclude, 1); Exclude[0] := '**/jhonson.pas';
  ApplyIncludeExclude(FScratch, Include, Exclude);
  Expect<Boolean>(Exists('src/middleware/horse.pas')).ToBe(True);
  Expect<Boolean>(Exists('src/middleware/jhonson.pas')).ToBe(False);
end;

procedure TApplyIncludeExclude.SetupTests;
begin
  Test('neither include nor exclude set: keep everything',
    TestNeitherSetKeepsEverything);
  Test('include only: keep files matching any include glob',
    TestIncludeOnlyKeepsMatches);
  Test('exclude only: drop files matching any exclude glob',
    TestExcludeOnlyDropsMatches);
  Test('include + exclude: include is additive, exclude subtracts',
    TestBothCombines);
  Test('empty directories are reaped after file pruning',
    TestEmptyDirectoriesReaped);
  Test('exclude overrides include for matching files',
    TestExcludeOverridesInclude);
end;

{ ── TCopyDirTreeGuards ─────────────────────────────────────────── }

function TCopyDirTreeGuards.Src: string;
begin
  Result := FScratch + '/src';
end;

function TCopyDirTreeGuards.Dst: string;
begin
  Result := FScratch + '/dst';
end;

procedure TCopyDirTreeGuards.ResetScratch;

  procedure W(const ARel: string);
  var SL: TStringList;
  begin
    ForceDirectories(ExtractFileDir(Src + '/' + ARel));
    SL := TStringList.Create;
    try
      SL.Text := 'content of ' + ARel;
      SL.SaveToFile(Src + '/' + ARel);
    finally
      SL.Free;
    end;
  end;

begin
  { WipeDir (not a naive recursive delete) — fixtures plant symlinks,
    and the wipe must remove the link, not follow it. }
  WipeDir(FScratch);
  ForceDirectories(FScratch);
  W('a.txt');
  W('sub/b.txt');
end;

procedure TCopyDirTreeGuards.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/copy-dir-tree-guards');
end;

procedure TCopyDirTreeGuards.TestCopiesNestedTree;
begin
  ResetScratch;
  CopyDirTree(Src, Dst);
  Expect<Boolean>(FileExists(Dst + '/a.txt')).ToBe(True);
  Expect<Boolean>(FileExists(Dst + '/sub/b.txt')).ToBe(True);
end;

procedure TCopyDirTreeGuards.TestDirSymlinkCycleTerminatesAndIsNotCopied;
begin
  {$IFDEF UNIX}
  ResetScratch;
  { loop -> . resolves to its own parent: the minimal directory cycle. }
  if FpSymlink('.', PAnsiChar(Src + '/loop')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for cycle link');
  { The regression assertion: this returns at all. }
  CopyDirTree(Src, Dst);
  Expect<Boolean>(FileExists(Dst + '/a.txt')).ToBe(True);
  Expect<Boolean>(FileExists(Dst + '/sub/b.txt')).ToBe(True);
  Expect<Boolean>(DirectoryExists(Dst + '/loop')).ToBe(False);
  {$ELSE}
  { The symlink fixture needs FpSymlink; the guard itself is portable. }
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TCopyDirTreeGuards.TestFileSymlinkCopiedThrough;
var SL: TStringList;
begin
  {$IFDEF UNIX}
  ResetScratch;
  if FpSymlink('a.txt', PAnsiChar(Src + '/link.txt')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for file link');
  CopyDirTree(Src, Dst);
  Expect<Boolean>(FileExists(Dst + '/link.txt')).ToBe(True);
  SL := TStringList.Create;
  try
    SL.LoadFromFile(Dst + '/link.txt');
    Expect<Boolean>(Pos('content of a.txt', SL.Text) > 0).ToBe(True);
  finally
    SL.Free;
  end;
  {$ELSE}
  SL := nil;
  if SL = nil then Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TCopyDirTreeGuards.TestDstInsideSrcRaises;
var Raised: Boolean;
begin
  ResetScratch;
  Raised := False;
  try
    CopyDirTree(Src, Src + '/sub/dst');
  except
    on E: EExtractError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  { Nothing was written before the guard fired. }
  Expect<Boolean>(DirectoryExists(Src + '/sub/dst')).ToBe(False);
end;

procedure TCopyDirTreeGuards.TestDstEqualsSrcRaises;
var Raised: Boolean;
begin
  ResetScratch;
  Raised := False;
  try
    CopyDirTree(Src, Src);
  except
    on E: EExtractError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TCopyDirTreeGuards.SetupTests;
begin
  Test('copies a nested tree (baseline)', TestCopiesNestedTree);
  Test('terminates on a directory-symlink cycle; link not copied',
    TestDirSymlinkCycleTerminatesAndIsNotCopied);
  Test('file symlink is copied through (target bytes)',
    TestFileSymlinkCopiedThrough);
  Test('destination inside source raises EExtractError',
    TestDstInsideSrcRaises);
  Test('destination equal to source raises EExtractError',
    TestDstEqualsSrcRaises);
end;

{ ── TWipeDirSymlinks ───────────────────────────────────────────── }

procedure TWipeDirSymlinks.ResetScratch;
begin
  WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TWipeDirSymlinks.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/wipe-dir-symlinks');
end;

procedure TWipeDirSymlinks.TestDanglingLinkIsRemoved;
begin
  {$IFDEF UNIX}
  ResetScratch;
  ForceDirectories(FScratch + '/victim');
  if FpSymlink('no-such-target',
       PAnsiChar(FScratch + '/victim/dangling')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for dangling link');
  WipeDir(FScratch + '/victim');
  Expect<Boolean>(DirectoryExists(FScratch + '/victim')).ToBe(False);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TWipeDirSymlinks.TestLinkTargetOutsideTreeSurvives;
var SL: TStringList;
begin
  {$IFDEF UNIX}
  ResetScratch;
  ForceDirectories(FScratch + '/outside');
  ForceDirectories(FScratch + '/victim');
  SL := TStringList.Create;
  try
    SL.Text := 'must survive the wipe';
    SL.SaveToFile(FScratch + '/outside/keep.txt');
  finally
    SL.Free;
  end;
  if FpSymlink('../outside',
       PAnsiChar(FScratch + '/victim/link')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for outside link');
  WipeDir(FScratch + '/victim');
  Expect<Boolean>(DirectoryExists(FScratch + '/victim')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/outside/keep.txt')).ToBe(True);
  {$ELSE}
  SL := nil;
  if SL = nil then Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TWipeDirSymlinks.SetupTests;
begin
  Test('dangling symlink entry is removed (wipe completes)',
    TestDanglingLinkIsRemoved);
  Test('link to a directory outside the tree: link dies, target survives',
    TestLinkTargetOutsideTreeSurvives);
end;

{ ── TPathGlobMatching ──────────────────────────────────────────── }

procedure ExpectMatch(const APath, APattern: string;
  AExpected: Boolean; ASuite: TTestSuite);
var Got: Boolean;
begin
  Got := MatchPathGlob(APath, APattern);
  if Got <> AExpected then
    ASuite.Fail(Format(
      'MatchPathGlob("%s", "%s") = %s; expected %s',
      [APath, APattern, BoolToStr(Got, True), BoolToStr(AExpected, True)]));
  Expect<Boolean>(True).ToBe(True);
end;

procedure TPathGlobMatching.TestExactPathMatch;
begin
  ExpectMatch('src/foo.pas', 'src/foo.pas', True, Self);
  ExpectMatch('src/foo.pas', 'src/bar.pas', False, Self);
end;

procedure TPathGlobMatching.TestSingleStarMatchesOneSegment;
begin
  ExpectMatch('src/foo.pas',     'src/*.pas',      True, Self);
  ExpectMatch('src/bar.pas',     'src/*.pas',      True, Self);
end;

procedure TPathGlobMatching.TestSingleStarRejectsSlash;
begin
  { `*` should NOT cross segment boundaries. }
  ExpectMatch('src/a/b.pas',     'src/*.pas',      False, Self);
end;

procedure TPathGlobMatching.TestDoubleStarMatchesAnyDepth;
begin
  ExpectMatch('src/a.pas',       'src/**',         True, Self);
  ExpectMatch('src/a/b.pas',     'src/**',         True, Self);
  ExpectMatch('src/a/b/c.pas',   'src/**',         True, Self);
  ExpectMatch('lib/a.pas',       'src/**',         False, Self);
end;

procedure TPathGlobMatching.TestDoubleStarMatchesZeroSegments;
begin
  { `**/foo.pas` matches `foo.pas` (zero intermediate segments) AND
    `a/foo.pas` AND `a/b/foo.pas`. }
  ExpectMatch('foo.pas',         '**/foo.pas',     True, Self);
  ExpectMatch('a/foo.pas',       '**/foo.pas',     True, Self);
  ExpectMatch('a/b/foo.pas',     '**/foo.pas',     True, Self);
end;

procedure TPathGlobMatching.TestQuestionMatchesOneChar;
begin
  ExpectMatch('src/foo.pas',     'src/fo?.pas',    True, Self);
  ExpectMatch('src/fooo.pas',    'src/fo?.pas',    False, Self);
end;

procedure TPathGlobMatching.TestExtensionGlob;
begin
  ExpectMatch('src/a/b/c.pas',   'src/**/*.pas',   True, Self);
  ExpectMatch('src/a/b/c.inc',   'src/**/*.pas',   False, Self);
end;

procedure TPathGlobMatching.TestTrailingDoubleStar;
begin
  ExpectMatch('tests',           'tests/**',       True, Self);
  ExpectMatch('tests/a/b.pas',   'tests/**',       True, Self);
end;

procedure TPathGlobMatching.TestLeadingDoubleStar;
begin
  ExpectMatch('any/depth/foo.pas','**/foo.pas',    True, Self);
  ExpectMatch('foo.pas',          '**/foo.pas',    True, Self);
end;

procedure TPathGlobMatching.TestNoMatchOnDifferentFile;
begin
  ExpectMatch('src/foo.pas',     'tests/**',       False, Self);
  ExpectMatch('docs/readme.md',  '**/*.pas',       False, Self);
end;

procedure TPathGlobMatching.SetupTests;
begin
  Test('exact path matches itself, mismatches others', TestExactPathMatch);
  Test('"*" matches a single segment',                 TestSingleStarMatchesOneSegment);
  Test('"*" does NOT cross "/" boundaries',            TestSingleStarRejectsSlash);
  Test('"**" matches paths at any depth',              TestDoubleStarMatchesAnyDepth);
  Test('"**" matches zero intermediate segments',      TestDoubleStarMatchesZeroSegments);
  Test('"?" matches exactly one character',            TestQuestionMatchesOneChar);
  Test('"src/**/*.pas" matches by extension at depth', TestExtensionGlob);
  Test('"tests/**" matches the dir and all descendants', TestTrailingDoubleStar);
  Test('"**/foo.pas" matches at any depth INCLUDING the root', TestLeadingDoubleStar);
  Test('no false positives on unrelated paths',        TestNoMatchOnDifferentFile);
end;

{ ── TCustomSources ──────────────────────────────────────────── }

function WriteCustomSourceManifest(const ASuffix, ABody: string): string;
var SL: TStringList;
begin
  ForceDirectories(TMP_DIR);
  Result := TMP_DIR + '/' + ASuffix + '.toml';
  SL := TStringList.Create;
  try
    SL.Text := ABody;
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

procedure TCustomSources.TestEmptyManifestHasNoCustomSources;
var Man: TManifest;
begin
  Man := LoadManifest(WriteCustomSourceManifest('empty-sources',
    '[package]'#10'name = "x"'#10'version = "0"'#10));
  Expect<Integer>(Length(Man.CustomSources)).ToBe(0);
end;

{ Inline-table form (ADR-0009): every entry under [sources] is an
  inline table assigned to the prefix name. }
function GiteaSourceLine(const ASectionName: string): string;
begin
  Result :=
    ASectionName + ' = { '
    + 'archive = "https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz", '
    + 'git = "https://git.example.com/{user}/{repository}.git"'
    + ' }'#10;
end;

procedure TCustomSources.TestSingleCustomSourceParsed;
var Man: TManifest;
begin
  Man := LoadManifest(WriteCustomSourceManifest('one-source',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    GiteaSourceLine('gitea')));
  Expect<Integer>(Length(Man.CustomSources)).ToBe(1);
  Expect<string>(Man.CustomSources[0].Name).ToBe('gitea');
  Expect<string>(Man.CustomSources[0].ArchiveTemplate).ToBe(
    'https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz');
  Expect<string>(Man.CustomSources[0].GitTemplate).ToBe(
    'https://git.example.com/{user}/{repository}.git');
end;

procedure TCustomSources.TestMissingArchiveTemplateRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('no-archive',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { git = "https://git.example.com/{user}/{repository}.git" }'#10),
    '"archive" and "git" URL templates', Self);
end;

procedure TCustomSources.TestMissingGitTemplateRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('no-git',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { archive = "https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz" }'#10),
    '"archive" and "git" URL templates', Self);
end;

procedure TCustomSources.TestArchiveTemplateMissingRefPlaceholderRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('no-ref',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "https://git.example.com/{user}/{repository}/HEAD.tar.gz", '
    + 'git = "https://git.example.com/{user}/{repository}.git"'
    + ' }'#10),
    'must contain all of {user}, {repository}, and {ref}', Self);
end;

procedure TCustomSources.TestArchiveTemplateMissingUserPlaceholderRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('no-user',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "https://git.example.com/{repository}/{ref}.tar.gz", '
    + 'git = "https://git.example.com/{user}/{repository}.git"'
    + ' }'#10),
    'must contain all of {user}, {repository}, and {ref}', Self);
end;

procedure TCustomSources.TestGitTemplateMissingRepositoryPlaceholderRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('no-repo-git',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz", '
    + 'git = "https://git.example.com/{user}.git"'
    + ' }'#10),
    'must contain both {user} and {repository}', Self);
end;

procedure TCustomSources.TestArchiveTemplateHttpRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('http-archive',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "http://git.example.com/{user}/{repository}/archive/{ref}.tar.gz", '
    + 'git = "https://git.example.com/{user}/{repository}.git"'
    + ' }'#10),
    'must use https://', Self);
end;

procedure TCustomSources.TestGitTemplateHttpRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('http-git',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz", '
    + 'git = "http://git.example.com/{user}/{repository}.git"'
    + ' }'#10),
    'must use https://', Self);
end;

procedure TCustomSources.TestShadowingBuiltinPrefixRejected;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('shadow-github',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    GiteaSourceLine('github')),
    'shadows a built-in prefix', Self);
end;

procedure TCustomSources.TestDepWithCustomPrefixRoutes;
var Man: TManifest;
begin
  Man := LoadManifest(WriteCustomSourceManifest('dep-with-custom',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    GiteaSourceLine('gitea') +
    ''#10 +
    '[dependencies]'#10 +
    'mylib = "gitea:team/mylib@v1.0.0"'#10));
  Expect<Integer>(Length(Man.Deps)).ToBe(1);
  Expect<string>(Man.Deps[0].Name).ToBe('mylib');
  Expect<Integer>(Ord(Man.Deps[0].SrcKind)).ToBe(Ord(skGitHost));
  Expect<Integer>(Ord(Man.Deps[0].SrcHost)).ToBe(Ord(hkCustom));
  Expect<string>(Man.Deps[0].SrcHostName).ToBe('gitea');
  Expect<string>(Man.Deps[0].SrcLocator).ToBe('team/mylib');
end;

procedure TCustomSources.TestDepWithUndeclaredCustomPrefixRejected;
begin
  { No [sources.gitea] declared; dep references gitea: prefix. }
  ExpectManifestLoadError(WriteCustomSourceManifest('undeclared',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'mylib = "gitea:team/mylib@v1.0.0"'#10),
    'unknown source prefix', Self);
end;

procedure TCustomSources.TestLockfilePermissiveOnUnknownPrefix;
var Entries: TResolvedArray;
begin
  { Lockfile entries with a "gitea:" source must load even when
    LoadLockfile has no manifest context. The kind is inferred as
    skGitHost; the host is hkCustom; the prefix is preserved for
    diagnostics; verification works via the resolvedURL + hashes. }
  Entries := LoadLockfile(
    WriteLockfileContent('permissive',
      'version = 3'#10 +
      ''#10 +
      '[package.mylib]'#10 +
      'source = "gitea:team/mylib"'#10 +
      'resolvedRef = "v1.0.0"'#10 +
      'resolvedURL = "https://git.example.com/team/mylib/archive/v1.0.0.tar.gz"'#10 +
      'computedHash = "sha256:abc"'#10 +
      'archiveHash = "sha256:def"'#10));
  Expect<Integer>(Length(Entries)).ToBe(1);
  Expect<Integer>(Ord(Entries[0].SrcKind)).ToBe(Ord(skGitHost));
  Expect<Integer>(Ord(Entries[0].SrcHost)).ToBe(Ord(hkCustom));
  Expect<string>(Entries[0].SrcHostName).ToBe('gitea');
end;

procedure TCustomSources.SetupTests;
begin
  Test('empty manifest produces zero custom sources',
    TestEmptyManifestHasNoCustomSources);
  Test('[sources] gitea = { archive, git } inline-table parsed',
    TestSingleCustomSourceParsed);
  Test('[sources] entry missing archive template hard-errors',
    TestMissingArchiveTemplateRejected);
  Test('[sources] entry missing git template hard-errors',
    TestMissingGitTemplateRejected);
  Test('archive template missing {ref} placeholder hard-errors',
    TestArchiveTemplateMissingRefPlaceholderRejected);
  Test('archive template missing {user} placeholder hard-errors',
    TestArchiveTemplateMissingUserPlaceholderRejected);
  Test('git template missing {repository} placeholder hard-errors',
    TestGitTemplateMissingRepositoryPlaceholderRejected);
  Test('archive template using plain HTTP hard-errors',
    TestArchiveTemplateHttpRejected);
  Test('git template using plain HTTP hard-errors',
    TestGitTemplateHttpRejected);
  Test('[sources] entry shadowing a built-in name hard-errors',
    TestShadowingBuiltinPrefixRejected);
  Test('dep with custom prefix routes to hkCustom + correct host name',
    TestDepWithCustomPrefixRoutes);
  Test('dep with undeclared custom prefix hard-errors at LoadManifest',
    TestDepWithUndeclaredCustomPrefixRejected);
  Test('lockfile read is permissive on unknown prefixes (no manifest context)',
    TestLockfilePermissiveOnUnknownPrefix);
end;

begin
  TestRunnerProgram.AddSuite(TSHA256NISTVectors.Create(
    'LWPT.Core: SHA-256 NIST vectors'));
  TestRunnerProgram.AddSuite(TLoadManifestHappy.Create(
    'LWPT.Manifest: LoadManifest happy path'));
  TestRunnerProgram.AddSuite(TLoadManifestValidation.Create(
    'LWPT.Manifest: LoadManifest validation'));
  TestRunnerProgram.AddSuite(TLoadManifestExtensions.Create(
    'LWPT.Manifest: LoadManifest extensions ([lwpt] / [format] / [generated])'));
  TestRunnerProgram.AddSuite(TLockfileLoading.Create(
    'LWPT.Install: LoadLockfile'));
  TestRunnerProgram.AddSuite(TVerifyAgainstLockfile.Create(
    'LWPT.Install: VerifyAgainstLockfile'));
  TestRunnerProgram.AddSuite(TParseDependencySource.Create(
    'LWPT.Manifest: ParseDependencySource'));
  TestRunnerProgram.AddSuite(TParseVersionSpec.Create(
    'LWPT.Manifest: ParseVersionSpec'));
  TestRunnerProgram.AddSuite(TGitProtocolParsing.Create(
    'LWPT.GitProtocol: ParseInfoRefs'));
  TestRunnerProgram.AddSuite(TCustomSources.Create(
    'LWPT.Manifest: Custom [sources]'));
  TestRunnerProgram.AddSuite(TPathGlobMatching.Create(
    'LWPT.Core: MatchPathGlob'));
  TestRunnerProgram.AddSuite(TApplyIncludeExclude.Create(
    'LWPT.Core: ApplyIncludeExclude'));
  TestRunnerProgram.AddSuite(TCopyDirTreeGuards.Create(
    'LWPT.Core: CopyDirTree recursion guards'));
  TestRunnerProgram.AddSuite(TWipeDirSymlinks.Create(
    'LWPT.Core: WipeDir symlink handling'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
