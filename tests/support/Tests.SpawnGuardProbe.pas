{ Tests.SpawnGuardProbe — deterministic proof that toolkit-state opens keep
  concurrent child spawns out of their open window and out of their
  descriptors.

  While armed, every protected open whose path contains the armed fragment
  starts a real child through ExecuteUnmanagedProcess from another thread,
  while the opener still holds the process-handle inheritance guard and has
  not yet marked the descriptor close-on-exec. The probe then waits for
  LWPT.Core's guard observation of the spawning thread: blocked waiting for
  the guard proves exclusion, having entered it is an escape. No elapsed
  time is interpreted.

  Every child is a descriptor reporter. It records the device and inode of
  each descriptor it holds after exec, then stays alive. Callers compare the
  reports with the files under test on every Unix target. Compile the caller
  with -dOBJECTSTORE_TESTING. }
unit Tests.SpawnGuardProbe;

{$mode delphi}{$H+}

interface

{$IFDEF UNIX}
{ Probe protected opens whose path contains APathFragment. Markers are
  written below AMarkerDirectory. At most AMaximumSpawns opens are probed. }
procedure ArmSpawnGuardProbe(const APathFragment, AMarkerDirectory: string;
  const AMaximumSpawns: Integer);
{ Stops probing and waits until every spawn attempt has returned. }
procedure DisarmSpawnGuardProbe;
function SpawnGuardProbeAttempts: Integer;
{ Children that entered the guard while their opener still held it. }
function SpawnGuardProbeEscapes: Integer;
{ Probed descriptors whose close-on-exec flag was clear after protection. }
function SpawnGuardProbeUnprotectedDescriptors: Integer;
{ Children that started, reported their descriptors and are still alive. }
function SpawnGuardProbeLiveChildren: Integer;
{ Reported child descriptors that refer to any of APaths. }
function SpawnGuardProbeInheritedFiles(const APaths: array of string): Integer;
function SpawnGuardProbeError: string;
procedure ReleaseSpawnGuardProbeChildren;

{ Starts one reporter child through the production spawn path now, waits for
  its report and stops it. Returns how many of its descriptors refer to any
  of APaths, or -1 when the child produced no report. }
function ChildInheritedFileCount(const APaths: array of string;
  const AMarkerDirectory: string): Integer;
{$ENDIF}

implementation

{$IFDEF UNIX}
uses
  BaseUnix,
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.ProcessTree;

const
  GUARD_OBSERVATION_TIMEOUT_MILLISECONDS = 10000;
  CHILD_REPORT_TIMEOUT_MILLISECONDS = 10000;
  POLL_MILLISECONDS = 1;
  REPORT_POLL_MILLISECONDS = 10;
  { POSIX fixes FD_CLOEXEC at 1; Linux FPC 3.2.2 does not declare it. }
  FD_CLOEXEC_PROBE = 1;
  CHILD_LIFETIME_SECONDS = '30';
  {$IFDEF DARWIN}
  STAT_IDENTITY_ARGUMENTS = '-L -f %d:%i';
  {$ELSE}
  STAT_IDENTITY_ARGUMENTS = '-L -c %d:%i';
  {$ENDIF}
  { Report every descriptor the shell holds after exec, publish the report
    atomically, then stay alive so the caller can compare. The glob's own
    listing descriptor is closed by then and never names a caller file. }
  REPORTER_SCRIPT = 'for d in /dev/fd/*; do stat '
    + STAT_IDENTITY_ARGUMENTS + ' "$d" 2>/dev/null; done > "$1.partial"; '
    + 'mv "$1.partial" "$1"; exec sleep ' + CHILD_LIFETIME_SECONDS;

type
  TProbeSpawner = class(TThread)
  private
    FReportPath: string;
    FChild: TProcess;
    FErrorMessage: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AReportPath: string);
    destructor Destroy; override;
  end;

var
  ProbeFragment: string = '';
  ProbeMarkerDirectory: string = '';
  ProbeMaximumSpawns: Integer = 0;
  ProbeAttempts: Integer = 0;
  ProbeEscapes: Integer = 0;
  ProbeUnprotected: Integer = 0;
  ProbeError: string = '';
  Spawners: TList = nil;
  ReportPaths: TStringList = nil;

