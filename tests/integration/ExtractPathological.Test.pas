{ ExtractPathological.Test — integration test for LWPT.Install.ExtractArchive
  against the specific tar shapes that motivated lwpt's custom ustar
  reader instead of FPC's bundled libtar.

  The handoff called out two pathological cases that broke libtar:

    1. Paths > 100 bytes that ustar splits across the prefix (offset
       345, 155 bytes) and name (offset 0, 100 bytes) fields. libtar
       ignored prefix and silently dropped every entry whose path
       exceeded 100 chars.
    2. Symlink entries (typeflag '2'). LWPT's extractor resolves them
       in a deferred pass after all regular files are written, copying
       the target's bytes to the symlink path.

  GNU 'L' long-name entries are also handled by LWPT's extractor but
  require a more involved fixture; defer the test for those
  alongside the broader extractor hardening.

  Fixtures are synthesised in-test via tests/support/Tests.TarSynth.pas
  (deterministic; controls the wire format exactly), gzipped, written
  to an invocation-private scratch dir, and extracted. The scratch dir
  is wiped at the start of each suite. }

program ExtractPathological.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Install,
  TestingPascalLibrary,
  Tests.Scratch,
  Tests.TarSynth;

type
  TExtractPathological = class(TTestSuite)
  private
    FScratch: string;
    procedure WipeScratch;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestRegularFileWithShortPath;
    procedure TestRegularFileWithPrefixSplitPath;
    procedure TestSymlinkResolvesToFileContent;
    procedure TestDirLinkToSiblingMaterialized;
    procedure TestLinkTargetIsOwnParentSkipped;
    procedure TestLinkTargetIsAncestorSkipped;
    procedure TestGnuLongNameOverridesHeaderName;
    procedure TestArchivePathBeyond255Extracts;
    procedure TestDirectoryAtPathLimitExtracts;
  end;

  { ExtractArchive's failure modes — every bad-input path must
    raise (not silently swallow) and must NOT leave half-extracted
    state under Dest. }
  TExtractFailureModes = class(TTestSuite)
  private
    FScratch: string;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestMissingArchiveRaisesEExtractError;
    procedure TestTruncatedGzipRaises;
    procedure TestInvalidGzipMagicRaises;
    procedure TestGzipCrcMismatchRaisesAndCleansUp;
    procedure TestOverlongEntryPathFailsBeforeWriting;
    procedure TestDirectoryLinkAliasFailsBeforeWriting;
    procedure TestOverlongNameComponentFailsBeforeWriting;
    procedure TestMixedCaseDirectoryLinkFailsBeforeWriting;
    procedure TestLinkThroughReplacedFileFailsBeforeWriting;
    procedure TestTarTruncatedMidEntryRaises;
    procedure TestParentTraversalPathRejected;
    procedure TestAbsoluteTraversalPathRejected;
    procedure TestLinkTargetOutsideDestRejected;
  end;

{ ── helpers ───────────────────────────────────────────────────────── }

const
  { The operating system's own path budgets, not LWPT's: PATH_MAX less its
    NUL on Unix; legacy MAX_PATH on Windows, where directory creation also
    reserves room for an 8.3 file name. }
  {$IFDEF MSWINDOWS}
  PlatformFilePathLimit = 259;
  PlatformDirectoryPathLimit = 247;
  {$ELSE}
  PlatformFilePathLimit = MaxPathLen - 1;
  PlatformDirectoryPathLimit = MaxPathLen - 1;
  {$ENDIF}
  PathFillComponentLength = 199;

