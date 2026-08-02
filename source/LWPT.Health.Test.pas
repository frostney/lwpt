{ LWPT.Health.Test — Pascal complexity and threshold contracts. }
program LWPT.Health.Test;

{$I Shared.inc}

uses
  LWPT.Analysis.Pascal,
  LWPT.Core,
  LWPT.Health,
  TestingPascalLibrary;

type
  THealthMetricTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestStraightLineRoutineStartsAtOne;
    procedure TestNestedDecisionsBooleanSequencesRecursionAndGoto;
    procedure TestCaseArmsAndExceptionHandlers;
    procedure TestExceptionFallbackAlwaysAdvances;
    procedure TestDirectRecursionRequiresSelfCall;
    procedure TestConditionalRoutineBodiesRemainRoutine;
    procedure TestConditionalElseRoutineBodiesBothScore;
    procedure TestEscapedKeywordsRemainIdentifiers;
    procedure TestSyntheticSectionsContributeToFileTotals;
    procedure TestLimitsAreStrictAndReportEveryViolation;
    procedure TestHotspotNormalizationExposesRawComponents;
  end;

function AnalyzeSource(const ASource: string): TLWPTHealthFile;
begin
  Result := AnalyzeHealthDocument(AnalyzePascal(ASource, 'demo.pas'),
    'demo', 'demo.pas');
end;

procedure THealthMetricTests.TestStraightLineRoutineStartsAtOne;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; begin WriteLn; end; begin Work; end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(2);
  Expect<string>(HealthFile.Metrics[0].Name).ToBe('work');
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(1);
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(0);
  Expect<Integer>(HealthFile.Cyclomatic).ToBe(2);
  Expect<Integer>(HealthFile.Cognitive).ToBe(0);
end;

procedure THealthMetricTests.
  TestNestedDecisionsBooleanSequencesRecursionAndGoto;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; label Again; begin '#10
    + 'if A and B or C then while D do Work else goto Again; end; '#10
    + 'begin end.');
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(5);
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(8);
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; begin '#10
    + 'if A and then B then C; end; begin end.');
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(3);
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(2);
end;

procedure THealthMetricTests.TestCaseArmsAndExceptionHandlers;
var
  CaseFile, ExceptFile, FinallyFile: TLWPTHealthFile;
  Limits: TLWPTHealthLimits;
  Violations: TLWPTHealthViolationArray;
