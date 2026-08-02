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
end;

begin
  TestRunnerProgram.AddSuite(TResolverSelectionTests.Create(
    'resolver: concrete version selection'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
