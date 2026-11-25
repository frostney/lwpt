{ TestCache.Test — verified compiled-test reuse with always-fresh execution. }
program TestCache.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch,

  LWPT.BuildSession,
  LWPT.ObjectStore,
  LWPT.WorkerBudget;

type
  TLWPTThreadRun = class(TThread)
  private
    FEnvironment: array of string;
    FProjectRoot: string;
    FResult: TLwptResult;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProjectRoot: string;
      const AEnvironment: array of string);
    property RunResult: TLwptResult read FResult;
  end;

  TTestCache = class(TTestSuite)
  private
    FScratch: string;
    FRepositoryRoot: string;
    function CacheEnvironment(const ACacheRoot, AMarker: string): TStringArray;
    function CountFiles(const ARoot: string): Integer;
    function CountMarkerLines(const APath: string): Integer;
    function FindOnlyFile(const ARoot: string): string;
    function ObjectPath(const ACacheRoot, ADigest: string): string;
    function ManifestField(const AText, AName: string): string;
    procedure WriteProject(const AProjectRoot, AProgramBody: string;
      const AUnitBody: string = '');
    procedure RequireSuccess(const ALabel: string; const ARun: TLwptResult);
    procedure WriteSearchProject(const AProjectRoot, AManifestTail,
      AProgramHead, AEditedPath, AInitial: string);
    procedure RequireEditRecompiles(const ALabel, AProjectRoot,
      AEditedPath, AEdited: string;
      const AExtraEnvironment: array of string);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestEquivalentWorktreesReuseCompileAndRunFresh;
    procedure TestSourceUnitAndFlagsInvalidateFingerprint;
    procedure TestImplicitRootUnitInvalidatesFingerprint;
    procedure TestConfiguredCompilerFileIsEffective;
    procedure TestBypassDoesNotCaptureCacheFingerprint;
    procedure TestInventoryReusesExecutableButQueriesRegistrations;
    procedure TestCorruptArtifactIsRejectedAndRebuilt;
    procedure TestFailedCompileNeverBecomesHit;
    procedure TestFailingExecutionIsAlwaysFresh;
    procedure TestConcurrentMissCompilesOnce;
    procedure TestPassingRerunRemovesSupersededExecutable;
    procedure TestFlagUnitDirectoryInvalidatesFingerprint;
    procedure TestProfileIncludeDirectoryInvalidatesFingerprint;
    procedure TestConfigurationIncludeDirectoryInvalidatesFingerprint;
    procedure TestEnvironmentMacroDirectoryInvalidatesFingerprint;
    procedure TestConfigurationDirectoryIncludeInvalidatesFingerprint;
    procedure TestUnboundedSearchEntryIsNeverReused;
    {$IFDEF UNIX}
    procedure TestFifoInUnitDirectoryDoesNotHangCachedRun;
    procedure TestConfigurationSwappedForFifoDoesNotHangCachedRun;
    {$ENDIF}
  end;

const
  { Bounds a run that a blocking open would otherwise hang. }
  FIFO_RUN_TIMEOUT_MILLISECONDS = 120000;

constructor TLWPTThreadRun.Create(const AProjectRoot: string;
  const AEnvironment: array of string);
var
  i: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProjectRoot := AProjectRoot;
  SetLength(FEnvironment, Length(AEnvironment));
  for i := 0 to High(AEnvironment) do
    FEnvironment[i] := AEnvironment[i];
end;

