program LWPT.BuildSession.Test;

{$I Shared.inc}
{$J-}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.BuildSession,
  LWPT.Core,
  TestingPascalLibrary;

type
  TLWPTBuildSessionTests = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
    procedure WriteText(const APath, AText: string);
    function BasicRequest: TLWPTBuildPublicationRequest;
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
    procedure TestParsedManifestChangeRefusesFingerprint;
    procedure TestRootUnitPathIgnoresSessionStaging;
    procedure TestRootUnitPathIgnoresDeclaredOutputs;
    procedure TestSearchPathContentChangeRefusesPublication;
    procedure TestSourceDirectoryChangeRefusesPublication;
    procedure TestExplicitExcludedResourceChangeRefusesPublication;
    procedure TestHookInputChangeRefusesPublication;
    {$IFDEF UNIX}
    procedure TestSymlinkedSearchRootChangeRefusesPublication;
    procedure TestDirectoryAliasesHaveDeterministicFingerprint;
    procedure TestPublicationLockUsesFilesystemIdentity;
    {$ENDIF}
    procedure TestRepairRemovesInactiveAndKeepsLiveSessions;
    procedure TestRepairRemovesInterruptedSessionCreation;
  end;

procedure TLWPTBuildSessionTests.ResetScratch;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TLWPTBuildSessionTests.WriteText(const APath, AText: string);
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

function TLWPTBuildSessionTests.BasicRequest: TLWPTBuildPublicationRequest;
begin
  Result := Default(TLWPTBuildPublicationRequest);
  Result.BuildRequest := DefaultBuildRequest;
  Result.BuildRequest.Compiler.ID := 'test-compiler';
  Result.BuildRequest.Compiler.VersionIdentity := '1.0.0';
  Result.CompilerExecutable := '/test/compiler';
  Result.ManifestContentHash := SHA256File(
    FScratch + '/' + MANIFEST_FILE);
  Result.PublicOutput := 'build/app';
  Result.BuildRequest.Target.OS := 'test-os';
  Result.BuildRequest.Target.Architecture := 'test-arch';
  Result.BuildRequest.Inputs.EntryPoint := 'source/app.pas';
  SetLength(Result.BuildRequest.Inputs.Sources, 1);
  Result.BuildRequest.Inputs.Sources[0] := 'source/app.pas';
  Result.BuildRequest.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.BuildRequest.Mode := BUILD_MODE_DEV;
  Result.BuildRequest.Outputs.Artifact := 'candidate/app';
  SetLength(Result.BuildRequest.Inputs.UnitPaths, 1);
  Result.BuildRequest.Inputs.UnitPaths[0] := 'source';
end;

procedure TLWPTBuildSessionTests.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/build-session-unit');
end;

procedure TLWPTBuildSessionTests.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TLWPTBuildSessionTests.TestSessionsAreUniqueAndPrivate;
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

procedure TLWPTBuildSessionTests.TestPathKeysAreBoundedAndCollisionResistant;
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

procedure TLWPTBuildSessionTests.TestSuccessfulSessionIsRemoved;
var
  Session: TLWPTBuildSession;
  OwnerPath, Root: string;
begin
  ResetScratch;
  Session := TLWPTBuildSession.Create(FScratch);
  Root := Session.SessionRoot;
  OwnerPath := FScratch + '/' + BUILD_SESSIONS_DIR + '/locks/owners/'
    + Session.SessionID + '.lock';
  Expect<Boolean>(FileExists(OwnerPath)).ToBe(True);
  Session.Finish(True);
  Session.Free;
  Expect<Boolean>(DirectoryExists(Root)).ToBe(False);
  Expect<Boolean>(FileExists(OwnerPath)).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestStaleCandidateDoesNotReplacePublicOutput;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE,
    '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/source/app.pas', 'begin WriteLn; end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

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

procedure TLWPTBuildSessionTests.TestCurrentCandidatePublishesAtomically;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

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

procedure TLWPTBuildSessionTests.TestCompetingCandidateLosesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate-first/app', 'winner');
  WriteText(FScratch + '/candidate-second/app', 'late');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate-first/app', 'build/app', Fingerprint,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate-second/app', 'build/app', Fingerprint,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);
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

