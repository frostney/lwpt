{ LWPT.Formatter — uses-clause + identifier formatter.

  The canonical entry point is FormatFile(path, mode). In rmCheck mode
  the function returns True when the file would change (without writing
  anything); in rmFormat mode it returns True after rewriting the file
  in place. The caller (LWPT.Command.Format.CmdFormat) handles file discovery
  per the manifest's [format] scope, summary stats, and exit code.

  Every pass reads the file through LWPT.Analysis.Pascal's tokenizer, the
  mode-aware lexer `lwpt health` and `lwpt duplication` share, and rewrites
  whole code tokens only. Text inside comments, compiler directives and
  string literals is therefore never rewritten, and a file the tokenizer
  cannot read is left exactly as it is. }
unit LWPT.Formatter;

{$mode delphi}{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TRunMode = (rmFormat, rmCheck);

function FormatFile(const AFilePath: string; const AMode: TRunMode): Boolean; overload;
{ As above; ASkipReason is non-empty when the file is not lexically valid
  Pascal (an unterminated comment or string) and was therefore left
  untouched. }
function FormatFile(const AFilePath: string; const AMode: TRunMode;
  out ASkipReason: string): Boolean; overload;

implementation

uses
  Generics.Collections,

  LWPT.Analysis.Pascal;

type
  TUnitCategory = (ucSystem, ucThirdParty, ucProject, ucRelative);

  { Lower-case name to text. }
  TNameMap = TDictionary<string, string>;

{ ═══════════════════════════════════════════════════════════════════════════
  Uses-Clause Formatting
  ═══════════════════════════════════════════════════════════════════════════ }

function ClassifyUnit(const AName: string): TUnitCategory;
const
  SystemUnits: array[0..20] of string = (
    'classes', 'sysutils', 'generics.collections', 'generics.defaults',
    'dateutils', 'strutils', 'math', 'typinfo', 'process', 'types',
    'windows', 'ctypes', 'unix', 'baseunix', 'crt', 'dos', 'variants',
    'syncobjs', 'contnrs', 'fgl', 'character'
  );
var
  Lower: string;
  I: Integer;
begin
  Lower := LowerCase(Trim(AName));

  if Pos(' in ', Lower) > 0 then
    Exit(ucRelative);

  for I := Low(SystemUnits) to High(SystemUnits) do
    if Lower = SystemUnits[I] then
      Exit(ucSystem);

  if Pos('goccia.', Lower) = 1 then
    Exit(ucProject);

  Result := ucThirdParty;
end;

function CompareUnitsCI(AList: TStringList; AIdx1, AIdx2: Integer): Integer;
begin
  Result := CompareText(AList[AIdx1], AList[AIdx2]);
end;

function FormatUsesClause(const AUnits: TStringList): TStringList;
const
  SectionCount = 4;
var
  Lists: array[0..SectionCount - 1] of TStringList;
  I, J, SecIdx, NonEmpty: Integer;
  IsLast: Boolean;
begin
  Result := TStringList.Create;
  for I := 0 to SectionCount - 1 do
    Lists[I] := TStringList.Create;
  try
    for I := 0 to AUnits.Count - 1 do
    begin
      case ClassifyUnit(AUnits[I]) of
        ucSystem:     Lists[0].Add(AUnits[I]);
        ucThirdParty: Lists[1].Add(AUnits[I]);
        ucProject:    Lists[2].Add(AUnits[I]);
        ucRelative:   Lists[3].Add(AUnits[I]);
      end;
    end;

    for I := 0 to SectionCount - 1 do
      Lists[I].CustomSort(@CompareUnitsCI);

    NonEmpty := 0;
    for I := 0 to SectionCount - 1 do
      if Lists[I].Count > 0 then
        Inc(NonEmpty);

    SecIdx := 0;
    for I := 0 to SectionCount - 1 do
    begin
      if Lists[I].Count = 0 then
        Continue;

      Inc(SecIdx);

      for J := 0 to Lists[I].Count - 1 do
      begin
        IsLast := (SecIdx = NonEmpty) and (J = Lists[I].Count - 1);
        if IsLast then
          Result.Add('  ' + Lists[I][J] + ';')
        else
          Result.Add('  ' + Lists[I][J] + ',');
      end;

      if SecIdx < NonEmpty then
        Result.Add('');
    end;
  finally
    for I := 0 to SectionCount - 1 do
      Lists[I].Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Lexical View
  ═══════════════════════════════════════════════════════════════════════════ }

type
  TLineIndexArray = array of Integer;

  (* The formatter's view of one file: its lines plus the shared
     tokenizer's tokens over them. Token lines and columns index the line
     list directly. Comments are not tokens at all, so no rewrite can land
     in one; directives and string literals are tokens of their own kinds
     and are never renamed. Rewrites are recorded per token and applied
     together, right to left, so every recorded column stays valid. *)
  TSourceTokens = class
  private
    FLines: TStringList;
    FTokens: TLWPTPascalTokenArray;
    FReplacements: array of string;
    FReplaced: array of Boolean;
    FSpacesBefore: array of Integer;
  public
    constructor Create(const ALines: TStringList; const ASourceName: string);
    function Count: Integer;
    function IsText(const AIndex: Integer; const AText: string): Boolean;
    function IsName(const AIndex: Integer): Boolean;
    function NameIs(const AIndex: Integer; const AName: string): Boolean;
    function Text(const AIndex: Integer): string;
    function Spelling(const AIndex: Integer): string;
    function LineIndex(const AIndex: Integer): Integer;
    function Column(const AIndex: Integer): Integer;
    function ConditionalDelta(const AIndex: Integer): Integer;
    function IsDirective(const AIndex: Integer): Boolean;
    function DirectiveWord(const AIndex: Integer; out AFollowing: Char): string;
    function IsIncludeDirective(const AIndex: Integer): Boolean;
    function IsConditionalDirective(const AIndex: Integer): Boolean;
    function IsString(const AIndex: Integer): Boolean;
    function StartsLine(const AIndex: Integer): Boolean;
    function EndsLine(const AIndex: Integer): Boolean;
    function OnlyBlanksBetween(const AFirst, ASecond: Integer): Boolean;
    procedure Replace(const AIndex: Integer; const ANewText: string);
    procedure RemoveSpacesBefore(const AIndex, ACount: Integer);
    procedure ApplyEdits;
  end;

constructor TSourceTokens.Create(const ALines: TStringList;
  const ASourceName: string);
var
  Source: string;
  Position: Integer;
