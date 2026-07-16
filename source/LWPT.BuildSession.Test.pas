program LWPT.BuildSession.Test;

{$I Shared.inc}
{$J-}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Core,
  TestingPascalLibrary;

type
  TBuildSessionTests = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
    procedure WriteText(const APath, AText: string);
    function BasicRequest: TBuildPublicationRequest;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestSessionsAreUniqueAndPrivate;
    procedure TestPathKeysAreBoundedAndCollisionResistant;
    procedure TestSuccessfulSessionIsRemoved;
    procedure TestStaleCandidateDoesNotReplacePublicOutput;
    procedure TestCurrentCandidatePublishesAtomically;
    procedure TestCompetingCandidateLosesPublication;
    procedure TestRootUnitPathIgnoresSessionStaging;
    procedure TestRootUnitPathIgnoresDeclaredOutputs;
    procedure TestSearchPathContentChangeRefusesPublication;
    procedure TestSourceDirectoryChangeRefusesPublication;
    procedure TestExplicitExcludedResourceChangeRefusesPublication;
    procedure TestHookInputChangeRefusesPublication;
    {$IFDEF UNIX}
    procedure TestSymlinkedSearchRootChangeRefusesPublication;
    procedure TestPublicationLockUsesFilesystemIdentity;
    {$ENDIF}
    procedure TestRepairRemovesInactiveAndKeepsLiveSessions;
    procedure TestRepairRemovesInterruptedSessionCreation;
  end;

procedure TBuildSessionTests.ResetScratch;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TBuildSessionTests.WriteText(const APath, AText: string);
var
  Lines: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

function TBuildSessionTests.BasicRequest: TBuildPublicationRequest;
begin
  Result := Default(TBuildPublicationRequest);
  Result.CompilerID := 'test-compiler';
  Result.CompilerExecutable := '/test/compiler';
  Result.CompilerVersion := '1.0.0';
  Result.Source := 'source/app.pas';
  Result.Output := 'build/app';
  Result.OutputKind := 'executable';
  Result.Mode := 'dev';
  SetLength(Result.UnitPaths, 1);
  Result.UnitPaths[0] := 'source';
end;

procedure TBuildSessionTests.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/build-session-unit');
end;

procedure TBuildSessionTests.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TBuildSessionTests.TestSessionsAreUniqueAndPrivate;
var
  First, Second: TLWPTBuildSession;
begin
  ResetScratch;
  First := TLWPTBuildSession.Create(FScratch);
  Second := TLWPTBuildSession.Create(FScratch);
  try
    Expect<Boolean>(First.SessionID <> Second.SessionID).ToBe(True);
    Expect<Boolean>(First.JobRoot('app') <> Second.JobRoot('app')).ToBe(True);
    Expect<Boolean>(First.JobRoot('one:two')
      <> First.JobRoot('one_two')).ToBe(True);
    Expect<Boolean>(DirectoryExists(First.SessionRoot)).ToBe(True);
    Expect<Boolean>(DirectoryExists(Second.SessionRoot)).ToBe(True);
  finally
    First.Finish(False, 'test');
    Second.Finish(False, 'test');
    First.Free;
    Second.Free;
  end;
end;

procedure TBuildSessionTests.TestPathKeysAreBoundedAndCollisionResistant;
var
  First, Second, LongKey: string;
begin
  First := BuildSessionPathKey('one:two.pas');
  Second := BuildSessionPathKey('one_two.pas');
  LongKey := BuildSessionPathKey(StringOfChar('a', 300) + '.pas');

  Expect<Boolean>(First <> Second).ToBe(True);
  Expect<Boolean>(Length(First) <= 49).ToBe(True);
  Expect<Boolean>(Length(Second) <= 49).ToBe(True);
  Expect<Boolean>(Length(LongKey) <= 49).ToBe(True);
end;

procedure TBuildSessionTests.TestSuccessfulSessionIsRemoved;
var
  Session: TLWPTBuildSession;
  Root: string;
begin
  ResetScratch;
  Session := TLWPTBuildSession.Create(FScratch);
  Root := Session.SessionRoot;
  Session.Finish(True);
  Session.Free;
  Expect<Boolean>(DirectoryExists(Root)).ToBe(False);
end;

procedure TBuildSessionTests.TestStaleCandidateDoesNotReplacePublicOutput;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/source/app.pas', 'begin WriteLn; end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/build/app');
    Expect<string>(Trim(Lines.Text)).ToBe('old');
  finally
    Lines.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(True);
end;

procedure TBuildSessionTests.TestCurrentCandidatePublishesAtomically;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/build/app');
    Expect<string>(Trim(Lines.Text)).ToBe('new');
  finally
    Lines.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(False);
