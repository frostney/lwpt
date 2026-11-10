{ CLI.Parser.Test — option syntax over real argv and over argument arrays.

  ParseCommandLine reads ParamStr / ParamCount directly, so each of its
  tests spawns this binary in child mode with the argv shape under test.
  The child registers a representative option table, parses its own argv,
  and checks the resulting option objects and positionals.

  ParseArguments, LeadingFlagGiven and EndOfOptionsIndex take the arguments
  as an array, so the end-of-options marker and stop-at-first-positional
  cases run in-process. }

program CLI.Parser.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  CLI.Options,
  CLI.Parser,
  TestingPascalLibrary;

const
  CHILD_MODE = '--child';
  { Each child parses its argv and exits at once. }
  CHILD_TIMEOUT_MILLISECONDS = 60000;

type
  TCLIParserSuite = class(TTestSuite)
  private
    function RunChild(const AScenario: string;
      const AArguments: array of string): Integer;
  public
    procedure SetupTests; override;
    procedure TestSeparatedValuedShortOption;
    procedure TestSeparatedShortValueMayStartWithHyphen;
    procedure TestAttachedAndSeparatedRepeatableShortOptions;
    procedure TestAttachedValueRequiresOptIn;
    procedure TestMissingShortValue;
    procedure TestUnknownShortOption;
    procedure TestValuelessShortFlag;
    procedure TestLongEqualsValueUnchanged;
    procedure TestLongSeparatedValueUnchanged;
    procedure TestCommandLineArgumentsStartAtTheGivenPosition;
  end;

  TCLIParserArgumentsSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestOptionsAreReadAfterPositionalsByDefault;
    procedure TestEndOfOptionsMarkerMakesTheRestPositional;
    procedure TestEndOfOptionsMarkerIsNotAPositional;
    procedure TestEndOfOptionsMarkerInValuePosition;
    procedure TestEndOfOptionsIndexFollowsTheParser;
    procedure TestStopAtFirstPositionalPassesTheRestThrough;
    procedure TestStopAtFirstPositionalConsumesOnlyALeadingMarker;
    procedure TestStopAtFirstPositionalRejectsLeadingUnknownOptions;
    procedure TestStopAtFirstPositionalEndsAtAnUnmatchedDashToken;
    procedure TestLeadingFlagGivenBeforeTheFirstPositional;
    procedure TestLeadingFlagNotGivenPastTheEndOfOptions;
    procedure TestLeadingFlagGivenAppliesNothing;
  end;

  { A representative option table for the in-process tests. }
  TParserFixture = class
  public
    Options: TOptionArray;
    Output: TStringOption;
    Define: TRepeatableOption;
    Verbose: TFlagOption;
    constructor Create;
    destructor Destroy; override;
    { ParseArguments, with the positionals joined by `|`. }
    function Parse(const AArguments: array of string;
      AStopAtFirstPositional: Boolean = False): string;
    { The TParseError message ParseArguments raises, or '' for none. }
    function ParseError(const AArguments: array of string;
      AStopAtFirstPositional: Boolean = False): string;
    function HelpGiven(const AArguments: array of string): Boolean;
  end;

const
  POSITIONAL_SEPARATOR = '|';
  HELP_LONG_NAME = 'help';
  HELP_SHORT_NAME = 'h';

constructor TParserFixture.Create;
begin
  inherited Create;
  Output := TStringOption.Create('output', 'output path');
  Output.ShortName := 'o';
  Define := TRepeatableOption.Create('define', 'conditional symbol');
  Define.ShortName := 'd';
  Define.AllowAttachedShortValue := True;
  Verbose := TFlagOption.Create('verbose', 'say more');
  Verbose.ShortName := 'V';
  SetLength(Options, 3);
  Options[0] := Output;
  Options[1] := Define;
  Options[2] := Verbose;
end;

destructor TParserFixture.Destroy;
begin
  Verbose.Free;
  Define.Free;
  Output.Free;
  inherited Destroy;
end;

function TParserFixture.Parse(const AArguments: array of string;
  AStopAtFirstPositional: Boolean = False): string;
