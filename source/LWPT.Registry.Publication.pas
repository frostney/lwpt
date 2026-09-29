{ LWPT.Registry.Publication -- authenticated publication requests.

  Routes, authenticates, authorizes, bounds, and audits every non-read
  request on an origin (ADR-0049). Error messages are fixed server text and
  never echo request content. Authentication, length, and concurrency checks
  run after the headers and before any body byte is read. }
unit LWPT.Registry.Publication;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  Generics.Collections,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Audit,
  LWPT.Registry.Incoming,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Tokens;

const
  RegistryTokenRequestsPerMinute = 60;
  RegistryPeerAuthenticationFailuresPerMinute = 20;
  RegistryMaximumBodiesInFlight = 2;

type
  TLWPTRegistryMutationKind = (rmkUpload, rmkRecord, rmkYank, rmkRestore);

  TRegistryRateWindow = record
    StartedAt: QWord;
    Count: Integer;
  end;

  TLWPTRegistryPublisher = class(TLWPTRegistryMutationHandler)
  private
    FStore: TLWPTRegistryStore;
    FIncoming: TLWPTRegistryIncoming;
    FLock: TRTLCriticalSection;
    FBodiesInFlight: LongInt;
    FWindows: TDictionary<string, TRegistryRateWindow>;
    function WindowExceeded(const AKey: string; const ALimit: Integer;
      const ACount: Boolean; out ARetryAfter: Integer): Boolean;
    procedure RecordWindow(const AKey: string);
    function TryTakeBodySlot: Boolean;
    procedure ReleaseBodySlot;
    procedure WriteAudit(var AAudit: TLWPTRegistryAuditRecord;
      const AResponse: TLWPTRegistryHTTPResponse; const ACode: string);
    function Refuse(var AAudit: TLWPTRegistryAuditRecord;
      const AResponse: TLWPTRegistryHTTPResponse;
      const ACode: string): TLWPTRegistryHTTPResponse;
  public
    constructor Create(AStore: TLWPTRegistryStore);
    destructor Destroy; override;
    function BeginMutation(const AHead: TLWPTRegistryRequestHead;
      out AResponse: TLWPTRegistryHTTPResponse): TLWPTRegistryMutation; override;
    property Store: TLWPTRegistryStore read FStore;
  end;

{ True for an origin with at least one active token. }
function RegistryPublicationEnabled(const ARoot, ANow: string): Boolean;

{$IFDEF REGISTRY_TESTING}
{ Replaces the per-token request and per-peer failure bounds; zero restores
  the defaults. }
procedure SetRegistryRateLimitsForTesting(const ATokenRequests,
  APeerFailures: Integer);
{$ENDIF}

implementation

uses
  StrUtils,

  LWPT.Registry.Verification;

type
  TLWPTRegistryPendingMutation = class(TLWPTRegistryMutation)
  private
    FPublisher: TLWPTRegistryPublisher;
    FKind: TLWPTRegistryMutationKind;
    FLength: Int64;
    FExpectContinue, FHoldsSlot, FDone: Boolean;
    FUpload: TLWPTRegistryUpload;
    FDigest: string;
    FRecord: TBytes;
    FReceived: Integer;
    FAudit: TLWPTRegistryAuditRecord;
    procedure Release;
  public
    destructor Destroy; override;
    function BodyLength: Int64; override;
    function ExpectsContinue: Boolean; override;
    procedure Feed(const ABuffer; const ACount: Integer); override;
    function Finish: TLWPTRegistryHTTPResponse; override;
    procedure Abort; override;
  end;

{$IFDEF REGISTRY_TESTING}
var
  TokenRequestsLimitForTesting, PeerFailuresLimitForTesting: Integer;

procedure SetRegistryRateLimitsForTesting(const ATokenRequests,
  APeerFailures: Integer);
begin
  TokenRequestsLimitForTesting := ATokenRequests;
  PeerFailuresLimitForTesting := APeerFailures;
end;
{$ENDIF}

