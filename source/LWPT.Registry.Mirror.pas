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
  {$IFDEF REGISTRY_TESTING}
  TRegistryMirrorTransferStats = record
    PeakReserved, CompletedReserved: Int64;
    MaximumWorkers: Integer;
  end;
  {$ENDIF}

  TLWPTRegistryMirror = class(TLWPTRegistryStore)
  private
    {$IFDEF REGISTRY_TESTING}
    FTransferStats: TRegistryMirrorTransferStats;
    {$ENDIF}
    function Trust: TLWPTRegistryTrust;
    function Accepted(const AState: TLWPTRegistryState): TLWPTRegistryAcceptedState;
    function VerifyStateProof(const AState: TLWPTRegistryState;
      AProgress: TSHA256Progress = nil): TLWPTVerifiedRegistry;
    procedure SaveAttempt(const AOutcome: string);
    procedure CacheDocument(const APath: string; const ABytes: TBytes);
    procedure TransferArchives(const AAPI: string; const APackages: TLWPTRegistryPackageArray);
  public
    procedure Recover; override;
    function LoadCurrentState(AProgress: TSHA256Progress = nil): TLWPTRegistryState; override;
    function CaptureReadView(AProgress: TSHA256Progress = nil): TLWPTRegistryReadView; override;
    procedure Synchronize;
    function VerifyMirror: string;
  end;

procedure ValidateMirrorConfiguration(const AConfig: TLWPTRegistryConfig);
{$IFDEF REGISTRY_TESTING}
function RegistryMirrorProofChecksForTesting: Integer;
function RegistryMirrorCanAdmitForTesting(const AReserved, ASize: Int64;
  const AWorkers: Integer): Boolean;
procedure RegistryMirrorTransferForTesting(AMirror: TLWPTRegistryMirror;
  const AAPI: string; const APackages: TLWPTRegistryPackageArray);
function RegistryMirrorTransferStatsForTesting(AMirror: TLWPTRegistryMirror): TRegistryMirrorTransferStats;
{$ENDIF}

implementation

uses
  Generics.Collections,
  StrUtils,

  HTTPClient,
  LWPT.ProducerLease,
  LWPT.Registry.Filesystem;

const
  MIRROR_REQUEST_TIMEOUT_MS = 120 * 1000;
  MIRROR_ATTEMPT_PATH = 'state/sync-attempt.toml';
  MAXIMUM_MIRROR_ARCHIVE_WORKERS = 2;

{$IFDEF REGISTRY_TESTING}
var
  MirrorProofChecks: Integer;

function RegistryMirrorProofChecksForTesting: Integer;
begin
  Result := MirrorProofChecks;
end;
{$ENDIF}

type
  TMirrorArchiveWorker = class(TThread)
  private
    FURL: string;
    FPackage: TLWPTRegistryPackage;
  protected
    procedure Execute; override;
  public
    Archive: TBytes;
    Error: string;
    constructor Create(const AAPI: string; const APackage: TLWPTRegistryPackage);
  end;

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
  ContentType, CanonicalBase: string;
begin
  CanonicalBase := AURL;
  if Pos('?', CanonicalBase) > 0 then
    CanonicalBase := Copy(CanonicalBase, 1, Pos('?', CanonicalBase) - 1);
  if not RegistryURIIsCanonical(CanonicalBase, True) or (Pos('#', AURL) > 0) then
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

constructor TMirrorArchiveWorker.Create(const AAPI: string;
  const APackage: TLWPTRegistryPackage);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPackage := APackage;
  FURL := AAPI + '/objects/sha256/' + Copy(APackage.ArchiveHash, 8, 64);
end;

procedure TMirrorArchiveWorker.Execute;
var
  Stream: TBytesStream;
begin
  try
    Archive := GetDocument(FURL, 'application/gzip', FPackage.ArchiveSize);
    Stream := TBytesStream.Create(Archive);
    try
      VerifyRegistryArtifact(FPackage, Stream);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      Error := E.Message;
      Archive := nil;
    end;
  end;
end;

function MirrorCanAdmit(const AReserved, ASize: Int64;
  const AWorkers: Integer): Boolean;
