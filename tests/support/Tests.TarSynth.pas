{ Tests.TarSynth — minimal POSIX ustar tarball synthesiser for the
  extractor's pathological-input regression tests.

  Exists because the system `tar` binary's behaviour for long paths
  varies across BSD tar (macOS) and GNU tar (Linux) and across format
  flags (--format=ustar vs gnu vs pax). To deterministically exercise
  the specific bytes LWPT's custom ustar reader handles — the >100-byte
  prefix-split path and the symlink type — the test needs to control
  the wire format exactly.

  Scope is intentionally small: just the entry types lwpt's extractor
  is asserted against. Not a complete tar implementation:
    - No PaxHeader / pax extended headers (LWPT doesn't read them)
    - GNU 'L' long-name entries are supported; 'K' long-linkname
      is not synthesised but the extractor handles both via the same
      pending-long-name buffer.
    - No sparse files
    - No device entries

  Each builder returns a TBytes of the raw archive (after end-of-archive
  zero blocks). Gzip wrapping is the caller's job via Gzip(). }

unit Tests.TarSynth;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,

  zstream;

type
  TByteArrays = array of TBytes;

{ Build a tar entry for a regular file. If LongName has > 100 chars AND
  can be split as prefix(155)+'/'+name(100), the ustar prefix field is
  used (the path is split at the last '/' that leaves both halves
  within their limits). Raises on names that can't be expressed in
  ustar (> 255 chars total, or no valid split point). }
function MakeRegularFileEntry(const APath: string;
  const AData: TBytes): TBytes;

{ Build a tar entry for a symlink. LinkName must fit in 100 chars
  (LWPT doesn't synthesise GNU 'K' long-linkname entries). }
function MakeSymlinkEntry(const APath, ALinkName: string): TBytes;

{ Build a directory entry (typeflag '5'). Useful as a parent entry
  for files inside it, though LWPT's extractor creates intermediate
  directories on demand and tolerates missing dir entries. }
function MakeDirectoryEntry(const APath: string): TBytes;

{ Build a GNU 'L' long-name entry for a regular file. The on-the-wire
  shape is two consecutive entries:

    1. A header with typeflag 'L', name '././@LongLink' (convention,
       not strictly required), size = Length(ALongPath)+1, followed by
       the long path as the body (NUL-terminated, padded to 512).
    2. A regular file header whose name field holds a TRUNCATED stub
       (since the real name can't fit in 100 bytes), typeflag '0',
       size = Length(AData). The extractor uses the pending long
       name from step 1 instead of this header's name.

  This is the format GNU tar emits for paths > 100 bytes when the
  ustar prefix-split doesn't work (e.g. no slash in the right place,
  or path > 255 bytes). The extractor's pending-long-name buffer
  carries the name across header boundaries. }
function MakeGnuLongNameRegularFileEntry(const ALongPath: string;
  const AData: TBytes): TBytes;

{ The same GNU 'L' shape for a directory entry (typeflag '5'). }
function MakeGnuLongNameDirectoryEntry(const ALongPath: string): TBytes;

{ Concatenate any number of entries, append the two end-of-archive
  zero blocks, return the complete raw tar. }
function BuildTar(const AEntries: TByteArrays): TBytes;

{ Wrap raw bytes in a gzip stream. Returns the .tar.gz bytes. }
function Gzip(const APlain: TBytes): TBytes;

{ Write a TBytes to a file at APath. Convenience for tests that
  immediately hand the archive path to ExtractArchive. }
procedure WriteBytesToFile(const APath: string; const ABytes: TBytes);

implementation

const
  TAR_BLOCK = 512;

{ ── byte-level helpers ────────────────────────────────────────────── }

procedure FillSpaces(var ABuf: array of Byte;
  const AOffset, ALen: Integer); inline;
var i: Integer;
begin
  for i := AOffset to AOffset + ALen - 1 do
    ABuf[i] := $20;
end;

procedure WriteStringField(var ABuf: array of Byte;
  const AOffset, ACap: Integer; const AValue: string);
var i, n: Integer;
begin
  n := Length(AValue);
  if n > ACap then n := ACap;
  for i := 1 to n do
    ABuf[AOffset + i - 1] := Byte(Ord(AValue[i]));
end;

procedure WriteOctalField(var ABuf: array of Byte;
  const AOffset, ACap: Integer; const AValue: Int64);
var
  S: string;
  V: Int64;
  i, Pad: Integer;
begin
  V := AValue;
  if V = 0 then
    S := '0'
  else
  begin
    S := '';
    while V > 0 do
    begin
      S := Char(Ord('0') + (V and $7)) + S;
      V := V shr 3;
    end;
  end;

  { ustar's octal fields are <ACap-1> octal digits + a trailing NUL;
    zero-pad on the left. }
  Pad := ACap - 1 - Length(S);
  if Pad < 0 then
    raise Exception.CreateFmt('octal value %d does not fit in %d chars',
      [AValue, ACap]);
  for i := 0 to Pad - 1 do
    ABuf[AOffset + i] := Byte(Ord('0'));
  for i := 1 to Length(S) do
    ABuf[AOffset + Pad + i - 1] := Byte(Ord(S[i]));
  ABuf[AOffset + ACap - 1] := 0;
end;

procedure StampHeader(var ABuf: array of Byte;
  const AName, APrefix, ALinkName: string;
  const AMode: Integer; const ASize: Int64; const ATypeFlag: Char);
var i: Integer; Sum: Integer;
begin
  for i := 0 to TAR_BLOCK - 1 do ABuf[i] := 0;

  WriteStringField(ABuf, 0,   100, AName);
  WriteOctalField (ABuf, 100, 8,   AMode);
  WriteOctalField (ABuf, 108, 8,   0);              { uid }
  WriteOctalField (ABuf, 116, 8,   0);              { gid }
  WriteOctalField (ABuf, 124, 12,  ASize);
  WriteOctalField (ABuf, 136, 12,  0);              { mtime: epoch 0 for
                                                      reproducibility }

  { Checksum: per POSIX, computed as if the checksum field were eight
    spaces. We fill the field with spaces, compute the sum of all 512
    bytes, then write the result back as six octal digits + NUL + space. }
  FillSpaces(ABuf, 148, 8);

  ABuf[156] := Byte(Ord(ATypeFlag));
  WriteStringField(ABuf, 157, 100, ALinkName);

  { ustar magic + version }
  WriteStringField(ABuf, 257, 5, 'ustar');
  ABuf[262] := 0;
  ABuf[263] := Byte(Ord('0'));
  ABuf[264] := Byte(Ord('0'));

  WriteStringField(ABuf, 345, 155, APrefix);

  Sum := 0;
  for i := 0 to TAR_BLOCK - 1 do
    Sum := Sum + Integer(ABuf[i]);
  WriteOctalField(ABuf, 148, 7, Sum);
  ABuf[148 + 6] := 0;
  ABuf[148 + 7] := $20;
end;

function ConcatBytes(const AParts: array of TBytes): TBytes;
var i, j, n, off: Integer;
begin
  n := 0;
  for i := 0 to High(AParts) do Inc(n, Length(AParts[i]));
  SetLength(Result, n);
  off := 0;
  for i := 0 to High(AParts) do
  begin
    for j := 0 to High(AParts[i]) do
      Result[off + j] := AParts[i][j];
    Inc(off, Length(AParts[i]));
  end;
end;

{ Pad the body to a 512-byte boundary so the next entry's header is
  block-aligned. Returns body + zero padding. }
function PadToBlock(const ABody: TBytes): TBytes;
var
  Pad: Integer;
  i: Integer;
begin
  if Length(ABody) = 0 then Exit(nil);
  Pad := (TAR_BLOCK - (Length(ABody) mod TAR_BLOCK)) mod TAR_BLOCK;
  SetLength(Result, Length(ABody) + Pad);
  for i := 0 to High(ABody) do Result[i] := ABody[i];
  for i := Length(ABody) to High(Result) do Result[i] := 0;
end;

{ Split a long path into (prefix, name) such that:
   - Length(name) <= 100, Length(prefix) <= 155
   - prefix + '/' + name == APath (i.e. split at a slash)
   - prefer the split that keeps prefix as long as possible
  Returns False if no valid split exists. }
function SplitForPrefix(const APath: string;
  out APrefix, AName: string): Boolean;
var
  Slash: Integer;
begin
  if Length(APath) <= 100 then
  begin
    APrefix := '';
    AName := APath;
    Exit(True);
  end;

  { Search for the rightmost slash that gives Length(name) <= 100. }
  Slash := Length(APath) - 100;
  while (Slash <= Length(APath)) and (Slash > 0) do
  begin
    if APath[Slash] = '/' then
    begin
      APrefix := Copy(APath, 1, Slash - 1);
      AName   := Copy(APath, Slash + 1, MaxInt);
      Exit((Length(APrefix) <= 155) and (Length(AName) <= 100));
    end;
    Inc(Slash);
  end;
  Result := False;
end;

{ ── public builders ───────────────────────────────────────────────── }

function MakeRegularFileEntry(const APath: string;
  const AData: TBytes): TBytes;
var
  Hdr: array[0..TAR_BLOCK - 1] of Byte;
  HdrBytes: TBytes;
  Prefix, Name: string;
  i: Integer;
begin
  if not SplitForPrefix(APath, Prefix, Name) then
    raise Exception.CreateFmt(
      'path %s cannot be expressed in ustar (>255 chars or no '
      + 'splittable slash)', [APath]);

  StampHeader(Hdr, Name, Prefix, '', $1A4, Length(AData), '0');

  SetLength(HdrBytes, TAR_BLOCK);
  for i := 0 to TAR_BLOCK - 1 do HdrBytes[i] := Hdr[i];

  Result := ConcatBytes([HdrBytes, PadToBlock(AData)]);
end;

function MakeSymlinkEntry(const APath, ALinkName: string): TBytes;
var
  Hdr: array[0..TAR_BLOCK - 1] of Byte;
  HdrBytes: TBytes;
  Prefix, Name: string;
  i: Integer;
begin
  if Length(ALinkName) > 100 then
    raise Exception.CreateFmt(
      'symlink target %s exceeds 100 chars (GNU K long-linkname)',
      [ALinkName]);
  if not SplitForPrefix(APath, Prefix, Name) then
    raise Exception.CreateFmt(
      'symlink path %s cannot be expressed in ustar', [APath]);

  StampHeader(Hdr, Name, Prefix, ALinkName, $1A4, 0, '2');

  SetLength(HdrBytes, TAR_BLOCK);
  for i := 0 to TAR_BLOCK - 1 do HdrBytes[i] := Hdr[i];

  Result := HdrBytes;
end;

function MakeDirectoryEntry(const APath: string): TBytes;
var
  Hdr: array[0..TAR_BLOCK - 1] of Byte;
  HdrBytes: TBytes;
  Prefix, Name: string;
  i: Integer;
begin
  if not SplitForPrefix(APath, Prefix, Name) then
    raise Exception.CreateFmt(
      'directory path %s cannot be expressed in ustar', [APath]);

  StampHeader(Hdr, Name, Prefix, '', $1ED, 0, '5');

  SetLength(HdrBytes, TAR_BLOCK);
  for i := 0 to TAR_BLOCK - 1 do HdrBytes[i] := Hdr[i];

  Result := HdrBytes;
end;

function MakeGnuLongNameEntry(const ALongPath: string;
  const AData: TBytes; const AMode: Integer; const ATypeFlag: Char): TBytes;
var
  LongHdr, FileHdr: array[0..TAR_BLOCK - 1] of Byte;
  LongHdrBytes, FileHdrBytes, NamePayload: TBytes;
  StubName: string;
  i, NameLen: Integer;
begin
  { Step 1: the 'L' entry. Name field is the GNU convention
    '././@LongLink' (LWPT's extractor ignores it; the typeflag is
    what triggers the long-name machinery). Size is the long name's
    length INCLUDING the NUL terminator that GNU tar appends. }
  NameLen := Length(ALongPath) + 1;
  StampHeader(LongHdr, '././@LongLink', '', '', $1A4, NameLen, 'L');
  SetLength(LongHdrBytes, TAR_BLOCK);
  for i := 0 to TAR_BLOCK - 1 do LongHdrBytes[i] := LongHdr[i];

  { Body: the long name + a single NUL terminator. PadToBlock zero-
    pads to the next 512 boundary. }
  SetLength(NamePayload, NameLen);
  for i := 1 to Length(ALongPath) do
    NamePayload[i - 1] := Byte(Ord(ALongPath[i]));
  NamePayload[NameLen - 1] := 0;

  { Step 2: the real entry's header. Name field holds a stub (the
    extractor overrides with the pending long name). Some tar
    implementations encode the FIRST 100 chars of the long name
    here; others use a placeholder. We use the first 100 chars when
    the path is long, or the full path otherwise — either form
    satisfies a strict tar reader that fell back to the truncated
    name, and LWPT's pending-long-name buffer always overrides. }
  if Length(ALongPath) > 100 then
    StubName := Copy(ALongPath, 1, 100)
  else
    StubName := ALongPath;
  StampHeader(FileHdr, StubName, '', '', AMode, Length(AData), ATypeFlag);
  SetLength(FileHdrBytes, TAR_BLOCK);
  for i := 0 to TAR_BLOCK - 1 do FileHdrBytes[i] := FileHdr[i];

  Result := ConcatBytes([
    LongHdrBytes,
    PadToBlock(NamePayload),
    FileHdrBytes,
    PadToBlock(AData)
  ]);
end;

function MakeGnuLongNameRegularFileEntry(const ALongPath: string;
  const AData: TBytes): TBytes;
begin
  Result := MakeGnuLongNameEntry(ALongPath, AData, $1A4, '0');
end;

function MakeGnuLongNameDirectoryEntry(const ALongPath: string): TBytes;
begin
  Result := MakeGnuLongNameEntry(ALongPath, nil, $1ED, '5');
end;

function BuildTar(const AEntries: TByteArrays): TBytes;
var
  EOA: TBytes;
  i: Integer;
  Combined: array of TBytes;
begin
  SetLength(EOA, TAR_BLOCK * 2);
  for i := 0 to High(EOA) do EOA[i] := 0;

  SetLength(Combined, Length(AEntries) + 1);
  for i := 0 to High(AEntries) do Combined[i] := AEntries[i];
  Combined[High(Combined)] := EOA;

  Result := ConcatBytes(Combined);
end;

var
  TempFileCounter: LongInt = 0;

function Gzip(const APlain: TBytes): TBytes;
var
  Compressor: TGZFileStream;
  TempPath: string;
  Reader: TFileStream;
begin
  { TGZFileStream wraps a file; the simplest path is to write to a temp
    file and slurp it back. This is a test-only helper; the cost is
    one extra disk round-trip per fixture. }
  { GetTempFileName returns the first unused name without creating it, so
    test programs running in parallel could pick the same path. Make the
    name unique per process and per call instead. }
  TempPath := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'lwpt-tarsynth-'
    + IntToStr(GetProcessID) + '-'
    + IntToStr(InterLockedIncrement(TempFileCounter)) + '.gz';
  try
    Compressor := TGZFileStream.Create(TempPath, gzopenwrite);
    try
      if Length(APlain) > 0 then
        Compressor.WriteBuffer(APlain[0], Length(APlain));
    finally
      Compressor.Free;
    end;

    Reader := TFileStream.Create(TempPath,
                fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, Reader.Size);
      if Reader.Size > 0 then Reader.ReadBuffer(Result[0], Reader.Size);
    finally
      Reader.Free;
    end;
  finally
    DeleteFile(TempPath);
  end;
end;

procedure WriteBytesToFile(const APath: string; const ABytes: TBytes);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
end;

end.
