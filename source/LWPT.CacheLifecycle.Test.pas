{ LWPT.CacheLifecycle.Test — aggregate LRU, live preservation, and repair. }
program LWPT.CacheLifecycle.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.ObjectStore,
  LWPT.ProducerLease,
  TestingPascalLibrary,
  Tests.Scratch;

type
  TCacheLifecycleContract = class(TTestSuite)
  private
    FCacheRoot: string;
    FOriginalBudget: string;
    FScratch: string;
    procedure ResetScratch;
    procedure SetBudget(const AValue: string);
    function WriteObject(const AName, ABytes: string;
      const AStore: TLWPTImmutableObjectStore): string;
  protected
    procedure AfterAll; override;
    procedure BeforeAll; override;
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestAggregateAdmissionEvictsDeterministicLRU;
    procedure TestLiveObjectIsPreservedAndAdmissionSkips;
    procedure TestRepairRebuildsIndexAndRemovesCorruption;
    procedure TestRepairRebuildsSemanticallyCorruptIndex;
    {$IFDEF UNIX}
    procedure TestRepairUnlinksCacheShardsWithoutFollowingThem;
    {$ENDIF}
    procedure TestRepairReclaimsAbandonedAndPreservesLiveLease;
    procedure TestBudgetParsing;
  end;

