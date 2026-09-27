{ Tests.SpawnGuardProbe — deterministic proof that toolkit-state opens keep
  concurrent child spawns out of their open window.

  While armed, every protected open whose path contains the armed fragment
  starts a real child through ExecuteUnmanagedProcess from another thread,
  while the opener still holds the process-handle inheritance guard and has
  not yet marked the descriptor close-on-exec. The probe waits until that
  spawn attempt reaches the guard, then checks that the child has not started.
  Each child records its start in a ready marker and then stays alive, so a
  caller can prove afterwards that the children never kept an inherited
  descriptor or its flock. Compile the caller with -dOBJECTSTORE_TESTING. }
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
{ Children that started while their opener still held the guard. }
function SpawnGuardProbeEscapes: Integer;
{ Children that started and are still alive after disarming. }
function SpawnGuardProbeLiveChildren: Integer;
{ Open descriptors in live children whose target contains APathFragment.
  Linux reads /proc; other Unix targets report zero and rely on the
  caller's flock assertions instead. }
function SpawnGuardProbeInheritedDescriptors(
  const APathFragment: string): Integer;
function SpawnGuardProbeError: string;
procedure ReleaseSpawnGuardProbeChildren;
{$ENDIF}

implementation

{$IFDEF UNIX}
uses
  BaseUnix,
  {$IFDEF LINUX}
  Unix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.ProcessTree;

const
  SPAWN_ATTEMPT_TIMEOUT_MILLISECONDS = 10000;
  CHILD_START_TIMEOUT_MILLISECONDS = 10000;
  GUARD_OBSERVATION_MILLISECONDS = 100;
  POLL_MILLISECONDS = 10;
  CHILD_LIFETIME_SECONDS = '30';

type
  TProbeSpawner = class(TThread)
  private
    FReadyPath: string;
    FChild: TProcess;
    FErrorMessage: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AReadyPath: string);
    destructor Destroy; override;
  end;

var
  ProbeFragment: string = '';
  ProbeMarkerDirectory: string = '';
  ProbeMaximumSpawns: Integer = 0;
  ProbeAttempts: Integer = 0;
  ProbeEscapes: Integer = 0;
  ProbeError: string = '';
  CurrentAttemptPath: string = '';
  Spawners: TList = nil;
  ReadyPaths: TStringList = nil;

procedure CreateMarker(const APath: string);
var
  Handle: THandle;
begin
  Handle := FileCreate(APath);
  if Handle <> THandle(-1) then FileClose(Handle);
end;

function WaitForMarker(const APath: string;
  const ATimeoutMilliseconds: Integer): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    if FileExists(APath) then Exit(True);
    Sleep(POLL_MILLISECONDS);
  until GetTickCount64 - Started >= QWord(ATimeoutMilliseconds);
  Result := FileExists(APath);
end;

procedure RecordError(const AMessage: string);
begin
  if ProbeError = '' then ProbeError := AMessage;
end;

procedure MarkSpawnAttempt;
begin
  CreateMarker(CurrentAttemptPath);
end;

constructor TProbeSpawner.Create(const AReadyPath: string);
begin
  FReadyPath := AReadyPath;
  FChild := nil;
  FErrorMessage := '';
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TProbeSpawner.Destroy;
begin
  if Assigned(FChild) then
  begin
    if FChild.Running then
    begin
      FChild.Terminate(0);
      FChild.WaitOnExit;
    end;
    FChild.Free;
  end;
  inherited Destroy;
end;

procedure TProbeSpawner.Execute;
begin
  try
    FChild := TProcess.Create(nil);
    FChild.Executable := '/bin/sh';
    FChild.Parameters.Add('-c');
    FChild.Parameters.Add(': > "$1"; exec sleep ' + CHILD_LIFETIME_SECONDS);
    FChild.Parameters.Add('spawn-guard-probe');
    FChild.Parameters.Add(FReadyPath);
    FChild.Options := [poNoConsole];
    ExecuteUnmanagedProcess(FChild);
  except
    on E: Exception do FErrorMessage := E.Message;
  end;
