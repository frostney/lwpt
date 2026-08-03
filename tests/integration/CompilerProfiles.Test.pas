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
  LAKON_DRIVER_ID = 'lakon';
  LAKON_MODE = 'lakon-cfg';
  LEASE_OBSERVER_ENV = PROJECT_NAME + '_LEASE_OBSERVER';

type
  TCompilerProfiles = class(TTestSuite)
  private
    FScratch: string;
    procedure SetMode(const AMode: string);
    procedure WriteLakonManifest;
    procedure WriteManifest(const AEntryCompiler: string = 'external';
      const AObservePostBuildLeases: Boolean = False);
    procedure WriteBlaiseManifest;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestExternalBuildAndTestSucceed;
    procedure TestEntryProfileOverridesProjectDefault;
    procedure TestIdentityMismatchNeverFallsBack;
    procedure TestVersionMismatchFails;
    procedure TestLiveCapabilityMutationFailsBeforeCompile;
    procedure TestLakonBuildConsumesCfgUnitPaths;
    procedure TestTargetMismatchFails;
    procedure TestMalformedStdoutRetainsStderr;
    procedure TestMalformedTestResultDoesNotAbortSibling;
    procedure TestCompileTimeoutCleansUp;
    procedure TestExtraArtifactIsRejected;
    procedure TestReorderedArtifactsPublishTheRequestedPrimary;
    procedure TestPublicationTargetMutationBlocksPublication;
    procedure TestPublicationRevalidationRetainsWorkerCapacity;
    procedure TestBuiltInBlaiseProfileDispatchesWithoutFallback;
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

procedure RunLakonDriver;
var
  ArgumentIndex: Integer;
  HasCfgUnitPath: Boolean;
  OutputPath: string;
begin
  if (ParamCount = 1) and (ParamStr(1) = '--version') then
  begin
    WriteLn(LAKON_DRIVER_ID, ' 0.1.0');
    Halt(0);
  end;
  if (ParamCount = 1) and (ParamStr(1) = '--help') then
  begin
    WriteLn('usage: ', LAKON_DRIVER_ID, ' <command>');
    WriteLn(LAKON_DRIVER_ID, ' compile <file> - Compile Pascal to WebAssembly');
    WriteLn('-o <file>');
    WriteLn('-Fu <dir>');
    WriteLn('-d <sym>');
    WriteLn('--no-cache');
    WriteLn('--verbose-units');
    WriteLn('--no-inline');
    WriteLn('--inline-stats');
    Halt(0);
  end;
  if (ParamCount < 2) or (ParamStr(1) <> 'compile') then Halt(2);
  HasCfgUnitPath := False;
  OutputPath := '';
  ArgumentIndex := 3;
  while ArgumentIndex <= ParamCount do
  begin
    if (ParamStr(ArgumentIndex) = '-Fu')
       and (ArgumentIndex < ParamCount) then
    begin
      Inc(ArgumentIndex);
      if ExpandFileName(ParamStr(ArgumentIndex)) =
         ExpandFileName('cfg-only-units') then HasCfgUnitPath := True;
    end
    else if (ParamStr(ArgumentIndex) = '-o')
      and (ArgumentIndex < ParamCount) then
    begin
      Inc(ArgumentIndex);
      OutputPath := ParamStr(ArgumentIndex);
    end;
    Inc(ArgumentIndex);
  end;
  if not HasCfgUnitPath then Halt(3);
  if OutputPath = '' then Halt(4);
  WriteTextFile(OutputPath, 'cfg-only unit path reached Lakon');
  Halt(0);
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
  if SysUtils.GetEnvironmentVariable(LEASE_OBSERVER_ENV) <> '' then Exit;
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
    ConfigureProcessEnvironment(P, [WORKER_LEASE_TOKEN_ENV + '=',
      LEASE_OBSERVER_ENV + '=1']);
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

procedure RunBlaiseProxy;
var
  Diagnostic, Value: string;
  Request: TLWPTBuildRequest;
  ArgumentIndex, Count, ExitCode: Integer;
