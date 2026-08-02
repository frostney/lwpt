{ Duplication.Test — binary-level output, scope, and exit-code contract. }
program Duplication.Test;

{$mode delphi}{$H+}

uses
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TDuplicationIntegration = class(TTestSuite)
  private
    FRoot: string;
    procedure CreateProject(const AName, AConfiguration: string;
      const AExcludedThird: Boolean = False);
    function ProjectPath(const AName: string): string;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestHumanReportIsReportOnlyByDefault;
    procedure TestJSONEnvelopeIsByteStable;
    procedure TestThresholdFailureUsesNonzeroExit;
    procedure TestInvalidMinimumIsActionable;
    procedure TestAnalysisExclusionRemovesFileFromScope;
  end;

const
  SOURCE_ONE =
    'program One;'#10'var A, B, C: Integer;'#10'begin'#10
    + '  A := 1; B := A + 2; C := B * 3;'#10
    + '  if C > A then B := C - A;'#10
    + '  WriteLn(B);'#10'end.'#10;
  SOURCE_TWO =
    'program Two;'#10'var Left, Right, Total: Integer;'#10'begin'#10
    + '  Left := 11; Right := Left + 12; Total := Right * 13;'#10
    + '  if Total > Left then Right := Total - Left;'#10
    + '  WriteLn(Right);'#10'end.'#10;

function TDuplicationIntegration.ProjectPath(const AName: string): string;
begin
  Result := FRoot + '/' + AName;
end;

procedure TDuplicationIntegration.CreateProject(const AName,
  AConfiguration: string; const AExcludedThird: Boolean);
begin
  ForceDirectories(ProjectPath(AName) + '/source');
  WriteTextFile(ProjectPath(AName) + '/lwpt.toml',
    '[package]'#10'name = "' + AName + '"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + AConfiguration);
  WriteTextFile(ProjectPath(AName) + '/source/one.lpr', SOURCE_ONE);
  WriteTextFile(ProjectPath(AName) + '/source/two.lpr', SOURCE_TWO);
  if AExcludedThird then
    WriteTextFile(ProjectPath(AName) + '/source/excluded.lpr', SOURCE_ONE);
end;

procedure TDuplicationIntegration.BeforeAll;
begin
  FRoot := CreateScratchRoot('duplication-integration');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  RecursiveDelete(FRoot);
  ForceDirectories(FRoot);
  CreateProject('human', '[duplication]'#10'minimum-tokens = 25'#10);
  CreateProject('json', '[duplication]'#10'minimum-tokens = 25'#10);
  CreateProject('threshold', '[duplication]'#10'minimum-tokens = 25'#10
    + 'maximum-percent = 0'#10);
  CreateProject('invalid', '[duplication]'#10'minimum-tokens = 24'#10);
  CreateProject('excluded', '[analysis]'#10
    + 'exclude = ["source/excluded.lpr"]'#10'[duplication]'#10
    + 'minimum-tokens = 25'#10, True);
end;

procedure TDuplicationIntegration.TestHumanReportIsReportOnlyByDefault;
var
  Result: TLwptResult;
begin
  Result := RunLwpt(['duplication'], ProjectPath('human'));
  Expect<Integer>(Result.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('Duplication:', Result.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('Clone 1:', Result.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('lwpt duplication: completed in ', Result.Stderr) > 0)
    .ToBe(True);
end;

procedure TDuplicationIntegration.TestJSONEnvelopeIsByteStable;
var
  First, Second: TLwptResult;
begin
  First := RunLwpt(['duplication', '--json'], ProjectPath('json'));
  Second := RunLwpt(['duplication', '--json'], ProjectPath('json'));
  Expect<Integer>(First.ExitCode).ToBe(0);
  Expect<Integer>(Second.ExitCode).ToBe(0);
  Expect<string>(First.Stdout).ToBe(Second.Stdout);
  Expect<Boolean>(Pos('"schema":"lwpt.analysis"', First.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"command":{"name":"duplication",'
    + '"schemaVersion":1}', First.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('"threshold":{"outcome":"not-configured"}',
    First.Stdout) > 0).ToBe(True);
end;

procedure TDuplicationIntegration.TestThresholdFailureUsesNonzeroExit;
var
  Result: TLwptResult;
begin
  Result := RunLwpt(['duplication'], ProjectPath('threshold'));
  Expect<Integer>(Result.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('exceeds configured maximum 0%', Result.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('lwpt duplication: failed after ', Result.Stderr) > 0)
    .ToBe(True);
end;

procedure TDuplicationIntegration.TestInvalidMinimumIsActionable;
var
  Result: TLwptResult;
begin
  Result := RunLwpt(['duplication'], ProjectPath('invalid'));
  Expect<Integer>(Result.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('minimum-tokens must be an integer of at least 25',
    Result.Stderr) > 0).ToBe(True);
end;

procedure TDuplicationIntegration.
  TestAnalysisExclusionRemovesFileFromScope;
var
  Result: TLwptResult;
begin
  Result := RunLwpt(['duplication', '--json'], ProjectPath('excluded'));
  Expect<Integer>(Result.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('"files":["source/one.lpr","source/two.lpr"]',
    Result.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('"file":"source/excluded.lpr"', Result.Stdout) = 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"occurrences":[{"file":"source/one.lpr"',
    Result.Stdout) > 0).ToBe(True);
end;

procedure TDuplicationIntegration.SetupTests;
begin
  Test('human output is report-only by default',
    TestHumanReportIsReportOnlyByDefault);
  Test('JSON uses the shared deterministic envelope',
    TestJSONEnvelopeIsByteStable);
  Test('configured maximum breach exits nonzero',
    TestThresholdFailureUsesNonzeroExit);
  Test('invalid clone floor reports the supported minimum',
    TestInvalidMinimumIsActionable);
  Test('shared analysis exclusion removes files from duplication scope',
    TestAnalysisExclusionRemovesFileFromScope);
end;

begin
  TestRunnerProgram.AddSuite(TDuplicationIntegration.Create(
    'LWPT duplication CLI'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
