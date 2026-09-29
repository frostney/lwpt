{ LWPT.Core.Test — unit coverage for the testable internals
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
  cthreads,
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  Process,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.GitProtocol,
  LWPT.Install,
  LWPT.Manifest,
  LWPT.Registry.Consumer,
  TestingPascalLibrary,
  TOML;

type
  TSHA256NISTVectors = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEmptyString;
    procedure TestAbc;
    procedure TestExactlyOneBlock;
    procedure TestSpansTwoBlocks;
  end;

  THashTreePaths = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
  protected
    procedure AfterAll; override;
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestPinnedNestedTreeDigest;
    procedure TestCanonicalPathReplacesSourceDelimiter;
    procedure TestNormalizeConvertsCrlfToLf;
    procedure TestNormalizePreservesLoneCr;
    procedure TestNormalizeLeavesBinaryVerbatim;
    procedure TestNormalizeEmptyInput;
    procedure TestCrlfTreeHashesEqualLf;
    procedure TestFoldOrderIsAsciiCaseInsensitive;
  end;

  { The framed sha256-tree2 digest of ADR-0052: every vector of its section
    2, streaming, path validation, links, and rollback snapshots. }
  TTreeDigestV2 = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
    procedure Put(const ARelative: string; const AContent: string);
    procedure ExpectDigests(const ALegacy, ATree2: string);
    procedure ExpectDigestFailure(const AContains: string);
  protected
    procedure AfterAll; override;
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestEmptyDirectoryVector;
    procedure TestNestedVector;
    procedure TestFoldOrderVector;
    procedure TestIssue352Vectors;
    procedure TestContentVectors;
    procedure TestNonAsciiVectors;
    procedure TestCaseCollisionVector;
    procedure TestComparatorTiebreak;
    procedure TestRecordEncoding;
    procedure TestStreamingEqualsBuffered;
    procedure TestTreeIsNotBuffered;
    procedure TestStrictUTF16Conversion;
    procedure TestWellFormedPaths;
    procedure TestMalformedPosixNameFails;
    procedure TestMalformedWindowsNamesFail;
    procedure TestCopyDirTreeLinkParity;
    procedure TestFindTreeLinkNamesEveryLinkKind;
    procedure TestMissingDirectoryFails;
    procedure TestIsTreeDigest;
    procedure TestRetentionRecordsTree2Snapshot;
    procedure TestLegacySidecarIsRecovered;
  end;

  TLoadManifestHappy = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestMinimalManifestNameAndVersion;
    procedure TestPackageUnitsArrayParsed;
    procedure TestBuildEntriesTable;
    procedure TestVersionSection;
    procedure TestManifestSnapshotBindsParsedBytes;
    procedure TestRootCompilerProfilesParsed;
    procedure TestBuildTargetTupleParsed;
    procedure TestDependencyCompilerPolicyIgnored;
  end;

  TLoadManifestValidation = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBareStringDepShorthandRejected;
    procedure TestDepWithoutSourceRejected;
    procedure TestDepWithHttpSourceRejected;
    procedure TestUnknownSourceKindRejected;
    procedure TestMissingManifestRejected;
    procedure TestBuildEntryTraversalNameRootOnly;
    procedure TestBuildDependsMustBeStringArray;
    procedure TestBuildFlagsMustBeStringArrayAndAreRootOnly;
    procedure TestTestFlagsMustBeStringArrayAndAreRootOnly;
    procedure TestUndeclaredCompilerProfilesAreRejected;
    procedure TestArrayCannotBecomeTablePath;
    procedure TestLegacyRunnableFieldsAreRejected;
  end;

  TLoadManifestExtensions = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestLwptOverridesParsed;
    procedure TestFormatExcludesParsed;
    procedure TestPrebuildHookEntriesParsed;
    procedure TestHookShorthandStringForm;
    procedure TestHookPairedInputsOutputRequired;
    procedure TestHookArraysAreStrict;
    procedure TestPerEntryHooksParsed;
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
    procedure TestSchemaV3RaisesWithRepairHint;
    procedure TestSchemaV3LoadsOnlyForTheUpgrade;
    procedure TestNewerSchemaNamesTheReader;
    procedure TestLegacyDigestInV4Fails;
    procedure TestRegistryTablesShareTheGate;
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

  { The frozen verifier's accumulated-constraints fingerprint. A lockfile
    is written on one machine and verified on another, so both the digest
    input and the line ORDER must be platform-invariant — hashing
    TStrings.Text made a POSIX-written lockfile fail --frozen on Windows,
    and a locale-collated sort would reintroduce the same class through
    line ordering. The pinned vectors below are the LF-terminated fold and
    the ordinal node sort; they fail on any platform (Windows CI included)
    whose fold or sort drifts. }
  TConstraintFingerprintFold = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestPinnedFingerprintForFixedConstraintSet;
    procedure TestFoldReproducesPlatformTextOnLineFeedPlatforms;
    procedure TestNodeFingerprintPinsOrdinalSort;
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
    procedure TestPeelSuffixRecordsCommitIdentity;
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
    procedure TestDanglingFileSymlinkSkipped;
    procedure TestDstInsideSrcRaises;
    procedure TestDstEqualsSrcRaises;
    procedure TestDstInsideAliasedSrcRaises;
    procedure TestAliasedSrcToDisjointDstCopies;
    procedure TestPathContainsBoundaries;
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

  { SanitisePathSegment — the shared flattener behind session-private
    build jobs and per-test build dirs. }
  TSanitisePathSegmentSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestPlainNameUnchanged;
    procedure TestSeparatorsFlattened;
    procedure TestDistinctInputsCanCollide;
  end;

  TMakeTmpPathThread = class(TThread)
  private
    FHint: string;
    FPaths: TStringList;
    FRoot: string;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARoot, AHint: string);
    destructor Destroy; override;
    property ErrorText: string read FErrorText;
    property Paths: TStringList read FPaths;
  end;

  TEnvironmentCopyThread = class(TThread)
  private
    FCopy: TStringList;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    property Copied: TStringList read FCopy;
    property ErrorText: string read FErrorText;
  end;

  TMakeTmpPathSuite = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
  protected
    procedure AfterAll; override;
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestExistingCandidateIsSkipped;
    procedure TestManyCallsAreDistinct;
    procedure TestSiblingCallsAreDistinct;
    procedure TestSiblingExistingCandidateIsSkipped;
    procedure TestThreadedBurstIsDistinct;
  end;

  { AppendProcessEnvironment must stay safe under concurrent first use:
    the RTL's GetEnvironmentVariableCount lazily initialises a shared
    global without synchronisation, and unsynchronised parallel sweeps
    truncated child environments (the aarch64-darwin fpc-proxy
    misroute). Every concurrent copy must be complete and identical. }
  TAppendProcessEnvironmentSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestConcurrentCopiesAreCompleteAndIdentical;
  end;

  { AtomicMoveFile / AtomicMoveDir with a bare relative destination
    (no directory component). ExtractFileDir of such a path is '',
    which the sibling tmp-path generator used to expand to the
    filesystem root, so the rename-aside backup of an existing
    destination landed at '/<name>.old.…' and the move failed. The
    suite chdirs into a scratch directory so bare names resolve
    inside it. }
  TAtomicMoveBareDestination = class(TTestSuite)
  private
    FOrigDir: string;
    FScratch: string;
    {$IFDEF UNIX}
    FCrossDeviceBase: string;
    FCrossDeviceSkipReason: string;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FJunctionSkipReason: string;
    {$ENDIF}
  protected
    procedure AfterAll; override;
    procedure BeforeAll; override;
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestSiblingOfBareFilenameStaysRelative;
    procedure TestMoveFileReplacesExistingBareDestination;
    procedure TestMoveDirReplacesExistingBareDestination;
    procedure TestRetiredExecutableSweepMatchesOnlyRetiredImages;
    procedure TestRetiredExecutableSweepStaysInsideOwnerRoot;
    {$IFDEF MSWINDOWS}
    procedure TestReplaceFileAtDeepExistingDestination;
    procedure TestReplaceFileRejectsDirectorySource;
    procedure TestReplaceExecutableRetiresMappedImage;
    procedure TestReplaceFileStaysStrictForMappedImage;
    procedure TestRetiredExecutableSweepRefusesJunctions;
    {$ENDIF}
    {$IFDEF UNIX}
    procedure TestMoveFileReplacesExistingAcrossFilesystems;
    procedure TestRetiredExecutableSweepSkipsFileLinks;
    procedure TestRetiredExecutableSweepRefusesDirectoryLinks;
    {$ENDIF}
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
    procedure TestRefPlaceholderInHostRejected;
    procedure TestShadowingBuiltinPrefixRejected;
    procedure TestDepWithCustomPrefixRoutes;
    procedure TestDepWithUndeclaredCustomPrefixRejected;
    procedure TestLockfilePermissiveOnUnknownPrefix;
  end;

  { ADR-0019 — lockfile-diff pruning behind `lwpt add` / `lwpt remove`. }
  TPruneOrphans = class(TTestSuite)
  private
    function  SetupPruneDirs(const ASuffix: string;
      out AModules, AArchives: string): string;
    function  MakeEntry(const AName: string; AKind: TSourceKind;
      const AVersion: string): TResolved;
  public
    procedure SetupTests; override;
    procedure TestRemovedPackagePrunesModulesAndArchive;
    procedure TestKindChangeToLocalPrunesOldArchive;
    procedure TestVersionBumpPrunesStaleArchive;
    procedure TestUnchangedEntryPrunesNothing;
    procedure TestUnsafeLockfileKeyRefusesToPrune;
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

{ Plant one fixture file, creating parent dirs. Shared by the
  tree-planting suites (TApplyIncludeExclude, TCopyDirTreeGuards). }
procedure WriteFixtureFile(const APath, AText: string);
var
  SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure WriteFixtureBytes(const APath: string; const ABytes: TBytes);
var
  FS: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  FS := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      FS.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    FS.Free;
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

{ ── THashTreePaths ───────────────────────────────────────────────── }

procedure THashTreePaths.ResetScratch;
begin
  WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure THashTreePaths.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/hash-tree-'
    + IntToStr(GetProcessID));
  ResetScratch;
end;

procedure THashTreePaths.AfterAll;
begin
  WipeDir(FScratch);
end;

procedure THashTreePaths.TestPinnedNestedTreeDigest;
const
  EXPECTED = 'sha256:5c970f737e82874a0c3c6bde83813385951ef2a78125d709ac4b46f5812ba4d4';
begin
  ResetScratch;
  WriteFixtureBytes(FScratch + PathDelim + 'alpha.txt',
    StringAsBytes('alpha'));
  WriteFixtureBytes(FScratch + PathDelim + 'nested' + PathDelim + 'beta.bin',
    StringAsBytes('beta'));
  WriteFixtureBytes(FScratch + PathDelim + 'nested' + PathDelim + 'deeper'
    + PathDelim + 'gamma.txt', StringAsBytes('gamma'));

  { The legacy v3 digest stays pinned: rollback recovery still validates
    sidecars that a pre-v4 binary wrote with it. }
  Expect<string>(LegacyHashTree(FScratch)).ToBe(EXPECTED);
end;

