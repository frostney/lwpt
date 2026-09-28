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
    function IsIdentifier(const AIndex: Integer): Boolean;
    function IdentifierIs(const AIndex: Integer; const AName: string): Boolean;
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
    function LineText(const AIndex: Integer): string;
    function SourceSpan(const AFirst, ALast: Integer): string;
    procedure Rebind(const ALines: TStringList);
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
  { Strict strings: a rewrite must not read code as string text. }
  FTokens := TokenizePascal(Source, ASourceName, True);
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
var
  Wanted: TLWPTPascalTokenKind;
begin
  if (AIndex < 0) or (AIndex >= Length(FTokens)) then
    Exit(False);
  { The kind check first: most tokens are identifiers, and it spares
    them the string comparison. }
  if AText[1] in ['a'..'z'] then
    Wanted := ptKeyword
  else
    Wanted := ptSymbol;
  Result := (FTokens[AIndex].Kind = Wanted) and (FTokens[AIndex].Text = AText);
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

(* An identifier token, never a keyword one. Renames touch only these:
   an escaped `&begin` is the identifier `begin`, while `begin` itself is
   syntax, so matching by text alone would rewrite the keyword. Directive
   words such as `name` or `message` are keyword tokens too, so a
   parameter spelled like one is never renamed. *)
function TSourceTokens.IsIdentifier(const AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(FTokens)) and
            (FTokens[AIndex].Kind = ptIdentifier);
end;

function TSourceTokens.IdentifierIs(const AIndex: Integer; const AName: string): Boolean;
begin
  Result := IsIdentifier(AIndex) and (FTokens[AIndex].Text = AName);
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

{ The line holding the token. }
function TSourceTokens.LineText(const AIndex: Integer): string;
begin
  Result := FLines[LineIndex(AIndex)];
end;

{ The source text from the first token through the last, which must share
  a line. }
function TSourceTokens.SourceSpan(const AFirst, ALast: Integer): string;
begin
  Result := Copy(FLines[LineIndex(AFirst)], Column(AFirst),
    Column(ALast) + FTokens[ALast].Length - Column(AFirst));
end;

{ Points the tokens at a line list holding exactly the same text. }
procedure TSourceTokens.Rebind(const ALines: TStringList);
begin
  FLines := ALines;
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

type
  { A uses clause the formatter may regroup, keyed by its first line. }
  TUsesClause = record
    EndLine: Integer;      { line of the terminating semicolon; -1: none }
    Verbatim: Boolean;     { emit the lines exactly as written }
    Units: array of string;
  end;
  TUsesClauseArray = array of TUsesClause;

(* The uses clause starting on each line, if any.

   The clause starts where `uses` is the first thing on its line. It is
   formattable only when a code-level semicolon closes it with nothing
   but unit names in between; an unterminated clause, or one that runs
   into other code, is left alone. A clause carrying a directive or a
   comment is emitted verbatim: reordering across an $IFDEF changes which
   units a build sees, and a comment inside the clause exists to pin a
   position ("cthreads must come first so TThread has a driver"). The
   same holds for a comment behind the terminating semicolon, and for a
   unit entry that spans lines. Entries are split at comma tokens, so a
   comma inside an `in 'path'` string stays in its entry. *)
function FindUsesClauses(const ASource: TSourceTokens;
  const ALineCount: Integer): TUsesClauseArray;
var
  TokenIndex, Terminator, Scan, StartLine, EntryStart, UnitCount: Integer;
  Clause: TUsesClause;
begin
  Result := nil;
  SetLength(Result, ALineCount);
  for StartLine := 0 to ALineCount - 1 do
    Result[StartLine].EndLine := -1;

  for TokenIndex := 0 to ASource.Count - 1 do
  begin
    if not ASource.IsText(TokenIndex, 'uses') or not ASource.StartsLine(TokenIndex) then
      Continue;
    Terminator := TokenIndex + 1;
    while (Terminator < ASource.Count) and IsUsesClauseToken(ASource, Terminator) do
      Inc(Terminator);
    if not ASource.IsText(Terminator, ';') then
      Continue;
    if (Terminator + 1 < ASource.Count) and
       (ASource.LineIndex(Terminator + 1) = ASource.LineIndex(Terminator)) then
      Continue;

    Clause := Default(TUsesClause);
    Clause.EndLine := ASource.LineIndex(Terminator);
    Clause.Verbatim := not ASource.EndsLine(Terminator);
    for Scan := TokenIndex to Terminator - 1 do
      if ASource.IsDirective(Scan) or not ASource.OnlyBlanksBetween(Scan, Scan + 1) then
        Clause.Verbatim := True;

    UnitCount := 0;
    EntryStart := TokenIndex + 1;
    for Scan := TokenIndex + 1 to Terminator do
      if ASource.IsText(Scan, ',') or (Scan = Terminator) then
      begin
        if Scan > EntryStart then
        begin
          if ASource.LineIndex(EntryStart) <> ASource.LineIndex(Scan - 1) then
            Clause.Verbatim := True;
          SetLength(Clause.Units, UnitCount + 1);
          Clause.Units[UnitCount] := ASource.SourceSpan(EntryStart, Scan - 1);
          Inc(UnitCount);
        end;
        EntryStart := Scan + 1;
      end;
    if UnitCount = 0 then
      Clause.Verbatim := True;

    Result[ASource.LineIndex(TokenIndex)] := Clause;
  end;
end;

