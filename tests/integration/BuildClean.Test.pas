{ BuildClean.Test — `lwpt build --clean` artefact sweep.

  Contract under test:

    build --clean   sweeps FPC intermediate artefacts (.ppu/.o/.or/
                    .res/.reslst) out of the WHOLE build/ tree —
                    including nested dirs and artefacts belonging to
                    units other than the target's own source —
                    before compiling, and still builds successfully
    build --clean   leaves non-artefact files under build/ alone
    build --clean   with no build/ dir at all succeeds (nothing to
                    clean is not an error)

  Goes through the real binary via Tests.LwptSubprocess so the flag
  parsing AND the sweep ordering inside CmdBuild are both covered.
  The planted artefact files are empty decoys: FPC never reads them
  because -B forces a full rebuild — the test only checks they are
  gone afterwards. }

program BuildClean.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess;

type
  TBuildClean = class(TTestSuite)
  private
    FScratch: string;
    procedure WipeOutputs;
    procedure PlantDecoys;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestCleanSweepsArtefactsEverywhereUnderBuild;
    procedure TestCleanKeepsNonArtefactFiles;
    procedure TestCleanWithoutBuildDirSucceeds;
  end;

procedure WriteTextFile(const APath, AContent: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure RecursiveDelete(const APath: string);
var
  SR: TSearchRec;
  Base: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
          RecursiveDelete(Base + SR.Name)
        else
          DeleteFile(Base + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
end;

procedure TBuildClean.BeforeAll;
const
  TRIVIAL = 'begin'#10'end.'#10;
begin
  FScratch := ExpandFileName(
    GetCurrentDir + '/build/tests/tmp/build-clean');
  RecursiveDelete(FScratch);

  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "buildclean"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "src/alpha.pas", output = "build/alpha" }'#10);
  WriteTextFile(FScratch + '/src/alpha.pas', 'program alpha;'#10 + TRIVIAL);
end;

procedure TBuildClean.WipeOutputs;
begin
  RecursiveDelete(FScratch + '/build');
end;

{ Stale artefacts a previous FPC run could have left: the target's own,
  a dependency unit's, and one in a nested dir — the old per-target
  delete only ever caught the first. }
procedure TBuildClean.PlantDecoys;
begin
  WriteTextFile(FScratch + '/build/alpha.ppu', '');
  WriteTextFile(FScratch + '/build/SomeDep.ppu', '');
  WriteTextFile(FScratch + '/build/SomeDep.o', '');
  WriteTextFile(FScratch + '/build/nested/Other.or', '');
  WriteTextFile(FScratch + '/build/nested/Other.reslst', '');
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TBuildClean.TestCleanSweepsArtefactsEverywhereUnderBuild;
var R: TLwptResult;
begin
  WipeOutputs;
  PlantDecoys;
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  { every planted decoy is gone, not just the target's own }
  Expect<Boolean>(FileExists(FScratch + '/build/SomeDep.ppu')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/build/SomeDep.o')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/build/nested/Other.or'))
    .ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/build/nested/Other.reslst'))
    .ToBe(False);
  { the sweep reports itself }
  Expect<Boolean>(Pos('clean: removed', R.Stdout) > 0).ToBe(True);
end;

procedure TBuildClean.TestCleanKeepsNonArtefactFiles;
var R: TLwptResult;
begin
  WipeOutputs;
  WriteTextFile(FScratch + '/build/keep.txt', 'not an artefact'#10);
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/build/keep.txt')).ToBe(True);
end;

procedure TBuildClean.TestCleanWithoutBuildDirSucceeds;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', '--clean'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(Pos('clean: no FPC artefacts', R.Stdout) > 0).ToBe(True);
end;

procedure TBuildClean.SetupTests;
begin
  Test('build --clean sweeps artefacts across the whole build/ tree',
    TestCleanSweepsArtefactsEverywhereUnderBuild);
  Test('build --clean keeps non-artefact files under build/',
    TestCleanKeepsNonArtefactFiles);
  Test('build --clean with no build/ dir still succeeds',
    TestCleanWithoutBuildDirSucceeds);
end;

begin
  TestRunnerProgram.AddSuite(TBuildClean.Create(
    'build: --clean artefact sweep'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
