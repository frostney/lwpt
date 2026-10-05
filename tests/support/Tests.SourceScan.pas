{ Tests.SourceScan — tokenized, routine-scoped scanning of the repository's
  test code, shared by the guard programs that keep known flake shapes out
  of it (PayloadHandoffGuard.Test, ChildWaitGuard.Test).

  Files are tokenized and split into regions by LWPT.Analysis.Pascal, the
  analyzer behind lwpt health and lwpt duplication. Like those commands it
  reads inactive conditional branches as well. A headerless fragment (an
  include file, a generated snippet) is analyzed inside a synthetic program
  shell. Every region is a scope; Executable marks routine bodies, program
  bodies, initialization, and finalization. A string expression in any
  region that decodes to Pascal is analyzed again as a generated fixture
  program, one scope per generated region. Each spliced-in value
  (PascalString(X), IntToStr(...)) becomes a placeholder token carrying X's
  expression as its GlueKey, and each EmitPayloadCompletion(..., P) becomes
  a PublishPayloadCompletion call on P. A string is fixture source only when
  it contains a semicolon and tokenizes as Pascal, and fixture source nested
  inside a fixture's own literals is not decoded again. Include directives
  are not followed. }
unit Tests.SourceScan;

{$mode delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Types,

  LWPT.Analysis.Pascal;

type
  TSourceFinding = record
    Path: string;
    Line: Integer;
    Rule: string;
    Routine: string;
    Key: string;
    Evidence: string;
  end;
  TSourceFindings = array of TSourceFinding;

  TGuardToken = record
    Kind: TLWPTPascalTokenKind;
    Text: string;     { lower case for identifiers and keywords }
    Original: string; { the source spelling }
    Line: Integer;    { line in the scanned file }
    GlueKey: string;  { a fixture placeholder's spliced-in expression }
    GlueLooseKey: string; { the same expression, loosely normalized }
  end;
  TGuardTokens = array of TGuardToken;

  TGuardScope = record
    Routine: string;
    Executable: Boolean;
    Tokens: TGuardTokens;
  end;
  TGuardScopes = array of TGuardScope;

  TTokenRange = record
    First: Integer;
    Last: Integer;
  end;
  TTokenRanges = array of TTokenRange;

function IsCodeToken(const AToken: TGuardToken): Boolean;
{ AText is lower case; string tokens never match. }
function TokenIs(const ATokens: TGuardTokens; AIndex: Integer;
  const AText: string): Boolean;
{ Paren- and bracket-balanced arguments of the call whose '(' is at AOpen.
  AClosed is False when the tokens end before the call does. }
function CallArguments(const ATokens: TGuardTokens; AOpen: Integer;
  out AClosed: Boolean): TTokenRanges;
function IsCallAt(const ATokens: TGuardTokens; AIndex: Integer;
  const AName: string): Boolean;
{ An identifier's lower-case text; ALoose drops a Delphi parameter's A
  prefix (APIDFile -> pidfile). }
function NormalizedIdentifier(const AToken: TGuardToken;
  ALoose: Boolean): string;
{ ARange's tokens as one comparable string, identifiers case-insensitive. }
function RangeKey(const ATokens: TGuardTokens; const ARange: TTokenRange;
  ALoose: Boolean = False): string;
function FirstArgumentKey(const ATokens: TGuardTokens; AOpen: Integer;
  out AKey: string; ALoose: Boolean = False): Boolean;

{ Statement structure, without control-flow analysis. }
function OpensBlock(const ATokens: TGuardTokens; AIndex: Integer): Boolean;
function MatchingEnd(const ATokens: TGuardTokens; AOpen: Integer): Integer;
function MatchingUntil(const ATokens: TGuardTokens; ARepeat: Integer): Integer;
{ Last token of the simple statement or expression starting at AStart. }
function SimpleStatementEnd(const ATokens: TGuardTokens;
  AStart: Integer): Integer;
{ Last token of the statement starting at AStart. }
function StatementEnd(const ATokens: TGuardTokens; AStart: Integer): Integer;
{ Marks every token of every while, for, and repeat loop, condition and
  body alike. }
function LoopMask(const ATokens: TGuardTokens): TBooleanDynArray;

procedure AddFinding(var AFindings: TSourceFindings; const APath: string;
  const ALines: TStrings; ALine: Integer; const ARule, ARoutine,
  AKey: string);
function DescribeFinding(const AFinding: TSourceFinding): string;

{ Line of every zero-based offset of ASource, one past the end included. }
function SourceLineMap(const ASource: string): TIntegerDynArray;
{ Every scope of ASource and of the fixture programs it generates; see the
  unit header. Raises ELWPTPascalAnalysisError when ASource does not
  tokenize. }
function SourceScopes(const ASource: string): TGuardScopes;

{ Test code: *.Test.* under source/, everything under tests/, and under
  packages/ the *.Test.* and Tests.* units and everything below a tests/
  directory; .pas and .inc only, AExcludedPath (the calling guard, whose
  self-tests embed violations) excepted. Paths are relative to the
  repository root, which lwpt test makes the working directory. }
function IsScanTarget(const ARelativePath, AExcludedPath: string): Boolean;
function ScanTargets(const AExcludedPath: string): TStringList;

implementation

const
  GluePrefix = 'lwptscanglue';

function IsCodeToken(const AToken: TGuardToken): Boolean;
begin
  Result := AToken.Kind in [ptIdentifier, ptKeyword];
end;

function TokenIs(const ATokens: TGuardTokens; AIndex: Integer;
  const AText: string): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex <= High(ATokens))
    and (ATokens[AIndex].Kind <> ptString) and (ATokens[AIndex].Text = AText);
end;

{ Paren- and bracket-balanced arguments of the call whose '(' is at AOpen.
  AClosed is False when the tokens end before the call does. }
function CallArguments(const ATokens: TGuardTokens; AOpen: Integer;
  out AClosed: Boolean): TTokenRanges;
var
  Depth, Index, Start: Integer;

  procedure Add(AFirst, ALast: Integer);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].First := AFirst;
    Result[High(Result)].Last := ALast;
  end;

begin
  Result := nil;
  AClosed := False;
  Depth := 0;
  Start := AOpen + 1;
  for Index := AOpen to High(ATokens) do
  begin
    if TokenIs(ATokens, Index, '(') or TokenIs(ATokens, Index, '[') then
      Inc(Depth)
    else if TokenIs(ATokens, Index, ')') or TokenIs(ATokens, Index, ']') then
    begin
      Dec(Depth);
      if Depth = 0 then
      begin
        if Index > Start then Add(Start, Index - 1);
        AClosed := True;
        Exit;
      end;
    end
    else if TokenIs(ATokens, Index, ',') and (Depth = 1) then
    begin
      Add(Start, Index - 1);
      Start := Index + 1;
    end;
  end;
end;

function IsCallAt(const ATokens: TGuardTokens; AIndex: Integer;
  const AName: string): Boolean;
begin
  Result := IsCodeToken(ATokens[AIndex]) and (ATokens[AIndex].Text = AName)
    and TokenIs(ATokens, AIndex + 1, '(');
end;

function NormalizedIdentifier(const AToken: TGuardToken;
  ALoose: Boolean): string;
begin
  Result := AToken.Text;
  { Delphi parameters carry an A prefix: APIDFile in a writer and PIDFile in
    its waiter usually name one path. The loose form only discovers
    suspicious barriers; it never proves that a write was completed. }
  if ALoose and (Length(AToken.Original) > 2) and (AToken.Original[1] = 'A')
     and (AToken.Original[2] in ['A'..'Z']) then
    Delete(Result, 1, 1);
end;

function RangeKey(const ATokens: TGuardTokens; const ARange: TTokenRange;
  ALoose: Boolean = False): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := ARange.First to ARange.Last do
    if (ATokens[Index].GlueKey <> '') and ALoose then
      Result := Result + ATokens[Index].GlueLooseKey
    else if ATokens[Index].GlueKey <> '' then
      Result := Result + ATokens[Index].GlueKey
    else if ATokens[Index].Kind = ptIdentifier then
      Result := Result + NormalizedIdentifier(ATokens[Index], ALoose)
    else if ATokens[Index].Kind = ptString then
      Result := Result + ATokens[Index].Original
    else
      Result := Result + ATokens[Index].Text;
end;

function FirstArgumentKey(const ATokens: TGuardTokens; AOpen: Integer;
  out AKey: string; ALoose: Boolean = False): Boolean;
var
  Arguments: TTokenRanges;
  Closed: Boolean;
begin
  Arguments := CallArguments(ATokens, AOpen, Closed);
  Result := Length(Arguments) > 0;
  if Result then AKey := RangeKey(ATokens, Arguments[0], ALoose);
end;

function OpensBlock(const ATokens: TGuardTokens; AIndex: Integer): Boolean;
begin
  Result := TokenIs(ATokens, AIndex, 'begin') or TokenIs(ATokens, AIndex, 'try')
    or TokenIs(ATokens, AIndex, 'case') or TokenIs(ATokens, AIndex, 'asm')
    or TokenIs(ATokens, AIndex, 'record');
end;

function MatchingEnd(const ATokens: TGuardTokens; AOpen: Integer): Integer;
var
  Depth, Index: Integer;
begin
  Depth := 0;
  for Index := AOpen to High(ATokens) do
    if OpensBlock(ATokens, Index) then Inc(Depth)
    else if TokenIs(ATokens, Index, 'end') then
    begin
      Dec(Depth);
      if Depth = 0 then Exit(Index);
    end;
  Result := High(ATokens);
end;

function MatchingUntil(const ATokens: TGuardTokens; ARepeat: Integer): Integer;
var
  Depth, Index: Integer;
begin
  Depth := 0;
  for Index := ARepeat to High(ATokens) do
    if TokenIs(ATokens, Index, 'repeat') then Inc(Depth)
    else if TokenIs(ATokens, Index, 'until') then
    begin
      Dec(Depth);
      if Depth = 0 then Exit(Index);
    end;
  Result := High(ATokens);
end;

{ Last token of the simple statement or expression starting at AStart. }
function SimpleStatementEnd(const ATokens: TGuardTokens;
  AStart: Integer): Integer;
var
  Blocks, Ifs, Index, Parens: Integer;
begin
  Blocks := 0;
  Ifs := 0;
  Parens := 0;
  for Index := AStart to High(ATokens) do
  begin
    if TokenIs(ATokens, Index, '(') or TokenIs(ATokens, Index, '[') then
      Inc(Parens)
    else if TokenIs(ATokens, Index, ')') or TokenIs(ATokens, Index, ']') then
      Dec(Parens)
    else if Parens > 0 then
      Continue
    else if OpensBlock(ATokens, Index) or TokenIs(ATokens, Index, 'repeat') then
      Inc(Blocks)
    else if TokenIs(ATokens, Index, 'end')
      or TokenIs(ATokens, Index, 'until') then
    begin
      if Blocks = 0 then Exit(Index - 1);
      Dec(Blocks);
    end
    else if Blocks > 0 then
      Continue
    else if TokenIs(ATokens, Index, 'if') then
      Inc(Ifs)
    else if TokenIs(ATokens, Index, 'else') then
    begin
      if Ifs = 0 then Exit(Index - 1);
      Dec(Ifs);
    end
    else if TokenIs(ATokens, Index, ';') or TokenIs(ATokens, Index, 'except')
      or TokenIs(ATokens, Index, 'finally') then
      Exit(Index - 1);
  end;
  Result := High(ATokens);
end;

function StatementEnd(const ATokens: TGuardTokens; AStart: Integer): Integer;
begin
  if AStart > High(ATokens) then Exit(High(ATokens));
  if OpensBlock(ATokens, AStart) then Exit(MatchingEnd(ATokens, AStart));
  if TokenIs(ATokens, AStart, 'repeat') then
    Exit(SimpleStatementEnd(ATokens, MatchingUntil(ATokens, AStart) + 1));
  Result := SimpleStatementEnd(ATokens, AStart);
end;

{ Marks every token of every while, for, and repeat loop, condition and
  body alike. }
function LoopMask(const ATokens: TGuardTokens): TBooleanDynArray;
var
  Index, LoopEnd, Mark, Parens, Search: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ATokens));
  for Index := 0 to High(ATokens) do
  begin
    LoopEnd := -1;
    if TokenIs(ATokens, Index, 'repeat') then
      LoopEnd := SimpleStatementEnd(ATokens, MatchingUntil(ATokens, Index) + 1)
    else if TokenIs(ATokens, Index, 'while') or TokenIs(ATokens, Index, 'for')
    then
    begin
      Parens := 0;
      Search := Index + 1;
      while Search <= High(ATokens) do
      begin
        if TokenIs(ATokens, Search, '(') then Inc(Parens)
        else if TokenIs(ATokens, Search, ')') then Dec(Parens)
        else if (Parens = 0) and TokenIs(ATokens, Search, 'do') then Break;
        Inc(Search);
      end;
      LoopEnd := StatementEnd(ATokens, Search + 1);
    end;
    for Mark := Index to LoopEnd do Result[Mark] := True;
  end;
