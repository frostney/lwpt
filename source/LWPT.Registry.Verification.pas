{ LWPT.Registry.Verification -- shared Protocol 1 artifact verification.
  Callers own transport and persistence. All trust inputs are explicit. }
unit LWPT.Registry.Verification;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Registry.Store;

type
  ELWPTRegistryError = LWPT.Registry.Store.ELWPTRegistryError;

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
  end;

  TLWPTRegistryVerificationLimits = record
    DocumentBytes, TotalBytes: Int64;
    Documents, Snapshots, Rotations: Integer;
  end;

  TLWPTRegistryVerificationMode = (rvmAcquire, rvmLockedProof);

  { Paths are relative to the protocol API, without a leading slash.
    Providers must bound reads before allocation. The verifier checks again. }
  TLWPTRegistryDocumentSource = class
  public
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; virtual; abstract;
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
procedure ValidateRegistryKeyDocument(const ABytes: TBytes;
  const ATrust: TLWPTRegistryTrust; const ACheckpointSequence: Int64);
function ValidateRegistryCapabilities(const AContent, ARole: string;
  out AHasRotations: Boolean): Integer;
function RegistryURIIsCanonical(const AValue: string;
  AAllowLocalhostHTTP: Boolean): Boolean;
function RegistryHashIsCanonical(const AValue: string): Boolean;
function RegistryPackageNameIsCanonical(const AValue: string): Boolean;
function RegistryVersionIsCanonical(const AValue: string): Boolean;
function RegistryConstraintIsCanonical(const AValue: string): Boolean;
function RegistryTrustRootIsValid(const AKeyId, APublicKey: string): Boolean;
function ParseRegistryPackage(const AContent, AExpectedHash,
  AExpectedOrigin: string): TLWPTRegistryPackage;

{ Acquisition enforces expiry at evaluation time. Locked proof requires the
  exact already-recorded checkpoint identity and permits its later expiry.
  Prior state is caller-trusted, and must belong to the same pinned origin.
  Verification walks to genesis and returns complete metadata proof bytes. }
function VerifyRegistryProof(const AProof: TLWPTRegistryProof;
  const ATrust: TLWPTRegistryTrust;
  const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
  const AMode: TLWPTRegistryVerificationMode;
  ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits): TLWPTVerifiedRegistry;
procedure VerifyRegistryArtifact(const APackage: TLWPTRegistryPackage;
  AArchive: TStream);

implementation

uses
  DateUtils,
  Generics.Collections,

  LWPT.Core,
  LWPT.Registry.Crypto,
  Semver,
  TOML;

const
  MAXIMUM_CANONICAL_DOCUMENT_BYTES = 4 * 1024 * 1024;
  MAXIMUM_CANONICAL_DEPTH = 3;

type
  TStringArray = array of string;
  TRegistryCheckpoint = TLWPTUntrustedRegistryCheckpoint;
  TRegistrySignature = record
    KeyId, Payload, Signature: string;
  end;

function RegistryURIIsCanonical(const AValue: string;
  AAllowLocalhostHTTP: Boolean): Boolean;
begin
  try
    Result := CanonicalRegistryURL(AValue, not AAllowLocalhostHTTP) = AValue;
  except
    on E: ELWPTRegistryError do Result := False;
  end;
end;

function BytesText(const ABytes: TBytes): string;
begin
  if Length(ABytes) = 0 then Exit('');
  SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;

function TextBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then Move(AText[1], Result[0], Length(AText));
end;

function IsLowerHex(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := AValue <> '';
  for I := 1 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function ValidHash(const AValue: string): Boolean;
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

function RegistryHashIsCanonical(const AValue: string): Boolean;
begin
  Result := ValidHash(AValue);
end;

function RegistryVersionIsCanonical(const AValue: string): Boolean;
begin
  Result := IsCanonicalVersion(AValue);
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

function RegistryTimestampIsCanonical(const AValue: string): Boolean;
var
  Year, Month, Day, Hour, Minute, Second: Integer;
  Stamp: TDateTime;
  Index: Integer;
begin
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
      Word(Minute), Word(Second), 0, Stamp);
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
  Delimiters: array[1..MAXIMUM_CANONICAL_DEPTH] of Char;
