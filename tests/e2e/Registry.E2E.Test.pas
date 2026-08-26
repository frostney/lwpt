program Registry.E2E.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Pipes,
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
  { The server's connection deadline is 10 seconds; retain two seconds for
    listener and connection teardown before the test force-terminates it. }
  SERVER_STOP_TIMEOUT_MILLISECONDS = 12000;
  SERVER_KILL_TIMEOUT_MILLISECONDS = 2000;
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
    function CurlAttempt(const AURL: string; const AInsecure: Boolean;
      out AExitStatus: Integer; out AStandardError: string;
      out AOutputTruncated, AStandardErrorTruncated: Boolean): string;
    function StopServerAndReturnExit(var AProcess: TProcess): Integer;
    procedure StopServer(var AProcess: TProcess);
    procedure WaitUntilReady(const AURL: string; const AInsecure: Boolean;
      AServer: TProcess);
  protected
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestInitPolicyAndStableIdentityThroughCLI;
    procedure TestForegroundServerSurvivesRestartAndConcurrentReaders;
    procedure TestConfiguredTLSServerCompletesARequest;
    procedure TestTemporaryKeychainResidueIsRecoveredAndCrashSafe;
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

procedure DrainCurlDiagnosticStream(AStream: TInputPipeStream;
  var ADestination: string; var ATruncated: Boolean);
const
  CURL_DIAGNOSTIC_CAPTURE_BYTES = 16 * 1024;
var
  Available, BytesRead, Keep, ReadSize, Remaining: Integer;
  Buffer: array[0..4095] of Byte;
begin
  Available := AStream.NumBytesAvailable;
  while Available > 0 do
  begin
    ReadSize := Length(Buffer);
    if Available < ReadSize then ReadSize := Available;
    BytesRead := AStream.Read(Buffer[0], ReadSize);
    if BytesRead <= 0 then Break;
    Remaining := CURL_DIAGNOSTIC_CAPTURE_BYTES - Length(ADestination);
    Keep := BytesRead;
    if Keep > Remaining then Keep := Remaining;
    if Keep > 0 then
    begin
      SetLength(ADestination, Length(ADestination) + Keep);
      Move(Buffer[0], ADestination[Length(ADestination) - Keep + 1], Keep);
    end;
    if Keep < BytesRead then ATruncated := True;
    Dec(Available, BytesRead);
  end;
end;

{$IFDEF DARWIN}
const
  MAX_TEMPORARY_KEYCHAIN_DIAGNOSTIC_PATHS = 129;

function TemporaryKeychainPathCount(const APID: LongInt): Integer;
var
  Pattern: string;
  Search: TSearchRec;
