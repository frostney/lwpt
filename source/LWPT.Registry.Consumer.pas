{ LWPT.Registry.Consumer -- registry dependency acquisition for installs.

  ADR-0051. One session per declared registry acquires one verified head per
  install: contacts are tried in order (manifest mirrors, then the origin),
  a request-layer failure or a stale contact advances, and every other
  failure aborts. Accepted state and the clock-rollback floor are kept per
  user (keyed by origin identity and pinned root key) and in the lock's
  per-origin table; acquisition extends both. }
unit LWPT.Registry.Consumer;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  HTTPClient,
  LWPT.Core,
  LWPT.Manifest,
  LWPT.Registry.Client,
  LWPT.Registry.Store,
  LWPT.Registry.Verification;

const
  REGISTRY_STATE_DIR_ENV = PROJECT_NAME + '_REGISTRY_STATE_DIR';
  REGISTRY_CONSUMER_STATE_SCHEMA = PROGRAM_NAME + '-registry-consumer-state-v1';
  { Committed proof documents live below the archives directory. }
  REGISTRY_PROOFS_DIR = 'registry-proofs';
  { Bounds one complete contact attempt, including history verification.
    Each request uses the smaller of this remainder and the request limit. }
  RegistryContactAttemptMilliseconds = 10 * 60 * 1000;
  RegistryArchiveRequestMilliseconds = 5 * 60 * 1000;
  { Archive responses are capped at the signed archive_size, never above. }
  RegistryMaximumArchiveBytes = Int64(256) * 1024 * 1024;
  RegistryStateLeaseWaitMilliseconds = 60 * 1000;
  RegistryStateDocumentBytes = 64 * 1024;

