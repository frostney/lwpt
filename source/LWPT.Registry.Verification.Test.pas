program LWPT.Registry.Verification.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads, { The real origin store uses the native producer-lease thread driver. }
  {$ENDIF}
  Classes,
  Generics.Collections,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Crypto,
  LWPT.Registry.Mirror,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.Scratch,
  TOML;

const
  FIXTURE_ROOT = 'tests/fixtures/registry/v1/';
  EVALUATION_TIME = '2026-01-06T00:00:00Z';
  ROOT_SNAPSHOT = 'sha256:d2dde0cae212bc793c9a312e55198c65167876aa0722f8cfcbf2f38a5bf5796b';
  ROOT_RECORD = 'sha256:6b464cebeb83b982d076b52f4152b05623fa410fef78c0ce159422097eff4948';

type
  TMirrorFixtureStore = class(TLWPTRegistryMirror)
  public
    procedure Retain(const AVerified: TLWPTVerifiedRegistry);
    procedure Corrupt(const APath: string);
  end;

  TFixtureSource = class(TLWPTRegistryDocumentSource)
  public
    Overrides: TDictionary<string, TBytes>;
    Requested: TStringList;
    BlockPath: string;
    OnlyOverrides: Boolean;
    constructor Create;
    destructor Destroy; override;
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; override;
  end;

  TOriginSource = class(TLWPTRegistryDocumentSource)
  public
    Store: TLWPTRegistryStore;
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; override;
  end;

  TRegistryVerificationTests = class(TTestSuite)
  private
    function Trust: TLWPTRegistryTrust;
    function Proof(const ASequence: Integer): TLWPTRegistryProof;
    function Verify(const AProof: TLWPTRegistryProof;
      const APrior: TLWPTRegistryAcceptedState;
      const AMode: TLWPTRegistryVerificationMode = rvmAcquire;
      const ATime: string = EVALUATION_TIME): TLWPTVerifiedRegistry;
    procedure ExpectFailure(const AProof: TLWPTRegistryProof;
      const AReason: string; const APrior: TLWPTRegistryAcceptedState;
      ASource: TFixtureSource = nil;
      const AMode: TLWPTRegistryVerificationMode = rvmAcquire);
  public
    procedure SetupTests; override;
    procedure CorpusBootstrapAndLifecycle;
    procedure AnchoredHistoryAndCompleteBundle;
    procedure ConflictingHistoryRejected;
    procedure ExpiredAcquisitionRejected;
    procedure LockedExpiredProofAccepted;
    procedure LockedProofRequiresExactState;
    procedure FutureCheckpointRejected;
    procedure TamperedCheckpointRejected;
    procedure InvalidSignatureRejected;
    procedure MissingRotationRejected;
    procedure BothRotationSignaturesRequired;
    procedure ReusedRotationRejected;
    procedure NonCanonicalProofRejected;
    procedure LiteralStringsCannotMaskNesting;
    procedure MalformedDelimitersRejectedBeforeParsing;
    procedure QuotedSyntaxRemainsCanonical;
    procedure SharedEncoderPinsEscapeBytes;
    procedure SnapshotTamperingRejected;
    procedure MissingAncestryRejected;
    procedure DuplicateIdentityRejected;
    procedure SkippedSequenceRejected;
    procedure MetadataLimitsEnforced;
    procedure ArchiveIdentityMatchesCache;
    procedure WrongTrustAndPriorOriginRejected;
    procedure TypedPackageFieldsRequired;
    procedure RealOriginPublicationVerified;
    procedure NumericPreviousRejected;
    procedure LockedCheckpointSubstitutionRejected;
    procedure DowngradeRejected;
    procedure EqualSequenceEquivocationRejected;
    procedure PinnedKeyDocumentValidated;
    procedure RotationPagesAreBoundedAndCanonical;
    procedure RetrievalDocumentsShareProofBudget;
    procedure MirrorReadViewReusesCapturedProof;
  end;