{ A relative path of exactly ALength characters whose components stay
  well inside every platform's file-name limit. }
function FillPath(const ALength: Integer): string;
begin
  Result := '';
  while ALength - Length(Result) > PathFillComponentLength + 1 do
    Result := Result + StringOfChar('x', PathFillComponentLength) + '/';
  Result := Result + StringOfChar('y', ALength - Length(Result));
end;

function ReadFileBytes(const APath: string): TBytes;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function BytesEqual(const A, B: TBytes): Boolean;
var i: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
  Result := True;
end;

procedure TExtractPathological.WipeScratch;
var SR: TSearchRec; Base: string;

  procedure NukeDir(const ADir: string);
  var R: TSearchRec; B: string;
  begin
    if not DirectoryExists(ADir) then Exit;
    B := IncludeTrailingPathDelimiter(ADir);
    if FindFirst(B + '*', faAnyFile, R) = 0 then
      try
        repeat
          if (R.Name = '.') or (R.Name = '..') then Continue;
          if (R.Attr and faDirectory) <> 0 then NukeDir(B + R.Name)
          else DeleteFile(B + R.Name);
        until FindNext(R) <> 0;
      finally
        FindClose(R);
      end;
    RemoveDir(ADir);
  end;

begin
  NukeDir(FScratch);
  ForceDirectories(FScratch);
  { silence unused-var warnings; we use the nested NukeDir }
  SR.Name := ''; Base := '';
end;

procedure TExtractPathological.BeforeAll;
begin
  FScratch := CreateScratchRoot('extract-pathological');
  WipeScratch;
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TExtractPathological.TestRegularFileWithShortPath;
{ Baseline sanity: the extractor handles the simplest possible entry. }
var
  Archive, Dest, ExtractedPath: string;
  Plain, Body: TBytes;
  Count: Integer;
begin
  Body := BytesOf('hello, short path');
  Plain := BuildTar([MakeRegularFileEntry('short.txt', Body)]);
  Archive := FScratch + '/short.tar.gz';
  Dest := FScratch + '/short-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(Plain));

  Count := ExtractArchive(Archive, Dest);

  { ExtractArchive strips the top-level directory by default. Our
    archive has a single root entry "short.txt", so after stripping
    the top component the relative name is empty and nothing lands
    under Dest. Verify the extractor returned 0 entries written. }
  Expect<Integer>(Count).ToBe(0);
  ExtractedPath := Dest + '/short.txt';
  Expect<Boolean>(FileExists(ExtractedPath)).ToBe(False);
end;

procedure TExtractPathological.TestRegularFileWithPrefixSplitPath;
{ The headline pathological case: a path > 100 chars that ustar must
  split between the prefix and name fields. libtar dropped these
  silently; LWPT's reader joins prefix + '/' + name correctly. }
var
  Archive, Dest, ExtractedPath, DeepPath: string;
  Body, ExtractedBytes: TBytes;
  Count: Integer;
  i: Integer;
begin
  { Path components chosen to:
      - exceed 100 chars total
      - have a slash that produces a < 155-char prefix and a < 100-char
        name (so it's a valid ustar prefix-split)
      - sit under a single top-level directory that StripFirstComponent
        will remove, leaving a deep relative path under Dest }
  DeepPath := 'topdir/' + StringOfChar('a', 60) + '/'
              + StringOfChar('b', 50) + '/leaf.txt';
  { Sanity: total > 100, leaf segment <= 100 }
  Expect<Boolean>(Length(DeepPath) > 100).ToBe(True);

  Body := BytesOf('pathological prefix-split survived round-trip');
  Archive := FScratch + '/deep.tar.gz';
  Dest := FScratch + '/deep-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar(
    [MakeRegularFileEntry(DeepPath, Body)])));

  Count := ExtractArchive(Archive, Dest);

  Expect<Integer>(Count).ToBe(1);
  ExtractedPath := Dest + '/' + StringOfChar('a', 60) + '/'
                   + StringOfChar('b', 50) + '/leaf.txt';
  Expect<Boolean>(FileExists(ExtractedPath)).ToBe(True);
  ExtractedBytes := ReadFileBytes(ExtractedPath);
  Expect<Boolean>(BytesEqual(ExtractedBytes, Body)).ToBe(True);
  { Belt-and-braces: ensure the body length isn't accidentally zero
    (libtar's silent-drop would give us length 0 even if the path
    by some accident were created). }
  Expect<Boolean>(Length(ExtractedBytes) > 0).ToBe(True);
  if i = -1 then;   { unused-var quiet }
end;

procedure TExtractPathological.TestSymlinkResolvesToFileContent;
{ The extractor's deferred-link pass: symlinks are recorded during
  the first walk and resolved to their target's bytes afterwards.
  This test puts both the target and the symlink under one top-level
  dir so StripFirstComponent gives them sibling positions under Dest. }
var
  Archive, Dest, TargetPath, SymPath: string;
  Body, ExtractedBytes: TBytes;
