{ LWPT.Archive — shared archive-contract primitives.

  The installer's extraction preflight and the publication archive layer
  (ADR-0049, "Archive contract" and "Zip normalization") apply the same
  entry-name rules. This unit holds them once:

  - the traversal tests the installer applies to every extracted tar entry
    (an absolute or drive-letter path, or a `..` component), and the
    255-byte file-name component limit;
  - a lexical link-target check that mirrors the installer's
    extraction-root containment for symlinks and hardlinks without touching
    the file system, so a publication scan gives the same answer on every
    platform;
  - strict UTF-8 validation for zip entry names;
  - the stable failure codes and the fixed bounds of the publication
    archive layer, raised as ELWPTArchiveError. }
unit LWPT.Archive;

{$I Shared.inc}

interface

uses
  LWPT.Core;

const
  { Stable failure codes (ADR-0049). The first three are named by the ADR;
    the others classify the remaining local refusals. }
  ARCHIVE_UNSUPPORTED = 'unsupported_archive';
  ARCHIVE_LIMIT_EXCEEDED = 'archive_limit_exceeded';
  ARCHIVE_UNSUPPORTED_DEPENDENCIES = 'unsupported_dependencies';
  ARCHIVE_INVALID = 'invalid_archive';
  ARCHIVE_INVALID_PACKAGE_NAME = 'invalid_package_name';
  ARCHIVE_INVALID_VERSION = 'invalid_version';

  { NAME_MAX on Unix; the per-component limit on Windows. The installer
    measures it in platform units at extraction time; the publication layer
    measures bytes, which is never looser. }
  ARCHIVE_NAME_COMPONENT_LIMIT = 255;

  { ADR-0049 "Bounds". Each is fixed; exceeding one fails with
    archive_limit_exceeded. }
  ARCHIVE_MAXIMUM_INPUT_BYTES = Int64(256) * 1024 * 1024;
  ARCHIVE_MAXIMUM_ZIP_ENTRIES = 10000;
  ARCHIVE_MAXIMUM_EXPANDED_BYTES = Int64(1024) * 1024 * 1024;
  ARCHIVE_MAXIMUM_OUTPUT_BYTES = Int64(256) * 1024 * 1024;
  { Implementation budgets that keep memory near input plus output plus
    fixed buffers (ADR-0049, "Bounds"). lwpt.toml is buffered and parsed,
    so its declared size and its TOML node count are bounded before either
    happens. The normalized zip tree holds every explicit and implied path
    (and an ASCII-folded copy of each), so the total bytes of its distinct
    paths are bounded as it is built. }
  ARCHIVE_MAXIMUM_MANIFEST_BYTES = 256 * 1024;
  ARCHIVE_MAXIMUM_MANIFEST_NODES = 10000;
  ARCHIVE_MAXIMUM_TREE_PATH_BYTES = Int64(16) * 1024 * 1024;
  { The longest path ustar can hold: a 155-byte prefix, '/', and a 100-byte
    name. }
  USTAR_MAXIMUM_PATH_BYTES = 256;

type
  { A local refusal with a stable machine code. Message is
    '<code>: <detail>', the shape ELWPTRegistryError uses. }
  ELWPTArchiveError = class(ELWPTError)
  private
    FCode: string;
  public
    constructor CreateStable(const ACode, ADetail: string);
    constructor CreateStableFmt(const ACode, ADetail: string;
      const AArgs: array of const);
    property Code: string read FCode;
  end;

  { The fixed bounds. Production callers use DefaultArchiveLimits; tests
    lower individual bounds to reach them without gigabyte fixtures. }
  TLWPTArchiveLimits = record
    MaximumInputBytes: Int64;
    MaximumZipEntries: Integer;
    MaximumExpandedBytes: Int64;
    MaximumOutputBytes: Int64;
    MaximumManifestBytes: Int64;
    MaximumManifestNodes: Integer;
    MaximumTreePathBytes: Int64;
  end;

function DefaultArchiveLimits: TLWPTArchiveLimits;

