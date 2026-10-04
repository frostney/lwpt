{ ChildWaitGuard.Test — a heuristic tripwire that keeps unbounded
  child-process waits out of the repository's test code.

  A test that waits for a child without a deadline hangs its test program
  until CI's job bound cancels it, with no diagnostics. FPC 3.2.2 offers
  three such waits: the parameterless TProcess.WaitOnExit, the poWaitOnExit
  option (Execute then waits the same way), and TProcess.Terminate, whose
  Unix implementation ends in an untimed WaitOnExit (fcl-process/src/unix/
  process.inc). PR #363 bounded the registry family and #365 converted the
  remaining sites onto Tests.ProcessSupport (WaitForChildExit, FinishChild,
  ReapChild, TerminateChildProcess); this program fails the run when one of
  the shapes returns. A clean run is not proof that every wait is bounded.

  Files are scanned through Tests.SourceScan, so generated fixture programs
  held in string literals are scanned as well. Four rules:

    parameterless-wait-on-exit  WaitOnExit without an argument list, or with
                                an empty one, in an executable scope.
    wait-on-exit-option         poWaitOnExit anywhere in code, declarations
                                included.
    process-terminate           Terminate(...) with arguments in an
                                executable scope: TProcess.Terminate takes an
                                exit code, while TThread.Terminate and
                                TLWPTProcessTree.Terminate take none and stay
                                allowed.
    unbounded-running-poll      while X.Running do S, or repeat S until not
                                X.Running, whose condition tests nothing
                                else and whose body S has no Break, Exit,
                                raise, or Halt.

  A finding's key is its receiver (the designator before .WaitOnExit,
  .Terminate, or .Running, or the one whose Options take poWaitOnExit), or
  <self> for an unqualified call. Types are not resolved, so a Terminate
  method with an argument on another class would be reported; none exists.

  Justified exceptions go in ChildWaitAllowlist. An allowance names one
  site, file, rule, routine, and key, and gives its reason. It fails the run
  when it matches no finding or more than one, and self-tests prove every
  rule still detects its violations, in fixture source too. }

program ChildWaitGuard.Test;

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
  RuleParameterlessWait = 'parameterless-wait-on-exit';
  RuleWaitOption = 'wait-on-exit-option';
  RuleProcessTerminate = 'process-terminate';
  RuleRunningPoll = 'unbounded-running-poll';
  RuleUnscannable = 'unscannable';
  SelfReceiver = '<self>';
  { The self-tests below embed violating snippets as literals. }
  GuardProgramPath = 'tests/integration/ChildWaitGuard.Test.pas';
  { A scan that finds almost nothing is scanning the wrong tree. }
  MinimumScannedFiles = 50;

type
  TChildWaitAllowance = record
    Path: string;
    Rule: string;
    Routine: string;
    Key: string;
    Reason: string;
  end;
  TChildWaitAllowances = array of TChildWaitAllowance;

  TChildWaitGuard = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRepositoryHasNoUnboundedChildWaits;
    procedure TestEveryAllowanceMatchesOneSite;
    procedure TestEveryAllowanceGivesAReason;
    procedure TestScanCoversTheTestTree;
    procedure TestParameterlessWaitsAreDetected;
    procedure TestWaitOnExitOptionIsDetected;
    procedure TestProcessTerminateIsDetected;
    procedure TestUnboundedRunningPollsAreDetected;
    procedure TestGeneratedFixturesAreScanned;
    procedure TestBoundedWaitsPass;
  end;