end;

procedure AddFinding(var AFindings: TSourceFindings; const APath: string;
  const ALines: TStrings; ALine: Integer; const ARule, ARoutine,
  AKey: string);
begin
  SetLength(AFindings, Length(AFindings) + 1);
  AFindings[High(AFindings)].Path := APath;
  AFindings[High(AFindings)].Line := ALine;
  AFindings[High(AFindings)].Rule := ARule;
  AFindings[High(AFindings)].Routine := ARoutine;
  AFindings[High(AFindings)].Key := AKey;
  if (ALine >= 1) and (ALine <= ALines.Count) then
    AFindings[High(AFindings)].Evidence := Trim(ALines[ALine - 1])
  else
    AFindings[High(AFindings)].Evidence := '';
end;

function DescribeFinding(const AFinding: TSourceFinding): string;
begin
  Result := AFinding.Path + ':' + IntToStr(AFinding.Line) + ': '
    + AFinding.Rule + ' in ' + AFinding.Routine + ' on "' + AFinding.Key
    + '": ' + AFinding.Evidence;
end;

{ Line of every zero-based offset of ASource, one past the end included. }
function SourceLineMap(const ASource: string): TIntegerDynArray;
var
  Index, Line: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ASource) + 1);
  Line := 1;
  for Index := 1 to Length(ASource) do
  begin
    Result[Index - 1] := Line;
    if ASource[Index] = #10 then Inc(Line);
  end;
  Result[Length(ASource)] := Line;