begin
  { Subtraction after range checks avoids overflow even for hostile sizes.
    A reservation includes completed buffers until their owner is freed. }
  if (AWorkers < 0) or (AWorkers >= MAXIMUM_MIRROR_ARCHIVE_WORKERS)
    or (AReserved < 0) or (AReserved > MAXIMUM_MIRROR_ARCHIVE_BYTES)
    or (ASize < 0) then Exit(False);
  Result := ASize <= MAXIMUM_MIRROR_ARCHIVE_BYTES - AReserved;
end;

{$IFDEF REGISTRY_TESTING}
function RegistryMirrorCanAdmitForTesting(const AReserved, ASize: Int64;
  const AWorkers: Integer): Boolean;
begin
  Result := MirrorCanAdmit(AReserved, ASize, AWorkers);
end;

procedure RegistryMirrorTransferForTesting(AMirror: TLWPTRegistryMirror;
  const AAPI: string; const APackages: TLWPTRegistryPackageArray);
begin
  AMirror.TransferArchives(AAPI, APackages);
end;

function RegistryMirrorTransferStatsForTesting(AMirror: TLWPTRegistryMirror): TRegistryMirrorTransferStats;
begin
  Result := AMirror.FTransferStats;
end;
{$ENDIF}

procedure TLWPTRegistryMirror.TransferArchives(const AAPI: string;
  const APackages: TLWPTRegistryPackageArray);
var
  Sizes: TDictionary<string, Int64>;
  Missing: TLWPTRegistryPackageArray;
  Package: TLWPTRegistryPackage;
  Workers: array[0..MAXIMUM_MIRROR_ARCHIVE_WORKERS - 1] of TMirrorArchiveWorker;
  Reserved, PreviousSize: Int64;
  Count, Next, Admitted, I: Integer;
  Path, Failure: string;
  Stream: TStream;
begin
  {$IFDEF REGISTRY_TESTING}
  FTransferStats := Default(TRegistryMirrorTransferStats);
  {$ENDIF}
  Sizes := TDictionary<string, Int64>.Create;
  try
    { Validate the complete authenticated plan before any archive request.
      The same bytes may serve several records, but their size cannot differ. }
    for Package in APackages do
    begin
      if (Package.ArchiveSize < 0) or (Package.ArchiveSize > MAXIMUM_MIRROR_ARCHIVE_BYTES) then
        raise ELWPTRegistryError.CreateStable('mirror_archive_limit_exceeded',
          'archive exceeds the bounded whole-body transfer limit');
      if Sizes.TryGetValue(Package.ArchiveHash, PreviousSize) then
      begin
        if PreviousSize <> Package.ArchiveSize then
          raise ELWPTRegistryError.CreateStable('registry_archive_size_conflict',
            'authenticated records disagree on one archive size');
      end
      else Sizes.Add(Package.ArchiveHash, Package.ArchiveSize);
    end;
    SetLength(Missing, Sizes.Count);
    Count := 0;
    for Package in APackages do
      if Sizes.ContainsKey(Package.ArchiveHash) then
      begin
        Sizes.Remove(Package.ArchiveHash);
        Path := RootPath('objects/sha256/' + Copy(Package.ArchiveHash, 8, 64));
        if FileExists(Path) then
        begin
          Stream := OpenRegistryFileWithoutFollowingLinks(Path);
          try
            VerifyRegistryArtifact(Package, Stream);
          finally
            Stream.Free;
          end;
        end
        else
        begin
          Missing[Count] := Package;
          Inc(Count);
        end;
      end;
  finally
    Sizes.Free;
  end;
  Next := 0;
  while Next < Count do
  begin
    Reserved := 0;
    Admitted := 0;
    Failure := '';
    for I := Low(Workers) to High(Workers) do Workers[I] := nil;
    try
      { Bounded pairs deliberately drain before admitting another pair. This
        also keeps finished sibling buffers charged during slow transfers. }
      while (Next < Count) and MirrorCanAdmit(Reserved,
        Missing[Next].ArchiveSize, Admitted) do
      begin
        Workers[Admitted] := TMirrorArchiveWorker.Create(AAPI, Missing[Next]);
        Inc(Reserved, Missing[Next].ArchiveSize);
        Inc(Admitted);
        Inc(Next);
        Workers[Admitted - 1].Start;
      end;
      {$IFDEF REGISTRY_TESTING}
      if Reserved > FTransferStats.PeakReserved then FTransferStats.PeakReserved := Reserved;
      if Admitted > FTransferStats.MaximumWorkers then FTransferStats.MaximumWorkers := Admitted;
      {$ENDIF}
      for I := 0 to Admitted - 1 do Workers[I].WaitFor;
      {$IFDEF REGISTRY_TESTING}
      if Reserved > FTransferStats.CompletedReserved then FTransferStats.CompletedReserved := Reserved;
      {$ENDIF}
      { Join every active request even after failure. Successful siblings are
        immutable retry material, never permission to activate a partial head. }
      for I := 0 to Admitted - 1 do
      begin
        if Assigned(Workers[I].FatalException) then
        begin
          if Failure = '' then Failure := 'registry_archive_worker_failed: '
            + Workers[I].FatalException.ClassName;
        end
        else if Workers[I].Error <> '' then
        begin
          if Failure = '' then Failure := Workers[I].Error;
        end
        else
          try
            WriteImmutable('objects/sha256/' + Copy(Workers[I].FPackage.ArchiveHash, 8, 64),
              Workers[I].Archive);
          except
            on E: Exception do if Failure = '' then Failure := E.Message;
          end;
      end;
    finally
      for I := 0 to Admitted - 1 do
      begin
        PreviousSize := Workers[I].FPackage.ArchiveSize;
        Workers[I].Free;
        Dec(Reserved, PreviousSize);
      end;
    end;
    if Failure <> '' then raise ELWPTRegistryError.Create(Failure);
  end;
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

