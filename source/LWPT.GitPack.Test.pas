program LWPT.GitPack.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  LWPT.GitPack,
  paszlib,
  sha1,
  TestingPascalLibrary;

const
  FIXTURE_DIR = 'tests/fixtures/git-reachability/';
  TREE_ID = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

type
  TGitPackTests = class(TTestSuite)
  private
    function FixtureCommit(const AName: string): string;
    procedure ExpectRealPack(const AFile: string);
  public
    procedure SetupTests; override;
    procedure TestReadsOfsDeltaPackFromGit;
    procedure TestReadsRefDeltaPackFromGit;
    procedure TestResolvesRefDeltaBeforeItsBase;
    procedure TestRejectsChecksumMismatch;
    procedure TestRejectsTruncatedPack;
    procedure TestRejectsTrailingBytes;
    procedure TestRejectsDeltaCopyOutOfRange;
    procedure TestRejectsDeltaInsertPastResult;
    procedure TestRejectsMissingDeltaBase;
    procedure TestRejectsRefDeltaCycle;
    procedure TestRejectsOfsDeltaIntoEntryMiddle;
    procedure TestRejectsObjectCountOverLimit;
    procedure TestRejectsObjectOverSizeLimit;
    procedure TestRejectsInflateRatioOverLimit;
    procedure TestRejectsDeclaredSizeMismatch;
    procedure TestRejectsTreeObjects;
    procedure TestRejectsMalformedParent;
    procedure TestWalkFindsReachingStart;
    procedure TestWalkStopsAtMissingCommits;
    procedure TestWalkFollowsVerifiedTagObjects;
    procedure TestRejectsIncompleteTagHeaders;
    procedure TestParsingAndWalkingHonourTheDeadline;
  end;

{ Pack construction helpers. Entries are assembled by hand so each hostile
  shape can be expressed exactly; the trailer is always recomputed unless a
  test corrupts it on purpose. }

