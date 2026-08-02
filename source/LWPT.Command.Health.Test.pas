{ LWPT.Command.Health.Test — report, inheritance, and config contracts. }
program LWPT.Command.Health.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Analysis.JSON,
  LWPT.Command.Health,
  LWPT.Core,
  LWPT.Health,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  THealthCommandTests = class(TTestSuite)
  private
    FRoot: string;
    procedure WriteText(const APath, AText: string);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestBuildsDeterministicSharedEnvelope;
    procedure TestWorkspaceInheritsAndCanReplaceLimits;
    procedure TestRejectsInvalidHealthLimits;
  end;

procedure THealthCommandTests.WriteText(const APath, AText: string);
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

procedure THealthCommandTests.BeforeAll;
begin
  FRoot := ExpandFileName('build/tests/tmp/health-command');
  if DirectoryExists(FRoot) then WipeDir(FRoot);
  ForceDirectories(FRoot);
  WriteText(FRoot + '/lwpt.toml',
    '[package]'#10'name = "root"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10
    + '[workspaces]'#10'include = ["packages/*"]'#10
    + '[health]'#10'max-routine-cyclomatic = 1'#10);
  WriteText(FRoot + '/source/root.pas',
    'unit RootUnit; interface implementation '#10
    + 'procedure Work; begin if A then B; end; end.');
  WriteText(FRoot + '/packages/child/lwpt.toml',
    '[package]'#10'name = "child"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteText(FRoot + '/packages/child/source/child.pas',
    'unit ChildUnit; interface implementation '#10
    + 'procedure Work; begin A; end; end.');
end;

procedure THealthCommandTests.TestBuildsDeterministicSharedEnvelope;
var
  Files: TLWPTHealthFileArray;
  FirstHuman, FirstJSON, SecondHuman, SecondJSON: string;
  Violations: TLWPTHealthViolationArray;
begin
  WriteText(FRoot + '/packages/child/lwpt.toml',
    '[package]'#10'name = "child"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  BuildHealthReport(FRoot + '/lwpt.toml', False, FirstHuman, FirstJSON,
    Files, Violations);
  BuildHealthReport(FRoot + '/lwpt.toml', False, SecondHuman, SecondJSON,
    Files, Violations);
  Expect<string>(FirstHuman).ToBe(SecondHuman);
  Expect<string>(FirstJSON).ToBe(SecondJSON);
  Expect<Boolean>(Pos('"schema":"' + ANALYSIS_ENVELOPE_SCHEMA + '"',
    FirstJSON) > 0).ToBe(True);
  Expect<Boolean>(Pos('"command":{"name":"health","schemaVersion":1}',
    FirstJSON) > 0).ToBe(True);
  Expect<Boolean>(Pos('"mode":"complexity-only"', FirstJSON) > 0)
    .ToBe(True);
end;

procedure THealthCommandTests.TestWorkspaceInheritsAndCanReplaceLimits;
var
  Files: TLWPTHealthFileArray;
  HumanReport, JSONReport: string;
  Violations: TLWPTHealthViolationArray;
begin
  WriteText(FRoot + '/packages/child/lwpt.toml',
    '[package]'#10'name = "child"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  Expect<Boolean>(BuildHealthReport(FRoot + '/lwpt.toml', False,
    HumanReport, JSONReport, Files, Violations)).ToBe(False);
  Expect<Integer>(Length(Violations)).ToBe(1);
  Expect<string>(Violations[0].ProjectName).ToBe('root');

  WriteText(FRoot + '/packages/child/lwpt.toml',
    '[package]'#10'name = "child"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10
    + '[health]'#10'max-routine-cyclomatic = 0'#10);
  BuildHealthReport(FRoot + '/lwpt.toml', False, HumanReport, JSONReport,
    Files, Violations);
  Expect<Integer>(Length(Violations)).ToBe(2);
  Expect<string>(Violations[1].ProjectName).ToBe('root');
  Expect<string>(Violations[0].ProjectName).ToBe('child');
end;

function RejectsManifest(const APath, AHealth: string): Boolean;
var
  Manifest: TManifest;
  Stream: TFileStream;
  Text: string;
begin
  Text := '[package]'#10'name = "bad"'#10'version = "1.0.0"'#10
    + '[health]'#10 + AHealth + #10;
  Stream := TFileStream.Create(APath, fmCreate);
  try
    Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
  Result := False;
  try
    Manifest := LoadManifest(APath);
    if Manifest.Name = '' then Result := False;
  except
    on EManifestError do Result := True;
  end;
end;

procedure THealthCommandTests.TestRejectsInvalidHealthLimits;
begin
  Expect<Boolean>(RejectsManifest(FRoot + '/negative.toml',
    'max-file-cognitive = -1')).ToBe(True);
  Expect<Boolean>(RejectsManifest(FRoot + '/string.toml',
    'max-routine-cyclomatic = "ten"')).ToBe(True);
  Expect<Boolean>(RejectsManifest(FRoot + '/hotspot.toml',
    'max-hotspot-score = 101')).ToBe(True);
  Expect<Boolean>(RejectsManifest(FRoot + '/unknown.toml',
    'max-file-complexity = 10')).ToBe(True);
end;

procedure THealthCommandTests.SetupTests;
begin
  Test('builds deterministic human and shared-envelope JSON reports',
    TestBuildsDeterministicSharedEnvelope);
  Test('inherits root limits and lets workspaces replace them',
    TestWorkspaceInheritsAndCanReplaceLimits);
  Test('rejects invalid health limits', TestRejectsInvalidHealthLimits);
end;

begin
  TestRunnerProgram.AddSuite(THealthCommandTests.Create(
    PROJECT_NAME + '.Command.Health'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
