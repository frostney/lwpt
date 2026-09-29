{ PayloadHandoffGuard.Test — keeps cross-process payload files in test code
  on the Tests.PayloadHandoff protocol.

  A file that one process writes and another reads is handed over through
  an existence-only <path>.complete marker, never through the payload's own
  existence (tests/support/Tests.PayloadHandoff.pas records the history:
  #205, #262, PR #289, and main's push run 36593670809). Those flakes were
  fixed one site at a time while sibling sites kept the bug, so this program
  scans the repository's test code and fails when the pattern returns.

  The scan is token-level. Comments are dropped, and string literals are
  scanned as the Pascal source they usually carry, so generated fixture
  programs are checked too. Three rules:

    raw-pid-write     A process ID reaches a file through a raw write: a
                      Write* helper with the PID in a content argument,
                      Write/WriteLn to a text-file variable, or X.Text :=
                      or X.Add/Append with the PID followed by
                      X.SaveToFile. A PID file exists only to be read by
                      another process. The write passes when
                      PublishPayloadCompletion or EmitPayloadCompletion
                      follows within four statements; otherwise use
                      PublishReadablePayload.
    polled-raw-read   A routine polls FileExists(E) in a loop and reads E
                      with a raw reader. Existence is not read ownership.
    payload-raw-read  A routine gates E with PayloadIsReadable but reads it
                      with a raw reader instead of ReadPayloadText.

  Atomic writers (AtomicWrite*, write-then-rename) publish complete content
  and are outside the rules. PIDs passed through an intermediate variable,
  and polling helpers that read in a different routine, are out of reach
  of a token scan; the rules target the shapes that actually recurred.

  Justified exceptions go in HandoffAllowlist, each with its reason. A
  stale allowance fails the run, and self-tests prove every rule still
  detects the historical violations. }

program PayloadHandoffGuard.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Scratch;

const
  RulePIDWrite = 'raw-pid-write';
  RulePolledRead = 'polled-raw-read';
  RulePayloadRead = 'payload-raw-read';
  { Statements after a raw write that may publish its completion marker. }
  CompletionWindowStatements = 4;
  { Statements after X.Text := <pid> that may save X. }
  SaveWindowStatements = 3;
  EvidenceLimit = 160;
  { The self-tests below embed violating snippets as literals. }
  GuardProgramPath = 'tests/integration/PayloadHandoffGuard.Test.pas';
  { A scan that finds almost nothing is scanning the wrong tree. }
  MinimumScannedFiles = 50;

type
  THandoffFinding = record
    Path: string;
    Line: Integer;
    Rule: string;
    Evidence: string;
  end;
  THandoffFindings = array of THandoffFinding;

  THandoffAllowance = record
    Path: string;
    Rule: string;
    { A substring of the finding's evidence. }
    Evidence: string;
  end;

  TScanToken = record
    Text: string;
    Lower: string;
    Line: Integer;
  end;
  TScanTokens = array of TScanToken;

  TScanStatement = record
    First: Integer;
    Last: Integer;
    Routine: Integer;
  end;
  TScanStatements = array of TScanStatement;

  TTokenRange = record
    First: Integer;
    Last: Integer;
  end;
  TTokenRanges = array of TTokenRange;

  TPayloadHandoffGuard = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRepositoryFollowsTheProtocol;
    procedure TestEveryAllowanceStillMatches;
    procedure TestScanCoversTheTestTree;
    procedure TestRawPIDWritesAreDetected;
    procedure TestExistenceGatedReadsAreDetected;
    procedure TestPublishedHandoffsPass;
    procedure TestUnrelatedPIDUsesPass;
  end;

type
  THandoffAllowances = array of THandoffAllowance;

{ Justified exceptions. Each entry names the file, the rule, and a
  substring of the finding's evidence, and carries a comment saying why the
  site is not a cross-process handoff. Empty while no exception is needed. }
function HandoffAllowlist: THandoffAllowances;
begin
  Result := nil;
end;

function AllowanceMatches(const AAllowance: THandoffAllowance;
  const AFinding: THandoffFinding): Boolean;
begin
  Result := (AAllowance.Path = AFinding.Path)
    and (AAllowance.Rule = AFinding.Rule)
    and (Pos(AAllowance.Evidence, AFinding.Evidence) > 0);
end;

function BuildScanText(const ASource: string): string;
var
  Index, Length_, Written: Integer;
begin
  Length_ := Length(ASource);
  { Every transformation below emits at most as many characters as it
    consumes, so the source length bounds the scan text. }
  SetLength(Result, Length_);
  Written := 0;
  Index := 1;
  while Index <= Length_ do
  begin
    if ASource[Index] = '{' then
    begin
      Inc(Index);
      while (Index <= Length_) and (ASource[Index] <> '}') do
      begin
        if ASource[Index] = #10 then
        begin
          Inc(Written);
          Result[Written] := #10;
        end;
        Inc(Index);
      end;
      Inc(Index);
      Inc(Written);
      Result[Written] := ' ';
    end
    else if (ASource[Index] = '(') and (Index < Length_)
      and (ASource[Index + 1] = '*') then
    begin
      Inc(Index, 2);
      while (Index < Length_)
        and not ((ASource[Index] = '*') and (ASource[Index + 1] = ')')) do
      begin
        if ASource[Index] = #10 then
        begin
          Inc(Written);
          Result[Written] := #10;
        end;
        Inc(Index);
      end;
      Inc(Index, 2);
      Inc(Written);
      Result[Written] := ' ';
    end
    else if (ASource[Index] = '/') and (Index < Length_)
      and (ASource[Index + 1] = '/') then
    begin
      while (Index <= Length_) and (ASource[Index] <> #10) do Inc(Index);
      Inc(Written);
      Result[Written] := ' ';
    end
    else if ASource[Index] = '''' then
    begin
      { Keep the literal's decoded content: generated fixture programs are
        Pascal source held in literals. }
      Inc(Written);
      Result[Written] := ' ';
      Inc(Index);
      while (Index <= Length_) and (ASource[Index] <> #10) do
      begin
        if ASource[Index] = '''' then
        begin
          if (Index < Length_) and (ASource[Index + 1] = '''') then
          begin
            Inc(Written);
            Result[Written] := '''';
            Inc(Index, 2);
            Continue;
          end;
          Inc(Index);
          Break;
        end;
        Inc(Written);
        Result[Written] := ASource[Index];
        Inc(Index);
      end;
      Inc(Written);
      Result[Written] := ' ';
    end
    else if ASource[Index] = '#' then
    begin
      Inc(Index);
      if (Index <= Length_) and (ASource[Index] = '$') then Inc(Index);
      while (Index <= Length_)
        and (ASource[Index] in ['0'..'9', 'A'..'F', 'a'..'f']) do
        Inc(Index);
      Inc(Written);
      Result[Written] := ' ';
    end
    else
    begin
      Inc(Written);
      Result[Written] := ASource[Index];
      Inc(Index);
    end;
  end;
  SetLength(Result, Written);
end;

function Tokenize(const AText: string): TScanTokens;
var
  Count, Index, Line, Start: Integer;

  procedure Add(const AToken: string);
  begin
    if Count = Length(Result) then SetLength(Result, Count * 2 + 64);
    Result[Count].Text := AToken;
    Result[Count].Lower := LowerCase(AToken);
    Result[Count].Line := Line;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  Line := 1;
  Index := 1;
  while Index <= Length(AText) do
  begin
    if AText[Index] = #10 then
    begin
      Inc(Line);
      Inc(Index);
    end
    else if AText[Index] <= ' ' then
      Inc(Index)
    else if AText[Index] in ['A'..'Z', 'a'..'z', '_', '0'..'9'] then
    begin
      Start := Index;
      while (Index <= Length(AText))
        and (AText[Index] in ['A'..'Z', 'a'..'z', '_', '0'..'9']) do
        Inc(Index);
      Add(Copy(AText, Start, Index - Start));
    end
    else if (AText[Index] = ':') and (Index < Length(AText))
      and (AText[Index + 1] = '=') then
    begin
      Add(':=');
      Inc(Index, 2);
    end
    else
    begin
      Add(AText[Index]);
      Inc(Index);
    end;
  end;
  SetLength(Result, Count);
end;

function IsRoutineKeyword(const ALower: string): Boolean;
begin
  Result := (ALower = 'procedure') or (ALower = 'function')
    or (ALower = 'constructor') or (ALower = 'destructor');
end;

function SplitStatements(const ATokens: TScanTokens): TScanStatements;
var
  Count, Index, Routine, Start: Integer;

  procedure Add(AFirst, ALast: Integer);
  begin
    if ALast < AFirst then Exit;
    if Count = Length(Result) then SetLength(Result, Count * 2 + 64);
    Result[Count].First := AFirst;
    Result[Count].Last := ALast;
    Result[Count].Routine := Routine;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  Routine := 0;
  Start := 0;
  for Index := 0 to High(ATokens) do
  begin
    if (Index = Start) and IsRoutineKeyword(ATokens[Index].Lower) then
      Inc(Routine);
    if ATokens[Index].Text = ';' then
    begin
      Add(Start, Index - 1);
      Start := Index + 1;
    end;
  end;
  Add(Start, High(ATokens));
  SetLength(Result, Count);
end;

{ Splits the arguments of the call whose '(' is at AOpen, stopping at ALast
  when the call is not closed within the statement. }
function CallArguments(const ATokens: TScanTokens;
  AOpen, ALast: Integer; out AClosed: Boolean): TTokenRanges;
var
  Depth, Index, Start: Integer;

  procedure Add(AFirst, AArgumentLast: Integer);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].First := AFirst;
    Result[High(Result)].Last := AArgumentLast;
  end;

begin
  Result := nil;
  AClosed := False;
  Depth := 0;
  Start := AOpen + 1;
  for Index := AOpen to ALast do
  begin
    if (ATokens[Index].Text = '(') or (ATokens[Index].Text = '[') then
      Inc(Depth)
    else if (ATokens[Index].Text = ')') or (ATokens[Index].Text = ']') then
    begin
      Dec(Depth);
      if Depth = 0 then
      begin
        Add(Start, Index - 1);
        AClosed := True;
        Exit;
      end;
    end
    else if (ATokens[Index].Text = ',') and (Depth = 1) then
    begin
      Add(Start, Index - 1);
      Start := Index + 1;
    end;
  end;
  Add(Start, ALast);
end;

function IsPIDToken(const ATokens: TScanTokens; AIndex: Integer): Boolean;
var
  Lower: string;
begin
  Lower := ATokens[AIndex].Lower;
  Result := (Lower = 'getprocessid') or (Lower = 'getcurrentprocessid')
    or (Lower = 'fpgetpid') or (Lower = 'getpid')
    or ((Lower = 'processid') and (AIndex > 0)
      and (ATokens[AIndex - 1].Text = '.'));
end;

function RangeHasPID(const ATokens: TScanTokens;
  const ARange: TTokenRange): Boolean;
var
  Index: Integer;
begin
  for Index := ARange.First to ARange.Last do
    if IsPIDToken(ATokens, Index) then Exit(True);
  Result := False;
end;

function RangeKey(const ATokens: TScanTokens;
  const ARange: TTokenRange): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := ARange.First to ARange.Last do
    Result := Result + ATokens[Index].Lower;
end;

function StatementEvidence(const ATokens: TScanTokens;
  const AStatement: TScanStatement): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := AStatement.First to AStatement.Last do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + ATokens[Index].Text;
    if Length(Result) >= EvidenceLimit then
      Exit(Copy(Result, 1, EvidenceLimit));
  end;
end;

function IsConsoleFile(const ALower: string): Boolean;
begin
  Result := (ALower = 'output') or (ALower = 'erroutput')
    or (ALower = 'stdout') or (ALower = 'stderr') or (ALower = 'input');
end;

{ True when the call at AIndex (identifier followed by '(') writes a PID
  into file content without publishing it. }
function IsRawPIDWriteCall(const ATokens: TScanTokens;
  const AStatement: TScanStatement; AIndex: Integer): Boolean;
var
  Arguments: TTokenRanges;
  ArgumentIndex: Integer;
  Closed, Qualified: Boolean;
  Lower: string;
begin
  Result := False;
  Lower := ATokens[AIndex].Lower;
  if Copy(Lower, 1, 5) <> 'write' then Exit;
  if (Lower = 'writefile') or (Lower = 'writebuffer') then Exit;
  Qualified := (AIndex > 0) and (ATokens[AIndex - 1].Text = '.');
  Arguments := CallArguments(ATokens, AIndex + 1, AStatement.Last, Closed);
  { An unclosed call spans generated fixture source; the writes inside it
    are checked on their own. }
  if not Closed or (Length(Arguments) < 2) then Exit;
  if (Lower = 'write') or (Lower = 'writeln') then
  begin
    { Only Write(TextFile, ...) reaches a file; stream methods and console
      output do not. }
    if Qualified then Exit;
    if Arguments[0].First <> Arguments[0].Last then Exit;
    if IsConsoleFile(ATokens[Arguments[0].First].Lower)
      or IsPIDToken(ATokens, Arguments[0].First) then Exit;
  end;
  for ArgumentIndex := 1 to High(Arguments) do
    if RangeHasPID(ATokens, Arguments[ArgumentIndex]) then Exit(True);
end;

function StatementHasToken(const ATokens: TScanTokens;
  const AStatement: TScanStatement; const ALower: string): Boolean;
var
  Index: Integer;
begin
  for Index := AStatement.First to AStatement.Last do
    if ATokens[Index].Lower = ALower then Exit(True);
  Result := False;
end;

function CompletionFollows(const ATokens: TScanTokens;
  const AStatements: TScanStatements; AStatementIndex: Integer): Boolean;
var
  Index: Integer;
begin
  for Index := AStatementIndex to AStatementIndex
    + CompletionWindowStatements do
  begin
    if Index > High(AStatements) then Break;
    if StatementHasToken(ATokens, AStatements[Index],
         'publishpayloadcompletion')
       or StatementHasToken(ATokens, AStatements[Index],
         'emitpayloadcompletion') then Exit(True);
  end;
  Result := False;
end;

{ Returns the statement index saving collection AName within the window,
  and the token index of its SaveToFile, or -1. }
function FindSaveToFile(const ATokens: TScanTokens;
  const AStatements: TScanStatements; AFrom: Integer; const AName: string;
  out ATokenIndex: Integer): Integer;
var
  Index, StatementIndex: Integer;
begin
  ATokenIndex := -1;
  for StatementIndex := AFrom to AFrom + SaveWindowStatements do
  begin
    if StatementIndex > High(AStatements) then Break;
    for Index := AStatements[StatementIndex].First
      to AStatements[StatementIndex].Last - 3 do
      if (ATokens[Index].Lower = AName) and (ATokens[Index + 1].Text = '.')
         and (ATokens[Index + 2].Lower = 'savetofile')
         and (ATokens[Index + 3].Text = '(') then
      begin
        ATokenIndex := Index + 2;
        Exit(StatementIndex);
      end;
  end;
  Result := -1;
end;

{ Name of a collection filled with a PID in this statement, or ''. }
function PIDFilledCollection(const ATokens: TScanTokens;
  const AStatement: TScanStatement): string;
var
  Arguments: TTokenRanges;
  Closed: Boolean;
  Index, ArgumentIndex: Integer;
  Member: string;
  Rest: TTokenRange;
begin
  Result := '';
  for Index := AStatement.First to AStatement.Last - 3 do
  begin
    if ATokens[Index + 1].Text <> '.' then Continue;
    Member := ATokens[Index + 2].Lower;
    if (Member = 'text') and (ATokens[Index + 3].Text = ':=') then
    begin
      Rest.First := Index + 4;
      Rest.Last := AStatement.Last;
      if RangeHasPID(ATokens, Rest) then Exit(ATokens[Index].Lower);
    end
    else if ((Member = 'add') or (Member = 'append'))
      and (ATokens[Index + 3].Text = '(') then
    begin
      Arguments := CallArguments(ATokens, Index + 3, AStatement.Last,
        Closed);
      for ArgumentIndex := 0 to High(Arguments) do
        if RangeHasPID(ATokens, Arguments[ArgumentIndex]) then
          Exit(ATokens[Index].Lower);
    end;
  end;
end;

procedure AddFinding(var AFindings: THandoffFindings; const APath: string;
  ALine: Integer; const ARule, AEvidence: string);
begin
  SetLength(AFindings, Length(AFindings) + 1);
  AFindings[High(AFindings)].Path := APath;
  AFindings[High(AFindings)].Line := ALine;
  AFindings[High(AFindings)].Rule := ARule;
  AFindings[High(AFindings)].Evidence := AEvidence;
end;

procedure ScanRawPIDWrites(const APath: string; const ATokens: TScanTokens;
  const AStatements: TScanStatements; var AFindings: THandoffFindings);
var
  Collection: string;
  Index, SaveStatement, SaveToken, StatementIndex: Integer;
begin
  for StatementIndex := 0 to High(AStatements) do
  begin
    for Index := AStatements[StatementIndex].First
      to AStatements[StatementIndex].Last - 1 do
      if (ATokens[Index + 1].Text = '(')
         and IsRawPIDWriteCall(ATokens, AStatements[StatementIndex], Index)
         and not CompletionFollows(ATokens, AStatements, StatementIndex) then
        AddFinding(AFindings, APath, ATokens[Index].Line, RulePIDWrite,
          StatementEvidence(ATokens, AStatements[StatementIndex]));
    Collection := PIDFilledCollection(ATokens, AStatements[StatementIndex]);
    if Collection = '' then Continue;
    SaveStatement := FindSaveToFile(ATokens, AStatements, StatementIndex,
      Collection, SaveToken);
    if (SaveStatement >= 0)
       and not CompletionFollows(ATokens, AStatements, SaveStatement) then
      AddFinding(AFindings, APath, ATokens[SaveToken].Line, RulePIDWrite,
        StatementEvidence(ATokens, AStatements[StatementIndex]) + ' ... '
        + StatementEvidence(ATokens, AStatements[SaveStatement]));
  end;
end;

function IsRawReader(const ALower: string): Boolean;
begin
  if ALower = 'loadfromfile' then Exit(True);
  Result := (Copy(ALower, 1, 4) = 'read') and (ALower <> 'read')
    and (ALower <> 'readln') and (ALower <> 'readbuffer')
    and (ALower <> 'readpayloadtext');
end;

{ Adds the first-argument key of every ACallee call in the statement. }
procedure CollectCallKeys(const ATokens: TScanTokens;
  const AStatement: TScanStatement; const ACallee: string;
  AKeys: TStrings);
var
  Arguments: TTokenRanges;
  Closed: Boolean;
  Index: Integer;
begin
  for Index := AStatement.First to AStatement.Last - 1 do
    if (ATokens[Index].Lower = ACallee)
       and (ATokens[Index + 1].Text = '(') then
    begin
      Arguments := CallArguments(ATokens, Index + 1, AStatement.Last,
        Closed);
      if Length(Arguments) > 0 then
        AKeys.Add(RangeKey(ATokens, Arguments[0]));
    end;
end;

procedure ScanRoutineReads(const APath: string; const ATokens: TScanTokens;
  const AStatements: TScanStatements; AFirst, ALast: Integer;
  var AFindings: THandoffFindings);
var
  Arguments: TTokenRanges;
  Closed: Boolean;
  Gated, Polled: TStringList;
  Index, StatementIndex: Integer;
  Key: string;
begin
  Polled := TStringList.Create;
  Gated := TStringList.Create;
  try
    for StatementIndex := AFirst to ALast do
    begin
      if StatementHasToken(ATokens, AStatements[StatementIndex], 'while')
         or StatementHasToken(ATokens, AStatements[StatementIndex], 'until')
         or StatementHasToken(ATokens, AStatements[StatementIndex],
           'repeat') then
        CollectCallKeys(ATokens, AStatements[StatementIndex], 'fileexists',
          Polled);
      CollectCallKeys(ATokens, AStatements[StatementIndex],
        'payloadisreadable', Gated);
    end;
    if (Polled.Count = 0) and (Gated.Count = 0) then Exit;
    for StatementIndex := AFirst to ALast do
      for Index := AStatements[StatementIndex].First
        to AStatements[StatementIndex].Last - 1 do
      begin
        if not IsRawReader(ATokens[Index].Lower)
           or (ATokens[Index + 1].Text <> '(') then Continue;
        Arguments := CallArguments(ATokens, Index + 1,
          AStatements[StatementIndex].Last, Closed);
        if Length(Arguments) = 0 then Continue;
        Key := RangeKey(ATokens, Arguments[0]);
        if Polled.IndexOf(Key) >= 0 then
          AddFinding(AFindings, APath, ATokens[Index].Line, RulePolledRead,
            StatementEvidence(ATokens, AStatements[StatementIndex]))
        else if Gated.IndexOf(Key) >= 0 then
          AddFinding(AFindings, APath, ATokens[Index].Line, RulePayloadRead,
            StatementEvidence(ATokens, AStatements[StatementIndex]));
      end;
  finally
    Gated.Free;
    Polled.Free;
  end;
end;

function ScanHandoffSource(const APath, ASource: string): THandoffFindings;
var
  Statements: TScanStatements;
  Tokens: TScanTokens;
  First, Index: Integer;
begin
  Result := nil;
  Tokens := Tokenize(BuildScanText(ASource));
  Statements := SplitStatements(Tokens);
  ScanRawPIDWrites(APath, Tokens, Statements, Result);
  First := 0;
  for Index := 1 to Length(Statements) do
    if (Index = Length(Statements))
       or (Statements[Index].Routine <> Statements[First].Routine) then
    begin
      ScanRoutineReads(APath, Tokens, Statements, First, Index - 1, Result);
      First := Index;
    end;
end;

function IsScanTarget(const ARelativePath: string): Boolean;
var
  Name: string;
begin
  if ARelativePath = GuardProgramPath then Exit(False);
  Name := ExtractFileName(ARelativePath);
  if Copy(ARelativePath, 1, 7) = 'source/' then
    Exit(Pos('.Test.pas', Name) = Length(Name) - Length('.Test.pas') + 1);
  if Copy(ARelativePath, 1, 6) = 'tests/' then
    Exit((ExtractFileExt(Name) = '.pas') or (ExtractFileExt(Name) = '.inc'));
  if Copy(ARelativePath, 1, 9) = 'packages/' then
    Exit((ExtractFileExt(Name) = '.pas')
      and ((Pos('.Test.pas', Name) > 0) or (Copy(Name, 1, 6) = 'Tests.')
        or (Pos('/tests/', ARelativePath) > 0)));
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

function IsAllowed(const AFinding: THandoffFinding): Boolean;
var
  Allowance: THandoffAllowance;
begin
  for Allowance in HandoffAllowlist do
    if AllowanceMatches(Allowance, AFinding) then Exit(True);
  Result := False;
end;

function RepositoryFindings: THandoffFindings;
var
  Files: TStringList;
  FileFindings: THandoffFindings;
  FileIndex, Index: Integer;
begin
  Result := nil;
  Files := ScanTargets;
  try
    for FileIndex := 0 to Files.Count - 1 do
    begin
      FileFindings := ScanHandoffSource(Files[FileIndex],
        ReadBinaryFile(Files[FileIndex]));
      for Index := 0 to High(FileFindings) do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FileFindings[Index];
      end;
    end;
  finally
    Files.Free;
  end;
end;

function DescribeFinding(const AFinding: THandoffFinding): string;
begin
  Result := AFinding.Path + ':' + IntToStr(AFinding.Line) + ': '
    + AFinding.Rule + ': ' + AFinding.Evidence;
end;

function RulesOf(const ASource: string): string;
var
  Findings: THandoffFindings;
  Index: Integer;
begin
  Findings := ScanHandoffSource('synthetic.pas', ASource);
  Result := '';
  for Index := 0 to High(Findings) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + Findings[Index].Rule + '@'
      + IntToStr(Findings[Index].Line);
  end;
end;

procedure TPayloadHandoffGuard.TestRepositoryFollowsTheProtocol;
var
  Findings: THandoffFindings;
  Index, Violations: Integer;
begin
  Findings := RepositoryFindings;
  Violations := 0;
  for Index := 0 to High(Findings) do
    if not IsAllowed(Findings[Index]) then
    begin
      WriteLn('PAYLOAD HANDOFF VIOLATION ', DescribeFinding(Findings[Index]));
      Inc(Violations);
    end;
  if Violations > 0 then
    WriteLn('Hand payloads over with Tests.PayloadHandoff: writers call ',
      'PublishReadablePayload (or write, then PublishPayloadCompletion; ',
      'EmitPayloadCompletion in generated fixtures), and readers wait for ',
      'PayloadIsReadable and read with ReadPayloadText. See docs/testing.md.');
  Expect<Integer>(Violations).ToBe(0);
end;

procedure TPayloadHandoffGuard.TestEveryAllowanceStillMatches;
var
  Allowance: THandoffAllowance;
  Finding: THandoffFinding;
  Findings: THandoffFindings;
  Matched: Boolean;
begin
  Findings := RepositoryFindings;
  for Allowance in HandoffAllowlist do
  begin
    Matched := False;
    for Finding in Findings do
      if AllowanceMatches(Allowance, Finding) then Matched := True;
    if not Matched then
      WriteLn('STALE PAYLOAD HANDOFF ALLOWANCE ', Allowance.Path, ' ',
        Allowance.Rule, ' "', Allowance.Evidence, '"');
    Expect<Boolean>(Matched).ToBe(True);
  end;
  { An empty allowlist is a verified state, not a case without assertions. }
  Expect<Boolean>(True).ToBe(True);
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
  finally
    Files.Free;
  end;
end;

procedure TPayloadHandoffGuard.TestRawPIDWritesAreDetected;
begin
  { The surviving-descendant proxy before 89f93a7 (run 36593670809). }
  Expect<string>(RulesOf(
      'function RunProxy: Integer;'#10
    + 'begin'#10
    + '  WriteTextFile(ParamStr(2), IntToStr(GetProcessID));'#10
    + '  Sleep(1000);'#10
    + 'end;'#10)).ToBe(RulePIDWrite + '@3');
  { The escaped stdin holder's forked grandchild. }
  Expect<string>(RulesOf(
      'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.Text := IntToStr(FpGetPID);'#10
    + '    Lines.SaveToFile(APIDFile);'#10
    + '  finally'#10
    + '    Lines.Free;'#10
    + '  end;'#10
    + 'end;'#10)).ToBe(RulePIDWrite + '@5');
  { Generated fixtures written as literals, without EmitPayloadCompletion. }
  Expect<string>(RulesOf(
      '  WriteTextFile(Path,'#10
    + '      ''    Child.Execute;''#10'#10
    + '    + ''    PIDFile.Text := IntToStr(Child.ProcessID);''#10'#10
    + '    + ''    PIDFile.SaveToFile('' + PascalString(P) + '');''#10'#10
    + '    + ''  finally PIDFile.Free end;''#10'#10
    + '    + ''end.''#10);'#10)).ToBe(RulePIDWrite + '@4');
  Expect<string>(RulesOf(
      '  WriteTextFile(Path,'#10
    + '      ''    Rewrite(PIDFile);''#10'#10
    + '    + ''    Write(PIDFile, Child.ProcessID);''#10'#10
    + '    + ''    Close(PIDFile);''#10'#10
    + '    + ''end.''#10);'#10)).ToBe(RulePIDWrite + '@3');
end;

procedure TPayloadHandoffGuard.TestExistenceGatedReadsAreDetected;
begin
  Expect<string>(RulesOf(
      'procedure WaitAndRead;'#10
    + 'begin'#10
    + '  while not FileExists(PIDPath) do Sleep(10);'#10
    + '  PID := StrToInt(Trim(ReadBinaryFile(PIDPath)));'#10
    + 'end;'#10)).ToBe(RulePolledRead + '@4');
  Expect<string>(RulesOf(
      'procedure WaitAndLoad;'#10
    + 'begin'#10
    + '  repeat'#10
    + '    if FileExists(APath + ''-owner'') then Break;'#10
    + '    Sleep(25);'#10
    + '  until False;'#10
    + '  Lines.LoadFromFile(APath + ''-owner'');'#10
    + 'end;'#10)).ToBe(RulePolledRead + '@7');
  Expect<string>(RulesOf(
      'procedure ReadGated;'#10
    + 'begin'#10
    + '  if PayloadIsReadable(PIDPath) then'#10
    + '    PID := StrToInt(Trim(ReadBinaryFile(PIDPath)));'#10
    + 'end;'#10)).ToBe(RulePayloadRead + '@4');
end;

procedure TPayloadHandoffGuard.TestPublishedHandoffsPass;
begin
  Expect<string>(RulesOf(
      'begin'#10
    + '  PublishReadablePayload(ParamStr(2), IntToStr(GetProcessID));'#10
    + '  WriteTextFile(PIDPath, IntToStr(GetProcessID));'#10
    + '  PublishPayloadCompletion(PIDPath);'#10
    + 'end;'#10)).ToBe('');
  Expect<string>(RulesOf(
      '  WriteTextFile(Path,'#10
    + '      ''    PIDFile.Text := IntToStr(Child.ProcessID);''#10'#10
    + '    + ''    PIDFile.SaveToFile('' + PascalString(P) + '');''#10'#10
    + '    + ''  finally PIDFile.Free end;''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(P))'#10
    + '    + ''    Write(PIDFile, Child.ProcessID);''#10'#10
    + '    + ''    Close(PIDFile);''#10'#10
    + '    + EmitPayloadCompletion(''CompleteFile'', PascalString(Q))'#10
    + '    + ''end.''#10);'#10)).ToBe('');
  Expect<string>(RulesOf(
      'procedure WaitAndRead;'#10
    + 'begin'#10
    + '  while not PayloadIsReadable(PIDPath) do Sleep(10);'#10
    + '  PID := StrToInt(Trim(ReadPayloadText(PIDPath)));'#10
    + 'end;'#10)).ToBe('');
end;

procedure TPayloadHandoffGuard.TestUnrelatedPIDUsesPass;
begin
  { A PID in the path, on the console, in a comment, or read after a poll
    in another routine is not a payload handoff. }
  Expect<string>(RulesOf(
      'begin'#10
    + '  WriteTextFile(ReadyDir + ''/ready-'' + Name + ''-'''#10
    + '    + IntToStr(GetProcessID), ''ready'');'#10
    + '  WriteLn(ErrOutput, ''pid '', GetProcessID);'#10
    + '  WriteLn(FpGetpid, '' '', FpGetpgrp);'#10
    + '  Stream.Write(PID, SizeOf(GetProcessID));'#10
    + '  { WriteTextFile(Path, IntToStr(GetProcessID)); }'#10
    + '  // WriteTextFile(Path, IntToStr(GetProcessID));'#10
    + '  Lines.Add(''pid='' + IntToStr(Child.ProcessID));'#10
    + '  A; B; C; D;'#10
    + '  Lines.SaveToFile(ReportPath);'#10
    + 'end;'#10)).ToBe('');
  Expect<string>(RulesOf(
      'function WaitForFile(const APath: string): Boolean;'#10
    + 'begin'#10
    + '  while not FileExists(APath) do Sleep(10);'#10
    + 'end;'#10
    + 'function ReadMarkerText(const APath: string): string;'#10
    + 'begin'#10
    + '  Lines.LoadFromFile(APath);'#10
    + 'end;'#10)).ToBe('');
end;

procedure TPayloadHandoffGuard.SetupTests;
begin
  Test('repository test code follows the payload handoff protocol',
    TestRepositoryFollowsTheProtocol);
  Test('every allowance still matches a finding',
    TestEveryAllowanceStillMatches);
  Test('the scan covers the repository test tree',
    TestScanCoversTheTestTree);
  Test('raw PID writes are detected', TestRawPIDWritesAreDetected);
  Test('existence-gated raw reads are detected',
    TestExistenceGatedReadsAreDetected);
  Test('published handoffs pass', TestPublishedHandoffsPass);
  Test('unrelated PID uses pass', TestUnrelatedPIDUsesPass);
end;

begin
  TestRunnerProgram.AddSuite(TPayloadHandoffGuard.Create(
    'payload handoff guard'));
  TestRunnerProgram.Run;
end.
