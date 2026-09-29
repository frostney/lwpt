{ LWPT.Zip — a bounded, in-tree zip container reader (ADR-0049, "Zip
  normalization", container rules and payload decoding).

  FPC's zipper unit is not built by LWPT's cross toolchain, so this reader
  works on zinflate and crc, as LWPT.Gzip does. The whole archive is held
  in memory and the central directory is authoritative. Opening an archive
  validates the complete container before any payload is decoded:

  - the input is at most the caller's input bound;
  - exactly one end-of-central-directory record ends the input, its comment
    accounting for every trailing byte;
  - every disk field is 0 and the entry counts agree (no multi-disk or
    split archives);
  - ZIP64 is refused in every form: the locator, the ZIP64 end record,
    0xFFFF/0xFFFFFFFF sentinels, and extra field 0x0001;
  - the entry count and the central-directory size (at least 46 bytes per
    declared entry) are checked before anything is allocated;
  - the central directory ends exactly where the end record begins, and its
    headers fill it exactly;
  - only methods 0 (stored, with equal sizes) and 8 (deflate), and only
    flag bits 1, 2, 3, and 11 are accepted; encryption (bits 0 and 6, AES
    method 99) and every other method or flag is refused;
  - extra fields parse within their declared lengths;
  - the declared uncompressed sizes total at most the expanded bound;
  - the local records fill [0, central-directory offset) in
    central-directory order with no gaps, overlaps, or prepended data, each
    repeating its central entry's name bytes, method, and flags, and its CRC
    and sizes unless it uses a data descriptor, whose local values must then
    be zero or equal and whose 12- or 16-byte descriptor must follow the data
    and match the central values.

  DecodeEntry decodes exactly the declared compressed slice. Deflate must
  reach Z_STREAM_END exactly when the slice is consumed and the output
  reaches the declared size; inflation stops one byte past the declared
  size. Stored entries are copied, never inflated. Both then check the
  CRC-32. }
unit LWPT.Zip;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  LWPT.Archive;

const
  ZIP_METHOD_STORED = 0;
  ZIP_METHOD_DEFLATE = 8;
  ZIP_METHOD_AES = 99;
  ZIP_FLAG_ENCRYPTED = $0001;
  ZIP_FLAG_DEFLATE_OPTIONS = $0006;
  ZIP_FLAG_DATA_DESCRIPTOR = $0008;
  ZIP_FLAG_STRONG_ENCRYPTION = $0040;
  ZIP_FLAG_UTF8 = $0800;
  ZIP_ALLOWED_FLAGS = ZIP_FLAG_DEFLATE_OPTIONS or ZIP_FLAG_DATA_DESCRIPTOR
    or ZIP_FLAG_UTF8;
  ZIP_HOST_MSDOS = 0;
  ZIP_HOST_UNIX = 3;
  ZIP_CENTRAL_HEADER_BYTES = 46;
  ZIP_LOCAL_HEADER_BYTES = 30;
  ZIP_END_RECORD_BYTES = 22;

type
  TLWPTZipEntry = record
    { The name bytes exactly as stored. }
    Name: RawByteString;
    VersionMadeBy: Word;
    Flags: Word;
    Method: Word;
    Crc32: Cardinal;
    CompressedSize: Int64;
    UncompressedSize: Int64;
    ExternalAttributes: Cardinal;
    LocalHeaderOffset: Int64;
    DataOffset: Int64;
    function HostSystem: Byte;
  end;
  TLWPTZipEntryArray = array of TLWPTZipEntry;

  TLWPTZipArchive = class
  private
    FData: TBytes;
    FLimits: TLWPTArchiveLimits;
    FEntries: TLWPTZipEntryArray;
    FDeclaredExpandedBytes: Int64;
    FCentralOffset: Int64;
    function U16(const AOffset: Int64): Word;
    function U32(const AOffset: Int64): Cardinal;
    function LocateEndRecord: Int64;
    procedure ReadCentralDirectory(const AEndOffset: Int64);
    procedure CheckExtraField(const AOffset, ALength: Int64;
      const AWhere: string);
    procedure CheckLocalRecords;
    function Entry(const AIndex: Integer): TLWPTZipEntry;
  public
    { Validates the whole container. AData is referenced, not copied. }
    constructor Create(const AData: TBytes;
      const ALimits: TLWPTArchiveLimits);
    { Decodes entry AIndex into ATarget. On failure ATarget holds a partial
      payload the caller must discard. }
    procedure DecodeEntry(const AIndex: Integer; const ATarget: TStream);
    function Count: Integer;
    property Entries[const AIndex: Integer]: TLWPTZipEntry read Entry;
    property DeclaredExpandedBytes: Int64 read FDeclaredExpandedBytes;
  end;

implementation

uses
  crc,
  zbase,
  zinflate;

const
  SIG_LOCAL = $04034B50;
  SIG_CENTRAL = $02014B50;
  SIG_END = $06054B50;
  SIG_ZIP64_END = $06064B50;
  SIG_ZIP64_LOCATOR = $07064B50;
  SIG_DESCRIPTOR = $08074B50;
  ZIP64_EXTRA_ID = $0001;
  ZIP64_LOCATOR_BYTES = 20;
  MAX_COMMENT_BYTES = $FFFF;
  DECODE_BUFFER_BYTES = 64 * 1024;

procedure RaiseInvalid(const ADetail: string);
begin
  raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID, 'zip ' + ADetail);
