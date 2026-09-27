{ LWPT.Formatter — uses-clause + identifier formatter.

  The canonical entry point is FormatFile(path, mode). In rmCheck mode
  the function returns True when the file would change (without writing
  anything); in rmFormat mode it returns True after rewriting the file
  in place. The caller (LWPT.Command.Format.CmdFormat) handles file discovery
  per the manifest's [format] scope, summary stats, and exit code. }
unit LWPT.Formatter;

{$mode delphi}{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TRunMode = (rmFormat, rmCheck);

function FormatFile(const AFilePath: string; AMode: TRunMode): Boolean;

implementation

type
  TUnitCategory = (ucSystem, ucThirdParty, ucProject, ucRelative);

  { Lexical state carried from one line to the next. A string literal
    cannot span a line break and a double-slash comment always ends at
    one, so only the two block-comment forms survive it. }
  TLexState = (lsCode, lsBraceComment, lsParenStarComment);

  TLineFlags = array of Boolean;

  (* Which characters of each line are code. Every rewriting pass reads
     the file through this map, so routine-header detection, identifier
     renames, uses-clause detection and the spacing fix never act on text
     inside a brace, parenthesis-star or double-slash comment, a compiler
     directive, or a string literal. Brace comments do not nest, matching
     FPC's delphi and objfpc modes. The map aliases the pass's line list;
     a pass that rewrites a line calls Refresh for it. *)
  TCodeMap = class
  private
    FLines: TStringList;
    FStartStates: array of TLexState;
    FKinds: array of string;
  public
    constructor Create(const ALines: TStringList);
    procedure Refresh(AIndex: Integer);
    function Count: Integer;
    function IsCode(AIndex, APosition: Integer): Boolean;
    function CodeText(AIndex: Integer): string;
    function StartsWithCode(AIndex: Integer): Boolean;
  end;

const
  KIND_CODE = 'c';
  KIND_OTHER = '-';

{ ═══════════════════════════════════════════════════════════════════════════
  Lexical Code Map
  ═══════════════════════════════════════════════════════════════════════════ }

{ Returns the index just past the string literal that opens at AStart.
  A doubled quote is an escaped quote; an unterminated literal ends at
  the line end. }
function SkipStringLiteral(const ALine: string; AStart: Integer): Integer;
begin
  Result := AStart + 1;
  while Result <= Length(ALine) do
  begin
    if ALine[Result] <> '''' then
      Inc(Result)
    else if (Result < Length(ALine)) and (ALine[Result + 1] = '''') then
      Inc(Result, 2)
    else
      Exit(Result + 1);
  end;
end;

{ Marks each character of ALine as code or not, starting in AState, and
  returns the state the next line starts in. }
function ClassifyLine(const ALine: string; AState: TLexState;
  out AKinds: string): TLexState;
var
  I, Len: Integer;
begin
  Len := Length(ALine);
  AKinds := StringOfChar(KIND_OTHER, Len);
  I := 1;
  while I <= Len do
  begin
    case AState of
      lsBraceComment:
        begin
          if ALine[I] = '}' then
            AState := lsCode;
          Inc(I);
        end;
      lsParenStarComment:
        if (ALine[I] = '*') and (I < Len) and (ALine[I + 1] = ')') then
        begin
          AState := lsCode;
          Inc(I, 2);
        end
        else
          Inc(I);
    else
      if ALine[I] = '''' then
        I := SkipStringLiteral(ALine, I)
      else if ALine[I] = '{' then
      begin
        AState := lsBraceComment;
        Inc(I);
      end
      else if (ALine[I] = '(') and (I < Len) and (ALine[I + 1] = '*') then
      begin
        AState := lsParenStarComment;
        Inc(I, 2);
      end
      else if (ALine[I] = '/') and (I < Len) and (ALine[I + 1] = '/') then
        Break
      else
      begin
        AKinds[I] := KIND_CODE;
        Inc(I);
      end;
    end;
  end;
  Result := AState;
end;

constructor TCodeMap.Create(const ALines: TStringList);
var
  I: Integer;
  State: TLexState;
begin
  inherited Create;
  FLines := ALines;
  SetLength(FStartStates, ALines.Count);
  SetLength(FKinds, ALines.Count);
  State := lsCode;
  for I := 0 to ALines.Count - 1 do
  begin
    FStartStates[I] := State;
    State := ClassifyLine(ALines[I], State, FKinds[I]);
  end;
end;

{ Reclassifies one line after a pass rewrote it. Passes only ever change
  code characters (identifier renames, stray-space removal), and neither
  can open or close a comment or literal, so every later line keeps its
  recorded start state. }
procedure TCodeMap.Refresh(AIndex: Integer);
begin
  ClassifyLine(FLines[AIndex], FStartStates[AIndex], FKinds[AIndex]);
end;

function TCodeMap.Count: Integer;
begin
  Result := Length(FKinds);
end;

function TCodeMap.IsCode(AIndex, APosition: Integer): Boolean;
begin
  Result := (APosition >= 1) and (APosition <= Length(FKinds[AIndex])) and
            (FKinds[AIndex][APosition] = KIND_CODE);
end;

{ The line with every non-code character blanked, so column positions
  still line up with the original text. }
function TCodeMap.CodeText(AIndex: Integer): string;
var
  K: Integer;
begin
  Result := FLines[AIndex];
  for K := 1 to Length(Result) do
    if FKinds[AIndex][K] <> KIND_CODE then
      Result[K] := ' ';
end;

{ True when the first non-blank character of the line is code rather
  than the inside or opening of a comment, directive or literal. }
function TCodeMap.StartsWithCode(AIndex: Integer): Boolean;
var
  Line: string;
  K: Integer;
begin
  Line := FLines[AIndex];
  for K := 1 to Length(Line) do
    if Line[K] > ' ' then
      Exit(FKinds[AIndex][K] = KIND_CODE);
  Result := False;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Uses-Clause Formatting
  ═══════════════════════════════════════════════════════════════════════════ }

function IsUsesKeyword(const ALine: string): Boolean;
var
  Trimmed: string;
begin
  Trimmed := Trim(ALine);
  if Length(Trimmed) < 4 then
    Exit(False);
  if LowerCase(Copy(Trimmed, 1, 4)) <> 'uses' then
    Exit(False);
  if Length(Trimmed) = 4 then
    Exit(True);
  Result := not (Trimmed[5] in ['A'..'Z', 'a'..'z', '0'..'9', '_']);
end;

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

(* A uses clause that carries a compiler directive or a comment is
   emitted verbatim rather than regrouped and sorted.

   Directives have always worked this way: reordering across an $IFDEF
   changes which units a build actually sees. Comments earn the same
   treatment for a second reason — a comment inside a uses clause exists
   to pin a position ("cthreads must come first so TThread has a
   driver"), so sorting past it would silently invalidate the note it
   carries. The clause is the smallest thing the formatter can leave
   alone; a comment anywhere in it makes the whole clause author-owned.

   Detection deliberately does not reuse StripLineComment: that helper
   truncates at the first comment marker, which is exactly what made the
   caller lose the clause-terminating `;` and swallow the rest of the
   file. String literals are skipped so a `Unit in 'some/path.pas'`
   entry can never be mistaken for a comment. *)
function ContainsDirectiveOrComment(const AText: string): Boolean;
var
  I: Integer;
  InStr: Boolean;
begin
  I := 1;
  InStr := False;
  while I <= Length(AText) do
  begin
    if InStr then
    begin
      if AText[I] = '''' then
        InStr := False;
    end
    else if AText[I] = '''' then
      InStr := True
    else if AText[I] = '{' then
      Exit(True)
    else if (I < Length(AText)) and (AText[I] = '(') and (AText[I + 1] = '*') then
      Exit(True)
    else if (I < Length(AText)) and (AText[I] = '/') and (AText[I + 1] = '/') then
      Exit(True);
    Inc(I);
  end;
  Result := False;
end;

function StripLineComment(const ALine: string): string;
var
  I: Integer;
  InStr: Boolean;
begin
  I := 1;
  InStr := False;
  while I <= Length(ALine) do
  begin
    if InStr then
    begin
      if (ALine[I] = '''') then
      begin
        if (I < Length(ALine)) and (ALine[I + 1] = '''') then
        begin
          Inc(I, 2);
          Continue;
        end;
        InStr := False;
      end;
    end
    else
    begin
      if ALine[I] = '''' then
        InStr := True
      else if (ALine[I] = '/') and (I < Length(ALine)) and (ALine[I + 1] = '/') then
      begin
        Result := Copy(ALine, 1, I - 1);
        Exit;
      end
      else if ALine[I] = '{' then
      begin
        Result := Copy(ALine, 1, I - 1);
        Exit;
      end;
    end;
    Inc(I);
  end;
  Result := ALine;
end;

{ Flags each line whose first code token is the uses keyword. The clause
  parser reads the raw line, so a keyword that only follows a comment's
  close on the same line is not flagged; prose inside any comment form
  never is. }
function MarkUsesClauseStarts(const ALines: TStringList): TLineFlags;
var
  Map: TCodeMap;
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ALines.Count);
  Map := TCodeMap.Create(ALines);
  try
    for I := 0 to ALines.Count - 1 do
      Result[I] := Map.StartsWithCode(I) and IsUsesKeyword(ALines[I]);
  finally
    Map.Free;
  end;
end;

procedure FormatUsesInLines(const AInput: TStringList; const AOutput: TStringList);
var
  I, J: Integer;
  UsesContent, AfterUses, FullBlock, BeforeSC: string;
  Units, Formatted: TStringList;
  ClauseStarts: TLineFlags;
begin
  ClauseStarts := MarkUsesClauseStarts(AInput);
  I := 0;
  while I < AInput.Count do
  begin
    if ClauseStarts[I] then
    begin
      FullBlock := AInput[I];
      J := I;
      BeforeSC := StripLineComment(FullBlock);

      while (Pos(';', BeforeSC) = 0) and (J + 1 < AInput.Count) do
      begin
        Inc(J);
        FullBlock := FullBlock + #10 + AInput[J];
        BeforeSC := StripLineComment(AInput[J]);
      end;

      if ContainsDirectiveOrComment(FullBlock) then
      begin
        (* The clause starts are precomputed from the whole file, so a
           brace opened inside the clause still reads as open on the
           lines after the passthrough, and prose inside that comment is
           never mistaken for the next clause.

           One known limit, pre-existing and harmless now that a
           commented clause is emitted verbatim: the terminator scan
           above overshoots a clause that ends `{ … };` — StripLineComment
           cuts at the brace, so the `;` behind it is invisible and J
           runs on to the next semicolon. The overshot lines are
           re-emitted unchanged; the only cost is that a clause landing
           inside that range is left unformatted. *)
        while I <= J do
        begin
          AOutput.Add(AInput[I]);
          Inc(I);
        end;
        Continue;
      end;

      AfterUses := Trim(AInput[I]);
      if LowerCase(AfterUses) = 'uses' then
        UsesContent := ''
      else
        UsesContent := Trim(Copy(AfterUses, 5, Length(AfterUses)));

      J := I;
      while (Pos(';', StripLineComment(UsesContent)) = 0) and (J + 1 < AInput.Count) do
      begin
        Inc(J);
        UsesContent := UsesContent + ' ' + Trim(AInput[J]);
      end;

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
          AOutput.Add(AInput[I]);
      finally
        Units.Free;
      end;

      I := J + 1;
    end
    else
    begin
      AOutput.Add(AInput[I]);
      Inc(I);
    end;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Code Analysis Helpers
  ═══════════════════════════════════════════════════════════════════════════ }

function IsIdentChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function IsFuncDeclStart(const ALine: string): Boolean;
var
  Trimmed: string;
begin
  Trimmed := LowerCase(Trim(ALine));
  Result := (Pos('function ', Trimmed) = 1) or (Pos('procedure ', Trimmed) = 1) or
            (Pos('constructor ', Trimmed) = 1) or (Pos('destructor ', Trimmed) = 1) or
            (Pos('class function ', Trimmed) = 1) or (Pos('class procedure ', Trimmed) = 1);
end;

function IsModifier(const AWord: string): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(AWord);
  Result := (Lower = 'const') or (Lower = 'var') or (Lower = 'out') or (Lower = 'constref');
end;

function HasAPrefix(const AName: string): Boolean;
begin
  Result := (Length(AName) > 1) and (AName[1] = 'A') and (AName[2] in ['A'..'Z']);
end;

function IsPascalCase(const AName: string): Boolean;
begin
  if Length(AName) = 0 then
    Exit(True);
  Result := AName[1] in ['A'..'Z'];
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

function ExtractFuncName(const ADeclText: string): string;
var
  Trimmed, NamePart: string;
  SpacePos, ParenPos, DotPos, Idx: Integer;
begin
  Result := '';
  Trimmed := Trim(ADeclText);

  if LowerCase(Copy(Trimmed, 1, 6)) = 'class ' then
    Trimmed := Trim(Copy(Trimmed, 7, Length(Trimmed)));

  SpacePos := Pos(' ', Trimmed);
  if SpacePos = 0 then
    Exit;
  NamePart := Trim(Copy(Trimmed, SpacePos + 1, Length(Trimmed)));

  ParenPos := Pos('(', NamePart);
  if ParenPos > 0 then
    NamePart := Trim(Copy(NamePart, 1, ParenPos - 1));
  ParenPos := Pos(';', NamePart);
  if ParenPos > 0 then
    NamePart := Trim(Copy(NamePart, 1, ParenPos - 1));
  ParenPos := Pos(':', NamePart);
  if ParenPos > 0 then
    NamePart := Trim(Copy(NamePart, 1, ParenPos - 1));

  DotPos := 0;
  for Idx := Length(NamePart) downto 1 do
    if NamePart[Idx] = '.' then
    begin
      DotPos := Idx;
      Break;
    end;

  if DotPos > 0 then
    Result := Copy(NamePart, DotPos + 1, Length(NamePart))
  else
    Result := NamePart;
end;

{ Renames every code occurrence of AOld on one line; occurrences inside
  comments, directives and string literals are left alone. Member access
  (`X.Name`) is never renamed, nor is an AT&T assembler register
  (`%name`): outside asm, `%` only prefixes a binary literal, never an
  identifier. Returns True when the line changed. }
function RenameWordInLine(const ALines: TStringList; const AMap: TCodeMap;
  AIndex: Integer; const AOld, ANew: string): Boolean;
var
  Line, Renamed: string;
  I, OldLen: Integer;
begin
  Result := False;
  Line := ALines[AIndex];
  Renamed := '';
  OldLen := Length(AOld);
  I := 1;
  while I <= Length(Line) do
  begin
    { An identifier never contains a comment, directive or literal
      opener, so a match that starts on code is code throughout. }
    if AMap.IsCode(AIndex, I) and (I + OldLen - 1 <= Length(Line)) and
       (CompareText(Copy(Line, I, OldLen), AOld) = 0) and
       ((I = 1) or (not IsIdentChar(Line[I - 1]) and
         not (Line[I - 1] in ['.', '%']))) and
       ((I + OldLen > Length(Line)) or not IsIdentChar(Line[I + OldLen])) then
    begin
      Renamed := Renamed + ANew;
      Inc(I, OldLen);
      Result := True;
      Continue;
    end;
    Renamed := Renamed + Line[I];
    Inc(I);
  end;

  if Result then
  begin
    ALines[AIndex] := Renamed;
    AMap.Refresh(AIndex);
  end;
end;

function CountKeywordOnLine(const AStripped, AKeyword: string): Integer;
var
  Lower: string;
  P, KLen: Integer;
begin
  Result := 0;
  Lower := LowerCase(AStripped);
  KLen := Length(AKeyword);
  P := 1;
  while P + KLen - 1 <= Length(Lower) do
  begin
    if (Copy(Lower, P, KLen) = AKeyword) and
       ((P = 1) or not IsIdentChar(Lower[P - 1])) and
       ((P + KLen > Length(Lower)) or not IsIdentChar(Lower[P + KLen])) then
    begin
      Inc(Result);
      P := P + KLen;
    end
    else
      Inc(P);
  end;
end;

{ A routine header is recognised only in code: its keyword must be the
  first code token on the line. Prose inside a comment that begins with
  `function` or `procedure` is blank in the code text and never matches. }
function IsRoutineHeader(const AMap: TCodeMap; AIndex: Integer): Boolean;
begin
  Result := IsFuncDeclStart(AMap.CodeText(AIndex));
end;

{ The last line of the header's parameter list: parentheses are counted
  in code only, so a parenthesis in a trailing comment or a default
  string value cannot stretch the header over the lines after it. }
function FindDeclEnd(const AMap: TCodeMap; ADeclStart: Integer): Integer;

  function ParenBalance(const ACode: string): Integer;
  var
    K: Integer;
  begin
    Result := 0;
    for K := 1 to Length(ACode) do
      if ACode[K] = '(' then Inc(Result)
      else if ACode[K] = ')' then Dec(Result);
  end;

var
  Depth, LastLine: Integer;
begin
  Result := ADeclStart;
  LastLine := AMap.Count - 1;
  Depth := ParenBalance(AMap.CodeText(ADeclStart));
  while (Depth > 0) and (Result < LastLine) do
  begin
    Inc(Result);
    Depth := Depth + ParenBalance(AMap.CodeText(Result));
  end;
end;

{ The code text of header lines ADeclStart..ADeclEnd, joined by spaces. }
function HeaderCode(const AMap: TCodeMap; ADeclStart, ADeclEnd: Integer): string;
var
  J: Integer;
begin
  Result := AMap.CodeText(ADeclStart);
  for J := ADeclStart + 1 to ADeclEnd do
    Result := Result + ' ' + Trim(AMap.CodeText(J));
end;

function IsExternalDeclaration(const AMap: TCodeMap; AStartLine: Integer): Boolean;
begin
  Result := Pos(' external ', LowerCase(HeaderCode(AMap, AStartLine,
    FindDeclEnd(AMap, AStartLine)))) > 0;
end;

{ A forward header owns no body: the code after it belongs to other
  routines or to the enclosing program. }
function IsForwardDeclaration(const AMap: TCodeMap; ADeclStart, ADeclEnd: Integer): Boolean;
begin
  Result := CountKeywordOnLine(HeaderCode(AMap, ADeclStart, ADeclEnd), 'forward') > 0;
end;

{ Find the line index of the function's closing `end;`. Walks forward
  from the end of the declaration looking for the body's `begin`, then
  tracks block depth (begin/try/case/record each +1; end -1) until depth
  drops back to zero.

  Nested constructs in the function-local declaration section
  (`var`/`type`/`const` between signature and `begin`) are handled
  explicitly:
    - Nested function/procedure declarations are recursively skipped
      past their own end, so their begin/end pair does not bleed into
      the outer depth count.
    - Nested record types contribute a `record .. end` pair; counting
      `record` as a depth-up keyword keeps the math balanced.
    - Local `type` / `var` / `const` sections themselves are inert —
      no early exit on those keywords.
  Unit-scope keywords (`implementation`, `interface`) DO indicate we've
  walked out of the function entirely; bail in that case. So does an
  `end` that closes more than the declaration section opened before any
  body: the header was a member of a class, object or record type and
  owns no body. An `asm` block opens a body the same way `begin` does.

  -1 means the header owns no body. Callers then confine a parameter
  rename to the header, so it can never run on into the code of the
  routines or program block that follow. }
function FindFuncEnd(const AMap: TCodeMap; ADeclEnd: Integer): Integer;
var
  I, Depth, Opened, NestedDeclEnd, NestedBodyEnd: Integer;
  Code: string;
  FoundBegin: Boolean;
begin
  Result := -1;
  Depth := 0;
  FoundBegin := False;
  I := ADeclEnd + 1;

  while I < AMap.Count do
  begin
    Code := AMap.CodeText(I);

    if not FoundBegin then
    begin
      { Nested function / procedure declaration in the outer function's
        var section. Recursively find its body end and skip past it so
        its begin/end pair is not counted toward our outer depth. A
        nested external or forward header has no body to skip. }
      if IsRoutineHeader(AMap, I) then
      begin
        NestedDeclEnd := FindDeclEnd(AMap, I);
        if IsExternalDeclaration(AMap, I) or
           IsForwardDeclaration(AMap, I, NestedDeclEnd) then
        begin
          I := NestedDeclEnd + 1;
          Continue;
        end;
        NestedBodyEnd := FindFuncEnd(AMap, NestedDeclEnd);
        if NestedBodyEnd = -1 then
          Exit(-1);
        I := NestedBodyEnd + 1;
        Continue;
      end;
      { Walking out of the function entirely without finding a begin. }
      if (CountKeywordOnLine(Code, 'implementation') > 0) or
         (CountKeywordOnLine(Code, 'interface') > 0) then
        Exit(-1);
    end;

    Opened := CountKeywordOnLine(Code, 'begin') + CountKeywordOnLine(Code, 'asm');
    Depth := Depth + Opened
                    + CountKeywordOnLine(Code, 'try')
                    + CountKeywordOnLine(Code, 'record')
                    - CountKeywordOnLine(Code, 'end');
    { Before the body, `case` can only select a variant record's part and
      shares the record's `end`; only a case statement has its own. }
    if FoundBegin or (Opened > 0) then
      Depth := Depth + CountKeywordOnLine(Code, 'case');

    if not FoundBegin then
    begin
      if Opened > 0 then
        FoundBegin := True
      else if Depth < 0 then
        Exit(-1);
    end;

    if FoundBegin and (Depth <= 0) then
    begin
      Result := I;
      Exit;
    end;

    Inc(I);
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: PascalCase Function Names
  ═══════════════════════════════════════════════════════════════════════════ }

function FixFuncNames(const ALines: TStringList): Boolean;
var
  I, J, K: Integer;
  FuncName, NewName: string;
  OldNames, NewNames: TStringList;
  Map: TCodeMap;
begin
  Result := False;
  Map := TCodeMap.Create(ALines);
  OldNames := TStringList.Create;
  NewNames := TStringList.Create;
  try
    for I := 0 to ALines.Count - 1 do
    begin
      if IsRoutineHeader(Map, I) and not IsExternalDeclaration(Map, I) then
      begin
        FuncName := ExtractFuncName(Map.CodeText(I));
        if (FuncName <> '') and not IsPascalCase(FuncName) then
        begin
          NewName := UpCase(FuncName[1]) + Copy(FuncName, 2, Length(FuncName));
          K := OldNames.IndexOf(FuncName);
          if K = -1 then
          begin
            OldNames.Add(FuncName);
            NewNames.Add(NewName);
          end;
        end;
      end;
    end;

    if OldNames.Count > 0 then
    begin
      Result := True;
      for K := 0 to OldNames.Count - 1 do
        for J := 0 to ALines.Count - 1 do
          RenameWordInLine(ALines, Map, J, OldNames[K], NewNames[K]);
    end;
  finally
    OldNames.Free;
    NewNames.Free;
    Map.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: Parameter A Prefix
  ═══════════════════════════════════════════════════════════════════════════ }

