program LWPT.Registry.Verification.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads, { The real origin store uses the native producer-lease thread driver. }
  {$ENDIF}
  Classes,
  Generics.Collections,
  StrUtils,
  SysUtils,

  TestingPascalLibrary,
  TOML,

  LWPT.Core,
  LWPT.Registry.Crypto,
  LWPT.Registry.Mirror,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  Tests.Scratch;

const
  FIXTURE_ROOT = 'tests/fixtures/registry/v1/';
  EVALUATION_TIME = '2026-01-06T00:00:00Z';
  ROOT_SNAPSHOT = 'sha256:d2dde0cae212bc793c9a312e55198c65167876aa0722f8cfcbf2f38a5bf5796b';
  ROOT_RECORD = 'sha256:6b464cebeb83b982d076b52f4152b05623fa410fef78c0ce159422097eff4948';

type
  TMirrorFixtureStore = class(TLWPTRegistryMirror)
  public
    procedure Retain(const AVerified: TLWPTVerifiedRegistry;
      const ALastSync: string = EVALUATION_TIME);
    procedure RetainArchives(const AVerified: TLWPTVerifiedRegistry);
    procedure Put(const APath: string; const ABytes: TBytes);
    procedure Corrupt(const APath: string);
    function StatePath: string;
  end;

  TMirrorRequestThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Mirror: TLWPTRegistryMirror;
    Status: Integer;
    Error: string;
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
    procedure UnknownRoutesSkipProofVerification;
    procedure ConcurrentRequestsShareOneVerification;
    procedure ServedBytesMatchAuthenticatedDigests;
    procedure UnacceptedRecordsAndObjectsStayHidden;
    procedure StrayRotationFilesDoNotJoinTheChain;
    procedure BackwardsRenewalRejected;
    procedure QuotedHashIsNotAComment;
    procedure InvalidUTF8Rejected;
    procedure DottedKeyNestingRejected;
    procedure StaleContactFailuresAreDistinguished;
    procedure RotationStepVerifiesBothSignatures;
    procedure ExpiredEquivocationIsTrustFailure;
    procedure OlderKeyCheckpointIsStaleDowngrade;
    procedure InconsistentDowngradeIsEquivocation;
    procedure UninitializedMirrorServesNothing;
    procedure CountArrival;
    procedure HoldBuildUntilAllArrive;
    procedure PauseFirstReader;
    procedure DelayedReaderKeepsNewerGeneration;
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

procedure TMirrorFixtureStore.Retain(const AVerified: TLWPTVerifiedRegistry;
  const ALastSync: string);
var
  Keys: array of TBytes;
  Index: Integer;
begin
  SetLength(Keys, Length(AVerified.Proof.Rotations) + 1);
  Keys[0] := ReadFixture('keys/root.toml');
  for Index := 1 to High(Keys) do Keys[Index] := ReadFixture('keys/rotated.toml');
  RegistryMirrorRetainForTesting(Self, AVerified, Keys, ALastSync);
end;

procedure TMirrorFixtureStore.RetainArchives(const AVerified: TLWPTVerifiedRegistry);
var
  Package: TLWPTRegistryPackage;
  Hex, Digest: string;
  Archive: TBytes;
  Index: Integer;
begin
  for Package in AVerified.Packages do
  begin
    Digest := Copy(Package.ArchiveHash, 8, 64);
    Hex := Trim(AsText(ReadFixture('objects/' + Digest + '.hex')));
    SetLength(Archive, Length(Hex) div 2);
    for Index := 0 to High(Archive) do
      Archive[Index] := StrToInt('$' + Copy(Hex, Index * 2 + 1, 2));
    WriteImmutable('objects/sha256/' + Digest, Archive);
  end;
end;

procedure TMirrorFixtureStore.Put(const APath: string; const ABytes: TBytes);
begin
  WriteImmutable(APath, ABytes);
end;

procedure TMirrorFixtureStore.Corrupt(const APath: string);
begin
  AtomicWriteBytes(RootPath(APath), TmpRoot, BytesOf('tampered'));
end;

function TMirrorFixtureStore.StatePath: string;
begin
  Result := ReadCurrentState.CheckpointPath;
end;


function NewFixtureMirror(const AScratch: string; const ATrust: TLWPTRegistryTrust): TMirrorFixtureStore;
var
  Config: TLWPTRegistryConfig;
begin
  Config := RegistryConfiguration(ATrust.Origin, 'http://localhost:8181', 'localhost', 8181, '', '');
  Config.Role := rrMirror;
  Config.UpstreamURL := ATrust.Origin;
  Config.TrustKeyID := ATrust.KeyId;
  Config.TrustPublicKey := ATrust.PublicKey;
  Result := TMirrorFixtureStore(TMirrorFixtureStore.Initialize(AScratch, Config, EVALUATION_TIME));