end;

procedure RaiseUnsupported(const ADetail: string);
begin
  raise ELWPTArchiveError.CreateStable(ARCHIVE_UNSUPPORTED, 'zip ' + ADetail);
end;

function TLWPTZipEntry.HostSystem: Byte;
begin
  Result := Byte(VersionMadeBy shr 8);
end;

constructor TLWPTZipArchive.Create(const AData: TBytes;
  const ALimits: TLWPTArchiveLimits);
var
  EndOffset: Int64;
begin
  inherited Create;
  FData := AData;
  FLimits := ALimits;
  if Length(FData) > FLimits.MaximumInputBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'zip input is %d bytes; the limit is %d',
      [Int64(Length(FData)), FLimits.MaximumInputBytes]);
  EndOffset := LocateEndRecord;
  ReadCentralDirectory(EndOffset);
  CheckLocalRecords;
end;

function TLWPTZipArchive.Count: Integer;
begin
  Result := Length(FEntries);
end;

function TLWPTZipArchive.Entry(const AIndex: Integer): TLWPTZipEntry;
begin
  Result := FEntries[AIndex];
end;

function TLWPTZipArchive.U16(const AOffset: Int64): Word;
begin
  Result := Word(FData[AOffset]) or (Word(FData[AOffset + 1]) shl 8);
end;

function TLWPTZipArchive.U32(const AOffset: Int64): Cardinal;
begin
  Result := Cardinal(FData[AOffset])
    or (Cardinal(FData[AOffset + 1]) shl 8)
    or (Cardinal(FData[AOffset + 2]) shl 16)
    or (Cardinal(FData[AOffset + 3]) shl 24);
end;

{ The end record must end exactly at the end of the input. More than one
  candidate that does so is ambiguous, so it is refused rather than guessed:
  another reader could pick the other one. }
function TLWPTZipArchive.LocateEndRecord: Int64;
var
  Offset, Lowest, Found: Int64;
  Candidates: Integer;
begin
  Found := -1;
  Candidates := 0;
  Lowest := Int64(Length(FData)) - ZIP_END_RECORD_BYTES - MAX_COMMENT_BYTES;
  if Lowest < 0 then Lowest := 0;
  Offset := Int64(Length(FData)) - ZIP_END_RECORD_BYTES;
  while Offset >= Lowest do
  begin
    if (U32(Offset) = SIG_END)
       and (Offset + ZIP_END_RECORD_BYTES + U16(Offset + 20)
            = Length(FData)) then
    begin
      Inc(Candidates);
      if Found < 0 then Found := Offset;
    end;
    Dec(Offset);
  end;
  if Candidates = 0 then
    RaiseInvalid('has no end-of-central-directory record ending the input');
  if Candidates > 1 then
    RaiseInvalid('has more than one end-of-central-directory record '
      + 'ending the input');
  Result := Found;
end;

procedure TLWPTZipArchive.CheckExtraField(const AOffset, ALength: Int64;
  const AWhere: string);
var
  Cursor, Stop: Int64;
  Id, Size: Word;
begin
  Cursor := AOffset;
  Stop := AOffset + ALength;
  while Cursor < Stop do
  begin
    if Stop - Cursor < 4 then
      RaiseInvalid(AWhere + ' extra field does not parse');
    Id := U16(Cursor);
    Size := U16(Cursor + 2);
    if Cursor + 4 + Size > Stop then
      RaiseInvalid(AWhere + ' extra field overruns its declared length');
    if Id = ZIP64_EXTRA_ID then
      RaiseUnsupported(AWhere + ' carries a ZIP64 extra field');
    Inc(Cursor, 4 + Size);
  end;
end;

