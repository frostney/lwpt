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

  TLWPTRegistrySession = class
  private
    FDeclaration: TLWPTRegistryDeclaration;
    FIdentity, FLockedIdentity: string;
    FAttempted, FAcquired, FUnreachable: Boolean;
    FVerified: TLWPTVerifiedRegistry;
    FAPI, FContact, FFailures: string;
    FAccepted: TLWPTRegistryConsumerState;
    FProofRotations: TLWPTRegistryRotationProofArray;
    FLockTables: TLWPTRegistryLockTableArray;
    function Contacts: TStringArray;
    function LockTableFor(const AIdentity: string;
      out ATable: TLWPTRegistryLockTable): Boolean;
    procedure AcquireFrom(const AContact, ANow: string);
  public
    constructor Create(const ADeclaration: TLWPTRegistryDeclaration;
      const ALockTables: TLWPTRegistryLockTableArray);
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
    property LockedIdentity: string read FLockedIdentity write FLockedIdentity;
    property Attempted: Boolean read FAttempted;
    property Acquired: Boolean read FAcquired;
    property Unreachable: Boolean read FUnreachable;
    property Failures: string read FFailures;
    property Verified: TLWPTVerifiedRegistry read FVerified;
    property Accepted: TLWPTRegistryConsumerState read FAccepted;
    property ProofRotations: TLWPTRegistryRotationProofArray read FProofRotations;
    property Contact: string read FContact;
  end;

  { Every session of one install, keyed by alias. }
  TLWPTRegistryConsumer = class
  private
    FRoot: TManifest;
    FSessions: TList;
    FLockTables: TLWPTRegistryLockTableArray;
    function SessionAt(AIndex: Integer): TLWPTRegistrySession;
  public
    constructor Create(const ARoot: TManifest;
      const ALockTables: TLWPTRegistryLockTableArray);
    destructor Destroy; override;
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
{ False when no state exists. Corrupt state raises, naming the file; it is
  never reset, because a reset would lower the clock floor. }
function LoadRegistryConsumerState(const AIdentity, ATrustKeyId: string;
  out AState: TLWPTRegistryConsumerState): Boolean;
{ Merges AState into the per-user file under a producer lease. The sequence
  and floor never go down. }
procedure MergeRegistryConsumerState(const AIdentity, ATrustKeyId: string;
  const AState: TLWPTRegistryConsumerState);
{ The newer of two accepted states; the floor is the later of both. }
function MergeRegistryAcceptedStates(const ALeft,
  ARight: TLWPTRegistryConsumerState): TLWPTRegistryConsumerState;
function RegistryAcceptedStatesEqual(const ALeft,
  ARight: TLWPTRegistryConsumerState): Boolean;
function RegistryRotationHashes(
  const ARotations: TLWPTRegistryRotationProofArray): TStringArray;
function LoadRegistryLockTables(const APath: string): TLWPTRegistryLockTableArray;
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

function RegistryStateRoot: string;
var Configured: string;
begin
  Configured := SysUtils.GetEnvironmentVariable(REGISTRY_STATE_DIR_ENV);
  if Configured <> '' then
    Exit(ExcludeTrailingPathDelimiter(ExpandFileName(Configured)));
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(
    IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'registry'));
end;

function RegistryStatePath(const AIdentity, ATrustKeyId: string): string;
begin
  Result := IncludeTrailingPathDelimiter(RegistryStateRoot) + 'origins/'
    + SHA256Hex(BytesOf(AIdentity + #10 + ATrustKeyId)) + '.toml';
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
var
  Path, Text: string;
  Stream: TFileStream;
  Parser: TTOMLParser;
  Root: TTOMLNode;
  Sequence: Int64;
begin
  AState := Default(TLWPTRegistryConsumerState);
  Path := RegistryStatePath(AIdentity, ATrustKeyId);
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
  const AState: TLWPTRegistryConsumerState);
var
  Root, Path: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Current, Merged: TLWPTRegistryConsumerState;
  StartedAt: QWord;
begin
  if AState.State.Sequence < 1 then Exit;
  Root := RegistryStateRoot;
  Path := RegistryStatePath(AIdentity, ATrustKeyId);
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
      if GetTickCount64 - StartedAt > RegistryStateLeaseWaitMilliseconds then
        raise ELWPTRegistryError.CreateStable('registry_state_locked',
          'another process holds the per-user registry state for ' + AIdentity);
      Sleep(PRODUCER_LEASE_POLL_MILLISECONDS);
    until False;
    Merged := AState;
    Merged.State.Origin := AIdentity;
    if LoadRegistryConsumerState(AIdentity, ATrustKeyId, Current) then
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

function LoadRegistryLockTables(const APath: string): TLWPTRegistryLockTableArray;
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
    API: string;
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

constructor TLWPTRegistrySession.Create(
  const ADeclaration: TLWPTRegistryDeclaration;
  const ALockTables: TLWPTRegistryLockTableArray);
begin
  inherited Create;
  FDeclaration := ADeclaration;
  FIdentity := ADeclaration.Identity;
  FLockTables := ALockTables;
end;

function TLWPTRegistrySession.Trust: TLWPTRegistryTrust;
begin
  Result.Origin := FIdentity;
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
    Source.Policy := RegistryContactDestination(AContact);
    Source.Deadline := Acquisition.Deadline;
    Head := VerifyRegistryProof(Acquisition.Proof, TrustRoot, Prior.State,
      ANow, rvmAcquire, Source, DefaultRegistryVerificationLimits);
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
  const ALockTables: TLWPTRegistryLockTableArray);
begin
  inherited Create;
  FRoot := ARoot;
  FLockTables := ALockTables;
  FSessions := TList.Create;
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
  Result := TLWPTRegistrySession.Create(Declaration, FLockTables);
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
    that omits it. }
  for Index := 0 to High(FRoot.Registries) do
  begin
    Session := SessionForAlias(FRoot.Registries[Index].Alias);
    if (Session.Declaration.Identity = '') and not Session.Attempted then
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
