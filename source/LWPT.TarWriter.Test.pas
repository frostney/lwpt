{ LWPT.TarWriter.Test — the canonical tar.gz writer (ADR-0049, "Canonical
  tar.gz"; normalizer version 1).

  The golden hashes pin the exact output bytes. They were cross-checked when
  pinned against an independent reference: a separate ustar writer following
  the ADR text, compressed by zlib 1.3 with the same level, window bits,
  memory level, strategy, and 64 KiB feeding, produced byte-identical
  output. A change here is a normalizer-version change, not a fixture
  refresh. The same hashes must hold on every release platform. }
program LWPT.TarWriter.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Archive,
  LWPT.Core,
  LWPT.Gzip,
  LWPT.TarWriter,
  TestingPascalLibrary;

type
  TTarWriterSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSmallGolden;
    procedure TestLargeGolden;
    procedure TestGzipFraming;
    procedure TestHeaderFields;
    procedure TestRecordPadding;
    procedure TestUstarSplit;
    procedure TestRejectsUnsplittablePath;
    procedure TestRejectsOutOfOrderEntries;
    procedure TestRejectsMissingParent;
    procedure TestRejectsWrongFileLength;
    procedure TestOutputLimitStopsGeneration;
  end;

  TBuild = procedure(const AWriter: TLWPTCanonicalTarGzipWriter);

function Bytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if AText <> '' then Move(AText[1], Result[0], Length(AText));
end;

{ xorshift32: shifts and xor only, so no overflow check can fire. }
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

procedure AddFile(const AWriter: TLWPTCanonicalTarGzipWriter;
  const APath: string; const AData: TBytes; const AExecutable: Boolean);
var
  Offset, Take: Integer;
begin
  AWriter.BeginFile(APath, Length(AData), AExecutable);
  { Uneven pieces, so nothing depends on how a caller splits its data. }
  Offset := 0;
  Take := 1;
  while Offset < Length(AData) do
  begin
    if Take > Length(AData) - Offset then Take := Length(AData) - Offset;
    AWriter.WriteFileData(AData[Offset], Take);
    Inc(Offset, Take);
    Take := Take * 3 + 7;
  end;
  AWriter.EndFile;
end;

function Run(const ABuild: TBuild;
  const AMaximum: Int64 = ARCHIVE_MAXIMUM_OUTPUT_BYTES): TBytes;
var
  Target: TBytesStream;
  Writer: TLWPTCanonicalTarGzipWriter;
begin
  Target := TBytesStream.Create(nil);
  try
    Writer := TLWPTCanonicalTarGzipWriter.Create(Target, AMaximum);
    try
      ABuild(Writer);
      Writer.Finish;
    finally
      Writer.Free;
    end;
    Result := System.Copy(Target.Bytes, 0, Target.Size);
  finally
    Target.Free;
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

function Field(const ATar: TBytes; const AOffset, ALength: Integer): string;
begin
  SetLength(Result, ALength);
  Move(ATar[AOffset], Result[1], ALength);
end;

function Outcome(const ABuild: TBuild): string;
begin
  Result := 'accepted';
  try
    Run(ABuild);
  except
    on E: ELWPTArchiveError do Result := E.Message;
  end;
end;

procedure BuildSmall(const AWriter: TLWPTCanonicalTarGzipWriter);
begin
  AWriter.AddDirectory('pkg-1.0.0');
  AddFile(AWriter, 'pkg-1.0.0/a.txt', Bytes('hello'#10), False);
  AWriter.AddDirectory('pkg-1.0.0/bin');
  AddFile(AWriter, 'pkg-1.0.0/bin/run', Bytes('#!/bin/sh'#10), True);
  AddFile(AWriter, 'pkg-1.0.0/empty.txt', nil, False);
end;

const
  LONG_DIRECTORY = 'pkg-2.0.0/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
  LONG_SUBDIRECTORY = LONG_DIRECTORY
    + '/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
  LONG_FILE = LONG_SUBDIRECTORY + '/ffffffffffffffffffffffffffffffffffffffff'
    + 'ffffffffffffffffffffffffffffffffffffffffffffffffff.txt';

procedure BuildLarge(const AWriter: TLWPTCanonicalTarGzipWriter);
var
  Text: string;
  i: Integer;
begin
  Text := '';
  for i := 1 to 4000 do
    Text := Text + Format('line %d of the canonical text payload'#10, [i]);
  AWriter.AddDirectory('pkg-2.0.0');
  AddFile(AWriter, 'pkg-2.0.0/data.bin', NoiseBytes(200000, $2545F491),
    False);
  AWriter.AddDirectory(LONG_DIRECTORY);
  AWriter.AddDirectory(LONG_SUBDIRECTORY);
  AddFile(AWriter, LONG_FILE, Bytes('long path'#10), False);
  AddFile(AWriter, 'pkg-2.0.0/text.txt', Bytes(Text), True);
  AddFile(AWriter, 'pkg-2.0.0/'#$C3#$BC'ber.md', Bytes('umlaut'#10), False);
end;

procedure TTarWriterSuite.TestSmallGolden;
var
  Output: TBytes;
begin
  Output := Run(BuildSmall);
  Expect<string>(SHA256Hex(Output)).ToBe(
    '18d04611f9fe12ea42f162675f13cfa2bf74502d6b31449cccbd17fac2b941bc');
  Expect<string>(SHA256Hex(Gunzip(Output))).ToBe(
    'eec527cc22f6a3e51ffa75f1642184d49b15ffc31d2456be871efc289a764809');
  { Deterministic across writer instances. }
  Expect<string>(SHA256Hex(Run(BuildSmall))).ToBe(SHA256Hex(Output));
end;

procedure TTarWriterSuite.TestLargeGolden;
var
  Output: TBytes;
begin
  Output := Run(BuildLarge);
  Expect<string>(SHA256Hex(Output)).ToBe(
    'caf1f0f4bd8ebe766f768440c7ccae7f167b4fc75b02eccd15115890b2b3dac9');
  Expect<string>(SHA256Hex(Gunzip(Output))).ToBe(
    '23db09ec1cbad1799fcec6566392ed9508d9d63dc482c2a195982c27463698bc');
end;

procedure TTarWriterSuite.TestGzipFraming;
var
  Output, Tar: TBytes;
  Crc, Size: Cardinal;
  i: Integer;
const
  HEADER: array[0..9] of Byte = (
    $1F, $8B, $08, $00, $00, $00, $00, $00, $00, $FF);
begin
  Output := Run(BuildLarge);
  for i := 0 to 9 do
    Expect<Integer>(Output[i]).ToBe(HEADER[i]);
  Tar := Gunzip(Output);
  Crc := 0;
  Size := 0;
  for i := 0 to 3 do
  begin
    Crc := Crc or (Cardinal(Output[Length(Output) - 8 + i]) shl (8 * i));
    Size := Size or (Cardinal(Output[Length(Output) - 4 + i]) shl (8 * i));
  end;
  Expect<Cardinal>(Size).ToBe(Cardinal(Length(Tar)));
  Expect<Boolean>(Length(Tar) > 3 * CANONICAL_GZIP_CHUNK_BYTES).ToBe(True);
  Expect<Boolean>(Crc <> 0).ToBe(True);
end;

procedure TTarWriterSuite.TestHeaderFields;
var
  Tar: TBytes;
  Sum, i: Integer;
begin
  Tar := Gunzip(Run(BuildSmall));
  { The root directory header. }
  Expect<string>(Field(Tar, 0, 11)).ToBe('pkg-1.0.0/'#0);
  Expect<string>(Field(Tar, 100, 8)).ToBe('0000755'#0);
  Expect<string>(Field(Tar, 108, 8)).ToBe('0000000'#0);
  Expect<string>(Field(Tar, 116, 8)).ToBe('0000000'#0);
  Expect<string>(Field(Tar, 124, 12)).ToBe('00000000000'#0);
  Expect<string>(Field(Tar, 136, 12)).ToBe('00000000000'#0);
  Expect<string>(Field(Tar, 156, 1)).ToBe('5');
  Expect<string>(Field(Tar, 257, 8)).ToBe('ustar'#0'00');
  { linkname, uname, gname, devmajor, devminor, prefix, and padding. }
  Sum := 0;
  for i := 157 to 256 do Inc(Sum, Tar[i]);
  for i := 265 to 511 do Inc(Sum, Tar[i]);
  Expect<Integer>(Sum).ToBe(0);
  { The standard checksum: six octal digits, NUL, space. }
  Sum := 0;
  for i := 0 to 511 do
    if (i >= 148) and (i < 156) then Inc(Sum, Ord(' ')) else Inc(Sum, Tar[i]);
  Expect<string>(Field(Tar, 148, 8))
    .ToBe(OctStr(Sum, 6) + #0' ');
  { The second entry is the regular file a.txt: mode 0644, size 6. }
  Expect<string>(Field(Tar, 512, 16)).ToBe('pkg-1.0.0/a.txt'#0);
  Expect<string>(Field(Tar, 612, 8)).ToBe('0000644'#0);
  Expect<string>(Field(Tar, 636, 12)).ToBe('00000000006'#0);
  Expect<string>(Field(Tar, 668, 1)).ToBe('0');
  Expect<string>(Field(Tar, 1024, 6)).ToBe('hello'#10);
  { bin/run is executable: 0755. }
  Expect<string>(Field(Tar, 3 * 512, 15)).ToBe('pkg-1.0.0/bin/'#0);
  Expect<string>(Field(Tar, 4 * 512, 18)).ToBe('pkg-1.0.0/bin/run'#0);
  Expect<string>(Field(Tar, 4 * 512 + 100, 8)).ToBe('0000755'#0);
end;

procedure TTarWriterSuite.TestRecordPadding;
var
  Tar: TBytes;
  i, Zeros: Integer;
begin
  Tar := Gunzip(Run(BuildSmall));
  Expect<Integer>(Length(Tar)).ToBe(CANONICAL_TAR_RECORD_BYTES);
  { Five headers and two one-block payloads, then only zeros: the two end
    blocks and the record padding. }
  Zeros := 0;
  for i := 7 * 512 to High(Tar) do
    if Tar[i] = 0 then Inc(Zeros);
  Expect<Integer>(Zeros).ToBe(Length(Tar) - 7 * 512);
  Tar := Gunzip(Run(BuildLarge));
  Expect<Integer>(Length(Tar) mod CANONICAL_TAR_RECORD_BYTES).ToBe(0);
end;

procedure TTarWriterSuite.TestUstarSplit;
var
  Prefix, Name, Path: string;
begin
  Expect<Boolean>(SplitUstarPath('a/b.txt', Prefix, Name)).ToBe(True);
  Expect<string>(Prefix + '|' + Name).ToBe('|a/b.txt');
  { Exactly 100 bytes fits the name field alone. }
  Path := StringOfChar('n', 100);
  Expect<Boolean>(SplitUstarPath(Path, Prefix, Name)).ToBe(True);
  Expect<string>(Prefix).ToBe('');
  { The longest prefix of at most 155 bytes that ends at a '/'. }
  Path := StringOfChar('p', 60) + '/' + StringOfChar('q', 60) + '/'
    + StringOfChar('r', 50);
  Expect<Boolean>(SplitUstarPath(Path, Prefix, Name)).ToBe(True);
  Expect<string>(Prefix).ToBe(StringOfChar('p', 60) + '/'
    + StringOfChar('q', 60));
  Expect<string>(Name).ToBe(StringOfChar('r', 50));
  Path := StringOfChar('p', 155) + '/' + StringOfChar('r', 100);
  Expect<Boolean>(SplitUstarPath(Path, Prefix, Name)).ToBe(True);
  Expect<Integer>(Length(Prefix)).ToBe(155);
  { A directory's own trailing slash never leaves an empty name. }
  Path := StringOfChar('p', 60) + '/' + StringOfChar('q', 60) + '/';
  Expect<Boolean>(SplitUstarPath(Path, Prefix, Name)).ToBe(True);
  Expect<string>(Name).ToBe(StringOfChar('q', 60) + '/');
end;

procedure TTarWriterSuite.TestRejectsUnsplittablePath;
var
  Prefix, Name: string;
begin
  Expect<Boolean>(SplitUstarPath(StringOfChar('n', 101), Prefix, Name))
    .ToBe(False);
  Expect<Boolean>(SplitUstarPath(StringOfChar('p', 156) + '/'
    + StringOfChar('r', 10), Prefix, Name)).ToBe(False);
  Expect<Boolean>(SplitUstarPath(StringOfChar('p', 20) + '/'
    + StringOfChar('r', 101), Prefix, Name)).ToBe(False);
  Expect<Boolean>(SplitUstarPath('', Prefix, Name)).ToBe(False);
end;

procedure BuildOutOfOrder(const AWriter: TLWPTCanonicalTarGzipWriter);
begin
  AWriter.AddDirectory('pkg');
  AddFile(AWriter, 'pkg/b', nil, False);
  AddFile(AWriter, 'pkg/a', nil, False);
end;

procedure BuildDuplicate(const AWriter: TLWPTCanonicalTarGzipWriter);
begin
  AWriter.AddDirectory('pkg');
  AddFile(AWriter, 'pkg/a', nil, False);
  AddFile(AWriter, 'pkg/a', nil, False);
end;

{ 'pkg/a-b' sorts before 'pkg/a/' because '-' (0x2D) < '/' (0x2F). }
procedure BuildDirectoryAfterSibling(
  const AWriter: TLWPTCanonicalTarGzipWriter);
begin
  AWriter.AddDirectory('pkg');
  AWriter.AddDirectory('pkg/a');
  AddFile(AWriter, 'pkg/a-b', nil, False);
end;

procedure TTarWriterSuite.TestRejectsOutOfOrderEntries;
begin
  Expect<Boolean>(Pos('strictly increasing', Outcome(BuildOutOfOrder)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('strictly increasing', Outcome(BuildDuplicate)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('strictly increasing',
    Outcome(BuildDirectoryAfterSibling)) > 0).ToBe(True);
end;

procedure BuildMissingParent(const AWriter: TLWPTCanonicalTarGzipWriter);
begin
  AWriter.AddDirectory('pkg');
  AddFile(AWriter, 'pkg/sub/a', nil, False);
end;

procedure TTarWriterSuite.TestRejectsMissingParent;
begin
  Expect<string>(Outcome(BuildMissingParent)).ToBe(
    'invalid_archive: canonical tar writer: parent directory not emitted '
    + 'before pkg/sub/a');
end;

procedure BuildShortFile(const AWriter: TLWPTCanonicalTarGzipWriter);
var
  Data: TBytes;
begin
  Data := Bytes('abc');
  AWriter.AddDirectory('pkg');
  AWriter.BeginFile('pkg/a', 4, False);
  AWriter.WriteFileData(Data[0], 3);
  AWriter.EndFile;
end;

procedure BuildLongFile(const AWriter: TLWPTCanonicalTarGzipWriter);
var
  Data: TBytes;
begin
  Data := Bytes('abc');
  AWriter.AddDirectory('pkg');
  AWriter.BeginFile('pkg/a', 2, False);
  AWriter.WriteFileData(Data[0], 3);
end;

procedure TTarWriterSuite.TestRejectsWrongFileLength;
begin
  Expect<Boolean>(Pos('shorter than its declared size',
    Outcome(BuildShortFile)) > 0).ToBe(True);
  Expect<Boolean>(Pos('exceeds its declared size',
    Outcome(BuildLongFile)) > 0).ToBe(True);
end;

procedure TTarWriterSuite.TestOutputLimitStopsGeneration;
var
  Target: TBytesStream;
  Writer: TLWPTCanonicalTarGzipWriter;
  Code: string;
begin
  Code := 'accepted';
  Target := TBytesStream.Create(nil);
  try
    Writer := TLWPTCanonicalTarGzipWriter.Create(Target, 4096);
    try
      try
        BuildLarge(Writer);
        Writer.Finish;
      except
        on E: ELWPTArchiveError do Code := E.Code;
      end;
    finally
      Writer.Free;
    end;
    Expect<string>(Code).ToBe(ARCHIVE_LIMIT_EXCEEDED);
    Expect<Boolean>(Target.Size <= 4096).ToBe(True);
  finally
    Target.Free;
  end;
  { The bound counts the whole member: exactly its length fits. }
  Expect<Integer>(Length(Run(BuildSmall, Length(Run(BuildSmall)))))
    .ToBe(Length(Run(BuildSmall)));
  Code := 'accepted';
  try
    Run(BuildSmall, Length(Run(BuildSmall)) - 1);
  except
    on E: ELWPTArchiveError do Code := E.Code;
  end;
  Expect<string>(Code).ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

procedure TTarWriterSuite.SetupTests;
begin
  Test('small tree matches its golden hash', TestSmallGolden);
  Test('multi-chunk tree with split and UTF-8 paths matches its golden hash',
    TestLargeGolden);
  Test('gzip member header, CRC-32, and ISIZE', TestGzipFraming);
  Test('ustar header fields are canonical', TestHeaderFields);
  Test('two end blocks and 10,240-byte record padding', TestRecordPadding);
  Test('paths split at the longest ustar prefix', TestUstarSplit);
  Test('paths that do not fit ustar are refused',
    TestRejectsUnsplittablePath);
  Test('entries must arrive in strictly increasing byte order',
    TestRejectsOutOfOrderEntries);
  Test('a parent directory must precede its entries',
    TestRejectsMissingParent);
  Test('file data must match its declared size', TestRejectsWrongFileLength);
  Test('output past the bound stops generation',
    TestOutputLimitStopsGeneration);
end;

begin
  TestRunnerProgram.AddSuite(TTarWriterSuite.Create('LWPT.TarWriter'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