{ Rewrites AInput into AOutput with each formattable uses clause grouped
  and sorted. ASource is the tokenized AInput. }
procedure FormatUsesInLines(const AInput: TStringList; const ASource: TSourceTokens;
  const AOutput: TStringList);
var
  I, K: Integer;
  Clauses: TUsesClauseArray;
  Units, Formatted: TStringList;
begin
  Clauses := FindUsesClauses(ASource, AInput.Count);
  I := 0;
  while I < AInput.Count do
  begin
    if Clauses[I].EndLine < 0 then
    begin
      AOutput.Add(AInput[I]);
      Inc(I);
      Continue;
    end;

    if Clauses[I].Verbatim then
    begin
      for K := I to Clauses[I].EndLine do
        AOutput.Add(AInput[K]);
      I := Clauses[I].EndLine + 1;
      Continue;
    end;

    Units := TStringList.Create;
    try
      for K := 0 to High(Clauses[I].Units) do
        Units.Add(Clauses[I].Units[K]);
      Formatted := FormatUsesClause(Units);
      try
        AOutput.Add('uses');
        AOutput.AddStrings(Formatted);
      finally
        Formatted.Free;
      end;
    finally
      Units.Free;
    end;
    I := Clauses[I].EndLine + 1;
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
    Key: string;               { the qualified name: `tfoo.bar` or `bar` }
    NameGroup: string;         { Key within its enclosing routine }
    Group: string;             { NameGroup with the parameter signature }
    Body: TRoutineBody;
    HasParameterList: Boolean;
    ParameterTokens: array of Integer;  { each parameter name, in order }
    { A conditional or include directive inside the parameter list: the
      declared parameters depend on text the formatter cannot settle. }
    UncertainParameters: Boolean;
    Signature: string;         { modifier and type of each parameter }
    { The header reached from another across a conditional directive, or
      NoRoutine. }
    CrossedFrom: Integer;
    { This header and one reached from it across a conditional directive
      share one body: alternative headers of one routine. }
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

     Group joins a declaration with its implementation: the qualified
     name (`tfoo.bar` from `TFoo.Bar` or from `Bar` declared inside
     `TFoo`, the bare name otherwise), the routine body it is nested in,
     and the modifier and type of each parameter, which tell overloads
     apart. FPC rejects an implementation whose parameter names differ
     from its declaration's, so a rename is applied to every header of a
     group or to none. *)

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
    function EndsDeclarationList(const AIndex: Integer): Boolean;
    function ExtendConditionalBody(const AHeaderEnd, ABodyEnd: Integer): Integer;
    function FindHeaderEnd(const AStartToken: Integer): Integer;
    function ParseRoutines(const AStartToken: Integer; const AQualifier: string): Integer;
    procedure ReadParameters(var AHeader: TRoutineHeader; const AOpenToken: Integer);
    procedure ResolveGroups;
  public
    constructor Create(const ASource: TSourceTokens);
    function Count: Integer;
    function Routine(const AIndex: Integer): TRoutineHeader;
    function IsRoutineHeaderAt(const AIndex: Integer): Boolean;
    function CompositeOpening(const AIndex: Integer): Boolean;
    function FindBlockEnd(const AStartToken: Integer): Integer;
    function MatchingClose(const AOpenToken: Integer): Integer;
  end;

const
  NoRoutine = -1;
  { Blocks every parameter of a routine key; never a Pascal name. }
  AllNames = '*';

function IsModifier(const AWord: string): Boolean;
begin
  Result := (AWord = 'const') or (AWord = 'var') or (AWord = 'out') or (AWord = 'constref');
end;

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
  ResolveGroups;
end;

{ Group keys need every header's body kind, so they are settled after
  parsing. A routine's enclosing routine is the nearest one with a body:
  a declaration-only header only chains to its siblings in an interface
  section or a type. }
procedure TRoutineIndex.ResolveGroups;
var
  RoutineIndex, Enclosing, Source: Integer;
begin
  for RoutineIndex := 0 to FCount - 1 do
  begin
    Enclosing := FRoutines[RoutineIndex].Parent;
    while (Enclosing <> NoRoutine) and (FRoutines[Enclosing].Body <> rbBody) do
      Enclosing := FRoutines[Enclosing].Parent;
    FRoutines[RoutineIndex].NameGroup :=
      FRoutines[RoutineIndex].Key + '@' + IntToStr(Enclosing);
    FRoutines[RoutineIndex].Group := FRoutines[RoutineIndex].NameGroup +
      '(' + FRoutines[RoutineIndex].Signature + ')';

    { Alternative headers: the later one owns the body the earlier one
      never found. Independent headers that merely sit on either side of
      a directive each keep their own outcome. }
    Source := FRoutines[RoutineIndex].CrossedFrom;
    if (Source <> NoRoutine) and (FRoutines[RoutineIndex].Body = rbBody) and
       (FRoutines[Source].Body = rbDeclaration) then
    begin
      FRoutines[RoutineIndex].ConditionalHeader := True;
      FRoutines[Source].ConditionalHeader := True;
    end;
  end;
end;

(* Reads the parameter list opened at AOpenToken: the token of each
   parameter name, and a signature of each parameter's modifier and type
   (defaults dropped, since an implementation may omit them). *)
procedure TRoutineIndex.ReadParameters(var AHeader: TRoutineHeader;
  const AOpenToken: Integer);