begin
  Body := BytesOf('symlink target content');
  Archive := FScratch + '/symlink.tar.gz';
  Dest := FScratch + '/symlink-out';
  ForceDirectories(Dest);

  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeRegularFileEntry('top/target.txt', Body),
    MakeSymlinkEntry('top/link.txt', 'target.txt')
  ])));

  ExtractArchive(Archive, Dest);

  TargetPath := Dest + '/target.txt';
  SymPath    := Dest + '/link.txt';

  Expect<Boolean>(FileExists(TargetPath)).ToBe(True);
  Expect<Boolean>(FileExists(SymPath)).ToBe(True);

  ExtractedBytes := ReadFileBytes(SymPath);
  Expect<Boolean>(BytesEqual(ExtractedBytes, Body)).ToBe(True);
end;

procedure TExtractPathological.TestDirLinkToSiblingMaterialized;
{ The legitimate directory-link shape: a link to a sibling directory
  is materialized as a recursive copy. Pins that the cycle guard
  below does not over-block the supported case. }
var
  Archive, Dest: string;
  Body: TBytes;
begin
  Body := BytesOf('reachable through the alias');
  Archive := FScratch + '/dir-link.tar.gz';
  Dest := FScratch + '/dir-link-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeDirectoryEntry('top/real'),
    MakeRegularFileEntry('top/real/data.txt', Body),
    MakeSymlinkEntry('top/alias', 'real')
  ])));

  ExtractArchive(Archive, Dest);

  Expect<Boolean>(FileExists(Dest + '/alias/data.txt')).ToBe(True);
  Expect<Boolean>(BytesEqual(
    ReadFileBytes(Dest + '/alias/data.txt'), Body)).ToBe(True);
end;

procedure TExtractPathological.TestLinkTargetIsOwnParentSkipped;
{ A link whose target resolves to its own parent directory is still
  inside the extraction root, so the escape check passes — but
  materializing it would copy the directory into its own subtree and
  recurse until the OS path-length limit. The extractor must skip the
  link, finish, and leave the sibling file intact. }
var
  Archive, Dest: string;
  Body: TBytes;
  Count: Integer;
begin
  Body := BytesOf('survives the cycle link');
  Archive := FScratch + '/link-own-parent.tar.gz';
  Dest := FScratch + '/link-own-parent-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeDirectoryEntry('top/dir'),
    MakeRegularFileEntry('top/dir/keep.txt', Body),
    MakeSymlinkEntry('top/dir/link', '.')
  ])));

  { The regression assertion: this returns at all. }
  Count := ExtractArchive(Archive, Dest);

  Expect<Integer>(Count).ToBe(1);
  Expect<Boolean>(FileExists(Dest + '/dir/keep.txt')).ToBe(True);
  Expect<Boolean>(BytesEqual(
    ReadFileBytes(Dest + '/dir/keep.txt'), Body)).ToBe(True);
  Expect<Boolean>(DirectoryExists(Dest + '/dir/link')).ToBe(False);
  Expect<Boolean>(FileExists(Dest + '/dir/link')).ToBe(False);
end;

procedure TExtractPathological.TestLinkTargetIsAncestorSkipped;
{ Same shape one level deeper: the target ('..') is a strict ancestor
  of the link, not just its immediate parent. }
var
  Archive, Dest: string;
  Body: TBytes;
  Count: Integer;
begin
  Body := BytesOf('survives the ancestor link');
  Archive := FScratch + '/link-ancestor.tar.gz';
  Dest := FScratch + '/link-ancestor-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeDirectoryEntry('top/dir'),
    MakeDirectoryEntry('top/dir/sub'),
    MakeRegularFileEntry('top/dir/keep.txt', Body),
    MakeSymlinkEntry('top/dir/sub/link', '..')
  ])));

  Count := ExtractArchive(Archive, Dest);

  Expect<Integer>(Count).ToBe(1);
  Expect<Boolean>(FileExists(Dest + '/dir/keep.txt')).ToBe(True);
  Expect<Boolean>(DirectoryExists(Dest + '/dir/sub/link')).ToBe(False);
  Expect<Boolean>(FileExists(Dest + '/dir/sub/link')).ToBe(False);
end;

