program LWPT.CompilerDriver.Delphi.Test;

{$I Shared.inc}
{$J-}

uses
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.Delphi,
  LWPT.CompilerRegistry,
  LWPT.Core,
  LWPT.Manifest,
  TestingPascalLibrary,
  Tests.Scratch;

type
  TMockDelphiCompilerDriver = class(TLWPTDelphiCompilerDriver)
  private
    FProbeCount: Integer;
    FProbeExitCode: Integer;
    FProbeOutput: string;
  protected
    function ExecuteProbe(const AArguments: LWPT.Core.TStringArray;
      out AOutput: string): Integer; override;
  public
    function ExposedGeneratedArtifactPath(
      const ARequest: TLWPTBuildRequest): string;
    property ProbeCount: Integer read FProbeCount;
    property ProbeExitCode: Integer read FProbeExitCode
      write FProbeExitCode;
    property ProbeOutput: string read FProbeOutput write FProbeOutput;
  end;

  TLWPTDelphiCompilerDriverTests = class(TTestSuite)
  private
    FScratchRoot: string;
    function ArgumentsContain(const AArguments: LWPT.Core.TStringArray;
      const AExpected: string): Boolean;
    function FixtureRequest(const ADriver: TLWPTCompilerDriver):
      TLWPTBuildRequest;
    procedure ExpectTarget(const AExecutable, AProductLabel, AOS,
      AArchitecture: string);
  public
    procedure BeforeAll; override;
    procedure AfterAll; override;
    procedure SetupTests; override;
    procedure TestVerifiedExecutableTargetMatrix;
    procedure TestUnknownExecutableIsRejected;
    procedure TestRootProfileSelectsBuiltInDriver;
    procedure TestProbeRefreshesIdentityVersionAndTargetEveryTime;
    procedure TestProbeRejectsOldVersion;
    procedure TestProbeFailuresRetainBoundedDiagnosticContext;
    procedure TestProbeRejectsExecutableHeaderMismatch;
    procedure TestProbeRejectsUnsupportedRequestedTarget;
    procedure TestArgumentsTranslateNeutralContract;
    procedure TestManagedExtraArgumentsAreRejected;
    procedure TestDiagnosticsRetainSourceLocationAndCode;
    procedure TestSuccessfulResultMovesArtifactToRequestedName;
  end;

function TMockDelphiCompilerDriver.ExecuteProbe(
  const AArguments: LWPT.Core.TStringArray; out AOutput: string): Integer;
begin
  Inc(FProbeCount);
  AOutput := FProbeOutput;
  Result := FProbeExitCode;
end;

function TMockDelphiCompilerDriver.ExposedGeneratedArtifactPath(
  const ARequest: TLWPTBuildRequest): string;
begin
  Result := GeneratedArtifactPath(ARequest);
end;

procedure TLWPTDelphiCompilerDriverTests.BeforeAll;
begin
  FScratchRoot := CreateScratchRoot('delphi-driver');
end;

procedure TLWPTDelphiCompilerDriverTests.AfterAll;
begin
  RecursiveDelete(FScratchRoot);
end;

function TLWPTDelphiCompilerDriverTests.ArgumentsContain(
  const AArguments: LWPT.Core.TStringArray;
  const AExpected: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AArguments) do
    if AArguments[i] = AExpected then Exit(True);
  Result := False;
end;

function TLWPTDelphiCompilerDriverTests.FixtureRequest(
  const ADriver: TLWPTCompilerDriver): TLWPTBuildRequest;
begin
  Result := ADriver.CreateBuildRequest('source/App.dpr',
    FScratchRoot + '/bin/Renamed.exe');
  Result.Outputs.ExecutableDirectory := FScratchRoot + '/bin';
  Result.Outputs.UnitDirectory := FScratchRoot + '/units';
  Result.Outputs.ObjectDirectory := FScratchRoot + '/objects';
end;

procedure TLWPTDelphiCompilerDriverTests.ExpectTarget(
  const AExecutable, AProductLabel, AOS, AArchitecture: string);
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockDelphiCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := TMockDelphiCompilerDriver.Create(AExecutable);
  try
    Target := Driver.DefaultTarget;
    Expect<string>(Target.OS).ToBe(AOS);
    Expect<string>(Target.Architecture).ToBe(AArchitecture);
    Driver.ProbeOutput := 'Embarcadero Delphi for ' + AProductLabel
      + ' compiler version 36.0';
    Capabilities := Driver.ProbeCapabilities(Target, True);
    Expect<string>(Capabilities.Targets[0].OS).ToBe(AOS);
    Expect<string>(Capabilities.Targets[0].Architecture)
      .ToBe(AArchitecture);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.TestVerifiedExecutableTargetMatrix;