procedure RememberRetrieval(var AProof: TLWPTRegistryProof; const ABytes: TBytes);
var
  Index: Integer;
begin
  Index := Length(AProof.RetrievalDocuments);
  SetLength(AProof.RetrievalDocuments, Index + 1);
  AProof.RetrievalDocuments[Index] := ABytes;
end;

function TLWPTRegistryMirror.VerifyStateProof(const AState: TLWPTRegistryState;
  AProgress: TSHA256Progress): TLWPTVerifiedRegistry;
var
  Source: TMirrorDocumentSource;
  Proof: TLWPTRegistryProof;
  Prefix, Sequence: string;
  Sequences: TStringList;
  Budget: TLWPTRegistryMetadataBudget;
  Index: Integer;
  Rotation: TLWPTUntrustedRegistryRotation;
  KeyTrust: TLWPTRegistryTrust;
  function ReadBounded(const APath: string; const AAuxiliary: Boolean = False): TBytes;
  var
    Allowance: Int64;
  begin
    Allowance := Budget.Allowance;
    if Allowance > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES then Allowance := MAX_REGISTRY_CONTROL_DOCUMENT_BYTES;
    Result := LoadResource(APath, AProgress, Allowance);
    Budget.Account(Result);
    if AAuxiliary then RememberRetrieval(Proof, Result);
  end;
