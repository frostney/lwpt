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
    function MakeRoomLocked(const AAdditionalBytes: Int64): Boolean;
    procedure DiscardObjectLocked(const ADigest, AObjectPath: string);
    procedure RecordObjectLocked(const ADigest, AObjectPath: string);
    procedure TouchObjectLocked(const ADigest: string);
  end;

function ResolveCacheMaxBytes: Int64;
function ResolveCacheMaxBytesFromValue(const AValue: string): Int64;
function RepairSharedCache(const ACacheRoot: string):
  TLWPTCacheRepairReport;

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

function ReadSmallTextFile(const APath: string;
  out AText: string): Boolean;
const
  MAX_CONTROL_BYTES = 16 * 1024 * 1024;
var
  Bytes: TBytes;
  Stream: TFileStream;
begin
  Result := False;
  AText := '';
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
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

procedure LoadIndex(const ACacheRoot: string; out ASequence: Int64;
  const AEntries: TStringList; out AValid: Boolean);
var
  Lines: TStringList;
  Index, Separator: Integer;
  Line, Name, Text: string;
  Value: Int64;
begin
  AEntries.Clear;
  ASequence := 0;
  AValid := False;
  if not ReadSmallTextFile(IndexPath(ACacheRoot), Text) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    if (Lines.Count < 2) or (Lines[0] <> 'schema=' +
       IntToStr(CACHE_INDEX_SCHEMA)) then Exit;
    if Copy(Lines[1], 1, 9) <> 'sequence=' then Exit;
    if not TryStrToInt64(Copy(Lines[1], 10, MaxInt), ASequence)
       or (ASequence < 0) then Exit;
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
      AEntries.Values[Name] := IntToStr(Value);
    end;
    AValid := True;
  finally
    Lines.Free;
  end;
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
    for Index := 0 to AEntries.Count - 1 do
      Lines.Add('entry.' + AEntries.Names[Index] + '='
        + AEntries.ValueFromIndex[Index]);
    ForceDirectories(LifecycleTemporaryRoot(ACacheRoot));
    AtomicWriteText(IndexPath(ACacheRoot),
      LifecycleTemporaryRoot(ACacheRoot), Lines);
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
      Lines.Add('entry.' + AEntries.Names[Index] + '='
        + AEntries.ValueFromIndex[Index]);
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

procedure SortByLRU(var AObjects: TLWPTCacheObjectArray);
var
  Current: TLWPTCacheObject;
  Index, Prior: Integer;
begin
  for Index := 1 to High(AObjects) do
  begin
    Current := AObjects[Index];
    Prior := Index - 1;
    while (Prior >= 0) and
      ((AObjects[Prior].LastUse > Current.LastUse) or
       ((AObjects[Prior].LastUse = Current.LastUse) and
        (ObjectKey(AObjects[Prior].Namespace,
          AObjects[Prior].Digest) > ObjectKey(Current.Namespace,
          Current.Digest)))) do
    begin
      AObjects[Prior + 1] := AObjects[Prior];
      Dec(Prior);
    end;
    AObjects[Prior + 1] := Current;
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

function ReferenceNamesBuildObject(const ACacheRoot, AReferencePath,
  AReferenceFingerprint, AObjectDigest: string;
  out AMalformed: Boolean): Boolean;
var
  Manifest: TLWPTCachedBuildResult;
  ManifestDigest, ManifestPath: string;
begin
  Result := False;
  AMalformed := False;
  if not ReadCanonicalBuildReference(AReferencePath, ManifestDigest) then
  begin
    AMalformed := True;
    Exit;
  end;
  if ManifestDigest = AObjectDigest then Exit(True);
  ManifestPath := BuildObjectPath(ACacheRoot, ManifestDigest);
  if not ReadVerifiedBuildResultManifest(ManifestPath, ManifestDigest,
       Manifest) then
  begin
    AMalformed := True;
    Exit;
  end;
  if Manifest.Fingerprint <> AReferenceFingerprint then
  begin
    AMalformed := True;
    Exit;
  end;
  Result := Manifest.ArtifactDigest = AObjectDigest;
end;

function RemoveBuildReferencesForDigest(const ACacheRoot,
  ADigest: string): Boolean;
var
  EntryPath, Fingerprint, PrefixPath, Root: string;
  EntrySearch, PrefixSearch: TSearchRec;
  FindResult: Integer;
  Malformed, RemoveEntry: Boolean;
