{ LWPT.Formatter.Test — formatter idempotence + nested-declarations
  regression. Covers the bug fixed in a later cycle where the formatter A-prefixed
  parameter names in signatures but failed to propagate the rename
  through bodies of functions containing nested `type record` or
  nested `procedure`/`function` declarations. The fix lives in
  LWPT.Formatter.FindFuncEnd (recursive descent + `record` in the depth-up
  set); this test exercises every shape that broke before. }

program LWPT.Formatter.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  LWPT.Command.Format,
  LWPT.Core,
  LWPT.Formatter,
  TestingPascalLibrary;

type
  TFormatIdempotence = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRunningFormatTwiceIsANoOp;
  end;

  TFormatParamRename = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNestedRecordTypeBodyRefsRenamed;
    procedure TestNestedProcedureBodyRefsRenamed;
    procedure TestNestedFunctionBodyRefsRenamed;
    procedure TestBothNestedShapesAtOnce;
  end;

  { ADR-0007 — exercises the scope-resolution algorithm via the
    exposed ExpandFormatPattern entry point. Sets up a known-shape
    fixture tree once, then each test asserts on a different pattern. }
  TFormatScopeExpansion = class(TTestSuite)
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestPlainDirShorthandIncludesFormattableExts;
    procedure TestTrailingSlashIsEquivalentToPlainDir;
    procedure TestSingleLevelGlobMatchesAtOneLevel;
    procedure TestDoubleStarGlobIsRecursive;
    procedure TestLiteralFilePathIsIncludedDirectly;
    procedure TestMissingLiteralPathRaisesWhenStrict;
    procedure TestMissingLiteralPathIsSilentWhenLenient;
    procedure TestGlobMatchingZeroFilesIsSilent;
    procedure TestHiddenFilesSkipped;
    procedure TestNonFormattableExtensionsFiltered;
  end;

const
  TMP_DIR = 'build/tests/fixtures/format';

{ ───────── helpers ───────── }

function WriteTempPas(const ASuffix, AContent: string): string;
var
  SL: TStringList;
begin
  ForceDirectories(TMP_DIR);
  Result := TMP_DIR + '/' + ASuffix + '.pas';
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;

function ReadFile(const APath: string): string;
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(APath);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function FormatAndRead(const ASuffix, ASource: string): string;
var Path: string;
begin
  Path := WriteTempPas(ASuffix, ASource);
  FormatFile(Path, rmFormat);
  Result := ReadFile(Path);
end;

{ Substring check that the test framework's Expect<T>.ToBe doesn't offer
  natively — for verifying body references contain a specific A-prefixed
  identifier. }
function Contains(const AHaystack, ANeedle: string): Boolean;
begin
  Result := Pos(ANeedle, AHaystack) > 0;
end;

{ ───────── TFormatIdempotence ─────────
  Running `lwpt format` twice on the same file must be a no-op. This is
  what makes `lwpt format --check` correct: a file that passes check
  must equal what `lwpt format` would have produced. }

procedure TFormatIdempotence.TestRunningFormatTwiceIsANoOp;
const
  INPUT =
    'unit Sample;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  SysUtils, Classes;'#10 +
    'procedure DoStuff(Items: array of string);'#10 +
    'implementation'#10 +
    'procedure DoStuff(Items: array of string);'#10 +
    'var I: Integer;'#10 +
    'begin'#10 +
    '  for I := 0 to High(Items) do WriteLn(Items[I]);'#10 +
    'end;'#10 +
    'end.'#10;
var
  Pass1, Pass2: string;
  Path: string;
begin
  Path := WriteTempPas('idempotence', INPUT);

  FormatFile(Path, rmFormat);
  Pass1 := ReadFile(Path);

  FormatFile(Path, rmFormat);
  Pass2 := ReadFile(Path);

  Expect<string>(Pass2).ToBe(Pass1);
end;

procedure TFormatIdempotence.SetupTests;
begin
  Test('running format twice is a no-op', TestRunningFormatTwiceIsANoOp);
end;

{ ───────── TFormatParamRename ─────────
  Each test feeds the formatter a function whose parameters lack the
  A-prefix AND whose body contains a nested declaration of one of the
  shapes that previously broke. We assert that AFTER format:
    1. The signature carries the A-prefix.
    2. The body references the A-prefixed name (not the original).
    3. The resulting source is valid Pascal that compiles cleanly
       enough to round-trip through the formatter again (covered by
       the idempotence test above). }