begin
  if ParamStr(1) = '--help' then
  begin
    WriteTextFile(ExpandFileName('.blaise-help'), 'probed');
    WriteLn('Blaise Compiler v0.13.0');
    WriteLn('Usage:');
    WriteLn('  blaise --source <file.pas> --output <binary>');
    WriteLn('Flags:');
    WriteLn('  --target <os>-<cpu>  Cross-compile target (default: '
      + 'linux-x86_64, the host).');
    WriteLn('                         linux-x86_64, freebsd-x86_64');
    Halt(0);
  end;

  Request := DefaultBuildRequest;
  Request.Compiler.ID := 'blaise';
  Request.Compiler.VersionConstraint := '>=0.13.0';
  Request.Target.OS := 'linux';
  Request.Target.Architecture := 'x86_64';
  Request.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Request.Mode := BUILD_MODE_DEV;
  ArgumentIndex := 1;
  while ArgumentIndex <= ParamCount do
  begin
    Value := ParamStr(ArgumentIndex);
    if (Value = '--source') and (ArgumentIndex < ParamCount) then
    begin
      Inc(ArgumentIndex);
      Request.Inputs.EntryPoint := ParamStr(ArgumentIndex);
      SetLength(Request.Inputs.Sources, 1);
      Request.Inputs.Sources[0] := Request.Inputs.EntryPoint;
    end
    else if (Value = '--output') and (ArgumentIndex < ParamCount) then
    begin
      Inc(ArgumentIndex);
      Request.Outputs.Artifact := ParamStr(ArgumentIndex);
      Request.Outputs.ExecutableDirectory := ExtractFileDir(
        Request.Outputs.Artifact);
    end
    else if (Value = '--unit-path') and (ArgumentIndex < ParamCount) then
    begin
      Inc(ArgumentIndex);
      Count := Length(Request.Inputs.UnitPaths);
      SetLength(Request.Inputs.UnitPaths, Count + 1);
      Request.Inputs.UnitPaths[Count] := ParamStr(ArgumentIndex);
    end
    else if (Value = '--unit-cache') and (ArgumentIndex < ParamCount) then
    begin
      Inc(ArgumentIndex);
      Request.Outputs.UnitDirectory := ParamStr(ArgumentIndex);
      Request.Outputs.ObjectDirectory := Request.Outputs.UnitDirectory;
    end
    else if ((Value = '--target') or (Value = '--backend')
      or (Value = '--define')) and (ArgumentIndex < ParamCount) then
      Inc(ArgumentIndex);
    Inc(ArgumentIndex);
  end;
  if Request.Outputs.UnitDirectory = '' then
  begin
    Request.Outputs.UnitDirectory := Request.Outputs.ExecutableDirectory;
    Request.Outputs.ObjectDirectory := Request.Outputs.UnitDirectory;
  end;
  WriteTextFile(ExpandFileName('.blaise-compile'), 'compiled');
  ExitCode := CompileWithFPC(Request, Diagnostic);
  if Diagnostic <> '' then Write(ErrOutput, Diagnostic);
  Halt(ExitCode);
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
    if SysUtils.GetEnvironmentVariable(LEASE_OBSERVER_ENV) <> '' then
      ProbeCount := 0
    else
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
  if (Mode = 'malformed-test-result')
     and (Pos('Broken.Test.pas', Request.Inputs.EntryPoint) > 0) then
  begin
    WriteLn(ErrOutput, 'malformed sibling raw diagnostic');
    Write('not = [valid');
    Halt(0);
  end;
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
  if FileExists(FScratch + '/.blaise-help') then
    DeleteFile(FScratch + '/.blaise-help');
  if FileExists(FScratch + '/.blaise-compile') then
    DeleteFile(FScratch + '/.blaise-compile');
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

procedure TCompilerProfiles.WriteLakonManifest;
begin
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "lakon-cfg-project"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[compiler]'#10
    + 'default = "' + LAKON_DRIVER_ID + '"'#10
    + #10
    + '[compiler.profiles.' + LAKON_DRIVER_ID + ']'#10
    + 'driver = "' + LAKON_DRIVER_ID + '"'#10
    + 'executable = "' + TomlString(ExpandFileName(ParamStr(0))) + '"'#10
    + 'version = "^0.1.0"'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app.wasm" }'#10);
end;