{ Justified exceptions, one site each, with the reason in the entry. }
function ChildWaitAllowlist: TChildWaitAllowances;

  procedure Allow(const APath, ARule, ARoutine, AKey, AReason: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Path := APath;
    Result[High(Result)].Rule := ARule;
    Result[High(Result)].Routine := ARoutine;
    Result[High(Result)].Key := AKey;
    Result[High(Result)].Reason := AReason;
  end;

begin
  Result := nil;
  Allow('tests/integration/PayloadHandoffGuard.Test.pas', RuleRunningPoll,
    'tpayloadhandoffguard.testunrelatedpidusespass fixture checkafterexit',
    'child', 'Synthetic source the payload guard feeds its own scanner as '
    + 'a passing case; it is never compiled or run.');
end;

function AllowanceMatches(const AAllowance: TChildWaitAllowance;
  const AFinding: TSourceFinding): Boolean;
begin
  Result := (AAllowance.Path = AFinding.Path)
    and (AAllowance.Rule = AFinding.Rule)
    and (AAllowance.Routine = AFinding.Routine)
    and (AAllowance.Key = AFinding.Key);
end;

{ Receivers ---------------------------------------------------------------- }

{ Index of the opener matching the closer at AClose, or -1. }
function MatchingOpener(const ATokens: TGuardTokens; AClose: Integer): Integer;
var
  Depth, Index: Integer;
begin
  Depth := 0;
  for Index := AClose downto 0 do
    if TokenIs(ATokens, Index, ')') or TokenIs(ATokens, Index, ']') then
      Inc(Depth)
    else if TokenIs(ATokens, Index, '(') or TokenIs(ATokens, Index, '[') then
    begin
      Dec(Depth);
      if Depth = 0 then Exit(Index);
    end;
  Result := -1;
end;

{ First token of the designator that ends at ALast (Threads[I].Child,
  Owner.Process, Items(0)). }
function DesignatorStart(const ATokens: TGuardTokens; ALast: Integer): Integer;
var
  Index, Opener: Integer;
begin
  Result := ALast + 1;
  Index := ALast;
  while Index >= 0 do
  begin
    if TokenIs(ATokens, Index, ')') or TokenIs(ATokens, Index, ']') then
    begin
      Opener := MatchingOpener(ATokens, Index);
      if Opener <= 0 then Exit;
      Index := Opener - 1;
      Continue;
    end;
    if ATokens[Index].Kind <> ptIdentifier then Exit;
    Result := Index;
    if not TokenIs(ATokens, Index - 1, '.') then Exit;
    Index := Index - 2;
  end;
end;

{ The receiver of the member whose name is at AMember, or SelfReceiver. }
function ReceiverKey(const ATokens: TGuardTokens; AMember: Integer): string;
var
  Range: TTokenRange;
begin
  if not TokenIs(ATokens, AMember - 1, '.') then
  begin
    if TokenIs(ATokens, AMember - 1, 'inherited') then Exit('inherited');
    Exit(SelfReceiver);
  end;
  Range.Last := AMember - 2;
  Range.First := DesignatorStart(ATokens, Range.Last);
  if Range.First > Range.Last then Exit(SelfReceiver);
  Result := RangeKey(ATokens, Range);
end;

{ The designator X of the X.Options := ... statement holding AIndex, or
  the token's own text when it sits in no such assignment. }
function OptionReceiverKey(const ATokens: TGuardTokens;
  AIndex: Integer): string;
var
  Index: Integer;
begin
  for Index := AIndex - 1 downto 1 do
  begin
    if TokenIs(ATokens, Index, ';') or TokenIs(ATokens, Index, 'begin')
       or TokenIs(ATokens, Index, 'then') or TokenIs(ATokens, Index, 'do')
       or TokenIs(ATokens, Index, 'else') then Break;
    if TokenIs(ATokens, Index, ':=') and TokenIs(ATokens, Index - 1, 'options')
    then
      Exit(ReceiverKey(ATokens, Index - 1));
  end;
  Result := ATokens[AIndex].Text;
end;

{ Rules ------------------------------------------------------------------ }

function IsDeclarationName(const ATokens: TGuardTokens;
  AIndex: Integer): Boolean;
var
  Index: Integer;
begin
  { function TFoo.WaitOnExit: Boolean; names a method, it does not call it. }
  Index := AIndex - 1;
  while TokenIs(ATokens, Index, '.') and (Index > 0)
    and (ATokens[Index - 1].Kind = ptIdentifier) do
    Index := Index - 2;
  Result := TokenIs(ATokens, Index, 'function')
    or TokenIs(ATokens, Index, 'procedure');
end;

function CallHasArguments(const ATokens: TGuardTokens;
  AIndex: Integer): Boolean;
var
  Closed: Boolean;
begin
  Result := TokenIs(ATokens, AIndex + 1, '(')
    and (Length(CallArguments(ATokens, AIndex + 1, Closed)) > 0);
end;

function BodyEscapes(const ATokens: TGuardTokens;
  AFirst, ALast: Integer): Boolean;
var
  Index: Integer;
begin
  for Index := AFirst to ALast do
    if TokenIs(ATokens, Index, 'break') or TokenIs(ATokens, Index, 'exit')
       or TokenIs(ATokens, Index, 'raise') or TokenIs(ATokens, Index, 'halt')
    then
      Exit(True);
  Result := False;
end;

{ When ATokens[AFirst..ALast] is exactly X.Running (parentheses allowed),
  returns True with X's key. }
function IsBareRunningTest(const ATokens: TGuardTokens;
  AFirst, ALast: Integer; out AKey: string): Boolean;
begin
  Result := False;
  while TokenIs(ATokens, AFirst, '(') and TokenIs(ATokens, ALast, ')')
    and (MatchingOpener(ATokens, ALast) = AFirst) do
  begin
    Inc(AFirst);
    Dec(ALast);
  end;
  if (ALast - AFirst < 2) or not TokenIs(ATokens, ALast, 'running')
     or not TokenIs(ATokens, ALast - 1, '.') then Exit;
  if DesignatorStart(ATokens, ALast - 2) <> AFirst then Exit;
  AKey := ReceiverKey(ATokens, ALast);
  Result := True;
end;

{ The token index of the do that ends a while condition starting after
  AWhile, or -1. }
function WhileDo(const ATokens: TGuardTokens; AWhile: Integer): Integer;
var
  Index, Parens: Integer;
begin
  Parens := 0;
  for Index := AWhile + 1 to High(ATokens) do
    if TokenIs(ATokens, Index, '(') or TokenIs(ATokens, Index, '[') then
      Inc(Parens)
    else if TokenIs(ATokens, Index, ')') or TokenIs(ATokens, Index, ']') then
      Dec(Parens)
    else if (Parens = 0) and TokenIs(ATokens, Index, 'do') then
      Exit(Index);
  Result := -1;
end;

procedure ScanScope(const APath: string; const ALines: TStrings;
  const AScope: TGuardScope; var AFindings: TSourceFindings);
var
  ConditionEnd, DoIndex, Index, UntilIndex: Integer;
  Key: string;
  Tokens: TGuardTokens;
begin
  Tokens := AScope.Tokens;
  for Index := 0 to High(Tokens) do
  begin
    if not IsCodeToken(Tokens[Index]) then Continue;
    if Tokens[Index].Text = 'powaitonexit' then
      AddFinding(AFindings, APath, ALines, Tokens[Index].Line, RuleWaitOption,
        AScope.Routine, OptionReceiverKey(Tokens, Index));
    if not AScope.Executable then Continue;
    if (Tokens[Index].Text = 'waitonexit')
       and not IsDeclarationName(Tokens, Index)
       and not CallHasArguments(Tokens, Index) then
      AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
        RuleParameterlessWait, AScope.Routine, ReceiverKey(Tokens, Index))
    else if (Tokens[Index].Text = 'terminate')
      and not IsDeclarationName(Tokens, Index)
      and CallHasArguments(Tokens, Index) then
      AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
        RuleProcessTerminate, AScope.Routine, ReceiverKey(Tokens, Index))
    else if Tokens[Index].Text = 'while' then
    begin
      DoIndex := WhileDo(Tokens, Index);
      if (DoIndex > Index + 1)
         and IsBareRunningTest(Tokens, Index + 1, DoIndex - 1, Key)
         and not BodyEscapes(Tokens, DoIndex + 1,
           StatementEnd(Tokens, DoIndex + 1)) then
        AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
          RuleRunningPoll, AScope.Routine, Key);
    end
    else if Tokens[Index].Text = 'repeat' then
    begin
      UntilIndex := MatchingUntil(Tokens, Index);
      ConditionEnd := SimpleStatementEnd(Tokens, UntilIndex + 1);
      if TokenIs(Tokens, UntilIndex, 'until')
         and TokenIs(Tokens, UntilIndex + 1, 'not')
         and IsBareRunningTest(Tokens, UntilIndex + 2, ConditionEnd, Key)
         and not BodyEscapes(Tokens, Index + 1, UntilIndex - 1) then
        AddFinding(AFindings, APath, ALines, Tokens[Index].Line,
          RuleRunningPoll, AScope.Routine, Key);
    end;
  end;