begin
  Result := True;
  Root := BuildReferenceSHA256Root(ACacheRoot);
  if IsDirSymlinkOrJunction(Root) then Exit(False);
  FindResult := FindFirst(IncludeTrailingPathDelimiter(Root) + '*',
    faAnyFile or faSymLink, PrefixSearch);
  if FindResult <> 0 then
  begin
    if not FindFirstMeansNoEntry(FindResult) then
      Result := False;
    Exit;
  end;
  try
    repeat
      if (PrefixSearch.Name = '.') or (PrefixSearch.Name = '..')
         or ((PrefixSearch.Attr and faDirectory) = 0)
         or ((PrefixSearch.Attr and faSymLink) <> 0) then
      begin
        if (PrefixSearch.Name <> '.') and (PrefixSearch.Name <> '..') then
          Result := False;
        Continue;
      end;
      PrefixPath := IncludeTrailingPathDelimiter(Root) + PrefixSearch.Name;
      if IsDirSymlinkOrJunction(PrefixPath) then
      begin
        Result := False;
        Continue;
      end;
      FindResult := FindFirst(IncludeTrailingPathDelimiter(PrefixPath) + '*',
        faAnyFile or faSymLink, EntrySearch);
      if FindResult <> 0 then
      begin
        if not FindFirstMeansNoEntry(FindResult) then Result := False;
        Continue;
      end;
      try
        repeat
          if (EntrySearch.Name = '.') or (EntrySearch.Name = '..')
             or ((EntrySearch.Attr and faDirectory) <> 0)
             or ((EntrySearch.Attr and faSymLink) <> 0) then
          begin
            if (EntrySearch.Name <> '.') and (EntrySearch.Name <> '..') then
              Result := False;
            Continue;
          end;
          EntryPath := IncludeTrailingPathDelimiter(PrefixPath)
            + EntrySearch.Name;
          Fingerprint := BuildReferenceFingerprint(PrefixSearch.Name,
            EntrySearch.Name);
          RemoveEntry := ReferenceNamesBuildObject(ACacheRoot, EntryPath,
            Fingerprint, ADigest, Malformed);
          if RemoveEntry or Malformed then
            try
              RemoveBuildReferenceEntry(EntryPath, EntrySearch.Attr);
            except
              on ELWPTCacheLifecycleError do Result := False;
            end;
        until FindNextFinished(EntrySearch, FindResult);
        if not FindNextMeansEnd(FindResult) then Result := False;
      finally
        SysUtils.FindClose(EntrySearch);
      end;
    until FindNextFinished(PrefixSearch, FindResult);
    if not FindNextMeansEnd(FindResult) then Result := False;
  finally
    SysUtils.FindClose(PrefixSearch);
  end;
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

function RemoveObject(const ACacheRoot: string;
  const AObject: TLWPTCacheObject; const AEntries: TStringList): Boolean;
var
  Index: Integer;
begin
  if (AObject.Namespace = BUILD_NAMESPACE)
     and not RemoveBuildReferencesForDigest(ACacheRoot,
       AObject.Digest) then Exit(False);
  Result := not FileExists(AObject.Path);
  if not Result then Result := SysUtils.DeleteFile(AObject.Path);
  if not Result then Exit;
  SysUtils.DeleteFile(ManifestPath(ACacheRoot, AObject.Namespace,
    AObject.Digest));
  Index := AEntries.IndexOfName(ObjectKey(AObject.Namespace,
    AObject.Digest));
  if Index >= 0 then AEntries.Delete(Index);
end;

function EnforceBudgetLocked(const ACacheRoot: string;
  const AAdditionalBytes: Int64; out ALivePreserved: Integer;
  out AReclaimed: Int64; const AKnownLive: TStrings): Boolean;
var
  Budget, CurrentBytes, RemovalBytes, Sequence: Int64;
  Entries: TStringList;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Index: Integer;
  IndexValid: Boolean;
  Lease: TObject;
  Objects: TLWPTCacheObjectArray;