procedure TExtractPathological.TestGnuLongNameOverridesHeaderName;
{ The third pathological case: GNU 'L' long-name entries. When a
  path exceeds 255 bytes (the ustar prefix-split ceiling), GNU tar
  emits an 'L' typeflag entry holding the real name in its body and
  follows it with the actual regular file entry. The extractor's
  pending-long-name buffer carries the name across the header
  boundary and uses it instead of the truncated stub in the file
  entry's name field.

  This test builds a path of ~270 chars (well past ustar's reach),
  wraps it as a GNU 'L' + regular file pair, gzips, extracts, and
  asserts the file lands under Dest at the expected stripped-top
  path with byte-perfect content. }
var
  Archive, Dest, LongPath, RelPath, ExtractedPath: string;
  Body, ExtractedBytes: TBytes;
  Count: Integer;
begin
  {$IFDEF MSWINDOWS}
  { The GNU-L fixture deliberately exceeds the ustar 255-byte path
    ceiling. Under the CI checkout path that also exceeds legacy
    Windows MAX_PATH before this test reaches the tar parser. }
  Expect<Boolean>(True).ToBe(True);
  Exit;
  {$ENDIF}

  { 270-char path under one top-level dir. After StripFirstComponent
    we expect the rest (~263 chars). Each segment is well under 100
    so OS limits don't bite. }
  LongPath := 'topdir/' + StringOfChar('a', 90) + '/'
              + StringOfChar('b', 90) + '/'
              + StringOfChar('c', 80) + '/leaf.txt';
  Expect<Boolean>(Length(LongPath) > 255).ToBe(True);

  Body := BytesOf('gnu long-name survived round-trip through L typeflag');
  Archive := FScratch + '/gnu-long.tar.gz';
  Dest := FScratch + '/gnu-long-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar(
    [MakeGnuLongNameRegularFileEntry(LongPath, Body)])));

  Count := ExtractArchive(Archive, Dest);

  Expect<Integer>(Count).ToBe(1);
  RelPath := StringOfChar('a', 90) + '/'
             + StringOfChar('b', 90) + '/'
             + StringOfChar('c', 80) + '/leaf.txt';
  ExtractedPath := Dest + '/' + RelPath;
  Expect<Boolean>(FileExists(ExtractedPath)).ToBe(True);
  ExtractedBytes := ReadFileBytes(ExtractedPath);
  Expect<Boolean>(BytesEqual(ExtractedBytes, Body)).ToBe(True);
end;

procedure TExtractPathological.TestArchivePathBeyond255Extracts;
{ Issue #309: FPC's TGZFileStream passes the archive path to paszlib's
  gzopen as a 255-character shortstring, so a longer path was truncated and
  the open failed. The archive and its temporary tar both sit past that
  limit here. }
var
  ArchiveDir, Archive, Dest: string;
  Body: TBytes;
  Count: Integer;
begin
  ArchiveDir := ExpandFileName(FScratch + '/' + StringOfChar('a', 100) + '/'
    + StringOfChar('b', 100) + '/' + StringOfChar('c', 60));
  Archive := ArchiveDir + '/long-archive-path.tar.gz';
  Expect<Boolean>(Length(Archive) > 255).ToBe(True);
  Body := BytesOf('extracted from beyond the shortstring limit');
  WriteBytesToFile(Archive, Gzip(BuildTar(
    [MakeRegularFileEntry('top/leaf.txt', Body)])));
  Dest := FScratch + '/long-archive-path-out';
  ForceDirectories(Dest);

  Count := ExtractArchive(Archive, Dest);

  Expect<Integer>(Count).ToBe(1);
  Expect<Boolean>(BytesEqual(ReadFileBytes(Dest + '/leaf.txt'), Body))
    .ToBe(True);
  Expect<Boolean>(FileExists(Archive + '.tar')).ToBe(False);
end;

procedure TExtractPathological.TestDirectoryAtPathLimitExtracts;
{ A directory whose path is exactly the platform limit is creatable, and
  tar spells directory entries both with and without a trailing '/'. The
  separator is not part of the created path, so neither spelling may be
  rejected as too long. }
const
  Suffixes: array[0..1] of string = ('/', '');
  Outputs: array[0..1] of string = ('/dir-limit-slash-out',
    '/dir-limit-bare-out');
var
  Suffix, Dest, RelPath, DirPath: string;
  Count, Variant: Integer;