end;

procedure ResignRoot(var AProof: TLWPTRegistryProof); forward;

procedure TRegistryVerificationTests.MirrorReadViewReusesCapturedProof;
var
  Scratch, Path: string;
  Mirror: TMirrorFixtureStore;
  View: TLWPTRegistryReadView;
  First, Latest: TLWPTVerifiedRegistry;
  Before: Integer;
  Paths: TStringList;
begin
  Scratch := CreateScratchRoot('registry-read-view');
  Mirror := nil;
  View := nil;
  Paths := TStringList.Create;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    First := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
    Latest := Verify(Proof(5), First.State);
    Mirror.Retain(First);
    Before := RegistryMirrorProofChecksForTesting;
    View := Mirror.CaptureReadView;
    Mirror.Retain(Latest);
    { A captured view keeps its own generation after activation. }
    Expect<Boolean>(View.ResourceIsPublished('rotations/2.toml')).ToBe(False);
    Expect<Boolean>(View.ResourceIsPublished('snapshots/sha256/' + Copy(Latest.State.Snapshot, 8, 64) + '.toml')).ToBe(False);
    Expect<Boolean>(View.ResourceIsPublished('snapshots/sha256/' + Copy(First.State.Snapshot, 8, 64) + '.toml')).ToBe(True);
    Expect<Boolean>(View.ResourceIsPublished('snapshots/sha256/' + UpperCase(Copy(First.State.Snapshot, 8, 64)) + '.toml')).ToBe(False);
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
    FreeAndNil(View);
    Paths.Add('/v1/keys/' + Trust.KeyId + '.toml');
    Paths.Add('/v1/keys/' + Latest.State.KeyId + '.toml');
    Paths.Add('/v1/rotations/2.toml');
    Paths.Add('/v1/rotations/2.old.sig.toml');
    Paths.Add('/v1/rotations?after=0&limit=1');
    Paths.Add('/v1/snapshots/sha256/' + Copy(Latest.State.Snapshot, 8, 64) + '.toml');
    { The new accepted state is verified once, then shared by every request. }
    Before := RegistryMirrorProofChecksForTesting;
    for Path in Paths do
      Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', Path).Status).ToBe(200);
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/rotations/2.OLD.SIG.TOML').Status).ToBe(404);
  finally
    Paths.Free;
    View.Free;
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.UnknownRoutesSkipProofVerification;
const
  Targets: array[0..10] of string = ('/v1/not-found', '/v1/objects/sha256/zz',
    '/v1/rotations/1.toml', '/v1/rotations/x.toml', '/v1/rotations/02.toml',
    '/v1/records/sha256/abc.toml', '/v1/checkpoints/latest',
    '/v1/checkpoints/garbage.toml', '/v1/checkpoints/01.toml',
    '/v1/checkpoints/renewals/sha256/abc.toml', '/v1/checkpoints/1.old.toml');
var
  Scratch, Target: string;
  Mirror: TMirrorFixtureStore;
  Before: Integer;
begin
  Scratch := CreateScratchRoot('registry-unknown-route');
  Mirror := nil;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    Mirror.Retain(Verify(Proof(1), Default(TLWPTRegistryAcceptedState)));
    Before := RegistryMirrorProofChecksForTesting;
    for Target in Targets do
      Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', Target).Status).ToBe(404);
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(0);
  finally
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

var
  GenerationArrivals, GenerationStart, DelayedReaderPaused, DelayedReaderRelease,
    DelayedReaderClaimed: LongInt;

procedure WaitForValue(var AValue: LongInt; const ATarget: LongInt);
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (InterlockedCompareExchange(AValue, 0, 0) < ATarget)
    and (GetTickCount64 - Started < 5000) do Sleep(1);
end;

procedure TMirrorRequestThread.Execute;
begin
  try
    WaitForValue(GenerationStart, 1);
    Status := RegistryHTTPResponse(Mirror, 'GET', '/v1/checkpoints/latest.toml').Status;
  except
    on E: Exception do Error := E.Message;
  end;
end;

procedure TRegistryVerificationTests.CountArrival;
begin
  InterlockedIncrement(GenerationArrivals);
end;

procedure TRegistryVerificationTests.HoldBuildUntilAllArrive;
begin
  { The first builder waits inside the lock until every reader is queued. }
  WaitForValue(GenerationArrivals, 8);
end;

procedure TRegistryVerificationTests.ConcurrentRequestsShareOneVerification;
const
  RequestCount = 8;
