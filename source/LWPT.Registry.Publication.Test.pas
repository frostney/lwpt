program LWPT.Registry.Publication.Test;

{ In-process origin behind the real listener, driven by raw HTTP requests:
  authentication, scopes, limits, idempotency, lifecycle, failure points,
  package lists, audit content, and the amended conformance corpus. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  DateUtils,
  SysUtils,

  LWPT.Core,
  LWPT.ProducerLease,
  LWPT.Registry.Incoming,
  LWPT.Registry.Mirror,
  LWPT.Registry.Publication,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Tokens,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.RegistryHTTP,
  Tests.RegistryServer,
  Tests.Scratch;

const
  FIXTURES = 'tests/fixtures/registry/v1/';
  MEBIBYTE = Int64(1024) * 1024;

type
  TServeThread = class(TThread)
  private
    FServer: TLWPTRegistryServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TLWPTRegistryServer);
  end;

  TRequestThread = class(TThread)
  private
    FPort: Word;
    FMethod, FTarget, FToken: string;
    FBody: TBytes;
  protected
    procedure Execute; override;
  public
    Response: TRawHTTPResponse;
    constructor Create(const APort: Word; const AMethod, ATarget,
      AToken: string; const ABody: TBytes);
  end;

  { Takes a guard as soon as it is free and holds it for a while. }
  TGuardHolder = class(TThread)
  private
    FCoordinator: TLWPTProducerLeaseCoordinator;
    FKey: string;
    FHoldMilliseconds: Cardinal;
  protected
    procedure Execute; override;
  public
    Acquired: PRTLEvent;
    constructor Create(const ALocks, AKey: string;
      const AHoldMilliseconds: Cardinal);
    destructor Destroy; override;
  end;

  TRegistryPublicationContract = class(TTestSuite)
  private
    FScratch, FRoot, FBase, FPrefix, FToken: string;
    FPort: Word;
    FStore: TLWPTRegistryStore;
    FServer: TLWPTRegistryServer;
    FThread: TServeThread;
    procedure StartOrigin(const AIdentity, APath, APublishedAt: string;
      const AIssueToken: Boolean = True);
    procedure StopOrigin;
    function Request(const AMethod, ATarget: string; const AToken: string;
      const ABody: TBytes; const AExtraHeaders: array of string): TRawHTTPResponse; overload;
    function Request(const AMethod, ATarget: string; const AToken: string;
      const ABody: TBytes): TRawHTTPResponse; overload;
    function Get(const ATarget: string): TRawHTTPResponse;
    function Upload(const AArchive: TBytes; const AToken: string = ''): TRawHTTPResponse;
    function RecordText(const AName, AVersion: string; const AArchive: TBytes;
      const APublishedAt: string; const AYanked: Boolean = False;
      const ADependencies: string = '[]'): string;
    function PublishText(const AName, AVersion, AText: string;
      const AToken: string = ''): TRawHTTPResponse;
    function Publish(const AName, AVersion: string; const AArchive: TBytes;
      const APublishedAt: string = ''): TRawHTTPResponse;
    function IssueToken(const APatterns: array of string;
      const AActions: TLWPTRegistryTokenActions; const ADays: Integer = 90;
      const AIssuedAt: string = ''): string;
    function Sequence: Int64;
    function AuditText: string;
    { Every audit record answering AStatus, concatenated. }
    function AuditsWithStatus(const AStatus: Integer): TStringList;
    function LatestCheckpointHash: string;
    function Fixture(const APath: string): TBytes;
    function HexFixture(const APath: string): TBytes;
    function WithoutRequestID(const AText: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestPublicationRoundTrip;
    procedure TestReadOnlyOriginsAndMirrorsRefuseMutation;
    procedure TestIdenticalRetriesSucceed;
    procedure TestConflictingContentIsRejected;
    procedure TestRecordValidation;
    procedure TestDependencyRefusalIsSeparable;
    procedure TestYankAndRestore;
    procedure TestAuthenticationFailures;
    procedure TestScopes;
    procedure TestLimitsApplyBeforeTheBody;
    procedure TestRateBounds;
    procedure TestBodyConcurrencyAndLeaseWaits;
    procedure TestTimedOutCommitLeavesStagingUnchanged;
    procedure TestStorageBudget;
    procedure TestAuditRecordsAreSecretFree;
    procedure TestServerClockBehindHeadRefuses;
    procedure TestFailureBeforePointerKeepsOldHead;
    procedure TestFailureAfterPointerServesNewHead;
    procedure TestReadersSeeOldOrNewHead;
    procedure TestPackageListReads;
    procedure TestAmendedConformanceCorpus;
    procedure ExpectRetryAudits(const ACount: Integer; const ASequence: Int64);
    procedure TestGuardTimeoutRefusesCommitsWithoutAdoption;
    procedure TestExpiredUploadsFreeTheBudgetForAdmission;
    procedure TestDoubleDotNamesRoute;
    procedure TestMalformedMutationsAreAudited;
    procedure TestSlowBodiesHitTheDeadline;
    procedure TestIncompleteMutatingHeadsAreAudited;
    procedure TestLongAdmissionStillAnswersRetryably;
  private
    FFinalHolder: TGuardHolder;
    procedure SlowAdmissionHook(const APoint: string);
  end;

constructor TGuardHolder.Create(const ALocks, AKey: string;
  const AHoldMilliseconds: Cardinal);
begin
  FCoordinator := TLWPTProducerLeaseCoordinator.Create(ALocks);
  FKey := AKey;
  FHoldMilliseconds := AHoldMilliseconds;
  Acquired := RTLEventCreate;
  FreeOnTerminate := False;
  inherited Create(True);
end;

destructor TGuardHolder.Destroy;
begin
  RTLEventDestroy(Acquired);
  FCoordinator.Free;
  inherited Destroy;
end;

procedure TGuardHolder.Execute;
var
  Guard: TObject;
  Started: QWord;
begin
  Guard := nil;
  Started := GetTickCount64;
  while not Assigned(Guard) and (GetTickCount64 - Started < 10000) do
  begin
    Guard := FCoordinator.TryAcquireGuard(FKey);
    if not Assigned(Guard) then Sleep(1);
  end;
  RTLEventSetEvent(Acquired);
  Sleep(FHoldMilliseconds);
  Guard.Free;
end;

constructor TServeThread.Create(AServer: TLWPTRegistryServer);
begin
  FServer := AServer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TServeThread.Execute;
begin
  try
    FServer.Run;
  except
  end;
end;

constructor TRequestThread.Create(const APort: Word; const AMethod, ATarget,
  AToken: string; const ABody: TBytes);
begin
  FPort := APort;
  FMethod := AMethod;
  FTarget := ATarget;
  FToken := AToken;
  FBody := ABody;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TRequestThread.Execute;
begin
  try
    Response := RawHTTPRequest(FPort, FMethod, FTarget,
      ['Authorization: Bearer ' + FToken], FBody);
  except
  end;
end;

function FreePort: Word;
var
  Reservation: TRegistryTestServer;
begin
  Reservation := TRegistryTestServer.Create(nil);
  try
    Result := Reservation.Port;
  finally
    Reservation.Free;
  end;
end;

function Bytes(const AText: string): TBytes;
begin
  Result := RawHTTPBytes(AText);
end;

function Filled(const ASize: Integer; const AByte: Byte): TBytes;
begin
  SetLength(Result, ASize);
  if ASize > 0 then FillChar(Result[0], ASize, AByte);
end;

procedure TRegistryPublicationContract.StartOrigin(const AIdentity, APath,
  APublishedAt: string; const AIssueToken: Boolean);
var
  Config: TLWPTRegistryConfig;
  Started: QWord;
begin
  FPort := FreePort;
  FPrefix := APath;
  FBase := 'http://localhost:' + IntToStr(FPort) + APath;
  FRoot := FScratch + '/origin';
  Config := RegistryConfiguration(AIdentity, FBase, 'localhost', FPort, '', '');
  FStore := TLWPTRegistryStore.Initialize(FRoot, Config, APublishedAt);
  FServer := TLWPTRegistryServer.Create(FStore);
  FThread := TServeThread.Create(FServer);
  Started := GetTickCount64;
  repeat
    try
      if Get('/.well-known/' + PROGRAM_NAME + '-registry').Status = 200 then Break;
    except
    end;
    if GetTickCount64 - Started > 5000 then
      raise Exception.Create('in-process registry did not start');
    Sleep(10);
  until False;
  if AIssueToken then
    FToken := IssueToken(['*'], [rtaPublish, rtaYank], 365, APublishedAt);
end;

procedure TRegistryPublicationContract.StopOrigin;
begin
  if Assigned(FServer) then FServer.RequestStop;
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FreeAndNil(FServer);
  FreeAndNil(FStore);
end;

function TRegistryPublicationContract.Request(const AMethod, ATarget: string;
  const AToken: string; const ABody: TBytes;
  const AExtraHeaders: array of string): TRawHTTPResponse;
var
  Headers: array of string;
  Index: Integer;
begin
  SetLength(Headers, Length(AExtraHeaders));
  for Index := 0 to High(AExtraHeaders) do Headers[Index] := AExtraHeaders[Index];
  if AToken <> '' then
  begin
    SetLength(Headers, Length(Headers) + 1);
    Headers[High(Headers)] := 'Authorization: Bearer ' + AToken;
  end;
  Result := RawHTTPRequest(FPort, AMethod, FPrefix + ATarget, Headers, ABody);
end;

function TRegistryPublicationContract.Request(const AMethod, ATarget: string;
  const AToken: string; const ABody: TBytes): TRawHTTPResponse;
begin
  Result := Request(AMethod, ATarget, AToken, ABody, []);
end;

function TRegistryPublicationContract.Get(const ATarget: string): TRawHTTPResponse;
begin
  Result := RawHTTPRequest(FPort, 'GET', FPrefix + ATarget, [], nil, False);
end;

function TRegistryPublicationContract.Upload(const AArchive: TBytes;
  const AToken: string): TRawHTTPResponse;
var
  Token: string;
begin
  Token := AToken;
  if Token = '' then Token := FToken;
  Result := Request('PUT', '/v1/objects/sha256/' + SHA256Hex(AArchive), Token,
    AArchive);
end;

function TRegistryPublicationContract.RecordText(const AName, AVersion: string;
  const AArchive: TBytes; const APublishedAt: string; const AYanked: Boolean;
  const ADependencies: string): string;
const
  YANKED: array[Boolean] of string = ('false', 'true');
begin
  Result := 'schema = "' + PROGRAM_NAME + '-registry-package-v1"' + #10
    + 'origin = "' + FStore.Config.Identity + '"' + #10
    + 'name = "' + AName + '"' + #10
    + 'version = "' + AVersion + '"' + #10
    + 'archive = "' + SHA256BytesPrefixed(AArchive) + '"' + #10
    + 'archive_size = ' + IntToStr(Length(AArchive)) + #10
    + 'published_at = "' + APublishedAt + '"' + #10
    + 'yanked = ' + YANKED[AYanked] + #10
    + 'dependencies = ' + ADependencies + #10;
end;

function TRegistryPublicationContract.PublishText(const AName, AVersion,
  AText: string; const AToken: string): TRawHTTPResponse;
var
  Token: string;
begin
  Token := AToken;
  if Token = '' then Token := FToken;
  Result := Request('PUT', '/v1/packages/' + AName + '/' + AVersion, Token,
    Bytes(AText));
end;

function TRegistryPublicationContract.Publish(const AName, AVersion: string;
  const AArchive: TBytes; const APublishedAt: string): TRawHTTPResponse;
var
  PublishedAt: string;
begin
  PublishedAt := APublishedAt;
  if PublishedAt = '' then PublishedAt := RegistryTimestampNow;
  Result := PublishText(AName, AVersion, RecordText(AName, AVersion, AArchive,
    PublishedAt));
end;

function TRegistryPublicationContract.IssueToken(const APatterns: array of string;
  const AActions: TLWPTRegistryTokenActions; const ADays: Integer;
  const AIssuedAt: string): string;
var
  TokenRecord: TLWPTRegistryToken;
  IssuedAt: string;
begin
  IssuedAt := AIssuedAt;
  if IssuedAt = '' then IssuedAt := RegistryTimestampNow;
  Result := IssueRegistryToken(FRoot, APatterns, AActions, ADays, 'test',
    IssuedAt, TokenRecord);
end;

function TRegistryPublicationContract.Sequence: Int64;
var
  Response: TRawHTTPResponse;
begin
  Response := Get('/v1/checkpoints/latest.toml');
  Result := InspectRegistryCheckpoint(Response.Body).Sequence;
end;

function CollectFiles(const ADirectory: string; AList: TStringList): Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*', faAnyFile,
    Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        Inc(Result, CollectFiles(IncludeTrailingPathDelimiter(ADirectory)
          + Search.Name, AList))
      else
      begin
        AList.Add(IncludeTrailingPathDelimiter(ADirectory) + Search.Name);
        Inc(Result);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TRegistryPublicationContract.AuditText: string;
var
  Files: TStringList;
  Path: string;
begin
  Result := '';
  Files := TStringList.Create;
  try
    CollectFiles(FRoot + '/audit', Files);
    Files.Sort;
    for Path in Files do
      if Pos('.staging', Path) = 0 then Result := Result + ReadBinaryFile(Path) + #0;
  finally
    Files.Free;
  end;
end;

function TRegistryPublicationContract.AuditsWithStatus(
  const AStatus: Integer): TStringList;
var
  Files: TStringList;
  Path, Text: string;
begin
  Result := TStringList.Create;
  Files := TStringList.Create;
  try
    CollectFiles(FRoot + '/audit', Files);
    for Path in Files do
    begin
      if Pos('.staging', Path) > 0 then Continue;
      Text := ReadBinaryFile(Path);
      if Pos('status = ' + IntToStr(AStatus) + #10, Text) > 0 then
        Result.Add(Text);
    end;
  finally
    Files.Free;
  end;
end;

function TRegistryPublicationContract.LatestCheckpointHash: string;
begin
  Result := SHA256BytesPrefixed(Get('/v1/checkpoints/latest.toml').Body);
end;

function TRegistryPublicationContract.Fixture(const APath: string): TBytes;
begin
  Result := Bytes(ReadBinaryFile(FIXTURES + APath));
end;

function TRegistryPublicationContract.HexFixture(const APath: string): TBytes;
var
  Text, Hex: string;
  Character: Char;
  Index: Integer;
begin
  Text := ReadBinaryFile(FIXTURES + APath);
  Hex := '';
  for Character in Text do
    if Character in ['0'..'9', 'a'..'f'] then Hex := Hex + Character;
  SetLength(Result, Length(Hex) div 2);
  for Index := 0 to High(Result) do
    Result[Index] := StrToInt('$' + Copy(Hex, Index * 2 + 1, 2));
end;

function TRegistryPublicationContract.WithoutRequestID(const AText: string): string;
var
  Lines: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for Index := Lines.Count - 1 downto 0 do
      if Pos('request_id = ', Lines[Index]) = 1 then Lines.Delete(Index);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TRegistryPublicationContract.BeforeEach;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
  FScratch := CreateScratchRoot('registry-publication');
  SetRegistryClockForTesting('');
  SetRegistryFailurePointForTesting('');
  SetRegistryRateLimitsForTesting(0, 0);
  SetRegistryDependencyRefusalForTesting(True);
end;

procedure TRegistryPublicationContract.AfterEach;
begin
  StopOrigin;
  SetRegistryClockForTesting('');
  SetRegistryFailurePointForTesting('');
  SetRegistryRateLimitsForTesting(0, 0);
  SetRegistryDependencyRefusalForTesting(True);
  SetRegistryPublicationBarrierForTesting('', '');
  SetRegistryBodyDeadlineForTesting(0);
  SetRegistryHeaderDeadlineForTesting(0);
end;

procedure TRegistryPublicationContract.AfterAll;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
end;

procedure TRegistryPublicationContract.TestPublicationRoundTrip;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Location: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Response := Get('/v1/capabilities');
  Expect<Boolean>(Pos('"publication-v1"', RawHTTPBodyText(Response)) > 0).ToBe(True);
  Expect<Boolean>(Pos('auth_schemes = ["bearer"]', RawHTTPBodyText(Response)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"package-list-v1"', RawHTTPBodyText(Response)) > 0).ToBe(True);
  Archive := Filled(2 * MEBIBYTE + 17, $5a);
  Response := Upload(Archive);
  Expect<Integer>(Response.Status).ToBe(201);
  Expect<string>(RawHTTPHeader(Response, 'ETag')).ToBe('"'
    + SHA256BytesPrefixed(Archive) + '"');
  Expect<string>(RawHTTPHeader(Response, 'Location')).ToBe('');
  Expect<Integer>(Upload(Archive).Status).ToBe(204);
  { Nothing under incoming/ is served. }
  Expect<Integer>(Get('/v1/objects/sha256/' + SHA256Hex(Archive)).Status).ToBe(404);
  Response := Publish('demo-lib', '1.0.0', Archive);
  Expect<Integer>(Response.Status).ToBe(201);
  Location := RawHTTPHeader(Response, 'Location');
  Expect<Boolean>(Pos(FBase + '/v1/records/sha256/', Location) = 1).ToBe(True);
  Expect<Int64>(Sequence).ToBe(2);
  Expect<Integer>(Get(Copy(Location, Length(FBase) + 1, MaxInt)).Status).ToBe(200);
  Response := Get('/v1/objects/sha256/' + SHA256Hex(Archive));
  Expect<Integer>(Response.Status).ToBe(200);
  Expect<Integer>(Length(Response.Body)).ToBe(Length(Archive));
  Expect<Boolean>(FileExists(FRoot + '/incoming/sha256/' + SHA256Hex(Archive)))
    .ToBe(False);
end;

procedure TRegistryPublicationContract.TestReadOnlyOriginsAndMirrorsRefuseMutation;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Config: TLWPTRegistryConfig;
  Mirror: TLWPTRegistryStore;
  Publisher: TLWPTRegistryPublisher;
  Head: TLWPTRegistryRequestHead;
  HTTP: TLWPTRegistryHTTPResponse;
begin
  StartOrigin('', '', RegistryTimestampNow, False);
  Response := Get('/v1/capabilities');
  Expect<Boolean>(Pos('publication-v1', RawHTTPBodyText(Response)) = 0).ToBe(True);
  Expect<Boolean>(Pos('auth_schemes = []', RawHTTPBodyText(Response)) > 0).ToBe(True);
  Archive := Bytes('read-only');
  Response := Upload(Archive, 'unused');
  Expect<Integer>(Response.Status).ToBe(405);
  Expect<Boolean>(Pos('method_not_allowed', RawHTTPBodyText(Response)) > 0)
    .ToBe(True);
  Config := RegistryConfiguration('http://localhost:8181', 'http://localhost:8182',
    'localhost', 8182, '', '');
  Config.Role := rrMirror;
  Config.UpstreamURL := Config.Identity;
  { Public protocol corpus pin, not secret material. }
  Config.TrustPublicKey := 'hex:d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
  Config.TrustKeyID := 'ed25519:21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9';
  Mirror := TLWPTRegistryMirror.Initialize(FScratch + '/mirror', Config,
    RegistryTimestampNow);
  Publisher := TLWPTRegistryPublisher.Create(Mirror);
  try
    Expect<Boolean>(ParseRegistryRequestHead('PUT /v1/packages/demo/1.0.0 HTTP/1.1'
      + #13#10 + 'Content-Length: 1', '127.0.0.1', Head)).ToBe(True);
    Expect<Boolean>(Publisher.BeginMutation(Head, HTTP) = nil).ToBe(True);
    Expect<Integer>(HTTP.Status).ToBe(405);
  finally
    Publisher.Free;
    Mirror.Free;
  end;
end;

procedure TRegistryPublicationContract.TestIdenticalRetriesSucceed;
var
  Archive: TBytes;
  First, Retry, Fresh: TRawHTTPResponse;
  Text: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('retry archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Text := RecordText('retry-lib', '1.0.0', Archive, RegistryTimestampNow);
  First := PublishText('retry-lib', '1.0.0', Text);
  Expect<Integer>(First.Status).ToBe(201);
  { A lost 201 is retried with the same bytes. }
  Retry := PublishText('retry-lib', '1.0.0', Text);
  Expect<Integer>(Retry.Status).ToBe(204);
  Expect<string>(RawHTTPHeader(Retry, 'Location'))
    .ToBe(RawHTTPHeader(First, 'Location'));
  { A retried CI job builds a fresh record with a new time stamp. }
  Fresh := PublishText('retry-lib', '1.0.0', RecordText('retry-lib', '1.0.0',
    Archive, FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
      LocalTimeToUniversal(Now) - 1 / 24)));
  Expect<Integer>(Fresh.Status).ToBe(204);
  Expect<string>(RawHTTPHeader(Fresh, 'Location'))
    .ToBe(RawHTTPHeader(First, 'Location'));
  Expect<Int64>(Sequence).ToBe(2);
  ExpectRetryAudits(2, 2);
end;

procedure TRegistryPublicationContract.ExpectRetryAudits(const ACount: Integer;
  const ASequence: Int64);
var
  Audits: TStringList;
  Text, Checkpoint: string;
  Records: Integer;
begin
  { Idempotent answers record the resulting head, like a new commit. }
  Checkpoint := LatestCheckpointHash;
  Audits := AuditsWithStatus(204);
  try
    Records := 0;
    for Text in Audits do
      if Pos('route = "/v1/packages/', Text) > 0 then
      begin
        Inc(Records);
        Expect<Boolean>(Pos('sequence = ' + IntToStr(ASequence) + #10, Text) > 0)
          .ToBe(True);
        Expect<Boolean>(Pos('checkpoint = "' + Checkpoint + '"', Text) > 0)
          .ToBe(True);
        Expect<Boolean>(Pos('record = "sha256:', Text) > 0).ToBe(True);
      end;
    Expect<Integer>(Records).ToBe(ACount);
  finally
    Audits.Free;
  end;
end;

procedure TRegistryPublicationContract.TestConflictingContentIsRejected;
var
  Original, Different: TBytes;
  Response: TRawHTTPResponse;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Original := Bytes('original archive');
  Different := Bytes('different archive');
  Expect<Integer>(Upload(Original).Status).ToBe(201);
  Expect<Integer>(Upload(Different).Status).ToBe(201);
  Expect<Integer>(Publish('conflict-lib', '1.0.0', Original).Status).ToBe(201);
  Response := Publish('conflict-lib', '1.0.0', Different);
  Expect<Integer>(Response.Status).ToBe(409);
  Expect<Boolean>(Pos('code = "identity_conflict"', RawHTTPBodyText(Response)) > 0)
    .ToBe(True);
  Expect<Int64>(Sequence).ToBe(2);
  Expect<Boolean>(Pos('status = 409' + #10 + 'code = "identity_conflict"',
    AuditText) > 0).ToBe(True);
end;

procedure TRegistryPublicationContract.TestRecordValidation;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Stale: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('validated archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Response := PublishText('valid-lib', '1.0.0', RecordText('valid-lib', '1.0.0',
    Archive, RegistryTimestampNow, True));
  Expect<Integer>(Response.Status).ToBe(400);
  Expect<Boolean>(Pos('code = "invalid_request"', RawHTTPBodyText(Response)) > 0)
    .ToBe(True);
  Stale := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now) - 6 / 1440);
  Expect<Integer>(PublishText('valid-lib', '1.0.0', RecordText('valid-lib',
    '1.0.0', Archive, Stale)).Status).ToBe(400);
  { The path must name the record's identity. }
  Expect<Integer>(PublishText('valid-lib', '2.0.0', RecordText('valid-lib',
    '1.0.0', Archive, RegistryTimestampNow)).Status).ToBe(400);
  Expect<Integer>(PublishText('valid-lib', '1.0.0', StringReplace(RecordText(
    'valid-lib', '1.0.0', Archive, RegistryTimestampNow), 'yanked = false',
    'yanked  = false', [])).Status).ToBe(400);
  Expect<Integer>(PublishText('valid-lib', '1.0.0', RecordText('valid-lib',
    '1.0.0', Bytes('never uploaded'), RegistryTimestampNow)).Status).ToBe(424);
  Expect<Integer>(PublishText('valid-lib', '1.0.0', StringReplace(RecordText(
    'valid-lib', '1.0.0', Archive, RegistryTimestampNow), 'archive_size = 17',
    'archive_size = 18', [])).Status).ToBe(424);
  Expect<Int64>(Sequence).ToBe(1);
  Expect<Integer>(Publish('valid-lib', '1.0.0', Archive).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestDependencyRefusalIsSeparable;
var
  Archive: TBytes;
  Text: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('dependent archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Text := RecordText('dependent-lib', '1.0.0', Archive, RegistryTimestampNow,
    False, '[{ name = "base-lib", version = "^1.0.0" }]');
  Expect<Boolean>(RegistryRecordDependenciesSupported(0)).ToBe(True);
  Expect<Boolean>(RegistryRecordDependenciesSupported(1)).ToBe(False);
  Expect<Integer>(PublishText('dependent-lib', '1.0.0', Text).Status).ToBe(400);
  SetRegistryDependencyRefusalForTesting(False);
  Expect<Integer>(PublishText('dependent-lib', '1.0.0', Text).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestYankAndRestore;
var
  Archive: TBytes;
  Published, Response: TRawHTTPResponse;
  PublishOnly, OtherPackage, OriginalLocation, Body, Text: string;
  Audits: TStringList;
  Found: Boolean;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('lifecycle archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Published := Publish('life-lib', '1.0.0', Archive);
  Expect<Integer>(Published.Status).ToBe(201);
  OriginalLocation := RawHTTPHeader(Published, 'Location');
  PublishOnly := IssueToken(['*'], [rtaPublish]);
  OtherPackage := IssueToken(['other-*'], [rtaYank]);
  Expect<Integer>(Request('PUT', '/v1/packages/life-lib/1.0.0/yank', PublishOnly,
    nil).Status).ToBe(403);
  Expect<Integer>(Request('PUT', '/v1/packages/life-lib/1.0.0/yank', OtherPackage,
    nil).Status).ToBe(403);
  Response := Request('PUT', '/v1/packages/life-lib/1.0.0/yank', FToken, nil);
  Expect<Integer>(Response.Status).ToBe(201);
  Body := RawHTTPBodyText(Response);
  Expect<Boolean>(Pos('yanked = true', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('archive = "' + SHA256BytesPrefixed(Archive) + '"', Body) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('archive_size = ' + IntToStr(Length(Archive)), Body) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('dependencies = []', Body) > 0).ToBe(True);
  Expect<string>(RawHTTPHeader(Response, 'Location')).ToBe(FBase
    + '/v1/records/sha256/' + SHA256Hex(Response.Body) + '.toml');
  Expect<Integer>(Request('PUT', '/v1/packages/life-lib/1.0.0/yank', FToken,
    nil).Status).ToBe(204);
  Expect<Int64>(Sequence).ToBe(3);
  { A yanked identity still answers an identical publication with 204. }
  Expect<Integer>(Publish('life-lib', '1.0.0', Archive).Status).ToBe(204);
  Response := Request('DELETE', '/v1/packages/life-lib/1.0.0/yank', FToken, nil,
    []);
  Expect<Integer>(Response.Status).ToBe(201);
  Expect<Boolean>(Pos('yanked = false', RawHTTPBodyText(Response)) > 0).ToBe(True);
  Expect<Integer>(Request('DELETE', '/v1/packages/life-lib/1.0.0/yank', FToken,
    nil).Status).ToBe(204);
  Expect<Integer>(Request('PUT', '/v1/packages/life-lib/9.9.9/yank', FToken,
    nil).Status).ToBe(404);
  { The original record stays retrievable by hash. }
  Expect<Integer>(Get(Copy(OriginalLocation, Length(FBase) + 1, MaxInt)).Status)
    .ToBe(200);
  Expect<Int64>(Sequence).ToBe(4);
  { The repeated restore answered at the final head. }
  Audits := AuditsWithStatus(204);
  try
    Found := False;
    for Text in Audits do
      if (Pos('action = "restore"', Text) > 0)
        and (Pos('checkpoint = "' + LatestCheckpointHash + '"', Text) > 0)
        and (Pos('sequence = 4' + #10, Text) > 0) then Found := True;
    Expect<Boolean>(Found).ToBe(True);
    Found := False;
    for Text in Audits do
      if (Pos('action = "yank"', Text) > 0)
        and (Pos('checkpoint = "sha256:', Text) > 0)
        and (Pos('sequence = 3' + #10, Text) > 0) then Found := True;
    Expect<Boolean>(Found).ToBe(True);
  finally
    Audits.Free;
  end;
end;

procedure TRegistryPublicationContract.TestAuthenticationFailures;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Revoked, Expired, IssuedYesterday: string;
  WrongLast: Char;
  TokenRecord: TLWPTRegistryToken;
  Audits: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  { A different base64url character keeps the credential well formed, so
    the failure is a secret mismatch. }
  WrongLast := 'A';
  if FToken[Length(FToken)] = 'A' then WrongLast := 'B';
  Archive := Bytes('auth archive');
  Response := Request('PUT', '/v1/objects/sha256/' + SHA256Hex(Archive), '',
    Archive);
  Expect<Integer>(Response.Status).ToBe(401);
  Expect<string>(RawHTTPHeader(Response, 'WWW-Authenticate')).ToBe('Bearer');
  Response := Request('PUT', '/v1/objects/sha256/' + SHA256Hex(Archive), '',
    Archive, ['Authorization: Basic Zm9vOmJhcg==']);
  Expect<Integer>(Response.Status).ToBe(401);
  Expect<Integer>(Upload(Archive, PROGRAM_NAME + '_rt1_'
    + StringOfChar('0', 32) + '_' + StringOfChar('A', 43)).Status).ToBe(401);
  Expect<Integer>(Upload(Archive, Copy(FToken, 1, Length(FToken) - 1)
    + WrongLast).Status).ToBe(401);
  Revoked := IssueToken(['*'], [rtaPublish]);
  Expect<Integer>(Upload(Archive, Revoked).Status).ToBe(201);
  RevokeRegistryToken(FRoot, Copy(Revoked, Length(PROGRAM_NAME + '_rt1_') + 1, 32),
    RegistryTimestampNow);
  Expect<Integer>(Upload(Archive, Revoked).Status).ToBe(401);
  IssuedYesterday := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now) - 1 - 1 / 1440);
  Expired := IssueRegistryToken(FRoot, ['*'], [rtaPublish], 1, '',
    IssuedYesterday, TokenRecord);
  Expect<Integer>(Upload(Archive, Expired).Status).ToBe(401);
  Audits := AuditText;
  Expect<Boolean>(Pos('auth_failure = "missing"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('auth_failure = "malformed"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('auth_failure = "unknown"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('auth_failure = "mismatch"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('auth_failure = "revoked"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('auth_failure = "expired"', Audits) > 0).ToBe(True);
end;

procedure TRegistryPublicationContract.TestScopes;
var
  Archive: TBytes;
  YankOnly, Scoped: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('scoped archive');
  YankOnly := IssueToken(['*'], [rtaYank]);
  Scoped := IssueToken(['team-*'], [rtaPublish]);
  Expect<Integer>(Upload(Archive, YankOnly).Status).ToBe(403);
  { Objects are unscoped until a record references them. }
  Expect<Integer>(Upload(Archive, Scoped).Status).ToBe(201);
  Expect<Integer>(PublishText('other-lib', '1.0.0', RecordText('other-lib',
    '1.0.0', Archive, RegistryTimestampNow), Scoped).Status).ToBe(403);
  Expect<Integer>(PublishText('team-lib', '1.0.0', RecordText('team-lib',
    '1.0.0', Archive, RegistryTimestampNow), Scoped).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestLimitsApplyBeforeTheBody;
var
  Connection: TRawHTTPConnection;
  Response: TRawHTTPResponse;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('PUT /v1/packages/big-lib/1.0.0 HTTP/1.1' + #13#10
      + 'Authorization: Bearer ' + FToken + #13#10
      + 'Content-Length: ' + IntToStr(RegistryMaximumRecordBytes + 1) + #13#10#13#10);
    Response := Connection.ReadResponse(10000);
    Expect<Integer>(Response.Status).ToBe(413);
  finally
    Connection.Free;
  end;
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('PUT /v1/objects/sha256/' + StringOfChar('a', 64)
      + ' HTTP/1.1' + #13#10 + 'Authorization: Bearer ' + FToken + #13#10
      + 'Content-Length: ' + IntToStr(RegistryMaximumArchiveBytes + 1)
      + #13#10#13#10);
    Response := Connection.ReadResponse(10000);
    Expect<Integer>(Response.Status).ToBe(413);
  finally
    Connection.Free;
  end;
  Response := RawHTTPRequest(FPort, 'PUT', '/v1/objects/sha256/'
    + SHA256Hex(Bytes('x')), ['Authorization: Bearer ' + FToken], Bytes('x'),
    False);
  Expect<Integer>(Response.Status).ToBe(400);
  Response := Request('PUT', '/v1/objects/sha256/' + SHA256Hex(Bytes('x')),
    FToken, Bytes('x'), ['Transfer-Encoding: chunked']);
  Expect<Integer>(Response.Status).ToBe(400);
  Response := Request('PUT', '/v1/objects/sha256/' + SHA256Hex(Bytes('x')),
    FToken, Bytes('x'), ['Content-Encoding: gzip']);
  Expect<Integer>(Response.Status).ToBe(400);
  Response := Request('PUT', '/v1/objects/sha256/' + SHA256Hex(Bytes('x')),
    FToken, Bytes('y'));
  Expect<Integer>(Response.Status).ToBe(422);
  Expect<Boolean>(Pos('uploaded object does not match its requested sha256',
    RawHTTPBodyText(Response)) > 0).ToBe(True);
end;

procedure TRegistryPublicationContract.TestRateBounds;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Index: Integer;
begin
  StartOrigin('', '', RegistryTimestampNow);
  SetRegistryRateLimitsForTesting(2, 2);
  Archive := Bytes('rated');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Expect<Integer>(Upload(Archive).Status).ToBe(204);
  Response := Upload(Archive);
  Expect<Integer>(Response.Status).ToBe(429);
  Expect<Boolean>(StrToIntDef(RawHTTPHeader(Response, 'Retry-After'), 0) >= 1)
    .ToBe(True);
  Expect<Boolean>(Pos('retryable = true', RawHTTPBodyText(Response)) > 0).ToBe(True);
  for Index := 1 to 2 do
    Expect<Integer>(Upload(Archive, 'wrong').Status).ToBe(401);
  Response := Upload(Archive, IssueToken(['*'], [rtaPublish]));
  Expect<Integer>(Response.Status).ToBe(429);
  Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
end;

procedure TRegistryPublicationContract.TestBodyConcurrencyAndLeaseWaits;
var
  First, Second: TRawHTTPConnection;
  Response: TRawHTTPResponse;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Archive: TBytes;
  StartedAt: QWord;
  Hex: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Filled(4096, 7);
  Hex := SHA256Hex(Archive);
  First := TRawHTTPConnection.Create(FPort);
  Second := TRawHTTPConnection.Create(FPort);
  try
    First.SendText('PUT /v1/objects/sha256/' + Hex + ' HTTP/1.1' + #13#10
      + 'Authorization: Bearer ' + FToken + #13#10 + 'Content-Length: 4096'
      + #13#10#13#10 + 'partial');
    Second.SendText('PUT /v1/objects/sha256/' + Hex + ' HTTP/1.1' + #13#10
      + 'Authorization: Bearer ' + FToken + #13#10 + 'Content-Length: 4096'
      + #13#10#13#10 + 'partial');
    Sleep(300);
    Response := Upload(Archive);
    Expect<Integer>(Response.Status).ToBe(503);
    Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
  finally
    First.Free;
    Second.Free;
  end;
  Sleep(300);
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FRoot + '/locks');
  Lease := Coordinator.TryAcquire('registry-publication', 'test holder');
  try
    Expect<Boolean>(Assigned(Lease)).ToBe(True);
    StartedAt := GetTickCount64;
    Response := Publish('waiting-lib', '1.0.0', Archive);
    Expect<Integer>(Response.Status).ToBe(503);
    Expect<Boolean>(GetTickCount64 - StartedAt >= 4900).ToBe(True);
    Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
  finally
    Lease.Free;
    Coordinator.Free;
  end;
  Expect<Integer>(Publish('waiting-lib', '1.0.0', Archive).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestTimedOutCommitLeavesStagingUnchanged;
var
  Archive: TBytes;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Guard: TObject;
  Response: TRawHTTPResponse;
  Hex: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('staged archive');
  Hex := SHA256Hex(Archive);
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FRoot + '/locks');
  Guard := Coordinator.TryAcquireGuard(REGISTRY_INCOMING_LEASE);
  try
    Expect<Boolean>(Assigned(Guard)).ToBe(True);
    Response := Publish('staged-lib', '1.0.0', Archive);
    Expect<Integer>(Response.Status).ToBe(503);
    Expect<Boolean>(FileExists(FRoot + '/incoming/sha256/' + Hex)).ToBe(True);
    Expect<Boolean>(FileExists(FRoot + '/objects/sha256/' + Hex)).ToBe(False);
    Expect<Int64>(Sequence).ToBe(1);
  finally
    Guard.Free;
    Coordinator.Free;
  end;
  Expect<Integer>(Publish('staged-lib', '1.0.0', Archive).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestStorageBudget;
var
  Response: TRawHTTPResponse;
begin
  StartOrigin('', '', RegistryTimestampNow);
  CreateSparseFile(FRoot + '/incoming/sha256/' + StringOfChar('e', 64),
    RegistryIncomingBudgetBytes - 10);
  Response := Upload(Bytes('eleven bytes'));
  Expect<Integer>(Response.Status).ToBe(507);
  Expect<Boolean>(Pos('storage_budget_exceeded', RawHTTPBodyText(Response)) > 0)
    .ToBe(True);
  Expect<Integer>(Upload(Bytes('ten bytes!')).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestAuditRecordsAreSecretFree;
var
  Archive: TBytes;
  Secret, Audits, TokenID: string;
  Files: TStringList;
  Path: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('audited archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Expect<Integer>(Publish('audit-lib', '1.0.0', Archive).Status).ToBe(201);
  { A credential misplaced in a path or query is never recorded. }
  Expect<Integer>(Request('PUT', '/v1/packages/' + FToken + '/1.0.0', FToken,
    nil).Status).ToBe(404);
  Expect<Integer>(Request('PUT', '/v1/objects/sha256/' + SHA256Hex(Archive)
    + '?token=' + FToken, FToken, Archive).Status).ToBe(400);
  Secret := Copy(FToken, Length(PROGRAM_NAME + '_rt1_') + 32 + 2, MaxInt);
  TokenID := Copy(FToken, Length(PROGRAM_NAME + '_rt1_') + 1, 32);
  Audits := AuditText;
  Expect<Boolean>(Pos(FToken, Audits) = 0).ToBe(True);
  Expect<Boolean>(Pos(Secret, Audits) = 0).ToBe(True);
  Expect<Boolean>(Pos(SHA256BytesPrefixed(Bytes(Secret)), Audits) = 0).ToBe(True);
  Expect<Boolean>(Pos('route = "invalid"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('route = "/v1/packages/{name}/{version}"', Audits) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('token_id = "' + TokenID + '"', Audits) > 0).ToBe(True);
  Expect<Boolean>(Pos('sequence = 2', Audits) > 0).ToBe(True);
  { Only the token record holds the hash; no other file holds the secret. }
  Files := TStringList.Create;
  try
    CollectFiles(FRoot, Files);
    for Path in Files do
    begin
      Expect<Boolean>(Pos(Secret, ReadBinaryFile(Path)) = 0).ToBe(True);
      if Pos(TokenID + '.toml', Path) = 0 then
        Expect<Boolean>(Pos(SHA256BytesPrefixed(Bytes(Secret)),
          ReadBinaryFile(Path)) = 0).ToBe(True);
    end;
  finally
    Files.Free;
  end;
end;

procedure TRegistryPublicationContract.TestServerClockBehindHeadRefuses;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
begin
  SetRegistryClockForTesting('2026-08-23T11:00:00Z');
  StartOrigin('', '', '2026-08-23T10:00:00Z', False);
  FToken := IssueToken(['*'], [rtaPublish], 365, '2026-08-01T00:00:00Z');
  Archive := Bytes('clock archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Expect<Integer>(Publish('clock-lib', '1.0.0', Archive).Status).ToBe(201);
  SetRegistryClockForTesting('2026-08-23T10:30:00Z');
  Response := Publish('clock-lib', '2.0.0', Archive);
  Expect<Integer>(Response.Status).ToBe(503);
  Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
  SetRegistryClockForTesting('2026-08-23T12:00:00Z');
  Expect<Integer>(Publish('clock-lib', '2.0.0', Archive).Status).ToBe(201);
  Expect<Boolean>(Pos('published_at = "2026-08-23T12:00:00Z"',
    RawHTTPBodyText(Get('/v1/checkpoints/latest.toml'))) > 0).ToBe(True);
end;

procedure TRegistryPublicationContract.TestFailureBeforePointerKeepsOldHead;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('failing archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  SetRegistryFailurePointForTesting('checkpoint');
  Response := Publish('fail-lib', '1.0.0', Archive);
  SetRegistryFailurePointForTesting('');
  Expect<Integer>(Response.Status).ToBe(503);
  Expect<Int64>(Sequence).ToBe(1);
  { The object moved before activation stays unreferenced and unserved. }
  Expect<Boolean>(FileExists(FRoot + '/objects/sha256/' + SHA256Hex(Archive)))
    .ToBe(True);
  Expect<Integer>(Get('/v1/objects/sha256/' + SHA256Hex(Archive)).Status).ToBe(404);
  Expect<Integer>(Upload(Archive).Status).ToBe(204);
  Response := Publish('fail-lib', '1.0.0', Archive);
  Expect<Integer>(Response.Status).ToBe(201);
  Expect<Int64>(Sequence).ToBe(2);
end;

procedure TRegistryPublicationContract.TestFailureAfterPointerServesNewHead;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('activated archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  SetRegistryFailurePointForTesting('activation');
  Response := Publish('late-lib', '1.0.0', Archive);
  SetRegistryFailurePointForTesting('');
  Expect<Integer>(Response.Status).ToBe(503);
  Expect<Int64>(Sequence).ToBe(2);
  Expect<Boolean>(FileExists(FRoot + '/indexes/sha256/'
    + SHA256Hex(Bytes('late-lib')) + '.toml')).ToBe(False);
  Response := Publish('late-lib', '1.0.0', Archive);
  Expect<Integer>(Response.Status).ToBe(204);
  Expect<Boolean>(RawHTTPHeader(Response, 'Location') <> '').ToBe(True);
  Expect<Boolean>(FileExists(FRoot + '/indexes/sha256/'
    + SHA256Hex(Bytes('late-lib')) + '.toml')).ToBe(True);
end;

procedure TRegistryPublicationContract.TestReadersSeeOldOrNewHead;
var
  Archive: TBytes;
  Publisher: TRequestThread;
  Ready, Release: string;
  StartedAt: QWord;
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
  Signature: TRawHTTPResponse;

  procedure ExpectConsistentHead(const ASequence: Int64);
  var
    CheckpointResponse: TRawHTTPResponse;
    Snapshot: TRawHTTPResponse;
  begin
    CheckpointResponse := Get('/v1/checkpoints/latest.toml');
    Checkpoint := InspectRegistryCheckpoint(CheckpointResponse.Body);
    Expect<Int64>(Checkpoint.Sequence).ToBe(ASequence);
    Signature := Get('/v1/checkpoints/latest.sig.toml');
    Expect<string>(InspectRegistrySignaturePayload(Signature.Body))
      .ToBe(SHA256BytesPrefixed(CheckpointResponse.Body));
    Snapshot := Get('/v1/snapshots/sha256/' + Copy(Checkpoint.Snapshot, 8, 64)
      + '.toml');
    Expect<Integer>(Snapshot.Status).ToBe(200);
    Expect<string>(SHA256BytesPrefixed(Snapshot.Body)).ToBe(Checkpoint.Snapshot);
  end;

begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('reader archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Ready := FScratch + '/barrier-ready';
  Release := FScratch + '/barrier-release';
  SetRegistryPublicationBarrierForTesting(Ready, Release);
  Publisher := TRequestThread.Create(FPort, 'PUT', '/v1/packages/reader-lib/1.0.0',
    FToken, Bytes(RecordText('reader-lib', '1.0.0', Archive, RegistryTimestampNow)));
  try
    StartedAt := GetTickCount64;
    while not FileExists(Ready) do
    begin
      if GetTickCount64 - StartedAt > 10000 then
        raise Exception.Create('publication did not reach its barrier');
      Sleep(10);
    end;
    { The checkpoint for sequence 2 is durable; readers still get sequence 1. }
    Expect<Boolean>(FileExists(FRoot + '/checkpoints/2.toml')).ToBe(True);
    ExpectConsistentHead(1);
    WriteTextFile(Release, 'release');
    Publisher.WaitFor;
    Expect<Integer>(Publisher.Response.Status).ToBe(201);
    ExpectConsistentHead(2);
  finally
    if not FileExists(Release) then WriteTextFile(Release, 'release');
    Publisher.WaitFor;
    Publisher.Free;
  end;
end;

procedure TRegistryPublicationContract.TestPackageListReads;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Body, Snapshot, Cursor, OldSnapshot: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('listed archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Expect<Integer>(Publish('beta-lib', '1.0.0', Archive).Status).ToBe(201);
  OldSnapshot := InspectRegistryCheckpoint(Get('/v1/checkpoints/latest.toml').Body)
    .Snapshot;
  Expect<Integer>(Publish('alpha-lib', '1.10.0', Archive).Status).ToBe(201);
  Expect<Integer>(Publish('alpha-lib', '1.2.0', Archive).Status).ToBe(201);
  Expect<Integer>(Publish('alpha-lib', '1.2.0-rc.1', Archive).Status).ToBe(201);
  Response := Get('/v1/packages?limit=2');
  Expect<Integer>(Response.Status).ToBe(200);
  Body := RawHTTPBodyText(Response);
  Expect<Boolean>(Pos('items = [{ name = "alpha-lib", version = "1.2.0-rc.1"', Body) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('{ name = "alpha-lib", version = "1.2.0", record', Body) > 0)
    .ToBe(True);
  Snapshot := Copy(Body, Pos('snapshot = "', Body) + 12, 71);
  Cursor := Copy(Body, Pos('next_cursor = "', Body) + 15, MaxInt);
  Cursor := Copy(Cursor, 1, Pos('"', Cursor) - 1);
  Expect<Boolean>(Cursor <> '').ToBe(True);
  Response := Get('/v1/packages?limit=2&cursor=' + RegistryQueryEncode(Cursor)
    + '&snapshot=' + RegistryQueryEncode(Snapshot));
  Body := RawHTTPBodyText(Response);
  Expect<Integer>(Response.Status).ToBe(200);
  Expect<Boolean>(Pos('version = "1.10.0"', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('name = "beta-lib"', Body) > 0).ToBe(True);
  Expect<Boolean>(Pos('next_cursor = ""', Body) > 0).ToBe(True);
  { A cursor binds its snapshot. }
  Expect<Integer>(Get('/v1/packages?limit=2&cursor=' + RegistryQueryEncode(Cursor)
    + '&snapshot=' + RegistryQueryEncode(OldSnapshot)).Status).ToBe(409);
  Expect<Integer>(Get('/v1/packages?cursor=' + RegistryQueryEncode(Cursor)).Status)
    .ToBe(400);
  Expect<Integer>(Get('/v1/packages?snapshot=sha256%3A' + StringOfChar('0', 64))
    .Status).ToBe(409);
  Expect<Integer>(Get('/v1/packages?limit=0').Status).ToBe(400);
  Expect<Integer>(Get('/v1/packages?limit=101').Status).ToBe(400);
  Expect<Integer>(Get('/v1/packages?limit=1&limit=2').Status).ToBe(400);
  Expect<Integer>(Get('/v1/packages?unknown=1').Status).ToBe(400);
  Expect<Integer>(Get('/v1/packages?limit=%zz').Status).ToBe(400);
  { An older snapshot in accepted history is still listable. }
  Response := Get('/v1/packages?snapshot=' + RegistryQueryEncode(OldSnapshot));
  Expect<Integer>(Response.Status).ToBe(200);
  Expect<Boolean>(Pos('alpha-lib', RawHTTPBodyText(Response)) = 0).ToBe(True);
  Response := Get('/v1/packages/alpha-lib');
  Expect<Integer>(Response.Status).ToBe(200);
  Expect<Boolean>(Pos('beta-lib', RawHTTPBodyText(Response)) = 0).ToBe(True);
  Expect<Integer>(Get('/v1/packages/missing-lib').Status).ToBe(404);
  Expect<Integer>(Get('/v1/packages/alpha-lib/1.2.0').Status).ToBe(400);
  Response := Get('/v1/packages/alpha-lib/1.2.0?snapshot=' + RegistryQueryEncode(Snapshot));
  Expect<Integer>(Response.Status).ToBe(200);
  Expect<Boolean>(Pos('version = "1.2.0"' + #10, RawHTTPBodyText(Response)) > 0)
    .ToBe(True);
  Expect<Integer>(Get('/v1/packages/alpha-lib/9.0.0?snapshot='
    + RegistryQueryEncode(Snapshot)).Status).ToBe(404);
  { Queries stay limited to rotation and package routes. }
  Expect<Integer>(Get('/v1/capabilities?x=1').Status).ToBe(400);
  Expect<Integer>(Get('/v1/rotations?after=0&limit=50').Status).ToBe(200);
end;

procedure TRegistryPublicationContract.TestAmendedConformanceCorpus;
const
  CORPUS_SNAPSHOT =
    'sha256:8c5f75ccea53bd5af230b1a736ac21ac45b9c0aa805fce5958d2ff8ee27536f5';
var
  Response: TRawHTTPResponse;
  Page, Expected, Snapshot, Cursor: string;
begin
  SetRegistryClockForTesting('2026-01-01T00:00:00Z');
  StartOrigin('https://registry.example.test/lwpt', '/lwpt', '2025-12-31T00:00:00Z',
    False);
  FToken := IssueToken(['*'], [rtaPublish, rtaYank], 365, '2026-01-01T00:00:00Z');
  { archive-object-create and archive-object-existing }
  Expect<Integer>(Upload(HexFixture('objects/7504299b2dd26311dcb09df648b0852e326dec522b055b5b1a75888d8f7b65f9.hex'))
    .Status).ToBe(201);
  Expect<Integer>(Upload(HexFixture('objects/7504299b2dd26311dcb09df648b0852e326dec522b055b5b1a75888d8f7b65f9.hex'))
    .Status).ToBe(204);
  Expect<Integer>(Upload(HexFixture('objects/977b719b477c0ee865cffc04fece1aab3edcdd7924d170a3f9755778688d91d4.hex'))
    .Status).ToBe(201);
  Expect<Integer>(Request('PUT', '/v1/packages/example-lib/1.0.0', FToken,
    Fixture('records/6b464cebeb83b982d076b52f4152b05623fa410fef78c0ce159422097eff4948.toml'))
    .Status).ToBe(201);
  SetRegistryClockForTesting('2026-01-02T00:00:00Z');
  Expect<Integer>(Request('PUT', '/v1/packages/example-lib/1.1.0', FToken,
    Fixture('records/3ed9d3d8a3bff9426cc4dd548336f16692fdc756ffbd577dceeb6305a4cc8903.toml'))
    .Status).ToBe(201);
  { Package listing at the head that holds the corpus's two records. }
  Page := RawHTTPBodyText(Get('/v1/packages'));
  Expected := ReadBinaryFile(FIXTURES + 'pages/packages.toml');
  Expect<string>(Copy(Page, Pos('items = ', Page), MaxInt))
    .ToBe(Copy(Expected, Pos('items = ', Expected), MaxInt));
  { package-list-first-page and package-list-next-page: the corpus cursor is
    bound to the corpus snapshot; this origin binds its own. }
  Snapshot := Copy(Page, Pos('snapshot = "', Page) + 12, 71);
  Expected := ReadBinaryFile(FIXTURES + 'pages/packages-first.toml');
  Expect<Boolean>(Pos('next_cursor = "' + RegistryPackageCursor(
    FStore.Config.Identity, CORPUS_SNAPSHOT, '', 'example-lib', '1.0.0') + '"',
    Expected) > 0).ToBe(True);
  Page := RawHTTPBodyText(Get('/v1/packages?limit=1'));
  Expect<string>(Copy(Page, Pos('items = ', Page), Pos('next_cursor', Page)
    - Pos('items = ', Page))).ToBe(Copy(Expected, Pos('items = ', Expected),
    Pos('next_cursor', Expected) - Pos('items = ', Expected)));
  Cursor := RegistryPackageCursor(FStore.Config.Identity, Snapshot, '',
    'example-lib', '1.0.0');
  Expect<Boolean>(Pos('next_cursor = "' + Cursor + '"', Page) > 0).ToBe(True);
  Response := Get('/v1/packages?limit=1&cursor=' + RegistryQueryEncode(Cursor)
    + '&snapshot=' + RegistryQueryEncode(Snapshot));
  Expect<Integer>(Response.Status).ToBe(200);
  Page := RawHTTPBodyText(Response);
  Expected := ReadBinaryFile(FIXTURES + 'pages/packages-second.toml');
  Expect<string>(Copy(Page, Pos('items = ', Page), MaxInt))
    .ToBe(Copy(Expected, Pos('items = ', Expected), MaxInt));
  { A cursor bound to another snapshot conflicts even at this snapshot. }
  Response := Get('/v1/packages?limit=1&cursor=' + RegistryQueryEncode(
    RegistryPackageCursor(FStore.Config.Identity, CORPUS_SNAPSHOT, '',
    'example-lib', '1.0.0')) + '&snapshot=' + RegistryQueryEncode(Snapshot));
  Expect<Integer>(Response.Status).ToBe(409);
  { package-identity-conflict: genuinely different content. }
  Response := Request('PUT', '/v1/packages/example-lib/1.1.0', FToken,
    Fixture('requests/package-identity-conflict.toml'));
  Expect<Integer>(Response.Status).ToBe(409);
  Expect<string>(WithoutRequestID(RawHTTPBodyText(Response)))
    .ToBe(WithoutRequestID(ReadBinaryFile(FIXTURES + 'errors/identity-conflict.toml')));
  { publish-yanked-record-rejected }
  Response := Request('PUT', '/v1/packages/example-lib/1.1.0', FToken,
    Fixture('records/ac8180e85258202a3fa266525b0936b142e04a08924aa2738f80c608e853892e.toml'));
  Expect<Integer>(Response.Status).ToBe(400);
  Expect<string>(WithoutRequestID(RawHTTPBodyText(Response)))
    .ToBe(WithoutRequestID(ReadBinaryFile(FIXTURES + 'errors/invalid-request.toml')));
  { publish-timestamp-only-retry }
  Response := Request('PUT', '/v1/packages/example-lib/1.1.0', FToken,
    Fixture('records/7802b04acce9fe2768d56d7003ab4d3f4c714f9692513205781a64b6d4e767fa.toml'));
  Expect<Integer>(Response.Status).ToBe(204);
  Expect<string>(RawHTTPHeader(Response, 'Location')).ToBe(FBase
    + '/v1/records/sha256/3ed9d3d8a3bff9426cc4dd548336f16692fdc756ffbd577dceeb6305a4cc8903.toml');
  { object-hash-mismatch }
  Response := Request('PUT', '/v1/objects/sha256/977b719b477c0ee865cffc04fece1aab3edcdd7924d170a3f9755778688d91d4',
    FToken, HexFixture('invalid/977b719b477c0ee865cffc04fece1aab3edcdd7924d170a3f9755778688d91d4.hex'));
  Expect<Integer>(Response.Status).ToBe(422);
  Expect<string>(WithoutRequestID(RawHTTPBodyText(Response)))
    .ToBe(WithoutRequestID(ReadBinaryFile(FIXTURES + 'errors/object-hash-mismatch.toml')));
  SetRegistryClockForTesting('2026-01-03T00:00:00Z');
  { package-archive-missing }
  Response := Request('PUT', '/v1/packages/missing-archive-lib/1.0.0', FToken,
    Fixture('requests/package-missing-archive.toml'));
  Expect<Integer>(Response.Status).ToBe(424);
  Expect<string>(WithoutRequestID(RawHTTPBodyText(Response)))
    .ToBe(WithoutRequestID(ReadBinaryFile(FIXTURES + 'errors/failed-dependency.toml')));
  { publication-authentication-required }
  Response := Request('PUT', '/v1/packages/consumer-lib/1.0.0', '',
    Fixture('records/222cb734f0f27085a49968889da26598be9c63a3ac497ad206403cd912ed0666.toml'));
  Expect<Integer>(Response.Status).ToBe(401);
  Expect<string>(RawHTTPHeader(Response, 'WWW-Authenticate')).ToBe('Bearer');
  Expect<string>(WithoutRequestID(RawHTTPBodyText(Response)))
    .ToBe(WithoutRequestID(ReadBinaryFile(FIXTURES + 'errors/authentication-required.toml')));
  { publish-package-created and publish-package-existing, with the decision-4
    refusal lifted because the corpus record declares dependencies. }
  SetRegistryDependencyRefusalForTesting(False);
  Expect<Integer>(Request('PUT', '/v1/packages/consumer-lib/1.0.0', FToken,
    Fixture('records/222cb734f0f27085a49968889da26598be9c63a3ac497ad206403cd912ed0666.toml'))
    .Status).ToBe(201);
  Expect<Integer>(Request('PUT', '/v1/packages/consumer-lib/1.0.0', FToken,
    Fixture('records/222cb734f0f27085a49968889da26598be9c63a3ac497ad206403cd912ed0666.toml'))
    .Status).ToBe(204);
  SetRegistryDependencyRefusalForTesting(True);
  { yank-package-version and yank-idempotent }
  SetRegistryClockForTesting('2026-01-04T00:00:00Z');
  Response := Request('PUT', '/v1/packages/example-lib/1.1.0/yank', FToken, nil);
  Expect<Integer>(Response.Status).ToBe(201);
  Expect<string>(RawHTTPBodyText(Response)).ToBe(ReadBinaryFile(FIXTURES
    + 'records/ac8180e85258202a3fa266525b0936b142e04a08924aa2738f80c608e853892e.toml'));
  Expect<Integer>(Request('PUT', '/v1/packages/example-lib/1.1.0/yank', FToken,
    nil).Status).ToBe(204);
  { restore-package-version and restore-idempotent }
  SetRegistryClockForTesting('2026-01-05T00:00:00Z');
  Response := Request('DELETE', '/v1/packages/example-lib/1.1.0/yank', FToken, nil);
  Expect<Integer>(Response.Status).ToBe(201);
  Expect<string>(RawHTTPBodyText(Response)).ToBe(ReadBinaryFile(FIXTURES
    + 'records/7802b04acce9fe2768d56d7003ab4d3f4c714f9692513205781a64b6d4e767fa.toml'));
  Expect<Integer>(Request('DELETE', '/v1/packages/example-lib/1.1.0/yank', FToken,
    nil).Status).ToBe(204);
  { cursor-snapshot-conflict }
  Response := Get('/v1/packages?cursor=' + RegistryQueryEncode(
    RegistryPackageCursor(FStore.Config.Identity, CORPUS_SNAPSHOT, '',
    'example-lib', '1.0.0'))
    + '&snapshot=sha256%3Ad2dde0cae212bc793c9a312e55198c65167876aa0722f8cfcbf2f38a5bf5796b');
  Expect<Integer>(Response.Status).ToBe(409);
  Expect<string>(WithoutRequestID(RawHTTPBodyText(Response)))
    .ToBe(WithoutRequestID(ReadBinaryFile(FIXTURES + 'errors/snapshot-conflict.toml')));
end;

procedure TRegistryPublicationContract.TestGuardTimeoutRefusesCommitsWithoutAdoption;
var
  Archive: TBytes;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Guard: TObject;
  Response: TRawHTTPResponse;
  Head: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Archive := Bytes('committed archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Expect<Integer>(Publish('held-lib', '1.0.0', Archive).Status).ToBe(201);
  Head := LatestCheckpointHash;
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FRoot + '/locks');
  Guard := Coordinator.TryAcquireGuard(REGISTRY_INCOMING_LEASE);
  try
    Expect<Boolean>(Assigned(Guard)).ToBe(True);
    { The object is already committed, so this commit needs no adoption. }
    Response := Publish('held-lib', '2.0.0', Archive);
    Expect<Integer>(Response.Status).ToBe(503);
    Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
    Response := Request('PUT', '/v1/packages/held-lib/1.0.0/yank', FToken, nil);
    Expect<Integer>(Response.Status).ToBe(503);
    Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
    Expect<string>(LatestCheckpointHash).ToBe(Head);
    Expect<Int64>(Sequence).ToBe(2);
  finally
    Guard.Free;
    Coordinator.Free;
  end;
  Expect<Integer>(Publish('held-lib', '2.0.0', Archive).Status).ToBe(201);
  Expect<Integer>(Request('PUT', '/v1/packages/held-lib/1.0.0/yank', FToken,
    nil).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.TestExpiredUploadsFreeTheBudgetForAdmission;
var
  Filler: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Filler := FRoot + '/incoming/sha256/' + StringOfChar('d', 64);
  CreateSparseFile(Filler, RegistryIncomingBudgetBytes - 10);
  Expect<Integer>(Upload(Bytes('over the budget')).Status).ToBe(507);
  { Completed uploads older than one hour expire at the next admission,
    without any publication or yank. }
  FileSetDate(Filler, DateTimeToFileDate(Now - 2 / 24));
  Expect<Integer>(Upload(Bytes('over the budget')).Status).ToBe(201);
  Expect<Boolean>(FileExists(Filler)).ToBe(False);
  { Recovery at startup expires them too. }
  CreateSparseFile(Filler, 100);
  FileSetDate(Filler, DateTimeToFileDate(Now - 2 / 24));
  StopOrigin;
  FStore := TLWPTRegistryStore.Create(FRoot);
  Expect<Boolean>(FileExists(Filler)).ToBe(False);
end;

procedure TRegistryPublicationContract.TestDoubleDotNamesRoute;
var
  Archive: TBytes;
  Response: TRawHTTPResponse;
  Snapshot: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Expect<Boolean>(RegistryPackageNameIsCanonical('a..b')).ToBe(True);
  Archive := Bytes('dotted archive');
  Expect<Integer>(Upload(Archive).Status).ToBe(201);
  Expect<Integer>(Publish('a..b', '1.0.0', Archive).Status).ToBe(201);
  Expect<Integer>(Publish('a..b', '1.0.0', Archive).Status).ToBe(204);
  Response := Get('/v1/packages/a..b');
  Expect<Integer>(Response.Status).ToBe(200);
  Expect<Boolean>(Pos('name = "a..b"', RawHTTPBodyText(Response)) > 0).ToBe(True);
  Snapshot := InspectRegistryCheckpoint(Get('/v1/checkpoints/latest.toml').Body)
    .Snapshot;
  Expect<Integer>(Get('/v1/packages/a..b/1.0.0?snapshot='
    + RegistryQueryEncode(Snapshot)).Status).ToBe(200);
  Expect<Integer>(Request('PUT', '/v1/packages/a..b/1.0.0/yank', FToken,
    nil).Status).ToBe(201);
  Expect<Integer>(Request('DELETE', '/v1/packages/a..b/1.0.0/yank', FToken,
    nil).Status).ToBe(201);
  { Dot segments stay refused. }
  Expect<Integer>(Get('/v1/../v1/capabilities').Status).ToBe(400);
  Expect<Integer>(Get('/v1/packages/..').Status).ToBe(400);
  Expect<Integer>(Request('PUT', '/v1/packages/../1.0.0', FToken,
    Bytes('x')).Status).ToBe(404);
end;

procedure TRegistryPublicationContract.TestMalformedMutationsAreAudited;
var
  Connection: TRawHTTPConnection;
  Response: TRawHTTPResponse;
  Audits: TStringList;
  Before: Integer;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('PUT /v1/objects/sha256/' + StringOfChar('a', 64)
      + ' HTTP/1.1' + #13#10 + 'Authorization: Bearer ' + FToken + #13#10
      + ' folded-' + FToken + #13#10 + 'Content-Length: 1' + #13#10#13#10 + 'x');
    Response := Connection.ReadResponse(10000);
  finally
    Connection.Free;
  end;
  Expect<Integer>(Response.Status).ToBe(400);
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('DELETE /v1/packages/x/1.0.0/yank HTTP/1.1' + #13#10
      + 'X-Padding: ' + StringOfChar('p', 40 * 1024) + #13#10#13#10);
    Response := Connection.ReadResponse(10000);
  finally
    Connection.Free;
  end;
  Expect<Integer>(Response.Status).ToBe(431);
  Audits := AuditsWithStatus(400);
  try
    Expect<Integer>(Audits.Count).ToBe(1);
    Expect<Boolean>(Pos('method = "PUT"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('route = "invalid"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('code = "invalid_request"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('request_id = "', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos(FToken, Audits[0]) = 0).ToBe(True);
    Expect<Boolean>(Pos('folded', Audits[0]) = 0).ToBe(True);
  finally
    Audits.Free;
  end;
  Audits := AuditsWithStatus(431);
  try
    Expect<Integer>(Audits.Count).ToBe(1);
    Expect<Boolean>(Pos('method = "DELETE"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('route = "invalid"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('ppppp', Audits[0]) = 0).ToBe(True);
  finally
    Audits.Free;
  end;
  { A malformed read is not a mutation and writes no audit record. }
  Before := Length(AuditText);
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('GET /v1/capabilities HTTP/1.1' + #13#10 + ' folded'
      + #13#10#13#10);
    Expect<Integer>(Connection.ReadResponse(10000).Status).ToBe(400);
  finally
    Connection.Free;
  end;
  Expect<Integer>(Length(AuditText)).ToBe(Before);
end;

procedure TRegistryPublicationContract.TestSlowBodiesHitTheDeadline;
var
  Connection: TRawHTTPConnection;
  Response: TRawHTTPResponse;
  Started: QWord;
begin
  StartOrigin('', '', RegistryTimestampNow);
  SetRegistryBodyDeadlineForTesting(500);
  try
    Connection := TRawHTTPConnection.Create(FPort);
    try
      Connection.SendText('PUT /v1/objects/sha256/' + StringOfChar('b', 64)
        + ' HTTP/1.1' + #13#10 + 'Authorization: Bearer ' + FToken + #13#10
        + 'Content-Length: 4096' + #13#10#13#10 + 'slow');
      Started := GetTickCount64;
      Response := Connection.ReadResponse(10000);
      { The server gives up after the body deadline (500 ms plus one second
        for the started MiB) and closes without an answer. }
      Expect<Integer>(Response.Status).ToBe(0);
      Expect<Boolean>(GetTickCount64 - Started < 5000).ToBe(True);
    finally
      Connection.Free;
    end;
    Started := GetTickCount64;
    while (Pos('code = "request_aborted"', AuditText) = 0)
      and (GetTickCount64 - Started < 5000) do Sleep(20);
    Expect<Boolean>(Pos('code = "request_aborted"', AuditText) > 0).ToBe(True);
    Expect<Boolean>(FileExists(FRoot + '/incoming/sha256/' + StringOfChar('b', 64)))
      .ToBe(False);
    Expect<Integer>(Upload(Bytes('after the slow client')).Status).ToBe(201);
  finally
    SetRegistryBodyDeadlineForTesting(0);
  end;
end;

procedure TRegistryPublicationContract.TestIncompleteMutatingHeadsAreAudited;
var
  Connection: TRawHTTPConnection;
  Audits: TStringList;
  Started: QWord;

  function WaitForAudits(const AStatus, ACount: Integer): TStringList;
  begin
    Started := GetTickCount64;
    repeat
      Result := AuditsWithStatus(AStatus);
      if (Result.Count >= ACount) or (GetTickCount64 - Started > 8000) then Exit;
      Result.Free;
      Sleep(20);
    until False;
  end;

begin
  StartOrigin('', '', RegistryTimestampNow);
  { The peer closes before the blank line that ends the head. }
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('PUT /v1/packages/eof-lib/1.0.0 HTTP/1.1' + #13#10
      + 'Authorization: Bearer ' + FToken + #13#10);
  finally
    Connection.Free;
  end;
  Audits := WaitForAudits(400, 1);
  try
    Expect<Integer>(Audits.Count).ToBe(1);
    Expect<Boolean>(Pos('method = "PUT"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('route = "invalid"', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos('name = ""', Audits[0]) > 0).ToBe(True);
    Expect<Boolean>(Pos(FToken, Audits[0]) = 0).ToBe(True);
    Expect<Boolean>(Pos('eof-lib', Audits[0]) = 0).ToBe(True);
  finally
    Audits.Free;
  end;
  { The head stalls past its deadline. }
  SetRegistryHeaderDeadlineForTesting(500);
  try
    Connection := TRawHTTPConnection.Create(FPort);
    try
      Connection.SendText('DELETE /v1/packages/slow-lib/1.0.0/yank HTTP/1.1'
        + #13#10);
      Audits := WaitForAudits(408, 1);
      try
        Expect<Integer>(Audits.Count).ToBe(1);
        Expect<Boolean>(Pos('method = "DELETE"', Audits[0]) > 0).ToBe(True);
        Expect<Boolean>(Pos('code = "request_timeout"', Audits[0]) > 0)
          .ToBe(True);
      finally
        Audits.Free;
      end;
    finally
      Connection.Free;
    end;
  finally
    SetRegistryHeaderDeadlineForTesting(0);
  end;
  { Exactly once each, and an abandoned read writes nothing. }
  Connection := TRawHTTPConnection.Create(FPort);
  try
    Connection.SendText('GET /v1/capabilities HTTP/1.1' + #13#10);
  finally
    Connection.Free;
  end;
  Sleep(300);
  Audits := AuditsWithStatus(400);
  try
    Expect<Integer>(Audits.Count).ToBe(1);
  finally
    Audits.Free;
  end;
  Audits := AuditsWithStatus(408);
  try
    Expect<Integer>(Audits.Count).ToBe(1);
  finally
    Audits.Free;
  end;
end;

procedure TRegistryPublicationContract.SlowAdmissionHook(const APoint: string);
begin
  { Slow progress while admission owns the publication lease, then another
    operation holding the accounting guard through the final attempt. }
  if APoint = 'expiry-owned' then Sleep(3000)
  else if (APoint = 'admission-final') and Assigned(FFinalHolder) then
  begin
    FFinalHolder.Start;
    RTLEventWaitFor(FFinalHolder.Acquired, 10000);
  end;
end;

procedure TRegistryPublicationContract.TestLongAdmissionStillAnswersRetryably;
var
  Incoming, Publication: TGuardHolder;
  Response: TRawHTTPResponse;
  Started, Elapsed: QWord;
  Filler: string;
begin
  StartOrigin('', '', RegistryTimestampNow);
  Filler := FRoot + '/incoming/sha256/' + StringOfChar('d', 64);
  CreateSparseFile(Filler, RegistryIncomingBudgetBytes - 10);
  FileSetDate(Filler, DateTimeToFileDate(Now - 2 / 24));
  { Each wait stays inside its bound: 1.5 s for the accounting guard, 4 s
    more for the publication lease, 3 s of slow expiry, then a final
    accounting wait that times out. Together they pass the 10-second header
    deadline, and the retryable answer must still arrive. }
  Incoming := TGuardHolder.Create(FRoot + '/locks', REGISTRY_INCOMING_LEASE, 1500);
  Publication := TGuardHolder.Create(FRoot + '/locks', 'registry-publication',
    5500);
  FFinalHolder := TGuardHolder.Create(FRoot + '/locks', REGISTRY_INCOMING_LEASE,
    3000);
  try
    Incoming.Start;
    Publication.Start;
    RTLEventWaitFor(Incoming.Acquired, 5000);
    RTLEventWaitFor(Publication.Acquired, 5000);
    SetRegistryIncomingHookForTesting(SlowAdmissionHook);
    Started := GetTickCount64;
    Response := Upload(Bytes('patient upload'));
    Elapsed := GetTickCount64 - Started;
    Expect<Integer>(Response.Status).ToBe(503);
    Expect<Boolean>(RawHTTPHeader(Response, 'Retry-After') <> '').ToBe(True);
    Expect<Boolean>(Elapsed >= 10000).ToBe(True);
    { The expired upload was removed; only the final wait failed. }
    Expect<Boolean>(FileExists(Filler)).ToBe(False);
  finally
    SetRegistryIncomingHookForTesting(nil);
    if FFinalHolder.Suspended then FFinalHolder.Start;
    FFinalHolder.WaitFor;
    FreeAndNil(FFinalHolder);
    Incoming.WaitFor;
    Publication.WaitFor;
    Incoming.Free;
    Publication.Free;
  end;
  Expect<Integer>(Upload(Bytes('patient upload')).Status).ToBe(201);
end;

procedure TRegistryPublicationContract.SetupTests;
begin
  Test('a token holder uploads and publishes over HTTP', TestPublicationRoundTrip);
  Test('read-only origins and mirrors refuse mutation with 405',
    TestReadOnlyOriginsAndMirrorsRefuseMutation);
  Test('identical, timestamp-only, and lost-response retries answer 204',
    TestIdenticalRetriesSucceed);
  Test('different content for an existing identity answers 409',
    TestConflictingContentIsRejected);
  Test('records are validated for yank state, skew, identity, and archive',
    TestRecordValidation);
  Test('the dependency refusal is a separable check', TestDependencyRefusalIsSeparable);
  Test('yank and restore replace the active record', TestYankAndRestore);
  Test('authentication failures answer one 401 and record their cause',
    TestAuthenticationFailures);
  Test('actions and package patterns scope a token', TestScopes);
  Test('length, framing, and digest limits apply before the body',
    TestLimitsApplyBeforeTheBody);
  Test('per-token and per-peer rate bounds answer 429', TestRateBounds);
  Test('body concurrency and the publication lease wait answer 503',
    TestBodyConcurrencyAndLeaseWaits);
  Test('a commit that times out on the staging guard moves nothing',
    TestTimedOutCommitLeavesStagingUnchanged);
  Test('the unreferenced-upload budget answers 507 before the body',
    TestStorageBudget);
  Test('audit records hold validated metadata and no secrets',
    TestAuditRecordsAreSecretFree);
  Test('a server clock behind the active checkpoint refuses to commit',
    TestServerClockBehindHeadRefuses);
  Test('a failure before the pointer keeps the old head',
    TestFailureBeforePointerKeepsOldHead);
  Test('a failure after the pointer serves the new head',
    TestFailureAfterPointerServesNewHead);
  Test('readers see the old or the new head', TestReadersSeeOldOrNewHead);
  Test('package lists bind cursors to accepted snapshots', TestPackageListReads);
  Test('the amended conformance corpus passes', TestAmendedConformanceCorpus);
  Test('a staging guard timeout refuses commits that need no adoption',
    TestGuardTimeoutRefusesCommitsWithoutAdoption);
  Test('expired uploads free the budget at admission and at recovery',
    TestExpiredUploadsFreeTheBudgetForAdmission);
  Test('names with consecutive dots publish, list, yank, and restore',
    TestDoubleDotNamesRoute);
  Test('malformed mutating requests are audited without their input',
    TestMalformedMutationsAreAudited);
  Test('a slow body is cut off at its deadline', TestSlowBodiesHitTheDeadline);
  Test('incomplete mutating heads are audited once on EOF and deadline',
    TestIncompleteMutatingHeadsAreAudited);
  Test('an admission that waits past the header deadline still answers 503',
    TestLongAdmissionStillAnswersRetryably);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryPublicationContract.Create(
    'registry publication'));
  TestRunnerProgram.Run;
end.