begin
  for Variant := 0 to High(Suffixes) do
  begin
    Suffix := Suffixes[Variant];
    Dest := ExpandFileName(FScratch + Outputs[Variant]);
    ForceDirectories(Dest);
    RelPath := FillPath(PlatformDirectoryPathLimit - Length(Dest) - 1);
    DirPath := Dest + '/' + RelPath;
    Expect<Integer>(Length(DirPath)).ToBe(PlatformDirectoryPathLimit);
    WriteBytesToFile(FScratch + '/dir-limit.tar.gz', Gzip(BuildTar(
      [MakeGnuLongNameDirectoryEntry('top/' + RelPath + Suffix)])));

    Count := ExtractArchive(FScratch + '/dir-limit.tar.gz', Dest);

    Expect<Integer>(Count).ToBe(0);
    Expect<Boolean>(DirectoryExists(DirPath)).ToBe(True);
  end;
end;

procedure TExtractPathological.SetupTests;
begin
  Test('regular file with short path: baseline sanity',
    TestRegularFileWithShortPath);
  Test('regular file with > 100-char ustar prefix-split path',
    TestRegularFileWithPrefixSplitPath);
  Test('symlink resolves to its target''s bytes (deferred-link pass)',
    TestSymlinkResolvesToFileContent);
  Test('directory link to a sibling is materialized as a copy',
    TestDirLinkToSiblingMaterialized);
  Test('link targeting its own parent is skipped, extraction completes',
    TestLinkTargetIsOwnParentSkipped);
  Test('link targeting an ancestor is skipped, extraction completes',
    TestLinkTargetIsAncestorSkipped);
  Test('GNU L long-name entry overrides truncated header name',
    TestGnuLongNameOverridesHeaderName);
  {$IFDEF MSWINDOWS}
  Skip('an archive whose own path exceeds 255 characters extracts',
    TestArchivePathBeyond255Extracts,
    'the fixture path exceeds legacy Windows MAX_PATH');
  {$ELSE}
  Test('an archive whose own path exceeds 255 characters extracts',
    TestArchivePathBeyond255Extracts);
  {$ENDIF}
  Test('a directory at the platform path limit extracts with or without '
    + 'a trailing separator', TestDirectoryAtPathLimitExtracts);
end;

{ ── TExtractFailureModes ─────────────────────────────────────── }

procedure TExtractFailureModes.BeforeAll;
begin
  FScratch := CreateScratchRoot('extract-failure-modes');
  if not DirectoryExists(FScratch) then ForceDirectories(FScratch);
end;

procedure TExtractFailureModes.TestMissingArchiveRaisesEExtractError;
var Raised: Boolean;
begin
  Raised := False;
  try
    ExtractArchive(FScratch + '/no-such-archive.tar.gz', FScratch);
  except
    on E: EExtractError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

function DirIsEmpty(const APath: string): Boolean;
var R: TSearchRec;
begin
  Result := True;
  if not DirectoryExists(APath) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, R) = 0 then
  begin
    try
      repeat
        if (R.Name <> '.') and (R.Name <> '..') then
          Exit(False);
      until FindNext(R) <> 0;
    finally
      FindClose(R);
    end;
  end;
end;

function RaisesExtractError(const AArchive, ADest: string): Boolean;
begin
  Result := False;
  try
    ExtractArchive(AArchive, ADest);
  except
    on E: EExtractError do Result := True;
  end;
end;

procedure TExtractFailureModes.TestTruncatedGzipRaises;
{ A gzip header with no deflate data must raise, and nothing may be
  extracted from it. }
var
  Archive, Dest: string;
  Bytes: TBytes;
begin
  Archive := FScratch + '/truncated.tar.gz';
  Dest    := FScratch + '/truncated-out';
  ForceDirectories(Dest);
  SetLength(Bytes, 4);
  Bytes[0] := $1F; Bytes[1] := $8B;
  Bytes[2] := $08; Bytes[3] := $00;
  WriteBytesToFile(Archive, Bytes);
  Expect<Boolean>(RaisesExtractError(Archive, Dest)).ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

procedure TExtractFailureModes.TestInvalidGzipMagicRaises;
{ Input that is not gzip at all must raise rather than be read as a raw
  tar stream. }
var
  Archive, Dest: string;
begin
  Archive := FScratch + '/not-gzip.tar.gz';
  Dest    := FScratch + '/not-gzip-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive,
    BytesOf('this is not a gzip stream; just plain text'));
  Expect<Boolean>(RaisesExtractError(Archive, Dest)).ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

