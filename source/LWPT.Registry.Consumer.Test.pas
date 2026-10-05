program LWPT.Registry.Consumer.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  SysUtils,

  Tests.ProcessSupport,

  LWPT.Core,
  LWPT.Manifest,
  LWPT.ProducerLease,
  LWPT.Registry.Consumer,
  LWPT.Registry.ConsumerStore,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.RegistryConsumer,
  Tests.Scratch,
  Tests.TarSynth;

const
  { A valid Ed25519 pin: the key id is the sha256 of the public key. }
  PIN_PUBLIC = 'hex:ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c';

type
  TRegistryConsumerTests = class(TTestSuite)
  private
    FScratch: string;
    FKeyID, FPublicKey: string;
    FCase: Integer;
    function Load(const AContent: string): TManifest;
    function LoadError(const AContent: string): string;
    function Registry(const AAlias, AFields: string): string;
    function Pin: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestRegistrySourceForms;
    procedure TestDependencyKeyMustEqualPackage;
    procedure TestRegistryVersionsAreSemverWithoutV;
    procedure TestExplicitDefaultAlias;
    procedure TestSingleRegistryIsImplied;
    procedure TestAmbiguousDefaultFails;
    procedure TestMissingRegistryFails;
    procedure TestUndeclaredAliasFails;
    procedure TestReservedAliasRejected;
    procedure TestInvalidPinRejected;
    procedure TestInsecureAndMalformedContactsRejected;
    procedure TestDuplicateContactsAndIdentitiesRejected;
    procedure TestOriginRequiredWithoutIdentity;
    procedure TestUnknownRegistryFieldRejected;
    procedure TestSourcesCannotShadowRegistry;
    procedure TestDependencyManifestRegistriesAreLenient;
    procedure TestAcceptedStateMergeIsMonotonic;
    procedure TestLockTablesRoundTrip;
    procedure TestLockedSelectionVerifiesWithoutHistory;
    procedure TestLockedSelectionRejectsTampering;
    procedure TestLockedSelectionRequiresValidSignature;
    procedure TestConcurrentStateMergesAreMonotonic;
    procedure TestRotationChainLoadingIsBounded;
    procedure TestLockedSelectionLoadingIsBounded;
    procedure TestStateReadsDuringConcurrentPublication;
    procedure TestAbsentStateIsReadUnderThePublisherLease;
    procedure TestTimeoutEndsTheProgramWithoutFinalization;
    {$IFDEF MSWINDOWS}
    procedure TestStateReadsShareAPublisherDeleteHandle;
    {$ENDIF}
  end;

  TMergeThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Root, Identity, KeyId, PublicKey, Error: string;
    Sequence: Integer;
  end;

  { Reads per-user state, and the document being published, without the
    producer lease until the publisher sets Done. }
  TStateReadThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Root, Identity, KeyId: string;
    Sequence: Int64;
    Documents: TStringArray;
    Completed, Done: LongInt;
    Reads, Absences, Failures, MissedDocuments, WrongStates: Integer;
    Failure: string;
  end;

procedure TRegistryConsumerTests.BeforeAll;
var Synthetic: TSyntheticRegistry;
begin
  FScratch := CreateScratchRoot('registry-consumer');
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  try
    FKeyID := Synthetic.KeyID;
    FPublicKey := Synthetic.PublicKey;
  finally
    Synthetic.Free;
  end;
end;

procedure TRegistryConsumerTests.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

function TRegistryConsumerTests.Pin: string;
begin
  Result := 'key-id = "' + FKeyID + '"'#10 + 'public-key = "' + FPublicKey
    + '"'#10;
end;

function TRegistryConsumerTests.Registry(const AAlias, AFields: string): string;
begin
  Result := '[registries.' + AAlias + ']'#10 + AFields;
end;

