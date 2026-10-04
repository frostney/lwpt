{ LWPT.Command.Common.Test — the staleness gate of hooks and run tasks
  (#367). Every modification time is set explicitly, so no test sleeps to
  cross a timestamp tick. The base second is even, which puts both stamps
  of a sub-second pair inside one SysUtils.FileAge tick on every platform:
  a whole second on Unix and a 2-second DOS tick on Windows. }

program LWPT.Command.Common.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Manifest,
  TestingPascalLibrary,
  Tests.Scratch;

const
  BaseSeconds = 1700000000;
  OutputNanoseconds = 500000000;
  { One millisecond after the output, in the same second. }
  NewerNanoseconds = 501000000;
  OlderNanoseconds = 100000000;
  OutputName = 'generated.out';

type
  THookStalenessTests = class(TTestSuite)
  private
    FRoot: string;
    function GatedHook(const AInputs: array of string): THook;
    procedure WriteStamped(const ARelativePath: string;
      const ANanoseconds: LongInt);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestInputNewerWithinOneSecondIsStale;
    procedure TestInputAsNewAsOutputIsStale;
    procedure TestOlderInputsAreFresh;
    procedure TestMissingOutputIsStale;
    procedure TestNewerInputInAnyGlobIsStale;
  end;

procedure THookStalenessTests.BeforeEach;
begin
  FRoot := CreateScratchRoot('hook-staleness');
end;

procedure THookStalenessTests.AfterEach;
begin
  RecursiveDelete(FRoot);
end;

function THookStalenessTests.GatedHook(
  const AInputs: array of string): THook;
var i: Integer;
begin
  Result := Default(THook);
  Result.Name := 'gen';
  SetLength(Result.Inputs, Length(AInputs));
  for i := 0 to High(AInputs) do Result.Inputs[i] := AInputs[i];
  Result.Output := OutputName;
end;

procedure THookStalenessTests.WriteStamped(const ARelativePath: string;
  const ANanoseconds: LongInt);
var Path: string;
begin
  Path := IncludeTrailingPathDelimiter(FRoot) + ARelativePath;
  WriteTextFile(Path, ARelativePath);
  SetFileModificationTime(Path, BaseSeconds, ANanoseconds);
end;

procedure THookStalenessTests.TestInputNewerWithinOneSecondIsStale;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', NewerNanoseconds);
  { The tick the old whole-second comparison could not see past. }
  Expect<Integer>(FileAge(IncludeTrailingPathDelimiter(FRoot) + 'lwpt.toml'))
    .ToBe(FileAge(IncludeTrailingPathDelimiter(FRoot) + OutputName));
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestInputAsNewAsOutputIsStale;
begin
  { A filesystem with coarse timestamps can give an edit made after the
    output the output's own time. Equal is therefore stale: never missing
    an edit costs at most one extra run. }
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OutputNanoseconds);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestOlderInputsAreFresh;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OlderNanoseconds);
  WriteStamped('src/a.pas', OlderNanoseconds);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml', 'src/*.pas']), FRoot))
    .ToBe(False);
end;

procedure THookStalenessTests.TestMissingOutputIsStale;
begin
  WriteStamped('lwpt.toml', OlderNanoseconds);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestNewerInputInAnyGlobIsStale;
var Hook: THook;
begin
  Hook := GatedHook(['src/*.pas', 'proto/**/*.proto']);
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('src/a.pas', OlderNanoseconds);
  WriteStamped('src/b.pas', OlderNanoseconds);
  WriteStamped('proto/v1/one.proto', OlderNanoseconds);
  WriteStamped('proto/v1/deep/two.proto', OlderNanoseconds);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(False);
  { One file of the second glob, edited a millisecond after the output. }
  WriteStamped('proto/v1/deep/two.proto', NewerNanoseconds);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

procedure THookStalenessTests.SetupTests;
begin
  Test('an input written a millisecond after the output, in the same second, is stale',
    TestInputNewerWithinOneSecondIsStale);
  Test('an input with the output''s exact time is stale',
    TestInputAsNewAsOutputIsStale);
  Test('inputs older than the output are fresh',
    TestOlderInputsAreFresh);
  Test('a missing output is stale', TestMissingOutputIsStale);
  Test('a newer file matched by any of several input globs is stale',
    TestNewerInputInAnyGlobIsStale);
end;

begin
  TestRunnerProgram.AddSuite(THookStalenessTests.Create('HookIsStale'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