function TokenRequestsLimit: Integer;
begin
  Result := RegistryTokenRequestsPerMinute;
  {$IFDEF REGISTRY_TESTING}
  if TokenRequestsLimitForTesting > 0 then Result := TokenRequestsLimitForTesting;
  {$ENDIF}
end;

function PeerFailuresLimit: Integer;
begin
  Result := RegistryPeerAuthenticationFailuresPerMinute;
  {$IFDEF REGISTRY_TESTING}
  if PeerFailuresLimitForTesting > 0 then Result := PeerFailuresLimitForTesting;
  {$ENDIF}
end;

function RegistryPublicationEnabled(const ARoot, ANow: string): Boolean;
begin
  try
    Result := RegistryHasActiveToken(ARoot, ANow);
  except
    on E: Exception do Result := False;
  end;
end;

function Reason(const AStatus: Integer): string;
begin
  case AStatus of
    201: Result := 'Created';
    204: Result := 'No Content';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    409: Result := 'Conflict';
    413: Result := 'Content Too Large';
    422: Result := 'Unprocessable Content';
    424: Result := 'Failed Dependency';
    429: Result := 'Too Many Requests';
    503: Result := 'Service Unavailable';
    507: Result := 'Insufficient Storage';
  else
    Result := 'Error';
  end;
end;

{ Fixed server text for every publication error code. }
function ErrorMessage(const ACode: string): string;
begin
  if ACode = 'authentication_required' then
    Result := 'publication requires Bearer authentication'
  else if ACode = 'permission_denied' then
    Result := 'the credential does not permit this operation'
  else if ACode = 'failed_dependency' then
    Result := 'referenced archive object is not present'
  else if ACode = 'identity_conflict' then
    Result := 'package identity already has different immutable content'
  else if ACode = 'object_hash_mismatch' then
    Result := 'uploaded object does not match its requested sha256'
  else if ACode = 'payload_too_large' then
    Result := 'declared request length exceeds the limit'
  else if ACode = 'storage_budget_exceeded' then
    Result := 'unreferenced uploads would exceed their budget'
  else if ACode = 'rate_limited' then
    Result := 'request rate exceeded; retry later'
  else if ACode = 'temporary_failure' then
    Result := 'the origin is busy; retry later'
  else if ACode = 'method_not_allowed' then
    Result := 'this registry does not accept that method here'
  else if ACode = 'not_found' then
    Result := 'registry resource was not found'
  else if ACode = 'invalid_request_target' then
    Result := 'request target is not canonical'
  else
    Result := 'the publication request is invalid';
end;

function PublicationError(const AStatus: Integer; const ACode,
  ARequestID: string): TLWPTRegistryHTTPResponse;
begin
  if (AStatus = 429) or (AStatus = 503) then
    Result := RegistryRetryableErrorResponse(AStatus, Reason(AStatus), ACode,
      ErrorMessage(ACode), ARequestID, 1)
  else Result := RegistryErrorResponse(AStatus, Reason(AStatus), ACode,
    ErrorMessage(ACode), ARequestID);
  if AStatus = 401 then Result.Challenge := 'Bearer';
end;

function WriteStandardError(const AText: string): Boolean;
begin
  Result := True;
  try
    WriteLn(ErrOutput, AText);
  except
    Result := False;
  end;
end;

{ TLWPTRegistryPublisher }

constructor TLWPTRegistryPublisher.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create;
  FStore := AStore;
  FIncoming := TLWPTRegistryIncoming.Create(AStore.Root);
  InitCriticalSection(FLock);
  FWindows := TDictionary<string, TRegistryRateWindow>.Create;
end;

destructor TLWPTRegistryPublisher.Destroy;
begin
  FWindows.Free;
  FIncoming.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TLWPTRegistryPublisher.WindowExceeded(const AKey: string;
  const ALimit: Integer; const ACount: Boolean;
  out ARetryAfter: Integer): Boolean;
var
  Window: TRegistryRateWindow;
  Now: QWord;
  Key: string;
  Stale: TStringList;