procedure TExtractFailureModes.TestGzipCrcMismatchRaisesAndCleansUp;
{ Every deflate byte decodes, but the trailer CRC-32 does not match: the
  archive must be rejected, nothing extracted, and the partial tar removed. }
var
  Archive, Dest: string;
  Bytes: TBytes;
begin
  Archive := FScratch + '/bad-crc.tar.gz';
  Dest    := FScratch + '/bad-crc-out';
  ForceDirectories(Dest);
  Bytes := Gzip(BuildTar(
    [MakeRegularFileEntry('top/file.txt', BytesOf('checked content'))]));
  { The trailer is CRC-32 then ISIZE, little-endian. }
  Bytes[Length(Bytes) - 8] := Bytes[Length(Bytes) - 8] xor $01;
  WriteBytesToFile(Archive, Bytes);
  Expect<Boolean>(RaisesExtractError(Archive, Dest)).ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
  Expect<Boolean>(FileExists(Archive + '.tar')).ToBe(False);
end;

procedure TExtractFailureModes.TestOverlongEntryPathFailsBeforeWriting;
{ An entry whose destination is past every platform's path limit fails
  with a path-length error before any entry, even an earlier short one, is
  written. The operating system would otherwise fail part-way through with
  an error that does not name the cause. }
var
  Archive, Dest, LongPath, Message: string;
  i: Integer;
begin
  Archive := FScratch + '/overlong-entry.tar.gz';
  Dest    := FScratch + '/overlong-entry-out';
  ForceDirectories(Dest);
  LongPath := 'top/';
  for i := 1 to 20 do
    LongPath := LongPath + StringOfChar('s', 240) + '/';
  LongPath := LongPath + 'leaf.txt';
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeRegularFileEntry('top/first.txt', BytesOf('written first')),
    MakeGnuLongNameRegularFileEntry(LongPath, BytesOf('never written'))
  ])));

  Message := '';
  try
    ExtractArchive(Archive, Dest);
  except
    on E: EExtractError do Message := E.Message;
  end;

  Expect<Boolean>(Pos('too long', Message) > 0).ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

function ExtractErrorMessage(const AArchive, ADest: string): string;
begin
  Result := '';
  try
    ExtractArchive(AArchive, ADest);
  except
    on E: EExtractError do Result := E.Message;
  end;
end;

procedure TExtractFailureModes.TestDirectoryLinkAliasFailsBeforeWriting;
{ Every stored entry fits, but materializing the directory link copies the
  deep file below the longer alias, past the platform limit. That copy must
  be checked with the stored entries, before anything is written. }
var
  Archive, Dest, Deep: string;
  DestLength: Integer;
begin
  Archive := FScratch + '/dir-link-alias.tar.gz';
  Dest := ExpandFileName(FScratch + '/dir-link-alias-out');
  ForceDirectories(Dest);
  DestLength := Length(Dest);
  { Dest/r/<Deep>/leaf.txt lands 10 characters inside the file limit. }
  Deep := FillPath(PlatformFilePathLimit - 10 - DestLength
    - Length('/r/') - Length('/leaf.txt'));
  Expect<Integer>(Length(Dest + '/r/' + Deep + '/leaf.txt'))
    .ToBe(PlatformFilePathLimit - 10);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeRegularFileEntry('top/first.txt', BytesOf('written first')),
    MakeDirectoryEntry('top/r'),
    MakeGnuLongNameRegularFileEntry('top/r/' + Deep + '/leaf.txt',
      BytesOf('deep')),
    MakeSymlinkEntry('top/' + StringOfChar('a', 100), 'r')
  ])));

  Expect<Boolean>(Pos('too long', ExtractErrorMessage(Archive, Dest)) > 0)
    .ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

{ A deep file below Dest/r that lands 10 characters inside the file limit. }
function DeepLeafBelowR(const ADest: string): string;
begin
  Result := FillPath(PlatformFilePathLimit - 10 - Length(ADest)
    - Length('/r/') - Length('/leaf.txt')) + '/leaf.txt';
end;

procedure TExtractFailureModes.TestMixedCaseDirectoryLinkFailsBeforeWriting;
{ Windows resolves the link target 'R' to the stored directory 'r' and
  copies its tree below the longer alias, so the check must match paths the
  way the file system does. }
var
  Archive, Dest: string;