begin
  Prefix := 'checkpoints/renewals/sha256/' + Copy(AState.CheckpointHash, 8, 64);
  {$IFDEF REGISTRY_TESTING}
  InterlockedIncrement(MirrorProofChecks);
  {$ENDIF}
  if not RegistryHashIsCanonical(AState.CheckpointHash)
    or (AState.CheckpointPath <> Prefix + '.toml')
    or (AState.SignaturePath <> Prefix + '.sig.toml') then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'invalid mirror proof paths');
  Proof := Default(TLWPTRegistryProof);
  Source := TMirrorDocumentSource.Create;
  Budget := TLWPTRegistryMetadataBudget.Create(DefaultRegistryVerificationLimits);
  Sequences := nil;
  try
    Proof.Checkpoint := ReadBounded(AState.CheckpointPath);
    Proof.Signature := ReadBounded(AState.SignaturePath);
    ValidateRegistryKeyDocument(ReadBounded(RegistryKeyStoragePath(Config.TrustKeyID), True),
      Trust, AState.Sequence);
    Sequences := RotationSequences(AState, AProgress);
    SetLength(Proof.Rotations, Sequences.Count);
    Index := 0;
    for Sequence in Sequences do
    begin
      Prefix := 'rotations/' + Sequence;
      Proof.Rotations[Index].Document := ReadBounded(Prefix + '.toml');
      Proof.Rotations[Index].OldSignature := ReadBounded(Prefix + '.old.sig.toml');
      Proof.Rotations[Index].NewSignature := ReadBounded(Prefix + '.new.sig.toml');
      Rotation := InspectRegistryRotation(Proof.Rotations[Index].Document);
      KeyTrust.Origin := Config.Identity;
      KeyTrust.KeyId := Rotation.ToKey;
      KeyTrust.PublicKey := Rotation.ToPublicKey;
      ValidateRegistryKeyDocument(ReadBounded(RegistryKeyStoragePath(Rotation.ToKey), True),
        KeyTrust, Rotation.EffectiveSequence, True);
      Inc(Index);
    end;
    Source.Store := Self;
    Source.Progress := AProgress;
    Result := VerifyRegistryProof(Proof, Trust, Accepted(AState), RegistryTimestampNow,
      rvmLockedProof, Source, DefaultRegistryVerificationLimits);
  finally
    Sequences.Free;
    Budget.Free;
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

function TLWPTRegistryMirror.CaptureReadView(AProgress: TSHA256Progress): TLWPTRegistryReadView;
var
  State: TLWPTRegistryState;
  Verified: TLWPTVerifiedRegistry;
  Document: TLWPTRegistryDocument;
  RotationProof: TLWPTRegistryRotationProof;
  Rotation: TLWPTUntrustedRegistryRotation;
  Prefix: string;
  Paths, Rotations: TStringList;
