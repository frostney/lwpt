program LWPT.Registry.ConsumerStore.Test;

{ The per-user registry document store's eviction policy (issue #345):
  accepted histories are never evicted, evictable documents leave in
  least-recently-used order exactly while their bytes exceed the budget,
  foreign and corrupt entries are handled without removing anything live,
  passes are bounded, and an invalid budget fails clearly. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Consumer,
  LWPT.Registry.ConsumerStore,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.RegistryConsumer,
  Tests.Scratch,
  Tests.TarSynth
  {$IFDEF MSWINDOWS},
  Windows
  {$ENDIF};

const
  IDENTITY = 'https://packages.example.com';
  DAY = 24 * 60 * 60;

type
  { A store holding one origin state whose head is a renewal at sequence 2,
    plus the two checkpoints it superseded. }
  TStoreFixture = record
    Root: string;
    Snapshot1, Snapshot2, RecordAlpha, RecordBeta: string;
    Checkpoints, Signatures: array[0..2] of string;
    StatePath, StateBytes: string;
  end;

  TRegistryStoreTests = class(TTestSuite)
  private
    FScratch: string;
    FCount: Integer;
    function NewRoot: string;
    function BuildStore: TStoreFixture;
    function Pass(const ARoot: string; const ABudget, ANow: Int64;
      const AWrite: Boolean = True): TLWPTRegistryStoreReport;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestAcceptedHistoryIsNeverEvicted;
    procedure TestEvictionIsLeastRecentlyUsed;
    procedure TestEqualStampsEvictTheLowerDigestFirst;
    procedure TestBudgetBoundaryIsExact;
    procedure TestRecencyStampsUseAndFirstSight;
    procedure TestForeignEntriesAreNeverTouched;
    procedure TestCorruptDocumentsAndIndexAreHandledSafely;
    procedure TestBrokenHistoryRemovesNothing;
    procedure TestUnlistableDirectoriesRemoveNothing;
    procedure TestLinksAndSpecialFilesAreForeign;
    procedure TestUnreadableSmallDocumentRemovesNothing;
    procedure TestFailedRemovalIsRetainedAndReported;
    procedure TestIndexWriteFailureRemovesNothing;
    procedure TestUnreadableStateBlocksEviction;
    procedure TestHistoryWalkIsBounded;
    procedure TestReadingPassWritesNothing;
    procedure TestBudgetParsing;
  end;

function Present(const ARoot, AHash: string): Boolean;
begin
  Result := FileExists(RegistryStateDocumentPath(ARoot, AHash));
end;

function DocumentSize(const ARoot, AHash: string): Int64;
var Search: TSearchRec;
begin
  Result := -1;
  if FindFirst(RegistryStateDocumentPath(ARoot, AHash), faAnyFile, Search) = 0 then
  try
    Result := Search.Size;
  finally
    SysUtils.FindClose(Search);
  end;
end;

{ Writes ABytes at its content address and returns the hash. }
function PutDocument(const ARoot: string; const ABytes: TBytes): string;
begin
  Result := SHA256BytesPrefixed(ABytes);
  ForceDirectories(RegistryStateDocumentsDirectory(ARoot));
  WriteBytesToFile(RegistryStateDocumentPath(ARoot, Result), ABytes);
end;

function Orphan(const ARoot, ALabel: string; const ASize: Integer): string;
var Text: string;
begin
  Text := 'orphan ' + ALabel + ' ';
  Text := Text + StringOfChar('x', ASize - Length(Text));
  Result := PutDocument(ARoot, BytesOf(Text));
end;

function Hashes(const AValues: array of string): TStringArray;
var Index: Integer;
begin
  SetLength(Result, Length(AValues));
  for Index := 0 to High(AValues) do Result[Index] := AValues[Index];
end;

procedure TRegistryStoreTests.BeforeAll;
begin
  FScratch := CreateScratchRoot('registry-store');
end;

procedure TRegistryStoreTests.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

function TRegistryStoreTests.NewRoot: string;
begin
  Inc(FCount);
  Result := FScratch + '/s' + IntToStr(FCount);
  ForceDirectories(Result);
end;

function TRegistryStoreTests.BuildStore: TStoreFixture;
var
  Registry: TSyntheticRegistry;
  Index: Integer;

  function Document(const APath: string): TLWPTRegistryDocument;
  begin
    Result.Path := APath;
    Expect<Boolean>(Registry.Document(APath, Result.Bytes)).ToBe(True);
  end;

  function SnapshotPath(const AHash: string): string;
  begin
    Result := 'snapshots/sha256/' + RegistryDigestHex(AHash) + '.toml';
  end;

  function RecordPath(const AHash: string): string;
  begin
    Result := 'records/sha256/' + RegistryDigestHex(AHash) + '.toml';
  end;

  procedure Merge(const ACheckpoint: Integer; const AHistory: array of string);
  var
    Current: TSyntheticCheckpoint;
    Checkpoint: TLWPTUntrustedRegistryCheckpoint;
    State: TLWPTRegistryConsumerState;
    History: TLWPTRegistryDocumentArray;
    Item: Integer;
  begin
    Current := Registry.Checkpoint(ACheckpoint);
    Checkpoint := InspectRegistryCheckpoint(Current.Checkpoint);
    State := Default(TLWPTRegistryConsumerState);
    State.State.KeyId := Registry.KeyID;
    State.State.PublicKey := Registry.PublicKey;
    State.State.Sequence := Checkpoint.Sequence;
    State.State.Snapshot := Checkpoint.Snapshot;
    State.State.CheckpointHash := SHA256BytesPrefixed(Current.Checkpoint);
    State.State.PublishedAt := Checkpoint.PublishedAt;
    State.State.ExpiresAt := Checkpoint.ExpiresAt;
    State.State.ClockFloor := Checkpoint.PublishedAt;
    SetLength(History, Length(AHistory) + 2);
    for Item := 0 to High(AHistory) do
      History[Item] := Document(AHistory[Item]);
    History[Length(AHistory)].Path := 'checkpoint';
    History[Length(AHistory)].Bytes := Current.Checkpoint;
    History[Length(AHistory) + 1].Path := 'signature';
    History[Length(AHistory) + 1].Bytes := Current.Signature;
    MergeRegistryConsumerStateAt(Result.Root, IDENTITY, Registry.KeyID, State,
      nil, History);
    Result.Checkpoints[ACheckpoint] := SHA256BytesPrefixed(Current.Checkpoint);
    Result.Signatures[ACheckpoint] := SHA256BytesPrefixed(Current.Signature);
  end;

begin
  Result := Default(TStoreFixture);
  Result.Root := NewRoot;
  Registry := TSyntheticRegistry.Create(IDENTITY);
  try
    Registry.AddPackage('alpha', '1.0.0', RegistryPackageArchive('alpha', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-3000), RegistryStamp(DAY));
    Result.Snapshot1 := Registry.Head;
    Result.RecordAlpha := Registry.RecordHash('alpha', '1.0.0');
    Registry.AddPackage('beta', '1.0.0', RegistryPackageArchive('beta', '1.0.0'), []);
    Registry.Publish(RegistryStamp(-2000), RegistryStamp(DAY));
    Result.Snapshot2 := Registry.Head;
    Result.RecordBeta := Registry.RecordHash('beta', '1.0.0');
    { A renewal: the same snapshot under a later checkpoint. }
    Registry.Renew(RegistryStamp(-1000), RegistryStamp(DAY));
    Merge(0, [SnapshotPath(Result.Snapshot1), RecordPath(Result.RecordAlpha)]);
    for Index := 1 to 2 do
      Merge(Index, [SnapshotPath(Result.Snapshot2), SnapshotPath(Result.Snapshot1),
        RecordPath(Result.RecordAlpha), RecordPath(Result.RecordBeta)]);
    Result.StatePath := RegistryStatePathAt(Result.Root, IDENTITY, Registry.KeyID);
  finally
    Registry.Free;
  end;
  Result.StateBytes := ReadBinaryFile(Result.StatePath);
end;

function TRegistryStoreTests.Pass(const ARoot: string; const ABudget,
  ANow: Int64; const AWrite: Boolean): TLWPTRegistryStoreReport;
var Roots: TLWPTRegistryStoreRootArray; Reason: string;
begin
  CollectRegistryStoreRoots(ARoot, Roots, Reason);
  Result := RunRegistryDocumentStorePass(ARoot, Roots, Reason, nil, ABudget,
    ANow, DefaultRegistryVerificationLimits, AWrite);
end;

procedure ExpectLive(const AStore: TStoreFixture);
begin
  Expect<Boolean>(Present(AStore.Root, AStore.Snapshot1)).ToBe(True);
  Expect<Boolean>(Present(AStore.Root, AStore.Snapshot2)).ToBe(True);
  Expect<Boolean>(Present(AStore.Root, AStore.RecordAlpha)).ToBe(True);
  Expect<Boolean>(Present(AStore.Root, AStore.RecordBeta)).ToBe(True);
  Expect<Boolean>(Present(AStore.Root, AStore.Checkpoints[2])).ToBe(True);
  Expect<Boolean>(Present(AStore.Root, AStore.Signatures[2])).ToBe(True);
  Expect<string>(ReadBinaryFile(AStore.StatePath)).ToBe(AStore.StateBytes);
end;

function SupersededBytes(const AStore: TStoreFixture): Int64;
var Index: Integer;
begin
  Result := 0;
  for Index := 0 to 1 do
    Result := Result + DocumentSize(AStore.Root, AStore.Checkpoints[Index])
      + DocumentSize(AStore.Root, AStore.Signatures[Index]);
end;

procedure TRegistryStoreTests.TestAcceptedHistoryIsNeverEvicted;
var Store: TStoreFixture; Report: TLWPTRegistryStoreReport; Index: Integer;
begin
  Store := BuildStore;
  Report := Pass(Store.Root, 0, 1000);
  Expect<Boolean>(Report.Complete).ToBe(True);
  Expect<Boolean>(Report.Analyzed).ToBe(True);
  Expect<Integer>(Report.StateFiles).ToBe(1);
  Expect<Integer>(Report.Documents).ToBe(10);
  Expect<Integer>(Report.LiveDocuments).ToBe(6);
  Expect<Integer>(Report.EvictableDocuments).ToBe(4);
  Expect<Integer>(Report.EvictedDocuments).ToBe(4);
  Expect<Int64>(Report.EvictedBytes).ToBe(Report.EvictableBytes);
  { The whole snapshot chain, every record it names, and the accepted
    checkpoint with its signature survive a zero budget. }
  ExpectLive(Store);
  for Index := 0 to 1 do
  begin
    Expect<Boolean>(Present(Store.Root, Store.Checkpoints[Index])).ToBe(False);
    Expect<Boolean>(Present(Store.Root, Store.Signatures[Index])).ToBe(False);
  end;
  { Nothing evictable remains: a second pass removes nothing. }
  Report := Pass(Store.Root, 0, 2000);
  Expect<Integer>(Report.EvictableDocuments).ToBe(0);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  ExpectLive(Store);
end;

procedure TRegistryStoreTests.TestEvictionIsLeastRecentlyUsed;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  First, Second, Third: string;
  Evictable: Int64;
begin
  Store := BuildStore;
  First := Orphan(Store.Root, 'first', 1000);
  Second := Orphan(Store.Root, 'second', 2000);
  Third := Orphan(Store.Root, 'third', 3000);
  StampRegistryDocuments(Store.Root, Hashes([First]), 100);
  StampRegistryDocuments(Store.Root, Hashes([Second]), 200);
  StampRegistryDocuments(Store.Root, Hashes([Third]), 300);
  StampRegistryDocuments(Store.Root, Hashes([Store.Checkpoints[0],
    Store.Signatures[0], Store.Checkpoints[1], Store.Signatures[1]]), 400);
  Evictable := 6000 + SupersededBytes(Store);
  { Removing the oldest alone reaches the budget. }
  Report := Pass(Store.Root, Evictable - 1000, 500);
  Expect<Int64>(Report.EvictableBytes).ToBe(Evictable);
  Expect<Integer>(Report.EvictedDocuments).ToBe(1);
  Expect<Boolean>(Present(Store.Root, First)).ToBe(False);
  Expect<Boolean>(Present(Store.Root, Second)).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Third)).ToBe(True);
  { One byte under the next two: both leave, oldest first, and the newer
    superseded checkpoints stay. }
  Report := Pass(Store.Root, Evictable - 6000 + 2999, 500);
  Expect<Integer>(Report.EvictedDocuments).ToBe(2);
  Expect<Boolean>(Present(Store.Root, Second)).ToBe(False);
  Expect<Boolean>(Present(Store.Root, Third)).ToBe(False);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Signatures[1])).ToBe(True);
  ExpectLive(Store);
