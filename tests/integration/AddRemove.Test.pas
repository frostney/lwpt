{ AddRemove.Test — pins `lwpt add` / `lwpt remove` semantics (ADR-0019).

  Offline by design: the scratch project's dependency is a local path
  (vendor/leaf inside the project), so the install transaction never
  touches the network. Each test gets a FRESH scratch project
  (BeforeEach) and runs its own preconditions, so the cases are
  order-independent. The contract under test:

    add:
      1. Writes `name = "<spec>"` into [dependencies] (creating the
         section), preserves unrelated manifest lines, installs the
         dep, and records it in lwpt.lock.
      2. Re-adding the same name updates the entry in place.
      3. A failing install (nonexistent local path) leaves lwpt.toml
         byte-identical — install-before-write ordering.
      4. A URL source without --name is rejected before any work.
      5. A dep declared as a [dependencies.<name>] dotted table is a
         hard error ("edit manually"), never a duplicate insertion.
    remove:
      6. Deletes the entry, regenerates the lockfile without it, and
         prunes .lwpt/modules/<name>/ — while the link TARGET
         (vendor/leaf) survives untouched.
      7. An unknown name is a hard error. }

program AddRemove.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

type
  TAddRemoveE2E = class(TTestSuite)
  private
    FScratch: string;
    function  ReadFileText(const APath: string): string;
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestAddWritesManifestLockAndModules;
    procedure TestAddSameNameUpdatesInPlace;
    procedure TestAddFailedInstallLeavesManifestUntouched;
    procedure TestAddUrlWithoutNameIsRejected;
    procedure TestAddDottedTableFormIsRejected;
    procedure TestRemovePrunesModulesButKeepsLinkTarget;
    procedure TestRemoveUnknownNameFails;
  end;

