{ Hooks.Test — pins lifecycle-hook execution semantics (ADR-0011).

  Five assertions:
    1. [prebuild] hook (bare-string shorthand) runs before `lwpt build`.
    2. [prebuild] hook with inputs/output (the staleness gate) skips
       on the second invocation when the output is fresher than every
       input.
    3. [postbuild] hook runs after `lwpt build` completes.
    4. [pretest] hook runs before `lwpt test`.
    5. Supply-chain guard: a dep manifest's [preinstall] hook is
       silently dropped during `lwpt install`. The hook would write a
       sentinel file in the consuming project; the test asserts that
       file does NOT exist after install. This is the most important
       assertion in the suite — without it, a malicious transitive
       dep could declare any hook + run arbitrary code on install.

  Each test uses sentinel files in a scratch dir as the observable
  side-effect. Hook scripts are tiny InstantFPC programs that touch
  the sentinel and exit cleanly. }

program Hooks.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

type
  THooksE2E = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    procedure WriteSentinelScript(const APath, ASentinelName: string);
    procedure SetupScratchProject(const AManifestBody: string);
    function  SentinelExists(const AName: string): Boolean;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestPrebuildShorthandRuns;
    procedure TestPrebuildStalenessGateSkipsSecondRun;
    procedure TestPostbuildRunsAfterBuild;
    procedure TestPretestRunsBeforeTest;
    procedure TestPosttestRunsWhenNoTestsDiscovered;
    procedure TestDepManifestHookSilentlyDropped;
  end;

