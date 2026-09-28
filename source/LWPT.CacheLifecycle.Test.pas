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
    function BuildObjectFile(const ADigest: string): string;
    function CacheBytes(const APath: string): Int64;
    function DependencyObjectFile(const ADigest: string): string;
    function ManifestFile(const ANamespace, ADigest: string): string;
    function RecordFabricatedObject(const ALifecycle: TLWPTCacheLifecycle;
      const AObjectRoot: string; const AHexDigit: Char;
      const ASize: Integer): string;
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
    procedure TestRepeatedIndexNameKeepsLastValue;
    procedure TestLargeCacheHitAndAdmissionStayFast;
    procedure TestEvictionCountsDeletedReferences;
    procedure TestUndeletedManifestIsNotCountedAsReclaimed;
    procedure TestConcurrentStagingGrowthKeepsEvicting;
    procedure TestLiveObjectIsPreservedAndAdmissionSkips;
    procedure TestRepairRebuildsIndexAndRemovesCorruption;
    procedure TestRepairRebuildsSemanticallyCorruptIndex;
    procedure TestRepairRemovesInvalidProducerLeaseRoot;
    procedure TestRepairZeroBudgetPrunesBuildReferences;
    procedure TestRepairRemovesTransitiveDanglingBuildReferences;
    procedure TestCorruptManifestCannotHideArtifactReference;
    procedure TestEmptyReferenceTreeDoesNotBlockRemoval;
    procedure TestRepairFailsClosedWhenReferenceCannotBeDeleted;
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

procedure TCacheLifecycleContract.
  TestRepairRemovesTransitiveDanglingBuildReferences;
