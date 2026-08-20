{ LWPT.Command.Outdated — report git-host deps whose latest tag is newer
  than the lock or outside the authored constraint (ADR-0039). }
unit LWPT.Command.Outdated;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

function CmdOutdated(const AManifestPath: string;
  const AJSON: Boolean): Integer;

implementation

uses
  SysUtils,

  LWPT.Core,
  LWPT.DependencyUpdate,
  LWPT.GitProtocol,
  LWPT.Install,
  LWPT.Manifest,
  LWPT.OutputRenderer;

function CmdOutdated(const AManifestPath: string;
  const AJSON: Boolean): Integer;
var
  Ctx: TManifestContext;
  Lock: TResolvedArray;
  Entries: TOutdatedEntryArray;
  LockPath: string;
begin
  Ctx := LoadManifestContext(AManifestPath);
  SetLength(Lock, 0);
  LockPath := IncludeTrailingPathDelimiter(Ctx.ProjectRoot) + LOCKFILE;
  if FileExists(LockPath) then
    Lock := LoadLockfile(LockPath);
  Entries := CollectOutdated(Ctx.Manifest, Lock, @ListRemoteRefs);
  if AJSON then
    WriteCommandResult(FormatOutdatedJSON(Entries))
  else
    WriteCommandResult(FormatOutdatedTable(Entries));
  if HasNonCurrent(Entries) then Result := 1
  else Result := 0;
end;

end.
