{ LWPT.BuildCache — build-fingerprint result manifests over the shared
  immutable object-store seam. }
unit LWPT.BuildCache;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.BuildResultManifest,
  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.ObjectStore,
  LWPT.ProducerLease;

const
  BUILD_RESULT_NAMESPACE = 'build-results';

type
  ELWPTBuildCacheError = class(ELWPTError);
  TLWPTCachedBuildResult =
    LWPT.BuildResultManifest.TLWPTCachedBuildResult;

  TLWPTBuildCache = class
  private
    FRoot: string;
    FCacheLifecycle: TLWPTCacheLifecycle;
    FObjects: TLWPTImmutableObjectStore;
    FProducerLeases: TLWPTProducerLeaseCoordinator;
    function ReferencePath(const AFingerprint: string): string;
    function InvalidateReferenceIfCurrent(const AFingerprint,
      AManifestDigest: string): Boolean;
    function ReadSmallTextFile(const APath: string;
      out AText: string): Boolean;
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

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

function BuildResultCacheRoot(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + BUILD_RESULT_NAMESPACE;
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
    + CanonicalBuildCacheDigest(AFingerprint), ADescription);
end;

function TLWPTBuildCache.ProducerSnapshot(const AFingerprint: string;
  out ASnapshot: TLWPTProducerLeaseSnapshot): Boolean;
begin
  ReferencePath(AFingerprint);
  Result := FProducerLeases.Snapshot('build:'
    + CanonicalBuildCacheDigest(AFingerprint), ASnapshot);
end;

function TLWPTBuildCache.ReferencePath(
  const AFingerprint: string): string;
var
  Digest, Hex: string;
begin
  Digest := CanonicalBuildCacheDigest(AFingerprint);
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
  Result := True;
end;

function TLWPTBuildCache.InvalidateReferenceIfCurrent(
  const AFingerprint, AManifestDigest: string): Boolean;
var
  Current: string;
  MutationLease: TObject;
begin
  Result := False;
  MutationLease := FCacheLifecycle.AcquireMutation;
  try
    if ReadSmallTextFile(ReferencePath(AFingerprint), Current)
       and (Trim(Current) = AManifestDigest) then
    begin
      if not SysUtils.DeleteFile(ReferencePath(AFingerprint)) then
      begin
        if FileExists(ReferencePath(AFingerprint)) then
          raise ELWPTBuildCacheError.CreateFmt(
            'failed to invalidate build-cache reference %s',
            [AFingerprint]);
        Exit;
      end;
      Result := True;
    end;
  finally
    MutationLease.Free;
  end;
end;

function TLWPTBuildCache.Materialize(const AFingerprint, ADestination,
  ASessionTemporaryRoot: string; out AResult: TLWPTCachedBuildResult;
  out AReason: string): Boolean;
var
  ManifestDigest, ManifestPath, ManifestText, ReferenceText: string;
  ObjectFailure: TLWPTObjectMaterializeFailure;
begin
  Result := False;
  AResult := Default(TLWPTCachedBuildResult);
  AReason := 'no-result';
  if not ReadSmallTextFile(ReferencePath(AFingerprint), ReferenceText) then
    Exit;
  ManifestDigest := CanonicalBuildCacheDigest(Trim(ReferenceText));
  if ManifestDigest = '' then
  begin
    AReason := 'invalid-reference';
    Exit;
  end;
  ForceDirectories(ASessionTemporaryRoot);
  ManifestPath := MakeTmpPath(ASessionTemporaryRoot, 'result-manifest');
  if not FObjects.Materialize(ManifestDigest, ManifestPath,
       ASessionTemporaryRoot, ObjectFailure) then
  begin
    AReason := 'result-manifest-'
      + ObjectMaterializeFailureName(ObjectFailure);
    if ObjectFailure in [omfObjectMissing, omfVerificationFailed] then
      if not InvalidateReferenceIfCurrent(AFingerprint,
           ManifestDigest) then AReason := 'no-result';
    Exit;
  end;
  try
    if not ReadSmallTextFile(ManifestPath, ManifestText)
       or not ParseBuildResultManifest(ManifestText, AResult)
       or (AResult.Fingerprint <>
         CanonicalBuildCacheDigest(AFingerprint)) then
    begin
      AReason := 'result-manifest-invalid';
      if not InvalidateReferenceIfCurrent(AFingerprint,
           ManifestDigest) then AReason := 'no-result';
      Exit;
    end;
  finally
    SysUtils.DeleteFile(ManifestPath);
  end;
  if not FObjects.Materialize(AResult.ArtifactDigest, ADestination,
    ASessionTemporaryRoot, ObjectFailure) then
  begin
    AReason := 'artifact-' + ObjectMaterializeFailureName(ObjectFailure);
    if ObjectFailure in [omfObjectMissing, omfVerificationFailed] then
      if not InvalidateReferenceIfCurrent(AFingerprint,
           ManifestDigest) then AReason := 'no-result';
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
    CacheResult.Fingerprint := CanonicalBuildCacheDigest(AFingerprint);
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
    Lines := SerializeBuildResultManifest(CacheResult);
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
