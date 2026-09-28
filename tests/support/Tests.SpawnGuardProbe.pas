{ Tests.SpawnGuardProbe — deterministic proof that toolkit-state opens keep
  concurrent child spawns out of their open window and out of their
  descriptors.

  While armed, every protected open whose path contains the armed fragment
  first checks that the opening thread holds LWPT.Core's process-handle
  inheritance guard, then starts a real child through ExecuteUnmanagedProcess
  from another thread. The probe waits for Core's observation of that
  spawning thread: a failed non-blocking attempt on the guard held by the
  opener proves exclusion, and having entered the guard is an escape. No
  elapsed time is interpreted. After protection, each probed descriptor's
  close-on-exec flag is read with fcntl(F_GETFD), and its device and inode
  are recorded as a published identity.

  Every child is the caller's own executable in descriptor-reporter mode:
  this unit's initialization lists the device and inode of each descriptor
  it holds after exec with fstat, then stays alive. A report is valid
  only when it is complete, every entry resolved, and it contains the
  probe's deliberately inherited control descriptor, so missing or unusable
  evidence fails instead of reading as zero inherited descriptors. Compile
  the caller with -dOBJECTSTORE_TESTING. }
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
{ Opens outside the guard plus children that entered it inside a window. }
function SpawnGuardProbeEscapes: Integer;
{ Probed descriptors whose close-on-exec flag was clear after protection. }
function SpawnGuardProbeUnprotectedDescriptors: Integer;
{ Children that produced a valid report and are still alive. }
function SpawnGuardProbeLiveChildren: Integer;
{ Reported child descriptors that refer to any identity published through a
  probed open, or -1 when any report is missing or invalid. }
function SpawnGuardProbeInheritedPublications: Integer;
{ Reported child descriptors that refer to any of APaths as they exist now,
  or -1 when any report is missing or invalid. }
function SpawnGuardProbeInheritedFiles(const APaths: array of string): Integer;
function SpawnGuardProbeError: string;
procedure ReleaseSpawnGuardProbeChildren;

{ Starts one reporter child through the production spawn path now, waits for
  its report and stops it. Returns how many of its descriptors refer to any
  of APaths, or -1 when the report is missing, invalid or lacks the control
  descriptor. Removes its own markers. }
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
  REPORT_END_MARKER = 'end';
  REPORT_ERROR_PREFIX = 'error:';
  { stdin, stdout, stderr and the control descriptor at least. }
  REPORT_MINIMUM_ENTRIES = 4;
  { The caller's own executable reports its descriptors from this unit's
    initialization, before any test code runs, so the evidence does not
    depend on a shell, stat(1) or a /dev/fd implementation. }
  REPORTER_SWITCH = '--spawn-guard-probe-reporter';
  { Upper bound on descriptor numbers a reporter inspects. }
  REPORTER_DESCRIPTOR_LIMIT = 1024;
  REPORTER_LIFETIME_MILLISECONDS = 30000;

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
  ProbeControlPath: string = '';
  ProbeControlHandle: THandle = THandle(-1);
  ProbeControlIdentity: string = '';
  Spawners: TList = nil;
  ReportPaths: TStringList = nil;
  PublishedIdentities: TStringList = nil;

function StartReporter(const AReportPath: string): TProcess;
begin
  Result := TProcess.Create(nil);
  try
    Result.Executable := ExpandFileName(ParamStr(0));
    Result.Parameters.Add(REPORTER_SWITCH);
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

function IdentityOfInfo(const AInfo: Stat): string;
begin
  Result := IntToStr(QWord(AInfo.st_dev)) + ':' + IntToStr(QWord(AInfo.st_ino));
end;

function FileIdentity(const APath: string): string;
var
  Info: Stat;
begin
  Result := '';
  if FpStat(PChar(APath), Info) = 0 then Result := IdentityOfInfo(Info);
end;

function ValidIdentity(const AValue: string): Boolean;
var
  Separator, Index: Integer;
begin
  Separator := Pos(':', AValue);
  Result := (Separator > 1) and (Separator < Length(AValue));
  if not Result then Exit;
  for Index := 1 to Length(AValue) do
    if (Index <> Separator) and not (AValue[Index] in ['0'..'9']) then
      Exit(False);
end;

{ Loads a report and validates it. AError explains any invalid evidence. }
function LoadValidReport(const AReportPath, AControlIdentity: string;
  const AEntries: TStrings; out AError: string): Boolean;
var
  Index: Integer;
  Line: string;
  Ended: Boolean;
