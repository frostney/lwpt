program LWPT.CompilerRegistry.Test;

{$I Shared.inc}
{$J-}

uses
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.Lakon,
  LWPT.CompilerRegistry,
  LWPT.Core,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  TFactoryOwner = class;

  TFactoryDriver = class(TLWPTCompilerDriver)
  private
    FCompilerIdentity: string;
    FOwner: TFactoryOwner;
    FVersionIdentity: string;
  public
    constructor Create(const AOwner: TFactoryOwner;
      const ACompilerIdentity, AVersionIdentity: string);
    destructor Destroy; override;
    function CompilerID: string; override;
    function DefaultTarget: TLWPTTarget; override;
    function ProbeCapabilities(const ATarget: TLWPTTarget;
      const ARefresh: Boolean = False): TLWPTCompilerCapabilities; override;
    function BuildArguments(const ARequest: TLWPTBuildRequest;
      const AOptions: TLWPTCompilerInvocationOptions):
      LWPT.Core.TStringArray; override;
    function ExecutableName: string; override;
    function ClassifyFailure(const AExitCode: Integer;
      const ARawOutput: string): TLWPTCompilerFailure; override;
    function NormalizeResult(const ARequest: TLWPTBuildRequest;
      const AExitCode: Integer; const ARawOutput: string):
      TLWPTBuildResult; override;
  end;

  TFactoryOwner = class
  public
    CompilerIdentity: string;
    DestroyCount: Integer;
    VersionIdentity: string;
    constructor Create;
    function CreateDriver(const AProfile: TLWPTCompilerProfile;
      const AProjectRoot: string): TLWPTCompilerDriver;
  end;

  TLWPTCompilerRegistryTests = class(TTestSuite)
  private
    FFactoryOwner: TFactoryOwner;
    function Profile(const AName, AExecutable: string):
      TLWPTCompilerProfile;
  public
    procedure BeforeAll; override;
    procedure AfterAll; override;
    procedure SetupTests; override;
    procedure TestSelectionPrecedence;
    procedure TestHostDefaultPrecedesBuiltIn;
    procedure TestBuiltInFallback;
    procedure TestDriversAreCachedByProfile;
    procedure TestProfileCacheIsCaseInsensitive;
    procedure TestFactoryIdentityMismatchIsFreedAndRejected;
    procedure TestFactoryVersionMismatchIsRejected;
    procedure TestFactoryDriverIsFreedExactlyOnce;
    procedure TestLakonProfileSelectsBuiltInAdapter;
    procedure TestLakonEmbeddingFactoryReplacesAdapterAndFPCDefault;
    procedure TestLakonBuiltInRejectsScripts;
  end;

constructor TFactoryDriver.Create(const AOwner: TFactoryOwner;
  const ACompilerIdentity, AVersionIdentity: string);
begin
  inherited Create;
  FOwner := AOwner;
  FCompilerIdentity := ACompilerIdentity;
  FVersionIdentity := AVersionIdentity;
end;

destructor TFactoryDriver.Destroy;
begin
  Inc(FOwner.DestroyCount);
  inherited Destroy;
end;

function TFactoryDriver.CompilerID: string;
begin
  Result := FCompilerIdentity;
end;

function TFactoryDriver.DefaultTarget: TLWPTTarget;
begin
  Result := Default(TLWPTTarget);
  Result.OS := 'darwin';
  Result.Architecture := 'aarch64';
end;

function TFactoryDriver.ProbeCapabilities(const ATarget: TLWPTTarget;
  const ARefresh: Boolean): TLWPTCompilerCapabilities;
begin
  Result := DefaultCompilerCapabilities;
  Result.CompilerID := FCompilerIdentity;
  Result.VersionIdentity := FVersionIdentity;
  SetLength(Result.Targets, 1);
  Result.Targets[0] := DefaultTarget;
  SetLength(Result.OutputKinds, 1);
  Result.OutputKinds[0] := BUILD_OUTPUT_EXECUTABLE;
  SetLength(Result.Modes, 1);
  Result.Modes[0] := BUILD_MODE_DEV;
end;

function TFactoryDriver.BuildArguments(const ARequest: TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions):
  LWPT.Core.TStringArray;
begin
  SetLength(Result, 0);
end;

function TFactoryDriver.ExecutableName: string;
begin
  Result := 'host-driver';
end;

function TFactoryDriver.ClassifyFailure(const AExitCode: Integer;
  const ARawOutput: string): TLWPTCompilerFailure;
begin
  Result := Default(TLWPTCompilerFailure);
end;

function TFactoryDriver.NormalizeResult(const ARequest: TLWPTBuildRequest;
  const AExitCode: Integer; const ARawOutput: string): TLWPTBuildResult;
begin
  Result := DefaultBuildResult;
  Result.Success := AExitCode = 0;
end;

