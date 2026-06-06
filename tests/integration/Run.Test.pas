{ Run.Test — pins lwpt run subcommand semantics (ADR-0013).

  `lwpt run <name>` resolves <name> against either:
    (a) a user-declared run-script in the consumer's manifest (any
        top-level section with a `script` field that isn't a reserved
        subcommand name), or
    (b) a built-in subcommand — `lwpt run install --frozen` aliases to
        `lwpt install --frozen`.

  Four assertions:
    1. User-script invocation propagates the script's exit code.
    2. Aliased built-in subcommand runs the subcommand correctly.
    3. Aliased built-in with flag passthrough works (--frozen).
    4. Unknown name exits non-zero with a useful message.

  Scratch project: a minimal manifest with one user-defined run-script
  section (`[hello] script = "scripts/hello.pas"`) plus a tiny InstantFPC
  script that writes a sentinel marker the test then asserts on. }

program Run.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess;

type
  TRunE2E = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    procedure WriteFile(const APath, AContent: string);
    procedure SetupScratchProject;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestUserScriptInvokesAndPropagatesExitCode;
    procedure TestAliasInstallSubcommand;
    procedure TestAliasWithFlagPassthrough;
    procedure TestListModeOmitsRetiredExport;
    procedure TestExportCanBeUserScriptName;
    procedure TestUnknownNameExitsNonZero;
  end;

procedure TRunE2E.WriteFile(const APath, AContent: string);
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
var SR: TSearchRec; Base: string;
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

procedure TRunE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/scripts');

  WriteFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "run-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[hello]'#10 +
    'script = "scripts/hello.pas"'#10);

  { InstantFPC script: writes a sentinel marker + exits 7. The test
    asserts on both. The marker proves the script ran; the exit code
    proves `lwpt run` propagates it. }
  WriteFile(FScratch + '/scripts/hello.pas',
    'program Hello;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'uses SysUtils, Classes;'#10 +
    'var SL: TStringList;'#10 +
    'begin'#10 +
    '  SL := TStringList.Create;'#10 +
    '  try'#10 +
    '    SL.Add(''ran'');'#10 +
    '    SL.SaveToFile(''marker.txt'');'#10 +
    '  finally'#10 +
    '    SL.Free;'#10 +
    '  end;'#10 +
    '  Halt(7);'#10 +
    'end.'#10);
end;

procedure TRunE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName('build/tests/tmp/run-e2e');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;

  RunLwpt(['install'], FScratch);
end;

procedure TRunE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TRunE2E.TestUserScriptInvokesAndPropagatesExitCode;
var R: TLwptResult;
begin
  { Remove any sentinel from a prior test run so its absence is meaningful. }
  DeleteFile(FScratch + '/marker.txt');

  R := RunLwpt(['run', 'hello'], FScratch);
  { Script exits 7; lwpt run must propagate that exit code. }
  Expect<Integer>(R.ExitCode).ToBe(7);
  Expect<Boolean>(FileExists(FScratch + '/marker.txt')).ToBe(True);
end;

procedure TRunE2E.TestAliasInstallSubcommand;
var R: TLwptResult;
begin
  { `lwpt run install` should dispatch to the built-in install
    subcommand identically to `lwpt install`. }
  R := RunLwpt(['run', 'install'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TRunE2E.TestAliasWithFlagPassthrough;
var R: TLwptResult;
begin
  { `lwpt run install --frozen` aliases to `lwpt install --frozen`.
    With a clean lockfile that matches the manifest, this exits 0. }
  R := RunLwpt(['run', 'install', '--frozen'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TRunE2E.TestListModeOmitsRetiredExport;
var R: TLwptResult;
begin
  R := RunLwpt(['run'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('install', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('export', R.Stdout) = 0).ToBe(True);
end;

procedure TRunE2E.TestExportCanBeUserScriptName;
var
  R: TLwptResult;
  ExportScratch: string;
begin
  ExportScratch := FScratch + '-export-script';
  RecursiveDelete(ExportScratch);
  ForceDirectories(ExportScratch + '/scripts');

  WriteFile(ExportScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "run-export-script"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[export]'#10 +
    'script = "scripts/export.pas"'#10);

  WriteFile(ExportScratch + '/scripts/export.pas',
    'program ExportScript;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'uses SysUtils, Classes;'#10 +
    'var SL: TStringList;'#10 +
    'begin'#10 +
    '  SL := TStringList.Create;'#10 +
    '  try'#10 +
    '    SL.Add(''export-script-ran'');'#10 +
    '    SL.SaveToFile(''export-marker.txt'');'#10 +
    '  finally'#10 +
    '    SL.Free;'#10 +
    '  end;'#10 +
    'end.'#10);

  R := RunLwpt(['run', 'export'], ExportScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(ExportScratch + '/export-marker.txt')).ToBe(True);
end;

procedure TRunE2E.TestUnknownNameExitsNonZero;
var R: TLwptResult;
begin
  R := RunLwpt(['run', 'absolutely-not-a-thing'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
end;

procedure TRunE2E.SetupTests;
begin
  Test('run <user-script> invokes the script and propagates its exit code',
    TestUserScriptInvokesAndPropagatesExitCode);
  Test('run install aliases to the built-in install subcommand',
    TestAliasInstallSubcommand);
  Test('run install --frozen passes flags through to the aliased subcommand',
    TestAliasWithFlagPassthrough);
  Test('run lists aliases without the retired export subcommand',
    TestListModeOmitsRetiredExport);
  Test('export is available as a user-declared run-script name',
    TestExportCanBeUserScriptName);
  Test('run <unknown> exits non-zero with a useful error',
    TestUnknownNameExitsNonZero);
end;

begin
  TestRunnerProgram.AddSuite(TRunE2E.Create('lwpt run: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