type
  { Accepted state plus the rotation triplet hashes that reach its key. }
  TLWPTRegistryConsumerState = record
    State: TLWPTRegistryAcceptedState;
    Rotations: TStringArray;
  end;

  { One [registry."<identity>"] table of lwpt.lock. The fields from KeyId
    through Rotations are the selection proof; Accepted* and ClockFloor are
    the recorded accepted state at the last lock change (decision 11). }
  TLWPTRegistryLockTable = record
    Identity, TrustKeyId: string;
    KeyId: string;
    Sequence: Int64;
    Snapshot, Checkpoint, Signature, PublishedAt, ExpiresAt: string;
    Rotations: TStringArray;
    Accepted: TLWPTRegistryConsumerState;
  end;
  TLWPTRegistryLockTableArray = array of TLWPTRegistryLockTable;

  TLWPTRegistryContactOutcome = (rcoRequestFailure, rcoStale);

  TLWPTRegistryConsumer = class;

  TLWPTRegistrySession = class
  private
    FOwner: TLWPTRegistryConsumer;
    FDeclaration: TLWPTRegistryDeclaration;
    FIdentity, FLockedIdentity, FLockAmbiguity: string;
    { Identities a workspace member's same-alias declaration requires, as
      Name=Value pairs of identity and declaring member. }
    FConstraints: TStringList;
    FAttempted, FAcquired, FUnreachable: Boolean;
    FVerified: TLWPTVerifiedRegistry;
    FAPI, FContact, FFailures: string;
    FAccepted, FUserAccepted: TLWPTRegistryConsumerState;
    FProofRotations: TLWPTRegistryRotationProofArray;
    FLockTables: TLWPTRegistryLockTableArray;
    function Contacts: TStringArray;
    function LockTableFor(const AIdentity: string;
      out ATable: TLWPTRegistryLockTable): Boolean;
    procedure AcquireFrom(const AContact, ANow: string);
    procedure SetLockedIdentity(const AIdentity: string);
    procedure RequireConstraints(const AIdentity: string);
    function AcceptedChain(const AHashes: TStringArray;
      out AChain: TLWPTRegistryRotationProofArray): Boolean;
  public
    constructor Create(AOwner: TLWPTRegistryConsumer;
      const ADeclaration: TLWPTRegistryDeclaration;
      const ALockTables: TLWPTRegistryLockTableArray);
    destructor Destroy; override;
    { Records that a workspace member declares this alias with AIdentity.
      A declared, locked, or later established identity must equal it. }
    procedure RequireIdentity(const AIdentity, AMember: string);
    { Refuses acquisition when the lock could not bind this alias to one
      recorded identity: an ambiguous binding is never new discovery. }
    procedure MarkAmbiguous(const AMessage: string);
    { Tries each contact once per install. Afterwards Acquired, or
      Unreachable when every contact failed at the request layer. Any other
      outcome raises. }
    procedure Acquire;
    function Trust: TLWPTRegistryTrust;
    { Archive bytes from the contact that produced the accepted proof,
      verified against the signed record before they are returned. }
    function FetchArchive(const APackage: TLWPTRegistryPackage): TBytes;
    function ArchiveURL(const APackage: TLWPTRegistryPackage): string;
    { Exact bytes of a document the verified head read. }
    function DocumentBytes(const APath: string; out ABytes: TBytes): Boolean;
    property Declaration: TLWPTRegistryDeclaration read FDeclaration;
    property Alias: string read FDeclaration.Alias;
    { Declared, locked, or (after acquisition) established identity. }
    property Identity: string read FIdentity;
    property LockedIdentity: string read FLockedIdentity write SetLockedIdentity;
    property Attempted: Boolean read FAttempted;
    property Acquired: Boolean read FAcquired;
    property Unreachable: Boolean read FUnreachable;
    property Failures: string read FFailures;
    property Verified: TLWPTVerifiedRegistry read FVerified;
    { The merged accepted state for the lock: per-user state, the lock's
      recorded state, and this acquisition. }
    property Accepted: TLWPTRegistryConsumerState read FAccepted;
    { What per-user state may absorb: its own prior and the authenticated
      head only, never unsigned project state such as a lock's floor. }
    property UserAccepted: TLWPTRegistryConsumerState read FUserAccepted;
    property ProofRotations: TLWPTRegistryRotationProofArray read FProofRotations;
    property Contact: string read FContact;
  end;

  { Every session of one install, keyed by alias. }
  TLWPTRegistryConsumer = class
  private
    FRoot: TManifest;
    FSessions: TList;
    FLockTables: TLWPTRegistryLockTableArray;
    FArchivesRoot: string;
    FNetworkFree: Boolean;
    function SessionAt(AIndex: Integer): TLWPTRegistrySession;
  public
    constructor Create(const ARoot: TManifest;
      const ALockTables: TLWPTRegistryLockTableArray;
      const AArchivesRoot: string);
    destructor Destroy; override;
    { One origin may be reached through only one alias: raises when another
      declaration declares, locks, or established AIdentity. }
    procedure RequireUniqueIdentity(ASession: TLWPTRegistrySession;
      const AIdentity: string);
    { Checkpoint freshness and the clock floor judged again at publication
      time, as the mirror does at activation. }
    procedure RecheckFreshness;
    { Merges every acquisition into per-user state. Part of a successful
      install: a failure raises. }
    procedure PersistAcceptedState;
    property ArchivesRoot: string read FArchivesRoot;
    { --frozen and --offline: sessions only bind identities from the manifest
      and the lock. Acquisition raises instead of selecting a contact, and
      SessionForIdentity never acquires to establish an identity. }
    property NetworkFree: Boolean read FNetworkFree write FNetworkFree;
    function SessionForAlias(const AAlias: string): TLWPTRegistrySession;
    { The session for a record dependency's origin identity: a declared
      identity, or one established in this install or recorded in the lock.
      Raises the declaration hint otherwise. }
    function SessionForIdentity(const AIdentity, ADependency,
      ARequiredBy, ARequirerOrigin: string): TLWPTRegistrySession;
    function Count: Integer;
    property Sessions[AIndex: Integer]: TLWPTRegistrySession read SessionAt;
    property LockTables: TLWPTRegistryLockTableArray read FLockTables;
  end;

function RegistryStateRoot: string;
function RegistryStatePath(const AIdentity, ATrustKeyId: string): string;
function RegistryStatePathAt(const ARoot, AIdentity, ATrustKeyId: string): string;
{ False when no state exists. Corrupt state raises, naming the file; it is
  never reset, because a reset would lower the clock floor. }
function LoadRegistryConsumerState(const AIdentity, ATrustKeyId: string;
  out AState: TLWPTRegistryConsumerState): Boolean;
function LoadRegistryConsumerStateAt(const ARoot, AIdentity, ATrustKeyId: string;
  out AState: TLWPTRegistryConsumerState): Boolean;
{ Merges AState into the per-user file under a producer lease. The sequence
  and floor never go down. The exact bytes of ARotations, the chain that
  reaches the accepted key, join the per-user document store so a later
  acquisition can authenticate an older contact against it. }
procedure MergeRegistryConsumerState(const AIdentity, ATrustKeyId: string;
  const AState: TLWPTRegistryConsumerState;
  const ARotations: TLWPTRegistryRotationProofArray;
  const AHistory: TLWPTRegistryDocumentArray);
{ Failure contract: documents are admitted to the content-addressed store
  before the state file is replaced, and nothing is rolled back when a later
  step fails. A retained document only ever adds authenticated history, and
  the state file only ever moves forward, so a failure leaves per-user state
  at the old or the new high-water mark, never lower. No atomicity across
  origins, documents, and project state is claimed. }
procedure MergeRegistryConsumerStateAt(const ARoot, AIdentity, ATrustKeyId: string;
  const AState: TLWPTRegistryConsumerState;
  const ARotations: TLWPTRegistryRotationProofArray;
  const AHistory: TLWPTRegistryDocumentArray);
{ One document of the per-user store, or nil when it is absent or its bytes
  do not hash to AHash. }
function LoadRegistryStateDocument(const ARoot, AHash: string): TBytes;
{ A document by hash from the per-user store, then the committed proofs.
  Nil when absent, larger than AMaximumBytes (checked before reading), or
  not hashing to AHash. }
function ReadLocalRegistryDocument(const AStateRoot, AArchivesRoot,
  AHash: string; const AMaximumBytes: Int64): TBytes;
{ The rotation chain named by AHashes (document, old, new per rotation),
  loaded locally within ALimits: the count and every hash are checked before
  anything is allocated, each size before it is read, and the running total
  before each read. False for a repeated hash, an exceeded limit, or any
  unavailable document; the chain is then simply not supplied. }
function LoadRegistryRotationChain(const AStateRoot, AArchivesRoot: string;
  const AHashes: TStringArray; const ALimits: TLWPTRegistryVerificationLimits;
  out AChain: TLWPTRegistryRotationProofArray): Boolean;
{ The bounded-loading policy for a rotation hash list, checked before any
  document is read: complete triplets, at most ALimits.Rotations rotations,
  canonical hashes, and no repeated hash. Raises proof_limit_exceeded or
  registry_proof_corrupt. }
procedure RequireBoundedRegistryRotationHashes(const AHashes: TStringArray;
  const ALimits: TLWPTRegistryVerificationLimits);
{ One document of a locked selection proof, read only when its size fits
  AAllowance (checked before allocation; proof_limit_exceeded otherwise).
  The committed file under AArchivesRoot must hash to its name
  (registry_proof_corrupt), and a corrupt committed file is never read
  around. Only when it is absent, and AStateRoot is not empty, does the
  per-user document store supply it by hash (--offline). }
function ReadLockedRegistryDocument(const AArchivesRoot, AStateRoot,
  AHash: string; const AAllowance: Int64): TBytes;
{ The committed bytes of ATable's selection proof and of ARecords, loaded
  under the policy above within ALimits: rotation hashes are checked by
  RequireBoundedRegistryRotationHashes, record hashes may not repeat, and
  every document is charged to the per-document limit, the remaining total,
  and the document count before it is allocated. }
function LoadLockedRegistrySelection(const AArchivesRoot, AStateRoot: string;
  const ATable: TLWPTRegistryLockTable; const ARecords: TStringArray;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTRegistryLockedSelection;
{ The newer of two accepted states; the floor is the later of both. }
function MergeRegistryAcceptedStates(const ALeft,
  ARight: TLWPTRegistryConsumerState): TLWPTRegistryConsumerState;
function RegistryAcceptedStatesEqual(const ALeft,
  ARight: TLWPTRegistryConsumerState): Boolean;
function RegistryRotationHashes(
  const ARotations: TLWPTRegistryRotationProofArray): TStringArray;
function LoadRegistryLockTables(const APath: string; const AAcceptSchemaV3: Boolean = False): TLWPTRegistryLockTableArray;
procedure RenderRegistryLockTables(const ATables: TLWPTRegistryLockTableArray;
  ALines: TStrings);
function RegistryProofPath(const AArchivesRoot, AHash: string): string;
function RegistryContactDestination(const AURL: string): THTTPDestinationPolicy;

implementation

uses
  StrUtils,

  LWPT.ProducerLease,
  TOML;

function AllowLocalhostContacts: Boolean;
begin
  {$IFDEF INSTALL_TESTING}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function IsLocalhostHTTP(const AURL: string): Boolean;
begin
  Result := RegistryConnectAddress(AURL) <> '';
end;

function RegistryContactDestination(const AURL: string): THTTPDestinationPolicy;
begin
  Result := Default(THTTPDestinationPolicy);
  { The test-build localhost exception is dialled at 127.0.0.1 through
    ConnectAddress, which cannot be combined with an address policy. }
  if AllowLocalhostContacts and IsLocalhostHTTP(AURL) then Exit;
  SetLength(Result.AllowedHosts, 1);
  Result.AllowedHosts[0] := HTTPURLHost(AURL);
  Result.RequireHTTPS := True;
  Result.PrivateAddressPolicy := papDeny;
end;

function RegistryProofPath(const AArchivesRoot, AHash: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AArchivesRoot) + REGISTRY_PROOFS_DIR
    + '/sha256/' + RegistryDigestHex(AHash) + '.toml';
end;

function RegistryRotationHashes(
  const ARotations: TLWPTRegistryRotationProofArray): TStringArray;
var Index: Integer;
begin
  SetLength(Result, 3 * Length(ARotations));
  for Index := 0 to High(ARotations) do
  begin
    Result[3 * Index] := SHA256BytesPrefixed(ARotations[Index].Document);
    Result[3 * Index + 1] := SHA256BytesPrefixed(ARotations[Index].OldSignature);
    Result[3 * Index + 2] := SHA256BytesPrefixed(ARotations[Index].NewSignature);
  end;
end;

{ ---------------------------------------------------------------------------
  Per-user accepted state
  --------------------------------------------------------------------------- }

const
  { One protocol metadata document never exceeds this, as in verification. }
  MaximumRegistryDocumentBytes = 4 * 1024 * 1024;

function Min64(const ALeft, ARight: Int64): Int64;
begin
  if ALeft < ARight then Result := ALeft else Result := ARight;
end;

function RegistryStateRoot: string;
var Configured: string;
begin
  Configured := SysUtils.GetEnvironmentVariable(REGISTRY_STATE_DIR_ENV);
  if Configured <> '' then
    Exit(ExcludeTrailingPathDelimiter(ExpandFileName(Configured)));
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(
    IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'registry'));
end;

function RegistryStatePathAt(const ARoot, AIdentity, ATrustKeyId: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARoot) + 'origins/'
    + SHA256Hex(BytesOf(AIdentity + #10 + ATrustKeyId)) + '.toml';
end;

function RegistryStatePath(const AIdentity, ATrustKeyId: string): string;
begin
  Result := RegistryStatePathAt(RegistryStateRoot, AIdentity, ATrustKeyId);
end;

function RegistryStateDocumentPath(const ARoot, AHash: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARoot) + 'documents/sha256/'
    + RegistryDigestHex(AHash) + '.toml';
end;

function ReadBoundedDocument(const APath, AHash: string;
  const AMaximumBytes: Int64): TBytes;
var Stream: TFileStream;
begin
  Result := nil;
  if not FileExists(APath) then Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if (Stream.Size > AMaximumBytes)
       or (Stream.Size > MaximumRegistryDocumentBytes) then Exit;
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
  if SHA256BytesPrefixed(Result) <> AHash then Result := nil;
end;

function LoadRegistryStateDocument(const ARoot, AHash: string): TBytes;
begin
  Result := nil;
  if not RegistryHashIsCanonical(AHash) then Exit;
  Result := ReadBoundedDocument(RegistryStateDocumentPath(ARoot, AHash), AHash,
    MaximumRegistryDocumentBytes);
end;

function ReadLocalRegistryDocument(const AStateRoot, AArchivesRoot,
  AHash: string; const AMaximumBytes: Int64): TBytes;
begin
  Result := nil;
  if not RegistryHashIsCanonical(AHash) then Exit;
  if AStateRoot <> '' then
    Result := ReadBoundedDocument(RegistryStateDocumentPath(AStateRoot, AHash),
      AHash, AMaximumBytes);
  if (Result = nil) and (AArchivesRoot <> '') then
    Result := ReadBoundedDocument(RegistryProofPath(AArchivesRoot, AHash),
      AHash, AMaximumBytes);
end;

procedure RequireBoundedRegistryRotationHashes(const AHashes: TStringArray;
  const ALimits: TLWPTRegistryVerificationLimits);
var
  Seen: TStringList;
  Index: Integer;
begin
  if (Length(AHashes) mod 3) <> 0 then
    raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
      'rotation hashes are incomplete: each rotation names three documents');
  if Length(AHashes) div 3 > ALimits.Rotations then
    raise ELWPTRegistryError.CreateStable('proof_limit_exceeded',
      'the proof names ' + IntToStr(Length(AHashes) div 3) + ' rotations; '
      + 'the limit is ' + IntToStr(ALimits.Rotations));
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for Index := 0 to High(AHashes) do
    begin
      if not RegistryHashIsCanonical(AHashes[Index]) then
        raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
          'rotation hash "' + AHashes[Index] + '" is not canonical');
      if Seen.IndexOf(AHashes[Index]) >= 0 then
        raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
          'rotation document ' + AHashes[Index] + ' is named more than once; '
          + 'a repeated document is refused before it is read');
      Seen.Add(AHashes[Index]);
    end;
  finally
    Seen.Free;
  end;
