{ LWPT.CompilerRegistry — root profiles and embedding-host factories. }
unit LWPT.CompilerRegistry;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,

  LWPT.CompilerDriver,
  LWPT.Manifest;

type
  TLWPTCompilerDriverFactory = function(
    const AProfile: TLWPTCompilerProfile;
    const AProjectRoot: string): TLWPTCompilerDriver of object;

  TLWPTCompilerHost = class
  private
    type
      TFactoryEntry = record
        DriverID: string;
        Factory: TLWPTCompilerDriverFactory;
      end;
  private
    FDefaultProfile: string;
    FFactories: array of TFactoryEntry;
    function FindFactory(const ADriverID: string): Integer;
  public
    procedure RegisterFactory(const ADriverID: string;
      const AFactory: TLWPTCompilerDriverFactory);
    property DefaultProfile: string read FDefaultProfile write FDefaultProfile;
  end;

  TLWPTCompilerSelection = class
  private
    type
      TDriverEntry = class
      public
        ProfileName: string;
        Driver: TLWPTCompilerDriver;
        destructor Destroy; override;
      end;
  private
    FManifest: TManifest;
    FProjectRoot: string;
    FHost: TLWPTCompilerHost;
    FDrivers: TList;
    function CreateDriver(const AProfile: TLWPTCompilerProfile):
      TLWPTCompilerDriver;
    function FindManifestProfile(const AName: string;
      out AProfile: TLWPTCompilerProfile): Boolean;
    function ResolveProfileName(const ABuildEntryProfile: string): string;
  public
    constructor Create(const AManifest: TManifest;
      const AProjectRoot: string; const AHost: TLWPTCompilerHost = nil);
    destructor Destroy; override;
    function DriverFor(const ABuildEntryProfile: string):
      TLWPTCompilerDriver;
  end;

implementation

uses
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver.Blaise,
  LWPT.CompilerDriver.External,
  LWPT.CompilerDriver.FPC,
  LWPT.CompilerDriver.Lakon,
  LWPT.Core,
  Semver;

const
  IMPLICIT_FPC_PROFILE = FPC_COMPILER_ID;

type
  TLWPTConfiguredCompilerDriver = class(TLWPTCompilerDriver)
  private
    FCompilerID: string;
    FInner: TLWPTCompilerDriver;
    FVersionConstraint: string;
  public
    constructor Create(const ACompilerID, AVersionConstraint: string;
      const AInner: TLWPTCompilerDriver);
    destructor Destroy; override;
    function CompilerID: string; override;
    function VersionConstraint: string; override;
    function CreateBuildRequest(const ASource, AArtifact: string):
      LWPT.BuildRequest.TLWPTBuildRequest; override;
    function DefaultTarget: LWPT.BuildRequest.TLWPTTarget; override;
    function ProbeCapabilities(
      const ATarget: LWPT.BuildRequest.TLWPTTarget;
      const ARefresh: Boolean = False):
      LWPT.BuildRequest.TLWPTCompilerCapabilities; override;
    function BuildArguments(
      const ARequest: LWPT.BuildRequest.TLWPTBuildRequest;
      const AOptions: TLWPTCompilerInvocationOptions):
      LWPT.Core.TStringArray; override;
    function ExecutableName: string; override;
    function BuildStandardInput(
      const ARequest: LWPT.BuildRequest.TLWPTBuildRequest): string; override;
    function SeparateStandardError: Boolean; override;
    function CompilationTimeoutMilliseconds: QWord; override;
    function ClassifyFailure(const AExitCode: Integer;
      const ARawOutput: string): TLWPTCompilerFailure; override;
    function NormalizeResult(
      const ARequest: LWPT.BuildRequest.TLWPTBuildRequest;
      const AExitCode: Integer; const ARawOutput: string):
      LWPT.BuildRequest.TLWPTBuildResult; override;
    function NormalizeExecutionResult(
      const ARequest: LWPT.BuildRequest.TLWPTBuildRequest;
      const AExitCode: Integer; const AStandardOutput,
      AStandardError: string): LWPT.BuildRequest.TLWPTBuildResult; override;
    function DisplayOutput(const AStandardOutput,
      AStandardError: string): string; override;
  end;

constructor TLWPTConfiguredCompilerDriver.Create(const ACompilerID,
  AVersionConstraint: string; const AInner: TLWPTCompilerDriver);
