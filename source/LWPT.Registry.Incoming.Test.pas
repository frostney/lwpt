program LWPT.Registry.Incoming.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SyncObjs,
  SysUtils,

  LWPT.Core,
  LWPT.ProducerLease,
  LWPT.Registry.Incoming,
  LWPT.Registry.Store,
  TestingPascalLibrary,
  Tests.Scratch;

const
  MEBIBYTE = Int64(1024) * 1024;

type
  TAdmissionThread = class(TThread)
  private
    FIncoming: TLWPTRegistryIncoming;
    FLength: Int64;
  protected
    procedure Execute; override;
  public
    Upload: TLWPTRegistryUpload;
    Failure: string;
    constructor Create(AIncoming: TLWPTRegistryIncoming; const ALength: Int64);
  end;

  TCompletionThread = class(TThread)
  private
    FUpload: TLWPTRegistryUpload;
    FHex: string;
  protected
    procedure Execute; override;
  public
    Outcome: TLWPTRegistryUploadOutcome;
    Failure: string;
    Finished: LongInt;
    constructor Create(AUpload: TLWPTRegistryUpload; const AHex: string);
  end;

  TSweepThread = class(TThread)
  private
    FIncoming: TLWPTRegistryIncoming;
  protected
    procedure Execute; override;
  public
    constructor Create(AIncoming: TLWPTRegistryIncoming);
  end;

  { Takes a guard as soon as it is free and holds it for a while. }
  TGuardHolder = class(TThread)
  private
    FCoordinator: TLWPTProducerLeaseCoordinator;
    FKey: string;
    FHoldMilliseconds: Cardinal;
  protected
    procedure Execute; override;
  public
    Acquired: TEvent;
    constructor Create(const ALocks, AKey: string;
      const AHoldMilliseconds: Cardinal);
    destructor Destroy; override;
  end;

  TRegistryIncomingContract = class(TTestSuite)
  private
    FScratch: string;
    FHookPoint: string;
    FHookReached, FHookRelease: TEvent;
    procedure Hook(const APoint: string);
    function NewIncoming: TLWPTRegistryIncoming;
    procedure AddCompleted(const AName: string; const ASize: Int64);
    function PartCount: Integer;
    procedure WriteAll(AUpload: TLWPTRegistryUpload; const AText: string);
    function HexOf(const AText: string): string;
    function AdmissionFailure(AIncoming: TLWPTRegistryIncoming;
      const ALength: Int64): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestInProgressUploadCountsAtDeclaredLength;
    procedure TestConcurrentAdmissionsCannotOvercommit;
    procedure TestFailedUploadsReleaseTheirReservation;
    procedure TestExistingObjectReleasesItsReservation;
    procedure TestCompletionWaitsForAPausedAdmissionScan;
    procedure TestGuardTimeoutLeavesAReclaimableReservation;
    procedure TestLiveUploadSurvivesReclamation;
    procedure TestExpiryAndAdoptionHoldTheGuard;
    procedure TestExpiredChargeIsRemovedBeforeRefusing;
    procedure TestContendedExpiryIsRetryable;
    procedure TestLongPublicationIsRetryable;
  private
    FHolder: TGuardHolder;
    procedure HoldGuardAtExpiry(const APoint: string);
  end;

constructor TGuardHolder.Create(const ALocks, AKey: string;
  const AHoldMilliseconds: Cardinal);
begin
  FCoordinator := TLWPTProducerLeaseCoordinator.Create(ALocks);
  FKey := AKey;
  FHoldMilliseconds := AHoldMilliseconds;
  Acquired := TEvent.Create(nil, True, False, '');
  FreeOnTerminate := False;
  inherited Create(True);
end;

destructor TGuardHolder.Destroy;
begin
  Acquired.Free;
  FCoordinator.Free;
  inherited Destroy;
end;

procedure TGuardHolder.Execute;
var
  Guard: TObject;
  Started: QWord;
begin
  Guard := nil;
  Started := GetTickCount64;
  while not Assigned(Guard) and (GetTickCount64 - Started < 10000) do
  begin
    Guard := FCoordinator.TryAcquireGuard(FKey);
    if not Assigned(Guard) then Sleep(1);
  end;
  Acquired.SetEvent;
  Sleep(FHoldMilliseconds);
  Guard.Free;
end;