procedure ParseParamNames(const ADeclText: string;
  const AOldNames, ANewNames: TStringList);
var
  ParenStart, ParenEnd, ColonPos, Depth, K, Sp: Integer;
  Inner, GroupStr, Rest, NamesStr, ParamName, FirstWord, NewName: string;
  Groups: TStringList;
  Ch: Char;
  Current: string;
var
  SemiPos: Integer;
begin
  SemiPos := Pos(';', ADeclText);
  ParenStart := Pos('(', ADeclText);
  if (ParenStart = 0) or ((SemiPos > 0) and (ParenStart > SemiPos)) then
    Exit;

  Depth := 0;
  ParenEnd := 0;
  for K := ParenStart to Length(ADeclText) do
  begin
    if ADeclText[K] = '(' then Inc(Depth)
    else if ADeclText[K] = ')' then
    begin
      Dec(Depth);
      if Depth = 0 then
      begin
        ParenEnd := K;
        Break;
      end;
    end;
  end;
  if ParenEnd = 0 then
    Exit;

  Inner := Trim(Copy(ADeclText, ParenStart + 1, ParenEnd - ParenStart - 1));
  if Inner = '' then
    Exit;

  Groups := TStringList.Create;
  try
    Depth := 0;
    Current := '';
    for K := 1 to Length(Inner) do
    begin
      Ch := Inner[K];
      if Ch in ['(', '['] then
      begin
        Inc(Depth);
        Current := Current + Ch;
      end
      else if Ch in [')', ']'] then
      begin
        Dec(Depth);
        Current := Current + Ch;
      end
      else if (Ch = ';') and (Depth = 0) then
      begin
        Groups.Add(Trim(Current));
        Current := '';
      end
      else
        Current := Current + Ch;
    end;
    if Trim(Current) <> '' then
      Groups.Add(Trim(Current));

    for K := 0 to Groups.Count - 1 do
    begin
      GroupStr := Trim(Groups[K]);
      if GroupStr = '' then
        Continue;

      Rest := GroupStr;
      FirstWord := '';
      Sp := Pos(' ', Rest);
      if Sp > 0 then
        FirstWord := Copy(Rest, 1, Sp - 1);
      if IsModifier(FirstWord) then
        Rest := Trim(Copy(Rest, Length(FirstWord) + 1, Length(Rest)));

      ColonPos := Pos(':', Rest);
      if ColonPos > 0 then
        NamesStr := Trim(Copy(Rest, 1, ColonPos - 1))
      else
        NamesStr := Trim(Rest);

      while Pos(',', NamesStr) > 0 do
      begin
        ParamName := Trim(Copy(NamesStr, 1, Pos(',', NamesStr) - 1));
        NamesStr := Trim(Copy(NamesStr, Pos(',', NamesStr) + 1, Length(NamesStr)));
        if (ParamName <> 'Self') and (Length(ParamName) > 1) and
           not HasAPrefix(ParamName) then
        begin
          NewName := 'A' + UpCase(ParamName[1]) + Copy(ParamName, 2, Length(ParamName));
          if not IsPascalKeyword(NewName) and (AOldNames.IndexOf(ParamName) = -1) then
          begin
            AOldNames.Add(ParamName);
            ANewNames.Add(NewName);
          end;
        end;
      end;

      ParamName := Trim(NamesStr);
      if (ParamName <> '') and (ParamName <> 'Self') and (Length(ParamName) > 1) and
         not HasAPrefix(ParamName) then
      begin
        NewName := 'A' + UpCase(ParamName[1]) + Copy(ParamName, 2, Length(ParamName));
        if not IsPascalKeyword(NewName) and (AOldNames.IndexOf(ParamName) = -1) then
        begin
          AOldNames.Add(ParamName);
          ANewNames.Add(NewName);
        end;
      end;
    end;
  finally
    Groups.Free;
  end;
