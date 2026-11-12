{ CLI.Options.Test — TOptionList, the registry that owns options.

  TOptionList keeps its items in a plain array so that CLI.Options needs no
  Generics.* unit (#419). These cases pin what a host relies on: the Add
  methods append in call order and return the option, Options hands out
  that order without giving the list's storage away, and freeing the list
  frees every option it holds. They run in-process. }

program CLI.Options.Test;

{$I Shared.inc}

uses
  SysUtils,

  CLI.Options,
  TestingPascalLibrary;

type
  { A flag that counts its own destruction, so a case can tell whether the
    list freed it. }
  TCountedFlag = class(TFlagOption)
  public
    destructor Destroy; override;
  end;

  TOptionListSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNewListHasNoOptions;
    procedure TestAddMethodsAppendInCallOrder;
    procedure TestAddReturnsTheGivenOption;
    procedure TestOptionsIsACopy;
    procedure TestManyOptionsKeepTheirOrder;
    procedure TestFreeingTheListFreesEveryOption;
  end;

var
  CountedFlagsFreed: Integer;

destructor TCountedFlag.Destroy;
begin
  Inc(CountedFlagsFreed);
  inherited Destroy;
end;

procedure TOptionListSuite.TestNewListHasNoOptions;
var
  List: TOptionList;
begin
  List := TOptionList.Create;
  try
    Expect<Integer>(Length(List.Options)).ToBe(0);
  finally
    List.Free;
  end;
end;

procedure TOptionListSuite.TestAddMethodsAppendInCallOrder;
var
  List: TOptionList;
  Flag: TFlagOption;
  Output: TStringOption;
  Jobs: TIntegerOption;
  Define: TRepeatableOption;
  Options: TOptionArray;
begin
  List := TOptionList.Create;
  try
    Flag := List.AddFlag('release', 'Optimize', 'build');
    Output := List.AddString('output', 'Output path');
    Jobs := List.AddInteger('jobs', 'Parallel jobs');
    Define := List.AddRepeatable('define', 'Define a symbol');

    Options := List.Options;
    Expect<Integer>(Length(Options)).ToBe(4);
    Expect<Boolean>(Options[0] = Flag).ToBe(True);
    Expect<Boolean>(Options[1] = Output).ToBe(True);
    Expect<Boolean>(Options[2] = Jobs).ToBe(True);
    Expect<Boolean>(Options[3] = Define).ToBe(True);

    Expect<string>(Flag.LongName).ToBe('release');
    Expect<string>(Flag.HelpText).ToBe('Optimize');
    Expect<string>(Flag.Group).ToBe('build');
    Expect<string>(Output.HelpLabel).ToBe('--output=<value>');
    Expect<string>(Jobs.HelpLabel).ToBe('--jobs=<N>');
    Expect<string>(Define.HelpLabel).ToBe('--define <value>');
  finally
    List.Free;
  end;
end;

procedure TOptionListSuite.TestAddReturnsTheGivenOption;
var
  List: TOptionList;
  Given: TInt64Option;
  Options: TOptionArray;
begin
  List := TOptionList.Create;
  try
    List.AddFlag('verbose', 'Say more');
    Given := TInt64Option.Create('limit', 'Byte limit');
    Expect<Boolean>(List.Add(Given) = Given).ToBe(True);

    Options := List.Options;
    Expect<Integer>(Length(Options)).ToBe(2);
    Expect<Boolean>(Options[1] = Given).ToBe(True);
  finally
    List.Free;
  end;
end;

procedure TOptionListSuite.TestOptionsIsACopy;
var
  List: TOptionList;
  Flag: TFlagOption;
  First, Second: TOptionArray;
begin
  List := TOptionList.Create;
  try
    Flag := List.AddFlag('release', 'Optimize');
    First := List.Options;
    First[0] := nil;
    SetLength(First, 0);

    Second := List.Options;
    Expect<Integer>(Length(Second)).ToBe(1);
    Expect<Boolean>(Second[0] = Flag).ToBe(True);

    List.AddFlag('verbose', 'Say more');
    Expect<Integer>(Length(Second)).ToBe(1);
    Expect<Integer>(Length(List.Options)).ToBe(2);
  finally
    List.Free;
  end;
end;

procedure TOptionListSuite.TestManyOptionsKeepTheirOrder;
const
  OPTION_COUNT = 100;
var
  List: TOptionList;
  Options: TOptionArray;
  I: Integer;
begin
  List := TOptionList.Create;
  try
    for I := 0 to OPTION_COUNT - 1 do
      List.AddFlag('flag-' + IntToStr(I), 'Flag ' + IntToStr(I));

    Options := List.Options;
    Expect<Integer>(Length(Options)).ToBe(OPTION_COUNT);
    for I := 0 to OPTION_COUNT - 1 do
      Expect<string>(Options[I].LongName).ToBe('flag-' + IntToStr(I));
  finally
    List.Free;
  end;
end;

procedure TOptionListSuite.TestFreeingTheListFreesEveryOption;
const
  OPTION_COUNT = 9;
var
  List: TOptionList;
  I: Integer;
begin
  CountedFlagsFreed := 0;
  List := TOptionList.Create;
  try
    for I := 1 to OPTION_COUNT do
      List.Add(TCountedFlag.Create('flag-' + IntToStr(I), 'Counted'));
    Expect<Integer>(CountedFlagsFreed).ToBe(0);
  finally
    List.Free;
  end;
  Expect<Integer>(CountedFlagsFreed).ToBe(OPTION_COUNT);
end;

procedure TOptionListSuite.SetupTests;
begin
  Test('a new list has no options', TestNewListHasNoOptions);
  Test('the Add methods append in call order and return the option',
    TestAddMethodsAppendInCallOrder);
  Test('Add takes a given option and returns it',
    TestAddReturnsTheGivenOption);
  Test('Options returns a copy of the list''s order',
    TestOptionsIsACopy);
  Test('many options keep their order', TestManyOptionsKeepTheirOrder);
  Test('freeing the list frees every option it holds',
    TestFreeingTheListFreesEveryOption);
end;

begin
  TestRunnerProgram.AddSuite(TOptionListSuite.Create(
    'CLI.Options: TOptionList'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
