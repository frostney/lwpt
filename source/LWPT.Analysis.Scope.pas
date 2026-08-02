{ LWPT.Analysis.Scope — effective root/workspace source ownership. }
unit LWPT.Analysis.Scope;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.Core;

type
  TLWPTAnalysisConfiguration = record
    Includes: TStringArray;
    Excludes: TStringArray;
  end;

  TLWPTAnalysisFile = record
    ProjectName: string;
    AbsolutePath: string;
    ProjectRelativePath: string;
    RootRelativePath: string;
  end;
  TLWPTAnalysisFileArray = array of TLWPTAnalysisFile;

  TLWPTAnalysisProject = record
    Name: string;
    Version: string;
    Root: string;
    ManifestPath: string;
    Configuration: TLWPTAnalysisConfiguration;
    Files: TLWPTAnalysisFileArray;
  end;
  TLWPTAnalysisProjectArray = array of TLWPTAnalysisProject;

  TLWPTAnalysisScope = record
    Root: string;
    ManifestPath: string;
    ProjectName: string;
    ProjectVersion: string;
    Projects: TLWPTAnalysisProjectArray;
    Files: TLWPTAnalysisFileArray;
  end;

function ResolveAnalysisScope(const AManifestPath: string):
  TLWPTAnalysisScope;
function IsPascalAnalysisSource(const APath: string): Boolean;

implementation

uses
  Classes,
  SysUtils,

  LWPT.Manifest;

function IsPascalAnalysisSource(const APath: string): Boolean;
var
  Extension: string;
begin
  Extension := LowerCase(ExtractFileExt(APath));
  Result := (Extension = '.pas') or (Extension = '.pp')
    or (Extension = '.inc') or (Extension = '.dpr')
    or (Extension = '.lpr');
end;

function CanonicalRelativePath(const ARoot, APath: string): string;
begin
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(
    ExpandFileName(ARoot)), ExpandFileName(APath));
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  if Copy(Result, 1, 2) = './' then Delete(Result, 1, 2);
end;

function CopyStrings(const AValues: TStringArray): TStringArray;
begin
  Result := Copy(AValues, 0, Length(AValues));
end;

function EffectiveConfiguration(const ARoot, AProject: TManifest;
  const AIsRoot: Boolean): TLWPTAnalysisConfiguration;
begin
  Result := Default(TLWPTAnalysisConfiguration);
  if AIsRoot or AProject.AnalysisConfigured then
  begin
    Result.Includes := CopyStrings(AProject.AnalysisIncludes);
    Result.Excludes := CopyStrings(AProject.AnalysisExcludes);
  end
  else
  begin
    Result.Includes := CopyStrings(ARoot.AnalysisIncludes);
    Result.Excludes := CopyStrings(ARoot.AnalysisExcludes);
  end;
end;

function PatternHasGlob(const APattern: string): Boolean;
begin
  Result := (Pos('*', APattern) > 0) or (Pos('?', APattern) > 0);
end;

