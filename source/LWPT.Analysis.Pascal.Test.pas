{ LWPT.Analysis.Pascal.Test — tokenizer and typed-region foundation. }
program LWPT.Analysis.Pascal.Test;

{$I Shared.inc}

uses
  SysUtils,

  LWPT.Analysis.Pascal,
  LWPT.Core,
  TestingPascalLibrary;

type
  TPascalTokenizerTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNormalizationAndLocations;
    procedure TestCommentsDisappearAndDirectivesRemain;
    procedure TestBraceCommentsIgnoreOtherDelimiters;
    procedure TestParenCommentsIgnoreOtherDelimiters;
    procedure TestReservedWordsAndEscapedIdentifiers;
    procedure TestCommentNestingFollowsSourceMode;
    procedure TestLexicalErrorsCarrySourceLocations;
  end;

  TPascalRegionTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestNestedRoutinesAndUnitSectionsAreSeparate;
    procedure TestExplicitExecutableSectionsDoNotOverlapDeclarations;
    procedure TestProceduralTypesRemainDeclarations;
    procedure TestForwardCompositeKeepsLaterRoutine;
    procedure TestConditionalAlternateRoutineBodiesRemainOneRoutine;
    procedure TestConditionalRoutineDeclarationStartsNewRegion;
    procedure TestProgramBodyIsExecutable;
    procedure TestImplicitUnitInitializationIsExecutable;
    procedure TestAssemblerRoutineBodyIsExecutable;
    procedure TestRoutineDeclarationKindsAndNoBody;
    procedure TestEmptyAndInterfaceOnlySources;
  end;

function RegionCount(const ADocument: TLWPTPascalDocument;
  const AKind: TLWPTPascalRegionKind): Integer;
var
  RegionIndex: Integer;
begin
  Result := 0;
  for RegionIndex := 0 to High(ADocument.Regions) do
    if ADocument.Regions[RegionIndex].Kind = AKind then Inc(Result);
end;

procedure TPascalTokenizerTests.TestNormalizationAndLocations;
var
  Tokens: TLWPTPascalTokenArray;
