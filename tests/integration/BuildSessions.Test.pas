{ BuildSessions.Test — concurrent subprocess builds in one project. }
program BuildSessions.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Core,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  FPC_ENV = PROJECT_NAME + '_FPC';
  TEST_FPC_PROXY_ENV = PROJECT_NAME + '_TEST_FPC_PROXY';
  TEST_REAL_FPC_ENV = PROJECT_NAME + '_TEST_REAL_FPC';
  TEST_FPC_READY_DIR_ENV = PROJECT_NAME + '_TEST_FPC_READY_DIR';
  TEST_FPC_RELEASE_ENV = PROJECT_NAME + '_TEST_FPC_RELEASE';
  TEST_FPC_RELEASE_DIR_ENV = PROJECT_NAME + '_TEST_FPC_RELEASE_DIR';
  TEST_FPC_FAIL_TARGET_ENV = PROJECT_NAME + '_TEST_FPC_FAIL_TARGET';
  TestFPCDelayMillisecondsEnvironment = PROJECT_NAME
    + '_TEST_FPC_DELAY_MS';
  TestFPCOutputEnvironment = PROJECT_NAME + '_TEST_FPC_OUTPUT';
  TestWorkerHolderEnvironment = PROJECT_NAME + '_TEST_WORKER_HOLDER';
  TestWorkerHolderReadyEnvironment = PROJECT_NAME
    + '_TEST_WORKER_HOLDER_READY';
  TestWorkerHolderDelayMillisecondsEnvironment = PROJECT_NAME
    + '_TEST_WORKER_HOLDER_DELAY_MS';
  TestHeartbeatIntervalMilliseconds = 75;
  TestHeartbeatJobDurationMilliseconds =
    TestHeartbeatIntervalMilliseconds * 4;
  TestWorkerContentionDurationMilliseconds =
    TestHeartbeatIntervalMilliseconds * 8;
  TestShortCompilerDelayMilliseconds = 20;
  { Ceiling for concurrency barriers (both spawned builds reaching a
    ready/handshake point). Deliberately generous: on a CPU-saturated CI
    runner these builds queue behind many other parallel test programs, so
    a tight window (the previous 10 s) times out with the barrier not yet
    reached and the isolation assertions flake. The happy path exits the
    wait loop as soon as the barrier is seen, so a large ceiling costs
    nothing when the machine is idle. }
  ConcurrencyBarrierCeilingSeconds = 180;

type
  TBuildSessions = class(TTestSuite)
  private
    FScratch: string;
    function CountSessionDirs: Integer;
    function CountSessionJobRoots: Integer;
    function CountReadyFiles(const ADir: string): Integer;
    function TargetReady(const ADir, ATarget: string): Boolean;
    function StartBuildWithEnv(const AProject, ATarget: string;
      const AExtraEnv: array of string): TProcess;
    function StartBuildWithArgs(const AProject: string;
      const AArgs, AExtraEnv: array of string): TProcess;
    function RunLwptWithWorkerEnv(const AArgs: array of string;
      const AProject: string;
      const AExtraEnv: array of string): TLwptResult;
    procedure WriteGraphProject(const AProject: string);
    procedure WriteAppSource(const AChanged: Boolean);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestConcurrentBuildsUseDistinctSessions;
    procedure TestDistinctOutputsPublishIndependentlyFromRootUnits;
    procedure TestFailedBuildPreservesLastSuccessfulOutput;
    procedure TestInFlightSourceChangeRefusesPublication;
    procedure TestInFlightWorkspaceChangeRefusesPublication;
    procedure TestOneInvocationRunsReadyTargetsInParallel;
    procedure TestJobsOneRunsTargetsSequentially;
    procedure TestFailedPrerequisiteBlocksOnlyDependants;
    procedure TestObservableBuildHeartbeatAndVerboseLogs;
    procedure TestFullyContendedBuildEmitsHeartbeat;
    procedure TestBuildFailureReplaysAndPreservesIsolatedLog;
  end;

function SlowUnitName(const AIndex: Integer): string;
begin
  Result := 'SlowUnit' + Format('%.3d', [AIndex]);
end;

{ When a nested build exits with an unexpected code, its captured output
  is the only evidence of why — dump it into the suite's stdout so the
  failure replay surfaces the cause directly in CI output. }
procedure DumpRunFailure(const ALabel: string; const ARun: TLwptResult;
  const AExpectedExit: Integer);
begin
  if ARun.ExitCode = AExpectedExit then Exit;
  WriteLn('RUN FAILURE [', ALabel, '] exit=', ARun.ExitCode,
    ' expected=', AExpectedExit);
  WriteLn('--- captured stdout ---');
  WriteLn(ARun.Stdout);
  WriteLn('--- captured stderr ---');
  WriteLn(ARun.Stderr);
  WriteLn('--- end captured output ---');
end;

{ On a barrier timeout the suite's stdout is captured into its isolated
  log and replayed by the failure path, so these lines surface directly
  in CI output. They separate "the scheduler never dispatched the
  target" (no START line in the replayed build output, no ready file)
  from "the child was dispatched but never signalled ready" (START
  present, ready file absent) without needing access to the runner. }
procedure DumpBarrierDiagnostics(const ALabel, AReadyDir: string);
var
  Search: TSearchRec;
  SawAny: Boolean;
begin
  WriteLn('BARRIER TIMEOUT [', ALabel, '] ready-dir ', AReadyDir, ':');
  SawAny := False;
  if FindFirst(IncludeTrailingPathDelimiter(AReadyDir) + 'ready-*',
    faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Attr and faDirectory) = 0 then
      begin
        WriteLn('  ready: ', Search.Name);
        SawAny := True;
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  if not SawAny then WriteLn('  (no ready files)');
end;

function RunProgram(const APath: string): Integer;
var
  Process: TProcess;
