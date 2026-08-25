program Registry.E2E.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  Sockets,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  TLS_PASSWORD_ENV = 'LWPT_REGISTRY_E2E_PASSWORD';
  TLS_PASSWORD = 'test-only';
  REGISTRY_TLS_FIXTURE =
    'tests/fixtures/registry/localhost-native-identity.p12';

type
  TRegistryE2EContract = class(TTestSuite)
  private
    FScratch: string;
    function BasePort: Integer;
    function StartServer(const ADataDirectory: string;
      const ATLS: Boolean): TProcess;
    function Curl(const AURL: string; const AInsecure: Boolean): string;
    procedure StopServer(AProcess: TProcess);
    procedure WaitUntilReady(const AURL: string; const AInsecure: Boolean);
  protected
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestInitPolicyAndStableIdentityThroughCLI;
    procedure TestForegroundServerSurvivesRestartAndConcurrentReaders;
    procedure TestConfiguredTLSServerCompletesARequest;
    procedure TestIdleTLSHandshakesExpireAndReleaseAdmission;
    procedure TestSilentServeUsesPersistedConfiguration;
    procedure TestSlowClientsAreBoundedByOneDeadline;
  end;

function TRegistryE2EContract.BasePort: Integer;
begin
  Result := 20000 + (GetProcessID mod 20000);
end;

function TRegistryE2EContract.StartServer(const ADataDirectory: string;
  const ATLS: Boolean): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := LwptBinaryPath;
  Result.CurrentDirectory := FScratch;
  Result.Parameters.Add('registry');
  Result.Parameters.Add('serve');
  Result.Parameters.Add('--data-dir');
  Result.Parameters.Add(ADataDirectory);
  if ATLS then ConfigureProcessEnvironment(Result,
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Result.Options := [];
  Result.Execute;
end;

function ReadProcessOutput(AProcess: TProcess): string;
var
  BytesRead, Total: Integer;
  Buffer: array[0..4095] of Byte;
begin
  Result := '';
  Total := 0;
  repeat
    BytesRead := AProcess.Output.Read(Buffer[0], Length(Buffer));
    if BytesRead > 0 then
    begin
      SetLength(Result, Total + BytesRead);
      Move(Buffer[0], Result[Total + 1], BytesRead);
      Inc(Total, BytesRead);
    end;
  until BytesRead <= 0;
end;

function TRegistryE2EContract.Curl(const AURL: string;
  const AInsecure: Boolean): string;
var
  ProcessInstance: TProcess;
begin
  ProcessInstance := TProcess.Create(nil);
  try
    {$IFDEF MSWINDOWS}
    ProcessInstance.Executable := 'curl.exe';
    {$ELSE}
    ProcessInstance.Executable := 'curl';
    {$ENDIF}
    ProcessInstance.Parameters.Add('--silent');
    ProcessInstance.Parameters.Add('--show-error');
    ProcessInstance.Parameters.Add('--max-time');
    ProcessInstance.Parameters.Add('3');
    if AInsecure then ProcessInstance.Parameters.Add('--insecure');
    ProcessInstance.Parameters.Add(AURL);
    ProcessInstance.Options := [poUsePipes, poWaitOnExit];
    ProcessInstance.Execute;
    Result := ReadProcessOutput(ProcessInstance);
    if ProcessInstance.ExitStatus <> 0 then Result := '';
  finally
    ProcessInstance.Free;
  end;
end;

procedure TRegistryE2EContract.StopServer(AProcess: TProcess);
begin
  if not Assigned(AProcess) then Exit;
  if AProcess.Running then
  begin
    {$IFDEF UNIX}
    FpKill(AProcess.ProcessID, SIGTERM);
    {$ELSE}
    AProcess.Terminate(1);
    {$ENDIF}
  end;
  AProcess.WaitOnExit;
  AProcess.Free;
end;

procedure TRegistryE2EContract.TestSilentServeUsesPersistedConfiguration;
var
  ResultValue: TLwptResult;
begin
  ResultValue := RunLwpt(['registry', 'serve', '--silent', '--data-dir',
    FScratch + '/missing']);
  Expect<Integer>(ResultValue.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('serve accepts only', ResultValue.Stderr) = 0)
    .ToBe(True);
  Expect<Boolean>(Pos('origin_not_initialized:', ResultValue.Stderr) > 0)
    .ToBe(True);
end;

procedure TRegistryE2EContract.TestSlowClientsAreBoundedByOneDeadline;
var
  Address: TInetSockAddr;
  DataDirectory, DiscoveryURL: string;
  Init: TLwptResult;
  Index: Integer;
  Server: TProcess;
  SlowSockets: array[0..39] of TSocket;
  Partial: AnsiString;
begin
  DataDirectory := FScratch + '/slow-origin';
  DiscoveryURL := 'http://localhost:' + IntToStr(BasePort + 3)
    + '/.well-known/lwpt-registry';
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'http://localhost:' + IntToStr(BasePort + 3), '--port',
    IntToStr(BasePort + 3)]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := StartServer(DataDirectory, False);
  for Index := 0 to High(SlowSockets) do SlowSockets[Index] := -1;
  try
    WaitUntilReady(DiscoveryURL, False);
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(BasePort + 3);
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    Partial := 'GET /';
    for Index := 0 to High(SlowSockets) do
    begin
      SlowSockets[Index] := fpSocket(AF_INET, SOCK_STREAM, 0);
      if (SlowSockets[Index] >= 0)
        and (fpConnect(SlowSockets[Index], @Address, SizeOf(Address)) = 0) then
        fpSend(SlowSockets[Index], @Partial[1], Length(Partial), 0);
    end;
    Sleep(11000);
    Expect<Boolean>(Pos('registry-discovery-v1', Curl(DiscoveryURL,
      False)) > 0).ToBe(True);
  finally
    for Index := 0 to High(SlowSockets) do
      if SlowSockets[Index] >= 0 then
      begin
        fpShutdown(SlowSockets[Index], 2);
        CloseSocket(SlowSockets[Index]);
      end;
    StopServer(Server);
  end;
