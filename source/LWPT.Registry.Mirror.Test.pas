program LWPT.Registry.Mirror.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  Sockets,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  Classes,
  DateUtils,
  Generics.Collections,
  Process,
  SysUtils,

  TestingPascalLibrary,
  TOML,

  LWPT.Core,
  LWPT.Registry.Mirror,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  Tests.LwptSubprocess,
  Tests.RegistryProcess,
  Tests.RegistryServer,
  Tests.Scratch;

const
  { Fixed signing times; the registry clock is controlled per test. }
  FixturePublishedAt = '2031-01-01T00:00:00Z';
  FixtureNow = '2031-01-02T00:00:00Z';
  FixtureExpiry = '2031-01-08T00:00:00Z';

type
  { A captured origin renews only when a test asks for it. }
  TCapturedOrigin = class(TLWPTRegistryStore)
  public
    AllowRenewal: Boolean;
    procedure EnsureFreshCheckpoint(const ANow: string;
      AProgress: TSHA256Progress = nil); override;
  end;

  { An in-process origin behind the loopback test server. Overrides replace
    individual responses; sequences serve successive bodies to one target. }
  TOriginHarness = class
  private
    FLock: TRTLCriticalSection;
    FOverrides: TDictionary<string, TBytes>;
    FSequences: TObjectDictionary<string, TList<TBytes>>;
    FStarted: Boolean;
  public
    Root: string;
    Server: TRegistryTestServer;
    Origin: TCapturedOrigin;
    Mirror: TLWPTRegistryMirror;
    constructor Create(const AName: string; const APublishedAt: string = '';
      const AStoreBudget: Int64 = 0; const ASyncBudget: Int64 = 0);
    destructor Destroy; override;
    function Handle(const ATarget: string; out AMediaType: string;
      out ABody: TBytes): Integer;
    function Body(const ATarget: string): TBytes;
    procedure Override(const ATarget: string; const ABody: TBytes);
    procedure Sequence(const ATarget: string; const ABodies: array of TBytes);
    procedure ClearOverrides;
    procedure UseOrigin(AOrigin: TCapturedOrigin);
    procedure Publish(const AName: string; const APublishedAt: string = '';
      const ASize: Integer = 0);
    function Sync: string;
    function Requested(const AFragment: string): Integer;
  end;

  TTransferThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Mirror: TLWPTRegistryMirror;
    API, Error: string;
    Packages: TLWPTRegistryPackageArray;
    FullSync: Boolean;
    constructor Create;
  end;

  TMirrorTransferTests = class(TTestSuite)
  private
    FRoot: string;
    FMirror: TLWPTRegistryMirror;
    FActivationMirror: TLWPTRegistryMirror;
    FActivationEntered: Boolean;
    procedure ExpireBeforeActivation;
    procedure BlockAttemptAndFail;
    procedure FailBeforeActivation;
    function ObjectPath(const APackage: TLWPTRegistryPackage): string;
    procedure PrepareSignedFixture(AServer: TRegistryTestServer;
      const APublishedAt: string; const ACount: Integer;
      out AOrigin: TCapturedOrigin; out ATimedMirror: TLWPTRegistryMirror;
      out ARoutes: TRegistryHTTPRouteArray; out APackages: TLWPTRegistryPackageArray);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure AdmissionArithmetic;
    procedure PairOverlapsAndRetainsCompletedReservation;
    procedure SignedSizeBudgetBlocksSibling;
    procedure DuplicateHashFetchedOnce;
    procedure ConflictingSizesFailBeforeFetch;
    procedure FailedSiblingDrainsAndRetainsVerifiedObject;
    procedure ExpiryDuringTransferPreventsActivation;
    procedure ExpiryBeforeActivationPreventsPublication;
    procedure CLIInterruptionReusesCompletedPair;
    procedure IncompleteClientShutdownIsBounded;
    procedure PoisonedRootKeyRecordIsNotPermanent;
    procedure ForgedRotationStopsFurtherRetrieval;
    procedure SynchronizationBudgetBoundsRequests;
    procedure AmbiguousDiscoveryEndpointsAreRefused;
    procedure AdvancingCheckpointPairIsRetried;
    procedure InconsistentCheckpointPairFailsBounded;
    procedure AttemptRecordingFailurePreservesError;
    procedure SyncBudgetRejectsBeforeTransfer;
    procedure StoreBudgetPrunesUnacceptedCandidates;
    procedure BackwardsRenewalKeepsAcceptedPointer;
    procedure AbandonedRotationCannotContaminateLaterHistory;
    procedure UnsupportedUpstreamsAreRejectedAtConfiguration;
    procedure LocalhostTransportUsesLoopback;
    procedure StaleActivatedMirrorReportsExpiry;
  end;

function Package(const ABytes: TBytes): TLWPTRegistryPackage;
begin
  Result := Default(TLWPTRegistryPackage);
  Result.ArchiveHash := SHA256BytesPrefixed(ABytes);
  Result.ArchiveSize := Length(ABytes);
end;

function Route(const APackage: TLWPTRegistryPackage; const ABody: TBytes): TRegistryHTTPRoute;
begin
  Result := RegistryRoute('/v1/objects/sha256/' + Copy(APackage.ArchiveHash, 8, 64),
    'application/gzip', ABody);
end;

function WaitForCounter(var ACounter: LongInt; const ACount: Integer): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (InterlockedCompareExchange(ACounter, 0, 0) < ACount)
    and (GetTickCount64 - Started < 5000) do Sleep(1);
  Result := InterlockedCompareExchange(ACounter, 0, 0) >= ACount;
end;

function AsText(const ABytes: TBytes): string;
begin
  Result := RegistryBytesText(ABytes);
end;

function ReadFileBytes(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function ServedBytes(AStore: TLWPTRegistryStore; const ATarget: string): TBytes;
var
  Response: TLWPTRegistryHTTPResponse;
  Stream: TStream;
begin
  Response := RegistryHTTPResponse(AStore, 'GET', ATarget);
  if Response.Status <> 200 then
    raise Exception.CreateFmt('HTTP %d for %s', [Response.Status, ATarget]);
  if Response.ResourcePath = '' then Exit(Response.Body);
  Stream := OpenRegistryHTTPResource(Response);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure CopyTree(const ASource, ATarget: string);
var
  Search: TSearchRec;
  Stream: TFileStream;
  Bytes: TBytes;
begin
  ForceDirectories(ATarget);
  if FindFirst(ASource + '/*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') or (Search.Name = 'locks') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        CopyTree(ASource + '/' + Search.Name, ATarget + '/' + Search.Name)
      else
      begin
        Bytes := ReadFileBytes(ASource + '/' + Search.Name);
        Stream := TFileStream.Create(ATarget + '/' + Search.Name, fmCreate);
        try
          if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[0], Length(Bytes));
        finally
          Stream.Free;
        end;
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

constructor TTransferThread.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
end;

procedure TTransferThread.Execute;
begin
  try
    if FullSync then Mirror.Synchronize
    else RegistryMirrorTransferForTesting(Mirror, API, Packages);
  except
    on E: Exception do Error := E.Message;
  end;
end;

procedure TCapturedOrigin.EnsureFreshCheckpoint(const ANow: string;
  AProgress: TSHA256Progress);
begin
  if AllowRenewal then inherited EnsureFreshCheckpoint(ANow, AProgress);
end;

constructor TOriginHarness.Create(const AName, APublishedAt: string;
  const AStoreBudget, ASyncBudget: Int64);