begin
  CaseFile := AnalyzeSource(
    'program Demo; procedure Work; begin case X of '#10
    + '1: A; 2, 3: B; else C; end; end; begin end.');
  Expect<Integer>(CaseFile.Metrics[0].Cyclomatic).ToBe(3);
  Expect<Integer>(CaseFile.Metrics[0].Cognitive).ToBe(2);
  Limits := DefaultHealthLimits;
  Limits.MaxRoutineCyclomatic := 3;
  SetLength(Violations, 0);
  CollectHealthViolations(CaseFile, Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(0);
  Limits.MaxRoutineCyclomatic := 2;
  CollectHealthViolations(CaseFile, Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(1);
  Expect<Double>(Violations[0].Observed).ToBe(3.0);

  ExceptFile := AnalyzeSource(
    'program Demo; procedure Work; begin try A except '#10
    + 'on E: EOne do B; on E: ETwo do C; end; end; begin end.');
  Expect<Integer>(ExceptFile.Metrics[0].Cyclomatic).ToBe(3);
  Expect<Integer>(ExceptFile.Metrics[0].Cognitive).ToBe(2);

  FinallyFile := AnalyzeSource(
    'program Demo; procedure Work; begin try A finally B end; end; begin end.');
  Expect<Integer>(FinallyFile.Metrics[0].Cyclomatic).ToBe(1);
  Expect<Integer>(FinallyFile.Metrics[0].Cognitive).ToBe(0);
end;

procedure THealthMetricTests.TestExceptionFallbackAlwaysAdvances;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; begin try A except '#10
    + 'on E: EOne do B; else C; end; end; begin end.');
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(3);
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(3);
end;

procedure THealthMetricTests.TestDirectRecursionRequiresSelfCall;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'program Demo; type TThing = class public '#10
    + 'constructor Create; destructor Destroy; procedure Work; end; '#10
    + 'constructor TThing.Create; begin inherited Create; end; '#10
    + 'destructor TThing.Destroy; begin inherited Destroy; end; '#10
    + 'procedure TThing.Work; begin Self.Work; end; begin end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(4);
  Expect<string>(HealthFile.Metrics[0].Name).ToBe('tthing.create');
  Expect<string>(HealthFile.Metrics[1].Name).ToBe('tthing.destroy');
  Expect<string>(HealthFile.Metrics[2].Name).ToBe('tthing.work');
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(0);
  Expect<Integer>(HealthFile.Metrics[1].Cognitive).ToBe(0);
  Expect<Integer>(HealthFile.Metrics[2].Cognitive).ToBe(1);

  HealthFile := AnalyzeSource(
    'program Demo; type TCallback = procedure of object; '#10
    + 'type TThing = class public procedure Capture; end; '#10
    + 'procedure TThing.Capture; var Callback: TCallback; '#10
    + 'begin Callback := @Self.Capture; end; begin end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(2);
  Expect<string>(HealthFile.Metrics[0].Name).ToBe('tthing.capture');
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(0);
end;

procedure THealthMetricTests.TestConditionalRoutineBodiesRemainRoutine;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'unit Demo; interface implementation '#10
    + 'function OwnerGuardHeld: Boolean; '#10
    + '{$IFDEF UNIX} var UnixValue: Boolean; '#10
    + 'begin if UnixValue then Exit(True); Result := False; end; {$ENDIF} '#10
    + '{$IFDEF MSWINDOWS} var WindowsValue: Boolean; '#10
    + 'begin if WindowsValue then Exit(True); Result := False; end; {$ENDIF} '#10
    + 'function Next: Boolean; begin Result := True; end; end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(2);
  Expect<string>(HealthFile.Metrics[0].Name).ToBe('ownerguardheld');
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(3);
  Expect<string>(HealthFile.Metrics[1].Name).ToBe('next');
end;

procedure THealthMetricTests.TestConditionalElseRoutineBodiesBothScore;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; '#10
    + '{$IFDEF UNIX} begin if A then B; end; '#10
    + '{$ELSE} begin if C then D; end; {$ENDIF} '#10
    + 'begin end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(2);
  Expect<string>(HealthFile.Metrics[0].Name).ToBe('work');
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(3);
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(2);
end;

procedure THealthMetricTests.TestEscapedKeywordsRemainIdentifiers;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; var &begin: Boolean; '#10
    + 'begin &begin := True; end; begin end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(2);
  Expect<Integer>(HealthFile.Metrics[0].Cyclomatic).ToBe(1);
  Expect<Integer>(HealthFile.Metrics[0].Cognitive).ToBe(0);
end;

procedure THealthMetricTests.TestSyntheticSectionsContributeToFileTotals;
var
  HealthFile: TLWPTHealthFile;
begin
  HealthFile := AnalyzeSource(
    'unit Demo; interface implementation '#10
    + 'procedure Work; begin if A then B; end; '#10
    + 'initialization while A do B; finalization if C then D; end.');
  Expect<Integer>(Length(HealthFile.Metrics)).ToBe(3);
  Expect<Integer>(HealthFile.Cyclomatic).ToBe(6);
  Expect<Integer>(HealthFile.Cognitive).ToBe(3);
  Expect<string>(HealthFile.Metrics[1].Name).ToBe('<initialization>');
  Expect<string>(HealthFile.Metrics[2].Name).ToBe('<finalization>');
end;

procedure THealthMetricTests.TestLimitsAreStrictAndReportEveryViolation;
var
  HealthFile: TLWPTHealthFile;
  Limits: TLWPTHealthLimits;
  Violations: TLWPTHealthViolationArray;
begin
  HealthFile := AnalyzeSource(
    'program Demo; procedure Work; begin if A then B; end; begin end.');
  Limits := DefaultHealthLimits;
  Limits.MaxRoutineCyclomatic := 2;
  Limits.MaxFileCyclomatic := HealthFile.Cyclomatic;
  SetLength(Violations, 0);
  CollectHealthViolations(HealthFile, Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(0);

  Limits.MaxRoutineCyclomatic := 1;
  Limits.MaxRoutineCognitive := 0;
  Limits.MaxFileCyclomatic := 2;
  Limits.MaxFileCognitive := 0;
  CollectHealthViolations(HealthFile, Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(4);
  Expect<string>(Violations[0].LimitName).ToBe('max-routine-cyclomatic');
  Expect<string>(Violations[3].LimitName).ToBe('max-file-cognitive');

  Limits := DefaultHealthLimits;
  Limits.MaxHotspotScore := 9;
  HealthFile.HotspotScore := 10;
  SetLength(Violations, 0);
  CollectHealthViolations(HealthFile, Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(1);
  Expect<string>(Violations[0].LimitName).ToBe('max-hotspot-score');
end;

procedure THealthMetricTests.TestHotspotNormalizationExposesRawComponents;
var
  Files: TLWPTHealthFileArray;
  Limits: TLWPTHealthLimits;
  Violations: TLWPTHealthViolationArray;
begin
  SetLength(Files, 2);
  Files[0].Cyclomatic := 1;
  Files[0].ChangedLines := 7;
  Files[1].Cyclomatic := 0;
  Files[1].ChangedLines := 25;
  NormalizeHotspots(Files);
  Expect<Double>(Files[0].HotspotScore).ToBe(28.0);
  Expect<Double>(Files[1].HotspotScore).ToBe(0.0);
  Expect<Int64>(Files[0].ChangedLines).ToBe(7);

  Limits := DefaultHealthLimits;
  Limits.MaxHotspotScore := 28;
  SetLength(Violations, 0);
  CollectHealthViolations(Files[0], Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(0);
  Files[0].HotspotScore := 28.0001;
  CollectHealthViolations(Files[0], Limits, Violations);
  Expect<Integer>(Length(Violations)).ToBe(1);
  Expect<Int64>(Round(Violations[0].Observed * 10000)).ToBe(280001);
end;

procedure THealthMetricTests.SetupTests;
begin
  Test('starts straight-line regions at cyclomatic one',
    TestStraightLineRoutineStartsAtOne);
  Test('scores nested decisions, Boolean sequences, recursion, and goto',
    TestNestedDecisionsBooleanSequencesRecursionAndGoto);
  Test('scores case arms and exception handlers',
    TestCaseArmsAndExceptionHandlers);
  Test('scores typed exception handlers followed by a fallback',
    TestExceptionFallbackAlwaysAdvances);
  Test('counts direct recursion but excludes inherited dispatch',
    TestDirectRecursionRequiresSelfCall);
  Test('keeps conditional alternate bodies in their routine',
    TestConditionalRoutineBodiesRemainRoutine);
  Test('scores both branches of a conditional routine body',
    TestConditionalElseRoutineBodiesBothScore);
  Test('does not score escaped keywords as block delimiters',
    TestEscapedKeywordsRemainIdentifiers);
  Test('sums routines and synthetic executable sections into files',
    TestSyntheticSectionsContributeToFileTotals);
  Test('uses strict maxima and reports every violation',
    TestLimitsAreStrictAndReportEveryViolation);
  Test('normalizes transparent complexity and churn components',
    TestHotspotNormalizationExposesRawComponents);
end;

begin
  TestRunnerProgram.AddSuite(THealthMetricTests.Create(
    PROJECT_NAME + '.Health'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
