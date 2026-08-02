{ LWPT.Analysis.JSON — deterministic shared analysis report envelope. }
unit LWPT.Analysis.JSON;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.Analysis.Scope,
  LWPT.Core;

const
  ANALYSIS_ENVELOPE_SCHEMA = PROGRAM_NAME + '.analysis';
  ANALYSIS_ENVELOPE_SCHEMA_VERSION = 1;

type
  TLWPTAnalysisThresholdOutcome = (atoNotConfigured, atoPassed, atoFailed);

  TLWPTAnalysisConfigurationValue = record
    ProjectName: string;
    Name: string;
    Value: string;
  end;
  TLWPTAnalysisConfigurationValueArray =
    array of TLWPTAnalysisConfigurationValue;

  TLWPTAnalysisMetadata = record
    CommandName: string;
    CommandSchemaVersion: Integer;
    ProjectName: string;
    ProjectVersion: string;
    Files: TStringArray;
    Configuration: TLWPTAnalysisConfigurationValueArray;
    ThresholdOutcome: TLWPTAnalysisThresholdOutcome;
    Diagnostics: TStringArray;
  end;

procedure AddAnalysisConfigurationValue(var AMetadata: TLWPTAnalysisMetadata;
  const AProjectName, AName, AValue: string);
procedure AddAnalysisDiagnostic(var AMetadata: TLWPTAnalysisMetadata;
  const AMessage: string);
function AnalysisMetadataFromScope(const ACommandName: string;
  const ACommandSchemaVersion: Integer; const AScope: TLWPTAnalysisScope):
  TLWPTAnalysisMetadata;
function JSONString(const AValue: string): string;
function SerializeAnalysisEnvelope(const AMetadata: TLWPTAnalysisMetadata;
  const APayloadJSON: string): string;

implementation

uses
  SysUtils;

procedure SortAndDeduplicate(var AValues: TStringArray);
var
  ItemIndex, OutputCount: Integer;
  Temporary: TStringArray;

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
      if AValues[LeftIndex] <= AValues[RightIndex] then
      begin
        Temporary[OutputIndex] := AValues[LeftIndex];
        Inc(LeftIndex);
      end
      else
      begin
        Temporary[OutputIndex] := AValues[RightIndex];
        Inc(RightIndex);
      end;
      Inc(OutputIndex);
    end;
    while LeftIndex <= MiddleIndex do
    begin
      Temporary[OutputIndex] := AValues[LeftIndex];
      Inc(LeftIndex);
      Inc(OutputIndex);
    end;
    while RightIndex <= AHigh do
    begin
      Temporary[OutputIndex] := AValues[RightIndex];
      Inc(RightIndex);
      Inc(OutputIndex);
    end;
    for OutputIndex := ALow to AHigh do
      AValues[OutputIndex] := Temporary[OutputIndex];
  end;

begin
  if Length(AValues) > 1 then
  begin
    SetLength(Temporary, Length(AValues));
    MergeSort(0, High(AValues));
  end;
  OutputCount := 0;
  for ItemIndex := 0 to High(AValues) do
  begin
    if (OutputCount > 0) and (AValues[ItemIndex] = AValues[OutputCount - 1])
      then Continue;
    AValues[OutputCount] := AValues[ItemIndex];
    Inc(OutputCount);
  end;
  SetLength(AValues, OutputCount);
end;

function CompareConfiguration(const ALeft,
  ARight: TLWPTAnalysisConfigurationValue): Integer;
begin
  if ALeft.ProjectName < ARight.ProjectName then Exit(-1);
  if ALeft.ProjectName > ARight.ProjectName then Exit(1);
  if ALeft.Name < ARight.Name then Exit(-1);
  if ALeft.Name > ARight.Name then Exit(1);
  if ALeft.Value < ARight.Value then Exit(-1);
  if ALeft.Value > ARight.Value then Exit(1);
  Result := 0;
end;

procedure SortAndDeduplicateConfiguration(
  var AValues: TLWPTAnalysisConfigurationValueArray);
var
  ItemIndex, OutputCount: Integer;
  Temporary: TLWPTAnalysisConfigurationValueArray;

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
      if CompareConfiguration(AValues[LeftIndex], AValues[RightIndex]) <= 0
        then
      begin
        Temporary[OutputIndex] := AValues[LeftIndex];
        Inc(LeftIndex);
      end
      else
      begin
        Temporary[OutputIndex] := AValues[RightIndex];
        Inc(RightIndex);
      end;
      Inc(OutputIndex);
    end;
    while LeftIndex <= MiddleIndex do
    begin
      Temporary[OutputIndex] := AValues[LeftIndex];
      Inc(LeftIndex);
      Inc(OutputIndex);
    end;
    while RightIndex <= AHigh do
    begin
      Temporary[OutputIndex] := AValues[RightIndex];
      Inc(RightIndex);
      Inc(OutputIndex);
    end;
    for OutputIndex := ALow to AHigh do
      AValues[OutputIndex] := Temporary[OutputIndex];
  end;