begin
  Process := TProcess.Create(nil);
  try
    Process.Executable := APath;
    Process.Options := [poWaitOnExit];
    Process.Execute;
    Result := Process.ExitStatus;
  finally
    Process.Free;
  end;
end;

procedure TBuildSessions.BeforeAll;
const
  UNIT_COUNT = 80;
var
  i: Integer;
  Body: string;
begin
  { This suite is an orchestrator: its tests start multiple LWPT processes
    and account those children independently. Keep the scheduler's worker
    reservation on the suite process, but do not forward its one-shot token
    to more than one child. }
  ClearWorkerLeaseEnvironment;
  FScratch := CreateScratchRoot('build-sessions');
  RecursiveDelete(FScratch);
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "session-app"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[version]'#10
    + 'output = "source/Version.Generated.inc"'#10
    + 'prefix = "APP"'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app" }'#10);
  WriteAppSource(False);
  for i := 1 to UNIT_COUNT do
  begin
    Body := 'unit ' + SlowUnitName(i) + ';'#10
      + '{$mode delphi}{$H+}'#10
      + 'interface'#10
      + 'function Value: Integer;'#10
      + 'implementation'#10;
    if i < UNIT_COUNT then
      Body := Body + 'uses ' + SlowUnitName(i + 1) + ';'#10;
    Body := Body + 'function Value: Integer;'#10
      + 'begin'#10;
    if i < UNIT_COUNT then
      Body := Body + '  Result := ' + SlowUnitName(i + 1)
        + '.Value + 1;'#10
    else
      Body := Body + '  Result := 1;'#10;
    Body := Body + 'end;'#10'end.'#10;
    WriteTextFile(FScratch + '/source/' + SlowUnitName(i) + '.pas', Body);
  end;
end;

procedure TBuildSessions.WriteAppSource(const AChanged: Boolean);
const
  UNIT_COUNT = 80;
var
  Body: string;
