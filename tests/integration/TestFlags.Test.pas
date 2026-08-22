{ TestFlags.Test — pins root [test].flags compiler-request wiring.

  The tests cross the real CLI boundary against scratch projects. They prove
  flags reach every selected test program, remain subject to compiler-driver
  confinement, and cannot leak into direct lifecycle commands. }

program TestFlags.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TTestFlagsIntegration = class(TTestSuite)
  private
    FScratch: string;
    procedure SetupScratchProject(const AFlags, AHookSection: string;
      const AIncludeNestedTest: Boolean);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestFlagsReachAllSelectedCompiles;
    procedure TestManagedOutputArgumentIsRejected;
    procedure TestDirectPretestCommandDoesNotInheritFlags;
  end;

procedure TTestFlagsIntegration.SetupScratchProject(const AFlags,
  AHookSection: string; const AIncludeNestedTest: Boolean);
const
  FLAG_TEST_SOURCE =
    'program FlagTest;'#10 +
    '{$mode delphi}{$H+}'#10 +
    '{$ifndef ISSUE172_FLAG}'#10 +
    '  {$fatal ISSUE172_FLAG was not forwarded to the test compile}'#10 +
    '{$endif}'#10 +
    'begin'#10 +
    'end.'#10;
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch + '/source');
  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "test-flags-integration"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["source"]'#10 +
    ''#10 +
    '[test]'#10 +
    'flags = [' + AFlags + ']'#10 +
    AHookSection);
  WriteTextFile(FScratch + '/source/DefaultFlag.Test.pas', FLAG_TEST_SOURCE);
  if AIncludeNestedTest then
  begin
    ForceDirectories(FScratch + '/tests/custom');
    WriteTextFile(FScratch + '/tests/custom/NestedFlag.Test.pas',
      FLAG_TEST_SOURCE);
  end;
end;

procedure TTestFlagsIntegration.BeforeAll;
begin
  FScratch := CreateScratchRoot('test-flags-integration');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure TTestFlagsIntegration.TestFlagsReachAllSelectedCompiles;
var
  Run: TLwptResult;
begin
  SetupScratchProject('"-dISSUE172_FLAG"', '', True);

  Run := RunLwpt(['test', '--jobs=1'], FScratch);
  DumpRunFailure('test flags on complete discovery', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
end;

procedure TTestFlagsIntegration.TestManagedOutputArgumentIsRejected;
var
  Run: TLwptResult;
begin
  SetupScratchProject('"-FEescaped-output"', '', False);

  Run := RunLwpt(['test', '--jobs=1'], FScratch);
  Expect<Boolean>(Run.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('managed by LWPT', Run.Stdout + Run.Stderr) > 0)
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(FScratch + '/escaped-output')).ToBe(False);
end;

procedure TTestFlagsIntegration.TestDirectPretestCommandDoesNotInheritFlags;
var
  Run: TLwptResult;
begin
  SetupScratchProject('"-dISSUE172_FLAG"',
    ''#10 +
    '[pretest]'#10 +
    'probe = { command = "instantfpc", args = '
      + '["scripts/probe-hook.pas", "declared-argument"] }'#10,
    False);
  WriteTextFile(FScratch + '/scripts/probe-hook.pas',
    'program ProbeHook;'#10 +
    '{$mode delphi}{$H+}'#10 +
    '{$ifdef ISSUE172_FLAG}'#10 +
    '  {$fatal test flags leaked into the direct pretest command}'#10 +
    '{$endif}'#10 +
    'uses Classes;'#10 +
    'var Lines: TStringList;'#10 +
    'begin'#10 +
    '  if ParamCount <> 1 then Halt(1);'#10 +
    '  if ParamStr(1) <> ''declared-argument'' then Halt(2);'#10 +
    '  Lines := TStringList.Create;'#10 +
    '  try'#10 +
    '    Lines.Add(''ok'');'#10 +
    '    Lines.SaveToFile(''hook-arguments-ok.txt'');'#10 +
    '  finally'#10 +
    '    Lines.Free;'#10 +
    '  end;'#10 +
    'end.'#10);

  Run := RunLwpt(['test', '--jobs=1'], FScratch);
  DumpRunFailure('direct pretest command isolation', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/hook-arguments-ok.txt')).ToBe(True);
end;

procedure TTestFlagsIntegration.SetupTests;
begin
  Test('[test] flags reach every selected test compile',
    TestFlagsReachAllSelectedCompiles);
  Test('[test] flags reject LWPT-managed output arguments',
    TestManagedOutputArgumentIsRejected);
  Test('[test] flags do not alter direct pretest command arguments',
    TestDirectPretestCommandDoesNotInheritFlags);
end;

begin
  TestRunnerProgram.AddSuite(
    TTestFlagsIntegration.Create('test flags: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