function StartReporter(const AReportPath: string): TProcess;
begin
  Result := TProcess.Create(nil);
  try
    Result.Executable := '/bin/sh';
    Result.Parameters.Add('-c');
    Result.Parameters.Add(REPORTER_SCRIPT);
    Result.Parameters.Add('spawn-guard-probe');
    Result.Parameters.Add(AReportPath);
    Result.Options := [poNoConsole];
    ExecuteUnmanagedProcess(Result);
  except
    Result.Free;
    raise;
  end;
end;

procedure StopReporter(var AChild: TProcess);
begin
  if not Assigned(AChild) then Exit;
  if AChild.Running then
  begin
    AChild.Terminate(0);
    AChild.WaitOnExit;
  end;
  FreeAndNil(AChild);
end;

function WaitForReport(const APath: string): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    if FileExists(APath) then Exit(True);
    Sleep(REPORT_POLL_MILLISECONDS);
  until GetTickCount64 - Started >= CHILD_REPORT_TIMEOUT_MILLISECONDS;
  Result := FileExists(APath);
end;

function FileIdentity(const APath: string): string;
var
  Info: Stat;
begin
  Result := '';
  if FpStat(PChar(APath), Info) = 0 then
    Result := IntToStr(QWord(Info.st_dev)) + ':' + IntToStr(QWord(Info.st_ino));
end;

function CountReportedFiles(const AReportPath: string;
  const AIdentities: TStrings): Integer;
var
  Report: TStringList;
  Index: Integer;
begin
  Result := 0;
  Report := TStringList.Create;
  try
    Report.LoadFromFile(AReportPath);
    for Index := 0 to Report.Count - 1 do
      if AIdentities.IndexOf(Trim(Report[Index])) >= 0 then Inc(Result);
  finally
    Report.Free;
  end;
end;

function IdentitiesOf(const APaths: array of string): TStringList;
var
  Index: Integer;
  Identity: string;
begin
  Result := TStringList.Create;
  for Index := Low(APaths) to High(APaths) do
  begin
    Identity := FileIdentity(APaths[Index]);
    if Identity <> '' then Result.Add(Identity);
  end;
end;

constructor TProbeSpawner.Create(const AReportPath: string);
begin
  FReportPath := AReportPath;
  FChild := nil;
  FErrorMessage := '';
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TProbeSpawner.Destroy;
begin
  StopReporter(FChild);
  inherited Destroy;
end;

procedure TProbeSpawner.Execute;
begin
  try
    FChild := StartReporter(FReportPath);
  except
    on E: Exception do FErrorMessage := E.Message;
  end;
end;

procedure RecordError(const AMessage: string);
begin
  if ProbeError = '' then ProbeError := AMessage;
end;

procedure ProbeProtectedOpen(const APath: string);
var
  Spawner: TProbeSpawner;
  Started: QWord;
begin
  if (ProbeFragment = '') or (Pos(ProbeFragment, APath) = 0) then Exit;
  if ProbeAttempts >= ProbeMaximumSpawns then Exit;
  Inc(ProbeAttempts);
  ReportPaths.Add(ProbeMarkerDirectory + '/child-report-'
    + IntToStr(ProbeAttempts));
  Spawner := TProbeSpawner.Create(ReportPaths[ReportPaths.Count - 1]);
  Spawners.Add(Spawner);
  Started := GetTickCount64;
  repeat
    case ObserveProcessHandleSetup(Spawner.ThreadID) of
      phsWaiting: Exit;
      phsEntered:
        begin
          Inc(ProbeEscapes);
          Exit;
        end;
    end;
    if Spawner.Finished then
    begin
      RecordError('probe spawn ended before reaching the guard: '
        + Spawner.FErrorMessage);
      Exit;
    end;
    if GetTickCount64 - Started >= GUARD_OBSERVATION_TIMEOUT_MILLISECONDS then
    begin
      RecordError('probe spawn never reached the guard for ' + APath);
      Exit;
    end;
    Sleep(POLL_MILLISECONDS);
  until False;
end;

procedure InspectProtectedDescriptor(const APath: string;
  const ADescriptor: LongInt);
begin
  if (ProbeFragment = '') or (Pos(ProbeFragment, APath) = 0) then Exit;
  if (FpFcntl(ADescriptor, F_GETFD) and FD_CLOEXEC_PROBE) = 0 then
    Inc(ProbeUnprotected);
