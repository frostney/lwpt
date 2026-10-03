{ StampVersion.Test — pins that scripts/stamp-version.pas, LWPT's own
  [prebuild] hook, is safe when several self-builds run it at once
  (issue #361).

  The script is copied into a scratch tool project (minus its InstantFPC
  shebang line) and compiled once with `lwpt build`, so every platform's
  toolchain configuration applies. Concurrent writers start together:
  each runs behind a gate (this program, re-entered with GATE_ARGUMENT)
  that announces itself with an existence-only ready file and starts the
  script only once the existence-only release file appears. Neither file
  carries content, so neither is a payload handoff. Every child is awaited
  to real completion under a deadline, then terminated and reaped if it
  overruns. Six assertions:

    1. Concurrent runs across changing versions all exit 0. This program
       reads the include continuously from before the release until every
       writer has exited; every read sees the complete previous or new
       text, never a truncated or partial file, and reads must overlap
       running writers. The final file holds exactly the new text, with
       SaveToFile's bytes (each line followed by LineEnding), and neither
       source/ nor the tmp directory keeps a temporary file.
    2. Concurrent runs whose expected text is already present leave the
       file untouched: its modification time stays at a value set in the
       past.
    3. Concurrent `lwpt build` runs of a project whose [prebuild] hook is
       the script all succeed: the hook's temporary file never enters the
       fingerprinted source/ tree, so no build is rejected for changed
       inputs, and the built program reports the new version.
    4. A `[lwpt] tmp-dir` that cannot be created makes the script stage
       beside the destination, still publishing exactly and leaving no
       temporary file.
    5. A target without a source/ directory fails without leaving any file
       behind.
    6. A destination that is a directory fails after the temporary file is
       written, and the temporary file is removed. }

program StampVersion.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  SCRIPT_PATH = 'scripts/stamp-version.pas';
  GATE_ARGUMENT = '--stamp-version-gate';
  INCLUDE_NAME = 'Version.inc';
  TEMP_PREFIX = 'stamp-version-';
  WRITER_COUNT = 6;
  ROUND_COUNT = 8;
  BUILD_COUNT = 3;
  BUILD_ROUND_COUNT = 3;
  { Deadlines are generous for slow Windows runners; none is unbounded. }
  BARRIER_MILLISECONDS = 60000;
  CHILD_MILLISECONDS = 120000;
  BUILD_MILLISECONDS = 600000;
  TERMINATION_GRACE_MILLISECONDS = 10000;
  POLL_MILLISECONDS = 1;
  { A past modification time that no run can reproduce by rewriting. }
  PAST_AGE_DAYS = 2;
  {$IFDEF MSWINDOWS}
  { The one open failure a Windows reader may meet while a replacement
    holds the path: ERROR_SHARING_VIOLATION. }
  READ_SHARING_VIOLATION = 32;
  {$ENDIF}

type
  { A child process awaited to real completion under a deadline. }
  TChild = class
  private
    FProcess: TProcess;
    FOutput: string;
    FExitCode: Integer;
    FFinished: Boolean;
  public
    constructor Create(const AExecutable, ADirectory: string;
      const AArguments, AEnvironment: array of string);
    destructor Destroy; override;
    procedure Drain;
    function Running: Boolean;
    procedure Finish(const ADeadline: QWord);
    property ExitCode: Integer read FExitCode;
    property Output: string read FOutput;
  end;
  TChildren = array of TChild;

  TReadStats = record
    Observations: Integer;
    { Reads that completed after the release while a writer still ran. }
    Overlapping: Integer;
    Torn: Integer;
    TornSample: string;
  end;

  TStampVersionTest = class(TTestSuite)
  private
    FOrigDir, FScratch, FTool, FTarget, FStampExe: string;
    FBarrier: Integer;
    procedure ResetTarget(const AWithSource: Boolean);
    procedure WriteTargetManifest(const AVersion: string;
      const AExtra: string = '');
    function IncludePath: string;
    function ExpectedText(const AVersion: string): string;
    function Observe(const AAllowed: array of string;
      var AStats: TReadStats): Boolean;
    function RunWriters(const AAllowed: array of string;
      out AStats: TReadStats): TChildren;
    procedure ExpectSucceeded(const AChildren: TChildren);
    procedure FreeChildren(var AChildren: TChildren);
    function RunStamp(const ADirectory: string): TChild;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestConcurrentRunsPublishCompleteText;
    procedure TestCurrentTextIsLeftUntouched;
    procedure TestConcurrentBuildsAreNotRejected;
    procedure TestUnavailableTmpDirStagesBesideDestination;
    procedure TestMissingSourceDirectoryFailsCleanly;
    procedure TestFailedReplacementRemovesTemporaryFile;
  end;

function VersionOverrideCleared: string;
begin
  { The release-tag override would change the expected text. }
  Result := PROJECT_NAME + '_VERSION_OVERRIDE=';
end;

constructor TChild.Create(const AExecutable, ADirectory: string;
  const AArguments, AEnvironment: array of string);
var
  Argument: string;
begin
  inherited Create;
  FExitCode := -1;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := AExecutable;
  FProcess.CurrentDirectory := ADirectory;
  FProcess.Options := [poUsePipes, poStderrToOutPut];
  for Argument in AArguments do FProcess.Parameters.Add(Argument);
  ConfigureProcessEnvironment(FProcess, AEnvironment);
  FProcess.Execute;
end;

destructor TChild.Destroy;
begin
  if not FFinished then
    try
      Finish(GetTickCount64);
    except
      on Exception do;
    end;
  FProcess.Free;
  inherited Destroy;
end;

procedure TChild.Drain;
begin
  if FProcess.Output.NumBytesAvailable > 0 then
    FOutput := FOutput + DrainAvailableStream(FProcess.Output);
end;

function TChild.Running: Boolean;
begin
  Drain;
  Result := FProcess.Running;
end;

{ Waits until the child has exited and, on Windows, until its process
  handle is signalled: GetExitCodeProcess reports the exit before the kernel
  runs down the child's handles, including its working directory. Past
  ADeadline the child is terminated, reaped within a grace period, and the
  overrun raises. }
procedure TChild.Finish(const ADeadline: QWord);
var
  TimedOut: Boolean;
  GraceEnd: QWord;
begin
  if FFinished then Exit;
  TimedOut := False;
  while Running do
  begin
    if GetTickCount64 >= ADeadline then
    begin
      TimedOut := True;
      FProcess.Terminate(1);
      Break;
    end;
    Sleep(POLL_MILLISECONDS);
  end;
  GraceEnd := GetTickCount64 + TERMINATION_GRACE_MILLISECONDS;
  while Running do
  begin
    if GetTickCount64 >= GraceEnd then
      raise Exception.CreateFmt('child %s did not exit after termination',
        [FProcess.Executable]);
    Sleep(POLL_MILLISECONDS);
  end;
  {$IFDEF MSWINDOWS}
  if not FProcess.WaitOnExit(TERMINATION_GRACE_MILLISECONDS) then
    raise Exception.CreateFmt('child %s exited but its handle never '
      + 'signalled', [FProcess.Executable]);
  {$ENDIF}
  Drain;
  { Mirrors RunLwpt: trust ExitStatus when ExitCode claims success. }
  FExitCode := FProcess.ExitCode;
  if (FExitCode = 0) and (FProcess.ExitStatus <> 0) then
    FExitCode := FProcess.ExitStatus;
  FFinished := True;
  if TimedOut then
    raise Exception.CreateFmt('child %s overran its deadline; output: %s',
      [FProcess.Executable, FOutput]);
end;

{ Child mode: ParamStr(2) is the ready file, 3 the release file, 4 the
  script executable. }
function RunGate: Integer;
var
  Deadline: QWord;
  Child: TChild;
begin
  try
    WriteTextFile(ParamStr(2), '');
    Deadline := GetTickCount64 + BARRIER_MILLISECONDS;
    while not FileExists(ParamStr(3)) do
    begin
      if GetTickCount64 >= Deadline then
      begin
        WriteLn('gate: never released');
        Exit(3);
      end;
      Sleep(POLL_MILLISECONDS);
    end;
    Child := TChild.Create(ParamStr(4), GetCurrentDir, [], []);
    try
      Child.Finish(GetTickCount64 + CHILD_MILLISECONDS);
      Write(Child.Output);
      Result := Child.ExitCode;
    finally
      Child.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('gate: ', E.Message);
      Result := 4;
    end;
  end;
end;

{ Reads APath to its end in chunks. It never trusts a size taken before the
  read, because an in-place writer can change the file between the two. }
function TryReadWhole(const APath: string; out AText: string;
  out AError: Integer): Boolean;
var
  Handle: THandle;
  Chunk: array[0..4095] of Byte;
  Got, Have: Integer;
begin
  AText := '';
  AError := 0;
  Handle := FileOpen(APath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
  begin
    AError := GetLastOSError;
    Exit(False);
  end;
  try
    repeat
      Got := FileRead(Handle, Chunk, SizeOf(Chunk));
      if Got > 0 then
      begin
        Have := Length(AText);
        SetLength(AText, Have + Got);
        Move(Chunk, AText[Have + 1], Got);
      end;
    until Got <= 0;
    if Got < 0 then
    begin
      AError := GetLastOSError;
      Exit(False);
    end;
  finally
    FileClose(Handle);
  end;
  Result := True;
end;

{ Every name in ADirectory, sorted and comma-joined; '' when absent. }
function DirectoryEntries(const ADirectory: string): string;
var
  SR: TSearchRec;
  Names: TStringList;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    if SysUtils.FindFirst(ADirectory + '/*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then Names.Add(SR.Name);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
    Names.Delimiter := ',';
    Names.StrictDelimiter := True;
    Result := Names.DelimitedText;
  finally
    Names.Free;
  end;
end;

function TimeLeft(const ADeadline: QWord): Boolean;
begin
  Result := GetTickCount64 < ADeadline;
end;

procedure TStampVersionTest.BeforeAll;
var
  R: TLwptResult;
  Script: string;
begin
  FOrigDir := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('stamp-version');
  FTool := FScratch + '/tool';
  FTarget := FScratch + '/target';
  FBarrier := 0;
  ForceDirectories(FTool);
  { InstantFPC skips the shebang line; the compiler does not. }
  Script := ReadBinaryFile(SCRIPT_PATH);
  if Copy(Script, 1, 2) = '#!' then
    Script := Copy(Script, Pos(#10, Script), MaxInt);
  WriteTextFile(FTool + '/stamp-version.pas', Script);
  WriteTextFile(FTool + '/lwpt.toml',
    '[package]'#10 +
    'name = "stamp-tool"'#10 +
    'version = "0.0.0"'#10 +
    ''#10 +
    '[build]'#10 +
    'stamp = { source = "stamp-version.pas", output = "build/stamp-version" }'#10);
  R := RunLwpt(['build'], FTool, [], BUILD_MILLISECONDS);
  DumpRunFailure('build stamp-version', R, 0);
  if R.TimedOut or (R.ExitCode <> 0) then
    raise Exception.Create('could not compile ' + SCRIPT_PATH);
  FStampExe := ExpandFileName(ExpectedExe(FTool + '/build/stamp-version'));
end;

procedure TStampVersionTest.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TStampVersionTest.ResetTarget(const AWithSource: Boolean);
begin
  RecursiveDelete(FTarget);
  ForceDirectories(FTarget);
  if AWithSource then ForceDirectories(FTarget + '/source');
end;

procedure TStampVersionTest.WriteTargetManifest(const AVersion: string;
  const AExtra: string);
begin
  WriteTextFile(FTarget + '/lwpt.toml',
    '[package]'#10 +
    'name = "stamp-target"'#10 +
    'version = "' + AVersion + '"'#10 +
    AExtra);
end;

function TStampVersionTest.IncludePath: string;
begin
  Result := FTarget + '/source/' + INCLUDE_NAME;
end;

function TStampVersionTest.ExpectedText(const AVersion: string): string;
begin
  { TStringList.SaveToFile's bytes, which the script must keep. }
  Result :=
    '{ Auto-generated by scripts/stamp-version.pas. Do not hand-edit. }'
    + LineEnding
    + '{ Source: [package].version in lwpt.toml. }' + LineEnding
    + LineEnding
    + '  PROGRAM_VERSION = ''' + AVersion + ''';' + LineEnding;
end;

{ Reads the include once. False when a Windows sharing violation kept the
  read from happening; any other failure or unexpected content is torn. }
function TStampVersionTest.Observe(const AAllowed: array of string;
  var AStats: TReadStats): Boolean;
var
  Seen: string;
  Error, Allowed: Integer;
  Matched: Boolean;
begin
  Result := True;
  if not TryReadWhole(IncludePath, Seen, Error) then
  begin
    {$IFDEF MSWINDOWS}
    if Error = READ_SHARING_VIOLATION then Exit(False);
    {$ENDIF}
    Inc(AStats.Torn);
    if AStats.TornSample = '' then
      AStats.TornSample := Format('read failed with OS error %d', [Error]);
    Exit;
  end;
  Inc(AStats.Observations);
  Matched := False;
  for Allowed := 0 to High(AAllowed) do
    if Seen = AAllowed[Allowed] then Matched := True;
  if Matched then Exit;
  Inc(AStats.Torn);
  if AStats.TornSample = '' then
    AStats.TornSample := Format('%d bytes: %s', [Length(Seen), Seen]);
end;

{ Starts WRITER_COUNT gated runs, releases them together, and reads the
  include until all have exited. Returns the finished writers. }
function TStampVersionTest.RunWriters(const AAllowed: array of string;
  out AStats: TReadStats): TChildren;
var
  Index: Integer;
  Release, GatePrefix: string;
  Ready: array of string;
  AllReady, AnyRunning, Observed: Boolean;
  Deadline: QWord;
begin
  AStats.Observations := 0;
  AStats.Overlapping := 0;
  AStats.Torn := 0;
  AStats.TornSample := '';
  Inc(FBarrier);
  GatePrefix := FScratch + '/gate-' + IntToStr(FBarrier);
  Release := GatePrefix + '-release';
  SetLength(Ready, WRITER_COUNT);
  Result := nil;
  SetLength(Result, WRITER_COUNT);
  for Index := 0 to High(Result) do Result[Index] := nil;
  try
    for Index := 0 to High(Result) do
    begin
      Ready[Index] := GatePrefix + '-ready-' + IntToStr(Index);
      Result[Index] := TChild.Create(ExpandFileName(ParamStr(0)), FTarget,
        [GATE_ARGUMENT, Ready[Index], Release, FStampExe],
        [VersionOverrideCleared]);
    end;

    Deadline := GetTickCount64 + BARRIER_MILLISECONDS;
    repeat
      AllReady := True;
      for Index := 0 to High(Result) do
      begin
        if not Result[Index].Running then
          raise Exception.Create('a gate exited before its release: '
            + Result[Index].Output);
        if not FileExists(Ready[Index]) then AllReady := False;
      end;
      if not AllReady then
      begin
        if not TimeLeft(Deadline) then
          raise Exception.Create('gates did not become ready in time');
        Sleep(POLL_MILLISECONDS);
      end;
    until AllReady;

    { The reader is running before any writer starts. }
    Observe(AAllowed, AStats);
    WriteTextFile(Release, '');
    Deadline := GetTickCount64 + CHILD_MILLISECONDS;
    repeat
      Observed := Observe(AAllowed, AStats);
      AnyRunning := False;
      for Index := 0 to High(Result) do
        if Result[Index].Running then AnyRunning := True;
      { The read just taken completed while a writer still ran. }
      if Observed and AnyRunning then Inc(AStats.Overlapping);
      {$IFDEF MSWINDOWS}
      { Let replacements land between reads. }
      Sleep(2);
      {$ENDIF}
      if AnyRunning and not TimeLeft(Deadline) then Break;
    until not AnyRunning;

    for Index := 0 to High(Result) do Result[Index].Finish(Deadline);
  except
    FreeChildren(Result);
    raise;
  end;
end;

procedure TStampVersionTest.ExpectSucceeded(const AChildren: TChildren);
var
  Index: Integer;
begin
  for Index := 0 to High(AChildren) do
  begin
    if AChildren[Index].ExitCode <> 0 then
      WriteLn(ErrOutput, 'child ', Index, ' exited ',
        AChildren[Index].ExitCode, ': ', AChildren[Index].Output);
    Expect<Integer>(AChildren[Index].ExitCode).ToBe(0);
  end;
end;

procedure TStampVersionTest.FreeChildren(var AChildren: TChildren);
var
  Index: Integer;
begin
  for Index := 0 to High(AChildren) do FreeAndNil(AChildren[Index]);
  SetLength(AChildren, 0);
end;

function TStampVersionTest.RunStamp(const ADirectory: string): TChild;
begin
  Result := TChild.Create(FStampExe, ADirectory, [],
    [VersionOverrideCleared]);
  try
    Result.Finish(GetTickCount64 + CHILD_MILLISECONDS);
  except
    Result.Free;
    raise;
  end;
end;

procedure TStampVersionTest.TestConcurrentRunsPublishCompleteText;
var
  Round, Overlapping, Torn: Integer;
  Previous, Current, FirstTornSample: string;
  Stats: TReadStats;
  Writers: TChildren;
begin
  ResetTarget(True);
  Previous := ExpectedText('1.0.0');
  WriteTextFile(IncludePath, Previous);
  Overlapping := 0;
  Torn := 0;
  FirstTornSample := '';
  for Round := 1 to ROUND_COUNT do
  begin
    WriteTargetManifest('1.0.' + IntToStr(Round));
    Current := ExpectedText('1.0.' + IntToStr(Round));
    Writers := RunWriters([Previous, Current], Stats);
    try
      ExpectSucceeded(Writers);
    finally
      FreeChildren(Writers);
    end;
    Inc(Overlapping, Stats.Overlapping);
    Inc(Torn, Stats.Torn);
    if FirstTornSample = '' then FirstTornSample := Stats.TornSample;
    Expect<string>(ReadBinaryFile(IncludePath)).ToBe(Current);
    Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
    Expect<string>(DirectoryEntries(FTarget + '/.lwpt/tmp')).ToBe('');
    Previous := Current;
  end;
  if Torn <> 0 then
    WriteLn(ErrOutput, 'torn reads: ', Torn, '; first: ', FirstTornSample);
  Expect<Integer>(Torn).ToBe(0);
  Expect<Boolean>(Overlapping > 0).ToBe(True);
end;

procedure TStampVersionTest.TestCurrentTextIsLeftUntouched;
var
  Past: LongInt;
  Current: string;
  Stats: TReadStats;
  Writers: TChildren;
  Index: Integer;
begin
  ResetTarget(True);
  WriteTargetManifest('2.0.0');
  Current := ExpectedText('2.0.0');
  WriteTextFile(IncludePath, Current);
  Past := DateTimeToFileDate(Now - PAST_AGE_DAYS);
  Expect<Integer>(FileSetDate(IncludePath, Past)).ToBe(0);

  Writers := RunWriters([Current], Stats);
  try
    ExpectSucceeded(Writers);
    for Index := 0 to High(Writers) do
      Expect<Boolean>(Pos('already current', Writers[Index].Output) > 0)
        .ToBe(True);
  finally
    FreeChildren(Writers);
  end;
  Expect<Integer>(Stats.Torn).ToBe(0);
  Expect<Boolean>(Stats.Overlapping > 0).ToBe(True);
  Expect<LongInt>(FileAge(IncludePath)).ToBe(Past);
  Expect<string>(ReadBinaryFile(IncludePath)).ToBe(Current);
  Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
end;

procedure TStampVersionTest.TestConcurrentBuildsAreNotRejected;
var
  Round, Index: Integer;
  Version, StampCommand, WorkerState: string;
  Builds: TChildren;
  App: TChild;
  Deadline: QWord;
begin
  ResetTarget(True);
  WorkerState := FScratch + '/workers';
  ForceDirectories(WorkerState);
  StampCommand := StringReplace(FStampExe, '\', '/', [rfReplaceAll]);
  WriteTextFile(FTarget + '/source/app.pas',
    'program app;'#10 +
    '{$mode delphi}{$H+}'#10 +
    'const'#10 +
    '{$I Version.inc}'#10 +
    'begin'#10 +
    '  WriteLn(PROGRAM_VERSION);'#10 +
    'end.'#10);
  for Round := 1 to BUILD_ROUND_COUNT do
  begin
    Version := '4.0.' + IntToStr(Round);
    WriteTargetManifest(Version,
      'units = ["source"]'#10 +
      ''#10 +
      '[prebuild]'#10 +
      'stamp-version = { command = "' + StampCommand + '", '
      + 'inputs = ["lwpt.toml"], output = "source/' + INCLUDE_NAME + '" }'#10 +
      ''#10 +
      '[build]'#10 +
      'app = { source = "source/app.pas", output = "build/app" }'#10);
    SetLength(Builds, BUILD_COUNT);
    for Index := 0 to High(Builds) do Builds[Index] := nil;
    try
      for Index := 0 to High(Builds) do
        Builds[Index] := TChild.Create(LwptBinaryPath, FTarget, ['build'],
          [VersionOverrideCleared,
           WORKER_STATE_DIR_ENV + '=' + WorkerState,
           WORKER_BUDGET_ENV + '=' + IntToStr(BUILD_COUNT),
           WORKER_LEASE_TOKEN_ENV + '=']);
      Deadline := GetTickCount64 + BUILD_MILLISECONDS;
      for Index := 0 to High(Builds) do Builds[Index].Finish(Deadline);
      ExpectSucceeded(Builds);
      for Index := 0 to High(Builds) do
        Expect<Boolean>(Pos('inputs changed', Builds[Index].Output) = 0)
          .ToBe(True);
    finally
      FreeChildren(Builds);
    end;
    Expect<string>(ReadBinaryFile(IncludePath)).ToBe(ExpectedText(Version));
    Expect<string>(DirectoryEntries(FTarget + '/source'))
      .ToBe('app.pas,' + INCLUDE_NAME);
    Expect<Boolean>(Pos(TEMP_PREFIX,
      DirectoryEntries(FTarget + '/.lwpt/tmp')) = 0).ToBe(True);
    App := TChild.Create(ExpandFileName(ExpectedExe(FTarget + '/build/app')),
      FTarget, [], []);
    try
      App.Finish(GetTickCount64 + CHILD_MILLISECONDS);
      Expect<Integer>(App.ExitCode).ToBe(0);
      Expect<string>(Trim(App.Output)).ToBe(Version);
    finally
      App.Free;
    end;
  end;
end;

procedure TStampVersionTest.TestUnavailableTmpDirStagesBesideDestination;
var
  Stamp: TChild;
begin
  ResetTarget(True);
  { A tmp directory below a regular file can never be created. }
  WriteTextFile(FTarget + '/blocker', 'not a directory');
  WriteTargetManifest('5.0.0', #10'[lwpt]'#10'tmp-dir = "blocker/tmp"'#10);
  Stamp := RunStamp(FTarget);
  try
    Expect<Integer>(Stamp.ExitCode).ToBe(0);
  finally
    Stamp.Free;
  end;
  Expect<string>(ReadBinaryFile(IncludePath)).ToBe(ExpectedText('5.0.0'));
  Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
  Expect<string>(DirectoryEntries(FTarget)).ToBe('blocker,lwpt.toml,source');
end;

procedure TStampVersionTest.TestMissingSourceDirectoryFailsCleanly;
var
  Stamp: TChild;
begin
  ResetTarget(False);
  WriteTargetManifest('3.0.0');
  Stamp := RunStamp(FTarget);
  try
    Expect<Boolean>(Stamp.ExitCode <> 0).ToBe(True);
  finally
    Stamp.Free;
  end;
  { The tmp directory may exist; nothing may be left in it. }
  Expect<string>(DirectoryEntries(FTarget + '/.lwpt/tmp')).ToBe('');
  Expect<Boolean>(DirectoryExists(FTarget + '/source')).ToBe(False);
end;

procedure TStampVersionTest.TestFailedReplacementRemovesTemporaryFile;
var
  Stamp: TChild;
begin
  ResetTarget(True);
  WriteTargetManifest('6.0.0');
  { A directory at the destination makes the replacement fail only after
    the temporary file is complete. }
  ForceDirectories(IncludePath + '/occupied');
  Stamp := RunStamp(FTarget);
  try
    Expect<Boolean>(Stamp.ExitCode <> 0).ToBe(True);
    Expect<Boolean>(Pos(TEMP_PREFIX, Stamp.Output) > 0).ToBe(True);
  finally
    Stamp.Free;
  end;
  Expect<string>(DirectoryEntries(FTarget + '/.lwpt/tmp')).ToBe('');
  Expect<string>(DirectoryEntries(FTarget + '/source')).ToBe(INCLUDE_NAME);
  Expect<string>(DirectoryEntries(IncludePath)).ToBe('occupied');
end;

procedure TStampVersionTest.SetupTests;
begin
  Test('concurrent runs across changing versions publish complete text '
    + 'and leave no temporary file', TestConcurrentRunsPublishCompleteText);
  Test('concurrent runs whose text is already present leave the file '
    + 'untouched', TestCurrentTextIsLeftUntouched);
  Test('concurrent lwpt builds running the hook are not rejected for '
    + 'changed inputs', TestConcurrentBuildsAreNotRejected);
  Test('an unavailable tmp directory stages beside the destination',
    TestUnavailableTmpDirStagesBesideDestination);
  Test('a target without source/ fails without leaving files behind',
    TestMissingSourceDirectoryFailsCleanly);
  Test('a failed replacement removes its written temporary file',
    TestFailedReplacementRemovesTemporaryFile);
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = GATE_ARGUMENT) then
  begin
    ExitCode := RunGate;
    Exit;
  end;
  TestRunnerProgram.AddSuite(TStampVersionTest.Create(
    'stamp-version: concurrent runs'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
