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

{ AtomicReplaceExecutable retires an old executable image it cannot delete
  because a process still runs it (Windows self-hosted rebuilds). Sweep each
  declared build output directory once; images still in use stay. }
procedure RemoveRetiredBuildOutputs(const ACtx: TManifestContext;
  out ARemoved, ARetained: Integer);
var
  Directories: TStringList;
  OutputPath: string;
  Retained, i: Integer;
begin
  ARemoved := 0;
  ARetained := 0;
  Directories := TStringList.Create;
  try
    Directories.Sorted := True;
    Directories.Duplicates := dupIgnore;
    for i := 0 to High(ACtx.Manifest.BuildEntries) do
    begin
      OutputPath := ACtx.Manifest.BuildEntries[i].Output;
      if OutputPath = '' then
        OutputPath := ChangeFileExt(ACtx.Manifest.BuildEntries[i].Source, '');
      if OutputPath = '' then Continue;
      Directories.Add(ExtractFileDir(
        ResolveRepairPath(ACtx.ProjectRoot, OutputPath)));
    end;
    for i := 0 to Directories.Count - 1 do
    begin
      if not DirectoryExists(Directories[i]) then Continue;
      Inc(ARemoved, RemoveRetiredExecutables(Directories[i], Retained));
      Inc(ARetained, Retained);
    end;
  finally
    Directories.Free;
  end;
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
  RetiredRemoved, RetiredInUse : Integer;
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

  RemoveRetiredBuildOutputs(Ctx, RetiredRemoved, RetiredInUse);
  WriteLn('repair: removed ', RetiredRemoved, ' retired executable image(s), ',
    RetiredInUse, ' still in use');

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