end;

procedure ArmSpawnGuardProbe(const APathFragment, AMarkerDirectory: string;
  const AMaximumSpawns: Integer);
begin
  ProbeFragment := APathFragment;
  ProbeMarkerDirectory := ExcludeTrailingPathDelimiter(AMarkerDirectory);
  ForceDirectories(ProbeMarkerDirectory);
  ProbeMaximumSpawns := AMaximumSpawns;
  ProbeAttempts := 0;
  ProbeEscapes := 0;
  ProbeUnprotected := 0;
  ProbeError := '';
  if not Assigned(Spawners) then Spawners := TList.Create;
  if not Assigned(ReportPaths) then ReportPaths := TStringList.Create;
  ResetProcessHandleSetupObservation;
  ProtectedOpenBeforeProtectionTestHook := ProbeProtectedOpen;
  ProtectedOpenAfterProtectionTestHook := InspectProtectedDescriptor;
end;

procedure DisarmSpawnGuardProbe;
var
  Index: Integer;
  Spawner: TProbeSpawner;
begin
  ProtectedOpenBeforeProtectionTestHook := nil;
  ProtectedOpenAfterProtectionTestHook := nil;
  ProbeFragment := '';
  for Index := 0 to Spawners.Count - 1 do
  begin
    Spawner := TProbeSpawner(Spawners[Index]);
    Spawner.WaitFor;
    if Spawner.FErrorMessage <> '' then
      RecordError('probe spawn failed: ' + Spawner.FErrorMessage);
  end;
end;

function SpawnGuardProbeAttempts: Integer;
begin
  Result := ProbeAttempts;
end;

function SpawnGuardProbeEscapes: Integer;
begin
  Result := ProbeEscapes;
end;

function SpawnGuardProbeUnprotectedDescriptors: Integer;
begin
  Result := ProbeUnprotected;
end;

function SpawnGuardProbeLiveChildren: Integer;
var
  Index: Integer;
  Spawner: TProbeSpawner;
begin
  Result := 0;
  for Index := 0 to Spawners.Count - 1 do
  begin
    Spawner := TProbeSpawner(Spawners[Index]);
    if WaitForReport(ReportPaths[Index])
       and Assigned(Spawner.FChild) and Spawner.FChild.Running then
      Inc(Result);
  end;
end;

function SpawnGuardProbeInheritedFiles(const APaths: array of string): Integer;
var
  Identities: TStringList;
  Index: Integer;
begin
  Result := 0;
  Identities := IdentitiesOf(APaths);
  try
    for Index := 0 to ReportPaths.Count - 1 do
      if WaitForReport(ReportPaths[Index]) then
        Inc(Result, CountReportedFiles(ReportPaths[Index], Identities));
  finally
    Identities.Free;
  end;
end;

function SpawnGuardProbeError: string;
begin
  Result := ProbeError;
end;

procedure ReleaseSpawnGuardProbeChildren;
var
  Index: Integer;
begin
  if Assigned(Spawners) then
  begin
    for Index := 0 to Spawners.Count - 1 do
      TProbeSpawner(Spawners[Index]).Free;
    Spawners.Clear;
  end;
  if Assigned(ReportPaths) then ReportPaths.Clear;
end;

function ChildInheritedFileCount(const APaths: array of string;
  const AMarkerDirectory: string): Integer;
var
  Child: TProcess;
  Identities: TStringList;
  ReportPath: string;
begin
  ForceDirectories(AMarkerDirectory);
  ReportPath := IncludeTrailingPathDelimiter(AMarkerDirectory)
    + 'reporter-' + IntToStr(GetProcessID) + '-' + IntToStr(GetTickCount64);
  Identities := IdentitiesOf(APaths);
  Child := nil;
  try
    Child := StartReporter(ReportPath);
    if not WaitForReport(ReportPath) then Exit(-1);
    Result := CountReportedFiles(ReportPath, Identities);
  finally
    StopReporter(Child);
    Identities.Free;
  end;
end;

initialization

finalization
  ReleaseSpawnGuardProbeChildren;
  Spawners.Free;
  ReportPaths.Free;
{$ENDIF}

end.