begin
  inherited Create;
  FCompilerID := ACompilerID;
  FVersionConstraint := AVersionConstraint;
  FInner := AInner;
end;

destructor TLWPTConfiguredCompilerDriver.Destroy;
begin
  FInner.Free;
  inherited Destroy;
end;

function TLWPTConfiguredCompilerDriver.CompilerID: string;
begin
  Result := FCompilerID;
end;

function TLWPTConfiguredCompilerDriver.VersionConstraint: string;
begin
  Result := FVersionConstraint;
end;

function TLWPTConfiguredCompilerDriver.CreateBuildRequest(
  const ASource, AArtifact: string): LWPT.BuildRequest.TLWPTBuildRequest;
begin
  Result := FInner.CreateBuildRequest(ASource, AArtifact);
  Result.Compiler.ID := FCompilerID;
  Result.Compiler.VersionConstraint := FVersionConstraint;
  Result.Compiler.VersionIdentity := '';
end;

function TLWPTConfiguredCompilerDriver.DefaultTarget:
  LWPT.BuildRequest.TLWPTTarget;
begin
  Result := FInner.DefaultTarget;
end;

function TLWPTConfiguredCompilerDriver.ProbeCapabilities(
  const ATarget: LWPT.BuildRequest.TLWPTTarget; const ARefresh: Boolean):
  LWPT.BuildRequest.TLWPTCompilerCapabilities;
begin
  Result := FInner.ProbeCapabilities(ATarget, ARefresh);
  ValidateCompilerCapabilities(Result);
  if not SameText(Result.CompilerID, FCompilerID) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler factory "%s" returned capabilities for "%s"',
      [FCompilerID, Result.CompilerID]);
  if not Satisfies(Result.VersionIdentity, FVersionConstraint,
    DefaultSemverOptions) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler "%s" version "%s" does not satisfy configured version "%s"',
      [FCompilerID, Result.VersionIdentity, FVersionConstraint]);
end;

function TLWPTConfiguredCompilerDriver.BuildArguments(
  const ARequest: LWPT.BuildRequest.TLWPTBuildRequest;
  const AOptions: TLWPTCompilerInvocationOptions): LWPT.Core.TStringArray;
begin
  Result := FInner.BuildArguments(ARequest, AOptions);
end;

function TLWPTConfiguredCompilerDriver.ExecutableName: string;
begin
  Result := FInner.ExecutableName;
end;

function TLWPTConfiguredCompilerDriver.BuildStandardInput(
  const ARequest: LWPT.BuildRequest.TLWPTBuildRequest): string;
begin
  Result := FInner.BuildStandardInput(ARequest);
end;

function TLWPTConfiguredCompilerDriver.SeparateStandardError: Boolean;
begin
  Result := FInner.SeparateStandardError;
end;

function TLWPTConfiguredCompilerDriver.CompilationTimeoutMilliseconds: QWord;
begin
  Result := FInner.CompilationTimeoutMilliseconds;
end;

function TLWPTConfiguredCompilerDriver.ClassifyFailure(
  const AExitCode: Integer; const ARawOutput: string): TLWPTCompilerFailure;
begin
  Result := FInner.ClassifyFailure(AExitCode, ARawOutput);
end;

function TLWPTConfiguredCompilerDriver.NormalizeResult(
  const ARequest: LWPT.BuildRequest.TLWPTBuildRequest;
  const AExitCode: Integer; const ARawOutput: string):
  LWPT.BuildRequest.TLWPTBuildResult;
begin
  Result := FInner.NormalizeResult(ARequest, AExitCode, ARawOutput);
end;

function TLWPTConfiguredCompilerDriver.NormalizeExecutionResult(
  const ARequest: LWPT.BuildRequest.TLWPTBuildRequest;
  const AExitCode: Integer; const AStandardOutput,
  AStandardError: string): LWPT.BuildRequest.TLWPTBuildResult;
begin
  Result := FInner.NormalizeExecutionResult(ARequest, AExitCode,
    AStandardOutput, AStandardError);
end;

function TLWPTConfiguredCompilerDriver.DisplayOutput(
  const AStandardOutput, AStandardError: string): string;
begin
  Result := FInner.DisplayOutput(AStandardOutput, AStandardError);