begin
  Result := False;
  ARetryAfter := 0;
  Now := GetTickCount64;
  EnterCriticalSection(FLock);
  try
    if FWindows.Count > 4096 then
    begin
      Stale := TStringList.Create;
      try
        for Key in FWindows.Keys do
          if Now - FWindows[Key].StartedAt >= 60000 then Stale.Add(Key);
        for Key in Stale do FWindows.Remove(Key);
      finally
        Stale.Free;
      end;
    end;
    if not FWindows.TryGetValue(AKey, Window)
      or (Now - Window.StartedAt >= 60000) then
    begin
      Window.StartedAt := Now;
      Window.Count := 0;
    end;
    if Window.Count >= ALimit then
    begin
      Result := True;
      ARetryAfter := Integer((Window.StartedAt + 60000 - Now + 999) div 1000);
      if ARetryAfter < 1 then ARetryAfter := 1;
    end
    else if ACount then Inc(Window.Count);
    FWindows.AddOrSetValue(AKey, Window);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLWPTRegistryPublisher.RecordWindow(const AKey: string);
var
  RetryAfter: Integer;
begin
  WindowExceeded(AKey, MaxInt, True, RetryAfter);
end;

function TLWPTRegistryPublisher.TryTakeBodySlot: Boolean;
begin
  if InterlockedIncrement(FBodiesInFlight) <= RegistryMaximumBodiesInFlight then
    Exit(True);
  InterlockedDecrement(FBodiesInFlight);
  Result := False;
end;

procedure TLWPTRegistryPublisher.ReleaseBodySlot;
begin
  InterlockedDecrement(FBodiesInFlight);
end;

procedure TLWPTRegistryPublisher.WriteAudit(
  var AAudit: TLWPTRegistryAuditRecord;
  const AResponse: TLWPTRegistryHTTPResponse; const ACode: string);
var
  RetryAfter: Integer;
begin
  AAudit.Status := AResponse.Status;
  AAudit.Code := ACode;
  AAudit.CompletedAt := RegistryTimestampNow;
  { Rate-limited failures aggregate to one record per peer per minute. }
  if (AResponse.Status = 429)
    and WindowExceeded('audit-429:' + AAudit.Peer, 1, True, RetryAfter) then
    Exit;
  try
    WriteRegistryAuditRecord(FStore.Root, AAudit);
  except
    on E: Exception do
      WriteStandardError('registry request ' + AAudit.RequestID
        + ' audit record could not be written');
  end;
end;

function TLWPTRegistryPublisher.Refuse(var AAudit: TLWPTRegistryAuditRecord;
  const AResponse: TLWPTRegistryHTTPResponse;
  const ACode: string): TLWPTRegistryHTTPResponse;
begin
  Result := AResponse;
  if FStore.Config.Role = rrOrigin then WriteAudit(AAudit, AResponse, ACode);
end;

function StrictLength(const AValue: string; out ALength: Int64): Boolean;
var
  Character: Char;
begin
  Result := (AValue <> '') and (Length(AValue) <= 18);
  if not Result then Exit;
  for Character in AValue do
    if not (Character in ['0'..'9']) then Exit(False);
  Result := TryStrToInt64(AValue, ALength) and (IntToStr(ALength) = AValue);
end;

function BasePath(const ABaseURL: string): string;
var
  AuthorityEnd, SchemeEnd: Integer;
begin
  SchemeEnd := Pos('://', ABaseURL);
  AuthorityEnd := PosEx('/', ABaseURL, SchemeEnd + 3);
  if AuthorityEnd = 0 then Exit('');
  Result := Copy(ABaseURL, AuthorityEnd, MaxInt);
end;

function IsLowerHex64(const AValue: string): Boolean;
var
  Character: Char;
begin
  Result := Length(AValue) = 64;
  if not Result then Exit;
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function TLWPTRegistryPublisher.BeginMutation(
  const AHead: TLWPTRegistryRequestHead;
  out AResponse: TLWPTRegistryHTTPResponse): TLWPTRegistryMutation;
