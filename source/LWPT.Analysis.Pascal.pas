{ LWPT.Analysis.Pascal — token and typed-region analysis for Object Pascal. }
unit LWPT.Analysis.Pascal;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

type
  ELWPTPascalAnalysisError = class(ELWPTError);

  TLWPTPascalTokenKind = (ptIdentifier, ptKeyword, ptNumber, ptString,
    ptSymbol, ptDirective);

  TLWPTPascalToken = record
    Kind: TLWPTPascalTokenKind;
    Text: string;
    Offset: Integer; { zero-based byte offset }
    Length: Integer;
    Line: Integer;   { one-based source line }
    Column: Integer; { one-based byte column }
  end;
  TLWPTPascalTokenArray = array of TLWPTPascalToken;

  TLWPTPascalTokenRange = record
    StartToken: Integer;
    EndToken: Integer; { exclusive }
  end;

  TLWPTPascalRoutineKind = (prProcedure, prFunction, prConstructor,
    prDestructor, prOperator);

  TLWPTPascalRegionKind = (pgUnitDeclarations, pgRoutineDeclarations,
    pgRoutineBody, pgProgramBody, pgInitialization, pgFinalization);

  TLWPTPascalRoutine = record
    Kind: TLWPTPascalRoutineKind;
    Name: string;
    ParentRoutine: Integer; { -1 for a top-level routine }
    Header: TLWPTPascalTokenRange;
    BodyRegion: Integer; { -1 for forward/external declarations }
  end;
  TLWPTPascalRoutineArray = array of TLWPTPascalRoutine;

  TLWPTPascalRegion = record
    Kind: TLWPTPascalRegionKind;
    OwnerRoutine: Integer; { -1 for unit/program regions }
    Tokens: TLWPTPascalTokenRange;
  end;
  TLWPTPascalRegionArray = array of TLWPTPascalRegion;

  TLWPTPascalDocument = record
    SourceName: string;
    Tokens: TLWPTPascalTokenArray;
    Routines: TLWPTPascalRoutineArray;
    Regions: TLWPTPascalRegionArray;
  end;

function TokenizePascal(const ASource: string;
  const ASourceName: string = ''): TLWPTPascalTokenArray;
function AnalyzePascal(const ASource: string;
  const ASourceName: string = ''): TLWPTPascalDocument;
function PascalRegionIsExecutable(const AKind: TLWPTPascalRegionKind):
  Boolean;

implementation

const
  PascalKeywords: array[0..94] of string = (
    'absolute', 'abstract', 'and', 'array', 'as', 'asm', 'assembler',
    'automated', 'begin', 'case', 'cdecl', 'class', 'const',
    'constructor', 'contains', 'default', 'deprecated', 'destructor',
    'dispid', 'dispinterface', 'div', 'do', 'downto', 'dynamic', 'else',
    'end', 'except', 'experimental', 'export', 'exports', 'external',
    'far', 'file', 'finalization', 'finally', 'for', 'forward', 'function',
    'generic', 'goto', 'helper', 'if', 'implementation', 'implements',
    'in', 'index', 'inherited', 'initialization', 'inline', 'interface',
    'is', 'label', 'library', 'local', 'message', 'mod', 'name', 'near',
    'nil', 'nodefault', 'not', 'object', 'of', 'on', 'operator', 'or',
    'out', 'overload', 'override', 'package', 'packed', 'pascal',
    'platform', 'private', 'procedure', 'program', 'property', 'protected',
    'public', 'published', 'raise', 'read', 'record', 'register', 'reintroduce',
    'repeat', 'requires', 'resourcestring', 'safecall', 'sealed', 'set',
    'shl', 'shr', 'specialize', 'static');

function IsIdentifierStart(const ACharacter: Char): Boolean; inline;
begin
  Result := (ACharacter in ['A'..'Z', 'a'..'z', '_'])
    or (Ord(ACharacter) >= 128);
end;

function IsIdentifierPart(const ACharacter: Char): Boolean; inline;
begin
  Result := IsIdentifierStart(ACharacter) or (ACharacter in ['0'..'9']);
end;

function IsKeyword(const AValue: string): Boolean;
var
  KeywordIndex: Integer;