procedure THooksE2E.WriteSentinelScript(const APath, ASentinelName: string);
begin
  WriteTestFile(APath,
    'program TouchSentinel;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'uses SysUtils, Classes;'#10 +
    'var SL: TStringList;'#10 +
    'begin'#10 +
    '  SL := TStringList.Create;'#10 +
    '  try'#10 +
    '    SL.Add(''ran'');'#10 +
    '    SL.SaveToFile(''' + ASentinelName + ''');'#10 +
    '  finally'#10 +
    '    SL.Free;'#10 +
    '  end;'#10 +
    'end.'#10);
end;

function THooksE2E.SentinelExists(const AName: string): Boolean;
begin
  Result := FileExists(FScratch + '/' + AName);
end;

procedure THooksE2E.SetupScratchProject(const AManifestBody: string);
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch + '/source');
  ForceDirectories(FScratch + '/scripts');

  WriteTestFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "hooks-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[build]'#10 +
    'tinybin = { source = "source/tinybin.pas", output = "build/tinybin" }'#10 +
    ''#10 +
    AManifestBody);

  WriteTestFile(FScratch + '/source/tinybin.pas',
    'program tinybin;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''tinybin'');'#10 +
    'end.'#10);
end;

procedure THooksE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/hooks-e2e');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure THooksE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure THooksE2E.TestPrebuildShorthandRuns;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[prebuild]'#10 +
    'touch = "scripts/touch-pre.pas"'#10);
  WriteSentinelScript(FScratch + '/scripts/touch-pre.pas',
    'sentinel-prebuild.txt');

  R := RunLwpt(['build'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(SentinelExists('sentinel-prebuild.txt')).ToBe(True);
end;

procedure THooksE2E.TestPrebuildStalenessGateSkipsSecondRun;
var
  R1, R2: TLwptResult;
  SentinelPath: string;
  FirstMtime, SecondMtime: Integer;
begin
  SetupScratchProject(
    '[prebuild]'#10 +
    'gen = { script = "scripts/gen.pas", inputs = ["scripts/gen.pas"], output = "sentinel-gen.txt" }'#10);
  WriteSentinelScript(FScratch + '/scripts/gen.pas', 'sentinel-gen.txt');

  R1 := RunLwpt(['build'], FScratch);
  Expect<Integer>(R1.ExitCode).ToBe(0);
  SentinelPath := FScratch + '/sentinel-gen.txt';
  Expect<Boolean>(FileExists(SentinelPath)).ToBe(True);

  FirstMtime := FileAge(SentinelPath);
  { Sleep 1 sec so a subsequent regen would be detectable via mtime. }
  Sleep(1100);

  R2 := RunLwpt(['build'], FScratch);
  Expect<Integer>(R2.ExitCode).ToBe(0);
  SecondMtime := FileAge(SentinelPath);

  { Staleness gate: input (gen.pas) is older than output (sentinel),
    so the hook must skip. Output mtime unchanged. }
  Expect<Integer>(SecondMtime).ToBe(FirstMtime);
end;

procedure THooksE2E.TestPostbuildRunsAfterBuild;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[postbuild]'#10 +
    'touch = "scripts/touch-post.pas"'#10);
  WriteSentinelScript(FScratch + '/scripts/touch-post.pas',
    'sentinel-postbuild.txt');

  R := RunLwpt(['build'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(SentinelExists('sentinel-postbuild.txt')).ToBe(True);
end;

procedure THooksE2E.TestPretestRunsBeforeTest;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[pretest]'#10 +
    'touch = "scripts/touch-pretest.pas"'#10);
  WriteSentinelScript(FScratch + '/scripts/touch-pretest.pas',
    'sentinel-pretest.txt');

  R := RunLwpt(['test'], FScratch);
  { Exit code may be anything (no *.Test.pas files present means 0 or
    an informational non-zero — the hook firing is what we're testing). }
  Expect<Boolean>(SentinelExists('sentinel-pretest.txt')).ToBe(True);
end;

procedure THooksE2E.TestPosttestRunsWhenNoTestsDiscovered;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[posttest]'#10 +
    'touch = "scripts/touch-posttest.pas"'#10);
  WriteSentinelScript(FScratch + '/scripts/touch-posttest.pas',
    'sentinel-posttest.txt');

  R := RunLwpt(['test'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(SentinelExists('sentinel-posttest.txt')).ToBe(True);
end;

procedure THooksE2E.TestDepManifestHookSilentlyDropped;
var R: TLwptResult;
begin
  { Root manifest declares one local-path dep. The dep's manifest
    declares a [preinstall] hook that would touch a sentinel — but
    per ADR-0011's supply-chain stance, dep hooks are silently
    dropped. The sentinel must NOT exist after install. }

  RecursiveDelete(FScratch);
  ForceDirectories(FScratch + '/source');
  ForceDirectories(FScratch + '/evildep');
  ForceDirectories(FScratch + '/evildep/source');
  ForceDirectories(FScratch + '/evildep/scripts');

  WriteTestFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "supply-chain-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'evildep = "./evildep"'#10);

  WriteTestFile(FScratch + '/source/dummy.pas',
    'unit Dummy;'#10'{$mode delphi}{$H+}'#10'interface'#10'implementation'#10'end.'#10);

  WriteTestFile(FScratch + '/evildep/lwpt.toml',
    '[package]'#10 +
    'name = "evildep"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[preinstall]'#10 +
    'attack = "scripts/attack.pas"'#10);

  WriteTestFile(FScratch + '/evildep/source/dep.pas',
    'unit Dep;'#10'{$mode delphi}{$H+}'#10'interface'#10'implementation'#10'end.'#10);

  { The attack script touches a sentinel in the consuming project's
    cwd. If supply-chain isolation works, this never runs. }
  WriteSentinelScript(FScratch + '/evildep/scripts/attack.pas',
    'sentinel-supply-chain-attack.txt');

  R := RunLwpt(['install'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  { THE assertion: a transitive dep's hook did NOT execute. }
  Expect<Boolean>(SentinelExists('sentinel-supply-chain-attack.txt'))
    .ToBe(False);
end;

procedure THooksE2E.SetupTests;
begin
  Test('[prebuild] shorthand runs before lwpt build',
    TestPrebuildShorthandRuns);
  Test('[prebuild] staleness gate skips the second run when output is fresh',
    TestPrebuildStalenessGateSkipsSecondRun);
  Test('[postbuild] runs after lwpt build completes',
    TestPostbuildRunsAfterBuild);
  Test('[pretest] runs before lwpt test',
    TestPretestRunsBeforeTest);
  Test('[posttest] runs after lwpt test even when no tests are discovered',
    TestPosttestRunsWhenNoTestsDiscovered);
  Test('dep manifest hook is silently dropped (supply-chain guard)',
    TestDepManifestHookSilentlyDropped);
end;

begin
  TestRunnerProgram.AddSuite(THooksE2E.Create('lifecycle hooks: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
