{ Init.Test — integration test for `lwpt init` (ADR-0010).

  Spawns the binary in a per-test scratch directory and asserts on
  fresh scaffolding plus non-destructive adoption around an existing
  manifest.

  Adoption preserves lwpt.toml byte-for-byte, creates missing local
  [package].units directories, appends only missing .gitignore entries,
  and rejects conflicts before changing the scaffold. }

program Init.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  StrUtils,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

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
    procedure TestAdoptPreservesManifestAndAddsMissingScaffold;
    procedure TestAdoptIsIdempotentAndReportsFoundScaffold;
    procedure TestAdoptRejectsForceWithoutWriting;
    procedure TestAdoptRequiresExistingManifest;
    procedure TestAdoptRejectsInvalidManifestWithoutWriting;
    procedure TestAdoptRejectsUnitFileConflictWithoutWriting;
    procedure TestAdoptRejectsMissingExternalUnitDirectory;
    procedure TestAdoptRejectsSymlinkedUnitParent;
    procedure TestAdoptRejectsSymlinkedGitignore;
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

function ReadRawFileText(const APath: string): string;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure WriteRawFileText(const APath, AContent: string);
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AContent <> '' then
      Stream.WriteBuffer(AContent[1], Length(AContent));
  finally
    Stream.Free;
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
  FScratch := CreateScratchRoot('init-test') + '/my-project';
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
  Expect<Boolean>(Pos('.lwpt/sessions/',    GI) > 0).ToBe(True);
  Expect<Boolean>(Pos('.lwpt/workers/',     GI) > 0).ToBe(True);
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
  DigitScratch := ExtractFileDir(FScratch) + '/123-app';
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
    '.lwpt/install.lock'#10 +
    '.lwpt/sessions/'#10 +
    '.lwpt/workers/'#10);
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
  Count := 0;
  while Pos('.lwpt/workers/', GI) > 0 do
  begin
    Inc(Count);
    GI := StringReplace(GI, '.lwpt/workers/', '###', []);
  end;
  Expect<Integer>(Count).ToBe(1);
end;

procedure TInitCommand.TestAdoptPreservesManifestAndAddsMissingScaffold;
var
  AdoptScratch, ManifestBefore, ManifestAfter: string;
  GitignoreBefore, GitignoreAfter, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-project';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-project"'#10 +
    'version = "1.2.3"'#10 +
    'units = ["source", "generated"]'#10);
  GitignoreBefore := '# user content without a trailing newline';
  WriteRawFileText(AdoptScratch + '/.gitignore', GitignoreBefore);
  ManifestBefore := ReadRawFileText(AdoptScratch + '/lwpt.toml');

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  ManifestAfter := ReadRawFileText(AdoptScratch + '/lwpt.toml');
  GitignoreAfter := ReadRawFileText(AdoptScratch + '/.gitignore');
  Output := R.Stdout + R.Stderr;
  Expect<string>(ManifestAfter).ToBe(ManifestBefore);
  Expect<Boolean>(Copy(GitignoreAfter, 1, Length(GitignoreBefore))
    = GitignoreBefore).ToBe(True);
  Expect<Boolean>(DirectoryExists(AdoptScratch + '/source')).ToBe(True);
  Expect<Boolean>(DirectoryExists(AdoptScratch + '/generated')).ToBe(True);
  Expect<Boolean>(Pos('.lwpt/tmp/', GitignoreAfter) > 0).ToBe(True);
  Expect<Boolean>(Pos('.lwpt/install.lock', GitignoreAfter) > 0).ToBe(True);
  Expect<Boolean>(Pos('.lwpt/sessions/', GitignoreAfter) > 0).ToBe(True);
  Expect<Boolean>(Pos('.lwpt/workers/', GitignoreAfter) > 0).ToBe(True);
  Expect<Boolean>(Pos('build/', GitignoreAfter) > 0).ToBe(True);
  Expect<Boolean>(Pos('preserved lwpt.toml', Output) > 0).ToBe(True);
  Expect<Boolean>(Pos('created unit directory source', Output) > 0).ToBe(True);
  Expect<Boolean>(Pos('added .gitignore entry build/', Output) > 0).ToBe(True);
end;

