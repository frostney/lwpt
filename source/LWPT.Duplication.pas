{ LWPT.Duplication — deterministic Type-2 Pascal clone analysis. }
unit LWPT.Duplication;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.Analysis.Scope,
  LWPT.Core,
  LWPT.Manifest;

const
  DUPLICATION_DEFAULT_MINIMUM_TOKENS =
    MANIFEST_DUPLICATION_DEFAULT_MINIMUM_TOKENS;
  DUPLICATION_MINIMUM_TOKEN_FLOOR =
    MANIFEST_DUPLICATION_MINIMUM_TOKEN_FLOOR;
  DUPLICATION_REPORT_SCHEMA_VERSION = 1;

type
  TLWPTDuplicationConfiguration = record
    ProjectName: string;
    MinimumTokens: Integer;
    MaximumPercentConfigured: Boolean;
    MaximumPercent: Integer;
  end;
  TLWPTDuplicationConfigurationArray =
    array of TLWPTDuplicationConfiguration;

  TLWPTCloneOccurrence = record
    DocumentIndex: Integer; { internal owner; intentionally not serialized }
    FileName: string;
    RegionKind: string;
    StartLine: Integer;
    StartColumn: Integer;
    EndLine: Integer;
    EndColumn: Integer;
  end;
  TLWPTCloneOccurrenceArray = array of TLWPTCloneOccurrence;

  TLWPTCloneGroup = record
    TokenCount: Integer;
    Occurrences: TLWPTCloneOccurrenceArray;
  end;
  TLWPTCloneGroupArray = array of TLWPTCloneGroup;

  TLWPTDuplicationProjectSummary = record
    ProjectName: string;
    TotalTokens: Int64;
    DuplicateTokens: Int64;
  end;
  TLWPTDuplicationProjectSummaryArray =
    array of TLWPTDuplicationProjectSummary;

  TLWPTDuplicationReport = record
    Configurations: TLWPTDuplicationConfigurationArray;
    Groups: TLWPTCloneGroupArray;
    Projects: TLWPTDuplicationProjectSummaryArray;
    TotalTokens: Int64;
    DuplicateTokens: Int64;
    ThresholdConfigured: Boolean;
    ThresholdFailed: Boolean;
    Diagnostics: TStringArray;
  end;

function AnalyzeDuplication(const AScope: TLWPTAnalysisScope):
  TLWPTDuplicationReport;
function DuplicationReportHuman(const AReport: TLWPTDuplicationReport):
  string;
function DuplicationReportJSON(const AReport: TLWPTDuplicationReport):
  string;

implementation

uses
  Classes,
  SysUtils,

  LWPT.Analysis.JSON,
  LWPT.Analysis.Pascal;

type
  TIntegerArray = array of Integer;
  TQWordArray = array of QWord;

  TAnalyzedDocument = record
    ProjectIndex: Integer;
    RootRelativePath: string;
    Document: TLWPTPascalDocument;
    TokenIDs: TIntegerArray;
    PreviousToken: TIntegerArray;
    NextToken: TIntegerArray;
  end;
  TAnalyzedDocumentArray = array of TAnalyzedDocument;

  TSeed = record
    Hash: QWord;
    DocumentIndex: Integer;
    RegionIndex: Integer;
    StartToken: Integer;
  end;
  TSeedArray = array of TSeed;

  TCandidate = record
    Hash: QWord;
    LeftDocument: Integer;
    LeftRegion: Integer;
    LeftStart: Integer;
    RightDocument: Integer;
    RightRegion: Integer;
    RightStart: Integer;
    TokenCount: Integer;
  end;
  TCandidateArray = array of TCandidate;

  TInternalOccurrence = record
    DocumentIndex: Integer;
    RegionIndex: Integer;
    StartToken: Integer;
  end;
  TInternalOccurrenceArray = array of TInternalOccurrence;
  TBooleanArray = array of Boolean;
  TDocumentOccupancy = array of TBooleanArray;
  TParameterizedMatcher = record
    Generation: Integer;
    LeftMap: TIntegerArray;
    RightMap: TIntegerArray;
    LeftStamp: TIntegerArray;
    RightStamp: TIntegerArray;
  end;

function ReadSourceText(const APath: string): string;
var
  Stream: TFileStream;
