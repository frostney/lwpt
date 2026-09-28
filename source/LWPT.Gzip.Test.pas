{ LWPT.Gzip.Test — RFC 1952 decoding between streams.

  Fixed vectors come from independent encoders: GNU gzip ("hello\n", with
  and without FNAME) and a Python-built member carrying FEXTRA, FNAME,
  FCOMMENT and FHCRC. The large round trip uses paszlib's own gzip writer
  and feeds the decoder a few bytes per read, so every header, deflate and
  trailer boundary crosses a buffer refill. Every malformed input must raise
  EExtractError rather than yield a short or unchecked result. }
program LWPT.Gzip.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Gzip,
  TestingPascalLibrary,
  Tests.TarSynth;

type
  { Returns at most a few bytes per Read, varying the count. }
  TTrickleStream = class(TStream)
  private
    FInner: TStream;
    FReads: Integer;
  public
    constructor Create(const AInner: TStream);
    function Read(var ABuffer; ACount: Longint): Longint; override;
  end;

  TGzipSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDecodesGnuGzipMember;
    procedure TestSkipsStoredFileName;
    procedure TestSkipsOptionalFieldsAndVerifiesHeaderCrc;
    procedure TestDecodesLargePayloadAcrossReadBoundaries;
    procedure TestDecodesConcatenatedMembers;
    procedure TestIgnoresTrailingZeroPadding;
    procedure TestRejectsLoneMagicByteAfterMember;
    procedure TestRejectsDamagedSecondMemberMagic;
    procedure TestRejectsDataAfterZeroPadding;
    procedure TestRejectsNonGzipInput;
    procedure TestRejectsEmptyInput;
    procedure TestRejectsTruncatedHeader;
    procedure TestRejectsTruncatedCompressedData;
    procedure TestRejectsTruncatedTrailer;
    procedure TestRejectsCrcMismatch;
    procedure TestRejectsLengthMismatch;
    procedure TestRejectsCorruptDeflateData;
    procedure TestRejectsHeaderCrcMismatch;
    procedure TestRejectsUnsupportedMethod;
    procedure TestRejectsReservedFlags;
  end;