end;

function ScanChildWaitSource(const APath, ASource: string): TSourceFindings;
var
  Lines: TStringList;
  Scope: TGuardScope;
  Scopes: TGuardScopes;
begin
  Result := nil;
  Lines := TStringList.Create;
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
    for Scope in Scopes do ScanScope(APath, Lines, Scope, Result);
  finally
    Lines.Free;
  end;
end;

{ Repository scan -------------------------------------------------------- }

function RepositoryFindings: TSourceFindings;
var
  Files: TStringList;
  Finding: TSourceFinding;
  FileIndex: Integer;
begin
  Result := nil;
  Files := ScanTargets(GuardProgramPath);
  try
    for FileIndex := 0 to Files.Count - 1 do
      for Finding in ScanChildWaitSource(Files[FileIndex],
        ReadBinaryFile(Files[FileIndex])) do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Finding;
      end;
  finally
    Files.Free;
  end;
end;

function IsAllowed(const AFinding: TSourceFinding): Boolean;
var
  Allowance: TChildWaitAllowance;
begin
  for Allowance in ChildWaitAllowlist do
    if AllowanceMatches(Allowance, AFinding) then Exit(True);
  Result := False;
end;

{ Rule@line:key for each finding of a synthetic source. }
function FindingsOf(const ASource: string): string;
var
  Finding: TSourceFinding;