begin
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Result, Stream.Size);
      if Stream.Size > 0 then Stream.ReadBuffer(Result[1], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      raise ELWPTError.CreateFmt('failed to read analysis source "%s": %s',
        [APath, E.Message]);
  end;
end;

function FindProjectIndex(const AScope: TLWPTAnalysisScope;
  const AProjectName: string): Integer;
begin
  for Result := 0 to High(AScope.Projects) do
    if AScope.Projects[Result].Name = AProjectName then Exit;
  raise ELWPTError.CreateFmt('analysis file has unknown project owner "%s"',
    [AProjectName]);
end;

function LoadConfigurations(const AScope: TLWPTAnalysisScope):
  TLWPTDuplicationConfigurationArray;
var
  Manifest: TManifest;
  ProjectIndex: Integer;
  RootConfiguration: TLWPTDuplicationConfiguration;
begin
  Result := Default(TLWPTDuplicationConfigurationArray);
  SetLength(Result, Length(AScope.Projects));
  RootConfiguration := Default(TLWPTDuplicationConfiguration);
  for ProjectIndex := 0 to High(AScope.Projects) do
  begin
    Manifest := LoadManifest(AScope.Projects[ProjectIndex].ManifestPath,
      ProjectIndex = 0);
    if (ProjectIndex > 0) and not Manifest.DuplicationConfigured then
      Result[ProjectIndex] := RootConfiguration
    else
    begin
      Result[ProjectIndex].MinimumTokens :=
        Manifest.DuplicationMinimumTokens;
      Result[ProjectIndex].MaximumPercentConfigured :=
        Manifest.DuplicationMaximumPercentConfigured;
      Result[ProjectIndex].MaximumPercent :=
        Manifest.DuplicationMaximumPercent;
    end;
    Result[ProjectIndex].ProjectName := AScope.Projects[ProjectIndex].Name;
    if ProjectIndex = 0 then RootConfiguration := Result[ProjectIndex];
  end;
end;

function CompareOccurrence(const ALeftDocument, ALeftRegion, ALeftStart,
  ARightDocument, ARightRegion, ARightStart: Integer): Integer;
begin
  if ALeftDocument < ARightDocument then Exit(-1);
  if ALeftDocument > ARightDocument then Exit(1);
  if ALeftRegion < ARightRegion then Exit(-1);
  if ALeftRegion > ARightRegion then Exit(1);
  if ALeftStart < ARightStart then Exit(-1);
  if ALeftStart > ARightStart then Exit(1);
  Result := 0;
end;

function CompareSeed(const ALeft, ARight: TSeed): Integer;
begin
  if ALeft.Hash < ARight.Hash then Exit(-1);
  if ALeft.Hash > ARight.Hash then Exit(1);
  Result := CompareOccurrence(ALeft.DocumentIndex, ALeft.RegionIndex,
    ALeft.StartToken, ARight.DocumentIndex, ARight.RegionIndex,
    ARight.StartToken);
end;

procedure SortSeeds(var ASeeds: TSeedArray);
var
  Temporary: TSeedArray;

  procedure MergeSort(const ALow, AHigh: Integer);
  var
    LeftIndex, MiddleIndex, OutputIndex, RightIndex: Integer;
  begin
    if ALow >= AHigh then Exit;
    MiddleIndex := ALow + ((AHigh - ALow) div 2);
    MergeSort(ALow, MiddleIndex);
    MergeSort(MiddleIndex + 1, AHigh);
    LeftIndex := ALow;
    RightIndex := MiddleIndex + 1;
    OutputIndex := ALow;
    while (LeftIndex <= MiddleIndex) and (RightIndex <= AHigh) do
    begin
      if CompareSeed(ASeeds[LeftIndex], ASeeds[RightIndex]) <= 0 then
      begin
        Temporary[OutputIndex] := ASeeds[LeftIndex];
        Inc(LeftIndex);
      end
      else
      begin
        Temporary[OutputIndex] := ASeeds[RightIndex];
        Inc(RightIndex);
      end;
      Inc(OutputIndex);
    end;
    while LeftIndex <= MiddleIndex do
    begin
      Temporary[OutputIndex] := ASeeds[LeftIndex];
      Inc(LeftIndex);
      Inc(OutputIndex);
    end;
    while RightIndex <= AHigh do
    begin
      Temporary[OutputIndex] := ASeeds[RightIndex];
      Inc(RightIndex);
      Inc(OutputIndex);
    end;
    for OutputIndex := ALow to AHigh do
      ASeeds[OutputIndex] := Temporary[OutputIndex];
  end;

begin
  if Length(ASeeds) < 2 then Exit;
  SetLength(Temporary, Length(ASeeds));
  MergeSort(0, High(ASeeds));
end;

function ParameterizedToken(const AKind: TLWPTPascalTokenKind): Boolean;
begin
  Result := AKind in [ptIdentifier, ptNumber, ptString];
end;

function TokenIdentityKey(const AToken: TLWPTPascalToken): string;
begin
  Result := Chr(Ord(AToken.Kind) + 1) + ':' + AToken.Text;
end;

procedure BuildCanonicalTokenData(var ADocuments: TAnalyzedDocumentArray;
  out ATokenIDCount: Integer);
var
  DocumentIndex, TokenID, TokenIndex: Integer;
  LastSeen: TIntegerArray;
  TokenIdentities: TStringList;
begin
  TokenIdentities := TStringList.Create;
  try
    TokenIdentities.CaseSensitive := True;
    TokenIdentities.Sorted := True;
    TokenIdentities.Duplicates := dupIgnore;
    for DocumentIndex := 0 to High(ADocuments) do
      for TokenIndex := 0 to High(ADocuments[DocumentIndex].Document.Tokens) do
        TokenIdentities.Add(TokenIdentityKey(ADocuments[DocumentIndex].
          Document.Tokens[TokenIndex]));
    ATokenIDCount := TokenIdentities.Count;
    SetLength(LastSeen, ATokenIDCount + 1);
    for DocumentIndex := 0 to High(ADocuments) do
    begin
      SetLength(ADocuments[DocumentIndex].TokenIDs,
        Length(ADocuments[DocumentIndex].Document.Tokens));
      SetLength(ADocuments[DocumentIndex].PreviousToken,
        Length(ADocuments[DocumentIndex].Document.Tokens));
      SetLength(ADocuments[DocumentIndex].NextToken,
        Length(ADocuments[DocumentIndex].Document.Tokens));
      FillChar(LastSeen[0], Length(LastSeen) * SizeOf(LastSeen[0]), 0);
      for TokenIndex := 0 to
        High(ADocuments[DocumentIndex].Document.Tokens) do
      begin
        TokenID := TokenIdentities.IndexOf(TokenIdentityKey(
          ADocuments[DocumentIndex].Document.Tokens[TokenIndex])) + 1;
        ADocuments[DocumentIndex].TokenIDs[TokenIndex] := TokenID;
        ADocuments[DocumentIndex].PreviousToken[TokenIndex] :=
          LastSeen[TokenID] - 1;
        LastSeen[TokenID] := TokenIndex + 1;
      end;
      FillChar(LastSeen[0], Length(LastSeen) * SizeOf(LastSeen[0]), 0);
      for TokenIndex := High(ADocuments[DocumentIndex].Document.Tokens)
        downto 0 do
      begin
        TokenID := ADocuments[DocumentIndex].TokenIDs[TokenIndex];
        ADocuments[DocumentIndex].NextToken[TokenIndex] :=
          LastSeen[TokenID] - 1;
        LastSeen[TokenID] := TokenIndex + 1;
      end;
    end;
  finally
    TokenIdentities.Free;
  end;
end;

function ParameterizedValue(const ADocument: TAnalyzedDocument;
  const ATokenIndex, AWindowStart: Integer): Integer; inline;
begin
  Result := ADocument.PreviousToken[ATokenIndex];
  if Result < AWindowStart then Result := 0
  else Result := ATokenIndex - Result;
end;

function EncodedToken(const ADocument: TAnalyzedDocument;
  const ATokenIndex, AWindowStart: Integer): QWord; inline;
begin
  Result := QWord(Ord(ADocument.Document.Tokens[ATokenIndex].Kind) + 1)
    shl 32;
  if ParameterizedToken(ADocument.Document.Tokens[ATokenIndex].Kind) then
    Result := Result + QWord(ParameterizedValue(ADocument, ATokenIndex,
      AWindowStart))
  else
    Result := Result + QWord(ADocument.TokenIDs[ATokenIndex]);
end;

const
  WINDOW_HASH_BASE = QWord(1099511628211);

{$PUSH}{$Q-}{$R-}
procedure BuildWindowPowers(const ATokenCount: Integer;
  var APowers: TQWordArray);
var
  PowerIndex: Integer;
begin
  SetLength(APowers, ATokenCount);
  APowers[0] := 1;
  for PowerIndex := 1 to High(APowers) do
    APowers[PowerIndex] := APowers[PowerIndex - 1] * WINDOW_HASH_BASE;
end;

function InitialWindowHash(const ADocument: TAnalyzedDocument;
  const AStartToken, ATokenCount: Integer): QWord;
var
  TokenIndex: Integer;
begin
  Result := 0;
  for TokenIndex := AStartToken to AStartToken + ATokenCount - 1 do
    Result := Result * WINDOW_HASH_BASE
      + EncodedToken(ADocument, TokenIndex, AStartToken);
end;

function ShiftWindowHash(const ADocument: TAnalyzedDocument;
  const AHash: QWord; const AStartToken, ATokenCount: Integer;
  const APowers: TQWordArray): QWord;
var
  Distance, NextOccurrence: Integer;
begin
  Result := AHash - EncodedToken(ADocument, AStartToken, AStartToken)
    * APowers[ATokenCount - 1];
  if ParameterizedToken(ADocument.Document.Tokens[AStartToken].Kind) then
  begin
    NextOccurrence := ADocument.NextToken[AStartToken];
    if (NextOccurrence >= 0)
      and (NextOccurrence < AStartToken + ATokenCount) then
    begin
      Distance := NextOccurrence - AStartToken;
      Result := Result - QWord(Distance)
        * APowers[ATokenCount - 1 - Distance];
    end;
  end;
  Result := Result * WINDOW_HASH_BASE
    + EncodedToken(ADocument, AStartToken + ATokenCount, AStartToken + 1);
end;
{$POP}

procedure InitializeMatcher(var AMatcher: TParameterizedMatcher;
  const ATokenIDCount: Integer);
begin
  AMatcher := Default(TParameterizedMatcher);
  SetLength(AMatcher.LeftMap, ATokenIDCount + 1);
  SetLength(AMatcher.RightMap, ATokenIDCount + 1);
  SetLength(AMatcher.LeftStamp, ATokenIDCount + 1);
  SetLength(AMatcher.RightStamp, ATokenIDCount + 1);
end;

procedure BeginMatch(var AMatcher: TParameterizedMatcher);
begin
  if AMatcher.Generation = High(Integer) then
  begin
    FillChar(AMatcher.LeftStamp[0], Length(AMatcher.LeftStamp)
      * SizeOf(AMatcher.LeftStamp[0]), 0);
    FillChar(AMatcher.RightStamp[0], Length(AMatcher.RightStamp)
      * SizeOf(AMatcher.RightStamp[0]), 0);
    AMatcher.Generation := 1;
  end
  else
    Inc(AMatcher.Generation);
end;

function ParameterizedMatchLength(const ALeftDocument,
  ARightDocument: TAnalyzedDocument; const ALeftStart, ALeftLimit,
  ARightStart, ARightLimit: Integer;
  var AMatcher: TParameterizedMatcher): Integer;
var
  LeftID, RightID: Integer;
  LeftToken, RightToken: TLWPTPascalToken;
begin
  Result := 0;
  BeginMatch(AMatcher);
  while (ALeftStart + Result < ALeftLimit)
    and (ARightStart + Result < ARightLimit) do
  begin
    LeftToken := ALeftDocument.Document.Tokens[ALeftStart + Result];
    RightToken := ARightDocument.Document.Tokens[ARightStart + Result];
    if LeftToken.Kind <> RightToken.Kind then Exit;
    if not ParameterizedToken(LeftToken.Kind) then
    begin
      if ALeftDocument.TokenIDs[ALeftStart + Result]
        <> ARightDocument.TokenIDs[ARightStart + Result] then Exit;
      Inc(Result);
      Continue;
    end;
    LeftID := ALeftDocument.TokenIDs[ALeftStart + Result];
    RightID := ARightDocument.TokenIDs[ARightStart + Result];
    if (AMatcher.LeftStamp[LeftID] = AMatcher.Generation)
      and (AMatcher.LeftMap[LeftID] <> RightID) then Exit;
    if (AMatcher.RightStamp[RightID] = AMatcher.Generation)
      and (AMatcher.RightMap[RightID] <> LeftID) then Exit;
    if AMatcher.LeftStamp[LeftID] <> AMatcher.Generation then
    begin
      AMatcher.LeftStamp[LeftID] := AMatcher.Generation;
      AMatcher.LeftMap[LeftID] := RightID;
    end;
    if AMatcher.RightStamp[RightID] <> AMatcher.Generation then
    begin
      AMatcher.RightStamp[RightID] := AMatcher.Generation;
      AMatcher.RightMap[RightID] := LeftID;
    end;
    Inc(Result);
  end;
end;

procedure AddSeed(var ASeeds: TSeedArray; const AHash: QWord;
  const ADocumentIndex, ARegionIndex, AStartToken: Integer);
var
  SeedCount: Integer;
begin
  SeedCount := Length(ASeeds);
  SetLength(ASeeds, SeedCount + 1);
  ASeeds[SeedCount].Hash := AHash;
  ASeeds[SeedCount].DocumentIndex := ADocumentIndex;
  ASeeds[SeedCount].RegionIndex := ARegionIndex;
  ASeeds[SeedCount].StartToken := AStartToken;
end;

procedure BuildSeeds(const ADocuments: TAnalyzedDocumentArray;
  const AMinimumTokens: Integer; var ASeeds: TSeedArray);
var
  DocumentIndex, RegionIndex, StartToken: Integer;
  Powers: TQWordArray;
  Region: TLWPTPascalRegion;
  RollingHash: QWord;
begin
  SetLength(ASeeds, 0);
  BuildWindowPowers(AMinimumTokens, Powers);
  for DocumentIndex := 0 to High(ADocuments) do
    for RegionIndex := 0 to High(ADocuments[DocumentIndex].Document.Regions) do
    begin
      Region := ADocuments[DocumentIndex].Document.Regions[RegionIndex];
      if Region.Tokens.EndToken - Region.Tokens.StartToken < AMinimumTokens
        then Continue;
      RollingHash := InitialWindowHash(ADocuments[DocumentIndex],
        Region.Tokens.StartToken, AMinimumTokens);
      for StartToken := Region.Tokens.StartToken to
        Region.Tokens.EndToken - AMinimumTokens do
      begin
        AddSeed(ASeeds, RollingHash, DocumentIndex, RegionIndex, StartToken);
        if StartToken < Region.Tokens.EndToken - AMinimumTokens then
          RollingHash := ShiftWindowHash(ADocuments[DocumentIndex],
            RollingHash, StartToken, AMinimumTokens, Powers);
      end;
    end;
  SortSeeds(ASeeds);
end;

function SeedsComparable(const ALeft, ARight: TSeed;
  const ADocuments: TAnalyzedDocumentArray): Boolean;
begin
  Result := PascalRegionIsExecutable(ADocuments[ALeft.DocumentIndex].Document.
    Regions[ALeft.RegionIndex].Kind)
    = PascalRegionIsExecutable(ADocuments[ARight.DocumentIndex].Document.
      Regions[ARight.RegionIndex].Kind);
end;

procedure AddCandidate(var ACandidates: TCandidateArray;
  const ALeft, ARight: TSeed; const ATokenCount: Integer);
var
  CandidateCount: Integer;
  Left, Right: TSeed;
begin
  Left := ALeft;
  Right := ARight;
  if CompareOccurrence(Left.DocumentIndex, Left.RegionIndex, Left.StartToken,
    Right.DocumentIndex, Right.RegionIndex, Right.StartToken) > 0 then
  begin
    Left := ARight;
    Right := ALeft;
  end;
  CandidateCount := Length(ACandidates);
  SetLength(ACandidates, CandidateCount + 1);
  ACandidates[CandidateCount].Hash := Left.Hash;
  ACandidates[CandidateCount].LeftDocument := Left.DocumentIndex;
  ACandidates[CandidateCount].LeftRegion := Left.RegionIndex;
  ACandidates[CandidateCount].LeftStart := Left.StartToken;
  ACandidates[CandidateCount].RightDocument := Right.DocumentIndex;
  ACandidates[CandidateCount].RightRegion := Right.RegionIndex;
  ACandidates[CandidateCount].RightStart := Right.StartToken;
  ACandidates[CandidateCount].TokenCount := ATokenCount;
end;

function CompareParameterizedSuffix(const ALeft, ARight: TSeed;
  const ADocuments: TAnalyzedDocumentArray): Integer;
var
  LeftIndex, LeftLimit, LeftValue, RightIndex, RightLimit,
    RightValue: Integer;
  LeftToken, RightToken: TLWPTPascalToken;
begin
  LeftIndex := ALeft.StartToken;
  RightIndex := ARight.StartToken;
  LeftLimit := ADocuments[ALeft.DocumentIndex].Document.Regions[
    ALeft.RegionIndex].Tokens.EndToken;
  RightLimit := ADocuments[ARight.DocumentIndex].Document.Regions[
    ARight.RegionIndex].Tokens.EndToken;
  while (LeftIndex < LeftLimit) and (RightIndex < RightLimit) do
  begin
    LeftToken := ADocuments[ALeft.DocumentIndex].Document.Tokens[LeftIndex];
    RightToken := ADocuments[ARight.DocumentIndex].Document.Tokens[
      RightIndex];
    if Ord(LeftToken.Kind) < Ord(RightToken.Kind) then Exit(-1);
    if Ord(LeftToken.Kind) > Ord(RightToken.Kind) then Exit(1);
    if ParameterizedToken(LeftToken.Kind) then
    begin
      LeftValue := ParameterizedValue(ADocuments[ALeft.DocumentIndex],
        LeftIndex, ALeft.StartToken);
      RightValue := ParameterizedValue(ADocuments[ARight.DocumentIndex],
        RightIndex, ARight.StartToken);
      if LeftValue < RightValue then Exit(-1);
      if LeftValue > RightValue then Exit(1);
    end;
    if not ParameterizedToken(LeftToken.Kind) then
    begin
      LeftValue := ADocuments[ALeft.DocumentIndex].TokenIDs[LeftIndex];
      RightValue := ADocuments[ARight.DocumentIndex].TokenIDs[RightIndex];
      if LeftValue < RightValue then Exit(-1);
      if LeftValue > RightValue then Exit(1);
    end;
    Inc(LeftIndex);
    Inc(RightIndex);
  end;
  if LeftIndex < LeftLimit then Exit(1);
  if RightIndex < RightLimit then Exit(-1);
  Result := CompareOccurrence(ALeft.DocumentIndex, ALeft.RegionIndex,
    ALeft.StartToken, ARight.DocumentIndex, ARight.RegionIndex,
    ARight.StartToken);
end;

procedure SortSeedSuffixes(var ASeeds: TSeedArray;
  const ADocuments: TAnalyzedDocumentArray);
var
  Temporary: TSeedArray;

  procedure MergeSort(const ALow, AHigh: Integer);
  var
    LeftIndex, MiddleIndex, OutputIndex, RightIndex: Integer;
  begin
    if ALow >= AHigh then Exit;
    MiddleIndex := ALow + ((AHigh - ALow) div 2);
    MergeSort(ALow, MiddleIndex);
    MergeSort(MiddleIndex + 1, AHigh);
    LeftIndex := ALow;
    RightIndex := MiddleIndex + 1;
    OutputIndex := ALow;
    while (LeftIndex <= MiddleIndex) and (RightIndex <= AHigh) do
    begin
      if CompareParameterizedSuffix(ASeeds[LeftIndex],
        ASeeds[RightIndex], ADocuments) <= 0 then
      begin
        Temporary[OutputIndex] := ASeeds[LeftIndex];
        Inc(LeftIndex);
      end
      else
      begin
        Temporary[OutputIndex] := ASeeds[RightIndex];
        Inc(RightIndex);
      end;
      Inc(OutputIndex);
    end;
    while LeftIndex <= MiddleIndex do
    begin
      Temporary[OutputIndex] := ASeeds[LeftIndex];
      Inc(LeftIndex);
      Inc(OutputIndex);
    end;
    while RightIndex <= AHigh do
    begin
      Temporary[OutputIndex] := ASeeds[RightIndex];
      Inc(RightIndex);
      Inc(OutputIndex);
    end;
    for OutputIndex := ALow to AHigh do
      ASeeds[OutputIndex] := Temporary[OutputIndex];
  end;

begin
  if Length(ASeeds) < 2 then Exit;
  SetLength(Temporary, Length(ASeeds));
  MergeSort(0, High(ASeeds));
end;

procedure BuildCandidateBucket(const ADocuments: TAnalyzedDocumentArray;
  const AConfigurations: TLWPTDuplicationConfigurationArray;
  const ASeeds: TSeedArray; const AExecutable: Boolean;
  var AMatcher: TParameterizedMatcher; var ACandidates: TCandidateArray);
var
  Bucket: TSeedArray;
  AdjacentLCP, DocumentStamp, EarliestSeed, LatestSeed,
    TouchedDocuments: TIntegerArray;
  BestDistance, BestDocument, BucketCount, CandidateLength, DocumentIndex,
    FirstDocumentSeed, GroupEnd, GroupStart, IntervalStamp, LCPIndex,
    MatchLength, MinimumIndex, RequiredMinimum, SecondDocumentSeed,
    SeedIndex, TouchedDocumentCount, TouchedIndex: Integer;
  DuplicateInterval: Boolean;
  LeftRegion, RightRegion: TLWPTPascalRegion;
begin
  SetLength(Bucket, Length(ASeeds));
  BucketCount := 0;
  for SeedIndex := 0 to High(ASeeds) do
    if PascalRegionIsExecutable(ADocuments[ASeeds[SeedIndex].DocumentIndex].
      Document.Regions[ASeeds[SeedIndex].RegionIndex].Kind) = AExecutable then
    begin
      Bucket[BucketCount] := ASeeds[SeedIndex];
      Inc(BucketCount);
    end;
  SetLength(Bucket, BucketCount);
  if BucketCount < 2 then Exit;

  { Parameterized suffix ordering gives the usual LCP interval property.
    Build the adjacent LCP array once, then each distinct interval chooses the
    pair that maximizes the usable non-overlapping length. Candidate storage
    remains linear; interval selection below uses only coordinates and the
    already-computed LCP values. The suffix comparator itself may inspect long
    tails while sorting, so this deliberately claims no linear-time suffix
    construction. }
  SortSeedSuffixes(Bucket, ADocuments);
  SetLength(AdjacentLCP, BucketCount - 1);
  for SeedIndex := 0 to High(AdjacentLCP) do
  begin
    LeftRegion := ADocuments[Bucket[SeedIndex].DocumentIndex].Document.
      Regions[Bucket[SeedIndex].RegionIndex];
    RightRegion := ADocuments[Bucket[SeedIndex + 1].DocumentIndex].Document.
      Regions[Bucket[SeedIndex + 1].RegionIndex];
    AdjacentLCP[SeedIndex] := ParameterizedMatchLength(
      ADocuments[Bucket[SeedIndex].DocumentIndex],
      ADocuments[Bucket[SeedIndex + 1].DocumentIndex],
      Bucket[SeedIndex].StartToken, LeftRegion.Tokens.EndToken,
      Bucket[SeedIndex + 1].StartToken, RightRegion.Tokens.EndToken,
      AMatcher);
  end;

  SetLength(EarliestSeed, Length(ADocuments));
  SetLength(LatestSeed, Length(ADocuments));
  SetLength(DocumentStamp, Length(ADocuments));
  SetLength(TouchedDocuments, Length(ADocuments));
  IntervalStamp := 0;
  for LCPIndex := 0 to High(AdjacentLCP) do
  begin
    MatchLength := AdjacentLCP[LCPIndex];
    if MatchLength <= 0 then Continue;
    GroupStart := LCPIndex;
    while (GroupStart > 0)
      and (AdjacentLCP[GroupStart - 1] >= MatchLength) do Dec(GroupStart);
    GroupEnd := LCPIndex;
    while (GroupEnd < High(AdjacentLCP))
      and (AdjacentLCP[GroupEnd + 1] >= MatchLength) do Inc(GroupEnd);

    { Equal minima inside one maximal LCP interval describe the same node.
      Emit it once so the number of candidates cannot exceed the number of
      adjacent LCP entries. }
    DuplicateInterval := False;
    for MinimumIndex := GroupStart to LCPIndex - 1 do
      if AdjacentLCP[MinimumIndex] = MatchLength then
      begin
        DuplicateInterval := True;
        Break;
      end;
    if DuplicateInterval then Continue;

    Inc(IntervalStamp);
    TouchedDocumentCount := 0;
    for SeedIndex := GroupStart to GroupEnd + 1 do
    begin
      DocumentIndex := Bucket[SeedIndex].DocumentIndex;
      RequiredMinimum := AConfigurations[ADocuments[DocumentIndex].
        ProjectIndex].MinimumTokens;
      if RequiredMinimum > MatchLength then Continue;
      if DocumentStamp[DocumentIndex] <> IntervalStamp then
      begin
        DocumentStamp[DocumentIndex] := IntervalStamp;
        EarliestSeed[DocumentIndex] := SeedIndex;
        LatestSeed[DocumentIndex] := SeedIndex;
        TouchedDocuments[TouchedDocumentCount] := DocumentIndex;
        Inc(TouchedDocumentCount);
        Continue;
      end;
      if
        (Bucket[SeedIndex].StartToken < Bucket[
          EarliestSeed[DocumentIndex]].StartToken) then
        EarliestSeed[DocumentIndex] := SeedIndex;
      if
        (Bucket[SeedIndex].StartToken > Bucket[
          LatestSeed[DocumentIndex]].StartToken) then
        LatestSeed[DocumentIndex] := SeedIndex;
    end;

    { Different documents never overlap, so the interval LCP is optimal. }
    FirstDocumentSeed := -1;
    SecondDocumentSeed := -1;
    for TouchedIndex := 0 to TouchedDocumentCount - 1 do
    begin
      DocumentIndex := TouchedDocuments[TouchedIndex];
      if (FirstDocumentSeed < 0) or
        (CompareOccurrence(Bucket[EarliestSeed[DocumentIndex]].DocumentIndex,
          Bucket[EarliestSeed[DocumentIndex]].RegionIndex,
          Bucket[EarliestSeed[DocumentIndex]].StartToken,
          Bucket[FirstDocumentSeed].DocumentIndex,
          Bucket[FirstDocumentSeed].RegionIndex,
          Bucket[FirstDocumentSeed].StartToken) < 0) then
      begin
        SecondDocumentSeed := FirstDocumentSeed;
        FirstDocumentSeed := EarliestSeed[DocumentIndex];
      end
      else if (SecondDocumentSeed < 0) or
        (CompareOccurrence(Bucket[EarliestSeed[DocumentIndex]].DocumentIndex,
          Bucket[EarliestSeed[DocumentIndex]].RegionIndex,
          Bucket[EarliestSeed[DocumentIndex]].StartToken,
          Bucket[SecondDocumentSeed].DocumentIndex,
          Bucket[SecondDocumentSeed].RegionIndex,
          Bucket[SecondDocumentSeed].StartToken) < 0) then
        SecondDocumentSeed := EarliestSeed[DocumentIndex];
    end;
    if SecondDocumentSeed >= 0 then
    begin
      AddCandidate(ACandidates, Bucket[FirstDocumentSeed],
        Bucket[SecondDocumentSeed], MatchLength);
      Continue;
    end;

    { A same-document pair is capped by its coordinate distance. Across an
      LCP interval the extreme starts maximize min(LCP, distance). }
    BestDistance := -1;
    BestDocument := -1;
    for TouchedIndex := 0 to TouchedDocumentCount - 1 do
    begin
      DocumentIndex := TouchedDocuments[TouchedIndex];
      if (EarliestSeed[DocumentIndex] <> LatestSeed[DocumentIndex])
        and (Bucket[LatestSeed[DocumentIndex]].StartToken
          - Bucket[EarliestSeed[DocumentIndex]].StartToken >
          BestDistance) then
      begin
        BestDistance := Bucket[LatestSeed[DocumentIndex]].StartToken
          - Bucket[EarliestSeed[DocumentIndex]].StartToken;
        BestDocument := DocumentIndex;
      end;
    end;
    if BestDocument < 0 then Continue;
    CandidateLength := MatchLength;
    if BestDistance < CandidateLength then CandidateLength := BestDistance;
    RequiredMinimum := AConfigurations[ADocuments[BestDocument].ProjectIndex].
      MinimumTokens;
    if CandidateLength >= RequiredMinimum then
      AddCandidate(ACandidates, Bucket[EarliestSeed[BestDocument]],
        Bucket[LatestSeed[BestDocument]], CandidateLength);
  end;
end;

procedure BuildCandidates(const ADocuments: TAnalyzedDocumentArray;
  const AConfigurations: TLWPTDuplicationConfigurationArray;
  const ASeeds: TSeedArray; var AMatcher: TParameterizedMatcher;
  var ACandidates: TCandidateArray);
var
  GroupEnd, GroupIndex, GroupStart: Integer;
  SeedGroup: TSeedArray;
begin
  SetLength(ACandidates, 0);
  GroupStart := 0;
  while GroupStart < Length(ASeeds) do
  begin
    GroupEnd := GroupStart + 1;
    while (GroupEnd < Length(ASeeds))
      and (ASeeds[GroupEnd].Hash = ASeeds[GroupStart].Hash) do Inc(GroupEnd);
    SetLength(SeedGroup, GroupEnd - GroupStart);
    for GroupIndex := GroupStart to GroupEnd - 1 do
      SeedGroup[GroupIndex - GroupStart] := ASeeds[GroupIndex];
    BuildCandidateBucket(ADocuments, AConfigurations, SeedGroup, False,
      AMatcher, ACandidates);
    BuildCandidateBucket(ADocuments, AConfigurations, SeedGroup, True,
      AMatcher, ACandidates);
    GroupStart := GroupEnd;
  end;
end;

function CompareCandidate(const ALeft, ARight: TCandidate): Integer;
begin
  if ALeft.TokenCount > ARight.TokenCount then Exit(-1);
  if ALeft.TokenCount < ARight.TokenCount then Exit(1);
  Result := CompareOccurrence(ALeft.LeftDocument, ALeft.LeftRegion,
    ALeft.LeftStart, ARight.LeftDocument, ARight.LeftRegion,
    ARight.LeftStart);
  if Result <> 0 then Exit;
  Result := CompareOccurrence(ALeft.RightDocument, ALeft.RightRegion,
    ALeft.RightStart, ARight.RightDocument, ARight.RightRegion,
    ARight.RightStart);
end;

procedure SortCandidates(var ACandidates: TCandidateArray);
var
  Temporary: TCandidateArray;

  procedure MergeSort(const ALow, AHigh: Integer);
  var
    LeftIndex, MiddleIndex, OutputIndex, RightIndex: Integer;
  begin
    if ALow >= AHigh then Exit;
    MiddleIndex := ALow + ((AHigh - ALow) div 2);
    MergeSort(ALow, MiddleIndex);
    MergeSort(MiddleIndex + 1, AHigh);
    LeftIndex := ALow;
    RightIndex := MiddleIndex + 1;
    OutputIndex := ALow;
    while (LeftIndex <= MiddleIndex) and (RightIndex <= AHigh) do
    begin
      if CompareCandidate(ACandidates[LeftIndex],
        ACandidates[RightIndex]) <= 0 then
      begin
        Temporary[OutputIndex] := ACandidates[LeftIndex];
        Inc(LeftIndex);
      end
      else
      begin
        Temporary[OutputIndex] := ACandidates[RightIndex];
        Inc(RightIndex);
      end;
      Inc(OutputIndex);
    end;
    while LeftIndex <= MiddleIndex do
    begin
      Temporary[OutputIndex] := ACandidates[LeftIndex];
      Inc(LeftIndex);
      Inc(OutputIndex);
    end;
    while RightIndex <= AHigh do
    begin
      Temporary[OutputIndex] := ACandidates[RightIndex];
      Inc(RightIndex);
      Inc(OutputIndex);
    end;
    for OutputIndex := ALow to AHigh do
      ACandidates[OutputIndex] := Temporary[OutputIndex];
  end;

begin
  if Length(ACandidates) < 2 then Exit;
  SetLength(Temporary, Length(ACandidates));
  MergeSort(0, High(ACandidates));
end;

function RangeOccupied(const AOccupancy: TDocumentOccupancy;
  const ADocumentIndex, AStartToken, ATokenCount: Integer): Boolean;
var
  TokenIndex: Integer;
begin
  for TokenIndex := AStartToken to AStartToken + ATokenCount - 1 do
    if AOccupancy[ADocumentIndex][TokenIndex] then Exit(True);
  Result := False;
end;

function OccurrencesOverlap(const ALeft, ARight: TInternalOccurrence;
  const ATokenCount: Integer): Boolean;
begin
  Result := (ALeft.DocumentIndex = ARight.DocumentIndex)
    and (ALeft.StartToken < ARight.StartToken + ATokenCount)
    and (ARight.StartToken < ALeft.StartToken + ATokenCount);
end;

function CanAddOccurrence(const AOccurrences: TInternalOccurrenceArray;
  const AOccurrence: TInternalOccurrence; const ATokenCount: Integer;
  const AOccupancy: TDocumentOccupancy): Boolean;
var
  OccurrenceIndex: Integer;
begin
  if RangeOccupied(AOccupancy, AOccurrence.DocumentIndex,
    AOccurrence.StartToken, ATokenCount) then Exit(False);
  for OccurrenceIndex := 0 to High(AOccurrences) do
    if OccurrencesOverlap(AOccurrences[OccurrenceIndex], AOccurrence,
      ATokenCount) then Exit(False);
  Result := True;
end;

procedure AddInternalOccurrence(var AOccurrences: TInternalOccurrenceArray;
  const ADocumentIndex, ARegionIndex, AStartToken: Integer);
var
  Count: Integer;
begin
  Count := Length(AOccurrences);
  SetLength(AOccurrences, Count + 1);
  AOccurrences[Count].DocumentIndex := ADocumentIndex;
  AOccurrences[Count].RegionIndex := ARegionIndex;
  AOccurrences[Count].StartToken := AStartToken;
end;

procedure MarkOccupied(var AOccupancy: TDocumentOccupancy;
  const AOccurrences: TInternalOccurrenceArray; const ATokenCount: Integer);
var
  OccurrenceIndex, TokenIndex: Integer;
begin
  for OccurrenceIndex := 0 to High(AOccurrences) do
    for TokenIndex := AOccurrences[OccurrenceIndex].StartToken to
      AOccurrences[OccurrenceIndex].StartToken + ATokenCount - 1 do
      AOccupancy[AOccurrences[OccurrenceIndex].DocumentIndex][TokenIndex] :=
        True;
end;

function RegionKindName(const AKind: TLWPTPascalRegionKind): string;
begin
  case AKind of
    pgUnitDeclarations: Result := 'unit-declarations';
    pgRoutineDeclarations: Result := 'routine-declarations';
    pgRoutineBody: Result := 'routine-body';
    pgProgramBody: Result := 'program-body';
    pgInitialization: Result := 'initialization';
    pgFinalization: Result := 'finalization';
  end;
end;

procedure AddReportGroup(var AReport: TLWPTDuplicationReport;
  const ADocuments: TAnalyzedDocumentArray;
  const AOccurrences: TInternalOccurrenceArray; const ATokenCount: Integer);
var
  GroupIndex, OccurrenceIndex, LastToken: Integer;
  Occurrence: TInternalOccurrence;
  StartLocation, EndLocation: TLWPTPascalToken;
begin
  GroupIndex := Length(AReport.Groups);
  SetLength(AReport.Groups, GroupIndex + 1);
  AReport.Groups[GroupIndex].TokenCount := ATokenCount;
  SetLength(AReport.Groups[GroupIndex].Occurrences, Length(AOccurrences));
  for OccurrenceIndex := 0 to High(AOccurrences) do
  begin
    Occurrence := AOccurrences[OccurrenceIndex];
    StartLocation := ADocuments[Occurrence.DocumentIndex].Document.Tokens[
      Occurrence.StartToken];
    LastToken := Occurrence.StartToken + ATokenCount - 1;
    EndLocation := ADocuments[Occurrence.DocumentIndex].Document.Tokens[
      LastToken];
    with AReport.Groups[GroupIndex].Occurrences[OccurrenceIndex] do
    begin
      DocumentIndex := Occurrence.DocumentIndex;
      FileName := ADocuments[Occurrence.DocumentIndex].RootRelativePath;
      RegionKind := RegionKindName(ADocuments[Occurrence.DocumentIndex].
        Document.Regions[Occurrence.RegionIndex].Kind);
      StartLine := StartLocation.Line;
      StartColumn := StartLocation.Column;
      EndLine := EndLocation.Line;
      EndColumn := EndLocation.Column;
    end;
  end;
  Inc(AReport.DuplicateTokens, Int64(ATokenCount)
    * (Length(AOccurrences) - 1));
end;

function SeedHashStart(const ASeeds: TSeedArray; const AHash: QWord): Integer;
var
  HighIndex, MiddleIndex, LowIndex: Integer;
begin
  LowIndex := 0;
  HighIndex := Length(ASeeds);
  while LowIndex < HighIndex do
  begin
    MiddleIndex := LowIndex + ((HighIndex - LowIndex) div 2);
    if ASeeds[MiddleIndex].Hash < AHash then LowIndex := MiddleIndex + 1
    else HighIndex := MiddleIndex;
  end;
  Result := LowIndex;
end;

function SeedHashEnd(const ASeeds: TSeedArray; const AHash: QWord): Integer;
var
  HighIndex, MiddleIndex, LowIndex: Integer;
begin
  LowIndex := 0;
  HighIndex := Length(ASeeds);
  while LowIndex < HighIndex do
  begin
    MiddleIndex := LowIndex + ((HighIndex - LowIndex) div 2);
    if ASeeds[MiddleIndex].Hash <= AHash then LowIndex := MiddleIndex + 1
    else HighIndex := MiddleIndex;
  end;
  Result := LowIndex;
end;

function MatchesEveryOccurrence(const ADocuments: TAnalyzedDocumentArray;
  const AOccurrences: TInternalOccurrenceArray;
  const ACandidateOccurrence: TInternalOccurrence;
  const ATokenCount: Integer; var AMatcher: TParameterizedMatcher): Boolean;
var
  ExistingOccurrence: TInternalOccurrence;
  MatchLength, OccurrenceIndex: Integer;
  CandidateRegion, ExistingRegion: TLWPTPascalRegion;
begin
  CandidateRegion := ADocuments[ACandidateOccurrence.DocumentIndex].Document.
    Regions[ACandidateOccurrence.RegionIndex];
  for OccurrenceIndex := 0 to High(AOccurrences) do
  begin
    ExistingOccurrence := AOccurrences[OccurrenceIndex];
    ExistingRegion := ADocuments[ExistingOccurrence.DocumentIndex].Document.
      Regions[ExistingOccurrence.RegionIndex];
    MatchLength := ParameterizedMatchLength(
      ADocuments[ExistingOccurrence.DocumentIndex],
      ADocuments[ACandidateOccurrence.DocumentIndex],
      ExistingOccurrence.StartToken, ExistingRegion.Tokens.EndToken,
      ACandidateOccurrence.StartToken, CandidateRegion.Tokens.EndToken,
      AMatcher);
    if MatchLength < ATokenCount then Exit(False);
  end;
  Result := True;
end;

procedure SelectGroups(const ADocuments: TAnalyzedDocumentArray;
  const AConfigurations: TLWPTDuplicationConfigurationArray;
  const ASeeds: TSeedArray; var ACandidates: TCandidateArray;
  var AMatcher: TParameterizedMatcher; var AReport: TLWPTDuplicationReport);
var
  BaseSeed, Seed: TSeed;
  CandidateIndex, DocumentIndex, SeedEnd, SeedIndex, SeedStart: Integer;
  Candidate: TCandidate;
  Occurrence, RightOccurrence: TInternalOccurrence;
  Occurrences: TInternalOccurrenceArray;
  Occupancy: TDocumentOccupancy;
  SeedRegion: TLWPTPascalRegion;
begin
  SetLength(Occupancy, Length(ADocuments));
  for DocumentIndex := 0 to High(ADocuments) do
    SetLength(Occupancy[DocumentIndex],
      Length(ADocuments[DocumentIndex].Document.Tokens));
  SortCandidates(ACandidates);
  for CandidateIndex := 0 to High(ACandidates) do
  begin
    Candidate := ACandidates[CandidateIndex];
    Occurrence.DocumentIndex := Candidate.LeftDocument;
    Occurrence.RegionIndex := Candidate.LeftRegion;
    Occurrence.StartToken := Candidate.LeftStart;
    RightOccurrence.DocumentIndex := Candidate.RightDocument;
    RightOccurrence.RegionIndex := Candidate.RightRegion;
    RightOccurrence.StartToken := Candidate.RightStart;
    SetLength(Occurrences, 0);
    if not CanAddOccurrence(Occurrences, Occurrence, Candidate.TokenCount,
      Occupancy) then Continue;
    AddInternalOccurrence(Occurrences, Occurrence.DocumentIndex,
      Occurrence.RegionIndex, Occurrence.StartToken);
    if not CanAddOccurrence(Occurrences, RightOccurrence,
      Candidate.TokenCount, Occupancy) then Continue;
    if not MatchesEveryOccurrence(ADocuments, Occurrences, RightOccurrence,
      Candidate.TokenCount, AMatcher) then Continue;
    AddInternalOccurrence(Occurrences, RightOccurrence.DocumentIndex,
      RightOccurrence.RegionIndex, RightOccurrence.StartToken);

    BaseSeed.Hash := Candidate.Hash;
    BaseSeed.DocumentIndex := Candidate.LeftDocument;
    BaseSeed.RegionIndex := Candidate.LeftRegion;
    BaseSeed.StartToken := Candidate.LeftStart;
    SeedStart := SeedHashStart(ASeeds, Candidate.Hash);
    SeedEnd := SeedHashEnd(ASeeds, Candidate.Hash);
    for SeedIndex := SeedStart to SeedEnd - 1 do
    begin
      Seed := ASeeds[SeedIndex];
      if CompareOccurrence(Seed.DocumentIndex, Seed.RegionIndex,
        Seed.StartToken, BaseSeed.DocumentIndex, BaseSeed.RegionIndex,
        BaseSeed.StartToken) = 0 then Continue;
      Occurrence.DocumentIndex := Seed.DocumentIndex;
      Occurrence.RegionIndex := Seed.RegionIndex;
      Occurrence.StartToken := Seed.StartToken;
      SeedRegion := ADocuments[Seed.DocumentIndex].Document.Regions[
        Seed.RegionIndex];
      if Seed.StartToken + Candidate.TokenCount >
        SeedRegion.Tokens.EndToken then Continue;
      if not CanAddOccurrence(Occurrences, Occurrence,
        Candidate.TokenCount, Occupancy) then Continue;
      if AConfigurations[ADocuments[Seed.DocumentIndex].ProjectIndex].
        MinimumTokens > Candidate.TokenCount then Continue;
      if not SeedsComparable(BaseSeed, Seed, ADocuments) then Continue;
      if MatchesEveryOccurrence(ADocuments, Occurrences, Occurrence,
        Candidate.TokenCount, AMatcher) then
        AddInternalOccurrence(Occurrences, Seed.DocumentIndex,
          Seed.RegionIndex, Seed.StartToken);
    end;
    MarkOccupied(Occupancy, Occurrences, Candidate.TokenCount);
    AddReportGroup(AReport, ADocuments, Occurrences,
      Candidate.TokenCount);
  end;
end;

procedure AddDiagnostic(var AValues: TStringArray; const AValue: string);
var
  Count: Integer;
begin
  Count := Length(AValues);
  SetLength(AValues, Count + 1);
  AValues[Count] := AValue;
end;

function PercentHundredths(const ADuplicateTokens,
  ATotalTokens: Int64): Int64;
begin
  if ATotalTokens = 0 then Exit(0);
  Result := (ADuplicateTokens * 10000) div ATotalTokens;
end;

function FormatPercent(const ADuplicateTokens, ATotalTokens: Int64): string;
var
  Hundredths: Int64;
  Fraction: string;
begin
  Hundredths := PercentHundredths(ADuplicateTokens, ATotalTokens);
  Fraction := IntToStr(Hundredths mod 100);
  if Length(Fraction) = 1 then Fraction := '0' + Fraction;
  Result := IntToStr(Hundredths div 100) + '.' + Fraction;
end;

procedure ComputeProjectSummaries(const AScope: TLWPTAnalysisScope;
  const ADocuments: TAnalyzedDocumentArray;
  var AReport: TLWPTDuplicationReport);
var
  DocumentIndex, GroupIndex, OccurrenceIndex, ProjectIndex: Integer;
  ProjectOccurrenceCounts: TIntegerArray;
begin
  SetLength(AReport.Projects, Length(AScope.Projects));
  SetLength(ProjectOccurrenceCounts, Length(AScope.Projects));
  for ProjectIndex := 0 to High(AScope.Projects) do
    AReport.Projects[ProjectIndex].ProjectName :=
      AScope.Projects[ProjectIndex].Name;
  for DocumentIndex := 0 to High(ADocuments) do
    for GroupIndex := 0 to High(ADocuments[DocumentIndex].Document.Regions) do
      Inc(AReport.Projects[ADocuments[DocumentIndex].ProjectIndex].TotalTokens,
        ADocuments[DocumentIndex].Document.Regions[GroupIndex].Tokens.EndToken
        - ADocuments[DocumentIndex].Document.Regions[GroupIndex].Tokens.StartToken);
  for GroupIndex := 0 to High(AReport.Groups) do
  begin
    FillChar(ProjectOccurrenceCounts[0], Length(ProjectOccurrenceCounts)
      * SizeOf(ProjectOccurrenceCounts[0]), 0);
    for OccurrenceIndex := 0 to High(AReport.Groups[GroupIndex].Occurrences) do
    begin
      DocumentIndex := AReport.Groups[GroupIndex].Occurrences[
        OccurrenceIndex].DocumentIndex;
      Inc(ProjectOccurrenceCounts[ADocuments[DocumentIndex].ProjectIndex]);
    end;
    for ProjectIndex := 0 to High(AReport.Projects) do
      if ProjectOccurrenceCounts[ProjectIndex] > 1 then
        Inc(AReport.Projects[ProjectIndex].DuplicateTokens,
          Int64(AReport.Groups[GroupIndex].TokenCount)
          * (ProjectOccurrenceCounts[ProjectIndex] - 1));
  end;
end;

procedure EvaluateThresholds(var AReport: TLWPTDuplicationReport);
var
  ConfigurationIndex: Integer;
  DuplicateTokens, TotalTokens: Int64;
begin
  for ConfigurationIndex := 0 to High(AReport.Configurations) do
  begin
    if not AReport.Configurations[ConfigurationIndex].
      MaximumPercentConfigured then Continue;
    AReport.ThresholdConfigured := True;
    if ConfigurationIndex = 0 then
    begin
      DuplicateTokens := AReport.DuplicateTokens;
      TotalTokens := AReport.TotalTokens;
    end
    else
    begin
      DuplicateTokens := AReport.Projects[
        ConfigurationIndex].DuplicateTokens;
      TotalTokens := AReport.Projects[ConfigurationIndex].TotalTokens;
    end;
    if (TotalTokens > 0) and (DuplicateTokens * 100 >
      Int64(AReport.Configurations[ConfigurationIndex].MaximumPercent)
      * TotalTokens) then
    begin
      AReport.ThresholdFailed := True;
      AddDiagnostic(AReport.Diagnostics, Format('project "%s" duplication '
        + '%s%% exceeds configured maximum %d%%', [AReport.Configurations[
          ConfigurationIndex].ProjectName, FormatPercent(DuplicateTokens,
          TotalTokens), AReport.Configurations[
          ConfigurationIndex].MaximumPercent]));
    end;
  end;
end;

function AnalyzeDuplication(const AScope: TLWPTAnalysisScope):
  TLWPTDuplicationReport;
var
  Candidates: TCandidateArray;
  Documents: TAnalyzedDocumentArray;
  FileIndex, GlobalMinimum, ProjectIndex, RegionIndex, TokenIDCount: Integer;
  Matcher: TParameterizedMatcher;
  Seeds: TSeedArray;
begin
  Result := Default(TLWPTDuplicationReport);
  Result.Configurations := LoadConfigurations(AScope);
  GlobalMinimum := High(Integer);
  for ProjectIndex := 0 to High(Result.Configurations) do
    if Result.Configurations[ProjectIndex].MinimumTokens < GlobalMinimum then
      GlobalMinimum := Result.Configurations[ProjectIndex].MinimumTokens;
  if GlobalMinimum = High(Integer) then
    GlobalMinimum := DUPLICATION_DEFAULT_MINIMUM_TOKENS;
  SetLength(Documents, Length(AScope.Files));
  for FileIndex := 0 to High(AScope.Files) do
  begin
    Documents[FileIndex].ProjectIndex := FindProjectIndex(AScope,
      AScope.Files[FileIndex].ProjectName);
    Documents[FileIndex].RootRelativePath :=
      AScope.Files[FileIndex].RootRelativePath;
    Documents[FileIndex].Document := AnalyzePascal(ReadSourceText(
      AScope.Files[FileIndex].AbsolutePath),
      AScope.Files[FileIndex].RootRelativePath);
    for RegionIndex := 0 to High(Documents[FileIndex].Document.Regions) do
      Inc(Result.TotalTokens, Documents[FileIndex].Document.Regions[
        RegionIndex].Tokens.EndToken - Documents[FileIndex].Document.Regions[
          RegionIndex].Tokens.StartToken);
  end;
  BuildCanonicalTokenData(Documents, TokenIDCount);
  InitializeMatcher(Matcher, TokenIDCount);
  BuildSeeds(Documents, GlobalMinimum, Seeds);
  BuildCandidates(Documents, Result.Configurations, Seeds, Matcher,
    Candidates);
  SelectGroups(Documents, Result.Configurations, Seeds, Candidates, Matcher,
    Result);
  ComputeProjectSummaries(AScope, Documents, Result);
  EvaluateThresholds(Result);
end;

function DuplicationReportHuman(const AReport: TLWPTDuplicationReport):
  string;
var
  ConfigurationIndex, GroupIndex, OccurrenceIndex: Integer;
  Occurrence: TLWPTCloneOccurrence;
begin
  Result := Format('Duplication: %d duplicate tokens of %d (%s%%) in %d '
    + 'clone groups'#10, [AReport.DuplicateTokens, AReport.TotalTokens,
    FormatPercent(AReport.DuplicateTokens, AReport.TotalTokens),
    Length(AReport.Groups)]);
  for ConfigurationIndex := 0 to High(AReport.Configurations) do
  begin
    Result := Result + Format('Policy %s: minimum %d tokens',
      [AReport.Configurations[ConfigurationIndex].ProjectName,
      AReport.Configurations[ConfigurationIndex].MinimumTokens]);
    if AReport.Configurations[ConfigurationIndex].
      MaximumPercentConfigured then
      Result := Result + Format(', maximum %d%%', [AReport.Configurations[
        ConfigurationIndex].MaximumPercent]);
    Result := Result + #10;
  end;
  for GroupIndex := 0 to High(AReport.Groups) do
  begin
    Result := Result + Format('Clone %d: %d tokens, %d occurrences'#10,
      [GroupIndex + 1, AReport.Groups[GroupIndex].TokenCount,
      Length(AReport.Groups[GroupIndex].Occurrences)]);
    for OccurrenceIndex := 0 to
      High(AReport.Groups[GroupIndex].Occurrences) do
    begin
      Occurrence := AReport.Groups[GroupIndex].Occurrences[OccurrenceIndex];
      Result := Result + Format('  %s:%d:%d-%d:%d [%s]'#10,
        [Occurrence.FileName, Occurrence.StartLine,
        Occurrence.StartColumn, Occurrence.EndLine, Occurrence.EndColumn,
        Occurrence.RegionKind]);
    end;
  end;
  for GroupIndex := 0 to High(AReport.Diagnostics) do
    Result := Result + 'Threshold: ' + AReport.Diagnostics[GroupIndex] + #10;
