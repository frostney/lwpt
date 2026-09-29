{ PayloadHandoffGuard.Test — a heuristic tripwire that keeps cross-process
  payload files in test code on the Tests.PayloadHandoff protocol.

  A file that one process writes and another reads is handed over through
  an existence-only <path>.complete marker, never through the payload's own
  existence (tests/support/Tests.PayloadHandoff.pas records the history:
  #205, #262, PR #289, and main's push run 36593670809). Those flakes were
  fixed one site at a time while sibling sites kept the bug, so this program
  scans the repository's test code and fails when a known shape returns. A
  clean run is not proof that every handoff is safe.

  Files are tokenized and split into routines by LWPT.Analysis.Pascal, the
  analyzer behind lwpt health and lwpt duplication. Like those commands it
  reads inactive conditional branches as well. A headerless fragment (an
  include file, a generated snippet) is analyzed inside a synthetic program
  shell. A string expression in any region, declarations included, that
  decodes to Pascal is analyzed again as a generated fixture program, one
  scope per generated routine. Each spliced-in value (PascalString(X),
  IntToStr(...)) is a placeholder carrying X's expression, and each
  EmitPayloadCompletion(..., P) becomes a completion call on P. Four rules,
  each within one routine body:

    raw-pid-write            A process ID is written to a file by a raw write
                             (a Write* helper with the PID in a content
                             argument, Write/WriteLn to a text file assigned
                             to a path, or X.Text := / X.Add(...) with the
                             PID followed by any X.SaveToFile(path) before X
                             is cleared, refilled, or freed), and no later
                             PublishPayloadCompletion call names the same
                             path, compared token by token with
                             identifiers case-insensitive. Use
                             PublishReadablePayload.
    polled-raw-read          FileExists(E) is called inside a while, for, or
                             repeat loop and E is read with a raw reader.
    payload-raw-read         E is gated by PayloadIsReadable but read without
                             ReadPayloadText.
    existence-polled-payload FileExists(E) is polled in a loop although E is
                             published with PublishReadablePayload or a
                             completion marker somewhere in the same file.
                             Only this rule compares paths loosely, dropping
                             the Delphi parameter prefix (APIDFile matches
                             PIDFile), because it discovers suspicious
                             barriers rather than proving a write complete.

  Limits. There is no control-flow analysis: "later" means later in the
  text, a completion in an untaken branch counts, a read and its poll are
  paired wherever they sit in the routine, and Write(F, ...) resolves F
  through the textually latest Assign. Paths are compared as text, so one
  path under two variable names (a test's Marker handed to a proxy that
  calls it PIDFile) is not recognized, and a PID passed through an
  intermediate variable is not seen. A polling helper whose reader lives in
  another routine is out of reach. Read, ReadLn, and ReadBuffer are not
  treated as raw readers. Include directives are not followed. A string is
  a fixture only when it contains a semicolon and tokenizes as Pascal, and
  fixture source nested inside a fixture's own literals is not decoded
  again. Atomic writers (AtomicWrite*, write-then-rename) publish complete
  content and are outside the rules.

  Justified exceptions go in HandoffAllowlist. An allowance names one site:
  file, rule, routine, and the payload expression. It fails the run when it
  matches no finding or more than one, and self-tests prove every rule
  still detects the historical violations. }

program PayloadHandoffGuard.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,
  Types,

  LWPT.Analysis.Pascal,
  TestingPascalLibrary,
  Tests.Scratch;

const
  RulePIDWrite = 'raw-pid-write';
  RulePolledRead = 'polled-raw-read';
  RulePayloadRead = 'payload-raw-read';
  RulePolledPayload = 'existence-polled-payload';
  RuleUnscannable = 'unscannable';
  GluePrefix = 'lwpthandoffglue';
  { The self-tests below embed violating snippets as literals. }
  GuardProgramPath = 'tests/integration/PayloadHandoffGuard.Test.pas';
  { A scan that finds almost nothing is scanning the wrong tree. }
  MinimumScannedFiles = 50;

type
  THandoffFinding = record
    Path: string;
    Line: Integer;
    Rule: string;
    Routine: string;
    Key: string;
    Evidence: string;
  end;
  THandoffFindings = array of THandoffFinding;

  THandoffAllowance = record
    Path: string;
    Rule: string;
    Routine: string;
    { The normalized payload expression the finding reports. }
    Key: string;
  end;
  THandoffAllowances = array of THandoffAllowance;

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
    Tokens: TGuardTokens;
  end;
  TGuardScopes = array of TGuardScope;

  TTokenRange = record
    First: Integer;
    Last: Integer;
  end;
  TTokenRanges = array of TTokenRange;

  TPayloadHandoffGuard = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRepositoryFollowsTheProtocol;
    procedure TestEveryAllowanceMatchesOneSite;
    procedure TestScanCoversTheTestTree;
    procedure TestRawPIDWritesAreDetected;
    procedure TestCompletionMustNameThePayload;
    procedure TestGeneratedRoutinesAndFragments;
    procedure TestExistenceGatedReadsAreDetected;
    procedure TestPublishedPayloadPollsAreDetected;
    procedure TestPublishedHandoffsPass;
    procedure TestUnrelatedPIDUsesPass;
  end;

{ Justified exceptions, one site each, with the reason beside the entry. }
function HandoffAllowlist: THandoffAllowances;

  procedure Allow(const APath, ARule, ARoutine, AKey: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Path := APath;
    Result[High(Result)].Rule := ARule;
    Result[High(Result)].Routine := ARoutine;
    Result[High(Result)].Key := AKey;
  end;

begin
  Result := nil;
  { A delegation report the parent reads only after this utility exits
    (RunUtility waits for it); the PID is diagnostic text in the report. }
  Allow('source/LWPT.WorkerBudget.Test.pas', RulePIDWrite, 'runchildmode',
    'outputpath');
end;

function AllowanceMatches(const AAllowance: THandoffAllowance;
  const AFinding: THandoffFinding): Boolean;
begin
  Result := (AAllowance.Path = AFinding.Path)
    and (AAllowance.Rule = AFinding.Rule)
    and (AAllowance.Routine = AFinding.Routine)
    and (AAllowance.Key = AFinding.Key);
end;

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

function IsPIDToken(const ATokens: TGuardTokens; AIndex: Integer): Boolean;
var
  Text: string;
begin
  if not IsCodeToken(ATokens[AIndex]) then Exit(False);
  Text := ATokens[AIndex].Text;
  Result := (Text = 'getprocessid') or (Text = 'getcurrentprocessid')
    or (Text = 'fpgetpid') or (Text = 'getpid')
    or ((Text = 'processid') and TokenIs(ATokens, AIndex - 1, '.'));
end;

function RangeHasPID(const ATokens: TGuardTokens;
  const ARange: TTokenRange): Boolean;
var
  Index: Integer;
begin
  for Index := ARange.First to ARange.Last do
    if IsPIDToken(ATokens, Index) then Exit(True);
  Result := False;
end;

{ Loop bodies ------------------------------------------------------------ }

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

{ Rules ------------------------------------------------------------------ }

procedure AddFinding(var AFindings: THandoffFindings; const APath: string;
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

{ Every payload the scope publishes, with the token index of the call. }
procedure CollectPublications(const ATokens: TGuardTokens;
  APublished: TStrings; ALoose: Boolean = False);
var
  Index: Integer;
  Key: string;
begin
  for Index := 0 to High(ATokens) - 1 do
    if (IsCallAt(ATokens, Index, 'publishpayloadcompletion')
        or IsCallAt(ATokens, Index, 'publishreadablepayload'))
       and FirstArgumentKey(ATokens, Index + 1, Key, ALoose) then
      APublished.AddObject(Key, TObject(PtrInt(Index)));
end;

function CompletedAfter(APublished: TStrings; AIndex: Integer;
  const AKey: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to APublished.Count - 1 do
    if (APublished[Index] = AKey)
       and (PtrInt(APublished.Objects[Index]) > AIndex) then Exit(True);
  Result := False;
end;

function IsConsoleFile(const AText: string): Boolean;
begin
  Result := (AText = 'output') or (AText = 'erroutput') or (AText = 'stdout')
    or (AText = 'stderr') or (AText = 'input');
end;

{ The path a text-file variable was last assigned before AIndex. }
function AssignedPath(const ATokens: TGuardTokens; AIndex: Integer;
  const AVariable: string): string;
var
  Arguments: TTokenRanges;
  Closed: Boolean;
  Index: Integer;
begin
  for Index := AIndex - 1 downto 0 do
    if IsCallAt(ATokens, Index, 'assign')
       or IsCallAt(ATokens, Index, 'assignfile') then
    begin
      Arguments := CallArguments(ATokens, Index + 1, Closed);
      if (Length(Arguments) = 2)
         and (RangeKey(ATokens, Arguments[0]) = AVariable) then
        Exit(RangeKey(ATokens, Arguments[1]));
    end;
  Result := AVariable;
end;

{ Returns the written path's key when the call at AIndex writes a PID into
  file content. }
function RawPIDWrite(const ATokens: TGuardTokens; AIndex: Integer;
  out AKey: string): Boolean;
var
  Arguments: TTokenRanges;
  ArgumentIndex: Integer;
  Closed, Qualified: Boolean;
  Name: string;
begin
  Result := False;
  if not IsCodeToken(ATokens[AIndex])
     or not TokenIs(ATokens, AIndex + 1, '(') then Exit;
  Name := ATokens[AIndex].Text;
  if (Copy(Name, 1, 5) <> 'write') or (Name = 'writefile')
     or (Name = 'writebuffer') then Exit;
  Qualified := TokenIs(ATokens, AIndex - 1, '.');
  Arguments := CallArguments(ATokens, AIndex + 1, Closed);
  if not Closed or (Length(Arguments) < 2) then Exit;
  if (Name = 'write') or (Name = 'writeln') then
  begin
    { Only Write(TextFile, ...) reaches a file; stream methods and console
      output do not. }
    if Qualified or (Arguments[0].First <> Arguments[0].Last)
       or (ATokens[Arguments[0].First].Kind <> ptIdentifier)
       or IsConsoleFile(ATokens[Arguments[0].First].Text) then Exit;
    AKey := AssignedPath(ATokens, AIndex, RangeKey(ATokens, Arguments[0]));
  end
  else
    AKey := RangeKey(ATokens, Arguments[0]);
  for ArgumentIndex := 1 to High(Arguments) do
    if RangeHasPID(ATokens, Arguments[ArgumentIndex]) then Exit(True);
end;

{ The collection X filled with a PID at AIndex (X.Text := ... or
  X.Add/Append(...)), or ''. }
function PIDFilledCollection(const ATokens: TGuardTokens;
  AIndex: Integer): string;
var
  Arguments: TTokenRanges;
  ArgumentIndex: Integer;
  Closed: Boolean;
  Member: string;
  Rest: TTokenRange;
begin
  Result := '';
  if (ATokens[AIndex].Kind <> ptIdentifier)
     or not TokenIs(ATokens, AIndex + 1, '.')
     or (AIndex + 3 > High(ATokens)) then Exit;
  Member := ATokens[AIndex + 2].Text;
  if (Member = 'text') and TokenIs(ATokens, AIndex + 3, ':=') then
  begin
    Rest.First := AIndex + 4;
    Rest.Last := SimpleStatementEnd(ATokens, AIndex + 4);
    if RangeHasPID(ATokens, Rest) then Result := ATokens[AIndex].Text;
  end
  else if ((Member = 'add') or (Member = 'append'))
    and TokenIs(ATokens, AIndex + 3, '(') then
  begin
    Arguments := CallArguments(ATokens, AIndex + 3, Closed);
    for ArgumentIndex := 0 to High(Arguments) do
      if RangeHasPID(ATokens, Arguments[ArgumentIndex]) then
        Exit(ATokens[AIndex].Text);
  end;
end;

{ True when the collection at AIndex is refilled, cleared, or released, so
  it no longer carries the earlier PID. }
function CollectionReset(const ATokens: TGuardTokens; AIndex: Integer;
  const ACollection: string): Boolean;
begin
  if (ATokens[AIndex].Kind = ptIdentifier)
     and (ATokens[AIndex].Text = ACollection) then
  begin
    if TokenIs(ATokens, AIndex + 1, ':=') then Exit(True);
    if TokenIs(ATokens, AIndex + 1, '.') and (AIndex + 2 <= High(ATokens))
       and ((ATokens[AIndex + 2].Text = 'clear')
         or (ATokens[AIndex + 2].Text = 'free')
         or ((ATokens[AIndex + 2].Text = 'text')
           and TokenIs(ATokens, AIndex + 3, ':='))) then Exit(True);
  end;
  Result := IsCallAt(ATokens, AIndex, 'freeandnil')
    and (AIndex + 2 <= High(ATokens))
    and (ATokens[AIndex + 2].Text = ACollection);
end;

procedure ScanRawPIDWrites(const APath: string; const ALines: TStrings;
  const AScope: TGuardScope; APublished: TStrings;
  var AFindings: THandoffFindings);
var
  Collection, Key: string;
  Index, Save: Integer;
  Reported: TBooleanDynArray;
  Tokens: TGuardTokens;
begin
  Tokens := AScope.Tokens;
  Reported := nil;
  SetLength(Reported, Length(Tokens));
  for Index := 0 to High(Tokens) - 1 do
  begin
    if RawPIDWrite(Tokens, Index, Key)
       and not CompletedAfter(APublished, Index, Key) then
      AddFinding(AFindings, APath, ALines, Tokens[Index].Line, RulePIDWrite,
        AScope.Routine, Key);
    Collection := PIDFilledCollection(Tokens, Index);
    if Collection = '' then Continue;
    { Every save while the collection still carries the PID is a payload. }
    for Save := Index + 4 to High(Tokens) - 3 do
    begin
      if CollectionReset(Tokens, Save, Collection) then Break;
      if (Tokens[Save].Kind = ptIdentifier)
         and (Tokens[Save].Text = Collection) and TokenIs(Tokens, Save + 1, '.')
         and IsCallAt(Tokens, Save + 2, 'savetofile')
         and not Reported[Save]
         and FirstArgumentKey(Tokens, Save + 3, Key)
         and not CompletedAfter(APublished, Save, Key) then
      begin
        Reported[Save] := True;
        AddFinding(AFindings, APath, ALines, Tokens[Save].Line,
          RulePIDWrite, AScope.Routine, Key);
      end;
    end;
  end;
end;

function IsRawReader(const AToken: TGuardToken): Boolean;
begin
  if not IsCodeToken(AToken) then Exit(False);
  if AToken.Text = 'loadfromfile' then Exit(True);
  Result := (Copy(AToken.Text, 1, 4) = 'read') and (AToken.Text <> 'read')
    and (AToken.Text <> 'readln') and (AToken.Text <> 'readbuffer')
    and (AToken.Text <> 'readpayloadtext');
end;

procedure ScanReads(const APath: string; const ALines: TStrings;
  const AScope: TGuardScope; AFilePublished: TStrings;
  var AFindings: THandoffFindings);
var
  Gated, Polled: TStringList;
  InLoop: TBooleanDynArray;
  Index: Integer;
  Key, LooseKey: string;
  Tokens: TGuardTokens;
begin
  Tokens := AScope.Tokens;
  InLoop := LoopMask(Tokens);
  Polled := TStringList.Create;
  Gated := TStringList.Create;
  try
    for Index := 0 to High(Tokens) - 1 do
      if IsCallAt(Tokens, Index, 'fileexists') and InLoop[Index]
         and FirstArgumentKey(Tokens, Index + 1, Key) then
      begin
        Polled.Add(Key);
        if FirstArgumentKey(Tokens, Index + 1, LooseKey, True)
           and (AFilePublished.IndexOf(LooseKey) >= 0) then
          AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
            RulePolledPayload, AScope.Routine, LooseKey);
      end
      else if IsCallAt(Tokens, Index, 'payloadisreadable')
        and FirstArgumentKey(Tokens, Index + 1, Key) then
        Gated.Add(Key);
    for Index := 0 to High(Tokens) - 1 do
      if IsRawReader(Tokens[Index]) and TokenIs(Tokens, Index + 1, '(')
         and FirstArgumentKey(Tokens, Index + 1, Key) then
      begin
        if Polled.IndexOf(Key) >= 0 then
          AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
            RulePolledRead, AScope.Routine, Key)
        else if Gated.IndexOf(Key) >= 0 then
          AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
            RulePayloadRead, AScope.Routine, Key);
      end;
  finally
    Gated.Free;
    Polled.Free;
  end;
end;

{ Scopes ----------------------------------------------------------------- }

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
  const ATokens: TGuardTokens);
