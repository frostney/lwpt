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
  TAnalyzedDocument = record
    ProjectIndex: Integer;
    RootRelativePath: string;
    Document: TLWPTPascalDocument;
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
  TIntegerArray = array of Integer;
  TDocumentOccupancy = array of TBooleanArray;
  TTokenMapping = record
    LeftValue: string;
    RightValue: string;
  end;
  TTokenMappingArray = array of TTokenMapping;

function ReadSourceText(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
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

{$PUSH}{$Q-}{$R-}
procedure HashByte(var AHash: QWord; const AValue: Byte); inline;
begin
  AHash := (AHash xor AValue) * QWord(1099511628211);
end;

procedure HashInteger(var AHash: QWord; const AValue: Integer);
var
  Shift: Integer;
begin
  for Shift := 0 to 3 do
    HashByte(AHash, Byte((Cardinal(AValue) shr (Shift * 8)) and $ff));
end;

procedure HashText(var AHash: QWord; const AValue: string);
var
  CharacterIndex: Integer;
begin
  HashInteger(AHash, Length(AValue));
  for CharacterIndex := 1 to Length(AValue) do
    HashByte(AHash, Byte(AValue[CharacterIndex]));
end;
{$POP}

function ParameterizedToken(const AKind: TLWPTPascalTokenKind): Boolean;
begin
  Result := AKind in [ptIdentifier, ptNumber, ptString];
end;

function WindowHash(const ADocument: TLWPTPascalDocument;
  const AStartToken, ATokenCount: Integer): QWord;
var
  CanonicalValues: TStringList;
  CanonicalIndex, TokenIndex: Integer;
  Token: TLWPTPascalToken;
begin
  Result := QWord(14695981039346656037);
  CanonicalValues := TStringList.Create;
  try
    CanonicalValues.CaseSensitive := True;
    for TokenIndex := AStartToken to AStartToken + ATokenCount - 1 do
    begin
      Token := ADocument.Tokens[TokenIndex];
      HashInteger(Result, Ord(Token.Kind));
      if ParameterizedToken(Token.Kind) then
      begin
        CanonicalIndex := CanonicalValues.IndexOf(
          IntToStr(Ord(Token.Kind)) + ':' + Token.Text);
        if CanonicalIndex < 0 then
        begin
          CanonicalIndex := CanonicalValues.Count;
          CanonicalValues.Add(IntToStr(Ord(Token.Kind)) + ':' + Token.Text);
        end;
        HashInteger(Result, CanonicalIndex);
      end
      else
        HashText(Result, Token.Text);
    end;
  finally
    CanonicalValues.Free;
  end;
end;

function ParameterizedMatchLength(const ALeftDocument,
  ARightDocument: TLWPTPascalDocument; const ALeftStart, ALeftLimit,
  ARightStart, ARightLimit: Integer): Integer;
var
  FoundMapping: Boolean;
  Mapping: TTokenMappingArray;
  MappingCount, MappingIndex: Integer;
  LeftKey, RightKey: string;
  LeftToken, RightToken: TLWPTPascalToken;
begin
  Result := 0;
  SetLength(Mapping, 0);
  while (ALeftStart + Result < ALeftLimit)
    and (ARightStart + Result < ARightLimit) do
  begin
    LeftToken := ALeftDocument.Tokens[ALeftStart + Result];
    RightToken := ARightDocument.Tokens[ARightStart + Result];
    if LeftToken.Kind <> RightToken.Kind then Exit;
    if not ParameterizedToken(LeftToken.Kind) then
    begin
      if LeftToken.Text <> RightToken.Text then Exit;
      Inc(Result);
      Continue;
    end;
    LeftKey := IntToStr(Ord(LeftToken.Kind)) + ':' + LeftToken.Text;
    RightKey := IntToStr(Ord(RightToken.Kind)) + ':' + RightToken.Text;
    FoundMapping := False;
    for MappingIndex := 0 to High(Mapping) do
    begin
      if (Mapping[MappingIndex].LeftValue = LeftKey)
        and (Mapping[MappingIndex].RightValue <> RightKey) then Exit;
      if (Mapping[MappingIndex].RightValue = RightKey)
        and (Mapping[MappingIndex].LeftValue <> LeftKey) then Exit;
      if Mapping[MappingIndex].LeftValue = LeftKey then
      begin
        Inc(Result);
        FoundMapping := True;
        Break;
      end;
    end;
    if not FoundMapping then
    begin
      MappingCount := Length(Mapping);
      SetLength(Mapping, MappingCount + 1);
      Mapping[MappingCount].LeftValue := LeftKey;
      Mapping[MappingCount].RightValue := RightKey;
      Inc(Result);
    end;
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
  Region: TLWPTPascalRegion;
begin
  SetLength(ASeeds, 0);
  for DocumentIndex := 0 to High(ADocuments) do
    for RegionIndex := 0 to High(ADocuments[DocumentIndex].Document.Regions) do
    begin
      Region := ADocuments[DocumentIndex].Document.Regions[RegionIndex];
      for StartToken := Region.Tokens.StartToken to
        Region.Tokens.EndToken - AMinimumTokens do
        AddSeed(ASeeds, WindowHash(ADocuments[DocumentIndex].Document,
          StartToken, AMinimumTokens), DocumentIndex, RegionIndex,
          StartToken);
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
  LeftCanonical, RightCanonical: TStringList;
  LeftIndex, LeftLimit, LeftValue, RightIndex, RightLimit,
    RightValue: Integer;
  LeftKey, RightKey: string;
  LeftToken, RightToken: TLWPTPascalToken;
begin
  LeftIndex := ALeft.StartToken;
  RightIndex := ARight.StartToken;
  LeftLimit := ADocuments[ALeft.DocumentIndex].Document.Regions[
    ALeft.RegionIndex].Tokens.EndToken;
  RightLimit := ADocuments[ARight.DocumentIndex].Document.Regions[
    ARight.RegionIndex].Tokens.EndToken;
  LeftCanonical := TStringList.Create;
  RightCanonical := TStringList.Create;
  try
    LeftCanonical.CaseSensitive := True;
    RightCanonical.CaseSensitive := True;
    while (LeftIndex < LeftLimit) and (RightIndex < RightLimit) do
    begin
      LeftToken := ADocuments[ALeft.DocumentIndex].Document.Tokens[LeftIndex];
      RightToken := ADocuments[ARight.DocumentIndex].Document.Tokens[
        RightIndex];
      if Ord(LeftToken.Kind) < Ord(RightToken.Kind) then Exit(-1);
      if Ord(LeftToken.Kind) > Ord(RightToken.Kind) then Exit(1);
      if ParameterizedToken(LeftToken.Kind) then
      begin
        LeftKey := IntToStr(Ord(LeftToken.Kind)) + ':' + LeftToken.Text;
        RightKey := IntToStr(Ord(RightToken.Kind)) + ':' + RightToken.Text;
        LeftValue := LeftCanonical.IndexOf(LeftKey);
        if LeftValue < 0 then
        begin
          LeftValue := LeftCanonical.Count;
          LeftCanonical.Add(LeftKey);
        end;
        RightValue := RightCanonical.IndexOf(RightKey);
        if RightValue < 0 then
        begin
          RightValue := RightCanonical.Count;
          RightCanonical.Add(RightKey);
        end;
        if LeftValue < RightValue then Exit(-1);
        if LeftValue > RightValue then Exit(1);
      end
      else
      begin
        Result := CompareStr(LeftToken.Text, RightToken.Text);
        if Result <> 0 then Exit;
      end;
      Inc(LeftIndex);
      Inc(RightIndex);
    end;
    if LeftIndex < LeftLimit then Exit(1);
    if RightIndex < RightLimit then Exit(-1);
    Result := CompareOccurrence(ALeft.DocumentIndex, ALeft.RegionIndex,
      ALeft.StartToken, ARight.DocumentIndex, ARight.RegionIndex,
      ARight.StartToken);
  finally
    LeftCanonical.Free;
    RightCanonical.Free;
  end;
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
  var ACandidates: TCandidateArray);
