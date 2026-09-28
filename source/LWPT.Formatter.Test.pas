{ LWPT.Formatter.Test — formatter idempotence, parameter-rename scope,
  lexical safety and format-scope resolution. The rename and lexical
  fixtures assert exact formatter output, and where they are complete
  programs or units they are compiled with the live FPC before and after
  formatting: the property users rely on is that `lwpt format` never turns
  compiling source into source that does not compile. }

program LWPT.Formatter.Test;

{$mode delphi}{$H+}

uses
  Classes,
  Process,
  SysUtils,

  LWPT.Command.Format,
  LWPT.Core,
  LWPT.Formatter,
  TestingPascalLibrary,
  Tests.Scratch;

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
    procedure TestNestedVariantRecordBodyRefsRenamed;
  end;

  (* A comment between unit names used to desynchronise the uses-clause
     parser. FormatUsesInLines accumulated the clause into one string and
     re-ran StripLineComment over the whole accumulation to find the
     terminating `;`; that helper truncates at the first comment marker,
     so the `;` was never seen and the scan swallowed the rest of the
     file, which `lwpt format` then re-emitted as sorted "unit names".
     --check only ever reported "needs formatting", so the destruction
     landed on the rewrite. A clause carrying a comment is now emitted
     verbatim — the treatment a clause carrying an $IFDEF has always had,
     and the semantics the comments already want: they pin a position. *)
  TFormatUsesComments = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestLineCommentPreservesTheWholeFile;
    procedure TestBlockCommentPreservesTheWholeFile;
    procedure TestParenStarCommentPreservesTheWholeFile;
    procedure TestBlockCommentOpenPastTheTerminatorScan;
    procedure TestCommentAfterTheSemicolonPreservesTheFile;
    procedure TestMarkersInsideStringLiteralsAreNotComments;
    procedure TestDirectiveClauseStaysVerbatim;
    procedure TestCommentedClauseIsIdempotent;
    procedure TestCheckAgreesWithRewrite;
    procedure TestUncommentedClauseIsStillSorted;
  end;

  { Issue #301: prose inside a comment whose line began with `function`
    or `procedure` read as a routine header. Its parenthesised words were
    A-prefixed, and the rename then ran on into the next routine's code.
    Comments, directives and string literals are now never rewritten,
    with comment nesting following the file's own mode. }
  TFormatCommentsAndStrings = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestIssueProbeIsUnchanged;
    procedure TestHeaderShapedProseIsUnchanged;
    procedure TestParenStarContinuationIsUnchanged;
    procedure TestCommentsInsideARealBodyAreNotRenamed;
    procedure TestStringLiteralsAreNotDeclarationsOrRenamed;
    procedure TestRealParameterStillGetsItsPrefix;
    procedure TestNestedBraceCommentsInObjFPCAreUnchanged;
    procedure TestNestedCommentsUnderModeswitchAreUnchanged;
    procedure TestDelphiModeBraceCommentsDoNotNest;
    procedure TestDirectiveTextKeepsRoutineNameSpelling;
    procedure TestUnterminatedCommentLeavesTheFileUntouched;
    procedure TestShebangScriptIsStillFormatted;
    procedure TestStringBrokenAcrossLinesLeavesTheFileUntouched;
    procedure TestCheckFailsForAFileItCannotRead;
    procedure TestCommaInsideAUsesPathStaysInItsEntry;
    procedure TestParenStarProseIsNotAUsesClause;
    procedure TestParenStarProseKeepsItsSpacing;
    procedure TestUnterminatedUsesClauseIsVerbatim;
    procedure TestUsesClauseRunningIntoCodeIsVerbatim;
  end;

  { Which code a parameter rename may touch: the headers of one routine
    and the body those headers own, excluding nested scopes that rebind
    the name, and nothing at all where the binding is not certain. }
  TFormatRoutineScope = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestForwardOnTheNextLineOwnsNoBody;
    procedure TestExternalOnTheNextLineIsLeftAlone;
    procedure TestBeginOnTheHeaderLineOwnsTheBody;
    procedure TestConditionalAlternativeBodiesAreAllRenamed;
    procedure TestNestedRedeclarationKeepsItsOwnBinding;
    procedure TestNestedParameterOfTheSameNameIsRenamedSeparately;
    procedure TestExistingNewNameBlocksTheRename;
    procedure TestNewNameBoundOnlyInAShadowingScopeIsNoCollision;
    procedure TestMemberOfTheNewNameIsNoCollision;
    procedure TestNestedRecordFieldIsNotABinding;
    procedure TestNestedAbsoluteAliasBlocksTheRename;
    procedure TestOwnAbsoluteAliasFollowsTheRename;
    procedure TestInitializerLabelBlocksTheRename;
    procedure TestInitializerLabelWithAGlobalBlocksTheRename;
    procedure TestSwitchAfterAModifierKeepsTheModifier;
    procedure TestEscapedKeywordParametersRenameOnlyIdentifiers;
    procedure TestDirectiveWordParameterIsLeftAlone;
    procedure TestEscapedDirectiveWordWithUnescapedUseIsLeftAlone;
    procedure TestUncertainNestedMentionBlocksTheRename;
    procedure TestNestedRoutineNamedLikeTheParameterBlocksTheRename;
    procedure TestSameNamedRecordFieldIsNotTheParameter;
    procedure TestWithStatementBlocksTheRename;
    procedure TestTypeNamedLikeTheParameterBlocksTheRename;
    procedure TestDeclarationAfterAnAlternativeBodyIsNotOwned;
    procedure TestOverloadsAreRenamedSeparately;
    procedure TestSameNamedNestedRoutinesAreSeparate;
    procedure TestIndependentConditionalDeclarationsAreRenamed;
    procedure TestPlainDirectiveInTheParameterListIsKept;
    procedure TestEscapedParameterIsRenamed;
    procedure TestBodylessHeadersKeepTheirRenameInTheHeader;
    procedure TestMethodDeclarationAndImplementationStayInStep;
    procedure TestInterfaceDeclarationAndImplementationStayInStep;
    procedure TestOmittedImplementationParametersBlockTheRename;
    procedure TestAssemblerRoutinesAreLeftUntouched;
    procedure TestDirectiveInTheParameterListBlocksTheRename;
    procedure TestDifferentlyCasedPrefixKeepsHeadersInStep;
    procedure TestParameterSpelledLikeItsRoutineIsKept;
    procedure TestBodyContinuedInAnIncludeFileBlocksTheRename;
    procedure TestParameterlessOverloadDoesNotBlockTheRename;
    procedure TestConditionalAlternativeHeadersBlockTheRename;
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
    procedure TestExplicitDotSegmentReachesHiddenDir;
    procedure TestExplicitDotFileGlobReachesHiddenDir;
    procedure TestWildcardSegmentsStillSkipHiddenDirs;
  end;

  { Toolkit state is excluded by default even when a [package].units
    entry seeds it — both the fixed .lwpt/ root and any [lwpt]
    modules-dir / archives-dir / tmp-dir / cfg-file override paths that
    sit outside it. An explicit [format].include match overrides that
    default, while [format].exclude remains the final subtraction. Runs
    the full CmdFormat composition in check mode. }
  TLWPTFormatToolkitStateDefault = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    FCaseDistinctFilesSupported: Boolean;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestSeededToolkitStateIsExcludedByDefault;
    procedure TestExplicitIncludeOverridesDefaultExclusion;
    procedure TestExplicitExcludeStillWinsOverInclude;
    procedure TestExplicitIncludeMatchIsCaseSensitive;
    procedure TestOverriddenModulesDirIsExcludedByDefault;
    procedure TestExplicitIncludeOverridesOverriddenModulesDir;
    procedure TestSessionsBaseDoesNotHideSiblingSources;
  end;

{ ───────── helpers ───────── }

var
  ScratchDirectory: string;

(* Every fixture and compiler output of this program lives below one
   invocation-private scratch root, so concurrent runs never format or
   compile each other's files. The path is kept relative to the
   repository root the runner starts in: format-scope globs treat hidden
   segments specially, and an absolute checkout path may contain one. *)
function ScratchRoot: string;
begin
  if ScratchDirectory = '' then
    ScratchDirectory := ExtractRelativePath(
      IncludeTrailingPathDelimiter(GetCurrentDir), CreateScratchRoot('formatter'));
  Result := ScratchDirectory;
end;

function FixtureDirectory: string;
begin
  Result := ScratchRoot + '/format';
end;

function WriteTempPas(const ASuffix, AContent: string): string;
var
  SL: TStringList;
begin
  ForceDirectories(FixtureDirectory);
  Result := FixtureDirectory + '/' + ASuffix + '.pas';
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

{ Source text from lines, in the form ReadFile returns. }
function SourceLines(const ALines: array of string): string;
var
  LineIndex: Integer;
begin
  Result := '';
  for LineIndex := Low(ALines) to High(ALines) do
    Result := Result + ALines[LineIndex] + LineEnding;
end;

var
  CompileCount: Integer;

{ Compiles APath with the live FPC, without linking, into a fresh private
  output directory. ADefine, when given, is passed as -d. The compiler's
  output is printed on failure so a red case shows the diagnostic. }
function CompilesWithFPC(const APath: string; const ADefine: string = ''): Boolean;
var
  OutputDirectory, Output: string;
  ExitStatus: Integer;
begin
  Inc(CompileCount);
  OutputDirectory := ScratchRoot + '/compile/' + IntToStr(CompileCount);
  ForceDirectories(OutputDirectory);
  if ADefine = '' then
    Result := RunCommandInDir(GetCurrentDir, TestCompilerExecutable,
      ['-Cn', '-FU' + OutputDirectory, '-FE' + OutputDirectory, APath],
      Output, ExitStatus) = 0
  else
    Result := RunCommandInDir(GetCurrentDir, TestCompilerExecutable,
      ['-Cn', '-d' + ADefine, '-FU' + OutputDirectory, '-FE' + OutputDirectory, APath],
      Output, ExitStatus) = 0;
  Result := Result and (ExitStatus = 0);
  if not Result then
    WriteLn(Output);
end;

(* The contract every rename-scope fixture pins: the input compiles, the
   formatter produces exactly AExpected, a second run changes nothing, and
   the result still compiles. AName is the program or unit name, which FPC
   requires a unit's file to carry. ADefine selects a conditional branch
   for one more compile of the result. *)
procedure ExpectFormats(const AName, AInput, AExpected: string;
  const ADefine: string = '');
var
  Path, Original, Formatted: string;
begin
  Path := WriteTempPas(AName, AInput);
  Original := ReadFile(Path);
  Expect<Boolean>(CompilesWithFPC(Path)).ToBe(True);
  FormatFile(Path, rmFormat);
  Formatted := ReadFile(Path);
  Expect<string>(Formatted).ToBe(AExpected);
  FormatFile(Path, rmFormat);
  Expect<string>(ReadFile(Path)).ToBe(Formatted);
  { An unchanged file was already proven to compile above. }
  if Formatted <> Original then
    Expect<Boolean>(CompilesWithFPC(Path)).ToBe(True);
  if ADefine <> '' then
    Expect<Boolean>(CompilesWithFPC(Path, ADefine)).ToBe(True);
end;

function DirectoryHasExactEntry(const ADir, AName: string): Boolean;
var
  SearchRec: TSearchRec;
begin
  Result := False;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile,
    SearchRec) <> 0 then Exit;
  try
    repeat
      if SearchRec.Name = AName then Exit(True);
    until FindNext(SearchRec) <> 0;
  finally
    FindClose(SearchRec);
  end;
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
  FirstPass, SecondPass: string;
  Path: string;
begin
  Path := WriteTempPas('idempotence', INPUT);

  FormatFile(Path, rmFormat);
  FirstPass := ReadFile(Path);

  FormatFile(Path, rmFormat);
  SecondPass := ReadFile(Path);

  Expect<string>(SecondPass).ToBe(FirstPass);
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
    3. The formatted unit still compiles with the live FPC. }