var
  Audit: TLWPTRegistryAuditRecord;
  APIPath, Prefix, Rest, Now, Digest: string;
  Kind: TLWPTRegistryMutationKind;
  Values: TStringArray;
  Declared: Int64;
  RouteKnown, MethodAllowed: Boolean;
  Token: TLWPTRegistryToken;
  Failure: TLWPTRegistryAuthFailure;
  RetryAfter: Integer;
  Pending: TLWPTRegistryPendingMutation;
  Upload: TLWPTRegistryUpload;
begin
  Result := nil;
  Audit := Default(TLWPTRegistryAuditRecord);
  Audit.RequestID := NewRegistryRequestID;
  Audit.ReceivedAt := RegistryTimestampNow;
  Audit.Peer := AHead.Peer;
  Audit.Method := RegistryAuditMethod(AHead.Method);
  Audit.Route := REGISTRY_AUDIT_INVALID_ROUTE;
  Kind := rmkUpload;
  RouteKnown := False;
  MethodAllowed := False;
  { Only a target that passes routing and every parameter grammar is
    recorded; anything else stays "invalid", so a misplaced credential in a
    path or query is never written. }
  Prefix := BasePath(FStore.Config.BaseURL);
  if (Pos('?', AHead.Target) = 0) and (Pos('#', AHead.Target) = 0)
    and (Pos('%', AHead.Target) = 0) and (Pos('..', AHead.Target) = 0)
    and StartsStr(Prefix + '/v1/', AHead.Target) then
  begin
    APIPath := Copy(AHead.Target, Length(Prefix) + 1, MaxInt);
    if StartsStr('/v1/objects/sha256/', APIPath) then
    begin
      Digest := Copy(APIPath, Length('/v1/objects/sha256/') + 1, MaxInt);
      if IsLowerHex64(Digest) then
      begin
        RouteKnown := True;
        Audit.Route := '/v1/objects/sha256/{hex}';
        Audit.ArchiveHash := 'sha256:' + Digest;
        Kind := rmkUpload;
        MethodAllowed := AHead.Method = 'PUT';
      end;
    end
    else if StartsStr('/v1/packages/', APIPath) then
    begin
      Rest := Copy(APIPath, Length('/v1/packages/') + 1, MaxInt);
      Audit.Name := Copy(Rest, 1, Pos('/', Rest) - 1);
      Rest := Copy(Rest, Pos('/', Rest) + 1, MaxInt);
      if EndsStr('/yank', Rest) then
      begin
        Audit.Version := Copy(Rest, 1, Length(Rest) - Length('/yank'));
        Audit.Route := '/v1/packages/{name}/{version}/yank';
        if AHead.Method = 'DELETE' then Kind := rmkRestore else Kind := rmkYank;
        MethodAllowed := (AHead.Method = 'PUT') or (AHead.Method = 'DELETE');
      end
      else
      begin
        Audit.Version := Rest;
        Audit.Route := '/v1/packages/{name}/{version}';
        Kind := rmkRecord;
        MethodAllowed := AHead.Method = 'PUT';
      end;
      RouteKnown := RegistryPackageNameIsCanonical(Audit.Name)
        and RegistryVersionIsCanonical(Audit.Version);
      if not RouteKnown then
      begin
        Audit.Route := REGISTRY_AUDIT_INVALID_ROUTE;
        Audit.Name := '';
        Audit.Version := '';
      end;
    end;
  end;
  if FStore.Config.Role = rrMirror then
  begin
    AResponse := Refuse(Audit, PublicationError(405, 'method_not_allowed',
      Audit.RequestID), 'method_not_allowed');
    Exit;
  end;
  if not RouteKnown then
  begin
    if Pos('?', AHead.Target) > 0 then
      AResponse := Refuse(Audit, PublicationError(400,
        'invalid_request_target', Audit.RequestID), 'invalid_request_target')
    else AResponse := Refuse(Audit, PublicationError(404, 'not_found',
      Audit.RequestID), 'not_found');
    Exit;
  end;
  case Kind of
    rmkUpload: Audit.Action := 'upload';
    rmkRecord: Audit.Action := 'publish';
    rmkYank: Audit.Action := 'yank';
    rmkRestore: Audit.Action := 'restore';
  end;
  Now := RegistryTimestampNow;
  if not MethodAllowed or not RegistryPublicationEnabled(FStore.Root, Now) then
  begin
    AResponse := Refuse(Audit, PublicationError(405, 'method_not_allowed',
      Audit.RequestID), 'method_not_allowed');
    Exit;
  end;
  { Framing: an exact length, and no transfer or content coding. }
  if (Length(RegistryHeaderValues(AHead, 'Transfer-Encoding')) > 0)
    or (Length(RegistryHeaderValues(AHead, 'Content-Encoding')) > 0) then
  begin
    AResponse := Refuse(Audit, PublicationError(400, 'invalid_request',
      Audit.RequestID), 'invalid_request');
    Exit;
  end;
  Values := RegistryHeaderValues(AHead, 'Content-Length');
  Declared := 0;
  if (Length(Values) > 1)
    or ((Length(Values) = 1) and not StrictLength(Values[0], Declared))
    or ((Length(Values) = 0) and (Kind in [rmkUpload, rmkRecord]))
    or ((Kind in [rmkYank, rmkRestore]) and (Declared <> 0)) then
  begin
    AResponse := Refuse(Audit, PublicationError(400, 'invalid_request',
      Audit.RequestID), 'invalid_request');
    Exit;
  end;
  if WindowExceeded('peer:' + AHead.Peer, PeerFailuresLimit, False,
    RetryAfter) then
  begin
    AResponse := PublicationError(429, 'rate_limited', Audit.RequestID);
    AResponse.RetryAfter := RetryAfter;
    AResponse := Refuse(Audit, AResponse, 'rate_limited');
    Exit;
  end;
  Values := RegistryHeaderValues(AHead, 'Authorization');
  if Length(Values) > 1 then
  begin
    Failure := rafMalformed;
    Token := Default(TLWPTRegistryToken);
  end
  else if Length(Values) = 0 then
  begin
    Failure := rafMissing;
    Token := Default(TLWPTRegistryToken);
  end
  else if AuthenticateRegistryBearer(FStore.Root, Values[0], Now, Token,
    Failure) then Failure := rafNone;
  if Failure <> rafNone then
  begin
    RecordWindow('peer:' + AHead.Peer);
    Audit.AuthFailure := RegistryAuthFailureText(Failure);
    AResponse := Refuse(Audit, PublicationError(401, 'authentication_required',
      Audit.RequestID), 'authentication_required');
    Exit;
  end;
  Audit.TokenID := Token.ID;
  if WindowExceeded('token:' + Token.ID, TokenRequestsLimit, True,
    RetryAfter) then
  begin
    AResponse := PublicationError(429, 'rate_limited', Audit.RequestID);
    AResponse.RetryAfter := RetryAfter;
    AResponse := Refuse(Audit, AResponse, 'rate_limited');
    Exit;
  end;
  case Kind of
    rmkUpload: MethodAllowed := RegistryTokenPermits(Token, rtaPublish, '');
    rmkRecord: MethodAllowed := RegistryTokenPermits(Token, rtaPublish,
      Audit.Name);
  else
    MethodAllowed := RegistryTokenPermits(Token, rtaYank, Audit.Name);
  end;
  if not MethodAllowed then
  begin
    AResponse := Refuse(Audit, PublicationError(403, 'permission_denied',
      Audit.RequestID), 'permission_denied');
    Exit;
  end;
  if ((Kind = rmkUpload) and (Declared > RegistryMaximumArchiveBytes))
    or ((Kind = rmkRecord) and (Declared > RegistryMaximumRecordBytes)) then
  begin
    AResponse := Refuse(Audit, PublicationError(413, 'payload_too_large',
      Audit.RequestID), 'payload_too_large');
    Exit;
  end;
  Pending := TLWPTRegistryPendingMutation.Create;
  Pending.FPublisher := Self;
  Pending.FKind := Kind;
  Pending.FLength := Declared;
  Pending.FAudit := Audit;
  Values := RegistryHeaderValues(AHead, 'Expect');
  Pending.FExpectContinue := (Length(Values) = 1)
    and SameText(Values[0], '100-continue');
  try
    if Kind in [rmkUpload, rmkRecord] then
    begin
      if not TryTakeBodySlot then
      begin
        AResponse := Refuse(Pending.FAudit, PublicationError(503,
          'temporary_failure', Audit.RequestID), 'temporary_failure');
        Pending.FDone := True;
        FreeAndNil(Pending);
        Exit;
      end;
      Pending.FHoldsSlot := True;
    end;
    if Kind = rmkUpload then
    begin
      Pending.FDigest := Copy(Audit.ArchiveHash, Length('sha256:') + 1, MaxInt);
      try
        Upload := FIncoming.Admit(Declared);
      except
        on E: ELWPTRegistryIncomingFull do
        begin
          AResponse := Refuse(Pending.FAudit, PublicationError(507,
            'storage_budget_exceeded', Audit.RequestID),
            'storage_budget_exceeded');
          Pending.FDone := True;
          FreeAndNil(Pending);
          Exit;
        end;
        on E: ELWPTRegistryBusy do
        begin
          AResponse := Refuse(Pending.FAudit, PublicationError(503,
            'temporary_failure', Audit.RequestID), 'temporary_failure');
          Pending.FDone := True;
          FreeAndNil(Pending);
          Exit;
        end;
      end;
      Pending.FUpload := Upload;
    end
    else if Kind = rmkRecord then
      SetLength(Pending.FRecord, Declared);
  except
    Pending.FDone := True;
    Pending.Free;
    raise;
  end;
  AResponse := Default(TLWPTRegistryHTTPResponse);
  Result := Pending;