end;

function LoadRegistryRotationChain(const AStateRoot, AArchivesRoot: string;
  const AHashes: TStringArray; const ALimits: TLWPTRegistryVerificationLimits;
  out AChain: TLWPTRegistryRotationProofArray): Boolean;
var
  Index, Count: Integer;
  Total: Int64;
  Parts: array[0..2] of TBytes;
  Part: Integer;
begin
  AChain := nil;
  Result := False;
  if Length(AHashes) = 0 then Exit(True);
  try
    RequireBoundedRegistryRotationHashes(AHashes, ALimits);
  except
    on E: ELWPTRegistryError do Exit;
  end;
  Count := Length(AHashes) div 3;
  Total := 0;
  SetLength(AChain, Count);
  for Index := 0 to Count - 1 do
  begin
    for Part := 0 to 2 do
    begin
      if ALimits.TotalBytes - Total < 1 then
      begin
        AChain := nil;
        Exit;
      end;
      Parts[Part] := ReadLocalRegistryDocument(AStateRoot, AArchivesRoot,
        AHashes[3 * Index + Part], Min64(ALimits.DocumentBytes,
          ALimits.TotalBytes - Total));
      if Parts[Part] = nil then
      begin
        AChain := nil;
        Exit;
      end;
      Inc(Total, Length(Parts[Part]));
    end;
    AChain[Index].Document := Parts[0];
    AChain[Index].OldSignature := Parts[1];
    AChain[Index].NewSignature := Parts[2];
  end;
  Result := True;
end;

function ReadLockedRegistryDocument(const AArchivesRoot, AStateRoot,
  AHash: string; const AAllowance: Int64): TBytes;
var Path: string; Stream: TFileStream;
begin
  Result := nil;
  if not RegistryHashIsCanonical(AHash) then
    raise ELWPTRegistryError.CreateStable('registry_proof_missing',
      'lock names an invalid proof document hash "' + AHash + '"');
  if AAllowance < 1 then
    raise ELWPTRegistryError.CreateStable('proof_limit_exceeded',
      'the committed selection proof exceeds the verification byte budget');
  Path := RegistryProofPath(AArchivesRoot, AHash);
  if not FileExists(Path) then
  begin
    if AStateRoot <> '' then
    begin
      Result := ReadBoundedDocument(RegistryStateDocumentPath(AStateRoot,
        AHash), AHash, AAllowance);
      if Result <> nil then Exit;
      raise ELWPTRegistryError.CreateStable('registry_proof_missing',
        'committed proof document ' + Path + ' is missing, and the per-user '
        + 'document store under ' + AStateRoot + ' has no verified copy '
        + 'within the verification limits');
    end;
    raise ELWPTRegistryError.CreateStable('registry_proof_missing',
      'committed proof document ' + Path + ' is missing');
  end;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > AAllowance then
      raise ELWPTRegistryError.CreateStable('proof_limit_exceeded',
        'committed proof document ' + Path + ' has ' + IntToStr(Stream.Size)
        + ' bytes; the remaining verification budget is '
        + IntToStr(AAllowance));
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
  if SHA256BytesPrefixed(Result) <> AHash then
    raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
      'committed proof document ' + Path + ' does not match its hash');
end;