begin
  if Length(AValues) > 1 then
  begin
    SetLength(Temporary, Length(AValues));
    MergeSort(0, High(AValues));
  end;
  OutputCount := 0;
  for ItemIndex := 0 to High(AValues) do
  begin
    if (OutputCount > 0) and
       (CompareConfiguration(AValues[ItemIndex],
       AValues[OutputCount - 1]) = 0) then Continue;
    AValues[OutputCount] := AValues[ItemIndex];
    Inc(OutputCount);
  end;
  SetLength(AValues, OutputCount);
end;

procedure AddConfigurationValue(
  var AValues: TLWPTAnalysisConfigurationValueArray;
  const AProjectName, AName, AValue: string);
var
  ValueCount: Integer;
begin
  ValueCount := Length(AValues);
  SetLength(AValues, ValueCount + 1);
  AValues[ValueCount].ProjectName := AProjectName;
  AValues[ValueCount].Name := AName;
  AValues[ValueCount].Value := AValue;
end;

procedure AddAnalysisConfigurationValue(var AMetadata: TLWPTAnalysisMetadata;
  const AProjectName, AName, AValue: string);
begin
  AddConfigurationValue(AMetadata.Configuration, AProjectName, AName, AValue);
end;

procedure AddAnalysisDiagnostic(var AMetadata: TLWPTAnalysisMetadata;
  const AMessage: string);
var
  DiagnosticCount: Integer;
begin
  DiagnosticCount := Length(AMetadata.Diagnostics);
  SetLength(AMetadata.Diagnostics, DiagnosticCount + 1);
  AMetadata.Diagnostics[DiagnosticCount] := AMessage;
end;

function AnalysisMetadataFromScope(const ACommandName: string;
  const ACommandSchemaVersion: Integer; const AScope: TLWPTAnalysisScope):
  TLWPTAnalysisMetadata;
var
  FileIndex, PatternIndex, ProjectIndex: Integer;
begin
  Result := Default(TLWPTAnalysisMetadata);
  Result.CommandName := ACommandName;
  Result.CommandSchemaVersion := ACommandSchemaVersion;
  Result.ProjectName := AScope.ProjectName;
  Result.ProjectVersion := AScope.ProjectVersion;
  SetLength(Result.Files, Length(AScope.Files));
  for FileIndex := 0 to High(AScope.Files) do
    Result.Files[FileIndex] := AScope.Files[FileIndex].RootRelativePath;
  SortAndDeduplicate(Result.Files);
  for ProjectIndex := 0 to High(AScope.Projects) do
  begin
    for PatternIndex := 0 to
      High(AScope.Projects[ProjectIndex].Configuration.Includes) do
      AddConfigurationValue(Result.Configuration,
        AScope.Projects[ProjectIndex].Name, 'analysis.include',
        AScope.Projects[ProjectIndex].Configuration.Includes[PatternIndex]);
    for PatternIndex := 0 to
      High(AScope.Projects[ProjectIndex].Configuration.Excludes) do
      AddConfigurationValue(Result.Configuration,
        AScope.Projects[ProjectIndex].Name, 'analysis.exclude',
        AScope.Projects[ProjectIndex].Configuration.Excludes[PatternIndex]);
  end;
  SortAndDeduplicateConfiguration(Result.Configuration);
end;

function JSONString(const AValue: string): string;
var
  CharacterIndex: Integer;
  ValueByte: Byte;
begin
  Result := '"';
  for CharacterIndex := 1 to Length(AValue) do
  begin
    ValueByte := Byte(AValue[CharacterIndex]);
    case AValue[CharacterIndex] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if ValueByte < 32 then
        Result := Result + '\u00' + IntToHex(ValueByte, 2)
      else
        Result := Result + AValue[CharacterIndex];
    end;
  end;
  Result := Result + '"';
end;

procedure ValidatePayloadJSON(const APayloadJSON: string);
const
  MAX_JSON_DEPTH = 128;
