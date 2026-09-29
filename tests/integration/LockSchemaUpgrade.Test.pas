{ LockSchemaUpgrade.Test -- lockfile schema v4 and the v3 upgrade
  (ADR-0052) for git-host, URL, local, and workspace dependencies.

  A committed schema-v3 lock is built the way a pre-v4 binary wrote it: the
  same entries with `version = 3` and legacy tree digests. Every command
  that reads the lock must refuse it and change nothing; `lwpt repair` must
  upgrade it without network access and without moving versions,
  re-deriving each module from its archive or source rather than trusting
  the v3 digest. The git-host transport is the fixture seam
  (LWPT_TEST_GIT_FIXTURE_DIR), whose request log proves "no network". The
  registry half lives in InstallRegistryLocked.Test. }
program LockSchemaUpgrade.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.HTTPMockServer,
  Tests.LockSchema,
  Tests.LwptSubprocess,
  Tests.Scratch,
  Tests.TarSynth;

const
  SHARED_COMMIT = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  NEWER_COMMIT = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  OTHER_COMMIT = 'cccccccccccccccccccccccccccccccccccccccc';
  ARCHIVE_ORIGIN_ENV = PROJECT_NAME + '_TEST_ARCHIVE_ORIGIN';
  ARCHIVE_TIMEOUT_ENV = PROJECT_NAME + '_TEST_ARCHIVE_TIMEOUT_MS';
  SHARED_ARCHIVE = '.lwpt/archives/shared-v1.0.0.tar.gz';
  { A refused or failed command may not touch these; repair's own recovery
    steps own .lwpt/tmp and build sessions. }
  REPAIR_OWNED: array[0..1] of string = ('.lwpt/tmp', '.lwpt/sessions');

type
  TLockSchemaUpgrade = class(TTestSuite)
  private
    FScratch, FFixtureRoot, FCacheRoot: string;
    FCount: Integer;
    function NewRoot(const AName: string): string;
    procedure WriteRefs(const ARepository, AContent: string);
    procedure WriteArchive(const AName, ACommit, AVersion: string);
    procedure WriteLocalPackage(const ADirectory, AName: string);
    { git-host `shared`, local `local-dep`, and workspace `workspace-dep`,
      installed online; returns the v4 lock text. }
    function Seed(const AName: string; out ARoot: string): string;
    function Run(const ARoot: string;
      const AArguments: array of string): TLwptResult;
    function Requests: string;
    procedure ClearRequests;
    procedure ExpectFailureWith(const ALabel: string; const ARun: TLwptResult;
      const AText: string);
    procedure ExpectSuccess(const ALabel: string; const ARun: TLwptResult);
    procedure ExpectRefusedLock(const ALabel, ARoot, AHistorical,
      AReason: string);
    function ArchiveMessage: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestInstallWritesSchemaV4;
    procedure TestEveryReaderRefusesV3AndChangesNothing;
    procedure TestRepairUpgradesWithoutNetworkOrVersionChange;
    procedure TestNoChurnAfterTheUpgrade;
    procedure TestHistoricalV3LockChangesOnlyItsDigests;
    procedure TestMultilineValuesFailClosed;
    procedure TestUnsafeLockFormsFailClosed;
    procedure TestRepairReplacesASubstitutedModule;
    procedure TestRepairMissingArchiveFailsWithMigrationMessage;
    procedure TestRepairCorruptArchiveFailsWithMigrationMessage;
    procedure TestRepairManifestDisagreementLeavesV3;
    procedure TestRepairLeavesV4Alone;
    procedure TestLegacyRollbackRecoveredByRepairOnV3;
    procedure TestLegacyRollbackRecoveredByInstallOnV4;
    procedure TestSubstitutionFailsFrozenForLockedKinds;
    procedure TestSubstitutionFailsFrozenForURL;
    procedure TestFrozenRefusesLinksInModules;
  end;

function LockText(const ARoot: string): string;
begin
  Result := ReadBinaryFile(ARoot + '/lwpt.lock');
end;

{ The lines two locks do not share, in order, joined by '|'. }
function ChangedLines(const ABefore, AAfter: string): string;
var Before, After: TStringList; i: Integer;
begin
  Result := '';
  Before := TStringList.Create;
  After := TStringList.Create;
  try
    Before.Text := ABefore;
    After.Text := AAfter;
    if Before.Count <> After.Count then Exit('line count changed');
    for i := 0 to Before.Count - 1 do
      if Before[i] <> After[i] then
      begin
        if Result <> '' then Result := Result + '|';
        Result := Result + Copy(After[i], 1, Pos(' = ', After[i]) - 1);
      end;
  finally
    After.Free;
    Before.Free;
  end;
end;

procedure TLockSchemaUpgrade.BeforeAll;
begin
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('lock-v4');
  FFixtureRoot := FScratch + '/fx';
  ForceDirectories(FFixtureRoot);
  FCount := 0;
