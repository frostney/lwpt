{ LWPT.TarWriter — the canonical, deterministic tar.gz writer (ADR-0049,
  "Canonical tar.gz", normalizer version 1).

  The output is a pure function of the entry paths, their order, their
  bytes, and their execute bits. Callers add entries sorted by the bytes of
  their tar path (a directory path ends with '/'), with every parent
  directory emitted before its children. The writer enforces both.

  Tar layer: POSIX ustar with no GNU or pax extensions. Every header has
  mode 0755 (directories and executable files) or 0644 (other files); uid,
  gid, and mtime 0 as zero-padded octal ('0000000'#0 and '00000000000'#0);
  an empty linkname, uname, gname, and device fields (all NUL); magic
  'ustar'#0 with version '00'; and the standard checksum written as six
  octal digits, NUL, space. A path longer than 100 bytes is split at the
  '/' that leaves the longest prefix of at most 155 bytes and a non-empty
  name of at most 100 bytes. The archive ends with two zero blocks and is
  zero-padded to a multiple of 10,240 bytes.

  Gzip layer: one member with header 1f 8b 08, FLG 0, MTIME 0, XFL 0, OS
  255, then raw deflate from paszlib's zdeflate at level 9, window bits
  -15, memory level 8, and the default strategy, then CRC-32 and ISIZE.
  The tar stream is fed to deflate in fixed 64 KiB chunks with Z_NO_FLUSH
  (the last chunk holds the remainder), followed by one Z_FINISH with no
  further input.

  Changing any byte of this output is a compatibility break: the golden
  fixtures in LWPT.TarWriter.Test and LWPT.ArchiveNormalize.Test pin it,
  and a change needs a new, documented normalizer version.

  The compressed output is bounded: once it would pass the caller's
  maximum, the writer raises archive_limit_exceeded without writing the
  excess. On any exception the target holds an incomplete stream that the
  caller must discard. }
unit LWPT.TarWriter;

{$I Shared.inc}

interface

uses
  Classes,
  Generics.Collections,
  SysUtils,

  LWPT.Archive,
  zbase;

const
  CANONICAL_NORMALIZER_VERSION = 1;
  CANONICAL_TAR_BLOCK_BYTES = 512;
  CANONICAL_TAR_RECORD_BYTES = 10240;
  CANONICAL_GZIP_CHUNK_BYTES = 64 * 1024;
  CANONICAL_DIRECTORY_MODE = &755;
  CANONICAL_EXECUTABLE_MODE = &755;
  CANONICAL_FILE_MODE = &644;
  USTAR_NAME_BYTES = 100;
  USTAR_PREFIX_BYTES = 155;

type
  TLWPTCanonicalTarGzipWriter = class
  private
    FTarget: TStream;
    FMaximumOutputBytes: Int64;
    FOutputBytes: Int64;
    FTarBytes: Int64;
    FTarCrc: Cardinal;
    FDeflate: z_stream;
    FDeflateActive: Boolean;
    FChunk: array[0..CANONICAL_GZIP_CHUNK_BYTES - 1] of Byte;
    FChunkCount: Integer;
    FOutput: array[0..CANONICAL_GZIP_CHUNK_BYTES - 1] of Byte;
    FDirectories: TDictionary<string, Boolean>;
    FLastPath: string;
    FHasLast: Boolean;
    FInFile: Boolean;
    FFileRemaining: Int64;
    FFileSize: Int64;
    FFinished: Boolean;
    procedure Emit(const ABuffer; const ACount: Integer);
    procedure DeflateInput(const AFlush: Integer);
    procedure AppendTar(const ABuffer; const ACount: Integer);
    procedure AppendZeros(const ACount: Int64);
    procedure CheckPath(const ATarPath, AParent: string);
    procedure WriteHeader(const ATarPath: string; const AMode: Integer;
      const ASize: Int64; const ATypeFlag: Char);
  public
    { Writes the gzip header at once. AMaximumOutputBytes bounds the whole
      compressed stream, header and trailer included. }
    constructor Create(const ATarget: TStream;
      const AMaximumOutputBytes: Int64);
    destructor Destroy; override;
    { APath is the directory's path without its trailing '/'. }
    procedure AddDirectory(const APath: string);
    procedure BeginFile(const APath: string; const ASize: Int64;
      const AExecutable: Boolean);
    procedure WriteFileData(const ABuffer; const ACount: Integer);
    procedure EndFile;
    { Writes the end blocks, record padding, deflate end, and trailer. }
    procedure Finish;
    property OutputBytes: Int64 read FOutputBytes;
    property TarBytes: Int64 read FTarBytes;
  end;

{ Splits a tar path into the ustar prefix and name fields. False when the
  path cannot be expressed in ustar. }
function SplitUstarPath(const ATarPath: string;
  out APrefix, AName: string): Boolean;

{ Byte-wise ordering of tar paths, the canonical entry order. }
function CompareTarPaths(const ALeft, ARight: string): Integer;

implementation

uses
  crc,
  zdeflate;

const
  GZIP_HEADER: array[0..9] of Byte = (
    $1F, $8B, $08, $00, $00, $00, $00, $00, $00, $FF);
  DEFLATE_LEVEL = 9;
  DEFLATE_MEMORY_LEVEL = 8;

function SplitUstarPath(const ATarPath: string;
  out APrefix, AName: string): Boolean;
var
  i, Start: Integer;
begin
  APrefix := '';
  AName := '';
  if ATarPath = '' then Exit(False);
  if Length(ATarPath) <= USTAR_NAME_BYTES then
  begin
    AName := ATarPath;
    Exit(True);
  end;
  Start := USTAR_PREFIX_BYTES + 1;
  if Start > Length(ATarPath) then Start := Length(ATarPath);
  for i := Start downto 2 do
    if ATarPath[i] = '/' then
    begin
      if Length(ATarPath) - i > USTAR_NAME_BYTES then Exit(False);
      { A directory's own trailing '/' cannot end the prefix: the name
        field would be empty. }
      if Length(ATarPath) - i = 0 then Continue;
      APrefix := System.Copy(ATarPath, 1, i - 1);
      AName := System.Copy(ATarPath, i + 1, MaxInt);
      Exit(True);
    end;
  Result := False;
end;

function CompareTarPaths(const ALeft, ARight: string): Integer;
var
  Common: Integer;
begin
  Common := Length(ALeft);
  if Length(ARight) < Common then Common := Length(ARight);
  if Common > 0 then
    Result := CompareByte(ALeft[1], ARight[1], Common)
  else
    Result := 0;
  if Result <> 0 then Exit;
  Result := Length(ALeft) - Length(ARight);
end;

procedure RaiseWriter(const ADetail: string);
begin
  raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID,
    'canonical tar writer: ' + ADetail);
end;

procedure WriteOctal(var ABlock: array of Byte; const AOffset,
  ADigits: Integer; const AValue: Int64);
var
  Value: Int64;
  i: Integer;
begin
  Value := AValue;
  for i := ADigits - 1 downto 0 do
  begin
    ABlock[AOffset + i] := Ord('0') + Byte(Value and 7);
    Value := Value shr 3;
  end;
  if Value <> 0 then
    RaiseWriter('value does not fit its octal field');
  ABlock[AOffset + ADigits] := 0;
end;

procedure WriteText(var ABlock: array of Byte; const AOffset,
  ALimit: Integer; const AValue: string);
begin
  if Length(AValue) > ALimit then RaiseWriter('field overflow');
  if AValue <> '' then Move(AValue[1], ABlock[AOffset], Length(AValue));
end;

constructor TLWPTCanonicalTarGzipWriter.Create(const ATarget: TStream;
  const AMaximumOutputBytes: Int64);
var
  Status: Integer;
begin
  inherited Create;
  FTarget := ATarget;
  FMaximumOutputBytes := AMaximumOutputBytes;
  FDirectories := TDictionary<string, Boolean>.Create;
  FTarCrc := crc32(0, nil, 0);
  FDeflate := Default(z_stream);
  Status := deflateInit2(FDeflate, DEFLATE_LEVEL, Z_DEFLATED, -MAX_WBITS,
    DEFLATE_MEMORY_LEVEL, Z_DEFAULT_STRATEGY);
  if Status <> Z_OK then
    RaiseWriter('deflate failed to start: ' + string(zError(Status)));
  FDeflateActive := True;
  Emit(GZIP_HEADER[0], Length(GZIP_HEADER));
end;

destructor TLWPTCanonicalTarGzipWriter.Destroy;
begin
  if FDeflateActive then deflateEnd(FDeflate);
  FDirectories.Free;
  inherited Destroy;
end;

procedure TLWPTCanonicalTarGzipWriter.Emit(const ABuffer;
  const ACount: Integer);
begin
  if ACount <= 0 then Exit;
  if FOutputBytes + ACount > FMaximumOutputBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'canonical tar.gz output passes the %d-byte limit',
      [FMaximumOutputBytes]);
  FTarget.WriteBuffer(ABuffer, ACount);
  Inc(FOutputBytes, ACount);
