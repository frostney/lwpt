{ LWPT.Command.Remove — remove subcommand entrypoint (ADR-0019). }
unit LWPT.Command.Remove;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdRemove(const AManifestPath: string; const ANames: array of string);

implementation

uses
  Classes,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Install,
  LWPT.Manifest,
  LWPT.ManifestEdit;

{ CmdRemove — delete [dependencies] entries, then hand the edited
  manifest to the mutation transaction, which re-resolves the
  remaining graph, commits lwpt.toml, and prunes orphaned module
  trees + archives (transitive orphans included) INSIDE the
  cross-process install lock. See ADR-0019. }
procedure CmdRemove(const AManifestPath: string;
  const ANames: array of string);

  function InResolved(const AResolved: TResolvedArray;
    const AName: string): Boolean;
  var k: Integer;
  begin
    for k := 0 to High(AResolved) do
      if SameText(AResolved[k].Name, AName) then Exit(True);
    Result := False;
  end;

var
  Ctx : TManifestContext;
  Lines : TStringList;
  Res : TInstallTransactionResult;
  i, j, k : Integer;
begin
  if Length(ANames) = 0 then
    raise EManifestError.Create(
      'remove needs at least one dependency name');

  Ctx := LoadManifestContext(AManifestPath);

  Lines := TStringList.Create;
  try
    LoadManifestLines(Ctx.Path, Lines);

    for i := 0 to High(ANames) do
    begin
      RequireNotWorkspacePackage(Ctx.Manifest, ANames[i]);

      if not RemoveDependencyLine(Lines, ANames[i]) then
      begin
        if HasDirectDep(Ctx.Manifest, ANames[i]) then
          raise EManifestError.CreateFmt(
            'dependency "%s" is declared in a form `%s remove` cannot '
            + 'edit (e.g. a [dependencies.%s] table); edit %s manually',
            [ANames[i], PROGRAM_NAME, ANames[i], MANIFEST_FILE])
        else
          raise EManifestError.CreateFmt(
            'no dependency named "%s" in %s', [ANames[i], MANIFEST_FILE]);
      end;

      { Drop it from the in-memory manifest the transaction resolves
        against. }
      for j := 0 to High(Ctx.Manifest.Deps) do
        if SameText(Ctx.Manifest.Deps[j].Name, ANames[i]) then
        begin
          for k := j to High(Ctx.Manifest.Deps) - 1 do
            Ctx.Manifest.Deps[k] := Ctx.Manifest.Deps[k + 1];
          SetLength(Ctx.Manifest.Deps, Length(Ctx.Manifest.Deps) - 1);
          Break;
        end;
    end;

    WriteLn('package: ', Ctx.Manifest.Name, ' ', Ctx.Manifest.Version);
    for i := 0 to High(ANames) do
      WriteLn('removing ', ANames[i]);
    RunHooks('preinstall', Ctx.Manifest.PreInstall);
    Res := RunManifestMutationTransaction(Ctx, Lines);
    RunHooks('postinstall', Ctx.Manifest.PostInstall);

    for i := 0 to High(ANames) do
      if InResolved(Res.Resolved, ANames[i]) then
        WriteLn('note: ', ANames[i], ' is still required transitively; '
                + 'its modules stay installed')
      else
        WriteLn('removed ', ANames[i], ' from ', MANIFEST_FILE);
  finally
    Lines.Free;
  end;
end;

end.
