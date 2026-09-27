{ Exercise the real build scheduler against a later blocking worker request. }
program BuildFairness.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.ProcessTree,
  LWPT.WorkerBudget,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  ChildArgument = '--build-fairness-child';
  ContenderSession = 'build-fairness-contender';
  BarrierMilliseconds = 30000;
  ChildMilliseconds = 90000;
  PollMilliseconds = 10;

type
  TChild = class
  private
    FProcess: TProcess;
    FTree: TLWPTProcessTree;
    FOutput: string;
  public
    constructor Create(const AExecutable, ADirectory, AState: string;
      const AArguments: array of string);
    destructor Destroy; override;
    procedure Drain;
    function Running: Boolean;
    function Status: Integer;
    property Output: string read FOutput;
  end;

  TBuildFairness = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestOlderBuildPrecedesBlockingContender;
  end;

constructor TChild.Create(const AExecutable, ADirectory, AState: string;
  const AArguments: array of string);
var
  Argument: string;
begin
  inherited Create;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := AExecutable;
  FProcess.CurrentDirectory := ADirectory;
  FProcess.Options := [poUsePipes, poStderrToOutPut];
  for Argument in AArguments do FProcess.Parameters.Add(Argument);
  ConfigureProcessEnvironment(FProcess, [WORKER_STATE_DIR_ENV + '=' + AState,
    WORKER_BUDGET_ENV + '=1', WORKER_LEASE_TOKEN_ENV + '=',
    WORKER_STALE_SECONDS_ENV + '=300']);
  FTree := TLWPTProcessTree.Create(FProcess);
  FTree.Execute;
end;

destructor TChild.Destroy;
begin
  if Assigned(FTree) and Assigned(FProcess) and FProcess.Running then
    FTree.Terminate;
  Drain;
  FTree.Free;
  FProcess.Free;
  inherited Destroy;
end;

procedure TChild.Drain;
var
  Buffer: array[0..4095] of Byte;
  Available, Count: LongInt;
  Chunk: RawByteString;
begin
  if not Assigned(FProcess) or not Assigned(FProcess.Output) then Exit;
  { Drain a bounded available-byte snapshot, never wait for pipe EOF. }
  Available := FProcess.Output.NumBytesAvailable;
  while Available > 0 do
  begin
    Count := Available;
    if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
    Count := FProcess.Output.Read(Buffer, Count);
    if Count <= 0 then Break;
    SetString(Chunk, PAnsiChar(@Buffer[0]), Count);
    FOutput := FOutput + string(Chunk);
    Dec(Available, Count);
  end;
end;

function TChild.Running: Boolean;
begin
  Drain;
  Result := FProcess.Running;
end;

function TChild.Status: Integer;
begin
  Drain;
  Result := FProcess.ExitStatus;
end;

procedure Mark(const ARoot, AName: string);
begin
  { These are existence-only barriers: no process reads an open payload. }
  WriteTextFile(ARoot + '/' + AName, '');
end;

function Marked(const ARoot, AName: string): Boolean;
begin
  Result := FileExists(ARoot + '/' + AName);
end;

function WaitForRelease(const ARoot, AName: string): Integer;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    if Marked(ARoot, AName) then Exit(0);
    Sleep(PollMilliseconds);
  until GetTickCount64 - StartedAt >= ChildMilliseconds;
  WriteLn(StdErr, 'Timed out waiting for ', AName);
  Result := 1;
end;

function RunHolder(const ARoot: string): Integer;
var
  Session: TLWPTWorkerBudgetSession;
  Lease: TLWPTWorkerLease;
  Snapshot: TLWPTWorkerBudgetSnapshot;
  Entry: TLWPTWorkerBudgetEntry;
  StartedAt: QWord;