begin
  Result := nil;
  if Length(AContent) > MAXIMUM_CANONICAL_DOCUMENT_BYTES then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: document bytes');
  if (AContent = '') or (AContent[Length(AContent)] <> #10)
    or (Pos(#13, AContent) > 0) or (Copy(AContent, 1, 3) = #$EF#$BB#$BF)
    or (Pos(#10#10, AContent) > 0) then
    raise ELWPTRegistryError.Create('non_canonical_document: byte framing');
  { Bound parser recursion before passing untrusted nested values to TOML. }
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
    else if AContent[I] = '"' then
    begin
      if Copy(AContent, I, 3) = '"""' then
        raise ELWPTRegistryError.Create('non_canonical_document: delimiters');
      InString := True;
    end
    else if AContent[I] in ['[', '{'] then
    begin
      Inc(Depth);
      if Depth > MAXIMUM_CANONICAL_DEPTH then
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
      if (Lines[I] = '') or (Pos('#', Lines[I]) > 0) then
        raise ELWPTRegistryError.Create(
          'non_canonical_document: comments or blank lines');
      EqualAt := Pos(' = ', Lines[I]);
      if EqualAt = 0 then
        raise ELWPTRegistryError.Create('non_canonical_document: assignment');
      Key := Copy(Lines[I], 1, EqualAt - 1);
      if Key <> AKeys[I] then
        raise ELWPTRegistryError.CreateFmt(
          'non_canonical_document: expected field "%s", got "%s"',
          [AKeys[I], Key]);
    end;
    Parser := TTOMLParser.Create;
    try
      try
        Result := Parser.ParseDocument(AContent);
      except
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

function NodeStringArray(ARoot: TTOMLNode; const AName: string): TStringArray;
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

function NodeBoolean(ARoot: TTOMLNode; const AName: string;
  ADefault: Boolean): Boolean;
var
  Node: TTOMLNode;
begin
  Node := TomlGet(ARoot, AName);
  if (Node = nil) or (Node.Kind <> tnkScalar)
    or (Node.ScalarKind <> tskBool) then
    raise ELWPTRegistryError.Create('non_canonical_document: boolean required');
  Result := Node.ScalarText = 'true';
end;

procedure ValidateRegistryKeyDocument(const ABytes: TBytes;
  const ATrust: TLWPTRegistryTrust; const ACheckpointSequence: Int64);
var
  Root: TTOMLNode;
  ValidFrom: Int64;
begin
  Root := ParseCanonical(BytesText(ABytes), PROGRAM_NAME + '-registry-key-v1',
    ['schema', 'origin', 'key_id', 'algorithm', 'public_key', 'valid_from_sequence']);
  try
    ValidFrom := UnsignedField(Root, 'valid_from_sequence');
    if not RegistryTrustRootIsValid(ATrust.KeyId, ATrust.PublicKey)
      or (StringField(Root, 'origin') <> ATrust.Origin)
      or (StringField(Root, 'key_id') <> ATrust.KeyId)
      or (StringField(Root, 'public_key') <> ATrust.PublicKey)
      or (StringField(Root, 'algorithm') <> 'ed25519')
      or (ValidFrom < 1) or (ValidFrom > ACheckpointSequence) then
      raise ELWPTRegistryError.Create('registry_key_pin_mismatch');
  finally
    Root.Free;
  end;
end;

function InspectRegistryCheckpoint(const ABody: TBytes): TLWPTUntrustedRegistryCheckpoint;
var
  Root: TTOMLNode;
begin
  Result := Default(TRegistryCheckpoint);
  Result.Bytes := Copy(ABody);
  Root := ParseCanonical(BytesText(ABody), PROGRAM_NAME + '-registry-checkpoint-v1',
    ['schema', 'origin', 'sequence', 'snapshot', 'published_at',
     'expires_at', 'key_id']);
  try
    Result.Origin := StringField(Root, 'origin');
    Result.Sequence := UnsignedField(Root, 'sequence');
    Result.Snapshot := StringField(Root, 'snapshot');
    Result.PublishedAt := StringField(Root, 'published_at');
    Result.ExpiresAt := StringField(Root, 'expires_at');
    Result.KeyId := StringField(Root, 'key_id');
    if (Result.Sequence < 1) or not ValidHash(Result.Snapshot)
      or not RegistryTimestampIsCanonical(Result.PublishedAt)
      or not RegistryTimestampIsCanonical(Result.ExpiresAt)
      or (Result.PublishedAt >= Result.ExpiresAt) then
      raise ELWPTRegistryError.Create('invalid_registry_checkpoint');
  finally
    Root.Free;
  end;
end;

function ParseSignature(const AContent: string): TRegistrySignature;
var
  Root: TTOMLNode;
begin
  Root := ParseCanonical(AContent, PROGRAM_NAME + '-registry-signature-v1',
    ['schema', 'algorithm', 'key_id', 'payload', 'signature']);
  try
    if TomlStr(Root, 'algorithm', '') <> 'ed25519' then
      raise ELWPTRegistryError.Create('unsupported_registry_signature');
    Result.KeyId := TomlStr(Root, 'key_id', '');
    Result.Payload := TomlStr(Root, 'payload', '');
    Result.Signature := TomlStr(Root, 'signature', '');
    if (Length(Result.KeyId) <> 72)
      or (Copy(Result.KeyId, 1, 8) <> 'ed25519:')
      or not IsLowerHex(Copy(Result.KeyId, 9, 64))
      or not ValidHash(Result.Payload)
      or (Length(Result.Signature) <> 132)
      or (Copy(Result.Signature, 1, 4) <> 'hex:')
      or not IsLowerHex(Copy(Result.Signature, 5, 128)) then
      raise ELWPTRegistryError.Create('invalid_registry_signature_encoding');
  finally
    Root.Free;
  end;
end;

procedure VerifySignature(const ADomain: string; const APayload: TBytes;
  const AEnvelope: TRegistrySignature; const AKeyId, APublicKey: string);
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
    raise ELWPTRegistryError.Create('invalid_registry_signature_encoding');
  DomainBytes := TextBytes(ADomain + #10);
  SetLength(MessageBytes, Length(DomainBytes) + Length(APayload));
  if Length(DomainBytes) > 0 then
    Move(DomainBytes[0], MessageBytes[0], Length(DomainBytes));
  if Length(APayload) > 0 then
    Move(APayload[0], MessageBytes[Length(DomainBytes)], Length(APayload));
  if not Ed25519Verify(MessageBytes, Key, Signature) then
    raise ELWPTRegistryError.Create('signature_invalid: Ed25519 verification failed');
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
    and (SHA256BytesPrefixed(TextBytes(AContent)) <> AExpectedHash) then
    raise ELWPTRegistryError.Create('registry_record_hash_mismatch');
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
    Result.Yanked := NodeBoolean(Root, 'yanked', False);
    if (Result.Origin <> AExpectedOrigin)
      or not RegistryPackageNameIsCanonical(Result.Name)
      or not IsCanonicalVersion(Result.Version)
      or not ValidHash(Result.ArchiveHash) or (Result.ArchiveSize < 0)
      or not RegistryTimestampIsCanonical(Result.PublishedAt) then
      raise ELWPTRegistryError.Create('invalid_registry_record');
    Deps := TomlGet(Root, 'dependencies');
    if not TomlIsArray(Deps) then
      raise ELWPTRegistryError.Create('invalid_registry_record_dependencies');
    SetLength(Result.Dependencies, Deps.Items.Count);
    CanonicalDependencyLine := 'dependencies = [';
    PreviousSortKey := '';
    for I := 0 to Deps.Items.Count - 1 do
    begin
      Item := Deps.Items[I];
      if not TomlIsTable(Item) then
        raise ELWPTRegistryError.Create('invalid_registry_dependency');
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
        raise ELWPTRegistryError.Create('invalid_registry_dependency');
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
    FBytes: Int64;
    FCount: Integer;
    FDocuments: TLWPTRegistryDocumentArray;
    FDocumentIndexes: TDictionary<string, Integer>;
    FPackages: TDictionary<string, TLWPTRegistryPackage>;
    procedure Account(const ABytes: TBytes);
    function Read(const APath: string): TBytes;
    function PackageRecord(const AHash, AOrigin: string): TLWPTRegistryPackage;
  public
    constructor Create(ASource: TLWPTRegistryDocumentSource;
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
      raise ELWPTRegistryError.Create('unsupported_registry_protocol');
    Result.Origin := TomlStr(Root, 'origin', '');
    Result.BaseURL := TomlStr(Root, 'base_url', '');
    Result.RoleName := TomlStr(Root, 'role', '');
    Result.API := TomlStr(Root, 'api', '');
    Result.Capabilities := TomlStr(Root, 'capabilities', '');
    Result.Checkpoint := TomlStr(Root, 'checkpoint', '');
    Result.Rotations := TomlStr(Root, 'rotations', '');
    if (Result.RoleName <> 'origin') and (Result.RoleName <> 'mirror') then
      raise ELWPTRegistryError.Create('invalid_registry_role');
    if not RegistryURIIsCanonical(Result.Origin, True)
      or not RegistryURIIsCanonical(Result.BaseURL, True)
      or not RegistryURIIsCanonical(Result.API, True)
      or not RegistryURIIsCanonical(Result.Capabilities, True)
      or not RegistryURIIsCanonical(Result.Checkpoint, True)
      or ((TomlGet(Root, 'rotations') <> nil)
        and not RegistryURIIsCanonical(Result.Rotations, True)) then
      raise ELWPTRegistryError.Create('invalid_registry_discovery_uri');
    if (Length(Result.Checkpoint) <= 5)
      or (Copy(Result.Checkpoint, Length(Result.Checkpoint) - 4, 5)
        <> '.toml') then
      raise ELWPTRegistryError.Create('invalid_registry_checkpoint_uri');
  finally
    Root.Free;
  end;
end;

function ValidateRegistryCapabilities(const AContent: string;
  const ARole: string; out AHasRotations: Boolean): Integer;
const
  REQUIRED_SCHEMAS: array[0..4] of string = (
    PROGRAM_NAME + '-registry-checkpoint-v1', PROGRAM_NAME + '-registry-discovery-v1',
    PROGRAM_NAME + '-registry-package-v1', PROGRAM_NAME + '-registry-signature-v1',
    PROGRAM_NAME + '-registry-snapshot-v1');
var
  Root: TTOMLNode;
  Hashes, Signatures, Schemas, Features, AuthSchemes: TStringArray;
  I: Integer;
  function Contains(const AValues: TStringArray; const AValue: string): Boolean;
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
      raise ELWPTRegistryError.Create('unsupported_registry_protocol');
    Hashes := NodeStringArray(Root, 'hashes');
    Signatures := NodeStringArray(Root, 'signatures');
    Schemas := NodeStringArray(Root, 'schemas');
    Features := NodeStringArray(Root, 'features');
    AHasRotations := Contains(Features, 'rotation-chain-v1');
    AuthSchemes := NodeStringArray(Root, 'auth_schemes');
    if UnsignedField(Root, 'max_page_size') > High(Integer) then
      raise ELWPTRegistryError.Create('registry_capability_missing');
    Result := UnsignedField(Root, 'max_page_size');
    if not Contains(Hashes, 'sha256') or not Contains(Signatures, 'ed25519')
      or not Contains(Features, 'snapshot-sync-v1')
      or (Result < 1) then
      raise ELWPTRegistryError.Create('registry_capability_missing');
    for I := 0 to High(REQUIRED_SCHEMAS) do
      if not Contains(Schemas, REQUIRED_SCHEMAS[I]) then
        raise ELWPTRegistryError.Create('registry_schema_capability_missing');
    if ARole = 'mirror' then
    begin
      if Contains(Features, 'publication-v1') then
        raise ELWPTRegistryError.Create('mirror_advertises_publication');
      if Length(AuthSchemes) <> 0 then
        raise ELWPTRegistryError.Create('mirror_advertises_authentication');
    end
    else if Contains(Features, 'publication-v1')
      and (Length(AuthSchemes) = 0) then
      raise ELWPTRegistryError.Create('origin_publication_capability_missing');
    if (ARole = 'origin') and not Contains(Features, 'publication-v1')
      and (Length(AuthSchemes) <> 0) then
      raise ELWPTRegistryError.Create('read_only_origin_advertises_authentication');
  finally
    Root.Free;
  end;
end;

function DefaultRegistryVerificationLimits: TLWPTRegistryVerificationLimits;
begin
  Result.DocumentBytes := MAXIMUM_CANONICAL_DOCUMENT_BYTES;
  Result.TotalBytes := 64 * 1024 * 1024;
  Result.Documents := 10000;
  Result.Snapshots := 10000;
  Result.Rotations := 1000;
end;

constructor TLWPTRegistryVerifier.Create(ASource: TLWPTRegistryDocumentSource;
  const ALimits: TLWPTRegistryVerificationLimits);
begin
  inherited Create;
  if not Assigned(ASource) or (ALimits.DocumentBytes < 1)
    or (ALimits.DocumentBytes > MAXIMUM_CANONICAL_DOCUMENT_BYTES)
    or (ALimits.TotalBytes < ALimits.DocumentBytes)
    or (ALimits.Documents < 2) or (ALimits.Snapshots < 1)
    or (ALimits.Rotations < 0) then
    raise ELWPTRegistryError.Create('invalid_verification_limits');
  FSource := ASource;
  FLimits := ALimits;
  FDocumentIndexes := TDictionary<string, Integer>.Create;
  FPackages := TDictionary<string, TLWPTRegistryPackage>.Create;
end;

destructor TLWPTRegistryVerifier.Destroy;
begin
  FPackages.Free;
  FDocumentIndexes.Free;
  inherited Destroy;
end;

procedure TLWPTRegistryVerifier.Account(const ABytes: TBytes);
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
  Allowance := FLimits.DocumentBytes;
  if Allowance > FLimits.TotalBytes - FBytes then
    Allowance := FLimits.TotalBytes - FBytes;
  if (Allowance < 1) or (FCount >= FLimits.Documents) then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: metadata budget');
  Result := FSource.ReadDocument(APath, Allowance);
  Account(Result);
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
  if not ValidHash(AHash) then
    raise ELWPTRegistryError.Create('record_hash_mismatch: invalid digest');
  if FPackages.TryGetValue(AHash, Result) then Exit;
  Result := ParseRegistryPackage(BytesText(Read('records/sha256/'
    + Copy(AHash, 8, 64) + '.toml')), AHash, AOrigin);
  FPackages.Add(AHash, Result);
end;

function PackageIdentity(const APackage: TLWPTRegistryPackage): string;
begin
  Result := APackage.Origin + #0 + APackage.Name + #0 + APackage.Version;
end;

procedure VerifyImmutablePackage(const AOlder, ANewer: TLWPTRegistryPackage);
var
  Index: Integer;
begin
  if (AOlder.ArchiveHash <> ANewer.ArchiveHash)
    or (AOlder.ArchiveSize <> ANewer.ArchiveSize)
    or (Length(AOlder.Dependencies) <> Length(ANewer.Dependencies)) then
    raise ELWPTRegistryError.Create('identity_conflict: changed immutable content');
  for Index := 0 to High(AOlder.Dependencies) do
    if (AOlder.Dependencies[Index].Origin <> ANewer.Dependencies[Index].Origin)
      or (AOlder.Dependencies[Index].Name <> ANewer.Dependencies[Index].Name)
      or (AOlder.Dependencies[Index].Version <> ANewer.Dependencies[Index].Version) then
      raise ELWPTRegistryError.Create('identity_conflict: changed dependencies');
  if (AOlder.RecordHash <> ANewer.RecordHash)
    and (AOlder.Yanked = ANewer.Yanked) then
    raise ELWPTRegistryError.Create('identity_conflict: invalid lifecycle change');
end;

function TLWPTRegistryVerifier.Verify(const AProof: TLWPTRegistryProof;
  const ATrust: TLWPTRegistryTrust;
  const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
  const AMode: TLWPTRegistryVerificationMode): TLWPTVerifiedRegistry;
var
  Checkpoint: TRegistryCheckpoint;
  Root: TTOMLNode;
  KeyId, PublicKey, ToKey, ToPublicKey, CurrentHash, Previous: string;
  PriorKeyId, PriorPublicKey, Identity: string;
  EffectiveSequence, LastEffectiveSequence, ExpectedSequence: Int64;
  Index, RecordIndex, SnapshotCount: Integer;
  Records: TStringArray;
  Packages: TLWPTRegistryPackageArray;
  Package, NewerPackage: TLWPTRegistryPackage;
  NewerPackages, CurrentPackages: TDictionary<string, TLWPTRegistryPackage>;
  UsedKeys: TStringList;
  SnapshotBytes: TBytes;
  PriorReached: Boolean;
begin
  Result := Default(TLWPTVerifiedRegistry);
  if not RegistryURIIsCanonical(ATrust.Origin, True)
    or not RegistryTrustRootIsValid(ATrust.KeyId, ATrust.PublicKey) then
    raise ELWPTRegistryError.Create('invalid_trust_root');
  if not RegistryTimestampIsCanonical(AEvaluationTime) then
    raise ELWPTRegistryError.Create('invalid_evaluation_time');
  if (APrior.Sequence < 0)
    or ((APrior.Sequence > 0) and ((APrior.Origin <> ATrust.Origin)
      or not ValidHash(APrior.Snapshot)
      or not RegistryTrustRootIsValid(APrior.KeyId, APrior.PublicKey))) then
    raise ELWPTRegistryError.Create('invalid_accepted_state');
  if (AMode = rvmLockedProof) and (APrior.Sequence = 0) then
    raise ELWPTRegistryError.Create('locked_proof_requires_accepted_state');
  Account(AProof.Checkpoint);
  Account(AProof.Signature);
  if (AMode = rvmLockedProof)
    and (APrior.CheckpointHash <> SHA256BytesPrefixed(AProof.Checkpoint)) then
    raise ELWPTRegistryError.Create('locked_proof_state_mismatch');
  Checkpoint := InspectRegistryCheckpoint(AProof.Checkpoint);
  if Checkpoint.Origin <> ATrust.Origin then
    raise ELWPTRegistryError.Create('checkpoint_origin_mismatch');
  KeyId := ATrust.KeyId;
  PublicKey := ATrust.PublicKey;
  PriorKeyId := KeyId;
  PriorPublicKey := PublicKey;
  LastEffectiveSequence := 1;
  if Length(AProof.Rotations) > FLimits.Rotations then
    raise ELWPTRegistryError.Create('proof_limit_exceeded: rotations');
  UsedKeys := TStringList.Create;
  try
    UsedKeys.CaseSensitive := True;
    UsedKeys.Sorted := True;
    UsedKeys.Add(KeyId);
    for Index := 0 to High(AProof.Rotations) do
    begin
      Account(AProof.Rotations[Index].Document);
      Account(AProof.Rotations[Index].OldSignature);
      Account(AProof.Rotations[Index].NewSignature);
      Root := ParseCanonical(BytesText(AProof.Rotations[Index].Document),
        PROGRAM_NAME + '-registry-key-rotation-v1', ['schema', 'origin',
          'from_key', 'to_key', 'to_public_key', 'effective_sequence']);
      try
        ToKey := TomlStr(Root, 'to_key', '');
        ToPublicKey := TomlStr(Root, 'to_public_key', '');
        EffectiveSequence := UnsignedField(Root, 'effective_sequence');
        if (TomlStr(Root, 'origin', '') <> ATrust.Origin)
          or (TomlStr(Root, 'from_key', '') <> KeyId)
          or not RegistryTrustRootIsValid(ToKey, ToPublicKey)
          or (UsedKeys.IndexOf(ToKey) >= 0)
          or (EffectiveSequence <= LastEffectiveSequence)
          or (EffectiveSequence > Checkpoint.Sequence) then
          raise ELWPTRegistryError.Create('rotation_chain_invalid');
      finally
        Root.Free;
      end;
      VerifySignature(PROJECT_NAME + '-REGISTRY-KEY-ROTATION-V1',
        AProof.Rotations[Index].Document,
        ParseSignature(BytesText(AProof.Rotations[Index].OldSignature)),
        KeyId, PublicKey);
      VerifySignature(PROJECT_NAME + '-REGISTRY-KEY-ROTATION-V1',
        AProof.Rotations[Index].Document,
        ParseSignature(BytesText(AProof.Rotations[Index].NewSignature)),
        ToKey, ToPublicKey);
      KeyId := ToKey;
      PublicKey := ToPublicKey;
      LastEffectiveSequence := EffectiveSequence;
      UsedKeys.Add(KeyId);
      if EffectiveSequence <= APrior.Sequence then
      begin
        PriorKeyId := KeyId;
        PriorPublicKey := PublicKey;
      end;
    end;
  finally
    UsedKeys.Free;
  end;
  if Checkpoint.KeyId <> KeyId then
    raise ELWPTRegistryError.Create('rotation_chain_invalid: checkpoint key');
  VerifySignature(PROJECT_NAME + '-REGISTRY-CHECKPOINT-V1',
    AProof.Checkpoint, ParseSignature(BytesText(AProof.Signature)),
    KeyId, PublicKey);
  if (AMode = rvmAcquire) and (Checkpoint.ExpiresAt <= AEvaluationTime) then
    raise ELWPTRegistryError.Create('checkpoint_expired');
  if (AMode = rvmAcquire) and (Checkpoint.PublishedAt > AEvaluationTime) then
    raise ELWPTRegistryError.Create('checkpoint_from_future');
  if APrior.Sequence > 0 then
  begin
    if Checkpoint.Sequence < APrior.Sequence then
      raise ELWPTRegistryError.Create('checkpoint_downgrade');
    if (PriorKeyId <> APrior.KeyId) or (PriorPublicKey <> APrior.PublicKey) then
      raise ELWPTRegistryError.Create('rotation_chain_invalid: accepted key');
    if (Checkpoint.Sequence = APrior.Sequence)
      and ((Checkpoint.Snapshot <> APrior.Snapshot)
        or (Checkpoint.KeyId <> APrior.KeyId)) then
      raise ELWPTRegistryError.Create('checkpoint_equivocation');
    if (AMode = rvmLockedProof) and (Checkpoint.Sequence <> APrior.Sequence) then
      raise ELWPTRegistryError.Create('locked_proof_state_mismatch');
  end;
  CurrentHash := Checkpoint.Snapshot;
  ExpectedSequence := Checkpoint.Sequence;
  SnapshotCount := 0;
  PriorReached := APrior.Sequence = 0;
  NewerPackages := nil;
  CurrentPackages := nil;
  try
    repeat
      Inc(SnapshotCount);
      if SnapshotCount > FLimits.Snapshots then
        raise ELWPTRegistryError.Create('proof_limit_exceeded: snapshots');
      if (ExpectedSequence = APrior.Sequence) and (APrior.Sequence > 0) then
      begin
        if CurrentHash <> APrior.Snapshot then
          raise ELWPTRegistryError.Create('snapshot_consistency_failed');
        PriorReached := True;
      end;
      SnapshotBytes := Read('snapshots/sha256/' + Copy(CurrentHash, 8, 64)
        + '.toml');
      if SHA256BytesPrefixed(SnapshotBytes) <> CurrentHash then
        raise ELWPTRegistryError.Create('snapshot_hash_mismatch');
      Root := ParseCanonical(BytesText(SnapshotBytes),
        PROGRAM_NAME + '-registry-snapshot-v1', ['schema', 'origin',
          'sequence', 'published_at', 'previous', 'records']);
      try
        if (TomlStr(Root, 'origin', '') <> ATrust.Origin)
          or (UnsignedField(Root, 'sequence') <> ExpectedSequence)
          or not RegistryTimestampIsCanonical(TomlStr(Root, 'published_at', '')) then
          raise ELWPTRegistryError.Create('snapshot_consistency_failed');
        Previous := StringField(Root, 'previous');
        if ((ExpectedSequence = 1) and (Previous <> ''))
          or ((ExpectedSequence > 1) and not ValidHash(Previous)) then
          raise ELWPTRegistryError.Create('snapshot_consistency_failed');
        Records := NodeStringArray(Root, 'records');
      finally
        Root.Free;
      end;
      SetLength(Packages, Length(Records));
      CurrentPackages := TDictionary<string, TLWPTRegistryPackage>.Create;
      for RecordIndex := 0 to High(Records) do
      begin
        Package := PackageRecord(Records[RecordIndex], ATrust.Origin);
        Identity := PackageIdentity(Package);
        if CurrentPackages.ContainsKey(Identity) then
          raise ELWPTRegistryError.Create('duplicate_package_identity');
        CurrentPackages.Add(Identity, Package);
        Packages[RecordIndex] := Package;
        if Assigned(NewerPackages) then
        begin
          if not NewerPackages.TryGetValue(Identity, NewerPackage) then
            raise ELWPTRegistryError.Create('identity_conflict: package removed');
          VerifyImmutablePackage(Package, NewerPackage);
        end;
      end;
      if SnapshotCount = 1 then Result.Packages := Copy(Packages);
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
  Result.State.Origin := ATrust.Origin;
  Result.State.KeyId := KeyId;
  Result.State.PublicKey := PublicKey;
  Result.State.Sequence := Checkpoint.Sequence;
  Result.State.Snapshot := Checkpoint.Snapshot;
  Result.State.CheckpointHash := SHA256BytesPrefixed(AProof.Checkpoint);
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

function VerifyRegistryProof(const AProof: TLWPTRegistryProof;
  const ATrust: TLWPTRegistryTrust;
  const APrior: TLWPTRegistryAcceptedState; const AEvaluationTime: string;
  const AMode: TLWPTRegistryVerificationMode;
  ASource: TLWPTRegistryDocumentSource;
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

procedure VerifyRegistryArtifact(const APackage: TLWPTRegistryPackage;
  AArchive: TStream);
begin
  if not Assigned(AArchive) or not ValidHash(APackage.ArchiveHash)
    or (APackage.ArchiveSize < 0) then
    raise ELWPTRegistryError.Create('object_hash_mismatch: invalid artifact');
  AArchive.Position := 0;
  if (AArchive.Size <> APackage.ArchiveSize)
    or ('sha256:' + SHA256Stream(AArchive) <> APackage.ArchiveHash) then
    raise ELWPTRegistryError.Create('object_hash_mismatch');
  AArchive.Position := 0;
end;

end.
