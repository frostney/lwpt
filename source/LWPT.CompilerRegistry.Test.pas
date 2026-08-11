program LWPT.CompilerRegistry.Test;

{$I Shared.inc}
{$J-}

uses
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.CompilerDriver.Blaise,
  LWPT.CompilerDriver.Lakon,
  LWPT.CompilerRegistry,
  LWPT.Core,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  TLWPTCompilerRegistryTests = class(TTestSuite)
  private
    function Profile(const AName, ADriver, ACommand: string):
      TLWPTCompilerProfile;
  public
    procedure SetupTests; override;
    procedure TestSelectionPrecedence;
    procedure TestHostDefaultCommandPrecedesBuiltIn;
    procedure TestManifestProfileOverridesHostCommand;
    procedure TestBuiltInFallback;
    procedure TestDriversAreCachedByProfile;
    procedure TestProfileCacheIsCaseInsensitive;
    procedure TestCommandsCannotShadowBuiltInDrivers;
    procedure TestDuplicateHostCommandIsRejected;
    procedure TestLakonProfileSelectsBuiltInAdapter;
    procedure TestBlaiseProfileSelectsBuiltInDriver;
    procedure TestConfiguredArgumentsPrecedeAdapterArguments;
  end;

function TLWPTCompilerRegistryTests.Profile(const AName, ADriver,
  ACommand: string): TLWPTCompilerProfile;
begin
  Result := Default(TLWPTCompilerProfile);
  Result.Name := AName;
  Result.Driver := ADriver;
  Result.Runnable.Command := ACommand;
  Result.VersionConstraint := '*';
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
  Manifest.CompilerProfiles[0] := Profile('project', 'fpc', 'project-fpc');
  Manifest.CompilerProfiles[1] := Profile('entry', 'fpc', 'entry-fpc');
  Host := TLWPTCompilerHost.Create;
  try
    Host.RegisterCommand('embedded', ParamStr(0), [], '*', True);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Expect<string>(Selection.DriverFor('').ExecutableName)
        .ToBe('project-fpc');
      Expect<string>(Selection.DriverFor('entry').ExecutableName)
        .ToBe('entry-fpc');
    finally
      Selection.Free;
    end;
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestHostDefaultCommandPrecedesBuiltIn;
var
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Host := TLWPTCompilerHost.Create;
  try
    Host.RegisterCommand(LAKON_COMPILER_ID, ParamStr(0), ['compiler-proxy'],
      '^1.0.0', True);
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Expect<string>(Selection.DriverFor('').CompilerID)
        .ToBe(LAKON_COMPILER_ID);
      Expect<string>(Selection.DriverFor('').ExecutableName)
        .ToBe(ExpandFileName(ParamStr(0)));
      Expect<string>(Selection.DriverFor('').VersionConstraint)
        .ToBe('^1.0.0');
    finally
      Selection.Free;
    end;
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestManifestProfileOverridesHostCommand;
var
  Host: TLWPTCompilerHost;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'embedded-profile';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Profile('embedded-profile', 'embedded',
    'tools/project-driver');
  Host := TLWPTCompilerHost.Create;
  try
    Host.RegisterCommand('embedded', 'host-driver', [], '*');
    Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir, Host);
    try
      Expect<string>(Selection.DriverFor('').ExecutableName)
        .ToBe(ExpandFileName('tools/project-driver'));
    finally
      Selection.Free;
    end;
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestCommandsCannotShadowBuiltInDrivers;
var
  Host: TLWPTCompilerHost;

  procedure ExpectRejected(const ADriverID: string);
  var
    Raised: Boolean;
  begin
    Raised := False;
    try
      Host.RegisterCommand(ADriverID, ParamStr(0), []);
    except
      on ELWPTCompilerDriverError do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  end;

begin
  Host := TLWPTCompilerHost.Create;
  try
    ExpectRejected('fpc');
    ExpectRejected('DELPHI');
    ExpectRejected(BLAISE_COMPILER_ID);
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestDuplicateHostCommandIsRejected;
var
  Host: TLWPTCompilerHost;
  Raised: Boolean;
begin
  Host := TLWPTCompilerHost.Create;
  try
    Host.RegisterCommand('embedded', ParamStr(0), []);
    Raised := False;
    try
      Host.RegisterCommand('EMBEDDED', ParamStr(0), []);
    except
      on E: ELWPTCompilerDriverError do
        Raised := Pos('already registered', E.Message) > 0;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Host.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestLakonProfileSelectsBuiltInAdapter;
