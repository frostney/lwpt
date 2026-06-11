{ BuildMultiTarget.Test — `lwpt build` with more than one named target.

  Contract under test:

    lwpt build <a> <b>   builds BOTH named targets (historically the
                         second name was silently dropped)
    lwpt build <a> <x>   where <x> names no target: exits 1, names the
                         unknown target on stderr, and builds NOTHING
                         (names are validated before any compile runs)
    lwpt build           (no names) still builds every target

  Goes through the real binary via Tests.LwptSubprocess because the
  defect spans the CLI positional handling AND the CmdBuild loop —
  an API-only test would miss the argv half. The scratch project's
  targets are three trivial one-line programs so each fpc run is
  fast and has no dependencies. }

program BuildMultiTarget.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

type
  TBuildMultiTarget = class(TTestSuite)
  private
    FScratch: string;
    procedure WipeOutputs;
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestTwoNamedTargetsBuildBoth;
    procedure TestUnknownTargetNameFailsBeforeBuildingAnything;
    procedure TestNoNamesStillBuildsAllTargets;
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

procedure TBuildMultiTarget.BeforeAll;
const
  TRIVIAL = 'begin'#10'end.'#10;
begin
  FScratch := ExpandFileName(
    GetCurrentDir + '/build/tests/tmp/build-multi-target');
  RecursiveDelete(FScratch);

  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "multitarget"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[build]'#10
    + 'alpha = { source = "src/alpha.pas", output = "build/alpha" }'#10
    + 'beta = { source = "src/beta.pas", output = "build/beta" }'#10
    + 'gamma = { source = "src/gamma.pas", output = "build/gamma" }'#10);
  WriteTextFile(FScratch + '/src/alpha.pas', 'program alpha;'#10 + TRIVIAL);
  WriteTextFile(FScratch + '/src/beta.pas',  'program beta;'#10  + TRIVIAL);
  WriteTextFile(FScratch + '/src/gamma.pas', 'program gamma;'#10 + TRIVIAL);
end;

procedure TBuildMultiTarget.WipeOutputs;
begin
  RecursiveDelete(FScratch + '/build');
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TBuildMultiTarget.TestTwoNamedTargetsBuildBoth;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'beta'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  { The un-named third target stays un-built. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/gamma')))
    .ToBe(False);
end;

procedure TBuildMultiTarget.TestUnknownTargetNameFailsBeforeBuildingAnything;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build', 'alpha', 'no-such-target'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('no-such-target', R.Stderr) > 0).ToBe(True);
  { Names are validated up front — a typo must not half-build. }
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(False);
end;

procedure TBuildMultiTarget.TestNoNamesStillBuildsAllTargets;
var R: TLwptResult;
begin
  WipeOutputs;
  R := RunLwpt(['build'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/alpha')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/beta')))
    .ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/gamma')))
    .ToBe(True);
end;

procedure TBuildMultiTarget.SetupTests;
begin
  Test('build alpha beta: both named targets are built',
    TestTwoNamedTargetsBuildBoth);
  Test('build alpha no-such-target: fails fast, builds nothing',
    TestUnknownTargetNameFailsBeforeBuildingAnything);
  Test('build with no names builds every target',
    TestNoNamesStillBuildsAllTargets);
end;

begin
  TestRunnerProgram.AddSuite(TBuildMultiTarget.Create(
    'build: multiple named targets'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
