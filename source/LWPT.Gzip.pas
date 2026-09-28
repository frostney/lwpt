{ LWPT.Gzip — RFC 1952 gzip decoding between caller-owned streams.

  FPC 3.2.2's TGZFileStream opens its file through paszlib's gzopen, whose
  path parameter is a 255-character shortstring: a longer archive path is
  truncated and the open fails with "Could not open gzip compressed file"
  (issue #309). Decoding from a TStream lets the caller open the archive
  through LWPT.Core's protected file helpers, so only the operating system
  bounds the path.

  Every member is verified in full: the deflate method, the reserved flag
  bits, the optional FEXTRA, FNAME and FCOMMENT fields, the FHCRC header
  checksum, and the CRC-32 and ISIZE trailer. Concatenated members decode in
  sequence, as RFC 1952 section 2.2 allows. Bytes after the last member that
  do not begin another member are ignored, as gzip(1) ignores them. Any other
  malformation raises EExtractError, so a truncated or corrupt archive can
  never be mistaken for a complete one. }
unit LWPT.Gzip;

{$I Shared.inc}

interface

uses
  Classes;

{ Decompresses every gzip member from ASource's current position to its end
  into ATarget. Raises EExtractError when ASource is not a gzip stream, when
  a member is truncated or corrupt, or when a checksum does not match. }
procedure GunzipStream(const ASource, ATarget: TStream);

implementation

uses
  SysUtils,

  crc,
  LWPT.Core,
  zbase,
  zinflate;

const
  GZIP_ID1 = $1F;
  GZIP_ID2 = $8B;
  GZIP_METHOD_DEFLATE = 8;
  GZIP_FLAG_HEADER_CRC = $02;
  GZIP_FLAG_EXTRA = $04;
  GZIP_FLAG_NAME = $08;
  GZIP_FLAG_COMMENT = $10;
  GZIP_FLAG_RESERVED = $E0;
  { Bytes after the flag byte that carry no structure: MTIME (4), XFL, OS. }
  GZIP_FIXED_TAIL_LENGTH = 6;
  GZIP_BUFFER_SIZE = 64 * 1024;

type
  TGzipDecoder = class
  private
    FSource, FTarget: TStream;
    FInput, FOutput: array[0..GZIP_BUFFER_SIZE - 1] of Byte;
    FPosition, FCount: Integer;
    FHeaderCrc: Cardinal;
    function Available: Integer;
    function Ensure(const ACount: Integer): Boolean;
    function ReadByte(const APart: string): Byte;
    function ReadHeaderByte: Byte;
    function ReadLittleEndian32: Cardinal;
    procedure SkipZeroTerminatedHeaderField;
    procedure ReadHeader;
    procedure Inflate(out ACrc: Cardinal; out ASize: QWord);
    procedure DecodeMember;
  public
    constructor Create(const ASource, ATarget: TStream);
    procedure Run;
  end;

procedure RaiseTruncated(const APart: string);
begin
  raise EExtractError.CreateFmt('gzip stream is truncated in its %s',
    [APart]);
end;

constructor TGzipDecoder.Create(const ASource, ATarget: TStream);
begin
  inherited Create;
  FSource := ASource;
  FTarget := ATarget;
end;

function TGzipDecoder.Available: Integer;
begin
  Result := FCount - FPosition;
end;

{ Buffers at least ACount unread bytes; False when the source ends first. }
function TGzipDecoder.Ensure(const ACount: Integer): Boolean;
var
  Remaining, ReadCount: Integer;
begin
  if Available >= ACount then Exit(True);
  Remaining := Available;
  if (Remaining > 0) and (FPosition > 0) then
    Move(FInput[FPosition], FInput[0], Remaining);
  FPosition := 0;
  FCount := Remaining;
  while FCount < ACount do
  begin
    ReadCount := FSource.Read(FInput[FCount], GZIP_BUFFER_SIZE - FCount);
    if ReadCount <= 0 then Exit(False);
    Inc(FCount, ReadCount);
  end;
  Result := True;
end;

function TGzipDecoder.ReadByte(const APart: string): Byte;
begin
  if not Ensure(1) then RaiseTruncated(APart);
  Result := FInput[FPosition];
  Inc(FPosition);
end;

function TGzipDecoder.ReadHeaderByte: Byte;
begin
  Result := ReadByte('header');
  FHeaderCrc := crc32(FHeaderCrc, @Result, 1);
end;

function TGzipDecoder.ReadLittleEndian32: Cardinal;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to 3 do
    Result := Result or (Cardinal(ReadByte('trailer')) shl (8 * i));
end;

procedure TGzipDecoder.SkipZeroTerminatedHeaderField;
begin
  while ReadHeaderByte <> 0 do;
end;

procedure TGzipDecoder.ReadHeader;
var
  Method, Flags: Byte;
  ExtraLength, StoredCrc: Cardinal;
  i: Integer;
begin
  FHeaderCrc := crc32(0, nil, 0);
  if (ReadHeaderByte <> GZIP_ID1) or (ReadHeaderByte <> GZIP_ID2) then
    raise EExtractError.Create('archive is not a gzip stream');
  Method := ReadHeaderByte;
  if Method <> GZIP_METHOD_DEFLATE then
    raise EExtractError.CreateFmt(
      'gzip header names unsupported compression method %d', [Method]);
  Flags := ReadHeaderByte;
  if (Flags and GZIP_FLAG_RESERVED) <> 0 then
    raise EExtractError.CreateFmt(
      'gzip header sets reserved flag bits ($%.2x)', [Flags]);
  for i := 1 to GZIP_FIXED_TAIL_LENGTH do
    ReadHeaderByte;
  if (Flags and GZIP_FLAG_EXTRA) <> 0 then
  begin
    ExtraLength := ReadHeaderByte;
    ExtraLength := ExtraLength or (Cardinal(ReadHeaderByte) shl 8);
    for i := 1 to Integer(ExtraLength) do
      ReadHeaderByte;
  end;
  if (Flags and GZIP_FLAG_NAME) <> 0 then
    SkipZeroTerminatedHeaderField;
  if (Flags and GZIP_FLAG_COMMENT) <> 0 then
    SkipZeroTerminatedHeaderField;
  if (Flags and GZIP_FLAG_HEADER_CRC) <> 0 then
  begin
    { The CRC16 is the low half of the CRC-32 of every preceding header
      byte, so it is read without folding it into FHeaderCrc. }
    StoredCrc := ReadByte('header');
    StoredCrc := StoredCrc or (Cardinal(ReadByte('header')) shl 8);
    if StoredCrc <> (FHeaderCrc and $FFFF) then
      raise EExtractError.CreateFmt(
        'gzip header checksum mismatch: stored $%.4x, computed $%.4x',
        [StoredCrc, FHeaderCrc and $FFFF]);
  end;
end;

procedure TGzipDecoder.Inflate(out ACrc: Cardinal; out ASize: QWord);
var
  Stream: z_stream;
  Status, Offered, Consumed, Produced: Integer;
begin
  ACrc := crc32(0, nil, 0);
  ASize := 0;
  Stream := Default(z_stream);
  { Negative window bits select a raw deflate stream: the gzip framing is
    parsed here, not by paszlib, which only knows the zlib wrapper. }
  Status := inflateInit2(Stream, -MAX_WBITS);
  if Status <> Z_OK then
    raise EExtractError.CreateFmt('gzip decoder failed to start: %s',
      [zError(Status)]);
  try
    repeat
      if not Ensure(1) then RaiseTruncated('compressed data');
      Offered := Available;
      Stream.next_in := @FInput[FPosition];
      Stream.avail_in := Offered;
      Stream.next_out := @FOutput[0];
      Stream.avail_out := GZIP_BUFFER_SIZE;
      Status := zinflate.inflate(Stream, Z_NO_FLUSH);
      Consumed := Offered - Integer(Stream.avail_in);
      Inc(FPosition, Consumed);
      Produced := GZIP_BUFFER_SIZE - Integer(Stream.avail_out);
      if Produced > 0 then
      begin
        ACrc := crc32(ACrc, @FOutput[0], Produced);
        FTarget.WriteBuffer(FOutput[0], Produced);
        Inc(ASize, Produced);
      end;
      case Status of
        Z_STREAM_END:
          Break;
        Z_OK:
          ;
        Z_BUF_ERROR:
          { More input is needed; anything else is a stalled decoder. }
          if (Consumed > 0) or (Produced > 0) or (Stream.avail_in = 0) then
            Continue
          else
            raise EExtractError.Create('corrupt gzip data: decoder stalled');
      else
        if Stream.msg <> '' then
          raise EExtractError.CreateFmt('corrupt gzip data: %s',
            [string(Stream.msg)])
        else
          raise EExtractError.CreateFmt('corrupt gzip data: %s',
            [zError(Status)]);
      end;
    until False;
  finally
    inflateEnd(Stream);
  end;
end;

procedure TGzipDecoder.DecodeMember;
var
  ComputedCrc, StoredCrc, StoredSize: Cardinal;
  Size: QWord;
begin
  ReadHeader;
  Inflate(ComputedCrc, Size);
  StoredCrc := ReadLittleEndian32;
  StoredSize := ReadLittleEndian32;
  if StoredCrc <> ComputedCrc then
    raise EExtractError.CreateFmt(
      'gzip CRC-32 mismatch: stored $%.8x, computed $%.8x',
      [StoredCrc, ComputedCrc]);
  { ISIZE is the member's uncompressed length modulo 2^32. }
  if StoredSize <> Cardinal(Size and $FFFFFFFF) then
    raise EExtractError.CreateFmt(
      'gzip length mismatch: stored %d, decoded %d', [StoredSize, Size]);
end;

procedure TGzipDecoder.Run;
begin
  DecodeMember;
  while Ensure(2) and (FInput[FPosition] = GZIP_ID1)
    and (FInput[FPosition + 1] = GZIP_ID2) do
    DecodeMember;
end;

procedure GunzipStream(const ASource, ATarget: TStream);
var
  Decoder: TGzipDecoder;
begin
  Decoder := TGzipDecoder.Create(ASource, ATarget);
  try
    Decoder.Run;
  finally
    Decoder.Free;
  end;
end;

end.
