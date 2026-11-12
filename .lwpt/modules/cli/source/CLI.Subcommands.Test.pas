{ CLI.Subcommands.Test — registry surface and dispatch coverage.

  The registry is the single source of truth for a program's command
  surface; Count / Item read iteration is what surface-rendering
  consumers (help printers, the host program's agent-facing reference
  generator) build on. The first suite pins the iteration contract —
  registration order, exact objects — in-process.

  The second suite pins what a host program configures: its description,
  top-level flags, opt-in subcommand aliasing, argument pass-through, the
  end-of-options marker, and usage errors. Dispatch that prints nothing
  runs in-process through the Run overload that takes the arguments;
  anything that writes help or a diagnostic runs in a child of this
  binary so both output streams can be read apart. }

program CLI.Subcommands.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  Pipes,
  Process,
  SysUtils,

  CLI.Options,
  CLI.Parser,
  CLI.Subcommands,
  TestingPascalLibrary;

type
  TSubcommandRegistrySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCountAndItemFollowRegistrationOrder;
    procedure TestFindReturnsTheRegisteredObject;
    procedure TestItemExposesOptionObjects;
    procedure TestItemOutOfRangeRaises;
    procedure TestCompletionCallbackReceivesDispatchMetadata;
    procedure TestCompletionCallbackCannotReplaceDispatchResult;
    procedure TestSharedFlagIsInheritedByExistingAndFutureCommands;
    procedure TestSharedFlagRejectsCommandOptionCollisions;
  end;

  THostDispatchSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestUnconfiguredRegistryKeepsItsDefaults;
    procedure TestPassThroughHandsTheRestOfTheLineToTheHandler;
    procedure TestPassThroughReadsItsOptionsBeforeTheFirstPositional;
    procedure TestSubcommandNameIsAnOperandWithoutAliasing;
    procedure TestAliasingDispatchesTheNamedSubcommandWhenOptedIn;
    procedure TestEndOfOptionsMarkerKeepsHelpSpellingsPositional;
    procedure TestTopLevelFlagRunsItsHandlerInsteadOfACommand;
    procedure TestTopLevelFlagsIterateInRegistrationOrder;
    procedure TestTopLevelFlagRegistrationRefusals;
    procedure TestSubcommandCannotTakeATopLevelFlagWord;
    procedure TestHandlerExitCodeIsReturnedUnchanged;
    procedure TestSharedFlagUsageLeadsAPassThroughCommand;
    procedure TestConfiguredTopLevelHelp;
    procedure TestUnconfiguredTopLevelHelpHasNoDescriptionLine;
    procedure TestTopLevelFlagBareWordIsOptIn;
    procedure TestConfiguredUsageErrors;
    procedure TestUnconfiguredUsageErrors;
    procedure TestPassThroughHelp;
    procedure TestHelpWordOutsidePassThrough;
    procedure TestOptionValueIsNeverAHelpRequest;
    procedure TestStrictSingleDashIsOptIn;
    procedure TestStrictSingleDashUsageErrors;
    procedure TestCommandHelpListsOptionShortNames;
  end;

var
  CompletionCount : Integer = 0;
  CapturedCompletion : TSubcommandCompletion;
  { What the recording handlers saw last. }
  DispatchCount : Integer = 0;
  DispatchedCommand : string = '';
  DispatchedPositionals : string = '';
  DispatchedOptions : string = '';
  TopLevelFlagCalls : Integer = 0;
  { Set in the host children, which then print a `command:` line for a
    dispatch and the version line for the version flag, so the parent can
    tell either from a help page on standard output. }
  EchoDispatch : Boolean = False;