var
  Config: TLWPTRegistryConfig;
  KeyID, PublishedAt: string;
  Parser: TTOMLParser;
  Key: TTOMLNode;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FOverrides := TDictionary<string, TBytes>.Create;
  FSequences := TObjectDictionary<string, TList<TBytes>>.Create([doOwnsValues]);
  Root := CreateScratchRoot(AName);
  PublishedAt := APublishedAt;
  if PublishedAt = '' then PublishedAt := RegistryTimestampNow;
  Server := TRegistryTestServer.Create(nil, True);
  Server.Handler := Handle;
  Config := RegistryConfiguration('', 'http://localhost:' + IntToStr(Server.Port),
    'localhost', Server.Port, '', '');
  Origin := TCapturedOrigin(TCapturedOrigin.Initialize(Root + '/origin', Config, PublishedAt));
  KeyID := InspectRegistryCheckpoint(Origin.LoadResource(Origin.LoadCurrentState.CheckpointPath)).KeyId;
  Parser := TTOMLParser.Create;
  Key := Parser.ParseDocument(AsText(Origin.LoadResource(RegistryKeyStoragePath(KeyID))));
  try
    Config := Origin.Config;
    Config.Role := rrMirror;
    Config.BaseURL := 'http://localhost:8182';
    Config.Port := 8182;
    Config.UpstreamURL := Origin.Config.BaseURL;
    Config.TrustKeyID := KeyID;
    Config.TrustPublicKey := TomlStr(Key, 'public_key', '');
    if AStoreBudget > 0 then Config.StoreBudgetBytes := AStoreBudget;
    if ASyncBudget > 0 then Config.SyncBudgetBytes := ASyncBudget;
  finally
    Key.Free;
    Parser.Free;
  end;
  Mirror := TLWPTRegistryMirror(TLWPTRegistryMirror.Initialize(Root + '/mirror', Config, PublishedAt));
end;

destructor TOriginHarness.Destroy;
begin
  Server.Free;
  Mirror.Free;
  Origin.Free;
  FSequences.Free;
  FOverrides.Free;
  DoneCriticalSection(FLock);
  RecursiveDelete(Root);
  inherited Destroy;
end;

function TOriginHarness.Handle(const ATarget: string; out AMediaType: string;
  out ABody: TBytes): Integer;
var
  Response: TLWPTRegistryHTTPResponse;
  Stream: TStream;
  Bodies: TList<TBytes>;
  Replacement: TBytes;
begin
  EnterCriticalSection(FLock);
  try
    Response := RegistryHTTPResponse(Origin, 'GET', ATarget);
    Result := Response.Status;
    AMediaType := Response.ContentType;
    ABody := Response.Body;
    if FSequences.TryGetValue(ATarget, Bodies) and (Bodies.Count > 0) then
    begin
      ABody := Bodies[0];
      if Bodies.Count > 1 then Bodies.Delete(0);
      Exit(200);
    end;
    if FOverrides.TryGetValue(ATarget, Replacement) then
    begin
      ABody := Replacement;
      Exit(200);
    end;
    if Response.ResourcePath <> '' then
    begin
      Stream := OpenRegistryHTTPResource(Response);
      try
        SetLength(ABody, Stream.Size);
        if Length(ABody) > 0 then Stream.ReadBuffer(ABody[0], Length(ABody));
      finally
        Stream.Free;
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TOriginHarness.Body(const ATarget: string): TBytes;
var
  MediaType: string;
begin
  if Handle(ATarget, MediaType, Result) <> 200 then
    raise Exception.Create('origin fixture has no ' + ATarget);
end;

procedure TOriginHarness.Override(const ATarget: string; const ABody: TBytes);
begin
  EnterCriticalSection(FLock);
  try
    FOverrides.AddOrSetValue(ATarget, ABody);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TOriginHarness.Sequence(const ATarget: string; const ABodies: array of TBytes);
var
  Bodies: TList<TBytes>;
  Index: Integer;
begin
  Bodies := TList<TBytes>.Create;
  for Index := 0 to High(ABodies) do Bodies.Add(ABodies[Index]);
  EnterCriticalSection(FLock);
  try
    FSequences.AddOrSetValue(ATarget, Bodies);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TOriginHarness.ClearOverrides;
begin
  EnterCriticalSection(FLock);
  try
    FOverrides.Clear;
    FSequences.Clear;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TOriginHarness.UseOrigin(AOrigin: TCapturedOrigin);
begin
  EnterCriticalSection(FLock);
  try
    Origin.Free;
    Origin := AOrigin;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TOriginHarness.Publish(const AName, APublishedAt: string;
  const ASize: Integer);
var
  Publication: TLWPTRegistryPublication;
begin
  Publication := Default(TLWPTRegistryPublication);
  Publication.Name := AName;
  Publication.Version := '1.0.0';
  Publication.PublishedAt := APublishedAt;
  if Publication.PublishedAt = '' then Publication.PublishedAt := RegistryTimestampNow;
  if ASize > 0 then
  begin
    SetLength(Publication.Archive, ASize);
    FillChar(Publication.Archive[0], ASize, Ord(AName[1]));
  end
  else Publication.Archive := BytesOf('archive ' + AName);
  EnterCriticalSection(FLock);
  try
    Origin.Publish(Publication);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TOriginHarness.Sync: string;
begin
  { Static routes can be installed until the first synchronization. }
  if not FStarted then
  begin
    Server.Start;
    FStarted := True;
  end;
  Result := 'ok';
  try
    Mirror.Synchronize;
  except
    on E: Exception do Result := E.Message;
  end;
end;

function TOriginHarness.Requested(const AFragment: string): Integer;
var
  Targets: TStringList;
  Target: string;
begin
  Result := 0;
  Targets := Server.RequestedTargets;
  try
    for Target in Targets do
      if Pos(AFragment, Target) > 0 then Inc(Result);
  finally
    Targets.Free;
  end;
end;

procedure TMirrorTransferTests.BeforeEach;
var
  Config: TLWPTRegistryConfig;
begin
  SetRegistryClockForTesting('');
  FRoot := CreateScratchRoot('mirror-transfer');
  Config := RegistryConfiguration('http://localhost:8181', 'http://localhost:8182',
    'localhost', 8182, '', '');
  Config.Role := rrMirror;
  Config.UpstreamURL := Config.Identity;
  { Public protocol corpus pin, not secret material. }
  Config.TrustPublicKey := 'hex:d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
  Config.TrustKeyID := 'ed25519:21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9';
  FMirror := TLWPTRegistryMirror(TLWPTRegistryMirror.Initialize(FRoot, Config, RegistryTimestampNow));
end;

procedure TMirrorTransferTests.AfterEach;
begin
  SetRegistryClockForTesting('');
  FMirror.Free;
  RecursiveDelete(FRoot);
end;

function TMirrorTransferTests.ObjectPath(const APackage: TLWPTRegistryPackage): string;
begin
  Result := FRoot + '/objects/sha256/' + Copy(APackage.ArchiveHash, 8, 64);
end;

procedure TMirrorTransferTests.AdmissionArithmetic;
begin
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(0, RegistryMaximumMirrorArchiveBytes, 0)).ToBe(True);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(RegistryMaximumMirrorArchiveBytes, 0, 1)).ToBe(True);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(RegistryMaximumMirrorArchiveBytes, 1, 1)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(RegistryMaximumMirrorArchiveBytes - 1, 1, 1)).ToBe(True);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(0, 0, 2)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(High(Int64), 1, 0)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(1, High(Int64), 0)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(-1, 1, 0)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(Low(Int64), 1, 0)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(0, -1, 0)).ToBe(False);
end;

