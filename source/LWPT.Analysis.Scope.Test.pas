{ LWPT.Analysis.Scope.Test — root/workspace effective analysis scope. }
program LWPT.Analysis.Scope.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Analysis.Scope,
  LWPT.Core,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  TAnalysisScopeTests = class(TTestSuite)
  private
    FOverlapRoot, FRoot: string;
    procedure WriteText(const APath, AText: string);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestResolvesRootAndWorkspaceOwnership;
    procedure TestWorkspaceCanReplaceRootAnalysisConfiguration;
    procedure TestDeepestDiscoveredProjectOwnsOverlappingFiles;
    procedure TestAnalysisArraysAreStrict;
    procedure TestRecognizesSupportedPascalExtensions;
  end;

procedure TAnalysisScopeTests.WriteText(const APath, AText: string);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

procedure TAnalysisScopeTests.BeforeAll;
begin
  FRoot := ExpandFileName('build/tests/tmp/analysis-scope');
  ForceDirectories(FRoot);
  WriteText(FRoot + '/lwpt.toml',
    '[package]'#10'name = "root"'#10'version = "1.0.0"'#10
    + 'units = ["source"]'#10
    + '[build.root]'#10'source = "app/main.lpr"'#10
    + '[workspaces]'#10'include = ["packages/*"]'#10
    + '[analysis]'#10'include = ["tests/**/*.pas"]'#10
    + 'exclude = ["source/excluded.pas"]'#10);
  WriteText(FRoot + '/source/owned.pas', 'unit Owned; interface end.');
  WriteText(FRoot + '/source/excluded.pas', 'unit Excluded; interface end.');
  WriteText(FRoot + '/app/main.lpr', 'program Main; begin end.');
  WriteText(FRoot + '/tests/deep/extra.pas', 'unit Extra; interface end.');
  WriteText(FRoot + '/unowned.pas', 'unit Unowned; interface end.');

  WriteText(FRoot + '/packages/inherited/lwpt.toml',
    '[package]'#10'name = "inherited"'#10'version = "1.1.0"'#10
    + 'units = ["src"]'#10
    + '[build.tool]'#10'source = "app/{item.name}.lpr"'#10
    + '[workspaces]'#10'include = ["nested/*"]'#10);
  WriteText(FRoot + '/packages/inherited/app/tool.lpr',
    'program Tool; begin end.');
  WriteText(FRoot + '/packages/inherited/src/owned.pas',
    'unit ChildOwned; interface end.');
  WriteText(FRoot + '/packages/inherited/tests/deep/extra.pas',
    'unit ChildExtra; interface end.');
  WriteText(FRoot + '/packages/inherited/nested/leaf/lwpt.toml',
    '[package]'#10'name = "leaf"'#10'version = "1.1.1"'#10
    + 'units = ["src"]'#10);
  WriteText(FRoot + '/packages/inherited/nested/leaf/src/owned.pas',
    'unit LeafOwned; interface end.');
  WriteText(FRoot + '/packages/inherited/nested/leaf/tests/deep/extra.pas',
    'unit LeafExtra; interface end.');

  WriteText(FRoot + '/packages/override/lwpt.toml',
    '[package]'#10'name = "override"'#10'version = "1.2.0"'#10
    + 'units = ["src"]'#10
    + '[analysis]'#10'include = ["extras/**/*.inc"]'#10
    + 'exclude = ["src/skip.pas"]'#10);
  WriteText(FRoot + '/packages/override/src/owned.pas',
    'unit OverrideOwned; interface end.');
  WriteText(FRoot + '/packages/override/src/skip.pas',
    'unit Skip; interface end.');
  WriteText(FRoot + '/packages/override/extras/deep/more.inc',
    '{$define MORE}');

  FOverlapRoot := ExpandFileName('build/tests/tmp/analysis-scope-overlap');
  ForceDirectories(FOverlapRoot);
  WriteText(FOverlapRoot + '/lwpt.toml',
    '[package]'#10'name = "overlap-root"'#10'version = "1.0.0"'#10
    + 'units = ["."]'#10
    + '[workspaces]'#10'include = ["packages/**"]'#10);
  WriteText(FOverlapRoot + '/packages/parent/lwpt.toml',
    '[package]'#10'name = "overlap-parent"'#10'version = "1.0.0"'#10
    + 'units = ["."]'#10);
  WriteText(FOverlapRoot + '/packages/parent/src/parent.pas',
    'unit ParentOwned; interface end.');
  WriteText(FOverlapRoot + '/packages/parent/nested/leaf/lwpt.toml',
    '[package]'#10'name = "overlap-leaf"'#10'version = "1.0.0"'#10
    + 'units = ["src"]'#10);
  WriteText(FOverlapRoot + '/packages/parent/nested/leaf/src/deep.pas',
    'unit DeepOwned; interface end.');
end;

procedure TAnalysisScopeTests.TestResolvesRootAndWorkspaceOwnership;
var
  Scope: TLWPTAnalysisScope;
begin
  Scope := ResolveAnalysisScope(FRoot + '/lwpt.toml');
  Expect<string>(Scope.ProjectName).ToBe('root');
  Expect<string>(Scope.ProjectVersion).ToBe('1.0.0');
  Expect<Integer>(Length(Scope.Projects)).ToBe(4);
  Expect<Integer>(Length(Scope.Files)).ToBe(10);
  Expect<string>(Scope.Files[0].RootRelativePath).ToBe('app/main.lpr');
  Expect<string>(Scope.Files[1].RootRelativePath).ToBe(
    'packages/inherited/app/tool.lpr');
  Expect<string>(Scope.Files[2].RootRelativePath).ToBe(
    'packages/inherited/nested/leaf/src/owned.pas');
  Expect<string>(Scope.Files[3].RootRelativePath).ToBe(
    'packages/inherited/nested/leaf/tests/deep/extra.pas');
  Expect<string>(Scope.Files[4].RootRelativePath).ToBe(
    'packages/inherited/src/owned.pas');
  Expect<string>(Scope.Files[5].RootRelativePath).ToBe(
    'packages/inherited/tests/deep/extra.pas');
  Expect<string>(Scope.Files[6].RootRelativePath).ToBe(
    'packages/override/extras/deep/more.inc');
  Expect<string>(Scope.Files[7].RootRelativePath).ToBe(
    'packages/override/src/owned.pas');
  Expect<string>(Scope.Files[8].RootRelativePath).ToBe('source/owned.pas');
  Expect<string>(Scope.Files[9].RootRelativePath).ToBe(
    'tests/deep/extra.pas');
end;

procedure TAnalysisScopeTests.TestWorkspaceCanReplaceRootAnalysisConfiguration;
var
  Scope: TLWPTAnalysisScope;
begin
  Scope := ResolveAnalysisScope(FRoot + '/lwpt.toml');
  Expect<Boolean>(Scope.Projects[1].Configuration.Includes[0]
    = 'tests/**/*.pas').ToBe(True);
  Expect<Boolean>(Scope.Projects[2].Configuration.Includes[0]
    = 'tests/**/*.pas').ToBe(True);
  Expect<Boolean>(Scope.Projects[3].Configuration.Includes[0]
    = 'extras/**/*.inc').ToBe(True);
  Expect<Boolean>(Scope.Projects[3].Configuration.Excludes[0]
    = 'src/skip.pas').ToBe(True);
end;

procedure TAnalysisScopeTests.
  TestDeepestDiscoveredProjectOwnsOverlappingFiles;
const
  DEEP_PATH = 'packages/parent/nested/leaf/src/deep.pas';
var
  DeepFileCount, FileIndex, ProjectIndex: Integer;
  ParentHasDeepFile: Boolean;
  Scope: TLWPTAnalysisScope;
begin
  Scope := ResolveAnalysisScope(FOverlapRoot + '/lwpt.toml');
  Expect<Integer>(Length(Scope.Projects)).ToBe(3);
  DeepFileCount := 0;
  for FileIndex := 0 to High(Scope.Files) do
    if Scope.Files[FileIndex].RootRelativePath = DEEP_PATH then
    begin
      Inc(DeepFileCount);
      Expect<string>(Scope.Files[FileIndex].ProjectName).ToBe('overlap-leaf');
      Expect<string>(Scope.Files[FileIndex].ProjectRelativePath).ToBe(
        'src/deep.pas');
    end;
  Expect<Integer>(DeepFileCount).ToBe(1);

  ParentHasDeepFile := False;
  for ProjectIndex := 0 to High(Scope.Projects) do
    if Scope.Projects[ProjectIndex].Name = 'overlap-parent' then
      for FileIndex := 0 to High(Scope.Projects[ProjectIndex].Files) do
        if Scope.Projects[ProjectIndex].Files[FileIndex].RootRelativePath
          = DEEP_PATH then ParentHasDeepFile := True;
  Expect<Boolean>(ParentHasDeepFile).ToBe(False);
end;

procedure TAnalysisScopeTests.TestAnalysisArraysAreStrict;
var
  Raised: Boolean;
begin
  WriteText(FRoot + '/invalid.toml',
    '[package]'#10'name = "invalid"'#10'version = "1.0.0"'#10
    + '[analysis]'#10'include = ["source", 42]'#10);
  Raised := False;
  try
    LoadManifest(FRoot + '/invalid.toml');
  except
    on EManifestError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TAnalysisScopeTests.TestRecognizesSupportedPascalExtensions;
begin
  Expect<Boolean>(IsPascalAnalysisSource('x.PAS')).ToBe(True);
  Expect<Boolean>(IsPascalAnalysisSource('x.pp')).ToBe(True);
  Expect<Boolean>(IsPascalAnalysisSource('x.inc')).ToBe(True);
  Expect<Boolean>(IsPascalAnalysisSource('x.dpr')).ToBe(True);
  Expect<Boolean>(IsPascalAnalysisSource('x.lpr')).ToBe(True);
  Expect<Boolean>(IsPascalAnalysisSource('x.txt')).ToBe(False);
end;

procedure TAnalysisScopeTests.SetupTests;
begin
  Test('resolves root/workspace files with one owner each',
    TestResolvesRootAndWorkspaceOwnership);
  Test('workspace analysis config replaces inherited root defaults',
    TestWorkspaceCanReplaceRootAnalysisConfiguration);
  Test('assigns overlapping files to the deepest discovered project',
    TestDeepestDiscoveredProjectOwnsOverlappingFiles);
  Test('requires string arrays in analysis config', TestAnalysisArraysAreStrict);
  Test('recognizes the supported Pascal source extensions',
    TestRecognizesSupportedPascalExtensions);
end;

begin
  TestRunnerProgram.AddSuite(TAnalysisScopeTests.Create(
    PROJECT_NAME + '.Analysis.Scope'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
