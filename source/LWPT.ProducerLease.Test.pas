{ LWPT.ProducerLease.Test — local cross-process producer coordination. }
program LWPT.ProducerLease.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.ProducerLease,
  TestingPascalLibrary,
  Tests.Scratch;

const
  CHILD_SWITCH = '--producer-lease-child';
  TEST_KEY = 'build:sha256:0123456789abcdef';
  SECOND_KEY = 'dependency:sha256:fedcba9876543210';
  WAIT_TIMEOUT_MILLISECONDS = 5000;

type
  TProducerLeaseContract = class(TTestSuite)
  private
    FScratch: string;
    FLeaseRoot: string;
    function StartChild(const AMode, AKey, AAcquired,
      ARelease: string): TProcess;
    function WaitForFile(const APath: string): Boolean;
    function StatePath(const AKey: string): string;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestOneLocalProducerOwnsAKey;
    procedure TestDifferentKeysProceedIndependently;
    procedure TestWaiterAbandonmentPreservesProducer;
    procedure TestReleasedProducerHandsOffToWaiter;
    procedure TestCrashedProducerIsReclaimable;
    procedure TestStaleHeartbeatDoesNotDisplaceLiveOwner;
  end;

function WaitForMarker(const APath: string): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  repeat
    if FileExists(APath) then Exit(True);
    Sleep(10);
  until GetTickCount64 - StartedAt >= WAIT_TIMEOUT_MILLISECONDS;
  Result := False;
end;

function RunChildMode: Boolean;
var
  AcquiredPath, Key, LeaseRoot, Mode, ReleasePath: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
begin
  Result := False;
  if (ParamCount <> 6) or (ParamStr(1) <> CHILD_SWITCH) then Exit;
  LeaseRoot := ParamStr(2);
  Mode := ParamStr(3);
  Key := ParamStr(4);
  AcquiredPath := ParamStr(5);
  ReleasePath := ParamStr(6);
  Coordinator := TLWPTProducerLeaseCoordinator.Create(LeaseRoot);
  Lease := nil;
  try
    if Mode = 'wait' then
      repeat
        Lease := Coordinator.TryAcquire(Key, 'child waiter');
        if not Assigned(Lease) then Sleep(PRODUCER_LEASE_POLL_MILLISECONDS);
      until Assigned(Lease)
    else
      Lease := Coordinator.TryAcquire(Key, 'child producer');
    if Mode = 'abandon' then
    begin
      if Assigned(Lease) then Halt(72);
      WriteTextFile(AcquiredPath, 'abandoned');
      Exit(True);
    end;
    if not Assigned(Lease) then Halt(73);
    WriteTextFile(AcquiredPath, 'acquired');
    if Mode = 'crash' then Halt(77);
    if not WaitForMarker(ReleasePath) then Halt(74);
  finally
    Lease.Free;
    Coordinator.Free;
  end;
  Result := True;
end;

function TProducerLeaseContract.WaitForFile(const APath: string): Boolean;
begin
  Result := WaitForMarker(APath);
end;

function TProducerLeaseContract.StatePath(const AKey: string): string;
var
  Digest: string;
begin
  Digest := SHA256Hex(BytesOf(AKey));
  Result := FLeaseRoot + '/sha256/' + Copy(Digest, 1, 2) + '/'
    + Copy(Digest, 3, MaxInt) + '/state';
end;

function TProducerLeaseContract.StartChild(const AMode, AKey,
  AAcquired, ARelease: string): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ParamStr(0);
  Result.Parameters.Add(CHILD_SWITCH);
  Result.Parameters.Add(FLeaseRoot);
  Result.Parameters.Add(AMode);
  Result.Parameters.Add(AKey);
  Result.Parameters.Add(AAcquired);
  Result.Parameters.Add(ARelease);
  Result.Options := [poNoConsole];
  Result.Execute;
end;

procedure TProducerLeaseContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('producer-lease');
end;

procedure TProducerLeaseContract.BeforeEach;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
  FLeaseRoot := FScratch + '/leases';
end;

procedure TProducerLeaseContract.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TProducerLeaseContract.TestOneLocalProducerOwnsAKey;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  First, Second: TLWPTProducerLease;
  Snapshot: TLWPTProducerLeaseSnapshot;
begin
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FLeaseRoot);
  First := nil;
  try
    First := Coordinator.TryAcquire(TEST_KEY, 'first producer');
    Expect<Boolean>(Assigned(First)).ToBe(True);
    Second := Coordinator.TryAcquire(TEST_KEY, 'second producer');
    try
      Expect<Boolean>(Assigned(Second)).ToBe(False);
    finally
      Second.Free;
    end;
    Expect<Boolean>(Coordinator.Snapshot(TEST_KEY, Snapshot)).ToBe(True);
    Expect<string>(Snapshot.Description).ToBe('first producer');
    Expect<Integer>(Snapshot.ProcessId).ToBe(GetProcessID);
  finally
    First.Free;
    Coordinator.Free;
  end;
end;

procedure TProducerLeaseContract.TestDifferentKeysProceedIndependently;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  First, Second: TLWPTProducerLease;
begin
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FLeaseRoot);
  First := nil;
  Second := nil;
  try
    First := Coordinator.TryAcquire(TEST_KEY, 'first key');
    Second := Coordinator.TryAcquire(SECOND_KEY, 'second key');
    Expect<Boolean>(Assigned(First)).ToBe(True);
    Expect<Boolean>(Assigned(Second)).ToBe(True);
  finally
    Second.Free;
    First.Free;
    Coordinator.Free;
  end;
