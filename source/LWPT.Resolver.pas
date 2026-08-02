unit LWPT.Resolver;

{$I Shared.inc}

interface

uses
  SysUtils,

  LWPT.GitProtocol,
  LWPT.Manifest;

type
  TResolverRequirement = record
    Spec: string;
    Kind: TVersionKind;
    Requirer: string;
  end;
  TResolverRequirementArray = array of TResolverRequirement;

  TResolverSelection = record
    RefName: string;
    CommitSHA: string;
  end;

  EResolverConflict = class(Exception);

function RefCommitSHA(const ARef: TGitRef): string;
function SelectHighestRef(const APackageName: string;
  const ARequirements: TResolverRequirementArray;
  const ARefs: TGitRefArray): TResolverSelection;

implementation

uses
  Classes,

  Semver;

function StripVPrefix(const S: string): string;
begin
  if (Length(S) > 0) and ((S[1] = 'v') or (S[1] = 'V')) then
    Result := Copy(S, 2, MaxInt)
  else
    Result := S;
end;

function RefCommitSHA(const ARef: TGitRef): string;
begin
  if ARef.PeeledSHA <> '' then
    Result := ARef.PeeledSHA
  else
    Result := ARef.SHA;
end;

function SHAAgrees(const ASpec, ACommitSHA: string): Boolean;
begin
  Result := (Length(ASpec) <= Length(ACommitSHA))
    and SameText(ASpec, Copy(ACommitSHA, 1, Length(ASpec)));
end;

function RequirementAccepts(const ARequirement: TResolverRequirement;
  const ARef: TGitRef; const ARefs: TGitRefArray): Boolean;
var Version, RequiredIdentity: string; i: Integer;
begin
  Result := False;
  case ARequirement.Kind of
    vkSemverRange:
    begin
      if ARef.Kind <> rkTag then Exit;
      Version := StripVPrefix(ARef.Name);
      Result := (Valid(Version, DefaultSemverOptions) <> '')
        and Satisfies(Version, ARequirement.Spec, DefaultSemverOptions);
    end;
    vkSemverExact:
    begin
      RequiredIdentity := '';
      for i := 0 to High(ARefs) do
        if (ARefs[i].Kind = rkTag)
           and ((ARefs[i].Name = ARequirement.Spec)
           or (ARefs[i].Name = 'v' + ARequirement.Spec)) then
        begin
          if (RequiredIdentity <> '')
             and not SameText(RequiredIdentity, RefCommitSHA(ARefs[i])) then
            Exit(False);
          RequiredIdentity := RefCommitSHA(ARefs[i]);
        end;
      Result := (RequiredIdentity <> '')
        and SameText(RequiredIdentity, RefCommitSHA(ARef));
    end;
    vkLiteralTag:
    begin
      RequiredIdentity := '';
      for i := 0 to High(ARefs) do
        if ARefs[i].Name = ARequirement.Spec then
        begin
          if (RequiredIdentity <> '')
             and not SameText(RequiredIdentity, RefCommitSHA(ARefs[i])) then
            Exit(False);
          RequiredIdentity := RefCommitSHA(ARefs[i]);
        end;
      Result := (RequiredIdentity <> '')
        and SameText(RequiredIdentity, RefCommitSHA(ARef));
    end;
    vkCommitSha:
      Result := SHAAgrees(ARequirement.Spec, RefCommitSHA(ARef));
    vkNone:
      Result := False;
  end;
end;

function RequirementLines(const ARequirements: TResolverRequirementArray): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(ARequirements) do
  begin
    if Result <> '' then Result := Result + LineEnding;
    Result := Result + '  ' + ARequirements[i].Requirer + ' wants "'
      + ARequirements[i].Spec + '"';
  end;
end;

function SelectHighestRef(const APackageName: string;
  const ARequirements: TResolverRequirementArray;
  const ARefs: TGitRefArray): TResolverSelection;
var
  i, j, Best: Integer;
  Accepted, HasNamedRequirement: Boolean;
  Version, BestVersion: string;

  function IsDirectCandidate(const ARef: TGitRef): Boolean;
  var k: Integer; CandidateVersion: string;
  begin
    Result := False;
    for k := 0 to High(ARequirements) do
      case ARequirements[k].Kind of
        vkSemverRange:
        begin
          if ARef.Kind <> rkTag then Continue;
          CandidateVersion := StripVPrefix(ARef.Name);
          if (Valid(CandidateVersion, DefaultSemverOptions) <> '')
             and Satisfies(CandidateVersion, ARequirements[k].Spec,
               DefaultSemverOptions) then Exit(True);
        end;
        vkSemverExact:
          if (ARef.Kind = rkTag)
             and ((ARef.Name = ARequirements[k].Spec)
             or (ARef.Name = 'v' + ARequirements[k].Spec)) then Exit(True);
        vkLiteralTag:
          if ARef.Name = ARequirements[k].Spec then Exit(True);
        vkCommitSha:
          if not HasNamedRequirement
             and SHAAgrees(ARequirements[k].Spec, RefCommitSHA(ARef)) then
            Exit(True);
        vkNone:;
      end;
  end;
begin
  Result := Default(TResolverSelection);
  Best := -1;
  BestVersion := '';
  HasNamedRequirement := False;
  for i := 0 to High(ARequirements) do
    HasNamedRequirement := HasNamedRequirement
      or (ARequirements[i].Kind <> vkCommitSha);
  for i := 0 to High(ARefs) do
  begin
    Accepted := True;
    for j := 0 to High(ARequirements) do
      if not RequirementAccepts(ARequirements[j], ARefs[i], ARefs) then
      begin
        Accepted := False;
        Break;
      end;
    if not Accepted then Continue;
    if not IsDirectCandidate(ARefs[i]) then Continue;

    Version := StripVPrefix(ARefs[i].Name);
    if Valid(Version, DefaultSemverOptions) <> '' then
    begin
      if (Best >= 0) and (BestVersion <> '')
         and (Compare(Version, BestVersion, DefaultSemverOptions) = 0)
         and not SameText(RefCommitSHA(ARefs[i]), RefCommitSHA(ARefs[Best])) then
        raise EResolverConflict.Create(
          'unresolvable version conflict on "' + APackageName + '":'
          + LineEnding + RequirementLines(ARequirements)
          + LineEnding + '  highest SemVer precedence is ambiguous: tags "'
          + ARefs[Best].Name + '" and "' + ARefs[i].Name
          + '" advertise different commit identities')
      else if (Best < 0) or (BestVersion = '')
         or (Compare(Version, BestVersion, DefaultSemverOptions) > 0) then
      begin
        Best := i;
        BestVersion := Version;
      end;
    end
    else if Best < 0 then
      Best := i
    else if not SameText(RefCommitSHA(ARefs[i]), RefCommitSHA(ARefs[Best])) then
      raise EResolverConflict.Create(
        'unresolvable version conflict on "' + APackageName + '":'
        + LineEnding + RequirementLines(ARequirements)
        + LineEnding + '  matching literal refs advertise different '
        + 'commit identities');
  end;

  if Best < 0 then
    raise EResolverConflict.Create(
      'unresolvable version conflict on "' + APackageName + '":'
      + LineEnding + RequirementLines(ARequirements)
      + LineEnding + '  no advertised tag identifies one concrete '
      + 'version satisfying every constraint');

  Result.RefName := ARefs[Best].Name;
  Result.CommitSHA := RefCommitSHA(ARefs[Best]);
end;

end.