procedure TLWPTZipArchive.ReadCentralDirectory(const AEndOffset: Int64);
var
  DiskNumber, CentralDisk, DiskEntries, TotalEntries: Word;
  CentralSize, CentralOffset, CompressedSize, UncompressedSize,
    LocalOffset: Cardinal;
  Cursor: Int64;
  NameLength, ExtraLength, CommentLength, StartDisk: Word;
  i: Integer;
  E: TLWPTZipEntry;
  Where: string;
begin
  if (AEndOffset >= ZIP64_LOCATOR_BYTES)
     and (U32(AEndOffset - ZIP64_LOCATOR_BYTES) = SIG_ZIP64_LOCATOR) then
    RaiseUnsupported('uses ZIP64 (end-of-central-directory locator)');
  DiskNumber := U16(AEndOffset + 4);
  CentralDisk := U16(AEndOffset + 6);
  DiskEntries := U16(AEndOffset + 8);
  TotalEntries := U16(AEndOffset + 10);
  CentralSize := U32(AEndOffset + 12);
  CentralOffset := U32(AEndOffset + 16);
  if (DiskNumber = $FFFF) or (CentralDisk = $FFFF) or (DiskEntries = $FFFF)
     or (TotalEntries = $FFFF) or (CentralSize = $FFFFFFFF)
     or (CentralOffset = $FFFFFFFF) then
    RaiseUnsupported('uses ZIP64 (end-record sentinel)');
  if (DiskNumber <> 0) or (CentralDisk <> 0)
     or (DiskEntries <> TotalEntries) then
    RaiseUnsupported('spans more than one disk');
  if TotalEntries > FLimits.MaximumZipEntries then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'zip declares %d entries; the limit is %d',
      [TotalEntries, FLimits.MaximumZipEntries]);
  if Int64(CentralSize) < Int64(TotalEntries) * ZIP_CENTRAL_HEADER_BYTES then
    RaiseInvalid('central directory is too small for its declared entries');
  if Int64(CentralOffset) + CentralSize <> AEndOffset then
    RaiseInvalid('central directory does not end where the end record '
      + 'begins');
  FCentralOffset := CentralOffset;
  SetLength(FEntries, TotalEntries);
  FDeclaredExpandedBytes := 0;
  Cursor := CentralOffset;
  for i := 0 to TotalEntries - 1 do
  begin
    Where := Format('central entry %d', [i]);
    if Cursor + ZIP_CENTRAL_HEADER_BYTES > AEndOffset then
      RaiseInvalid(Where + ' overruns the central directory');
    if U32(Cursor) = SIG_ZIP64_END then
      RaiseUnsupported('uses ZIP64 (end-of-central-directory record)');
    if U32(Cursor) <> SIG_CENTRAL then
      RaiseInvalid(Where + ' has no central header signature');
    E := Default(TLWPTZipEntry);
    E.VersionMadeBy := U16(Cursor + 4);
    E.Flags := U16(Cursor + 8);
    E.Method := U16(Cursor + 10);
    E.Crc32 := U32(Cursor + 16);
    CompressedSize := U32(Cursor + 20);
    UncompressedSize := U32(Cursor + 24);
    NameLength := U16(Cursor + 28);
    ExtraLength := U16(Cursor + 30);
    CommentLength := U16(Cursor + 32);
    StartDisk := U16(Cursor + 34);
    E.ExternalAttributes := U32(Cursor + 38);
    LocalOffset := U32(Cursor + 42);
    if Cursor + ZIP_CENTRAL_HEADER_BYTES + NameLength + ExtraLength
       + CommentLength > AEndOffset then
      RaiseInvalid(Where + ' overruns the central directory');
    if (CompressedSize = $FFFFFFFF) or (UncompressedSize = $FFFFFFFF)
       or (LocalOffset = $FFFFFFFF) or (StartDisk = $FFFF) then
      RaiseUnsupported(Where + ' uses ZIP64 (size or offset sentinel)');
    if StartDisk <> 0 then
      RaiseUnsupported(Where + ' starts on another disk');
    SetLength(E.Name, NameLength);
    if NameLength > 0 then
      Move(FData[Cursor + ZIP_CENTRAL_HEADER_BYTES], E.Name[1], NameLength);
    CheckExtraField(Cursor + ZIP_CENTRAL_HEADER_BYTES + NameLength,
      ExtraLength, Where);
    if (E.Flags and (ZIP_FLAG_ENCRYPTED or ZIP_FLAG_STRONG_ENCRYPTION)) <> 0
       then
      RaiseUnsupported(Where + ' is encrypted');
    if E.Method = ZIP_METHOD_AES then
      RaiseUnsupported(Where + ' is encrypted (AES)');
    if (E.Flags and not ZIP_ALLOWED_FLAGS) <> 0 then
      RaiseUnsupported(Format('%s sets unsupported flags $%.4x',
        [Where, E.Flags and not ZIP_ALLOWED_FLAGS]));
    if (E.Method <> ZIP_METHOD_STORED) and (E.Method <> ZIP_METHOD_DEFLATE)
       then
      RaiseUnsupported(Format('%s uses unsupported method %d',
        [Where, E.Method]));
    if (E.Method = ZIP_METHOD_STORED)
       and (CompressedSize <> UncompressedSize) then
      RaiseInvalid(Where + ' is stored with differing sizes');
    E.CompressedSize := CompressedSize;
    E.UncompressedSize := UncompressedSize;
    E.LocalHeaderOffset := LocalOffset;
    FEntries[i] := E;
    Inc(FDeclaredExpandedBytes, UncompressedSize);
    Inc(Cursor, ZIP_CENTRAL_HEADER_BYTES + NameLength + ExtraLength
      + CommentLength);
  end;
  if Cursor <> AEndOffset then
    RaiseInvalid('central directory has bytes after its declared entries');
  if FDeclaredExpandedBytes > FLimits.MaximumExpandedBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'zip declares %d uncompressed bytes; the limit is %d',
      [FDeclaredExpandedBytes, FLimits.MaximumExpandedBytes]);
