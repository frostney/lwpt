{ Repair.Test — pins lwpt repair semantics.

  `lwpt repair` clears two kinds of post-crash residue:
    - .lwpt/install.lock (the cross-process install lock PID file)
    - .lwpt/tmp/ (the atomic-write staging area)

  It must NOT touch .lwpt/modules/ or .lwpt/archives/ (the committed
  zero-install state). Repair is the documented recovery path when an
  install crashes mid-run; it must be safe on a clean tree and
  effective on a dirty one.

  Three assertions:
    1. Repair on a clean tree is a no-op exit 0 (idempotent).
    2. Stale .lwpt/install.lock is removed.
    3. .lwpt/tmp/ contents are removed; the directory itself stays.
       .lwpt/modules/ and .lwpt/archives/ contents are untouched. }

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
    FOrigDir, FScratch: string;
    procedure WriteFile(const APath, AContent: string);
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestRepairOnCleanTreeIsNoop;
    procedure TestRepairClearsStaleInstallLock;
    procedure TestRepairCleansTmpButLeavesCommittedState;
  end;

procedure TRepairE2E.WriteFile(const APath, AContent: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure TRepairE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/source');

  WriteFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "repair-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10);

  WriteFile(FScratch + '/source/dummy.pas',
    'unit Dummy;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'interface'#10 +
    'implementation'#10 +
    'end.'#10);
end;

procedure TRepairE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/repair-e2e');
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
  R := RunLwpt(['repair'], FScratch);
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
  WriteFile(LockPath, '99999');
  Expect<Boolean>(FileExists(LockPath)).ToBe(True);

  R := RunLwpt(['repair'], FScratch);
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
  WriteFile(TmpOrphan, 'fake archive data');
  Expect<Boolean>(FileExists(TmpOrphan)).ToBe(True);

  { A committed marker under .lwpt/modules/ — must survive repair. }
  ForceDirectories(FScratch + '/.lwpt/modules');
  WriteFile(ModulesMarker, 'committed state, must survive');
  Expect<Boolean>(FileExists(ModulesMarker)).ToBe(True);

  R := RunLwpt(['repair'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  Expect<Boolean>(FileExists(TmpOrphan)).ToBe(False);
  Expect<Boolean>(FileExists(ModulesMarker)).ToBe(True);
end;

procedure TRepairE2E.SetupTests;
begin
  Test('repair on a clean tree is a no-op exit 0',
    TestRepairOnCleanTreeIsNoop);
  Test('repair clears a stale .lwpt/install.lock',
    TestRepairClearsStaleInstallLock);
  Test('repair cleans .lwpt/tmp/ but leaves .lwpt/modules/ untouched',
    TestRepairCleansTmpButLeavesCommittedState);
end;

begin
  TestRunnerProgram.AddSuite(TRepairE2E.Create('lwpt repair: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