function FixtureCompiles(const AName: string): Boolean;
begin
  Result := CompilesWithFPC(FixtureDirectory + '/' + AName + '.pas');
end;

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
var Formatted: string;
begin
  Formatted := FormatAndRead('NestedRec', INPUT);
  { signature renamed }
  Expect<Boolean>(Contains(Formatted, 'procedure WithRec(AItems: array of string)'))
    .ToBe(True);
  { body refs renamed — the regression: pre-fix, these stayed as `Items` }
  Expect<Boolean>(Contains(Formatted, 'High(AItems)')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'AItems[i]')).ToBe(True);
  { record field name is NOT a parameter and must stay verbatim }
  Expect<Boolean>(Contains(Formatted, 'Name: string;')).ToBe(True);
  Expect<Boolean>(FixtureCompiles('NestedRec')).ToBe(True);
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
var Formatted: string;
begin
  Formatted := FormatAndRead('NestedProc', INPUT);
  Expect<Boolean>(Contains(Formatted, 'procedure WithProc(APath: string; AVerbose: Boolean)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'Buf := APath;')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'if AVerbose then')).ToBe(True);
  { nested procedure's own parameter also renamed }
  Expect<Boolean>(Contains(Formatted, 'procedure Append(ASuffix: string)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'Buf := Buf + ASuffix;')).ToBe(True);
  Expect<Boolean>(FixtureCompiles('NestedProc')).ToBe(True);
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
var Formatted: string;
begin
  Formatted := FormatAndRead('NestedFn', INPUT);
  Expect<Boolean>(Contains(Formatted, 'function WithFn(AData: array of Byte; ASalt: Cardinal): Cardinal'))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'Result := ASalt;')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'High(AData)')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'AData[i]')).ToBe(True);
  { single-letter parameters X, N stay verbatim (the rule excludes them) }
  Expect<Boolean>(Contains(Formatted, 'function Rotate(X: Cardinal; N: Byte)'))
    .ToBe(True);
  Expect<Boolean>(FixtureCompiles('NestedFn')).ToBe(True);
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
var Formatted: string;
begin
  Formatted := FormatAndRead('BothShapes', INPUT);
  Expect<Boolean>(Contains(Formatted, 'procedure WithBoth(AItems: array of Integer; ATotal: Cardinal)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'High(AItems)')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'AItems[i]')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'WriteLn(Bucket.Sum, ATotal)')).ToBe(True);
  { nested procedure's param renamed too }
  Expect<Boolean>(Contains(Formatted, 'procedure Bump(AValue: Integer)'))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'Cardinal(AValue)')).ToBe(True);
  Expect<Boolean>(FixtureCompiles('BothShapes')).ToBe(True);
end;

procedure TFormatParamRename.TestNestedVariantRecordBodyRefsRenamed;
const
  { A variant part's `case` shares the record's `end`. Counted as a
    block of its own, it leaves the body unbalanced and the rename
    stops at the header. }
  INPUT =
    'unit NestedVariant;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure Fill(count: Integer);'#10 +
    'type'#10 +
    '  TCell = record'#10 +
    '    case Byte of'#10 +
    '      0: (Whole: LongInt);'#10 +
    '      1: (Parts: array[0..3] of Byte);'#10 +
    '  end;'#10 +
    'var'#10 +
    '  Cell: TCell;'#10 +
    'begin'#10 +
    '  case count of'#10 +
    '    0: Cell.Whole := 0;'#10 +
    '  else'#10 +
    '    Cell.Whole := count;'#10 +
    '  end;'#10 +
    'end;'#10 +
    'end.'#10;
var Formatted: string;
begin
  Formatted := FormatAndRead('NestedVariant', INPUT);
  Expect<Boolean>(Contains(Formatted, 'procedure Fill(ACount: Integer);')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, '  case ACount of')).ToBe(True);
  Expect<Boolean>(Contains(Formatted, '    Cell.Whole := ACount;')).ToBe(True);
  Expect<Boolean>(FixtureCompiles('NestedVariant')).ToBe(True);
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
  Test('nested variant record: body refs renamed',
    TestNestedVariantRecordBodyRefsRenamed);end;

{ ───────── TFormatUsesComments ─────────
  Every fixture below is already in the shape the formatter should
  produce, so "unchanged" is the whole assertion: the clause survives
  byte-for-byte and, crucially, so does everything after it. }

const
  { The downstream shape that triggered the corruption (Knips, lwpt
    0.7.0): the comment documents why the unit may not be sorted. }
  USES_LINE_COMMENT =
    'unit LineComment;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  cmem,'#10 +
    '  // must stay second: pthread-backed locks before anything spawns'#10 +
    '  Knips.ThreadManager,'#10 +
    '  SysUtils;'#10 +
    'procedure DoStuff;'#10 +
    'implementation'#10 +
    'procedure DoStuff;'#10 +
    'begin'#10 +
    '  WriteLn(''hello'');'#10 +
    'end;'#10 +
    'end.'#10;

  USES_BLOCK_COMMENT =
    'unit BlockComment;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  cmem,'#10 +
    '  { must stay second: pthread-backed locks before anything spawns }'#10 +
    '  Knips.ThreadManager,'#10 +
    '  SysUtils;'#10 +
    'implementation'#10 +
    'end.'#10;

  USES_PAREN_STAR_COMMENT =
    'unit ParenStarComment;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  cmem,'#10 +
    { No brace anywhere in the body: the (* *) branch of the detector is
      the only thing that can divert this clause. }
    '  (* must stay second: pthread-backed locks before anything spawns *)'#10 +
    '  Knips.ThreadManager,'#10 +
    '  SysUtils;'#10 +
    'implementation'#10 +
    'end.'#10;

  { The comment sits after the terminating `;`. Pre-fix the clause
    parser folded it into the last unit name and appended a second
    semicolon behind it. }
  USES_TRAILING_COMMENT =
    'unit TrailingComment;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  cmem,'#10 +
    '  SysUtils; // pinned order, do not sort'#10 +
    'implementation'#10 +
    'end.'#10;

  { The pre-existing passthrough this fix generalises. }
  USES_DIRECTIVE =
    'unit Directive;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  SysUtils,'#10 +
    '{$IFDEF UNIX}'#10 +
    '  BaseUnix,'#10 +
    '{$ENDIF}'#10 +
    '  Classes;'#10 +
    'implementation'#10 +
    'end.'#10;

  USES_UNCOMMENTED =
    'unit Uncommented;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  SysUtils, Classes;'#10 +
    'implementation'#10 +
    'end.'#10;

  { Comment markers that live inside a `Unit in 'path'` string literal
    are not comments. The detector scans string-aware precisely so this
    clause stays sortable; drop that and the clause diverts to the
    verbatim path and is never grouped. }
  USES_MARKERS_IN_STRING =
    'unit MarkersInString;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  SysUtils, Classes,'#10 +
    '  Braced in ''gen/a{0}.pas'','#10 +
    '  Slashed in ''gen//legacy.pas'';'#10 +
    'implementation'#10 +
    'end.'#10;

  (* A brace comment that stays open past the line the terminator scan
     stops on. The scan cuts `cmem, { note` at the brace, sees no `;`,
     and stops one line later on `…needs it;` — which is still inside
     the comment. Everything after that is reached by the outer loop,
     so the passthrough has to hand it a correct block state: without
     the fold, InBlock reads False and the prose line below is parsed
     as a second uses clause and rewritten. *)
  USES_OPEN_BLOCK_COMMENT =
    'unit OpenBlockComment;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'uses'#10 +
    '  cmem, { keep cmem first: it must replace the memory manager'#10 +
    '    before any other unit allocates, and the RTL needs it;'#10 +
    '    uses C, D; would be a different clause entirely'#10 +
    '    end of note }'#10 +
    '  Knips.ThreadManager,'#10 +
    '  SysUtils;'#10 +
    'implementation'#10 +
    'end.'#10;

{ Formats APath in place and reports whether the bytes survived. }
function FormatLeavesFileUnchanged(const ASuffix, ASource: string;
  out AAfter: string): Boolean;
var
  Path, Before: string;
begin
  Path   := WriteTempPas(ASuffix, ASource);
  Before := ReadFile(Path);
  FormatFile(Path, rmFormat);
  AAfter := ReadFile(Path);
  Result := AAfter = Before;
end;

procedure TFormatUsesComments.TestLineCommentPreservesTheWholeFile;
var Formatted: string;
begin
  Expect<Boolean>(FormatLeavesFileUnchanged('uses-line-comment',
    USES_LINE_COMMENT, Formatted)).ToBe(True);

  { The regression signature: pre-fix everything from `procedure DoStuff`
    to `end.` was folded into the clause and re-emitted as one line
    terminated by `end.;`. }
  Expect<Boolean>(Contains(Formatted, 'end.;')).ToBe(False);
  Expect<Boolean>(Contains(Formatted, 'implementation' + LineEnding)).ToBe(True);
  Expect<Boolean>(Contains(Formatted, LineEnding + 'end.')).ToBe(True);

  { The comment still precedes the unit it pins, in the authored order. }
  Expect<Boolean>(Contains(Formatted,
    '  cmem,' + LineEnding +
    '  // must stay second: pthread-backed locks before anything spawns' +
    LineEnding + '  Knips.ThreadManager,')).ToBe(True);
end;

procedure TFormatUsesComments.TestBlockCommentPreservesTheWholeFile;
var Formatted: string;
begin
  Expect<Boolean>(FormatLeavesFileUnchanged('uses-block-comment',
    USES_BLOCK_COMMENT, Formatted)).ToBe(True);
  Expect<Boolean>(Contains(Formatted, 'end.,')).ToBe(False);
  Expect<Boolean>(Contains(Formatted,
    '  cmem,' + LineEnding +
    '  { must stay second: pthread-backed locks before anything spawns }' +
    LineEnding + '  Knips.ThreadManager,')).ToBe(True);
end;

procedure TFormatUsesComments.TestParenStarCommentPreservesTheWholeFile;
var Formatted: string;
begin
  Expect<Boolean>(FormatLeavesFileUnchanged('uses-paren-star-comment',
    USES_PAREN_STAR_COMMENT, Formatted)).ToBe(True);
  Expect<Boolean>(Contains(Formatted, LineEnding + 'end.')).ToBe(True);
end;

procedure TFormatUsesComments.TestCommentAfterTheSemicolonPreservesTheFile;
var Formatted: string;
begin
  Expect<Boolean>(FormatLeavesFileUnchanged('uses-trailing-comment',
    USES_TRAILING_COMMENT, Formatted)).ToBe(True);
  { Pre-fix: `SysUtils; // pinned order, do not sort;` — a second
    semicolon glued behind the comment. }
  Expect<Boolean>(Contains(Formatted, 'do not sort;')).ToBe(False);
end;

procedure TFormatUsesComments.TestDirectiveClauseStaysVerbatim;
var Formatted: string;
begin
  Expect<Boolean>(FormatLeavesFileUnchanged('uses-directive',
    USES_DIRECTIVE, Formatted)).ToBe(True);
  { Unsorted on purpose: SysUtils still precedes Classes because the
    clause was never reordered. }
  Expect<Boolean>(Contains(Formatted,
    '  SysUtils,' + LineEnding + '{$IFDEF UNIX}')).ToBe(True);
end;

procedure TFormatUsesComments.TestCommentedClauseIsIdempotent;
var
  Path, FirstPass, SecondPass: string;
begin
  Path := WriteTempPas('uses-comment-idempotence', USES_LINE_COMMENT);

  FormatFile(Path, rmFormat);
  FirstPass := ReadFile(Path);
  FormatFile(Path, rmFormat);
  SecondPass := ReadFile(Path);

  Expect<string>(SecondPass).ToBe(FirstPass);
end;

procedure TFormatUsesComments.TestCheckAgreesWithRewrite;
var Path: string;
begin
  { The correctness contract behind --check: it must not claim a change
    the rewrite would not make. Pre-fix, check reported True ("needs
    formatting") and the rewrite it stood for destroyed the file. }
  Path := WriteTempPas('uses-comment-check', USES_LINE_COMMENT);
  Expect<Boolean>(FormatFile(Path, rmCheck)).ToBe(False);
  Expect<Boolean>(FormatFile(Path, rmFormat)).ToBe(False);
end;

procedure TFormatUsesComments.TestUncommentedClauseIsStillSorted;
var Formatted: string;
begin
  { The passthrough must stay scoped to commented clauses — an ordinary
    clause is still regrouped and alphabetised. }
  Formatted := FormatAndRead('uses-uncommented', USES_UNCOMMENTED);
  Expect<Boolean>(Contains(Formatted,
    'uses' + LineEnding + '  Classes,' + LineEnding + '  SysUtils;'))
    .ToBe(True);
end;

procedure TFormatUsesComments.TestMarkersInsideStringLiteralsAreNotComments;
var Formatted: string;
begin
  Formatted := FormatAndRead('uses-markers-in-string', USES_MARKERS_IN_STRING);

  { Grouped and alphabetised — proof the clause was NOT diverted to the
    verbatim path by the `{` and `//` inside the two path literals. }
  Expect<Boolean>(Contains(Formatted,
    'uses' + LineEnding + '  Classes,' + LineEnding + '  SysUtils,'))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted,
    '  Braced in ''gen/a{0}.pas'',' + LineEnding +
    '  Slashed in ''gen//legacy.pas'';')).ToBe(True);
end;

procedure TFormatUsesComments.TestBlockCommentOpenPastTheTerminatorScan;
var Formatted: string;
begin
  Expect<Boolean>(FormatLeavesFileUnchanged('uses-open-block-comment',
    USES_OPEN_BLOCK_COMMENT, Formatted)).ToBe(True);

  { The decoy prose sits beyond the line the terminator scan stopped on.
    Without the block-state fold it is parsed as a uses clause and
    rewritten to one unit per line. }
  Expect<Boolean>(Contains(Formatted,
    '    uses C, D; would be a different clause entirely' + LineEnding))
    .ToBe(True);
  Expect<Boolean>(Contains(Formatted,
    'uses' + LineEnding + '  C,')).ToBe(False);
end;

procedure TFormatUsesComments.SetupTests;
begin
  Test('// comment inside uses: file survives, comment stays put',
    TestLineCommentPreservesTheWholeFile);
  Test('{ } comment inside uses: file survives, comment stays put',
    TestBlockCommentPreservesTheWholeFile);
  Test('(* *) comment inside uses: file survives',
    TestParenStarCommentPreservesTheWholeFile);
  Test('brace comment open past the terminator scan: prose after it is '
    + 'not parsed as a clause', TestBlockCommentOpenPastTheTerminatorScan);
  Test('comment after the clause semicolon: no stray semicolon appended',
    TestCommentAfterTheSemicolonPreservesTheFile);
  Test('comment markers inside path literals do not divert the clause',
    TestMarkersInsideStringLiteralsAreNotComments);
  Test('directive clause keeps its established verbatim treatment',
    TestDirectiveClauseStaysVerbatim);
  Test('commented clause: formatting twice equals formatting once',
    TestCommentedClauseIsIdempotent);
  Test('--check agrees with the rewrite on a commented clause',
    TestCheckAgreesWithRewrite);
  Test('uncommented clause is still grouped and alphabetised',
    TestUncommentedClauseIsStillSorted);
end;

{ ───────── TFormatCommentsAndStrings ───────── }

const
  { The reproduction from issue #301, verbatim. }
  PROBE_BRACE_COMMENT =
    'program Probe;'#10 +
    #10 +
    '{ Counts down. The loop runs until this'#10 +
    '  procedure reaches (count) zero. }'#10 +
    'procedure Countdown;'#10 +
    'var'#10 +
    '  count: Integer;'#10 +
    'begin'#10 +
    '  count := 3;'#10 +
    '  while count > 0 do'#10 +
    '    Dec(count);'#10 +
    '  WriteLn(count);'#10 +
    'end;'#10 +
    #10 +
    'begin'#10 +
    '  Countdown;'#10 +
    'end.'#10;

  PROBE_PAREN_STAR_COMMENT =
    'program ProbeParenStar;'#10 +
    #10 +
    '(* Counts down. The loop runs until this'#10 +
    '  procedure reaches (count) zero.'#10 +
    '  function returns (count, total) as well. *)'#10 +
    'procedure Countdown;'#10 +
    'var'#10 +
    '  count, total: Integer;'#10 +
    'begin'#10 +
    '  count := 3;'#10 +
    '  total := count;'#10 +
    '  WriteLn(count, total);'#10 +
    'end;'#10 +
    #10 +
    'begin'#10 +
    '  Countdown;'#10 +
    'end.'#10;

  { The frostney/wasmlight#142 comment, which each format run garbled
    into `(AA parameter only read, ASuch as a loop bound)`. }
  HEADER_SHAPED_PROSE =
    'unit HeaderShapedProse;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    '{ Mark each static fixed host whose slot AWritten says no instruction of the'#10 +
    '  function writes (a parameter only read, such as a loop bound) as Stable. }'#10 +
    'procedure MarkStable(const AWritten: array of Boolean);'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10;

{ The input in the form the formatter writes it back. }
function Normalized(const ASource: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := ASource;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure ExpectUnchanged(const AName, AInput: string);
begin
  ExpectFormats(AName, AInput, Normalized(AInput));
end;

procedure TFormatCommentsAndStrings.TestIssueProbeIsUnchanged;
var
  Path: string;
begin
  ExpectUnchanged('Probe', PROBE_BRACE_COMMENT);
  Path := WriteTempPas('Probe', PROBE_BRACE_COMMENT);
  Expect<Boolean>(FormatFile(Path, rmCheck)).ToBe(False);
end;

procedure TFormatCommentsAndStrings.TestHeaderShapedProseIsUnchanged;
begin
  ExpectUnchanged('HeaderShapedProse', HEADER_SHAPED_PROSE);
end;

procedure TFormatCommentsAndStrings.TestParenStarContinuationIsUnchanged;
begin
  ExpectUnchanged('ProbeParenStar', PROBE_PAREN_STAR_COMMENT);
end;

procedure TFormatCommentsAndStrings.TestCommentsInsideARealBodyAreNotRenamed;
begin
  ExpectFormats('BodyComments', SourceLines([
    'unit BodyComments;',
    '{$mode delphi}{$H+}',
    'interface',
    'implementation',
    'procedure Drain(count: Integer);',
    'begin',
    '  // count reaches zero here',
    '  (* count is never negative *)',
    '  { count is a value parameter }',
    '  while count > 0 do',
    '    Dec(count); // stop at count = 0',
    'end;',
    'end.']), SourceLines([
    'unit BodyComments;',
    '{$mode delphi}{$H+}',
    'interface',
    'implementation',
    'procedure Drain(ACount: Integer);',
    'begin',
    '  // count reaches zero here',
    '  (* count is never negative *)',
    '  { count is a value parameter }',
    '  while ACount > 0 do',
    '    Dec(ACount); // stop at count = 0',
    'end;',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestStringLiteralsAreNotDeclarationsOrRenamed;
begin
  ExpectFormats('StringLiterals', SourceLines([
    'unit StringLiterals;',
    '{$mode delphi}{$H+}',
    'interface',
    'implementation',
    'procedure Describe(count: Integer);',
    'begin',
    '  WriteLn(''function (x) is not a declaration'', count);',
    '  WriteLn(',
    '    ''procedure (count, total) neither'');',
    'end;',
    'procedure Tally;',
    'var',
    '  total: Integer;',
    'begin',
    '  total := 0;',
    '  WriteLn(total);',
    'end;',
    'end.']), SourceLines([
    'unit StringLiterals;',
    '{$mode delphi}{$H+}',
    'interface',
    'implementation',
    'procedure Describe(ACount: Integer);',
    'begin',
    '  WriteLn(''function (x) is not a declaration'', ACount);',
    '  WriteLn(',
    '    ''procedure (count, total) neither'');',
    'end;',
    'procedure Tally;',
    'var',
    '  total: Integer;',
    'begin',
    '  total := 0;',
    '  WriteLn(total);',
    'end;',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestRealParameterStillGetsItsPrefix;
begin
  ExpectFormats('RealParameter', SourceLines([
    'program RealParameter;',
    '',
    '{ Counts down. The loop runs until this',
    '  procedure reaches (count) zero. }',
    'procedure Countdown(count: Integer);',
    'begin',
    '  while count > 0 do',
    '    Dec(count);',
    'end;',
    '',
    'begin',
    '  Countdown(3);',
    'end.']), SourceLines([
    'program RealParameter;',
    '',
    '{ Counts down. The loop runs until this',
    '  procedure reaches (count) zero. }',
    'procedure Countdown(ACount: Integer);',
    'begin',
    '  while ACount > 0 do',
    '    Dec(ACount);',
    'end;',
    '',
    'begin',
    '  Countdown(3);',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestNestedBraceCommentsInObjFPCAreUnchanged;
begin
  (* ObjFPC nests brace comments: the first `}` closes only the inner one. *)
  ExpectUnchanged('NestedBraceObjFPC', SourceLines([
    'program NestedBraceObjFPC;',
    '{$mode objfpc}',
    '',
    '{ Outer comment.',
    '  { Nested comment. }',
    '  procedure reaches (count) zero. }',
    'procedure Countdown;',
    'var',
    '  count: Integer;',
    'begin',
    '  count := 3;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Countdown;',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestNestedCommentsUnderModeswitchAreUnchanged;
begin
  { Delphi mode with the nestedcomments switch nests both forms. }
  ExpectUnchanged('NestedModeswitch', SourceLines([
    'program NestedModeswitch;',
    '{$mode delphi}{$modeswitch nestedcomments+}',
    '',
    '{ Outer.',
    '  { Nested. }',
    '  procedure reaches (count) zero. }',
    '(* Outer.',
    '  (* Nested. *)',
    '  function returns (count) too. *)',
    'procedure Countdown;',
    'var',
    '  count: Integer;',
    'begin',
    '  count := 3;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Countdown;',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestDelphiModeBraceCommentsDoNotNest;
begin
  (* Positive control for mode awareness: in Delphi mode the first `}`
     closes the comment, so the header after it is code and is fixed. *)
  ExpectFormats('DelphiComments', SourceLines([
    'program DelphiComments;',
    '{$mode delphi}',
    '',
    '{ A brace comment { does not nest here }',
    'procedure Show(count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']), SourceLines([
    'program DelphiComments;',
    '{$mode delphi}',
    '',
    '{ A brace comment { does not nest here }',
    'procedure Show(ACount: Integer);',
    'begin',
    '  WriteLn(ACount);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestDirectiveTextKeepsRoutineNameSpelling;
begin
  { The function-name fix recases code references, never directive text. }
  ExpectFormats('DirectiveText', SourceLines([
    'program DirectiveText;',
    '{$mode objfpc}',
    '',
    'procedure tidy;',
    'begin',
    'end;',
    '',
    'begin',
    '  {$IFDEF tidy}{$ENDIF}',
    '  tidy;',
    'end.']), SourceLines([
    'program DirectiveText;',
    '{$mode objfpc}',
    '',
    'procedure Tidy;',
    'begin',
    'end;',
    '',
    'begin',
    '  {$IFDEF tidy}{$ENDIF}',
    '  Tidy;',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestUnterminatedCommentLeavesTheFileUntouched;
var
  Path, Before, SkipReason: string;
begin
  Path := WriteTempPas('Unterminated', SourceLines([
    'program Unterminated;',
    'procedure Show(count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    '{ never closed',
    'begin',
    'end.']));
  Before := ReadFile(Path);
  Expect<Boolean>(FormatFile(Path, rmFormat, SkipReason)).ToBe(False);
  Expect<string>(ReadFile(Path)).ToBe(Before);
  Expect<Boolean>(Contains(SkipReason, 'Unterminated.pas(6,1): unterminated comment'))
    .ToBe(True);
end;

procedure TFormatCommentsAndStrings.TestStringBrokenAcrossLinesLeavesTheFileUntouched;
var
  Path, Before, SkipReason: string;
begin
  { Review D-7: FPC ends a string at its line ("String exceeds line"). A
    quote on the next line used to close it, and the routine above was
    formatted anyway. }
  Path := WriteTempPas('BrokenString', SourceLines([
    'program BrokenString;',
    'procedure Show(count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    'const',
    '  Broken = ''no closing quote',
    ''';',
    'begin',
    'end.']));
  Before := ReadFile(Path);
  Expect<Boolean>(FormatFile(Path, rmFormat, SkipReason)).ToBe(False);
  Expect<string>(ReadFile(Path)).ToBe(Before);
  Expect<Boolean>(Contains(SkipReason, 'BrokenString.pas(7,12): unterminated string literal'))
    .ToBe(True);
end;

(* Review D-9: `format --check` exits non-zero for a file it could not
   read, instead of reporting every file correctly formatted. *)
procedure TFormatCommentsAndStrings.TestCheckFailsForAFileItCannotRead;
var
  Project, OriginalDirectory: string;
  CheckResult: Integer;
begin
  Project := ExpandFileName(ScratchRoot + '/unreadable-project');
  WriteTextFile(Project + '/lwpt.toml',
    '[package]'#10'name = "unreadable"'#10'version = "0.0.0"'#10'units = ["src"]'#10);
  WriteTextFile(Project + '/src/Good.pas', 'program Good;'#10'begin'#10'end.'#10);
  WriteTextFile(Project + '/src/Broken.pas',
    'program Broken;'#10'{ never closed'#10'begin'#10'end.'#10);
  OriginalDirectory := GetCurrentDir;
  SetCurrentDir(Project);
  try
    CheckResult := CmdFormat('lwpt.toml', True);
  finally
    SetCurrentDir(OriginalDirectory);
  end;
  Expect<Integer>(CheckResult).ToBe(1);

  DeleteFile(Project + '/src/Broken.pas');
  SetCurrentDir(Project);
  try
    CheckResult := CmdFormat('lwpt.toml', True);
  finally
    SetCurrentDir(OriginalDirectory);
  end;
  Expect<Integer>(CheckResult).ToBe(0);
end;

procedure TFormatCommentsAndStrings.TestCommaInsideAUsesPathStaysInItsEntry;
var
  UnitPath: string;
begin
  { Entries split at comma tokens; the comma in the path string used to
    split the entry in two. FPC resolves the path from the working
    directory. }
  UnitPath := FixtureDirectory + '/a,b/CommaUnit.pas';
  WriteTextFile(UnitPath, 'unit CommaUnit;'#10'interface'#10'implementation'#10'end.'#10);
  ExpectFormats('CommaPath', SourceLines([
    'program CommaPath;',
    'uses',
    '  SysUtils, CommaUnit in ''' + UnitPath + ''', Classes;',
    'begin',
    'end.']), SourceLines([
    'program CommaPath;',
    'uses',
    '  Classes,',
    '  SysUtils,',
    '',
    '  CommaUnit in ''' + UnitPath + ''';',
    'begin',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestShebangScriptIsStillFormatted;
var
  Path, Formatted: string;
begin
  { InstantFPC strips a script's `#!` line before compiling; the formatter
    skips it too. Plain fpc rejects the line, so this fixture is not
    compiled. }
  Path := WriteTempPas('ShebangScript', SourceLines([
    '#!/usr/bin/env instantfpc',
    'program ShebangScript;',
    'procedure Show(count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    'begin',
    '  Show(1);',
    'end.']));
  FormatFile(Path, rmFormat);
  Formatted := ReadFile(Path);
  FormatFile(Path, rmFormat);
  Expect<string>(ReadFile(Path)).ToBe(Formatted);
  Expect<string>(Formatted).ToBe(SourceLines([
    '#!/usr/bin/env instantfpc',
    'program ShebangScript;',
    'procedure Show(ACount: Integer);',
    'begin',
    '  WriteLn(ACount);',
    'end;',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestParenStarProseIsNotAUsesClause;
begin
  ExpectUnchanged('ParenStarUses', SourceLines([
    'unit ParenStarUses;',
    '{$mode delphi}{$H+}',
    'interface',
    '(* Callers pick their own order:',
    '  uses C, B; would be a clause if this were code. *)',
    'implementation',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestParenStarProseKeepsItsSpacing;
begin
  ExpectFormats('ParenStarSpacing', SourceLines([
    'unit ParenStarSpacing;',
    '{$mode delphi}{$H+}',
    'interface',
    'implementation',
    '(* Spacing is prose here : keep ( as is ) , please ; *)',
    'procedure Tidy;',
    'begin',
    '  WriteLn(''a'' , ''b'' ) ;',
    'end;',
    'end.']), SourceLines([
    'unit ParenStarSpacing;',
    '{$mode delphi}{$H+}',
    'interface',
    'implementation',
    '(* Spacing is prose here : keep ( as is ) , please ; *)',
    'procedure Tidy;',
    'begin',
    '  WriteLn(''a'', ''b'');',
    'end;',
    'end.']));
end;

procedure TFormatCommentsAndStrings.TestUnterminatedUsesClauseIsVerbatim;
var
  Formatted: string;
begin
  { No semicolon closes the clause before the end of the file. It used to
    be collapsed into one line with everything after it. }
  Expect<Boolean>(FormatLeavesFileUnchanged('UnterminatedUses', SourceLines([
    'unit UnterminatedUses;',
    'interface',
    'uses',
    '  SysUtils',
    'implementation',
    'end.']), Formatted)).ToBe(True);
end;

procedure TFormatCommentsAndStrings.TestUsesClauseRunningIntoCodeIsVerbatim;
var
  Formatted: string;
begin
  { The first semicolon after `uses` belongs to a later declaration. }
  Expect<Boolean>(FormatLeavesFileUnchanged('UsesIntoCode', SourceLines([
    'unit UsesIntoCode;',
    'interface',
    'uses',
    '  SysUtils',
    'implementation',
    'procedure Touch;',
    'begin',
    'end;',
    'end.']), Formatted)).ToBe(True);
end;

procedure TFormatCommentsAndStrings.SetupTests;
begin
  Test('issue #301 probe: comment and the next routine''s locals unchanged',
    TestIssueProbeIsUnchanged);
  Test('header-shaped prose in a brace comment is unchanged',
    TestHeaderShapedProseIsUnchanged);
  Test('header-shaped prose in a (* *) comment is unchanged',
    TestParenStarContinuationIsUnchanged);
  Test('comments inside a real routine body keep the parameter name',
    TestCommentsInsideARealBodyAreNotRenamed);
  Test('string literals are neither headers nor rename targets',
    TestStringLiteralsAreNotDeclarationsOrRenamed);
  Test('a real parameter after a header-shaped comment is still prefixed',
    TestRealParameterStillGetsItsPrefix);
  Test('nested brace comments in objfpc mode are unchanged',
    TestNestedBraceCommentsInObjFPCAreUnchanged);
  Test('nested comments under {$modeswitch nestedcomments+} are unchanged',
    TestNestedCommentsUnderModeswitchAreUnchanged);
  Test('delphi-mode brace comments close at the first brace',
    TestDelphiModeBraceCommentsDoNotNest);
  Test('directive text keeps a routine name''s spelling',
    TestDirectiveTextKeepsRoutineNameSpelling);
  Test('an unterminated comment leaves the file untouched and says why',
    TestUnterminatedCommentLeavesTheFileUntouched);
  Test('an InstantFPC script''s #! line does not stop formatting',
    TestShebangScriptIsStillFormatted);
  Test('a string broken across lines leaves the file untouched',
    TestStringBrokenAcrossLinesLeavesTheFileUntouched);
  Test('format --check fails for a file it cannot read',
    TestCheckFailsForAFileItCannotRead);
  Test('a comma inside a uses path stays in its entry',
    TestCommaInsideAUsesPathStaysInItsEntry);
  Test('(* *) prose beginning with uses is not parsed as a clause',
    TestParenStarProseIsNotAUsesClause);
  Test('(* *) prose keeps its spacing',
    TestParenStarProseKeepsItsSpacing);
  Test('an unterminated uses clause is kept verbatim',
    TestUnterminatedUsesClauseIsVerbatim);
  Test('a uses clause that runs into code is kept verbatim',
    TestUsesClauseRunningIntoCodeIsVerbatim);
end;

{ ───────── TFormatRoutineScope ───────── }

procedure TFormatRoutineScope.TestForwardOnTheNextLineOwnsNoBody;
begin
  ExpectFormats('ForwardNextLine', SourceLines([
    'program ForwardNextLine;',
    '{$mode objfpc}',
    '',
    'procedure Report(total: Integer);',
    '  forward;',
    '',
    'procedure Other;',
    'begin',
    '  Report(2);',
    'end;',
    '',
    'procedure Report(total: Integer);',
    'begin',
    '  WriteLn(total);',
    'end;',
    '',
    'var',
    '  total: Integer;',
    'begin',
    '  total := 1;',
    '  Report(total);',
    '  Other;',
    'end.']), SourceLines([
    'program ForwardNextLine;',
    '{$mode objfpc}',
    '',
    'procedure Report(ATotal: Integer);',
    '  forward;',
    '',
    'procedure Other;',
    'begin',
    '  Report(2);',
    'end;',
    '',
    'procedure Report(ATotal: Integer);',
    'begin',
    '  WriteLn(ATotal);',
    'end;',
    '',
    'var',
    '  total: Integer;',
    'begin',
    '  total := 1;',
    '  Report(total);',
    '  Other;',
    'end.']));
end;

procedure TFormatRoutineScope.TestExternalOnTheNextLineIsLeftAlone;
begin
  { External parameter naming is out of scope; the rename must not leak
    into the program either. }
  ExpectUnchanged('ExternalNextLine', SourceLines([
    'program ExternalNextLine;',
    '{$mode objfpc}',
    '',
    'function Puts(text: PChar): LongInt; cdecl;',
    '  external ''c'' name ''puts'';',
    '',
    'var',
    '  text: PChar;',
    'begin',
    '  text := ''hello'';',
    '  Puts(text);',
    'end.']));
end;

procedure TFormatRoutineScope.TestBeginOnTheHeaderLineOwnsTheBody;
begin
  ExpectFormats('SameLineBegin', SourceLines([
    'program SameLineBegin;',
    '{$mode objfpc}',
    '',
    'procedure PrintValue(value: Integer); begin',
    '  WriteLn(value);',
    'end;',
    '',
    'begin',
    '  PrintValue(1);',
    'end.']), SourceLines([
    'program SameLineBegin;',
    '{$mode objfpc}',
    '',
    'procedure PrintValue(AValue: Integer); begin',
    '  WriteLn(AValue);',
    'end;',
    '',
    'begin',
    '  PrintValue(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestConditionalAlternativeBodiesAreAllRenamed;
begin
  { Both configurations must still compile after formatting. }
  ExpectFormats('ConditionalBodies', SourceLines([
    'program ConditionalBodies;',
    '{$mode objfpc}',
    '',
    'procedure Show(count: Integer);',
    '{$IFDEF FORMAT_PROBE_ALTERNATIVE}',
    'begin',
    '  WriteLn(''alternative '', count);',
    'end;',
    '{$ELSE}',
    'begin',
    '  WriteLn(''default '', count);',
    'end;',
    '{$ENDIF}',
    '',
    'begin',
    '  Show(1);',
    'end.']), SourceLines([
    'program ConditionalBodies;',
    '{$mode objfpc}',
    '',
    'procedure Show(ACount: Integer);',
    '{$IFDEF FORMAT_PROBE_ALTERNATIVE}',
    'begin',
    '  WriteLn(''alternative '', ACount);',
    'end;',
    '{$ELSE}',
    'begin',
    '  WriteLn(''default '', ACount);',
    'end;',
    '{$ENDIF}',
    '',
    'begin',
    '  Show(1);',
    'end.']), 'FORMAT_PROBE_ALTERNATIVE');
end;

procedure TFormatRoutineScope.TestNestedRedeclarationKeepsItsOwnBinding;
begin
  ExpectFormats('NestedRedeclaration', SourceLines([
    'program NestedRedeclaration;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  var',
    '    count: Integer;',
    '  begin',
    '    count := 1;',
    '    WriteLn(count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']), SourceLines([
    'program NestedRedeclaration;',
    '{$mode objfpc}',
    '',
    'procedure Outer(ACount: Integer);',
    '  procedure Inner;',
    '  var',
    '    count: Integer;',
    '  begin',
    '    count := 1;',
    '    WriteLn(count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(ACount);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestNestedParameterOfTheSameNameIsRenamedSeparately;
begin
  ExpectFormats('NestedParameter', SourceLines([
    'program NestedParameter;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner(count: Integer);',
    '  begin',
    '    WriteLn(count);',
    '  end;',
    'begin',
    '  Inner(count);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']), SourceLines([
    'program NestedParameter;',
    '{$mode objfpc}',
    '',
    'procedure Outer(ACount: Integer);',
    '  procedure Inner(ACount: Integer);',
    '  begin',
    '    WriteLn(ACount);',
    '  end;',
    'begin',
    '  Inner(ACount);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestExistingNewNameBlocksTheRename;
begin
  { ACount already names a global the body uses; the parameter would
    shadow it. }
  ExpectUnchanged('ExistingNewName', SourceLines([
    'program ExistingNewName;',
    '',
    'var',
    '  ACount: Integer;',
    '',
    'procedure Show(count: Integer);',
    'begin',
    '  WriteLn(count + ACount);',
    'end;',
    '',
    'begin',
    '  ACount := 1;',
    '  Show(2);',
    'end.']));
end;

procedure TFormatRoutineScope.TestNewNameBoundOnlyInAShadowingScopeIsNoCollision;
begin
  { The first review probe, which used to become `var ACount, ACount`:
    Inner binds both names itself, so it keeps them and Outer is fixed. }
  ExpectFormats('ShadowedNewName', SourceLines([
    'program ShadowedNewName;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  var',
    '    count, ACount: Integer;',
    '  begin',
    '    count := 1;',
    '    ACount := 2;',
    '    WriteLn(count + ACount);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']), SourceLines([
    'program ShadowedNewName;',
    '{$mode objfpc}',
    '',
    'procedure Outer(ACount: Integer);',
    '  procedure Inner;',
    '  var',
    '    count, ACount: Integer;',
    '  begin',
    '    count := 1;',
    '    ACount := 2;',
    '    WriteLn(count + ACount);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(ACount);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestMemberOfTheNewNameIsNoCollision;
begin
  ExpectFormats('NewNameMember', SourceLines([
    'program NewNameMember;',
    '{$mode objfpc}',
    '',
    'type',
    '  TEntry = record',
    '    ACount: Integer;',
    '  end;',
    '',
    'procedure Store(count: Integer);',
    'var',
    '  Entry: TEntry;',
    'begin',
    '  Entry.ACount := count;',
    '  WriteLn(Entry.ACount);',
    'end;',
    '',
    'begin',
    '  Store(1);',
    'end.']), SourceLines([
    'program NewNameMember;',
    '{$mode objfpc}',
    '',
    'type',
    '  TEntry = record',
    '    ACount: Integer;',
    '  end;',
    '',
    'procedure Store(ACount: Integer);',
    'var',
    '  Entry: TEntry;',
    'begin',
    '  Entry.ACount := ACount;',
    '  WriteLn(Entry.ACount);',
    'end;',
    '',
    'begin',
    '  Store(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestNestedRecordFieldIsNotABinding;
begin
  { Review D-1: a field of the same name in a nested routine's record
    does not shadow the parameter, so the nested routine's use of it is
    renamed with the parameter, and the field keeps its name. }
  ExpectFormats('NestedField', SourceLines([
    'program NestedField;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  type',
    '    TEntry = record',
    '      count: Integer;',
    '    end;',
    '  var',
    '    Entry: TEntry;',
    '  begin',
    '    Entry.count := count;',
    '    WriteLn(Entry.count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(1);',
    'end.']), SourceLines([
    'program NestedField;',
    '{$mode objfpc}',
    '',
    'procedure Outer(ACount: Integer);',
    '  procedure Inner;',
    '  type',
    '    TEntry = record',
    '      count: Integer;',
    '    end;',
    '  var',
    '    Entry: TEntry;',
    '  begin',
    '    Entry.count := ACount;',
    '    WriteLn(Entry.count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(ACount);',
    'end;',
    '',
    'begin',
    '  Outer(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestNestedAbsoluteAliasBlocksTheRename;
begin
  { A nested `absolute` target may name a binding the formatter cannot
    place, so the outer parameter keeps its name (review D-1, N-3). }
  ExpectUnchanged('NestedAbsoluteAlias', SourceLines([
    'program NestedAbsoluteAlias;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  var',
    '    Alias: Integer absolute count;',
    '  begin',
    '    WriteLn(Alias);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestOwnAbsoluteAliasFollowsTheRename;
begin
  { In the routine that owns the parameter, `absolute count` can only
    name the parameter, so it is renamed with it. }
  ExpectFormats('OwnAbsoluteAlias', SourceLines([
    'program OwnAbsoluteAlias;',
    '{$mode objfpc}',
    '',
    'procedure Show(count: Integer);',
    'var',
    '  Alias: Integer absolute count;',
    'begin',
    '  WriteLn(Alias, count);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']), SourceLines([
    'program OwnAbsoluteAlias;',
    '{$mode objfpc}',
    '',
    'procedure Show(ACount: Integer);',
    'var',
    '  Alias: Integer absolute ACount;',
    'begin',
    '  WriteLn(Alias, ACount);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestInitializerLabelBlocksTheRename;
begin
  { Review N-3: `count: 7` labels a field of a typed constant; read as a
    nested binding, it used to exclude Inner and leave its use of the
    parameter stale. }
  ExpectUnchanged('InitializerLabel', SourceLines([
    'program InitializerLabel;',
    '{$mode objfpc}',
    '',
    'type',
    '  TRec = record',
    '    first, count: Integer;',
    '  end;',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  const',
    '    Data: TRec = (first: 1; count: 7);',
    '  begin',
    '    WriteLn(count, Data.count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestInitializerLabelWithAGlobalBlocksTheRename;
begin
  { The same shape with a global `count`: the stale reference used to
    compile against the global, and the program printed 997 instead of
    37. }
  ExpectUnchanged('InitializerGlobal', SourceLines([
    'program InitializerGlobal;',
    '{$mode objfpc}',
    '',
    'type',
    '  TRec = record',
    '    first, count: Integer;',
    '  end;',
    '',
    'var',
    '  count: Integer = 99;',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  const',
    '    Data: TRec = (first: 1; count: 7);',
    '  begin',
    '    WriteLn(count, Data.count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestSwitchAfterAModifierKeepsTheModifier;
begin
  (* Review N-1: a switch between `const` or `var` and the name made the
     modifier read as a parameter (`AConst {$R+} ACount`). *)
  ExpectFormats('SwitchAfterModifier', SourceLines([
    'program SwitchAfterModifier;',
    '',
    'procedure Show(const {$R+} count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    '',
    'procedure Fill(var {$R+} total: Integer);',
    'begin',
    '  total := 1;',
    'end;',
    '',
    'var',
    '  Value: Integer;',
    'begin',
    '  Show(1);',
    '  Fill(Value);',
    'end.']), SourceLines([
    'program SwitchAfterModifier;',
    '',
    'procedure Show(const {$R+} ACount: Integer);',
    'begin',
    '  WriteLn(ACount);',
    'end;',
    '',
    'procedure Fill(var {$R+} ATotal: Integer);',
    'begin',
    '  ATotal := 1;',
    'end;',
    '',
    'var',
    '  Value: Integer;',
    'begin',
    '  Show(1);',
    '  Fill(Value);',
    'end.']));
end;

procedure TFormatRoutineScope.TestEscapedKeywordParametersRenameOnlyIdentifiers;
begin
  { Review N-2: `&begin` and `&end` are identifiers; the `begin` and `end`
    keywords around them used to be renamed too. }
  ExpectFormats('EscapedKeywords', SourceLines([
    'program EscapedKeywords;',
    '',
    'procedure Outer(&begin: Integer);',
    'begin',
    '  WriteLn(&begin);',
    'end;',
    '',
    'procedure Last(&end: Integer);',
    'begin',
    '  WriteLn(&end);',
    'end;',
    '',
    'begin',
    '  Outer(1);',
    '  Last(2);',
    'end.']), SourceLines([
    'program EscapedKeywords;',
    '',
    'procedure Outer(ABegin: Integer);',
    'begin',
    '  WriteLn(ABegin);',
    'end;',
    '',
    'procedure Last(AEnd: Integer);',
    'begin',
    '  WriteLn(AEnd);',
    'end;',
    '',
    'begin',
    '  Outer(1);',
    '  Last(2);',
    'end.']));
end;

procedure TFormatRoutineScope.TestUncertainNestedMentionBlocksTheRename;
begin
  { A use in a nested declaration part that is neither a binding nor an
    `absolute` target leaves the binding uncertain. }
  ExpectUnchanged('UncertainMention', SourceLines([
    'program UncertainMention;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '  const',
    '    Limit = SizeOf(count);',
    '  begin',
    '    WriteLn(Limit, count);',
    '  end;',
    'begin',
    '  Inner;',
    'end;',
    '',
    'begin',
    '  Outer(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestNestedRoutineNamedLikeTheParameterBlocksTheRename;
begin
  ExpectUnchanged('NestedNamedLikeParameter', SourceLines([
    'program NestedNamedLikeParameter;',
    '{$mode objfpc}',
    '',
    'procedure Outer(count: Integer);',
    '  procedure Inner;',
    '    function Count: Integer;',
    '    begin',
    '      Count := 7;',
    '    end;',
    '  begin',
    '    WriteLn(count);',
    '  end;',
    'begin',
    '  Inner;',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Outer(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestSameNamedRecordFieldIsNotTheParameter;
begin
  ExpectFormats('SameNamedField', SourceLines([
    'program SameNamedField;',
    '{$mode objfpc}',
    '',
    'procedure Tally(count: Integer);',
    'type',
    '  TEntry = record',
    '    count: Integer;',
    '  end;',
    'var',
    '  Entry: TEntry;',
    'begin',
    '  Entry.count := count;',
    '  WriteLn(Entry.count);',
    'end;',
    '',
    'begin',
    '  Tally(2);',
    'end.']), SourceLines([
    'program SameNamedField;',
    '{$mode objfpc}',
    '',
    'procedure Tally(ACount: Integer);',
    'type',
    '  TEntry = record',
    '    count: Integer;',
    '  end;',
    'var',
    '  Entry: TEntry;',
    'begin',
    '  Entry.count := ACount;',
    '  WriteLn(Entry.count);',
    'end;',
    '',
    'begin',
    '  Tally(2);',
    'end.']));
end;

procedure TFormatRoutineScope.TestWithStatementBlocksTheRename;
begin
  { Inside `with Entry do`, `count` is the field: renaming it to the
    parameter would change what the program prints. }
  ExpectUnchanged('WithStatement', SourceLines([
    'program WithStatement;',
    '{$mode objfpc}',
    '',
    'type',
    '  TEntry = record',
    '    count: Integer;',
    '  end;',
    '',
    'procedure Show(count: Integer);',
    'var',
    '  Entry: TEntry;',
    'begin',
    '  Entry.count := 7;',
    '  with Entry do',
    '    WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Show(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestTypeNamedLikeTheParameterBlocksTheRename;
begin
  ExpectUnchanged('TypeLikeParameter', SourceLines([
    'program TypeLikeParameter;',
    '',
    'type',
    '  Value = Integer;',
    '',
    'procedure Show(value: Value);',
    'begin',
    '  WriteLn(value);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestDeclarationAfterAnAlternativeBodyIsNotOwned;
begin
  { The global `count` sits between the alternative bodies; the routine's
    extent may not swallow it. }
  ExpectUnchanged('ConditionalGlobal', SourceLines([
    'program ConditionalGlobal;',
    '',
    'procedure Show(count: Integer);',
    '{$ifdef FORMAT_PROBE_ALTERNATIVE}',
    'begin',
    '  WriteLn(count);',
    'end;',
    'var',
    '  count: Integer;',
    '{$else}',
    'begin',
    '  WriteLn(count);',
    'end;',
    '{$endif}',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestOverloadsAreRenamedSeparately;
begin
  { Review D-2: the collision in the string overload no longer holds back
    the integer one. }
  ExpectFormats('OverloadGroups', SourceLines([
    'program OverloadGroups;',
    '{$mode objfpc}',
    '',
    'procedure Show(count: Integer); overload;',
    'begin',
    '  WriteLn(count);',
    'end;',
    '',
    'procedure Show(count: string); overload;',
    'var',
    '  ACount: Integer;',
    'begin',
    '  ACount := 1;',
    '  WriteLn(count, ACount);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    '  Show(''x'');',
    'end.']), SourceLines([
    'program OverloadGroups;',
    '{$mode objfpc}',
    '',
    'procedure Show(ACount: Integer); overload;',
    'begin',
    '  WriteLn(ACount);',
    'end;',
    '',
    'procedure Show(count: string); overload;',
    'var',
    '  ACount: Integer;',
    'begin',
    '  ACount := 1;',
    '  WriteLn(count, ACount);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    '  Show(''x'');',
    'end.']));
end;

procedure TFormatRoutineScope.TestSameNamedNestedRoutinesAreSeparate;
begin
  { Review D-2: nested routines of one name in different parents are
    different routines. }
  ExpectFormats('NestedSameName', SourceLines([
    'program NestedSameName;',
    '{$mode objfpc}',
    '',
    'var',
    '  ACount: Integer;',
    '',
    'procedure First;',
    '  procedure Show(count: Integer);',
    '  begin',
    '    WriteLn(count + ACount);',
    '  end;',
    'begin',
    '  Show(1);',
    'end;',
    '',
    'procedure Second;',
    '  procedure Show(count: Integer);',
    '  begin',
    '    WriteLn(count);',
    '  end;',
    'begin',
    '  Show(2);',
    'end;',
    '',
    'begin',
    '  First;',
    '  Second;',
    'end.']), SourceLines([
    'program NestedSameName;',
    '{$mode objfpc}',
    '',
    'var',
    '  ACount: Integer;',
    '',
    'procedure First;',
    '  procedure Show(count: Integer);',
    '  begin',
    '    WriteLn(count + ACount);',
    '  end;',
    'begin',
    '  Show(1);',
    'end;',
    '',
    'procedure Second;',
    '  procedure Show(ACount: Integer);',
    '  begin',
    '    WriteLn(ACount);',
    '  end;',
    'begin',
    '  Show(2);',
    'end;',
    '',
    'begin',
    '  First;',
    '  Second;',
    'end.']));
end;

procedure TFormatRoutineScope.TestIndependentConditionalDeclarationsAreRenamed;
var
  Source, Expected: string;
begin
  { Review D-3: a directive between two independent declarations does not
    make them alternatives. Both configurations compile. }
  Source := SourceLines([
    'unit IndependentConditional;',
    '{$mode objfpc}',
    '',
    'interface',
    '',
    'procedure First(count: Integer);',
    '{$ifdef FORMAT_PROBE_ALTERNATIVE}',
    'procedure Second(value: Integer);',
    '{$endif}',
    '',
    'implementation',
    '',
    'procedure First(count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    '',
    '{$ifdef FORMAT_PROBE_ALTERNATIVE}',
    'procedure Second(value: Integer);',
    'begin',
    '  WriteLn(value);',
    'end;',
    '{$endif}',
    '',
    'end.']);
  Expected := StringReplace(StringReplace(Source, 'count', 'ACount', [rfReplaceAll]),
    'value', 'AValue', [rfReplaceAll]);
  ExpectFormats('IndependentConditional', Source, Expected, 'FORMAT_PROBE_ALTERNATIVE');
end;

procedure TFormatRoutineScope.TestPlainDirectiveInTheParameterListIsKept;
begin
  { Review D-5: a switch directive does not change the declaration. }
  ExpectFormats('SwitchInParameters', SourceLines([
    'program SwitchInParameters;',
    '',
    'procedure Show({$R+}count: Integer);',
    'begin',
    '  WriteLn(count);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']), SourceLines([
    'program SwitchInParameters;',
    '',
    'procedure Show({$R+}ACount: Integer);',
    'begin',
    '  WriteLn(ACount);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestEscapedParameterIsRenamed;
begin
  { Review D-6: `&value` and `value` are one name; the prefixed form needs
    no escape. }
  ExpectFormats('EscapedParameter', SourceLines([
    'program EscapedParameter;',
    '',
    'procedure Show(&value: Integer);',
    'begin',
    '  WriteLn(&value);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']), SourceLines([
    'program EscapedParameter;',
    '',
    'procedure Show(AValue: Integer);',
    'begin',
    '  WriteLn(AValue);',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestBodylessHeadersKeepTheirRenameInTheHeader;
begin
  { Neither the class member nor the forward header owns the code that
    follows it, so the program's own `count` and `total` survive. }
  ExpectFormats('BodylessHeaders', SourceLines([
    'program BodylessHeaders;',
    '{$mode objfpc}',
    '',
    'type',
    '  TCounter = class',
    '    procedure Step(count: Integer);',
    '  end;',
    '',
    'procedure Report(total: Integer); forward;',
    '',
    'procedure TCounter.Step(count: Integer);',
    'begin',
    '  Report(count);',
    'end;',
    '',
    'procedure Report(total: Integer);',
    'begin',
    '  WriteLn(total);',
    'end;',
    '',
    'var',
    '  count, total: Integer;',
    'begin',
    '  count := 1;',
    '  total := count;',
    '  Report(total);',
    'end.']), SourceLines([
    'program BodylessHeaders;',
    '{$mode objfpc}',
    '',
    'type',
    '  TCounter = class',
    '    procedure Step(ACount: Integer);',
    '  end;',
    '',
    'procedure Report(ATotal: Integer); forward;',
    '',
    'procedure TCounter.Step(ACount: Integer);',
    'begin',
    '  Report(ACount);',
    'end;',
    '',
    'procedure Report(ATotal: Integer);',
    'begin',
    '  WriteLn(ATotal);',
    'end;',
    '',
    'var',
    '  count, total: Integer;',
    'begin',
    '  count := 1;',
    '  total := count;',
    '  Report(total);',
    'end.']));
end;

procedure TFormatRoutineScope.TestMethodDeclarationAndImplementationStayInStep;
begin
  { FPC rejects an implementation whose parameter names differ from the
    declaration's, so members of a class, of a type nested in it, and a
    member declared right after `class` are renamed with their
    implementations. }
  ExpectFormats('MethodsInStep', SourceLines([
    'program MethodsInStep;',
    '{$mode objfpc}{$modeswitch advancedrecords}',
    '',
    'type',
    '  TShape = class',
    '    constructor Create(width: Integer);',
    '  private',
    '    class var Made: Integer;',
    '  public',
    '    type',
    '      TPoint = record',
    '        X, Y: Integer;',
    '        procedure Shift(delta: Integer);',
    '      end;',
    '    function Area(height: Integer): Integer;',
    '  end;',
    '',
    'procedure TShape.TPoint.Shift(delta: Integer);',
    'begin',
    '  X := X + delta;',
    'end;',
    '',
    'constructor TShape.Create(width: Integer);',
    'begin',
    '  Made := width;',
    'end;',
    '',
    'function TShape.Area(height: Integer): Integer;',
    'begin',
    '  Result := Made * height;',
    'end;',
    '',
    'begin',
    '  WriteLn(TShape.Create(2).Area(3));',
    'end.']), SourceLines([
    'program MethodsInStep;',
    '{$mode objfpc}{$modeswitch advancedrecords}',
    '',
    'type',
    '  TShape = class',
    '    constructor Create(AWidth: Integer);',
    '  private',
    '    class var Made: Integer;',
    '  public',
    '    type',
    '      TPoint = record',
    '        X, Y: Integer;',
    '        procedure Shift(ADelta: Integer);',
    '      end;',
    '    function Area(AHeight: Integer): Integer;',
    '  end;',
    '',
    'procedure TShape.TPoint.Shift(ADelta: Integer);',
    'begin',
    '  X := X + ADelta;',
    'end;',
    '',
    'constructor TShape.Create(AWidth: Integer);',
    'begin',
    '  Made := AWidth;',
    'end;',
    '',
    'function TShape.Area(AHeight: Integer): Integer;',
    'begin',
    '  Result := Made * AHeight;',
    'end;',
    '',
    'begin',
    '  WriteLn(TShape.Create(2).Area(3));',
    'end.']));
end;

procedure TFormatRoutineScope.TestInterfaceDeclarationAndImplementationStayInStep;
begin
  ExpectFormats('InterfaceInStep', SourceLines([
    'unit InterfaceInStep;',
    '{$mode objfpc}',
    '',
    'interface',
    '',
    'procedure Announce(note: string);',
    '',
    'implementation',
    '',
    'procedure Announce(note: string);',
    'begin',
    '  WriteLn(note);',
    'end;',
    '',
    'end.']), SourceLines([
    'unit InterfaceInStep;',
    '{$mode objfpc}',
    '',
    'interface',
    '',
    'procedure Announce(ANote: string);',
    '',
    'implementation',
    '',
    'procedure Announce(ANote: string);',
    'begin',
    '  WriteLn(ANote);',
    'end;',
    '',
    'end.']));
end;

procedure TFormatRoutineScope.TestDirectiveWordParameterIsLeftAlone;
begin
  { `message` is read as a keyword token. Renames never touch keyword
    tokens, so a parameter spelled like a directive word keeps its name. }
  ExpectUnchanged('DirectiveWordParameter', SourceLines([
    'program DirectiveWordParameter;',
    '{$mode objfpc}',
    '',
    'procedure Announce(message: string);',
    'begin',
    '  WriteLn(message);',
    'end;',
    '',
    'begin',
    '  Announce(''x'');',
    'end.']));
end;

procedure TFormatRoutineScope.TestEscapedDirectiveWordWithUnescapedUseIsLeftAlone;
begin
  { An escaped `&message` parameter may be used unescaped, and those uses
    are keyword tokens a rename cannot touch. Renaming only the escaped
    header would rebind `message` to the global and print 99 instead of 3. }
  ExpectUnchanged('EscapedDirectiveWord', SourceLines([
    'program EscapedDirectiveWord;',
    '{$mode objfpc}',
    '',
    'var',
    '  message: Integer = 99;',
    '',
    'procedure Show(&message: Integer);',
    'begin',
    '  WriteLn(message);',
    'end;',
    '',
    'begin',
    '  Show(3);',
    'end.']));
end;

procedure TFormatRoutineScope.TestOmittedImplementationParametersBlockTheRename;
begin
  { Delphi mode lets the implementation omit the parameter list, so its
    body uses names only the declaration shows. }
  ExpectUnchanged('OmittedParameters', SourceLines([
    'unit OmittedParameters;',
    '{$mode delphi}',
    '',
    'interface',
    '',
    'type',
    '  TGauge = class',
    '    procedure Fill(level: Integer);',
    '  end;',
    '',
    'implementation',
    '',
    'procedure TGauge.Fill;',
    'begin',
    '  WriteLn(level);',
    'end;',
    '',
    'end.']));
end;

procedure TFormatRoutineScope.TestAssemblerRoutinesAreLeftUntouched;
begin
  { A routine containing assembler keeps every header's parameter names:
    the formatter cannot tell an operand from a register (`eax`). A
    routine without assembler in the same file is still fixed. }
  ExpectFormats('AssemblerRoutines', SourceLines([
    'program AssemblerRoutines;',
    '{$mode objfpc}',
    '{$IFDEF CPUX86_64}{$asmmode intel}{$ENDIF}',
    '',
    'type',
    '  TAdder = class',
    '    function Twice(eax: LongInt): LongInt;',
    '  end;',
    '',
    'function TAdder.Twice(eax: LongInt): LongInt; assembler; nostackframe;',
    'asm',
    '{$IFDEF CPUX86_64}',
    '  mov eax, edx',
    '  add eax, eax',
    '{$ELSE}',
    '  nop',
    '{$ENDIF}',
    'end;',
    '',
    'function Triple(value: LongInt): LongInt;',
    'begin',
    '  Result := value;',
    '  asm',
    '    nop',
    '  end;',
    '  Result := Result * 3;',
    'end;',
    '',
    'function Half(value: LongInt): LongInt;',
    'begin',
    '  Result := value div 2;',
    'end;',
    '',
    'begin',
    '  WriteLn(Triple(2), Half(4));',
    'end.']), SourceLines([
    'program AssemblerRoutines;',
    '{$mode objfpc}',
    '{$IFDEF CPUX86_64}{$asmmode intel}{$ENDIF}',
    '',
    'type',
    '  TAdder = class',
    '    function Twice(eax: LongInt): LongInt;',
    '  end;',
    '',
    'function TAdder.Twice(eax: LongInt): LongInt; assembler; nostackframe;',
    'asm',
    '{$IFDEF CPUX86_64}',
    '  mov eax, edx',
    '  add eax, eax',
    '{$ELSE}',
    '  nop',
    '{$ENDIF}',
    'end;',
    '',
    'function Triple(value: LongInt): LongInt;',
    'begin',
    '  Result := value;',
    '  asm',
    '    nop',
    '  end;',
    '  Result := Result * 3;',
    'end;',
    '',
    'function Half(AValue: LongInt): LongInt;',
    'begin',
    '  Result := AValue div 2;',
    'end;',
    '',
    'begin',
    '  WriteLn(Triple(2), Half(4));',
    'end.']));
end;

procedure TFormatRoutineScope.TestDirectiveInTheParameterListBlocksTheRename;
begin
  { The directive selects between parameter modifiers the formatter
    cannot read both ways. }
  ExpectUnchanged('DirectiveInParameters', SourceLines([
    'program DirectiveInParameters;',
    '{$mode objfpc}',
    '',
    'procedure Keep({$ifdef fpc}constref{$else}const{$endif} value: Integer);',
    'begin',
    '  WriteLn(value);',
    'end;',
    '',
    'begin',
    '  Keep(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestDifferentlyCasedPrefixKeepsHeadersInStep;
begin
  { FPC treats `aRecord` and `ARecord` as one name. Only the first lacks
    the prefix, so renaming it alone would break the match. }
  ExpectUnchanged('PrefixSpelling', SourceLines([
    'program PrefixSpelling;',
    '{$mode objfpc}',
    '',
    'type',
    '  TPool = class',
    '    procedure Release(aRecord: Pointer);',
    '  end;',
    '',
    'procedure TPool.Release(ARecord: Pointer);',
    'begin',
    '  WriteLn(ARecord <> nil);',
    'end;',
    '',
    'begin',
    '  TPool.Create.Release(nil);',
    'end.']));
end;

procedure TFormatRoutineScope.TestParameterSpelledLikeItsRoutineIsKept;
begin
  ExpectFormats('ParameterLikeRoutine', SourceLines([
    'program ParameterLikeRoutine;',
    '',
    'procedure Wheel(Wheel, Direction: Integer);',
    'begin',
    '  WriteLn(Wheel + Direction);',
    'end;',
    '',
    'begin',
    '  Wheel(1, 2);',
    'end.']), SourceLines([
    'program ParameterLikeRoutine;',
    '',
    'procedure Wheel(Wheel, ADirection: Integer);',
    'begin',
    '  WriteLn(Wheel + ADirection);',
    'end;',
    '',
    'begin',
    '  Wheel(1, 2);',
    'end.']));
end;

procedure TFormatRoutineScope.TestBodyContinuedInAnIncludeFileBlocksTheRename;
begin
  { The include file's references are out of the formatter's reach. }
  WriteTextFile(FixtureDirectory + '/IncludedBody.inc', '  WriteLn(count);' + LineEnding);
  ExpectUnchanged('IncludedBody', SourceLines([
    'program IncludedBody;',
    '',
    'procedure Show(count: Integer);',
    'begin',
    '  {$I IncludedBody.inc}',
    'end;',
    '',
    'begin',
    '  Show(1);',
    'end.']));
end;

procedure TFormatRoutineScope.TestParameterlessOverloadDoesNotBlockTheRename;
begin
  { Only a declaration with parameters can have an implementation that
    omits them; two overloads with bodies are no such case. }
  ExpectFormats('ParameterlessOverload', SourceLines([
    'program ParameterlessOverload;',
    '{$mode objfpc}',
    '',
    'function Scale(factor: Integer): Integer; overload;',
    'begin',
    '  Result := factor * 2;',
    'end;',
    '',
    'function Scale: Integer; overload;',
    'begin',
    '  Result := Scale(1);',
    'end;',
    '',
    'begin',
    '  WriteLn(Scale);',
    'end.']), SourceLines([
    'program ParameterlessOverload;',
    '{$mode objfpc}',
    '',
    'function Scale(AFactor: Integer): Integer; overload;',
    'begin',
    '  Result := AFactor * 2;',
    'end;',
    '',
    'function Scale: Integer; overload;',
    'begin',
    '  Result := Scale(1);',
    'end;',
    '',
    'begin',
    '  WriteLn(Scale);',
    'end.']));
end;

procedure TFormatRoutineScope.TestConditionalAlternativeHeadersBlockTheRename;
var
  Source: string;
begin
  { The fcl-db dbf.pas shape: one body under two alternative headers.
    Renaming the first header alone left `files` unresolved in its body. }
  Source := SourceLines([
    'unit AlternativeHeaders;',
    '{$mode objfpc}',
    '',
    'interface',
    '',
    'implementation',
    '',
    'uses',
    '  SysUtils;',
    '',
    '{$ifdef FORMAT_PROBE_ALTERNATIVE}',
    'function Describe(files: Integer): string;',
    '{$else}',
    'function DescribeCount(files: Integer): string;',
    '{$endif}',
    'begin',
    '  Result := IntToStr(files);',
    'end;',
    '',
    'end.']);
  ExpectFormats('AlternativeHeaders', Source, Normalized(Source),
    'FORMAT_PROBE_ALTERNATIVE');
end;

procedure TFormatRoutineScope.SetupTests;
begin
  Test('forward on the next line: the header owns no body',
    TestForwardOnTheNextLineOwnsNoBody);
  Test('external on the next line: left alone, nothing leaks',
    TestExternalOnTheNextLineIsLeftAlone);
  Test('begin on the header line: the body is renamed with the header',
    TestBeginOnTheHeaderLineOwnsTheBody);
  Test('conditional alternative bodies are all renamed',
    TestConditionalAlternativeBodiesAreAllRenamed);
  Test('a nested redeclaration keeps its own binding',
    TestNestedRedeclarationKeepsItsOwnBinding);
  Test('a nested parameter of the same name is renamed separately',
    TestNestedParameterOfTheSameNameIsRenamedSeparately);
  Test('an existing new name blocks the rename',
    TestExistingNewNameBlocksTheRename);
  Test('a nested routine named like the parameter blocks the rename',
    TestNestedRoutineNamedLikeTheParameterBlocksTheRename);
  Test('a same-named record field is not the parameter',
    TestSameNamedRecordFieldIsNotTheParameter);
  Test('the new name bound only in a shadowing scope is no collision',
    TestNewNameBoundOnlyInAShadowingScopeIsNoCollision);
  Test('a member access of the new name is no collision',
    TestMemberOfTheNewNameIsNoCollision);
  Test('a nested record field is not a binding',
    TestNestedRecordFieldIsNotABinding);
  Test('a nested absolute alias blocks the rename',
    TestNestedAbsoluteAliasBlocksTheRename);
  Test('the owning routine''s absolute alias follows the rename',
    TestOwnAbsoluteAliasFollowsTheRename);
  Test('a typed-constant initializer label blocks the rename',
    TestInitializerLabelBlocksTheRename);
  Test('an initializer label with a same-named global blocks the rename',
    TestInitializerLabelWithAGlobalBlocksTheRename);
  Test('a switch after a parameter modifier keeps the modifier',
    TestSwitchAfterAModifierKeepsTheModifier);
  Test('escaped keyword parameters rename only identifiers',
    TestEscapedKeywordParametersRenameOnlyIdentifiers);
  Test('a parameter spelled like a directive word is left alone',
    TestDirectiveWordParameterIsLeftAlone);
  Test('an escaped directive-word parameter used unescaped keeps its name',
    TestEscapedDirectiveWordWithUnescapedUseIsLeftAlone);
  Test('an uncertain nested mention blocks the rename',
    TestUncertainNestedMentionBlocksTheRename);
  Test('a with statement blocks the rename',
    TestWithStatementBlocksTheRename);
  Test('a type named like the parameter blocks the rename',
    TestTypeNamedLikeTheParameterBlocksTheRename);
  Test('a declaration after an alternative body is not owned',
    TestDeclarationAfterAnAlternativeBodyIsNotOwned);
  Test('overloads are renamed separately',
    TestOverloadsAreRenamedSeparately);
  Test('same-named nested routines in different parents are separate',
    TestSameNamedNestedRoutinesAreSeparate);
  Test('independent declarations around a directive are renamed',
    TestIndependentConditionalDeclarationsAreRenamed);
  Test('a switch directive in the parameter list does not block the rename',
    TestPlainDirectiveInTheParameterListIsKept);
  Test('an escaped parameter is renamed',
    TestEscapedParameterIsRenamed);
  Test('bodyless headers confine their rename to the header',
    TestBodylessHeadersKeepTheirRenameInTheHeader);
  Test('method declarations and implementations stay in step',
    TestMethodDeclarationAndImplementationStayInStep);
  Test('interface declarations and implementations stay in step',
    TestInterfaceDeclarationAndImplementationStayInStep);
  Test('an implementation omitting its parameters blocks the rename',
    TestOmittedImplementationParametersBlockTheRename);
  Test('routines containing assembler are left untouched',
    TestAssemblerRoutinesAreLeftUntouched);
  Test('a directive in the parameter list blocks the rename',
    TestDirectiveInTheParameterListBlocksTheRename);
  Test('a differently cased prefix keeps declaration and implementation in step',
    TestDifferentlyCasedPrefixKeepsHeadersInStep);
  Test('a parameter spelled like its routine is kept',
    TestParameterSpelledLikeItsRoutineIsKept);
  Test('a body continued in an include file blocks the rename',
    TestBodyContinuedInAnIncludeFileBlocksTheRename);
  Test('a parameterless overload does not block the rename',
    TestParameterlessOverloadDoesNotBlockTheRename);
  Test('alternative headers in conditional branches block the rename',
    TestConditionalAlternativeHeadersBlockTheRename);
end;

{ ───────── TFormatScopeExpansion (ADR-0007) ───────── }

function ScopeFixture: string;
begin
  Result := ScratchRoot + '/format-scope';
end;

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
  WriteTextFile(ScopeFixture + '/top.pas',                'unit Top; end.'#10);
  WriteTextFile(ScopeFixture + '/top.inc',                '{ inc }'#10);
  WriteTextFile(ScopeFixture + '/top.dpr',                'program Top; begin end.'#10);
  WriteTextFile(ScopeFixture + '/top.lpr',                'program TopL; begin end.'#10);
  WriteTextFile(ScopeFixture + '/not-pascal.txt',         'plain text'#10);
  WriteTextFile(ScopeFixture + '/.hidden.pas',            'unit Hidden; end.'#10);
  WriteTextFile(ScopeFixture + '/sub/middle.pas',         'unit Middle; end.'#10);
  WriteTextFile(ScopeFixture + '/sub/deep/leaf.pas',      'unit Leaf; end.'#10);
  WriteTextFile(ScopeFixture + '/.lwpt/modules/dep/source/Vendored.pas',
                'unit Vendored; end.'#10);
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
    ExpandFormatPattern(ScopeFixture, List, True);
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
    ExpandFormatPattern(ScopeFixture,       A, True);
    ExpandFormatPattern(ScopeFixture + '/', B, True);
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
    ExpandFormatPattern(ScopeFixture + '/*.pas', List, True);
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
    ExpandFormatPattern(ScopeFixture + '/**/*.pas', List, True);
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
    ExpandFormatPattern(ScopeFixture + '/sub/middle.pas', List, True);
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
      ExpandFormatPattern(ScopeFixture + '/does-not-exist.pas', List, True);
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
    ExpandFormatPattern(ScopeFixture + '/does-not-exist.pas', List, False);
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
    ExpandFormatPattern(ScopeFixture + '/*.xyz', List, True);
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
    ExpandFormatPattern(ScopeFixture + '/*.pas', List, True);
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
    ExpandFormatPattern(ScopeFixture + '/*.txt', List, True);
    Expect<Integer>(List.Count).ToBe(0);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestExplicitDotSegmentReachesHiddenDir;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    { A pattern segment that itself starts with '.' names the hidden
      dir explicitly — the walker must enter it. Matches shell glob
      convention (`*` hides dotfiles; `.lwpt/*` does not). }
    ExpandFormatPattern(ScopeFixture + '/.lwpt/**', List, True);
    Expect<Boolean>(ListContainsSuffix(List, 'Vendored.pas')).ToBe(True);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestExplicitDotFileGlobReachesHiddenDir;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    ExpandFormatPattern(ScopeFixture + '/.lwpt/**/*.pas', List, True);
    Expect<Boolean>(ListContainsSuffix(List, 'Vendored.pas')).ToBe(True);
  finally
    List.Free;
  end;
end;

procedure TFormatScopeExpansion.TestWildcardSegmentsStillSkipHiddenDirs;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    { Without the explicit dot, hidden dirs stay invisible: a plain
      recursive glob never descends into .lwpt/. }
    ExpandFormatPattern(ScopeFixture + '/**/*.pas', List, True);
    Expect<Boolean>(ListContainsSuffix(List, 'Vendored.pas')).ToBe(False);
    Expect<Boolean>(ListContainsSuffix(List, '.hidden.pas')).ToBe(False);
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
  Test('explicit .dir segment enters the hidden dir it names',
    TestExplicitDotSegmentReachesHiddenDir);
  Test('explicit .dir segment composes with trailing file globs',
    TestExplicitDotFileGlobReachesHiddenDir);
  Test('wildcard segments still skip hidden dirs',
    TestWildcardSegmentsStillSkipHiddenDirs);
end;

{ ───────── TLWPTFormatToolkitStateDefault ───────── }

procedure TLWPTFormatToolkitStateDefault.BeforeAll;
const
  NEEDS_FORMAT =
    'unit Vendored;'#10#10
    + 'interface'#10#10
    + 'uses'#10
    + '  SysUtils,'#10
    + '  Classes;'#10#10
    + 'implementation'#10#10
    + 'end.'#10;
  ALREADY_FORMATTED =
    'unit Good;'#10#10
    + 'interface'#10#10
    + 'uses'#10
    + '  Classes,'#10
    + '  SysUtils;'#10#10
    + 'implementation'#10#10
    + 'end.'#10;
begin
  FOrigDir  := GetCurrentDir;
  FScratch  := ExpandFileName(ScratchRoot + '/format-toolkit-state-default');

  { All variants seed the toolkit-state source via [package].units.
    The source genuinely needs formatting, so exit 0 proves exclusion
    and exit 1 proves the explicit-include override reached it. }
  WriteTextFile(FScratch + '/default.toml',
      '[package]'#10
    + 'name = "format-toolkit-state-default"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src", ".lwpt/modules/dep/source"]'#10);
  WriteTextFile(FScratch + '/include.toml',
      '[package]'#10
    + 'name = "format-toolkit-state-include"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src", ".lwpt/modules/dep/source"]'#10
    + #10
    + '[format]'#10
    + 'include = [".lwpt/modules/**"]'#10);
  WriteTextFile(FScratch + '/include-exclude.toml',
      '[package]'#10
    + 'name = "format-toolkit-state-include-exclude"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src", ".lwpt/modules/dep/source"]'#10
    + #10
    + '[format]'#10
    + 'include = [".lwpt/modules/**"]'#10
    + 'exclude = [".lwpt/**"]'#10);
  WriteTextFile(FScratch + '/case-sensitive.toml',
      '[package]'#10
    + 'name = "format-toolkit-state-case-sensitive"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src", ".lwpt/case/source"]'#10
    + #10
    + '[format]'#10
    + 'include = [".lwpt/case/source/Included.pas"]'#10);
  WriteTextFile(FScratch + '/override.toml',
      '[package]'#10
    + 'name = "format-toolkit-state-override"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src", "vendor/modules/dep/source"]'#10
    + #10
    + '[lwpt]'#10
    + 'modules-dir = "vendor/modules"'#10);
  WriteTextFile(FScratch + '/override-include.toml',
      '[package]'#10
    + 'name = "format-toolkit-state-override-include"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src", "vendor/modules/dep/source"]'#10
    + #10
    + '[lwpt]'#10
    + 'modules-dir = "vendor/modules"'#10
    + #10
    + '[format]'#10
    + 'include = ["vendor/modules/**"]'#10);
  WriteTextFile(FScratch + '/sessions-in-source.toml',
      '[package]'#10
    + 'name = "format-sessions-in-source"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["session-source"]'#10
    + #10
    + '[lwpt]'#10
    + 'sessions-dir = "session-source"'#10);
  WriteTextFile(FScratch + '/src/Good.pas', ALREADY_FORMATTED);
  WriteTextFile(FScratch + '/.lwpt/modules/dep/source/Vendored.pas',
    NEEDS_FORMAT);
  WriteTextFile(FScratch + '/vendor/modules/dep/source/Vendored.pas',
    NEEDS_FORMAT);
  WriteTextFile(FScratch + '/.lwpt/case/source/Included.pas',
    ALREADY_FORMATTED);
  WriteTextFile(FScratch + '/.lwpt/case/source/included.pas',
    NEEDS_FORMAT);
  WriteTextFile(FScratch + '/session-source/NeedsFormat.pas',
    NEEDS_FORMAT);
  FCaseDistinctFilesSupported :=
    DirectoryHasExactEntry(FScratch + '/.lwpt/case/source', 'Included.pas')
    and DirectoryHasExactEntry(FScratch + '/.lwpt/case/source',
      'included.pas');

  SetCurrentDir(FScratch);
end;

procedure TLWPTFormatToolkitStateDefault.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TLWPTFormatToolkitStateDefault.TestSeededToolkitStateIsExcludedByDefault;
begin
  Expect<Integer>(CmdFormat('default.toml', True)).ToBe(0);
end;

procedure TLWPTFormatToolkitStateDefault.TestExplicitIncludeOverridesDefaultExclusion;
begin
  Expect<Integer>(CmdFormat('include.toml', True)).ToBe(1);
end;

procedure TLWPTFormatToolkitStateDefault.TestExplicitExcludeStillWinsOverInclude;
begin
  Expect<Integer>(CmdFormat('include-exclude.toml', True)).ToBe(0);
end;

procedure TLWPTFormatToolkitStateDefault.TestExplicitIncludeMatchIsCaseSensitive;
begin
  { Case-insensitive filesystems cannot hold both fixture paths. Linux CI
    exercises the full regression; other platforms report the limitation. }
  if not FCaseDistinctFilesSupported then
  begin
    WriteLn('  case-distinct path behavior not exercised: filesystem is case-insensitive');
    Expect<Boolean>(FCaseDistinctFilesSupported).ToBe(False);
    Exit;
  end;

  Expect<Integer>(CmdFormat('case-sensitive.toml', True)).ToBe(0);
end;

procedure TLWPTFormatToolkitStateDefault.TestOverriddenModulesDirIsExcludedByDefault;
begin
  { [lwpt] modules-dir points outside .lwpt/; the redirected toolkit
    state must be protected exactly like the fixed root. }
  Expect<Integer>(CmdFormat('override.toml', True)).ToBe(0);
end;

procedure TLWPTFormatToolkitStateDefault.TestExplicitIncludeOverridesOverriddenModulesDir;
begin
  Expect<Integer>(CmdFormat('override-include.toml', True)).ToBe(1);
end;

procedure TLWPTFormatToolkitStateDefault.
  TestSessionsBaseDoesNotHideSiblingSources;
begin
  Expect<Integer>(CmdFormat('sessions-in-source.toml', True)).ToBe(1);
end;

procedure TLWPTFormatToolkitStateDefault.SetupTests;
begin
  Test('units-seeded .lwpt source is excluded by default',
    TestSeededToolkitStateIsExcludedByDefault);
  Test('explicit include overrides the .lwpt default exclusion',
    TestExplicitIncludeOverridesDefaultExclusion);
  Test('explicit exclude still wins over an explicit include',
    TestExplicitExcludeStillWinsOverInclude);
  Test('explicit include provenance is case-sensitive',
    TestExplicitIncludeMatchIsCaseSensitive);
  Test('overridden [lwpt] modules-dir outside .lwpt is excluded by default',
    TestOverriddenModulesDirIsExcludedByDefault);
  Test('explicit include overrides the overridden modules-dir exclusion',
    TestExplicitIncludeOverridesOverriddenModulesDir);
  Test('configured sessions base does not hide sibling sources',
    TestSessionsBaseDoesNotHideSiblingSources);
end;

begin
  TestRunnerProgram.AddSuite(TFormatIdempotence.Create(PROJECT_NAME + '.Formatter: idempotence'));
  TestRunnerProgram.AddSuite(TFormatParamRename.Create(PROJECT_NAME + '.Formatter: param-rename regression'));
  TestRunnerProgram.AddSuite(TFormatUsesComments.Create(PROJECT_NAME + '.Formatter: uses-clause comments'));
  TestRunnerProgram.AddSuite(TFormatCommentsAndStrings.Create(PROJECT_NAME + '.Formatter: comments and strings'));
  TestRunnerProgram.AddSuite(TFormatRoutineScope.Create(PROJECT_NAME + '.Formatter: routine scope'));
  TestRunnerProgram.AddSuite(TFormatScopeExpansion.Create(PROJECT_NAME + '.Formatter: scope expansion (ADR-0007)'));
  TestRunnerProgram.AddSuite(TLWPTFormatToolkitStateDefault.Create(PROJECT_NAME + '.Formatter: toolkit-state default'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
  if ScratchDirectory <> '' then
    RecursiveDelete(ScratchDirectory);
end.
