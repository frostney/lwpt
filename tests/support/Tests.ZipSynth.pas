{ Tests.ZipSynth — a byte-exact zip synthesiser for the archive-normalizer
  tests (ADR-0049).

  Real zip tools cannot produce most of the containers the normalizer must
  refuse, and they differ in the metadata they write. This builder lays out
  local records and the central directory from explicit fields, so a test
  controls every byte: the method, flags, host system and external
  attributes, timestamps, extra fields, comments, data descriptors (with or
  without their signature), and overrides of the CRC, sizes, and payload.
  Archive-level options prepend a stub or insert gaps while keeping every
  recorded offset consistent, and append bytes the end record does not
  cover. Build records the offset of every local header, central header,
  and the end record so a test can patch a single field afterwards.

  Deflated payloads come from paszlib's zdeflate as raw deflate, at a level
  the entry chooses. }
unit Tests.ZipSynth;

{$I Shared.inc}

interface

uses
  SysUtils;

const
  ZIP_SYNTH_UNIX = 3;
  ZIP_SYNTH_MSDOS = 0;
  ZIP_SYNTH_REGULAR_644 = Cardinal($81A4) shl 16;
  ZIP_SYNTH_REGULAR_755 = Cardinal($81ED) shl 16;
  ZIP_SYNTH_DIRECTORY_755 = Cardinal($41ED) shl 16;

type
  TZipSynthEntry = record
    Name: RawByteString;
    Data: TBytes;
    Method: Word;
    Level: Integer;
    Flags: Word;
    Host: Byte;
    ExternalAttributes: Cardinal;
    DosTime, DosDate: Word;
    CentralExtra, LocalExtra: TBytes;
    Comment: RawByteString;
    Descriptor: Boolean;
    DescriptorSignature: Boolean;
    { Replace the computed payload, CRC, or sizes. }
    HasPayload: Boolean;
    Payload: TBytes;
    HasCrc: Boolean;
    Crc: Cardinal;
    HasCompressedSize: Boolean;
    CompressedSize: Cardinal;
    HasUncompressedSize: Boolean;
    UncompressedSize: Cardinal;
    { Bytes written between this record and the next. }
    GapAfter: TBytes;
  end;

  TZipSynth = class
  private
    FEntries: array of TZipSynthEntry;
    FCount: Integer;
  public
    Comment: RawByteString;
    LeadingBytes: TBytes;
    TrailingBytes: TBytes;
    { Offsets recorded by the last Build. }
    LocalOffsets, CentralOffsets: array of Integer;
    EndOffset: Integer;
    function Add(const AName: RawByteString; const AData: TBytes;
      const AMethod: Word = 8): Integer;
    function AddText(const AName: RawByteString; const AText: string;
      const AMethod: Word = 8): Integer;
    function AddDirectory(const AName: RawByteString): Integer;
    function Entry(const AIndex: Integer): TZipSynthEntry;
    procedure SetEntry(const AIndex: Integer; const AEntry: TZipSynthEntry);
    function Count: Integer;
    function Build: TBytes;
  end;

function RawDeflate(const AData: TBytes; const ALevel: Integer = 6): TBytes;
function ZipCrc32(const AData: TBytes): Cardinal;
function TextBytes(const AText: string): TBytes;
procedure PutU16(var ABytes: TBytes; const AOffset: Integer;
  const AValue: Word);
procedure PutU32(var ABytes: TBytes; const AOffset: Integer;
  const AValue: Cardinal);
function GetU16(const ABytes: TBytes; const AOffset: Integer): Word;
function GetU32(const ABytes: TBytes; const AOffset: Integer): Cardinal;

implementation

uses
  crc,
  zbase,
  zdeflate;

function TextBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if AText <> '' then Move(AText[1], Result[0], Length(AText));
end;

function ZipCrc32(const AData: TBytes): Cardinal;
begin
  Result := crc32(0, nil, 0);
  if Length(AData) > 0 then
    Result := crc32(Result, @AData[0], Length(AData));
end;

function RawDeflate(const AData: TBytes; const ALevel: Integer): TBytes;
var
  Stream: z_stream;
  Status, Used: Integer;
  Dummy: Byte;