end;

procedure TLWPTCanonicalTarGzipWriter.DeflateInput(const AFlush: Integer);
var
  Status, Produced: Integer;
begin
  if AFlush = Z_FINISH then
  begin
    FDeflate.next_in := nil;
    FDeflate.avail_in := 0;
  end
  else
  begin
    FDeflate.next_in := @FChunk[0];
    FDeflate.avail_in := FChunkCount;
  end;
  repeat
    FDeflate.next_out := @FOutput[0];
    FDeflate.avail_out := SizeOf(FOutput);
    Status := deflate(FDeflate, AFlush);
    if (Status <> Z_OK) and (Status <> Z_STREAM_END)
       and (Status <> Z_BUF_ERROR) then
      RaiseWriter('deflate failed: ' + string(zError(Status)));
    Produced := SizeOf(FOutput) - Integer(FDeflate.avail_out);
    Emit(FOutput[0], Produced);
    if AFlush = Z_FINISH then
    begin
      if Status = Z_STREAM_END then Break;
    end
    else if (FDeflate.avail_in = 0) and (FDeflate.avail_out <> 0) then
      Break;
  until False;
  FChunkCount := 0;
end;

procedure TLWPTCanonicalTarGzipWriter.AppendTar(const ABuffer;
  const ACount: Integer);