begin
  SetLength(AScopes, Length(AScopes) + 1);
  AScopes[High(AScopes)].Routine := ARoutine;
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
          on ELWPTPascalAnalysisError do ;
        end;
    finally
      Builder.GlueLooseKeys.Free;
      Builder.GlueKeys.Free;
    end;
  end;
end;

{ Adds one scope per executable region of AText. A headerless fragment (an
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
  FragmentHeader = 'program lwpthandofffragment; ';
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
    if PascalRegionIsExecutable(Region.Kind) then
      AddScope(AScopes, RegionLabel, Tokens);
    if ADecodeFixtures then AddFixtureScopes(RegionLabel, Tokens, AScopes);
  end;
end;

function ScanHandoffSource(const APath, ASource: string): THandoffFindings;
var
  FilePublished, ScopePublished: TStringList;
  Index: Integer;
  Lines: TStringList;
  Scopes: TGuardScopes;
begin
  Result := nil;
  Scopes := nil;
  Lines := TStringList.Create;
  FilePublished := TStringList.Create;
  ScopePublished := TStringList.Create;
  try
    Lines.Text := ASource;
    try
      AddTextScopes(ASource, SourceLineMap(ASource), '', nil, nil, True,
        Scopes);
    except
      on E: ELWPTPascalAnalysisError do
      begin
        AddFinding(Result, APath, Lines, 0, RuleUnscannable, '<file>',
          E.Message);
        Exit;
      end;
    end;
    for Index := 0 to High(Scopes) do
      CollectPublications(Scopes[Index].Tokens, FilePublished, True);
    for Index := 0 to High(Scopes) do
    begin
      ScopePublished.Clear;
      CollectPublications(Scopes[Index].Tokens, ScopePublished);
      ScanRawPIDWrites(APath, Lines, Scopes[Index], ScopePublished, Result);
      ScanReads(APath, Lines, Scopes[Index], FilePublished, Result);
    end;
  finally
    ScopePublished.Free;
    FilePublished.Free;
    Lines.Free;
  end;
end;


{ Repository scan -------------------------------------------------------- }

function IsScanTarget(const ARelativePath: string): Boolean;
var
  Extension, Name: string;
begin
  if ARelativePath = GuardProgramPath then Exit(False);
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

procedure CollectScanTargets(const ARelativeDirectory: string;
  AFiles: TStrings);
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
          CollectScanTargets(RelativePath, AFiles);
      end
      else if IsScanTarget(RelativePath) then
        AFiles.Add(RelativePath);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function ScanTargets: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  CollectScanTargets('source', Result);
  CollectScanTargets('tests', Result);
  CollectScanTargets('packages', Result);
end;

function RepositoryFindings: THandoffFindings;
var
  Files: TStringList;
  Finding: THandoffFinding;
  FileIndex: Integer;
begin
  Result := nil;
  Files := ScanTargets;
  try
    for FileIndex := 0 to Files.Count - 1 do
      for Finding in ScanHandoffSource(Files[FileIndex],
        ReadBinaryFile(Files[FileIndex])) do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Finding;
      end;
  finally
    Files.Free;
  end;
end;

function IsAllowed(const AFinding: THandoffFinding): Boolean;
var
  Allowance: THandoffAllowance;
begin
  for Allowance in HandoffAllowlist do
    if AllowanceMatches(Allowance, AFinding) then Exit(True);
  Result := False;
end;

function DescribeFinding(const AFinding: THandoffFinding): string;
begin
  Result := AFinding.Path + ':' + IntToStr(AFinding.Line) + ': '
    + AFinding.Rule + ' in ' + AFinding.Routine + ' on "' + AFinding.Key
    + '": ' + AFinding.Evidence;
end;

function RulesOf(const ASource: string): string;
var
  Finding: THandoffFinding;
begin
  Result := '';
  for Finding in ScanHandoffSource('synthetic.pas', ASource) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + Finding.Rule + '@' + IntToStr(Finding.Line);
  end;
end;

{ Tests ------------------------------------------------------------------ }

procedure TPayloadHandoffGuard.TestRepositoryFollowsTheProtocol;
var
  Finding: THandoffFinding;
  Violations: Integer;
begin
  Violations := 0;
  for Finding in RepositoryFindings do
    if not IsAllowed(Finding) then
    begin
      WriteLn('PAYLOAD HANDOFF VIOLATION ', DescribeFinding(Finding));
      Inc(Violations);
    end;
  if Violations > 0 then
    WriteLn('Hand payloads over with Tests.PayloadHandoff: writers call ',
      'PublishReadablePayload (or write, then PublishPayloadCompletion on ',
      'the same path; EmitPayloadCompletion in generated fixtures), and ',
      'readers and barriers wait for PayloadIsReadable (the .complete ',
      'marker in generated fixtures) and read with ReadPayloadText. See ',
      'docs/testing.md.');
  Expect<Integer>(Violations).ToBe(0);
end;

procedure TPayloadHandoffGuard.TestEveryAllowanceMatchesOneSite;
var
  Allowance: THandoffAllowance;
  Finding: THandoffFinding;
  Findings: THandoffFindings;
  Matches: Integer;
begin
  Findings := RepositoryFindings;
  for Allowance in HandoffAllowlist do
  begin
    Matches := 0;
    for Finding in Findings do
      if AllowanceMatches(Allowance, Finding) then Inc(Matches);
    if Matches <> 1 then
      WriteLn('PAYLOAD HANDOFF ALLOWANCE MATCHES ', Matches, ' SITES: ',
        Allowance.Path, ' ', Allowance.Rule, ' ', Allowance.Routine, ' "',
        Allowance.Key, '"');
    Expect<Integer>(Matches).ToBe(1);
  end;
end;

procedure TPayloadHandoffGuard.TestScanCoversTheTestTree;
var
  Files: TStringList;
begin
  Files := ScanTargets;
  try
    Expect<Boolean>(Files.Count >= MinimumScannedFiles).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'source/LWPT.Command.Build.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'tests/integration/TestScheduling.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'tests/support/Tests.PayloadHandoff.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'packages/httpclient/source/Tests.HTTPMockServer.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'packages/httpclient/tests/e2e/TransportSecuritySocket.E2E.Test.pas')
      >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf('source/LWPT.Core.pas') >= 0).ToBe(False);
    Expect<Boolean>(Files.IndexOf(GuardProgramPath) >= 0).ToBe(False);
    Expect<Boolean>(IsScanTarget('packages/demo/tests/Shared.inc'))
      .ToBe(True);
    Expect<Boolean>(IsScanTarget('packages/demo/source/Demo.pas'))
      .ToBe(False);
  finally
    Files.Free;
  end;
