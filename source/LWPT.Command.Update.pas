{ LWPT.Command.Update — bump authored constraints that no longer cover
  the latest tag, then run the install transaction (ADR-0039). }
unit LWPT.Command.Update;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

procedure CmdUpdate(const AManifestPath: string;
  const ANames: array of string);

implementation

uses
  Classes,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.DependencyUpdate,
  LWPT.GitProtocol,
  LWPT.Install,
  LWPT.Manifest,
  LWPT.ManifestEdit;

procedure CmdUpdate(const AManifestPath: string;
  const ANames: array of string);
var
  Ctx: TManifestContext;
  Lock: TResolvedArray;
  Entries, Selected, Planned: TOutdatedEntryArray;
  Lines: TStringList;
  LockPath, NewConstraint: string;
  i, j, N: Integer;
  NeedManifestWrite: Boolean;
begin
  Ctx := LoadManifestContext(AManifestPath);
  SetLength(Lock, 0);
  LockPath := IncludeTrailingPathDelimiter(Ctx.ProjectRoot) + LOCKFILE;
  if FileExists(LockPath) then
    Lock := LoadLockfile(LockPath);

  Entries := CollectOutdated(Ctx.Manifest, Lock, @ListRemoteRefs);
  if Length(ANames) > 0 then
    Selected := FilterNamedEntries(Entries, ANames)
  else
    Selected := Entries;

  SetLength(Planned, 0);
  N := 0;
  for i := 0 to High(Selected) do
    if Selected[i].Status <> ousCurrent then
    begin
      SetLength(Planned, N + 1);
      Planned[N] := Selected[i];
      Inc(N);
    end;

  WriteLn('package: ', Ctx.Manifest.Name, ' ', Ctx.Manifest.Version);
  if Length(Planned) = 0 then
  begin
    WriteLn('already up to date');
    Exit;
  end;

  Lines := TStringList.Create;
  try
    LoadManifestLines(Ctx.Path, Lines);
    NeedManifestWrite := False;
    for i := 0 to High(Planned) do
    begin
      if ConstraintSatisfiesLatest(Planned[i].Constraint, Planned[i].Kind,
        Planned[i].Latest, Planned[i].LatestRef) then
      begin
        WriteLn('refreshing ', Planned[i].Name, ': locked ',
          Planned[i].Locked, ' -> ', Planned[i].LatestRef,
          ' (constraint ', Planned[i].Constraint, ' still covers it)');
        Continue;
      end;

      NewConstraint := BumpConstraint(Planned[i].Constraint, Planned[i].Kind,
        Planned[i].Latest, Planned[i].LatestRef);
      if not SetDependencyVersionConstraint(Lines, Planned[i].Name,
        NewConstraint) then
        raise EManifestError.CreateFmt(
          'dependency "%s" is declared in a form `%s update` cannot edit '
          + '(e.g. a [dependencies.%s] table); edit %s manually',
          [Planned[i].Name, PROGRAM_NAME, Planned[i].Name, MANIFEST_FILE]);

      for j := 0 to High(Ctx.Manifest.Deps) do
        if SameText(Ctx.Manifest.Deps[j].Name, Planned[i].Name) then
        begin
          ParseVersionSpec(NewConstraint, Ctx.Manifest.Deps[j].VersionKind,
            Ctx.Manifest.Deps[j].VersionSpec);
          Break;
        end;

      WriteLn('updating ', Planned[i].Name, ': locked ',
        Planned[i].Locked, ' -> ', Planned[i].LatestRef,
        ' (constraint ', Planned[i].Constraint, ' -> ', NewConstraint, ')');
      NeedManifestWrite := True;
    end;

    RunHooks('preinstall', Ctx.Manifest.PreInstall, Ctx.ProjectRoot);
    if NeedManifestWrite then
      RunManifestMutationTransaction(Ctx, Lines)
    else
      RunInstallTransaction(Ctx, itmMaterialize);
    RunHooks('postinstall', Ctx.Manifest.PostInstall, Ctx.ProjectRoot);
    WriteLn('updated ', IntToStr(Length(Planned)), ' dependenc',
      BoolToStr(Length(Planned) = 1, 'y', 'ies'));
  finally
    Lines.Free;
  end;
end;

end.
