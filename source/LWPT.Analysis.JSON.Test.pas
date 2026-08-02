{ LWPT.Analysis.JSON.Test — deterministic shared envelope contract. }
program LWPT.Analysis.JSON.Test;

{$I Shared.inc}

uses
  SysUtils,

  LWPT.Analysis.JSON,
  LWPT.Analysis.Scope,
  LWPT.Core,
  TestingPascalLibrary;

type
  TAnalysisJSONTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestJSONStringEscapesControlBytes;
    procedure TestEnvelopeIsStableAndCommandPayloadOwned;
    procedure TestMetadataCopiesSortedScopePaths;
    procedure TestRejectsInvalidEnvelopeInputs;
  end;

procedure TAnalysisJSONTests.TestJSONStringEscapesControlBytes;
begin
  Expect<string>(JSONString('a"\'#10#1)).ToBe('"a\"\\\n\u0001"');
end;

procedure TAnalysisJSONTests.TestEnvelopeIsStableAndCommandPayloadOwned;
const
  EXPECTED = '{'#10
    + '  "schema":"lwpt.analysis",'#10
    + '  "schemaVersion":1,'#10
    + '  "command":{"name":"health","schemaVersion":3},'#10
    + '  "tool":{"name":"lwpt","version":"' + PROGRAM_VERSION + '"},'#10
    + '  "project":{"name":"demo","version":"1.2.3"},'#10
    + '  "files":["a.pas","z.pas"],'#10
    + '  "configuration":[{"project":"demo","name":"analysis.exclude","value":"generated/**"},{"project":"demo","name":"analysis.include","value":"source/**"}],'#10
    + '  "threshold":{"outcome":"passed"},'#10
    + '  "diagnostics":["first","second"],'#10
    + '  "payload":{"score":7}'#10
    + '}'#10;
var
  Metadata: TLWPTAnalysisMetadata;
begin
  Metadata := Default(TLWPTAnalysisMetadata);
  Metadata.CommandName := 'health';
  Metadata.CommandSchemaVersion := 3;
  Metadata.ProjectName := 'demo';
  Metadata.ProjectVersion := '1.2.3';
  SetLength(Metadata.Files, 3);
  Metadata.Files[0] := 'z.pas';
  Metadata.Files[1] := 'a.pas';
  Metadata.Files[2] := 'z.pas';
  AddAnalysisConfigurationValue(Metadata, 'demo', 'analysis.include',
    'source/**');
  AddAnalysisConfigurationValue(Metadata, 'demo', 'analysis.exclude',
    'generated/**');
  AddAnalysisConfigurationValue(Metadata, 'demo', 'analysis.include',
    'source/**');
  Metadata.ThresholdOutcome := atoPassed;
  AddAnalysisDiagnostic(Metadata, 'second');
  AddAnalysisDiagnostic(Metadata, 'first');
  AddAnalysisDiagnostic(Metadata, 'second');
  Expect<string>(SerializeAnalysisEnvelope(Metadata, ' {"score":7} '))
    .ToBe(EXPECTED);
end;

procedure TAnalysisJSONTests.TestMetadataCopiesSortedScopePaths;
var
  Metadata: TLWPTAnalysisMetadata;
  Scope: TLWPTAnalysisScope;
begin
  Scope := Default(TLWPTAnalysisScope);
  Scope.ProjectName := 'demo';
  Scope.ProjectVersion := '2.0.0';
  SetLength(Scope.Projects, 1);
  Scope.Projects[0].Name := 'demo';
  SetLength(Scope.Projects[0].Configuration.Includes, 1);
  Scope.Projects[0].Configuration.Includes[0] := 'source/**';
  SetLength(Scope.Projects[0].Configuration.Excludes, 1);
  Scope.Projects[0].Configuration.Excludes[0] := 'generated/**';
  SetLength(Scope.Files, 2);
  Scope.Files[0].RootRelativePath := 'source/z.pas';
  Scope.Files[1].RootRelativePath := 'source/a.pas';
  Metadata := AnalysisMetadataFromScope('duplication', 1, Scope);
  Expect<string>(Metadata.CommandName).ToBe('duplication');
  Expect<Integer>(Metadata.CommandSchemaVersion).ToBe(1);
  Expect<string>(Metadata.Files[0]).ToBe('source/a.pas');
  Expect<string>(Metadata.Files[1]).ToBe('source/z.pas');
  Expect<Integer>(Length(Metadata.Configuration)).ToBe(2);
  Expect<string>(Metadata.Configuration[0].Name).ToBe('analysis.exclude');
  Expect<string>(Metadata.Configuration[1].Name).ToBe('analysis.include');
end;

function RejectsPayload(const AMetadata: TLWPTAnalysisMetadata;
  const APayload: string): Boolean;
begin
  Result := False;
  try
    SerializeAnalysisEnvelope(AMetadata, APayload);
  except
    on ELWPTError do Result := True;
  end;
end;

procedure TAnalysisJSONTests.TestRejectsInvalidEnvelopeInputs;
var
  DeepPayload: string;
  Metadata: TLWPTAnalysisMetadata;
begin
  Metadata := Default(TLWPTAnalysisMetadata);
  Metadata.CommandName := 'health';
  Metadata.CommandSchemaVersion := 1;
  Metadata.ProjectName := 'demo';
  Expect<Boolean>(RejectsPayload(Metadata, 'not-json')).ToBe(True);
  Expect<Boolean>(RejectsPayload(Metadata, '{"broken":}')).ToBe(True);
  Expect<Boolean>(RejectsPayload(Metadata, '{}{}')).ToBe(True);
  Expect<Boolean>(RejectsPayload(Metadata, '[1,]')).ToBe(True);
  Expect<Boolean>(RejectsPayload(Metadata, '{"value":"\q"}')).ToBe(True);
  DeepPayload := StringOfChar('[', 129) + '0' + StringOfChar(']', 129);
  Expect<Boolean>(RejectsPayload(Metadata, DeepPayload)).ToBe(True);
  Expect<Boolean>(Pos('{"nested":[{"value":"\u0041"}]}',
    SerializeAnalysisEnvelope(Metadata,
    '{"nested":[{"value":"\u0041"}]}')) > 0).ToBe(True);
end;

procedure TAnalysisJSONTests.SetupTests;
begin
  Test('escapes JSON strings without external dependencies',
    TestJSONStringEscapesControlBytes);
  Test('writes a stable envelope around a command-owned payload',
    TestEnvelopeIsStableAndCommandPayloadOwned);
  Test('copies deterministic root-relative paths from scope',
    TestMetadataCopiesSortedScopePaths);
  Test('rejects invalid envelope inputs', TestRejectsInvalidEnvelopeInputs);
end;

begin
  TestRunnerProgram.AddSuite(TAnalysisJSONTests.Create(
    PROJECT_NAME + '.Analysis.JSON'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