begin
  Stream := Default(z_stream);
  if deflateInit2(Stream, ALevel, Z_DEFLATED, -MAX_WBITS, 8,
    Z_DEFAULT_STRATEGY) <> Z_OK then
    raise Exception.Create('deflateInit2 failed');
  try
    SetLength(Result, Length(AData) + Length(AData) div 8 + 64);
    if Length(AData) > 0 then
      Stream.next_in := @AData[0]
    else
      Stream.next_in := @Dummy;
    Stream.avail_in := Length(AData);
    Stream.next_out := @Result[0];
    Stream.avail_out := Length(Result);
    Status := deflate(Stream, Z_FINISH);
    if Status <> Z_STREAM_END then
      raise Exception.CreateFmt('deflate failed: %d', [Status]);
    Used := Length(Result) - Integer(Stream.avail_out);
    SetLength(Result, Used);
  finally
    deflateEnd(Stream);
  end;
end;

procedure PutU16(var ABytes: TBytes; const AOffset: Integer;
  const AValue: Word);
begin
  ABytes[AOffset] := Byte(AValue and $FF);
  ABytes[AOffset + 1] := Byte(AValue shr 8);
end;

procedure PutU32(var ABytes: TBytes; const AOffset: Integer;
  const AValue: Cardinal);
begin
  ABytes[AOffset] := Byte(AValue and $FF);
  ABytes[AOffset + 1] := Byte((AValue shr 8) and $FF);
  ABytes[AOffset + 2] := Byte((AValue shr 16) and $FF);
  ABytes[AOffset + 3] := Byte(AValue shr 24);
end;

function GetU16(const ABytes: TBytes; const AOffset: Integer): Word;
begin
  Result := Word(ABytes[AOffset]) or (Word(ABytes[AOffset + 1]) shl 8);
end;

function GetU32(const ABytes: TBytes; const AOffset: Integer): Cardinal;
begin
  Result := Cardinal(ABytes[AOffset]) or (Cardinal(ABytes[AOffset + 1]) shl 8)
    or (Cardinal(ABytes[AOffset + 2]) shl 16)
    or (Cardinal(ABytes[AOffset + 3]) shl 24);
end;

type
  TByteWriter = record
    Bytes: TBytes;
    Count: Integer;
    procedure Append(const AData: TBytes);
    procedure AppendRaw(const AData: RawByteString);
    procedure U16(const AValue: Word);
    procedure U32(const AValue: Cardinal);
  end;

procedure TByteWriter.Append(const AData: TBytes);
begin
  if Length(AData) = 0 then Exit;
  if Count + Length(AData) > Length(Bytes) then
    SetLength(Bytes, (Count + Length(AData)) * 2);
  Move(AData[0], Bytes[Count], Length(AData));
  Inc(Count, Length(AData));
end;

procedure TByteWriter.AppendRaw(const AData: RawByteString);
var
  Data: TBytes;
begin
  SetLength(Data, Length(AData));
  if AData <> '' then Move(AData[1], Data[0], Length(AData));
  Append(Data);
end;

procedure TByteWriter.U16(const AValue: Word);
var
  Data: TBytes;
begin
  SetLength(Data, 2);
  PutU16(Data, 0, AValue);
  Append(Data);
end;

procedure TByteWriter.U32(const AValue: Cardinal);
var
  Data: TBytes;
begin
  SetLength(Data, 4);
  PutU32(Data, 0, AValue);
  Append(Data);
end;

function TZipSynth.Add(const AName: RawByteString; const AData: TBytes;
  const AMethod: Word): Integer;
var
  E: TZipSynthEntry;
begin
  E := Default(TZipSynthEntry);
  E.Name := AName;
  E.Data := AData;
  E.Method := AMethod;
  E.Level := 6;
  E.Host := ZIP_SYNTH_UNIX;
  E.ExternalAttributes := ZIP_SYNTH_REGULAR_644;
  E.DosTime := $6000;
  E.DosDate := $5A21;
  if FCount = Length(FEntries) then
    SetLength(FEntries, 2 * FCount + 8);
  FEntries[FCount] := E;
  Result := FCount;
  Inc(FCount);
end;

function TZipSynth.AddText(const AName: RawByteString; const AText: string;
  const AMethod: Word): Integer;
begin
  Result := Add(AName, TextBytes(AText), AMethod);
end;

function TZipSynth.AddDirectory(const AName: RawByteString): Integer;
begin
  Result := Add(AName, nil, 0);
  FEntries[Result].ExternalAttributes := ZIP_SYNTH_DIRECTORY_755;