const
  FINGERPRINT =
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
var
  ArtifactDigest, ManifestDigest, MalformedDigest, OversizedDigest,
    OversizedReferencePath, ReferencePath, MalformedReferencePath: string;
  {$IFDEF UNIX}
  UnreadableReferencePath: string;
  {$ENDIF}
  Report: TLWPTCacheRepairReport;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  try
    ArtifactDigest := WriteObject('artifact', 'compiled-artifact', Store);
    ManifestDigest := WriteObject('manifest',
      'schema = 1'#10
      + 'fingerprint = "' + FINGERPRINT + '"'#10
      + 'artifact_digest = "' + ArtifactDigest + '"'#10
      + 'artifact_kind = "executable"'#10
      + 'unix_mode = 0'#10, Store);
    MalformedDigest := WriteObject('malformed-manifest',
      'schema = 1'#10 + 'artifact_digest = [broken'#10, Store);
    OversizedDigest := WriteObject('oversized-manifest',
      StringOfChar('x', 64 * 1024 + 1), Store);
    ReferencePath := FCacheRoot + '/build-results/refs/sha256/aa/'
      + StringOfChar('a', 62);
    MalformedReferencePath := FCacheRoot
      + '/build-results/refs/sha256/bb/' + StringOfChar('b', 62);
    OversizedReferencePath := FCacheRoot
      + '/build-results/refs/sha256/cc/' + StringOfChar('c', 62);
    WriteTextFile(ReferencePath, ManifestDigest + #10);
    WriteTextFile(MalformedReferencePath, MalformedDigest + #10);
    WriteTextFile(OversizedReferencePath, OversizedDigest + #10);
    {$IFDEF UNIX}
    UnreadableReferencePath := FCacheRoot
      + '/build-results/refs/sha256/ee/' + StringOfChar('e', 62);
    WriteTextFile(UnreadableReferencePath, ManifestDigest + #10);
    if FpChmod(PChar(UnreadableReferencePath), 0) <> 0 then
      raise Exception.Create('failed to make build reference unreadable');
    {$ENDIF}
    SysUtils.DeleteFile(Store.ObjectPath(ArtifactDigest));

    Report := RepairSharedCache(FCacheRoot);
    Expect<Boolean>(FileExists(ReferencePath)).ToBe(False);
    Expect<Boolean>(FileExists(MalformedReferencePath)).ToBe(False);
    Expect<Boolean>(FileExists(OversizedReferencePath)).ToBe(False);
    {$IFDEF UNIX}
    Expect<Boolean>(FileExists(UnreadableReferencePath)).ToBe(False);
    Expect<Boolean>(Report.IncompleteEntriesRemoved >= 4).ToBe(True);
    {$ELSE}
    Expect<Boolean>(Report.IncompleteEntriesRemoved >= 3).ToBe(True);
    {$ENDIF}
  finally
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestCorruptManifestCannotHideArtifactReference;
const
  FINGERPRINT =
    'sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
var
  ArtifactDigest, ManifestDigest, ReferencePath: string;
  Lifecycle: TLWPTCacheLifecycle;
  MutationLease, ObjectLease: TObject;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot, 'build-results');
  ObjectLease := nil;
  MutationLease := nil;
  try
    ArtifactDigest := WriteObject('hidden-artifact', 'compiled-artifact',
      Store);
    ManifestDigest := WriteObject('hidden-manifest',
      'schema = 1'#10
      + 'fingerprint = "' + FINGERPRINT + '"'#10
      + 'artifact_digest = "' + ArtifactDigest + '"'#10
      + 'artifact_kind = "executable"'#10
      + 'unix_mode = 0'#10, Store);
    ReferencePath := FCacheRoot + '/build-results/refs/sha256/dd/'
      + StringOfChar('d', 62);
    WriteTextFile(ReferencePath, ManifestDigest + #10);

    { Keep the TOML valid while changing its bytes and named artifact. An
      eviction must distrust this object because it no longer matches the
      digest persisted by the reference. }
    WriteTextFile(Store.ObjectPath(ManifestDigest),
      'schema = 1'#10
      + 'fingerprint = "' + FINGERPRINT + '"'#10
      + 'artifact_digest = "sha256:' + StringOfChar('e', 64) + '"'#10
      + 'artifact_kind = "executable"'#10
      + 'unix_mode = 0'#10);
    ObjectLease := Lifecycle.AcquireObject(ArtifactDigest);
    MutationLease := Lifecycle.AcquireMutation;
    Lifecycle.DiscardObjectLocked(ArtifactDigest,
      Store.ObjectPath(ArtifactDigest));
    MutationLease.Free;
    MutationLease := nil;
    ObjectLease.Free;
    ObjectLease := nil;

    Expect<Boolean>(FileExists(Store.ObjectPath(ArtifactDigest))).ToBe(False);
    Expect<Boolean>(FileExists(ReferencePath)).ToBe(False);
  finally
    MutationLease.Free;
    ObjectLease.Free;
    Lifecycle.Free;
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.TestEmptyReferenceTreeDoesNotBlockRemoval;
var
  Digest: string;
  Lifecycle: TLWPTCacheLifecycle;
  MutationLease, ObjectLease: TObject;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/build-results/objects', FCacheRoot, 'build-results');
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot, 'build-results');
  ObjectLease := nil;
  MutationLease := nil;
  try
    Digest := WriteObject('unreferenced', 'unreferenced-result', Store);
    ForceDirectories(FCacheRoot + '/build-results/refs/sha256');
    ObjectLease := Lifecycle.AcquireObject(Digest);
    MutationLease := Lifecycle.AcquireMutation;
    Lifecycle.DiscardObjectLocked(Digest, Store.ObjectPath(Digest));
    MutationLease.Free;
    MutationLease := nil;
    ObjectLease.Free;
    ObjectLease := nil;
    Expect<Boolean>(FileExists(Store.ObjectPath(Digest))).ToBe(False);
  finally
    MutationLease.Free;
    ObjectLease.Free;
    Lifecycle.Free;
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestRepairFailsClosedWhenReferenceCannotBeDeleted;
var
  PrefixPath, ReferencePath: string;
  Refused: Boolean;
  Report: TLWPTCacheRepairReport;
  {$IFDEF MSWINDOWS}
  ReferenceHandle: THandle;
  {$ENDIF}
begin
  PrefixPath := FCacheRoot + '/build-results/refs/sha256/ff';
  ReferencePath := PrefixPath + '/' + StringOfChar('f', 62);
  WriteTextFile(ReferencePath, 'not-a-digest');
  Refused := False;
  {$IFDEF UNIX}
  if FpChmod(PChar(PrefixPath), &555) <> 0 then
    raise Exception.Create('failed to protect build-reference fixture');
  try
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ReferenceHandle := Windows.CreateFileW(
    PWideChar(UnicodeString(ReferencePath)), Windows.GENERIC_READ,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE, nil,
    Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if ReferenceHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
    raise Exception.Create('failed to protect build-reference fixture');
  try
  {$ENDIF}
    try
      RepairSharedCache(FCacheRoot);
    except
      on ELWPTCacheLifecycleError do Refused := True;
    end;
    Expect<Boolean>(Refused).ToBe(True);
    Expect<Boolean>(FileExists(ReferencePath)).ToBe(True);
  finally
    {$IFDEF UNIX}
    if FpChmod(PChar(PrefixPath), &755) <> 0 then
      raise Exception.Create('failed to restore build-reference fixture');
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Windows.CloseHandle(ReferenceHandle);
    {$ENDIF}
  end;
  Report := RepairSharedCache(FCacheRoot);
  Expect<Boolean>(FileExists(ReferencePath)).ToBe(False);
  Expect<Boolean>(Report.IncompleteEntriesRemoved >= 1).ToBe(True);

  {$IFDEF UNIX}
  PrefixPath := FCacheRoot + '/build-results/refs/sha256/ee';
  ReferencePath := PrefixPath + '/' + StringOfChar('e', 62);
  WriteTextFile(ReferencePath, 'not-a-digest');
  if FpChmod(PChar(PrefixPath), 0) <> 0 then
    raise Exception.Create('failed to hide build-reference fixture');
  Refused := False;
  try
    try
      RepairSharedCache(FCacheRoot);
    except
      on ELWPTCacheLifecycleError do Refused := True;
    end;
  finally
    if FpChmod(PChar(PrefixPath), &755) <> 0 then
      raise Exception.Create('failed to restore hidden reference fixture');
  end;
  Expect<Boolean>(Refused).ToBe(True);
  Expect<Boolean>(FileExists(ReferencePath)).ToBe(True);
  RepairSharedCache(FCacheRoot);
  Expect<Boolean>(FileExists(ReferencePath)).ToBe(False);
  {$ENDIF}
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

function ShardPath(const ARoot, ADigest: string): string;
var
  Hex: string;
begin
  Hex := Copy(ADigest, Length('sha256:') + 1, MaxInt);
  Result := ARoot + '/sha256/' + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
end;

function FileSizeOf(const APath: string): Int64;
var
  Search: TSearchRec;
begin
  if FindFirst(APath, faAnyFile, Search) <> 0 then
    raise Exception.Create('missing fixture file ' + APath);
  try
    Result := Search.Size;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function TCacheLifecycleContract.BuildObjectFile(
  const ADigest: string): string;
begin
  Result := ShardPath(FCacheRoot + '/build-results/objects', ADigest);
end;

function TCacheLifecycleContract.DependencyObjectFile(
  const ADigest: string): string;
begin
  Result := ShardPath(FCacheRoot + '/dependency-archives', ADigest);
end;

function TCacheLifecycleContract.ManifestFile(const ANamespace,
  ADigest: string): string;
begin
  Result := ShardPath(FCacheRoot + '/lifecycle/manifests/' + ANamespace,
    ADigest);
end;

{ Places an object of ASize bytes whose digest is AHexDigit repeated, and
  records it as the most recently used; the caller holds the mutation. }
function TCacheLifecycleContract.RecordFabricatedObject(
  const ALifecycle: TLWPTCacheLifecycle; const AObjectRoot: string;
  const AHexDigit: Char; const ASize: Integer): string;
var
  Path: string;
begin
  Result := 'sha256:' + StringOfChar(AHexDigit, 64);
  Path := ShardPath(AObjectRoot, Result);
  WriteTextFile(Path, StringOfChar('x', ASize));
  ALifecycle.RecordObjectLocked(Result, Path);
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

procedure TCacheLifecycleContract.TestRepeatedIndexNameKeepsLastValue;
var
  Digest, Hit, IndexText, Key, LastSpelling, OtherDigest,
    OtherKey: string;
  Store: TLWPTImmutableObjectStore;
  Lines: TStringList;
  Index, Occurrences: Integer;
begin
  { A name repeated in the index (names compare case-insensitively)
    resolves to its last row, spelling and value, exactly as the original
    Values[]-based loader did, and the next rewrite carries the name
    once. The hit touches a different object, so the repeated entry's
    rewritten value can only come from the loader: 7 when the last write
    wins, 3 when the first does. Another entry sits between the repeats,
    so they do not arrive adjacent. }
  Store := TLWPTImmutableObjectStore.Create(
    FCacheRoot + '/dependency-archives', FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  Lines := TStringList.Create;
  try
    Digest := WriteObject('repeated', 'repeated-name', Store);
    OtherDigest := WriteObject('other', 'other-name', Store);
    Key := DEPENDENCY_ARCHIVE_NAMESPACE + ':' + Digest;
    OtherKey := DEPENDENCY_ARCHIVE_NAMESPACE + ':' + OtherDigest;
    LastSpelling := DEPENDENCY_ARCHIVE_NAMESPACE + ':' + UpperCase(Digest);
    IndexText := 'schema=1'#10 + 'sequence=7'#10
      + 'entry.' + Key + '=3'#10
      + 'entry.' + OtherKey + '=5'#10
      + 'entry.' + LastSpelling + '=7'#10;
    WriteTextFile(FCacheRoot + '/lifecycle/index', IndexText);
    Expect<Boolean>(Store.Lookup(OtherDigest, Hit)).ToBe(True);
    Lines.CaseSensitive := True;
    Lines.LoadFromFile(FCacheRoot + '/lifecycle/index');
    Occurrences := 0;
    for Index := 0 to Lines.Count - 1 do
      if Pos('entry.' + Key + '=', LowerCase(Lines[Index])) = 1 then
        Inc(Occurrences);
    Expect<Integer>(Occurrences).ToBe(1);
    Expect<Integer>(Lines.Count).ToBe(4);
    Expect<string>(Lines[1]).ToBe('sequence=8');
    Expect<Boolean>(Lines.IndexOf('entry.' + LastSpelling + '=7') >= 2)
      .ToBe(True);
    Expect<Boolean>(Lines.IndexOf('entry.' + OtherKey + '=8') >= 2)
      .ToBe(True);
  finally
    Lines.Free;
    Store.Free;
  end;
end;

procedure TCacheLifecycleContract.TestLargeCacheHitAndAdmissionStayFast;
const
  SmallObjects = 2000;
  LargeObjects = 20000;
  ObjectBytes = 100;
  { Enforcement also sees the admitted object, its manifest and its index
    entry, which cost a few more evictions of about ObjectBytes each. }
  EvictionSlack = 10;
  { Ten times the objects and evictions costs about ten times as much when
    hit and admission are linear, and about a hundred times for each
    quadratic variant this guards against. Comparing two sizes on the same
    machine keeps runner speed and per-file costs (far higher on NTFS) out
    of the bound. }
  ScaleMultiple = 30;
  ScaleSlackMs = 500;

  procedure Measure(const AObjectCount: Integer; out AHitMs, AAdmitMs: Int64);
  var
    Digest, Hit, NewDigest, Source: string;
    Store: TLWPTImmutableObjectStore;
    IndexLines: TStringList;
    Digests: array of string;
    LastUses: array of Integer;
    Budget: Int64;
    Index, Evicted, Evictions: Integer;
    Started: QWord;
    EvictedInOrder: Boolean;
  begin
    ResetScratch;
    Evictions := AObjectCount div 10;
    Store := TLWPTImmutableObjectStore.Create(
      FCacheRoot + '/dependency-archives', FCacheRoot,
      DEPENDENCY_ARCHIVE_NAMESPACE);
    IndexLines := TStringList.Create;
    try
      Digest := WriteObject('hot', 'hot-object', Store);
      SetLength(Digests, AObjectCount);
      SetLength(LastUses, AObjectCount);
      for Index := 0 to AObjectCount - 1 do
      begin
        Digests[Index] := 'sha256:' + LowerCase(SHA256Hex(BytesOf(
          'scale-object-' + IntToStr(Index))));
        { 7919 is prime and coprime with both sizes, so this is a
          permutation of 1..AObjectCount unrelated to the digests' order. }
        LastUses[Index] := Int64(Index) * 7919 mod AObjectCount + 1;
        WriteTextFile(Store.ObjectPath(Digests[Index]),
          StringOfChar('s', ObjectBytes));
        IndexLines.Add('entry.' + DEPENDENCY_ARCHIVE_NAMESPACE + ':'
          + Digests[Index] + '=' + IntToStr(LastUses[Index]));
      end;
      IndexLines.Add('entry.' + DEPENDENCY_ARCHIVE_NAMESPACE + ':' + Digest
        + '=' + IntToStr(AObjectCount + 1));
      IndexLines.Sort;
      for Index := 0 to IndexLines.Count div 2 - 1 do
        IndexLines.Exchange(Index, IndexLines.Count - 1 - Index);
      IndexLines.Insert(0, 'sequence=' + IntToStr(AObjectCount + 1));
      IndexLines.Insert(0, 'schema=1');
      IndexLines.LineBreak := #10;
      ForceDirectories(FCacheRoot + '/lifecycle');
      IndexLines.SaveToFile(FCacheRoot + '/lifecycle/index');

      Started := GetTickCount64;
      Expect<Boolean>(Store.Lookup(Digest, Hit)).ToBe(True);
      AHitMs := Int64(GetTickCount64 - Started);

      Source := FScratch + '/sources/cold';
      WriteTextFile(Source, 'cold-object');
      NewDigest := 'sha256:' + SHA256File(Source);
      { WriteTextFile adds the platform line break to each payload. }
      Budget := CacheBytes(FCacheRoot)
        - Evictions * FileSizeOf(Store.ObjectPath(Digests[0]));
      SetBudget(IntToStr(Budget));
      Started := GetTickCount64;
      Expect<Boolean>(Store.Admit(Source, NewDigest) <> '').ToBe(True);
      AAdmitMs := Int64(GetTickCount64 - Started);

      { The evicted objects are exactly the least recently used ones, and
        no more of them than the budget needed. }
      Evicted := 0;
      for Index := 0 to AObjectCount - 1 do
        if not FileExists(Store.ObjectPath(Digests[Index])) then Inc(Evicted);
      EvictedInOrder := True;
      for Index := 0 to AObjectCount - 1 do
        if FileExists(Store.ObjectPath(Digests[Index]))
           <> (LastUses[Index] > Evicted) then
          EvictedInOrder := False;
      if (Evicted < Evictions) or (Evicted > Evictions + EvictionSlack) then
        Fail(Format('%d objects: evicted %d, expected %d to %d',
          [AObjectCount, Evicted, Evictions, Evictions + EvictionSlack]));
      if not EvictedInOrder then
        Fail(Format('%d objects: eviction did not remove exactly the least '
          + 'recently used objects', [AObjectCount]));
      if not FileExists(Store.ObjectPath(Digest)) then
        Fail(Format('%d objects: the recently used hot object was evicted',
          [AObjectCount]));
      if CacheBytes(FCacheRoot) > Budget then
        Fail(Format('%d objects: the cache is still over budget after '
          + 'admission', [AObjectCount]));
    finally
      IndexLines.Free;
      Store.Free;
    end;
  end;

var
  SmallHitMs, SmallAdmitMs, LargeHitMs, LargeAdmitMs: Int64;
begin
  { A grown shared cache holds tens of thousands of objects and index
    entries. Every hit loads the index, and an admission over budget also
    matches each object to its entry, orders them by recency, and evicts
    many of them. Each step used to be quadratic: the loader and the
    per-object lookup scanned the index, the insertion sort shifted
    objects, and every eviction re-walked the tree and rescanned the
    index for its entry. The fixture makes those steps expensive: real
    objects whose recency is unrelated to the order discovery returns them
    in, an index written in reverse name order, and a budget that forces
    a tenth of the objects out. }
  Measure(SmallObjects, SmallHitMs, SmallAdmitMs);
  Measure(LargeObjects, LargeHitMs, LargeAdmitMs);
  if LargeHitMs >= ScaleMultiple * SmallHitMs + ScaleSlackMs then
    Fail(Format('hit took %d ms at %d objects against %d ms at %d; bound '
      + '%d x + %d ms', [LargeHitMs, LargeObjects, SmallHitMs, SmallObjects,
      ScaleMultiple, ScaleSlackMs]));
  if LargeAdmitMs >= ScaleMultiple * SmallAdmitMs + ScaleSlackMs then
    Fail(Format('admission took %d ms at %d objects against %d ms at %d; '
      + 'bound %d x + %d ms', [LargeAdmitMs, LargeObjects, SmallAdmitMs,
      SmallObjects, ScaleMultiple, ScaleSlackMs]));
end;

procedure TCacheLifecycleContract.TestEvictionCountsDeletedReferences;
var
  Budget: Int64;
  Evicted, Kept, Newest, Reference: string;
  Lifecycle: TLWPTCacheLifecycle;
  Mutation: TObject;
  Index: Integer;
  References: array[0..2] of string;
begin
  { Evicting a build result also deletes the references that name it.
    Those bytes are freed too: when they are what brings the cache under
    budget, eviction stops there instead of taking the next object. }
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot, 'build-results');
  Mutation := Lifecycle.AcquireMutation;
  try
    Evicted := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/build-results/objects', 'a', 1000);
    Kept := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/build-results/objects', 'c', 1000);
    Newest := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/build-results/objects', 'e', 1000);
    for Index := 0 to High(References) do
    begin
      References[Index] := FCacheRoot + '/build-results/refs/sha256/'
        + IntToStr(Index + 1) + '1/' + StringOfChar('1', 62);
      WriteTextFile(References[Index], Evicted + #10);
    end;
    Budget := CacheBytes(FCacheRoot)
      - FileSizeOf(BuildObjectFile(Evicted))
      - FileSizeOf(ManifestFile('build-results', Evicted));
    for Reference in References do
      Dec(Budget, FileSizeOf(Reference));
    SetBudget(IntToStr(Budget));
    Expect<Boolean>(Lifecycle.MakeRoomLocked(0)).ToBe(True);
    Expect<Boolean>(FileExists(BuildObjectFile(Evicted))).ToBe(False);
    for Reference in References do
      Expect<Boolean>(FileExists(Reference)).ToBe(False);
    Expect<Boolean>(FileExists(BuildObjectFile(Kept))).ToBe(True);
    Expect<Boolean>(FileExists(BuildObjectFile(Newest))).ToBe(True);
  finally
    Mutation.Free;
    Lifecycle.Free;
  end;
end;

var
  ConcurrentStagingPath: string;
  ConcurrentStagingBytes: Integer;

{ Stands in for another writer copying into object staging, which it does
  before taking the mutation guard: the tree grows once, mid-eviction. }
procedure GrowStagingOnce(const ACacheRoot: string);
begin
  if ConcurrentStagingPath = '' then Exit;
  WriteTextFile(ConcurrentStagingPath,
    StringOfChar('g', ConcurrentStagingBytes));
  ConcurrentStagingPath := '';
end;

procedure TCacheLifecycleContract.
  TestConcurrentStagingGrowthKeepsEvicting;
var
  Budget: Int64;
  Oldest, Second, Third, Newest, Staged: string;
  Lifecycle: TLWPTCacheLifecycle;
  Mutation: TObject;
begin
  { The budget fits once the oldest object goes, but another writer's
    staging grows the tree by more than one object in the meantime. The
    running total then fits while the tree does not; eviction must
    continue from the next candidates rather than refuse the admission
    with eligible objects left. }
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  Mutation := Lifecycle.AcquireMutation;
  try
    Oldest := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'a', 1000);
    Second := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'b', 1000);
    Third := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'c', 1000);
    Newest := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'e', 1000);
    Budget := CacheBytes(FCacheRoot)
      - FileSizeOf(DependencyObjectFile(Oldest))
      - FileSizeOf(ManifestFile(DEPENDENCY_ARCHIVE_NAMESPACE, Oldest));
    SetBudget(IntToStr(Budget));
    Staged := FCacheRoot + '/dependency-archives/tmp/'
      + StringOfChar('d', 64) + '/object';
    ConcurrentStagingPath := Staged;
    ConcurrentStagingBytes := 1500;
    CacheLifecycleAfterEvictionTestHook := GrowStagingOnce;
    try
      Expect<Boolean>(Lifecycle.MakeRoomLocked(0)).ToBe(True);
    finally
      CacheLifecycleAfterEvictionTestHook := nil;
      ConcurrentStagingPath := '';
    end;
    Expect<Boolean>(FileExists(Staged)).ToBe(True);
    Expect<Boolean>(FileExists(DependencyObjectFile(Oldest))).ToBe(False);
    Expect<Boolean>(FileExists(DependencyObjectFile(Second))).ToBe(False);
    Expect<Boolean>(FileExists(DependencyObjectFile(Newest))).ToBe(True);
    { Whether Third also goes depends on manifest and index sizes; the
      growth is under two objects, so the newest always survives. }
    Expect<Boolean>(CacheBytes(FCacheRoot) <= Budget).ToBe(True);
  finally
    Mutation.Free;
    Lifecycle.Free;
  end;
end;

procedure TCacheLifecycleContract.
  TestUndeletedManifestIsNotCountedAsReclaimed;
var
  Budget: Int64;
  Manifest, Oldest, Next, Newest: string;
  Lifecycle: TLWPTCacheLifecycle;
  Mutation: TObject;
  {$IFDEF MSWINDOWS}
  ManifestHandle: THandle;
  {$ENDIF}
begin
  { A payload that is deleted while its manifest is not frees only the
    payload's bytes. Counting the manifest too would stop eviction early
    and then reject the admission on the final walk, although the next
    object could still have been evicted. }
  Lifecycle := TLWPTCacheLifecycle.Create(FCacheRoot,
    DEPENDENCY_ARCHIVE_NAMESPACE);
  Mutation := Lifecycle.AcquireMutation;
  try
    Oldest := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'a', 1000);
    Next := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'c', 1000);
    Newest := RecordFabricatedObject(Lifecycle,
      FCacheRoot + '/dependency-archives', 'e', 1000);
    Manifest := ManifestFile(DEPENDENCY_ARCHIVE_NAMESPACE, Oldest);
    Budget := CacheBytes(FCacheRoot)
      - FileSizeOf(DependencyObjectFile(Oldest)) - FileSizeOf(Manifest);
    SetBudget(IntToStr(Budget));
    {$IFDEF UNIX}
    if FpChmod(PChar(ExtractFileDir(Manifest)), &555) <> 0 then
      raise Exception.Create('failed to protect manifest fixture');
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    ManifestHandle := Windows.CreateFileW(
      PWideChar(UnicodeString(Manifest)), Windows.GENERIC_READ,
      Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE, nil,
      Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
    if ManifestHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
      raise Exception.Create('failed to protect manifest fixture');
    {$ENDIF}
    try
      Expect<Boolean>(Lifecycle.MakeRoomLocked(0)).ToBe(True);
      Expect<Boolean>(FileExists(Manifest)).ToBe(True);
    finally
      {$IFDEF UNIX}
      if FpChmod(PChar(ExtractFileDir(Manifest)), &755) <> 0 then
        raise Exception.Create('failed to restore manifest fixture');
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      Windows.CloseHandle(ManifestHandle);
      {$ENDIF}
    end;
    Expect<Boolean>(FileExists(DependencyObjectFile(Oldest))).ToBe(False);
    Expect<Boolean>(FileExists(DependencyObjectFile(Next))).ToBe(False);
    Expect<Boolean>(FileExists(DependencyObjectFile(Newest))).ToBe(True);
    Expect<Boolean>(CacheBytes(FCacheRoot) <= Budget).ToBe(True);
  finally
    Mutation.Free;
    Lifecycle.Free;
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
  Digest, KeyRoot, LeaseKey, ReleasedDigest, ReleasedKeyRoot: string;
  Lease: TLWPTProducerLease;
  ReleasedGuard: TObject;
  Report: TLWPTCacheRepairReport;
begin
  LeaseKey := 'test-live-producer';
  Digest := SHA256Hex(BytesOf('test-abandoned-producer'));
  KeyRoot := ProducerLeaseRoot(FCacheRoot) + '/sha256/'
    + Copy(Digest, 1, 2) + '/' + Copy(Digest, 3, MaxInt);
  WriteTextFile(KeyRoot + '/state', 'abandoned');
  Coordinator := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(FCacheRoot));
  ReleasedDigest := SHA256Hex(BytesOf('test-released-guard'));
  ReleasedKeyRoot := ProducerLeaseRoot(FCacheRoot) + '/sha256/'
    + Copy(ReleasedDigest, 1, 2) + '/'
    + Copy(ReleasedDigest, 3, MaxInt);
  ReleasedGuard := Coordinator.TryAcquireGuard('test-released-guard');
  Expect<Boolean>(ReleasedGuard <> nil).ToBe(True);
  ReleasedGuard.Free;
  Lease := Coordinator.TryAcquire(LeaseKey, 'live test producer');
  try
    Expect<Boolean>(Lease <> nil).ToBe(True);
    Report := RepairSharedCache(FCacheRoot);
    Expect<Integer>(Report.AbandonedLeasesReclaimed).ToBe(2);
    Expect<Boolean>(Report.LiveLeasesPreserved >= 1).ToBe(True);
    Expect<Boolean>(FileExists(KeyRoot + '/state')).ToBe(False);
    Expect<Boolean>(DirectoryExists(KeyRoot)).ToBe(False);
    Expect<Boolean>(DirectoryExists(ReleasedKeyRoot)).ToBe(False);
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
  Test('a repeated index name keeps its last value and is written once',
    TestRepeatedIndexNameKeepsLastValue);
  Test('a 20 000-object cache keeps hits and multi-eviction admissions '
    + 'fast', TestLargeCacheHitAndAdmissionStayFast);
  Test('eviction counts the references it deletes as reclaimed',
    TestEvictionCountsDeletedReferences);
  Test('a manifest that cannot be deleted is not counted as reclaimed',
    TestUndeletedManifestIsNotCountedAsReclaimed);
  Test('eviction continues when concurrent staging outgrows its total',
    TestConcurrentStagingGrowthKeepsEvicting);
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
  Test('repair removes transitive dangling build references',
    TestRepairRemovesTransitiveDanglingBuildReferences);
  Test('corrupt manifests cannot hide artifact references from eviction',
    TestCorruptManifestCannotHideArtifactReference);
  Test('an empty reference tree does not block object removal',
    TestEmptyReferenceTreeDoesNotBlockRemoval);
  Test('repair fails closed when a reference cannot be deleted',
    TestRepairFailsClosedWhenReferenceCannotBeDeleted);
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
