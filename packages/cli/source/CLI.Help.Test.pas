{ CLI.Help.Test — how help names an option.

  TOptionBase.HelpLabel is the one label every help surface prints for an
  option: command help, GenerateHelpText, and a host's generated command
  reference. FormatHelpLabel is the rule it shares with top-level flag
  help. These cases run in-process: the labels and the generated help are
  plain strings. }

program CLI.Help.Test;

{$I Shared.inc}

uses
  SysUtils,

  CLI.Help,
  CLI.Options,
  TestingPascalLibrary;

type
  THelpLabelSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestFormatHelpLabelAddsAShortNameOnlyWhenGiven;
    procedure TestOptionWithoutShortNameKeepsItsLongForm;
    procedure TestShortNameLeadsTheLongForm;
    procedure TestMultiCharacterShortNameLeadsTheLongForm;
    procedure TestGeneratedHelpListsShortNamesInOneColumn;
  end;

  TTestColor = (tcRed, tcGreen);

procedure THelpLabelSuite.TestFormatHelpLabelAddsAShortNameOnlyWhenGiven;
begin
  { The rule top-level flag help and option help share. }
  Expect<string>(FormatHelpLabel('', '--license')).ToBe('--license');
  Expect<string>(FormatHelpLabel('V', '--version')).ToBe('-V, --version');
end;

procedure THelpLabelSuite.TestOptionWithoutShortNameKeepsItsLongForm;
var
  Flag: TFlagOption;
  Output: TStringOption;
begin
  Flag := TFlagOption.Create('release', 'Optimize');
  Output := TStringOption.Create('output', 'Output path');
  try
    Expect<string>(Flag.HelpLabel).ToBe('--release');
    Expect<string>(Output.HelpLabel).ToBe('--output=<value>');
  finally
    Output.Free;
    Flag.Free;
  end;
end;

procedure THelpLabelSuite.TestShortNameLeadsTheLongForm;
var
  Flag: TFlagOption;
  Output: TStringOption;
  Jobs: TIntegerOption;
  Color: TEnumOption<TTestColor>;
  Hot: TOptionalStringOption;
begin
  Flag := TFlagOption.Create('verbose', 'Talk more');
  Flag.ShortName := 'V';
  Output := TStringOption.Create('output', 'Output path');
  Output.ShortName := 'o';
  Jobs := TIntegerOption.Create('jobs', 'Parallel jobs');
  Jobs.ShortName := 'j';
  Color := TEnumOption<TTestColor>.Create('color', 'Color', '', 2);
  Color.ShortName := 'c';
  Hot := TOptionalStringOption.Create('hot', 'Reload');
  Hot.ShortName := 'H';
  try
    Expect<string>(Flag.HelpLabel).ToBe('-V, --verbose');
    Expect<string>(Output.HelpLabel).ToBe('-o, --output=<value>');
    Expect<string>(Jobs.HelpLabel).ToBe('-j, --jobs=<N>');
    Expect<string>(Color.HelpLabel).ToBe('-c, --color=red|green');
    Expect<string>(Hot.HelpLabel).ToBe('-H, --hot[=<value>]');
    { FormatForHelp keeps its meaning: the long form only. }
    Expect<string>(Output.FormatForHelp).ToBe('--output=<value>');
  finally
    Hot.Free;
    Color.Free;
    Jobs.Free;
    Output.Free;
    Flag.Free;
  end;
end;

procedure THelpLabelSuite.TestMultiCharacterShortNameLeadsTheLongForm;
var
  UnitPath: TRepeatableOption;
begin
  UnitPath := TRepeatableOption.Create('unit-path', 'Unit search path');
  UnitPath.ShortName := 'Fu';
  try
    Expect<string>(UnitPath.HelpLabel).ToBe('-Fu, --unit-path <value>');
  finally
    UnitPath.Free;
  end;
end;

procedure THelpLabelSuite.TestGeneratedHelpListsShortNamesInOneColumn;
var
  Options: TOptionArray;
  Output: TStringOption;
  Text: string;
  I: Integer;
begin
  SetLength(Options, 2);
  Options[0] := TFlagOption.Create('release', 'Optimize');
  Output := TStringOption.Create('output', 'Output path');
  Output.ShortName := 'o';
  Options[1] := Output;
  try
    Text := GenerateHelpText('tool', '[options] <file>', Options);
    Expect<string>(Text).ToBe(
      'Usage: tool [options] <file>' + sLineBreak +
      sLineBreak +
      'Options:' + sLineBreak +
      '  --release             Optimize' + sLineBreak +
      '  -o, --output=<value>  Output path' + sLineBreak);
  finally
    for I := 0 to High(Options) do
      Options[I].Free;
  end;
end;

procedure THelpLabelSuite.SetupTests;
begin
  Test('FormatHelpLabel adds a short name only when one is given',
    TestFormatHelpLabelAddsAShortNameOnlyWhenGiven);
  Test('an option without a short name keeps its long form',
    TestOptionWithoutShortNameKeepsItsLongForm);
  Test('a short name leads the long form of every option kind',
    TestShortNameLeadsTheLongForm);
  Test('a multi-character short name leads the long form',
    TestMultiCharacterShortNameLeadsTheLongForm);
  Test('generated help lists short names with one help column',
    TestGeneratedHelpListsShortNamesInOneColumn);
end;

begin
  TestRunnerProgram.AddSuite(THelpLabelSuite.Create(
    'CLI.Help: option labels in help'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