var
  Source: PByte;
  Remaining, Take: Integer;
begin
  if ACount <= 0 then Exit;
  Source := @ABuffer;
  FTarCrc := crc32(FTarCrc, Source, ACount);
  Inc(FTarBytes, ACount);
  Remaining := ACount;
  while Remaining > 0 do
  begin
    Take := SizeOf(FChunk) - FChunkCount;
    if Take > Remaining then Take := Remaining;
    Move(Source^, FChunk[FChunkCount], Take);
    Inc(FChunkCount, Take);
    Inc(Source, Take);
    Dec(Remaining, Take);
    if FChunkCount = SizeOf(FChunk) then DeflateInput(Z_NO_FLUSH);
  end;
end;

procedure TLWPTCanonicalTarGzipWriter.AppendZeros(const ACount: Int64);
var
  Zeros: array[0..CANONICAL_TAR_BLOCK_BYTES - 1] of Byte;
  Remaining: Int64;
  Take: Integer;
begin
  FillChar(Zeros, SizeOf(Zeros), 0);
  Remaining := ACount;
  while Remaining > 0 do
  begin
    Take := SizeOf(Zeros);
    if Take > Remaining then Take := Integer(Remaining);
    AppendTar(Zeros[0], Take);
    Dec(Remaining, Take);
  end;
end;

procedure TLWPTCanonicalTarGzipWriter.CheckPath(const ATarPath,
  AParent: string);
begin
  if FFinished then RaiseWriter('entry added after Finish');
  if FInFile then RaiseWriter('entry added before the previous file ended');
  if FHasLast and (CompareTarPaths(FLastPath, ATarPath) >= 0) then
    RaiseWriter('entries are not in strictly increasing path order: '
      + ATarPath);
  if (AParent <> '') and not FDirectories.ContainsKey(AParent) then
    RaiseWriter('parent directory not emitted before ' + ATarPath);
  FLastPath := ATarPath;
  FHasLast := True;
end;

function ParentOf(const APath: string): string;
var
  i: Integer;
begin
  for i := Length(APath) downto 1 do
    if APath[i] = '/' then Exit(System.Copy(APath, 1, i - 1));
  Result := '';
end;

procedure CheckEntryPath(const APath: string);
var
  i, Start: Integer;
  Part: string;
begin
  if (APath = '') or (APath[1] = '/') or (APath[Length(APath)] = '/') then
    RaiseWriter('invalid entry path: ' + APath);
  Start := 1;
  for i := 1 to Length(APath) + 1 do
    if (i > Length(APath)) or (APath[i] = '/') then
    begin
      Part := System.Copy(APath, Start, i - Start);
      if (Part = '') or (Part = '.') or (Part = '..') then
        RaiseWriter('invalid entry path: ' + APath);
      Start := i + 1;
    end;
