{ LWPT.Duplication.Test — Type-2 clone detector and policy coverage. }
program LWPT.Duplication.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Analysis.Scope,
  LWPT.Core,
  LWPT.Duplication,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  TDuplicationTests = class(TTestSuite)
  private
    FRoot: string;
    procedure CreateProject(const AName, AConfiguration: string;
      const ASources: array of string);
    function ProjectPath(const AName: string): string;
    function RunProject(const AName: string): TLWPTDuplicationReport;
    procedure WriteText(const APath, AText: string);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestType2ClonesIgnorePresentationAndRenameConsistently;
    procedure TestInconsistentRenamingDoesNotMatch;
    procedure TestSameFileOccurrencesDoNotOverlap;
    procedure TestDeclarationAndExecutableRegionsDoNotMix;
    procedure TestNestedRoutineBoundariesAreNotCrossed;
    procedure TestRepetitiveSourceCompletesWithinPracticalBound;
    procedure TestGroupsMaximalNonOverlappingOccurrences;
    procedure TestConfiguredMinimumIncludesExactBoundary;
    procedure TestThresholdIsOptionalAndStrictlyExceeded;
    procedure TestManifestRejectsMinimumBelowFloor;
    procedure TestManifestRejectsInvalidMaximumPercent;
    procedure TestWorkspaceOverridesRootMinimumAndAnalysisExclusion;
    procedure TestWorkspaceInheritsOrReplacesRootDuplicationPolicy;
  end;

const
  BODY_ONE =
    'program One;'#10'var A, B, C: Integer;'#10'begin'#10
    + '  A := 1; B := A + 2; C := B * 3;'#10
    + '  if C > A then B := C - A;'#10
    + '  WriteLn(B);'#10'end.'#10;
  BODY_TWO =
    'PROGRAM Two;'#10'var Left, Right, Total: Integer;'#10'begin'#10
    + '  Left:=11; { ignored } Right := Left + 12;'#10
    + '  Total := Right * 13;'#10
    + '  IF Total > Left THEN Right := Total - Left;'#10
    + '  writeln(Right);'#10'end.'#10;
  BODY_THREE =
    'program Three;'#10'var X, Y, Z: Integer;'#10'begin'#10
    + '  X := 21; Y := X + 22; Z := Y * 23;'#10
    + '  if Z > X then Y := Z - X;'#10
    + '  WriteLn(Y);'#10'end.'#10;

procedure TDuplicationTests.WriteText(const APath, AText: string);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

function TDuplicationTests.ProjectPath(const AName: string): string;
begin
  Result := FRoot + '/' + AName;
end;

procedure TDuplicationTests.CreateProject(const AName,
  AConfiguration: string; const ASources: array of string);
var
  SourceIndex: Integer;
