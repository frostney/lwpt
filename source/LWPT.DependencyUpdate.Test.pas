{ LWPT.DependencyUpdate.Test — constraint comparison, skip rules, and
  mocked remote-tag collection (ADR-0039). No network. }
program LWPT.DependencyUpdate.Test;

{$I Shared.inc}

uses
  SysUtils,

  LWPT.Core,
  LWPT.DependencyUpdate,
  LWPT.GitProtocol,
  LWPT.Install,
  LWPT.Manifest,
  TestingPascalLibrary;

type
  TConstraintSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCaretInsideRangeIsCurrentWhenLockedMatchesLatest;
    procedure TestPatchInsideCaretIsNewer;
    procedure TestMajorOutsideCaretIsMajor;
    procedure TestZeroMinorBumpIsMajor;
    procedure TestLiteralNonSemverEqualityIsCurrent;
    procedure TestEmptyLockedWithLatestIsMajor;
  end;

  TSkipSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestWorkspaceAndLocalAreNotUpdatable;
    procedure TestGitHostIsUpdatable;
    procedure TestCollectSkipsWorkspaceLocalAndURL;
  end;

  TBumpSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestPreservesCaretAndTilde;
    procedure TestExactBecomesLatest;
    procedure TestOtherRangeBecomesCaret;
    procedure TestConstraintSatisfiesUsesSemverRange;
  end;

  TMockRefsSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestHighestTagStripsVPrefix;
    procedure TestCollectUsesInjectedRefs;
    procedure TestFilterUnknownNameFails;
    procedure TestJSONAndTableAreDeterministic;
  end;

function GitDep(const AName, ASource, ASpec: string): TDependency;
begin
  Result := Default(TDependency);
  Result.Name := AName;
  ParseBareDepString(ASource + '@' + ASpec, nil, Result);
  Result.Name := AName;
end;

function LocalDep(const AName, APath: string): TDependency;
begin
  Result := Default(TDependency);
  Result.Name := AName;
  ParseBareDepString(APath, nil, Result);
  Result.Name := AName;
end;

function WorkspaceDep(const AName: string): TDependency;
begin
  Result := Default(TDependency);
  Result.Name := AName;
  Result.SrcOriginal := 'workspace:auto';
  Result.SrcKind := skWorkspace;
  Result.VersionSpec := 'auto';
  Result.VersionKind := vkNone;
end;

function LockEntry(const AName, AVersion: string): TResolved;
begin
  Result := Default(TResolved);
  Result.Name := AName;
  Result.Version := AVersion;
end;

function Tag(const AName, ASHA: string): TGitRef;
begin
  Result := Default(TGitRef);
  Result.Kind := rkTag;
  Result.Name := AName;
  Result.SHA := ASHA;
end;

function MockLeafRefs(const ARepoURL: string): TGitRefArray;
begin
  SetLength(Result, 0);
  if Pos('leaf', ARepoURL) > 0 then
  begin
    SetLength(Result, 3);
    Result[0] := Tag('v0.6.0', StringOfChar('a', 40));
    Result[1] := Tag('v0.6.1', StringOfChar('b', 40));
    Result[2] := Tag('v0.7.0', StringOfChar('c', 40));
  end
  else if Pos('widget', ARepoURL) > 0 then
  begin
    SetLength(Result, 2);
    Result[0] := Tag('v1.2.0', StringOfChar('d', 40));
    Result[1] := Tag('v1.2.3', StringOfChar('e', 40));
  end;
end;

procedure TConstraintSuite.TestCaretInsideRangeIsCurrentWhenLockedMatchesLatest;
begin
  Expect<Integer>(Ord(ClassifyOutdatedStatus('0.6.1', '0.6.1')))
    .ToBe(Ord(ousCurrent));
  Expect<Integer>(Ord(ClassifyOutdatedStatus('v1.2.3', '1.2.3')))
    .ToBe(Ord(ousCurrent));
end;

procedure TConstraintSuite.TestPatchInsideCaretIsNewer;
begin
  Expect<Integer>(Ord(ClassifyOutdatedStatus('1.2.0', '1.2.3')))
    .ToBe(Ord(ousNewer));
  Expect<Integer>(Ord(ClassifyOutdatedStatus('1.2.0', '1.3.0')))
    .ToBe(Ord(ousNewer));
end;

procedure TConstraintSuite.TestMajorOutsideCaretIsMajor;
begin
  Expect<Integer>(Ord(ClassifyOutdatedStatus('1.9.0', '2.0.0')))
    .ToBe(Ord(ousMajor));
end;

procedure TConstraintSuite.TestZeroMinorBumpIsMajor;
begin
  Expect<Integer>(Ord(ClassifyOutdatedStatus('0.6.1', '0.7.0')))
    .ToBe(Ord(ousMajor));
  Expect<Integer>(Ord(ClassifyOutdatedStatus('0.6.1', '0.6.2')))
    .ToBe(Ord(ousNewer));
end;