var
  Close, TokenIndex, Depth, GroupNames, Following: Integer;
  InNames, InDefault, GroupStart: Boolean;
  Modifier, TypeText: string;

  procedure FinishGroup;
  var
    NameIndex: Integer;
  begin
    for NameIndex := 1 to GroupNames do
      AHeader.Signature := AHeader.Signature + Modifier + ':' + TypeText + ';';
    GroupNames := 0;
    Modifier := '';
    TypeText := '';
    InNames := True;
    InDefault := False;
    GroupStart := True;
  end;

begin
  Close := MatchingClose(AOpenToken);
  Depth := 0;
  GroupNames := 0;
  Modifier := '';
  TypeText := '';
  InNames := True;
  InDefault := False;
  GroupStart := True;
  for TokenIndex := AOpenToken + 1 to Close - 1 do
  begin
    if FSource.IsDirective(TokenIndex) then
    begin
      if FSource.IsConditionalDirective(TokenIndex) or
         FSource.IsIncludeDirective(TokenIndex) then
        AHeader.UncertainParameters := True;
      Continue;
    end;
    if (Depth = 0) and FSource.IsText(TokenIndex, ';') then
    begin
      FinishGroup;
      Continue;
    end;
    if FSource.IsText(TokenIndex, '(') or FSource.IsText(TokenIndex, '[') then
      Inc(Depth)
    else if FSource.IsText(TokenIndex, ')') or FSource.IsText(TokenIndex, ']') then
      Dec(Depth);
    if (Depth = 0) and FSource.IsText(TokenIndex, '=') then
      InDefault := True;
    if InDefault then
      Continue;
    if InNames and (Depth = 0) then
    begin
      if FSource.IsText(TokenIndex, ':') then
      begin
        InNames := False;
        Continue;
      end;
      if FSource.IsText(TokenIndex, ',') or not FSource.IsName(TokenIndex) then
        Continue;
      (* A switch directive may sit between a modifier and its name
         (`const {$R+} count`); look past it. *)
      Following := TokenIndex + 1;
      while (Following < Close) and FSource.IsDirective(Following) do
        Inc(Following);
      if GroupStart and IsModifier(FSource.Text(TokenIndex)) and
         FSource.IsName(Following) then
      begin
        Modifier := FSource.Text(TokenIndex);
        GroupStart := False;
        Continue;
      end;
      GroupStart := False;
      SetLength(AHeader.ParameterTokens, Length(AHeader.ParameterTokens) + 1);
      AHeader.ParameterTokens[High(AHeader.ParameterTokens)] := TokenIndex;
      Inc(GroupNames);
    end
    else
      TypeText := TypeText + ' ' + FSource.Text(TokenIndex);
  end;
  FinishGroup;
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
  the routine's extent then runs to the block's closing directive. Only
  directives, semicolons and further bodies may lie in between: anything
  else (a declaration, a routine header) means the block is not a set of
  alternative bodies, and the extent stays at the first body. The
  routine's directives then do not balance, and no rename touches it. }
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
    if FSource.IsText(TokenIndex, 'begin') or FSource.IsText(TokenIndex, 'asm') then
    begin
      TokenIndex := FindBlockEnd(TokenIndex);
      Continue;
    end;
    if not FSource.IsDirective(TokenIndex) and not FSource.IsText(TokenIndex, ';') then
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
  Header.CrossedFrom := NoRoutine;

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
          ReadParameters(Header, TokenIndex);
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
          FRoutines[Frames[Top].Routine].CrossedFrom := Current;
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

{ Records the function-name fix: every code reference to a routine whose
  name starts lower-case takes the declared spelling with a capital.
  Assembler blocks are skipped. The edits change case only, so every
  later pass reads the same token positions. }
procedure FixFuncNames(const ASource: TSourceTokens; const AIndex: TRoutineIndex);
var
  Names: TNameMap;
  RoutineIndex, TokenIndex: Integer;
  Header: TRoutineHeader;
  Name, NewName: string;
begin
  Names := TNameMap.Create;
  try
    for RoutineIndex := 0 to AIndex.Count - 1 do
    begin
      Header := AIndex.Routine(RoutineIndex);
      if (Header.Body = rbExternal) or (Header.NameToken < 0) then
        Continue;
      Name := ASource.Spelling(Header.NameToken);
      if (Name[1] in ['a'..'z']) and not Names.ContainsKey(LowerCase(Name)) then
        Names.Add(LowerCase(Name), UpCase(Name[1]) + Copy(Name, 2, MaxInt));
    end;
    if Names.Count = 0 then
      Exit;

    TokenIndex := 0;
    while TokenIndex < ASource.Count do
    begin
      if ASource.IsText(TokenIndex, 'asm') then
      begin
        TokenIndex := AIndex.FindBlockEnd(TokenIndex);
        Continue;
      end;
      if ASource.IsIdentifier(TokenIndex) and not ASource.IsText(TokenIndex - 1, '.') and
         Names.TryGetValue(ASource.Text(TokenIndex), NewName) then
        ASource.Replace(TokenIndex, NewName);
      Inc(TokenIndex);
    end;
  finally
    Names.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: Parameter A Prefix
  ═══════════════════════════════════════════════════════════════════════════ }