end;

procedure TProducerLeaseContract.TestWaiterAbandonmentPreservesProducer;
var
  Abandoned, ReleasePath: string;
  Child: TProcess;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Owner, Contender: TLWPTProducerLease;
begin
  Abandoned := FScratch + '/abandoned';
  ReleasePath := FScratch + '/unused-release';
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FLeaseRoot);
  Owner := Coordinator.TryAcquire(TEST_KEY, 'live producer');
  try
    Child := StartChild('abandon', TEST_KEY, Abandoned, ReleasePath);
    try
      Child.WaitOnExit;
      Expect<Integer>(Child.ExitStatus).ToBe(0);
      Expect<Boolean>(WaitForFile(Abandoned)).ToBe(True);
    finally
      Child.Free;
    end;
    Contender := Coordinator.TryAcquire(TEST_KEY, 'late contender');
    try
      Expect<Boolean>(Assigned(Contender)).ToBe(False);
    finally
      Contender.Free;
    end;
  finally
    Owner.Free;
    Coordinator.Free;
  end;
end;

procedure TProducerLeaseContract.TestReleasedProducerHandsOffToWaiter;
var
  Acquired, ReleasePath: string;
  Child: TProcess;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Owner: TLWPTProducerLease;
begin
  Acquired := FScratch + '/waiter-acquired';
  ReleasePath := FScratch + '/waiter-release';
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FLeaseRoot);
  Owner := Coordinator.TryAcquire(TEST_KEY, 'initial producer');
  try
    Child := StartChild('wait', TEST_KEY, Acquired, ReleasePath);
    try
      Sleep(200);
      Expect<Boolean>(FileExists(Acquired)).ToBe(False);
      FreeAndNil(Owner);
      Expect<Boolean>(WaitForFile(Acquired)).ToBe(True);
      WriteTextFile(ReleasePath, 'release');
      Child.WaitOnExit;
      Expect<Integer>(Child.ExitStatus).ToBe(0);
    finally
      Child.Free;
    end;
  finally
    Owner.Free;
    Coordinator.Free;
  end;
end;

procedure TProducerLeaseContract.TestCrashedProducerIsReclaimable;
var
  Acquired, ReleasePath: string;
  Child: TProcess;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Takeover: TLWPTProducerLease;
begin
  Acquired := FScratch + '/crash-acquired';
  ReleasePath := FScratch + '/unused-release';
  Child := StartChild('crash', TEST_KEY, Acquired, ReleasePath);
  try
    Expect<Boolean>(WaitForFile(Acquired)).ToBe(True);
    Child.WaitOnExit;
    Expect<Integer>(Child.ExitStatus).ToBe(77);
  finally
    Child.Free;
  end;
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FLeaseRoot);
  try
    Takeover := Coordinator.TryAcquire(TEST_KEY, 'takeover producer');
    try
      Expect<Boolean>(Assigned(Takeover)).ToBe(True);
    finally
      Takeover.Free;
    end;
  finally
    Coordinator.Free;
  end;
end;

procedure TProducerLeaseContract.TestStaleHeartbeatDoesNotDisplaceLiveOwner;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lines: TStringList;
  Owner, Contender: TLWPTProducerLease;
  Snapshot: TLWPTProducerLeaseSnapshot;
begin
  Coordinator := TLWPTProducerLeaseCoordinator.Create(FLeaseRoot);
  Owner := Coordinator.TryAcquire(TEST_KEY, 'long-running producer');
  try
    Lines := TStringList.Create;
    try
      Lines.LineBreak := #10;
      Lines.Add('schema=1');
      Lines.Add('key=' + SHA256Hex(BytesOf(TEST_KEY)));
      Lines.Add('description=long-running producer');
      Lines.Add('pid=' + IntToStr(GetProcessID));
      Lines.Add('started=1');
      Lines.Add('heartbeat=1');
      AtomicWriteText(StatePath(TEST_KEY), ExtractFileDir(StatePath(TEST_KEY)),
        Lines);
    finally
      Lines.Free;
    end;
    Expect<Boolean>(Coordinator.Snapshot(TEST_KEY, Snapshot)).ToBe(True);
    Expect<Boolean>(Snapshot.HeartbeatStale).ToBe(True);
    Contender := Coordinator.TryAcquire(TEST_KEY, 'stale takeover');
    try
      Expect<Boolean>(Assigned(Contender)).ToBe(False);
    finally
      Contender.Free;
    end;
  finally
    Owner.Free;
    Coordinator.Free;
  end;
end;

procedure TProducerLeaseContract.SetupTests;
begin
  Test('one local producer owns an object key',
    TestOneLocalProducerOwnsAKey);
  Test('different object keys proceed independently',
    TestDifferentKeysProceedIndependently);
  Test('waiter abandonment preserves the producer',
    TestWaiterAbandonmentPreservesProducer);
  Test('released producer hands off to a waiter',
    TestReleasedProducerHandsOffToWaiter);
  Test('crashed producer is reclaimable',
    TestCrashedProducerIsReclaimable);
  Test('stale heartbeat does not displace a live owner',
    TestStaleHeartbeatDoesNotDisplaceLiveOwner);
end;

begin
  if RunChildMode then Halt(0);
  TestRunnerProgram.AddSuite(TProducerLeaseContract.Create(
    'producer lease: local coalescing and recovery'));
  TestRunnerProgram.Run;
end.