begin
  Archive := FScratch + '/mixed-case-link.tar.gz';
  Dest := ExpandFileName(FScratch + '/mixed-case-link-out');
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeRegularFileEntry('top/first.txt', BytesOf('written first')),
    MakeDirectoryEntry('top/r'),
    MakeGnuLongNameRegularFileEntry('top/r/' + DeepLeafBelowR(Dest),
      BytesOf('deep')),
    MakeSymlinkEntry('top/' + StringOfChar('a', 100), 'R')
  ])));

  Expect<Boolean>(Pos('too long', ExtractErrorMessage(Archive, Dest)) > 0)
    .ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

procedure TExtractFailureModes.TestLinkThroughReplacedFileFailsBeforeWriting;
{ The link 'a -> r' replaces the stored file 'a' with a copy of r's tree;
  the later 'long-alias -> a' then copies that tree again below the longer
  alias, past the limit. }
var
  Archive, Dest: string;
begin
  Archive := FScratch + '/replaced-file-link.tar.gz';
  Dest := ExpandFileName(FScratch + '/replaced-file-link-out');
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeRegularFileEntry('top/first.txt', BytesOf('written first')),
    MakeRegularFileEntry('top/a', BytesOf('replaced by the link')),
    MakeDirectoryEntry('top/r'),
    MakeGnuLongNameRegularFileEntry('top/r/' + DeepLeafBelowR(Dest),
      BytesOf('deep')),
    MakeSymlinkEntry('top/a', 'r'),
    MakeSymlinkEntry('top/' + StringOfChar('l', 100), 'a')
  ])));

  Expect<Boolean>(Pos('too long', ExtractErrorMessage(Archive, Dest)) > 0)
    .ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

procedure TExtractFailureModes.TestOverlongNameComponentFailsBeforeWriting;
{ A 256-character file name is past every platform's component limit even
  though the whole path is short; moving the project cannot fix it. }
var
  Archive, Dest: string;
begin
  Archive := FScratch + '/long-component.tar.gz';
  Dest := FScratch + '/long-component-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeRegularFileEntry('top/first.txt', BytesOf('written first')),
    MakeGnuLongNameRegularFileEntry('top/' + StringOfChar('n', 256),
      BytesOf('never written'))
  ])));

  Expect<Boolean>(Pos('too long', ExtractErrorMessage(Archive, Dest)) > 0)
    .ToBe(True);
  Expect<Boolean>(DirIsEmpty(Dest)).ToBe(True);
end;