function IsAbsoluteFilesystemPath(const APath: string): Boolean;
begin
  Result := (APath <> '') and ((APath[1] = '/') or (APath[1] = '\'));
  if not Result then
    Result := (Length(APath) >= 3) and (APath[1] in ['A'..'Z', 'a'..'z'])
      and (APath[2] = ':') and (APath[3] in ['/', '\']);
end;

function PatternMatches(const ARelativePath, APattern: string): Boolean;
var
  CleanPattern: string;
begin
  CleanPattern := StringReplace(APattern, '\', '/', [rfReplaceAll]);
  while (Length(CleanPattern) > 0)
    and (CleanPattern[Length(CleanPattern)] = '/') do
    Delete(CleanPattern, Length(CleanPattern), 1);
  if CleanPattern = '' then Exit(False);
  if MatchPathGlob(ARelativePath, CleanPattern) then Exit(True);
  Result := not PatternHasGlob(CleanPattern)
    and (Copy(ARelativePath, 1, Length(CleanPattern) + 1)
      = CleanPattern + '/');
end;

function MatchesAny(const ARelativePath: string;
  const APatterns: TStringArray): Boolean;
var
  PatternIndex: Integer;
begin
  for PatternIndex := 0 to High(APatterns) do
    if PatternMatches(ARelativePath, APatterns[PatternIndex]) then
      Exit(True);
  Result := False;
end;

function PathIsSeeded(const AManifest: TManifest;
  const AProjectRoot, AAbsolutePath: string): Boolean;
var
  EntryIndex, UnitIndex: Integer;
  SeedPath: string;
begin
  for UnitIndex := 0 to High(AManifest.Units) do
  begin
    SeedPath := AManifest.Units[UnitIndex];
    if not IsAbsoluteFilesystemPath(SeedPath) then
      SeedPath := IncludeTrailingPathDelimiter(AProjectRoot) + SeedPath;
    SeedPath := ExpandFileName(SeedPath);
    if (AAbsolutePath = SeedPath) or PathContains(SeedPath, AAbsolutePath) then
      Exit(True);
  end;
  for EntryIndex := 0 to High(AManifest.BuildEntries) do
  begin
    SeedPath := AManifest.BuildEntries[EntryIndex].Source;
    if not IsAbsoluteFilesystemPath(SeedPath) then
      SeedPath := IncludeTrailingPathDelimiter(AProjectRoot) + SeedPath;
    SeedPath := ExpandFileName(SeedPath);
    if AAbsolutePath = SeedPath then Exit(True);
  end;
  Result := False;
end;

function OwnedByWorkspace(const AAbsolutePath: string;
  const AWorkspaces: TWorkspaceArray): Boolean;
var
  WorkspaceIndex: Integer;
  WorkspaceRoot: string;
begin
  for WorkspaceIndex := 0 to High(AWorkspaces) do
  begin
    WorkspaceRoot := ExpandFileName(AWorkspaces[WorkspaceIndex].Path);
    if (AAbsolutePath = WorkspaceRoot)
      or PathContains(WorkspaceRoot, AAbsolutePath) then
      Exit(True);
  end;
  Result := False;
end;

procedure SortFiles(var AFiles: TLWPTAnalysisFileArray);
var
  FileIndex, OtherIndex: Integer;
  Temporary: TLWPTAnalysisFile;
begin
  for FileIndex := 0 to High(AFiles) do
    for OtherIndex := FileIndex + 1 to High(AFiles) do
      if AFiles[OtherIndex].RootRelativePath
        < AFiles[FileIndex].RootRelativePath then
      begin
        Temporary := AFiles[FileIndex];
        AFiles[FileIndex] := AFiles[OtherIndex];
        AFiles[OtherIndex] := Temporary;
      end;
end;

procedure AddFile(var AFiles: TLWPTAnalysisFileArray;
  const AProjectName, AProjectRoot, ARoot, AAbsolutePath: string);
var
  FileCount: Integer;
begin
  FileCount := Length(AFiles);
  SetLength(AFiles, FileCount + 1);
  AFiles[FileCount].ProjectName := AProjectName;
  AFiles[FileCount].AbsolutePath := ExpandFileName(AAbsolutePath);
  AFiles[FileCount].ProjectRelativePath := CanonicalRelativePath(
    AProjectRoot, AAbsolutePath);
  AFiles[FileCount].RootRelativePath := CanonicalRelativePath(ARoot,
    AAbsolutePath);
end;

procedure CollectProjectFiles(const AProjectManifest: TManifest;
  const AProjectRoot, ARoot: string; const AConfiguration:
  TLWPTAnalysisConfiguration; var AFiles: TLWPTAnalysisFileArray);

  procedure Walk(const ADirectory: string);
  var
    AbsolutePath, RelativePath: string;
    Search: TSearchRec;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
      faAnyFile, Search) <> 0 then Exit;
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        if (Length(Search.Name) > 0) and (Search.Name[1] = '.') then Continue;
        AbsolutePath := IncludeTrailingPathDelimiter(ADirectory)
          + Search.Name;
        if (Search.Attr and faDirectory) <> 0 then
        begin
          if IsDirSymlinkOrJunction(AbsolutePath) then Continue;
          Walk(AbsolutePath);
          Continue;
        end;
        if (Search.Attr and faSymLink) <> 0 then Continue;
        if not IsPascalAnalysisSource(AbsolutePath) then Continue;
        if OwnedByWorkspace(AbsolutePath, AProjectManifest.Workspaces) then
          Continue;
        RelativePath := CanonicalRelativePath(AProjectRoot, AbsolutePath);
        if not PathIsSeeded(AProjectManifest, AProjectRoot, AbsolutePath)
          and not MatchesAny(RelativePath, AConfiguration.Includes) then
          Continue;
        if MatchesAny(RelativePath, AConfiguration.Excludes) then Continue;
        AddFile(AFiles, AProjectManifest.Name, AProjectRoot, ARoot,
          AbsolutePath);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  end;

begin
  SetLength(AFiles, 0);
  Walk(AProjectRoot);
  SortFiles(AFiles);
end;

procedure AppendFiles(var ADestination: TLWPTAnalysisFileArray;
  const ASource: TLWPTAnalysisFileArray);
var
  DestinationCount, SourceIndex: Integer;
begin
  DestinationCount := Length(ADestination);
  SetLength(ADestination, DestinationCount + Length(ASource));
  for SourceIndex := 0 to High(ASource) do
    ADestination[DestinationCount + SourceIndex] := ASource[SourceIndex];
end;

procedure ApplyDeepestProjectOwnership(var AScope: TLWPTAnalysisScope);
var
  CandidateIndex, FileIndex, KeepCount, OwnerIndex, ProjectIndex: Integer;
  CandidateRoot, FilePath, OwnerRoot: string;
begin
  SetLength(AScope.Files, 0);
  for ProjectIndex := 0 to High(AScope.Projects) do
  begin
    KeepCount := 0;
    for FileIndex := 0 to High(AScope.Projects[ProjectIndex].Files) do
    begin
      FilePath := AScope.Projects[ProjectIndex].Files[FileIndex].AbsolutePath;
      OwnerIndex := ProjectIndex;
      OwnerRoot := ExpandFileName(AScope.Projects[OwnerIndex].Root);
      for CandidateIndex := 0 to High(AScope.Projects) do
      begin
        CandidateRoot := ExpandFileName(AScope.Projects[CandidateIndex].Root);
        if (Length(CandidateRoot) > Length(OwnerRoot))
          and ((FilePath = CandidateRoot)
            or PathContains(CandidateRoot, FilePath)) then
        begin
          OwnerIndex := CandidateIndex;
          OwnerRoot := CandidateRoot;
        end;
      end;
      if OwnerIndex <> ProjectIndex then Continue;
      AScope.Projects[ProjectIndex].Files[KeepCount] :=
        AScope.Projects[ProjectIndex].Files[FileIndex];
      Inc(KeepCount);
    end;
    SetLength(AScope.Projects[ProjectIndex].Files, KeepCount);
    SortFiles(AScope.Projects[ProjectIndex].Files);
    AppendFiles(AScope.Files, AScope.Projects[ProjectIndex].Files);
  end;
  SortFiles(AScope.Files);
end;

function ResolveAnalysisScope(const AManifestPath: string):
  TLWPTAnalysisScope;
var
  Project: TLWPTAnalysisProject;
  ProjectCount: Integer;
  RootManifest: TManifest;
  VisitedManifests: TStringList;

  procedure AddProject(const AProjectManifest: TManifest;
    const AProjectRoot, AProjectManifestPath: string;
    const AIsRoot: Boolean);
  var
    ChildManifest: TManifest;
    CanonicalManifestPath: string;
    WorkspaceIndex: Integer;
    WorkspaceManifestPath, WorkspaceRoot: string;
  begin
    CanonicalManifestPath := ExpandFileName(AProjectManifestPath);
    if VisitedManifests.IndexOf(CanonicalManifestPath) >= 0 then Exit;
    VisitedManifests.Add(CanonicalManifestPath);
    Project := Default(TLWPTAnalysisProject);
    Project.Name := AProjectManifest.Name;
    Project.Version := AProjectManifest.Version;
    Project.Root := ExpandFileName(AProjectRoot);
    Project.ManifestPath := ExpandFileName(AProjectManifestPath);
    Project.Configuration := EffectiveConfiguration(RootManifest,
      AProjectManifest, AIsRoot);
    CollectProjectFiles(AProjectManifest, Project.Root, Result.Root,
      Project.Configuration, Project.Files);
    ProjectCount := Length(Result.Projects);
    SetLength(Result.Projects, ProjectCount + 1);
    Result.Projects[ProjectCount] := Project;
    for WorkspaceIndex := 0 to High(AProjectManifest.Workspaces) do
    begin
      WorkspaceRoot := ExpandFileName(
        AProjectManifest.Workspaces[WorkspaceIndex].Path);
      WorkspaceManifestPath := IncludeTrailingPathDelimiter(WorkspaceRoot)
        + MANIFEST_FILE;
      { A workspace is an analyzed project, not an untrusted dependency
        manifest. Project semantics expand supported build-source placeholders
        while AddProject still applies root analysis inheritance separately. }
      ChildManifest := LoadManifest(WorkspaceManifestPath);
      AddProject(ChildManifest, WorkspaceRoot, WorkspaceManifestPath, False);
    end;
  end;

begin
  Result := Default(TLWPTAnalysisScope);
  VisitedManifests := TStringList.Create;
  try
    Result.ManifestPath := ExpandFileName(AManifestPath);
    Result.Root := ExtractFileDir(Result.ManifestPath);
    RootManifest := LoadManifest(Result.ManifestPath);
    Result.ProjectName := RootManifest.Name;
    Result.ProjectVersion := RootManifest.Version;
    AddProject(RootManifest, Result.Root, Result.ManifestPath, True);
    ApplyDeepestProjectOwnership(Result);
  finally
    VisitedManifests.Free;
  end;
end;

end.