end;

procedure TPayloadHandoffGuard.TestRawPIDWritesAreDetected;
begin
  { The surviving-descendant proxy before 89f93a7 (run 36593670809). }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'function RunProxy: Integer;'#10
    + 'begin'#10
    + '  WriteTextFile(ParamStr(2), IntToStr(GetProcessID));'#10
    + '  Sleep(1000);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@4');
  { The escaped stdin holder's forked grandchild. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Hold(const APIDFile: string);'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.Text := IntToStr(FpGetPID);'#10
    + '    Lines.SaveToFile(APIDFile);'#10
    + '  finally'#10
    + '    Lines.Free;'#10
    + '  end;'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@7');
  { Generated fixtures without EmitPayloadCompletion (before #291). }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''begin'''#10
    + '    + ''    PIDFile.Text := IntToStr(Child.ProcessID);''#10'#10
    + '    + ''    PIDFile.SaveToFile('' + PascalString(P) + '');''#10'#10
    + '    + ''  PIDFile.Free;''#10'#10
    + '    + ''end.''#10);'#10
    + 'end.'#10)).ToBe(RulePIDWrite + '@6');
  Expect<string>(RulesOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''begin''#10'#10
    + '    + ''    Assign(PIDFile, '' + PascalString(HolderPath) + '');''#10'#10
    + '    + ''    Rewrite(PIDFile);''#10'#10
    + '    + ''    Write(PIDFile, Child.ProcessID);''#10'#10
    + '    + ''    Close(PIDFile);''#10'#10
    + '    + ''end.''#10);'#10
    + 'end.'#10)).ToBe(RulePIDWrite + '@7');
end;

procedure TPayloadHandoffGuard.TestCompletionMustNameThePayload;
begin
  { A completion for another path. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish;'#10
    + 'begin'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + '  PublishPayloadCompletion(UnrelatedPath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@4');
  { A completion in the next routine. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish;'#10
    + 'begin'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + 'end;'#10
    + 'procedure Complete;'#10
    + 'begin'#10
    + '  PublishPayloadCompletion(PIDPath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@4');
  { A completion that only appears in a diagnostic string. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish;'#10
    + 'begin'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + '  WriteLn(''PublishPayloadCompletion'');'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@4');
  { A completion before the write does not publish it. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish;'#10
    + 'begin'#10
    + '  PublishPayloadCompletion(PIDPath);'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@5');
  { APIDPath and PIDPath are different identifiers, so different paths. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish(const APIDPath: string);'#10
    + 'begin'#10
    + '  WriteTextFile(APIDPath, IntToStr(GetProcessID));'#10
    + '  PublishPayloadCompletion(PIDPath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@4');
  { A second save of the same PID collection needs its own completion. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish;'#10
    + 'begin'#10
    + '  Lines.Text := IntToStr(GetProcessID);'#10
    + '  Lines.SaveToFile(FirstPath);'#10
    + '  PublishPayloadCompletion(FirstPath);'#10
    + '  Lines.SaveToFile(SecondPath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@7');
  { A generated fixture completing another path. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''begin''#10'#10
    + '    + ''    Assign(PIDFile, '' + PascalString(HolderPath) + '');''#10'#10
    + '    + ''    Rewrite(PIDFile);''#10'#10
    + '    + ''    Write(PIDFile, Child.ProcessID);''#10'#10
    + '    + ''    Close(PIDFile);''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(OtherPath))'#10
    + '    + ''end.''#10);'#10
    + 'end.'#10)).ToBe(RulePIDWrite + '@7');
end;

procedure TPayloadHandoffGuard.TestGeneratedRoutinesAndFragments;
begin
  { A completion in another generated routine does not publish the write. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''program Fixture;''#10'#10
    + '    + ''procedure WritePID;''#10'#10
    + '    + ''var F: Text;''#10'#10
    + '    + ''begin''#10'#10
    + '    + ''  Assign(F, '' + PascalString(PIDPath) + '');''#10'#10
    + '    + ''  Rewrite(F);''#10'#10
    + '    + ''  Write(F, GetProcessID);''#10'#10
    + '    + ''  Close(F);''#10'#10
    + '    + ''end;''#10'#10
    + '    + ''procedure CompletePID;''#10'#10
    + '    + ''var CompleteFile: Text;''#10'#10
    + '    + ''begin''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(PIDPath))'#10
    + '    + ''end;''#10'#10
    + '    + ''begin WritePID end.''#10);'#10
    + 'end.'#10)).ToBe(RulePIDWrite + '@10');
  { An Assign in another generated routine does not name the write. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''program Fixture;''#10'#10
    + '    + ''var F: Text;''#10'#10
    + '    + ''procedure Open;''#10'#10
    + '    + ''begin''#10'#10
    + '    + ''  Assign(F, '' + PascalString(PIDPath) + '');''#10'#10
    + '    + ''end;''#10'#10
    + '    + ''procedure WritePID;''#10'#10
    + '    + ''var CompleteFile: Text;''#10'#10
    + '    + ''begin''#10'#10
    + '    + ''  Rewrite(F);''#10'#10
    + '    + ''  Write(F, GetProcessID);''#10'#10
    + '    + ''  Close(F);''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(PIDPath))'#10
    + '    + ''end;''#10'#10
    + '    + ''begin Open; WritePID end.''#10);'#10
    + 'end.'#10)).ToBe(RulePIDWrite + '@14');
  { A generated program held in a global constant. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'const'#10
    + '  Fixture = ''program Fixture;''#10'#10
    + '    + ''var F: Text;''#10'#10
    + '    + ''begin''#10'#10
    + '    + ''  Assign(F, ''''pid.txt'''');''#10'#10
    + '    + ''  Rewrite(F);''#10'#10
    + '    + ''  Write(F, GetProcessID);''#10'#10
    + '    + ''  Close(F);''#10'#10
    + '    + ''end.''#10;'#10
    + 'begin'#10
    + '  WriteTextFile(Path, Fixture);'#10
    + 'end.'#10)).ToBe(RulePIDWrite + '@8');
  { A generated fragment held in a routine's local constant. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Generate;'#10
    + 'const'#10
    + '  Fixture = ''begin''#10'#10
    + '    + ''  PIDFile.Text := IntToStr(GetProcessID);''#10'#10
    + '    + ''  PIDFile.SaveToFile(''''pid.txt'''');''#10'#10
    + '    + ''end.''#10;'#10
    + 'begin'#10
    + '  WriteTextFile(Path, Fixture);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePIDWrite + '@6');
  { A headerless include file with several routines. }
  Expect<string>(RulesOf(
      'procedure First;'#10
    + 'begin'#10
    + '  PublishReadablePayload(PIDPath, IntToStr(GetProcessID));'#10
    + 'end;'#10
    + #10
    + 'procedure Second;'#10
    + 'begin'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + 'end;'#10)).ToBe(RulePIDWrite + '@8');
  { A headerless include file of statements. }
  Expect<string>(RulesOf(
      'Lines.Text := IntToStr(GetProcessID);'#10
    + 'Lines.SaveToFile(PIDPath);'#10)).ToBe(RulePIDWrite + '@2');
end;

procedure TPayloadHandoffGuard.TestExistenceGatedReadsAreDetected;
begin
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure WaitAndRead;'#10
    + 'begin'#10
    + '  while not FileExists(PIDPath) do Sleep(10);'#10
    + '  PID := StrToInt(Trim(ReadBinaryFile(PIDPath)));'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePolledRead + '@5');
  { Polling after an earlier statement of the loop body. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure WaitAndRead;'#10
    + 'begin'#10
    + '  repeat'#10
    + '    Sleep(10);'#10
    + '    if FileExists(PayloadPath) then Break;'#10
    + '  until False;'#10
    + '  Contents := ReadBinaryFile(PayloadPath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePolledRead + '@8');
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure WaitAndLoad(const APath: string);'#10
    + 'begin'#10
    + '  while Child.Running do'#10
    + '  begin'#10
    + '    Drain;'#10
    + '    if FileExists(APath + ''-owner'') then Break;'#10
    + '  end;'#10
    + '  Lines.LoadFromFile(APath + ''-owner'');'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePolledRead + '@9');
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure ReadGated;'#10
    + 'begin'#10
    + '  if PayloadIsReadable(PIDPath) then'#10
    + '    PID := StrToInt(Trim(ReadBinaryFile(PIDPath)));'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePayloadRead + '@5');
end;

procedure TPayloadHandoffGuard.TestPublishedPayloadPollsAreDetected;
begin
  { A barrier that advances on the payload of a PID published elsewhere
    (the acknowledgement owner before this guard). }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Leaf(const APIDFile: string);'#10
    + 'begin'#10
    + '  PublishReadablePayload(APIDFile + ''-descendant'', IntToStr(GetProcessID));'#10
    + 'end;'#10
    + 'procedure Owner(const PIDFile: string);'#10
    + 'begin'#10
    + '  while not FileExists(PIDFile + ''-descendant'') do Sleep(10);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RulePolledPayload + '@8');
  { The same barrier in a generated fixture. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Compiler(const PIDFile: string);'#10
    + 'begin'#10
    + '  PublishReadablePayload(PIDFile, IntToStr(GetProcessID));'#10
    + 'end;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''begin''#10'#10
    + '    + ''  while (not FileExists('' + PascalString(PIDFile) + ''))''#10'#10
    + '    + ''    do Sleep(10);''#10'#10
    + '    + ''  Halt(1);''#10'#10
    + '    + ''end.''#10);'#10
    + 'end.'#10)).ToBe(RulePolledPayload + '@9');
end;

procedure TPayloadHandoffGuard.TestPublishedHandoffsPass;
begin
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Publish;'#10
    + 'begin'#10
    + '  PublishReadablePayload(ParamStr(2), IntToStr(GetProcessID));'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + '  PublishPayloadCompletion(PIDPath);'#10
    + '  Lines.Text := IntToStr(GetProcessID);'#10
    + '  Lines.SaveToFile(ReportPath);'#10
    + '  PublishPayloadCompletion(ReportPath);'#10
    + '  Lines.Clear;'#10
    + '  Lines.SaveToFile(EmptyPath);'#10
    + 'end;'#10
    + 'procedure Wait;'#10
    + 'begin'#10
    + '  while not PayloadIsReadable(PIDPath) do Sleep(10);'#10
    + '  PID := StrToInt(Trim(ReadPayloadText(PIDPath)));'#10
    + '  while not FileExists(PIDPath + PayloadCompleteSuffix) do Sleep(1);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe('');
  Expect<string>(RulesOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''begin''#10'#10
    + '    + ''    PIDFile.Text := IntToStr(Child.ProcessID);''#10'#10
    + '    + ''    PIDFile.SaveToFile('' + PascalString(P) + '');''#10'#10
    + '    + ''    PIDFile.Free;''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(P))'#10
    + '    + ''    Assign(PIDFile, '' + PascalString(Q) + '');''#10'#10
    + '    + ''    Rewrite(PIDFile);''#10'#10
    + '    + ''    Write(PIDFile, Child.ProcessID);''#10'#10
    + '    + ''    Close(PIDFile);''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(Q))'#10
    + '    + ''end.''#10);'#10
    + 'end.'#10)).ToBe('');
end;

procedure TPayloadHandoffGuard.TestUnrelatedPIDUsesPass;
begin
  { A PID in the path, on the console, in a stream, or in comments (brace,
    parenthesis-star, line, and inside a fixture string). }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure Unrelated;'#10
    + 'begin'#10
    + '  WriteTextFile(ReadyDir + ''/ready-'' + Name + ''-'''#10
    + '    + IntToStr(GetProcessID), ''ready'');'#10
    + '  WriteLn(ErrOutput, ''pid '', GetProcessID);'#10
    + '  WriteLn(FpGetpid, '' '', FpGetpgrp);'#10
    + '  Stream.Write(PID, SizeOf(GetProcessID));'#10
    + '  { WriteTextFile(Path, IntToStr(GetProcessID)); }'#10
    + '  (* WriteTextFile(Path, IntToStr(GetProcessID)); *)'#10
    + '  // WriteTextFile(Path, IntToStr(GetProcessID));'#10
    + '  WriteLn(''a (b; c'', ''{ WriteTextFile(P, IntToStr(GetProcessID)); }'');'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe('');
  { Polling and reading the same name in different routines. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'function WaitForFile(const APath: string): Boolean;'#10
    + 'begin'#10
    + '  while not FileExists(APath) do Sleep(10);'#10
    + 'end;'#10
    + 'function ReadMarkerText(const APath: string): string;'#10
    + 'begin'#10
    + '  Lines.LoadFromFile(APath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe('');
  { An existence check after the loop is not polling. }
  Expect<string>(RulesOf(
      'program P;'#10
    + 'procedure CheckAfterExit;'#10
    + 'begin'#10
    + '  while Child.Running do Sleep(10);'#10
    + '  if FileExists(ResponsePath) then'#10
    + '    Body := ReadBinaryFile(ResponsePath);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe('');
end;

procedure TPayloadHandoffGuard.SetupTests;
begin
  Test('repository test code follows the payload handoff protocol',
    TestRepositoryFollowsTheProtocol);
  Test('every allowance matches exactly one site',
    TestEveryAllowanceMatchesOneSite);
  Test('the scan covers the repository test tree',
    TestScanCoversTheTestTree);
  Test('raw PID writes are detected', TestRawPIDWritesAreDetected);
  Test('a completion must name the written payload',
    TestCompletionMustNameThePayload);
  Test('generated routines, constants, and include fragments are scanned',
    TestGeneratedRoutinesAndFragments);
  Test('existence-gated raw reads are detected',
    TestExistenceGatedReadsAreDetected);
  Test('existence polls of published payloads are detected',
    TestPublishedPayloadPollsAreDetected);
  Test('published handoffs pass', TestPublishedHandoffsPass);
  Test('unrelated PID uses pass', TestUnrelatedPIDUsesPass);
end;

begin
  TestRunnerProgram.AddSuite(TPayloadHandoffGuard.Create(
    'payload handoff guard'));
  TestRunnerProgram.Run;
end.
