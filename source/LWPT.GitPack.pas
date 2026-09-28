unit LWPT.GitPack;

{$I Shared.inc}

{ LWPT.GitPack — a bounded reader for commits-only git packfiles.

  Commit-pin verification (ADR-0047) asks a git host for the commits between
  its advertised branch and tag tips and the pinned commit, then walks their
  parent links. This unit turns such a pack into a commit graph whose every
  node id was recomputed locally from the received bytes, so the walk never
  trusts an id the server merely claimed.

  Pack format (gitformat-pack, version 2 and 3):

    'PACK' | version (4 bytes BE) | object count (4 bytes BE)
    entry* | SHA-1 of everything before it (20 bytes)

    entry = type+size varint | [base] | zlib stream of the payload
      types 1-4: commit, tree, blob, tag (payload is the object)
      type 6:    OFS_DELTA, base is an earlier entry at a relative offset
      type 7:    REF_DELTA, base is named by its 20-byte object id and may
                 appear anywhere in the pack

  The reader is written for hostile input. Every length is bounded before it
  is used, the object count, per-object size, total inflated bytes and the
  inflate ratio are capped, delta instructions are range-checked, and a delta
  whose base never resolves (a thin pack, a cycle, or a dangling id) fails
  the whole pack. Only commits and annotated tags are accepted: the request
  filters out trees and blobs, and a pack that carries them anyway is
  refused rather than held in memory. }

interface

uses
  Generics.Collections,
  SysUtils;

const
  GIT_OBJECT_ID_LENGTH = 40;

  { Upper bound on the object count a pack header may declare. A 64 MiB
    response holds far fewer commits than this; the cap stops a forged
    header from driving allocation or work. }
  MAX_PACK_OBJECT_COUNT = 1000000;
  { Largest inflated payload, delta instruction stream, or delta result for
    one object. Real commits are a few hundred bytes. }
  MAX_PACK_OBJECT_BYTES = 8 * 1024 * 1024;
  { Cumulative bytes produced by inflation and delta application. }
  MAX_PACK_INFLATED_BYTES = Int64(256) * 1024 * 1024;
  { Cumulative produced bytes may not exceed this multiple of the pack size
    (plus PACK_INFLATE_ALLOWANCE), which defeats zlib and delta bombs whose
    output dwarfs what was transferred. Commit text compresses about 2-4x. }
  MAX_PACK_INFLATE_RATIO = 32;
  PACK_INFLATE_ALLOWANCE = 1024 * 1024;

type
  EGitPackError = class(Exception);
  { Parsing or walking passed the caller's deadline. }
  EGitPackDeadlineExceeded = class(EGitPackError);

  TGitPackLimits = record
    MaxObjectCount: Integer;
    MaxObjectBytes: Integer;
    MaxInflatedBytes: Int64;
    MaxInflateRatio: Integer;
    { GetTickCount64 value after which parsing stops; 0 for none. }
    Deadline: QWord;
  end;

  TGitCommitRecord = record
    { Parent ids, concatenated 40-character lowercase hex. }
    Parents: string;
    { Committer timestamp (seconds since the epoch); 0 when unparseable.
      Used only to order probes, never to decide reachability. }
    CommitTime: Int64;
  end;

  { Commits and annotated tags whose ids were recomputed from pack bytes. }
  TGitCommitGraph = class
  private
    FCommits: TDictionary<string, TGitCommitRecord>;
    FTags: TDictionary<string, string>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AId: string; const ARecord: TGitCommitRecord);
    { An annotated tag whose object line names a commit or another tag. }
    procedure AddTag(const AId, ATarget: string);
    { The commit AId names, following verified tag objects; '' when the
      chain leaves the graph or does not end at a commit. }
    function PeelToCommit(const AId: string): string;
    function Contains(const AId: string): Boolean;
    function TryGetCommit(const AId: string;
      out ARecord: TGitCommitRecord): Boolean;
    function Count: Integer;
    { Index of the first start from which ATarget is reachable through
      objects held in this graph, or -1. ATarget itself need not be in the
      graph: it is reached when a visited commit lists it as a parent, a
      visited tag object names it, or a start equals it. A walk stops at
      ids the graph does not hold, so a pack that omits part of a path can
      only produce a false negative. }
    function FindReachingStart(const AStarts: array of string;
      const ATarget: string): Integer; overload;
    { As above, raising EGitPackDeadlineExceeded once GetTickCount64 passes
      ADeadline (0 for none). }
    function FindReachingStart(const AStarts: array of string;
      const ATarget: string; ADeadline: QWord): Integer; overload;
  end;

  TGitPackStatistics = record
    ObjectCount: Integer;
    DeltaCount: Integer;
    CommitCount: Integer;
    InflatedBytes: Int64;
  end;