procedure TLWPTBuildSessionTests.TestParsedManifestChangeRefusesFingerprint;
var
  Request: TLWPTBuildPublicationRequest;
  Raised: Boolean;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  Request := BasicRequest;
  WriteText(FScratch + '/' + MANIFEST_FILE,
    '[package]'#10'name = "changed-app"');
  Raised := False;
  try
    CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
      CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  except
    on E: ELWPTError do
      Raised := Pos('manifest changed after it was parsed', E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestRootUnitPathIgnoresSessionStaging;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Session: TLWPTBuildSession;
  Candidate: string;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/app.pas', 'begin end.');
  Request := BasicRequest;
  Request.BuildRequest.Inputs.EntryPoint := 'app.pas';
  Request.BuildRequest.Inputs.Sources[0] := 'app.pas';
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 1);
  Request.BuildRequest.Inputs.UnitPaths[0] := '.';
  Session := TLWPTBuildSession.Create(FScratch);
  try
    Candidate := Session.JobRoot('app') + '/app';
    WriteText(Candidate, 'new');
    Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
      CFG_FILE, LOCKFILE, MODULES_DIR, Request);
    WriteText(Session.JobRoot('app') + '/units/app.ppu', 'private');

    Publication := PublishBuildArtifact(FScratch, Candidate, 'build/app',
      Fingerprint, MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR,
      Request);

    Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
    Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(True);
    Session.Finish(True);
  finally
    Session.Free;
  end;
end;

procedure TLWPTBuildSessionTests.TestRootUnitPathIgnoresDeclaredOutputs;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/app.pas', 'begin end.');
  WriteText(FScratch + '/other.pas', 'begin end.');
  WriteText(FScratch + '/candidate/other', 'new');
  Request := BasicRequest;
  Request.BuildRequest.Inputs.EntryPoint := 'other.pas';
  Request.BuildRequest.Inputs.Sources[0] := 'other.pas';
  Request.PublicOutput := 'build/other';
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 1);
  Request.BuildRequest.Inputs.UnitPaths[0] := '.';
  SetLength(Request.ExcludedPaths, 2);
  Request.ExcludedPaths[0] := 'build/app';
  Request.ExcludedPaths[1] := 'build/other';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/build/app', 'unrelated published output');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/other', 'build/other', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
  Expect<Boolean>(FileExists(FScratch + '/build/other')).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestSearchPathContentChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/extra/SharedUnit.pas', 'unit SharedUnit; end.');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 2);
  Request.BuildRequest.Inputs.UnitPaths[0] := 'source';
  Request.BuildRequest.Inputs.UnitPaths[1] := 'extra';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/extra/SharedUnit.pas',
    'unit SharedUnit; interface implementation end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestSourceDirectoryChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas',
    'program app;'#10'{$I sibling.inc}'#10'begin end.');
  WriteText(FScratch + '/source/sibling.inc', 'const Value = 1;');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 0);
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/source/sibling.inc', 'const Value = 2;');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestExplicitExcludedResourceChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/generated.res', 'first');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.Resources, 1);
  Request.BuildRequest.Inputs.Resources[0] := 'build/generated.res';
  SetLength(Request.ExcludedPaths, 2);
  Request.ExcludedPaths[0] := 'build/generated.res';
  Request.ExcludedPaths[1] := 'build/app';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/build/generated.res', 'second');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestHookInputChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
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
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/scripts/signing-key.txt', 'second');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

{$IFDEF UNIX}
procedure TLWPTBuildSessionTests.TestSymlinkedSearchRootChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/packages/shared/source/SharedUnit.pas',
    'unit SharedUnit; interface implementation end.');
  ForceDirectories(FScratch + '/' + MODULES_DIR);
  if FpSymlink(PAnsiChar('../../packages/shared'),
    PAnsiChar(FScratch + '/' + MODULES_DIR + '/shared')) <> 0 then
    raise Exception.Create('fixture: workspace symlink creation failed');
  if FpSymlink(PAnsiChar('.'),
    PAnsiChar(FScratch + '/packages/shared/loop')) <> 0 then
    raise Exception.Create('fixture: cycle symlink creation failed');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/packages/shared/source/SharedUnit.pas',
    'unit SharedUnit; interface const Changed = True; implementation end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestDirectoryAliasesHaveDeterministicFingerprint;
