program CompilerProfiles.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core,
  LWPT.ProcessRunner,
  LWPT.WorkerBudget,
  Platform,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  DRIVER_ID = 'integration-driver';

type
  TCompilerProfiles = class(TTestSuite)
  private
    FScratch: string;
    procedure SetMode(const AMode: string);
    procedure WriteManifest(const AEntryCompiler: string = 'external';
      const AObservePostBuildLeases: Boolean = False);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestExternalBuildAndTestSucceed;
    procedure TestEntryProfileOverridesProjectDefault;
    procedure TestIdentityMismatchNeverFallsBack;
    procedure TestVersionMismatchFails;
    procedure TestLiveCapabilityMutationFailsBeforeCompile;
    procedure TestTargetMismatchFails;
    procedure TestMalformedStdoutRetainsStderr;
    procedure TestCompileTimeoutCleansUp;
    procedure TestExtraArtifactIsRejected;
    procedure TestReorderedArtifactsPublishTheRequestedPrimary;
    procedure TestPublicationTargetMutationBlocksPublication;
    procedure TestPublicationRevalidationRetainsWorkerCapacity;
  end;

function ReadInput: string;
var
  Line: string;
begin
  Result := '';
  while not EOF(Input) do
  begin
    ReadLn(Line);
    Result := Result + Line + #10;
  end;
end;

function ReadMode: string;
var
  Lines: TStringList;
begin
  Result := '';
  if not FileExists('.driver-mode') then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile('.driver-mode');
    Result := Trim(Lines.Text);
  finally
    Lines.Free;
  end;
end;

function IncrementProbeCount: Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    if FileExists('.probe-count') then
    begin
      Lines.LoadFromFile('.probe-count');
      Result := StrToIntDef(Trim(Lines.Text), 0);
    end;
    Inc(Result);
    Lines.Text := IntToStr(Result);
    Lines.SaveToFile('.probe-count');
  finally
    Lines.Free;
  end;
end;

procedure ObservePublicationLease;
var
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
  StandardError, StandardOutput: string;
  TimedOut: Boolean;
  Values: TStringList;
begin
  WriteTextFile(ExpandFileName('.driver-mode'), 'success');
  P := TProcess.Create(nil);
  Runner := nil;
  try
    Values := TStringList.Create;
    try
      Values.LoadFromFile('.lwpt-binary');
      P.Executable := Trim(Values.Text);
    finally
      Values.Free;
    end;
    P.CurrentDirectory := GetCurrentDir;
    P.Parameters.Add('build');
    P.Parameters.Add('--jobs');
    P.Parameters.Add('1');
    ConfigureProcessEnvironment(P, [WORKER_LEASE_TOKEN_ENV + '=']);
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('publication lease contender');
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds := 300;
    TimedOut := False;
    try
      Runner.Run('', Options, StandardOutput, StandardError);
    except
      on ELWPTProcessRunnerTimeout do TimedOut := True;
    end;
    if TimedOut then
      WriteTextFile(ExpandFileName('.lease-observed'), 'blocked');
  finally
    Runner.Free;
    P.Free;
  end;
end;

function CompileWithFPC(const ARequest: TLWPTBuildRequest;
  out ADiagnostic: string): Integer;
var
  Arguments: TStringArray;
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
  StandardOutput: string;
  i, Count: Integer;

  procedure AddArgument(const AValue: string);
  begin
    Count := Length(Arguments);
    SetLength(Arguments, Count + 1);
    Arguments[Count] := AValue;
  end;

