program RegistryPublishHostile.E2E.Test;

{ `registry publish` against hostile or broken origins (ADR-0049). A proxy
  on the advertised base URL relays to a real `registry serve` and rewrites
  selected responses: redirects are refused without contacting their
  target, discovery cannot move requests to another authority, responses
  that reflect the credential in any field never make it print, 429 and
  503 are retried a bounded number of times, and a publication the origin
  acknowledged still fails unless the verified head extends the first head
  (consistency) and includes the record (inclusion). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  DateUtils,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryHTTP,
  Tests.RegistryOrigin,
  Tests.RegistryProcess,
  Tests.RegistryPublish,
  Tests.RegistryServer,
  Tests.Scratch;

const
  CRLF = #13#10;

type
  TProxyMode = (pmForward, pmRedirectDiscovery, pmRedirectUpload, pmForeignAPI,
    pmEchoError, pmEchoKnownError, pmEchoLocation, pmEchoETag,
    pmEchoRetryAfter, pmEchoTransport, pmEchoOrigin, pmEchoSchema, pmRetry, pmAlways503,
    pmCheckpointAfter, pmFakeCreated, pmTamperSignature, pmTamperSnapshot,
    pmSwitchBackend);

  { Relays every request to a backend listener and rewrites responses as
    the mode directs. "After" means after the record PUT was answered. }
  TPublishProxy = class
  private
    FLock: TRTLCriticalSection;
    FListener: TRegistryTestServer;
    FCounts: TStringList;
    FRecordAnswered, FPutSeen: Boolean;
    FFailures: Integer;
    function Handle(const ARequest: TBytes): TBytes;
    procedure Increment(const AKey: string);
    function Forward(const APort: Word; const AMethod, ATarget: string;
      const AHeaders: TStringList; const ABody: TBytes): TRawHTTPResponse;
  public
    Backend, SecondBackend, Other: Word;
    Mode: TProxyMode;
    Token, Base: string;
    CheckpointSequence: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    { Switches the mode and restarts the counts and the after-record stage. }
    procedure SetMode(const AMode: TProxyMode);
    function Count(const AKey: string): Integer;
    function Port: Word;
  end;

  TRegistryPublishHostileE2E = class(TTestSuite)
  private
    FScratch, FProject, FOutputs, FToken: string;
    FProxy: TPublishProxy;
    FOther: TRegistryTestServer;
    FOrigin, FSecond: TPublishOrigin;
    procedure ReleaseScratch;
    procedure StartProxiedOrigin(const AMode: TProxyMode);
    function PublishThroughProxy(const AName, AContent: string): TLwptResult;
    procedure DirectPublish(AOrigin: TPublishOrigin; const AName, AContent: string);
    procedure ExpectRefused(const ARun: TLwptResult; const APrefix: string);
    procedure ExpectNoCredentialPrinted;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestRedirectsAreRefusedWithoutContactingTheTarget;
    procedure TestDiscoveryCannotNameAnotherAuthority;
    procedure TestReflectedCredentialsAreNeverPrinted;
    procedure TestRetryableAnswersAreRetriedBoundedly;
    procedure TestWithheldOrFakedPublicationFails;
    procedure TestDowngradedCheckpointFails;
    procedure TestTamperedSignatureOrSnapshotFails;
    procedure TestInconsistentHistoryFails;
  end;

function BytesText(const ABytes: TBytes): string;
begin
  SetString(Result, PAnsiChar(PByte(ABytes)), Length(ABytes));
end;

{ Replaces or appends one header line of a response head. }
function WithHeader(const AHead, AName, AValue: string): string;
var
  Lines: TStringArray;
  Index: Integer;
  Found: Boolean;
begin
  Lines := AHead.Split([CRLF]);
  Found := False;
  for Index := 1 to High(Lines) do
    if SameText(Copy(Lines[Index], 1, Length(AName) + 1), AName + ':') then
    begin
      Lines[Index] := AName + ': ' + AValue;
      Found := True;
    end;
  Result := string.Join(CRLF, Lines);
  if not Found then Result := Result + CRLF + AName + ': ' + AValue;
end;

function Assemble(const AHead: string; const ABody: TBytes): TBytes;
begin
  Result := RawHTTPBytes(WithHeader(AHead, 'Content-Length', IntToStr(Length(ABody)))
    + CRLF + CRLF);
  SetLength(Result, Length(Result) + Length(ABody));
  if Length(ABody) > 0 then
    Move(ABody[0], Result[Length(Result) - Length(ABody)], Length(ABody));
end;

function ErrorResponse(const AStatus: Integer; const AReason, ACode, AMessage,
  ARequestID: string; const AExtraHeaders: string = ''): TBytes;
begin
  Result := Assemble('HTTP/1.1 ' + IntToStr(AStatus) + ' ' + AReason + CRLF
    + 'Content-Type: application/vnd.' + RegistryProgramName
    + '.registry-error+toml' + CRLF + 'Connection: close' + AExtraHeaders,
    RawHTTPBytes('schema = "' + RegistryProgramName + '-registry-error-v1"' + #10
      + 'code = "' + ACode + '"' + #10 + 'message = "' + AMessage + '"' + #10
      + 'request_id = "' + ARequestID + '"' + #10 + 'retryable = false' + #10));
end;

{ --- TPublishProxy --------------------------------------------------------- }

constructor TPublishProxy.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FCounts := TStringList.Create;
  FListener := TRegistryTestServer.Create(nil);
  FListener.RawHandler := Handle;
end;

destructor TPublishProxy.Destroy;
begin
  FListener.Free;
  FCounts.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPublishProxy.Start;
begin
  FListener.Start;
end;

procedure TPublishProxy.SetMode(const AMode: TProxyMode);
begin
  EnterCriticalSection(FLock);
  try
    Mode := AMode;
    FCounts.Clear;
    FRecordAnswered := False;
    FPutSeen := False;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPublishProxy.Port: Word;
begin
  Result := FListener.Port;
end;

procedure TPublishProxy.Increment(const AKey: string);
begin
  EnterCriticalSection(FLock);
  try
    FCounts.Values[AKey] := IntToStr(StrToIntDef(FCounts.Values[AKey], 0) + 1);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPublishProxy.Count(const AKey: string): Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := StrToIntDef(FCounts.Values[AKey], 0);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPublishProxy.Forward(const APort: Word; const AMethod, ATarget: string;
  const AHeaders: TStringList; const ABody: TBytes): TRawHTTPResponse;
var
  Headers: array of string;
  Index: Integer;
begin
  Headers := nil;
  for Index := 0 to AHeaders.Count - 1 do
    if SameText(AHeaders.Names[Index], 'Authorization')
      or SameText(AHeaders.Names[Index], 'Content-Type')
      or SameText(AHeaders.Names[Index], 'Accept') then
    begin
      SetLength(Headers, Length(Headers) + 1);
      Headers[High(Headers)] := AHeaders.Names[Index] + ': '
        + Trim(AHeaders.ValueFromIndex[Index]);
    end;
  Result := RawHTTPRequest(APort, AMethod, ATarget, Headers, ABody,
    AMethod <> 'GET', 30000);
end;

function TPublishProxy.Handle(const ARequest: TBytes): TBytes;
var
  Text, Head, Method, Target, Kind, Body: string;
  Lines: TStringArray;
  Headers: TStringList;
  Content: TBytes;
  Index, HeaderEnd: Integer;
  Response: TRawHTTPResponse;
  Destination: Word;
  IsDiscovery, IsObject, IsRecord, IsLatest, After: Boolean;
begin
  Text := BytesText(ARequest);
  HeaderEnd := Pos(CRLF + CRLF, Text);
  Head := Copy(Text, 1, HeaderEnd - 1);
  Content := RawHTTPBytes(Copy(Text, HeaderEnd + 4, MaxInt));
  Lines := Head.Split([CRLF]);
  Method := Copy(Lines[0], 1, Pos(' ', Lines[0]) - 1);
  Target := Copy(Lines[0], Length(Method) + 2, MaxInt);
  Target := Copy(Target, 1, Pos(' ', Target) - 1);
  Headers := TStringList.Create;
  try
    Headers.NameValueSeparator := ':';
    for Index := 1 to High(Lines) do Headers.Add(Lines[Index]);
    IsDiscovery := Pos('/.well-known/', Target) = 1;
    IsObject := (Method = 'PUT') and (Pos('/v1/objects/', Target) = 1);
    IsRecord := (Method = 'PUT') and (Pos('/v1/packages/', Target) = 1);
    IsLatest := Pos('/v1/checkpoints/latest.', Target) = 1;
    if IsObject then Kind := 'object'
    else if IsRecord then Kind := 'record'
    else Kind := Method;
    Increment(Kind);
    EnterCriticalSection(FLock);
    try
      After := FRecordAnswered;
      if Method = 'PUT' then FPutSeen := True;
      Destination := Backend;
      if (Mode = pmSwitchBackend) and FPutSeen then Destination := SecondBackend;
    finally
      LeaveCriticalSection(FLock);
    end;

    case Mode of
      pmRedirectDiscovery:
        if IsDiscovery then
          Exit(Assemble('HTTP/1.1 302 Found' + CRLF + 'Location: http://127.0.0.1:'
            + IntToStr(Other) + Target + CRLF + 'Connection: close', nil));
      pmRedirectUpload:
        if IsObject then
          Exit(Assemble('HTTP/1.1 307 Temporary Redirect' + CRLF
            + 'Location: http://127.0.0.1:' + IntToStr(Other) + '/steal' + CRLF
            + 'Connection: close', nil));
      pmEchoTransport:
        if IsDiscovery then
          Exit(RawHTTPBytes('HTTP/1.1 200 OK' + CRLF + 'Content-Length: ' + Token
            + CRLF + 'Connection: close' + CRLF + CRLF));
      pmEchoError:
        if IsObject then
          Exit(ErrorResponse(403, Token, Token, Token, Token,
            CRLF + 'Location: ' + Token + CRLF + 'ETag: "' + Token + '"' + CRLF
            + 'Retry-After: ' + Token + CRLF + 'WWW-Authenticate: Bearer realm="'
            + Token + '"'));
      pmEchoKnownError:
        if IsObject then
          Exit(ErrorResponse(409, Token, 'identity_conflict', Token, 'r0123abc',
            CRLF + 'Location: ' + Base + '/v1/records/sha256/' + Token));
      pmEchoRetryAfter:
        if IsObject and (Count('object') = 1) then
          Exit(ErrorResponse(503, Token, 'temporary_failure', Token, Token,
            CRLF + 'Retry-After: ' + Token));
      pmRetry:
        if (IsObject and (Count('object') <= 2)) then
          Exit(ErrorResponse(503, 'Busy', 'temporary_failure', 'busy', 'r1',
            CRLF + 'Retry-After: 0'))
        else if IsRecord and (Count('record') = 1) then
          Exit(ErrorResponse(429, 'Slow Down', 'rate_limited', 'slow', 'r2',
            CRLF + 'Retry-After: 0'));
      pmAlways503:
        if IsObject then
          Exit(ErrorResponse(503, 'Busy', 'temporary_failure', 'busy', 'r3',
            CRLF + 'Retry-After: 0'));
      pmFakeCreated:
        if IsRecord then
        begin
          EnterCriticalSection(FLock);
          FRecordAnswered := True;
          LeaveCriticalSection(FLock);
          Exit(Assemble('HTTP/1.1 201 Created' + CRLF + 'Location: ' + Base
            + '/v1/records/sha256/' + Copy(RegistryArtifactHash(Content), 8, 64)
            + '.toml' + CRLF + 'Connection: close', nil));
        end;
      pmCheckpointAfter:
        if After and IsLatest then
          Target := StringReplace(Target, 'latest', IntToStr(CheckpointSequence), []);
    end;

    Response := Forward(Destination, Method, Target, Headers, Content);
    if IsRecord then
    begin
      EnterCriticalSection(FLock);
      FRecordAnswered := True;
      LeaveCriticalSection(FLock);
    end;
    Body := BytesText(Response.Body);
    case Mode of
      pmForeignAPI:
        if IsDiscovery then
          Body := StringReplace(Body, 'api = "' + Base + '/v1"',
            'api = "http://localhost:' + IntToStr(Other) + '/v1"', []);
      pmEchoOrigin:
        if IsDiscovery then
          Body := StringReplace(Body, 'origin = "' + Base + '"',
            'origin = "' + Base + '/' + Token + '"', []);
      pmEchoSchema:
        if IsDiscovery then
          Body := StringReplace(Body, 'schema = "' + RegistryProgramName
            + '-registry-discovery-v1"', 'schema = "' + Token + '"', []);
      pmEchoLocation:
        if IsRecord then
          Response.Head := WithHeader(Response.Head, 'Location',
            Base + '/v1/records/sha256/' + Token + '.toml');
      pmEchoETag:
        if IsObject then
          Response.Head := WithHeader(Response.Head, 'ETag', '"' + Token + '"');
      pmTamperSignature:
        if After and (Target = '/v1/checkpoints/latest.sig.toml') then
        begin
          Index := Pos('signature = "hex:', Body) + Length('signature = "hex:');
          if Body[Index] = '0' then Body[Index] := '1' else Body[Index] := '0';
        end;
      pmTamperSnapshot:
        if After and (Pos('/v1/snapshots/', Target) = 1) then
          Body := StringReplace(Body, 'published_at = "', 'published_at = " ', []);
    end;
    Result := Assemble(Response.Head, RawHTTPBytes(Body));
  finally
    Headers.Free;
  end;
end;

{ --- the suite ------------------------------------------------------------- }

procedure TRegistryPublishHostileE2E.BeforeEach;
begin
  FreeAndNil(FOrigin);
  FreeAndNil(FSecond);
  FreeAndNil(FProxy);
  FreeAndNil(FOther);
  ReleaseScratch;
  FScratch := CreateScratchRoot('registry-publish-hostile');
  FProject := FScratch + '/project';
  ForceDirectories(FProject);
  FOutputs := '';
  FToken := '';
end;

procedure TRegistryPublishHostileE2E.AfterEach;
begin
  FreeAndNil(FOrigin);
  FreeAndNil(FSecond);
  FreeAndNil(FProxy);
  FreeAndNil(FOther);
end;

procedure TRegistryPublishHostileE2E.AfterAll;
begin
  AfterEach;
  ReleaseScratch;
end;

procedure TRegistryPublishHostileE2E.ReleaseScratch;
var
  Started: QWord;
  Failure: string;
begin
  if FScratch = '' then Exit;
  Started := GetTickCount64;
  repeat
    try
      RecursiveDelete(FScratch);
      FScratch := '';
      Exit;
    except
      on E: Exception do Failure := E.Message;
    end;
    Sleep(50);
  until GetTickCount64 - Started >= 10000;
  WriteLn(StdErr, 'registry publish hostile e2e cleanup: ', Failure);
  FScratch := '';
end;

{ The origin advertises the proxy's port and listens elsewhere, so every
  client request goes through the proxy. }
procedure TRegistryPublishHostileE2E.StartProxiedOrigin(const AMode: TProxyMode);
begin
  FProxy := TPublishProxy.Create;
  FOther := TRegistryTestServer.Create(nil);
  FOther.Start;
  FOrigin := TPublishOrigin.Create(FScratch, 'origin', FProxy.Port,
    FindAvailableRegistryTestPort);
  FToken := FOrigin.IssueToken(['--packages', '*']);
  FOrigin.Start;
  FProxy.Backend := FOrigin.ListenPort;
  FProxy.Other := FOther.Port;
  FProxy.Token := FToken;
  FProxy.Base := FOrigin.Base;
  FProxy.Mode := AMode;
  FProxy.Start;
end;

function TRegistryPublishHostileE2E.PublishThroughProxy(const AName,
  AContent: string): TLwptResult;
var
  Path: string;
begin
  Path := FScratch + '/' + AName + '.tar.gz';
  WriteBinaryFile(Path, PublishTarGz(AName, '1.0.0', AContent));
  Result := RunPublish(Path, FOrigin.Base, FOrigin.KeyID, FOrigin.PublicKey, '',
    FToken, FProject, [], []);
  FOutputs := FOutputs + Result.Stdout + Result.Stderr;
end;

procedure TRegistryPublishHostileE2E.DirectPublish(AOrigin: TPublishOrigin;
  const AName, AContent: string);
var
  Archive: TBytes;
  Authorization: string;
begin
  Archive := PublishTarGz(AName, '1.0.0', AContent);
  Authorization := 'Authorization: Bearer ' + FToken;
  Expect<Integer>(AOrigin.Request('PUT', '/v1/objects/sha256/'
    + Copy(RegistryArtifactHash(Archive), 8, 64), [Authorization], Archive).Status)
    .ToBe(201);
  Expect<Integer>(AOrigin.Request('PUT', '/v1/packages/' + AName + '/1.0.0',
    [Authorization], RawHTTPBytes('schema = "' + RegistryProgramName
      + '-registry-package-v1"' + #10 + 'origin = "' + AOrigin.Base + '"' + #10
      + 'name = "' + AName + '"' + #10 + 'version = "1.0.0"' + #10
      + 'archive = "' + RegistryArtifactHash(Archive) + '"' + #10
      + 'archive_size = ' + IntToStr(Length(Archive)) + #10
      + 'published_at = "' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
        LocalTimeToUniversal(Now)) + '"' + #10 + 'yanked = false' + #10
      + 'dependencies = []' + #10)).Status).ToBe(201);
end;

procedure TRegistryPublishHostileE2E.ExpectRefused(const ARun: TLwptResult;
  const APrefix: string);
begin
  if Pos(APrefix, ARun.Stderr) = 0 then
    WriteLn(StdErr, 'expected "', APrefix, '" in: ', ARun.Stderr);
  Expect<Integer>(ARun.ExitCode).ToBe(1);
  Expect<Boolean>(Pos(APrefix, ARun.Stderr) > 0).ToBe(True);
  Expect<string>(PublishLine(ARun)).ToBe('');
end;

procedure TRegistryPublishHostileE2E.ExpectNoCredentialPrinted;
begin
  Expect<Boolean>(Pos(FToken, FOutputs) = 0).ToBe(True);
  Expect<Boolean>(Pos(TokenSecret(FToken), FOutputs) = 0).ToBe(True);
end;

procedure TRegistryPublishHostileE2E.TestRedirectsAreRefusedWithoutContactingTheTarget;
begin
  StartProxiedOrigin(pmRedirectDiscovery);
  ExpectRefused(PublishThroughProxy('redirect-lib', 'a'),
    'registry: unexpected_redirect: origin answered discovery with HTTP 302');
  { A redirected upload would carry the credential to a second authority. }
  FProxy.SetMode(pmRedirectUpload);
  ExpectRefused(PublishThroughProxy('redirect-lib', 'a'),
    'registry: unexpected_redirect: origin answered the archive upload with HTTP 307');
  { Not retried: exactly one attempt, and nothing reached the target. }
  Expect<Integer>(FProxy.Count('object')).ToBe(1);
  Sleep(200);
  Expect<Integer>(FOther.AcceptedCount).ToBe(0);
  Expect<Integer>(FOrigin.LatestSequence).ToBe(1);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.TestDiscoveryCannotNameAnotherAuthority;
begin
  StartProxiedOrigin(pmForeignAPI);
  ExpectRefused(PublishThroughProxy('scope-lib', 'a'),
    'registry: registry_discovery_scope_mismatch: ');
  Expect<Integer>(FProxy.Count('GET')).ToBe(1);
  Sleep(200);
  Expect<Integer>(FOther.AcceptedCount).ToBe(0);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.TestReflectedCredentialsAreNeverPrinted;
var
  Run: TLwptResult;
begin
  StartProxiedOrigin(pmEchoError);
  { Code, message, request_id, status text, and headers all hold it. }
  ExpectRefused(PublishThroughProxy('echo-lib', 'a'), 'registry: unrecognized_error: '
    + 'origin refused the archive upload with HTTP 403' + LineEnding);
  FProxy.SetMode(pmEchoKnownError);
  ExpectRefused(PublishThroughProxy('echo-lib', 'a'), 'registry: identity_conflict: '
    + 'origin refused the archive upload with HTTP 409 (request r0123abc)');
  FProxy.SetMode(pmEchoETag);
  ExpectRefused(PublishThroughProxy('echo-lib', 'a'), 'registry: unexpected_response: ');
  FProxy.SetMode(pmEchoLocation);
  ExpectRefused(PublishThroughProxy('echo-lib', 'a'), 'registry: unexpected_response: ');
  FProxy.SetMode(pmEchoOrigin);
  ExpectRefused(PublishThroughProxy('echo-lib', 'a'),
    'registry: checkpoint_origin_mismatch: the checkpoint names a different '
    + 'origin than discovery' + LineEnding);
  { The verifier quotes an unsupported schema value; only fixed local text
    reaches the output. }
  FProxy.SetMode(pmEchoSchema);
  ExpectRefused(PublishThroughProxy('echo-lib', 'a'),
    'registry: unsupported_registry_schema: the origin sent a document with '
    + 'an unsupported schema' + LineEnding);
  { A transport error whose text would carry it is redacted. }
  FProxy.SetMode(pmEchoTransport);
  Run := PublishThroughProxy('echo-lib', 'a');
  ExpectRefused(Run, 'registry: registry_transport_failed: ');
  Expect<Boolean>(Pos('[redacted]', Run.Stderr) > 0).ToBe(True);
  { A retry after a reflected Retry-After still succeeds. }
  FProxy.SetMode(pmEchoRetryAfter);
  Run := PublishThroughProxy('echo-lib', 'a');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('already published echo-lib@1.0.0', PublishLine(Run)) = 1)
    .ToBe(True);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.TestRetryableAnswersAreRetriedBoundedly;
var
  Run: TLwptResult;
begin
  StartProxiedOrigin(pmRetry);
  Run := PublishThroughProxy('retry-lib', 'a');
  if Run.ExitCode <> 0 then WriteLn(StdErr, Run.Stderr);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(FProxy.Count('object')).ToBe(3);
  Expect<Integer>(FProxy.Count('record')).ToBe(2);
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  FProxy.SetMode(pmAlways503);
  Run := PublishThroughProxy('retry-other', 'b');
  ExpectRefused(Run, 'registry: temporary_failure: origin refused the archive upload '
    + 'with HTTP 503 (request r3)');
  Expect<Integer>(FProxy.Count('object')).ToBe(5);
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.TestWithheldOrFakedPublicationFails;
begin
  { The origin commits, but keeps serving the first head afterwards. }
  StartProxiedOrigin(pmCheckpointAfter);
  FProxy.CheckpointSequence := 1;
  ExpectRefused(PublishThroughProxy('withheld-lib', 'a'),
    'registry: publication_not_included: ');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  { An acknowledgement for a record the origin never received. }
  FProxy.SetMode(pmFakeCreated);
  ExpectRefused(PublishThroughProxy('faked-lib', 'a'),
    'registry: publication_not_included: ');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.TestDowngradedCheckpointFails;
begin
  StartProxiedOrigin(pmCheckpointAfter);
  DirectPublish(FOrigin, 'earlier-lib', 'first');
  { First head is sequence 2; after the commit the proxy serves 1. }
  FProxy.CheckpointSequence := 1;
  ExpectRefused(PublishThroughProxy('downgrade-lib', 'a'),
    'registry: checkpoint_downgrade: ');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(3);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.TestTamperedSignatureOrSnapshotFails;
begin
  StartProxiedOrigin(pmTamperSignature);
  ExpectRefused(PublishThroughProxy('signed-lib', 'a'), 'registry: signature_invalid: '
    + 'the checkpoint signature does not verify' + LineEnding);
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  FProxy.SetMode(pmTamperSnapshot);
  ExpectRefused(PublishThroughProxy('snapshot-lib', 'a'),
    'registry: resource_hash_mismatch: ');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(3);
  ExpectNoCredentialPrinted;
end;

procedure CopyTree(const ASource, ATarget: string);
var
  Search: TSearchRec;
  Input, Output: TFileStream;
begin
  ForceDirectories(ATarget);
  if FindFirst(ASource + '/*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        CopyTree(ASource + '/' + Search.Name, ATarget + '/' + Search.Name)
      else
      begin
        Input := TFileStream.Create(ASource + '/' + Search.Name, fmOpenRead);
        try
          Output := TFileStream.Create(ATarget + '/' + Search.Name, fmCreate);
          try
            Output.CopyFrom(Input, 0);
          finally
            Output.Free;
          end;
        finally
          Input.Free;
        end;
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure TRegistryPublishHostileE2E.TestInconsistentHistoryFails;
begin
  { Two origins with one identity and one key diverge at sequence 2. The
    proxy serves the first head from one and commits to the other. }
  FProxy := TPublishProxy.Create;
  FOrigin := TPublishOrigin.Create(FScratch, 'first', FProxy.Port,
    FindAvailableRegistryTestPort);
  FToken := FOrigin.IssueToken(['--packages', '*']);
  CopyTree(FOrigin.DataDirectory, FScratch + '/second');
  FSecond := TPublishOrigin.Create(FScratch, 'second', FProxy.Port,
    FindAvailableRegistryTestPort);
  Expect<string>(FSecond.KeyID).ToBe(FOrigin.KeyID);
  FOrigin.Start;
  FSecond.Start;
  DirectPublish(FOrigin, 'fork-a', 'a');
  DirectPublish(FSecond, 'fork-b', 'b');
  FProxy.Backend := FOrigin.ListenPort;
  FProxy.SecondBackend := FSecond.ListenPort;
  FProxy.Token := FToken;
  FProxy.Base := FOrigin.Base;
  FProxy.SetMode(pmSwitchBackend);
  FProxy.Start;
  ExpectRefused(PublishThroughProxy('fork-lib', 'c'),
    'registry: snapshot_consistency_failed: ');
  Expect<Integer>(FSecond.LatestSequence).ToBe(3);
  ExpectNoCredentialPrinted;
end;

procedure TRegistryPublishHostileE2E.SetupTests;
begin
  Test('redirects are refused without contacting their target',
    TestRedirectsAreRefusedWithoutContactingTheTarget);
  Test('discovery cannot move requests to another authority',
    TestDiscoveryCannotNameAnotherAuthority);
  Test('a credential reflected in any response field is never printed',
    TestReflectedCredentialsAreNeverPrinted);
  Test('429 and 503 are retried at most five times',
    TestRetryableAnswersAreRetriedBoundedly);
  Test('a withheld or faked publication fails inclusion',
    TestWithheldOrFakedPublicationFails);
  Test('a downgraded checkpoint after the commit fails', TestDowngradedCheckpointFails);
  Test('a tampered signature or snapshot fails although the origin answered 201',
    TestTamperedSignatureOrSnapshotFails);
  Test('a head that does not extend the first head fails consistency',
    TestInconsistentHistoryFails);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryPublishHostileE2E.Create(
    'registry publish hostile e2e'));
  TestRunnerProgram.Run;
end.