{$IFDEF UNIX}
function CSetEnvironmentVariable(AName, AValue: PAnsiChar;
  AOverwrite: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setenv';
  {$ELSE}
  external name 'setenv';
  {$ENDIF}
function CUnsetEnvironmentVariable(AName: PAnsiChar): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'unsetenv';
  {$ELSE}
  external name 'unsetenv';
  {$ENDIF}
{$ENDIF}

procedure SetProcessEnvironment(const AName, AValue: string);
{$IFDEF UNIX}
var
  Name, Value: AnsiString;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Name, Value: UnicodeString;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Name := AnsiString(AName);
  Value := AnsiString(AValue);
  if AValue = '' then
  begin
    if CUnsetEnvironmentVariable(PAnsiChar(Name)) <> 0 then
      raise Exception.Create('failed to clear ' + AName);
  end
  else if CSetEnvironmentVariable(PAnsiChar(Name), PAnsiChar(Value), 1) <> 0
    then
    raise Exception.Create('failed to set ' + AName);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Name := UnicodeString(AName);
  Value := UnicodeString(AValue);
  if AValue = '' then
  begin
    if not Windows.SetEnvironmentVariableW(PWideChar(Name), nil) then
      raise Exception.Create('failed to clear ' + AName);
  end
  else if not Windows.SetEnvironmentVariableW(PWideChar(Name),
    PWideChar(Value)) then
    raise Exception.Create('failed to set ' + AName);
  {$ENDIF}
end;

procedure TCacheLifecycleContract.TestRepairRebuildsSemanticallyCorruptIndex;
var
  Digest, IndexText: string;
  Report: TLWPTCacheRepairReport;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Digest := WriteObject('indexed', 'indexed-object', Store);
    WriteTextFile(FCacheRoot + '/lifecycle/index',
      'schema=1'#10
      + 'sequence=1'#10
      + 'entry.' + DEPENDENCY_ARCHIVE_NAMESPACE + ':' + Digest + '=999'#10
      + 'entry.garbage=1');
    Report := RepairSharedCache(FCacheRoot);
    Expect<Boolean>(Report.IndexRebuilt).ToBe(True);
    with TStringList.Create do
      try
        LoadFromFile(FCacheRoot + '/lifecycle/index');
        IndexText := Text;
      finally
        Free;
      end;
    Expect<Boolean>(Pos('entry.garbage=', IndexText) = 0).ToBe(True);
    Expect<Boolean>(Pos('=999', IndexText) = 0).ToBe(True);
    Expect<Boolean>(Pos('entry.' + DEPENDENCY_ARCHIVE_NAMESPACE + ':'
      + Digest + '=0', IndexText) > 0).ToBe(True);
  finally
    Store.Free;
  end;
end;

{$IFDEF UNIX}
procedure TCacheLifecycleContract.
  TestRepairUnlinksCacheShardsWithoutFollowingThem;
var
  LinkPath, NamespaceLink, NamespaceOutsideFile, NamespaceOutsideRoot,
    OutsideFile, OutsideRoot: string;
  Report: TLWPTCacheRepairReport;
begin
  OutsideRoot := FScratch + '/outside';
  OutsideFile := OutsideRoot + '/' + StringOfChar('a', 62);
  WriteTextFile(OutsideFile, 'outside-must-survive');
  ForceDirectories(FCacheRoot + '/dependency-archives/sha256');
  LinkPath := FCacheRoot + '/dependency-archives/sha256/ab';
  if FpSymlink(PChar(OutsideRoot), PChar(LinkPath)) <> 0 then
    raise Exception.Create('failed to create cache-shard symlink fixture');
  Report := RepairSharedCache(FCacheRoot);
  Expect<Boolean>(FileExists(OutsideFile)).ToBe(True);
  Expect<Boolean>(IsDirSymlinkOrJunction(LinkPath)).ToBe(False);
  Expect<Boolean>(Report.IncompleteEntriesRemoved >= 1).ToBe(True);

  WipeDir(FCacheRoot + '/dependency-archives');
  NamespaceOutsideRoot := FScratch + '/outside-namespace';
  NamespaceOutsideFile := NamespaceOutsideRoot + '/sha256/cd/'
    + StringOfChar('b', 62);
  WriteTextFile(NamespaceOutsideFile, 'namespace-outside-must-survive');
  NamespaceLink := FCacheRoot + '/dependency-archives';
  if FpSymlink(PChar(NamespaceOutsideRoot), PChar(NamespaceLink)) <> 0 then
    raise Exception.Create('failed to create cache-namespace link fixture');
  Report := RepairSharedCache(FCacheRoot);
  Expect<Boolean>(FileExists(NamespaceOutsideFile)).ToBe(True);
  Expect<Boolean>(IsDirSymlinkOrJunction(NamespaceLink)).ToBe(False);
  Expect<Boolean>(Report.IncompleteEntriesRemoved >= 1).ToBe(True);
end;
{$ENDIF}

procedure TCacheLifecycleContract.SetBudget(const AValue: string);
begin
  SetProcessEnvironment(CACHE_MAX_BYTES_ENV, AValue);
end;

procedure TCacheLifecycleContract.ResetScratch;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
  FCacheRoot := FScratch + '/cache';
  SetBudget('10737418240');
end;

procedure TCacheLifecycleContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('cache-lifecycle');
  FOriginalBudget := SysUtils.GetEnvironmentVariable(CACHE_MAX_BYTES_ENV);
end;

procedure TCacheLifecycleContract.BeforeEach;
begin
  ResetScratch;
end;

procedure TCacheLifecycleContract.AfterAll;
begin
  SetBudget(FOriginalBudget);
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

function TCacheLifecycleContract.WriteObject(const AName,
  ABytes: string; const AStore: TLWPTImmutableObjectStore): string;
var
  Raw: RawByteString;
  Source: string;
  Stream: TFileStream;
begin
  Source := FScratch + '/sources/' + AName;
  ForceDirectories(ExtractFileDir(Source));
  Stream := TFileStream.Create(Source, fmCreate);
  try
    Raw := RawByteString(ABytes);
    if Length(Raw) > 0 then Stream.WriteBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
  Result := 'sha256:' + SHA256File(Source);
  Expect<Boolean>(AStore.Admit(Source, Result) <> '').ToBe(True);
end;

procedure TCacheLifecycleContract.
  TestAggregateAdmissionEvictsDeterministicLRU;
var
  BuildStore, DependencyStore: TLWPTImmutableObjectStore;
  FirstDigest, Hit, SecondDigest, ThirdDigest: string;
begin
  SetBudget('14');
  DependencyStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  BuildStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  try
    FirstDigest := WriteObject('first', 'aaaa', DependencyStore);
    SecondDigest := WriteObject('second', 'bbbbbb', BuildStore);
    Expect<Boolean>(DependencyStore.Lookup(FirstDigest, Hit)).ToBe(True);
    ThirdDigest := WriteObject('third', 'cccccccc', DependencyStore);
    Expect<Boolean>(FileExists(DependencyStore.ObjectPath(FirstDigest)))
      .ToBe(True);
    Expect<Boolean>(FileExists(BuildStore.ObjectPath(SecondDigest)))
      .ToBe(False);
    Expect<Boolean>(FileExists(DependencyStore.ObjectPath(ThirdDigest)))
      .ToBe(True);
  finally
    BuildStore.Free;
    DependencyStore.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestLiveObjectIsPreservedAndAdmissionSkips;
var
  BuildStore, DependencyStore: TLWPTImmutableObjectStore;
  FirstDigest, LiveDigest, NewDigest, Source: string;
  Lifecycle: TLWPTCacheLifecycle;
  LiveLease: TObject;
begin
  SetBudget('10');
  DependencyStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  BuildStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot, 'build-results');
  LiveLease := nil;
  try
    FirstDigest := WriteObject('old', 'aaaa', DependencyStore);
    LiveDigest := WriteObject('live', 'bbbbbb', BuildStore);
    LiveLease := Lifecycle.AcquireObject(LiveDigest);
    Source := FScratch + '/sources/new';
    WriteTextFile(Source, 'cccccccc');
    NewDigest := 'sha256:' + SHA256File(Source);
    Expect<string>(DependencyStore.Admit(Source, NewDigest)).ToBe('');
    Expect<Boolean>(FileExists(DependencyStore.ObjectPath(FirstDigest)))
      .ToBe(False);
    Expect<Boolean>(FileExists(BuildStore.ObjectPath(LiveDigest)))
      .ToBe(True);
    Expect<Boolean>(FileExists(DependencyStore.ObjectPath(NewDigest)))
      .ToBe(False);
  finally
    LiveLease.Free;
    Lifecycle.Free;
    BuildStore.Free;
    DependencyStore.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestRepairRebuildsIndexAndRemovesCorruption;
