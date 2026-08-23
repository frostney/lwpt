program Registry.E2E.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

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
  if AProcess.Running then AProcess.Terminate(1);
  AProcess.WaitOnExit;
  AProcess.Free;
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
  First, Reconfigured, Rejected: TLwptResult;
  DataDirectory: string;
begin
  DataDirectory := FScratch + '/origin';
  First := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(BasePort), '--identity',
    'https://identity.example', '--port', IntToStr(BasePort), '--tls-pkcs12',
    REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(First.ExitCode).ToBe(0);
  Reconfigured := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(BasePort + 1), '--port',
    IntToStr(BasePort + 1), '--tls-pkcs12',
    REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(Reconfigured.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('https://identity.example', Reconfigured.Stdout) > 0)
    .ToBe(True);
  Rejected := RunLwpt(['registry', 'init', '--data-dir',
    FScratch + '/remote-http', '--base-url', 'http://example.com',
    '--listen', '0.0.0.0']);
  Expect<Integer>(Rejected.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('insecure_transport:', Rejected.Stderr) > 0).ToBe(True);
end;

procedure TRegistryE2EContract.TestForegroundServerSurvivesRestartAndConcurrentReaders;
var
  DataDirectory, DiscoveryURL: string;
  Init: TLwptResult;
  Index: Integer;
  Readers: array[0..7] of TProcess;
  Server: TProcess;
begin
  DataDirectory := FScratch + '/plain-origin';
  DiscoveryURL := 'http://localhost:' + IntToStr(BasePort)
    + '/.well-known/lwpt-registry';
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'http://localhost:' + IntToStr(BasePort), '--port',
    IntToStr(BasePort)]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := StartServer(DataDirectory, False);
  try
    WaitUntilReady(DiscoveryURL, False);
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
      Readers[Index].Parameters.Add(DiscoveryURL);
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
  finally
    StopServer(Server);
  end;
end;

procedure TRegistryE2EContract.TestConfiguredTLSServerCompletesARequest;
var
  DataDirectory, DiscoveryURL: string;
  Init: TLwptResult;
  Server: TProcess;
begin
  DataDirectory := FScratch + '/tls-origin';
  DiscoveryURL := 'https://localhost:' + IntToStr(BasePort + 2)
    + '/.well-known/lwpt-registry';
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
  finally
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
end;

begin
  TestRunnerProgram.AddSuite(TRegistryE2EContract.Create(
    'registry CLI and lifecycle'));
  TestRunnerProgram.Run;
end.