var
  Positionals: TStringList;
  I: Integer;
begin
  Result := '';
  Positionals := ParseArguments(AArguments, Options, AStopAtFirstPositional);
  try
    for I := 0 to Positionals.Count - 1 do
    begin
      if I > 0 then Result := Result + POSITIONAL_SEPARATOR;
      Result := Result + Positionals[I];
    end;
  finally
    Positionals.Free;
  end;
end;

function TParserFixture.ParseError(const AArguments: array of string;
  AStopAtFirstPositional: Boolean = False): string;
begin
  Result := '';
  try
    Parse(AArguments, AStopAtFirstPositional);
  except
    on E: TParseError do Result := E.Message;
  end;
end;

function TParserFixture.HelpGiven(
  const AArguments: array of string): Boolean;
begin
  Result := LeadingFlagGiven(AArguments, Options, HELP_LONG_NAME,
    HELP_SHORT_NAME);
end;

function ScenarioFailure(const AMessage: string): Integer;
begin
  WriteLn(ErrOutput, AMessage);
  Result := 1;
end;

{ The child's own arguments start at position 3, after the mode word and
  the scenario name. }
function RunCommandLineArgumentsScenario: Integer;
var
  Arguments: TCommandLineArguments;
begin
  Arguments := GetCommandLineArguments(3);
  if Length(Arguments) <> 3 then
    Exit(ScenarioFailure('wrong argument count from position 3'));
  if (Arguments[0] <> 'first') or (Arguments[1] <> '--') or
     (Arguments[2] <> '-last') then
    Exit(ScenarioFailure('arguments from position 3 differ from argv'));
  if Length(GetCommandLineArguments) <> ParamCount then
    Exit(ScenarioFailure('default position does not start at argv[1]'));
  if Length(GetCommandLineArguments(ParamCount + 1)) <> 0 then
    Exit(ScenarioFailure('a position past argv is not empty'));
  Result := 0;
end;

function RunParserScenario(const AScenario: string): Integer;
var
  Options: TOptionArray;
  OutputOption: TStringOption;
  ShortFOption, UnitDirectoryOption, DefineOption: TRepeatableOption;
  HelpOption: TFlagOption;
  Positionals: TStringList;
  ExpectedError: string;
