{ LWPT.Health — deterministic Pascal complexity and hotspot metrics. }
unit LWPT.Health;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.Analysis.Pascal,
  LWPT.Core;

const
  HEALTH_COMMAND_SCHEMA_VERSION = 1;
  HEALTH_GIT_HISTORY_COMMITS = 100;

type
  TLWPTHealthRegionKind = (hrRoutine, hrProgram, hrInitialization,
    hrFinalization);

  TLWPTHealthMetric = record
    Name: string;
    Kind: TLWPTHealthRegionKind;
    Line: Integer;
    Column: Integer;
    Cyclomatic: Integer;
    Cognitive: Integer;
  end;
  TLWPTHealthMetricArray = array of TLWPTHealthMetric;

  TLWPTHealthFile = record
    ProjectName: string;
    Path: string;
    Metrics: TLWPTHealthMetricArray;
    Cyclomatic: Integer;
    Cognitive: Integer;
    ChangedLines: Int64;
    HotspotScore: Double;
  end;
  TLWPTHealthFileArray = array of TLWPTHealthFile;

  TLWPTHealthLimits = record
    MaxRoutineCyclomatic: Integer;
    MaxRoutineCognitive: Integer;
    MaxFileCyclomatic: Integer;
    MaxFileCognitive: Integer;
    MaxHotspotScore: Integer;
  end;

  TLWPTHealthViolation = record
    ProjectName: string;
    Path: string;
    RegionName: string;
    LimitName: string;
    Observed: Double;
    Limit: Double;
  end;
  TLWPTHealthViolationArray = array of TLWPTHealthViolation;

function DefaultHealthLimits: TLWPTHealthLimits;
function AnalyzeHealthDocument(const ADocument: TLWPTPascalDocument;
  const AProjectName, APath: string): TLWPTHealthFile;
procedure NormalizeHotspots(var AFiles: TLWPTHealthFileArray);
procedure CollectHealthViolations(const AFile: TLWPTHealthFile;
  const ALimits: TLWPTHealthLimits;
  var AViolations: TLWPTHealthViolationArray);

implementation

uses
  SysUtils;

type
  TLWPTHealthStatementParser = class
  private
    FDocument: TLWPTPascalDocument;
    FEndToken: Integer;
    FIndex: Integer;
    FMetric: TLWPTHealthMetric;
    FRoutineSimpleName: string;
    FRecursionFound: Boolean;
    function AtToken(const AText: string): Boolean;
    function AtAny(const AValues: array of string): Boolean;
    procedure AdvanceTo(const AStop: string);
    procedure CountCondition(const AStop: string);
    procedure CountDirectRecursion(const AStart, AEnd: Integer);
    procedure ParseBegin(const ANesting: Integer);
    procedure ParseCase(const ANesting: Integer);
    procedure ParseIf(const ANesting: Integer);
    procedure ParseLoop(const ANesting: Integer);
    procedure ParseRepeat(const ANesting: Integer);
    procedure ParseSequence(const AStops: array of string;
      const ANesting: Integer);
    procedure ParseSimple;
    procedure ParseStatement(const ANesting: Integer);
    procedure ParseTry(const ANesting: Integer);
    procedure ScoreStructure(const ANesting: Integer);
  public
    constructor Create(const ADocument: TLWPTPascalDocument;
      const ARegion: TLWPTPascalRegion; const AName: string;
      const AKind: TLWPTHealthRegionKind);
    function Analyze: TLWPTHealthMetric;
  end;

function DefaultHealthLimits: TLWPTHealthLimits;
begin
  Result := Default(TLWPTHealthLimits);
  Result.MaxRoutineCyclomatic := -1;
  Result.MaxRoutineCognitive := -1;
  Result.MaxFileCyclomatic := -1;
  Result.MaxFileCognitive := -1;
  Result.MaxHotspotScore := -1;
end;

constructor TLWPTHealthStatementParser.Create(
  const ADocument: TLWPTPascalDocument; const ARegion: TLWPTPascalRegion;
  const AName: string; const AKind: TLWPTHealthRegionKind);
var
  DotAt: Integer;