const
  NONZERO_HANDLER_EXIT_CODE = 7;
  { Every child dispatches one command line and exits at once. }
  CHILD_TIMEOUT_MILLISECONDS = 60000;
  { Child modes: the arguments after the mode word are the host's. }
  HOST_CHILD_MODE = '--host-child';
  UNCONFIGURED_CHILD_MODE = '--unconfigured-child';
  { The host registry with StrictSingleDash set. }
  STRICT_HOST_CHILD_MODE = '--strict-host-child';
  HOST_PROGRAM_NAME = 'host';
  UNCONFIGURED_PROGRAM_NAME = 'fixture';
  HOST_USAGE_EXIT_CODE = 2;
  VERSION_FLAG_EXIT_CODE = 3;
  BUILD_INFO_FLAG_EXIT_CODE = 4;
  LIST_SEPARATOR = '|';

procedure CaptureCompletion(const ACompletion: TSubcommandCompletion);
begin
  Inc(CompletionCount);
  CapturedCompletion := ACompletion;
end;

procedure RaiseFromCompletion(const ACompletion: TSubcommandCompletion);
begin
  Inc(CompletionCount);
  CapturedCompletion := ACompletion;
  raise Exception.Create('completion callback failed');
end;

function StubHandler(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  Result := 0;
end;

function NonzeroHandler(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  Result := NONZERO_HANDLER_EXIT_CODE;
end;

procedure RecordDispatch(const ACommand: string;
  const APositionals: TStringList; const AOptions: TOptionArray);
var
  Index: Integer;
begin
  Inc(DispatchCount);
  DispatchedCommand := ACommand;
  DispatchedPositionals := '';
  for Index := 0 to APositionals.Count - 1 do
  begin
    if Index > 0 then
      DispatchedPositionals := DispatchedPositionals + LIST_SEPARATOR;
    DispatchedPositionals := DispatchedPositionals + APositionals[Index];
  end;
  DispatchedOptions := '';
  for Index := 0 to High(AOptions) do
    if AOptions[Index].Present then
    begin
      if DispatchedOptions <> '' then
        DispatchedOptions := DispatchedOptions + LIST_SEPARATOR;
      DispatchedOptions := DispatchedOptions + AOptions[Index].LongName;
    end;
  if EchoDispatch then
    WriteLn('command: ', ACommand);
end;

procedure ResetDispatch;
begin
  DispatchCount := 0;
  DispatchedCommand := '';
  DispatchedPositionals := '';
  DispatchedOptions := '';
  TopLevelFlagCalls := 0;
  CompletionCount := 0;
end;

function RecordRun(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  RecordDispatch('run', APositionals, AOptions);
  Result := 0;
end;

function RecordBuild(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  RecordDispatch('build', APositionals, AOptions);
  Result := 0;
end;

function HandleVersionFlag: Integer;
begin
  Inc(TopLevelFlagCalls);
  if EchoDispatch then WriteLn(HOST_PROGRAM_NAME, ' 1.2.3');
  Result := VERSION_FLAG_EXIT_CODE;
end;

function HandleBuildInfoFlag: Integer;
begin
  Inc(TopLevelFlagCalls);
  Result := BUILD_INFO_FLAG_EXIT_CODE;
end;

function RejectTheRejectCommand(const ACommandName: string;
  const AOptions: TOptionArray): string;
begin
  if ACommandName = 'reject' then
    Result := 'not allowed'
  else
    Result := '';
end;

{ A host that configures everything the registry lets a host choose:
  a description, two listed top-level flags and a hidden one, a shared
  flag, a pass-through `run`, a usage exit code of its own, usage help on
  standard error, and a bare invocation that is a usage error. }
function BuildHostRegistry: TSubcommandRegistry;
var
  RunOptions, BuildOptions, NoOptions : TOptionArray;
  RunCommand : TSubcommand;
  Flag : TTopLevelFlag;
  OutputOption : TStringOption;
begin
  Result := TSubcommandRegistry.Create;
  Result.Description := 'demo host';
  Result.UsageExitCode := HOST_USAGE_EXIT_CODE;
  Result.UsageHelpToStandardError := True;
  Result.BareInvocation := biUsageError;
  Result.OnCommandPrepared := @RejectTheRejectCommand;

  Flag := TTopLevelFlag.Create('version', 'Print the version',
    @HandleVersionFlag);
  Flag.ShortName := 'V';
  Flag.BareWord := True;
  Result.AddTopLevelFlag(Flag);
  Result.AddTopLevelFlag(TTopLevelFlag.Create('license', 'Print the license',
    @HandleBuildInfoFlag));
  Result.AddTopLevelFlag(TTopLevelFlag.Create('build-info', '',
    @HandleBuildInfoFlag));

  Result.AddSharedFlag('json', 'Print diagnostics as JSON');

  SetLength(RunOptions, 2);
  RunOptions[0] := TFlagOption.Create('unchecked',
    'Remove the runtime checks');
  RunOptions[1] := TStringOption.Create('mode', 'Execution mode');
  RunCommand := TSubcommand.Create('run', 'Run a program',
    '<file> [arguments]', @RecordRun, RunOptions);
  RunCommand.PassThrough := True;
  Result.Add(RunCommand);

  SetLength(BuildOptions, 3);
  BuildOptions[0] := TFlagOption.Create('release', 'Optimize');
  BuildOptions[1] := TIntegerOption.Create('level', 'Optimization level');
  OutputOption := TStringOption.Create('output', 'Output path');
  OutputOption.ShortName := 'o';
  BuildOptions[2] := OutputOption;
  Result.Add(TSubcommand.Create('build', 'Build a program', '<file>',
    @RecordBuild, BuildOptions));

  SetLength(NoOptions, 0);
  Result.Add(TSubcommand.Create('fail', 'Fail', '', @NonzeroHandler,
    NoOptions));
  SetLength(NoOptions, 0);
  Result.Add(TSubcommand.Create('reject', 'Rejected before dispatch', '',
    @RecordBuild, NoOptions));
end;

function BuildRegistry: TSubcommandRegistry;
var
  NoOpts   : TOptionArray;
  BetaOpts : TOptionArray;
begin
  Result := TSubcommandRegistry.Create;
  SetLength(NoOpts, 0);
  SetLength(BetaOpts, 1);
  BetaOpts[0] := TFlagOption.Create('check', 'verify without writing');
  Result.Add(TSubcommand.Create('alpha', 'first summary', '[--none]',
    @StubHandler, NoOpts));
  Result.Add(TSubcommand.Create('beta', 'second summary', '',
    @StubHandler, BetaOpts));
end;

function RunCompletionScenario: Integer;
var
  Registry : TSubcommandRegistry;
  RunExitCode : Integer;
begin
  CompletionCount := 0;
  CapturedCompletion.ElapsedMilliseconds := High(QWord);
  Registry := BuildRegistry;
  try
    Registry.OnCommandCompleted := @CaptureCompletion;
    RunExitCode := Registry.Run('fixture');
    if RunExitCode <> 0 then Exit(1);
    if CompletionCount <> 1 then Exit(2);
    if CapturedCompletion.CommandName <> 'alpha' then Exit(3);
    if CapturedCompletion.ExitCode <> 0 then Exit(4);
    if CapturedCompletion.ElapsedMilliseconds = High(QWord) then Exit(5);
    Result := 0;
  finally
    Registry.Free;
  end;
end;

function RunRaisingCompletionScenario: Integer;
var
  Registry : TSubcommandRegistry;
  RunExitCode : Integer;
begin
  CompletionCount := 0;
  Registry := BuildRegistry;
  try
    Registry.Find('alpha').Handler := @NonzeroHandler;
    Registry.OnCommandCompleted := @RaiseFromCompletion;
    RunExitCode := Registry.Run('fixture');
    if RunExitCode <> NONZERO_HANDLER_EXIT_CODE then Exit(8);
    if CompletionCount <> 1 then Exit(9);
    if CapturedCompletion.CommandName <> 'alpha' then Exit(10);
    if CapturedCompletion.ExitCode <> NONZERO_HANDLER_EXIT_CODE then Exit(11);
    Result := RunExitCode;
  finally
    Registry.Free;
  end;
end;

{$IFDEF MSWINDOWS}
{ Declared here rather than through the Windows unit, which would shadow
  SysUtils routines. }
function TerminateChildHandle(AProcess: THandle;
  AExitCode: LongWord): LongBool; stdcall;
  external 'kernel32.dll' name 'TerminateProcess';
{$ENDIF}

{ Appends the bytes a child has written to one of its pipes so far, never
  waiting for more: a snapshot of what is available, so a continuous writer
  cannot keep the caller from its deadline. }
procedure DrainChildPipe(const APipe: TInputPipeStream; var AText: string);
var
  Buffer: array[0..4095] of Byte;
  Available, Count: Integer;
begin
  Available := APipe.NumBytesAvailable;
  while Available > 0 do
  begin
    Count := Available;
    if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
    Count := APipe.Read(Buffer[0], Count);
    if Count <= 0 then Break;
    SetLength(AText, Length(AText) + Count);
    Move(Buffer[0], AText[Length(AText) - Count + 1], Count);
    Dec(Available, Count);
  end;
end;

{ Drains both pipes of a poUsePipes child. }
procedure DrainChildOutput(const AProcess: TProcess;
  var AOutput, AErrorOutput: string);
begin
  DrainChildPipe(AProcess.Output, AOutput);
  DrainChildPipe(AProcess.Stderr, AErrorOutput);
end;

{ A bounded replacement for poWaitOnExit and RunCommand, which wait forever
  for a child that never exits. Running is a nonblocking status query that
  also reaps the child on Unix, so ExitCode then decodes its status. A
  poUsePipes child's output is drained into AOutput and AErrorOutput
  meanwhile. A child past the deadline is killed and reported as an error. }
function FinishChildWithin(const AProcess: TProcess;
  const ATimeoutMilliseconds: QWord;
  var AOutput, AErrorOutput: string): Integer;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while AProcess.Running
    and (GetTickCount64 - StartedAt < ATimeoutMilliseconds) do
  begin
    DrainChildOutput(AProcess, AOutput, AErrorOutput);
    Sleep(10);
  end;
  DrainChildOutput(AProcess, AOutput, AErrorOutput);
  if AProcess.Running then
  begin
    {$IFDEF UNIX}
    FpKill(AProcess.ProcessID, SIGKILL);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    TerminateChildHandle(AProcess.ProcessHandle, 1);
    {$ENDIF}
    StartedAt := GetTickCount64;
    while AProcess.Running and (GetTickCount64 - StartedAt < 2000) do
      Sleep(10);
    raise Exception.CreateFmt('child %s did not exit within %d ms',
      [AProcess.Executable, ATimeoutMilliseconds]);
  end;
  Result := AProcess.ExitCode;
  if (Result = 0) and (AProcess.ExitStatus <> 0) then
    Result := AProcess.ExitStatus;
end;

{ The outcome of one child of this binary, with its two output streams
  read apart. }
type
  TChildResult = record
    ExitCode: Integer;
    StandardOutput: string;
    StandardError: string;
  end;

{ Runs this executable with AArguments, bounded. A child mode word, when
  there is one, is the first argument. }
function RunSelf(const AArguments: array of string): TChildResult;
var
  ProcessInstance: TProcess;
  Index: Integer;
begin
  Result.StandardOutput := '';
  Result.StandardError := '';
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := ExpandFileName(ParamStr(0));
    for Index := 0 to High(AArguments) do
      ProcessInstance.Parameters.Add(AArguments[Index]);
    ProcessInstance.Options := [poUsePipes];
    ProcessInstance.Execute;
    Result.ExitCode := FinishChildWithin(ProcessInstance,
      CHILD_TIMEOUT_MILLISECONDS, Result.StandardOutput,
      Result.StandardError);
  finally
    ProcessInstance.Free;
  end;
end;

function Contains(const AText, ANeedle: string): Boolean;
begin
  Result := Pos(ANeedle, AText) > 0;
end;

function StartsWith(const AText, APrefix: string): Boolean;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

procedure TSubcommandRegistrySuite.TestCountAndItemFollowRegistrationOrder;
var
  Registry : TSubcommandRegistry;
begin
  Registry := BuildRegistry;
  try
    Expect<Integer>(Registry.Count).ToBe(2);
    Expect<string>(Registry.Item(0).Name).ToBe('alpha');
    Expect<string>(Registry.Item(0).Summary).ToBe('first summary');
    Expect<string>(Registry.Item(0).UsageArg).ToBe('[--none]');
    Expect<string>(Registry.Item(1).Name).ToBe('beta');
  finally
    Registry.Free;
  end;
end;

procedure TSubcommandRegistrySuite.TestFindReturnsTheRegisteredObject;
var
  Registry : TSubcommandRegistry;
begin
  Registry := BuildRegistry;
  try
    Expect<Boolean>(Registry.Find('beta') = Registry.Item(1)).ToBe(True);
    Expect<Boolean>(Registry.Find('BETA') = Registry.Item(1)).ToBe(True);
    Expect<Boolean>(Registry.Find('missing') = nil).ToBe(True);
  finally
    Registry.Free;
  end;
end;

procedure TSubcommandRegistrySuite.TestItemExposesOptionObjects;
var
  Registry : TSubcommandRegistry;
begin
  Registry := BuildRegistry;
  try
    Expect<Integer>(Length(Registry.Item(0).Options)).ToBe(0);
    Expect<Integer>(Length(Registry.Item(1).Options)).ToBe(1);
    Expect<string>(Registry.Item(1).Options[0].LongName).ToBe('check');
  finally
    Registry.Free;
  end;
end;

procedure TSubcommandRegistrySuite.TestItemOutOfRangeRaises;
var
  Registry : TSubcommandRegistry;
  RaisedBelow, RaisedAbove : Boolean;
begin
  { Production builds disable compiler range checks (Shared.inc), so
    Item carries an explicit bounds guard that must raise instead of
    returning a garbage pointer. }
  Registry := BuildRegistry;
  try
    RaisedBelow := False;
    try
      Registry.Item(-1);
    except
      on EArgumentOutOfRangeException do RaisedBelow := True;
    end;
    RaisedAbove := False;
    try
      Registry.Item(Registry.Count);
    except
      on EArgumentOutOfRangeException do RaisedAbove := True;
    end;
    Expect<Boolean>(RaisedBelow).ToBe(True);
    Expect<Boolean>(RaisedAbove).ToBe(True);
  finally
    Registry.Free;
  end;
end;

procedure TSubcommandRegistrySuite.TestCompletionCallbackReceivesDispatchMetadata;
var
  HelpChild: TChildResult;
  HelpOutput: string;
begin
  Expect<Integer>(RunSelf(['alpha']).ExitCode).ToBe(0);
  { Help for a command without options still completes and links to the
    program-wide command list, using the consumer's program name. }
  HelpChild := RunSelf(['alpha', '--help']);
  Expect<Integer>(HelpChild.ExitCode).ToBe(0);
  HelpOutput := HelpChild.StandardOutput;
  Expect<Boolean>(Pos('fixture alpha', HelpOutput) > 0).ToBe(True);
  Expect<Boolean>(Pos('options:', HelpOutput) = 0).ToBe(True);
  Expect<Boolean>(Pos('run "fixture --help" to see all commands',
    HelpOutput) > 0).ToBe(True);
end;

procedure TSubcommandRegistrySuite.TestCompletionCallbackCannotReplaceDispatchResult;
begin
  Expect<Integer>(RunSelf(['alpha', 'raise-callback']).ExitCode).ToBe(
    NONZERO_HANDLER_EXIT_CODE);
end;

procedure TSubcommandRegistrySuite.
  TestSharedFlagIsInheritedByExistingAndFutureCommands;
var
  EmptyOptions: TOptionArray;
  Registry: TSubcommandRegistry;
begin
  SetLength(EmptyOptions, 0);
  Registry := TSubcommandRegistry.Create;
  try
    Registry.Add(TSubcommand.Create('before', 'before', '', nil,
      EmptyOptions));
    Registry.AddSharedFlag('silent', 'Suppress ordinary output');
    SetLength(EmptyOptions, 0);
    Registry.Add(TSubcommand.Create('after', 'after', '', nil,
      EmptyOptions));

    Expect<Integer>(Length(Registry.Find('before').Options)).ToBe(1);
    Expect<Integer>(Length(Registry.Find('after').Options)).ToBe(1);
    Expect<string>(Registry.Find('before').Options[0].LongName).ToBe(
      'silent');
    Expect<string>(Registry.Find('after').Options[0].LongName).ToBe(
      'silent');
    Expect<string>(Registry.Find('before').UsageArg).ToBe('[--silent]');
    Expect<string>(Registry.Find('after').UsageArg).ToBe('[--silent]');
    Expect<Boolean>(Registry.Find('before').Options[0]
      <> Registry.Find('after').Options[0]).ToBe(True);
  finally
    Registry.Free;
  end;
end;

procedure TSubcommandRegistrySuite.
  TestSharedFlagRejectsCommandOptionCollisions;
var
  DuplicateCommand: TSubcommand;
  DuplicateOptions: TOptionArray;
  Raised: Boolean;
  Registry: TSubcommandRegistry;
begin
  SetLength(DuplicateOptions, 1);
  DuplicateOptions[0] := TFlagOption.Create('silent', 'local flag');
  Registry := TSubcommandRegistry.Create;
  try
    Registry.Add(TSubcommand.Create('before', 'before', '', nil,
      DuplicateOptions));
    Raised := False;
    try
      Registry.AddSharedFlag('silent', 'shared flag');
    except
      on EArgumentException do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Integer>(Length(Registry.Find('before').Options)).ToBe(1);
  finally
    Registry.Free;
  end;

  Registry := TSubcommandRegistry.Create;
  try
    Registry.AddSharedFlag('silent', 'shared flag');
    SetLength(DuplicateOptions, 1);
    DuplicateOptions[0] := TFlagOption.Create('silent', 'local flag');
    DuplicateCommand := TSubcommand.Create('after', 'after', '', nil,
      DuplicateOptions);
    Raised := False;
    try
      Registry.Add(DuplicateCommand);
    except
      on EArgumentException do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    if Raised then
    begin
      DuplicateOptions[0].Free;
      DuplicateCommand.Free;
      { Add rejected both objects before taking ownership. }
    end;
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestUnconfiguredRegistryKeepsItsDefaults;
var
  Registry: TSubcommandRegistry;
begin
  Registry := TSubcommandRegistry.Create;
  try
    Expect<string>(Registry.Description).ToBe('');
    Expect<Integer>(Registry.UsageExitCode).ToBe(DEFAULT_USAGE_EXIT_CODE);
    Expect<Integer>(DEFAULT_USAGE_EXIT_CODE).ToBe(1);
    Expect<Boolean>(Registry.UsageHelpToStandardError).ToBe(False);
    Expect<Boolean>(Registry.BareInvocation = biShowHelp).ToBe(True);
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestPassThroughHandsTheRestOfTheLineToTheHandler;
var
  Registry: TSubcommandRegistry;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', '--unchecked',
      'main.x', '--port', '80', '--', 'help', '--help', '-h', '--json',
      '--mode'])).ToBe(0);
    Expect<Integer>(DispatchCount).ToBe(1);
    Expect<string>(DispatchedCommand).ToBe('run');
    Expect<string>(DispatchedPositionals).ToBe(
      'main.x|--port|80|--|help|--help|-h|--json|--mode');
    Expect<string>(DispatchedOptions).ToBe('unchecked');

    { The bare word is an operand even in first place. }
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', 'help'])).ToBe(
      0);
    Expect<Integer>(DispatchCount).ToBe(2);
    Expect<string>(DispatchedPositionals).ToBe('help');
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.
  TestPassThroughReadsItsOptionsBeforeTheFirstPositional;
var
  Registry: TSubcommandRegistry;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    { A marker before the first positional is consumed, so an operand may
      look like an option. }
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', '--mode', 'fast',
      '--json', '--', '--unchecked', 'main.x'])).ToBe(0);
    Expect<string>(DispatchedPositionals).ToBe('--unchecked|main.x');
    Expect<string>(DispatchedOptions).ToBe('mode|json');
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestSubcommandNameIsAnOperandWithoutAliasing;
var
  Registry: TSubcommandRegistry;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', 'build',
      '--release'])).ToBe(0);
    Expect<string>(DispatchedCommand).ToBe('run');
    Expect<string>(DispatchedPositionals).ToBe('build|--release');
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.
  TestAliasingDispatchesTheNamedSubcommandWhenOptedIn;
