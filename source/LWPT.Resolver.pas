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
    RefKind: TGitRefKind;
  end;

  EResolverConflict = class(Exception);

  { One published registry version from a verified snapshot (ADR-0051). Key
    is opaque to the resolver (the record hash). }
  TResolverVersionCandidate = record
    Version: string;
    Key: string;
    Yanked: Boolean;
  end;
  TResolverVersionCandidateArray = array of TResolverVersionCandidate;

function RefCommitSHA(const ARef: TGitRef): string;
{ The index of the highest candidate satisfying every requirement. Yanked
  candidates are never newly selected, even by an exact version; one whose
  version equals ALockedVersion stays selectable (ADR-0051 decision 7).
  Ranges use Semver.Satisfies with DefaultSemverOptions, as git tags do. An
  empty result raises EResolverConflict with the complete requirement set. }
function SelectHighestVersion(const APackageName: string;
  const ARequirements: TResolverRequirementArray;
  const ACandidates: TResolverVersionCandidateArray;
  const ALockedVersion: string): Integer;
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

function SelectHighestVersion(const APackageName: string;
  const ARequirements: TResolverRequirementArray;
  const ACandidates: TResolverVersionCandidateArray;
  const ALockedVersion: string): Integer;
var
  i, j: Integer;
  Accepted, YankedExcluded: Boolean;
  Version: string;
begin
  Result := -1;
  YankedExcluded := False;
  for i := 0 to High(ACandidates) do
  begin
    Version := ACandidates[i].Version;
    if Valid(Version, DefaultSemverOptions) <> Version then Continue;
    Accepted := True;
    for j := 0 to High(ARequirements) do
    begin
      case ARequirements[j].Kind of
        vkNone:;
        vkSemverRange:
          Accepted := Satisfies(Version, ARequirements[j].Spec,
            DefaultSemverOptions);
        vkSemverExact:
          Accepted := Version = ARequirements[j].Spec;
      else
        Accepted := False;
      end;
      if not Accepted then Break;
    end;
    if not Accepted then Continue;
    if ACandidates[i].Yanked and (Version <> ALockedVersion) then
    begin
      YankedExcluded := True;
      Continue;
    end;
    if (Result < 0) or (Compare(Version, ACandidates[Result].Version,
         DefaultSemverOptions) > 0) then
      Result := i;
  end;
  if Result < 0 then
  begin
    if YankedExcluded then
      raise EResolverConflict.Create(
        'unresolvable version conflict on "' + APackageName + '":'
        + LineEnding + RequirementLines(ARequirements)
        + LineEnding + '  every published version satisfying every '
        + 'constraint is yanked; yanked versions are never newly selected')
    else
      raise EResolverConflict.Create(
        'unresolvable version conflict on "' + APackageName + '":'
        + LineEnding + RequirementLines(ARequirements)
        + LineEnding + '  no published registry version satisfies every '
        + 'constraint');
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
  Result.RefKind := ARefs[Best].Kind;
end;

end.
