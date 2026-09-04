{ LWPT.Registry.Mirror -- explicit pull synchronization and read-only serving. }
unit LWPT.Registry.Mirror;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store,
  LWPT.Registry.Verification;

const
  MAXIMUM_MIRROR_ARCHIVE_BYTES = Int64(256) * 1024 * 1024;

type
  TLWPTRegistryMirror = class(TLWPTRegistryStore)
  private
    function Trust: TLWPTRegistryTrust;
    function Accepted(const AState: TLWPTRegistryState): TLWPTRegistryAcceptedState;
    function VerifyStateProof(const AState: TLWPTRegistryState;
      AProgress: TSHA256Progress = nil): TLWPTVerifiedRegistry;
    procedure SaveAttempt(const AOutcome: string);
    procedure CacheDocument(const APath: string; const ABytes: TBytes);
  public
    procedure Recover; override;
    function LoadCurrentState(AProgress: TSHA256Progress = nil): TLWPTRegistryState; override;
    procedure Synchronize;
    function VerifyMirror: string;
  end;

procedure ValidateMirrorConfiguration(const AConfig: TLWPTRegistryConfig);

implementation

uses
  StrUtils,

  HTTPClient,
  LWPT.ProducerLease,
  LWPT.Registry.Filesystem;

const
  MIRROR_REQUEST_TIMEOUT_MS = 120 * 1000;
  MIRROR_ATTEMPT_PATH = 'state/sync-attempt.toml';

type
  TMirrorDocumentSource = class(TLWPTRegistryDocumentSource)
  public
    Store: TLWPTRegistryMirror;
    API: string;
    Progress: TSHA256Progress;
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; override;
  end;

function Bytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(Result) > 0 then Move(AText[1], Result[0], Length(Result));
end;

function Text(const ABytes: TBytes): string;
begin
  Result := '';
  if Length(ABytes) > 0 then SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;

function GetDocument(const AURL, AMediaType: string;
  const AMaximumBytes: Int64): TBytes;
var
  Options: THTTPRequestOptions;
  Headers: THTTPHeaders;
  Response: THTTPResponse;
  Header: THTTPHeader;
  ContentType: string;
begin
  if not RegistryURIIsCanonical(AURL, True) then
    raise ELWPTRegistryError.CreateStable('invalid_registry_uri', 'noncanonical request URI');
  Options := DefaultHTTPRequestOptions;
  Options.MaxResponseBodyBytes := AMaximumBytes;
  Options.RequestTimeoutMilliseconds := MIRROR_REQUEST_TIMEOUT_MS;
  { Discovery endpoints are scoped to the configured transport. Never follow
    a redirect before checking its target's transport and scope. }
  Options.MaximumRedirects := 0;
  SetLength(Headers, 1);
  Headers[0].Name := 'Accept';
  Headers[0].Value := AMediaType;
  try
    Response := HTTPGet(AURL, Headers, Options);
  except
    on E: EHTTPError do
      raise ELWPTRegistryError.CreateStable('registry_transport_failed', E.Message);
  end;
  if Response.StatusCode <> 200 then
    raise ELWPTRegistryError.CreateStable('registry_transport_failed',
      'upstream returned HTTP ' + IntToStr(Response.StatusCode));
  ContentType := '';
  for Header in Response.Headers do
  begin
    if SameText(Header.Name, 'Content-Type') then ContentType := LowerCase(Trim(Header.Value));
    if SameText(Header.Name, 'Content-Encoding') and (Header.Value <> '') then
      raise ELWPTRegistryError.CreateStable('registry_content_encoding_forbidden',
        'hashes require exact protocol bytes');
  end;
  if Pos(';', ContentType) > 0 then
    ContentType := Trim(Copy(ContentType, 1, Pos(';', ContentType) - 1));
  if ContentType <> AMediaType then
    raise ELWPTRegistryError.CreateStable('registry_media_type_mismatch',
      'upstream returned an unexpected media type');
  Result := Response.Body;
end;

procedure ValidateMirrorConfiguration(const AConfig: TLWPTRegistryConfig);
begin
  ValidateRegistryConfiguration(AConfig);
  if (AConfig.Role <> rrMirror)
    or not RegistryURIIsCanonical(AConfig.Identity, True)
    or not RegistryURIIsCanonical(AConfig.UpstreamURL, True)
    or not RegistryTrustRootIsValid(AConfig.TrustKeyID, AConfig.TrustPublicKey) then
    raise ELWPTRegistryError.CreateStable('invalid_mirror_configuration',
      'mirror role, canonical origin and upstream, and an explicit valid root pin are required');
end;

function TLWPTRegistryMirror.Trust: TLWPTRegistryTrust;
begin
  Result.Origin := Config.Identity;
  Result.KeyId := Config.TrustKeyID;
  Result.PublicKey := Config.TrustPublicKey;
end;

function TLWPTRegistryMirror.Accepted(const AState: TLWPTRegistryState): TLWPTRegistryAcceptedState;
begin
  if (AState.Sequence > High(Int64)) or not RegistryHashIsCanonical(AState.CheckpointHash) then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'invalid accepted mirror state');
  Result.Origin := Config.Identity;
  Result.Sequence := AState.Sequence;
  Result.Snapshot := AState.SnapshotHash;
  Result.CheckpointHash := AState.CheckpointHash;
  Result.KeyId := AState.TrustKeyID;
  Result.PublicKey := AState.TrustPublicKey;
