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
  sequence, as RFC 1952 section 2.2 allows. After a member, the stream may
  end or continue with zero padding to its end; any other byte starts a
  member that must decode in full. Every other malformation raises
  EExtractError, so a truncated or corrupt archive can never be mistaken for
  a complete one.

  Decompressed output is not size-limited here, as it was not by paszlib's
  gzread: the fetched archive is bounded, the expansion is not. }
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
  GzipId1 = $1F;
  GzipId2 = $8B;
  GzipMethodDeflate = 8;
  GzipFlagHeaderCrc = $02;
  GzipFlagExtra = $04;
  GzipFlagName = $08;
  GzipFlagComment = $10;
  GzipFlagReserved = $E0;
  { Bytes after the flag byte that carry no structure: MTIME (4), XFL, OS. }
  GzipFixedTailLength = 6;
  GzipBufferSize = 64 * 1024;

type
  TLWPTGzipDecoder = class
  private
    FSource, FTarget: TStream;
    FInput, FOutput: array[0..GzipBufferSize - 1] of Byte;
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
    procedure SkipZeroPadding;
  public
    constructor Create(const ASource, ATarget: TStream);
    procedure Run;
  end;

procedure RaiseTruncated(const APart: string);
begin
  raise EExtractError.CreateFmt('gzip stream is truncated in its %s',
    [APart]);
end;

constructor TLWPTGzipDecoder.Create(const ASource, ATarget: TStream);
begin
  inherited Create;
  FSource := ASource;
  FTarget := ATarget;
end;

function TLWPTGzipDecoder.Available: Integer;
begin
  Result := FCount - FPosition;
end;

{ Buffers at least ACount unread bytes; False when the source ends first. }
function TLWPTGzipDecoder.Ensure(const ACount: Integer): Boolean;
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
    ReadCount := FSource.Read(FInput[FCount], GzipBufferSize - FCount);
    if ReadCount <= 0 then Exit(False);
    Inc(FCount, ReadCount);
  end;
  Result := True;
end;

function TLWPTGzipDecoder.ReadByte(const APart: string): Byte;
begin
  if not Ensure(1) then RaiseTruncated(APart);
  Result := FInput[FPosition];
  Inc(FPosition);
end;

function TLWPTGzipDecoder.ReadHeaderByte: Byte;
begin
  Result := ReadByte('header');
  FHeaderCrc := crc32(FHeaderCrc, @Result, 1);
end;

function TLWPTGzipDecoder.ReadLittleEndian32: Cardinal;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to 3 do
    Result := Result or (Cardinal(ReadByte('trailer')) shl (8 * i));
end;

procedure TLWPTGzipDecoder.SkipZeroTerminatedHeaderField;
begin
  while ReadHeaderByte <> 0 do;
end;

procedure TLWPTGzipDecoder.ReadHeader;
var
  Method, Flags: Byte;
  ExtraLength, StoredCrc: Cardinal;
  i: Integer;
begin
  FHeaderCrc := crc32(0, nil, 0);
  if (ReadHeaderByte <> GzipId1) or (ReadHeaderByte <> GzipId2) then
    raise EExtractError.Create('archive is not a gzip stream');
  Method := ReadHeaderByte;
  if Method <> GzipMethodDeflate then
    raise EExtractError.CreateFmt(
      'gzip header names unsupported compression method %d', [Method]);
  Flags := ReadHeaderByte;
  if (Flags and GzipFlagReserved) <> 0 then
    raise EExtractError.CreateFmt(
      'gzip header sets reserved flag bits ($%.2x)', [Flags]);
  for i := 1 to GzipFixedTailLength do
    ReadHeaderByte;
  if (Flags and GzipFlagExtra) <> 0 then
  begin
    ExtraLength := ReadHeaderByte;
    ExtraLength := ExtraLength or (Cardinal(ReadHeaderByte) shl 8);
    for i := 1 to Integer(ExtraLength) do
      ReadHeaderByte;
  end;
  if (Flags and GzipFlagName) <> 0 then
    SkipZeroTerminatedHeaderField;
  if (Flags and GzipFlagComment) <> 0 then
    SkipZeroTerminatedHeaderField;
  if (Flags and GzipFlagHeaderCrc) <> 0 then
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

procedure TLWPTGzipDecoder.Inflate(out ACrc: Cardinal; out ASize: QWord);
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
      Stream.avail_out := GzipBufferSize;
      Status := zinflate.inflate(Stream, Z_NO_FLUSH);
      Consumed := Offered - Integer(Stream.avail_in);
      Inc(FPosition, Consumed);
      Produced := GzipBufferSize - Integer(Stream.avail_out);
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

procedure TLWPTGzipDecoder.DecodeMember;
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

{ Consumes the rest of the stream, which must be all zero bytes. }
procedure TLWPTGzipDecoder.SkipZeroPadding;
begin
  while Ensure(1) do
  begin
    if FInput[FPosition] <> 0 then
      raise EExtractError.Create(
        'gzip stream has data after its trailing zero padding');
    Inc(FPosition);
  end;
end;

procedure TLWPTGzipDecoder.Run;
begin
  DecodeMember;
  while Ensure(1) do
    if FInput[FPosition] = 0 then
      SkipZeroPadding
    else
      DecodeMember;
end;

procedure GunzipStream(const ASource, ATarget: TStream);
var
  Decoder: TLWPTGzipDecoder;
begin
  Decoder := TLWPTGzipDecoder.Create(ASource, ATarget);
  try
    Decoder.Run;
  finally
    Decoder.Free;
  end;
end;

end.
