{ LWPT.Command.Testing — test subcommand entrypoint. }
unit LWPT.Command.Testing;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

function CmdTest(const AManifestPath: string; AIncludeE2E: Boolean): Integer;

implementation

uses
  Classes,
  Process,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest;

{
  CmdTest itself adds nothing to the search path beyond what the
  manifest's units + the modules dir already provide — the testing
  library is just a dep.
  =========================================================================== }

{ Standard set of directories the discovery walks must NOT descend into.
  .lwpt holds toolkit state; build is FPC output (per the build-system
  contract); .git is version control. Add to this list with care — every
  exclusion is a place where tests / sources can hide silently. }
function IsExcludedDir(const AName: string): Boolean; inline;
begin
  Result := (AName = LWPT_DIR) or (AName = 'build') or (AName = '.git');
end;

procedure CollectTestFiles(const ADir: string; AList: TStringList);
var SR: TSearchRec; Base: string;
begin
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if not IsExcludedDir(SR.Name) then
          CollectTestFiles(Base + SR.Name, AList);
      end
      else if (Length(SR.Name) > 9)
        and SameText(Copy(SR.Name, Length(SR.Name) - 8, 9), '.Test.pas') then
        AList.Add(Base + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ Per-test-source build dir. Avoids dumping .o / .ppu / executables
  next to the .Test.pas under source/ or tests/. Each test gets its
  own dir so siblings with the same filename in different paths
  (source/Foo.Test.pas vs tests/integration/Foo.Test.pas) cannot
  collide. The dir name is the relative path with separators flattened. }

function RunBinary(const ABinPath: string): Integer;
var P: TProcess;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := ABinPath;
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

{ Test discovery + run policy.

  Default tier skips anything under tests/e2e/ (network-touching). The
  --tier=e2e flag passed to lwpt test wires AIncludeE2E=True, which
  bypasses the skip. The other tiers (unit + integration) always run.
  See docs/testing.md for the policy table. }
function IsE2ETestPath(const APath: string): Boolean; inline;
var Normalised: string;
begin
  Normalised := StringReplace(APath, '\', '/', [rfReplaceAll]);
  Result := (Pos('/tests/e2e/', Normalised) > 0)
         or (Pos('tests/e2e/', Normalised) = 1);
end;

function CmdTest(const AManifestPath: string; AIncludeE2E: Boolean): Integer;
const
  TESTS_SUPPORT_DIR = 'tests/support';
var
  Man : TManifest;
  Tests : TStringList;
  UnitPaths : array of string;
  ModulesRoot : string;
  i, n, Passed, Failed, Skipped, CompileFailed, Code : Integer;
  Bin : string;
begin
  Man := LoadManifest(AManifestPath);

  { [pretest] hooks fire before test discovery. Same conceptual
    role as [prebuild] but tied to test compilation; ADR-0011 lets
    an entry be authored in BOTH [prebuild] AND [pretest] when a
    project-level prep step needs to run for either phase (the
    staleness gate ensures it runs at most once per source edit). }
  RunHooks('pretest', Man.PreTest);

  { Per ADR-0015, TestingPascalLibrary is consumed via the `testing`
    workspace package — no extrude step here. The modules dir + each
    workspace package's source/ are already on the cfg's -Fu / -Fi
    paths courtesy of CmdInstall + WriteCfg. }
  ModulesRoot := ResolveModulesDir(Man);

  SetLength(UnitPaths, 0);
  for i := 0 to High(Man.Units) do
  begin
    n := Length(UnitPaths); SetLength(UnitPaths, n + 1);
    UnitPaths[n] := Man.Units[i];
  end;
  n := Length(UnitPaths); SetLength(UnitPaths, n + 1);
  UnitPaths[n] := ModulesRoot;
  if DirectoryExists(TESTS_SUPPORT_DIR) then
  begin
    n := Length(UnitPaths); SetLength(UnitPaths, n + 1);
    UnitPaths[n] := TESTS_SUPPORT_DIR;
  end;

  Tests := TStringList.Create;
  try
    for i := 0 to High(Man.Units) do
      CollectTestFiles(Man.Units[i], Tests);
    CollectTestFiles('.', Tests);

    { dedupe: a unit dir under '.' is walked twice — collapse by
      canonical absolute path }
    for i := 0 to Tests.Count - 1 do
      Tests[i] := ExpandFileName(Tests[i]);
    Tests.Sort;
    i := Tests.Count - 1;
    while i > 0 do
    begin
      if Tests[i] = Tests[i - 1] then Tests.Delete(i);
      Dec(i);
    end;

    if Tests.Count = 0 then
    begin
      WriteLn('no *.Test.pas files found');
      Exit(0);
    end;

    WriteLn('discovered ', Tests.Count, ' test file(s)');
    if not AIncludeE2E then
      WriteLn('  (e2e tier skipped; pass --tier=e2e to include)');
    Passed := 0; Failed := 0; Skipped := 0; CompileFailed := 0;
    for i := 0 to Tests.Count - 1 do
    begin
      if (not AIncludeE2E) and IsE2ETestPath(Tests[i]) then
      begin
        WriteLn('  ', ExtractFileName(Tests[i]), ' ... skipped (e2e tier)');
        Inc(Skipped);
        Continue;
      end;
      Write('  ', ExtractFileName(Tests[i]), ' ... ');
      if not CompilePascal(Tests[i], UnitPaths, Bin) then
      begin
        WriteLn('COMPILE FAILED');
        Inc(CompileFailed);
        Continue;
      end;
      Code := RunBinary(Bin);
      if Code = 0 then
      begin
        WriteLn('pass');
        Inc(Passed);
      end
      else
      begin
        WriteLn('FAIL (exit ', Code, ')');
        Inc(Failed);
      end;
    end;

    WriteLn;
    Write(Passed, ' passed, ', Failed, ' failed, ',
          CompileFailed, ' did not compile');
    if Skipped > 0 then
      Write(', ', Skipped, ' skipped');
    WriteLn;
    if (Failed = 0) and (CompileFailed = 0) then
      Result := 0
    else
      Result := 1;
  finally
    Tests.Free;
  end;

  { [posttest] hooks fire after the test suite finishes regardless
    of pass/fail — handy for coverage upload, test-result archival,
    etc. The function's Result (0 = all pass) is set above and
    propagates to the caller's exit code unmodified. }
  RunHooks('posttest', Man.PostTest);
end;

end.