procedure TConstraintSuite.TestLiteralNonSemverEqualityIsCurrent;
begin
  Expect<Integer>(Ord(ClassifyOutdatedStatus('stable', 'stable')))
    .ToBe(Ord(ousCurrent));
  Expect<Integer>(Ord(ClassifyOutdatedStatus('stable', 'next')))
    .ToBe(Ord(ousNewer));
end;

procedure TConstraintSuite.TestEmptyLockedWithLatestIsMajor;
begin
  Expect<Integer>(Ord(ClassifyOutdatedStatus('', '1.0.0')))
    .ToBe(Ord(ousMajor));
end;

procedure TConstraintSuite.SetupTests;
begin
  Test('locked matching latest is current',
    TestCaretInsideRangeIsCurrentWhenLockedMatchesLatest);
  Test('same-major newer tag is newer', TestPatchInsideCaretIsNewer);
  Test('major bump is major', TestMajorOutsideCaretIsMajor);
  Test('0.x minor bump is major', TestZeroMinorBumpIsMajor);
  Test('non-semver tags compare as text', TestLiteralNonSemverEqualityIsCurrent);
  Test('missing lock with a latest tag is major',
    TestEmptyLockedWithLatestIsMajor);
end;

procedure TSkipSuite.TestWorkspaceAndLocalAreNotUpdatable;
begin
  Expect<Boolean>(IsUpdatableSource(WorkspaceDep('testing'))).ToBe(False);
  Expect<Boolean>(IsUpdatableSource(LocalDep('leaf', './vendor/leaf'))).ToBe(False);
  Expect<Boolean>(IsUpdatableSource(LocalDep('abs', '/tmp/leaf'))).ToBe(False);
end;

procedure TSkipSuite.TestGitHostIsUpdatable;
begin
  Expect<Boolean>(IsUpdatableSource(GitDep('leaf', 'acme/leaf', '^0.6.0')))
    .ToBe(True);
  Expect<Boolean>(IsUpdatableSource(GitDep('leaf', 'gitlab:acme/leaf', '^1.0.0')))
    .ToBe(True);
end;

procedure TSkipSuite.TestCollectSkipsWorkspaceLocalAndURL;
var
  Manifest: TManifest;
  Lock: TResolvedArray;
  Entries: TOutdatedEntryArray;
begin
  Manifest := Default(TManifest);
  SetLength(Manifest.Deps, 4);
  Manifest.Deps[0] := WorkspaceDep('testing');
  Manifest.Deps[1] := LocalDep('cli', './packages/cli');
  Manifest.Deps[2] := GitDep('leaf', 'acme/leaf', '^0.6.0');
  Manifest.Deps[3] := Default(TDependency);
  Manifest.Deps[3].Name := 'dist';
  ParseBareDepString('https://example.com/dist.tar.gz', nil, Manifest.Deps[3]);
  Manifest.Deps[3].Name := 'dist';
  SetLength(Lock, 1);
  Lock[0] := LockEntry('leaf', 'v0.6.1');
  Entries := CollectOutdated(Manifest, Lock, @MockLeafRefs);
  Expect<Integer>(Length(Entries)).ToBe(1);
  Expect<string>(Entries[0].Name).ToBe('leaf');
  Expect<string>(Entries[0].Latest).ToBe('0.7.0');
  Expect<Integer>(Ord(Entries[0].Status)).ToBe(Ord(ousMajor));
end;

procedure TSkipSuite.SetupTests;
begin
  Test('workspace and local sources are not updatable',
    TestWorkspaceAndLocalAreNotUpdatable);
  Test('git-host sources are updatable', TestGitHostIsUpdatable);
  Test('collect skips workspace, local, and URL deps',
    TestCollectSkipsWorkspaceLocalAndURL);
end;

procedure TBumpSuite.TestPreservesCaretAndTilde;
begin
  Expect<string>(BumpConstraint('^0.6.0', vkSemverRange, '0.7.0', 'v0.7.0'))
    .ToBe('^0.7.0');
  Expect<string>(BumpConstraint('~1.2.0', vkSemverRange, '1.3.0', 'v1.3.0'))
    .ToBe('~1.3.0');
end;

procedure TBumpSuite.TestExactBecomesLatest;
begin
  Expect<string>(BumpConstraint('1.2.0', vkSemverExact, '1.2.3', 'v1.2.3'))
    .ToBe('1.2.3');
end;

procedure TBumpSuite.TestOtherRangeBecomesCaret;
begin
  Expect<string>(BumpConstraint('>=1.0.0 <2.0.0', vkSemverRange, '2.0.0',
    'v2.0.0')).ToBe('^2.0.0');
end;

procedure TBumpSuite.TestConstraintSatisfiesUsesSemverRange;
begin
  Expect<Boolean>(ConstraintSatisfiesLatest('^0.6.0', vkSemverRange,
    '0.6.2', 'v0.6.2')).ToBe(True);
  Expect<Boolean>(ConstraintSatisfiesLatest('^0.6.0', vkSemverRange,
    '0.7.0', 'v0.7.0')).ToBe(False);
  Expect<Boolean>(ConstraintSatisfiesLatest('1.2.3', vkSemverExact,
    '1.2.3', 'v1.2.3')).ToBe(True);
end;

