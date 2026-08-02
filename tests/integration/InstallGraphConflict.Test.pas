program InstallGraphConflict.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  {$IFDEF MSWINDOWS}
  Process,
  {$ENDIF}
  SysUtils,

  LWPT.Command.Install,
  LWPT.Core,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TInstallGraphConflict = class(TTestSuite)
  private
    FOriginalDir, FScratch, FRoot, FMessage: string;
    procedure WritePackage(const ADir, AName, ADependencies: string);
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestDiagnosticNamesEveryRequirer;
    procedure TestConflictPublishesNoGraphState;
    procedure TestPreexistingCommittedStateIsUntouched;
    procedure TestFailureAfterLockWriteRollsBackWholeBatch;
    procedure TestExtractionPolicyParticipatesInIdentity;
    procedure TestDuplicateNormalizedPolicyGlobsUnify;
    procedure TestPolicyCaseRemainsSemanticallyDistinct;
    procedure TestSourceConflictCollectsEveryReachableSource;
    procedure TestInterWorkspaceRequirementUnifiesWithAutoDiscovery;
    procedure TestInterWorkspaceRequirementChecksWorkspaceVersion;
    procedure TestInlineWorkspaceRequirementChecksWorkspaceVersion;
    procedure TestInlineWorkspaceWildcardUnifiesWithAutoDiscovery;
    procedure TestFilteredSnapshotIsPublishedExactly;
    procedure TestLocalMutationPreflightRefusesPublication;
    procedure TestRollbackRetentionKeepsPublishedTreeReadable;
    procedure TestInterruptedPublicationRecoversBeforeTmpCleanup;
    procedure TestRollbackAggregatesFailuresAndRetainsBackup;
    procedure TestRestoreExceptionContinuesTransactionRollback;
    procedure TestRestoreExceptionContinuesCrashRecovery;
    {$IFDEF UNIX}
    procedure TestRollbackPreservesModuleSymlink;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    procedure TestRollbackPreservesModuleJunction;
    {$ENDIF}
  end;

function ReadText(const APath: string): string;
var Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function HasRollbackMarker(const ATmpRoot: string): Boolean;
var Outer, Inner: TSearchRec; Dir: string;
begin
  Result := False;
  if FindFirst(ATmpRoot + '/*', faAnyFile, Outer) <> 0 then Exit;
  try
    repeat
      if (Outer.Name = '.') or (Outer.Name = '..') then Continue;
      if (Outer.Attr and faDirectory) = 0 then Continue;
      Dir := ATmpRoot + '/' + Outer.Name;
      if FindFirst(Dir + '/*.rollback', faAnyFile, Inner) = 0 then
      begin
        FindClose(Inner);
        Exit(True);
      end;
    until FindNext(Outer) <> 0;
  finally
    FindClose(Outer);
  end;
end;

function TextCount(const AText, ANeedle: string): Integer;
var Offset, Found: Integer;
begin
  Result := 0;
  Offset := 1;
  repeat
    Found := Pos(ANeedle, Copy(AText, Offset, MaxInt));
    if Found = 0 then Exit;
    Inc(Result);
    Inc(Offset, Found + Length(ANeedle) - 1);
  until False;
end;

{$IFDEF UNIX}
function ReadSymlinkTarget(const APath: string): string;
var Buffer: array[0..4095] of Char; Count: ssize_t;
begin
  Count := FpReadLink(PChar(APath), @Buffer[0], SizeOf(Buffer));
  if Count < 0 then Exit('');
  SetString(Result, PChar(@Buffer[0]), Count);
end;
{$ENDIF}

procedure TInstallGraphConflict.WritePackage(const ADir, AName,
  ADependencies: string);
