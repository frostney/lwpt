{ LWPT.Command.Install — install subcommand entrypoint. }
unit LWPT.Command.Install;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

{ AAcceptMovedTags lets an online install re-pin a locked tag that the host
  now advertises at a different commit; without it such a tag fails the
  install. }
procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean;
  AOffline: Boolean = False; AAcceptMovedTags: Boolean = False);

implementation

uses
  SysUtils,

  LWPT.Command.Common,
  LWPT.Install,
  LWPT.Manifest;

procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean;
  AOffline: Boolean; AAcceptMovedTags: Boolean);
var
  Ctx : TManifestContext;
  Mode : TInstallTransactionMode;
begin
  Ctx := LoadManifestContext(AManifestPath);
  WriteLn('package: ', Ctx.Manifest.Name, ' ', Ctx.Manifest.Version);
  RunHooks('preinstall', Ctx.Manifest.PreInstall, Ctx.ProjectRoot);
  if AFrozen then
    Mode := itmFrozenVerify
  else if AOffline then
    Mode := itmOfflineMaterialize
  else
    Mode := itmMaterialize;
  RunInstallTransaction(Ctx, Mode, AAcceptMovedTags);
  RunHooks('postinstall', Ctx.Manifest.PostInstall, Ctx.ProjectRoot);
end;

end.