constructor TAdmissionThread.Create(AIncoming: TLWPTRegistryIncoming;
  const ALength: Int64);
begin
  FIncoming := AIncoming;
  FLength := ALength;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TAdmissionThread.Execute;
begin
  try
    Upload := FIncoming.Admit(FLength);
  except
    on E: Exception do Failure := E.Message;
  end;
end;

constructor TCompletionThread.Create(AUpload: TLWPTRegistryUpload;
  const AHex: string);
begin
  FUpload := AUpload;
  FHex := AHex;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TCompletionThread.Execute;
begin
  try
    Outcome := FUpload.Complete(FHex);
  except
    on E: Exception do Failure := E.Message;
  end;
  InterlockedExchange(Finished, 1);
end;

constructor TSweepThread.Create(AIncoming: TLWPTRegistryIncoming);
begin
  FIncoming := AIncoming;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSweepThread.Execute;
begin
  try
    FIncoming.Sweep;
  except
  end;
end;

procedure TRegistryIncomingContract.Hook(const APoint: string);
begin
  if APoint <> FHookPoint then Exit;
  FHookReached.SetEvent;
  FHookRelease.WaitFor(10000);
end;

function TRegistryIncomingContract.NewIncoming: TLWPTRegistryIncoming;
begin
  ForceDirectories(FScratch + '/origin/incoming/sha256');
  Result := TLWPTRegistryIncoming.Create(FScratch + '/origin');
end;

procedure TRegistryIncomingContract.AddCompleted(const AName: string;
  const ASize: Int64);
begin
  CreateSparseFile(FScratch + '/origin/incoming/sha256/' + AName, ASize);
end;

function TRegistryIncomingContract.PartCount: Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(FScratch + '/origin/incoming/*.part', faAnyFile, Search) = 0 then
  try
    repeat
      Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure TRegistryIncomingContract.WriteAll(AUpload: TLWPTRegistryUpload;
  const AText: string);
begin
  if AText <> '' then AUpload.Write(AText[1], Length(AText));
end;

function TRegistryIncomingContract.HexOf(const AText: string): string;
begin
  Result := SHA256Hex(BytesOf(AText));
end;

procedure TRegistryIncomingContract.BeforeEach;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
  FScratch := CreateScratchRoot('registry-incoming');
  FHookPoint := '';
  FHookReached := TEvent.Create(nil, True, False, '');
  FHookRelease := TEvent.Create(nil, True, False, '');
  SetRegistryIncomingHookForTesting(Hook);
end;

procedure TRegistryIncomingContract.AfterEach;
begin
  SetRegistryIncomingHookForTesting(nil);
  FHookRelease.SetEvent;
  FHookReached.Free;
  FHookRelease.Free;
end;

procedure TRegistryIncomingContract.AfterAll;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
end;

procedure TRegistryIncomingContract.TestInProgressUploadCountsAtDeclaredLength;
var
  Incoming: TLWPTRegistryIncoming;
  Upload: TLWPTRegistryUpload;
  Bytes: Int64;
  Entries: Integer;
begin
  Incoming := NewIncoming;
  Upload := nil;
  try
    Upload := Incoming.Admit(100 * MEBIBYTE);
    Incoming.Usage(Bytes, Entries);
    Expect<Int64>(Bytes).ToBe(100 * MEBIBYTE);
    Expect<Integer>(Entries).ToBe(1);
    WriteAll(Upload, 'partial');
    Incoming.Usage(Bytes, Entries);
    Expect<Int64>(Bytes).ToBe(100 * MEBIBYTE);
  finally
    Upload.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestConcurrentAdmissionsCannotOvercommit;
var
  Incoming: TLWPTRegistryIncoming;
  First, Second: TAdmissionThread;
  Admitted, Refused: Integer;
begin
  AddCompleted(StringOfChar('a', 64), 600 * MEBIBYTE);
  Incoming := NewIncoming;
  First := TAdmissionThread.Create(Incoming, 256 * MEBIBYTE);
  Second := TAdmissionThread.Create(Incoming, 256 * MEBIBYTE);
  try
    First.WaitFor;
    Second.WaitFor;
    Admitted := Ord(Assigned(First.Upload)) + Ord(Assigned(Second.Upload));
    Refused := Ord(Pos('storage_budget_exceeded:', First.Failure) = 1)
      + Ord(Pos('storage_budget_exceeded:', Second.Failure) = 1);
    Expect<Integer>(Admitted).ToBe(1);
    Expect<Integer>(Refused).ToBe(1);
    Expect<Integer>(PartCount).ToBe(1);
  finally
    First.Upload.Free;
    Second.Upload.Free;
    First.Free;
    Second.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestFailedUploadsReleaseTheirReservation;
var
  Incoming: TLWPTRegistryIncoming;
  Upload: TLWPTRegistryUpload;
  Bytes: Int64;
  Entries: Integer;
begin
  Incoming := NewIncoming;
  try
    Upload := Incoming.Admit(5);
    try
      WriteAll(Upload, 'hello');
      Expect<Boolean>(Upload.Complete(HexOf('other')) = ruoMismatch).ToBe(True);
    finally
      Upload.Free;
    end;
    Incoming.Usage(Bytes, Entries);
    Expect<Int64>(Bytes).ToBe(0);
    Expect<Integer>(PartCount).ToBe(0);
    Upload := Incoming.Admit(5);
    try
      WriteAll(Upload, 'he');
      Expect<Boolean>(Upload.Abandon).ToBe(True);
    finally
      Upload.Free;
    end;
    { A dropped connection that never reaches Complete or Abandon. }
    Upload := Incoming.Admit(5);
    WriteAll(Upload, 'h');
    Upload.Free;
    Incoming.Usage(Bytes, Entries);
    Expect<Int64>(Bytes).ToBe(0);
    Expect<Integer>(Entries).ToBe(0);
  finally
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestExistingObjectReleasesItsReservation;
var
  Incoming: TLWPTRegistryIncoming;
  Upload: TLWPTRegistryUpload;
  Bytes: Int64;
  Entries: Integer;
begin
  Incoming := NewIncoming;
  try
    Upload := Incoming.Admit(5);
    try
      WriteAll(Upload, 'hello');
      Expect<Boolean>(Upload.Complete(HexOf('hello')) = ruoCreated).ToBe(True);
    finally
      Upload.Free;
    end;
    Upload := Incoming.Admit(5);
    try
      WriteAll(Upload, 'hello');
      Expect<Boolean>(Upload.Complete(HexOf('hello')) = ruoExisting).ToBe(True);
    finally
      Upload.Free;
    end;
    Incoming.Usage(Bytes, Entries);
    Expect<Int64>(Bytes).ToBe(5);
    Expect<Integer>(Entries).ToBe(1);
    Expect<Boolean>(FileExists(Incoming.CompletedPath(HexOf('hello')))).ToBe(True);
  finally
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestCompletionWaitsForAPausedAdmissionScan;
var
  Incoming: TLWPTRegistryIncoming;
  Upload: TLWPTRegistryUpload;
  Admission: TAdmissionThread;
  Completion: TCompletionThread;
  Bytes: Int64;
  Entries: Integer;