end;

procedure TBuildSessionTests.TestCompetingCandidateLosesPublication;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate-first/app', 'winner');
  WriteText(FScratch + '/candidate-second/app', 'late');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate-first/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate-second/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/build/app');
    Expect<string>(Trim(Lines.Text)).ToBe('winner');
  finally
    Lines.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/candidate-second/app')).ToBe(True);
end;

procedure TBuildSessionTests.TestRootUnitPathIgnoresSessionStaging;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
  Session: TLWPTBuildSession;
  Candidate: string;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/app.pas', 'begin end.');
  Request := BasicRequest;
  Request.Source := 'app.pas';
  SetLength(Request.UnitPaths, 1);
  Request.UnitPaths[0] := '.';
  Session := TLWPTBuildSession.Create(FScratch);
  try
    Candidate := Session.JobRoot('app') + '/app';
    WriteText(Candidate, 'new');
    Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
      'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
    WriteText(Session.JobRoot('app') + '/units/app.ppu', 'private');

    Publication := PublishBuildArtifact(FScratch, Candidate, 'build/app',
      Fingerprint, 'lwpt.toml', 'lwpt.cfg', 'lwpt.lock', '.lwpt/modules',
      Request);

    Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
    Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(True);
    Session.Finish(True);
  finally
    Session.Free;
  end;
end;

procedure TBuildSessionTests.TestRootUnitPathIgnoresDeclaredOutputs;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/app.pas', 'begin end.');
  WriteText(FScratch + '/other.pas', 'begin end.');
  WriteText(FScratch + '/candidate/other', 'new');
  Request := BasicRequest;
  Request.Source := 'other.pas';
  Request.Output := 'build/other';
  SetLength(Request.UnitPaths, 1);
  Request.UnitPaths[0] := '.';
  SetLength(Request.ExcludedPaths, 2);
  Request.ExcludedPaths[0] := 'build/app';
  Request.ExcludedPaths[1] := 'build/other';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/build/app', 'unrelated published output');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/other', 'build/other', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
  Expect<Boolean>(FileExists(FScratch + '/build/other')).ToBe(True);
end;

procedure TBuildSessionTests.TestSearchPathContentChangeRefusesPublication;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/extra/SharedUnit.pas', 'unit SharedUnit; end.');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.UnitPaths, 2);
  Request.UnitPaths[0] := 'source';
  Request.UnitPaths[1] := 'extra';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/extra/SharedUnit.pas',
    'unit SharedUnit; interface implementation end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(True);
end;

procedure TBuildSessionTests.TestSourceDirectoryChangeRefusesPublication;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas',
    'program app;'#10'{$I sibling.inc}'#10'begin end.');
  WriteText(FScratch + '/source/sibling.inc', 'const Value = 1;');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.UnitPaths, 0);
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/source/sibling.inc', 'const Value = 2;');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TBuildSessionTests.TestExplicitExcludedResourceChangeRefusesPublication;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/generated.res', 'first');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.Resources, 1);
  Request.Resources[0] := 'build/generated.res';
  SetLength(Request.ExcludedPaths, 2);
  Request.ExcludedPaths[0] := 'build/generated.res';
  Request.ExcludedPaths[1] := 'build/app';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/build/generated.res', 'second');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TBuildSessionTests.TestHookInputChangeRefusesPublication;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/scripts/sign.pas', 'program sign; begin end.');
  WriteText(FScratch + '/scripts/signing-key.txt', 'first');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.HookDefinition, 2);
  Request.HookDefinition[0] := 'sign';
  Request.HookDefinition[1] := 'scripts/sign.pas';
  SetLength(Request.HookInputs, 2);
  Request.HookInputs[0] := 'scripts/sign.pas';
  Request.HookInputs[1] := 'scripts/signing-key.txt';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/scripts/signing-key.txt', 'second');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