begin
  SetLength(Options, 5);
  OutputOption := TStringOption.Create('output', 'output path');
  OutputOption.ShortName := 'o';
  Options[0] := OutputOption;

  ShortFOption := TRepeatableOption.Create('framework', 'framework');
  ShortFOption.ShortName := 'F';
  ShortFOption.AllowAttachedShortValue := True;
  Options[1] := ShortFOption;

  UnitDirectoryOption := TRepeatableOption.Create(
    'unit-directory', 'unit directory');
  UnitDirectoryOption.ShortName := 'Fu';
  UnitDirectoryOption.AllowAttachedShortValue := True;
  Options[2] := UnitDirectoryOption;

  DefineOption := TRepeatableOption.Create('define', 'conditional symbol');
  DefineOption.ShortName := 'd';
  DefineOption.AllowAttachedShortValue := True;
  Options[3] := DefineOption;

  HelpOption := TFlagOption.Create('help', 'show help');
  HelpOption.ShortName := 'h';
  Options[4] := HelpOption;

  Positionals := nil;
  ExpectedError := '';
  if AScenario = 'missing-value' then
    ExpectedError := '-o requires a value'
  else if AScenario = 'unknown-option' then
    ExpectedError := 'Unknown option: -x';

  try
    try
      Positionals := ParseCommandLine(Options, 3);
    except
      on E: TParseError do
      begin
        if (ExpectedError <> '') and (E.Message = ExpectedError) then
          Exit(0);
        Exit(ScenarioFailure('unexpected parse error: ' + E.Message));
      end;
    end;

    if ExpectedError <> '' then
      Exit(ScenarioFailure('expected parse error: ' + ExpectedError));

    if AScenario = 'separated-value' then
    begin
      if OutputOption.ValueOr('') <> 'out.wasm' then
        Exit(ScenarioFailure('-o did not bind its separated value'));
      if (Positionals.Count <> 1) or
         (Positionals[0] <> 'input.pas') then
        Exit(ScenarioFailure('-o value leaked into positionals'));
    end
    else if AScenario = 'hyphen-value' then
    begin
      if OutputOption.ValueOr('') <> '-generated.wasm' then
        Exit(ScenarioFailure('-o rejected a hyphen-leading value'));
    end
    else if AScenario = 'attached-repeatable' then
    begin
      if ShortFOption.Values.Count <> 0 then
        Exit(ScenarioFailure('-Fu matched the shorter -F prefix'));
      if (UnitDirectoryOption.Values.Count <> 2) or
         (UnitDirectoryOption.Values[0] <> 'source') or
         (UnitDirectoryOption.Values[1] <> 'lib') then
        Exit(ScenarioFailure('-Fu values were not parsed in order'));
      if (DefineOption.Values.Count <> 2) or
         (DefineOption.Values[0] <> 'DEBUG') or
         (DefineOption.Values[1] <> 'TRACE') then
        Exit(ScenarioFailure('-d values were not parsed in order'));
    end
    else if AScenario = 'attached-requires-opt-in' then
    begin
      if OutputOption.Present then
        Exit(ScenarioFailure('-o accepted an attached value without opt-in'));
      if (Positionals.Count <> 1) or
         (Positionals[0] <> '-oout.wasm') then
        Exit(ScenarioFailure('unmatched attached token changed behavior'));
    end
    else if AScenario = 'short-flag' then
    begin
      if not HelpOption.Present then
        Exit(ScenarioFailure('-h did not set the flag'));
    end
    else if (AScenario = 'long-equals') or
            (AScenario = 'long-separated') then
    begin
      if OutputOption.ValueOr('') <> 'out.wasm' then
        Exit(ScenarioFailure('--output did not bind its value'));
    end
    else
      Exit(ScenarioFailure('unknown scenario: ' + AScenario));

    Result := 0;
  finally
    Positionals.Free;
    HelpOption.Free;
    DefineOption.Free;
    UnitDirectoryOption.Free;
    ShortFOption.Free;
    OutputOption.Free;
  end;
end;

{$IFDEF MSWINDOWS}
{ Declared here rather than through the Windows unit, which would shadow
  SysUtils routines. }
function TerminateChildHandle(AProcess: THandle;
  AExitCode: LongWord): LongBool; stdcall;
  external 'kernel32.dll' name 'TerminateProcess';
{$ENDIF}

{ A bounded replacement for poWaitOnExit, which waits forever for a child
  that never exits. Running is a nonblocking status query that also reaps
  the child on Unix, so ExitCode then decodes its status. A child past the
  deadline is killed and reported as an error. }
function FinishChildWithin(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord): Integer;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while AProcess.Running
    and (GetTickCount64 - StartedAt < ATimeoutMilliseconds) do
    Sleep(10);
  if AProcess.Running then
  begin
    {$IFDEF UNIX}
    FpKill(AProcess.ProcessID, SIGKILL);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    TerminateChildHandle(AProcess.ProcessHandle, 1);
    {$ENDIF}
    StartedAt := GetTickCount64;
    while AProcess.Running and (GetTickCount64 - StartedAt < 2000) do
      Sleep(10);
    raise Exception.CreateFmt('child %s did not exit within %d ms',
      [AProcess.Executable, ATimeoutMilliseconds]);
  end;
  Result := AProcess.ExitCode;
  if (Result = 0) and (AProcess.ExitStatus <> 0) then
    Result := AProcess.ExitStatus;
end;

function TCLIParserSuite.RunChild(const AScenario: string;
  const AArguments: array of string): Integer;
var
  ProcessInstance: TProcess;
  I: Integer;
begin
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := ExpandFileName(ParamStr(0));
    ProcessInstance.Parameters.Add(CHILD_MODE);
    ProcessInstance.Parameters.Add(AScenario);
    for I := 0 to High(AArguments) do
      ProcessInstance.Parameters.Add(AArguments[I]);
    ProcessInstance.Execute;
    Result := FinishChildWithin(ProcessInstance, CHILD_TIMEOUT_MILLISECONDS);
  finally
    ProcessInstance.Free;
  end;
