{ TOML.Test — structural resource limits of the TOML parser.

  Registry clients parse untrusted network documents with this parser, and
  LWPT reads dependency manifests fetched from remote archives. A short line
  such as `x = { a.a.a.… = 0 }` or a long run of `[` must fail with a
  typed limit error before parser or destructor recursion can exhaust the
  stack. Ordinary documents stay within the default limits. }

program TOML.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  TOML;

type
  TTOMLLimitTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestOrdinaryDocumentParsesWithDefaults;
    procedure TestDottedInlineKeyDepthFailsBeforeRecursion;
    procedure TestNestedArraysFailWithTypedLimit;
    procedure TestDepthCountsHeadersDottedKeysAndValues;
    procedure TestNodeLimitCountsValuesAndTables;
    procedure TestZeroDisablesLimits;
  end;

function DottedKey(const AComponents: Integer): string;
var
  Index: Integer;
begin
  Result := 'a';
  for Index := 2 to AComponents do Result := Result + '.a';
end;

function ParseOutcome(AParser: TTOMLParser; const AText: string): string;
var
  Root: TTOMLNode;
begin
  Result := 'parsed';
  try
    Root := AParser.ParseDocument(AText);
    Root.Free;
  except
    on E: ETOMLLimitError do Result := 'limit';
    on E: ETOMLParseError do Result := 'parse error: ' + E.Message;
  end;
end;

procedure TTOMLLimitTests.TestOrdinaryDocumentParsesWithDefaults;
var
  Parser: TTOMLParser;
  Root: TTOMLNode;
begin
  Parser := TTOMLParser.Create;
  try
    Expect<Integer>(Parser.MaximumDepth).ToBe(TOMLDefaultMaximumDepth);
    Expect<Integer>(Parser.MaximumNodes).ToBe(0);
    Root := Parser.ParseDocument('[package]' + #10 + 'name = "x"' + #10
      + 'units = ["source", "tests"]' + #10 + '[build.lwpt]' + #10
      + 'target = { os = "linux", architecture = "x86_64" }' + #10);
    try
      Expect<Integer>(Root.Children.Count).ToBe(2);
    finally
      Root.Free;
    end;
  finally
    Parser.Free;
  end;
end;

procedure TTOMLLimitTests.TestDottedInlineKeyDepthFailsBeforeRecursion;
var
  Parser: TTOMLParser;
begin
  Parser := TTOMLParser.Create;
  try
    { 100,000 components in one inline table: 200 KB, bracket depth one. }
    Expect<string>(ParseOutcome(Parser, 'x = { ' + DottedKey(100000)
      + ' = 0 }' + #10)).ToBe('limit');
    Expect<string>(ParseOutcome(Parser, DottedKey(100000) + ' = 0' + #10))
      .ToBe('limit');
    Expect<string>(ParseOutcome(Parser, '[' + DottedKey(100000) + ']' + #10))
      .ToBe('limit');
    { The parser remains reusable after a limit failure. }
    Expect<string>(ParseOutcome(Parser, 'x = 1' + #10)).ToBe('parsed');
  finally
    Parser.Free;
  end;
end;

procedure TTOMLLimitTests.TestNestedArraysFailWithTypedLimit;
var
  Parser: TTOMLParser;
begin
  Parser := TTOMLParser.Create;
  try
    Expect<string>(ParseOutcome(Parser, 'x = ' + StringOfChar('[', 100000)
      + StringOfChar(']', 100000) + #10)).ToBe('limit');
    Expect<string>(ParseOutcome(Parser, 'x = ' + StringOfChar('[', 50000)
      + '{ y = ' + StringOfChar('[', 50000) + #10)).ToBe('limit');
  finally
    Parser.Free;
  end;
end;

procedure TTOMLLimitTests.TestDepthCountsHeadersDottedKeysAndValues;
var
  Parser: TTOMLParser;
begin
  Parser := TTOMLParser.Create;
  try
    Parser.MaximumDepth := 3;
    { Root 0; x 1; array 1 holds table 2 holding scalar 3. }
    Expect<string>(ParseOutcome(Parser, 'x = [{ y = 1 }]' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, 'x = [{ y = [1] }]' + #10)).ToBe('limit');
    Expect<string>(ParseOutcome(Parser, 'x = { y.z = 1 }' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, 'x = { y.z.w = 1 }' + #10)).ToBe('limit');
    Expect<string>(ParseOutcome(Parser, 'a.b.c = 1' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, 'a.b.c.d = 1' + #10)).ToBe('limit');
    Expect<string>(ParseOutcome(Parser, '[a.b]' + #10 + 'c = 1' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, '[a.b]' + #10 + 'c.d = 1' + #10)).ToBe('limit');
    { An array-of-tables item sits one level below its array. }
    Expect<string>(ParseOutcome(Parser, '[[a]]' + #10 + 'b = 1' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, '[[a.b]]' + #10 + 'c = 1' + #10)).ToBe('limit');
  finally
    Parser.Free;
  end;
end;

procedure TTOMLLimitTests.TestNodeLimitCountsValuesAndTables;
var
  Parser: TTOMLParser;
begin
  Parser := TTOMLParser.Create;
  try
    Parser.MaximumNodes := 3;
    { The array value assigned to x and its two items. }
    Expect<string>(ParseOutcome(Parser, 'x = [1, 2]' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, 'x = [1, 2, 3]' + #10)).ToBe('limit');
    Parser.MaximumNodes := 4;
    { Header table, dotted intermediate table, and two values. }
    Expect<string>(ParseOutcome(Parser, '[t]' + #10 + 'a.b = 1' + #10
      + 'c = 2' + #10)).ToBe('parsed');
    Expect<string>(ParseOutcome(Parser, '[t]' + #10 + 'a.b = 1' + #10
      + 'c = 2' + #10 + 'd = 3' + #10)).ToBe('limit');
  finally
    Parser.Free;
  end;
end;

procedure TTOMLLimitTests.TestZeroDisablesLimits;
var
  Parser: TTOMLParser;
begin
  Parser := TTOMLParser.Create;
  try
    Parser.MaximumDepth := 0;
    Expect<string>(ParseOutcome(Parser, 'x = ' + StringOfChar('[', 300)
      + StringOfChar(']', 300) + #10)).ToBe('parsed');
  finally
    Parser.Free;
  end;
end;

procedure TTOMLLimitTests.SetupTests;
begin
  Test('ordinary documents parse within the default limits',
    TestOrdinaryDocumentParsesWithDefaults);
  Test('100,000 dotted key components fail before recursion',
    TestDottedInlineKeyDepthFailsBeforeRecursion);
  Test('deeply nested arrays and inline tables fail with a typed limit',
    TestNestedArraysFailWithTypedLimit);
  Test('depth counts headers, dotted keys, arrays, and inline tables',
    TestDepthCountsHeadersDottedKeysAndValues);
  Test('node limit counts parsed values and created tables',
    TestNodeLimitCountsValuesAndTables);
  Test('zero disables the depth limit', TestZeroDisablesLimits);
end;

begin
  TestRunnerProgram.AddSuite(TTOMLLimitTests.Create('TOML: structural limits'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
