{ CLI.Subcommands.Test — registry surface coverage.

  The registry is the single source of truth for a program's command
  surface; Count / Item read iteration is what surface-rendering
  consumers (help printers, the host program's agent-facing reference
  generator) build on. This suite pins the iteration contract —
  registration order, exact objects — in-process. Dispatch behaviour
  (argv parsing, help interception, run-aliasing) lives behind
  ParamStr and is covered by the host program's subprocess tests. }

program CLI.Subcommands.Test;

{$I Shared.inc}

uses
  Classes,
  Process,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  TestingPascalLibrary;

type
  TSubcommandRegistrySuite = class(TTestSuite)
  private
    function RunCompletionChild: Integer;
  public
    procedure SetupTests; override;
    procedure TestCountAndItemFollowRegistrationOrder;
    procedure TestFindReturnsTheRegisteredObject;
    procedure TestItemExposesOptionObjects;
    procedure TestItemOutOfRangeRaises;
    procedure TestCompletionCallbackReceivesDispatchMetadata;
  end;

var
  CompletionCount : Integer = 0;
  CapturedCompletion : TSubcommandCompletion;

procedure CaptureCompletion(const ACompletion: TSubcommandCompletion);
begin
  Inc(CompletionCount);
  CapturedCompletion := ACompletion;
end;

function StubHandler(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  Result := 0;
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
  Registry := BuildRegistry;
  try
    Registry.OnCommandCompleted := @CaptureCompletion;
    RunExitCode := Registry.Run('fixture');
    if RunExitCode <> 0 then Exit(1);
    if CompletionCount <> 1 then Exit(2);
    if CapturedCompletion.CommandName <> 'alpha' then Exit(3);
    if CapturedCompletion.ExitCode <> 0 then Exit(4);
    Result := 0;
  finally
    Registry.Free;
  end;
end;

function TSubcommandRegistrySuite.RunCompletionChild: Integer;
var
  ProcessInstance : TProcess;
begin
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := ExpandFileName(ParamStr(0));
    ProcessInstance.Parameters.Add('alpha');
    ProcessInstance.Options := [poWaitOnExit];
    ProcessInstance.Execute;
    Result := ProcessInstance.ExitCode;
    if (Result = 0) and (ProcessInstance.ExitStatus <> 0) then
      Result := ProcessInstance.ExitStatus;
  finally
    ProcessInstance.Free;
  end;
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
begin
  Expect<Integer>(RunCompletionChild).ToBe(0);
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
end;

begin
  if (ParamCount = 1) and SameText(ParamStr(1), 'alpha') then
  begin
    ExitCode := RunCompletionScenario;
    Exit;
  end;

  TestRunnerProgram.AddSuite(TSubcommandRegistrySuite.Create(
    'CLI.Subcommands: registry iteration'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