end;

procedure TCLIParserSuite.TestSeparatedValuedShortOption;
begin
  Expect<Integer>(RunChild('separated-value',
    ['-o', 'out.wasm', 'input.pas'])).ToBe(0);
end;

procedure TCLIParserSuite.TestAttachedAndSeparatedRepeatableShortOptions;
begin
  Expect<Integer>(RunChild('attached-repeatable',
    ['-Fusource', '-Fu', 'lib', '-dDEBUG', '-d', 'TRACE'])).ToBe(0);
end;

procedure TCLIParserSuite.TestSeparatedShortValueMayStartWithHyphen;
begin
  Expect<Integer>(RunChild('hyphen-value',
    ['-o', '-generated.wasm'])).ToBe(0);
end;

procedure TCLIParserSuite.TestAttachedValueRequiresOptIn;
begin
  Expect<Integer>(RunChild('attached-requires-opt-in',
    ['-oout.wasm'])).ToBe(0);
end;

procedure TCLIParserSuite.TestMissingShortValue;
begin
  Expect<Integer>(RunChild('missing-value', ['-o'])).ToBe(0);
end;

procedure TCLIParserSuite.TestUnknownShortOption;
begin
  Expect<Integer>(RunChild('unknown-option', ['-x'])).ToBe(0);
end;

procedure TCLIParserSuite.TestValuelessShortFlag;
begin
  Expect<Integer>(RunChild('short-flag', ['-h'])).ToBe(0);
end;

procedure TCLIParserSuite.TestLongEqualsValueUnchanged;
begin
  Expect<Integer>(RunChild('long-equals',
    ['--output=out.wasm'])).ToBe(0);
end;

procedure TCLIParserSuite.TestLongSeparatedValueUnchanged;
begin
  Expect<Integer>(RunChild('long-separated',
    ['--output', 'out.wasm'])).ToBe(0);
end;

procedure TCLIParserSuite.TestCommandLineArgumentsStartAtTheGivenPosition;
begin
  Expect<Integer>(RunChild('command-line-arguments',
    ['first', '--', '-last'])).ToBe(0);
end;

