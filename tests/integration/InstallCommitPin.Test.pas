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

procedure TInstallCommitPin.WriteArchive(const ACommit: string);
var Entries: TByteArrays; Path: string;
begin
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry('reach-fixture/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "reach"'#10 + 'version = "1.0.0"'#10
      + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry('reach-fixture/source/reach.pas',
    BytesOf('unit reach;'#10 + 'interface'#10 + 'implementation'#10
      + 'end.'#10));
  Path := FFixtureRoot + '/archives/reach/' + ACommit + '.tar.gz';
  ForceDirectories(ExtractFileDir(Path));
  WriteBytesToFile(Path, Gzip(BuildTar(Entries)));
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
  { The resolver's v1 listing of the same repository: branch and tag tips
    only, like a real advertisement filtered by the parser. }
  WriteTextFile(FFixtureRoot + '/refs/reach.refs',
    'branch|main|' + Commit('c6') + '|'#10
    + 'branch|release/0.1|' + Commit('r2') + '|'#10
    + 'tag|v0.1.0|' + Commit('c2') + '|'#10
    + 'tag|v0.2.0|' + Commit('v0.2.0-tag') + '|' + Commit('c4') + #10);
  WriteArchive(Commit('c1'));
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
    + '" is abbreviated', Run.Stderr) > 0).ToBe(True);
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
end;

begin
  TestRunnerProgram.AddSuite(TInstallCommitPin.Create(
    'install: commit pins must be reachable'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
