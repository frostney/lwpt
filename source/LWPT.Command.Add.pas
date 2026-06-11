{ LWPT.Command.Add — add subcommand entrypoint (ADR-0019). }
unit LWPT.Command.Add;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdAdd(const AManifestPath, ASpec, ANameOverride: string);

implementation

uses
  Classes,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Install,
  LWPT.Manifest,
  LWPT.ManifestEdit;

{ CmdAdd — validate the bare-string spec, stage the one-line manifest
  edit, then hand both to the mutation transaction, which installs the
  amended graph and commits lwpt.toml + prunes orphans INSIDE the
  cross-process install lock. A failed resolve/fetch leaves the
  manifest byte-identical — see ADR-0019 §"Install-before-write". }
procedure CmdAdd(const AManifestPath, ASpec, ANameOverride: string);
var
  Ctx : TManifestContext;
  Dep : TDependency;
  Name, Action : string;
  Lines : TStringList;
  Replaced : Boolean;
  i, Slot : Integer;
begin
  Ctx := LoadManifestContext(AManifestPath);

  Dep := Default(TDependency);
  { Pre-name the dep so parse errors read "dependency "<something>"";
    the real name may not be derivable until the parse succeeded. }
  if ANameOverride <> '' then Dep.Name := ANameOverride
  else Dep.Name := ASpec;
  ParseBareDepString(ASpec, Ctx.Manifest.CustomSources, Dep);

  if ANameOverride <> '' then Name := ANameOverride
  else Name := DeriveDependencyName(Dep);
  if Name = '' then
    raise EManifestError.CreateFmt(
      'cannot derive a dependency name from "%s"; pass --name <name>',
      [ASpec]);
  if not ValidPackageName(Name) then
    raise EManifestError.CreateFmt(
      'dependency name "%s" is not valid (ASCII letters/digits/'
      + 'hyphen/underscore); pass --name <name> to pick another',
      [Name]);
  Dep.Name := Name;

  RequireNotWorkspacePackage(Ctx.Manifest, Name);

  Lines := TStringList.Create;
  try
    LoadManifestLines(Ctx.Path, Lines);
    SetDependencyLine(Lines, Name, ASpec, Replaced);
    { A direct dep that exists in the parsed manifest but has no
      editable line is declared in a form the textual editor can't
      handle (a [dependencies.<name>] dotted table). Inserting a bare
      line alongside it would define the key twice and brick the
      manifest on its next load — hard-error instead, mirroring the
      remove path's guard. }
    if (not Replaced) and HasDirectDep(Ctx.Manifest, Name) then
      raise EManifestError.CreateFmt(
        'dependency "%s" is declared in a form `%s add` cannot edit '
        + '(e.g. a [dependencies.%s] table); edit %s manually',
        [Name, PROGRAM_NAME, Name, MANIFEST_FILE]);
    if Replaced then Action := 'updated' else Action := 'added';

    { Amend the in-memory manifest the transaction resolves against. }
    Slot := -1;
    for i := 0 to High(Ctx.Manifest.Deps) do
      if SameText(Ctx.Manifest.Deps[i].Name, Name) then
      begin
        Slot := i;
        Break;
      end;
    if Slot < 0 then
    begin
      Slot := Length(Ctx.Manifest.Deps);
      SetLength(Ctx.Manifest.Deps, Slot + 1);
    end;
    Ctx.Manifest.Deps[Slot] := Dep;

    WriteLn('package: ', Ctx.Manifest.Name, ' ', Ctx.Manifest.Version);
    WriteLn('adding ', Name, ' = "', ASpec, '"');
    RunHooks('preinstall', Ctx.Manifest.PreInstall);
    RunManifestMutationTransaction(Ctx, Lines);
    RunHooks('postinstall', Ctx.Manifest.PostInstall);
    WriteLn(Action, ' ', Name, ' in ', MANIFEST_FILE);
  finally
    Lines.Free;
  end;
end;

end.