type
  { How a routine's own header or declaration part uses a name, in rising
    order of concern. }
  TMention = (mnNone, mnReference, mnBinding, mnUncertain);

  (* Plans the parameter A-prefix fix over one file. A parameter is renamed
     in every header of its routine and in the bodies those headers own,
     or nowhere. Binding is established conservatively; a parameter is
     left as it is when:
       - a header of its routine is external (out of scope), contains
         assembler, whose operands the formatter cannot tell from
         registers, or an include directive, whose text it cannot see;
       - its routine's conditional directives do not balance, its headers
         are alternatives in conditional branches, or a conditional or
         include directive sits inside a parameter list;
       - the old name is used in a header other than as a parameter (a
         type of the same name), is declared or used in the routine's own
         declaration part other than as a record member or through
         `absolute`, appears in a nested routine's initializer or
         `absolute` target, names a nested routine, or is the routine's
         name;
       - the parameter token is a keyword token (a directive word such as
         `message`): renames touch identifier tokens only;
       - a `with` statement precedes a use of the old name;
       - the new name is already visible where the parameter is;
       - an implementation omits the parameter list a declaration gives,
         a declaration and an implementation of one name cannot be
         paired by signature, or another header spells the parameter
         with its prefix already.
     A nested routine that binds the old name itself — as a parameter,
     a variable, a constant or a type — keeps that binding and is
     excluded from the outer rename. *)
  TParameterRenamer = class
  private
    FSource: TSourceTokens;
    FIndex: TRoutineIndex;
    FParameters: array of TRenamePairArray;
    FBlocked: TStringList;
    FExcluded: TLineIndexArray;
    FExcludedCount: Integer;
    procedure Block(const AGroup, AOldName: string);
    function IsBlocked(const AHeader: TRoutineHeader; const AOldName: string): Boolean;
    function NameOccurs(const AName: string; const AFirst, ALast: Integer): Boolean;
    function KeywordSpelledAs(const AName: string; const AFirst, ALast: Integer): Boolean;
    function HeaderMentions(const ARoutine: Integer; const AName: string): TMention;
    function DeclarationMentions(const ARoutine: Integer; const AName: string;
      const ANested: Boolean): TMention;
    function BindsName(const ARoutine: Integer; const AName: string): Boolean;
    function RoutineIsSafe(const ARoutine: Integer): Boolean;
    function CollectScope(const ARoutine: Integer; const AName: string): Boolean;
    function ExcludedRoot(const ATokenIndex: Integer): Integer;
    function UsedAfterWith(const ARoutine: Integer; const AName: string): Boolean;
    function NewNameCollides(const ARoutine: Integer; const ANewName: string): Boolean;
    function BodyRenameIsSafe(const ARoutine: Integer; const APair: TRenamePair): Boolean;
    procedure BlockAmbiguousGroups;
    procedure RenameRange(const AFirst, ALast: Integer; const APair: TRenamePair);
    function HeaderParameters(const ARoutine: Integer): TRenamePairArray;
  public
    constructor Create(const ASource: TSourceTokens; const AIndex: TRoutineIndex);
    destructor Destroy; override;
    procedure Apply;
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

procedure TParameterRenamer.Block(const AGroup, AOldName: string);
begin
  FBlocked.Add(AGroup + '|' + AOldName);
end;

function TParameterRenamer.IsBlocked(const AHeader: TRoutineHeader;
  const AOldName: string): Boolean;
begin
  Result := (FBlocked.IndexOf(AHeader.NameGroup + '|' + AllNames) >= 0) or
            (FBlocked.IndexOf(AHeader.Group + '|' + AllNames) >= 0) or
            (FBlocked.IndexOf(AHeader.Group + '|' + AOldName) >= 0);
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

{ A parameter of that name is a binding; the name anywhere else in the
  header after the routine's own name (a parameter or result type of the
  same name) is uncertain. }
function TParameterRenamer.HeaderMentions(const ARoutine: Integer;
  const AName: string): TMention;
var
  Header: TRoutineHeader;
  TokenIndex, ParameterIndex: Integer;
  IsParameter: Boolean;
begin
  Result := mnNone;
  Header := FIndex.Routine(ARoutine);
  for TokenIndex := Header.NameToken + 1 to Header.HeaderEnd - 1 do
  begin
    if not FSource.IdentifierIs(TokenIndex, AName) then
      Continue;
    IsParameter := False;
    for ParameterIndex := 0 to High(Header.ParameterTokens) do
      if Header.ParameterTokens[ParameterIndex] = TokenIndex then
        IsParameter := True;
    if not IsParameter then
      Exit(mnUncertain);
    Result := mnBinding;
  end;
end;

(* How the routine's own declaration part — outside the routines nested
   there — uses AName:
     - a member of a record, class or object type: no concern;
     - the target of `absolute` in the routine that owns the parameter:
       a reference to it. In a nested routine the target may be a
       binding the formatter cannot place, so it is uncertain;
     - declared as a variable, constant, type or resource string: a
       binding;
     - anything in an initializer, after a declaration's `=` (a typed
       constant's record labels look like declarations): uncertain;
     - anything else: uncertain. *)
function TParameterRenamer.DeclarationMentions(const ARoutine: Integer;
  const AName: string; const ANested: Boolean): TMention;
var
  Header, Child: TRoutineHeader;
  TokenIndex, ChildIndex, Depth, Brackets: Integer;
  InInitializer: Boolean;
  Mention: TMention;
