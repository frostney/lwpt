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
  end;

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
  FResult := RunLwpt(['test', '--verbose', '--jobs=1'], FProjectRoot,
    FEnvironment);
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
end;

begin
  TestRunnerProgram.AddSuite(TTestCache.Create('test executable cache'));
  TestRunnerProgram.Run;
end.
