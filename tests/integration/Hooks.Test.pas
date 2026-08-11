{ Hooks.Test — pins lifecycle-hook execution semantics (ADR-0011).

  Eleven assertions:
    1. [prebuild] hook (bare-string shorthand) runs before `lwpt build`.
    2. A bare `.pas` command receives no implicit InstantFPC treatment.
    3. [prebuild] hook with inputs/output (the staleness gate) skips
       on the second invocation when the output is fresher than every
       input.
    4. The whole-build [postbuild] hook sees staged outputs before
       publication.
    5. A per-entry [postbuild] hook sees the private candidate before
       the public output exists.
    6. Related paths containing the output name are not retargeted.
    7. A failing per-entry [postbuild] hook leaves no public output.
    8. A failing whole-build [postbuild] hook leaves no public output.
    9. [pretest] hook runs before `lwpt test`.
    10. [posttest] hook runs even when no tests are discovered.
    11. Supply-chain guard: a dep manifest's [preinstall] hook is
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
  Tests.LwptSubprocess,
  Tests.Scratch;

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
    procedure TestPrebuildCommandRuns;
    procedure TestBareStringDoesNotSelectInstantFPC;
    procedure TestPrebuildStalenessGateSkipsSecondRun;
    procedure TestPostbuildRunsAfterBuild;
    procedure TestEntryPostbuildUsesPrivateCandidate;
    procedure TestEntryPostbuildKeepsRelatedPath;
    procedure TestFailingEntryPostbuildDoesNotPublish;
    procedure TestFailingWholePostbuildDoesNotPublish;
    procedure TestPretestRunsBeforeTest;
    procedure TestPosttestRunsWhenNoTestsDiscovered;
    procedure TestDepManifestHookSilentlyDropped;
  end;

procedure THooksE2E.WriteSentinelScript(const APath, ASentinelName: string);
begin
  WriteTextFile(APath,
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

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "hooks-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[build]'#10 +
    'tinybin = { source = "source/tinybin.pas", output = "build/tinybin" }'#10 +
    ''#10 +
    AManifestBody);

  WriteTextFile(FScratch + '/source/tinybin.pas',
    'program tinybin;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''tinybin'');'#10 +
    'end.'#10);
end;

procedure THooksE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('hooks-e2e');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure THooksE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure THooksE2E.TestPrebuildCommandRuns;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[prebuild]'#10 +
    'touch = { command = "instantfpc", args = ["scripts/touch-pre.pas"] }'#10);
  WriteSentinelScript(FScratch + '/scripts/touch-pre.pas',
    'sentinel-prebuild.txt');

  R := RunLwpt(['build'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(SentinelExists('sentinel-prebuild.txt')).ToBe(True);
end;

procedure THooksE2E.TestBareStringDoesNotSelectInstantFPC;
var
  R: TLwptResult;
begin
  SetupScratchProject(
    '[prebuild]'#10 + 'direct = "scripts/not-executable.pas"'#10);
  WriteSentinelScript(FScratch + '/scripts/not-executable.pas',
    'must-not-exist.txt');
  R := RunLwpt(['build'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(SentinelExists('must-not-exist.txt')).ToBe(False);
end;

procedure THooksE2E.TestPrebuildStalenessGateSkipsSecondRun;
var
  R1, R2: TLwptResult;
  SentinelPath: string;
  FirstMtime, SecondMtime: Integer;
begin
  SetupScratchProject(
    '[prebuild]'#10 +
    'gen = { command = "instantfpc", args = ["scripts/gen.pas"], inputs = ["scripts/gen.pas"], output = "sentinel-gen.txt" }'#10);
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
    'touch = { command = "instantfpc", '
    + 'args = ["scripts/touch-post.pas", "build/tinybin"] }'#10);
  WriteTextFile(FScratch + '/scripts/touch-post.pas',
      'program TouchPostbuild;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  if (ParamStr(1) = '''') or not FileExists(ParamStr(1)) '
    + 'then Halt(1);'#10
    + '  if FileExists(''build/tinybin'')'
    + ' or FileExists(''build/tinybin.exe'') then Halt(2);'#10
    + '  Lines := TStringList.Create;'#10
    + '  try Lines.Add(''ok''); '
    + 'Lines.SaveToFile(''sentinel-postbuild.txt'');'#10
    + '  finally Lines.Free; end;'#10
    + 'end.'#10);

  R := RunLwpt(['build'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(SentinelExists('sentinel-postbuild.txt')).ToBe(True);
end;

procedure THooksE2E.TestEntryPostbuildUsesPrivateCandidate;
var R: TLwptResult;
begin
  SetupScratchProject('');
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "hooks-e2e"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[build]'#10
    + 'tinybin = { source = "source/tinybin.pas", '
    + 'output = "build/tinybin", '
    + 'postbuild = { probe = { command = "instantfpc", '
    + 'args = ["scripts/probe-output.pas", "{item.output}"] } } }'#10);
  WriteTextFile(FScratch + '/scripts/probe-output.pas',
      'program ProbeOutput;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'begin'#10
    + '  if ParamStr(1) <> GetEnvironmentVariable('
    + '''LWPT_BUILD_OUTPUT'') then Halt(3);'#10
    + '  if not FileExists(GetEnvironmentVariable('
    + '''LWPT_BUILD_OUTPUT'')) then Halt(1);'#10
    + '  if FileExists(GetEnvironmentVariable('
    + '''LWPT_BUILD_PUBLIC_OUTPUT'')) then Halt(2);'#10
    + 'end.'#10);

  R := RunLwpt(['build'], FScratch);

  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/tinybin')))
    .ToBe(True);
end;

procedure THooksE2E.TestEntryPostbuildKeepsRelatedPath;
var R: TLwptResult;
begin
  SetupScratchProject('');
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "hooks-e2e"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[build]'#10
    + 'tinybin = { source = "source/tinybin.pas", '
    + 'output = "build/tinybin", '
    + 'postbuild = { probe = { command = "instantfpc", '
    + 'args = ["scripts/probe-related.pas", "build/tinybin.json"] } } }'#10);
  WriteTextFile(FScratch + '/scripts/probe-related.pas',
      'program ProbeRelated;'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin'#10
    + '  if ParamStr(1) <> ''build/tinybin.json'' then Halt(1);'#10
    + 'end.'#10);

  R := RunLwpt(['build'], FScratch);

  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure THooksE2E.TestFailingEntryPostbuildDoesNotPublish;
var R: TLwptResult;
begin
  SetupScratchProject('');
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "hooks-e2e"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["source"]'#10
    + #10
    + '[build]'#10
    + 'tinybin = { source = "source/tinybin.pas", '
    + 'output = "build/tinybin", '
    + 'postbuild = { fail = { command = "instantfpc", args = ["scripts/fail-postbuild.pas"] } } }'#10);
  WriteTextFile(FScratch + '/scripts/fail-postbuild.pas',
      'program FailPostbuild;'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin Halt(7); end.'#10);

  R := RunLwpt(['build'], FScratch);

  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/tinybin')))
    .ToBe(False);
end;

procedure THooksE2E.TestFailingWholePostbuildDoesNotPublish;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[postbuild]'#10 +
    'fail = { command = "instantfpc", args = ["scripts/fail-postbuild.pas"] }'#10);
  WriteTextFile(FScratch + '/scripts/fail-postbuild.pas',
      'program FailPostbuild;'#10
    + '{$mode delphi}{$H+}'#10
    + 'begin Halt(7); end.'#10);

  R := RunLwpt(['build'], FScratch);

  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/tinybin')))
    .ToBe(False);
end;

procedure THooksE2E.TestPretestRunsBeforeTest;
var R: TLwptResult;
begin
  SetupScratchProject(
    '[pretest]'#10 +
    'touch = { command = "instantfpc", args = ["scripts/touch-pretest.pas"] }'#10);
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
    'touch = { command = "instantfpc", args = ["scripts/touch-posttest.pas"] }'#10);
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

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "supply-chain-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[dependencies]'#10 +
    'evildep = "./evildep"'#10);

  WriteTextFile(FScratch + '/source/dummy.pas',
    'unit Dummy;'#10'{$mode delphi}{$H+}'#10'interface'#10'implementation'#10'end.'#10);

  WriteTextFile(FScratch + '/evildep/lwpt.toml',
    '[package]'#10 +
    'name = "evildep"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[preinstall]'#10 +
    'attack = { command = "instantfpc", args = ["scripts/attack.pas"] }'#10);

  WriteTextFile(FScratch + '/evildep/source/dep.pas',
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
  Test('[prebuild] direct command runs before lwpt build',
    TestPrebuildCommandRuns);
  Test('bare-string hook is direct and does not select InstantFPC',
    TestBareStringDoesNotSelectInstantFPC);
  Test('[prebuild] staleness gate skips the second run when output is fresh',
    TestPrebuildStalenessGateSkipsSecondRun);
  Test('[postbuild] sees staged outputs before publication',
    TestPostbuildRunsAfterBuild);
  Test('entry postbuild receives the private candidate before publication',
    TestEntryPostbuildUsesPrivateCandidate);
  Test('entry postbuild keeps paths that only contain the output name',
    TestEntryPostbuildKeepsRelatedPath);
  Test('failing entry postbuild leaves the public output untouched',
    TestFailingEntryPostbuildDoesNotPublish);
  Test('failing whole-build postbuild leaves the public output untouched',
    TestFailingWholePostbuildDoesNotPublish);
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