procedure TFormatParamRename.TestNestedRecordTypeBodyRefsRenamed;
const
  INPUT =
    'unit NestedRec;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure WithRec(Items: array of string);'#10 +
    'type'#10 +
    '  TEntry = record'#10 +
    '    Name: string;'#10 +
    '  end;'#10 +
    'var'#10 +
    '  i: Integer;'#10 +
    'begin'#10 +
    '  for i := 0 to High(Items) do WriteLn(Items[i]);'#10 +
    'end;'#10 +
    'end.'#10;
var Out: string;
begin
  Out := FormatAndRead('nested-record', INPUT);
  { signature renamed }
  Expect<Boolean>(Contains(Out, 'procedure WithRec(AItems: array of string)'))
    .ToBe(True);
  { body refs renamed — the regression: pre-fix, these stayed as `Items` }
  Expect<Boolean>(Contains(Out, 'High(AItems)')).ToBe(True);
  Expect<Boolean>(Contains(Out, 'AItems[i]')).ToBe(True);
  { record field name is NOT a parameter and must stay verbatim }
  Expect<Boolean>(Contains(Out, 'Name: string;')).ToBe(True);
end;

procedure TFormatParamRename.TestNestedProcedureBodyRefsRenamed;
const
  INPUT =
    'unit NestedProc;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure WithProc(Path: string; Verbose: Boolean);'#10 +
    'var Buf: string;'#10 +
    '  procedure Append(Suffix: string);'#10 +
    '  begin'#10 +
    '    Buf := Buf + Suffix;'#10 +
    '  end;'#10 +
    'begin'#10 +
    '  Buf := Path;'#10 +
    '  Append(''.tmp'');'#10 +
    '  if Verbose then WriteLn(Buf);'#10 +
    'end;'#10 +
    'end.'#10;
