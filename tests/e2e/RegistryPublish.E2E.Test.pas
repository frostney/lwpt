program RegistryPublish.E2E.Test;

{ Black-box `registry publish` against a running `registry serve`
  (ADR-0049): a tar.gz and a zip published over localhost HTTP and over
  HTTPS trusted through the test build's anchor seam, idempotent retries
  including the same zip twice and its normalized tar.gz, a content
  conflict, authentication and scope failures, and local refusals (a
  dependency-bearing archive, a missing trust pin, plain HTTP to another
  host, a missing or malformed token) that make no connection and never
  read the token first. The secret appears in no output. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryHTTP,
  Tests.RegistryOrigin,
  Tests.RegistryPublish,
  Tests.RegistryServer,
  Tests.Scratch,
  Tests.TCPRelay;

type
  TRegistryPublishE2E = class(TTestSuite)
  private
    FScratch, FProject, FOutputs: string;
    FOrigin: TPublishOrigin;
    procedure ReleaseScratch;
    function NewOrigin(const AName: string; const AHTTPS: Boolean = False): TPublishOrigin;
    function Archive(const AName: string; const ABytes: TBytes): string;
    function Publish(const AArchive, AToken: string;
      const AExtra: array of string; const AVariable: string = ''): TLwptResult;
    procedure ExpectFailure(const ARun: TLwptResult; const APrefix: string);
    procedure ExpectSecretAbsent(const AToken: string);
    procedure ExpectProjectUntouched;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestPublishesATarGzToARunningOrigin;
    procedure TestZipRetriesAreIdempotent;
    procedure TestConflictingContentIsRefused;
    procedure TestAuthenticationAndScopeFailures;
    procedure TestLocalRefusalsMakeNoConnectionAndReadNoToken;
    procedure TestPublishesOverHTTPSWithTheTestRoot;
    procedure TestPublishesAcrossKeyRotations;
  end;

procedure TRegistryPublishE2E.BeforeEach;
begin
  FreeAndNil(FOrigin);
  ReleaseScratch;
  FScratch := CreateScratchRoot('registry-publish-e2e');
  { The directory publish runs in: it must stay exactly as created. }
  FProject := FScratch + '/project';
  ForceDirectories(FProject);
  FOutputs := '';
end;

procedure TRegistryPublishE2E.AfterEach;
begin
  FreeAndNil(FOrigin);
end;

procedure TRegistryPublishE2E.AfterAll;
begin
  FreeAndNil(FOrigin);
  ReleaseScratch;
end;

procedure TRegistryPublishE2E.ReleaseScratch;
var
  Started: QWord;
  Failure: string;
begin
  if FScratch = '' then Exit;
  Started := GetTickCount64;
  repeat
    try
      RecursiveDelete(FScratch);
      FScratch := '';
      Exit;
    except
      on E: Exception do Failure := E.Message;
    end;
    Sleep(50);
  until GetTickCount64 - Started >= 10000;
  WriteLn(StdErr, 'registry publish e2e cleanup: ', Failure);
  FScratch := '';
end;

function TRegistryPublishE2E.NewOrigin(const AName: string;
  const AHTTPS: Boolean): TPublishOrigin;
var
  Port: Word;
begin
  Port := FindAvailableRegistryTestPort;
  Result := TPublishOrigin.Create(FScratch, AName, Port, Port, AHTTPS);
end;

function TRegistryPublishE2E.Archive(const AName: string; const ABytes: TBytes): string;
begin
  Result := FScratch + '/' + AName;
  WriteBinaryFile(Result, ABytes);
end;

function TRegistryPublishE2E.Publish(const AArchive, AToken: string;
  const AExtra: array of string; const AVariable: string): TLwptResult;
begin
  Result := RunPublish(AArchive, FOrigin.Base, FOrigin.KeyID, FOrigin.PublicKey,
    AVariable, AToken, FProject, AExtra, []);
  FOutputs := FOutputs + Result.Stdout + Result.Stderr;
end;

procedure TRegistryPublishE2E.ExpectFailure(const ARun: TLwptResult;
  const APrefix: string);
begin
  if Pos(APrefix, ARun.Stderr) = 0 then
    WriteLn(StdErr, 'expected "', APrefix, '" in: ', ARun.Stderr);
  Expect<Integer>(ARun.ExitCode).ToBe(1);
  Expect<Boolean>(Pos(APrefix, ARun.Stderr) > 0).ToBe(True);
  Expect<string>(PublishLine(ARun)).ToBe('');
end;

procedure TRegistryPublishE2E.ExpectSecretAbsent(const AToken: string);
begin
  Expect<Boolean>(Pos(TokenSecret(AToken), FOutputs) = 0).ToBe(True);
  if Assigned(FOrigin) then
    Expect<Boolean>(Pos(TokenSecret(AToken), FOrigin.Outputs) = 0).ToBe(True);
end;

procedure TRegistryPublishE2E.ExpectProjectUntouched;
var
  Search: TSearchRec;
  Count: Integer;
begin
  { publish reads no lwpt.toml and writes nothing: no lock, no .lwpt/. }
  Count := 0;
  if FindFirst(FProject + '/*', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Name <> '.') and (Search.Name <> '..') then Inc(Count);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  Expect<Integer>(Count).ToBe(0);
end;

procedure TRegistryPublishE2E.TestPublishesATarGzToARunningOrigin;
var
  Token, Path, Line, Expected, RecordHash: string;
  Bytes: TBytes;
  Run: TLwptResult;
  PID: Integer;
begin
  FOrigin := NewOrigin('origin');
  Token := FOrigin.IssueToken(['--packages', 'e2e-*']);
  FOrigin.Start;
  PID := FOrigin.Serve.ProcessID;
  Bytes := PublishTarGz('e2e-lib', '1.0.0', 'first release');
  Path := Archive('e2e-lib.tar.gz', Bytes);
  Run := Publish(Path, Token, []);
  if Run.ExitCode <> 0 then WriteLn(StdErr, Run.Stderr);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Line := PublishLine(Run);
  RecordHash := PublishedRecordHash(Line);
  Expected := 'published e2e-lib@1.0.0 to ' + FOrigin.Base + ' at sequence 2 (archive '
    + RegistryArtifactHash(Bytes) + ', record ' + RecordHash + ')';
  Expect<string>(Line).ToBe(Expected);
  Expect<string>(Trim(Run.Stdout)).ToBe(Line);
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  { The printed record is the one the origin serves. }
  Expect<Integer>(FOrigin.Request('GET', '/v1/records/sha256/'
    + Copy(RecordHash, 8, 64) + '.toml', [], nil).Status).ToBe(200);
  Expect<Integer>(FOrigin.Request('GET', '/v1/objects/sha256/'
    + Copy(RegistryArtifactHash(Bytes), 8, 64), [], nil).Status).ToBe(200);
  { An identical retry, through a named variable, changes nothing. }
  Run := Publish(Path, Token, [], 'CI_PUBLISH_TOKEN');
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(PublishLine(Run)).ToBe('already ' + Expected);
  { --silent keeps the outcome line. }
  Run := Publish(Path, Token, ['--silent']);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('already ' + Expected + LineEnding, Run.Stdout) = 1).ToBe(True);
  Expect<string>(Trim(Run.Stderr)).ToBe('');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  Expect<Boolean>(FOrigin.Serve.Running).ToBe(True);
  Expect<Integer>(FOrigin.Serve.ProcessID).ToBe(PID);
  ExpectProjectUntouched;
  FOrigin.Stop;
  ExpectSecretAbsent(Token);
