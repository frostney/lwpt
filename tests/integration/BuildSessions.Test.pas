{ BuildSessions.Test — concurrent subprocess builds in one project. }
program BuildSessions.Test;

{$mode delphi}{$H+}

uses
  Process,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TBuildSessions = class(TTestSuite)
  private
    FScratch: string;
    function CountSessionDirs: Integer;
    function CountSessionJobRoots: Integer;
    function CountReadyFiles(const ADir: string): Integer;
    function StartBuildWithEnv(const AProject, ATarget: string;
      const AExtraEnv: array of string): TProcess;
    procedure WriteAppSource(AChanged: Boolean);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestConcurrentBuildsUseDistinctSessions;
    procedure TestDistinctOutputsPublishIndependentlyFromRootUnits;
    procedure TestFailedBuildPreservesLastSuccessfulOutput;
    procedure TestInFlightSourceChangeRefusesPublication;
    procedure TestInFlightWorkspaceChangeRefusesPublication;
  end;

function SlowUnitName(AIndex: Integer): string;
begin
  Result := 'SlowUnit' + Format('%.3d', [AIndex]);
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
  FScratch := ExpandFileName('build/tests/tmp/build-sessions');
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

procedure TBuildSessions.WriteAppSource(AChanged: Boolean);
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
  if FindFirst(FScratch + '/.lwpt/sessions/session-*', faDirectory,
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
  if FindFirst(FScratch + '/.lwpt/sessions/session-*', faDirectory,
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

function EnvName(const AEntry: string): string;
var
  EqualsAt: Integer;
begin
  EqualsAt := Pos('=', AEntry);
  if EqualsAt = 0 then Result := AEntry
  else Result := Copy(AEntry, 1, EqualsAt - 1);
end;

function EnvOverridden(const AEntry: string;
  const AOverrides: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AOverrides) do
    {$IFDEF MSWINDOWS}
    if SameText(EnvName(AEntry), EnvName(AOverrides[i])) then
    {$ELSE}
    if EnvName(AEntry) = EnvName(AOverrides[i]) then
    {$ENDIF}
      Exit(True);
  Result := False;
end;

function TBuildSessions.StartBuildWithEnv(
  const AProject, ATarget: string;
  const AExtraEnv: array of string): TProcess;
var
  i: Integer;
begin
  Result := TProcess.Create(nil);
  Result.Executable := LwptBinaryPath;
  Result.Parameters.Add('build');
  Result.Parameters.Add(ATarget);
  Result.CurrentDirectory := AProject;
  Result.Options := [];
  if Length(AExtraEnv) > 0 then
  begin
    for i := 1 to GetEnvironmentVariableCount do
      if not EnvOverridden(GetEnvironmentString(i), AExtraEnv) then
        Result.Environment.Add(GetEnvironmentString(i));
    for i := 0 to High(AExtraEnv) do
      Result.Environment.Add(AExtraEnv[i]);
  end;
  Result.Execute;
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
  SetLength(Env, 5);
  Env[0] := 'LWPT_FPC=' + ExpandFileName(ParamStr(0));
  Env[1] := 'LWPT_TEST_FPC_PROXY=1';
  Env[2] := 'LWPT_TEST_REAL_FPC=' + RealFPC;
  Env[3] := 'LWPT_TEST_FPC_READY_DIR=' + ReadyDir;
  Env[4] := 'LWPT_TEST_FPC_RELEASE=' + ReleasePath;
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
      if (Now - Started) * 86400 > 10 then Break;
      Sleep(10);
    end;
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
    RepairResult := RunLwpt(['repair'], FScratch);
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
  Project := FScratch + '-distinct-outputs';
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
  SetLength(Env, 5);
  Env[0] := 'LWPT_FPC=' + ExpandFileName(ParamStr(0));
  Env[1] := 'LWPT_TEST_FPC_PROXY=1';
  Env[2] := 'LWPT_TEST_REAL_FPC=' + RealFPC;
  Env[3] := 'LWPT_TEST_FPC_READY_DIR=' + ReadyDir;
  Env[4] := 'LWPT_TEST_FPC_RELEASE=' + ReleasePath;
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
      if (Now - Started) * 86400 > 10 then Break;
      Sleep(10);
    end;
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
  R := RunLwpt(['build', 'app'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  BeforeContent := ReadBinaryFile(ExpectedExe(FScratch + '/build/app'));

  R := RunLwpt(['build', '--clean', 'app'], FScratch,
    ['LWPT_FPC=' + FScratch + '/missing-fpc']);

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
  Project := FScratch + '-workspace';
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
  InstallResult := RunLwpt(['install'], Project);
  Expect<Integer>(InstallResult.ExitCode).ToBe(0);

  RealFPC := TestCompilerExecutable;
  SetLength(Env, 5);
  Env[0] := 'LWPT_FPC=' + ExpandFileName(ParamStr(0));
  Env[1] := 'LWPT_TEST_FPC_PROXY=1';
  Env[2] := 'LWPT_TEST_REAL_FPC=' + RealFPC;
  Env[3] := 'LWPT_TEST_FPC_READY_DIR=' + ReadyDir;
  Env[4] := 'LWPT_TEST_FPC_RELEASE=' + ReleasePath;
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
      if (Now - Started) * 86400 > 10 then Break;
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
    RepairResult := RunLwpt(['repair'], Project);
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
  Env[0] := 'LWPT_FPC=' + ExpandFileName(ParamStr(0));
  Env[1] := 'LWPT_TEST_FPC_PROXY=1';
  Env[2] := 'LWPT_TEST_REAL_FPC=' + RealFPC;
  Env[3] := 'LWPT_TEST_FPC_READY_DIR=' + ReadyDir;
  Env[4] := 'LWPT_TEST_FPC_RELEASE=' + ReleasePath;
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
      if (Now - Started) * 86400 > 10 then Break;
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
    RepairResult := RunLwpt(['repair'], FScratch);
    Expect<Integer>(RepairResult.ExitCode).ToBe(0);
    Expect<Integer>(CountSessionDirs).ToBe(0);
  finally
    WriteTextFile(ReleasePath, 'release');
    if Build.Running then Build.WaitOnExit;
    Build.Free;
    WriteAppSource(False);
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
end;

function RunCompilerProxy: Integer;
var
  Compiler, ReadyDir, ReleasePath: string;
  IsVersionQuery: Boolean;
  Process: TProcess;
  Started: TDateTime;
  i: Integer;
begin
  Compiler := GetEnvironmentVariable('LWPT_TEST_REAL_FPC');
  ReadyDir := GetEnvironmentVariable('LWPT_TEST_FPC_READY_DIR');
  ReleasePath := GetEnvironmentVariable('LWPT_TEST_FPC_RELEASE');
  IsVersionQuery := False;
  for i := 1 to ParamCount do
    if ParamStr(i) = '-iV' then IsVersionQuery := True;
  if not IsVersionQuery then
  begin
    ForceDirectories(ReadyDir);
    WriteTextFile(IncludeTrailingPathDelimiter(ReadyDir)
      + 'ready-' + IntToStr(GetProcessID), 'ready');
    Started := Now;
    while not FileExists(ReleasePath) do
    begin
      if (Now - Started) * 86400 > 15 then
      begin
        Result := 125;
        Exit;
      end;
      Sleep(10);
    end;
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

begin
  if GetEnvironmentVariable('LWPT_TEST_FPC_PROXY') = '1' then
    Halt(RunCompilerProxy);
  TestRunnerProgram.AddSuite(TBuildSessions.Create(
    'build sessions: subprocess concurrency'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