var
  Bucket: TSeedArray;
  AdjacentLCP, EarliestSeed, LatestSeed: TIntegerArray;
  BestDistance, BestDocument, BucketCount, CandidateLength, DocumentIndex,
    GroupEnd, GroupStart, LCPIndex, MatchLength, MinimumIndex,
    RequiredMinimum, SeedIndex: Integer;
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
      ADocuments[Bucket[SeedIndex].DocumentIndex].Document,
      ADocuments[Bucket[SeedIndex + 1].DocumentIndex].Document,
      Bucket[SeedIndex].StartToken, LeftRegion.Tokens.EndToken,
      Bucket[SeedIndex + 1].StartToken, RightRegion.Tokens.EndToken);
  end;

  SetLength(EarliestSeed, Length(ADocuments));
  SetLength(LatestSeed, Length(ADocuments));
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

    for DocumentIndex := 0 to High(ADocuments) do
    begin
      EarliestSeed[DocumentIndex] := -1;
      LatestSeed[DocumentIndex] := -1;
    end;
    for SeedIndex := GroupStart to GroupEnd + 1 do
    begin
      DocumentIndex := Bucket[SeedIndex].DocumentIndex;
      RequiredMinimum := AConfigurations[ADocuments[DocumentIndex].
        ProjectIndex].MinimumTokens;
      if RequiredMinimum > MatchLength then Continue;
      if (EarliestSeed[DocumentIndex] < 0) or
        (Bucket[SeedIndex].StartToken < Bucket[
          EarliestSeed[DocumentIndex]].StartToken) then
        EarliestSeed[DocumentIndex] := SeedIndex;
      if (LatestSeed[DocumentIndex] < 0) or
        (Bucket[SeedIndex].StartToken > Bucket[
          LatestSeed[DocumentIndex]].StartToken) then
        LatestSeed[DocumentIndex] := SeedIndex;
    end;

    { Different documents never overlap, so the interval LCP is optimal. }
    MinimumIndex := -1;
    SeedIndex := -1;
    for DocumentIndex := 0 to High(ADocuments) do
      if EarliestSeed[DocumentIndex] >= 0 then
      begin
        if MinimumIndex < 0 then
          MinimumIndex := EarliestSeed[DocumentIndex]
        else
        begin
          SeedIndex := EarliestSeed[DocumentIndex];
          Break;
        end;
      end;
    if SeedIndex >= 0 then
    begin
      AddCandidate(ACandidates, Bucket[MinimumIndex], Bucket[SeedIndex],
        MatchLength);
      Continue;
    end;

    { A same-document pair is capped by its coordinate distance. Across an
      LCP interval the extreme starts maximize min(LCP, distance). }
    BestDistance := -1;
    BestDocument := -1;
    for DocumentIndex := 0 to High(ADocuments) do
      if (EarliestSeed[DocumentIndex] >= 0)
        and (LatestSeed[DocumentIndex] >= 0)
        and (EarliestSeed[DocumentIndex] <> LatestSeed[DocumentIndex])
        and (Bucket[LatestSeed[DocumentIndex]].StartToken
          - Bucket[EarliestSeed[DocumentIndex]].StartToken >
          BestDistance) then
      begin
        BestDistance := Bucket[LatestSeed[DocumentIndex]].StartToken
          - Bucket[EarliestSeed[DocumentIndex]].StartToken;
        BestDocument := DocumentIndex;
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
  const ASeeds: TSeedArray; var ACandidates: TCandidateArray);
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
      ACandidates);
    BuildCandidateBucket(ADocuments, AConfigurations, SeedGroup, True,
      ACandidates);
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

