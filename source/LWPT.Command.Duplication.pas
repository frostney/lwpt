{ LWPT.Command.Duplication — manifest-scoped clone-report entrypoint. }
unit LWPT.Command.Duplication;

{$I Shared.inc}
{$J-}

interface

function CmdDuplication(const AManifestPath: string;
  const AJSON: Boolean): Integer;

implementation

uses
  SysUtils,

  LWPT.Analysis.JSON,
  LWPT.Analysis.Scope,
  LWPT.Duplication;

function CmdDuplication(const AManifestPath: string;
  const AJSON: Boolean): Integer;
var
  ConfigurationIndex, DiagnosticIndex: Integer;
  Metadata: TLWPTAnalysisMetadata;
  Report: TLWPTDuplicationReport;
  Scope: TLWPTAnalysisScope;
begin
  Scope := ResolveAnalysisScope(AManifestPath);
  Report := AnalyzeDuplication(Scope);
  if AJSON then
  begin
    Metadata := AnalysisMetadataFromScope('duplication',
      DUPLICATION_REPORT_SCHEMA_VERSION, Scope);
    for ConfigurationIndex := 0 to High(Report.Configurations) do
    begin
      AddAnalysisConfigurationValue(Metadata,
        Report.Configurations[ConfigurationIndex].ProjectName,
        'duplication.minimum-tokens', IntToStr(
          Report.Configurations[ConfigurationIndex].MinimumTokens));
      if Report.Configurations[ConfigurationIndex].
        MaximumPercentConfigured then
        AddAnalysisConfigurationValue(Metadata,
          Report.Configurations[ConfigurationIndex].ProjectName,
          'duplication.maximum-percent', IntToStr(
            Report.Configurations[ConfigurationIndex].MaximumPercent));
    end;
    if Report.ThresholdConfigured then
      if Report.ThresholdFailed then
        Metadata.ThresholdOutcome := atoFailed
      else
        Metadata.ThresholdOutcome := atoPassed
    else
      Metadata.ThresholdOutcome := atoNotConfigured;
    for DiagnosticIndex := 0 to High(Report.Diagnostics) do
      AddAnalysisDiagnostic(Metadata, Report.Diagnostics[DiagnosticIndex]);
    Write(SerializeAnalysisEnvelope(Metadata,
      DuplicationReportJSON(Report)));
  end
  else
    Write(DuplicationReportHuman(Report));
  if Report.ThresholdFailed then Result := 1 else Result := 0;
end;

end.