procedure TMirrorTransferTests.PairOverlapsAndRetainsCompletedReservation;
var
  Server: TRegistryTestServer;
  Transfer: TTransferThread;
  Routes: TRegistryHTTPRouteArray;
  Gate, FirstGate: PRTLEvent;
  Arrived, Third: LongInt;
  Stats: PRegistryMirrorTransferStats;
  I: Integer;
begin
  Gate := RTLEventCreate;
  FirstGate := RTLEventCreate;
  Server := nil;
  Transfer := TTransferThread.Create;
  Arrived := 0;
  Third := 0;
  try
    SetLength(Routes, 3);
    SetLength(Transfer.Packages, 3);
    for I := 0 to 2 do
    begin
      Transfer.Packages[I] := Package(BytesOf('payload-' + IntToStr(I)));
      Routes[I] := Route(Transfer.Packages[I], BytesOf('payload-' + IntToStr(I)));
      Routes[I].Arrived := @Arrived;
    end;
    Routes[0].Gate := FirstGate;
    Routes[1].Gate := Gate;
    Routes[2].Arrived := @Third;
    Server := TRegistryTestServer.Create(Routes, True);
    Server.Start;
    Stats := RegistryMirrorTransferStatsForTesting(FMirror);
    Transfer.Mirror := FMirror;
    Transfer.API := 'http://localhost:' + IntToStr(Server.Port) + '/v1';
    Transfer.Start;
    Expect<Boolean>(WaitForCounter(Arrived, 2)).ToBe(True);
    { Neither response can finish before both requests reach their barriers. }
    RTLEventSetEvent(FirstGate);
    { Observe the first worker's completion instead of sleeping. Its sibling
      is still blocked, so the pair must not admit the third archive. }
    Expect<Boolean>(WaitForCounter(Stats^.CompletedWorkers, 1)).ToBe(True);
    Expect<Integer>(InterlockedCompareExchange(Third, 0, 0)).ToBe(0);
    Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[0]))).ToBe(False);
    RTLEventSetEvent(Gate);
    Transfer.WaitFor;
    Expect<string>(Transfer.Error).ToBe('');
    Expect<Integer>(Third).ToBe(1);
    Expect<Integer>(Stats^.MaximumWorkers).ToBe(2);
    Expect<Int64>(Stats^.PeakReserved).ToBe(18);
    Expect<Int64>(Stats^.CompletedReserved).ToBe(18);
    for I := 0 to 2 do Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[I]))).ToBe(True);
  finally
    RTLEventSetEvent(Gate);
    RTLEventSetEvent(FirstGate);
    Transfer.Free;
    Server.Free;
    RTLEventDestroy(Gate);
    RTLEventDestroy(FirstGate);
  end;
end;

procedure TMirrorTransferTests.SignedSizeBudgetBlocksSibling;
var
  Server: TRegistryTestServer;
  Transfer: TTransferThread;
  Routes: TRegistryHTTPRouteArray;
  Gate: PRTLEvent;
  First, Second: LongInt;
  Stats: PRegistryMirrorTransferStats;
begin
  Gate := RTLEventCreate;
  Server := nil;
  Transfer := TTransferThread.Create;
  First := 0;
  Second := 0;
  try
    SetLength(Transfer.Packages, 2);
    Transfer.Packages[0] := Package(BytesOf('small'));
    Transfer.Packages[0].ArchiveSize := RegistryMaximumMirrorArchiveBytes;
    Transfer.Packages[1] := Package(BytesOf('sibling'));
    SetLength(Routes, 2);
    Routes[0] := Route(Transfer.Packages[0], BytesOf('small'));
    Routes[0].Gate := Gate;
    Routes[0].Arrived := @First;
    Routes[1] := Route(Transfer.Packages[1], BytesOf('sibling'));
    Routes[1].Arrived := @Second;
    Server := TRegistryTestServer.Create(Routes, True);
    Server.Start;
    Stats := RegistryMirrorTransferStatsForTesting(FMirror);
    Transfer.Mirror := FMirror;
    Transfer.API := 'http://localhost:' + IntToStr(Server.Port) + '/v1';
    Transfer.Start;
    Expect<Boolean>(WaitForCounter(First, 1)).ToBe(True);
    { Admission for this pair is complete once the coordinator closes it. }
    Expect<Boolean>(WaitForCounter(Stats^.AdmissionsClosed, 1)).ToBe(True);
    Expect<Integer>(Stats^.MaximumWorkers).ToBe(1);
    Expect<Integer>(InterlockedCompareExchange(Second, 0, 0)).ToBe(0);
    RTLEventSetEvent(Gate);
    Transfer.WaitFor;
    Expect<Boolean>(Pos('object_hash_mismatch', Transfer.Error) > 0).ToBe(True);
    Expect<Integer>(Second).ToBe(0);
    Expect<Int64>(Stats^.PeakReserved).ToBe(RegistryMaximumMirrorArchiveBytes);
  finally
    RTLEventSetEvent(Gate);
    Transfer.Free;
    Server.Free;
    RTLEventDestroy(Gate);
  end;
end;

procedure TMirrorTransferTests.DuplicateHashFetchedOnce;
var
  Server: TRegistryTestServer;
  Packages: TLWPTRegistryPackageArray;
  Routes: TRegistryHTTPRouteArray;
begin
  SetLength(Packages, 2);
  Packages[0] := Package(BytesOf('shared'));
  Packages[1] := Packages[0];
  SetLength(Routes, 1);
  Routes[0] := Route(Packages[0], BytesOf('shared'));
  Server := TRegistryTestServer.Create(Routes, True);
  try
    Server.Start;
    RegistryMirrorTransferForTesting(FMirror, 'http://localhost:' + IntToStr(Server.Port) + '/v1', Packages);
    Expect<Integer>(Server.RequestCount).ToBe(1);
    RegistryMirrorTransferForTesting(FMirror, 'http://localhost:' + IntToStr(Server.Port) + '/v1', Packages);
    Expect<Integer>(Server.RequestCount).ToBe(1);
  finally
    Server.Free;
  end;
end;

procedure TMirrorTransferTests.ConflictingSizesFailBeforeFetch;
var
  Packages: TLWPTRegistryPackageArray;
  Diagnostic: string;
begin
  SetLength(Packages, 2);
  Packages[0] := Package(BytesOf('same-hash'));
  Packages[1] := Packages[0];
  Inc(Packages[1].ArchiveSize);
  Diagnostic := '';
  try
    RegistryMirrorTransferForTesting(FMirror, 'not-a-valid-network-address', Packages);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('registry_archive_size_conflict', Diagnostic) > 0).ToBe(True);
end;

procedure TMirrorTransferTests.FailedSiblingDrainsAndRetainsVerifiedObject;
var
  Server: TRegistryTestServer;
  Transfer: TTransferThread;
  Routes: TRegistryHTTPRouteArray;
  I: Integer;