function LoadLockedRegistrySelection(const AArchivesRoot, AStateRoot: string;
  const ATable: TLWPTRegistryLockTable; const ARecords: TStringArray;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTRegistryLockedSelection;
var
  Total: Int64;
  Index: Integer;
  Seen: TStringList;

  function Next(const AHash: string): TBytes;
  begin
    Result := ReadLockedRegistryDocument(AArchivesRoot, AStateRoot, AHash,
      Min64(ALimits.DocumentBytes, ALimits.TotalBytes - Total));
    Inc(Total, Length(Result));
  end;

begin
  Result := Default(TLWPTRegistryLockedSelection);
  RequireBoundedRegistryRotationHashes(ATable.Rotations, ALimits);
  if 3 + Length(ATable.Rotations) + Length(ARecords) > ALimits.Documents then
    raise ELWPTRegistryError.CreateStable('proof_limit_exceeded',
      'the committed selection proof names more than '
      + IntToStr(ALimits.Documents) + ' documents');
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for Index := 0 to High(ARecords) do
    begin
      if Seen.IndexOf(ARecords[Index]) >= 0 then
        raise ELWPTRegistryError.CreateStable('registry_proof_corrupt',
          'selected record ' + ARecords[Index] + ' is named more than once');
      Seen.Add(ARecords[Index]);
    end;
  finally
    Seen.Free;
  end;
  Total := 0;
  Result.Checkpoint := Next(ATable.Checkpoint);
  Result.Signature := Next(ATable.Signature);
  Result.Snapshot := Next(ATable.Snapshot);
  SetLength(Result.Rotations, Length(ATable.Rotations) div 3);
  for Index := 0 to High(Result.Rotations) do
  begin
    Result.Rotations[Index].Document := Next(ATable.Rotations[3 * Index]);
    Result.Rotations[Index].OldSignature := Next(ATable.Rotations[3 * Index + 1]);
    Result.Rotations[Index].NewSignature := Next(ATable.Rotations[3 * Index + 2]);
  end;
  SetLength(Result.Records, Length(ARecords));
  for Index := 0 to High(ARecords) do
    Result.Records[Index] := Next(ARecords[Index]);
end;

function QuoteList(const AValues: TStringArray): string;
var Index: Integer;
begin
  Result := '[';
  for Index := 0 to High(AValues) do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + '"' + TomlEscape(AValues[Index]) + '"';
  end;
  Result := Result + ']';
end;

function ReadList(ANode: TTOMLNode; const AKey: string;
  out AValues: TStringArray): Boolean;
var Items: TTOMLNode; Index: Integer;
begin
  AValues := nil;
  Items := TomlGet(ANode, AKey);
  if not TomlIsArray(Items) then Exit(False);
  SetLength(AValues, Items.Items.Count);
  for Index := 0 to Items.Items.Count - 1 do
  begin
    if not TomlIsString(Items.Items[Index])
       or not RegistryHashIsCanonical(Items.Items[Index].ScalarText) then
      Exit(False);
    AValues[Index] := Items.Items[Index].ScalarText;
  end;
  Result := (Length(AValues) mod 3) = 0;
end;

function StateDocument(const AIdentity, ATrustKeyId: string;
  const AState: TLWPTRegistryConsumerState): TBytes;
var Text: string;
begin
  Text := 'schema = "' + REGISTRY_CONSUMER_STATE_SCHEMA + '"' + #10
    + 'origin = "' + TomlEscape(AIdentity) + '"' + #10
    + 'trust_key_id = "' + TomlEscape(ATrustKeyId) + '"' + #10
    + 'key_id = "' + TomlEscape(AState.State.KeyId) + '"' + #10
    + 'public_key = "' + TomlEscape(AState.State.PublicKey) + '"' + #10
    + 'sequence = ' + IntToStr(AState.State.Sequence) + #10
    + 'snapshot = "' + TomlEscape(AState.State.Snapshot) + '"' + #10
    + 'checkpoint = "' + TomlEscape(AState.State.CheckpointHash) + '"' + #10
    + 'published_at = "' + TomlEscape(AState.State.PublishedAt) + '"' + #10
    + 'expires_at = "' + TomlEscape(AState.State.ExpiresAt) + '"' + #10
    + 'clock_floor = "' + TomlEscape(AState.State.ClockFloor) + '"' + #10
    + 'rotations = ' + QuoteList(AState.Rotations) + #10;
  Result := BytesOf(Text);
end;

procedure RaiseCorruptState(const APath, AReason: string);
begin
  raise ELWPTRegistryError.CreateStable('registry_state_corrupt',
    'per-user registry state ' + APath + ' is corrupt (' + AReason
    + '). It is never reset automatically, because a reset lowers the '
    + 'clock-rollback floor; inspect it, or delete it deliberately to '
    + 'accept reduced protection until the next acquisition');
end;

function LoadRegistryConsumerState(const AIdentity, ATrustKeyId: string;
  out AState: TLWPTRegistryConsumerState): Boolean;
begin
  Result := LoadRegistryConsumerStateAt(RegistryStateRoot, AIdentity,
    ATrustKeyId, AState);
end;

function LoadRegistryConsumerStateAt(const ARoot, AIdentity, ATrustKeyId: string;
  out AState: TLWPTRegistryConsumerState): Boolean;
var
  Path, Text: string;
  Stream: TFileStream;
  Parser: TTOMLParser;
  Root: TTOMLNode;
  Sequence: Int64;
begin
  AState := Default(TLWPTRegistryConsumerState);
  Path := RegistryStatePathAt(ARoot, AIdentity, ATrustKeyId);
  if not FileExists(Path) then Exit(False);
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > RegistryStateDocumentBytes then
      RaiseCorruptState(Path, 'oversized');
    SetLength(Text, Stream.Size);
    if Length(Text) > 0 then Stream.ReadBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    try
      Root := Parser.ParseDocument(Text);
    except
      on E: Exception do RaiseCorruptState(Path, E.Message);
    end;
    if (TomlStr(Root, 'schema', '') <> REGISTRY_CONSUMER_STATE_SCHEMA)
       or (TomlStr(Root, 'origin', '') <> AIdentity)
       or (TomlStr(Root, 'trust_key_id', '') <> ATrustKeyId) then
      RaiseCorruptState(Path, 'schema, origin, or pinned key differs');
    Sequence := TomlInt(Root, 'sequence', -1);
    AState.State.Origin := AIdentity;
    AState.State.KeyId := TomlStr(Root, 'key_id', '');
    AState.State.PublicKey := TomlStr(Root, 'public_key', '');
    AState.State.Sequence := Sequence;
    AState.State.Snapshot := TomlStr(Root, 'snapshot', '');
    AState.State.CheckpointHash := TomlStr(Root, 'checkpoint', '');
    AState.State.PublishedAt := TomlStr(Root, 'published_at', '');
    AState.State.ExpiresAt := TomlStr(Root, 'expires_at', '');
    AState.State.ClockFloor := TomlStr(Root, 'clock_floor', '');
    if (Sequence < 1)
       or not RegistryTrustRootIsValid(AState.State.KeyId, AState.State.PublicKey)
       or not RegistryHashIsCanonical(AState.State.Snapshot)
       or not RegistryHashIsCanonical(AState.State.CheckpointHash)
       or not RegistryTimestampIsCanonical(AState.State.PublishedAt)
       or not RegistryTimestampIsCanonical(AState.State.ExpiresAt)
       or not RegistryTimestampIsCanonical(AState.State.ClockFloor)
       or not ReadList(Root, 'rotations', AState.Rotations) then
      RaiseCorruptState(Path, 'a field is missing or not canonical');
  finally
    Root.Free;
    Parser.Free;
  end;
  Result := True;
end;

function MergeRegistryAcceptedStates(const ALeft,
  ARight: TLWPTRegistryConsumerState): TLWPTRegistryConsumerState;
var Floor: string;
begin
  if ALeft.State.Sequence = 0 then Exit(ARight);
  if ARight.State.Sequence = 0 then Exit(ALeft);
  Floor := RegistryLaterTimestamp(
    RegistryLaterTimestamp(ALeft.State.ClockFloor, ALeft.State.PublishedAt),
    RegistryLaterTimestamp(ARight.State.ClockFloor, ARight.State.PublishedAt));
  if ALeft.State.Sequence > ARight.State.Sequence then Result := ALeft
  else if ARight.State.Sequence > ALeft.State.Sequence then Result := ARight
  { One sequence names one snapshot and key; a renewal moves both times
    forward, so the later publication is the newer acceptance. }
  else if ARight.State.PublishedAt > ALeft.State.PublishedAt then Result := ARight
  else Result := ALeft;
  Result.State.ClockFloor := Floor;
end;

function RegistryAcceptedStatesEqual(const ALeft,
  ARight: TLWPTRegistryConsumerState): Boolean;
var Index: Integer;
begin
  Result := (ALeft.State.KeyId = ARight.State.KeyId)
    and (ALeft.State.Sequence = ARight.State.Sequence)
    and (ALeft.State.Snapshot = ARight.State.Snapshot)
    and (ALeft.State.CheckpointHash = ARight.State.CheckpointHash)
    and (ALeft.State.PublishedAt = ARight.State.PublishedAt)
    and (ALeft.State.ExpiresAt = ARight.State.ExpiresAt)
    and (ALeft.State.ClockFloor = ARight.State.ClockFloor)
    and (Length(ALeft.Rotations) = Length(ARight.Rotations));
  if not Result then Exit;
  for Index := 0 to High(ALeft.Rotations) do
    if ALeft.Rotations[Index] <> ARight.Rotations[Index] then Exit(False);
end;

procedure MergeRegistryConsumerState(const AIdentity, ATrustKeyId: string;
  const AState: TLWPTRegistryConsumerState;
  const ARotations: TLWPTRegistryRotationProofArray;
  const AHistory: TLWPTRegistryDocumentArray);
begin
  MergeRegistryConsumerStateAt(RegistryStateRoot, AIdentity, ATrustKeyId,
    AState, ARotations, AHistory);
end;

function StateLeaseWaitMilliseconds: QWord;
begin
  Result := RegistryStateLeaseWaitMilliseconds;
  {$IFDEF INSTALL_TESTING}
  if TestSeamValue('REGISTRY_STATE_LEASE_MS') <> '' then
    Result := StrToIntDef(TestSeamValue('REGISTRY_STATE_LEASE_MS'), 0);
  {$ENDIF}
end;

procedure MergeRegistryConsumerStateAt(const ARoot, AIdentity, ATrustKeyId: string;
  const AState: TLWPTRegistryConsumerState;
  const ARotations: TLWPTRegistryRotationProofArray;
  const AHistory: TLWPTRegistryDocumentArray);
var
  Root, Path: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Current, Merged: TLWPTRegistryConsumerState;
  StartedAt: QWord;
  Index: Integer;

  procedure StoreDocument(const ABytes: TBytes);
  var DocumentPath: string;
  begin
    DocumentPath := RegistryStateDocumentPath(Root, SHA256BytesPrefixed(ABytes));
    if FileExists(DocumentPath) then Exit;
    ForceDirectories(ExtractFileDir(DocumentPath));
    AtomicWriteBytes(DocumentPath, Root + '/tmp', ABytes);
  end;

begin
  if AState.State.Sequence < 1 then Exit;
  Root := ExcludeTrailingPathDelimiter(ARoot);
  Path := RegistryStatePathAt(Root, AIdentity, ATrustKeyId);
  ForceDirectories(Root + '/locks');
  ForceDirectories(Root + '/tmp');
  Coordinator := TLWPTProducerLeaseCoordinator.Create(Root + '/locks');
  Lease := nil;
  try
    StartedAt := GetTickCount64;
    repeat
      Lease := Coordinator.TryAcquire('registry-state:' + ExtractFileName(Path),
        'registry consumer state for ' + AIdentity);
      if Assigned(Lease) then Break;
      if GetTickCount64 - StartedAt > StateLeaseWaitMilliseconds then
        raise ELWPTRegistryError.CreateStable('registry_state_locked',
          'another process holds the per-user registry state for ' + AIdentity);
      Sleep(PRODUCER_LEASE_POLL_MILLISECONDS);
    until False;
    {$IFDEF INSTALL_TESTING}
    if (TestSeamValue('FAIL_REGISTRY_STATE_WRITE') = '1')
       or (TestSeamValue('FAIL_REGISTRY_STATE_WRITE') = AIdentity) then
      raise ELWPTRegistryError.CreateStable('registry_state_write_failed',
        'injected per-user registry state write failure');
    {$ENDIF}
    for Index := 0 to High(ARotations) do
    begin
      StoreDocument(ARotations[Index].Document);
      StoreDocument(ARotations[Index].OldSignature);
      StoreDocument(ARotations[Index].NewSignature);
    end;
    { The verified snapshots and records let a later acquisition classify
      a lagging contact that lacks newer history, as the mirror does with
      its retained proof. }
    for Index := 0 to High(AHistory) do
      StoreDocument(AHistory[Index].Bytes);
    Merged := AState;
    Merged.State.Origin := AIdentity;
    Current := Default(TLWPTRegistryConsumerState);
    if LoadRegistryConsumerStateAt(Root, AIdentity, ATrustKeyId, Current) then
      Merged := MergeRegistryAcceptedStates(Current, AState)
    else
      Merged.State.ClockFloor := RegistryLaterTimestamp(
        Merged.State.ClockFloor, Merged.State.PublishedAt);
    if FileExists(Path) and RegistryAcceptedStatesEqual(Current, Merged) then
      Exit;
    ForceDirectories(ExtractFileDir(Path));
    AtomicWriteBytes(Path, Root + '/tmp', StateDocument(AIdentity,
      ATrustKeyId, Merged));
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Lock tables
  --------------------------------------------------------------------------- }