begin
  Result := '';
  for Finding in ScanChildWaitSource('synthetic.pas', ASource) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + Finding.Rule + '@' + IntToStr(Finding.Line) + ':'
      + Finding.Key;
  end;
end;

{ Tests ------------------------------------------------------------------ }

procedure TChildWaitGuard.TestRepositoryHasNoUnboundedChildWaits;
var
  Finding: TSourceFinding;
  Violations: Integer;
begin
  Violations := 0;
  for Finding in RepositoryFindings do
    if not IsAllowed(Finding) then
    begin
      WriteLn('UNBOUNDED CHILD WAIT ', DescribeFinding(Finding));
      Inc(Violations);
    end;
  if Violations > 0 then
    WriteLn('Wait for children through Tests.ProcessSupport: FinishChild or ',
      'WaitForChildExit with a deadline, ReapChild in cleanup, and ',
      'TerminateChildProcess instead of TProcess.Terminate; generated ',
      'fixtures poll Running against a deadline. See docs/testing.md.');
  Expect<Integer>(Violations).ToBe(0);
end;

procedure TChildWaitGuard.TestEveryAllowanceMatchesOneSite;
var
  Allowance: TChildWaitAllowance;
  Finding: TSourceFinding;
  Findings: TSourceFindings;
  Matches: Integer;
begin
  Findings := RepositoryFindings;
  for Allowance in ChildWaitAllowlist do
  begin
    Matches := 0;
    for Finding in Findings do
      if AllowanceMatches(Allowance, Finding) then Inc(Matches);
    if Matches <> 1 then
      WriteLn('CHILD WAIT ALLOWANCE MATCHES ', Matches, ' SITES: ',
        Allowance.Path, ' ', Allowance.Rule, ' ', Allowance.Routine, ' "',
        Allowance.Key, '"');
    Expect<Integer>(Matches).ToBe(1);
  end;
end;

procedure TChildWaitGuard.TestEveryAllowanceGivesAReason;
var
  Allowance: TChildWaitAllowance;
begin
  for Allowance in ChildWaitAllowlist do
    Expect<Boolean>(Length(Trim(Allowance.Reason)) >= 20).ToBe(True);
end;

procedure TChildWaitGuard.TestScanCoversTheTestTree;
var
  Files: TStringList;