end;

procedure TRegistryPublishE2E.TestZipRetriesAreIdempotent;
var
  Token, Line, ArchiveHash, RecordHash, Normalized: string;
  Run: TLwptResult;
  Served: TRawHTTPResponse;
begin
  FOrigin := NewOrigin('origin');
  Token := FOrigin.IssueToken(['--packages', 'zip-lib']);
  FOrigin.Start;
  Run := Publish(Archive('zip-lib.zip', PublishZip('zip-lib', '1.0.0', 'zipped')),
    Token, []);
  if Run.ExitCode <> 0 then WriteLn(StdErr, Run.Stderr);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Line := PublishLine(Run);
  Expect<Boolean>(Pos('published zip-lib@1.0.0 to ' + FOrigin.Base
    + ' at sequence 2 (archive sha256:', Line) = 1).ToBe(True);
  ArchiveHash := PublishedArchiveHash(Line);
  RecordHash := PublishedRecordHash(Line);
  { The same zip again. }
  Run := Publish(FScratch + '/zip-lib.zip', Token, []);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(PublishLine(Run)).ToBe('already ' + Line);
  { A zip with other order, methods, timestamps, and a comment. }
  Run := Publish(Archive('zip-lib-variant.zip',
    PublishZip('zip-lib', '1.0.0', 'zipped', 1)), Token, []);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(PublishLine(Run)).ToBe('already ' + Line);
  { The normalized tar.gz the origin stored, published as a tar.gz. }
  Served := FOrigin.Request('GET', '/v1/objects/sha256/' + Copy(ArchiveHash, 8, 64),
    [], nil);
  Expect<Integer>(Served.Status).ToBe(200);
  Expect<string>(RegistryArtifactHash(Served.Body)).ToBe(ArchiveHash);
  Normalized := Archive('zip-lib-normalized.tar.gz', Served.Body);
  Run := Publish(Normalized, Token, []);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<string>(PublishedArchiveHash(PublishLine(Run))).ToBe(ArchiveHash);
  Expect<string>(PublishedRecordHash(PublishLine(Run))).ToBe(RecordHash);
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  ExpectProjectUntouched;
  ExpectSecretAbsent(Token);
