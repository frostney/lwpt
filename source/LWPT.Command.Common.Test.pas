{ LWPT.Command.Common.Test — the staleness gate of hooks and run tasks
  (#367): modification times, plus the content recorded by the last
  successful run. Every modification time is set explicitly, so no test sleeps to
  cross a timestamp tick. The base second is even, which puts both stamps
  of a sub-second pair inside one SysUtils.FileAge tick on every platform:
  a whole second on Unix and a 2-second DOS tick on Windows. Fresh inputs
  are two whole seconds older than the output, so they stay older on a
  filesystem that keeps whole or even seconds. The cases that depend on
  sub-second precision or on wide dates are chosen by probing the scratch
  filesystem, and their names say which variant ran. }

program LWPT.Command.Common.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest,
  TestingPascalLibrary,
  Tests.Scratch;

const
  BaseSeconds = 1700000000;
  OutputNanoseconds = 500000000;
  { One millisecond after the output, in the same second. }
  NewerNanoseconds = 501000000;
  { Two whole seconds before the output: older at any timestamp precision,
    the 2-second DOS tick included. }
  OlderSeconds = BaseSeconds - 2;
  OlderNanoseconds = 100000000;
  OutputName = 'generated.out';

type
  THookStalenessTests = class(TTestSuite)
  private
    FRoot: string;
    function GatedHook(const AInputs: array of string): THook;
    procedure WriteStamped(const ARelativePath: string;
      const ANanoseconds: LongInt); overload;
    procedure WriteStamped(const ARelativePath: string;
      const ASeconds: Int64; const ANanoseconds: LongInt); overload;
    function StampOf(const ARelativePath: string): TLWPTModificationStamp;
    procedure RecordRun(const AHook: THook);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestInputNewerWithinOneSecondIsStale;
    procedure TestInputInOutputTickIsStaleOnCoarseFilesystem;
    procedure TestFarFutureInputIsStale;
    procedure TestInputAsNewAsOutputIsStale;
    procedure TestOlderInputsAreFresh;
    procedure TestMissingOutputIsStale;
    procedure TestNewerInputInAnyGlobIsStale;
    procedure TestUnrecordedRunIsStale;
    procedure TestReplacedOutputNewerThanInputsIsStale;
    procedure TestChangedInputContentWithOlderTimeIsStale;
    procedure TestChangedDeclarationIsStale;
    procedure TestRecordedRunStaysFreshAcrossChecks;
    procedure TestInputEditedDuringRunIsNotRecorded;
    procedure TestSessionPrivateOutputKeepsNoRecord;
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
begin
  WriteStamped(ARelativePath, BaseSeconds, ANanoseconds);
end;

procedure THookStalenessTests.WriteStamped(const ARelativePath: string;
  const ASeconds: Int64; const ANanoseconds: LongInt);
var Path: string;
begin
  Path := IncludeTrailingPathDelimiter(FRoot) + ARelativePath;
  WriteTextFile(Path, ARelativePath);
  SetFileModificationTime(Path, ASeconds, ANanoseconds);
end;

function THookStalenessTests.StampOf(
  const ARelativePath: string): TLWPTModificationStamp;
begin
  Expect<Boolean>(LongPathModificationStamp(
    IncludeTrailingPathDelimiter(FRoot) + ARelativePath, Result)).ToBe(True);
end;

{ What RunHooks and RunUserTask do after the command succeeds: digest the
  inputs as the gate saw them, then record them with the output's content. }
procedure THookStalenessTests.RecordRun(const AHook: THook);
var
  InputDigest: string;
begin
  HookIsStale(AHook, FRoot, InputDigest);
  Expect<Boolean>(InputDigest <> '').ToBe(True);
  RecordHookRun(AHook, FRoot, InputDigest);
end;

{ Registered where the filesystem keeps sub-second times. }
procedure THookStalenessTests.TestInputNewerWithinOneSecondIsStale;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', NewerNanoseconds);
  { The tick the old whole-second comparison could not see past. }
  Expect<Integer>(FileAge(IncludeTrailingPathDelimiter(FRoot) + 'lwpt.toml'))
    .ToBe(FileAge(IncludeTrailingPathDelimiter(FRoot) + OutputName));
  Expect<Integer>(CompareModificationStamps(StampOf('lwpt.toml'),
    StampOf(OutputName))).ToBe(1);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

{ Registered where the filesystem drops sub-second times: the same edit
  reads as the output's own time, and the equality fallback runs it. }
procedure THookStalenessTests.TestInputInOutputTickIsStaleOnCoarseFilesystem;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', NewerNanoseconds);
  Expect<Integer>(CompareModificationStamps(StampOf('lwpt.toml'),
    StampOf(OutputName))).ToBe(0);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

{ An input dated past 2262, where a 64-bit nanosecond count since 1970
  overflows, is still newer than a 2023 output. }
procedure THookStalenessTests.TestFarFutureInputIsStale;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', FarFutureUnixSeconds, 0);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestInputAsNewAsOutputIsStale;
begin
  { A filesystem with coarse timestamps can give an edit made after the
    output the output's own time. Equal is therefore stale, so an edit is
    never missed; the command re-runs until its output is strictly newer
    than every input. }
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OutputNanoseconds);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestOlderInputsAreFresh;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  WriteStamped('src/a.pas', OlderSeconds, OlderNanoseconds);
  RecordRun(GatedHook(['lwpt.toml', 'src/*.pas']));
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml', 'src/*.pas']), FRoot))
    .ToBe(False);
end;

procedure THookStalenessTests.TestMissingOutputIsStale;
begin
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestNewerInputInAnyGlobIsStale;
var Hook: THook;
begin
  Hook := GatedHook(['src/*.pas', 'proto/**/*.proto']);
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('src/a.pas', OlderSeconds, OlderNanoseconds);
  WriteStamped('src/b.pas', OlderSeconds, OlderNanoseconds);
  WriteStamped('proto/v1/one.proto', OlderSeconds, OlderNanoseconds);
  WriteStamped('proto/v1/deep/two.proto', OlderSeconds, OlderNanoseconds);
  RecordRun(Hook);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(False);
  { One file of the second glob, edited a millisecond after the output: newer
    at sub-second precision, equal (so also stale) on a coarse filesystem. }
  WriteStamped('proto/v1/deep/two.proto', NewerNanoseconds);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

{ An output that no successful run recorded, such as the committed output
  of a fresh clone, runs once even when every input is older. }
procedure THookStalenessTests.TestUnrecordedRunIsStale;
begin
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  Expect<Boolean>(HookIsStale(GatedHook(['lwpt.toml']), FRoot)).ToBe(True);
end;

{ The reported trap: resolving a merge conflict by checking out one side
  of the generated file writes an output from another generation after
  the merged inputs, so it is newer than every input and still stale. }
procedure THookStalenessTests.TestReplacedOutputNewerThanInputsIsStale;
var
  Hook: THook;
  OutputPath: string;
begin
  Hook := GatedHook(['lwpt.toml']);
  WriteStamped(OutputName, OlderSeconds, OlderNanoseconds + 1000000);
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  RecordRun(Hook);
  OutputPath := IncludeTrailingPathDelimiter(FRoot) + OutputName;
  WriteTextFile(OutputPath, 'the other branch''s generation');
  SetFileModificationTime(OutputPath, BaseSeconds, OutputNanoseconds);
  Expect<Integer>(CompareModificationStamps(StampOf(OutputName),
    StampOf('lwpt.toml'))).ToBe(1);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

{ An input rewritten with an older time, as a checkout or an archive
  extraction can leave it, is stale by its content. }
procedure THookStalenessTests.TestChangedInputContentWithOlderTimeIsStale;
var
  Hook: THook;
  InputPath: string;
begin
  Hook := GatedHook(['src/*.pas']);
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('src/a.pas', OlderSeconds, OlderNanoseconds);
  RecordRun(Hook);
  InputPath := IncludeTrailingPathDelimiter(FRoot) + 'src/a.pas';
  WriteTextFile(InputPath, 'merged content');
  SetFileModificationTime(InputPath, OlderSeconds, OlderNanoseconds);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

procedure THookStalenessTests.TestChangedDeclarationIsStale;
var
  Hook: THook;
begin
  Hook := GatedHook(['lwpt.toml']);
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  RecordRun(Hook);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(False);
  Hook.Runnable.Command := 'generate';
  SetLength(Hook.Runnable.Args, 1);
  Hook.Runnable.Args[0] := '--other';
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

{ Checking does not consume the record: unchanged inputs and output skip
  on every later invocation. }
procedure THookStalenessTests.TestRecordedRunStaysFreshAcrossChecks;
var
  Hook: THook;
begin
  Hook := GatedHook(['lwpt.toml']);
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  RecordRun(Hook);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(False);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(False);
end;

{ An input edited while the command ran may not have reached the output.
  Recording the pre-run digest with that output would let a later revert
  of the input pass as fresh, so nothing is recorded. }
procedure THookStalenessTests.TestInputEditedDuringRunIsNotRecorded;
var
  Hook: THook;
  InputDigest, InputPath: string;
begin
  Hook := GatedHook(['lwpt.toml']);
  InputPath := IncludeTrailingPathDelimiter(FRoot) + 'lwpt.toml';
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  HookIsStale(Hook, FRoot, InputDigest);
  { The run: the input changes mid-run and the output reflects the edit. }
  WriteTextFile(InputPath, 'edited during the run');
  SetFileModificationTime(InputPath, OlderSeconds, OlderNanoseconds);
  WriteStamped(OutputName, OutputNanoseconds);
  RecordHookRun(Hook, FRoot, InputDigest);
  { Revert the input to the content the run started from. }
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

{ A per-entry postbuild output retargeted to a session's private candidate
  changes path with every session, so it never gets a record. }
procedure THookStalenessTests.TestSessionPrivateOutputKeepsNoRecord;
var
  Hook: THook;
  InputDigest: string;
begin
  Hook := GatedHook(['lwpt.toml']);
  Hook.SessionPrivateOutput := True;
  WriteStamped(OutputName, OutputNanoseconds);
  WriteStamped('lwpt.toml', OlderSeconds, OlderNanoseconds);
  HookIsStale(Hook, FRoot, InputDigest);
  RecordHookRun(Hook, FRoot, InputDigest);
  Expect<Boolean>(DirectoryExists(IncludeTrailingPathDelimiter(FRoot)
    + '.lwpt/sessions/hook-runs')).ToBe(False);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

procedure THookStalenessTests.SetupTests;
var
  Support: TTimestampSupport;
begin
  Support := ProbeTimestampSupport;
  if Support.SubSecond then
    Test('an input written a millisecond after the output, in the same second, is stale',
      TestInputNewerWithinOneSecondIsStale)
  else
    Test('an input written in the output''s timestamp tick is stale (filesystem keeps no sub-second times)',
      TestInputInOutputTickIsStaleOnCoarseFilesystem);
  Test('an input with the output''s exact time is stale',
    TestInputAsNewAsOutputIsStale);
  Test('inputs older than the output are fresh',
    TestOlderInputsAreFresh);
  Test('a missing output is stale', TestMissingOutputIsStale);
  Test('a newer file matched by any of several input globs is stale',
    TestNewerInputInAnyGlobIsStale);
  Test('an output no successful run recorded is stale',
    TestUnrecordedRunIsStale);
  Test('an output replaced after the run is stale though newer than every input',
    TestReplacedOutputNewerThanInputsIsStale);
  Test('an input whose content changed is stale though older than the output',
    TestChangedInputContentWithOlderTimeIsStale);
  Test('a changed command or argument is stale', TestChangedDeclarationIsStale);
  Test('a recorded run stays fresh across checks',
    TestRecordedRunStaysFreshAcrossChecks);
  Test('an input edited during the run is not recorded',
    TestInputEditedDuringRunIsNotRecorded);
  Test('a session-private output keeps no record',
    TestSessionPrivateOutputKeepsNoRecord);
  if Support.WideDates then
    Test('an input dated 2300 is newer than a 2023 output',
      TestFarFutureInputIsStale)
  else
    Skip('an input dated 2300 is newer than a 2023 output',
      TestFarFutureInputIsStale, 'the filesystem does not keep that date');
end;

begin
  TestRunnerProgram.AddSuite(THookStalenessTests.Create('HookIsStale'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
