unit Tests.RegistryProcess;

{$mode delphi}{$H+}

interface

uses
  Process,
  SysUtils;

type
  TRegistryStopResult = record
    ExitStatus: Integer;
    Forced, Stopped: Boolean;
  end;

{ The listener allows ten seconds for connections, plus two for teardown. }
function StopRegistryProcess(var AProcess: TProcess;
  const AGraceMilliseconds: QWord = 12000;
  const AKillMilliseconds: QWord = 2000): TRegistryStopResult;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix
  {$ELSE}
  Windows
  {$ENDIF};

function WaitForRegistryExit(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while AProcess.Running
    and (GetTickCount64 - StartedAt < ATimeoutMilliseconds) do Sleep(10);
  Result := not AProcess.Running;
end;

function StopRegistryProcess(var AProcess: TProcess;
  const AGraceMilliseconds, AKillMilliseconds: QWord): TRegistryStopResult;
var
  Instance: TProcess;
begin
  Result := Default(TRegistryStopResult);
  Result.ExitStatus := -1;
  Result.Stopped := True;
  if AProcess = nil then Exit;
  Instance := AProcess;
  AProcess := nil;
  try
    if Instance.Running then
    begin
      {$IFDEF UNIX}
      FpKill(Instance.ProcessID, SIGTERM);
      {$ELSE}
      TerminateProcess(Instance.Handle, 1);
      {$ENDIF}
    end;
    if not WaitForRegistryExit(Instance, AGraceMilliseconds) then
    begin
      Result.Forced := True;
      {$IFDEF UNIX}
      FpKill(Instance.ProcessID, SIGKILL);
      {$ELSE}
      TerminateProcess(Instance.Handle, 1);
      {$ENDIF}
      Result.Stopped := WaitForRegistryExit(Instance, AKillMilliseconds);
    end;
    if Result.Stopped then
    begin
      { Running uses a nonblocking status query; never enter FPC's unbounded
        Unix Terminate/WaitOnExit path while the child is still running. }
      Instance.WaitOnExit;
      Result.ExitStatus := Instance.ExitStatus;
    end;
  finally
    Instance.Free;
  end;
end;

end.
