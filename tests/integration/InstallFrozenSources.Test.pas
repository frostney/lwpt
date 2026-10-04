{ InstallFrozenSources.Test - `lwpt install --frozen` and `--offline`
  against local and workspace sources that changed after install (#370).

  A local or workspace module is a snapshot of a live source. Its committed
  tree under .lwpt/modules/ and its lwpt.lock computedHash agree with each
  other even when both are stale, so the frozen gate re-derives the snapshot
  from the source under the dependency's include/exclude policy and compares
  it with computedHash. Each test builds its own scratch project, installs it
  through the spawned binary, edits a source, and checks the gate's result
  and that nothing committed changed. }

program InstallFrozenSources.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TCommittedState = record
    LockfileBytes, ConfigurationBytes, ModulesTreeHash: string;
  end;

  TInstallFrozenSources = class(TTestSuite)
  private
    FOriginalDirectory, FScratch: string;
    procedure WritePackage(const ADirectory, AName, AManifestSuffix: string);
    function NewWorkspaceProject(const AName: string): string;
    function NewFilteredProject(const AName: string): string;
    procedure InstallOrFail(const ARoot, ALabel: string);
    function Snapshot(const ARoot: string): TCommittedState;
    procedure ExpectUnchanged(const ARoot: string;
      const ABefore: TCommittedState);
    procedure ExpectNoScratchLeft(const ARoot: string);
    function RunFrozen(const ARoot: string): TLwptResult;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestUnchangedWorkspacePasses;
    procedure TestEditedWorkspaceSourceFails;
    procedure TestAddedWorkspaceFileFails;
    procedure TestRemovedWorkspaceFileFails;
    procedure TestInstallRefreshesStaleWorkspace;
    procedure TestExcludedLocalEditPasses;
    procedure TestIncludedLocalEditFails;
    procedure TestMissingLocalSourceFails;
    procedure TestOfflineRefusesEditedWorkspace;
  end;

end;

procedure TInstallFrozenSources.WritePackage(const ADirectory, AName,
  AManifestSuffix: string);
begin
  ForceDirectories(ADirectory + '/source');
  WriteTextFile(ADirectory + '/source/' + AName + '.pas',
    'unit ' + StringReplace(AName, '-', '_', [rfReplaceAll]) + ';'#10
    + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  WriteTextFile(ADirectory + '/lwpt.toml',
    '[package]'#10 + 'name = "' + AName + '"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10 + AManifestSuffix);
end;

{ A root whose only dependency is the auto-discovered packages/shared. }
function TInstallFrozenSources.NewWorkspaceProject(
  const AName: string): string;
begin
  Result := FScratch + '/' + AName;
  WritePackage(Result, AName,
    '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  WritePackage(Result + '/packages/shared', 'shared', '');
  InstallOrFail(Result, AName);
end;

{ A root with an explicit local dependency outside the project whose
  docs/ directory is excluded from the installed snapshot. }
function TInstallFrozenSources.NewFilteredProject(
  const AName: string): string;
begin
  Result := FScratch + '/' + AName + '/root';
  WritePackage(Result, AName,
    '[dependencies]'#10
    + 'filtered = { source = "../filtered", exclude = ["docs/**"] }'#10);
  WritePackage(FScratch + '/' + AName + '/filtered', 'filtered', '');
  WriteTextFile(FScratch + '/' + AName + '/filtered/docs/notes.txt',
    'first');
  InstallOrFail(Result, AName);
end;

procedure TInstallFrozenSources.InstallOrFail(const ARoot, ALabel: string);
var Run: TLwptResult;
begin
  Run := RunLwpt(['install'], ARoot);
  DumpRunFailure(ALabel + ' install', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

function TInstallFrozenSources.Snapshot(
  const ARoot: string): TCommittedState;
begin
  Result.LockfileBytes := ReadBinaryFile(ARoot + '/lwpt.lock');
  Result.ConfigurationBytes := ReadBinaryFile(ARoot + '/lwpt.cfg');
  Result.ModulesTreeHash := HashTree(ARoot + '/.lwpt/modules');
end;

procedure TInstallFrozenSources.ExpectUnchanged(const ARoot: string;
  const ABefore: TCommittedState);
begin
  Expect<string>(ReadBinaryFile(ARoot + '/lwpt.lock'))
    .ToBe(ABefore.LockfileBytes);
  Expect<string>(ReadBinaryFile(ARoot + '/lwpt.cfg'))
    .ToBe(ABefore.ConfigurationBytes);
  Expect<string>(HashTree(ARoot + '/.lwpt/modules'))
    .ToBe(ABefore.ModulesTreeHash);
end;

{ The re-derived snapshot lives in private scratch that every path removes. }
procedure TInstallFrozenSources.ExpectNoScratchLeft(const ARoot: string);
var SR: TSearchRec; Leftover: string;
begin
  Leftover := '';
  if FindFirst(ARoot + '/.lwpt/tmp/*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
          Leftover := Leftover + ' ' + SR.Name;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  Expect<string>(Leftover).ToBe('');
end;

{ Every frozen run, passing or refused, removes its re-derivation scratch. }
function TInstallFrozenSources.RunFrozen(const ARoot: string): TLwptResult;
begin
  Result := RunLwpt(['install', '--frozen'], ARoot);
  ExpectNoScratchLeft(ARoot);
end;

procedure TInstallFrozenSources.BeforeAll;
begin
  FOriginalDirectory := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('install-frozen-sources');
end;

procedure TInstallFrozenSources.AfterAll;
begin
  SetCurrentDir(FOriginalDirectory);
end;

procedure TInstallFrozenSources.TestUnchangedWorkspacePasses;
var Root: string; Before: TCommittedState; Run: TLwptResult;
begin
  Root := NewWorkspaceProject('ws-clean');
  Before := Snapshot(Root);
  Run := RunFrozen(Root);
  DumpRunFailure('clean frozen', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestEditedWorkspaceSourceFails;
var Root, Combined: string; Before: TCommittedState; Run: TLwptResult;
begin
  Root := NewWorkspaceProject('ws-edited');
  Before := Snapshot(Root);
  WriteTextFile(Root + '/packages/shared/source/shared.pas',
    'unit shared;'#10 + 'interface'#10 + 'implementation'#10
    + '{ edited without lwpt install }'#10 + 'end.'#10);
  Run := RunFrozen(Root);
  Combined := Run.Stdout + Run.Stderr;
  DumpRunFailure('expected refusal', Run, 1);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('workspace package "shared" at packages/shared '
    + 'changed after it was installed', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('changed source/shared.pas', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('Run `lwpt install` and commit the updated '
    + 'lwpt.lock and .lwpt/modules/shared', Combined) > 0).ToBe(True);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestAddedWorkspaceFileFails;
var Root, Combined: string; Before: TCommittedState; Run: TLwptResult;
begin
  Root := NewWorkspaceProject('ws-added');
  Before := Snapshot(Root);
  WriteTextFile(Root + '/packages/shared/source/extra.pas',
    'unit extra;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  Run := RunFrozen(Root);
  Combined := Run.Stdout + Run.Stderr;
  DumpRunFailure('expected refusal', Run, 1);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('workspace package "shared"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('added source/extra.pas', Combined) > 0).ToBe(True);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestRemovedWorkspaceFileFails;
var Root, Combined: string; Before: TCommittedState; Run: TLwptResult;
begin
  Root := NewWorkspaceProject('ws-removed');
  Before := Snapshot(Root);
  Expect<Boolean>(DeleteFile(Root + '/packages/shared/source/shared.pas'))
    .ToBe(True);
  Run := RunFrozen(Root);
  Combined := Run.Stdout + Run.Stderr;
  DumpRunFailure('expected refusal', Run, 1);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('workspace package "shared"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('removed source/shared.pas', Combined) > 0)
    .ToBe(True);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestInstallRefreshesStaleWorkspace;
var Root: string; Run: TLwptResult;
begin
  { The remedy the diagnostic names restores a verifiable state. }
  Root := NewWorkspaceProject('ws-refresh');
  WriteTextFile(Root + '/packages/shared/source/extra.pas',
    'unit extra;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  Run := RunFrozen(Root);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  InstallOrFail(Root, 'ws-refresh again');
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/shared/source/extra.pas')).ToBe(True);
  Run := RunFrozen(Root);
  DumpRunFailure('refreshed frozen', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TInstallFrozenSources.TestExcludedLocalEditPasses;
var Root: string; Before: TCommittedState; Run: TLwptResult;
begin
  { The re-derived snapshot applies the same extraction policy as install:
    a change the policy excludes is not drift. }
  Root := NewFilteredProject('local-excluded');
  Expect<Boolean>(FileExists(Root + '/.lwpt/modules/filtered/docs/notes.txt'))
    .ToBe(False);
  Before := Snapshot(Root);
  WriteTextFile(FScratch + '/local-excluded/filtered/docs/notes.txt',
    'second');
  Run := RunFrozen(Root);
  DumpRunFailure('excluded edit frozen', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestIncludedLocalEditFails;
var Root, Combined: string; Before: TCommittedState; Run: TLwptResult;
begin
  Root := NewFilteredProject('local-included');
  Before := Snapshot(Root);
  WriteTextFile(FScratch + '/local-included/filtered/source/filtered.pas',
    'unit filtered;'#10 + 'interface'#10 + 'implementation'#10
    + '{ edited }'#10 + 'end.'#10);
  Run := RunFrozen(Root);
  Combined := Run.Stdout + Run.Stderr;
  DumpRunFailure('expected refusal', Run, 1);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('local dependency "filtered"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('changed source/filtered.pas', Combined) > 0)
    .ToBe(True);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestMissingLocalSourceFails;
var Root, Combined: string; Before: TCommittedState; Run: TLwptResult;
begin
  { Without its source a snapshot cannot be proven current; the gate fails
    closed rather than trusting the committed copy. }
  Root := NewFilteredProject('local-missing');
  Before := Snapshot(Root);
  RecursiveDelete(FScratch + '/local-missing/filtered');
  Run := RunFrozen(Root);
  Combined := Run.Stdout + Run.Stderr;
  DumpRunFailure('expected refusal', Run, 1);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('source of local dependency "filtered" is missing',
    Combined) > 0).ToBe(True);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.TestOfflineRefusesEditedWorkspace;
var Root, Combined: string; Before: TCommittedState; Run: TLwptResult;
begin
  { --offline re-copies a local source, so it cannot restore the locked
    snapshot from an edited one; it fails and publishes nothing. }
  Root := NewWorkspaceProject('ws-offline');
  Before := Snapshot(Root);
  WriteTextFile(Root + '/packages/shared/source/extra.pas',
    'unit extra;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  Run := RunLwpt(['install', '--offline'], Root);
  Combined := Run.Stdout + Run.Stderr;
  DumpRunFailure('expected refusal', Run, 1);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('[offline] tree hash mismatch for "shared"',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('source changed after it was installed', Combined) > 0)
    .ToBe(True);
  ExpectUnchanged(Root, Before);
end;

procedure TInstallFrozenSources.SetupTests;
begin
  Test('frozen accepts an unchanged workspace package',
    TestUnchangedWorkspacePasses);
  Test('frozen names a workspace package whose source file was edited',
    TestEditedWorkspaceSourceFails);
  Test('frozen names a file added to a workspace source',
    TestAddedWorkspaceFileFails);
  Test('frozen names a file removed from a workspace source',
    TestRemovedWorkspaceFileFails);
  Test('a plain install refreshes a stale workspace snapshot',
    TestInstallRefreshesStaleWorkspace);
  Test('frozen ignores edits the local extraction policy excludes',
    TestExcludedLocalEditPasses);
  Test('frozen names a local dependency whose included source changed',
    TestIncludedLocalEditFails);
  Test('frozen fails closed when a local source is missing',
    TestMissingLocalSourceFails);
  Test('offline refuses to restore from an edited workspace source',
    TestOfflineRefusesEditedWorkspace);
end;

begin
  TestRunnerProgram.AddSuite(TInstallFrozenSources.Create(
    'install --frozen: local and workspace source drift'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
