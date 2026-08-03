{ LWPT.Output.Legacy — compatibility vocabulary for the current human output.

  Build and test still render their established text directly. This unit keeps
  that presentation policy outside LWPT.Observability until the shared reporter
  replaces it. }
unit LWPT.Output.Legacy;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

const
  ObservabilityHeartbeatIntervalEnvironment = PROJECT_NAME
    + '_HEARTBEAT_INTERVAL_MS';
  ObservabilityStartEvent = 'START ';
  ObservabilityHeartbeatEvent = 'HEARTBEAT ';
  ObservabilityPassEvent = 'PASS ';
  ObservabilityFailEvent = 'FAIL ';
  ObservabilitySkipEvent = 'SKIP ';
  ObservabilityBuildIdentityNamespace = 'build:';
  ObservabilityTestIdentityNamespace = 'test:';

function ObservabilityHeartbeatIntervalMilliseconds: QWord;
function FormatElapsedMilliseconds(const AElapsed: QWord): string;

implementation

const
  DefaultObservabilityHeartbeatIntervalMilliseconds = 30000;

function ObservabilityHeartbeatIntervalMilliseconds: QWord;
var
  Raw: string;
  Parsed: Int64;
begin
  Raw := SysUtils.GetEnvironmentVariable(
    ObservabilityHeartbeatIntervalEnvironment);
  if (Raw <> '') and TryStrToInt64(Raw, Parsed) and (Parsed > 0) then
  begin
    Result := QWord(Parsed);
    if Result > DefaultObservabilityHeartbeatIntervalMilliseconds then
      Result := DefaultObservabilityHeartbeatIntervalMilliseconds;
    Exit;
  end;
  Result := DefaultObservabilityHeartbeatIntervalMilliseconds;
end;

function FormatElapsedMilliseconds(const AElapsed: QWord): string;
begin
  Result := UIntToStr(AElapsed) + ' ms';
end;

end.
