{ CLI.Parser.Test — real-argv coverage for valued short options.

  ParseCommandLine reads ParamStr / ParamCount directly, so each test
  spawns this binary in child mode with the argv shape under test. The
  child registers a representative option table, parses its own argv,
  and checks the resulting option objects and positionals. }

program CLI.Parser.Test;

{$I Shared.inc}

uses
  Classes,
  Process,
  SysUtils,

  CLI.Options,
  CLI.Parser,
  TestingPascalLibrary;

const
  CHILD_MODE = '--child';

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
  end;

function ScenarioFailure(const AMessage: string): Integer;
begin
  WriteLn(ErrOutput, AMessage);
  Result := 1;
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
    ProcessInstance.Options := [poWaitOnExit];
    ProcessInstance.Execute;
    Result := ProcessInstance.ExitCode;
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
end;

begin
  if (ParamCount >= 2) and (ParamStr(1) = CHILD_MODE) then
  begin
    ExitCode := RunParserScenario(ParamStr(2));
    Exit;
  end;

  TestRunnerProgram.AddSuite(TCLIParserSuite.Create(
    'CLI.Parser: valued short options'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