end;

procedure TLWPTRegistryMirror.CacheDocument(const APath: string; const ABytes: TBytes);
begin
  WriteImmutable(APath, ABytes);
end;

function TMirrorDocumentSource.ReadDocument(const APath: string;
  const AMaximumBytes: Int64): TBytes;
var
  Digest, MediaType: string;
begin
  if Assigned(Progress) then Progress;
  if StartsStr('snapshots/sha256/', APath) then
  begin
    Digest := Copy(APath, Length('snapshots/sha256/') + 1, 64);
    MediaType := 'snapshot';
  end
  else if StartsStr('records/sha256/', APath) then
  begin
    Digest := Copy(APath, Length('records/sha256/') + 1, 64);
    MediaType := 'package';
  end
  else raise ELWPTRegistryError.CreateStable('invalid_resource_path', 'unexpected proof resource');
  if not RegistryHashIsCanonical('sha256:' + Digest) or not EndsStr(Digest + '.toml', APath) then
    raise ELWPTRegistryError.CreateStable('invalid_resource_path', 'invalid proof resource hash');
  if (API = '') or FileExists(IncludeTrailingPathDelimiter(Store.Root) + APath) then
    Result := Store.LoadResource(APath, Progress, AMaximumBytes)
  else
    Result := GetDocument(API + '/' + APath, 'application/vnd.' + PROGRAM_NAME
      + '.registry-' + MediaType + '+toml', AMaximumBytes);
  if SHA256BytesPrefixed(Result) <> 'sha256:' + Digest then
    raise ELWPTRegistryError.CreateStable('resource_hash_mismatch', 'proof resource hash does not match');
  if API <> '' then Store.CacheDocument(APath, Result);
end;

function TLWPTRegistryMirror.VerifyStateProof(const AState: TLWPTRegistryState;
  AProgress: TSHA256Progress): TLWPTVerifiedRegistry;
var
  Source: TMirrorDocumentSource;
  Proof: TLWPTRegistryProof;
  Prefix: string;
