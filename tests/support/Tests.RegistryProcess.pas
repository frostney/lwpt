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
{ Before Execute: on Linux the child receives SIGKILL when this test program
  dies, so a killed test run leaves no orphaned registry server. Other
  platforms rely on the fixture's own stop path. }
procedure BindRegistryChildToParent(AProcess: TProcess);
{ After AProcess.Running has reported an exit: waits, bounded, until the
  child has released its handles. Windows signals the process handle only
  after that rundown; Unix has already reaped the child. False means the
  wait timed out. }
function WaitForRegistryHandleRelease(AProcess: TProcess;
  const ATimeoutMilliseconds: Cardinal): Boolean;

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

{$IFDEF LINUX}
const
  PR_SET_PDEATHSIG = 1;

function prctl(AOption: LongInt; AArgument: PtrUInt): LongInt; cdecl;
  external 'c' name 'prctl';
{$ENDIF}

type
  TRegistryChildBinder = class
  public
    procedure ChildForked(ASender: TObject);
  end;

var
  RegistryChildBinder: TRegistryChildBinder;
  {$IFDEF UNIX}
  RegistryParentPID: TPid;
  {$ENDIF}

procedure TRegistryChildBinder.ChildForked(ASender: TObject);
begin
  {$IFDEF LINUX}
  { Runs in the forked child before exec. FPC forks, prepares the child,
    and only then calls this, so the parent may already have died: the
    death signal would then never arrive. Exit at once when the request
    fails or the child has been reparented. }
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) <> 0)
    or (FpGetppid <> RegistryParentPID) then
    FpExit(127);
  {$ENDIF}
end;

function WaitForRegistryHandleRelease(AProcess: TProcess;
  const ATimeoutMilliseconds: Cardinal): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := AProcess.WaitOnExit(ATimeoutMilliseconds);
  {$ELSE}
  Result := not AProcess.Running;
  {$ENDIF}
end;

procedure BindRegistryChildToParent(AProcess: TProcess);
begin
  {$IFDEF LINUX}
  AProcess.OnForkEvent := RegistryChildBinder.ChildForked;
  {$ENDIF}
end;

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
      { Running uses a nonblocking status query. Never enter FPC's unbounded
        WaitOnExit: on Windows it waits forever, so the handle wait is
        bounded and a timeout is reported as not stopped. }
      Result.Stopped := WaitForRegistryHandleRelease(Instance,
        AKillMilliseconds);
      if Result.Stopped then Result.ExitStatus := Instance.ExitStatus;
    end;
  finally
    Instance.Free;
  end;
end;

initialization
  RegistryChildBinder := TRegistryChildBinder.Create;
  {$IFDEF UNIX}
  RegistryParentPID := FpGetpid;
  {$ENDIF}

finalization
  RegistryChildBinder.Free;
end.