begin
  Result := mnNone;
  Header := FIndex.Routine(ARoutine);
  if Header.BodyStart < 0 then
    Exit;
  TokenIndex := Header.HeaderEnd;
  ChildIndex := Header.FirstChild;
  Depth := 0;
  Brackets := 0;
  InInitializer := False;
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
    if FSource.IsText(TokenIndex, '(') or FSource.IsText(TokenIndex, '[') then
      Inc(Brackets)
    else if (FSource.IsText(TokenIndex, ')') or FSource.IsText(TokenIndex, ']')) and
            (Brackets > 0) then
      Dec(Brackets)
    else if (Brackets = 0) and FSource.IsText(TokenIndex, ';') then
      InInitializer := False
    else if (Brackets = 0) and (Depth = 0) and FSource.IsText(TokenIndex, '=') then
      InInitializer := True;

    if FIndex.CompositeOpening(TokenIndex) then
      Inc(Depth)
    else if FSource.IsText(TokenIndex, 'end') and (Depth > 0) then
      Dec(Depth)
    else if (Depth = 0) and FSource.IdentifierIs(TokenIndex, AName) then
    begin
      if InInitializer then
        Mention := mnUncertain
      else if FSource.IsText(TokenIndex - 1, 'absolute') then
      begin
        if ANested then
          Mention := mnUncertain
        else
          Mention := mnReference;
      end
      else if (FSource.IsText(TokenIndex - 1, 'var') or FSource.IsText(TokenIndex - 1, 'const') or
               FSource.IsText(TokenIndex - 1, 'type') or FSource.IsText(TokenIndex - 1, 'threadvar') or
               FSource.IsText(TokenIndex - 1, 'resourcestring') or
               FSource.IsText(TokenIndex - 1, ';') or FSource.IsText(TokenIndex - 1, ',')) and
              (FSource.IsText(TokenIndex + 1, ':') or FSource.IsText(TokenIndex + 1, ',') or
               FSource.IsText(TokenIndex + 1, '=')) then
        Mention := mnBinding
      else
        Mention := mnUncertain;
      if Mention > Result then
        Result := Mention;
    end;
    Inc(TokenIndex);
  end;
end;

function TParameterRenamer.BindsName(const ARoutine: Integer; const AName: string): Boolean;
begin
  Result := (HeaderMentions(ARoutine, AName) = mnBinding) or
            (DeclarationMentions(ARoutine, AName, True) = mnBinding);
end;

function TParameterRenamer.RoutineIsSafe(const ARoutine: Integer): Boolean;
var
  Header: TRoutineHeader;
  TokenIndex, Depth: Integer;
begin
  Header := FIndex.Routine(ARoutine);
  Depth := 0;
  for TokenIndex := Header.StartToken to Header.ExtentEnd - 1 do
    if FSource.IsDirective(TokenIndex) then
    begin
      if FSource.IsIncludeDirective(TokenIndex) then
        Exit(False);
      Inc(Depth, FSource.ConditionalDelta(TokenIndex));
      if Depth < 0 then
        Exit(False);
    end
    else if FSource.IsText(TokenIndex, 'asm') or FSource.IsText(TokenIndex, 'assembler') then
      Exit(False);
  Result := Depth = 0;
end;

(* Walks the routines nested in ARoutine and records, in FExcluded, the
   extent of every one that binds AName itself, so it keeps that binding.
   Returns False when the binding cannot be settled: a nested routine is
   named AName (inside the enclosing body the name then refers to it),
   or uses AName in a way that is neither a binding nor a reference. *)
function TParameterRenamer.CollectScope(const ARoutine: Integer; const AName: string): Boolean;
var
  ChildIndex: Integer;
  Child: TRoutineHeader;
  InHeader, InDeclarations: TMention;
begin
  ChildIndex := FIndex.Routine(ARoutine).FirstChild;
  while ChildIndex <> NoRoutine do
  begin
    Child := FIndex.Routine(ChildIndex);
    if FSource.NameIs(Child.NameToken, AName) then
      Exit(False);
    InHeader := HeaderMentions(ChildIndex, AName);
    InDeclarations := DeclarationMentions(ChildIndex, AName, True);
    if (InHeader = mnUncertain) or (InDeclarations = mnUncertain) then
      Exit(False);
    if (InHeader = mnBinding) or (InDeclarations = mnBinding) then
    begin
      if FExcludedCount + 3 > Length(FExcluded) then
        SetLength(FExcluded, FExcludedCount * 2 + 9);
      FExcluded[FExcludedCount] := Child.StartToken;
      FExcluded[FExcludedCount + 1] := Child.ExtentEnd;
      FExcluded[FExcludedCount + 2] := ChildIndex;
      Inc(FExcludedCount, 3);
    end
    else if not CollectScope(ChildIndex, AName) then
      Exit(False);
    ChildIndex := Child.NextSibling;
  end;
  Result := True;
end;

{ The excluded nested routine whose extent holds the token, or NoRoutine. }
function TParameterRenamer.ExcludedRoot(const ATokenIndex: Integer): Integer;
var
  Entry: Integer;
begin
  Entry := 0;
  while Entry < FExcludedCount do
  begin
    if (ATokenIndex >= FExcluded[Entry]) and (ATokenIndex < FExcluded[Entry + 1]) then
      Exit(FExcluded[Entry + 2]);
    Inc(Entry, 3);
  end;
  Result := NoRoutine;
end;

{ Inside `with X do`, a name may resolve to a member of X; the formatter
  cannot tell, so a use of the name after any `with` in the routine
  blocks the rename. }
function TParameterRenamer.UsedAfterWith(const ARoutine: Integer;
  const AName: string): Boolean;