var
  CorruptDigest, HealthyDigest: string;
  FirstReport, SecondReport: TLWPTCacheRepairReport;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    CorruptDigest := WriteObject('corrupt', 'corrupt-me', Store);
    HealthyDigest := WriteObject('healthy', 'keep-me', Store);
    WriteTextFile(FCacheRoot + '/lifecycle/index', 'broken');
    WriteTextFile(Store.ObjectPath(CorruptDigest), 'wrong');
    WriteTextFile(FCacheRoot + '/dependency-archives/tmp/incomplete',
      'partial');
    FirstReport := RepairSharedCache(FCacheRoot);
    Expect<Boolean>(FirstReport.IndexRebuilt).ToBe(True);
    Expect<Integer>(FirstReport.CorruptObjectsRemoved).ToBe(1);
    Expect<Integer>(FirstReport.IncompleteEntriesRemoved).ToBe(1);
    Expect<Boolean>(FirstReport.BytesReclaimed > 0).ToBe(True);
    Expect<Boolean>(FileExists(Store.ObjectPath(CorruptDigest))).ToBe(False);
    Expect<Boolean>(FileExists(Store.ObjectPath(HealthyDigest))).ToBe(True);
    SecondReport := RepairSharedCache(FCacheRoot);
    Expect<Integer>(SecondReport.CorruptObjectsRemoved).ToBe(0);
    Expect<Integer>(SecondReport.IncompleteEntriesRemoved).ToBe(0);
    Expect<Int64>(SecondReport.BytesReclaimed).ToBe(0);
  finally
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestRepairReclaimsAbandonedAndPreservesLiveLease;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  Digest, KeyRoot, LeaseKey: string;
  Lease: TLWPTProducerLease;
  Report: TLWPTCacheRepairReport;
begin
  LeaseKey := 'test-live-producer';
  Digest := SHA256Hex(BytesOf('test-abandoned-producer'));
  KeyRoot := ProducerLeaseRoot(FCacheRoot) + '/sha256/'
    + Copy(Digest, 1, 2) + '/' + Copy(Digest, 3, MaxInt);
  WriteTextFile(KeyRoot + '/state', 'abandoned');
  Coordinator := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(FCacheRoot));
  Lease := Coordinator.TryAcquire(LeaseKey, 'live test producer');
  try
    Expect<Boolean>(Lease <> nil).ToBe(True);
    Report := RepairSharedCache(FCacheRoot);
    Expect<Integer>(Report.AbandonedLeasesReclaimed).ToBe(1);
    Expect<Boolean>(Report.LiveLeasesPreserved >= 1).ToBe(True);
    Expect<Boolean>(FileExists(KeyRoot + '/state')).ToBe(False);
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

procedure TCacheLifecycleContract.TestBudgetParsing;
var
  Refused: Boolean;
begin
  Expect<Int64>(ResolveCacheMaxBytesFromValue('')).ToBe(
    DEFAULT_CACHE_MAX_BYTES);
  Expect<Int64>(ResolveCacheMaxBytesFromValue('0')).ToBe(0);
  Expect<Int64>(ResolveCacheMaxBytesFromValue(' 42 ')).ToBe(42);
  Refused := False;
  try
    ResolveCacheMaxBytesFromValue('-1');
  except
    on ELWPTCacheLifecycleError do Refused := True;
  end;
  Expect<Boolean>(Refused).ToBe(True);
end;

procedure TCacheLifecycleContract.SetupTests;
begin
  Test('aggregate admission evicts the deterministic least-recently-used '
    + 'object', TestAggregateAdmissionEvictsDeterministicLRU);
  Test('live objects are preserved and an admission that cannot fit skips',
    TestLiveObjectIsPreservedAndAdmissionSkips);
  Test('repair rebuilds the index and removes corruption repeatably',
    TestRepairRebuildsIndexAndRemovesCorruption);
  Test('repair rebuilds a semantically inconsistent index exactly',
    TestRepairRebuildsSemanticallyCorruptIndex);
  {$IFDEF UNIX}
  Test('repair unlinks cache shards without following them',
    TestRepairUnlinksCacheShardsWithoutFollowingThem);
  {$ENDIF}
  Test('repair reclaims abandoned and preserves live producer leases',
    TestRepairReclaimsAbandonedAndPreservesLiveLease);
  Test('cache budget parsing has one byte-valued contract',
    TestBudgetParsing);
end;

begin
  TestRunnerProgram.AddSuite(TCacheLifecycleContract.Create(
    'shared cache lifecycle'));
  TestRunnerProgram.Run;
end.