begin
  { Three completed 256 MiB objects and one small upload in progress: a new
    256 MiB admission must see the upload's charge wherever it is. }
  AddCompleted(StringOfChar('1', 64), 256 * MEBIBYTE);
  AddCompleted(StringOfChar('2', 64), 256 * MEBIBYTE);
  AddCompleted(StringOfChar('3', 64), 256 * MEBIBYTE);
  Incoming := NewIncoming;
  Upload := Incoming.Admit(5);
  Admission := nil;
  Completion := nil;
  try
    WriteAll(Upload, 'hello');
    FHookPoint := 'admission-scan';
    Admission := TAdmissionThread.Create(Incoming, 256 * MEBIBYTE);
    Expect<Boolean>(FHookReached.WaitFor(10000) = wrSignaled)
      .ToBe(True);
    Completion := TCompletionThread.Create(Upload, HexOf('hello'));
    Sleep(300);
    Expect<Integer>(InterlockedCompareExchange(Completion.Finished, 0, 0))
      .ToBe(0);
    Expect<Integer>(PartCount).ToBe(1);
    FHookPoint := '';
    FHookRelease.SetEvent;
    Admission.WaitFor;
    Completion.WaitFor;
    Expect<Boolean>(Pos('storage_budget_exceeded:', Admission.Failure) = 1)
      .ToBe(True);
    Expect<Boolean>(Admission.Upload = nil).ToBe(True);
    Expect<string>(Completion.Failure).ToBe('');
    Expect<Boolean>(Completion.Outcome = ruoCreated).ToBe(True);
    Incoming.Usage(Bytes, Entries);
    Expect<Int64>(Bytes).ToBe(768 * MEBIBYTE + 5);
    Expect<Integer>(Entries).ToBe(4);
  finally
    FHookRelease.SetEvent;
    if Assigned(Admission) then
    begin
      Admission.WaitFor;
      Admission.Upload.Free;
      Admission.Free;
    end;
    if Assigned(Completion) then
    begin
      Completion.WaitFor;
      Completion.Free;
    end;
    Upload.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestGuardTimeoutLeavesAReclaimableReservation;
var
  Incoming: TLWPTRegistryIncoming;
  Holder: TLWPTProducerLeaseCoordinator;
  Guard, Probe: TObject;
  Completing, Mismatched, Fitting: TLWPTRegistryUpload;
  Diagnostic: string;
  StartedAt: QWord;
begin
  AddCompleted(StringOfChar('f', 64), 1024 * MEBIBYTE - 10);
  Incoming := NewIncoming;
  Holder := TLWPTProducerLeaseCoordinator.Create(FScratch + '/origin/locks');
  Completing := nil;
  Mismatched := nil;
  Fitting := nil;
  Guard := nil;
  try
    Completing := Incoming.Admit(5);
    Mismatched := Incoming.Admit(5);
    WriteAll(Completing, 'hello');
    WriteAll(Mismatched, 'wrong');
    Guard := Holder.TryAcquireGuard(REGISTRY_INCOMING_LEASE);
    Expect<Boolean>(Assigned(Guard)).ToBe(True);
    StartedAt := GetTickCount64;
    Diagnostic := '';
    try
      Completing.Complete(HexOf('hello'));
    except
      on E: ELWPTRegistryBusy do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('temporary_failure:', Diagnostic) = 1).ToBe(True);
    Expect<Boolean>(GetTickCount64 - StartedAt >= 1900).ToBe(True);
    Diagnostic := '';
    try
      Mismatched.Complete(HexOf('hello'));
    except
      on E: ELWPTRegistryBusy do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('temporary_failure:', Diagnostic) = 1).ToBe(True);
    { Both reservations stay charged at full length; their owners released
      the upload leases, so the reservations are reclaimable. }
    Expect<Integer>(PartCount).ToBe(2);
    Probe := Holder.TryAcquireGuard(REGISTRY_UPLOAD_LEASE_PREFIX + Completing.ID);
    Expect<Boolean>(Assigned(Probe)).ToBe(True);
    Probe.Free;
    { A timed-out admission holds nothing and leaves nothing. }
    Diagnostic := '';
    try
      Incoming.Admit(1);
    except
      on E: ELWPTRegistryBusy do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('temporary_failure:', Diagnostic) = 1).ToBe(True);
    Expect<Integer>(PartCount).ToBe(2);
    FreeAndNil(Guard);
    { The next admission reclaims both and now fits. }
    Fitting := Incoming.Admit(10);
    Expect<Integer>(PartCount).ToBe(1);
  finally
    Guard.Free;
    Fitting.Free;
    Completing.Free;
    Mismatched.Free;
    Holder.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestLiveUploadSurvivesReclamation;
var
  Incoming: TLWPTRegistryIncoming;
  Live, Other: TLWPTRegistryUpload;
begin
  Incoming := NewIncoming;
  Live := nil;
  Other := nil;
  try
    Live := Incoming.Admit(5);
    WriteAll(Live, 'he');
    Other := Incoming.Admit(5);
    Expect<Integer>(PartCount).ToBe(2);
    Expect<Boolean>(Incoming.Sweep).ToBe(True);
    Expect<Integer>(PartCount).ToBe(2);
    WriteAll(Live, 'llo');
    Expect<Boolean>(Live.Complete(HexOf('hello')) = ruoCreated).ToBe(True);
  finally
    Live.Free;
    Other.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestExpiryAndAdoptionHoldTheGuard;
var
  Incoming: TLWPTRegistryIncoming;
  Upload: TLWPTRegistryUpload;
  Completion: TCompletionThread;
  Old, Fresh: string;
  Sweeper: TSweepThread;