begin
  inherited Create;
  FDocument := ADocument;
  FIndex := ARegion.Tokens.StartToken;
  FEndToken := ARegion.Tokens.EndToken;
  FMetric := Default(TLWPTHealthMetric);
  FMetric.Name := AName;
  FMetric.Kind := AKind;
  FMetric.Cyclomatic := 1;
  if FIndex < Length(FDocument.Tokens) then
  begin
    FMetric.Line := FDocument.Tokens[FIndex].Line;
    FMetric.Column := FDocument.Tokens[FIndex].Column;
  end;
  FRoutineSimpleName := LowerCase(AName);
  DotAt := LastDelimiter('.', FRoutineSimpleName);
  if DotAt > 0 then
    FRoutineSimpleName := Copy(FRoutineSimpleName, DotAt + 1, MaxInt);
  FRecursionFound := False;
end;

function TLWPTHealthStatementParser.AtToken(const AText: string): Boolean;
begin
  Result := (FIndex < FEndToken)
    and (FDocument.Tokens[FIndex].Text = AText);
end;

function TLWPTHealthStatementParser.AtAny(
  const AValues: array of string): Boolean;
var
  ValueIndex: Integer;
begin
  for ValueIndex := Low(AValues) to High(AValues) do
    if AtToken(AValues[ValueIndex]) then Exit(True);
  Result := False;
end;

procedure TLWPTHealthStatementParser.ScoreStructure(const ANesting: Integer);
begin
  Inc(FMetric.Cyclomatic);
  Inc(FMetric.Cognitive, 1 + ANesting);
end;

procedure TLWPTHealthStatementParser.CountDirectRecursion(
  const AStart, AEnd: Integer);
var
  IsAddress, IsCall, IsSelfQualified: Boolean;
  TokenIndex: Integer;
begin
  if FRecursionFound or (FRoutineSimpleName = '')
    or (FRoutineSimpleName[1] = '<') then Exit;
  for TokenIndex := AStart to AEnd - 1 do
    if FDocument.Tokens[TokenIndex].Text = FRoutineSimpleName then
    begin
      IsSelfQualified := (TokenIndex >= AStart + 2)
        and (FDocument.Tokens[TokenIndex - 1].Text = '.')
        and (FDocument.Tokens[TokenIndex - 2].Text = 'self');
      IsAddress := ((TokenIndex > AStart)
          and (FDocument.Tokens[TokenIndex - 1].Text = '@'))
        or (IsSelfQualified and (TokenIndex >= AStart + 3)
          and (FDocument.Tokens[TokenIndex - 3].Text = '@'));
      IsCall := ((TokenIndex + 1 >= AEnd)
          or (FDocument.Tokens[TokenIndex + 1].Text = '('))
        and ((TokenIndex = AStart)
          or (FDocument.Tokens[TokenIndex - 1].Text <> 'inherited'))
        and not IsAddress
        and ((TokenIndex = AStart)
          or (FDocument.Tokens[TokenIndex - 1].Text <> '.')
          or IsSelfQualified);
      if IsCall then
      begin
        Inc(FMetric.Cognitive);
        FRecursionFound := True;
        Exit;
      end;
    end;
end;

procedure TLWPTHealthStatementParser.CountCondition(const AStop: string);
var
  Depth, StartIndex: Integer;
  CurrentBoolean, PreviousBoolean: string;
begin
  Depth := 0;
  PreviousBoolean := '';
  StartIndex := FIndex;
  while FIndex < FEndToken do
  begin
    if (Depth = 0) and AtToken(AStop)
      and not ((AStop = 'then') and (FIndex > StartIndex)
        and (FDocument.Tokens[FIndex - 1].Text = 'and')) then Break;
    if AtAny(['(', '[']) then Inc(Depth)
    else if AtAny([')', ']']) and (Depth > 0) then Dec(Depth);
    if AtAny(['and', 'or', 'xor']) then
    begin
      CurrentBoolean := FDocument.Tokens[FIndex].Text;
      Inc(FMetric.Cyclomatic);
      if (PreviousBoolean = '') or (PreviousBoolean <> CurrentBoolean) then
        Inc(FMetric.Cognitive);
      PreviousBoolean := CurrentBoolean;
    end;
    Inc(FIndex);
  end;
  CountDirectRecursion(StartIndex, FIndex);
end;

procedure TLWPTHealthStatementParser.AdvanceTo(const AStop: string);
var
  Depth, StartIndex: Integer;
begin
  Depth := 0;
  StartIndex := FIndex;
  while FIndex < FEndToken do
  begin
    if (Depth = 0) and AtToken(AStop) then Break;
    if AtAny(['(', '[']) then Inc(Depth)
    else if AtAny([')', ']']) and (Depth > 0) then Dec(Depth);
    Inc(FIndex);
  end;
  CountDirectRecursion(StartIndex, FIndex);