function DefaultGitPackLimits: TGitPackLimits;

{ Parse APack into a commit graph. Raises EGitPackError on any malformed,
  truncated, over-limit, or non-commit content. }
function ReadCommitPack(const APack: TBytes;
  const ALimits: TGitPackLimits): TGitCommitGraph; overload;
function ReadCommitPack(const APack: TBytes; const ALimits: TGitPackLimits;
  out AStatistics: TGitPackStatistics): TGitCommitGraph; overload;

{ Lowercase hex SHA-1 of the loose-object encoding "<kind> <size>\0<data>". }
function GitObjectId(const AKind: string; const AData: AnsiString): string;

{ True for exactly 40 hex characters (either case). }
function IsFullGitObjectId(const AValue: string): Boolean;

implementation

uses
  paszlib,
  sha1;

const
  OBJ_COMMIT = 1;
  OBJ_TREE = 2;
  OBJ_BLOB = 3;
  OBJ_TAG = 4;
  OBJ_OFS_DELTA = 6;
  OBJ_REF_DELTA = 7;

  PACK_HEADER_BYTES = 12;
  PACK_TRAILER_BYTES = 20;
  RAW_OBJECT_ID_BYTES = 20;
  HEX_DIGITS: array[0..15] of Char = '0123456789abcdef';

type
  TPackEntry = record
    Offset: Integer;
    PackedKind: Integer;
    Kind: Integer;           { resolved object kind (1-4); 0 while pending }
    Data: AnsiString;     { payload, or delta instructions while pending }
    BaseEntry: Integer;      { OFS_DELTA base entry index }
    BaseId: string;          { REF_DELTA base object id }
    Id: string;
    NextWaiter: Integer;     { next delta waiting on the same base }
  end;

function DefaultGitPackLimits: TGitPackLimits;
begin
  Result.MaxObjectCount := MAX_PACK_OBJECT_COUNT;
  Result.MaxObjectBytes := MAX_PACK_OBJECT_BYTES;
  Result.MaxInflatedBytes := MAX_PACK_INFLATED_BYTES;
  Result.MaxInflateRatio := MAX_PACK_INFLATE_RATIO;
  Result.Deadline := 0;
end;

function IsFullGitObjectId(const AValue: string): Boolean;
var i: Integer;
begin
  Result := Length(AValue) = GIT_OBJECT_ID_LENGTH;
  if Result then
    for i := 1 to Length(AValue) do
      if not (AValue[i] in ['0'..'9', 'a'..'f', 'A'..'F']) then
        Exit(False);
end;

function IsLowerObjectId(const AValue: string): Boolean;
var i: Integer;
begin
  Result := Length(AValue) = GIT_OBJECT_ID_LENGTH;
  if Result then
    for i := 1 to Length(AValue) do
      if not (AValue[i] in ['0'..'9', 'a'..'f']) then
        Exit(False);
end;

function DigestHex(const ADigest: TSHA1Digest): string;
var i: Integer;
begin
  SetLength(Result, 2 * Length(ADigest));
  for i := 0 to High(ADigest) do
  begin
    Result[2 * i + 1] := HEX_DIGITS[ADigest[i] shr 4];
    Result[2 * i + 2] := HEX_DIGITS[ADigest[i] and $0F];
  end;
end;

function KindName(AKind: Integer): string;
begin
  case AKind of
    OBJ_COMMIT: Result := 'commit';
    OBJ_TREE: Result := 'tree';
    OBJ_BLOB: Result := 'blob';
    OBJ_TAG: Result := 'tag';
  else
    raise EGitPackError.CreateFmt('invalid git object type %d', [AKind]);
  end;
end;

