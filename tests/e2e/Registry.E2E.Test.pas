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
  Tests.ProcessSupport,
  Tests.RegistryProcess,
  Tests.Scratch;

const
  TLS_PASSWORD_ENV = 'LWPT_REGISTRY_E2E_PASSWORD';
  TLS_PASSWORD = 'test-only';
  REGISTRY_TLS_FIXTURE =
    'tests/fixtures/registry/localhost-native-identity.p12';
  DISCOVERY_PATH = '/.well-known/lwpt-registry';
  CHECKPOINT_PATH = '/v1/checkpoints/latest.toml';

type
  TRegistryE2EContract = class(TTestSuite)
  private
    FScratch: string;
    function StartServer(const ADataDirectory: string;
      const ATLS: Boolean): TProcess;
    function LaunchServer(const ADataDirectory: string;
      var ABaseURL: string; const ATLS: Boolean): TProcess;
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
    procedure TestClientResetDoesNotTerminateServer;
    procedure TestCLIRunPastItsDeadlineIsTerminated;
  end;

{ The port of a base URL of the form scheme://localhost:port[/path]. }
function URLPort(const AURL: string): Word;
var
  Authority: string;
begin
  Authority := Copy(AURL, Pos('://', AURL) + 3, MaxInt);
  if Pos('/', Authority) > 0 then
    Authority := Copy(Authority, 1, Pos('/', Authority) - 1);
  Result := StrToInt(Copy(Authority, Pos(':', Authority) + 1, MaxInt));
end;

{ A base URL on a port the kernel just chose. LaunchServer recovers if another
  process binds it before the registry does. }
function FreshBaseURL(const AScheme, APath: string): string;
begin
  Result := AScheme + '://localhost:' + IntToStr(FindAvailableRegistryTestPort)
    + APath;
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
  BindRegistryChildToParent(Result);
  Result.Execute;
end;

{ Starts a server that is expected to serve: returns once the child announces
  that it bound ABaseURL's port. A port another process took after it was
  chosen moves the data directory to a fresh port and updates ABaseURL. }
function TRegistryE2EContract.LaunchServer(const ADataDirectory: string;
  var ABaseURL: string; const ATLS: Boolean): TProcess;
begin
  if ATLS then
    Result := LaunchRegistryCLI(ADataDirectory, ABaseURL,
      [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD], FScratch)
  else Result := LaunchRegistryCLI(ADataDirectory, ABaseURL, [], FScratch);
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
  SECURE_TRANSPORT_KEYCHAIN_PREFIX = 'secure-transport-server-';

function RegistryTemporaryKeychainPrefix: string;
begin
  Result := ChangeFileExt(ExtractFileName(LwptBinaryPath), '')
    + '-registry-tls-';
end;

function TemporaryKeychainPath(const APrefix: string; const APID: LongInt;
  const ANonce: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) + APrefix
    + IntToStr(APID) + '-' + ANonce + '.keychain';
end;

function TemporaryKeychainPathCountForPrefix(const APrefix: string;
  const APID: LongInt): Integer;
var
  Pattern: string;
  Search: TSearchRec;
begin
  Result := 0;
  Pattern := IncludeTrailingPathDelimiter(GetTempDir) + APrefix
    + IntToStr(APID) + '-*.keychain';
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

function TemporaryKeychainPathCount(const APID: LongInt): Integer;
begin
  Result := TemporaryKeychainPathCountForPrefix(
    RegistryTemporaryKeychainPrefix, APID)
    + TemporaryKeychainPathCountForPrefix(
      SECURE_TRANSPORT_KEYCHAIN_PREFIX, APID);
end;

function TemporaryKeychainPathForPrefix(const APrefix: string;
  const APID: LongInt): string;
var
  Pattern: string;
  Search: TSearchRec;
begin
  Result := '';
  Pattern := IncludeTrailingPathDelimiter(GetTempDir) + APrefix
    + IntToStr(APID) + '-*.keychain';
  if FindFirst(Pattern, faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    Result := IncludeTrailingPathDelimiter(GetTempDir) + Search.Name;
  finally
    FindClose(Search);
  end;
end;

function TemporaryKeychainPathForProcess(const APID: LongInt): string;
begin
  Result := TemporaryKeychainPathForPrefix(
    RegistryTemporaryKeychainPrefix, APID);
  if Result = '' then
    Result := TemporaryKeychainPathForPrefix(
      SECURE_TRANSPORT_KEYCHAIN_PREFIX, APID);
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
    ProcessInstance.Execute;
    Result := ProcessInstance.ProcessID;
    { Running reaps the child on Unix, so its PID is dead once it reports
      the exit. }
    Expect<Boolean>(WaitForRegistryExit(ProcessInstance, 5000)).ToBe(True);
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
const
  { curl's own --max-time normally ends it far sooner than this bound. }
  CURL_BOUND_MILLISECONDS = 15000;
var
  ProcessInstance: TProcess;
  Started: QWord;
  Stopped: TRegistryStopResult;
  TimedOut: Boolean;
begin
  TimedOut := False;
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
    Started := GetTickCount64;
    while ProcessInstance.Running
      and (GetTickCount64 - Started <= CURL_BOUND_MILLISECONDS) do
    begin
      DrainCurlDiagnosticStream(ProcessInstance.Output, Result,
        AOutputTruncated);
      DrainCurlDiagnosticStream(ProcessInstance.Stderr, AStandardError,
        AStandardErrorTruncated);
      Sleep(10);
    end;
    TimedOut := ProcessInstance.Running;
    DrainCurlDiagnosticStream(ProcessInstance.Output, Result,
      AOutputTruncated);
    DrainCurlDiagnosticStream(ProcessInstance.Stderr, AStandardError,
      AStandardErrorTruncated);
  finally
    { The bounded stop path owns and frees the process: a signal only when
      curl is still running, a forced kill after the grace period, and a
      bounded wait until its handles are released. }
    Stopped := StopRegistryProcess(ProcessInstance, 2000, 2000);
  end;
  if not Stopped.Stopped then
    raise Exception.Create('curl did not exit and release its handles');
  AExitStatus := Stopped.ExitStatus;
  if TimedOut then
  begin
    AExitStatus := -1;
    AStandardError := AStandardError + ' [curl exceeded its '
      + IntToStr(CURL_BOUND_MILLISECONDS) + ' ms bound and was stopped]';
  end;
  if AExitStatus <> 0 then Result := '';
end;

function TRegistryE2EContract.StopServerAndReturnExit(
  var AProcess: TProcess): Integer;
var
  Stopped: TRegistryStopResult;
  FailureMessage: string;
begin
  Stopped := StopRegistryProcess(AProcess);
  Result := Stopped.ExitStatus;
  FailureMessage := '';
  if not Stopped.Stopped then
    FailureMessage := 'registry server did not stop after forced termination'
  else if Stopped.Forced then
    FailureMessage := 'registry server exceeded its 12000 ms shutdown '
      + 'bound and required forced termination';
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
  Expect<Boolean>(ForceDirectories(FScratch + '/uninitialized')).ToBe(True);
  ResultValue := RunLwpt(['registry', 'serve', '--silent', '--data-dir',
    FScratch + '/uninitialized']);
  Expect<Integer>(ResultValue.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('origin_not_initialized:', ResultValue.Stderr) > 0)
    .ToBe(True);
  { A regular file, not a directory: the binary itself (with its Windows
    extension, since build/lwpt does not exist there). }
  ResultValue := RunLwpt(['registry', 'serve', '--silent', '--data-dir',
    ExpectedExe(LwptBinaryPath)]);
  Expect<Integer>(ResultValue.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('invalid_registry_path:', ResultValue.Stderr) > 0)
    .ToBe(True);
end;

procedure TRegistryE2EContract.TestSlowClientsAreBoundedByOneDeadline;
var
  Address: TInetSockAddr;
  BaseURL, DataDirectory, DiscoveryURL: string;
  Init: TLwptResult;
  Index: Integer;
  Server: TProcess;
  SlowSockets: array[0..39] of TSocket;
  Partial: AnsiString;
begin
  DataDirectory := FScratch + '/slow-origin';
  BaseURL := FreshBaseURL('http', '');
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL))]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := LaunchServer(DataDirectory, BaseURL, False);
  DiscoveryURL := BaseURL + DISCOVERY_PATH;
  for Index := 0 to High(SlowSockets) do SlowSockets[Index] := -1;
  try
    WaitUntilReady(DiscoveryURL, False, Server);
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(URLPort(BaseURL));
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