var
  Scratch: string;
  Mirror: TMirrorFixtureStore;
  Threads: array[0..RequestCount - 1] of TMirrorRequestThread;
  Before, Index: Integer;
  Verified: TLWPTVerifiedRegistry;
begin
  Scratch := CreateScratchRoot('registry-concurrent-view');
  Mirror := nil;
  FillChar(Threads, SizeOf(Threads), 0);
  GenerationArrivals := 0;
  GenerationStart := 0;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    Verified := Verify(Proof(5), Default(TLWPTRegistryAcceptedState));
    Mirror.Retain(Verified);
    { The cache is cold: no request has built this generation yet. }
    RegistryMirrorGenerationHooksForTesting(Mirror, CountArrival, HoldBuildUntilAllArrive);
    Before := RegistryMirrorProofChecksForTesting;
    for Index := 0 to RequestCount - 1 do
    begin
      Threads[Index] := TMirrorRequestThread.Create(True);
      Threads[Index].FreeOnTerminate := False;
      Threads[Index].Mirror := Mirror;
      Threads[Index].Start;
    end;
    InterlockedExchange(GenerationStart, 1);
    for Index := 0 to RequestCount - 1 do
    begin
      Threads[Index].WaitFor;
      Expect<string>(Threads[Index].Error).ToBe('');
      Expect<Integer>(Threads[Index].Status).ToBe(200);
    end;
    Expect<Integer>(InterlockedCompareExchange(GenerationArrivals, 0, 0)).ToBe(RequestCount);
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
  finally
    InterlockedExchange(GenerationStart, 1);
    for Index := 0 to RequestCount - 1 do Threads[Index].Free;
    if Mirror <> nil then RegistryMirrorGenerationHooksForTesting(Mirror, nil, nil);
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.PauseFirstReader;
begin
  if InterlockedCompareExchange(DelayedReaderClaimed, 1, 0) <> 0 then Exit;
  InterlockedExchange(DelayedReaderPaused, 1);
  WaitForValue(DelayedReaderRelease, 1);
end;

procedure TRegistryVerificationTests.DelayedReaderKeepsNewerGeneration;
var
  Scratch: string;
  Mirror: TMirrorFixtureStore;
  Delayed: TMirrorRequestThread;
  Verified: TLWPTVerifiedRegistry;
  Before: Integer;
begin
  Scratch := CreateScratchRoot('registry-delayed-reader');
  Mirror := nil;
  Delayed := nil;
  DelayedReaderPaused := 0;
  DelayedReaderRelease := 0;
  DelayedReaderClaimed := 0;
  GenerationStart := 1;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    Verified := Verify(Proof(5), Default(TLWPTRegistryAcceptedState));
    Mirror.Retain(Verified);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/checkpoints/latest.toml').Status).ToBe(200);
    RegistryMirrorGenerationHooksForTesting(Mirror, PauseFirstReader, nil);
    Before := RegistryMirrorProofChecksForTesting;
    Delayed := TMirrorRequestThread.Create(True);
    Delayed.FreeOnTerminate := False;
    Delayed.Mirror := Mirror;
    Delayed.Start;
    WaitForValue(DelayedReaderPaused, 1);
    Expect<Integer>(DelayedReaderPaused).ToBe(1);
    { A newer pointer is activated and served while the first reader waits. }
    Mirror.Retain(Verified, '2026-01-07T00:00:00Z');
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/checkpoints/latest.toml').Status).ToBe(200);
    InterlockedExchange(DelayedReaderRelease, 1);
    Delayed.WaitFor;
    Expect<string>(Delayed.Error).ToBe('');
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/checkpoints/latest.toml').Status).ToBe(200);
    { Only the newer generation was ever built; nothing rebuilt it. }
    Expect<Integer>(RegistryMirrorProofChecksForTesting - Before).ToBe(1);
  finally
    InterlockedExchange(DelayedReaderRelease, 1);
    Delayed.Free;
    if Mirror <> nil then RegistryMirrorGenerationHooksForTesting(Mirror, nil, nil);
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.ServedBytesMatchAuthenticatedDigests;
const
  Targets: array[0..1] of string = ('/v1/checkpoints/latest.toml',
    '/v1/rotations/2.old.sig.toml');
var
  Scratch, Diagnostic: string;
  Mirror: TMirrorFixtureStore;
  Verified: TLWPTVerifiedRegistry;
  Response: TLWPTRegistryHTTPResponse;
  Stream: TStream;
  Target: string;