begin
  Result := 1;
  Session := TLWPTWorkerBudgetSession.Create(NewWorkerSessionId, 1);
  try
    Lease := Session.Acquire(BarrierMilliseconds);
    if not Assigned(Lease) then Exit;
    try
      Mark(ARoot, 'holder-ready');
      StartedAt := GetTickCount64;
      repeat
        if Marked(ARoot, 'holder-release') then Exit(0);
        Snapshot := GetWorkerBudgetSnapshot;
        for Entry in Snapshot.Entries do
          if Entry.SessionId <> Session.SessionId then
          begin
            if Entry.SessionId = ContenderSession then
            begin
              if Entry.Waiting and (Entry.WaitTicket > 0) then
                Mark(ARoot, 'contender-queued');
            end
            else if (Entry.Granted = 0) and not Entry.Uncertain
              and (Entry.HeartbeatAt - Entry.StartedAt >= 100) then
            begin
              { Before the contender starts, the real build is the only other
                session. Its background heartbeat interval is 100 seconds,
                beyond this child's entire lifetime. An advanced heartbeat
                therefore proves that the build has tried to acquire capacity;
                merely observing process startup would not establish order. }
              Mark(ARoot, 'build-attempted');
            end;
          end;
        Sleep(PollMilliseconds);
      until GetTickCount64 - StartedAt >= ChildMilliseconds;
      WriteLn(StdErr, 'Holder barrier timed out');
    finally
      Lease.Free;
    end;
  finally
    Session.Free;
  end;
end;

function RunContender(const ARoot: string): Integer;
var
  Session: TLWPTWorkerBudgetSession;
  Lease: TLWPTWorkerLease;
begin
  Result := 1;
  Session := TLWPTWorkerBudgetSession.Create(ContenderSession, 1);
  try
    Lease := Session.Acquire(ChildMilliseconds);
    if not Assigned(Lease) then Exit;
    try
      Mark(ARoot, 'contender-acquired');
      Result := WaitForRelease(ARoot, 'contender-release');
    finally
      Lease.Free;
    end;
  finally
    Session.Free;
  end;
end;

function TomlString(const AValue: string): string;
begin
  Result := '"' + StringReplace(StringReplace(AValue, '\', '\\',
    [rfReplaceAll]), '"', '\"', [rfReplaceAll]) + '"';
end;

procedure WaitForMarker(const ARoot, AName: string; AChild: TChild);
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while not Marked(ARoot, AName) do
  begin
    if not AChild.Running then
      raise Exception.Create('Child exited before ' + AName + ': '
        + AChild.Output);
    if GetTickCount64 - StartedAt >= BarrierMilliseconds then
      raise Exception.Create('Timed out waiting for ' + AName + ': '
        + AChild.Output);
    Sleep(PollMilliseconds);
  end;
end;

procedure TBuildFairness.TestOlderBuildPrecedesBlockingContender;
var
  Scratch, Control, Project, WorkerState, SelfExecutable: string;
  Holder, Build, Contender: TChild;
  StartedAt: QWord;
  BuildFirst, ContenderFirst, AllExited: Boolean;
  HolderStatus, BuildStatus, ContenderStatus: Integer;