end;

{ TLWPTRegistryPendingMutation }

procedure TLWPTRegistryPendingMutation.Release;
begin
  if FHoldsSlot then
  begin
    FHoldsSlot := False;
    FPublisher.ReleaseBodySlot;
  end;
end;

destructor TLWPTRegistryPendingMutation.Destroy;
begin
  if not FDone then Abort;
  Release;
  FUpload.Free;
  inherited Destroy;
end;

function TLWPTRegistryPendingMutation.BodyLength: Int64;
begin
  Result := FLength;
end;

function TLWPTRegistryPendingMutation.ExpectsContinue: Boolean;
begin
  Result := FExpectContinue;
end;

procedure TLWPTRegistryPendingMutation.Feed(const ABuffer;
  const ACount: Integer);
begin
  if ACount <= 0 then Exit;
  case FKind of
    rmkUpload: FUpload.Write(ABuffer, ACount);
    rmkRecord:
      begin
        if ACount > Length(FRecord) - FReceived then
          raise ELWPTRegistryError.CreateStable('invalid_request',
            'request body exceeds its declared length');
        Move(ABuffer, FRecord[FReceived], ACount);
        Inc(FReceived, ACount);
      end;
  else
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'this request carries no body');
  end;
end;

procedure TLWPTRegistryPendingMutation.Abort;
var
  Response: TLWPTRegistryHTTPResponse;