end;

procedure TLockSchemaUpgrade.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

function TLockSchemaUpgrade.NewRoot(const AName: string): string;
begin
  Inc(FCount);
  { Short case directories keep rollback paths inside legacy MAX_PATH. }
  Result := FScratch + '/c' + IntToStr(FCount);
  FCacheRoot := Result + '-cache';
  ForceDirectories(Result + '/source');
  WriteExactFile(Result + '-case', AName + #10);
end;

procedure TLockSchemaUpgrade.WriteRefs(const ARepository, AContent: string);
begin
  WriteExactFile(FFixtureRoot + '/refs/' + ARepository + '.refs', AContent);
end;

procedure TLockSchemaUpgrade.WriteArchive(const AName, ACommit,
  AVersion: string);
var Entries: TByteArrays;
begin
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry(AName + '-fixture/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "' + AName + '"'#10 + 'version = "'
      + AVersion + '"'#10 + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry(AName + '-fixture/source/' + AName
    + '.pas', BytesOf('unit ' + AName + ';'#10 + 'interface'#10
      + 'implementation'#10 + 'end.'#10));
  WriteBytesToFile(FFixtureRoot + '/archives/' + AName + '/' + ACommit
    + '.tar.gz', Gzip(BuildTar(Entries)));
end;

procedure TLockSchemaUpgrade.WriteLocalPackage(const ADirectory,
  AName: string);
var UnitName: string;
begin
  UnitName := StringReplace(AName, '-', '_', [rfReplaceAll]);
  WriteExactFile(ADirectory + '/lwpt.toml', '[package]'#10 + 'name = "'
    + AName + '"'#10 + 'version = "1.0.0"'#10 + 'units = ["source"]'#10);
  WriteExactFile(ADirectory + '/source/' + UnitName + '.pas', 'unit '
    + UnitName + ';'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
end;

function TLockSchemaUpgrade.Seed(const AName: string;
  out ARoot: string): string;
begin
  ARoot := NewRoot(AName);
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  WriteArchive('shared', SHARED_COMMIT, '1.0.0');
  WriteLocalPackage(ARoot + '/local-dep', 'local-dep');
  WriteLocalPackage(ARoot + '/packages/workspace-dep', 'workspace-dep');
  WriteExactFile(ARoot + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteExactFile(ARoot + '/lwpt.toml', '[package]'#10 + 'name = "'
    + AName + '"'#10 + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + '[dependencies]'#10 + 'shared = "fixture/shared@^1.0.0"'#10
    + 'local-dep = "./local-dep"'#10
    + 'workspace-dep = "workspace:^1.0.0"'#10
    + '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  ExpectSuccess('seed ' + AName, Run(ARoot, ['install']));
  Result := LockText(ARoot);
end;

function TLockSchemaUpgrade.Run(const ARoot: string;
  const AArguments: array of string): TLwptResult;
begin
  Result := RunLwptTesting(AArguments, ARoot,
    [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot,
     PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot]);
end;

function TLockSchemaUpgrade.Requests: string;
begin
  if FileExists(FFixtureRoot + '/requests.log') then
    Result := ReadBinaryFile(FFixtureRoot + '/requests.log')
  else
    Result := '';
end;

procedure TLockSchemaUpgrade.ClearRequests;
begin
  WriteExactFile(FFixtureRoot + '/requests.log', '');
end;

procedure TLockSchemaUpgrade.ExpectSuccess(const ALabel: string;
  const ARun: TLwptResult);
begin
  DumpRunFailure(ALabel, ARun, 0);
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

procedure TLockSchemaUpgrade.ExpectFailureWith(const ALabel: string;
  const ARun: TLwptResult; const AText: string);
var Output: string;
begin
  Output := ARun.Stdout + ARun.Stderr;
  if (ARun.ExitCode = 0) or (Pos(AText, Output) = 0) then
    WriteLn('--- ', ALabel, ': expected failure containing "', AText,
      '" ---'#10, Output, '---');
  Expect<Boolean>(ARun.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos(AText, Output) > 0).ToBe(True);
end;

function TLockSchemaUpgrade.ArchiveMessage: string;
begin
  Result := '`' + PROGRAM_NAME + ' repair` cannot upgrade `' + LOCKFILE
    + '` from schema v3: the archive for "shared" at `' + SHARED_ARCHIVE
    + '` is missing or does not match its locked `archiveHash`, and the '
    + 'per-user cache has no matching copy. Restore that exact archive, for '
    + 'example from version control, and run `' + PROGRAM_NAME + ' repair` '
    + 'again. To give up the version-stable migration, delete `' + LOCKFILE
    + '` and run `' + PROGRAM_NAME + ' install`; that needs network access '
    + 'and moves range dependencies to their newest matching versions.';
end;

{ ---------------------------------------------------------------------------
  The v4 writer
  --------------------------------------------------------------------------- }

procedure TLockSchemaUpgrade.TestInstallWritesSchemaV4;
var Root, Lock: string;
begin
  Lock := Seed('writes-v4', Root);
  Expect<Boolean>(Pos('version = 4', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('computedHash = "sha256:', Lock) = 0).ToBe(True);
  Expect<string>(LockEntryField(Lock, 'shared', 'computedHash'))
    .ToBe(HashTree(Root + '/.lwpt/modules/shared'));
  Expect<Boolean>(IsTreeDigest(LockEntryField(Lock, 'local-dep',
    'computedHash'))).ToBe(True);
  Expect<Boolean>(IsTreeDigest(LockEntryField(Lock, 'workspace-dep',
    'computedHash'))).ToBe(True);
  ExpectSuccess('frozen v4', Run(Root, ['install', '--frozen']));
end;

{ ---------------------------------------------------------------------------
  Every reader refuses v3 (decision 2)
  --------------------------------------------------------------------------- }

procedure TLockSchemaUpgrade.TestEveryReaderRefusesV3AndChangesNothing;
var Root, Before: string; Index: Integer;
const
  COMMANDS: array[0..6] of string = ('install', 'install --frozen',
    'install --offline', 'add fixture/other@^1.0.0', 'remove shared',
    'update', 'outdated');

  function Arguments(const ACommand: string): TStringArray;
  var Parts: TStringList; k: Integer;
  begin
    Parts := TStringList.Create;
    try
      Parts.Delimiter := ' ';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := ACommand;
      SetLength(Result, Parts.Count);
      for k := 0 to Parts.Count - 1 do Result[k] := Parts[k];
    finally
      Parts.Free;
    end;
  end;

begin
  Seed('refuse-v3', Root);
  WriteRefs('other', 'tag|v1.0.0|' + OTHER_COMMIT + '|'#10);
  WriteArchive('other', OTHER_COMMIT, '1.0.0');
  DowngradeLockToV3(Root);
  { An interrupted transaction's rollback files must survive too: install
    refuses before any recovery. }
  PlantLegacyModuleRollback(Root, 'shared');
  Before := ProjectSnapshot(Root, []);
  ClearRequests;
  for Index := 0 to High(COMMANDS) do
  begin
    ExpectFailureWith(COMMANDS[Index],
      Run(Root, Arguments(COMMANDS[Index])), LockfileSchemaV3Message);
    Expect<string>(ProjectSnapshot(Root, [])).ToBe(Before);
  end;
  Expect<string>(Requests).ToBe('');
end;

{ ---------------------------------------------------------------------------
  `lwpt repair` (decision 3)
  --------------------------------------------------------------------------- }

procedure TLockSchemaUpgrade.TestRepairUpgradesWithoutNetworkOrVersionChange;
var Root, V4, V3, Modules: string; Outcome: TLwptResult;
begin
  V4 := Seed('repair-upgrade', Root);
  Modules := ProjectSnapshot(Root + '/.lwpt', ['tmp', 'sessions']);
  V3 := DowngradeLockToV3(Root);
  { A newer satisfying tag is advertised; the upgrade must not see it. }
  WriteRefs('shared', 'tag|v1.0.0|' + SHARED_COMMIT + '|'#10
    + 'tag|v1.1.0|' + NEWER_COMMIT + '|'#10);
  WriteArchive('shared', NEWER_COMMIT, '1.1.0');
  ClearRequests;
  Outcome := Run(Root, ['repair']);
  ExpectSuccess('repair upgrade', Outcome);
  Expect<string>(Requests).ToBe('');
  Expect<Boolean>(Pos('upgraded ' + LOCKFILE + ' from schema v3 to v4',
    Outcome.Stdout) > 0).ToBe(True);
  { Versions, commits, and every other field are unchanged: the upgraded
    lock is exactly what an install writes for the same selection. }
  Expect<string>(LockText(Root)).ToBe(V4);
  Expect<string>(ChangedLines(V3, LockText(Root))).ToBe(
    'version|computedHash|computedHash|computedHash');
  Expect<string>(LockEntryField(LockText(Root), 'shared', 'resolvedRef'))
    .ToBe('v1.0.0');
  Expect<string>(ProjectSnapshot(Root + '/.lwpt', ['tmp', 'sessions']))
    .ToBe(Modules);
  ExpectSuccess('frozen after repair', Run(Root, ['install', '--frozen']));
end;

procedure TLockSchemaUpgrade.TestNoChurnAfterTheUpgrade;
var Root, V4: string;
begin
  V4 := Seed('no-churn', Root);
  DowngradeLockToV3(Root);
  ExpectSuccess('repair', Run(Root, ['repair']));
  Expect<string>(LockText(Root)).ToBe(V4);
  { Decision 11: an online install with an unchanged selection and an
    offline restore leave the upgraded lock byte-identical. }
  ExpectSuccess('online install', Run(Root, ['install']));
  Expect<string>(LockText(Root)).ToBe(V4);
  ExpectSuccess('offline install', Run(Root, ['install', '--offline']));
  Expect<string>(LockText(Root)).ToBe(V4);
end;

{ The lock an early schema-v3 writer produced: `source`, `resolvedRef`,
  `resolvedURL`, `computedHash`, and `archiveHash` only, with no
  `resolvedCommit`, `sourceIdentity`, or `constraintFingerprint`. Unknown
  keys and tables, which every reader tolerates, are added so that the
  upgrade must keep them. Built from scratch, never from a v4 lock. }
function HistoricalV3Lock(const ARoot, AEnding: string;
  const ASharedHashLine: string = ''; const ASharedExtra: string = ''): string;

  procedure Line(const AText: string);
  begin
    Result := Result + AText + AEnding;
  end;

  procedure Entry(const AName, ASource, ARef, AURL, AArchive: string);
  begin
    Line('');
    Line('[package.' + AName + ']');
    Line('source = "' + ASource + '"');
    Line('resolvedRef = "' + ARef + '"');
    Line('resolvedURL = "' + AURL + '"');
    if (AName = 'shared') and (ASharedHashLine <> '') then
      Line(ASharedHashLine)
    else
      Line('computedHash = "' + LegacyHashTree(ARoot + '/.lwpt/modules/'
        + AName) + '"');
    Line('archiveHash = "' + AArchive + '"');
    if AName = 'shared' then Result := Result + ASharedExtra;
  end;

begin
  Result := '';
  Line('# ' + LOCKFILE + ' - generated by ' + PROGRAM_NAME
    + '; do not edit by hand.');
  Line('version = 3');
  Entry('shared', 'fixture/shared', 'v1.0.0',
    'https://github.com/fixture/shared/archive/' + SHARED_COMMIT + '.tar.gz',
    'sha256:' + SHA256File(ARoot + '/' + SHARED_ARCHIVE));
  Line('futureKey = "kept by every reader"');
  Entry('local-dep', './local-dep', '', '', '');
  Entry('workspace-dep', 'workspace:^1.0.0', '1.0.0', '', '');
  Line('');
  Line('[futureTable]');
  Line('note = "unknown tables are tolerated"');
end;

procedure TLockSchemaUpgrade.TestHistoricalV3LockChangesOnlyItsDigests;
var
  Root, V4, Historical, Upgraded, Expected: string;
  Ending: string;
  Index: Integer;
const
  ENDINGS: array[0..1] of string = (#10, #13#10);
begin
  { ADR-0052 step 4: the upgrade changes `version` and every computedHash,
    and nothing else; fields an older writer omitted stay absent, unknown
    keys and tables stay, and each line keeps its ending. }
  for Index := 0 to High(ENDINGS) do
  begin
    Ending := ENDINGS[Index];
    V4 := Seed('historical-' + IntToStr(Index), Root);
    Historical := HistoricalV3Lock(Root, Ending);
    WriteExactFile(Root + '/lwpt.lock', Historical);
    ClearRequests;
    ExpectSuccess('repair historical', Run(Root, ['repair']));
    Expect<string>(Requests).ToBe('');
    Upgraded := LockText(Root);
    Expected := StringReplace(Historical, 'version = 3' + Ending,
      'version = 4' + Ending, []);
    Expected := StringReplace(Expected, 'computedHash = "'
      + LegacyHashTree(Root + '/.lwpt/modules/shared') + '"',
      'computedHash = "' + LockEntryField(V4, 'shared', 'computedHash')
      + '"', []);
    Expected := StringReplace(Expected, 'computedHash = "'
      + LegacyHashTree(Root + '/.lwpt/modules/local-dep') + '"',
      'computedHash = "' + LockEntryField(V4, 'local-dep', 'computedHash')
      + '"', []);
    Expected := StringReplace(Expected, 'computedHash = "'
      + LegacyHashTree(Root + '/.lwpt/modules/workspace-dep') + '"',
      'computedHash = "' + LockEntryField(V4, 'workspace-dep',
      'computedHash') + '"', []);
    Expect<string>(Upgraded).ToBe(Expected);
    Expect<string>(ChangedLines(Historical, Upgraded)).ToBe(
      'version|computedHash|computedHash|computedHash');
    Expect<Boolean>(Pos('sourceIdentity', Upgraded) = 0).ToBe(True);
    Expect<Boolean>(Pos('resolvedCommit', Upgraded) = 0).ToBe(True);
    ExpectSuccess('frozen after historical repair',
      Run(Root, ['install', '--frozen']));
    ExpectSuccess('offline after historical repair',
      Run(Root, ['install', '--offline']));
    Expect<string>(LockText(Root)).ToBe(Upgraded);
  end;
end;

{ Repair must fail closed on AHistorical: a migration error naming AReason,
  the lock byte-identical, and the project unchanged. }
procedure TLockSchemaUpgrade.ExpectRefusedLock(const ALabel, ARoot,
  AHistorical, AReason: string);
var Before: string;
begin
  WriteExactFile(ARoot + '/lwpt.lock', AHistorical);
  Before := ProjectSnapshot(ARoot, REPAIR_OWNED);
  ExpectFailureWith(ALabel, Run(ARoot, ['repair']), '`' + PROGRAM_NAME
    + ' repair` cannot upgrade `' + LOCKFILE + '` from schema v3: it cannot '
    + 'be edited safely: ');
  ExpectFailureWith(ALabel + ' reason', Run(ARoot, ['repair']), AReason);
  Expect<string>(LockText(ARoot)).ToBe(AHistorical);
  Expect<string>(ProjectSnapshot(ARoot, REPAIR_OWNED)).ToBe(Before);
end;

procedure TLockSchemaUpgrade.TestMultilineValuesFailClosed;
var Root, Legacy: string;
begin
  { The writer never emits a multiline string or a multi-line array, so a
    lock holding one is refused rather than edited around. The escaped
    triple quote is the review's case: a tracker that took it for the
    closing delimiter would edit the header and key inside the string. }
  Seed('multiline', Root);
  Legacy := LegacyHashTree(Root + '/.lwpt/modules/shared');
  ExpectRefusedLock('multiline string', Root, HistoricalV3Lock(Root, #10, '',
    'notes = ''''''' + #10 + 'computedHash = "' + Legacy + '"' + #10
    + '[package.local-dep]' + #10 + '''''''' + #10),
    'it contains a multiline string');
  ExpectRefusedLock('escaped triple quote', Root, HistoricalV3Lock(Root, #10,
    '', 'notes = """' + #10 + '\"""' + #10 + '[package.local-dep]' + #10
    + 'computedHash = "preserve this text"' + #10 + '# """' + #10),
    'it contains a multiline string');
  ExpectRefusedLock('multi-line array', Root, HistoricalV3Lock(Root, #10, '',
    'history = [' + #10 + '  ["computedHash", "kept"],' + #10 + ']' + #10),
    'line ');
end;

procedure TLockSchemaUpgrade.TestUnsafeLockFormsFailClosed;
var Root, Legacy, Historical: string;
begin
  Seed('unsafe', Root);
  Legacy := LegacyHashTree(Root + '/.lwpt/modules/shared');
  { A quoted key the editor would miss and then duplicate. }
  ExpectRefusedLock('quoted key', Root, HistoricalV3Lock(Root, #10,
    '"computedHash" = "' + Legacy + '"'), 'which is not a bare key');
  { The review's aliasing case: a single root key whose escaped \u0001
    separators spell the permitted path package.shared.computedHash, holding
    a string with an escaped triple quote and an embedded header. }
  Historical := HistoricalV3Lock(Root, #10);
  Historical := StringReplace(Historical, 'version = 3' + #10,
    'version = 3' + #10 + '"package\u0001shared\u0001computedHash" = """'
    + #10 + '\"""' + #10 + '[package.shared]' + #10
    + 'computedHash = "preserve this text"' + #10 + '# """' + #10, []);
  ExpectRefusedLock('aliasing key', Root, Historical,
    'it contains a multiline string');
  { The same aliasing key with a single-line value: refused as a quoted key
    before any edit, and the component-wise comparison could not alias it
    either. }
  Historical := StringReplace(HistoricalV3Lock(Root, #10),
    'version = 3' + #10, 'version = 3' + #10
    + '"package\u0001shared\u0001computedHash" = "preserve this text"' + #10,
    []);
  ExpectRefusedLock('aliasing key, single line', Root, Historical,
    'which is not a bare key');
  { An inline table the writer never emits. }
  ExpectRefusedLock('inline table', Root, HistoricalV3Lock(Root, #10, '',
    'extra = { computedHash = "x" }' + #10), 'has a value');
  { A dotted key is not a bare key either. }
  ExpectRefusedLock('dotted key', Root, HistoricalV3Lock(Root, #10, '',
    'meta.computedHash = "x"' + #10), 'which is not a bare key');
  { An array-of-tables header the writer never emits. }
  ExpectRefusedLock('array of tables', Root, HistoricalV3Lock(Root, #10) + #10
    + '[[extra]]' + #10 + 'note = "x"' + #10, 'is not a table header');
end;

procedure TLockSchemaUpgrade.TestRepairReplacesASubstitutedModule;
var Root, V4, Module, Legacy: string; Outcome: TLwptResult;
begin
  { A v4 lock rewritten as v3 with the legacy digest of a forged tree: the
    #352 substitution keeps the legacy digest, so the forged v3 lock
    "matches". Every reader refuses it, and repair re-derives the module
    from its archive instead of trusting that digest. }
  V4 := Seed('repair-forged', Root);
  Module := Root + '/.lwpt/modules/shared';
  Legacy := LegacyHashTree(Module);
  SubstituteModuleLayout(Module, 'source/shared.pas');
  Expect<string>(LegacyHashTree(Module)).ToBe(Legacy);
  DowngradeLockToV3(Root);
  Expect<string>(LockEntryField(LockText(Root), 'shared', 'computedHash'))
    .ToBe(Legacy);
  ExpectFailureWith('frozen on forged v3',
    Run(Root, ['install', '--frozen']), LockfileSchemaV3Message);
  ClearRequests;
  Outcome := Run(Root, ['repair']);
  ExpectSuccess('repair forged', Outcome);
  Expect<string>(Requests).ToBe('');
  Expect<Boolean>(Pos('module "shared"', Outcome.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('replacing it with the re-derived tree',
    Outcome.Stdout) > 0).ToBe(True);
  Expect<Boolean>(FileExists(Module + '/unit shared;')).ToBe(False);
  Expect<string>(HashTree(Module))
    .ToBe(LockEntryField(V4, 'shared', 'computedHash'));
  Expect<string>(LockText(Root)).ToBe(V4);
end;

procedure TLockSchemaUpgrade.TestRepairMissingArchiveFailsWithMigrationMessage;
var Root, V3, Before: string;
begin
  Seed('repair-missing', Root);
  V3 := DowngradeLockToV3(Root);
  Expect<Boolean>(DeleteFile(Root + '/' + SHARED_ARCHIVE)).ToBe(True);
  { No per-user copy either. }
  RecursiveDelete(FCacheRoot);
  Before := ProjectSnapshot(Root, REPAIR_OWNED);
  ClearRequests;
  ExpectFailureWith('repair missing archive', Run(Root, ['repair']),
    ArchiveMessage);
  Expect<string>(Requests).ToBe('');
  Expect<string>(LockText(Root)).ToBe(V3);
  Expect<string>(ProjectSnapshot(Root, REPAIR_OWNED)).ToBe(Before);
end;

procedure TLockSchemaUpgrade.TestRepairCorruptArchiveFailsWithMigrationMessage;
var Root, V3, Before, Archive: string; Bytes: TBytes;
begin
  Seed('repair-corrupt', Root);
  V3 := DowngradeLockToV3(Root);
  Archive := ReadBinaryFile(Root + '/' + SHARED_ARCHIVE);
  Bytes := BytesOf(Archive);
  Bytes[Length(Bytes) div 2] := Bytes[Length(Bytes) div 2] xor $01;
  WriteBytesToFile(Root + '/' + SHARED_ARCHIVE, Bytes);
  RecursiveDelete(FCacheRoot);
  Before := ProjectSnapshot(Root, REPAIR_OWNED);
  ExpectFailureWith('repair corrupt archive', Run(Root, ['repair']),
    ArchiveMessage);
  Expect<string>(LockText(Root)).ToBe(V3);
  Expect<string>(ProjectSnapshot(Root, REPAIR_OWNED)).ToBe(Before);
end;

procedure TLockSchemaUpgrade.TestRepairManifestDisagreementLeavesV3;
var Root, V3, Manifest, Before: string;
begin
  Seed('repair-drift', Root);
  V3 := DowngradeLockToV3(Root);
  Manifest := ReadBinaryFile(Root + '/lwpt.toml');
  WriteExactFile(Root + '/lwpt.toml', StringReplace(Manifest,
    'fixture/shared@^1.0.0', 'fixture/shared@^2.0.0', []));
  Before := ProjectSnapshot(Root, REPAIR_OWNED);
  ClearRequests;
  ExpectFailureWith('repair drift', Run(Root, ['repair']),
    'the manifest does not agree with the lockfile');
  ExpectFailureWith('repair drift hint', Run(Root, ['repair']),
    'Restore the ' + MANIFEST_FILE + ' that `' + LOCKFILE
    + '` was written from, run `' + PROGRAM_NAME + ' repair`, and then '
    + 'change the manifest.');
  Expect<string>(Requests).ToBe('');
  Expect<string>(LockText(Root)).ToBe(V3);
  Expect<string>(ProjectSnapshot(Root, REPAIR_OWNED)).ToBe(Before);
end;

procedure TLockSchemaUpgrade.TestRepairLeavesV4Alone;
var Root, V4, Before: string; Outcome: TLwptResult;
begin
  V4 := Seed('repair-v4', Root);
  Before := ProjectSnapshot(Root, REPAIR_OWNED);
  Outcome := Run(Root, ['repair']);
  ExpectSuccess('repair v4', Outcome);
  Expect<Boolean>(Pos(LOCKFILE + ' is schema v4; no upgrade needed',
    Outcome.Stdout) > 0).ToBe(True);
  Expect<string>(LockText(Root)).ToBe(V4);
  Expect<string>(ProjectSnapshot(Root, REPAIR_OWNED)).ToBe(Before);
end;

{ ---------------------------------------------------------------------------
  Rollback files a pre-v4 binary wrote
  --------------------------------------------------------------------------- }

procedure TLockSchemaUpgrade.TestLegacyRollbackRecoveredByRepairOnV3;
var Root, V4, UnitPath: string;
begin
  { A restore that did not accept the legacy digest would fail recovery
    and so the whole command. }
  V4 := Seed('legacy-rollback-v3', Root);
  DowngradeLockToV3(Root);
  PlantLegacyModuleRollback(Root, 'shared');
  UnitPath := Root + '/.lwpt/modules/shared/source/shared.pas';
  Expect<Boolean>(DeleteFile(UnitPath)).ToBe(True);
  ExpectSuccess('repair legacy rollback', Run(Root, ['repair']));
  Expect<Boolean>(FileExists(UnitPath)).ToBe(True);
  Expect<Boolean>(HasPendingRollback(Root + '/.lwpt/tmp')).ToBe(False);
  Expect<string>(LockText(Root)).ToBe(V4);
end;

procedure TLockSchemaUpgrade.TestLegacyRollbackRecoveredByInstallOnV4;
var Root, V4, UnitPath: string; Outcome: TLwptResult;
begin
  V4 := Seed('legacy-rollback-v4', Root);
  PlantLegacyModuleRollback(Root, 'shared');
  UnitPath := Root + '/.lwpt/modules/shared/source/shared.pas';
  Expect<Boolean>(DeleteFile(UnitPath)).ToBe(True);
  Outcome := Run(Root, ['install', '--offline']);
  ExpectSuccess('install legacy rollback', Outcome);
  Expect<Boolean>(FileExists(UnitPath)).ToBe(True);
  Expect<Boolean>(HasPendingRollback(Root + '/.lwpt/tmp')).ToBe(False);
  Expect<string>(LockText(Root)).ToBe(V4);
end;

{ ---------------------------------------------------------------------------
  --frozen under v4 (section 4)
  --------------------------------------------------------------------------- }

procedure TLockSchemaUpgrade.TestSubstitutionFailsFrozenForLockedKinds;
var Root, V4, Before, Module, Saved: string; Index: Integer;
const
  NAMES: array[0..2] of string = ('shared', 'local-dep', 'workspace-dep');
  UNITS: array[0..2] of string = ('source/shared.pas',
    'source/local_dep.pas', 'source/workspace_dep.pas');
begin
  V4 := Seed('frozen-layout', Root);
  for Index := 0 to High(NAMES) do
  begin
    Module := Root + '/.lwpt/modules/' + NAMES[Index];
    Saved := Root + '/saved-' + IntToStr(Index);
    RecursiveDelete(Saved);
    CopyDirTree(Module, Saved);
    Before := LegacyHashTree(Module);
    SubstituteModuleLayout(Module, UNITS[Index]);
    Expect<string>(LegacyHashTree(Module)).ToBe(Before);
    ExpectFailureWith('frozen layout ' + NAMES[Index],
      Run(Root, ['install', '--frozen']),
      'tree hash mismatch for "' + NAMES[Index] + '"');
    Expect<string>(LockText(Root)).ToBe(V4);
    RecursiveDelete(Module);
    CopyDirTree(Saved, Module);
    RecursiveDelete(Saved);
  end;
  ExpectSuccess('frozen restored', Run(Root, ['install', '--frozen']));
end;

procedure TLockSchemaUpgrade.TestSubstitutionFailsFrozenForURL;
var
  Root, Lock, Module, Archives: string;
  Entries: TByteArrays;
  Mock: TMockHTTPServer;
  Outcome: TLwptResult;
begin
  Root := NewRoot('frozen-url');
  WriteExactFile(Root + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteExactFile(Root + '/lwpt.toml', '[package]'#10 + 'name = "url"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'direct = "https://example.invalid/direct.tar.gz"'#10);
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry('direct-fixture/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "direct"'#10 + 'version = "1.0.0"'#10
      + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry('direct-fixture/source/direct.pas',
    BytesOf('unit direct;'#10 + 'interface'#10 + 'implementation'#10
      + 'end.'#10));
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(Gzip(BuildTar(Entries))));
  try
    Mock.Start;
    Outcome := RunLwptTesting(['install'], Root,
      [PROJECT_NAME + '_CACHE_DIR=' + FCacheRoot,
       ARCHIVE_ORIGIN_ENV + '=http://127.0.0.1:' + IntToStr(Mock.Port),
       ARCHIVE_TIMEOUT_ENV + '=5000']);
    Expect<Boolean>(Mock.WaitDone(5000)).ToBe(True);
  finally
    Mock.Free;
  end;
  ExpectSuccess('url install', Outcome);
  Lock := LockText(Root);
  Expect<Boolean>(IsTreeDigest(LockEntryField(Lock, 'direct', 'computedHash')))
    .ToBe(True);
  Archives := ProjectSnapshot(Root + '/.lwpt/archives', []);
  Module := Root + '/.lwpt/modules/direct';
  SubstituteModuleLayout(Module, 'source/direct.pas');
  ExpectFailureWith('url frozen layout', RunLwpt(['install', '--frozen'], Root),
    'tree hash mismatch for "direct"');
  Expect<string>(LockText(Root)).ToBe(Lock);
  Expect<string>(ProjectSnapshot(Root + '/.lwpt/archives', [])).ToBe(Archives);
end;

{$IFDEF UNIX}
procedure TLockSchemaUpgrade.TestFrozenRefusesLinksInModules;
var Root, Module: string;
begin
  Seed('frozen-links', Root);
  Module := Root + '/.lwpt/modules/shared';
  { A file link that reads the same bytes still fails: LWPT never installs
    links. }
  Expect<Integer>(FpSymlink('shared.pas', PAnsiChar(Module
    + '/source/copy.pas'))).ToBe(0);
  ExpectFailureWith('frozen file link', Run(Root, ['install', '--frozen']),
    '.lwpt/modules/shared/source/copy.pas. ' + PROGRAM_NAME
    + ' never installs links');
  DeleteFile(Module + '/source/copy.pas');
  { A directory link is invisible to the digest, but FPC would read it. }
  Expect<Integer>(FpSymlink(PAnsiChar(Root + '/local-dep/source'),
    PAnsiChar(Module + '/extra'))).ToBe(0);
  ExpectFailureWith('frozen directory link',
    Run(Root, ['install', '--frozen']),
    '.lwpt/modules/shared/extra. ' + PROGRAM_NAME + ' never installs links');
  DeleteFile(Module + '/extra');
  Expect<Integer>(FpSymlink('missing.pas', PAnsiChar(Module
    + '/source/gone.pas'))).ToBe(0);
  ExpectFailureWith('frozen dangling link',
    Run(Root, ['install', '--frozen']),
    '.lwpt/modules/shared/source/gone.pas. ' + PROGRAM_NAME
    + ' never installs links');
  DeleteFile(Module + '/source/gone.pas');
  ExpectSuccess('frozen without links', Run(Root, ['install', '--frozen']));
end;
{$ELSE}
procedure TLockSchemaUpgrade.TestFrozenRefusesLinksInModules;
begin
end;
{$ENDIF}

procedure TLockSchemaUpgrade.SetupTests;
begin
  Test('install writes schema v4 with sha256-tree2 digests',
    TestInstallWritesSchemaV4);
  Test('every lock reader refuses a v3 lock and changes nothing',
    TestEveryReaderRefusesV3AndChangesNothing);
  Test('repair upgrades v3 without network and without moving versions',
    TestRepairUpgradesWithoutNetworkOrVersionChange);
  Test('an install after the upgrade leaves the v4 lock byte-identical',
    TestNoChurnAfterTheUpgrade);
  Test('repair of a historical v3 lock changes only version and digests',
    TestHistoricalV3LockChangesOnlyItsDigests);
  Test('repair refuses multiline strings and arrays the writer never emits',
    TestMultilineValuesFailClosed);
  Test('repair refuses quoted, aliasing, dotted, and inline-table forms',
    TestUnsafeLockFormsFailClosed);
  Test('repair replaces a substituted module a forged v3 digest matched',
    TestRepairReplacesASubstitutedModule);
  Test('repair names a missing archive with the migration message',
    TestRepairMissingArchiveFailsWithMigrationMessage);
  Test('repair names a corrupt archive with the migration message',
    TestRepairCorruptArchiveFailsWithMigrationMessage);
  Test('repair refuses a manifest that disagrees with the v3 lock',
    TestRepairManifestDisagreementLeavesV3);
  Test('repair leaves a v4 lock alone', TestRepairLeavesV4Alone);
  Test('repair recovers a legacy rollback file on a v3 lock',
    TestLegacyRollbackRecoveredByRepairOnV3);
  Test('install recovers a legacy rollback file on a v4 lock',
    TestLegacyRollbackRecoveredByInstallOnV4);
  Test('#352: --frozen fails a git-host, local, or workspace layout '
    + 'substitution', TestSubstitutionFailsFrozenForLockedKinds);
  Test('#352: --frozen fails a URL layout substitution',
    TestSubstitutionFailsFrozenForURL);
  {$IFDEF UNIX}
  Test('--frozen refuses file, directory, and dangling links in a module',
    TestFrozenRefusesLinksInModules);
  {$ELSE}
  Skip('--frozen refuses file, directory, and dangling links in a module',
    TestFrozenRefusesLinksInModules, 'link fixtures need FpSymlink');
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TLockSchemaUpgrade.Create(
    'lockfile schema v4 and the v3 upgrade'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
