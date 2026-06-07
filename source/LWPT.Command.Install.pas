{ LWPT.Command.Install — install subcommand entrypoint. }
unit LWPT.Command.Install;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean);

implementation

uses
  SysUtils,

  LWPT.Command.Common,
  LWPT.Install,
  LWPT.Manifest;

procedure CmdInstall(const AManifestPath: string; AFrozen: Boolean);
var
  Ctx : TManifestContext;
  Mode : TInstallTransactionMode;
begin
  Ctx := LoadManifestContext(AManifestPath);
  WriteLn('package: ', Ctx.Manifest.Name, ' ', Ctx.Manifest.Version);
  RunHooks('preinstall', Ctx.Manifest.PreInstall);
  if AFrozen then Mode := itmFrozenVerify else Mode := itmMaterialize;
  RunInstallTransaction(Ctx, Mode);
  RunHooks('postinstall', Ctx.Manifest.PostInstall);
end;

end.