begin
  Scratch := CreateScratchRoot('registry-served-digest');
  Mirror := nil;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    Verified := Verify(Proof(5), Default(TLWPTRegistryAcceptedState));
    Mirror.Retain(Verified);
    Response := RegistryHTTPResponse(Mirror, 'GET', '/v1/checkpoints/latest.toml');
    Expect<string>(Response.ResourceDigest).ToBe(Verified.State.CheckpointHash);
    { Replace verified bytes after the generation was authenticated. }
    Mirror.Corrupt(Mirror.StatePath);
    for Target in Targets do
    begin
      if Target = '/v1/rotations/2.old.sig.toml' then
        Mirror.Corrupt('proofs/sha256/' + Copy(SHA256BytesPrefixed(
          Verified.Proof.Rotations[0].OldSignature), 8, 64) + '.toml');
      Response := RegistryHTTPResponse(Mirror, 'GET', Target);
      Expect<Integer>(Response.Status).ToBe(200);
      Diagnostic := '';
      Stream := nil;
      try
        Stream := OpenRegistryHTTPResource(Response);
      except
        on E: ELWPTRegistryError do Diagnostic := E.Message;
      end;
      Stream.Free;
      Expect<Boolean>(Pos('resource_hash_mismatch:', Diagnostic) = 1).ToBe(True);
    end;
    Expect<Boolean>(Response.ResourceDigest = SHA256BytesPrefixed(BytesOf('tampered'))).ToBe(False);
  finally
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.UnacceptedRecordsAndObjectsStayHidden;
var
  Scratch, Stray: string;
  Mirror: TMirrorFixtureStore;
  Verified: TLWPTVerifiedRegistry;
begin
  Scratch := CreateScratchRoot('registry-unaccepted');
  Mirror := nil;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    Verified := Verify(Proof(1), Default(TLWPTRegistryAcceptedState));
    Mirror.Retain(Verified);
    Mirror.RetainArchives(Verified);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/objects/sha256/'
      + Copy(Verified.Packages[0].ArchiveHash, 8, 64)).Status).ToBe(200);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/records/sha256/'
      + Copy(ROOT_RECORD, 8, 64) + '.toml').Status).ToBe(200);
    Stray := SHA256Hex(BytesOf('unaccepted candidate'));
    Mirror.Put('objects/sha256/' + Stray, BytesOf('unaccepted candidate'));
    Mirror.Put('records/sha256/' + Stray + '.toml', BytesOf('unaccepted candidate'));
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/objects/sha256/' + Stray).Status).ToBe(404);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/records/sha256/' + Stray + '.toml').Status).ToBe(404);
  finally
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.StrayRotationFilesDoNotJoinTheChain;
const
  Suffixes: array[0..2] of string = ('.toml', '.old.sig.toml', '.new.sig.toml');
var
  Scratch, Suffix: string;
  Mirror: TMirrorFixtureStore;
  Alternative: TLWPTRegistryProof;
  Verified: TLWPTVerifiedRegistry;
  View: TLWPTRegistryReadView;
begin
  Scratch := CreateScratchRoot('registry-stray-rotation');
  Mirror := nil;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    { An accepted root-signed sequence 3 that never rotated. }
    Alternative := Proof(3);
    Alternative.Rotations := nil;
    Alternative.Checkpoint := BytesOf(StringReplace(AsText(Alternative.Checkpoint),
      Field(Alternative.Checkpoint, 'key_id'), Trust.KeyId, []));
    ResignRoot(Alternative);
    Verified := Verify(Alternative, Default(TLWPTRegistryAcceptedState));
    Mirror.Retain(Verified);
    Mirror.RetainArchives(Verified);
    { An abandoned candidate left a valid rotation at an earlier sequence,
      in both the numeric and the content-addressed layouts. }
    for Suffix in Suffixes do
    begin
      Mirror.Put('rotations/2' + Suffix, ReadFixture('rotations/2' + Suffix));
      Mirror.Put('proofs/sha256/' + Copy(SHA256BytesPrefixed(ReadFixture('rotations/2'
        + Suffix)), 8, 64) + '.toml', ReadFixture('rotations/2' + Suffix));
    end;
    View := Mirror.CaptureReadView;
    try
      Expect<Integer>(View.RotationSequences.Count).ToBe(0);
    finally
      View.Free;
    end;
    Expect<Boolean>(Pos('sequence = 3', Mirror.VerifyMirror) > 0).ToBe(True);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/rotations/2.toml').Status).ToBe(404);
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/checkpoints/latest.toml').Status).ToBe(200);
  finally
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

function Renewed(const APublishedDay, AExpiresDay: string): TLWPTRegistryProof;
var
  Text: string;