var
  FirstRequest: TLWPTBuildPublicationRequest;
  FirstFingerprint, SecondFingerprint: string;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/modules/real/value.txt', 'same');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/z-alias')) <> 0 then
    raise Exception.Create('fixture: first z alias creation failed');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/a-alias')) <> 0 then
    raise Exception.Create('fixture: first a alias creation failed');
  FirstRequest := Default(TLWPTBuildPublicationRequest);
  FirstRequest.BuildRequest := DefaultBuildRequest;
  FirstRequest.BuildRequest.Compiler.ID := 'test-compiler';
  FirstRequest.BuildRequest.Compiler.VersionIdentity := '1.0.0';
  FirstRequest.CompilerExecutable := '/test/compiler';
  FirstRequest.ManifestContentHash := SHA256File(
    FScratch + '/' + MANIFEST_FILE);
  FirstRequest.PublicOutput := 'build/app';
  FirstRequest.BuildRequest.Target.OS := 'test-os';
  FirstRequest.BuildRequest.Target.Architecture := 'test-arch';
  FirstRequest.BuildRequest.Inputs.EntryPoint := 'source/app.pas';
  SetLength(FirstRequest.BuildRequest.Inputs.Sources, 1);
  FirstRequest.BuildRequest.Inputs.Sources[0] := 'source/app.pas';
  FirstRequest.BuildRequest.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  FirstRequest.BuildRequest.Mode := BUILD_MODE_DEV;
  FirstRequest.BuildRequest.Outputs.Artifact := 'candidate/app';
  SetLength(FirstRequest.BuildRequest.Inputs.UnitPaths, 1);
  FirstRequest.BuildRequest.Inputs.UnitPaths[0] := 'modules';
  FirstFingerprint := CaptureBuildPublicationFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, 'modules', FirstRequest);
  SysUtils.DeleteFile(FScratch + '/modules/a-alias');
  SysUtils.DeleteFile(FScratch + '/modules/z-alias');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/a-alias')) <> 0 then
    raise Exception.Create('fixture: second a alias creation failed');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/z-alias')) <> 0 then
    raise Exception.Create('fixture: second z alias creation failed');
  SecondFingerprint := CaptureBuildPublicationFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, 'modules', FirstRequest);

  Expect<string>(SecondFingerprint).ToBe(FirstFingerprint);
end;

procedure TLWPTBuildSessionTests.TestPublicationLockUsesFilesystemIdentity;
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

procedure TLWPTBuildSessionTests.TestRepairRemovesInactiveAndKeepsLiveSessions;
var
  LiveSession, FailedSession: TLWPTBuildSession;
  LiveRoot, FailedRoot, FailedOwnerPath: string;
  Removed, Retained: Integer;
begin
  ResetScratch;
  LiveSession := TLWPTBuildSession.Create(FScratch);
  FailedSession := TLWPTBuildSession.Create(FScratch);
  LiveRoot := LiveSession.SessionRoot;
  FailedRoot := FailedSession.SessionRoot;
  FailedOwnerPath := FScratch + '/' + BUILD_SESSIONS_DIR + '/locks/owners/'
    + FailedSession.SessionID + '.lock';
  FailedSession.Finish(False, 'failed');
  FailedSession.Free;
  Expect<Boolean>(FileExists(FailedOwnerPath)).ToBe(True);
  WriteText(LiveRoot + '/session.state', 'unreadable live state');

  RepairBuildSessions(FScratch, Removed, Retained);
  Expect<Integer>(Removed).ToBe(1);
  Expect<Integer>(Retained).ToBe(1);
  Expect<Boolean>(DirectoryExists(FailedRoot)).ToBe(False);
  Expect<Boolean>(FileExists(FailedOwnerPath)).ToBe(False);
  Expect<Boolean>(DirectoryExists(LiveRoot)).ToBe(True);

  LiveSession.Finish(True);
  LiveSession.Free;
end;

procedure TLWPTBuildSessionTests.TestRepairRemovesInterruptedSessionCreation;
var
  Removed, Retained: Integer;
begin
  ResetScratch;
  WriteText(FScratch
    + '/' + BUILD_SESSIONS_DIR
    + '/.creating-session-abandoned/session.state',
    '999999999'#10'active'#10'1');

  RepairBuildSessions(FScratch, Removed, Retained);

  Expect<Integer>(Removed).ToBe(1);
  Expect<Integer>(Retained).ToBe(0);
  Expect<Boolean>(DirectoryExists(FScratch
    + '/' + BUILD_SESSIONS_DIR
    + '/.creating-session-abandoned')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.SetupTests;
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
  Test('manifest changes after parsing refuse fingerprint capture',
    TestParsedManifestChangeRefusesFingerprint);
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
  Test('directory aliases produce deterministic fingerprints',
    TestDirectoryAliasesHaveDeterministicFingerprint);
  Test('publication locks use destination filesystem identity',
    TestPublicationLockUsesFilesystemIdentity);
  {$ENDIF}
  Test('repair removes inactive sessions and retains live sessions',
    TestRepairRemovesInactiveAndKeepsLiveSessions);
  Test('repair removes interrupted session creation',
    TestRepairRemovesInterruptedSessionCreation);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTBuildSessionTests.Create(
    'build sessions and publication'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
