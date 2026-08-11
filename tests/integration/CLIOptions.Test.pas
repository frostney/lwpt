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

  Scratch project: built in-test under an invocation-private root with
  a minimal lwpt.toml + one trivial source. Not committed; gets wiped
  and regenerated on each test run. }

program CLIOptions.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

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
    procedure TestVerboseFlagIsLongOnly;
    procedure TestSilentFlagIsSharedByEverySubcommand;
    procedure TestSuccessfulCommandReportsCompletion;
    procedure TestFailedCommandReportsCompletion;
    procedure TestRunAliasReportsResolvedCommand;
    procedure TestSilentSuccessEmitsOnlyCompletion;
    procedure TestSilentFailureReplaysDiagnosticBeforeCompletion;
    procedure TestSilentFormatCheckRetainsEvidenceAfterWarning;
    procedure TestSilentVerboseConflictIsRejected;
    procedure TestSilentRunAliasUsesResolvedCommand;
    procedure TestSilentRunTaskSuppressesSuccessfulChildOutput;
    procedure TestSilentRunTaskReplaysFailedChildOutput;
    procedure TestSilentBuildReplaysFailedCompilerOutputOnly;
    procedure TestSilentNoBuildEntriesRetainsFailureAfterWarning;
    procedure TestSilentInteractiveInitIsRejected;
  end;

function CompletionPrefix(const ACommand, AStatus: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(LwptBinaryPath), '') + ' '
    + ACommand + ': ' + AStatus;
end;

function CountOccurrences(const AText, ANeedle: string): Integer;
var
  Offset, FoundAt : Integer;
begin
  Result := 0;
  Offset := 1;
  while Offset <= Length(AText) do
  begin
    FoundAt := Pos(ANeedle, Copy(AText, Offset, MaxInt));
    if FoundAt = 0 then Exit;
    Inc(Result);
    Inc(Offset, FoundAt + Length(ANeedle) - 1);
  end;
end;