const
  { printf 'hello\n' | gzip -n -9 }
  HELLO_GZIP: array[0..25] of Byte = (
    $1F, $8B, $08, $00, $00, $00, $00, $00, $02, $03,
    $CB, $48, $CD, $C9, $C9, $E7, $02, $00,
    $20, $30, $3A, $36, $06, $00, $00, $00);
  { gzip -c l309-hello.txt: FNAME set. }
  HELLO_NAMED_GZIP: array[0..40] of Byte = (
    $1F, $8B, $08, $08, $72, $52, $BA, $6A, $00, $03,
    $6C, $33, $30, $39, $2D, $68, $65, $6C, $6C, $6F, $2E, $74, $78, $74, $00,
    $CB, $48, $CD, $C9, $C9, $E7, $02, $00,
    $20, $30, $3A, $36, $06, $00, $00, $00);
  { FLG = FHCRC | FEXTRA | FNAME | FCOMMENT; CRC16 from Python's zlib. }
  HELLO_ALL_FIELDS_GZIP: array[0..37] of Byte = (
    $1F, $8B, $08, $1E, $00, $00, $00, $00, $00, $03,
    $04, $00, $4C, $57, $00, $00,
    $6E, $00,
    $63, $00,
    $A6, $B2,
    $CB, $48, $CD, $C9, $C9, $E7, $02, $00,
    $20, $30, $3A, $36, $06, $00, $00, $00);
  HELLO_HEADER_LENGTH = 10;
  HELLO_DEFLATE_LENGTH = 8;
  HELLO_ALL_FIELDS_CRC16_OFFSET = 20;
  HELLO = 'hello'#10;

constructor TTrickleStream.Create(const AInner: TStream);
begin
  inherited Create;
  FInner := AInner;
end;

function TTrickleStream.Read(var ABuffer; ACount: Longint): Longint;
begin
  Inc(FReads);
  if ACount > 1 + FReads mod 7 then ACount := 1 + FReads mod 7;
  Result := FInner.Read(ABuffer, ACount);
end;

function ToBytes(const AValues: array of Byte): TBytes;
begin
  SetLength(Result, Length(AValues));
  if Length(AValues) > 0 then Move(AValues[0], Result[0], Length(AValues));
end;

function JoinBytes(const AFirst, ASecond: TBytes): TBytes;
begin
  SetLength(Result, Length(AFirst) + Length(ASecond));
  if Length(AFirst) > 0 then Move(AFirst[0], Result[0], Length(AFirst));
  if Length(ASecond) > 0 then
    Move(ASecond[0], Result[Length(AFirst)], Length(ASecond));
end;

function Prefix(const AValue: TBytes; const ALength: Integer): TBytes;
begin
  Result := Copy(AValue, 0, ALength);
end;

function Decode(const AGzip: TBytes; const ATrickle: Boolean = False): TBytes;
var
  Source: TBytesStream;
  Reader: TStream;
  Target: TBytesStream;
begin
  Source := TBytesStream.Create(AGzip);
  Target := TBytesStream.Create(nil);
  try
    if ATrickle then
      Reader := TTrickleStream.Create(Source)
    else
      Reader := Source;
    try
      GunzipStream(Reader, Target);
    finally
      if Reader <> Source then Reader.Free;
    end;
    Result := Copy(Target.Bytes, 0, Target.Size);
  finally
    Target.Free;
    Source.Free;
  end;
end;

function DecodeText(const AGzip: TBytes): string;
var
  Bytes: TBytes;
begin
  Bytes := Decode(AGzip);
  SetLength(Result, Length(Bytes));
  if Length(Bytes) > 0 then Move(Bytes[0], Result[1], Length(Bytes));
end;

function RaisesExtractError(const AGzip: TBytes): Boolean;
begin
  Result := False;
  try
    Decode(AGzip);
  except
    on E: EExtractError do Result := True;
  end;
end;

procedure TGzipSuite.TestDecodesGnuGzipMember;
begin
  Expect<string>(DecodeText(ToBytes(HELLO_GZIP))).ToBe(HELLO);
end;

procedure TGzipSuite.TestSkipsStoredFileName;
begin
  Expect<string>(DecodeText(ToBytes(HELLO_NAMED_GZIP))).ToBe(HELLO);
end;

procedure TGzipSuite.TestSkipsOptionalFieldsAndVerifiesHeaderCrc;
begin
  Expect<string>(DecodeText(ToBytes(HELLO_ALL_FIELDS_GZIP))).ToBe(HELLO);
end;

procedure TGzipSuite.TestDecodesLargePayloadAcrossReadBoundaries;
var
  Plain, Decoded: TBytes;
  i: Integer;
begin
  { Past the decoder's 64 KiB buffers, mixing runs with noise so the deflate
    stream holds both stored-like and compressed blocks. }
  SetLength(Plain, 300 * 1024);
  for i := 0 to High(Plain) do
    if (i div 4096) mod 2 = 0 then
      Plain[i] := Byte((i * 7919) xor (i shr 5))
    else
      Plain[i] := Byte(i div 4096);
  Decoded := Decode(Gzip(Plain), True);
  Expect<Integer>(Length(Decoded)).ToBe(Length(Plain));
  Expect<Boolean>(CompareMem(@Decoded[0], @Plain[0], Length(Plain)))
    .ToBe(True);
end;

procedure TGzipSuite.TestDecodesConcatenatedMembers;
begin
  Expect<string>(DecodeText(JoinBytes(ToBytes(HELLO_GZIP),
    ToBytes(HELLO_NAMED_GZIP)))).ToBe(HELLO + HELLO);
end;

procedure TGzipSuite.TestIgnoresTrailingZeroPadding;
var
  Padding: TBytes;
begin
  SetLength(Padding, 512);
  FillChar(Padding[0], Length(Padding), 0);
  Expect<string>(DecodeText(JoinBytes(ToBytes(HELLO_GZIP), Padding)))
    .ToBe(HELLO);
end;

procedure TGzipSuite.TestRejectsLoneMagicByteAfterMember;
begin
  { A second member truncated after its first header byte. }
  Expect<Boolean>(RaisesExtractError(JoinBytes(ToBytes(HELLO_GZIP),
    ToBytes([$1F])))).ToBe(True);
end;

procedure TGzipSuite.TestRejectsDamagedSecondMemberMagic;
var
  Second: TBytes;
begin
  Second := ToBytes(HELLO_GZIP);
  Second[1] := $8C;
  Expect<Boolean>(RaisesExtractError(JoinBytes(ToBytes(HELLO_GZIP), Second)))
    .ToBe(True);
end;

procedure TGzipSuite.TestRejectsDataAfterZeroPadding;
var
  Tail: TBytes;
begin
  SetLength(Tail, 16);
  FillChar(Tail[0], Length(Tail), 0);
  Tail[High(Tail)] := $01;
  Expect<Boolean>(RaisesExtractError(JoinBytes(ToBytes(HELLO_GZIP), Tail)))
    .ToBe(True);
end;

procedure TGzipSuite.TestRejectsNonGzipInput;
begin
  Expect<Boolean>(RaisesExtractError(
    BytesOf('this is not a gzip stream; just plain text'))).ToBe(True);
end;

procedure TGzipSuite.TestRejectsEmptyInput;
begin
  Expect<Boolean>(RaisesExtractError(nil)).ToBe(True);
end;

procedure TGzipSuite.TestRejectsTruncatedHeader;
begin
  Expect<Boolean>(RaisesExtractError(
    Prefix(ToBytes(HELLO_GZIP), HELLO_HEADER_LENGTH - 1))).ToBe(True);
  { Inside the NUL-terminated FNAME field. }
  Expect<Boolean>(RaisesExtractError(
    Prefix(ToBytes(HELLO_NAMED_GZIP), HELLO_HEADER_LENGTH + 4))).ToBe(True);
end;

procedure TGzipSuite.TestRejectsTruncatedCompressedData;
begin
  Expect<Boolean>(RaisesExtractError(
    Prefix(ToBytes(HELLO_GZIP), HELLO_HEADER_LENGTH + 3))).ToBe(True);
end;

procedure TGzipSuite.TestRejectsTruncatedTrailer;
begin
  Expect<Boolean>(RaisesExtractError(Prefix(ToBytes(HELLO_GZIP),
    HELLO_HEADER_LENGTH + HELLO_DEFLATE_LENGTH + 5))).ToBe(True);
end;

procedure TGzipSuite.TestRejectsCrcMismatch;
var
  Bytes: TBytes;
begin
  Bytes := ToBytes(HELLO_GZIP);
  Bytes[HELLO_HEADER_LENGTH + HELLO_DEFLATE_LENGTH] :=
    Bytes[HELLO_HEADER_LENGTH + HELLO_DEFLATE_LENGTH] xor $01;
  Expect<Boolean>(RaisesExtractError(Bytes)).ToBe(True);
end;

procedure TGzipSuite.TestRejectsLengthMismatch;
var
  Bytes: TBytes;
begin
  Bytes := ToBytes(HELLO_GZIP);
  Bytes[HELLO_HEADER_LENGTH + HELLO_DEFLATE_LENGTH + 4] := $07;
  Expect<Boolean>(RaisesExtractError(Bytes)).ToBe(True);
end;

procedure TGzipSuite.TestRejectsCorruptDeflateData;
var
  Bytes: TBytes;
begin
  { $FF opens a final block of reserved type 3, which deflate forbids. }
  Bytes := ToBytes(HELLO_GZIP);
  Bytes[HELLO_HEADER_LENGTH] := $FF;
  Expect<Boolean>(RaisesExtractError(Bytes)).ToBe(True);
end;

procedure TGzipSuite.TestRejectsHeaderCrcMismatch;
var
  Bytes: TBytes;
begin
  Bytes := ToBytes(HELLO_ALL_FIELDS_GZIP);
  Bytes[HELLO_ALL_FIELDS_CRC16_OFFSET] :=
    Bytes[HELLO_ALL_FIELDS_CRC16_OFFSET] xor $01;
  Expect<Boolean>(RaisesExtractError(Bytes)).ToBe(True);
end;

procedure TGzipSuite.TestRejectsUnsupportedMethod;
var
  Bytes: TBytes;
begin
  Bytes := ToBytes(HELLO_GZIP);
  Bytes[2] := $07;
  Expect<Boolean>(RaisesExtractError(Bytes)).ToBe(True);
end;

procedure TGzipSuite.TestRejectsReservedFlags;
var
  Bytes: TBytes;
begin
  Bytes := ToBytes(HELLO_GZIP);
  Bytes[3] := $20;
  Expect<Boolean>(RaisesExtractError(Bytes)).ToBe(True);
end;

procedure TGzipSuite.SetupTests;
begin
  Test('decodes a GNU gzip member', TestDecodesGnuGzipMember);
  Test('skips a stored file name', TestSkipsStoredFileName);
  Test('skips FEXTRA, FNAME and FCOMMENT and verifies FHCRC',
    TestSkipsOptionalFieldsAndVerifiesHeaderCrc);
  Test('decodes a large payload read a few bytes at a time',
    TestDecodesLargePayloadAcrossReadBoundaries);
  Test('decodes concatenated members in order',
    TestDecodesConcatenatedMembers);
  Test('ignores zero padding after the last member',
    TestIgnoresTrailingZeroPadding);
  Test('rejects a lone magic byte after a member',
    TestRejectsLoneMagicByteAfterMember);
  Test('rejects a damaged second-member magic',
    TestRejectsDamagedSecondMemberMagic);
  Test('rejects nonzero data after zero padding',
    TestRejectsDataAfterZeroPadding);
  Test('rejects input that is not gzip', TestRejectsNonGzipInput);
  Test('rejects empty input', TestRejectsEmptyInput);
  Test('rejects a truncated header', TestRejectsTruncatedHeader);
  Test('rejects truncated compressed data',
    TestRejectsTruncatedCompressedData);
  Test('rejects a truncated trailer', TestRejectsTruncatedTrailer);
  Test('rejects a CRC-32 mismatch', TestRejectsCrcMismatch);
  Test('rejects an ISIZE mismatch', TestRejectsLengthMismatch);
  Test('rejects corrupt deflate data', TestRejectsCorruptDeflateData);
  Test('rejects a header CRC mismatch', TestRejectsHeaderCrcMismatch);
  Test('rejects an unsupported compression method',
    TestRejectsUnsupportedMethod);
  Test('rejects reserved header flags', TestRejectsReservedFlags);
end;

begin
  TestRunnerProgram.AddSuite(TGzipSuite.Create('LWPT.Gzip'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
