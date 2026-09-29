{ LWPT.ArchiveNormalize.Test — the publication archive layer (ADR-0049,
  "Archive contract" and "Zip normalization").

  Golden fixtures pin the canonical tar.gz. Three zips of one tree, written
  by independent tools (Info-ZIP, 7-Zip with the package at the zip root,
  and Python's zipfile with data descriptors; see
  tests/fixtures/archive-normalize/README.md), and a synthesised zip of the
  same tree must all normalize to the pinned hash, as must every variation
  in entry order, timestamps, compression, descriptors, comments, and
  extra fields. The pinned hashes were cross-checked when pinned against an
  independent reference writer over zlib 1.3, which produced identical
  bytes. The same hashes must hold on every release platform; a change is a
  new normalizer version, not a fixture refresh.

  Every other zip is synthesised byte by byte (Tests.ZipSynth) and every
  tar.gz by Tests.TarSynth, so each refusal isolates one rule. A refusal is
  asserted by its stable code together with a fragment of its detail. }
program LWPT.ArchiveNormalize.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Archive,
  LWPT.ArchiveNormalize,
  LWPT.Core,
  LWPT.Gzip,
  LWPT.Install,
  TestingPascalLibrary,
  Tests.Scratch,
  Tests.TarSynth,
  Tests.ZipSynth;

type
  TNormalizeGoldenSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDetectsInputByLeadingBytes;
    procedure TestIndependentToolZipsMatchGolden;
    procedure TestSynthesisedZipMatchesGolden;
    procedure TestIrrelevantDifferencesGiveSameBytes;
    procedure TestConvertingTwiceIsIdentical;
    procedure TestLargeZipMatchesGolden;
    procedure TestExecuteBits;
    procedure TestOutputIsACanonicalPackage;
    procedure TestAcceptedOutputsRoundTrip;
  end;

  TNormalizeEntrySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRejectsSpecialFiles;
    procedure TestRejectsMsDosVolumeAndDirectoryMismatch;
    procedure TestRejectsAbsoluteAndDrivePaths;
    procedure TestRejectsDotComponents;
    procedure TestRejectsEmptyComponents;
    procedure TestRejectsDuplicateNames;
    procedure TestComponentAndUstarLimits;
    procedure TestRejectsInvalidNames;
    procedure TestRejectsDirectoryWithContent;
    procedure TestPackageRootLayouts;
    procedure TestRootStrippingRevalidatesPaths;
  end;

  TNormalizeNamespaceSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRejectsFileBesideDirectory;
    procedure TestRejectsCaseCollisions;
    procedure TestAcceptsExplicitParentDirectory;
  end;

  TNormalizeIdentitySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRejectsInvalidIdentity;
    procedure TestDependencyRefusalIsSeparable;
  end;

  TNormalizeLimitSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestInputBound;
    procedure TestEntryAndDeclaredBounds;
    procedure TestInflationPastDeclaredSize;
    procedure TestOutputBound;
    procedure TestTarGzipExpansionBound;
    procedure TestOverlongPathRefusedBeforeTree;
    procedure TestTreePathBudget;
    procedure TestManifestByteBudget;
    procedure TestManifestNodeBudget;
  end;

  TManifestAliasSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTarManifestOverwriteIsRefused;
    procedure TestTarManifestAliases;
    procedure TestZipManifestAliases;
    procedure TestPlatformAliasesInEveryEntry;
  end;

  TTarGzipScanSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAcceptsGitArchiveUnchanged;
    procedure TestAcceptsCanonicalOutput;
    procedure TestAcceptsInstallerSupportedShapes;
    procedure TestRejectsTraversal;
    procedure TestRejectsEscapingLinks;
    procedure TestRejectsLongComponent;
    procedure TestRequiresOneTopLevelDirectory;
    procedure TestRequiresOneRegularManifest;
    procedure TestRejectsCorruptStreams;
  end;

const
  FIXTURE_DIR = 'tests/fixtures/archive-normalize/';
  { The canonical tar.gz of the golden tree (normalizer version 1). }
  GOLDEN_HASH =
    'be0b81514a8bdc8fb6687673d0b70c50e128f8795bd772f325b99a6e3399c27a';
  GOLDEN_MANIFEST = '[package]'#10'name = "golden"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10;
  GOLDEN_README = '# golden'#10#10'Normalizer fixture.'#10;
  GOLDEN_UNIT = 'unit Golden;'#10#10'interface'#10#10'implementation'#10#10
    + 'end.'#10;
  GOLDEN_SCRIPT = '#!/bin/sh'#10'echo golden'#10;
  DEMO_MANIFEST = '[package]'#10'name = "demo"'#10'version = "1.0.0"'#10;