var
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'wasm';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Profile('wasm', LAKON_COMPILER_ID,
    'tools/lakon');
  Manifest.CompilerProfiles[0].VersionConstraint :=
    '>=' + LAKON_MINIMUM_VERSION;
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Expect<string>(Selection.DriverFor('').CompilerID)
      .ToBe(LAKON_COMPILER_ID);
    Expect<string>(Selection.DriverFor('').ExecutableName)
      .ToBe(ExpandFileName('tools/lakon'));
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.TestBlaiseProfileSelectsBuiltInDriver;
var
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'modern';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Profile('modern', BLAISE_COMPILER_ID,
    'tools/blaise');
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Expect<string>(Selection.DriverFor('').CompilerID)
      .ToBe(BLAISE_COMPILER_ID);
    Expect<string>(Selection.DriverFor('').ExecutableName)
      .ToBe(ExpandFileName('tools/blaise'));
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.
  TestConfiguredArgumentsPrecedeAdapterArguments;
var
  Arguments: TStringArray;
  Manifest: TManifest;
  Selection: TLWPTCompilerSelection;
  Target: TLWPTTarget;
begin
  Manifest := Default(TManifest);
  Manifest.CompilerDefault := 'wrapped';
  SetLength(Manifest.CompilerProfiles, 1);
  Manifest.CompilerProfiles[0] := Profile('wrapped', 'fpc', 'ccache');
  SetLength(Manifest.CompilerProfiles[0].Runnable.Args, 1);
  Manifest.CompilerProfiles[0].Runnable.Args[0] := 'fpc';
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Arguments := Selection.DriverFor('').InvocationArguments(['-iV']);
    Expect<Integer>(Length(Arguments)).ToBe(2);
    Expect<string>(Arguments[0]).ToBe('fpc');
    Expect<string>(Arguments[1]).ToBe('-iV');
  finally
    Selection.Free;
  end;

  Manifest.CompilerProfiles[0] := Profile('wrapped', 'delphi', 'ccache');
  SetLength(Manifest.CompilerProfiles[0].Runnable.Args, 1);
  Manifest.CompilerProfiles[0].Runnable.Args[0] := 'dcc64';
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Target := Selection.DriverFor('').DefaultTarget;
    Expect<string>(Target.OS).ToBe('win64');
    Expect<string>(Target.Architecture).ToBe('x86_64');
    Arguments := Selection.DriverFor('').InvocationArguments(['--version']);
    Expect<string>(Arguments[0]).ToBe('dcc64');
    Expect<string>(Arguments[1]).ToBe('--version');
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
  Manifest.CompilerProfiles[0] := Profile('Native', 'fpc', 'fpc');
  Selection := TLWPTCompilerSelection.Create(Manifest, GetCurrentDir);
  try
    Expect<Boolean>(Selection.DriverFor('native') =
      Selection.DriverFor('NATIVE')).ToBe(True);
  finally
    Selection.Free;
  end;
end;

procedure TLWPTCompilerRegistryTests.SetupTests;
begin
  Test('project and entry profiles precede host default',
    TestSelectionPrecedence);
  Test('host default command precedes implicit FPC',
    TestHostDefaultCommandPrecedesBuiltIn);
  Test('manifest command overrides host command for the same driver',
    TestManifestProfileOverridesHostCommand);
  Test('implicit FPC is the final fallback', TestBuiltInFallback);
  Test('drivers are cached by profile', TestDriversAreCachedByProfile);
  Test('profile cache is case-insensitive', TestProfileCacheIsCaseInsensitive);
  Test('host commands cannot shadow built-in drivers',
    TestCommandsCannotShadowBuiltInDrivers);
  Test('duplicate host command registration is rejected',
    TestDuplicateHostCommandIsRejected);
  Test('Lakon profile selects the built-in adapter',
    TestLakonProfileSelectsBuiltInAdapter);
  Test('Blaise profile selects the built-in adapter',
    TestBlaiseProfileSelectsBuiltInDriver);
  Test('configured compiler arguments precede adapter arguments',
    TestConfiguredArgumentsPrecedeAdapterArguments);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTCompilerRegistryTests.Create(
    'compiler registry'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
