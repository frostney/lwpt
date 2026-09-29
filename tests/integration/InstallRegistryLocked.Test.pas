{ InstallRegistryLocked.Test -- network-free registry installs (ADR-0051).

  `install --frozen` and `install --offline` with registry dependencies, the
  registry half of issue #226. Every case drives the test-flavoured binary
  with a transport journal (LWPT_TEST_REGISTRY_TRANSPORT_LOG): the registry
  client unit appends a line whenever a client is constructed or a request
  attempted, so "no network" is proven at the transport boundary. Contacts
  also fail every request while a network-free mode runs. Failure cases
  compare the lock, the cfg, the modules and archives trees (including the
  committed proof documents), and the whole per-user state directory before
  and after. }
program InstallRegistryLocked.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.LockSchema,
  Tests.LwptSubprocess,
  Tests.RegistryConsumer,
  Tests.Scratch,
  Tests.TarSynth;

const
  DAY = 24 * 60 * 60;
  IDENTITY = 'https://packages.example.com';
  PROOFS = '/project/.lwpt/archives/registry-proofs/sha256/';

type
  TMutation = procedure(const ACase: string) of object;

  TInstallRegistryLocked = class(TTestSuite)
  private
    FScratch, FCurrentCase, FBaseline: string;
    FCount: Integer;
    FRegistry: TSyntheticRegistry;
    FOrigin: TSyntheticContact;
    function NewCase(const AName: string): string;
    function Clone(const ASource, AName: string): string;
    procedure WriteProject(const ACase, ARegistries, ADependencies: string);
    function Declaration(ARegistry: TSyntheticRegistry;
      const AWithIdentity: Boolean = True): string;
    function Run(const ACase: string;
      const AArguments: array of string): TLwptResult;
    function RunWith(const ACase: string;
      const AArguments, AEnvironment: array of string): TLwptResult;
    { Points AVictim's lock entry, archive, and module at ASource's record,
      archive, and tree, updating every unsigned hash to match. }
    procedure Substitute(const ACase, AVictim, ASource: string);
    function SubstitutionCase(const AName: string;
      out AOther: TSyntheticRegistry; out AOtherOrigin: TSyntheticContact): string;
    procedure SetArchivesReadOnly(const ACase: string; const AReadOnly: Boolean);
    function Journal(const ACase: string): string;
    function Fingerprint(const ACase: string): string;
    function ProjectFingerprint(const ACase: string): string;
    function LockText(const ACase: string): string;
    procedure EditLock(const ACase, AOld, ANew: string);
    function TableField(const ACase, AKey: string): string;
    procedure ExpectSuccess(const ALabel: string; const ARun: TLwptResult);
    procedure ExpectFailure(const ARun: TLwptResult; const AText: string);
    procedure ExpectNetworkFree(const ACase: string; const ARequests: Integer);
    procedure DumpCase(const ALabel: string);
    { Installs json (which requires util through its signed record) and a
      filtered util online, then keeps that project as the drift baseline. }
    function Baseline: string;
    procedure RunDrift(const AName: string; AMutation: TMutation;
      const AExpected: string; const AOffline: Boolean = False);
    procedure ForgeSignature(const ACase: string);
    procedure CoordinatedTamper(const ACase: string);
    procedure FlipArchive(const ACase: string);
    procedure EditModule(const ACase: string);
    procedure EditRecord(const ACase: string);
    procedure EditCheckpoint(const ACase: string);
    procedure EditSequence(const ACase: string);
    procedure EditTrustKey(const ACase: string);
    procedure FlipProof(const ACase: string);
    procedure DeleteProof(const ACase: string);
    procedure ChangePin(const ACase: string);
    procedure SchemaTwo(const ACase: string);
    procedure ChangeRange(const ACase: string);
    procedure ChangeIdentity(const ACase: string);
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestJournalRecordsOnlineTransport;
    procedure TestFrozenCloneIsNetworkFree;
    procedure TestFrozenIdentityFromLock;
    procedure TestFrozenArchiveFlipFails;
    procedure TestFrozenModuleEditFails;
    procedure TestFrozenRecordEditFails;
    procedure TestFrozenCheckpointEditFails;
    procedure TestFrozenSequenceEditFails;
    procedure TestFrozenTrustKeyEditFails;
    procedure TestFrozenProofFlipFails;
    procedure TestFrozenProofDeletionFails;
    procedure TestFrozenPinChangeFails;
    procedure TestFrozenSchemaTwoFails;
    procedure TestFrozenCoordinatedTamperFails;
    procedure TestFrozenForgedSignatureFails;
    procedure TestExpiredProofStillVerifies;
    procedure TestOfflineFromSharedCacheOnly;
    procedure TestOfflineFromCommittedArchivesOnly;
    procedure TestOfflineReconstructsModulesCfgAndProofs;
    procedure TestOfflineMissFailsWithoutChange;
    procedure TestOfflineCorruptionIsNotReadAround;
    procedure TestOfflineRangeDriftFails;
    procedure TestOfflineIdentityDriftFails;
    procedure TestOfflinePinChangeFails;
    procedure TestOfflineCoordinatedTamperFails;
    procedure TestOfflineForgedSignatureFails;
    procedure TestRecordSubstitutionSameOriginFails;
    procedure TestRecordSubstitutionAcrossOriginsFails;
    procedure TestLayoutSubstitutionWithEqualTreeHashFails;
    procedure TestRegistryV3LockIsRefusedEverywhere;
    procedure TestRegistryRepairUpgradesWithoutNetwork;
    procedure TestRegistryRepairReplacesForgedTree;
    procedure TestRegistryRepairNeedsItsProofs;
    procedure TestRegistryRepairRecordsMergedAcceptedState;
    procedure TestRegistryRepairBoundsProofDocuments;
    procedure TestFrozenLeavesArchiveStorageUntouched;
    procedure TestRepeatedRotationHashesAreRefused;
    procedure TestRotationCountIsBoundedBeforeReading;
  end;

function ReadText(const APath: string): string;
begin
  if not FileExists(APath) then Exit('');
  Result := ReadBinaryFile(APath);
end;

function TreeFingerprint(const APath: string): string;
begin
  if DirectoryExists(APath) then Result := HashTree(APath)
  else Result := 'absent';
end;

