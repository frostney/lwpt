{ LWPT.CacheLifecycle — aggregate per-user cache budgeting and recovery. }
unit LWPT.CacheLifecycle;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.ProducerLease;

const
  CACHE_MAX_BYTES_ENV = PROJECT_NAME + '_CACHE_MAX_BYTES';
  DEFAULT_CACHE_MAX_BYTES = Int64(10) * 1024 * 1024 * 1024;

type
  ELWPTCacheLifecycleError = class(ELWPTError);

  TLWPTCacheRepairReport = record
    BudgetBytes: Int64;
    BytesBefore: Int64;
    BytesAfter: Int64;
    BytesReclaimed: Int64;
    CorruptObjectsRemoved: Integer;
    IncompleteEntriesRemoved: Integer;
    AbandonedLeasesReclaimed: Integer;
    LiveObjectsPreserved: Integer;
    LiveLeasesPreserved: Integer;
    IndexRebuilt: Boolean;
  end;

  TLWPTCacheLifecycle = class
  private
    FCacheRoot: string;
    FCoordinator: TLWPTProducerLeaseCoordinator;
    FNamespace: string;
    function Acquire(const AKey: string): TObject;
    function Key(const ADigest: string): string;
  public
    constructor Create(const ACacheRoot, ANamespace: string);
    destructor Destroy; override;
    function AcquireMutation: TObject;
    function AcquireObject(const ADigest: string): TObject;
    { Makes room for AAdditionalBytes the caller writes next, under the
      mutation guard, and counts them in the usage ledger when it does. }
    function MakeRoomLocked(const AAdditionalBytes: Int64): Boolean;
    procedure DiscardObjectLocked(const ADigest, AObjectPath: string);
    procedure RecordObjectLocked(const ADigest, AObjectPath: string);
    procedure TouchObjectLocked(const ADigest: string);
  end;

function ResolveCacheMaxBytes: Int64;
function ResolveCacheMaxBytesFromValue(const AValue: string): Int64;
{ The size eviction brings the cache down to once it has to evict: one
  band (a tenth of the budget) below it, so the walk and reference scan
  that eviction needs run once per band of admissions, not on each. }
function CacheLowWaterBytes(const ABudget: Int64): Int64;
function RepairSharedCache(const ACacheRoot: string):
  TLWPTCacheRepairReport;

{$IFDEF OBJECTSTORE_TESTING}
type
  TLWPTCacheEvictionTestHook = procedure(const ACacheRoot: string);

var
  { Runs after each eviction attempt, before the next budget check, so a
    test can change unguarded staging bytes at a deterministic point. }
  CacheLifecycleAfterEvictionTestHook: TLWPTCacheEvictionTestHook;
  { Counts authoritative budget enforcements (cache walks), so a test can
    show that admissions stop walking the cache once it is measured. }
  CacheLifecycleEnforcementCount: Integer;
  { Counts walks of the build references, so a test can show that one
    eviction batch collects them once however many objects it evicts. }
  CacheLifecycleReferenceCollectionCount: Integer;
{$ENDIF}

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  LWPT.BuildResultManifest;

const
  CACHE_LIFECYCLE_NAMESPACE = 'lifecycle';
  CACHE_INDEX_SCHEMA = 1;
  CACHE_LEDGER_SCHEMA = 1;
  { The ledger is padded to exactly this size, so rewriting it never moves
    the measured total and a walk can count it before it exists. }
  CACHE_LEDGER_BYTES = 256;
  CACHE_MANIFEST_SCHEMA = 1;
  DEPENDENCY_NAMESPACE = 'dependency-archives';
  BUILD_NAMESPACE = 'build-results';

type
  TLWPTCacheObject = record
    Namespace: string;
    Digest: string;
    Path: string;
    Size: Int64;
    LastUse: Int64;
  end;

  TLWPTCacheObjectArray = array of TLWPTCacheObject;