begin
  Tokens := TokenizePascal('Foo := &BEGIN + #$41;'#13#10'Bar', 'sample.pas');
  Expect<Integer>(Length(Tokens)).ToBe(7);
  Expect<string>(Tokens[0].Text).ToBe('foo');
  Expect<Integer>(Ord(Tokens[0].Kind)).ToBe(Ord(ptIdentifier));
  Expect<string>(Tokens[2].Text).ToBe('begin');
  Expect<Integer>(Ord(Tokens[2].Kind)).ToBe(Ord(ptIdentifier));
  Expect<string>(Tokens[4].Text).ToBe('#$41');
  Expect<Integer>(Ord(Tokens[4].Kind)).ToBe(Ord(ptString));
  Expect<Integer>(Tokens[6].Line).ToBe(2);
  Expect<Integer>(Tokens[6].Column).ToBe(1);
  Expect<Integer>(Tokens[6].Offset).ToBe(23);
end;

procedure TPascalTokenizerTests.TestCommentsDisappearAndDirectivesRemain;
var
  Tokens: TLWPTPascalTokenArray;
begin
  Tokens := TokenizePascal(
    '{ comment (* nested *) } Alpha // tail'#10'{$IFDEF X} Beta');
  Expect<Integer>(Length(Tokens)).ToBe(3);
  Expect<string>(Tokens[0].Text).ToBe('alpha');
  Expect<Integer>(Ord(Tokens[1].Kind)).ToBe(Ord(ptDirective));
  Expect<string>(Tokens[1].Text).ToBe('{$IFDEF X}');
  Expect<string>(Tokens[2].Text).ToBe('beta');
end;

procedure TPascalTokenizerTests.TestBraceCommentsIgnoreOtherDelimiters;
var
  Tokens: TLWPTPascalTokenArray;
begin
  Tokens := TokenizePascal('{ comment (* remains text } Alpha');
  Expect<Integer>(Length(Tokens)).ToBe(1);
  Expect<string>(Tokens[0].Text).ToBe('alpha');
  Tokens := TokenizePascal('{ comment // remains text } Gamma');
  Expect<Integer>(Length(Tokens)).ToBe(1);
  Expect<string>(Tokens[0].Text).ToBe('gamma');
end;

procedure TPascalTokenizerTests.TestParenCommentsIgnoreOtherDelimiters;
var
  Tokens: TLWPTPascalTokenArray;
begin
  Tokens := TokenizePascal('(* comment { remains text *) Beta');
  Expect<Integer>(Length(Tokens)).ToBe(1);
  Expect<string>(Tokens[0].Text).ToBe('beta');
  Tokens := TokenizePascal('(* comment // remains text *) Delta');
  Expect<Integer>(Length(Tokens)).ToBe(1);
  Expect<string>(Tokens[0].Text).ToBe('delta');
end;

procedure TPascalTokenizerTests.TestReservedWordsAndEscapedIdentifiers;
var
  Tokens: TLWPTPascalTokenArray;
begin
  Tokens := TokenizePascal('self string &self &string');
  Expect<Integer>(Length(Tokens)).ToBe(4);
  Expect<Integer>(Ord(Tokens[0].Kind)).ToBe(Ord(ptKeyword));
  Expect<Integer>(Ord(Tokens[1].Kind)).ToBe(Ord(ptKeyword));
  Expect<Integer>(Ord(Tokens[2].Kind)).ToBe(Ord(ptIdentifier));
  Expect<Integer>(Ord(Tokens[3].Kind)).ToBe(Ord(ptIdentifier));
  Expect<string>(Tokens[2].Text).ToBe('self');
  Expect<string>(Tokens[3].Text).ToBe('string');
end;

procedure TPascalTokenizerTests.TestCommentNestingFollowsSourceMode;
var
  Tokens: TLWPTPascalTokenArray;
begin
  Tokens := TokenizePascal(
    '{$mode delphi}{ pass { to open a block } Alpha');
  Expect<Integer>(Length(Tokens)).ToBe(2);
  Expect<string>(Tokens[1].Text).ToBe('alpha');

  Tokens := TokenizePascal('{$mode delphi}{$modeswitch nestedcomments+}'
    + '{ outer { nested } still comment } Beta');
  Expect<Integer>(Length(Tokens)).ToBe(3);
  Expect<string>(Tokens[2].Text).ToBe('beta');
end;

procedure TPascalTokenizerTests.TestLexicalErrorsCarrySourceLocations;
var
  MessageText: string;
begin
  MessageText := '';
  try
    TokenizePascal('ok'#10'(* never closes', 'broken.pas');
  except
    on Error: ELWPTPascalAnalysisError do MessageText := Error.Message;
  end;
  Expect<Boolean>(Pos('broken.pas(2,1)', MessageText) > 0).ToBe(True);
  Expect<Boolean>(Pos('unterminated comment', MessageText) > 0).ToBe(True);
end;

procedure TPascalTokenizerTests.SetupTests;
begin
  Test('normalizes tokens and records byte locations',
    TestNormalizationAndLocations);
  Test('drops comments but retains compiler directives',
    TestCommentsDisappearAndDirectivesRemain);
  Test('brace comments ignore other comment delimiters',
    TestBraceCommentsIgnoreOtherDelimiters);
  Test('parenthesis-star comments ignore other comment delimiters',
    TestParenCommentsIgnoreOtherDelimiters);
  Test('classifies reserved words and escaped identifiers',
    TestReservedWordsAndEscapedIdentifiers);
  Test('follows source mode when nesting active-style comments',
    TestCommentNestingFollowsSourceMode);
  Test('reports lexical errors with source locations',
    TestLexicalErrorsCarrySourceLocations);
end;

procedure TPascalRegionTests.TestNestedRoutinesAndUnitSectionsAreSeparate;
const
  SOURCE =
    'unit Demo;'#10'interface'#10'procedure PublicOnly;'#10
    + 'implementation'#10'procedure Outer;'#10'var X: Integer;'#10
    + 'type TCallback = procedure(Value: Integer);'#10
    + '  procedure Inner;'#10'  begin X := 1; end;'#10
    + 'begin Inner; end;'#10'initialization'#10'Outer;'#10
    + 'finalization'#10'Outer;'#10'end.';
var
  Document: TLWPTPascalDocument;
  InnerBody, OuterBody: TLWPTPascalRegion;
begin
  Document := AnalyzePascal(SOURCE, 'demo.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(2);
  Expect<string>(Document.Routines[0].Name).ToBe('outer');
  Expect<Integer>(Document.Routines[0].ParentRoutine).ToBe(-1);
  Expect<string>(Document.Routines[1].Name).ToBe('inner');
  Expect<Integer>(Document.Routines[1].ParentRoutine).ToBe(0);
  Expect<Integer>(RegionCount(Document, pgRoutineBody)).ToBe(2);
  Expect<Integer>(RegionCount(Document, pgRoutineDeclarations)).ToBe(1);
  Expect<Integer>(RegionCount(Document, pgInitialization)).ToBe(1);
  Expect<Integer>(RegionCount(Document, pgFinalization)).ToBe(1);
  OuterBody := Document.Regions[Document.Routines[0].BodyRegion];
  InnerBody := Document.Regions[Document.Routines[1].BodyRegion];
  Expect<Boolean>(InnerBody.Tokens.EndToken <= OuterBody.Tokens.StartToken)
    .ToBe(True);
  Expect<Boolean>(PascalRegionIsExecutable(pgRoutineDeclarations)).ToBe(False);
  Expect<Boolean>(PascalRegionIsExecutable(pgRoutineBody)).ToBe(True);
end;

procedure TPascalRegionTests.TestProceduralTypesRemainDeclarations;
const
  SOURCE =
    'unit Backend;'#10'interface'#10'implementation'#10'type'#10
    + '  TReadCallback = function(Buffer: Pointer): Integer; cdecl;'#10
    + '  TWriteCallback = procedure(Buffer: Pointer); cdecl;'#10
    + '  ICallback = interface'#10'    procedure Invoke;'#10'  end;'#10
    + 'procedure Run;'#10'type TLocalCallback = procedure(Value: Integer);'#10
    + 'begin end;'#10'end.';
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(SOURCE, 'backend.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(1);
  Expect<string>(Document.Routines[0].Name).ToBe('run');
  Expect<Integer>(Document.Routines[0].ParentRoutine).ToBe(-1);
  Expect<Boolean>(Document.Routines[0].BodyRegion >= 0).ToBe(True);
end;

procedure TPascalRegionTests.TestForwardCompositeKeepsLaterRoutine;
const
  SOURCE =
    'unit ForwardComposite;'#10'interface'#10'implementation'#10'type'#10
    + '  TThing = class;'#10'procedure Later;'#10'begin'#10'end;'#10'end.';
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(SOURCE, 'forward-composite.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(1);
  Expect<string>(Document.Routines[0].Name).ToBe('later');
  Expect<Boolean>(Document.Routines[0].BodyRegion >= 0).ToBe(True);
  Expect<Integer>(RegionCount(Document, pgRoutineBody)).ToBe(1);
end;

procedure TPascalRegionTests.
  TestConditionalAlternateRoutineBodiesRemainOneRoutine;
const
  SOURCE =
    'unit ConditionalBodies;'#10'interface'#10'implementation'#10
    + 'function OwnerGuardHeld: Boolean;'#10
    + '{$IFDEF UNIX}'#10'var UnixValue: Boolean;'#10
    + 'begin Result := UnixValue; end;'#10'{$ENDIF}'#10
    + '{$IFDEF MSWINDOWS}'#10'var WindowsValue: Boolean;'#10
    + 'begin Result := WindowsValue; end;'#10'{$ENDIF}'#10
    + 'function Next: Boolean;'#10'begin Result := True; end;'#10'end.';
var
  Document: TLWPTPascalDocument;
  FirstBody: TLWPTPascalRegion;
begin
  Document := AnalyzePascal(SOURCE, 'conditional-bodies.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(2);
  Expect<string>(Document.Routines[0].Name).ToBe('ownerguardheld');
  Expect<string>(Document.Routines[1].Name).ToBe('next');
  Expect<Integer>(RegionCount(Document, pgRoutineBody)).ToBe(2);
  Expect<Integer>(RegionCount(Document, pgInitialization)).ToBe(0);
  FirstBody := Document.Regions[Document.Routines[0].BodyRegion];
  Expect<Integer>(FirstBody.Tokens.EndToken).ToBe(
    Document.Routines[1].Header.StartToken);
end;

procedure TPascalRegionTests.TestConditionalRoutineDeclarationStartsNewRegion;
const
  SOURCE =
    'unit ConditionalRoutine;'#10'interface'#10'implementation'#10
    + 'procedure Outer;'#10'begin end;'#10
    + '{$IFDEF X}'#10'procedure Helper;'#10'begin end;'#10'{$ENDIF}'#10
    + 'end.';
var
  Document: TLWPTPascalDocument;
  OuterBody: TLWPTPascalRegion;
begin
  Document := AnalyzePascal(SOURCE, 'conditional-routine.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(2);
  Expect<string>(Document.Routines[0].Name).ToBe('outer');
  Expect<string>(Document.Routines[1].Name).ToBe('helper');
  Expect<Integer>(RegionCount(Document, pgRoutineBody)).ToBe(2);
  OuterBody := Document.Regions[Document.Routines[0].BodyRegion];
  Expect<Boolean>(OuterBody.Tokens.EndToken <=
    Document.Routines[1].Header.StartToken).ToBe(True);
end;

procedure TPascalRegionTests.
  TestExplicitExecutableSectionsDoNotOverlapDeclarations;
const
  SOURCE =
    'unit Sections;'#10'interface'#10'const PublicValue = 1;'#10
    + 'implementation'#10'var Initialized: Boolean;'#10
    + 'initialization'#10'Initialized := True;'#10
    + 'finalization'#10'Initialized := False;'#10'end.';
var
  DeclarationRegion, FinalizationRegion, InitializationRegion:
    TLWPTPascalRegion;
  DeclarationCount, DeclarationIndex, FinalizationIndex,
    InitializationIndex: Integer;
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(SOURCE, 'sections.pas');
  InitializationIndex := -1;
  FinalizationIndex := -1;
  for DeclarationIndex := 0 to High(Document.Regions) do
    case Document.Regions[DeclarationIndex].Kind of
      pgInitialization: InitializationIndex := DeclarationIndex;
      pgFinalization: FinalizationIndex := DeclarationIndex;
    end;
  Expect<Boolean>((InitializationIndex >= 0) and
    (FinalizationIndex >= 0)).ToBe(True);
  if (InitializationIndex < 0) or (FinalizationIndex < 0) then Exit;
  InitializationRegion := Document.Regions[InitializationIndex];
  FinalizationRegion := Document.Regions[FinalizationIndex];
  Expect<string>(Document.Tokens[
    InitializationRegion.Tokens.StartToken - 1].Text).ToBe('initialization');
  Expect<string>(Document.Tokens[
    FinalizationRegion.Tokens.StartToken - 1].Text).ToBe('finalization');
  Expect<Boolean>(InitializationRegion.Tokens.EndToken <=
    FinalizationRegion.Tokens.StartToken).ToBe(True);
  DeclarationCount := 0;
  for DeclarationIndex := 0 to High(Document.Regions) do
    if Document.Regions[DeclarationIndex].Kind = pgUnitDeclarations then
    begin
      Inc(DeclarationCount);
      DeclarationRegion := Document.Regions[DeclarationIndex];
      Expect<Boolean>(DeclarationRegion.Tokens.EndToken <=
        InitializationRegion.Tokens.StartToken - 1).ToBe(True);
      Expect<Boolean>((DeclarationRegion.Tokens.EndToken <=
        InitializationRegion.Tokens.StartToken) or
        (DeclarationRegion.Tokens.StartToken >=
          InitializationRegion.Tokens.EndToken)).ToBe(True);
      Expect<Boolean>((DeclarationRegion.Tokens.EndToken <=
        FinalizationRegion.Tokens.StartToken) or
        (DeclarationRegion.Tokens.StartToken >=
          FinalizationRegion.Tokens.EndToken)).ToBe(True);
    end;
  Expect<Boolean>(DeclarationCount > 0).ToBe(True);
  Expect<Boolean>(PascalRegionIsExecutable(pgUnitDeclarations)).ToBe(False);
  Expect<Boolean>(PascalRegionIsExecutable(pgInitialization)).ToBe(True);
  Expect<Boolean>(PascalRegionIsExecutable(pgFinalization)).ToBe(True);
end;

procedure TPascalRegionTests.TestProgramBodyIsExecutable;
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(
    'program Demo; var X: Integer; begin X := 1; end.', 'demo.lpr');
  Expect<Integer>(RegionCount(Document, pgUnitDeclarations)).ToBe(1);
  Expect<Integer>(RegionCount(Document, pgProgramBody)).ToBe(1);
  Expect<Boolean>(PascalRegionIsExecutable(pgProgramBody)).ToBe(True);
end;

procedure TPascalRegionTests.TestImplicitUnitInitializationIsExecutable;
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(
    'unit Demo; interface implementation begin WriteLn; end.', 'demo.pas');
  Expect<Integer>(RegionCount(Document, pgInitialization)).ToBe(1);
  Expect<Boolean>(PascalRegionIsExecutable(pgInitialization)).ToBe(True);
end;

procedure TPascalRegionTests.TestAssemblerRoutineBodyIsExecutable;
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(
    'program Demo; procedure MachineCode; assembler; asm nop end; '
    + 'begin MachineCode; end.', 'demo.lpr');
  Expect<Integer>(Length(Document.Routines)).ToBe(1);
  Expect<Boolean>(Document.Routines[0].BodyRegion >= 0).ToBe(True);
  Expect<Integer>(Ord(Document.Regions[
    Document.Routines[0].BodyRegion].Kind)).ToBe(Ord(pgRoutineBody));
  Expect<Integer>(RegionCount(Document, pgProgramBody)).ToBe(1);
end;

procedure TPascalRegionTests.TestRoutineDeclarationKindsAndNoBody;
const
  SOURCE =
    'unit Kinds;'#10'interface'#10'implementation'#10
    + 'procedure Deferred; forward;'#10
    + 'procedure Imported; external;'#10
    + 'constructor TObject.Create; begin end;'#10
    + 'destructor TObject.Destroy; begin end;'#10
    + 'operator +(Left, Right: Integer): Integer; begin Result := Left; end;'#10
    + 'end.';
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal(SOURCE, 'kinds.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(5);
  Expect<Integer>(Document.Routines[0].BodyRegion).ToBe(-1);
  Expect<Integer>(Document.Routines[1].BodyRegion).ToBe(-1);
  Expect<Integer>(Ord(Document.Routines[2].Kind)).ToBe(Ord(prConstructor));
  Expect<Integer>(Ord(Document.Routines[3].Kind)).ToBe(Ord(prDestructor));
  Expect<Integer>(Ord(Document.Routines[4].Kind)).ToBe(Ord(prOperator));
end;

procedure TPascalRegionTests.TestEmptyAndInterfaceOnlySources;
var
  Document: TLWPTPascalDocument;
begin
  Document := AnalyzePascal('', 'empty.pas');
  Expect<Integer>(Length(Document.Tokens)).ToBe(0);
  Expect<Integer>(Length(Document.Regions)).ToBe(0);
  Document := AnalyzePascal(
    'unit API; interface procedure PublicOnly; end.', 'api.pas');
  Expect<Integer>(Length(Document.Routines)).ToBe(0);
  Expect<Integer>(Length(Document.Regions)).ToBe(0);
end;

procedure TPascalRegionTests.SetupTests;
begin
  Test('separates nested routine bodies, declarations, and unit sections',
    TestNestedRoutinesAndUnitSectionsAreSeparate);
  Test('keeps explicit initialization and finalization out of declarations',
    TestExplicitExecutableSectionsDoNotOverlapDeclarations);
  Test('keeps implementation and local procedural types in declarations',
    TestProceduralTypesRemainDeclarations);
  Test('keeps routines after forward composite declarations',
    TestForwardCompositeKeepsLaterRoutine);
  Test('keeps conditional alternate bodies in one routine region',
    TestConditionalAlternateRoutineBodiesRemainOneRoutine);
  Test('keeps conditional routine declarations in separate regions',
    TestConditionalRoutineDeclarationStartsNewRegion);
  Test('types a program main block as executable', TestProgramBodyIsExecutable);
  Test('types an implicit unit initialization block as executable',
    TestImplicitUnitInitializationIsExecutable);
  Test('types assembler routine bodies as executable',
    TestAssemblerRoutineBodyIsExecutable);
  Test('classifies routine kinds and bodyless declarations',
    TestRoutineDeclarationKindsAndNoBody);
  Test('handles empty and interface-only source documents',
    TestEmptyAndInterfaceOnlySources);
end;

begin
  TestRunnerProgram.AddSuite(TPascalTokenizerTests.Create(
    PROJECT_NAME + '.Analysis.Pascal: tokenizer'));
  TestRunnerProgram.AddSuite(TPascalRegionTests.Create(
    PROJECT_NAME + '.Analysis.Pascal: typed regions'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
