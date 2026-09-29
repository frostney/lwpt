program LWPT.Registry.Consumer.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Manifest,
  LWPT.Registry.Consumer,
  LWPT.Registry.Verification,
  TestingPascalLibrary,
  Tests.RegistryConsumer,
  Tests.Scratch;

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
  end;

  TMergeThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Root, Identity, KeyId, PublicKey, Error: string;
    Sequence: Integer;
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
    Lines.Add('version = 3');
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
      SHA256BytesPrefixed(Selection.Checkpoint));
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
    const ATrust: TLWPTRegistryTrust; const AHash: string): string;
  begin
    Result := '';
    try
      VerifyRegistryLockedSelection(ASelection, ATrust, AHash);
    except
      on E: Exception do Result := E.Message;
    end;
  end;

begin
  Synthetic := TSyntheticRegistry.Create('https://packages.example.com');
  Other := TSyntheticRegistry.Create('https://packages.example.com', 9);
  try
    Synthetic.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    Index := Synthetic.Publish(RegistryStamp(-60), RegistryStamp(86400));
    Selection := SelectionOf(Synthetic, Index, Synthetic.RecordHash('json', '1.0.0'));
    { The recorded checkpoint hash must name these bytes. }
    Message := Failure(Selection, TrustOf(Synthetic), 'sha256:' + StringOfChar('0', 64));
    Expect<Boolean>(Pos('locked_proof_state_mismatch', Message) > 0).ToBe(True);
    { A different pin cannot verify the signature. }
    Message := Failure(Selection, TrustOf(Other),
      SHA256BytesPrefixed(Selection.Checkpoint));
    Expect<Boolean>(Message <> '').ToBe(True);
    { A record outside the signed snapshot is not a member. }
    Tampered := Selection;
    Tampered.Records[0] := Copy(Selection.Records[0]);
    Tampered.Records[0][Length(Tampered.Records[0]) - 3] := Ord('X');
    Message := Failure(Tampered, TrustOf(Synthetic),
      SHA256BytesPrefixed(Selection.Checkpoint));
    Expect<Boolean>(Pos('registry_record_not_in_snapshot', Message) > 0).ToBe(True);
    { A snapshot that is not the checkpoint's fails. }
    Tampered := Selection;
    Tampered.Snapshot := Copy(Selection.Snapshot);
    Tampered.Snapshot[10] := Ord('X');
    Message := Failure(Tampered, TrustOf(Synthetic),
      SHA256BytesPrefixed(Selection.Checkpoint));
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
        SHA256BytesPrefixed(Selection.Checkpoint));
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
  Test('rotation chains load within count and byte limits and refuse repeats',
    TestRotationChainLoadingIsBounded);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryConsumerTests.Create(
    'registry consumer: manifest, state, and locked selection'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