function Bytes(const S: AnsiString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function ReadFileBytes(const APath: string): TBytes;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function Deflate(const AData: AnsiString): AnsiString;
var DestLen: Cardinal;
begin
  DestLen := Length(AData) + Length(AData) div 100 + 64;
  SetLength(Result, DestLen);
  if compress(PChar(Result), DestLen, PChar(AData), Length(AData)) <> Z_OK then
    raise Exception.Create('test deflate failed');
  SetLength(Result, DestLen);
end;

function EntryHeader(AKind: Integer; ASize: Int64): AnsiString;
var C: Byte;
begin
  C := Byte((AKind shl 4) or (ASize and $0F));
  ASize := ASize shr 4;
  Result := '';
  while ASize > 0 do
  begin
    Result := Result + AnsiChar(C or $80);
    C := Byte(ASize and $7F);
    ASize := ASize shr 7;
  end;
  Result := Result + AnsiChar(C);
end;

function DeltaVarint(AValue: Int64): AnsiString;
begin
  Result := '';
  repeat
    if AValue >= $80 then
      Result := Result + AnsiChar((AValue and $7F) or $80)
    else
      Result := Result + AnsiChar(AValue);
    AValue := AValue shr 7;
  until AValue = 0;
end;

function OfsEncode(ARelative: Int64): AnsiString;
var Value: Int64;
begin
  Value := ARelative;
  Result := AnsiChar(Value and $7F);
  Value := Value shr 7;
  while Value > 0 do
  begin
    Dec(Value);
    Result := AnsiChar($80 or (Value and $7F)) + Result;
    Value := Value shr 7;
  end;
end;

function WholeEntry(AKind: Integer; const AData: AnsiString): AnsiString;
begin
  Result := EntryHeader(AKind, Length(AData)) + Deflate(AData);
end;

function RawId(const AHex: string): AnsiString;
var i: Integer;
begin
  SetLength(Result, 20);
  for i := 0 to 19 do
    Result[i + 1] := AnsiChar(StrToInt('$' + Copy(AHex, 2 * i + 1, 2)));
end;

function RefDeltaEntry(const ABaseId: string;
  const ADelta: AnsiString): AnsiString;
begin
  Result := EntryHeader(7, Length(ADelta)) + RawId(ABaseId) + Deflate(ADelta);
end;

function OfsDeltaEntry(ARelative: Int64; const ADelta: AnsiString): AnsiString;
begin
  Result := EntryHeader(6, Length(ADelta)) + OfsEncode(ARelative)
    + Deflate(ADelta);
end;

{ A delta that rebuilds ATarget from ABase: copy ABase's first ACopy bytes,
  then insert the rest of ATarget literally. }
function MakeDelta(const ABase, ATarget: AnsiString; ACopy: Integer): AnsiString;
var Rest: AnsiString; Chunk: Integer;
begin
  Result := DeltaVarint(Length(ABase)) + DeltaVarint(Length(ATarget));
  if ACopy > 0 then
    Result := Result + AnsiChar($80 or $01 or $10) + AnsiChar(0)
      + AnsiChar(ACopy);
  Rest := Copy(ATarget, ACopy + 1, MaxInt);
  while Rest <> '' do
  begin
    Chunk := Length(Rest);
    if Chunk > 127 then Chunk := 127;
    Result := Result + AnsiChar(Chunk) + Copy(Rest, 1, Chunk);
    Delete(Rest, 1, Chunk);
  end;
end;

function AssemblePack(const AEntries: array of AnsiString): TBytes;
var
  Body: AnsiString;
  i, Count: Integer;
  Digest: TSHA1Digest;
begin
  Count := Length(AEntries);
  Body := 'PACK' + #0#0#0#2 + AnsiChar((Count shr 24) and $FF)
    + AnsiChar((Count shr 16) and $FF) + AnsiChar((Count shr 8) and $FF)
    + AnsiChar(Count and $FF);
  for i := 0 to High(AEntries) do Body := Body + AEntries[i];
  Digest := SHA1Buffer(Body[1], Length(Body));
  SetLength(Body, Length(Body) + 20);
  Move(Digest[0], Body[Length(Body) - 19], 20);
  Result := Bytes(Body);
end;

procedure Reseal(var APack: TBytes);
var Digest: TSHA1Digest;
begin
  Digest := SHA1Buffer(APack[0], Length(APack) - 20);
  Move(Digest[0], APack[Length(APack) - 20], 20);
end;

function CommitText(const AParents: array of string; ATime: Int64;
  const AMessage: string): AnsiString;
var i: Integer;
begin
  Result := 'tree ' + TREE_ID + #10;
  for i := 0 to High(AParents) do
    Result := Result + 'parent ' + AParents[i] + #10;
  Result := Result + 'author A <a@example.invalid> ' + IntToStr(ATime)
    + ' +0000'#10 + 'committer A <a@example.invalid> ' + IntToStr(ATime)
    + ' +0000'#10#10 + AMessage + #10;
end;

function ReadFails(const APack: TBytes; const ALimits: TGitPackLimits;
  const AExpected: string): Boolean;
var Message: string;
begin
  Message := '';
  try
    ReadCommitPack(APack, ALimits).Free;
  except
    on E: EGitPackError do
      Message := E.Message;
  end;
  Result := (Message <> '') and (Pos(AExpected, Message) > 0);
  if not Result then
    WriteLn('    expected error containing "', AExpected, '", got "',
      Message, '"');
end;

{ TGitPackTests }

function TGitPackTests.FixtureCommit(const AName: string): string;
var Lines: TStringList; i: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FIXTURE_DIR + 'commits.txt');
    for i := 0 to Lines.Count - 1 do
      if Copy(Lines[i], 1, Length(AName) + 1) = AName + ' ' then
        Exit(Copy(Lines[i], Length(AName) + 2, 40));
  finally
    Lines.Free;
  end;
  raise Exception.Create('fixture commit not found: ' + AName);
end;

procedure TGitPackTests.ExpectRealPack(const AFile: string);
var
  Graph: TGitCommitGraph;
  Stats: TGitPackStatistics;
  Commit: TGitCommitRecord;
begin
  Graph := ReadCommitPack(ReadFileBytes(FIXTURE_DIR + AFile),
    DefaultGitPackLimits, Stats);
  try
    Expect<Integer>(Graph.Count).ToBe(9);
    Expect<Integer>(Stats.ObjectCount).ToBe(9);
    Expect<Boolean>(Stats.DeltaCount > 0).ToBe(True);
    Expect<Boolean>(Graph.TryGetCommit(FixtureCommit('c1'), Commit))
      .ToBe(True);
    Expect<string>(Commit.Parents).ToBe('');
    Expect<Int64>(Commit.CommitTime).ToBe(1704110400);  { 2024-01-01 12:00Z }
    Expect<Boolean>(Graph.TryGetCommit(FixtureCommit('f1'), Commit))
      .ToBe(True);
    Expect<string>(Commit.Parents).ToBe(FixtureCommit('c3'));
    Expect<Boolean>(Graph.TryGetCommit(FixtureCommit('c4'), Commit))
      .ToBe(True);
    Expect<string>(Commit.Parents).ToBe(FixtureCommit('c3'));
    Expect<Integer>(Graph.FindReachingStart([FixtureCommit('c6')],
      FixtureCommit('c1'))).ToBe(0);
    Expect<Integer>(Graph.FindReachingStart([FixtureCommit('c6'),
      FixtureCommit('r2')], FixtureCommit('f1'))).ToBe(-1);
  finally
    Graph.Free;
  end;