{ True when APath starts with '/' or '\', or with a drive letter and ':'. }
function LooksLikeAbsoluteArchivePath(const APath: string): Boolean;

{ True when any '/'- or '\'-separated component of ARelPath is '..'. }
function ArchiveRelPathHasParentSegment(const ARelPath: string): Boolean;

{ The extraction-root containment test for a link, done lexically. A link
  at ALinkRelPath (relative to the extraction root) whose target ATarget is
  resolved against the link's directory, as the installer resolves both
  symlinks and hardlinks. True when ATarget is absolute or climbs above the
  root. '.' and empty components are ignored, as path expansion does. }
function ArchiveLinkTargetEscapesRoot(const ALinkRelPath,
  ATarget: string): Boolean;

{ The installer's tar header reading, shared so a publication scan reads
  every header exactly as extraction will. StripFirstComponent drops the
  archive's top-level directory ('' for the top-level entry itself); '\'
  reads as '/'. TarOctal parses a NUL- or space-terminated octal field;
  TarStr reads a NUL-terminated text field. }
function StripFirstComponent(const AName: string): string;
function TarOctal(const ABlock: array of Byte; AOffset, ALen: Integer): Int64;
function TarStr(const ABlock: array of Byte; AOffset, ALen: Integer): string;

{ Why a relative archive path could alias another path on a platform file
  system, or '' when it cannot. Applied to every entry of a publication
  archive, following Git's is_hfs_dotgit/is_ntfs_dotgit protections but for
  all names, not only one:
  - HFS+ ignores some code points when comparing names, so 'a<U+200C>b'
    names the file 'ab'. Git's list: U+200C-U+200F, U+202A-U+202E,
    U+206A-U+206F, and U+FEFF.
  - NTFS gives a long name an 8.3 short name that later entries can spell,
    including checksum-based ones ('LW1A2B~1.TOM') once the simple 'NAME~N'
    slots are taken. Any component whose base name (before its first '.')
    has '~' followed by a digit within its first eight characters has that
    shape and is refused. }
function ArchivePathPlatformAlias(const APath: string): string;

{ True when AValue is well-formed UTF-8 (no overlong forms, surrogates, or
  code points above U+10FFFF) and contains no C0, DEL, or C1 control
  character. }
function IsStrictUTF8WithoutControls(const AValue: RawByteString): Boolean;

implementation

uses
  SysUtils;

constructor ELWPTArchiveError.CreateStable(const ACode, ADetail: string);
begin
  inherited Create(ACode + ': ' + ADetail);
  FCode := ACode;
end;

constructor ELWPTArchiveError.CreateStableFmt(const ACode, ADetail: string;
  const AArgs: array of const);
begin
  CreateStable(ACode, Format(ADetail, AArgs));
end;

function DefaultArchiveLimits: TLWPTArchiveLimits;
begin
  Result.MaximumInputBytes := ARCHIVE_MAXIMUM_INPUT_BYTES;
  Result.MaximumZipEntries := ARCHIVE_MAXIMUM_ZIP_ENTRIES;
  Result.MaximumExpandedBytes := ARCHIVE_MAXIMUM_EXPANDED_BYTES;
  Result.MaximumOutputBytes := ARCHIVE_MAXIMUM_OUTPUT_BYTES;
  Result.MaximumManifestBytes := ARCHIVE_MAXIMUM_MANIFEST_BYTES;
  Result.MaximumManifestNodes := ARCHIVE_MAXIMUM_MANIFEST_NODES;
  Result.MaximumTreePathBytes := ARCHIVE_MAXIMUM_TREE_PATH_BYTES;
end;

function LooksLikeAbsoluteArchivePath(const APath: string): Boolean;
begin
  Result := (APath <> '') and ((APath[1] = '/') or (APath[1] = '\'));
  if Result then Exit;
  Result := (Length(APath) >= 2)
        and (APath[1] in ['a'..'z', 'A'..'Z'])
        and (APath[2] = ':');
end;

function ArchiveRelPathHasParentSegment(const ARelPath: string): Boolean;
var
  S, Part: string;
  StartAt, i: Integer;
begin
  Result := False;
  S := StringReplace(ARelPath, '\', '/', [rfReplaceAll]);
  StartAt := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = '/') then
    begin
      Part := System.Copy(S, StartAt, i - StartAt);
      if Part = '..' then Exit(True);
      StartAt := i + 1;
    end;
end;

function ArchiveLinkTargetEscapesRoot(const ALinkRelPath,
  ATarget: string): Boolean;
var
  Target: string;
  Parts: TStringArray;
  Depth, i: Integer;
begin
  Target := StringReplace(ATarget, '\', '/', [rfReplaceAll]);
  if LooksLikeAbsoluteArchivePath(Target) then Exit(True);
  { The link's own directory depth: every non-empty, non-'.' component of
    the link path except its last. }
  Depth := 0;
  Parts := StringReplace(ALinkRelPath, '\', '/', [rfReplaceAll]).Split(['/']);
  for i := 0 to High(Parts) - 1 do
    if Parts[i] = '..' then
      Dec(Depth)
    else if (Parts[i] <> '') and (Parts[i] <> '.') then
      Inc(Depth);
  if Depth < 0 then Exit(True);
  Parts := Target.Split(['/']);
  for i := 0 to High(Parts) do
    if Parts[i] = '..' then
    begin
      Dec(Depth);
      if Depth < 0 then Exit(True);
    end
    else if (Parts[i] <> '') and (Parts[i] <> '.') then
      Inc(Depth);
  { A target that resolves to the root itself names the extraction root,
    which the installer's containment test refuses too. }
  Result := Depth = 0;
end;

function StripFirstComponent(const AName: string): string;
var P: Integer;
begin
  Result := StringReplace(AName, '\', '/', [rfReplaceAll]);
  P := Pos('/', Result);
  if P > 0 then
    Result := System.Copy(Result, P + 1, MaxInt)
  else
    Result := '';   { the top-level dir entry itself — skip }
end;

function TarOctal(const ABlock: array of Byte; AOffset, ALen: Integer): Int64;
var i: Integer; C: Byte;
begin
  Result := 0;
  for i := AOffset to AOffset + ALen - 1 do
  begin
    C := ABlock[i];
    if (C = 0) or (C = Ord(' ')) then
    begin
      if Result = 0 then Continue else Break;
    end;
    if (C >= Ord('0')) and (C <= Ord('7')) then
      Result := (Result shl 3) or Int64(C - Ord('0'));
  end;
end;

function TarStr(const ABlock: array of Byte; AOffset, ALen: Integer): string;
var i: Integer;
begin
  Result := '';
  for i := AOffset to AOffset + ALen - 1 do
  begin
    if ABlock[i] = 0 then Break;
    Result := Result + Chr(ABlock[i]);
  end;
end;

function ArchivePathPlatformAlias(const APath: string): string;
var
  i, Tilde, Dot: Integer;
  Parts: TStringArray;
  Base: string;
  B1, B2, B3: Byte;
begin
  for i := 1 to Length(APath) - 2 do
  begin
    B1 := Byte(APath[i]);
    B2 := Byte(APath[i + 1]);
    B3 := Byte(APath[i + 2]);
    { U+200C-U+200F and U+202A-U+202E: E2 80 8C-8F, E2 80 AA-AE;
      U+206A-U+206F: E2 81 AA-AF; U+FEFF: EF BB BF. }
    if ((B1 = $E2) and (B2 = $80)
         and (((B3 >= $8C) and (B3 <= $8F)) or ((B3 >= $AA) and (B3 <= $AE))))
       or ((B1 = $E2) and (B2 = $81) and (B3 >= $AA) and (B3 <= $AF))
       or ((B1 = $EF) and (B2 = $BB) and (B3 = $BF)) then
      Exit('holds a code point HFS+ ignores in names');
  end;
  Parts := StringReplace(APath, '\', '/', [rfReplaceAll]).Split(['/']);
  for i := 0 to High(Parts) do
  begin
    Dot := Pos('.', Parts[i]);
    if Dot > 0 then
      Base := System.Copy(Parts[i], 1, Dot - 1)
    else
      Base := Parts[i];
    for Tilde := 1 to 8 do
      if (Tilde < Length(Base)) and (Base[Tilde] = '~')
         and (Base[Tilde + 1] in ['0'..'9']) then
        Exit(Format('has the 8.3 short-name component "%s"', [Parts[i]]));
  end;
  Result := '';
end;

function IsStrictUTF8WithoutControls(const AValue: RawByteString): Boolean;
var
  i, Needed, k: Integer;
  B: Byte;
  CodePoint, Minimum: Cardinal;
begin
  i := 1;
  while i <= Length(AValue) do
  begin
    B := Byte(AValue[i]);
    if B < $80 then
    begin
      if (B < $20) or (B = $7F) then Exit(False);
      Inc(i);
      Continue;
    end;
    if (B and $E0) = $C0 then
    begin
      Needed := 1;
      CodePoint := B and $1F;
      Minimum := $80;
    end
    else if (B and $F0) = $E0 then
    begin
      Needed := 2;
      CodePoint := B and $0F;
      Minimum := $800;
    end
    else if (B and $F8) = $F0 then
    begin
      Needed := 3;
      CodePoint := B and $07;
      Minimum := $10000;
    end
    else
      Exit(False);
    if i + Needed > Length(AValue) then Exit(False);
    for k := 1 to Needed do
    begin
      B := Byte(AValue[i + k]);
      if (B and $C0) <> $80 then Exit(False);
      CodePoint := (CodePoint shl 6) or (B and $3F);
    end;
    if (CodePoint < Minimum) or (CodePoint > $10FFFF)
       or ((CodePoint >= $D800) and (CodePoint <= $DFFF))
       or ((CodePoint >= $80) and (CodePoint <= $9F)) then
      Exit(False);
    Inc(i, Needed + 1);
  end;
  Result := True;
end;

end.