end;

procedure TRegistryPublishE2E.TestConflictingContentIsRefused;
var
  Token: string;
  Run: TLwptResult;
begin
  FOrigin := NewOrigin('origin');
  Token := FOrigin.IssueToken(['--packages', '*']);
  FOrigin.Start;
  Run := Publish(Archive('first.tar.gz', PublishTarGz('conflict-lib', '1.0.0', 'a')),
    Token, []);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Run := Publish(Archive('second.tar.gz', PublishTarGz('conflict-lib', '1.0.0', 'b')),
    Token, []);
  ExpectFailure(Run, RegistryProgramName + ' registry: identity_conflict: origin refused '
    + 'the record publication with HTTP 409 (request ');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
  ExpectSecretAbsent(Token);
end;

procedure TRegistryPublishE2E.TestAuthenticationAndScopeFailures;
const
  REFUSED = 'registry: authentication_required: origin refused the archive upload with HTTP 401';
var
  Scoped, Revoked, Expired, Unknown, Path: string;
  Tokens: array[0..2] of string;
  Index: Integer;
begin
  FOrigin := NewOrigin('origin');
  Scoped := FOrigin.IssueToken(['--packages', 'other-*']);
  Revoked := FOrigin.IssueToken(['--packages', '*']);
  FOrigin.RevokeToken(Revoked);
  Expired := FOrigin.IssueToken(['--packages', '*']);
  FOrigin.ExpireToken(Expired);
  Unknown := RegistryProgramName + '_rt1_' + StringOfChar('0', 32) + '_'
    + StringOfChar('A', 43);
  FOrigin.Start;
  Path := Archive('auth-lib.tar.gz', PublishTarGz('auth-lib', '1.0.0', 'auth'));
  Tokens[0] := Unknown;
  Tokens[1] := Revoked;
  Tokens[2] := Expired;
  for Index := 0 to High(Tokens) do
    ExpectFailure(Publish(Path, Tokens[Index], []), REFUSED);
  { The upload is unscoped; the record is refused for its package. }
  ExpectFailure(Publish(Path, Scoped, []), 'registry: permission_denied: origin '
    + 'refused the record publication with HTTP 403');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(1);
  for Index := 0 to High(Tokens) do ExpectSecretAbsent(Tokens[Index]);
  ExpectSecretAbsent(Scoped);
end;

procedure TRegistryPublishE2E.TestLocalRefusalsMakeNoConnectionAndReadNoToken;
const
  MALFORMED = 'not-a-token-value';
var
  Listener: TRegistryTestServer;
  Origin, Plain, DependentTar, DependentZip: string;
  Run: TLwptResult;

  function Attempt(const AArchive, AOrigin, AKeyID, APublicKey,
    AToken: string): TLwptResult;
  begin
    Result := RunPublish(AArchive, AOrigin, AKeyID, APublicKey, 'PUBLISH_E2E_TOKEN',
      AToken, FProject, [], []);
    FOutputs := FOutputs + Result.Stdout + Result.Stderr;
    Expect<Boolean>(Pos(MALFORMED, Result.Stderr + Result.Stdout) = 0).ToBe(True);
  end;