end;

procedure TGitPackTests.TestReadsOfsDeltaPackFromGit;
begin
  ExpectRealPack('commits-ofs.pack');
end;

procedure TGitPackTests.TestReadsRefDeltaPackFromGit;
begin
  ExpectRealPack('commits-ref.pack');
end;

procedure TGitPackTests.TestResolvesRefDeltaBeforeItsBase;
var
  Base, Target, Chained: AnsiString;
  BaseId, TargetId: string;
  Graph: TGitCommitGraph;
  Commit: TGitCommitRecord;
  Stats: TGitPackStatistics;
begin
  Base := CommitText([], 1000, 'base commit with a shared message body');
  BaseId := GitObjectId('commit', Base);
  Target := CommitText([BaseId], 2000, 'second commit');
  TargetId := GitObjectId('commit', Target);
  Chained := CommitText([TargetId], 3000, 'third commit');
  { Both deltas precede the base they depend on, and the second delta's
    base is itself a delta. }
  Graph := ReadCommitPack(AssemblePack([
    RefDeltaEntry(TargetId, MakeDelta(Target, Chained, 46)),
    RefDeltaEntry(BaseId, MakeDelta(Base, Target, 46)),
    WholeEntry(1, Base)]), DefaultGitPackLimits, Stats);
  try
    Expect<Integer>(Graph.Count).ToBe(3);
    Expect<Integer>(Stats.DeltaCount).ToBe(2);
    Expect<Boolean>(Graph.TryGetCommit(GitObjectId('commit', Chained),
      Commit)).ToBe(True);
    Expect<string>(Commit.Parents).ToBe(TargetId);
    Expect<Int64>(Commit.CommitTime).ToBe(3000);
  finally
    Graph.Free;
  end;
end;

procedure TGitPackTests.TestRejectsChecksumMismatch;
var Pack: TBytes;
begin
  Pack := AssemblePack([WholeEntry(1, CommitText([], 1, 'a'))]);
  Pack[Length(Pack) - 1] := Pack[Length(Pack) - 1] xor $FF;
  Expect<Boolean>(ReadFails(Pack, DefaultGitPackLimits, 'checksum'))
    .ToBe(True);
end;

procedure TGitPackTests.TestRejectsTruncatedPack;
var Pack: TBytes; Entry: AnsiString;
begin
  Entry := WholeEntry(1, CommitText([], 1, 'a'));
  Pack := AssemblePack([Copy(Entry, 1, Length(Entry) - 6)]);
  Expect<Boolean>(ReadFails(Pack, DefaultGitPackLimits,
    'not a complete zlib stream')).ToBe(True);
  { A header that promises a second entry the bytes never deliver. }
  Pack := AssemblePack([Entry]);
  Pack[11] := 2;
  Reseal(Pack);
  Expect<Boolean>(ReadFails(Pack, DefaultGitPackLimits, 'truncated'))
    .ToBe(True);
end;

procedure TGitPackTests.TestRejectsTrailingBytes;
begin
  Expect<Boolean>(ReadFails(AssemblePack([
    WholeEntry(1, CommitText([], 1, 'a')) + 'junk']),
    DefaultGitPackLimits, 'unexpected bytes')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsDeltaCopyOutOfRange;
var Base, Delta: AnsiString;
begin
  Base := CommitText([], 1, 'base');
  { Copy 200 bytes from offset 0 of a base that is shorter than that. }
  Delta := DeltaVarint(Length(Base)) + DeltaVarint(200)
    + AnsiChar($80 or $01 or $10) + AnsiChar(0) + AnsiChar(200);
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(1, Base),
    RefDeltaEntry(GitObjectId('commit', Base), Delta)]),
    DefaultGitPackLimits, 'delta copy is out of range')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsDeltaInsertPastResult;