function GitObjectId(const AKind: string; const AData: AnsiString): string;
var
  Context: TSHA1Context;
  Header: AnsiString;
  Digest: TSHA1Digest;
begin
  Header := AnsiString(AKind + ' ' + IntToStr(Length(AData))) + #0;
  SHA1Init(Context);
  SHA1Update(Context, Header[1], Length(Header));
  if Length(AData) > 0 then
    SHA1Update(Context, AData[1], Length(AData));
  SHA1Final(Context, Digest);
  Result := DigestHex(Digest);
end;

{ TGitCommitGraph }

constructor TGitCommitGraph.Create;
begin
  inherited Create;
  FCommits := TDictionary<string, TGitCommitRecord>.Create;
  FTags := TDictionary<string, string>.Create;
end;

destructor TGitCommitGraph.Destroy;
begin
  FTags.Free;
  FCommits.Free;
  inherited Destroy;
end;

procedure TGitCommitGraph.Add(const AId: string;
  const ARecord: TGitCommitRecord);
begin
  FCommits.AddOrSetValue(AId, ARecord);
end;

procedure TGitCommitGraph.AddTag(const AId, ATarget: string);
begin
  FTags.AddOrSetValue(AId, ATarget);
end;

function TGitCommitGraph.PeelToCommit(const AId: string): string;
var Id, Target: string; Hops: Integer;
begin
  Result := '';
  Id := AId;
  { Tag chains are short; the bound also stops a self-referencing chain. }
  for Hops := 0 to 16 do
  begin
    if FCommits.ContainsKey(Id) then Exit(Id);
    if not FTags.TryGetValue(Id, Target) then Exit;
    Id := Target;
  end;
end;

function TGitCommitGraph.Contains(const AId: string): Boolean;
begin
  Result := FCommits.ContainsKey(AId);
end;

function TGitCommitGraph.TryGetCommit(const AId: string;
  out ARecord: TGitCommitRecord): Boolean;
begin
  Result := FCommits.TryGetValue(AId, ARecord);
end;

function TGitCommitGraph.Count: Integer;
begin
  Result := FCommits.Count;
end;

procedure CheckDeadline(ADeadline: QWord);
begin
  if (ADeadline <> 0) and (GetTickCount64 > ADeadline) then
    raise EGitPackDeadlineExceeded.Create(
      'pack processing passed the proof deadline');
end;

function TGitCommitGraph.FindReachingStart(const AStarts: array of string;
  const ATarget: string): Integer;
begin
  Result := FindReachingStart(AStarts, ATarget, 0);
end;

function TGitCommitGraph.FindReachingStart(const AStarts: array of string;
  const ATarget: string; ADeadline: QWord): Integer;
var
  Steps: Integer;
  Visited: TDictionary<string, Boolean>;
  Stack: TList<string>;
  StartIndex, p: Integer;
  Id, Parent, Target: string;
  Commit: TGitCommitRecord;
begin
  Result := -1;
  Steps := 0;
  Visited := TDictionary<string, Boolean>.Create;
  Stack := TList<string>.Create;
  try
    { Starts share one visited set: a commit fully explored from an earlier
      start without meeting ATarget cannot lead to it from a later one. }
    for StartIndex := 0 to High(AStarts) do
    begin
      if AStarts[StartIndex] = ATarget then Exit(StartIndex);
      Stack.Clear;
      Stack.Add(AStarts[StartIndex]);
      while Stack.Count > 0 do
      begin
        Inc(Steps);
      if (Steps and $3FF) = 1 then CheckDeadline(ADeadline);
      Id := Stack[Stack.Count - 1];
        Stack.Delete(Stack.Count - 1);
        if Visited.ContainsKey(Id) then Continue;
        Visited.Add(Id, True);
        if FTags.TryGetValue(Id, Target) then
        begin
          if Target = ATarget then Exit(StartIndex);
          if not Visited.ContainsKey(Target) then Stack.Add(Target);
          Continue;
        end;
        if not FCommits.TryGetValue(Id, Commit) then Continue;
        p := 1;
        while p + GIT_OBJECT_ID_LENGTH - 1 <= Length(Commit.Parents) do
        begin
          Parent := Copy(Commit.Parents, p, GIT_OBJECT_ID_LENGTH);
          if Parent = ATarget then Exit(StartIndex);
          if not Visited.ContainsKey(Parent) then Stack.Add(Parent);
          Inc(p, GIT_OBJECT_ID_LENGTH);
        end;
      end;
    end;
  finally
    Stack.Free;
    Visited.Free;
  end;