function TRegistryConsumerTests.Load(const AContent: string): TManifest;
var Path: string;
begin
  Inc(FCase);
  Path := FScratch + '/case-' + IntToStr(FCase);
  ForceDirectories(Path);
  WriteTextFile(Path + '/lwpt.toml', '[package]'#10 + 'name = "root"'#10
    + 'version = "1.0.0"'#10 + AContent);
  Result := LoadManifest(Path + '/lwpt.toml');
end;

function TRegistryConsumerTests.LoadError(const AContent: string): string;
begin
  Result := '';
  try
    Load(AContent);
  except
    on E: Exception do Result := E.Message;
  end;
end;

procedure TRegistryConsumerTests.TestRegistrySourceForms;
var Manifest: TManifest; Index: Integer;
begin
  Manifest := Load(Registry('corp', 'identity = "https://packages.example.com"'#10
    + Pin) + '[dependencies]'#10
    + 'json = "registry:json@^1.2.0"'#10
    + 'http = "registry:corp/http@~2.0.0"'#10
    + 'extras = { source = "registry:corp/extras", version = "^0.3.0", '
    + 'include = ["source/**"] }'#10);
  Expect<Integer>(Length(Manifest.Deps)).ToBe(3);
  for Index := 0 to High(Manifest.Deps) do
  begin
    Expect<Boolean>(Manifest.Deps[Index].SrcKind = skRegistry).ToBe(True);
    Expect<string>(Manifest.Deps[Index].SrcLocator).ToBe(Manifest.Deps[Index].Name);
  end;
  Expect<string>(Manifest.Deps[0].RegistryAlias).ToBe('');
  Expect<string>(Manifest.Deps[1].RegistryAlias).ToBe('corp');
  Expect<Boolean>(Manifest.Deps[1].VersionKind = vkSemverRange).ToBe(True);
  Expect<string>(Manifest.Deps[2].VersionSpec).ToBe('^0.3.0');
  Expect<Integer>(Length(Manifest.Deps[2].IncludeGlobs)).ToBe(1);
  Expect<string>(RegistryAliasFor(Manifest, Manifest.Deps[0])).ToBe('corp');
end;

procedure TRegistryConsumerTests.TestDependencyKeyMustEqualPackage;
begin
  Expect<Boolean>(Pos('must equal its package name', LoadError(
    Registry('corp', 'identity = "https://packages.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'jsonlib = "registry:corp/json@^1.0.0"'#10)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('[a-z0-9][a-z0-9_-]{0,127}', LoadError(
    Registry('corp', 'identity = "https://packages.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'json = "registry:corp/js.on"'#10)) > 0)
    .ToBe(True);
end;

procedure TRegistryConsumerTests.TestRegistryVersionsAreSemverWithoutV;
var Header: string;
begin
  Header := Registry('corp', 'identity = "https://packages.example.com"'#10 + Pin)
    + '[dependencies]'#10;
  Expect<Boolean>(Pos('SemVer without "v"', LoadError(Header
    + 'json = "registry:json@v1.2.0"'#10)) > 0).ToBe(True);
  Expect<Boolean>(Pos('SemVer without "v"', LoadError(Header
    + 'json = "registry:json@^v1.2.0"'#10)) > 0).ToBe(True);
  Expect<Boolean>(Pos('SemVer without "v"', LoadError(Header
    + 'json = "registry:json@0123456789abcdef0123456789abcdef01234567"'#10)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('SemVer without "v"', LoadError(Header
    + 'json = "registry:json@main"'#10)) > 0).ToBe(True);
  Expect<Integer>(Length(Load(Header + 'json = "registry:json@1.2.3-dev.1"'#10)
    .Deps)).ToBe(1);
  Expect<Integer>(Length(Load(Header + 'json = "registry:json"'#10).Deps))
    .ToBe(1);
end;

procedure TRegistryConsumerTests.TestExplicitDefaultAlias;
var Manifest: TManifest;
begin
  Manifest := Load('[registries]'#10 + 'default = "oss"'#10
    + Registry('corp', 'identity = "https://corp.example.com"'#10 + Pin)
    + Registry('oss', 'identity = "https://oss.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'json = "registry:json"'#10);
  Expect<string>(RegistryAliasFor(Manifest, Manifest.Deps[0])).ToBe('oss');
  Expect<Boolean>(Pos('default names undeclared registry "missing"', LoadError(
    '[registries]'#10 + 'default = "missing"'#10
    + Registry('corp', 'identity = "https://corp.example.com"'#10 + Pin))) > 0)
    .ToBe(True);
end;

procedure TRegistryConsumerTests.TestSingleRegistryIsImplied;
var Manifest: TManifest;
begin
  Manifest := Load(Registry('corp', 'origin = "https://corp.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'json = "registry:json"'#10);
  Expect<string>(RegistryAliasFor(Manifest, Manifest.Deps[0])).ToBe('corp');
  Expect<string>(Manifest.Registries[0].Identity).ToBe('');
  Expect<string>(Manifest.Registries[0].Origin).ToBe('https://corp.example.com');
end;

procedure TRegistryConsumerTests.TestAmbiguousDefaultFails;
begin
  Expect<Boolean>(Pos('registries corp and oss are declared and no default is '
    + 'set; write registry:<alias>/json', LoadError(
    Registry('corp', 'identity = "https://corp.example.com"'#10 + Pin)
    + Registry('oss', 'identity = "https://oss.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'json = "registry:json"'#10)) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestMissingRegistryFails;
begin
  Expect<Boolean>(Pos('uses registry:json but no registry is declared; add '
    + '[registries.<alias>]', LoadError('[dependencies]'#10
    + 'json = "registry:json"'#10)) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestUndeclaredAliasFails;
begin
  Expect<Boolean>(Pos('registry alias "oss" is not declared', LoadError(
    Registry('corp', 'identity = "https://corp.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'json = "registry:oss/json"'#10)) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestReservedAliasRejected;
begin
  Expect<Boolean>(Pos('must not be "default"', LoadError(
    Registry('corp', 'identity = "https://corp.example.com"'#10 + Pin)
    + '[dependencies]'#10 + 'json = "registry:default/json"'#10)) > 0)
    .ToBe(True);
  Expect<Boolean>(LoadError(Registry('default',
    'identity = "https://corp.example.com"'#10 + Pin)) <> '').ToBe(True);
end;

procedure TRegistryConsumerTests.TestInvalidPinRejected;
begin
  Expect<Boolean>(Pos('do not form a valid Ed25519 pin', LoadError(
    Registry('corp', 'identity = "https://corp.example.com"'#10
    + 'key-id = "ed25519:' + StringOfChar('0', 64) + '"'#10
    + 'public-key = "' + PIN_PUBLIC + '"'#10))) > 0).ToBe(True);
  Expect<Boolean>(LoadError(Registry('corp',
    'identity = "https://corp.example.com"'#10)) <> '').ToBe(True);
end;

procedure TRegistryConsumerTests.TestInsecureAndMalformedContactsRejected;
begin
  Expect<Boolean>(Pos('insecure_transport', LoadError(Registry('corp',
    'origin = "http://corp.example.com"'#10 + Pin))) > 0).ToBe(True);
  Expect<Boolean>(Pos('insecure_transport', LoadError(Registry('corp',
    'identity = "https://corp.example.com"'#10
    + 'mirrors = ["http://127.0.0.1:8080"]'#10 + Pin))) > 0).ToBe(True);
  Expect<Boolean>(Pos('not a canonical https registry URI', LoadError(
    Registry('corp', 'identity = "https://Corp.example.com/"'#10 + Pin))) > 0)
    .ToBe(True);
  Expect<Boolean>(LoadError(Registry('corp',
    'identity = "https://[2001:db8::1]"'#10 + Pin)) <> '').ToBe(True);
end;

procedure TRegistryConsumerTests.TestDuplicateContactsAndIdentitiesRejected;
begin
  Expect<Boolean>(Pos('is listed more than once', LoadError(Registry('corp',
    'identity = "https://corp.example.com"'#10
    + 'mirrors = ["https://corp.example.com"]'#10 + Pin))) > 0).ToBe(True);
  Expect<Boolean>(Pos('is already declared under another alias', LoadError(
    Registry('corp', 'identity = "https://corp.example.com"'#10 + Pin)
    + Registry('copy', 'identity = "https://corp.example.com"'#10
    + 'origin = "https://mirror.example.com"'#10 + Pin))) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestOriginRequiredWithoutIdentity;
begin
  Expect<Boolean>(Pos('needs an origin contact when identity is omitted',
    LoadError(Registry('corp', Pin))) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestUnknownRegistryFieldRejected;
begin
  Expect<Boolean>(Pos('unknown field "token"', LoadError(Registry('corp',
    'identity = "https://corp.example.com"'#10 + 'token = "secret"'#10
    + Pin))) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestSourcesCannotShadowRegistry;
begin
  Expect<Boolean>(Pos('shadows a built-in prefix', LoadError('[sources]'#10
    + 'registry = { archive = "https://x.example.com/{user}/{repository}/'
    + '{ref}.tar.gz", git = "https://x.example.com/{user}/{repository}.git" }'
    + #10)) > 0).ToBe(True);
end;

procedure TRegistryConsumerTests.TestDependencyManifestRegistriesAreLenient;
var Path: string; Manifest: TManifest;
begin
  Path := FScratch + '/dependency';
  ForceDirectories(Path);
  WriteTextFile(Path + '/lwpt.toml', '[package]'#10 + 'name = "dep"'#10
    + Registry('corp', 'origin = "http://corp.example.com"'#10));
  Manifest := LoadManifest(Path + '/lwpt.toml', False);
  Expect<Integer>(Length(Manifest.Registries)).ToBe(1);
end;

function State(const ASequence: Int64; const APublishedAt,
  AFloor: string): TLWPTRegistryConsumerState;
begin
  Result := Default(TLWPTRegistryConsumerState);
  Result.State.Sequence := ASequence;
  Result.State.PublishedAt := APublishedAt;
  Result.State.ClockFloor := AFloor;
  Result.State.Snapshot := 'sha256:' + StringOfChar(Chr(Ord('0') + ASequence mod 10), 64);
end;

procedure TRegistryConsumerTests.TestAcceptedStateMergeIsMonotonic;
var Merged: TLWPTRegistryConsumerState;
begin
  Merged := MergeRegistryAcceptedStates(
    State(57, '2026-10-20T00:00:00Z', '2026-10-20T00:00:00Z'),
    State(42, '2026-09-29T00:00:00Z', '2026-09-29T00:00:00Z'));
  Expect<Int64>(Merged.State.Sequence).ToBe(57);
  { A later checkpoint published earlier than the floor never lowers it. }
  Merged := MergeRegistryAcceptedStates(
    State(60, '2026-10-10T00:00:00Z', ''),
    State(57, '2026-10-20T00:00:00Z', '2026-10-20T00:00:00Z'));
  Expect<Int64>(Merged.State.Sequence).ToBe(60);
  Expect<string>(Merged.State.ClockFloor).ToBe('2026-10-20T00:00:00Z');
  Merged := MergeRegistryAcceptedStates(Default(TLWPTRegistryConsumerState),
    State(3, '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'));
  Expect<Int64>(Merged.State.Sequence).ToBe(3);
end;

procedure TRegistryConsumerTests.TestLockTablesRoundTrip;
var
  Tables, Loaded: TLWPTRegistryLockTableArray;
  Lines: TStringList;
begin
  SetLength(Tables, 1);
  Tables[0].Identity := 'https://packages.example.com';
  Tables[0].TrustKeyId := FKeyID;
  Tables[0].KeyId := FKeyID;
  Tables[0].Sequence := 42;
  Tables[0].Snapshot := 'sha256:' + StringOfChar('a', 64);
  Tables[0].Checkpoint := 'sha256:' + StringOfChar('b', 64);
  Tables[0].Signature := 'sha256:' + StringOfChar('c', 64);
  Tables[0].PublishedAt := '2026-09-29T00:00:00Z';
  Tables[0].ExpiresAt := '2026-10-06T00:00:00Z';
  Tables[0].Accepted := State(57, '2026-10-20T00:00:00Z', '2026-10-21T00:00:00Z');
  Tables[0].Accepted.State.CheckpointHash := 'sha256:' + StringOfChar('d', 64);
  Tables[0].Accepted.State.KeyId := FKeyID;
  Tables[0].Accepted.State.ExpiresAt := '2026-10-27T00:00:00Z';
  Lines := TStringList.Create;
  try
    Lines.Add('version = 4');
    RenderRegistryLockTables(Tables, Lines);
    Lines.SaveToFile(FScratch + '/tables.lock');
  finally
    Lines.Free;
  end;
  Loaded := LoadRegistryLockTables(FScratch + '/tables.lock');
  Expect<Integer>(Length(Loaded)).ToBe(1);
  Expect<string>(Loaded[0].Identity).ToBe('https://packages.example.com');
  Expect<Int64>(Loaded[0].Sequence).ToBe(42);
  Expect<Int64>(Loaded[0].Accepted.State.Sequence).ToBe(57);
  Expect<string>(Loaded[0].Accepted.State.ClockFloor).ToBe('2026-10-21T00:00:00Z');
  Expect<string>(Loaded[0].Checkpoint).ToBe(Tables[0].Checkpoint);
end;

function SelectionOf(ARegistry: TSyntheticRegistry; const ACheckpoint: Integer;
  const ARecord: string): TLWPTRegistryLockedSelection;
var Current: TSyntheticCheckpoint; Checkpoint: TLWPTUntrustedRegistryCheckpoint;
begin
  Current := ARegistry.Checkpoint(ACheckpoint);
  Result := Default(TLWPTRegistryLockedSelection);
  Result.Checkpoint := Current.Checkpoint;
  Result.Signature := Current.Signature;
  Checkpoint := InspectRegistryCheckpoint(Current.Checkpoint);
  ARegistry.Document('snapshots/sha256/' + Copy(Checkpoint.Snapshot, 8, 64)
    + '.toml', Result.Snapshot);
  SetLength(Result.Records, 1);
  ARegistry.Document('records/sha256/' + Copy(ARecord, 8, 64) + '.toml',
    Result.Records[0]);
end;

function TrustOf(ARegistry: TSyntheticRegistry): TLWPTRegistryTrust;
begin
  Result.Origin := ARegistry.Identity;
  Result.KeyId := ARegistry.KeyID;
  Result.PublicKey := ARegistry.PublicKey;
end;

{ The lock's claims for ASelection: its own bytes' hashes, and the one
  record recorded as AName@AVersion with its signed archive. }
function ClaimsOf(ARegistry: TSyntheticRegistry;
  const ASelection: TLWPTRegistryLockedSelection;
  const AName, AVersion: string): TLWPTRegistryLockedClaims;
var Checkpoint: TLWPTUntrustedRegistryCheckpoint;
begin
  Checkpoint := InspectRegistryCheckpoint(ASelection.Checkpoint);
  Result := Default(TLWPTRegistryLockedClaims);
  Result.Checkpoint := SHA256BytesPrefixed(ASelection.Checkpoint);
  Result.Signature := SHA256BytesPrefixed(ASelection.Signature);
  Result.Snapshot := Checkpoint.Snapshot;
  Result.KeyId := Checkpoint.KeyId;
  Result.Sequence := Checkpoint.Sequence;
  Result.PublishedAt := Checkpoint.PublishedAt;
  Result.ExpiresAt := Checkpoint.ExpiresAt;
  SetLength(Result.Records, 1);
  Result.Records[0].RecordHash := SHA256BytesPrefixed(ASelection.Records[0]);
  Result.Records[0].Name := AName;
  Result.Records[0].Version := AVersion;
  Result.Records[0].ArchiveHash := ARegistry.ArchiveHashOf(AName, AVersion);
end;

procedure TRegistryConsumerTests.TestLockedSelectionVerifiesWithoutHistory;
var
  Synthetic: TSyntheticRegistry;
  Selection: TLWPTRegistryLockedSelection;
  Verified: TLWPTVerifiedRegistrySelection;
  Index: Integer;
begin
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  try
    Synthetic.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Synthetic.Publish(RegistryStamp(-20 * 86400), RegistryStamp(-14 * 86400));
    Synthetic.AddPackage('json', '1.1.0', RegistryPackageArchive('json', '1.1.0'), []);
    { An expired checkpoint still verifies: no expiry, no floor. }
    Index := Synthetic.Publish(RegistryStamp(-10 * 86400), RegistryStamp(-4 * 86400));
    Selection := SelectionOf(Synthetic, Index, Synthetic.RecordHash('json', '1.1.0'));
    Verified := VerifyRegistryLockedSelection(Selection, TrustOf(Synthetic),
      ClaimsOf(Synthetic, Selection, 'json', '1.1.0'));
    Expect<Int64>(Verified.Sequence).ToBe(2);
    Expect<string>(Verified.Packages[0].Version).ToBe('1.1.0');
  finally
    Synthetic.Free;
  end;
end;

procedure TRegistryConsumerTests.TestLockedSelectionRejectsTampering;
var
  Synthetic, Other: TSyntheticRegistry;
  Selection, Tampered: TLWPTRegistryLockedSelection;
  Index: Integer;
  Message: string;

  function Failure(const ASelection: TLWPTRegistryLockedSelection;
    const ATrust: TLWPTRegistryTrust;
    const AClaims: TLWPTRegistryLockedClaims): string;
  begin
    Result := '';
    try
      VerifyRegistryLockedSelection(ASelection, ATrust, AClaims);
    except
      on E: Exception do Result := E.Message;
    end;
  end;

var Claims: TLWPTRegistryLockedClaims;

begin
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  Other := TSyntheticRegistry.Create('https://packages.example.com', 9);
  try
    Synthetic.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Index := Synthetic.Publish(RegistryStamp(-60), RegistryStamp(86400));
    Selection := SelectionOf(Synthetic, Index, Synthetic.RecordHash('json', '1.0.0'));
    { The recorded checkpoint hash must name these bytes. }
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.Checkpoint := 'sha256:' + StringOfChar('0', 64);
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    { So must the recorded signature hash. }
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.Signature := 'sha256:' + StringOfChar('0', 64);
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    { The recorded sequence, key, and snapshot are the checkpoint's. }
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.Sequence := Claims.Sequence + 1;
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.Snapshot := 'sha256:' + StringOfChar('1', 64);
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    { So are its signed publication and expiry times. }
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.PublishedAt := RegistryStamp(-3600);
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.ExpiresAt := RegistryStamp(30 * 86400);
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    { A different pin cannot verify the signature. }
    Message := Failure(Selection, TrustOf(Other),
      ClaimsOf(Synthetic, Selection, 'json', '1.0.0'));
    Expect<Boolean>(Message <> '').ToBe(True);
    { A record outside the signed snapshot is not a member. }
    Tampered := Selection;
    { The outer array is shared by the record copy: copy it first. }
    Tampered.Records := Copy(Selection.Records);
    Tampered.Records[0] := Copy(Selection.Records[0]);
    Tampered.Records[0][Length(Tampered.Records[0]) - 3] := Ord('X');
    Message := Failure(Tampered, TrustOf(Synthetic),
      ClaimsOf(Synthetic, Tampered, 'json', '1.0.0'));
    Expect<Boolean>(Pos('registry_record_not_in_snapshot', Message) > 0).ToBe(True);
    { Record bytes must be the ones the lock names. }
    Message := Failure(Tampered, TrustOf(Synthetic),
      ClaimsOf(Synthetic, Selection, 'json', '1.0.0'));
    Expect<Boolean>(Pos('locked_record_mismatch', Message) > 0).ToBe(True);
    { A member record whose fields differ from the lock fails. }
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.Records[0].Version := '1.0.1';
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_record_mismatch', Message) > 0).ToBe(True);
    Claims := ClaimsOf(Synthetic, Selection, 'json', '1.0.0');
    Claims.Records[0].ArchiveHash := 'sha256:' + StringOfChar('2', 64);
    Message := Failure(Selection, TrustOf(Synthetic), Claims);
    Expect<Boolean>(Pos('locked_record_mismatch', Message) > 0).ToBe(True);
    { A snapshot that is not the checkpoint's fails. }
    Tampered := Selection;
    Tampered.Snapshot := Copy(Selection.Snapshot);
    Tampered.Snapshot[10] := Ord('X');
    Message := Failure(Tampered, TrustOf(Synthetic),
      ClaimsOf(Synthetic, Selection, 'json', '1.0.0'));
    Expect<Boolean>(Pos('snapshot_hash_mismatch', Message) > 0).ToBe(True);
  finally
    Other.Free;
    Synthetic.Free;
  end;
end;

{ A canonical envelope with the right key id and payload hash but a wrong
  signature must fail: only Ed25519 verification rejects it. }
procedure TRegistryConsumerTests.TestLockedSelectionRequiresValidSignature;
var
  Synthetic: TSyntheticRegistry;
  Selection: TLWPTRegistryLockedSelection;
  Index, Position: Integer;
  Message, Text: string;
begin
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  try
    Synthetic.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Index := Synthetic.Publish(RegistryStamp(-60), RegistryStamp(86400));
    Selection := SelectionOf(Synthetic, Index, Synthetic.RecordHash('json', '1.0.0'));
    Selection.Signature := Copy(Selection.Signature);
    SetString(Text, PAnsiChar(@Selection.Signature[0]), Length(Selection.Signature));
    Position := Pos('signature = "hex:', Text) + Length('signature = "hex:') + 10;
    if Selection.Signature[Position - 1] = Ord('0') then
      Selection.Signature[Position - 1] := Ord('1')
    else Selection.Signature[Position - 1] := Ord('0');
    Message := '';
    try
      VerifyRegistryLockedSelection(Selection, TrustOf(Synthetic),
        ClaimsOf(Synthetic, Selection, 'json', '1.0.0'));
    except
      on E: Exception do Message := E.Message;
    end;
    Expect<Boolean>(Pos('signature_invalid', Message) > 0).ToBe(True);
  finally
    Synthetic.Free;
  end;
end;

procedure TMergeThread.Execute;
var State: TLWPTRegistryConsumerState;
begin
  try
    State := Default(TLWPTRegistryConsumerState);
    State.State.KeyId := KeyId;
    State.State.PublicKey := PublicKey;
    State.State.Sequence := Sequence;
    State.State.Snapshot := 'sha256:' + StringOfChar('a', 62)
      + LowerCase(Format('%.2x', [Sequence]));
    State.State.CheckpointHash := 'sha256:' + StringOfChar('b', 62)
      + LowerCase(Format('%.2x', [Sequence]));
    State.State.PublishedAt := Format('2026-10-%.2dT00:00:00Z', [Sequence]);
    State.State.ExpiresAt := Format('2026-10-%.2dT12:00:00Z', [Sequence]);
    State.State.ClockFloor := State.State.PublishedAt;
    MergeRegistryConsumerStateAt(Root, Identity, KeyId, State, nil, nil);
  except
    on E: Exception do Error := E.Message;
  end;
end;

procedure TRegistryConsumerTests.TestConcurrentStateMergesAreMonotonic;
const
  MERGE_WORKERS = 12;
var
  Threads: array[1..MERGE_WORKERS] of TMergeThread;
  Index: Integer;
  Loaded: TLWPTRegistryConsumerState;
  Root: string;
begin
  Root := FScratch + '/concurrent-state';
  for Index := 1 to MERGE_WORKERS do
  begin
    Threads[Index] := TMergeThread.Create(True);
    Threads[Index].Root := Root;
    Threads[Index].Identity := 'https://packages.example.com';
    Threads[Index].KeyId := FKeyID;
    Threads[Index].PublicKey := FPublicKey;
    { A permutation of 1..MERGE_WORKERS that interleaves high and low. }
    Threads[Index].Sequence := (Index * 5) mod MERGE_WORKERS + 1;
  end;
  for Index := 1 to MERGE_WORKERS do Threads[Index].Start;
  for Index := 1 to MERGE_WORKERS do
  begin
    Threads[Index].WaitFor;
    Expect<string>(Threads[Index].Error).ToBe('');
    Threads[Index].Free;
  end;
  Expect<Boolean>(LoadRegistryConsumerStateAt(Root,
    'https://packages.example.com', FKeyID, Loaded)).ToBe(True);
  Expect<Int64>(Loaded.State.Sequence).ToBe(MERGE_WORKERS);
  Expect<string>(Loaded.State.ClockFloor)
    .ToBe(Format('2026-10-%.2dT00:00:00Z', [MERGE_WORKERS]));
end;

procedure TRegistryConsumerTests.TestLockedSelectionLoadingIsBounded;
var
  Synthetic: TSyntheticRegistry;
  Current: TSyntheticCheckpoint;
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
  Table: TLWPTRegistryLockTable;
  Selection: TLWPTRegistryLockedSelection;
  Limits: TLWPTRegistryVerificationLimits;
  Records, Many: TStringArray;
  Archives, State, Message, Big: string;
  Snapshot, RecordBytes: TBytes;
  Index: Integer;

  procedure Commit(const ABytes: TBytes);
  begin
    WriteBytesToFile(RegistryProofPath(Archives, SHA256BytesPrefixed(ABytes)),
      ABytes);
  end;

  function Failure(const ATable: TLWPTRegistryLockTable;
    const ARecords: TStringArray; const ALimits: TLWPTRegistryVerificationLimits;
    const AState: string = ''): string;
  begin
    Result := '';
    try
      LoadLockedRegistrySelection(Archives, AState, ATable, ARecords, ALimits);
    except
      on E: Exception do Result := E.Message;
    end;
  end;

begin
  Archives := FScratch + '/locked-load/archives';
  State := FScratch + '/locked-load/state';
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  try
    Synthetic.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Current := Synthetic.Checkpoint(Synthetic.Publish(RegistryStamp(-60),
      RegistryStamp(86400)));
    Checkpoint := InspectRegistryCheckpoint(Current.Checkpoint);
    Synthetic.Document('snapshots/sha256/' + Copy(Checkpoint.Snapshot, 8, 64)
      + '.toml', Snapshot);
    Synthetic.Document('records/sha256/' + Copy(Synthetic.RecordHash('json',
      '1.0.0'), 8, 64) + '.toml', RecordBytes);
    Commit(Current.Checkpoint);
    Commit(Current.Signature);
    Commit(Snapshot);
    Commit(RecordBytes);
    Table := Default(TLWPTRegistryLockTable);
    Table.Checkpoint := SHA256BytesPrefixed(Current.Checkpoint);
    Table.Signature := SHA256BytesPrefixed(Current.Signature);
    Table.Snapshot := Checkpoint.Snapshot;
    SetLength(Records, 1);
    Records[0] := Synthetic.RecordHash('json', '1.0.0');
    Limits := DefaultRegistryVerificationLimits;
    Selection := LoadLockedRegistrySelection(Archives, '', Table, Records, Limits);
    Expect<Integer>(Length(Selection.Records)).ToBe(1);
    { A repeated rotation document is refused before any read. }
    SetLength(Table.Rotations, 3);
    for Index := 0 to 2 do Table.Rotations[Index] := Table.Snapshot;
    Expect<Boolean>(Pos('named more than once', Failure(Table, Records, Limits)) > 0)
      .ToBe(True);
    { So is a repeated record. }
    Table.Rotations := nil;
    SetLength(Many, 2);
    Many[0] := Records[0];
    Many[1] := Records[0];
    Expect<Boolean>(Pos('named more than once', Failure(Table, Many, Limits)) > 0)
      .ToBe(True);
    { More rotations than the verifier accepts: refused by count first. }
    SetLength(Many, 3 * (Limits.Rotations + 1));
    for Index := 0 to High(Many) do
      Many[Index] := 'sha256:' + LowerCase(Format('%.64x', [Index]));
    Table.Rotations := Many;
    Expect<Boolean>(Pos('proof_limit_exceeded', Failure(Table, Records, Limits)) > 0)
      .ToBe(True);
    Table.Rotations := nil;
    { The cumulative budget is charged before each allocation. }
    Limits.TotalBytes := Length(Current.Checkpoint) + Length(Current.Signature);
    Expect<Boolean>(Pos('proof_limit_exceeded', Failure(Table, Records, Limits)) > 0)
      .ToBe(True);
    Limits := DefaultRegistryVerificationLimits;
    { An oversized document is refused by its size, before it is read: a
      sparse gigabyte named by a canonical hash costs nothing. }
    Big := 'sha256:' + StringOfChar('c', 64);
    CreateSparseFile(RegistryProofPath(Archives, Big), Int64(1024) * 1024 * 1024);
    Table.Rotations := nil;
    SetLength(Many, 1);
    Many[0] := Big;
    Expect<Boolean>(Pos('proof_limit_exceeded', Failure(Table, Many, Limits)) > 0)
      .ToBe(True);
    DeleteFile(RegistryProofPath(Archives, Big));
    { A corrupt committed document is never read around, even when the
      per-user store holds good bytes; an absent one comes from the store. }
    WriteBytesToFile(State + '/documents/sha256/'
      + Copy(Records[0], 8, 64) + '.toml', RecordBytes);
    WriteBytesToFile(RegistryProofPath(Archives, Records[0]), BytesOf('corrupt'));
    Message := Failure(Table, Records, Limits, State);
    Expect<Boolean>(Pos('registry_proof_corrupt', Message) > 0).ToBe(True);
    DeleteFile(RegistryProofPath(Archives, Records[0]));
    Selection := LoadLockedRegistrySelection(Archives, State, Table, Records,
      Limits);
    Expect<Integer>(Length(Selection.Records[0])).ToBe(Length(RecordBytes));
    Expect<Boolean>(Pos('registry_proof_missing', Failure(Table, Records,
      Limits)) > 0).ToBe(True);
  finally
    Synthetic.Free;
  end;
end;

procedure TRegistryConsumerTests.TestRotationChainLoadingIsBounded;
var
  Synthetic: TSyntheticRegistry;
  Rotation: TSyntheticRotation;
  Proofs: TLWPTRegistryRotationProofArray;
  Chain: TLWPTRegistryRotationProofArray;
  State: TLWPTRegistryConsumerState;
  Hashes, Repeated, Many: TStringArray;
  Limits: TLWPTRegistryVerificationLimits;
  Root: string;
  Index, Size: Integer;
begin
  Root := FScratch + '/bounded-chain';
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  try
    Synthetic.Publish(RegistryStamp(-60), RegistryStamp(86400));
    Synthetic.Rotate(11);
    Rotation := Synthetic.Rotation(0);
    SetLength(Proofs, 1);
    Proofs[0].Document := Rotation.Document;
    Proofs[0].OldSignature := Rotation.OldSignature;
    Proofs[0].NewSignature := Rotation.NewSignature;
    State := Default(TLWPTRegistryConsumerState);
    State.State.KeyId := FKeyID;
    State.State.PublicKey := FPublicKey;
    State.State.Sequence := 1;
    State.State.Snapshot := 'sha256:' + StringOfChar('a', 64);
    State.State.CheckpointHash := 'sha256:' + StringOfChar('b', 64);
    State.State.PublishedAt := '2026-10-01T00:00:00Z';
    State.State.ExpiresAt := '2026-10-02T00:00:00Z';
    State.State.ClockFloor := State.State.PublishedAt;
    MergeRegistryConsumerStateAt(Root, 'https://packages.example.com', FKeyID,
      State, Proofs, nil);
    Hashes := RegistryRotationHashes(Proofs);
    Limits := DefaultRegistryVerificationLimits;
    Expect<Boolean>(LoadRegistryRotationChain(Root, '', Hashes, Limits, Chain))
      .ToBe(True);
    Expect<Integer>(Length(Chain)).ToBe(1);
    { A repeated triplet is refused before anything is read. }
    SetLength(Repeated, 6);
    for Index := 0 to 5 do Repeated[Index] := Hashes[Index mod 3];
    Expect<Boolean>(LoadRegistryRotationChain(Root, '', Repeated, Limits, Chain))
      .ToBe(False);
    Expect<Integer>(Length(Chain)).ToBe(0);
    { More rotations than the verifier accepts are refused before any
      allocation or read, even with distinct hashes. }
    SetLength(Many, 3 * (Limits.Rotations + 1));
    for Index := 0 to High(Many) do
      Many[Index] := 'sha256:' + LowerCase(Format('%.64x', [Index]));
    Expect<Boolean>(LoadRegistryRotationChain(Root, '', Many, Limits, Chain))
      .ToBe(False);
    { The cumulative byte budget applies across the chain. }
    Size := Length(Proofs[0].Document) + Length(Proofs[0].OldSignature)
      + Length(Proofs[0].NewSignature);
    Limits.TotalBytes := Size - 1;
    Expect<Boolean>(LoadRegistryRotationChain(Root, '', Hashes, Limits, Chain))
      .ToBe(False);
    Limits := DefaultRegistryVerificationLimits;
    Limits.DocumentBytes := 16;
    Expect<Boolean>(LoadRegistryRotationChain(Root, '', Hashes, Limits, Chain))
      .ToBe(False);
  finally
    Synthetic.Free;
  end;
end;

const
  RACE_IDENTITY = 'https://packages.example.com';

{ Accepted state at ASequence, its timestamps rising with it. }
function SequencedState(const AKeyId, APublicKey: string;
  const ASequence: Integer): TLWPTRegistryConsumerState;
begin
  Result := Default(TLWPTRegistryConsumerState);
  Result.State.KeyId := AKeyId;
  Result.State.PublicKey := APublicKey;
  Result.State.Sequence := ASequence;
  Result.State.Snapshot := 'sha256:' + StringOfChar('a', 56)
    + LowerCase(IntToHex(ASequence, 8));
  Result.State.CheckpointHash := 'sha256:' + StringOfChar('b', 56)
    + LowerCase(IntToHex(ASequence, 8));
  Result.State.PublishedAt := Format('2026-10-01T%.2d:%.2d:00Z',
    [ASequence div 60, ASequence mod 60]);
  Result.State.ExpiresAt := '2026-10-02T00:00:00Z';
  Result.State.ClockFloor := Result.State.PublishedAt;
end;

function RaceDocument(const AIndex: Integer): TLWPTRegistryDocumentArray;
begin
  SetLength(Result, 1);
  Result[0].Bytes := BytesOf('race document ' + IntToStr(AIndex) + #10);
end;

procedure TStateReadThread.Execute;
var
  State: TLWPTRegistryConsumerState;
  Next: LongInt;
  Present: Boolean;
begin
  repeat
    try
      if LoadRegistryConsumerStateAt(Root, Identity, KeyId, State) then
      begin
        Inc(Reads);
        if State.State.Sequence <> Sequence then Inc(WrongStates);
      end
      else Inc(Absences);
      { The document the publisher is renaming into place now. Documents
        are written once and never removed here, so one that exists must
        read whole. }
      Next := InterLockedExchangeAdd(Completed, 0);
      if Next <= High(Documents) then
      begin
        Present := RegistryStoreFileIsRegular(RegistryStateDocumentPath(Root,
          Documents[Next]));
        if Present and (LoadRegistryStateDocument(Root, Documents[Next])
          = nil) then Inc(MissedDocuments);
      end;
    except
      on E: Exception do
      begin
        Inc(Failures);
        if Failure = '' then Failure := E.ClassName + ': ' + E.Message;
      end;
    end;
  until InterLockedExchangeAdd(Done, 0) <> 0;
end;

var
  { Set by the reader thread whenever it waits for the publisher's lease. }
  RaceReaderWaiting: LongInt = 0;

procedure NoteRaceReaderWaiting(const AKey: string);
begin
  InterLockedExchange(RaceReaderWaiting, 1);
end;

const
  { Bounds every wait in the race test. A reader iteration can itself wait
    RegistryStateLeaseWaitMilliseconds for the lease, so a finishing reader
    always fits; only a stuck one exceeds it. }
  RACE_WAIT_MILLISECONDS = 2 * RegistryStateLeaseWaitMilliseconds;

const
  RACE_ABORT_EXIT_CODE = 3;
  RACE_ABORT_PROBE_ARGUMENT = '--race-abort-probe';

{ Reports AWhat on stderr and ends the process at once, with no exit
  procedures and no unit finalization. A worker thread that outlived its
  bound may still be running and may touch unit state (the producer-lease
  globals, the contention hook), so neither later tests nor finalization
  may run beneath it; lwpt test reports the program as failed with this
  line. }
procedure AbortTestProgram(const AWhat: string);
begin
  Flush(Output);
  WriteLn(ErrOutput, 'FATAL: ', AWhat, '; ending the test program without '
    + 'finalization');
  Flush(ErrOutput);
  EndProcessAbruptly(RACE_ABORT_EXIT_CODE);
end;

{ The publisher's per-origin lease, or a failure naming the key once
  RACE_WAIT_MILLISECONDS pass without it. }
function AwaitStateLease(ACoordinator: TLWPTProducerLeaseCoordinator;
  const AKey: string): TLWPTProducerLease;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    Result := ACoordinator.TryAcquire(AKey, 'test state publisher');
    if Result <> nil then Exit;
    if GetTickCount64 - StartedAt >= RACE_WAIT_MILLISECONDS then
      raise Exception.CreateFmt(
        'the test publisher could not take lease %s within %d ms',
        [AKey, RACE_WAIT_MILLISECONDS]);
    Sleep(1);
  until False;
end;

{ True once AThread has finished Execute, False when AMilliseconds pass
  first. Free on a finished thread still joins the operating-system thread
  (pthread_join on Unix), which returns once the thread function, already
  past Execute, exits; Free on a thread that has not finished would join
  without a limit, so it is never called on one. }
function AwaitThreadFinished(AThread: TThread;
  const AMilliseconds: QWord): Boolean;
var StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not AThread.Finished do
  begin
    if GetTickCount64 - StartedAt >= AMilliseconds then Exit(False);
    Sleep(10);
  end;
  Result := True;
end;

{ Another project's install publishes per-user state and documents while
  this install reads them without the producer lease (#372). The publisher
  runs the primitive a merge uses, under the per-origin lease a merge
  holds: each round first-publishes a new document and replaces the state
  file with AtomicWriteBytes. Neither side may fail for the other. Every
  state read returns the published state: never absent, never torn, never
  an open error (on Windows a sharing violation, or the moment ReplaceFileW
  has moved the old file aside, which the reader waits out under the
  lease). No existing document is unreadable, and every publication
  commits. FPC's fmShareDenyNone, which does not share delete access,
  failed both sides on Windows. }
procedure TRegistryConsumerTests.TestStateReadsDuringConcurrentPublication;
const
  BATCHES = 40;
  ROUNDS = 10;
  STATE_SEQUENCE = 9;
var
  Root, StatePath, Failure: string;
  StateBytes, DocumentBytes: TBytes;
  Reader: TStateReadThread;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Loaded: TLWPTRegistryConsumerState;
  Batch, Round, Index, Failures: Integer;
  Started: Boolean;
begin
  Root := FScratch + '/state-read-race';
  MergeRegistryConsumerStateAt(Root, RACE_IDENTITY, FKeyID,
    SequencedState(FKeyID, FPublicKey, STATE_SEQUENCE), nil, nil);
  StatePath := RegistryStatePathAt(Root, RACE_IDENTITY, FKeyID);
  StateBytes := BytesOf(ReadBinaryFile(StatePath));
  Coordinator := TLWPTProducerLeaseCoordinator.Create(Root + '/locks');
  Reader := TStateReadThread.Create(True);
  Started := False;
  try
    Reader.Root := Root;
    Reader.Identity := RACE_IDENTITY;
    Reader.KeyId := FKeyID;
    Reader.Sequence := STATE_SEQUENCE;
    SetLength(Reader.Documents, BATCHES * ROUNDS);
    for Index := 0 to High(Reader.Documents) do
      Reader.Documents[Index] :=
        SHA256BytesPrefixed(RaceDocument(Index)[0].Bytes);
    RaceReaderWaiting := 0;
    RegistryStateLeaseContendedTestHook := NoteRaceReaderWaiting;
    Reader.Start;
    Started := True;
    Failures := 0;
    Failure := '';
    Index := 0;
    for Batch := 1 to BATCHES do
    begin
      Lease := AwaitStateLease(Coordinator, RegistryStateLeaseKey(StatePath));
      try
        for Round := 1 to ROUNDS do
        begin
          try
            DocumentBytes := RaceDocument(Index)[0].Bytes;
            AtomicWriteBytes(RegistryStateDocumentPath(Root,
              Reader.Documents[Index]), Root + '/tmp', DocumentBytes);
            AtomicWriteBytes(StatePath, Root + '/tmp', StateBytes);
          except
            on E: Exception do
            begin
              Inc(Failures);
              Failure := E.Message;
            end;
          end;
          InterLockedIncrement(Reader.Completed);
          Inc(Index);
        end;
      finally
        Lease.Free;
      end;
      { A reader waiting for the lease polls every
        PRODUCER_LEASE_POLL_MILLISECONDS; let it in before the next batch so
        it keeps reading during publication instead of only after it. }
      if InterLockedExchange(RaceReaderWaiting, 0) <> 0 then
        Sleep(3 * PRODUCER_LEASE_POLL_MILLISECONDS);
    end;
    InterLockedExchange(Reader.Done, 1);
    if not AwaitThreadFinished(Reader, RACE_WAIT_MILLISECONDS) then
      AbortTestProgram(Format('registry consumer race test: the reader '
        + 'thread did not finish within %d ms', [RACE_WAIT_MILLISECONDS]));
    RegistryStateLeaseContendedTestHook := nil;
    Expect<string>(Failure).ToBe('');
    Expect<Integer>(Failures).ToBe(0);
    Expect<string>(Reader.Failure).ToBe('');
    Expect<Integer>(Reader.Failures).ToBe(0);
    Expect<Integer>(Reader.Absences).ToBe(0);
    Expect<Integer>(Reader.WrongStates).ToBe(0);
    Expect<Integer>(Reader.MissedDocuments).ToBe(0);
    Expect<Boolean>(Reader.Reads > 0).ToBe(True);
  finally
    { An exception (a failed publication's lease wait included) can leave
      the reader running: stop it, starting one never started so that it
      sees Done and returns, since a suspended thread cannot finish. One
      that outlives the bound ends the program; see AbortTestProgram. }
    InterLockedExchange(Reader.Done, 1);
    if not Started then Reader.Start;
    if not AwaitThreadFinished(Reader, RACE_WAIT_MILLISECONDS) then
      AbortTestProgram(Format('registry consumer race test: the reader '
        + 'thread did not finish within %d ms after a failure',
        [RACE_WAIT_MILLISECONDS]));
    RegistryStateLeaseContendedTestHook := nil;
    Reader.Free;
    Coordinator.Free;
  end;
  Expect<Boolean>(LoadRegistryConsumerStateAt(Root, RACE_IDENTITY, FKeyID,
    Loaded)).ToBe(True);
  Expect<Int64>(Loaded.State.Sequence).ToBe(STATE_SEQUENCE);
end;

var
  { The publisher the contention hook completes: its lease, and the state
    file it has moved aside mid-replacement. }
  AbsencePublisherLease: TLWPTProducerLease = nil;
  AbsenceStatePath: string = '';
  AbsenceContentions: Integer = 0;

procedure CompleteReplacementOnContention(const AKey: string);
begin
  Inc(AbsenceContentions);
  if AbsencePublisherLease = nil then Exit;
  if not RenameFile(AbsenceStatePath + '.aside', AbsenceStatePath) then
    raise Exception.Create('fixture: could not restore the state file');
  FreeAndNil(AbsencePublisherLease);
end;

{ CR-1 of #372, deterministic: a publisher holds the per-origin lease and has
  moved the old state file aside, as ReplaceFileW does mid-replacement. A
  lease-free read must not take that moment for a fresh state directory,
  which would drop the per-user sequence prior and let an older, still
  valid checkpoint in. The read meets the publisher's lease, the contention
  hook completes the replacement on the reading thread, and the read then
  returns the stored sequence 9, which keeps a sequence 8 checkpoint stale
  against a lock that records only 3. A state that is really absent, with
  no publisher, reads as absent without waiting. The read runs on the test
  thread, and if the hook ever stopped releasing the lease it would fail
  with registry_state_locked after RegistryStateLeaseWaitMilliseconds. }
procedure TRegistryConsumerTests.TestAbsentStateIsReadUnderThePublisherLease;
var
  Root: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Loaded, Locked, Prior: TLWPTRegistryConsumerState;
  Found: Boolean;
begin
  Root := FScratch + '/state-absence';
  MergeRegistryConsumerStateAt(Root, RACE_IDENTITY, FKeyID,
    SequencedState(FKeyID, FPublicKey, 9), nil, nil);
  AbsenceStatePath := RegistryStatePathAt(Root, RACE_IDENTITY, FKeyID);
  AbsenceContentions := 0;
  Coordinator := TLWPTProducerLeaseCoordinator.Create(Root + '/locks');
  try
    AbsencePublisherLease := Coordinator.TryAcquire(
      RegistryStateLeaseKey(AbsenceStatePath), 'test publisher');
    Expect<Boolean>(AbsencePublisherLease <> nil).ToBe(True);
    Expect<Boolean>(RenameFile(AbsenceStatePath,
      AbsenceStatePath + '.aside')).ToBe(True);
    RegistryStateLeaseContendedTestHook := CompleteReplacementOnContention;
    try
      Found := LoadRegistryConsumerStateAt(Root, RACE_IDENTITY, FKeyID,
        Loaded);
    finally
      RegistryStateLeaseContendedTestHook := nil;
      if AbsencePublisherLease <> nil then
      begin
        RenameFile(AbsenceStatePath + '.aside', AbsenceStatePath);
        FreeAndNil(AbsencePublisherLease);
      end;
    end;
    Expect<Boolean>(Found).ToBe(True);
    Expect<Int64>(Loaded.State.Sequence).ToBe(9);
    Expect<Boolean>(AbsenceContentions > 0).ToBe(True);
    Locked := SequencedState(FKeyID, FPublicKey, 3);
    Prior := MergeRegistryAcceptedStates(Loaded, Locked);
    Expect<Int64>(Prior.State.Sequence).ToBe(9);
    { Another origin's state was never written: absent at once. }
    AbsenceContentions := 0;
    Expect<Boolean>(LoadRegistryConsumerStateAt(Root,
      'https://other.example.com', FKeyID, Loaded)).ToBe(False);
    Expect<Integer>(AbsenceContentions).ToBe(0);
  finally
    Coordinator.Free;
  end;
end;

{$IFDEF MSWINDOWS}
const
  DELETE_ACCESS_TEST = $00010000;

{ The handle a write-through rename keeps, with delete access, while the
  file it renamed is already visible. }
function HoldPublisherHandle(const APath: string): THandle;
begin
  Result := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)),
    DELETE_ACCESS_TEST or Windows.GENERIC_READ, Windows.FILE_SHARE_READ
      or Windows.FILE_SHARE_WRITE or Windows.FILE_SHARE_DELETE, nil,
    Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if Result = Windows.INVALID_HANDLE_VALUE then RaiseLastOSError;
end;

{ The deterministic half of the race above: with the publisher's handle
  held, the state file and a document both read. }
procedure TRegistryConsumerTests.TestStateReadsShareAPublisherDeleteHandle;
var
  Root, Hash: string;
  History: TLWPTRegistryDocumentArray;
  Loaded: TLWPTRegistryConsumerState;
  StateHandle, DocumentHandle: THandle;
  Bytes: TBytes;
begin
  Root := FScratch + '/state-read-delete-handle';
  History := RaceDocument(1);
  Hash := SHA256BytesPrefixed(History[0].Bytes);
  MergeRegistryConsumerStateAt(Root, RACE_IDENTITY, FKeyID,
    SequencedState(FKeyID, FPublicKey, 7), nil, History);
  StateHandle := HoldPublisherHandle(RegistryStatePathAt(Root, RACE_IDENTITY,
    FKeyID));
  try
    DocumentHandle := HoldPublisherHandle(RegistryStateDocumentPath(Root,
      Hash));
    try
      Expect<Boolean>(LoadRegistryConsumerStateAt(Root, RACE_IDENTITY, FKeyID,
        Loaded)).ToBe(True);
      Expect<Int64>(Loaded.State.Sequence).ToBe(7);
      Bytes := LoadRegistryStateDocument(Root, Hash);
      Expect<Integer>(Length(Bytes)).ToBe(Length(History[0].Bytes));
    finally
      Windows.CloseHandle(DocumentHandle);
    end;
  finally
    Windows.CloseHandle(StateHandle);
  end;
end;
{$ENDIF}

{ Run with RACE_ABORT_PROBE_ARGUMENT, the program installs an exit procedure
  and calls AbortTestProgram, as a race-test timeout does. Halt would run
  that exit procedure, then unit finalization; AbortTestProgram must end
  the process before either, with its exit code and its stderr line. }
procedure MarkExitProcedureRan;
begin
  WriteLn('exit procedure ran');
  Flush(Output);
end;

procedure RunRaceAbortProbe;
begin
  ExitProc := @MarkExitProcedureRan;
  AbortTestProgram('race abort probe');
  WriteLn('abort returned');
  Flush(Output);
end;

procedure TRegistryConsumerTests.TestTimeoutEndsTheProgramWithoutFinalization;
var
  Captured: string;
  Code: Integer;
begin
  Code := RunChildCommand('', ParamStr(0), [RACE_ABORT_PROBE_ARGUMENT],
    Captured);
  Expect<Integer>(Code).ToBe(RACE_ABORT_EXIT_CODE);
  Expect<Boolean>(Pos('FATAL: race abort probe; ending the test program '
    + 'without finalization', Captured) > 0).ToBe(True);
  Expect<Boolean>(Pos('exit procedure ran', Captured) > 0).ToBe(False);
  Expect<Boolean>(Pos('abort returned', Captured) > 0).ToBe(False);
end;

procedure TRegistryConsumerTests.SetupTests;
begin
  Test('registry sources parse in bare and inline-table forms',
    TestRegistrySourceForms);
  Test('a registry dependency key must equal its package name',
    TestDependencyKeyMustEqualPackage);
  Test('registry versions are SemVer ranges or exact versions without v',
    TestRegistryVersionsAreSemverWithoutV);
  Test('[registries] default selects the default alias',
    TestExplicitDefaultAlias);
  Test('exactly one declared registry is the implied default',
    TestSingleRegistryIsImplied);
  Test('two registries without a default fail with the alias hint',
    TestAmbiguousDefaultFails);
  Test('a registry dependency without any registry fails with the '
    + 'declaration hint', TestMissingRegistryFails);
  Test('an undeclared alias fails at load', TestUndeclaredAliasFails);
  Test('the alias default is reserved', TestReservedAliasRejected);
  Test('a pin that fails validation is rejected', TestInvalidPinRejected);
  Test('plain HTTP, non-canonical, and IPv6 contacts are rejected',
    TestInsecureAndMalformedContactsRejected);
  Test('duplicate contacts and one identity under two aliases are rejected',
    TestDuplicateContactsAndIdentitiesRejected);
  Test('an origin contact is required when identity is omitted',
    TestOriginRequiredWithoutIdentity);
  Test('unknown [registries.<alias>] fields are errors',
    TestUnknownRegistryFieldRejected);
  Test('[sources] cannot shadow the registry prefix',
    TestSourcesCannotShadowRegistry);
  Test('a dependency manifest keeps a lenient [registries] copy',
    TestDependencyManifestRegistriesAreLenient);
  Test('merged accepted state never lowers the sequence or the floor',
    TestAcceptedStateMergeIsMonotonic);
  Test('per-origin lock tables round-trip', TestLockTablesRoundTrip);
  Test('a locked selection verifies from the pin without history or expiry',
    TestLockedSelectionVerifiesWithoutHistory);
  Test('a tampered locked selection fails verification',
    TestLockedSelectionRejectsTampering);
  Test('a locked selection with a well-formed but invalid signature fails',
    TestLockedSelectionRequiresValidSignature);
  Test('concurrent per-user state merges keep the highest sequence and floor',
    TestConcurrentStateMergesAreMonotonic);
  Test('locked selection proofs load within count and byte limits, refuse '
    + 'repeats, and never read around a corrupt committed document',
    TestLockedSelectionLoadingIsBounded);
  Test('rotation chains load within count and byte limits and refuse repeats',
    TestRotationChainLoadingIsBounded);
  Test('per-user state and documents read while another install publishes '
    + 'them', TestStateReadsDuringConcurrentPublication);
  Test('a state file a publisher has moved aside is read under its lease, '
    + 'never as fresh state', TestAbsentStateIsReadUnderThePublisherLease);
  Test('a race-test timeout ends the program without exit procedures or '
    + 'finalization', TestTimeoutEndsTheProgramWithoutFinalization);
  {$IFDEF MSWINDOWS}
  Test('per-user state and documents read beside a publisher holding '
    + 'delete access', TestStateReadsShareAPublisherDeleteHandle);
  {$ENDIF}
end;

begin
  if (ParamCount = 1) and (ParamStr(1) = RACE_ABORT_PROBE_ARGUMENT) then
  begin
    RunRaceAbortProbe;
    Halt(1);
  end;
  TestRunnerProgram.AddSuite(TRegistryConsumerTests.Create(
    'registry consumer: manifest, state, and locked selection'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