end;

function FixParamNames(const ALines: TStringList): Boolean;
var
  I, J, K, DeclEnd, BodyEnd: Integer;
  OldNames, NewNames: TStringList;
  Map: TCodeMap;
begin
  Result := False;
  Map := TCodeMap.Create(ALines);
  try
    I := 0;
    while I < ALines.Count do
    begin
      if IsRoutineHeader(Map, I) and not IsExternalDeclaration(Map, I) then
      begin
        DeclEnd := FindDeclEnd(Map, I);

        OldNames := TStringList.Create;
        NewNames := TStringList.Create;
        try
          ParseParamNames(HeaderCode(Map, I, DeclEnd), OldNames, NewNames);

          if OldNames.Count > 0 then
          begin
            Result := True;

            { The rename covers the header and the body it owns, nothing
              more: a header without a body keeps it in the header. }
            if IsForwardDeclaration(Map, I, DeclEnd) then
              BodyEnd := -1
            else
              BodyEnd := FindFuncEnd(Map, DeclEnd);
            if BodyEnd = -1 then
              BodyEnd := DeclEnd;

            for K := 0 to OldNames.Count - 1 do
              for J := I to BodyEnd do
                RenameWordInLine(ALines, Map, J, OldNames[K], NewNames[K]);
          end;
        finally
          OldNames.Free;
          NewNames.Free;
        end;

        I := DeclEnd + 1;
      end
      else
        Inc(I);
    end;
  finally
    Map.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  Auto-Fix: Stray Spaces
  ═══════════════════════════════════════════════════════════════════════════ }