begin
  if FDone then Exit;
  FDone := True;
  try
    if Assigned(FUpload) then FUpload.Abandon;
  except
  end;
  FreeAndNil(FUpload);
  Release;
  Response := Default(TLWPTRegistryHTTPResponse);
  Response.Status := 0;
  try
    FPublisher.WriteAudit(FAudit, Response, 'request_aborted');
  except
  end;
end;

function TLWPTRegistryPendingMutation.Finish: TLWPTRegistryHTTPResponse;
var
  Code, RequestID: string;
  Commit: TLWPTRegistryCommitResult;
  Outcome: TLWPTRegistryUploadOutcome;
  Status: Integer;

  function CodeStatus(const ACode: string): Integer;
  begin
    if ACode = 'invalid_request' then Result := 400
    else if ACode = 'not_found' then Result := 404
    else if ACode = 'method_not_allowed' then Result := 405
    else if ACode = 'identity_conflict' then Result := 409
    else if ACode = 'payload_too_large' then Result := 413
    else if ACode = 'failed_dependency' then Result := 424
    else Result := 503;
  end;

begin
  RequestID := FAudit.RequestID;
  if FDone then
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'mutation already finished');
  FDone := True;
  Code := '';
  try
    try
      case FKind of
        rmkUpload:
          begin
            Outcome := FUpload.Complete(FDigest);
            case Outcome of
              ruoCreated, ruoExisting:
                begin
                  Result := Default(TLWPTRegistryHTTPResponse);
                  if Outcome = ruoCreated then Status := 201 else Status := 204;
                  Result.Status := Status;
                  Result.Reason := Reason(Status);
                  Result.CacheControl := 'no-store';
                  Result.ETag := '"sha256:' + FDigest + '"';
                end;
            else
              Code := 'object_hash_mismatch';
              Result := PublicationError(422, Code, RequestID);
            end;
          end;
        rmkRecord:
          begin
            if FReceived <> Length(FRecord) then
            begin
              Code := 'invalid_request';
              Result := PublicationError(400, Code, RequestID);
            end
            else
            begin
              Release;
              Commit := FPublisher.Store.PublishRecord(FRecord, FAudit.Name,
                FAudit.Version);
              Result := Default(TLWPTRegistryHTTPResponse);
              if Commit.Outcome = rcoCreated then Status := 201
              else Status := 204;
              Result.Status := Status;
              Result.Reason := Reason(Status);
              Result.CacheControl := 'no-store';
              Result.Location := FPublisher.Store.Config.BaseURL
                + '/v1/records/sha256/' + Copy(Commit.RecordHash, 8, 64)
                + '.toml';
              FAudit.ArchiveHash := Commit.ArchiveHash;
              FAudit.RecordHash := Commit.RecordHash;
              FAudit.Sequence := Commit.Sequence;
              FAudit.CheckpointHash := Commit.CheckpointHash;
            end;
          end;
        rmkYank, rmkRestore:
          begin
            Commit := FPublisher.Store.SetYanked(FAudit.Name, FAudit.Version,
              FKind = rmkYank);
            Result := Default(TLWPTRegistryHTTPResponse);
            if Commit.Outcome = rcoCreated then
            begin
              Status := 201;
              Result.ContentType := 'application/vnd.' + PROGRAM_NAME
                + '.registry-package+toml';
              Result.Body := Commit.RecordBytes;
              Result.ETag := '"' + Commit.RecordHash + '"';
            end
            else Status := 204;
            Result.Status := Status;
            Result.Reason := Reason(Status);
            Result.CacheControl := 'no-store';
            Result.Location := FPublisher.Store.Config.BaseURL
              + '/v1/records/sha256/' + Copy(Commit.RecordHash, 8, 64)
              + '.toml';
            FAudit.ArchiveHash := Commit.ArchiveHash;
            FAudit.RecordHash := Commit.RecordHash;
            FAudit.Sequence := Commit.Sequence;
            FAudit.CheckpointHash := Commit.CheckpointHash;
          end;
      end;
    except
      on E: ELWPTRegistryBusy do
      begin
        Code := 'temporary_failure';
        Result := PublicationError(503, Code, RequestID);
      end;
      on E: Exception do
      begin
        Code := RegistryErrorCode(E.Message);
        Status := CodeStatus(Code);
        { Unexpected failures leave either the old or the new head; the
          client's retry resolves which. }
        if Status = 503 then Code := 'temporary_failure';
        Result := PublicationError(Status, Code, RequestID);
      end;
    end;
  finally
    FreeAndNil(FUpload);
    Release;
  end;
  FPublisher.WriteAudit(FAudit, Result, Code);
end;

end.