begin
  ExpectTarget('C:/Delphi/bin/dcc32.exe', 'Win32', 'win32', 'i386');
  ExpectTarget('C:/Delphi/bin/dcc64.exe', 'Win64', 'win64', 'x86_64');
  ExpectTarget('C:/Delphi/bin/dcclinux64.exe', 'Linux 64 bit',
    'linux', 'x86_64');
  ExpectTarget('C:/Delphi/bin/dccosx64.exe', 'Mac OS X 64 bit',
    'darwin', 'x86_64');
  ExpectTarget('C:/Delphi/bin/dccosxarm64.exe', 'Mac OS X ARM 64 bit',
    'darwin', 'aarch64');
end;

procedure TLWPTDelphiCompilerDriverTests.TestUnknownExecutableIsRejected;
var
  Driver: TLWPTDelphiCompilerDriver;
  Raised: Boolean;
begin
  Driver := TLWPTDelphiCompilerDriver.Create('custom-dcc.exe');
  try
    Raised := False;
    try
      Driver.DefaultTarget;
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('not a verified Delphi command-line compiler',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.TestRootProfileSelectsBuiltInDriver;
var
  Driver: TLWPTCompilerDriver;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'delphi-win64';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0].Name := 'delphi-win64';
  Manifest.CompilerProfiles[0].Driver := DELPHI_COMPILER_ID;
  Manifest.CompilerProfiles[0].Executable := 'tools/dcc64.exe';
  Manifest.CompilerProfiles[0].VersionConstraint := '>=36.0.0';
  Selection := TLWPTCompilerSelection.Create(Manifest, FScratchRoot);
  try
    Driver := Selection.DriverFor('');
    Expect<string>(Driver.CompilerID).ToBe(DELPHI_COMPILER_ID);
    Expect<string>(Driver.ExecutableName)
      .ToBe(ExpandFileName(FScratchRoot + '/tools/dcc64.exe'));
  finally
    Selection.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestProbeRefreshesIdentityVersionAndTargetEveryTime;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TMockDelphiCompilerDriver;
  Target: TLWPTTarget;
begin
  Driver := TMockDelphiCompilerDriver.Create('dcc64.exe');
  try
    Driver.ProbeOutput :=
      'Embarcadero Delphi for Win64 compiler version 37.0'#10
      + 'Copyright (c) Embarcadero Technologies, Inc.'#10;
    Target := Driver.DefaultTarget;
    Capabilities := Driver.ProbeCapabilities(Target);
    Expect<string>(Capabilities.VersionIdentity).ToBe('37.0.0');
    Capabilities := Driver.ProbeCapabilities(Target, True);
    Expect<string>(Capabilities.Targets[0].OS).ToBe('win64');
    Expect<Integer>(Driver.ProbeCount).ToBe(2);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.TestProbeRejectsOldVersion;
var
  Driver: TMockDelphiCompilerDriver;
  Raised: Boolean;
