{ LWPT.Registry.Client -- `lwpt registry publish` (ADR-0049).

  Publication is a client of one origin, named only on the command line:

  1. Local validation, before any credential or connection: the trust pin,
     the origin URL (https, or plain http for the exact host localhost),
     the token variable's name, and the archive (PreparePublicationArchive:
     type detection, the tar.gz scan or zip normalization, and the
     [dependencies] refusal).
  2. The token is read from its environment variable, once.
  3. Discovery and capabilities (role origin, publication-v1, bearer), then
     the latest checkpoint verified from the pin: the "before" head.
  4. PUT the archive by content hash, then PUT the canonical record.
  5. The latest checkpoint is verified again with the before head as prior
     state, so its history must extend it (consistency), and the new
     snapshot must hold the record the origin named in Location with the
     published identity and content (inclusion). Only then is it a success.

  Requests go through HTTPClient with verified TLS, only the origin host,
  and no redirects: any 3xx fails, so the credential never reaches a second
  authority. 429, 503, and transport failures are retried; every request is
  idempotent (content-addressed objects, content-identity records, reads).

  Diagnostics are generated here. A server message or status text is never
  printed; the only response-derived values that can appear are an
  allow-listed error code, a grammar-checked request_id, protocol hashes,
  and the origin identity once the pinned key has authenticated it. Every
  message is also redacted for the credential before it leaves this unit. }
unit LWPT.Registry.Client;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store;

const
  REGISTRY_DEFAULT_TOKEN_ENVIRONMENT = PROJECT_NAME + '_REGISTRY_TOKEN';
  REGISTRY_REDACTED = '[redacted]';
  RegistryPublishMaximumAttempts = 5;
  RegistryPublishMaximumBackoffSeconds = 60;
  RegistryPublishDocumentTimeoutMilliseconds = 60 * 1000;
  RegistryPublishMaximumResponseBytes = 64 * 1024;

type
  TLWPTRegistryPublishOptions = record
    ArchivePath, Origin, KeyID, PublicKey, TokenEnvironment: string;
  end;

  TLWPTRegistryPublishResult = record
    { True for 201 (new version), False for 204 (content already active). }
    Created: Boolean;
    Name, Version, Origin: string;
    Sequence: Int64;
    ArchiveHash, RecordHash: string;
  end;

  { A publish failure whose message is '<code>: <local text>', already
    redacted for the credential. }
  ELWPTRegistryPublishError = class(ELWPTRegistryError);

{ Runs one publication. Raises ELWPTRegistryPublishError only. }
function PublishToRegistry(
  const AOptions: TLWPTRegistryPublishOptions): TLWPTRegistryPublishResult;
function RegistryPublishResultLine(
  const AResult: TLWPTRegistryPublishResult): string;

{ Replaces every occurrence of AToken, and of its secret part when AToken
  is a well-formed token, with [redacted]. }
function RedactRegistryCredential(const AText, AToken: string): string;
{ AValue when it is 1 to 64 characters of [a-z0-9_] starting with a letter
  and is an error code of the protocol or ADR-0049; otherwise
  unrecognized_error. }
function RegistryPublicationErrorCode(const AValue: string): string;
{ True when AValue is 1 to 64 characters of [0-9a-z]. }
function RegistryRequestIDIsValid(const AValue: string): Boolean;
{ Whole seconds from a delta-seconds Retry-After value, or -1 when absent
  or not plain decimal. Values above the backoff cap are capped. }
function ParseRegistryRetryAfter(const AValue: string): Integer;
{ Delay before retry AAttempt + 1: 2^(AAttempt - 1) seconds, capped by a
  valid Retry-After (ARetryAfter >= 0) and by 60 seconds. }
function RegistryPublishBackoffSeconds(const AAttempt,
  ARetryAfter: Integer): Integer;
{ The canonical origin URL; raises insecure_transport for plain http to any
  host but localhost, invalid_configuration for anything else invalid. }
function CanonicalRegistryPublishOrigin(const AOrigin: string): string;
{ The canonical package record the client publishes. }
function RegistryPublishRecordDocument(const AOrigin, AName, AVersion,
  AArchiveHash: string; const AArchiveSize: Int64;
  const APublishedAt: string): string;
{ The record hash named by a Location value that is exactly
  <AAPI>/records/sha256/<hex>.toml, or '' for anything else. }
function RegistryRecordHashFromLocation(const ALocation, AAPI: string): string;
{ True when AName is a portable environment variable name. }
function RegistryTokenEnvironmentNameIsValid(const AName: string): Boolean;

implementation

uses
  Classes,
  Generics.Collections,
  StrUtils,

  HTTPClient,
  LWPT.Archive,
  LWPT.ArchiveNormalize,
  LWPT.Registry.Tokens,
  LWPT.Registry.Verification,
  TOML,
  TransportSecurity;