var
  Registry: TSubcommandRegistry;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    Registry.Find('run').AliasesSubcommands := True;
    Registry.OnCommandCompleted := @CaptureCompletion;
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', 'BUILD',
      '--release', 'main.x'])).ToBe(0);
    Expect<string>(DispatchedCommand).ToBe('build');
    Expect<string>(DispatchedPositionals).ToBe('main.x');
    Expect<string>(DispatchedOptions).ToBe('release');
    Expect<Integer>(CompletionCount).ToBe(1);
    Expect<string>(CapturedCompletion.CommandName).ToBe('build');

    { A first argument that names no subcommand stays with the command. }
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', 'task',
      'build'])).ToBe(0);
    Expect<string>(DispatchedCommand).ToBe('run');
    Expect<string>(DispatchedPositionals).ToBe('task|build');
    Expect<string>(CapturedCompletion.CommandName).ToBe('run');

    { Only the argument directly after the command is looked up, so the
      marker hands an operand spelled like a subcommand to the command. }
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['run', '--',
      'build'])).ToBe(0);
    Expect<string>(DispatchedCommand).ToBe('run');
    Expect<string>(DispatchedPositionals).ToBe('build');
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.
  TestEndOfOptionsMarkerKeepsHelpSpellingsPositional;
var
  Registry: TSubcommandRegistry;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['build', '--release',
      'main.x', '--', '--level', '-h', 'help', '--help', '--'])).ToBe(0);
    Expect<Integer>(DispatchCount).ToBe(1);
    Expect<string>(DispatchedCommand).ToBe('build');
    Expect<string>(DispatchedPositionals).ToBe(
      'main.x|--level|-h|help|--help|--');
    Expect<string>(DispatchedOptions).ToBe('release');
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestTopLevelFlagRunsItsHandlerInsteadOfACommand;
var
  Registry: TSubcommandRegistry;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    Registry.OnCommandCompleted := @CaptureCompletion;
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['--version'])).ToBe(
      VERSION_FLAG_EXIT_CODE);
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['-V'])).ToBe(
      VERSION_FLAG_EXIT_CODE);
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['version'])).ToBe(
      VERSION_FLAG_EXIT_CODE);
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['Version'])).ToBe(
      VERSION_FLAG_EXIT_CODE);
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['--build-info'])).ToBe(
      BUILD_INFO_FLAG_EXIT_CODE);
    { Only the first argument is read; the rest of the line is ignored. }
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['--version', 'run',
      '--bogus'])).ToBe(VERSION_FLAG_EXIT_CODE);
    Expect<Integer>(TopLevelFlagCalls).ToBe(6);
    Expect<Integer>(DispatchCount).ToBe(0);
    Expect<Integer>(CompletionCount).ToBe(0);
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestTopLevelFlagsIterateInRegistrationOrder;
var
  Registry: TSubcommandRegistry;
  RaisedBelow, RaisedAbove: Boolean;