end;

procedure TRegistryStoreTests.TestEqualStampsEvictTheLowerDigestFirst;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Left, Right, Lower, Higher: string;
begin
  Store := BuildStore;
  Left := Orphan(Store.Root, 'left', 500);
  Right := Orphan(Store.Root, 'right', 500);
  StampRegistryDocuments(Store.Root, Hashes([Left, Right]), 50);
  StampRegistryDocuments(Store.Root, Hashes([Store.Checkpoints[0],
    Store.Signatures[0], Store.Checkpoints[1], Store.Signatures[1]]), 400);
  if CompareStr(Left, Right) < 0 then
  begin
    Lower := Left;
    Higher := Right;
  end
  else
  begin
    Lower := Right;
    Higher := Left;
  end;
  Report := Pass(Store.Root, 500 + SupersededBytes(Store), 500);
  Expect<Integer>(Report.EvictedDocuments).ToBe(1);
  Expect<Boolean>(Present(Store.Root, Lower)).ToBe(False);
  Expect<Boolean>(Present(Store.Root, Higher)).ToBe(True);
end;

procedure TRegistryStoreTests.TestBudgetBoundaryIsExact;
var Store: TStoreFixture; Report: TLWPTRegistryStoreReport; Evictable: Int64;
begin
  Store := BuildStore;
  Evictable := SupersededBytes(Store);
  { Evictable bytes equal to the budget are within it. }
  Report := Pass(Store.Root, Evictable, 100);
  Expect<Boolean>(Report.Analyzed).ToBe(True);
  Expect<Int64>(Report.EvictableBytes).ToBe(Evictable);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  { One byte less removes exactly one document: they share one stamp, so
    the lowest digest leaves. }
  Report := Pass(Store.Root, Evictable - 1, 100);
  Expect<Integer>(Report.EvictedDocuments).ToBe(1);
  Expect<Integer>(Report.EvictableDocuments - Report.EvictedDocuments).ToBe(3);
  { A store within the budget in total skips the live-set walk. }
  Report := Pass(Store.Root, Report.DocumentBytes, 100);
  Expect<Boolean>(Report.Analyzed).ToBe(False);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  ExpectLive(Store);
