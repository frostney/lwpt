{ ListenerPortGuard.Test — a heuristic tripwire that keeps fixed TCP ports
  in test code below every platform's default ephemeral range.

  The kernel hands ephemeral ports to every outbound connection that does
  not bind first: Linux from 32768-60999, Windows and macOS from
  49152-65535, and FreeBSD from 10000-65535. A test listener on a fixed
  port inside that range collides whenever a concurrent test program's
  loopback connection happens to be auto-bound to it. The collision is an
  EADDRINUSE that SO_REUSEADDR cannot override, because the connecting
  socket lacks the option. The retrieval recorder's port 47931 failed this
  way in PR #366's run 37213048005, so this program scans the repository's
  test code and fails when such a port returns. Listeners that need no
  fixed port bind port 0 and read the assignment back; a port that is
  baked into a fixture (the recorder's) must sit below
  LowestEphemeralPort.

  Files are tokenized by LWPT.Analysis.Pascal. Like lwpt health it reads
  inactive conditional branches as well. Three rules, each on an integer
  from LowestEphemeralPort to 65535:

    port-constant  An identifier with a separate "port" word (Port, APort,
                   ListenPort, RECORDER_PORT, sin_port, but not Report or
                   Transport) declared, typed-declared, or assigned with
                   that integer as the first token of its value.
    port-htons     htons(N) with that integer as its only argument.
    port-argument  A '--port' string literal followed by the integer as
                   a string literal, or a '--port=N' literal.

  Limits. Ports computed at run time (a base plus a PID offset) or passed
  through an intermediate variable are not seen, and include directives
  are not followed. A configuration value that is never bound is still
  reported; give it a port below LowestEphemeralPort. Ports chosen by the
  kernel and released before a child process binds them are a separate
  race, handled where they are used (Tests.RegistryProcess relocates a
  listener that loses it). }

program ListenerPortGuard.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  LWPT.Analysis.Pascal,
  TestingPascalLibrary,
  Tests.Scratch;

const
  RuleConstant = 'port-constant';
  RuleHtons = 'port-htons';
  RuleArgument = 'port-argument';
  { FreeBSD's default first ephemeral port, the lowest of any platform
    LWPT documents; Linux starts at 32768, Windows and macOS at 49152. }
  LowestEphemeralPort = 10000;
  HighestPort = 65535;
  { The self-tests below embed violating snippets as literals. }
  GuardProgramPath = 'tests/integration/ListenerPortGuard.Test.pas';
  { A scan that finds almost nothing is scanning the wrong tree. }
  MinimumScannedFiles = 50;

type
  TPortFinding = record
    Path: string;
    Line: Integer;
    Rule: string;
    Evidence: string;
  end;
  TPortFindings = array of TPortFinding;

  TListenerPortGuard = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRepositoryKeepsFixedPortsBelowEphemeralRanges;
    procedure TestScanCoversTheTestTree;
    procedure TestHistoricalRecorderPortIsDetected;
    procedure TestFixedPortShapesAreDetected;
    procedure TestSafePortsAndLookalikesPass;
  end;

{ Splits an identifier's source spelling into words at underscores and
  case changes: APort -> A Port, ListenPORT -> Listen PORT, Report ->
  Report. }
function HasPortWord(const AOriginal: string): Boolean;
var
  Index, Start: Integer;

  function WordAt(AFirst, ALast: Integer): Boolean;
  begin
    Result := (ALast >= AFirst)
      and SameText(Copy(AOriginal, AFirst, ALast - AFirst + 1), 'port');
  end;

begin
  Start := 1;
  for Index := 1 to Length(AOriginal) do
  begin
    if AOriginal[Index] = '_' then
    begin
      if WordAt(Start, Index - 1) then Exit(True);
      Start := Index + 1;
    end
    else if (Index > Start) and (AOriginal[Index] in ['A'..'Z']) and
      ((AOriginal[Index - 1] in ['a'..'z', '0'..'9']) or
       ((Index < Length(AOriginal)) and (AOriginal[Index + 1] in ['a'..'z'])
        and (AOriginal[Index - 1] in ['A'..'Z']))) then
    begin
      if WordAt(Start, Index - 1) then Exit(True);
      Start := Index;
    end;
  end;
  Result := WordAt(Start, Length(AOriginal));
end;

{ Decimal or $-hexadecimal; -1 for any other spelling (reals included). }
function NumberValue(const AText: string): Int64;
begin
  Result := StrToInt64Def(AText, -1);
end;

function InEphemeralRange(const AValue: Int64): Boolean;
begin
  Result := (AValue >= LowestEphemeralPort) and (AValue <= HighestPort);
end;

{ The text of a single-quoted literal; '' for any other spelling. }
function QuotedText(const AOriginal: string): string;
begin
  Result := '';
  if (Length(AOriginal) >= 2) and (AOriginal[1] = '''')
     and (AOriginal[Length(AOriginal)] = '''') then
    Result := StringReplace(Copy(AOriginal, 2, Length(AOriginal) - 2),
      '''''', '''', [rfReplaceAll]);
end;

function ScanPortSource(const APath, ASource: string): TPortFindings;
var
  Tokens: TLWPTPascalTokenArray;
  Originals: array of string;
  Index, Value: Integer;
  Findings: TPortFindings;

  function SymbolAt(AIndex: Integer; const AText: string): Boolean;
  begin
    Result := (AIndex >= 0) and (AIndex <= High(Tokens))
      and (Tokens[AIndex].Kind = ptSymbol) and (Tokens[AIndex].Text = AText);
  end;

  function NumberAt(AIndex: Integer): Int64;
  begin
    Result := -1;
    if (AIndex >= 0) and (AIndex <= High(Tokens))
       and (Tokens[AIndex].Kind = ptNumber) then
      Result := NumberValue(Originals[AIndex]);
  end;

  procedure Add(const ARule: string; AIndex: Integer;
    const AEvidence: string);
  begin
    SetLength(Findings, Length(Findings) + 1);
    Findings[High(Findings)].Path := APath;
    Findings[High(Findings)].Line := Tokens[AIndex].Line;
    Findings[High(Findings)].Rule := ARule;
    Findings[High(Findings)].Evidence := AEvidence;
  end;

  { Index of the value's first token after Name [: Type] (= | :=). }
  function ValueStart(AIndex: Integer): Integer;
  begin
    Result := -1;
    if SymbolAt(AIndex + 1, '=') or SymbolAt(AIndex + 1, ':=') then
      Exit(AIndex + 2);
    if SymbolAt(AIndex + 1, ':') and (AIndex + 3 <= High(Tokens))
       and (Tokens[AIndex + 2].Kind = ptIdentifier)
       and SymbolAt(AIndex + 3, '=') then
      Exit(AIndex + 4);
  end;

begin
  Findings := nil;
  Tokens := TokenizePascal(ASource, APath);
  SetLength(Originals, Length(Tokens));
  for Index := 0 to High(Tokens) do
    Originals[Index] := Copy(ASource, Tokens[Index].Offset + 1,
      Tokens[Index].Length);
  for Index := 0 to High(Tokens) do
  begin
    if (Tokens[Index].Kind = ptIdentifier) and HasPortWord(Originals[Index])
       then
    begin
      Value := ValueStart(Index);
      if (Value >= 0) and InEphemeralRange(NumberAt(Value)) then
        Add(RuleConstant, Index, Originals[Index] + ' = ' + Originals[Value]);
    end;
    if (Tokens[Index].Kind = ptIdentifier) and (Tokens[Index].Text = 'htons')
       and SymbolAt(Index + 1, '(') and SymbolAt(Index + 3, ')')
       and InEphemeralRange(NumberAt(Index + 2)) then
      Add(RuleHtons, Index, 'htons(' + Originals[Index + 2] + ')');
    if Tokens[Index].Kind = ptString then
    begin
      if (QuotedText(Originals[Index]) = '--port') and SymbolAt(Index + 1, ',')
         and (Index + 2 <= High(Tokens))
         and (Tokens[Index + 2].Kind = ptString)
         and InEphemeralRange(StrToInt64Def(
           QuotedText(Originals[Index + 2]), -1)) then
        Add(RuleArgument, Index, '--port ' + Originals[Index + 2]);
      if (Copy(QuotedText(Originals[Index]), 1, 7) = '--port=')
         and InEphemeralRange(StrToInt64Def(
           Copy(QuotedText(Originals[Index]), 8, MaxInt), -1)) then
        Add(RuleArgument, Index, Originals[Index]);
    end;
  end;
  Result := Findings;
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

function RulesOf(const ASource: string): string;
var
  Finding: TPortFinding;
begin
  Result := '';
  for Finding in ScanPortSource('synthetic.pas', ASource) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + Finding.Rule + '@' + IntToStr(Finding.Line);
  end;
end;

{ Tests ------------------------------------------------------------------ }

procedure TListenerPortGuard.TestRepositoryKeepsFixedPortsBelowEphemeralRanges;
var
  Files: TStringList;
  Finding: TPortFinding;
  FileIndex, Violations: Integer;
begin
  Violations := 0;
  Files := ScanTargets;
  try
    for FileIndex := 0 to Files.Count - 1 do
      for Finding in ScanPortSource(Files[FileIndex],
        ReadBinaryFile(Files[FileIndex])) do
      begin
        WriteLn('EPHEMERAL LISTENER PORT ', Finding.Path, ':', Finding.Line,
          ': ', Finding.Rule, ': ', Finding.Evidence);
        Inc(Violations);
      end;
  finally
    Files.Free;
  end;
  if Violations > 0 then
    WriteLn('A concurrent test''s outbound connection can be auto-bound to ',
      'a port from ', LowestEphemeralPort, ' to ', HighestPort, '. Bind port ',
      '0 and read the assignment back, or use a fixed port below ',
      LowestEphemeralPort, '. See docs/testing.md.');
  Expect<Integer>(Violations).ToBe(0);
end;

procedure TListenerPortGuard.TestScanCoversTheTestTree;
var
  Files: TStringList;
begin
  Files := ScanTargets;
  try
    Expect<Boolean>(Files.Count >= MinimumScannedFiles).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'packages/httpclient/source/Tests.RetrievalRecorder.pas') >= 0)
      .ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'packages/httpclient/source/Tests.HTTPMockServer.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'tests/support/Tests.RegistryServer.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf(
      'source/LWPT.Registry.Mirror.Test.pas') >= 0).ToBe(True);
    Expect<Boolean>(Files.IndexOf('source/LWPT.Registry.Store.pas') >= 0)
      .ToBe(False);
    Expect<Boolean>(Files.IndexOf(GuardProgramPath) >= 0).ToBe(False);
  finally
    Files.Free;
  end;
end;

procedure TListenerPortGuard.TestHistoricalRecorderPortIsDetected;
begin
  { Tests.RetrievalRecorder before PR #366's run 37213048005. }
  Expect<string>(RulesOf(
      'unit Tests.RetrievalRecorder;'#10
    + 'interface'#10
    + 'const'#10
    + '  RETRIEVAL_RECORDER_PORT = 47931;'#10
    + 'implementation'#10
    + 'end.'#10)).ToBe(RuleConstant + '@4');
end;

procedure TListenerPortGuard.TestFixedPortShapesAreDetected;
begin
  Expect<string>(RulesOf(
      'program P;'#10
    + 'const'#10
    + '  FIXED_PORT: Word = 50000;'#10
    + '  ListenPort = $BB3B;'#10
    + 'begin'#10
    + '  Server.Port := 40000;'#10
    + '  APort := 32768 + Offset;'#10
    + '  Address.sin_port := HToNs(47931);'#10
    + '  Addr.sin_port := WinSock2.htons(65535);'#10
    + '  Run([''registry'', ''serve'', ''--port'', ''47931'']);'#10
    + '  Run([''registry'', ''init'', ''--port=10000'']);'#10
    + 'end.'#10)).ToBe(RuleConstant + '@3,' + RuleConstant + '@4,'
    + RuleConstant + '@6,' + RuleConstant + '@7,' + RuleHtons + '@8,'
    + RuleHtons + '@9,' + RuleArgument + '@10,' + RuleArgument + '@11');
end;

procedure TListenerPortGuard.TestSafePortsAndLookalikesPass;
begin
  Expect<string>(RulesOf(
      'program P;'#10
    + 'const'#10
    + '  RETRIEVAL_RECORDER_PORT = 6741;'#10
    + '  REPORT_LIMIT = 50000;'#10
    + '  TransportBudget = 65535;'#10
    + '  ImportCount: Integer = 40000;'#10
    + '  ReadBufferBytes = 32768;'#10
    + 'var'#10
    + '  Buffer: array[0..65535] of Byte;'#10
    + 'begin'#10
    + '  Address.sin_port := 0;'#10
    + '  Address.sin_port := htons(APort);'#10
    + '  Port := FindAvailableRegistryTestPort;'#10
    + '  Config.Port := 9443;'#10
    + '  Expected := Port + 40000;'#10
    + '  Run([''registry'', ''serve'', ''--port'', IntToStr(Port)]);'#10
    + '  Run([''registry'', ''init'', ''--port'', ''8080'']);'#10
    + '  Run([''--timeout'', ''50000'']);'#10
    + '  Text := ''Port = 47931'';'#10
    + '  { Port := 47931 }'#10
    + 'end.'#10)).ToBe('');
end;

procedure TListenerPortGuard.SetupTests;
begin
  Test('repository test code keeps fixed ports below default ephemeral ranges',
    TestRepositoryKeepsFixedPortsBelowEphemeralRanges);
  Test('the scan covers the repository test tree', TestScanCoversTheTestTree);
  Test('the historical retrieval-recorder port is detected',
    TestHistoricalRecorderPortIsDetected);
  Test('fixed-port constants, htons literals, and --port arguments are detected',
    TestFixedPortShapesAreDetected);
  Test('safe ports and look-alike identifiers pass',
    TestSafePortsAndLookalikesPass);
end;

begin
  TestRunnerProgram.AddSuite(TListenerPortGuard.Create('listener port guard'));
  TestRunnerProgram.Run;
end.