function LifecycleRoot(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + CACHE_LIFECYCLE_NAMESPACE;
end;

function IndexPath(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(LifecycleRoot(ACacheRoot))
    + 'index';
end;

function LedgerPath(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(LifecycleRoot(ACacheRoot))
    + 'usage';
end;

function LifecycleTemporaryRoot(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(LifecycleRoot(ACacheRoot))
    + 'tmp';
end;

function ObjectKey(const ANamespace, ADigest: string): string;
begin
  Result := ANamespace + ':' + LowerCase(ADigest);
end;

function ManifestPath(const ACacheRoot, ANamespace,
  ADigest: string): string;
var
  Hex: string;
begin
  Hex := Copy(ADigest, 8, MaxInt);
  Result := IncludeTrailingPathDelimiter(LifecycleRoot(ACacheRoot))
    + 'manifests/' + ANamespace + '/sha256/' + Copy(Hex, 1, 2)
    + '/' + Copy(Hex, 3, MaxInt);
end;

function IsLowerHex(const AValue: string): Boolean;
var
  Index: Integer;
begin
  if Length(AValue) <> 64 then Exit(False);
  for Index := 1 to Length(AValue) do
    if not (AValue[Index] in ['0'..'9', 'a'..'f']) then Exit(False);
  Result := True;
end;

function ResolveCacheMaxBytesFromValue(const AValue: string): Int64;
var
  Parsed: QWord;
  Value: string;
begin
  Value := Trim(AValue);
  if Value = '' then Exit(DEFAULT_CACHE_MAX_BYTES);
  if not TryStrToQWord(Value, Parsed)
     or (Parsed > QWord(High(Int64))) then
    raise ELWPTCacheLifecycleError.CreateFmt(
      '%s must be an integer from 0 through %d bytes, got "%s"',
      [CACHE_MAX_BYTES_ENV, High(Int64), AValue]);
  Result := Int64(Parsed);
end;

{$IFDEF UNIX}
function CGetEnvironmentVariable(AName: PAnsiChar): PAnsiChar; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'getenv';
  {$ELSE}
  external name 'getenv';
  {$ENDIF}
{$ENDIF}

function LiveEnvironmentVariable(const AName: string): string;
{$IFDEF UNIX}
var
  Name: AnsiString;
  Value: PAnsiChar;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Name, Value: UnicodeString;
  Required, Written: DWORD;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Name := AnsiString(AName);
  Value := CGetEnvironmentVariable(PAnsiChar(Name));
  if Value = nil then Exit('');
  Result := string(AnsiString(Value));
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Name := UnicodeString(AName);
  Required := Windows.GetEnvironmentVariableW(PWideChar(Name), nil, 0);
  if Required = 0 then Exit('');
  SetLength(Value, Required);
  Written := Windows.GetEnvironmentVariableW(PWideChar(Name),
    PWideChar(Value), Required);
  if Written = 0 then Exit('');
  SetLength(Value, Written);
  Result := string(Value);
  {$ENDIF}
end;

function ResolveCacheMaxBytes: Int64;
begin
  Result := ResolveCacheMaxBytesFromValue(
    LiveEnvironmentVariable(CACHE_MAX_BYTES_ENV));
end;

function CacheLowWaterBytes(const ABudget: Int64): Int64;
begin
  if ABudget <= 0 then Exit(0);
  Result := ABudget - ABudget div 10;
end;

function ReadSmallTextFile(const APath: string;
  out AText: string): Boolean;
const
  MAX_CONTROL_BYTES = 16 * 1024 * 1024;
var
  Bytes: TBytes;
  Stream: TLWPTProtectedFileStream;
begin
  Result := False;
  AText := '';
  try
    Stream := OpenProtectedFileStream(APath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size > MAX_CONTROL_BYTES then Exit;
      SetLength(Bytes, Stream.Size);
      if Stream.Size > 0 then Stream.ReadBuffer(Bytes[0], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    on E: EFOpenError do Exit;
    on E: EInOutError do Exit;
    on E: EReadError do Exit;
  end;
  SetLength(AText, Length(Bytes));
  if Length(Bytes) > 0 then Move(Bytes[0], AText[1], Length(Bytes));
  Result := True;
end;

{ A sorted view over an entry list's names, for O(log n) lookups where
  TStrings.Values[] / IndexOfName would scan. Objects[] carries the index
  into the entry list it was built from; the list must not be reordered
  or shrunk while the lookup is in use. The names are appended unsorted
  and sorted once: inserting each one into a sorted list shifts the tail,
  which is quadratic whenever the entries do not arrive in order. }
function BuildNameLookup(const AEntries: TStringList): TStringList;
var
  Index: Integer;
begin
  Result := TStringList.Create;
  Result.Capacity := AEntries.Count;
  for Index := 0 to AEntries.Count - 1 do
    Result.AddObject(AEntries.Names[Index], TObject(PtrInt(Index)));
  Result.Sorted := True;
end;

{ Orders parsed index names as TStringList's default name comparison does
  (case-insensitive, locale-aware), then by the line they came from, so a
  repeated name forms one run whose last member is its last write. }
function CompareIndexNameThenLine(AList: TStringList; AIndex1,
  AIndex2: Integer): Integer;
var
  Left, Right: PtrInt;
begin
  Result := AnsiCompareText(AList[AIndex1], AList[AIndex2]);
  if Result <> 0 then Exit;
  Left := PtrInt(AList.Objects[AIndex1]);
  Right := PtrInt(AList.Objects[AIndex2]);
  if Left < Right then
    Result := -1
  else if Left > Right then
    Result := 1;
end;

function LookupEntryIndex(const ALookup: TStringList;
  const AName: string): Integer;
var
  Position: Integer;
begin
  if ALookup.Find(AName, Position) then
    Result := Integer(PtrInt(ALookup.Objects[Position]))
  else
    Result := -1;
end;

procedure LoadIndex(const ACacheRoot: string; out ASequence: Int64;
  const AEntries: TStringList; out AValid: Boolean);
var
  Lines, Parsed: TStringList;
  Index, Separator: Integer;
  Line, Name, Text: string;
  Value: Int64;
  Values: array of Int64;
begin
  AEntries.Clear;
  ASequence := 0;
  AValid := False;
  if not ReadSmallTextFile(IndexPath(ACacheRoot), Text) then Exit;
  Lines := TStringList.Create;
  Parsed := TStringList.Create;
  try
    { Values[Name] := ... scans every earlier entry, so a large index
      loaded that way costs O(n^2) on every cache hit. Parse every line
      first, sort the names once with their line numbers as a tie-break,
      and keep the last value of each name: the same last-write-wins
      result in O(n log n) whatever order the lines arrive in. }
    Lines.Text := Text;
    if (Lines.Count < 2) or (Lines[0] <> 'schema=' +
       IntToStr(CACHE_INDEX_SCHEMA)) then Exit;
    if Copy(Lines[1], 1, 9) <> 'sequence=' then Exit;
    if not TryStrToInt64(Copy(Lines[1], 10, MaxInt), ASequence)
       or (ASequence < 0) then Exit;
    SetLength(Values, Lines.Count);
    Parsed.Capacity := Lines.Count;
    for Index := 2 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      if Line = '' then Continue;
      Separator := LastDelimiter('=', Line);
      if Separator <= 7 then Exit;
      Name := Copy(Line, 1, Separator - 1);
      if Copy(Name, 1, 6) <> 'entry.' then Exit;
      Delete(Name, 1, 6);
      if not TryStrToInt64(Copy(Line, Separator + 1, MaxInt), Value)
         or (Value < 0) then Exit;
      Values[Index] := Value;
      Parsed.AddObject(Name, TObject(PtrInt(Index)));
    end;
    Parsed.CustomSort(CompareIndexNameThenLine);
    { Each run of one name keeps its last row, spelling and value, exactly
      as repeated Values[Name] := ... assignments (TStrings.SetValue) did. }
    for Index := 0 to Parsed.Count - 1 do
    begin
      if (Index < Parsed.Count - 1)
         and (AnsiCompareText(Parsed[Index], Parsed[Index + 1]) = 0) then
        Continue;
      AEntries.Add(Parsed[Index] + '='
        + IntToStr(Values[PtrInt(Parsed.Objects[Index])]));
    end;
    AValid := True;
  finally
    Parsed.Free;
    Lines.Free;
  end;
end;

{ Sets one entry of an index LoadIndex returned, which holds each name
  once in its name order: a binary search where Values[] would scan every
  entry. Like Values[], an existing name takes the new spelling. }
procedure SetIndexEntry(const AEntries: TStringList; const AName,
  AValue: string);
var
  Comparison, High, Low, Middle: Integer;
begin
  Low := 0;
  High := AEntries.Count - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    Comparison := AnsiCompareText(AEntries.Names[Middle], AName);
    if Comparison = 0 then
    begin
      AEntries[Middle] := AName + '=' + AValue;
      Exit;
    end;
    if Comparison < 0 then Low := Middle + 1
    else High := Middle - 1;
  end;
  AEntries.Insert(Low, AName + '=' + AValue);
end;

procedure WriteIndex(const ACacheRoot: string; const ASequence: Int64;
  const AEntries: TStringList);
var
  Index: Integer;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema=' + IntToStr(CACHE_INDEX_SCHEMA));
    Lines.Add('sequence=' + IntToStr(ASequence));
    AEntries.Sort;
    { Each entry is already its name, the separator and its value. }
    for Index := 0 to AEntries.Count - 1 do
      Lines.Add('entry.' + AEntries[Index]);
    ForceDirectories(LifecycleTemporaryRoot(ACacheRoot));
    { One write of the whole text: TStrings.SaveToStream writes each line
      and each line break separately, two system calls per index entry on
      every access. }
    AtomicWriteBytes(IndexPath(ACacheRoot),
      LifecycleTemporaryRoot(ACacheRoot), BytesOf(Lines.Text));
  finally
    Lines.Free;
  end;
end;

function IndexByteSize(const ASequence: Int64;
  const AEntries: TStringList): Int64;
var
  Index: Integer;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema=' + IntToStr(CACHE_INDEX_SCHEMA));
    Lines.Add('sequence=' + IntToStr(ASequence));
    AEntries.Sort;
    for Index := 0 to AEntries.Count - 1 do
      Lines.Add('entry.' + AEntries[Index]);
    Result := Length(RawByteString(Lines.Text));
  finally
    Lines.Free;
  end;
end;

function FileByteSize(const APath: string): Int64;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(APath, faAnyFile, Search) <> 0 then Exit;
  try
    if (Search.Attr and faDirectory) = 0 then Result := Search.Size;
  finally
    SysUtils.FindClose(Search);
  end;
end;

{ The usage ledger: the cache's byte total as last measured by a walk,
  plus every change guarded writers made since. It is trusted only while
  the index it was written against is still current, so a writer that does
  not keep it (an older LWPT, or a crash between the index and ledger
  writes) invalidates it, and the next admission measures the tree. Growth
  counts the bytes added since that measurement; once it exceeds one band,
  the next admission measures again, which bounds how long bytes no guarded
  writer reports (crash residue, producer metadata) can go uncounted. }
type
  TLWPTCacheLedger = record
    Bytes: Int64;
    Growth: Int64;
  end;

{ The index's sequence and byte size, without parsing its entries. A
  missing index has sequence -1; an unreadable header makes it unknown. }
function ReadIndexIdentity(const ACacheRoot: string; out ASequence,
  ABytes: Int64): Boolean;
const
  HEADER_BYTES = 64;
var
  Buffer: RawByteString;
  Count, LineEnd: Integer;
  Header: string;
  Stream: TLWPTProtectedFileStream;
begin
  Result := False;
  ASequence := -1;
  ABytes := 0;
  if not FileExists(IndexPath(ACacheRoot)) then Exit(True);
  try
    Stream := OpenProtectedFileStream(IndexPath(ACacheRoot),
      fmOpenRead or fmShareDenyNone);
    try
      ABytes := Stream.Size;
      Count := HEADER_BYTES;
      if ABytes < Count then Count := Integer(ABytes);
      SetLength(Buffer, Count);
      if Count > 0 then Stream.ReadBuffer(Buffer[1], Count);
    finally
      Stream.Free;
    end;
  except
    on E: EFOpenError do Exit;
    on E: EInOutError do Exit;
    on E: EReadError do Exit;
  end;
  Header := 'schema=' + IntToStr(CACHE_INDEX_SCHEMA) + #10'sequence=';
  if Copy(string(Buffer), 1, Length(Header)) <> Header then Exit;
  Delete(Buffer, 1, Length(Header));
  LineEnd := Pos(#10, string(Buffer));
  if LineEnd <= 1 then Exit;
  Result := TryStrToInt64(Copy(string(Buffer), 1, LineEnd - 1), ASequence)
    and (ASequence >= 0);
end;

{ The ledger's size when it is a regular file, and -1 for a link or any
  other entry. A walk skips links, so only a regular ledger's bytes are in
  its total, and only a regular ledger is ever trusted. 0 when absent. }
function LedgerFileBytes(const ACacheRoot: string): Int64;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(LedgerPath(ACacheRoot), faAnyFile or faSymLink,
       Search) <> 0 then Exit;
  try
    if ((Search.Attr and (faSymLink or faDirectory)) <> 0)
       or IsDirSymlinkOrJunction(LedgerPath(ACacheRoot)) then
      Result := -1
    else
      Result := Search.Size;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function LoadLedger(const ACacheRoot: string;
  out ALedger: TLWPTCacheLedger): Boolean;
var
  IndexBytes, IndexSequence: Int64;
  Lines: TStringList;
  Text: string;
begin
  Result := False;
  ALedger := Default(TLWPTCacheLedger);
  if LedgerFileBytes(ACacheRoot) <> CACHE_LEDGER_BYTES then Exit;
  if not ReadSmallTextFile(LedgerPath(ACacheRoot), Text) then Exit;
  if not ReadIndexIdentity(ACacheRoot, IndexSequence, IndexBytes) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    Result := (Lines.Values['schema'] = IntToStr(CACHE_LEDGER_SCHEMA))
      and (Lines.Values['index-sequence'] = IntToStr(IndexSequence))
      and (Lines.Values['index-bytes'] = IntToStr(IndexBytes))
      and TryStrToInt64(Lines.Values['bytes'], ALedger.Bytes)
      and TryStrToInt64(Lines.Values['growth'], ALedger.Growth)
      and (ALedger.Bytes >= 0) and (ALedger.Growth >= 0);
  finally
    Lines.Free;
  end;
end;

{ Removes whatever entry holds the ledger's name without following it: a
  link is unlinked and a directory is wiped, so nothing outside the cache
  is touched and the next write can publish a regular ledger. }
procedure DropLedger(const ACacheRoot: string);
var
  Attributes: LongInt;
  Path: string;
  Search: TSearchRec;
begin
  Path := LedgerPath(ACacheRoot);
  if FindFirst(Path, faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    Attributes := Search.Attr;
  finally
    SysUtils.FindClose(Search);
  end;
  if (((Attributes and faDirectory) <> 0)
      and ((Attributes and faSymLink) = 0))
     or IsDirSymlinkOrJunction(Path) then
    WipeDir(Path)
  else
    SysUtils.DeleteFile(Path);
  if FindFirst(Path, faAnyFile or faSymLink, Search) = 0 then
  begin
    SysUtils.FindClose(Search);
    raise ELWPTCacheLifecycleError.CreateFmt(
      'failed to remove stale cache usage ledger %s', [Path]);
  end;
end;

{ Records ABytes against the current index. The ledger itself always
  counts as CACHE_LEDGER_BYTES, the exact size it is padded to. }
procedure StoreLedger(const ACacheRoot: string; const ABytes,
  AGrowth: Int64);
var
  IndexBytes, IndexSequence: Int64;
  Lines: TStringList;
  Padding: Integer;
begin
  if not ReadIndexIdentity(ACacheRoot, IndexSequence, IndexBytes) then
  begin
    DropLedger(ACacheRoot);
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema=' + IntToStr(CACHE_LEDGER_SCHEMA));
    Lines.Add('index-sequence=' + IntToStr(IndexSequence));
    Lines.Add('index-bytes=' + IntToStr(IndexBytes));
    if ABytes < 0 then Lines.Add('bytes=0')
    else Lines.Add('bytes=' + IntToStr(ABytes));
    if AGrowth < 0 then Lines.Add('growth=0')
    else Lines.Add('growth=' + IntToStr(AGrowth));
    Padding := CACHE_LEDGER_BYTES - Length(Lines.Text) - Length('pad=') - 1;
    if Padding < 0 then
      raise ELWPTCacheLifecycleError.Create(
        'cache usage ledger exceeds its fixed size');
    Lines.Add('pad=' + StringOfChar('0', Padding));
    ForceDirectories(LifecycleTemporaryRoot(ACacheRoot));
    AtomicWriteText(LedgerPath(ACacheRoot),
      LifecycleTemporaryRoot(ACacheRoot), Lines);
  finally
    Lines.Free;
  end;
end;

{ Applies ADelta bytes to a ledger loaded before the change, or drops a
  ledger that was already untrusted so it cannot match a later index. }
procedure AccountLedger(const ACacheRoot: string; const ATrusted: Boolean;
  const ALedger: TLWPTCacheLedger; const ADelta: Int64);
var
  Growth: Int64;
begin
  if not ATrusted then
  begin
    DropLedger(ACacheRoot);
    Exit;
  end;
  Growth := ALedger.Growth;
  if ADelta > 0 then Inc(Growth, ADelta);
  StoreLedger(ACacheRoot, ALedger.Bytes + ADelta, Growth);
end;

procedure WriteManifest(const ACacheRoot, ANamespace, ADigest,
  AObjectPath: string; const ASize: Int64);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Add('schema=' + IntToStr(CACHE_MANIFEST_SCHEMA));
    Lines.Add('namespace=' + ANamespace);
    Lines.Add('digest=' + LowerCase(ADigest));
    Lines.Add('size=' + IntToStr(ASize));
    Lines.Add('object=' + AObjectPath);
    ForceDirectories(ExtractFileDir(ManifestPath(ACacheRoot,
      ANamespace, ADigest)));
    ForceDirectories(LifecycleTemporaryRoot(ACacheRoot));
    AtomicWriteText(ManifestPath(ACacheRoot, ANamespace, ADigest),
      LifecycleTemporaryRoot(ACacheRoot), Lines);
  finally
    Lines.Free;
  end;
end;

function ManifestIsVerified(const ACacheRoot: string;
  const AObject: TLWPTCacheObject): Boolean;
var
  Lines: TStringList;
  Text: string;
begin
  Result := False;
  if not ReadSmallTextFile(ManifestPath(ACacheRoot,
       AObject.Namespace, AObject.Digest), Text) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    Result := (StrToIntDef(Lines.Values['schema'], 0)
      = CACHE_MANIFEST_SCHEMA)
      and (Lines.Values['namespace'] = AObject.Namespace)
      and (Lines.Values['digest'] = AObject.Digest)
      and (StrToInt64Def(Lines.Values['size'], -1) = AObject.Size)
      and (Lines.Values['object'] = AObject.Path);
  finally
    Lines.Free;
  end;
end;

procedure AppendObjects(const AObjectRoot, ANamespace: string;
  var AObjects: TLWPTCacheObjectArray);
var
  Hex, Path, PrefixPath, SHA256Root: string;
  Item: TLWPTCacheObject;
  PrefixSearch, ObjectSearch: TSearchRec;
  LengthBefore: Integer;
begin
  if IsDirSymlinkOrJunction(AObjectRoot) then Exit;
  SHA256Root := IncludeTrailingPathDelimiter(AObjectRoot) + 'sha256';
  if IsDirSymlinkOrJunction(SHA256Root) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(SHA256Root) + '*',
       faAnyFile or faSymLink, PrefixSearch) <> 0 then Exit;
  try
    repeat
      if (PrefixSearch.Name = '.') or (PrefixSearch.Name = '..')
         or ((PrefixSearch.Attr and faDirectory) = 0)
         or ((PrefixSearch.Attr and faSymLink) <> 0)
         or IsDirSymlinkOrJunction(IncludeTrailingPathDelimiter(SHA256Root)
           + PrefixSearch.Name)
         or (Length(PrefixSearch.Name) <> 2) then Continue;
      PrefixPath := IncludeTrailingPathDelimiter(SHA256Root)
        + PrefixSearch.Name;
      if FindFirst(IncludeTrailingPathDelimiter(PrefixPath) + '*',
           faAnyFile or faSymLink, ObjectSearch) <> 0 then Continue;
      try
        repeat
          if (ObjectSearch.Name = '.') or (ObjectSearch.Name = '..')
             or ((ObjectSearch.Attr and faDirectory) <> 0)
             or ((ObjectSearch.Attr and faSymLink) <> 0) then Continue;
          Hex := LowerCase(PrefixSearch.Name + ObjectSearch.Name);
          if not IsLowerHex(Hex) then Continue;
          Path := IncludeTrailingPathDelimiter(PrefixPath)
            + ObjectSearch.Name;
          Item := Default(TLWPTCacheObject);
          Item.Namespace := ANamespace;
          Item.Digest := 'sha256:' + Hex;
          Item.Path := Path;
          Item.Size := ObjectSearch.Size;
          LengthBefore := Length(AObjects);
          SetLength(AObjects, LengthBefore + 1);
          AObjects[LengthBefore] := Item;
        until FindNext(ObjectSearch) <> 0;
      finally
        SysUtils.FindClose(ObjectSearch);
      end;
    until FindNext(PrefixSearch) <> 0;
  finally
    SysUtils.FindClose(PrefixSearch);
  end;
end;

function DiscoverObjects(const ACacheRoot: string): TLWPTCacheObjectArray;
var
  BuildRoot, DependencyRoot: string;
begin
  Result := nil;
  DependencyRoot := IncludeTrailingPathDelimiter(ACacheRoot)
    + DEPENDENCY_NAMESPACE;
  BuildRoot := IncludeTrailingPathDelimiter(ACacheRoot) + BUILD_NAMESPACE;
  if not IsDirSymlinkOrJunction(DependencyRoot) then
    AppendObjects(DependencyRoot, DEPENDENCY_NAMESPACE, Result);
  if not IsDirSymlinkOrJunction(BuildRoot) then
    AppendObjects(BuildRoot + '/objects', BUILD_NAMESPACE, Result);
end;

function DirectoryBytes(const APath: string): Int64; forward;

function IndexMatchesObjects(const AObjects: TLWPTCacheObjectArray;
  const AEntries: TStringList; const ASequence: Int64): Boolean;
var
  Index: Integer;
  KeyName, ValueText: string;
  Value: Int64;
begin
  Result := False;
  if AEntries.Count <> Length(AObjects) then Exit;
  for Index := 0 to High(AObjects) do
  begin
    KeyName := ObjectKey(AObjects[Index].Namespace,
      AObjects[Index].Digest);
    if AEntries.IndexOfName(KeyName) < 0 then Exit;
    ValueText := AEntries.Values[KeyName];
    if not TryStrToInt64(ValueText, Value) or (Value < 0)
       or (Value > ASequence) then Exit;
  end;
  Result := True;
end;

procedure RebuildIndexFromObjects(const AObjects: TLWPTCacheObjectArray;
  const AEntries: TStringList; out ASequence: Int64);
var
  Index: Integer;
begin
  AEntries.Clear;
  ASequence := 0;
  for Index := 0 to High(AObjects) do
    AEntries.Values[ObjectKey(AObjects[Index].Namespace,
      AObjects[Index].Digest)] := '0';
end;

{ Least recently used first; ties (such as unindexed objects at 0) by
  object key, so the order is total and eviction is deterministic. }
function CompareLRU(const ALeft, ARight: TLWPTCacheObject): Integer;
begin
  if ALeft.LastUse < ARight.LastUse then Exit(-1);
  if ALeft.LastUse > ARight.LastUse then Exit(1);
  Result := CompareStr(ObjectKey(ALeft.Namespace, ALeft.Digest),
    ObjectKey(ARight.Namespace, ARight.Digest));
end;

{ Bottom-up merge sort: O(n log n) whatever order discovery returned the
  objects in, where the insertion sort it replaces was quadratic. }
procedure SortByLRU(var AObjects: TLWPTCacheObjectArray);
var
  Count, Left, Middle, Right, Width, LeftIndex, RightIndex,
    Target: Integer;
  Scratch, Swap: TLWPTCacheObjectArray;
begin
  Count := Length(AObjects);
  if Count < 2 then Exit;
  SetLength(Scratch, Count);
  Width := 1;
  while Width < Count do
  begin
    Left := 0;
    while Left < Count do
    begin
      Middle := Left + Width;
      if Middle > Count then Middle := Count;
      Right := Middle + Width;
      if Right > Count then Right := Count;
      LeftIndex := Left;
      RightIndex := Middle;
      for Target := Left to Right - 1 do
        if (RightIndex >= Right) or ((LeftIndex < Middle) and
           (CompareLRU(AObjects[LeftIndex], AObjects[RightIndex]) <= 0)) then
        begin
          Scratch[Target] := AObjects[LeftIndex];
          Inc(LeftIndex);
        end
        else
        begin
          Scratch[Target] := AObjects[RightIndex];
          Inc(RightIndex);
        end;
      Left := Right;
    end;
    Swap := AObjects;
    AObjects := Scratch;
    Scratch := Swap;
    if Width > Count div 2 then Break;
    Width := Width * 2;
  end;
end;

function BuildReferenceSHA256Root(const ACacheRoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + BUILD_NAMESPACE + '/refs/sha256';
end;

function FindObjectPath(const AObjects: TLWPTCacheObjectArray;
  const ANamespace, ADigest: string; out APath: string): Boolean;
var
  Index: Integer;
begin
  APath := '';
  for Index := 0 to High(AObjects) do
    if (AObjects[Index].Namespace = ANamespace)
       and (AObjects[Index].Digest = ADigest) then
    begin
      APath := AObjects[Index].Path;
      Exit(True);
    end;
  Result := False;
end;

function BuildReferenceFingerprint(const APrefix,
  AEntry: string): string;
var
  Hex: string;
begin
  Hex := APrefix + AEntry;
  if not IsLowerHex(Hex) then Exit('');
  Result := 'sha256:' + Hex;
end;

function BuildObjectPath(const ACacheRoot, ADigest: string): string;
var
  Hex: string;
begin
  Hex := Copy(ADigest, 8, MaxInt);
  Result := IncludeTrailingPathDelimiter(ACacheRoot)
    + BUILD_NAMESPACE + '/objects/sha256/' + Copy(Hex, 1, 2)
    + '/' + Copy(Hex, 3, MaxInt);
end;

function ReadCanonicalBuildReference(const APath: string;
  out ADigest: string): Boolean;
var
  Text: string;
begin
  ADigest := '';
  if not ReadSmallTextFile(APath, Text) then Exit(False);
  ADigest := CanonicalBuildCacheDigest(Trim(Text));
  Result := (ADigest <> '') and (Trim(Text) = ADigest);
end;

function FindFirstMeansNoEntry(const AResult: Integer): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := AResult in [Windows.ERROR_FILE_NOT_FOUND,
    Windows.ERROR_PATH_NOT_FOUND, Windows.ERROR_NO_MORE_FILES];
  {$ELSE}
  Result := (AResult = -1) and (FpGetErrNo = ESysENOENT);
  {$ENDIF}
end;

function FindNextFinished(var ASearch: TSearchRec;
  out AResult: Integer): Boolean;
begin
  AResult := FindNext(ASearch);
  Result := AResult <> 0;
end;

function FindNextMeansEnd(const AResult: Integer): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := AResult = Windows.ERROR_NO_MORE_FILES;
  {$ELSE}
  { FPC 3.2.2 collapses both end-of-directory and errors to -1 on POSIX. }
  Result := AResult = -1;
  {$ENDIF}
end;

function CacheEntryExists(const APath: string): Boolean;
var
  FindResult: Integer;
  Search: TSearchRec;
begin
  FindResult := FindFirst(APath, faAnyFile or faSymLink, Search);
  Result := FindResult = 0;
  if Result then
    SysUtils.FindClose(Search)
  else if not FindFirstMeansNoEntry(FindResult) then
    raise ELWPTCacheLifecycleError.CreateFmt(
      'failed to verify removal of build-cache reference %s', [APath]);
end;

procedure RemoveBuildReferenceEntry(const APath: string;
  const AAttributes: LongInt);
begin
  if ((AAttributes and faDirectory) <> 0)
     or IsDirSymlinkOrJunction(APath) then
    WipeDir(APath)
  else
    SysUtils.DeleteFile(APath);
  if CacheEntryExists(APath) then
    raise ELWPTCacheLifecycleError.CreateFmt(
      'failed to remove invalid build-cache reference %s', [APath]);
end;

{ The reference edges of one eviction batch (or one explicit removal),
  collected by a single walk of the build references when the batch first
  removes a build object.
  Rescanning every reference for each evicted object made eviction cost
  the number of references times the number of evictions. The collection
  stays exact for the whole batch because references are only written and
  removed under the mutation guard the batch holds. Each reference names
  its result manifest directly and, through a verified manifest that
  binds its own fingerprint, that manifest's artifact. A reference that
  cannot be read that far is removed, as the per-object scan removed it;
  when the walk is incomplete or such a reference cannot be removed, no
  build object is removed for the rest of the batch. }
type
  TLWPTBuildReferenceEdge = record
    Path: string;
    Attributes: LongInt;
    Size: Int64;
    Removed: Boolean;
  end;

  TLWPTBuildReferenceEdges = class
  private
    FCacheRoot: string;
    FCollected: Boolean;
    FComplete: Boolean;
    FReferences: array of TLWPTBuildReferenceEdge;
    FTargets: TStringList;
    procedure AddReference(const APath: string; const AAttributes: LongInt;
      const ASize: Int64; const ATargets: array of string);
    procedure Collect(var AFreedBytes: Int64);
    function RemoveReference(const AIndex: Integer;
      var AFreedBytes: Int64): Boolean;
  public
    constructor Create(const ACacheRoot: string);
    destructor Destroy; override;
    function RemoveReferencesFor(const ADigest: string;
      var AFreedBytes: Int64): Boolean;
  end;

constructor TLWPTBuildReferenceEdges.Create(const ACacheRoot: string);
begin
  inherited Create;
  FCacheRoot := ACacheRoot;
  FTargets := TStringList.Create;
  FTargets.CaseSensitive := True;
end;

destructor TLWPTBuildReferenceEdges.Destroy;
begin
  FTargets.Free;
  inherited Destroy;
end;

procedure TLWPTBuildReferenceEdges.AddReference(const APath: string;
  const AAttributes: LongInt; const ASize: Int64;
  const ATargets: array of string);
var
  Index, Position: Integer;
begin
  Position := Length(FReferences);
  SetLength(FReferences, Position + 1);
  FReferences[Position].Path := APath;
  FReferences[Position].Attributes := AAttributes;
  FReferences[Position].Size := ASize;
  FReferences[Position].Removed := False;
  for Index := 0 to High(ATargets) do
    FTargets.AddObject(ATargets[Index], TObject(PtrInt(Position)));
end;

function TLWPTBuildReferenceEdges.RemoveReference(const AIndex: Integer;
  var AFreedBytes: Int64): Boolean;
begin
  Result := True;
  if FReferences[AIndex].Removed then Exit;
  try
    RemoveBuildReferenceEntry(FReferences[AIndex].Path,
      FReferences[AIndex].Attributes);
    FReferences[AIndex].Removed := True;
    Inc(AFreedBytes, FReferences[AIndex].Size);
  except
    on ELWPTCacheLifecycleError do Result := False;
  end;
end;

procedure TLWPTBuildReferenceEdges.Collect(var AFreedBytes: Int64);
var
  EntryPath, Fingerprint, ManifestDigest, PrefixPath, Root: string;
  EntrySearch, PrefixSearch: TSearchRec;
  FindResult, Index: Integer;
  Manifest: TLWPTCachedBuildResult;
  Malformed: array of Integer;
begin
  FCollected := True;
  FComplete := True;
  Malformed := nil;
  {$IFDEF OBJECTSTORE_TESTING}
  Inc(CacheLifecycleReferenceCollectionCount);
  {$ENDIF}
  Root := BuildReferenceSHA256Root(FCacheRoot);
  if IsDirSymlinkOrJunction(Root) then
  begin
    FComplete := False;
    Exit;
  end;
  FindResult := FindFirst(IncludeTrailingPathDelimiter(Root) + '*',
    faAnyFile or faSymLink, PrefixSearch);
  if FindResult <> 0 then
  begin
    if not FindFirstMeansNoEntry(FindResult) then FComplete := False;
    Exit;
  end;
  try
    repeat
      if (PrefixSearch.Name = '.') or (PrefixSearch.Name = '..') then
        Continue;
      if ((PrefixSearch.Attr and faDirectory) = 0)
         or ((PrefixSearch.Attr and faSymLink) <> 0) then
      begin
        FComplete := False;
        Continue;
      end;
      PrefixPath := IncludeTrailingPathDelimiter(Root) + PrefixSearch.Name;
      if IsDirSymlinkOrJunction(PrefixPath) then
      begin
        FComplete := False;
        Continue;
      end;
      FindResult := FindFirst(IncludeTrailingPathDelimiter(PrefixPath) + '*',
        faAnyFile or faSymLink, EntrySearch);
      if FindResult <> 0 then
      begin
        if not FindFirstMeansNoEntry(FindResult) then FComplete := False;
        Continue;
      end;
      try
        repeat
          if (EntrySearch.Name = '.') or (EntrySearch.Name = '..') then
            Continue;
          if ((EntrySearch.Attr and faDirectory) <> 0)
             or ((EntrySearch.Attr and faSymLink) <> 0) then
          begin
            FComplete := False;
            Continue;
          end;
          EntryPath := IncludeTrailingPathDelimiter(PrefixPath)
            + EntrySearch.Name;
          Fingerprint := BuildReferenceFingerprint(PrefixSearch.Name,
            EntrySearch.Name);
          if not ReadCanonicalBuildReference(EntryPath, ManifestDigest) then
          begin
            AddReference(EntryPath, EntrySearch.Attr, EntrySearch.Size, []);
            SetLength(Malformed, Length(Malformed) + 1);
            Malformed[High(Malformed)] := High(FReferences);
            Continue;
          end;
          if ReadVerifiedBuildResultManifest(BuildObjectPath(FCacheRoot,
               ManifestDigest), ManifestDigest, Manifest)
             and (Manifest.Fingerprint = Fingerprint) then
            AddReference(EntryPath, EntrySearch.Attr, EntrySearch.Size,
              [ManifestDigest, Manifest.ArtifactDigest])
          else
          begin
            AddReference(EntryPath, EntrySearch.Attr, EntrySearch.Size,
              [ManifestDigest]);
            SetLength(Malformed, Length(Malformed) + 1);
            Malformed[High(Malformed)] := High(FReferences);
          end;
        until FindNextFinished(EntrySearch, FindResult);
        if not FindNextMeansEnd(FindResult) then FComplete := False;
      finally
        SysUtils.FindClose(EntrySearch);
      end;
    until FindNextFinished(PrefixSearch, FindResult);
    if not FindNextMeansEnd(FindResult) then FComplete := False;
  finally
    SysUtils.FindClose(PrefixSearch);
  end;
  for Index := 0 to High(Malformed) do
    if not RemoveReference(Malformed[Index], AFreedBytes) then
      FComplete := False;
end;

{ AFreedBytes is increased by the size of every reference this call
  removed, including when the result reports failure. }
function TLWPTBuildReferenceEdges.RemoveReferencesFor(
  const ADigest: string; var AFreedBytes: Int64): Boolean;
var
  First, Last, Position: Integer;
begin
  if not FCollected then
  begin
    Collect(AFreedBytes);
    FTargets.Sorted := True;
  end;
  Result := FComplete;
  if not FTargets.Find(ADigest, Position) then Exit;
  First := Position;
  while (First > 0) and (FTargets[First - 1] = ADigest) do Dec(First);
  Last := Position;
  while (Last < FTargets.Count - 1) and (FTargets[Last + 1] = ADigest) do
    Inc(Last);
  for Position := First to Last do
    if not RemoveReference(Integer(PtrInt(FTargets.Objects[Position])),
         AFreedBytes) then Result := False;
end;

procedure RepairBuildReferences(const ACacheRoot: string;
  const AObjects: TLWPTCacheObjectArray;
  var AReport: TLWPTCacheRepairReport);
var
  ArtifactPath, Digest, EntryPath, Fingerprint, Hex, ManifestPath,
    PrefixPath, Root: string;
  EntrySearch, PrefixSearch: TSearchRec;
  FindResult: Integer;
  Manifest: TLWPTCachedBuildResult;
  RemoveEntry: Boolean;
begin
  Root := BuildReferenceSHA256Root(ACacheRoot);
  if IsDirSymlinkOrJunction(Root) then
  begin
    WipeDir(Root);
    Inc(AReport.IncompleteEntriesRemoved);
    Exit;
  end;
  FindResult := FindFirst(IncludeTrailingPathDelimiter(Root) + '*',
    faAnyFile or faSymLink, PrefixSearch);
  if FindResult <> 0 then
  begin
    if not FindFirstMeansNoEntry(FindResult) then
      raise ELWPTCacheLifecycleError.CreateFmt(
        'failed to enumerate build-cache references at %s', [Root]);
    Exit;
  end;
  try
    repeat
      if (PrefixSearch.Name = '.') or (PrefixSearch.Name = '..') then
        Continue;
      PrefixPath := IncludeTrailingPathDelimiter(Root) + PrefixSearch.Name;
      if ((PrefixSearch.Attr and faDirectory) = 0)
         or ((PrefixSearch.Attr and faSymLink) <> 0)
         or IsDirSymlinkOrJunction(PrefixPath)
         or (Length(PrefixSearch.Name) <> 2) then
      begin
        RemoveBuildReferenceEntry(PrefixPath, PrefixSearch.Attr);
        Inc(AReport.IncompleteEntriesRemoved);
        Continue;
      end;
      FindResult := FindFirst(IncludeTrailingPathDelimiter(PrefixPath) + '*',
        faAnyFile or faSymLink, EntrySearch);
      if FindResult <> 0 then
      begin
        if not FindFirstMeansNoEntry(FindResult) then
          raise ELWPTCacheLifecycleError.CreateFmt(
            'failed to enumerate build-cache references at %s',
            [PrefixPath]);
        Continue;
      end;
      try
        repeat
          if (EntrySearch.Name = '.') or (EntrySearch.Name = '..') then
            Continue;
          EntryPath := IncludeTrailingPathDelimiter(PrefixPath)
            + EntrySearch.Name;
          Hex := PrefixSearch.Name + EntrySearch.Name;
          RemoveEntry := ((EntrySearch.Attr and faDirectory) <> 0)
            or ((EntrySearch.Attr and faSymLink) <> 0)
            or not IsLowerHex(Hex)
            or not ReadCanonicalBuildReference(EntryPath, Digest);
          if not RemoveEntry then
          begin
            Fingerprint := BuildReferenceFingerprint(PrefixSearch.Name,
              EntrySearch.Name);
            RemoveEntry := not FindObjectPath(AObjects, BUILD_NAMESPACE,
              Digest, ManifestPath)
              or not ReadVerifiedBuildResultManifest(ManifestPath, Digest,
                Manifest)
              or (Manifest.Fingerprint <> Fingerprint)
              or not FindObjectPath(AObjects, BUILD_NAMESPACE,
                Manifest.ArtifactDigest, ArtifactPath);
          end;
          if RemoveEntry then
          begin
            RemoveBuildReferenceEntry(EntryPath, EntrySearch.Attr);
            Inc(AReport.IncompleteEntriesRemoved);
          end;
        until FindNextFinished(EntrySearch, FindResult);
        if not FindNextMeansEnd(FindResult) then
          raise ELWPTCacheLifecycleError.CreateFmt(
            'failed to enumerate build-cache references at %s',
            [PrefixPath]);
      finally
        SysUtils.FindClose(EntrySearch);
      end;
    until FindNextFinished(PrefixSearch, FindResult);
    if not FindNextMeansEnd(FindResult) then
      raise ELWPTCacheLifecycleError.CreateFmt(
        'failed to enumerate build-cache references at %s', [Root]);
  finally
    SysUtils.FindClose(PrefixSearch);
  end;
end;

{ Removes the object, its manifest and (build namespace) its references,
  through AEdges when an eviction batch collects them, leaving the index
  entry to the caller. AFreedBytes is the size of every
  file this call actually deleted, measured just before its deletion, so
  it is exact even when the call reports failure part-way: a caller that
  keeps a running byte total instead of re-walking the tree neither stops
  early on bytes that are still present nor evicts more than it must. }
function RemoveObjectFiles(const ACacheRoot: string;
  const AObject: TLWPTCacheObject; out AFreedBytes: Int64;
  const AEdges: TLWPTBuildReferenceEdges = nil): Boolean;
var
  Manifest: string;
  ManifestBytes, PayloadBytes: Int64;
  Edges: TLWPTBuildReferenceEdges;
  ReferencesRemoved: Boolean;
begin
  AFreedBytes := 0;
  if AObject.Namespace = BUILD_NAMESPACE then
  begin
    Edges := AEdges;
    if Edges = nil then Edges := TLWPTBuildReferenceEdges.Create(ACacheRoot);
    try
      ReferencesRemoved := Edges.RemoveReferencesFor(AObject.Digest,
        AFreedBytes);
    finally
      if AEdges = nil then Edges.Free;
    end;
    if not ReferencesRemoved then Exit(False);
  end;
  Result := not FileExists(AObject.Path);
  if not Result then
  begin
    PayloadBytes := FileByteSize(AObject.Path);
    Result := SysUtils.DeleteFile(AObject.Path);
    if not Result then Exit;
    Inc(AFreedBytes, PayloadBytes);
  end;
  Manifest := ManifestPath(ACacheRoot, AObject.Namespace, AObject.Digest);
  ManifestBytes := FileByteSize(Manifest);
  if SysUtils.DeleteFile(Manifest) then Inc(AFreedBytes, ManifestBytes);
end;

function RemoveObject(const ACacheRoot: string;
  const AObject: TLWPTCacheObject; const AEntries: TStringList): Boolean;
var
  FreedBytes: Int64;
  Index: Integer;
begin
  Result := RemoveObjectFiles(ACacheRoot, AObject, FreedBytes);
  if not Result then Exit;
  Index := AEntries.IndexOfName(ObjectKey(AObject.Namespace,
    AObject.Digest));
  if Index >= 0 then AEntries.Delete(Index);
end;

{ Persists the index without the entries whose Removed flag is set, in one
  pass; deleting them one IndexOfName at a time costs a scan of the whole
  index per eviction. AEntries itself is left intact, so a name lookup
  built over it stays valid for further evictions. }
procedure WriteIndexWithoutFlagged(const ACacheRoot: string;
  const ASequence: Int64; const AEntries: TStringList;
  const ARemoved: array of Boolean);
var
  Index: Integer;
  Kept: TStringList;
begin
  Kept := TStringList.Create;
  try
    Kept.NameValueSeparator := AEntries.NameValueSeparator;
    Kept.Capacity := AEntries.Count;
    for Index := 0 to AEntries.Count - 1 do
      if not ARemoved[Index] then Kept.Add(AEntries[Index]);
    if Kept.Count = 0 then
      SysUtils.DeleteFile(IndexPath(ACacheRoot))
    else
      WriteIndex(ACacheRoot, ASequence, Kept);
  finally
    Kept.Free;
  end;
end;

{ The bytes a walk finds, with the usage ledger counted at its fixed size
  whether or not it exists yet: enforcement writes it after measuring. }
function MeasureCacheBytes(const ACacheRoot: string): Int64;
var
  LedgerBytes: Int64;
begin
  Result := DirectoryBytes(ACacheRoot) + CACHE_LEDGER_BYTES;
  LedgerBytes := LedgerFileBytes(ACacheRoot);
  if LedgerBytes > 0 then Dec(Result, LedgerBytes);
end;

{ Authoritative enforcement: measures the whole tree and, when the cache
  plus AAdditionalBytes exceeds the budget, evicts in least-recently-used
  order down to the low-water mark. It then records the measured total in
  the usage ledger, so later admissions can judge the budget without a
  walk until the ledger runs out of room or loses its trust. }
function EnforceBudgetLocked(const ACacheRoot: string;
  const AAdditionalBytes: Int64; out ALivePreserved: Integer;
  out AReclaimed: Int64; const AKnownLive: TStrings): Boolean;
var
  Budget, CurrentBytes, Sequence, Target: Int64;
  Entries, Lookup: TStringList;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Edges: TLWPTBuildReferenceEdges;
  Index, EntryIndex, Next: Integer;
  IndexValid: Boolean;
  Objects: TLWPTCacheObjectArray;
  Removed: array of Boolean;

  { Tries one candidate once: a live object is preserved and reported, any
    other is removed and its deleted bytes leave the running total. }
  procedure EvictCandidate(const ACandidate: Integer);
  var
    Key: string;
    Lease: TObject;
    Removable: Boolean;
    FreedBytes: Int64;
    Position: Integer;
  begin
    Key := ObjectKey(Objects[ACandidate].Namespace,
      Objects[ACandidate].Digest);
    Lease := Coordinator.TryAcquireGuard('cache-object:' + Key);
    if Lease = nil then
    begin
      if (AKnownLive = nil) or (AKnownLive.IndexOf(Key) < 0) then
        Inc(ALivePreserved);
      if (AKnownLive <> nil) and (AKnownLive.IndexOf(Key) < 0) then
        AKnownLive.Add(Key);
      Exit;
    end;
    try
      { A partial failure still deleted what it reports, so those bytes
        count whatever the result. }
      Removable := RemoveObjectFiles(ACacheRoot, Objects[ACandidate],
        FreedBytes, Edges);
      Dec(CurrentBytes, FreedBytes);
      Inc(AReclaimed, FreedBytes);
      if Removable then
      begin
        Position := LookupEntryIndex(Lookup, Key);
        if Position >= 0 then Removed[Position] := True;
      end;
    finally
      Lease.Free;
    end;
  end;

begin
  Result := False;
  ALivePreserved := 0;
  AReclaimed := 0;
  Budget := ResolveCacheMaxBytes;
  if AAdditionalBytes > Budget then Exit;
  {$IFDEF OBJECTSTORE_TESTING}
  Inc(CacheLifecycleEnforcementCount);
  {$ENDIF}
  { The budget owns the complete shared-cache tree, not only immutable object
    payloads. This includes result references, lifecycle control files,
    producer metadata, and incomplete/quarantined bytes until repair reclaims
    them. Directory entries themselves carry no portable logical byte size. }
  CurrentBytes := MeasureCacheBytes(ACacheRoot);
  if CurrentBytes + AAdditionalBytes <= Budget then
  begin
    StoreLedger(ACacheRoot, CurrentBytes, 0);
    Exit(True);
  end;
  { Evicting only enough to fit would leave the next admission over budget
    again, and every eviction batch walks the tree and the references.
    Going down to the low-water mark leaves a band of room, so that cost
    is paid once per band of admissions. }
  Target := CacheLowWaterBytes(Budget);
  Objects := DiscoverObjects(ACacheRoot);
  Entries := TStringList.Create;
  Coordinator := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(ACacheRoot));
  Edges := TLWPTBuildReferenceEdges.Create(ACacheRoot);
  try
    Entries.NameValueSeparator := '=';
    LoadIndex(ACacheRoot, Sequence, Entries, IndexValid);
    if not IndexValid then
    begin
      Entries.Clear;
      Sequence := 0;
    end;
    { One sorted lookup instead of a Values[] scan per discovered object:
      with thousands of objects and thousands of index entries the scan
      was the dominant cost of every admission. The lookup also locates
      each evicted object's entry, which the index rewrite drops. }
    Lookup := BuildNameLookup(Entries);
    try
      SetLength(Removed, Entries.Count);
      for Index := 0 to High(Objects) do
      begin
        EntryIndex := LookupEntryIndex(Lookup,
          ObjectKey(Objects[Index].Namespace, Objects[Index].Digest));
        if EntryIndex >= 0 then
          Objects[Index].LastUse := StrToInt64Def(
            Entries.ValueFromIndex[EntryIndex], 0)
        else
          Objects[Index].LastUse := 0;
      end;
      SortByLRU(Objects);
      { Evict in LRU order against a running total, then settle it with one
        authoritative walk. The mutation guard does not cover object
        staging, which other writers fill before taking it, so the tree can
        grow while this runs. When the walk still finds the cache above
        the low-water mark, resume from the next candidate with the
        measured total. Without concurrent growth this is one pass and one
        walk; with it, every extra walk follows at least one further
        candidate, so the loop ends once the candidates run out. }
      Next := 0;
      repeat
        while (Next <= High(Objects))
              and (CurrentBytes + AAdditionalBytes > Target) do
        begin
          EvictCandidate(Next);
          Inc(Next);
          {$IFDEF OBJECTSTORE_TESTING}
          if Assigned(CacheLifecycleAfterEvictionTestHook) then
            CacheLifecycleAfterEvictionTestHook(ACacheRoot);
          {$ENDIF}
        end;
        WriteIndexWithoutFlagged(ACacheRoot, Sequence, Entries, Removed);
        CurrentBytes := MeasureCacheBytes(ACacheRoot);
      until (CurrentBytes + AAdditionalBytes <= Target)
            or (Next > High(Objects));
    finally
      Lookup.Free;
    end;
    { A ledger is only worth its bytes while the cache fits. Above the
      budget (live objects, or a budget smaller than the ledger itself)
      every admission measures anyway, so the ledger is dropped. }
    if CurrentBytes <= Budget then
      StoreLedger(ACacheRoot, CurrentBytes, 0)
    else
      DropLedger(ACacheRoot);
    Result := CurrentBytes + AAdditionalBytes <= Budget;
  finally
    Edges.Free;
    Coordinator.Free;
    Entries.Free;
  end;
end;

{ Judges room for AAdditionalBytes from a trusted ledger with no walk, and
  falls back to authoritative enforcement when the ledger is missing or
  untrusted, has no room left, or has grown by more than one band since
  the tree was last measured. }
function EnsureRoomLocked(const ACacheRoot: string;
  const AAdditionalBytes: Int64): Boolean;
var
  Budget, Reclaimed: Int64;
  Ledger: TLWPTCacheLedger;
  LivePreserved: Integer;
begin
  Budget := ResolveCacheMaxBytes;
  if AAdditionalBytes > Budget then Exit(False);
  if LoadLedger(ACacheRoot, Ledger)
     and (Ledger.Bytes <= Budget - AAdditionalBytes)
     and (Ledger.Growth <= Budget - CacheLowWaterBytes(Budget)) then
    Exit(True);
  Result := EnforceBudgetLocked(ACacheRoot, AAdditionalBytes,
    LivePreserved, Reclaimed, nil);
end;

constructor TLWPTCacheLifecycle.Create(const ACacheRoot,
  ANamespace: string);
var
  Budget: Int64;
begin
  inherited Create;
  FCacheRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ACacheRoot));
  FNamespace := ANamespace;
  Budget := ResolveCacheMaxBytes;
  if Budget < 0 then
    raise ELWPTCacheLifecycleError.Create('cache budget cannot be negative');
  FCoordinator := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(FCacheRoot));
end;

destructor TLWPTCacheLifecycle.Destroy;
begin
  FCoordinator.Free;
  inherited Destroy;
end;

function TLWPTCacheLifecycle.Acquire(const AKey: string): TObject;
begin
  repeat
    Result := FCoordinator.TryAcquireGuard(AKey);
    if Result = nil then Sleep(25);
  until Result <> nil;
end;

function TLWPTCacheLifecycle.Key(const ADigest: string): string;
begin
  Result := ObjectKey(FNamespace, ADigest);
end;

function TLWPTCacheLifecycle.AcquireMutation: TObject;
begin
  Result := Acquire('cache-lifecycle:mutation');
end;

function TLWPTCacheLifecycle.AcquireObject(
  const ADigest: string): TObject;
begin
  Result := Acquire('cache-object:' + Key(ADigest));
end;

function TLWPTCacheLifecycle.MakeRoomLocked(
  const AAdditionalBytes: Int64): Boolean;
var
  Ledger: TLWPTCacheLedger;
begin
  Result := EnsureRoomLocked(FCacheRoot, AAdditionalBytes);
  if Result and (AAdditionalBytes > 0) then
    AccountLedger(FCacheRoot, LoadLedger(FCacheRoot, Ledger), Ledger,
      AAdditionalBytes);
end;

procedure TLWPTCacheLifecycle.DiscardObjectLocked(const ADigest,
  AObjectPath: string);
var
  Entries: TStringList;
  IndexValid, LedgerTrusted: Boolean;
  Item: TLWPTCacheObject;
  FreedBytes, IndexBytes, Sequence: Int64;
  Index: Integer;
  Ledger: TLWPTCacheLedger;
begin
  LedgerTrusted := LoadLedger(FCacheRoot, Ledger);
  IndexBytes := FileByteSize(IndexPath(FCacheRoot));
  Entries := TStringList.Create;
  try
    Entries.NameValueSeparator := '=';
    LoadIndex(FCacheRoot, Sequence, Entries, IndexValid);
    if not IndexValid then
    begin
      Entries.Clear;
      Sequence := 0;
    end;
    Item := Default(TLWPTCacheObject);
    Item.Namespace := FNamespace;
    Item.Digest := ADigest;
    Item.Path := AObjectPath;
    if not RemoveObjectFiles(FCacheRoot, Item, FreedBytes) then
    begin
      AccountLedger(FCacheRoot, LedgerTrusted, Ledger, -FreedBytes);
      raise ELWPTCacheLifecycleError.CreateFmt(
        'failed to discard cache object %s', [ADigest]);
    end;
    Index := Entries.IndexOfName(Key(ADigest));
    if Index >= 0 then Entries.Delete(Index);
    if Entries.Count = 0 then
      SysUtils.DeleteFile(IndexPath(FCacheRoot))
    else
      WriteIndex(FCacheRoot, Sequence, Entries);
    AccountLedger(FCacheRoot, LedgerTrusted, Ledger,
      FileByteSize(IndexPath(FCacheRoot)) - IndexBytes - FreedBytes);
  finally
    Entries.Free;
  end;
end;

procedure TLWPTCacheLifecycle.RecordObjectLocked(const ADigest,
  AObjectPath: string);
var
  Entries: TStringList;
  IndexValid, LedgerTrusted: Boolean;
  Sequence, Size, ControlBytes: Int64;
  Search: TSearchRec;
  Ledger: TLWPTCacheLedger;
begin
  if FindFirst(AObjectPath, faAnyFile, Search) <> 0 then
    raise ELWPTCacheLifecycleError.CreateFmt(
      'admitted cache object is missing: %s', [AObjectPath]);
  try
    Size := Search.Size;
  finally
    SysUtils.FindClose(Search);
  end;
  { The object arrived by renaming staging bytes that no ledger counted,
    so its size is new to the ledger, as are the control file changes. }
  LedgerTrusted := LoadLedger(FCacheRoot, Ledger);
  ControlBytes := FileByteSize(IndexPath(FCacheRoot))
    + FileByteSize(ManifestPath(FCacheRoot, FNamespace, ADigest));
  Entries := TStringList.Create;
  try
    try
      WriteManifest(FCacheRoot, FNamespace, ADigest, AObjectPath, Size);
      Entries.NameValueSeparator := '=';
      LoadIndex(FCacheRoot, Sequence, Entries, IndexValid);
      if not IndexValid then
      begin
        Entries.Clear;
        Sequence := 0;
      end;
      Inc(Sequence);
      SetIndexEntry(Entries, Key(ADigest), IntToStr(Sequence));
      WriteIndex(FCacheRoot, Sequence, Entries);
    except
      { The published object is not counted yet, so a rollback discard
        would subtract bytes the ledger never held. Measure instead, and
        keep the original failure if the ledger cannot be dropped. }
      try
        DropLedger(FCacheRoot);
      except
        on ELWPTCacheLifecycleError do;
      end;
      raise;
    end;
  finally
    Entries.Free;
  end;
  AccountLedger(FCacheRoot, LedgerTrusted, Ledger, Size
    + FileByteSize(IndexPath(FCacheRoot))
    + FileByteSize(ManifestPath(FCacheRoot, FNamespace, ADigest))
    - ControlBytes);
end;

procedure TLWPTCacheLifecycle.TouchObjectLocked(
  const ADigest: string);
var
  Entries: TStringList;
  IndexValid, LedgerTrusted: Boolean;
  AdditionalBytes, ExistingBytes, Sequence: Int64;
  Ledger: TLWPTCacheLedger;
begin
  Entries := TStringList.Create;
  try
    Entries.NameValueSeparator := '=';
    LoadIndex(FCacheRoot, Sequence, Entries, IndexValid);
    if not IndexValid then
    begin
      Entries.Clear;
      Sequence := 0;
    end;
    Inc(Sequence);
    SetIndexEntry(Entries, Key(ADigest), IntToStr(Sequence));
    ExistingBytes := FileByteSize(IndexPath(FCacheRoot));
    AdditionalBytes := IndexByteSize(Sequence, Entries) - ExistingBytes;
    if AdditionalBytes < 0 then AdditionalBytes := 0;
    if (AdditionalBytes > 0)
       and not EnsureRoomLocked(FCacheRoot, AdditionalBytes) then Exit;
    if AdditionalBytes > 0 then
    begin
      LoadIndex(FCacheRoot, Sequence, Entries, IndexValid);
      if not IndexValid then
      begin
        Entries.Clear;
        Sequence := 0;
      end;
      Inc(Sequence);
      SetIndexEntry(Entries, Key(ADigest), IntToStr(Sequence));
    end;
    LedgerTrusted := LoadLedger(FCacheRoot, Ledger);
    ExistingBytes := FileByteSize(IndexPath(FCacheRoot));
    WriteIndex(FCacheRoot, Sequence, Entries);
    AccountLedger(FCacheRoot, LedgerTrusted, Ledger,
      FileByteSize(IndexPath(FCacheRoot)) - ExistingBytes);
  finally
    Entries.Free;
  end;
end;

function DirectoryBytes(const APath: string): Int64;
var
  Child: string;
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*',
       faAnyFile or faSymLink,
       Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Child := IncludeTrailingPathDelimiter(APath) + Search.Name;
      if (Search.Attr and faSymLink) <> 0 then Continue
      else if ((Search.Attr and faDirectory) <> 0)
         and not IsDirSymlinkOrJunction(Child) then
        Inc(Result, DirectoryBytes(Child))
      else
        Inc(Result, Search.Size);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function DirectoryEntryCount(const APath: string): Integer;
var
  Child: string;
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*',
       faAnyFile or faSymLink,
       Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Inc(Result);
      if ((Search.Attr and faDirectory) <> 0)
         and ((Search.Attr and faSymLink) = 0)
         and not IsDirSymlinkOrJunction(
           IncludeTrailingPathDelimiter(APath) + Search.Name) then
      begin
        Child := IncludeTrailingPathDelimiter(APath) + Search.Name;
        Inc(Result, DirectoryEntryCount(Child));
      end;
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

procedure RemoveResidue(const APath: string;
  var AReport: TLWPTCacheRepairReport); forward;

procedure RepairObjectStagingRoot(const AObjectRoot, ANamespace: string;
  const ACoordinator: TLWPTProducerLeaseCoordinator;
  var AReport: TLWPTCacheRepairReport);
var
  Digest, EntryPath, StageRoot: string;
  Guard: TObject;
  Search: TSearchRec;
begin
  StageRoot := IncludeTrailingPathDelimiter(AObjectRoot) + 'tmp';
  if IsDirSymlinkOrJunction(StageRoot) then
  begin
    WipeDir(StageRoot);
    Inc(AReport.IncompleteEntriesRemoved);
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(StageRoot) + '*',
       faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      EntryPath := IncludeTrailingPathDelimiter(StageRoot) + Search.Name;
      if ((Search.Attr and faDirectory) = 0)
         or ((Search.Attr and faSymLink) <> 0)
         or IsDirSymlinkOrJunction(EntryPath)
         or not IsLowerHex(LowerCase(Search.Name)) then
      begin
        if (Search.Attr and faSymLink) <> 0 then WipeDir(EntryPath)
        else if (Search.Attr and faDirectory) <> 0 then
          RemoveResidue(EntryPath, AReport)
        else if SysUtils.DeleteFile(EntryPath) then
        begin
          Inc(AReport.BytesReclaimed, Search.Size);
          Inc(AReport.IncompleteEntriesRemoved);
        end;
        Continue;
      end;
      Digest := 'sha256:' + LowerCase(Search.Name);
      Guard := ACoordinator.TryAcquireGuard('cache-object:'
        + ObjectKey(ANamespace, Digest));
      if Guard = nil then
      begin
        Inc(AReport.LiveObjectsPreserved);
        Continue;
      end;
      try
        RemoveResidue(EntryPath, AReport);
      finally
        Guard.Free;
      end;
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

procedure RemoveObjectStoreLinks(const AObjectRoot: string;
  var AReport: TLWPTCacheRepairReport);
var
  EntryPath, Hex, PrefixPath, SHA256Root: string;
  EntrySearch, PrefixSearch: TSearchRec;
begin
  SHA256Root := IncludeTrailingPathDelimiter(AObjectRoot) + 'sha256';
  if IsDirSymlinkOrJunction(SHA256Root) then
  begin
    WipeDir(SHA256Root);
    Inc(AReport.IncompleteEntriesRemoved);
    Exit;
  end;
  if FileExists(SHA256Root) then
  begin
    if not SysUtils.DeleteFile(SHA256Root) then
      raise ELWPTCacheLifecycleError.CreateFmt(
        'failed to remove invalid object-store root at %s', [SHA256Root]);
    Inc(AReport.IncompleteEntriesRemoved);
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(SHA256Root) + '*',
       faAnyFile or faSymLink, PrefixSearch) <> 0 then Exit;
  try
    repeat
      if (PrefixSearch.Name = '.') or (PrefixSearch.Name = '..') then Continue;
      PrefixPath := IncludeTrailingPathDelimiter(SHA256Root)
        + PrefixSearch.Name;
      if ((PrefixSearch.Attr and faSymLink) <> 0)
         or IsDirSymlinkOrJunction(PrefixPath)
         or ((PrefixSearch.Attr and faDirectory) = 0)
         or not IsLowerHex(PrefixSearch.Name + StringOfChar('0', 62)) then
      begin
        if (PrefixSearch.Attr and faSymLink) <> 0 then
          WipeDir(PrefixPath)
        else if (PrefixSearch.Attr and faDirectory) <> 0 then
          RemoveResidue(PrefixPath, AReport)
        else if SysUtils.DeleteFile(PrefixPath) then
          Inc(AReport.BytesReclaimed, PrefixSearch.Size)
        else
          raise ELWPTCacheLifecycleError.CreateFmt(
            'failed to remove malformed object-store entry at %s',
            [PrefixPath]);
        Inc(AReport.IncompleteEntriesRemoved);
        Continue;
      end;
      if FindFirst(IncludeTrailingPathDelimiter(PrefixPath) + '*',
           faAnyFile or faSymLink, EntrySearch) <> 0 then Continue;
      try
        repeat
          if (EntrySearch.Name = '.') or (EntrySearch.Name = '..') then
            Continue;
          EntryPath := IncludeTrailingPathDelimiter(PrefixPath)
            + EntrySearch.Name;
          Hex := PrefixSearch.Name + EntrySearch.Name;
          if ((EntrySearch.Attr and faSymLink) <> 0)
             or IsDirSymlinkOrJunction(EntryPath)
             or ((EntrySearch.Attr and faDirectory) <> 0)
             or not IsLowerHex(Hex) then
          begin
            if (EntrySearch.Attr and faSymLink) <> 0 then
              WipeDir(EntryPath)
            else if (EntrySearch.Attr and faDirectory) <> 0 then
              RemoveResidue(EntryPath, AReport)
            else if SysUtils.DeleteFile(EntryPath) then
              Inc(AReport.BytesReclaimed, EntrySearch.Size)
            else
              raise ELWPTCacheLifecycleError.CreateFmt(
                'failed to remove malformed object-store entry at %s',
                [EntryPath]);
            Inc(AReport.IncompleteEntriesRemoved);
          end;
        until FindNext(EntrySearch) <> 0;
      finally
        SysUtils.FindClose(EntrySearch);
      end;
    until FindNext(PrefixSearch) <> 0;
  finally
    SysUtils.FindClose(PrefixSearch);
  end;
end;

procedure RemoveResidue(const APath: string;
  var AReport: TLWPTCacheRepairReport);
var
  Bytes: Int64;
  Entries: Integer;
begin
  if not DirectoryExists(APath) then Exit;
  if IsDirSymlinkOrJunction(APath) then
  begin
    WipeDir(APath);
    Inc(AReport.IncompleteEntriesRemoved);
    Exit;
  end;
  Bytes := DirectoryBytes(APath);
  Entries := DirectoryEntryCount(APath);
  WipeDir(APath);
  Inc(AReport.BytesReclaimed, Bytes);
  if Entries > 0 then Inc(AReport.IncompleteEntriesRemoved);
end;

function PrepareInternalRoot(const APath: string;
  var AReport: TLWPTCacheRepairReport): Boolean;
begin
  if IsDirSymlinkOrJunction(APath) then
  begin
    WipeDir(APath);
    Inc(AReport.IncompleteEntriesRemoved);
    Exit(False);
  end;
  Result := True;
end;

function RepairSharedCache(const ACacheRoot: string):
  TLWPTCacheRepairReport;
var
  BuildRoot, CacheRoot, DependencyRoot: string;
  Entries, LiveKeys: TStringList;
  GlobalCoordinator: TLWPTProducerLeaseCoordinator;
  GlobalLease, ObjectLease: TObject;
  Index, LivePreserved: Integer;
  BuildObjectsSafe, BuildRootSafe, DependencyRootSafe, IndexValid,
    ManifestValid: Boolean;
  Objects: TLWPTCacheObjectArray;
  InitialBytes, Reclaimed, Sequence: Int64;
begin
  Result := Default(TLWPTCacheRepairReport);
  CacheRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ACacheRoot));
  DependencyRoot := IncludeTrailingPathDelimiter(CacheRoot)
    + DEPENDENCY_NAMESPACE;
  BuildRoot := IncludeTrailingPathDelimiter(CacheRoot) + BUILD_NAMESPACE;
  InitialBytes := DirectoryBytes(CacheRoot);
  Result.BudgetBytes := ResolveCacheMaxBytes;
  Result.AbandonedLeasesReclaimed := RepairProducerLeases(CacheRoot,
    Result.LiveLeasesPreserved);
  LiveKeys := TStringList.Create;
  GlobalCoordinator := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(CacheRoot));
  GlobalLease := nil;
  try
    repeat
      GlobalLease := GlobalCoordinator.TryAcquireGuard(
        'cache-lifecycle:mutation');
      if GlobalLease = nil then Sleep(25);
    until GlobalLease <> nil;

    DependencyRootSafe := PrepareInternalRoot(DependencyRoot, Result);
    BuildRootSafe := PrepareInternalRoot(BuildRoot, Result);
    if PrepareInternalRoot(LifecycleRoot(CacheRoot), Result) then
    begin
      RemoveResidue(LifecycleTemporaryRoot(CacheRoot), Result);
      { Repair changes bytes without keeping the usage ledger; budget
        enforcement below measures the tree and writes a fresh one. }
      DropLedger(CacheRoot);
    end;
    if DependencyRootSafe then
    begin
      RepairObjectStagingRoot(DependencyRoot, DEPENDENCY_NAMESPACE,
        GlobalCoordinator, Result);
      RemoveResidue(DependencyRoot + '/quarantine', Result);
      RemoveObjectStoreLinks(DependencyRoot, Result);
    end;
    if BuildRootSafe then
    begin
      RemoveResidue(BuildRoot + '/tmp', Result);
      BuildObjectsSafe := PrepareInternalRoot(BuildRoot + '/objects', Result);
      if BuildObjectsSafe then
      begin
        RepairObjectStagingRoot(BuildRoot + '/objects', BUILD_NAMESPACE,
          GlobalCoordinator, Result);
        RemoveResidue(BuildRoot + '/objects/quarantine', Result);
        RemoveObjectStoreLinks(BuildRoot + '/objects', Result);
      end;
    end;

    Objects := DiscoverObjects(CacheRoot);
    Entries := TStringList.Create;
    try
      Entries.NameValueSeparator := '=';
      LoadIndex(CacheRoot, Sequence, Entries, IndexValid);
      if not IndexValid then
      begin
        Entries.Clear;
        Sequence := 0;
        Result.IndexRebuilt := True;
      end;
      for Index := 0 to High(Objects) do
      begin
        ObjectLease := GlobalCoordinator.TryAcquireGuard(
          'cache-object:' + ObjectKey(Objects[Index].Namespace,
            Objects[Index].Digest));
        if ObjectLease = nil then
        begin
          Inc(Result.LiveObjectsPreserved);
          LiveKeys.Add(ObjectKey(Objects[Index].Namespace,
            Objects[Index].Digest));
          Continue;
        end;
        try
          if ('sha256:' + SHA256File(Objects[Index].Path)) <>
             Objects[Index].Digest then
          begin
            if RemoveObject(CacheRoot, Objects[Index], Entries) then
            begin
              Inc(Result.CorruptObjectsRemoved);
              Inc(Result.BytesReclaimed, Objects[Index].Size);
            end;
            Continue;
          end;
          ManifestValid := ManifestIsVerified(CacheRoot, Objects[Index]);
          if not ManifestValid then
          begin
            WriteManifest(CacheRoot, Objects[Index].Namespace,
              Objects[Index].Digest, Objects[Index].Path,
              Objects[Index].Size);
          end;
        finally
          ObjectLease.Free;
        end;
      end;
      Objects := DiscoverObjects(CacheRoot);
      RepairBuildReferences(CacheRoot, Objects, Result);
      if not IndexValid
         or not IndexMatchesObjects(Objects, Entries, Sequence) then
      begin
        RebuildIndexFromObjects(Objects, Entries, Sequence);
        Result.IndexRebuilt := True;
      end;
      WriteIndex(CacheRoot, Sequence, Entries);
    finally
      Entries.Free;
    end;

    EnforceBudgetLocked(CacheRoot, 0, LivePreserved, Reclaimed, LiveKeys);
    Inc(Result.LiveObjectsPreserved, LivePreserved);
    Result.BytesAfter := DirectoryBytes(CacheRoot);
    Result.BytesBefore := InitialBytes;
    if Result.BytesAfter < Result.BytesBefore then
      Result.BytesReclaimed := Result.BytesBefore - Result.BytesAfter
    else
      Result.BytesReclaimed := 0;
  finally
    GlobalLease.Free;
    GlobalCoordinator.Free;
    LiveKeys.Free;
  end;
end;

end.