begin
  for KeywordIndex := Low(PascalKeywords) to High(PascalKeywords) do
    if AValue = PascalKeywords[KeywordIndex] then Exit(True);
  Result := (AValue = 'strict') or (AValue = 'then')
    or (AValue = 'threadvar') or (AValue = 'to') or (AValue = 'try')
    or (AValue = 'type') or (AValue = 'unit') or (AValue = 'until')
    or (AValue = 'uses') or (AValue = 'var') or (AValue = 'virtual')
    or (AValue = 'while') or (AValue = 'with') or (AValue = 'write')
    or (AValue = 'xor');
end;

procedure RaiseLexicalError(const ASourceName, AMessage: string;
  const ALine, AColumn: Integer);
var
  Prefix: string;
begin
  Prefix := ASourceName;
  if Prefix = '' then Prefix := '<source>';
  raise ELWPTPascalAnalysisError.CreateFmt('%s(%d,%d): %s',
    [Prefix, ALine, AColumn, AMessage]);
end;

function TokenizePascal(const ASource, ASourceName: string):
  TLWPTPascalTokenArray;
var
  Column, Index, Line, StartColumn, StartIndex, StartLine: Integer;

  procedure Advance;
  begin
    if Index > Length(ASource) then Exit;
    if ASource[Index] = #13 then
    begin
      Inc(Index);
      if (Index <= Length(ASource)) and (ASource[Index] = #10) then
        Inc(Index);
      Inc(Line);
      Column := 1;
    end
    else if ASource[Index] = #10 then
    begin
      Inc(Index);
      Inc(Line);
      Column := 1;
    end
    else
    begin
      Inc(Index);
      Inc(Column);
    end;
  end;

  procedure AddToken(const AKind: TLWPTPascalTokenKind;
    const ANormalize: Boolean = True; const AStripEscape: Boolean = False);
  var
    TokenCount: Integer;
  begin
    TokenCount := Length(Result);
    SetLength(Result, TokenCount + 1);
    Result[TokenCount].Kind := AKind;
    Result[TokenCount].Text := Copy(ASource, StartIndex, Index - StartIndex);
    if AStripEscape and (Result[TokenCount].Text <> '')
      and (Result[TokenCount].Text[1] = '&') then
      Delete(Result[TokenCount].Text, 1, 1);
    if ANormalize then Result[TokenCount].Text :=
      LowerCase(Result[TokenCount].Text);
    Result[TokenCount].Offset := StartIndex - 1;
    Result[TokenCount].Length := Index - StartIndex;
    Result[TokenCount].Line := StartLine;
    Result[TokenCount].Column := StartColumn;
  end;

  procedure SkipLineComment;
  begin
    while (Index <= Length(ASource))
      and not (ASource[Index] in [#10, #13]) do Advance;
  end;

  procedure ScanComment(const ABraceComment: Boolean;
    const ADirective: Boolean);
  var
    Depth: Integer;

  begin
    Depth := 1;
    if ABraceComment then Advance
    else
    begin
      Advance;
      Advance;
    end;
    while (Index <= Length(ASource)) and (Depth > 0) do
    begin
      if ABraceComment and (ASource[Index] = '{') then
      begin
        Inc(Depth);
        Advance;
      end
      else if (not ABraceComment) and (ASource[Index] = '(')
        and (Index < Length(ASource))
        and (ASource[Index + 1] = '*') then
      begin
        Inc(Depth);
        Advance;
        Advance;
      end
      else if ABraceComment and (ASource[Index] = '}') then
      begin
        Dec(Depth);
        Advance;
      end
      else if (not ABraceComment) and (ASource[Index] = '*')
        and (Index < Length(ASource))
        and (ASource[Index + 1] = ')') then
      begin
        Dec(Depth);
        Advance;
        Advance;
      end
      else
        Advance;
    end;
    if Depth > 0 then
      RaiseLexicalError(ASourceName, 'unterminated comment', StartLine,
        StartColumn);
    if ADirective then AddToken(ptDirective, False);
  end;

  procedure ScanString;
  begin
    Advance;
    while Index <= Length(ASource) do
    begin
      if ASource[Index] <> '''' then
      begin
        Advance;
        Continue;
      end;
      Advance;
      if (Index <= Length(ASource)) and (ASource[Index] = '''') then
      begin
        Advance;
        Continue;
      end;
      AddToken(ptString, False);
      Exit;
    end;
    RaiseLexicalError(ASourceName, 'unterminated string literal', StartLine,
      StartColumn);
  end;

  procedure ScanCharacterCode;
  var
    DigitStart: Integer;
  begin
    Advance;
    if (Index <= Length(ASource)) and (ASource[Index] = '$') then Advance;
    DigitStart := Index;
    while (Index <= Length(ASource))
      and (ASource[Index] in ['0'..'9', 'A'..'F', 'a'..'f']) do Advance;
    if Index = DigitStart then
      RaiseLexicalError(ASourceName, 'character code requires digits',
        StartLine, StartColumn);
    AddToken(ptString);
  end;

  procedure ScanNumber;
  begin
    if ASource[Index] in ['$', '%', '&'] then
    begin
      Advance;
      while (Index <= Length(ASource))
        and (ASource[Index] in ['0'..'9', 'A'..'F', 'a'..'f']) do Advance;
      AddToken(ptNumber);
      Exit;
    end;
    while (Index <= Length(ASource)) and (ASource[Index] in ['0'..'9']) do
      Advance;
    if (Index <= Length(ASource)) and (ASource[Index] = '.')
      and ((Index = Length(ASource)) or (ASource[Index + 1] <> '.')) then
    begin
      Advance;
      while (Index <= Length(ASource)) and (ASource[Index] in ['0'..'9']) do
        Advance;
    end;
    if (Index <= Length(ASource)) and (ASource[Index] in ['E', 'e']) then
    begin
      Advance;
      if (Index <= Length(ASource)) and (ASource[Index] in ['+', '-']) then
        Advance;
      while (Index <= Length(ASource)) and (ASource[Index] in ['0'..'9']) do
        Advance;
    end;
    AddToken(ptNumber);
  end;

  procedure ScanSymbol;
  var
    Pair: string;
  begin
    Pair := Copy(ASource, Index, 2);
    if (Pair = ':=') or (Pair = '<=') or (Pair = '>=')
      or (Pair = '<>') or (Pair = '..') or (Pair = '**')
      or (Pair = '<<') or (Pair = '>>') or (Pair = '><')
      or (Pair = '(.') or (Pair = '.)') or (Pair = '+=')
      or (Pair = '-=') or (Pair = '*=') or (Pair = '/=') then
    begin
      Advance;
      Advance;
    end
    else
      Advance;
    AddToken(ptSymbol, False);
  end;

var
  Directive: Boolean;
  Value: string;
begin
  SetLength(Result, 0);
  Index := 1;
  Line := 1;
  Column := 1;
  while Index <= Length(ASource) do
  begin
    if ASource[Index] in [' ', #9, #10, #13, #12] then
    begin
      Advance;
      Continue;
    end;
    StartIndex := Index;
    StartLine := Line;
    StartColumn := Column;
    if (ASource[Index] = '/') and (Index < Length(ASource))
      and (ASource[Index + 1] = '/') then
    begin
      SkipLineComment;
      Continue;
    end;
    if ASource[Index] = '{' then
    begin
      Directive := (Index < Length(ASource)) and (ASource[Index + 1] = '$');
      ScanComment(True, Directive);
      Continue;
    end;
    if (ASource[Index] = '(') and (Index < Length(ASource))
      and (ASource[Index + 1] = '*') then
    begin
      Directive := (Index + 2 <= Length(ASource))
        and (ASource[Index + 2] = '$');
      ScanComment(False, Directive);
      Continue;
    end;
    if ASource[Index] = '''' then
    begin
      ScanString;
      Continue;
    end;
    if ASource[Index] = '#' then
    begin
      ScanCharacterCode;
      Continue;
    end;
    if (ASource[Index] in ['0'..'9', '$', '%'])
      or ((ASource[Index] = '&') and (Index < Length(ASource))
        and (ASource[Index + 1] in ['0'..'9'])) then
    begin
      ScanNumber;
      Continue;
    end;
    if IsIdentifierStart(ASource[Index])
      or ((ASource[Index] = '&') and (Index < Length(ASource))
        and IsIdentifierStart(ASource[Index + 1])) then
    begin
      if ASource[Index] = '&' then Advance;
      while (Index <= Length(ASource))
        and IsIdentifierPart(ASource[Index]) do Advance;
      Value := LowerCase(Copy(ASource, StartIndex, Index - StartIndex));
      if Value[1] = '&' then
        AddToken(ptIdentifier, True, True)
      else if IsKeyword(Value) then
        AddToken(ptKeyword)
      else
        AddToken(ptIdentifier);
      Continue;
    end;
    ScanSymbol;
  end;
end;

type
  TLWPTPascalStructureParser = class
  private
    FDocument: TLWPTPascalDocument;
    function AddRegion(const AKind: TLWPTPascalRegionKind;
      const AOwnerRoutine, AStartToken, AEndToken: Integer): Integer;
    function AddRoutine(const AKind: TLWPTPascalRoutineKind;
      const AName: string; const AParentRoutine, AHeaderStart,
      AHeaderEnd: Integer): Integer;
    function CompositeOpening(const AIndex: Integer): Boolean;
    function FindBodyEnd(const AStartToken, ALimit: Integer): Integer;
    function FindHeaderEnd(const AStartToken, ALimit: Integer): Integer;
    function ParseRoutine(const AStartToken, ALimit,
      AParentRoutine: Integer): Integer;
    procedure ParseTopDeclarations(const AStartToken, ALimit: Integer;
      const AProgram: Boolean);
    procedure Parse;
    function RoutineDeclarationAt(const AIndex, ADeclarationStart: Integer;
      out AKind: TLWPTPascalRoutineKind): Boolean;
    function RoutineKindAt(const AIndex: Integer;
      out AKind: TLWPTPascalRoutineKind): Boolean;
    function RoutineName(const AStartToken, AHeaderEnd: Integer): string;
    function TokenIs(const AIndex: Integer; const AText: string): Boolean;
  public
    constructor Create(const ASource, ASourceName: string);
    function Build: TLWPTPascalDocument;
  end;

constructor TLWPTPascalStructureParser.Create(const ASource,
  ASourceName: string);
begin
  inherited Create;
  FDocument := Default(TLWPTPascalDocument);
  FDocument.SourceName := ASourceName;
  FDocument.Tokens := TokenizePascal(ASource, ASourceName);
end;

function TLWPTPascalStructureParser.TokenIs(const AIndex: Integer;
  const AText: string): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(FDocument.Tokens))
    and (FDocument.Tokens[AIndex].Text = AText);
  if Result and (AText <> '') and IsIdentifierStart(AText[1]) then
    Result := FDocument.Tokens[AIndex].Kind = ptKeyword;
end;

function TLWPTPascalStructureParser.AddRegion(
  const AKind: TLWPTPascalRegionKind; const AOwnerRoutine, AStartToken,
  AEndToken: Integer): Integer;
begin
  if AEndToken <= AStartToken then Exit(-1);
  Result := Length(FDocument.Regions);
  SetLength(FDocument.Regions, Result + 1);
  FDocument.Regions[Result].Kind := AKind;
  FDocument.Regions[Result].OwnerRoutine := AOwnerRoutine;
  FDocument.Regions[Result].Tokens.StartToken := AStartToken;
  FDocument.Regions[Result].Tokens.EndToken := AEndToken;
end;

function TLWPTPascalStructureParser.AddRoutine(
  const AKind: TLWPTPascalRoutineKind; const AName: string;
  const AParentRoutine, AHeaderStart, AHeaderEnd: Integer): Integer;
begin
  Result := Length(FDocument.Routines);
  SetLength(FDocument.Routines, Result + 1);
  FDocument.Routines[Result] := Default(TLWPTPascalRoutine);
  FDocument.Routines[Result].Kind := AKind;
  FDocument.Routines[Result].Name := AName;
  FDocument.Routines[Result].ParentRoutine := AParentRoutine;
  FDocument.Routines[Result].Header.StartToken := AHeaderStart;
  FDocument.Routines[Result].Header.EndToken := AHeaderEnd;
  FDocument.Routines[Result].BodyRegion := -1;
end;

function TLWPTPascalStructureParser.RoutineKindAt(const AIndex: Integer;
  out AKind: TLWPTPascalRoutineKind): Boolean;
begin
  Result := True;
  if TokenIs(AIndex, 'procedure') then AKind := prProcedure
  else if TokenIs(AIndex, 'function') then AKind := prFunction
  else if TokenIs(AIndex, 'constructor') then AKind := prConstructor
  else if TokenIs(AIndex, 'destructor') then AKind := prDestructor
  else if TokenIs(AIndex, 'operator') then AKind := prOperator
  else Result := False;
end;

function TLWPTPascalStructureParser.RoutineDeclarationAt(const AIndex,
  ADeclarationStart: Integer; out AKind: TLWPTPascalRoutineKind): Boolean;
var
  TokenIndex: Integer;
begin
  Result := RoutineKindAt(AIndex, AKind);
  if not Result then Exit;
  { Procedural types reuse the routine keywords. Look only within the current
    declaration so an earlier typed constant cannot hide a later routine. }
  TokenIndex := AIndex - 1;
  while (TokenIndex >= ADeclarationStart)
    and not TokenIs(TokenIndex, ';') do
  begin
    if TokenIs(TokenIndex, '=') or TokenIs(TokenIndex, ':') then
      Exit(False);
    Dec(TokenIndex);
  end;
end;

function TLWPTPascalStructureParser.FindHeaderEnd(const AStartToken,
  ALimit: Integer): Integer;
var
  Depth, TokenIndex: Integer;
begin
  Depth := 0;
  for TokenIndex := AStartToken to ALimit - 1 do
  begin
    if TokenIs(TokenIndex, '(') or TokenIs(TokenIndex, '[') then Inc(Depth)
    else if TokenIs(TokenIndex, ')') or TokenIs(TokenIndex, ']') then
    begin
      if Depth > 0 then Dec(Depth);
    end
    else if (Depth = 0) and TokenIs(TokenIndex, ';') then
      Exit(TokenIndex + 1);
  end;
  Result := ALimit;
end;

function TLWPTPascalStructureParser.RoutineName(const AStartToken,
  AHeaderEnd: Integer): string;
var
  TokenIndex: Integer;
begin
  Result := '';
  TokenIndex := AStartToken + 1;
  while TokenIndex < AHeaderEnd do
  begin
    if TokenIs(TokenIndex, '(') or TokenIs(TokenIndex, ':')
      or TokenIs(TokenIndex, ';') then Break;
    if TokenIs(TokenIndex, '.') then Result := Result + '.'
    else if (FDocument.Tokens[TokenIndex].Kind in
      [ptIdentifier, ptKeyword, ptSymbol]) then
    begin
      if (Result <> '') and (Result[Length(Result)] <> '.') then
        Result := Result + ' ';
      Result := Result + FDocument.Tokens[TokenIndex].Text;
    end;
    Inc(TokenIndex);
  end;
end;

function TLWPTPascalStructureParser.CompositeOpening(
  const AIndex: Integer): Boolean;
begin
  if TokenIs(AIndex + 1, ';') then Exit(False);
  Result := TokenIs(AIndex, 'record') or TokenIs(AIndex, 'object')
    or TokenIs(AIndex, 'interface') or TokenIs(AIndex, 'dispinterface');
  if TokenIs(AIndex, 'class') then
    Result := not TokenIs(AIndex + 1, 'of')
      and not TokenIs(AIndex + 1, 'function')
      and not TokenIs(AIndex + 1, 'procedure')
      and not TokenIs(AIndex + 1, 'constructor')
      and not TokenIs(AIndex + 1, 'destructor')
      and not TokenIs(AIndex + 1, 'operator');
end;

function TLWPTPascalStructureParser.FindBodyEnd(const AStartToken,
  ALimit: Integer): Integer;
var
  Depth, RepeatDepth, TokenIndex: Integer;
begin
  Depth := 0;
  RepeatDepth := 0;
  for TokenIndex := AStartToken to ALimit - 1 do
  begin
    if TokenIs(TokenIndex, 'begin') or TokenIs(TokenIndex, 'case')
      or TokenIs(TokenIndex, 'try') or TokenIs(TokenIndex, 'asm') then
      Inc(Depth)
    else if TokenIs(TokenIndex, 'repeat') then
      Inc(RepeatDepth)
    else if TokenIs(TokenIndex, 'until') and (RepeatDepth > 0) then
      Dec(RepeatDepth)
    else if TokenIs(TokenIndex, 'end') then
    begin
      if Depth > 0 then Dec(Depth);
      if (Depth = 0) and (RepeatDepth = 0) then Exit(TokenIndex + 1);
    end;
  end;
  Result := ALimit;
end;

function TLWPTPascalStructureParser.ParseRoutine(const AStartToken,
  ALimit, AParentRoutine: Integer): Integer;
var
  BodyEnd, BodyStart, CompositeDepth, DeclarationStart, HeaderEnd,
    RoutineIndex, TokenIndex: Integer;
  Kind, NestedKind: TLWPTPascalRoutineKind;
begin
  Result := AStartToken + 1;
  if not RoutineKindAt(AStartToken, Kind) then Exit;
  HeaderEnd := FindHeaderEnd(AStartToken, ALimit);
  RoutineIndex := AddRoutine(Kind, RoutineName(AStartToken, HeaderEnd),
    AParentRoutine, AStartToken, HeaderEnd);
  TokenIndex := HeaderEnd;
  DeclarationStart := TokenIndex;
  CompositeDepth := 0;
  BodyStart := -1;
  while TokenIndex < ALimit do
  begin
    if (CompositeDepth = 0) and (TokenIs(TokenIndex, 'forward')
      or TokenIs(TokenIndex, 'external') or TokenIs(TokenIndex, 'abstract')) then
    begin
      while (TokenIndex < ALimit) and not TokenIs(TokenIndex, ';') do
        Inc(TokenIndex);
      if TokenIndex < ALimit then Inc(TokenIndex);
      Exit(TokenIndex);
    end;
    if CompositeOpening(TokenIndex) then Inc(CompositeDepth)
    else if TokenIs(TokenIndex, 'end') and (CompositeDepth > 0) then
      Dec(CompositeDepth)
    else if (CompositeDepth = 0) and RoutineDeclarationAt(TokenIndex,
      DeclarationStart, NestedKind) then
    begin
      AddRegion(pgRoutineDeclarations, RoutineIndex, DeclarationStart,
        TokenIndex);
      TokenIndex := ParseRoutine(TokenIndex, ALimit, RoutineIndex);
      DeclarationStart := TokenIndex;
      Continue;
    end
    else if (CompositeDepth = 0) and (TokenIs(TokenIndex, 'begin')
      or TokenIs(TokenIndex, 'asm')) then
    begin
      BodyStart := TokenIndex;
      Break;
    end;
    Inc(TokenIndex);
  end;
  if BodyStart < 0 then Exit(TokenIndex);
  AddRegion(pgRoutineDeclarations, RoutineIndex, DeclarationStart, BodyStart);
  BodyEnd := FindBodyEnd(BodyStart, ALimit);
  FDocument.Routines[RoutineIndex].BodyRegion := AddRegion(pgRoutineBody,
    RoutineIndex, BodyStart, BodyEnd);
  Result := BodyEnd;
  if TokenIs(Result, ';') then Inc(Result);
end;

procedure TLWPTPascalStructureParser.ParseTopDeclarations(
  const AStartToken, ALimit: Integer; const AProgram: Boolean);
var
  CompositeDepth, DeclarationStart, MainEnd, TokenIndex: Integer;
  Kind: TLWPTPascalRoutineKind;
begin
  CompositeDepth := 0;
  DeclarationStart := AStartToken;
  TokenIndex := AStartToken;
  while TokenIndex < ALimit do
  begin
    if CompositeOpening(TokenIndex) then Inc(CompositeDepth)
    else if TokenIs(TokenIndex, 'end') and (CompositeDepth > 0) then
      Dec(CompositeDepth)
    else if (CompositeDepth = 0) and RoutineDeclarationAt(TokenIndex,
      DeclarationStart, Kind) then
    begin
      AddRegion(pgUnitDeclarations, -1, DeclarationStart, TokenIndex);
      TokenIndex := ParseRoutine(TokenIndex, ALimit, -1);
      DeclarationStart := TokenIndex;
      Continue;
    end
    else if (CompositeDepth = 0) and TokenIs(TokenIndex, 'begin') then
    begin
      AddRegion(pgUnitDeclarations, -1, DeclarationStart, TokenIndex);
      MainEnd := FindBodyEnd(TokenIndex, ALimit);
      if AProgram then
        AddRegion(pgProgramBody, -1, TokenIndex, MainEnd)
      else
        AddRegion(pgInitialization, -1, TokenIndex, MainEnd);
      Exit;
    end;
    Inc(TokenIndex);
  end;
  AddRegion(pgUnitDeclarations, -1, DeclarationStart, ALimit);
end;

procedure TLWPTPascalStructureParser.Parse;
var
  FinalEnd, FinalizationIndex, HeaderEnd, ImplementationIndex,
    InitializationIndex, InterfaceIndex, TokenIndex: Integer;
  IsUnit: Boolean;
begin
  if Length(FDocument.Tokens) = 0 then Exit;
  IsUnit := TokenIs(0, 'unit');
  HeaderEnd := FindHeaderEnd(0, Length(FDocument.Tokens));
  if not IsUnit then
  begin
    ParseTopDeclarations(HeaderEnd, Length(FDocument.Tokens), True);
    Exit;
  end;
  InterfaceIndex := -1;
  ImplementationIndex := -1;
  InitializationIndex := -1;
  FinalizationIndex := -1;
  FinalEnd := Length(FDocument.Tokens);
  for TokenIndex := HeaderEnd to High(FDocument.Tokens) do
  begin
    if (InterfaceIndex < 0) and TokenIs(TokenIndex, 'interface') then
      InterfaceIndex := TokenIndex
    else if TokenIs(TokenIndex, 'implementation') then
      ImplementationIndex := TokenIndex
    else if TokenIs(TokenIndex, 'initialization') then
      InitializationIndex := TokenIndex
    else if TokenIs(TokenIndex, 'finalization') then
      FinalizationIndex := TokenIndex;
  end;
  for TokenIndex := High(FDocument.Tokens) downto HeaderEnd do
    if TokenIs(TokenIndex, 'end') then
    begin
      FinalEnd := TokenIndex;
      Break;
    end;
  if (InterfaceIndex >= 0) and (ImplementationIndex > InterfaceIndex) then
    AddRegion(pgUnitDeclarations, -1, InterfaceIndex + 1,
      ImplementationIndex);
  if ImplementationIndex < 0 then Exit;
  TokenIndex := FinalEnd;
  if (InitializationIndex >= 0) and (InitializationIndex < TokenIndex) then
    TokenIndex := InitializationIndex;
  if (FinalizationIndex >= 0) and (FinalizationIndex < TokenIndex) then
    TokenIndex := FinalizationIndex;
  ParseTopDeclarations(ImplementationIndex + 1, TokenIndex, False);
  if InitializationIndex >= 0 then
  begin
    if FinalizationIndex > InitializationIndex then
      AddRegion(pgInitialization, -1, InitializationIndex + 1,
        FinalizationIndex)
    else
      AddRegion(pgInitialization, -1, InitializationIndex + 1, FinalEnd);
  end;
  if FinalizationIndex >= 0 then
    AddRegion(pgFinalization, -1, FinalizationIndex + 1, FinalEnd);
end;

function TLWPTPascalStructureParser.Build: TLWPTPascalDocument;
begin
  Parse;
  Result := FDocument;
end;

function AnalyzePascal(const ASource, ASourceName: string):
  TLWPTPascalDocument;
var
  Parser: TLWPTPascalStructureParser;
begin
  Parser := TLWPTPascalStructureParser.Create(ASource, ASourceName);
  try
    Result := Parser.Build;
  finally
    Parser.Free;
  end;
end;

function PascalRegionIsExecutable(const AKind: TLWPTPascalRegionKind):
  Boolean;
begin
  Result := AKind in [pgRoutineBody, pgProgramBody, pgInitialization,
    pgFinalization];
end;

end.