function ReadFixture(const AName: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FIXTURE_DIR + AName, fmOpenRead
    or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function Gunzip(const AGzip: TBytes): TBytes;
var
  Source, Target: TBytesStream;
begin
  Source := TBytesStream.Create(AGzip);
  Target := TBytesStream.Create(nil);
  try
    GunzipStream(Source, Target);
    Result := System.Copy(Target.Bytes, 0, Target.Size);
  finally
    Target.Free;
    Source.Free;
  end;
end;

function Normalized(const AInput: TBytes): TBytes;
begin
  Result := PreparePublicationArchive(AInput).Archive;
end;

function NormalizedHash(const AInput: TBytes): string;
begin
  Result := SHA256Hex(Normalized(AInput));
end;

{ The stable code when the refusal's detail contains AFragment, the whole
  message when it does not, 'accepted' when nothing is refused. }
function Rejection(const AInput: TBytes; const AFragment: string;
  const ALimits: TLWPTArchiveLimits): string; overload;
var
  Prepared: TLWPTPublicationArchive;
begin
  Result := 'accepted';
  try
    Prepared := PreparePublicationArchive(AInput, ALimits);
    { Every accepted zip must yield a tar.gz that passes the tar.gz
      contract it is published under. }
    if Prepared.Kind = akZip then
    try
      ScanTarGzipArchive(Prepared.Archive, ALimits);
    except
      on E: ELWPTArchiveError do
        Exit('normalized output fails the tar.gz scan: ' + E.Message);
    end;
  except
    on E: ELWPTArchiveError do
      if Pos(AFragment, E.Message) > 0 then
        Result := E.Code
      else
        Result := E.Message;
  end;
end;

function Rejection(const AInput: TBytes;
  const AFragment: string): string; overload;
begin
  Result := Rejection(AInput, AFragment, DefaultArchiveLimits);
end;

function NoiseBytes(const ACount: Integer; ASeed: Cardinal): TBytes;
var
  i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
  begin
    ASeed := ASeed xor (ASeed shl 13);
    ASeed := ASeed xor (ASeed shr 17);
    ASeed := ASeed xor (ASeed shl 5);
    Result[i] := Byte(ASeed and $FF);
  end;
end;

{ A one-package zip: 'pkg/lwpt.toml' plus the given extra entries. }
function DemoZip(const ANames: array of RawByteString;
  const AManifest: string = DEMO_MANIFEST): TBytes;
var
  Z: TZipSynth;
  i: Integer;
begin
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', AManifest);
    for i := 0 to High(ANames) do
      if (ANames[i] <> '') and (ANames[i][Length(ANames[i])] = '/') then
        Z.AddDirectory(ANames[i])
      else
        Z.AddText(ANames[i], 'x');
    Result := Z.Build;
  finally
    Z.Free;
  end;
end;

{ One entry with the given host and external attributes beside the
  manifest. }
function AttributeZip(const AName: RawByteString; const AHost: Byte;
  const AAttributes: Cardinal): TBytes;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  i: Integer;
begin
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
    if (AName <> '') and (AName[Length(AName)] = '/') then
      i := Z.AddDirectory(AName)
    else
      i := Z.AddText(AName, 'x');
    E := Z.Entry(i);
    E.Host := AHost;
    E.ExternalAttributes := AAttributes;
    Z.SetEntry(i, E);
    Result := Z.Build;
  finally
    Z.Free;
  end;
end;

{ The golden tree, synthesised. AVariant selects one irrelevant
  difference. }
function GoldenZip(const AVariant: Integer): TBytes;
var
  Z: TZipSynth;
  Order: array[0..5] of Integer;
  i, k, Method: Word;
  E: TZipSynthEntry;
  Prefix: RawByteString;
begin
  Z := TZipSynth.Create;
  try
    Prefix := 'golden/';
    if AVariant = 7 then Prefix := '';
    for i := 0 to 5 do Order[i] := i;
    if AVariant = 1 then
      for i := 0 to 5 do Order[i] := 5 - i;
    Method := 8;
    if AVariant = 3 then Method := 0;
    for k := 0 to 5 do
    begin
      case Order[k] of
        0: i := Z.AddText(Prefix + 'lwpt.toml', GOLDEN_MANIFEST, Method);
        1: i := Z.AddText(Prefix + 'README.md', GOLDEN_README, Method);
        2: i := Z.AddText(Prefix + 'source/Golden.pas', GOLDEN_UNIT, Method);
        3: begin
             i := Z.AddText(Prefix + 'bin/run.sh', GOLDEN_SCRIPT, Method);
             E := Z.Entry(i);
             E.ExternalAttributes := ZIP_SYNTH_REGULAR_755;
             Z.SetEntry(i, E);
           end;
        4: i := Z.AddDirectory(Prefix + 'empty/');
      else
        { The explicit directory for source/, which the others imply. }
        if AVariant = 6 then Continue;
        i := Z.AddDirectory(Prefix + 'source/');
      end;
      E := Z.Entry(i);
      case AVariant of
        2: begin
             E.DosTime := Word(k * 1111);
             E.DosDate := Word($4000 + k * 37);
           end;
        4: E.Level := 1 + (k mod 9);
        5: begin
             E.Descriptor := True;
             E.DescriptorSignature := Odd(k);
           end;
        6: begin
             E.Comment := RawByteString(Format('entry %d', [k]));
             E.CentralExtra := TextBytes('UT'#5#0'abcde');
             E.LocalExtra := TextBytes('ux'#0#0);
           end;
      end;
      Z.SetEntry(i, E);
    end;
    if AVariant = 6 then Z.Comment := 'archive comment';
    Result := Z.Build;
  finally
    Z.Free;
  end;
end;

{ ---- detection and golden output ---------------------------------------- }

procedure TNormalizeGoldenSuite.TestDetectsInputByLeadingBytes;

  function Kind(const AInput: TBytes): string;
  begin
    try
      case DetectArchiveKind(AInput) of
        akTarGzip: Result := 'tar.gz';
        akZip: Result := 'zip';
      end;
    except
      on E: ELWPTArchiveError do Result := E.Code;
    end;
  end;

begin
  Expect<string>(Kind(TextBytes(#$1F#$8B))).ToBe('tar.gz');
  Expect<string>(Kind(TextBytes('PK'#3#4))).ToBe('zip');
  Expect<string>(Kind(TextBytes('PK'#5#6))).ToBe('zip');
  Expect<string>(Kind(TextBytes('PK'#7#8))).ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Kind(TextBytes('PK'))).ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Kind(TextBytes(#$1F))).ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Kind(nil)).ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Kind(TextBytes('ustar'))).ToBe(ARCHIVE_UNSUPPORTED);
  { The name never matters: a zip is a zip whatever it is called, and an
    empty zip (end record only) is a zip without a manifest. }
  Expect<string>(Rejection(TextBytes('PK'#5#6 + StringOfChar(#0, 18)),
    'zip has no lwpt.toml')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(TextBytes('7z'#$BC#$AF), 'neither'))
    .ToBe(ARCHIVE_UNSUPPORTED);
end;

procedure TNormalizeGoldenSuite.TestIndependentToolZipsMatchGolden;
var
  Result: TLWPTPublicationArchive;
begin
  Expect<string>(NormalizedHash(ReadFixture('infozip.zip'))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(ReadFixture('sevenzip-root.zip')))
    .ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(ReadFixture('python-descriptors.zip')))
    .ToBe(GOLDEN_HASH);
  Result := PreparePublicationArchive(ReadFixture('infozip.zip'));
  Expect<Boolean>(Result.Kind = akZip).ToBe(True);
  Expect<string>(Result.Manifest.Name).ToBe('golden');
  Expect<string>(Result.Manifest.Version).ToBe('1.0.0');
  Expect<Boolean>(Result.Manifest.DeclaresDependencies).ToBe(False);
end;

procedure TNormalizeGoldenSuite.TestSynthesisedZipMatchesGolden;
begin
  Expect<string>(NormalizedHash(GoldenZip(0))).ToBe(GOLDEN_HASH);
end;

procedure TNormalizeGoldenSuite.TestIrrelevantDifferencesGiveSameBytes;
begin
  { 1 reversed entry order, 2 timestamps, 3 stored instead of deflate,
    4 deflate levels, 5 data descriptors with and without signatures,
    6 comments, extra fields, and an implied instead of explicit parent,
    7 the package at the zip root. }
  Expect<string>(NormalizedHash(GoldenZip(1))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(GoldenZip(2))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(GoldenZip(3))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(GoldenZip(4))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(GoldenZip(5))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(GoldenZip(6))).ToBe(GOLDEN_HASH);
  Expect<string>(NormalizedHash(GoldenZip(7))).ToBe(GOLDEN_HASH);
end;

procedure TNormalizeGoldenSuite.TestConvertingTwiceIsIdentical;
var
  Input, First, Second: TBytes;
  Stream: TBytesStream;
  Manifest: TLWPTPublicationManifest;
begin
  Input := ReadFixture('python-descriptors.zip');
  First := Normalized(Input);
  Second := Normalized(Input);
  Expect<Integer>(Length(Second)).ToBe(Length(First));
  Expect<Boolean>(CompareMem(@First[0], @Second[0], Length(First)))
    .ToBe(True);
  { The streaming entry point writes the same bytes to the caller's
    target. }
  Stream := TBytesStream.Create(nil);
  try
    Manifest := NormalizeZipArchive(Input, Stream, DefaultArchiveLimits);
    Expect<string>(Manifest.Name).ToBe('golden');
    Expect<string>(SHA256Hex(System.Copy(Stream.Bytes, 0, Stream.Size)))
      .ToBe(GOLDEN_HASH);
  finally
    Stream.Free;
  end;
end;

const
  LONG_DIRECTORY = 'bulk/dddddddddddddddddddddddddddddddddddddddddddddddddd'
    + 'dddddddddd/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    + 'e';

function LargeZip: TBytes;
var
  Z: TZipSynth;
  Text: string;
  i: Integer;
  E: TZipSynthEntry;
begin
  Text := '';
  for i := 1 to 3000 do
    Text := Text + Format('row %d of the bulk text payload'#10, [i]);
  Z := TZipSynth.Create;
  try
    Z.AddText('bulk/lwpt.toml', '[package]'#10'name = "bulk"'#10
      + 'version = "2.1.0-rc.1"'#10);
    Z.Add('bulk/data/noise.bin', NoiseBytes(300000, $1234567));
    i := Z.AddText('bulk/text.txt', Text, 0);
    E := Z.Entry(i);
    E.ExternalAttributes := Cardinal($8140) shl 16;
    Z.SetEntry(i, E);
    Z.AddText(LONG_DIRECTORY + '/' + StringOfChar('f', 90) + '.txt', 'deep');
    Z.AddText('bulk/docs/'#$C3#$BC'bersicht.md', 'umlaut');
    Z.AddText('bulk/docs/Z.md', 'upper');
    Z.AddText('bulk/docs/a-b.md', 'dash');
    Z.AddDirectory('bulk/docs/a/');
    Result := Z.Build;
  finally
    Z.Free;
  end;
end;

procedure TNormalizeGoldenSuite.TestLargeZipMatchesGolden;
var
  Output: TBytes;
  Result: TLWPTPublicationArchive;
begin
  Result := PreparePublicationArchive(LargeZip);
  Output := Result.Archive;
  Expect<string>(Result.Manifest.Version).ToBe('2.1.0-rc.1');
  Expect<string>(SHA256Hex(Output)).ToBe(
    'f97cab7cd7795c084f554a6a15e9e89ec88657cafc736af06f48ae2997ab42c3');
  Expect<string>(SHA256Hex(Gunzip(Output))).ToBe(
    '176ed9cb2e2589306034f9e76e0259db50e329e9a08dc334cb975bbc010df170');
end;

procedure TNormalizeGoldenSuite.TestExecuteBits;

  { The mode field of the tar entry for pkg's file 'demo-1.0.0/f'. }
  function ModeOf(const AHost: Byte; const AAttributes: Cardinal): string;
  var
    Tar: TBytes;
    Offset: Integer;
  begin
    Tar := Gunzip(Normalized(AttributeZip('pkg/f', AHost, AAttributes)));
    { Root directory, then 'f', then lwpt.toml. }
    Offset := 512;
    SetLength(Result, 7);
    Move(Tar[Offset + 100], Result[1], 7);
  end;

begin
  Expect<string>(ModeOf(ZIP_SYNTH_UNIX, Cardinal($81A4) shl 16))
    .ToBe('0000644');
  Expect<string>(ModeOf(ZIP_SYNTH_UNIX, Cardinal($81ED) shl 16))
    .ToBe('0000755');
  Expect<string>(ModeOf(ZIP_SYNTH_UNIX, Cardinal($8140) shl 16))
    .ToBe('0000755');
  Expect<string>(ModeOf(ZIP_SYNTH_UNIX, Cardinal($8001) shl 16))
    .ToBe('0000755');
  { An unset Unix file type is a regular file; its execute bits count. }
  Expect<string>(ModeOf(ZIP_SYNTH_UNIX, Cardinal($0049) shl 16))
    .ToBe('0000755');
  Expect<string>(ModeOf(ZIP_SYNTH_UNIX, Cardinal($81B6) shl 16))
    .ToBe('0000644');
  { Other hosts carry no execute bit. }
  Expect<string>(ModeOf(ZIP_SYNTH_MSDOS, Cardinal($81ED) shl 16 or $20))
    .ToBe('0000644');
  Expect<string>(ModeOf(11, Cardinal($81ED) shl 16)).ToBe('0000644');
end;

procedure TNormalizeGoldenSuite.TestOutputIsACanonicalPackage;
var
  Output: TBytes;
  Scanned: TLWPTPublicationManifest;
begin
  Output := Normalized(ReadFixture('infozip.zip'));
  { The output satisfies the tar.gz contract it will be published under. }
  Scanned := ScanTarGzipArchive(Output, DefaultArchiveLimits);
  Expect<string>(Scanned.Name + '@' + Scanned.Version).ToBe('golden@1.0.0');
  Expect<string>(SHA256Hex(PreparePublicationArchive(Output).Archive))
    .ToBe(GOLDEN_HASH);
end;

{ A seeded property check: random small trees drawn from names that
  exercise every entry and namespace rule. Whatever is accepted must
  normalize deterministically and pass the tar.gz scan. }
procedure TNormalizeGoldenSuite.TestAcceptedOutputsRoundTrip;
const
  COMPONENTS: array[0..15] of RawByteString = ('a', 'B', 'b', 'C:', 'c:x',
    'lwpt.toml', 'LWPT.toml', 'lwpt.toml.', '.', '..', '', 'x y',
    #$C3#$BC, 'd', 'LWPT~1.TOM', 'a-b');
var
  Seed: Cardinal;
  Round, Entries, Depth, k, j, Accepted: Integer;
  Z: TZipSynth;
  Name: RawByteString;
  Input: TBytes;
  First, Second: TLWPTPublicationArchive;
  Failure: string;

  function Next(const ABound: Integer): Integer;
  begin
    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor (Seed shl 5);
    Result := Integer(Seed mod Cardinal(ABound));
  end;

begin
  Seed := $C0FFEE11;
  Accepted := 0;
  Failure := '';
  for Round := 1 to 600 do
  begin
    Z := TZipSynth.Create;
    try
      if Next(4) = 0 then
        Z.AddText('lwpt.toml', DEMO_MANIFEST)
      else
        Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
      Entries := 1 + Next(5);
      for k := 1 to Entries do
      begin
        if Next(3) = 0 then Name := '' else Name := 'pkg/';
        Depth := 1 + Next(3);
        for j := 1 to Depth do
        begin
          if j > 1 then Name := Name + '/';
          Name := Name + COMPONENTS[Next(Length(COMPONENTS))];
        end;
        if Next(3) = 0 then
          Z.AddDirectory(Name + '/')
        else
          Z.AddText(Name, 'x');
      end;
      Input := Z.Build;
    finally
      Z.Free;
    end;
    try
      First := PreparePublicationArchive(Input);
    except
      on E: ELWPTArchiveError do Continue;
    end;
    Inc(Accepted);
    Second := PreparePublicationArchive(Input);
    if SHA256Hex(First.Archive) <> SHA256Hex(Second.Archive) then
      Failure := Failure + Format(' round %d: nondeterministic;', [Round]);
    try
      ScanTarGzipArchive(First.Archive, DefaultArchiveLimits);
    except
      on E: ELWPTArchiveError do
        Failure := Failure + Format(' round %d: %s;', [Round, E.Message]);
    end;
  end;
  Expect<string>(Failure).ToBe('');
  { Enough accepted cases for the property to mean something. }
  Expect<Boolean>(Accepted >= 50).ToBe(True);
end;

procedure TNormalizeGoldenSuite.SetupTests;
begin
  Test('input type comes from the leading bytes',
    TestDetectsInputByLeadingBytes);
  Test('Info-ZIP, 7-Zip, and Python zips match the golden hash',
    TestIndependentToolZipsMatchGolden);
  Test('a synthesised zip of the golden tree matches the golden hash',
    TestSynthesisedZipMatchesGolden);
  Test('order, timestamps, compression, descriptors, and comments do not '
    + 'change the bytes', TestIrrelevantDifferencesGiveSameBytes);
  Test('converting the same zip twice gives identical bytes',
    TestConvertingTwiceIsIdentical);
  Test('a multi-chunk zip with split and UTF-8 paths matches its golden hash',
    TestLargeZipMatchesGolden);
  Test('only Unix execute bits make a file 0755', TestExecuteBits);
  Test('the output passes the tar.gz contract unchanged',
    TestOutputIsACanonicalPackage);
  Test('every accepted random tree round-trips through the tar.gz scan',
    TestAcceptedOutputsRoundTrip);
end;

{ ---- entry rules -------------------------------------------------------- }

procedure TNormalizeEntrySuite.TestRejectsSpecialFiles;
begin
  Expect<string>(Rejection(AttributeZip('pkg/link', ZIP_SYNTH_UNIX,
    Cardinal($A1FF) shl 16), 'is a symbolic link')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/tty', ZIP_SYNTH_UNIX,
    Cardinal($21A4) shl 16), 'is a character device'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/disk', ZIP_SYNTH_UNIX,
    Cardinal($61A4) shl 16), 'is a block device')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/pipe', ZIP_SYNTH_UNIX,
    Cardinal($11A4) shl 16), 'is a FIFO')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/sock', ZIP_SYNTH_UNIX,
    Cardinal($C1A4) shl 16), 'is a socket')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/odd', ZIP_SYNTH_UNIX,
    Cardinal($E1A4) shl 16), 'not a regular file or directory'))
    .ToBe(ARCHIVE_INVALID);
  { Regular, directory, and unset types are accepted. }
  Expect<string>(Rejection(AttributeZip('pkg/d/', ZIP_SYNTH_UNIX,
    Cardinal($41ED) shl 16), '')).ToBe('accepted');
  Expect<string>(Rejection(AttributeZip('pkg/u', ZIP_SYNTH_UNIX, 0), ''))
    .ToBe('accepted');
end;

procedure TNormalizeEntrySuite.TestRejectsMsDosVolumeAndDirectoryMismatch;
begin
  Expect<string>(Rejection(AttributeZip('pkg/LABEL', ZIP_SYNTH_MSDOS, $08),
    'is a volume label')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/f', ZIP_SYNTH_MSDOS, $10),
    'directory attribute disagrees')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/d/', ZIP_SYNTH_MSDOS, $20),
    'directory attribute disagrees')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(AttributeZip('pkg/d/', ZIP_SYNTH_MSDOS, $10), ''))
    .ToBe('accepted');
  Expect<string>(Rejection(AttributeZip('pkg/f', ZIP_SYNTH_MSDOS, $21), ''))
    .ToBe('accepted');
  { Attributes from other hosts are ignored. }
  Expect<string>(Rejection(AttributeZip('pkg/f', 11, $FFFFFFFF), ''))
    .ToBe('accepted');
end;

procedure TNormalizeEntrySuite.TestRejectsAbsoluteAndDrivePaths;
begin
  Expect<string>(Rejection(DemoZip(['/etc/passwd']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['\windows\x']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['C:/x']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['c:x']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['/']), 'has an empty path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['//']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
end;

procedure TNormalizeEntrySuite.TestRejectsDotComponents;
begin
  Expect<string>(Rejection(DemoZip(['pkg/../x']), 'has a ".." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['..']), 'has a ".." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg\..\x']), 'has a ".." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/./x']), 'empty or "." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/./']), 'empty or "." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['./pkg/x']), 'empty or "." component'))
    .ToBe(ARCHIVE_INVALID);
end;

procedure TNormalizeEntrySuite.TestRejectsEmptyComponents;
begin
  Expect<string>(Rejection(DemoZip(['pkg//x']), 'empty or "." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a//']), 'empty or "." component'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['']), 'has an empty path'))
    .ToBe(ARCHIVE_INVALID);
  { The single terminal slash of a directory is not a component. }
  Expect<string>(Rejection(DemoZip(['pkg/a/']), '')).ToBe('accepted');
end;

procedure TNormalizeEntrySuite.TestRejectsDuplicateNames;
begin
  Expect<string>(Rejection(DemoZip(['pkg/a', 'pkg/a']), 'more than once'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/d/', 'pkg/d/']), 'more than once'))
    .ToBe(ARCHIVE_INVALID);
  { '\' reads as '/', so these name one path. }
  Expect<string>(Rejection(DemoZip(['pkg/a/b', 'pkg\a\b']), 'more than once'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/lwpt.toml']), 'more than once'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/', 'pkg/']),
    'top-level directory more than once')).ToBe(ARCHIVE_INVALID);
end;

procedure TNormalizeEntrySuite.TestComponentAndUstarLimits;
begin
  Expect<string>(Rejection(DemoZip(['pkg/' + StringOfChar('c', 256)]),
    'has a 256-byte component')).ToBe(ARCHIVE_INVALID);
  { Within the component limit but past ustar's 100-byte name field. }
  Expect<string>(Rejection(DemoZip(['pkg/' + StringOfChar('c', 101)]),
    'does not fit ustar')).ToBe(ARCHIVE_INVALID);
  { Implied directories are checked too: a 160-byte parent cannot be a
    ustar prefix. }
  Expect<string>(Rejection(DemoZip(['pkg/' + StringOfChar('p', 150) + '/q']),
    'does not fit ustar')).ToBe(ARCHIVE_INVALID);
  { A 100-byte last component fits the name field below the root prefix. }
  Expect<string>(Rejection(DemoZip(['pkg/' + StringOfChar('c', 100)]), ''))
    .ToBe('accepted');
  { The file itself would split, but its 141-byte parent directory cannot. }
  Expect<string>(Rejection(DemoZip(['pkg/' + StringOfChar('p', 140) + '/'
    + StringOfChar('n', 100)]), 'does not fit ustar')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/' + StringOfChar('p', 60) + '/'
    + StringOfChar('q', 60) + '/' + StringOfChar('n', 90)]), ''))
    .ToBe('accepted');
end;

procedure TNormalizeEntrySuite.TestRejectsInvalidNames;
begin
  Expect<string>(Rejection(DemoZip(['pkg/'#$C0#$AF'x']), 'not strict UTF-8'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/'#$FC'ber']), 'not strict UTF-8'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/'#$ED#$A0#$80]), 'not strict UTF-8'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a'#9'b']), 'not strict UTF-8'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a'#0'b']), 'not strict UTF-8'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/'#$C3#$BC'ber']), ''))
    .ToBe('accepted');
end;

procedure TNormalizeEntrySuite.TestRejectsDirectoryWithContent;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  i: Integer;
begin
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
    i := Z.AddText('pkg/d/', 'content', 0);
    E := Z.Entry(i);
    E.ExternalAttributes := ZIP_SYNTH_DIRECTORY_755;
    Z.SetEntry(i, E);
    Expect<string>(Rejection(Z.Build, 'is a directory with content'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TNormalizeEntrySuite.TestPackageRootLayouts;
var
  Z: TZipSynth;
begin
  { lwpt.toml at the zip root: every entry belongs to the package. }
  Z := TZipSynth.Create;
  try
    Z.AddText('lwpt.toml', DEMO_MANIFEST);
    Z.AddText('a/b.txt', 'b');
    Z.AddText('c.txt', 'c');
    Expect<string>(Rejection(Z.Build, '')).ToBe('accepted');
  finally
    Z.Free;
  end;
  Expect<string>(Rejection(DemoZip(['other/x']), 'single top-level'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['README']), 'single top-level'))
    .ToBe(ARCHIVE_INVALID);
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/sub/lwpt.toml', DEMO_MANIFEST);
    Z.AddText('pkg/a.txt', 'a');
    Expect<string>(Rejection(Z.Build, 'no lwpt.toml at its package root'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
  Z := TZipSynth.Create;
  try
    Z.AddText('a/lwpt.toml', DEMO_MANIFEST);
    Z.AddText('b/lwpt.toml', DEMO_MANIFEST);
    Expect<string>(Rejection(Z.Build, 'single top-level'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
  { A directory named lwpt.toml is not a manifest. }
  Z := TZipSynth.Create;
  try
    Z.AddDirectory('lwpt.toml/');
    Z.AddText('lwpt.toml/x', 'x');
    Expect<string>(Rejection(Z.Build, 'no lwpt.toml at its package root'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TNormalizeEntrySuite.TestRootStrippingRevalidatesPaths;
begin
  { Each name is relative until its top-level directory is removed. }
  Expect<string>(Rejection(DemoZip(['pkg/C:/x']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/c:x']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/C:/']), 'is an absolute path'))
    .ToBe(ARCHIVE_INVALID);
  { A drive-like name deeper down stays a plain component. }
  Expect<string>(Rejection(DemoZip(['pkg/sub/C:x']), '')).ToBe('accepted');
end;

procedure TNormalizeEntrySuite.SetupTests;
begin
  Test('rejects symlinks, devices, FIFOs, and sockets',
    TestRejectsSpecialFiles);
  Test('rejects MS-DOS volume labels and directory-bit mismatches',
    TestRejectsMsDosVolumeAndDirectoryMismatch);
  Test('rejects absolute and drive paths and a lone slash',
    TestRejectsAbsoluteAndDrivePaths);
  Test('rejects ".." and "." components', TestRejectsDotComponents);
  Test('rejects empty components and "a//"', TestRejectsEmptyComponents);
  Test('rejects duplicate names', TestRejectsDuplicateNames);
  Test('enforces the 255-byte component and ustar path limits',
    TestComponentAndUstarLimits);
  Test('rejects invalid UTF-8 and control characters',
    TestRejectsInvalidNames);
  Test('rejects a directory entry with content',
    TestRejectsDirectoryWithContent);
  Test('package root is the zip root or its single top-level directory',
    TestPackageRootLayouts);
  Test('paths below the package root are revalidated',
    TestRootStrippingRevalidatesPaths);
end;

{ ---- namespace rules ---------------------------------------------------- }

procedure TNormalizeNamespaceSuite.TestRejectsFileBesideDirectory;
begin
  Expect<string>(Rejection(DemoZip(['pkg/a', 'pkg/a/b']), 'is an ancestor'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a/b', 'pkg/a']), 'is an ancestor'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a/b/c', 'pkg/a']), 'is an ancestor'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a', 'pkg/a/']),
    'both a file and a directory')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/a/', 'pkg/a']),
    'both a file and a directory')).ToBe(ARCHIVE_INVALID);
end;

procedure TNormalizeNamespaceSuite.TestRejectsCaseCollisions;
begin
  Expect<string>(Rejection(DemoZip(['pkg/README.md', 'pkg/readme.md']),
    'differ only in ASCII case')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/A/x', 'pkg/a/y']),
    'differ only in ASCII case')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/Src/', 'pkg/src/a']),
    'differ only in ASCII case')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/LWPT.toml']),
    'aliases lwpt.toml')).ToBe(ARCHIVE_INVALID);
  { Only ASCII folds: these are distinct paths everywhere. }
  Expect<string>(Rejection(DemoZip(['pkg/'#$C3#$9C, 'pkg/'#$C3#$BC]), ''))
    .ToBe('accepted');
end;

procedure TNormalizeNamespaceSuite.TestAcceptsExplicitParentDirectory;
var
  Tar: TBytes;
begin
  Expect<string>(Rejection(DemoZip(['pkg/a/', 'pkg/a/b']), ''))
    .ToBe('accepted');
  Expect<string>(Rejection(DemoZip(['pkg/a/b', 'pkg/a/']), ''))
    .ToBe('accepted');
  { Explicit and implied parents produce the same bytes. }
  Expect<string>(NormalizedHash(DemoZip(['pkg/a/', 'pkg/a/b'])))
    .ToBe(NormalizedHash(DemoZip(['pkg/a/b'])));
  Tar := Gunzip(Normalized(DemoZip(['pkg/a/b'])));
  Expect<Char>(Chr(Tar[512 + 156])).ToBe('5');
end;

procedure TNormalizeNamespaceSuite.SetupTests;
begin
  Test('rejects a file beside a directory of the same path',
    TestRejectsFileBesideDirectory);
  Test('rejects ASCII case collisions, explicit and implied',
    TestRejectsCaseCollisions);
  Test('accepts an explicit directory matching an implied parent',
    TestAcceptsExplicitParentDirectory);
end;

{ ---- identity and dependencies ------------------------------------------ }

procedure TNormalizeIdentitySuite.TestRejectsInvalidIdentity;
begin
  Expect<string>(Rejection(DemoZip([],
    '[package]'#10'name = "Demo"'#10'version = "1.0.0"'#10), 'name'))
    .ToBe(ARCHIVE_INVALID_PACKAGE_NAME);
  Expect<string>(Rejection(DemoZip([],
    '[package]'#10'version = "1.0.0"'#10), 'name'))
    .ToBe(ARCHIVE_INVALID_PACKAGE_NAME);
  Expect<string>(Rejection(DemoZip([],
    '[package]'#10'name = 7'#10'version = "1.0.0"'#10), 'name'))
    .ToBe(ARCHIVE_INVALID_PACKAGE_NAME);
  Expect<string>(Rejection(DemoZip([], 'package = "demo"'#10), 'name'))
    .ToBe(ARCHIVE_INVALID_PACKAGE_NAME);
  Expect<string>(Rejection(DemoZip([],
    '[package]'#10'name = "demo"'#10'version = "v1.0.0"'#10), 'version'))
    .ToBe(ARCHIVE_INVALID_VERSION);
  Expect<string>(Rejection(DemoZip([],
    '[package]'#10'name = "demo"'#10'version = "1.0"'#10), 'version'))
    .ToBe(ARCHIVE_INVALID_VERSION);
  Expect<string>(Rejection(DemoZip([],
    '[package]'#10'name = "demo"'#10), 'version'))
    .ToBe(ARCHIVE_INVALID_VERSION);
  Expect<string>(Rejection(DemoZip([], '[package'#10), 'does not parse'))
    .ToBe(ARCHIVE_INVALID);
end;

function DependencyTarGz(const ADependencies: string): TBytes;
begin
  Result := Gzip(BuildTar([
    MakeDirectoryEntry('dep-1.0.0/'),
    MakeRegularFileEntry('dep-1.0.0/lwpt.toml', TextBytes(
      '[package]'#10'name = "dep"'#10'version = "1.0.0"'#10
      + ADependencies))]));
end;

procedure TNormalizeIdentitySuite.TestDependencyRefusalIsSeparable;
var
  Zip, TarGz: TBytes;
  Stream: TBytesStream;
  Manifest: TLWPTPublicationManifest;
begin
  Zip := DemoZip([], DEMO_MANIFEST
    + '[dependencies]'#10'lib = "owner/lib@^1.0.0"'#10);
  TarGz := DependencyTarGz(
    '[dependencies]'#10'lib = "owner/lib@^1.0.0"'#10);
  Expect<string>(Rejection(Zip, 'declares [dependencies]'))
    .ToBe(ARCHIVE_UNSUPPORTED_DEPENDENCIES);
  Expect<string>(Rejection(TarGz, 'declares [dependencies]'))
    .ToBe(ARCHIVE_UNSUPPORTED_DEPENDENCIES);
  { An empty table is still a declaration. }
  Expect<string>(Rejection(DependencyTarGz('[dependencies]'#10),
    'declares [dependencies]')).ToBe(ARCHIVE_UNSUPPORTED_DEPENDENCIES);
  Expect<string>(Rejection(DependencyTarGz(''), '')).ToBe('accepted');
  { The refusal is a policy step of its own: normalization and the scan
    succeed and report the declaration. }
  Stream := TBytesStream.Create(nil);
  try
    Manifest := NormalizeZipArchive(Zip, Stream, DefaultArchiveLimits);
    Expect<Boolean>(Manifest.DeclaresDependencies).ToBe(True);
    Expect<Boolean>(Stream.Size > 0).ToBe(True);
  finally
    Stream.Free;
  end;
  Manifest := ScanTarGzipArchive(TarGz, DefaultArchiveLimits);
  Expect<Boolean>(Manifest.DeclaresDependencies).ToBe(True);
end;

procedure TNormalizeIdentitySuite.SetupTests;
begin
  Test('rejects a missing or protocol-invalid identity',
    TestRejectsInvalidIdentity);
  Test('refuses [dependencies] as a separate policy step',
    TestDependencyRefusalIsSeparable);
end;

{ ---- bounds ------------------------------------------------------------- }

procedure TNormalizeLimitSuite.TestInputBound;
var
  Data: TBytes;
begin
  SetLength(Data, ARCHIVE_MAXIMUM_INPUT_BYTES + 1);
  FillChar(Data[0], Length(Data), 0);
  Data[0] := Ord('P');
  Data[1] := Ord('K');
  Data[2] := 3;
  Data[3] := 4;
  Expect<string>(Rejection(Data, 'zip input is 268435457 bytes'))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Data[0] := $1F;
  Data[1] := $8B;
  Expect<string>(Rejection(Data, 'tar.gz input is 268435457 bytes'))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

procedure TNormalizeLimitSuite.TestEntryAndDeclaredBounds;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  i: Integer;
begin
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
    for i := 1 to 10000 do
      Z.Add(RawByteString(Format('pkg/f%.5d', [i])), nil, 0);
    Expect<string>(Rejection(Z.Build, 'declares 10001 entries'))
      .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  finally
    Z.Free;
  end;
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
    i := Z.Add('pkg/bomb.bin', NoiseBytes(100, 7));
    E := Z.Entry(i);
    E.HasUncompressedSize := True;
    E.UncompressedSize := ARCHIVE_MAXIMUM_EXPANDED_BYTES;
    Z.SetEntry(i, E);
    Expect<string>(Rejection(Z.Build, 'uncompressed bytes; the limit'))
      .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  finally
    Z.Free;
  end;
end;

procedure TNormalizeLimitSuite.TestInflationPastDeclaredSize;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  i: Integer;
begin
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
    i := Z.Add('pkg/grows.bin', NoiseBytes(1000, 9));
    E := Z.Entry(i);
    E.HasUncompressedSize := True;
    E.UncompressedSize := 999;
    Z.SetEntry(i, E);
    Expect<string>(Rejection(Z.Build, 'inflates past its declared 999'))
      .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  finally
    Z.Free;
  end;
end;

procedure TNormalizeLimitSuite.TestOutputBound;
var
  Limits: TLWPTArchiveLimits;
  Input: TBytes;
  Size: Integer;
begin
  Input := LargeZip;
  Size := Length(Normalized(Input));
  Limits := DefaultArchiveLimits;
  Limits.MaximumOutputBytes := Size;
  Expect<string>(Rejection(Input, '', Limits)).ToBe('accepted');
  Limits.MaximumOutputBytes := Size - 1;
  Expect<string>(Rejection(Input, 'output passes the', Limits))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Limits.MaximumOutputBytes := 65536;
  Expect<string>(Rejection(Input, 'output passes the 65536-byte limit',
    Limits)).ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

procedure TNormalizeLimitSuite.TestTarGzipExpansionBound;
var
  Limits: TLWPTArchiveLimits;
  Input: TBytes;
begin
  Input := Gzip(BuildTar([
    MakeDirectoryEntry('demo-1.0.0/'),
    MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST)),
    MakeRegularFileEntry('demo-1.0.0/big.bin', NoiseBytes(100000, 3))]));
  Limits := DefaultArchiveLimits;
  { Headers, the two payloads, and the two end blocks. }
  Limits.MaximumExpandedBytes := Length(Gunzip(Input));
  Expect<string>(Rejection(Input, '', Limits)).ToBe('accepted');
  Limits.MaximumExpandedBytes := Length(Gunzip(Input)) - 1;
  Expect<string>(Rejection(Input, 'tar.gz expands past', Limits))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

procedure TNormalizeLimitSuite.TestOverlongPathRefusedBeforeTree;
var
  Name: RawByteString;
  i: Integer;
  Started: QWord;
begin
  { 'a/' 32,760 times: a 64 KiB name whose implied parents would total
    about 1 GiB. It is refused before a single parent is built. }
  Name := 'pkg/';
  for i := 1 to 32760 do Name := Name + 'a/';
  Name := Name + 'b';
  Started := GetTickCount64;
  Expect<string>(Rejection(DemoZip([Name]),
    'longer than any path ustar can hold')).ToBe(ARCHIVE_INVALID);
  Expect<Boolean>(GetTickCount64 - Started < 5000).ToBe(True);
  { Below the root, 254 bytes is the most any ustar path leaves. }
  Name := 'pkg/';
  for i := 1 to 127 do Name := Name + 'a/';
  Name := Name + 'b';
  Expect<string>(Rejection(DemoZip([Name]),
    '255 bytes, longer than any path ustar can hold'))
    .ToBe(ARCHIVE_INVALID);
end;

procedure TNormalizeLimitSuite.TestTreePathBudget;
var
  Z: TZipSynth;
  Chain: RawByteString;
  i: Integer;
  Limits: TLWPTArchiveLimits;
begin
  { 2,000 distinct 120-deep chains imply about 30 MiB of distinct parent
    paths: past the 16 MiB budget, which stops the build. }
  Chain := '';
  for i := 1 to 120 do Chain := Chain + 'a/';
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', DEMO_MANIFEST);
    for i := 1 to 2000 do
      Z.Add(RawByteString(Format('pkg/d%.4d/', [i])) + Chain + 'f', nil, 0);
    Expect<string>(Rejection(Z.Build, 'implied directories, pass 16777216'))
      .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  finally
    Z.Free;
  end;
  { The budget counts every distinct path once: 'demo' tree 'a', 'a/b',
    and 'lwpt.toml' total 13 bytes. }
  Limits := DefaultArchiveLimits;
  Limits.MaximumTreePathBytes := 13;
  Expect<string>(Rejection(DemoZip(['pkg/a/b']), '', Limits))
    .ToBe('accepted');
  Limits.MaximumTreePathBytes := 12;
  Expect<string>(Rejection(DemoZip(['pkg/a/b']), 'pass 12 bytes', Limits))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

function PaddedManifest(const ALength: Integer): string;
begin
  Result := DEMO_MANIFEST + '#';
  Result := Result + StringOfChar('x', ALength - Length(Result) - 1) + #10;
end;

procedure TNormalizeLimitSuite.TestManifestByteBudget;
var
  Limits: TLWPTArchiveLimits;
  Big: string;
begin
  { A comment makes the manifest large but trivially compressible: it is
    refused by its declared size before it is decoded or scanned. }
  Big := PaddedManifest(ARCHIVE_MAXIMUM_MANIFEST_BYTES + 1);
  Expect<string>(Rejection(DemoZip([], Big), 'lwpt.toml is 262145 bytes'))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Expect<string>(Rejection(Gzip(BuildTar([MakeRegularFileEntry(
    'demo-1.0.0/lwpt.toml', TextBytes(Big))])), 'lwpt.toml is 262145 bytes'))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Expect<string>(Rejection(DemoZip([], PaddedManifest(
    ARCHIVE_MAXIMUM_MANIFEST_BYTES)), '')).ToBe('accepted');
  Limits := DefaultArchiveLimits;
  Limits.MaximumManifestBytes := 100;
  Expect<string>(Rejection(DemoZip([], PaddedManifest(100)), '', Limits))
    .ToBe('accepted');
  Expect<string>(Rejection(Gzip(BuildTar([MakeRegularFileEntry(
    'demo-1.0.0/lwpt.toml', TextBytes(PaddedManifest(100)))])), '', Limits))
    .ToBe('accepted');
  Expect<string>(Rejection(DemoZip([], PaddedManifest(101)),
    'lwpt.toml is 101 bytes', Limits)).ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Expect<string>(Rejection(Gzip(BuildTar([MakeRegularFileEntry(
    'demo-1.0.0/lwpt.toml', TextBytes(PaddedManifest(101)))])),
    'lwpt.toml is 101 bytes', Limits)).ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

function ArrayManifest(const AItems: Integer): string;
var
  i: Integer;
begin
  Result := DEMO_MANIFEST + 'values = [';
  for i := 1 to AItems do
    Result := Result + '0,';
  Result := Result + ']'#10;
end;

procedure TNormalizeLimitSuite.TestManifestNodeBudget;
begin
  { A flat array within the byte budget but past the node budget. }
  Expect<Boolean>(Length(ArrayManifest(20000)) < ARCHIVE_MAXIMUM_MANIFEST_BYTES)
    .ToBe(True);
  Expect<string>(Rejection(DemoZip([], ArrayManifest(20000)),
    'exceeds its parse budget')).ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Expect<string>(Rejection(Gzip(BuildTar([MakeRegularFileEntry(
    'demo-1.0.0/lwpt.toml', TextBytes(ArrayManifest(20000)))])),
    'exceeds its parse budget')).ToBe(ARCHIVE_LIMIT_EXCEEDED);
  Expect<string>(Rejection(DemoZip([], ArrayManifest(1000)), ''))
    .ToBe('accepted');
end;

procedure TNormalizeLimitSuite.SetupTests;
begin
  Test('refuses zip and tar.gz input one byte over 256 MiB', TestInputBound);
  Test('refuses 10,001 entries and a 1 GiB declared expansion',
    TestEntryAndDeclaredBounds);
  Test('refuses an entry that inflates past its declared size',
    TestInflationPastDeclaredSize);
  Test('stops output that passes the output bound', TestOutputBound);
  Test('bounds a tar.gz''s expanded size', TestTarGzipExpansionBound);
  Test('refuses an over-long path before building its parents',
    TestOverlongPathRefusedBeforeTree);
  Test('bounds the bytes of the normalized tree''s paths',
    TestTreePathBudget);
  Test('bounds lwpt.toml''s size before decoding it',
    TestManifestByteBudget);
  Test('bounds lwpt.toml''s TOML node count', TestManifestNodeBudget);
end;

{ ---- manifest aliases --------------------------------------------------- }

{ Rewrites an entry's type flag and restores its header checksum. }
function Retyped(const AEntry: TBytes; const AType: Char): TBytes;
var
  Sum, i: Integer;
  Digits: string;
begin
  Result := System.Copy(AEntry);
  Result[156] := Ord(AType);
  FillChar(Result[148], 8, Ord(' '));
  Sum := 0;
  for i := 0 to 511 do Inc(Sum, Result[i]);
  Digits := OctStr(Sum, 6);
  Move(Digits[1], Result[148], 6);
  Result[154] := 0;
end;


const
  OTHER_MANIFEST = '[package]'#10'name = "other"'#10'version = "9.9.9"'#10
    + '[dependencies]'#10'lib = "owner/lib@^1.0.0"'#10;

function ManifestPairTarGz(const ASecond: TBytes): TBytes;
begin
  Result := Gzip(BuildTar([
    MakeDirectoryEntry('demo-1.0.0/'),
    MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST)),
    ASecond]));
end;

procedure TManifestAliasSuite.TestTarManifestOverwriteIsRefused;
var
  Scratch, Archive, Installed: string;
  Input: TBytes;
begin
  { The installer expands 'demo-1.0.0/./lwpt.toml' to the manifest's own
    destination, so the second entry replaces the first: installing this
    archive yields "other" 9.9.9 with a dependency, not the "demo" identity
    a literal comparison would have inspected. }
  Input := ManifestPairTarGz(MakeRegularFileEntry('demo-1.0.0/./lwpt.toml',
    TextBytes(OTHER_MANIFEST)));
  Scratch := CreateScratchRoot('archive-normalize-overwrite');
  try
    Archive := IncludeTrailingPathDelimiter(Scratch) + 'alias.tar.gz';
    WriteBytesToFile(Archive, Input);
    ExtractArchive(Archive, IncludeTrailingPathDelimiter(Scratch) + 'out');
    Installed := ReadBinaryFile(IncludeTrailingPathDelimiter(Scratch)
      + 'out' + PathDelim + 'lwpt.toml');
    Expect<string>(Installed).ToBe(OTHER_MANIFEST);
  finally
    RecursiveDelete(Scratch);
  end;
  Expect<string>(Rejection(Input, 'lwpt.toml appears more than once'))
    .ToBe(ARCHIVE_INVALID);
  { An empty component makes the path absolute once the root is stripped. }
  Expect<string>(Rejection(ManifestPairTarGz(MakeRegularFileEntry(
    'demo-1.0.0//lwpt.toml', TextBytes(OTHER_MANIFEST))),
    'escapes the extraction root')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(ManifestPairTarGz(MakeRegularFileEntry(
    'demo-1.0.0/./././lwpt.toml', TextBytes(OTHER_MANIFEST))),
    'lwpt.toml appears more than once')).ToBe(ARCHIVE_INVALID);
end;

procedure TManifestAliasSuite.TestTarManifestAliases;
const
  { Typed arrays: FPC sizes an untyped string-array constructor in a for-in
    loop to its first element. }
  ALIASES: array[0..5] of string = ('LWPT.TOML', 'Lwpt.toml', 'lwpt.toml.',
    'lwpt.toml ', 'lwpt.toml..', 'lwpt.toml::$DATA');
  { NTFS 8.3 short names, simple and checksum-based, and names HFS+
    compares equal to lwpt.toml by ignoring a code point (U+200C, U+200F,
    U+202A, U+202E, U+206A, U+206F, U+FEFF). }
  SHORT_NAMES: array[0..3] of string = ('LWPT~1.TOM', 'lwpt~2.tom',
    'LW1A2B~1.TOM', 'LWC3F4~9.TOM');
  HFS_IGNORABLE: array[0..6] of string = ('lwpt'#$E2#$80#$8C'.toml',
    'lwpt.toml'#$E2#$80#$8F, #$E2#$80#$AA'lwpt.toml', 'lw'#$E2#$80#$AE'pt.toml',
    'lwpt'#$E2#$81#$AA'.toml', 'lwpt.tom'#$E2#$81#$AF'l',
    #$EF#$BB#$BF'lwpt.toml');
  DISTINCT: array[0..4] of string = ('sub/lwpt.toml', 'lwpt.toml.bak',
    'lwpt.tomlx', 'xlwpt.toml', 'sub/LWPT.TOML');
var
  Spelling: string;
begin
  { Links and directories at the manifest's destination. }
  Expect<string>(Rejection(ManifestPairTarGz(MakeSymlinkEntry(
    'demo-1.0.0/./lwpt.toml', 'README')), 'is not a regular file'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(ManifestPairTarGz(Retyped(MakeSymlinkEntry(
    'demo-1.0.0/lwpt.toml', 'README'), '1')), 'is not a regular file'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(ManifestPairTarGz(MakeDirectoryEntry(
    'demo-1.0.0/lwpt.toml/')), 'is not a regular file'))
    .ToBe(ARCHIVE_INVALID);
  { Spellings a case-insensitive or Windows file system resolves to the
    manifest. }
  for Spelling in ALIASES do
    Expect<string>(Rejection(ManifestPairTarGz(MakeRegularFileEntry(
      'demo-1.0.0/' + Spelling, TextBytes(OTHER_MANIFEST))),
      'aliases lwpt.toml')).ToBe(ARCHIVE_INVALID);
  for Spelling in SHORT_NAMES do
    Expect<string>(Rejection(ManifestPairTarGz(MakeRegularFileEntry(
      'demo-1.0.0/' + Spelling, TextBytes(OTHER_MANIFEST))),
      'has the 8.3 short-name component')).ToBe(ARCHIVE_INVALID);
  for Spelling in HFS_IGNORABLE do
    Expect<string>(Rejection(ManifestPairTarGz(MakeRegularFileEntry(
      'demo-1.0.0/' + Spelling, TextBytes(OTHER_MANIFEST))),
      'holds a code point HFS+ ignores')).ToBe(ARCHIVE_INVALID);
  { An alias before the manifest is refused too. }
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeRegularFileEntry('demo-1.0.0/LWPT.TOML', TextBytes(OTHER_MANIFEST)),
    MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST))])),
    'aliases lwpt.toml')).ToBe(ARCHIVE_INVALID);
  { Names that no platform resolves to the root manifest. }
  for Spelling in DISTINCT do
    Expect<string>(Rejection(ManifestPairTarGz(MakeRegularFileEntry(
      'demo-1.0.0/' + Spelling, TextBytes(OTHER_MANIFEST))), ''))
      .ToBe('accepted');
end;

procedure TManifestAliasSuite.TestZipManifestAliases;
const
  ALIASES: array[0..4] of RawByteString = ('pkg/lwpt.toml.',
    'pkg/lwpt.toml ', 'pkg/lwpt.toml:x', 'pkg/LWPT.TOML/',
    'pkg/lwpt.toml./x');
var
  Spelling: RawByteString;
begin
  for Spelling in ALIASES do
    Expect<string>(Rejection(DemoZip([Spelling]), 'aliases lwpt.toml'))
      .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/LW1A2B~1.TOM']),
    'has the 8.3 short-name component')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/lwpt'#$E2#$80#$8C'.toml']),
    'holds a code point HFS+ ignores')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoZip(['pkg/lwpt.toml.bak']), ''))
    .ToBe('accepted');
end;

{ The rules hold for every entry, not only spellings of the manifest: any
  name that a platform could fold onto another is refused. }
procedure TManifestAliasSuite.TestPlatformAliasesInEveryEntry;
const
  REFUSED: array[0..6] of RawByteString = ('pkg/PROGRA~1/x',
    'pkg/src/NAME~1', 'pkg/docs/AB12CD~3.MD', 'pkg/~1', 'pkg/a~0b.txt',
    'pkg/docs/a'#$EF#$BB#$BF'.md', 'pkg/'#$E2#$80#$8D'src/x.pas');
  ACCEPTED: array[0..6] of RawByteString = ('pkg/a~b', 'pkg/name~x.txt',
    'pkg/verylongn~1.txt', 'pkg/a.b~1', 'pkg/~', 'pkg/a'#$E2#$80#$8B'b',
    'pkg/a'#$E2#$80#$A9'b');
var
  Name: RawByteString;
begin
  for Name in REFUSED do
  begin
    Expect<string>(Rejection(DemoZip([Name]), 'zip entry'))
      .ToBe(ARCHIVE_INVALID);
    Expect<string>(Rejection(Gzip(BuildTar([
      MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST)),
      MakeRegularFileEntry('demo-1.0.0/' + System.Copy(Name, 5, MaxInt),
        TextBytes('x'))])), 'entry "demo-1.0.0/')).ToBe(ARCHIVE_INVALID);
  end;
  { A tilde past the eighth character, without a digit, or only in the
    extension, and zero-width code points HFS+ does not ignore. }
  for Name in ACCEPTED do
    Expect<string>(Rejection(DemoZip([Name]), '')).ToBe('accepted');
end;

procedure TManifestAliasSuite.SetupTests;
begin
  Test('a tar entry that would overwrite the inspected manifest is refused',
    TestTarManifestOverwriteIsRefused);
  Test('tar links, directories, and platform spellings of lwpt.toml',
    TestTarManifestAliases);
  Test('zip spellings of lwpt.toml', TestZipManifestAliases);
  Test('HFS+-ignorable and 8.3 short names are refused in every entry',
    TestPlatformAliasesInEveryEntry);
end;

{ ---- tar.gz scan -------------------------------------------------------- }

function DemoTarGz(const AEntries: array of TBytes): TBytes;
var
  Entries: TByteArrays;
  i: Integer;
begin
  SetLength(Entries, Length(AEntries) + 2);
  Entries[0] := MakeDirectoryEntry('demo-1.0.0/');
  Entries[1] := MakeRegularFileEntry('demo-1.0.0/lwpt.toml',
    TextBytes(DEMO_MANIFEST));
  for i := 0 to High(AEntries) do
    Entries[i + 2] := AEntries[i];
  Result := Gzip(BuildTar(Entries));
end;

procedure TTarGzipScanSuite.TestAcceptsGitArchiveUnchanged;
var
  Input: TBytes;
  Prepared: TLWPTPublicationArchive;
begin
  Input := ReadFixture('git-archive.tar.gz');
  Prepared := PreparePublicationArchive(Input);
  Expect<Boolean>(Prepared.Kind = akTarGzip).ToBe(True);
  Expect<string>(Prepared.Manifest.Name + '@' + Prepared.Manifest.Version)
    .ToBe('golden@1.0.0');
  { Uploaded exactly as given. }
  Expect<string>(SHA256Hex(Prepared.Archive)).ToBe(SHA256Hex(Input));
end;

procedure TTarGzipScanSuite.TestAcceptsCanonicalOutput;
begin
  Expect<string>(Rejection(Normalized(LargeZip), '')).ToBe('accepted');
end;

procedure TTarGzipScanSuite.TestAcceptsInstallerSupportedShapes;
var
  Long: string;
begin
  Long := 'demo-1.0.0/' + StringOfChar('l', 120) + '/'
    + StringOfChar('m', 120) + '.pas';
  Expect<string>(Rejection(DemoTarGz([
    MakeGnuLongNameRegularFileEntry(Long, TextBytes('long')),
    MakeRegularFileEntry('demo-1.0.0/' + StringOfChar('p', 120) + '/x.txt',
      TextBytes('prefix')),
    MakeSymlinkEntry('demo-1.0.0/src/link', '../lwpt.toml'),
    Retyped(MakeSymlinkEntry('demo-1.0.0/hard', 'lwpt.toml'), '1')]), ''))
    .ToBe('accepted');
  { A pax global header before the top-level directory, as git archive
    writes. }
  Expect<string>(Rejection(Gzip(BuildTar([
    Retyped(MakeRegularFileEntry('pax_global_header',
      TextBytes('52 comment=0123456789012345678901234567890123456789'#10)),
      'g'),
    MakeDirectoryEntry('demo-1.0.0/'),
    MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST))])),
    '')).ToBe('accepted');
  { The top-level directory need not have its own entry. }
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST))])),
    '')).ToBe('accepted');
end;

procedure TTarGzipScanSuite.TestRejectsTraversal;
begin
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry(
    'demo-1.0.0/../../etc/x', TextBytes('x'))]), 'escapes the extraction'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry(
    'demo-1.0.0/a/../../x', TextBytes('x'))]), 'escapes the extraction'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry(
    'demo-1.0.0//etc/x', TextBytes('x'))]), 'escapes the extraction'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry(
    'demo-1.0.0/C:/x', TextBytes('x'))]), 'escapes the extraction'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeGnuLongNameRegularFileEntry(
    'demo-1.0.0/' + StringOfChar('a', 100) + '/../../x', TextBytes('x'))]),
    'escapes the extraction')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeRegularFileEntry('/demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST))])),
    'is an absolute path')).ToBe(ARCHIVE_INVALID);
end;

procedure TTarGzipScanSuite.TestRejectsEscapingLinks;
begin
  Expect<string>(Rejection(DemoTarGz([MakeSymlinkEntry('demo-1.0.0/a/link',
    '../../x')]), 'link target escapes')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeSymlinkEntry('demo-1.0.0/link',
    '/etc/passwd')]), 'link target escapes')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([Retyped(MakeSymlinkEntry(
    'demo-1.0.0/hard', '../outside'), '1')]), 'link target escapes'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeSymlinkEntry('demo-1.0.0/link',
    'a\..\..\x')]), 'link target escapes')).ToBe(ARCHIVE_INVALID);
end;

procedure TTarGzipScanSuite.TestRejectsLongComponent;
begin
  Expect<string>(Rejection(DemoTarGz([MakeGnuLongNameRegularFileEntry(
    'demo-1.0.0/' + StringOfChar('c', 256), TextBytes('x'))]),
    'has a 256-byte name component')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeGnuLongNameRegularFileEntry(
    'demo-1.0.0/' + StringOfChar('c', 255), TextBytes('x'))]), ''))
    .ToBe('accepted');
end;

procedure TTarGzipScanSuite.TestRequiresOneTopLevelDirectory;
begin
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry('other/x',
    TextBytes('x'))]), 'exactly one top-level directory'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry('README',
    TextBytes('x'))]), 'exactly one top-level directory'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeRegularFileEntry('lwpt.toml', TextBytes(DEMO_MANIFEST))])),
    'not inside the top-level directory')).ToBe(ARCHIVE_INVALID);
