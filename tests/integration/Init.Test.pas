{ Init.Test — integration test for `lwpt init --yes` (ADR-0010).

  Spawns the binary in a per-test scratch directory and asserts on
  the three artefacts the subcommand is responsible for:

    - lwpt.toml: a parsable manifest naming a [package] derived from
      the scratch dir's basename, version "0.1.0", units = ["source"].
    - lwpt.lock: schema-v3 empty lockfile (no packages, but the
      version header is correct so the next `lwpt install` accepts it).
    - .gitignore: contains the two LWPT-internal paths
      (.lwpt/tmp/ + .lwpt/install.lock) — added if absent, never
      duplicated if present.

  Also covers the refuse-to-clobber semantics: a second run without
  --force fails; with --force succeeds. }

program Init.Test;

{$mode delphi}{$H+}

uses
  Classes,
  StrUtils,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

type
  TInitCommand = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestInitYesCreatesManifestEntryAndGitignore;
    procedure TestInitYesDoesNotCreateLockfile;
    procedure TestInitYesScaffoldedManifestParses;
    procedure TestInitYesScaffoldedEntryIsValidPascal;
    procedure TestInitYesLeadingDigitEntryIsValidPascal;
    procedure TestInitYesGitignoreHasLwptAndBuildEntries;
    procedure TestInitYesPackageNameIsScratchBasename;
    procedure TestInitYesEntryRunsAfterInstallAndBuild;
    procedure TestSecondInitWithoutForceRejects;
    procedure TestSecondInitWithForceOverwrites;
    procedure TestExistingGitignoreIsNotDuplicated;
  end;

function ReadFileText(const APath: string): string;
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

procedure WriteText(const APath, AContent: string);
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure TInitCommand.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := ExpandFileName('build/tests/tmp/init-test/my-project');
  RecursiveDelete(ExpandFileName('build/tests/tmp/init-test'));
  ForceDirectories(FScratch);
end;

