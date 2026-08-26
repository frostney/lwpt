{ LWPT.Command.Install — install subcommand entrypoint. }
unit LWPT.Command.Install;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean;
  AOffline: Boolean = False);

implementation

uses
  SysUtils,

  LWPT.Command.Common,
  LWPT.Install,
  LWPT.Manifest;

procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean;
  AOffline: Boolean);
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
  RunInstallTransaction(Ctx, Mode);
  RunHooks('postinstall', Ctx.Manifest.PostInstall, Ctx.ProjectRoot);
end;

end.