end;

procedure TTarGzipScanSuite.TestRequiresOneRegularManifest;
begin
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeDirectoryEntry('demo-1.0.0/'),
    MakeRegularFileEntry('demo-1.0.0/README', TextBytes('x'))])),
    'has no lwpt.toml')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeRegularFileEntry('demo-1.0.0/sub/lwpt.toml', TextBytes(DEMO_MANIFEST))])),
    'has no lwpt.toml')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(BuildTar([
    MakeRegularFileEntry('demo-1.0.0/real.toml', TextBytes(DEMO_MANIFEST)),
    MakeSymlinkEntry('demo-1.0.0/lwpt.toml', 'real.toml')])),
    'lwpt.toml is not a regular file')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(DemoTarGz([MakeRegularFileEntry(
    'demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST))]),
    'appears more than once')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(BuildTar([])), 'has no lwpt.toml'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(BuildTar([MakeRegularFileEntry(
    'demo-1.0.0/lwpt.toml', TextBytes('[package]'#10'name = "Demo"'#10
    + 'version = "1.0.0"'#10))])), 'name'))
    .ToBe(ARCHIVE_INVALID_PACKAGE_NAME);
end;

procedure TTarGzipScanSuite.TestRejectsCorruptStreams;
var
  Tar, Input: TBytes;
begin
  { A tar cut inside an entry's payload. }
  Tar := BuildTar([MakeDirectoryEntry('demo-1.0.0/'),
    MakeRegularFileEntry('demo-1.0.0/lwpt.toml', TextBytes(DEMO_MANIFEST)),
    MakeRegularFileEntry('demo-1.0.0/big', NoiseBytes(2000, 5))]);
  Expect<string>(Rejection(Gzip(System.Copy(Tar, 0, 3 * 512 + 700)),
    'ends inside an entry')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(Gzip(System.Copy(Tar, 0, 3 * 512 + 100)),
    'ends inside an entry')).ToBe(ARCHIVE_INVALID);
  { A damaged gzip trailer. }
  Input := Gzip(Tar);
  Input[Length(Input) - 5] := Input[Length(Input) - 5] xor 1;
  Expect<string>(Rejection(Input, 'CRC-32 mismatch')).ToBe(ARCHIVE_INVALID);
  Input := Gzip(Tar);
  Expect<string>(Rejection(System.Copy(Input, 0, Length(Input) - 20),
    'truncated')).ToBe(ARCHIVE_INVALID);
end;

procedure TTarGzipScanSuite.SetupTests;
begin
  Test('accepts a git archive tar.gz and uploads it unchanged',
    TestAcceptsGitArchiveUnchanged);
  Test('accepts the canonical output of a zip', TestAcceptsCanonicalOutput);
  Test('accepts long names, prefixes, internal links, and pax globals',
    TestAcceptsInstallerSupportedShapes);
  Test('rejects entries that escape the extraction root',
    TestRejectsTraversal);
  Test('rejects link targets that escape the extraction root',
    TestRejectsEscapingLinks);
  Test('rejects a name component over 255 bytes', TestRejectsLongComponent);
  Test('requires exactly one top-level directory',
    TestRequiresOneTopLevelDirectory);
  Test('requires one regular lwpt.toml in the top-level directory',
    TestRequiresOneRegularManifest);
  Test('rejects truncated and corrupt streams', TestRejectsCorruptStreams);
end;

begin
  TestRunnerProgram.AddSuite(TNormalizeGoldenSuite.Create(
    'LWPT.ArchiveNormalize determinism'));
  TestRunnerProgram.AddSuite(TNormalizeEntrySuite.Create(
    'LWPT.ArchiveNormalize entries'));
  TestRunnerProgram.AddSuite(TNormalizeNamespaceSuite.Create(
    'LWPT.ArchiveNormalize namespace'));
  TestRunnerProgram.AddSuite(TNormalizeIdentitySuite.Create(
    'LWPT.ArchiveNormalize identity'));
  TestRunnerProgram.AddSuite(TNormalizeLimitSuite.Create(
    'LWPT.ArchiveNormalize bounds'));
  TestRunnerProgram.AddSuite(TManifestAliasSuite.Create(
    'LWPT.ArchiveNormalize manifest aliases'));
  TestRunnerProgram.AddSuite(TTarGzipScanSuite.Create(
    'LWPT.ArchiveNormalize tar.gz scan'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