begin
  Registry := BuildHostRegistry;
  try
    Expect<Integer>(Registry.TopLevelFlagCount).ToBe(3);
    Expect<string>(Registry.TopLevelFlagItem(0).LongName).ToBe('version');
    Expect<string>(Registry.TopLevelFlagItem(0).ShortName).ToBe('V');
    Expect<string>(Registry.TopLevelFlagItem(1).LongName).ToBe('license');
    Expect<string>(Registry.TopLevelFlagItem(2).LongName).ToBe('build-info');
    RaisedBelow := False;
    try
      Registry.TopLevelFlagItem(-1);
    except
      on EArgumentOutOfRangeException do RaisedBelow := True;
    end;
    RaisedAbove := False;
    try
      Registry.TopLevelFlagItem(Registry.TopLevelFlagCount);
    except
      on EArgumentOutOfRangeException do RaisedAbove := True;
    end;
    Expect<Boolean>(RaisedBelow).ToBe(True);
    Expect<Boolean>(RaisedAbove).ToBe(True);
  finally
    Registry.Free;
  end;
end;

{ Whether AddTopLevelFlag raises for AFlag. A refused flag stays with the
  caller, so it is freed here. }
function TopLevelFlagIsRefused(const ARegistry: TSubcommandRegistry;
  const AFlag: TTopLevelFlag): Boolean;