end;

procedure TLWPTHealthStatementParser.ParseBegin(const ANesting: Integer);
begin
  Inc(FIndex);
  ParseSequence(['end'], ANesting);
  if AtToken('end') then Inc(FIndex);
end;

procedure TLWPTHealthStatementParser.ParseIf(const ANesting: Integer);
begin
  ScoreStructure(ANesting);
  Inc(FIndex);
  CountCondition('then');
  if AtToken('then') then Inc(FIndex);
  ParseStatement(ANesting + 1);
  if AtToken(';') then Inc(FIndex);
  if AtToken('else') then
  begin
    Inc(FMetric.Cognitive);
    Inc(FIndex);
    ParseStatement(ANesting + 1);
  end;
end;

procedure TLWPTHealthStatementParser.ParseLoop(const ANesting: Integer);
var
  LoopKind: string;
begin
  LoopKind := FDocument.Tokens[FIndex].Text;
  ScoreStructure(ANesting);
  Inc(FIndex);
  if LoopKind = 'for' then AdvanceTo('do')
  else CountCondition('do');
  if AtToken('do') then Inc(FIndex);
  ParseStatement(ANesting + 1);
end;

procedure TLWPTHealthStatementParser.ParseRepeat(const ANesting: Integer);
begin
  ScoreStructure(ANesting);
  Inc(FIndex);
  ParseSequence(['until'], ANesting + 1);
  if AtToken('until') then Inc(FIndex);
  CountCondition(';');
end;

procedure TLWPTHealthStatementParser.ParseCase(const ANesting: Integer);
var
  ArmStart, Depth: Integer;
  IsDefault: Boolean;
begin
  Inc(FMetric.Cognitive, 1 + ANesting);
  Inc(FIndex);
  AdvanceTo('of');
  if AtToken('of') then Inc(FIndex);
  while (FIndex < FEndToken) and not AtToken('end') do
  begin
    if AtToken(';') then
    begin
      Inc(FIndex);
      Continue;
    end;
    IsDefault := AtToken('else');
    if IsDefault then
    begin
      Inc(FMetric.Cognitive);
      Inc(FIndex);
      ParseSequence(['end'], ANesting + 1);
      Break;
    end;
    ArmStart := FIndex;
    Depth := 0;
    while FIndex < FEndToken do
    begin
      if AtAny(['(', '[']) then Inc(Depth)
      else if AtAny([')', ']']) and (Depth > 0) then Dec(Depth)
      else if (Depth = 0) and AtToken(':') then Break
      else if (Depth = 0) and AtToken('end') then Break;
      Inc(FIndex);
    end;
    if AtToken(':') then
    begin
      Inc(FMetric.Cyclomatic);
      CountDirectRecursion(ArmStart, FIndex);
      Inc(FIndex);
      ParseStatement(ANesting + 1);
    end
    else
      Break;
    if AtToken(';') then Inc(FIndex);
  end;
  if AtToken('end') then Inc(FIndex);
end;

procedure TLWPTHealthStatementParser.ParseTry(const ANesting: Integer);
var
  HandlerCount, PreviousIndex: Integer;
begin
  Inc(FIndex);
  ParseSequence(['except', 'finally', 'end'], ANesting);
  if AtToken('finally') then
  begin
    Inc(FIndex);
    ParseSequence(['end'], ANesting);
  end
  else if AtToken('except') then
  begin
    Inc(FIndex);
    HandlerCount := 0;
    while (FIndex < FEndToken) and not AtToken('end') do
    begin
      if AtToken('on') then
      begin
        Inc(HandlerCount);
        ScoreStructure(ANesting);
        Inc(FIndex);
        AdvanceTo('do');
        if AtToken('do') then Inc(FIndex);
        ParseStatement(ANesting + 1);
      end
      else if AtToken('else') then
      begin
        Inc(HandlerCount);
        ScoreStructure(ANesting);
        Inc(FMetric.Cognitive);
        Inc(FIndex);
        ParseSequence(['end'], ANesting + 1);
      end
      else
      begin
        PreviousIndex := FIndex;
        ParseStatement(ANesting + 1);
        if FIndex = PreviousIndex then Inc(FIndex);
      end;
      if AtToken(';') then Inc(FIndex);
    end;
    if HandlerCount = 0 then ScoreStructure(ANesting);
  end;
  if AtToken('end') then Inc(FIndex);