begin
  Result := 0;
  Pattern := IncludeTrailingPathDelimiter(GetTempDir)
    + ChangeFileExt(ExtractFileName(LwptBinaryPath), '')
    + '-registry-tls-' + IntToStr(APID) + '-*.keychain';
  if FindFirst(Pattern, faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      Inc(Result);
      if Result >= MAX_TEMPORARY_KEYCHAIN_DIAGNOSTIC_PATHS then Break;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TemporaryKeychainPathForProcess(const APID: LongInt): string;
var
  Pattern: string;
  Search: TSearchRec;
begin
  Result := '';
  Pattern := IncludeTrailingPathDelimiter(GetTempDir)
    + ChangeFileExt(ExtractFileName(LwptBinaryPath), '')
    + '-registry-tls-' + IntToStr(APID) + '-*.keychain';
  if FindFirst(Pattern, faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    Result := IncludeTrailingPathDelimiter(GetTempDir) + Search.Name;
  finally
    FindClose(Search);
  end;
end;

procedure RemoveRunOwnedTemporaryKeychain(const APath: string);
var
  Status: Stat;
begin
  if APath = '' then Exit;
  if (FpLStat(PChar(APath), Status) <> 0)
    or ((Status.st_mode and S_IFMT) <> S_IFREG)
    or (Status.st_uid <> FpGetUID) then Exit;
  FpUnlink(PChar(APath));
end;

function CreateDeadProcessID: LongInt;
var
  ProcessInstance: TProcess;
begin
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := '/usr/bin/true';
    ProcessInstance.Options := [poWaitOnExit];
    ProcessInstance.Execute;
    Result := ProcessInstance.ProcessID;
    Expect<Integer>(ProcessInstance.ExitStatus).ToBe(0);
    Expect<Boolean>((FpKill(Result, 0) <> 0)
      and (FpGetErrNo = ESysESRCH)).ToBe(True);
  finally
    ProcessInstance.Free;
  end;
end;
{$ENDIF}

function TRegistryE2EContract.Curl(const AURL: string;
  const AInsecure: Boolean): string;
var
  ExitStatus: Integer;
  OutputTruncated, StandardErrorTruncated: Boolean;
  StandardError: string;
begin
  Result := CurlAttempt(AURL, AInsecure, ExitStatus, StandardError,
    OutputTruncated, StandardErrorTruncated);
end;

function TRegistryE2EContract.CurlAttempt(const AURL: string;
  const AInsecure: Boolean; out AExitStatus: Integer;
  out AStandardError: string; out AOutputTruncated,
  AStandardErrorTruncated: Boolean): string;
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
    ProcessInstance.Options := [poUsePipes];
    Result := '';
    AStandardError := '';
    AOutputTruncated := False;
    AStandardErrorTruncated := False;
    ProcessInstance.Execute;
    while ProcessInstance.Running do
    begin
      DrainCurlDiagnosticStream(ProcessInstance.Output, Result,
        AOutputTruncated);
      DrainCurlDiagnosticStream(ProcessInstance.Stderr, AStandardError,
        AStandardErrorTruncated);
      Sleep(10);
    end;
    DrainCurlDiagnosticStream(ProcessInstance.Output, Result,
      AOutputTruncated);
    DrainCurlDiagnosticStream(ProcessInstance.Stderr, AStandardError,
      AStandardErrorTruncated);
    ProcessInstance.WaitOnExit;
    AExitStatus := ProcessInstance.ExitStatus;
    if AExitStatus <> 0 then Result := '';
  finally
    ProcessInstance.Free;
  end;
end;

function WaitForServerExit(AProcess: TProcess;
  const ATimeoutMilliseconds: QWord): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while AProcess.Running
    and (GetTickCount64 - StartedAt < ATimeoutMilliseconds) do Sleep(10);
  Result := not AProcess.Running;
end;

function TRegistryE2EContract.StopServerAndReturnExit(
  var AProcess: TProcess): Integer;
var
  Forced: Boolean;
  FailureMessage: string;
  ProcessInstance: TProcess;
begin
  Result := -1;
  if not Assigned(AProcess) then Exit;
  ProcessInstance := AProcess;
  AProcess := nil;
  Forced := False;
  FailureMessage := '';
  try
    if ProcessInstance.Running then
    begin
      {$IFDEF UNIX}
      FpKill(ProcessInstance.ProcessID, SIGTERM);
      {$ELSE}
      ProcessInstance.Terminate(1);
      {$ENDIF}
    end;
    if not WaitForServerExit(ProcessInstance,
      SERVER_STOP_TIMEOUT_MILLISECONDS) then
    begin
      Forced := True;
      {$IFDEF UNIX}
      FpKill(ProcessInstance.ProcessID, SIGKILL);
      {$ELSE}
      ProcessInstance.Terminate(1);
      {$ENDIF}
      if not WaitForServerExit(ProcessInstance,
        SERVER_KILL_TIMEOUT_MILLISECONDS) then
        FailureMessage := 'registry server did not stop after forced '
          + 'termination';
    end;
  finally
    if not ProcessInstance.Running then
    begin
      ProcessInstance.WaitOnExit;
      Result := ProcessInstance.ExitStatus;
    end;
    ProcessInstance.Free;
  end;
  if Forced and (FailureMessage = '') then
    FailureMessage := Format('registry server exceeded its %d ms shutdown '
      + 'bound and required forced termination',
      [SERVER_STOP_TIMEOUT_MILLISECONDS]);
  if FailureMessage <> '' then
  begin
    if ExceptObject <> nil then
      WriteLn(StdErr, 'registry E2E cleanup: ', FailureMessage)
    else raise Exception.Create(FailureMessage);
  end;
end;

procedure TRegistryE2EContract.StopServer(var AProcess: TProcess);
var
  IgnoredExitStatus: Integer;
begin
  IgnoredExitStatus := StopServerAndReturnExit(AProcess);
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
    WaitUntilReady(DiscoveryURL, False, Server);
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
  const AInsecure: Boolean; AServer: TProcess);
var
  ExitState, KeychainState, StandardError: string;
  ExitStatus: Integer;
  OutputTruncated, Running, StandardErrorTruncated: Boolean;
  StartedAt: QWord;
  {$IFDEF DARWIN}
  KeychainPaths: Integer;
  {$ENDIF}
begin
  ExitStatus := -1;
  StandardError := '';
  StartedAt := GetTickCount64;
  repeat
    if Pos('lwpt-registry-discovery-v1', CurlAttempt(AURL, AInsecure,
      ExitStatus, StandardError, OutputTruncated,
      StandardErrorTruncated)) > 0 then Exit;
    Sleep(25);
  until GetTickCount64 - StartedAt >= 10000;
  Running := Assigned(AServer) and AServer.Running;
  if Running then ExitState := 'running'
  else if Assigned(AServer) then ExitState := IntToStr(AServer.ExitStatus)
  else ExitState := 'unavailable';
  {$IFDEF DARWIN}
  if Assigned(AServer) then
  begin
    KeychainPaths := TemporaryKeychainPathCount(AServer.ProcessID);
    if KeychainPaths >= MAX_TEMPORARY_KEYCHAIN_DIAGNOSTIC_PATHS then
      KeychainState := '>='
        + IntToStr(MAX_TEMPORARY_KEYCHAIN_DIAGNOSTIC_PATHS)
    else KeychainState := IntToStr(KeychainPaths);
  end
  else KeychainState := 'unavailable';
  {$ELSE}
  KeychainState := 'not-applicable';
  {$ENDIF}
  raise Exception.CreateFmt('registry server did not become ready: '
    + 'curl exit=%d stdout-truncated=%s stderr=%s '
    + 'stderr-truncated=%s; server running=%s exit=%s; '
    + 'temporary keychain paths=%s', [ExitStatus,
    BoolToStr(OutputTruncated, True), QuotedStr(StandardError),
    BoolToStr(StandardErrorTruncated, True), BoolToStr(Running, True),
    ExitState, KeychainState]);
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
    WaitUntilReady(DiscoveryURL, False, Server);
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
      Readers[Index].Parameters.Add('--fail');
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
    WaitUntilReady(DiscoveryURL, False, Server);
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
    WaitUntilReady(DiscoveryURL, True, Server);
    Expect<Boolean>(Pos('lwpt-registry-checkpoint-v1', Curl(ResourceURL,
      True)) > 0).ToBe(True);
  finally
    StopServer(Server);
  end;
end;

procedure TRegistryE2EContract.TestTemporaryKeychainResidueIsRecoveredAndCrashSafe;
{$IFDEF DARWIN}
const
  TEST_NONCE =
    '0000000000000000000000000000000000000000000000000000000000000000';
  TEST_SYMLINK_NONCE =
    '1111111111111111111111111111111111111111111111111111111111111111';
var
  BoundedPaths: array of string;
  CrashedPath, DataDirectory, DiscoveryURL, LivePath, Nonce,
    ResiduePath, SymlinkPath: string;
  CrashedPID, DeadPID, RecoveredPID: LongInt;
  Index: Integer;
  Init: TLwptResult;
  Residue: TFileStream;
  Server: TProcess;
  Status: Stat;
begin
  CrashedPath := '';
  LivePath := '';
  DeadPID := CreateDeadProcessID;
  ResiduePath := IncludeTrailingPathDelimiter(GetTempDir)
    + ChangeFileExt(ExtractFileName(LwptBinaryPath), '')
    + '-registry-tls-' + IntToStr(DeadPID) + '-' + TEST_NONCE
    + '.keychain';
  SymlinkPath := IncludeTrailingPathDelimiter(GetTempDir)
    + ChangeFileExt(ExtractFileName(LwptBinaryPath), '')
    + '-registry-tls-' + IntToStr(DeadPID) + '-' + TEST_SYMLINK_NONCE
    + '.keychain';
  SetLength(BoundedPaths, 129);
  for Index := 0 to High(BoundedPaths) do
  begin
    Nonce := LowerCase(StringOfChar('0', 60) + IntToHex(Index + 2, 4));
    BoundedPaths[Index] := IncludeTrailingPathDelimiter(GetTempDir)
      + ChangeFileExt(ExtractFileName(LwptBinaryPath), '')
      + '-registry-tls-' + IntToStr(DeadPID) + '-' + Nonce + '.keychain';
  end;
  Server := nil;
  try
    SysUtils.DeleteFile(ResiduePath);
    Residue := TFileStream.Create(ResiduePath, fmCreate);
    Residue.Free;
    FpUnlink(PChar(SymlinkPath));
    Expect<Integer>(FpSymlink(PChar(ResiduePath),
      PChar(SymlinkPath))).ToBe(0);
    DataDirectory := FScratch + '/crash-safe-tls-origin';
    DiscoveryURL := 'https://localhost:' + IntToStr(BasePort + 5)
      + '/.well-known/lwpt-registry';
    Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
      '--base-url', 'https://localhost:' + IntToStr(BasePort + 5), '--port',
      IntToStr(BasePort + 5), '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
      '--tls-password-env', TLS_PASSWORD_ENV], '',
      [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
    Expect<Integer>(Init.ExitCode).ToBe(0);
    for Index := 0 to High(BoundedPaths) do
    begin
      FpUnlink(PChar(BoundedPaths[Index]));
      Expect<Integer>(FpSymlink(PChar(ResiduePath),
        PChar(BoundedPaths[Index]))).ToBe(0);
    end;
    Server := StartServer(DataDirectory, True);
    for Index := 1 to 200 do
    begin
      if not Server.Running then Break;
      Sleep(10);
    end;
    Expect<Boolean>(Server.Running).ToBe(False);
    Expect<Boolean>(Server.ExitStatus <> 0).ToBe(True);
    StopServer(Server);
    Server := nil;
    for Index := 0 to High(BoundedPaths) do
      FpUnlink(PChar(BoundedPaths[Index]));
    SysUtils.DeleteFile(ResiduePath);
    Residue := TFileStream.Create(ResiduePath, fmCreate);
    Residue.Free;
    Server := StartServer(DataDirectory, True);
    WaitUntilReady(DiscoveryURL, True, Server);
    Expect<Boolean>(FileExists(ResiduePath)).ToBe(False);
    Expect<Integer>(FpLStat(PChar(SymlinkPath), Status)).ToBe(0);
    Expect<Integer>(TemporaryKeychainPathCount(Server.ProcessID)).ToBe(1);
    CrashedPath := TemporaryKeychainPathForProcess(Server.ProcessID);
    Expect<Boolean>(CrashedPath <> '').ToBe(True);
    Expect<Integer>(FpLStat(PChar(CrashedPath), Status)).ToBe(0);
    Expect<Integer>(Status.st_mode and S_IFMT).ToBe(S_IFREG);
    Expect<Integer>(Status.st_mode and (S_IRWXU or S_IRWXG or S_IRWXO))
      .ToBe(S_IRUSR or S_IWUSR);
    Expect<QWord>(Status.st_uid).ToBe(FpGetUID);
    CrashedPID := Server.ProcessID;
    Expect<Integer>(FpKill(CrashedPID, SIGKILL)).ToBe(0);
    Server.WaitOnExit;
    Expect<Boolean>(Server.Running).ToBe(False);
    Expect<Integer>(TemporaryKeychainPathCount(CrashedPID)).ToBe(1);
    StopServer(Server);
    Server := StartServer(DataDirectory, True);
    WaitUntilReady(DiscoveryURL, True, Server);
    RecoveredPID := Server.ProcessID;
    Expect<Integer>(TemporaryKeychainPathCount(CrashedPID)).ToBe(0);
    Expect<Integer>(TemporaryKeychainPathCount(RecoveredPID)).ToBe(1);
    LivePath := TemporaryKeychainPathForProcess(RecoveredPID);
    Expect<Integer>(StopServerAndReturnExit(Server)).ToBe(0);
    Expect<Integer>(TemporaryKeychainPathCount(RecoveredPID)).ToBe(0);
  finally
    try
      StopServer(Server);
    finally
      RemoveRunOwnedTemporaryKeychain(CrashedPath);
      RemoveRunOwnedTemporaryKeychain(LivePath);
      SysUtils.DeleteFile(ResiduePath);
      FpUnlink(PChar(SymlinkPath));
      for Index := 0 to High(BoundedPaths) do
        FpUnlink(PChar(BoundedPaths[Index]));
    end;
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(True).ToBe(True);
end;
{$ENDIF}

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
    WaitUntilReady(DiscoveryURL, True, Server);
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
  Test('temporary TLS keychain retains live storage and recovers a hard crash',
    TestTemporaryKeychainResidueIsRecoveredAndCrashSafe);
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