begin
  Body := 'program app;'#10
    + 'uses ' + SlowUnitName(1) + ';'#10
    + '{$I Version.Generated.inc}'#10
    + 'begin'#10
    + '  if APP_VERSION = '''' then Halt(2);'#10
    + '  if Value <> ' + IntToStr(UNIT_COUNT) + ' then Halt(1);'#10
    + 'end.'#10;
  if AChanged then
    Body := Body + '// changed while compilation was paused'#10;
  WriteTextFile(FScratch + '/source/app.pas', Body);
end;

function TBuildSessions.CountSessionDirs: Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(FScratch + '/.lwpt/sessions/s-*', faDirectory,
    Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name <> '.') and (Search.Name <> '..')
        and ((Search.Attr and faDirectory) <> 0) then
        Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TBuildSessions.CountSessionJobRoots: Integer;
var
  SessionSearch, JobSearch: TSearchRec;
  JobsPath: string;
begin
  Result := 0;
  if FindFirst(FScratch + '/.lwpt/sessions/s-*', faDirectory,
    SessionSearch) <> 0 then Exit;
  try
    repeat
      if (SessionSearch.Name = '.') or (SessionSearch.Name = '..') then
        Continue;
      if (SessionSearch.Attr and faDirectory) = 0 then Continue;
      JobsPath := FScratch + '/.lwpt/sessions/' + SessionSearch.Name
        + '/jobs';
      if FindFirst(JobsPath + '/*', faDirectory, JobSearch) <> 0 then
        Continue;
      try
        repeat
          if (JobSearch.Name = '.') or (JobSearch.Name = '..') then
            Continue;
          if (JobSearch.Attr and faDirectory) = 0 then Continue;
          if DirectoryExists(JobsPath + '/' + JobSearch.Name + '/units') then
            Inc(Result);
        until FindNext(JobSearch) <> 0;
      finally
        FindClose(JobSearch);
      end;
    until FindNext(SessionSearch) <> 0;
  finally
    FindClose(SessionSearch);
  end;
end;

function TBuildSessions.CountReadyFiles(const ADir: string): Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + 'ready-*',
    faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Attr and faDirectory) = 0 then Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TBuildSessions.TargetReady(const ADir, ATarget: string): Boolean;
var Search: TSearchRec;
begin
  Result := FindFirst(IncludeTrailingPathDelimiter(ADir) + 'ready-'
    + ATarget + '-*', faAnyFile, Search) = 0;
  if Result then FindClose(Search);
end;

function EnvName(const AEntry: string): string;
var
  EqualsAt: Integer;
begin
  EqualsAt := Pos('=', AEntry);
  if EqualsAt = 0 then Result := AEntry
  else Result := Copy(AEntry, 1, EqualsAt - 1);
end;

function SameEnvName(const ALeft, ARight: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(EnvName(ALeft), EnvName(ARight));
  {$ELSE}
  Result := EnvName(ALeft) = EnvName(ARight);
  {$ENDIF}
end;

function EnvOverridden(const AEntry: string;
  const AOverrides: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AOverrides) do
    if SameEnvName(AEntry, AOverrides[i]) then
      Exit(True);
  Result := False;
end;

procedure SetProcessEnv(AEnvironment: TStrings; const AEntry: string);
var
  i: Integer;
begin
  for i := AEnvironment.Count - 1 downto 0 do
    if SameEnvName(AEnvironment[i], AEntry) then
      AEnvironment.Delete(i);
  AEnvironment.Add(AEntry);
end;

procedure SetEnv(var AEnvironment: TStringArray; const AEntry: string);
var
  i: Integer;
begin
  for i := 0 to High(AEnvironment) do
    if SameEnvName(AEnvironment[i], AEntry) then
    begin
      AEnvironment[i] := AEntry;
      Exit;
    end;
  i := Length(AEnvironment);
  SetLength(AEnvironment, i + 1);
  AEnvironment[i] := AEntry;
end;

function IsWorkerEnvironment(const AEntry: string): Boolean;
begin
  Result := SameText(EnvName(AEntry), WORKER_STATE_DIR_ENV)
         or SameText(EnvName(AEntry), WORKER_BUDGET_ENV)
         or SameText(EnvName(AEntry), WORKER_STALE_SECONDS_ENV)
         or SameText(EnvName(AEntry), WORKER_LEASE_TOKEN_ENV);
end;

function TBuildSessions.StartBuildWithEnv(
  const AProject, ATarget: string;
  const AExtraEnv: array of string): TProcess;
begin
  Result := StartBuildWithArgs(AProject, ['build', ATarget], AExtraEnv);
end;

function TBuildSessions.StartBuildWithArgs(const AProject: string;
  const AArgs, AExtraEnv: array of string): TProcess;
var
  i: Integer;
begin
  Result := TProcess.Create(nil);
  Result.Executable := LwptBinaryPath;
  for i := 0 to High(AArgs) do Result.Parameters.Add(AArgs[i]);
  Result.CurrentDirectory := AProject;
  Result.Options := [];
  for i := 1 to GetEnvironmentVariableCount do
    if not IsWorkerEnvironment(GetEnvironmentString(i))
       and not EnvOverridden(GetEnvironmentString(i), AExtraEnv) then
      Result.Environment.Add(GetEnvironmentString(i));
  SetProcessEnv(Result.Environment, WORKER_STATE_DIR_ENV + '='
    + FScratch + '/worker-state');
  SetProcessEnv(Result.Environment, WORKER_BUDGET_ENV + '=4');
  for i := 0 to High(AExtraEnv) do
    SetProcessEnv(Result.Environment, AExtraEnv[i]);
  Result.Execute;
end;

function TBuildSessions.RunLwptWithWorkerEnv(
  const AArgs: array of string; const AProject: string;
  const AExtraEnv: array of string): TLwptResult;
var
  Env: TStringArray;
  i: Integer;
begin
  SetLength(Env, 0);
  SetEnv(Env, WORKER_STATE_DIR_ENV + '=' + FScratch + '/worker-state');
  SetEnv(Env, WORKER_BUDGET_ENV + '=4');
  for i := 0 to High(AExtraEnv) do SetEnv(Env, AExtraEnv[i]);
  Result := RunLwpt(AArgs, AProject, Env);
end;

function FirstLogReference(const AOutput: string): string;
var
  ReferenceStart, ReferenceEnd: Integer;
begin
  Result := '';
  ReferenceStart := Pos('log: ', AOutput);
  if ReferenceStart = 0 then Exit;
  Inc(ReferenceStart, Length('log: '));
  ReferenceEnd := ReferenceStart;
  while (ReferenceEnd <= Length(AOutput))
    and not (AOutput[ReferenceEnd] in [')', ';', #10, #13]) do
    Inc(ReferenceEnd);
  Result := Copy(AOutput, ReferenceStart, ReferenceEnd - ReferenceStart);
end;

procedure TBuildSessions.WriteGraphProject(const AProject: string);
begin
  RecursiveDelete(AProject);
  WriteTextFile(AProject + '/lwpt.toml',
      '[package]'#10
    + 'name = "graph-app"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "source/alpha.pas", output = "build/alpha" }'#10
    + 'beta = { source = "source/beta.pas", output = "build/beta" }'#10
    + 'app = { source = "source/app.pas", output = "build/app", depends = ["alpha", "beta"] }'#10);
  WriteTextFile(AProject + '/source/alpha.pas',
    'program alpha; begin end.'#10);
  WriteTextFile(AProject + '/source/beta.pas',
    'program beta; begin end.'#10);
  WriteTextFile(AProject + '/source/app.pas',
    'program app; begin end.'#10);
end;

procedure TBuildSessions.TestConcurrentBuildsUseDistinctSessions;
var
  First, Second: TProcess;
  SawTwoSessions, SawTwoJobRoots: Boolean;
  Started: TDateTime;
  RepairResult: TLwptResult;
  FirstStatus, SecondStatus: Integer;
  ReadyDir, ReleasePath, RealFPC: string;
  Env: array of string;
begin
  RecursiveDelete(FScratch + '/build');
  RecursiveDelete(FScratch + '/.lwpt/sessions');
  ReadyDir := FScratch + '/control/concurrent-ready';
  ReleasePath := FScratch + '/control/concurrent-release';
  RecursiveDelete(FScratch + '/control');
  RealFPC := TestCompilerExecutable;
  SetLength(Env, 7);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_ENV + '=' + ReleasePath;
  Env[5] := WORKER_STATE_DIR_ENV + '=' + FScratch
    + '/control/concurrent-worker-state';
  Env[6] := WORKER_BUDGET_ENV + '=2';
  First := StartBuildWithEnv(FScratch, 'app', Env);
  Second := StartBuildWithEnv(FScratch, 'app', Env);
  try
    SawTwoSessions := False;
    SawTwoJobRoots := False;
    Started := Now;
    while First.Running or Second.Running do
    begin
      if CountReadyFiles(ReadyDir) >= 2 then
      begin
        SawTwoSessions := CountSessionDirs >= 2;
        SawTwoJobRoots := CountSessionJobRoots >= 2;
        Break;
      end;
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    { Diagnostics before the release/wait: a child that hung before
      signalling ready would never see the release and WaitOnExit would
      block with the evidence still unflushed. }
    if not (SawTwoSessions and SawTwoJobRoots) then
      DumpBarrierDiagnostics('concurrent-sessions', ReadyDir);
    WriteTextFile(ReleasePath, 'release');
    First.WaitOnExit;
    Second.WaitOnExit;
    FirstStatus := First.ExitStatus;
    SecondStatus := Second.ExitStatus;

    Expect<Boolean>(SawTwoSessions).ToBe(True);
    Expect<Boolean>(SawTwoJobRoots).ToBe(True);
    Expect<Boolean>(((FirstStatus = 0) and (SecondStatus = 1))
      or ((FirstStatus = 1) and (SecondStatus = 0))).ToBe(True);
    Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app')))
      .ToBe(True);
    Expect<Integer>(RunProgram(ExpectedExe(FScratch + '/build/app')))
      .ToBe(0);
    RepairResult := RunLwptWithWorkerEnv(['repair'], FScratch, []);
    Expect<Integer>(RepairResult.ExitCode).ToBe(0);
    Expect<Integer>(CountSessionDirs).ToBe(0);
  finally
    First.Free;
    Second.Free;
  end;
end;

procedure TBuildSessions.TestDistinctOutputsPublishIndependentlyFromRootUnits;
var
  Project, ReadyDir, ReleasePath, RealFPC: string;
  First, Second: TProcess;
  FirstStatus, SecondStatus: Integer;
  Ready: Boolean;
  Started: TDateTime;
  Env: array of string;
begin
  Project := FScratch + '/distinct-outputs';
  ReadyDir := FScratch + '/control/distinct-ready';
  ReleasePath := FScratch + '/control/distinct-release';
  RecursiveDelete(Project);
  RecursiveDelete(FScratch + '/control');
  WriteTextFile(Project + '/lwpt.toml',
      '[package]'#10
    + 'name = "distinct-outputs"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["."]'#10
    + #10
    + '[build]'#10
    + 'first = { source = "first.pas", output = "build/first" }'#10
    + 'second = { source = "second.pas", output = "build/second" }'#10);
  WriteTextFile(Project + '/first.pas',
    'program first; begin end.'#10);
  WriteTextFile(Project + '/second.pas',
    'program second; begin end.'#10);
  RealFPC := TestCompilerExecutable;
  SetLength(Env, 7);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_ENV + '=' + ReleasePath;
  Env[5] := WORKER_STATE_DIR_ENV + '=' + FScratch
    + '/control/distinct-worker-state';
  Env[6] := WORKER_BUDGET_ENV + '=2';
  First := StartBuildWithEnv(Project, 'first', Env);
  Second := StartBuildWithEnv(Project, 'second', Env);
  try
    Ready := False;
    Started := Now;
    while First.Running or Second.Running do
    begin
      if CountReadyFiles(ReadyDir) >= 2 then
      begin
        Ready := True;
        Break;
      end;
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    { Diagnostics before the release/wait — see the concurrent-sessions
      note: a hung child would block WaitOnExit with evidence unflushed. }
    if not Ready then
      DumpBarrierDiagnostics('distinct-outputs', ReadyDir);
    WriteTextFile(ReleasePath, 'release');
    First.WaitOnExit;
    Second.WaitOnExit;
    FirstStatus := First.ExitStatus;
    SecondStatus := Second.ExitStatus;

    Expect<Boolean>(Ready).ToBe(True);
    Expect<Integer>(FirstStatus).ToBe(0);
    Expect<Integer>(SecondStatus).ToBe(0);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/first')))
      .ToBe(True);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/second')))
      .ToBe(True);
  finally
    WriteTextFile(ReleasePath, 'release');
    if First.Running then First.WaitOnExit;
    if Second.Running then Second.WaitOnExit;
    First.Free;
    Second.Free;
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestFailedBuildPreservesLastSuccessfulOutput;
var
  BeforeContent, AfterContent: string;
  R: TLwptResult;
begin
  R := RunLwptWithWorkerEnv(['build', 'app'], FScratch, []);
  Expect<Integer>(R.ExitCode).ToBe(0);
  BeforeContent := ReadBinaryFile(ExpectedExe(FScratch + '/build/app'));

  R := RunLwptWithWorkerEnv(['build', '--clean', 'app'], FScratch,
    [FPC_ENV + '=' + FScratch + '/missing-fpc']);

  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  AfterContent := ReadBinaryFile(ExpectedExe(FScratch + '/build/app'));
  Expect<string>(AfterContent).ToBe(BeforeContent);
end;

procedure TBuildSessions.TestInFlightWorkspaceChangeRefusesPublication;
var
  Project, ReadyDir, ReleasePath, RealFPC: string;
  Build: TProcess;
  Ready: Boolean;
  Started: TDateTime;
  Env: array of string;
  InstallResult, RepairResult: TLwptResult;
begin
  Project := FScratch + '/workspace';
  ReadyDir := FScratch + '/control/workspace-ready';
  ReleasePath := FScratch + '/control/workspace-release';
  RecursiveDelete(Project);
  RecursiveDelete(FScratch + '/control');
  WriteTextFile(Project + '/lwpt.toml',
      '[package]'#10
    + 'name = "workspace-app"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[workspaces]'#10
    + 'include = ["packages/*"]'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app" }'#10);
  WriteTextFile(Project + '/packages/shared/lwpt.toml',
      '[package]'#10
    + 'name = "shared"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(Project + '/packages/shared/source/WorkspaceUnit.pas',
      'unit WorkspaceUnit;'#10
    + '{$mode delphi}{$H+}'#10
    + 'interface'#10
    + 'function Value: Integer;'#10
    + 'implementation'#10
    + 'function Value: Integer;'#10
    + 'begin Result := 1; end;'#10
    + 'end.'#10);
  WriteTextFile(Project + '/source/app.pas',
      'program app;'#10
    + 'uses WorkspaceUnit;'#10
    + 'begin if Value <> 2 then Halt(1); end.'#10);
  InstallResult := RunLwptWithWorkerEnv(['install'], Project, []);
  Expect<Integer>(InstallResult.ExitCode).ToBe(0);

  RealFPC := TestCompilerExecutable;
  SetLength(Env, 5);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_ENV + '=' + ReleasePath;
  Build := StartBuildWithEnv(Project, 'app', Env);
  try
    Ready := False;
    Started := Now;
    while Build.Running do
    begin
      if CountReadyFiles(ReadyDir) >= 1 then
      begin
        Ready := True;
        Break;
      end;
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if Ready then
      WriteTextFile(Project
          + '/packages/shared/source/WorkspaceUnit.pas',
          'unit WorkspaceUnit;'#10
        + '{$mode delphi}{$H+}'#10
        + 'interface'#10
        + 'function Value: Integer;'#10
        + 'implementation'#10
        + 'function Value: Integer;'#10
        + 'begin Result := 2; end;'#10
        + 'end.'#10);
    WriteTextFile(ReleasePath, 'release');
    Build.WaitOnExit;

    Expect<Boolean>(Ready).ToBe(True);
    Expect<Integer>(Build.ExitStatus).ToBe(1);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/app')))
      .ToBe(False);
    RepairResult := RunLwptWithWorkerEnv(['repair'], Project, []);
    Expect<Integer>(RepairResult.ExitCode).ToBe(0);
  finally
    WriteTextFile(ReleasePath, 'release');
    if Build.Running then Build.WaitOnExit;
    Build.Free;
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestInFlightSourceChangeRefusesPublication;
var
  Build: TProcess;
  Started: TDateTime;
  Ready: Boolean;
  ReadyDir, ReleasePath, RealFPC: string;
  Env: array of string;
  RepairResult: TLwptResult;
begin
  RecursiveDelete(FScratch + '/build');
  RecursiveDelete(FScratch + '/.lwpt/sessions');
  RecursiveDelete(FScratch + '/control');
  WriteAppSource(False);
  ReadyDir := FScratch + '/control/stale-ready';
  ReleasePath := FScratch + '/control/stale-release';
  RealFPC := TestCompilerExecutable;
  SetLength(Env, 5);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_ENV + '=' + ReleasePath;
  Build := StartBuildWithEnv(FScratch, 'app', Env);
  try
    Ready := False;
    Started := Now;
    while Build.Running do
    begin
      if CountReadyFiles(ReadyDir) >= 1 then
      begin
        Ready := True;
        Break;
      end;
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if Ready then WriteAppSource(True);
    WriteTextFile(ReleasePath, 'release');
    Build.WaitOnExit;

    Expect<Boolean>(Ready).ToBe(True);
    Expect<Integer>(Build.ExitStatus).ToBe(1);
    Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app')))
      .ToBe(False);
    Expect<Integer>(CountSessionDirs).ToBe(1);
    RepairResult := RunLwptWithWorkerEnv(['repair'], FScratch, []);
    Expect<Integer>(RepairResult.ExitCode).ToBe(0);
    Expect<Integer>(CountSessionDirs).ToBe(0);
  finally
    WriteTextFile(ReleasePath, 'release');
    if Build.Running then Build.WaitOnExit;
    Build.Free;
    WriteAppSource(False);
  end;
end;

procedure TBuildSessions.TestOneInvocationRunsReadyTargetsInParallel;
var
  Project, ReadyDir, ReleaseDir, RealFPC: string;
  Build: TProcess;
  Started: TDateTime;
  Env: array of string;
begin
  Project := FScratch + '/parallel-graph';
  ReadyDir := Project + '/control/ready';
  ReleaseDir := Project + '/control/release';
  WriteGraphProject(Project);
  RealFPC := TestCompilerExecutable;
  SetLength(Env, 7);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_DIR_ENV + '=' + ReleaseDir;
  Env[5] := WORKER_STATE_DIR_ENV + '=' + Project + '/worker-state';
  Env[6] := WORKER_BUDGET_ENV + '=4';
  Build := StartBuildWithArgs(Project, ['build', 'app'], Env);
  try
    Started := Now;
    while Build.Running
      and not (TargetReady(ReadyDir, 'alpha')
        and TargetReady(ReadyDir, 'beta')) do
    begin
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if not (TargetReady(ReadyDir, 'alpha')
      and TargetReady(ReadyDir, 'beta')) then
      DumpBarrierDiagnostics('overlap: alpha+beta ready', ReadyDir);
    Expect<Boolean>(TargetReady(ReadyDir, 'alpha')).ToBe(True);
    Expect<Boolean>(TargetReady(ReadyDir, 'beta')).ToBe(True);
    Expect<Boolean>(TargetReady(ReadyDir, 'app')).ToBe(False);

    { Complete in reverse manifest order. The dependent still cannot start
      until both prerequisite publications have succeeded. }
    WriteTextFile(ReleaseDir + '/beta', 'release');
    Sleep(50);
    Expect<Boolean>(TargetReady(ReadyDir, 'app')).ToBe(False);
    WriteTextFile(ReleaseDir + '/alpha', 'release');
    Started := Now;
    while Build.Running and not TargetReady(ReadyDir, 'app') do
    begin
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if not TargetReady(ReadyDir, 'app') then
      DumpBarrierDiagnostics('app ready after releases', ReadyDir);
    Expect<Boolean>(TargetReady(ReadyDir, 'app')).ToBe(True);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/alpha')))
      .ToBe(True);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/beta')))
      .ToBe(True);
    WriteTextFile(ReleaseDir + '/app', 'release');
    Build.WaitOnExit;
    Expect<Integer>(Build.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/app')))
      .ToBe(True);
  finally
    WriteTextFile(ReleaseDir + '/alpha', 'release');
    WriteTextFile(ReleaseDir + '/beta', 'release');
    WriteTextFile(ReleaseDir + '/app', 'release');
    if Build.Running then Build.WaitOnExit;
    Build.Free;
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestJobsOneRunsTargetsSequentially;
var
  Project, ReadyDir, ReleaseDir, RealFPC: string;
  Build: TProcess;
  Started: TDateTime;
  Env: array of string;
begin
  Project := FScratch + '/sequential-graph';
  ReadyDir := Project + '/control/ready';
  ReleaseDir := Project + '/control/release';
  WriteGraphProject(Project);
  RealFPC := TestCompilerExecutable;
  SetLength(Env, 7);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_DIR_ENV + '=' + ReleaseDir;
  Env[5] := WORKER_STATE_DIR_ENV + '=' + Project + '/worker-state';
  Env[6] := WORKER_BUDGET_ENV + '=4';
  Build := StartBuildWithArgs(Project,
    ['build', 'app', '--jobs=1'], Env);
  try
    Started := Now;
    while Build.Running and not TargetReady(ReadyDir, 'alpha') do
    begin
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if not TargetReady(ReadyDir, 'alpha') then
      DumpBarrierDiagnostics('sequential: alpha ready', ReadyDir);
    Expect<Boolean>(TargetReady(ReadyDir, 'alpha')).ToBe(True);
    Expect<Boolean>(TargetReady(ReadyDir, 'beta')).ToBe(False);
    WriteTextFile(ReleaseDir + '/alpha', 'release');
    Started := Now;
    while Build.Running and not TargetReady(ReadyDir, 'beta') do
    begin
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if not TargetReady(ReadyDir, 'beta') then
      DumpBarrierDiagnostics('sequential: beta ready', ReadyDir);
    Expect<Boolean>(TargetReady(ReadyDir, 'beta')).ToBe(True);
    Expect<Boolean>(TargetReady(ReadyDir, 'app')).ToBe(False);
    WriteTextFile(ReleaseDir + '/beta', 'release');
    Started := Now;
    while Build.Running and not TargetReady(ReadyDir, 'app') do
    begin
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then Break;
      Sleep(10);
    end;
    if not TargetReady(ReadyDir, 'app') then
      DumpBarrierDiagnostics('app ready after releases', ReadyDir);
    Expect<Boolean>(TargetReady(ReadyDir, 'app')).ToBe(True);
    WriteTextFile(ReleaseDir + '/app', 'release');
    Build.WaitOnExit;
    Expect<Integer>(Build.ExitCode).ToBe(0);
  finally
    WriteTextFile(ReleaseDir + '/alpha', 'release');
    WriteTextFile(ReleaseDir + '/beta', 'release');
    WriteTextFile(ReleaseDir + '/app', 'release');
    if Build.Running then Build.WaitOnExit;
    Build.Free;
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestFailedPrerequisiteBlocksOnlyDependants;
var
  Project, ReadyDir, ReleaseDir, RealFPC: string;
  Env: array of string;
  R: TLwptResult;
  AlphaAt, BetaAt, AppAt: Integer;
begin
  Project := FScratch + '/failed-graph';
  ReadyDir := Project + '/control/ready';
  ReleaseDir := Project + '/control/release';
  WriteGraphProject(Project);
  WriteTextFile(ReleaseDir + '/alpha', 'release');
  WriteTextFile(ReleaseDir + '/beta', 'release');
  WriteTextFile(ReleaseDir + '/app', 'release');
  RealFPC := TestCompilerExecutable;
  SetLength(Env, 8);
  Env[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Env[1] := TEST_FPC_PROXY_ENV + '=1';
  Env[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Env[3] := TEST_FPC_READY_DIR_ENV + '=' + ReadyDir;
  Env[4] := TEST_FPC_RELEASE_DIR_ENV + '=' + ReleaseDir;
  Env[5] := TEST_FPC_FAIL_TARGET_ENV + '=alpha';
  Env[6] := WORKER_STATE_DIR_ENV + '=' + Project + '/worker-state';
  Env[7] := WORKER_BUDGET_ENV + '=4';
  try
    R := RunLwptWithWorkerEnv(['build'], Project, Env);
    Expect<Integer>(R.ExitCode).ToBe(1);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/beta')))
      .ToBe(True);
    Expect<Boolean>(FileExists(ExpectedExe(Project + '/build/app')))
      .ToBe(False);
    Expect<Boolean>(TargetReady(ReadyDir, 'app')).ToBe(False);
    Expect<Boolean>(Pos('blocked by failed prerequisite "alpha"',
      R.Stderr) > 0).ToBe(True);
    AlphaAt := Pos('START alpha ', R.Stdout);
    BetaAt := Pos('START beta ', R.Stdout);
    AppAt := Pos('SKIP app ', R.Stdout);
    Expect<Boolean>((AlphaAt > 0) and (AlphaAt < BetaAt)
      and (BetaAt < AppAt)).ToBe(True);
  finally
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestObservableBuildHeartbeatAndVerboseLogs;
var
  Project, RealFPC: string;
  Environment, QuietEnvironment: array of string;
  RunResult: TLwptResult;
  LogReference: string;
begin
  Project := FScratch + '/observable-graph';
  WriteGraphProject(Project);
  RealFPC := TestCompilerExecutable;
  SetLength(QuietEnvironment, 6);
  QuietEnvironment[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  QuietEnvironment[1] := TEST_FPC_PROXY_ENV + '=1';
  QuietEnvironment[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  QuietEnvironment[3] := TestFPCDelayMillisecondsEnvironment + '='
    + IntToStr(TestShortCompilerDelayMilliseconds);
  QuietEnvironment[4] := TestFPCOutputEnvironment + '=1';
  QuietEnvironment[5] := WORKER_BUDGET_ENV + '=4';
  SetLength(Environment, 7);
  Environment[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Environment[1] := TEST_FPC_PROXY_ENV + '=1';
  Environment[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Environment[3] := TestFPCDelayMillisecondsEnvironment + '='
    + IntToStr(TestHeartbeatJobDurationMilliseconds);
  Environment[4] := TestFPCOutputEnvironment + '=1';
  Environment[5] := ObservabilityHeartbeatIntervalEnvironment + '='
    + IntToStr(TestHeartbeatIntervalMilliseconds);
  Environment[6] := WORKER_BUDGET_ENV + '=4';
  try
    RunResult := RunLwptWithWorkerEnv(
      ['build', 'alpha', 'beta'], Project, QuietEnvironment);
    DumpRunFailure('observable: quiet build', RunResult, 0);
    Expect<Integer>(RunResult.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('alpha-begin|', RunResult.Stdout) = 0).ToBe(True);
    Expect<Boolean>(Pos('beta-begin|', RunResult.Stdout) = 0).ToBe(True);
    Expect<Boolean>(Pos('HEARTBEAT ', RunResult.Stdout) = 0).ToBe(True);

    RunResult := RunLwptWithWorkerEnv(
      ['build', 'alpha', 'beta', '--verbose'], Project, Environment);
    DumpRunFailure('observable: verbose build', RunResult, 0);
    Expect<Integer>(RunResult.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('discovered 2 build target(s)', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('build session: ', RunResult.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('(.lwpt/sessions/', RunResult.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('effective workers: 2', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('START alpha ', RunResult.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('START beta ', RunResult.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('HEARTBEAT build elapsed ', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('active: alpha ', RunResult.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('PASS alpha -> build/alpha', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('PASS beta -> build/beta', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('alpha-begin|alpha-end|', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('beta-begin|beta-end|', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('summary: 2 built, 0 failed, 0 skipped; elapsed ',
      RunResult.Stdout) > 0).ToBe(True);
    LogReference := FirstLogReference(RunResult.Stdout);
    Expect<Boolean>(LogReference <> '').ToBe(True);
    Expect<Boolean>(FileExists(Project + '/' + LogReference)).ToBe(True);
  finally
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestFullyContendedBuildEmitsHeartbeat;
var
  Holder: TProcess;
  Environment: array of string;
  RunResult: TLwptResult;
  Project, ReadyPath: string;
  StartedAt: QWord;
begin
  Project := FScratch + '/fully-contended';
  WriteGraphProject(Project);
  ReadyPath := Project + '/control/holder-ready';
  Holder := TProcess.Create(nil);
  try
    Holder.Executable := ExpandFileName(ParamStr(0));
    Holder.Options := [];
    SetProcessEnv(Holder.Environment, TestWorkerHolderEnvironment + '=1');
    SetProcessEnv(Holder.Environment, TestWorkerHolderReadyEnvironment + '='
      + ReadyPath);
    SetProcessEnv(Holder.Environment,
      TestWorkerHolderDelayMillisecondsEnvironment + '='
      + IntToStr(TestWorkerContentionDurationMilliseconds));
    SetProcessEnv(Holder.Environment, WORKER_STATE_DIR_ENV + '='
      + Project + '/worker-state');
    SetProcessEnv(Holder.Environment, WORKER_BUDGET_ENV + '=1');
    Holder.Execute;
    StartedAt := GetTickCount64;
    while Holder.Running and not FileExists(ReadyPath)
      and (GetTickCount64 - StartedAt
        < ConcurrencyBarrierCeilingSeconds * 1000) do Sleep(10);
    Expect<Boolean>(FileExists(ReadyPath)).ToBe(True);

    SetLength(Environment, 3);
    Environment[0] := WORKER_STATE_DIR_ENV + '=' + Project + '/worker-state';
    Environment[1] := WORKER_BUDGET_ENV + '=1';
    Environment[2] := ObservabilityHeartbeatIntervalEnvironment + '='
      + IntToStr(TestHeartbeatIntervalMilliseconds);
    RunResult := RunLwpt(['build', 'alpha'], Project, Environment);

    DumpRunFailure('contended: queued build', RunResult, 0);
    Expect<Integer>(RunResult.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('HEARTBEAT build elapsed ', RunResult.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('active: alpha (queued)', RunResult.Stdout) > 0)
      .ToBe(True);
  finally
    if Holder.Running then Holder.Terminate(1);
    Holder.WaitOnExit;
    Holder.Free;
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.TestBuildFailureReplaysAndPreservesIsolatedLog;
var
  Project, RealFPC, LogPath: string;
  Environment: array of string;
  RunResult: TLwptResult;
  SessionSearch, LogSearch: TSearchRec;
begin
  Project := FScratch + '/observable-failure';
  WriteGraphProject(Project);
  RealFPC := TestCompilerExecutable;
  SetLength(Environment, 6);
  Environment[0] := FPC_ENV + '=' + ExpandFileName(ParamStr(0));
  Environment[1] := TEST_FPC_PROXY_ENV + '=1';
  Environment[2] := TEST_REAL_FPC_ENV + '=' + RealFPC;
  Environment[3] := TestFPCDelayMillisecondsEnvironment + '='
    + IntToStr(TestShortCompilerDelayMilliseconds);
  Environment[4] := TestFPCOutputEnvironment + '=1';
  Environment[5] := TEST_FPC_FAIL_TARGET_ENV + '=alpha';
  try
    RunResult := RunLwptWithWorkerEnv(['build', 'alpha'], Project,
      Environment);
    Expect<Integer>(RunResult.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('FAIL alpha ', RunResult.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('alpha-begin|alpha-end|', RunResult.Stdout)
      > Pos('FAIL alpha ', RunResult.Stdout)).ToBe(True);
    Expect<Boolean>(Pos('target "alpha" failed: compiler failed',
      RunResult.Stderr) > 0).ToBe(True);
    Expect<Boolean>(Pos('summary: 0 built, 1 failed, 0 skipped; elapsed ',
      RunResult.Stdout) > 0).ToBe(True);
    LogPath := '';
    if FindFirst(Project + '/.lwpt/sessions/s-*', faDirectory,
      SessionSearch) = 0 then
    try
      repeat
        if (SessionSearch.Attr and faDirectory) = 0 then Continue;
        if FindFirst(Project + '/.lwpt/sessions/' + SessionSearch.Name
          + '/logs/*.log', faAnyFile, LogSearch) = 0 then
        try
          LogPath := Project + '/.lwpt/sessions/' + SessionSearch.Name
            + '/logs/' + LogSearch.Name;
        finally
          FindClose(LogSearch);
        end;
      until (LogPath <> '') or (FindNext(SessionSearch) <> 0);
    finally
      FindClose(SessionSearch);
    end;
    Expect<Boolean>(LogPath <> '').ToBe(True);
    Expect<Boolean>(Pos('alpha-begin|alpha-end|', ReadBinaryFile(LogPath))
      > 0).ToBe(True);
  finally
    RecursiveDelete(Project);
  end;
end;

procedure TBuildSessions.SetupTests;
begin
  Test('concurrent builds use distinct private sessions',
    TestConcurrentBuildsUseDistinctSessions);
  Test('distinct outputs publish independently with root units',
    TestDistinctOutputsPublishIndependentlyFromRootUnits);
  Test('failed clean build preserves last successful output',
    TestFailedBuildPreservesLastSuccessfulOutput);
  Test('in-flight source changes refuse stale publication',
    TestInFlightSourceChangeRefusesPublication);
  Test('in-flight workspace changes refuse stale publication',
    TestInFlightWorkspaceChangeRefusesPublication);
  Test('one invocation overlaps independent ready targets',
    TestOneInvocationRunsReadyTargetsInParallel);
  Test('--jobs=1 runs ready targets sequentially',
    TestJobsOneRunsTargetsSequentially);
  Test('failed prerequisite blocks only its dependants',
    TestFailedPrerequisiteBlocksOnlyDependants);
  Test('observable builds heartbeat and serialize verbose logs',
    TestObservableBuildHeartbeatAndVerboseLogs);
  Test('fully contended builds heartbeat while targets are queued',
    TestFullyContendedBuildEmitsHeartbeat);
  Test('build failures replay and preserve isolated logs',
    TestBuildFailureReplaysAndPreservesIsolatedLog);
end;

function RunCompilerProxy: Integer;
var
  Compiler, ReadyDir, ReleasePath, ReleaseDir, TargetName,
    FailTarget: string;
  IsVersionQuery: Boolean;
  Process: TProcess;
  Started: TDateTime;
  DelayMilliseconds, i: Integer;
begin
  Compiler := GetEnvironmentVariable(TEST_REAL_FPC_ENV);
  ReadyDir := GetEnvironmentVariable(TEST_FPC_READY_DIR_ENV);
  ReleasePath := GetEnvironmentVariable(TEST_FPC_RELEASE_ENV);
  ReleaseDir := GetEnvironmentVariable(TEST_FPC_RELEASE_DIR_ENV);
  FailTarget := GetEnvironmentVariable(TEST_FPC_FAIL_TARGET_ENV);
  DelayMilliseconds := StrToIntDef(
    GetEnvironmentVariable(TestFPCDelayMillisecondsEnvironment), 0);
  IsVersionQuery := False;
  for i := 1 to ParamCount do
    if ParamStr(i) = '-iV' then IsVersionQuery := True;
  if not IsVersionQuery then
  begin
    TargetName := ChangeFileExt(ExtractFileName(ParamStr(ParamCount)), '');
    if ReadyDir <> '' then
    begin
      ForceDirectories(ReadyDir);
      WriteTextFile(IncludeTrailingPathDelimiter(ReadyDir)
        + 'ready-' + TargetName + '-' + IntToStr(GetProcessID), 'ready');
    end;
    if ReleaseDir <> '' then
      ReleasePath := IncludeTrailingPathDelimiter(ReleaseDir) + TargetName;
    if GetEnvironmentVariable(TestFPCOutputEnvironment) = '1' then
    begin
      Write(TargetName, '-begin|');
      Flush(Output);
    end;
    if DelayMilliseconds > 0 then Sleep(DelayMilliseconds);
    Started := Now;
    while (ReleasePath <> '') and not FileExists(ReleasePath) do
    begin
      if (Now - Started) * 86400 > ConcurrencyBarrierCeilingSeconds then
      begin
        Result := 125;
        Exit;
      end;
      Sleep(10);
    end;
    if GetEnvironmentVariable(TestFPCOutputEnvironment) = '1' then
    begin
      Write(TargetName, '-end|');
      Flush(Output);
    end;
    if SameText(TargetName, FailTarget) then Exit(17);
  end;

  Process := TProcess.Create(nil);
  try
    Process.Executable := Compiler;
    for i := 1 to ParamCount do Process.Parameters.Add(ParamStr(i));
    Process.Options := [poWaitOnExit];
    Process.Execute;
    Result := Process.ExitStatus;
  finally
    Process.Free;
  end;
end;

function RunWorkerHolder: Integer;
var
  Session: TLWPTWorkerBudgetSession;
  Lease: TLWPTWorkerLease;
  ReadyPath: string;
  DelayMilliseconds: Integer;
begin
  Result := 1;
  Session := TLWPTWorkerBudgetSession.Create(NewWorkerSessionId, 1);
  try
    Lease := Session.Acquire(5000);
    if not Assigned(Lease) then Exit;
    try
      ReadyPath := GetEnvironmentVariable(TestWorkerHolderReadyEnvironment);
      if not ForceDirectories(ExtractFileDir(ReadyPath)) then Exit;
      WriteTextFile(ReadyPath, 'ready');
      DelayMilliseconds := StrToIntDef(GetEnvironmentVariable(
        TestWorkerHolderDelayMillisecondsEnvironment),
        TestWorkerContentionDurationMilliseconds);
      Sleep(DelayMilliseconds);
      Result := 0;
    finally
      Lease.Free;
    end;
  finally
    Session.Free;
  end;
end;

begin
  if GetEnvironmentVariable(TestWorkerHolderEnvironment) = '1' then
    Halt(RunWorkerHolder);
  if GetEnvironmentVariable(TEST_FPC_PROXY_ENV) = '1' then
    Halt(RunCompilerProxy);
  TestRunnerProgram.AddSuite(TBuildSessions.Create(
    'build sessions: subprocess concurrency'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