var Base, Delta: AnsiString;
begin
  Base := CommitText([], 1, 'base');
  Delta := DeltaVarint(Length(Base)) + DeltaVarint(2) + AnsiChar(5) + 'hello';
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(1, Base),
    RefDeltaEntry(GitObjectId('commit', Base), Delta)]),
    DefaultGitPackLimits, 'delta insert is out of range')).ToBe(True);
  { Opcode 0 is reserved. }
  Delta := DeltaVarint(Length(Base)) + DeltaVarint(1) + AnsiChar(0);
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(1, Base),
    RefDeltaEntry(GitObjectId('commit', Base), Delta)]),
    DefaultGitPackLimits, 'reserved opcode')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsMissingDeltaBase;
var Base: AnsiString;
begin
  Base := CommitText([], 1, 'base');
  { A thin pack: the base is not included. }
  Expect<Boolean>(ReadFails(AssemblePack([
    RefDeltaEntry(GitObjectId('commit', Base),
      MakeDelta(Base, CommitText([], 2, 'next'), 46))]),
    DefaultGitPackLimits, 'not in the pack')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsRefDeltaCycle;
var A, B: AnsiString; IdA, IdB: string;
begin
  A := CommitText([], 1, 'first');
  B := CommitText([], 2, 'second');
  IdA := GitObjectId('commit', A);
  IdB := GitObjectId('commit', B);
  Expect<Boolean>(ReadFails(AssemblePack([
    RefDeltaEntry(IdB, MakeDelta(B, A, 46)),
    RefDeltaEntry(IdA, MakeDelta(A, B, 46))]),
    DefaultGitPackLimits, 'not in the pack')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsOfsDeltaIntoEntryMiddle;
var First, Base: AnsiString;
begin
  Base := CommitText([], 1, 'base');
  First := WholeEntry(1, Base);
  { Relative offset one byte short of the entry start. }
  Expect<Boolean>(ReadFails(AssemblePack([First,
    OfsDeltaEntry(Length(First) - 1,
      MakeDelta(Base, CommitText([], 2, 'x'), 46))]),
    DefaultGitPackLimits, 'does not point at an entry')).ToBe(True);
  Expect<Boolean>(ReadFails(AssemblePack([First,
    OfsDeltaEntry(Length(First) + 100,
      MakeDelta(Base, CommitText([], 2, 'x'), 46))]),
    DefaultGitPackLimits, 'points outside the pack')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsObjectCountOverLimit;
var Limits: TGitPackLimits;
begin
  Limits := DefaultGitPackLimits;
  Limits.MaxObjectCount := 1;
  Expect<Boolean>(ReadFails(AssemblePack([
    WholeEntry(1, CommitText([], 1, 'a')),
    WholeEntry(1, CommitText([], 2, 'b'))]), Limits,
    'more than the 1-object limit')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsObjectOverSizeLimit;
var Limits: TGitPackLimits; Base: AnsiString;
begin
  Limits := DefaultGitPackLimits;
  Limits.MaxObjectBytes := 64;
  Base := CommitText([], 1, StringOfChar('m', 100));
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(1, Base)]), Limits,
    'exceeds the 64-byte limit')).ToBe(True);
  { A small delta whose declared result is over the limit. }
  Limits.MaxObjectBytes := 200;
  Base := CommitText([], 1, 'b');
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(1, Base),
    RefDeltaEntry(GitObjectId('commit', Base),
      DeltaVarint(Length(Base)) + DeltaVarint(5000))]), Limits,
    'delta result of 5000 bytes')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsInflateRatioOverLimit;
var Limits: TGitPackLimits;
begin
  Limits := DefaultGitPackLimits;
  Limits.MaxInflatedBytes := 4096;
  Expect<Boolean>(ReadFails(AssemblePack([
    WholeEntry(1, CommitText([], 1, StringOfChar('z', 8000)))]), Limits,
    'inflates past the 4096-byte limit')).ToBe(True);
  { 3 MiB of one repeated byte compresses to a few KiB: far past 32x plus
    the 1 MiB allowance. }
  Expect<Boolean>(ReadFails(AssemblePack([
    WholeEntry(1, CommitText([], 1, StringOfChar('z', 3 * 1024 * 1024)))]),
    DefaultGitPackLimits, 'more than 32x')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsDeclaredSizeMismatch;
var Data: AnsiString;
begin
  Data := CommitText([], 1, 'a');
  { Header declares fewer bytes than the zlib stream holds. }
  Expect<Boolean>(ReadFails(AssemblePack([
    EntryHeader(1, Length(Data) - 1) + Deflate(Data)]),
    DefaultGitPackLimits, 'declared')).ToBe(True);
  { And more. }
  Expect<Boolean>(ReadFails(AssemblePack([
    EntryHeader(1, Length(Data) + 1) + Deflate(Data)]),
    DefaultGitPackLimits, 'declared')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsTreeObjects;
begin
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(2, '')]),
    DefaultGitPackLimits, 'tree object')).ToBe(True);
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(3, 'data')]),
    DefaultGitPackLimits, 'blob object')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsMalformedParent;