begin
  Result := False;
  try
    ARegistry.AddTopLevelFlag(AFlag);
  except
    on EArgumentException do
    begin
      Result := True;
      AFlag.Free;
    end;
  end;
end;

procedure THostDispatchSuite.TestTopLevelFlagRegistrationRefusals;
var
  Registry: TSubcommandRegistry;
  Flag: TTopLevelFlag;
begin
  ResetDispatch;
  Registry := BuildHostRegistry;
  try
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, TTopLevelFlag.Create('',
      'no name', @HandleBuildInfoFlag))).ToBe(True);
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, TTopLevelFlag.Create(
      '--verbose', 'name given with its dashes',
      @HandleBuildInfoFlag))).ToBe(True);
    Flag := TTopLevelFlag.Create('quiet', 'short name given with its dash',
      @HandleBuildInfoFlag);
    Flag.ShortName := '-q';
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, Flag)).ToBe(True);
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, TTopLevelFlag.Create(
      'credits', 'no handler', nil))).ToBe(True);
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, TTopLevelFlag.Create(
      'Help', 'reserved name', @HandleBuildInfoFlag))).ToBe(True);
    Flag := TTopLevelFlag.Create('host', 'reserved short name',
      @HandleBuildInfoFlag);
    Flag.ShortName := 'H';
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, Flag)).ToBe(True);
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, TTopLevelFlag.Create(
      'VERSION', 'duplicate name', @HandleBuildInfoFlag))).ToBe(True);
    Flag := TTopLevelFlag.Create('verbose', 'duplicate short name',
      @HandleBuildInfoFlag);
    Flag.ShortName := 'V';
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, Flag)).ToBe(True);
    Flag := TTopLevelFlag.Create('Build', 'word of a subcommand',
      @HandleBuildInfoFlag);
    Flag.BareWord := True;
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, Flag)).ToBe(True);

    { Every refusal left the registry as it was. }
    Expect<Integer>(Registry.TopLevelFlagCount).ToBe(3);
    Expect<string>(Registry.TopLevelFlagItem(2).LongName).ToBe('build-info');
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['build'])).ToBe(0);
    Expect<string>(DispatchedCommand).ToBe('build');
    Expect<Integer>(TopLevelFlagCalls).ToBe(0);

    { The same name without the bare word, and a short name that differs
      in letter case only, are accepted. }
    Flag := TTopLevelFlag.Create('build', 'same name as a subcommand',
      @HandleBuildInfoFlag);
    Flag.ShortName := 'v';
    Expect<Boolean>(TopLevelFlagIsRefused(Registry, Flag)).ToBe(False);
    Expect<Integer>(Registry.TopLevelFlagCount).ToBe(4);
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['--build'])).ToBe(
      BUILD_INFO_FLAG_EXIT_CODE);
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['-v'])).ToBe(
      BUILD_INFO_FLAG_EXIT_CODE);
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestSubcommandCannotTakeATopLevelFlagWord;
var
  Command: TSubcommand;
  CommandCount: Integer;
  NoOptions: TOptionArray;
  Raised: Boolean;
  Registry: TSubcommandRegistry;
begin
  Registry := BuildHostRegistry;
  try
    CommandCount := Registry.Count;
    SetLength(NoOptions, 0);
    Command := TSubcommand.Create('Version', 'shadowed by the flag word', '',
      @StubHandler, NoOptions);
    Raised := False;
    try
      Registry.Add(Command);
    except
      on EArgumentException do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    { Add rejected the command before changing it or the registry: it has
      no shared flag, and the caller still owns it. }
    Expect<Integer>(Registry.Count).ToBe(CommandCount);
    Expect<Boolean>(Registry.Find('version') = nil).ToBe(True);
    Expect<Integer>(Length(Command.Options)).ToBe(0);
    Expect<string>(Command.UsageArg).ToBe('');
    if Raised then Command.Free;

    { A flag without the bare word leaves its name to a subcommand. }
    SetLength(NoOptions, 0);
    Registry.Add(TSubcommand.Create('build-info', 'not shadowed', '',
      @StubHandler, NoOptions));
    Expect<Boolean>(Registry.Find('build-info') <> nil).ToBe(True);
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestHandlerExitCodeIsReturnedUnchanged;
var
  Registry: TSubcommandRegistry;