var
  Header: TRoutineHeader;
  TokenIndex: Integer;
  SeenWith: Boolean;
begin
  Header := FIndex.Routine(ARoutine);
  SeenWith := False;
  for TokenIndex := Header.HeaderEnd to Header.ExtentEnd - 1 do
  begin
    if ExcludedRoot(TokenIndex) <> NoRoutine then
      Continue;
    if FSource.IsText(TokenIndex, 'with') then
      SeenWith := True
    else if SeenWith and FSource.NameIs(TokenIndex, AName) and
            not FSource.IsText(TokenIndex - 1, '.') then
      Exit(True);
  end;
  Result := False;
end;

{ Whether the new name is already visible where the parameter will be:
  any unqualified use of it in the routine's extent, except inside a
  nested routine that binds the new name itself. A member access
  (`Entry.ACount`) never collides. }
function TParameterRenamer.NewNameCollides(const ARoutine: Integer;
  const ANewName: string): Boolean;
var
  Header: TRoutineHeader;
  TokenIndex, Root: Integer;
begin
  Header := FIndex.Routine(ARoutine);
  for TokenIndex := Header.StartToken to Header.ExtentEnd - 1 do
  begin
    if not FSource.NameIs(TokenIndex, ANewName) or FSource.IsText(TokenIndex - 1, '.') then
      Continue;
    Root := ExcludedRoot(TokenIndex);
    if (Root = NoRoutine) or not BindsName(Root, ANewName) then
      Exit(True);
  end;
  Result := False;
end;

function TParameterRenamer.BodyRenameIsSafe(const ARoutine: Integer;
  const APair: TRenamePair): Boolean;
var
  InDeclarations: TMention;
begin
  FExcludedCount := 0;
  if HeaderMentions(ARoutine, APair.OldName) = mnUncertain then
    Exit(False);
  InDeclarations := DeclarationMentions(ARoutine, APair.OldName, False);
  if InDeclarations in [mnBinding, mnUncertain] then
    Exit(False);
  if not CollectScope(ARoutine, APair.OldName) then
    Exit(False);
  Result := not UsedAfterWith(ARoutine, APair.OldName) and
            not NewNameCollides(ARoutine, LowerCase(APair.NewName));
end;

(* Blocks every parameter of a name whose headers cannot be paired safely.

   Delphi mode lets an implementation omit the parameter list its
   declaration gives; its body then uses names only the declaration shows.
   When a name has a declaration with parameters and more parameterless
   bodies than parameterless declarations, some body may be such an
   implementation. A parameterless overload that has only a body is no
   such case.

   Headers are paired by signature. When one name has both a declaration
   whose signature no body shares and a body whose signature no
   declaration shares, the two may be one routine spelled differently
   (a type alias, a unit-qualified type), so the pairing is not trusted. *)
procedure TParameterRenamer.BlockAmbiguousGroups;
var
  Tally: TNameMap;
  RoutineIndex: Integer;
  Header: TRoutineHeader;
  Mark, Existing, Key: string;
  Entry: TPair<string, string>;
  Declarations, Bodies, UnpairedDeclarations, UnpairedBodies: TStringList;

  function Occurrences(const AText: string; const AMark: Char): Integer;
  var
    Position: Integer;
  begin
    Result := 0;
    for Position := 1 to Length(AText) do
      if AText[Position] = AMark then
        Inc(Result);
  end;

  { Adds to AUnpaired the name group of every entry of AFrom whose group
    AIn lacks. }
  procedure CollectUnpaired(const AFrom, AIn, AUnpaired: TStringList);
  var
    Item: Integer;
  begin
    for Item := 0 to AFrom.Count - 1 do
      if AIn.IndexOf(AFrom[Item]) < 0 then
        AUnpaired.Add(AFrom.Names[Item]);
  end;

begin
  Tally := TNameMap.Create;
  Declarations := TStringList.Create;
  Bodies := TStringList.Create;
  UnpairedDeclarations := TStringList.Create;
  UnpairedBodies := TStringList.Create;
  try
    UnpairedDeclarations.Sorted := True;
    UnpairedDeclarations.Duplicates := dupIgnore;
    UnpairedBodies.Sorted := True;
    UnpairedBodies.Duplicates := dupIgnore;
    Declarations.Sorted := True;
    Declarations.Duplicates := dupIgnore;
    Bodies.Sorted := True;
    Bodies.Duplicates := dupIgnore;
    for RoutineIndex := 0 to FIndex.Count - 1 do
    begin
      { Q: a declaration with a parameter list; D: one without; B: a body
        without one. A body with a parameter list needs no tally. }
      Header := FIndex.Routine(RoutineIndex);
      if Header.Body = rbBody then
      begin
        Bodies.Add(Header.NameGroup + '=' + Header.Group);
        if Header.HasParameterList then
          Mark := ''
        else
          Mark := 'B';
      end
      else
      begin
        Declarations.Add(Header.NameGroup + '=' + Header.Group);
        if Header.HasParameterList then
          Mark := 'Q'
        else
          Mark := 'D';
      end;
      if Tally.TryGetValue(Header.NameGroup, Existing) then
        Tally.AddOrSetValue(Header.NameGroup, Existing + Mark)
      else
        Tally.Add(Header.NameGroup, Mark);
    end;
    CollectUnpaired(Declarations, Bodies, UnpairedDeclarations);
    CollectUnpaired(Bodies, Declarations, UnpairedBodies);
    for Entry in Tally do
    begin
      Key := Entry.Key;
      if ((Occurrences(Entry.Value, 'Q') > 0) and
          (Occurrences(Entry.Value, 'B') > Occurrences(Entry.Value, 'D'))) or
         ((UnpairedDeclarations.IndexOf(Key) >= 0) and (UnpairedBodies.IndexOf(Key) >= 0)) then
        Block(Key, AllNames);
    end;
  finally
    UnpairedBodies.Free;
    UnpairedDeclarations.Free;
    Bodies.Free;
    Declarations.Free;
    Tally.Free;
  end;
