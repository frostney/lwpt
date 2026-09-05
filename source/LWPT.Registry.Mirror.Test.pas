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
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Mirror,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryProcess,
  Tests.RegistryServer,
  Tests.Scratch,
  TOML;

type
  { A captured origin fixture cannot renew its deliberately near-expiry proof. }
  TCapturedOrigin = class(TLWPTRegistryStore)
  public
    procedure EnsureFreshCheckpoint(const ANow: string;
      AProgress: TSHA256Progress = nil); override;
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
    procedure CLIInterruptionReusesCompletedPair;
    procedure IncompleteClientShutdownIsBounded;
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
    and (GetTickCount64 - Started < 3000) do Sleep(1);
  Result := InterlockedCompareExchange(ACounter, 0, 0) >= ACount;
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
end;

procedure TMirrorTransferTests.BeforeEach;
var
  Config: TLWPTRegistryConfig;
begin
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
  FMirror.Free;
  RecursiveDelete(FRoot);
end;

function TMirrorTransferTests.ObjectPath(const APackage: TLWPTRegistryPackage): string;
begin
  Result := FRoot + '/objects/sha256/' + Copy(APackage.ArchiveHash, 8, 64);
end;

procedure TMirrorTransferTests.AdmissionArithmetic;
begin
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(0, MAXIMUM_MIRROR_ARCHIVE_BYTES, 0)).ToBe(True);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(MAXIMUM_MIRROR_ARCHIVE_BYTES, 0, 1)).ToBe(True);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(MAXIMUM_MIRROR_ARCHIVE_BYTES, 1, 1)).ToBe(False);
  Expect<Boolean>(RegistryMirrorCanAdmitForTesting(MAXIMUM_MIRROR_ARCHIVE_BYTES - 1, 1, 1)).ToBe(True);
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
  Stats: TRegistryMirrorTransferStats;
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
    Transfer.Mirror := FMirror;
    Transfer.API := 'http://localhost:' + IntToStr(Server.Port) + '/v1';
    Transfer.Start;
    Expect<Boolean>(WaitForCounter(Arrived, 2)).ToBe(True);
    { Neither response can finish before both requests reach their barriers. }
    RTLEventSetEvent(FirstGate);
    Sleep(50); { The first response can finish while its sibling is blocked. }
    Expect<Integer>(InterlockedCompareExchange(Third, 0, 0)).ToBe(0);
    Expect<Boolean>(FileExists(ObjectPath(Transfer.Packages[0]))).ToBe(False);
    RTLEventSetEvent(Gate);
    Transfer.WaitFor;
    Expect<string>(Transfer.Error).ToBe('');
    Expect<Integer>(Third).ToBe(1);
    Stats := RegistryMirrorTransferStatsForTesting(FMirror);
    Expect<Integer>(Stats.MaximumWorkers).ToBe(2);
    Expect<Int64>(Stats.PeakReserved).ToBe(18);
    Expect<Int64>(Stats.CompletedReserved).ToBe(18);
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
begin
  Gate := RTLEventCreate;
  Server := nil;
  Transfer := TTransferThread.Create;
  First := 0;
  Second := 0;
  try
    SetLength(Transfer.Packages, 2);
    Transfer.Packages[0] := Package(BytesOf('small'));
    Transfer.Packages[0].ArchiveSize := MAXIMUM_MIRROR_ARCHIVE_BYTES;
    Transfer.Packages[1] := Package(BytesOf('sibling'));
    SetLength(Routes, 2);
    Routes[0] := Route(Transfer.Packages[0], BytesOf('small'));
    Routes[0].Gate := Gate;
    Routes[0].Arrived := @First;
    Routes[1] := Route(Transfer.Packages[1], BytesOf('sibling'));
    Routes[1].Arrived := @Second;
    Server := TRegistryTestServer.Create(Routes, True);
    Server.Start;
    Transfer.Mirror := FMirror;
    Transfer.API := 'http://localhost:' + IntToStr(Server.Port) + '/v1';
    Transfer.Start;
    Expect<Boolean>(WaitForCounter(First, 1)).ToBe(True);
    Sleep(50);
    Expect<Integer>(InterlockedCompareExchange(Second, 0, 0)).ToBe(0);
    RTLEventSetEvent(Gate);
    Transfer.WaitFor;
    Expect<Boolean>(Pos('object_hash_mismatch', Transfer.Error) > 0).ToBe(True);
    Expect<Integer>(Second).ToBe(0);
    Expect<Int64>(RegistryMirrorTransferStatsForTesting(FMirror).PeakReserved).ToBe(MAXIMUM_MIRROR_ARCHIVE_BYTES);
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
    ATimedMirror := TLWPTRegistryMirror(TLWPTRegistryMirror.Initialize(FRoot + '/timed-mirror', Config, RegistryTimestampNow));
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
  PublishedAt, Expiry: string;
begin
  Server := TRegistryTestServer.Create(nil, True);
  Origin := nil;
  TimedMirror := nil;
  Transfer := nil;
  Gate := RTLEventCreate;
  Arrived := 0;
  try
    Expiry := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
      IncSecond(ISO8601ToDate(RegistryTimestampNow, True), 10));
    PublishedAt := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
      IncDay(ISO8601ToDate(Expiry, True), -7));
    PrepareSignedFixture(Server, PublishedAt, 1, Origin, TimedMirror, Routes, Packages);
    Routes[High(Routes)].Gate := Gate;
    Routes[High(Routes)].GateTimeoutMilliseconds := 15000;
    Routes[High(Routes)].Arrived := @Arrived;
    Server.SetRoutes(Routes);
    Server.Start;
    Transfer := TTransferThread.Create;
    Transfer.Mirror := TimedMirror;
    Transfer.FullSync := True;
    Transfer.Start;
    Expect<Boolean>(WaitForCounter(Arrived, 1)).ToBe(True);
    if Arrived = 0 then
    begin
      Transfer.WaitFor;
      raise Exception.Create('expiry fixture never reached archive request: ' + Transfer.Error);
    end;
    while RegistryTimestampNow < Expiry do Sleep(20);
    RTLEventSetEvent(Gate);
    Transfer.WaitFor;
    Expect<Boolean>(Pos('checkpoint_expired', Transfer.Error) > 0).ToBe(True);
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
  finally
    StopRegistryProcess(Child, 0, 2000);
    RTLEventSetEvent(Gate);
    Server.Free;
    Mirror.Free;
    Origin.Free;
    RTLEventDestroy(Gate);
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
  Test('actual CLI interruption resumes a verified archive pair', CLIInterruptionReusesCompletedPair);
  Test('concurrent fixture closes an incomplete client inside a child watchdog', IncompleteClientShutdownIsBounded);
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
