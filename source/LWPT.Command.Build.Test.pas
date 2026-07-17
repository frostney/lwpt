{ LWPT.Command.Build.Test — unit-tier coverage for the stale-artefact
  failure heuristic behind the `--clean` retry hint.

  Non-destructive clean rebuild behaviour is covered end-to-end by
  tests/integration/BuildClean.Test.pas through the real binary; this
  file stays at the unit level: pure string classification, no
  filesystem, no subprocess. }

program LWPT.Command.Build.Test;

{$mode delphi}{$H+}
{$modeswitch nestedcomments+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Command.Build,
  LWPT.Core,
  TestingPascalLibrary,
  Tests.Scratch;

const
  COMPILER_PROCESS_PROXY_OPTION = '--' + PROGRAM_NAME
    + '-compiler-process-proxy';

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
    procedure TestCompilerCancellationCapturesAndReaps;
  end;

  TCompilerRunnerThread = class(TThread)
  private
    FRunner: TLWPTCompilerProcess;
    FMarker: string;
  protected
    procedure Execute; override;
  public
    Output: string;
    ErrorMessage: string;
    ExitCode: Integer;
    constructor Create(ARunner: TLWPTCompilerProcess;
      const AMarker: string);
  end;

constructor TCompilerRunnerThread.Create(ARunner: TLWPTCompilerProcess;
  const AMarker: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRunner := ARunner;
  FMarker := AMarker;
  ExitCode := -1;
end;

procedure TCompilerRunnerThread.Execute;
begin
  try
    ExitCode := FRunner.Run([COMPILER_PROCESS_PROXY_OPTION, FMarker], Output);
  except
    on E: Exception do ErrorMessage := E.Message;
  end;
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
    'fpcres: Error: Cannot open file build/app.reslst')).ToBe(True);
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
    'Writing resource list build/app.reslst')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestEmptyOutputDoesNotMatch;
begin
  Expect<Boolean>(HasStaleArtefactSignature('')).ToBe(False);
end;

procedure TStaleArtefactSignature.TestCompilerCancellationCapturesAndReaps;
var
  Runner: TLWPTCompilerProcess;
  Worker: TCompilerRunnerThread;
  Scratch, Marker: string;
  Started: TDateTime;
begin
  Scratch := ExpandFileName('build/tests/tmp/compiler-process-cancel');
  Marker := Scratch + '/ready';
  RecursiveDelete(Scratch);
  Runner := TLWPTCompilerProcess.Create(ExpandFileName(ParamStr(0)));
  Worker := TCompilerRunnerThread.Create(Runner, Marker);
  try
    Worker.Start;
    Started := Now;
    while not FileExists(Marker) do
    begin
      if (Now - Started) * 86400 > 10 then Break;
      Sleep(10);
    end;
    Expect<Boolean>(FileExists(Marker)).ToBe(True);
    Runner.Cancel;
    Worker.WaitFor;
    Expect<string>(Worker.ErrorMessage).ToBe('');
    Expect<Boolean>(Worker.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos('captured-output-', Worker.Output) > 0).ToBe(True);
    Expect<Boolean>(Length(Worker.Output) > 65536).ToBe(True);
  finally
    Runner.Cancel;
    Worker.WaitFor;
    Worker.Free;
    Runner.Free;
    RecursiveDelete(Scratch);
  end;
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
  Test('compiler cancellation captures output and reaps the child',
    TestCompilerCancellationCapturesAndReaps);
end;

function RunCompilerProcessProxy: Integer;
var i: Integer;
begin
  for i := 1 to 6000 do Write('captured-output-');
  Flush(Output);
  WriteTextFile(ParamStr(2), 'ready');
  Sleep(30000);
  Result := 0;
end;

begin
  if (ParamCount >= 2)
     and (ParamStr(1) = COMPILER_PROCESS_PROXY_OPTION) then
    Halt(RunCompilerProcessProxy);
  TestRunnerProgram.AddSuite(TStaleArtefactSignature.Create(
    'build: stale-artefact failure signature'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