end;

{ Commit header parsing }

function ParseCommitTime(const ALine: string): Int64;
var Close, i, Start: Integer;
begin
  { committer Name <email> 1700000000 +0000 }
  Result := 0;
  Close := LastDelimiter('>', ALine);
  if Close = 0 then Exit;
  i := Close + 1;
  while (i <= Length(ALine)) and (ALine[i] = ' ') do Inc(i);
  Start := i;
  while (i <= Length(ALine)) and (ALine[i] in ['0'..'9']) do Inc(i);
  if (i = Start) or (i - Start > 18) then Exit;
  Result := StrToInt64Def(Copy(ALine, Start, i - Start), 0);
end;

function ParseCommit(const AId: string;
  const AData: AnsiString): TGitCommitRecord;
var
  LineStart, i: Integer;
  Line, Parent: string;
  SeenTree: Boolean;
begin
  Result := Default(TGitCommitRecord);
  SeenTree := False;
  LineStart := 1;
  for i := 1 to Length(AData) do
  begin
    if AData[i] <> #10 then Continue;
    Line := Copy(AData, LineStart, i - LineStart);
    LineStart := i + 1;
    if Line = '' then Break;   { end of header; the message follows }
    if Copy(Line, 1, 5) = 'tree ' then
      SeenTree := True
    else if Copy(Line, 1, 7) = 'parent ' then
    begin
      Parent := Copy(Line, 8, MaxInt);
      if not IsLowerObjectId(Parent) then
        raise EGitPackError.CreateFmt(
          'commit %s has a malformed parent line', [AId]);
      Result.Parents := Result.Parents + Parent;
    end
    else if Copy(Line, 1, 10) = 'committer ' then
      Result.CommitTime := ParseCommitTime(Line);
  end;
  if not SeenTree then
    raise EGitPackError.CreateFmt('commit %s has no tree header', [AId]);
end;

{ The target of an annotated tag that names a commit or another tag; ''
  for tags of trees and blobs, which never lead to a commit. }
function ParseTagTarget(const AId: string; const AData: AnsiString): string;
var
  Lines: array[0..2] of string;
  Start, Stop, i: Integer;
  Kind: string;