end;

{ Renames the parameter's uses in the range, outside excluded nested
  routines, member accesses (`X.Name`), and the member lists of record,
  class and object types declared there: a field of the same name is not
  the parameter. }
procedure TParameterRenamer.RenameRange(const AFirst, ALast: Integer;
  const APair: TRenamePair);
var
  TokenIndex, Excluded, Depth: Integer;
begin
  TokenIndex := AFirst;
  Excluded := 0;
  Depth := 0;
  while TokenIndex < ALast do
  begin
    if (Excluded < FExcludedCount) and (TokenIndex >= FExcluded[Excluded]) then
    begin
      TokenIndex := FExcluded[Excluded + 1];
      Inc(Excluded, 3);
      Continue;
    end;
    if FIndex.CompositeOpening(TokenIndex) then
      Inc(Depth)
    else if FSource.IsText(TokenIndex, 'end') and (Depth > 0) then
      Dec(Depth)
    else if (Depth = 0) and FSource.IdentifierIs(TokenIndex, APair.OldName) and
            not FSource.IsText(TokenIndex - 1, '.') then
      FSource.Replace(TokenIndex, APair.NewName);
    Inc(TokenIndex);
  end;
end;

(* True when a keyword token in the range is spelled like AName and AName
   is not a reserved word. An `&`-escaped parameter named after a directive
   word (`&message`) may be used unescaped, and those uses are keyword
   tokens the rename cannot touch, so renaming only the escaped spellings
   would rebind them. A reserved word (`&begin`) can only be used escaped,
   so its unescaped occurrences are syntax and do not block the rename. *)
function TParameterRenamer.KeywordSpelledAs(const AName: string;
  const AFirst, ALast: Integer): Boolean;
const
  { FPC's reserved words in the objfpc and delphi modes. These can only be
    used escaped, so every unescaped occurrence is syntax, not a use. }
  ReservedWords: array[0..66] of string = (
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto',
    'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally',
    'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library', 'mod',
    'nil', 'not', 'object', 'of', 'on', 'operator', 'or', 'out', 'packed',
    'procedure', 'program', 'property', 'raise', 'record', 'repeat',
    'resourcestring', 'set', 'shl', 'shr', 'string', 'then', 'threadvar',
    'to', 'try', 'type', 'unit', 'until', 'uses', 'var', 'while', 'with',
    'xor');
var
  TokenIndex, WordIndex: Integer;
begin
  for WordIndex := Low(ReservedWords) to High(ReservedWords) do
    if SameText(AName, ReservedWords[WordIndex]) then
      Exit(False);
  for TokenIndex := AFirst to ALast do
    if FSource.IsName(TokenIndex) and not FSource.IsIdentifier(TokenIndex) and
       SameText(FSource.Text(TokenIndex), AName) then
      Exit(True);
  Result := False;
end;

(* Every parameter a header declares, keyed by its normalized name (an
   `&` escape dropped). A renameable one — two or more letters, no A
   prefix yet, not Self, and not one whose prefixed form is a keyword —
   carries its new name; any other carries an empty one, so a header
   that spells the same parameter differently (`aValue` here, `AValue`
   there, which FPC treats as one name) blocks the rename for all. *)
function TParameterRenamer.HeaderParameters(const ARoutine: Integer): TRenamePairArray;
var
  Header: TRoutineHeader;
  ParameterIndex, Count, Existing: Integer;
  Duplicate: Boolean;
  Spelling, NewName: string;
begin
  Result := nil;
  Header := FIndex.Routine(ARoutine);
  Count := 0;
  for ParameterIndex := 0 to High(Header.ParameterTokens) do
  begin
    Spelling := FSource.Spelling(Header.ParameterTokens[ParameterIndex]);
    if (Spelling <> '') and (Spelling[1] = '&') then
      Delete(Spelling, 1, 1);
    NewName := 'A' + UpCase(Spelling[1]) + Copy(Spelling, 2, MaxInt);
    { A parameter read as a keyword token (a directive word such as
      `message`) cannot be renamed by token role, so it is left alone. }
    if (LowerCase(Spelling) = 'self') or (Length(Spelling) < 2) or
       HasAPrefix(Spelling) or IsPascalKeyword(NewName) or
       not FSource.IsIdentifier(Header.ParameterTokens[ParameterIndex]) then
      NewName := '';
    Duplicate := False;
    for Existing := 0 to Count - 1 do
      if Result[Existing].OldName = FSource.Text(Header.ParameterTokens[ParameterIndex]) then
        Duplicate := True;
    if Duplicate then
      Continue;
    SetLength(Result, Count + 1);
    Result[Count].OldName := FSource.Text(Header.ParameterTokens[ParameterIndex]);
    Result[Count].NewName := NewName;
    Inc(Count);
  end;
end;

