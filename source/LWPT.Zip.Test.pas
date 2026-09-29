{ LWPT.Zip.Test — the bounded zip container reader (ADR-0049, "Zip
  normalization": container rules, payload decoding, and bounds).

  Every archive is synthesised byte by byte (Tests.ZipSynth) and, where a
  single field matters, patched after it is laid out, so each case isolates
  one rule. A refusal is asserted by its stable code together with a
  fragment of its detail, so a case cannot pass on an unrelated earlier
  failure. Independent-tool zips (Info-ZIP, 7-Zip, Python) are exercised
  through the normalizer in LWPT.ArchiveNormalize.Test. }
program LWPT.Zip.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Archive,
  LWPT.Zip,
  TestingPascalLibrary,
  Tests.ZipSynth;

type
  TZipContainerSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAcceptsStoredDeflateAndDescriptors;
    procedure TestAcceptsDescriptorWithEqualLocalValues;
    procedure TestRejectsEncryption;
    procedure TestRejectsZip64;
    procedure TestRejectsMultiDisk;
    procedure TestRejectsUnsupportedMethodsAndFlags;
    procedure TestRejectsPrependedAndTrailingData;
    procedure TestRejectsGapsAndOverlaps;
    procedure TestRejectsLocalCentralMismatch;
    procedure TestRejectsDescriptorMismatch;
    procedure TestRejectsMalformedDirectory;
    procedure TestRejectsAmbiguousEndRecord;
    procedure TestRejectsMalformedExtraField;
  end;

  TZipDecodingSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRejectsBadCrc;
    procedure TestRejectsTruncatedDeflate;
    procedure TestRejectsBytesAfterStreamEnd;
    procedure TestRejectsShortOutput;
    procedure TestStopsOneBytePastDeclaredSize;
    procedure TestRejectsStoredSizeMismatch;
    procedure TestRejectsStoredBadCrc;
    procedure TestRejectsCorruptDeflate;
  end;

  TZipLimitSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestInputSizeBound;
    procedure TestEntryCountBound;
    procedure TestDeclaredExpansionBound;
  end;

const
  MANIFEST = '[package]'#10'name = "demo"'#10'version = "1.0.0"'#10;

function Payload(const ASize: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, ASize);
  for i := 0 to ASize - 1 do
    Result[i] := Byte((i * 7 + i div 13) and $FF);
end;

function Basic: TZipSynth;
begin
  Result := TZipSynth.Create;
  Result.AddText('pkg/lwpt.toml', MANIFEST);
  Result.Add('pkg/data.bin', Payload(5000));
end;

function BuildBasic: TBytes;
var
  Z: TZipSynth;
begin
  Z := Basic;
  try
    Result := Z.Build;
  finally
    Z.Free;
  end;
end;

{ Opens AData and decodes every entry. The stable code when the detail
  contains AFragment, the whole message when it does not, 'accepted' when
  nothing is refused. }
function Rejection(const AData: TBytes; const AFragment: string;
  const ALimits: TLWPTArchiveLimits): string; overload;
var
  Zip: TLWPTZipArchive;
  Sink: TBytesStream;
  i: Integer;
begin
  Result := 'accepted';
  Zip := nil;
  Sink := TBytesStream.Create(nil);
  try
    try
      Zip := TLWPTZipArchive.Create(AData, ALimits);
      for i := 0 to Zip.Count - 1 do
        Zip.DecodeEntry(i, Sink);
    except
      on E: ELWPTArchiveError do
        if Pos(AFragment, E.Message) > 0 then
          Result := E.Code
        else
          Result := E.Message;
    end;
  finally
    Sink.Free;
    Zip.Free;
  end;
end;

function Rejection(const AData: TBytes;
  const AFragment: string): string; overload;
begin
  Result := Rejection(AData, AFragment, DefaultArchiveLimits);
end;

function Splice(const AData: TBytes; const AOffset: Integer;
  const AInsert: TBytes): TBytes;
begin
  SetLength(Result, Length(AData) + Length(AInsert));
  Move(AData[0], Result[0], AOffset);
  if Length(AInsert) > 0 then
    Move(AInsert[0], Result[AOffset], Length(AInsert));
  if AOffset < Length(AData) then
    Move(AData[AOffset], Result[AOffset + Length(AInsert)],
      Length(AData) - AOffset);
end;

function ExtraField(const AId: Word; const ASize: Integer): TBytes;
begin
  SetLength(Result, 4 + ASize);
  FillChar(Result[0], Length(Result), 0);
  PutU16(Result, 0, AId);
  PutU16(Result, 2, ASize);
end;

{ ---- container ---------------------------------------------------------- }

procedure TZipContainerSuite.TestAcceptsStoredDeflateAndDescriptors;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  Data, Expected: TBytes;
  Zip: TLWPTZipArchive;
  Sink: TBytesStream;
  i: Integer;
begin
  Expected := Payload(70000);
  Z := TZipSynth.Create;
  try
    Z.AddText('pkg/lwpt.toml', MANIFEST, 0);
    Z.Add('pkg/deflated.bin', Payload(70000));
    i := Z.Add('pkg/descriptor.bin', Payload(3000));
    E := Z.Entry(i);
    E.Descriptor := True;
    E.DescriptorSignature := True;
    E.CentralExtra := ExtraField($5455, 5);
    E.LocalExtra := ExtraField($7875, 11);
    E.Comment := 'entry comment';
    Z.SetEntry(i, E);
    i := Z.Add('pkg/unsigned-descriptor.bin', Payload(10));
    E := Z.Entry(i);
    E.Descriptor := True;
    E.Flags := $0800 or $0002;
    Z.SetEntry(i, E);
    Z.AddDirectory('pkg/empty/');
    Z.Comment := 'archive comment';
    Data := Z.Build;
  finally
    Z.Free;
  end;
  Expect<string>(Rejection(Data, '')).ToBe('accepted');
  Zip := TLWPTZipArchive.Create(Data, DefaultArchiveLimits);
  Sink := TBytesStream.Create(nil);
  try
    Expect<Integer>(Zip.Count).ToBe(5);
    Expect<Int64>(Zip.DeclaredExpandedBytes)
      .ToBe(Length(MANIFEST) + 70000 + 3000 + 10);
    Zip.DecodeEntry(1, Sink);
    Expect<Int64>(Sink.Size).ToBe(70000);
    Expect<Boolean>(CompareMem(Sink.Memory, @Expected[0], 70000))
      .ToBe(True);
    Expect<string>(Zip.Entries[2].Name).ToBe('pkg/descriptor.bin');
    Expect<Integer>(Zip.Entries[2].HostSystem).ToBe(ZIP_HOST_UNIX);
  finally
    Sink.Free;
    Zip.Free;
  end;
end;

procedure TZipContainerSuite.TestAcceptsDescriptorWithEqualLocalValues;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  Data: TBytes;
  Local: Integer;
begin
  Z := Basic;
  try
    E := Z.Entry(1);
    E.Descriptor := True;
    Z.SetEntry(1, E);
    Data := Z.Build;
    Local := Z.LocalOffsets[1];
    PutU32(Data, Local + 14, GetU32(Data, Z.CentralOffsets[1] + 16));
    PutU32(Data, Local + 18, GetU32(Data, Z.CentralOffsets[1] + 20));
    PutU32(Data, Local + 22, GetU32(Data, Z.CentralOffsets[1] + 24));
    Expect<string>(Rejection(Data, '')).ToBe('accepted');
    { A local value that is neither zero nor the central one. }
    PutU32(Data, Local + 22, 1);
    Expect<string>(Rejection(Data, 'local CRC or sizes disagree'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsEncryption;

  function WithEntry(const AFlags, AMethod: Word): TBytes;
  var
    Z: TZipSynth;
    E: TZipSynthEntry;
  begin
    Z := Basic;
    try
      E := Z.Entry(1);
      E.Flags := AFlags;
      E.Method := AMethod;
      E.HasPayload := True;
      E.Payload := Payload(40);
      Z.SetEntry(1, E);
      Result := Z.Build;
    finally
      Z.Free;
    end;
  end;

begin
  Expect<string>(Rejection(WithEntry($0001, 8), 'is encrypted'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry($0041, 8), 'is encrypted'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry($0040, 8), 'is encrypted'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry($0000, 99), 'encrypted (AES)'))
    .ToBe(ARCHIVE_UNSUPPORTED);
end;

procedure TZipContainerSuite.TestRejectsZip64;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  Data, Patched, Locator, Record64: TBytes;
  EndAt, Central: Integer;
begin
  Z := Basic;
  try
    Data := Z.Build;
    EndAt := Z.EndOffset;
    Central := Z.CentralOffsets[1];
    { The locator before the end record. }
    SetLength(Locator, 20);
    FillChar(Locator[0], 20, 0);
    PutU32(Locator, 0, $07064B50);
    Expect<string>(Rejection(Splice(Data, EndAt, Locator),
      'end-of-central-directory locator')).ToBe(ARCHIVE_UNSUPPORTED);
    { A ZIP64 end record where a central header is expected. }
    SetLength(Record64, 56);
    FillChar(Record64[0], 56, 0);
    PutU32(Record64, 0, $06064B50);
    Patched := Splice(Data, EndAt, Record64);
    PutU16(Patched, EndAt + 56 + 8, 3);
    PutU16(Patched, EndAt + 56 + 10, 3);
    PutU32(Patched, EndAt + 56 + 12, GetU32(Data, EndAt + 12) + 56);
    Expect<string>(Rejection(Patched, 'end-of-central-directory record'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    { End-record sentinels. }
    Patched := System.Copy(Data);
    PutU16(Patched, EndAt + 8, $FFFF);
    PutU16(Patched, EndAt + 10, $FFFF);
    Expect<string>(Rejection(Patched, 'end-record sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU32(Patched, EndAt + 12, $FFFFFFFF);
    Expect<string>(Rejection(Patched, 'end-record sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU32(Patched, EndAt + 16, $FFFFFFFF);
    Expect<string>(Rejection(Patched, 'end-record sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    { Central-header sentinels. }
    Patched := System.Copy(Data);
    PutU32(Patched, Central + 20, $FFFFFFFF);
    Expect<string>(Rejection(Patched, 'size or offset sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU32(Patched, Central + 24, $FFFFFFFF);
    Expect<string>(Rejection(Patched, 'size or offset sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU32(Patched, Central + 42, $FFFFFFFF);
    Expect<string>(Rejection(Patched, 'size or offset sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU16(Patched, Central + 34, $FFFF);
    Expect<string>(Rejection(Patched, 'size or offset sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    { A local-header size sentinel. }
    Patched := System.Copy(Data);
    PutU32(Patched, Z.LocalOffsets[1] + 22, $FFFFFFFF);
    Expect<string>(Rejection(Patched, 'local size sentinel'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    { Extra field 0x0001, central and local. }
    E := Z.Entry(1);
    E.CentralExtra := ExtraField($0001, 16);
    Z.SetEntry(1, E);
    Expect<string>(Rejection(Z.Build, 'ZIP64 extra field'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    E.CentralExtra := nil;
    E.LocalExtra := ExtraField($0001, 16);
    Z.SetEntry(1, E);
    Expect<string>(Rejection(Z.Build, 'local carries a ZIP64 extra field'))
      .ToBe(ARCHIVE_UNSUPPORTED);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsMultiDisk;
var
  Z: TZipSynth;
  Data, Patched: TBytes;
  EndAt: Integer;
begin
  Z := Basic;
  try
    Data := Z.Build;
    EndAt := Z.EndOffset;
    Patched := System.Copy(Data);
    PutU16(Patched, EndAt + 4, 1);
    Expect<string>(Rejection(Patched, 'more than one disk'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU16(Patched, EndAt + 6, 1);
    Expect<string>(Rejection(Patched, 'more than one disk'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU16(Patched, EndAt + 8, 1);
    Expect<string>(Rejection(Patched, 'more than one disk'))
      .ToBe(ARCHIVE_UNSUPPORTED);
    Patched := System.Copy(Data);
    PutU16(Patched, Z.CentralOffsets[0] + 34, 1);
    Expect<string>(Rejection(Patched, 'starts on another disk'))
      .ToBe(ARCHIVE_UNSUPPORTED);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsUnsupportedMethodsAndFlags;

  function WithEntry(const AFlags, AMethod: Word): TBytes;
  var
    Z: TZipSynth;
    E: TZipSynthEntry;
  begin
    Z := Basic;
    try
      E := Z.Entry(1);
      E.Flags := AFlags;
      E.Method := AMethod;
      E.HasPayload := True;
      E.Payload := Payload(40);
      Z.SetEntry(1, E);
      Result := Z.Build;
    finally
      Z.Free;
    end;
  end;

begin
  Expect<string>(Rejection(WithEntry(0, 12), 'unsupported method 12'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry(0, 14), 'unsupported method 14'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry(0, 9), 'unsupported method 9'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry($0010, 8), 'unsupported flags $0010'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry($2000, 8), 'unsupported flags $2000'))
    .ToBe(ARCHIVE_UNSUPPORTED);
  Expect<string>(Rejection(WithEntry($0020, 8), 'unsupported flags $0020'))
    .ToBe(ARCHIVE_UNSUPPORTED);
end;

procedure TZipContainerSuite.TestRejectsPrependedAndTrailingData;
var
  Z: TZipSynth;
  Data: TBytes;
begin
  Z := Basic;
  try
    { A self-extractor stub, with every offset adjusted as such tools do. }
    Z.LeadingBytes := TextBytes('MZ self-extracting stub');
    Expect<string>(Rejection(Z.Build, 'data before its first local header'))
      .ToBe(ARCHIVE_INVALID);
    Z.LeadingBytes := nil;
    Z.TrailingBytes := TextBytes('trailing');
    Expect<string>(Rejection(Z.Build, 'no end-of-central-directory record'))
      .ToBe(ARCHIVE_INVALID);
    Z.TrailingBytes := nil;
    { A comment length that claims more bytes than follow. }
    Z.Comment := 'comment';
    Data := Z.Build;
    PutU16(Data, Z.EndOffset + 20, 8);
    Expect<string>(Rejection(Data, 'no end-of-central-directory record'))
      .ToBe(ARCHIVE_INVALID);
    { The comment accounts for every trailing byte: accepted. }
    Expect<string>(Rejection(Z.Build, '')).ToBe('accepted');
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsGapsAndOverlaps;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  Data: TBytes;
begin
  Z := Basic;
  try
    E := Z.Entry(0);
    E.GapAfter := TextBytes('hidden');
    Z.SetEntry(0, E);
    Expect<string>(Rejection(Z.Build, 'leaves a gap'))
      .ToBe(ARCHIVE_INVALID);
    E.GapAfter := nil;
    Z.SetEntry(0, E);
    E := Z.Entry(1);
    E.GapAfter := TextBytes('hidden');
    Z.SetEntry(1, E);
    Expect<string>(Rejection(Z.Build, 'between its last record'))
      .ToBe(ARCHIVE_INVALID);
    E.GapAfter := nil;
    Z.SetEntry(1, E);
    { Two central entries sharing one local record: the overlapping-entry
      bomb shape. }
    Data := Z.Build;
    PutU32(Data, Z.CentralOffsets[1] + 42, Z.LocalOffsets[0]);
    Expect<string>(Rejection(Data, 'overlaps the previous record'))
      .ToBe(ARCHIVE_INVALID);
    { A central entry pointing into the previous entry's data. }
    PutU32(Data, Z.CentralOffsets[1] + 42, Z.LocalOffsets[1] - 4);
    Expect<string>(Rejection(Data, 'overlaps the previous record'))
      .ToBe(ARCHIVE_INVALID);
    { Local records in a different order from the central directory. }
    Data := Z.Build;
    PutU32(Data, Z.CentralOffsets[0] + 42, Z.LocalOffsets[1]);
    PutU32(Data, Z.CentralOffsets[1] + 42, Z.LocalOffsets[0]);
    Expect<string>(Rejection(Data, 'data before its first local header'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsLocalCentralMismatch;
var
  Z: TZipSynth;
  Data, Patched: TBytes;
  Local: Integer;
begin
  Z := Basic;
  try
    Data := Z.Build;
    Local := Z.LocalOffsets[1];
    Patched := System.Copy(Data);
    Patched[Local + 30] := Ord('P');
    Expect<string>(Rejection(Patched, 'local name differs'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    PutU16(Patched, Local + 8, 0);
    Expect<string>(Rejection(Patched, 'method or flags'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    PutU16(Patched, Local + 6, $0800);
    Expect<string>(Rejection(Patched, 'method or flags'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    PutU32(Patched, Local + 14, GetU32(Data, Local + 14) xor 1);
    Expect<string>(Rejection(Patched, 'local CRC or sizes disagree'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    PutU32(Patched, Local + 18, 0);
    Expect<string>(Rejection(Patched, 'local CRC or sizes disagree'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    PutU32(Patched, Local + 22, 0);
    Expect<string>(Rejection(Patched, 'local CRC or sizes disagree'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsDescriptorMismatch;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  Data, Patched: TBytes;
  Descriptor: Integer;
begin
  Z := Basic;
  try
    E := Z.Entry(1);
    E.Descriptor := True;
    E.DescriptorSignature := True;
    Z.SetEntry(1, E);
    Data := Z.Build;
    Descriptor := Z.CentralOffsets[0] - 16;
    Expect<Cardinal>(GetU32(Data, Descriptor)).ToBe($08074B50);
    Expect<string>(Rejection(Data, '')).ToBe('accepted');
    Patched := System.Copy(Data);
    Patched[Descriptor + 4] := Patched[Descriptor + 4] xor 1;
    Expect<string>(Rejection(Patched, 'data descriptor'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    PutU32(Patched, Descriptor + 12, 0);
    Expect<string>(Rejection(Patched, 'data descriptor'))
      .ToBe(ARCHIVE_INVALID);
    { No descriptor at all after data that claims one. }
    E.Descriptor := False;
    E.Flags := $0008;
    Z.SetEntry(1, E);
    Data := Z.Build;
    Expect<string>(Rejection(Data, 'data descriptor'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsMalformedDirectory;
var
  Z: TZipSynth;
  Data, Patched: TBytes;
  EndAt: Integer;
begin
  Z := Basic;
  try
    Data := Z.Build;
    EndAt := Z.EndOffset;
    { Bytes inside the central directory after its declared entries. }
    Patched := Splice(Data, EndAt, TextBytes('junk'));
    PutU32(Patched, EndAt + 4 + 12, GetU32(Data, EndAt + 12) + 4);
    Expect<string>(Rejection(Patched, 'bytes after its declared entries'))
      .ToBe(ARCHIVE_INVALID);
    { A central-directory size below 46 bytes per declared entry. }
    Patched := System.Copy(Data);
    PutU16(Patched, EndAt + 8, 100);
    PutU16(Patched, EndAt + 10, 100);
    Expect<string>(Rejection(Patched, 'too small for its declared entries'))
      .ToBe(ARCHIVE_INVALID);
    { A central directory that does not end at the end record. }
    Patched := System.Copy(Data);
    PutU32(Patched, EndAt + 16, GetU32(Data, EndAt + 16) - 1);
    Expect<string>(Rejection(Patched, 'does not end where the end record'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    Patched[Z.CentralOffsets[1]] := 0;
    Expect<string>(Rejection(Patched, 'no central header signature'))
      .ToBe(ARCHIVE_INVALID);
    Patched := System.Copy(Data);
    Patched[Z.LocalOffsets[1]] := 0;
    Expect<string>(Rejection(Patched, 'no local header signature'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.TestRejectsAmbiguousEndRecord;
var
  Z: TZipSynth;
  Fake: RawByteString;
begin
  Z := Basic;
  try
    { A comment that itself ends with a well-formed end record. }
    Fake := 'PK'#5#6 + StringOfChar(#0, 18);
    Z.Comment := Fake;
    Expect<string>(Rejection(Z.Build, 'more than one end-of-central'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
  Expect<string>(Rejection(TextBytes('PK'#3#4'not a zip at all'),
    'no end-of-central-directory record')).ToBe(ARCHIVE_INVALID);
end;

procedure TZipContainerSuite.TestRejectsMalformedExtraField;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
begin
  Z := Basic;
  try
    E := Z.Entry(1);
    E.CentralExtra := ExtraField($5455, 5);
    PutU16(E.CentralExtra, 2, 6);
    Z.SetEntry(1, E);
    Expect<string>(Rejection(Z.Build, 'overruns its declared length'))
      .ToBe(ARCHIVE_INVALID);
    E.CentralExtra := TextBytes('ab');
    Z.SetEntry(1, E);
    Expect<string>(Rejection(Z.Build, 'extra field does not parse'))
      .ToBe(ARCHIVE_INVALID);
    E.CentralExtra := nil;
    E.LocalExtra := TextBytes('abc');
    Z.SetEntry(1, E);
    Expect<string>(Rejection(Z.Build, 'local extra field does not parse'))
      .ToBe(ARCHIVE_INVALID);
  finally
    Z.Free;
  end;
end;

procedure TZipContainerSuite.SetupTests;
begin
  Test('accepts stored, deflate, descriptors, extra fields, and comments',
    TestAcceptsStoredDeflateAndDescriptors);
  Test('accepts descriptor-mode local values equal to the central ones',
    TestAcceptsDescriptorWithEqualLocalValues);
  Test('rejects encryption: bits 0 and 6 and AES', TestRejectsEncryption);
  Test('rejects ZIP64 in each form', TestRejectsZip64);
  Test('rejects multi-disk archives', TestRejectsMultiDisk);
  Test('rejects unsupported methods and flags',
    TestRejectsUnsupportedMethodsAndFlags);
  Test('rejects prepended and trailing data',
    TestRejectsPrependedAndTrailingData);
  Test('rejects gaps and overlapping entries', TestRejectsGapsAndOverlaps);
  Test('rejects local and central mismatches',
    TestRejectsLocalCentralMismatch);
  Test('rejects a descriptor mismatch', TestRejectsDescriptorMismatch);
  Test('rejects a malformed central directory',
    TestRejectsMalformedDirectory);
  Test('rejects a missing or ambiguous end record',
    TestRejectsAmbiguousEndRecord);
  Test('rejects extra fields that overrun their length',
    TestRejectsMalformedExtraField);
end;

{ ---- decoding ----------------------------------------------------------- }

function WithSecondEntry(const AMethod: Word; const APayload: TBytes;
  const AHasPayload: Boolean; const AUncompressed: Int64 = -1;
  const ACrc: Int64 = -1): TBytes;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
begin
  Z := Basic;
  try
    E := Z.Entry(1);
    E.Method := AMethod;
    E.HasPayload := AHasPayload;
    E.Payload := APayload;
    if AUncompressed >= 0 then
    begin
      E.HasUncompressedSize := True;
      E.UncompressedSize := Cardinal(AUncompressed);
    end;
    if ACrc >= 0 then
    begin
      E.HasCrc := True;
      E.Crc := Cardinal(ACrc);
    end;
    Z.SetEntry(1, E);
    Result := Z.Build;
  finally
    Z.Free;
  end;
end;

function Join(const A, B: TBytes): TBytes;
begin
  Result := Splice(A, Length(A), B);
end;

procedure TZipDecodingSuite.TestRejectsBadCrc;
begin
  Expect<string>(Rejection(WithSecondEntry(8, nil, False, -1,
    ZipCrc32(Payload(5000)) xor $10), 'CRC-32 mismatch'))
    .ToBe(ARCHIVE_INVALID);
end;

procedure TZipDecodingSuite.TestRejectsTruncatedDeflate;
var
  Deflated: TBytes;
begin
  Deflated := RawDeflate(Payload(5000));
  Expect<string>(Rejection(WithSecondEntry(8,
    System.Copy(Deflated, 0, Length(Deflated) - 3), True),
    'ends before its deflate stream does')).ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(WithSecondEntry(8,
    System.Copy(Deflated, 0, 1), True),
    'ends before its deflate stream does')).ToBe(ARCHIVE_INVALID);
end;

procedure TZipDecodingSuite.TestRejectsBytesAfterStreamEnd;
var
  Deflated: TBytes;
begin
  Deflated := RawDeflate(Payload(5000));
  { One stray byte, then a whole second deflate stream, inside the slice. }
  Expect<string>(Rejection(WithSecondEntry(8, Join(Deflated,
    TextBytes('x')), True), 'compressed bytes after the end'))
    .ToBe(ARCHIVE_INVALID);
  Expect<string>(Rejection(WithSecondEntry(8, Join(Deflated,
    RawDeflate(Payload(10))), True), 'compressed bytes after the end'))
    .ToBe(ARCHIVE_INVALID);
end;

procedure TZipDecodingSuite.TestRejectsShortOutput;
begin
  Expect<string>(Rejection(WithSecondEntry(8, nil, False, 5001),
    'short of its declared 5001')).ToBe(ARCHIVE_INVALID);
end;

{ Counts what reaches the target, so the test sees where inflation stops. }
type
  TCountingSink = class(TStream)
  public
    Written: Int64;
    function Write(const ABuffer; ACount: Longint): Longint; override;
    function Read(var ABuffer; ACount: Longint): Longint; override;
  end;

function TCountingSink.Write(const ABuffer; ACount: Longint): Longint;
begin
  Inc(Written, ACount);
  Result := ACount;
end;

function TCountingSink.Read(var ABuffer; ACount: Longint): Longint;
begin
  Result := 0;
end;

procedure TZipDecodingSuite.TestStopsOneBytePastDeclaredSize;
var
  Data: TBytes;
  Zip: TLWPTZipArchive;
  Sink: TCountingSink;
  Code: string;
begin
  Expect<string>(Rejection(WithSecondEntry(8, nil, False, 4999),
    'inflates past its declared 4999')).ToBe(ARCHIVE_LIMIT_EXCEEDED);
  { A 200 KiB payload declared as 70,000 bytes: the decoder stops at byte
    70,001 and never passes more than the declared size on. }
  Data := WithSecondEntry(8, RawDeflate(Payload(200000)), True, 70000,
    ZipCrc32(Payload(70000)));
  Zip := TLWPTZipArchive.Create(Data, DefaultArchiveLimits);
  Sink := TCountingSink.Create;
  Code := 'accepted';
  try
    try
      Zip.DecodeEntry(1, Sink);
    except
      on E: ELWPTArchiveError do Code := E.Code;
    end;
    Expect<string>(Code).ToBe(ARCHIVE_LIMIT_EXCEEDED);
    Expect<Int64>(Sink.Written).ToBe(65536);
  finally
    Sink.Free;
    Zip.Free;
  end;
end;

procedure TZipDecodingSuite.TestRejectsStoredSizeMismatch;
begin
  Expect<string>(Rejection(WithSecondEntry(0, nil, False, 4999),
    'stored with differing sizes')).ToBe(ARCHIVE_INVALID);
end;

procedure TZipDecodingSuite.TestRejectsStoredBadCrc;
begin
  Expect<string>(Rejection(WithSecondEntry(0, nil, False, -1,
    ZipCrc32(Payload(5000)) xor $80000000), 'CRC-32 mismatch'))
    .ToBe(ARCHIVE_INVALID);
end;

procedure TZipDecodingSuite.TestRejectsCorruptDeflate;
var
  Corrupt: TBytes;
begin
  { $FF opens a final block of reserved type 3. }
  Corrupt := RawDeflate(Payload(5000));
  Corrupt[0] := $FF;
  Expect<string>(Rejection(WithSecondEntry(8, Corrupt, True),
    'corrupt deflate data')).ToBe(ARCHIVE_INVALID);
end;

procedure TZipDecodingSuite.SetupTests;
begin
  Test('rejects a bad CRC-32', TestRejectsBadCrc);
  Test('rejects a truncated deflate stream', TestRejectsTruncatedDeflate);
  Test('rejects compressed bytes left after Z_STREAM_END',
    TestRejectsBytesAfterStreamEnd);
  Test('rejects output short of the declared size', TestRejectsShortOutput);
  Test('stops one byte past the declared size',
    TestStopsOneBytePastDeclaredSize);
  Test('rejects a stored entry whose sizes differ',
    TestRejectsStoredSizeMismatch);
  Test('rejects a stored entry with a bad CRC', TestRejectsStoredBadCrc);
  Test('rejects corrupt deflate data', TestRejectsCorruptDeflate);
end;

{ ---- bounds ------------------------------------------------------------- }

procedure TZipLimitSuite.TestInputSizeBound;
var
  Data: TBytes;
begin
  { Zero bytes: under the bound it is refused only for having no end
    record; one byte over, it is refused by size before any parsing. }
  SetLength(Data, ARCHIVE_MAXIMUM_INPUT_BYTES);
  FillChar(Data[0], Length(Data), 0);
  Expect<string>(Rejection(Data, 'no end-of-central-directory record'))
    .ToBe(ARCHIVE_INVALID);
  SetLength(Data, ARCHIVE_MAXIMUM_INPUT_BYTES + 1);
  Expect<string>(Rejection(Data, 'zip input is 268435457 bytes'))
    .ToBe(ARCHIVE_LIMIT_EXCEEDED);
end;

procedure TZipLimitSuite.TestEntryCountBound;
var
  Z: TZipSynth;
  i: Integer;
  Data: TBytes;
begin
  Z := TZipSynth.Create;
  try
    for i := 1 to 10000 do
      Z.Add(RawByteString(Format('pkg/f%.5d', [i])), nil, 0);
    Data := Z.Build;
    Expect<string>(Rejection(Data, '')).ToBe('accepted');
    Z.Add('pkg/one-more', nil, 0);
    Expect<string>(Rejection(Z.Build, 'declares 10001 entries'))
      .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  finally
    Z.Free;
  end;
end;

procedure TZipLimitSuite.TestDeclaredExpansionBound;
var
  Z: TZipSynth;
  E: TZipSynthEntry;
  Zip: TLWPTZipArchive;
begin
  Z := Basic;
  try
    { Tiny payloads declaring 512 MiB each: exactly 1 GiB with the
      manifest's bytes removed is accepted by the declared-size check. }
    E := Z.Entry(1);
    E.HasUncompressedSize := True;
    E.UncompressedSize := 512 * 1024 * 1024;
    Z.SetEntry(1, E);
    E.Name := 'pkg/second.bin';
    E.UncompressedSize := 512 * 1024 * 1024 - Length(MANIFEST);
    Z.SetEntry(Z.Add('pkg/second.bin', nil), E);
    Zip := TLWPTZipArchive.Create(Z.Build, DefaultArchiveLimits);
    try
      Expect<Int64>(Zip.DeclaredExpandedBytes)
        .ToBe(ARCHIVE_MAXIMUM_EXPANDED_BYTES);
    finally
      Zip.Free;
    end;
    { One more declared byte is refused before anything inflates. }
    E.UncompressedSize := E.UncompressedSize + 1;
    Z.SetEntry(2, E);
    Expect<string>(Rejection(Z.Build, 'declares 1073741825 uncompressed'))
      .ToBe(ARCHIVE_LIMIT_EXCEEDED);
  finally
    Z.Free;
  end;
end;

procedure TZipLimitSuite.SetupTests;
begin
  Test('refuses input one byte over 256 MiB before parsing',
    TestInputSizeBound);
  Test('refuses 10,001 entries and accepts 10,000', TestEntryCountBound);
  Test('refuses 1 GiB plus one declared byte before inflating',
    TestDeclaredExpansionBound);
end;

begin
  TestRunnerProgram.AddSuite(TZipContainerSuite.Create('LWPT.Zip container'));
  TestRunnerProgram.AddSuite(TZipDecodingSuite.Create('LWPT.Zip decoding'));
  TestRunnerProgram.AddSuite(TZipLimitSuite.Create('LWPT.Zip bounds'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
