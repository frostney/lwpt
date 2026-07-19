{ TestScheduling.Test — parallel test scheduling and numeric bail policy. }
program TestScheduling.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

type
  TTestScheduling = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetProject(ABail: Integer);
    procedure WriteMarkerProgram(const AFileName, AMarker: string;
      AExitCode: Integer);
    procedure WriteOverlapProgram(const AFileName, AOwnMarker,
      AOtherMarker: string);
    function RunTests(const AArgs: array of string): TLwptResult;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
  public
    procedure SetupTests; override;
    procedure TestDefaultJobsOverlap;
    procedure TestJobsOneRunsInSourceOrder;
    procedure TestBailZeroOverridesManifestAndRunsAll;
    procedure TestCompileFailureCountsTowardBail;
    procedure TestBailTerminatesActiveAndLeavesPendingUnstarted;
  end;

function PascalString(const AValue: string): string;
begin
  Result := '''' + StringReplace(AValue, '''', '''''', [rfReplaceAll]) + '''';
end;

procedure TTestScheduling.BeforeAll;
begin
  FScratch := CreateScratchRoot('test-scheduling');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure TTestScheduling.BeforeEach;
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch + '/tests');
  ForceDirectories(FScratch + '/control');
end;

procedure TTestScheduling.ResetProject(ABail: Integer);
begin
  RecursiveDelete(FScratch + '/tests');
  RecursiveDelete(FScratch + '/.lwpt');
  RecursiveDelete(FScratch + '/worker-state');
  RecursiveDelete(FScratch + '/control');
  ForceDirectories(FScratch + '/tests');
  ForceDirectories(FScratch + '/control');
  WriteTextFile(FScratch + '/lwpt.toml',
      '[package]'#10
    + 'name = "scheduler-fixture"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["tests"]'#10
    + #10
    + '[test]'#10
    + 'bail = ' + IntToStr(ABail) + #10);
end;

procedure TTestScheduling.WriteMarkerProgram(const AFileName,
  AMarker: string; AExitCode: Integer);
begin
  WriteTextFile(FScratch + '/tests/' + AFileName,
      'program MarkerFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes;'#10
    + 'begin'#10
    + '  TFileStream.Create(' + PascalString(FScratch + '/control/' + AMarker)
    + ', fmCreate).Free;'#10
    + '  Halt(' + IntToStr(AExitCode) + ');'#10
    + 'end.'#10);
end;

procedure TTestScheduling.WriteOverlapProgram(const AFileName,
  AOwnMarker, AOtherMarker: string);
begin
  WriteTextFile(FScratch + '/tests/' + AFileName,
      'program OverlapFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Started: TDateTime;'#10
    + 'begin'#10
    + '  TFileStream.Create(' + PascalString(FScratch + '/control/' + AOwnMarker)
    + ', fmCreate).Free;'#10
    + '  Started := Now;'#10
    + '  while (not FileExists('
    + PascalString(FScratch + '/control/' + AOtherMarker) + '))'#10
    + '    and ((Now - Started) * 86400 < 5) do Sleep(10);'#10
    + '  if not FileExists('
    + PascalString(FScratch + '/control/' + AOtherMarker) + ') then Halt(2);'#10
    + 'end.'#10);
end;

function TTestScheduling.RunTests(const AArgs: array of string): TLwptResult;
var
  Args, Environment: array of string;
  i: Integer;
begin
  SetLength(Args, Length(AArgs) + 1);
  Args[0] := 'test';
  for i := 0 to High(AArgs) do Args[i + 1] := AArgs[i];
  SetLength(Environment, 3);
  Environment[0] := WORKER_LEASE_TOKEN_ENV + '=';
  Environment[1] := WORKER_STATE_DIR_ENV + '='
    + FScratch + '/worker-state';
  Environment[2] := WORKER_BUDGET_ENV + '=2';
  Result := RunLwpt(Args, FScratch, Environment);
end;

procedure TTestScheduling.TestDefaultJobsOverlap;
var
  R: TLwptResult;
begin
  ResetProject(0);
  WriteOverlapProgram('A.First.Test.pas', 'first-started', 'second-started');
  WriteOverlapProgram('B.Second.Test.pas', 'second-started', 'first-started');
  R := RunTests([]);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(FScratch + '/control/first-started')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/second-started')).ToBe(True);
end;

procedure TTestScheduling.TestJobsOneRunsInSourceOrder;
var
  R: TLwptResult;
  Lines: TStringList;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.First.Test.pas',
      'program FirstFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.Add(''first'');'#10
    + '    Lines.SaveToFile('
    + PascalString(FScratch + '/control/order') + ');'#10
    + '  finally Lines.Free end;'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/tests/B.Second.Test.pas',
      'program SecondFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'var Lines: TStringList;'#10
    + 'begin'#10
    + '  Lines := TStringList.Create;'#10
    + '  try'#10
    + '    Lines.LoadFromFile('
    + PascalString(FScratch + '/control/order') + ');'#10
    + '    Lines.Add(''second'');'#10
    + '    Lines.SaveToFile('
    + PascalString(FScratch + '/control/order') + ');'#10
    + '  finally Lines.Free end;'#10
    + 'end.'#10);
  R := RunTests(['--jobs=1']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/control/order');
    Expect<Integer>(Lines.Count).ToBe(2);
    Expect<string>(Lines[0]).ToBe('first');
    Expect<string>(Lines[1]).ToBe('second');
  finally
    Lines.Free;
  end;
end;

procedure TTestScheduling.TestBailZeroOverridesManifestAndRunsAll;
var
  R: TLwptResult;
begin
  ResetProject(1);
  WriteMarkerProgram('A.Fail.Test.pas', 'failed-ran', 1);
  WriteMarkerProgram('B.Pass.Test.pas', 'pass-ran', 0);
  R := RunTests(['--jobs=1', '--bail=0']);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(FScratch + '/control/failed-ran')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/pass-ran')).ToBe(True);
  Expect<Boolean>(Pos('1 passed, 1 failed', R.Stdout) > 0).ToBe(True);
end;

procedure TTestScheduling.TestCompileFailureCountsTowardBail;
var
  R: TLwptResult;
begin
  ResetProject(0);
  WriteTextFile(FScratch + '/tests/A.Bad.Test.pas',
    'program BadFixture; begin this is not valid pascal end.'#10);
  WriteMarkerProgram('B.Pending.Test.pas', 'pending-ran', 0);
  R := RunTests(['--jobs=1', '--bail=1']);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(FScratch + '/control/pending-ran')).ToBe(False);
  Expect<Boolean>(Pos('A.Bad.Test.pas ... COMPILE FAILED', R.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('B.Pending.Test.pas ... cancelled', R.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.TestBailTerminatesActiveAndLeavesPendingUnstarted;
var
  R: TLwptResult;
  Started: TDateTime;
begin
  ResetProject(1);
  WriteTextFile(FScratch + '/tests/A.Slow.Test.pas',
      'program SlowFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses Classes, SysUtils;'#10
    + 'begin'#10
    + '  TFileStream.Create('
    + PascalString(FScratch + '/control/slow-started')
    + ', fmCreate).Free;'#10
    + '  Sleep(15000);'#10
    + '  TFileStream.Create('
    + PascalString(FScratch + '/control/slow-completed')
    + ', fmCreate).Free;'#10
    + 'end.'#10);
  WriteTextFile(FScratch + '/tests/B.Fail.Test.pas',
      'program FailFixture;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses SysUtils;'#10
    + 'var Started: TDateTime;'#10
    + 'begin'#10
    + '  Started := Now;'#10
    + '  while (not FileExists('
    + PascalString(FScratch + '/control/slow-started') + '))'#10
    + '    and ((Now - Started) * 86400 < 5) do Sleep(10);'#10
    + '  if not FileExists('
    + PascalString(FScratch + '/control/slow-started') + ') then Halt(2);'#10
    + '  Halt(1);'#10
    + 'end.'#10);
  WriteMarkerProgram('C.Pending.Test.pas', 'pending-ran', 0);
  Started := Now;
  R := RunTests(['--jobs=2']);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<Boolean>((Now - Started) * 86400 < 12).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/slow-started')).ToBe(True);
  Expect<Boolean>(FileExists(FScratch + '/control/slow-completed')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/control/pending-ran')).ToBe(False);
  Expect<Boolean>(Pos('A.Slow.Test.pas ... cancelled', R.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('B.Fail.Test.pas ... FAIL (exit 1)', R.Stdout) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('C.Pending.Test.pas ... cancelled', R.Stdout) > 0)
    .ToBe(True);
end;

procedure TTestScheduling.SetupTests;
begin
  Test('default jobs overlap', TestDefaultJobsOverlap);
  Test('--jobs=1 runs in source order', TestJobsOneRunsInSourceOrder);
  Test('--bail=0 overrides manifest and runs all',
    TestBailZeroOverridesManifestAndRunsAll);
  Test('compile failure counts toward bail',
    TestCompileFailureCountsTowardBail);
  Test('bail terminates active and leaves pending unstarted',
    TestBailTerminatesActiveAndLeavesPendingUnstarted);
end;

begin
  TestRunnerProgram.AddSuite(TTestScheduling.Create('TestScheduling'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