const
  { ADR-0049 "Wire protocol" and the protocol's stable codes. }
  KNOWN_SERVER_CODES: array[0..14] of string = (
    'authentication_required', 'failed_dependency', 'identity_conflict',
    'invalid_request', 'invalid_request_target', 'method_not_allowed',
    'not_found', 'object_hash_mismatch', 'payload_too_large',
    'permission_denied', 'rate_limited', 'snapshot_conflict',
    'storage_budget_exceeded', 'temporary_failure', 'unsupported_protocol');
  UNRECOGNIZED_ERROR = 'unrecognized_error';
  LOCALHOST_HTTP_PREFIX = 'http://localhost';
  LOOPBACK_ADDRESS = '127.0.0.1';
  CHECKPOINT_PAIR_ATTEMPTS = 3;
  { Token layout: <PROGRAM_NAME>_rt1_<32 hex>_<43 base64url>. }
  TOKEN_SECRET_LENGTH = 43;

type
  TRegistryPublishSession = class;

  TRegistryPublishDocumentSource = class(TLWPTRegistryDocumentSource)
  public
    Session: TRegistryPublishSession;
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; override;
  end;

  TRegistryPublishSession = class
  private
    FOrigin, FHost, FConnectAddress: string;
    FRequireHTTPS: Boolean;
    FTLS: TTransportSecurityClientOptions;
    FToken: string;
    FDiscovery: TLWPTRegistryDiscovery;
    FHasRotations: Boolean;
    FPageSize: Integer;
    FTrust: TLWPTRegistryTrust;
    FDocuments: TDictionary<string, TBytes>;
    function RequestOptions(const ATimeoutMilliseconds: QWord;
      const AMaximumBytes: Int64): THTTPRequestOptions;
    function Send(const AMethod, AURL: string; const ABody: TBytes;
      const AContentType, AAccept, AWhat: string; const AAuthorized: Boolean;
      const ATimeoutMilliseconds: QWord;
      const AMaximumBytes: Int64): THTTPResponse;
    function GetDocument(const AURL, AKind, AWhat: string;
      const AMaximumBytes: Int64): TBytes;
    procedure RequireScope(const AURL: string);
  public
    constructor Create(const AOrigin: string);
    destructor Destroy; override;
    procedure WipeToken;
    procedure Discover;
    function AcquireHead(const APrior: TLWPTRegistryAcceptedState;
      const APriorRotations: TLWPTRegistryRotationProofArray): TLWPTVerifiedRegistry;
    function ReadContentAddressed(const APath: string;
      const AMaximumBytes: Int64): TBytes;
    function Upload(const AArchive: TBytes; const AArchiveHash: string): Integer;
    function PublishRecord(const AName, AVersion: string; const ARecord: TBytes;
      out ARecordHash: string): Integer;
    property Token: string read FToken write FToken;
    property Trust: TLWPTRegistryTrust read FTrust;
    property Discovery: TLWPTRegistryDiscovery read FDiscovery;
  end;

procedure Fail(const ACode, AMessage: string);
begin
  raise ELWPTRegistryPublishError.CreateStable(ACode, AMessage);
end;

function RedactRegistryCredential(const AText, AToken: string): string;
begin
  Result := AText;
  if AToken = '' then Exit;
  Result := StringReplace(Result, AToken, REGISTRY_REDACTED, [rfReplaceAll]);
  if RegistryTokenIsWellFormed(AToken) then
    Result := StringReplace(Result, Copy(AToken,
      Length(AToken) - TOKEN_SECRET_LENGTH + 1, TOKEN_SECRET_LENGTH),
      REGISTRY_REDACTED, [rfReplaceAll]);
end;

function CodeGrammarIsValid(const AValue: string): Boolean;
var
  Index: Integer;
begin
  Result := (Length(AValue) >= 1) and (Length(AValue) <= 64)
    and (AValue[1] in ['a'..'z']);
  if not Result then Exit;
  for Index := 2 to Length(AValue) do
    if not (AValue[Index] in ['a'..'z', '0'..'9', '_']) then Exit(False);
end;

function RegistryPublicationErrorCode(const AValue: string): string;
var
  Known: string;
begin
  Result := UNRECOGNIZED_ERROR;
  if not CodeGrammarIsValid(AValue) then Exit;
  for Known in KNOWN_SERVER_CODES do
    if Known = AValue then Exit(AValue);
end;

function RegistryRequestIDIsValid(const AValue: string): Boolean;
var
  Index: Integer;
begin
  Result := (Length(AValue) >= 1) and (Length(AValue) <= 64);
  if not Result then Exit;
  for Index := 1 to Length(AValue) do
    if not (AValue[Index] in ['0'..'9', 'a'..'z']) then Exit(False);
end;

function ParseRegistryRetryAfter(const AValue: string): Integer;
var
  Index: Integer;
  Value: string;
begin
  Value := Trim(AValue);
  if (Value = '') or (Length(Value) > 9) then Exit(-1);
  for Index := 1 to Length(Value) do
    if not (Value[Index] in ['0'..'9']) then Exit(-1);
  Result := StrToInt(Value);
  if Result > RegistryPublishMaximumBackoffSeconds then
    Result := RegistryPublishMaximumBackoffSeconds;
end;

function RegistryPublishBackoffSeconds(const AAttempt,
  ARetryAfter: Integer): Integer;
var
  Index: Integer;
begin
  Result := 1;
  for Index := 2 to AAttempt do
  begin
    Result := Result * 2;
    if Result >= RegistryPublishMaximumBackoffSeconds then Break;
  end;
  if (ARetryAfter >= 0) and (ARetryAfter < Result) then Result := ARetryAfter;
  if Result > RegistryPublishMaximumBackoffSeconds then
    Result := RegistryPublishMaximumBackoffSeconds;
end;

function CanonicalRegistryPublishOrigin(const AOrigin: string): string;
begin
  if AOrigin = '' then
    Fail('invalid_configuration', 'publish requires --origin');
  try
    Result := CanonicalRegistryURL(AOrigin, False);
  except
    on E: ELWPTRegistryError do
      if RegistryErrorCode(E.Message) = 'insecure_transport' then
        Fail('insecure_transport',
          '--origin must use https; plain http is allowed only for the exact host localhost')
      else
        Fail('invalid_configuration', '--origin is not a valid registry URL');
  end;
end;

function RegistryTokenEnvironmentNameIsValid(const AName: string): Boolean;
var
  Index: Integer;
begin
  Result := (AName <> '') and (Length(AName) <= 128)
    and (AName[1] in ['A'..'Z', 'a'..'z', '_']);
  if not Result then Exit;
  for Index := 2 to Length(AName) do
    if not (AName[Index] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(False);
end;

function RegistryPublishRecordDocument(const AOrigin, AName, AVersion,
  AArchiveHash: string; const AArchiveSize: Int64;
  const APublishedAt: string): string;
begin
  Result := 'schema = ' + RegistryTOMLQuote(PROGRAM_NAME + '-registry-package-v1') + #10
    + 'origin = ' + RegistryTOMLQuote(AOrigin) + #10
    + 'name = ' + RegistryTOMLQuote(AName) + #10
    + 'version = ' + RegistryTOMLQuote(AVersion) + #10
    + 'archive = ' + RegistryTOMLQuote(AArchiveHash) + #10
    + 'archive_size = ' + IntToStr(AArchiveSize) + #10
    + 'published_at = ' + RegistryTOMLQuote(APublishedAt) + #10
    + 'yanked = false' + #10
    { ADR-0049 decision 4: dependency-bearing archives are refused before
      this point, so every record publishes an empty list. }
    + 'dependencies = []' + #10;
end;

function RegistryRecordHashFromLocation(const ALocation, AAPI: string): string;
var
  Prefix, Digest: string;
begin
  Result := '';
  Prefix := AAPI + '/records/sha256/';
  if not StartsStr(Prefix, ALocation) or not EndsStr('.toml', ALocation)
    or (Length(ALocation) <> Length(Prefix) + 64 + Length('.toml')) then Exit;
  Digest := 'sha256:' + Copy(ALocation, Length(Prefix) + 1, 64);
  if RegistryHashIsCanonical(Digest) then Result := Digest;
end;

function MediaType(const AKind: string): string;
begin
  Result := 'application/vnd.' + PROGRAM_NAME + '.registry-' + AKind + '+toml';
end;

function HeaderValues(const AResponse: THTTPResponse;
  const AName: string): TStringArray;
var
  Header: THTTPHeader;
begin
  Result := nil;
  for Header in AResponse.Headers do
    if SameText(Header.Name, AName) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Header.Value;
    end;
end;

function SingleHeader(const AResponse: THTTPResponse; const AName: string;
  out AValue: string): Boolean;
var
  Values: TStringArray;
begin
  Values := HeaderValues(AResponse, AName);
  Result := Length(Values) = 1;
  if Result then AValue := Trim(Values[0]) else AValue := '';
end;

{ The response's content type without parameters, lowercased. }
function ResponseMediaType(const AResponse: THTTPResponse): string;
begin
  if not SingleHeader(AResponse, 'Content-Type', Result) then Exit('');
  if Pos(';', Result) > 0 then Result := Trim(Copy(Result, 1, Pos(';', Result) - 1));
  Result := LowerCase(Result);
end;

{ Raises the failure for a non-success response. Only the status number,
  an allow-listed code, and a grammar-checked request_id are used. }
procedure FailResponse(const AResponse: THTTPResponse; const AWhat: string);
var
  Parser: TTOMLParser;
  Root: TTOMLNode;
  Code, RequestID, Text: string;
begin
  Code := UNRECOGNIZED_ERROR;
  RequestID := '';
  if (ResponseMediaType(AResponse) = MediaType('error'))
    and (Length(AResponse.Body) <= RegistryPublishMaximumResponseBytes) then
  begin
    Parser := TTOMLParser.Create;
    try
      try
        Root := Parser.ParseDocument(RegistryBytesText(AResponse.Body));
        try
          if TomlStr(Root, 'schema', '') = PROGRAM_NAME + '-registry-error-v1' then
          begin
            Code := RegistryPublicationErrorCode(TomlStr(Root, 'code', ''));
            RequestID := TomlStr(Root, 'request_id', '');
          end;
        finally
          Root.Free;
        end;
      except
        on Exception do Code := UNRECOGNIZED_ERROR;
      end;
    finally
      Parser.Free;
    end;
  end;
  Text := 'origin refused ' + AWhat + ' with HTTP ' + IntToStr(AResponse.StatusCode);
  if RegistryRequestIDIsValid(RequestID) then
    Text := Text + ' (request ' + RequestID + ')';
  Fail(Code, Text);
end;

{ --- TRegistryPublishDocumentSource ---------------------------------------- }

function TRegistryPublishDocumentSource.ReadDocument(const APath: string;
  const AMaximumBytes: Int64): TBytes;
begin
  Result := Session.ReadContentAddressed(APath, AMaximumBytes);
end;

{ --- TRegistryPublishSession ----------------------------------------------- }

constructor TRegistryPublishSession.Create(const AOrigin: string);
{$IFDEF INSTALL_TESTING}
var
  AnchorPath: string;
  Stream: TFileStream;
{$ENDIF}
begin
  inherited Create;
  FOrigin := AOrigin;
  FDocuments := TDictionary<string, TBytes>.Create;
  FRequireHTTPS := StartsStr('https://', AOrigin);
  FHost := HTTPURLHost(AOrigin);
  FConnectAddress := '';
  { The plain HTTP exception names exactly localhost; dial the loopback
    address directly, as the listener binds it, instead of trusting
    resolver configuration. The Host header still names localhost. }
  if StartsStr(LOCALHOST_HTTP_PREFIX, AOrigin)
    and ((Length(AOrigin) = Length(LOCALHOST_HTTP_PREFIX))
      or (AOrigin[Length(LOCALHOST_HTTP_PREFIX) + 1] in [':', '/'])) then
    FConnectAddress := LOOPBACK_ADDRESS;
  FTLS := DefaultTransportSecurityClientOptions;
  {$IFDEF INSTALL_TESTING}
  { ADR-0049 decision 7: publish has no CLI trust option. Only a test build
    lets the E2E suite trust the committed test root. }
  AnchorPath := TestSeamValue('REGISTRY_TRUST_ANCHORS');
  if AnchorPath <> '' then
  begin
    Stream := TFileStream.Create(AnchorPath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(FTLS.TrustAnchors, Stream.Size);
      if Stream.Size > 0 then Stream.ReadBuffer(FTLS.TrustAnchors[0], Stream.Size);
    finally
      Stream.Free;
    end;
    FTLS.TrustMode := tstmAnchorsOnly;
  end;
  {$ENDIF}
end;

destructor TRegistryPublishSession.Destroy;
begin
  WipeToken;
  FDocuments.Free;
  inherited Destroy;
end;

procedure TRegistryPublishSession.WipeToken;
begin
  if FToken <> '' then
  begin
    UniqueString(FToken);
    FillChar(FToken[1], Length(FToken), 0);
    FToken := '';
  end;
end;

function TRegistryPublishSession.RequestOptions(
  const ATimeoutMilliseconds: QWord;
  const AMaximumBytes: Int64): THTTPRequestOptions;
begin
  Result := DefaultHTTPRequestOptions;
  Result.MaxResponseBodyBytes := AMaximumBytes;
  Result.RequestTimeoutMilliseconds := ATimeoutMilliseconds;
  Result.MaximumRedirects := 0;
  SetLength(Result.Destination.AllowedHosts, 1);
  Result.Destination.AllowedHosts[0] := FHost;
  Result.Destination.RequireHTTPS := FRequireHTTPS;
  Result.ConnectAddress := FConnectAddress;
  Result.TLS := FTLS;
end;

function TRegistryPublishSession.Send(const AMethod, AURL: string;
  const ABody: TBytes; const AContentType, AAccept, AWhat: string;
  const AAuthorized: Boolean; const ATimeoutMilliseconds: QWord;
  const AMaximumBytes: Int64): THTTPResponse;
var
  Headers: THTTPHeaders;
  Options: THTTPRequestOptions;
  Attempt, RetryAfter: Integer;
  Value, Failure: string;
  Retryable: Boolean;
begin
  if not StartsStr(FOrigin + '/', AURL) then
    Fail('registry_discovery_scope_mismatch',
      'a request would leave the origin named by --origin');
  Options := RequestOptions(ATimeoutMilliseconds, AMaximumBytes);
  SetLength(Headers, 1);
  Headers[0].Name := 'Accept';
  Headers[0].Value := AAccept;
  if AAuthorized then
  begin
    SetLength(Headers, 2);
    Headers[1].Name := 'Authorization';
    Headers[1].Value := 'Bearer ' + FToken;
  end;
  try
    Attempt := 0;
    repeat
      Inc(Attempt);
      Failure := '';
      Retryable := False;
      RetryAfter := -1;
      try
        if AMethod = 'PUT' then
          Result := HTTPPut(AURL, ABody, AContentType, Headers, Options)
        else
          Result := HTTPGet(AURL, Headers, Options);
      except
        on E: EHTTPResponseTooLarge do
          Fail('registry_transport_failed', RedactRegistryCredential(
            'request for ' + AWhat + ' failed: ' + E.Message, FToken));
        on E: EHTTPError do
        begin
          Failure := RedactRegistryCredential(E.Message, FToken);
          { A verification refusal (ADR-0050's stable message) is not a
            transient failure; everything else at the transport is. }
          Retryable := not StartsStr('TLS certificate verification failed', E.Message);
        end;
      end;
      if Failure = '' then
      begin
        if (Result.StatusCode >= 300) and (Result.StatusCode <= 399) then
          Fail('unexpected_redirect', 'origin answered ' + AWhat + ' with HTTP '
            + IntToStr(Result.StatusCode)
            + '; publication never follows a redirect');
        if (Result.StatusCode <> 429) and (Result.StatusCode <> 503) then Exit;
        Retryable := True;
        if SingleHeader(Result, 'Retry-After', Value) then
          RetryAfter := ParseRegistryRetryAfter(Value);
      end;
      if not Retryable or (Attempt >= RegistryPublishMaximumAttempts) then
      begin
        if Failure <> '' then
          Fail('registry_transport_failed', 'request for ' + AWhat
            + ' failed: ' + Failure);
        FailResponse(Result, AWhat);
      end;
      Sleep(RegistryPublishBackoffSeconds(Attempt, RetryAfter) * 1000);
    until False;
  finally
    if Length(Headers) > 1 then
    begin
      UniqueString(Headers[1].Value);
      FillChar(Headers[1].Value[1], Length(Headers[1].Value), 0);
    end;
  end;
end;

function TRegistryPublishSession.GetDocument(const AURL, AKind, AWhat: string;
  const AMaximumBytes: Int64): TBytes;
var
  Response: THTTPResponse;
  Maximum: Int64;
begin
  Maximum := AMaximumBytes;
  if Maximum > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES then
    Maximum := MAX_REGISTRY_CONTROL_DOCUMENT_BYTES;
  Response := Send('GET', AURL, nil, '', MediaType(AKind), AWhat, False,
    RegistryPublishDocumentTimeoutMilliseconds, Maximum);
  if Response.StatusCode <> 200 then FailResponse(Response, AWhat);
  if Length(HeaderValues(Response, 'Content-Encoding')) > 0 then
    Fail('registry_content_encoding_forbidden',
      'origin encoded ' + AWhat + '; hashes require exact protocol bytes');
  if ResponseMediaType(Response) <> MediaType(AKind) then
    Fail('registry_media_type_mismatch',
      'origin answered ' + AWhat + ' with an unexpected media type');
  Result := Response.Body;
end;

procedure TRegistryPublishSession.RequireScope(const AURL: string);
begin
  if not StartsStr(FOrigin + '/', AURL)
    or not RegistryEndpointSuffixIsUnambiguous(Copy(AURL, Length(FOrigin) + 2, MaxInt)) then
    Fail('registry_discovery_scope_mismatch',
      'discovery names an endpoint outside the origin named by --origin');
end;

procedure TRegistryPublishSession.Discover;
var
  Document: TBytes;
  Capabilities: string;
begin
  Document := GetDocument(FOrigin + '/.well-known/' + PROGRAM_NAME + '-registry',
    'discovery', 'discovery', MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
  FDiscovery := ParseRegistryDiscovery(RegistryBytesText(Document));
  if FDiscovery.BaseURL <> FOrigin then
    Fail('registry_discovery_scope_mismatch',
      'discovery names a different base URL than --origin');
  RequireScope(FDiscovery.API);
  RequireScope(FDiscovery.Capabilities);
  RequireScope(FDiscovery.Checkpoint);
  if FDiscovery.Rotations <> '' then RequireScope(FDiscovery.Rotations);
  if FDiscovery.RoleName <> 'origin' then
    Fail('publication_not_supported',
      'the registry at --origin is a mirror; publish to its origin');
  Capabilities := RegistryBytesText(GetDocument(FDiscovery.Capabilities,
    'capabilities', 'capabilities', MAX_REGISTRY_CONTROL_DOCUMENT_BYTES));
  FPageSize := ValidateRegistryCapabilities(Capabilities, FDiscovery.RoleName,
    FHasRotations);
  if FPageSize > RegistryRotationPageLimit then FPageSize := RegistryRotationPageLimit;
  if FHasRotations <> (FDiscovery.Rotations <> '') then
    Fail('registry_rotation_capability_mismatch',
      'discovery and capabilities disagree about key rotation');
  if not RegistryCapabilitiesAcceptBearerPublication(Capabilities) then
    Fail('publication_not_supported',
      'the origin does not accept bearer publication; issue a token on the origin first');
end;

function TRegistryPublishSession.ReadContentAddressed(const APath: string;
  const AMaximumBytes: Int64): TBytes;
var
  Digest, Kind: string;
begin
  if FDocuments.TryGetValue(APath, Result) then
  begin
    if Length(Result) > AMaximumBytes then
      Fail('proof_limit_exceeded', 'a proof document exceeds its budget');
    Exit;
  end;
  if StartsStr('snapshots/sha256/', APath) then
  begin
    Digest := Copy(APath, Length('snapshots/sha256/') + 1, 64);
    Kind := 'snapshot';
  end
  else if StartsStr('records/sha256/', APath) then
  begin
    Digest := Copy(APath, Length('records/sha256/') + 1, 64);
    Kind := 'package';
  end
  else Fail('invalid_resource_path', 'the verifier asked for an unexpected resource');
  if not RegistryHashIsCanonical('sha256:' + Digest)
    or (APath <> Copy(APath, 1, Pos('/sha256/', APath) + 7) + Digest + '.toml') then
    Fail('invalid_resource_path', 'the verifier asked for an invalid resource hash');
  Result := GetDocument(FDiscovery.API + '/' + APath, Kind, 'a ' + Kind
    + ' document', AMaximumBytes);
  if SHA256BytesPrefixed(Result) <> 'sha256:' + Digest then
    Fail('resource_hash_mismatch', 'a ' + Kind + ' document does not match its hash');
  FDocuments.AddOrSetValue(APath, Result);
end;

procedure RememberRetrieval(var AProof: TLWPTRegistryProof; const ABytes: TBytes);
begin
  SetLength(AProof.RetrievalDocuments, Length(AProof.RetrievalDocuments) + 1);
  AProof.RetrievalDocuments[High(AProof.RetrievalDocuments)] := ABytes;
end;

function TRegistryPublishSession.AcquireHead(
  const APrior: TLWPTRegistryAcceptedState;
  const APriorRotations: TLWPTRegistryRotationProofArray): TLWPTVerifiedRegistry;
var
  Proof: TLWPTRegistryProof;
  Budget: TLWPTRegistryMetadataBudget;
  Source: TRegistryPublishDocumentSource;
  Hint: TLWPTUntrustedRegistryCheckpoint;
  Rotation: TLWPTUntrustedRegistryRotation;
  RotationProof: TLWPTRegistryRotationProof;
  KeyTrust: TLWPTRegistryTrust;
  Page: TLWPTRegistryRotationPage;
  PageItem: TLWPTRegistryRotationPageItem;
  Cursors: TStringList;
  Document, NextCheckpoint: TBytes;
  SignatureURL, CurrentKey, CurrentPublicKey, Cursor, PageURL: string;
  PairAttempt, Index: Integer;
  AfterSequence, PreviousSequence, PinnedSequence: Int64;

  function Control(const AURL, AKind: string; const AAuxiliary: Boolean): TBytes;
  begin
    Result := GetDocument(AURL, AKind, 'the ' + AKind + ' document',
      Budget.Allowance);
    Budget.Account(Result);
    if AAuxiliary then RememberRetrieval(Proof, Result);
  end;
begin
  Proof := Default(TLWPTRegistryProof);
  Proof.Rotations := Copy(APriorRotations);
  Budget := TLWPTRegistryMetadataBudget.Create(DefaultRegistryVerificationLimits);
  Source := TRegistryPublishDocumentSource.Create;
  Cursors := TStringList.Create;
  try
    for RotationProof in Proof.Rotations do
    begin
      Budget.Account(RotationProof.Document);
      Budget.Account(RotationProof.OldSignature);
      Budget.Account(RotationProof.NewSignature);
    end;
    SignatureURL := Copy(FDiscovery.Checkpoint, 1,
      Length(FDiscovery.Checkpoint) - Length('.toml')) + '.sig.toml';
    Proof.Checkpoint := Control(FDiscovery.Checkpoint, 'checkpoint', False);
    PairAttempt := 1;
    repeat
      Proof.Signature := Control(SignatureURL, 'signature', False);
      if InspectRegistrySignaturePayload(Proof.Signature)
        = SHA256BytesPrefixed(Proof.Checkpoint) then Break;
      { Only a checkpoint that advanced between the two reads is retried. }
      if PairAttempt >= CHECKPOINT_PAIR_ATTEMPTS then
        Fail('signature_payload_mismatch', 'checkpoint and signature stayed inconsistent');
      Inc(PairAttempt);
      NextCheckpoint := Control(FDiscovery.Checkpoint, 'checkpoint', False);
      if SHA256BytesPrefixed(NextCheckpoint) = SHA256BytesPrefixed(Proof.Checkpoint) then
        Fail('signature_payload_mismatch', 'signature names a different checkpoint');
      Proof.Checkpoint := NextCheckpoint;
    until False;
    Hint := InspectRegistryCheckpoint(Proof.Checkpoint);
    if Hint.Origin <> FTrust.Origin then
      Fail('checkpoint_origin_mismatch',
        'the checkpoint names a different origin than discovery');
    if InspectRegistrySignatureKey(Proof.Signature) <> Hint.KeyId then
      Fail('signature_key_mismatch', 'signature names a different key than its checkpoint');
    Document := Control(FDiscovery.API + '/keys/' + FTrust.KeyId + '.toml', 'key', True);
    PinnedSequence := ValidateRegistryKeyDocument(Document, FTrust, Hint.Sequence);
    CurrentKey := FTrust.KeyId;
    CurrentPublicKey := FTrust.PublicKey;
    AfterSequence := 0;
    if PinnedSequence > 1 then AfterSequence := PinnedSequence;
    if Length(Proof.Rotations) > 0 then
    begin
      Rotation := InspectRegistryRotation(Proof.Rotations[High(Proof.Rotations)].Document);
      CurrentKey := Rotation.ToKey;
      CurrentPublicKey := Rotation.ToPublicKey;
      AfterSequence := Rotation.EffectiveSequence;
    end;
    PreviousSequence := AfterSequence;
    Cursor := '';
    { An older or equal checkpoint is authenticated by the chain already
      held; rotation retrieval only extends it forward. }
    while (CurrentKey <> Hint.KeyId) and (Hint.Sequence > APrior.Sequence) do
    begin
      if not FHasRotations then
        Fail('registry_key_rotation_incomplete',
          'checkpoint key is untrusted and the origin offers no rotation chain');
      PageURL := FDiscovery.Rotations + '?after=' + IntToStr(AfterSequence)
        + '&limit=' + IntToStr(FPageSize);
      if Cursor <> '' then PageURL := PageURL + '&cursor=' + RegistryQueryEncode(Cursor);
      Document := Control(PageURL, 'rotation-page', True);
      Page := ParseRegistryRotationPage(Document, FTrust.Origin, FDiscovery.API,
        PreviousSequence, FPageSize);
      for PageItem in Page.Items do
      begin
        if (PageItem.EffectiveSequence > Hint.Sequence)
          or (Length(Proof.Rotations) >= DefaultRegistryVerificationLimits.Rotations) then
          Fail('rotation_chain_invalid',
            'rotation page exceeds the checkpoint or rotation limit');
        RequireScope(PageItem.Rotation);
        RequireScope(PageItem.OldSignature);
        RequireScope(PageItem.NewSignature);
        RotationProof.Document := Control(PageItem.Rotation, 'key-rotation', False);
        RotationProof.OldSignature := Control(PageItem.OldSignature, 'signature', False);
        RotationProof.NewSignature := Control(PageItem.NewSignature, 'signature', False);
        Rotation := VerifyRegistryRotation(RotationProof, FTrust.Origin, CurrentKey,
          CurrentPublicKey, PreviousSequence, Hint.Sequence);
        if Rotation.EffectiveSequence <> PageItem.EffectiveSequence then
          Fail('rotation_chain_invalid', 'rotation page item names a different sequence');
        KeyTrust.Origin := FTrust.Origin;
        KeyTrust.KeyId := Rotation.ToKey;
        KeyTrust.PublicKey := Rotation.ToPublicKey;
        Document := Control(FDiscovery.API + '/keys/' + Rotation.ToKey + '.toml', 'key', True);
        ValidateRegistryKeyDocument(Document, KeyTrust, Rotation.EffectiveSequence, True);
        Index := Length(Proof.Rotations);
        SetLength(Proof.Rotations, Index + 1);
        Proof.Rotations[Index] := RotationProof;
        CurrentKey := Rotation.ToKey;
        CurrentPublicKey := Rotation.ToPublicKey;
        PreviousSequence := Rotation.EffectiveSequence;
        if CurrentKey = Hint.KeyId then Break;
      end;
      if CurrentKey = Hint.KeyId then Break;
      if (Page.NextCursor = '') or (Cursors.IndexOf(Page.NextCursor) >= 0) then
        Fail('registry_key_rotation_incomplete',
          'rotation pages end before the checkpoint key');
      Cursors.Add(Page.NextCursor);
      Cursor := Page.NextCursor;
    end;
    Source.Session := Self;
    Result := VerifyRegistryProof(Proof, FTrust, APrior, RegistryTimestampNow,
      rvmAcquire, Source, DefaultRegistryVerificationLimits);
  finally
    Cursors.Free;
    Source.Free;
    Budget.Free;
  end;
end;

function UploadTimeoutMilliseconds(const ABytes: Int64): QWord;
begin
  { The origin allows 30 seconds plus one per declared MiB; the client
    waits twice that per attempt. }
  Result := QWord(RegistryPublishDocumentTimeoutMilliseconds)
    + QWord(ABytes div (1024 * 1024)) * 2000;
end;

function TRegistryPublishSession.Upload(const AArchive: TBytes;
  const AArchiveHash: string): Integer;
var
  Response: THTTPResponse;
  Value: string;
begin
  Response := Send('PUT', FDiscovery.API + '/objects/sha256/'
    + RegistryDigestHex(AArchiveHash), AArchive, 'application/gzip',
    MediaType('error'), 'the archive upload', True,
    UploadTimeoutMilliseconds(Length(AArchive)), RegistryPublishMaximumResponseBytes);
  if (Response.StatusCode <> 201) and (Response.StatusCode <> 204) then
    FailResponse(Response, 'the archive upload');
  if (Length(HeaderValues(Response, 'ETag')) > 0)
    and (not SingleHeader(Response, 'ETag', Value)
      or (Value <> '"' + AArchiveHash + '"')) then
    Fail('unexpected_response',
      'origin acknowledged the archive upload with a different object hash');
  Result := Response.StatusCode;
end;

function TRegistryPublishSession.PublishRecord(const AName, AVersion: string;
  const ARecord: TBytes; out ARecordHash: string): Integer;
var
  Response: THTTPResponse;
  Location: string;
begin
  ARecordHash := '';
  Response := Send('PUT', FDiscovery.API + '/packages/' + AName + '/' + AVersion,
    ARecord, MediaType('package'), MediaType('error'), 'the record publication',
    True, RegistryPublishDocumentTimeoutMilliseconds,
    RegistryPublishMaximumResponseBytes);
  Result := Response.StatusCode;
  if Result = 424 then Exit;
  if (Result <> 201) and (Result <> 204) then
    FailResponse(Response, 'the record publication');
  if SingleHeader(Response, 'Location', Location) then
    ARecordHash := RegistryRecordHashFromLocation(Location, FDiscovery.API);
  if ARecordHash = '' then
    Fail('unexpected_response',
      'origin accepted the record without a valid record Location');
end;

function ReadArchiveFile(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  if APath = '' then
    Fail('invalid_configuration', 'publish requires an archive path');
  if not FileExists(APath) then
    Fail('archive_unreadable', 'archive "' + APath + '" does not exist');
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
      Fail('archive_unreadable', 'archive "' + APath + '" cannot be opened');
  end;
  try
    if Stream.Size > ARCHIVE_MAXIMUM_INPUT_BYTES then
      Fail(ARCHIVE_LIMIT_EXCEEDED, 'archive exceeds the '
        + IntToStr(ARCHIVE_MAXIMUM_INPUT_BYTES) + '-byte input limit');
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function IncludedPackage(const AVerified: TLWPTVerifiedRegistry;
  const ARecordHash: string; out APackage: TLWPTRegistryPackage): Boolean;
var
  Package: TLWPTRegistryPackage;
begin
  for Package in AVerified.Packages do
    if Package.RecordHash = ARecordHash then
    begin
      APackage := Package;
      Exit(True);
    end;
  APackage := Default(TLWPTRegistryPackage);
  Result := False;
end;

function RunPublication(const AOptions: TLWPTRegistryPublishOptions;
  out AToken: string): TLWPTRegistryPublishResult;
var
  Origin, TokenEnvironment, RecordHash: string;
  Prepared: TLWPTPublicationArchive;
  Session: TRegistryPublishSession;
  Before, After: TLWPTVerifiedRegistry;
  Status: Integer;
  RecordBytes: TBytes;
  Package: TLWPTRegistryPackage;
  Trust: TLWPTRegistryTrust;
begin
  AToken := '';
  Result := Default(TLWPTRegistryPublishResult);
  { 1. Everything local, before any credential or connection. }
  if (AOptions.KeyID = '') or (AOptions.PublicKey = '') then
    Fail('invalid_configuration',
      'publish requires the trust pin --key-id and --public-key');
  if not RegistryTrustRootIsValid(AOptions.KeyID, AOptions.PublicKey) then
    Fail('invalid_configuration',
      '--key-id and --public-key must be a matching ed25519 key ID and hex: public key');
  TokenEnvironment := AOptions.TokenEnvironment;
  if TokenEnvironment = '' then TokenEnvironment := REGISTRY_DEFAULT_TOKEN_ENVIRONMENT;
  if not RegistryTokenEnvironmentNameIsValid(TokenEnvironment) then
    Fail('invalid_configuration', '--token-env must name an environment variable');
  Origin := CanonicalRegistryPublishOrigin(AOptions.Origin);
  Prepared := PreparePublicationArchive(ReadArchiveFile(AOptions.ArchivePath));
  Result.Name := Prepared.Manifest.Name;
  Result.Version := Prepared.Manifest.Version;
  Result.ArchiveHash := SHA256BytesPrefixed(Prepared.Archive);
  { 2. The credential, read once. }
  AToken := GetEnvironmentVariable(TokenEnvironment);
  if AToken = '' then
    Fail('credential_missing', 'environment variable ' + TokenEnvironment
      + ' does not hold a registry token');
  if not RegistryTokenIsWellFormed(AToken) then
    Fail('credential_invalid', 'environment variable ' + TokenEnvironment
      + ' does not hold a well-formed registry token');
  Session := TRegistryPublishSession.Create(Origin);
  try
    Session.Token := AToken;
    { 3. The before head, from the pin. }
    Session.Discover;
    Trust.Origin := Session.Discovery.Origin;
    Trust.KeyId := AOptions.KeyID;
    Trust.PublicKey := AOptions.PublicKey;
    Session.FTrust := Trust;
    Before := Session.AcquireHead(Default(TLWPTRegistryAcceptedState), nil);
    { 4. Object, then record. A record arriving after an unreferenced upload
      expired gets 424; upload once more and retry. }
    Session.Upload(Prepared.Archive, Result.ArchiveHash);
    RecordBytes := BytesOf(RegistryPublishRecordDocument(Session.Trust.Origin,
      Result.Name, Result.Version, Result.ArchiveHash, Length(Prepared.Archive),
      RegistryTimestampNow));
    Status := Session.PublishRecord(Result.Name, Result.Version, RecordBytes,
      RecordHash);
    if Status = 424 then
    begin
      Session.Upload(Prepared.Archive, Result.ArchiveHash);
      Status := Session.PublishRecord(Result.Name, Result.Version, RecordBytes,
        RecordHash);
      if Status = 424 then
        Fail('failed_dependency',
          'origin still lacks the uploaded archive after a second upload');
    end;
    Session.WipeToken;
    { 5. Consistency from the before head, then inclusion. }
    After := Session.AcquireHead(Before.State, Before.Proof.Rotations);
    if not IncludedPackage(After, RecordHash, Package) then
      Fail('publication_not_included',
        'the verified head does not include the record the origin reported');
    if (Package.Name <> Result.Name) or (Package.Version <> Result.Version)
      or (Package.ArchiveHash <> Result.ArchiveHash)
      or (Package.ArchiveSize <> Length(Prepared.Archive))
      or (Length(Package.Dependencies) <> 0) then
      Fail('publication_not_included',
        'the included record differs from the published identity or content');
    Result.Created := Status = 201;
    Result.Origin := After.State.Origin;
    Result.Sequence := After.State.Sequence;
    Result.RecordHash := RecordHash;
  finally
    Session.Free;
  end;
end;

function PublishToRegistry(
  const AOptions: TLWPTRegistryPublishOptions): TLWPTRegistryPublishResult;
var
  Token, Message: string;
begin
  Token := '';
  Message := '';
  try
    try
      Result := RunPublication(AOptions, Token);
    except
      on E: ELWPTRegistryPublishError do
        Message := E.Message;
      on E: ELWPTRegistryError do
        Message := E.Message;
      on E: ELWPTArchiveError do
        Message := E.Message;
      on E: EHTTPError do
        Message := 'registry_transport_failed: ' + E.Message;
      on E: Exception do
        { Anything else arose while handling a response: its text may hold
          response bytes, so only a local description is kept. }
        Message := 'unexpected_response: the origin sent a document that could not be processed';
    end;
    if Message <> '' then
    begin
      if not CodeGrammarIsValid(RegistryErrorCode(Message)) then
        Message := UNRECOGNIZED_ERROR + ': ' + Message;
      raise ELWPTRegistryPublishError.Create(
        RedactRegistryCredential(Message, Token));
    end;
  finally
    if Token <> '' then
    begin
      UniqueString(Token);
      FillChar(Token[1], Length(Token), 0);
    end;
  end;
end;

function RegistryPublishResultLine(
  const AResult: TLWPTRegistryPublishResult): string;
begin
  if AResult.Created then Result := 'published ' else Result := 'already published ';
  Result := Result + AResult.Name + '@' + AResult.Version + ' to ' + AResult.Origin
    + ' at sequence ' + IntToStr(AResult.Sequence) + ' (archive '
    + AResult.ArchiveHash + ', record ' + AResult.RecordHash + ')';
end;

end.
