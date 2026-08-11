{ LWPT.CompilerRegistry — root profiles and embedding-host commands. }
unit LWPT.CompilerRegistry;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,

  LWPT.CompilerDriver,
  LWPT.Manifest;

type
  TLWPTCompilerHost = class
  private
    type
      TCommandEntry = record
        DriverID: string;
        Runnable: TLWPTRunnableCommand;
        VersionConstraint: string;
      end;
  private
    FDefaultProfile: string;
    FCommands: array of TCommandEntry;
    function FindCommand(const ADriverID: string): Integer;
  public
    procedure RegisterCommand(const ADriverID, ACommand: string;
      const AArguments: array of string;
      const AVersionConstraint: string = '*';
      const ABindAsDefault: Boolean = False);
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

  LWPT.CompilerDriver.Blaise,
  LWPT.CompilerDriver.Delphi,
  LWPT.CompilerDriver.External,
  LWPT.CompilerDriver.FPC,
  LWPT.CompilerDriver.Lakon,
  LWPT.Core;

const
  IMPLICIT_FPC_PROFILE = FPC_COMPILER_ID;

function IsAbsoluteFilesystemPath(const APath: string): Boolean; inline;
begin
  Result := False;
  if APath = '' then Exit;
  if APath[1] in ['/', '\'] then Exit(True);
  if (Length(APath) >= 3) and (APath[2] = ':')
     and (APath[3] in ['/', '\']) then
    Exit(True);
end;

function TLWPTCompilerHost.FindCommand(const ADriverID: string): Integer;
begin
  for Result := 0 to High(FCommands) do
    if SameText(FCommands[Result].DriverID, ADriverID) then Exit;
  Result := -1;
end;

procedure TLWPTCompilerHost.RegisterCommand(const ADriverID,
  ACommand: string; const AArguments: array of string;
  const AVersionConstraint: string; const ABindAsDefault: Boolean);
var
  i, Index: Integer;
begin
  if Trim(ADriverID) = '' then
    raise ELWPTCompilerDriverError.Create(
      'embedding compiler command ID must not be empty');
  if Trim(ACommand) = '' then
    raise ELWPTCompilerDriverError.CreateFmt(
      'embedding compiler command "%s" must name a command', [ADriverID]);
  if Trim(AVersionConstraint) = '' then
    raise ELWPTCompilerDriverError.CreateFmt(
      'embedding compiler command "%s" version must not be empty',
      [ADriverID]);
  if SameText(ADriverID, FPC_COMPILER_ID)
     or SameText(ADriverID, BLAISE_COMPILER_ID)
     or SameText(ADriverID, DELPHI_COMPILER_ID) then
    raise ELWPTCompilerDriverError.Create(
      'embedding compiler commands cannot shadow built-in "'
      + LowerCase(ADriverID) + '"');
  Index := FindCommand(ADriverID);
  if Index >= 0 then
    raise ELWPTCompilerDriverError.CreateFmt(
      'embedding compiler command "%s" is already registered',
      [ADriverID]);
  Index := Length(FCommands);
  SetLength(FCommands, Index + 1);
  FCommands[Index].DriverID := ADriverID;
  FCommands[Index].Runnable.Command := ACommand;
  SetLength(FCommands[Index].Runnable.Args, Length(AArguments));
  for i := 0 to High(AArguments) do
    FCommands[Index].Runnable.Args[i] := AArguments[i];
  FCommands[Index].VersionConstraint := AVersionConstraint;
  if ABindAsDefault then FDefaultProfile := ADriverID;
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

function ResolveConfiguredCommand(const AProjectRoot, ACommand: string): string;
begin
  Result := ACommand;
  if ACommand = '' then Exit;
  if IsAbsoluteFilesystemPath(ACommand) then
    Result := ExpandFileName(ACommand)
  else if (Pos('/', ACommand) > 0) or (Pos('\', ACommand) > 0) then
    Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjectRoot)
      + ACommand);
end;

function TLWPTCompilerSelection.CreateDriver(
  const AProfile: TLWPTCompilerProfile): TLWPTCompilerDriver;
var
  CommandPath, VersionConstraint: string;
  CommandIndex: Integer;
begin
  CommandPath := ResolveConfiguredCommand(FProjectRoot,
    AProfile.Runnable.Command);

  CommandIndex := -1;
  if Assigned(FHost) then CommandIndex := FHost.FindCommand(AProfile.Driver);
  if (CommandIndex >= 0) and (CommandPath = '') then
  begin
    CommandPath := ResolveConfiguredCommand(FProjectRoot,
      FHost.FCommands[CommandIndex].Runnable.Command);
    VersionConstraint := AProfile.VersionConstraint;
    if VersionConstraint = '*' then
      VersionConstraint := FHost.FCommands[CommandIndex].VersionConstraint;
    Exit(TLWPTExternalCompilerDriver.Create(AProfile.Driver, CommandPath,
      FHost.FCommands[CommandIndex].Runnable.Args, VersionConstraint,
      FProjectRoot));
  end;

  if SameText(AProfile.Driver, FPC_COMPILER_ID) then
  begin
    Result := TLWPTFPCCompilerDriver.Create(CommandPath,
      AProfile.VersionConstraint);
    Result.ConfigureCommand('', AProfile.Runnable.Args,
      FProjectRoot);
    Exit;
  end;

  if SameText(AProfile.Driver, DELPHI_COMPILER_ID) then
  begin
    Result := TLWPTDelphiCompilerDriver.Create(CommandPath,
      AProfile.VersionConstraint);
    Result.ConfigureCommand('', AProfile.Runnable.Args,
      FProjectRoot);
    Exit;
  end;

  if SameText(AProfile.Driver, BLAISE_COMPILER_ID) then
  begin
    Result := TLWPTBlaiseCompilerDriver.Create(CommandPath,
      AProfile.VersionConstraint);
    Result.ConfigureCommand('', AProfile.Runnable.Args,
      FProjectRoot);
    Exit;
  end;

  if SameText(AProfile.Driver, LAKON_COMPILER_ID) then
  begin
    Result := TLWPTLakonCompilerDriver.Create(CommandPath,
      AProfile.VersionConstraint);
    Result.ConfigureCommand('', AProfile.Runnable.Args,
      FProjectRoot);
    Exit;
  end;

  if CommandPath = '' then
    raise ELWPTCompilerDriverError.CreateFmt(
      'compiler profile "%s" selects custom driver "%s" but does not '
      + 'declare required command',
      [AProfile.Name, AProfile.Driver]);
  Result := TLWPTExternalCompilerDriver.Create(AProfile.Driver,
    CommandPath, AProfile.Runnable.Args, AProfile.VersionConstraint,
    FProjectRoot);
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
        'compiler command "%s" returned no driver', [Profile.Driver]);
    FDrivers.Add(DriverEntry);
    Result := DriverEntry.Driver;
  except
    DriverEntry.Free;
    raise;
  end;
end;

end.