begin
  Files := ScanTargets(GuardProgramPath);
  try
    Expect<Boolean>(Files.Count >= MinimumScannedFiles).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'source/LWPT.WorkerBudget.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'tests/integration/BuildSessions.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'tests/support/Tests.ProcessSupport.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'tests/e2e/HealthGit.E2E.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'packages/cli/source/CLI.Parser.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf('source/LWPT.ProcessTree.pas') >= 0)
      .ToBe(False);
    Expect<Boolean>(Files.IndexOf(GuardProgramPath) >= 0).ToBe(False);
  finally
    Files.Free;
  end;
end;

procedure TChildWaitGuard.TestParameterlessWaitsAreDetected;
begin
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'procedure Run;'#10
    + 'begin'#10
    + '  Child.Execute;'#10
    + '  Child.WaitOnExit;'#10
    + '  if Child.Running then Threads[Index].Process.WaitOnExit;'#10
    + '  Owner.Child.WaitOnExit();'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(
      RuleParameterlessWait + '@5:child,'
    + RuleParameterlessWait + '@6:threads[index].process,'
    + RuleParameterlessWait + '@7:owner.child');
  { Inside a TProcess subclass and in a with block. }
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'function TReaper.Reap: Boolean;'#10
    + 'begin'#10
    + '  Result := inherited WaitOnExit;'#10
    + '  with Child do WaitOnExit;'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(
      RuleParameterlessWait + '@4:inherited,'
    + RuleParameterlessWait + '@5:' + SelfReceiver);
  { The barrier before the payload handoff guard: a bounded poll, then an
    unbounded WaitOnExit that hangs whenever the poll gave up. }
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'procedure Stop(AProcess: TProcess);'#10
    + 'begin'#10
    + '  while AProcess.Running and (GetTickCount64 < Deadline) do'#10
    + '    Sleep(10);'#10
    + '  if AProcess.Running then AProcess.WaitOnExit;'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(RuleParameterlessWait + '@6:aprocess');
end;

procedure TChildWaitGuard.TestWaitOnExitOptionIsDetected;
begin
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'const'#10
    + '  Blocking: TProcessOptions = [poWaitOnExit, poNoConsole];'#10
    + 'procedure Run;'#10
    + 'begin'#10
    + '  Utility.Options := [poWaitOnExit];'#10
    + '  Owner.Command.Options := [poUsePipes,'#10
    + '    poWaitOnExit];'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(
      RuleWaitOption + '@3:powaitonexit,'
    + RuleWaitOption + '@6:utility,'
    + RuleWaitOption + '@8:owner.command');
end;

procedure TChildWaitGuard.TestProcessTerminateIsDetected;
begin
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'procedure Cleanup;'#10
    + 'begin'#10
    + '  if Child.Running then Child.Terminate(1);'#10
    + '  Children[0].Terminate(ExitCodeFor(Child));'#10
    + '  with Holder do Terminate(9);'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(
      RuleProcessTerminate + '@4:child,'
    + RuleProcessTerminate + '@5:children[0],'
    + RuleProcessTerminate + '@6:' + SelfReceiver);
end;

procedure TChildWaitGuard.TestUnboundedRunningPollsAreDetected;
begin
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'procedure Drain;'#10
    + 'begin'#10
    + '  while Utility.Running do'#10
    + '  begin'#10
    + '    Output := Output + ReadAvailable(Utility.Output);'#10
    + '    Sleep(10);'#10
    + '  end;'#10
    + '  while (Child.Running) do Sleep(10);'#10
    + '  repeat'#10
    + '    Sleep(10);'#10
    + '  until not Owner.Process.Running;'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe(
      RuleRunningPoll + '@4:utility,'
    + RuleRunningPoll + '@9:child,'
    + RuleRunningPoll + '@10:owner.process');
end;