var Out: string;
begin
  Out := FormatAndRead('nested-proc', INPUT);
  Expect<Boolean>(Contains(Out, 'procedure WithProc(APath: string; AVerbose: Boolean)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Out, 'Buf := APath;')).ToBe(True);
  Expect<Boolean>(Contains(Out, 'if AVerbose then')).ToBe(True);
  { nested procedure's own parameter also renamed }
  Expect<Boolean>(Contains(Out, 'procedure Append(ASuffix: string)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Out, 'Buf := Buf + ASuffix;')).ToBe(True);
end;

procedure TFormatParamRename.TestNestedFunctionBodyRefsRenamed;
const
  INPUT =
    'unit NestedFn;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'function WithFn(Data: array of Byte; Salt: Cardinal): Cardinal;'#10 +
    '  function Rotate(X: Cardinal; N: Byte): Cardinal;'#10 +
    '  begin'#10 +
    '    Result := (X shr N) or (X shl (32 - N));'#10 +
    '  end;'#10 +
    'var i: Integer;'#10 +
    'begin'#10 +
    '  Result := Salt;'#10 +
    '  for i := 0 to High(Data) do Result := Rotate(Result xor Data[i], 7);'#10 +
    'end;'#10 +
    'end.'#10;
var Out: string;
begin
  Out := FormatAndRead('nested-fn', INPUT);
  Expect<Boolean>(Contains(Out, 'function WithFn(AData: array of Byte; ASalt: Cardinal): Cardinal'))
    .ToBe(True);
  Expect<Boolean>(Contains(Out, 'Result := ASalt;')).ToBe(True);
  Expect<Boolean>(Contains(Out, 'High(AData)')).ToBe(True);
  Expect<Boolean>(Contains(Out, 'AData[i]')).ToBe(True);
  { single-letter parameters X, N stay verbatim (the rule excludes them) }
  Expect<Boolean>(Contains(Out, 'function Rotate(X: Cardinal; N: Byte)'))
    .ToBe(True);
end;

procedure TFormatParamRename.TestBothNestedShapesAtOnce;
const
  INPUT =
    'unit BothShapes;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure WithBoth(Items: array of Integer; Total: Cardinal);'#10 +
    'type'#10 +
    '  TBucket = record'#10 +
    '    Sum: Cardinal;'#10 +
    '  end;'#10 +
    'var'#10 +
    '  Bucket: TBucket;'#10 +
    '  procedure Bump(Value: Integer);'#10 +
    '  begin'#10 +
    '    Bucket.Sum := Bucket.Sum + Cardinal(Value);'#10 +
    '  end;'#10 +
    'var i: Integer;'#10 +
    'begin'#10 +
    '  Bucket.Sum := 0;'#10 +
    '  for i := 0 to High(Items) do Bump(Items[i]);'#10 +
    '  WriteLn(Bucket.Sum, Total);'#10 +
    'end;'#10 +
    'end.'#10;
var Out: string;
begin
  Out := FormatAndRead('both-shapes', INPUT);
  Expect<Boolean>(Contains(Out, 'procedure WithBoth(AItems: array of Integer; ATotal: Cardinal)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Out, 'High(AItems)')).ToBe(True);
  Expect<Boolean>(Contains(Out, 'AItems[i]')).ToBe(True);
  Expect<Boolean>(Contains(Out, 'WriteLn(Bucket.Sum, ATotal)')).ToBe(True);
  { nested procedure's param renamed too }
  Expect<Boolean>(Contains(Out, 'procedure Bump(AValue: Integer)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Out, 'Cardinal(AValue)')).ToBe(True);
end;

procedure TFormatParamRename.SetupTests;
begin
  Test('nested record type: body refs renamed',
    TestNestedRecordTypeBodyRefsRenamed);
  Test('nested procedure: body refs renamed (both outer and nested)',
    TestNestedProcedureBodyRefsRenamed);
  Test('nested function: body refs renamed; single-letter params preserved',
    TestNestedFunctionBodyRefsRenamed);
  Test('both shapes at once: nothing leaks across scopes',
    TestBothNestedShapesAtOnce);
end;

{ ───────── TFormatScopeExpansion (ADR-0007) ───────── }

const
  SCOPE_FIXTURE = 'build/tests/fixtures/format-scope';

procedure WriteTextFile(const APath, AContent: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure TFormatScopeExpansion.BeforeAll;
begin
  { Build a known-shape fixture tree once. Each test asserts on a
    different pattern against it. Mtimes don't matter, contents don't
    matter — we only care which paths the resolver returns. }
  WriteTextFile(SCOPE_FIXTURE + '/top.pas',                'unit Top; end.'#10);
  WriteTextFile(SCOPE_FIXTURE + '/top.inc',                '{ inc }'#10);
  WriteTextFile(SCOPE_FIXTURE + '/top.dpr',                'program Top; begin end.'#10);
  WriteTextFile(SCOPE_FIXTURE + '/top.lpr',                'program TopL; begin end.'#10);
  WriteTextFile(SCOPE_FIXTURE + '/not-pascal.txt',         'plain text'#10);
  WriteTextFile(SCOPE_FIXTURE + '/.hidden.pas',            'unit Hidden; end.'#10);
  WriteTextFile(SCOPE_FIXTURE + '/sub/middle.pas',         'unit Middle; end.'#10);
  WriteTextFile(SCOPE_FIXTURE + '/sub/deep/leaf.pas',      'unit Leaf; end.'#10);
end;

function CountSuffix(const AList: TStringList; const ASuffix: string): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to AList.Count - 1 do
    if (Length(AList[i]) >= Length(ASuffix))
       and SameText(Copy(AList[i], Length(AList[i]) - Length(ASuffix) + 1,
                         Length(ASuffix)), ASuffix) then
      Inc(Result);
end;

function ListContainsSuffix(const AList: TStringList; const ASuffix: string): Boolean;
begin
  Result := CountSuffix(AList, ASuffix) > 0;
end;

procedure TFormatScopeExpansion.TestPlainDirShorthandIncludesFormattableExts;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    ExpandFormatPattern(SCOPE_FIXTURE, List, True);
    { Plain dir shorthand → top-level .pas/.inc/.dpr/.lpr only. }
    Expect<Boolean>(ListContainsSuffix(List, 'top.pas')).ToBe(True);
    Expect<Boolean>(ListContainsSuffix(List, 'top.inc')).ToBe(True);
    Expect<Boolean>(ListContainsSuffix(List, 'top.dpr')).ToBe(True);
    Expect<Boolean>(ListContainsSuffix(List, 'top.lpr')).ToBe(True);
    { Non-formattable extension filtered out. }
    Expect<Boolean>(ListContainsSuffix(List, 'not-pascal.txt')).ToBe(False);
    { Hidden file skipped. }
    Expect<Boolean>(ListContainsSuffix(List, '.hidden.pas')).ToBe(False);
    { No recursion by default — sub/ files not reached. }
    Expect<Boolean>(ListContainsSuffix(List, 'middle.pas')).ToBe(False);
    Expect<Boolean>(ListContainsSuffix(List, 'leaf.pas')).ToBe(False);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestTrailingSlashIsEquivalentToPlainDir;
var A, B: TStringList;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    ExpandFormatPattern(SCOPE_FIXTURE,       A, True);
    ExpandFormatPattern(SCOPE_FIXTURE + '/', B, True);
    A.Sort; B.Sort;
    Expect<Integer>(A.Count).ToBe(B.Count);
    Expect<string>(A.Text).ToBe(B.Text);
  finally
    A.Free; B.Free;
  end;
end;

procedure TFormatScopeExpansion.TestSingleLevelGlobMatchesAtOneLevel;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    ExpandFormatPattern(SCOPE_FIXTURE + '/*.pas', List, True);
    Expect<Boolean>(ListContainsSuffix(List, 'top.pas')).ToBe(True);
    { Glob is .pas only — .inc, .dpr, .lpr excluded by the pattern itself. }
    Expect<Boolean>(ListContainsSuffix(List, 'top.inc')).ToBe(False);
    Expect<Boolean>(ListContainsSuffix(List, 'top.dpr')).ToBe(False);
    { No recursion. }
    Expect<Boolean>(ListContainsSuffix(List, 'middle.pas')).ToBe(False);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestDoubleStarGlobIsRecursive;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    ExpandFormatPattern(SCOPE_FIXTURE + '/**/*.pas', List, True);
    Expect<Boolean>(ListContainsSuffix(List, 'top.pas')).ToBe(True);
    Expect<Boolean>(ListContainsSuffix(List, 'middle.pas')).ToBe(True);
    Expect<Boolean>(ListContainsSuffix(List, 'leaf.pas')).ToBe(True);
    { Hidden file still skipped under recursive globs. }
    Expect<Boolean>(ListContainsSuffix(List, '.hidden.pas')).ToBe(False);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestLiteralFilePathIsIncludedDirectly;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    ExpandFormatPattern(SCOPE_FIXTURE + '/sub/middle.pas', List, True);
    Expect<Integer>(List.Count).ToBe(1);
    Expect<Boolean>(ListContainsSuffix(List, 'middle.pas')).ToBe(True);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestMissingLiteralPathRaisesWhenStrict;
var
  List: TStringList;
  Raised: Boolean;
begin
  List := TStringList.Create;
  Raised := False;
  try
    try
      ExpandFormatPattern(SCOPE_FIXTURE + '/does-not-exist.pas', List, True);
    except
      on E: EManifestError do Raised := True;
    end;
  finally
    List.Free;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TFormatScopeExpansion.TestMissingLiteralPathIsSilentWhenLenient;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    { AErrorOnMissingLiteral = False → no exception, empty result. }
    ExpandFormatPattern(SCOPE_FIXTURE + '/does-not-exist.pas', List, False);
    Expect<Integer>(List.Count).ToBe(0);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestGlobMatchingZeroFilesIsSilent;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    { Globs are always silent on zero match, even with strict=True. }
    ExpandFormatPattern(SCOPE_FIXTURE + '/*.xyz', List, True);
    Expect<Integer>(List.Count).ToBe(0);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestHiddenFilesSkipped;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    { Even an explicit *.pas glob doesn't pick up .hidden.pas because
      the recursive walker skips entries with leading dots. Matches
      shell glob convention. }
    ExpandFormatPattern(SCOPE_FIXTURE + '/*.pas', List, True);
    Expect<Boolean>(ListContainsSuffix(List, '.hidden.pas')).ToBe(False);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestNonFormattableExtensionsFiltered;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    { A glob that matches .txt resolves to nothing because the final
      extension filter strips non-formattable files. }
    ExpandFormatPattern(SCOPE_FIXTURE + '/*.txt', List, True);
    Expect<Integer>(List.Count).ToBe(0);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.SetupTests;
begin
  Test('plain dir shorthand: tests → tests/*.{pas,inc,dpr,lpr}, no recursion',
    TestPlainDirShorthandIncludesFormattableExts);
  Test('trailing slash equivalent to plain dir',
    TestTrailingSlashIsEquivalentToPlainDir);
  Test('single-level glob *.pas: only top-level matches',
    TestSingleLevelGlobMatchesAtOneLevel);
  Test('double-star glob **/*.pas: recursive across any depth',
    TestDoubleStarGlobIsRecursive);
  Test('literal file path: included as exactly itself',
    TestLiteralFilePathIsIncludedDirectly);
  Test('missing literal path raises EManifestError when strict',
    TestMissingLiteralPathRaisesWhenStrict);
  Test('missing literal path is silent when lenient',
    TestMissingLiteralPathIsSilentWhenLenient);
  Test('glob matching zero files is silent (even when strict)',
    TestGlobMatchingZeroFilesIsSilent);
  Test('hidden files (leading .) skipped',
    TestHiddenFilesSkipped);
  Test('non-formattable extensions filtered after glob match',
    TestNonFormattableExtensionsFiltered);
end;

begin
  TestRunnerProgram.AddSuite(TFormatIdempotence.Create('LWPT.Formatter: idempotence'));
  TestRunnerProgram.AddSuite(TFormatParamRename.Create('LWPT.Formatter: param-rename regression'));
  TestRunnerProgram.AddSuite(TFormatScopeExpansion.Create('LWPT.Formatter: scope expansion (ADR-0007)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