begin
  Transfer := TTransferThread.Create;
  Server := nil;
  try
    SetLength(Transfer.Packages, 3);
    SetLength(Routes, 3);
    for I := 0 to 2 do
    begin
      Transfer.Packages[I] := Package(BytesOf('data-' + IntToStr(I)));
      Routes[I] := Route(Transfer.Packages[I], BytesOf('data-' + IntToStr(I)));
    end;
    Routes[0].Body := BytesOf('tamper');
    Server := TRegistryTestServer.Create(Routes, True);
    Server.Start;
    Transfer.Mirror := FMirror;
    Transfer.API := 'http://localhost:' + IntToStr(Server.Port) + '/v1';
    Transfer.Start;
    Transfer.WaitFor;
    Expect<Boolean>(Pos('object_hash_mismatch', Transfer.Error) > 0).ToBe(True);
    Expect<Integer>(Server.RequestCount).ToBe(2);
    Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[0]))).ToBe(False);
    Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[1]))).ToBe(True);
    Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[2]))).ToBe(False);
    { An unavailable sibling origin object must not be requested on retry. }
    Server.Free;
    Server := nil;
    Routes[0].Body := BytesOf('data-0');
    Routes[1].Status := 500;
    Server := TRegistryTestServer.Create(Routes, True);
    Server.Start;
    RegistryMirrorTransferForTesting(FMirror, 'http://localhost:' + IntToStr(Server.Port) + '/v1', Transfer.Packages);
    Expect<Integer>(Server.RequestCount).ToBe(2);
    for I := 0 to 2 do Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[I]))).ToBe(True);
  finally
    Transfer.Free;
    Server.Free;
  end;
end;

procedure TMirrorTransferTests.PrepareSignedFixture(AServer: TRegistryTestServer;
  const APublishedAt: string; const ACount: Integer;
  out AOrigin: TCapturedOrigin; out ATimedMirror: TLWPTRegistryMirror;
  out ARoutes: TRegistryHTTPRouteArray; out APackages: TLWPTRegistryPackageArray);