begin
  Result := Default(TLWPTRegistryProof);
  Text := AsText(ReadFixture('checkpoints/1.toml'));
  Text := StringReplace(Text, 'published_at = "2026-01-01', 'published_at = "2026-01-' + APublishedDay, []);
  Text := StringReplace(Text, 'expires_at = "2026-01-08', 'expires_at = "2026-01-' + AExpiresDay, []);
  Result.Checkpoint := BytesOf(Text);
  ResignRoot(Result);
end;

procedure TRegistryVerificationTests.BackwardsRenewalRejected;
var
  Newer, Replayed, Forward: TLWPTVerifiedRegistry;
  Actual: string;
  Stale: Boolean;
begin
  Newer := Verify(Renewed('05', '12'), Default(TLWPTRegistryAcceptedState));
  { Exact replay of the accepted renewal is idempotent. }
  Replayed := Verify(Renewed('05', '12'), Newer.State);
  Expect<string>(Replayed.State.CheckpointHash).ToBe(Newer.State.CheckpointHash);
  Forward := Verify(Renewed('05', '13'), Newer.State);
  Expect<string>(Forward.ExpiresAt).ToBe('2026-01-13T00:00:00Z');
  ExpectFailure(Proof(1), 'checkpoint_renewal_rollback:', Newer.State);
  ExpectFailure(Renewed('04', '12'), 'checkpoint_renewal_rollback:', Newer.State);
  Actual := '';
  Stale := False;
  try
    Verify(Renewed('05', '11'), Newer.State);
  except
    on E: ELWPTRegistryStaleContactError do
    begin
      Actual := E.Message;
      Stale := True;
    end;
  end;
  Expect<Boolean>(Stale).ToBe(True);
  Expect<Boolean>(Pos('checkpoint_renewal_rollback:', Actual) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.QuotedHashIsNotAComment;
var
  Original: string;
  Page: TLWPTRegistryRotationPage;
  Diagnostic: string;
begin
  Original := AsText(ReadFixture('pages/rotations.toml'));
  Page := ParseRegistryRotationPage(BytesOf(StringReplace(Original,
    'next_cursor = ""', 'next_cursor = "page#2"', [])), Trust.Origin,
    Trust.Origin + '/v1', 0, 100);
  Expect<string>(Page.NextCursor).ToBe('page#2');
  Diagnostic := '';
  try
    ParseRegistryRotationPage(BytesOf(StringReplace(Original,
      'next_cursor = ""', 'next_cursor = "" # page', [])), Trust.Origin,
      Trust.Origin + '/v1', 0, 100);
  except
    on E: ELWPTRegistryError do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('non_canonical_document: comments', Diagnostic) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.InvalidUTF8Rejected;
const
  Invalid: array[0..6] of string = (#$C0#$AF, #$E0#$80#$AF, #$C3, #$E2#$82,
    #$80, #$ED#$A0#$80, #$F4#$90#$80#$80);
  Valid: array[0..2] of string = (#$C3#$A9, #$E2#$82#$AC, #$F0#$9F#$98#$80);
var
  Original, Value, Diagnostic: string;
begin
  Original := AsText(ReadFixture('pages/rotations.toml'));
  for Value in Valid do
    Expect<string>(ParseRegistryRotationPage(BytesOf(StringReplace(Original,
      'next_cursor = ""', 'next_cursor = "a' + Value + 'b"', [])), Trust.Origin,
      Trust.Origin + '/v1', 0, 100).NextCursor).ToBe('a' + Value + 'b');
  for Value in Invalid do
  begin
    Diagnostic := '';
    try
      ParseRegistryRotationPage(BytesOf(StringReplace(Original,
        'next_cursor = ""', 'next_cursor = "a' + Value + 'b"', [])), Trust.Origin,
        Trust.Origin + '/v1', 0, 100);
    except
      on E: ELWPTRegistryError do Diagnostic := E.Message;
    end;
    Expect<string>(Diagnostic).ToBe('non_canonical_document: invalid UTF-8');
  end;
end;

procedure TRegistryVerificationTests.DottedKeyNestingRejected;
var
  Keys, Document, Diagnostic: string;
  Index: Integer;
begin
  Keys := 'a';
  for Index := 2 to 100000 do Keys := Keys + '.a';
  Document := AsText(ReadFixture('discovery-origin.toml'));
  Document := Copy(Document, 1, Pos('api = ', Document) - 1) + 'api = { ' + Keys
    + ' = 0 }' + Copy(Document, PosEx(#10, Document, Pos('api = ', Document)), MaxInt);
  Diagnostic := '';
  try
    ParseRegistryDiscovery(Document);
  except
    on E: ELWPTRegistryError do Diagnostic := E.Message;
  end;
  Expect<string>(Diagnostic).ToBe('non_canonical_document: nesting');
end;

procedure TRegistryVerificationTests.StaleContactFailuresAreDistinguished;
var
  Prior: TLWPTVerifiedRegistry;
  Candidate: TLWPTRegistryProof;

  function StaleFailure(const AProof: TLWPTRegistryProof;
    const APrior: TLWPTRegistryAcceptedState; const ATime: string): string;
  begin
    Result := 'accepted';
    try
      Verify(AProof, APrior, rvmAcquire, ATime);
    except
      on E: ELWPTRegistryStaleContactError do Result := 'stale';
      on E: ELWPTRegistryError do Result := 'trust';
    end;
  end;
begin
  Prior := Verify(Proof(2), Default(TLWPTRegistryAcceptedState));
  Expect<string>(StaleFailure(Proof(1), Default(TLWPTRegistryAcceptedState),
    '2026-01-08T00:00:00Z')).ToBe('stale');
  Expect<string>(StaleFailure(Proof(1), Prior.State, EVALUATION_TIME)).ToBe('stale');
  Candidate := Proof(2);
  Candidate.Signature := ReadFixture('invalid/checkpoint-2-invalid-signature.sig.toml');
  Expect<string>(StaleFailure(Candidate, Default(TLWPTRegistryAcceptedState),
    EVALUATION_TIME)).ToBe('trust');
  Candidate := Proof(2);
  Candidate.Checkpoint := ReadFixture('invalid/checkpoint-2-equivocation.toml');
  Candidate.Signature := ReadFixture('invalid/checkpoint-2-equivocation.sig.toml');
  Expect<string>(StaleFailure(Candidate, Prior.State, EVALUATION_TIME)).ToBe('trust');
end;

procedure TRegistryVerificationTests.RotationStepVerifiesBothSignatures;
var
  Rotation: TLWPTRegistryRotationProof;
  Accepted: TLWPTUntrustedRegistryRotation;
  Diagnostic, Forged: string;
begin
  Rotation := Proof(2).Rotations[0];
  Accepted := VerifyRegistryRotation(Rotation, Trust.Origin, Trust.KeyId,
    Trust.PublicKey, 1, 2);
  Expect<Int64>(Accepted.EffectiveSequence).ToBe(2);
  Forged := AsText(Rotation.OldSignature);
  Forged := Copy(Forged, 1, Pos('signature = "hex:', Forged) + 16)
    + StringOfChar('0', 128) + '"' + #10;
  Rotation.OldSignature := BytesOf(Forged);
  Diagnostic := '';
  try
    VerifyRegistryRotation(Rotation, Trust.Origin, Trust.KeyId, Trust.PublicKey, 1, 2);
  except
    on E: ELWPTRegistryError do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('signature_invalid:', Diagnostic) = 1).ToBe(True);
  Rotation := Proof(2).Rotations[0];
  Diagnostic := '';
  try
    VerifyRegistryRotation(Rotation, Trust.Origin, Trust.KeyId, Trust.PublicKey, 2, 2);
  except
    on E: ELWPTRegistryError do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('rotation_chain_invalid:', Diagnostic) = 1).ToBe(True);
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
  Ed25519Sign(BytesOf(PROJECT_NAME + '-REGISTRY-CHECKPOINT-V1' + #10
    + AsText(AProof.Checkpoint)), Seed, Signature);
  AProof.Signature := BytesOf('schema = "' + PROGRAM_NAME
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
  Expect<Boolean>(Pos('checkpoint_expired:', Actual) = 1).ToBe(True);
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
  Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
    '2026-', '2027-', [rfReplaceAll]));
  ResignRoot(Candidate);
  ExpectFailure(Candidate, 'checkpoint_from_future', Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(1);
  Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
  Candidate.Checkpoint := BytesOf(AsText(Candidate.Checkpoint) + #10);
  ExpectFailure(Candidate, 'non_canonical_document', Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(1);
  Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
  Candidate.Checkpoint := BytesOf(Text);
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
    Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
    ParseRegistryPackage(Text, SHA256BytesPrefixed(BytesOf(Text)), Trust.Origin);
  except
    on E: ELWPTRegistryError do Actual := E.Message;
  end;
  { Canonical quoting passes; only the timestamp's domain validation fails. }
  Expect<Boolean>(Pos('invalid_registry_record:', Actual) = 1).ToBe(True);
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
    ParseRegistryPackage(Text, SHA256BytesPrefixed(BytesOf(Text)), Trust.Origin);
  except
    on E: ELWPTRegistryError do Actual := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_registry_record:', Actual) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.SnapshotTamperingRejected;
var
  Source: TFixtureSource;
begin
  Source := TFixtureSource.Create;
  try
    Source.Overrides.Add('snapshots/sha256/' + Copy(ROOT_SNAPSHOT, 8, 64)
      + '.toml', BytesOf('tampered'));
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
    RecordBytes := BytesOf(StringReplace(AsText(ReadFixture('records/'
      + Copy(ROOT_RECORD, 8, 64) + '.toml')), '2026-01-01', '2026-01-02', []));
    RecordHash := SHA256BytesPrefixed(RecordBytes);
    Source.Overrides.Add('records/sha256/' + Copy(RecordHash, 8, 64)
      + '.toml', RecordBytes);
    if RecordHash < ROOT_RECORD then
      RecordList := '"' + RecordHash + '", "' + ROOT_RECORD + '"'
    else RecordList := '"' + ROOT_RECORD + '", "' + RecordHash + '"';
    SnapshotBytes := BytesOf(StringReplace(AsText(ReadFixture('snapshots/'
      + Copy(ROOT_SNAPSHOT, 8, 64) + '.toml')), '"' + ROOT_RECORD + '"',
      RecordList, []));
    SnapshotHash := SHA256BytesPrefixed(SnapshotBytes);
    Source.Overrides.Add('snapshots/sha256/' + Copy(SnapshotHash, 8, 64)
      + '.toml', SnapshotBytes);
    Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
  Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
    Expect<Boolean>(Pos('object_hash_mismatch:', Actual) = 1).ToBe(True);
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
    Expect<Boolean>(Pos('invalid_trust_root:', Actual) = 1).ToBe(True);
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
    ParseRegistryPackage(Text, SHA256BytesPrefixed(BytesOf(Text)), Trust.Origin);
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
    Publication.Archive := BytesOf('real origin artifact' + #0 + 'bytes');
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
    SnapshotBytes := BytesOf(StringReplace(AsText(ReadFixture('snapshots/'
      + Copy(ROOT_SNAPSHOT, 8, 64) + '.toml')), 'previous = ""',
      'previous = 0', []));
    SnapshotHash := SHA256BytesPrefixed(SnapshotBytes);
    Source.Overrides.Add('snapshots/sha256/' + Copy(SnapshotHash, 8, 64)
      + '.toml', SnapshotBytes);
    Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
  Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
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
  ValidateRegistryKeyDocument(BytesOf(Original), Trust, 1);
  ValidateRegistryKeyDocument(BytesOf(StringReplace(Original,
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
      ValidateRegistryKeyDocument(BytesOf(Candidate), Trust, 1);
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
  Page := ParseRegistryRotationPage(BytesOf(Original), Trust.Origin, Trust.Origin + '/v1', 0, 1);
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
      ParseRegistryRotationPage(BytesOf(Candidate), Trust.Origin, Trust.Origin + '/v1', AfterSequence, Maximum);
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
  Candidate.RetrievalDocuments[0] := BytesOf(StringOfChar('p', 16));
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
    Budget.Account(BytesOf('page'));
    Budget.Account(BytesOf('keys'));
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


function StaleOrTrust(ASuite: TRegistryVerificationTests; const AProof: TLWPTRegistryProof;
  const APrior: TLWPTRegistryAcceptedState; const ATime: string; out AMessage: string): string;
begin
  Result := 'accepted';
  AMessage := '';
  try
    ASuite.Verify(AProof, APrior, rvmAcquire, ATime);
  except
    on E: ELWPTRegistryStaleContactError do
    begin
      Result := 'stale';
      AMessage := E.Message;
    end;
    on E: ELWPTRegistryError do
    begin
      Result := 'trust';
      AMessage := E.Message;
    end;
  end;
end;

procedure TRegistryVerificationTests.ExpiredEquivocationIsTrustFailure;
var
  Prior: TLWPTVerifiedRegistry;
  Candidate: TLWPTRegistryProof;
  Message: string;
begin
  Prior := Verify(Proof(2), Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(2);
  Candidate.Checkpoint := ReadFixture('invalid/checkpoint-2-equivocation.toml');
  Candidate.Signature := ReadFixture('invalid/checkpoint-2-equivocation.sig.toml');
  { Expiry must not hide equivocation, which aborts acquisition. }
  Expect<string>(StaleOrTrust(Self, Candidate, Prior.State, '2027-01-01T00:00:00Z',
    Message)).ToBe('trust');
  Expect<Boolean>(Pos('checkpoint_equivocation:', Message) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.OlderKeyCheckpointIsStaleDowngrade;
var
  Prior: TLWPTVerifiedRegistry;
  Candidate: TLWPTRegistryProof;
  Message: string;
begin
  { The accepted chain already rotated past the key that signed sequence 1.
    A contact still serving that older checkpoint is stale, not untrusted. }
  Prior := Verify(Proof(5), Default(TLWPTRegistryAcceptedState));
  Candidate := Proof(1);
  Candidate.Rotations := Proof(5).Rotations;
  Expect<string>(StaleOrTrust(Self, Candidate, Prior.State, EVALUATION_TIME, Message)).ToBe('stale');
  Expect<Boolean>(Pos('checkpoint_downgrade:', Message) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.InconsistentDowngradeIsEquivocation;
var
  Prior: TLWPTVerifiedRegistry;
  Candidate: TLWPTRegistryProof;
  Message: string;
begin
  Prior := Verify(Proof(2), Default(TLWPTRegistryAcceptedState));
  { A signed older checkpoint that contradicts accepted history. }
  Candidate := Proof(1);
  Candidate.Checkpoint := BytesOf(StringReplace(AsText(Candidate.Checkpoint),
    ROOT_SNAPSHOT, 'sha256:' + StringOfChar('0', 64), []));
  ResignRoot(Candidate);
  Expect<string>(StaleOrTrust(Self, Candidate, Prior.State, EVALUATION_TIME, Message)).ToBe('trust');
  Expect<Boolean>(Pos('checkpoint_equivocation:', Message) = 1).ToBe(True);
end;

procedure TRegistryVerificationTests.UninitializedMirrorServesNothing;
const
  Targets: array[0..4] of string = ('/v1/checkpoints/latest.toml',
    '/v1/checkpoints/latest.sig.toml', '/v1/rotations?after=0&limit=1',
    '/v1/objects/sha256/' + 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '/v1/records/sha256/' + 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.toml');
var
  Scratch, Target, Diagnostic: string;
  Mirror: TMirrorFixtureStore;
  Status: Integer;
begin
  Scratch := CreateScratchRoot('registry-uninitialized-mirror');
  Mirror := nil;
  try
    Mirror := NewFixtureMirror(Scratch, Trust);
    for Target in Targets do
    begin
      Diagnostic := '';
      Status := 0;
      try
        Status := RegistryHTTPResponse(Mirror, 'GET', Target).Status;
      except
        on E: Exception do Diagnostic := E.Message;
      end;
      Expect<string>(Diagnostic).ToBe('');
      Expect<Integer>(Status).ToBe(404);
    end;
    Expect<Integer>(RegistryHTTPResponse(Mirror, 'GET', '/v1/capabilities').Status).ToBe(200);
  finally
    Mirror.Free;
    RecursiveDelete(Scratch);
  end;
end;

procedure TRegistryVerificationTests.SetupTests;
begin
  Test('rotation pages enforce item counts, order, scope and canonical fields', RotationPagesAreBoundedAndCanonical);
  Test('retrieval pages and key documents share signed-proof aggregate limits', RetrievalDocumentsShareProofBudget);
  Test('read views share one verified generation per accepted state', MirrorReadViewReusesCapturedProof);
  Test('unknown and malformed routes never verify retained proof', UnknownRoutesSkipProofVerification);
  Test('concurrent cold-cache requests share one verification', ConcurrentRequestsShareOneVerification);
  Test('a delayed reader cannot replace a newer verified generation', DelayedReaderKeepsNewerGeneration);
  Test('served proof bytes must match their authenticated digests', ServedBytesMatchAuthenticatedDigests);
  Test('records and objects outside accepted history are not addressable', UnacceptedRecordsAndObjectsStayHidden);
  Test('stray rotation files cannot join the accepted chain', StrayRotationFilesDoNotJoinTheChain);
  Test('same-sequence renewal cannot move backwards', BackwardsRenewalRejected);
  Test('a quoted hash in an opaque cursor is not a comment', QuotedHashIsNotAComment);
  Test('canonical documents require strict UTF-8', InvalidUTF8Rejected);
  Test('dotted inline keys cannot bypass the nesting bound', DottedKeyNestingRejected);
  Test('stale contacts are distinguished from trust failures', StaleContactFailuresAreDistinguished);
  Test('each rotation step verifies both signatures before advancing', RotationStepVerifiesBothSignatures);
  Test('expiry does not hide same-sequence equivocation', ExpiredEquivocationIsTrustFailure);
  Test('an older checkpoint under an earlier chain key is a stale downgrade', OlderKeyCheckpointIsStaleDowngrade);
  Test('an older checkpoint contradicting accepted history is equivocation', InconsistentDowngradeIsEquivocation);
  Test('an uninitialized mirror publishes no resources', UninitializedMirrorServesNothing);
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