end;

procedure TLWPTZipArchive.CheckLocalRecords;
var
  Expected, DataEnd: Int64;
  i: Integer;
  E: TLWPTZipEntry;
  Where: string;
  NameLength, ExtraLength: Word;
  LocalCrc, LocalCompressed, LocalUncompressed: Cardinal;
  Descriptor: Boolean;

  function Matches(const AOffset: Int64): Boolean;
  begin
    Result := (AOffset + 12 <= FCentralOffset)
      and (U32(AOffset) = E.Crc32)
      and (U32(AOffset + 4) = Cardinal(E.CompressedSize))
      and (U32(AOffset + 8) = Cardinal(E.UncompressedSize));
  end;

  function ZeroOrEqual(const ALocal, ACentral: Cardinal): Boolean;
  begin
    Result := (ALocal = 0) or (ALocal = ACentral);
  end;

begin
  Expected := 0;
  for i := 0 to High(FEntries) do
  begin
    E := FEntries[i];
    Where := Format('entry %d', [i]);
    if E.LocalHeaderOffset < Expected then
      RaiseInvalid(Where + ' overlaps the previous record');
    if E.LocalHeaderOffset > Expected then
    begin
      if i = 0 then
        RaiseInvalid('has data before its first local header');
      RaiseInvalid(Where + ' leaves a gap after the previous record');
    end;
    if Expected + ZIP_LOCAL_HEADER_BYTES > FCentralOffset then
      RaiseInvalid(Where + ' local header overruns the central directory');
    if U32(Expected) <> SIG_LOCAL then
      RaiseInvalid(Where + ' has no local header signature');
    if (U16(Expected + 6) <> E.Flags) or (U16(Expected + 8) <> E.Method) then
      RaiseInvalid(Where + ' local header disagrees with its central '
        + 'method or flags');
    LocalCrc := U32(Expected + 14);
    LocalCompressed := U32(Expected + 18);
    LocalUncompressed := U32(Expected + 22);
    NameLength := U16(Expected + 26);
    ExtraLength := U16(Expected + 28);
    if (LocalCompressed = $FFFFFFFF) or (LocalUncompressed = $FFFFFFFF) then
      RaiseUnsupported(Where + ' uses ZIP64 (local size sentinel)');
    if Expected + ZIP_LOCAL_HEADER_BYTES + NameLength + ExtraLength
       > FCentralOffset then
      RaiseInvalid(Where + ' local header overruns the central directory');
    if (NameLength <> Length(E.Name)) or ((NameLength > 0)
       and (CompareByte(FData[Expected + ZIP_LOCAL_HEADER_BYTES], E.Name[1],
         NameLength) <> 0)) then
      RaiseInvalid(Where + ' local name differs from its central name');
    CheckExtraField(Expected + ZIP_LOCAL_HEADER_BYTES + NameLength,
      ExtraLength, Where + ' local');
    Descriptor := (E.Flags and ZIP_FLAG_DATA_DESCRIPTOR) <> 0;
    if Descriptor then
    begin
      if not ZeroOrEqual(LocalCrc, E.Crc32)
         or not ZeroOrEqual(LocalCompressed, E.CompressedSize)
         or not ZeroOrEqual(LocalUncompressed, E.UncompressedSize) then
        RaiseInvalid(Where + ' local CRC or sizes disagree with the '
          + 'central directory');
    end
    else if (LocalCrc <> E.Crc32) or (LocalCompressed <> E.CompressedSize)
         or (LocalUncompressed <> E.UncompressedSize) then
      RaiseInvalid(Where + ' local CRC or sizes disagree with the central '
        + 'directory');
    E.DataOffset := Expected + ZIP_LOCAL_HEADER_BYTES + NameLength
      + ExtraLength;
    DataEnd := E.DataOffset + E.CompressedSize;
    if DataEnd > FCentralOffset then
      RaiseInvalid(Where + ' data overruns the central directory');
    Expected := DataEnd;
    if Descriptor then
    begin
      if (DataEnd + 16 <= FCentralOffset)
         and (U32(DataEnd) = SIG_DESCRIPTOR) and Matches(DataEnd + 4) then
        Expected := DataEnd + 16
      else if Matches(DataEnd) then
        Expected := DataEnd + 12
      else
        RaiseInvalid(Where + ' data descriptor is missing or disagrees '
          + 'with the central directory');
    end;
    FEntries[i] := E;
  end;
  if Expected <> FCentralOffset then
    RaiseInvalid('has bytes between its last record and the central '
      + 'directory');
