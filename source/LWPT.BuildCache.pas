{ LWPT.BuildCache — build-fingerprint result manifests over the shared
  immutable object-store seam. }
unit LWPT.BuildCache;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.ObjectStore,
  LWPT.ProducerLease;

const
  BUILD_CACHE_RESULT_SCHEMA_VERSION = 1;
  BUILD_RESULT_NAMESPACE = 'build-results';

type
  ELWPTBuildCacheError = class(ELWPTError);

  TLWPTCachedBuildResult = record
    SchemaVersion: Integer;
    Fingerprint: string;
    ArtifactDigest: string;
    ArtifactKind: string;
    UnixMode: Integer;
  end;

  TLWPTBuildCache = class
  private
    FRoot: string;
    FCacheLifecycle: TLWPTCacheLifecycle;
    FObjects: TLWPTImmutableObjectStore;
    FProducerLeases: TLWPTProducerLeaseCoordinator;
    function ReferencePath(const AFingerprint: string): string;
    function ParseResultManifest(const AText: string;
      out AResult: TLWPTCachedBuildResult): Boolean;
    function ReadSmallTextFile(const APath: string;
      out AText: string): Boolean;
    function SerializeResultManifest(
      const AResult: TLWPTCachedBuildResult): TStringList;
  public
    constructor CreateDefault;
    constructor Create(const ACacheRoot: string);
    destructor Destroy; override;
    function Materialize(const AFingerprint, ADestination,
      ASessionTemporaryRoot: string; out AResult: TLWPTCachedBuildResult;
      out AReason: string): Boolean;
    function ProducerSnapshot(const AFingerprint: string;
      out ASnapshot: TLWPTProducerLeaseSnapshot): Boolean;
    function Store(const AFingerprint, AArtifactPath,
      AArtifactKind: string; const AUnixMode: Integer = -1): Boolean;
    function TryAcquireProducer(const AFingerprint,
      ADescription: string): TLWPTProducerLease;
    property Root: string read FRoot;
  end;

function BuildResultCacheRoot(const ACacheRoot: string): string;
function BuildArtifactUnixMode(const APath: string): Integer;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  TOML;

const
  RESULT_MANIFEST_MAX_BYTES = 64 * 1024;

function BuildResultCacheRoot(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + BUILD_RESULT_NAMESPACE;
end;

function CanonicalDigest(const ADigest: string): string;
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

function BuildArtifactUnixMode(const APath: string): Integer;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  if FpStat(APath, Info) <> 0 then Exit(0);
  Result := Info.st_mode and $1FF;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

function ApplyUnixMode(const APath: string; const AMode: Integer): Boolean;
begin
  {$IFDEF UNIX}
  Exit(FpChmod(APath, AMode) = 0);
  {$ENDIF}
  Result := True;
end;

constructor TLWPTBuildCache.Create(const ACacheRoot: string);
begin
  inherited Create;
  FRoot := BuildResultCacheRoot(ACacheRoot);
  FCacheLifecycle := TLWPTCacheLifecycle.Create(ACacheRoot,
    BUILD_RESULT_NAMESPACE);
  FObjects := TLWPTImmutableObjectStore.Create(
    IncludeTrailingPathDelimiter(FRoot) + 'objects', ACacheRoot,
    BUILD_RESULT_NAMESPACE);
  FProducerLeases := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(ACacheRoot));
end;

constructor TLWPTBuildCache.CreateDefault;
begin
  Create(ResolveCacheRoot);
end;

destructor TLWPTBuildCache.Destroy;
begin
  FProducerLeases.Free;
  FObjects.Free;
  FCacheLifecycle.Free;
  inherited Destroy;
end;

function TLWPTBuildCache.TryAcquireProducer(const AFingerprint,
  ADescription: string): TLWPTProducerLease;
begin
  { ReferencePath performs the public fingerprint validation before the
    caller can create shared coordination state. }
  ReferencePath(AFingerprint);
  Result := FProducerLeases.TryAcquire('build:'
    + CanonicalDigest(AFingerprint), ADescription);
end;

function TLWPTBuildCache.ProducerSnapshot(const AFingerprint: string;
  out ASnapshot: TLWPTProducerLeaseSnapshot): Boolean;
