{ LWPT.Registry.Verification -- shared Protocol 1 artifact verification.
  Callers own transport and persistence. All trust inputs are explicit. }
unit LWPT.Registry.Verification;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store;

const
  { Protocol 1 rotation pages carry at most this many items. }
  RegistryRotationPageLimit = 100;
  RegistryRotationDocumentSuffix = '.toml';
  RegistryRotationOldSignatureSuffix = '.old.sig.toml';
  RegistryRotationNewSignatureSuffix = '.new.sig.toml';
  { Protocol 1 checkpoint validity ceiling. Origins sign exactly this window;
    acquisition rejects a window longer than it plus the clock-skew allowance. }
  RegistryCheckpointMaximumLifetimeDays = 7;
  RegistryCheckpointMaximumLifetimeSeconds =
    Int64(RegistryCheckpointMaximumLifetimeDays) * 24 * 60 * 60;
  RegistryCheckpointClockSkewSeconds = 5 * 60;

type
  ELWPTRegistryError = LWPT.Registry.Store.ELWPTRegistryError;
  { A correctly authenticated response that is older than accepted state or
    expired. It identifies a stale contact, not a trust failure. }
  ELWPTRegistryStaleContactError = class(ELWPTRegistryError);

  TLWPTRegistryDependency = record
    Origin, Name, Version: string;
  end;
  TLWPTRegistryDiscovery = record
    Origin, BaseURL, RoleName, API, Capabilities, Checkpoint, Rotations: string;
  end;
  { Retrieval hints only. No identity or key is trusted until VerifyRegistryProof. }
  TLWPTUntrustedRegistryCheckpoint = record
    Origin, Snapshot, PublishedAt, ExpiresAt, KeyId: string;
    Sequence: Int64;
    Bytes: TBytes;
  end;
  TLWPTUntrustedRegistryRotation = record
    Origin, FromKey, ToKey, ToPublicKey: string;
    EffectiveSequence: Int64;
  end;
  TLWPTRegistryRotationPageItem = record
    EffectiveSequence: Int64;
    Rotation, OldSignature, NewSignature: string;
  end;
  TLWPTRegistryRotationPage = record
    Items: array of TLWPTRegistryRotationPageItem;
    NextCursor: string;
  end;
  TLWPTRegistryDependencyArray = array of TLWPTRegistryDependency;

  TLWPTRegistryPackage = record
    RecordHash, Origin, Name, Version, ArchiveHash: string;
    ArchiveSize: Int64;
    PublishedAt: string;
    Yanked: Boolean;
    Dependencies: TLWPTRegistryDependencyArray;
  end;
  TLWPTRegistryPackageArray = array of TLWPTRegistryPackage;

  TLWPTRegistryAcceptedState = record
    Origin, KeyId, PublicKey: string;
    Sequence: Int64;
    Snapshot, CheckpointHash: string;
    { Authenticated renewal times of the accepted checkpoint. }
    PublishedAt, ExpiresAt: string;
    { Highest published_at ever accepted for this origin. Acquisition refuses
      an earlier evaluation time. Empty means PublishedAt alone. }
    ClockFloor: string;
  end;

  TLWPTRegistryTrust = record
    Origin, KeyId, PublicKey: string;
  end;

  TLWPTRegistryDocument = record
    Path: string;
    Bytes: TBytes;
  end;
  TLWPTRegistryDocumentArray = array of TLWPTRegistryDocument;

  TLWPTRegistryRotationProof = record
    Document, OldSignature, NewSignature: TBytes;
  end;
  TLWPTRegistryRotationProofArray = array of TLWPTRegistryRotationProof;

  TLWPTRegistryProof = record
    Checkpoint, Signature: TBytes;
    Rotations: TLWPTRegistryRotationProofArray;
    { Untrusted acquisition bytes, charged to limits only. They grant no trust
      and are unnecessary for a retained signed proof's offline verification. }
    RetrievalDocuments: array of TBytes;
  end;

  TLWPTRegistryVerificationLimits = record
    DocumentBytes, TotalBytes: Int64;
    Documents, Snapshots, Rotations: Integer;
  end;
  TLWPTRegistryMetadataBudget = class
  private
    FLimits: TLWPTRegistryVerificationLimits;
    FBytes: Int64;
    FCount: Integer;
  public
    constructor Create(const ALimits: TLWPTRegistryVerificationLimits);
    function Allowance: Int64;
    procedure Account(const ABytes: TBytes);
  end;

  TLWPTRegistryVerificationMode = (rvmAcquire, rvmLockedProof);

  { Paths are relative to the protocol API, without a leading slash.
    Providers must bound reads before allocation. The verifier checks again. }
  TLWPTRegistryDocumentSource = class
  public
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; virtual; abstract;
    { Called between verification steps; raise to enforce a caller deadline. }
    procedure CheckProgress; virtual;
  end;

  TLWPTVerifiedRegistry = record
    State: TLWPTRegistryAcceptedState;
    PublishedAt, ExpiresAt: string;
    Packages: TLWPTRegistryPackageArray;
    Proof: TLWPTRegistryProof;
    Documents: TLWPTRegistryDocumentArray;
  end;

function DefaultRegistryVerificationLimits: TLWPTRegistryVerificationLimits;
function ParseRegistryDiscovery(const AContent: string): TLWPTRegistryDiscovery;
function InspectRegistryCheckpoint(const ABody: TBytes): TLWPTUntrustedRegistryCheckpoint;
function InspectRegistryRotation(const ABytes: TBytes): TLWPTUntrustedRegistryRotation;
function ParseRegistryRotationPage(const ABytes: TBytes;
  const AOrigin, AAPI: string; const AAfter: Int64;
  const AMaximumItems: Integer): TLWPTRegistryRotationPage;
function RegistryQueryEncode(const AValue: string): string;
{ Signed validity window of canonical checkpoint times, in whole seconds. }
function RegistryCheckpointLifetimeSeconds(const APublishedAt,
  AExpiresAt: string): Int64;
{ The later of two canonical times; an empty value is ignored. }
function RegistryLaterTimestamp(const AFirst, ASecond: string): string;
{ Refuses acquisition while ANow is earlier than the accepted clock floor. }
procedure RequireRegistryClockAtFloor(const ANow, AFloor: string);
function ValidateRegistryKeyDocument(const ABytes: TBytes;
  const ATrust: TLWPTRegistryTrust; const ACheckpointSequence: Int64;
  const AExactSequence: Boolean = False): Int64;
function ValidateRegistryCapabilities(const AContent, ARole: string;
  out AHasRotations: Boolean): Integer;
{ True when capabilities already accepted by ValidateRegistryCapabilities
  advertise publication-v1 with the bearer authentication scheme. }
function RegistryCapabilitiesAcceptBearerPublication(
  const AContent: string): Boolean;
function RegistryURIIsCanonical(const AValue: string;
  const AAllowLocalhostHTTP: Boolean): Boolean;
function RegistryHashIsCanonical(const AValue: string): Boolean;
{ Protocol 1 package-name grammar: 1-128 bytes of [a-z0-9._-], starting
  with a letter or digit. }
function RegistryPackageNameIsCanonical(const AValue: string): Boolean;
{ Canonical SemVer 2.0.0 with no 'v' prefix. }
function RegistryVersionIsCanonical(const AValue: string): Boolean;
{ RFC 3339 UTC with whole seconds and the Z suffix. }
function RegistryTimestampIsCanonical(const AValue: string): Boolean;
function RegistryTrustRootIsValid(const AKeyId, APublicKey: string): Boolean;
{ Byte-preserving conversion of protocol bytes to RawByteString text. The
  reverse conversion is SysUtils.BytesOf. }
function RegistryBytesText(const ABytes: TBytes): string;
{ Hex digest of a canonical "sha256:<hex>" hash, as used in resource paths. }
function RegistryDigestHex(const AHash: string): string;
{ Route-relative rotation resource path; ASuffix is one of
  RegistryRotationDocumentSuffix and the two signature suffixes. }
function RegistryRotationPath(const ASequence: Int64; const ASuffix: string): string;
{ Untrusted retrieval hint: the checkpoint hash a signature envelope claims. }
function InspectRegistrySignaturePayload(const ABytes: TBytes): string;
{ Untrusted retrieval hint: the key a signature envelope claims. }
function InspectRegistrySignatureKey(const ABytes: TBytes): string;
{ Verifies one dual-signed transition from an already trusted key, before a
  caller follows further retrieval hints. Returns the authenticated rotation. }
function VerifyRegistryRotation(const ARotation: TLWPTRegistryRotationProof;
  const AOrigin, AFromKey, AFromPublicKey: string;
  const APreviousSequence, ACheckpointSequence: Int64): TLWPTUntrustedRegistryRotation;
function ParseRegistryPackage(const AContent, AExpectedHash,
  AExpectedOrigin: string): TLWPTRegistryPackage;
{ Content identity of two records for one package identity: archive,
  archive size, and dependencies. published_at and yanked are excluded. }
function RegistryPackageContentEqual(const ALeft,
  ARight: TLWPTRegistryPackage): Boolean;

{ The caller must authenticate the captured head first. This verifies its
  complete hash-linked history and immutable package consistency, not trust. }
function VerifyRegistrySnapshotHistory(const AOrigin, AHeadHash: string;
  const ASequence: Int64; const ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTRegistryDocumentArray;

{ Acquisition enforces expiry at evaluation time. Locked proof requires the
  exact already-recorded checkpoint identity and permits its later expiry.
  Prior state is caller-trusted, and must belong to the same pinned origin.
  Verification walks to genesis and returns complete metadata proof bytes. }
function VerifyRegistryProof(const AProof: TLWPTRegistryProof;
  const ATrust: TLWPTRegistryTrust;
  const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
  const AMode: TLWPTRegistryVerificationMode;
  const ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTVerifiedRegistry;
procedure VerifyRegistryArtifact(const APackage: TLWPTRegistryPackage;
  const AArchive: TStream; const AProgress: TSHA256Progress = nil);

type
  { The committed bytes of one consumer's selection proof (ADR-0051). }
  TLWPTRegistryLockedSelection = record
    Checkpoint, Signature, Snapshot: TBytes;
    Rotations: TLWPTRegistryRotationProofArray;
    Records: array of TBytes;
  end;
  TLWPTVerifiedRegistrySelection = record
    Sequence: Int64;
    KeyId, Snapshot, PublishedAt, ExpiresAt: string;
    Packages: TLWPTRegistryPackageArray;
  end;
  { What a lock records for one selected record. }
  TLWPTRegistryLockedRecord = record
    RecordHash, Name, Version, ArchiveHash: string;
  end;
  TLWPTRegistryLockedRecordArray = array of TLWPTRegistryLockedRecord;
  { What a lock records for one origin's selection proof, and for each record
    of TLWPTRegistryLockedSelection.Records, in the same order. }
  TLWPTRegistryLockedClaims = record
    Checkpoint, Signature, Snapshot, KeyId, PublishedAt, ExpiresAt: string;
    Sequence: Int64;
    Records: TLWPTRegistryLockedRecordArray;
  end;

{ Network-free verification of a consumer's locked selection proof against
  the lock's claims: the checkpoint and signature bytes are the recorded ones,
  the signature verifies under the key the committed rotation chain reaches
  from the pin, the checkpoint's sequence, key, snapshot, publication, and
  expiry are the recorded ones, the snapshot bytes are the checkpoint's, and every selected record is
  a member of that snapshot whose origin, name, version, and archive equal
  the lock. It walks no history and applies neither expiry nor the clock
  floor (ADR-0051 decision 4). }
function VerifyRegistryLockedSelection(
  const ASelection: TLWPTRegistryLockedSelection;
  const ATrust: TLWPTRegistryTrust;
  const AClaims: TLWPTRegistryLockedClaims): TLWPTVerifiedRegistrySelection;
{$IFDEF REGISTRY_TESTING}
procedure SetRegistryVerificationLimitsForTesting(
  const ALimits: TLWPTRegistryVerificationLimits; const AEnabled: Boolean);
{$ENDIF}

implementation

uses
  DateUtils,
  Generics.Collections,

  LWPT.Registry.Crypto,
  Semver,
  TOML;

const
  MaximumCanonicalDocumentBytes = 4 * 1024 * 1024;
  MaximumCanonicalDepth = 3;
  { Every value and table below the root, far above a 4 MiB snapshot's
    record count, but finite before allocation. }
  MaximumCanonicalNodes = 262144;

type
  TLWPTRegistryStringArray = array of string;
  TLWPTRegistrySignature = record
    KeyId, Payload, Signature: string;
  end;

{$IFDEF REGISTRY_TESTING}
var
  VerificationLimitsForTesting: TLWPTRegistryVerificationLimits;
  VerificationLimitsForTestingEnabled: Boolean;

procedure SetRegistryVerificationLimitsForTesting(
  const ALimits: TLWPTRegistryVerificationLimits; const AEnabled: Boolean);
begin
  VerificationLimitsForTesting := ALimits;
  VerificationLimitsForTestingEnabled := AEnabled;
end;
{$ENDIF}

function RegistryURIIsCanonical(const AValue: string;
  const AAllowLocalhostHTTP: Boolean): Boolean;
begin
  try
    Result := CanonicalRegistryURL(AValue, not AAllowLocalhostHTTP) = AValue;
  except
    on E: ELWPTRegistryError do Result := False;
  end;
end;

procedure TLWPTRegistryDocumentSource.CheckProgress;
begin
end;

function RegistryDigestHex(const AHash: string): string;
begin
  Result := Copy(AHash, Length('sha256:') + 1, MaxInt);
end;

function RegistryRotationPath(const ASequence: Int64; const ASuffix: string): string;
begin
  Result := 'rotations/' + IntToStr(ASequence) + ASuffix;
end;

function RegistryBytesText(const ABytes: TBytes): string;
begin
  if Length(ABytes) = 0 then Exit('');
  SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;


{ Strict RFC 3629: no overlong forms, surrogates, or scalars above U+10FFFF. }
function IsValidUTF8(const AText: string): Boolean;
var
  Index, Remaining: Integer;
  Lead: Byte;
  Minimum, Scalar: Cardinal;
begin
  Index := 1;
  while Index <= Length(AText) do
  begin
    Lead := Byte(AText[Index]);
    if Lead < $80 then
    begin
      Inc(Index);
      Continue;
    end;
    if (Lead and $E0) = $C0 then
    begin
      Remaining := 1;
      Scalar := Lead and $1F;
      Minimum := $80;
    end
    else if (Lead and $F0) = $E0 then
    begin
      Remaining := 2;
      Scalar := Lead and $0F;
      Minimum := $800;
    end
    else if (Lead and $F8) = $F0 then
    begin
      Remaining := 3;
      Scalar := Lead and $07;
      Minimum := $10000;
    end
    else Exit(False);
    if Index + Remaining > Length(AText) then Exit(False);
    while Remaining > 0 do
    begin
      Inc(Index);
      if (Byte(AText[Index]) and $C0) <> $80 then Exit(False);
      Scalar := (Scalar shl 6) or (Byte(AText[Index]) and $3F);
      Dec(Remaining);
    end;
    if (Scalar < Minimum) or (Scalar > $10FFFF)
      or ((Scalar >= $D800) and (Scalar <= $DFFF)) then Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function IsLowerHex(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := AValue <> '';
  for I := 1 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function RegistryHashIsCanonical(const AValue: string): Boolean;
begin
  Result := (Length(AValue) = 71)
    and (Copy(AValue, 1, 7) = 'sha256:')
    and IsLowerHex(Copy(AValue, 8, 64));
end;

function IsCanonicalVersion(const AValue: string): Boolean;
begin
  Result := (AValue <> '') and (AValue[1] <> 'v') and (AValue[1] <> 'V')
    and (Valid(AValue, DefaultSemverOptions) = AValue);
end;

function RegistryVersionIsCanonical(const AValue: string): Boolean;
begin
  Result := IsCanonicalVersion(AValue);
end;

function RegistryPackageNameIsCanonical(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AValue) >= 1) and (Length(AValue) <= 128)
    and (AValue[1] in ['a'..'z', '0'..'9']);
  if not Result then Exit;
  for I := 2 to Length(AValue) do
    if not (AValue[I] in ['a'..'z', '0'..'9', '.', '_', '-']) then
      Exit(False);
end;

function RegistryTrustRootIsValid(const AKeyId, APublicKey: string): Boolean;
var
  Key: TLWPTEd25519PublicKey;
  RawKey: TBytes;
begin
  Result := (Length(AKeyId) = 72) and (Copy(AKeyId, 1, 8) = 'ed25519:')
    and IsLowerHex(Copy(AKeyId, 9, 64))
    and (Length(APublicKey) = 68) and (Copy(APublicKey, 1, 4) = 'hex:')
    and IsLowerHex(Copy(APublicKey, 5, 64))
    and HexToBytes(Copy(APublicKey, 5, 64), Key, SizeOf(Key));
  if not Result then Exit;
  SetLength(RawKey, SizeOf(Key));
  Move(Key[0], RawKey[0], SizeOf(Key));
  Result := AKeyId = 'ed25519:' + SHA256Hex(RawKey);
end;

function TryRegistryTimestamp(const AValue: string;
  out AStamp: TDateTime): Boolean;
var
  Year, Month, Day, Hour, Minute, Second: Integer;
  Index: Integer;
begin
  AStamp := 0;
  if Length(AValue) <> 20 then Exit(False);
  for Index := 1 to 19 do
    if not (Index in [5, 8, 11, 14, 17])
      and not (AValue[Index] in ['0'..'9']) then Exit(False);
  Result := (Length(AValue) = 20) and (AValue[5] = '-')
    and (AValue[8] = '-') and (AValue[11] = 'T') and (AValue[14] = ':')
    and (AValue[17] = ':') and (AValue[20] = 'Z')
    and TryStrToInt(Copy(AValue, 1, 4), Year)
    and TryStrToInt(Copy(AValue, 6, 2), Month)
    and TryStrToInt(Copy(AValue, 9, 2), Day)
    and TryStrToInt(Copy(AValue, 12, 2), Hour)
    and TryStrToInt(Copy(AValue, 15, 2), Minute)
    and TryStrToInt(Copy(AValue, 18, 2), Second)
    and TryEncodeDateTime(Word(Year), Word(Month), Word(Day), Word(Hour),
      Word(Minute), Word(Second), 0, AStamp);
end;

function RegistryTimestampIsCanonical(const AValue: string): Boolean;
var
  Stamp: TDateTime;
begin
  Result := TryRegistryTimestamp(AValue, Stamp);
end;

function RegistryCheckpointLifetimeSeconds(const APublishedAt,
  AExpiresAt: string): Int64;
var
  Published, Expires: TDateTime;
begin
  if not TryRegistryTimestamp(APublishedAt, Published)
    or not TryRegistryTimestamp(AExpiresAt, Expires) then
    raise ELWPTRegistryError.CreateStable('invalid_registry_checkpoint',
      'checkpoint times are not canonical UTC');
  { Both stamps are whole seconds, so the rounded difference is exact. }
  Result := DateTimeToUnix(Expires) - DateTimeToUnix(Published);
end;

function RegistryLaterTimestamp(const AFirst, ASecond: string): string;
begin
  { Canonical UTC stamps have fixed width, so they order lexicographically. }
  if AFirst > ASecond then Result := AFirst else Result := ASecond;
end;

procedure RequireRegistryClockAtFloor(const ANow, AFloor: string);
begin
  if (AFloor <> '') and (ANow < AFloor) then
    raise ELWPTRegistryError.CreateStable('local_clock_behind_accepted_state',
      'local clock is behind accepted registry state: the clock reads ' + ANow
      + ' but a checkpoint published at ' + AFloor
      + ' was already accepted; correct the system clock, and acquisition'
      + ' resumes once it reaches ' + AFloor);
end;

function RegistryConstraintArmIsCanonical(const AValue: string): Boolean;
var
  Parts: TStringList;
  I, PrefixLength: Integer;
  Token: string;
begin
  Result := False;
  if AValue = '' then Exit;
  if AValue[1] in ['^', '~'] then
    Exit(IsCanonicalVersion(Copy(AValue, 2, MaxInt)));
  if IsCanonicalVersion(AValue) then Exit(True);
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ' ';
    Parts.DelimitedText := AValue;
    if Parts.Count = 0 then Exit;
    for I := 0 to Parts.Count - 1 do
    begin
      Token := Parts[I];
      PrefixLength := 0;
      if Copy(Token, 1, 2) = '>=' then PrefixLength := 2
      else if Copy(Token, 1, 2) = '<=' then PrefixLength := 2
      else if (Token <> '') and (Token[1] in ['>', '<']) then PrefixLength := 1;
      if (PrefixLength = 0)
        or not IsCanonicalVersion(Copy(Token, PrefixLength + 1, MaxInt)) then
        Exit;
    end;
    Result := True;
  finally
    Parts.Free;
  end;
end;

function RegistryConstraintIsCanonical(const AValue: string): Boolean;
var
  Cursor, Next: Integer;
  Arm: string;
begin
  Result := False;
  if (AValue = '') or (Trim(AValue) <> AValue)
    or (Pos('  ', AValue) > 0) or (Pos(',', AValue) > 0)
    or (Pos('*', AValue) > 0) then Exit;
  Cursor := 1;
  repeat
    Next := Pos(' || ', Copy(AValue, Cursor, MaxInt));
    if Next = 0 then Arm := Copy(AValue, Cursor, MaxInt)
    else Arm := Copy(AValue, Cursor, Next - 1);
    if not RegistryConstraintArmIsCanonical(Arm) then Exit;
    if Next = 0 then Break;
    Inc(Cursor, Next + 3);
  until False;
  Result := Pos('||', StringReplace(AValue, ' || ', '', [rfReplaceAll])) = 0;
end;

function CanonicalTomlKey(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := AValue <> '';
  for I := 1 to Length(AValue) do
    if not (AValue[I] in ['a'..'z', '0'..'9', '_']) then Exit(False);
end;

function CanonicalTomlValue(ANode: TTOMLNode): string;
var
  I: Integer;
  IntegerValue: Int64;
  Pair: TTOMLNodeMap.TKeyValuePair;
begin
  if ANode = nil then
    raise ELWPTRegistryError.Create('non_canonical_document: missing value');
  case ANode.Kind of
    tnkScalar:
      case ANode.ScalarKind of
        tskString: Result := RegistryTOMLQuote(ANode.ScalarText);
        tskInteger:
        begin
          if not TryStrToInt64(ANode.ScalarText, IntegerValue)
            or (IntegerValue < 0) then
            raise ELWPTRegistryError.Create(
              'non_canonical_document: integer outside supported range');
          Result := IntToStr(IntegerValue);
        end;
        tskBool:
          if ANode.ScalarText = 'true' then Result := 'true'
          else Result := 'false';
      else
        raise ELWPTRegistryError.Create(
          'non_canonical_document: unsupported scalar');
      end;
    tnkArray:
    begin
      Result := '[';
      for I := 0 to ANode.Items.Count - 1 do
      begin
        if I > 0 then Result := Result + ', ';
        Result := Result + CanonicalTomlValue(ANode.Items[I]);
      end;
      Result := Result + ']';
    end;
    tnkTable:
    begin
      Result := '{ ';
      I := 0;
      for Pair in ANode.Children do
      begin
        if not CanonicalTomlKey(Pair.Key) then
          raise ELWPTRegistryError.Create(
            'non_canonical_document: invalid inline-table key');
        if I > 0 then Result := Result + ', ';
        Result := Result + Pair.Key + ' = '
          + CanonicalTomlValue(Pair.Value);
        Inc(I);
      end;
      Result := Result + ' }';
    end;
  else
    raise ELWPTRegistryError.Create(
      'non_canonical_document: unsupported value');
  end;
end;

function ParseCanonical(const AContent, ASchema: string;
  const AKeys: array of string): TTOMLNode;
var
  Parser: TTOMLParser;
  Lines: TStringList;
  I, EqualAt, Depth: Integer;
  Key: string;
  InString, Escaped: Boolean;
  Delimiters: array[1..MaximumCanonicalDepth] of Char;
begin
  Result := nil;
  if Length(AContent) > MaximumCanonicalDocumentBytes then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: document bytes');
  if (AContent = '') or (AContent[Length(AContent)] <> #10)
    or (Pos(#13, AContent) > 0) or (Copy(AContent, 1, 3) = #$EF#$BB#$BF)
    or (Pos(#10#10, AContent) > 0) then
    raise ELWPTRegistryError.Create('non_canonical_document: byte framing');
  if not IsValidUTF8(AContent) then
    raise ELWPTRegistryError.Create('non_canonical_document: invalid UTF-8');
  { Reject delimiter nesting and comments before TOML parsing. Quoted bytes,
    including "#" in an opaque cursor, are string content. The parser also
    enforces structural depth, because dotted keys nest without brackets. }
  InString := False;
  Escaped := False;
  Depth := 0;
  for I := 1 to Length(AContent) do
  begin
    if InString then
    begin
      if AContent[I] = #10 then
        raise ELWPTRegistryError.Create('non_canonical_document: delimiters');
      if Escaped then Escaped := False
      else if AContent[I] = '\' then Escaped := True
      else if AContent[I] = '"' then InString := False;
    end
    else if AContent[I] = #39 then
      raise ELWPTRegistryError.Create('non_canonical_document: literal strings')
    else if AContent[I] = '#' then
      raise ELWPTRegistryError.Create('non_canonical_document: comments')
    else if AContent[I] = '"' then
    begin
      if Copy(AContent, I, 3) = '"""' then
        raise ELWPTRegistryError.Create('non_canonical_document: delimiters');
      InString := True;
    end
    else if AContent[I] in ['[', '{'] then
    begin
      Inc(Depth);
      if Depth > MaximumCanonicalDepth then
        raise ELWPTRegistryError.Create('non_canonical_document: nesting');
      Delimiters[Depth] := AContent[I];
    end
    else if AContent[I] in [']', '}'] then
    begin
      if Depth = 0 then
        raise ELWPTRegistryError.Create('non_canonical_document: delimiters');
      if ((AContent[I] = ']') and (Delimiters[Depth] <> '['))
        or ((AContent[I] = '}') and (Delimiters[Depth] <> '{')) then
        raise ELWPTRegistryError.Create('non_canonical_document: delimiters');
      Dec(Depth);
    end;
  end;
  if InString or (Depth <> 0) then
    raise ELWPTRegistryError.Create('non_canonical_document: delimiters');
  Lines := TStringList.Create;
  try
    Lines.Text := AContent;
    if (Lines.Count <> Length(AKeys)) then
      raise ELWPTRegistryError.CreateFmt(
        'non_canonical_document: %s field count', [ASchema]);
    for I := 0 to Lines.Count - 1 do
    begin
      if Lines[I] = '' then
        raise ELWPTRegistryError.Create(
          'non_canonical_document: blank lines');
      EqualAt := Pos(' = ', Lines[I]);
      if EqualAt = 0 then
        raise ELWPTRegistryError.Create('non_canonical_document: assignment');
      Key := Copy(Lines[I], 1, EqualAt - 1);
      { Reflect at most a short prefix of untrusted input in diagnostics. }
      if Key <> AKeys[I] then
        raise ELWPTRegistryError.CreateFmt(
          'non_canonical_document: expected field "%s", got %s',
          [AKeys[I], RegistryTOMLQuote(Copy(Key, 1, 64))]);
    end;
    Parser := TTOMLParser.Create;
    try
      Parser.MaximumDepth := MaximumCanonicalDepth;
      Parser.MaximumNodes := MaximumCanonicalNodes;
      try
        Result := Parser.ParseDocument(AContent);
      except
        on E: ETOMLLimitError do
          raise ELWPTRegistryError.Create('non_canonical_document: nesting');
        on E: ETOMLParseError do
          raise ELWPTRegistryError.Create('non_canonical_document: invalid TOML');
      end;
    finally
      Parser.Free;
    end;
    try
      if TomlStr(Result, 'schema', '') <> ASchema then
        raise ELWPTRegistryError.CreateFmt(
          'unsupported_registry_schema: %s', [TomlStr(Result, 'schema', '')]);
      for I := 0 to High(AKeys) do
        if Lines[I] <> AKeys[I] + ' = '
          + CanonicalTomlValue(TomlGet(Result, AKeys[I])) then
          raise ELWPTRegistryError.CreateFmt(
            'non_canonical_document: non-canonical value for "%s"',
            [AKeys[I]]);
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    Lines.Free;
  end;
end;

function UnsignedField(ARoot: TTOMLNode; const AName: string): Int64;
var
  Node: TTOMLNode;
begin
  Node := TomlGet(ARoot, AName);
  if (Node = nil) or (Node.Kind <> tnkScalar)
    or (Node.ScalarKind <> tskInteger)
    or not TryStrToInt64(Node.ScalarText, Result) or (Result < 0) then
    raise ELWPTRegistryError.Create('non_canonical_document: integer required');
end;

function StringField(ARoot: TTOMLNode; const AName: string): string;
var
  Node: TTOMLNode;
begin
  Node := TomlGet(ARoot, AName);
  if not TomlIsString(Node) then
    raise ELWPTRegistryError.Create('non_canonical_document: string required');
  Result := Node.ScalarText;
end;

function NodeStringArray(ARoot: TTOMLNode; const AName: string): TLWPTRegistryStringArray;
var
  Node: TTOMLNode;
  I: Integer;
begin
  Result := nil;
  Node := TomlGet(ARoot, AName);
  if not TomlIsArray(Node) then
    raise ELWPTRegistryError.CreateFmt(
      'non_canonical_document: %s must be an array', [AName]);
  SetLength(Result, Node.Items.Count);
  for I := 0 to Node.Items.Count - 1 do
  begin
    if not TomlIsString(Node.Items[I]) then
      raise ELWPTRegistryError.CreateFmt(
        'non_canonical_document: %s item must be a string', [AName]);
    Result[I] := Node.Items[I].ScalarText;
    if (I > 0) and (Result[I - 1] >= Result[I]) then
      raise ELWPTRegistryError.CreateFmt(
        'non_canonical_document: %s must be sorted and unique', [AName]);
  end;
end;

function NodeBoolean(ARoot: TTOMLNode; const AName: string): Boolean;
var
  Node: TTOMLNode;
begin
  Node := TomlGet(ARoot, AName);
  if (Node = nil) or (Node.Kind <> tnkScalar)
    or (Node.ScalarKind <> tskBool) then
    raise ELWPTRegistryError.Create('non_canonical_document: boolean required');
  Result := Node.ScalarText = 'true';
end;

function ValidateRegistryKeyDocument(const ABytes: TBytes;
  const ATrust: TLWPTRegistryTrust; const ACheckpointSequence: Int64;
  const AExactSequence: Boolean): Int64;
var
  Root: TTOMLNode;
  ValidFrom: Int64;
begin
  Root := ParseCanonical(RegistryBytesText(ABytes), PROGRAM_NAME + '-registry-key-v1',
    ['schema', 'origin', 'key_id', 'algorithm', 'public_key', 'valid_from_sequence']);
  try
    ValidFrom := UnsignedField(Root, 'valid_from_sequence');
    if not RegistryTrustRootIsValid(ATrust.KeyId, ATrust.PublicKey)
      or (StringField(Root, 'origin') <> ATrust.Origin)
      or (StringField(Root, 'key_id') <> ATrust.KeyId)
      or (StringField(Root, 'public_key') <> ATrust.PublicKey)
      or (StringField(Root, 'algorithm') <> 'ed25519')
      or (ValidFrom < 1) or (ValidFrom > ACheckpointSequence)
      or (AExactSequence and (ValidFrom <> ACheckpointSequence)) then
      raise ELWPTRegistryError.CreateStable('registry_key_pin_mismatch',
        'key document does not match the pinned key or sequence');
    Result := ValidFrom;
  finally
    Root.Free;
  end;
end;

function RegistryQueryEncode(const AValue: string): string;
const
  Hex: array[0..15] of Char = '0123456789ABCDEF';
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    if AValue[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + AValue[I]
    else Result := Result + '%' + Hex[Ord(AValue[I]) shr 4] + Hex[Ord(AValue[I]) and $F];
end;

function InspectRegistryRotation(const ABytes: TBytes): TLWPTUntrustedRegistryRotation;
var
  Root: TTOMLNode;
begin
  Root := ParseCanonical(RegistryBytesText(ABytes), PROGRAM_NAME + '-registry-key-rotation-v1',
    ['schema', 'origin', 'from_key', 'to_key', 'to_public_key', 'effective_sequence']);
  try
    Result.Origin := StringField(Root, 'origin');
    Result.FromKey := StringField(Root, 'from_key');
    Result.ToKey := StringField(Root, 'to_key');
    Result.ToPublicKey := StringField(Root, 'to_public_key');
    Result.EffectiveSequence := UnsignedField(Root, 'effective_sequence');
    if not RegistryURIIsCanonical(Result.Origin, True)
      or (Result.EffectiveSequence < 2)
      or not RegistryTrustRootIsValid(Result.ToKey, Result.ToPublicKey) then
      raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
        'rotation document is not a valid transition');
    RegistryKeyStoragePath(Result.FromKey);
  finally
    Root.Free;
  end;
end;

function ParseRegistryRotationPage(const ABytes: TBytes;
  const AOrigin, AAPI: string; const AAfter: Int64;
  const AMaximumItems: Integer): TLWPTRegistryRotationPage;
var
  Root, Items, Item: TTOMLNode;
  I: Integer;
  Previous: Int64;
  Entry: TLWPTRegistryRotationPageItem;
  Prefix: string;
begin
  Result := Default(TLWPTRegistryRotationPage);
  Root := ParseCanonical(RegistryBytesText(ABytes), PROGRAM_NAME + '-registry-rotation-page-v1',
    ['schema', 'origin', 'items', 'next_cursor']);
  try
    if StringField(Root, 'origin') <> AOrigin then
      raise ELWPTRegistryError.CreateStable('registry_rotation_origin_mismatch',
        'rotation page names a different origin');
    Result.NextCursor := StringField(Root, 'next_cursor');
    Items := TomlGet(Root, 'items');
    if not TomlIsArray(Items) or (Items.Items.Count > AMaximumItems)
      or (Length(Result.NextCursor) > 1024)
      or ((Items.Items.Count = 0) and (Result.NextCursor <> '')) then
      raise ELWPTRegistryError.CreateStable('invalid_registry_rotation_page',
        'rotation page is out of order, oversized, or malformed');
    SetLength(Result.Items, Items.Items.Count);
    Previous := AAfter;
    for I := 0 to Items.Items.Count - 1 do
    begin
      Item := Items.Items[I];
      if not TomlIsTable(Item) or (Item.Children.Count <> 4) then
        raise ELWPTRegistryError.CreateStable('invalid_registry_rotation_page',
          'rotation page is out of order, oversized, or malformed');
      Entry.EffectiveSequence := UnsignedField(Item, 'effective_sequence');
      Entry.Rotation := StringField(Item, 'rotation');
      Entry.OldSignature := StringField(Item, 'old_signature');
      Entry.NewSignature := StringField(Item, 'new_signature');
      Prefix := AAPI + '/';
      if (Entry.EffectiveSequence <= Previous)
        or (Entry.Rotation <> Prefix + RegistryRotationPath(Entry.EffectiveSequence,
          RegistryRotationDocumentSuffix))
        or (Entry.OldSignature <> Prefix + RegistryRotationPath(Entry.EffectiveSequence,
          RegistryRotationOldSignatureSuffix))
        or (Entry.NewSignature <> Prefix + RegistryRotationPath(Entry.EffectiveSequence,
          RegistryRotationNewSignatureSuffix))
        or (CanonicalTomlValue(Item) <> '{ effective_sequence = '
          + IntToStr(Entry.EffectiveSequence) + ', rotation = ' + RegistryTOMLQuote(Entry.Rotation)
          + ', old_signature = ' + RegistryTOMLQuote(Entry.OldSignature)
          + ', new_signature = ' + RegistryTOMLQuote(Entry.NewSignature) + ' }') then
        raise ELWPTRegistryError.CreateStable('invalid_registry_rotation_page',
          'rotation page is out of order, oversized, or malformed');
      Previous := Entry.EffectiveSequence;
      Result.Items[I] := Entry;
    end;
  finally
    Root.Free;
  end;
end;

function InspectRegistryCheckpoint(const ABody: TBytes): TLWPTUntrustedRegistryCheckpoint;
var
  Root: TTOMLNode;
begin
  Result := Default(TLWPTUntrustedRegistryCheckpoint);
  Result.Bytes := Copy(ABody);
  Root := ParseCanonical(RegistryBytesText(ABody), PROGRAM_NAME + '-registry-checkpoint-v1',
    ['schema', 'origin', 'sequence', 'snapshot', 'published_at',
     'expires_at', 'key_id']);
  try
    Result.Origin := StringField(Root, 'origin');
    Result.Sequence := UnsignedField(Root, 'sequence');
    Result.Snapshot := StringField(Root, 'snapshot');
    Result.PublishedAt := StringField(Root, 'published_at');
    Result.ExpiresAt := StringField(Root, 'expires_at');
    Result.KeyId := StringField(Root, 'key_id');
    if (Result.Sequence < 1) or not RegistryHashIsCanonical(Result.Snapshot)
      or not RegistryTimestampIsCanonical(Result.PublishedAt)
      or not RegistryTimestampIsCanonical(Result.ExpiresAt)
      or (Result.PublishedAt >= Result.ExpiresAt) then
      raise ELWPTRegistryError.CreateStable('invalid_registry_checkpoint',
        'checkpoint fields are invalid');
  finally
    Root.Free;
  end;
end;

function ParseSignature(const AContent: string): TLWPTRegistrySignature;
var
  Root: TTOMLNode;
begin
  Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-signature-v1',
    ['schema', 'algorithm', 'key_id', 'payload', 'signature']);
  try
    if TomlStr(Root, 'algorithm', '') <> 'ed25519' then
      raise ELWPTRegistryError.CreateStable('unsupported_registry_signature',
        'signature algorithm is not ed25519');
    Result.KeyId := TomlStr(Root, 'key_id', '');
    Result.Payload := TomlStr(Root, 'payload', '');
    Result.Signature := TomlStr(Root, 'signature', '');
    if (Length(Result.KeyId) <> 72)
      or (Copy(Result.KeyId, 1, 8) <> 'ed25519:')
      or not IsLowerHex(Copy(Result.KeyId, 9, 64))
      or not RegistryHashIsCanonical(Result.Payload)
      or (Length(Result.Signature) <> 132)
      or (Copy(Result.Signature, 1, 4) <> 'hex:')
      or not IsLowerHex(Copy(Result.Signature, 5, 128)) then
      raise ELWPTRegistryError.CreateStable('invalid_registry_signature_encoding',
        'signature envelope encoding is invalid');
  finally
    Root.Free;
  end;
end;

procedure VerifySignature(const ADomain: string; const APayload: TBytes;
  const AEnvelope: TLWPTRegistrySignature; const AKeyId, APublicKey: string);
var
  Key: TLWPTEd25519PublicKey;
  Signature: TLWPTEd25519Signature;
  MessageBytes, DomainBytes: TBytes;
begin
  if (AEnvelope.KeyId <> AKeyId)
    or (AEnvelope.Payload <> SHA256BytesPrefixed(APayload)) then
    if AEnvelope.KeyId <> AKeyId then
      raise ELWPTRegistryError.Create('signature_key_mismatch: unexpected key')
    else
      raise ELWPTRegistryError.Create('signature_payload_mismatch: unexpected hash');
  if not HexToBytes(Copy(APublicKey, 5, MaxInt), Key, SizeOf(Key))
    or not HexToBytes(Copy(AEnvelope.Signature, 5, MaxInt), Signature,
      SizeOf(Signature)) then
    raise ELWPTRegistryError.CreateStable('invalid_registry_signature_encoding',
      'signature envelope encoding is invalid');
  DomainBytes := BytesOf(ADomain + #10);
  SetLength(MessageBytes, Length(DomainBytes) + Length(APayload));
  if Length(DomainBytes) > 0 then
    Move(DomainBytes[0], MessageBytes[0], Length(DomainBytes));
  if Length(APayload) > 0 then
    Move(APayload[0], MessageBytes[Length(DomainBytes)], Length(APayload));
  if not Ed25519Verify(MessageBytes, Key, Signature) then
    raise ELWPTRegistryError.Create('signature_invalid: Ed25519 verification failed');
end;

function InspectRegistrySignaturePayload(const ABytes: TBytes): string;
begin
  Result := ParseSignature(RegistryBytesText(ABytes)).Payload;
end;

function InspectRegistrySignatureKey(const ABytes: TBytes): string;
begin
  Result := ParseSignature(RegistryBytesText(ABytes)).KeyId;
end;

function VerifyRegistryRotation(const ARotation: TLWPTRegistryRotationProof;
  const AOrigin, AFromKey, AFromPublicKey: string;
  const APreviousSequence, ACheckpointSequence: Int64): TLWPTUntrustedRegistryRotation;
begin
  Result := InspectRegistryRotation(ARotation.Document);
  if (Result.Origin <> AOrigin) or (Result.FromKey <> AFromKey)
    or (Result.ToKey = AFromKey)
    or (Result.EffectiveSequence <= APreviousSequence)
    or (Result.EffectiveSequence > ACheckpointSequence) then
    raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
      'rotation does not extend the trusted chain');
  VerifySignature(PROJECT_NAME + '-REGISTRY-KEY-ROTATION-V1', ARotation.Document,
    ParseSignature(RegistryBytesText(ARotation.OldSignature)), AFromKey, AFromPublicKey);
  VerifySignature(PROJECT_NAME + '-REGISTRY-KEY-ROTATION-V1', ARotation.Document,
    ParseSignature(RegistryBytesText(ARotation.NewSignature)), Result.ToKey,
    Result.ToPublicKey);
end;

function ParseRegistryPackage(const AContent, AExpectedHash,
  AExpectedOrigin: string): TLWPTRegistryPackage;
var
  Root, Deps, Item: TTOMLNode;
  I: Integer;
  ExplicitOrigin, CanonicalDependencyLine, SortKey, PreviousSortKey: string;
begin
  Result := Default(TLWPTRegistryPackage);
  if (AExpectedHash <> '')
    and (SHA256BytesPrefixed(BytesOf(AContent)) <> AExpectedHash) then
    raise ELWPTRegistryError.CreateStable('registry_record_hash_mismatch',
      'package record bytes do not match their hash');
  Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-package-v1',
    ['schema', 'origin', 'name', 'version', 'archive', 'archive_size',
     'published_at', 'yanked', 'dependencies']);
  try
    Result.RecordHash := AExpectedHash;
    Result.Origin := TomlStr(Root, 'origin', '');
    Result.Name := TomlStr(Root, 'name', '');
    Result.Version := TomlStr(Root, 'version', '');
    Result.ArchiveHash := TomlStr(Root, 'archive', '');
    Result.ArchiveSize := UnsignedField(Root, 'archive_size');
    Result.PublishedAt := TomlStr(Root, 'published_at', '');
    Result.Yanked := NodeBoolean(Root, 'yanked');
    if (Result.Origin <> AExpectedOrigin)
      or not RegistryPackageNameIsCanonical(Result.Name)
      or not IsCanonicalVersion(Result.Version)
      or not RegistryHashIsCanonical(Result.ArchiveHash) or (Result.ArchiveSize < 0)
      or not RegistryTimestampIsCanonical(Result.PublishedAt) then
      raise ELWPTRegistryError.CreateStable('invalid_registry_record',
        'package record fields are invalid');
    Deps := TomlGet(Root, 'dependencies');
    if not TomlIsArray(Deps) then
      raise ELWPTRegistryError.CreateStable('invalid_registry_record_dependencies',
        'package record dependencies must be an array');
    SetLength(Result.Dependencies, Deps.Items.Count);
    CanonicalDependencyLine := 'dependencies = [';
    PreviousSortKey := '';
    for I := 0 to Deps.Items.Count - 1 do
    begin
      Item := Deps.Items[I];
      if not TomlIsTable(Item) then
        raise ELWPTRegistryError.CreateStable('invalid_registry_dependency',
          'package dependency is invalid');
      ExplicitOrigin := TomlStr(Item, 'origin', '');
      if ExplicitOrigin = '' then
        Result.Dependencies[I].Origin := Result.Origin
      else
        Result.Dependencies[I].Origin := ExplicitOrigin;
      Result.Dependencies[I].Name := TomlStr(Item, 'name', '');
      Result.Dependencies[I].Version := TomlStr(Item, 'version', '');
      if not RegistryPackageNameIsCanonical(Result.Dependencies[I].Name)
        or not RegistryConstraintIsCanonical(Result.Dependencies[I].Version)
        or not RegistryURIIsCanonical(Result.Dependencies[I].Origin, True) then
        raise ELWPTRegistryError.CreateStable('invalid_registry_dependency',
          'package dependency is invalid');
      SortKey := Result.Dependencies[I].Origin + #0
        + Result.Dependencies[I].Name + #0 + Result.Dependencies[I].Version;
      if (I > 0) and (SortKey <= PreviousSortKey) then
        raise ELWPTRegistryError.Create(
          'non_canonical_document: dependencies must be sorted and unique');
      PreviousSortKey := SortKey;
      if I > 0 then CanonicalDependencyLine := CanonicalDependencyLine + ', ';
      CanonicalDependencyLine := CanonicalDependencyLine + '{ ';
      if ExplicitOrigin <> '' then
        CanonicalDependencyLine := CanonicalDependencyLine + 'origin = "'
          + ExplicitOrigin + '", ';
      CanonicalDependencyLine := CanonicalDependencyLine + 'name = "'
        + Result.Dependencies[I].Name + '", version = "'
        + Result.Dependencies[I].Version + '" }';
    end;
    CanonicalDependencyLine := CanonicalDependencyLine + ']';
    if Copy(AContent, LastDelimiter(#10, Copy(AContent, 1,
         Length(AContent) - 1)) + 1, MaxInt) <> CanonicalDependencyLine + #10 then
      raise ELWPTRegistryError.Create(
        'non_canonical_document: dependency inline table encoding');
  finally
    Root.Free;
  end;
end;


type
  TLWPTRegistryVerifier = class
  private
    FSource: TLWPTRegistryDocumentSource;
    FLimits: TLWPTRegistryVerificationLimits;
    FBudget: TLWPTRegistryMetadataBudget;
    FDocuments: TLWPTRegistryDocumentArray;
    FDocumentIndexes: TDictionary<string, Integer>;
    FPackages: TDictionary<string, TLWPTRegistryPackage>;
    function Read(const APath: string): TBytes;
    function PackageRecord(const AHash, AOrigin: string): TLWPTRegistryPackage;
    function VerifyHistory(const AOrigin, AHeadHash: string; const ASequence: Int64;
      const APrior: TLWPTRegistryAcceptedState): TLWPTRegistryPackageArray;
    function SnapshotAtSequence(const AOrigin, AHeadHash: string;
      const AHeadSequence, ATargetSequence: Int64): string;
  public
    constructor Create(const ASource: TLWPTRegistryDocumentSource;
      const ALimits: TLWPTRegistryVerificationLimits);
    destructor Destroy; override;
    function Verify(const AProof: TLWPTRegistryProof;
      const ATrust: TLWPTRegistryTrust;
      const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
      const AMode: TLWPTRegistryVerificationMode): TLWPTVerifiedRegistry;
  end;

function ParseRegistryDiscovery(const AContent: string): TLWPTRegistryDiscovery;
var
  Root: TTOMLNode;
begin
  if Pos(#10 + 'rotations = ', AContent) > 0 then
    Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-discovery-v1',
      ['schema', 'protocol', 'origin', 'base_url', 'role', 'api',
       'capabilities', 'checkpoint', 'rotations'])
  else
    Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-discovery-v1',
      ['schema', 'protocol', 'origin', 'base_url', 'role', 'api',
       'capabilities', 'checkpoint']);
  try
    if UnsignedField(Root, 'protocol') <> 1 then
      raise ELWPTRegistryError.CreateStable('unsupported_registry_protocol',
        'only protocol 1 is supported');
    Result.Origin := TomlStr(Root, 'origin', '');
    Result.BaseURL := TomlStr(Root, 'base_url', '');
    Result.RoleName := TomlStr(Root, 'role', '');
    Result.API := TomlStr(Root, 'api', '');
    Result.Capabilities := TomlStr(Root, 'capabilities', '');
    Result.Checkpoint := TomlStr(Root, 'checkpoint', '');
    Result.Rotations := TomlStr(Root, 'rotations', '');
    if (Result.RoleName <> 'origin') and (Result.RoleName <> 'mirror') then
      raise ELWPTRegistryError.CreateStable('invalid_registry_role',
        'role must be origin or mirror');
    if not RegistryURIIsCanonical(Result.Origin, True)
      or not RegistryURIIsCanonical(Result.BaseURL, True)
      or not RegistryURIIsCanonical(Result.API, True)
      or not RegistryURIIsCanonical(Result.Capabilities, True)
      or not RegistryURIIsCanonical(Result.Checkpoint, True)
      or ((TomlGet(Root, 'rotations') <> nil)
        and not RegistryURIIsCanonical(Result.Rotations, True)) then
      raise ELWPTRegistryError.CreateStable('invalid_registry_discovery_uri',
        'discovery endpoint is not a canonical URL');
    if (Length(Result.Checkpoint) <= 5)
      or (Copy(Result.Checkpoint, Length(Result.Checkpoint) - 4, 5)
        <> '.toml') then
      raise ELWPTRegistryError.CreateStable('invalid_registry_checkpoint_uri',
        'checkpoint endpoint must name a .toml resource');
  finally
    Root.Free;
  end;
end;

function ValidateRegistryCapabilities(const AContent: string;
  const ARole: string; out AHasRotations: Boolean): Integer;
const
  RequiredSchemas: array[0..4] of string = (
    PROGRAM_NAME + '-registry-checkpoint-v1', PROGRAM_NAME + '-registry-discovery-v1',
    PROGRAM_NAME + '-registry-package-v1', PROGRAM_NAME + '-registry-signature-v1',
    PROGRAM_NAME + '-registry-snapshot-v1');
var
  Root: TTOMLNode;
  Hashes, Signatures, Schemas, Features, AuthSchemes: TLWPTRegistryStringArray;
  I: Integer;
  function Contains(const AValues: TLWPTRegistryStringArray; const AValue: string): Boolean;
  var J: Integer;
  begin
    for J := 0 to High(AValues) do if AValues[J] = AValue then Exit(True);
    Result := False;
  end;
begin
  Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-capabilities-v1',
    ['schema', 'protocol', 'hashes', 'signatures', 'schemas', 'features',
     'auth_schemes', 'max_page_size']);
  try
    if UnsignedField(Root, 'protocol') <> 1 then
      raise ELWPTRegistryError.CreateStable('unsupported_registry_protocol',
        'only protocol 1 is supported');
    Hashes := NodeStringArray(Root, 'hashes');
    Signatures := NodeStringArray(Root, 'signatures');
    Schemas := NodeStringArray(Root, 'schemas');
    Features := NodeStringArray(Root, 'features');
    AHasRotations := Contains(Features, 'rotation-chain-v1');
    if AHasRotations and (not Contains(Schemas, PROGRAM_NAME + '-registry-key-rotation-v1')
      or not Contains(Schemas, PROGRAM_NAME + '-registry-rotation-page-v1')) then
      raise ELWPTRegistryError.CreateStable('registry_schema_capability_missing',
        'a required schema is not advertised');
    AuthSchemes := NodeStringArray(Root, 'auth_schemes');
    if UnsignedField(Root, 'max_page_size') > High(Integer) then
      raise ELWPTRegistryError.CreateStable('registry_capability_missing',
        'a required capability is not advertised');
    Result := UnsignedField(Root, 'max_page_size');
    if not Contains(Hashes, 'sha256') or not Contains(Signatures, 'ed25519')
      or not Contains(Features, 'snapshot-sync-v1')
      or (Result < 1) then
      raise ELWPTRegistryError.CreateStable('registry_capability_missing',
        'a required capability is not advertised');
    for I := 0 to High(RequiredSchemas) do
      if not Contains(Schemas, RequiredSchemas[I]) then
        raise ELWPTRegistryError.CreateStable('registry_schema_capability_missing',
          'a required schema is not advertised');
    if ARole = 'mirror' then
    begin
      if Contains(Features, 'publication-v1') then
        raise ELWPTRegistryError.CreateStable('mirror_advertises_publication',
          'a mirror cannot advertise publication');
      if Length(AuthSchemes) <> 0 then
        raise ELWPTRegistryError.CreateStable('mirror_advertises_authentication',
          'a mirror cannot advertise authentication');
    end
    else if Contains(Features, 'publication-v1')
      and (Length(AuthSchemes) = 0) then
      raise ELWPTRegistryError.CreateStable('origin_publication_capability_missing',
        'publication requires an authentication scheme');
    if (ARole = 'origin') and not Contains(Features, 'publication-v1')
      and (Length(AuthSchemes) <> 0) then
      raise ELWPTRegistryError.CreateStable('read_only_origin_advertises_authentication',
        'a read-only origin cannot advertise authentication');
  finally
    Root.Free;
  end;
end;

function RegistryCapabilitiesAcceptBearerPublication(
  const AContent: string): Boolean;
var
  Root: TTOMLNode;
  Values: TLWPTRegistryStringArray;
  HasPublication, HasBearer: Boolean;
  Index: Integer;
begin
  Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-capabilities-v1',
    ['schema', 'protocol', 'hashes', 'signatures', 'schemas', 'features',
     'auth_schemes', 'max_page_size']);
  try
    HasPublication := False;
    Values := NodeStringArray(Root, 'features');
    for Index := 0 to High(Values) do
      if Values[Index] = 'publication-v1' then HasPublication := True;
    HasBearer := False;
    Values := NodeStringArray(Root, 'auth_schemes');
    for Index := 0 to High(Values) do
      if Values[Index] = 'bearer' then HasBearer := True;
    Result := HasPublication and HasBearer;
  finally
    Root.Free;
  end;
end;

function DefaultRegistryVerificationLimits: TLWPTRegistryVerificationLimits;
begin
  {$IFDEF REGISTRY_TESTING}
  if VerificationLimitsForTestingEnabled then Exit(VerificationLimitsForTesting);
  {$ENDIF}
  Result.DocumentBytes := MaximumCanonicalDocumentBytes;
  Result.TotalBytes := 64 * 1024 * 1024;
  Result.Documents := 10000;
  Result.Snapshots := 10000;
  Result.Rotations := 1000;
end;

constructor TLWPTRegistryVerifier.Create(const ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits);
begin
  inherited Create;
  if not Assigned(ASource) or (ALimits.DocumentBytes < 1)
    or (ALimits.DocumentBytes > MaximumCanonicalDocumentBytes)
    or (ALimits.TotalBytes < ALimits.DocumentBytes)
    or (ALimits.Documents < 2) or (ALimits.Snapshots < 1)
    or (ALimits.Rotations < 0) then
    raise ELWPTRegistryError.CreateStable('invalid_verification_limits',
      'verification limits are invalid');
  FSource := ASource;
  FLimits := ALimits;
  FBudget := TLWPTRegistryMetadataBudget.Create(ALimits);
  FDocumentIndexes := TDictionary<string, Integer>.Create;
  FPackages := TDictionary<string, TLWPTRegistryPackage>.Create;
end;

destructor TLWPTRegistryVerifier.Destroy;
begin
  FPackages.Free;
  FDocumentIndexes.Free;
  FBudget.Free;
  inherited Destroy;
end;

constructor TLWPTRegistryMetadataBudget.Create(const ALimits: TLWPTRegistryVerificationLimits);
begin
  inherited Create;
  FLimits := ALimits;
  if (FLimits.DocumentBytes < 1) or (FLimits.TotalBytes < FLimits.DocumentBytes)
    or (FLimits.Documents < 1) then
    raise ELWPTRegistryError.CreateStable('invalid_verification_limits',
      'verification limits are invalid');
end;

function TLWPTRegistryMetadataBudget.Allowance: Int64;
begin
  Result := FLimits.DocumentBytes;
  if Result > FLimits.TotalBytes - FBytes then Result := FLimits.TotalBytes - FBytes;
  if (Result < 1) or (FCount >= FLimits.Documents) then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: metadata budget');
end;

procedure TLWPTRegistryMetadataBudget.Account(const ABytes: TBytes);
begin
  if (Length(ABytes) > FLimits.DocumentBytes)
    or (Length(ABytes) > FLimits.TotalBytes - FBytes)
    or (FCount >= FLimits.Documents) then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: metadata budget');
  Inc(FBytes, Length(ABytes));
  Inc(FCount);
end;

function TLWPTRegistryVerifier.Read(const APath: string): TBytes;
var
  Index: Integer;
  Allowance: Int64;
begin
  if FDocumentIndexes.TryGetValue(APath, Index) then
    Exit(FDocuments[Index].Bytes);
  Allowance := FBudget.Allowance;
  Result := FSource.ReadDocument(APath, Allowance);
  FBudget.Account(Result);
  Result := Copy(Result);
  Index := Length(FDocuments);
  SetLength(FDocuments, Index + 1);
  FDocuments[Index].Path := APath;
  FDocuments[Index].Bytes := Result;
  FDocumentIndexes.Add(APath, Index);
end;

function TLWPTRegistryVerifier.PackageRecord(const AHash,
  AOrigin: string): TLWPTRegistryPackage;
begin
  if not RegistryHashIsCanonical(AHash) then
    raise ELWPTRegistryError.Create('record_hash_mismatch: invalid digest');
  if FPackages.TryGetValue(AHash, Result) then Exit;
  Result := ParseRegistryPackage(RegistryBytesText(Read('records/sha256/'
    + Copy(AHash, 8, 64) + '.toml')), AHash, AOrigin);
  FPackages.Add(AHash, Result);
end;

function PackageIdentity(const APackage: TLWPTRegistryPackage): string;
begin
  Result := APackage.Origin + #0 + APackage.Name + #0 + APackage.Version;
end;

function RegistryPackageContentEqual(const ALeft,
  ARight: TLWPTRegistryPackage): Boolean;
var
  Index: Integer;
begin
  Result := (ALeft.ArchiveHash = ARight.ArchiveHash)
    and (ALeft.ArchiveSize = ARight.ArchiveSize)
    and (Length(ALeft.Dependencies) = Length(ARight.Dependencies));
  if not Result then Exit;
  for Index := 0 to High(ALeft.Dependencies) do
    if (ALeft.Dependencies[Index].Origin <> ARight.Dependencies[Index].Origin)
      or (ALeft.Dependencies[Index].Name <> ARight.Dependencies[Index].Name)
      or (ALeft.Dependencies[Index].Version <> ARight.Dependencies[Index].Version) then
      Exit(False);
end;

procedure VerifyImmutablePackage(const AOlder, ANewer: TLWPTRegistryPackage);
begin
  if (AOlder.ArchiveHash <> ANewer.ArchiveHash)
    or (AOlder.ArchiveSize <> ANewer.ArchiveSize) then
    raise ELWPTRegistryError.Create('identity_conflict: changed immutable content');
  if not RegistryPackageContentEqual(AOlder, ANewer) then
    raise ELWPTRegistryError.Create('identity_conflict: changed dependencies');
  if (AOlder.RecordHash <> ANewer.RecordHash)
    and (AOlder.Yanked = ANewer.Yanked) then
    raise ELWPTRegistryError.Create('identity_conflict: invalid lifecycle change');
end;

function TLWPTRegistryVerifier.VerifyHistory(const AOrigin, AHeadHash: string;
  const ASequence: Int64; const APrior: TLWPTRegistryAcceptedState): TLWPTRegistryPackageArray;
var
  CurrentHash, Previous, Identity: string;
  ExpectedSequence: Int64;
  RecordIndex, SnapshotCount: Integer;
  SnapshotBytes: TBytes;
  Root: TTOMLNode;
  Records: TLWPTRegistryStringArray;
  Packages: TLWPTRegistryPackageArray;
  Package, NewerPackage: TLWPTRegistryPackage;
  NewerPackages, CurrentPackages: TDictionary<string, TLWPTRegistryPackage>;
  PriorReached: Boolean;
begin
  Result := nil;
  if not RegistryURIIsCanonical(AOrigin, True) or not RegistryHashIsCanonical(AHeadHash)
    or (ASequence < 1) then
    raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
      'snapshot history is inconsistent');
  CurrentHash := AHeadHash;
  ExpectedSequence := ASequence;
  SnapshotCount := 0;
  PriorReached := APrior.Sequence = 0;
  NewerPackages := nil;
  CurrentPackages := nil;
  try
    repeat
      FSource.CheckProgress;
      Inc(SnapshotCount);
      if SnapshotCount > FLimits.Snapshots then
        raise ELWPTRegistryError.Create('proof_limit_exceeded: snapshots');
      if (ExpectedSequence = APrior.Sequence) and (APrior.Sequence > 0) then
      begin
        if CurrentHash <> APrior.Snapshot then
          raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
            'snapshot history is inconsistent');
        PriorReached := True;
      end;
      SnapshotBytes := Read('snapshots/sha256/' + Copy(CurrentHash, 8, 64)
        + '.toml');
      if SHA256BytesPrefixed(SnapshotBytes) <> CurrentHash then
        raise ELWPTRegistryError.CreateStable('snapshot_hash_mismatch',
          'snapshot bytes do not match their hash');
      Root := ParseCanonical(RegistryBytesText(SnapshotBytes),
        PROGRAM_NAME + '-registry-snapshot-v1', ['schema', 'origin',
          'sequence', 'published_at', 'previous', 'records']);
      try
        if (TomlStr(Root, 'origin', '') <> AOrigin)
          or (UnsignedField(Root, 'sequence') <> ExpectedSequence)
          or not RegistryTimestampIsCanonical(TomlStr(Root, 'published_at', '')) then
          raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
            'snapshot history is inconsistent');
        Previous := StringField(Root, 'previous');
        if ((ExpectedSequence = 1) and (Previous <> ''))
          or ((ExpectedSequence > 1) and not RegistryHashIsCanonical(Previous)) then
          raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
            'snapshot history is inconsistent');
        Records := NodeStringArray(Root, 'records');
      finally
        Root.Free;
      end;
      SetLength(Packages, Length(Records));
      CurrentPackages := TDictionary<string, TLWPTRegistryPackage>.Create;
      for RecordIndex := 0 to High(Records) do
      begin
        Package := PackageRecord(Records[RecordIndex], AOrigin);
        Identity := PackageIdentity(Package);
        if CurrentPackages.ContainsKey(Identity) then
          raise ELWPTRegistryError.CreateStable('duplicate_package_identity',
            'snapshot contains one package identity twice');
        CurrentPackages.Add(Identity, Package);
        Packages[RecordIndex] := Package;
        if Assigned(NewerPackages) then
        begin
          if not NewerPackages.TryGetValue(Identity, NewerPackage) then
            raise ELWPTRegistryError.Create('identity_conflict: package removed');
          VerifyImmutablePackage(Package, NewerPackage);
        end;
      end;
      if SnapshotCount = 1 then Result := Copy(Packages);
      FreeAndNil(NewerPackages);
      NewerPackages := CurrentPackages;
      CurrentPackages := nil;
      if ExpectedSequence = 1 then Break;
      CurrentHash := Previous;
      Dec(ExpectedSequence);
    until False;
  finally
    CurrentPackages.Free;
    NewerPackages.Free;
  end;
  if not PriorReached then
    raise ELWPTRegistryError.Create('snapshot_consistency_failed: missing accepted head');
