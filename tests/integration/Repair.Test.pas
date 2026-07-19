{ Repair.Test — pins lwpt repair semantics.

  `lwpt repair` clears two kinds of post-crash residue:
    - .lwpt/install.lock (the cross-process install lock PID file)
    - .lwpt/tmp/ (the atomic-write staging area)

  It must NOT touch .lwpt/modules/ or .lwpt/archives/ (the committed
  zero-install state). Repair is the documented recovery path when an
  install crashes mid-run; it must be safe on a clean tree and
  effective on a dirty one.

  Five assertions:
    1. Repair on a clean tree is a no-op exit 0 (idempotent).
    2. Stale .lwpt/install.lock is removed.
    3. .lwpt/tmp/ contents are removed; the directory itself stays.
       .lwpt/modules/ and .lwpt/archives/ contents are untouched.
    4. Failed build-session staging is reclaimed.
    5. Dead machine-wide worker requests are reclaimed and diagnosed. }

program Repair.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TRepairE2E = class(TTestSuite)
  private
    FOrigDir, FScratch, FWorkerState: string;
    procedure SetupScratchProject;
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
    procedure TestRepairReclaimsWorkerRequests;
  end;

procedure TRepairE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/source');

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "repair-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10);

  WriteTextFile(FScratch + '/source/dummy.pas',
    'unit Dummy;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);
end;

function TRepairE2E.RunRepair: TLwptResult;
begin
  Result := RunLwpt(['repair'], FScratch, [
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
  FWorkerState := FScratch + '/worker-state';
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;

  { Run install once so .lwpt/ has the canonical committed state. }
  RunLwpt(['install'], FScratch);
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
  Test('repair reclaims dead machine-wide worker requests',
    TestRepairReclaimsWorkerRequests);
end;

begin
  TestRunnerProgram.AddSuite(TRepairE2E.Create('lwpt repair: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