begin
  SetLength(Arguments, 0);
  AddArgument('-Sh');
  AddArgument('-FE' + ARequest.Outputs.ExecutableDirectory);
  AddArgument('-FU' + ARequest.Outputs.UnitDirectory);
  AddArgument('-o' + ARequest.Outputs.Artifact);
  for i := 0 to High(ARequest.Inputs.UnitPaths) do
    AddArgument('-Fu' + ARequest.Inputs.UnitPaths[i]);
  for i := 0 to High(ARequest.Inputs.IncludePaths) do
    AddArgument('-Fi' + ARequest.Inputs.IncludePaths[i]);
  AddArgument(ARequest.Inputs.EntryPoint);
  P := TProcess.Create(nil);
  Runner := nil;
  try
    P.Executable := TestCompilerExecutable;
    for i := 0 to High(Arguments) do P.Parameters.Add(Arguments[i]);
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('integration proxy FPC compile');
    Options.TimeoutMilliseconds := 60000;
    Result := Runner.Run('', Options, StandardOutput, ADiagnostic);
    ADiagnostic := StandardOutput + ADiagnostic;
  finally
    Runner.Free;
    P.Free;
  end;
end;

procedure RunDriver(const AOperation: string);
var
  BuildResult: TLWPTBuildResult;
  Capabilities: TLWPTCompilerCapabilities;
  Diagnostic, Mode: string;
  Request: TLWPTBuildRequest;
  ExitCode, ProbeCount: Integer;
begin
  Mode := ReadMode;
  if AOperation = 'probe' then
  begin
    ParseCompilerProbeRequest(ReadInput);
    ProbeCount := IncrementProbeCount;
    if (Mode = 'publication-lease') and (ProbeCount >= 3) then
      ObservePublicationLease;
    Capabilities := DefaultCompilerCapabilities;
    if Mode = 'identity-mismatch' then Capabilities.CompilerID := 'wrong'
    else Capabilities.CompilerID := DRIVER_ID;
    if (Mode = 'version-mismatch')
       or ((Mode = 'capability-mutation') and (ProbeCount >= 2)) then
      Capabilities.VersionIdentity := '2.0.0'
    else
      Capabilities.VersionIdentity := '1.0.0';
    SetLength(Capabilities.Targets, 1);
    if ((Mode = 'target-mismatch') and (ProbeCount >= 2))
       or ((Mode = 'publication-target-mutation')
         and (ProbeCount >= 3)) then
    begin
      Capabilities.Targets[0].OS := 'unsupported-os';
      Capabilities.Targets[0].Architecture := 'unsupported-arch';
    end
    else
    begin
      Capabilities.Targets[0].OS := Platform.GetBuildOS;
      Capabilities.Targets[0].Architecture := Platform.GetBuildArch;
    end;
    SetLength(Capabilities.OutputKinds, 1);
    Capabilities.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
    SetLength(Capabilities.Modes, 2);
    Capabilities.Modes[0] := BUILD_MODE_DEV;
    Capabilities.Modes[1] := BUILD_MODE_RELEASE;
    WriteLn(ErrOutput, 'integration proxy raw diagnostic');
    Write(SerializeCompilerCapabilities(Capabilities));
    Halt(0);
  end;
  if AOperation <> 'compile' then Halt(2);
  if Mode = 'timeout' then
  begin
    Sleep(30000);
    Halt(0);
  end;
  Request := ParseBuildRequest(ReadInput);
  if Mode = 'malformed' then
  begin
    WriteLn(ErrOutput, 'malformed compile raw diagnostic');
    Write('not = [valid');
    Halt(0);
  end;
  ExitCode := CompileWithFPC(Request, Diagnostic);
  if Diagnostic <> '' then Write(ErrOutput, Diagnostic);
  BuildResult := DefaultBuildResult;
  BuildResult.Success := ExitCode = 0;
  if BuildResult.Success then
  begin
    if Mode = 'reordered-artifacts' then
    begin
      SetLength(BuildResult.Artifacts, 2);
      BuildResult.Artifacts[0].Kind := 'debug';
      BuildResult.Artifacts[0].Path :=
        Request.Outputs.UnitDirectory + '/first.map';
      WriteTextFile(BuildResult.Artifacts[0].Path,
        'auxiliary artifact must not be published');
      BuildResult.Artifacts[1].Kind := Request.OutputKind;
      BuildResult.Artifacts[1].Path := Request.Outputs.Artifact;
    end
    else
    begin
      SetLength(BuildResult.Artifacts, 1 + Ord(Mode = 'extra-artifact'));
      BuildResult.Artifacts[0].Kind := Request.OutputKind;
      BuildResult.Artifacts[0].Path := Request.Outputs.Artifact;
      if Mode = 'extra-artifact' then
      begin
        BuildResult.Artifacts[1].Kind := 'debug';
        BuildResult.Artifacts[1].Path := ExpandFileName('outside.map');
      end;
    end;
  end
  else
  begin
    SetLength(BuildResult.Diagnostics, 1);
    BuildResult.Diagnostics[0].Severity := DIAGNOSTIC_ERROR;
    BuildResult.Diagnostics[0].MessageText := 'proxy FPC compile failed';
  end;
  Write(SerializeBuildResult(BuildResult));
  Halt(ExitCode);
