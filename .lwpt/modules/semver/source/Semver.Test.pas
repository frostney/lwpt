{ Semver.Test — covers the semver paths LWPT's resolver depends on.

  The resolver's correctness rests on three Semver entry points:

    Satisfies(version, range)       — does a concrete version satisfy a range?
    RangeIntersects(rangeA, rangeB) — do two ranges share any version?
    MaxSatisfying(versions, range)  — pick the highest matching version

  All three are part of the LWPT-canonical Semver package (a full
  node-semver port); the basic happy path is covered upstream of this
  test by the port's own internal tests, but the LWPT-relevant edge
  cases (the ones the conflict-detection logic in CheckNodeConstraints
  leans on) warrant their own assertions here. }

program Semver.Test;

{$mode delphi}{$H+}

uses
  SysUtils,

  Semver,
  TestingPascalLibrary;

type
  TSemverHappyPath = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSatisfiesCaret;
    procedure TestSatisfiesTilde;
    procedure TestSatisfiesExact;
    procedure TestPrereleaseExcludedByDefault;
  end;

  TSemverConflictMatrix = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCaretAndCaretSameMajorIntersect;
    procedure TestCaretAcrossMajorBoundaryDoesNotIntersect;
    procedure TestExactAndCaretWithinIntersect;
    procedure TestExactAndCaretOutsideDoesNotIntersect;
    procedure TestUnionRangeIntersectsWhenEitherBranchOverlaps;
  end;

  TSemverMaxSatisfying = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestPicksHighestInRange;
    procedure TestReturnsEmptyWhenNoneMatch;
    procedure TestIgnoresOutOfRangeVersions;
  end;

{ ───────── helpers ───────── }

function Sat(const AVersion, ARange: string): Boolean;
begin
  Result := Satisfies(AVersion, ARange, DefaultSemverOptions);
end;

function Inter(const ARangeA, ARangeB: string): Boolean;
begin
  Result := RangeIntersects(ARangeA, ARangeB, DefaultSemverOptions);
end;

function PickMax(const AVersions: array of string; const ARange: string): string;
begin
  Result := MaxSatisfying(AVersions, ARange, DefaultSemverOptions);
end;

{ ───────── TSemverHappyPath ───────── }

procedure TSemverHappyPath.TestSatisfiesCaret;
begin
  Expect<Boolean>(Sat('1.2.3', '^1.2.0')).ToBe(True);
  Expect<Boolean>(Sat('1.9.0', '^1.2.0')).ToBe(True);
  Expect<Boolean>(Sat('2.0.0', '^1.2.0')).ToBe(False);
  Expect<Boolean>(Sat('1.1.9', '^1.2.0')).ToBe(False);
end;

procedure TSemverHappyPath.TestSatisfiesTilde;
begin
  Expect<Boolean>(Sat('1.2.5', '~1.2.0')).ToBe(True);
  Expect<Boolean>(Sat('1.3.0', '~1.2.0')).ToBe(False);
  Expect<Boolean>(Sat('1.2.0', '~1.2.0')).ToBe(True);
end;

procedure TSemverHappyPath.TestSatisfiesExact;
begin
  Expect<Boolean>(Sat('1.2.3', '1.2.3')).ToBe(True);
  Expect<Boolean>(Sat('1.2.4', '1.2.3')).ToBe(False);
end;

procedure TSemverHappyPath.TestPrereleaseExcludedByDefault;
begin
  { With the default options, prereleases on one side of the range do
    not "leak" into satisfaction of a non-prerelease range. The resolver
    relies on this: a manifest range "^1.2.0" should not pull in 2.0.0-rc.1. }
  Expect<Boolean>(Sat('2.0.0-rc.1', '^1.2.0')).ToBe(False);
end;

procedure TSemverHappyPath.SetupTests;
begin
  Test('satisfies caret happy path', TestSatisfiesCaret);
  Test('satisfies tilde happy path', TestSatisfiesTilde);
  Test('satisfies exact match',     TestSatisfiesExact);
  Test('prereleases excluded from non-prerelease ranges by default',
    TestPrereleaseExcludedByDefault);