begin
  Incoming := NewIncoming;
  Upload := nil;
  Completion := nil;
  Sweeper := nil;
  try
    Old := StringOfChar('0', 64);
    Fresh := StringOfChar('9', 64);
    { Admission sweeps expired entries itself when no publication runs, so
      the expired entry is created after this admission. }
    Upload := Incoming.Admit(5);
    WriteAll(Upload, 'hello');
    AddCompleted(Old, 3);
    AddCompleted(Fresh, 3);
    FileSetDate(Incoming.CompletedPath(Old),
      DateTimeToFileDate(Now - 2 / 24));
    FHookPoint := 'expire';
    Sweeper := TSweepThread.Create(Incoming);
    Expect<Boolean>(FHookReached.WaitFor(10000) = wrSignaled)
      .ToBe(True);
    Completion := TCompletionThread.Create(Upload, HexOf('hello'));
    Sleep(300);
    Expect<Integer>(InterlockedCompareExchange(Completion.Finished, 0, 0))
      .ToBe(0);
    FHookPoint := '';
    FHookRelease.SetEvent;
    Sweeper.WaitFor;
    Completion.WaitFor;
    Expect<Boolean>(FileExists(Incoming.CompletedPath(Old))).ToBe(False);
    Expect<Boolean>(FileExists(Incoming.CompletedPath(Fresh))).ToBe(True);
    Expect<Boolean>(Completion.Outcome = ruoCreated).ToBe(True);
    Incoming.Adopt(HexOf('hello'));
    Expect<Boolean>(FileExists(Incoming.ObjectPath(HexOf('hello')))).ToBe(True);
    Expect<Boolean>(FileExists(Incoming.CompletedPath(HexOf('hello'))))
      .ToBe(False);
  finally
    FHookRelease.SetEvent;
    if Assigned(Sweeper) then
    begin
      Sweeper.WaitFor;
      Sweeper.Free;
    end;
    if Assigned(Completion) then
    begin
      Completion.WaitFor;
      Completion.Free;
    end;
    Upload.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.HoldGuardAtExpiry(const APoint: string);
