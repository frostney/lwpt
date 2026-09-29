{ LWPT.Registry.Client -- shared Protocol 1 acquisition over one contact.

  Mirror synchronization and dependency installation both acquire a signed
  registry head the same way: discovery, capabilities, the checkpoint and
  signature pair, and the rotation chain from a pinned key. This unit owns
  those requests. Callers own the prior accepted state, proof verification
  (VerifyRegistryProof), persistence, and contact selection (ADR-0045,
  ADR-0051). }
unit LWPT.Registry.Client;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  HTTPClient,
  LWPT.Core,
  LWPT.Registry.Store,
  LWPT.Registry.Verification;

const
  { Per-request deadline shared by mirror synchronization and consumers. }
  RegistryRequestTimeoutMilliseconds = 120 * 1000;
  { A checkpoint and its signature come from two mutable latest URLs. Retry
    only while the checkpoint itself advances between the reads. }
  RegistryCheckpointPairAttempts = 3;
  RegistryLocalHTTPPrefix = 'http://localhost';
  RegistryLoopbackAddress = '127.0.0.1';
  { Stable code of every request-layer failure: an HTTPClient exception or a
    non-200 response, including any redirect. Consumers advance to the next
    contact on exactly this code (ADR-0051). }
  RegistryTransportFailedCode = 'registry_transport_failed';

type
  { One acquisition from one contact. Rotation retrieval starts after the
    last seeded rotation in Proof, or at the pinned key. }
  TLWPTRegistryAcquisition = class
  private
    FBudget: TLWPTRegistryMetadataBudget;
    procedure RequireScope(const AURL: string);
  protected
    { Bytes of one request; the default uses GetRegistryDocument. }
    function Fetch(const AURL, AMediaType: string;
      const AMaximumBytes: Int64): TBytes; virtual;
    function RequestTimeoutMilliseconds: QWord; virtual;
    function Destination: THTTPDestinationPolicy; virtual;
    { Runs after one dual-signed rotation and its key record verified. }
    procedure RotationAccepted(const ARotation: TLWPTRegistryRotationProof;
      const ASequence: Int64; const AKeyDocument: TBytes); virtual;
  public
    { Canonical contact base URL. }
    Contact: string;
    { Expected origin identity. Empty accepts the identity the contact
      advertises; the caller must then verify the checkpoint under its pin
      with that identity before trusting it (ADR-0051 decision 2). }
    Identity: string;
    TrustKeyId, TrustPublicKey: string;
    { Highest accepted sequence whose key chain Proof already carries. }
    PriorSequence: Int64;
    { The mirror retains the pinned key record; a consumer requests it only
      when a rotation must be discovered. }
    AlwaysFetchRootKey: Boolean;
    Proof: TLWPTRegistryProof;
    Discovery: TLWPTRegistryDiscovery;
    KeyDocument: TBytes;
    Hint: TLWPTUntrustedRegistryCheckpoint;
    constructor Create(ABudget: TLWPTRegistryMetadataBudget);
    { One bounded control request, charged to the budget. Auxiliary bytes
      are retrieval documents, charged again by the verifier. }
    function Control(const AURL, AKind: string;
      const AAuxiliary: Boolean = True): TBytes;
    procedure Acquire;
  end;

{ The development exception for plain HTTP names exactly localhost; it is
  dialled at 127.0.0.1. Empty for every other URL. }
function RegistryConnectAddress(const AURL: string): string;
{ Discovery may only name resources below the contact, in unambiguous
  segments. }
function RegistryEndpointSuffixIsUnambiguous(const ASuffix: string): Boolean;
function RegistryMediaType(const AKind: string): string;
procedure RequireRegistryRequestURI(const AURL: string);
{ One GET without redirects. Every HTTPClient exception and non-200 status
  raises RegistryTransportFailedCode; a wrong media type or any content
  encoding is a protocol failure. }
function GetRegistryDocument(const AURL, AMediaType: string;
  const AMaximumBytes: Int64; const ATimeoutMilliseconds: QWord;
  const ADestination: THTTPDestinationPolicy): TBytes;
procedure RememberRegistryRetrieval(var AProof: TLWPTRegistryProof;
  const ABytes: TBytes);
{ True when AError is a request-layer failure. }
function IsRegistryTransportFailure(const AError: Exception): Boolean;

implementation

uses
  StrUtils;

function RegistryConnectAddress(const AURL: string): string;
begin
  Result := '';
  if StartsStr(RegistryLocalHTTPPrefix, AURL)
    and ((Length(AURL) = Length(RegistryLocalHTTPPrefix))
      or (AURL[Length(RegistryLocalHTTPPrefix) + 1] in [':', '/', '?'])) then
    Result := RegistryLoopbackAddress;