begin
  ReferencePath(AFingerprint);
  Result := FProducerLeases.Snapshot('build:'
    + CanonicalDigest(AFingerprint), ASnapshot);
end;

function TLWPTBuildCache.ReferencePath(
  const AFingerprint: string): string;
var
  Digest, Hex: string;
begin
  Digest := CanonicalDigest(AFingerprint);
  if Digest = '' then
    raise ELWPTBuildCacheError.CreateFmt(
      'build fingerprint must use sha256:<64 lowercase hex> (got "%s")',
      [AFingerprint]);
  Hex := Copy(Digest, 8, MaxInt);
  Result := IncludeTrailingPathDelimiter(FRoot) + 'refs/sha256/'
    + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
end;

function TLWPTBuildCache.ReadSmallTextFile(const APath: string;
  out AText: string): Boolean;
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  Result := False;
  AText := '';
  if not FileExists(APath) then Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > RESULT_MANIFEST_MAX_BYTES then Exit;
    SetLength(Bytes, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Bytes[0], Stream.Size);
  finally
    Stream.Free;
  end;
  SetLength(AText, Length(Bytes));
  if Length(Bytes) > 0 then Move(Bytes[0], AText[1], Length(Bytes));
  Result := True;
end;

function TLWPTBuildCache.SerializeResultManifest(
  const AResult: TLWPTCachedBuildResult): TStringList;
begin
  Result := TStringList.Create;
  Result.LineBreak := #10;
  Result.Add('schema = ' + IntToStr(AResult.SchemaVersion));
  Result.Add('fingerprint = "' + AResult.Fingerprint + '"');
  Result.Add('artifact_digest = "' + AResult.ArtifactDigest + '"');
  Result.Add('artifact_kind = "' + AResult.ArtifactKind + '"');
  Result.Add('unix_mode = ' + IntToStr(AResult.UnixMode));
end;