begin
  ForceDirectories(ProjectPath(AName) + '/source');
  WriteText(ProjectPath(AName) + '/lwpt.toml',
    '[package]'#10'name = "' + AName + '"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + AConfiguration);
  for SourceIndex := 0 to High(ASources) do
    WriteText(ProjectPath(AName) + '/source/program'
      + IntToStr(SourceIndex + 1) + '.lpr', ASources[SourceIndex]);
end;

function TDuplicationTests.RunProject(const AName: string):
  TLWPTDuplicationReport;
begin
  Result := AnalyzeDuplication(ResolveAnalysisScope(
    ProjectPath(AName) + '/lwpt.toml'));
end;

procedure TDuplicationTests.BeforeAll;
begin
  FRoot := ExpandFileName('build/tests/tmp/duplication');
  if DirectoryExists(FRoot) then WipeDir(FRoot);
  ForceDirectories(FRoot);
end;

procedure TDuplicationTests.
  TestType2ClonesIgnorePresentationAndRenameConsistently;
var
  Report: TLWPTDuplicationReport;
begin
  CreateProject('type2', '[duplication]'#10'minimum-tokens = 25'#10,
    [BODY_ONE, BODY_TWO]);
  Report := RunProject('type2');
  Expect<Integer>(Length(Report.Groups)).ToBe(1);
  Expect<Integer>(Length(Report.Groups[0].Occurrences)).ToBe(2);
  Expect<Boolean>(Report.Groups[0].TokenCount >= 25).ToBe(True);
  Expect<string>(Report.Groups[0].Occurrences[0].FileName).ToBe(
    'source/program1.lpr');
  Expect<string>(Report.Groups[0].Occurrences[1].FileName).ToBe(
    'source/program2.lpr');
end;

procedure TDuplicationTests.TestInconsistentRenamingDoesNotMatch;
const
  INCONSISTENT =
    'program Broken;'#10'var Left, Right, Total: Integer;'#10'begin'#10
    + '  Left:=11; Right := Left + 12; Total := Right * 13;'#10
    + '  if Total > Right then Right := Total - Left;'#10
    + '  WriteLn(Right);'#10'end.'#10;
var
  Report: TLWPTDuplicationReport;
begin
  CreateProject('inconsistent',
    '[duplication]'#10'minimum-tokens = 25'#10,
    [BODY_ONE, INCONSISTENT]);
  Report := RunProject('inconsistent');
  Expect<Integer>(Length(Report.Groups)).ToBe(0);
  Expect<Int64>(Report.DuplicateTokens).ToBe(0);
end;

procedure TDuplicationTests.TestSameFileOccurrencesDoNotOverlap;
const
  SAME_FILE =
    'program SameFile;'#10
    + 'procedure First; var A, B, C: Integer; begin'#10
    + 'A:=1; B:=A+2; C:=B*3; if C>A then B:=C-A; WriteLn(B); end;'#10
    + 'procedure Second; var X, Y, Z: Integer; begin'#10
    + 'X:=4; Y:=X+5; Z:=Y*6; if Z>X then Y:=Z-X; WriteLn(Y); end;'#10
    + 'begin First; Second end.'#10;
var
  Report: TLWPTDuplicationReport;
begin
  CreateProject('same-file',
    '[duplication]'#10'minimum-tokens = 25'#10, [SAME_FILE]);
  Report := RunProject('same-file');
  Expect<Integer>(Length(Report.Groups)).ToBe(1);
  Expect<Integer>(Length(Report.Groups[0].Occurrences)).ToBe(2);
  Expect<string>(Report.Groups[0].Occurrences[0].FileName).ToBe(
    'source/program1.lpr');
  Expect<string>(Report.Groups[0].Occurrences[1].FileName).ToBe(
    'source/program1.lpr');
  Expect<Boolean>(Report.Groups[0].Occurrences[0].StartLine <
    Report.Groups[0].Occurrences[1].StartLine).ToBe(True);
end;

procedure TDuplicationTests.TestDeclarationAndExecutableRegionsDoNotMix;
var
  DirectiveIndex: Integer;
  DirectiveRun, ExecutableSource, DeclarationSource: string;
  Report: TLWPTDuplicationReport;
begin
  DirectiveRun := '';
  for DirectiveIndex := 1 to 30 do
    DirectiveRun := DirectiveRun + '{$define boundary'
      + IntToStr(DirectiveIndex) + '}'#10;
  DeclarationSource := 'unit DeclarationBoundary;'#10'interface'#10
    + DirectiveRun + 'implementation'#10'end.'#10;
  ExecutableSource := 'program ExecutableBoundary;'#10'begin'#10
    + DirectiveRun + 'end.'#10;
  CreateProject('typed-boundary',
    '[duplication]'#10'minimum-tokens = 25'#10,
    [DeclarationSource, ExecutableSource]);
  Report := RunProject('typed-boundary');
  Expect<Integer>(Length(Report.Groups)).ToBe(0);
end;

procedure TDuplicationTests.TestNestedRoutineBoundariesAreNotCrossed;
var
  DirectiveIndex: Integer;
  FirstHalf, FlatSource, SecondHalf, SplitSource: string;
  Report: TLWPTDuplicationReport;
begin
  FirstHalf := '';
  SecondHalf := '';
  for DirectiveIndex := 1 to 30 do
    if DirectiveIndex <= 15 then
      FirstHalf := FirstHalf + '{$define nested'
        + IntToStr(DirectiveIndex) + '}'#10
    else
      SecondHalf := SecondHalf + '{$define nested'
        + IntToStr(DirectiveIndex) + '}'#10;
  SplitSource := 'program SplitNested;'#10'procedure Outer;'#10
    + 'procedure Inner; begin'#10 + FirstHalf + 'end;'#10
    + 'begin'#10 + SecondHalf + 'end;'#10'begin Outer end.'#10;
  FlatSource := 'program FlatNested;'#10'begin'#10 + FirstHalf
    + SecondHalf + 'end.'#10;
  CreateProject('nested-boundary',
    '[duplication]'#10'minimum-tokens = 25'#10,
    [SplitSource, FlatSource]);
  Report := RunProject('nested-boundary');
  Expect<Integer>(Length(Report.Groups)).ToBe(0);
end;

procedure TDuplicationTests.
  TestRepetitiveSourceCompletesWithinPracticalBound;
var
  Elapsed: QWord;
  RepetitionIndex: Integer;
  Report: TLWPTDuplicationReport;
  Source: string;
begin
  Source := 'program Repetitive; var A: Integer; begin'#10;
  for RepetitionIndex := 1 to 400 do
    Source := Source + 'A := A + 1;'#10;
  Source := Source + 'end.'#10;
  CreateProject('repetitive',
    '[duplication]'#10'minimum-tokens = 25'#10, [Source]);
  Elapsed := GetTickCount64;
  Report := RunProject('repetitive');
  Elapsed := GetTickCount64 - Elapsed;
  Expect<Integer>(Length(Report.Groups)).ToBe(1);
  Expect<Integer>(Report.Groups[0].TokenCount).ToBe(1200);
  Expect<Integer>(Length(Report.Groups[0].Occurrences)).ToBe(2);
  Expect<Boolean>(Elapsed < 10000).ToBe(True);
end;

procedure TDuplicationTests.TestGroupsMaximalNonOverlappingOccurrences;
var
  Report: TLWPTDuplicationReport;
begin
  CreateProject('grouped', '[duplication]'#10'minimum-tokens = 25'#10,
    [BODY_ONE, BODY_TWO, BODY_THREE]);
  Report := RunProject('grouped');
  Expect<Integer>(Length(Report.Groups)).ToBe(1);
  Expect<Integer>(Length(Report.Groups[0].Occurrences)).ToBe(3);
  Expect<Int64>(Report.DuplicateTokens).ToBe(
    Int64(Report.Groups[0].TokenCount) * 2);
end;

procedure TDuplicationTests.TestConfiguredMinimumIncludesExactBoundary;
const
  EXACT_ONE =
    'program ExactOne; begin A:=1; B:=2; C:=3; D:=4; E:=5; F:=6 end.';
  EXACT_TWO =
    'program ExactTwo; begin G:=7; H:=8; I:=9; J:=10; K:=11; L:=12 end.';
var
  Report: TLWPTDuplicationReport;
begin
  CreateProject('boundary', '[duplication]'#10'minimum-tokens = 25'#10,
    [EXACT_ONE, EXACT_TWO]);
  Report := RunProject('boundary');
  Expect<Integer>(Length(Report.Groups)).ToBe(1);
  Expect<Integer>(Report.Groups[0].TokenCount).ToBe(25);
end;

procedure TDuplicationTests.TestThresholdIsOptionalAndStrictlyExceeded;
var
  Report: TLWPTDuplicationReport;
begin
  CreateProject('report-only', '[duplication]'#10'minimum-tokens = 25'#10,
    [BODY_ONE, BODY_TWO]);
  Report := RunProject('report-only');
  Expect<Boolean>(Report.ThresholdConfigured).ToBe(False);
  Expect<Boolean>(Report.ThresholdFailed).ToBe(False);

  CreateProject('threshold', '[duplication]'#10'minimum-tokens = 25'#10
    + 'maximum-percent = 0'#10, [BODY_ONE, BODY_TWO]);
  Report := RunProject('threshold');
  Expect<Boolean>(Report.ThresholdConfigured).ToBe(True);
  Expect<Boolean>(Report.ThresholdFailed).ToBe(True);
  Expect<Integer>(Length(Report.Diagnostics)).ToBe(1);

  CreateProject('threshold-pass',
    '[duplication]'#10'minimum-tokens = 25'#10
    + 'maximum-percent = 100'#10, [BODY_ONE, BODY_TWO]);
  Report := RunProject('threshold-pass');
  Expect<Boolean>(Report.ThresholdConfigured).ToBe(True);
  Expect<Boolean>(Report.ThresholdFailed).ToBe(False);
end;

procedure TDuplicationTests.TestManifestRejectsMinimumBelowFloor;
var
  Raised: Boolean;
begin
  CreateProject('invalid', '[duplication]'#10'minimum-tokens = 24'#10,
    [BODY_ONE]);
  Raised := False;
  try
    LoadManifest(ProjectPath('invalid') + '/lwpt.toml');
  except
    on EManifestError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TDuplicationTests.TestManifestRejectsInvalidMaximumPercent;
var
  Raised: Boolean;
begin
  CreateProject('invalid-maximum',
    '[duplication]'#10'maximum-percent = 101'#10, [BODY_ONE]);
  Raised := False;
  try
    LoadManifest(ProjectPath('invalid-maximum') + '/lwpt.toml');
  except
    on EManifestError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);

  CreateProject('invalid-maximum-type',
    '[duplication]'#10'maximum-percent = "ten"'#10, [BODY_ONE]);
  Raised := False;
  try
    LoadManifest(ProjectPath('invalid-maximum-type') + '/lwpt.toml');
  except
    on EManifestError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TDuplicationTests.
  TestWorkspaceOverridesRootMinimumAndAnalysisExclusion;
var
  Report: TLWPTDuplicationReport;
  RootPath: string;
begin
  RootPath := ProjectPath('workspace');
  ForceDirectories(RootPath + '/source');
  ForceDirectories(RootPath + '/packages/child/source');
  WriteText(RootPath + '/lwpt.toml',
    '[package]'#10'name = "workspace-root"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10'[workspaces]'#10
    + 'include = ["packages/*"]'#10'[duplication]'#10
    + 'minimum-tokens = 100'#10);
  WriteText(RootPath + '/packages/child/lwpt.toml',
    '[package]'#10'name = "child"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10'[analysis]'#10
    + 'exclude = ["source/excluded.lpr"]'#10'[duplication]'#10
    + 'minimum-tokens = 25'#10);
  WriteText(RootPath + '/packages/child/source/one.lpr', BODY_ONE);
  WriteText(RootPath + '/packages/child/source/two.lpr', BODY_TWO);
  WriteText(RootPath + '/packages/child/source/excluded.lpr', BODY_THREE);

  Report := AnalyzeDuplication(ResolveAnalysisScope(
    RootPath + '/lwpt.toml'));
  Expect<Integer>(Length(Report.Configurations)).ToBe(2);
  Expect<Integer>(Report.Configurations[0].MinimumTokens).ToBe(100);
  Expect<Integer>(Report.Configurations[1].MinimumTokens).ToBe(25);
  Expect<Integer>(Length(Report.Groups)).ToBe(1);
  Expect<Integer>(Length(Report.Groups[0].Occurrences)).ToBe(2);
end;

procedure TDuplicationTests.
  TestWorkspaceInheritsOrReplacesRootDuplicationPolicy;
var
  Report: TLWPTDuplicationReport;
  RootPath: string;
begin
  RootPath := ProjectPath('workspace-policy');
  ForceDirectories(RootPath + '/source');
  ForceDirectories(RootPath + '/packages/inherited/source');
  ForceDirectories(RootPath + '/packages/replaced/source');
  WriteText(RootPath + '/lwpt.toml',
    '[package]'#10'name = "policy-root"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10'[workspaces]'#10
    + 'include = ["packages/*"]'#10'[duplication]'#10
    + 'minimum-tokens = 75'#10'maximum-percent = 0'#10);
  WriteText(RootPath + '/source/root.lpr', BODY_ONE);
  WriteText(RootPath + '/packages/inherited/lwpt.toml',
    '[package]'#10'name = "inherited"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteText(RootPath + '/packages/inherited/source/inherited.lpr', BODY_ONE);
  WriteText(RootPath + '/packages/replaced/lwpt.toml',
    '[package]'#10'name = "replaced"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10'[duplication]'#10
    + 'minimum-tokens = 25'#10);
  WriteText(RootPath + '/packages/replaced/source/replaced.lpr', BODY_TWO);

  Report := AnalyzeDuplication(ResolveAnalysisScope(
    RootPath + '/lwpt.toml'));
  Expect<Integer>(Length(Report.Configurations)).ToBe(3);
  Expect<string>(Report.Configurations[0].ProjectName).ToBe('policy-root');
  Expect<Integer>(Report.Configurations[0].MinimumTokens).ToBe(75);
  Expect<Boolean>(Report.Configurations[0].MaximumPercentConfigured).
    ToBe(True);
  Expect<string>(Report.Configurations[1].ProjectName).ToBe('inherited');
  Expect<Integer>(Report.Configurations[1].MinimumTokens).ToBe(75);
  Expect<Boolean>(Report.Configurations[1].MaximumPercentConfigured).
    ToBe(True);
  Expect<string>(Report.Configurations[2].ProjectName).ToBe('replaced');
  Expect<Integer>(Report.Configurations[2].MinimumTokens).ToBe(25);
  Expect<Boolean>(Report.Configurations[2].MaximumPercentConfigured).
    ToBe(False);
end;

procedure TDuplicationTests.SetupTests;
begin
  Test('detects Type-2 clones across comments case and consistent renaming',
    TestType2ClonesIgnorePresentationAndRenameConsistently);
  Test('rejects inconsistent identifier equality mappings',
    TestInconsistentRenamingDoesNotMatch);
  Test('keeps same-file clone occurrences non-overlapping',
    TestSameFileOccurrencesDoNotOverlap);
  Test('does not mix declaration and executable regions',
    TestDeclarationAndExecutableRegionsDoNotMix);
  Test('does not cross nested routine boundaries',
    TestNestedRoutineBoundariesAreNotCrossed);
  Test('bounds repetitive-source candidate generation',
    TestRepetitiveSourceCompletesWithinPracticalBound);
  Test('groups maximal non-overlapping occurrences deterministically',
    TestGroupsMaximalNonOverlappingOccurrences);
  Test('includes matches exactly at the configured minimum',
    TestConfiguredMinimumIncludesExactBoundary);
  Test('is report-only unless a strict maximum is configured',
    TestThresholdIsOptionalAndStrictlyExceeded);
  Test('rejects a pathological clone floor below 25',
    TestManifestRejectsMinimumBelowFloor);
  Test('rejects invalid maximum-percent values and types',
    TestManifestRejectsInvalidMaximumPercent);
  Test('workspace policy overrides root while analysis exclusion remains final',
    TestWorkspaceOverridesRootMinimumAndAnalysisExclusion);
  Test('workspace policy is inherited or replaced as a complete section',
    TestWorkspaceInheritsOrReplacesRootDuplicationPolicy);
end;

begin
  TestRunnerProgram.AddSuite(TDuplicationTests.Create(
    PROJECT_NAME + '.Duplication'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