end;

procedure ProbeProtectedOpen(const APath: string);
var
  AttemptPath, ReadyPath: string;
begin
  if (ProbeFragment = '') or (Pos(ProbeFragment, APath) = 0) then Exit;
  if ProbeAttempts >= ProbeMaximumSpawns then Exit;
  Inc(ProbeAttempts);
  AttemptPath := ProbeMarkerDirectory + '/spawn-attempt-'
    + IntToStr(ProbeAttempts);
  ReadyPath := ProbeMarkerDirectory + '/child-ready-'
    + IntToStr(ProbeAttempts);
  CurrentAttemptPath := AttemptPath;
  ProcessTreeBeforeUnmanagedSpawnLockTestHook := MarkSpawnAttempt;
  ReadyPaths.Add(ReadyPath);
  Spawners.Add(TProbeSpawner.Create(ReadyPath));
  if not WaitForMarker(AttemptPath, SPAWN_ATTEMPT_TIMEOUT_MILLISECONDS) then
  begin
    RecordError('timed out waiting for a concurrent spawn attempt on '
      + APath);
    Exit;
  end;
  Sleep(GUARD_OBSERVATION_MILLISECONDS);
  if FileExists(ReadyPath) then Inc(ProbeEscapes);
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
  ProbeError := '';
  if not Assigned(Spawners) then Spawners := TList.Create;
  if not Assigned(ReadyPaths) then ReadyPaths := TStringList.Create;
  ProtectedOpenBeforeProtectionTestHook := ProbeProtectedOpen;
end;

procedure DisarmSpawnGuardProbe;
var
  Index: Integer;
  Spawner: TProbeSpawner;
begin
  ProtectedOpenBeforeProtectionTestHook := nil;
  ProbeFragment := '';
  for Index := 0 to Spawners.Count - 1 do
  begin
    Spawner := TProbeSpawner(Spawners[Index]);
    Spawner.WaitFor;
    if Spawner.FErrorMessage <> '' then
      RecordError('probe spawn failed: ' + Spawner.FErrorMessage);
  end;
  ProcessTreeBeforeUnmanagedSpawnLockTestHook := nil;
end;

function SpawnGuardProbeAttempts: Integer;
begin
  Result := ProbeAttempts;
end;

function SpawnGuardProbeEscapes: Integer;
begin
  Result := ProbeEscapes;
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
    if WaitForMarker(ReadyPaths[Index], CHILD_START_TIMEOUT_MILLISECONDS)
       and Assigned(Spawner.FChild) and Spawner.FChild.Running then
      Inc(Result);
  end;
end;

function SpawnGuardProbeInheritedDescriptors(
  const APathFragment: string): Integer;
{$IFDEF LINUX}
var
  Index: Integer;
  Search: TSearchRec;
  DescriptorDirectory, Target: string;
  Spawner: TProbeSpawner;
{$ENDIF}
begin
  Result := 0;
  {$IFDEF LINUX}
  for Index := 0 to Spawners.Count - 1 do
  begin
    Spawner := TProbeSpawner(Spawners[Index]);
    if not Assigned(Spawner.FChild) or not Spawner.FChild.Running then
      Continue;
    DescriptorDirectory := '/proc/' + IntToStr(Spawner.FChild.ProcessID)
      + '/fd';
    if FindFirst(DescriptorDirectory + '/*', faAnyFile, Search) <> 0 then
      Continue;
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        Target := FpReadLink(DescriptorDirectory + '/' + Search.Name);
        if Pos(APathFragment, Target) > 0 then Inc(Result);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  end;
  {$ENDIF}
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
  if Assigned(ReadyPaths) then ReadyPaths.Clear;
end;

initialization

finalization
  ReleaseSpawnGuardProbeChildren;
  Spawners.Free;
  ReadyPaths.Free;
{$ENDIF}

end.