end;

procedure TRegistryStoreTests.TestRecencyStampsUseAndFirstSight;
var
  Store: TStoreFixture;
  Recency: TLWPTRegistryRecency;
  Roots: TLWPTRegistryStoreRootArray;
  Reason, Extra: string;
  Stamp: Int64;
begin
  Store := BuildStore;
  Extra := Orphan(Store.Root, 'extra', 100);
  { Every document without a stamp is first seen at ANow; AUsed is stamped
    even when a stamp exists. }
  Pass(Store.Root, High(Int64), 700);
  StampRegistryDocuments(Store.Root, Hashes([Extra]), 10);
  CollectRegistryStoreRoots(Store.Root, Roots, Reason);
  RunRegistryDocumentStorePass(Store.Root, Roots, Reason,
    Hashes([Store.Checkpoints[0]]), High(Int64), 900,
    DefaultRegistryVerificationLimits, True);
  Recency := LoadRegistryDocumentRecency(Store.Root);
  try
    Expect<Integer>(Recency.Count).ToBe(11);
    Expect<Boolean>(Recency.TryGetValue(RegistryDigestHex(Extra), Stamp)).ToBe(True);
    Expect<Int64>(Stamp).ToBe(10);
    Recency.TryGetValue(RegistryDigestHex(Store.Checkpoints[0]), Stamp);
    Expect<Int64>(Stamp).ToBe(900);
    Recency.TryGetValue(RegistryDigestHex(Store.Snapshot1), Stamp);
    Expect<Int64>(Stamp).ToBe(700);
  finally
    Recency.Free;
  end;
  { The index is published before removals, so evicted documents leave it
    on the next pass. }
  Pass(Store.Root, 0, 1000);
  Recency := LoadRegistryDocumentRecency(Store.Root);
  try
    Expect<Integer>(Recency.Count).ToBe(11);
  finally
    Recency.Free;
  end;
  Pass(Store.Root, 0, 1100);
  Recency := LoadRegistryDocumentRecency(Store.Root);
  try
    Expect<Integer>(Recency.Count).ToBe(6);
    Expect<Boolean>(Recency.ContainsKey(RegistryDigestHex(Extra))).ToBe(False);
  finally
    Recency.Free;
  end;
