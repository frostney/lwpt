{ LWPT.Command.Common.Test — the staleness gate of hooks and run tasks
  (#367). Every modification time is set explicitly, so no test sleeps to
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
  { AppendCompilerSearchDirectories against FPC 3.2's own search-path
    resolution (TSearchPathList.AddLibraryPath in compiler/cfileutl.pas). }
  TCompilerSearchDirectoryTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestEachSearchOptionNamesItsDirectories;
    procedure TestEqualsPrefixIsRelativeToEmptySysroot;
    procedure TestLibraryEqualsPrefixFollowsEverySysroot;
    procedure TestQuotedWildcardAndMacroEntries;
    procedure TestPathSeparatorSplitsEntries;
  end;

  THookStalenessTests = class(TTestSuite)
  private
    FRoot: string;
    function GatedHook(const AInputs: array of string): THook;
    procedure WriteStamped(const ARelativePath: string;
      const ANanoseconds: LongInt); overload;
    procedure WriteStamped(const ARelativePath: string;
      const ASeconds: Int64; const ANanoseconds: LongInt); overload;
    function StampOf(const ARelativePath: string): TLWPTModificationStamp;
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
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(False);
  { One file of the second glob, edited a millisecond after the output: newer
    at sub-second precision, equal (so also stale) on a coarse filesystem. }
  WriteStamped('proto/v1/deep/two.proto', NewerNanoseconds);
  Expect<Boolean>(HookIsStale(Hook, FRoot)).ToBe(True);
end;

{ The directories AOptions name, joined by "|". }
function SearchDirectories(const AOptions: array of string): string;
var
  Directories: TStringArray;
  i: Integer;
begin
  SetLength(Directories, 0);
  AppendCompilerSearchDirectories(AOptions, Directories);
  Result := '';
  for i := 0 to High(Directories) do
  begin
    if i > 0 then Result := Result + '|';
    Result := Result + Directories[i];
  end;
end;

procedure TCompilerSearchDirectoryTests.TestEachSearchOptionNamesItsDirectories;
begin
  Expect<string>(SearchDirectories(['-Fuunits', '-Fiincs', '-Foobjs',
    '-Fllibs', '-Iinc2', '-FEout', '-FUunitout', '-dDEBUG', '-Fu', '# -Fux']))
    .ToBe('units|incs|objs|libs|inc2');
end;

procedure TCompilerSearchDirectoryTests.TestEqualsPrefixIsRelativeToEmptySysroot;
begin
  { FPC passes an empty sysroot for every option but -Fl, so "=incs" is
    "incs" and "=/abs" is "/abs", whatever -XR says. }
  Expect<string>(SearchDirectories(['-XR/fpc-sysroot', '-Fi=incs',
    '-Fu=/abs/units', '-I=inc2', '-Fo=objs']))
    .ToBe('incs|/abs/units|inc2|objs');
end;

procedure TCompilerSearchDirectoryTests.TestLibraryEqualsPrefixFollowsEverySysroot;
begin
  { -Fl prefixes the sysroot that the last -XR before it set; option order
    across the cfg file, flags and profile arguments decides which one, so
    every candidate is watched, the empty sysroot included. }
  Expect<string>(SearchDirectories(['-Fl=/fn-lib', '-XR/fpc-sysroot',
    '-XR/other-root', '-Flplain']))
    .ToBe('/fpc-sysroot/fn-lib|/other-root/fn-lib|/fn-lib|plain');
  Expect<string>(SearchDirectories(['-Fl=/fn-lib'])).ToBe('/fn-lib');
end;

procedure TCompilerSearchDirectoryTests.TestQuotedWildcardAndMacroEntries;
begin
  { FPC removes Pascal quotes before it looks for "=", so a quoted entry
    after "=" keeps its quotes. }
  Expect<string>(SearchDirectories(['-Fi''quoted dir''', '-Fu"double"',
    '-Fuextra/*/units', '-Fiextra/$FPCTARGET', '-Fu$FPCDIR/units',
    '-Fi=''eq''', '-Fi''unterminated']))
    .ToBe('quoted dir|double|"double"|extra/|extra/|.|''eq''|''unterminated');
end;

procedure TCompilerSearchDirectoryTests.TestPathSeparatorSplitsEntries;
begin
  {$IFDEF MSWINDOWS}
  Expect<string>(SearchDirectories(['-Fumissing;C:\units', '-Fi;incs']))
    .ToBe('missing|C:\units|incs');
  {$ELSE}
  { FPC turns the platform path separator into ";" before it splits. }
  Expect<string>(SearchDirectories(['-Fumissing;units:=incs', '-Fi;:incs']))
    .ToBe('missing|units|incs|incs');
  {$ENDIF}
end;

procedure TCompilerSearchDirectoryTests.SetupTests;
begin
  Test('each search option names its directories',
    TestEachSearchOptionNamesItsDirectories);
  Test('a leading "=" is relative to an empty sysroot outside -Fl',
    TestEqualsPrefixIsRelativeToEmptySysroot);
  Test('a leading "=" in -Fl follows every -XR sysroot',
    TestLibraryEqualsPrefixFollowsEverySysroot);
  Test('quoted, wildcard and macro entries name their fixed directory',
    TestQuotedWildcardAndMacroEntries);
  Test('the platform path separator splits entries',
    TestPathSeparatorSplitsEntries);
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
  if Support.WideDates then
    Test('an input dated 2300 is newer than a 2023 output',
      TestFarFutureInputIsStale)
  else
    Skip('an input dated 2300 is newer than a 2023 output',
      TestFarFutureInputIsStale, 'the filesystem does not keep that date');
end;

begin
  TestRunnerProgram.AddSuite(THookStalenessTests.Create('HookIsStale'));
  TestRunnerProgram.AddSuite(TCompilerSearchDirectoryTests.Create(
    'AppendCompilerSearchDirectories'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