function TAddRemoveE2E.ReadFileText(const APath: string): string;
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(APath);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TAddRemoveE2E.SetupScratchProject;
begin
  WriteTestFile(FScratch + '/lwpt.toml',
    '# scratch manifest — this comment must survive every edit'#10 +
    '[package]'#10 +
    'name = "addremove-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10);

  WriteTestFile(FScratch + '/source/Dummy.pas',
    'unit Dummy;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);

  { The local dep `lwpt add` will install. Lives inside the project
    root, so the installer links rather than copies — which makes the
    prune-must-not-follow-the-link assertion meaningful. }
  WriteTestFile(FScratch + '/vendor/leaf/lwpt.toml',
    '[package]'#10 +
    'name = "leaf"'#10 +
    'version = "0.1.0"'#10 +
    'units = ["source"]'#10);

  WriteTestFile(FScratch + '/vendor/leaf/source/Leaf.pas',
    'unit Leaf;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);
end;

procedure TAddRemoveE2E.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/addremove-e2e');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure TAddRemoveE2E.BeforeEach;
begin
  { Fresh project per test — no case depends on another's mutations. }
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;
  RunLwpt(['install'], FScratch);
end;

procedure TAddRemoveE2E.TestAddWritesManifestLockAndModules;
var
  R: TLwptResult;
  Manifest, Lock: string;
begin
  R := RunLwpt(['add', './vendor/leaf'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  Manifest := ReadFileText(FScratch + '/lwpt.toml');
  Expect<Boolean>(Pos('[dependencies]', Manifest) > 0).ToBe(True);
  Expect<Boolean>(Pos('leaf = "./vendor/leaf"', Manifest) > 0).ToBe(True);
  Expect<Boolean>(Pos('this comment must survive', Manifest) > 0).ToBe(True);

  Expect<Boolean>(DirectoryExists(FScratch + '/.lwpt/modules/leaf'))
    .ToBe(True);
  Lock := ReadFileText(FScratch + '/lwpt.lock');
  Expect<Boolean>(Pos('leaf', Lock) > 0).ToBe(True);
end;

procedure TAddRemoveE2E.TestAddSameNameUpdatesInPlace;
var
  R: TLwptResult;
  Manifest: string;
  First: Integer;
begin
  { precondition: leaf already added once }
  R := RunLwpt(['add', './vendor/leaf'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  R := RunLwpt(['add', './vendor/leaf'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('updated leaf', R.Stdout) > 0).ToBe(True);

  { exactly one leaf entry — the line was replaced, not duplicated }
  Manifest := ReadFileText(FScratch + '/lwpt.toml');
  First := Pos('leaf = "./vendor/leaf"', Manifest);
  Expect<Boolean>(First > 0).ToBe(True);
  Expect<Integer>(
    Pos('leaf = "./vendor/leaf"', Manifest, First + 1)).ToBe(0);
end;

procedure TAddRemoveE2E.TestAddFailedInstallLeavesManifestUntouched;
var
  Before, After: string;
  R: TLwptResult;
begin
  Before := ReadFileText(FScratch + '/lwpt.toml');
  R := RunLwpt(['add', './vendor/does-not-exist'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  After := ReadFileText(FScratch + '/lwpt.toml');
  Expect<Boolean>(Before = After).ToBe(True);
end;

procedure TAddRemoveE2E.TestAddUrlWithoutNameIsRejected;
var R: TLwptResult;
begin
  { rejected at name derivation — before any network/disk work }
  R := RunLwpt(['add', 'https://example.invalid/dist/x.tar.gz'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('--name', R.Stderr) > 0).ToBe(True);
end;

procedure TAddRemoveE2E.TestAddDottedTableFormIsRejected;
var
  Dir, Before, After: string;
  R: TLwptResult;
begin
  { A dep authored as a [dependencies.<name>] dotted table parses fine
    but is not textually editable. `lwpt add` of the same name must
    hard-error (duplicate-key corruption otherwise) and leave the
    manifest untouched. }
  Dir := ExpandFileName('build/tests/tmp/addremove-dotted');
  RecursiveDelete(Dir);
  WriteTestFile(Dir + '/lwpt.toml',
    '[package]'#10 +
    'name = "addremove-dotted"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    #10 +
    '[dependencies.leaf]'#10 +
    'source = "./vendor/leaf"'#10);
  WriteTestFile(Dir + '/source/Dummy.pas',
    'unit Dummy;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);
  WriteTestFile(Dir + '/vendor/leaf/lwpt.toml',
    '[package]'#10 +
    'name = "leaf"'#10 +
    'version = "0.1.0"'#10 +
    'units = ["source"]'#10);
  WriteTestFile(Dir + '/vendor/leaf/source/Leaf.pas',
    'unit Leaf;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);

  Before := ReadFileText(Dir + '/lwpt.toml');
  R := RunLwpt(['add', './vendor/leaf'], Dir);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('manually', R.Stderr) > 0).ToBe(True);
  After := ReadFileText(Dir + '/lwpt.toml');
  Expect<Boolean>(Before = After).ToBe(True);
end;

procedure TAddRemoveE2E.TestRemovePrunesModulesButKeepsLinkTarget;
var
  R: TLwptResult;
  Manifest, Lock: string;
begin
  { precondition: leaf installed via add }
  R := RunLwpt(['add', './vendor/leaf'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(DirectoryExists(FScratch + '/.lwpt/modules/leaf'))
    .ToBe(True);

  R := RunLwpt(['remove', 'leaf'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  Manifest := ReadFileText(FScratch + '/lwpt.toml');
  Expect<Integer>(Pos('leaf = ', Manifest)).ToBe(0);
  Expect<Boolean>(Pos('this comment must survive', Manifest) > 0).ToBe(True);

  Expect<Boolean>(DirectoryExists(FScratch + '/.lwpt/modules/leaf'))
    .ToBe(False);
  Lock := ReadFileText(FScratch + '/lwpt.lock');
  Expect<Integer>(Pos('leaf', Lock)).ToBe(0);

  { pruning removed the LINK, never the linked-to source tree }
  Expect<Boolean>(FileExists(FScratch + '/vendor/leaf/source/Leaf.pas'))
    .ToBe(True);
end;

procedure TAddRemoveE2E.TestRemoveUnknownNameFails;
var R: TLwptResult;
begin
  R := RunLwpt(['remove', 'nope'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('no dependency named', R.Stderr) > 0).ToBe(True);
end;

procedure TAddRemoveE2E.SetupTests;
begin
  Test('add writes the manifest entry, lockfile, and modules tree',
    TestAddWritesManifestLockAndModules);
  Test('re-adding the same name updates the entry in place',
    TestAddSameNameUpdatesInPlace);
  Test('a failed install leaves lwpt.toml byte-identical',
    TestAddFailedInstallLeavesManifestUntouched);
  Test('a URL source without --name is rejected up front',
    TestAddUrlWithoutNameIsRejected);
  Test('a [dependencies.<name>] dotted-table dep is a hard error',
    TestAddDottedTableFormIsRejected);
  Test('remove prunes modules but never the link target',
    TestRemovePrunesModulesButKeepsLinkTarget);
  Test('removing an unknown name is a hard error',
    TestRemoveUnknownNameFails);
end;

begin
  TestRunnerProgram.AddSuite(
    TAddRemoveE2E.Create('lwpt add/remove: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