end;

function TLWPTRegistryVerifier.SnapshotAtSequence(const AOrigin, AHeadHash: string;
  const AHeadSequence, ATargetSequence: Int64): string;
var
  Current: string;
  Sequence: Int64;
  Bytes: TBytes;
  Root: TTOMLNode;
  Count: Integer;
begin
  Current := AHeadHash;
  Sequence := AHeadSequence;
  Count := 0;
  while Sequence > ATargetSequence do
  begin
    FSource.CheckProgress;
    Inc(Count);
    if Count > FLimits.Snapshots then
      raise ELWPTRegistryError.Create('proof_limit_exceeded: snapshots');
    Bytes := Read('snapshots/sha256/' + RegistryDigestHex(Current) + '.toml');
    if SHA256BytesPrefixed(Bytes) <> Current then
      raise ELWPTRegistryError.CreateStable('snapshot_hash_mismatch',
        'snapshot bytes do not match their hash');
    Root := ParseCanonical(RegistryBytesText(Bytes), PROGRAM_NAME + '-registry-snapshot-v1',
      ['schema', 'origin', 'sequence', 'published_at', 'previous', 'records']);
    try
      if (TomlStr(Root, 'origin', '') <> AOrigin)
        or (UnsignedField(Root, 'sequence') <> Sequence) then
        raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
          'accepted snapshot history is inconsistent');
      Current := StringField(Root, 'previous');
    finally
      Root.Free;
    end;
    Dec(Sequence);
    if not RegistryHashIsCanonical(Current) then
      raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
        'accepted snapshot history is inconsistent');
  end;
  Result := Current;