end;

procedure TRegistryE2EContract.WaitUntilReady(const AURL: string;
  const AInsecure: Boolean);
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    if Pos('lwpt-registry-discovery-v1', Curl(AURL, AInsecure)) > 0 then Exit;
    Sleep(25);
  until GetTickCount64 - StartedAt >= 10000;
  raise Exception.Create('registry server did not become ready');
end;

procedure TRegistryE2EContract.BeforeEach;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
  FScratch := CreateScratchRoot('registry-e2e');
end;

procedure TRegistryE2EContract.AfterAll;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
end;

procedure TRegistryE2EContract.TestInitPolicyAndStableIdentityThroughCLI;
var
  ControlRejected, First, Reconfigured, Rejected: TLwptResult;
  ControlDirectory, DataDirectory: string;
begin
  DataDirectory := FScratch + '/origin';
  First := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(BasePort), '--identity',
    'https://identity.example', '--port', IntToStr(BasePort), '--tls-pkcs12',
    REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  DumpRunFailure('registry init', First, 0);
  Expect<Integer>(First.ExitCode).ToBe(0);
  Reconfigured := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(BasePort + 1), '--port',
    IntToStr(BasePort + 1), '--tls-pkcs12',
    REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  DumpRunFailure('registry reconfiguration', Reconfigured, 0);
  Expect<Integer>(Reconfigured.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('https://identity.example', Reconfigured.Stdout) > 0)
    .ToBe(True);
  Rejected := RunLwpt(['registry', 'init', '--data-dir',
    FScratch + '/remote-http', '--base-url', 'http://example.com',
    '--listen', '0.0.0.0']);
  DumpRunFailure('remote plain HTTP rejection', Rejected, 1);
  Expect<Integer>(Rejected.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('insecure_transport:', Rejected.Stderr) > 0).ToBe(True);
  ControlDirectory := FScratch + '/control-origin';
  { DEL crosses both Unix and Windows command-line tokenization unchanged. }
  ControlRejected := RunLwpt(['registry', 'init', '--data-dir',
    ControlDirectory, '--base-url', 'https://localhost:'
    + IntToStr(BasePort + 2), '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV + #127]);
  DumpRunFailure('control-character configuration rejection',
    ControlRejected, 1);
  Expect<Integer>(ControlRejected.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('invalid_configuration:', ControlRejected.Stderr) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(ControlDirectory + '/registry.toml')).ToBe(False);
  Expect<Boolean>(FileExists(ControlDirectory + '/keys/root.seed')).ToBe(False);
  Expect<Boolean>(DirectoryExists(ControlDirectory + '/keys')).ToBe(False);
  Expect<Boolean>(DirectoryExists(ControlDirectory + '/snapshots')).ToBe(False);
  Expect<Boolean>(DirectoryExists(ControlDirectory + '/checkpoints'))
    .ToBe(False);
  Expect<Boolean>(DirectoryExists(ControlDirectory + '/state')).ToBe(False);
end;

procedure TRegistryE2EContract.TestForegroundServerSurvivesRestartAndConcurrentReaders;
var
  DataDirectory, DiscoveryURL, ResourceURL: string;
  Init: TLwptResult;
  Index: Integer;
  Readers: array[0..7] of TProcess;
  Server: TProcess;
  {$IFDEF MSWINDOWS}
  SecondServer: TProcess;
  StartedAt: QWord;
  {$ENDIF}
begin
  DataDirectory := FScratch + '/plain-origin';
  DiscoveryURL := 'http://localhost:' + IntToStr(BasePort)
    + '/registry%2Fstable//instance/.well-known/lwpt-registry';
  ResourceURL := 'http://localhost:' + IntToStr(BasePort)
    + '/registry%2Fstable//instance/v1/checkpoints/latest.toml';
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'http://localhost:' + IntToStr(BasePort)
    + '/registry%2Fstable//instance', '--port', IntToStr(BasePort)]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := StartServer(DataDirectory, False);
  try
    WaitUntilReady(DiscoveryURL, False);
    {$IFDEF MSWINDOWS}
    SecondServer := StartServer(DataDirectory, False);
    try
      StartedAt := GetTickCount64;
      while SecondServer.Running and (GetTickCount64 - StartedAt < 3000) do
        Sleep(10);
      Expect<Boolean>(SecondServer.Running).ToBe(False);
      if not SecondServer.Running then
      begin
        SecondServer.WaitOnExit;
        Expect<Boolean>(SecondServer.ExitStatus <> 0).ToBe(True);
      end;
      Expect<Boolean>(Pos('lwpt-registry-discovery-v1', Curl(DiscoveryURL,
        False)) > 0).ToBe(True);
    finally
      StopServer(SecondServer);
    end;
    {$ENDIF}
    for Index := 0 to High(Readers) do
    begin
      Readers[Index] := TProcess.Create(nil);
      {$IFDEF MSWINDOWS}
      Readers[Index].Executable := 'curl.exe';
      {$ELSE}
      Readers[Index].Executable := 'curl';
      {$ENDIF}
      Readers[Index].Parameters.Add('--silent');
      Readers[Index].Parameters.Add('--max-time');
      Readers[Index].Parameters.Add('3');
      Readers[Index].Parameters.Add('--output');
      {$IFDEF MSWINDOWS}
      Readers[Index].Parameters.Add('NUL');
      {$ELSE}
      Readers[Index].Parameters.Add('/dev/null');
      {$ENDIF}
      Readers[Index].Parameters.Add(ResourceURL);
      Readers[Index].Execute;
    end;
    for Index := 0 to High(Readers) do
    begin
      Readers[Index].WaitOnExit;
      Expect<Integer>(Readers[Index].ExitStatus).ToBe(0);
      Readers[Index].Free;
    end;
  finally
    StopServer(Server);
  end;
  Server := StartServer(DataDirectory, False);
  try
    WaitUntilReady(DiscoveryURL, False);
    Expect<Boolean>(Pos('lwpt-registry-checkpoint-v1', Curl(ResourceURL,
      False)) > 0).ToBe(True);
  finally
    StopServer(Server);
  end;
end;

procedure TRegistryE2EContract.TestConfiguredTLSServerCompletesARequest;
var
  DataDirectory, DiscoveryURL, ResourceURL: string;
  Init: TLwptResult;
  Server: TProcess;
begin
  DataDirectory := FScratch + '/tls-origin';
  DiscoveryURL := 'https://localhost:' + IntToStr(BasePort + 2)
    + '/.well-known/lwpt-registry';
  ResourceURL := 'https://localhost:' + IntToStr(BasePort + 2)
    + '/v1/checkpoints/latest.toml';
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(BasePort + 2), '--port',
    IntToStr(BasePort + 2), '--tls-pkcs12',
    REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := StartServer(DataDirectory, True);
  try
    WaitUntilReady(DiscoveryURL, True);
    Expect<Boolean>(Pos('lwpt-registry-checkpoint-v1', Curl(ResourceURL,
      True)) > 0).ToBe(True);
  finally
    StopServer(Server);
  end;
end;

procedure TRegistryE2EContract.TestIdleTLSHandshakesExpireAndReleaseAdmission;
var
  Address: TInetSockAddr;
  DataDirectory, DiscoveryURL: string;
  IdleSockets: array[0..31] of TSocket;
  Index: Integer;
  Init: TLwptResult;
  Server: TProcess;
begin
  DataDirectory := FScratch + '/idle-tls-origin';
  DiscoveryURL := 'https://localhost:' + IntToStr(BasePort + 4)
    + '/.well-known/lwpt-registry';
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(BasePort + 4), '--port',
    IntToStr(BasePort + 4), '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := StartServer(DataDirectory, True);
  for Index := 0 to High(IdleSockets) do IdleSockets[Index] := -1;
  try
    WaitUntilReady(DiscoveryURL, True);
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(BasePort + 4);
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    for Index := 0 to High(IdleSockets) do
    begin
      IdleSockets[Index] := fpSocket(AF_INET, SOCK_STREAM, 0);
      Expect<Boolean>(IdleSockets[Index] >= 0).ToBe(True);
      Expect<Integer>(fpConnect(IdleSockets[Index], @Address,
        SizeOf(Address))).ToBe(0);
    end;
    Sleep(11000);
    Expect<Boolean>(Server.Running).ToBe(True);
    Expect<Boolean>(Pos('lwpt-registry-discovery-v1', Curl(DiscoveryURL,
      True)) > 0).ToBe(True);
  finally
    for Index := 0 to High(IdleSockets) do
      if IdleSockets[Index] >= 0 then
      begin
        fpShutdown(IdleSockets[Index], 2);
        CloseSocket(IdleSockets[Index]);
      end;
    StopServer(Server);
  end;
end;

procedure TRegistryE2EContract.SetupTests;
begin
  Test('CLI init preserves identity and rejects remote plain HTTP',
    TestInitPolicyAndStableIdentityThroughCLI);
  Test('foreground server survives restart and concurrent readers',
    TestForegroundServerSurvivesRestartAndConcurrentReaders);
  Test('configured TLS server completes a request',
    TestConfiguredTLSServerCompletesARequest);
  Test('idle TLS handshakes expire and release admission',
    TestIdleTLSHandshakesExpireAndReleaseAdmission);
  Test('silent serve uses persisted configuration',
    TestSilentServeUsesPersistedConfiguration);
  Test('slow clients are bounded by one deadline',
    TestSlowClientsAreBoundedByOneDeadline);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryE2EContract.Create(
    'registry CLI and lifecycle'));
  TestRunnerProgram.Run;
end.