end;

function IsAbsoluteFilesystemPath(const APath: string): Boolean; inline;
begin
  Result := False;
  if APath = '' then Exit;
  if APath[1] in ['/', '\'] then Exit(True);
  if (Length(APath) >= 3) and (APath[2] = ':')
     and (APath[3] in ['/', '\']) then
    Exit(True);
end;

function TLWPTCompilerHost.FindFactory(const ADriverID: string): Integer;
begin
  for Result := 0 to High(FFactories) do
    if SameText(FFactories[Result].DriverID, ADriverID) then Exit;
  Result := -1;
end;

procedure TLWPTCompilerHost.RegisterFactory(const ADriverID: string;
  const AFactory: TLWPTCompilerDriverFactory);
var
  Index: Integer;
begin
  if Trim(ADriverID) = '' then
    raise ELWPTCompilerDriverError.Create(
      'embedding compiler factory ID must not be empty');
  if not Assigned(AFactory) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'embedding compiler factory "%s" is not assigned', [ADriverID]);
  if SameText(ADriverID, FPC_COMPILER_ID)
     or SameText(ADriverID, BLAISE_COMPILER_ID) then
    raise ELWPTCompilerDriverError.Create(
      'embedding compiler factories cannot shadow built-in "'
      + LowerCase(ADriverID) + '"');
  Index := FindFactory(ADriverID);
  if Index >= 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'embedding compiler factory "%s" is already registered',
      [ADriverID]);
  Index := Length(FFactories);
  SetLength(FFactories, Index + 1);
  FFactories[Index].DriverID := ADriverID;
  FFactories[Index].Factory := AFactory;
end;

destructor TLWPTCompilerSelection.TDriverEntry.Destroy;
begin
  Driver.Free;
  inherited Destroy;
end;

constructor TLWPTCompilerSelection.Create(const AManifest: TManifest;
  const AProjectRoot: string; const AHost: TLWPTCompilerHost);
begin
  inherited Create;
  FManifest := AManifest;
  FProjectRoot := ExpandFileName(AProjectRoot);
  FHost := AHost;
  FDrivers := TList.Create;
end;

destructor TLWPTCompilerSelection.Destroy;
var
  i: Integer;
begin
  for i := 0 to FDrivers.Count - 1 do TDriverEntry(FDrivers[i]).Free;
  FDrivers.Free;
  inherited Destroy;
end;

function TLWPTCompilerSelection.FindManifestProfile(const AName: string;
  out AProfile: TLWPTCompilerProfile): Boolean;
var
  i: Integer;
begin
  AProfile := Default(TLWPTCompilerProfile);
  for i := 0 to High(FManifest.CompilerProfiles) do
    if SameText(FManifest.CompilerProfiles[i].Name, AName) then
    begin
      AProfile := FManifest.CompilerProfiles[i];
      Exit(True);
    end;
  Result := False;
end;

function TLWPTCompilerSelection.ResolveProfileName(
  const ABuildEntryProfile: string): string;
begin
  if ABuildEntryProfile <> '' then Exit(ABuildEntryProfile);
  if FManifest.CompilerDefault <> '' then Exit(FManifest.CompilerDefault);
  if Assigned(FHost) and (FHost.DefaultProfile <> '') then
    Exit(FHost.DefaultProfile);
  Result := IMPLICIT_FPC_PROFILE;
end;

function ResolveConfiguredPath(const AProjectRoot, APath: string): string;
begin
  Result := APath;
  if APath = '' then Exit;
  if IsAbsoluteFilesystemPath(APath) then
    Result := ExpandFileName(APath)
  else
    Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjectRoot)
      + APath);
end;

function TLWPTCompilerSelection.CreateDriver(
  const AProfile: TLWPTCompilerProfile): TLWPTCompilerDriver;
var
  ExecutablePath, ScriptPath: string;
  FactoryIndex: Integer;
  FactoryDriver: TLWPTCompilerDriver;
  ResolvedProfile: TLWPTCompilerProfile;