begin
  Driver := TMockDelphiCompilerDriver.Create('dcc32.exe');
  try
    Driver.ProbeOutput :=
      'Embarcadero Delphi for Win32 compiler version 35.0'#10;
    Raised := False;
    try
      Driver.ProbeCapabilities(Driver.DefaultTarget, True);
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('35.0.0', E.Message) > 0)
          and (Pos(DELPHI_MINIMUM_VERSION, E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestProbeFailuresRetainBoundedDiagnosticContext;
var
  Driver: TMockDelphiCompilerDriver;
  ErrorMessage: string;
  Raised: Boolean;
begin
  Driver := TMockDelphiCompilerDriver.Create('dcc32.exe');
  try
    Driver.ProbeExitCode := 7;
    Driver.ProbeOutput := StringOfChar('x', 5000) + 'license unavailable';
    Raised := False;
    try
      Driver.ProbeCapabilities(Driver.DefaultTarget, True);
    except
      on E: ELWPTCompilerDriverError do
      begin
        ErrorMessage := E.Message;
        Raised := (Pos('failed with exit 7', ErrorMessage) > 0)
          and (Pos('license unavailable', ErrorMessage) > 0)
          and (Length(ErrorMessage) < 4300);
      end;
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Driver.ProbeExitCode := 0;
    Driver.ProbeOutput := 'compiler configuration is incomplete';
    Raised := False;
    try
      Driver.ProbeCapabilities(Driver.DefaultTarget, True);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('compiler configuration is incomplete', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestProbeRejectsExecutableHeaderMismatch;
var
  Driver: TMockDelphiCompilerDriver;
  Raised: Boolean;
begin
  Driver := TMockDelphiCompilerDriver.Create('dcc32.exe');
  try
    Driver.ProbeOutput :=
      'Embarcadero Delphi for Win64 compiler version 36.0'#10;
    Raised := False;
    try
      Driver.ProbeCapabilities(Driver.DefaultTarget, True);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('identifies target "win64/x86_64"', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestProbeRejectsUnsupportedRequestedTarget;
var
  Driver: TMockDelphiCompilerDriver;
  Raised: Boolean;
  Target: TLWPTTarget;
begin
  Driver := TMockDelphiCompilerDriver.Create('dcclinux64.exe');
  try
    Driver.ProbeOutput :=
      'Embarcadero Delphi for Linux 64 bit compiler version 36.0'#10;
    Target := Driver.DefaultTarget;
    Target.Architecture := 'aarch64';
    Raised := False;
    try
      Driver.ProbeCapabilities(Target, True);
    except
      on E: ELWPTCompilerDriverError do
        Raised := (Pos('supports target "linux/x86_64"', E.Message) > 0)
          and (Pos('requested target "linux/aarch64"', E.Message) > 0);
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestArgumentsTranslateNeutralContract;
var
  Arguments: LWPT.Core.TStringArray;
  Driver: TLWPTDelphiCompilerDriver;
  Options: TLWPTCompilerInvocationOptions;
  Request: TLWPTBuildRequest;
begin
  ForceDirectories(FScratchRoot + '/config');
  WriteTextFile(FScratchRoot + '/config/lwpt.cfg',
    '-Fuconfig/units'#10 + '-dFPC_ONLY'#10);
  Driver := TLWPTDelphiCompilerDriver.Create('dcc64.exe');
  try
    Request := FixtureRequest(Driver);
    Request.Mode := BUILD_MODE_RELEASE;
    SetLength(Request.Inputs.Defines, 1);
    Request.Inputs.Defines[0] := 'PRODUCTION';
    SetLength(Request.Inputs.UnitPaths, 1);
    Request.Inputs.UnitPaths[0] := 'source';
    SetLength(Request.Inputs.IncludePaths, 1);
    Request.Inputs.IncludePaths[0] := 'include';
    SetLength(Request.Inputs.Resources, 2);
    Request.Inputs.Resources[0] := 'resources/app.res';
    Request.Inputs.Resources[1] := 'resources/icons/icon.res';
    SetLength(Request.Inputs.ExtraArguments, 1);
    Request.Inputs.ExtraArguments[0] := '-Q';
    Options := BuildCompilerInvocationOptions(
      FScratchRoot + '/config/lwpt.cfg', True);
    Arguments := Driver.BuildArguments(Request, Options);
    Expect<Boolean>(ArgumentsContain(Arguments,
      '-E' + FScratchRoot + '/bin')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments,
      '-NU' + FScratchRoot + '/units')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments,
      '-NO' + FScratchRoot + '/objects')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Uconfig/units')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Usource')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Iinclude')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments,
      '-Rresources;resources/icons')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-DPRODUCTION')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-$O+')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-B')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-TX.exe')).ToBe(True);
    Expect<Boolean>(ArgumentsContain(Arguments, '-Q')).ToBe(True);
    Expect<string>(Arguments[High(Arguments)]).ToBe('source/App.dpr');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestManagedExtraArgumentsAreRejected;
var
  Arguments: LWPT.Core.TStringArray;
  Driver: TLWPTDelphiCompilerDriver;
  Raised: Boolean;
  Request: TLWPTBuildRequest;