begin
  State := ReadCurrentState(AProgress);
  Verified := VerifyStateProof(State, AProgress);
  Paths := TStringList.Create;
  Rotations := TStringList.Create;
  try
    Paths.Add(State.CheckpointPath);
    Paths.Add(State.SignaturePath);
    Paths.Add(RegistryKeyStoragePath(Config.TrustKeyID));
    for Document in Verified.Documents do
      if StartsStr('snapshots/', Document.Path) then Paths.Add(Document.Path);
    for RotationProof in Verified.Proof.Rotations do
    begin
      Rotation := InspectRegistryRotation(RotationProof.Document);
      Rotations.Add(IntToStr(Rotation.EffectiveSequence));
      Prefix := 'rotations/' + IntToStr(Rotation.EffectiveSequence);
      Paths.Add(Prefix + '.toml');
      Paths.Add(Prefix + '.old.sig.toml');
      Paths.Add(Prefix + '.new.sig.toml');
      Paths.Add(RegistryKeyStoragePath(Rotation.ToKey));
    end;
    Result := TLWPTRegistryReadView.Create(Self, State, Paths, Rotations);
    Paths := nil;
    Rotations := nil;
  finally
    Rotations.Free;
    Paths.Free;
  end;
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
  Verified, PriorVerified: TLWPTVerifiedRegistry;
  Source: TMirrorDocumentSource;
  State: TLWPTRegistryState;
  Document, KeyDocument: TBytes;
  HasRotations: Boolean;
  Prefix: string;
  Budget: TLWPTRegistryMetadataBudget;
  Hint: TLWPTUntrustedRegistryCheckpoint;
  Rotation: TLWPTUntrustedRegistryRotation;
  RotationProof: TLWPTRegistryRotationProof;
  KeyTrust: TLWPTRegistryTrust;
  KeyDocuments: TLWPTRegistryDocumentArray;
  KeyResource: TLWPTRegistryDocument;
  Page: TLWPTRegistryRotationPage;
  PageItem: TLWPTRegistryRotationPageItem;
  Cursors: TStringList;
  PageSize, Index: Integer;
  AfterSequence, PreviousSequence, PinnedSequence: Int64;
  CurrentKey, Cursor, PageURL: string;

  function Control(const AURL, AKind: string; const AAuxiliary: Boolean = True): TBytes;
  var
    Allowance: Int64;
  begin
    Allowance := Budget.Allowance;
    if Allowance > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES then Allowance := MAX_REGISTRY_CONTROL_DOCUMENT_BYTES;
    Result := GetDocument(AURL, 'application/vnd.' + PROGRAM_NAME + '.registry-' + AKind + '+toml', Allowance);
    Budget.Account(Result);
    if AAuxiliary then RememberRetrieval(Proof, Result);
  end;

  procedure KeepKey(const AKeyID: string; const ABytes: TBytes);
  var
    KeyIndex: Integer;
  begin
    KeyIndex := Length(KeyDocuments);
    SetLength(KeyDocuments, KeyIndex + 1);
    KeyDocuments[KeyIndex].Path := RegistryKeyStoragePath(AKeyID);
    KeyDocuments[KeyIndex].Bytes := ABytes;
  end;

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
  Budget := TLWPTRegistryMetadataBudget.Create(DefaultRegistryVerificationLimits);
  Cursors := TStringList.Create;
  Proof := Default(TLWPTRegistryProof);
  try
    Lease := Coordinator.TryAcquire('registry-publication', 'registry mirror synchronization');
    if not Assigned(Lease) then
      raise ELWPTRegistryError.CreateStable('publication_locked', 'another synchronization owns this mirror');
    try
      Prior := Default(TLWPTRegistryAcceptedState);
      if FileExists(RootPath('state/current.toml')) then
      begin
        State := ReadCurrentState;
        PriorVerified := VerifyStateProof(State);
        Prior := Accepted(State);
        Proof.Rotations := PriorVerified.Proof.Rotations;
        for RotationProof in Proof.Rotations do
        begin
          Budget.Account(RotationProof.Document);
          Budget.Account(RotationProof.OldSignature);
          Budget.Account(RotationProof.NewSignature);
        end;
      end;
      Document := Control(Config.UpstreamURL + '/.well-known/' + PROGRAM_NAME + '-registry', 'discovery');
      Discovery := ParseRegistryDiscovery(Text(Document));
      if Discovery.Origin <> Config.Identity then
        raise ELWPTRegistryError.CreateStable('registry_origin_mismatch', 'discovery changed the pinned identity');
      if Discovery.BaseURL <> Config.UpstreamURL then
        raise ELWPTRegistryError.CreateStable('registry_discovery_scope_mismatch', 'discovery changed the contact base');
      RequireScope(Discovery.API);
      RequireScope(Discovery.Capabilities);
      RequireScope(Discovery.Checkpoint);
      if Discovery.Rotations <> '' then RequireScope(Discovery.Rotations);
      Document := Control(Discovery.Capabilities, 'capabilities');
      PageSize := ValidateRegistryCapabilities(Text(Document), Discovery.RoleName, HasRotations);
      if PageSize > 100 then PageSize := 100;
      if HasRotations <> (Discovery.Rotations <> '') then
        raise ELWPTRegistryError.CreateStable('registry_rotation_capability_mismatch', 'inconsistent discovery capabilities');
      Proof.Checkpoint := Control(Discovery.Checkpoint, 'checkpoint', False);
      Proof.Signature := Control(Copy(Discovery.Checkpoint, 1, Length(Discovery.Checkpoint) - 5)
        + '.sig.toml', 'signature', False);
      Hint := InspectRegistryCheckpoint(Proof.Checkpoint);
      KeyDocument := Control(Discovery.API + '/keys/' + Config.TrustKeyID + '.toml', 'key');
      PinnedSequence := ValidateRegistryKeyDocument(KeyDocument, Trust, Hint.Sequence);
      KeepKey(Config.TrustKeyID, KeyDocument);
      CurrentKey := Config.TrustKeyID;
      AfterSequence := 0;
      if PinnedSequence > 1 then AfterSequence := PinnedSequence;
      if Length(Proof.Rotations) > 0 then
      begin
        Rotation := InspectRegistryRotation(Proof.Rotations[High(Proof.Rotations)].Document);
        CurrentKey := Rotation.ToKey;
        AfterSequence := Rotation.EffectiveSequence;
      end;
      PreviousSequence := AfterSequence;
      Cursor := '';
      while CurrentKey <> Hint.KeyId do
      begin
        if not HasRotations then
          raise ELWPTRegistryError.Create('registry_key_rotation_incomplete');
        PageURL := Discovery.Rotations + '?after=' + IntToStr(AfterSequence)
          + '&limit=' + IntToStr(PageSize);
        if Cursor <> '' then PageURL := PageURL + '&cursor=' + RegistryQueryEncode(Cursor);
        Document := Control(PageURL, 'rotation-page');
        Page := ParseRegistryRotationPage(Document, Config.Identity, Discovery.API,
          PreviousSequence, PageSize);
        for PageItem in Page.Items do
        begin
          if (PageItem.EffectiveSequence > Hint.Sequence)
            or (Length(Proof.Rotations) >= DefaultRegistryVerificationLimits.Rotations) then
            raise ELWPTRegistryError.Create('rotation_chain_invalid');
          RotationProof.Document := Control(PageItem.Rotation, 'key-rotation', False);
          Rotation := InspectRegistryRotation(RotationProof.Document);
          if (Rotation.Origin <> Config.Identity) or (Rotation.FromKey <> CurrentKey)
            or (Rotation.EffectiveSequence <> PageItem.EffectiveSequence) then
            raise ELWPTRegistryError.Create('rotation_chain_invalid');
          RotationProof.OldSignature := Control(PageItem.OldSignature, 'signature', False);
          RotationProof.NewSignature := Control(PageItem.NewSignature, 'signature', False);
          Index := Length(Proof.Rotations);
          SetLength(Proof.Rotations, Index + 1);
          Proof.Rotations[Index] := RotationProof;
          CurrentKey := Rotation.ToKey;
          PreviousSequence := Rotation.EffectiveSequence;
          if CurrentKey = Hint.KeyId then Break;
        end;
        if CurrentKey = Hint.KeyId then Break;
        if (Page.NextCursor = '') or (Cursors.IndexOf(Page.NextCursor) >= 0) then
          raise ELWPTRegistryError.Create('registry_key_rotation_incomplete');
        Cursors.Add(Page.NextCursor);
        Cursor := Page.NextCursor;
      end;
      for RotationProof in Proof.Rotations do
      begin
        Rotation := InspectRegistryRotation(RotationProof.Document);
        KeyTrust.Origin := Config.Identity;
        KeyTrust.KeyId := Rotation.ToKey;
        KeyTrust.PublicKey := Rotation.ToPublicKey;
        KeyDocument := Control(Discovery.API + '/keys/' + Rotation.ToKey + '.toml', 'key');
        ValidateRegistryKeyDocument(KeyDocument, KeyTrust, Rotation.EffectiveSequence, True);
        KeepKey(Rotation.ToKey, KeyDocument);
      end;
      Source := TMirrorDocumentSource.Create;
      Source.Store := Self;
      Source.API := Discovery.API;
      Verified := VerifyRegistryProof(Proof, Trust, Prior, RegistryTimestampNow,
        rvmAcquire, Source, DefaultRegistryVerificationLimits);
      TransferArchives(Discovery.API, Verified.Packages);
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
      for KeyResource in KeyDocuments do WriteImmutable(KeyResource.Path, KeyResource.Bytes);
      for RotationProof in Proof.Rotations do
      begin
        Rotation := InspectRegistryRotation(RotationProof.Document);
        Prefix := 'rotations/' + IntToStr(Rotation.EffectiveSequence);
        WriteImmutable(Prefix + '.toml', RotationProof.Document);
        WriteImmutable(Prefix + '.old.sig.toml', RotationProof.OldSignature);
        WriteImmutable(Prefix + '.new.sig.toml', RotationProof.NewSignature);
      end;
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
    Cursors.Free;
    Budget.Free;
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
