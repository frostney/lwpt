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

procedure WipeDirContents(const ADir: string);
var SR: TSearchRec; Base, FullPath: string;
begin
  if not DirectoryExists(ADir) then Exit;
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      FullPath := Base + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        WipeDirContents(FullPath);
        RemoveDir(FullPath);
      end
      else
        DeleteFile(FullPath);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

procedure CmdRepair(const AManifestPath: string);
var
  Man : TManifest;
  TmpRoot : string;
begin
  Man := LoadManifest(AManifestPath);
  TmpRoot := ResolveTmpDir(Man);

  if DirectoryExists(TmpRoot) then
  begin
    WipeDirContents(TmpRoot);
    WriteLn('repair: cleaned ', TmpRoot, '/');
  end
  else
    WriteLn('repair: no ', TmpRoot, '/ to clean');

  if FileExists(INSTALL_LOCK) then
  begin
    DeleteFile(INSTALL_LOCK);
    WriteLn('repair: removed stale ', INSTALL_LOCK);
  end
  else
    WriteLn('repair: no install lock to remove');

  WriteLn('repair complete. Committed state under ', LWPT_DIR,
          '/modules/ and ', LWPT_DIR, '/archives/ was not modified.');
end;

end.