function ReadFixture(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FIXTURE_ROOT + APath, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function AsText(const ABytes: TBytes): string;
begin
  Result := '';
  if Length(ABytes) > 0 then
    SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;

function AsBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(Result) > 0 then Move(AText[1], Result[0], Length(Result));
end;

function Field(const ABytes: TBytes; const AName: string): string;
var
  Parser: TTOMLParser;
  Root: TTOMLNode;
begin
  Parser := TTOMLParser.Create;
  try
    Root := Parser.ParseDocument(AsText(ABytes));
    try
      Result := TomlStr(Root, AName, '');
    finally
      Root.Free;
    end;
  finally
    Parser.Free;
  end;
end;

procedure TMirrorFixtureStore.Retain(const AVerified: TLWPTVerifiedRegistry);
const
  KeyNames: array[0..1] of string = ('root', 'rotated');
var
  State: TLWPTRegistryState;
  Document: TLWPTRegistryDocument;
  Rotation: TLWPTRegistryRotationProof;
  KeyBytes: TBytes;
  Prefix, KeyName: string;
begin
  for Document in AVerified.Documents do WriteImmutable(Document.Path, Document.Bytes);
  for KeyName in KeyNames do
  begin
    KeyBytes := ReadFixture('keys/' + KeyName + '.toml');
    WriteImmutable(RegistryKeyStoragePath(Field(KeyBytes, 'key_id')), KeyBytes);
  end;
  for Rotation in AVerified.Proof.Rotations do
  begin
    Prefix := 'rotations/' + IntToStr(InspectRegistryRotation(Rotation.Document).EffectiveSequence);
    WriteImmutable(Prefix + '.toml', Rotation.Document);
    WriteImmutable(Prefix + '.old.sig.toml', Rotation.OldSignature);
    WriteImmutable(Prefix + '.new.sig.toml', Rotation.NewSignature);
  end;
  State := Default(TLWPTRegistryState);
  State.Sequence := AVerified.State.Sequence;
  State.SnapshotHash := AVerified.State.Snapshot;
  State.TrustKeyID := AVerified.State.KeyId;
  State.TrustPublicKey := AVerified.State.PublicKey;
  State.CheckpointHash := AVerified.State.CheckpointHash;
  State.LastSync := EVALUATION_TIME;
  Prefix := 'checkpoints/renewals/sha256/' + Copy(State.CheckpointHash, 8, 64);
  State.CheckpointPath := Prefix + '.toml';
  State.SignaturePath := Prefix + '.sig.toml';
  WriteImmutable(State.CheckpointPath, AVerified.Proof.Checkpoint);
  WriteImmutable(State.SignaturePath, AVerified.Proof.Signature);
  ActivateState(State);
end;

procedure TMirrorFixtureStore.Corrupt(const APath: string);
begin
  AtomicWriteBytes(RootPath(APath), TmpRoot, AsBytes('tampered'));
end;

procedure TRegistryVerificationTests.MirrorReadViewReusesCapturedProof;
var
  Scratch, Path, Diagnostic: string;
  Mirror: TMirrorFixtureStore;
  View: TLWPTRegistryReadView;
  Config: TLWPTRegistryConfig;
  First, Latest: TLWPTVerifiedRegistry;
  Before: Integer;
  Paths: TStringList;
begin
  Scratch := CreateScratchRoot('registry-read-view');
  Mirror := nil;
  View := nil;
  Paths := TStringList.Create;
  try
    Config := RegistryConfiguration(Trust.Origin, 'http://localhost:8181', 'localhost', 8181, '', '');
    Config.Role := rrMirror;
    Config.UpstreamURL := Trust.Origin;
    Config.TrustKeyID := Trust.KeyId;
    Config.TrustPublicKey := Trust.PublicKey;
    Mirror := TMirrorFixtureStore(TMirrorFixtureStore.Initialize(Scratch, Config, EVALUATION_TIME));
    First := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
    Latest := Verify(Proof(5), First.State);
    Mirror.Retain(First);
    Before := RegistryMirrorProofChecksForTesting;
    View := Mirror.CaptureReadView;
    Mirror.Retain(Latest);
    Expect<Boolean>(View.ResourceIsPublished('rotations/2.toml')).ToBe(False);
    Expect<Boolean>(View.ResourceIsPublished('snapshots/sha256/' + Copy(Latest.State.Snapshot, 8, 64) + '.toml')).ToBe(False);
    Expect<Boolean>(View.ResourceIsPublished('snapshots/sha256/' + Copy(First.State.Snapshot, 8, 64) + '.toml')).ToBe(True);
    Expect<Boolean>(View.ResourceIsPublished('snapshots/sha256/' + UpperCase(Copy(First.State.Snapshot, 8, 64)) + '.toml')).ToBe(False);
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
    Paths.Add('/v1/keys/' + Trust.KeyId + '.toml');
    Paths.Add('/v1/keys/' + Latest.State.KeyId + '.toml');
    Paths.Add('/v1/rotations/2.toml');
    Paths.Add('/v1/rotations/2.old.sig.toml');
    Paths.Add('/v1/rotations?after=0&limit=1');
    Paths.Add('/v1/snapshots/sha256/' + Copy(Latest.State.Snapshot, 8, 64) + '.toml');
    for Path in Paths do
    begin
      Before := RegistryMirrorProofChecksForTesting;
      Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', Path).Status).ToBe(200);
      Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
    end;
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/rotations/2.OLD.SIG.TOML').Status).ToBe(404);
    Mirror.Corrupt('rotations/2.old.sig.toml');
    Diagnostic := '';
    Before := RegistryMirrorProofChecksForTesting;
    try
      RegistryHTTPResponse(Mirror, 'GET', Paths[0]);
    except
      on E: ELWPTRegistryError do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Diagnostic <> '').ToBe(True);
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
  finally
    Paths.Free;
    View.Free;
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure ResignRoot(var AProof: TLWPTRegistryProof);
var
  Seed: TLWPTEd25519Seed;
  Signature: TLWPTEd25519Signature;
  KeyId: string;