function TLWPTBuildCache.ParseResultManifest(const AText: string;
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
    AResult.Fingerprint := CanonicalDigest(
      TomlStr(Root, 'fingerprint', ''));
    AResult.ArtifactDigest := CanonicalDigest(
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

function TLWPTBuildCache.Materialize(const AFingerprint, ADestination,
  ASessionTemporaryRoot: string; out AResult: TLWPTCachedBuildResult;
  out AReason: string): Boolean;
var
  ManifestDigest, ManifestPath, ManifestText, ReferenceText: string;
begin
  Result := False;
  AResult := Default(TLWPTCachedBuildResult);
  AReason := 'no-result';
  if not ReadSmallTextFile(ReferencePath(AFingerprint), ReferenceText) then
    Exit;
  ManifestDigest := CanonicalDigest(Trim(ReferenceText));
  if ManifestDigest = '' then
  begin
    AReason := 'invalid-reference';
    Exit;
  end;
  ForceDirectories(ASessionTemporaryRoot);
  ManifestPath := MakeTmpPath(ASessionTemporaryRoot, 'result-manifest');
  if not FObjects.Materialize(ManifestDigest, ManifestPath,
       ASessionTemporaryRoot) then
  begin
    AReason := 'result-manifest-missing';
    Exit;
  end;
  try
    if not ReadSmallTextFile(ManifestPath, ManifestText)
       or not ParseResultManifest(ManifestText, AResult)
       or (AResult.Fingerprint <> CanonicalDigest(AFingerprint)) then
    begin
      AReason := 'result-manifest-invalid';
      Exit;
    end;
  finally
    SysUtils.DeleteFile(ManifestPath);
  end;
  if not FObjects.Materialize(AResult.ArtifactDigest, ADestination,
    ASessionTemporaryRoot) then
  begin
    AReason := 'artifact-missing';
    Exit;
  end;
  if not ApplyUnixMode(ADestination, AResult.UnixMode) then
  begin
    SysUtils.DeleteFile(ADestination);
    AReason := 'artifact-mode-failed';
    Exit;
  end;
  AReason := 'hit';
  Result := True;
end;

function TLWPTBuildCache.Store(const AFingerprint, AArtifactPath,
  AArtifactKind: string; const AUnixMode: Integer): Boolean;
var
  ArtifactDigest, ManifestDigest, ManifestPath, ManifestTmpRoot: string;
  ArtifactLease, ManifestLease, MutationLease: TObject;
  ArtifactInserted, ManifestInserted, Published: Boolean;
  CacheResult: TLWPTCachedBuildResult;
  Lines: TStringList;
  ReferenceAdditional, ReferenceBytes, ReferenceSize: Int64;
  Search: TSearchRec;
begin
  Result := False;
  ArtifactLease := nil;
  ManifestLease := nil;
  MutationLease := nil;
  ArtifactInserted := False;
  ManifestInserted := False;
  Published := False;
  try
    if not FileExists(AArtifactPath) then
      raise ELWPTBuildCacheError.CreateFmt(
        'cache artifact does not exist: %s', [AArtifactPath]);
    CacheResult := Default(TLWPTCachedBuildResult);
    CacheResult.SchemaVersion := BUILD_CACHE_RESULT_SCHEMA_VERSION;
    CacheResult.Fingerprint := CanonicalDigest(AFingerprint);
    if CacheResult.Fingerprint = '' then
      raise ELWPTBuildCacheError.CreateFmt(
        'invalid build fingerprint "%s"', [AFingerprint]);
    CacheResult.ArtifactKind := AArtifactKind;
    if AUnixMode >= 0 then CacheResult.UnixMode := AUnixMode
    else CacheResult.UnixMode := BuildArtifactUnixMode(AArtifactPath);
    ArtifactDigest := 'sha256:' + SHA256File(AArtifactPath);
    CacheResult.ArtifactDigest := ArtifactDigest;
    if FObjects.AdmitRetained(AArtifactPath, ArtifactDigest,
         ArtifactLease, ArtifactInserted) = '' then Exit;

    { Compose the manifest beside the invocation-private artifact. Shared
      build-cache tmp is repair-owned and is used only while mutation-guarded. }
    ManifestTmpRoot := ExtractFileDir(AArtifactPath);
    ForceDirectories(ManifestTmpRoot);
    ManifestPath := MakeTmpPath(ManifestTmpRoot, 'build-result');
    Lines := SerializeResultManifest(CacheResult);
    try
      AtomicWriteText(ManifestPath, ManifestTmpRoot, Lines);
    finally
      Lines.Free;
    end;
    try
      ManifestDigest := 'sha256:' + SHA256File(ManifestPath);
      if FObjects.AdmitRetained(ManifestPath, ManifestDigest,
           ManifestLease, ManifestInserted) = '' then Exit;
    finally
      SysUtils.DeleteFile(ManifestPath);
    end;

    MutationLease := FCacheLifecycle.AcquireMutation;
    try
      Lines := TStringList.Create;
      try
        Lines.LineBreak := #10;
        Lines.Add(ManifestDigest);
        ReferenceBytes := Length(RawByteString(Lines.Text));
        ReferenceSize := 0;
        if FindFirst(ReferencePath(AFingerprint), faAnyFile, Search) = 0 then
        try
          ReferenceSize := Search.Size;
        finally
          SysUtils.FindClose(Search);
        end;
        ReferenceAdditional := ReferenceBytes - ReferenceSize;
        if ReferenceAdditional < 0 then ReferenceAdditional := 0;
        if not FCacheLifecycle.MakeRoomLocked(ReferenceAdditional) then Exit;
        ForceDirectories(ExtractFileDir(ReferencePath(AFingerprint)));
        AtomicWriteText(ReferencePath(AFingerprint), ManifestTmpRoot, Lines);
        Published := True;
        Result := True;
      finally
        Lines.Free;
      end;
    finally
      MutationLease.Free;
      MutationLease := nil;
    end;
  finally
    MutationLease.Free;
    try
      if not Published then
      begin
        if ManifestInserted then FObjects.DiscardRetained(ManifestDigest);
        if ArtifactInserted then FObjects.DiscardRetained(ArtifactDigest);
      end;
    finally
      ManifestLease.Free;
      ArtifactLease.Free;
    end;
  end;
end;

end.