procedure TBumpSuite.SetupTests;
begin
  Test('bump keeps a leading caret or tilde', TestPreservesCaretAndTilde);
  Test('exact specs become the latest version', TestExactBecomesLatest);
  Test('other ranges rewrite as caret-latest', TestOtherRangeBecomesCaret);
  Test('constraint satisfaction uses the SemVer range',
    TestConstraintSatisfiesUsesSemverRange);
end;

procedure TMockRefsSuite.TestHighestTagStripsVPrefix;
var
  Refs: TGitRefArray;
  RefName, Version: string;
begin
  SetLength(Refs, 3);
  Refs[0] := Tag('v1.0.0', StringOfChar('a', 40));
  Refs[1] := Tag('not-a-version', StringOfChar('b', 40));
  Refs[2] := Tag('v1.4.0', StringOfChar('c', 40));
  Expect<Boolean>(HighestSemverTag(Refs, RefName, Version)).ToBe(True);
  Expect<string>(RefName).ToBe('v1.4.0');
  Expect<string>(Version).ToBe('1.4.0');
end;

procedure TMockRefsSuite.TestCollectUsesInjectedRefs;
var
  Manifest: TManifest;
  Lock: TResolvedArray;
  Entries: TOutdatedEntryArray;
begin
  Manifest := Default(TManifest);
  SetLength(Manifest.Deps, 2);
  Manifest.Deps[0] := GitDep('leaf', 'acme/leaf', '^0.6.0');
  Manifest.Deps[1] := GitDep('widget', 'acme/widget', '^1.2.0');
  SetLength(Lock, 2);
  Lock[0] := LockEntry('leaf', 'v0.6.1');
  Lock[1] := LockEntry('widget', 'v1.2.3');
  Entries := CollectOutdated(Manifest, Lock, @MockLeafRefs);
  Expect<Integer>(Length(Entries)).ToBe(2);
  Expect<string>(Entries[0].LatestRef).ToBe('v0.7.0');
  Expect<Integer>(Ord(Entries[0].Status)).ToBe(Ord(ousMajor));
  Expect<string>(Entries[1].Latest).ToBe('1.2.3');
  Expect<Integer>(Ord(Entries[1].Status)).ToBe(Ord(ousCurrent));
  Expect<Boolean>(HasNonCurrent(Entries)).ToBe(True);
end;

procedure TMockRefsSuite.TestFilterUnknownNameFails;
var
  Manifest: TManifest;
  Entries: TOutdatedEntryArray;
  Raised: Boolean;
begin
  Manifest := Default(TManifest);
  SetLength(Manifest.Deps, 1);
  Manifest.Deps[0] := GitDep('leaf', 'acme/leaf', '^0.6.0');
  Entries := CollectOutdated(Manifest, nil, @MockLeafRefs);
  Raised := False;
  try
    FilterNamedEntries(Entries, ['nope']);
  except
    on E: EManifestError do
      Raised := Pos('nope', E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TMockRefsSuite.TestJSONAndTableAreDeterministic;
var
  Manifest: TManifest;
  Lock: TResolvedArray;
  Entries: TOutdatedEntryArray;
  FirstTable, SecondTable, FirstJSON, SecondJSON: string;
begin
  Manifest := Default(TManifest);
  SetLength(Manifest.Deps, 1);
  Manifest.Deps[0] := GitDep('widget', 'acme/widget', '^1.2.0');
  SetLength(Lock, 1);
  Lock[0] := LockEntry('widget', 'v1.2.0');
  Entries := CollectOutdated(Manifest, Lock, @MockLeafRefs);
  FirstTable := FormatOutdatedTable(Entries);
  SecondTable := FormatOutdatedTable(Entries);
  FirstJSON := FormatOutdatedJSON(Entries);
  SecondJSON := FormatOutdatedJSON(Entries);
  Expect<string>(FirstTable).ToBe(SecondTable);
  Expect<string>(FirstJSON).ToBe(SecondJSON);
  Expect<Boolean>(Pos('"status":"newer"', FirstJSON) > 0).ToBe(True);
  Expect<Boolean>(Pos('widget', FirstTable) > 0).ToBe(True);
end;

procedure TMockRefsSuite.SetupTests;
begin
  Test('highest SemVer tag ignores non-version tags',
    TestHighestTagStripsVPrefix);
  Test('collect uses the injected ref list', TestCollectUsesInjectedRefs);
  Test('filtering an unknown name is an error', TestFilterUnknownNameFails);
  Test('human and JSON reports are deterministic',
    TestJSONAndTableAreDeterministic);
end;

begin
  TestRunnerProgram.AddSuite(TConstraintSuite.Create(
    PROJECT_NAME + '.DependencyUpdate: status'));
  TestRunnerProgram.AddSuite(TSkipSuite.Create(
    PROJECT_NAME + '.DependencyUpdate: skip rules'));
  TestRunnerProgram.AddSuite(TBumpSuite.Create(
    PROJECT_NAME + '.DependencyUpdate: constraint bump'));
  TestRunnerProgram.AddSuite(TMockRefsSuite.Create(
    PROJECT_NAME + '.DependencyUpdate: mocked refs'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