begin
  Scratch := CreateScratchRoot('build-fairness');
  Control := Scratch + '/control';
  Project := Scratch + '/project';
  WorkerState := Scratch + '/worker-state';
  SelfExecutable := ExpandFileName(ParamStr(0));
  Holder := nil;
  Build := nil;
  Contender := nil;
  BuildFirst := False;
  ContenderFirst := False;
  HolderStatus := -1;
  BuildStatus := -1;
  ContenderStatus := -1;
  WriteTextFile(Project + '/source/app.pas',
    'program app; begin end.' + LineEnding);
  WriteTextFile(Project + '/' + PROGRAM_NAME + '.toml',
    '[package]' + LineEnding
    + 'name = "build-fairness"' + LineEnding
    + 'version = "0.0.0"' + LineEnding
    + 'units = ["source"]' + LineEnding
    + '[build.app]' + LineEnding
    + 'source = "source/app.pas"' + LineEnding
    + 'output = "build/app"' + LineEnding
    + '[build.app.prebuild]' + LineEnding
    + 'entered = { command = ' + TomlString(SelfExecutable)
    + ', args = [' + TomlString(ChildArgument) + ', "entry", '
    + TomlString(Control) + '] }' + LineEnding);
  try
    Holder := TChild.Create(SelfExecutable, Project, WorkerState,
      [ChildArgument, 'holder', Control]);
    WaitForMarker(Control, 'holder-ready', Holder);
    Build := TChild.Create(LwptBinaryPath, Project, WorkerState,
      ['build', '--no-cache', '--jobs', '1', 'app']);
    WaitForMarker(Control, 'build-attempted', Holder);
    Contender := TChild.Create(SelfExecutable, Project, WorkerState,
      [ChildArgument, 'contender', Control]);
    WaitForMarker(Control, 'contender-queued', Holder);
    Mark(Control, 'holder-release');
    StartedAt := GetTickCount64;
    repeat
      BuildFirst := Marked(Control, 'build-started');
      ContenderFirst := Marked(Control, 'contender-acquired');
      if BuildFirst or ContenderFirst then Break;
      if not Build.Running or not Contender.Running then Break;
      Sleep(PollMilliseconds);
    until GetTickCount64 - StartedAt >= BarrierMilliseconds;
    { Both winners hold the only lease at a barrier. The losing request cannot
      start during this observation, independent of process scheduling speed. }
  finally
    Mark(Control, 'holder-release');
    Mark(Control, 'contender-release');
    Mark(Control, 'build-release');
    StartedAt := GetTickCount64;
    repeat
      AllExited := True;
      if Assigned(Holder) and Holder.Running then AllExited := False;
      if Assigned(Build) and Build.Running then AllExited := False;
      if Assigned(Contender) and Contender.Running then AllExited := False;
      if AllExited then Break;
      Sleep(PollMilliseconds);
    until GetTickCount64 - StartedAt >= BarrierMilliseconds;
    if Assigned(Holder) and not Holder.Running then
      HolderStatus := Holder.Status;
    if Assigned(Build) and not Build.Running then
      BuildStatus := Build.Status;
    if Assigned(Contender) and not Contender.Running then
      ContenderStatus := Contender.Status;
    WriteLn('Build fairness evidence: ', Scratch);
    WriteLn('Observed first: build=', BuildFirst,
      '; later blocking contender=', ContenderFirst);
    if Assigned(Build) then
      WriteLn('Real build output (status ', BuildStatus, '):', LineEnding,
        Build.Output);
    if Assigned(Holder) then
      WriteLn('Holder output (status ', HolderStatus, '): ', Holder.Output);
    if Assigned(Contender) then
      WriteLn('Contender output (status ', ContenderStatus, '): ',
        Contender.Output);
    { Process-tree ownership bounds exceptional cleanup and includes hooks and
      compiler descendants. Keep the isolated scratch evidence for failures. }
    Contender.Free;
    Build.Free;
    Holder.Free;
  end;
  Expect<Boolean>(AllExited).ToBe(True);
  Expect<Integer>(HolderStatus).ToBe(0);
  Expect<Integer>(BuildStatus).ToBe(0);
  Expect<Integer>(ContenderStatus).ToBe(0);
  if not BuildFirst and not ContenderFirst then
    Fail('Neither request was admitted after the holder released its lease');
  if not BuildFirst or ContenderFirst then
    Fail('Older real build lost its FIFO position to a later blocking contender');
  RecursiveDelete(Scratch);
end;

procedure TBuildFairness.SetupTests;
begin
  Test('older queued build precedes a later blocking contender',
    TestOlderBuildPrecedesBlockingContender);
end;

begin
  if (ParamCount = 3) and (ParamStr(1) = ChildArgument) then
  begin
    if ParamStr(2) = 'holder' then Halt(RunHolder(ParamStr(3)));
    if ParamStr(2) = 'contender' then Halt(RunContender(ParamStr(3)));
    if ParamStr(2) = 'entry' then
    begin
      Mark(ParamStr(3), 'build-started');
      Halt(WaitForRelease(ParamStr(3), 'build-release'));
    end;
    Halt(2);
  end;
  TestRunnerProgram.AddSuite(TBuildFairness.Create('build FIFO fairness'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