begin
  Result := False;
  AError := '';
  AEntries.Clear;
  if not WaitForReport(AReportPath) then
  begin
    AError := 'no descriptor report at ' + AReportPath;
    Exit;
  end;
  Ended := False;
  with TStringList.Create do
  try
    LoadFromFile(AReportPath);
    for Index := 0 to Count - 1 do
    begin
      Line := Trim(Strings[Index]);
      if Line = '' then Continue;
      if Ended then
      begin
        AError := 'descriptor report continues after its end marker';
        Exit;
      end;
      if Line = REPORT_END_MARKER then Ended := True
      else if ValidIdentity(Line) then AEntries.Add(Line)
      else
      begin
        AError := 'descriptor report has an unusable entry: ' + Line;
        Exit;
      end;
    end;
  finally
    Free;
  end;
  if not Ended then
    AError := 'descriptor report is incomplete'
  else if AEntries.Count < REPORT_MINIMUM_ENTRIES then
    AError := 'descriptor report lists too few descriptors'
  else if AEntries.IndexOf(AControlIdentity) < 0 then
    AError := 'descriptor report misses the inherited control descriptor';
  Result := AError = '';
end;

function CountMatches(const AEntries, AIdentities: TStrings): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to AEntries.Count - 1 do
    if AIdentities.IndexOf(AEntries[Index]) >= 0 then Inc(Result);
end;

{ Opens an inheritable control file whose identity every report must list. }
function OpenControlDescriptor(const APath: string;
  out AIdentity: string): THandle;
var
  Info: Stat;
begin
  Result := FileCreate(APath);
  AIdentity := '';
  if Result = THandle(-1) then Exit;
  if FpFStat(Result, Info) = 0 then AIdentity := IdentityOfInfo(Info);
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
  Flags: TLWPTProcessHandleSetupFlags;
  Spawner: TProbeSpawner;
  Started: QWord;
begin
  if (ProbeFragment = '') or (Pos(ProbeFragment, APath) = 0) then Exit;
  if ProbeAttempts >= ProbeMaximumSpawns then Exit;
  Inc(ProbeAttempts);
  if not (phfHeld in ObserveProcessHandleSetup(GetCurrentThreadId)) then
  begin
    { Without the guard the window cannot exclude any spawn. }
    Inc(ProbeEscapes);
    Exit;
  end;
  ReportPaths.Add(ProbeMarkerDirectory + '/child-report-'
    + IntToStr(ProbeAttempts));
  Spawner := TProbeSpawner.Create(ReportPaths[ReportPaths.Count - 1]);
  Spawners.Add(Spawner);
  Started := GetTickCount64;
  repeat
    Flags := ObserveProcessHandleSetup(Spawner.ThreadID);
    if phfEntered in Flags then
    begin
      Inc(ProbeEscapes);
      Exit;
    end;
    if phfContended in Flags then Exit;
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
var
  Info: Stat;
begin
  if (ProbeFragment = '') or (Pos(ProbeFragment, APath) = 0) then Exit;
  if (FpFcntl(ADescriptor, F_GETFD) and FD_CLOEXEC_PROBE) = 0 then
    Inc(ProbeUnprotected);
  if FpFStat(ADescriptor, Info) = 0 then
    PublishedIdentities.Add(IdentityOfInfo(Info))
  else
    RecordError('could not identify probed descriptor for ' + APath);
end;

procedure ArmSpawnGuardProbe(const APathFragment, AMarkerDirectory: string;
  const AMaximumSpawns: Integer);
begin
  ProbeMarkerDirectory := ExcludeTrailingPathDelimiter(AMarkerDirectory);
  ForceDirectories(ProbeMarkerDirectory);
  ProbeMaximumSpawns := AMaximumSpawns;
  ProbeAttempts := 0;
  ProbeEscapes := 0;
  ProbeUnprotected := 0;
  ProbeError := '';
  if not Assigned(Spawners) then Spawners := TList.Create;
  if not Assigned(ReportPaths) then ReportPaths := TStringList.Create;
  if not Assigned(PublishedIdentities) then
    PublishedIdentities := TStringList.Create;
  PublishedIdentities.Clear;
  ProbeControlPath := ProbeMarkerDirectory + '/inherited-control';
  ProbeControlHandle := OpenControlDescriptor(ProbeControlPath,
    ProbeControlIdentity);
  if ProbeControlIdentity = '' then
    RecordError('could not open the inherited control descriptor');
  ResetProcessHandleSetupObservation;
  ProbeFragment := APathFragment;
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
  { Every child has forked once its spawner returned; the control descriptor
    is no longer needed in this process. }
  if ProbeControlHandle <> THandle(-1) then
  begin
    FileClose(ProbeControlHandle);
    ProbeControlHandle := THandle(-1);
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
  Entries: TStringList;
  Index: Integer;
  ReportError: string;
  Spawner: TProbeSpawner;
begin
  Result := 0;
  Entries := TStringList.Create;
  try
    for Index := 0 to Spawners.Count - 1 do
    begin
      Spawner := TProbeSpawner(Spawners[Index]);
      if LoadValidReport(ReportPaths[Index], ProbeControlIdentity, Entries,
           ReportError)
         and Assigned(Spawner.FChild) and Spawner.FChild.Running then
        Inc(Result)
      else if ReportError <> '' then
        RecordError(ReportError);
    end;
  finally
    Entries.Free;
  end;
end;