begin
  { Admission now owns the publication lease; another operation takes the
    accounting guard before admission's sweep can. }
  if (APoint <> 'expiry-owned') or not Assigned(FHolder) then Exit;
  FHolder.Start;
  FHolder.Acquired.WaitFor(10000);
end;

procedure TRegistryIncomingContract.TestExpiredChargeIsRemovedBeforeRefusing;
var
  Incoming: TLWPTRegistryIncoming;
  Upload: TLWPTRegistryUpload;
  Filler: string;
begin
  Incoming := NewIncoming;
  Upload := nil;
  try
    Filler := StringOfChar('e', 64);
    AddCompleted(Filler, 1024 * MEBIBYTE - 10);
    Expect<Boolean>(Pos('storage_budget_exceeded:', AdmissionFailure(Incoming,
      100)) = 1).ToBe(True);
    FileSetDate(Incoming.CompletedPath(Filler), DateTimeToFileDate(Now - 2 / 24));
    { Another operation holds the accounting guard at admission and again
      when admission removes the expired upload; both waits are bounded
      and admission succeeds once each holder is done. }
    FHolder := TGuardHolder.Create(FScratch + '/origin/locks',
      REGISTRY_INCOMING_LEASE, 800);
    SetRegistryIncomingHookForTesting(HoldGuardAtExpiry);
    Upload := Incoming.Admit(100);
    Expect<Boolean>(Assigned(Upload)).ToBe(True);
    Expect<Boolean>(FileExists(Incoming.CompletedPath(Filler))).ToBe(False);
  finally
    SetRegistryIncomingHookForTesting(Hook);
    if Assigned(FHolder) then
    begin
      if FHolder.Suspended then FHolder.Start;
      FHolder.WaitFor;
      FreeAndNil(FHolder);
    end;
    Upload.Free;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestContendedExpiryIsRetryable;
var
  Incoming: TLWPTRegistryIncoming;
  Filler, Diagnostic: string;
begin
  Incoming := NewIncoming;
  try
    Filler := StringOfChar('e', 64);
    AddCompleted(Filler, 1024 * MEBIBYTE - 10);
    FileSetDate(Incoming.CompletedPath(Filler), DateTimeToFileDate(Now - 2 / 24));
    { The guard stays held past the two-second wait while admission tries to
      remove expired uploads: a retryable refusal, never a 507. }
    FHolder := TGuardHolder.Create(FScratch + '/origin/locks',
      REGISTRY_INCOMING_LEASE, 3000);
    SetRegistryIncomingHookForTesting(HoldGuardAtExpiry);
    Diagnostic := AdmissionFailure(Incoming, 100);
    Expect<Boolean>(Pos('temporary_failure:', Diagnostic) = 1).ToBe(True);
    Expect<Boolean>(FileExists(Incoming.CompletedPath(Filler))).ToBe(True);
    Expect<Integer>(PartCount).ToBe(0);
    SetRegistryIncomingHookForTesting(Hook);
    if FHolder.Suspended then FHolder.Start;
    FHolder.WaitFor;
    FreeAndNil(FHolder);
    Expect<string>(AdmissionFailure(Incoming, 100)).ToBe('');
    Expect<Boolean>(FileExists(Incoming.CompletedPath(Filler))).ToBe(False);
  finally
    SetRegistryIncomingHookForTesting(Hook);
    if Assigned(FHolder) then
    begin
      if FHolder.Suspended then FHolder.Start;
      FHolder.WaitFor;
      FreeAndNil(FHolder);
    end;
    Incoming.Free;
  end;
end;

procedure TRegistryIncomingContract.TestLongPublicationIsRetryable;
var
  Incoming: TLWPTRegistryIncoming;
  Holder: TLWPTProducerLeaseCoordinator;
  Publication: TObject;
  Filler, Diagnostic: string;
  Started: QWord;
begin
  Incoming := NewIncoming;
  Holder := TLWPTProducerLeaseCoordinator.Create(FScratch + '/origin/locks');
  Publication := nil;
  try
    Filler := StringOfChar('e', 64);
    AddCompleted(Filler, 1024 * MEBIBYTE - 10);
    FileSetDate(Incoming.CompletedPath(Filler), DateTimeToFileDate(Now - 2 / 24));
    Publication := Holder.TryAcquireGuard(REGISTRY_PUBLICATION_LEASE);
    Expect<Boolean>(Assigned(Publication)).ToBe(True);
    Started := GetTickCount64;
    Diagnostic := AdmissionFailure(Incoming, 100);
    Expect<Boolean>(Pos('temporary_failure:', Diagnostic) = 1).ToBe(True);
    Expect<Boolean>(GetTickCount64 - Started >= 4900).ToBe(True);
    Expect<Integer>(PartCount).ToBe(0);
    FreeAndNil(Publication);
    Expect<string>(AdmissionFailure(Incoming, 100)).ToBe('');
  finally
    Publication.Free;
    Holder.Free;
    Incoming.Free;
  end;
end;

function TRegistryIncomingContract.AdmissionFailure(
  AIncoming: TLWPTRegistryIncoming; const ALength: Int64): string;
var
  Upload: TLWPTRegistryUpload;
begin
  Result := '';
  try
    Upload := AIncoming.Admit(ALength);
    Upload.Free;
  except
    on E: Exception do Result := E.Message;
  end;
end;

procedure TRegistryIncomingContract.SetupTests;
begin
  Test('an in-progress upload counts at its declared length',
    TestInProgressUploadCountsAtDeclaredLength);
  Test('two admissions over the budget: exactly one proceeds',
    TestConcurrentAdmissionsCannotOvercommit);
  Test('a digest mismatch, an abort, or a dropped upload releases its reservation',
    TestFailedUploadsReleaseTheirReservation);
  Test('an existing object releases its reservation',
    TestExistingObjectReleasesItsReservation);
  Test('a completion waits for a paused admission scan, which refuses with 507',
    TestCompletionWaitsForAPausedAdmissionScan);
  Test('a guard timeout leaves a counted, reclaimable reservation',
    TestGuardTimeoutLeavesAReclaimableReservation);
  Test('a live upload survives reclamation', TestLiveUploadSurvivesReclamation);
  Test('expiry and adoption run under the guard', TestExpiryAndAdoptionHoldTheGuard);
  Test('expired uploads are removed before admission refuses capacity',
    TestExpiredChargeIsRemovedBeforeRefusing);
  Test('contended expiry answers a retryable failure, not 507',
    TestContendedExpiryIsRetryable);
  Test('a publication held past its wait makes expiry retryable',
    TestLongPublicationIsRetryable);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryIncomingContract.Create('registry incoming'));
  TestRunnerProgram.Run;
end.
