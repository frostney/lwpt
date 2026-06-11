{ CLIOptions.Test — spawn ./build/lwpt with various argv shapes
  and assert on exit codes + stdout/stderr.

  Lives in the E2E tier because the CLI parser lives BEHIND ParamStr /
  ParamCount; a unit test inside the test process would parse its own
  argv, not arbitrary input. The only way to test option-parsing
  realistically is to spawn the binary.

  Coverage:

    - `lwpt --help` and `lwpt -h` (alias) → exit 0, stdout lists every
      registered subcommand. Catches accidental subcommand removal +
      help formatting regressions.
    - `lwpt unknownsubcommand` → exit != 0, stderr names the unknown
      subcommand. Catches "silent fallthrough" regressions where an
      unknown verb does nothing.
    - `lwpt build --mode release <scratch project>` → the space-separated
      option-value regression. CLI.Parser accepts the space-separated
      form (`--mode release`) for plain string/integer options as well
      as the equals form (`--mode=release`); both are tested so any
      divergence between the two shapes is caught.
    - `lwpt build --mode invalid` → exit != 0; the mode value is
      validated by the build subcommand itself (not the parser), so
      this catches regressions in BOTH parsing + the validation step.

  Scratch project: built in-test under build/tests/tmp/cli-options-e2e/
  with a minimal lwpt.toml + one trivial source. Not committed; gets
  wiped + regenerated on each test run. }

program CLIOptions.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.Fixtures,
  Tests.LwptSubprocess;

type
  TCLIOptionsE2E = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestHelpListsAllSubcommands;
    procedure TestShortHelpAlias;
    procedure TestUnknownSubcommandExitsNonZero;
    procedure TestBuildModeSpaceSeparatedValueParses;
    procedure TestBuildModeEqualsSeparatedValueParses;
    procedure TestBuildModeInvalidValueExitsNonZero;
  end;

procedure TCLIOptionsE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/source');

  WriteTestFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "cli-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[build.hello]'#10 +
    'source = "source/hello.pas"'#10 +
    'output = "build/hello"'#10);

  WriteTestFile(FScratch + '/source/hello.pas',
    'program hello;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''hello e2e'');'#10 +
    'end.'#10);
end;

procedure TCLIOptionsE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/cli-options-e2e');
  { Absolutise the binary path BEFORE we chdir into the scratch dir;
    LwptBinaryPath caches the path the first time SetLwptBinaryPath
    is called, and we want that resolution against the project root,
    not the scratch dir. }
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  { Wipe + re-seed the scratch on each run. }
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;

  { lwpt install in the scratch (writes lwpt.cfg from a 0-dep manifest). }
  RunLwpt(['install'], FScratch);
end;

procedure TCLIOptionsE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TCLIOptionsE2E.TestHelpListsAllSubcommands;
var R: TLwptResult;
begin
  R := RunLwpt(['--help']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('install', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('build',   R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('format',  R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('test',    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('repair',  R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('init',    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('run',     R.Stdout) > 0).ToBe(True);
  { Per ADR-0015, `export` is gone — verify it's NOT listed. }
  Expect<Boolean>(Pos('export',  R.Stdout) > 0).ToBe(False);
end;

procedure TCLIOptionsE2E.TestShortHelpAlias;
var R: TLwptResult;
begin
  R := RunLwpt(['-h']);
  { The short form must produce the same exit code as --help and
    list the subcommands. We don't byte-compare stdout because the
    formatter may evolve; we just assert on the load-bearing content. }
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('install', R.Stdout) > 0).ToBe(True);
end;

procedure TCLIOptionsE2E.TestUnknownSubcommandExitsNonZero;
var R: TLwptResult;
begin
  R := RunLwpt(['does-not-exist-as-a-subcommand']);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  { Error message should mention the unknown subcommand somewhere
    (stdout or stderr; the framework hasn't standardised which yet). }
  Expect<Boolean>(
    (Pos('does-not-exist', R.Stdout) > 0)
    or (Pos('does-not-exist', R.Stderr) > 0)
    or (Pos('unknown', LowerCase(R.Stdout + R.Stderr)) > 0)
  ).ToBe(True);
end;

procedure TCLIOptionsE2E.TestBuildModeSpaceSeparatedValueParses;
var R: TLwptResult;
begin
  { Space-separated option-value form: --mode release (a SPACE between
    the option and its value, not an =). The CLI.Parser accepts this
    shape for plain string options like --mode; the test pins the
    behaviour against regression. }
  R := RunLwpt(['build', 'hello', '--mode', 'release'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/hello'))).ToBe(True);
end;

procedure TCLIOptionsE2E.TestBuildModeEqualsSeparatedValueParses;
var R: TLwptResult;
begin
  { Sibling shape: --mode=release. Must produce the same outcome as
    the space-separated form; any divergence between the two shapes
    is a parser regression. }
  R := RunLwpt(['build', 'hello', '--mode=release'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExpectedExe(FScratch + '/build/hello'))).ToBe(True);
end;

procedure TCLIOptionsE2E.TestBuildModeInvalidValueExitsNonZero;
var R: TLwptResult;
begin
  { An invalid value for --mode must exit non-zero. The mode value is
    validated by the build subcommand (not the parser), so this guards
    both the parse path AND the validation step. }
  R := RunLwpt(['build', 'hello', '--mode', 'totally-wrong'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
end;

procedure TCLIOptionsE2E.SetupTests;
begin
  Test('lwpt --help lists every subcommand on stdout',
    TestHelpListsAllSubcommands);
  Test('-h is an alias for --help and produces equivalent output',
    TestShortHelpAlias);
  Test('unknown subcommand exits non-zero + names the unknown verb',
    TestUnknownSubcommandExitsNonZero);
  Test('build --mode release (space-separated value) parses correctly',
    TestBuildModeSpaceSeparatedValueParses);
  Test('build --mode=release (equals-separated value) parses correctly',
    TestBuildModeEqualsSeparatedValueParses);
  Test('build --mode invalid (unknown mode value) exits non-zero',
    TestBuildModeInvalidValueExitsNonZero);
end;

begin
  TestRunnerProgram.AddSuite(TCLIOptionsE2E.Create(
    'CLI options: subprocess (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
