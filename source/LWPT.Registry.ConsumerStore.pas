{ LWPT.Registry.ConsumerStore -- byte budget, recency, and eviction for the
  per-user registry document store (ADR-0051, issue #345).

  The consumer keeps every authenticated snapshot, record, checkpoint,
  signature, and rotation document it verified under
  <state root>/documents/sha256/<hex>.toml. Losing one costs only
  re-transfer, or a stale classification while offline: every document is
  verified again from the pin before it is trusted.

  Live documents are never evicted. A document is live when it belongs to
  the current accepted history of a stored origin state:
    - the accepted checkpoint, and each signature envelope naming it;
    - the accepted snapshot and every predecessor reached through its
      `previous` links;
    - every record those snapshots name; and
    - the accepted rotation triplets.
  A committed selection proof of a lock lies on that history (the head must
  extend it), so its snapshot, records, and rotations are live; only a
  superseded checkpoint and its signature are not.

  Every other document is evictable: superseded checkpoints and their
  signatures, and documents of deleted states. Evictable bytes are capped by
  LWPT_REGISTRY_STATE_MAX_BYTES; beyond it, the least recently used go first.
  Recency is an access stamp kept in one index file, written atomically
  under the store lease by each successful online install for the
  documents it verified or its lock references. A document without a stamp
  is stamped when a pass first sees it.

  Any uncertainty about the live set removes nothing: a directory that
  cannot be listed completely, a state file that cannot be read, a missing,
  unreadable, corrupt, or unparsable snapshot on an accepted history, an
  unreadable small document that could be a live signature, and an
  exceeded bound each make the pass incomplete. Passes are bounded: at most
  RegistryStoreScanEntries entries are listed per directory, each chain is
  read within the verifier's snapshot, per-document, and total byte limits,
  and only small evictable documents are opened to recognise signatures.
  Only regular files are documents: links, directories, devices, FIFOs, and
  other names are foreign, never opened, counted, or removed, and state
  files are never touched. The new recency index is published before any
  removal, so a failed index write removes nothing. }
unit LWPT.Registry.ConsumerStore;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  Generics.Collections,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store,
  LWPT.Registry.Verification;

const
  REGISTRY_STATE_MAX_BYTES_ENV = PROJECT_NAME + '_REGISTRY_STATE_MAX_BYTES';
  { The verifier's cumulative metadata limit: the most one origin's
    verification can ever charge (DefaultRegistryVerificationLimits). The
    store keeps at most that much evictable history beside the live
    histories, which the same limit bounds per origin. }
  RegistryStateDefaultMaxBytes = Int64(64) * 1024 * 1024;
  REGISTRY_DOCUMENT_RECENCY_SCHEMA = PROGRAM_NAME + '-registry-document-recency-v1';
  { One pass lists at most this many documents: 100 complete histories at
    the verifier's 10,000-document limit. }
  RegistryStoreScanEntries = 1000000;
  { Signature envelopes are a few hundred bytes; only evictable documents up
    to this size are opened to recognise one. }
  RegistryStoreSignatureProbeBytes = 4096;
  RegistryRecencyIndexMaxBytes = Int64(128) * 1024 * 1024;

type
  TLWPTRegistryRecency = TDictionary<string, Int64>;

  { The roots of one stored origin state's accepted history. }
  TLWPTRegistryStoreRoot = record
    Checkpoint, Snapshot: string;
    Rotations: TStringArray;
  end;
  TLWPTRegistryStoreRootArray = array of TLWPTRegistryStoreRoot;

  TLWPTRegistryStoreReport = record
    BudgetBytes: Int64;
    StateFiles: Integer;
    Documents: Integer;
    DocumentBytes: Int64;
    { Entries below documents/sha256/ that are not store documents. }
    IgnoredEntries: Integer;
    { True when the live set was computed; Live* and Evictable* are then
      exact. A writing pass under budget skips it. }
    Analyzed: Boolean;
    { False when the live set could not be determined; nothing is removed. }
    Complete: Boolean;
    Incomplete: string;
    LiveDocuments: Integer;
    LiveBytes: Int64;
    EvictableDocuments: Integer;
    EvictableBytes: Int64;
    EvictedDocuments: Integer;
    EvictedBytes: Int64;
    { Evictable documents a removal failed for (for example still open on
      Windows); they stay, and a later pass tries again. }
    RetainedDocuments: Integer;
    RetainedBytes: Int64;
  end;

  { One directory entry, described without following links. }
  TLWPTRegistryStoreEntry = record
    Name: string;
    { A regular file: not a link, reparse point, directory, or device. }
    Regular: Boolean;
    Size: Int64;
  end;
  TLWPTRegistryStoreEntryArray = array of TLWPTRegistryStoreEntry;

function RegistryStateDocumentPath(const ARoot, AHash: string): string;
function RegistryStateDocumentsDirectory(const ARoot: string): string;
function RegistryDocumentRecencyPath(const ARoot: string): string;
{ Lists ADirectory without following links (lstat on Unix, find data
  attributes on Windows). True with no entries when it does not exist. False,
  with AError, when it exists but cannot be listed completely, or holds more
  than AMaximum entries. }
function ListRegistryStoreDirectory(const ADirectory: string;
  const AMaximum: Integer; out AEntries: TLWPTRegistryStoreEntryArray;
  out AError: string): Boolean;
{ True when APath is a regular file, checked without following a link. }
function RegistryStoreFileIsRegular(const APath: string): Boolean;
{ The budget from AValue: empty selects the default; otherwise an integer
  from 0 through High(Int64). Raises registry_state_budget_invalid. }
function ResolveRegistryStateMaxBytesFromValue(const AValue: string): Int64;
function ResolveRegistryStateMaxBytes: Int64;
function RegistryStoreNowMilliseconds: Int64;
{ One pass over the store at ARoot. ARoots are the stored states' accepted
  histories; a non-empty ARootsIncomplete says they could not all be read.
  A reading pass (AWrite False) computes the live set and writes nothing.
  A writing pass, which the caller runs under the store lease, stamps AUsed
  and unstamped documents with ANow, evicts least-recently-used evictable
  documents while their bytes exceed ABudget, and replaces the recency
  index atomically. }
function RunRegistryDocumentStorePass(const ARoot: string;
  const ARoots: TLWPTRegistryStoreRootArray; const ARootsIncomplete: string;
  const AUsed: TStringArray; const ABudget, ANow: Int64;
  const ALimits: TLWPTRegistryVerificationLimits;
  const AWrite: Boolean): TLWPTRegistryStoreReport;
{ The recency stamps by hex digest. A missing, corrupt, or oversized index
  loads as empty, and malformed lines are skipped: recency never decides
  liveness, so a lost stamp only makes a document look newly seen. }
function LoadRegistryDocumentRecency(const ARoot: string): TLWPTRegistryRecency;
{ Replaces the stamps of AHashes ("sha256:<hex>") with AStamp; the caller
  holds the store lease. }
procedure StampRegistryDocuments(const ARoot: string;
  const AHashes: TStringArray; const AStamp: Int64);



implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  DateUtils,
  StrUtils
  {$IFDEF MSWINDOWS},
  Windows
  {$ENDIF};

const
  DOCUMENT_EXTENSION = '.toml';

function RegistryStateDocumentsDirectory(const ARoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARoot) + 'documents/sha256';
end;

function RegistryStateDocumentPath(const ARoot, AHash: string): string;
begin
  Result := RegistryStateDocumentsDirectory(ARoot) + '/'
    + RegistryDigestHex(AHash) + DOCUMENT_EXTENSION;
end;

function RegistryDocumentRecencyPath(const ARoot: string): string;
begin
  { Outside documents/, so a document directory that refuses removals still
    takes the index. }
  Result := IncludeTrailingPathDelimiter(ARoot) + 'recency';
end;

function ResolveRegistryStateMaxBytesFromValue(const AValue: string): Int64;
var Parsed: QWord; Value: string; Index: Integer; Decimal: Boolean;
begin
  Value := Trim(AValue);
  if Value = '' then Exit(RegistryStateDefaultMaxBytes);
  { TryStrToQWord also accepts signs and $, 0x, and & prefixes. }
  Decimal := True;
  for Index := 1 to Length(Value) do
    if not (Value[Index] in ['0'..'9']) then Decimal := False;
  if not Decimal or not TryStrToQWord(Value, Parsed)
     or (Parsed > QWord(High(Int64))) then
    raise ELWPTRegistryError.CreateStable('registry_state_budget_invalid',
      REGISTRY_STATE_MAX_BYTES_ENV + ' must be an integer from 0 through '
      + IntToStr(High(Int64)) + ' bytes, got "' + AValue + '"');
  Result := Int64(Parsed);
end;

function ResolveRegistryStateMaxBytes: Int64;
begin
  Result := ResolveRegistryStateMaxBytesFromValue(
    SysUtils.GetEnvironmentVariable(REGISTRY_STATE_MAX_BYTES_ENV));
end;

function RegistryStoreNowMilliseconds: Int64;
var Current: TDateTime;
begin
  Current := Now;
  Result := DateTimeToUnix(Current, False) * 1000
    + MilliSecondOfTheSecond(Current);
end;

{$IFDEF UNIX}
function DescribeUnixEntry(const APath: string; out ARegular: Boolean;
  out ASize: Int64): cint;
var Info: TStat;
begin
  ARegular := False;
  ASize := 0;
  if fpLStat(PChar(APath), Info) <> 0 then Exit(fpgeterrno);
  ARegular := fpS_ISREG(Info.st_mode);
  ASize := Info.st_size;
  Result := 0;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
const
  NON_REGULAR_ATTRIBUTES = FILE_ATTRIBUTE_DIRECTORY
    or FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DEVICE;
{$ENDIF}

function RegistryStoreFileIsRegular(const APath: string): Boolean;
{$IFDEF UNIX}
var Size: Int64;
begin
  Result := (DescribeUnixEntry(APath, Result, Size) = 0) and Result;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var Attributes: DWORD;
begin
  Attributes := GetFileAttributesW(PWideChar(UnicodeString(APath)));
  Result := (Attributes <> INVALID_FILE_ATTRIBUTES)
    and ((Attributes and NON_REGULAR_ATTRIBUTES) = 0);
end;
{$ENDIF}

function ListRegistryStoreDirectory(const ADirectory: string;
  const AMaximum: Integer; out AEntries: TLWPTRegistryStoreEntryArray;
  out AError: string): Boolean;
var
  Count: Integer;

  function Add(const AName: string; const ARegular: Boolean;
    const ASize: Int64): Boolean;
  begin
    if Count >= AMaximum then
    begin
      AError := ADirectory + ' holds more than ' + IntToStr(AMaximum)
        + ' entries';
      Exit(False);
    end;
    if Count > High(AEntries) then SetLength(AEntries, 2 * Count + 64);
    AEntries[Count].Name := AName;
    AEntries[Count].Regular := ARegular;
    AEntries[Count].Size := ASize;
    Inc(Count);
    Result := True;
  end;

{$IFDEF UNIX}
var
  Directory: pDir;
  Entry: pDirent;
  Name: string;
  Regular: Boolean;
  Size: Int64;
  Error: cint;
  Info: TStat;
begin
  AEntries := nil;
  AError := '';
  Count := 0;
  Result := False;
  { The entry itself, not a link's target: only a truly missing entry is
    empty. A link, dangling or not, or any other non-directory is not. }
  if fpLStat(PChar(ADirectory), Info) <> 0 then
  begin
    Error := fpgeterrno;
    if Error = ESysENOENT then Exit(True);
    AError := ADirectory + ' cannot be examined (error ' + IntToStr(Error) + ')';
    Exit;
  end;
  if not fpS_ISDIR(Info.st_mode) then
  begin
    AError := ADirectory + ' is not a directory (a link or another kind of file)';
    Exit;
  end;
  Directory := fpOpenDir(PChar(ADirectory));
  if Directory = nil then
  begin
    Error := fpgeterrno;
    AError := ADirectory + ' cannot be listed (error ' + IntToStr(Error) + ')';
    Exit;
  end;
  try
    repeat
      fpSetErrno(0);
      Entry := fpReadDir(Directory^);
      if Entry = nil then
      begin
        Error := fpgeterrno;
        if Error <> 0 then
        begin
          AError := ADirectory + ' could not be listed completely (error '
            + IntToStr(Error) + ')';
          Exit;
        end;
        Break;
      end;
      Name := StrPas(PChar(@Entry^.d_name[0]));
      if (Name = '.') or (Name = '..') then Continue;
      Error := DescribeUnixEntry(ADirectory + '/' + Name, Regular, Size);
      { An entry replaced or removed since it was listed is no longer
        there; any other failure leaves the listing uncertain. }
      if Error = ESysENOENT then Continue;
      if Error <> 0 then
      begin
        AError := ADirectory + '/' + Name + ' cannot be examined (error '
          + IntToStr(Error) + ')';
        Exit;
      end;
      if not Add(Name, Regular, Size) then Exit;
    until False;
  finally
    fpCloseDir(Directory^);
  end;
  SetLength(AEntries, Count);
  Result := True;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
  Data: TWin32FindDataW;
  Name: string;
  Error, Attributes: DWORD;
begin
  AEntries := nil;
  AError := '';
  Count := 0;
  Result := False;
  { The attributes of the path itself: only a truly missing entry is empty.
    A reparse point (link or junction) or any non-directory is not. }
  Attributes := GetFileAttributesW(PWideChar(UnicodeString(ADirectory)));
  if Attributes = INVALID_FILE_ATTRIBUTES then
  begin
    Error := GetLastError;
    if (Error = ERROR_FILE_NOT_FOUND) or (Error = ERROR_PATH_NOT_FOUND) then
      Exit(True);
    AError := ADirectory + ' cannot be examined (error ' + IntToStr(Error) + ')';
    Exit;
  end;
  if ((Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0)
     or ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
  begin
    AError := ADirectory + ' is not a directory (a link or another kind of file)';
    Exit;
  end;
  Handle := FindFirstFileW(PWideChar(UnicodeString(ADirectory + '\*')), Data);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    AError := ADirectory + ' cannot be listed (error ' + IntToStr(Error) + ')';
    Exit;
  end;
  try
    repeat
      Name := string(UnicodeString(PWideChar(@Data.cFileName[0])));
      if (Name <> '.') and (Name <> '..') then
        if not Add(Name, (Data.dwFileAttributes and NON_REGULAR_ATTRIBUTES) = 0,
             (Int64(Data.nFileSizeHigh) shl 32) or Int64(Data.nFileSizeLow)) then
          Exit;
      if not FindNextFileW(Handle, Data) then
      begin
        Error := GetLastError;
        if Error <> ERROR_NO_MORE_FILES then
        begin
          AError := ADirectory + ' could not be listed completely (error '
            + IntToStr(Error) + ')';
          Exit;
        end;
        Break;
      end;
    until False;
  finally
    Windows.FindClose(Handle);
  end;
  SetLength(AEntries, Count);
  Result := True;
end;
{$ENDIF}

function IsLowerHexDigest(const AValue: string): Boolean;
var Index: Integer;
begin
  if Length(AValue) <> 64 then Exit(False);
  for Index := 1 to Length(AValue) do
    if not (AValue[Index] in ['0'..'9', 'a'..'f']) then Exit(False);
  Result := True;
end;

{ The hex digest of a canonical document file name, or ''. }
function DocumentNameDigest(const AName: string): string;
begin
  Result := '';
  if (Length(AName) <> 64 + Length(DOCUMENT_EXTENSION))
     or not EndsStr(DOCUMENT_EXTENSION, AName) then Exit;
  if IsLowerHexDigest(Copy(AName, 1, 64)) then Result := Copy(AName, 1, 64);
end;

function HashDigest(const AHash: string): string;
begin
  if RegistryHashIsCanonical(AHash) then Result := RegistryDigestHex(AHash)
  else Result := '';
end;

{ The bytes of the regular file APath when it holds at most AMaximum bytes;
  nil when absent, not a regular file (never opened), unreadable, or
  larger. }
function ReadSmallFile(const APath: string; const AMaximum: Int64): TBytes;
var Stream: TFileStream;
begin
  Result := nil;
  if not RegistryStoreFileIsRegular(APath) then Exit;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: EFOpenError do Exit;
  end;
  try
    if Stream.Size > AMaximum then Exit;
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

{ Ordinal ascending sort; byte order never depends on the locale. }
procedure SortOrdinal(var AValues: TStringArray);
var Scratch: TStringArray;

  procedure Sort(ALow, AHigh: Integer);
  var Middle, Left, Right, Target: Integer;
  begin
    if ALow >= AHigh then Exit;
    Middle := (ALow + AHigh) div 2;
    Sort(ALow, Middle);
    Sort(Middle + 1, AHigh);
    Left := ALow;
    Right := Middle + 1;
    Target := ALow;
    while (Left <= Middle) or (Right <= AHigh) do
    begin
      if (Right > AHigh) or ((Left <= Middle)
         and (CompareStr(AValues[Left], AValues[Right]) <= 0)) then
      begin
        Scratch[Target] := AValues[Left];
        Inc(Left);
      end
      else
      begin
        Scratch[Target] := AValues[Right];
        Inc(Right);
      end;
      Inc(Target);
    end;
    for Target := ALow to AHigh do AValues[Target] := Scratch[Target];
  end;

begin
  SetLength(Scratch, Length(AValues));
  Sort(0, High(AValues));
end;

{ The canonical snapshot's predecessor and records. False unless the text
  is a snapshot whose `previous` and `records` are canonical. }
function ParseSnapshotLinks(const AText: string; out APrevious: string;
  out ARecords: TStringArray): Boolean;
var Start, Finish, Count: Integer; Line, Item: string;
begin
  APrevious := '';
  ARecords := nil;
  Result := False;
  if not StartsStr('schema = "' + PROGRAM_NAME + '-registry-snapshot-v1"'#10,
       AText) then Exit;
  Start := Pos(#10'previous = "', AText);
  if Start = 0 then Exit;
  Start := Start + Length(#10'previous = "');
  Finish := PosEx('"', AText, Start);
  if Finish = 0 then Exit;
  APrevious := Copy(AText, Start, Finish - Start);
  if (APrevious <> '') and not RegistryHashIsCanonical(APrevious) then Exit;
  Start := Pos(#10'records = [', AText);
  if Start = 0 then Exit;
  Start := Start + Length(#10'records = [');
  Finish := PosEx(']', AText, Start);
  if Finish = 0 then Exit;
  Line := Copy(AText, Start, Finish - Start);
  { Each quoted hash takes at least 73 bytes. }
  SetLength(ARecords, Length(Line) div 73 + 1);
  Count := 0;
  Start := 1;
  while Start <= Length(Line) do
  begin
    if Line[Start] in [' ', ','] then
    begin
      Inc(Start);
      Continue;
    end;
    if Line[Start] <> '"' then Exit;
    Finish := PosEx('"', Line, Start + 1);
    if Finish = 0 then Exit;
    Item := Copy(Line, Start + 1, Finish - Start - 1);
    if not RegistryHashIsCanonical(Item) or (Count > High(ARecords)) then Exit;
    ARecords[Count] := Item;
    Inc(Count);
    Start := Finish + 1;
  end;
  SetLength(ARecords, Count);
  Result := True;
end;

function LoadRegistryDocumentRecency(const ARoot: string): TLWPTRegistryRecency;
var
  Lines: TStringList;
  Bytes: TBytes;
  Index: Integer;
  Line, Digest: string;
  Stamp: Int64;
begin
  Result := TLWPTRegistryRecency.Create;
  Bytes := ReadSmallFile(RegistryDocumentRecencyPath(ARoot),
    RegistryRecencyIndexMaxBytes);
  if Bytes = nil then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := RegistryBytesText(Bytes);
    if (Lines.Count = 0) or (Lines[0] <> REGISTRY_DOCUMENT_RECENCY_SCHEMA) then
      Exit;
    for Index := 1 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      if (Length(Line) < 66) or (Line[65] <> ' ') then Continue;
      Digest := Copy(Line, 1, 64);
      if not IsLowerHexDigest(Digest)
         or not TryStrToInt64(Copy(Line, 66, MaxInt), Stamp)
         or (Stamp < 0) then Continue;
      Result.AddOrSetValue(Digest, Stamp);
    end;
  finally
    Lines.Free;
  end;
end;

procedure WriteRecency(const ARoot: string; ARecency: TLWPTRegistryRecency);
var
  Lines: TStringList;
  Digests: TStringArray;
  Digest: string;
  Index: Integer;
begin
  SetLength(Digests, ARecency.Count);
  Index := 0;
  for Digest in ARecency.Keys do
  begin
    Digests[Index] := Digest;
    Inc(Index);
  end;
  SortOrdinal(Digests);
  Lines := TStringList.Create;
  try
    Lines.Add(REGISTRY_DOCUMENT_RECENCY_SCHEMA);
    for Index := 0 to High(Digests) do
      Lines.Add(Digests[Index] + ' ' + IntToStr(ARecency[Digests[Index]]));
    ForceDirectories(IncludeTrailingPathDelimiter(ARoot) + 'tmp');
    AtomicWriteText(RegistryDocumentRecencyPath(ARoot),
      IncludeTrailingPathDelimiter(ARoot) + 'tmp', Lines);
  finally
    Lines.Free;
  end;
end;

procedure StampRegistryDocuments(const ARoot: string;
  const AHashes: TStringArray; const AStamp: Int64);
var Recency: TLWPTRegistryRecency; Index: Integer;
begin
  Recency := LoadRegistryDocumentRecency(ARoot);
  try
    for Index := 0 to High(AHashes) do
      if HashDigest(AHashes[Index]) <> '' then
        Recency.AddOrSetValue(HashDigest(AHashes[Index]), AStamp);
    WriteRecency(ARoot, Recency);
  finally
    Recency.Free;
  end;
end;

type
  TStoreDocument = record
    Digest: string;
    Size: Int64;
    Live: Boolean;
  end;

function RunRegistryDocumentStorePass(const ARoot: string;
  const ARoots: TLWPTRegistryStoreRootArray; const ARootsIncomplete: string;
  const AUsed: TStringArray; const ABudget, ANow: Int64;
  const ALimits: TLWPTRegistryVerificationLimits;
  const AWrite: Boolean): TLWPTRegistryStoreReport;
var
  Directory: string;
  Documents: array of TStoreDocument;
  { Digest -> index into Documents. }
  Present: TDictionary<string, Integer>;
  Checkpoints, Walked: TDictionary<string, Boolean>;

  procedure MarkIncomplete(const AReason: string);
  begin
    if not Result.Complete then Exit;
    Result.Complete := False;
    Result.Incomplete := AReason;
  end;

  function DocumentPath(const ADigest: string): string;
  begin
    Result := Directory + '/' + ADigest + DOCUMENT_EXTENSION;
  end;

  procedure ListDocuments;
  var
    Entries: TLWPTRegistryStoreEntryArray;
    Error, Digest: string;
    Index, Count: Integer;
  begin
    if not ListRegistryStoreDirectory(Directory, RegistryStoreScanEntries,
         Entries, Error) then
    begin
      MarkIncomplete(Error);
      Exit;
    end;
    SetLength(Documents, Length(Entries));
    Count := 0;
    for Index := 0 to High(Entries) do
    begin
      Digest := DocumentNameDigest(Entries[Index].Name);
      if (Digest = '') or not Entries[Index].Regular then
      begin
        Inc(Result.IgnoredEntries);
        Continue;
      end;
      Documents[Count].Digest := Digest;
      Documents[Count].Size := Entries[Index].Size;
      Documents[Count].Live := False;
      Present.AddOrSetValue(Digest, Count);
      Inc(Result.DocumentBytes, Entries[Index].Size);
      Inc(Count);
    end;
    SetLength(Documents, Count);
    Result.Documents := Count;
  end;

  function DocumentIndex(const ADigest: string): Integer;
  begin
    if (ADigest = '') or not Present.TryGetValue(ADigest, Result) then
      Result := -1;
  end;

  procedure MarkLive(const AHash: string);
  var Index: Integer;
  begin
    Index := DocumentIndex(HashDigest(AHash));
    if Index >= 0 then Documents[Index].Live := True;
  end;

  procedure WalkHistory(const ASnapshot: string);
  var
    Current, Digest, Previous: string;
    Records: TStringArray;
    Bytes: TBytes;
    Index, Item, Steps: Integer;
    Total: Int64;
  begin
    Current := ASnapshot;
    Steps := 0;
    Total := 0;
    while (Current <> '') and Result.Complete do
    begin
      Digest := HashDigest(Current);
      if Digest = '' then
      begin
        MarkIncomplete('an accepted history names the invalid snapshot "'
          + Current + '"');
        Exit;
      end;
      MarkLive(Current);
      { A chain shared with an earlier root was followed already. }
      if Walked.ContainsKey(Digest) then Exit;
      Walked.Add(Digest, True);
      Index := DocumentIndex(Digest);
      { Every acquisition stores its whole history, so a gap means the live
        set behind it is unknown. }
      if Index < 0 then
      begin
        MarkIncomplete('accepted snapshot ' + Current + ' is missing from '
          + Directory + '; the next online install stores it again');
        Exit;
      end;
      if Steps >= ALimits.Snapshots then
      begin
        MarkIncomplete('an accepted history exceeds '
          + IntToStr(ALimits.Snapshots) + ' snapshots');
        Exit;
      end;
      if (Documents[Index].Size > ALimits.DocumentBytes)
         or (Documents[Index].Size > ALimits.TotalBytes - Total) then
      begin
        MarkIncomplete('an accepted history exceeds the verifier''s '
          + 'metadata byte limits');
        Exit;
      end;
      Bytes := ReadSmallFile(DocumentPath(Digest), ALimits.DocumentBytes);
      Inc(Steps);
      Inc(Total, Int64(Length(Bytes)));
      if (Bytes = nil) and (Documents[Index].Size > 0) then
      begin
        MarkIncomplete('accepted snapshot ' + DocumentPath(Digest)
          + ' cannot be read');
        Exit;
      end;
      if (SHA256BytesPrefixed(Bytes) <> Current)
         or not ParseSnapshotLinks(RegistryBytesText(Bytes), Previous, Records) then
      begin
        MarkIncomplete('accepted snapshot ' + DocumentPath(Digest)
          + ' is corrupt; delete it so the next online install stores a '
          + 'verified copy');
        Exit;
      end;
      for Item := 0 to High(Records) do MarkLive(Records[Item]);
      Current := Previous;
    end;
  end;

  { A signature envelope is live when it names a live checkpoint. }
  procedure MarkSignatures;
  var Index: Integer; Bytes: TBytes; Payload: string;
  begin
    if Checkpoints.Count = 0 then Exit;
    for Index := 0 to High(Documents) do
    begin
      if not Result.Complete then Exit;
      if Documents[Index].Live
         or (Documents[Index].Size > RegistryStoreSignatureProbeBytes) then
        Continue;
      Bytes := ReadSmallFile(DocumentPath(Documents[Index].Digest),
        RegistryStoreSignatureProbeBytes);
      if (Bytes = nil) and (Documents[Index].Size > 0) then
      begin
        MarkIncomplete(DocumentPath(Documents[Index].Digest)
          + ' cannot be read, so whether it is a live signature is unknown');
        Exit;
      end;
      { Bytes that do not hash to the name are not that document, and no
        other document's liveness depends on a signature: it stays
        evictable. }
      if (SHA256BytesPrefixed(Bytes) <> 'sha256:' + Documents[Index].Digest)
         or not StartsStr('schema = "' + PROGRAM_NAME
           + '-registry-signature-v1"', RegistryBytesText(Bytes)) then
        Continue;
      try
        Payload := InspectRegistrySignaturePayload(Bytes);
      except
        on E: Exception do
        begin
          MarkIncomplete(DocumentPath(Documents[Index].Digest)
            + ' is a signature envelope that cannot be parsed');
          Exit;
        end;
      end;
      if Checkpoints.ContainsKey(HashDigest(Payload)) then
        Documents[Index].Live := True;
    end;
  end;

  procedure ComputeLiveSet;
  var Index, Item: Integer;
  begin
    for Index := 0 to High(ARoots) do
    begin
      if not Result.Complete then Break;
      MarkLive(ARoots[Index].Checkpoint);
      if HashDigest(ARoots[Index].Checkpoint) <> '' then
        Checkpoints.AddOrSetValue(HashDigest(ARoots[Index].Checkpoint), True);
      for Item := 0 to High(ARoots[Index].Rotations) do
        MarkLive(ARoots[Index].Rotations[Item]);
      WalkHistory(ARoots[Index].Snapshot);
    end;
    if Result.Complete then MarkSignatures;
    if not Result.Complete then Exit;
    Result.Analyzed := True;
    for Index := 0 to High(Documents) do
      if Documents[Index].Live then
      begin
        Inc(Result.LiveDocuments);
        Inc(Result.LiveBytes, Documents[Index].Size);
      end
      else
      begin
        Inc(Result.EvictableDocuments);
        Inc(Result.EvictableBytes, Documents[Index].Size);
      end;
  end;

  procedure UpdateAndEvict;
  var
    Recency, Published: TLWPTRegistryRecency;
    Stamps: array of Int64;
    Order: TStringArray;
    Victims: array of Integer;
    Index, Position, Count: Integer;
    Stamp, Remaining: Int64;
  begin
    Recency := LoadRegistryDocumentRecency(ARoot);
    Published := TLWPTRegistryRecency.Create;
    try
      SetLength(Stamps, Length(Documents));
      { A document without a stamp is first seen now. }
      for Index := 0 to High(Documents) do
      begin
        if not Recency.TryGetValue(Documents[Index].Digest, Stamp) then
          Stamp := ANow;
        Stamps[Index] := Stamp;
      end;
      for Index := 0 to High(AUsed) do
      begin
        Position := DocumentIndex(HashDigest(AUsed[Index]));
        if Position >= 0 then Stamps[Position] := ANow;
      end;
      for Index := 0 to High(Documents) do
        Published.AddOrSetValue(Documents[Index].Digest, Stamps[Index]);
      { Victims are chosen first: oldest stamp, then digest. Stamps are
        non-negative, so the zero-padded decimal sorts numerically. }
      Victims := nil;
      if Result.Analyzed and Result.Complete
         and (Result.EvictableBytes > ABudget) then
      begin
        SetLength(Order, Result.EvictableDocuments);
        Count := 0;
        for Index := 0 to High(Documents) do
          if not Documents[Index].Live then
          begin
            Stamp := Stamps[Index];
            if Stamp < 0 then Stamp := 0;
            Order[Count] := Format('%.19d', [Stamp]) + Documents[Index].Digest;
            Inc(Count);
          end;
        SortOrdinal(Order);
        Remaining := Result.EvictableBytes;
        SetLength(Victims, Length(Order));
        Count := 0;
        for Position := 0 to High(Order) do
        begin
          if Remaining <= ABudget then Break;
          Index := DocumentIndex(Copy(Order[Position], 20, 64));
          Victims[Count] := Index;
          Inc(Count);
          Dec(Remaining, Documents[Index].Size);
        end;
        SetLength(Victims, Count);
      end;
      { The index is published before any removal: a failed write raises
        with every document still in place. A victim keeps its entry, so a
        removal that fails keeps its stamp; the next pass prunes the rest. }
      WriteRecency(ARoot, Published);
      for Position := 0 to High(Victims) do
      begin
        Index := Victims[Position];
        if SysUtils.DeleteFile(DocumentPath(Documents[Index].Digest)) then
        begin
          Inc(Result.EvictedDocuments);
          Inc(Result.EvictedBytes, Documents[Index].Size);
        end
        else
        begin
          Inc(Result.RetainedDocuments);
          Inc(Result.RetainedBytes, Documents[Index].Size);
        end;
      end;
    finally
      Published.Free;
      Recency.Free;
    end;
  end;

begin
  Result := Default(TLWPTRegistryStoreReport);
  Result.BudgetBytes := ABudget;
  Result.StateFiles := Length(ARoots);
  Result.Complete := True;
  Directory := RegistryStateDocumentsDirectory(ARoot);
  Documents := nil;
  Present := TDictionary<string, Integer>.Create;
  Checkpoints := TDictionary<string, Boolean>.Create;
  Walked := TDictionary<string, Boolean>.Create;
  try
    { A state set that could not be read is uncertain whatever the budget,
      and the report says so even when the shortcut below skips the walk. }
    if ARootsIncomplete <> '' then MarkIncomplete(ARootsIncomplete);
    ListDocuments;
    if not Result.Complete then
    begin
      { Recency is still recorded; nothing is removed. }
      if AWrite and (Length(Documents) > 0) then UpdateAndEvict;
      Exit;
    end;
    { Under budget nothing can be evictable beyond it, so a writing pass
      only records recency. }
    if not AWrite or (Result.DocumentBytes > ABudget) then ComputeLiveSet;
    if AWrite then UpdateAndEvict;
  finally
    Walked.Free;
    Checkpoints.Free;
    Present.Free;
  end;
end;

end.