procedure TCompilerProfiles.WriteBlaiseManifest;
begin
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "compiler-profile-project"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[compiler]'#10
    + 'default = "modern"'#10
    + #10
    + '[compiler.profiles.modern]'#10
    + 'driver = "blaise"'#10
    + 'executable = "' + TomlString(ExpandFileName(ParamStr(0))) + '"'#10
    + 'version = ">=0.13.0"'#10
    + #10
    + '[build]'#10
    + 'app = { source = "source/app.pas", output = "build/app" }'#10);
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
  WriteTextFile(FScratch + '/source/Broken.Test.pas',
      'program Broken.Test;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses TestingPascalLibrary;'#10
    + 'begin'#10
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

procedure TCompilerProfiles.TestLakonBuildConsumesCfgUnitPaths;
var
  OriginalCfg, UpdatedCfg: TStringList;
  R: TLwptResult;
begin
  SetMode(LAKON_MODE);
  WriteLakonManifest;
  WriteTextFile(FScratch + '/source/app.pas',
    'program app;'#10'uses CfgOnlyUnit;'#10'begin'#10'end.'#10);
  WriteTextFile(FScratch + '/cfg-only-units/CfgOnlyUnit.pas',
      'unit CfgOnlyUnit;'#10
    + 'interface'#10
    + 'implementation'#10
    + 'end.'#10);
  OriginalCfg := TStringList.Create;
  UpdatedCfg := TStringList.Create;
  try
    OriginalCfg.LoadFromFile(FScratch + '/lwpt.cfg');
    UpdatedCfg.Assign(OriginalCfg);
    UpdatedCfg.Add('-Fucfg-only-units');
    AtomicWriteText(FScratch + '/lwpt.cfg', FScratch + '/.lwpt/tmp',
      UpdatedCfg);
    R := RunLwpt(['build', '--jobs', '1'], FScratch);
    DumpRunFailure('Lakon cfg-only unit path', R, 0);
    Expect<Integer>(R.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(FScratch + '/build/app.wasm')).ToBe(True);
  finally
    AtomicWriteText(FScratch + '/lwpt.cfg', FScratch + '/.lwpt/tmp',
      OriginalCfg);
    UpdatedCfg.Free;
    OriginalCfg.Free;
    WriteTextFile(FScratch + '/source/app.pas',
      'program app;'#10'begin'#10'end.'#10);
  end;
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

procedure TCompilerProfiles.TestMalformedTestResultDoesNotAbortSibling;
var
  EnvironmentUnitPaths: string;
  R: TLwptResult;
begin
  SetMode('malformed-test-result');
  WriteManifest('external');
  EnvironmentUnitPaths := GetEnvironmentVariable(
    PROJECT_NAME + '_FPC_UNIT_PATHS');
  if EnvironmentUnitPaths <> '' then
    EnvironmentUnitPaths := EnvironmentUnitPaths + PathSeparator;
  EnvironmentUnitPaths := EnvironmentUnitPaths
    + FScratch + '/environment-units';
  R := RunLwpt(['test', '--jobs', '1', '--bail', '0'], FScratch,
    [PROJECT_NAME + '_FPC_UNIT_PATHS=' + EnvironmentUnitPaths]);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('Broken.Test.pas', R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('Example.Test.pas', R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('summary: 1 passed, 0 failed, 1 did not compile',
    R.Stdout + R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('scheduler error', R.Stdout + R.Stderr) = 0).ToBe(True);
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

procedure TCompilerProfiles.TestBuiltInBlaiseProfileDispatchesWithoutFallback;
var
  R: TLwptResult;
begin
  SetMode('success');
  WriteBlaiseManifest;
  R := RunLwpt(['build', '--jobs', '1'], FScratch);
  DumpRunFailure('built-in Blaise build', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/.blaise-help')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/.blaise-compile')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(True);
end;

procedure TCompilerProfiles.SetupTests;
begin
  Test('root external profile drives real build and test',
    TestExternalBuildAndTestSucceed);
  Test('Lakon build consumes cfg-only dependency unit paths',
    TestLakonBuildConsumesCfgUnitPaths);
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
  Test('malformed test results fail one test without aborting its sibling',
    TestMalformedTestResultDoesNotAbortSibling);
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
  Test('built-in Blaise profile dispatches without FPC fallback',
    TestBuiltInBlaiseProfileDispatchesWithoutFallback);
end;

begin
  if ReadMode = LAKON_MODE then RunLakonDriver;
  if (ParamCount > 0)
     and ((ParamStr(1) = '--help') or (ParamStr(1) = '--source')) then
    RunBlaiseProxy;
  if (ParamCount = 1)
     and ((ParamStr(1) = 'probe') or (ParamStr(1) = 'compile')) then
    RunDriver(ParamStr(1));
  TestRunnerProgram.AddSuite(TCompilerProfiles.Create('compiler profiles'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