begin
  Registry := BuildHostRegistry;
  try
    Expect<Integer>(Registry.Run(HOST_PROGRAM_NAME, ['fail'])).ToBe(
      NONZERO_HANDLER_EXIT_CODE);
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestSharedFlagUsageLeadsAPassThroughCommand;
var
  Command: TSubcommand;
  NoOptions: TOptionArray;
  Registry: TSubcommandRegistry;
begin
  Registry := TSubcommandRegistry.Create;
  try
    Registry.AddSharedFlag('verify', 'Check the output');
    SetLength(NoOptions, 0);
    Command := TSubcommand.Create('run', 'Run a program',
      '<file> [arguments]', @StubHandler, NoOptions);
    Command.PassThrough := True;
    Registry.Add(Command);
    SetLength(NoOptions, 0);
    Command := TSubcommand.Create('repl', 'Start a session', '',
      @StubHandler, NoOptions);
    Command.PassThrough := True;
    Registry.Add(Command);
    SetLength(NoOptions, 0);
    Registry.Add(TSubcommand.Create('build', 'Build a program', '<file>',
      @StubHandler, NoOptions));
    Registry.AddSharedFlag('json', 'Print diagnostics as JSON');

    { Options count only before a pass-through command's first positional,
      so its shared flags are shown ahead of its operands, in registration
      order. }
    Expect<string>(Registry.Find('run').UsageArg).ToBe(
      '[--verify] [--json] <file> [arguments]');
    Expect<string>(Registry.Find('repl').UsageArg).ToBe(
      '[--verify] [--json]');
    Expect<string>(Registry.Find('build').UsageArg).ToBe(
      '<file> [--verify] [--json]');
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestConfiguredTopLevelHelp;
var
  Child: TChildResult;
begin
  Child := RunSelf([HOST_CHILD_MODE, '--help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<string>(Child.StandardError).ToBe('');
  { The first line is the program name and the host's description. }
  Expect<Boolean>(StartsWith(Child.StandardOutput,
    HOST_PROGRAM_NAME + ' ')).ToBe(True);
  Expect<Boolean>(Pos('demo host', Child.StandardOutput)
    < Pos('usage: host <command> [options]', Child.StandardOutput)).ToBe(
    True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'demo host')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'commands:')).ToBe(True);
  { A flag with help text is listed with its short name; one without is
    accepted but not listed. }
  Expect<Boolean>(Contains(Child.StandardOutput, 'options:')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput,
    '  -V, --version   Print the version')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput,
    '  --license       Print the license')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'build-info')).ToBe(False);
  Expect<Boolean>(Contains(Child.StandardOutput,
    'run "host <command> --help" for command options')).ToBe(True);

  Child := RunSelf([HOST_CHILD_MODE, '--version']);
  Expect<Integer>(Child.ExitCode).ToBe(VERSION_FLAG_EXIT_CODE);
  Expect<Boolean>(StartsWith(Child.StandardOutput, 'host 1.2.3')).ToBe(True);
  Expect<string>(Child.StandardError).ToBe('');
end;

procedure THostDispatchSuite.TestUnconfiguredTopLevelHelpHasNoDescriptionLine;
var
  Child: TChildResult;
begin
  { A bare invocation prints help and succeeds unless the host chooses
    otherwise; without a description the help starts at the usage line. }
  Child := RunSelf([UNCONFIGURED_CHILD_MODE]);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<string>(Child.StandardError).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardOutput,
    'usage: fixture <command> [options]')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'options:')).ToBe(False);
  Expect<Boolean>(Contains(Child.StandardOutput,
    'run "fixture <command> --help" for command options')).ToBe(True);
end;

procedure THostDispatchSuite.TestTopLevelFlagBareWordIsOptIn;
var
  Child: TChildResult;
begin
  { `build-info` is a flag without the bare word, so the word alone is an
    unknown command; so is a flag in the wrong letter case. }
  Child := RunSelf([HOST_CHILD_MODE, 'build-info']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<Boolean>(Contains(Child.StandardError,
    'unknown command: build-info')).ToBe(True);
  Child := RunSelf([HOST_CHILD_MODE, '--VERSION']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<Boolean>(Contains(Child.StandardError, 'unknown command:')).ToBe(
    True);
end;

procedure THostDispatchSuite.TestConfiguredUsageErrors;
var
  Child: TChildResult;
begin
  Child := RunSelf([HOST_CHILD_MODE, 'nosuch']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<string>(Child.StandardOutput).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardError,
    'unknown command: nosuch')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardError,
    'usage: host <command> [options]')).ToBe(True);

  Child := RunSelf([HOST_CHILD_MODE]);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<string>(Child.StandardOutput).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardError, 'missing command')).ToBe(
    True);
  Expect<Boolean>(Contains(Child.StandardError,
    'usage: host <command> [options]')).ToBe(True);

  Child := RunSelf([HOST_CHILD_MODE, 'build', '--bogus']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<string>(Child.StandardOutput).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardError,
    'host build: Unknown option: --bogus')).ToBe(True);

  Child := RunSelf([HOST_CHILD_MODE, 'build', '--level=high']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<Boolean>(StartsWith(Child.StandardError,
    'host build: Invalid integer value for --level: high')).ToBe(True);

  Child := RunSelf([HOST_CHILD_MODE, 'run', '--bogus', 'main.x']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<string>(Child.StandardOutput).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardError,
    'host run: Unknown option: --bogus')).ToBe(True);

  Child := RunSelf([HOST_CHILD_MODE, 'reject']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<string>(Child.StandardOutput).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardError,
    'host reject: not allowed')).ToBe(True);
end;

procedure THostDispatchSuite.TestUnconfiguredUsageErrors;
var
  Child: TChildResult;
begin
  { Without host configuration a usage error exits like a failing handler
    and the help after an unknown command goes to standard output. }
  Child := RunSelf([UNCONFIGURED_CHILD_MODE, 'nosuch']);
  Expect<Integer>(Child.ExitCode).ToBe(DEFAULT_USAGE_EXIT_CODE);
  Expect<Boolean>(StartsWith(Child.StandardError,
    'unknown command: nosuch')).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardError, 'usage:')).ToBe(False);
  Expect<Boolean>(StartsWith(Child.StandardOutput,
    'usage: fixture <command> [options]')).ToBe(True);

  Child := RunSelf([UNCONFIGURED_CHILD_MODE, 'beta', '--bogus']);
  Expect<Integer>(Child.ExitCode).ToBe(DEFAULT_USAGE_EXIT_CODE);
  Expect<string>(Child.StandardOutput).ToBe('');
  Expect<Boolean>(StartsWith(Child.StandardError,
    'fixture beta: Unknown option: --bogus')).ToBe(True);

  { No top-level flag exists unless the host registers one. }
  Child := RunSelf([UNCONFIGURED_CHILD_MODE, '--version']);
  Expect<Integer>(Child.ExitCode).ToBe(DEFAULT_USAGE_EXIT_CODE);
  Expect<Boolean>(StartsWith(Child.StandardError,
    'unknown command: --version')).ToBe(True);