procedure THashTreePaths.TestCanonicalPathReplacesSourceDelimiter;
begin
  Expect<string>(CanonicalTreeHashPath('nested\file.txt', '\'))
    .ToBe('nested' + TREE_HASH_PATH_SEPARATOR + 'file.txt');
  { A backslash is a legal filename character on POSIX: with '/' as the
    source delimiter it must survive canonicalisation untouched. }
  Expect<string>(CanonicalTreeHashPath('nested\file.txt', '/'))
    .ToBe('nested\file.txt');
end;

procedure THashTreePaths.TestNormalizeConvertsCrlfToLf;
begin
  { CRLF text folds to exactly its LF form — the content analogue of the
    path canonicalisation, so a Windows checkout hashes as its LF tree. }
  Expect<string>(SHA256Hex(NormalizeTreeHashContent(
    StringAsBytes('a'#13#10'b'#13#10'c'))))
    .ToBe(SHA256Hex(StringAsBytes('a'#10'b'#10'c')));
end;

procedure THashTreePaths.TestNormalizePreservesLoneCr;
begin
  { A CR not followed by LF survives untouched (git's convention). }
  Expect<string>(SHA256Hex(NormalizeTreeHashContent(
    StringAsBytes('a'#13'b'#13))))
    .ToBe(SHA256Hex(StringAsBytes('a'#13'b'#13)));
end;

procedure THashTreePaths.TestNormalizeLeavesBinaryVerbatim;
var
  Bin: TBytes;
begin
  { A NUL byte marks the content binary: its embedded CRLF must NOT fold,
    so the exact bytes reach the digest. }
  Bin := StringAsBytes('a'#13#10#0'b'#13#10);
  Expect<string>(SHA256Hex(NormalizeTreeHashContent(Bin)))
    .ToBe(SHA256Hex(Bin));
end;

procedure THashTreePaths.TestNormalizeEmptyInput;
begin
  Expect<Integer>(Length(NormalizeTreeHashContent(nil))).ToBe(0);
end;

procedure THashTreePaths.TestCrlfTreeHashesEqualLf;
var
  CrlfDigest, LfDigest: string;
begin
  { End-to-end: a CRLF working tree and its LF twin produce one digest. }
  ResetScratch;
  WriteFixtureBytes(FScratch + PathDelim + 'unit.pas',
    StringAsBytes('unit A;'#13#10'begin'#13#10'end.'#13#10));
  CrlfDigest := HashTree(FScratch);
  ResetScratch;
  WriteFixtureBytes(FScratch + PathDelim + 'unit.pas',
    StringAsBytes('unit A;'#10'begin'#10'end.'#10));
  LfDigest := HashTree(FScratch);
  Expect<string>(CrlfDigest).ToBe(LfDigest);
end;

procedure THashTreePaths.TestFoldOrderIsAsciiCaseInsensitive;
const
  { Independently computed (SHA-256 over path + #10 + bytes, folded in
    ASCII case-insensitive path order): the exact order every existing
    lockfile was written with. Windows word-sort ranks 'leaf.cnf' BEFORE
    'leaf-ca-true.cnf' (hyphens are primary-ignorable) and would yield
    c7e20c2d... instead — the real-world "tree hash mismatch" this
    comparator pin fixes. }
  EXPECTED = 'sha256:77386de0b4e46c60b337ea3255b2f68ddb48a46a1a216a828dce604a2f84ad85';
begin
  ResetScratch;
  WriteFixtureBytes(FScratch + PathDelim + 'leaf-ca-true.cnf',
    StringAsBytes('ca=true'#10));
  WriteFixtureBytes(FScratch + PathDelim + 'leaf.cnf',
    StringAsBytes('leaf'#10));
  WriteFixtureBytes(FScratch + PathDelim + 'README.md',
    StringAsBytes('# fixture'#10));
  WriteFixtureBytes(FScratch + PathDelim + 'sub' + PathDelim + 'a-b.pas',
    StringAsBytes('unit ab;'#10));
  WriteFixtureBytes(FScratch + PathDelim + 'sub' + PathDelim + 'ab.pas',
    StringAsBytes('unit ab2;'#10));

  Expect<string>(LegacyHashTree(FScratch)).ToBe(EXPECTED);
end;

procedure THashTreePaths.SetupTests;
begin
  Test('nested tree digest matches the pinned hash layout',
    TestPinnedNestedTreeDigest);
  Test('canonical path replaces the supplied source delimiter',
    TestCanonicalPathReplacesSourceDelimiter);
  Test('normalize folds CRLF content to its LF form',
    TestNormalizeConvertsCrlfToLf);
  Test('normalize preserves a lone CR',
    TestNormalizePreservesLoneCr);
  Test('normalize leaves NUL-bearing binary verbatim',
    TestNormalizeLeavesBinaryVerbatim);
  Test('normalize returns empty for empty input',
    TestNormalizeEmptyInput);
  Test('CRLF tree hashes equal its LF twin',
    TestCrlfTreeHashesEqualLf);
  Test('fold order is ASCII case-insensitive on every platform',
    TestFoldOrderIsAsciiCaseInsensitive);
end;

function ReadFixtureText(const APath: string): RawByteString;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

{ ── TTreeDigestV2 ──────────────────────────────────────────────── }

{ Heap tracking for the streaming bound: a wrapper memory manager counts the
  bytes live between Begin and End and records their peak. The test runs
  single-threaded while it is installed. }
var
  TrackedPrevious: TMemoryManager;
  TrackedCurrent, TrackedPeak: PtrInt;

function TrackedGetMem(ASize: PtrUInt): Pointer;
begin
  Result := TrackedPrevious.GetMem(ASize);
  if Result <> nil then
  begin
    Inc(TrackedCurrent, PtrInt(TrackedPrevious.MemSize(Result)));
    if TrackedCurrent > TrackedPeak then TrackedPeak := TrackedCurrent;
  end;
end;

function TrackedFreeMem(APointer: Pointer): PtrUInt;
begin
  if APointer <> nil then
    Dec(TrackedCurrent, PtrInt(TrackedPrevious.MemSize(APointer)));
  Result := TrackedPrevious.FreeMem(APointer);
end;

function TrackedFreeMemSize(APointer: Pointer; ASize: PtrUInt): PtrUInt;
begin
  if APointer <> nil then
    Dec(TrackedCurrent, PtrInt(TrackedPrevious.MemSize(APointer)));
  Result := TrackedPrevious.FreeMemSize(APointer, ASize);
end;

function TrackedAllocMem(ASize: PtrUInt): Pointer;
begin
  Result := TrackedPrevious.AllocMem(ASize);
  if Result <> nil then
  begin
    Inc(TrackedCurrent, PtrInt(TrackedPrevious.MemSize(Result)));
    if TrackedCurrent > TrackedPeak then TrackedPeak := TrackedCurrent;
  end;
end;

function TrackedReAllocMem(var APointer: Pointer; ASize: PtrUInt): Pointer;
var Before: PtrInt;
begin
  Before := 0;
  if APointer <> nil then Before := PtrInt(TrackedPrevious.MemSize(APointer));
  Result := TrackedPrevious.ReAllocMem(APointer, ASize);
  Dec(TrackedCurrent, Before);
  if APointer <> nil then
    Inc(TrackedCurrent, PtrInt(TrackedPrevious.MemSize(APointer)));
  if TrackedCurrent > TrackedPeak then TrackedPeak := TrackedCurrent;
end;

procedure BeginHeapTracking;
var Tracking: TMemoryManager;
begin
  GetMemoryManager(TrackedPrevious);
  Tracking := TrackedPrevious;
  Tracking.GetMem := TrackedGetMem;
  Tracking.FreeMem := TrackedFreeMem;
  Tracking.FreeMemSize := TrackedFreeMemSize;
  Tracking.AllocMem := TrackedAllocMem;
  Tracking.ReAllocMem := TrackedReAllocMem;
  TrackedCurrent := 0;
  TrackedPeak := 0;
  SetMemoryManager(Tracking);
end;

procedure EndHeapTracking;
begin
  SetMemoryManager(TrackedPrevious);
end;

{ A fixture file whose name is given as UTF-16. Windows creates it through
  CreateFileW, so no ANSI code page is involved; POSIX creates the strictly
  converted UTF-8 bytes. }
procedure WriteNamedFixture(const ADirectory: string;
  const AName: UnicodeString; const ABytes: TBytes);
{$IFDEF MSWINDOWS}
var Handle: THandle; Written: DWORD;
begin
  ForceDirectories(ADirectory);
  Handle := CreateFileW(PWideChar(UnicodeString(ADirectory) + '\' + AName),
    GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then
    raise Exception.Create('fixture: CreateFileW failed for '
      + EscapeUTF16Name(AName));
  try
    Written := 0;
    if (Length(ABytes) > 0)
       and not WriteFile(Handle, ABytes[0], Length(ABytes), Written, nil) then
      raise Exception.Create('fixture: WriteFile failed');
  finally
    CloseHandle(Handle);
  end;
end;
{$ELSE}
var Name: RawByteString;
begin
  if not StrictUTF16ToUTF8(AName, Name) then
    raise Exception.Create('fixture: malformed UTF-16 name');
  WriteFixtureBytes(ADirectory + '/' + Name, ABytes);
end;
{$ENDIF}

{ Removes the flat fixture files of ADirectory by their UTF-16 names: the
  ANSI-path WipeDir cannot name a file outside the code page on Windows. }
procedure RemoveNamedFixtures(const ADirectory: string);
{$IFDEF MSWINDOWS}
var Find: THandle; Data: TWin32FindDataW; Name: UnicodeString;
begin
  Find := FindFirstFileW(PWideChar(UnicodeString(ADirectory) + '\*'), Data);
  if Find = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      Name := PWideChar(@Data.cFileName[0]);
      if (Name = '.') or (Name = '..') then Continue;
      if (Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
        DeleteFileW(PWideChar(UnicodeString(ADirectory) + '\' + Name));
    until not FindNextFileW(Find, Data);
  finally
    Windows.FindClose(Find);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

function Utf16(const ACodeUnits: array of Word): UnicodeString;
var i: Integer;
begin
  SetLength(Result, Length(ACodeUnits));
  for i := 0 to High(ACodeUnits) do Result[i + 1] := WideChar(ACodeUnits[i]);
end;

function BytesToHex(const ABytes: RawByteString): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(ABytes) do
    Result := Result + LowerCase(IntToHex(Ord(ABytes[i]), 2));
end;

procedure TTreeDigestV2.ResetScratch;
begin
  WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TTreeDigestV2.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/tree2-'
    + IntToStr(GetProcessID));
  ResetScratch;
end;

procedure TTreeDigestV2.AfterAll;
begin
  WipeDir(FScratch);
end;

procedure TTreeDigestV2.Put(const ARelative: string; const AContent: string);
begin
  WriteFixtureBytes(FScratch + PathDelim + StringReplace(ARelative, '/',
    PathDelim, [rfReplaceAll]), StringAsBytes(AContent));
end;

procedure TTreeDigestV2.ExpectDigests(const ALegacy, ATree2: string);
begin
  if ALegacy <> '' then
    Expect<string>(LegacyHashTree(FScratch)).ToBe('sha256:' + ALegacy);
  Expect<string>(HashTree(FScratch)).ToBe(TREE_DIGEST_PREFIX + ATree2);
end;

procedure TTreeDigestV2.TestEmptyDirectoryVector;
begin
  ResetScratch;
  ExpectDigests(
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    '27822f587b72b705a08f0c9865fe020a44bbd681b87df7462f2cc46af0e33ab7');
end;

procedure TTreeDigestV2.TestNestedVector;
begin
  ResetScratch;
  Put('alpha.txt', 'alpha');
  Put('nested/beta.bin', 'beta');
  Put('nested/deeper/gamma.txt', 'gamma');
  ExpectDigests(
    '5c970f737e82874a0c3c6bde83813385951ef2a78125d709ac4b46f5812ba4d4',
    '24a5a83e163c4c78a47b5c93c5f7061ed40cff21bf794d2237e88d40114947ae');
end;

procedure TTreeDigestV2.TestFoldOrderVector;
begin
  ResetScratch;
  Put('leaf-ca-true.cnf', 'ca=true'#10);
  Put('leaf.cnf', 'leaf'#10);
  Put('README.md', '# fixture'#10);
  Put('sub/a-b.pas', 'unit ab;'#10);
  Put('sub/ab.pas', 'unit ab2;'#10);
  ExpectDigests(
    '77386de0b4e46c60b337ea3255b2f68ddb48a46a1a216a828dce604a2f84ad85',
    'c832919ae78620edac02c29d991b78b2895023c181110c3095d4b1759ed666b1');
end;

const
  JSON_MANIFEST = '[package]'#10'name = "json"'#10'version = "1.3.0"'#10
    + 'units = ["source"]'#10;
  JSON_UNIT_TAIL = '{ 1.3.0 }'#10'interface'#10'implementation'#10'end.'#10;

procedure TTreeDigestV2.TestIssue352Vectors;
var LegacyOriginal, Tree2Original: string;
begin
  { The #352 layout substitution: equal legacy digests, different tree2
    digests. }
  ResetScratch;
  Put('lwpt.toml', JSON_MANIFEST);
  Put('source/json.pas', 'unit json;'#10 + JSON_UNIT_TAIL);
  ExpectDigests(
    '68f88ceb5c7c6ff44ff90c66861ad33fba687776194988f2aee59078b8c4508f',
    '10e083e1804357e2376467dedbb598b3059e7a69bd18f125498e5e92efca1c1a');
  LegacyOriginal := LegacyHashTree(FScratch);
  Tree2Original := HashTree(FScratch);
  ResetScratch;
  Put('lwpt.toml', JSON_MANIFEST);
  Put('source/json.pas', '');
  Put('unit json;', JSON_UNIT_TAIL);
  ExpectDigests(
    '68f88ceb5c7c6ff44ff90c66861ad33fba687776194988f2aee59078b8c4508f',
    '67817df420cfac5318569f13b72d82082cc28f3e889aacaf392e37bfaf14943d');
  Expect<string>(LegacyHashTree(FScratch)).ToBe(LegacyOriginal);
  Expect<Boolean>(HashTree(FScratch) <> Tree2Original).ToBe(True);
end;

procedure TTreeDigestV2.TestContentVectors;
begin
  ResetScratch;
  Put('unit.pas', 'unit A;'#13#10'begin'#13#10'end.'#13#10);
  ExpectDigests(
    '2bb80f3322fc70ef3ab7bda3fc07e71bbbbc153c0618e655bf4139af6bedbb05',
    '7c177c9e38d6e6f87d4fcbc81e5af3e89d41ab13806c2ecc13cedcd74681bd8c');
  ResetScratch;
  Put('unit.pas', 'unit A;'#10'begin'#10'end.'#10);
  ExpectDigests(
    '2bb80f3322fc70ef3ab7bda3fc07e71bbbbc153c0618e655bf4139af6bedbb05',
    '7c177c9e38d6e6f87d4fcbc81e5af3e89d41ab13806c2ecc13cedcd74681bd8c');
  ResetScratch;
  Put('blob.bin', 'a'#13#10#0'b'#13#10);
  ExpectDigests(
    '69934cb6a9d50a2d61ebb273ddbbcd6f8f29806a652a57e8e6bef1305d2d2782',
    'cf31319e6c1d6b3e75f2fbece1f5f6d4d97f9105a455a7ca4511a123808c3836');
  ResetScratch;
  Put('blob.bin', 'a'#10#0'b'#10);
  ExpectDigests(
    '4c3f6771f755d55099b1a72e54e0665187931cfb0ce5d2852d8d37569d1e12d6',
    'e51425a5ce78cb9d69d51f068373e691b794c9b31c8b65ec522c5761a6650d7e');
  ResetScratch;
  Put('cr.txt', 'a'#13'b'#13);
  ExpectDigests(
    '62f79a9f6fe3a6805be13d8d9a6040422b06f6bf9c39e172693c0d52f4831f8c',
    '6767b67a1459191651578f01c861b4e6b7681825da5449dbdb7087c74bb1b5eb');
  ResetScratch;
  Put('empty.pas', '');
  ExpectDigests(
    '7de1b0d19b3467c2191240d86d4479c6635e73c0c30cb99f005e3213c45a17bb',
    '86d302c47f0b9d1c94fd0385467be28c3d31fef8f03df93345c0203295b9df32');
end;

procedure TTreeDigestV2.TestNonAsciiVectors;
const
  { The legacy digest read names through the ANSI code page on Windows, so
    it is pinned for these names on POSIX only. }
  {$IFDEF MSWINDOWS}
  LEGACY_SUSS = '';
  LEGACY_SUPPLEMENTARY = '';
  {$ELSE}
  LEGACY_SUSS =
    '2ac8aeee577349918473caaebe1f3cd79a1cd83c749c1c2a0c80969a206b9616';
  LEGACY_SUPPLEMENTARY =
    'd4beb95e5f9d918a1a7beddc50331157c88d431063f5e3d3483520594ffa10bb';
  {$ENDIF}
begin
  ResetScratch;
  try
    WriteNamedFixture(FScratch, Utf16([Ord('s'), $00FC, $00DF, Ord('.'),
      Ord('p'), Ord('a'), Ord('s')]), StringAsBytes('unit s;'#10));
    ExpectDigests(LEGACY_SUSS,
      '8398b468076302b8f9cf0a930f6e7d129f7201c6896bafabe2674385c7a25069');
  finally
    RemoveNamedFixtures(FScratch);
  end;
  { U+1D518 is the surrogate pair D835 DD18: on Windows this exercises the
    pair's conversion to its four-byte UTF-8 form. }
  ResetScratch;
  try
    WriteNamedFixture(FScratch, Utf16([$D835, $DD18, Ord('.'), Ord('p'),
      Ord('a'), Ord('s')]), StringAsBytes('unit u;'#10));
    ExpectDigests(LEGACY_SUPPLEMENTARY,
      '07c9aecdbc478349c8f2c275ff6e01717a166118cd2e2e8f1089b9be5486fe8a');
  finally
    RemoveNamedFixtures(FScratch);
  end;
end;

procedure TTreeDigestV2.TestCaseCollisionVector;
begin
  { Only case-sensitive filesystems can hold both names; each creation
    order must give the tiebreak's digest. }
  ResetScratch;
  Put('a.pas', 'unit a;'#10);
  Put('A.pas', 'unit A;'#10);
  ExpectDigests(
    'c179b461d81015e4bfdcaa89a916b3b84f473b00f4466ee5412f8cda08b39d37',
    'ce003a228b9696df3a9f38e525a88fc8e295feb855f7850e9ac49a6615c4256a');
  ResetScratch;
  Put('A.pas', 'unit A;'#10);
  Put('a.pas', 'unit a;'#10);
  ExpectDigests(
    'c179b461d81015e4bfdcaa89a916b3b84f473b00f4466ee5412f8cda08b39d37',
    'ce003a228b9696df3a9f38e525a88fc8e295feb855f7850e9ac49a6615c4256a');
end;

procedure TTreeDigestV2.TestComparatorTiebreak;
var Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    Paths.Add('a.pas');
    Paths.Add('A.pas');
    Paths.CustomSort(@TreeHashPathCompare);
    Expect<string>(Paths[0] + '|' + Paths[1]).ToBe('A.pas|a.pas');
    Paths.Clear;
    Paths.Add('A.pas');
    Paths.Add('a.pas');
    Paths.CustomSort(@TreeHashPathCompare);
    Expect<string>(Paths[0] + '|' + Paths[1]).ToBe('A.pas|a.pas');
  finally
    Paths.Free;
  end;
end;

procedure TTreeDigestV2.TestRecordEncoding;
var Expected: TBytes; Stream: string; Size: Int64; Digest: TSHA256Digest;
  Bytes: TBytesStream;
begin
  { One file `alpha.txt` holding `alpha`: magic, then 01, 00000009, the
    path, 0000000000000005, and SHA-256("alpha"). }
  Bytes := TBytesStream.Create(StringAsBytes('alpha'));
  try
    Digest := TreeContentDigest(Bytes, Size);
  finally
    Bytes.Free;
  end;
  Expect<Int64>(Size).ToBe(5);
  Expect<string>(SHA256DigestHex(Digest))
    .ToBe(SHA256Hex(StringAsBytes('alpha')));
  Stream := 'sha256-tree2'#0 + #1 + #0#0#0#9 + 'alpha.txt'
    + #0#0#0#0#0#0#0#5;
  Expected := StringAsBytes(Stream);
  SetLength(Expected, Length(Expected) + 32);
  Move(Digest[0], Expected[Length(Stream)], 32);
  ResetScratch;
  Put('alpha.txt', 'alpha');
  Expect<string>(HashTree(FScratch))
    .ToBe(TREE_DIGEST_PREFIX + SHA256Hex(Expected));
end;

procedure TTreeDigestV2.TestStreamingEqualsBuffered;

  procedure Check(const ALabel: string; const AData: TBytes);
  var Stream: TBytesStream; Size: Int64; Digest: TSHA256Digest;
    Normalized: TBytes;
  begin
    Normalized := NormalizeTreeHashContent(AData);
    Stream := TBytesStream.Create(AData);
    try
      Digest := TreeContentDigest(Stream, Size);
    finally
      Stream.Free;
    end;
    if SHA256DigestHex(Digest) <> SHA256Hex(Normalized) then
      Fail('streamed digest differs for ' + ALabel);
    Expect<string>(SHA256DigestHex(Digest)).ToBe(SHA256Hex(Normalized));
    Expect<Int64>(Size).ToBe(Length(Normalized));
  end;

  function Text(const ACount: Integer): TBytes;
  var i: Integer;
  begin
    SetLength(Result, ACount);
    for i := 0 to ACount - 1 do Result[i] := Ord('a') + i mod 23;
  end;

var
  Chunk, i: Integer;
  Data: TBytes;
begin
  Chunk := TREE_DIGEST_CHUNK_BYTES;
  Check('empty', nil);
  for i := -1 to 1 do
  begin
    Data := Text(Chunk + i);
    Data[10] := TREE_HASH_BYTE_CR;
    Data[11] := TREE_HASH_BYTE_LF;
    Check('size chunk' + IntToStr(i), Data);
  end;
  { A CR as the last byte of a chunk followed by an LF in the next. }
  Data := Text(Chunk + 5);
  Data[Chunk - 1] := TREE_HASH_BYTE_CR;
  Data[Chunk] := TREE_HASH_BYTE_LF;
  Check('CR at chunk end before LF', Data);
  { A CR as the last byte of a chunk followed by another byte, or a CR. }
  Data := Text(Chunk + 5);
  Data[Chunk - 1] := TREE_HASH_BYTE_CR;
  Check('lone CR at chunk end', Data);
  Data := Text(Chunk + 5);
  Data[Chunk - 1] := TREE_HASH_BYTE_CR;
  Data[Chunk] := TREE_HASH_BYTE_CR;
  Data[Chunk + 1] := TREE_HASH_BYTE_LF;
  Check('CR CR LF across the chunk end', Data);
  { A CR at end of file, at a chunk boundary and inside a chunk. }
  Data := Text(Chunk);
  Data[Chunk - 1] := TREE_HASH_BYTE_CR;
  Check('CR at end of file on the chunk boundary', Data);
  Data := Text(7);
  Data[6] := TREE_HASH_BYTE_CR;
  Check('CR at end of a short file', Data);
  { A NUL only in the last chunk, after CRLFs in the first: binary. }
  Data := Text(Chunk + 100);
  for i := 0 to 20 do
  begin
    Data[i * 3] := TREE_HASH_BYTE_CR;
    Data[i * 3 + 1] := TREE_HASH_BYTE_LF;
  end;
  Data[Chunk + 50] := TREE_HASH_BYTE_NUL;
  Check('NUL in the last chunk after CRLFs', Data);
end;

procedure TTreeDigestV2.TestTreeIsNotBuffered;
const
  FILE_MEBIBYTES = 64;
  LIMIT_BYTES = 1024 * 1024;
var
  Stream: TFileStream;
  Block: TBytes;
  i: Integer;
  Digest: string;
  Peak: PtrInt;
begin
  { One 64 MiB file of NUL bytes: binary, so the normalized context stops at
    the first byte and only the raw context runs. }
  ResetScratch;
  SetLength(Block, 1024 * 1024);
  FillChar(Block[0], Length(Block), 0);
  Stream := TFileStream.Create(FScratch + PathDelim + 'large.bin', fmCreate);
  try
    for i := 1 to FILE_MEBIBYTES do Stream.WriteBuffer(Block[0], Length(Block));
  finally
    Stream.Free;
  end;
  SetLength(Block, 0);
  { The tracker is live: a 2 MiB allocation shows in its peak. }
  BeginHeapTracking;
  try
    SetLength(Block, 2 * LIMIT_BYTES);
    Peak := TrackedPeak;
    SetLength(Block, 0);
  finally
    EndHeapTracking;
  end;
  Expect<Boolean>(Peak >= 2 * LIMIT_BYTES).ToBe(True);
  BeginHeapTracking;
  try
    Digest := HashTree(FScratch);
  finally
    EndHeapTracking;
  end;
  Peak := TrackedPeak;
  Expect<Boolean>(IsTreeDigest(Digest)).ToBe(True);
  if Peak >= LIMIT_BYTES then
    Fail('hashing a 64 MiB file raised peak heap use by '
      + IntToStr(Peak) + ' bytes');
  Expect<Boolean>(Peak < LIMIT_BYTES).ToBe(True);
end;

procedure TTreeDigestV2.TestStrictUTF16Conversion;
var UTF8: RawByteString;
begin
  { A correctly paired surrogate converts to its four-byte form. }
  Expect<Boolean>(StrictUTF16ToUTF8(Utf16([$D835, $DD18]), UTF8)).ToBe(True);
  Expect<string>(BytesToHex(UTF8)).ToBe('f09d9498');
  Expect<Boolean>(StrictUTF16ToUTF8(Utf16([Ord('s'), $00FC, $00DF]), UTF8))
    .ToBe(True);
  Expect<string>(BytesToHex(UTF8)).ToBe('73c3bcc39f');
  { Unpaired or reversed surrogates fail; they are never replaced with
    U+FFFD, which would merge distinct names. }
  Expect<Boolean>(StrictUTF16ToUTF8(Utf16([Ord('a'), $D800]), UTF8))
    .ToBe(False);
  Expect<Boolean>(StrictUTF16ToUTF8(Utf16([$DC00, Ord('a')]), UTF8))
    .ToBe(False);
  Expect<Boolean>(StrictUTF16ToUTF8(Utf16([$DC00, $D800]), UTF8)).ToBe(False);
  Expect<Boolean>(StrictUTF16ToUTF8(Utf16([$D800, Ord('b')]), UTF8))
    .ToBe(False);
  Expect<string>(EscapeUTF16Name(Utf16([Ord('a'), $D800])))
    .ToBe('a\ud800');
end;

procedure TTreeDigestV2.TestWellFormedPaths;
begin
  Expect<Boolean>(IsWellFormedTreePath('source/json.pas')).ToBe(True);
  Expect<Boolean>(IsWellFormedTreePath('s'#$C3#$BC#$C3#$9F'.pas')).ToBe(True);
  Expect<Boolean>(IsWellFormedTreePath(#$F0#$9D#$94#$98'.pas')).ToBe(True);
  Expect<Boolean>(IsWellFormedTreePath('')).ToBe(False);
  Expect<Boolean>(IsWellFormedTreePath('bad'#$FF'.pas')).ToBe(False);
  { Overlong '/', a UTF-8-encoded surrogate, beyond U+10FFFF, truncated. }
  Expect<Boolean>(IsWellFormedTreePath(#$C0#$AF)).ToBe(False);
  Expect<Boolean>(IsWellFormedTreePath(#$ED#$A0#$80)).ToBe(False);
  Expect<Boolean>(IsWellFormedTreePath(#$F4#$90#$80#$80)).ToBe(False);
  Expect<Boolean>(IsWellFormedTreePath('a'#$C3)).ToBe(False);
  Expect<Boolean>(IsWellFormedTreePath('a'#0'b')).ToBe(False);
  Expect<string>(EscapeTreePath('bad'#$FF'.pas')).ToBe('bad\xff.pas');
end;

procedure TTreeDigestV2.ExpectDigestFailure(const AContains: string);
var Raised: Boolean;
begin
  Raised := False;
  try
    HashTree(FScratch);
  except
    on E: EVerifyError do
    begin
      Raised := True;
      if Pos(AContains, E.Message) = 0 then
        Fail('expected the digest error to name ' + AContains + '; got: '
          + E.Message);
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TTreeDigestV2.TestMalformedPosixNameFails;
begin
  { Linux stores any byte string; the digest fails closed and names it. }
  ResetScratch;
  Put('ok.pas', 'unit ok;'#10);
  WriteFixtureBytes(FScratch + '/bad'#$FF'.pas', StringAsBytes('x'));
  ExpectDigestFailure('bad\xff.pas');
end;

procedure TTreeDigestV2.TestMalformedWindowsNamesFail;

  { NTFS stores unpaired surrogates. Wine maps names onto a host
    filesystem that cannot, so there only the conversion is checked. }
  function RunningUnderWine: Boolean;
  {$IFDEF MSWINDOWS}
  var Module: HMODULE;
  begin
    Module := GetModuleHandle('ntdll.dll');
    Result := (Module <> 0)
      and (GetProcAddress(Module, 'wine_get_version') <> nil);
  end;
  {$ELSE}
  begin
    Result := False;
  end;
  {$ENDIF}

  procedure Check(const ANames: array of UnicodeString; const AContains: string);
  var k: Integer; UTF8: RawByteString;
  begin
    ResetScratch;
    try
      if RunningUnderWine then
      begin
        for k := 0 to High(ANames) do
          Expect<Boolean>(StrictUTF16ToUTF8(ANames[k], UTF8)).ToBe(False);
        Exit;
      end;
      for k := 0 to High(ANames) do
        WriteNamedFixture(FScratch, ANames[k], StringAsBytes('x'));
      ExpectDigestFailure(AContains);
    finally
      RemoveNamedFixtures(FScratch);
    end;
  end;

begin
  Check([Utf16([Ord('a'), $D800, Ord('.'), Ord('p')])], 'a\ud800.p');
  Check([Utf16([Ord('a'), $DC00, Ord('.'), Ord('p')])], 'a\udc00.p');
  Check([Utf16([Ord('a'), $DC00, $D800, Ord('.'), Ord('p')])],
    'a\udc00\ud800.p');
  { Two names that U+FFFD replacement would merge never yield a digest. }
  Check([Utf16([Ord('m'), $D800]), Utf16([Ord('m'), $DC00])], 'm\ud');
end;

{$IFDEF UNIX}
procedure TTreeDigestV2.TestCopyDirTreeLinkParity;
var Source, Copied: string;
begin
  { A file link is read through and a directory link is omitted, exactly as
    CopyDirTree copies them, so rollback retention validates. }
  ResetScratch;
  Source := FScratch + '/src';
  Copied := FScratch + '/copy';
  WriteFixtureBytes(Source + '/real.pas', StringAsBytes('unit real;'#10));
  WriteFixtureBytes(Source + '/dir/inner.pas', StringAsBytes('unit inner;'#10));
  if FpSymlink('real.pas', PAnsiChar(Source + '/link.pas')) <> 0 then
    raise Exception.Create('fixture: file link failed');
  if FpSymlink('dir', PAnsiChar(Source + '/dirlink')) <> 0 then
    raise Exception.Create('fixture: directory link failed');
  ForceDirectories(Copied);
  CopyDirTree(Source, Copied);
  Expect<string>(HashTree(Copied)).ToBe(HashTree(Source));
  Expect<Boolean>(FileExists(Copied + '/link.pas')).ToBe(True);
  Expect<Boolean>(DirectoryExists(Copied + '/dirlink')).ToBe(False);
end;

procedure TTreeDigestV2.TestFindTreeLinkNamesEveryLinkKind;
begin
  ResetScratch;
  Put('source/a.pas', 'unit a;'#10);
  Expect<string>(FindTreeLink(FScratch)).ToBe('');
  if FpSymlink('a.pas', PAnsiChar(FScratch + '/source/f.pas')) <> 0 then
    raise Exception.Create('fixture: file link failed');
  Expect<string>(FindTreeLink(FScratch)).ToBe('source/f.pas');
  ResetScratch;
  Put('source/a.pas', 'unit a;'#10);
  if FpSymlink('source', PAnsiChar(FScratch + '/d')) <> 0 then
    raise Exception.Create('fixture: directory link failed');
  Expect<string>(FindTreeLink(FScratch)).ToBe('d');
  ResetScratch;
  Put('source/a.pas', 'unit a;'#10);
  if FpSymlink('missing', PAnsiChar(FScratch + '/source/gone')) <> 0 then
    raise Exception.Create('fixture: dangling link failed');
  Expect<string>(FindTreeLink(FScratch)).ToBe('source/gone');
end;
{$ELSE}
procedure TTreeDigestV2.TestCopyDirTreeLinkParity;
begin
end;

procedure TTreeDigestV2.TestFindTreeLinkNamesEveryLinkKind;
begin
end;
{$ENDIF}

procedure TTreeDigestV2.TestMissingDirectoryFails;
var Raised: Boolean;
begin
  Raised := False;
  try
    HashTree(FScratch + PathDelim + 'absent');
  except
    on E: EVerifyError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TTreeDigestV2.TestIsTreeDigest;
begin
  Expect<Boolean>(IsTreeDigest(TREE_DIGEST_PREFIX + StringOfChar('a', 64)))
    .ToBe(True);
  Expect<Boolean>(IsTreeDigest('sha256:' + StringOfChar('a', 64))).ToBe(False);
  Expect<Boolean>(IsTreeDigest(TREE_DIGEST_PREFIX + StringOfChar('A', 64)))
    .ToBe(False);
  Expect<Boolean>(IsTreeDigest(TREE_DIGEST_PREFIX + StringOfChar('a', 63)))
    .ToBe(False);
  Expect<Boolean>(IsTreeDigest('sha256:(unfetched)')).ToBe(False);
end;

procedure TTreeDigestV2.TestRetentionRecordsTree2Snapshot;
var Live, Backup: string; Meta: TStringList;
begin
  ResetScratch;
  Live := FScratch + PathDelim + 'module';
  WriteFixtureBytes(Live + PathDelim + 'a.pas', StringAsBytes('unit a;'#10));
  Expect<Boolean>(AtomicRetainPath(Live, FScratch, 'm', Backup)).ToBe(True);
  Meta := TStringList.Create;
  try
    Meta.LoadFromFile(Backup + '.rollback');
    Expect<string>(Meta[1]).ToBe('tree:' + HashTree(Live));
  finally
    Meta.Free;
  end;
  AtomicDiscardRetainedPath(Backup);
end;

procedure TTreeDigestV2.TestLegacySidecarIsRecovered;
var Live, Backup: string; Meta: TStringList;
begin
  { A rollback file that a pre-v4 binary wrote records the legacy digest;
    recovery still validates and restores it. }
  ResetScratch;
  Live := FScratch + PathDelim + 'module';
  Backup := FScratch + PathDelim + 'rollback-module';
  WriteFixtureBytes(Backup + PathDelim + 'a.pas', StringAsBytes('unit a;'#10));
  WriteFixtureBytes(Live + PathDelim + 'a.pas', StringAsBytes('changed'#10));
  Meta := TStringList.Create;
  try
    Meta.Add(Live);
    Meta.Add('tree:' + LegacyHashTree(Backup));
    Meta.SaveToFile(Backup + '.rollback');
  finally
    Meta.Free;
  end;
  Expect<Boolean>(AtomicRestorePath(Backup, Live)).ToBe(True);
  Expect<string>(BytesToHex(ReadFixtureText(Live + PathDelim + 'a.pas')))
    .ToBe(BytesToHex('unit a;'#10));
  { A legacy sidecar that does not match its copy is refused. }
  WriteFixtureBytes(Backup + PathDelim + 'a.pas', StringAsBytes('unit b;'#10));
  Meta := TStringList.Create;
  try
    Meta.Add(Live);
    Meta.Add('tree:sha256:' + StringOfChar('0', 64));
    Meta.SaveToFile(Backup + '.rollback');
  finally
    Meta.Free;
  end;
  Expect<Boolean>(AtomicRestorePath(Backup, Live)).ToBe(False);
end;

procedure TTreeDigestV2.SetupTests;
begin
  Test('ADR-0052 vector: empty directory', TestEmptyDirectoryVector);
  Test('ADR-0052 vector: nested tree', TestNestedVector);
  Test('ADR-0052 vector: fold order', TestFoldOrderVector);
  Test('ADR-0052 vector: the #352 substitution changes only tree2',
    TestIssue352Vectors);
  Test('ADR-0052 vectors: CRLF, LF, binary, lone CR, and empty content',
    TestContentVectors);
  Test('ADR-0052 vectors: non-ASCII and supplementary-plane names',
    TestNonAsciiVectors);
  {$IFDEF LINUX}
  Test('ADR-0052 vector: case collision in either creation order',
    TestCaseCollisionVector);
  {$ELSE}
  Skip('ADR-0052 vector: case collision in either creation order',
    TestCaseCollisionVector,
    'the default filesystem cannot hold names differing only in case');
  {$ENDIF}
  Test('the comparator orders a case collision A.pas first in either order',
    TestComparatorTiebreak);
  Test('one record is magic, type, length, path, size, and digest',
    TestRecordEncoding);
  Test('streamed per-file digests equal the buffered definition',
    TestStreamingEqualsBuffered);
  Test('hashing a 64 MiB file raises peak heap use by less than 1 MiB',
    TestTreeIsNotBuffered);
  Test('strict UTF-16 conversion rejects unpaired surrogates',
    TestStrictUTF16Conversion);
  Test('tree paths must be well-formed UTF-8', TestWellFormedPaths);
  {$IFDEF LINUX}
  Test('a name that is not UTF-8 fails the digest and is named',
    TestMalformedPosixNameFails);
  {$ELSE}
  Skip('a name that is not UTF-8 fails the digest and is named',
    TestMalformedPosixNameFails,
    'only Linux filesystems store arbitrary name bytes');
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Test('names with lone or reversed surrogates fail the digest',
    TestMalformedWindowsNamesFail);
  {$ELSE}
  Skip('names with lone or reversed surrogates fail the digest',
    TestMalformedWindowsNamesFail, 'UTF-16 names exist only on Windows');
  {$ENDIF}
  {$IFDEF UNIX}
  Test('a CopyDirTree copy with file and directory links hashes alike',
    TestCopyDirTreeLinkParity);
  Test('FindTreeLink names file, directory, and dangling links',
    TestFindTreeLinkNamesEveryLinkKind);
  {$ELSE}
  Skip('a CopyDirTree copy with file and directory links hashes alike',
    TestCopyDirTreeLinkParity, 'link fixtures need FpSymlink');
  Skip('FindTreeLink names file, directory, and dangling links',
    TestFindTreeLinkNamesEveryLinkKind, 'link fixtures need FpSymlink');
  {$ENDIF}
  Test('a missing directory fails the digest', TestMissingDirectoryFails);
  Test('IsTreeDigest accepts only the canonical tree2 form', TestIsTreeDigest);
  Test('rollback retention records a tree2 snapshot',
    TestRetentionRecordsTree2Snapshot);
  Test('a legacy tree sidecar from a pre-v4 binary is still recovered',
    TestLegacySidecarIsRecovered);
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
  Expect<Integer>(Length(Man.BuildEntries)).ToBe(0);
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

procedure TLoadManifestHappy.TestBuildEntriesTable;
const
  INPUT =
    '[package]'#10 +
    'name = "with-build-items"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'cli = { source = "src/cli.pas", output = "bin/cli" }'#10 +
    'tool = { source = "src/tool.pas", depends = ["cli"], '
    + 'flags = ["-dTOOL", "-k-ld_classic"] }'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('build-items', INPUT));
  Expect<Integer>(Length(Man.BuildEntries)).ToBe(2);
  Expect<string>(Man.BuildEntries[0].Name).ToBe('cli');
  Expect<string>(Man.BuildEntries[0].Source).ToBe('src/cli.pas');
  Expect<string>(Man.BuildEntries[0].Output).ToBe('bin/cli');
  Expect<string>(Man.BuildEntries[1].Name).ToBe('tool');
  Expect<string>(Man.BuildEntries[1].Source).ToBe('src/tool.pas');
  Expect<string>(Man.BuildEntries[1].Output).ToBe('');
  Expect<Integer>(Length(Man.BuildEntries[1].Depends)).ToBe(1);
  Expect<string>(Man.BuildEntries[1].Depends[0]).ToBe('cli');
  Expect<Integer>(Length(Man.BuildEntries[1].Flags)).ToBe(2);
  Expect<string>(Man.BuildEntries[1].Flags[0]).ToBe('-dTOOL');
  Expect<string>(Man.BuildEntries[1].Flags[1]).ToBe('-k-ld_classic');
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

procedure TLoadManifestHappy.TestManifestSnapshotBindsParsedBytes;
const
  INPUT =
    '[package]'#10 +
    'name = "snapshot"'#10 +
    'version = "1.2.3"'#10;
var
  ContentHash, Path: string;
  Man: TManifest;
begin
  Path := WriteManifest('snapshot', INPUT);
  Man := LoadManifestSnapshot(Path, ContentHash);

  Expect<string>(ContentHash).ToBe(SHA256File(Path));
  Expect<string>(Man.Name).ToBe('snapshot');
  Expect<string>(Man.Version).ToBe('1.2.3');
end;

procedure TLoadManifestHappy.TestRootCompilerProfilesParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "compiler-profiles"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[compiler]'#10 +
    'default = "native"'#10 +
    ''#10 +
    '[compiler.profiles.native]'#10 +
    'driver = "fpc"'#10 +
    'command = "custom-fpc"'#10 +
    'args = ["--wrapped", "", "fpc"]'#10 +
    'version = "^3.2.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'source = "source/app.pas"'#10 +
    'compiler = "native"'#10;
var
  Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('compiler-profiles', INPUT));
  Expect<string>(Man.CompilerDefault).ToBe('native');
  Expect<Integer>(Length(Man.CompilerProfiles)).ToBe(1);
  Expect<string>(Man.CompilerProfiles[0].Driver).ToBe('fpc');
  Expect<string>(Man.CompilerProfiles[0].Runnable.Command).ToBe('custom-fpc');
  Expect<Integer>(Length(Man.CompilerProfiles[0].Runnable.Args)).ToBe(3);
  Expect<string>(Man.CompilerProfiles[0].Runnable.Args[0]).ToBe('--wrapped');
  Expect<string>(Man.CompilerProfiles[0].Runnable.Args[1]).ToBe('');
  Expect<string>(Man.CompilerProfiles[0].VersionConstraint).ToBe('^3.2.0');
  Expect<string>(Man.BuildEntries[0].CompilerProfile).ToBe('native');
end;

procedure TLoadManifestHappy.TestBuildTargetTupleParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "targeted"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[build.server]'#10 +
    'source = "source/server.pas"'#10 +
    'target = { os = "linux", architecture = "aarch64", abi = "gnu", environment = "container" }'#10;
var
  Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('target-tuple', INPUT));
  Expect<Boolean>(Man.BuildEntries[0].HasTarget).ToBe(True);
  Expect<string>(Man.BuildEntries[0].Target.OS).ToBe('linux');
  Expect<string>(Man.BuildEntries[0].Target.Architecture).ToBe('aarch64');
  Expect<string>(Man.BuildEntries[0].Target.ABI).ToBe('gnu');
  Expect<string>(Man.BuildEntries[0].Target.Environment).ToBe('container');
end;

procedure TLoadManifestHappy.TestDependencyCompilerPolicyIgnored;
const
  INPUT =
    '[package]'#10 +
    'name = "dependency-compiler"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[compiler]'#10 +
    'default = "foreign"'#10 +
    ''#10 +
    '[compiler.profiles.foreign]'#10 +
    'driver = "foreign"'#10 +
    'command = "foreign-driver"'#10 +
    ''#10 +
    '[build]'#10 +
    'source = "source/app.pas"'#10 +
    'compiler = "foreign"'#10;
var
  Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('dependency-compiler', INPUT), False);
  Expect<string>(Man.CompilerDefault).ToBe('');
  Expect<Integer>(Length(Man.CompilerProfiles)).ToBe(0);
  Expect<string>(Man.BuildEntries[0].CompilerProfile).ToBe('');
end;

procedure TLoadManifestHappy.SetupTests;
begin
  Test('minimal manifest: name + version',  TestMinimalManifestNameAndVersion);
  Test('[package] units array parsed',      TestPackageUnitsArrayParsed);
  Test('[build] table with output + bare-source entries', TestBuildEntriesTable);
  Test('[version] section parsed',          TestVersionSection);
  Test('manifest snapshot hashes the bytes it parses',
    TestManifestSnapshotBindsParsedBytes);
  Test('root compiler profiles and build selection are parsed',
    TestRootCompilerProfilesParsed);
  Test('build entries parse an independent complete target tuple',
    TestBuildTargetTupleParsed);
  Test('dependency compiler policy is ignored',
    TestDependencyCompilerPolicyIgnored);
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

procedure TLoadManifestValidation.TestBuildEntryTraversalNameRootOnly;
const
  INPUT =
    '[package]'#10 +
    'name = "traversal"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    '".." = { source = "src/x.pas" }'#10;
var
  Path : string;
  Man  : TManifest;
begin
  { Root manifest: ".." would make build/entries/.. resolve to build/
    itself — rejected at load. }
  Path := WriteManifest('traversal-build-name', INPUT);
  ExpectManifestLoadError(Path, 'invalid [build] entry name', Self);

  { Dependency manifest (AIsRoot=False): its build entries are never built
    by the consumer (parse-and-drop posture, ADR-0011) — a broken or
    hostile dep manifest must not block `lwpt install`. }
  Man := LoadManifest(Path, False);
  Expect<Integer>(Length(Man.BuildEntries)).ToBe(1);
end;

procedure TLoadManifestValidation.TestBuildDependsMustBeStringArray;
const
  SINGLE_ENTRY =
    '[package]'#10 +
    'name = "single"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'source = "src/single.pas"'#10 +
    'depends = "base"'#10;
  NAMED_ENTRY =
    '[package]'#10 +
    'name = "named"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'app = { source = "src/app.pas", depends = ["base", 1] }'#10;
begin
  ExpectManifestLoadError(
    WriteManifest('single-build-depends', SINGLE_ENTRY),
    'build.depends must be an array of strings', Self);
  ExpectManifestLoadError(
    WriteManifest('named-build-depends', NAMED_ENTRY),
    'build.app.depends[1] must be a string', Self);
end;

procedure TLoadManifestValidation.
  TestBuildFlagsMustBeStringArrayAndAreRootOnly;
const
  SCALAR_FLAGS =
    '[package]'#10 +
    'name = "scalar-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'source = "src/app.pas"'#10 +
    'flags = "-dAPP"'#10;
  MIXED_FLAGS =
    '[package]'#10 +
    'name = "mixed-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'app = { source = "src/app.pas", flags = ["-dAPP", 1] }'#10;
  EMPTY_FLAGS =
    '[package]'#10 +
    'name = "empty-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'app = { source = "src/app.pas", flags = [""] }'#10;
var
  Man: TManifest;
  Path: string;
begin
  ExpectManifestLoadError(
    WriteManifest('scalar-build-flags', SCALAR_FLAGS),
    'build.flags must be an array of strings', Self);
  Path := WriteManifest('mixed-build-flags', MIXED_FLAGS);
  ExpectManifestLoadError(Path,
    'build.app.flags[1] must be a string', Self);
  ExpectManifestLoadError(
    WriteManifest('empty-build-flags', EMPTY_FLAGS),
    'build.app.flags[0] must not be empty', Self);

  { Dependency build entries never execute in the consuming project.
    Their flag values are therefore dropped without validation so a
    dependency cannot widen the root project's compiler argument surface. }
  Man := LoadManifest(Path, False);
  Expect<Integer>(Length(Man.BuildEntries)).ToBe(1);
  Expect<Integer>(Length(Man.BuildEntries[0].Flags)).ToBe(0);
end;

procedure TLoadManifestValidation.
  TestTestFlagsMustBeStringArrayAndAreRootOnly;
const
  VALID_FLAGS =
    '[package]'#10 +
    'name = "valid-test-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[test]'#10 +
    'flags = ["-dFIRST", "-k-ld_classic", "-dFIRST"]'#10;
  SCALAR_FLAGS =
    '[package]'#10 +
    'name = "scalar-test-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[test]'#10 +
    'flags = "-dAPP"'#10;
  MIXED_FLAGS =
    '[package]'#10 +
    'name = "mixed-test-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[test]'#10 +
    'flags = ["-dAPP", 1]'#10;
  EMPTY_FLAGS =
    '[package]'#10 +
    'name = "empty-test-flags"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[test]'#10 +
    'flags = [""]'#10;
var
  Man: TManifest;
  Path: string;
begin
  Man := LoadManifest(WriteManifest('valid-test-flags', VALID_FLAGS));
  Expect<Integer>(Length(Man.TestFlags)).ToBe(3);
  Expect<string>(Man.TestFlags[0]).ToBe('-dFIRST');
  Expect<string>(Man.TestFlags[1]).ToBe('-k-ld_classic');
  Expect<string>(Man.TestFlags[2]).ToBe('-dFIRST');

  ExpectManifestLoadError(
    WriteManifest('scalar-test-flags', SCALAR_FLAGS),
    'test.flags must be an array of strings', Self);
  Path := WriteManifest('mixed-test-flags', MIXED_FLAGS);
  ExpectManifestLoadError(Path, 'test.flags[1] must be a string', Self);
  ExpectManifestLoadError(
    WriteManifest('empty-test-flags', EMPTY_FLAGS),
    'test.flags[0] must not be empty', Self);

  { A dependency never compiles tests in the consuming project. Its test
    flags are therefore dropped without validation, matching build flags. }
  Man := LoadManifest(Path, False);
  Expect<Integer>(Length(Man.TestFlags)).ToBe(0);
end;

procedure TLoadManifestValidation.TestUndeclaredCompilerProfilesAreRejected;
const
  UNKNOWN_DEFAULT =
    '[package]'#10 +
    'name = "unknown-default"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[compiler]'#10 +
    'default = "typo"'#10;
  UNKNOWN_ENTRY =
    '[package]'#10 +
    'name = "unknown-entry"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[compiler.profiles.native]'#10 +
    'driver = "fpc"'#10 +
    ''#10 +
    '[build]'#10 +
    'app = { source = "source/app.pas", compiler = "typo" }'#10;
  DUPLICATE_CASE =
    '[package]'#10 +
    'name = "duplicate-profile-case"'#10 +
    'version = "1.0.0"'#10 +
    ''#10 +
    '[compiler.profiles.Native]'#10 +
    'driver = "fpc"'#10 +
    ''#10 +
    '[compiler.profiles.native]'#10 +
    'driver = "fpc"'#10;
begin
  ExpectManifestLoadError(
    WriteManifest('unknown-compiler-default', UNKNOWN_DEFAULT),
    '[compiler] default names undeclared compiler profile "typo"', Self);
  ExpectManifestLoadError(
    WriteManifest('unknown-entry-compiler', UNKNOWN_ENTRY),
    'build.app.compiler names undeclared compiler profile "typo"', Self);
  ExpectManifestLoadError(
    WriteManifest('duplicate-compiler-profile-case', DUPLICATE_CASE),
    '[compiler.profiles] duplicate profile name "native" '
      + '(profile names are case-insensitive)', Self);
end;

procedure TLoadManifestValidation.TestArrayCannotBecomeTablePath;
const
  REGULAR_TABLE =
    'a = [1]'#10 +
    '[a.b]'#10;
  ARRAY_OF_TABLES =
    'a = [1]'#10 +
    '[[a.b]]'#10;
var
  Parser: TTOMLParser;
  Raised: Boolean;
  Root: TTOMLNode;
begin
  Parser := TTOMLParser.Create;
  try
    Root := nil;
    Raised := False;
    try
      Root := Parser.ParseDocument(REGULAR_TABLE);
    except
      on E: ETOMLParseError do
      begin
        Raised := Pos('after assigning it a value', E.Message) > 0;
        if not Raised then
          Fail('regular table error did not identify the assigned value');
      end;
    end;
    Root.Free;
    Expect<Boolean>(Raised).ToBe(True);

    Root := nil;
    Raised := False;
    try
      Root := Parser.ParseDocument(ARRAY_OF_TABLES);
    except
      on E: ETOMLParseError do
      begin
        Raised := Pos('after assigning it a value', E.Message) > 0;
        if not Raised then
          Fail('array-of-tables error did not identify the assigned value');
      end;
    end;
    Root.Free;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Parser.Free;
  end;
end;

procedure TLoadManifestValidation.TestLegacyRunnableFieldsAreRejected;
const
  LEGACY_HOOK =
    '[package]'#10 + 'name = "legacy-hook"'#10 + 'version = "1.0.0"'#10 +
    '[prebuild]'#10 + 'old = { script = "scripts/old.pas" }'#10;
  LEGACY_RUN =
    '[package]'#10 + 'name = "legacy-run"'#10 + 'version = "1.0.0"'#10 +
    '[deploy]'#10 + 'script = "scripts/deploy.pas"'#10;
  LEGACY_COMPILER =
    '[package]'#10 + 'name = "legacy-compiler"'#10 + 'version = "1.0.0"'#10 +
    '[compiler.profiles.old]'#10 + 'driver = "fpc"'#10 +
    'executable = "fpc"'#10;
begin
  ExpectManifestLoadError(WriteManifest('legacy-hook', LEGACY_HOOK),
    'use "command" and explicit "args"', Self);
  ExpectManifestLoadError(WriteManifest('legacy-run', LEGACY_RUN),
    'use "command" and explicit "args"', Self);
  ExpectManifestLoadError(WriteManifest('legacy-compiler', LEGACY_COMPILER),
    'use command and args', Self);
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
  Test('traversal [build] name rejected for root, tolerated for deps',
    TestBuildEntryTraversalNameRootOnly);
  Test('[build] depends requires only string array values',
    TestBuildDependsMustBeStringArray);
  Test('[build] flags are strict root-owned string arrays',
    TestBuildFlagsMustBeStringArrayAndAreRootOnly);
  Test('[test] flags are strict root-owned string arrays',
    TestTestFlagsMustBeStringArrayAndAreRootOnly);
  Test('compiler defaults and build entries name declared profiles',
    TestUndeclaredCompilerProfilesAreRejected);
  Test('value arrays cannot become table paths',
    TestArrayCannotBecomeTablePath);
  Test('legacy runnable fields hard-error with migration guidance',
    TestLegacyRunnableFieldsAreRejected);
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
    'sessions-dir = "/tmp/lwpt-sessions"'#10 +
    'cfg-file = "fpc.cfg"'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('lwpt-overrides', INPUT));
  Expect<string>(Man.ModulesDirOverride).ToBe('vendor/modules');
  Expect<string>(Man.ArchivesDirOverride).ToBe('vendor/archives');
  Expect<string>(Man.TmpDirOverride).ToBe('.cache/lwpt-tmp');
  Expect<string>(Man.SessionsDirOverride).ToBe('/tmp/lwpt-sessions');
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
    'embed = { command = "instantfpc", args = ["scripts/stamp-version.pas"], inputs = ["src/Source.pas"], output = "src/Embedded.inc" }'#10 +
    'codegen = { command = "tools/codegen", args = ["--flag", "v"], inputs = ["a.pas", "b.pas"], output = "src/Other.inc" }'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('prebuild', INPUT));
  Expect<Integer>(Length(Man.PreBuild)).ToBe(2);

  { Insertion order preserved via OrderedStringMap (ADR-0011). }
  Expect<string>(Man.PreBuild[0].Name).ToBe('embed');
  Expect<string>(Man.PreBuild[0].Runnable.Command).ToBe('instantfpc');
  Expect<Integer>(Length(Man.PreBuild[0].Inputs)).ToBe(1);
  Expect<string>(Man.PreBuild[0].Inputs[0]).ToBe('src/Source.pas');
  Expect<string>(Man.PreBuild[0].Output).ToBe('src/Embedded.inc');

  Expect<string>(Man.PreBuild[1].Name).ToBe('codegen');
  Expect<string>(Man.PreBuild[1].Runnable.Command).ToBe('tools/codegen');
  Expect<Integer>(Length(Man.PreBuild[1].Runnable.Args)).ToBe(2);
  Expect<string>(Man.PreBuild[1].Runnable.Args[0]).ToBe('--flag');
  Expect<string>(Man.PreBuild[1].Runnable.Args[1]).ToBe('v');
  Expect<Integer>(Length(Man.PreBuild[1].Inputs)).ToBe(2);
end;

procedure TLoadManifestExtensions.TestHookShorthandStringForm;
const
  { Bare-string shorthand: equivalent to { command = "..." } per
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
  Expect<string>(Man.PostInstall[0].Runnable.Command).ToBe('scripts/notify.pas');
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
    'half = { command = "tools/x", inputs = ["a.pas"] }'#10;
begin
  ExpectManifestLoadError(
    WriteManifest('hook-half-pair', INPUT),
    'paired option',
    Self);
end;

procedure TLoadManifestExtensions.TestHookArraysAreStrict;
const
  BAD_ARGS =
    '[package]'#10 + 'name = "bad-args"'#10 + 'version = "1.0.0"'#10 +
    '[prebuild]'#10 + 'bad = { command = "tool", args = "--bad" }'#10;
  BAD_INPUTS =
    '[package]'#10 + 'name = "bad-inputs"'#10 + 'version = "1.0.0"'#10 +
    '[prebuild]'#10 +
    'bad = { command = "tool", inputs = "source.pas", output = "out" }'#10;
begin
  ExpectManifestLoadError(WriteManifest('hook-bad-args', BAD_ARGS),
    'args must be an array of strings', Self);
  ExpectManifestLoadError(WriteManifest('hook-bad-inputs', BAD_INPUTS),
    'inputs must be an array of strings', Self);
end;

procedure TLoadManifestExtensions.TestPerEntryHooksParsed;
const
  INPUT =
    '[package]'#10 +
    'name = "per-item-hooks"'#10 +
    'version = "0.1.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'cli = { source = "src/cli.pas", output = "build/cli",'#10 +
    '        prebuild  = { stamp = "scripts/stamp.pas" },'#10 +
    '        postbuild = { sign = { command = "tools/sign", args = ["{item.output}"] } } }'#10;
var Man: TManifest;
begin
  Man := LoadManifest(WriteManifest('per-item-hooks', INPUT));
  Expect<Integer>(Length(Man.BuildEntries)).ToBe(1);
  Expect<Integer>(Length(Man.BuildEntries[0].PreBuild)).ToBe(1);
  Expect<string>(Man.BuildEntries[0].PreBuild[0].Name).ToBe('stamp');
  Expect<string>(Man.BuildEntries[0].PreBuild[0].Runnable.Command).ToBe('scripts/stamp.pas');
  Expect<Integer>(Length(Man.BuildEntries[0].PostBuild)).ToBe(1);
  Expect<string>(Man.BuildEntries[0].PostBuild[0].Name).ToBe('sign');
  Expect<string>(Man.BuildEntries[0].PostBuild[0].Runnable.Command).ToBe('tools/sign');
  Expect<Integer>(Length(Man.BuildEntries[0].PostBuild[0].Runnable.Args)).ToBe(1);
  { {item.output} interpolates to the resolved output value. }
  Expect<string>(Man.BuildEntries[0].PostBuild[0].Runnable.Args[0]).ToBe('build/cli');
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
  Test('hook bare-string shorthand expands to { command = "..." }',
    TestHookShorthandStringForm);
  Test('hook inputs/output is a paired option (half-pair rejected)',
    TestHookPairedInputsOutputRequired);
  Test('hook arguments and staleness inputs are strict arrays',
    TestHookArraysAreStrict);
  Test('[build].<entry>.prebuild / postbuild parsed + {item.output} expanded',
    TestPerEntryHooksParsed);
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

const
  V3_LOCK = 'version = 3'#10 + ''#10 + '[package.alpha]'#10
    + 'source = "owner/alpha"'#10 + 'resolvedRef = "v1.2.3"'#10
    + 'computedHash = "sha256:aaa"'#10 + 'archiveHash = "sha256:bbb"'#10;

procedure TLockfileLoading.TestSchemaV3RaisesWithRepairHint;
var Raised: Boolean;
begin
  { One message, naming repair and the delete-and-install alternative with
    its consequences (ADR-0052 section 5). }
  Expect<string>(LockfileSchemaV3Message).ToBe('`' + LOCKFILE
    + '` is schema v3, whose tree hash cannot detect a rearranged module '
    + 'tree (ADR-0052). Run `' + PROGRAM_NAME + ' repair` to upgrade it to '
    + 'v4 without network access and without changing dependency versions, '
    + 'then commit `' + LOCKFILE + '`. Deleting `' + LOCKFILE
    + '` and running `' + PROGRAM_NAME + ' install` also works, but needs '
    + 'network access and moves range dependencies to their newest matching '
    + 'versions.');
  ExpectLockfileLoadError(WriteLockfileContent('schema-v3', V3_LOCK),
    LockfileSchemaV3Message, Self);
  Raised := False;
  try
    RequireCurrentLockfileSchema(WriteLockfileContent('schema-v3-gate',
      V3_LOCK));
  except
    on E: ELockfileError do
      Raised := E.Message = LockfileSchemaV3Message;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLockfileLoading.TestSchemaV3LoadsOnlyForTheUpgrade;
var Entries: TResolvedArray;
begin
  Entries := LoadLockfile(WriteLockfileContent('schema-v3-upgrade', V3_LOCK),
    True);
  Expect<Integer>(Length(Entries)).ToBe(1);
  Expect<string>(Entries[0].Hash).ToBe('sha256:aaa');
  Expect<Integer>(ReadLockfileSchemaVersion(
    WriteLockfileContent('schema-v3-version', V3_LOCK))).ToBe(3);
  Expect<Integer>(ReadLockfileSchemaVersion(LOCK_TMP_DIR + '/absent.lock'))
    .ToBe(0);
  Expect<Integer>(ReadLockfileSchemaVersion(WriteLockfileContent(
    'schema-corrupt', 'this is { not'#10))).ToBe(-1);
end;

procedure TLockfileLoading.TestNewerSchemaNamesTheReader;
begin
  ExpectLockfileLoadError(WriteLockfileContent('schema-v5', 'version = 5'#10),
    'schema v5; this ' + PROGRAM_NAME + ' reads up to v4', Self);
end;

procedure TLockfileLoading.TestLegacyDigestInV4Fails;
begin
  { A v4 lock never holds a legacy digest; the entry is named. }
  ExpectLockfileLoadError(WriteLockfileContent('v4-legacy-digest',
    'version = 4'#10 + ''#10 + '[package.good]'#10
    + 'source = "owner/good"'#10 + 'computedHash = "sha256-tree2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'#10
    + ''#10 + '[package.forged]'#10 + 'source = "owner/forged"'#10
    + 'computedHash = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'#10),
    'entry "forged" has computedHash', Self);
end;

procedure TLockfileLoading.TestRegistryTablesShareTheGate;
var Raised: Boolean; Path: string;
begin
  Path := WriteLockfileContent('registry-v3', V3_LOCK);
  Raised := False;
  try
    LoadRegistryLockTables(Path);
  except
    on E: ELockfileError do
      Raised := E.Message = LockfileSchemaV3Message;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Integer>(Length(LoadRegistryLockTables(Path, True))).ToBe(0);
end;

procedure TLockfileLoading.TestEmptyPackageTableReturnsEmptyArray;
var Entries: TResolvedArray;
begin
  Entries := LoadLockfile(
    WriteLockfileContent('empty',
      'version = 4'#10));
  Expect<Integer>(Length(Entries)).ToBe(0);
end;

procedure TLockfileLoading.TestPackageEntriesRoundTripFields;
var Entries: TResolvedArray;
begin
  Entries := LoadLockfile(
    WriteLockfileContent('three-pkgs',
      'version = 4'#10 +
      ''#10 +
      '[package.alpha]'#10 +
      'source = "owner/alpha"'#10 +
      'resolvedRef = "v1.2.3"'#10 +
      'resolvedURL = "https://github.com/owner/alpha/archive/v1.2.3.tar.gz"'#10 +
      'computedHash = "sha256-tree2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'#10 +
      'archiveHash = "sha256:bbb"'#10 +
      ''#10 +
      '[package.beta]'#10 +
      'source = "../local-beta"'#10 +
      'resolvedRef = ""'#10 +
      'resolvedURL = ""'#10 +
      'computedHash = "sha256-tree2:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'#10 +
      'archiveHash = ""'#10));
  Expect<Integer>(Length(Entries)).ToBe(2);
  Expect<string>(Entries[0].Name).ToBe('alpha');
  Expect<string>(Entries[0].Version).ToBe('v1.2.3');
  Expect<string>(Entries[0].SrcOriginal).ToBe('owner/alpha');
  Expect<string>(Entries[0].SrcLocator).ToBe('owner/alpha');
  Expect<string>(Entries[0].Hash).ToBe('sha256-tree2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
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
  Test('schema v3 raises the repair hint for every reader',
    TestSchemaV3RaisesWithRepairHint);
  Test('schema v3 loads only for the repair upgrade',
    TestSchemaV3LoadsOnlyForTheUpgrade);
  Test('a newer schema names the highest version this reader reads',
    TestNewerSchemaNamesTheReader);
  Test('a legacy computedHash in a v4 lock fails and names the entry',
    TestLegacyDigestInV4Fails);
  Test('registry lock tables share the schema gate',
    TestRegistryTablesShareTheGate);
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

{ ── TConstraintFingerprintFold ────────────────────────────────── }

{ The exact list the resolver hands to the fingerprint: sorted, duplicates
  accepted, one line per accumulated requirement plus the canonical source
  identity. }
function FixedConstraintLines: TStringList;
begin
  Result := TStringList.Create;
  try
    Result.Sorted := True;
    Result.Duplicates := dupAccept;
    Result.Add('1|^1.0.0|lwpt');
    Result.Add('1|^1.2.0|widget');
    Result.Add('source|git|https://github.com/acme/widget');
  except
    Result.Free;
    raise;
  end;
end;

procedure TConstraintFingerprintFold.TestPinnedFingerprintForFixedConstraintSet;
const
  { sha256 of "1|^1.0.0|lwpt\n1|^1.2.0|widget\n"
    + "source|git|https://github.com/acme/widget\n" }
  EXPECTED = 'sha256:81583af3bb365d31608e77e1a4b034feb09fe13a4fa93ef9e3d3b5'
    + 'a8fca355c9';
var Lines: TStringList;
begin
  Lines := FixedConstraintLines;
  try
    Expect<string>(ConstraintFingerprintForLines(Lines)).ToBe(EXPECTED);
  finally
    Lines.Free;
  end;
end;

procedure TConstraintFingerprintFold.TestFoldReproducesPlatformTextOnLineFeedPlatforms;
var Lines: TStringList; CarriageReturnFold: string;
begin
  Lines := FixedConstraintLines;
  try
    { The pin's whole purpose: on an LF platform the pinned fold must be
      byte-identical to the platform TStrings.Text fold it replaced, so
      every fingerprint an LF machine ever wrote stays valid. TStrings.Text
      terminates every line — including the last — with the platform line
      ending, which is why the separator is a terminator, not a join. On
      Windows Text uses CRLF, so the equality only holds off Windows. }
    {$IFNDEF MSWINDOWS}
    Expect<string>(ConstraintFingerprintForLines(Lines)).ToBe(
      'sha256:' + SHA256Hex(BytesOf(Lines.Text)));
    {$ENDIF}
    { The separator is pinned to LF and must stay distinguishable from CRLF,
      so a platform-inherited fold cannot pass by coincidence on any host. }
    CarriageReturnFold := 'sha256:' + SHA256Hex(StringAsBytes(
      '1|^1.0.0|lwpt'#13#10'1|^1.2.0|widget'#13#10
      + 'source|git|https://github.com/acme/widget'#13#10));
    Expect<Boolean>(ConstraintFingerprintForLines(Lines) = CarriageReturnFold)
      .ToBe(False);
    Expect<string>(string(CONSTRAINT_FINGERPRINT_SEPARATOR)).ToBe(string(#10));
  finally
    Lines.Free;
  end;
end;

procedure TConstraintFingerprintFold.TestNodeFingerprintPinsOrdinalSort;
const
  { Two requirement lines identical but for a hyphen in the requirer:
    'appcore' is added FIRST, so the assertion only holds if the node fold
    reorders them by 8-bit ordinal ('app-core' wins because '-' = $2D <
    'c' = $63). A locale word-sort folds the hyphen away and would leave the
    input order, changing the digest. Folded (each line LF-terminated):
      1|^1.0.0|app-core\n1|^1.0.0|appcore\nsource|workspace|widget\n }
  EXPECTED = 'sha256:d8dd5ec45301a80b19936b1fef484def270eee9ce723692183a8b6b'
    + 'a3c3705b3';
var Node: TResolveNode;
begin
  Node := Default(TResolveNode);
  Node.Name := 'widget';
  Node.Dep.Name := 'widget';
  Node.Dep.SrcKind := skWorkspace;
  SetLength(Node.Specs, 2);
  SetLength(Node.Kinds, 2);
  SetLength(Node.Requirers, 2);
  Node.Specs[0] := '^1.0.0'; Node.Kinds[0] := vkSemverRange;
  Node.Requirers[0] := 'appcore';
  Node.Specs[1] := '^1.0.0'; Node.Kinds[1] := vkSemverRange;
  Node.Requirers[1] := 'app-core';
  Expect<string>(ConstraintFingerprintForNode(Node, '')).ToBe(EXPECTED);
end;

procedure TConstraintFingerprintFold.SetupTests;
begin
  Test('fixed constraint set folds to the pinned cross-platform digest',
    TestPinnedFingerprintForFixedConstraintSet);
  Test('fold reproduces the platform Text join on LF platforms',
    TestFoldReproducesPlatformTextOnLineFeedPlatforms);
  Test('node fold orders requirement lines by ordinal byte value',
    TestNodeFingerprintPinsOrdinalSort);
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
    '0000' +
    '0000';
begin
  { Service-announce line + its flush, then an advertisement with no refs
    and its own terminating flush. Should yield an empty array, not error
    out. (Without the second flush the advertisement is truncated.) }
  Expect<Integer>(Length(ParseInfoRefs(PAYLOAD))).ToBe(0);
end;

procedure TGitProtocolParsing.TestHeadWithCapabilitiesIsRecognised;
const
  { 4-char hex length + payload. 40-char SHA + space + "HEAD"
    + NUL + capability string (19) + LF. Total payload = 66 chars,
    +4 prefix = 70 = $0046. (The length was once 3c; the lenient parser
    stopped at the short frame and returned the same empty result, which
    hid the error. The strict parser refuses a frame that overruns.)
    HEAD is dropped by the filter, so the result is still empty. }
  PAYLOAD =
    '00460123456789012345678901234567890123456789 HEAD'#0 +
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

procedure TGitProtocolParsing.TestPeelSuffixRecordsCommitIdentity;
const
  (* Both lines refer to the same tag; the ^{} line is the peeled
     commit SHA. The parser keeps one tag and attaches the commit
     identity advertised by Git. *)
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
  Expect<string>(Refs[0].PeeledSHA)
    .ToBe('cccccccccccccccccccccccccccccccccccccccc');
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
  Test('peel-suffix lines attach the authoritative commit identity',
    TestPeelSuffixRecordsCommitIdentity);
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
  begin
    WriteFixtureFile(FScratch + '/' + ARel,
      'placeholder content for ' + ARel);
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
  begin
    WriteFixtureFile(Src + '/' + ARel, 'content of ' + ARel);
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

procedure TCopyDirTreeGuards.TestDanglingFileSymlinkSkipped;
begin
  {$IFDEF UNIX}
  ResetScratch;
  if FpSymlink('no-such-target',
       PAnsiChar(Src + '/dangling.txt')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for dangling link');
  { Must skip the unresolvable link (CollectFiles skips it too), not
    raise on the failed copy-through. }
  CopyDirTree(Src, Dst);
  Expect<Boolean>(FileExists(Dst + '/a.txt')).ToBe(True);
  Expect<Boolean>(FileExists(Dst + '/dangling.txt')).ToBe(False);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
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

procedure TCopyDirTreeGuards.TestDstInsideAliasedSrcRaises;
var Raised: Boolean;
begin
  {$IFDEF UNIX}
  ResetScratch;
  { alias -> src: the source reached through a link while the
    destination names the real tree. Lexically disjoint, physically
    dst-inside-src — the shape the PathContains check cannot see. }
  if FpSymlink('src', PAnsiChar(FScratch + '/alias')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for alias link');
  Raised := False;
  try
    CopyDirTree(FScratch + '/alias', Src + '/sub/dst');
  except
    on E: EExtractError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  { The guard fired before ForceDirectories polluted the source. }
  Expect<Boolean>(DirectoryExists(Src + '/sub/dst')).ToBe(False);
  {$ELSE}
  Raised := False;
  if not Raised then Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TCopyDirTreeGuards.TestAliasedSrcToDisjointDstCopies;
begin
  {$IFDEF UNIX}
  ResetScratch;
  { Copying FROM a symlinked root into a disjoint destination is
    legal and must keep working — the identity walk only rejects
    destinations that resolve into the source. }
  if FpSymlink('src', PAnsiChar(FScratch + '/alias')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for alias link');
  CopyDirTree(FScratch + '/alias', Dst);
  Expect<Boolean>(FileExists(Dst + '/a.txt')).ToBe(True);
  Expect<Boolean>(FileExists(Dst + '/sub/b.txt')).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TCopyDirTreeGuards.TestPathContainsBoundaries;
begin
  { The compare CopyDirTree's guard and the extractor's link-cycle
    skip both ride on: equality counts as contained, and a sibling
    sharing a name prefix does not. }
  Expect<Boolean>(PathContains(Src, Src)).ToBe(True);
  Expect<Boolean>(PathContains(Src, Src + '/sub')).ToBe(True);
  Expect<Boolean>(PathContains(Src, Src + 'ling')).ToBe(False);
  Expect<Boolean>(PathContains(Src + '/sub', Src)).ToBe(False);
end;

procedure TCopyDirTreeGuards.SetupTests;
begin
  Test('copies a nested tree (baseline)', TestCopiesNestedTree);
  Test('terminates on a directory-symlink cycle; link not copied',
    TestDirSymlinkCycleTerminatesAndIsNotCopied);
  Test('file symlink is copied through (target bytes)',
    TestFileSymlinkCopiedThrough);
  Test('dangling file symlink is skipped, not a copy failure',
    TestDanglingFileSymlinkSkipped);
  Test('destination inside source raises EExtractError',
    TestDstInsideSrcRaises);
  Test('destination equal to source raises EExtractError',
    TestDstEqualsSrcRaises);
  Test('destination inside symlink-aliased source raises (identity walk)',
    TestDstInsideAliasedSrcRaises);
  Test('symlink-aliased source root copies to a disjoint destination',
    TestAliasedSrcToDisjointDstCopies);
  Test('PathContains: equality contained, prefix-sibling not',
    TestPathContainsBoundaries);
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
begin
  {$IFDEF UNIX}
  ResetScratch;
  ForceDirectories(FScratch + '/victim');
  WriteFixtureFile(FScratch + '/outside/keep.txt',
    'must survive the wipe');
  if FpSymlink('../outside',
       PAnsiChar(FScratch + '/victim/link')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for outside link');
  WipeDir(FScratch + '/victim');
  Expect<Boolean>(DirectoryExists(FScratch + '/victim')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/outside/keep.txt')).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
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

procedure TCustomSources.TestRefPlaceholderInHostRejected;
var Man: TManifest;
begin
  ExpectManifestLoadError(WriteCustomSourceManifest('ref-in-archive-host',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "https://{ref}.downloads.example/{user}/{repository}.tar.gz", '
    + 'git = "https://git.example.com/{user}/{repository}.git"'
    + ' }'#10),
    'must not use {ref} in its host', Self);
  ExpectManifestLoadError(WriteCustomSourceManifest('ref-in-git-host',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'gitea = { '
    + 'archive = "https://git.example.com/{user}/{repository}/{ref}.tar.gz", '
    + 'git = "https://{ref}.git.example.com/{user}/{repository}.git"'
    + ' }'#10),
    'must not use {ref} in its host', Self);
  { User and repository may name the host; ref in the path stays valid. }
  Man := LoadManifest(WriteCustomSourceManifest('user-in-host',
    '[package]'#10 +
    'name = "x"'#10 +
    'version = "0"'#10 +
    ''#10 +
    '[sources]'#10 +
    'pages = { '
    + 'archive = "https://{user}.pages.example/{repository}/{ref}.tar.gz", '
    + 'git = "https://{user}.pages.example/{repository}.git"'
    + ' }'#10));
  Expect<Integer>(Length(Man.CustomSources)).ToBe(1);
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
      'version = 4'#10 +
      ''#10 +
      '[package.mylib]'#10 +
      'source = "gitea:team/mylib"'#10 +
      'resolvedRef = "v1.0.0"'#10 +
      'resolvedURL = "https://git.example.com/team/mylib/archive/v1.0.0.tar.gz"'#10 +
      'computedHash = "sha256-tree2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'#10 +
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
  Test('a ref placeholder in a template host hard-errors',
    TestRefPlaceholderInHostRejected);
  Test('[sources] entry shadowing a built-in name hard-errors',
    TestShadowingBuiltinPrefixRejected);
  Test('dep with custom prefix routes to hkCustom + correct host name',
    TestDepWithCustomPrefixRoutes);
  Test('dep with undeclared custom prefix hard-errors at LoadManifest',
    TestDepWithUndeclaredCustomPrefixRejected);
  Test('lockfile read is permissive on unknown prefixes (no manifest context)',
    TestLockfilePermissiveOnUnknownPrefix);
end;

{ ── TPruneOrphans ─────────────────────────────────────────────────── }

function TPruneOrphans.SetupPruneDirs(const ASuffix: string;
  out AModules, AArchives: string): string;
begin
  Result := TMP_DIR + '/prune-' + ASuffix;
  AModules  := Result + '/modules';
  AArchives := Result + '/archives';
  if DirectoryExists(Result) then WipeDir(Result);
  ForceDirectories(AModules);
  ForceDirectories(AArchives);
end;

function TPruneOrphans.MakeEntry(const AName: string; AKind: TSourceKind;
  const AVersion: string): TResolved;
begin
  Result := Default(TResolved);
  Result.Name    := AName;
  Result.SrcKind := AKind;
  Result.Version := AVersion;
end;

procedure TPruneOrphans.TestRemovedPackagePrunesModulesAndArchive;
var
  Modules, Archives, Archive: string;
  OldLock, NewLock: TResolvedArray;
begin
  SetupPruneDirs('removed', Modules, Archives);
  ForceDirectories(Modules + '/foo/source');
  Archive := Archives + '/foo-v1.0.0.tar.gz';
  with TStringList.Create do
  try
    Text := 'fake tarball';
    SaveToFile(Archive);
  finally
    Free;
  end;

  SetLength(OldLock, 1);
  OldLock[0] := MakeEntry('foo', skGitHost, 'v1.0.0');
  NewLock := nil;

  Expect<Integer>(
    PruneOrphanedPackages(OldLock, NewLock, Modules, Archives)).ToBe(1);
  Expect<Boolean>(DirectoryExists(Modules + '/foo')).ToBe(False);
  Expect<Boolean>(FileExists(Archive)).ToBe(False);
end;

procedure TPruneOrphans.TestKindChangeToLocalPrunesOldArchive;
var
  Modules, Archives, Archive: string;
  OldLock, NewLock: TResolvedArray;
begin
  { Re-pointing a dep from a git host to a local path: the old cached
    archive must go, the (re-materialized) modules tree must stay. }
  SetupPruneDirs('kindchange', Modules, Archives);
  ForceDirectories(Modules + '/foo');
  Archive := Archives + '/foo-v1.0.0.tar.gz';
  with TStringList.Create do
  try
    Text := 'fake tarball';
    SaveToFile(Archive);
  finally
    Free;
  end;

  SetLength(OldLock, 1);
  OldLock[0] := MakeEntry('foo', skGitHost, 'v1.0.0');
  SetLength(NewLock, 1);
  NewLock[0] := MakeEntry('foo', skLocal, '');

  Expect<Integer>(
    PruneOrphanedPackages(OldLock, NewLock, Modules, Archives)).ToBe(0);
  Expect<Boolean>(FileExists(Archive)).ToBe(False);
  Expect<Boolean>(DirectoryExists(Modules + '/foo')).ToBe(True);
end;

procedure TPruneOrphans.TestVersionBumpPrunesStaleArchive;
var
  Modules, Archives, OldArchive, NewArchive: string;
  OldLock, NewLock: TResolvedArray;
begin
  SetupPruneDirs('bump', Modules, Archives);
  OldArchive := Archives + '/foo-v1.0.0.tar.gz';
  NewArchive := Archives + '/foo-v2.0.0.tar.gz';
  with TStringList.Create do
  try
    Text := 'fake tarball';
    SaveToFile(OldArchive);
    SaveToFile(NewArchive);
  finally
    Free;
  end;

  SetLength(OldLock, 1);
  OldLock[0] := MakeEntry('foo', skGitHost, 'v1.0.0');
  SetLength(NewLock, 1);
  NewLock[0] := MakeEntry('foo', skGitHost, 'v2.0.0');

  Expect<Integer>(
    PruneOrphanedPackages(OldLock, NewLock, Modules, Archives)).ToBe(0);
  Expect<Boolean>(FileExists(OldArchive)).ToBe(False);
  Expect<Boolean>(FileExists(NewArchive)).ToBe(True);
end;

procedure TPruneOrphans.TestUnchangedEntryPrunesNothing;
var
  Modules, Archives, Archive: string;
  OldLock, NewLock: TResolvedArray;
begin
  SetupPruneDirs('unchanged', Modules, Archives);
  ForceDirectories(Modules + '/foo');
  Archive := Archives + '/foo-v1.0.0.tar.gz';
  with TStringList.Create do
  try
    Text := 'fake tarball';
    SaveToFile(Archive);
  finally
    Free;
  end;

  SetLength(OldLock, 1);
  OldLock[0] := MakeEntry('foo', skGitHost, 'v1.0.0');
  NewLock := Copy(OldLock);

  Expect<Integer>(
    PruneOrphanedPackages(OldLock, NewLock, Modules, Archives)).ToBe(0);
  Expect<Boolean>(FileExists(Archive)).ToBe(True);
  Expect<Boolean>(DirectoryExists(Modules + '/foo')).ToBe(True);
end;

procedure TPruneOrphans.TestUnsafeLockfileKeyRefusesToPrune;
var
  Modules, Archives, Marker: string;
  OldLock, NewLock: TResolvedArray;
  Raised: Boolean;
begin
  { A crafted lockfile key must never become a deletion path — the
    prune refuses the whole lockfile rather than WipeDir-ing outside
    the modules root. }
  SetupPruneDirs('unsafe', Modules, Archives);
  Marker := TMP_DIR + '/prune-unsafe-sibling';
  ForceDirectories(Marker);

  SetLength(OldLock, 1);
  OldLock[0] := MakeEntry('../prune-unsafe-sibling', skGitHost, 'v1.0.0');
  NewLock := nil;

  Raised := False;
  try
    PruneOrphanedPackages(OldLock, NewLock, Modules, Archives);
  except
    on ELockfileError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(DirectoryExists(Marker)).ToBe(True);
end;

procedure TPruneOrphans.SetupTests;
begin
  Test('a removed package loses its modules tree and archive',
    TestRemovedPackagePrunesModulesAndArchive);
  Test('a git-host → local re-point prunes the old archive',
    TestKindChangeToLocalPrunesOldArchive);
  Test('a version bump prunes the stale old archive only',
    TestVersionBumpPrunesStaleArchive);
  Test('an unchanged entry prunes nothing',
    TestUnchangedEntryPrunesNothing);
  Test('an unsafe lockfile key refuses to prune (ELockfileError)',
    TestUnsafeLockfileKeyRefusesToPrune);
end;

{ ── TSanitisePathSegmentSuite ─────────────────────────────────────── }

procedure TSanitisePathSegmentSuite.TestPlainNameUnchanged;
begin
  Expect<string>(SanitisePathSegment('alpha')).ToBe('alpha');
  Expect<string>(SanitisePathSegment('my-tool_2')).ToBe('my-tool_2');
end;

procedure TSanitisePathSegmentSuite.TestSeparatorsFlattened;
begin
  Expect<string>(SanitisePathSegment('a/b')).ToBe('a_b');
  Expect<string>(SanitisePathSegment('a\b')).ToBe('a_b');
  Expect<string>(SanitisePathSegment('C:tool')).ToBe('C_tool');
  Expect<string>(SanitisePathSegment('a/b\c:d')).ToBe('a_b_c_d');
end;

procedure TSanitisePathSegmentSuite.TestDistinctInputsCanCollide;
begin
  { Documented contract: callers keying dirs off the result must
    detect collisions themselves (CmdBuild does). }
  Expect<string>(SanitisePathSegment('a:b'))
    .ToBe(SanitisePathSegment('a_b'));
end;

procedure TSanitisePathSegmentSuite.SetupTests;
begin
  Test('plain names pass through unchanged', TestPlainNameUnchanged);
  Test('separators and colons flatten to underscores',
    TestSeparatorsFlattened);
  Test('distinct inputs can collide (callers must guard)',
    TestDistinctInputsCanCollide);
end;

{ ── TMakeTmpPathSuite ───────────────────────────────────────────── }

const
  TmpPathCallCount = 1000;
  TmpPathThreadCount = 4;
  TmpPathThreadCallCount = 250;
  EnvironmentCopyThreadCount = 8;

var
  { LongInt + Interlocked* (the codebase's cross-thread flag idiom, cf.
    TLWPTProcessTree.FImmediateTerminationRequested) so the start signal
    does not rely on unsynchronised Boolean visibility. The ready counter
    makes the barrier real: the gate opens only after every thread has
    checked in, so all copies genuinely start together. }
  EnvironmentCopyGate: LongInt = 0;
  EnvironmentCopyReady: LongInt = 0;

{ Predicts the generator's next candidate for an occupied-path test by
  advancing the trailing sequence of a previously returned path. }
function ComputeNextSequenceCandidate(const APath: string): string;
var
  Stem, Counter: string;
  Separator: Integer;
begin
  Stem := Copy(APath, 1, Length(APath) - Length(TmpPathExtension));
  Separator := LastDelimiter(TmpPathDelimiter, Stem);
  Counter := Copy(Stem, Separator + 1, MaxInt);
  Result := Copy(Stem, 1, Separator)
    + IntToStr(StrToInt64(Counter) + 1) + TmpPathExtension;
end;

constructor TMakeTmpPathThread.Create(const ARoot, AHint: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRoot := ARoot;
  FHint := AHint;
  FPaths := TStringList.Create;
end;

destructor TMakeTmpPathThread.Destroy;
begin
  FPaths.Free;
  inherited Destroy;
end;

procedure TMakeTmpPathThread.Execute;
var
  Index: Integer;
begin
  try
    for Index := 1 to TmpPathThreadCallCount do
      FPaths.Add(MakeTmpPath(FRoot, FHint));
  except
    on E: Exception do FErrorText := E.Message;
  end;
end;

procedure TMakeTmpPathSuite.ResetScratch;
begin
  WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TMakeTmpPathSuite.BeforeAll;
begin
  { Process-unique root: concurrent test binaries must not wipe each
    other's occupied-candidate fixtures. }
  FScratch := ExpandFileName('build/tests/tmp/make-tmp-path-'
    + IntToStr(GetProcessID));
  ResetScratch;
end;

procedure TMakeTmpPathSuite.AfterAll;
begin
  WipeDir(FScratch);
end;

procedure TMakeTmpPathSuite.TestManyCallsAreDistinct;
var
  Index: Integer;
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    Paths.Sorted := True;
    Paths.Duplicates := dupIgnore;
    for Index := 1 to TmpPathCallCount do
      Paths.Add(MakeTmpPath(FScratch, 'burst'));
    Expect<Integer>(Paths.Count).ToBe(TmpPathCallCount);
  finally
    Paths.Free;
  end;
end;

procedure TMakeTmpPathSuite.TestExistingCandidateIsSkipped;
var
  Candidate, ResultPath: string;
begin
  Candidate := ComputeNextSequenceCandidate(MakeTmpPath(FScratch, 'existing'));
  WriteFixtureFile(Candidate, 'occupied');

  ResultPath := MakeTmpPath(FScratch, 'existing');

  Expect<Boolean>(FileExists(Candidate)).ToBe(True);
  Expect<Boolean>(ResultPath <> Candidate).ToBe(True);
end;

procedure TMakeTmpPathSuite.TestThreadedBurstIsDistinct;
var
  AllPaths: TStringList;
  Index: Integer;
  Threads: array[0..TmpPathThreadCount - 1] of TMakeTmpPathThread;
begin
  AllPaths := TStringList.Create;
  try
    AllPaths.Sorted := True;
    AllPaths.Duplicates := dupIgnore;
    for Index := 0 to High(Threads) do
      Threads[Index] := TMakeTmpPathThread.Create(FScratch, 'threaded');
    for Index := 0 to High(Threads) do Threads[Index].Start;
    for Index := 0 to High(Threads) do Threads[Index].WaitFor;
    for Index := 0 to High(Threads) do
    begin
      Expect<string>(Threads[Index].ErrorText).ToBe('');
      AllPaths.AddStrings(Threads[Index].Paths);
    end;
    Expect<Integer>(AllPaths.Count)
      .ToBe(TmpPathThreadCount * TmpPathThreadCallCount);
  finally
    for Index := 0 to High(Threads) do Threads[Index].Free;
    AllPaths.Free;
  end;
end;

procedure TMakeTmpPathSuite.TestSiblingCallsAreDistinct;
var
  BasePath: string;
  Index: Integer;
  Paths: TStringList;
begin
  BasePath := IncludeTrailingPathDelimiter(FScratch) + 'target.txt';
  Paths := TStringList.Create;
  try
    Paths.Sorted := True;
    Paths.Duplicates := dupIgnore;
    for Index := 1 to TmpPathCallCount do
      Paths.Add(MakeSiblingTmpPath(BasePath, 'old'));
    Expect<Integer>(Paths.Count).ToBe(TmpPathCallCount);
    for Index := 0 to Paths.Count - 1 do
    begin
      Expect<string>(ExtractFileDir(Paths[Index]))
        .ToBe(ExcludeTrailingPathDelimiter(FScratch));
      Expect<Boolean>(Pos('target.txt.old.', ExtractFileName(Paths[Index])) = 1)
        .ToBe(True);
    end;
  finally
    Paths.Free;
  end;
end;

procedure TMakeTmpPathSuite.TestSiblingExistingCandidateIsSkipped;
var
  BasePath, Candidate, ResultPath: string;
begin
  BasePath := IncludeTrailingPathDelimiter(FScratch) + 'target.txt';
  Candidate := ComputeNextSequenceCandidate(MakeSiblingTmpPath(BasePath, 'old'));
  WriteFixtureFile(Candidate, 'occupied');

  ResultPath := MakeSiblingTmpPath(BasePath, 'old');

  Expect<Boolean>(FileExists(Candidate)).ToBe(True);
  Expect<Boolean>(ResultPath <> Candidate).ToBe(True);
end;

constructor TEnvironmentCopyThread.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCopy := TStringList.Create;
  FErrorText := '';
end;

destructor TEnvironmentCopyThread.Destroy;
begin
  FCopy.Free;
  inherited Destroy;
end;

procedure TEnvironmentCopyThread.Execute;
begin
  try
    { Check in, then spin until the gate opens so every thread's copy
      starts inside the same few microseconds -- the shape that raced the
      RTL's lazy env count before AppendProcessEnvironment serialised the
      sweep. }
    InterlockedIncrement(EnvironmentCopyReady);
    while InterlockedExchangeAdd(EnvironmentCopyGate, 0) = 0 do
      ThreadSwitch;
    AppendProcessEnvironment(FCopy);
  except
    on E: Exception do FErrorText := E.Message;
  end;
end;

procedure TAppendProcessEnvironmentSuite
  .TestConcurrentCopiesAreCompleteAndIdentical;
var
  Index: Integer;
  Reference: TStringList;
  Threads: array[0..EnvironmentCopyThreadCount - 1] of
    TEnvironmentCopyThread;
begin
  Reference := TStringList.Create;
  try
    InterlockedExchange(EnvironmentCopyGate, 0);
    InterlockedExchange(EnvironmentCopyReady, 0);
    for Index := 0 to High(Threads) do
      Threads[Index] := TEnvironmentCopyThread.Create;
    for Index := 0 to High(Threads) do Threads[Index].Start;
    while InterlockedExchangeAdd(EnvironmentCopyReady, 0)
      < EnvironmentCopyThreadCount do
      ThreadSwitch;
    InterlockedExchange(EnvironmentCopyGate, 1);
    for Index := 0 to High(Threads) do Threads[Index].WaitFor;

    { The reference copy is taken after the burst on purpose: every
      concurrent copy must already match the settled snapshot. }
    AppendProcessEnvironment(Reference);
    Expect<Boolean>(Reference.Count > 0).ToBe(True);
    for Index := 0 to High(Threads) do
    begin
      Expect<string>(Threads[Index].ErrorText).ToBe('');
      Expect<Integer>(Threads[Index].Copied.Count).ToBe(Reference.Count);
      Expect<Boolean>(Threads[Index].Copied.Text = Reference.Text)
        .ToBe(True);
    end;
  finally
    for Index := 0 to High(Threads) do Threads[Index].Free;
    Reference.Free;
  end;
end;

procedure TAppendProcessEnvironmentSuite.SetupTests;
begin
  Test('concurrent environment copies are complete and identical',
    TestConcurrentCopiesAreCompleteAndIdentical);
end;

procedure TMakeTmpPathSuite.SetupTests;
begin
  Test('tight loop with one root and hint returns distinct paths',
    TestManyCallsAreDistinct);
  Test('pre-existing candidate is skipped',
    TestExistingCandidateIsSkipped);
  Test('multi-threaded burst returns distinct paths',
    TestThreadedBurstIsDistinct);
  Test('sibling paths for one base path are distinct',
    TestSiblingCallsAreDistinct);
  Test('pre-existing sibling candidate is skipped',
    TestSiblingExistingCandidateIsSkipped);
end;

{ ── TAtomicMoveBareDestination ──────────────────────────────────── }

procedure WriteBareFile(const AName, AText: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(AName);
  finally
    SL.Free;
  end;
end;

function ReadBareFile(const AName: string): string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AName);
    Result := Trim(SL.Text);
  finally
    SL.Free;
  end;
end;

function CountDirEntries(const APath: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(APath) + '*',
      faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then Inc(Result);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
end;

function CountRetiredExecutables(const APath: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(APath) + '*',
      faAnyFile, SR) = 0 then
    try
      repeat
        if IsRetiredExecutableName(SR.Name) then Inc(Result);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
end;

{$IFDEF MSWINDOWS}
const
  SEC_IMAGE_TEST = $01000000;
  GENERIC_EXECUTE_TEST = $20000000;

type
  { An executable mapped as an image section, the way the loader maps a
    running program: the file handle closes once the section exists. }
  TMappedImage = record
    Section: THandle;
    View: Pointer;
  end;

function MapExecutableImage(const APath: string;
  out AImage: TMappedImage): Boolean;
var
  FileHandle: THandle;
begin
  AImage.Section := 0;
  AImage.View := nil;
  FileHandle := Windows.CreateFileW(PWideChar(UnicodeString(
    ExpandFileName(APath))), GENERIC_READ or GENERIC_EXECUTE_TEST,
    FILE_SHARE_READ or FILE_SHARE_DELETE, nil, OPEN_EXISTING, 0, 0);
  if FileHandle = INVALID_HANDLE_VALUE then Exit(False);
  try
    AImage.Section := Windows.CreateFileMappingW(FileHandle, nil,
      PAGE_READONLY or SEC_IMAGE_TEST, 0, 0, nil);
  finally
    Windows.CloseHandle(FileHandle);
  end;
  if AImage.Section = 0 then Exit(False);
  AImage.View := Windows.MapViewOfFile(AImage.Section, FILE_MAP_READ,
    0, 0, 0);
  Result := AImage.View <> nil;
end;

procedure UnmapExecutableImage(var AImage: TMappedImage);
begin
  if AImage.View <> nil then Windows.UnmapViewOfFile(AImage.View);
  if AImage.Section <> 0 then Windows.CloseHandle(AImage.Section);
  AImage.View := nil;
  AImage.Section := 0;
end;
{$ENDIF}

{$IFDEF UNIX}
function FindCrossDeviceBase(const AReferencePath: string;
  out AReason: string): string;
var
  ReferenceInfo, CandidateInfo: BaseUnix.Stat;
  Candidates: TStringList;
  Candidate, Probe: string;
  i: Integer;
begin
  Result := '';
  AReason := '';
  if FpStat(AReferencePath, ReferenceInfo) <> 0 then
  begin
    AReason := 'could not inspect the destination filesystem';
    Exit;
  end;

  Candidates := TStringList.Create;
  try
    Candidate := GetEnvironmentVariable(
      PROJECT_NAME + '_TEST_CROSS_DEVICE_DIR');
    if Candidate <> '' then Candidates.Add(Candidate);
    Candidates.Add('/dev/shm');
    Candidates.Add(GetTempDir(False));
    for i := 0 to Candidates.Count - 1 do
    begin
      Candidate := ExcludeTrailingPathDelimiter(Candidates[i]);
      if (Candidate = '') or not DirectoryExists(Candidate) then Continue;
      if (FpStat(Candidate, CandidateInfo) <> 0)
         or (CandidateInfo.st_dev = ReferenceInfo.st_dev) then Continue;
      Probe := IncludeTrailingPathDelimiter(Candidate)
        + PROGRAM_NAME + '-cross-device-probe-'
        + IntToStr(GetProcessID);
      try
        ForceDirectories(Probe);
        if DirectoryExists(Probe) then Exit(Candidate);
      finally
        if DirectoryExists(Probe) then WipeDir(Probe);
      end;
    end;
  finally
    Candidates.Free;
  end;
  AReason := 'no writable second filesystem is available on this host';
end;
{$ENDIF}

procedure TAtomicMoveBareDestination.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  { Process-unique root: concurrent test binaries must not wipe each
    other's fixtures. }
  FScratch := ExpandFileName('build/tests/tmp/atomic-move-bare-'
    + IntToStr(GetProcessID));
  WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TAtomicMoveBareDestination.BeforeEach;
begin
  SetCurrentDir(FOrigDir);
  WipeDir(FScratch);
  ForceDirectories(FScratch);
  SetCurrentDir(FScratch);
end;

procedure TAtomicMoveBareDestination.AfterAll;
begin
  SetCurrentDir(FOrigDir);
  WipeDir(FScratch);
end;

procedure TAtomicMoveBareDestination.TestSiblingOfBareFilenameStaysRelative;
var
  Sibling: string;
begin
  Sibling := MakeSiblingTmpPath('target.txt', 'old');
  Expect<string>(ExtractFileDir(Sibling)).ToBe('.');
end;

procedure TAtomicMoveBareDestination.TestMoveFileReplacesExistingBareDestination;
begin
  WriteBareFile('dest.txt', 'stale');
  WriteBareFile('incoming.tmp', 'fresh');

  Expect<Boolean>(AtomicMoveFile('incoming.tmp', 'dest.txt')).ToBe(True);

  Expect<string>(ReadBareFile('dest.txt')).ToBe('fresh');
  Expect<Boolean>(FileExists('incoming.tmp')).ToBe(False);
  { No rename-aside backup left behind. }
  Expect<Integer>(CountDirEntries('.')).ToBe(1);
end;

procedure TAtomicMoveBareDestination.TestMoveDirReplacesExistingBareDestination;
begin
  ForceDirectories('destdir');
  WriteBareFile('destdir/stale.txt', 'stale');
  ForceDirectories('incoming');
  WriteBareFile('incoming/fresh.txt', 'fresh');

  Expect<Boolean>(AtomicMoveDir('incoming', 'destdir')).ToBe(True);

  Expect<Boolean>(FileExists('destdir/fresh.txt')).ToBe(True);
  Expect<Boolean>(FileExists('destdir/stale.txt')).ToBe(False);
  Expect<Boolean>(DirectoryExists('incoming')).ToBe(False);
  { No rename-aside backup left behind. }
  Expect<Integer>(CountDirEntries('.')).ToBe(1);
end;

procedure TAtomicMoveBareDestination.
  TestRetiredExecutableSweepMatchesOnlyRetiredImages;
const
  RetiredName = RetiredExecutablePrefix + '4242-1f1huft3e-7'
    + TmpPathExtension;
var
  Retained: Integer;
begin
  Expect<Boolean>(IsRetiredExecutableName(RetiredName)).ToBe(True);
  Expect<Boolean>(IsRetiredExecutableName(RetiredExecutablePrefix
    + '4242-1F1-7' + TmpPathExtension)).ToBe(False);
  Expect<Boolean>(IsRetiredExecutableName(RetiredExecutablePrefix
    + '4242-1f1' + TmpPathExtension)).ToBe(False);
  Expect<Boolean>(IsRetiredExecutableName(RetiredExecutablePrefix
    + '4242-1f1-7-8' + TmpPathExtension)).ToBe(False);
  Expect<Boolean>(IsRetiredExecutableName('.r-4242-1f1huft3e-7'
    + TmpPathExtension)).ToBe(False);

  WriteBareFile('app', 'current');
  WriteBareFile(RetiredName, 'retired');
  { An in-flight replacement backup and a look-alike stay untouched. }
  WriteBareFile('.r-4242-1f1huft3e-8' + TmpPathExtension, 'in flight');
  WriteBareFile(RetiredExecutablePrefix + 'notes' + TmpPathExtension, 'user');
  ForceDirectories(RetiredExecutablePrefix + '4242-1f1huft3e-9'
    + TmpPathExtension);

  Expect<Integer>(RemoveRetiredExecutables('.', '.', Retained)).ToBe(1);
  Expect<Integer>(Retained).ToBe(0);
  Expect<Boolean>(FileExists(RetiredName)).ToBe(False);
  Expect<Integer>(CountDirEntries('.')).ToBe(4);
  Expect<Integer>(RemoveRetiredExecutables('.', 'missing-dir', Retained))
    .ToBe(0);
  Expect<Integer>(Retained).ToBe(0);
end;

const
  SweepFixtureName = RetiredExecutablePrefix + '4242-1f1huft3e-7'
    + TmpPathExtension;

procedure TAtomicMoveBareDestination.
  TestRetiredExecutableSweepStaysInsideOwnerRoot;
var
  Retained: Integer;
begin
  ForceDirectories('outside');
  WriteBareFile('outside' + PathDelim + SweepFixtureName, 'foreign');
  ForceDirectories('project' + PathDelim + 'build');
  WriteBareFile('project' + PathDelim + 'build' + PathDelim
    + SweepFixtureName, 'retired');

  { A directory outside the owner root is never swept, however it is
    spelled. }
  Expect<Boolean>(RetiredExecutableSweepAllowed('project', 'outside'))
    .ToBe(False);
  Expect<Boolean>(RetiredExecutableSweepAllowed('project',
    'project' + PathDelim + '..' + PathDelim + 'outside')).ToBe(False);
  Expect<Integer>(RemoveRetiredExecutables('project', 'outside', Retained))
    .ToBe(0);
  Expect<Integer>(Retained).ToBe(0);
  Expect<Boolean>(FileExists('outside' + PathDelim + SweepFixtureName))
    .ToBe(True);

  Expect<Boolean>(RetiredExecutableSweepAllowed('project', 'project'))
    .ToBe(True);
  Expect<Integer>(RemoveRetiredExecutables('project',
    'project' + PathDelim + 'build', Retained)).ToBe(1);
  Expect<Boolean>(FileExists('project' + PathDelim + 'build' + PathDelim
    + SweepFixtureName)).ToBe(False);
end;

{$IFDEF UNIX}
function LinkEntryExists(const APath: string): Boolean;
var
  Info: BaseUnix.Stat;
begin
  Result := (FpLstat(APath, Info) = 0) and FpS_ISLNK(Info.st_mode);
end;

procedure TAtomicMoveBareDestination.TestRetiredExecutableSweepSkipsFileLinks;
const
  LiveLink = RetiredExecutablePrefix + '4242-1f1huft3e-8' + TmpPathExtension;
  DanglingLink = RetiredExecutablePrefix + '4242-1f1huft3e-9'
    + TmpPathExtension;
var
  Retained: Integer;
begin
  WriteBareFile('link-target', 'user-owned');
  WriteBareFile(SweepFixtureName, 'retired');
  Expect<Integer>(FpSymlink('link-target', LiveLink)).ToBe(0);
  Expect<Integer>(FpSymlink('missing-target', DanglingLink)).ToBe(0);

  { Only the regular retired image goes; matching links, live or dangling,
    are neither followed nor removed. }
  Expect<Integer>(RemoveRetiredExecutables('.', '.', Retained)).ToBe(1);
  Expect<Integer>(Retained).ToBe(0);
  Expect<Boolean>(FileExists(SweepFixtureName)).ToBe(False);
  Expect<Boolean>(LinkEntryExists(LiveLink)).ToBe(True);
  Expect<Boolean>(LinkEntryExists(DanglingLink)).ToBe(True);
  Expect<string>(ReadBareFile('link-target')).ToBe('user-owned');
end;

procedure TAtomicMoveBareDestination.
  TestRetiredExecutableSweepRefusesDirectoryLinks;
var
  Retained: Integer;
begin
  ForceDirectories('project');
  ForceDirectories('elsewhere/bin');
  WriteBareFile('elsewhere/' + SweepFixtureName, 'foreign');
  WriteBareFile('elsewhere/bin/' + SweepFixtureName, 'foreign');
  Expect<Integer>(FpSymlink('../elsewhere', 'project/build')).ToBe(0);
  Expect<Integer>(FpSymlink('../elsewhere', 'project/redirect')).ToBe(0);

  { The output directory itself is a link. }
  Expect<Boolean>(RetiredExecutableSweepAllowed('project', 'project/build'))
    .ToBe(False);
  Expect<Integer>(RemoveRetiredExecutables('project', 'project/build',
    Retained)).ToBe(0);
  { A link on an ancestor redirects an ordinary-looking directory. }
  Expect<Boolean>(RetiredExecutableSweepAllowed('project',
    'project/redirect/bin')).ToBe(False);
  Expect<Integer>(RemoveRetiredExecutables('project', 'project/redirect/bin',
    Retained)).ToBe(0);
  Expect<Boolean>(FileExists('elsewhere/' + SweepFixtureName)).ToBe(True);
  Expect<Boolean>(FileExists('elsewhere/bin/' + SweepFixtureName))
    .ToBe(True);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
{ mklink /J reports success under Wine without creating anything, so the
  result is the junction's presence, not the exit status. }
function TryCreateJunction(const ALink, ATarget: string): Boolean;
var
  Command: TProcess;
begin
  Command := TProcess.Create(nil);
  try
    Command.Executable := SysUtils.GetEnvironmentVariable('COMSPEC');
    if Command.Executable = '' then Command.Executable := 'cmd.exe';
    Command.Parameters.Add('/C');
    Command.Parameters.Add('mklink /J "' + ExpandFileName(ALink) + '" "'
      + ExpandFileName(ATarget) + '"');
    Command.Options := [poWaitOnExit, poNoConsole];
    try
      Command.Execute;
    except
      Exit(False);
    end;
  finally
    Command.Free;
  end;
  Result := IsDirSymlinkOrJunction(ALink);
end;

function JunctionSkipReason: string;
var
  Probe: string;
begin
  Probe := ExpandFileName('build\tests\tmp\junction-probe-'
    + IntToStr(GetProcessID));
  ForceDirectories(Probe + '\target');
  try
    if TryCreateJunction(Probe + '\link', Probe + '\target') then
      Result := ''
    else
      Result := 'directory junctions cannot be created on this host';
  finally
    Windows.RemoveDirectoryW(PWideChar(UnicodeString(Probe + '\link')));
    WipeDir(Probe);
  end;
end;

procedure TAtomicMoveBareDestination.
  TestRetiredExecutableSweepRefusesJunctions;
var
  Retained: Integer;
begin
  ForceDirectories('project');
  ForceDirectories('elsewhere\bin');
  WriteBareFile('elsewhere\' + SweepFixtureName, 'foreign');
  WriteBareFile('elsewhere\bin\' + SweepFixtureName, 'foreign');
  Expect<Boolean>(TryCreateJunction('project\build', 'elsewhere'))
    .ToBe(True);
  Expect<Boolean>(TryCreateJunction('project\redirect', 'elsewhere'))
    .ToBe(True);
  try
    Expect<Integer>(RemoveRetiredExecutables('project', 'project\build',
      Retained)).ToBe(0);
    Expect<Integer>(RemoveRetiredExecutables('project',
      'project\redirect\bin', Retained)).ToBe(0);
    Expect<Boolean>(FileExists('elsewhere\' + SweepFixtureName)).ToBe(True);
    Expect<Boolean>(FileExists('elsewhere\bin\' + SweepFixtureName))
      .ToBe(True);
  finally
    Windows.RemoveDirectoryW(PWideChar(UnicodeString(
      ExpandFileName('project\build'))));
    Windows.RemoveDirectoryW(PWideChar(UnicodeString(
      ExpandFileName('project\redirect'))));
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure TAtomicMoveBareDestination.TestReplaceExecutableRetiresMappedImage;
var
  Image: TMappedImage;
  Retained: Integer;
begin
  ForceDirectories('images');
  Expect<Boolean>(CopyFileContent(ParamStr(0), 'images\app.exe')).ToBe(True);
  WriteBareFile('images\incoming.tmp', 'fresh');
  Expect<Boolean>(MapExecutableImage('images\app.exe', Image)).ToBe(True);
  try
    { A self-hosted rebuild replaces the image it is running from. The
      replacement commits and the undeletable old image is retired. }
    Expect<Boolean>(AtomicReplaceExecutable('images\incoming.tmp',
      'images\app.exe', '.')).ToBe(True);
    Expect<string>(ReadBareFile('images\app.exe')).ToBe('fresh');
    Expect<Boolean>(FileExists('images\incoming.tmp')).ToBe(False);
    Expect<Integer>(CountRetiredExecutables('images')).ToBe(1);
    Expect<Integer>(CountDirEntries('images')).ToBe(2);
    { A sweep while the image is still mapped retains it. }
    Expect<Integer>(RemoveRetiredExecutables('.', 'images', Retained))
      .ToBe(0);
    Expect<Integer>(Retained).ToBe(1);
  finally
    UnmapExecutableImage(Image);
  end;

  { Once the image is released, the next executable replacement in the
    directory removes the retired image. }
  WriteBareFile('images\incoming.tmp', 'newer');
  Expect<Boolean>(AtomicReplaceExecutable('images\incoming.tmp',
    'images\app.exe', '.')).ToBe(True);
  Expect<string>(ReadBareFile('images\app.exe')).ToBe('newer');
  Expect<Integer>(CountDirEntries('images')).ToBe(1);
end;

procedure TAtomicMoveBareDestination.TestReplaceFileStaysStrictForMappedImage;
var
  Image: TMappedImage;
  Raised: Boolean;
begin
  ForceDirectories('images');
  Expect<Boolean>(CopyFileContent(ParamStr(0), 'images\app.exe')).ToBe(True);
  WriteBareFile('images\incoming.tmp', 'fresh');
  Expect<Boolean>(MapExecutableImage('images\app.exe', Image)).ToBe(True);
  try
    { Toolkit state keeps the strict contract: an undeletable backup is
      reported, never silently retired. }
    Raised := False;
    try
      AtomicReplaceFile('images\incoming.tmp', 'images\app.exe');
    except
      on E: EExtractError do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<string>(ReadBareFile('images\app.exe')).ToBe('fresh');
    Expect<Integer>(CountRetiredExecutables('images')).ToBe(0);
  finally
    UnmapExecutableImage(Image);
  end;
end;

procedure TAtomicMoveBareDestination.TestReplaceFileAtDeepExistingDestination;
const
  DestinationName = 'destination-with-existing-bytes.txt';
  LegacyWindowsPathCeiling = 260;
var
  DeepDir, DestinationPath, LegacyBackupPath, SourcePath: string;
  PaddingLength: Integer;
begin
  PaddingLength := 245 - Length(IncludeTrailingPathDelimiter(FScratch))
    - 1 - Length(DestinationName);
  Expect<Boolean>(PaddingLength > 0).ToBe(True);
  DeepDir := IncludeTrailingPathDelimiter(FScratch)
    + StringOfChar('d', PaddingLength);
  ForceDirectories(DeepDir);
  DestinationPath := IncludeTrailingPathDelimiter(DeepDir) + DestinationName;
  SourcePath := IncludeTrailingPathDelimiter(DeepDir) + 'incoming.tmp';
  WriteBareFile(DestinationPath, 'stale');
  WriteBareFile(SourcePath, 'fresh');

  { The former destination-derived backup crosses the legacy Win32 ceiling,
    while both caller-owned paths remain below it and are valid fixtures. }
  LegacyBackupPath := MakeSiblingTmpPath(DestinationPath, 'replace-backup');
  Expect<Boolean>(Length(DestinationPath) < LegacyWindowsPathCeiling)
    .ToBe(True);
  Expect<Boolean>(Length(SourcePath) < LegacyWindowsPathCeiling).ToBe(True);
  Expect<Boolean>(Length(LegacyBackupPath) >= LegacyWindowsPathCeiling)
    .ToBe(True);

  Expect<Boolean>(AtomicReplaceFile(SourcePath, DestinationPath)).ToBe(True);
  Expect<string>(ReadBareFile(DestinationPath)).ToBe('fresh');
  Expect<Boolean>(FileExists(SourcePath)).ToBe(False);
  Expect<Integer>(CountDirEntries(DeepDir)).ToBe(1);
end;

procedure TAtomicMoveBareDestination.TestReplaceFileRejectsDirectorySource;
begin
  ForceDirectories('incoming-dir');

  Expect<Boolean>(AtomicReplaceFile('incoming-dir', 'dest.txt')).ToBe(False);
  Expect<Boolean>(DirectoryExists('incoming-dir')).ToBe(True);
  Expect<Boolean>(FileExists('dest.txt')).ToBe(False);
end;
{$ENDIF}

{$IFDEF UNIX}
procedure TAtomicMoveBareDestination.
  TestMoveFileReplacesExistingAcrossFilesystems;
var
  CrossScratch, SourcePath, DestinationPath: string;
  SourceInfo, DestinationInfo: BaseUnix.Stat;
begin
  CrossScratch := IncludeTrailingPathDelimiter(FCrossDeviceBase)
    + PROGRAM_NAME + '-atomic-move-' + IntToStr(GetProcessID);
  SourcePath := CrossScratch + '/incoming.tmp';
  DestinationPath := FScratch + '/cross-device-destination.txt';
  try
    ForceDirectories(CrossScratch);
    WriteBareFile(SourcePath, 'fresh');
    WriteBareFile(DestinationPath, 'stale');
    Expect<Integer>(FpStat(SourcePath, SourceInfo)).ToBe(0);
    Expect<Integer>(FpStat(DestinationPath, DestinationInfo)).ToBe(0);
    Expect<Boolean>(SourceInfo.st_dev <> DestinationInfo.st_dev).ToBe(True);

    Expect<Boolean>(AtomicMoveFile(SourcePath, DestinationPath)).ToBe(True);

    Expect<string>(ReadBareFile(DestinationPath)).ToBe('fresh');
    Expect<Boolean>(FileExists(SourcePath)).ToBe(False);
    { The EXDEV copy is staged beside the destination and leaves no sibling. }
    Expect<Integer>(CountDirEntries(FScratch)).ToBe(1);
  finally
    if DirectoryExists(CrossScratch) then WipeDir(CrossScratch);
  end;
end;
{$ENDIF}

procedure TAtomicMoveBareDestination.SetupTests;
begin
  {$IFDEF UNIX}
  FCrossDeviceBase := FindCrossDeviceBase(GetCurrentDir,
    FCrossDeviceSkipReason);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FJunctionSkipReason := JunctionSkipReason;
  {$ENDIF}
  Test('sibling of a bare filename resolves under the current directory',
    TestSiblingOfBareFilenameStaysRelative);
  Test('bare-filename destination with existing file is replaced',
    TestMoveFileReplacesExistingBareDestination);
  Test('bare-dirname destination with existing directory is replaced',
    TestMoveDirReplacesExistingBareDestination);
  Test('retired-image sweep removes only retired executable images',
    TestRetiredExecutableSweepMatchesOnlyRetiredImages);
  Test('retired-image sweep stays inside its owner root',
    TestRetiredExecutableSweepStaysInsideOwnerRoot);
  {$IFDEF MSWINDOWS}
  Test('deep existing destination is replaced without a longer-path backup',
    TestReplaceFileAtDeepExistingDestination);
  Test('file replacement rejects a directory source',
    TestReplaceFileRejectsDirectorySource);
  Test('executable replacement retires a mapped image and cleans it later',
    TestReplaceExecutableRetiresMappedImage);
  Test('file replacement stays strict when its backup is a mapped image',
    TestReplaceFileStaysStrictForMappedImage);
  if FJunctionSkipReason = '' then
    Test('retired-image sweep refuses junction-redirected directories',
      TestRetiredExecutableSweepRefusesJunctions)
  else
    Skip('retired-image sweep refuses junction-redirected directories',
      TestRetiredExecutableSweepRefusesJunctions, FJunctionSkipReason);
  {$ENDIF}
  {$IFDEF UNIX}
  Test('retired-image sweep never follows or removes file links',
    TestRetiredExecutableSweepSkipsFileLinks);
  Test('retired-image sweep refuses link-redirected directories',
    TestRetiredExecutableSweepRefusesDirectoryLinks);
  if FCrossDeviceBase <> '' then
    Test('existing file is atomically replaced across filesystems',
      TestMoveFileReplacesExistingAcrossFilesystems)
  else
    Skip('existing file is atomically replaced across filesystems',
      TestMoveFileReplacesExistingAcrossFilesystems,
      FCrossDeviceSkipReason);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TSHA256NISTVectors.Create(
    PROJECT_NAME + '.Core: SHA-256 NIST vectors'));
  TestRunnerProgram.AddSuite(THashTreePaths.Create(
    PROJECT_NAME + '.Core: HashTree paths'));
  TestRunnerProgram.AddSuite(TTreeDigestV2.Create(
    PROJECT_NAME + '.Core: sha256-tree2 digest (ADR-0052)'));
  TestRunnerProgram.AddSuite(TLoadManifestHappy.Create(
    PROJECT_NAME + '.Manifest: LoadManifest happy path'));
  TestRunnerProgram.AddSuite(TLoadManifestValidation.Create(
    PROJECT_NAME + '.Manifest: LoadManifest validation'));
  TestRunnerProgram.AddSuite(TLoadManifestExtensions.Create(
    PROJECT_NAME + '.Manifest: LoadManifest extensions ([' + PROGRAM_NAME
    + '] / [format] / [generated])'));
  TestRunnerProgram.AddSuite(TLockfileLoading.Create(
    PROJECT_NAME + '.Install: LoadLockfile'));
  TestRunnerProgram.AddSuite(TVerifyAgainstLockfile.Create(
    PROJECT_NAME + '.Install: VerifyAgainstLockfile'));
  TestRunnerProgram.AddSuite(TConstraintFingerprintFold.Create(
    PROJECT_NAME + '.Install: ConstraintFingerprintForNode'));
  TestRunnerProgram.AddSuite(TParseDependencySource.Create(
    PROJECT_NAME + '.Manifest: ParseDependencySource'));
  TestRunnerProgram.AddSuite(TParseVersionSpec.Create(
    PROJECT_NAME + '.Manifest: ParseVersionSpec'));
  TestRunnerProgram.AddSuite(TGitProtocolParsing.Create(
    PROJECT_NAME + '.GitProtocol: ParseInfoRefs'));
  TestRunnerProgram.AddSuite(TCustomSources.Create(
    PROJECT_NAME + '.Manifest: Custom [sources]'));
  TestRunnerProgram.AddSuite(TPathGlobMatching.Create(
    PROJECT_NAME + '.Core: MatchPathGlob'));
  TestRunnerProgram.AddSuite(TSanitisePathSegmentSuite.Create(
    PROJECT_NAME + '.Core: SanitisePathSegment'));
  TestRunnerProgram.AddSuite(TMakeTmpPathSuite.Create(
    PROJECT_NAME + '.Core: MakeTmpPath uniqueness'));
  TestRunnerProgram.AddSuite(TAppendProcessEnvironmentSuite.Create(
    PROJECT_NAME + '.Core: AppendProcessEnvironment concurrency'));
  TestRunnerProgram.AddSuite(TAtomicMoveBareDestination.Create(
    PROJECT_NAME + '.Core: atomic move, bare relative destination'));
  TestRunnerProgram.AddSuite(TApplyIncludeExclude.Create(
    PROJECT_NAME + '.Core: ApplyIncludeExclude'));
  TestRunnerProgram.AddSuite(TCopyDirTreeGuards.Create(
    PROJECT_NAME + '.Core: CopyDirTree recursion guards'));
  TestRunnerProgram.AddSuite(TWipeDirSymlinks.Create(
    PROJECT_NAME + '.Core: WipeDir symlink handling'));
  TestRunnerProgram.AddSuite(TPruneOrphans.Create(
    PROJECT_NAME + '.Install: PruneOrphanedPackages'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