begin
  Prefix := 'checkpoints/renewals/sha256/' + Copy(AState.CheckpointHash, 8, 64);
  if not RegistryHashIsCanonical(AState.CheckpointHash)
    or (AState.CheckpointPath <> Prefix + '.toml')
    or (AState.SignaturePath <> Prefix + '.sig.toml') then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'invalid mirror proof paths');
  Proof := Default(TLWPTRegistryProof);
  Proof.Checkpoint := LoadResource(AState.CheckpointPath, AProgress, MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
  Proof.Signature := LoadResource(AState.SignaturePath, AProgress, MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
  Source := TMirrorDocumentSource.Create;
  try
    Source.Store := Self;
    Source.Progress := AProgress;
    Result := VerifyRegistryProof(Proof, Trust, Accepted(AState), RegistryTimestampNow,
      rvmLockedProof, Source, DefaultRegistryVerificationLimits);
  finally
    Source.Free;
  end;
end;

procedure TLWPTRegistryMirror.Recover;
begin
  ValidateMirrorConfiguration(Config);
  { Verified immutable resources survive interrupted synchronization. There is
    no origin seed, derived publication index, or temporary-directory sweep. }
  if FileExists(RootPath('state/current.toml')) then LoadCurrentState;
end;

function TLWPTRegistryMirror.LoadCurrentState(AProgress: TSHA256Progress): TLWPTRegistryState;
begin
  Result := ReadCurrentState(AProgress);
  VerifyStateProof(Result, AProgress);
end;

procedure TLWPTRegistryMirror.SaveAttempt(const AOutcome: string);
begin
  AtomicWriteBytes(RootPath(MIRROR_ATTEMPT_PATH), TmpRoot,
    Bytes('attempted_at = ' + RegistryTOMLQuote(RegistryTimestampNow) + #10
      + 'outcome = ' + RegistryTOMLQuote(AOutcome) + #10));
end;

procedure TLWPTRegistryMirror.Synchronize;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Discovery: TLWPTRegistryDiscovery;
  Proof: TLWPTRegistryProof;
  Prior: TLWPTRegistryAcceptedState;
  Verified: TLWPTVerifiedRegistry;
  Source: TMirrorDocumentSource;
  State: TLWPTRegistryState;
  Package: TLWPTRegistryPackage;
  Document, Archive: TBytes;
  ArchiveStream: TStream;
  HasRotations: Boolean;
  ObjectPath, FullPath, Prefix, KeyDocument: string;

  procedure RequireScope(const AURL: string);
  begin
    if not StartsStr(Config.UpstreamURL + '/', AURL) then
      raise ELWPTRegistryError.CreateStable('registry_discovery_scope_mismatch',
        'discovery endpoint escapes configured transport');
  end;
begin
  Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
  Lease := nil;
  Source := nil;
  try
    Lease := Coordinator.TryAcquire('registry-publication', 'registry mirror synchronization');
    if not Assigned(Lease) then
      raise ELWPTRegistryError.CreateStable('publication_locked', 'another synchronization owns this mirror');
    try
      Prior := Default(TLWPTRegistryAcceptedState);
      if FileExists(RootPath('state/current.toml')) then Prior := Accepted(LoadCurrentState);
      Document := GetDocument(Config.UpstreamURL + '/.well-known/' + PROGRAM_NAME
        + '-registry', 'application/vnd.' + PROGRAM_NAME + '.registry-discovery+toml',
        MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
      Discovery := ParseRegistryDiscovery(Text(Document));
      if Discovery.Origin <> Config.Identity then
        raise ELWPTRegistryError.CreateStable('registry_origin_mismatch', 'discovery changed the pinned identity');
      if Discovery.BaseURL <> Config.UpstreamURL then
        raise ELWPTRegistryError.CreateStable('registry_discovery_scope_mismatch', 'discovery changed the contact base');
      RequireScope(Discovery.API);
      RequireScope(Discovery.Capabilities);
      RequireScope(Discovery.Checkpoint);
      if Discovery.Rotations <> '' then RequireScope(Discovery.Rotations);
      Document := GetDocument(Discovery.Capabilities, 'application/vnd.' + PROGRAM_NAME
        + '.registry-capabilities+toml', MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
      ValidateRegistryCapabilities(Text(Document), Discovery.RoleName, HasRotations);
      if HasRotations <> (Discovery.Rotations <> '') then
        raise ELWPTRegistryError.CreateStable('registry_rotation_capability_mismatch', 'inconsistent discovery capabilities');
      Proof := Default(TLWPTRegistryProof);
      Proof.Checkpoint := GetDocument(Discovery.Checkpoint, 'application/vnd.' + PROGRAM_NAME
        + '.registry-checkpoint+toml', MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
      Proof.Signature := GetDocument(Copy(Discovery.Checkpoint, 1, Length(Discovery.Checkpoint) - 5)
        + '.sig.toml', 'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml',
        MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
      Source := TMirrorDocumentSource.Create;
      Source.Store := Self;
      Source.API := Discovery.API;
      Verified := VerifyRegistryProof(Proof, Trust, Prior, RegistryTimestampNow,
        rvmAcquire, Source, DefaultRegistryVerificationLimits);
      for Package in Verified.Packages do
      begin
        if Package.ArchiveSize > MAXIMUM_MIRROR_ARCHIVE_BYTES then
          raise ELWPTRegistryError.CreateStable('mirror_archive_limit_exceeded',
            'archive exceeds the bounded whole-body transfer limit');
        ObjectPath := 'objects/sha256/' + Copy(Package.ArchiveHash, 8, 64);
        FullPath := RootPath(ObjectPath);
        ArchiveStream := nil;
        try
          if FileExists(FullPath) then
            ArchiveStream := OpenRegistryFileWithoutFollowingLinks(FullPath)
          else
          begin
            Archive := GetDocument(Discovery.API + '/' + ObjectPath, 'application/gzip',
              Package.ArchiveSize);
            ArchiveStream := TBytesStream.Create(Archive);
          end;
          VerifyRegistryArtifact(Package, ArchiveStream);
          if not FileExists(FullPath) then WriteImmutable(ObjectPath, Archive);
        finally
          ArchiveStream.Free;
          Archive := nil;
        end;
      end;
      { Recheck current freshness immediately before activation, using only
        retained resources. Expiry during transfer cannot become a fresh head. }
      Source.API := '';
      Verified := VerifyRegistryProof(Proof, Trust, Prior, RegistryTimestampNow,
        rvmAcquire, Source, DefaultRegistryVerificationLimits);
      State := Default(TLWPTRegistryState);
      State.Sequence := Verified.State.Sequence;
      State.SnapshotHash := Verified.State.Snapshot;
      State.CheckpointHash := Verified.State.CheckpointHash;
      State.TrustKeyID := Verified.State.KeyId;
      State.TrustPublicKey := Verified.State.PublicKey;
      State.LastSync := RegistryTimestampNow;
      Prefix := 'checkpoints/renewals/sha256/' + Copy(State.CheckpointHash, 8, 64);
      State.CheckpointPath := Prefix + '.toml';
      State.SignaturePath := Prefix + '.sig.toml';
      WriteImmutable(State.CheckpointPath, Proof.Checkpoint);
      WriteImmutable(State.SignaturePath, Proof.Signature);
      KeyDocument := 'schema = ' + RegistryTOMLQuote(PROGRAM_NAME + '-registry-key-v1')
        + #10 + 'origin = ' + RegistryTOMLQuote(Config.Identity)
        + #10 + 'key_id = ' + RegistryTOMLQuote(Config.TrustKeyID)
        + #10 + 'algorithm = "ed25519"' + #10 + 'public_key = '
        + RegistryTOMLQuote(Config.TrustPublicKey) + #10 + 'valid_from_sequence = 1' + #10;
      WriteImmutable(RegistryKeyStoragePath(Config.TrustKeyID), Bytes(KeyDocument));
      SaveAttempt('verified');
      { All immutable files are closed and verified before this atomic pointer.
        This is process-interruption recovery, not an fsync power-loss promise. }
      ActivateState(State);
    except
      on E: Exception do
      begin
        SaveAttempt(E.Message);
        raise;
      end;
    end;
  finally
    Source.Free;
    Lease.Free;
    Coordinator.Free;
  end;
end;

function TLWPTRegistryMirror.VerifyMirror: string;
var
  State: TLWPTRegistryState;
  Verified: TLWPTVerifiedRegistry;
  Package: TLWPTRegistryPackage;
  Stream: TStream;
  Freshness: string;
begin
  Result := 'role = "mirror"' + #10 + 'origin = ' + RegistryTOMLQuote(Config.Identity) + #10;
  if FileExists(RootPath('state/current.toml')) then
  begin
    State := ReadCurrentState;
    Verified := VerifyStateProof(State);
    for Package in Verified.Packages do
    begin
      Stream := OpenRegistryFileWithoutFollowingLinks(RootPath('objects/sha256/'
        + Copy(Package.ArchiveHash, 8, 64)));
      try
        VerifyRegistryArtifact(Package, Stream);
      finally
        Stream.Free;
      end;
    end;
    Freshness := 'fresh';
    if Verified.ExpiresAt <= RegistryTimestampNow then Freshness := 'expired';
    Result := Result + 'sequence = ' + UIntToStr(State.Sequence) + #10
      + 'freshness = ' + RegistryTOMLQuote(Freshness) + #10
      + 'expires_at = ' + RegistryTOMLQuote(Verified.ExpiresAt) + #10
      + 'last_successful_sync = ' + RegistryTOMLQuote(State.LastSync) + #10;
  end
  else Result := Result + 'freshness = "uninitialized"' + #10;
  if FileExists(RootPath(MIRROR_ATTEMPT_PATH)) then
    Result := Result + Text(LoadResource(MIRROR_ATTEMPT_PATH, nil, MAX_REGISTRY_CONTROL_DOCUMENT_BYTES));
end;

end.
