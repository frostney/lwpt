{ Repair.Test — pins lwpt repair semantics.

  `lwpt repair` clears two kinds of post-crash residue:
    - .lwpt/install.lock (the cross-process install lock PID file)
    - .lwpt/tmp/ (the atomic-write staging area)

  It must NOT touch .lwpt/modules/ or .lwpt/archives/ (the committed
  zero-install state). Repair is the documented recovery path when an
  install crashes mid-run; it must be safe on a clean tree and
  effective on a dirty one.

  Eight assertions:
    1. Repair on a clean tree is a no-op exit 0 (idempotent).
    2. Stale .lwpt/install.lock is removed.
    3. .lwpt/tmp/ contents are removed; the directory itself stays.
       .lwpt/modules/ and .lwpt/archives/ contents are untouched.
    4. Failed build-session staging is reclaimed.
    5. Dead machine-wide worker requests are reclaimed and diagnosed.
    6. Historical relocated sessions remain reclaimable after the override
       is absent.
    7. Shared-cache corruption and incomplete state are repaired repeatably.
    8. Transitive build references with missing artifacts are removed. }

program Repair.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.BuildSession,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TRepairE2E = class(TTestSuite)
  private
    FCacheRoot, FOrigDir, FScratch, FWorkerState: string;
    procedure SetupScratchProject;
    procedure WriteCacheBytes(const APath, ABytes: string);
    function RunRepair: TLwptResult;
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

function TRepairE2E.RunRepair: TLwptResult;
begin
  Result := RunLwpt(['repair'], FScratch, [
    'LWPT_CACHE_DIR=' + FCacheRoot,
    'LWPT_WORKER_STATE_DIR=' + FWorkerState,
    'LWPT_WORKER_BUDGET=1'
  ]);
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
end;

procedure TRepairE2E.TestRepairClearsStaleInstallLock;
var
  LockPath: string;
  R: TLwptResult;
begin
  LockPath := FScratch + '/.lwpt/install.lock';

  { Simulate a crashed install: leave a stale lock file with a fake PID. }
  ForceDirectories(FScratch + '/.lwpt');
  WriteTextFile(LockPath, '99999');
  Expect<Boolean>(FileExists(LockPath)).ToBe(True);

  R := RunRepair;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(LockPath)).ToBe(False);
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

procedure TRepairE2E.SetupTests;
begin
  Test('repair on a clean tree is a no-op exit 0',
    TestRepairOnCleanTreeIsNoop);
  Test('repair clears a stale .lwpt/install.lock',
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
end;

begin
  TestRunnerProgram.AddSuite(TRepairE2E.Create('lwpt repair: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
