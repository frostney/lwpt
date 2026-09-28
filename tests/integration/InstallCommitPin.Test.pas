program InstallCommitPin.Test;

{ Commit-SHA pins through the real CLI (ADR-0047). The git host is the
  test-build fixture seam: ref listings from refs/<repo>.refs, archives from
  archives/<repo>/<ref>.tar.gz, and upload-pack exchanges replayed from the
  recordings in tests/fixtures/git-reachability/upload-pack/reach, which
  were captured from `git upload-pack` serving the repository that
  tests/fixtures/git-reachability/make-repo.sh builds. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch,
  Tests.TarSynth;

const
  RECORDINGS = 'tests/fixtures/git-reachability';

type
  TInstallCommitPin = class(TTestSuite)
  private
    FScratch, FFixtureRoot, FCacheRoot: string;
    function Commit(const AName: string): string;
    procedure WriteRoot(const ARoot, ADependencies: string);
    procedure WriteArchive(const ACommit: string);
    procedure WritePackageArchive(const ARepository, ACommit,
      ADependencies: string);
    procedure WriteReachRefs(const AExtra: string);
    procedure StripReachableFrom(const ARoot: string);
    procedure SetReachableFrom(const ARoot, AValue: string);
    procedure ResetRequests;
    function RunLwptIn(const ARoot: string;
      const AArguments: array of string): TLwptResult;
    function RequestCount(const APrefix: string): Integer;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestReachableOldCommitInstalls;
    procedure TestLockedPinIsNotProvenAgain;
    procedure TestAdvertisedTipNeedsNoProof;
    procedure TestForkOnlyCommitFailsBeforeFetch;
    procedure TestChangedPinIsProvenAgain;
    procedure TestAbbreviatedCommitIsRefused;
    procedure TestAddOfForkOnlyCommitKeepsManifest;
    procedure TestUnmarkedLockedPinIsProvenAgain;
    procedure TestMixedAbbreviatedPinIsRefused;
    procedure TestMixedPinWithLyingPeelIsRefused;
    procedure TestMixedPinRecordsItsProof;
    procedure TestInvalidProvenanceIsProvenAgain;
  end;

function TInstallCommitPin.Commit(const AName: string): string;
var Lines: TStringList; i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(RECORDINGS + '/commits.txt');
    for i := 0 to Lines.Count - 1 do
      if Copy(Lines[i], 1, Length(AName) + 1) = AName + ' ' then
        Exit(Copy(Lines[i], Length(AName) + 2, 40));
  finally
    Lines.Free;
  end;
  raise Exception.Create('fixture commit not found: ' + AName);
end;

procedure TInstallCommitPin.WriteRoot(const ARoot, ADependencies: string);
begin
  RecursiveDelete(ARoot);
  ForceDirectories(ARoot + '/source');
  WriteTextFile(ARoot + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteTextFile(ARoot + '/lwpt.toml',
    '[package]'#10 + 'name = "pinned"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10 + ADependencies);
end;

procedure TInstallCommitPin.WritePackageArchive(const ARepository, ACommit,
  ADependencies: string);
var Entries: TByteArrays; Path, Manifest: string;
begin
  Manifest := '[package]'#10 + 'name = "' + ARepository + '"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10;
  if ADependencies <> '' then
    Manifest := Manifest + '[dependencies]'#10 + ADependencies;
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry(ARepository + '-fixture/lwpt.toml',
    BytesOf(Manifest));
  Entries[1] := MakeRegularFileEntry(ARepository + '-fixture/source/'
    + ARepository + '.pas', BytesOf('unit ' + ARepository + ';'#10
      + 'interface'#10 + 'implementation'#10 + 'end.'#10));
  Path := FFixtureRoot + '/archives/' + ARepository + '/' + ACommit
    + '.tar.gz';
  ForceDirectories(ExtractFileDir(Path));
  WriteBytesToFile(Path, Gzip(BuildTar(Entries)));
end;

procedure TInstallCommitPin.WriteArchive(const ACommit: string);
begin
  WritePackageArchive('reach', ACommit, '');
end;

procedure TInstallCommitPin.WriteReachRefs(const AExtra: string);
begin
  { The resolver's v1 listing of the same repository: branch and tag tips
    only, like a real advertisement filtered by the parser. }
  WriteTextFile(FFixtureRoot + '/refs/reach.refs',
    'branch|main|' + Commit('c6') + '|'#10
    + 'branch|release/0.1|' + Commit('r2') + '|'#10
    + 'tag|v0.1.0|' + Commit('c2') + '|'#10
    + 'tag|v0.2.0|' + Commit('v0.2.0-tag') + '|' + Commit('c4') + #10
    + AExtra);
end;

procedure TInstallCommitPin.SetReachableFrom(const ARoot, AValue: string);
var Lines: TStringList; i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(ARoot + '/lwpt.lock');
    for i := 0 to Lines.Count - 1 do
      if Pos('reachableFrom = ', Lines[i]) = 1 then
        Lines[i] := 'reachableFrom = "' + AValue + '"';
    Lines.SaveToFile(ARoot + '/lwpt.lock');
  finally
    Lines.Free;
  end;
end;

procedure TInstallCommitPin.StripReachableFrom(const ARoot: string);
var Lines: TStringList; i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(ARoot + '/lwpt.lock');
    for i := Lines.Count - 1 downto 0 do
      if Pos('reachableFrom = ', Lines[i]) = 1 then Lines.Delete(i);
    Lines.SaveToFile(ARoot + '/lwpt.lock');
  finally
    Lines.Free;
  end;
end;

procedure TInstallCommitPin.ResetRequests;
begin
  WriteTextFile(FFixtureRoot + '/requests.log', '');
end;

function TInstallCommitPin.RunLwptIn(const ARoot: string;
  const AArguments: array of string): TLwptResult;
begin
  Result := RunLwpt(AArguments, ARoot,
    [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot,
     PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot]);
end;

function TInstallCommitPin.RequestCount(const APrefix: string): Integer;
var Lines: TStringList; i: Integer;
begin
  Result := 0;
  if not FileExists(FFixtureRoot + '/requests.log') then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FFixtureRoot + '/requests.log');
    for i := 0 to Lines.Count - 1 do
      if Copy(Lines[i], 1, Length(APrefix)) = APrefix then Inc(Result);
  finally
    Lines.Free;
  end;
end;

procedure TInstallCommitPin.BeforeAll;
var Search: TSearchRec; Source, Target: string;
begin
  SetLwptBinaryPath(LwptTestingBinaryPath);
  FScratch := CreateScratchRoot('install-commit-pin');
  FFixtureRoot := FScratch + '/git-fixture';
  FCacheRoot := FScratch + '/user-cache';
  RecursiveDelete(FScratch);
  ForceDirectories(FFixtureRoot + '/upload-pack/reach');
  Source := RECORDINGS + '/upload-pack/reach/';
  Target := FFixtureRoot + '/upload-pack/reach/';
  if FindFirst(Source + '*', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Attr and faDirectory) = 0 then
        WriteBytesToFile(Target + Search.Name,
          BytesOf(ReadBinaryFile(Source + Search.Name)));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  WriteReachRefs('');
  WriteArchive(Commit('c1'));
  WriteArchive(Commit('c2'));
  WriteArchive(Commit('c6'));
  WriteArchive(Commit('f1'));
end;

procedure TInstallCommitPin.TestReachableOldCommitInstalls;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/old-commit';
  WriteRoot(Root, 'reach = "fixture/reach@' + Commit('c1') + '"'#10);
  ResetRequests;
  Run := RunLwptIn(Root, ['install']);
  DumpRunFailure('old commit', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('verified commit ' + Commit('c1')
    + ' for reach: reachable from refs/tags/v0.1.0', Run.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('resolvedCommit = "' + Commit('c1') + '"',
    ReadBinaryFile(Root + '/lwpt.lock')) > 0).ToBe(True);
  { The lock records which ref proved the pin. }
  Expect<Boolean>(Pos('reachableFrom = "refs/tags/v0.1.0"',
    ReadBinaryFile(Root + '/lwpt.lock')) > 0).ToBe(True);
  Expect<Integer>(RequestCount('upload-pack|reach|advertise')).ToBe(1);
  Expect<Integer>(RequestCount('upload-pack|reach|fetch')).ToBe(2);
end;

procedure TInstallCommitPin.TestLockedPinIsNotProvenAgain;
var Root: string; Run: TLwptResult;
begin
  { The lock entry written by the previous test already records c1 for
    this source; neither an online nor a frozen install proves it again. }
  Root := FScratch + '/old-commit';
  ResetRequests;
  Run := RunLwptIn(Root, ['install']);
  DumpRunFailure('locked pin', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RequestCount('upload-pack|')).ToBe(0);
  Run := RunLwptIn(Root, ['install', '--frozen']);
  DumpRunFailure('locked pin frozen', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Integer>(RequestCount('upload-pack|')).ToBe(0);
  Expect<Integer>(RequestCount('refs|reach')).ToBe(0);
end;

procedure TInstallCommitPin.TestAdvertisedTipNeedsNoProof;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/tip-commit';
  WriteRoot(Root, 'reach = "fixture/reach@' + Commit('c6') + '"'#10);
  ResetRequests;
  Run := RunLwptIn(Root, ['install']);
  DumpRunFailure('tip commit', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('reachable from refs/heads/main (0 requests',
    Run.Stdout) > 0).ToBe(True);
  Expect<Integer>(RequestCount('refs|reach')).ToBe(1);
  Expect<Integer>(RequestCount('upload-pack|')).ToBe(0);
end;

procedure TInstallCommitPin.TestForkOnlyCommitFailsBeforeFetch;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/fork-commit';
  WriteRoot(Root, 'reach = "fixture/reach@' + Commit('f1') + '"'#10);
  ResetRequests;
  Run := RunLwptIn(Root, ['install']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('commit ' + Commit('f1')
    + ' is not reachable from any branch or tag', Run.Stderr) > 0)
    .ToBe(True);
  { The archive the host would happily serve is never requested, and no
    dependency state is published. }
  Expect<Integer>(RequestCount('archive|reach|')).ToBe(0);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/reach'))
    .ToBe(False);
end;

procedure TInstallCommitPin.TestChangedPinIsProvenAgain;
var Root, LockBefore: string; Run: TLwptResult;
begin
  Root := FScratch + '/changed-pin';
  WriteRoot(Root, 'reach = "fixture/reach@' + Commit('c6') + '"'#10);
  Run := RunLwptIn(Root, ['install']);
  DumpRunFailure('changed pin seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  LockBefore := ReadBinaryFile(Root + '/lwpt.lock');
  WriteTextFile(Root + '/lwpt.toml',
    '[package]'#10 + 'name = "pinned"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'reach = "fixture/reach@' + Commit('f1') + '"'#10);
  ResetRequests;
  Run := RunLwptIn(Root, ['install']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('is not reachable', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(RequestCount('upload-pack|reach|fetch') > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.lock')).ToBe(LockBefore);
end;

procedure TInstallCommitPin.TestAbbreviatedCommitIsRefused;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/abbreviated';
  WriteRoot(Root, 'reach = "fixture/reach@' + Copy(Commit('c1'), 1, 12)
    + '"'#10);
  ResetRequests;
  Run := RunLwptIn(Root, ['install']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('commit pin "' + Copy(Commit('c1'), 1, 12)
    + '" (required by ', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('is abbreviated', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('full 40-character SHA', Run.Stderr) > 0).ToBe(True);
  Expect<Integer>(RequestCount('refs|reach')).ToBe(0);
  Expect<Integer>(RequestCount('upload-pack|')).ToBe(0);
end;

procedure TInstallCommitPin.TestAddOfForkOnlyCommitKeepsManifest;
var Root, ManifestBefore: string; Run: TLwptResult;
begin
  Root := FScratch + '/add-fork';
  WriteRoot(Root, '');
  ManifestBefore := ReadBinaryFile(Root + '/lwpt.toml');
  ResetRequests;
  Run := RunLwptIn(Root, ['add', 'fixture/reach@' + Commit('f1')]);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('is not reachable', Run.Stderr) > 0).ToBe(True);
  Expect<string>(ReadBinaryFile(Root + '/lwpt.toml')).ToBe(ManifestBefore);
  Expect<Integer>(RequestCount('archive|reach|')).ToBe(0);
end;

procedure TInstallCommitPin.TestUnmarkedLockedPinIsProvenAgain;
var Root: string; Run: TLwptResult;
begin
  { A lock written before proofs existed: seed it while the host still
    advertises f1 as a branch tip, drop the proof marker, then withdraw
    the branch. The entry carries no evidence and must be proven again. }
  Root := FScratch + '/legacy-lock';
  WriteRoot(Root, 'reach = "fixture/reach@' + Commit('f1') + '"'#10);
  WriteReachRefs('branch|feature|' + Commit('f1') + '|'#10);
  try
    Run := RunLwptIn(Root, ['install']);
    DumpRunFailure('legacy lock seed', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
  finally
    WriteReachRefs('');
  end;
  StripReachableFrom(Root);

  { Frozen and offline stay network-free but say the entry is unproven. }
  ResetRequests;
  Run := RunLwptIn(Root, ['install', '--frozen']);
  DumpRunFailure('legacy lock frozen', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('without a reachability proof', Run.Stderr) > 0)
    .ToBe(True);
  Run := RunLwptIn(Root, ['install', '--offline']);
  DumpRunFailure('legacy lock offline', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('without a reachability proof', Run.Stderr) > 0)
    .ToBe(True);
  Expect<Integer>(RequestCount('upload-pack|')).ToBe(0);
  Expect<Integer>(RequestCount('refs|')).ToBe(0);

  Run := RunLwptIn(Root, ['install']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('is not reachable', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(RequestCount('upload-pack|reach|fetch') > 0).ToBe(True);
end;

procedure TInstallCommitPin.TestMixedAbbreviatedPinIsRefused;
const
  WRAPPER_COMMIT = '1234567890123456789012345678901234567890';
var Root: string; Run: TLwptResult;
begin
  { The root names a tag; a dependency names an abbreviated SHA for the same
    package. The mixed requirement set must still refuse the abbreviation. }
  WriteTextFile(FFixtureRoot + '/refs/wrapper.refs',
    'tag|v1.0.0|' + WRAPPER_COMMIT + '|'#10);
  WritePackageArchive('wrapper', WRAPPER_COMMIT,
    'reach = "fixture/reach@' + Copy(Commit('c2'), 1, 12) + '"'#10);
  Root := FScratch + '/mixed-abbreviated';
  WriteRoot(Root, 'reach = "fixture/reach@v0.1.0"'#10
    + 'wrapper = "fixture/wrapper@1.0.0"'#10);
  Run := RunLwptIn(Root, ['install']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('commit pin "' + Copy(Commit('c2'), 1, 12)
    + '" (required by ', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('is abbreviated', Run.Stderr) > 0).ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
end;

procedure TInstallCommitPin.TestMixedPinWithLyingPeelIsRefused;
const
  PINNER_COMMIT = '2345678901234567890123456789012345678901';
var Root: string; Run: TLwptResult;
begin
  { The root names tag v0.2.0; a dependency pins the fork-only f1 by SHA.
    The listing's peel line claims v0.2.0 peels to f1, so the resolver's
    tag selection agrees with the pin. The SHA requirement must still be
    proven, and the hash-verified tag object points at c4. }
  WriteTextFile(FFixtureRoot + '/refs/pinner.refs',
    'tag|v1.0.0|' + PINNER_COMMIT + '|'#10);
  WritePackageArchive('pinner', PINNER_COMMIT,
    'reach = "fixture/reach@' + Commit('f1') + '"'#10);
  WriteTextFile(FFixtureRoot + '/refs/reach.refs',
    'branch|main|' + Commit('c6') + '|'#10
    + 'branch|release/0.1|' + Commit('r2') + '|'#10
    + 'tag|v0.1.0|' + Commit('c2') + '|'#10
    + 'tag|v0.2.0|' + Commit('v0.2.0-tag') + '|' + Commit('f1') + #10);
  try
    Root := FScratch + '/mixed-lying-peel';
    WriteRoot(Root, 'reach = "fixture/reach@v0.2.0"'#10
      + 'pinner = "fixture/pinner@1.0.0"'#10);
    ResetRequests;
    Run := RunLwptIn(Root, ['install']);
    Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos('is not reachable', Run.Stderr) > 0).ToBe(True);
    { Round one stages the tag alone (the SHA arrives with pinner), so a
      candidate archive may already be fetched; nothing is published. }
    Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
    Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/reach'))
      .ToBe(False);
  finally
    WriteReachRefs('');
  end;
end;

procedure TInstallCommitPin.TestMixedPinRecordsItsProof;
const
  PINNER_COMMIT = '3456789012345678901234567890123456789012';
var Root: string; Run: TLwptResult;
begin
  { Honest listing: the tag and the SHA agree on c4. The SHA requirement is
    proven like a lone pin and the lock records the proof. }
  WriteTextFile(FFixtureRoot + '/refs/pinner2.refs',
    'tag|v1.0.0|' + PINNER_COMMIT + '|'#10);
  WritePackageArchive('pinner2', PINNER_COMMIT,
    'reach = "fixture/reach@' + Commit('c4') + '"'#10);
  WriteArchive(Commit('c4'));
  Root := FScratch + '/mixed-proof';
  WriteRoot(Root, 'reach = "fixture/reach@v0.2.0"'#10
    + 'pinner2 = "fixture/pinner2@1.0.0"'#10);
  Run := RunLwptIn(Root, ['install']);
  DumpRunFailure('mixed proof', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('reachableFrom = "refs/tags/v0.2.0"',
    ReadBinaryFile(Root + '/lwpt.lock')) > 0).ToBe(True);
  { Without the marker a mixed entry is unproven too. }
  StripReachableFrom(Root);
  ResetRequests;
  Run := RunLwptIn(Root, ['install', '--frozen']);
  DumpRunFailure('mixed frozen', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('without a reachability proof', Run.Stderr) > 0)
    .ToBe(True);
end;

procedure TInstallCommitPin.TestInvalidProvenanceIsProvenAgain;
var Root: string; Run: TLwptResult;
begin
  { A marker naming a ref outside refs/heads/* and refs/tags/* proves
    nothing: warn offline, prove again online. }
  Root := FScratch + '/invalid-provenance';
  WriteRoot(Root, 'reach = "fixture/reach@' + Commit('f1') + '"'#10);
  WriteReachRefs('branch|feature|' + Commit('f1') + '|'#10);
  try
    Run := RunLwptIn(Root, ['install']);
    DumpRunFailure('invalid provenance seed', Run, 0);
    Expect<Integer>(Run.ExitCode).ToBe(0);
  finally
    WriteReachRefs('');
  end;
  SetReachableFrom(Root, 'refs/pull/1/head');
  ResetRequests;
  Run := RunLwptIn(Root, ['install', '--offline']);
  DumpRunFailure('invalid provenance offline', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('without a reachability proof', Run.Stderr) > 0)
    .ToBe(True);
  Run := RunLwptIn(Root, ['install']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('is not reachable', Run.Stderr) > 0).ToBe(True);
end;

procedure TInstallCommitPin.SetupTests;
begin
  Test('a pin to an older reachable commit installs',
    TestReachableOldCommitInstalls);
  Test('an unchanged locked pin is not proven again',
    TestLockedPinIsNotProvenAgain);
  Test('a pin equal to an advertised tip needs no upload-pack request',
    TestAdvertisedTipNeedsNoProof);
  Test('a fork-only commit fails before its archive is fetched',
    TestForkOnlyCommitFailsBeforeFetch);
  Test('changing a locked pin proves the new commit',
    TestChangedPinIsProvenAgain);
  Test('an abbreviated commit pin is refused without network',
    TestAbbreviatedCommitIsRefused);
  Test('add of a fork-only commit leaves the manifest unchanged',
    TestAddOfForkOnlyCommitKeepsManifest);
  Test('a locked pin without a proof marker is proven again online',
    TestUnmarkedLockedPinIsProvenAgain);
  Test('an abbreviated pin is refused beside a named requirement',
    TestMixedAbbreviatedPinIsRefused);
  Test('a SHA pin beside a tag is proven, whatever the peel claims',
    TestMixedPinWithLyingPeelIsRefused);
  Test('a SHA pin beside a tag records its proof',
    TestMixedPinRecordsItsProof);
  Test('a proof marker outside branches and tags is proven again',
    TestInvalidProvenanceIsProvenAgain);
end;

begin
  TestRunnerProgram.AddSuite(TInstallCommitPin.Create(
    'install: commit pins must be reachable'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