end;

function TLWPTRegistryVerifier.Verify(const AProof: TLWPTRegistryProof;
  const ATrust: TLWPTRegistryTrust;
  const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
  const AMode: TLWPTRegistryVerificationMode): TLWPTVerifiedRegistry;
var
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
  Rotation: TLWPTUntrustedRegistryRotation;
  KeyId, PublicKey, CheckpointKeyId, CheckpointPublicKey: string;
  PriorKeyId, PriorPublicKey: string;
  LastEffectiveSequence, ChainBound: Int64;
  Index: Integer;
  UsedKeys: TStringList;
  Downgrade: Boolean;
  ClockFloor: string;
begin
  Result := Default(TLWPTVerifiedRegistry);
  if not RegistryURIIsCanonical(ATrust.Origin, True)
    or not RegistryTrustRootIsValid(ATrust.KeyId, ATrust.PublicKey) then
    raise ELWPTRegistryError.CreateStable('invalid_trust_root',
      'origin identity or pinned root key is invalid');
  if not RegistryTimestampIsCanonical(AEvaluationTime) then
    raise ELWPTRegistryError.CreateStable('invalid_evaluation_time',
      'evaluation time must be canonical UTC');
  if (APrior.Sequence < 0)
    or ((APrior.Sequence > 0) and ((APrior.Origin <> ATrust.Origin)
      or not RegistryHashIsCanonical(APrior.Snapshot)
      or not RegistryTrustRootIsValid(APrior.KeyId, APrior.PublicKey)
      or not RegistryTimestampIsCanonical(APrior.PublishedAt)
      or not RegistryTimestampIsCanonical(APrior.ExpiresAt)
      or ((APrior.ClockFloor <> '')
        and not RegistryTimestampIsCanonical(APrior.ClockFloor)))) then
    raise ELWPTRegistryError.CreateStable('invalid_accepted_state',
      'prior accepted state is incomplete or belongs to another origin');
  ClockFloor := '';
  if APrior.Sequence > 0 then
    ClockFloor := RegistryLaterTimestamp(APrior.ClockFloor, APrior.PublishedAt);
  { A clock set behind accepted state could make an expired checkpoint look
    fresh again. This is a local condition, so no contact can satisfy it. }
  if AMode = rvmAcquire then RequireRegistryClockAtFloor(AEvaluationTime, ClockFloor);
  if (AMode = rvmLockedProof) and (APrior.Sequence = 0) then
    raise ELWPTRegistryError.CreateStable('locked_proof_requires_accepted_state',
      'locked proof verification requires the recorded checkpoint');
  FBudget.Account(AProof.Checkpoint);
  FBudget.Account(AProof.Signature);
  for Index := 0 to High(AProof.RetrievalDocuments) do
    FBudget.Account(AProof.RetrievalDocuments[Index]);
  if (AMode = rvmLockedProof)
    and (APrior.CheckpointHash <> SHA256BytesPrefixed(AProof.Checkpoint)) then
    raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
      'retained checkpoint bytes differ from the recorded checkpoint');
  Checkpoint := InspectRegistryCheckpoint(AProof.Checkpoint);
  if Checkpoint.Origin <> ATrust.Origin then
    raise ELWPTRegistryError.CreateStable('checkpoint_origin_mismatch',
      'checkpoint names a different origin');
  KeyId := ATrust.KeyId;
  PublicKey := ATrust.PublicKey;
  PriorKeyId := KeyId;
  PriorPublicKey := PublicKey;
  CheckpointKeyId := KeyId;
  CheckpointPublicKey := PublicKey;
  LastEffectiveSequence := 1;
  { Rotations already accepted may lie beyond an older checkpoint. The key
    that signs the checkpoint is the one effective at its own sequence. }
  ChainBound := Checkpoint.Sequence;
  if APrior.Sequence > ChainBound then ChainBound := APrior.Sequence;
  if Length(AProof.Rotations) > FLimits.Rotations then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: rotations');
  UsedKeys := TStringList.Create;
  try
    UsedKeys.CaseSensitive := True;
    UsedKeys.Sorted := True;
    UsedKeys.Add(KeyId);
    for Index := 0 to High(AProof.Rotations) do
    begin
      FSource.CheckProgress;
      FBudget.Account(AProof.Rotations[Index].Document);
      FBudget.Account(AProof.Rotations[Index].OldSignature);
      FBudget.Account(AProof.Rotations[Index].NewSignature);
      Rotation := VerifyRegistryRotation(AProof.Rotations[Index], ATrust.Origin,
        KeyId, PublicKey, LastEffectiveSequence, ChainBound);
      if UsedKeys.IndexOf(Rotation.ToKey) >= 0 then
        raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
          'rotation reuses an earlier key');
      if (Rotation.EffectiveSequence > Checkpoint.Sequence)
        and (Rotation.EffectiveSequence > APrior.Sequence) then
        raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
          'rotation is effective after the checkpoint');
      KeyId := Rotation.ToKey;
      PublicKey := Rotation.ToPublicKey;
      LastEffectiveSequence := Rotation.EffectiveSequence;
      UsedKeys.Add(KeyId);
      if Rotation.EffectiveSequence <= Checkpoint.Sequence then
      begin
        CheckpointKeyId := KeyId;
        CheckpointPublicKey := PublicKey;
      end;
      if Rotation.EffectiveSequence <= APrior.Sequence then
      begin
        PriorKeyId := KeyId;
        PriorPublicKey := PublicKey;
      end;
    end;
  finally
    UsedKeys.Free;
  end;
  if Checkpoint.KeyId <> CheckpointKeyId then
    raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
      'checkpoint key is not reached by the verified rotation chain');
  VerifySignature(PROJECT_NAME + '-REGISTRY-CHECKPOINT-V1',
    AProof.Checkpoint, ParseSignature(RegistryBytesText(AProof.Signature)),
    CheckpointKeyId, CheckpointPublicKey);
  { Every trust check precedes stale classification, so an expired or older
    response can never hide equivocation or an inconsistent history. }
  if (AMode = rvmAcquire) and (Checkpoint.PublishedAt > AEvaluationTime) then
    raise ELWPTRegistryError.CreateStable('checkpoint_from_future',
      'checkpoint publication time is later than the evaluation time');
  { An authenticated window beyond the ceiling is a signing-policy violation,
    not a stale contact. Locked proof keeps its already accepted bytes. }
  if (AMode = rvmAcquire) and (RegistryCheckpointLifetimeSeconds(
    Checkpoint.PublishedAt, Checkpoint.ExpiresAt)
    > RegistryCheckpointMaximumLifetimeSeconds + RegistryCheckpointClockSkewSeconds) then
    raise ELWPTRegistryError.CreateStable('checkpoint_lifetime_exceeded',
      'checkpoint is valid from ' + Checkpoint.PublishedAt + ' to '
      + Checkpoint.ExpiresAt + ', longer than the '
      + IntToStr(RegistryCheckpointMaximumLifetimeDays) + '-day maximum plus '
      + IntToStr(RegistryCheckpointClockSkewSeconds) + ' seconds of clock skew');
  Downgrade := False;
  if APrior.Sequence > 0 then
  begin
    { Every candidate, including an older one, must carry the chain that
      reaches the accepted key. Only then does the key selected for an older
      checkpoint come from authenticated accepted key history. }
    if (PriorKeyId <> APrior.KeyId) or (PriorPublicKey <> APrior.PublicKey) then
      raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
        'rotation chain does not preserve the accepted signing key');
    if (Checkpoint.Sequence = APrior.Sequence)
      and ((Checkpoint.Snapshot <> APrior.Snapshot)
        or (Checkpoint.KeyId <> APrior.KeyId)) then
      raise ELWPTRegistryError.CreateStable('checkpoint_equivocation',
        'same sequence names a different snapshot or key');
    if Checkpoint.Sequence < APrior.Sequence then
    begin
      if SnapshotAtSequence(ATrust.Origin, APrior.Snapshot, APrior.Sequence,
        Checkpoint.Sequence) <> Checkpoint.Snapshot then
        raise ELWPTRegistryError.CreateStable('checkpoint_equivocation',
          'older checkpoint contradicts accepted snapshot history');
      Downgrade := True;
    end;
    if (AMode = rvmLockedProof) and (Checkpoint.Sequence <> APrior.Sequence) then
      raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
        'retained checkpoint sequence differs from the recorded state');
  end;
  if not Downgrade then
    Result.Packages := VerifyHistory(ATrust.Origin, Checkpoint.Snapshot,
      Checkpoint.Sequence, APrior);
  if Downgrade then
    raise ELWPTRegistryStaleContactError.CreateStable('checkpoint_downgrade',
      'checkpoint sequence is lower than accepted state');
  if (AMode = rvmAcquire) and (Checkpoint.ExpiresAt <= AEvaluationTime) then
    raise ELWPTRegistryStaleContactError.CreateStable('checkpoint_expired',
      'checkpoint expired at ' + Checkpoint.ExpiresAt);
  { A renewal may only move both authenticated times forward. Identical
    bytes remain an idempotent replay. }
  if (APrior.Sequence > 0) and (Checkpoint.Sequence = APrior.Sequence)
    and ((Checkpoint.PublishedAt < APrior.PublishedAt)
      or (Checkpoint.ExpiresAt < APrior.ExpiresAt)) then
    raise ELWPTRegistryStaleContactError.CreateStable(
      'checkpoint_renewal_rollback',
      'same-sequence checkpoint is older than the accepted renewal');
  Result.State.Origin := ATrust.Origin;
  Result.State.KeyId := KeyId;
  Result.State.PublicKey := PublicKey;
  Result.State.Sequence := Checkpoint.Sequence;
  Result.State.Snapshot := Checkpoint.Snapshot;
  Result.State.CheckpointHash := SHA256BytesPrefixed(AProof.Checkpoint);
  Result.State.PublishedAt := Checkpoint.PublishedAt;
  Result.State.ExpiresAt := Checkpoint.ExpiresAt;
  Result.State.ClockFloor := RegistryLaterTimestamp(ClockFloor, Checkpoint.PublishedAt);
  Result.PublishedAt := Checkpoint.PublishedAt;
  Result.ExpiresAt := Checkpoint.ExpiresAt;
  Result.Documents := FDocuments;
  Result.Proof.Checkpoint := Copy(AProof.Checkpoint);
  Result.Proof.Signature := Copy(AProof.Signature);
  SetLength(Result.Proof.Rotations, Length(AProof.Rotations));
  for Index := 0 to High(AProof.Rotations) do
  begin
    Result.Proof.Rotations[Index].Document := Copy(AProof.Rotations[Index].Document);
    Result.Proof.Rotations[Index].OldSignature := Copy(AProof.Rotations[Index].OldSignature);
    Result.Proof.Rotations[Index].NewSignature := Copy(AProof.Rotations[Index].NewSignature);
  end;
