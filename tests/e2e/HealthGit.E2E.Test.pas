{ HealthGit.E2E.Test — CLI, local Git history, and threshold contracts. }
program HealthGit.E2E.Test;

{$mode delphi}{$H+}

uses
  Process,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  THealthGitE2E = class(TTestSuite)
  private
    FGitRoot, FNonGitRoot, FWorktreeRoot: string;
    procedure RunGit(const AArguments: array of string);
    procedure WriteManifest(const ARoot: string;
      const AMaxFileCyclomatic: Integer = -1);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestGitHistoryProducesStableEnrichedJSON;
    procedure TestNonGitProjectDegradesToComplexityOnly;
    procedure TestThresholdEqualityPassesAndExcessFails;
  end;

procedure THealthGitE2E.RunGit(const AArguments: array of string);
var
  ArgumentIndex: Integer;
  ProcessInstance: TProcess;
begin
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := 'git';
    ProcessInstance.Parameters.Add('-C');
    ProcessInstance.Parameters.Add(FGitRoot);
    for ArgumentIndex := Low(AArguments) to High(AArguments) do
      ProcessInstance.Parameters.Add(AArguments[ArgumentIndex]);
    ProcessInstance.Options := [poWaitOnExit];
    ProcessInstance.Execute;
    if ProcessInstance.ExitCode <> 0 then
      raise Exception.CreateFmt('git command failed with exit %d',
        [ProcessInstance.ExitCode]);
  finally
    ProcessInstance.Free;
  end;
end;

procedure THealthGitE2E.WriteManifest(const ARoot: string;
  const AMaxFileCyclomatic: Integer);
var
  Text: string;
begin
  Text := '[package]'#10'name = "health-e2e"'#10
    + 'version = "1.0.0"'#10'units = ["source"]'#10;
  if AMaxFileCyclomatic >= 0 then
    Text := Text + '[health]'#10'max-file-cyclomatic = '
      + IntToStr(AMaxFileCyclomatic) + #10;
  WriteTextFile(ARoot + '/lwpt.toml', Text);
end;

procedure THealthGitE2E.BeforeAll;
begin
  FWorktreeRoot := ExpandFileName('.');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FGitRoot := CreateScratchRoot('health-git-e2e');
  FNonGitRoot := CreateScratchRoot('health-nongit-e2e');
  RecursiveDelete(FGitRoot);
  RecursiveDelete(FNonGitRoot);
  ForceDirectories(FGitRoot + '/source');
  ForceDirectories(FNonGitRoot + '/source');
  WriteManifest(FGitRoot);
  WriteManifest(FNonGitRoot);
  WriteTextFile(FGitRoot + '/source/changed.pas',
    'unit Changed; interface implementation '#10
    + 'procedure Work; begin if A then B; end; end.');
  WriteTextFile(FGitRoot + '/source/stable.pas',
    'unit Stable; interface implementation '#10
    + 'procedure Work; begin A; end; end.');
  WriteTextFile(FNonGitRoot + '/source/demo.pas',
    'unit Demo; interface implementation '#10
    + 'procedure Work; begin if A then B; end; end.');

  RunGit(['init']);
  RunGit(['config', 'user.name', 'LWPT Test']);
  RunGit(['config', 'user.email', 'lwpt-test@example.invalid']);
  RunGit(['config', 'commit.gpgSign', 'false']);
  RunGit(['add', '.']);
  RunGit(['commit', '-m', 'initial']);
  WriteTextFile(FGitRoot + '/source/changed.pas',
    'unit Changed; interface implementation '#10
    + 'procedure Work; begin if A and B then C; end; end.');
  RunGit(['add', 'source/changed.pas']);
  RunGit(['commit', '-m', 'change complexity']);
  RunGit(['mv', 'source/stable.pas', 'source/renamed.pas']);
  RunGit(['commit', '-m', 'rename stable source']);
end;

procedure THealthGitE2E.TestGitHistoryProducesStableEnrichedJSON;
var
  FirstRun, SecondRun: TLwptResult;
begin
  FirstRun := RunLwpt(['health', '--hotspots', '--json'], FGitRoot);
  SecondRun := RunLwpt(['health', '--hotspots', '--json'], FGitRoot);
  Expect<Integer>(FirstRun.ExitCode).ToBe(0);
  Expect<string>(FirstRun.Stdout).ToBe(SecondRun.Stdout);
  Expect<Boolean>(Pos('"mode":"git-enriched"', FirstRun.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('"historyCommits":100', FirstRun.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('source/renamed.pas', FirstRun.Stdout) > 0).ToBe(True);
  Expect<Integer>(Pos('"changedLines":0', FirstRun.Stdout)).ToBe(0);
end;

procedure THealthGitE2E.TestNonGitProjectDegradesToComplexityOnly;
var
  Run: TLwptResult;
begin
  Run := RunLwpt(['health', '--hotspots', '--json'], FNonGitRoot,
    ['GIT_CEILING_DIRECTORIES=' + FWorktreeRoot]);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('"mode":"complexity-only"', Run.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('Git history unavailable', Run.Stdout) > 0).ToBe(True);
end;

procedure THealthGitE2E.TestThresholdEqualityPassesAndExcessFails;
var
  Run: TLwptResult;
begin
  WriteManifest(FNonGitRoot, 2);
  Run := RunLwpt(['health', '--json'], FNonGitRoot);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('"outcome":"passed"', Run.Stdout) > 0).ToBe(True);

  WriteManifest(FNonGitRoot, 1);
  Run := RunLwpt(['health', '--json'], FNonGitRoot);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('"outcome":"failed"', Run.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('max-file-cyclomatic', Run.Stdout) > 0).ToBe(True);
end;

procedure THealthGitE2E.SetupTests;
begin
  Test('reports deterministic JSON from rename-aware local Git history',
    TestGitHistoryProducesStableEnrichedJSON);
  Test('degrades non-Git projects to complexity-only mode',
    TestNonGitProjectDegradesToComplexityOnly);
  Test('passes equality and fails only above configured thresholds',
    TestThresholdEqualityPassesAndExcessFails);
end;

begin
  TestRunnerProgram.AddSuite(THealthGitE2E.Create('LWPT.Health Git E2E'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