procedure TCLIOptionsE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/source');
  ForceDirectories(FScratch + '/scripts');

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "cli-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[build.hello]'#10 +
    'source = "source/hello.pas"'#10 +
    'output = "build/hello"'#10 +
    ''#10 +
    '[child-success]'#10 +
    'command = "instantfpc"'#10 +
    'args = ["scripts/child-success.pas"]'#10 +
    ''#10 +
    '[child-failure]'#10 +
    'command = "instantfpc"'#10 +
    'args = ["scripts/child-failure.pas"]'#10 +
    ''#10 +
    '[prebuild]'#10 +
    'successful = { command = "instantfpc", args = ["scripts/child-success.pas"] }'#10 +
    ''#10 +
    '[unknown-section]'#10 +
    'enabled = true'#10);

  WriteTextFile(FScratch + '/source/hello.pas',
    'program hello;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''hello e2e'');'#10 +
    'end.'#10);

  WriteTextFile(FScratch + '/scripts/child-success.pas',
    'program ChildSuccess;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  WriteLn(''successful-child-output'');'#10 +
    'end.'#10);
  WriteTextFile(FScratch + '/scripts/child-failure.pas',
    'program ChildFailure;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'begin'#10 +
    '  Write(''failed-child-output'');'#10 +
    '  Halt(7);'#10 +
    'end.'#10);
end;

procedure TCLIOptionsE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('cli-options-e2e');
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
  Expect<Boolean>(Pos('duplication', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('test',    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('repair',  R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('init',    R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('run',     R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('health',  R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('agents',  R.Stdout) > 0).ToBe(True);
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

procedure TCLIOptionsE2E.TestVerboseFlagIsLongOnly;
var
  BuildHelp, TestHelp: TLwptResult;
begin
  BuildHelp := RunLwpt(['build', '--help']);
  TestHelp := RunLwpt(['test', '--help']);
  Expect<Integer>(BuildHelp.ExitCode).ToBe(0);
  Expect<Integer>(TestHelp.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('--verbose', BuildHelp.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('--verbose', TestHelp.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('-v, --verbose', BuildHelp.Stdout) = 0).ToBe(True);
  Expect<Boolean>(Pos('-v, --verbose', TestHelp.Stdout) = 0).ToBe(True);
end;

procedure TCLIOptionsE2E.TestSilentFlagIsSharedByEverySubcommand;
const
  Commands: array[0..11] of string = ('install', 'add', 'remove', 'build',
    'format', 'duplication', 'test', 'repair', 'init', 'run', 'health',
    'agents');
var
  CommandIndex: Integer;
  HelpResult: TLwptResult;
begin
  for CommandIndex := 0 to High(Commands) do
  begin
    HelpResult := RunLwpt([Commands[CommandIndex], '--help']);
    Expect<Integer>(HelpResult.ExitCode).ToBe(0);
    Expect<Boolean>(Pos('--silent', HelpResult.Stdout) > 0).ToBe(True);
  end;
end;

procedure TCLIOptionsE2E.TestSuccessfulCommandReportsCompletion;
var
  R: TLwptResult;
  Prefix, StderrText: string;
begin
  R := RunLwpt(['build', '--help']);
  Prefix := CompletionPrefix('build', 'completed in ');
  StderrText := Trim(R.Stderr);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Integer>(CountOccurrences(R.Stdout, Prefix)).ToBe(0);
  Expect<Integer>(CountOccurrences(R.Stderr, Prefix)).ToBe(1);
  Expect<Boolean>(Pos(Prefix, StderrText) > 0).ToBe(True);
  Expect<Boolean>((StderrText <> '')
    and (StderrText[Length(StderrText)] = 's')).ToBe(True);
end;

procedure TCLIOptionsE2E.TestFailedCommandReportsCompletion;
var
  R : TLwptResult;
  Prefix : string;
begin
  R := RunLwpt(['build', '--mode', 'totally-wrong'], FScratch);
  Prefix := CompletionPrefix('build', 'failed after ');
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('--mode must be', R.Stderr) > 0).ToBe(True);
  Expect<Integer>(CountOccurrences(R.Stderr, Prefix)).ToBe(1);
end;

procedure TCLIOptionsE2E.TestRunAliasReportsResolvedCommand;
var
  R : TLwptResult;
  BuildPrefix, RunPrefix : string;
begin
  R := RunLwpt(['run', 'build', '--help']);
  BuildPrefix := CompletionPrefix('build', 'completed in ');
  RunPrefix := CompletionPrefix('run', 'completed in ');
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Integer>(CountOccurrences(R.Stderr, BuildPrefix)).ToBe(1);
  Expect<Integer>(CountOccurrences(R.Stderr, RunPrefix)).ToBe(0);
end;

procedure TCLIOptionsE2E.TestSilentSuccessEmitsOnlyCompletion;
var
  R: TLwptResult;
  Prefix, StdoutText: string;
begin
  R := RunLwpt(['build', 'hello', '--silent'], FScratch);
  Prefix := CompletionPrefix('build', 'completed in ');
  StdoutText := Trim(R.Stdout);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(R.Stderr).ToBe('');
  Expect<Integer>(CountOccurrences(StdoutText, Prefix)).ToBe(1);
  Expect<Boolean>(Pos(LineEnding, StdoutText) = 0).ToBe(True);
  Expect<Boolean>(Pos('discovered', StdoutText) = 0).ToBe(True);
  Expect<Boolean>(Pos('summary:', StdoutText) = 0).ToBe(True);
end;

procedure TCLIOptionsE2E.TestSilentFailureReplaysDiagnosticBeforeCompletion;
var
  R: TLwptResult;
  DiagnosticAt, FinalAt: Integer;
begin
  R := RunLwpt(['build', '--mode', 'totally-wrong', '--silent'], FScratch);
  DiagnosticAt := Pos('--mode must be', R.Stderr);
  FinalAt := Pos(CompletionPrefix('build', 'failed after '), R.Stderr);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<string>(R.Stdout).ToBe('');
  Expect<Boolean>(DiagnosticAt > 0).ToBe(True);
  Expect<Boolean>(FinalAt > DiagnosticAt).ToBe(True);
  Expect<Integer>(CountOccurrences(R.Stderr,
    CompletionPrefix('build', 'failed after '))).ToBe(1);
end;

procedure TCLIOptionsE2E.TestSilentFormatCheckRetainsEvidenceAfterWarning;
var
  EvidenceAt, FinalAt, WarningAt: Integer;
  R: TLwptResult;
begin
  WriteTextFile(FScratch + '/source/hello.pas',
    'program hello;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'uses'#10 +
    '  SysUtils,'#10 +
    '  Classes;'#10 +
    'begin'#10 +
    '  WriteLn(''hello e2e'');'#10 +
    'end.'#10);
  try
    R := RunLwpt(['format', '--check', '--silent'], FScratch);
    WarningAt := Pos('warning: unrecognised section [unknown-section]',
      R.Stderr);
    EvidenceAt := Pos('needs formatting: hello.pas', R.Stderr);
    FinalAt := Pos(CompletionPrefix('format', 'failed after '), R.Stderr);
    Expect<Integer>(R.ExitCode).ToBe(1);
    Expect<string>(R.Stdout).ToBe('');
    Expect<Boolean>(WarningAt > 0).ToBe(True);
    Expect<Boolean>(EvidenceAt > WarningAt).ToBe(True);
    Expect<Boolean>(FinalAt > EvidenceAt).ToBe(True);
  finally
    WriteTextFile(FScratch + '/source/hello.pas',
      'program hello;'#10 +
      '{$mode delphi}{$H+}'#10 +
      'begin'#10 +
      '  WriteLn(''hello e2e'');'#10 +
      'end.'#10);
  end;
end;

procedure TCLIOptionsE2E.TestSilentVerboseConflictIsRejected;
var
  R: TLwptResult;
begin
  R := RunLwpt(['build', 'hello', '--silent', '--verbose'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<string>(R.Stdout).ToBe('');
  Expect<Boolean>(Pos('--silent cannot be combined with --verbose',
    R.Stderr) > 0).ToBe(True);
  Expect<Integer>(CountOccurrences(R.Stderr,
    CompletionPrefix('build', 'failed after '))).ToBe(1);
end;

procedure TCLIOptionsE2E.TestSilentRunAliasUsesResolvedCommand;
var
  R: TLwptResult;
begin
  R := RunLwpt(['run', 'build', 'hello', '--silent'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(R.Stderr).ToBe('');
  Expect<Integer>(CountOccurrences(R.Stdout,
    CompletionPrefix('build', 'completed in '))).ToBe(1);
  Expect<Integer>(CountOccurrences(R.Stdout,
    CompletionPrefix('run', 'completed in '))).ToBe(0);
  Expect<Boolean>(Pos(LineEnding, Trim(R.Stdout)) = 0).ToBe(True);
end;

procedure TCLIOptionsE2E.TestSilentRunTaskSuppressesSuccessfulChildOutput;
var
  R: TLwptResult;
begin
  R := RunLwpt(['run', 'child-success', '--silent'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<string>(R.Stderr).ToBe('');
  Expect<Boolean>(Pos('successful-child-output', R.Stdout) = 0).ToBe(True);
  Expect<Integer>(CountOccurrences(R.Stdout,
    CompletionPrefix('run', 'completed in '))).ToBe(1);
  Expect<Boolean>(Pos(LineEnding, Trim(R.Stdout)) = 0).ToBe(True);
end;

procedure TCLIOptionsE2E.TestSilentRunTaskReplaysFailedChildOutput;
var
  R: TLwptResult;
  ChildAt, FinalAt, WarningAt: Integer;
begin
  R := RunLwpt(['run', 'child-failure', '--silent'], FScratch);
  WarningAt := Pos('warning: unrecognised section [unknown-section]',
    R.Stderr);
  ChildAt := Pos('failed-child-output', R.Stderr);
  FinalAt := Pos(CompletionPrefix('run', 'failed after '), R.Stderr);
  Expect<Integer>(R.ExitCode).ToBe(7);
  Expect<string>(R.Stdout).ToBe('');
  Expect<Boolean>(WarningAt > 0).ToBe(True);
  Expect<Boolean>(ChildAt > WarningAt).ToBe(True);
  Expect<Boolean>(ChildAt > 0).ToBe(True);
  Expect<Boolean>(FinalAt > ChildAt).ToBe(True);
  Expect<Boolean>(Pos('failed-child-output' + LineEnding
    + CompletionPrefix('run', 'failed after '), R.Stderr) > 0).ToBe(True);
  Expect<Integer>(CountOccurrences(R.Stderr,
    CompletionPrefix('run', 'failed after '))).ToBe(1);
end;

procedure TCLIOptionsE2E.TestSilentBuildReplaysFailedCompilerOutputOnly;
var
  R: TLwptResult;
begin
  WriteTextFile(FScratch + '/source/hello.pas',
    'program hello;'#10 +
    'begin'#10 +
    '  this is not valid Pascal'#10 +
    'end.'#10);
  try
    R := RunLwpt(['build', 'hello', '--clean', '--silent'], FScratch);
    Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
    Expect<string>(R.Stdout).ToBe('');
    Expect<Boolean>((Pos('Fatal:', R.Stderr) > 0)
      or (Pos('Error:', R.Stderr) > 0)).ToBe(True);
    Expect<Boolean>(Pos('successful-child-output', R.Stderr) = 0).ToBe(True);
    Expect<Boolean>(Pos('discovered ', R.Stderr) = 0).ToBe(True);
    Expect<Boolean>(Pos('START hello', R.Stderr) = 0).ToBe(True);
    Expect<Integer>(CountOccurrences(R.Stderr,
      CompletionPrefix('build', 'failed after '))).ToBe(1);
  finally
    WriteTextFile(FScratch + '/source/hello.pas',
      'program hello;'#10 +
      '{$mode delphi}{$H+}'#10 +
      'begin'#10 +
      '  WriteLn(''hello e2e'');'#10 +
      'end.'#10);
  end;
end;

procedure TCLIOptionsE2E.TestSilentNoBuildEntriesRetainsFailureAfterWarning;
var
  EvidenceAt, FinalAt, WarningAt: Integer;
  ProjectPath: string;
  R: TLwptResult;
begin
  ProjectPath := FScratch + '/no-build';
  ForceDirectories(ProjectPath + '/source');
  WriteTextFile(ProjectPath + '/lwpt.toml',
    '[package]'#10 +
    'name = "no-build"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[unknown-section]'#10 +
    'enabled = true'#10);
  R := RunLwpt(['build', '--silent'], ProjectPath);
  WarningAt := Pos('warning: unrecognised section [unknown-section]',
    R.Stderr);
  EvidenceAt := Pos('no [build] entries defined in lwpt.toml', R.Stderr);
  FinalAt := Pos(CompletionPrefix('build', 'failed after '), R.Stderr);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<string>(R.Stdout).ToBe('');
  Expect<Boolean>(WarningAt > 0).ToBe(True);
  Expect<Boolean>(EvidenceAt > WarningAt).ToBe(True);
  Expect<Boolean>(FinalAt > EvidenceAt).ToBe(True);
end;

procedure TCLIOptionsE2E.TestSilentInteractiveInitIsRejected;
var
  InitPath: string;
  R: TLwptResult;
begin
  InitPath := FScratch + '/interactive-init';
  ForceDirectories(InitPath);
  R := RunLwpt(['init', '--silent'], InitPath, [], 1000);
  Expect<Boolean>(R.TimedOut).ToBe(False);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<string>(R.Stdout).ToBe('');
  Expect<Boolean>(Pos('--silent requires --yes or --adopt for '
    + 'non-interactive init', R.Stderr) > 0).ToBe(True);
  Expect<Integer>(CountOccurrences(R.Stderr,
    CompletionPrefix('init', 'failed after '))).ToBe(1);
  Expect<Boolean>(FileExists(InitPath + '/lwpt.toml')).ToBe(False);
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
  Test('--verbose is long-only for build and test',
    TestVerboseFlagIsLongOnly);
  Test('--silent is inherited by every registered subcommand',
    TestSilentFlagIsSharedByEverySubcommand);
  Test('successful subcommand reports one final completion line',
    TestSuccessfulCommandReportsCompletion);
  Test('failed subcommand reports its diagnostic and one final completion line',
    TestFailedCommandReportsCompletion);
  Test('run alias reports the resolved subcommand name',
    TestRunAliasReportsResolvedCommand);
  Test('silent success emits exactly one canonical completion line',
    TestSilentSuccessEmitsOnlyCompletion);
  Test('silent failure replays diagnostics before one failure result',
    TestSilentFailureReplaysDiagnosticBeforeCompletion);
  Test('silent format check retains evidence after an unrelated warning',
    TestSilentFormatCheckRetainsEvidenceAfterWarning);
  Test('silent and verbose are rejected as contradictory',
    TestSilentVerboseConflictIsRejected);
  Test('silent run alias reports only the resolved command result',
    TestSilentRunAliasUsesResolvedCommand);
  Test('silent successful run task suppresses child output',
    TestSilentRunTaskSuppressesSuccessfulChildOutput);
  Test('silent failed run task replays child output before the result',
    TestSilentRunTaskReplaysFailedChildOutput);
  Test('silent failed build replays compiler output without progress',
    TestSilentBuildReplaysFailedCompilerOutputOnly);
  Test('silent no-build failure survives an unrelated manifest warning',
    TestSilentNoBuildEntriesRetainsFailureAfterWarning);
  Test('silent interactive init is rejected without waiting for input',
    TestSilentInteractiveInitIsRejected);
end;

begin
  TestRunnerProgram.AddSuite(TCLIOptionsE2E.Create(
    'CLI options: subprocess (E2E)'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