procedure TRegistryE2EContract.TestClientResetDoesNotTerminateServer;
{$IFDEF UNIX}
type
  TResetLinger = packed record
    Enabled: LongInt;
    Seconds: LongInt;
  end;
var
  Address: TInetSockAddr;
  BaseURL, DataDirectory, DiscoveryURL: string;
  Index: Integer;
  Init: TLwptResult;
  Linger: TResetLinger;
  Request: AnsiString;
  ResetSocket: TSocket;
  Server: TProcess;
{$ENDIF}
begin
  {$IFDEF UNIX}
  DataDirectory := FScratch + '/reset-origin';
  BaseURL := FreshBaseURL('http', '');
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL))]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := LaunchServer(DataDirectory, BaseURL, False);
  DiscoveryURL := BaseURL + DISCOVERY_PATH;
  try
    WaitUntilReady(DiscoveryURL, False, Server);
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(URLPort(BaseURL));
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    Linger.Enabled := 1;
    Linger.Seconds := 0;
    Request := 'GET /.well-known/lwpt-registry HTTP/1.1'#13#10
      + 'Host: localhost'#13#10'Connection: close'#13#10#13#10;
    for Index := 1 to 128 do
    begin
      ResetSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
      Expect<Boolean>(ResetSocket >= 0).ToBe(True);
      try
        Expect<Integer>(fpConnect(ResetSocket, @Address,
          SizeOf(Address))).ToBe(0);
        Expect<Integer>(fpSetSockOpt(ResetSocket, SOL_SOCKET, SO_LINGER,
          @Linger, SizeOf(Linger))).ToBe(0);
        Expect<Integer>(fpSend(ResetSocket, @Request[1], Length(Request),
          0)).ToBe(Length(Request));
      finally
        CloseSocket(ResetSocket);
      end;
    end;
    Sleep(100);
    Expect<Boolean>(Server.Running).ToBe(True);
    { Every reset connection above still costs the origin a client thread
      that parses the request, builds the response and only then learns
      the peer is gone. Under MAX_ACTIVE_CLIENTS that backlog drains in
      milliseconds on a workstation and in noticeably more on a loaded
      two-core runner, where a single probe fired 100 ms after the burst
      met the cap and came back empty. The property under test is that
      the process survives and serves again — so wait for it the way the
      start-up already does, bounded by the same readiness deadline, with
      the same exit-state diagnostics if it never comes back. }
    WaitUntilReady(DiscoveryURL, False, Server);
    Expect<Boolean>(Server.Running).ToBe(True);
  finally
    StopServer(Server);
  end;
  {$ENDIF}
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
  FirstPort, SecondPort: Word;