end;

procedure TRegistryStoreTests.TestForeignEntriesAreNeverTouched;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Directory, Upper: string;
begin
  Store := BuildStore;
  Directory := RegistryStateDocumentsDirectory(Store.Root);
  { Not a stored digest: on a case-insensitive file system an upper-case
    twin of a stored name would be that document. }
  Upper := StringOfChar('B', 64) + '.toml';
  WriteTextFile(Directory + '/README', 'notes');
  WriteTextFile(Directory + '/' + Upper, 'upper-case name');
  WriteTextFile(Directory + '/short.toml', 'short name');
  ForceDirectories(Directory + '/' + StringOfChar('a', 64) + '.toml');
  WriteTextFile(Store.Root + '/origins/notes.txt', 'not a state file');
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(True);
  Expect<Integer>(Report.IgnoredEntries).ToBe(4);
  Expect<Integer>(Report.Documents).ToBe(10);
  Expect<Integer>(Report.EvictedDocuments).ToBe(4);
  Expect<Boolean>(FileExists(Directory + '/README')).ToBe(True);
  Expect<Boolean>(FileExists(Directory + '/' + Upper)).ToBe(True);
  Expect<Boolean>(FileExists(Directory + '/short.toml')).ToBe(True);
  Expect<Boolean>(DirectoryExists(Directory + '/' + StringOfChar('a', 64)
    + '.toml')).ToBe(True);
  Expect<Boolean>(FileExists(Store.Root + '/origins/notes.txt')).ToBe(True);
  ExpectLive(Store);
