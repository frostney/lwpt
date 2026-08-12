{ TestingPascalLibrary.Test — the framework canary.

  The testing package's self-test. Every consumer's *.Test.pas file
  uses TestingPascalLibrary; if the framework breaks (an upstream
  change, an FPC version shift, a heap-corruption regression), every
  other *.Test.pas in the consumer either fails to compile or fails
  to report results, and the failure mode is opaque.

  This file is the canary. It exercises the framework's most basic
  invariants — instantiate a suite, register a test, run, observe
  the result — through nothing but writeln and exit-code assertions.
  If THIS file fails or fails to compile, the framework is what's
  broken, not the project's tests of it.

  The canary uses TestingPascalLibrary at arm's length: the simplest
  possible assertion (Expect<Boolean>(True).ToBe(True)) and a one-test
  suite. If TPL is genuinely broken, this file is what we look at first
  to narrow the blame; everything else stays opaque.

  earlier this lived in source/Tests.TestingPascalLibrary.Canary.Test.pas
  while TestingPascalLibrary was an embedded-blob in the lwpt binary
  (the `lwpt export testing` model). ADR-0015 graduated the testing
  framework to this workspace package, so the canary moves with the
  library and is named conventionally (PackageName.Test.pas) like
  every other package's self-test. }

program TestingPascalLibrary.Test;

{$mode delphi}{$H+}

uses
  SysUtils,

  TestingPascalLibrary,
  TestingPascalLibrary.Protocol;

type
  TCanarySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAddsAFakeAssertion;
    procedure TestInventoryRequestIsConsumedBeforeBodies;
  end;

  { Deliberately failing suite: pins Run's fail-the-process default
    (a failing suite sets ExitCode without per-program boilerplate). }
  TFailingCanarySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDeliberateFailure;
  end;

procedure TCanarySuite.SetupTests;
begin
  Test('canary always assigns FHasAssertions', TestAddsAFakeAssertion);
  Test('inventory authorization is consumed before test bodies',
    TestInventoryRequestIsConsumedBeforeBodies);
end;

procedure TCanarySuite.TestInventoryRequestIsConsumedBeforeBodies;
begin
  Expect<string>(GetEnvironmentVariable(TEST_INVENTORY_ENVIRONMENT)).ToBe('');
  Expect<string>(GetEnvironmentVariable(
    TEST_INVENTORY_EXECUTABLE_ENVIRONMENT)).ToBe('');
end;

procedure TFailingCanarySuite.SetupTests;
begin
  Test('deliberately failing assertion', TestDeliberateFailure);
end;

procedure TFailingCanarySuite.TestDeliberateFailure;
begin
  Expect<Boolean>(True).ToBe(False);
end;

procedure TCanarySuite.TestAddsAFakeAssertion;
begin
  if not Assigned(TestRunnerProgram) then
    Halt(11);   { framework initialization broken; not even a fair canary }
  if not Assigned(_ActiveTestSuite) then
    Self.Fail('_ActiveTestSuite was nil during a running test');
  { Single, minimal assertion. If THIS line fails, TPL is broken in
    a way the rest of the suite cannot diagnose for us. }
  Expect<Boolean>(True).ToBe(True);
end;

procedure TestInventoryProtocol;
var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create;
  try
    Runner.AddSuite(TCanarySuite.Create('inventory canary'));
    if Runner.InventoryLine <> TEST_INVENTORY_PREFIX + '1'#9'2' then
    begin
      WriteLn(ErrOutput, 'FATAL: inventory protocol mismatch: ',
        Runner.InventoryLine);
      Halt(15);
    end;
  finally
    Runner.Free;
  end;
end;

var
  Suite: TCanarySuite;
  Runner: TTestRunner;
  Passed, Failed: Integer;
  R: TTestResult;
begin
  TestInventoryProtocol;
  WriteLn('TestingPascalLibrary canary starting');

  if not Assigned(TestRunnerProgram) then
  begin
    WriteLn(ErrOutput, 'FATAL: TestRunnerProgram was nil at startup');
    Halt(10);
  end;

  { Build a tiny throwaway runner so the canary doesn't share state
    with TestRunnerProgram's globals. If TTestRunner's instantiation
    or AddSuite is broken, we crash here with a clear exit code. }
  Runner := TTestRunner.Create;
  try
    Suite := TCanarySuite.Create('canary');
    try
      Runner.AddSuite(Suite);
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'FATAL: Runner.AddSuite raised: ', E.Message);
        Halt(12);
      end;
    end;

    try
      Runner.Run;
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'FATAL: Runner.Run raised: ', E.Message);
        Halt(13);
      end;
    end;

    Passed := 0;
    Failed := 0;
    for R in Runner.Results do
      case R.Status of
        tsPass: Inc(Passed);
        tsFail: Inc(Failed);
      end;

    if (Passed <> 2) or (Failed <> 0) then
    begin
      WriteLn(ErrOutput, Format(
        'FATAL: expected 2 passes / 0 fail; got %d pass / %d fail',
        [Passed, Failed]));
      Halt(14);
    end;

    { A fully passing run must leave the process exit code alone. }
    if ExitCode <> 0 then
    begin
      WriteLn(ErrOutput, Format(
        'FATAL: passing Run set ExitCode to %d', [ExitCode]));
      Halt(15);
    end;
  finally
    Runner.Free;
  end;

  { Fail-the-process default: a failing suite run through a fresh
    throwaway runner must set ExitCode = 1 on its own — this is the
    contract lwpt test gates on, with no per-program boilerplate. }
  Runner := TTestRunner.Create;
  try
    Runner.AddSuite(TFailingCanarySuite.Create('failing canary'));
    try
      Runner.Run;
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'FATAL: failing-suite Run raised: ', E.Message);
        Halt(16);
      end;
    end;

    if ExitCode <> 1 then
    begin
      WriteLn(ErrOutput, Format(
        'FATAL: failing Run left ExitCode at %d, expected 1', [ExitCode]));
      Halt(17);
    end;
  finally
    Runner.Free;
  end;

  WriteLn('TestingPascalLibrary canary green');
  ExitCode := 0;
end.
