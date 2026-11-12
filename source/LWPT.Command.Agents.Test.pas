{ LWPT.Command.Agents.Test — the agents block lists an option the way
  command help does.

  The block is rendered from the same registry as `--help`. No lwpt
  command option has a short name, so a registry fixture with one pins
  that the block names an option by its help label (`-o, --output=<value>`)
  rather than by its long form only. The end-to-end contract of the
  subcommand lives in tests/integration/Agents.Test.pas. }
program LWPT.Command.Agents.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  LWPT.Command.Agents,
  TestingPascalLibrary,
  Tests.Scratch;

type
  TAgentsBlockTests = class(TTestSuite)
  private
    FOriginalDir: string;
    FRoot: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestOptionsAreListedByTheirHelpLabel;
  end;

function HandleNothing(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  Result := 0;
end;

procedure TAgentsBlockTests.BeforeAll;
begin
  FOriginalDir := GetCurrentDir;
  FRoot := CreateScratchRoot('command-agents');
  WriteTextFile(FRoot + '/lwpt.toml',
    '[package]'#10'name = "agents-fixture"'#10'version = "1.0.0"'#10);
  { CmdAgents writes AGENTS.md in the current directory; failing here
    keeps it from writing the repository's own. }
  if not SetCurrentDir(FRoot) then
    raise Exception.CreateFmt('cannot enter scratch root "%s"', [FRoot]);
end;

procedure TAgentsBlockTests.AfterAll;
begin
  SetCurrentDir(FOriginalDir);
  RecursiveDelete(FRoot);
end;

procedure TAgentsBlockTests.TestOptionsAreListedByTheirHelpLabel;
var
  Registry: TSubcommandRegistry;
  Options: TOptionArray;
  Output: TStringOption;
  Block: string;
begin
  Registry := TSubcommandRegistry.Create;
  try
    SetLength(Options, 2);
    Options[0] := TFlagOption.Create('release', 'Optimize');
    Output := TStringOption.Create('output', 'Output path');
    Output.ShortName := 'o';
    Options[1] := Output;
    Registry.Add(TSubcommand.Create('build', 'Build a program', '<file>',
      @HandleNothing, Options));

    Expect<Integer>(CmdAgents(FRoot + '/lwpt.toml', Registry, False)).ToBe(0);
    Block := ReadBinaryFile(FRoot + '/AGENTS.md');
    Expect<Boolean>(Pos(#10'  - `--release` — Optimize'#10, Block) > 0).ToBe(
      True);
    Expect<Boolean>(Pos(#10'  - `-o, --output=<value>` — Output path'#10,
      Block) > 0).ToBe(True);
  finally
    Registry.Free;
  end;
end;

procedure TAgentsBlockTests.SetupTests;
begin
  Test('the agents block lists options by their help label',
    TestOptionsAreListedByTheirHelpLabel);
end;

begin
  TestRunnerProgram.AddSuite(TAgentsBlockTests.Create(
    'LWPT.Command.Agents: options in the agents block'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