end;

procedure THostDispatchSuite.TestPassThroughHelp;
const
  RUN_USAGE = 'usage: host run [--json] <file> [arguments]';
var
  Child: TChildResult;
begin
  Child := RunSelf([HOST_CHILD_MODE, 'run', '--help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, RUN_USAGE)).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command:')).ToBe(False);

  Child := RunSelf([HOST_CHILD_MODE, 'run', '--mode', 'fast', '-h']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, RUN_USAGE)).ToBe(True);

  { Help wins over an argument the parser would reject, as it does for
    every other command. }
  Child := RunSelf([HOST_CHILD_MODE, 'run', '--bogus', '--help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, RUN_USAGE)).ToBe(True);
end;

procedure THostDispatchSuite.TestCommandHelpListsOptionShortNames;
var
  Child: TChildResult;
begin
  { `--output` has the short name `o`. It is listed the way top-level
    help lists a flag's short name; the other rows keep their long form,
    and every help text starts in the column after the widest label. }
  Child := RunSelf([HOST_CHILD_MODE, 'build', '--help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<string>(Child.StandardError).ToBe('');
  Expect<Boolean>(Contains(Child.StandardOutput,
    'options:' + sLineBreak +
    '  --release              Optimize' + sLineBreak +
    '  --level=<N>            Optimization level' + sLineBreak +
    '  -o, --output=<value>   Output path' + sLineBreak +
    '  --json                 Print diagnostics as JSON' + sLineBreak)).ToBe(
    True);
end;

procedure THostDispatchSuite.TestHelpWordOutsidePassThrough;
const
  BUILD_USAGE = 'usage: host build <file> [--json]';
var
  Child: TChildResult;
begin
  Child := RunSelf([HOST_CHILD_MODE, 'build', 'main.x', 'help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, BUILD_USAGE)).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command:')).ToBe(False);

  Child := RunSelf([HOST_CHILD_MODE, 'build', '--bogus', '-h']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, BUILD_USAGE)).ToBe(True);

  { Without a help spelling the command is dispatched instead. }
  Child := RunSelf([HOST_CHILD_MODE, 'build', 'main.x']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command: build')).ToBe(
    True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'usage:')).ToBe(False);

  { A `--` that a valued short option takes as its value is not the
    marker, so a help spelling after it still asks for help. }
  Child := RunSelf([HOST_CHILD_MODE, 'build', '-o', '--', '--help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, BUILD_USAGE)).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command:')).ToBe(False);

  { A help spelling of its own after an option's value still asks for
    help, and so does `-h` after a long option, which takes no separated
    value that begins with `-`. }
  Child := RunSelf([HOST_CHILD_MODE, 'build', '-o', 'help', '--help']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, BUILD_USAGE)).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command:')).ToBe(False);
  Child := RunSelf([HOST_CHILD_MODE, 'build', '--output', '-h', 'main.x']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, BUILD_USAGE)).ToBe(True);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command:')).ToBe(False);
end;

{ Dispatches `build` with AArguments on a fresh host registry and returns
  the value its `--output` option received and the positionals. A line
  that dispatched nothing returns `<exit N>`, the exit code of Run. }
function BuildOutputFor(const AArguments: array of string;
  const AStrictSingleDash: Boolean = False): string;
var
  Registry: TSubcommandRegistry;
  Build: TSubcommand;
  Output: TStringOption;
  Arguments: array of string;
  Index, RunExitCode: Integer;
begin
  ResetDispatch;
  SetLength(Arguments, Length(AArguments) + 1);
  Arguments[0] := 'build';
  for Index := 0 to High(AArguments) do
    Arguments[Index + 1] := AArguments[Index];
  Registry := BuildHostRegistry;
  try
    Registry.StrictSingleDash := AStrictSingleDash;
    RunExitCode := Registry.Run(HOST_PROGRAM_NAME, Arguments);
    if DispatchCount <> 1 then
      Exit(Format('<exit %d>', [RunExitCode]));
    Build := Registry.Find('build');
    Output := nil;
    for Index := 0 to High(Build.Options) do
      if Build.Options[Index].LongName = 'output' then
        Output := Build.Options[Index] as TStringOption;
    Result := Output.Value + ' ' + DispatchedPositionals;
  finally
    Registry.Free;
  end;
end;

procedure THostDispatchSuite.TestOptionValueIsNeverAHelpRequest;
begin
  Expect<string>(BuildOutputFor(['-o', 'help', 'main.x'])).ToBe(
    'help main.x');
  Expect<string>(BuildOutputFor(['--output', 'help', 'main.x'])).ToBe(
    'help main.x');
  Expect<string>(BuildOutputFor(['main.x', '-o', 'HELP'])).ToBe(
    'HELP main.x');
  Expect<string>(BuildOutputFor(['-o', '-h', 'main.x'])).ToBe('-h main.x');
  Expect<string>(BuildOutputFor(['-o', '--help', 'main.x'])).ToBe(
    '--help main.x');
end;

procedure THostDispatchSuite.TestStrictSingleDashIsOptIn;
var
  Registry: TSubcommandRegistry;
begin
  Registry := TSubcommandRegistry.Create;
  try
    Expect<Boolean>(Registry.StrictSingleDash).ToBe(False);
  finally
    Registry.Free;
  end;
  Expect<string>(BuildOutputFor(['-verify', 'main.x'])).ToBe(
    ' -verify|main.x');
  { Strict parsing still takes numbers, values and a lone `-`. }
  Expect<string>(BuildOutputFor(['-o', '-verify', '-5', '-', 'main.x'],
    True)).ToBe('-verify -5|-|main.x');
  Expect<string>(BuildOutputFor(['-verify', 'main.x'], True)).ToBe(
    '<exit ' + IntToStr(HOST_USAGE_EXIT_CODE) + '>');
end;

procedure THostDispatchSuite.TestStrictSingleDashUsageErrors;
var
  Child: TChildResult;