procedure TCLIParserArgumentsSuite.TestOptionsAreReadAfterPositionalsByDefault;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<string>(Fixture.Parse(['main.x', '--verbose', 'other',
      '-o', 'out'])).ToBe('main.x|other');
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(True);
    Expect<string>(Fixture.Output.ValueOr('')).ToBe('out');
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestEndOfOptionsMarkerMakesTheRestPositional;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<string>(Fixture.Parse(['--verbose', 'first', '--', '--output',
      'out', '-dDEBUG', '--unknown', '-x', '--', 'help'])).ToBe(
      'first|--output|out|-dDEBUG|--unknown|-x|--|help');
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(True);
    Expect<Boolean>(Fixture.Output.Present).ToBe(False);
    Expect<Integer>(Fixture.Define.Values.Count).ToBe(0);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestEndOfOptionsMarkerIsNotAPositional;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<string>(Fixture.Parse(['--'])).ToBe('');
    Expect<string>(Fixture.Parse(['--verbose', '--'])).ToBe('');
    Expect<string>(Fixture.Parse(['first', '--', 'second'])).ToBe(
      'first|second');
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestEndOfOptionsMarkerInValuePosition;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    { A separated long value never begins with a hyphen, so the marker
      is not taken for one. }
    Expect<string>(Fixture.ParseError(['--output', '--', 'out'])).ToBe(
      '--output requires a value');
    { A separated short value may begin with a hyphen, the marker
      included. }
    Expect<string>(Fixture.Parse(['-o', '--', '--verbose'])).ToBe('');
    Expect<string>(Fixture.Output.ValueOr('')).ToBe('--');
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(True);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestEndOfOptionsIndexFollowsTheParser;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<Integer>(EndOfOptionsIndex([], Fixture.Options)).ToBe(0);
    Expect<Integer>(EndOfOptionsIndex(['first', 'second'],
      Fixture.Options)).ToBe(2);
    Expect<Integer>(EndOfOptionsIndex(['first', '--', 'second', '--'],
      Fixture.Options)).ToBe(1);
    Expect<Integer>(EndOfOptionsIndex(['--bogus', '-x', '--'],
      Fixture.Options)).ToBe(2);
    { A valued short option reads the marker as its value; a long one
      never does. }
    Expect<Integer>(EndOfOptionsIndex(['-o', '--', 'first'],
      Fixture.Options)).ToBe(3);
    Expect<Integer>(EndOfOptionsIndex(['-o', '--', '--', 'first'],
      Fixture.Options)).ToBe(2);
    Expect<Integer>(EndOfOptionsIndex(['--output', '--', 'first'],
      Fixture.Options)).ToBe(1);
    Expect<Boolean>(Fixture.Output.Present).ToBe(False);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestStopAtFirstPositionalPassesTheRestThrough;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<string>(Fixture.Parse(['--output', 'out', '-dDEBUG', 'main.x',
      '--port', '80', '--', '--verbose', '-o', 'help', '--help'],
      True)).ToBe('main.x|--port|80|--|--verbose|-o|help|--help');
    Expect<string>(Fixture.Output.ValueOr('')).ToBe('out');
    Expect<Integer>(Fixture.Define.Values.Count).ToBe(1);
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(False);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.
  TestStopAtFirstPositionalConsumesOnlyALeadingMarker;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<string>(Fixture.Parse(['--verbose', '--', '--port', 'main.x',
      '--'], True)).ToBe('--port|main.x|--');
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(True);
    Expect<string>(Fixture.Parse(['--'], True)).ToBe('');
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.
  TestStopAtFirstPositionalRejectsLeadingUnknownOptions;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<string>(Fixture.ParseError(['--bogus', 'main.x'], True)).ToBe(
      'Unknown option: --bogus');
    Expect<string>(Fixture.ParseError(['-x', 'main.x'], True)).ToBe(
      'Unknown option: -x');
    Expect<string>(Fixture.ParseError(['--output'], True)).ToBe(
      '--output requires a value');
    { The same spellings after the first positional are not read. }
    Expect<string>(Fixture.ParseError(['main.x', '--bogus', '-x',
      '--output'], True)).ToBe('');
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.
  TestStopAtFirstPositionalEndsAtAnUnmatchedDashToken;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    { An unmatched multi-character single-dash token and a lone hyphen
      are positionals, so each one ends option parsing. }
    Expect<string>(Fixture.Parse(['-abc', '--verbose'], True)).ToBe(
      '-abc|--verbose');
    Expect<string>(Fixture.Parse(['-', '--verbose'], True)).ToBe(
      '-|--verbose');
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(False);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestLeadingFlagGivenBeforeTheFirstPositional;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<Boolean>(Fixture.HelpGiven(['--help'])).ToBe(True);
    Expect<Boolean>(Fixture.HelpGiven(['-h'])).ToBe(True);
    Expect<Boolean>(Fixture.HelpGiven(['--verbose', '--output', 'out',
      '-dDEBUG', '-h', 'main.x'])).ToBe(True);
    { Arguments the parser would reject do not hide the flag. }
    Expect<Boolean>(Fixture.HelpGiven(['--bogus', '-x', '--help'])).ToBe(
      True);
    Expect<Boolean>(Fixture.HelpGiven(['--output', '--help'])).ToBe(True);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestLeadingFlagNotGivenPastTheEndOfOptions;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<Boolean>(Fixture.HelpGiven([])).ToBe(False);
    Expect<Boolean>(Fixture.HelpGiven(['main.x', '--help', '-h'])).ToBe(
      False);
    Expect<Boolean>(Fixture.HelpGiven(['--', '--help'])).ToBe(False);
    Expect<Boolean>(Fixture.HelpGiven(['-abc', '-h'])).ToBe(False);
    { A valued short option reads the next argument as its value. }
    Expect<Boolean>(Fixture.HelpGiven(['-o', '-h'])).ToBe(False);
    Expect<Boolean>(Fixture.HelpGiven(['-d', '--help'])).ToBe(False);
    { Only the exact spellings count. }
    Expect<Boolean>(Fixture.HelpGiven(['--help=yes'])).ToBe(False);
    Expect<Boolean>(Fixture.HelpGiven(['--HELP', '-H'])).ToBe(False);
    Expect<Boolean>(Fixture.HelpGiven(['help'])).ToBe(False);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.TestLeadingFlagGivenAppliesNothing;