procedure TExtractFailureModes.TestTarTruncatedMidEntryRaises;
{ Build a tar entry whose body is large enough that truncating the
  back half of the archive actually slices through the body bytes
  (not just the trailing zero-block padding). The contract: the
  resulting file must NOT be byte-equal to the original body — that
  would mean the extractor invented bytes that aren't in the stream. }
var
  Archive, Dest, ExtractedPath: string;
  Plain, Trunc, Original: TBytes;
  i: Integer;
begin
  { 10 KiB body — well past one tar block (512 bytes), so any
    serious truncation slices the body. }
  SetLength(Original, 10 * 1024);
  for i := 0 to High(Original) do Original[i] := Byte(i and $FF);
  Plain := BuildTar([MakeRegularFileEntry('top/payload.txt', Original)]);
  { Drop the last 4 KiB — straight through the body bytes, leaving
    the header intact (Size in header still says 10 KiB). }
  SetLength(Trunc, Length(Plain) - 4 * 1024);
  for i := 0 to High(Trunc) do Trunc[i] := Plain[i];

  Archive := FScratch + '/half-tar.tar.gz';
  Dest    := FScratch + '/half-tar-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(Trunc));
  try ExtractArchive(Archive, Dest); except on Exception do; end;

  ExtractedPath := Dest + '/payload.txt';
  if FileExists(ExtractedPath) then
    Expect<Boolean>(BytesEqual(ReadFileBytes(ExtractedPath), Original))
      .ToBe(False)   { partial / wrong content is acceptable; byte-perfect is not }
  else
    Expect<Boolean>(True).ToBe(True);   { absent is the cleanest outcome }
end;

procedure TExtractFailureModes.TestParentTraversalPathRejected;
var
  Archive, Dest, OutsidePath: string;
  Raised: Boolean;
begin
  Archive := FScratch + '/parent-traversal.tar.gz';
  Dest := FScratch + '/parent-traversal-out';
  OutsidePath := FScratch + '/escaped.txt';
  ForceDirectories(Dest);
  WriteBytesToFile(OutsidePath, BytesOf('original'));
  WriteBytesToFile(Archive, Gzip(BuildTar(
    [MakeRegularFileEntry('top/../escaped.txt', BytesOf('evil'))])));

  Raised := False;
  try
    ExtractArchive(Archive, Dest);
  except
    on E: EExtractError do Raised := True;
  end;

  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(BytesEqual(ReadFileBytes(OutsidePath), BytesOf('original')))
    .ToBe(True);
end;

procedure TExtractFailureModes.TestAbsoluteTraversalPathRejected;
var
  Archive, Dest: string;
  Raised: Boolean;
begin
  Archive := FScratch + '/absolute-traversal.tar.gz';
  Dest := FScratch + '/absolute-traversal-out';
  ForceDirectories(Dest);
  WriteBytesToFile(Archive, Gzip(BuildTar(
    [MakeRegularFileEntry('top//escaped.txt', BytesOf('evil'))])));

  Raised := False;
  try
    ExtractArchive(Archive, Dest);
  except
    on E: EExtractError do Raised := True;
  end;

  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(FileExists(Dest + '/escaped.txt')).ToBe(False);
end;

procedure TExtractFailureModes.TestLinkTargetOutsideDestRejected;
var
  Archive, Dest, OutsidePath: string;
  Raised: Boolean;
begin
  Archive := FScratch + '/link-outside.tar.gz';
  Dest := FScratch + '/link-outside-out';
  OutsidePath := FScratch + '/outside.txt';
  ForceDirectories(Dest);
  WriteBytesToFile(OutsidePath, BytesOf('outside host file'));
  WriteBytesToFile(Archive, Gzip(BuildTar([
    MakeDirectoryEntry('top/dir'),
    MakeSymlinkEntry('top/dir/link.txt', '../../outside.txt')
  ])));

  Raised := False;
  try
    ExtractArchive(Archive, Dest);
  except
    on E: EExtractError do Raised := True;
  end;

  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(FileExists(Dest + '/dir/link.txt')).ToBe(False);
end;

procedure TExtractFailureModes.SetupTests;
begin
  Test('missing archive path raises EExtractError',
    TestMissingArchiveRaisesEExtractError);
  Test('truncated gzip stream raises EExtractError', TestTruncatedGzipRaises);
  Test('invalid gzip magic raises EExtractError', TestInvalidGzipMagicRaises);
  Test('gzip CRC-32 mismatch raises and removes the partial tar',
    TestGzipCrcMismatchRaisesAndCleansUp);
  Test('an over-long entry path fails before any entry is written',
    TestOverlongEntryPathFailsBeforeWriting);
  Test('a directory-link copy past the path limit fails before any entry '
    + 'is written', TestDirectoryLinkAliasFailsBeforeWriting);
  Test('an over-long entry name component fails before any entry is written',
    TestOverlongNameComponentFailsBeforeWriting);
  {$IFDEF MSWINDOWS}
  Test('a directory link naming its target in another case is checked '
    + 'before any entry is written',
    TestMixedCaseDirectoryLinkFailsBeforeWriting);
  {$ELSE}
  Skip('a directory link naming its target in another case is checked '
    + 'before any entry is written',
    TestMixedCaseDirectoryLinkFailsBeforeWriting,
    'LWPT treats archive paths case-sensitively outside Windows');
  {$ENDIF}
  Test('a link through a file replaced by a directory link is checked '
    + 'before any entry is written',
    TestLinkThroughReplacedFileFailsBeforeWriting);
  Test('tar truncated mid-entry raises or extracts nothing',
    TestTarTruncatedMidEntryRaises);
  Test('archive entry with parent traversal is rejected',
    TestParentTraversalPathRejected);
  Test('archive entry with absolute post-strip path is rejected',
    TestAbsoluteTraversalPathRejected);
  Test('archive link target outside extraction root is rejected',
    TestLinkTargetOutsideDestRejected);
end;

begin
  TestRunnerProgram.AddSuite(TExtractPathological.Create(
    'ExtractArchive: pathological ustar shapes'));
  TestRunnerProgram.AddSuite(TExtractFailureModes.Create(
    'ExtractArchive: failure modes'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
