program LWPT.Registry.Publish.Test;

{ The publish client's local contract (ADR-0049): the diagnostic grammar
  and credential redaction, retry arithmetic, origin transport rules, the
  record it publishes with its dependencies in protocol order, Location
  parsing, and the order of local refusals: trust pin, transport, and
  archive validation (including dependencies a record cannot carry) all
  fail before the token is read or any connection is made. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  DateUtils,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Publish,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.RegistryServer,
  Tests.Scratch,
  Tests.TarSynth,
  Tests.ZipSynth;

const
  { A syntactically valid token that no origin issued. }
  SAMPLE_TOKEN = PROGRAM_NAME + '_rt1_0123456789abcdef0123456789abcdef_'
    + 'Secr3tPartOfTheTokenAbCdEfGhIjKlMnOpQrStU-_';
  SAMPLE_SECRET = 'Secr3tPartOfTheTokenAbCdEfGhIjKlMnOpQrStU-_';
  PIN_KEY_ID = 'ed25519:035fbd9c9aade687fd77c8da783d6ed29e20d10f52ca0a0e143d6602aa9135ae';
  PIN_PUBLIC_KEY = 'hex:154c2482652c8aa9b04b9e9d9bd4294593b6f5a0c850e583b440d5597cca1fa9';
  HASH_A = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  REGISTRY = '[registries.home]' + #10 + 'identity = "https://packages.example.com"'
    + #10;

type
  TRegistryClientContract = class(TTestSuite)
  private
    FScratch: string;
    function Failure(const AOptions: TLWPTRegistryPublishOptions): string;
    function Options(const AArchive, AOrigin: string): TLWPTRegistryPublishOptions;
    function WriteArchive(const AName: string; const ABytes: TBytes): string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestRedactionRemovesTokenAndSecret;
    procedure TestErrorCodesAreAllowListed;
    procedure TestRequestIDGrammar;
    procedure TestRetryAfterAndBackoff;
    procedure TestOriginTransportRules;
    procedure TestRecordDocumentIsCanonical;
    procedure TestRecordDependenciesAreInProtocolOrder;
    procedure TestLocationNamesOneRecordBelowTheAPI;
    procedure TestTokenEnvironmentNames;
    procedure TestLocalRefusalsPrecedeCredentialsAndConnections;
  end;

function PackageTarGz(const AName, AVersion, AExtra: string): TBytes;
var
  Root: string;
begin
  Root := AName + '-' + AVersion + '/';
  Result := Gzip(BuildTar([MakeDirectoryEntry(Root),
    MakeRegularFileEntry(Root + 'lwpt.toml', TextBytes('[package]' + #10
      + 'name = "' + AName + '"' + #10 + 'version = "' + AVersion + '"' + #10
      + AExtra)),
    MakeRegularFileEntry(Root + 'source.pas', TextBytes('unit source;' + #10))]));
end;

function PackageZip(const AName, AVersion, AExtra: string): TBytes;
var
  Zip: TZipSynth;
begin
  Zip := TZipSynth.Create;
  try
    Zip.AddText('lwpt.toml', '[package]' + #10 + 'name = "' + AName + '"' + #10
      + 'version = "' + AVersion + '"' + #10 + AExtra);
    Zip.AddText('source.pas', 'unit source;' + #10);
    Result := Zip.Build;
  finally
    Zip.Free;
  end;
end;

procedure TRegistryClientContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('registry-client');
end;

procedure TRegistryClientContract.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

function TRegistryClientContract.WriteArchive(const AName: string;
  const ABytes: TBytes): string;
begin
  Result := FScratch + '/' + AName;
  WriteBytesToFile(Result, ABytes);
end;

function TRegistryClientContract.Options(const AArchive,
  AOrigin: string): TLWPTRegistryPublishOptions;
begin
  Result.ArchivePath := AArchive;
  Result.Origin := AOrigin;
  Result.KeyID := PIN_KEY_ID;
  Result.PublicKey := PIN_PUBLIC_KEY;
  { A variable this process never sets: reading it would fail with
    credential_missing, so any other failure proves it was not read. }
  Result.TokenEnvironment := UpperCase(PROGRAM_NAME) + '_CLIENT_TEST_UNSET_TOKEN';
end;

function TRegistryClientContract.Failure(
  const AOptions: TLWPTRegistryPublishOptions): string;
begin
  Result := '';
  try
    PublishToRegistry(AOptions);
  except
    on E: ELWPTRegistryPublishError do Result := E.Message;
  end;
end;

procedure TRegistryClientContract.TestRedactionRemovesTokenAndSecret;
begin
  Expect<string>(RedactRegistryCredential('Bearer ' + SAMPLE_TOKEN + ' and '
    + SAMPLE_TOKEN, SAMPLE_TOKEN)).ToBe('Bearer [redacted] and [redacted]');
  Expect<string>(RedactRegistryCredential('x' + SAMPLE_SECRET + 'y', SAMPLE_TOKEN))
    .ToBe('x[redacted]y');
  Expect<string>(RedactRegistryCredential('nothing here', SAMPLE_TOKEN))
    .ToBe('nothing here');
  { A malformed value is still removed whole. }
  Expect<string>(RedactRegistryCredential('a secret b', 'secret')).ToBe('a [redacted] b');
  Expect<string>(RedactRegistryCredential('kept', '')).ToBe('kept');
end;

procedure TRegistryClientContract.TestErrorCodesAreAllowListed;
begin
  Expect<string>(RegistryPublicationErrorCode('identity_conflict')).ToBe('identity_conflict');
  Expect<string>(RegistryPublicationErrorCode('authentication_required'))
    .ToBe('authentication_required');
  Expect<string>(RegistryPublicationErrorCode('storage_budget_exceeded'))
    .ToBe('storage_budget_exceeded');
  Expect<string>(RegistryPublicationErrorCode('temporary_failure')).ToBe('temporary_failure');
  { Grammar-valid but not a listed code. }
  Expect<string>(RegistryPublicationErrorCode('made_up_code')).ToBe('unrecognized_error');
  Expect<string>(RegistryPublicationErrorCode('Identity_conflict')).ToBe('unrecognized_error');
  Expect<string>(RegistryPublicationErrorCode('')).ToBe('unrecognized_error');
  Expect<string>(RegistryPublicationErrorCode(SAMPLE_TOKEN)).ToBe('unrecognized_error');
  Expect<string>(RegistryPublicationErrorCode(StringOfChar('a', 65))).ToBe('unrecognized_error');
end;

procedure TRegistryClientContract.TestRequestIDGrammar;
begin
  Expect<Boolean>(RegistryRequestIDIsValid('01j00000000000000000000000')).ToBe(True);
  Expect<Boolean>(RegistryRequestIDIsValid(StringOfChar('z', 64))).ToBe(True);
  Expect<Boolean>(RegistryRequestIDIsValid(StringOfChar('z', 65))).ToBe(False);
  Expect<Boolean>(RegistryRequestIDIsValid('')).ToBe(False);
  Expect<Boolean>(RegistryRequestIDIsValid('ABC')).ToBe(False);
  Expect<Boolean>(RegistryRequestIDIsValid('a_b')).ToBe(False);
  Expect<Boolean>(RegistryRequestIDIsValid(SAMPLE_TOKEN)).ToBe(False);
end;

procedure TRegistryClientContract.TestRetryAfterAndBackoff;
var
  Now: TDateTime;
begin
  Expect<Integer>(ParseRegistryRetryAfter('0')).ToBe(0);
  Expect<Integer>(ParseRegistryRetryAfter(' 7 ')).ToBe(7);
  Expect<Integer>(ParseRegistryRetryAfter('3600')).ToBe(60);
  Expect<Integer>(ParseRegistryRetryAfter('')).ToBe(-1);
  Expect<Integer>(ParseRegistryRetryAfter('+5')).ToBe(-1);
  Expect<Integer>(ParseRegistryRetryAfter(SAMPLE_TOKEN)).ToBe(-1);
  Expect<Integer>(ParseRegistryRetryAfter('12a')).ToBe(-1);
  Expect<Integer>(ParseRegistryRetryAfter('1.5')).ToBe(-1);
  { delay-seconds has no digit limit; it saturates at the cap. }
  Expect<Integer>(ParseRegistryRetryAfter('99999999999999999999999999')).ToBe(60);
  Expect<Integer>(ParseRegistryRetryAfter('0000000000000000000000000030')).ToBe(30);
  { HTTP-date in all three forms, relative to the clock, never negative. }
  Now := EncodeDateTime(2026, 10, 21, 7, 28, 0, 0);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:28:30 GMT', Now))
    .ToBe(30);
  Expect<Integer>(ParseRegistryRetryAfter('Wednesday, 21-Oct-26 07:28:45 GMT', Now))
    .ToBe(45);
  Expect<Integer>(ParseRegistryRetryAfter('Wed Oct 21 07:28:10 2026', Now)).ToBe(10);
  Expect<Integer>(ParseRegistryRetryAfter('Sun Nov  6 08:49:37 1994', Now)).ToBe(0);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:27:00 GMT', Now))
    .ToBe(0);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 09:00:00 GMT', Now))
    .ToBe(60);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:28:30 UTC', Now))
    .ToBe(-1);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 32 Oct 2026 07:28:30 GMT', Now))
    .ToBe(-1);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Foo 2026 07:28:30 GMT', Now))
    .ToBe(-1);
  { A fractional clock rounds the remaining time up, never down. }
  Now := EncodeDateTime(2026, 10, 21, 7, 28, 0, 400);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:28:30 GMT', Now))
    .ToBe(30);
  Now := EncodeDateTime(2026, 10, 21, 7, 28, 0, 999);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:28:01 GMT', Now))
    .ToBe(1);
  Now := EncodeDateTime(2026, 10, 21, 7, 28, 1, 1);
  Expect<Integer>(ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:28:01 GMT', Now))
    .ToBe(0);
  Now := EncodeDateTime(2026, 10, 21, 7, 28, 0, 0);
  { A date 30 seconds ahead is honoured as the minimum wait. }
  Expect<Integer>(RegistryPublishBackoffSeconds(1,
    ParseRegistryRetryAfter('Wed, 21 Oct 2026 07:28:30 GMT', Now))).ToBe(30);
  { Exponential from one second, never shorter than Retry-After, and at
    most 60 seconds. }
  Expect<Integer>(RegistryPublishBackoffSeconds(1, -1)).ToBe(1);
  Expect<Integer>(RegistryPublishBackoffSeconds(2, -1)).ToBe(2);
  Expect<Integer>(RegistryPublishBackoffSeconds(4, -1)).ToBe(8);
  Expect<Integer>(RegistryPublishBackoffSeconds(7, -1)).ToBe(60);
  Expect<Integer>(RegistryPublishBackoffSeconds(40, -1)).ToBe(60);
  Expect<Integer>(RegistryPublishBackoffSeconds(4, 0)).ToBe(8);
  Expect<Integer>(RegistryPublishBackoffSeconds(4, 3)).ToBe(8);
  Expect<Integer>(RegistryPublishBackoffSeconds(1, 0)).ToBe(1);
  Expect<Integer>(RegistryPublishBackoffSeconds(1, 30)).ToBe(30);
  Expect<Integer>(RegistryPublishBackoffSeconds(2, 60)).ToBe(60);
  Expect<Integer>(RegistryPublishBackoffSeconds(40, 60)).ToBe(60);
  Expect<Integer>(RegistryPublishMaximumAttempts).ToBe(5);
end;

function OriginFailure(const AOrigin: string): string;
begin
  Result := '';
  try
    CanonicalRegistryPublishOrigin(AOrigin);
  except
    on E: ELWPTRegistryPublishError do Result := RegistryErrorCode(E.Message);
  end;
end;

procedure TRegistryClientContract.TestOriginTransportRules;
begin
  Expect<string>(CanonicalRegistryPublishOrigin('https://Packages.Example.COM:443/lwpt/'))
    .ToBe('https://packages.example.com/lwpt');
  Expect<string>(CanonicalRegistryPublishOrigin('http://localhost:8080'))
    .ToBe('http://localhost:8080');
  Expect<string>(CanonicalRegistryPublishOrigin('https://10.0.0.5:8443'))
    .ToBe('https://10.0.0.5:8443');
  Expect<string>(OriginFailure('http://example.com')).ToBe('insecure_transport');
  Expect<string>(OriginFailure('http://127.0.0.1:8080')).ToBe('insecure_transport');
  Expect<string>(OriginFailure('http://localhost.example.com')).ToBe('insecure_transport');
  Expect<string>(OriginFailure('')).ToBe('invalid_configuration');
  Expect<string>(OriginFailure('ftp://example.com')).ToBe('invalid_configuration');
  Expect<string>(OriginFailure('https://user@example.com')).ToBe('invalid_configuration');
  Expect<string>(OriginFailure('https://example.com/?q=1')).ToBe('invalid_configuration');
end;

procedure TRegistryClientContract.TestRecordDocumentIsCanonical;
var
  Document: string;
  Package: TLWPTRegistryPackage;
begin
  Document := RegistryPublishRecordDocument('https://packages.example.com',
    'example-lib', '1.2.3', HASH_A, 261, '2026-09-29T12:00:00Z', nil);
  Package := ParseRegistryPackage(Document,
    SHA256BytesPrefixed(BytesOf(Document)), 'https://packages.example.com');
  Expect<string>(Package.Name).ToBe('example-lib');
  Expect<string>(Package.Version).ToBe('1.2.3');
  Expect<string>(Package.ArchiveHash).ToBe(HASH_A);
  Expect<Int64>(Package.ArchiveSize).ToBe(261);
  Expect<string>(Package.PublishedAt).ToBe('2026-09-29T12:00:00Z');
  Expect<Boolean>(Package.Yanked).ToBe(False);
  Expect<Integer>(Length(Package.Dependencies)).ToBe(0);
  { LF line endings on every platform: the hash is over exact bytes. }
  Expect<Boolean>(Pos(#13, Document) = 0).ToBe(True);
  Expect<Boolean>(Pos('dependencies = []' + #10, Document) > 0).ToBe(True);
end;

procedure TRegistryClientContract.TestRecordDependenciesAreInProtocolOrder;
const
  HOME = 'https://packages.example.com';
var
  Dependencies: TLWPTRegistryDependencyArray;
  Document: string;
  Package: TLWPTRegistryPackage;

  procedure Add(const AOrigin, AName, AVersion: string);
  begin
    SetLength(Dependencies, Length(Dependencies) + 1);
    Dependencies[High(Dependencies)].Origin := AOrigin;
    Dependencies[High(Dependencies)].Name := AName;
    Dependencies[High(Dependencies)].Version := AVersion;
  end;

begin
  Dependencies := nil;
  { Declaration order; sorting uses each effective origin. }
  Add('https://z.example.com', 'alpha', '^1.0.0');
  Add(HOME, 'zeta', '1.0.0');
  Add('http://localhost:8080', 'omega', '>=2.0.0 <3.0.0');
  Add(HOME, 'beta', '~0.1.0 || ^1.0.0');
  Document := RegistryPublishRecordDocument(HOME, 'example-lib', '1.2.3',
    HASH_A, 261, '2026-09-29T12:00:00Z', Dependencies);
  { The publishing origin is omitted; the rest name theirs. }
  Expect<string>(Copy(Document, Pos('dependencies = ', Document), MaxInt))
    .ToBe('dependencies = [{ origin = "http://localhost:8080", name = "omega", '
      + 'version = ">=2.0.0 <3.0.0" }, { name = "beta", version = "~0.1.0 || '
      + '^1.0.0" }, { name = "zeta", version = "1.0.0" }, { origin = '
      + '"https://z.example.com", name = "alpha", version = "^1.0.0" }]' + #10);
  { The verifier's canonical decoder accepts it unchanged. }
  Package := ParseRegistryPackage(Document,
    SHA256BytesPrefixed(BytesOf(Document)), HOME);
  Expect<Integer>(Length(Package.Dependencies)).ToBe(4);
  Expect<string>(Package.Dependencies[1].Origin).ToBe(HOME);
  Expect<string>(Package.Dependencies[1].Name).ToBe('beta');
  Expect<string>(SortRegistryDependencies(Dependencies)[3].Name).ToBe('alpha');
  Expect<Integer>(Length(Dependencies)).ToBe(4);
  Expect<string>(Dependencies[0].Name).ToBe('alpha');
end;

procedure TRegistryClientContract.TestLocationNamesOneRecordBelowTheAPI;
const
  API = 'https://packages.example.com/lwpt/v1';
  HEX = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
begin
  Expect<string>(RegistryRecordHashFromLocation(API + '/records/sha256/' + HEX
    + '.toml', API)).ToBe('sha256:' + HEX);
  Expect<string>(RegistryRecordHashFromLocation('https://other.example.com/lwpt/v1'
    + '/records/sha256/' + HEX + '.toml', API)).ToBe('');
  Expect<string>(RegistryRecordHashFromLocation(API + '/records/sha256/'
    + UpperCase(HEX) + '.toml', API)).ToBe('');
  Expect<string>(RegistryRecordHashFromLocation(API + '/records/sha256/' + HEX
    + '.toml?x=1', API)).ToBe('');
  Expect<string>(RegistryRecordHashFromLocation(API + '/objects/sha256/' + HEX, API))
    .ToBe('');
  Expect<string>(RegistryRecordHashFromLocation(API + '/records/sha256/'
    + SAMPLE_TOKEN + '.toml', API)).ToBe('');
  Expect<string>(RegistryRecordHashFromLocation('', API)).ToBe('');
end;

procedure TRegistryClientContract.TestTokenEnvironmentNames;
begin
  Expect<string>(REGISTRY_DEFAULT_TOKEN_ENVIRONMENT)
    .ToBe(PROJECT_NAME + '_REGISTRY_TOKEN');
  Expect<Boolean>(RegistryTokenEnvironmentNameIsValid('CI_REGISTRY_TOKEN')).ToBe(True);
  Expect<Boolean>(RegistryTokenEnvironmentNameIsValid('_x9')).ToBe(True);
  Expect<Boolean>(RegistryTokenEnvironmentNameIsValid('')).ToBe(False);
  Expect<Boolean>(RegistryTokenEnvironmentNameIsValid('9LIVES')).ToBe(False);
  Expect<Boolean>(RegistryTokenEnvironmentNameIsValid('A=B')).ToBe(False);
  { A token pasted where a name belongs is refused, not read. }
  Expect<Boolean>(RegistryTokenEnvironmentNameIsValid(SAMPLE_TOKEN)).ToBe(False);
end;

procedure TRegistryClientContract.TestLocalRefusalsPrecedeCredentialsAndConnections;
var
  Listener: TRegistryTestServer;
  Origin, Plain, Dependent, DependentZip, Unsupported: string;
  Request: TLWPTRegistryPublishOptions;
begin
  Listener := TRegistryTestServer.Create(nil);
  try
    Listener.Start;
    Origin := 'http://localhost:' + IntToStr(Listener.Port);
    Plain := WriteArchive('plain.tar.gz', PackageTarGz('plain', '1.0.0', ''));
    Dependent := WriteArchive('dependent.tar.gz', PackageTarGz('dependent', '1.0.0',
      '[dependencies]' + #10 + 'plain = "local:../plain"' + #10));
    DependentZip := WriteArchive('dependent.zip', PackageZip('dependent', '1.0.0',
      '[dependencies]' + #10 + 'plain = "local:../plain"' + #10));
    Unsupported := WriteArchive('unsupported.bin', TextBytes('not an archive'));

    Expect<string>(Copy(Failure(Options(Dependent, Origin)), 1, 80))
      .ToBe('unsupported_dependencies: lwpt.toml dependency "plain" is not a '
        + 'registry: source');
    Expect<string>(RegistryErrorCode(Failure(Options(DependentZip, Origin))))
      .ToBe('unsupported_dependencies');
    Expect<string>(RegistryErrorCode(Failure(Options(WriteArchive('filtered.tar.gz',
      PackageTarGz('dependent', '1.0.0', REGISTRY + '[dependencies]' + #10
      + 'plain = { source = "registry:plain", version = "^1.0.0", '
      + 'include = ["source/**"] }' + #10)), Origin)))).ToBe('unsupported_dependencies');
    Expect<string>(RegistryErrorCode(Failure(Options(WriteArchive('dotted.zip',
      PackageZip('dotted.lib', '1.0.0', '')), Origin)))).ToBe('invalid_package_name');
    Expect<string>(RegistryErrorCode(Failure(Options(Unsupported, Origin))))
      .ToBe('unsupported_archive');
    Expect<string>(RegistryErrorCode(Failure(Options(FScratch + '/missing.tar.gz',
      Origin)))).ToBe('archive_unreadable');
    { The transport is checked before the archive is read. }
    Expect<string>(RegistryErrorCode(Failure(Options(FScratch + '/missing.tar.gz',
      'http://example.com')))).ToBe('insecure_transport');
    Request := Options(Plain, Origin);
    Request.KeyID := '';
    Expect<string>(Failure(Request)).ToBe('invalid_configuration: publish '
      + 'requires the trust pin --key-id and --public-key');
    Request := Options(Plain, Origin);
    Request.PublicKey := '';
    Expect<string>(RegistryErrorCode(Failure(Request))).ToBe('invalid_configuration');
    Request := Options(Plain, Origin);
    Request.PublicKey := 'hex:' + StringOfChar('0', 64);
    Expect<string>(RegistryErrorCode(Failure(Request))).ToBe('invalid_configuration');
    Request := Options(Plain, '');
    Expect<string>(RegistryErrorCode(Failure(Request))).ToBe('invalid_configuration');
    Request := Options(Plain, Origin);
    Request.TokenEnvironment := SAMPLE_TOKEN;
    Expect<string>(RegistryErrorCode(Failure(Request))).ToBe('invalid_configuration');
    { Only a valid archive reaches the credential, and a missing one still
      fails before any connection. A mapped registry dependency is valid. }
    Expect<string>(Failure(Options(Plain, Origin))).ToBe('credential_missing: '
      + 'environment variable ' + UpperCase(PROGRAM_NAME)
      + '_CLIENT_TEST_UNSET_TOKEN does not hold a registry token');
    Expect<string>(RegistryErrorCode(Failure(Options(WriteArchive('mapped.zip',
      PackageZip('dependent', '1.0.0', REGISTRY + '[dependencies]' + #10
      + 'plain = "registry:plain@^1.0.0"' + #10)), Origin))))
      .ToBe('credential_missing');
    Sleep(100);
    Expect<Integer>(Listener.AcceptedCount).ToBe(0);
  finally
    Listener.Free;
  end;
end;

procedure TRegistryClientContract.SetupTests;
begin
  Test('diagnostics redact the token and its secret', TestRedactionRemovesTokenAndSecret);
  Test('server error codes are grammar-checked and allow-listed',
    TestErrorCodesAreAllowListed);
  Test('request IDs are grammar-checked', TestRequestIDGrammar);
  Test('Retry-After and exponential backoff are bounded', TestRetryAfterAndBackoff);
  Test('origins need https except for the exact host localhost',
    TestOriginTransportRules);
  Test('the published record is canonical',
    TestRecordDocumentIsCanonical);
  Test('record dependencies omit the publishing origin and are in protocol order',
    TestRecordDependenciesAreInProtocolOrder);
  Test('a Location names exactly one record below the API',
    TestLocationNamesOneRecordBelowTheAPI);
  Test('token variable names are validated, never read as tokens',
    TestTokenEnvironmentNames);
  Test('local refusals precede the credential and any connection',
    TestLocalRefusalsPrecedeCredentialsAndConnections);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryClientContract.Create('registry publish client'));
  TestRunnerProgram.Run;
end.