end;

procedure TLWPTHealthStatementParser.ParseSimple;
var
  Depth, StartIndex: Integer;
begin
  Depth := 0;
  StartIndex := FIndex;
  while FIndex < FEndToken do
  begin
    if (Depth = 0) and AtAny([';', 'else', 'end', 'until', 'except',
      'finally']) then Break;
    if AtToken('goto') then Inc(FMetric.Cognitive);
    if AtAny(['(', '[']) then Inc(Depth)
    else if AtAny([')', ']']) and (Depth > 0) then Dec(Depth);
    Inc(FIndex);
  end;
  CountDirectRecursion(StartIndex, FIndex);
end;

procedure TLWPTHealthStatementParser.ParseStatement(const ANesting: Integer);
begin
  while (FIndex < FEndToken)
    and (AtToken(';')
      or (FDocument.Tokens[FIndex].Kind = ptDirective)) do
    Inc(FIndex);
  if FIndex >= FEndToken then Exit;
  if AtToken('begin') then ParseBegin(ANesting)
  else if AtToken('if') then ParseIf(ANesting)
  else if AtAny(['for', 'while']) then ParseLoop(ANesting)
  else if AtToken('repeat') then ParseRepeat(ANesting)
  else if AtToken('case') then ParseCase(ANesting)
  else if AtToken('try') then ParseTry(ANesting)
  else ParseSimple;
end;

procedure TLWPTHealthStatementParser.ParseSequence(
  const AStops: array of string; const ANesting: Integer);
var
  PreviousIndex: Integer;
begin
  while (FIndex < FEndToken) and not AtAny(AStops) do
  begin
    PreviousIndex := FIndex;
    ParseStatement(ANesting);
    if AtToken(';') then Inc(FIndex);
    if FIndex = PreviousIndex then Inc(FIndex);
  end;
end;

function TLWPTHealthStatementParser.Analyze: TLWPTHealthMetric;
begin
  ParseSequence([], 0);
  Result := FMetric;
end;

procedure AddMetric(var AFile: TLWPTHealthFile;
  const AMetric: TLWPTHealthMetric);
var
  MetricCount: Integer;
begin
  MetricCount := Length(AFile.Metrics);
  SetLength(AFile.Metrics, MetricCount + 1);
  AFile.Metrics[MetricCount] := AMetric;
  Inc(AFile.Cyclomatic, AMetric.Cyclomatic);
  Inc(AFile.Cognitive, AMetric.Cognitive);
end;

function AnalyzeRegion(const ADocument: TLWPTPascalDocument;
  const ARegion: TLWPTPascalRegion; const AName: string;
  const AKind: TLWPTHealthRegionKind): TLWPTHealthMetric;
var
  Parser: TLWPTHealthStatementParser;
begin
  Parser := TLWPTHealthStatementParser.Create(ADocument, ARegion, AName,
    AKind);
  try
    Result := Parser.Analyze;
  finally
    Parser.Free;
  end;
end;

function AnalyzeHealthDocument(const ADocument: TLWPTPascalDocument;
  const AProjectName, APath: string): TLWPTHealthFile;
var
  Metric: TLWPTHealthMetric;
  Region: TLWPTPascalRegion;
  RegionIndex, RoutineIndex: Integer;
begin
  Result := Default(TLWPTHealthFile);
  Result.ProjectName := AProjectName;
  Result.Path := APath;
  for RoutineIndex := 0 to High(ADocument.Routines) do
    if ADocument.Routines[RoutineIndex].BodyRegion >= 0 then
    begin
      Region := ADocument.Regions[
        ADocument.Routines[RoutineIndex].BodyRegion];
      Metric := AnalyzeRegion(ADocument, Region,
        ADocument.Routines[RoutineIndex].Name, hrRoutine);
      if ADocument.Routines[RoutineIndex].Header.StartToken
        < Length(ADocument.Tokens) then
      begin
        Metric.Line := ADocument.Tokens[ADocument.Routines[
          RoutineIndex].Header.StartToken].Line;
        Metric.Column := ADocument.Tokens[ADocument.Routines[
          RoutineIndex].Header.StartToken].Column;
      end;
      AddMetric(Result, Metric);
    end;
  for RegionIndex := 0 to High(ADocument.Regions) do
  begin
    Region := ADocument.Regions[RegionIndex];
    case Region.Kind of
      pgProgramBody:
        AddMetric(Result, AnalyzeRegion(ADocument, Region, '<program>',
          hrProgram));
      pgInitialization:
        AddMetric(Result, AnalyzeRegion(ADocument, Region,
          '<initialization>', hrInitialization));
      pgFinalization:
        AddMetric(Result, AnalyzeRegion(ADocument, Region, '<finalization>',
          hrFinalization));
    end;
  end;