begin
  Driver := TLWPTDelphiCompilerDriver.Create('dcc64.exe');
  try
    Request := FixtureRequest(Driver);
    SetLength(Request.Inputs.ExtraArguments, 1);
    Request.Inputs.ExtraArguments[0] := '-Eoutside';
    Raised := False;
    try
      Driver.BuildArguments(Request,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('managed by ' + PROJECT_NAME, E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Request.Inputs.ExtraArguments[0] := '/$O-';
    Raised := False;
    try
      Driver.BuildArguments(Request,
        BuildCompilerInvocationOptions('', False));
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('managed by ' + PROJECT_NAME, E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);

    Request.Inputs.ExtraArguments[0] := '-NSSystem';
    Arguments := Driver.BuildArguments(Request,
      BuildCompilerInvocationOptions('', False));
    Expect<Boolean>(ArgumentsContain(Arguments, '-NSSystem')).ToBe(True);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestDiagnosticsRetainSourceLocationAndCode;
var
  Driver: TLWPTDelphiCompilerDriver;
  Request: TLWPTBuildRequest;
  Result: TLWPTBuildResult;
begin
  Driver := TLWPTDelphiCompilerDriver.Create('dcc64.exe');
  try
    Request := FixtureRequest(Driver);
    Result := Driver.NormalizeResult(Request, 1,
      'source/Widget.pas(12,7) Error: E2003 Undeclared identifier: Foo');
    Expect<Boolean>(Result.Success).ToBe(False);
    Expect<Integer>(Length(Result.Diagnostics)).ToBe(1);
    Expect<string>(Result.Diagnostics[0].Severity).ToBe(DIAGNOSTIC_ERROR);
    Expect<string>(Result.Diagnostics[0].Code).ToBe('E2003');
    Expect<string>(Result.Diagnostics[0].Path).ToBe('source/Widget.pas');
    Expect<Integer>(Result.Diagnostics[0].Line).ToBe(12);
    Expect<Integer>(Result.Diagnostics[0].Column).ToBe(7);
    Expect<string>(Result.Diagnostics[0].MessageText)
      .ToBe('Undeclared identifier: Foo');

    Result := Driver.NormalizeResult(Request, 1,
      'Fatal: F2048 Bad unit format');
    Expect<Boolean>(Result.Success).ToBe(False);
    Expect<Integer>(Length(Result.Diagnostics)).ToBe(1);
    Expect<string>(Result.Diagnostics[0].Severity).ToBe(DIAGNOSTIC_ERROR);
    Expect<string>(Result.Diagnostics[0].Code).ToBe('F2048');
    Expect<string>(Result.Diagnostics[0].MessageText)
      .ToBe('Bad unit format');

    ForceDirectories(Request.Outputs.ExecutableDirectory);
    WriteTextFile(Request.Outputs.ExecutableDirectory + '/App.exe',
      'compiled with a warning');
    Result := Driver.NormalizeResult(Request, 0,
      'source/Widget.pas(14) Warning: W1000 Error is a field name');
    Expect<Boolean>(Result.Success).ToBe(True);
    Expect<Integer>(Length(Result.Diagnostics)).ToBe(1);
    Expect<string>(Result.Diagnostics[0].Severity).ToBe(DIAGNOSTIC_WARNING);
    Expect<string>(Result.Diagnostics[0].Code).ToBe('W1000');
    Expect<string>(Result.Diagnostics[0].MessageText)
      .ToBe('Error is a field name');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.
  TestSuccessfulResultMovesArtifactToRequestedName;
var
  Driver: TMockDelphiCompilerDriver;
  Request: TLWPTBuildRequest;
  Result: TLWPTBuildResult;
begin
  Driver := TMockDelphiCompilerDriver.Create('dcc64.exe');
  try
    Request := FixtureRequest(Driver);
    ForceDirectories(Request.Outputs.ExecutableDirectory);
    WriteTextFile(Request.Outputs.ExecutableDirectory + '/App.exe',
      'compiled');
    Result := Driver.NormalizeResult(Request, 0,
      'Embarcadero Delphi for Win64 compiler version 37.0');
    Expect<Boolean>(Result.Success).ToBe(True);
    Expect<Boolean>(FileExists(Request.Outputs.Artifact)).ToBe(True);
    Expect<Boolean>(FileExists(
      Request.Outputs.ExecutableDirectory + '/App.exe')).ToBe(False);
    Expect<Integer>(Length(Result.Artifacts)).ToBe(1);
    Expect<string>(Result.Artifacts[0].Path)
      .ToBe(Request.Outputs.Artifact);

    Request.Outputs.ExecutableDirectory := '';
    Request.Outputs.Artifact := 'BareName.exe';
    Expect<string>(Driver.ExposedGeneratedArtifactPath(Request))
      .ToBe('App.exe');
  finally
    Driver.Free;
  end;
end;

procedure TLWPTDelphiCompilerDriverTests.SetupTests;
begin
  Test('verified executable names map to the release target matrix',
    TestVerifiedExecutableTargetMatrix);
  Test('unknown compiler executables are rejected without fallback',
    TestUnknownExecutableIsRejected);
  Test('root profiles select the built-in driver without external protocol',
    TestRootProfileSelectsBuiltInDriver);
  Test('identity, version, and target are probed on every operation',
    TestProbeRefreshesIdentityVersionAndTargetEveryTime);
  Test('versions older than Delphi 12 Athens are rejected',
    TestProbeRejectsOldVersion);
  Test('probe failures retain bounded compiler diagnostic context',
    TestProbeFailuresRetainBoundedDiagnosticContext);
  Test('executable and live header target must agree',
    TestProbeRejectsExecutableHeaderMismatch);
  Test('unsupported requested targets name the required executable profile',
    TestProbeRejectsUnsupportedRequestedTarget);
  Test('neutral build fields translate deterministically',
    TestArgumentsTranslateNeutralContract);
  Test('extra arguments cannot override driver-owned fields',
    TestManagedExtraArgumentsAreRejected);
  Test('normalized diagnostics retain Delphi source locations and codes',
    TestDiagnosticsRetainSourceLocationAndCode);
  Test('successful output is moved to the exact requested artifact',
    TestSuccessfulResultMovesArtifactToRequestedName);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTDelphiCompilerDriverTests.Create(
    'Delphi compiler driver'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