function LoadRegistryLockTables(const APath: string;
  const AAcceptSchemaV3: Boolean): TLWPTRegistryLockTableArray;
var
  Lines: TStringList;
  Parser: TTOMLParser;
  Root, Tables, Entry: TTOMLNode;
  Pair: TTOMLNodeMap.TKeyValuePair;
  Table: TLWPTRegistryLockTable;
  Index: Integer;
begin
  Result := nil;
  if not FileExists(APath) then Exit;
  Lines := TStringList.Create;
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    Lines.LoadFromFile(APath);
    try
      Root := Parser.ParseDocument(Lines.Text);
    except
      on E: ETOMLParseError do Exit;
    end;
    { The shared lock schema gate (ADR-0052). }
    CheckLockfileSchema(Root, APath, AAcceptSchemaV3);
    Tables := TomlGet(Root, 'registry');
    if not TomlIsTable(Tables) then Exit;
    for Pair in Tables.Children do
    begin
      Entry := Pair.Value;
      if not TomlIsTable(Entry) then Continue;
      Table := Default(TLWPTRegistryLockTable);
      Table.Identity := Pair.Key;
      Table.TrustKeyId := TomlStr(Entry, 'trustKeyId', '');
      Table.KeyId := TomlStr(Entry, 'keyId', '');
      Table.Sequence := TomlInt(Entry, 'sequence', 0);
      Table.Snapshot := TomlStr(Entry, 'snapshot', '');
      Table.Checkpoint := TomlStr(Entry, 'checkpoint', '');
      Table.Signature := TomlStr(Entry, 'signature', '');
      Table.PublishedAt := TomlStr(Entry, 'publishedAt', '');
      Table.ExpiresAt := TomlStr(Entry, 'expiresAt', '');
      ReadList(Entry, 'rotations', Table.Rotations);
      Table.Accepted.State.Origin := Table.Identity;
      Table.Accepted.State.Sequence := TomlInt(Entry, 'acceptedSequence', 0);
      Table.Accepted.State.Snapshot := TomlStr(Entry, 'acceptedSnapshot', '');
      Table.Accepted.State.CheckpointHash := TomlStr(Entry, 'acceptedCheckpoint', '');
      Table.Accepted.State.KeyId := TomlStr(Entry, 'acceptedKeyId', '');
      Table.Accepted.State.PublishedAt := TomlStr(Entry, 'acceptedPublishedAt', '');
      Table.Accepted.State.ExpiresAt := TomlStr(Entry, 'acceptedExpiresAt', '');
      Table.Accepted.State.ClockFloor := TomlStr(Entry, 'clockFloor', '');
      ReadList(Entry, 'acceptedRotations', Table.Accepted.Rotations);
      { Unsigned project state that is incomplete grants nothing: it is
        ignored as a prior rather than trusted partially. }
      if (Table.Accepted.State.Sequence < 1)
         or not RegistryHashIsCanonical(Table.Accepted.State.Snapshot)
         or not RegistryHashIsCanonical(Table.Accepted.State.CheckpointHash)
         or not RegistryTimestampIsCanonical(Table.Accepted.State.PublishedAt)
         or not RegistryTimestampIsCanonical(Table.Accepted.State.ExpiresAt)
         or not RegistryTimestampIsCanonical(Table.Accepted.State.ClockFloor) then
        Table.Accepted := Default(TLWPTRegistryConsumerState);
      Index := Length(Result);
      SetLength(Result, Index + 1);
      Result[Index] := Table;
    end;
  finally
    Root.Free;
    Parser.Free;
    Lines.Free;
  end;
end;

procedure RenderRegistryLockTables(const ATables: TLWPTRegistryLockTableArray;
  ALines: TStrings);
var
  Order: TStringList;
  Index, TableIndex: Integer;
  Table: TLWPTRegistryLockTable;

  procedure KV(const AKey, AValue: string);
  begin
    ALines.Add(AKey + ' = "' + TomlEscape(AValue) + '"');
  end;

begin
  Order := TStringList.Create;
  try
    Order.CaseSensitive := True;
    for Index := 0 to High(ATables) do
      Order.AddObject(ATables[Index].Identity, TObject(PtrInt(Index)));
    Order.Sort;
    for Index := 0 to Order.Count - 1 do
    begin
      TableIndex := PtrInt(Order.Objects[Index]);
      Table := ATables[TableIndex];
      ALines.Add('');
      ALines.Add('[registry."' + TomlEscape(Table.Identity) + '"]');
      KV('trustKeyId', Table.TrustKeyId);
      KV('keyId', Table.KeyId);
      ALines.Add('sequence = ' + IntToStr(Table.Sequence));
      KV('snapshot', Table.Snapshot);
      KV('checkpoint', Table.Checkpoint);
      KV('signature', Table.Signature);
      KV('publishedAt', Table.PublishedAt);
      KV('expiresAt', Table.ExpiresAt);
      ALines.Add('rotations = ' + QuoteList(Table.Rotations));
      ALines.Add('acceptedSequence = ' + IntToStr(Table.Accepted.State.Sequence));
      KV('acceptedSnapshot', Table.Accepted.State.Snapshot);
      KV('acceptedCheckpoint', Table.Accepted.State.CheckpointHash);
      KV('acceptedKeyId', Table.Accepted.State.KeyId);
      KV('acceptedPublishedAt', Table.Accepted.State.PublishedAt);
      KV('acceptedExpiresAt', Table.Accepted.State.ExpiresAt);
      ALines.Add('acceptedRotations = ' + QuoteList(Table.Accepted.Rotations));
      KV('clockFloor', Table.Accepted.State.ClockFloor);
    end;
  finally
    Order.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Contact acquisition
  --------------------------------------------------------------------------- }

type
  { One contact's requests share one attempt deadline and the contact's
    destination policy. }
  TLWPTConsumerAcquisition = class(TLWPTRegistryAcquisition)
  protected
    function RequestTimeoutMilliseconds: QWord; override;
    function Destination: THTTPDestinationPolicy; override;
  public
    Deadline: QWord;
  end;

  TLWPTConsumerDocumentSource = class(TLWPTRegistryDocumentSource)
  public
    API, StateRoot, ArchivesRoot: string;
    Policy: THTTPDestinationPolicy;
    Deadline: QWord;
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; override;
    procedure CheckProgress; override;
  end;

function RemainingMilliseconds(const ADeadline: QWord): QWord;
var Now: QWord;
begin
  Now := GetTickCount64;
  if Now >= ADeadline then
    raise ELWPTRegistryError.CreateStable(RegistryTransportFailedCode,
      'contact attempt exceeded its time budget');
  Result := ADeadline - Now;
  if Result > RegistryRequestTimeoutMilliseconds then
    Result := RegistryRequestTimeoutMilliseconds;
end;

function TLWPTConsumerAcquisition.RequestTimeoutMilliseconds: QWord;
begin
  Result := RemainingMilliseconds(Deadline);