procedure TInitCommand.TestAdoptIsIdempotentAndReportsFoundScaffold;
var
  AdoptScratch, ManifestBefore, GitignoreBefore, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-idempotent';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-idempotent"'#10 +
    'version = "0.4.0"'#10 +
    'units = ["src"]'#10);

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  ManifestBefore := ReadRawFileText(AdoptScratch + '/lwpt.toml');
  GitignoreBefore := ReadRawFileText(AdoptScratch + '/.gitignore');

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Output := R.Stdout + R.Stderr;
  Expect<string>(ReadRawFileText(AdoptScratch + '/lwpt.toml'))
    .ToBe(ManifestBefore);
  Expect<string>(ReadRawFileText(AdoptScratch + '/.gitignore'))
    .ToBe(GitignoreBefore);
  Expect<Boolean>(Pos('found unit directory src', Output) > 0).ToBe(True);
  Expect<Boolean>(Pos('found .gitignore entry build/', Output) > 0).ToBe(True);
  Expect<Boolean>(Pos('added .gitignore entry', Output) = 0).ToBe(True);
end;

procedure TInitCommand.TestAdoptRejectsForceWithoutWriting;
var
  AdoptScratch, ManifestBefore, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-force-conflict';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-force-conflict"'#10 +
    'units = ["source"]'#10);
  ManifestBefore := ReadRawFileText(AdoptScratch + '/lwpt.toml');

  R := RunLwpt(['init', '--adopt', '--force'], AdoptScratch);
  Output := R.Stdout + R.Stderr;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('--adopt and --force', Output) > 0).ToBe(True);
  Expect<string>(ReadRawFileText(AdoptScratch + '/lwpt.toml'))
    .ToBe(ManifestBefore);
  Expect<Boolean>(DirectoryExists(AdoptScratch + '/source')).ToBe(False);
  Expect<Boolean>(FileExists(AdoptScratch + '/.gitignore')).ToBe(False);
end;

procedure TInitCommand.TestAdoptRequiresExistingManifest;
var
  AdoptScratch, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-no-manifest';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Output := R.Stdout + R.Stderr;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('cannot adopt without an existing lwpt.toml',
    Output) > 0).ToBe(True);
  Expect<Boolean>(FileExists(AdoptScratch + '/.gitignore')).ToBe(False);
end;

procedure TInitCommand.TestAdoptRejectsInvalidManifestWithoutWriting;
var
  AdoptScratch, ManifestBefore, GitignoreBefore: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-invalid-manifest';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package'#10 +
    'name = "broken"'#10);
  WriteRawFileText(AdoptScratch + '/.gitignore', '# unchanged');
  ManifestBefore := ReadRawFileText(AdoptScratch + '/lwpt.toml');
  GitignoreBefore := ReadRawFileText(AdoptScratch + '/.gitignore');

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<string>(ReadRawFileText(AdoptScratch + '/lwpt.toml'))
    .ToBe(ManifestBefore);
  Expect<string>(ReadRawFileText(AdoptScratch + '/.gitignore'))
    .ToBe(GitignoreBefore);
  Expect<Boolean>(DirectoryExists(AdoptScratch + '/source')).ToBe(False);
end;

procedure TInitCommand.TestAdoptRejectsUnitFileConflictWithoutWriting;
var
  AdoptScratch, ManifestBefore, GitignoreBefore, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-unit-file';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-unit-file"'#10 +
    'units = ["source"]'#10);
  WriteRawFileText(AdoptScratch + '/source', 'not a directory');
  WriteRawFileText(AdoptScratch + '/.gitignore', '# unchanged');
  ManifestBefore := ReadRawFileText(AdoptScratch + '/lwpt.toml');
  GitignoreBefore := ReadRawFileText(AdoptScratch + '/.gitignore');

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Output := R.Stdout + R.Stderr;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('is a file, not a directory', Output) > 0).ToBe(True);
  Expect<string>(ReadRawFileText(AdoptScratch + '/lwpt.toml'))
    .ToBe(ManifestBefore);
  Expect<string>(ReadRawFileText(AdoptScratch + '/.gitignore'))
    .ToBe(GitignoreBefore);
end;

