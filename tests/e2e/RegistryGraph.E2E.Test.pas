program RegistryGraph.E2E.Test;

{ A dependency graph published through `registry publish` and installed
  from the signed records (ADR-0051 decision 10, "Dependency-bearing
  publication"). Two `registry serve` origins hold a chain: alpha on origin
  one depends on beta on origin two and on delta on its own origin, and
  beta depends on gamma on its own origin. The records name those edges;
  the served record bytes must equal the mapped manifest, with the
  publishing origin omitted and entries in protocol order. A consumer that
  declares only alpha then installs the whole graph online, and with both
  origins stopped passes --frozen, restores deleted modules and cfg with
  --offline, and leaves the lock byte-identical. }

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
  Tests.RegistryProcess,
  Tests.RegistryPublish,
  Tests.Scratch,
  Tests.TarSynth,
  Tests.ZipSynth;

const
  ONE_IDENTITY = 'https://one.example.test';
  INSTALL_TIMEOUT_MILLISECONDS = 180000;
  GRAPH: array[0..3] of string = ('alpha', 'beta', 'gamma', 'delta');

type
  TRegistryGraphE2E = class(TTestSuite)
  private
    FScratch, FWork, FProject: string;
    FOne, FTwo: TPublishOrigin;
    FOneToken, FTwoToken, FOutputs: string;
    procedure ReleaseScratch;
    function Publish(AOrigin: TPublishOrigin; const AToken, AFile: string;
      const ABytes: TBytes): string;
    function Install(const AArguments: array of string): TLwptResult;
    function Output(const ARun: TLwptResult): string;
    procedure ExpectSuccess(const ALabel: string; const ARun: TLwptResult);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestPublishedGraphInstallsFromSignedRecords;
  end;

function PackageManifest(const AName, AVersion, AExtra: string): string;
begin
  Result := '[package]' + #10 + 'name = "' + AName + '"' + #10
    + 'version = "' + AVersion + '"' + #10 + 'units = ["source"]' + #10 + AExtra;
end;

function PackageUnit(const AName: string): string;
begin
  Result := 'unit ' + AName + ';' + #10 + 'interface' + #10
    + 'implementation' + #10 + 'end.' + #10;
end;

function GraphTarGz(const AName, AVersion, AExtra: string): TBytes;
var
  Root: string;
begin
  Root := AName + '-' + AVersion + '/';
  Result := Gzip(BuildTar([MakeDirectoryEntry(Root),
    MakeRegularFileEntry(Root + 'lwpt.toml',
      TextBytes(PackageManifest(AName, AVersion, AExtra))),
    MakeRegularFileEntry(Root + 'source/' + AName + '.pas',
      TextBytes(PackageUnit(AName)))]));
end;

function GraphZip(const AName, AVersion, AExtra: string): TBytes;
var
  Zip: TZipSynth;
begin
  Zip := TZipSynth.Create;
  try
    Zip.AddText('lwpt.toml', PackageManifest(AName, AVersion, AExtra));
    Zip.AddText('source/' + AName + '.pas', PackageUnit(AName));
    Result := Zip.Build;
  finally
    Zip.Free;
  end;
end;

function ReadText(const APath: string): string;
begin
  if not FileExists(APath) then Exit('');
  Result := ReadBinaryFile(APath);
end;

{ The value of AField in the [package.<AName>] entry of a lock. }
function EntryField(const ALock, AName, AField: string): string;
var
  Rest: string;
  Start, Stop: Integer;
begin
  Result := '';
  { The lock uses the platform line ending. }
  Rest := StringReplace(ALock, #13#10, #10, [rfReplaceAll]);
  Start := Pos('[package.' + AName + ']' + #10, Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start + 1, MaxInt);
  Stop := Pos(#10 + '[', Rest);
  if Stop > 0 then Rest := Copy(Rest, 1, Stop);
  Start := Pos(#10 + AField + ' = "', Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start + Length(AField) + 5, MaxInt);
  Result := Copy(Rest, 1, Pos('"', Rest) - 1);
end;

{ The last line of a canonical record: its dependency list. }
function DependencyLine(const ARecord: string): string;
var
  Body: string;
begin
  Body := Copy(ARecord, 1, Length(ARecord) - 1);
  Result := Copy(Body, LastDelimiter(#10, Body) + 1, MaxInt);
end;

procedure TRegistryGraphE2E.BeforeEach;
begin
  ReleaseScratch;
  { Short names keep the deepest install paths inside the legacy Windows
    MAX_PATH on CI runners with deep workspaces (#347). }
  FScratch := CreateScratchRoot('reg-graph');
  FWork := FScratch + '/w';
  FProject := FScratch + '/p';
  ForceDirectories(FWork);
  ForceDirectories(FProject + '/source');
  ForceDirectories(FScratch + '/s');
  ForceDirectories(FScratch + '/c');
  FOutputs := '';
end;

procedure TRegistryGraphE2E.AfterEach;
begin
  FreeAndNil(FOne);
  FreeAndNil(FTwo);
end;

procedure TRegistryGraphE2E.AfterAll;
begin
  FreeAndNil(FOne);
  FreeAndNil(FTwo);
  ReleaseScratch;
end;

procedure TRegistryGraphE2E.ReleaseScratch;
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
  WriteLn(StdErr, 'registry graph e2e cleanup: ', Failure);
  FScratch := '';
end;

function TRegistryGraphE2E.Output(const ARun: TLwptResult): string;
begin
  Result := ARun.Stdout + ARun.Stderr;
end;

procedure TRegistryGraphE2E.ExpectSuccess(const ALabel: string;
  const ARun: TLwptResult);
begin
  if ARun.ExitCode <> 0 then
    WriteLn(StdErr, '--- ', ALabel, ' ---', LineEnding, Output(ARun), '---');
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

{ Publishes AFile through the production binary and returns the record
  hash its success line names. }
function TRegistryGraphE2E.Publish(AOrigin: TPublishOrigin;
  const AToken, AFile: string; const ABytes: TBytes): string;
var
  Path: string;
  Run: TLwptResult;
begin
  Path := FScratch + '/' + AFile;
  WriteBinaryFile(Path, ABytes);
  Run := RunPublish(Path, AOrigin.Base, AOrigin.KeyID, AOrigin.PublicKey, '',
    AToken, FWork, [], []);
  FOutputs := FOutputs + Output(Run);
  ExpectSuccess('publish ' + AFile, Run);
  Expect<Boolean>(Pos('published ', PublishLine(Run)) = 1).ToBe(True);
  Result := PublishedRecordHash(PublishLine(Run));
end;

{ The consumer runs the test-flavoured binary, which accepts plain-HTTP
  localhost contacts, with private registry state and cache. }
function TRegistryGraphE2E.Install(const AArguments: array of string): TLwptResult;
begin
  Result := RunLwptTesting(AArguments, FProject,
    [UpperCase(RegistryProgramName) + '_REGISTRY_STATE_DIR=' + FScratch + '/s',
     UpperCase(RegistryProgramName) + '_CACHE_DIR=' + FScratch + '/c'],
    INSTALL_TIMEOUT_MILLISECONDS);
  FOutputs := FOutputs + Output(Result);
end;

procedure TRegistryGraphE2E.TestPublishedGraphInstallsFromSignedRecords;
var
  OnePort, TwoPort: Word;
  TwoIdentity, AlphaRecord, BetaRecord, Registries, Lock, Cfg, Name,
    ServedAlpha, ServedBeta: string;
  Run: TLwptResult;
begin
  OnePort := FindAvailableRegistryTestPort;
  FOne := TPublishOrigin.Create(FScratch, 'o1', OnePort, OnePort, False,
    ONE_IDENTITY);
  TwoPort := FindAvailableRegistryTestPort;
  if TwoPort = OnePort then TwoPort := FindAvailableRegistryTestPort;
  FTwo := TPublishOrigin.Create(FScratch, 'o2', TwoPort, TwoPort);
  TwoIdentity := FTwo.Base;
  FOneToken := FOne.IssueToken(['--packages', '*']);
  FTwoToken := FTwo.IssueToken(['--packages', '*']);
  FOne.Start;
  FTwo.Start;

  { Origin two: gamma in three versions, then beta, which depends on gamma
    through its only (so implied default) registry: its own origin. }
  Publish(FTwo, FTwoToken, 'g1.tar.gz', GraphTarGz('gamma', '1.0.0', ''));
  Publish(FTwo, FTwoToken, 'g2.tar.gz', GraphTarGz('gamma', '1.1.0', ''));
  Publish(FTwo, FTwoToken, 'g3.tar.gz', GraphTarGz('gamma', '2.0.0', ''));
  BetaRecord := Publish(FTwo, FTwoToken, 'b.tar.gz', GraphTarGz('beta', '1.0.0',
    '[registries.two]' + #10 + 'identity = "' + TwoIdentity + '"' + #10
    + '[dependencies]' + #10 + 'gamma = "registry:gamma@^1.0.0"' + #10));
  { Origin one: delta, then alpha as a zip, which depends on beta across
    origins and on delta through its default registry. }
  Publish(FOne, FOneToken, 'd.tar.gz', GraphTarGz('delta', '1.0.0', ''));
  AlphaRecord := Publish(FOne, FOneToken, 'a.zip', GraphZip('alpha', '1.0.0',
    '[registries]' + #10 + 'default = "one"' + #10
    + '[registries.one]' + #10 + 'identity = "' + ONE_IDENTITY + '"' + #10
    + '[registries.two]' + #10 + 'identity = "' + TwoIdentity + '"' + #10
    + '[dependencies]' + #10
    + 'delta = "registry:delta@^1.0.0"' + #10
    + 'beta = { source = "registry:two/beta", version = ">=1.0.0 <2.0.0" }' + #10));

  { The served records carry the mapped manifests: the publishing origin
    omitted, the rest explicit, sorted by effective origin. }
  ServedAlpha := RawHTTPBodyText(FOne.Request('GET', '/v1/records/sha256/'
    + Copy(AlphaRecord, 8, 64) + '.toml', [], nil));
  Expect<string>(DependencyLine(ServedAlpha)).ToBe('dependencies = [{ origin = "'
    + TwoIdentity + '", name = "beta", version = ">=1.0.0 <2.0.0" }, '
    + '{ name = "delta", version = "^1.0.0" }]');
  ServedBeta := RawHTTPBodyText(FTwo.Request('GET', '/v1/records/sha256/'
    + Copy(BetaRecord, 8, 64) + '.toml', [], nil));
  Expect<string>(DependencyLine(ServedBeta))
    .ToBe('dependencies = [{ name = "gamma", version = "^1.0.0" }]');

  { A consumer that declares only alpha gets the graph from the records. }
  Registries := '[registries]' + #10 + 'default = "one"' + #10
    + '[registries.one]' + #10 + 'identity = "' + ONE_IDENTITY + '"' + #10
    + 'key-id = "' + FOne.KeyID + '"' + #10
    + 'public-key = "' + FOne.PublicKey + '"' + #10
    + 'origin = "' + FOne.Base + '"' + #10
    + '[registries.two]' + #10 + 'identity = "' + TwoIdentity + '"' + #10
    + 'key-id = "' + FTwo.KeyID + '"' + #10
    + 'public-key = "' + FTwo.PublicKey + '"' + #10;
  WriteBinaryFile(FProject + '/lwpt.toml', TextBytes('[package]' + #10
    + 'name = "consumer"' + #10 + 'version = "1.0.0"' + #10
    + 'units = ["source"]' + #10 + Registries + '[dependencies]' + #10
    + 'alpha = "registry:alpha@^1.0.0"' + #10));
  WriteBinaryFile(FProject + '/source/main.pas', TextBytes('program main;' + #10
    + 'begin' + #10 + 'end.' + #10));
  ExpectSuccess('online install', Install(['install']));
  Lock := ReadText(FProject + '/lwpt.lock');
  Expect<string>(EntryField(Lock, 'alpha', 'registryOrigin')).ToBe(ONE_IDENTITY);
  Expect<string>(EntryField(Lock, 'alpha', 'registryRecord')).ToBe(AlphaRecord);
  Expect<string>(EntryField(Lock, 'alpha', 'resolvedRef')).ToBe('1.0.0');
  Expect<string>(EntryField(Lock, 'beta', 'registryOrigin')).ToBe(TwoIdentity);
  Expect<string>(EntryField(Lock, 'beta', 'registryRecord')).ToBe(BetaRecord);
  Expect<string>(EntryField(Lock, 'beta', 'source')).ToBe('registry:beta');
  Expect<string>(EntryField(Lock, 'delta', 'registryOrigin')).ToBe(ONE_IDENTITY);
  Expect<string>(EntryField(Lock, 'delta', 'resolvedRef')).ToBe('1.0.0');
  { Reached only through beta's record; the highest version in its range. }
  Expect<string>(EntryField(Lock, 'gamma', 'registryOrigin')).ToBe(TwoIdentity);
  Expect<string>(EntryField(Lock, 'gamma', 'resolvedRef')).ToBe('1.1.0');
  Expect<Boolean>(Pos('[registry."' + ONE_IDENTITY + '"]', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('[registry."' + TwoIdentity + '"]', Lock) > 0).ToBe(True);
  Cfg := ReadText(FProject + '/lwpt.cfg');
  for Name in GRAPH do
  begin
    Expect<Boolean>(Pos('-Fu.lwpt/modules/' + Name + '/source', Cfg) > 0).ToBe(True);
    Expect<Boolean>(FileExists(FProject + '/.lwpt/modules/' + Name + '/source/'
      + Name + '.pas')).ToBe(True);
  end;

  { With both origins gone, frozen verification and offline restoration
    use only committed state. }
  FOne.Stop;
  FTwo.Stop;
  ExpectSuccess('frozen', Install(['install', '--frozen']));
  RecursiveDelete(FProject + '/.lwpt/modules');
  DeleteFile(FProject + '/lwpt.cfg');
  ExpectSuccess('offline', Install(['install', '--offline']));
  Expect<string>(ReadText(FProject + '/lwpt.lock')).ToBe(Lock);
  Expect<string>(ReadText(FProject + '/lwpt.cfg')).ToBe(Cfg);
  Expect<Boolean>(FileExists(FProject + '/.lwpt/modules/gamma/source/gamma.pas'))
    .ToBe(True);
  Run := Install(['install', '--frozen']);
  ExpectSuccess('frozen after offline', Run);
  Expect<string>(ReadText(FProject + '/lwpt.lock')).ToBe(Lock);
  { Tokens are never printed. }
  Expect<Boolean>(Pos(TokenSecret(FOneToken), FOutputs) = 0).ToBe(True);
  Expect<Boolean>(Pos(TokenSecret(FTwoToken), FOutputs) = 0).ToBe(True);
end;

procedure TRegistryGraphE2E.SetupTests;
begin
  Test('a published cross-origin graph installs from its records online, frozen, and offline',
    TestPublishedGraphInstallsFromSignedRecords);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryGraphE2E.Create('registry graph e2e'));
  TestRunnerProgram.Run;
end.