procedure SelectGroups(const ADocuments: TAnalyzedDocumentArray;
  const AConfigurations: TLWPTDuplicationConfigurationArray;
  const ASeeds: TSeedArray; var ACandidates: TCandidateArray;
  var AReport: TLWPTDuplicationReport);
var
  BaseSeed, Seed: TSeed;
  CandidateIndex, DocumentIndex, MatchLength, SeedIndex: Integer;
  Candidate: TCandidate;
  Occurrence, RightOccurrence: TInternalOccurrence;
  Occurrences: TInternalOccurrenceArray;
  Occupancy: TDocumentOccupancy;
  BaseRegion, SeedRegion: TLWPTPascalRegion;
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
    AddInternalOccurrence(Occurrences, RightOccurrence.DocumentIndex,
      RightOccurrence.RegionIndex, RightOccurrence.StartToken);

    BaseSeed.Hash := Candidate.Hash;
    BaseSeed.DocumentIndex := Candidate.LeftDocument;
    BaseSeed.RegionIndex := Candidate.LeftRegion;
    BaseSeed.StartToken := Candidate.LeftStart;
    BaseRegion := ADocuments[BaseSeed.DocumentIndex].Document.Regions[
      BaseSeed.RegionIndex];
    for SeedIndex := 0 to High(ASeeds) do
    begin
      Seed := ASeeds[SeedIndex];
      if Seed.Hash <> Candidate.Hash then Continue;
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
      MatchLength := ParameterizedMatchLength(
        ADocuments[BaseSeed.DocumentIndex].Document,
        ADocuments[Seed.DocumentIndex].Document, BaseSeed.StartToken,
        BaseRegion.Tokens.EndToken, Seed.StartToken,
        SeedRegion.Tokens.EndToken);
      if MatchLength >= Candidate.TokenCount then
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
  DocumentIndex, GroupIndex, OccurrenceIndex, ProjectIndex,
    ProjectOccurrenceCount: Integer;