procedure TInitCommand.TestAdoptRejectsMissingExternalUnitDirectory;
var
  AdoptScratch, ExternalDir, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-external-unit';
  ExternalDir := ExtractFileDir(AdoptScratch) + '/outside-source';
  RecursiveDelete(AdoptScratch);
  RecursiveDelete(ExternalDir);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-external-unit"'#10 +
    'units = ["../outside-source"]'#10);

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Output := R.Stdout + R.Stderr;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('refusing to create [package].units path',
    Output) > 0).ToBe(True);
  Expect<Boolean>(DirectoryExists(ExternalDir)).ToBe(False);
  Expect<Boolean>(FileExists(AdoptScratch + '/.gitignore')).ToBe(False);
end;

procedure TInitCommand.TestAdoptRejectsSymlinkedUnitParent;
{$IFDEF UNIX}
var
  AdoptScratch, ExternalDir, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-linked-unit';
  ExternalDir := ExtractFileDir(AdoptScratch) + '/linked-unit-target';
  RecursiveDelete(AdoptScratch);
  RecursiveDelete(ExternalDir);
  ForceDirectories(AdoptScratch);
  ForceDirectories(ExternalDir);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-linked-unit"'#10 +
    'units = ["linked-parent/new-dir"]'#10);
  if FpSymlink(PAnsiChar('../linked-unit-target'),
    PAnsiChar(AdoptScratch + '/linked-parent')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for unit parent');

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Output := R.Stdout + R.Stderr;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('through symlink or junction', Output) > 0).ToBe(True);
  Expect<Boolean>(DirectoryExists(ExternalDir + '/new-dir')).ToBe(False);
  Expect<Boolean>(FileExists(AdoptScratch + '/.gitignore')).ToBe(False);
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure TInitCommand.TestAdoptRejectsSymlinkedGitignore;
{$IFDEF UNIX}
var
  AdoptScratch, ExternalFile, ExternalBefore, Output: string;
  R: TLwptResult;
begin
  AdoptScratch := ExtractFileDir(FScratch) + '/adopt-linked-gitignore';
  ExternalFile := ExtractFileDir(AdoptScratch) + '/outside.gitignore';
  RecursiveDelete(AdoptScratch);
  ForceDirectories(AdoptScratch);
  WriteRawFileText(AdoptScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "adopt-linked-gitignore"'#10 +
    'units = []'#10);
  ExternalBefore := '# external content';
  WriteRawFileText(ExternalFile, ExternalBefore);
  if FpSymlink(PAnsiChar('../outside.gitignore'),
    PAnsiChar(AdoptScratch + '/.gitignore')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for .gitignore');

  R := RunLwpt(['init', '--adopt'], AdoptScratch);
  Output := R.Stdout + R.Stderr;
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('through symlink or junction', Output) > 0).ToBe(True);
  Expect<string>(ReadRawFileText(ExternalFile)).ToBe(ExternalBefore);
end;
{$ELSE}
begin
end;
{$ENDIF}

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
  Test('init --adopt preserves the manifest and adds missing scaffold',
    TestAdoptPreservesManifestAndAddsMissingScaffold);
  Test('init --adopt is idempotent and reports found scaffold',
    TestAdoptIsIdempotentAndReportsFoundScaffold);
  Test('init --adopt rejects --force before writing',
    TestAdoptRejectsForceWithoutWriting);
  Test('init --adopt requires an existing manifest',
    TestAdoptRequiresExistingManifest);
  Test('init --adopt rejects an invalid manifest without writing',
    TestAdoptRejectsInvalidManifestWithoutWriting);
  Test('init --adopt rejects a unit-file conflict without writing',
    TestAdoptRejectsUnitFileConflictWithoutWriting);
  Test('init --adopt refuses to create a missing external unit directory',
    TestAdoptRejectsMissingExternalUnitDirectory);
  {$IFDEF UNIX}
  Test('init --adopt refuses a symlinked units-directory parent',
    TestAdoptRejectsSymlinkedUnitParent);
  Test('init --adopt refuses a symlinked .gitignore',
    TestAdoptRejectsSymlinkedGitignore);
  {$ELSE}
  Skip('init --adopt refuses a symlinked units-directory parent',
    TestAdoptRejectsSymlinkedUnitParent,
    'symlink fixture requires a Unix host');
  Skip('init --adopt refuses a symlinked .gitignore',
    TestAdoptRejectsSymlinkedGitignore,
    'symlink fixture requires a Unix host');
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TInitCommand.Create(
    'lwpt init (ADR-0010)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