end;

function TLWPTConsumerAcquisition.Destination: THTTPDestinationPolicy;
begin
  Result := RegistryContactDestination(Contact);
end;

function TLWPTConsumerDocumentSource.ReadDocument(const APath: string;
  const AMaximumBytes: Int64): TBytes;
var Kind: string;
begin
  if StartsStr('snapshots/sha256/', APath) then Kind := 'snapshot'
  else if StartsStr('records/sha256/', APath) then Kind := 'package'
  else
    raise ELWPTRegistryError.CreateStable('invalid_resource_path',
      'unexpected proof resource');
  { Authenticated history retained locally is consulted first; the
    verifier hashes every document again. }
  Result := ReadLocalRegistryDocument(StateRoot, ArchivesRoot, 'sha256:'
    + Copy(APath, Pos('/sha256/', APath) + Length('/sha256/'), 64), AMaximumBytes);
  if Result <> nil then Exit;
  Result := GetRegistryDocument(API + '/' + APath, RegistryMediaType(Kind),
    AMaximumBytes, RemainingMilliseconds(Deadline), Policy);
end;

procedure TLWPTConsumerDocumentSource.CheckProgress;
begin
  RemainingMilliseconds(Deadline);
end;

function IdentityIsAcceptable(const AIdentity: string): Boolean;
begin
  if RegistryURIIsCanonical(AIdentity, False) then Exit(True);
  Result := AllowLocalhostContacts and IsLocalhostHTTP(AIdentity)
    and RegistryURIIsCanonical(AIdentity, True);
end;

constructor TLWPTRegistrySession.Create(AOwner: TLWPTRegistryConsumer;
  const ADeclaration: TLWPTRegistryDeclaration;
  const ALockTables: TLWPTRegistryLockTableArray);
begin
  inherited Create;
  FOwner := AOwner;
  FDeclaration := ADeclaration;
  FIdentity := ADeclaration.Identity;
  FLockTables := ALockTables;
  FConstraints := TStringList.Create;
end;

destructor TLWPTRegistrySession.Destroy;
begin
  FConstraints.Free;
  inherited Destroy;
end;

procedure TLWPTRegistrySession.MarkAmbiguous(const AMessage: string);
begin
  FLockAmbiguity := AMessage;
end;

procedure TLWPTRegistrySession.SetLockedIdentity(const AIdentity: string);
begin
  if AIdentity <> '' then
  begin
    FOwner.RequireUniqueIdentity(Self, AIdentity);
    RequireConstraints(AIdentity);
  end;
  FLockedIdentity := AIdentity;
end;

procedure TLWPTRegistrySession.RequireConstraints(const AIdentity: string);
var Index: Integer;
begin
  for Index := 0 to FConstraints.Count - 1 do
    if FConstraints.Names[Index] <> AIdentity then
      raise EManifestError.CreateFmt(
        'workspace member "%s" declares [registries.%s] with identity %s, '
        + 'but the root registry resolves to %s; an alias shared with the '
        + 'root must name the same identity and pin',
        [FConstraints.ValueFromIndex[Index], FDeclaration.Alias,
         FConstraints.Names[Index], AIdentity]);
end;

procedure TLWPTRegistrySession.RequireIdentity(const AIdentity, AMember: string);
var Known: string;
begin
  FConstraints.Add(AIdentity + '=' + AMember);
  Known := FIdentity;
  if Known = '' then Known := FLockedIdentity;
  if Known <> '' then RequireConstraints(Known);
end;