begin
  { Published RFC 8032 test-vector key, never an operator credential. }
  if not HexToBytes('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
    Seed, SizeOf(Seed)) then raise Exception.Create('invalid vector');
  KeyId := Field(AProof.Checkpoint, 'key_id');
  Ed25519Sign(AsBytes(PROJECT_NAME + '-REGISTRY-CHECKPOINT-V1' + #10
    + AsText(AProof.Checkpoint)), Seed, Signature);
  AProof.Signature := AsBytes('schema = "' + PROGRAM_NAME
    + '-registry-signature-v1"' + #10 + 'algorithm = "ed25519"' + #10
    + 'key_id = "' + KeyId + '"' + #10 + 'payload = "'
    + SHA256BytesPrefixed(AProof.Checkpoint) + '"' + #10
    + 'signature = "hex:' + BytesToHex(Signature, SizeOf(Signature))
    + '"' + #10);
end;

constructor TFixtureSource.Create;
begin
  inherited Create;
  Overrides := TDictionary<string, TBytes>.Create;
  Requested := TStringList.Create;
end;

destructor TFixtureSource.Destroy;
begin
  Requested.Free;
  Overrides.Free;
  inherited Destroy;
end;

function TFixtureSource.ReadDocument(const APath: string;
  const AMaximumBytes: Int64): TBytes;
var
  FixturePath: string;
begin
  Requested.Add(APath);
  if APath = BlockPath then
    raise ELWPTRegistryError.Create('state_missing: requested proof resource');
  if Overrides.TryGetValue(APath, Result) then Exit;
  if OnlyOverrides then
    raise ELWPTRegistryError.Create('state_missing: offline bundle is incomplete');
  FixturePath := StringReplace(APath, '/sha256/', '/', []);
  Result := ReadFixture(FixturePath);
  if Length(Result) > AMaximumBytes then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: provider read');
end;

function TOriginSource.ReadDocument(const APath: string;
  const AMaximumBytes: Int64): TBytes;
begin
  Result := Store.LoadResource(APath, nil, AMaximumBytes);
end;

function TRegistryVerificationTests.Trust: TLWPTRegistryTrust;
var
  Key: TBytes;
begin
  Key := ReadFixture('keys/root.toml');
  Result.Origin := Field(Key, 'origin');
  Result.KeyId := Field(Key, 'key_id');
  Result.PublicKey := Field(Key, 'public_key');
end;

function TRegistryVerificationTests.Proof(const ASequence: Integer): TLWPTRegistryProof;
begin
  Result := Default(TLWPTRegistryProof);
  Result.Checkpoint := ReadFixture('checkpoints/' + IntToStr(ASequence) + '.toml');
  Result.Signature := ReadFixture('checkpoints/' + IntToStr(ASequence) + '.sig.toml');
  if ASequence > 1 then
  begin
    SetLength(Result.Rotations, 1);
    Result.Rotations[0].Document := ReadFixture('rotations/2.toml');
    Result.Rotations[0].OldSignature := ReadFixture('rotations/2.old.sig.toml');
    Result.Rotations[0].NewSignature := ReadFixture('rotations/2.new.sig.toml');
  end;
end;

function TRegistryVerificationTests.Verify(const AProof: TLWPTRegistryProof;
  const APrior: TLWPTRegistryAcceptedState;
  const AMode: TLWPTRegistryVerificationMode;
  const ATime: string): TLWPTVerifiedRegistry;
var
  Source: TFixtureSource;
begin
  Source := TFixtureSource.Create;
  try
    Result := VerifyRegistryProof(AProof, Trust, APrior, ATime, AMode,
      Source, DefaultRegistryVerificationLimits);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.ExpectFailure(const AProof: TLWPTRegistryProof;
  const AReason: string; const APrior: TLWPTRegistryAcceptedState;
  ASource: TFixtureSource; const AMode: TLWPTRegistryVerificationMode);
var
  Owned: Boolean;
  Actual: string;
begin
  Owned := not Assigned(ASource);
  if Owned then ASource := TFixtureSource.Create;
  try
    Actual := '';
    try
      VerifyRegistryProof(AProof, Trust, APrior, EVALUATION_TIME, AMode,
        ASource, DefaultRegistryVerificationLimits);
    except
      on E: ELWPTRegistryError do Actual := E.Message;
    end;
    Expect<string>(Copy(Actual, 1, Length(AReason))).ToBe(AReason);
  finally
    if Owned then ASource.Free;
  end;
end;

procedure TRegistryVerificationTests.CorpusBootstrapAndLifecycle;
var
  Sequence, Index: Integer;
  Verified: TLWPTVerifiedRegistry;
begin
  for Sequence := 1 to 5 do
  begin
    Verified := Verify(Proof(Sequence), Default(TLWPTRegistryAcceptedState));
    Expect<Int64>(Verified.State.Sequence).ToBe(Sequence);
    Expect<string>(Verified.State.Origin).ToBe(Trust.Origin);
    if Sequence >= 3 then Expect<Integer>(Length(Verified.Packages)).ToBe(3);
    for Index := 0 to High(Verified.Packages) do
      if (Verified.Packages[Index].Name = 'example-lib')
        and (Verified.Packages[Index].Version = '1.1.0') then
        Expect<Boolean>(Verified.Packages[Index].Yanked).ToBe(Sequence = 4);
  end;
end;

procedure TRegistryVerificationTests.AnchoredHistoryAndCompleteBundle;
var
  Prior, Verified, Replayed: TLWPTVerifiedRegistry;
  Source: TFixtureSource;
  Index: Integer;
begin
  Prior := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  Verified := Verify(Proof(5), Prior.State);
  Source := TFixtureSource.Create;
  try
    Source.OnlyOverrides := True;
    for Index := 0 to High(Verified.Documents) do
      Source.Overrides.Add(Verified.Documents[Index].Path,
        Verified.Documents[Index].Bytes);
    Replayed := VerifyRegistryProof(Verified.Proof, Trust, Verified.State,
      '2030-01-01T00:00:00Z', rvmLockedProof, Source,
      DefaultRegistryVerificationLimits);
    Expect<Integer>(Source.Requested.Count).ToBe(Length(Verified.Documents));
    Expect<string>(Replayed.State.Snapshot).ToBe(Verified.State.Snapshot);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.ConflictingHistoryRejected;
var
  Prior: TLWPTVerifiedRegistry;
begin
  Prior := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  Prior.State.Snapshot := 'sha256:' + StringOfChar('0', 64);
  ExpectFailure(Proof(5), 'snapshot_consistency_failed', Prior.State);
end;

procedure TRegistryVerificationTests.ExpiredAcquisitionRejected;
var
  Actual: string;
begin
  Actual := '';
  try
    Verify(Proof(1), Default(TLWPTRegistryAcceptedState), rvmAcquire,
      '2026-01-08T00:00:00Z');
  except
    on E: ELWPTRegistryError do Actual := E.Message;
  end;
  Expect<string>(Actual).ToBe('checkpoint_expired');
end;

procedure TRegistryVerificationTests.LockedExpiredProofAccepted;
var
  Prior, Verified: TLWPTVerifiedRegistry;
begin
  Prior := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  Verified := Verify(Proof(1), Prior.State, rvmLockedProof, '2030-01-01T00:00:00Z');
  Expect<string>(Verified.State.Snapshot).ToBe(Prior.State.Snapshot);
end;

procedure TRegistryVerificationTests.LockedProofRequiresExactState;
var
  Prior: TLWPTVerifiedRegistry;
begin
  ExpectFailure(Proof(1), 'locked_proof_requires_accepted_state',
    Default(TLWPTRegistryAcceptedState), nil, rvmLockedProof);
  Prior := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  ExpectFailure(Proof(2), 'locked_proof_state_mismatch', Prior.State, nil,
    rvmLockedProof);
end;

procedure TRegistryVerificationTests.FutureCheckpointRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(1);
  Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
    '2026-', '2027-', [rfReplaceAll]));
  ResignRoot(Candidate);
  ExpectFailure(Candidate, 'checkpoint_from_future', Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(1);
  Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
    'expires_at = "2026-01-08', 'expires_at = "2026-01-01', []));
  ResignRoot(Candidate);
  ExpectFailure(Candidate, 'invalid_registry_checkpoint', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.TamperedCheckpointRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(2);
  Candidate.Checkpoint := ReadFixture('invalid/checkpoint-2-tampered.toml');
  ExpectFailure(Candidate, 'signature_payload_mismatch', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.InvalidSignatureRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(2);
  Candidate.Signature := ReadFixture('invalid/checkpoint-2-invalid-signature.sig.toml');
  ExpectFailure(Candidate, 'signature_invalid', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.MissingRotationRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(2);
  Candidate.Rotations := nil;
  ExpectFailure(Candidate, 'rotation_chain_invalid', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.BothRotationSignaturesRequired;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(2);
  Candidate.Rotations[0].OldSignature := Candidate.Rotations[0].NewSignature;
  ExpectFailure(Candidate, 'signature_key_mismatch', Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(2);
  Candidate.Rotations[0].NewSignature := Candidate.Rotations[0].OldSignature;
  ExpectFailure(Candidate, 'signature_key_mismatch', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.ReusedRotationRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(2);
  SetLength(Candidate.Rotations, 2);
  Candidate.Rotations[1] := Candidate.Rotations[0];
  ExpectFailure(Candidate, 'rotation_chain_invalid', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.NonCanonicalProofRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(1);
  Candidate.Checkpoint := AsBytes(AsText(Candidate.Checkpoint) + #10);
  ExpectFailure(Candidate, 'non_canonical_document', Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(1);
  Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
    'sequence = 1', 'sequence = [[[[1]]]]', []));
  ExpectFailure(Candidate, 'non_canonical_document', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.LiteralStringsCannotMaskNesting;
var
  Candidate: TLWPTRegistryProof;
  Text: string;
begin
  Candidate := Proof(1);
  { Eight levels safely demonstrate the old counter bypass without a
    stack-exhaustion payload. The guard must reject before TOML parsing. }
  Text := StringReplace(AsText(Candidate.Checkpoint),
    'origin = "' + Trust.Origin + '"', 'origin = ' + #39
    + StringOfChar(']', 8) + #39, []);
  Text := StringReplace(Text, 'sequence = 1', 'sequence = '
    + StringOfChar('[', 8) + '1' + StringOfChar(']', 8), []);
  Candidate.Checkpoint := AsBytes(Text);
  ExpectFailure(Candidate, 'non_canonical_document: literal strings',
    Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.MalformedDelimitersRejectedBeforeParsing;
const
  VALUES: array[0..4] of string = (']', '[1', '[}', '"unterminated', '"""text"""');
var
  Candidate: TLWPTRegistryProof;
  Value: string;
begin
  for Value in VALUES do
  begin
    Candidate := Proof(1);
    Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
      'sequence = 1', 'sequence = ' + Value, []));
    ExpectFailure(Candidate, 'non_canonical_document: delimiters',
      Default(TLWPTRegistryAcceptedState));
  end;
end;

procedure TRegistryVerificationTests.QuotedSyntaxRemainsCanonical;
var
  Text, Actual: string;
begin
  Text := AsText(ReadFixture('records/' + Copy(ROOT_RECORD, 8, 64) + '.toml'));
  Text := StringReplace(Text, 'published_at = "2026-01-01T00:00:00Z"',
    'published_at = ' + RegistryTOMLQuote('[]{}' + #39 + '"\' + #9), []);
  Actual := '';
  try
    ParseRegistryPackage(Text, SHA256BytesPrefixed(AsBytes(Text)), Trust.Origin);
  except
    on E: ELWPTRegistryError do Actual := E.Message;
  end;
  { Canonical quoting passes; only the timestamp's domain validation fails. }
  Expect<string>(Actual).ToBe('invalid_registry_record');
end;

procedure TRegistryVerificationTests.SharedEncoderPinsEscapeBytes;
var
  Text, Actual: string;
begin
  Expect<string>(RegistryTOMLQuote('"\' + #8#9#10#12#13#0#11#27#31#127))
    .ToBe('"\"\\\b\t\n\f\r\u0000\u000b\u001b\u001f\u007f"');
  Text := AsText(ReadFixture('records/' + Copy(ROOT_RECORD, 8, 64) + '.toml'));
  Text := StringReplace(Text, 'published_at = "2026-01-01T00:00:00Z"',
    'published_at = ' + RegistryTOMLQuote(#27), []);
  Actual := '';
  try
    ParseRegistryPackage(Text, SHA256BytesPrefixed(AsBytes(Text)), Trust.Origin);
  except
    on E: ELWPTRegistryError do Actual := E.Message;
  end;
  Expect<string>(Actual).ToBe('invalid_registry_record');
end;

procedure TRegistryVerificationTests.SnapshotTamperingRejected;
var
  Source: TFixtureSource;
begin
  Source := TFixtureSource.Create;
  try
    Source.Overrides.Add('snapshots/sha256/' + Copy(ROOT_SNAPSHOT, 8, 64)
      + '.toml', AsBytes('tampered'));
    ExpectFailure(Proof(1), 'snapshot_hash_mismatch',
      Default(TLWPTRegistryAcceptedState), Source);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.MissingAncestryRejected;
var
  Source: TFixtureSource;
begin
  Source := TFixtureSource.Create;
  try
    Source.BlockPath := 'snapshots/sha256/' + Copy(ROOT_SNAPSHOT, 8, 64) + '.toml';
    ExpectFailure(Proof(2), 'state_missing', Default(TLWPTRegistryAcceptedState), Source);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.DuplicateIdentityRejected;
var
  Source: TFixtureSource;
  Candidate: TLWPTRegistryProof;
  RecordBytes, SnapshotBytes: TBytes;
  RecordHash, SnapshotHash, RecordList: string;
begin
  Candidate := Proof(1);
  Source := TFixtureSource.Create;
  try
    RecordBytes := AsBytes(StringReplace(AsText(ReadFixture('records/'
      + Copy(ROOT_RECORD, 8, 64) + '.toml')), '2026-01-01', '2026-01-02', []));
    RecordHash := SHA256BytesPrefixed(RecordBytes);
    Source.Overrides.Add('records/sha256/' + Copy(RecordHash, 8, 64)
      + '.toml', RecordBytes);
    if RecordHash < ROOT_RECORD then
      RecordList := '"' + RecordHash + '", "' + ROOT_RECORD + '"'
    else RecordList := '"' + ROOT_RECORD + '", "' + RecordHash + '"';
    SnapshotBytes := AsBytes(StringReplace(AsText(ReadFixture('snapshots/'
      + Copy(ROOT_SNAPSHOT, 8, 64) + '.toml')), '"' + ROOT_RECORD + '"',
      RecordList, []));
    SnapshotHash := SHA256BytesPrefixed(SnapshotBytes);
    Source.Overrides.Add('snapshots/sha256/' + Copy(SnapshotHash, 8, 64)
      + '.toml', SnapshotBytes);
    Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
      ROOT_SNAPSHOT, SnapshotHash, []));
    ResignRoot(Candidate);
    ExpectFailure(Candidate, 'duplicate_package_identity',
      Default(TLWPTRegistryAcceptedState), Source);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.SkippedSequenceRejected;
var
  Candidate: TLWPTRegistryProof;
begin
  Candidate := Proof(1);
  Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
    'sequence = 1', 'sequence = 2', []));
  ResignRoot(Candidate);
  ExpectFailure(Candidate, 'snapshot_consistency_failed', Default(TLWPTRegistryAcceptedState));
end;

procedure TRegistryVerificationTests.MetadataLimitsEnforced;
var
  Source: TFixtureSource;
  Limits: TLWPTRegistryVerificationLimits;
  Actual: string;
begin
  Source := TFixtureSource.Create;
  try
    Limits := DefaultRegistryVerificationLimits;
    Limits.Documents := 2;
    Actual := '';
    try
      VerifyRegistryProof(Proof(1), Trust, Default(TLWPTRegistryAcceptedState),
        EVALUATION_TIME, rvmAcquire, Source, Limits);
    except
      on E: ELWPTRegistryError do Actual := E.Message;
    end;
    Expect<Boolean>(Pos('proof_limit_exceeded', Actual) = 1).ToBe(True);
    Expect<Integer>(Source.Requested.Count).ToBe(0);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.ArchiveIdentityMatchesCache;
var
  Verified: TLWPTVerifiedRegistry;
  Hex: string;
  Archive: TBytes;
  Stream: TBytesStream;
  Index: Integer;
  Actual: string;
begin
  Verified := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  Hex := Trim(AsText(ReadFixture('objects/'
    + Copy(Verified.Packages[0].ArchiveHash, 8, 64) + '.hex')));
  SetLength(Archive, Length(Hex) div 2);
  for Index := 0 to High(Archive) do
    Archive[Index] := StrToInt('$' + Copy(Hex, Index * 2 + 1, 2));
  Stream := TBytesStream.Create(Archive);
  try
    VerifyRegistryArtifact(Verified.Packages[0], Stream);
    Expect<string>('sha256:' + SHA256Stream(Stream)).ToBe(Verified.Packages[0].ArchiveHash);
    Archive[0] := Archive[0] xor 1;
    Stream.Position := 0;
    Stream.WriteBuffer(Archive[0], Length(Archive));
    Actual := '';
    try
      VerifyRegistryArtifact(Verified.Packages[0], Stream);
    except
      on E: ELWPTRegistryError do Actual := E.Message;
    end;
    Expect<string>(Actual).ToBe('object_hash_mismatch');
  finally
    Stream.Free;
  end;
end;

procedure TRegistryVerificationTests.WrongTrustAndPriorOriginRejected;
var
  Prior: TLWPTVerifiedRegistry;
  WrongTrust: TLWPTRegistryTrust;
  Source: TFixtureSource;
  Actual: string;
begin
  Prior := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  Prior.State.Origin := 'https://other.example.test';
  ExpectFailure(Proof(1), 'invalid_accepted_state', Prior.State);
  WrongTrust := Trust;
  WrongTrust.PublicKey := 'hex:' + StringOfChar('0', 64);
  Source := TFixtureSource.Create;
  try
    Actual := '';
    try
      VerifyRegistryProof(Proof(1), WrongTrust,
        Default(TLWPTRegistryAcceptedState), EVALUATION_TIME, rvmAcquire,
        Source, DefaultRegistryVerificationLimits);
    except
      on E: ELWPTRegistryError do Actual := E.Message;
    end;
    Expect<string>(Actual).ToBe('invalid_trust_root');
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.TypedPackageFieldsRequired;
var
  Text, Actual: string;
begin
  Text := AsText(ReadFixture('records/' + Copy(ROOT_RECORD, 8, 64) + '.toml'));
  Text := StringReplace(Text, 'yanked = false', 'yanked = 0', []);
  Actual := '';
  try
    ParseRegistryPackage(Text, SHA256BytesPrefixed(AsBytes(Text)), Trust.Origin);
  except
    on E: ELWPTRegistryError do Actual := E.Message;
  end;
  Expect<Boolean>(Pos('non_canonical_document', Actual) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.RealOriginPublicationVerified;
var
  Scratch: string;
  Store: TLWPTRegistryStore;
  Source: TOriginSource;
  Config: TLWPTRegistryConfig;
  State: TLWPTRegistryState;
  Candidate: TLWPTRegistryProof;
  Pin: TLWPTRegistryTrust;
  Publication: TLWPTRegistryPublication;
  Verified: TLWPTVerifiedRegistry;
  KeyBytes: TBytes;
begin
  Scratch := CreateScratchRoot('registry-verification');
  Store := nil;
  Source := TOriginSource.Create;
  try
    Config := RegistryConfiguration('', 'http://localhost:8080',
      'localhost', 8080, '', '');
    Store := TLWPTRegistryStore.Initialize(Scratch, Config, '2026-01-01T00:00:00Z');
    Publication := Default(TLWPTRegistryPublication);
    Publication.Name := 'origin-package';
    Publication.Version := '1.0.0';
    Publication.PublishedAt := '2026-01-02T00:00:00Z';
    Publication.Archive := AsBytes('real origin artifact' + #0 + 'bytes');
    Store.Publish(Publication);
    State := Store.LoadCurrentState;
    Candidate := Default(TLWPTRegistryProof);
    Candidate.Checkpoint := Store.LoadResource(State.CheckpointPath);
    Candidate.Signature := Store.LoadResource(State.SignaturePath);
    Pin.Origin := Store.Config.Identity;
    Pin.KeyId := Field(Candidate.Checkpoint, 'key_id');
    KeyBytes := Store.LoadResource(RegistryKeyStoragePath(Pin.KeyId));
    Pin.PublicKey := Field(KeyBytes, 'public_key');
    Source.Store := Store;
    Verified := VerifyRegistryProof(Candidate, Pin,
      Default(TLWPTRegistryAcceptedState), EVALUATION_TIME, rvmAcquire,
      Source, DefaultRegistryVerificationLimits);
    Expect<Integer>(Length(Verified.Packages)).ToBe(1);
    Expect<string>(Verified.Packages[0].ArchiveHash).ToBe(
      SHA256BytesPrefixed(Publication.Archive));
    Expect<string>(Verified.State.Origin).ToBe('http://localhost:8080');
  finally
    Source.Free;
    Store.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.NumericPreviousRejected;
var
  Source: TFixtureSource;
  Candidate: TLWPTRegistryProof;
  SnapshotBytes: TBytes;
  SnapshotHash: string;
begin
  Candidate := Proof(1);
  Source := TFixtureSource.Create;
  try
    SnapshotBytes := AsBytes(StringReplace(AsText(ReadFixture('snapshots/'
      + Copy(ROOT_SNAPSHOT, 8, 64) + '.toml')), 'previous = ""',
      'previous = 0', []));
    SnapshotHash := SHA256BytesPrefixed(SnapshotBytes);
    Source.Overrides.Add('snapshots/sha256/' + Copy(SnapshotHash, 8, 64)
      + '.toml', SnapshotBytes);
    Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
      ROOT_SNAPSHOT, SnapshotHash, []));
    ResignRoot(Candidate);
    ExpectFailure(Candidate, 'non_canonical_document',
      Default(TLWPTRegistryAcceptedState), Source);
  finally
    Source.Free;
  end;
end;

procedure TRegistryVerificationTests.LockedCheckpointSubstitutionRejected;
var
  Prior: TLWPTVerifiedRegistry;
  Candidate: TLWPTRegistryProof;
begin
  Prior := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(1);
  Candidate.Checkpoint := AsBytes(StringReplace(AsText(Candidate.Checkpoint),
    'expires_at = "2026-01-08', 'expires_at = "2026-01-09', []));
  ResignRoot(Candidate);
  ExpectFailure(Candidate, 'locked_proof_state_mismatch', Prior.State,
    nil, rvmLockedProof);
  Verify(Candidate, Prior.State);
end;

procedure TRegistryVerificationTests.DowngradeRejected;
var
  Prior: TLWPTVerifiedRegistry;
begin
  Prior := Verify(Proof(2), Default(TLWPTRegistryAcceptedState));
  ExpectFailure(Proof(1), 'checkpoint_downgrade', Prior.State);
end;

procedure TRegistryVerificationTests.EqualSequenceEquivocationRejected;
var
  Prior: TLWPTVerifiedRegistry;
  Candidate: TLWPTRegistryProof;
begin
  Prior := Verify(Proof(2), Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(2);
  Candidate.Checkpoint := ReadFixture('invalid/checkpoint-2-equivocation.toml');
  Candidate.Signature := ReadFixture('invalid/checkpoint-2-equivocation.sig.toml');
  ExpectFailure(Candidate, 'checkpoint_equivocation', Prior.State);
end;

procedure TRegistryVerificationTests.PinnedKeyDocumentValidated;
var
  Original, Candidate: string;
  Rejected: Boolean;
  Index: Integer;
begin
  Original := AsText(ReadFixture('keys/root.toml'));
  ValidateRegistryKeyDocument(AsBytes(Original), Trust, 1);
  ValidateRegistryKeyDocument(AsBytes(StringReplace(Original,
    'valid_from_sequence = 1', 'valid_from_sequence = 2', [])), Trust, 2);
  for Index := 0 to 5 do
  begin
    case Index of
      0: Candidate := StringReplace(Original, Trust.Origin, 'https://wrong.example', []);
      1: Candidate := StringReplace(Original, Trust.KeyId, 'ed25519:' + StringOfChar('0', 64), []);
      2: Candidate := StringReplace(Original, Trust.PublicKey, 'hex:' + StringOfChar('0', 64), []);
      3: Candidate := StringReplace(Original, 'valid_from_sequence = 1', 'valid_from_sequence = 0', []);
      4: Candidate := StringReplace(Original, 'valid_from_sequence = 1', 'valid_from_sequence = 2', []);
      5: Candidate := StringReplace(Original, 'valid_from_sequence = 1', 'valid_from_sequence = "1"', []);
    end;
    Rejected := False;
    try
      ValidateRegistryKeyDocument(AsBytes(Candidate), Trust, 1);
    except
      on E: ELWPTRegistryError do Rejected := True;
    end;
    Expect<Boolean>(Rejected).ToBe(True);
  end;
end;

procedure TRegistryVerificationTests.RotationPagesAreBoundedAndCanonical;
var
  Original, Candidate: string;
  Page: TLWPTRegistryRotationPage;
  Index, Maximum: Integer;
  AfterSequence: Int64;
  Rejected: Boolean;
begin
  Original := AsText(ReadFixture('pages/rotations.toml'));
  Page := ParseRegistryRotationPage(AsBytes(Original), Trust.Origin, Trust.Origin + '/v1', 0, 1);
  Expect<Integer>(Length(Page.Items)).ToBe(1);
  Expect<Int64>(Page.Items[0].EffectiveSequence).ToBe(2);
  Expect<string>(RegistryQueryEncode('a b&%=/')).ToBe('a%20b%26%25%3D%2F');
  for Index := 0 to 7 do
  begin
    Candidate := Original;
    Maximum := 1;
    AfterSequence := 0;
    case Index of
      0: Maximum := 0;
      1: AfterSequence := 2;
      2: Candidate := StringReplace(Original, 'origin = "' + Trust.Origin,
        'origin = "https://wrong.example', []);
      3: Candidate := StringReplace(Original, '/v1/rotations/2.toml', '/v1/rotations/3.toml', []);
      4: Candidate := StringReplace(Original, 'effective_sequence = 2', 'effective_sequence = "2"', []);
      5: Candidate := StringReplace(Original, 'next_cursor = ""',
        'next_cursor = "' + StringOfChar('x', 1025) + '"', []);
      6: Candidate := Copy(Original, 1, Pos('items =', Original) - 1)
        + 'items = []' + #10 + 'next_cursor = "again"' + #10;
      7: Candidate := StringReplace(Original, '{ effective_sequence', '{ extra = 1, effective_sequence', []);
    end;
    Rejected := False;
    try
      ParseRegistryRotationPage(AsBytes(Candidate), Trust.Origin, Trust.Origin + '/v1', AfterSequence, Maximum);
    except
      on E: ELWPTRegistryError do Rejected := True;
    end;
    Expect<Boolean>(Rejected).ToBe(True);
  end;
end;

procedure TRegistryVerificationTests.RetrievalDocumentsShareProofBudget;
var
  Candidate: TLWPTRegistryProof;
  Rotation: TLWPTRegistryRotationProof;
  Limits: TLWPTRegistryVerificationLimits;
  Source: TFixtureSource;
  Budget: TLWPTRegistryMetadataBudget;
  Diagnostic: string;
  procedure Count(const ABytes: TBytes);
  begin
    Inc(Limits.TotalBytes, Length(ABytes));
    if Length(ABytes) > Limits.DocumentBytes then Limits.DocumentBytes := Length(ABytes);
  end;
begin
  Candidate := Proof(2);
  Limits := DefaultRegistryVerificationLimits;
  Limits.TotalBytes := 15;
  Limits.DocumentBytes := 16;
  Count(Candidate.Checkpoint);
  Count(Candidate.Signature);
  for Rotation in Candidate.Rotations do
  begin
    Count(Rotation.Document);
    Count(Rotation.OldSignature);
    Count(Rotation.NewSignature);
  end;
  SetLength(Candidate.RetrievalDocuments, 1);
  Candidate.RetrievalDocuments[0] := AsBytes(StringOfChar('p', 16));
  Source := TFixtureSource.Create;
  try
    Diagnostic := '';
    try
      VerifyRegistryProof(Candidate, Trust, Default(TLWPTRegistryAcceptedState),
        EVALUATION_TIME, rvmAcquire, Source, Limits);
    except
      on E: ELWPTRegistryError do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('proof_limit_exceeded:', Diagnostic) = 1).ToBe(True);
    Expect<Integer>(Source.Requested.Count).ToBe(0);
  finally
    Source.Free;
  end;
  Limits.DocumentBytes := 4;
  Limits.TotalBytes := 8;
  Limits.Documents := 2;
  Budget := TLWPTRegistryMetadataBudget.Create(Limits);
  try
    Expect<Int64>(Budget.Allowance).ToBe(4);
    Budget.Account(AsBytes('page'));
    Budget.Account(AsBytes('keys'));
    Diagnostic := '';
    try
      Budget.Allowance;
    except
      on E: ELWPTRegistryError do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('proof_limit_exceeded:', Diagnostic) = 1).ToBe(True);
  finally
    Budget.Free;
  end;
end;

procedure TRegistryVerificationTests.SetupTests;
begin
  Test('rotation pages enforce item counts, order, scope and canonical fields', RotationPagesAreBoundedAndCanonical);
  Test('retrieval pages and key documents share signed-proof aggregate limits', RetrievalDocumentsShareProofBudget);
  Test('read views verify once and retain captured membership without a global cache', MirrorReadViewReusesCapturedProof);
  Test('key documents retain canonical bytes and match immutable trust and sequence', PinnedKeyDocumentValidated);
  Test('bootstrap and yank/restore corpus verifies', CorpusBootstrapAndLifecycle);
  Test('anchored history returns a complete offline bundle', AnchoredHistoryAndCompleteBundle);
  Test('conflicting previously accepted history fails', ConflictingHistoryRejected);
  Test('acquisition rejects expiry at the exact boundary', ExpiredAcquisitionRejected);
  Test('locked proof permits later checkpoint expiry', LockedExpiredProofAccepted);
  Test('locked proof requires the exact recorded state', LockedProofRequiresExactState);
  Test('acquisition rejects a correctly signed future checkpoint', FutureCheckpointRejected);
  Test('checkpoint tampering fails payload binding', TamperedCheckpointRejected);
  Test('cryptographically invalid signatures fail', InvalidSignatureRejected);
  Test('unknown checkpoint key requires verified rotation', MissingRotationRejected);
  Test('both rotation signatures are mandatory', BothRotationSignaturesRequired);
  Test('reused rotation fails closed', ReusedRotationRejected);
  Test('noncanonical and deeply nested proofs fail', NonCanonicalProofRejected);
  Test('literal strings cannot mask parser nesting', LiteralStringsCannotMaskNesting);
  Test('malformed delimiters fail before TOML parsing', MalformedDelimitersRejectedBeforeParsing);
  Test('quoted brackets apostrophes and escapes remain canonical', QuotedSyntaxRemainsCanonical);
  Test('shared encoder pins canonical escape bytes', SharedEncoderPinsEscapeBytes);
  Test('snapshot byte tampering fails', SnapshotTamperingRejected);
  Test('missing ancestry fails', MissingAncestryRejected);
  Test('signed snapshot cannot include duplicate package identity', DuplicateIdentityRejected);
  Test('signed checkpoint cannot skip snapshot sequence', SkippedSequenceRejected);
  Test('metadata budget stops additional provider reads', MetadataLimitsEnforced);
  Test('artifact proof binds the cache raw-byte digest', ArchiveIdentityMatchesCache);
  Test('pin mismatch and foreign prior state fail', WrongTrustAndPriorOriginRejected);
  Test('package booleans cannot be replaced by integers', TypedPackageFieldsRequired);
  Test('real origin publication verifies with localhost identity', RealOriginPublicationVerified);
  Test('snapshot previous hash cannot be an integer', NumericPreviousRejected);
  Test('locked checkpoint bytes cannot be substituted by renewal', LockedCheckpointSubstitutionRejected);
  Test('authenticated lower sequence is rejected', DowngradeRejected);
  Test('authenticated same-sequence equivocation is rejected', EqualSequenceEquivocationRejected);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryVerificationTests.Create('registry verification'));
  TestRunnerProgram.Run;
end.