function FixStraySpaces(const ALines: TStringList): Boolean;
var
  I, J, SpaceStart: Integer;
  Line: string;
  Map: TCodeMap;
begin
  Result := False;
  Map := TCodeMap.Create(ALines);
  try
    for I := 0 to ALines.Count - 1 do
    begin
      Line := ALines[I];
      J := 1;
      while J <= Length(Line) do
      begin
        { A space that is code is followed by code up to the next
          non-space character, so only that character needs checking. }
        if Map.IsCode(I, J) and (Line[J] = ' ') and (J > 1) and
           (Line[J - 1] <> ' ') and (not (Line[J - 1] in [#9, '(', ','])) then
        begin
          SpaceStart := J;
          while (J + 1 <= Length(Line)) and (Line[J + 1] = ' ') do
            Inc(J);
          if Map.IsCode(I, J + 1) and (Line[J + 1] in [';', ')', ',']) then
          begin
            Delete(Line, SpaceStart, J - SpaceStart + 1);
            ALines[I] := Line;
            Map.Refresh(I);
            Result := True;
            J := SpaceStart;
            Continue;
          end;
        end;
        Inc(J);
      end;
    end;
  finally
    Map.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════════
  File Processing
  ═══════════════════════════════════════════════════════════════════════════ }

function FormatFile(const AFilePath: string; AMode: TRunMode): Boolean;
var
  Lines, ResultLines: TStringList;
begin
  Result := False;
  Lines := TStringList.Create;
  ResultLines := TStringList.Create;
  try
    Lines.LoadFromFile(AFilePath);

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

end.