var
  Config: TLWPTRegistryConfig;
  Publication: TLWPTRegistryPublication;
  State: TLWPTRegistryState;
  Hint: TLWPTUntrustedRegistryCheckpoint;
  Base, KeyText, RecordHash: string;
  Parser: TTOMLParser;
  Key: TTOMLNode;
  KeyBytes: TBytes;
  Records: TStringList;
  I: Integer;

  procedure Add(const APath, AKind: string; const ABytes: TBytes);
  var
    Index: Integer;
  begin
    Index := Length(ARoutes);
    SetLength(ARoutes, Index + 1);
    ARoutes[Index] := RegistryRoute(APath, 'application/vnd.' + PROGRAM_NAME
      + '.registry-' + AKind + '+toml', ABytes);
  end;

  procedure AddHashed(const ADirectory, AKind: string);
  var
    Search: TSearchRec;
    Relative: string;
  begin
    if FindFirst(AOrigin.Root + '/' + ADirectory + '/*.toml', faAnyFile, Search) <> 0 then Exit;
    try
      repeat
        if (Search.Attr and faDirectory) <> 0 then Continue;
        Relative := ADirectory + '/' + Search.Name;
        Add('/v1/' + Relative, AKind, AOrigin.LoadResource(Relative));
        if AKind = 'package' then Records.Add(Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  end;
begin
  AOrigin := nil;
  ATimedMirror := nil;
  Parser := TTOMLParser.Create;
  Records := TStringList.Create;
  try
    Base := 'http://localhost:' + IntToStr(AServer.Port);
    Config := RegistryConfiguration('', Base, 'localhost', AServer.Port, '', '');
    AOrigin := TCapturedOrigin(TCapturedOrigin.Initialize(FRoot + '/timed-origin', Config, APublishedAt));
    Config := AOrigin.Config;
    for I := 0 to ACount - 1 do
    begin
      Publication := Default(TLWPTRegistryPublication);
      Publication.Name := 'package-' + IntToStr(I);
      Publication.Version := '1.0.0';
      Publication.PublishedAt := APublishedAt;
      Publication.Archive := BytesOf('signed archive-' + IntToStr(I));
      AOrigin.Publish(Publication);
    end;
    State := AOrigin.LoadCurrentState;
    Hint := InspectRegistryCheckpoint(AOrigin.LoadResource(State.CheckpointPath));
    KeyBytes := AOrigin.LoadResource(RegistryKeyStoragePath(Hint.KeyId));
    SetString(KeyText, PAnsiChar(@KeyBytes[0]), Length(KeyBytes));
    Key := Parser.ParseDocument(KeyText);
    try
      Config.Role := rrMirror;
      Config.BaseURL := 'http://localhost:8182';
      Config.Port := 8182;
      Config.UpstreamURL := Base;
      Config.TrustKeyID := Hint.KeyId;
      Config.TrustPublicKey := TomlStr(Key, 'public_key', '');
    finally
      Key.Free;
    end;
    ATimedMirror := TLWPTRegistryMirror(TLWPTRegistryMirror.Initialize(FRoot + '/timed-mirror', Config, APublishedAt));
    Add('/.well-known/' + PROGRAM_NAME + '-registry', 'discovery',
      RegistryHTTPResponse(AOrigin, 'GET', '/.well-known/' + PROGRAM_NAME + '-registry').Body);
    Add('/v1/capabilities', 'capabilities', RegistryHTTPResponse(AOrigin, 'GET', '/v1/capabilities').Body);
    Add('/v1/checkpoints/latest.toml', 'checkpoint', AOrigin.LoadResource(State.CheckpointPath));
    Add('/v1/checkpoints/latest.sig.toml', 'signature', AOrigin.LoadResource(State.SignaturePath));
    Add('/v1/keys/' + Hint.KeyId + '.toml', 'key', KeyBytes);
    AddHashed('snapshots/sha256', 'snapshot');
    AddHashed('records/sha256', 'package');
    Records.Sort;
    SetLength(APackages, Records.Count);
    for I := 0 to Records.Count - 1 do
    begin
      KeyBytes := AOrigin.LoadResource('records/sha256/' + Records[I]);
      SetString(KeyText, PAnsiChar(@KeyBytes[0]), Length(KeyBytes));
      RecordHash := 'sha256:' + Copy(Records[I], 1, 64);
      APackages[I] := ParseRegistryPackage(KeyText, RecordHash, Config.Identity);
      SetLength(ARoutes, Length(ARoutes) + 1);
      ARoutes[High(ARoutes)] := Route(APackages[I], AOrigin.LoadResource('objects/sha256/'
        + Copy(APackages[I].ArchiveHash, 8, 64)));
    end;
  finally
    Records.Free;
    Parser.Free;
  end;
end;

procedure TMirrorTransferTests.ExpiryDuringTransferPreventsActivation;
var
  Server: TRegistryTestServer;
  Origin: TCapturedOrigin;
  TimedMirror: TLWPTRegistryMirror;
  Transfer: TTransferThread;
  Routes: TRegistryHTTPRouteArray;
  Packages: TLWPTRegistryPackageArray;
  Gate: PRTLEvent;
  Arrived: LongInt;
begin
  Server := TRegistryTestServer.Create(nil, True);
  Origin := nil;
  TimedMirror := nil;
  Transfer := nil;
  Gate := RTLEventCreate;
  Arrived := 0;
  try
    SetRegistryClockForTesting(FixtureNow);
    PrepareSignedFixture(Server, FixturePublishedAt, 1, Origin, TimedMirror, Routes, Packages);
    Routes[High(Routes)].Gate := Gate;
    Routes[High(Routes)].GateTimeoutMilliseconds := 15000;
    Routes[High(Routes)].Arrived := @Arrived;
    Server.SetRoutes(Routes);
    Server.Start;
    Transfer := TTransferThread.Create;
    Transfer.Mirror := TimedMirror;
    Transfer.FullSync := True;
    Transfer.Start;
    if not WaitForCounter(Arrived, 1) then
    begin
      Transfer.WaitFor;
      raise Exception.Create('expiry fixture never reached archive request: ' + Transfer.Error);
    end;
    { The controlled clock reaches expiry while the archive is in flight. }
    SetRegistryClockForTesting(FixtureExpiry);
    RTLEventSetEvent(Gate);
    Transfer.WaitFor;
    Expect<Boolean>(Pos('checkpoint_expired:', Transfer.Error) = 1).ToBe(True);
    Expect<Boolean>(FileExists(TimedMirror.Root + '/state/current.toml')).ToBe(False);
    Expect<Boolean>(FileExists(TimedMirror.Root + '/objects/sha256/'
      + Copy(Packages[0].ArchiveHash, 8, 64))).ToBe(True);
  finally
    RTLEventSetEvent(Gate);
    Transfer.Free;
    Server.Free;
    TimedMirror.Free;
    Origin.Free;
    RTLEventDestroy(Gate);
  end;
end;

procedure TMirrorTransferTests.ExpireBeforeActivation;
begin
  FActivationEntered := True;
  SetRegistryClockForTesting(FixtureExpiry);
end;

procedure TMirrorTransferTests.ExpiryBeforeActivationPreventsPublication;
var
  Server: TRegistryTestServer;
  Origin: TCapturedOrigin;
  TimedMirror: TLWPTRegistryMirror;
  Routes: TRegistryHTTPRouteArray;
  Packages: TLWPTRegistryPackageArray;
  Failure: string;
begin
  Server := TRegistryTestServer.Create(nil, True);
  Origin := nil;
  TimedMirror := nil;
  try
    SetRegistryClockForTesting(FixtureNow);
    PrepareSignedFixture(Server, FixturePublishedAt, 1, Origin, TimedMirror, Routes, Packages);
    Server.SetRoutes(Routes);
    Server.Start;
    FActivationEntered := False;
    { Expiry occurs after verification and storage, before the pointer. }
    RegistryMirrorBeforeActivateForTesting(TimedMirror, ExpireBeforeActivation);
    Failure := '';
    try
      TimedMirror.Synchronize;
    except
      on E: Exception do Failure := E.Message;
    end;
    Expect<Boolean>(FActivationEntered).ToBe(True);
    Expect<Boolean>(Pos('checkpoint_expired:', Failure) = 1).ToBe(True);
    Expect<Boolean>(FileExists(TimedMirror.Root + '/state/current.toml')).ToBe(False);
    Expect<Boolean>(FileExists(TimedMirror.Root + '/objects/sha256/'
      + Copy(Packages[0].ArchiveHash, 8, 64))).ToBe(True);
  finally
    Server.Free;
    TimedMirror.Free;
    Origin.Free;
  end;
end;

procedure TMirrorTransferTests.CLIInterruptionReusesCompletedPair;
var
  Server: TRegistryTestServer;
  Origin: TCapturedOrigin;
  Mirror: TLWPTRegistryMirror;
  Routes: TRegistryHTTPRouteArray;
  Packages: TLWPTRegistryPackageArray;
  Gate: PRTLEvent;
  Arrived: LongInt;
  Child: TProcess;
  Stopped: TRegistryStopResult;
  Run: TLwptResult;
  CountBefore: Integer;
  I: Integer;
begin
  Server := TRegistryTestServer.Create(nil, True);
  Origin := nil;
  Mirror := nil;
  Child := nil;
  Gate := RTLEventCreate;
  Arrived := 0;
  try
    PrepareSignedFixture(Server, RegistryTimestampNow, 3, Origin, Mirror, Routes, Packages);
    Routes[High(Routes)].Gate := Gate;
    Routes[High(Routes)].GateRequestLimit := 1;
    Routes[High(Routes)].GateTimeoutMilliseconds := 15000;
    Routes[High(Routes)].Arrived := @Arrived;
    Server.SetRoutes(Routes);
    Server.Start;
    Child := TProcess.Create(nil);
    Child.Executable := LwptBinaryPath;
    Child.Options := [poUsePipes];
    Child.Parameters.Add('registry');
    Child.Parameters.Add('sync');
    Child.Parameters.Add('--data-dir');
    Child.Parameters.Add(Mirror.Root);
    Child.Execute;
    if not WaitForCounter(Arrived, 1) then
      raise Exception.Create('interruption fixture never reached third archive: '
        + DrainAvailableStream(Child.Stderr, 4096));
    for I := 0 to 1 do
      Expect<Boolean>(FileExists(Mirror.Root + '/objects/sha256/'
        + Copy(Packages[I].ArchiveHash, 8, 64))).ToBe(True);
    Expect<Boolean>(FileExists(Mirror.Root + '/state/current.toml')).ToBe(False);
    Stopped := StopRegistryProcess(Child, 0, 2000);
    Expect<Boolean>(Stopped.Stopped).ToBe(True);
    RTLEventSetEvent(Gate);
    { The killed attempt recorded its identifier and start state; the next
      process to open the mirror reports it as abandoned. }
    Run := RunLwpt(['registry', 'verify', '--data-dir', Mirror.Root]);
    DumpRunFailure('report abandoned attempt', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('outcome = "abandoned"', Run.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('attempt_id = "', Run.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('freshness = "uninitialized"', Run.Stdout) > 0).ToBe(True);
    { Completed objects are also removed at the origin; retry must use CAS. }
    for I := 0 to 1 do
      Expect<Boolean>(DeleteFile(Origin.Root + '/objects/sha256/'
        + Copy(Packages[I].ArchiveHash, 8, 64))).ToBe(True);
    CountBefore := Server.RequestCount;
    Run := RunLwpt(['registry', 'sync', '--data-dir', Mirror.Root]);
    DumpRunFailure('resume interrupted archive pair', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(Mirror.Root + '/state/current.toml')).ToBe(True);
    { All proof metadata was retained before the first attempt; only five
      control resources and the interrupted third archive are fetched again. }
    Expect<Integer>(Server.RequestCount - CountBefore).ToBe(6);
    Expect<Integer>(Arrived).ToBe(2);
    Run := RunLwpt(['registry', 'verify', '--data-dir', Mirror.Root]);
    Expect<Boolean>(Pos('outcome = "activated"', Run.Stdout) > 0).ToBe(True);
  finally
    StopRegistryProcess(Child, 0, 2000);
    RTLEventSetEvent(Gate);
    Server.Free;
    Mirror.Free;
    Origin.Free;
    RTLEventDestroy(Gate);
  end;
end;

procedure TMirrorTransferTests.PoisonedRootKeyRecordIsNotPermanent;
var
  Harness: TOriginHarness;
  KeyTarget, Honest: string;
begin
  Harness := TOriginHarness.Create('mirror-key-poison');
  try
    Harness.Publish('one');
    KeyTarget := '/v1/keys/' + Harness.Mirror.Config.TrustKeyID + '.toml';
    Honest := AsText(Harness.Body(KeyTarget));
    { Only the unsigned effective sequence differs. }
    Harness.Override(KeyTarget, BytesOf(StringReplace(Honest,
      'valid_from_sequence = 1', 'valid_from_sequence = 2', [])));
    Expect<string>(Harness.Sync).ToBe('ok');
    Harness.ClearOverrides;
    Harness.Publish('two');
    Expect<string>(Harness.Sync).ToBe('ok');
    { The mirror serves the record bound to its newest accepted state. }
    Expect<string>(AsText(ServedBytes(Harness.Mirror, KeyTarget))).ToBe(Honest);
    Expect<Boolean>(Pos('sequence = 3', Harness.Mirror.VerifyMirror) > 0).ToBe(True);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.ForgedRotationStopsFurtherRetrieval;
var
  Harness: TOriginHarness;
  Key, Signature, Outcome: string;
  Index: Integer;
begin
  Harness := TOriginHarness.Create('mirror-forged-rotation');
  try
    for Index := 1 to 3 do
    begin
      Key := InspectRegistryCheckpoint(Harness.Body('/v1/checkpoints/latest.toml')).KeyId;
      Harness.Origin.RotateKey(Key, RegistryTimestampNow);
    end;
    { A structurally valid but forged old-key signature on the first step. }
    Signature := AsText(Harness.Body('/v1/rotations/2.old.sig.toml'));
    Signature := Copy(Signature, 1, Pos('signature = "hex:', Signature) + 16)
      + StringOfChar('0', 128) + '"' + #10;
    Harness.Override('/v1/rotations/2.old.sig.toml', BytesOf(Signature));
    Outcome := Harness.Sync;
    Expect<Boolean>(Pos('signature_invalid:', Outcome) = 1).ToBe(True);
    Expect<Integer>(Harness.Requested('/v1/rotations/2.')).ToBe(3);
    Expect<Integer>(Harness.Requested('/v1/rotations/3')).ToBe(0);
    Expect<Integer>(Harness.Requested('/v1/rotations/4')).ToBe(0);
    { Only the pinned root key record was requested. }
    Expect<Integer>(Harness.Requested('/v1/keys/')).ToBe(1);
    Expect<Boolean>(FileExists(Harness.Mirror.Root + '/state/current.toml')).ToBe(False);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.SynchronizationBudgetBoundsRequests;
var
  Harness: TOriginHarness;
  Gate: PRTLEvent;
  Routes: TRegistryHTTPRouteArray;
  Started, Elapsed: QWord;
  Outcome: string;
begin
  Harness := TOriginHarness.Create('mirror-sync-budget');
  Gate := RTLEventCreate;
  try
    { The capabilities response stalls far beyond the synchronization budget. }
    SetLength(Routes, 1);
    Routes[0] := RegistryRoute('/v1/capabilities', 'application/vnd.' + PROGRAM_NAME
      + '.registry-capabilities+toml', Harness.Body('/v1/capabilities'));
    Routes[0].Gate := Gate;
    Routes[0].GateTimeoutMilliseconds := 30000;
    Harness.Server.SetRoutes(Routes);
    RegistryMirrorSynchronizationBudgetForTesting(Harness.Mirror, 500);
    Started := GetTickCount64;
    Outcome := Harness.Sync;
    Elapsed := GetTickCount64 - Started;
    Expect<Boolean>((Pos('registry_transport_failed:', Outcome) = 1)
      or (Pos('mirror_sync_deadline_exceeded:', Outcome) = 1)).ToBe(True);
    { Bounded by the 500 ms budget, not the 120 s per-request deadline. }
    Expect<Boolean>(Elapsed < 20000).ToBe(True);
    Expect<Integer>(Harness.Requested('/v1/checkpoints/')).ToBe(0);
  finally
    RTLEventSetEvent(Gate);
    Harness.Free;
    RTLEventDestroy(Gate);
  end;
end;

procedure TMirrorTransferTests.AmbiguousDiscoveryEndpointsAreRefused;
const
  Replacements: array[0..2] of string = ('/..%2Fadmin/capabilities',
    '/v1%2Fcapabilities', '/v1/%2E%2E/capabilities');
var
  Harness: TOriginHarness;
  Discovery, Replacement, Outcome: string;
begin
  for Replacement in Replacements do
  begin
    Harness := TOriginHarness.Create('mirror-encoded-scope');
    try
      Discovery := AsText(Harness.Body('/.well-known/' + PROGRAM_NAME + '-registry'));
      Harness.Override('/.well-known/' + PROGRAM_NAME + '-registry', BytesOf(StringReplace(
        Discovery, '/v1/capabilities', Replacement, [])));
      Outcome := Harness.Sync;
      Expect<Boolean>(Pos('registry_discovery_scope_mismatch:', Outcome)
        + Pos('invalid_registry_discovery_uri:', Outcome) = 1).ToBe(True);
      Expect<Integer>(Harness.Server.RequestCount).ToBe(1);
    finally
      Harness.Free;
    end;
  end;
end;

procedure TMirrorTransferTests.AdvancingCheckpointPairIsRetried;
var
  Harness: TOriginHarness;
  Stale: TBytes;
begin
  Harness := TOriginHarness.Create('mirror-checkpoint-race');
  try
    Stale := Harness.Body('/v1/checkpoints/latest.toml');
    Harness.Publish('published-between-reads');
    { The first checkpoint read predates publication; its signature read and
      every later checkpoint read observe the new head. }
    Harness.Sequence('/v1/checkpoints/latest.toml',
      [Stale, Harness.Body('/v1/checkpoints/latest.toml')]);
    Expect<string>(Harness.Sync).ToBe('ok');
    Expect<Integer>(Harness.Requested('/v1/checkpoints/latest.toml')).ToBe(2);
    Expect<Integer>(Harness.Requested('/v1/checkpoints/latest.sig.toml')).ToBe(2);
    Expect<Boolean>(Pos('sequence = 2', Harness.Mirror.VerifyMirror) > 0).ToBe(True);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.InconsistentCheckpointPairFailsBounded;
var
  Harness: TOriginHarness;
  Current: TBytes;
  Outcome: string;
begin
  Harness := TOriginHarness.Create('mirror-checkpoint-mismatch');
  try
    Current := Harness.Body('/v1/checkpoints/latest.toml');
    Harness.Publish('other-head');
    { A stable checkpoint paired with another head's signature is invalid. }
    Harness.Override('/v1/checkpoints/latest.toml', Current);
    Outcome := Harness.Sync;
    Expect<Boolean>(Pos('signature_payload_mismatch:', Outcome) = 1).ToBe(True);
    Expect<Integer>(Harness.Requested('/v1/checkpoints/latest.toml')).ToBe(2);
    Expect<Integer>(Harness.Requested('/v1/checkpoints/latest.sig.toml')).ToBe(1);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.BlockAttemptAndFail;
begin
  DeleteFile(FActivationMirror.Root + '/state/sync-attempt.toml');
  ForceDirectories(FActivationMirror.Root + '/state/sync-attempt.toml');
  raise ELWPTRegistryError.CreateStable('primary_failure', 'activation failed first');
end;

procedure TMirrorTransferTests.AttemptRecordingFailurePreservesError;
var
  Harness: TOriginHarness;
begin
  Harness := TOriginHarness.Create('mirror-attempt-record');
  try
    FActivationMirror := Harness.Mirror;
    RegistryMirrorBeforeActivateForTesting(Harness.Mirror, BlockAttemptAndFail);
    Expect<string>(Harness.Sync).ToBe('primary_failure: activation failed first');
    Expect<Boolean>(FileExists(Harness.Mirror.Root + '/state/current.toml')).ToBe(False);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.SyncBudgetRejectsBeforeTransfer;
var
  Harness: TOriginHarness;
  Outcome: string;
begin
  Harness := TOriginHarness.Create('mirror-sync-bytes', '',
    Int64(64) * 1024 * 1024, RegistryMinimumMirrorSyncBytes);
  try
    Harness.Publish('large', '', 2 * 1024 * 1024);
    Outcome := Harness.Sync;
    Expect<Boolean>(Pos('mirror_sync_budget_exceeded:', Outcome) = 1).ToBe(True);
    Expect<Integer>(Harness.Requested('/v1/objects/')).ToBe(0);
    Expect<Boolean>(FileExists(Harness.Mirror.Root + '/state/current.toml')).ToBe(False);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.StoreBudgetPrunesUnacceptedCandidates;
var
  Harness: TOriginHarness;
  Residue: TBytes;
  ResiduePath, Outcome: string;
  Stream: TFileStream;
begin
  { Store budget 4 MiB with a 2 MiB attempt budget: an attempt only fits
    while less than 2 MiB is already used. }
  Harness := TOriginHarness.Create('mirror-store-bytes', '',
    Int64(4) * 1024 * 1024, Int64(2) * 1024 * 1024);
  try
    Harness.Publish('small');
    Expect<string>(Harness.Sync).ToBe('ok');
    { An abandoned candidate archive of 3 MiB is not accepted state. }
    SetLength(Residue, 3 * 1024 * 1024);
    FillChar(Residue[0], Length(Residue), $41);
    ResiduePath := Harness.Mirror.Root + '/objects/sha256/' + SHA256Hex(Residue);
    Stream := TFileStream.Create(ResiduePath, fmCreate);
    try
      Stream.WriteBuffer(Residue[0], Length(Residue));
    finally
      Stream.Free;
    end;
    Harness.Publish('next');
    Expect<string>(Harness.Sync).ToBe('ok');
    Expect<Boolean>(FileExists(ResiduePath)).ToBe(False);
    { Accepted content alone can also exhaust the store budget. }
    Harness.Publish('too-large', '', 1536 * 1024);
    Harness.Publish('also-large', '', 1536 * 1024);
    Outcome := Harness.Sync;
    Expect<Boolean>((Pos('mirror_sync_budget_exceeded:', Outcome) = 1)
      or (Pos('mirror_store_budget_exceeded:', Outcome) = 1)).ToBe(True);
    Expect<Integer>(Harness.Requested('/v1/objects/sha256/' + SHA256Hex(
      BytesOf(StringOfChar('t', 1536 * 1024))))).ToBe(0);
    Expect<Boolean>(Pos('sequence = 3', Harness.Mirror.VerifyMirror) > 0).ToBe(True);
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.BackwardsRenewalKeepsAcceptedPointer;
var
  Harness: TOriginHarness;
  Checkpoint, Signature: TBytes;
  PointerBefore, Outcome: string;
begin
  SetRegistryClockForTesting(FixtureNow);
  Harness := TOriginHarness.Create('mirror-renewal-rollback', FixturePublishedAt);
  try
    Checkpoint := Harness.Body('/v1/checkpoints/latest.toml');
    Signature := Harness.Body('/v1/checkpoints/latest.sig.toml');
    SetRegistryClockForTesting('2031-01-07T12:00:00Z');
    Harness.Origin.AllowRenewal := True;
    Harness.Origin.EnsureFreshCheckpoint(RegistryTimestampNow);
    Harness.Origin.AllowRenewal := False;
    Expect<string>(Harness.Sync).ToBe('ok');
    PointerBefore := AsText(ReadFileBytes(Harness.Mirror.Root + '/state/current.toml'));
    { Replay the older, still unexpired checkpoint of the same sequence. }
    Harness.Override('/v1/checkpoints/latest.toml', Checkpoint);
    Harness.Override('/v1/checkpoints/latest.sig.toml', Signature);
    Outcome := Harness.Sync;
    Expect<Boolean>(Pos('checkpoint_renewal_rollback:', Outcome) = 1).ToBe(True);
    Expect<string>(AsText(ReadFileBytes(Harness.Mirror.Root + '/state/current.toml')))
      .ToBe(PointerBefore);
    { An exact replay of the accepted renewal remains idempotent. }
    Harness.ClearOverrides;
    Expect<string>(Harness.Sync).ToBe('ok');
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.FailBeforeActivation;
begin
  raise ELWPTRegistryError.CreateStable('interrupted_attempt', 'stopped before activation');
end;

procedure TMirrorTransferTests.AbandonedRotationCannotContaminateLaterHistory;
var
  Harness: TOriginHarness;
  Alternative: TCapturedOrigin;
  View: TLWPTRegistryReadView;
begin
  Harness := TOriginHarness.Create('mirror-abandoned-rotation');
  Alternative := nil;
  try
    Harness.Publish('one');
    Expect<string>(Harness.Sync).ToBe('ok');
    { A second history extends the same accepted head without rotating. }
    CopyTree(Harness.Origin.Root, Harness.Root + '/alternative');
    Harness.Origin.RotateKey(Harness.Mirror.Config.TrustKeyID, RegistryTimestampNow);
    RegistryMirrorBeforeActivateForTesting(Harness.Mirror, FailBeforeActivation);
    Expect<Boolean>(Pos('interrupted_attempt:', Harness.Sync) = 1).ToBe(True);
    RegistryMirrorBeforeActivateForTesting(Harness.Mirror, nil);
    Alternative := TCapturedOrigin(TCapturedOrigin.Create(Harness.Root + '/alternative'));
    Harness.UseOrigin(Alternative);
    Alternative := nil;
    Harness.Publish('two');
    Harness.Publish('three');
    Expect<string>(Harness.Sync).ToBe('ok');
    View := Harness.Mirror.CaptureReadView;
    try
      Expect<Integer>(View.RotationSequences.Count).ToBe(0);
      Expect<Int64>(View.State.Sequence).ToBe(4);
    finally
      View.Free;
    end;
    Expect<Boolean>(Pos('sequence = 4', Harness.Mirror.VerifyMirror) > 0).ToBe(True);
    Expect<Integer>(RegistryHTTPResponse(Harness.Mirror, 'GET', '/v1/rotations/3.toml').Status).ToBe(404);
    Expect<Integer>(RegistryHTTPResponse(Harness.Mirror, 'GET', '/v1/checkpoints/latest.toml').Status).ToBe(200);
  finally
    Alternative.Free;
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.UnsupportedUpstreamsAreRejectedAtConfiguration;
var
  Config: TLWPTRegistryConfig;
  Diagnostic: string;
begin
  Config := FMirror.Config;
  Config.UpstreamURL := 'https://[2001:db8::1]:8443';
  Diagnostic := '';
  try
    ValidateMirrorConfiguration(Config);
  except
    on E: ELWPTRegistryError do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_mirror_configuration:', Diagnostic) = 1).ToBe(True);
  Expect<Boolean>(Pos('IPv6', Diagnostic) > 0).ToBe(True);
  Config.UpstreamURL := 'https://registry.example.test';
  ValidateMirrorConfiguration(Config);
end;

procedure TMirrorTransferTests.LocalhostTransportUsesLoopback;
var
  Harness: TOriginHarness;
begin
  Expect<string>(RegistryMirrorTransportURLForTesting('http://localhost:8080/v1/capabilities'))
    .ToBe('http://127.0.0.1:8080/v1/capabilities');
  Expect<string>(RegistryMirrorTransportURLForTesting('http://localhost/v1'))
    .ToBe('http://127.0.0.1/v1');
  Expect<string>(RegistryMirrorTransportURLForTesting('http://localhost'))
    .ToBe('http://127.0.0.1');
  Expect<string>(RegistryMirrorTransportURLForTesting('http://localhost.example/v1'))
    .ToBe('http://localhost.example/v1');
  Expect<string>(RegistryMirrorTransportURLForTesting('https://localhost:8443/v1'))
    .ToBe('https://localhost:8443/v1');
  { The configured identity still names localhost end to end. }
  Harness := TOriginHarness.Create('mirror-loopback');
  try
    Expect<Boolean>(Pos('http://localhost:', Harness.Mirror.Config.UpstreamURL) = 1).ToBe(True);
    Expect<string>(Harness.Sync).ToBe('ok');
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.StaleActivatedMirrorReportsExpiry;
var
  Harness: TOriginHarness;
  Checkpoint, Served: TBytes;
  CheckpointPath: string;
  Run: TLwptResult;
  Stream: TStream;
  Response: TLWPTRegistryHTTPResponse;
begin
  { Accept a proof while it is fresh, then report it with the real clock. }
  SetRegistryClockForTesting('2026-01-02T00:00:00Z');
  Harness := TOriginHarness.Create('mirror-stale-activated', '2026-01-01T00:00:00Z');
  try
    Harness.Publish('stale', '2026-01-01T00:00:00Z');
    Expect<string>(Harness.Sync).ToBe('ok');
    SetRegistryClockForTesting('');
    CheckpointPath := Harness.Mirror.Root + '/' + Harness.Mirror.LoadCurrentState.CheckpointPath;
    Checkpoint := ReadFileBytes(CheckpointPath);
    Run := RunLwpt(['registry', 'verify', '--data-dir', Harness.Mirror.Root]);
    DumpRunFailure('verify stale activated mirror', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('freshness = "expired"', Run.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('expires_at = "2026-01-08T00:00:00Z"', Run.Stdout) > 0).ToBe(True);
    { Retained proof is served unchanged; the mirror never renews it. }
    Expect<string>(AsText(ReadFileBytes(CheckpointPath))).ToBe(AsText(Checkpoint));
    Response := RegistryHTTPResponse(Harness.Mirror, 'GET', '/v1/checkpoints/latest.toml');
    Stream := OpenRegistryHTTPResource(Response);
    try
      SetLength(Served, Stream.Size);
      if Length(Served) > 0 then Stream.ReadBuffer(Served[0], Length(Served));
    finally
      Stream.Free;
    end;
    Expect<string>(AsText(Served)).ToBe(AsText(Checkpoint));
  finally
    Harness.Free;
  end;
end;

procedure TMirrorTransferTests.SetupTests;
begin
  Test('archive admission arithmetic is overflow safe', AdmissionArithmetic);
  Test('two HTTP transfers overlap and completed buffers remain reserved', PairOverlapsAndRetainsCompletedReservation);
  Test('signed aggregate byte cap blocks a sibling without allocating its payload', SignedSizeBudgetBlocksSibling);
  Test('shared artifact hashes fetch once and verified objects resume', DuplicateHashFetchedOnce);
  Test('conflicting signed sizes fail before any archive request', ConflictingSizesFailBeforeFetch);
  Test('failed sibling drains without third admission and retains verified retry objects', FailedSiblingDrainsAndRetainsVerifiedObject);
  Test('checkpoint expiry during archive transfer prevents activation', ExpiryDuringTransferPreventsActivation);
  Test('checkpoint expiry after verification and storage prevents activation', ExpiryBeforeActivationPreventsPublication);
  Test('actual CLI interruption is reported as abandoned and resumes a verified archive pair', CLIInterruptionReusesCompletedPair);
  Test('concurrent fixture closes an incomplete client inside a child watchdog', IncompleteClientShutdownIsBounded);
  Test('an unsigned root key record cannot poison later synchronization', PoisonedRootKeyRecordIsNotPermanent);
  Test('a forged rotation stops retrieval before later items and keys', ForgedRotationStopsFurtherRetrieval);
  Test('a whole-synchronization budget bounds every request', SynchronizationBudgetBoundsRequests);
  Test('encoded or dot-segment discovery endpoints are refused before use', AmbiguousDiscoveryEndpointsAreRefused);
  Test('a checkpoint that advances between pair reads is retried', AdvancingCheckpointPairIsRetried);
  Test('a stable inconsistent checkpoint pair fails after one recheck', InconsistentCheckpointPairFailsBounded);
  Test('attempt recording failure preserves the synchronization error', AttemptRecordingFailurePreservesError);
  Test('the attempt byte budget rejects archives before transfer', SyncBudgetRejectsBeforeTransfer);
  Test('the store budget prunes unaccepted candidates and refuses overflow', StoreBudgetPrunesUnacceptedCandidates);
  Test('an older same-sequence renewal leaves the accepted pointer', BackwardsRenewalKeepsAcceptedPointer);
  Test('an abandoned rotation cannot contaminate a later accepted history', AbandonedRotationCannotContaminateLaterHistory);
  Test('IPv6 upstreams are rejected at configuration time', UnsupportedUpstreamsAreRejectedAtConfiguration);
  Test('the localhost HTTP exception connects to loopback directly', LocalhostTransportUsesLoopback);
  Test('an activated mirror becoming stale is reported with unchanged proof', StaleActivatedMirrorReportsExpiry);
end;

procedure RunIncompleteClient;
var
  Server: TRegistryTestServer;
  Client: TRegistryTestSocket;
  Addr: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Started: QWord;
  Request: AnsiString;
begin
  Server := TRegistryTestServer.Create(nil, True);
  Client := {$IFDEF UNIX}-1{$ELSE}INVALID_SOCKET{$ENDIF};
  try
    Server.Start;
    {$IFDEF UNIX}
    Client := fpSocket(AF_INET, SOCK_STREAM, 0);
    {$ELSE}
    Client := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
    {$ENDIF}
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    {$IFDEF UNIX}
    Addr.sin_addr := StrToNetAddr('127.0.0.1');
    Addr.sin_port := htons(Server.Port);
    if fpConnect(Client, @Addr, SizeOf(Addr)) <> 0 then Halt(2);
    {$ELSE}
    Addr.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
    Addr.sin_port := WinSock2.htons(Server.Port);
    if WinSock2.connect(Client, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then Halt(2);
    {$ENDIF}
    Request := 'GET /';
    {$IFDEF UNIX}
    fpSend(Client, @Request[1], Length(Request), 0);
    {$ELSE}
    WinSock2.send(Client, Request[1], Length(Request), 0);
    {$ENDIF}
    Started := GetTickCount64;
    while (Server.AcceptedCount = 0) and (GetTickCount64 - Started < 1000) do Sleep(1);
    if Server.AcceptedCount <> 1 then Halt(3);
    { Keep the peer open while the server tears down its incomplete request. }
    FreeAndNil(Server);
  finally
    {$IFDEF UNIX}
    CloseSocket(Client);
    {$ELSE}
    WinSock2.closesocket(Client);
    {$ENDIF}
    Server.Free;
  end;
end;

procedure TMirrorTransferTests.IncompleteClientShutdownIsBounded;
var
  Child: TProcess;
  Started: QWord;
  TimedOut: Boolean;
begin
  Child := TProcess.Create(nil);
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    Child.Parameters.Add('--registry-incomplete-client');
    Child.Execute;
    Started := GetTickCount64;
    while Child.Running and (GetTickCount64 - Started < 3000) do Sleep(10);
    TimedOut := Child.Running;
    Expect<Boolean>(TimedOut).ToBe(False);
    if not TimedOut then Expect<Integer>(Child.ExitStatus).ToBe(0);
  finally
    StopRegistryProcess(Child, 0, 2000);
  end;
end;

begin
  if ParamStr(1) = '--registry-incomplete-client' then
  begin
    RunIncompleteClient;
    Halt(0);
  end;
  TestRunnerProgram.AddSuite(TMirrorTransferTests.Create('registry mirror transfer'));
  TestRunnerProgram.Run;
end.