end;

{ Guard tokens for ATokens[AFirst..ALast]. A fixture placeholder takes the
  spliced-in expression recorded at the same index of AGlueKeys. }
function GuardTokens(const ASource: string;
  const ATokens: TLWPTPascalTokenArray; AFirst, ALast: Integer;
  const ALineMap: TIntegerDynArray;
  AGlueKeys, AGlueLooseKeys: TStrings): TGuardTokens;
var
  GlueIndex, Index: Integer;
  Token: TGuardToken;
begin
  Result := nil;
  SetLength(Result, ALast - AFirst + 1);
  for Index := AFirst to ALast do
  begin
    Token.Kind := ATokens[Index].Kind;
    Token.Text := ATokens[Index].Text;
    Token.Original := Copy(ASource, ATokens[Index].Offset + 1,
      ATokens[Index].Length);
    Token.Line := ALineMap[ATokens[Index].Offset];
    Token.GlueKey := '';
    Token.GlueLooseKey := '';
    if Assigned(AGlueKeys) and (Token.Kind = ptIdentifier)
       and (Copy(Token.Text, 1, Length(GluePrefix)) = GluePrefix) then
    begin
      GlueIndex := StrToIntDef(Copy(Token.Text, Length(GluePrefix) + 1,
        MaxInt), -1);
      if (GlueIndex >= 0) and (GlueIndex < AGlueKeys.Count) then
      begin
        Token.GlueKey := AGlueKeys[GlueIndex];
        Token.GlueLooseKey := AGlueLooseKeys[GlueIndex];
      end;
    end;
    Result[Index - AFirst] := Token;
  end;