end;

procedure TRegistryStoreTests.TestCorruptDocumentsAndIndexAreHandledSafely;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Forged: string;
  Recency: TLWPTRegistryRecency;
begin
  Store := BuildStore;
  { A small file under an evictable name whose bytes do not match it is not
    that document, and nothing else depends on it. }
  Forged := Orphan(Store.Root, 'forged', 200);
  WriteTextFile(RegistryStateDocumentPath(Store.Root, Forged), 'tampered');
  WriteTextFile(RegistryDocumentRecencyPath(Store.Root), 'not an index'#10
    + 'zz 12'#10);
  Recency := LoadRegistryDocumentRecency(Store.Root);
  try
    Expect<Integer>(Recency.Count).ToBe(0);
  finally
    Recency.Free;
  end;
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(5);
  Expect<Boolean>(Present(Store.Root, Forged)).ToBe(False);
  ExpectLive(Store);
  Recency := LoadRegistryDocumentRecency(Store.Root);
  try
    Expect<Integer>(Recency.Count).ToBe(Report.Documents);
  finally
    Recency.Free;
  end;
end;

procedure TRegistryStoreTests.TestBrokenHistoryRemovesNothing;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Before, SnapshotPath: string;
begin
  Store := BuildStore;
  SnapshotPath := RegistryStateDocumentPath(Store.Root, Store.Snapshot2);
  { A corrupt accepted snapshot hides the history behind it. }
  Before := ReadBinaryFile(SnapshotPath);
  WriteTextFile(SnapshotPath, 'corrupt snapshot');
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Boolean>(Pos('is corrupt; delete it', Report.Incomplete) > 0).ToBe(True);
  Expect<Boolean>(Pos(RegistryDigestHex(Store.Snapshot2), Report.Incomplete) > 0)
    .ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
  { So does a snapshot that is not there at all. }
  WriteBytesToFile(SnapshotPath, BytesOf(Before));
  Expect<Boolean>(SysUtils.DeleteFile(RegistryStateDocumentPath(Store.Root,
    Store.Snapshot1))).ToBe(True);
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Boolean>(Pos('is missing', Report.Incomplete) > 0).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Boolean>(Present(Store.Root, Store.RecordAlpha)).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Signatures[1])).ToBe(True);
  Expect<string>(ReadBinaryFile(Store.StatePath)).ToBe(Store.StateBytes);
end;

{ Running as root defeats permission-based failures; those cases then only
  check that nothing breaks. }
function PermissionsApply: Boolean;
begin
  {$IFDEF UNIX}
  Result := fpGetEUid <> 0;
  {$ELSE}
  Result := True;
  {$ENDIF}
end;

procedure TRegistryStoreTests.TestUnlistableDirectoriesRemoveNothing;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Roots: TLWPTRegistryStoreRootArray;
  Reason, Origins: string;
begin
  Store := BuildStore;
  Origins := Store.Root + '/origins';
  { An origins path that is not a directory is never an empty directory. }
  Expect<Boolean>(RenameFile(Origins, Store.Root + '/origins.away')).ToBe(True);
  WriteTextFile(Origins, 'not a directory');
  Expect<Boolean>(CollectRegistryStoreRoots(Store.Root, Roots, Reason)).ToBe(False);
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
  SysUtils.DeleteFile(Origins);
  Expect<Boolean>(RenameFile(Store.Root + '/origins.away', Origins)).ToBe(True);
  {$IFDEF UNIX}
  if PermissionsApply then
  begin
    { A directory that exists but cannot be listed. }
    fpChmod(PChar(Origins), &000);
    try
      Report := Pass(Store.Root, 0, 100);
    finally
      fpChmod(PChar(Origins), &755);
    end;
    Expect<Boolean>(Report.Complete).ToBe(False);
    Expect<Boolean>(Pos('cannot be listed', Report.Incomplete) > 0).ToBe(True);
    Expect<Integer>(Report.EvictedDocuments).ToBe(0);
    fpChmod(PChar(RegistryStateDocumentsDirectory(Store.Root)), &000);
    try
      Report := Pass(Store.Root, 0, 100);
    finally
      fpChmod(PChar(RegistryStateDocumentsDirectory(Store.Root)), &755);
    end;
    Expect<Boolean>(Report.Complete).ToBe(False);
    Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  end;
  {$ENDIF}
  Expect<Boolean>(Present(Store.Root, Store.Signatures[0])).ToBe(True);
  Report := Pass(Store.Root, 0, 100);
  Expect<Integer>(Report.EvictedDocuments).ToBe(4);
