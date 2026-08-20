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
    function CacheBytes(const APath: string): Int64;
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
    procedure TestAuxiliaryBytesConstrainAdmission;
    procedure TestFirstRecordCreatesLifecycleTemporaryRoot;
    procedure TestIndexGrowthCannotExceedBudget;
    procedure TestLiveObjectIsPreservedAndAdmissionSkips;
    procedure TestRepairRebuildsIndexAndRemovesCorruption;
    procedure TestRepairRebuildsSemanticallyCorruptIndex;
    procedure TestRepairRemovesInvalidProducerLeaseRoot;
    procedure TestRepairZeroBudgetPrunesBuildReferences;
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

procedure TCacheLifecycleContract.TestRepairZeroBudgetPrunesBuildReferences;
var
  Digest, ReferencePath, StaleReferencePath, UpperReferencePath: string;
  FirstReport, SecondReport: TLWPTCacheRepairReport;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  try
    Digest := WriteObject('build-manifest', 'cached-result-manifest', Store);
    ReferencePath := FCacheRoot + '/build-results/refs/sha256/11/'
      + StringOfChar('1', 62);
    StaleReferencePath := FCacheRoot + '/build-results/refs/sha256/22/'
      + StringOfChar('2', 62);
    UpperReferencePath := FCacheRoot + '/build-results/refs/sha256/33/'
      + StringOfChar('3', 62);
    WriteTextFile(ReferencePath, Digest + #10);
    WriteTextFile(StaleReferencePath,
      'sha256:' + StringOfChar('f', 64) + #10);
    WriteTextFile(UpperReferencePath, UpperCase(Digest) + #10);
    SetBudget('0');
    FirstReport := RepairSharedCache(FCacheRoot);
    Expect<Boolean>(FileExists(Store.ObjectPath(Digest))).ToBe(False);
    Expect<Boolean>(FileExists(ReferencePath)).ToBe(False);
    Expect<Boolean>(FileExists(StaleReferencePath)).ToBe(False);
    Expect<Boolean>(FileExists(UpperReferencePath)).ToBe(False);
    Expect<Int64>(FirstReport.BytesAfter).ToBe(0);
    Expect<Boolean>(FirstReport.BytesReclaimed > 0).ToBe(True);
    Expect<Boolean>(FirstReport.IncompleteEntriesRemoved >= 1).ToBe(True);
    SecondReport := RepairSharedCache(FCacheRoot);
    Expect<Int64>(SecondReport.BytesReclaimed).ToBe(0);
    Expect<Integer>(SecondReport.IncompleteEntriesRemoved).ToBe(0);
  finally
    Store.Free;
  end;
end;

{$IFDEF UNIX}
procedure TCacheLifecycleContract.
  TestRepairUnlinksCacheShardsWithoutFollowingThem;
var
  LeaseDigest, LeaseLink, LeaseOutsideFile, LeaseOutsideRoot, LinkPath,
    NamespaceLink, NamespaceOutsideFile, NamespaceOutsideRoot, OutsideFile,
    OutsideRoot: string;
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

  LeaseOutsideRoot := FScratch + '/outside-producer';
  LeaseOutsideFile := LeaseOutsideRoot + '/state';
  WriteTextFile(LeaseOutsideFile, 'producer-outside-must-survive');
  LeaseDigest := SHA256Hex(BytesOf('linked-producer-key'));
  LeaseLink := ProducerLeaseRoot(FCacheRoot) + '/sha256/'
    + Copy(LeaseDigest, 1, 2) + '/' + Copy(LeaseDigest, 3, MaxInt);
  ForceDirectories(ExtractFileDir(LeaseLink));
  if FpSymlink(PChar(LeaseOutsideRoot), PChar(LeaseLink)) <> 0 then
    raise Exception.Create('failed to create producer-key link fixture');
  Report := RepairSharedCache(FCacheRoot);
  Expect<Boolean>(FileExists(LeaseOutsideFile)).ToBe(True);
  Expect<Boolean>(IsDirSymlinkOrJunction(LeaseLink)).ToBe(False);
  Expect<Boolean>(Report.AbandonedLeasesReclaimed >= 1).ToBe(True);
end;
{$ENDIF}

procedure TCacheLifecycleContract.SetBudget(const AValue: string);
begin
  SetProcessEnvironment(CACHE_MAX_BYTES_ENV, AValue);
end;

function TCacheLifecycleContract.CacheBytes(const APath: string): Int64;
var
  Child: string;
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile,
       Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Child := IncludeTrailingPathDelimiter(APath) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
        Inc(Result, CacheBytes(Child))
      else
        Inc(Result, Search.Size);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
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
  SetBudget('15000');
  DependencyStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  BuildStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  try
    FirstDigest := WriteObject('first', StringOfChar('a', 4000),
      DependencyStore);
    SecondDigest := WriteObject('second', StringOfChar('b', 6000),
      BuildStore);
    Expect<Boolean>(DependencyStore.Lookup(FirstDigest, Hit)).ToBe(True);
    ThirdDigest := WriteObject('third', StringOfChar('c', 8000),
      DependencyStore);
    Expect<Boolean>(FileExists(DependencyStore.ObjectPath(FirstDigest)))
      .ToBe(True);
    Expect<Boolean>(FileExists(BuildStore.ObjectPath(SecondDigest)))
      .ToBe(False);
    Expect<Boolean>(FileExists(DependencyStore.ObjectPath(ThirdDigest)))
      .ToBe(True);
    Expect<Boolean>(CacheBytes(FCacheRoot) <= 15000).ToBe(True);
  finally
    BuildStore.Free;
    DependencyStore.Free;
  end;
end;

procedure TCacheLifecycleContract.TestAuxiliaryBytesConstrainAdmission;
var
  Digest, Source: string;
  Store: TLWPTImmutableObjectStore;
begin
  SetBudget('2500');
  WriteTextFile(FCacheRoot + '/producer-leases/diagnostic',
    StringOfChar('m', 2000));
  Source := FScratch + '/sources/constrained';
  WriteTextFile(Source, StringOfChar('x', 1000));
  Digest := 'sha256:' + SHA256File(Source);
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Expect<string>(Store.Admit(Source, Digest)).ToBe('');
    Expect<Boolean>(FileExists(Store.ObjectPath(Digest))).ToBe(False);
    Expect<Boolean>(CacheBytes(FCacheRoot) <= 2500).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestFirstRecordCreatesLifecycleTemporaryRoot;
var
  Digest, ObjectPath: string;
  Lifecycle: TLWPTCacheLifecycle;
  Mutation: TObject;
begin
  ObjectPath := FCacheRoot + '/dependency-archives/sha256/aa/'
    + StringOfChar('b', 62);
  WriteTextFile(ObjectPath, 'seed');
  Digest := 'sha256:aa' + StringOfChar('b', 62);
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  Mutation := Lifecycle.AcquireMutation;
  try
    Lifecycle.RecordObjectLocked(Digest, ObjectPath);
    Expect<Boolean>(FileExists(FCacheRoot + '/lifecycle/index')).ToBe(True);
    Expect<Boolean>(FileExists(FCacheRoot + '/lifecycle/manifests/'
      + DEPENDENCY_ARCHIVE_NAMESPACE + '/sha256/aa/'
      + StringOfChar('b', 62))).ToBe(True);
  finally
    Mutation.Free;
    Lifecycle.Free;
  end;
end;

procedure TCacheLifecycleContract.TestIndexGrowthCannotExceedBudget;
var
  Digest, Hit, IndexText: string;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Digest := WriteObject('sequence-boundary', 'bounded-index', Store);
    IndexText := 'schema=1'#10
      + 'sequence=9'#10
      + 'entry.' + DEPENDENCY_ARCHIVE_NAMESPACE + ':' + Digest + '=9'#10;
    WriteTextFile(FCacheRoot + '/lifecycle/index', IndexText);
    SetBudget(IntToStr(CacheBytes(FCacheRoot)));
    Expect<Boolean>(Store.Lookup(Digest, Hit)).ToBe(True);
    Expect<Boolean>(CacheBytes(FCacheRoot) <= ResolveCacheMaxBytes).ToBe(True);
  finally
    Store.Free;
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
  SetBudget('12000');
  DependencyStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  BuildStore := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot, 'build-results');
  LiveLease := nil;
  try
    FirstDigest := WriteObject('old', StringOfChar('a', 4000),
      DependencyStore);
    LiveDigest := WriteObject('live', StringOfChar('b', 6000), BuildStore);
    LiveLease := Lifecycle.AcquireObject(LiveDigest);
    Source := FScratch + '/sources/new';
    WriteTextFile(Source, StringOfChar('c', 8000));
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
  CorruptDigest, HealthyDigest, MalformedEntry, MalformedPrefix,
    MalformedRootEntry: string;
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
    MalformedRootEntry := FCacheRoot
      + '/dependency-archives/sha256/not-a-shard';
    MalformedPrefix := FCacheRoot + '/dependency-archives/sha256/zz/entry';
    MalformedEntry := FCacheRoot + '/dependency-archives/sha256/ab/bad';
    WriteTextFile(MalformedRootEntry, 'root-residue');
    WriteTextFile(MalformedPrefix, 'prefix-residue');
    WriteTextFile(MalformedEntry, 'entry-residue');
    FirstReport := RepairSharedCache(FCacheRoot);
    Expect<Boolean>(FirstReport.IndexRebuilt).ToBe(True);
    Expect<Integer>(FirstReport.CorruptObjectsRemoved).ToBe(1);
    Expect<Integer>(FirstReport.IncompleteEntriesRemoved).ToBe(5);
    Expect<Boolean>(FirstReport.BytesReclaimed > 0).ToBe(True);
    Expect<Boolean>(FileExists(Store.ObjectPath(CorruptDigest))).ToBe(False);
    Expect<Boolean>(FileExists(Store.ObjectPath(HealthyDigest))).ToBe(True);
    Expect<Boolean>(FileExists(MalformedRootEntry)).ToBe(False);
    Expect<Boolean>(FileExists(MalformedPrefix)).ToBe(False);
    Expect<Boolean>(FileExists(MalformedEntry)).ToBe(False);
    SecondReport := RepairSharedCache(FCacheRoot);
    Expect<Integer>(SecondReport.CorruptObjectsRemoved).ToBe(0);
    Expect<Integer>(SecondReport.IncompleteEntriesRemoved).ToBe(0);
    Expect<Int64>(SecondReport.BytesReclaimed).ToBe(0);
  finally
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.TestRepairRemovesInvalidProducerLeaseRoot;
var
  InvalidRoot: string;
  Report: TLWPTCacheRepairReport;
begin
  InvalidRoot := ProducerLeaseRoot(FCacheRoot) + '/sha256';
  WriteTextFile(InvalidRoot, 'invalid-root');
  Report := RepairSharedCache(FCacheRoot);
  Expect<Boolean>(FileExists(InvalidRoot)).ToBe(False);
  Expect<Boolean>(DirectoryExists(InvalidRoot)).ToBe(True);
  Expect<Integer>(Report.AbandonedLeasesReclaimed).ToBe(1);
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
    Expect<Boolean>(DirectoryExists(KeyRoot)).ToBe(False);
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
  Test('auxiliary cache bytes constrain ordinary admission',
    TestAuxiliaryBytesConstrainAdmission);
  Test('the first lifecycle record creates its atomic temporary root',
    TestFirstRecordCreatesLifecycleTemporaryRoot);
  Test('index growth cannot take a cache hit above budget',
    TestIndexGrowthCannotExceedBudget);
  Test('live objects are preserved and an admission that cannot fit skips',
    TestLiveObjectIsPreservedAndAdmissionSkips);
  Test('repair rebuilds the index and removes corruption repeatably',
    TestRepairRebuildsIndexAndRemovesCorruption);
  Test('repair rebuilds a semantically inconsistent index exactly',
    TestRepairRebuildsSemanticallyCorruptIndex);
  Test('repair removes an invalid producer lease root file',
    TestRepairRemovesInvalidProducerLeaseRoot);
  Test('zero-budget repair prunes live and stale build references',
    TestRepairZeroBudgetPrunesBuildReferences);
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