begin
  ResolvedProfile := AProfile;
  ExecutablePath := ResolveConfiguredPath(FProjectRoot,
    AProfile.Executable);
  ScriptPath := ResolveConfiguredPath(FProjectRoot, AProfile.Script);
  ResolvedProfile.Executable := ExecutablePath;
  ResolvedProfile.Script := ScriptPath;

  if SameText(AProfile.Driver, FPC_COMPILER_ID) then
  begin
    if ScriptPath <> '' then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler profile "%s" cannot use script with built-in "fpc"',
        [AProfile.Name]);
    Exit(TLWPTFPCCompilerDriver.Create(ExecutablePath,
      AProfile.VersionConstraint));
  end;

  if SameText(AProfile.Driver, BLAISE_COMPILER_ID) then
  begin
    if ScriptPath <> '' then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler profile "%s" cannot use script with built-in "blaise"',
        [AProfile.Name]);
    Exit(TLWPTBlaiseCompilerDriver.Create(ExecutablePath,
      AProfile.VersionConstraint));
  end;

  FactoryIndex := -1;
  if Assigned(FHost) then FactoryIndex := FHost.FindFactory(AProfile.Driver);
  if FactoryIndex >= 0 then
  begin
    FactoryDriver := FHost.FFactories[FactoryIndex].Factory(ResolvedProfile,
      FProjectRoot);
    if not Assigned(FactoryDriver) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler factory "%s" returned no driver', [AProfile.Driver]);
    try
      if not SameText(FactoryDriver.CompilerID, AProfile.Driver) then
        raise ELWPTCompilerDriverError.CreateFmt(
          'compiler factory "%s" returned driver identity "%s"',
          [AProfile.Driver, FactoryDriver.CompilerID]);
      Result := TLWPTConfiguredCompilerDriver.Create(AProfile.Driver,
        AProfile.VersionConstraint, FactoryDriver);
      FactoryDriver := nil;
      Exit;
    finally
      FactoryDriver.Free;
    end;
  end;

  if SameText(AProfile.Driver, LAKON_COMPILER_ID) then
  begin
    if ScriptPath <> '' then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler profile "%s" cannot use script with built-in "%s"',
        [AProfile.Name, LAKON_COMPILER_ID]);
    Exit(TLWPTLakonCompilerDriver.Create(ExecutablePath,
      AProfile.VersionConstraint));
  end;

  if (ExecutablePath = '') and (ScriptPath = '') then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler profile "%s" selects unavailable driver "%s"',
      [AProfile.Name, AProfile.Driver]);
  if (ExecutablePath <> '') and not FileExists(ExecutablePath) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler profile "%s" executable not found at %s',
      [AProfile.Name, ExecutablePath]);
  if (ScriptPath <> '') and not FileExists(ScriptPath) then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler profile "%s" script not found at %s',
      [AProfile.Name, ScriptPath]);
  if ScriptPath <> '' then
    Result := TLWPTExternalCompilerDriver.Create(AProfile.Driver,
      InstantFPCExecutable, ScriptPath, AProfile.VersionConstraint)
  else
    Result := TLWPTExternalCompilerDriver.Create(AProfile.Driver,
      ExecutablePath, '', AProfile.VersionConstraint);
end;

function TLWPTCompilerSelection.DriverFor(
  const ABuildEntryProfile: string): TLWPTCompilerDriver;
var
  DriverEntry: TDriverEntry;
  Profile: TLWPTCompilerProfile;
  ProfileName: string;
  i: Integer;
begin
  ProfileName := ResolveProfileName(ABuildEntryProfile);
  for i := 0 to FDrivers.Count - 1 do
  begin
    DriverEntry := TDriverEntry(FDrivers[i]);
    if SameText(DriverEntry.ProfileName, ProfileName) then
      Exit(DriverEntry.Driver);
  end;

  if not FindManifestProfile(ProfileName, Profile) then
  begin
    Profile := Default(TLWPTCompilerProfile);
    Profile.Name := ProfileName;
    Profile.Driver := ProfileName;
    Profile.VersionConstraint := '*';
  end;
  DriverEntry := TDriverEntry.Create;
  try
    DriverEntry.ProfileName := ProfileName;
    DriverEntry.Driver := CreateDriver(Profile);
    if not Assigned(DriverEntry.Driver) then
      raise ELWPTCompilerDriverError.CreateFmt(
        'compiler factory "%s" returned no driver', [Profile.Driver]);
    FDrivers.Add(DriverEntry);
    Result := DriverEntry.Driver;
  except
    DriverEntry.Free;
    raise;
  end;
end;

end.