end;

function DecodeLiteral(const AOriginal: string): string;
var
  Index: Integer;
begin
  if (AOriginal <> '') and (AOriginal[1] = '#') then
  begin
    if (Length(AOriginal) > 1) and (AOriginal[2] = '$') then
      Exit(Chr(StrToIntDef('$' + Copy(AOriginal, 3, MaxInt), 32)));
    Exit(Chr(StrToIntDef(Copy(AOriginal, 2, MaxInt), 32)));
  end;
  Result := '';
  Index := 2;
  while Index < Length(AOriginal) do
  begin
    Result := Result + AOriginal[Index];
    if (AOriginal[Index] = '''') and (Index + 1 < Length(AOriginal)) then
      Inc(Index);
    Inc(Index);
  end;
end;

{ Last token of a spliced-in value that starts at AStart. }
function GlueEnd(const ATokens: TGuardTokens; AStart: Integer): Integer;
var
  Depth, Index: Integer;
begin
  Depth := 0;
  for Index := AStart to High(ATokens) do
  begin
    if TokenIs(ATokens, Index, '(') or TokenIs(ATokens, Index, '[') then
      Inc(Depth)
    else if TokenIs(ATokens, Index, ')') or TokenIs(ATokens, Index, ']') then
    begin
      if Depth = 0 then Exit(Index - 1);
      Dec(Depth);
    end
    else if (Depth = 0) and (TokenIs(ATokens, Index, '+')
      or TokenIs(ATokens, Index, ',') or TokenIs(ATokens, Index, ';')
      or TokenIs(ATokens, Index, ':=') or TokenIs(ATokens, Index, 'then')
      or TokenIs(ATokens, Index, 'do') or TokenIs(ATokens, Index, 'of')
      or TokenIs(ATokens, Index, 'else') or TokenIs(ATokens, Index, 'end')) then
      Exit(Index - 1);
  end;
  Result := High(ATokens);
end;

{ Strips an enclosing PascalString(...) call from a spliced-in value. }
function SplicedValue(const ATokens: TGuardTokens;
  const ARange: TTokenRange): TTokenRange;
begin
  Result := ARange;
  if IsCallAt(ATokens, ARange.First, 'pascalstring')
     and TokenIs(ATokens, ARange.Last, ')') then
  begin
    Result.First := ARange.First + 2;
    Result.Last := ARange.Last - 1;
  end;
end;

type
  TFixtureBuilder = record
    Text: string;
    Lines: TIntegerDynArray;
    GlueKeys: TStringList;
    GlueLooseKeys: TStringList;
  end;

procedure AppendFixture(var ABuilder: TFixtureBuilder; const AText: string;
  ALine: Integer);
var
  Index, Start: Integer;
begin
  Start := Length(ABuilder.Text);
  ABuilder.Text := ABuilder.Text + AText;
  SetLength(ABuilder.Lines, Length(ABuilder.Text) + 1);
  for Index := Start to Length(ABuilder.Text) do
    ABuilder.Lines[Index] := ALine;
end;

function AddGlue(var ABuilder: TFixtureBuilder; const ATokens: TGuardTokens;
  const AValue: TTokenRange): string;
begin
  ABuilder.GlueLooseKeys.Add(RangeKey(ATokens, AValue, True));
  Result := GluePrefix + IntToStr(ABuilder.GlueKeys.Add(
    RangeKey(ATokens, AValue)));
end;

procedure AppendGlue(var ABuilder: TFixtureBuilder;
  const ATokens: TGuardTokens; const ARange: TTokenRange);
var
  Arguments: TTokenRanges;
  Closed: Boolean;
begin
  if IsCallAt(ATokens, ARange.First, 'emitpayloadcompletion') then
  begin
    Arguments := CallArguments(ATokens, ARange.First + 1, Closed);
    if Length(Arguments) = 2 then
    begin
      AppendFixture(ABuilder, ' PublishPayloadCompletion('
        + AddGlue(ABuilder, ATokens, SplicedValue(ATokens, Arguments[1]))
        + '); ', ATokens[ARange.First].Line);
      Exit;
    end;
  end;
  AppendFixture(ABuilder, ' ' + AddGlue(ABuilder, ATokens,
    SplicedValue(ATokens, ARange)) + ' ', ATokens[ARange.First].Line);
end;

{ Decodes the string expression starting at AStart into fixture source.
  Returns the last token it consumed. }
function DecodeStringExpression(const ATokens: TGuardTokens; AStart: Integer;
  var ABuilder: TFixtureBuilder): Integer;
var
  Glue: TTokenRange;
  Index: Integer;
begin
  Index := AStart;
  Result := AStart;
  while Index <= High(ATokens) do
  begin
    if ATokens[Index].Kind = ptString then
    begin
      AppendFixture(ABuilder, DecodeLiteral(ATokens[Index].Original),
        ATokens[Index].Line);
      Result := Index;
      Inc(Index);
      Continue;
    end;
    if not TokenIs(ATokens, Index, '+') or (Index = High(ATokens)) then Break;
    Inc(Index);
    if ATokens[Index].Kind = ptString then Continue;
    Glue.First := Index;
    Glue.Last := GlueEnd(ATokens, Index);
    if Glue.Last < Glue.First then Break;
    AppendGlue(ABuilder, ATokens, Glue);
    Result := Glue.Last;
    Index := Glue.Last + 1;
  end;
end;

procedure AddScope(var AScopes: TGuardScopes; const ARoutine: string;
  const AExecutable: Boolean; const ATokens: TGuardTokens);
begin
  SetLength(AScopes, Length(AScopes) + 1);
  AScopes[High(AScopes)].Routine := ARoutine;
  AScopes[High(AScopes)].Executable := AExecutable;
  AScopes[High(AScopes)].Tokens := ATokens;
end;

function RoutineLabel(const ADocument: TLWPTPascalDocument;
  const ARegion: TLWPTPascalRegion): string;
begin
  if ARegion.OwnerRoutine >= 0 then
    Result := ADocument.Routines[ARegion.OwnerRoutine].Name
  else if ARegion.Kind = pgInitialization then
    Result := '<initialization>'
  else if ARegion.Kind = pgFinalization then
    Result := '<finalization>'
  else if ARegion.Kind = pgUnitDeclarations then
    Result := '<declarations>'
  else
    Result := '<main>';
end;

function FirstCodeToken(const ATokens: TLWPTPascalTokenArray): string;
var
  Index: Integer;
begin
  for Index := 0 to High(ATokens) do
    if ATokens[Index].Kind <> ptDirective then Exit(ATokens[Index].Text);
  Result := '';
end;

function IsDeclarationKeyword(const AText: string): Boolean;
begin
  Result := (AText = 'procedure') or (AText = 'function')
    or (AText = 'constructor') or (AText = 'destructor')
    or (AText = 'operator') or (AText = 'class') or (AText = 'type')
    or (AText = 'const') or (AText = 'var') or (AText = 'threadvar')
    or (AText = 'resourcestring') or (AText = 'label') or (AText = 'uses');
end;

procedure AddTextScopes(const AText: string;
  const ALineMap: TIntegerDynArray; const ALabel: string;
  AGlueKeys, AGlueLooseKeys: TStrings; ADecodeFixtures: Boolean;
  var AScopes: TGuardScopes); forward;

{ Adds a scope for every routine of every generated fixture program whose
  source is a string expression in ATokens. }
procedure AddFixtureScopes(const ALabel: string; const ATokens: TGuardTokens;
  var AScopes: TGuardScopes);
var
  Builder: TFixtureBuilder;
  Index: Integer;
begin
  Index := 0;
  while Index <= High(ATokens) do
  begin
    if ATokens[Index].Kind <> ptString then
    begin
      Inc(Index);
      Continue;
    end;
    Builder.Text := '';
    Builder.Lines := nil;
    Builder.GlueKeys := TStringList.Create;
    Builder.GlueLooseKeys := TStringList.Create;
    try
      Index := DecodeStringExpression(ATokens, Index, Builder) + 1;
      { Only a string that reads as statements is fixture source. }
      if Pos(';', Builder.Text) > 0 then
        try
          AddTextScopes(Builder.Text, Builder.Lines, ALabel + ' fixture ',
            Builder.GlueKeys, Builder.GlueLooseKeys, False, AScopes);
        except
          { A string that does not tokenize is not fixture source. }
          on ELWPTPascalAnalysisError do Builder.Text := '';
        end;
    finally
      Builder.GlueLooseKeys.Free;
      Builder.GlueKeys.Free;
    end;
  end;
end;

{ Adds one scope per region of AText. A headerless fragment (an
  include file or a generated snippet) is analyzed inside a synthetic
  program shell: declarations before an empty main block, statements as
  the main block. ALineMap maps AText offsets to lines of the scanned
  file. With ADecodeFixtures, string expressions in every region,
  declarations included, are scanned as generated fixture programs. }
procedure AddTextScopes(const AText: string;
  const ALineMap: TIntegerDynArray; const ALabel: string;
  AGlueKeys, AGlueLooseKeys: TStrings; ADecodeFixtures: Boolean;
  var AScopes: TGuardScopes);
const
  FragmentHeader = 'program lwptscanfragment; ';
var
  Document: TLWPTPascalDocument;
  First: string;
  Index: Integer;
  Map: TIntegerDynArray;
  Prefix, Suffix, Text: string;
  Region: TLWPTPascalRegion;
  RegionLabel: string;
  Tokens: TGuardTokens;
begin
  Text := AText;
  Map := ALineMap;
  First := FirstCodeToken(TokenizePascal(AText, '<source>'));
  if (First <> '') and (First <> 'program') and (First <> 'unit')
     and (First <> 'library') and (First <> 'package') then
  begin
    if IsDeclarationKeyword(First) then
    begin
      Prefix := FragmentHeader;
      Suffix := #10'begin end.';
    end
    else
    begin
      Prefix := FragmentHeader + 'begin ';
      Suffix := #10'end.';
    end;
    Text := Prefix + AText + Suffix;
    Map := nil;
    SetLength(Map, Length(Text) + 1);
    for Index := 0 to High(Map) do
      if Index < Length(Prefix) then
        Map[Index] := ALineMap[0]
      else if Index - Length(Prefix) <= High(ALineMap) then
        Map[Index] := ALineMap[Index - Length(Prefix)]
      else
        Map[Index] := ALineMap[High(ALineMap)];
  end;
  Document := AnalyzePascal(Text, '<source>');
  for Region in Document.Regions do
  begin
    if Region.Tokens.EndToken <= Region.Tokens.StartToken then Continue;
    Tokens := GuardTokens(Text, Document.Tokens, Region.Tokens.StartToken,
      Region.Tokens.EndToken - 1, Map, AGlueKeys, AGlueLooseKeys);
    RegionLabel := ALabel + RoutineLabel(Document, Region);
    AddScope(AScopes, RegionLabel, PascalRegionIsExecutable(Region.Kind),
      Tokens);
    if ADecodeFixtures then AddFixtureScopes(RegionLabel, Tokens, AScopes);
  end;
end;

function IsScanTarget(const ARelativePath, AExcludedPath: string): Boolean;
var
  Extension, Name: string;
begin
  if ARelativePath = AExcludedPath then Exit(False);
  Name := ExtractFileName(ARelativePath);
  Extension := ExtractFileExt(Name);
  if (Extension <> '.pas') and (Extension <> '.inc') then Exit(False);
  if Copy(ARelativePath, 1, 7) = 'source/' then
    Exit(Pos('.Test.', Name) > 0);
  if Copy(ARelativePath, 1, 6) = 'tests/' then Exit(True);
  if Copy(ARelativePath, 1, 9) = 'packages/' then
    Exit((Pos('.Test.', Name) > 0) or (Copy(Name, 1, 6) = 'Tests.')
      or (Pos('/tests/', ARelativePath) > 0));
  Result := False;
end;

procedure CollectScanTargets(const ARelativeDirectory,
  AExcludedPath: string; AFiles: TStrings);
var
  Search: TSearchRec;
  RelativePath: string;
begin
  if FindFirst(ARelativeDirectory + '/*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      RelativePath := ARelativeDirectory + '/' + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        if (Search.Name <> '.lwpt') and (Search.Name <> 'build')
           and (Search.Name <> '.git') then
          CollectScanTargets(RelativePath, AExcludedPath, AFiles);
      end
      else if IsScanTarget(RelativePath, AExcludedPath) then
        AFiles.Add(RelativePath);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function ScanTargets(const AExcludedPath: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  CollectScanTargets('source', AExcludedPath, Result);
  CollectScanTargets('tests', AExcludedPath, Result);
  CollectScanTargets('packages', AExcludedPath, Result);
end;

function SourceScopes(const ASource: string): TGuardScopes;
begin
  Result := nil;
  AddTextScopes(ASource, SourceLineMap(ASource), '', nil, nil, True, Result);
end;

end.