procedure TChildWaitGuard.TestGeneratedFixturesAreScanned;
begin
  { A nested build a generated test program starts and waits for (the
    bail fixture of TestScheduling before #365). }
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'begin'#10
    + '  WriteTextFile(Path,'#10
    + '      ''program Nested;''#10'#10
    + '    + ''uses Process;''#10'#10
    + '    + ''var Child: TProcess;''#10'#10
    + '    + ''begin''#10'#10
    + '    + ''  Child := TProcess.Create(nil);''#10'#10
    + '    + ''  Child.Executable := '' + PascalString(LwptBinaryPath) + '';''#10'#10
    + '    + ''  Child.Execute;''#10'#10
    + '    + ''  Child.WaitOnExit;''#10'#10
    + '    + ''  if Child.Running then Child.Terminate(1);''#10'#10
    + '    + ''end.''#10);'#10
    + 'end.'#10)).ToBe(
      RuleParameterlessWait + '@11:child,'
    + RuleProcessTerminate + '@12:child');
  { A generated program in a constant, and a headerless fragment. }
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'const'#10
    + '  Fixture = ''begin''#10'#10
    + '    + ''  Child.Options := [poWaitOnExit];''#10'#10
    + '    + ''  while Child.Running do Sleep(1);''#10'#10
    + '    + ''end.''#10;'#10
    + 'begin'#10
    + '  WriteTextFile(Path, Fixture);'#10
    + 'end.'#10)).ToBe(
      RuleWaitOption + '@4:child,'
    + RuleRunningPoll + '@5:child');
  Expect<string>(FindingsOf(
      'Child.Execute;'#10
    + 'Child.WaitOnExit;'#10)).ToBe(RuleParameterlessWait + '@2:child');
end;

procedure TChildWaitGuard.TestBoundedWaitsPass;
begin
  Expect<string>(FindingsOf(
      'program P;'#10
    + 'type'#10
    + '  TReaper = class(TProcess)'#10
    + '    function WaitOnExit: Boolean;'#10
    + '  end;'#10
    + 'function TReaper.WaitOnExit: Boolean;'#10
    + 'begin'#10
    + '  Result := inherited WaitOnExit(1000);'#10
    + 'end;'#10
    + 'procedure Run;'#10
    + 'begin'#10
    + '  Expect<Boolean>(Child.WaitOnExit(CHILD_TIMEOUT_MS)).ToBe(True);'#10
    + '  Code := FinishChild(Child, 60000, ''probe'');'#10
    + '  ReapChild(Child);'#10
    + '  TerminateChildProcess(Child);'#10
    + '  Worker.Terminate;'#10
    + '  ChildTree.Terminate();'#10
    + '  Options := [poUsePipes];'#10
    + '  while Child.Running and (GetTickCount64 < Deadline) do Sleep(10);'#10
    + '  while not Child.Running do Sleep(10);'#10
    + '  while Child.Running do'#10
    + '    if GetTickCount64 >= Deadline then raise Exception.Create(''x'');'#10
    + '  while Child.Running do'#10
    + '  begin'#10
    + '    if Expired then Break;'#10
    + '    Sleep(10);'#10
    + '  end;'#10
    + '  repeat Sleep(10) until not Child.Running or Expired;'#10
    + '  { Child.WaitOnExit; Child.Terminate(1); }'#10
    + '  // Child.Options := [poWaitOnExit];'#10
    + '  WriteLn(''never call Child.WaitOnExit without a deadline'');'#10
    + 'end;'#10
    + 'begin end.'#10)).ToBe('');
end;

procedure TChildWaitGuard.SetupTests;
begin
  Test('repository test code has no unbounded child-process waits',
    TestRepositoryHasNoUnboundedChildWaits);
  Test('every allowance matches exactly one site',
    TestEveryAllowanceMatchesOneSite);
  Test('every allowance gives its reason', TestEveryAllowanceGivesAReason);
  Test('the scan covers the repository test tree',
    TestScanCoversTheTestTree);
  Test('parameterless WaitOnExit calls are detected',
    TestParameterlessWaitsAreDetected);
  Test('the poWaitOnExit option is detected',
    TestWaitOnExitOptionIsDetected);
  Test('TProcess.Terminate calls are detected',
    TestProcessTerminateIsDetected);
  Test('Running polls without a deadline are detected',
    TestUnboundedRunningPollsAreDetected);
  Test('generated fixture programs are scanned',
    TestGeneratedFixturesAreScanned);
  Test('bounded waits pass', TestBoundedWaitsPass);
end;

begin
  TestRunnerProgram.AddSuite(TChildWaitGuard.Create('child wait guard'));
  TestRunnerProgram.Run;
end.