begin
  SetLength(AReport.Projects, Length(AScope.Projects));
  for ProjectIndex := 0 to High(AScope.Projects) do
    AReport.Projects[ProjectIndex].ProjectName :=
      AScope.Projects[ProjectIndex].Name;
  for DocumentIndex := 0 to High(ADocuments) do
    for GroupIndex := 0 to High(ADocuments[DocumentIndex].Document.Regions) do
      Inc(AReport.Projects[ADocuments[DocumentIndex].ProjectIndex].TotalTokens,
        ADocuments[DocumentIndex].Document.Regions[GroupIndex].Tokens.EndToken
        - ADocuments[DocumentIndex].Document.Regions[GroupIndex].Tokens.StartToken);
  for GroupIndex := 0 to High(AReport.Groups) do
    for ProjectIndex := 0 to High(AReport.Projects) do
    begin
      { Count by resolving the stable report path back through the analyzed
        document list. The path is unique in the resolved scope. }
      ProjectOccurrenceCount := 0;
      for OccurrenceIndex := 0 to
        High(AReport.Groups[GroupIndex].Occurrences) do
        for DocumentIndex := 0 to High(ADocuments) do
          if (ADocuments[DocumentIndex].RootRelativePath =
            AReport.Groups[GroupIndex].Occurrences[
              OccurrenceIndex].FileName)
            and (ADocuments[DocumentIndex].ProjectIndex = ProjectIndex) then
          begin
            Inc(ProjectOccurrenceCount);
            Break;
          end;
      if ProjectOccurrenceCount > 1 then
        Inc(AReport.Projects[ProjectIndex].DuplicateTokens,
          Int64(AReport.Groups[GroupIndex].TokenCount)
          * (ProjectOccurrenceCount - 1));
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
  FileIndex, GlobalMinimum, ProjectIndex, RegionIndex: Integer;
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
  BuildSeeds(Documents, GlobalMinimum, Seeds);
  BuildCandidates(Documents, Result.Configurations, Seeds, Candidates);
  SelectGroups(Documents, Result.Configurations, Seeds, Candidates, Result);
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