end;

function DuplicationReportJSON(const AReport: TLWPTDuplicationReport):
  string;
var
  GroupIndex, OccurrenceIndex, ProjectIndex: Integer;
  Occurrence: TLWPTCloneOccurrence;
begin
  Result := '{"minimumTokenFloor":'
    + IntToStr(DUPLICATION_MINIMUM_TOKEN_FLOOR)
    + ',"totalTokens":' + IntToStr(AReport.TotalTokens)
    + ',"duplicateTokens":' + IntToStr(AReport.DuplicateTokens)
    + ',"duplicationPercent":'
    + FormatPercent(AReport.DuplicateTokens, AReport.TotalTokens)
    + ',"projects":[';
  for ProjectIndex := 0 to High(AReport.Projects) do
  begin
    if ProjectIndex > 0 then Result := Result + ',';
    Result := Result + '{"name":'
      + JSONString(AReport.Projects[ProjectIndex].ProjectName)
      + ',"minimumTokens":'
      + IntToStr(AReport.Configurations[ProjectIndex].MinimumTokens)
      + ',"maximumPercent":';
    if AReport.Configurations[ProjectIndex].MaximumPercentConfigured then
      Result := Result + IntToStr(AReport.Configurations[
        ProjectIndex].MaximumPercent)
    else
      Result := Result + 'null';
    Result := Result + ',"totalTokens":'
      + IntToStr(AReport.Projects[ProjectIndex].TotalTokens)
      + ',"duplicateTokens":'
      + IntToStr(AReport.Projects[ProjectIndex].DuplicateTokens) + '}';
  end;
  Result := Result + '],"groups":[';
  for GroupIndex := 0 to High(AReport.Groups) do
  begin
    if GroupIndex > 0 then Result := Result + ',';
    Result := Result + '{"tokens":'
      + IntToStr(AReport.Groups[GroupIndex].TokenCount)
      + ',"occurrences":[';
    for OccurrenceIndex := 0 to
      High(AReport.Groups[GroupIndex].Occurrences) do
    begin
      if OccurrenceIndex > 0 then Result := Result + ',';
      Occurrence := AReport.Groups[GroupIndex].Occurrences[OccurrenceIndex];
      Result := Result + '{"file":' + JSONString(Occurrence.FileName)
        + ',"region":' + JSONString(Occurrence.RegionKind)
        + ',"start":{"line":' + IntToStr(Occurrence.StartLine)
        + ',"column":' + IntToStr(Occurrence.StartColumn)
        + '},"end":{"line":' + IntToStr(Occurrence.EndLine)
        + ',"column":' + IntToStr(Occurrence.EndColumn) + '}}';
    end;
    Result := Result + ']}';
  end;
  Result := Result + ']}';
end;

end.