begin
  inherited Create;
  FLines := ALines;
  Source := ALines.Text;
  { InstantFPC strips a script's `#!` line before compiling it; blank it
    so the tokenizer skips it too, keeping every line and column where
    it was. }
  if Copy(Source, 1, 2) = '#!' then
  begin
    Position := 1;
    while (Position <= Length(Source)) and not (Source[Position] in [#10, #13]) do
    begin
      Source[Position] := ' ';
      Inc(Position);
    end;
  end;
  FTokens := TokenizePascal(Source, ASourceName);
  SetLength(FReplacements, Length(FTokens));
  SetLength(FReplaced, Length(FTokens));
  SetLength(FSpacesBefore, Length(FTokens));
end;

function TSourceTokens.Count: Integer;
begin
  Result := Length(FTokens);
end;

{ Exact match against a keyword (lower case) or a symbol. }
function TSourceTokens.IsText(const AIndex: Integer; const AText: string): Boolean;
begin
  if (AIndex < 0) or (AIndex >= Length(FTokens)) or
     (FTokens[AIndex].Text <> AText) then
    Exit(False);
  if AText[1] in ['a'..'z'] then
    Result := FTokens[AIndex].Kind = ptKeyword
  else
    Result := FTokens[AIndex].Kind = ptSymbol;
end;

{ An identifier-shaped token. The tokenizer's keyword list includes
  directive words such as `name`, `index` and `message` that are valid
  identifiers, so keyword tokens count too; a genuinely reserved word can
  never match a declared parameter or routine name. }
function TSourceTokens.IsName(const AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(FTokens)) and
            (FTokens[AIndex].Kind in [ptIdentifier, ptKeyword]);
end;

function TSourceTokens.NameIs(const AIndex: Integer; const AName: string): Boolean;
begin
  Result := IsName(AIndex) and (FTokens[AIndex].Text = AName);
end;

function TSourceTokens.Text(const AIndex: Integer): string;
begin
  Result := FTokens[AIndex].Text;
end;

{ The token as written; identifier tokens never span lines. }
function TSourceTokens.Spelling(const AIndex: Integer): string;
begin
  Result := Copy(FLines[FTokens[AIndex].Line - 1], FTokens[AIndex].Column,
    FTokens[AIndex].Length);
end;

function TSourceTokens.LineIndex(const AIndex: Integer): Integer;
begin
  Result := FTokens[AIndex].Line - 1;
end;

function TSourceTokens.Column(const AIndex: Integer): Integer;
begin
  Result := FTokens[AIndex].Column;
end;

function TSourceTokens.ConditionalDelta(const AIndex: Integer): Integer;
begin
  Result := PascalConditionalDirectiveDelta(FTokens[AIndex]);
end;

function TSourceTokens.IsDirective(const AIndex: Integer): Boolean;
begin
  Result := FTokens[AIndex].Kind = ptDirective;
end;

{ The lower-case directive name and the character after it, or '' for a
  token that is not a directive. }
function TSourceTokens.DirectiveWord(const AIndex: Integer; out AFollowing: Char): string;
var
  Directive: string;
  Position: Integer;
begin
  Result := '';
  AFollowing := #0;
  if FTokens[AIndex].Kind <> ptDirective then
    Exit;
  Directive := LowerCase(FTokens[AIndex].Text);
  if Copy(Directive, 1, 2) = '{$' then
    Position := 3
  else
    Position := 4;
  while (Position <= Length(Directive)) and (Directive[Position] in ['a'..'z']) do
  begin
    Result := Result + Directive[Position];
    Inc(Position);
  end;
  if Position <= Length(Directive) then
    AFollowing := Directive[Position];
end;

(* `{$I file}` or `{$INCLUDE file}`, as opposed to the `{$I+}` / `{$I-}`
   switch. *)
function TSourceTokens.IsIncludeDirective(const AIndex: Integer): Boolean;
var
  Word: string;
  Following: Char;
begin
  Word := DirectiveWord(AIndex, Following);
  Result := (Word = 'include') or ((Word = 'i') and (Following in [' ', #9]));
end;

{ Any directive that opens, switches or closes a conditional block. }
function TSourceTokens.IsConditionalDirective(const AIndex: Integer): Boolean;
var
  Word: string;
  Following: Char;
begin
  Word := DirectiveWord(AIndex, Following);
  Result := (Word = 'if') or (Word = 'ifdef') or (Word = 'ifndef') or
            (Word = 'ifopt') or (Word = 'else') or (Word = 'elseif') or
            (Word = 'endif') or (Word = 'ifend');
end;

function TSourceTokens.IsString(const AIndex: Integer): Boolean;
begin
  Result := FTokens[AIndex].Kind = ptString;
end;

{ True when only blanks precede the token on its line. }
function TSourceTokens.StartsLine(const AIndex: Integer): Boolean;
begin
  Result := Trim(Copy(FLines[LineIndex(AIndex)], 1, Column(AIndex) - 1)) = '';
end;

{ True when only blanks follow the token on its line. }
function TSourceTokens.EndsLine(const AIndex: Integer): Boolean;
begin
  Result := Trim(Copy(FLines[LineIndex(AIndex)],
    Column(AIndex) + FTokens[AIndex].Length, MaxInt)) = '';
end;

{ True when nothing but blanks — in particular no comment — separates
  two consecutive tokens. }
function TSourceTokens.OnlyBlanksBetween(const AFirst, ASecond: Integer): Boolean;
var
  FirstLine, SecondLine, LineNumber: Integer;
  After: Integer;
begin
  FirstLine := LineIndex(AFirst);
  SecondLine := LineIndex(ASecond);
  After := Column(AFirst) + FTokens[AFirst].Length;
  if FirstLine = SecondLine then
    Exit(Trim(Copy(FLines[FirstLine], After, Column(ASecond) - After)) = '');
  if not EndsLine(AFirst) or not StartsLine(ASecond) then
    Exit(False);
  for LineNumber := FirstLine + 1 to SecondLine - 1 do
    if Trim(FLines[LineNumber]) <> '' then
      Exit(False);
  Result := True;
end;

procedure TSourceTokens.Replace(const AIndex: Integer; const ANewText: string);
begin
  FReplaced[AIndex] := True;
  FReplacements[AIndex] := ANewText;
end;

procedure TSourceTokens.RemoveSpacesBefore(const AIndex, ACount: Integer);
begin
  FSpacesBefore[AIndex] := ACount;
end;

procedure TSourceTokens.ApplyEdits;
var
  TokenIndex, CurrentLine, EditColumn: Integer;
  Line: string;
begin
  CurrentLine := -1;
  Line := '';
  for TokenIndex := High(FTokens) downto 0 do
  begin
    if not FReplaced[TokenIndex] and (FSpacesBefore[TokenIndex] = 0) then
      Continue;
    if LineIndex(TokenIndex) <> CurrentLine then
    begin
      if CurrentLine >= 0 then
        FLines[CurrentLine] := Line;
      CurrentLine := LineIndex(TokenIndex);
      Line := FLines[CurrentLine];
    end;
    EditColumn := Column(TokenIndex);
    if FReplaced[TokenIndex] then
    begin
      Delete(Line, EditColumn, FTokens[TokenIndex].Length);
      Insert(FReplacements[TokenIndex], Line, EditColumn);
    end;
    if FSpacesBefore[TokenIndex] > 0 then
      Delete(Line, EditColumn - FSpacesBefore[TokenIndex],
        FSpacesBefore[TokenIndex]);
  end;
  if CurrentLine >= 0 then
    FLines[CurrentLine] := Line;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Uses-Clause Pass
  ═══════════════════════════════════════════════════════════════════════════ }

{ A uses clause holds unit names, `in` paths, commas and directives. A
  word that opens a declaration or section means the clause has run
  into the code after it. }
function IsUsesClauseToken(const ASource: TSourceTokens; const AIndex: Integer): Boolean;
const
  ClauseEnders: array[0..17] of string = (
    'begin', 'class', 'const', 'constructor', 'destructor', 'end', 'exports',
    'finalization', 'function', 'implementation', 'initialization',
    'interface', 'label', 'procedure', 'resourcestring', 'threadvar',
    'type', 'var');
var
  Word: Integer;
begin
  if (AIndex >= ASource.Count) then
    Exit(False);
  if ASource.IsString(AIndex) or ASource.IsDirective(AIndex) or
     ASource.IsText(AIndex, '.') or ASource.IsText(AIndex, ',') then
    Exit(True);
  if not ASource.IsName(AIndex) then
    Exit(False);
  for Word := Low(ClauseEnders) to High(ClauseEnders) do
    if ASource.IsText(AIndex, ClauseEnders[Word]) then
      Exit(False);
  Result := True;
end;

(* For each line that starts a formattable uses clause, the line of its
   terminating semicolon; -1 elsewhere. AVerbatim marks clauses that are
   emitted exactly as written.

   The clause starts where `uses` is the first thing on its line. It is
   formattable only when a code-level semicolon closes it with nothing
   but unit names in between; an unterminated clause, or one that runs
   into other code, is left alone. A clause carrying a directive or a
   comment is emitted verbatim: reordering across an $IFDEF changes which
   units a build sees, and a comment inside the clause exists to pin a
   position ("cthreads must come first so TThread has a driver"). The
   same holds for a comment behind the terminating semicolon. *)
function FindUsesClauses(const ALines: TStringList;
  out AVerbatim: TLineIndexArray): TLineIndexArray;
var
  Source: TSourceTokens;
  TokenIndex, Terminator, Scan, StartLine: Integer;
  Verbatim: Boolean;
begin
  Result := nil;
  AVerbatim := nil;
  SetLength(Result, ALines.Count);
  SetLength(AVerbatim, ALines.Count);
  for StartLine := 0 to ALines.Count - 1 do
  begin
    Result[StartLine] := -1;
    AVerbatim[StartLine] := 0;
  end;

  Source := TSourceTokens.Create(ALines, '');
  try
    for TokenIndex := 0 to Source.Count - 1 do
    begin
      if not Source.IsText(TokenIndex, 'uses') or not Source.StartsLine(TokenIndex) then
        Continue;
      Terminator := TokenIndex + 1;
      while (Terminator < Source.Count) and IsUsesClauseToken(Source, Terminator) do
        Inc(Terminator);
      if not Source.IsText(Terminator, ';') then
        Continue;
      if (Terminator + 1 < Source.Count) and
         (Source.LineIndex(Terminator + 1) = Source.LineIndex(Terminator)) then
        Continue;

      Verbatim := not Source.EndsLine(Terminator);
      for Scan := TokenIndex to Terminator - 1 do
        if Source.IsDirective(Scan) or not Source.OnlyBlanksBetween(Scan, Scan + 1) then
          Verbatim := True;

      StartLine := Source.LineIndex(TokenIndex);
      Result[StartLine] := Source.LineIndex(Terminator);
      AVerbatim[StartLine] := Ord(Verbatim);
    end;
  finally
    Source.Free;
  end;
end;

procedure FormatUsesInLines(const AInput: TStringList; const AOutput: TStringList);
var
  I, J, K: Integer;
  UsesContent: string;
  Units, Formatted: TStringList;
  ClauseEnds, Verbatim: TLineIndexArray;
begin
  ClauseEnds := FindUsesClauses(AInput, Verbatim);
  I := 0;
  while I < AInput.Count do
  begin
    J := ClauseEnds[I];
    if J < 0 then
    begin
      AOutput.Add(AInput[I]);
      Inc(I);
      Continue;
    end;

    if Verbatim[I] <> 0 then
    begin
      for K := I to J do
        AOutput.Add(AInput[K]);
      I := J + 1;
      Continue;
    end;

    UsesContent := Trim(Copy(Trim(AInput[I]), 5, MaxInt));
    for K := I + 1 to J do
      UsesContent := UsesContent + ' ' + Trim(AInput[K]);

    Units := TStringList.Create;
    try
      while Pos(',', UsesContent) > 0 do
      begin
        Units.Add(Trim(Copy(UsesContent, 1, Pos(',', UsesContent) - 1)));
        UsesContent := Trim(Copy(UsesContent, Pos(',', UsesContent) + 1, Length(UsesContent)));
      end;
      UsesContent := Trim(UsesContent);
      if (Length(UsesContent) > 0) and (UsesContent[Length(UsesContent)] = ';') then
        UsesContent := Trim(Copy(UsesContent, 1, Length(UsesContent) - 1));
      if UsesContent <> '' then
        Units.Add(UsesContent);

      if Units.Count > 0 then
      begin
        Formatted := FormatUsesClause(Units);
        try
          AOutput.Add('uses');
          AOutput.AddStrings(Formatted);
        finally
          Formatted.Free;
        end;
      end
      else
        for K := I to J do
          AOutput.Add(AInput[K]);
    finally
      Units.Free;
    end;

    I := J + 1;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Routine Index
  ═══════════════════════════════════════════════════════════════════════════ }

type
  TRoutineBody = (rbBody, rbDeclaration, rbExternal);

  TRoutineHeader = record
    StartToken: Integer;       { the procedure/function/constructor/destructor keyword }
    NameToken: Integer;        { the name's last segment, or -1 }
    HeaderEnd: Integer;        { token after the header's terminating semicolon }
    BodyStart: Integer;        { the body's begin or asm, or -1 }
    ExtentEnd: Integer;        { token after the routine's last token }
    Parent: Integer;           { enclosing routine, or -1 }
    FirstChild: Integer;
    NextSibling: Integer;
    Key: string;               { groups a declaration with its implementation }
    Body: TRoutineBody;
    HasParameterList: Boolean;
    { Reached another header across a conditional directive before any
      body: the two may be alternative headers of one routine. }
    ConditionalHeader: Boolean;
  end;

  (* The routine headers of one file and the extent each one owns, built
     from tokens: a header split over lines, a `forward` or `external`
     directive on a later line, and a `begin` on the header's own line
     are all found.

     A header owns a body only when a `begin` or `asm` follows it before
     anything that closes a declaration list — a class, record or object
     `end`, a unit section keyword, a class member keyword, or the end of
     the file. Headers inside types, in a unit's interface section, and
     forward, abstract or external headers therefore own no body. When a
     body sits in one branch of a conditional block, the extent runs to
     the block's closing directive so every alternative body belongs to
     the routine.

     Key joins a declaration with its implementation: `tfoo.bar` for a
     method (from `TFoo.Bar` or from `Bar` declared inside `TFoo`) and
     the bare name otherwise. FPC rejects an implementation whose
     parameter names differ from its declaration's, so a rename is
     applied to every header of a key or to none. *)

  { One header still looking for its body. }
  TParseFrame = record
    Routine: Integer;
    Depth: Integer;              { types opened in its declaration list }
    Names: array of string;      { their names, innermost last }
    Qualifier: string;
    { A header reached inside another header's declaration list: when it
      meets the end of that list, so does the enclosing header. }
    SharesDeclarationList: Boolean;
  end;

  TRoutineIndex = class
  private
    FSource: TSourceTokens;
    FRoutines: array of TRoutineHeader;
    FCount: Integer;
    FLastChild: array of Integer;
    function AddRoutine(const AStartToken, AParent: Integer;
      const AQualifier: string): Integer;
    function CompositeName(const AIndex: Integer): string;
    function CompositeOpening(const AIndex: Integer): Boolean;
    function EndsDeclarationList(const AIndex: Integer): Boolean;
    function ExtendConditionalBody(const AHeaderEnd, ABodyEnd: Integer): Integer;
    function FindHeaderEnd(const AStartToken: Integer): Integer;
    function MatchingClose(const AOpenToken: Integer): Integer;
    function ParseRoutines(const AStartToken: Integer; const AQualifier: string): Integer;
  public
    constructor Create(const ASource: TSourceTokens);
    function Count: Integer;
    function Routine(const AIndex: Integer): TRoutineHeader;
    function IsRoutineHeaderAt(const AIndex: Integer): Boolean;
    function FindBlockEnd(const AStartToken: Integer): Integer;
  end;

const
  NoRoutine = -1;
  { Blocks every parameter of a routine key; never a Pascal name. }
  AllNames = '*';

constructor TRoutineIndex.Create(const ASource: TSourceTokens);
var
  TokenIndex, Depth: Integer;
  Names: array of string;
begin
  inherited Create;
  FSource := ASource;
  Names := nil;
  Depth := 0;
  TokenIndex := 0;
  while TokenIndex < FSource.Count do
  begin
    if IsRoutineHeaderAt(TokenIndex) then
    begin
      if Depth > 0 then
        TokenIndex := ParseRoutines(TokenIndex, Names[Depth - 1])
      else
        TokenIndex := ParseRoutines(TokenIndex, '');
      Continue;
    end;
    if CompositeOpening(TokenIndex) then
    begin
      Inc(Depth);
      SetLength(Names, Depth);
      Names[Depth - 1] := CompositeName(TokenIndex);
    end
    else if FSource.IsText(TokenIndex, 'end') and (Depth > 0) then
      Dec(Depth);
    Inc(TokenIndex);
  end;
end;

function TRoutineIndex.Count: Integer;
begin
  Result := FCount;
end;

function TRoutineIndex.Routine(const AIndex: Integer): TRoutineHeader;
begin
  Result := FRoutines[AIndex];
end;

function TRoutineIndex.MatchingClose(const AOpenToken: Integer): Integer;
var
  Depth: Integer;
begin
  Depth := 0;
  Result := AOpenToken;
  while Result < FSource.Count do
  begin
    if FSource.IsText(Result, '(') or FSource.IsText(Result, '[') then
      Inc(Depth)
    else if FSource.IsText(Result, ')') or FSource.IsText(Result, ']') then
    begin
      Dec(Depth);
      if Depth = 0 then
        Exit;
    end;
    Inc(Result);
  end;
end;

{ `procedure`, `function`, `constructor` or `destructor` starting a
  routine declaration. A procedural type or a routine-typed parameter
  reuses the keywords behind `=` or `:`; the look-back stops where the
  current declaration begins. }
function TRoutineIndex.IsRoutineHeaderAt(const AIndex: Integer): Boolean;
var
  Previous: Integer;
begin
  if not (FSource.IsText(AIndex, 'procedure') or FSource.IsText(AIndex, 'function') or
          FSource.IsText(AIndex, 'constructor') or FSource.IsText(AIndex, 'destructor')) then
    Exit(False);
  Previous := AIndex - 1;
  while Previous >= 0 do
  begin
    if FSource.IsText(Previous, ';') or FSource.IsText(Previous, 'class') or
       FSource.IsText(Previous, 'object') or FSource.IsText(Previous, 'record') or
       FSource.IsText(Previous, 'interface') or FSource.IsText(Previous, 'implementation') or
       FSource.IsText(Previous, 'private') or FSource.IsText(Previous, 'protected') or
       FSource.IsText(Previous, 'public') or FSource.IsText(Previous, 'published') then
      Break;
    if FSource.IsText(Previous, '=') or FSource.IsText(Previous, ':') then
      Exit(False);
    Dec(Previous);
  end;
  Result := True;
end;

{ A type definition that opens a member list closed by `end`. }
function TRoutineIndex.CompositeOpening(const AIndex: Integer): Boolean;
var
  Previous, Close: Integer;
begin
  if FSource.IsText(AIndex, 'record') then
    Exit(True);
  if not (FSource.IsText(AIndex, 'class') or FSource.IsText(AIndex, 'object') or
          FSource.IsText(AIndex, 'interface') or
          FSource.IsText(AIndex, 'dispinterface')) then
    Exit(False);
  Previous := AIndex - 1;
  if FSource.IsText(Previous, 'packed') then
    Dec(Previous);
  if not FSource.IsText(Previous, '=') then
    Exit(False);
  if FSource.IsText(AIndex + 1, ';') or FSource.IsText(AIndex + 1, 'of') then
    Exit(False);
  if FSource.IsText(AIndex + 1, '(') then
  begin
    { `TFoo = class(TBase);` is complete without a member list. }
    Close := MatchingClose(AIndex + 1);
    if FSource.IsText(Close + 1, ';') then
      Exit(False);
  end;
  Result := True;
end;

{ The lower-case name of the type a composite opening defines. }
function TRoutineIndex.CompositeName(const AIndex: Integer): string;
var
  Previous, Depth: Integer;
begin
  Result := '';
  Previous := AIndex - 1;
  if FSource.IsText(Previous, 'packed') then
    Dec(Previous);
  Dec(Previous);
  if FSource.IsText(Previous, '>') then
  begin
    Depth := 0;
    while Previous >= 0 do
    begin
      if FSource.IsText(Previous, '>') then
        Inc(Depth)
      else if FSource.IsText(Previous, '<') then
      begin
        Dec(Depth);
        if Depth = 0 then
          Break;
      end;
      Dec(Previous);
    end;
    Dec(Previous);
  end;
  if FSource.IsName(Previous) then
    Result := FSource.Text(Previous);
end;

function TRoutineIndex.EndsDeclarationList(const AIndex: Integer): Boolean;
begin
  Result := FSource.IsText(AIndex, 'end') or
            FSource.IsText(AIndex, 'implementation') or
            FSource.IsText(AIndex, 'initialization') or
            FSource.IsText(AIndex, 'finalization') or
            FSource.IsText(AIndex, 'property') or
            (FSource.IsText(AIndex, 'interface') and not FSource.IsText(AIndex - 1, '=')) or
            (FSource.IsText(AIndex, 'class') and
             (FSource.IsText(AIndex + 1, 'procedure') or FSource.IsText(AIndex + 1, 'function') or
              FSource.IsText(AIndex + 1, 'constructor') or FSource.IsText(AIndex + 1, 'destructor') or
              FSource.IsText(AIndex + 1, 'operator') or FSource.IsText(AIndex + 1, 'var') or
              FSource.IsText(AIndex + 1, 'threadvar') or FSource.IsText(AIndex + 1, 'property')));
end;

function TRoutineIndex.FindHeaderEnd(const AStartToken: Integer): Integer;
var
  Depth: Integer;
begin
  Depth := 0;
  Result := AStartToken + 1;
  while Result < FSource.Count do
  begin
    if FSource.IsText(Result, '(') or FSource.IsText(Result, '[') then
      Inc(Depth)
    else if FSource.IsText(Result, ')') or FSource.IsText(Result, ']') then
    begin
      if Depth > 0 then
        Dec(Depth);
    end
    else if (Depth = 0) and FSource.IsText(Result, ';') then
      Exit(Result + 1);
    Inc(Result);
  end;
end;

{ Token after the `end` that closes the block opened at AStartToken. }
function TRoutineIndex.FindBlockEnd(const AStartToken: Integer): Integer;
var
  Depth, RepeatDepth: Integer;
begin
  Depth := 0;
  RepeatDepth := 0;
  Result := AStartToken;
  while Result < FSource.Count do
  begin
    if FSource.IsText(Result, 'begin') or FSource.IsText(Result, 'case') or
       FSource.IsText(Result, 'try') or FSource.IsText(Result, 'asm') then
      Inc(Depth)
    else if FSource.IsText(Result, 'repeat') then
      Inc(RepeatDepth)
    else if FSource.IsText(Result, 'until') and (RepeatDepth > 0) then
      Dec(RepeatDepth)
    else if FSource.IsText(Result, 'end') then
    begin
      if Depth > 0 then
        Dec(Depth);
      if (Depth = 0) and (RepeatDepth = 0) then
        Exit(Result + 1);
    end;
    Inc(Result);
  end;
end;

{ A body that ends inside an open conditional block is one alternative;
  the routine's extent then runs to the block's closing directive. A
  routine header before that point means the block is not a set of
  alternative bodies, and the extent stays at the first body. }
function TRoutineIndex.ExtendConditionalBody(const AHeaderEnd, ABodyEnd: Integer): Integer;
var
  Depth, TokenIndex: Integer;
begin
  Result := ABodyEnd;
  Depth := 0;
  for TokenIndex := AHeaderEnd to ABodyEnd - 1 do
    Inc(Depth, FSource.ConditionalDelta(TokenIndex));
  if Depth <= 0 then
    Exit;
  TokenIndex := ABodyEnd;
  while (TokenIndex < FSource.Count) and (Depth > 0) do
  begin
    if IsRoutineHeaderAt(TokenIndex) then
      Exit;
    Inc(Depth, FSource.ConditionalDelta(TokenIndex));
    Inc(TokenIndex);
  end;
  Result := TokenIndex;
end;

function TRoutineIndex.AddRoutine(const AStartToken, AParent: Integer;
  const AQualifier: string): Integer;
var
  TokenIndex, AngleDepth: Integer;
  Segments: TStringList;
  Header: TRoutineHeader;
begin
  Header := Default(TRoutineHeader);
  Header.StartToken := AStartToken;
  Header.HeaderEnd := FindHeaderEnd(AStartToken);
  Header.BodyStart := -1;
  Header.ExtentEnd := Header.HeaderEnd;
  Header.Parent := AParent;
  Header.FirstChild := NoRoutine;
  Header.NextSibling := NoRoutine;
  Header.NameToken := -1;
  Header.Body := rbDeclaration;

  Segments := TStringList.Create;
  try
    AngleDepth := 0;
    TokenIndex := AStartToken + 1;
    while TokenIndex < Header.HeaderEnd do
    begin
      if FSource.IsText(TokenIndex, '<') then
        Inc(AngleDepth)
      else if FSource.IsText(TokenIndex, '>') then
        Dec(AngleDepth)
      else if AngleDepth = 0 then
      begin
        if FSource.IsText(TokenIndex, '(') then
        begin
          Header.HasParameterList := True;
          Break;
        end;
        if FSource.IsText(TokenIndex, ':') or FSource.IsText(TokenIndex, ';') then
          Break;
        if FSource.IsName(TokenIndex) then
        begin
          Segments.Add(FSource.Text(TokenIndex));
          Header.NameToken := TokenIndex;
        end;
      end;
      Inc(TokenIndex);
    end;
    if Segments.Count >= 2 then
      Header.Key := Segments[Segments.Count - 2] + '.' + Segments[Segments.Count - 1]
    else if Segments.Count = 1 then
    begin
      if AQualifier <> '' then
        Header.Key := AQualifier + '.' + Segments[0]
      else
        Header.Key := Segments[0];
    end;
  finally
    Segments.Free;
  end;

  if FCount = Length(FRoutines) then
  begin
    SetLength(FRoutines, FCount * 2 + 16);
    SetLength(FLastChild, Length(FRoutines));
  end;
  Result := FCount;
  FRoutines[Result] := Header;
  FLastChild[Result] := NoRoutine;
  Inc(FCount);
  if AParent <> NoRoutine then
  begin
    if FLastChild[AParent] = NoRoutine then
      FRoutines[AParent].FirstChild := Result
    else
      FRoutines[FLastChild[AParent]].NextSibling := Result;
    FLastChild[AParent] := Result;
  end;
end;

(* Parses the header at AStartToken together with every header reached
   before it finds its body or its declaration list ends, and returns the
   token to resume at. A header reached in another header's declaration
   list is nested in it if that header finds a body, and a sibling in the
   same list (an interface section, a class) if the list ends first. The
   open headers are kept on an explicit stack: a long run of declarations
   is one chain of unfinished headers, and recursing per header would
   need stack space in proportion to it. *)
function TRoutineIndex.ParseRoutines(const AStartToken: Integer;
  const AQualifier: string): Integer;
var
  Frames: array of TParseFrame;
  Top, TokenIndex, BodyEnd: Integer;

  procedure Push(const AHeaderToken, AParent: Integer; const AFrameQualifier: string;
    const AShares: Boolean);
  begin
    Inc(Top);
    if Top >= Length(Frames) then
      SetLength(Frames, Top * 2 + 8);
    Frames[Top] := Default(TParseFrame);
    Frames[Top].Routine := AddRoutine(AHeaderToken, AParent, AFrameQualifier);
    Frames[Top].Qualifier := AFrameQualifier;
    Frames[Top].SharesDeclarationList := AShares;
    TokenIndex := FRoutines[Frames[Top].Routine].HeaderEnd;
  end;

var
  Current, Scan: Integer;
  Shares, Crossed: Boolean;
begin
  Frames := nil;
  Top := -1;
  Push(AStartToken, NoRoutine, AQualifier, False);
  while (Top >= 0) and (TokenIndex < FSource.Count) do
  begin
    if Frames[Top].Depth = 0 then
    begin
      if FSource.IsText(TokenIndex, 'forward') or FSource.IsText(TokenIndex, 'abstract') or
         FSource.IsText(TokenIndex, 'external') then
      begin
        if FSource.IsText(TokenIndex, 'external') then
          FRoutines[Frames[Top].Routine].Body := rbExternal;
        while (TokenIndex < FSource.Count) and not FSource.IsText(TokenIndex, ';') do
          Inc(TokenIndex);
        Inc(TokenIndex);
        Dec(Top);
        Continue;
      end;
      if EndsDeclarationList(TokenIndex) then
      begin
        { The list ends for this header and every header sharing it; the
          token is then read again by whatever scan encloses them. }
        repeat
          Shares := Frames[Top].SharesDeclarationList;
          Dec(Top);
        until (Top < 0) or not Shares;
        Continue;
      end;
      if IsRoutineHeaderAt(TokenIndex) then
      begin
        Current := Frames[Top].Routine;
        Crossed := False;
        for Scan := FRoutines[Current].HeaderEnd to TokenIndex - 1 do
          if FSource.IsConditionalDirective(Scan) then
            Crossed := True;
        Push(TokenIndex, Current, Frames[Top].Qualifier, True);
        if Crossed then
        begin
          FRoutines[Current].ConditionalHeader := True;
          FRoutines[Frames[Top].Routine].ConditionalHeader := True;
        end;
        Continue;
      end;
      if FSource.IsText(TokenIndex, 'begin') or FSource.IsText(TokenIndex, 'asm') then
      begin
        BodyEnd := FindBlockEnd(TokenIndex);
        Current := Frames[Top].Routine;
        FRoutines[Current].Body := rbBody;
        FRoutines[Current].BodyStart := TokenIndex;
        FRoutines[Current].ExtentEnd :=
          ExtendConditionalBody(FRoutines[Current].HeaderEnd, BodyEnd);
        TokenIndex := FRoutines[Current].ExtentEnd;
        if FSource.IsText(TokenIndex, ';') then
          Inc(TokenIndex);
        Dec(Top);
        Continue;
      end;
    end
    else if IsRoutineHeaderAt(TokenIndex) then
    begin
      { A member of a type declared in this declaration list. }
      Push(TokenIndex, NoRoutine, Frames[Top].Names[Frames[Top].Depth - 1], False);
      Continue;
    end;

    if CompositeOpening(TokenIndex) then
    begin
      Inc(Frames[Top].Depth);
      SetLength(Frames[Top].Names, Frames[Top].Depth);
      Frames[Top].Names[Frames[Top].Depth - 1] := CompositeName(TokenIndex);
    end
    else if FSource.IsText(TokenIndex, 'end') and (Frames[Top].Depth > 0) then
      Dec(Frames[Top].Depth);
    Inc(TokenIndex);
  end;
  { Headers still open at the end of the file own no body. }
  Result := TokenIndex;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Naming Helpers
  ═══════════════════════════════════════════════════════════════════════════ }

type
  { One parameter rename: the declared name (lower case) and its A-prefixed form. }
  TRenamePair = record
    OldName: string;
    NewName: string;
  end;
  TRenamePairArray = array of TRenamePair;

function IsModifier(const AWord: string): Boolean;
begin
  Result := (AWord = 'const') or (AWord = 'var') or (AWord = 'out') or (AWord = 'constref');
end;

function HasAPrefix(const AName: string): Boolean;
begin
  Result := (Length(AName) > 1) and (AName[1] = 'A') and (AName[2] in ['A'..'Z']);
end;

function IsPascalKeyword(const AWord: string): Boolean;
const
  Keywords: array[0..14] of string = (
    'as', 'at', 'do', 'if', 'in', 'is', 'of', 'on', 'or', 'to',
    'and', 'end', 'for', 'not', 'set'
 );
var
  Lower: string;
  I: Integer;
begin
  Lower := LowerCase(AWord);
  for I := Low(Keywords) to High(Keywords) do
    if Lower = Keywords[I] then
      Exit(True);
  Result := False;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: PascalCase Function Names
  ═══════════════════════════════════════════════════════════════════════════ }

function FixFuncNames(const ALines: TStringList): Boolean;
var
  Source: TSourceTokens;
  Index: TRoutineIndex;
  Names: TNameMap;
  RoutineIndex, TokenIndex: Integer;
  Header: TRoutineHeader;
  Name, NewName: string;
begin
  Result := False;
  Source := TSourceTokens.Create(ALines, '');
  Index := TRoutineIndex.Create(Source);
  Names := TNameMap.Create;
  try
    for RoutineIndex := 0 to Index.Count - 1 do
    begin
      Header := Index.Routine(RoutineIndex);
      if (Header.Body = rbExternal) or (Header.NameToken < 0) then
        Continue;
      Name := Source.Spelling(Header.NameToken);
      if (Name[1] in ['a'..'z']) and not Names.ContainsKey(LowerCase(Name)) then
        Names.Add(LowerCase(Name), UpCase(Name[1]) + Copy(Name, 2, MaxInt));
    end;
    if Names.Count = 0 then
      Exit;

    TokenIndex := 0;
    while TokenIndex < Source.Count do
    begin
      if Source.IsText(TokenIndex, 'asm') then
      begin
        TokenIndex := Index.FindBlockEnd(TokenIndex);
        Continue;
      end;
      if Source.IsName(TokenIndex) and not Source.IsText(TokenIndex - 1, '.') and
         Names.TryGetValue(Source.Text(TokenIndex), NewName) then
      begin
        Source.Replace(TokenIndex, NewName);
        Result := True;
      end;
      Inc(TokenIndex);
    end;
    Source.ApplyEdits;
  finally
    Names.Free;
    Index.Free;
    Source.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: Parameter A Prefix
  ═══════════════════════════════════════════════════════════════════════════ }

type
  (* Plans the parameter A-prefix fix over one file. A parameter is renamed
     in every header of its routine and in the bodies those headers own,
     or nowhere. Binding is established conservatively; a routine is left
     untouched when:
       - any of its headers is external (out of scope), or it contains
         assembler, whose operands the formatter cannot tell from
         registers, or an include directive, whose file it cannot see;
       - its conditional directives do not balance within its extent,
         a header has alternatives in conditional branches, or a
         directive sits inside a parameter list;
       - the old name appears in its own declaration part (a record
         field, an `absolute` alias) or names a nested routine, or a
         parameter is spelled like its routine;
       - the new name already appears anywhere the parameter is visible;
       - an implementation omits the parameter list a declaration gives,
         or another header spells the parameter with its prefix already.
     A nested routine that redeclares the old name keeps its own binding
     and is excluded from the outer rename. *)
  TParameterRenamer = class
  private
    FSource: TSourceTokens;
    FIndex: TRoutineIndex;
    FParameters: array of TRenamePairArray;
    FBlocked: TStringList;
    FExcluded: TLineIndexArray;
    FExcludedCount: Integer;
    function BlockKey(const AKey, AOldName: string): string;
    procedure Block(const AKey, AOldName: string);
    function IsBlocked(const AKey, AOldName: string): Boolean;
    function NameOccurs(const AName: string; const AFirst, ALast: Integer): Boolean;
    function OwnDeclarationsMention(const ARoutine: Integer; const AName: string): Boolean;
    function RoutineIsSafe(const ARoutine: Integer): Boolean;
    function CollectScope(const ARoutine: Integer; const AName: string): Boolean;
    function BodyRenameIsSafe(const ARoutine: Integer; const APair: TRenamePair): Boolean;
    procedure BlockOmittedParameterLists;
    procedure RenameRange(const AFirst, ALast: Integer; const APair: TRenamePair);
    function HeaderParameters(const ARoutine: Integer): TRenamePairArray;
  public
    constructor Create(const ASource: TSourceTokens; const AIndex: TRoutineIndex);
    destructor Destroy; override;
    function Apply: Boolean;
  end;

constructor TParameterRenamer.Create(const ASource: TSourceTokens;
  const AIndex: TRoutineIndex);
begin
  inherited Create;
  FSource := ASource;
  FIndex := AIndex;
  FBlocked := TStringList.Create;
  FBlocked.Sorted := True;
  FBlocked.Duplicates := dupIgnore;
end;

destructor TParameterRenamer.Destroy;
begin
  FBlocked.Free;
  inherited Destroy;
end;

function TParameterRenamer.BlockKey(const AKey, AOldName: string): string;
begin
  Result := AKey + '|' + AOldName;
end;

procedure TParameterRenamer.Block(const AKey, AOldName: string);
begin
  FBlocked.Add(BlockKey(AKey, AOldName));
end;

function TParameterRenamer.IsBlocked(const AKey, AOldName: string): Boolean;
begin
  Result := (FBlocked.IndexOf(BlockKey(AKey, AllNames)) >= 0) or
            (FBlocked.IndexOf(BlockKey(AKey, AOldName)) >= 0);
end;

function TParameterRenamer.NameOccurs(const AName: string;
  const AFirst, ALast: Integer): Boolean;
var
  TokenIndex: Integer;
begin
  for TokenIndex := AFirst to ALast - 1 do
    if FSource.NameIs(TokenIndex, AName) then
      Exit(True);
  Result := False;
end;

{ Whether AName appears in the routine's own declaration part, outside
  the routines nested there. }
function TParameterRenamer.OwnDeclarationsMention(const ARoutine: Integer;
  const AName: string): Boolean;
var
  Header, Child: TRoutineHeader;
  TokenIndex, ChildIndex: Integer;
begin
  Header := FIndex.Routine(ARoutine);
  if Header.BodyStart < 0 then
    Exit(False);
  TokenIndex := Header.HeaderEnd;
  ChildIndex := Header.FirstChild;
  while TokenIndex < Header.BodyStart do
  begin
    if ChildIndex <> NoRoutine then
    begin
      Child := FIndex.Routine(ChildIndex);
      if TokenIndex >= Child.StartToken then
      begin
        TokenIndex := Child.ExtentEnd;
        ChildIndex := Child.NextSibling;
        Continue;
      end;
    end;
    if FSource.NameIs(TokenIndex, AName) then
      Exit(True);
    Inc(TokenIndex);
  end;
  Result := False;
end;

function TParameterRenamer.RoutineIsSafe(const ARoutine: Integer): Boolean;
var
  Header: TRoutineHeader;
  TokenIndex, Depth: Integer;
begin
  Header := FIndex.Routine(ARoutine);
  Depth := 0;
  for TokenIndex := Header.StartToken to Header.ExtentEnd - 1 do
  begin
    if FSource.IsText(TokenIndex, 'asm') or FSource.IsText(TokenIndex, 'assembler') or
       FSource.IsIncludeDirective(TokenIndex) then
      Exit(False);
    Inc(Depth, FSource.ConditionalDelta(TokenIndex));
    if Depth < 0 then
      Exit(False);
  end;
  Result := Depth = 0;
end;

(* Walks the routines nested in ARoutine and records, in FExcluded, the
   extent of every one that redeclares AName — in its header or its own
   declaration part — so it keeps its own binding. Returns False when a
   nested routine is itself named AName: inside the enclosing body the
   name then refers to that routine, not to the parameter. *)
function TParameterRenamer.CollectScope(const ARoutine: Integer; const AName: string): Boolean;
var
  ChildIndex: Integer;
  Child: TRoutineHeader;
begin
  ChildIndex := FIndex.Routine(ARoutine).FirstChild;
  while ChildIndex <> NoRoutine do
  begin
    Child := FIndex.Routine(ChildIndex);
    if FSource.NameIs(Child.NameToken, AName) then
      Exit(False);
    if NameOccurs(AName, Child.StartToken, Child.HeaderEnd) or
       OwnDeclarationsMention(ChildIndex, AName) then
    begin
      if FExcludedCount + 2 > Length(FExcluded) then
        SetLength(FExcluded, FExcludedCount * 2 + 8);
      FExcluded[FExcludedCount] := Child.StartToken;
      FExcluded[FExcludedCount + 1] := Child.ExtentEnd;
      Inc(FExcludedCount, 2);
    end
    else if not CollectScope(ChildIndex, AName) then
      Exit(False);
    ChildIndex := Child.NextSibling;
  end;
  Result := True;
end;

function TParameterRenamer.BodyRenameIsSafe(const ARoutine: Integer;
  const APair: TRenamePair): Boolean;
var
  Header: TRoutineHeader;
begin
  Header := FIndex.Routine(ARoutine);
  FExcludedCount := 0;
  Result := not NameOccurs(LowerCase(APair.NewName), Header.StartToken, Header.ExtentEnd) and
            not OwnDeclarationsMention(ARoutine, APair.OldName) and
            CollectScope(ARoutine, APair.OldName);
end;

(* Delphi mode lets an implementation omit the parameter list its
  declaration gives; its body then uses names only the declaration shows.
  When a key has a declaration with parameters and more parameterless
  bodies than parameterless declarations, some body may be such an
  implementation, and none of the key's parameters are renamed. A
  parameterless overload that has only a body is no such case. *)
procedure TParameterRenamer.BlockOmittedParameterLists;

  function Occurrences(const ATally: string; const AMark: Char): Integer;
  var
    Position: Integer;
  begin
    Result := 0;
    for Position := 1 to Length(ATally) do
      if ATally[Position] = AMark then
        Inc(Result);
  end;

var
  Counts: TNameMap;
  RoutineIndex: Integer;
  Header: TRoutineHeader;
  Tally, Existing: string;
  Entry: TPair<string, string>;
begin
  Counts := TNameMap.Create;
  try
    for RoutineIndex := 0 to FIndex.Count - 1 do
    begin
      { Q: a declaration with a parameter list; D: one without; B: a body
        without one. A body with a parameter list needs no tally. }
      Header := FIndex.Routine(RoutineIndex);
      if Header.Body = rbBody then
      begin
        if Header.HasParameterList then
          Continue;
        Tally := 'B';
      end
      else if Header.HasParameterList then
        Tally := 'Q'
      else
        Tally := 'D';
      if Counts.TryGetValue(Header.Key, Existing) then
        Counts.AddOrSetValue(Header.Key, Existing + Tally)
      else
        Counts.Add(Header.Key, Tally);
    end;
    for Entry in Counts do
      if (Occurrences(Entry.Value, 'Q') > 0) and
         (Occurrences(Entry.Value, 'B') > Occurrences(Entry.Value, 'D')) then
        Block(Entry.Key, AllNames);
  finally
    Counts.Free;
  end;
end;

procedure TParameterRenamer.RenameRange(const AFirst, ALast: Integer;
  const APair: TRenamePair);
var
  TokenIndex, Excluded: Integer;
begin
  TokenIndex := AFirst;
  Excluded := 0;
  while TokenIndex < ALast do
  begin
    if (Excluded < FExcludedCount) and (TokenIndex >= FExcluded[Excluded]) then
    begin
      TokenIndex := FExcluded[Excluded + 1];
      Inc(Excluded, 2);
      Continue;
    end;
    if FSource.NameIs(TokenIndex, APair.OldName) and
       not FSource.IsText(TokenIndex - 1, '.') then
      FSource.Replace(TokenIndex, APair.NewName);
    Inc(TokenIndex);
  end;
end;

(* Every parameter a header declares. A renameable one — two or more
   letters, no A prefix yet, not Self, and not one whose prefixed form is
   a keyword — carries its new name; any other carries an empty one, so
   a header that spells the same parameter differently (`aValue` here,
   `AValue` there, which FPC treats as one name) blocks the rename for
   all of them. A parameter list containing a directive has alternatives
   the formatter cannot read, and blocks every rename for the routine. *)
function TParameterRenamer.HeaderParameters(const ARoutine: Integer): TRenamePairArray;
var
  Header: TRoutineHeader;
  Open, Close, TokenIndex, Depth, Count, Existing: Integer;
  InNames, GroupStart, Duplicate: Boolean;
  Spelling, NewName: string;
begin
  Result := nil;
  Header := FIndex.Routine(ARoutine);
  if not Header.HasParameterList then
    Exit;
  Open := Header.StartToken + 1;
  while not FSource.IsText(Open, '(') do
    Inc(Open);
  Close := FIndex.MatchingClose(Open);
  for TokenIndex := Open + 1 to Close - 1 do
    if FSource.IsDirective(TokenIndex) then
    begin
      Block(Header.Key, AllNames);
      Exit;
    end;

  Count := 0;
  Depth := 0;
  InNames := True;
  GroupStart := True;
  for TokenIndex := Open + 1 to Close - 1 do
  begin
    if FSource.IsText(TokenIndex, '(') or FSource.IsText(TokenIndex, '[') then
      Inc(Depth)
    else if FSource.IsText(TokenIndex, ')') or FSource.IsText(TokenIndex, ']') then
      Dec(Depth);
    if Depth > 0 then
      Continue;
    if FSource.IsText(TokenIndex, ';') then
    begin
      InNames := True;
      GroupStart := True;
      Continue;
    end;
    if FSource.IsText(TokenIndex, ':') or FSource.IsText(TokenIndex, '=') then
      InNames := False;
    if not InNames or not FSource.IsName(TokenIndex) then
      Continue;
    if GroupStart and IsModifier(FSource.Text(TokenIndex)) and
       FSource.IsName(TokenIndex + 1) then
    begin
      GroupStart := False;
      Continue;
    end;
    GroupStart := False;

    Spelling := FSource.Spelling(TokenIndex);
    NewName := 'A' + UpCase(Spelling[1]) + Copy(Spelling, 2, MaxInt);
    if (LowerCase(Spelling) = 'self') or (Length(Spelling) < 2) or
       HasAPrefix(Spelling) or IsPascalKeyword(NewName) then
      NewName := '';
    Duplicate := False;
    for Existing := 0 to Count - 1 do
      if Result[Existing].OldName = LowerCase(Spelling) then
        Duplicate := True;
    if Duplicate then
      Continue;
    SetLength(Result, Count + 1);
    Result[Count].OldName := LowerCase(Spelling);
    Result[Count].NewName := NewName;
    Inc(Count);
  end;
end;

function TParameterRenamer.Apply: Boolean;
var
  RoutineIndex, PairIndex: Integer;
  Header: TRoutineHeader;
  Pair: TRenamePair;
begin
  Result := False;
  SetLength(FParameters, FIndex.Count);
  for RoutineIndex := 0 to FIndex.Count - 1 do
    FParameters[RoutineIndex] := HeaderParameters(RoutineIndex);

  BlockOmittedParameterLists;
  for RoutineIndex := 0 to FIndex.Count - 1 do
  begin
    Header := FIndex.Routine(RoutineIndex);
    if (Header.Body = rbExternal) or Header.ConditionalHeader or
       ((Header.Body = rbBody) and not RoutineIsSafe(RoutineIndex)) then
    begin
      for PairIndex := 0 to High(FParameters[RoutineIndex]) do
        Block(Header.Key, FParameters[RoutineIndex][PairIndex].OldName);
      Continue;
    end;
    for PairIndex := 0 to High(FParameters[RoutineIndex]) do
    begin
      Pair := FParameters[RoutineIndex][PairIndex];
      { A parameter spelled like its routine makes every mention of the
        name ambiguous. }
      if (Pair.NewName = '') or FSource.NameIs(Header.NameToken, Pair.OldName) then
        Block(Header.Key, Pair.OldName)
      else if Header.Body = rbBody then
      begin
        if not BodyRenameIsSafe(RoutineIndex, Pair) then
          Block(Header.Key, Pair.OldName);
      end
      else if NameOccurs(LowerCase(Pair.NewName), Header.StartToken, Header.HeaderEnd) then
        Block(Header.Key, Pair.OldName);
    end;
  end;

  for RoutineIndex := 0 to FIndex.Count - 1 do
  begin
    Header := FIndex.Routine(RoutineIndex);
    for PairIndex := 0 to High(FParameters[RoutineIndex]) do
    begin
      Pair := FParameters[RoutineIndex][PairIndex];
      if (Pair.NewName = '') or IsBlocked(Header.Key, Pair.OldName) then
        Continue;
      Result := True;
      if Header.Body = rbBody then
      begin
        BodyRenameIsSafe(RoutineIndex, Pair);
        RenameRange(Header.StartToken, Header.ExtentEnd, Pair);
      end
      else
      begin
        FExcludedCount := 0;
        RenameRange(Header.StartToken, Header.HeaderEnd, Pair);
      end;
    end;
  end;
end;

function FixParamNames(const ALines: TStringList): Boolean;
var
  Source: TSourceTokens;
  Index: TRoutineIndex;
  Renamer: TParameterRenamer;
begin
  Source := TSourceTokens.Create(ALines, '');
  Index := TRoutineIndex.Create(Source);
  Renamer := TParameterRenamer.Create(Source, Index);
  try
    Result := Renamer.Apply;
    Source.ApplyEdits;
  finally
    Renamer.Free;
    Index.Free;
    Source.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: Stray Spaces
  ═══════════════════════════════════════════════════════════════════════════ }

{ Removes the spaces directly before a `;`, `)` or `,` token, unless they
  follow a tab, `(` or `,` or start the line. Only spaces that separate
  two code tokens can qualify, so comment and string text keeps its
  spacing. }
function FixStraySpaces(const ALines: TStringList): Boolean;
var
  Source: TSourceTokens;
  TokenIndex, Before: Integer;
  Line: string;
begin
  Result := False;
  Source := TSourceTokens.Create(ALines, '');
  try
    for TokenIndex := 0 to Source.Count - 1 do
    begin
      if not (Source.IsText(TokenIndex, ';') or Source.IsText(TokenIndex, ')') or
              Source.IsText(TokenIndex, ',')) then
        Continue;
      Line := ALines[Source.LineIndex(TokenIndex)];
      Before := Source.Column(TokenIndex) - 1;
      while (Before >= 1) and (Line[Before] = ' ') do
        Dec(Before);
      if (Before >= 1) and (Before < Source.Column(TokenIndex) - 1) and
         not (Line[Before] in [#9, '(', ',']) then
      begin
        Source.RemoveSpacesBefore(TokenIndex, Source.Column(TokenIndex) - 1 - Before);
        Result := True;
      end;
    end;
    Source.ApplyEdits;
  finally
    Source.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  File Processing
  ═══════════════════════════════════════════════════════════════════════════ }

function FormatFile(const AFilePath: string; const AMode: TRunMode;
  out ASkipReason: string): Boolean;
var
  Lines, ResultLines: TStringList;
  Probe: TSourceTokens;
begin
  Result := False;
  ASkipReason := '';
  Lines := TStringList.Create;
  ResultLines := TStringList.Create;
  try
    Lines.LoadFromFile(AFilePath);

    { A file the tokenizer cannot read — an unterminated comment or
      string — is left exactly as it is: without a trustworthy view of
      what is code, no rewrite is safe. }
    try
      Probe := TSourceTokens.Create(Lines, ExtractFileName(AFilePath));
      Probe.Free;
    except
      on E: ELWPTPascalAnalysisError do
      begin
        ASkipReason := E.Message;
        Exit;
      end;
    end;

    FormatUsesInLines(Lines, ResultLines);
    FixFuncNames(ResultLines);
    FixParamNames(ResultLines);
    FixStraySpaces(ResultLines);

    if ResultLines.Text <> Lines.Text then
    begin
      Result := True;
      if AMode = rmFormat then
        ResultLines.SaveToFile(AFilePath);
    end;
  finally
    Lines.Free;
    ResultLines.Free;
  end;
end;

function FormatFile(const AFilePath: string; const AMode: TRunMode): Boolean;
var
  SkipReason: string;
begin
  Result := FormatFile(AFilePath, AMode, SkipReason);
end;

end.
