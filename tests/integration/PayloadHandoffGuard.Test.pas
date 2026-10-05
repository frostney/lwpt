{ PayloadHandoffGuard.Test — a heuristic tripwire that keeps cross-process
  payload files in test code on the Tests.PayloadHandoff protocol.

  A file that one process writes and another reads is handed over through
  an existence-only <path>.complete marker, never through the payload's own
  existence (tests/support/Tests.PayloadHandoff.pas records the history:
  #205, #262, PR #289, and main's push run 36593670809). Those flakes were
  fixed one site at a time while sibling sites kept the bug, so this program
  scans the repository's test code and fails when a known shape returns. A
  clean run is not proof that every handoff is safe.

  Files are scanned through Tests.SourceScan, which tokenizes them with
  LWPT.Analysis.Pascal and decodes generated fixture programs from string
  expressions (see its header); only executable scopes carry these rules.
  Each spliced-in value (PascalString(X), IntToStr(...)) is a placeholder
  carrying X's expression, and each EmitPayloadCompletion(..., P) becomes a
  completion call on P. Four rules, each within one routine body:

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
  treated as raw readers. Atomic writers (AtomicWrite*, write-then-rename) publish complete
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
  Tests.Scratch,
  Tests.SourceScan;

const
  RulePIDWrite = 'raw-pid-write';
  RulePolledRead = 'polled-raw-read';
  RulePayloadRead = 'payload-raw-read';
  RulePolledPayload = 'existence-polled-payload';
  RuleUnscannable = 'unscannable';
  { The self-tests below embed violating snippets as literals. }
  GuardProgramPath = 'tests/integration/PayloadHandoffGuard.Test.pas';
  { A scan that finds almost nothing is scanning the wrong tree. }
  MinimumScannedFiles = 50;

type
  THandoffFinding = TSourceFinding;
  THandoffFindings = TSourceFindings;

  THandoffAllowance = record
    Path: string;
    Rule: string;
    Routine: string;
    { The normalized payload expression the finding reports. }
    Key: string;
  end;
  THandoffAllowances = array of THandoffAllowance;

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

{ Rules ------------------------------------------------------------------ }

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
      Scopes := SourceScopes(ASource);
    except
      on E: ELWPTPascalAnalysisError do
      begin
        AddFinding(Result, APath, Lines, 0, RuleUnscannable, '<file>',
          E.Message);
        Exit;
      end;
    end;
    for Index := 0 to High(Scopes) do
      if Scopes[Index].Executable then
        CollectPublications(Scopes[Index].Tokens, FilePublished, True);
    for Index := 0 to High(Scopes) do
    begin
      if not Scopes[Index].Executable then Continue;
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

function RepositoryFindings: THandoffFindings;
var
  Files: TStringList;
  Finding: THandoffFinding;
  FileIndex: Integer;
begin
  Result := nil;
  Files := ScanTargets(GuardProgramPath);
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
  Files := ScanTargets(GuardProgramPath);
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
    Expect<Boolean>(IsScanTarget('packages/demo/tests/Shared.inc',
      GuardProgramPath))
      .ToBe(True);
    Expect<Boolean>(IsScanTarget('packages/demo/source/Demo.pas',
      GuardProgramPath))
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
