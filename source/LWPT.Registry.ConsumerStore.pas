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
      `previous` links among stored, hash-verified snapshots;
    - every record those snapshots name; and
    - the accepted rotation triplets.
  A committed selection proof of a lock lies on that history (the head must
  extend it), so its snapshot, records, and rotations are live; only a
  superseded checkpoint and its signature are not.

  Every other document is evictable: superseded checkpoints and their
  signatures, documents of deleted or re-pinned states, and documents behind
  a missing or corrupt chain link. Evictable bytes are capped by
  LWPT_REGISTRY_STATE_MAX_BYTES; beyond it, the least recently used go first.
  Recency is an access stamp kept in one index file, written atomically
  under the store lease by each successful online install for the
  documents it verified or its lock references. A document without a stamp
  is stamped when a pass first sees it.

  Passes are bounded: at most RegistryStoreScanEntries documents are listed,
  each chain is read within the verifier's snapshot, per-document, and total
  byte limits, and only small evictable documents are opened to recognise
  signatures. A pass that cannot determine the live set completely removes
  nothing. Foreign entries (other names, directories, links) are never
  counted or removed, and state files are never touched. }
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
    { Evictable documents a removal failed for (for example still open). }
    RetainedDocuments: Integer;
  end;

function RegistryStateDocumentPath(const ARoot, AHash: string): string;
function RegistryStateDocumentsDirectory(const ARoot: string): string;
function RegistryDocumentRecencyPath(const ARoot: string): string;
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
  DateUtils,
  StrUtils;

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
  Result := IncludeTrailingPathDelimiter(ARoot) + 'documents/recency';
end;

function ResolveRegistryStateMaxBytesFromValue(const AValue: string): Int64;
var Parsed: QWord; Value: string;
begin
  Value := Trim(AValue);
  if Value = '' then Exit(RegistryStateDefaultMaxBytes);
  { TryStrToQWord also accepts "$" hexadecimal and signs. }
  if not (Value[1] in ['0'..'9']) or not TryStrToQWord(Value, Parsed)
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

{ The bytes of APath when it holds at most AMaximum bytes; nil when absent,
  unreadable (for example removed concurrently), or larger. }
function ReadSmallFile(const APath: string; const AMaximum: Int64): TBytes;
var Stream: TFileStream;
begin
  Result := nil;
  if not FileExists(APath) then Exit;
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
  var Entry: TSearchRec; Digest: string; Count: Integer;
  begin
    Count := 0;
    if FindFirst(Directory + '/*', faAnyFile, Entry) = 0 then
    try
      repeat
        if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
        Digest := DocumentNameDigest(Entry.Name);
        if (Digest = '') or ((Entry.Attr and faDirectory) <> 0)
           {$IFDEF UNIX} or ((Entry.Attr and faSymLink) <> 0) {$ENDIF} then
        begin
          Inc(Result.IgnoredEntries);
          Continue;
        end;
        if Count >= RegistryStoreScanEntries then
        begin
          MarkIncomplete('the document store lists more than '
            + IntToStr(RegistryStoreScanEntries) + ' documents');
          Break;
        end;
        if Count > High(Documents) then SetLength(Documents, 2 * Count + 64);
        Documents[Count].Digest := Digest;
        Documents[Count].Size := Entry.Size;
        Documents[Count].Live := False;
        Present.AddOrSetValue(Digest, Count);
        Inc(Result.DocumentBytes, Int64(Entry.Size));
        Inc(Count);
      until SysUtils.FindNext(Entry) <> 0;
    finally
      SysUtils.FindClose(Entry);
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
      MarkLive(Current);
      Digest := HashDigest(Current);
      { A chain shared with an earlier root was followed already. }
      if (Digest = '') or Walked.ContainsKey(Digest) then Exit;
      Walked.Add(Digest, True);
      Index := DocumentIndex(Digest);
      { A missing link ends the chain: the next acquisition transfers what
        lies behind it again. }
      if Index < 0 then Exit;
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
      { A corrupt or unreadable link stays live by name; the chain behind it
        is not followed. }
      if (Bytes = nil) or (SHA256BytesPrefixed(Bytes) <> Current) then Exit;
      if not ParseSnapshotLinks(RegistryBytesText(Bytes), Previous, Records) then
        Exit;
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
      if Documents[Index].Live
         or (Documents[Index].Size > RegistryStoreSignatureProbeBytes) then
        Continue;
      Bytes := ReadSmallFile(DocumentPath(Documents[Index].Digest),
        RegistryStoreSignatureProbeBytes);
      if (Bytes = nil)
         or not StartsStr('schema = "' + PROGRAM_NAME
           + '-registry-signature-v1"', RegistryBytesText(Bytes))
         or (SHA256BytesPrefixed(Bytes) <> 'sha256:' + Documents[Index].Digest) then
        Continue;
      try
        Payload := InspectRegistrySignaturePayload(Bytes);
      except
        on E: Exception do Continue;
      end;
      if Checkpoints.ContainsKey(HashDigest(Payload)) then
        Documents[Index].Live := True;
    end;
  end;

  procedure ComputeLiveSet;
  var Index, Item: Integer;
  begin
    if ARootsIncomplete <> '' then MarkIncomplete(ARootsIncomplete);
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
    if not Result.Complete then Exit;
    MarkSignatures;
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
    Recency, Survivors: TLWPTRegistryRecency;
    Stamps: array of Int64;
    Order: TStringArray;
    Index, Position, Count: Integer;
    Stamp: Int64;
  begin
    Recency := LoadRegistryDocumentRecency(ARoot);
    Survivors := TLWPTRegistryRecency.Create;
    try
      SetLength(Stamps, Length(Documents));
      { A document without a stamp is first seen now. }
      for Index := 0 to High(Documents) do
      begin
        if not Recency.TryGetValue(Documents[Index].Digest, Stamp) then
          Stamp := ANow;
        Stamps[Index] := Stamp;
        Survivors.AddOrSetValue(Documents[Index].Digest, Stamp);
      end;
      for Index := 0 to High(AUsed) do
      begin
        Position := DocumentIndex(HashDigest(AUsed[Index]));
        if Position < 0 then Continue;
        Stamps[Position] := ANow;
        Survivors.AddOrSetValue(Documents[Position].Digest, ANow);
      end;
      if Result.Analyzed and (Result.EvictableBytes > ABudget) then
      begin
        { Oldest stamp first; the digest breaks ties. Stamps are
          non-negative, so the zero-padded decimal sorts numerically. }
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
        for Position := 0 to High(Order) do
        begin
          if Result.EvictableBytes - Result.EvictedBytes <= ABudget then Break;
          Index := DocumentIndex(Copy(Order[Position], 20, 64));
          if SysUtils.DeleteFile(DocumentPath(Documents[Index].Digest)) then
          begin
            Survivors.Remove(Documents[Index].Digest);
            Inc(Result.EvictedDocuments);
            Inc(Result.EvictedBytes, Documents[Index].Size);
          end
          else Inc(Result.RetainedDocuments);
        end;
      end;
      WriteRecency(ARoot, Survivors);
    finally
      Survivors.Free;
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
    ListDocuments;
    if not Result.Complete then Exit;
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
