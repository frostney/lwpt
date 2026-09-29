program LWPT.Resolver.Test;

{$mode delphi}{$H+}

uses
  SysUtils,

  LWPT.GitProtocol,
  LWPT.Manifest,
  LWPT.Resolver,
  TestingPascalLibrary;

type
  TResolverSelectionTests = class(TTestSuite)
  private
    function Requirement(const ASpec, ARequirer: string;
      AKind: TVersionKind): TResolverRequirement;
    function Tag(const AName, ASHA: string): TGitRef;
  public
    procedure SetupTests; override;
    procedure TestHighestCommonVersionWins;
    procedure TestGlobalEmptyIntersectionFails;
    procedure TestLiteralTagAndSHAUnifyByCommit;
    procedure TestAnnotatedTagUsesPeeledCommit;
    procedure TestEqualPrecedenceDifferentCommitsFails;
    procedure TestLiteralBranchRemainsSupported;
    procedure TestDifferentTagsAtSameCommitUnify;
    procedure TestRegistryRangesSelectHighest;
    procedure TestRegistryExactVersion;
    procedure TestRegistryPrereleaseFollowsSemver;
    procedure TestRegistryYankedNeverNewlySelected;
    procedure TestRegistryLockedYankStays;
    procedure TestRegistryEmptySetNamesRequirements;
  end;

function Candidate(const AVersion: string;
  const AYanked: Boolean = False): TResolverVersionCandidate;
begin
  Result.Version := AVersion;
  Result.Key := 'record-' + AVersion;
  Result.Yanked := AYanked;
end;

function TResolverSelectionTests.Requirement(const ASpec,
  ARequirer: string; AKind: TVersionKind): TResolverRequirement;
begin
  Result := Default(TResolverRequirement);
  Result.Spec := ASpec;
  Result.Requirer := ARequirer;
  Result.Kind := AKind;
end;

function TResolverSelectionTests.Tag(const AName, ASHA: string): TGitRef;
begin
  Result := Default(TGitRef);
  Result.Kind := rkTag;
  Result.Name := AName;
  Result.SHA := ASHA;
end;

procedure TResolverSelectionTests.TestHighestCommonVersionWins;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Selection: TResolverSelection;
begin
  SetLength(Requirements, 2);
  Requirements[0] := Requirement('>=1.0.0 <3.0.0', 'branch-a', vkSemverRange);
  Requirements[1] := Requirement('^2.0.0', 'branch-b', vkSemverRange);
  SetLength(Refs, 3);
  Refs[0] := Tag('v1.9.0', StringOfChar('a', 40));
  Refs[1] := Tag('v2.1.0', StringOfChar('b', 40));
  Refs[2] := Tag('v2.8.0', StringOfChar('c', 40));
  Selection := SelectHighestRef('shared', Requirements, Refs);
  Expect<string>(Selection.RefName).ToBe('v2.8.0');
end;

procedure TResolverSelectionTests.TestGlobalEmptyIntersectionFails;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Raised: Boolean;
begin
  SetLength(Requirements, 3);
  Requirements[0] := Requirement('<2.0.0 || >=3.0.0', 'a', vkSemverRange);
  Requirements[1] := Requirement('>=1.0.0 <3.0.0', 'b', vkSemverRange);
  Requirements[2] := Requirement('>=2.0.0', 'c', vkSemverRange);
  SetLength(Refs, 3);
  Refs[0] := Tag('v1.5.0', StringOfChar('a', 40));
  Refs[1] := Tag('v2.5.0', StringOfChar('b', 40));
  Refs[2] := Tag('v3.5.0', StringOfChar('c', 40));
  Raised := False;
  try
    SelectHighestRef('shared', Requirements, Refs);
  except
    on E: EResolverConflict do
      Raised := (Pos('a wants', E.Message) > 0)
        and (Pos('b wants', E.Message) > 0)
        and (Pos('c wants', E.Message) > 0);
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TResolverSelectionTests.TestLiteralTagAndSHAUnifyByCommit;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Selection: TResolverSelection;
begin
  SetLength(Requirements, 2);
  Requirements[0] := Requirement('release-1', 'a', vkLiteralTag);
  Requirements[1] := Requirement('abcdef0', 'b', vkCommitSha);
  SetLength(Refs, 1);
  Refs[0] := Tag('release-1', 'abcdef0123456789abcdef0123456789abcdef01');
  Selection := SelectHighestRef('shared', Requirements, Refs);
  Expect<string>(Selection.CommitSHA)
    .ToBe('abcdef0123456789abcdef0123456789abcdef01');
end;