begin
  { Nothing listens in this case; the ports only need to be valid. }
  FirstPort := FindAvailableRegistryTestPort;
  SecondPort := FindAvailableRegistryTestPort;
  DataDirectory := FScratch + '/origin';
  First := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(FirstPort), '--identity',
    'https://identity.example', '--port', IntToStr(FirstPort), '--tls-pkcs12',
    REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  DumpRunFailure('registry init', First, 0);
  Expect<Integer>(First.ExitCode).ToBe(0);
  Reconfigured := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', 'https://localhost:' + IntToStr(SecondPort), '--port',
    IntToStr(SecondPort), '--tls-pkcs12',
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
    + IntToStr(FirstPort), '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
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
const
  READERS_BOUND_MILLISECONDS = 15000;
var
  BaseURL, DataDirectory, DiscoveryURL, ResourceURL: string;
  Init: TLwptResult;
  Index: Integer;
  Readers: array[0..7] of TProcess;
  Server: TProcess;
  StartedAt, Elapsed: QWord;
  Exited: Boolean;
  Stopped: TRegistryStopResult;
  {$IFDEF MSWINDOWS}
  SecondServer: TProcess;
  {$ENDIF}
begin
  for Index := 0 to High(Readers) do Readers[Index] := nil;
  DataDirectory := FScratch + '/plain-origin';
  BaseURL := FreshBaseURL('http', '/registry%2Fstable//instance');
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL))]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := LaunchServer(DataDirectory, BaseURL, False);
  DiscoveryURL := BaseURL + DISCOVERY_PATH;
  ResourceURL := BaseURL + CHECKPOINT_PATH;
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
        { Windows signals the handle only after the child's rundown. }
        Expect<Boolean>(WaitForRegistryHandleRelease(SecondServer, 5000))
          .ToBe(True);
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
    { Each reader's --max-time ends it well inside this shared bound. }
    StartedAt := GetTickCount64;
    for Index := 0 to High(Readers) do
    begin
      Elapsed := GetTickCount64 - StartedAt;
      if Elapsed > READERS_BOUND_MILLISECONDS then
        Elapsed := READERS_BOUND_MILLISECONDS;
      Exited := WaitForRegistryExit(Readers[Index],
        READERS_BOUND_MILLISECONDS - Elapsed);
      Stopped := StopRegistryProcess(Readers[Index], 2000, 2000);
      Expect<Boolean>(Exited).ToBe(True);
      Expect<Boolean>(Stopped.Stopped).ToBe(True);
      Expect<Integer>(Stopped.ExitStatus).ToBe(0);
    end;
  finally
    for Index := 0 to High(Readers) do
      StopRegistryProcess(Readers[Index], 2000, 2000);
    StopServer(Server);
  end;
  Server := LaunchServer(DataDirectory, BaseURL, False);
  DiscoveryURL := BaseURL + DISCOVERY_PATH;
  ResourceURL := BaseURL + CHECKPOINT_PATH;
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
  BaseURL, DataDirectory, DiscoveryURL, ResourceURL: string;
  Init: TLwptResult;
  Server: TProcess;
begin
  DataDirectory := FScratch + '/tls-origin';
  BaseURL := FreshBaseURL('https', '');
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL)),
    '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := LaunchServer(DataDirectory, BaseURL, True);
  DiscoveryURL := BaseURL + DISCOVERY_PATH;
  ResourceURL := BaseURL + CHECKPOINT_PATH;
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
  REGISTRY_TEST_NONCE =
    '0000000000000000000000000000000000000000000000000000000000000000';
  REGISTRY_TEST_SYMLINK_NONCE =
    '1111111111111111111111111111111111111111111111111111111111111111';
  SECURE_TRANSPORT_TEST_NONCE =
    '00000000000000000000000000000000';
  SECURE_TRANSPORT_TEST_SYMLINK_NONCE =
    '11111111111111111111111111111111';