end;

function VerifyRegistrySnapshotHistory(const AOrigin, AHeadHash: string;
  const ASequence: Int64; const ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTRegistryDocumentArray;
var
  Verifier: TLWPTRegistryVerifier;
begin
  Verifier := TLWPTRegistryVerifier.Create(ASource, ALimits);
  try
    Verifier.VerifyHistory(AOrigin, AHeadHash, ASequence, Default(TLWPTRegistryAcceptedState));
    Result := Verifier.FDocuments;
  finally
    Verifier.Free;
  end;
end;

function VerifyRegistryProof(const AProof: TLWPTRegistryProof;
  const ATrust: TLWPTRegistryTrust;
  const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
  const AMode: TLWPTRegistryVerificationMode;
  const ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTVerifiedRegistry;
var
  Verifier: TLWPTRegistryVerifier;
begin
  Verifier := TLWPTRegistryVerifier.Create(ASource, ALimits);
  try
    Result := Verifier.Verify(AProof, ATrust, APrior, AEvaluationTime, AMode);
  finally
    Verifier.Free;
  end;
end;

function VerifyRegistryLockedSelection(
  const ASelection: TLWPTRegistryLockedSelection;
  const ATrust: TLWPTRegistryTrust;
  const AClaims: TLWPTRegistryLockedClaims): TLWPTVerifiedRegistrySelection;
var
  Claimed: TLWPTRegistryLockedRecord;
  Package: TLWPTRegistryPackage;
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
  Rotation: TLWPTUntrustedRegistryRotation;
  KeyId, PublicKey: string;
  LastEffectiveSequence: Int64;
  Index, RecordIndex: Integer;
  Root: TTOMLNode;
  Members: TLWPTRegistryStringArray;
  RecordHash: string;
  Member: Boolean;
begin
  Result := Default(TLWPTVerifiedRegistrySelection);
  if not RegistryURIIsCanonical(ATrust.Origin, True)
    or not RegistryTrustRootIsValid(ATrust.KeyId, ATrust.PublicKey) then
    raise ELWPTRegistryError.CreateStable('invalid_trust_root',
      'origin identity or pinned root key is invalid');
  if not RegistryHashIsCanonical(AClaims.Checkpoint)
    or (SHA256BytesPrefixed(ASelection.Checkpoint) <> AClaims.Checkpoint) then
    raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
      'retained checkpoint bytes differ from the recorded checkpoint');
  if not RegistryHashIsCanonical(AClaims.Signature)
    or (SHA256BytesPrefixed(ASelection.Signature) <> AClaims.Signature) then
    raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
      'retained signature bytes differ from the recorded signature');
  if Length(ASelection.Records) <> Length(AClaims.Records) then
    raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
      'the retained records differ from the recorded selection');
  Checkpoint := InspectRegistryCheckpoint(ASelection.Checkpoint);
  if (Checkpoint.Sequence <> AClaims.Sequence)
    or (Checkpoint.KeyId <> AClaims.KeyId)
    or (Checkpoint.Snapshot <> AClaims.Snapshot)
    or (Checkpoint.PublishedAt <> AClaims.PublishedAt)
    or (Checkpoint.ExpiresAt <> AClaims.ExpiresAt) then
    raise ELWPTRegistryError.CreateStable('locked_proof_state_mismatch',
      'the retained checkpoint differs from the recorded selection proof');
  if Checkpoint.Origin <> ATrust.Origin then
    raise ELWPTRegistryError.CreateStable('checkpoint_origin_mismatch',
      'checkpoint names a different origin');
  if Length(ASelection.Rotations) > DefaultRegistryVerificationLimits.Rotations then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: rotations');
  KeyId := ATrust.KeyId;
  PublicKey := ATrust.PublicKey;
  LastEffectiveSequence := 1;
  for Index := 0 to High(ASelection.Rotations) do
  begin
    Rotation := VerifyRegistryRotation(ASelection.Rotations[Index],
      ATrust.Origin, KeyId, PublicKey, LastEffectiveSequence,
      Checkpoint.Sequence);
    KeyId := Rotation.ToKey;
    PublicKey := Rotation.ToPublicKey;
    LastEffectiveSequence := Rotation.EffectiveSequence;
  end;
  if Checkpoint.KeyId <> KeyId then
    raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
      'checkpoint key is not reached by the committed rotation chain');
  VerifySignature(PROJECT_NAME + '-REGISTRY-CHECKPOINT-V1',
    ASelection.Checkpoint, ParseSignature(RegistryBytesText(ASelection.Signature)),
    KeyId, PublicKey);
  if SHA256BytesPrefixed(ASelection.Snapshot) <> Checkpoint.Snapshot then
    raise ELWPTRegistryError.CreateStable('snapshot_hash_mismatch',
      'snapshot bytes do not match their hash');
  Root := ParseCanonical(RegistryBytesText(ASelection.Snapshot),
    PROGRAM_NAME + '-registry-snapshot-v1', ['schema', 'origin',
      'sequence', 'published_at', 'previous', 'records']);
  try
    if (TomlStr(Root, 'origin', '') <> ATrust.Origin)
      or (UnsignedField(Root, 'sequence') <> Checkpoint.Sequence) then
      raise ELWPTRegistryError.CreateStable('snapshot_consistency_failed',
        'snapshot does not belong to its checkpoint');
    Members := NodeStringArray(Root, 'records');
  finally
    Root.Free;
  end;
  SetLength(Result.Packages, Length(ASelection.Records));
  for Index := 0 to High(ASelection.Records) do
  begin
    RecordHash := SHA256BytesPrefixed(ASelection.Records[Index]);
    Claimed := AClaims.Records[Index];
    if RecordHash <> Claimed.RecordHash then
      raise ELWPTRegistryError.CreateStable('locked_record_mismatch',
        'retained record bytes differ from the recorded record hash');
    Member := False;
    for RecordIndex := 0 to High(Members) do
      if Members[RecordIndex] = RecordHash then
      begin
        Member := True;
        Break;
      end;
    if not Member then
      raise ELWPTRegistryError.CreateStable('registry_record_not_in_snapshot',
        'a selected record is not a member of the signed snapshot');
    Package := ParseRegistryPackage(
      RegistryBytesText(ASelection.Records[Index]), RecordHash, ATrust.Origin);
    if (Package.Name <> Claimed.Name) or (Package.Version <> Claimed.Version)
      or (Package.ArchiveHash <> Claimed.ArchiveHash) then
      raise ELWPTRegistryError.CreateStable('locked_record_mismatch',
        'signed record ' + RecordHash + ' is ' + Package.Name + '@'
        + Package.Version + ' with archive ' + Package.ArchiveHash
        + ', but the lock records ' + Claimed.Name + '@' + Claimed.Version
        + ' with archive ' + Claimed.ArchiveHash);
    Result.Packages[Index] := Package;
  end;
  Result.Sequence := Checkpoint.Sequence;
  Result.KeyId := Checkpoint.KeyId;
  Result.Snapshot := Checkpoint.Snapshot;
  Result.PublishedAt := Checkpoint.PublishedAt;
  Result.ExpiresAt := Checkpoint.ExpiresAt;
end;

procedure VerifyRegistryArtifact(const APackage: TLWPTRegistryPackage;
  const AArchive: TStream; const AProgress: TSHA256Progress);
begin
  if not Assigned(AArchive) or not RegistryHashIsCanonical(APackage.ArchiveHash)
    or (APackage.ArchiveSize < 0) then
    raise ELWPTRegistryError.Create('object_hash_mismatch: invalid artifact');
  AArchive.Position := 0;
  if (AArchive.Size <> APackage.ArchiveSize)
    or ('sha256:' + SHA256Stream(AArchive, AProgress) <> APackage.ArchiveHash) then
    raise ELWPTRegistryError.CreateStable('object_hash_mismatch',
      'archive bytes do not match the signed record');
  AArchive.Position := 0;
end;

end.