begin
  { A tag object starts with exactly `object <id>`, `type <kind>`, and
    `tag <name>`, the headers git's own fsck requires. }
  Start := 1;
  for i := 0 to 2 do
  begin
    Stop := Start;
    while (Stop <= Length(AData)) and (AData[Stop] <> #10) do Inc(Stop);
    if Stop > Length(AData) then
      raise EGitPackError.CreateFmt('tag %s is malformed', [AId]);
    Lines[i] := Copy(AData, Start, Stop - Start);
    Start := Stop + 1;
  end;
  if (Copy(Lines[0], 1, 7) <> 'object ')
     or not IsLowerObjectId(Copy(Lines[0], 8, MaxInt)) then
    raise EGitPackError.CreateFmt('tag %s has a malformed object line',
      [AId]);
  Kind := Copy(Lines[1], 6, MaxInt);
  if (Copy(Lines[1], 1, 5) <> 'type ')
     or not ((Kind = 'commit') or (Kind = 'tree') or (Kind = 'blob')
       or (Kind = 'tag')) then
    raise EGitPackError.CreateFmt('tag %s has a malformed type line', [AId]);
  if (Copy(Lines[2], 1, 4) <> 'tag ') or (Length(Lines[2]) <= 4) then
    raise EGitPackError.CreateFmt('tag %s has a malformed tag line', [AId]);
  { Tags of trees and blobs never lead to a commit. }
  if (Kind = 'commit') or (Kind = 'tag') then
    Result := Copy(Lines[0], 8, MaxInt)
  else
    Result := '';
end;

{ Pack reader }

type
  TPackReader = class
  private
    FPack: TBytes;
    FEnd: Integer;             { first trailer byte (exclusive entry end) }
    FLimits: TGitPackLimits;
    FProduced: Int64;
    FProducedLimit: Int64;
    FEntries: array of TPackEntry;
    FEntryCount: Integer;
    FByOffset: TDictionary<Integer, Integer>;
    FRefWaiters: TDictionary<string, Integer>;
    FOffsetWaiters: array of Integer;
    FGraph: TGitCommitGraph;
    FStatistics: TGitPackStatistics;
    function ReadByte(var APos: Integer): Byte;
    procedure Account(ABytes: Int64);
    function Inflate(var APos: Integer; ASize: Int64): AnsiString;
    function ApplyDelta(const ABase, ADelta: AnsiString): AnsiString;
    procedure ReadEntry(var APos: Integer);
    procedure Complete(AIndex: Integer; AKind: Integer;
      const AData: AnsiString);
    procedure Resolve;
  public
    constructor Create(const APack: TBytes; const ALimits: TGitPackLimits);
    destructor Destroy; override;
    function Run: TGitCommitGraph;
    property Statistics: TGitPackStatistics read FStatistics;
  end;

constructor TPackReader.Create(const APack: TBytes;
  const ALimits: TGitPackLimits);
begin
  inherited Create;
  FPack := APack;
  FLimits := ALimits;
  FByOffset := TDictionary<Integer, Integer>.Create;
  FRefWaiters := TDictionary<string, Integer>.Create;
end;

destructor TPackReader.Destroy;
begin
  FGraph.Free;
  FRefWaiters.Free;
  FByOffset.Free;
  inherited Destroy;
end;

function TPackReader.ReadByte(var APos: Integer): Byte;
begin
  if APos >= FEnd then
    raise EGitPackError.Create('truncated pack entry');
  Result := FPack[APos];
  Inc(APos);
end;

procedure TPackReader.Account(ABytes: Int64);
begin
  Inc(FProduced, ABytes);
  if FProduced > FLimits.MaxInflatedBytes then
    raise EGitPackError.CreateFmt(
      'pack inflates past the %d-byte limit', [FLimits.MaxInflatedBytes]);
  if FProduced > FProducedLimit then
    raise EGitPackError.CreateFmt(
      'pack inflates more than %dx its transferred size',
      [FLimits.MaxInflateRatio]);
end;

function TPackReader.Inflate(var APos: Integer; ASize: Int64): AnsiString;
var
  Stream: TZStream;
  Status: Integer;
  Spare: Byte;
begin
  if ASize > FLimits.MaxObjectBytes then
    raise EGitPackError.CreateFmt(
      'pack object of %d bytes exceeds the %d-byte limit',
      [ASize, FLimits.MaxObjectBytes]);
  Account(ASize);
  SetLength(Result, ASize);
  FillChar(Stream, SizeOf(Stream), 0);
  if inflateInit(Stream) <> Z_OK then
    raise EGitPackError.Create('zlib initialisation failed');
  try
    Stream.next_in := @FPack[APos];
    Stream.avail_in := FEnd - APos;
    { With exactly the declared room, a stream holding more data cannot
      reach Z_STREAM_END. An empty object still gets one spare byte so that
      a non-empty stream is reported as a size mismatch. }
    if ASize > 0 then
    begin
      Stream.next_out := @Result[1];
      Stream.avail_out := ASize;
    end
    else
    begin
      Stream.next_out := @Spare;
      Stream.avail_out := 1;
    end;
    Status := paszlib.inflate(Stream, Z_FINISH);
    if Status <> Z_STREAM_END then
      raise EGitPackError.CreateFmt(
        'pack entry at offset %d is not a complete zlib stream '
        + 'of the declared size (zlib status %d)', [APos, Status]);
    if Int64(Stream.total_out) <> ASize then
      raise EGitPackError.CreateFmt(
        'pack entry at offset %d inflates to %d bytes, declared %d',
        [APos, Int64(Stream.total_out), ASize]);
    if Stream.total_in > QWord(FEnd - APos) then
      raise EGitPackError.Create('zlib stream overruns the pack');
    Inc(APos, Integer(Stream.total_in));
  finally
    inflateEnd(Stream);
  end;
end;

function TPackReader.ApplyDelta(const ABase,
  ADelta: AnsiString): AnsiString;
var
  P, OutPos: Integer;

  function DeltaByte: Byte;
  begin
    if P > Length(ADelta) then
      raise EGitPackError.Create('truncated delta instructions');
    Result := Ord(ADelta[P]);
    Inc(P);
  end;

  function DeltaSize: Int64;
  var C: Byte; Shift: Integer;
  begin
    Result := 0;
    Shift := 0;
    repeat
      if Shift > 49 then
        raise EGitPackError.Create('delta size varint overflows');
      C := DeltaByte;
      Result := Result or (Int64(C and $7F) shl Shift);
      Inc(Shift, 7);
    until (C and $80) = 0;
  end;

var
  BaseSize, ResultSize, CopyOffset, CopySize: Int64;
  Op: Byte;
  i: Integer;
begin
  P := 1;
  BaseSize := DeltaSize;
  ResultSize := DeltaSize;
  if BaseSize <> Length(ABase) then
    raise EGitPackError.CreateFmt(
      'delta expects a %d-byte base, found %d', [BaseSize, Length(ABase)]);
  if ResultSize > FLimits.MaxObjectBytes then
    raise EGitPackError.CreateFmt(
      'delta result of %d bytes exceeds the %d-byte limit',
      [ResultSize, FLimits.MaxObjectBytes]);
  Account(ResultSize);
  SetLength(Result, ResultSize);
  OutPos := 1;
  while P <= Length(ADelta) do
  begin
    Op := DeltaByte;
    if (Op and $80) <> 0 then
    begin
      CopyOffset := 0;
      CopySize := 0;
      for i := 0 to 3 do
        if (Op and (1 shl i)) <> 0 then
          CopyOffset := CopyOffset or (Int64(DeltaByte) shl (8 * i));
      for i := 0 to 2 do
        if (Op and ($10 shl i)) <> 0 then
          CopySize := CopySize or (Int64(DeltaByte) shl (8 * i));
      if CopySize = 0 then CopySize := $10000;
      if (CopyOffset + CopySize > Length(ABase))
         or (OutPos + CopySize - 1 > ResultSize) then
        raise EGitPackError.Create('delta copy is out of range');
      Move(ABase[CopyOffset + 1], Result[OutPos], CopySize);
      Inc(OutPos, CopySize);
    end
    else if Op <> 0 then
    begin
      if (P + Op - 1 > Length(ADelta))
         or (OutPos + Op - 1 > ResultSize) then
        raise EGitPackError.Create('delta insert is out of range');
      Move(ADelta[P], Result[OutPos], Op);
      Inc(P, Op);
      Inc(OutPos, Op);
    end
    else
      raise EGitPackError.Create('delta uses reserved opcode 0');
  end;
  if OutPos - 1 <> ResultSize then
    raise EGitPackError.CreateFmt(
      'delta produced %d bytes, declared %d', [OutPos - 1, ResultSize]);
end;

procedure TPackReader.ReadEntry(var APos: Integer);
var
  Entry: TPackEntry;
  C: Byte;
  Shift, Index, BaseIndex: Integer;
  Size, Relative: Int64;
  Digest: TSHA1Digest;
begin
  Entry := Default(TPackEntry);
  Entry.Offset := APos;
  Entry.BaseEntry := -1;
  Entry.NextWaiter := -1;
  C := ReadByte(APos);
  Entry.PackedKind := (C shr 4) and 7;
  Size := C and $0F;
  Shift := 4;
  while (C and $80) <> 0 do
  begin
    if Shift > 53 then
      raise EGitPackError.Create('pack entry size varint overflows');
    C := ReadByte(APos);
    Size := Size or (Int64(C and $7F) shl Shift);
    Inc(Shift, 7);
  end;

  case Entry.PackedKind of
    OBJ_COMMIT, OBJ_TAG:
      Entry.Kind := Entry.PackedKind;
    OBJ_TREE, OBJ_BLOB:
      raise EGitPackError.CreateFmt(
        'pack carries a %s object although trees and blobs were filtered '
        + 'out', [KindName(Entry.PackedKind)]);
    OBJ_OFS_DELTA:
    begin
      C := ReadByte(APos);
      Relative := C and $7F;
      while (C and $80) <> 0 do
      begin
        if Relative > (High(Int64) shr 8) then
          raise EGitPackError.Create('delta base offset overflows');
        C := ReadByte(APos);
        Relative := ((Relative + 1) shl 7) or (C and $7F);
      end;
      if (Relative <= 0) or (Relative > Entry.Offset - PACK_HEADER_BYTES) then
        raise EGitPackError.CreateFmt(
          'delta at offset %d points outside the pack', [Entry.Offset]);
      if not FByOffset.TryGetValue(Integer(Entry.Offset - Relative),
           BaseIndex) then
        raise EGitPackError.CreateFmt(
          'delta at offset %d does not point at an entry', [Entry.Offset]);
      Entry.BaseEntry := BaseIndex;
    end;
    OBJ_REF_DELTA:
    begin
      if APos + RAW_OBJECT_ID_BYTES > FEnd then
        raise EGitPackError.Create('truncated delta base id');
      Move(FPack[APos], Digest[0], RAW_OBJECT_ID_BYTES);
      Inc(APos, RAW_OBJECT_ID_BYTES);
      Entry.BaseId := DigestHex(Digest);
    end;
  else
    raise EGitPackError.CreateFmt(
      'pack entry at offset %d has invalid type %d',
      [Entry.Offset, Entry.PackedKind]);
  end;

  Entry.Data := Inflate(APos, Size);

  Index := FEntryCount;
  if Index >= Length(FEntries) then
    SetLength(FEntries, 2 * Length(FEntries) + 16);
  FEntries[Index] := Entry;
  Inc(FEntryCount);
  FByOffset.Add(Entry.Offset, Index);
  if Entry.PackedKind = OBJ_OFS_DELTA then
  begin
    FEntries[Index].NextWaiter := FOffsetWaiters[Entry.BaseEntry];
    FOffsetWaiters[Entry.BaseEntry] := Index;
  end
  else if Entry.PackedKind = OBJ_REF_DELTA then
  begin
    if FRefWaiters.TryGetValue(Entry.BaseId, BaseIndex) then
      FEntries[Index].NextWaiter := BaseIndex;
    FRefWaiters.AddOrSetValue(Entry.BaseId, Index);
  end;
end;

procedure TPackReader.Complete(AIndex: Integer; AKind: Integer;
  const AData: AnsiString);
var Target: string;
begin
  FEntries[AIndex].Kind := AKind;
  FEntries[AIndex].Data := AData;
  FEntries[AIndex].Id := GitObjectId(KindName(AKind), AData);
  if AKind = OBJ_COMMIT then
    FGraph.Add(FEntries[AIndex].Id,
      ParseCommit(FEntries[AIndex].Id, AData))
  else if AKind = OBJ_TAG then
  begin
    Target := ParseTagTarget(FEntries[AIndex].Id, AData);
    if Target <> '' then FGraph.AddTag(FEntries[AIndex].Id, Target);
  end;
end;

procedure TPackReader.Resolve;
var
  Queue: array of Integer;
  Head, Tail, Index, Waiter, Next, i, Work: Integer;

  procedure ApplyWaiters(AFirst, ABase: Integer);
  begin
    Waiter := AFirst;
    while Waiter >= 0 do
    begin
      Next := FEntries[Waiter].NextWaiter;
      if FEntries[Waiter].Kind = 0 then
      begin
        Inc(Work);
        if (Work and $3F) = 0 then CheckDeadline(FLimits.Deadline);
        Complete(Waiter, FEntries[ABase].Kind,
          ApplyDelta(FEntries[ABase].Data, FEntries[Waiter].Data));
        Inc(FStatistics.DeltaCount);
        Queue[Tail] := Waiter;
        Inc(Tail);
      end;
      Waiter := Next;
    end;
  end;

begin
  SetLength(Queue, FEntryCount);
  Head := 0;
  Tail := 0;
  Work := 0;
  for i := 0 to FEntryCount - 1 do
    if FEntries[i].Kind <> 0 then
    begin
      if (i and $3F) = 0 then CheckDeadline(FLimits.Deadline);
      Complete(i, FEntries[i].Kind, FEntries[i].Data);
      Queue[Tail] := i;
      Inc(Tail);
    end;
  { Breadth-first over resolved objects: each one releases the deltas that
    wait on it by offset or by id, in whatever order they appeared. }
  while Head < Tail do
  begin
    if (Head and $3F) = 0 then CheckDeadline(FLimits.Deadline);
    Index := Queue[Head];
    Inc(Head);
    ApplyWaiters(FOffsetWaiters[Index], Index);
    if FRefWaiters.TryGetValue(FEntries[Index].Id, Waiter) then
    begin
      FRefWaiters.Remove(FEntries[Index].Id);
      ApplyWaiters(Waiter, Index);
    end;
    { Every waiter of this object is resolved; its bytes are not needed
      again (commits already live in the graph). }
    FEntries[Index].Data := '';
  end;
  if Tail <> FEntryCount then
    raise EGitPackError.CreateFmt(
      '%d delta(s) reference a base that is not in the pack',
      [FEntryCount - Tail]);
end;

function TPackReader.Run: TGitCommitGraph;
var
  Version, Count: Cardinal;
  Pos, i: Integer;
  Expected, Actual: TSHA1Digest;

  function BE32(AAt: Integer): Cardinal;
  begin
    Result := (Cardinal(FPack[AAt]) shl 24) or (Cardinal(FPack[AAt + 1]) shl 16)
      or (Cardinal(FPack[AAt + 2]) shl 8) or Cardinal(FPack[AAt + 3]);
  end;

begin
  if Length(FPack) < PACK_HEADER_BYTES + PACK_TRAILER_BYTES then
    raise EGitPackError.Create('pack is shorter than its header and trailer');
  if (FPack[0] <> Ord('P')) or (FPack[1] <> Ord('A'))
     or (FPack[2] <> Ord('C')) or (FPack[3] <> Ord('K')) then
    raise EGitPackError.Create('pack does not start with the PACK signature');
  FEnd := Length(FPack) - PACK_TRAILER_BYTES;
  Actual := SHA1Buffer(FPack[0], FEnd);
  Move(FPack[FEnd], Expected[0], PACK_TRAILER_BYTES);
  if not SHA1Match(Actual, Expected) then
    raise EGitPackError.Create('pack checksum does not match its contents');
  Version := BE32(4);
  if (Version <> 2) and (Version <> 3) then
    raise EGitPackError.CreateFmt('unsupported pack version %d', [Version]);
  Count := BE32(8);
  if Count > Cardinal(FLimits.MaxObjectCount) then
    raise EGitPackError.CreateFmt(
      'pack declares %d objects, more than the %d-object limit',
      [Count, FLimits.MaxObjectCount]);
  FProducedLimit := Int64(FLimits.MaxInflateRatio) * Length(FPack)
    + PACK_INFLATE_ALLOWANCE;

  FGraph := TGitCommitGraph.Create;
  Pos := PACK_HEADER_BYTES;
  for i := 1 to Integer(Count) do
  begin
    if (i and $3F) = 1 then CheckDeadline(FLimits.Deadline);
    if Length(FOffsetWaiters) <= FEntryCount then
    begin
      SetLength(FOffsetWaiters, 2 * Length(FOffsetWaiters) + 16);
    end;
    FOffsetWaiters[FEntryCount] := -1;
    ReadEntry(Pos);
  end;
  if Pos <> FEnd then
    raise EGitPackError.CreateFmt(
      'pack has %d unexpected bytes after its last entry', [FEnd - Pos]);
  Resolve;

  FStatistics.ObjectCount := FEntryCount;
  FStatistics.CommitCount := FGraph.Count;
  FStatistics.InflatedBytes := FProduced;
  Result := FGraph;
  FGraph := nil;
end;

function ReadCommitPack(const APack: TBytes;
  const ALimits: TGitPackLimits): TGitCommitGraph;
var Statistics: TGitPackStatistics;
begin
  Result := ReadCommitPack(APack, ALimits, Statistics);
end;

function ReadCommitPack(const APack: TBytes; const ALimits: TGitPackLimits;
  out AStatistics: TGitPackStatistics): TGitCommitGraph;
var Reader: TPackReader;
begin
  if Length(APack) > High(Integer) - 1 then
    raise EGitPackError.Create('pack is too large to index');
  Reader := TPackReader.Create(APack, ALimits);
  try
    Result := Reader.Run;
    AStatistics := Reader.Statistics;
  finally
    Reader.Free;
  end;
end;

end.