begin
  Result := False;
  ALivePreserved := 0;
  AReclaimed := 0;
  Budget := ResolveCacheMaxBytes;
  if AAdditionalBytes > Budget then Exit;
  Objects := DiscoverObjects(ACacheRoot);
  { The budget owns the complete shared-cache tree, not only immutable object
    payloads. This includes result references, lifecycle control files,
    producer metadata, and incomplete/quarantined bytes until repair reclaims
    them. Directory entries themselves carry no portable logical byte size. }
  CurrentBytes := DirectoryBytes(ACacheRoot);
  Entries := TStringList.Create;
  Coordinator := TLWPTProducerLeaseCoordinator.Create(
    ProducerLeaseRoot(ACacheRoot));
  try
    Entries.NameValueSeparator := '=';
    LoadIndex(ACacheRoot, Sequence, Entries, IndexValid);
    if not IndexValid then
    begin
      Entries.Clear;
      Sequence := 0;
    end;
    for Index := 0 to High(Objects) do
      Objects[Index].LastUse := StrToInt64Def(
        Entries.Values[ObjectKey(Objects[Index].Namespace,
          Objects[Index].Digest)], 0);
    SortByLRU(Objects);
    for Index := 0 to High(Objects) do
    begin
      if CurrentBytes + AAdditionalBytes <= Budget then Break;
      Lease := Coordinator.TryAcquireGuard(
          'cache-object:' + ObjectKey(Objects[Index].Namespace,
            Objects[Index].Digest));
      if Lease = nil then
      begin
        if (AKnownLive = nil)
           or (AKnownLive.IndexOf(ObjectKey(Objects[Index].Namespace,
             Objects[Index].Digest)) < 0) then
          Inc(ALivePreserved);
        if (AKnownLive <> nil)
           and (AKnownLive.IndexOf(ObjectKey(Objects[Index].Namespace,
             Objects[Index].Digest)) < 0) then
          AKnownLive.Add(ObjectKey(Objects[Index].Namespace,
            Objects[Index].Digest));
        Continue;
      end;
      try
        if RemoveObject(ACacheRoot, Objects[Index], Entries) then
        begin
          RemovalBytes := CurrentBytes;
          CurrentBytes := DirectoryBytes(ACacheRoot);
          if CurrentBytes < RemovalBytes then
            Inc(AReclaimed, RemovalBytes - CurrentBytes);
        end;
      finally
        Lease.Free;
      end;
    end;
    if Entries.Count = 0 then
      SysUtils.DeleteFile(IndexPath(ACacheRoot))
    else
      WriteIndex(ACacheRoot, Sequence, Entries);
    CurrentBytes := DirectoryBytes(ACacheRoot);
    Result := CurrentBytes + AAdditionalBytes <= Budget;
  finally
    Coordinator.Free;
    Entries.Free;
  end;
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
  LivePreserved: Integer;
  Reclaimed: Int64;
begin
  Result := EnforceBudgetLocked(FCacheRoot, AAdditionalBytes,
    LivePreserved, Reclaimed, nil);
end;

procedure TLWPTCacheLifecycle.DiscardObjectLocked(const ADigest,
  AObjectPath: string);
var
  Entries: TStringList;
  IndexValid: Boolean;
  Item: TLWPTCacheObject;
  Sequence: Int64;
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
    Item := Default(TLWPTCacheObject);
    Item.Namespace := FNamespace;
    Item.Digest := ADigest;
    Item.Path := AObjectPath;
    if not RemoveObject(FCacheRoot, Item, Entries) then
      raise ELWPTCacheLifecycleError.CreateFmt(
        'failed to discard cache object %s', [ADigest]);
    if Entries.Count = 0 then
      SysUtils.DeleteFile(IndexPath(FCacheRoot))
    else
      WriteIndex(FCacheRoot, Sequence, Entries);
  finally
    Entries.Free;
  end;
end;

procedure TLWPTCacheLifecycle.RecordObjectLocked(const ADigest,
  AObjectPath: string);
var
  Entries: TStringList;
  IndexValid: Boolean;
  Sequence, Size: Int64;
  Search: TSearchRec;
begin
  if FindFirst(AObjectPath, faAnyFile, Search) <> 0 then
    raise ELWPTCacheLifecycleError.CreateFmt(
      'admitted cache object is missing: %s', [AObjectPath]);
  try
    Size := Search.Size;
  finally
    SysUtils.FindClose(Search);
  end;
  WriteManifest(FCacheRoot, FNamespace, ADigest, AObjectPath, Size);
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
    Entries.Values[Key(ADigest)] := IntToStr(Sequence);
    WriteIndex(FCacheRoot, Sequence, Entries);
  finally
    Entries.Free;
  end;
end;

procedure TLWPTCacheLifecycle.TouchObjectLocked(
  const ADigest: string);
var
  Entries: TStringList;
  IndexValid: Boolean;
  AdditionalBytes, ExistingBytes, Sequence: Int64;
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
    Entries.Values[Key(ADigest)] := IntToStr(Sequence);
    ExistingBytes := FileByteSize(IndexPath(FCacheRoot));
    AdditionalBytes := IndexByteSize(Sequence, Entries) - ExistingBytes;
    if AdditionalBytes < 0 then AdditionalBytes := 0;
    if (AdditionalBytes > 0)
       and not MakeRoomLocked(AdditionalBytes) then Exit;
    if AdditionalBytes > 0 then
    begin
      LoadIndex(FCacheRoot, Sequence, Entries, IndexValid);
      if not IndexValid then
      begin
        Entries.Clear;
        Sequence := 0;
      end;
      Inc(Sequence);
      Entries.Values[Key(ADigest)] := IntToStr(Sequence);
    end;
    WriteIndex(FCacheRoot, Sequence, Entries);
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
      RemoveResidue(LifecycleTemporaryRoot(CacheRoot), Result);
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