begin
  Child := RunSelf([STRICT_HOST_CHILD_MODE, 'build', '-verify', 'main.x']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<Boolean>(Contains(Child.StandardError,
    'host build: Unknown option: -verify')).ToBe(True);
  Expect<string>(Child.StandardOutput).ToBe('');

  { A pass-through command hands everything from its first positional on
    to the program it launches. }
  Child := RunSelf([STRICT_HOST_CHILD_MODE, 'run', 'main.x', '-verify']);
  Expect<Integer>(Child.ExitCode).ToBe(0);
  Expect<Boolean>(Contains(Child.StandardOutput, 'command: run')).ToBe(True);
  Child := RunSelf([STRICT_HOST_CHILD_MODE, 'run', '-verify', 'main.x']);
  Expect<Integer>(Child.ExitCode).ToBe(HOST_USAGE_EXIT_CODE);
  Expect<Boolean>(Contains(Child.StandardError,
    'host run: Unknown option: -verify')).ToBe(True);
end;

procedure THostDispatchSuite.SetupTests;
begin
  Test('an unconfigured registry keeps the defaults every host started with',
    TestUnconfiguredRegistryKeepsItsDefaults);
  Test('a pass-through command hands the rest of the line to its handler',
    TestPassThroughHandsTheRestOfTheLineToTheHandler);
  Test('a pass-through command reads its options before the first positional',
    TestPassThroughReadsItsOptionsBeforeTheFirstPositional);
  Test('a subcommand name after a command is an operand without aliasing',
    TestSubcommandNameIsAnOperandWithoutAliasing);
  Test('an aliasing command dispatches the subcommand its first argument names',
    TestAliasingDispatchesTheNamedSubcommandWhenOptedIn);
  Test('help spellings after the end-of-options marker stay positional',
    TestEndOfOptionsMarkerKeepsHelpSpellingsPositional);
  Test('a top-level flag runs its handler instead of a command',
    TestTopLevelFlagRunsItsHandlerInsteadOfACommand);
  Test('top-level flags iterate in registration order',
    TestTopLevelFlagsIterateInRegistrationOrder);
  Test('top-level flag registration refuses unusable and clashing flags',
    TestTopLevelFlagRegistrationRefusals);
  Test('a subcommand cannot take the name of a top-level flag word',
    TestSubcommandCannotTakeATopLevelFlagWord);
  Test('a failing handler''s exit code is returned unchanged',
    TestHandlerExitCodeIsReturnedUnchanged);
  Test('shared flags lead the usage of a pass-through command',
    TestSharedFlagUsageLeadsAPassThroughCommand);
  Test('top-level help prints the description and the listed flags',
    TestConfiguredTopLevelHelp);
  Test('top-level help without a description starts at the usage line',
    TestUnconfiguredTopLevelHelpHasNoDescriptionLine);
  Test('a top-level flag matches as a bare word only when opted in',
    TestTopLevelFlagBareWordIsOptIn);
  Test('usage errors return the host''s exit code on standard error',
    TestConfiguredUsageErrors);
  Test('usage errors keep the unconfigured exit code and streams',
    TestUnconfiguredUsageErrors);
  Test('a pass-through command reads --help and -h before its first positional',
    TestPassThroughHelp);
  Test('outside pass-through a help spelling asks for help, even after a -- value',
    TestHelpWordOutsidePassThrough);
  Test('a value that an option takes is never a help request',
    TestOptionValueIsNeverAHelpRequest);
  Test('strict single-dash parsing is opt-in and keeps numbers and values',
    TestStrictSingleDashIsOptIn);
  Test('strict single-dash parsing reports unknown dash words as usage errors',
    TestStrictSingleDashUsageErrors);
  Test('command help lists an option''s short name and keeps one help column',
    TestCommandHelpListsOptionShortNames);
end;

procedure TSubcommandRegistrySuite.SetupTests;
begin
  Test('Count + Item iterate subcommands in registration order',
    TestCountAndItemFollowRegistrationOrder);
  Test('Find resolves case-insensitively to the same object Item returns',
    TestFindReturnsTheRegisteredObject);
  Test('Item exposes each subcommand''s option objects',
    TestItemExposesOptionObjects);
  Test('Item raises EArgumentOutOfRangeException outside 0..Count-1',
    TestItemOutOfRangeRaises);
  Test('completion callback receives resolved command metadata exactly once',
    TestCompletionCallbackReceivesDispatchMetadata);
  Test('completion callback cannot replace the command dispatch result',
    TestCompletionCallbackCannotReplaceDispatchResult);
  Test('shared flags reach existing and future subcommands independently',
    TestSharedFlagIsInheritedByExistingAndFutureCommands);
  Test('shared flags reject existing and future option name collisions',
    TestSharedFlagRejectsCommandOptionCollisions);
end;

{ The host children: dispatch the arguments after the mode word and exit
  with the registry's result. }
function RunHostChildMode(const AMode: string): Integer;
var
  Registry : TSubcommandRegistry;
begin
  EchoDispatch := True;
  if (AMode = HOST_CHILD_MODE) or (AMode = STRICT_HOST_CHILD_MODE) then
    Registry := BuildHostRegistry
  else
    Registry := BuildRegistry;
  try
    Registry.StrictSingleDash := AMode = STRICT_HOST_CHILD_MODE;
    if (AMode = HOST_CHILD_MODE) or (AMode = STRICT_HOST_CHILD_MODE) then
      Result := Registry.Run(HOST_PROGRAM_NAME, GetCommandLineArguments(2))
    else
      Result := Registry.Run(UNCONFIGURED_PROGRAM_NAME,
        GetCommandLineArguments(2));
  finally
    Registry.Free;
  end;
end;

begin
  if (ParamCount >= 1) and ((ParamStr(1) = HOST_CHILD_MODE)
    or (ParamStr(1) = STRICT_HOST_CHILD_MODE)
    or (ParamStr(1) = UNCONFIGURED_CHILD_MODE)) then
  begin
    ExitCode := RunHostChildMode(ParamStr(1));
    Exit;
  end;

  if (ParamCount >= 1) and SameText(ParamStr(1), 'alpha') then
  begin
    if (ParamCount = 2) and SameText(ParamStr(2), 'raise-callback') then
      ExitCode := RunRaisingCompletionScenario
    else
      ExitCode := RunCompletionScenario;
    Exit;
  end;

  TestRunnerProgram.AddSuite(TSubcommandRegistrySuite.Create(
    'CLI.Subcommands: registry iteration'));
  TestRunnerProgram.AddSuite(THostDispatchSuite.Create(
    'CLI.Subcommands: host dispatch'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
