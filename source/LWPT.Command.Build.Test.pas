{ LWPT.Command.Build.Test — unit-tier coverage for the stale-artefact
  failure heuristic behind the `--clean` retry hint.

  The sweep itself (SweepBuildArtefacts) is covered end-to-end by
  tests/integration/BuildClean.Test.pas through the real binary; this
  file stays at the unit level: pure string classification, no
  filesystem, no subprocess. }

program LWPT.Command.Build.Test;

{$mode delphi}{$H+}
{$modeswitch nestedcomments+}

uses
  SysUtils,

  LWPT.Command.Build,
  TestingPascalLibrary;

type
  TStaleArtefactSignature = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestInternalCompilerExceptionMatches;
    procedure TestResourceCompileErrorMatches;
    procedure TestMissingReslstMatches;
    procedure TestOrdinarySourceErrorDoesNotMatch;
    procedure TestReslstMentionAloneDoesNotMatch;
    procedure TestEmptyOutputDoesNotMatch;
  end;

procedure TStaleArtefactSignature.TestInternalCompilerExceptionMatches;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'Fatal: Compilation raised exception internally')).ToBe(True);
end;

procedure TStaleArtefactSignature.TestResourceCompileErrorMatches;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'Error while compiling resources -> compile with -vd for more details'))
    .ToBe(True);
end;

procedure TStaleArtefactSignature.TestMissingReslstMatches;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'fpcres: Error: Cannot open file build/lwpt.reslst')).ToBe(True);
end;

procedure TStaleArtefactSignature.TestOrdinarySourceErrorDoesNotMatch;
begin
  Expect<Boolean>(HasStaleArtefactSignature(
    'bad.pas(3,3) Error: Identifier not found "ThisDoesNotExist"'#10
    + 'Fatal: Compilation aborted')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestReslstMentionAloneDoesNotMatch;
begin
  { .reslst only signals staleness together with an open/read failure }
  Expect<Boolean>(HasStaleArtefactSignature(
    'Writing resource list build/lwpt.reslst')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestEmptyOutputDoesNotMatch;
begin
  Expect<Boolean>(HasStaleArtefactSignature('')).ToBe(False);
end;

procedure TStaleArtefactSignature.SetupTests;
begin
  Test('internal compiler exception matches',
    TestInternalCompilerExceptionMatches);
  Test('resource-compile error matches', TestResourceCompileErrorMatches);
  Test('missing .reslst matches', TestMissingReslstMatches);
  Test('ordinary source error does not match',
    TestOrdinarySourceErrorDoesNotMatch);
  Test('.reslst mention alone does not match',
    TestReslstMentionAloneDoesNotMatch);
  Test('empty output does not match', TestEmptyOutputDoesNotMatch);
end;

begin
  TestRunnerProgram.AddSuite(TStaleArtefactSignature.Create(
    'build: stale-artefact failure signature'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
