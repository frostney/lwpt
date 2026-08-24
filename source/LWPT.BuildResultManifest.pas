{ LWPT.BuildResultManifest — the canonical persisted shape shared by build
  cache publication, materialization, eviction, and repair. }
unit LWPT.BuildResultManifest;

{$I Shared.inc}
{$J-}

interface

uses
  Classes;

const
  BUILD_CACHE_RESULT_SCHEMA_VERSION = 1;
  BUILD_RESULT_MANIFEST_MAX_BYTES = 64 * 1024;

type
  TLWPTCachedBuildResult = record
    SchemaVersion: Integer;
    Fingerprint: string;
    ArtifactDigest: string;
    ArtifactKind: string;
    UnixMode: Integer;
  end;

function CanonicalBuildCacheDigest(const ADigest: string): string;
function ParseBuildResultManifest(const AText: string;
  out AResult: TLWPTCachedBuildResult): Boolean;
function ReadBuildResultManifest(const APath: string;
  out AResult: TLWPTCachedBuildResult): Boolean;
function ReadVerifiedBuildResultManifest(const APath, AExpectedDigest: string;
  out AResult: TLWPTCachedBuildResult): Boolean;
function SerializeBuildResultManifest(
  const AResult: TLWPTCachedBuildResult): TStringList;

implementation

uses
  SysUtils,

  LWPT.Core,
  TOML;

function CanonicalBuildCacheDigest(const ADigest: string): string;
var
  Hex: string;
  Index: Integer;
begin
  Result := '';
  if not SameText(Copy(ADigest, 1, 7), 'sha256:') then Exit;
  Hex := LowerCase(Copy(ADigest, 8, MaxInt));
  if Length(Hex) <> 64 then Exit;
  for Index := 1 to Length(Hex) do
    if not (Hex[Index] in ['0'..'9', 'a'..'f']) then Exit;
  Result := 'sha256:' + Hex;
end;

function ParseBuildResultManifest(const AText: string;
  out AResult: TLWPTCachedBuildResult): Boolean;
var
  Parser: TTOMLParser;
  Root: TTOMLNode;
begin
  Result := False;
  AResult := Default(TLWPTCachedBuildResult);
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    try
      Root := Parser.ParseDocument(AText);
    except
      on ETOMLParseError do Exit;
    end;
  finally
    Parser.Free;
  end;
  try
    AResult.SchemaVersion := TomlInt(Root, 'schema', 0);
    AResult.Fingerprint := CanonicalBuildCacheDigest(
      TomlStr(Root, 'fingerprint', ''));
    AResult.ArtifactDigest := CanonicalBuildCacheDigest(
      TomlStr(Root, 'artifact_digest', ''));
    AResult.ArtifactKind := TomlStr(Root, 'artifact_kind', '');
    AResult.UnixMode := TomlInt(Root, 'unix_mode', -1);
    Result := (AResult.SchemaVersion = BUILD_CACHE_RESULT_SCHEMA_VERSION)
      and (AResult.Fingerprint <> '')
      and (AResult.ArtifactDigest <> '')
      and (AResult.ArtifactKind <> '')
      and (AResult.UnixMode >= 0) and (AResult.UnixMode <= $1FF);
  finally
    Root.Free;
  end;
end;

function ReadBuildResultManifestText(const APath: string;
  out AText, ADigest: string): Boolean;
var
  Bytes: TBytes;
  Stream: TFileStream;
begin
  Result := False;
  AText := '';
  ADigest := '';
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size > BUILD_RESULT_MANIFEST_MAX_BYTES then Exit;
      SetLength(Bytes, Stream.Size);
      if Stream.Size > 0 then Stream.ReadBuffer(Bytes[0], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    on E: EFOpenError do Exit;
    on E: EInOutError do Exit;
    on E: EReadError do Exit;
  end;
  SetLength(AText, Length(Bytes));
  if Length(Bytes) > 0 then Move(Bytes[0], AText[1], Length(Bytes));
  ADigest := SHA256BytesPrefixed(Bytes);
  Result := True;
end;

function ReadBuildResultManifest(const APath: string;
  out AResult: TLWPTCachedBuildResult): Boolean;
var
  Digest, Text: string;
begin
  AResult := Default(TLWPTCachedBuildResult);
  Result := ReadBuildResultManifestText(APath, Text, Digest)
    and ParseBuildResultManifest(Text, AResult);
end;

function ReadVerifiedBuildResultManifest(const APath,
  AExpectedDigest: string; out AResult: TLWPTCachedBuildResult): Boolean;
var
  ActualDigest, Text: string;
begin
  AResult := Default(TLWPTCachedBuildResult);
  Result := ReadBuildResultManifestText(APath, Text, ActualDigest)
    and (ActualDigest = CanonicalBuildCacheDigest(AExpectedDigest))
    and ParseBuildResultManifest(Text, AResult);
end;

function SerializeBuildResultManifest(
  const AResult: TLWPTCachedBuildResult): TStringList;
begin
  Result := TStringList.Create;
  Result.LineBreak := #10;
  Result.Add('schema = ' + IntToStr(AResult.SchemaVersion));
  Result.Add('fingerprint = "' + AResult.Fingerprint + '"');
  Result.Add('artifact_digest = "' + AResult.ArtifactDigest + '"');
  Result.Add('artifact_kind = "' + TomlEscape(AResult.ArtifactKind) + '"');
  Result.Add('unix_mode = ' + IntToStr(AResult.UnixMode));
end;

end.