end;

function RegistryEndpointSuffixIsUnambiguous(const ASuffix: string): Boolean;
var
  Segments: TStringList;
  Segment: string;
  Character: Char;
begin
  Result := ASuffix <> '';
  if not Result then Exit;
  Segments := TStringList.Create;
  try
    Segments.StrictDelimiter := True;
    Segments.Delimiter := '/';
    Segments.DelimitedText := ASuffix;
    for Segment in Segments do
    begin
      if (Segment = '') or (Segment = '.') or (Segment = '..') then Exit(False);
      for Character in Segment do
        if not (Character in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']) then
          Exit(False);
    end;
  finally
    Segments.Free;
  end;
end;

function RegistryMediaType(const AKind: string): string;
begin
  Result := 'application/vnd.' + PROGRAM_NAME + '.registry-' + AKind + '+toml';
end;

procedure RequireRegistryRequestURI(const AURL: string);
var
  CanonicalBase: string;
begin
  CanonicalBase := AURL;
  if Pos('?', CanonicalBase) > 0 then
    CanonicalBase := Copy(CanonicalBase, 1, Pos('?', CanonicalBase) - 1);
  if not RegistryURIIsCanonical(CanonicalBase, True) or (Pos('#', AURL) > 0) then
    raise ELWPTRegistryError.CreateStable('invalid_registry_uri', 'noncanonical request URI');
end;

function GetRegistryDocument(const AURL, AMediaType: string;
  const AMaximumBytes: Int64; const ATimeoutMilliseconds: QWord;
  const ADestination: THTTPDestinationPolicy): TBytes;
var
  Options: THTTPRequestOptions;
  Headers: THTTPHeaders;
  Response: THTTPResponse;
  Header: THTTPHeader;
  ContentType: string;
begin
  RequireRegistryRequestURI(AURL);
  Options := DefaultHTTPRequestOptions;
  Options.MaxResponseBodyBytes := AMaximumBytes;
  Options.RequestTimeoutMilliseconds := ATimeoutMilliseconds;
  { Discovery endpoints are scoped to the contact. Never follow a redirect:
    a 3xx is a request-layer failure. }
  Options.MaximumRedirects := 0;
  Options.Destination := ADestination;
  Options.ConnectAddress := RegistryConnectAddress(AURL);
  SetLength(Headers, 1);
  Headers[0].Name := 'Accept';
  Headers[0].Value := AMediaType;
  try
    Response := HTTPGet(AURL, Headers, Options);
  except
    on E: EHTTPError do
      raise ELWPTRegistryError.CreateStable(RegistryTransportFailedCode, E.Message);
  end;
  if Response.StatusCode <> 200 then
    raise ELWPTRegistryError.CreateStable(RegistryTransportFailedCode,
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

procedure RememberRegistryRetrieval(var AProof: TLWPTRegistryProof;
  const ABytes: TBytes);
var
  Index: Integer;
begin
  Index := Length(AProof.RetrievalDocuments);
  SetLength(AProof.RetrievalDocuments, Index + 1);
  AProof.RetrievalDocuments[Index] := ABytes;
end;

function IsRegistryTransportFailure(const AError: Exception): Boolean;
begin
  Result := (AError is ELWPTRegistryError)
    and StartsStr(RegistryTransportFailedCode + ':', AError.Message);
end;

constructor TLWPTRegistryAcquisition.Create(ABudget: TLWPTRegistryMetadataBudget);
begin
  inherited Create;
  FBudget := ABudget;
  Proof := Default(TLWPTRegistryProof);
end;

function TLWPTRegistryAcquisition.RequestTimeoutMilliseconds: QWord;
begin
  Result := RegistryRequestTimeoutMilliseconds;
end;

function TLWPTRegistryAcquisition.Destination: THTTPDestinationPolicy;
begin
  Result := Default(THTTPDestinationPolicy);
end;

function TLWPTRegistryAcquisition.Fetch(const AURL, AMediaType: string;
  const AMaximumBytes: Int64): TBytes;
begin
  Result := GetRegistryDocument(AURL, AMediaType, AMaximumBytes,
    RequestTimeoutMilliseconds, Destination);
end;

procedure TLWPTRegistryAcquisition.RotationAccepted(
  const ARotation: TLWPTRegistryRotationProof; const ASequence: Int64;
  const AKeyDocument: TBytes);
begin
end;

function TLWPTRegistryAcquisition.Control(const AURL, AKind: string;
  const AAuxiliary: Boolean): TBytes;
var
  Allowance: Int64;
begin
  Allowance := FBudget.Allowance;
  if Allowance > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES then
    Allowance := MAX_REGISTRY_CONTROL_DOCUMENT_BYTES;
  Result := Fetch(AURL, RegistryMediaType(AKind), Allowance);
  FBudget.Account(Result);
  if AAuxiliary then RememberRegistryRetrieval(Proof, Result);
end;

procedure TLWPTRegistryAcquisition.RequireScope(const AURL: string);
begin
  if not StartsStr(Contact + '/', AURL)
    or not RegistryEndpointSuffixIsUnambiguous(Copy(AURL, Length(Contact) + 2, MaxInt)) then
    raise ELWPTRegistryError.CreateStable('registry_discovery_scope_mismatch',
      'discovery endpoint escapes or ambiguously encodes the configured transport');
end;

procedure TLWPTRegistryAcquisition.Acquire;
var
  Document, NextCheckpoint: TBytes;
  HasRotations: Boolean;
  PageSize, Index, PairAttempt: Integer;
  AfterSequence, PreviousSequence, PinnedSequence: Int64;
  CurrentKey, CurrentPublicKey, Cursor, PageURL, SignatureURL: string;
  Rotation: TLWPTUntrustedRegistryRotation;
  RotationProof: TLWPTRegistryRotationProof;
  Trust, KeyTrust: TLWPTRegistryTrust;
  Page: TLWPTRegistryRotationPage;
  PageItem: TLWPTRegistryRotationPageItem;
  Cursors: TStringList;
begin
  Cursors := TStringList.Create;
  try
    Document := Control(Contact + '/.well-known/' + PROGRAM_NAME + '-registry', 'discovery');
    Discovery := ParseRegistryDiscovery(RegistryBytesText(Document));
    if Identity = '' then Identity := Discovery.Origin
    else if Discovery.Origin <> Identity then
      raise ELWPTRegistryError.CreateStable('registry_origin_mismatch', 'discovery changed the pinned identity');
    if Discovery.BaseURL <> Contact then
      raise ELWPTRegistryError.CreateStable('registry_discovery_scope_mismatch', 'discovery changed the contact base');
    RequireScope(Discovery.API);
    RequireScope(Discovery.Capabilities);
    RequireScope(Discovery.Checkpoint);
    if Discovery.Rotations <> '' then RequireScope(Discovery.Rotations);
    Document := Control(Discovery.Capabilities, 'capabilities');
    PageSize := ValidateRegistryCapabilities(RegistryBytesText(Document), Discovery.RoleName, HasRotations);
    if PageSize > RegistryRotationPageLimit then PageSize := RegistryRotationPageLimit;
    if HasRotations <> (Discovery.Rotations <> '') then
      raise ELWPTRegistryError.CreateStable('registry_rotation_capability_mismatch', 'inconsistent discovery capabilities');
    SignatureURL := Copy(Discovery.Checkpoint, 1, Length(Discovery.Checkpoint) - 5) + '.sig.toml';
    Proof.Checkpoint := Control(Discovery.Checkpoint, 'checkpoint', False);
    PairAttempt := 1;
    repeat
      Proof.Signature := Control(SignatureURL, 'signature', False);
      { A malformed envelope fails here, before any key or rotation request. }
      if InspectRegistrySignaturePayload(Proof.Signature)
        = SHA256BytesPrefixed(Proof.Checkpoint) then Break;
      { Only a checkpoint that advanced between the reads is retried; a
        stable or persistently inconsistent pair is rejected now. }
      if PairAttempt >= RegistryCheckpointPairAttempts then
        raise ELWPTRegistryError.CreateStable('signature_payload_mismatch',
          'checkpoint and signature stayed inconsistent');
      Inc(PairAttempt);
      NextCheckpoint := Control(Discovery.Checkpoint, 'checkpoint', False);
      if SHA256BytesPrefixed(NextCheckpoint) = SHA256BytesPrefixed(Proof.Checkpoint) then
        raise ELWPTRegistryError.CreateStable('signature_payload_mismatch',
          'signature names a different checkpoint');
      Proof.Checkpoint := NextCheckpoint;
    until False;
    Hint := InspectRegistryCheckpoint(Proof.Checkpoint);
    { Identity contradictions are decidable now; reject them before any key
      record or rotation request. Cryptography still follows the chain. }
    if Hint.Origin <> Identity then
      raise ELWPTRegistryError.CreateStable('checkpoint_origin_mismatch',
        'checkpoint names a different origin');
    if InspectRegistrySignatureKey(Proof.Signature) <> Hint.KeyId then
      raise ELWPTRegistryError.CreateStable('signature_key_mismatch',
        'signature names a different key than its checkpoint');
    Trust.Origin := Identity;
    Trust.KeyId := TrustKeyId;
    Trust.PublicKey := TrustPublicKey;
    CurrentKey := TrustKeyId;
    CurrentPublicKey := TrustPublicKey;
    AfterSequence := 0;
    PinnedSequence := 0;
    if Length(Proof.Rotations) > 0 then
    begin
      Rotation := InspectRegistryRotation(Proof.Rotations[High(Proof.Rotations)].Document);
      CurrentKey := Rotation.ToKey;
      CurrentPublicKey := Rotation.ToPublicKey;
    end;
    { The root key record's effective sequence is unsigned retrieval data.
      It is bound to this attempt's state only, never to a fixed path. }
    if AlwaysFetchRootKey
      or ((CurrentKey <> Hint.KeyId) and (Hint.Sequence > PriorSequence)) then
    begin
      KeyDocument := Control(Discovery.API + '/keys/' + TrustKeyId + '.toml', 'key');
      PinnedSequence := ValidateRegistryKeyDocument(KeyDocument, Trust, Hint.Sequence);
    end;
    if PinnedSequence > 1 then AfterSequence := PinnedSequence;
    if Length(Proof.Rotations) > 0 then AfterSequence := Rotation.EffectiveSequence;
    PreviousSequence := AfterSequence;
    Cursor := '';
    { An older or equal checkpoint is authenticated by the accepted chain;
      rotation retrieval only extends it forward. }
    while (CurrentKey <> Hint.KeyId) and (Hint.Sequence > PriorSequence) do
    begin
      if not HasRotations then
        raise ELWPTRegistryError.CreateStable('registry_key_rotation_incomplete',
          'checkpoint key is untrusted and the upstream offers no rotation chain');
      PageURL := Discovery.Rotations + '?after=' + IntToStr(AfterSequence)
        + '&limit=' + IntToStr(PageSize);
      if Cursor <> '' then PageURL := PageURL + '&cursor=' + RegistryQueryEncode(Cursor);
      Document := Control(PageURL, 'rotation-page');
      Page := ParseRegistryRotationPage(Document, Identity, Discovery.API,
        PreviousSequence, PageSize);
      for PageItem in Page.Items do
      begin
        if (PageItem.EffectiveSequence > Hint.Sequence)
          or (Length(Proof.Rotations) >= DefaultRegistryVerificationLimits.Rotations) then
          raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
            'rotation page exceeds the checkpoint or rotation limit');
        RotationProof.Document := Control(PageItem.Rotation, 'key-rotation', False);
        RotationProof.OldSignature := Control(PageItem.OldSignature, 'signature', False);
        RotationProof.NewSignature := Control(PageItem.NewSignature, 'signature', False);
        { Authenticate this transition before trusting its key or following
          any further page item. }
        Rotation := VerifyRegistryRotation(RotationProof, Identity, CurrentKey,
          CurrentPublicKey, PreviousSequence, Hint.Sequence);
        if Rotation.EffectiveSequence <> PageItem.EffectiveSequence then
          raise ELWPTRegistryError.CreateStable('rotation_chain_invalid',
            'rotation page item names a different sequence');
        KeyTrust.Origin := Identity;
        KeyTrust.KeyId := Rotation.ToKey;
        KeyTrust.PublicKey := Rotation.ToPublicKey;
        Document := Control(Discovery.API + '/keys/' + Rotation.ToKey + '.toml', 'key');
        ValidateRegistryKeyDocument(Document, KeyTrust, Rotation.EffectiveSequence, True);
        Index := Length(Proof.Rotations);
        SetLength(Proof.Rotations, Index + 1);
        Proof.Rotations[Index] := RotationProof;
        RotationAccepted(RotationProof, Rotation.EffectiveSequence, Document);
        CurrentKey := Rotation.ToKey;
        CurrentPublicKey := Rotation.ToPublicKey;
        PreviousSequence := Rotation.EffectiveSequence;
        if CurrentKey = Hint.KeyId then Break;
      end;
      if CurrentKey = Hint.KeyId then Break;
      if (Page.NextCursor = '') or (Cursors.IndexOf(Page.NextCursor) >= 0) then
        raise ELWPTRegistryError.CreateStable('registry_key_rotation_incomplete',
          'rotation pages end before the checkpoint key');
      Cursors.Add(Page.NextCursor);
      Cursor := Page.NextCursor;
    end;
  finally
    Cursors.Free;
  end;
end;

end.