function CountInheritedIdentities(const AIdentities: TStrings): Integer;
var
  Entries: TStringList;
  Index: Integer;
  ReportError: string;
begin
  Result := 0;
  Entries := TStringList.Create;
  try
    for Index := 0 to ReportPaths.Count - 1 do
    begin
      if not LoadValidReport(ReportPaths[Index], ProbeControlIdentity,
           Entries, ReportError) then
      begin
        RecordError(ReportError);
        Exit(-1);
      end;
      Inc(Result, CountMatches(Entries, AIdentities));
    end;
  finally
    Entries.Free;
  end;
end;

function SpawnGuardProbeInheritedPublications: Integer;
begin
  if PublishedIdentities.Count = 0 then
  begin
    RecordError('no published descriptor identity was recorded');
    Exit(-1);
  end;
  Result := CountInheritedIdentities(PublishedIdentities);
end;

function SpawnGuardProbeInheritedFiles(const APaths: array of string): Integer;
var
  Identities: TStringList;
  Index: Integer;
  Identity: string;
begin
  Identities := TStringList.Create;
  try
    for Index := Low(APaths) to High(APaths) do
    begin
      Identity := FileIdentity(APaths[Index]);
      if Identity <> '' then Identities.Add(Identity);
    end;
    Result := CountInheritedIdentities(Identities);
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
  if Assigned(ReportPaths) then
  begin
    for Index := 0 to ReportPaths.Count - 1 do
      DeleteFile(ReportPaths[Index]);
    ReportPaths.Clear;
  end;
  if ProbeControlHandle <> THandle(-1) then
  begin
    FileClose(ProbeControlHandle);
    ProbeControlHandle := THandle(-1);
  end;
  if ProbeControlPath <> '' then
  begin
    DeleteFile(ProbeControlPath);
    ProbeControlPath := '';
  end;
  if ProbeMarkerDirectory <> '' then RemoveDir(ProbeMarkerDirectory);
end;

function ChildInheritedFileCount(const APaths: array of string;
  const AMarkerDirectory: string): Integer;
var
  Child: TProcess;
  ControlHandle: THandle;
  ControlIdentity, ControlPath, Identity, ReportError, ReportPath: string;
  Entries, Identities: TStringList;
  Index: Integer;
begin
  Result := -1;
  ForceDirectories(AMarkerDirectory);
  ReportPath := IncludeTrailingPathDelimiter(AMarkerDirectory) + 'report';
  ControlPath := IncludeTrailingPathDelimiter(AMarkerDirectory)
    + 'inherited-control';
  Child := nil;
  Entries := TStringList.Create;
  Identities := TStringList.Create;
  ControlHandle := OpenControlDescriptor(ControlPath, ControlIdentity);
  try
    if ControlIdentity = '' then Exit;
    for Index := Low(APaths) to High(APaths) do
    begin
      Identity := FileIdentity(APaths[Index]);
      if Identity <> '' then Identities.Add(Identity);
    end;
    Child := StartReporter(ReportPath);
    if not LoadValidReport(ReportPath, ControlIdentity, Entries,
      ReportError) then Exit;
    Result := CountMatches(Entries, Identities);
  finally
    StopReporter(Child);
    if ControlHandle <> THandle(-1) then FileClose(ControlHandle);
    DeleteFile(ControlPath);
    DeleteFile(ReportPath);
    DeleteFile(ReportPath + '.partial');
    RemoveDir(AMarkerDirectory);
    Identities.Free;
    Entries.Free;
  end;
end;

{ Runs in the spawned reporter child: records the device and inode of every
  descriptor it holds right after exec, publishes the report atomically and
  stays alive until the caller stops it. }
procedure RunDescriptorReporter(const AReportPath: string);
var
  Descriptor: LongInt;
  Info: Stat;
  Report: TStringList;
  Started: QWord;
begin
  Report := TStringList.Create;
  try
    for Descriptor := 0 to REPORTER_DESCRIPTOR_LIMIT - 1 do
      if FpFStat(Descriptor, Info) = 0 then
        Report.Add(IdentityOfInfo(Info))
      else if FpGetErrNo <> ESysEBADF then
        Report.Add(REPORT_ERROR_PREFIX + IntToStr(Descriptor));
    Report.Add(REPORT_END_MARKER);
    Report.SaveToFile(AReportPath + '.partial');
  finally
    Report.Free;
  end;
  if not RenameFile(AReportPath + '.partial', AReportPath) then Halt(1);
  Started := GetTickCount64;
  while GetTickCount64 - Started < REPORTER_LIFETIME_MILLISECONDS do
    Sleep(REPORT_POLL_MILLISECONDS);
  Halt(0);
end;

initialization
  if (ParamCount = 2) and (ParamStr(1) = REPORTER_SWITCH) then
    RunDescriptorReporter(ParamStr(2));

finalization
  ReleaseSpawnGuardProbeChildren;
  Spawners.Free;
  ReportPaths.Free;
  PublishedIdentities.Free;
{$ENDIF}

end.