end;

{ ───────── TSemverConflictMatrix ─────────
  CheckNodeConstraints uses RangeIntersects on every pair of accumulated
  constraints. These tests cover the cases the resolver leans on. }

procedure TSemverConflictMatrix.TestCaretAndCaretSameMajorIntersect;
begin
  { Two callers both want ^1.x — clearly compatible. }
  Expect<Boolean>(Inter('^1.2.0', '^1.5.0')).ToBe(True);
end;

procedure TSemverConflictMatrix.TestCaretAcrossMajorBoundaryDoesNotIntersect;
begin
  { Caller A wants ^1.0, caller B wants ^2.0. FPC's one-version-per-name
    rule turns this into a hard conflict. }
  Expect<Boolean>(Inter('^1.0.0', '^2.0.0')).ToBe(False);
end;

procedure TSemverConflictMatrix.TestExactAndCaretWithinIntersect;
begin
  Expect<Boolean>(Inter('1.2.3', '^1.2.0')).ToBe(True);
end;

procedure TSemverConflictMatrix.TestExactAndCaretOutsideDoesNotIntersect;
begin
  Expect<Boolean>(Inter('1.0.0', '^1.2.0')).ToBe(False);
end;

procedure TSemverConflictMatrix.TestUnionRangeIntersectsWhenEitherBranchOverlaps;
begin
  { Union ranges (||) intersect iff any branch overlaps the other range.
    The resolver doesn't construct union ranges itself, but a dependency
    manifest could declare one, and we must handle the case correctly. }
  Expect<Boolean>(Inter('^1.0.0 || ^3.0.0', '^3.5.0')).ToBe(True);
  Expect<Boolean>(Inter('^1.0.0 || ^3.0.0', '^2.0.0')).ToBe(False);
end;

procedure TSemverConflictMatrix.SetupTests;
begin
  Test('caret + caret same major intersect',
    TestCaretAndCaretSameMajorIntersect);
  Test('caret + caret across major boundary does not intersect',
    TestCaretAcrossMajorBoundaryDoesNotIntersect);
  Test('exact + caret within range intersects',
    TestExactAndCaretWithinIntersect);
  Test('exact + caret outside range does not intersect',
    TestExactAndCaretOutsideDoesNotIntersect);
  Test('union range intersects when either branch overlaps',
    TestUnionRangeIntersectsWhenEitherBranchOverlaps);
end;

{ ───────── TSemverMaxSatisfying ─────────
  Used by the (now-deferred) http registry consumer; also useful when a
  future workstream restores version negotiation. }

procedure TSemverMaxSatisfying.TestPicksHighestInRange;
begin
  Expect<string>(PickMax(['1.0.0', '1.2.0', '1.5.3', '1.9.0'], '^1.2.0'))
    .ToBe('1.9.0');
end;

procedure TSemverMaxSatisfying.TestReturnsEmptyWhenNoneMatch;
begin
  Expect<string>(PickMax(['0.1.0', '0.2.0'], '^1.0.0')).ToBe('');
end;

procedure TSemverMaxSatisfying.TestIgnoresOutOfRangeVersions;
begin
  Expect<string>(PickMax(['0.9.0', '1.0.0', '1.4.0', '2.0.0'], '^1.0.0'))
    .ToBe('1.4.0');
end;

procedure TSemverMaxSatisfying.SetupTests;
begin
  Test('picks highest in range',           TestPicksHighestInRange);
  Test('returns empty when none match',    TestReturnsEmptyWhenNoneMatch);
  Test('ignores out-of-range versions',    TestIgnoresOutOfRangeVersions);
end;

begin
  TestRunnerProgram.AddSuite(TSemverHappyPath.Create('Semver: happy path'));
  TestRunnerProgram.AddSuite(TSemverConflictMatrix.Create('Semver: conflict matrix'));
  TestRunnerProgram.AddSuite(TSemverMaxSatisfying.Create('Semver: MaxSatisfying'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