var
  BoundedPaths: array of string;
  BaseURL, CrashedPath, DataDirectory, DiscoveryURL, LivePath, Nonce,
    RegistryResiduePath, RegistrySymlinkPath, SecureTransportResiduePath,
    SecureTransportSymlinkPath: string;
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
  RegistryResiduePath := TemporaryKeychainPath(
    RegistryTemporaryKeychainPrefix, DeadPID, REGISTRY_TEST_NONCE);
  RegistrySymlinkPath := TemporaryKeychainPath(
    RegistryTemporaryKeychainPrefix, DeadPID,
    REGISTRY_TEST_SYMLINK_NONCE);
  SecureTransportResiduePath := TemporaryKeychainPath(
    SECURE_TRANSPORT_KEYCHAIN_PREFIX, DeadPID,
    SECURE_TRANSPORT_TEST_NONCE);
  SecureTransportSymlinkPath := TemporaryKeychainPath(
    SECURE_TRANSPORT_KEYCHAIN_PREFIX, DeadPID,
    SECURE_TRANSPORT_TEST_SYMLINK_NONCE);
  SetLength(BoundedPaths, 258);
  for Index := 0 to 128 do
  begin
    Nonce := LowerCase(StringOfChar('0', 60) + IntToHex(Index + 2, 4));
    BoundedPaths[Index] := TemporaryKeychainPath(
      RegistryTemporaryKeychainPrefix, DeadPID, Nonce);
    Nonce := LowerCase(StringOfChar('0', 28) + IntToHex(Index + 2, 4));
    BoundedPaths[Index + 129] := TemporaryKeychainPath(
      SECURE_TRANSPORT_KEYCHAIN_PREFIX, DeadPID, Nonce);
  end;
  Server := nil;
  try
    SysUtils.DeleteFile(RegistryResiduePath);
    SysUtils.DeleteFile(SecureTransportResiduePath);
    Residue := TFileStream.Create(RegistryResiduePath, fmCreate);
    Residue.Free;
    Residue := TFileStream.Create(SecureTransportResiduePath, fmCreate);
    Residue.Free;
    FpUnlink(PChar(RegistrySymlinkPath));
    FpUnlink(PChar(SecureTransportSymlinkPath));
    Expect<Integer>(FpSymlink(PChar(RegistryResiduePath),
      PChar(RegistrySymlinkPath))).ToBe(0);
    Expect<Integer>(FpSymlink(PChar(SecureTransportResiduePath),
      PChar(SecureTransportSymlinkPath))).ToBe(0);
    DataDirectory := FScratch + '/crash-safe-tls-origin';
    BaseURL := FreshBaseURL('https', '');
    Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
      '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL)),
      '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
      '--tls-password-env', TLS_PASSWORD_ENV], '',
      [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
    Expect<Integer>(Init.ExitCode).ToBe(0);
    for Index := 0 to High(BoundedPaths) do
    begin
      FpUnlink(PChar(BoundedPaths[Index]));
      if Index < 129 then
        Expect<Integer>(FpSymlink(PChar(RegistryResiduePath),
          PChar(BoundedPaths[Index]))).ToBe(0)
      else
        Expect<Integer>(FpSymlink(PChar(SecureTransportResiduePath),
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
    SysUtils.DeleteFile(RegistryResiduePath);
    SysUtils.DeleteFile(SecureTransportResiduePath);
    Residue := TFileStream.Create(RegistryResiduePath, fmCreate);
    Residue.Free;
    Residue := TFileStream.Create(SecureTransportResiduePath, fmCreate);
    Residue.Free;
    Server := LaunchServer(DataDirectory, BaseURL, True);
    DiscoveryURL := BaseURL + DISCOVERY_PATH;
    WaitUntilReady(DiscoveryURL, True, Server);
    Expect<Boolean>(FileExists(RegistryResiduePath)
      xor FileExists(SecureTransportResiduePath)).ToBe(True);
    Expect<Integer>(FpLStat(PChar(RegistrySymlinkPath), Status)).ToBe(0);
    Expect<Integer>(FpLStat(PChar(SecureTransportSymlinkPath), Status)).ToBe(0);
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
    Expect<Boolean>(WaitForRegistryExit(Server, 5000)).ToBe(True);
    Expect<Boolean>(Server.Running).ToBe(False);
    Expect<Integer>(TemporaryKeychainPathCount(CrashedPID)).ToBe(1);
    StopServer(Server);
    Server := LaunchServer(DataDirectory, BaseURL, True);
    DiscoveryURL := BaseURL + DISCOVERY_PATH;
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
      SysUtils.DeleteFile(RegistryResiduePath);
      SysUtils.DeleteFile(SecureTransportResiduePath);
      FpUnlink(PChar(RegistrySymlinkPath));
      FpUnlink(PChar(SecureTransportSymlinkPath));
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
  BaseURL, DataDirectory, DiscoveryURL: string;
  IdleSockets: array[0..31] of TSocket;
  Index: Integer;
  Init: TLwptResult;
  Server: TProcess;
begin
  DataDirectory := FScratch + '/idle-tls-origin';
  BaseURL := FreshBaseURL('https', '');
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL)),
    '--tls-pkcs12', REGISTRY_TLS_FIXTURE,
    '--tls-password-env', TLS_PASSWORD_ENV], '',
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Server := LaunchServer(DataDirectory, BaseURL, True);
  DiscoveryURL := BaseURL + DISCOVERY_PATH;
  for Index := 0 to High(IdleSockets) do IdleSockets[Index] := -1;
  try
    WaitUntilReady(DiscoveryURL, True, Server);
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := HToNs(URLPort(BaseURL));
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