begin
  Expect<Boolean>(ReadFails(AssemblePack([
    WholeEntry(1, CommitText(['ABCDEF'], 1, 'a'))]),
    DefaultGitPackLimits, 'malformed parent')).ToBe(True);
  Expect<Boolean>(ReadFails(AssemblePack([
    WholeEntry(1, 'author x'#10#10'no tree'#10)]),
    DefaultGitPackLimits, 'no tree header')).ToBe(True);
end;

procedure TGitPackTests.TestWalkFindsReachingStart;
var
  Graph: TGitCommitGraph;
  Root, Middle, Side: TGitCommitRecord;
  Target: string;
begin
  Target := StringOfChar('0', 40);
  Graph := TGitCommitGraph.Create;
  try
    Root := Default(TGitCommitRecord);
    Root.Parents := Target;
    Graph.Add(StringOfChar('1', 40), Root);
    Middle := Default(TGitCommitRecord);
    Middle.Parents := StringOfChar('9', 40) + StringOfChar('1', 40);
    Graph.Add(StringOfChar('2', 40), Middle);
    Side := Default(TGitCommitRecord);
    Graph.Add(StringOfChar('3', 40), Side);
    Expect<Integer>(Graph.FindReachingStart([StringOfChar('3', 40),
      StringOfChar('2', 40)], Target)).ToBe(1);
    Expect<Integer>(Graph.FindReachingStart([StringOfChar('3', 40)],
      Target)).ToBe(-1);
    Expect<Integer>(Graph.FindReachingStart([Target], Target)).ToBe(0);
  finally
    Graph.Free;
  end;
end;

procedure TGitPackTests.TestWalkStopsAtMissingCommits;
var Graph: TGitCommitGraph; Tip: TGitCommitRecord;
begin
  { The tip's parent is absent from the graph, so the path to the target
    cannot be proven even if it exists upstream. }
  Graph := TGitCommitGraph.Create;
  try
    Tip := Default(TGitCommitRecord);
    Tip.Parents := StringOfChar('5', 40);
    Graph.Add(StringOfChar('6', 40), Tip);
    Expect<Integer>(Graph.FindReachingStart([StringOfChar('6', 40)],
      StringOfChar('4', 40))).ToBe(-1);
  finally
    Graph.Free;
  end;
end;

procedure TGitPackTests.TestWalkFollowsVerifiedTagObjects;
var
  Commit, Tag, Nested: AnsiString;
  CommitId, TagId, NestedId: string;
  Graph: TGitCommitGraph;
begin
  Commit := CommitText([], 1000, 'tagged');
  CommitId := GitObjectId('commit', Commit);
  Tag := 'object ' + CommitId + #10 + 'type commit'#10 + 'tag v1'#10
    + 'tagger A <a@example.invalid> 1000 +0000'#10#10 + 'v1'#10;
  TagId := GitObjectId('tag', Tag);
  Nested := 'object ' + TagId + #10 + 'type tag'#10 + 'tag v1-signed'#10
    + 'tagger A <a@example.invalid> 1000 +0000'#10#10 + 'nested'#10;
  NestedId := GitObjectId('tag', Nested);
  Graph := ReadCommitPack(AssemblePack([WholeEntry(4, Nested),
    WholeEntry(4, Tag), WholeEntry(1, Commit)]), DefaultGitPackLimits);
  try
    { The tag object's id is recomputed from its bytes, so its target is
      verified; the walk peels through it (and through a tag of a tag). }
    Expect<Integer>(Graph.FindReachingStart([TagId], CommitId)).ToBe(0);
    Expect<Integer>(Graph.FindReachingStart([NestedId], CommitId)).ToBe(0);
    Expect<string>(Graph.PeelToCommit(NestedId)).ToBe(CommitId);
    Expect<string>(Graph.PeelToCommit(StringOfChar('7', 40))).ToBe('');
  finally
    Graph.Free;
  end;
  { A tag whose object line is not an id is malformed. }
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(4,
    'object nope'#10'type commit'#10'tag x'#10#10)]),
    DefaultGitPackLimits, 'malformed object line')).ToBe(True);
end;

procedure TGitPackTests.TestRejectsIncompleteTagHeaders;
var Target: string;
begin
  { git hash-object -t tag rejects each of these; so does the reader,
    instead of skipping them or adding an edge. }
  Target := GitObjectId('commit', CommitText([], 1, 'x'));
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(4,
    'object ' + Target + #10 + 'tag v1'#10#10)]),
    DefaultGitPackLimits, 'malformed')).ToBe(True);
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(4,
    'object ' + Target + #10 + 'type bogus'#10 + 'tag v1'#10#10)]),
    DefaultGitPackLimits, 'malformed')).ToBe(True);
  Expect<Boolean>(ReadFails(AssemblePack([WholeEntry(4,
    'object ' + Target + #10 + 'type commit'#10
    + 'tagger A <a@example.invalid> 1 +0000'#10#10)]),
    DefaultGitPackLimits, 'malformed')).ToBe(True);
end;

procedure TGitPackTests.TestParsingAndWalkingHonourTheDeadline;
var
  Limits: TGitPackLimits;
  Graph: TGitCommitGraph;
  Raised: Boolean;
begin
  { A deadline already in the past stops parsing, even for a valid pack
    that arrived in time. }
  Limits := DefaultGitPackLimits;
  Limits.Deadline := 1;
  Raised := False;
  try
    ReadCommitPack(ReadFileBytes(FIXTURE_DIR + 'commits-ofs.pack'),
      Limits).Free;
  except
    on E: EGitPackDeadlineExceeded do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  { And the walk. }
  Graph := ReadCommitPack(ReadFileBytes(FIXTURE_DIR + 'commits-ofs.pack'),
    DefaultGitPackLimits);
  try
    Raised := False;
    try
      Graph.FindReachingStart([FixtureCommit('c6')], FixtureCommit('c1'), 1);
    except
      on E: EGitPackDeadlineExceeded do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Graph.FindReachingStart([FixtureCommit('c6')],
      FixtureCommit('c1'), GetTickCount64 + 60000)).ToBe(0);
  finally
    Graph.Free;
  end;
end;

procedure TGitPackTests.SetupTests;
begin
  Test('reads an OFS_DELTA commit pack written by git',
    TestReadsOfsDeltaPackFromGit);
  Test('reads a REF_DELTA commit pack written by git',
    TestReadsRefDeltaPackFromGit);
  Test('resolves REF_DELTA entries that precede their base',
    TestResolvesRefDeltaBeforeItsBase);
  Test('rejects a pack whose trailer checksum does not match',
    TestRejectsChecksumMismatch);
  Test('rejects truncated entries and missing entries',
    TestRejectsTruncatedPack);
  Test('rejects bytes after the last entry', TestRejectsTrailingBytes);
  Test('rejects a delta copy outside its base',
    TestRejectsDeltaCopyOutOfRange);
  Test('rejects delta inserts past the result and reserved opcodes',
    TestRejectsDeltaInsertPastResult);
  Test('rejects a delta whose base is not in the pack',
    TestRejectsMissingDeltaBase);
  Test('rejects REF_DELTA entries that depend on each other',
    TestRejectsRefDeltaCycle);
  Test('rejects OFS_DELTA offsets that do not name an entry',
    TestRejectsOfsDeltaIntoEntryMiddle);
  Test('rejects a declared object count over the limit',
    TestRejectsObjectCountOverLimit);
  Test('rejects objects and delta results over the size limit',
    TestRejectsObjectOverSizeLimit);
  Test('rejects packs that inflate past the byte or ratio limit',
    TestRejectsInflateRatioOverLimit);
  Test('rejects entries whose zlib size differs from the header',
    TestRejectsDeclaredSizeMismatch);
  Test('rejects trees and blobs in a commits-only pack',
    TestRejectsTreeObjects);
  Test('rejects commits with malformed headers',
    TestRejectsMalformedParent);
  Test('walk reports which start reaches the target',
    TestWalkFindsReachingStart);
  Test('walk peels through hash-verified tag objects',
    TestWalkFollowsVerifiedTagObjects);
  Test('rejects tag objects with missing or unknown headers',
    TestRejectsIncompleteTagHeaders);
  Test('parsing and walking stop at the deadline',
    TestParsingAndWalkingHonourTheDeadline);
  Test('walk never crosses commits missing from the pack',
    TestWalkStopsAtMissingCommits);
end;

begin
  TestRunnerProgram.AddSuite(TGitPackTests.Create('git pack reader'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