var
  Index: Integer;
  Text: string;

  procedure Fail(const AReason: string);
  begin
    raise ELWPTError.CreateFmt(
      'analysis payload is not valid JSON at byte %d: %s',
      [Index, AReason]);
  end;

  procedure SkipWhitespace;
  begin
    while (Index <= Length(Text)) and
      (Text[Index] in [' ', #9, #10, #13]) do Inc(Index);
  end;

  function IsHexDigit(const ACharacter: Char): Boolean;
  begin
    Result := ACharacter in ['0'..'9', 'A'..'F', 'a'..'f'];
  end;

  procedure ParseString;
  var
    EscapeIndex: Integer;
  begin
    if (Index > Length(Text)) or (Text[Index] <> '"') then
      Fail('expected a string');
    Inc(Index);
    while Index <= Length(Text) do
    begin
      if Text[Index] = '"' then
      begin
        Inc(Index);
        Exit;
      end;
      if Ord(Text[Index]) < 32 then
        Fail('unescaped control byte in string');
      if Text[Index] <> '\' then
      begin
        Inc(Index);
        Continue;
      end;
      Inc(Index);
      if Index > Length(Text) then Fail('unterminated string escape');
      if Text[Index] = 'u' then
      begin
        for EscapeIndex := 1 to 4 do
        begin
          Inc(Index);
          if (Index > Length(Text)) or not IsHexDigit(Text[Index]) then
            Fail('invalid Unicode escape');
        end;
        Inc(Index);
      end
      else if Text[Index] in ['"', '\', '/', 'b', 'f', 'n', 'r', 't'] then
        Inc(Index)
      else
        Fail('invalid string escape');
    end;
    Fail('unterminated string');
  end;

  procedure ParseNumber;
  begin
    if Text[Index] = '-' then
    begin
      Inc(Index);
      if Index > Length(Text) then Fail('incomplete number');
    end;
    if Text[Index] = '0' then
    begin
      Inc(Index);
      if (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) then
        Fail('leading zero in number');
    end
    else if Text[Index] in ['1'..'9'] then
      while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
        Inc(Index)
    else
      Fail('expected a number');
    if (Index <= Length(Text)) and (Text[Index] = '.') then
    begin
      Inc(Index);
      if (Index > Length(Text)) or not (Text[Index] in ['0'..'9']) then
        Fail('fraction requires a digit');
      while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
        Inc(Index);
    end;
    if (Index <= Length(Text)) and (Text[Index] in ['e', 'E']) then
    begin
      Inc(Index);
      if (Index <= Length(Text)) and (Text[Index] in ['+', '-']) then
        Inc(Index);
      if (Index > Length(Text)) or not (Text[Index] in ['0'..'9']) then
        Fail('exponent requires a digit');
      while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
        Inc(Index);
    end;
  end;

  procedure ParseLiteral(const AValue: string);
  begin
    if Copy(Text, Index, Length(AValue)) <> AValue then
      Fail('invalid literal');
    Inc(Index, Length(AValue));
  end;

  procedure ParseValue(const ADepth: Integer);
  begin
    if ADepth > MAX_JSON_DEPTH then Fail('maximum nesting depth exceeded');
    SkipWhitespace;
    if Index > Length(Text) then Fail('expected a value');
    case Text[Index] of
      '{':
        begin
          Inc(Index);
          SkipWhitespace;
          if (Index <= Length(Text)) and (Text[Index] = '}') then
          begin
            Inc(Index);
            Exit;
          end;
          repeat
            ParseString;
            SkipWhitespace;
            if (Index > Length(Text)) or (Text[Index] <> ':') then
              Fail('expected a colon');
            Inc(Index);
            ParseValue(ADepth + 1);
            SkipWhitespace;
            if (Index <= Length(Text)) and (Text[Index] = '}') then
            begin
              Inc(Index);
              Exit;
            end;
            if (Index > Length(Text)) or (Text[Index] <> ',') then
              Fail('expected a comma or closing brace');
            Inc(Index);
            SkipWhitespace;
          until False;
        end;
      '[':
        begin
          Inc(Index);
          SkipWhitespace;
          if (Index <= Length(Text)) and (Text[Index] = ']') then
          begin
            Inc(Index);
            Exit;
          end;
          repeat
            ParseValue(ADepth + 1);
            SkipWhitespace;
            if (Index <= Length(Text)) and (Text[Index] = ']') then
            begin
              Inc(Index);
              Exit;
            end;
            if (Index > Length(Text)) or (Text[Index] <> ',') then
              Fail('expected a comma or closing bracket');
            Inc(Index);
          until False;
        end;
      '"': ParseString;
      '-', '0'..'9': ParseNumber;
      't': ParseLiteral('true');
      'f': ParseLiteral('false');
      'n': ParseLiteral('null');
    else
      Fail('expected a value');
    end;
  end;

begin
  Text := Trim(APayloadJSON);
  if (Text = '') or not (Text[1] in ['{', '[']) then
    raise ELWPTError.Create(
      'analysis payload must be a JSON object or array');
  Index := 1;
  ParseValue(1);
  SkipWhitespace;
  if Index <= Length(Text) then Fail('trailing content');
end;

procedure ValidateMetadata(const AMetadata: TLWPTAnalysisMetadata;
  const APayloadJSON: string);
begin
  if Trim(AMetadata.CommandName) = '' then
    raise ELWPTError.Create('analysis command name must not be empty');
  if AMetadata.CommandSchemaVersion < 1 then
    raise ELWPTError.Create(
      'analysis command schema version must be a positive integer');
  if Trim(AMetadata.ProjectName) = '' then
    raise ELWPTError.Create('analysis project name must not be empty');
  ValidatePayloadJSON(APayloadJSON);
end;

function SerializeStringArray(const AValues: TStringArray): string;
var
  ValueIndex: Integer;
begin
  Result := '[';
  for ValueIndex := 0 to High(AValues) do
  begin
    if ValueIndex > 0 then Result := Result + ',';
    Result := Result + JSONString(AValues[ValueIndex]);
  end;
  Result := Result + ']';
end;

function SerializeConfiguration(
  const AValues: TLWPTAnalysisConfigurationValueArray): string;
var
  ValueIndex: Integer;
begin
  Result := '[';
  for ValueIndex := 0 to High(AValues) do
  begin
    if ValueIndex > 0 then Result := Result + ',';
    Result := Result + '{"project":' + JSONString(AValues[ValueIndex].ProjectName)
      + ',"name":' + JSONString(AValues[ValueIndex].Name)
      + ',"value":' + JSONString(AValues[ValueIndex].Value) + '}';
  end;
  Result := Result + ']';
end;

function ThresholdOutcomeName(
  const AOutcome: TLWPTAnalysisThresholdOutcome): string;
begin
  case AOutcome of
    atoPassed: Result := 'passed';
    atoFailed: Result := 'failed';
  else
    Result := 'not-configured';
  end;
end;

function SerializeAnalysisEnvelope(const AMetadata: TLWPTAnalysisMetadata;
  const APayloadJSON: string): string;
var
  Configuration: TLWPTAnalysisConfigurationValueArray;
  Diagnostics: TStringArray;
  Files: TStringArray;
begin
  ValidateMetadata(AMetadata, APayloadJSON);
  Files := Copy(AMetadata.Files, 0, Length(AMetadata.Files));
  SortAndDeduplicate(Files);
  Configuration := Copy(AMetadata.Configuration, 0,
    Length(AMetadata.Configuration));
  SortAndDeduplicateConfiguration(Configuration);
  Diagnostics := Copy(AMetadata.Diagnostics, 0,
    Length(AMetadata.Diagnostics));
  SortAndDeduplicate(Diagnostics);
  { Fixed member order and LF delimiters make the writer byte-stable across
    platforms. Payload structure and schema remain command-owned. }
  Result := '{'#10
    + '  "schema":' + JSONString(ANALYSIS_ENVELOPE_SCHEMA) + ','#10
    + '  "schemaVersion":'
      + IntToStr(ANALYSIS_ENVELOPE_SCHEMA_VERSION) + ','#10
    + '  "command":{"name":' + JSONString(AMetadata.CommandName)
      + ',"schemaVersion":' + IntToStr(AMetadata.CommandSchemaVersion)
      + '},'#10
    + '  "tool":{"name":' + JSONString(PROGRAM_NAME)
      + ',"version":' + JSONString(PROGRAM_VERSION) + '},'#10
    + '  "project":{"name":' + JSONString(AMetadata.ProjectName)
      + ',"version":' + JSONString(AMetadata.ProjectVersion) + '},'#10
    + '  "files":' + SerializeStringArray(Files) + ','#10
    + '  "configuration":' + SerializeConfiguration(Configuration) + ','#10
    + '  "threshold":{"outcome":'
      + JSONString(ThresholdOutcomeName(AMetadata.ThresholdOutcome)) + '},'#10
    + '  "diagnostics":' + SerializeStringArray(Diagnostics) + ','#10
    + '  "payload":' + Trim(APayloadJSON) + #10
    + '}'#10;
end;

end.