begin
  ForceDirectories(ADir + '/source');
  WriteTextFile(ADir + '/source/' + AName + '.pas',
    'unit ' + StringReplace(AName, '-', '_', [rfReplaceAll]) + ';'#10
    + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  WriteTextFile(ADir + '/lwpt.toml',
    '[package]'#10 + 'name = "' + AName + '"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + ADependencies);
end;

procedure TInstallGraphConflict.BeforeAll;
begin
  FOriginalDir := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('install-graph-conflict');
  FRoot := FScratch + '/root';
  RecursiveDelete(FScratch);
  WritePackage(FRoot, 'conflict-root',
    '[dependencies]'#10 + 'branch-a = "../a"'#10
    + 'branch-b = "../b"'#10);
  WritePackage(FScratch + '/a', 'branch-a',
    '[dependencies]'#10 + 'shared = "../shared-a"'#10);
  WritePackage(FScratch + '/b', 'branch-b',
    '[dependencies]'#10 + 'shared = "../shared-b"'#10);
  WritePackage(FScratch + '/shared-a', 'shared', '');
  WritePackage(FScratch + '/shared-b', 'shared', '');
  ForceDirectories(FRoot + '/.lwpt/modules/sentinel');
  ForceDirectories(FRoot + '/.lwpt/archives');
  WriteTextFile(FRoot + '/.lwpt/modules/sentinel/keep.txt', 'module-sentinel');
  WriteTextFile(FRoot + '/.lwpt/archives/keep.tar.gz', 'archive-sentinel');
  SetCurrentDir(FRoot);
  FMessage := '';
  try
    CmdInstall('lwpt.toml', False);
  except
    on E: Exception do FMessage := E.Message;
  end;
end;

procedure TInstallGraphConflict.AfterAll;
begin
  SetCurrentDir(FOriginalDir);
end;

procedure TInstallGraphConflict.TestDiagnosticNamesEveryRequirer;
begin
  Expect<Boolean>(Pos('branch-a wants', FMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('branch-b wants', FMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('different canonical sources', FMessage) > 0)
    .ToBe(True);
end;

procedure TInstallGraphConflict.TestConflictPublishesNoGraphState;
begin
  Expect<Boolean>(DirectoryExists(FRoot + '/.lwpt/modules/branch-a'))
    .ToBe(False);
  Expect<Boolean>(DirectoryExists(FRoot + '/.lwpt/modules/branch-b'))
    .ToBe(False);
  Expect<Boolean>(DirectoryExists(FRoot + '/.lwpt/modules/shared'))
    .ToBe(False);
  Expect<Boolean>(FileExists(FRoot + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(FileExists(FRoot + '/lwpt.cfg')).ToBe(False);
end;

procedure TInstallGraphConflict.TestPreexistingCommittedStateIsUntouched;
begin
  Expect<string>(ReadText(FRoot + '/.lwpt/modules/sentinel/keep.txt'))
    .ToBe('module-sentinel'#10);
  Expect<string>(ReadText(FRoot + '/.lwpt/archives/keep.tar.gz'))
    .ToBe('archive-sentinel'#10);
end;

procedure TInstallGraphConflict.TestFailureAfterLockWriteRollsBackWholeBatch;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/rollback-root';
  WritePackage(Root, 'rollback-root',
    '[dependencies]'#10 + 'branch-a = "../rollback-a"'#10
    + 'branch-b = "../rollback-b"'#10);
  WritePackage(FScratch + '/rollback-a', 'branch-a', '');
  WritePackage(FScratch + '/rollback-b', 'branch-b', '');
  ForceDirectories(Root + '/.lwpt/modules/branch-a');
  ForceDirectories(Root + '/.lwpt/modules/branch-b');
  ForceDirectories(Root + '/.lwpt/archives');
  WriteTextFile(Root + '/.lwpt/modules/branch-a/old.txt', 'old-a');
  WriteTextFile(Root + '/.lwpt/modules/branch-b/old.txt', 'old-b');
  WriteTextFile(Root + '/.lwpt/archives/sentinel.tar.gz', 'old-archive');
  WriteTextFile(Root + '/lwpt.lock', 'old-lock');
  WriteTextFile(Root + '/lwpt.cfg', 'old-cfg');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<string>(ReadText(Root + '/.lwpt/modules/branch-a/old.txt'))
    .ToBe('old-a'#10);
  Expect<string>(ReadText(Root + '/.lwpt/modules/branch-b/old.txt'))
    .ToBe('old-b'#10);
  Expect<string>(ReadText(Root + '/.lwpt/archives/sentinel.tar.gz'))
    .ToBe('old-archive'#10);
  Expect<string>(ReadText(Root + '/lwpt.lock')).ToBe('old-lock'#10);
  Expect<string>(ReadText(Root + '/lwpt.cfg')).ToBe('old-cfg'#10);
end;

procedure TInstallGraphConflict.TestExtractionPolicyParticipatesInIdentity;
var Root: string; Run: TLwptResult; Combined: string;
begin
  Root := FScratch + '/policy-root';
  WritePackage(Root, 'policy-root',
    '[dependencies]'#10 + 'branch-a = "../policy-a"'#10
    + 'branch-b = "../policy-b"'#10);
  WritePackage(FScratch + '/policy-a', 'branch-a',
    '[dependencies]'#10
    + 'shared = { source = "../policy-shared", '
    + 'include = ["source/**"] }'#10);
  WritePackage(FScratch + '/policy-b', 'branch-b',
    '[dependencies]'#10
    + 'shared = { source = "../policy-shared", '
    + 'exclude = ["docs/**"] }'#10);
  WritePackage(FScratch + '/policy-shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('different canonical sources', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/branch-a'))
    .ToBe(False);
end;

procedure TInstallGraphConflict.TestDuplicateNormalizedPolicyGlobsUnify;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/policy-dedupe-root';
  WritePackage(Root, 'policy-dedupe-root',
    '[dependencies]'#10 + 'branch-a = "../policy-dedupe-a"'#10
    + 'branch-b = "../policy-dedupe-b"'#10);
  WritePackage(FScratch + '/policy-dedupe-a', 'branch-a',
    '[dependencies]'#10
    + 'shared = { source = "../policy-dedupe-shared", '
    + 'include = ["source/**", "source\\**"] }'#10);
  WritePackage(FScratch + '/policy-dedupe-b', 'branch-b',
    '[dependencies]'#10
    + 'shared = { source = "../policy-dedupe-shared", '
    + 'include = ["source/**"] }'#10);
  WritePackage(FScratch + '/policy-dedupe-shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  if Run.ExitCode <> 0 then
    WriteLn('--- policy dedupe ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(True);
end;

procedure TInstallGraphConflict.TestPolicyCaseRemainsSemanticallyDistinct;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/policy-case-root';
  WritePackage(Root, 'policy-case-root',
    '[dependencies]'#10 + 'branch-a = "../policy-case-a"'#10
    + 'branch-b = "../policy-case-b"'#10);
  WritePackage(FScratch + '/policy-case-a', 'branch-a',
    '[dependencies]'#10
    + 'shared = { source = "../policy-case-shared", '
    + 'include = ["Source/**"] }'#10);
  WritePackage(FScratch + '/policy-case-b', 'branch-b',
    '[dependencies]'#10
    + 'shared = { source = "../policy-case-shared", '
    + 'include = ["source/**"] }'#10);
  WritePackage(FScratch + '/policy-case-shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('different canonical sources',
    Run.Stdout + Run.Stderr) > 0).ToBe(True);
end;

procedure TInstallGraphConflict.TestSourceConflictCollectsEveryReachableSource;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/three-source-root';
  WritePackage(Root, 'three-source-root',
    '[dependencies]'#10 + 'branch-a = "../three-source-a"'#10
    + 'branch-b = "../three-source-b"'#10
    + 'branch-c = "../three-source-c"'#10);
  WritePackage(FScratch + '/three-source-a', 'branch-a',
    '[dependencies]'#10 + 'shared = "../shared-source-a"'#10);
  WritePackage(FScratch + '/three-source-b', 'branch-b',
    '[dependencies]'#10 + 'shared = "../shared-source-b"'#10);
  WritePackage(FScratch + '/three-source-c', 'branch-c',
    '[dependencies]'#10 + 'shared = "../shared-source-c"'#10);
  WritePackage(FScratch + '/shared-source-a', 'shared', '');
  WritePackage(FScratch + '/shared-source-b', 'shared', '');
  WritePackage(FScratch + '/shared-source-c', 'shared', '');
  Run := RunLwpt(['install'], Root);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('branch-a wants', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('branch-b wants', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('branch-c wants', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('shared-source-a', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('shared-source-b', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('shared-source-c', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('different canonical sources', Combined) > 0)
    .ToBe(True);
end;

procedure TInstallGraphConflict.TestInterWorkspaceRequirementUnifiesWithAutoDiscovery;
var Root, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/workspace-unify-root';
  WritePackage(Root, 'workspace-unify-root',
    '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  WritePackage(Root + '/packages/consumer', 'consumer',
    '[dependencies]'#10 + 'shared = "workspace:^1.0.0"'#10);
  WritePackage(Root + '/packages/shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  if Run.ExitCode <> 0 then
    WriteLn('--- workspace unify ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
  Expect<Boolean>(IsDirSymlinkOrJunction(
    Root + '/.lwpt/modules/shared')).ToBe(False);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Integer>(TextCount(LockText, '[package.shared]')).ToBe(1);
  Expect<Boolean>(Pos('sourceIdentity = "local|packages/shared/',
    LockText) > 0).ToBe(True);
  Run := RunLwpt(['install', '--frozen'], Root);
  if Run.ExitCode <> 0 then
    WriteLn('--- workspace frozen ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TInstallGraphConflict.TestInterWorkspaceRequirementChecksWorkspaceVersion;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/workspace-version-root';
  WritePackage(Root, 'workspace-version-root',
    '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  WritePackage(Root + '/packages/consumer', 'consumer',
    '[dependencies]'#10 + 'shared = "workspace:^2.0.0"'#10);
  WritePackage(Root + '/packages/shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('consumer wants "^2.0.0"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('workspace version is "1.0.0"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(False);
end;

procedure TInstallGraphConflict.TestInlineWorkspaceRequirementChecksWorkspaceVersion;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/workspace-inline-version-root';
  WritePackage(Root, 'workspace-inline-version-root',
    '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  WritePackage(Root + '/packages/consumer', 'consumer',
    '[dependencies]'#10
    + 'shared = { source = "workspace:^2.0.0" }'#10);
  WritePackage(Root + '/packages/shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('consumer wants "^2.0.0"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('workspace version is "1.0.0"', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(Root + '/lwpt.lock')).ToBe(False);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/shared'))
    .ToBe(False);
end;

procedure TInstallGraphConflict.TestInlineWorkspaceWildcardUnifiesWithAutoDiscovery;
var Root, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/workspace-inline-wildcard-root';
  WritePackage(Root, 'workspace-inline-wildcard-root',
    '[workspaces]'#10 + 'include = ["packages/*"]'#10);
  WritePackage(Root + '/packages/consumer', 'consumer',
    '[dependencies]'#10
    + 'shared = { source = "workspace:*" }'#10);
  WritePackage(Root + '/packages/shared', 'shared', '');
  Run := RunLwpt(['install'], Root);
  if Run.ExitCode <> 0 then
    WriteLn('--- inline workspace wildcard ---'#10,
      Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Integer>(TextCount(LockText, '[package.shared]')).ToBe(1);
end;

procedure TInstallGraphConflict.TestFilteredSnapshotIsPublishedExactly;
var Root, LockText: string; Run: TLwptResult;
begin
  Root := FScratch + '/filtered-root';
  WritePackage(Root, 'filtered-root',
    '[dependencies]'#10
    + 'shared = { source = "../filtered-shared", '
    + 'include = ["source\\**"] }'#10);
  WritePackage(FScratch + '/filtered-shared', 'shared', '');
  WriteTextFile(FScratch + '/filtered-shared/docs/private.txt', 'private');
  Run := RunLwpt(['install'], Root);
  if Run.ExitCode <> 0 then
    WriteLn('--- filtered snapshot ---'#10, Run.Stdout, Run.Stderr, '---');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/shared/docs/private.txt')).ToBe(False);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/shared/lwpt.toml')).ToBe(False);
  Expect<Boolean>(IsDirSymlinkOrJunction(
    Root + '/.lwpt/modules/shared')).ToBe(False);
  LockText := ReadText(Root + '/lwpt.lock');
  Expect<Boolean>(Pos('include=source/**', LockText) > 0).ToBe(True);
end;

procedure TInstallGraphConflict.TestLocalMutationPreflightRefusesPublication;
var Root: string; Run: TLwptResult; Combined: string;
begin
  Root := FScratch + '/mutation-root';
  WritePackage(Root, 'mutation-root',
    '[dependencies]'#10 + 'branch-a = "../mutation-a"'#10);
  WritePackage(FScratch + '/mutation-a', 'branch-a', '');
  ForceDirectories(Root + '/.lwpt/modules/sentinel');
  WriteTextFile(Root + '/.lwpt/modules/sentinel/old.txt', 'old');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_STALE_LOCAL_SNAPSHOT=branch-a']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('changed during resolution', Combined) > 0)
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(Root + '/.lwpt/modules/branch-a'))
    .ToBe(False);
  Expect<string>(ReadText(Root + '/.lwpt/modules/sentinel/old.txt'))
    .ToBe('old'#10);
end;

procedure TInstallGraphConflict.TestInterruptedPublicationRecoversBeforeTmpCleanup;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/crash-recovery-root';
  WritePackage(Root, 'crash-recovery-root',
    '[dependencies]'#10 + 'branch-a = "../crash-recovery-a"'#10);
  WritePackage(FScratch + '/crash-recovery-a', 'branch-a', '');
  ForceDirectories(Root + '/.lwpt/modules/branch-a');
  WriteTextFile(Root + '/.lwpt/modules/branch-a/old.txt', 'old');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_HALT_PUBLISH_AFTER=1']);
  Expect<Integer>(Run.ExitCode).ToBe(86);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/branch-a/source/branch-a.pas')).ToBe(True);
  Run := RunLwpt(['repair'], Root);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-a/old.txt')).ToBe('old'#10);
  Expect<Boolean>(FileExists(
    Root + '/.lwpt/modules/branch-a/source/branch-a.pas')).ToBe(False);
  Expect<Boolean>(HasRollbackMarker(Root + '/.lwpt/tmp')).ToBe(False);
end;

procedure TInstallGraphConflict.TestRollbackRetentionKeepsPublishedTreeReadable;
var Root: string; Run: TLwptResult;
begin
  Root := FScratch + '/retention-reader-root';
  WritePackage(Root, 'retention-reader-root',
    '[dependencies]'#10 + 'branch-a = "../retention-reader-a"'#10);
  WritePackage(FScratch + '/retention-reader-a', 'branch-a', '');
  ForceDirectories(Root + '/.lwpt/modules/branch-a');
  WriteTextFile(Root + '/.lwpt/modules/branch-a/old.txt', 'old');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_HALT_AFTER_MODULE_RETAIN=branch-a']);
  Expect<Integer>(Run.ExitCode).ToBe(87);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-a/old.txt')).ToBe('old'#10);
  Run := RunLwpt(['repair'], Root);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-a/old.txt')).ToBe('old'#10);
end;

procedure TInstallGraphConflict.TestRollbackAggregatesFailuresAndRetainsBackup;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/aggregate-rollback-root';
  WritePackage(Root, 'aggregate-rollback-root',
    '[dependencies]'#10 + 'branch-a = "../aggregate-a"'#10
    + 'branch-b = "../aggregate-b"'#10);
  WritePackage(FScratch + '/aggregate-a', 'branch-a', '');
  WritePackage(FScratch + '/aggregate-b', 'branch-b', '');
  ForceDirectories(Root + '/.lwpt/modules/branch-a');
  ForceDirectories(Root + '/.lwpt/modules/branch-b');
  WriteTextFile(Root + '/.lwpt/modules/branch-a/old.txt', 'old-a');
  WriteTextFile(Root + '/.lwpt/modules/branch-b/old.txt', 'old-b');
  WriteTextFile(Root + '/lwpt.lock', 'old-lock');
  WriteTextFile(Root + '/lwpt.cfg', 'old-cfg');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1',
     PROJECT_NAME + '_TEST_CORRUPT_ROLLBACK_FOR=branch-a']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('injected failure after lockfile publication',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('rollback failures:', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('module "branch-a"', Combined) > 0).ToBe(True);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-b/old.txt')).ToBe('old-b'#10);
  Expect<string>(ReadText(Root + '/lwpt.lock')).ToBe('old-lock'#10);
  Expect<string>(ReadText(Root + '/lwpt.cfg')).ToBe('old-cfg'#10);
  Expect<Boolean>(HasRollbackMarker(Root + '/.lwpt/tmp')).ToBe(True);
end;

procedure TInstallGraphConflict.TestRestoreExceptionContinuesTransactionRollback;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/exception-rollback-root';
  WritePackage(Root, 'exception-rollback-root',
    '[dependencies]'#10 + 'branch-a = "../exception-a"'#10
    + 'branch-b = "../exception-b"'#10);
  WritePackage(FScratch + '/exception-a', 'branch-a', '');
  WritePackage(FScratch + '/exception-b', 'branch-b', '');
  ForceDirectories(Root + '/.lwpt/modules/branch-a');
  ForceDirectories(Root + '/.lwpt/modules/branch-b');
  WriteTextFile(Root + '/.lwpt/modules/branch-a/old.txt', 'old-a');
  WriteTextFile(Root + '/.lwpt/modules/branch-b/old.txt', 'old-b');
  WriteTextFile(Root + '/lwpt.lock', 'old-lock');
  WriteTextFile(Root + '/lwpt.cfg', 'old-cfg');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1',
     PROJECT_NAME + '_TEST_THROW_RESTORE_FOR=branch-b']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('injected failure after lockfile publication',
    Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('injected restore exception', Combined) > 0).ToBe(True);
  Expect<Boolean>(Pos('module "branch-b"', Combined) > 0).ToBe(True);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-a/old.txt')).ToBe('old-a'#10);
  Expect<string>(ReadText(Root + '/lwpt.lock')).ToBe('old-lock'#10);
  Expect<string>(ReadText(Root + '/lwpt.cfg')).ToBe('old-cfg'#10);
  Expect<Boolean>(HasRollbackMarker(Root + '/.lwpt/tmp')).ToBe(True);
  Run := RunLwpt(['repair'], Root);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-b/old.txt')).ToBe('old-b'#10);
end;

procedure TInstallGraphConflict.TestRestoreExceptionContinuesCrashRecovery;
var Root, Combined: string; Run: TLwptResult;
begin
  Root := FScratch + '/exception-recovery-root';
  WritePackage(Root, 'exception-recovery-root',
    '[dependencies]'#10 + 'branch-a = "../recovery-exception-a"'#10
    + 'branch-b = "../recovery-exception-b"'#10);
  WritePackage(FScratch + '/recovery-exception-a', 'branch-a', '');
  WritePackage(FScratch + '/recovery-exception-b', 'branch-b', '');
  ForceDirectories(Root + '/.lwpt/modules/branch-a');
  ForceDirectories(Root + '/.lwpt/modules/branch-b');
  WriteTextFile(Root + '/.lwpt/modules/branch-a/old.txt', 'old-a');
  WriteTextFile(Root + '/.lwpt/modules/branch-b/old.txt', 'old-b');
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_HALT_PUBLISH_AFTER=2']);
  Expect<Integer>(Run.ExitCode).ToBe(86);
  Run := RunLwpt(['repair'], Root,
    [PROJECT_NAME + '_TEST_THROW_RESTORE_FOR=branch-a']);
  Combined := Run.Stdout + Run.Stderr;
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('injected restore exception', Combined) > 0).ToBe(True);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-b/old.txt')).ToBe('old-b'#10);
  Expect<Boolean>(HasRollbackMarker(Root + '/.lwpt/tmp')).ToBe(True);
  Run := RunLwpt(['repair'], Root);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(ReadText(
    Root + '/.lwpt/modules/branch-a/old.txt')).ToBe('old-a'#10);
end;

{$IFDEF UNIX}
procedure TInstallGraphConflict.TestRollbackPreservesModuleSymlink;
const LinkTarget = '../../original-branch-a';
var Root, ModulePath, TargetPath: string; Run: TLwptResult;
begin
  Root := FScratch + '/symlink-rollback-root';
  WritePackage(Root, 'symlink-rollback-root',
    '[dependencies]'#10 + 'branch-a = "../symlink-source-a"'#10);
  WritePackage(FScratch + '/symlink-source-a', 'branch-a', '');
  TargetPath := Root + '/original-branch-a';
  ForceDirectories(TargetPath);
  WriteTextFile(TargetPath + '/old.txt', 'old-link-target');
  ForceDirectories(Root + '/.lwpt/modules');
  ModulePath := Root + '/.lwpt/modules/branch-a';
  Expect<Integer>(FpSymlink(PChar(LinkTarget), PChar(ModulePath))).ToBe(0);
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(IsDirSymlinkOrJunction(ModulePath)).ToBe(True);
  Expect<string>(ReadSymlinkTarget(ModulePath)).ToBe(LinkTarget);
  Expect<string>(ReadText(ModulePath + '/old.txt')).ToBe(
    'old-link-target'#10);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure TInstallGraphConflict.TestRollbackPreservesModuleJunction;
var Root, ModulePath, TargetPath, Cmd: string; Run: TLwptResult;
  P: TProcess;
begin
  Root := FScratch + '/junction-rollback-root';
  WritePackage(Root, 'junction-rollback-root',
    '[dependencies]'#10 + 'branch-a = "../junction-source-a"'#10);
  WritePackage(FScratch + '/junction-source-a', 'branch-a', '');
  TargetPath := Root + '/original-branch-a';
  ForceDirectories(TargetPath);
  WriteTextFile(TargetPath + '/old.txt', 'old-junction-target');
  ForceDirectories(Root + '/.lwpt/modules');
  ModulePath := Root + '/.lwpt/modules/branch-a';
  Cmd := GetEnvironmentVariable('COMSPEC');
  if Cmd = '' then Cmd := 'cmd.exe';
  P := TProcess.Create(nil);
  try
    P.Executable := Cmd;
    P.Parameters.Add('/C');
    P.Parameters.Add('mklink /J "' + NativePath(ModulePath) + '" "'
      + NativePath(TargetPath) + '"');
    P.Options := [poWaitOnExit];
    P.Execute;
    Expect<Integer>(P.ExitStatus).ToBe(0);
  finally
    P.Free;
  end;
  Run := RunLwpt(['install'], Root,
    [PROJECT_NAME + '_TEST_FAIL_AFTER_LOCK_WRITE=1']);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(IsDirSymlinkOrJunction(ModulePath)).ToBe(True);
  Expect<string>(ReadText(ModulePath + '/old.txt')).ToBe(
    'old-junction-target'#10);
end;
{$ENDIF}

procedure TInstallGraphConflict.SetupTests;
begin
  Test('complete conflict diagnostic names every requirer',
    TestDiagnosticNamesEveryRequirer);
  Test('invalid graph publishes no module, lock, or cfg state',
    TestConflictPublishesNoGraphState);
  Test('invalid graph preserves preexisting committed state',
    TestPreexistingCommittedStateIsUntouched);
  Test('failure after lock write rolls back modules archives lock and cfg',
    TestFailureAfterLockWriteRollsBackWholeBatch);
  Test('normalized extraction policy participates in artifact identity',
    TestExtractionPolicyParticipatesInIdentity);
  Test('duplicate extraction globs unify after slash normalization',
    TestDuplicateNormalizedPolicyGlobsUnify);
  Test('extraction-policy identity preserves case-sensitive matching',
    TestPolicyCaseRemainsSemanticallyDistinct);
  Test('source conflicts include every reachable requirer and source',
    TestSourceConflictCollectsEveryReachableSource);
  Test('workspace requirements unify with auto-discovered candidates',
    TestInterWorkspaceRequirementUnifiesWithAutoDiscovery);
  Test('workspace requirements enforce the discovered workspace version',
    TestInterWorkspaceRequirementChecksWorkspaceVersion);
  Test('inline workspace requirements enforce the discovered version',
    TestInlineWorkspaceRequirementChecksWorkspaceVersion);
  Test('inline workspace wildcard unifies with auto-discovery',
    TestInlineWorkspaceWildcardUnifiesWithAutoDiscovery);
  Test('local publication uses the exact validated filtered snapshot',
    TestFilteredSnapshotIsPublishedExactly);
  Test('local mutation preflight refuses publication',
    TestLocalMutationPreflightRefusesPublication);
  Test('rollback retention keeps the published tree readable',
    TestRollbackRetentionKeepsPublishedTreeReadable);
  Test('interrupted publication recovers before tmp cleanup',
    TestInterruptedPublicationRecoversBeforeTmpCleanup);
  Test('rollback aggregates failures and retains invalid backups',
    TestRollbackAggregatesFailuresAndRetainsBackup);
  Test('restore exceptions do not abort later transaction rollback entries',
    TestRestoreExceptionContinuesTransactionRollback);
  Test('restore exceptions do not abort later crash-recovery entries',
    TestRestoreExceptionContinuesCrashRecovery);
  {$IFDEF UNIX}
  Test('rollback preserves a module symlink and its exact target',
    TestRollbackPreservesModuleSymlink);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Test('rollback preserves a native module junction',
    TestRollbackPreservesModuleJunction);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TInstallGraphConflict.Create(
    'install: graph-wide conflict transaction'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