procedure TInitCommand.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TInitCommand.TestInitYesCreatesManifestEntryAndGitignore;
var R: TLwptResult;
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  R := RunLwpt(['init', '--yes'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  { Three artefacts: the manifest, the hello-world entry .pas, and
    the .gitignore. The scratch dir basename is "my-project" → the
    entry file is source/my-project.pas. }
  Expect<Boolean>(FileExists(FScratch + '/lwpt.toml')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/source/my-project.pas')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/.gitignore')).ToBe(True);
end;

procedure TInitCommand.TestInitYesDoesNotCreateLockfile;
begin
  { lwpt.lock is created by `lwpt install`, not by `lwpt init`. The
    --yes flag explicitly skips the post-init install/build chain,
    so right after `init --yes` there should be no lockfile. }
  Expect<Boolean>(FileExists(FScratch + '/lwpt.lock')).ToBe(False);
end;

procedure TInitCommand.TestInitYesScaffoldedManifestParses;
var R: TLwptResult;
begin
  { Round-trip: `lwpt install` immediately after `lwpt init --yes`
    must parse the scaffolded manifest cleanly + emit a v3 lockfile. }
  R := RunLwpt(['install'], FScratch);
  if R.ExitCode <> 0 then
    WriteLn('--- install stderr after init ---'#10, R.Stderr, #10'---');
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/lwpt.lock')).ToBe(True);
end;

procedure TInitCommand.TestInitYesScaffoldedEntryIsValidPascal;
var Entry: string;
begin
  Entry := ReadFileText(FScratch + '/source/my-project.pas');
  { The program declaration sanitises hyphens (Pascal identifier
    rules); the WriteLn greeting keeps the original spelling. }
  Expect<Boolean>(Pos('program my_project;', Entry) > 0).ToBe(True);
  Expect<Boolean>(Pos('hello from my-project', Entry) > 0).ToBe(True);
  Expect<Boolean>(Pos('{$mode delphi}',       Entry) > 0).ToBe(True);
end;

procedure TInitCommand.TestInitYesGitignoreHasLwptAndBuildEntries;
var GI: string;
begin
  GI := ReadFileText(FScratch + '/.gitignore');
  Expect<Boolean>(Pos('.lwpt/tmp/',         GI) > 0).ToBe(True);
  Expect<Boolean>(Pos('.lwpt/install.lock', GI) > 0).ToBe(True);
  Expect<Boolean>(Pos('build/',             GI) > 0).ToBe(True);
end;

procedure TInitCommand.TestInitYesPackageNameIsScratchBasename;
var Man: string;
begin
  Man := ReadFileText(FScratch + '/lwpt.toml');
  { The scratch dir's basename is "my-project". Manifest also has
    a [build] entry pointing at the scaffolded .pas. }
  Expect<Boolean>(Pos('name = "my-project"', Man) > 0).ToBe(True);
  Expect<Boolean>(Pos('version = "0.1.0"',   Man) > 0).ToBe(True);
  Expect<Boolean>(Pos('units = ["source"]',  Man) > 0).ToBe(True);
  Expect<Boolean>(Pos('[build]',           Man) > 0).ToBe(True);
  Expect<Boolean>(Pos('my-project = { source = "source/my-project.pas", output = "build/my-project" }',
    Man) > 0).ToBe(True);
end;

procedure TInitCommand.TestInitYesEntryRunsAfterInstallAndBuild;
var R: TLwptResult; Exe: string;
begin
  { The end-to-end story: `lwpt init --yes && lwpt build` produces
    a runnable binary at <BuildDir>/<EntryName>. We don't actually
    spawn it (the test process is restricted enough) — we just
    assert the file exists + is non-zero in size. }
  R := RunLwpt(['build'], FScratch);
  if R.ExitCode <> 0 then
    WriteLn('--- build stderr ---'#10, R.Stderr, #10'---');
  Expect<Integer>(R.ExitCode).ToBe(0);
  Exe := FScratch + '/build/my-project';
  Expect<Boolean>(FileExists(ExpectedExe(Exe))).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/source/my-project.o')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/source/my-project.ppu')).ToBe(False);
end;

procedure TInitCommand.TestInitYesLeadingDigitEntryIsValidPascal;
var
  DigitScratch, Entry: string;
  R: TLwptResult;
begin
  DigitScratch := ExpandFileName('build/tests/tmp/init-test/123-app');
  RecursiveDelete(DigitScratch);
  ForceDirectories(DigitScratch);

  R := RunLwpt(['init', '--yes'], DigitScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  Entry := ReadFileText(DigitScratch + '/source/123-app.pas');
  Expect<Boolean>(Pos('program _123_app;', Entry) > 0).ToBe(True);
  Expect<Boolean>(Pos('hello from 123-app', Entry) > 0).ToBe(True);
end;

procedure TInitCommand.TestSecondInitWithoutForceRejects;
var R: TLwptResult;
begin
  { lwpt.toml already exists from the first init; running again
    without --force must fail and name the file in the error. }
  R := RunLwpt(['init', '--yes'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('lwpt.toml', R.Stdout + R.Stderr) > 0).ToBe(True);
end;

procedure TInitCommand.TestSecondInitWithForceOverwrites;
var R: TLwptResult; Before, After: string;
begin
  { With --force, the existing manifest is overwritten. We assert
    that the new file is at least different from a tampered version
    we plant beforehand. }
  WriteText(FScratch + '/lwpt.toml',
    '# tampered'#10 +
    '[package]'#10 +
    'name = "tampered"'#10 +
    'version = "0.0.0"'#10);
  Before := ReadFileText(FScratch + '/lwpt.toml');

  R := RunLwpt(['init', '--yes', '--force'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  After := ReadFileText(FScratch + '/lwpt.toml');
  Expect<Boolean>(After <> Before).ToBe(True);
  Expect<Boolean>(Pos('tampered', After) = 0).ToBe(True);
end;

procedure TInitCommand.TestExistingGitignoreIsNotDuplicated;
var R: TLwptResult; GI: string; Count: Integer;
begin
  { Pre-populate .gitignore with our entries, then re-init; the
    entries must not be duplicated. (Run --force so the second
    init succeeds.) }
  WriteText(FScratch + '/.gitignore',
    '# existing'#10 +
    '.lwpt/tmp/'#10 +
    '.lwpt/install.lock'#10);
  R := RunLwpt(['init', '--yes', '--force'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  GI := ReadFileText(FScratch + '/.gitignore');
  Count := 0;
  while PosEx('.lwpt/tmp/', GI, Count + 1) > 0 do
    Count := PosEx('.lwpt/tmp/', GI, Count + 1);
  { Count tracking via position isn't a count of occurrences; do a
    proper count. }
  Count := 0;
  while Pos('.lwpt/tmp/', GI) > 0 do
  begin
    Inc(Count);
    GI := StringReplace(GI, '.lwpt/tmp/', '###', []);
  end;
  Expect<Integer>(Count).ToBe(1);
end;

procedure TInitCommand.SetupTests;
begin
  Test('lwpt init --yes creates lwpt.toml + entry .pas + .gitignore',
    TestInitYesCreatesManifestEntryAndGitignore);
  Test('lwpt init --yes does NOT create lwpt.lock (install does)',
    TestInitYesDoesNotCreateLockfile);
  Test('scaffolded manifest round-trips through `lwpt install`',
    TestInitYesScaffoldedManifestParses);
  Test('scaffolded entry .pas is valid Pascal (program + WriteLn + delphi mode)',
    TestInitYesScaffoldedEntryIsValidPascal);
  Test('leading-digit entry name is sanitised into a valid Pascal program id',
    TestInitYesLeadingDigitEntryIsValidPascal);
  Test('.gitignore contains the LWPT-internal paths + the build dir',
    TestInitYesGitignoreHasLwptAndBuildEntries);
  Test('manifest reflects scratch basename + [build] for the entry',
    TestInitYesPackageNameIsScratchBasename);
  Test('`lwpt build` after init produces an executable at <BuildDir>/<EntryName>',
    TestInitYesEntryRunsAfterInstallAndBuild);
  Test('re-running init without --force is rejected with a clear error',
    TestSecondInitWithoutForceRejects);
  Test('re-running with --force overwrites the existing manifest',
    TestSecondInitWithForceOverwrites);
  Test('existing .gitignore entries are not duplicated on re-init',
    TestExistingGitignoreIsNotDuplicated);
end;

begin
  TestRunnerProgram.AddSuite(TInitCommand.Create(
    'lwpt init (ADR-0010)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
