{ LWPT.Command.Repair — repair subcommand entrypoint. }
unit LWPT.Command.Repair;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdRepair(const AManifestPath: string);

implementation

uses
  SysUtils,

  LWPT.Core,
  LWPT.Manifest;

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
begin
  Ctx := LoadManifestContext(AManifestPath);
  TmpRoot := ResolveRepairPath(Ctx.ProjectRoot, ResolveTmpDir(Ctx.Manifest));
  LockPath := ResolveRepairPath(Ctx.ProjectRoot, INSTALL_LOCK);

  if DirectoryExists(TmpRoot) then
  begin
    WipeDir(TmpRoot);
    WriteLn('repair: cleaned ', TmpRoot, '/');
  end
  else
    WriteLn('repair: no ', TmpRoot, '/ to clean');

  if FileExists(LockPath) then
  begin
    if not DeleteFile(LockPath) then
      raise EConcurrencyError.CreateFmt(
        'repair: failed to remove stale install lock at %s', [LockPath]);
    WriteLn('repair: removed stale ', LockPath);
  end
  else
    WriteLn('repair: no install lock to remove');

  WriteLn('repair complete. Committed state under ', LWPT_DIR,
          '/modules/ and ', LWPT_DIR, '/archives/ was not modified.');
end;

end.