end;

function TomlString(const AValue: string): string;
begin
  Result := StringReplace(AValue, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

procedure TCompilerProfiles.SetMode(const AMode: string);
begin
  WriteTextFile(FScratch + '/.driver-mode', AMode);
  WriteTextFile(FScratch + '/.probe-count', '0');
  if FileExists(FScratch + '/.lease-observed') then
    DeleteFile(FScratch + '/.lease-observed');
  if FileExists(FScratch + '/.entry-lease-observed') then
    DeleteFile(FScratch + '/.entry-lease-observed');
  if FileExists(FScratch + '/.whole-lease-observed') then
    DeleteFile(FScratch + '/.whole-lease-observed');
  RecursiveDelete(FScratch + '/build');
end;

procedure TCompilerProfiles.WriteManifest(const AEntryCompiler: string;
  const AObservePostBuildLeases: Boolean);
var
  CompilerField, EntryPostBuild, WholePostBuild: string;
begin
  if AEntryCompiler = '' then CompilerField := ''
  else CompilerField := ', compiler = "' + AEntryCompiler + '"';
  EntryPostBuild := '';
  WholePostBuild := '';
  if AObservePostBuildLeases then
  begin
    EntryPostBuild := ', postbuild = { lease = { script = '
      + '"scripts/observe-lease.pas", args = '
      + '[".entry-lease-observed"] } }';
    WholePostBuild := #10
      + '[postbuild]'#10
      + 'lease = { script = "scripts/observe-lease.pas", args = '
      + '[".whole-lease-observed"] }'#10;
  end;
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "compiler-profile-project"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[compiler]'#10
    + 'default = "external"'#10
    + #10
    + '[compiler.profiles.external]'#10
    + 'driver = "' + DRIVER_ID + '"'#10
    + 'executable = "' + TomlString(ExpandFileName(ParamStr(0))) + '"'#10
    + 'version = "^1.0.0"'#10
    + #10
    + '[compiler.profiles.native]'#10
    + 'driver = "fpc"'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app"'
    + CompilerField + EntryPostBuild + ' }'#10
    + WholePostBuild);
end;

procedure TCompilerProfiles.BeforeAll;
var
  EnvironmentUnitPath, TestingUnitPath: string;