{ A CLI run that never exits on its own, `registry serve`, outlives a short
  deadline: RunLwpt must end it within its bounded grace and kill periods
  and fail with the command and the output it captured, never hang. }
procedure TRegistryE2EContract.TestCLIRunPastItsDeadlineIsTerminated;
const
  RUN_DEADLINE_MILLISECONDS = 1500;
var
  BaseURL, DataDirectory, Failure: string;
  Init, Unexpected: TLwptResult;
  StartedAt, Elapsed: QWord;
begin
  DataDirectory := FScratch + '/deadline-origin';
  BaseURL := FreshBaseURL('http', '');
  Init := RunLwpt(['registry', 'init', '--data-dir', DataDirectory,
    '--base-url', BaseURL, '--port', IntToStr(URLPort(BaseURL))]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Failure := '';
  StartedAt := GetTickCount64;
  try
    Unexpected := RunLwpt(['registry', 'serve', '--data-dir', DataDirectory],
      FScratch, [], RUN_DEADLINE_MILLISECONDS);
    Failure := 'returned exit ' + IntToStr(Unexpected.ExitCode);
  except
    on E: ELwptRunTimeout do Failure := E.Message;
  end;
  Elapsed := GetTickCount64 - StartedAt;
  Expect<Boolean>(Pos('exceeded its ' + IntToStr(RUN_DEADLINE_MILLISECONDS)
    + ' ms deadline', Failure) > 0).ToBe(True);
  Expect<Boolean>(Pos('was terminated', Failure) > 0).ToBe(True);
  Expect<Boolean>(Pos('''serve''', Failure) > 0).ToBe(True);
  { The output the child produced before its deadline is reported. }
  Expect<Boolean>(Pos('listening at ' + BaseURL, Failure) > 0).ToBe(True);
  Expect<Boolean>(Elapsed < RUN_DEADLINE_MILLISECONDS
    + CHILD_TERMINATION_GRACE_MILLISECONDS + CHILD_KILL_MILLISECONDS + 3000)
    .ToBe(True);
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
  Test('a CLI run past its deadline is terminated and reported',
    TestCLIRunPastItsDeadlineIsTerminated);
  {$IFDEF UNIX}
  Test('client resets cannot terminate the registry process',
    TestClientResetDoesNotTerminateServer);
  {$ELSE}
  Skip('client resets cannot terminate the registry process',
    TestClientResetDoesNotTerminateServer,
    'SIGPIPE is a Unix socket behavior');
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TRegistryE2EContract.Create(
    'registry CLI and lifecycle'));
  TestRunnerProgram.Run;
end.