procedure TLWPTThreadRun.Execute;
begin
  try
    FResult := RunLwpt(['test', '--verbose', '--jobs=1'], FProjectRoot,
      FEnvironment);
  except
    { A thread swallows exceptions; report a timed-out run as a failure
      the caller's exit-code check cannot mistake for success. }
    on E: Exception do
    begin
      FResult.ExitCode := -1;
      FResult.TimedOut := E is ELwptRunTimeout;
      FResult.Stderr := FResult.Stderr + E.Message;
    end;
  end;
end;

function CountSubstring(const AText, ANeedle: string): Integer;
var
  Offset, Position: Integer;
begin
  Result := 0;
  Offset := 1;
  repeat
    Position := Pos(ANeedle, Copy(AText, Offset, MaxInt));
    if Position = 0 then Exit;
    Inc(Result);
    Inc(Offset, Position + Length(ANeedle) - 1);
  until False;
end;

procedure TTestCache.BeforeAll;
begin
  FScratch := CreateScratchRoot('test-cache');
  FRepositoryRoot := GetCurrentDir;
end;

function TTestCache.CacheEnvironment(const ACacheRoot,
  AMarker: string): TStringArray;
begin
  SetLength(Result, 5);
  Result[0] := CACHE_DIR_ENV + '=' + ACacheRoot;
  Result[1] := 'CACHE_EXEC_MARKER=' + AMarker;
  Result[2] := WORKER_STATE_DIR_ENV + '=' + FScratch + '/worker-state';
  Result[3] := WORKER_BUDGET_ENV + '=2';
  Result[4] := WORKER_LEASE_TOKEN_ENV + '=';
end;

function TTestCache.CountFiles(const ARoot: string): Integer;
var
  Search: TSearchRec;
  Base: string;
begin
  Result := 0;
  if not DirectoryExists(ARoot) then Exit;
  Base := IncludeTrailingPathDelimiter(ARoot);
  if FindFirst(Base + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        Inc(Result, CountFiles(Base + Search.Name))
      else
        Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TTestCache.CountMarkerLines(const APath: string): Integer;
var
  Lines: TStringList;
begin
  if not FileExists(APath) then Exit(0);
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Result := Lines.Count;
  finally
    Lines.Free;
  end;
end;

function TTestCache.FindOnlyFile(const ARoot: string): string;
var
  Search: TSearchRec;
  Base, Found: string;
begin
  Result := '';
  if not DirectoryExists(ARoot) then Exit;
  Base := IncludeTrailingPathDelimiter(ARoot);
  if FindFirst(Base + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        Found := FindOnlyFile(Base + Search.Name)
      else
        Found := Base + Search.Name;
      if Found = '' then Continue;
      if Result <> '' then
        raise Exception.CreateFmt('expected one file below %s', [ARoot]);
      Result := Found;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TTestCache.ObjectPath(const ACacheRoot, ADigest: string): string;
var
  Hex: string;
begin
  Hex := Copy(ADigest, Length('sha256:') + 1, MaxInt);
  Result := ACacheRoot + '/build-results/objects/sha256/'
    + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
end;

function TTestCache.ManifestField(const AText, AName: string): string;
var
  Lines: TStringList;
  i: Integer;
  Prefix: string;
begin
  Result := '';
  Prefix := AName + ' = "';
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for i := 0 to Lines.Count - 1 do
      if Copy(Lines[i], 1, Length(Prefix)) = Prefix then
      begin
        Result := Copy(Lines[i], Length(Prefix) + 1,
          Length(Lines[i]) - Length(Prefix) - 1);
        Exit;
      end;
  finally
    Lines.Free;
  end;
end;

procedure TTestCache.WriteProject(const AProjectRoot, AProgramBody: string;
  const AUnitBody: string);
begin
  RecursiveDelete(AProjectRoot);
  WriteTextFile(AProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-cache-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(AProjectRoot + '/tests/CacheFixture.Test.pas', AProgramBody);
  if AUnitBody <> '' then
    WriteTextFile(AProjectRoot + '/source/CacheFixtureUnit.pas', AUnitBody);
end;

procedure TTestCache.RequireSuccess(const ALabel: string;
  const ARun: TLwptResult);
var
  Diagnostics: TStringList;
begin
  if ARun.ExitCode = 0 then Exit;
  Diagnostics := TStringList.Create;
  try
    DumpRunFailure(ALabel, ARun, 0, Diagnostics);
    Fail(Diagnostics.Text);
  finally
    Diagnostics.Free;
  end;
end;

function MarkerProgram(const AExitCode: Integer;
  const AUsesUnit: Boolean = False): string;
var
  UnitUse: string;
begin
  if AUsesUnit then UnitUse := ', CacheFixtureUnit' else UnitUse := '';
  Result := 'program CacheFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils' + UnitUse + ';'#10
    + 'var Lines: TStringList; Marker: string;'#10
    + 'begin'#10
    + '  Marker := GetEnvironmentVariable(''CACHE_EXEC_MARKER'');'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    if FileExists(Marker) then Lines.LoadFromFile(Marker);'#10
    + '    Lines.Add(''executed'');'#10
    + '    Lines.SaveToFile(Marker);'#10
    + '  finally Lines.Free end;'#10
    + '  Halt(' + IntToStr(AExitCode) + ');'#10
    + 'end.'#10;
end;

function ConcurrentMarkerProgram: string;
begin
  Result := 'program ConcurrentCacheFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Marker: string; Stream: TFileStream;'#10
    + 'begin'#10
    + '  Marker := IncludeTrailingPathDelimiter(GetEnvironmentVariable('
    + '''CACHE_EXEC_MARKER'')) + IntToStr(GetProcessID);'#10
    + '  Stream := TFileStream.Create(Marker, fmCreate);'#10
    + '  Stream.Free;'#10
    + 'end.'#10;
end;

procedure TTestCache.TestEquivalentWorktreesReuseCompileAndRunFresh;
var
  CacheRoot, Marker, ProjectA, ProjectB: string;
  Environment: TStringArray;
  First, Second, Bypass: TLwptResult;
begin
  CacheRoot := FScratch + '/equivalent-cache';
  Marker := FScratch + '/equivalent-marker';
  ProjectA := FScratch + '/worktree-a';
  ProjectB := FScratch + '/worktree-b';
  RecursiveDelete(CacheRoot);
  WriteProject(ProjectA, MarkerProgram(0));
  WriteProject(ProjectB, MarkerProgram(0));
  Environment := CacheEnvironment(CacheRoot, Marker);

  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectA, Environment);
  RequireSuccess('first equivalent worktree run', First);
  Expect<Boolean>(Pos('cache miss: no-result', First.Stdout) > 0).ToBe(True);
  Second := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectB, Environment);
  RequireSuccess('second equivalent worktree run', Second);
  Expect<Boolean>(Pos('cache hit:', Second.Stdout) > 0).ToBe(True);
  Expect<Integer>(CountMarkerLines(Marker)).ToBe(2);

  Bypass := RunLwpt(['test', '--verbose', '--jobs=1', '--no-cache'],
    ProjectB, Environment);
  RequireSuccess('test cache bypass run', Bypass);
  Expect<Boolean>(Pos('cache bypass: disabled', Bypass.Stdout) > 0).ToBe(True);
  Expect<Integer>(CountMarkerLines(Marker)).ToBe(3);
end;

procedure TTestCache.TestSourceUnitAndFlagsInvalidateFingerprint;
const
  UNIT_ONE = 'unit CacheFixtureUnit; interface const Value = 1; '
    + 'implementation end.'#10;
  UNIT_TWO = 'unit CacheFixtureUnit; interface const Value = 2; '
    + 'implementation end.'#10;
var
  CacheRoot, Marker, ProjectRoot: string;
  Environment: TStringArray;
  First, Hit, UnitChanged, FlagsChanged, SourceChanged: TLwptResult;
begin
  CacheRoot := FScratch + '/invalidation-cache';
  Marker := FScratch + '/invalidation-marker';
  ProjectRoot := FScratch + '/invalidation-project';
  RecursiveDelete(CacheRoot);
  WriteProject(ProjectRoot, MarkerProgram(0, True), UNIT_ONE);
  Environment := CacheEnvironment(CacheRoot, Marker);

  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot, Environment);
  RequireSuccess('invalidation seed', First);
  Hit := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot, Environment);
  RequireSuccess('invalidation hit', Hit);
  Expect<Boolean>(Pos('cache hit:', Hit.Stdout) > 0).ToBe(True);

  WriteTextFile(ProjectRoot + '/source/CacheFixtureUnit.pas', UNIT_TWO);
  UnitChanged := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('unit invalidation', UnitChanged);
  Expect<Boolean>(Pos('cache hit:', UnitChanged.Stdout) = 0).ToBe(True);

  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "test-cache-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[test]'#10
    + 'flags = ["-dCACHE_FLAG"]'#10);
  FlagsChanged := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('flags invalidation', FlagsChanged);
  Expect<Boolean>(Pos('cache hit:', FlagsChanged.Stdout) = 0).ToBe(True);

  WriteTextFile(ProjectRoot + '/tests/CacheFixture.Test.pas',
    MarkerProgram(0, True) + #10);
  SourceChanged := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('source invalidation', SourceChanged);
  Expect<Boolean>(Pos('cache hit:', SourceChanged.Stdout) = 0).ToBe(True);
end;

procedure TTestCache.TestImplicitRootUnitInvalidatesFingerprint;
const
  UNIT_ONE = 'unit CacheFixtureUnit; interface const Value = 1; '
    + 'implementation end.'#10;
  UNIT_TWO = 'unit CacheFixtureUnit; interface const Value = 2; '
    + 'implementation end.'#10;
var
  CacheRoot, Marker, ProjectRoot: string;
  Environment: TStringArray;
  First, Hit, IncludeChanged, UnitChanged: TLwptResult;
begin
  CacheRoot := FScratch + '/implicit-root-cache';
  Marker := FScratch + '/implicit-root-marker';
  ProjectRoot := FScratch + '/implicit-root-project';
  RecursiveDelete(CacheRoot);
  WriteProject(ProjectRoot, MarkerProgram(0, True));
  WriteTextFile(ProjectRoot + '/CacheFixtureUnit.pas', UNIT_ONE);
  WriteTextFile(ProjectRoot + '/RootValue.def', 'const RootValue = 1;'#10);
  WriteTextFile(ProjectRoot + '/tests/CacheFixture.Test.pas',
    StringReplace(MarkerProgram(0, True), 'var Lines:',
      '{$I RootValue.def}'#10'var Lines:', []));
  Environment := CacheEnvironment(CacheRoot, Marker);

  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('implicit root seed', First);
  Hit := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot, Environment);
  RequireSuccess('implicit root hit', Hit);
  Expect<Boolean>(Pos('cache hit:', Hit.Stdout) > 0).ToBe(True);

  WriteTextFile(ProjectRoot + '/RootValue.def', 'const RootValue = 2;'#10);
  IncludeChanged := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('implicit root include invalidation', IncludeChanged);
  Expect<Boolean>(Pos('cache hit:', IncludeChanged.Stdout) = 0).ToBe(True);

  WriteTextFile(ProjectRoot + '/CacheFixtureUnit.pas', UNIT_TWO);
  UnitChanged := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('implicit root unit invalidation', UnitChanged);
  Expect<Boolean>(Pos('cache hit:', UnitChanged.Stdout) = 0).ToBe(True);
end;

procedure TTestCache.TestConfiguredCompilerFileIsEffective;
var
  CacheRoot, ProjectRoot: string;
  Environment: TStringArray;
  First, Changed: TLwptResult;
begin
  CacheRoot := FScratch + '/configured-cfg-cache';
  ProjectRoot := FScratch + '/configured-cfg-project';
  RecursiveDelete(CacheRoot);
  RecursiveDelete(ProjectRoot);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "configured-cfg-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + '[lwpt]'#10
    + 'cfg-file = "config/custom.cfg"'#10);
  WriteTextFile(ProjectRoot + '/config/custom.cfg', '-dCACHE_CONFIGURED'#10);
  WriteTextFile(ProjectRoot + '/tests/Configured.Test.pas',
      'program Configured;'#10
    + '{$mode delphi}{$H+}'#10
    + '{$IFNDEF CACHE_CONFIGURED}{$ERROR configured cfg not loaded}{$ENDIF}'#10
    + 'begin end.'#10);
  Environment := CacheEnvironment(CacheRoot,
    FScratch + '/configured-cfg-marker');

  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('configured cfg seed', First);
  WriteTextFile(ProjectRoot + '/config/custom.cfg', '-dOTHER_CONFIGURATION'#10);
  Changed := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  Expect<Integer>(Changed.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('cache hit:', Changed.Stdout) = 0).ToBe(True);
  Expect<Boolean>(Pos('configured cfg not loaded', Changed.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestCache.TestBypassDoesNotCaptureCacheFingerprint;
var
  Environment: TStringArray;
  ProjectRoot, UnreadablePath: string;
  Bypass, Enabled: TLwptResult;
  FingerprintUnavailableExpected: Boolean;
  {$IFDEF UNIX}
  UnreadableDescriptor: THandle;
  {$ENDIF}
begin
  ProjectRoot := FScratch + '/bypass-fingerprint-project';
  WriteProject(ProjectRoot, MarkerProgram(0));
  UnreadablePath := ProjectRoot + '/source/Unused.pas';
  WriteTextFile(UnreadablePath, 'unit Unused; interface implementation end.');
  Environment := CacheEnvironment(FScratch + '/bypass-fingerprint-cache',
    FScratch + '/bypass-fingerprint-marker');
  FingerprintUnavailableExpected := False;
  {$IFDEF UNIX}
  if FpChmod(UnreadablePath, 0) <> 0 then
    raise Exception.Create('fixture: unreadable input chmod failed');
  UnreadableDescriptor := FileOpen(UnreadablePath, fmOpenRead);
  FingerprintUnavailableExpected := UnreadableDescriptor = THandle(-1);
  if UnreadableDescriptor <> THandle(-1) then FileClose(UnreadableDescriptor);
  {$ENDIF}
  try
    Bypass := RunLwpt(['test', '--verbose', '--jobs=1', '--no-cache'],
      ProjectRoot, Environment);
    Enabled := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
      Environment);
  finally
    {$IFDEF UNIX}
    FpChmod(UnreadablePath, &600);
    {$ENDIF}
  end;
  RequireSuccess('cache bypass without fingerprint', Bypass);
  Expect<Boolean>(Pos('cache bypass: disabled', Bypass.Stdout) > 0).ToBe(True);
  RequireSuccess('cache fail-open fingerprint', Enabled);
  {$IFDEF UNIX}
  if FingerprintUnavailableExpected then
    Expect<Boolean>(Pos('cache bypass: unavailable', Enabled.Stdout) > 0)
      .ToBe(True);
  {$ENDIF}
end;

procedure TTestCache.TestInventoryReusesExecutableButQueriesRegistrations;
var
  CacheRoot, Marker, ProjectRoot, ReferencePath: string;
  Environment: TStringArray;
  First, Second: TLwptResult;
  ReferenceAge: LongInt;
begin
  CacheRoot := FScratch + '/inventory-cache';
  Marker := FScratch + '/inventory-marker';
  ProjectRoot := FScratch + '/inventory-project';
  RecursiveDelete(CacheRoot);
  RecursiveDelete(ProjectRoot);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "inventory-cache-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["'
    + StringReplace(FRepositoryRoot + '/.lwpt/modules/testing/source', '\',
      '/', [rfReplaceAll]) + '"]'#10);
  WriteTextFile(ProjectRoot + '/tests/Inventory.Test.pas',
      'program Inventory;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils, TestingPascalLibrary;'#10
    + 'type TInventorySuite = class(TTestSuite)'#10
    + '  public procedure SetupTests; override; procedure TestOne; end;'#10
    + 'procedure TInventorySuite.TestOne; begin Expect<Integer>(1).ToBe(1); end;'#10
    + 'procedure TInventorySuite.SetupTests; begin Test(''one'', TestOne); end;'#10
    + 'var Lines: TStringList; Marker: string;'#10
    + 'begin'#10
    + '  Marker := GetEnvironmentVariable(''CACHE_EXEC_MARKER'');'#10
    + '  Lines := TStringList.Create;'#10
    + '  try if FileExists(Marker) then Lines.LoadFromFile(Marker); '
    + 'Lines.Add(''queried''); Lines.SaveToFile(Marker); finally Lines.Free end;'#10
    + '  TestRunnerProgram.AddSuite(TInventorySuite.Create(''inventory''));'#10
    + '  TestRunnerProgram.Run;'#10
    + 'end.'#10);
  Environment := CacheEnvironment(CacheRoot, Marker);

  First := RunLwpt(['test', 'tests/Inventory.Test.pas', '--inventory',
    '--jobs=1'], ProjectRoot, Environment);
  RequireSuccess('first inventory query', First);
  ReferencePath := FindOnlyFile(CacheRoot
    + '/build-results/refs/sha256');
  Expect<Boolean>(ReferencePath <> '').ToBe(True);
  ReferenceAge := FileAge(ReferencePath);
  Sleep(1100);
  Second := RunLwpt(['test', 'tests/Inventory.Test.pas', '--inventory',
    '--jobs=1'], ProjectRoot, Environment);
  RequireSuccess('second inventory query', Second);
  Expect<Boolean>(Pos('"suites":1,"cases":1', Second.Stdout) > 0).ToBe(True);
  Expect<Integer>(CountMarkerLines(Marker)).ToBe(2);
  Expect<Integer>(FileAge(ReferencePath)).ToBe(ReferenceAge);
end;

procedure TTestCache.TestCorruptArtifactIsRejectedAndRebuilt;
var
  ArtifactDigest, ArtifactPath, CacheRoot, ManifestDigest, ManifestPath,
    Marker, ProjectRoot, ReferencePath: string;
  Environment: TStringArray;
  First, Rebuilt: TLwptResult;
begin
  CacheRoot := FScratch + '/corrupt-cache';
  Marker := FScratch + '/corrupt-marker';
  ProjectRoot := FScratch + '/corrupt-project';
  RecursiveDelete(CacheRoot);
  WriteProject(ProjectRoot, MarkerProgram(0));
  Environment := CacheEnvironment(CacheRoot, Marker);
  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot, Environment);
  RequireSuccess('corrupt cache seed', First);

  ReferencePath := FindOnlyFile(CacheRoot
    + '/build-results/refs/sha256');
  ManifestDigest := Trim(ReadBinaryFile(ReferencePath));
  ManifestPath := ObjectPath(CacheRoot, ManifestDigest);
  ArtifactDigest := ManifestField(ReadBinaryFile(ManifestPath),
    'artifact_digest');
  ArtifactPath := ObjectPath(CacheRoot, ArtifactDigest);
  WriteTextFile(ArtifactPath, 'corrupt');

  Rebuilt := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  RequireSuccess('corrupt cache rebuild', Rebuilt);
  Expect<Boolean>(Pos('cache corruption: artifact-verification-failed',
    Rebuilt.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('cache stored:', Rebuilt.Stdout) > 0).ToBe(True);
  Expect<Integer>(CountMarkerLines(Marker)).ToBe(2);
end;

procedure TTestCache.TestFailedCompileNeverBecomesHit;
var
  CacheRoot, ProjectRoot: string;
  Environment: TStringArray;
  First, Second: TLwptResult;
begin
  CacheRoot := FScratch + '/compile-failure-cache';
  ProjectRoot := FScratch + '/compile-failure-project';
  RecursiveDelete(CacheRoot);
  WriteProject(ProjectRoot,
    'program Broken; begin this is not valid pascal end.'#10);
  Environment := CacheEnvironment(CacheRoot,
    FScratch + '/compile-failure-marker');

  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot, Environment);
  Expect<Integer>(First.ExitCode).ToBe(1);
  Second := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  Expect<Integer>(Second.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('cache hit:', Second.Stdout) = 0).ToBe(True);
  Expect<Integer>(CountFiles(CacheRoot + '/build-results/refs')).ToBe(0);
end;

procedure TTestCache.TestFailingExecutionIsAlwaysFresh;
var
  CacheRoot, Marker, ProjectRoot: string;
  Environment: TStringArray;
  First, Second: TLwptResult;
begin
  CacheRoot := FScratch + '/run-failure-cache';
  Marker := FScratch + '/run-failure-marker';
  ProjectRoot := FScratch + '/run-failure-project';
  RecursiveDelete(CacheRoot);
  WriteProject(ProjectRoot, MarkerProgram(7));
  Environment := CacheEnvironment(CacheRoot, Marker);

  First := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot, Environment);
  Expect<Integer>(First.ExitCode).ToBe(1);
  Second := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment);
  Expect<Integer>(Second.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('cache hit:', Second.Stdout) > 0).ToBe(True);
  Expect<Integer>(CountMarkerLines(Marker)).ToBe(2);
end;

procedure TTestCache.TestConcurrentMissCompilesOnce;
var
  CacheRoot, Combined, Marker, ProjectRoot: string;
  Environment: TStringArray;
  First, Second: TLWPTThreadRun;
begin
  CacheRoot := FScratch + '/concurrent-cache';
  Marker := FScratch + '/concurrent-marker';
  ProjectRoot := FScratch + '/concurrent-project';
  RecursiveDelete(CacheRoot);
  ForceDirectories(Marker);
  WriteProject(ProjectRoot, ConcurrentMarkerProgram);
  Environment := CacheEnvironment(CacheRoot, Marker);
  First := TLWPTThreadRun.Create(ProjectRoot, Environment);
  Second := TLWPTThreadRun.Create(ProjectRoot, Environment);
  try
    First.Start;
    Second.Start;
    First.WaitFor;
    Second.WaitFor;
    RequireSuccess('first concurrent test run', First.RunResult);
    RequireSuccess('second concurrent test run', Second.RunResult);
    Combined := First.RunResult.Stdout + Second.RunResult.Stdout;
    Expect<Integer>(CountSubstring(Combined, 'cache stored:')).ToBe(1);
    Expect<Boolean>((Pos('cache wait hit:', Combined) > 0)
      or (Pos('cache hit:', Combined) > 0)).ToBe(True);
    Expect<Integer>(CountFiles(Marker)).ToBe(2);
  finally
    Second.Free;
    First.Free;
  end;
end;

procedure CollectExecutables(const ARoot, AProgram: string;
  AFound: TStrings);
var
  Search: TSearchRec;
  Base: string;
begin
  if not DirectoryExists(ARoot) then Exit;
  Base := IncludeTrailingPathDelimiter(ARoot);
  if FindFirst(Base + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        CollectExecutables(Base + Search.Name, AProgram, AFound)
      else if (Search.Name = AProgram)
        or (Search.Name = AProgram + '.exe') then
        AFound.Add(Base + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function ExitProgram(const AName: string; const AExitCode: Integer): string;
begin
  Result := 'program ' + AName + ';'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin'#10
    + '  WriteLn(''' + AName + ' exits ' + IntToStr(AExitCode) + ''');'#10
    + '  Halt(' + IntToStr(AExitCode) + ');'#10
    + 'end.'#10;
end;

procedure TTestCache.TestPassingRerunRemovesSupersededExecutable;
var
  CacheRoot, Marker, ProjectRoot, FailedSession: string;
  Environment: TStringArray;
  Failed, Passed: TLwptResult;
  Rerun, Unselected: TStringList;
begin
  CacheRoot := FScratch + '/superseded-cache';
  Marker := FScratch + '/superseded-marker';
  ProjectRoot := FScratch + '/superseded-project';
  RecursiveDelete(CacheRoot);
  RecursiveDelete(ProjectRoot);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "superseded-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(ProjectRoot + '/tests/Rerun.Test.pas', ExitProgram('Rerun', 1));
  WriteTextFile(ProjectRoot + '/tests/Unselected.Test.pas',
    ExitProgram('Unselected', 1));
  Environment := CacheEnvironment(CacheRoot, Marker);
  { Staging must land in the project's default sessions root, which the
    assertions below inspect. }
  SetLength(Environment, Length(Environment) + 1);
  Environment[High(Environment)] := BUILD_SESSION_DIR_ENV + '=';

  Failed := RunLwpt(['test', '--jobs=1'], ProjectRoot, Environment);
  Expect<Integer>(Failed.ExitCode).ToBe(1);
  { Both programs compiled and failed at run time, so each left a retained
    executable for the rerun to supersede. }
  Rerun := TStringList.Create;
  try
    CollectExecutables(ProjectRoot + '/.lwpt/sessions', 'Rerun.Test', Rerun);
    Expect<Integer>(Rerun.Count).ToBe(1);
    Rerun.Clear;
    CollectExecutables(ProjectRoot + '/.lwpt/sessions', 'Unselected.Test',
      Rerun);
    Expect<Integer>(Rerun.Count).ToBe(1);
  finally
    Rerun.Free;
  end;
  WriteTextFile(ProjectRoot + '/tests/Rerun.Test.pas', ExitProgram('Rerun', 0));
  Passed := RunLwpt(['test', '--jobs=1', 'tests/Rerun.Test.pas'],
    ProjectRoot, Environment);
  RequireSuccess('passing selected rerun', Passed);

  Rerun := TStringList.Create;
  Unselected := TStringList.Create;
  try
    CollectExecutables(ProjectRoot + '/.lwpt/sessions', 'Rerun.Test', Rerun);
    CollectExecutables(ProjectRoot + '/.lwpt/sessions', 'Unselected.Test',
      Unselected);
    { The passing rerun superseded the failed build of the program it ran,
      so no executable of it is left to be run by hand. The program it did
      not select keeps its failed build, and the failed session keeps its
      diagnosis. }
    Expect<Integer>(Rerun.Count).ToBe(0);
    Expect<Integer>(Unselected.Count).ToBe(1);
    FailedSession := Unselected[0];
    while (ExtractFileName(ExtractFileDir(FailedSession)) <> 'sessions')
      and (FailedSession <> ExtractFileDir(FailedSession)) do
      FailedSession := ExtractFileDir(FailedSession);
    Expect<Boolean>(FileExists(FailedSession + '/failure.txt')).ToBe(True);
    Expect<Boolean>(FileExists(FailedSession + '/session.state')).ToBe(True);
    Expect<Boolean>(DirectoryExists(FailedSession + '/logs')).ToBe(True);
  finally
    Unselected.Free;
    Rerun.Free;
  end;
end;

{ A project whose only test program prints the constant V that it reads
  through a search directory only AManifestTail (or a cfg file the caller
  writes) names. AEditedPath starts with AInitial. }
procedure TTestCache.WriteSearchProject(const AProjectRoot, AManifestTail,
  AProgramHead, AEditedPath, AInitial: string);
begin
  RecursiveDelete(AProjectRoot);
  WriteTextFile(AProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "search-directory-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + AManifestTail);
  WriteTextFile(AProjectRoot + '/' + AEditedPath, AInitial);
  WriteTextFile(AProjectRoot + '/tests/Search.Test.pas',
      'program Search;'#10
    + '{$mode delphi}{$H+}'#10
    + AProgramHead
    + 'begin'#10
    + '  WriteLn(''SEARCH V='', V);'#10
    + 'end.'#10);
end;

{ The stable rerun must be a cache hit that prints V=1, which proves the
  compile read AEditedPath (a full path) through the search directory under
  test. After AEditedPath changes to AEdited (V=2), the next run must
  recompile, and the run after it hits the cache again: an unchanged tree
  keeps its fingerprint. Every run adds AExtraEnvironment. }
procedure TTestCache.RequireEditRecompiles(const ALabel, AProjectRoot,
  AEditedPath, AEdited: string; const AExtraEnvironment: array of string);
var
  Environment: TStringArray;
  Seed, Hit, Edited, Rerun: TLwptResult;
  i: Integer;
begin
  RecursiveDelete(FScratch + '/' + ALabel + '-cache');
  Environment := CacheEnvironment(FScratch + '/' + ALabel + '-cache',
    FScratch + '/' + ALabel + '-marker');
  for i := 0 to High(AExtraEnvironment) do
  begin
    SetLength(Environment, Length(Environment) + 1);
    Environment[High(Environment)] := AExtraEnvironment[i];
  end;
  Seed := RunLwpt(['test', '--verbose', '--jobs=1'], AProjectRoot,
    Environment);
  RequireSuccess(ALabel + ' seed', Seed);
  Expect<Boolean>(Pos('cache miss: no-result', Seed.Stdout) > 0).ToBe(True);
  Hit := RunLwpt(['test', '--verbose', '--jobs=1'], AProjectRoot,
    Environment);
  RequireSuccess(ALabel + ' stable rerun', Hit);
  Expect<Boolean>(Pos('cache hit:', Hit.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('SEARCH V=1', Hit.Stdout) > 0).ToBe(True);

  WriteTextFile(AEditedPath, AEdited);
  Edited := RunLwpt(['test', '--verbose', '--jobs=1'], AProjectRoot,
    Environment);
  RequireSuccess(ALabel + ' edited run', Edited);
  Expect<Boolean>(Pos('cache hit:', Edited.Stdout) = 0).ToBe(True);
  Expect<Boolean>(Pos('SEARCH V=2', Edited.Stdout) > 0).ToBe(True);

  Rerun := RunLwpt(['test', '--verbose', '--jobs=1'], AProjectRoot,
    Environment);
  RequireSuccess(ALabel + ' edited rerun', Rerun);
  Expect<Boolean>(Pos('cache hit:', Rerun.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('SEARCH V=2', Rerun.Stdout) > 0).ToBe(True);
end;

procedure TTestCache.TestFlagUnitDirectoryInvalidatesFingerprint;
var
  ProjectRoot: string;
begin
  ProjectRoot := FScratch + '/flag-unit-directory';
  { A unit directory that only a [test] flag names. }
  WriteSearchProject(ProjectRoot,
    '[test]'#10'flags = ["-Fuextra"]'#10, 'uses Extra;'#10,
    'extra/Extra.pas',
    'unit Extra; interface const V = 1; implementation end.'#10);
  RequireEditRecompiles('flag-unit-directory', ProjectRoot,
    ProjectRoot + '/extra/Extra.pas',
    'unit Extra; interface const V = 2; implementation end.'#10, []);
end;

procedure TTestCache.TestProfileIncludeDirectoryInvalidatesFingerprint;
var
  ProjectRoot: string;
begin
  ProjectRoot := FScratch + '/profile-include-directory';
  { An include directory that only the compiler profile's args name. }
  WriteSearchProject(ProjectRoot,
      '[compiler]'#10
    + 'default = "pinned"'#10
    + '[compiler.profiles.pinned]'#10
    + 'driver = "fpc"'#10
    + 'args = ["-Fiincs"]'#10,
    '{$I Value.inc}'#10, 'incs/Value.inc', 'const V = 1;'#10);
  RequireEditRecompiles('profile-include-directory', ProjectRoot,
    ProjectRoot + '/incs/Value.inc', 'const V = 2;'#10, []);
end;

procedure TTestCache.TestConfigurationIncludeDirectoryInvalidatesFingerprint;
var
  ProjectRoot: string;
begin
  ProjectRoot := FScratch + '/cfg-include-directory';
  { An include directory that only the cfg file names: its -Fu lines reach
    the request's unit paths, its -Fi lines do not. }
  WriteSearchProject(ProjectRoot,
    '[lwpt]'#10'cfg-file = "custom.cfg"'#10, '{$I Value.inc}'#10,
    'incs/Value.inc', 'const V = 1;'#10);
  WriteTextFile(ProjectRoot + '/custom.cfg', '-Fiincs'#10);
  RequireEditRecompiles('cfg-include-directory', ProjectRoot,
    ProjectRoot + '/incs/Value.inc', 'const V = 2;'#10, []);
end;

procedure TTestCache.TestEnvironmentMacroDirectoryInvalidatesFingerprint;
var
  External, ProjectRoot: string;
begin
  ProjectRoot := FScratch + '/environment-macro-directory';
  External := FScratch + '/environment-macro-includes';
  { FPC replaces "$NAME$" in a search option with that environment
    variable, a set but empty one included, so the include directory lies
    outside the project. }
  WriteSearchProject(ProjectRoot,
    '[test]'#10
    + 'flags = ["-Fi$LWPT_FIXTURE_EMPTY$$LWPT_FIXTURE_INCLUDES$"]'#10,
    '{$I Value.inc}'#10, 'source/Unused.pas',
    'unit Unused; interface implementation end.'#10);
  RecursiveDelete(External);
  WriteTextFile(External + '/Value.inc', 'const V = 1;'#10);
  RequireEditRecompiles('environment-macro-directory', ProjectRoot,
    External + '/Value.inc', 'const V = 2;'#10,
    ['LWPT_FIXTURE_EMPTY=', 'LWPT_FIXTURE_INCLUDES=' + External]);
end;

procedure TTestCache.TestConfigurationDirectoryIncludeInvalidatesFingerprint;
var
  ProjectRoot: string;
begin
  ProjectRoot := FScratch + '/cfgdir-include';
  { The profile passes a response file. It adds a #CFGDIR directory and
    includes paths.cfg, which FPC finds there; only that file names the
    include directory. }
  WriteSearchProject(ProjectRoot,
      '[compiler]'#10
    + 'default = "pinned"'#10
    + '[compiler.profiles.pinned]'#10
    + 'driver = "fpc"'#10
    + 'args = ["@opts.rsp"]'#10,
    '{$I Value.inc}'#10, 'incs/Value.inc', 'const V = 1;'#10);
  WriteTextFile(ProjectRoot + '/opts.rsp',
    '#CFGDIR cfgs'#10'#INCLUDE paths.cfg'#10);
  WriteTextFile(ProjectRoot + '/cfgs/paths.cfg', '-Fiincs'#10);
  RequireEditRecompiles('cfgdir-include', ProjectRoot,
    ProjectRoot + '/incs/Value.inc', 'const V = 2;'#10, []);
end;

procedure TTestCache.TestUnboundedSearchEntryIsNeverReused;
var
  Environment: TStringArray;
  ProjectRoot: string;
  Run: TLwptResult;
  Attempt: Integer;
begin
  ProjectRoot := FScratch + '/unbounded-search-entry';
  { "incs/$FPCTARGET/../../incs" resolves to incs/ only once the compiler
    names its target; no fixed directory is known to hold it, so the
    program compiles every time, and sees each edit. }
  WriteSearchProject(ProjectRoot,
    '[test]'#10'flags = ["-Fiincs/$FPCTARGET/../../incs"]'#10,
    '{$I Value.inc}'#10, 'incs/Value.inc', 'const V = 1;'#10);
  RecursiveDelete(FScratch + '/unbounded-search-entry-cache');
  Environment := CacheEnvironment(FScratch + '/unbounded-search-entry-cache',
    FScratch + '/unbounded-search-entry-marker');
  for Attempt := 1 to 3 do
  begin
    if Attempt = 3 then
      WriteTextFile(ProjectRoot + '/incs/Value.inc', 'const V = 2;'#10);
    Run := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
      Environment);
    RequireSuccess('unbounded search entry run ' + IntToStr(Attempt), Run);
    Expect<Boolean>(Pos('cache bypass: unavailable '
      + '(ELWPTUnboundedCompilerInputs', Run.Stdout) > 0).ToBe(True);
    Expect<Boolean>(Pos('cache hit:', Run.Stdout) = 0).ToBe(True);
    if Attempt = 3 then
      Expect<Boolean>(Pos('SEARCH V=2', Run.Stdout) > 0).ToBe(True)
    else
      Expect<Boolean>(Pos('SEARCH V=1', Run.Stdout) > 0).ToBe(True);
  end;
end;

{$IFDEF UNIX}
procedure TTestCache.TestFifoInUnitDirectoryDoesNotHangCachedRun;
var
  Environment: TStringArray;
  ProjectRoot: string;
  Seed, Hit: TLwptResult;
begin
  ProjectRoot := FScratch + '/fifo-unit-directory';
  { The fingerprint walks every file in a unit directory. A FIFO there has
    no writer, so opening it with a blocking open would hang the run; the
    fingerprint records it by type instead, and keeps doing so. }
  WriteSearchProject(ProjectRoot, '', 'const V = 1;'#10, 'source/Unused.pas',
    'unit Unused; interface implementation end.'#10);
  Expect<Integer>(FpMkfifo(ProjectRoot + '/source/pipe', &600)).ToBe(0);
  RecursiveDelete(FScratch + '/fifo-unit-directory-cache');
  Environment := CacheEnvironment(FScratch + '/fifo-unit-directory-cache',
    FScratch + '/fifo-unit-directory-marker');
  Seed := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment, FIFO_RUN_TIMEOUT_MILLISECONDS);
  RequireSuccess('FIFO unit directory seed', Seed);
  Expect<Boolean>(Pos('cache miss: no-result', Seed.Stdout) > 0).ToBe(True);
  Hit := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment, FIFO_RUN_TIMEOUT_MILLISECONDS);
  RequireSuccess('FIFO unit directory rerun', Hit);
  Expect<Boolean>(Pos('cache hit:', Hit.Stdout) > 0).ToBe(True);
end;

procedure TTestCache.TestConfigurationSwappedForFifoDoesNotHangCachedRun;
var
  Environment: TStringArray;
  ProjectRoot: string;
  Run: TLwptResult;
begin
  ProjectRoot := FScratch + '/cfg-fifo-cached';
  { A replaces the cfg file with a FIFO that has no writer. B compiles from
    the run's copy, but its cache fingerprint hashes the live cfg file; that
    read must not block, and the run's input check then voids B. }
  RecursiveDelete(ProjectRoot);
  WriteTextFile(ProjectRoot + '/lwpt.toml',
      '[package]'#10
    + 'name = "cfg-fifo-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10);
  WriteTextFile(ProjectRoot + '/lwpt.cfg', '# fixture configuration'#10);
  WriteTextFile(ProjectRoot + '/tests/A.Test.pas',
      'program A;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses BaseUnix, SysUtils;'#10
    + 'begin'#10
    + '  if not DeleteFile(''' + ProjectRoot + '/lwpt.cfg'') then Halt(2);'#10
    + '  if FpMkfifo(''' + ProjectRoot + '/lwpt.cfg'', &600) <> 0 then '
    + 'Halt(3);'#10
    + 'end.'#10);
  WriteTextFile(ProjectRoot + '/tests/B.Test.pas',
    'program B;'#10'begin'#10'end.'#10);
  RecursiveDelete(FScratch + '/cfg-fifo-cached-cache');
  Environment := CacheEnvironment(FScratch + '/cfg-fifo-cached-cache',
    FScratch + '/cfg-fifo-cached-marker');
  Run := RunLwpt(['test', '--verbose', '--jobs=1'], ProjectRoot,
    Environment, FIFO_RUN_TIMEOUT_MILLISECONDS);
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('tests/A.Test.pas ... pass', Run.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('tests/B.Test.pas ... VOID (compiler inputs changed '
    + 'after this test run started (lwpt.cfg)', Run.Stdout) > 0).ToBe(True);
end;
{$ENDIF}

procedure TTestCache.SetupTests;
begin
  Test('equivalent worktrees compile once and execute every run',
    TestEquivalentWorktreesReuseCompileAndRunFresh);
  Test('source, transitive unit and test flags invalidate the fingerprint',
    TestSourceUnitAndFlagsInvalidateFingerprint);
  Test('implicit project-root units invalidate the fingerprint',
    TestImplicitRootUnitInvalidatesFingerprint);
  Test('configured compiler files drive compilation and invalidation',
    TestConfiguredCompilerFileIsEffective);
  Test('cache bypass does not capture a cache fingerprint',
    TestBypassDoesNotCaptureCacheFingerprint);
  Test('inventory reuses the executable but queries registrations every time',
    TestInventoryReusesExecutableButQueriesRegistrations);
  Test('corrupt cached artifacts are rejected and rebuilt',
    TestCorruptArtifactIsRejectedAndRebuilt);
  Test('failed compiles never become cache hits',
    TestFailedCompileNeverBecomesHit);
  Test('failing execution is never cached',
    TestFailingExecutionIsAlwaysFresh);
  Test('concurrent identical misses compile once',
    TestConcurrentMissCompilesOnce);
  Test('a passing rerun removes the superseded failed executable',
    TestPassingRerunRemovesSupersededExecutable);
  Test('a unit directory named by a test flag invalidates the fingerprint',
    TestFlagUnitDirectoryInvalidatesFingerprint);
  Test('an include directory named by the compiler profile invalidates the '
    + 'fingerprint', TestProfileIncludeDirectoryInvalidatesFingerprint);
  Test('an include directory named only by the cfg file invalidates the '
    + 'fingerprint', TestConfigurationIncludeDirectoryInvalidatesFingerprint);
  Test('an include directory behind an environment macro invalidates the '
    + 'fingerprint', TestEnvironmentMacroDirectoryInvalidatesFingerprint);
  Test('an include directory named by a #CFGDIR-found file invalidates the '
    + 'fingerprint', TestConfigurationDirectoryIncludeInvalidatesFingerprint);
  Test('a search entry no fixed directory holds is never reused',
    TestUnboundedSearchEntryIsNeverReused);
  {$IFDEF UNIX}
  Test('a FIFO in a unit directory neither hangs nor defeats the cache',
    TestFifoInUnitDirectoryDoesNotHangCachedRun);
  Test('a cfg file swapped for a FIFO does not hang a cached run',
    TestConfigurationSwappedForFifoDoesNotHangCachedRun);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TTestCache.Create('test executable cache'));
  TestRunnerProgram.Run;
end.