{ The exact rotation chain of an accepted state, from the per-user document
  store or the committed proofs, within the verifier's limits. }
function TLWPTRegistrySession.AcceptedChain(const AHashes: TStringArray;
  out AChain: TLWPTRegistryRotationProofArray): Boolean;
begin
  Result := LoadRegistryRotationChain(RegistryStateRoot, FOwner.ArchivesRoot,
    AHashes, DefaultRegistryVerificationLimits, AChain);
end;

{ True when ALeft's hashes are a prefix of ARight's. }
function RotationPrefix(const ALeft, ARight: TStringArray): Boolean;
var Index: Integer;
begin
  Result := Length(ALeft) <= Length(ARight);
  if not Result then Exit;
  for Index := 0 to High(ALeft) do
    if ALeft[Index] <> ARight[Index] then Exit(False);
end;

function TLWPTRegistrySession.Trust: TLWPTRegistryTrust;
begin
  Result.Origin := FIdentity;
  if Result.Origin = '' then Result.Origin := FLockedIdentity;
  Result.KeyId := FDeclaration.KeyId;
  Result.PublicKey := FDeclaration.PublicKey;
end;

function TLWPTRegistrySession.Contacts: TStringArray;
var Index: Integer;

  procedure Add(const AValue: string);
  var Existing: Integer;
  begin
    for Existing := 0 to High(Result) do
      if Result[Existing] = AValue then Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := AValue;
  end;

begin
  Result := nil;
  for Index := 0 to High(FDeclaration.Mirrors) do Add(FDeclaration.Mirrors[Index]);
  Add(FDeclaration.Origin);
end;

function TLWPTRegistrySession.LockTableFor(const AIdentity: string;
  out ATable: TLWPTRegistryLockTable): Boolean;
var Index: Integer;
begin
  for Index := 0 to High(FLockTables) do
    if (FLockTables[Index].Identity = AIdentity)
       and (FLockTables[Index].TrustKeyId = FDeclaration.KeyId) then
    begin
      ATable := FLockTables[Index];
      Exit(True);
    end;
  ATable := Default(TLWPTRegistryLockTable);
  Result := False;
end;

{ The head must extend every recorded state: its verified history holds
  that snapshot at that sequence. }
procedure RequireOnHistory(const AVerified: TLWPTVerifiedRegistry;
  const ASequence: Int64; const ASnapshot, AWhat: string);
var
  Document: TLWPTRegistryDocument;
  Parser: TTOMLParser;
  Root: TTOMLNode;
  Found: Boolean;
begin
  if ASequence < 1 then Exit;
  if ASequence = AVerified.State.Sequence then
  begin
    if ASnapshot <> AVerified.State.Snapshot then
      raise ELWPTRegistryError.CreateStable('checkpoint_equivocation',
        'the verified head contradicts the ' + AWhat);
    Exit;
  end;
  if ASequence > AVerified.State.Sequence then
    raise ELWPTRegistryError.CreateStable('checkpoint_equivocation',
      'the verified head is older than the ' + AWhat);
  Found := False;
  for Document in AVerified.Documents do
    if Document.Path = 'snapshots/sha256/' + RegistryDigestHex(ASnapshot) + '.toml' then
    begin
      Parser := TTOMLParser.Create;
      try
        Root := Parser.ParseDocument(RegistryBytesText(Document.Bytes));
        try
          Found := TomlInt(Root, 'sequence', -1) = ASequence;
        finally
          Root.Free;
        end;
      finally
        Parser.Free;
      end;
      Break;
    end;
  if not Found then
    raise ELWPTRegistryError.CreateStable('checkpoint_equivocation',
      'the verified head does not extend the ' + AWhat);
end;

procedure TLWPTRegistrySession.AcquireFrom(const AContact, ANow: string);
var
  Budget: TLWPTRegistryMetadataBudget;
  Acquisition: TLWPTConsumerAcquisition;
  Source: TLWPTConsumerDocumentSource;
  Candidate: string;
  UserState, LockState, Prior: TLWPTRegistryConsumerState;
  Table: TLWPTRegistryLockTable;
  HasTable: Boolean;
  TrustRoot: TLWPTRegistryTrust;
  Rotation: TLWPTUntrustedRegistryRotation;
  Index: Integer;
  Head: TLWPTVerifiedRegistry;
  Chain: TLWPTRegistryRotationProofArray;
  VerifyNow: string;
begin
  Budget := TLWPTRegistryMetadataBudget.Create(DefaultRegistryVerificationLimits);
  Acquisition := TLWPTConsumerAcquisition.Create(Budget);
  Source := nil;
  try
    Acquisition.Deadline := GetTickCount64 + RegistryContactAttemptMilliseconds;
    Acquisition.Contact := AContact;
    { A declaration without identity accepts the advertised one; a locked
      advertised identity is compared below for its actionable diagnostic. }
    Acquisition.Identity := FDeclaration.Identity;
    Acquisition.TrustKeyId := FDeclaration.KeyId;
    Acquisition.TrustPublicKey := FDeclaration.PublicKey;
    Acquisition.PriorSequence := 0;
    Acquisition.AlwaysFetchRootKey := False;
    Acquisition.Acquire;
    Candidate := Acquisition.Identity;
    if FDeclaration.Identity = '' then
    begin
      FOwner.RequireUniqueIdentity(Self, Candidate);
      RequireConstraints(Candidate);
      if not IdentityIsAcceptable(Candidate) then
        raise ELWPTRegistryError.CreateStable('registry_identity_invalid',
          '[registries.' + FDeclaration.Alias + '] contact ' + AContact
          + ' advertises origin "' + Candidate + '", which is not a canonical '
          + 'https identity');
      if (FLockedIdentity <> '') and (Candidate <> FLockedIdentity) then
        raise ELWPTRegistryError.CreateStable('registry_identity_changed',
          '[registries.' + FDeclaration.Alias + '] contact ' + AContact
          + ' now advertises origin ' + Candidate + ', but '
          + LWPT.Core.LOCKFILE + ' records ' + FLockedIdentity
          + '; an advertised identity is never replaced. Declare identity = "'
          + FLockedIdentity + '" (or the intended origin) in [registries.'
          + FDeclaration.Alias + ']');
    end;
    { The prior is the newer of per-user state and the lock's recorded
      accepted state for this identity and pin. }
    UserState := Default(TLWPTRegistryConsumerState);
    LoadRegistryConsumerState(Candidate, FDeclaration.KeyId, UserState);
    LockState := Default(TLWPTRegistryConsumerState);
    HasTable := LockTableFor(Candidate, Table);
    if HasTable then LockState := Table.Accepted;
    Prior := MergeRegistryAcceptedStates(UserState, LockState);
    if Prior.State.Sequence > 0 then
    begin
      Prior.State.Origin := Candidate;
      { A clock behind accepted state is local; no contact can satisfy it. }
      RequireRegistryClockAtFloor(ANow, RegistryLaterTimestamp(
        Prior.State.ClockFloor, Prior.State.PublishedAt));
      { Supply the authenticated accepted chain, as the mirror does, so an
        older checkpoint signed by an earlier key is judged stale against
        it. A contact's own chain replaces it only when it extends it. }
      if AcceptedChain(Prior.Rotations, Chain)
         and RotationPrefix(RegistryRotationHashes(Acquisition.Proof.Rotations),
           Prior.Rotations) then
        Acquisition.Proof.Rotations := Chain;
      if Prior.State.KeyId = FDeclaration.KeyId then
        Prior.State.PublicKey := FDeclaration.PublicKey
      else if Prior.State.PublicKey = '' then
        for Index := 0 to High(Acquisition.Proof.Rotations) do
        begin
          Rotation := InspectRegistryRotation(Acquisition.Proof.Rotations[Index].Document);
          if Rotation.ToKey = Prior.State.KeyId then
            Prior.State.PublicKey := Rotation.ToPublicKey;
        end;
    end;
    TrustRoot.Origin := Candidate;
    TrustRoot.KeyId := FDeclaration.KeyId;
    TrustRoot.PublicKey := FDeclaration.PublicKey;
    Source := TLWPTConsumerDocumentSource.Create;
    Source.API := Acquisition.Discovery.API;
    Source.StateRoot := RegistryStateRoot;
    Source.ArchivesRoot := FOwner.ArchivesRoot;
    Source.Policy := RegistryContactDestination(AContact);
    Source.Deadline := Acquisition.Deadline;
    { Freshness is judged when the proof is verified, not when the install
      started: requests to this and earlier contacts take time. }
    VerifyNow := RegistryTimestampNow;
    Head := VerifyRegistryProof(Acquisition.Proof, TrustRoot, Prior.State,
      VerifyNow, rvmAcquire, Source, DefaultRegistryVerificationLimits);
    { Every recorded state must lie on the verified history: the older of
      the two priors and the lock's selection proof. }
    RequireOnHistory(Head, UserState.State.Sequence, UserState.State.Snapshot,
      'per-user accepted state');
    RequireOnHistory(Head, LockState.State.Sequence, LockState.State.Snapshot,
      'accepted state recorded in ' + LWPT.Core.LOCKFILE);
    if HasTable then
      RequireOnHistory(Head, Table.Sequence, Table.Snapshot,
        'selection proof recorded in ' + LWPT.Core.LOCKFILE);
    FIdentity := Candidate;
    FVerified := Head;
    FProofRotations := Head.Proof.Rotations;
    FAccepted.State := Head.State;
    FAccepted.Rotations := RegistryRotationHashes(Head.Proof.Rotations);
    { The merged maximum carries the floor forward even when the head's own
      publication time is earlier than an accepted one. }
    FAccepted := MergeRegistryAcceptedStates(Prior, FAccepted);
    FUserAccepted.State := Head.State;
    FUserAccepted.State.ClockFloor := Head.State.PublishedAt;
    FUserAccepted.Rotations := RegistryRotationHashes(Head.Proof.Rotations);
    FUserAccepted := MergeRegistryAcceptedStates(UserState, FUserAccepted);
    FAPI := Acquisition.Discovery.API;
    FContact := AContact;
    FAcquired := True;
  finally
    Source.Free;
    Acquisition.Free;
    Budget.Free;
  end;
end;

procedure TLWPTRegistrySession.Acquire;
var
  ContactList: TStringArray;
  Index, StaleCount, RequestCount: Integer;
  Now, Known: string;
  UserState: TLWPTRegistryConsumerState;
  Table: TLWPTRegistryLockTable;
  Floor: string;
begin
  if FAttempted then Exit;
  if FOwner.NetworkFree then
    raise ELWPTRegistryError.CreateStable('registry_network_forbidden',
      'registry ' + FDeclaration.Alias + ' cannot be acquired: network-free '
      + 'verification never selects a contact');
  if FLockAmbiguity <> '' then
    raise EManifestError.Create(FLockAmbiguity);
  FAttempted := True;
  Now := RegistryTimestampNow;
  { With a known identity the floor is checked before any request. }
  if FIdentity <> '' then Known := FIdentity else Known := FLockedIdentity;
  if Known <> '' then
  begin
    Floor := '';
    if LoadRegistryConsumerState(Known, FDeclaration.KeyId, UserState) then
      Floor := RegistryLaterTimestamp(UserState.State.ClockFloor,
        UserState.State.PublishedAt);
    if LockTableFor(Known, Table) and (Table.Accepted.State.Sequence > 0) then
      Floor := RegistryLaterTimestamp(Floor, RegistryLaterTimestamp(
        Table.Accepted.State.ClockFloor, Table.Accepted.State.PublishedAt));
    RequireRegistryClockAtFloor(Now, Floor);
  end;
  ContactList := Contacts;
  StaleCount := 0;
  RequestCount := 0;
  FFailures := '';
  for Index := 0 to High(ContactList) do
  begin
    WriteLn('  acquiring registry ', FDeclaration.Alias, ' from ',
      ContactList[Index], '...');
    try
      AcquireFrom(ContactList[Index], Now);
      WriteLn('  verified ', FIdentity, ' at sequence ',
        FVerified.State.Sequence, ' through ', ContactList[Index]);
      Exit;
    except
      on E: ELWPTRegistryStaleContactError do
      begin
        Inc(StaleCount);
        FFailures := FFailures + LineEnding + '  ' + ContactList[Index]
          + ': stale: ' + E.Message;
        WriteLn(ErrOutput, 'warning: registry contact ', ContactList[Index],
          ' is stale: ', E.Message, '; trying the next contact');
      end;
      on E: Exception do
      begin
        if not IsRegistryTransportFailure(E) then
          raise ELWPTRegistryError.Create('registry ' + FDeclaration.Alias
            + ' contact ' + ContactList[Index] + ' failed verification: '
            + E.Message + '. A trust failure never tries another contact.');
        Inc(RequestCount);
        FFailures := FFailures + LineEnding + '  ' + ContactList[Index]
          + ': unreachable: ' + E.Message;
        WriteLn(ErrOutput, 'warning: registry contact ', ContactList[Index],
          ' is unreachable: ', E.Message);
      end;
    end;
  end;
  if StaleCount > 0 then
    raise ELWPTRegistryStaleContactError.CreateStable('registry_contacts_stale',
      'no contact for registry ' + FDeclaration.Alias
      + ' served acceptable current state:' + FFailures);
  FUnreachable := True;
end;

function TLWPTRegistrySession.ArchiveURL(const APackage: TLWPTRegistryPackage): string;
begin
  Result := FAPI + '/objects/sha256/' + RegistryDigestHex(APackage.ArchiveHash);
end;

function TLWPTRegistrySession.FetchArchive(
  const APackage: TLWPTRegistryPackage): TBytes;
var
  Stream: TBytesStream;
  Timeout: QWord;
begin
  if not FAcquired then
    raise ELWPTRegistryError.CreateStable('registry_not_acquired',
      'registry ' + FDeclaration.Alias + ' has no verified contact');
  if (APackage.ArchiveSize < 0)
     or (APackage.ArchiveSize > RegistryMaximumArchiveBytes) then
    raise ELWPTRegistryError.CreateStable('registry_archive_limit_exceeded',
      'archive of ' + APackage.Name + '@' + APackage.Version
      + ' exceeds the 256 MiB archive limit');
  Timeout := RegistryArchiveRequestMilliseconds;
  { Archive fetching never switches to another contact. }
  Result := GetRegistryDocument(ArchiveURL(APackage), 'application/gzip',
    APackage.ArchiveSize, Timeout, RegistryContactDestination(FContact));
  Stream := TBytesStream.Create(Result);
  try
    VerifyRegistryArtifact(APackage, Stream);
  finally
    Stream.Free;
  end;
end;

function TLWPTRegistrySession.DocumentBytes(const APath: string;
  out ABytes: TBytes): Boolean;
var Document: TLWPTRegistryDocument;
begin
  for Document in FVerified.Documents do
    if Document.Path = APath then
    begin
      ABytes := Document.Bytes;
      Exit(True);
    end;
  ABytes := nil;
  Result := False;
end;

{ ---------------------------------------------------------------------------
  Consumer
  --------------------------------------------------------------------------- }

constructor TLWPTRegistryConsumer.Create(const ARoot: TManifest;
  const ALockTables: TLWPTRegistryLockTableArray;
  const AArchivesRoot: string);
begin
  inherited Create;
  FRoot := ARoot;
  FLockTables := ALockTables;
  FArchivesRoot := AArchivesRoot;
  FSessions := TList.Create;
end;

procedure TLWPTRegistryConsumer.RequireUniqueIdentity(
  ASession: TLWPTRegistrySession; const AIdentity: string);
var Index: Integer; Other: TLWPTRegistrySession; Alias: string;
begin
  Alias := '';
  for Index := 0 to High(FRoot.Registries) do
    if (FRoot.Registries[Index].Alias <> ASession.Alias)
       and (FRoot.Registries[Index].Identity = AIdentity) then
      Alias := FRoot.Registries[Index].Alias;
  for Index := 0 to FSessions.Count - 1 do
  begin
    Other := SessionAt(Index);
    if (Other <> ASession) and ((Other.Identity = AIdentity)
       or (Other.LockedIdentity = AIdentity)) then
      Alias := Other.Alias;
  end;
  if Alias <> '' then
    raise EManifestError.CreateFmt(
      'registries %s and %s both resolve to origin %s; one origin may be '
      + 'declared under only one alias. Declare distinct identities or '
      + 'remove one alias', [Alias, ASession.Alias, AIdentity]);
end;

procedure TLWPTRegistryConsumer.RecheckFreshness;
var Index: Integer; Session: TLWPTRegistrySession; Now: string;
begin
  Now := RegistryTimestampNow;
  for Index := 0 to FSessions.Count - 1 do
  begin
    Session := SessionAt(Index);
    if not Session.Acquired then Continue;
    RequireRegistryClockAtFloor(Now, RegistryLaterTimestamp(
      Session.Accepted.State.ClockFloor, Session.Accepted.State.PublishedAt));
    if Session.Verified.ExpiresAt <= Now then
      raise ELWPTRegistryStaleContactError.CreateStable('checkpoint_expired',
        'the checkpoint of ' + Session.Identity + ' verified through '
        + Session.Contact + ' expired at ' + Session.Verified.ExpiresAt
        + ' before the install could publish; nothing was published. Run '
        + 'the install again');
  end;
end;

{ Origins persist one after another. When a later origin fails, earlier
  origins' advances and every admitted document remain: they are
  authenticated and monotonic, and undoing them could lower state another
  concurrent install already relies on. The install still fails and rolls
  project state back (see MergeRegistryConsumerStateAt). }
procedure TLWPTRegistryConsumer.PersistAcceptedState;
var
  Index, Count: Integer;
  Session: TLWPTRegistrySession;
  Documents: TLWPTRegistryDocumentArray;
begin
  for Index := 0 to FSessions.Count - 1 do
  begin
    Session := SessionAt(Index);
    if not Session.Acquired then Continue;
    { The checkpoint and its signature join the verified history, so
      --offline can restore every committed proof document by hash. }
    Documents := Copy(Session.Verified.Documents);
    Count := Length(Documents);
    SetLength(Documents, Count + 2);
    Documents[Count].Path := 'checkpoint';
    Documents[Count].Bytes := Session.Verified.Proof.Checkpoint;
    Documents[Count + 1].Path := 'signature';
    Documents[Count + 1].Bytes := Session.Verified.Proof.Signature;
    try
      MergeRegistryConsumerState(Session.Identity, Session.Declaration.KeyId,
        Session.UserAccepted, Session.ProofRotations, Documents);
    except
      on E: Exception do
        raise ELWPTRegistryError.CreateStable('registry_state_not_persisted',
          'per-user registry state for ' + Session.Identity + ' in '
          + RegistryStateRoot + ' could not be updated (' + E.Message
          + '); nothing was published, because this state is the only '
          + 'record of the accepted high-water mark when ' + LWPT.Core.LOCKFILE
          + ' does not change. Fix the state directory or set '
          + REGISTRY_STATE_DIR_ENV + ', then run the install again');
    end;
  end;
end;

destructor TLWPTRegistryConsumer.Destroy;
var Index: Integer;
begin
  for Index := 0 to FSessions.Count - 1 do
    TLWPTRegistrySession(FSessions[Index]).Free;
  FSessions.Free;
  inherited Destroy;
end;

function TLWPTRegistryConsumer.SessionAt(AIndex: Integer): TLWPTRegistrySession;
begin
  Result := TLWPTRegistrySession(FSessions[AIndex]);
end;

function TLWPTRegistryConsumer.Count: Integer;
begin
  Result := FSessions.Count;
end;

function TLWPTRegistryConsumer.SessionForAlias(
  const AAlias: string): TLWPTRegistrySession;
var
  Index: Integer;
  Declaration: TLWPTRegistryDeclaration;
begin
  for Index := 0 to FSessions.Count - 1 do
    if SessionAt(Index).Alias = AAlias then Exit(SessionAt(Index));
  if not FindRegistryDeclaration(FRoot.Registries, AAlias, Declaration) then
    raise EManifestError.CreateFmt(
      'registry alias "%s" is not declared; add [registries.%s] with its '
      + 'identity and key to the root %s', [AAlias, AAlias, MANIFEST_FILE]);
  Result := TLWPTRegistrySession.Create(Self, Declaration, FLockTables);
  FSessions.Add(Result);
end;

function TLWPTRegistryConsumer.SessionForIdentity(const AIdentity,
  ADependency, ARequiredBy, ARequirerOrigin: string): TLWPTRegistrySession;
var
  Index: Integer;
  Session: TLWPTRegistrySession;
begin
  for Index := 0 to High(FRoot.Registries) do
  begin
    Session := SessionForAlias(FRoot.Registries[Index].Alias);
    if (Session.Identity = AIdentity)
       or ((Session.Identity = '') and (Session.LockedIdentity = AIdentity)) then
      Exit(Session);
  end;
  { An advertised identity may be established by acquiring a declaration
    that omits it; network-free modes only use the lock's bindings. }
  for Index := 0 to High(FRoot.Registries) do
  begin
    Session := SessionForAlias(FRoot.Registries[Index].Alias);
    if not FNetworkFree and (Session.Declaration.Identity = '')
       and not Session.Attempted then
    begin
      Session.Acquire;
      if Session.Identity = AIdentity then Exit(Session);
    end;
  end;
  raise EManifestError.CreateFmt(
    '"%s" is required by %s from %s, but origin %s is not declared; add a '
    + '[registries.<alias>] with its identity and key to the root %s',
    [ADependency, ARequiredBy, ARequirerOrigin, AIdentity, MANIFEST_FILE]);
end;

end.