var
  Fixture: TParserFixture;
begin
  Fixture := TParserFixture.Create;
  try
    Expect<Boolean>(Fixture.HelpGiven(['--verbose', '--output', 'out',
      '-dDEBUG', '--help'])).ToBe(True);
    Expect<Boolean>(Fixture.Verbose.Present).ToBe(False);
    Expect<Boolean>(Fixture.Output.Present).ToBe(False);
    Expect<Integer>(Fixture.Define.Values.Count).ToBe(0);
  finally
    Fixture.Free;
  end;
end;

procedure TCLIParserArgumentsSuite.SetupTests;
begin
  Test('options are read after positionals by default',
    TestOptionsAreReadAfterPositionalsByDefault);
  Test('the end-of-options marker makes every later argument positional',
    TestEndOfOptionsMarkerMakesTheRestPositional);
  Test('the end-of-options marker itself is not a positional',
    TestEndOfOptionsMarkerIsNotAPositional);
  Test('the marker is a short option''s value but never a long option''s',
    TestEndOfOptionsMarkerInValuePosition);
  Test('the end-of-options index is the marker the parser reads',
    TestEndOfOptionsIndexFollowsTheParser);
  Test('stop-at-first-positional returns the rest of the line verbatim',
    TestStopAtFirstPositionalPassesTheRestThrough);
  Test('stop-at-first-positional consumes only a leading marker',
    TestStopAtFirstPositionalConsumesOnlyALeadingMarker);
  Test('stop-at-first-positional rejects unknown options before the positional',
    TestStopAtFirstPositionalRejectsLeadingUnknownOptions);
  Test('stop-at-first-positional ends at an unmatched single-dash token',
    TestStopAtFirstPositionalEndsAtAnUnmatchedDashToken);
  Test('a leading flag is found before the first positional',
    TestLeadingFlagGivenBeforeTheFirstPositional);
  Test('a leading flag is not found past the end of options or as a value',
    TestLeadingFlagNotGivenPastTheEndOfOptions);
  Test('looking for a leading flag applies no option',
    TestLeadingFlagGivenAppliesNothing);
end;

procedure TCLIParserSuite.SetupTests;
begin
  Test('separated valued short option binds the following argv',
    TestSeparatedValuedShortOption);
  Test('separated short option values may begin with a hyphen',
    TestSeparatedShortValueMayStartWithHyphen);
  Test('attached values support multi-character and repeatable short options',
    TestAttachedAndSeparatedRepeatableShortOptions);
  Test('attached short values require an explicit opt-in',
    TestAttachedValueRequiresOptIn);
  Test('valued short option without a value raises a clear error',
    TestMissingShortValue);
  Test('unknown short option raises TParseError',
    TestUnknownShortOption);
  Test('existing valueless short flags remain unchanged',
    TestValuelessShortFlag);
  Test('long equals-separated values remain unchanged',
    TestLongEqualsValueUnchanged);
  Test('long space-separated values remain unchanged',
    TestLongSeparatedValueUnchanged);
  Test('GetCommandLineArguments returns argv from the given position',
    TestCommandLineArgumentsStartAtTheGivenPosition);
end;

begin
  if (ParamCount >= 2) and (ParamStr(1) = CHILD_MODE) then
  begin
    if ParamStr(2) = 'command-line-arguments' then
      ExitCode := RunCommandLineArgumentsScenario
    else
      ExitCode := RunParserScenario(ParamStr(2));
    Exit;
  end;

  TestRunnerProgram.AddSuite(TCLIParserSuite.Create(
    'CLI.Parser: process arguments'));
  TestRunnerProgram.AddSuite(TCLIParserArgumentsSuite.Create(
    'CLI.Parser: argument arrays'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