constructor TFactoryOwner.Create;
begin
  inherited Create;
  CompilerIdentity := 'embedded';
  VersionIdentity := '1.2.3';
end;

function TFactoryOwner.CreateDriver(const AProfile: TLWPTCompilerProfile;
  const AProjectRoot: string): TLWPTCompilerDriver;
begin
  Result := TFactoryDriver.Create(Self, CompilerIdentity, VersionIdentity);
end;

function TLWPTCompilerRegistryTests.Profile(const AName,
  AExecutable: string): TLWPTCompilerProfile;
begin
  Result := Default(TLWPTCompilerProfile);
  Result.Name := AName;
  Result.Driver := 'fpc';
  Result.Executable := AExecutable;
  Result.VersionConstraint := '*';
end;

procedure TLWPTCompilerRegistryTests.BeforeAll;
begin
  FFactoryOwner := TFactoryOwner.Create;
end;

procedure TLWPTCompilerRegistryTests.AfterAll;
begin
  FFactoryOwner.Free;
end;

procedure TLWPTCompilerRegistryTests.TestSelectionPrecedence;
var
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'project';
  SetLength(Manifest.CompilerProfiles, 2);
  Manifest.CompilerProfiles[0] := Profile('project', 'project-fpc');
  Manifest.CompilerProfiles[1] := Profile('entry', 'entry-fpc');
  Host := TLWPTCompilerHost.Create;
  try
    Host.DefaultProfile := 'embedded';
    Host.RegisterFactory('embedded', FFactoryOwner.CreateDriver);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Expect<string>(Selection.DriverFor('').ExecutableName)
        .ToBe(ExpandFileName('project-fpc'));
      Expect<string>(Selection.DriverFor('entry').ExecutableName)
        .ToBe(ExpandFileName('entry-fpc'));
    finally
      Selection.Free;
    end;
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestHostDefaultPrecedesBuiltIn;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TLWPTCompilerDriver;
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  FFactoryOwner.CompilerIdentity := 'EMBEDDED';
  Manifest := Default(TManifest);
  Host := TLWPTCompilerHost.Create;
  try
    Host.DefaultProfile := 'embedded';
    Host.RegisterFactory('embedded', FFactoryOwner.CreateDriver);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Driver := Selection.DriverFor('');
      Expect<string>(Driver.ExecutableName).ToBe('host-driver');
      Capabilities := Driver.ProbeCapabilities(Default(TLWPTTarget));
      Expect<string>(Capabilities.CompilerID).ToBe('EMBEDDED');
    finally
      Selection.Free;
    end;
  finally
    Host.Free;
    FFactoryOwner.CompilerIdentity := 'embedded';
  end;
end;

procedure TLWPTCompilerRegistryTests.TestFactoryIdentityMismatchIsFreedAndRejected;
var
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Raised: Boolean;
  Selection: TLWPTCompilerSelection;
begin
  FFactoryOwner.CompilerIdentity := 'wrong';
  FFactoryOwner.DestroyCount := 0;
  Manifest := Default(TManifest);
  Host := TLWPTCompilerHost.Create;
  try
    Host.DefaultProfile := 'embedded';
    Host.RegisterFactory('embedded', FFactoryOwner.CreateDriver);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Raised := False;
      try
        Selection.DriverFor('');
      except
        on E: ELWPTCompilerDriverError do
          Raised := Pos('returned driver identity "wrong"', E.Message) > 0;
      end;
      Expect<Boolean>(Raised).ToBe(True);
      Expect<Integer>(FFactoryOwner.DestroyCount).ToBe(1);
    finally
      Selection.Free;
    end;
  finally
    Host.Free;
    FFactoryOwner.CompilerIdentity := 'embedded';
  end;
end;

procedure TLWPTCompilerRegistryTests.TestFactoryVersionMismatchIsRejected;
var
  Driver: TLWPTCompilerDriver;
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Raised: Boolean;
  Selection: TLWPTCompilerSelection;