procedure TParameterRenamer.Apply;
var
  RoutineIndex, PairIndex: Integer;
  Header: TRoutineHeader;
  Pair: TRenamePair;
begin
  SetLength(FParameters, FIndex.Count);
  for RoutineIndex := 0 to FIndex.Count - 1 do
    FParameters[RoutineIndex] := HeaderParameters(RoutineIndex);

  BlockAmbiguousGroups;
  for RoutineIndex := 0 to FIndex.Count - 1 do
  begin
    Header := FIndex.Routine(RoutineIndex);
    if (Header.Body = rbExternal) or Header.ConditionalHeader or
       Header.UncertainParameters or
       ((Header.Body = rbBody) and not RoutineIsSafe(RoutineIndex)) then
    begin
      Block(Header.Group, AllNames);
      Continue;
    end;
    for PairIndex := 0 to High(FParameters[RoutineIndex]) do
    begin
      Pair := FParameters[RoutineIndex][PairIndex];
      { A parameter spelled like its routine makes every mention of the
        name ambiguous. }
      if (Pair.NewName = '') or FSource.NameIs(Header.NameToken, Pair.OldName) or
         KeywordSpelledAs(Pair.OldName, Header.StartToken, Header.ExtentEnd - 1) then
        Block(Header.Group, Pair.OldName)
      else if Header.Body = rbBody then
      begin
        if not BodyRenameIsSafe(RoutineIndex, Pair) then
          Block(Header.Group, Pair.OldName);
      end
      else if NameOccurs(LowerCase(Pair.NewName), Header.StartToken, Header.HeaderEnd) or
              (HeaderMentions(RoutineIndex, Pair.OldName) = mnUncertain) then
        Block(Header.Group, Pair.OldName);
    end;
  end;

  for RoutineIndex := 0 to FIndex.Count - 1 do
  begin
    Header := FIndex.Routine(RoutineIndex);
    for PairIndex := 0 to High(FParameters[RoutineIndex]) do
    begin
      Pair := FParameters[RoutineIndex][PairIndex];
      if (Pair.NewName = '') or IsBlocked(Header, Pair.OldName) then
        Continue;
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

procedure FixParamNames(const ASource: TSourceTokens; const AIndex: TRoutineIndex);
var
  Renamer: TParameterRenamer;
begin
  Renamer := TParameterRenamer.Create(ASource, AIndex);
  try
    Renamer.Apply;
  finally
    Renamer.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: Stray Spaces
  ═══════════════════════════════════════════════════════════════════════════ }

{ Records removal of the spaces directly before a `;`, `)` or `,` token,
  unless they follow a tab, `(` or `,` or start the line. Only spaces that
  separate two code tokens can qualify, so comment and string text keeps
  its spacing. The character before the spaces is never part of an
  identifier another pass renames, so the checks hold after those edits. }
procedure FixStraySpaces(const ASource: TSourceTokens);
var
  TokenIndex, Before: Integer;
  Line: string;
begin
  for TokenIndex := 0 to ASource.Count - 1 do
  begin
    if not (ASource.IsText(TokenIndex, ';') or ASource.IsText(TokenIndex, ')') or
            ASource.IsText(TokenIndex, ',')) then
      Continue;
    Line := ASource.LineText(TokenIndex);
    Before := ASource.Column(TokenIndex) - 1;
    while (Before >= 1) and (Line[Before] = ' ') do
      Dec(Before);
    if (Before >= 1) and (Before < ASource.Column(TokenIndex) - 1) and
       not (Line[Before] in [#9, '(', ',']) then
      ASource.RemoveSpacesBefore(TokenIndex, ASource.Column(TokenIndex) - 1 - Before);
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  File Processing
  ═══════════════════════════════════════════════════════════════════════════ }

(* The uses pass rewrites lines; the other three passes record token edits
   against one tokenization of its result and apply them together. The
   file is tokenized twice at most: once as read, and once more only when
   the uses pass changed it. *)
function FormatFile(const AFilePath: string; const AMode: TRunMode;
  out ASkipReason: string): Boolean;
var
  Lines, ResultLines: TStringList;
  Source: TSourceTokens;
  Index: TRoutineIndex;
begin
  Result := False;
  ASkipReason := '';
  Source := nil;
  Index := nil;
  Lines := TStringList.Create;
  ResultLines := TStringList.Create;
  try
    Lines.LoadFromFile(AFilePath);
    try
      { A file the tokenizer cannot read — an unterminated comment or
        string — is left exactly as it is: without a trustworthy view of
        what is code, no rewrite is safe. }
      Source := TSourceTokens.Create(Lines, ExtractFileName(AFilePath));
      FormatUsesInLines(Lines, Source, ResultLines);
      if ResultLines.Text = Lines.Text then
        Source.Rebind(ResultLines)
      else
      begin
        FreeAndNil(Source);
        Source := TSourceTokens.Create(ResultLines, ExtractFileName(AFilePath));
      end;
      Index := TRoutineIndex.Create(Source);
      FixFuncNames(Source, Index);
      FixParamNames(Source, Index);
      FixStraySpaces(Source);
      Source.ApplyEdits;
    except
      on E: ELWPTPascalAnalysisError do
      begin
        ASkipReason := E.Message;
        Exit;
      end;
    end;

    if ResultLines.Text <> Lines.Text then
    begin
      Result := True;
      if AMode = rmFormat then
        ResultLines.SaveToFile(AFilePath);
    end;
  finally
    Index.Free;
    Source.Free;
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
