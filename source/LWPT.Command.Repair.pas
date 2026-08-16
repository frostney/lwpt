{ LWPT.Command.Repair — repair subcommand entrypoint. }
unit LWPT.Command.Repair;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdRepair(const AManifestPath: string);

implementation

uses
  Classes,
  SysUtils,

  LWPT.BuildSession,
  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.Install,
  LWPT.Manifest,
  LWPT.ObjectStore,
  LWPT.WorkerBudget;

function LooksLikeAbsolutePath(const APath: string): Boolean;
begin
  Result := (APath <> '') and ((APath[1] = '/') or (APath[1] = '\'));
  if Result then Exit;
  Result := (Length(APath) >= 2)
        and (APath[1] in ['a'..'z', 'A'..'Z'])
        and (APath[2] = ':');
end;

function ResolveRepairPath(const AProjectRoot, APath: string): string;
begin
  if APath = '' then Exit('');
  if LooksLikeAbsolutePath(APath) then
    Exit(ExpandFileName(APath));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjectRoot) + APath);
end;

procedure CmdRepair(const AManifestPath: string);
var
  Ctx : TManifestContext;
  TmpRoot, LockPath : string;
  SessionsRemoved, SessionsRetained: Integer;
  TmpRootCleaned: Boolean;
  WorkerLines : TStringList;
  WorkerSnapshot : TLWPTWorkerBudgetSnapshot;
  CacheReport: TLWPTCacheRepairReport;
  Reclaimed, i : Integer;
begin
  Ctx := LoadManifestContext(AManifestPath);
  TmpRoot := ResolveRepairPath(Ctx.ProjectRoot, ResolveTmpDir(Ctx.Manifest));
  LockPath := ResolveRepairPath(Ctx.ProjectRoot, INSTALL_LOCK);

  if FileExists(LockPath) then
  begin
    if not DeleteFile(LockPath) then
      raise EConcurrencyError.CreateFmt(
        'repair: failed to remove stale install lock at %s', [LockPath]);
    WriteLn('repair: removed stale ', LockPath);
  end
  else
    WriteLn('repair: no install lock to remove');

  { A crashed writer may have a validated pre-transaction snapshot below
    tmp. Restore it before the ordinary residue sweep can delete it. }
  RecoverInterruptedInstall(Ctx);
  RepairBuildSessions(Ctx.ProjectRoot, TmpRoot, SessionsRemoved,
    SessionsRetained, TmpRootCleaned);
  if TmpRootCleaned then
  begin
    WriteLn('repair: recovered interrupted publication and cleaned ',
      TmpRoot, '/');
  end
  else
    WriteLn('repair: no ', TmpRoot, '/ to clean');

  WriteLn('repair: removed ', SessionsRemoved, ' abandoned build session(s), ',
    SessionsRetained, ' live session(s) retained');

  Reclaimed := RepairWorkerBudget;
  WorkerSnapshot := GetWorkerBudgetSnapshot;
  WorkerLines := TStringList.Create;
  try
    AppendWorkerBudgetDiagnostics(WorkerLines, WorkerSnapshot);
    WriteLn('repair: reclaimed ', Reclaimed,
      ' abandoned worker invocation(s)');
    for i := 0 to WorkerLines.Count - 1 do
      WriteLn(WorkerLines[i]);
  finally
    WorkerLines.Free;
  end;

  CacheReport := RepairSharedCache(ResolveCacheRoot);
  WriteLn('repair: shared cache ', CacheReport.BytesAfter, ' byte(s) after ',
    'repair; budget ', CacheReport.BudgetBytes, ' byte(s), reclaimed ',
    CacheReport.BytesReclaimed, ' byte(s)');
  WriteLn('repair: removed ', CacheReport.CorruptObjectsRemoved,
    ' corrupt shared-cache object(s), ',
    CacheReport.IncompleteEntriesRemoved, ' incomplete area(s), and ',
    CacheReport.AbandonedLeasesReclaimed,
    ' abandoned producer lease(s)');
  WriteLn('repair: preserved ', CacheReport.LiveObjectsPreserved,
    ' live shared-cache object(s) and ', CacheReport.LiveLeasesPreserved,
    ' live producer lease(s)');
  if CacheReport.IndexRebuilt then
    WriteLn('repair: rebuilt the shared-cache LRU index from verified ',
      'object manifests')
  else
    WriteLn('repair: verified the shared-cache LRU index');

  WriteLn('repair complete. Project install recovery and per-user shared-cache '
    + 'recovery completed without touching committed project archives.');
end;

end.