procedure TResolverSelectionTests.TestAnnotatedTagUsesPeeledCommit;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Selection: TResolverSelection;
begin
  SetLength(Requirements, 2);
  Requirements[0] := Requirement('v1.0.0', 'a', vkLiteralTag);
  Requirements[1] := Requirement('ccccccc', 'b', vkCommitSha);
  SetLength(Refs, 1);
  Refs[0] := Tag('v1.0.0', StringOfChar('b', 40));
  Refs[0].PeeledSHA := StringOfChar('c', 40);
  Selection := SelectHighestRef('shared', Requirements, Refs);
  Expect<string>(Selection.CommitSHA).ToBe(StringOfChar('c', 40));
end;

procedure TResolverSelectionTests.TestEqualPrecedenceDifferentCommitsFails;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Raised: Boolean;
begin
  SetLength(Requirements, 1);
  Requirements[0] := Requirement('^1.0.0', 'root', vkSemverRange);
  SetLength(Refs, 2);
  Refs[0] := Tag('v1.2.0+build-a', StringOfChar('a', 40));
  Refs[1] := Tag('v1.2.0+build-b', StringOfChar('b', 40));
  Raised := False;
  try
    SelectHighestRef('shared', Requirements, Refs);
  except
    on E: EResolverConflict do
      Raised := Pos('ambiguous', E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TResolverSelectionTests.TestLiteralBranchRemainsSupported;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Selection: TResolverSelection;
begin
  SetLength(Requirements, 1);
  Requirements[0] := Requirement('main', 'root', vkLiteralTag);
  SetLength(Refs, 1);
  Refs[0] := Tag('main', StringOfChar('a', 40));
  Refs[0].Kind := rkBranch;
  Selection := SelectHighestRef('shared', Requirements, Refs);
  Expect<string>(Selection.RefName).ToBe('main');
end;

procedure TResolverSelectionTests.TestDifferentTagsAtSameCommitUnify;
var Requirements: TResolverRequirementArray; Refs: TGitRefArray;
  Selection: TResolverSelection; Commit: string;
begin
  Commit := StringOfChar('a', 40);
  SetLength(Requirements, 2);
  Requirements[0] := Requirement('stable', 'a', vkLiteralTag);
  Requirements[1] := Requirement('release-1', 'b', vkLiteralTag);
  SetLength(Refs, 2);
  Refs[0] := Tag('release-1', Commit);
  Refs[1] := Tag('stable', Commit);
  Selection := SelectHighestRef('shared', Requirements, Refs);
  Expect<string>(Selection.CommitSHA).ToBe(Commit);
end;

procedure TResolverSelectionTests.TestRegistryRangesSelectHighest;
var Requirements: TResolverRequirementArray;
  Candidates: TResolverVersionCandidateArray;
begin
  SetLength(Requirements, 2);
  Requirements[0] := Requirement('^1.0.0', 'root', vkSemverRange);
  Requirements[1] := Requirement('<1.3.0', 'app@2.0.0', vkSemverRange);
  SetLength(Candidates, 4);
  Candidates[0] := Candidate('1.1.0');
  Candidates[1] := Candidate('1.2.5');
  Candidates[2] := Candidate('1.3.0');
  Candidates[3] := Candidate('2.0.0');
  Expect<string>(Candidates[SelectHighestVersion('json', Requirements,
    Candidates, '')].Version).ToBe('1.2.5');
end;

procedure TResolverSelectionTests.TestRegistryExactVersion;
var Requirements: TResolverRequirementArray;
  Candidates: TResolverVersionCandidateArray;
begin
  SetLength(Requirements, 1);
  Requirements[0] := Requirement('1.1.0', 'root', vkSemverExact);
  SetLength(Candidates, 2);
  Candidates[0] := Candidate('1.1.0');
  Candidates[1] := Candidate('1.2.0');
  Expect<string>(Candidates[SelectHighestVersion('json', Requirements,
    Candidates, '')].Version).ToBe('1.1.0');
end;

procedure TResolverSelectionTests.TestRegistryPrereleaseFollowsSemver;
var Requirements: TResolverRequirementArray;
  Candidates: TResolverVersionCandidateArray;
begin
  SetLength(Requirements, 1);
  Requirements[0] := Requirement('^1.0.0', 'root', vkSemverRange);
  SetLength(Candidates, 2);
  Candidates[0] := Candidate('1.0.0');
  Candidates[1] := Candidate('1.1.0-beta.1');
  { As for git tags: a range without a prerelease excludes prereleases. }
  Expect<string>(Candidates[SelectHighestVersion('json', Requirements,
    Candidates, '')].Version).ToBe('1.0.0');
  Requirements[0] := Requirement('>=1.1.0-beta.0', 'root', vkSemverRange);
  Expect<string>(Candidates[SelectHighestVersion('json', Requirements,
    Candidates, '')].Version).ToBe('1.1.0-beta.1');
end;

procedure TResolverSelectionTests.TestRegistryYankedNeverNewlySelected;
var Requirements: TResolverRequirementArray;
  Candidates: TResolverVersionCandidateArray;
  Message: string;
begin
  SetLength(Requirements, 1);
  Requirements[0] := Requirement('^1.0.0', 'root', vkSemverRange);
  SetLength(Candidates, 2);
  Candidates[0] := Candidate('1.0.0');
  Candidates[1] := Candidate('1.1.0', True);
  Expect<string>(Candidates[SelectHighestVersion('json', Requirements,
    Candidates, '')].Version).ToBe('1.0.0');
  { Not even an exact version selects a yanked record. }
  Requirements[0] := Requirement('1.1.0', 'root', vkSemverExact);
  Message := '';
  try
    SelectHighestVersion('json', Requirements, Candidates, '');
  except
    on E: EResolverConflict do Message := E.Message;
  end;
  Expect<Boolean>(Pos('yanked', Message) > 0).ToBe(True);
  Expect<Boolean>(Pos('root wants "1.1.0"', Message) > 0).ToBe(True);
end;

procedure TResolverSelectionTests.TestRegistryLockedYankStays;
var Requirements: TResolverRequirementArray;
  Candidates: TResolverVersionCandidateArray;
begin
  SetLength(Requirements, 1);
  Requirements[0] := Requirement('^1.0.0', 'root', vkSemverRange);
  SetLength(Candidates, 2);
  Candidates[0] := Candidate('1.0.0');
  Candidates[1] := Candidate('1.1.0', True);
  Expect<string>(Candidates[SelectHighestVersion('json', Requirements,
    Candidates, '1.1.0')].Version).ToBe('1.1.0');
end;

procedure TResolverSelectionTests.TestRegistryEmptySetNamesRequirements;
var Requirements: TResolverRequirementArray;
  Candidates: TResolverVersionCandidateArray;
  Message: string;
begin
  SetLength(Requirements, 2);
  Requirements[0] := Requirement('^2.0.0', 'root', vkSemverRange);
  Requirements[1] := Requirement('<2.0.0', 'app@1.0.0', vkSemverRange);
  SetLength(Candidates, 2);
  Candidates[0] := Candidate('1.9.0');
  Candidates[1] := Candidate('2.1.0');
  Message := '';
  try
    SelectHighestVersion('json', Requirements, Candidates, '');
  except
    on E: EResolverConflict do Message := E.Message;
  end;
  Expect<Boolean>(Pos('unresolvable version conflict on "json"', Message) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('root wants "^2.0.0"', Message) > 0).ToBe(True);
  Expect<Boolean>(Pos('app@1.0.0 wants "<2.0.0"', Message) > 0).ToBe(True);
  SetLength(Candidates, 0);
  Message := '';
  try
    SelectHighestVersion('json', Requirements, Candidates, '');
  except
    on E: EResolverConflict do Message := E.Message;
  end;
  Expect<Boolean>(Pos('no published registry version', Message) > 0).ToBe(True);
end;

procedure TResolverSelectionTests.SetupTests;
begin
  Test('highest advertised version satisfying all constraints wins',
    TestHighestCommonVersionWins);
  Test('pairwise-overlap with globally empty intersection fails',
    TestGlobalEmptyIntersectionFails);
  Test('literal tag and SHA unify through advertised commit identity',
    TestLiteralTagAndSHAUnifyByCommit);
  Test('annotated tag identity uses the peeled commit',
    TestAnnotatedTagUsesPeeledCommit);
  Test('equal SemVer precedence with different commits is ambiguous',
    TestEqualPrecedenceDifferentCommitsFails);
  Test('literal branch refs remain supported',
    TestLiteralBranchRemainsSupported);
  Test('different authoritative tags at one commit unify',
    TestDifferentTagsAtSameCommitUnify);
  Test('registry ranges select the highest version satisfying every '
    + 'requirement', TestRegistryRangesSelectHighest);
  Test('a registry exact version selects exactly that version',
    TestRegistryExactVersion);
  Test('registry prereleases follow the git tag SemVer rules',
    TestRegistryPrereleaseFollowsSemver);
  Test('a yanked registry version is never newly selected, even exactly',
    TestRegistryYankedNeverNewlySelected);
  Test('a locked yanked registry version stays selectable',
    TestRegistryLockedYankStays);
  Test('an empty registry candidate set names every requirement',
    TestRegistryEmptySetNamesRequirements);
end;

begin
  TestRunnerProgram.AddSuite(TResolverSelectionTests.Create(
    'resolver: concrete version selection'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