begin
  FFactoryOwner.DestroyCount := 0;
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'embedded-profile';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Default(TLWPTCompilerProfile);
  Manifest.CompilerProfiles[0].Name := 'embedded-profile';
  Manifest.CompilerProfiles[0].Driver := 'embedded';
  Manifest.CompilerProfiles[0].VersionConstraint := '>=2.0.0';
  Host := TLWPTCompilerHost.Create;
  try
    Host.RegisterFactory('embedded', FFactoryOwner.CreateDriver);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Driver := Selection.DriverFor('');
      Raised := False;
      try
        Driver.ProbeCapabilities(Default(TLWPTTarget));
      except
        on E: ELWPTCompilerDriverError do
          Raised := Pos('does not satisfy configured version', E.Message) > 0;
      end;
      Expect<Boolean>(Raised).ToBe(True);
    finally
      Selection.Free;
    end;
    Expect<Integer>(FFactoryOwner.DestroyCount).ToBe(1);
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestFactoryDriverIsFreedExactlyOnce;
var
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  FFactoryOwner.DestroyCount := 0;
  Manifest := Default(TManifest);
  Host := TLWPTCompilerHost.Create;
  try
    Host.DefaultProfile := 'embedded';
    Host.RegisterFactory('embedded', FFactoryOwner.CreateDriver);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    Selection.DriverFor('');
    Selection.Free;
    Expect<Integer>(FFactoryOwner.DestroyCount).ToBe(1);
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestLakonProfileSelectsBuiltInAdapter;
var
  Driver: TLWPTCompilerDriver;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'wasm';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Default(TLWPTCompilerProfile);
  Manifest.CompilerProfiles[0].Name := 'wasm';
  Manifest.CompilerProfiles[0].Driver := LAKON_COMPILER_ID;
  Manifest.CompilerProfiles[0].Executable := 'tools/lakon';
  Manifest.CompilerProfiles[0].VersionConstraint :=
    '>=' + LAKON_MINIMUM_VERSION;
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Driver := Selection.DriverFor('');
    Expect<string>(Driver.CompilerID).ToBe(LAKON_COMPILER_ID);
    Expect<string>(Driver.ExecutableName)
      .ToBe(ExpandFileName('tools/lakon'));
    Expect<string>(Driver.VersionConstraint)
      .ToBe('>=' + LAKON_MINIMUM_VERSION);
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.
  TestLakonEmbeddingFactoryReplacesAdapterAndFPCDefault;
var
  Driver: TLWPTCompilerDriver;
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  FFactoryOwner.CompilerIdentity := LAKON_COMPILER_ID;
  FFactoryOwner.DestroyCount := 0;
  Manifest := Default(TManifest);
  Host := TLWPTCompilerHost.Create;
  try
    Host.DefaultProfile := LAKON_COMPILER_ID;
    Host.RegisterFactory(LAKON_COMPILER_ID, FFactoryOwner.CreateDriver);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Driver := Selection.DriverFor('');
      Expect<string>(Driver.CompilerID).ToBe(LAKON_COMPILER_ID);
      Expect<string>(Driver.ExecutableName).ToBe('host-driver');
    finally
      Selection.Free;
    end;
    Expect<Integer>(FFactoryOwner.DestroyCount).ToBe(1);
  finally
    Host.Free;
    FFactoryOwner.CompilerIdentity := 'embedded';
  end;
end;

procedure TLWPTCompilerRegistryTests.TestLakonBuiltInRejectsScripts;
var
  Manifest: TManifest;
  Raised: Boolean;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'wasm';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Default(TLWPTCompilerProfile);
  Manifest.CompilerProfiles[0].Name := 'wasm';
  Manifest.CompilerProfiles[0].Driver := LAKON_COMPILER_ID;
  Manifest.CompilerProfiles[0].Script := 'tools/lakon-driver.pas';
  Manifest.CompilerProfiles[0].VersionConstraint := '*';
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Raised := False;
    try
      Selection.DriverFor('');
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('cannot use script with built-in "lakon"',
          E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestBuiltInFallback;
var
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Expect<string>(Selection.DriverFor('').CompilerID).ToBe('fpc');
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestDriversAreCachedByProfile;
var
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Expect<Boolean>(Selection.DriverFor('') = Selection.DriverFor(''))
      .ToBe(True);
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestProfileCacheIsCaseInsensitive;
var
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Profile('Mixed', 'mixed-fpc');
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Expect<Boolean>(Selection.DriverFor('mixed') = Selection.DriverFor('MIXED'))
      .ToBe(True);
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.SetupTests;
begin
  Test('build entry overrides project and embedding defaults',
    TestSelectionPrecedence);
  Test('embedding default overrides the built-in fallback',
    TestHostDefaultPrecedesBuiltIn);
  Test('FPC is the built-in fallback', TestBuiltInFallback);
  Test('one invocation caches one driver per profile',
    TestDriversAreCachedByProfile);
  Test('profile resolution and caching are case-insensitive',
    TestProfileCacheIsCaseInsensitive);
  Test('factory identity mismatch is freed and rejected',
    TestFactoryIdentityMismatchIsFreedAndRejected);
  Test('factory version constraint is enforced independently',
    TestFactoryVersionMismatchIsRejected);
  Test('selection frees a factory driver exactly once',
    TestFactoryDriverIsFreedExactlyOnce);
  Test('Lakon profiles select the built-in CLI adapter',
    TestLakonProfileSelectsBuiltInAdapter);
  Test('a Lakon embedding factory replaces the adapter and FPC default',
    TestLakonEmbeddingFactoryReplacesAdapterAndFPCDefault);
  Test('Lakon built-in profiles reject external scripts',
    TestLakonBuiltInRejectsScripts);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTCompilerRegistryTests.Create(
    'compiler registry'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
