unit Tests.RegistryProcess;

{$mode delphi}{$H+}

interface

uses
  Process,
  SysUtils;

const
  { Bound for each readiness phase of a started registry child. }
  RegistryReadyMilliseconds = 5000;

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

{ A loopback port the kernel chose and released; see LaunchRegistryCLI for
  recovery when another process takes it before the registry binds. }
function FindAvailableRegistryTestPort: Word;
{ Moves an initialized data directory's transport to APort and returns the
  new base URL, keeping its scheme, host, and path. The origin identity and
  role stay as initialized. }
function RelocateRegistryPortTo(const ADataDirectory, ABaseURL: string;
  const APort: Word): string;
{ Starts `registry serve` and returns once this child has announced that it
  bound ABaseURL's port, so no other process can be answering there. A port
  taken between selection and bind is recovered deterministically: the data
  directory is moved to a fresh port, ABaseURL is updated (keeping its scheme
  and path), and the start is retried a bounded number of times. AEnvironment
  entries ("KEY=value") are added to the inherited environment, and a
  nonempty AWorkingDirectory becomes the child's current directory, and a
  nonempty AExecutable replaces LwptBinaryPath (e.g. the test build). Callers
  that serve HTTPS, or that probe readiness themselves, use this directly. }
function LaunchRegistryCLI(const ADataDirectory: string; var ABaseURL: string;
  const AEnvironment: array of string; const AWorkingDirectory: string = '';
  const AAllowRelocation: Boolean = True;
  const AExecutable: string = ''): TProcess;
procedure StopRegistryCLI(var AProcess: TProcess);

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ELSE}
  Windows,
  {$ENDIF}
  Classes,
  Tests.LwptSubprocess,
  Tests.RegistryServer;

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

{ The port is free when observed but not reserved; LaunchRegistryCLI proves
  that the listener it reaches is the registry it started. }
function FindAvailableRegistryTestPort: Word;
var
  Reservation: TRegistryTestServer;
begin
  Reservation := TRegistryTestServer.Create(nil);
  try
    Result := Reservation.Port;
  finally
    Reservation.Free;
  end;
end;

const
  RegistryStartAttempts = 5;

function RelocateRegistryPortTo(const ADataDirectory, ABaseURL: string;
  const APort: Word): string;
var
  Lines: TStringList;
  Index: Integer;
  Authority, Host, Path: string;
begin
  Authority := Copy(ABaseURL, Pos('://', ABaseURL) + 3, MaxInt);
  Path := '';
  if Pos('/', Authority) > 0 then
  begin
    Path := Copy(Authority, Pos('/', Authority), MaxInt);
    Authority := Copy(Authority, 1, Pos('/', Authority) - 1);
  end;
  { Test registries use a DNS name or an IPv4 address, never IPv6. }
  Host := Authority;
  if Pos(':', Host) > 0 then Host := Copy(Host, 1, Pos(':', Host) - 1);
  Result := Copy(ABaseURL, 1, Pos('://', ABaseURL) + 2) + Host + ':'
    + IntToStr(APort) + Path;
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.LoadFromFile(ADataDirectory + '/registry.toml');
    for Index := 0 to Lines.Count - 1 do
      if Pos('base_url = ', Lines[Index]) = 1 then
        Lines[Index] := 'base_url = "' + Result + '"'
      else if Pos('port = ', Lines[Index]) = 1 then
        Lines[Index] := 'port = ' + IntToStr(APort);
    Lines.SaveToFile(ADataDirectory + '/registry.toml');
  finally
    Lines.Free;
  end;
end;

{ Moves an initialized data directory to a newly selected port. }
function RelocateRegistryPort(const ADataDirectory, ABaseURL: string): string;
begin
  Result := RelocateRegistryPortTo(ADataDirectory, ABaseURL,
    FindAvailableRegistryTestPort);
end;

function LaunchRegistryCLI(const ADataDirectory: string; var ABaseURL: string;
  const AEnvironment: array of string; const AWorkingDirectory: string;
  const AAllowRelocation: Boolean; const AExecutable: string): TProcess;
var
  Started: QWord;
  Attempt: Integer;
  Collided: Boolean;
  ExitState, Diagnostics, Output: string;
begin
  Result := nil;
  for Attempt := 1 to RegistryStartAttempts do
  begin
    Result := TProcess.Create(nil);
    if AExecutable <> '' then Result.Executable := AExecutable
    else Result.Executable := LwptBinaryPath;
    Result.Options := [poUsePipes];
    if AWorkingDirectory <> '' then
      Result.CurrentDirectory := AWorkingDirectory;
    Result.Parameters.Add('registry');
    Result.Parameters.Add('serve');
    Result.Parameters.Add('--data-dir');
    Result.Parameters.Add(ADataDirectory);
    if Length(AEnvironment) > 0 then
      ConfigureProcessEnvironment(Result, AEnvironment);
    BindRegistryChildToParent(Result);
    try
      Result.Execute;
      Started := GetTickCount64;
      Output := '';
      repeat
        { The child announces only after binding its own socket, so another
          process answering on the same URL can never satisfy readiness. }
        Output := Output + DrainAvailableStream(Result.Output, 4096);
        if Pos(' listening at ' + ABaseURL, Output) > 0 then Exit;
        if not Result.Running then Break;
        Sleep(10);
      until GetTickCount64 - Started >= RegistryReadyMilliseconds;
      ExitState := 'running';
      if not Result.Running then ExitState := IntToStr(Result.ExitCode)
        + ' (status=' + IntToStr(Result.ExitStatus) + ')';
      Diagnostics := DrainAvailableStream(Result.Stderr, 4096);
      Collided := (not Result.Running) and (Pos('listen_failed:', Diagnostics) > 0);
      { A caller that asserts readiness is refused must not be rescued by
        relocating to a free port. }
      if not Collided or not AAllowRelocation
         or (Attempt = RegistryStartAttempts) then
        raise Exception.Create('registry CLI listener did not become ready after '
          + IntToStr(Attempt) + ' start attempt(s); exit=' + ExitState
          + '; last probe: listener has not announced its bound port; stderr: '
          + Diagnostics);
    except
      StopRegistryCLI(Result);
      raise;
    end;
    { Another process took the port after it was selected. }
    StopRegistryCLI(Result);
    ABaseURL := RelocateRegistryPort(ADataDirectory, ABaseURL);
  end;
end;

procedure StopRegistryCLI(var AProcess: TProcess);
var
  Stopped: TRegistryStopResult;
  FailureMessage: string;
begin
  Stopped := StopRegistryProcess(AProcess);
  FailureMessage := '';
  if not Stopped.Stopped then
    FailureMessage := 'registry CLI listener did not stop after forced termination'
  else if Stopped.Forced then
    FailureMessage := 'registry CLI listener exceeded its 12000 ms shutdown bound';
  if FailureMessage <> '' then
  begin
    if ExceptObject <> nil then
      WriteLn(StdErr, 'registry E2E cleanup: ', FailureMessage)
    else raise Exception.Create(FailureMessage);
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