end;

procedure TLWPTCanonicalTarGzipWriter.WriteHeader(const ATarPath: string;
  const AMode: Integer; const ASize: Int64; const ATypeFlag: Char);
var
  Block: array[0..CANONICAL_TAR_BLOCK_BYTES - 1] of Byte;
  Prefix, Name: string;
  Sum, i: Integer;
begin
  if not SplitUstarPath(ATarPath, Prefix, Name) then
    raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID,
      'path does not fit ustar''s 155-byte prefix and 100-byte name: '
      + ATarPath);
  FillChar(Block, SizeOf(Block), 0);
  WriteText(Block, 0, 100, Name);
  WriteOctal(Block, 100, 7, AMode);
  WriteOctal(Block, 108, 7, 0);
  WriteOctal(Block, 116, 7, 0);
  WriteOctal(Block, 124, 11, ASize);
  WriteOctal(Block, 136, 11, 0);
  FillChar(Block[148], 8, Ord(' '));
  Block[156] := Ord(ATypeFlag);
  WriteText(Block, 257, 6, 'ustar');
  Block[263] := Ord('0');
  Block[264] := Ord('0');
  WriteText(Block, 345, 155, Prefix);
  Sum := 0;
  for i := 0 to High(Block) do
    Inc(Sum, Block[i]);
  WriteOctal(Block, 148, 6, Sum);
  Block[155] := Ord(' ');
  AppendTar(Block[0], SizeOf(Block));
end;

procedure TLWPTCanonicalTarGzipWriter.AddDirectory(const APath: string);
begin
  CheckEntryPath(APath);
  CheckPath(APath + '/', ParentOf(APath));
  WriteHeader(APath + '/', CANONICAL_DIRECTORY_MODE, 0, '5');
  FDirectories.Add(APath, True);
end;

procedure TLWPTCanonicalTarGzipWriter.BeginFile(const APath: string;
  const ASize: Int64; const AExecutable: Boolean);
var
  Mode: Integer;
begin
  CheckEntryPath(APath);
  if ASize < 0 then RaiseWriter('negative file size');
  CheckPath(APath, ParentOf(APath));
  if AExecutable then
    Mode := CANONICAL_EXECUTABLE_MODE
  else
    Mode := CANONICAL_FILE_MODE;
  WriteHeader(APath, Mode, ASize, '0');
  FInFile := True;
  FFileSize := ASize;
  FFileRemaining := ASize;
end;

procedure TLWPTCanonicalTarGzipWriter.WriteFileData(const ABuffer;
  const ACount: Integer);
begin
  if not FInFile then RaiseWriter('file data outside a file');
  if ACount > FFileRemaining then
    RaiseWriter('file data exceeds its declared size');
  AppendTar(ABuffer, ACount);
  Dec(FFileRemaining, ACount);
end;

procedure TLWPTCanonicalTarGzipWriter.EndFile;
begin
  if not FInFile then RaiseWriter('EndFile outside a file');
  if FFileRemaining <> 0 then
    RaiseWriter('file data is shorter than its declared size');
  AppendZeros((CANONICAL_TAR_BLOCK_BYTES
    - FFileSize mod CANONICAL_TAR_BLOCK_BYTES) mod CANONICAL_TAR_BLOCK_BYTES);
  FInFile := False;
end;

procedure TLWPTCanonicalTarGzipWriter.Finish;
var
  Trailer: array[0..7] of Byte;
  i: Integer;
begin
  if FFinished then RaiseWriter('Finish called twice');
  if FInFile then RaiseWriter('Finish inside a file');
  AppendZeros(2 * CANONICAL_TAR_BLOCK_BYTES);
  AppendZeros((CANONICAL_TAR_RECORD_BYTES
    - FTarBytes mod CANONICAL_TAR_RECORD_BYTES) mod CANONICAL_TAR_RECORD_BYTES);
  if FChunkCount > 0 then DeflateInput(Z_NO_FLUSH);
  DeflateInput(Z_FINISH);
  deflateEnd(FDeflate);
  FDeflateActive := False;
  for i := 0 to 3 do
    Trailer[i] := Byte((FTarCrc shr (8 * i)) and $FF);
  for i := 0 to 3 do
    Trailer[4 + i] := Byte((FTarBytes shr (8 * i)) and $FF);
  Emit(Trailer[0], SizeOf(Trailer));
  FFinished := True;
end;

end.