{$IFDEF UNIX}
procedure TBuildSessionTests.TestSymlinkedSearchRootChangeRefusesPublication;
var
  Request: TBuildPublicationRequest;
  Fingerprint: string;
  Publication: TBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/lwpt.toml', '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/packages/shared/source/SharedUnit.pas',
    'unit SharedUnit; interface implementation end.');
  ForceDirectories(FScratch + '/.lwpt/modules');
  if FpSymlink(PAnsiChar('../../packages/shared'),
    PAnsiChar(FScratch + '/.lwpt/modules/shared')) <> 0 then
    raise Exception.Create('fixture: workspace symlink creation failed');
  if FpSymlink(PAnsiChar('.'),
    PAnsiChar(FScratch + '/packages/shared/loop')) <> 0 then
    raise Exception.Create('fixture: cycle symlink creation failed');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);
  WriteText(FScratch + '/packages/shared/source/SharedUnit.pas',
    'unit SharedUnit; interface const Changed = True; implementation end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, 'lwpt.toml',
    'lwpt.cfg', 'lwpt.lock', '.lwpt/modules', Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TBuildSessionTests.TestPublicationLockUsesFilesystemIdentity;
var
  PhysicalPath, AliasPath: string;
begin
  ResetScratch;
  ForceDirectories(FScratch + '/physical');
  if FpSymlink(PAnsiChar('physical'),
    PAnsiChar(FScratch + '/alias')) <> 0 then
    raise Exception.Create('fixture: output alias creation failed');

  PhysicalPath := BuildPublicationLockPath(FScratch,
    FScratch + '/physical/app');
  AliasPath := BuildPublicationLockPath(FScratch,
    FScratch + '/alias/app');

  Expect<string>(AliasPath).ToBe(PhysicalPath);
end;
{$ENDIF}

procedure TBuildSessionTests.TestRepairRemovesInactiveAndKeepsLiveSessions;
var
  LiveSession, FailedSession: TLWPTBuildSession;
  LiveRoot, FailedRoot: string;
  Removed, Retained: Integer;
begin
  ResetScratch;
  LiveSession := TLWPTBuildSession.Create(FScratch);
  FailedSession := TLWPTBuildSession.Create(FScratch);
  LiveRoot := LiveSession.SessionRoot;
  FailedRoot := FailedSession.SessionRoot;
  FailedSession.Finish(False, 'failed');
  FailedSession.Free;
  WriteText(LiveRoot + '/session.state', 'unreadable live state');

  RepairBuildSessions(FScratch, Removed, Retained);
  Expect<Integer>(Removed).ToBe(1);
  Expect<Integer>(Retained).ToBe(1);
  Expect<Boolean>(DirectoryExists(FailedRoot)).ToBe(False);
  Expect<Boolean>(DirectoryExists(LiveRoot)).ToBe(True);

  LiveSession.Finish(True);
  LiveSession.Free;
end;

procedure TBuildSessionTests.TestRepairRemovesInterruptedSessionCreation;
var
  Removed, Retained: Integer;
begin
  ResetScratch;
  WriteText(FScratch
    + '/.lwpt/sessions/.creating-session-abandoned/session.state',
    '999999999'#10'active'#10'1');

  RepairBuildSessions(FScratch, Removed, Retained);

  Expect<Integer>(Removed).ToBe(1);
  Expect<Integer>(Retained).ToBe(0);
  Expect<Boolean>(DirectoryExists(FScratch
    + '/.lwpt/sessions/.creating-session-abandoned')).ToBe(False);
end;

procedure TBuildSessionTests.SetupTests;
begin
  Test('sessions have unique private job roots',
    TestSessionsAreUniqueAndPrivate);
  Test('path keys are bounded and resist sanitised collisions',
    TestPathKeysAreBoundedAndCollisionResistant);
  Test('successful sessions remove private staging',
    TestSuccessfulSessionIsRemoved);
  Test('stale candidate cannot replace public output',
    TestStaleCandidateDoesNotReplacePublicOutput);
  Test('current candidate atomically replaces public output',
    TestCurrentCandidatePublishesAtomically);
  Test('competing candidate loses publication to the winner',
    TestCompetingCandidateLosesPublication);
  Test('root unit path excludes changing session staging',
    TestRootUnitPathIgnoresSessionStaging);
  Test('root unit path excludes declared build outputs',
    TestRootUnitPathIgnoresDeclaredOutputs);
  Test('search-path content change refuses publication',
    TestSearchPathContentChangeRefusesPublication);
  Test('source-directory content change refuses publication',
    TestSourceDirectoryChangeRefusesPublication);
  Test('explicit resources remain inputs when also declared outputs',
    TestExplicitExcludedResourceChangeRefusesPublication);
  Test('postbuild hook input changes refuse publication',
    TestHookInputChangeRefusesPublication);
  {$IFDEF UNIX}
  Test('symlinked search roots detect changes and terminate cycles',
    TestSymlinkedSearchRootChangeRefusesPublication);
  Test('publication locks use destination filesystem identity',
    TestPublicationLockUsesFilesystemIdentity);
  {$ENDIF}
  Test('repair removes inactive sessions and retains live sessions',
    TestRepairRemovesInactiveAndKeepsLiveSessions);
  Test('repair removes interrupted session creation',
    TestRepairRemovesInterruptedSessionCreation);
end;

begin
  TestRunnerProgram.AddSuite(TBuildSessionTests.Create(
    'build sessions and publication'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