end;

{$IFDEF MSWINDOWS}
function CreateSymbolicLinkW(ALink, ATarget: PWideChar; AFlags: DWORD): BOOLEAN;
  stdcall; external 'kernel32' name 'CreateSymbolicLinkW';
{$ENDIF}

procedure TRegistryStoreTests.TestLinksAndSpecialFilesAreForeign;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Outside, OutsideHash, LinkPath, Expected: string;
  Ignored: Integer;
begin
  Store := BuildStore;
  { A hash-named link to a file outside the store. }
  Outside := Store.Root + '/outside.toml';
  WriteTextFile(Outside, 'outside the store');
  OutsideHash := SHA256BytesPrefixed(BytesOf(ReadBinaryFile(Outside)));
  LinkPath := RegistryStateDocumentPath(Store.Root, OutsideHash);
  Expected := ReadBinaryFile(Outside);
  Ignored := 0;
  {$IFDEF UNIX}
  Expect<Integer>(fpSymlink(PChar(Outside), PChar(LinkPath))).ToBe(0);
  Inc(Ignored);
  { A FIFO under a document name would block a reader forever. }
  Expect<Integer>(fpMkFifo(PChar(RegistryStateDocumentPath(Store.Root,
    'sha256:' + StringOfChar('f', 64))), &600)).ToBe(0);
  Inc(Ignored);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  { 2 = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE; without developer mode
    or privilege the link cannot be made, and the case checks the rest. }
  if CreateSymbolicLinkW(PWideChar(UnicodeString(StringReplace(LinkPath, '/',
       '\', [rfReplaceAll]))), PWideChar(UnicodeString(StringReplace(Outside,
       '/', '\', [rfReplaceAll]))), 2)
     { Some emulators report success without creating anything. }
     and (GetFileAttributesW(PWideChar(UnicodeString(LinkPath)))
       <> INVALID_FILE_ATTRIBUTES) then
    Inc(Ignored)
  else
    WriteLn('  (file symbolic links unavailable; reparse-point case skipped)');
  {$ENDIF}
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(True);
  Expect<Integer>(Report.IgnoredEntries).ToBe(Ignored);
  Expect<Integer>(Report.Documents).ToBe(10);
  Expect<Integer>(Report.EvictedDocuments).ToBe(4);
  Expect<string>(ReadBinaryFile(Outside)).ToBe(Expected);
  {$IFDEF UNIX}
  Expect<Boolean>(fpReadLink(LinkPath) = Outside).ToBe(True);
  Expect<Boolean>(FileExists(RegistryStateDocumentPath(Store.Root,
    'sha256:' + StringOfChar('f', 64)))).ToBe(True);
  {$ENDIF}
  ExpectLive(Store);
end;

procedure TRegistryStoreTests.TestUnreadableSmallDocumentRemovesNothing;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Small: string;
  {$IFDEF MSWINDOWS}
  Holder: TFileStream;
  {$ENDIF}
begin
  Store := BuildStore;
  { It could be a live signature, so the pass cannot rule it out. }
  Small := Orphan(Store.Root, 'small', 300);
  if not PermissionsApply then Exit;
  {$IFDEF UNIX}
  fpChmod(PChar(RegistryStateDocumentPath(Store.Root, Small)), &000);
  try
    Report := Pass(Store.Root, 0, 100);
  finally
    fpChmod(PChar(RegistryStateDocumentPath(Store.Root, Small)), &644);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Holder := TFileStream.Create(RegistryStateDocumentPath(Store.Root, Small),
    fmOpenRead or fmShareExclusive);
  try
    Report := Pass(Store.Root, 0, 100);
  finally
    Holder.Free;
  end;
  {$ENDIF}
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Boolean>(Pos('whether it is a live signature is unknown',
    Report.Incomplete) > 0).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Boolean>(Present(Store.Root, Small)).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
end;

procedure TRegistryStoreTests.TestFailedRemovalIsRetainedAndReported;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Victim: string;
  Recency: TLWPTRegistryRecency;
  {$IFDEF MSWINDOWS}
  Holder: TFileStream;
  {$ENDIF}
begin
  Store := BuildStore;
  Victim := Orphan(Store.Root, 'held', 5000);
  StampRegistryDocuments(Store.Root, Hashes([Victim]), 1);
  if not PermissionsApply then Exit;
  { Only the orphan is over a budget that holds the superseded documents. }
  {$IFDEF UNIX}
  fpChmod(PChar(RegistryStateDocumentsDirectory(Store.Root)), &555);
  try
    Report := Pass(Store.Root, SupersededBytes(Store), 100);
  finally
    fpChmod(PChar(RegistryStateDocumentsDirectory(Store.Root)), &755);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  { A reader's handle shares reading and writing, never deletion. }
  Holder := TFileStream.Create(RegistryStateDocumentPath(Store.Root, Victim),
    fmOpenRead or fmShareDenyNone);
  try
    Report := Pass(Store.Root, SupersededBytes(Store), 100);
  finally
    Holder.Free;
  end;
  {$ENDIF}
  Expect<Boolean>(Report.Complete).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Integer>(Report.RetainedDocuments).ToBe(1);
  Expect<Int64>(Report.RetainedBytes).ToBe(5000);
  Expect<Boolean>(Present(Store.Root, Victim)).ToBe(True);
  { The retained document keeps its stamp for the next pass. }
  Recency := LoadRegistryDocumentRecency(Store.Root);
  try
    Expect<Boolean>(Recency.ContainsKey(RegistryDigestHex(Victim))).ToBe(True);
  finally
    Recency.Free;
  end;
  Report := Pass(Store.Root, SupersededBytes(Store), 100);
  Expect<Integer>(Report.EvictedDocuments).ToBe(1);
  Expect<Boolean>(Present(Store.Root, Victim)).ToBe(False);
end;

procedure TRegistryStoreTests.TestIndexWriteFailureRemovesNothing;
var
  Store: TStoreFixture;
  Message: string;
begin
  Store := BuildStore;
  { The index cannot replace a directory. }
  ForceDirectories(RegistryDocumentRecencyPath(Store.Root) + '/blocked');
  Message := '';
  try
    Pass(Store.Root, 0, 100);
  except
    on E: Exception do Message := E.Message;
  end;
  Expect<Boolean>(Message <> '').ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Signatures[0])).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[1])).ToBe(True);
  Expect<Boolean>(Present(Store.Root, Store.Signatures[1])).ToBe(True);
  ExpectLive(Store);
end;

procedure TRegistryStoreTests.TestUnreadableStateBlocksEviction;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Corrupt, CorruptBytes: string;
  Roots: TLWPTRegistryStoreRootArray;
  Reason: string;
begin
  Store := BuildStore;
  Corrupt := Store.Root + '/origins/' + StringOfChar('c', 64) + '.toml';
  WriteTextFile(Corrupt, 'schema = "corrupt');
  CorruptBytes := ReadBinaryFile(Corrupt);
  Expect<Boolean>(CollectRegistryStoreRoots(Store.Root, Roots, Reason)).ToBe(False);
  Expect<Boolean>(Pos(StringOfChar('c', 64) + '.toml', Reason) > 0).ToBe(True);
  { Its live documents are unknown, so a zero budget removes nothing. }
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Boolean>(Pos('cannot be read', Report.Incomplete) > 0).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
  Expect<string>(ReadBinaryFile(Corrupt)).ToBe(CorruptBytes);
  { A valid state file under another file's name is not trusted either. }
  SysUtils.DeleteFile(Corrupt);
  WriteTextFile(Corrupt, Store.StateBytes);
  Report := Pass(Store.Root, 0, 100);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  SysUtils.DeleteFile(Corrupt);
  Report := Pass(Store.Root, 0, 100);
  Expect<Integer>(Report.EvictedDocuments).ToBe(4);
end;

procedure TRegistryStoreTests.TestHistoryWalkIsBounded;
var
  Store: TStoreFixture;
  Report: TLWPTRegistryStoreReport;
  Limits: TLWPTRegistryVerificationLimits;
  Roots: TLWPTRegistryStoreRootArray;
  Reason: string;
begin
  Store := BuildStore;
  CollectRegistryStoreRoots(Store.Root, Roots, Reason);
  Limits := DefaultRegistryVerificationLimits;
  Limits.Snapshots := 1;
  Report := RunRegistryDocumentStorePass(Store.Root, Roots, Reason, nil, 0, 100,
    Limits, True);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Boolean>(Pos('1 snapshots', Report.Incomplete) > 0).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Limits := DefaultRegistryVerificationLimits;
  Limits.TotalBytes := DocumentSize(Store.Root, Store.Snapshot2);
  Report := RunRegistryDocumentStorePass(Store.Root, Roots, Reason, nil, 0, 100,
    Limits, True);
  Expect<Boolean>(Report.Complete).ToBe(False);
  Expect<Boolean>(Pos('byte limits', Report.Incomplete) > 0).ToBe(True);
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<Boolean>(Present(Store.Root, Store.Checkpoints[0])).ToBe(True);
end;

procedure TRegistryStoreTests.TestReadingPassWritesNothing;
var Store: TStoreFixture; Report: TLWPTRegistryStoreReport; Before: string;
begin
  Store := BuildStore;
  Before := HashTree(Store.Root);
  Report := Pass(Store.Root, 0, 100, False);
  Expect<Boolean>(Report.Analyzed).ToBe(True);
  Expect<Integer>(Report.LiveDocuments).ToBe(6);
  Expect<Integer>(Report.EvictableDocuments).ToBe(4);
  Expect<Int64>(Report.EvictableBytes).ToBe(SupersededBytes(Store));
  Expect<Integer>(Report.EvictedDocuments).ToBe(0);
  Expect<string>(HashTree(Store.Root)).ToBe(Before);
  Expect<Boolean>(FileExists(RegistryDocumentRecencyPath(Store.Root))).ToBe(False);
end;

procedure TRegistryStoreTests.TestBudgetParsing;

  function Failure(const AValue: string): string;
  begin
    Result := '';
    try
      ResolveRegistryStateMaxBytesFromValue(AValue);
    except
      on E: ELWPTRegistryError do Result := E.Message;
    end;
  end;

begin
  Expect<Int64>(ResolveRegistryStateMaxBytesFromValue(''))
    .ToBe(Int64(64) * 1024 * 1024);
  Expect<Int64>(RegistryStateDefaultMaxBytes)
    .ToBe(DefaultRegistryVerificationLimits.TotalBytes);
  Expect<Int64>(ResolveRegistryStateMaxBytesFromValue('0')).ToBe(0);
  Expect<Int64>(ResolveRegistryStateMaxBytesFromValue(' 1048576 ')).ToBe(1048576);
  Expect<Int64>(ResolveRegistryStateMaxBytesFromValue('9223372036854775807'))
    .ToBe(High(Int64));
  Expect<Boolean>(Pos('registry_state_budget_invalid', Failure('-1')) > 0).ToBe(True);
  Expect<Boolean>(Pos(REGISTRY_STATE_MAX_BYTES_ENV, Failure('abc')) > 0).ToBe(True);
  Expect<Boolean>(Failure('1.5') <> '').ToBe(True);
  Expect<Boolean>(Failure('$10') <> '').ToBe(True);
  Expect<Boolean>(Failure('0x10') <> '').ToBe(True);
  Expect<Boolean>(Failure('0X10') <> '').ToBe(True);
  Expect<Boolean>(Failure('+5') <> '').ToBe(True);
  Expect<Boolean>(Failure('1 0') <> '').ToBe(True);
  Expect<Boolean>(Failure('64MiB') <> '').ToBe(True);
  Expect<Boolean>(Pos('"9223372036854775808"', Failure('9223372036854775808')) > 0)
    .ToBe(True);
end;

procedure TRegistryStoreTests.SetupTests;
begin
  Test('the accepted snapshot chain, its records, and the accepted '
    + 'checkpoint and signature survive a zero budget',
    TestAcceptedHistoryIsNeverEvicted);
  Test('evictable documents leave least recently used first, only while '
    + 'over budget', TestEvictionIsLeastRecentlyUsed);
  Test('equal stamps evict the lower digest first',
    TestEqualStampsEvictTheLowerDigestFirst);
  Test('evictable bytes equal to the budget stay; one byte over evicts one',
    TestBudgetBoundaryIsExact);
  Test('use and first sight stamp recency; evicted documents leave the index '
    + 'on the next pass',
    TestRecencyStampsUseAndFirstSight);
  Test('foreign names, directories, and non-state files are never touched',
    TestForeignEntriesAreNeverTouched);
  Test('a forged small document is evicted and a corrupt index is rebuilt',
    TestCorruptDocumentsAndIndexAreHandledSafely);
  Test('a corrupt or missing accepted snapshot removes nothing',
    TestBrokenHistoryRemovesNothing);
  Test('a directory that cannot be listed removes nothing',
    TestUnlistableDirectoriesRemoveNothing);
  Test('links and special files are foreign, never opened or removed',
    TestLinksAndSpecialFilesAreForeign);
  Test('an unreadable document that could be a live signature removes nothing',
    TestUnreadableSmallDocumentRemovesNothing);
  Test('a removal that fails is retained, reported, and retried',
    TestFailedRemovalIsRetainedAndReported);
  Test('a failed index write removes nothing', TestIndexWriteFailureRemovesNothing);
  Test('an unreadable or misnamed state file blocks eviction',
    TestUnreadableStateBlocksEviction);
  Test('the history walk stays within the verifier''s limits',
    TestHistoryWalkIsBounded);
  Test('a reading pass reports and writes nothing', TestReadingPassWritesNothing);
  Test('the budget defaults to 64 MiB and invalid values fail clearly',
    TestBudgetParsing);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryStoreTests.Create(
    'registry consumer document store eviction'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
