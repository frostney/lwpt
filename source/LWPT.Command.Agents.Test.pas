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
  LWPT.Core,
  TestingPascalLibrary;

type
  TAgentsBlockTests = class(TTestSuite)
  private
    FOriginalDir: string;
    FRoot: string;
    procedure WriteText(const APath, AText: string);
    function ReadText(const APath: string): string;
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

procedure TAgentsBlockTests.WriteText(const APath, AText: string);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

function TAgentsBlockTests.ReadText(const APath: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(APath, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure TAgentsBlockTests.BeforeAll;
begin
  FOriginalDir := GetCurrentDir;
  FRoot := ExpandFileName('build/tests/tmp/command-agents');
  if DirectoryExists(FRoot) then WipeDir(FRoot);
  ForceDirectories(FRoot);
  WriteText(FRoot + '/lwpt.toml',
    '[package]'#10'name = "agents-fixture"'#10'version = "1.0.0"'#10);
  { CmdAgents writes AGENTS.md in the current directory. }
  SetCurrentDir(FRoot);
end;

procedure TAgentsBlockTests.AfterAll;
begin
  SetCurrentDir(FOriginalDir);
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
    Block := ReadText(FRoot + '/AGENTS.md');
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
