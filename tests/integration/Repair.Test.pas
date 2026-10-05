{ Repair.Test — pins lwpt repair semantics.

  `lwpt repair` clears two kinds of post-crash residue:
    - .lwpt/install.lock (the cross-process install lock), only once its
      owner has exited
    - .lwpt/tmp/ (the atomic-write staging area), under the install lock

  It must NOT touch .lwpt/modules/ or .lwpt/archives/ (the committed
  zero-install state). Repair is the documented recovery path when an
  install crashes mid-run; it must be safe on a clean tree and
  effective on a dirty one.

  Assertions:
    1. Repair on a clean tree is a no-op exit 0 (idempotent).
    2. A dead owner's .lwpt/install.lock is removed.
    3. .lwpt/tmp/ contents are removed; the directory itself stays.
       .lwpt/modules/ and .lwpt/archives/ contents are untouched.
    4. Failed build-session staging is reclaimed.
    5. Dead machine-wide worker requests are reclaimed and diagnosed.
    6. Historical relocated sessions remain reclaimable after the override
       is absent.
    7. Shared-cache corruption and incomplete state are repaired repeatably.
    8. Transitive build references with missing artifacts are removed.
    9. Retired executable images beside build outputs are removed.
   10. A build output directory reached through a link is never swept
       (Unix; directory symlinks need no privilege there).
   11. An abandoned session and a retired image whose paths pass the
       Windows MAX_PATH are still reclaimed (#347).
   12. Against a live install's lock, repair fails, names the holder, and
       leaves the lock, .lwpt/tmp/ and committed state byte-identical
       (#384).
   13. A crashed install's lock is reclaimed and its pending transaction
       recovered.
   14. While repair holds the lock, an install and a second repair fail
       fast naming it, and the second repair sweeps nothing.
   15. Repair never reclaims what it cannot prove dead: a PID-only record
       (older binary), a lock file without an owner record, or any lock on
       a filesystem without record locks. It does reclaim a record-lock
       owner record whose PID was reused, including its own PID.
   16. An install whose freshly created lock file was replaced before it
       took the record lock fails instead of running beside the new owner.
       }

program Repair.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  DateUtils,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Core,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.PayloadHandoff,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  { Bounds one held child's whole run and the wait for it. }
  HELD_RUN_MILLISECONDS = 3 * 60 * 1000;
  HELD_WAIT_MILLISECONDS = HELD_RUN_MILLISECONDS + 30 * 1000;
  { A PID no process can have: above every Unix pid_max and outside the
    range Windows assigns. }
  UNUSED_PID = '2147483644';
  { The owner record of a dead owner that held the record lock. }
  DEAD_OWNER_RECORD = UNUSED_PID + #10'holder=install'#10'lock=record';

type
  TRepairE2E = class(TTestSuite)
  private
    FCacheRoot, FOrigDir, FScratch, FWorkerState: string;
    procedure SetupScratchProject;
    procedure WriteCacheBytes(const APath, ABytes: string);
    function RunRepair: TLwptResult; overload;
    function RunRepair(const AProject: string): TLwptResult; overload;
    function RepairEnvironment: TStringArray;
    function WriteLockProject(const AName: string): string;
    procedure CrashInstall(const AProject: string);
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestRepairOnCleanTreeIsNoop;
    procedure TestRepairClearsStaleInstallLock;
    procedure TestRepairCleansTmpButLeavesCommittedState;
    procedure TestRepairReclaimsFailedBuildSession;
    procedure TestRepairReclaimsHistoricalRelocatedSession;
    procedure TestRepairRecoversSharedCache;
    procedure TestRepairRemovesTransitiveBuildReference;
    procedure TestRepairReclaimsWorkerRequests;
    procedure TestRepairRemovesRetiredExecutableImages;
    procedure TestRepairReclaimsDeepSessionAndRetiredImage;
    procedure TestRepairRefusesLiveInstallLock;
    procedure TestRepairReclaimsDeadOwnerAndRecovers;
    procedure TestRunningRepairExcludesInstallAndRepair;
    procedure TestRepairRefusesLegacyLock;
    procedure TestRepairReclaimsRecordLockWithReusedPID;
    procedure TestRepairReclaimsRecordOfItsOwnPID;
    procedure TestRepairRefusesLockWithoutOwnerRecord;
    procedure TestRepairRefusesWithoutRecordLocks;
    procedure TestDisplacedCreatorFails;
    {$IFDEF UNIX}
    procedure TestRepairSkipsRedirectedOutputDirectory;
    {$ENDIF}
  end;

  { One lwpt-testing run on a test thread, so a held child and its
    contenders can overlap. }
  TLwptThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Project, Error: string;
    Arguments, Environment: TStringArray;
    Run: TLwptResult;
  end;

procedure TLwptThread.Execute;
begin
  try
    Run := RunLwptTesting(Arguments, Project, Environment,
      HELD_RUN_MILLISECONDS);
  except
    on E: Exception do Error := E.Message;
  end;
end;

function StartLwptTesting(const AArguments: array of string;
  const AProject: string; const AEnvironment: array of string): TLwptThread;
var Index: Integer;
begin
  Result := TLwptThread.Create(True);
  Result.Project := AProject;
  SetLength(Result.Arguments, Length(AArguments));
  for Index := 0 to High(AArguments) do
    Result.Arguments[Index] := AArguments[Index];
  SetLength(Result.Environment, Length(AEnvironment));
  for Index := 0 to High(AEnvironment) do
    Result.Environment[Index] := AEnvironment[Index];
  Result.Start;
end;

{ True when AThread ended within the bounded wait. A thread that did not is
  left running rather than freed. }
function AwaitFinished(AThread: TLwptThread): Boolean;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not AThread.Finished
     and (GetTickCount64 - StartedAt < HELD_WAIT_MILLISECONDS) do
    Sleep(20);
  Result := AThread.Finished;
end;

{ Waits for APath's completion marker, or for AThread to end first. }
function AwaitPayload(const APath: string; AThread: TLwptThread): Boolean;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not PayloadIsReadable(APath) and not AThread.Finished
     and (GetTickCount64 - StartedAt < HELD_WAIT_MILLISECONDS) do
    Sleep(20);
  Result := PayloadIsReadable(APath);
end;

procedure AddTreeSnapshot(const ARoot, ARelative: string;
  const ALines: TStringList);
var Search: TSearchRec; Relative: string;
begin
  if FindFirst(ARoot + ARelative + '/*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Relative := ARelative + '/' + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        ALines.Add(Relative + '/');
        AddTreeSnapshot(ARoot, Relative, ALines);
      end
      else
        ALines.Add(Relative + ' = ' + ReadBinaryFile(ARoot + Relative));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

{ Every path below ARoot with the bytes of every file, in name order. }
function TreeSnapshot(const ARoot: string): string;
var Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    AddTreeSnapshot(ARoot, '', Lines);
    Lines.Sort;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function HasRollbackMarker(const ATmpRoot: string): Boolean;
var Outer, Inner: TSearchRec;
begin
  Result := False;
  if FindFirst(ATmpRoot + '/*', faAnyFile, Outer) <> 0 then Exit;
  try
    repeat
      if (Outer.Name = '.') or (Outer.Name = '..')
         or ((Outer.Attr and faDirectory) = 0) then
        Continue;
      if FindFirst(ATmpRoot + '/' + Outer.Name + '/*.rollback', faAnyFile,
        Inner) = 0 then
      begin
        FindClose(Inner);
        Exit(True);
      end;
    until FindNext(Outer) <> 0;
  finally
    FindClose(Outer);
  end;
end;

function FirstLine(const AText: string): string;
var Ending: Integer;
begin
  Result := AText;
  Ending := Pos(#10, Result);
  if Ending > 0 then SetLength(Result, Ending - 1);
  Result := Trim(Result);
end;

procedure TRepairE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/source');

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "repair-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    #10 +
    '[build]'#10 +
    'app = { source = "source/dummy.pas", output = "build/app" }'#10);

  WriteTextFile(FScratch + '/source/dummy.pas',
    'unit Dummy;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);
end;

procedure TRepairE2E.WriteCacheBytes(const APath, ABytes: string);
var
  Raw: RawByteString;
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    Raw := RawByteString(ABytes);
    if Length(Raw) > 0 then Stream.WriteBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
end;

function TRepairE2E.RepairEnvironment: TStringArray;
begin
  Result := [
    'LWPT_CACHE_DIR=' + FCacheRoot,
    'LWPT_WORKER_STATE_DIR=' + FWorkerState,
    'LWPT_WORKER_BUDGET=1',
    PROJECT_NAME + '_REGISTRY_STATE_DIR=' + FScratch + '/registry-state'
  ];
end;

function TRepairE2E.RunRepair: TLwptResult;
begin
  Result := RunRepair(FScratch);
end;

function TRepairE2E.RunRepair(const AProject: string): TLwptResult;
begin
  Result := RunLwpt(['repair'], AProject, RepairEnvironment);
end;

{ A project whose local dependency branch-a replaces a committed module
  tree holding old.txt, so an interrupted publication leaves a pending
  transaction that recovery visibly restores. }
function TRepairE2E.WriteLockProject(const AName: string): string;
begin
  Result := FScratch + '/' + AName;
  RecursiveDelete(Result);
  RecursiveDelete(Result + '-a');
  WriteTextFile(Result + '/lwpt.toml',
    '[package]'#10 + 'name = "' + AName + '"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10 + '[dependencies]'#10
    + 'branch-a = "../' + AName + '-a"'#10);
  WriteTextFile(Result + '/source/root.pas',
    'unit root;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  WriteTextFile(Result + '-a/lwpt.toml',
    '[package]'#10 + 'name = "branch-a"'#10 + 'version = "1.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(Result + '-a/source/branch-a.pas',
    'unit branch_a;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  WriteTextFile(Result + '/.lwpt/modules/branch-a/old.txt', 'old');
end;

{ Ends an install abruptly after it published branch-a, as a crash would:
  the lock file and the pending transaction stay behind. }
procedure TRepairE2E.CrashInstall(const AProject: string);
var R: TLwptResult;
begin
  R := RunLwptTesting(['install'], AProject,
    ['LWPT_CACHE_DIR=' + FCacheRoot,
     PROJECT_NAME + '_TEST_HALT_PUBLISH_AFTER=1']);
  DumpRunFailure('crashed install', R, 86);
  Expect<Integer>(R.ExitCode).ToBe(86);
  Expect<Boolean>(FileExists(AProject + '/.lwpt/install.lock')).ToBe(True);
  Expect<Boolean>(FileExists(
    AProject + '/.lwpt/modules/branch-a/source/branch-a.pas')).ToBe(True);
  Expect<Boolean>(HasRollbackMarker(AProject + '/.lwpt/tmp')).ToBe(True);
end;

procedure TRepairE2E.TestRepairReclaimsWorkerRequests;
var
  StateRoot, RequestPath : string;
  R : TLwptResult;
begin
  StateRoot := FWorkerState;
  RequestPath := StateRoot + '/dead-agent.request';
  ForceDirectories(StateRoot);
  WriteTextFile(RequestPath,
    'schema=3'#10
    + 'session=dead-agent'#10
    + 'pid=999999'#10
    + 'requested=1'#10
    + 'granted=1'#10
    + 'waiting=0'#10
    + 'started=1'#10
    + 'heartbeat=1'#10
    + 'lease-started=1'#10
    + 'wait-ticket=0'#10
    + 'lease-tokens=' + StringOfChar('a', 64) + #10
    + 'delegations='#10);

  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(RequestPath)).ToBe(False);
  Expect<Boolean>(Pos('reclaimed 1 abandoned worker invocation',
    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('worker budget: 1 total', R.Stdout) > 0).ToBe(True);
end;

procedure TRepairE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('repair-e2e');
  FCacheRoot := FScratch + '/shared-cache';
  FWorkerState := FScratch + '/worker-state';
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;

  { Run install once so .lwpt/ has the canonical committed state. }
  RunLwpt(['install'], FScratch, ['LWPT_CACHE_DIR=' + FCacheRoot]);
end;

procedure TRepairE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TRepairE2E.TestRepairOnCleanTreeIsNoop;
var R: TLwptResult;
begin
  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);
  { Without a per-user registry document store there is nothing to report. }
  Expect<Boolean>(Pos('repair: no per-user registry document store at ',
    R.Stdout) > 0).ToBe(True);
end;

procedure TRepairE2E.TestRepairClearsStaleInstallLock;
var
  LockPath: string;
  R: TLwptResult;
begin
  LockPath := FScratch + '/.lwpt/install.lock';

  { A crashed install's owner record: it held the record lock, which its
    death released. }
  ForceDirectories(FScratch + '/.lwpt');
  WriteTextFile(LockPath, DEAD_OWNER_RECORD);
  Expect<Boolean>(FileExists(LockPath)).ToBe(True);

  R := RunRepair;
  DumpRunFailure('repair', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(LockPath)).ToBe(False);
  Expect<Boolean>(Pos('its owner (PID ' + UNUSED_PID + ') has exited',
    R.Stdout) > 0).ToBe(True);
end;

procedure TRepairE2E.TestRepairCleansTmpButLeavesCommittedState;
var
  TmpOrphan, ModulesMarker: string;
  R: TLwptResult;
begin
  TmpOrphan     := FScratch + '/.lwpt/tmp/crashed-orphan.tar.gz';
  ModulesMarker := FScratch + '/.lwpt/modules/.preserve-me';

  { Simulate a crash: a stray file under .lwpt/tmp/ (the atomic-write
    staging area an in-progress install would have created). }
  ForceDirectories(FScratch + '/.lwpt/tmp');
  WriteTextFile(TmpOrphan, 'fake archive data');
  Expect<Boolean>(FileExists(TmpOrphan)).ToBe(True);

  { A committed marker under .lwpt/modules/ — must survive repair. }
  ForceDirectories(FScratch + '/.lwpt/modules');
  WriteTextFile(ModulesMarker, 'committed state, must survive');
  Expect<Boolean>(FileExists(ModulesMarker)).ToBe(True);

  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);

  Expect<Boolean>(FileExists(TmpOrphan)).ToBe(False);
  Expect<Boolean>(FileExists(ModulesMarker)).ToBe(True);
end;

procedure TRepairE2E.TestRepairReclaimsFailedBuildSession;
var
  SessionPath: string;
  R: TLwptResult;
begin
  SessionPath := FScratch + '/.lwpt/sessions/session-failed-test';
  WriteTextFile(SessionPath + '/session.state',
    '999999'#10'failed'#10'1'#10);
  WriteTextFile(SessionPath + '/jobs/app/private-output', 'incomplete');

  R := RunRepair;

  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(DirectoryExists(SessionPath)).ToBe(False);
  Expect<Boolean>(Pos('removed 1 abandoned build session', R.Stdout) > 0)
    .ToBe(True);
end;

procedure TRepairE2E.TestRepairReclaimsHistoricalRelocatedSession;
var
  RelocatedBase, NamespacePath, SessionPath: string;
  NamespaceSearch, SessionSearch: TSearchRec;
  R: TLwptResult;
begin
  RelocatedBase := FScratch + '/relocated-sessions';
  RecursiveDelete(RelocatedBase);
  R := RunLwpt(['build'], FScratch,
    [BUILD_SESSION_DIR_ENV + '=' + RelocatedBase,
     'LWPT_WORKER_STATE_DIR=' + FWorkerState,
     'LWPT_WORKER_BUDGET=1']);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(FScratch + '/'
    + BUILD_SESSION_ROOT_LEDGER)).ToBe(True);

  NamespacePath := '';
  if FindFirst(RelocatedBase + '/p-*', faDirectory, NamespaceSearch) = 0 then
  try
    repeat
      if (NamespaceSearch.Attr and faDirectory) <> 0 then
      begin
        NamespacePath := RelocatedBase + '/' + NamespaceSearch.Name;
        Break;
      end;
    until FindNext(NamespaceSearch) <> 0;
  finally
    FindClose(NamespaceSearch);
  end;
  Expect<Boolean>(NamespacePath <> '').ToBe(True);
  SessionPath := '';
  if FindFirst(NamespacePath + '/s-*', faDirectory, SessionSearch) = 0 then
  try
    repeat
      if (SessionSearch.Attr and faDirectory) <> 0 then
      begin
        SessionPath := NamespacePath + '/' + SessionSearch.Name;
        Break;
      end;
    until FindNext(SessionSearch) <> 0;
  finally
    FindClose(SessionSearch);
  end;
  Expect<Boolean>(SessionPath <> '').ToBe(True);

  R := RunRepair;

  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(DirectoryExists(SessionPath)).ToBe(False);
  Expect<Boolean>(FileExists(NamespacePath + '/project.identity')).ToBe(True);
end;

procedure TRepairE2E.TestRepairRecoversSharedCache;
const
  CORRUPT_HEX =
    '6e16134b15b8ffcaf579c488d22e69239e96b2978b9cfa2b600907f71bcbd462';
  HEALTHY_HEX =
    '95059162bf04f962254ae2f56b4159c8d93ecb6ab5be9d4ad6d1368aebeb0c53';
var
  CorruptPath, HealthyPath: string;
  R: TLwptResult;
begin
  { Seed the on-disk public cache contract directly: this root CLI test must
    not construct its fixture through the implementation under test. }
  CorruptPath := FCacheRoot + '/dependency-archives/sha256/'
    + Copy(CORRUPT_HEX, 1, 2) + '/' + Copy(CORRUPT_HEX, 3, MaxInt);
  HealthyPath := FCacheRoot + '/dependency-archives/sha256/'
    + Copy(HEALTHY_HEX, 1, 2) + '/' + Copy(HEALTHY_HEX, 3, MaxInt);
  WriteCacheBytes(CorruptPath, 'tampered'#10);
  WriteCacheBytes(HealthyPath, 'healthy cache payload'#10);
  WriteTextFile(FCacheRoot + '/dependency-archives/tmp/incomplete',
    'partial');

  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(CorruptPath)).ToBe(False);
  Expect<Boolean>(FileExists(HealthyPath)).ToBe(True);
  Expect<Boolean>(Pos('removed 1 corrupt shared-cache object',
    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('shared-cache recovery completed without touching '
    + 'committed project archives', R.Stdout) > 0).ToBe(True);

  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('removed 0 corrupt shared-cache object',
    R.Stdout) > 0).ToBe(True);
end;

procedure TRepairE2E.TestRepairRemovesTransitiveBuildReference;
const
  FINGERPRINT_HEX =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  MANIFEST_HEX =
    'baa8500429609b519b80a8937d8f83e861c3326d08d75264a54a2c2c7b9fe1e1';
  ARTIFACT_HEX =
    'd64f66647820cf67d9fc5ca385a2645de43ea5b5e00c787c530e9e49371ff6ed';
var
  ManifestPath, ReferencePath: string;
  R: TLwptResult;
begin
  ManifestPath := FCacheRoot + '/build-results/objects/sha256/'
    + Copy(MANIFEST_HEX, 1, 2) + '/' + Copy(MANIFEST_HEX, 3, MaxInt);
  ReferencePath := FCacheRoot + '/build-results/refs/sha256/'
    + Copy(FINGERPRINT_HEX, 1, 2) + '/'
    + Copy(FINGERPRINT_HEX, 3, MaxInt);
  WriteCacheBytes(ManifestPath,
    'schema = 1'#10
    + 'fingerprint = "sha256:' + FINGERPRINT_HEX + '"'#10
    + 'artifact_digest = "sha256:' + ARTIFACT_HEX + '"'#10
    + 'artifact_kind = "executable"'#10
    + 'unix_mode = 0'#10);
  WriteCacheBytes(ReferencePath, 'sha256:' + MANIFEST_HEX + #10);

  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ManifestPath)).ToBe(True);
  Expect<Boolean>(FileExists(ReferencePath)).ToBe(False);
end;

procedure TRepairE2E.TestRepairRemovesRetiredExecutableImages;
var
  RetiredPath, BackupPath: string;
  R: TLwptResult;
begin
  { A Windows self-hosted rebuild retires the image it runs from beside the
    build output. Once unused, repair removes it; an in-flight replacement
    backup is not retired residue and stays. }
  RetiredPath := FScratch + '/build/' + RetiredExecutablePrefix
    + '4242-1f1huft3e-7' + TmpPathExtension;
  BackupPath := FScratch + '/build/.r-4242-1f1huft3e-8' + TmpPathExtension;
  WriteTextFile(RetiredPath, 'old image');
  WriteTextFile(BackupPath, 'in-flight backup');
  try
    R := RunRepair;
    Expect<Integer>(R.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(RetiredPath)).ToBe(False);
    Expect<Boolean>(FileExists(BackupPath)).ToBe(True);
    Expect<Boolean>(Pos('removed 1 retired executable image(s), 0 still in '
      + 'use', R.Stdout) > 0).ToBe(True);
  finally
    SysUtils.DeleteFile(BackupPath);
  end;
end;

{ Writes AContent through the Core long-path helpers: the RTL cannot create
  a file past MAX_PATH on Windows. }
procedure WriteLongFile(const APath, AContent: string);
var Stream: TLWPTProtectedFileStream;
begin
  LongPathForceDirectories(ExtractFileDir(APath));
  Stream := OpenProtectedFileStream(APath, fmCreate);
  try
    if AContent <> '' then Stream.WriteBuffer(AContent[1], Length(AContent));
  finally
    Stream.Free;
  end;
end;

procedure TRepairE2E.TestRepairReclaimsDeepSessionAndRetiredImage;
const
  { Win32 MAX_PATH, including the terminating NUL. }
  LEGACY_WINDOWS_MAX_PATH = 260;
  { Deep, but still a valid working directory for the child process. }
  PROJECT_PATH_LENGTH = 200;
var
  DeepRoot, Project, Output, Session, StatePath, JobFile, Retired: string;
  Remaining: Integer;
  R: TLwptResult;
begin
  DeepRoot := ExpandFileName(FScratch + '/deep');
  Project := DeepRoot;
  repeat
    Remaining := PROJECT_PATH_LENGTH - Length(Project) - 1;
    if Remaining < 1 then Break;
    if Remaining > 48 then Remaining := 48;
    Project := Project + '/' + StringOfChar('p', Remaining);
  until False;
  Output := 'out/' + StringOfChar('o', 48) + '/' + StringOfChar('o', 48);
  try
    LongPathForceDirectories(Project + '/source');
    WriteLongFile(Project + '/lwpt.toml',
      '[package]'#10 + 'name = "repair-deep"'#10 + 'version = "0.0.0"'#10
      + 'units = ["source"]'#10 + #10 + '[build]'#10
      + 'app = { source = "source/dummy.pas", output = "' + Output
      + '/app" }'#10);
    WriteLongFile(Project + '/source/dummy.pas',
      'unit Dummy;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);

    Session := Project + '/.lwpt/sessions/session-failed-'
      + StringOfChar('s', 48);
    StatePath := Session + '/session.state';
    JobFile := Session + '/jobs/app/' + StringOfChar('j', 48)
      + '/private-output';
    Retired := Project + '/' + Output + '/' + RetiredExecutablePrefix
      + '4242-1f1huft3e-7' + TmpPathExtension;
    Expect<Boolean>(Length(StatePath) > LEGACY_WINDOWS_MAX_PATH).ToBe(True);
    Expect<Boolean>(Length(ExtractFileDir(Retired)) > LEGACY_WINDOWS_MAX_PATH)
      .ToBe(True);
    WriteLongFile(StatePath, '999999'#10'failed'#10'1'#10);
    WriteLongFile(JobFile, 'incomplete');
    WriteLongFile(Retired, 'old image');

    R := RunLwpt(['repair'], Project, [
      'LWPT_CACHE_DIR=' + FCacheRoot,
      'LWPT_WORKER_STATE_DIR=' + FWorkerState,
      'LWPT_WORKER_BUDGET=1'
    ]);
    if R.ExitCode <> 0 then WriteLn(R.Stdout, R.Stderr);
    Expect<Integer>(R.ExitCode).ToBe(0);
    Expect<Boolean>(LongPathDirectoryExists(Session)).ToBe(False);
    Expect<Boolean>(LongPathFileExists(Retired)).ToBe(False);
    Expect<Boolean>(Pos('removed 1 abandoned build session', R.Stdout) > 0)
      .ToBe(True);
    Expect<Boolean>(Pos('removed 1 retired executable image(s), 0 still in '
      + 'use', R.Stdout) > 0).ToBe(True);
  finally
    if LongPathDirectoryExists(DeepRoot) then WipeDir(DeepRoot);
  end;
end;

procedure TRepairE2E.TestRepairRefusesLiveInstallLock;
var
  Project, Signals, HeldBy, Before: string;
  Holder: TLwptThread;
  Released: Boolean;
  R: TLwptResult;
begin
  { A pending transaction a live install has not yet recovered: an older
    repair recovered it and swept tmp under the running install. }
  Project := WriteLockProject('live-holder');
  CrashInstall(Project);
  Expect<Boolean>(DeleteFile(Project + '/.lwpt/install.lock')).ToBe(True);
  Signals := Project + '-signals';
  Holder := StartLwptTesting(['install'], Project,
    ['LWPT_CACHE_DIR=' + FCacheRoot,
     PROJECT_NAME + '_TEST_HOLD_INSTALL_LOCK=' + Signals]);
  Released := False;
  try
    Expect<Boolean>(AwaitPayload(Signals + '/held', Holder)).ToBe(True);
    HeldBy := ReadPayloadText(Signals + '/held');
    Before := TreeSnapshot(Project);
    Expect<string>(FirstLine(ReadBinaryFile(Project + '/.lwpt/install.lock')))
      .ToBe(HeldBy);

    R := RunRepair(Project);

    DumpRunFailure('repair against a live lock', R, 1);
    Expect<Integer>(R.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('held by a running ' + PROGRAM_NAME + ' install (PID '
      + HeldBy + ')', R.Stderr) > 0).ToBe(True);
    Expect<string>(TreeSnapshot(Project)).ToBe(Before);
    Expect<Boolean>(Holder.Finished).ToBe(False);
    PublishPayloadCompletion(Signals + '/release');
    Released := True;
    Expect<Boolean>(AwaitFinished(Holder)).ToBe(True);
    Expect<string>(Holder.Error).ToBe('');
    DumpRunFailure('held install', Holder.Run, 0);
    Expect<Integer>(Holder.Run.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(Project + '/.lwpt/install.lock')).ToBe(False);
  finally
    if not Released then PublishPayloadCompletion(Signals + '/release');
    if AwaitFinished(Holder) then Holder.Free;
  end;
end;

procedure TRepairE2E.TestRepairReclaimsDeadOwnerAndRecovers;
var Project, OwnerPID: string; R: TLwptResult;
begin
  Project := WriteLockProject('dead-owner');
  CrashInstall(Project);
  OwnerPID := FirstLine(ReadBinaryFile(Project + '/.lwpt/install.lock'));
  Expect<Boolean>(StrToIntDef(OwnerPID, 0) > 0).ToBe(True);
  Expect<Boolean>(ProcessIsLive(StrToIntDef(OwnerPID, 0))).ToBe(False);

  R := RunRepair(Project);

  DumpRunFailure('repair after a crash', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('its owner (PID ' + OwnerPID + ') has exited',
    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(FileExists(Project + '/.lwpt/install.lock')).ToBe(False);
  Expect<string>(ReadBinaryFile(Project + '/.lwpt/modules/branch-a/old.txt'))
    .ToBe('old' + LineEnding);
  Expect<Boolean>(FileExists(
    Project + '/.lwpt/modules/branch-a/source/branch-a.pas')).ToBe(False);
  Expect<Boolean>(HasRollbackMarker(Project + '/.lwpt/tmp')).ToBe(False);
end;

procedure TRepairE2E.TestRunningRepairExcludesInstallAndRepair;
var
  Project, Signals, HeldBy, Orphan: string;
  Environment: TStringArray;
  Holder: TLwptThread;
  Released: Boolean;
  R: TLwptResult;
begin
  Project := WriteLockProject('repair-holder');
  Orphan := Project + '/.lwpt/tmp/orphan';
  WriteTextFile(Orphan, 'residue');
  Signals := Project + '-signals';
  Environment := RepairEnvironment;
  Insert(PROJECT_NAME + '_TEST_HOLD_INSTALL_LOCK=' + Signals, Environment,
    Length(Environment));
  Holder := StartLwptTesting(['repair'], Project, Environment);
  Released := False;
  try
    Expect<Boolean>(AwaitPayload(Signals + '/held', Holder)).ToBe(True);
    HeldBy := ReadPayloadText(Signals + '/held');

    R := RunLwpt(['install'], Project, ['LWPT_CACHE_DIR=' + FCacheRoot]);
    DumpRunFailure('install against a running repair', R, 1);
    Expect<Integer>(R.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('another ' + PROGRAM_NAME + ' repair is in progress '
      + '(lock holder PID: ' + HeldBy + ')', R.Stderr) > 0).ToBe(True);
    Expect<Boolean>(DirectoryExists(Project + '/.lwpt/modules/branch-a/source'))
      .ToBe(False);

    R := RunRepair(Project);
    DumpRunFailure('second repair', R, 1);
    Expect<Integer>(R.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('held by a running ' + PROGRAM_NAME + ' repair (PID '
      + HeldBy + ')', R.Stderr) > 0).ToBe(True);
    Expect<Boolean>(FileExists(Orphan)).ToBe(True);

    Expect<Boolean>(Holder.Finished).ToBe(False);
    PublishPayloadCompletion(Signals + '/release');
    Released := True;
    Expect<Boolean>(AwaitFinished(Holder)).ToBe(True);
    Expect<string>(Holder.Error).ToBe('');
    DumpRunFailure('held repair', Holder.Run, 0);
    Expect<Integer>(Holder.Run.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(Orphan)).ToBe(False);
    Expect<Boolean>(FileExists(Project + '/.lwpt/install.lock')).ToBe(False);
  finally
    if not Released then PublishPayloadCompletion(Signals + '/release');
    if AwaitFinished(Holder) then Holder.Free;
  end;
end;

{ Asserts a refused repair: exit 1 naming ANeedle, the lock and a tmp
  orphan unchanged. }
procedure ExpectRefusedRepair(const ALabel, ANeedle, ALockPath,
  ALockBefore, AOrphan: string; const ARun: TLwptResult);
begin
  DumpRunFailure(ALabel, ARun, 1);
  Expect<Integer>(ARun.ExitCode).ToBe(1);
  Expect<Boolean>(Pos(ANeedle, ARun.Stderr) > 0).ToBe(True);
  Expect<Boolean>(Pos('delete ' + ALockPath + ' by hand', ARun.Stderr) > 0)
    .ToBe(True);
  Expect<string>(ReadBinaryFile(ALockPath)).ToBe(ALockBefore);
  Expect<Boolean>(FileExists(AOrphan)).ToBe(True);
end;

procedure TRepairE2E.TestRepairRefusesLegacyLock;
var Project, LockPath, Orphan: string;
begin
  { An older binary recorded only its PID and held no record lock. A PID
    that names no local process proves nothing: that owner may run in
    another PID namespace or on another host sharing the project. }
  Project := WriteLockProject('legacy-record');
  LockPath := Project + '/.lwpt/install.lock';
  Orphan := Project + '/.lwpt/tmp/orphan';
  WriteTextFile(LockPath, UNUSED_PID);
  WriteTextFile(Orphan, 'residue');
  ExpectRefusedRepair('repair against a PID-only lock',
    'was written by an older ' + PROGRAM_NAME, LockPath,
    ReadBinaryFile(LockPath), Orphan, RunRepair(Project));
end;

procedure TRepairE2E.TestRepairReclaimsRecordLockWithReusedPID;
var Project, LockPath, Running: string; R: TLwptResult;
begin
  { An owner that recorded the record lock is dead once that lock is free,
    whatever process its PID names now. }
  Project := WriteLockProject('record-reused');
  LockPath := Project + '/.lwpt/install.lock';
  Running := IntToStr(GetProcessID);
  WriteTextFile(LockPath, Running + #10'holder=install'#10'lock=record');

  R := RunRepair(Project);

  DumpRunFailure('repair against a reused PID', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('its owner (PID ' + Running + ') has exited',
    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(FileExists(LockPath)).ToBe(False);
end;

procedure TRepairE2E.TestRepairReclaimsRecordOfItsOwnPID;
var
  Project, LockPath, Signals, OwnPID: string;
  Environment: TStringArray;
  R: TLwptResult;
begin
  { A crashed install and the repair after it can both run as PID 1 of
    separate containers. The seam rewrites the record to repair's own PID
    before repair examines it. }
  Project := WriteLockProject('own-pid');
  LockPath := Project + '/.lwpt/install.lock';
  Signals := Project + '-signals';
  WriteTextFile(LockPath, DEAD_OWNER_RECORD);
  Environment := RepairEnvironment;
  Insert(PROJECT_NAME + '_TEST_RECORD_OWN_PID=' + Signals, Environment,
    Length(Environment));

  R := RunLwptTesting(['repair'], Project, Environment);

  DumpRunFailure('repair against its own PID', R, 0);
  Expect<Integer>(R.ExitCode).ToBe(0);
  OwnPID := ReadPayloadText(Signals + '/pid');
  Expect<Boolean>(Pos('its owner (PID ' + OwnPID + ') has exited',
    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(FileExists(LockPath)).ToBe(False);
end;

procedure TRepairE2E.TestRepairRefusesLockWithoutOwnerRecord;
var Project, LockPath, Orphan: string;
begin
  { Its creator may still be starting, or may have died before writing a
    record; no age proves which. }
  Project := WriteLockProject('incomplete');
  LockPath := Project + '/.lwpt/install.lock';
  Orphan := Project + '/.lwpt/tmp/orphan';
  WriteTextFile(LockPath, '');
  WriteTextFile(Orphan, 'residue');
  SetFileModificationTime(LockPath, DateTimeToUnix(Now, False) - 3600, 0);
  ExpectRefusedRepair('repair against a lock without an owner record',
    'has no owner record', LockPath, ReadBinaryFile(LockPath), Orphan,
    RunRepair(Project));
end;

procedure TRepairE2E.TestRepairRefusesWithoutRecordLocks;
var
  Project, LockPath, Orphan: string;
  Environment: TStringArray;
begin
  { Without a record lock nothing proves the owner dead or keeps a second
    repair out, so even a dead owner's record stays. }
  Project := WriteLockProject('no-record-locks');
  LockPath := Project + '/.lwpt/install.lock';
  Orphan := Project + '/.lwpt/tmp/orphan';
  WriteTextFile(LockPath, DEAD_OWNER_RECORD);
  WriteTextFile(Orphan, 'residue');
  Environment := RepairEnvironment;
  Insert(PROJECT_NAME + '_TEST_RECORD_LOCK_UNSUPPORTED=1', Environment,
    Length(Environment));
  ExpectRefusedRepair('repair without record locks', 'keeps no record locks',
    LockPath, ReadBinaryFile(LockPath), Orphan,
    RunLwptTesting(['repair'], Project, Environment));
end;

procedure TRepairE2E.TestDisplacedCreatorFails;
var
  Project, LockPath, FirstSignals, SecondSignals, SecondPID: string;
  First, Second: TLwptThread;
  FirstResumed, SecondReleased: Boolean;
begin
  { An install pauses between creating the lock file and taking its record
    lock. Meanwhile its file is deleted by hand and, where the platform
    frees the name at once, a second install takes the lock. The first must
    not then lock its unlinked file and run beside the second. }
  Project := WriteLockProject('displaced');
  LockPath := Project + '/.lwpt/install.lock';
  FirstSignals := Project + '-first';
  SecondSignals := Project + '-second';
  Second := nil;
  FirstResumed := False;
  SecondReleased := False;
  First := StartLwptTesting(['install'], Project,
    ['LWPT_CACHE_DIR=' + FCacheRoot,
     PROJECT_NAME + '_TEST_PAUSE_BEFORE_RECORD_LOCK=' + FirstSignals]);
  try
    Expect<Boolean>(AwaitPayload(FirstSignals + '/created', First))
      .ToBe(True);
    Expect<Boolean>(DeleteFile(LockPath)).ToBe(True);
    {$IFDEF UNIX}
    Second := StartLwptTesting(['install'], Project,
      ['LWPT_CACHE_DIR=' + FCacheRoot,
       PROJECT_NAME + '_TEST_HOLD_INSTALL_LOCK=' + SecondSignals]);
    Expect<Boolean>(AwaitPayload(SecondSignals + '/held', Second)).ToBe(True);
    SecondPID := ReadPayloadText(SecondSignals + '/held');
    {$ENDIF}

    PublishPayloadCompletion(FirstSignals + '/resume');
    FirstResumed := True;
    Expect<Boolean>(AwaitFinished(First)).ToBe(True);
    Expect<string>(First.Error).ToBe('');
    DumpRunFailure('displaced install', First.Run, 1);
    Expect<Integer>(First.Run.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('was taken over, removed, or replaced',
      First.Run.Stderr) > 0).ToBe(True);

    if Second <> nil then
    begin
      Expect<string>(FirstLine(ReadBinaryFile(LockPath))).ToBe(SecondPID);
      Expect<Boolean>(Second.Finished).ToBe(False);
      PublishPayloadCompletion(SecondSignals + '/release');
      SecondReleased := True;
      Expect<Boolean>(AwaitFinished(Second)).ToBe(True);
      Expect<string>(Second.Error).ToBe('');
      DumpRunFailure('second install', Second.Run, 0);
      Expect<Integer>(Second.Run.ExitCode).ToBe(0);
    end
    else
      Expect<Boolean>(FileExists(
        Project + '/.lwpt/modules/branch-a/source/branch-a.pas')).ToBe(False);
  finally
    if not FirstResumed then PublishPayloadCompletion(FirstSignals + '/resume');
    if (Second <> nil) and not SecondReleased then
      PublishPayloadCompletion(SecondSignals + '/release');
    if AwaitFinished(First) then First.Free;
    if (Second <> nil) and AwaitFinished(Second) then Second.Free;
  end;
end;

{$IFDEF UNIX}
procedure TRepairE2E.TestRepairSkipsRedirectedOutputDirectory;
var
  BuildDir, SavedBuildDir, ForeignDir, ForeignPath: string;
  R: TLwptResult;
begin
  { Redirecting the output directory must not let repair delete matching
    files in a directory the project does not own. }
  BuildDir := FScratch + '/build';
  SavedBuildDir := FScratch + '/build.saved';
  ForeignDir := FScratch + '/foreign-output';
  ForeignPath := ForeignDir + '/' + RetiredExecutablePrefix
    + '4242-1f1huft3e-7' + TmpPathExtension;
  WriteTextFile(ForeignPath, 'not owned by the project');
  if DirectoryExists(BuildDir) then
    Expect<Boolean>(RenameFile(BuildDir, SavedBuildDir)).ToBe(True);
  Expect<Integer>(FpSymlink(PChar(ForeignDir), PChar(BuildDir))).ToBe(0);
  try
    R := RunRepair;
    Expect<Integer>(R.ExitCode).ToBe(0);
    Expect<Boolean>(FileExists(ForeignPath)).ToBe(True);
    Expect<Boolean>(Pos('skipped retired-image sweep', R.Stdout) > 0)
      .ToBe(True);
  finally
    FpUnlink(PChar(BuildDir));
    if DirectoryExists(SavedBuildDir) then
      RenameFile(SavedBuildDir, BuildDir);
    RecursiveDelete(ForeignDir);
  end;
end;
{$ENDIF}

procedure TRepairE2E.SetupTests;
begin
  Test('repair on a clean tree is a no-op exit 0',
    TestRepairOnCleanTreeIsNoop);
  Test('repair clears a dead owner''s .lwpt/install.lock',
    TestRepairClearsStaleInstallLock);
  Test('repair cleans .lwpt/tmp/ but leaves .lwpt/modules/ untouched',
    TestRepairCleansTmpButLeavesCommittedState);
  Test('repair reclaims failed build-session staging',
    TestRepairReclaimsFailedBuildSession);
  Test('repair reclaims a historical relocated build session',
    TestRepairReclaimsHistoricalRelocatedSession);
  Test('shared cache recovery is explicit and repeatable',
    TestRepairRecoversSharedCache);
  Test('repair removes a transitive build reference with no artifact',
    TestRepairRemovesTransitiveBuildReference);
  Test('repair reclaims dead machine-wide worker requests',
    TestRepairReclaimsWorkerRequests);
  Test('repair removes retired executable images beside build outputs',
    TestRepairRemovesRetiredExecutableImages);
  Test('repair reclaims a session and a retired image past MAX_PATH',
    TestRepairReclaimsDeepSessionAndRetiredImage);
  Test('repair against a live install lock fails and changes nothing',
    TestRepairRefusesLiveInstallLock);
  Test('repair reclaims a crashed install''s lock and recovers it',
    TestRepairReclaimsDeadOwnerAndRecovers);
  Test('a running repair excludes an install and a second repair',
    TestRunningRepairExcludesInstallAndRepair);
  Test('repair refuses a PID-only lock from an older binary',
    TestRepairRefusesLegacyLock);
  Test('repair reclaims a record-lock owner record whose PID was reused',
    TestRepairReclaimsRecordLockWithReusedPID);
  Test('repair reclaims a record-lock owner record carrying its own PID',
    TestRepairReclaimsRecordOfItsOwnPID);
  Test('repair refuses a lock file without an owner record, however old',
    TestRepairRefusesLockWithoutOwnerRecord);
  Test('repair refuses to reclaim without record locks',
    TestRepairRefusesWithoutRecordLocks);
  Test('an install whose new lock file was replaced fails',
    TestDisplacedCreatorFails);
  {$IFDEF UNIX}
  Test('repair never sweeps a link-redirected build output directory',
    TestRepairSkipsRedirectedOutputDirectory);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TRepairE2E.Create('lwpt repair: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