{ The value of AField in the [package.<AName>] entry of a lock. }
function EntryField(const ALock, AName, AField: string): string;
var Rest: string; Start: Integer;
begin
  Result := '';
  Rest := StringReplace(ALock, #13#10, #10, [rfReplaceAll]);
  Start := Pos('[package.' + AName + ']'#10, Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start, MaxInt);
  Start := Pos(#10 + AField + ' = "', Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start + Length(AField) + 5, MaxInt);
  Result := Copy(Rest, 1, Pos('"', Rest) - 1);
end;

procedure CopyTree(const ASource, ATarget: string);
var Entry: TSearchRec;
begin
  ForceDirectories(ATarget);
  if FindFirst(ASource + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
      if (Entry.Attr and faDirectory) <> 0 then
        CopyTree(ASource + '/' + Entry.Name, ATarget + '/' + Entry.Name)
      else if not CopyFileContent(ASource + '/' + Entry.Name,
           ATarget + '/' + Entry.Name) then
        raise Exception.Create('cannot copy ' + ASource + '/' + Entry.Name);
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

{ The first file below ARoot whose path ends with ASuffix, or ''. }
function FindFileEndingWith(const ARoot, ASuffix: string): string;
var Entry: TSearchRec; Path: string;
begin
  Result := '';
  if FindFirst(ARoot + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
      Path := ARoot + '/' + Entry.Name;
      if (Entry.Attr and faDirectory) <> 0 then
        Result := FindFileEndingWith(Path, ASuffix)
      else if Copy(Path, Length(Path) - Length(ASuffix) + 1, MaxInt)
          = ASuffix then
        Result := Path;
      if Result <> '' then Exit;
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

{ Flips one byte in the middle of APath, writing the exact bytes back. }
procedure FlipByte(const APath: string);
var Text: string; Bytes: TBytes;
begin
  Text := ReadBinaryFile(APath);
  Bytes := BytesOf(Text);
  Bytes[Length(Bytes) div 2] := Bytes[Length(Bytes) div 2] xor $01;
  WriteBytesToFile(APath, Bytes);
end;

function DirectoryIsEmpty(const APath: string): Boolean;
var Entry: TSearchRec;
begin
  Result := True;
  if FindFirst(APath + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name <> '.') and (Entry.Name <> '..') then Exit(False);
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

function TmpHasFrozenScratch(const AProject: string): Boolean;
var Entry: TSearchRec;
begin
  Result := False;
  if FindFirst(AProject + '/.lwpt/tmp/fz*', faAnyFile, Entry) <> 0 then Exit;
  FindClose(Entry);
  Result := True;
end;

procedure TInstallRegistryLocked.BeforeAll;
begin
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('reg-locked');
  FRegistry := TSyntheticRegistry.Create(IDENTITY);
  FOrigin := TSyntheticContact.Create(FRegistry, '/origin');
  FRegistry.AddPackage('util', '1.0.0', RegistryPackageArchive('util', '1.0.0'), []);
  FRegistry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'),
    ['util@^1.0.0']);
  FRegistry.AddPackage('json', '2.0.0', RegistryPackageArchive('json', '2.0.0'), []);
  FRegistry.AddPackage('extras', '1.0.0', RegistryPackageArchive('extras', '1.0.0'),
    []);
  FRegistry.AddPackage('misc', '1.0.0', RegistryPackageArchive('misc', '1.0.0'), []);
  FRegistry.Publish(RegistryStamp(-120), RegistryStamp(6 * DAY));
  FBaseline := '';
end;

procedure TInstallRegistryLocked.AfterAll;
begin
  FOrigin.Free;
  FRegistry.Free;
  RecursiveDelete(FScratch);
end;

function TInstallRegistryLocked.NewCase(const AName: string): string;
begin
  Inc(FCount);
  { Short names keep the deepest transaction and scratch paths inside the
    legacy Windows MAX_PATH; the case name is kept in a file. }
  Result := FScratch + '/c' + IntToStr(FCount);
  FCurrentCase := Result;
  { A failed expectation ends a case early; the shared origin serves again. }
  FOrigin.Mode := scmServe;
  ForceDirectories(Result + '/project/source');
  ForceDirectories(Result + '/state');
  ForceDirectories(Result + '/cache');
  WriteTextFile(Result + '/CASE', AName + #10);
  WriteTextFile(Result + '/project/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
end;

{ A fresh checkout of ASource's project with empty per-user state and an
  empty cache. }
function TInstallRegistryLocked.Clone(const ASource, AName: string): string;
begin
  Result := NewCase(AName);
  CopyTree(ASource + '/project', Result + '/project');
end;

procedure TInstallRegistryLocked.WriteProject(const ACase, ARegistries,
  ADependencies: string);
begin
  WriteTextFile(ACase + '/project/lwpt.toml', '[package]'#10
    + 'name = "consumer"'#10 + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + ARegistries + '[dependencies]'#10 + ADependencies);
end;

function TInstallRegistryLocked.Declaration(ARegistry: TSyntheticRegistry;
  const AWithIdentity: Boolean): string;
begin
  Result := '[registries.corp]'#10;
  if AWithIdentity then
    Result := Result + 'identity = "' + ARegistry.Identity + '"'#10;
  Result := Result + 'key-id = "' + ARegistry.KeyID + '"'#10
    + 'public-key = "' + ARegistry.PublicKey + '"'#10
    + 'origin = "' + FOrigin.BaseURL + '"'#10;
end;

function TInstallRegistryLocked.RunWith(const ACase: string;
  const AArguments, AEnvironment: array of string): TLwptResult;
var Environment: array of string; Index: Integer;
begin
  SetLength(Environment, 3 + Length(AEnvironment));
  Environment[0] := PROJECT_NAME + '_REGISTRY_STATE_DIR=' + ACase + '/state';
  Environment[1] := PROJECT_NAME + '_CACHE_DIR=' + ACase + '/cache';
  Environment[2] := PROJECT_NAME + '_TEST_REGISTRY_TRANSPORT_LOG=' + ACase
    + '/transport.log';
  for Index := 0 to High(AEnvironment) do
    Environment[3 + Index] := AEnvironment[Index];
  Result := RunLwptTesting(AArguments, ACase + '/project', Environment);
end;

function TInstallRegistryLocked.Run(const ACase: string;
  const AArguments: array of string): TLwptResult;
begin
  Result := RunLwptTesting(AArguments, ACase + '/project',
    [PROJECT_NAME + '_REGISTRY_STATE_DIR=' + ACase + '/state',
     PROJECT_NAME + '_CACHE_DIR=' + ACase + '/cache',
     PROJECT_NAME + '_TEST_REGISTRY_TRANSPORT_LOG=' + ACase + '/transport.log']);
end;

function TInstallRegistryLocked.Journal(const ACase: string): string;
begin
  Result := ReadText(ACase + '/transport.log');
end;

function TInstallRegistryLocked.ProjectFingerprint(const ACase: string): string;
begin
  Result := SHA256Hex(BytesOf(ReadText(ACase + '/project/lwpt.lock')))
    + '|' + SHA256Hex(BytesOf(ReadText(ACase + '/project/lwpt.cfg')))
    + '|' + TreeFingerprint(ACase + '/project/.lwpt/modules')
    + '|' + TreeFingerprint(ACase + '/project/.lwpt/archives');
end;

{ The project and the whole per-user registry state directory. The archive
  cache is shared, self-verifying storage whose own housekeeping (creating
  its layout, quarantining a corrupt object) is not project state. }
function TInstallRegistryLocked.Fingerprint(const ACase: string): string;
begin
  Result := ProjectFingerprint(ACase) + '|' + TreeFingerprint(ACase + '/state');
end;

function TInstallRegistryLocked.LockText(const ACase: string): string;
begin
  Result := ReadText(ACase + '/project/lwpt.lock');
end;

procedure TInstallRegistryLocked.EditLock(const ACase, AOld, ANew: string);
var Lock: string;
begin
  Lock := LockText(ACase);
  Expect<Boolean>(Pos(AOld, Lock) > 0).ToBe(True);
  WriteBytesToFile(ACase + '/project/lwpt.lock',
    BytesOf(StringReplace(Lock, AOld, ANew, [])));
end;

{ The value of AKey in the lock's [registry."<identity>"] table. }
function TInstallRegistryLocked.TableField(const ACase, AKey: string): string;
var Rest: string; Start: Integer;
begin
  Rest := LockText(ACase);
  Start := Pos(#10 + AKey + ' = "', Rest);
  if Start = 0 then Exit('');
  Rest := Copy(Rest, Start + Length(AKey) + 5, MaxInt);
  Result := Copy(Rest, 1, Pos('"', Rest) - 1);
end;

procedure TInstallRegistryLocked.DumpCase(const ALabel: string);
begin
  WriteLn('--- ', ALabel, ': case ', FCurrentCase, ' (',
    Trim(ReadText(FCurrentCase + '/CASE')), ') ---');
  WriteLn('  transport journal: ', Journal(FCurrentCase));
end;

procedure TInstallRegistryLocked.ExpectSuccess(const ALabel: string;
  const ARun: TLwptResult);
begin
  if ARun.ExitCode <> 0 then
  begin
    WriteLn('--- ', ALabel, ' ---'#10, ARun.Stdout, ARun.Stderr, '---');
    DumpCase(ALabel);
  end;
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

procedure TInstallRegistryLocked.ExpectFailure(const ARun: TLwptResult;
  const AText: string);
var Output: string;
begin
  Output := ARun.Stdout + ARun.Stderr;
  if (ARun.ExitCode = 0) or (Pos(AText, Output) = 0) then
  begin
    WriteLn('--- expected failure containing "', AText, '" ---'#10, Output,
      '---');
    DumpCase('expected failure');
  end;
  Expect<Boolean>(ARun.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos(AText, Output) > 0).ToBe(True);
end;

{ No registry client was constructed and no request attempted, and the
  contact saw nothing. }
procedure TInstallRegistryLocked.ExpectNetworkFree(const ACase: string;
  const ARequests: Integer);
begin
  if Journal(ACase) <> '' then DumpCase('network use');
  Expect<string>(Journal(ACase)).ToBe('');
  Expect<Integer>(FOrigin.Requests).ToBe(ARequests);
end;

function TInstallRegistryLocked.Baseline: string;
begin
  if FBaseline <> '' then Exit(FBaseline);
  FBaseline := NewCase('baseline');
  ForceDirectories(FBaseline + '/project/vendor/local/source');
  WriteTextFile(FBaseline + '/project/vendor/local/lwpt.toml', '[package]'#10
    + 'name = "local"'#10 + 'version = "1.0.0"'#10 + 'units = ["source"]'#10);
  WriteTextFile(FBaseline + '/project/vendor/local/source/local.pas',
    'unit local;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
  { extras carries an extraction policy: frozen must re-derive it filtered. }
  WriteProject(FBaseline, Declaration(FRegistry),
    'json = "registry:corp/json@^1.0.0"'#10
    + 'extras = { source = "registry:extras", version = "^1.0.0", '
    + 'exclude = ["lwpt.toml"] }'#10
    + 'local = "./vendor/local"'#10);
  FOrigin.Mode := scmServe;
  ExpectSuccess('baseline install', Run(FBaseline, ['install']));
  Result := FBaseline;
end;

{ ---------------------------------------------------------------------------
  The transport journal and --frozen
  --------------------------------------------------------------------------- }

procedure TInstallRegistryLocked.TestJournalRecordsOnlineTransport;
var CaseRoot: string;
begin
  { The seam is live: an online install journals its client and requests,
    so an empty journal below is evidence, not an unwired hook. }
  CaseRoot := Baseline;
  Expect<Boolean>(Pos('client', Journal(CaseRoot)) > 0).ToBe(True);
  Expect<Boolean>(Pos('request ' + FOrigin.BaseURL, Journal(CaseRoot)) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('source = "registry:util"', LockText(CaseRoot)) > 0)
    .ToBe(True);
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/modules/extras/source/extras.pas')).ToBe(True);
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/modules/extras/lwpt.toml')).ToBe(False);
end;

procedure TInstallRegistryLocked.TestFrozenCloneIsNetworkFree;
var CaseRoot, Before: string; Requests: Integer;
begin
  CaseRoot := Clone(Baseline, 'frozen-clone');
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  ExpectSuccess('frozen clone', Run(CaseRoot, ['install', '--frozen']));
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  { The re-derivation scratch below .lwpt/tmp is removed on exit. }
  Expect<Boolean>(TmpHasFrozenScratch(CaseRoot + '/project')).ToBe(False);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestFrozenIdentityFromLock;
var CaseRoot: string; Requests: Integer;
begin
  { A declaration without identity takes the one the lock recorded. }
  CaseRoot := NewCase('frozen-advertised');
  WriteProject(CaseRoot, Declaration(FRegistry, False),
    'json = "registry:json@^1.0.0"'#10);
  ExpectSuccess('advertised install', Run(CaseRoot, ['install']));
  DeleteFile(CaseRoot + '/transport.log');
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  ExpectSuccess('advertised frozen', Run(CaseRoot, ['install', '--frozen']));
  RecursiveDelete(CaseRoot + '/project/.lwpt/modules');
  ExpectSuccess('advertised offline', Run(CaseRoot, ['install', '--offline']));
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/modules/json/source/json.pas')).ToBe(True);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.RunDrift(const AName: string;
  AMutation: TMutation; const AExpected: string; const AOffline: Boolean);
var CaseRoot, Before: string; Requests: Integer;
begin
  CaseRoot := Clone(Baseline, AName);
  AMutation(CaseRoot);
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  if AOffline then
    ExpectFailure(Run(CaseRoot, ['install', '--offline']), AExpected)
  else
    ExpectFailure(Run(CaseRoot, ['install', '--frozen']), AExpected);
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.FlipArchive(const ACase: string);
begin
  FlipByte(ACase + '/project/.lwpt/archives/json-1.0.0.tar.gz');
end;

procedure TInstallRegistryLocked.EditModule(const ACase: string);
begin
  WriteTextFile(ACase + '/project/.lwpt/modules/json/source/json.pas',
    'unit json;'#10 + 'interface'#10 + 'implementation'#10 + 'end.'#10);
end;

procedure TInstallRegistryLocked.EditRecord(const ACase: string);
begin
  EditLock(ACase, 'registryRecord = "' + FRegistry.RecordHash('json', '1.0.0'),
    'registryRecord = "' + FRegistry.RecordHash('json', '2.0.0'));
end;

procedure TInstallRegistryLocked.EditCheckpoint(const ACase: string);
begin
  EditLock(ACase, 'checkpoint = "' + TableField(ACase, 'checkpoint'),
    'checkpoint = "sha256:' + StringOfChar('a', 64));
end;

procedure TInstallRegistryLocked.EditSequence(const ACase: string);
begin
  EditLock(ACase, #10'sequence = 1', #10'sequence = 7');
end;

procedure TInstallRegistryLocked.EditTrustKey(const ACase: string);
begin
  EditLock(ACase, 'trustKeyId = "' + FRegistry.KeyID,
    'trustKeyId = "ed25519:' + StringOfChar('b', 64));
end;

procedure TInstallRegistryLocked.FlipProof(const ACase: string);
begin
  FlipByte(ACase + PROOFS + Copy(FRegistry.RecordHash('json', '1.0.0'), 8, 64)
    + '.toml');
end;

procedure TInstallRegistryLocked.DeleteProof(const ACase: string);
begin
  Expect<Boolean>(DeleteFile(ACase + PROOFS
    + Copy(TableField(ACase, 'snapshot'), 8, 64) + '.toml')).ToBe(True);
end;

procedure TInstallRegistryLocked.ChangePin(const ACase: string);
var Other: TSyntheticRegistry; Manifest: string;
begin
  { Another key with the same identity: a human re-pin. }
  Other := TSyntheticRegistry.Create(IDENTITY, 9);
  try
    Manifest := ReadText(ACase + '/project/lwpt.toml');
    Manifest := StringReplace(Manifest, FRegistry.KeyID, Other.KeyID, []);
    Manifest := StringReplace(Manifest, FRegistry.PublicKey, Other.PublicKey, []);
    WriteBytesToFile(ACase + '/project/lwpt.toml', BytesOf(Manifest));
  finally
    Other.Free;
  end;
end;

procedure TInstallRegistryLocked.SchemaTwo(const ACase: string);
begin
  EditLock(ACase, 'version = 4', 'version = 2');
end;

procedure TInstallRegistryLocked.ChangeRange(const ACase: string);
var Manifest: string;
begin
  Manifest := ReadText(ACase + '/project/lwpt.toml');
  WriteBytesToFile(ACase + '/project/lwpt.toml', BytesOf(StringReplace(
    Manifest, 'registry:corp/json@^1.0.0', 'registry:corp/json@^2.0.0', [])));
end;

procedure TInstallRegistryLocked.ChangeIdentity(const ACase: string);
var Manifest: string;
begin
  Manifest := ReadText(ACase + '/project/lwpt.toml');
  WriteBytesToFile(ACase + '/project/lwpt.toml', BytesOf(StringReplace(
    Manifest, 'identity = "' + IDENTITY + '"',
    'identity = "https://moved.example.com"', [])));
end;

{ Replaces the committed signature envelope with a canonical one whose key id
  and payload hash are right but whose signature is not, keeping the proof
  file name and the lock's hash consistent with the forged bytes. }
procedure TInstallRegistryLocked.ForgeSignature(const ACase: string);
var OldHash, NewHash, Text: string; Bytes: TBytes; Position: Integer;
begin
  OldHash := TableField(ACase, 'signature');
  Text := ReadText(ACase + PROOFS + Copy(OldHash, 8, 64) + '.toml');
  Position := Pos('signature = "hex:', Text) + Length('signature = "hex:') + 20;
  if Text[Position] = '0' then Text[Position] := '1' else Text[Position] := '0';
  Bytes := BytesOf(Text);
  NewHash := SHA256BytesPrefixed(Bytes);
  DeleteFile(ACase + PROOFS + Copy(OldHash, 8, 64) + '.toml');
  WriteBytesToFile(ACase + PROOFS + Copy(NewHash, 8, 64) + '.toml', Bytes);
  EditLock(ACase, 'signature = "' + OldHash, 'signature = "' + NewHash);
end;

{ Edits a unit of the installed module and recomputes computedHash to match,
  as a pull request could: only the proof-authenticated archive shows it. }
procedure TInstallRegistryLocked.CoordinatedTamper(const ACase: string);
var Lock, OldHash: string;
begin
  EditModule(ACase);
  Lock := LockText(ACase);
  OldHash := EntryField(Lock, 'json', 'computedHash');
  Expect<Boolean>(OldHash <> '').ToBe(True);
  EditLock(ACase, 'computedHash = "' + OldHash, 'computedHash = "'
    + HashTree(ACase + '/project/.lwpt/modules/json'));
end;

procedure TInstallRegistryLocked.TestFrozenArchiveFlipFails;
begin
  RunDrift('frozen-archive', FlipArchive, 'archive hash mismatch');
end;

procedure TInstallRegistryLocked.TestFrozenModuleEditFails;
begin
  RunDrift('frozen-module', EditModule, 'tree hash mismatch');
end;

procedure TInstallRegistryLocked.TestFrozenRecordEditFails;
begin
  RunDrift('frozen-record', EditRecord, 'registry_proof_missing');
end;

procedure TInstallRegistryLocked.TestFrozenCheckpointEditFails;
begin
  RunDrift('frozen-checkpoint', EditCheckpoint, 'registry_proof_missing');
end;

procedure TInstallRegistryLocked.TestFrozenSequenceEditFails;
begin
  RunDrift('frozen-sequence', EditSequence, 'locked_proof_state_mismatch');
end;

procedure TInstallRegistryLocked.TestFrozenTrustKeyEditFails;
begin
  RunDrift('frozen-trust-key', EditTrustKey, 'trust pin for ' + IDENTITY
    + ' changed');
end;

procedure TInstallRegistryLocked.TestFrozenProofFlipFails;
begin
  RunDrift('frozen-proof-flip', FlipProof, 'registry_proof_corrupt');
end;

procedure TInstallRegistryLocked.TestFrozenProofDeletionFails;
begin
  RunDrift('frozen-proof-delete', DeleteProof, 'registry_proof_missing');
end;

procedure TInstallRegistryLocked.TestFrozenPinChangeFails;
begin
  RunDrift('frozen-pin', ChangePin, 'trust pin for ' + IDENTITY + ' changed');
end;

procedure TInstallRegistryLocked.TestFrozenSchemaTwoFails;
begin
  RunDrift('frozen-schema', SchemaTwo, 'schema v2');
end;

procedure TInstallRegistryLocked.TestFrozenCoordinatedTamperFails;
begin
  RunDrift('frozen-coordinated', CoordinatedTamper,
    'differs from the tree re-derived from its proof-authenticated archive');
end;

procedure TInstallRegistryLocked.TestFrozenForgedSignatureFails;
begin
  RunDrift('frozen-forged', ForgeSignature, 'signature_invalid');
end;

procedure TInstallRegistryLocked.TestExpiredProofStillVerifies;
var
  Registry: TSyntheticRegistry;
  Origin: TSyntheticContact;
  CaseRoot, ExpiresAt: string;
  Run: TLwptResult;
begin
  { A checkpoint that expires moments after the install: --frozen and
    --offline apply no expiry and report it for information only. }
  CaseRoot := NewCase('expired');
  Registry := TSyntheticRegistry.Create(IDENTITY, 11);
  Origin := TSyntheticContact.Create(Registry, '/short');
  try
    Registry.AddPackage('json', '1.0.0', RegistryPackageArchive('json', '1.0.0'), []);
    ExpiresAt := RegistryStamp(15);
    Registry.Publish(RegistryStamp(-60), ExpiresAt);
    WriteTextFile(CaseRoot + '/project/lwpt.toml', '[package]'#10
      + 'name = "consumer"'#10 + 'version = "1.0.0"'#10
      + 'units = ["source"]'#10 + '[registries.corp]'#10
      + 'identity = "' + IDENTITY + '"'#10
      + 'key-id = "' + Registry.KeyID + '"'#10
      + 'public-key = "' + Registry.PublicKey + '"'#10
      + 'origin = "' + Origin.BaseURL + '"'#10
      + '[dependencies]'#10 + 'json = "registry:json"'#10);
    ExpectSuccess('expiring install', Self.Run(CaseRoot, ['install']));
    DeleteFile(CaseRoot + '/transport.log');
    Origin.Mode := scmFail;
    while RegistryStamp(0) <= ExpiresAt do Sleep(250);
    Run := Self.Run(CaseRoot, ['install', '--frozen']);
    ExpectSuccess('expired frozen', Run);
    Expect<Boolean>(Pos('expired at ' + ExpiresAt, Run.Stdout + Run.Stderr) > 0)
      .ToBe(True);
    RecursiveDelete(CaseRoot + '/project/.lwpt/modules');
    ExpectSuccess('expired offline', Self.Run(CaseRoot, ['install', '--offline']));
    Expect<string>(Journal(CaseRoot)).ToBe('');
  finally
    Origin.Free;
    Registry.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  --offline (#226)
  --------------------------------------------------------------------------- }

procedure TInstallRegistryLocked.TestOfflineFromSharedCacheOnly;
var CaseRoot, Lock: string; Requests: Integer; Run: TLwptResult;
begin
  CaseRoot := NewCase('offline-cas');
  WriteProject(CaseRoot, Declaration(FRegistry), 'json = "registry:json@^1.0.0"'#10);
  ExpectSuccess('cas seed', Self.Run(CaseRoot, ['install']));
  Lock := LockText(CaseRoot);
  DeleteFile(CaseRoot + '/transport.log');
  { Only the per-user CAS holds the archives now. }
  Expect<Boolean>(DeleteFile(CaseRoot
    + '/project/.lwpt/archives/json-1.0.0.tar.gz')).ToBe(True);
  Expect<Boolean>(DeleteFile(CaseRoot
    + '/project/.lwpt/archives/util-1.0.0.tar.gz')).ToBe(True);
  RecursiveDelete(CaseRoot + '/project/.lwpt/modules');
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  Run := Self.Run(CaseRoot, ['install', '--offline']);
  ExpectSuccess('offline from cas', Run);
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<Boolean>(Pos('reused verified archive for json from the per-user '
    + 'cache', Run.Stdout) > 0).ToBe(True);
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/archives/json-1.0.0.tar.gz')).ToBe(True);
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/modules/util/source/util.pas')).ToBe(True);
  Expect<string>(LockText(CaseRoot)).ToBe(Lock);
  ExpectSuccess('frozen after cas restore',
    Self.Run(CaseRoot, ['install', '--frozen']));
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestOfflineFromCommittedArchivesOnly;
var CaseRoot, Lock: string; Requests: Integer; Run: TLwptResult;
begin
  { A fresh checkout: empty cache and per-user state. }
  CaseRoot := Clone(Baseline, 'offline-committed');
  Lock := LockText(CaseRoot);
  RecursiveDelete(CaseRoot + '/project/.lwpt/modules');
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  Run := Self.Run(CaseRoot, ['install', '--offline']);
  ExpectSuccess('offline from committed archives', Run);
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<Boolean>(Pos('reused committed archive for json', Run.Stdout) > 0)
    .ToBe(True);
  Expect<string>(LockText(CaseRoot)).ToBe(Lock);
  Expect<string>(TreeFingerprint(CaseRoot + '/project/.lwpt/modules'))
    .ToBe(TreeFingerprint(Baseline + '/project/.lwpt/modules'));
  { The filtered module is re-extracted under its declared policy. }
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/modules/extras/lwpt.toml')).ToBe(False);
  { Nothing was written to per-user state or the cache. }
  Expect<Boolean>(DirectoryIsEmpty(CaseRoot + '/state')).ToBe(True);
  Expect<Boolean>(DirectoryIsEmpty(CaseRoot + '/cache')).ToBe(True);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestOfflineReconstructsModulesCfgAndProofs;
var
  CaseRoot, Lock, RecordPath, CheckpointPath, RecordBytes,
    CheckpointBytes, Cfg: string;
  Requests: Integer;
begin
  CaseRoot := NewCase('offline-rebuild');
  WriteProject(CaseRoot, Declaration(FRegistry), 'json = "registry:json@^1.0.0"'#10);
  ExpectSuccess('rebuild seed', Run(CaseRoot, ['install']));
  DeleteFile(CaseRoot + '/transport.log');
  Lock := LockText(CaseRoot);
  Cfg := ReadText(CaseRoot + '/project/lwpt.cfg');
  RecordPath := CaseRoot + PROOFS + Copy(FRegistry.RecordHash('json', '1.0.0'),
    8, 64) + '.toml';
  CheckpointPath := CaseRoot + PROOFS + Copy(TableField(CaseRoot, 'checkpoint'),
    8, 64) + '.toml';
  RecordBytes := ReadText(RecordPath);
  CheckpointBytes := ReadText(CheckpointPath);
  RecursiveDelete(CaseRoot + '/project/.lwpt/modules/json');
  DeleteFile(CaseRoot + '/project/lwpt.cfg');
  Expect<Boolean>(DeleteFile(RecordPath)).ToBe(True);
  Expect<Boolean>(DeleteFile(CheckpointPath)).ToBe(True);
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  ExpectSuccess('offline rebuild', Run(CaseRoot, ['install', '--offline']));
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<Boolean>(FileExists(CaseRoot
    + '/project/.lwpt/modules/json/source/json.pas')).ToBe(True);
  Expect<string>(ReadText(CaseRoot + '/project/lwpt.cfg')).ToBe(Cfg);
  { Both documents come back byte for byte from the per-user store. }
  Expect<string>(ReadText(RecordPath)).ToBe(RecordBytes);
  Expect<string>(ReadText(CheckpointPath)).ToBe(CheckpointBytes);
  Expect<string>(LockText(CaseRoot)).ToBe(Lock);
  ExpectSuccess('frozen after rebuild', Run(CaseRoot, ['install', '--frozen']));
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestOfflineMissFailsWithoutChange;
var CaseRoot, Before: string; Requests: Integer;
begin
  { Neither the committed archive nor the cache holds json. }
  CaseRoot := Clone(Baseline, 'offline-miss');
  Expect<Boolean>(DeleteFile(CaseRoot
    + '/project/.lwpt/archives/json-1.0.0.tar.gz')).ToBe(True);
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  ExpectFailure(Run(CaseRoot, ['install', '--offline']),
    '[offline] verified archive for "json" is unavailable');
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  { A missing proof document with no per-user copy fails the same way. }
  DeleteProof(CaseRoot);
  CopyFileContent(Baseline + '/project/.lwpt/archives/json-1.0.0.tar.gz',
    CaseRoot + '/project/.lwpt/archives/json-1.0.0.tar.gz');
  Before := Fingerprint(CaseRoot);
  ExpectFailure(Run(CaseRoot, ['install', '--offline']), 'registry_proof_missing');
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestOfflineCorruptionIsNotReadAround;
var CaseRoot, Before, CachedObject: string; Requests: Integer;
begin
  { The cache and the per-user store hold good copies throughout: a corrupt
    committed file must fail rather than be read around. }
  CaseRoot := NewCase('offline-corrupt');
  WriteProject(CaseRoot, Declaration(FRegistry), 'json = "registry:json@^1.0.0"'#10);
  ExpectSuccess('corrupt seed', Run(CaseRoot, ['install']));
  DeleteFile(CaseRoot + '/transport.log');
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  FlipArchive(CaseRoot);
  Before := Fingerprint(CaseRoot);
  ExpectFailure(Run(CaseRoot, ['install', '--offline']), 'archive hash mismatch');
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  FlipArchive(CaseRoot);
  FlipProof(CaseRoot);
  Before := Fingerprint(CaseRoot);
  ExpectFailure(Run(CaseRoot, ['install', '--offline']), 'registry_proof_corrupt');
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  FlipProof(CaseRoot);
  { With the committed archive gone, a flipped CAS object is refused. }
  Expect<Boolean>(DeleteFile(CaseRoot
    + '/project/.lwpt/archives/json-1.0.0.tar.gz')).ToBe(True);
  { The object store keeps sha256/<two hex>/<remaining hex>. }
  CachedObject := FindFileEndingWith(CaseRoot + '/cache/dependency-archives',
    '/sha256/'
    + Copy(FRegistry.ArchiveHashOf('json', '1.0.0'), 8, 2) + '/'
    + Copy(FRegistry.ArchiveHashOf('json', '1.0.0'), 10, 62));
  Expect<Boolean>(CachedObject <> '').ToBe(True);
  FlipByte(CachedObject);
  Before := Fingerprint(CaseRoot);
  ExpectFailure(Run(CaseRoot, ['install', '--offline']),
    '[offline] verified archive for "json" is unavailable');
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestOfflineRangeDriftFails;
begin
  RunDrift('offline-range', ChangeRange, 'no longer satisfies', True);
end;

procedure TInstallRegistryLocked.TestOfflineIdentityDriftFails;
begin
  RunDrift('offline-identity', ChangeIdentity, 'no compatible lock entry', True);
end;

procedure TInstallRegistryLocked.TestOfflinePinChangeFails;
begin
  RunDrift('offline-pin', ChangePin, 'trust pin for ' + IDENTITY + ' changed',
    True);
end;

procedure TInstallRegistryLocked.TestOfflineCoordinatedTamperFails;
begin
  { The staged tree, re-extracted from the authenticated archive, differs
    from the recomputed computedHash before anything is published. }
  RunDrift('offline-coordinated', CoordinatedTamper, 'tree hash mismatch', True);
end;

procedure TInstallRegistryLocked.TestOfflineForgedSignatureFails;
begin
  RunDrift('offline-forged', ForgeSignature, 'signature_invalid', True);
end;

{ ---------------------------------------------------------------------------
  Review regressions
  --------------------------------------------------------------------------- }

{ AText with AField of the [package.<AName>] entry set to AValue. }
function WithEntryField(const AText, AName, AField, AValue: string): string;
var Start, FieldStart, ValueEnd: Integer;
begin
  Start := Pos('[package.' + AName + ']', AText);
  Expect<Boolean>(Start > 0).ToBe(True);
  FieldStart := Pos(#10 + AField + ' = "', Copy(AText, Start, MaxInt));
  Expect<Boolean>(FieldStart > 0).ToBe(True);
  FieldStart := Start + FieldStart - 1 + Length(AField) + 5;
  ValueEnd := FieldStart;
  while AText[ValueEnd] <> '"' do Inc(ValueEnd);
  Result := Copy(AText, 1, FieldStart - 1) + AValue
    + Copy(AText, ValueEnd, MaxInt);
end;

procedure TInstallRegistryLocked.Substitute(const ACase, AVictim,
  ASource: string);
var Lock, Field: string;
begin
  Lock := LockText(ACase);
  for Field in ['registryRecord', 'archiveHash', 'computedHash'] do
    Lock := WithEntryField(Lock, AVictim, Field,
      EntryField(Lock, ASource, Field));
  WriteBytesToFile(ACase + '/project/lwpt.lock', BytesOf(Lock));
  Expect<Boolean>(CopyFileContent(ACase + '/project/.lwpt/archives/' + ASource
    + '-1.0.0.tar.gz', ACase + '/project/.lwpt/archives/' + AVictim
    + '-1.0.0.tar.gz')).ToBe(True);
  RecursiveDelete(ACase + '/project/.lwpt/modules/' + AVictim);
  CopyTree(ACase + '/project/.lwpt/modules/' + ASource,
    ACase + '/project/.lwpt/modules/' + AVictim);
end;

{ extras and misc from corp, tool from a second origin under another pin,
  all without dependencies, installed online. }
function TInstallRegistryLocked.SubstitutionCase(const AName: string;
  out AOther: TSyntheticRegistry; out AOtherOrigin: TSyntheticContact): string;
begin
  Result := NewCase(AName);
  AOther := TSyntheticRegistry.Create('https://other.example.com', 13);
  AOtherOrigin := TSyntheticContact.Create(AOther, '/other');
  AOther.AddPackage('tool', '1.0.0', RegistryPackageArchive('tool', '1.0.0'), []);
  AOther.Publish(RegistryStamp(-120), RegistryStamp(6 * DAY));
  WriteProject(Result, Declaration(FRegistry) + '[registries.oss]'#10
    + 'identity = "' + AOther.Identity + '"'#10
    + 'key-id = "' + AOther.KeyID + '"'#10
    + 'public-key = "' + AOther.PublicKey + '"'#10
    + 'origin = "' + AOtherOrigin.BaseURL + '"'#10
    + '[registries]'#10 + 'default = "corp"'#10,
    'extras = "registry:corp/extras@^1.0.0"'#10
    + 'misc = "registry:corp/misc@^1.0.0"'#10
    + 'tool = "registry:oss/tool@^1.0.0"'#10);
  ExpectSuccess('substitution install', Run(Result, ['install']));
  ExpectSuccess('substitution frozen baseline', Run(Result, ['install', '--frozen']));
  DeleteFile(Result + '/transport.log');
end;

procedure TInstallRegistryLocked.TestRecordSubstitutionSameOriginFails;
var
  Other: TSyntheticRegistry;
  OtherOrigin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  Other := nil;
  OtherOrigin := nil;
  try
    CaseRoot := SubstitutionCase('substitute-same', Other, OtherOrigin);
    { extras verifies first; misc then claims extras' record. }
    Substitute(CaseRoot, 'misc', 'extras');
    Before := Fingerprint(CaseRoot);
    FOrigin.Mode := scmFail;
    OtherOrigin.Mode := scmFail;
    ExpectFailure(Run(CaseRoot, ['install', '--frozen']), 'locked_record_mismatch');
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
    ExpectFailure(Run(CaseRoot, ['install', '--offline']), 'locked_record_mismatch');
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
    Expect<string>(Journal(CaseRoot)).ToBe('');
  finally
    OtherOrigin.Free;
    Other.Free;
  end;
end;

procedure TInstallRegistryLocked.TestRecordSubstitutionAcrossOriginsFails;
var
  Other: TSyntheticRegistry;
  OtherOrigin: TSyntheticContact;
  CaseRoot, Before: string;
begin
  Other := nil;
  OtherOrigin := nil;
  try
    CaseRoot := SubstitutionCase('substitute-cross', Other, OtherOrigin);
    { tool, from another origin under another pin, claims corp's extras. }
    Substitute(CaseRoot, 'tool', 'extras');
    Before := Fingerprint(CaseRoot);
    FOrigin.Mode := scmFail;
    OtherOrigin.Mode := scmFail;
    ExpectFailure(Run(CaseRoot, ['install', '--frozen']),
      'committed selection proof for "tool"');
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
    ExpectFailure(Run(CaseRoot, ['install', '--offline']),
      'committed selection proof for "tool"');
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
    Expect<string>(Journal(CaseRoot)).ToBe('');
  finally
    OtherOrigin.Free;
    Other.Free;
  end;
end;

procedure TInstallRegistryLocked.TestLayoutSubstitutionWithEqualTreeHashFails;
var CaseRoot, Module, Legacy, Tree2, Before: string;
begin
  { #352: emptying a unit and adding a file named after its first line,
    holding the rest, keeps the legacy digest. The framed digest changes,
    so --frozen fails on the tree hash itself (ADR-0052). }
  CaseRoot := Clone(Baseline, 'frozen-layout');
  Module := CaseRoot + '/project/.lwpt/modules/json';
  Legacy := LegacyHashTree(Module);
  Tree2 := HashTree(Module);
  SubstituteModuleLayout(Module, 'source/json.pas');
  Expect<string>(LegacyHashTree(Module)).ToBe(Legacy);
  Expect<Boolean>(HashTree(Module) <> Tree2).ToBe(True);
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  ExpectFailure(Run(CaseRoot, ['install', '--frozen']),
    'tree hash mismatch for "json"');
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  Expect<string>(Journal(CaseRoot)).ToBe('');
end;

{ ---------------------------------------------------------------------------
  Schema v4 (ADR-0052)
  --------------------------------------------------------------------------- }

procedure TInstallRegistryLocked.TestRegistryV3LockIsRefusedEverywhere;
var CaseRoot, Before, Manifest: string; Requests: Integer;
begin
  CaseRoot := Clone(Baseline, 'v3-refused');
  DowngradeLockToV3(CaseRoot + '/project');
  Before := Fingerprint(CaseRoot);
  Manifest := ReadText(CaseRoot + '/project/lwpt.toml');
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  ExpectFailure(Run(CaseRoot, ['install']), LockfileSchemaV3Message);
  ExpectFailure(Run(CaseRoot, ['install', '--frozen']), LockfileSchemaV3Message);
  ExpectFailure(Run(CaseRoot, ['install', '--offline']),
    LockfileSchemaV3Message);
  ExpectFailure(Run(CaseRoot, ['add', 'registry:corp/misc@^1.0.0']),
    LockfileSchemaV3Message);
  ExpectFailure(Run(CaseRoot, ['remove', 'local']), LockfileSchemaV3Message);
  ExpectFailure(Run(CaseRoot, ['update']), LockfileSchemaV3Message);
  ExpectFailure(Run(CaseRoot, ['outdated']), LockfileSchemaV3Message);
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  Expect<string>(ReadText(CaseRoot + '/project/lwpt.toml')).ToBe(Manifest);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestRegistryRepairUpgradesWithoutNetwork;
var CaseRoot, V4, Archives, Modules: string; Requests: Integer;
begin
  { The selection proof and its documents are carried forward byte for
    byte; with no newer per-user state the upgraded lock is exactly the v4
    lock an install wrote. }
  CaseRoot := Clone(Baseline, 'v3-repair');
  V4 := LockText(CaseRoot);
  Archives := TreeFingerprint(CaseRoot + '/project/.lwpt/archives');
  Modules := TreeFingerprint(CaseRoot + '/project/.lwpt/modules');
  DowngradeLockToV3(CaseRoot + '/project');
  FOrigin.Mode := scmFail;
  Requests := FOrigin.Requests;
  ExpectSuccess('registry repair', Run(CaseRoot, ['repair']));
  ExpectNetworkFree(CaseRoot, Requests);
  Expect<string>(LockText(CaseRoot)).ToBe(V4);
  Expect<string>(TreeFingerprint(CaseRoot + '/project/.lwpt/archives'))
    .ToBe(Archives);
  Expect<string>(TreeFingerprint(CaseRoot + '/project/.lwpt/modules'))
    .ToBe(Modules);
  ExpectSuccess('registry frozen after repair',
    Run(CaseRoot, ['install', '--frozen']));
  ExpectSuccess('registry offline after repair',
    Run(CaseRoot, ['install', '--offline']));
  Expect<string>(LockText(CaseRoot)).ToBe(V4);
  ExpectNetworkFree(CaseRoot, Requests);
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestRegistryRepairReplacesForgedTree;
var CaseRoot, V4, Module, Output: string; Outcome: TLwptResult;
begin
  { A v4 lock rewritten as v3 with the legacy digest of a forged tree gains
    nothing: --frozen refuses v3, and repair re-derives the module from the
    proof-authenticated archive. }
  CaseRoot := Clone(Baseline, 'v3-forged');
  V4 := LockText(CaseRoot);
  Module := CaseRoot + '/project/.lwpt/modules/json';
  SubstituteModuleLayout(Module, 'source/json.pas');
  DowngradeLockToV3(CaseRoot + '/project');
  FOrigin.Mode := scmFail;
  ExpectFailure(Run(CaseRoot, ['install', '--frozen']), LockfileSchemaV3Message);
  Outcome := Run(CaseRoot, ['repair']);
  ExpectSuccess('registry repair of a forged tree', Outcome);
  Output := Outcome.Stdout + Outcome.Stderr;
  Expect<Boolean>(Pos('module "json"', Output) > 0).ToBe(True);
  Expect<string>(HashTree(Module))
    .ToBe(EntryField(V4, 'json', 'computedHash'));
  Expect<string>(LockText(CaseRoot)).ToBe(V4);
  Expect<string>(Journal(CaseRoot)).ToBe('');
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestRegistryRepairNeedsItsProofs;
var CaseRoot, V3, Snapshot, Before: string;
begin
  CaseRoot := Clone(Baseline, 'v3-proof');
  V3 := DowngradeLockToV3(CaseRoot + '/project');
  Snapshot := Copy(TableField(CaseRoot, 'snapshot'), 8, 64);
  Expect<Boolean>(DeleteFile(CaseRoot + PROOFS + Snapshot + '.toml'))
    .ToBe(True);
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  ExpectFailure(Run(CaseRoot, ['repair']), '`' + PROGRAM_NAME
    + ' repair` cannot upgrade `' + LOCKFILE + '` from schema v3: the '
    + 'registry proof document for "');
  ExpectFailure(Run(CaseRoot, ['repair']), '" at `.lwpt/archives/'
    + 'registry-proofs/sha256/' + Snapshot + '.toml` is missing or does not '
    + 'match its hash, and the per-user document store has no matching copy. '
    + 'Restore that exact document, for example from version control, and '
    + 'run `' + PROGRAM_NAME + ' repair` again. To give up the '
    + 'version-stable migration, delete `' + LOCKFILE + '` and run `'
    + PROGRAM_NAME + ' install`; that needs network access and moves range '
    + 'dependencies to their newest matching versions.');
  Expect<string>(LockText(CaseRoot)).ToBe(V3);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  Expect<string>(Journal(CaseRoot)).ToBe('');
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestRegistryRepairRecordsMergedAcceptedState;
var CaseRoot, V4, V3, Stripped: string; Lines: TStringList; Index: Integer;
begin
  { Decision 11: the upgrade is a lock change, so an origin whose recorded
    accepted state is behind is written with the merged state, here lifted
    to the selection proof; the edit inserts the missing lines in place. }
  CaseRoot := Clone(Baseline, 'v3-accepted');
  V4 := LockText(CaseRoot);
  V3 := DowngradeLockToV3(CaseRoot + '/project');
  Lines := TStringList.Create;
  try
    Lines.Text := V3;
    for Index := Lines.Count - 1 downto 0 do
      if (Copy(Lines[Index], 1, 8) = 'accepted')
         or (Copy(Lines[Index], 1, 10) = 'clockFloor') then
        Lines.Delete(Index);
    Stripped := Lines.Text;
  finally
    Lines.Free;
  end;
  Expect<Boolean>(Stripped <> V3).ToBe(True);
  { A trailing comment on the header must not hide the table from the
    accepted-state update. }
  Stripped := StringReplace(Stripped, '[registry."' + IDENTITY + '"]',
    '[registry."' + IDENTITY + '"] # corp', []);
  WriteBytesToFile(CaseRoot + '/project/lwpt.lock', BytesOf(Stripped));
  FOrigin.Mode := scmFail;
  ExpectSuccess('registry repair accepted state', Run(CaseRoot, ['repair']));
  Expect<string>(LockText(CaseRoot)).ToBe(StringReplace(V4,
    '[registry."' + IDENTITY + '"]', '[registry."' + IDENTITY + '"] # corp',
    []));
  Expect<string>(Journal(CaseRoot)).ToBe('');
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.TestRegistryRepairBoundsProofDocuments;
var CaseRoot, V3, Snapshot, Before: string; Oversized: TBytes;
begin
  { Repair loads proofs through the bounded loader: an oversized document is
    refused by its size before it is read, and repeated rotation hashes
    before any read, with the migration prefix and the lock left v3. }
  CaseRoot := Clone(Baseline, 'v3-oversized');
  V3 := DowngradeLockToV3(CaseRoot + '/project');
  Snapshot := Copy(TableField(CaseRoot, 'snapshot'), 8, 64);
  SetLength(Oversized, 5 * 1024 * 1024);
  FillChar(Oversized[0], Length(Oversized), Ord('x'));
  WriteBytesToFile(CaseRoot + PROOFS + Snapshot + '.toml', Oversized);
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  ExpectFailure(Run(CaseRoot, ['repair']), '`' + PROGRAM_NAME
    + ' repair` cannot upgrade `' + LOCKFILE + '` from schema v3: the '
    + 'committed selection proof of ' + IDENTITY);
  ExpectFailure(Run(CaseRoot, ['repair']), 'proof_limit_exceeded');
  Expect<string>(LockText(CaseRoot)).ToBe(V3);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);

  CaseRoot := Clone(Baseline, 'v3-repeated');
  DowngradeLockToV3(CaseRoot + '/project');
  Snapshot := TableField(CaseRoot, 'snapshot');
  EditLock(CaseRoot, #10'rotations = []', #10'rotations = ["' + Snapshot
    + '", "' + Snapshot + '", "' + Snapshot + '"]');
  V3 := LockText(CaseRoot);
  Before := Fingerprint(CaseRoot);
  ExpectFailure(Run(CaseRoot, ['repair']), 'repeat');
  ExpectFailure(Run(CaseRoot, ['repair']), 'cannot upgrade `' + LOCKFILE
    + '` from schema v3');
  Expect<string>(LockText(CaseRoot)).ToBe(V3);
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  Expect<string>(Journal(CaseRoot)).ToBe('');
  FOrigin.Mode := scmServe;
end;

procedure TInstallRegistryLocked.SetArchivesReadOnly(const ACase: string;
  const AReadOnly: Boolean);
var Entry: TSearchRec; Root: string;
begin
  Root := ACase + '/project/.lwpt/archives';
  if FindFirst(Root + '/*.tar.gz', faAnyFile, Entry) = 0 then
    try
      repeat
        if AReadOnly then FileSetAttr(Root + '/' + Entry.Name, faReadOnly)
        else FileSetAttr(Root + '/' + Entry.Name, 0);
      until FindNext(Entry) <> 0;
    finally
      FindClose(Entry);
    end;
  {$IFDEF UNIX}
  if AReadOnly then FpChmod(Root, &555) else FpChmod(Root, &755);
  {$ENDIF}
end;

procedure TInstallRegistryLocked.TestFrozenLeavesArchiveStorageUntouched;
var CaseRoot, Sentinel, Before: string;
begin
  CaseRoot := Clone(Baseline, 'frozen-readonly');
  { A file where a sibling intermediate tar would go must survive. }
  Sentinel := CaseRoot + '/project/.lwpt/archives/json-1.0.0.tar.gz.tar';
  { Exact bytes: WriteTextFile uses the platform line ending. }
  WriteBytesToFile(Sentinel, BytesOf('sentinel'#10));
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  SetArchivesReadOnly(CaseRoot, True);
  try
    ExpectSuccess('frozen over read-only archives',
      Run(CaseRoot, ['install', '--frozen']));
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
    Expect<Boolean>(TmpHasFrozenScratch(CaseRoot + '/project')).ToBe(False);
    { An extraction that fails after decompression cleans up its private
      scratch and still writes nothing beside the archives. }
    ExpectFailure(RunWith(CaseRoot, ['install', '--frozen'],
      [PROJECT_NAME + '_TEST_FAIL_REGISTRY_REDERIVE=1']), 'extract');
    Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
    Expect<Boolean>(TmpHasFrozenScratch(CaseRoot + '/project')).ToBe(False);
    Expect<Boolean>(FileExists(CaseRoot
      + '/project/.lwpt/archives/extras-1.0.0.tar.gz.tar')).ToBe(False);
  finally
    SetArchivesReadOnly(CaseRoot, False);
  end;
  Expect<string>(ReadText(Sentinel)).ToBe('sentinel'#10);
  Expect<string>(Journal(CaseRoot)).ToBe('');
end;

procedure TInstallRegistryLocked.TestRepeatedRotationHashesAreRefused;
var CaseRoot, Snapshot, Before: string;
begin
  { One committed document named three times: a repeat is refused before any
    rotation document is read, so repeats cannot multiply allocation. }
  CaseRoot := Clone(Baseline, 'rotation-repeat');
  Snapshot := TableField(CaseRoot, 'snapshot');
  EditLock(CaseRoot, #10'rotations = []', #10'rotations = ["' + Snapshot
    + '", "' + Snapshot + '", "' + Snapshot + '"]');
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  ExpectFailure(Run(CaseRoot, ['install', '--frozen']), 'repeat');
  ExpectFailure(Run(CaseRoot, ['install', '--offline']), 'repeat');
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  Expect<string>(Journal(CaseRoot)).ToBe('');
end;

procedure TInstallRegistryLocked.TestRotationCountIsBoundedBeforeReading;
var CaseRoot, Hashes, Before: string; Index: Integer;
begin
  { 1,001 rotations of distinct, absent documents: the count limit fails
    first, so no document is looked up. }
  CaseRoot := Clone(Baseline, 'rotation-count');
  Hashes := '';
  for Index := 1 to 3003 do
  begin
    if Hashes <> '' then Hashes := Hashes + ', ';
    Hashes := Hashes + '"sha256:' + SHA256Hex(BytesOf(IntToStr(Index))) + '"';
  end;
  EditLock(CaseRoot, #10'rotations = []', #10'rotations = [' + Hashes + ']');
  Before := Fingerprint(CaseRoot);
  FOrigin.Mode := scmFail;
  ExpectFailure(Run(CaseRoot, ['install', '--frozen']), 'proof_limit_exceeded');
  Expect<string>(Fingerprint(CaseRoot)).ToBe(Before);
  Expect<string>(Journal(CaseRoot)).ToBe('');
end;

procedure TInstallRegistryLocked.SetupTests;
begin
  Test('the transport journal records an online install''s client and requests',
    TestJournalRecordsOnlineTransport);
  Test('#62: --frozen verifies a fresh clone with no network, cache, or state',
    TestFrozenCloneIsNetworkFree);
  Test('#62: --frozen and --offline take an omitted identity from the lock',
    TestFrozenIdentityFromLock);
  Test('#62: --frozen fails on a flipped archive byte',
    TestFrozenArchiveFlipFails);
  Test('#62: --frozen fails on an edited module file',
    TestFrozenModuleEditFails);
  Test('#62: --frozen fails on an edited registryRecord',
    TestFrozenRecordEditFails);
  Test('#62: --frozen fails on an edited checkpoint',
    TestFrozenCheckpointEditFails);
  Test('#62: --frozen fails on an edited proof sequence',
    TestFrozenSequenceEditFails);
  Test('#62: --frozen fails on an edited trustKeyId',
    TestFrozenTrustKeyEditFails);
  Test('#62: --frozen fails on a flipped proof document byte',
    TestFrozenProofFlipFails);
  Test('#62: --frozen fails on a deleted proof document',
    TestFrozenProofDeletionFails);
  Test('#62: --frozen fails on a changed manifest pin',
    TestFrozenPinChangeFails);
  Test('#62: --frozen fails on a schema version 2 lock',
    TestFrozenSchemaTwoFails);
  Test('#62: --frozen catches a module edit with a recomputed computedHash',
    TestFrozenCoordinatedTamperFails);
  Test('#62: --frozen catches a forged signature with consistent hashes',
    TestFrozenForgedSignatureFails);
  Test('#62: an expired proof still verifies under --frozen and --offline',
    TestExpiredProofStillVerifies);
  Test('#226: --offline restores from the shared cache without network',
    TestOfflineFromSharedCacheOnly);
  Test('#226: --offline restores from committed archives without the cache',
    TestOfflineFromCommittedArchivesOnly);
  Test('#226: --offline rebuilds modules, cfg, and proofs from the store',
    TestOfflineReconstructsModulesCfgAndProofs);
  Test('#226: an offline archive or proof miss fails without change',
    TestOfflineMissFailsWithoutChange);
  Test('#226: corrupt archives, proofs, and CAS objects are not read around',
    TestOfflineCorruptionIsNotReadAround);
  Test('#226: an offline range change fails', TestOfflineRangeDriftFails);
  Test('#226: an offline alias identity change fails',
    TestOfflineIdentityDriftFails);
  Test('#226: an offline pin change fails', TestOfflinePinChangeFails);
  Test('#226: --offline catches a module edit with a recomputed computedHash',
    TestOfflineCoordinatedTamperFails);
  Test('#226: --offline catches a forged signature with consistent hashes',
    TestOfflineForgedSignatureFails);
  Test('review: a lock entry pointed at another package''s record fails',
    TestRecordSubstitutionSameOriginFails);
  Test('review: a lock entry pointed at another origin''s record fails',
    TestRecordSubstitutionAcrossOriginsFails);
  Test('#352: a re-laid-out module with an equal legacy digest fails --frozen',
    TestLayoutSubstitutionWithEqualTreeHashFails);
  Test('ADR-0052: every reader refuses a registry v3 lock and changes nothing',
    TestRegistryV3LockIsRefusedEverywhere);
  Test('ADR-0052: repair upgrades a registry v3 lock without network',
    TestRegistryRepairUpgradesWithoutNetwork);
  Test('ADR-0052: repair replaces a forged registry tree behind a v3 lock',
    TestRegistryRepairReplacesForgedTree);
  Test('ADR-0052: repair names a missing registry proof document',
    TestRegistryRepairNeedsItsProofs);
  Test('ADR-0052: repair writes the merged accepted state into the old table',
    TestRegistryRepairRecordsMergedAcceptedState);
  Test('ADR-0052: repair loads proofs within the verification budgets',
    TestRegistryRepairBoundsProofDocuments);
  Test('review: --frozen never writes beside committed archives, even on failure',
    TestFrozenLeavesArchiveStorageUntouched);
  Test('review: repeated rotation hashes in the lock are refused',
    TestRepeatedRotationHashesAreRefused);
  Test('review: an oversized rotation list is refused before any document is read',
    TestRotationCountIsBoundedBeforeReading);
end;

begin
  TestRunnerProgram.AddSuite(TInstallRegistryLocked.Create(
    'Install registry frozen and offline'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