begin
  FOrigin := NewOrigin('origin');
  { Nothing answers here; any connection would be counted. }
  Listener := TRegistryTestServer.Create(nil);
  try
    Listener.Start;
    Origin := 'http://localhost:' + IntToStr(Listener.Port);
    Plain := Archive('plain.tar.gz', PublishTarGz('plain-lib', '1.0.0', 'plain'));
    DependentTar := Archive('dependent.tar.gz', PublishTarGz('dependent-lib', '1.0.0',
      'dependent', '[dependencies]' + #10 + 'plain-lib = "local:../plain"' + #10));
    DependentZip := Archive('dependent.zip', PublishZip('dependent-lib', '1.0.0',
      'dependent', 0, '[dependencies]' + #10 + 'plain-lib = "local:../plain"' + #10));
    { Decision 4: refused before the token is read, set or not. }
    ExpectFailure(Attempt(DependentTar, Origin, FOrigin.KeyID, FOrigin.PublicKey, ''),
      'registry: unsupported_dependencies: ');
    ExpectFailure(Attempt(DependentTar, Origin, FOrigin.KeyID, FOrigin.PublicKey,
      MALFORMED), 'registry: unsupported_dependencies: ');
    ExpectFailure(Attempt(DependentZip, Origin, FOrigin.KeyID, FOrigin.PublicKey, ''),
      'registry: unsupported_dependencies: ');
    ExpectFailure(Attempt(DependentZip, Origin, FOrigin.KeyID, FOrigin.PublicKey,
      MALFORMED), 'registry: unsupported_dependencies: ');
    { The trust pin is required. }
    ExpectFailure(Attempt(Plain, Origin, '', FOrigin.PublicKey, MALFORMED),
      'registry: invalid_configuration: publish requires the trust pin');
    ExpectFailure(Attempt(Plain, Origin, FOrigin.KeyID, '', MALFORMED),
      'registry: invalid_configuration: publish requires the trust pin');
    { Plain HTTP only for the exact host localhost. }
    ExpectFailure(Attempt(Plain, 'http://example.invalid', FOrigin.KeyID,
      FOrigin.PublicKey, MALFORMED), 'registry: insecure_transport: ');
    ExpectFailure(Attempt(Plain, 'http://127.0.0.1:' + IntToStr(Listener.Port),
      FOrigin.KeyID, FOrigin.PublicKey, MALFORMED), 'registry: insecure_transport: ');
    { The credential itself, still before any connection. }
    ExpectFailure(Attempt(Plain, Origin, FOrigin.KeyID, FOrigin.PublicKey, ''),
      'registry: credential_missing: environment variable PUBLISH_E2E_TOKEN');
    Run := Attempt(Plain, Origin, FOrigin.KeyID, FOrigin.PublicKey, MALFORMED);
    ExpectFailure(Run, 'registry: credential_invalid: environment variable PUBLISH_E2E_TOKEN');
    Sleep(200);
    Expect<Integer>(Listener.AcceptedCount).ToBe(0);
  finally
    Listener.Free;
  end;
  { An origin without an active token stays read-only and says so before
    anything is uploaded. }
  FOrigin.Start;
  Run := RunPublish(Plain, FOrigin.Base, FOrigin.KeyID, FOrigin.PublicKey, '',
    RegistryProgramName + '_rt1_' + StringOfChar('0', 32) + '_' + StringOfChar('A', 43),
    FProject, [], []);
  ExpectFailure(Run, 'registry: publication_not_supported: ');
  Expect<Integer>(FOrigin.LatestSequence).ToBe(1);
  ExpectProjectUntouched;
end;

procedure TRegistryPublishE2E.TestPublishesOverHTTPSWithTheTestRoot;
var
  Token, Seam, Path: string;
  Bytes: TBytes;
  Run: TLwptResult;
  Relay: TTCPRelay;
  Backend: Word;
  Before: Integer;
begin
  { The origin advertises a relay's port, so the test counts every
    connection the client makes. }
  Relay := TTCPRelay.Create(0);
  try
    Backend := FindAvailableRegistryTestPort;
    Relay.Backend := Backend;
    FOrigin := TPublishOrigin.Create(FScratch, 'tls-origin', Relay.Port, Backend, True);
    Token := FOrigin.IssueToken(['--packages', 'tls-*']);
    FOrigin.Start;
    Seam := UpperCase(RegistryProgramName) + '_TEST_REGISTRY_TRUST_ANCHORS='
      + TestRootCertificatePath;
    Bytes := PublishTarGz('tls-lib', '1.0.0', 'over tls');
    Path := Archive('tls-lib.tar.gz', Bytes);
    { Decision 7: only the test build trusts the committed test root. }
    Run := RunPublish(Path, FOrigin.Base, FOrigin.KeyID, FOrigin.PublicKey, '', Token,
      FProject, [], [Seam], True);
    FOutputs := FOutputs + Run.Stdout + Run.Stderr;
    if Run.ExitCode <> 0 then WriteLn(StdErr, Run.Stderr);
    Expect<Integer>(Run.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('published tls-lib@1.0.0 to ' + FOrigin.Base
      + ' at sequence 2 (archive ' + RegistryArtifactHash(Bytes),
      PublishLine(Run)) = 1).ToBe(True);
    Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
    { A release-flavoured binary ignores the seam and verifies against the
      system store, which does not hold the test root. A refused
      certificate is not retried: exactly one connection. }
    Before := Relay.Accepted;
    Path := Archive('tls-lib-2.tar.gz', PublishTarGz('tls-lib', '1.0.1', 'refused'));
    Run := RunPublish(Path, FOrigin.Base, FOrigin.KeyID, FOrigin.PublicKey, '', Token,
      FProject, [], [Seam], False);
    FOutputs := FOutputs + Run.Stdout + Run.Stderr;
    ExpectFailure(Run, 'registry: registry_tls_verification_failed: ');
    Sleep(200);
    Expect<Integer>(Relay.Accepted - Before).ToBe(1);
    Expect<Integer>(FOrigin.LatestSequence).ToBe(2);
    ExpectProjectUntouched;
    ExpectSecretAbsent(Token);
  finally
    FreeAndNil(FOrigin);
    Relay.Free;
  end;
end;

procedure TRegistryPublishE2E.TestPublishesAcrossKeyRotations;
var
  Token, Line: string;
  Run: TLwptResult;

  procedure Rotate(const AFromKey: string);
  var
    Rotation: TLwptResult;
  begin
    Rotation := RunLwpt(['registry', 'rotate-key', '--data-dir', FOrigin.DataDirectory,
      '--from-key', AFromKey], FScratch);
    FOutputs := FOutputs + Rotation.Stdout + Rotation.Stderr;
    if Rotation.ExitCode <> 0 then WriteLn(StdErr, Rotation.Stderr);
    Expect<Integer>(Rotation.ExitCode).ToBe(0);
  end;

  function SigningKey: string;
  var
    Text: string;
  begin
    Text := RawHTTPBodyText(FOrigin.Request('GET', '/v1/checkpoints/latest.toml', [], nil));
    Result := Copy(Text, Pos('key_id = "', Text) + Length('key_id = "'), 72);
  end;
begin
  { The client holds only the root pin: every publish walks the dual-signed
    rotation chain, before and after its commit. }
  FOrigin := NewOrigin('origin');
  Token := FOrigin.IssueToken(['--packages', 'rotated-*']);
  Rotate(FOrigin.KeyID);
  FOrigin.Start;
  Expect<Boolean>(SigningKey <> FOrigin.KeyID).ToBe(True);
  Run := Publish(Archive('rotated-a.tar.gz', PublishTarGz('rotated-a', '1.0.0', 'a')),
    Token, []);
  if Run.ExitCode <> 0 then WriteLn(StdErr, Run.Stderr);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Line := PublishLine(Run);
  Expect<Boolean>(Pos('published rotated-a@1.0.0 to ' + FOrigin.Base, Line) = 1)
    .ToBe(True);
  { A second rotation while the origin serves. }
  Rotate(SigningKey);
  Run := Publish(Archive('rotated-b.tar.gz', PublishTarGz('rotated-b', '1.0.0', 'b')),
    Token, []);
  if Run.ExitCode <> 0 then WriteLn(StdErr, Run.Stderr);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('published rotated-b@1.0.0 to ' + FOrigin.Base,
    PublishLine(Run)) = 1).ToBe(True);
  ExpectSecretAbsent(Token);
end;

procedure TRegistryPublishE2E.SetupTests;
begin
  Test('a tar.gz publishes to a running origin and an identical retry is a no-op',
    TestPublishesATarGzToARunningOrigin);
  Test('the same zip twice and its normalized tar.gz publish idempotently',
    TestZipRetriesAreIdempotent);
  Test('different content for a published version is refused',
    TestConflictingContentIsRefused);
  Test('unknown, revoked, expired, and out-of-scope tokens are refused',
    TestAuthenticationAndScopeFailures);
  Test('local refusals make no connection and never read the token first; a read-only origin is refused',
    TestLocalRefusalsMakeNoConnectionAndReadNoToken);
  Test('HTTPS publication trusts the test root only in the test build; a refused certificate is not retried',
    TestPublishesOverHTTPSWithTheTestRoot);
  Test('a root-pinned publish walks the rotation chain before and after its commit',
    TestPublishesAcrossKeyRotations);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryPublishE2E.Create('registry publish e2e'));
  TestRunnerProgram.Run;
end.