end;

procedure NormalizeHotspots(var AFiles: TLWPTHealthFileArray);
var
  Complexity, MaxComplexity, MaxChurn: Int64;
  FileIndex: Integer;
begin
  MaxComplexity := 0;
  MaxChurn := 0;
  for FileIndex := 0 to High(AFiles) do
  begin
    Complexity := AFiles[FileIndex].Cyclomatic
      + AFiles[FileIndex].Cognitive;
    if Complexity > MaxComplexity then MaxComplexity := Complexity;
    if AFiles[FileIndex].ChangedLines > MaxChurn then
      MaxChurn := AFiles[FileIndex].ChangedLines;
  end;
  for FileIndex := 0 to High(AFiles) do
  begin
    if (MaxComplexity = 0) or (MaxChurn = 0) then
      AFiles[FileIndex].HotspotScore := 0
    else
      AFiles[FileIndex].HotspotScore := Round(100.0 * 10000
        * ((AFiles[FileIndex].Cyclomatic + AFiles[FileIndex].Cognitive)
          / MaxComplexity)
        * (AFiles[FileIndex].ChangedLines / MaxChurn)) / 10000.0;
  end;
end;

procedure AddViolation(var AViolations: TLWPTHealthViolationArray;
  const AFile: TLWPTHealthFile; const ARegionName, ALimitName: string;
  const AObserved, ALimit: Double);
var
  ViolationCount: Integer;
begin
  ViolationCount := Length(AViolations);
  SetLength(AViolations, ViolationCount + 1);
  AViolations[ViolationCount].ProjectName := AFile.ProjectName;
  AViolations[ViolationCount].Path := AFile.Path;
  AViolations[ViolationCount].RegionName := ARegionName;
  AViolations[ViolationCount].LimitName := ALimitName;
  AViolations[ViolationCount].Observed := AObserved;
  AViolations[ViolationCount].Limit := ALimit;
end;

procedure CollectHealthViolations(const AFile: TLWPTHealthFile;
  const ALimits: TLWPTHealthLimits;
  var AViolations: TLWPTHealthViolationArray);
var
  MetricIndex: Integer;
begin
  for MetricIndex := 0 to High(AFile.Metrics) do
  begin
    if (ALimits.MaxRoutineCyclomatic >= 0)
      and (AFile.Metrics[MetricIndex].Cyclomatic
        > ALimits.MaxRoutineCyclomatic) then
      AddViolation(AViolations, AFile, AFile.Metrics[MetricIndex].Name,
        'max-routine-cyclomatic', AFile.Metrics[MetricIndex].Cyclomatic,
        ALimits.MaxRoutineCyclomatic);
    if (ALimits.MaxRoutineCognitive >= 0)
      and (AFile.Metrics[MetricIndex].Cognitive
        > ALimits.MaxRoutineCognitive) then
      AddViolation(AViolations, AFile, AFile.Metrics[MetricIndex].Name,
        'max-routine-cognitive', AFile.Metrics[MetricIndex].Cognitive,
        ALimits.MaxRoutineCognitive);
  end;
  if (ALimits.MaxFileCyclomatic >= 0)
    and (AFile.Cyclomatic > ALimits.MaxFileCyclomatic) then
    AddViolation(AViolations, AFile, '', 'max-file-cyclomatic',
      AFile.Cyclomatic, ALimits.MaxFileCyclomatic);
  if (ALimits.MaxFileCognitive >= 0)
    and (AFile.Cognitive > ALimits.MaxFileCognitive) then
    AddViolation(AViolations, AFile, '', 'max-file-cognitive',
      AFile.Cognitive, ALimits.MaxFileCognitive);
  if (ALimits.MaxHotspotScore >= 0)
    and (Round(AFile.HotspotScore * 10000)
      > Int64(ALimits.MaxHotspotScore) * 10000) then
    AddViolation(AViolations, AFile, '', 'max-hotspot-score',
      Round(AFile.HotspotScore * 10000) / 10000.0,
      ALimits.MaxHotspotScore);
end;

end.