end;

function TZipSynth.Entry(const AIndex: Integer): TZipSynthEntry;
begin
  Result := FEntries[AIndex];
end;

procedure TZipSynth.SetEntry(const AIndex: Integer;
  const AEntry: TZipSynthEntry);
begin
  FEntries[AIndex] := AEntry;
end;

function TZipSynth.Count: Integer;
begin
  Result := FCount;
end;

function TZipSynth.Build: TBytes;
var
  W: TByteWriter;
  Payloads: array of TBytes;
  Crcs, Compressed, Uncompressed: array of Cardinal;
  i, CentralStart: Integer;
  E: TZipSynthEntry;
begin
  SetLength(FEntries, FCount);
  W := Default(TByteWriter);
  SetLength(Payloads, Length(FEntries));
  SetLength(Crcs, Length(FEntries));
  SetLength(Compressed, Length(FEntries));
  SetLength(Uncompressed, Length(FEntries));
  SetLength(LocalOffsets, Length(FEntries));
  SetLength(CentralOffsets, Length(FEntries));
  W.Append(LeadingBytes);
  for i := 0 to High(FEntries) do
  begin
    E := FEntries[i];
    if E.HasPayload then
      Payloads[i] := E.Payload
    else if E.Method = 8 then
      Payloads[i] := RawDeflate(E.Data, E.Level)
    else
      Payloads[i] := E.Data;
    if E.HasCrc then Crcs[i] := E.Crc else Crcs[i] := ZipCrc32(E.Data);
    if E.HasCompressedSize then
      Compressed[i] := E.CompressedSize
    else
      Compressed[i] := Length(Payloads[i]);
    if E.HasUncompressedSize then
      Uncompressed[i] := E.UncompressedSize
    else
      Uncompressed[i] := Length(E.Data);
    if E.Descriptor then E.Flags := E.Flags or $0008;
    FEntries[i].Flags := E.Flags;
    LocalOffsets[i] := W.Count;
    W.U32($04034B50);
    W.U16(20);
    W.U16(E.Flags);
    W.U16(E.Method);
    W.U16(E.DosTime);
    W.U16(E.DosDate);
    if E.Descriptor then
    begin
      W.U32(0);
      W.U32(0);
      W.U32(0);
    end
    else
    begin
      W.U32(Crcs[i]);
      W.U32(Compressed[i]);
      W.U32(Uncompressed[i]);
    end;
    W.U16(Length(E.Name));
    W.U16(Length(E.LocalExtra));
    W.AppendRaw(E.Name);
    W.Append(E.LocalExtra);
    W.Append(Payloads[i]);
    if E.Descriptor then
    begin
      if E.DescriptorSignature then W.U32($08074B50);
      W.U32(Crcs[i]);
      W.U32(Compressed[i]);
      W.U32(Uncompressed[i]);
    end;
    W.Append(E.GapAfter);
  end;
  CentralStart := W.Count;
  for i := 0 to High(FEntries) do
  begin
    E := FEntries[i];
    CentralOffsets[i] := W.Count;
    W.U32($02014B50);
    W.U16(Word(E.Host) shl 8 or 20);
    W.U16(20);
    W.U16(E.Flags);
    W.U16(E.Method);
    W.U16(E.DosTime);
    W.U16(E.DosDate);
    W.U32(Crcs[i]);
    W.U32(Compressed[i]);
    W.U32(Uncompressed[i]);
    W.U16(Length(E.Name));
    W.U16(Length(E.CentralExtra));
    W.U16(Length(E.Comment));
    W.U16(0);
    W.U16(0);
    W.U32(E.ExternalAttributes);
    W.U32(LocalOffsets[i]);
    W.AppendRaw(E.Name);
    W.Append(E.CentralExtra);
    W.AppendRaw(E.Comment);
  end;
  EndOffset := W.Count;
  W.U32($06054B50);
  W.U16(0);
  W.U16(0);
  W.U16(Length(FEntries));
  W.U16(Length(FEntries));
  W.U32(EndOffset - CentralStart);
  W.U32(CentralStart);
  W.U16(Length(Comment));
  W.AppendRaw(Comment);
  W.Append(TrailingBytes);
  Result := System.Copy(W.Bytes, 0, W.Count);
end;

end.