begin
  FScratch := CreateScratchRoot('compiler-profiles');
  RecursiveDelete(FScratch);
  EnvironmentUnitPath := FScratch + '/environment-units';
  TestingUnitPath := ExpandFileName('.lwpt/modules/testing/source');
  WriteTextFile(FScratch + '/.lwpt-binary', LwptBinaryPath);
  WriteTextFile(FScratch + '/lwpt.cfg', '-Fu' + TestingUnitPath + #10);
  WriteTextFile(FScratch + '/source/app.pas',
    'program app;'#10'begin'#10'end.'#10);
  WriteTextFile(FScratch + '/source/Example.Test.pas',
      'program Example.Test;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses EnvironmentOnlyUnit, TestingPascalLibrary;'#10
    + 'begin'#10
    + '  if ENVIRONMENT_ONLY_MARKER <> 1 then Halt(2);'#10
    + '  TestRunnerProgram.Run;'#10
    + '  ExitCode := TestResultToExitCode;'#10
    + 'end.'#10);
  WriteTextFile(EnvironmentUnitPath + '/EnvironmentOnlyUnit.pas',
      'unit EnvironmentOnlyUnit;'#10
    + '{$mode delphi}{$H+}'#10
    + 'interface'#10
    + 'const ENVIRONMENT_ONLY_MARKER = 1;'#10
    + 'implementation'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/scripts/observe-lease.pas',
      'program ObserveLease;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Found: Boolean; Lines: TStringList; Root: string; '
    + 'Search: TSearchRec;'#10
    + 'begin'#10
    + '  Found := False;'#10
    + '  Root := GetEnvironmentVariable(''' + WORKER_STATE_DIR_ENV + ''');'#10
    + '  if FindFirst(IncludeTrailingPathDelimiter(Root) + ''*.request'', '
    + 'faAnyFile, Search) = 0 then'#10
    + '  try'#10
    + '    repeat'#10
    + '      Lines := TStringList.Create;'#10
    + '      try'#10
    + '        Lines.LoadFromFile(IncludeTrailingPathDelimiter(Root) '
    + '+ Search.Name);'#10
    + '        if Trim(Lines.Values[''lease-tokens'']) <> '''' then '
    + 'Found := True;'#10
    + '      finally Lines.Free; end;'#10
    + '    until Found or (FindNext(Search) <> 0);'#10
    + '  finally FindClose(Search); end;'#10
    + '  if not Found then Halt(2);'#10
    + '  Lines := TStringList.Create;'#10
    + '  try Lines.Text := ''held''; Lines.SaveToFile(ParamStr(1));'#10
    + '  finally Lines.Free; end;'#10
    + 'end.'#10);
end;

procedure TCompilerProfiles.TestExternalBuildAndTestSucceed;
var
  EnvironmentUnitPaths: string;
  R: TLwptResult;
begin
  SetMode('success');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  DumpRunFailure('external build', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app'))).ToBe(True);
  EnvironmentUnitPaths := GetEnvironmentVariable(
    PROJECT_NAME + '_FPC_UNIT_PATHS');
  if EnvironmentUnitPaths <> '' then
    EnvironmentUnitPaths := EnvironmentUnitPaths + PathSeparator;
  EnvironmentUnitPaths := EnvironmentUnitPaths
    + FScratch + '/environment-units';
  R := RunLwpt(['test', '--jobs', '1'], FScratch,
    [PROJECT_NAME + '_FPC_UNIT_PATHS=' + EnvironmentUnitPaths]);
  DumpRunFailure('external test', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TCompilerProfiles.TestEntryProfileOverridesProjectDefault;
var
  R: TLwptResult;
begin
  SetMode('identity-mismatch');
  WriteManifest('native');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  DumpRunFailure('entry precedence', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TCompilerProfiles.TestIdentityMismatchNeverFallsBack;
var
  R: TLwptResult;
begin
  SetMode('identity-mismatch');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('returned compiler identity "wrong"',
    R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app'))).ToBe(False);
end;

procedure TCompilerProfiles.TestVersionMismatchFails;
var
  R: TLwptResult;
begin
  SetMode('version-mismatch');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('does not satisfy', R.Stdout + R.Stderr) > 0).ToBe(True);
end;

procedure TCompilerProfiles.TestTargetMismatchFails;
var
  R: TLwptResult;
begin
  SetMode('target-mismatch');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('target tuple', R.Stdout + R.Stderr) > 0).ToBe(True);
end;

procedure TCompilerProfiles.TestLiveCapabilityMutationFailsBeforeCompile;
var
  R: TLwptResult;
begin
  SetMode('capability-mutation');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('does not satisfy', R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app'))).ToBe(False);
end;

procedure TCompilerProfiles.TestMalformedStdoutRetainsStderr;
var
  R: TLwptResult;
begin
  SetMode('malformed');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('malformed compile raw diagnostic',
    R.Stdout + R.Stderr) > 0).ToBe(True);
end;

procedure TCompilerProfiles.TestCompileTimeoutCleansUp;
var
  R: TLwptResult;
begin
  SetMode('timeout');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch,
    [COMPILER_TIMEOUT_ENVIRONMENT + '=100']);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('timed out after 100 ms', R.Stdout + R.Stderr) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app'))).ToBe(False);
end;

procedure TCompilerProfiles.TestExtraArtifactIsRejected;
var
  R: TLwptResult;
begin
  SetMode('extra-artifact');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('outside the declared private output roots',
    R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app'))).ToBe(False);
end;

procedure TCompilerProfiles.TestReorderedArtifactsPublishTheRequestedPrimary;
var
  Options: TLWPTProcessRunOptions;
  P: TProcess;
  R: TLwptResult;
  Runner: TLWPTDuplexProcessRunner;
  StandardError, StandardOutput: string;
begin
  SetMode('reordered-artifacts');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  DumpRunFailure('reordered artifacts', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);

  P := TProcess.Create(nil);
  Runner := nil;
  try
    P.Executable := ExpectedExe(FScratch + '/build/app');
    Runner := TLWPTDuplexProcessRunner.Create(P);
    Options := DefaultProcessRunOptions('published primary artifact');
    Options.SeparateStandardError := True;
    Options.TimeoutMilliseconds := 5000;
    Expect<Integer>(Runner.Run('', Options, StandardOutput, StandardError))
      .ToBe(0);
  finally
    Runner.Free;
    P.Free;
  end;
end;

procedure TCompilerProfiles.TestPublicationTargetMutationBlocksPublication;
var
  R: TLwptResult;
begin
  SetMode('publication-target-mutation');
  WriteManifest('external');
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('target tuple is not supported',
    R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/app'))).ToBe(False);
end;

procedure TCompilerProfiles.TestPublicationRevalidationRetainsWorkerCapacity;
var
  R: TLwptResult;
begin
  SetMode('publication-lease');
  WriteManifest('external', True);
  R := RunLwpt(['build', '--jobs', '1'], FScratch,
    [WORKER_STATE_DIR_ENV + '=' + FScratch + '/worker-state',
     WORKER_BUDGET_ENV + '=1']);
  DumpRunFailure('publication lease', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/.entry-lease-observed')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/.whole-lease-observed')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/.lease-observed')).ToBe(True);
end;

procedure TCompilerProfiles.SetupTests;
begin
  Test('root external profile drives real build and test',
    TestExternalBuildAndTestSucceed);
  Test('entry profile overrides project default',
    TestEntryProfileOverridesProjectDefault);
  Test('identity mismatch never falls back',
    TestIdentityMismatchNeverFallsBack);
  Test('version mismatch fails explicitly', TestVersionMismatchFails);
  Test('live capability mutation fails before compile',
    TestLiveCapabilityMutationFailsBeforeCompile);
  Test('target mismatch fails explicitly', TestTargetMismatchFails);
  Test('malformed stdout retains stderr in the job log',
    TestMalformedStdoutRetainsStderr);
  Test('compile timeout terminates and leaves no public artifact',
    TestCompileTimeoutCleansUp);
  Test('extra artifact outside private roots is rejected',
    TestExtraArtifactIsRejected);
  Test('artifact order does not change the requested primary publication',
    TestReorderedArtifactsPublishTheRequestedPrimary);
  Test('third-probe target mutation blocks publication',
    TestPublicationTargetMutationBlocksPublication);
  Test('postbuild and publication revalidation retain worker capacity',
    TestPublicationRevalidationRetainsWorkerCapacity);
end;

begin
  if (ParamCount = 1)
     and ((ParamStr(1) = 'probe') or (ParamStr(1) = 'compile')) then
    RunDriver(ParamStr(1));
  TestRunnerProgram.AddSuite(TCompilerProfiles.Create('compiler profiles'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