end;

procedure TLWPTZipArchive.DecodeEntry(const AIndex: Integer;
  const ATarget: TStream);
var
  E: TLWPTZipEntry;
  Buffer: array[0..DECODE_BUFFER_BYTES - 1] of Byte;
  Stream: z_stream;
  Status, Got, Room: Integer;
  Produced, Remaining, Offered: Int64;
  Crc: Cardinal;
  Where: string;
  Source: PByte;
begin
  E := FEntries[AIndex];
  Where := Format('entry %d', [AIndex]);
  Crc := crc32(0, nil, 0);
  Source := PByte(@FData[0]) + E.DataOffset;
  if E.Method = ZIP_METHOD_STORED then
  begin
    Remaining := E.CompressedSize;
    while Remaining > 0 do
    begin
      Got := DECODE_BUFFER_BYTES;
      if Got > Remaining then Got := Integer(Remaining);
      Crc := crc32(Crc, Source, Got);
      ATarget.WriteBuffer(Source^, Got);
      Inc(Source, Got);
      Dec(Remaining, Got);
    end;
  end
  else
  begin
    Stream := Default(z_stream);
    Status := inflateInit2(Stream, -MAX_WBITS);
    if Status <> Z_OK then
      RaiseInvalid(Where + ' decoder failed to start');
    try
      Stream.next_in := Source;
      Stream.avail_in := Cardinal(E.CompressedSize);
      Produced := 0;
      repeat
        { Room for at most one byte past the declared size. }
        Offered := E.UncompressedSize + 1 - Produced;
        if Offered > DECODE_BUFFER_BYTES then Offered := DECODE_BUFFER_BYTES;
        Room := Integer(Offered);
        Stream.next_out := @Buffer[0];
        Stream.avail_out := Room;
        Status := zinflate.inflate(Stream, Z_NO_FLUSH);
        Got := Room - Integer(Stream.avail_out);
        if Got > 0 then
        begin
          if Produced + Got > E.UncompressedSize then
            raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
              'zip %s inflates past its declared %d bytes',
              [Where, E.UncompressedSize]);
          Crc := crc32(Crc, @Buffer[0], Got);
          ATarget.WriteBuffer(Buffer[0], Got);
          Inc(Produced, Got);
        end;
        case Status of
          Z_STREAM_END:
            Break;
          Z_OK:
            ;
          Z_BUF_ERROR:
            if Stream.avail_in = 0 then
              RaiseInvalid(Where + ' compressed slice ends before its '
                + 'deflate stream does')
            else if Got = 0 then
              RaiseInvalid(Where + ' deflate decoder stalled');
        else
          RaiseInvalid(Where + ' holds corrupt deflate data');
        end;
      until False;
      if Stream.avail_in <> 0 then
        RaiseInvalid(Where + ' has compressed bytes after the end of its '
          + 'deflate stream');
      if Produced <> E.UncompressedSize then
        RaiseInvalid(Format('%s inflates to %d bytes, short of its declared '
          + '%d', [Where, Produced, E.UncompressedSize]));
    finally
      inflateEnd(Stream);
    end;
  end;
  if Crc <> E.Crc32 then
    RaiseInvalid(Format('%s CRC-32 mismatch: declared $%.8x, computed $%.8x',
      [Where, E.Crc32, Crc]));
end;

end.
