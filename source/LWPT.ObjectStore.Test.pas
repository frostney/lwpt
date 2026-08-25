{ Cross-platform contract tests for per-user root addressing and the generic
  immutable object store. The same executable also acts as a child producer
  so same-key publication is exercised across processes on every CI target. }
program LWPT.ObjectStore.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  Pipes,
  Process,
  SysUtils,

  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.ObjectStore,
  LWPT.ProcessTree,
  TestingPascalLibrary,
  Tests.Scratch;

const
  ADMIT_CHILD_SWITCH = '--object-store-admit-child';
  DIAGNOSTIC_ADMIT_CHILD_SWITCH = '--object-store-diagnostic-admit-child';
  GUARDED_ADMIT_CHILD_SWITCH = '--object-store-guarded-admit-child';
  START_BARRIER_TIMEOUT_MS = 10000;
  ADMIT_CHILD_TIMEOUT_MS = 5000;
  ADMIT_CHILD_TERMINATION_TIMEOUT_MS = 2000;
  CONTENTION_ITERATIONS = 16;
  DIAGNOSTIC_STREAM_BYTES = 256 * 1024;
  STDOUT_TAIL_MARKER = 'object-store-stdout-tail';
  STDERR_TAIL_MARKER = 'object-store-stderr-tail';

type
  TAdmitterResult = record
    ExitCode: Integer;
    ExitStatus: Integer;
    RawExitStatus: Integer;
    Stdout: string;
    Stderr: string;
    Phases: string;
    TimedOut: Boolean;
  end;

  TProcessStreamReader = class(TThread)
  private
    FErrorMessage: string;
    FOutput: string;
    FStream: TStream;
  protected
    procedure Execute; override;
  public
    constructor Create(const AStream: TStream);
    property ErrorMessage: string read FErrorMessage;
    property Output: string read FOutput;
  end;

  {$IFDEF UNIX}
  TProtectedStageSpawner = class(TThread)
  private
    FErrorMessage: string;
  protected
    procedure Execute; override;
  public
    constructor Create;
    property ErrorMessage: string read FErrorMessage;
  end;
  {$ENDIF}

var
  ChildPhasePrefix: string;
  InjectPublicationFailure: Boolean;
  ProtectedStageChild: TProcess;
  {$IFDEF UNIX}
  ProtectedStageSpawnAttemptPath: string;
  ProtectedStageSpawner: TProtectedStageSpawner;
  {$ENDIF}
  ProtectedStageChildReadyPath: string;
  ReplacementSource: string;
  StageReadyPath: string;
  StageReleasePath: string;

procedure RemoveMaterializeSource(const ADigest, APath: string);
begin
  SysUtils.DeleteFile(APath);
end;

procedure CorruptMaterializeSource(const ADigest, APath: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    Stream.WriteBuffer(ADigest[1], 1);
  finally
    Stream.Free;
  end;
end;

type
  TObjectStoreContract = class(TTestSuite)
  private
    FScratch: string;
    FStoreRoot: string;
    FSource: string;
    FDigest: string;
    procedure ResetScratch;
    procedure WriteBytes(const APath, AText: string);
    function ReadBytes(const APath: string): string;
    function StartAdmitter(const AReadyPath, AReleasePath: string;
      const AChildSwitch: string = ADMIT_CHILD_SWITCH): TProcess;
    procedure RunContentionIteration(const AIteration: Integer);
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestDigestAddressIsCanonicalAndSharded;
    procedure TestInvalidDigestIsRefused;
    procedure TestAdmitLookupAndMaterialize;
    procedure TestMaterializeReportsExactFailureStage;
    {$IFDEF UNIX}
    procedure TestMaterializeProtectsStageFromChildInheritance;
    {$ENDIF}
    procedure TestAdmissionHashMismatchPublishesNothing;
    procedure TestCorruptObjectIsQuarantinedAndMisses;
    procedure TestConcurrentValidReplacementIsRestoredAfterQuarantine;
    procedure TestInterruptedTemporaryObjectIsNeverVisible;
    procedure TestAfterPublicationFailureRollsBackAndRecovers;
    procedure TestAdmitterFailurePreservesDiagnostics;
    procedure TestConcurrentSameKeyAdmissionPublishesOneCompleteObject;
    procedure TestRepairPreservesActiveCrossProcessAdmission;
    procedure TestCacheRootOverrideIsAbsoluteAndNormalized;
    procedure TestPlatformDefaultUsesPerUserCacheLocation;
  end;

procedure WriteSignal(const APath: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  Stream.Free;
end;

function WaitForSignal(const APath: string): Boolean; forward;

{$IFDEF UNIX}
procedure MarkProtectedStageSpawnAttempt;
begin
  WriteSignal(ProtectedStageSpawnAttemptPath);
end;

constructor TProtectedStageSpawner.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
end;

procedure TProtectedStageSpawner.Execute;
begin
  FErrorMessage := '';
  try
    ProtectedStageChild := TProcess.Create(nil);
    ProtectedStageChild.Executable := '/bin/sh';
    ProtectedStageChild.Parameters.Add('-c');
    ProtectedStageChild.Parameters.Add(
      'printf ready > "$1"; sleep 5');
    ProtectedStageChild.Parameters.Add('object-store-child');
    ProtectedStageChild.Parameters.Add(ProtectedStageChildReadyPath);
    ProtectedStageChild.Options := [poNoConsole];
    ExecuteUnmanagedProcess(ProtectedStageChild);
  except
    on E: Exception do FErrorMessage := E.Message;
  end;
end;

procedure AttemptSpawnBeforeStreamProtection(const APath: string);
begin
  if Pos('cache-object.', ExtractFileName(APath)) <> 1 then Exit;
  ProtectedStageSpawnAttemptPath := APath + '.spawn-attempt';
  ProtectedStageChildReadyPath := APath + '.child-ready';
  ProcessTreeBeforeUnmanagedSpawnLockTestHook :=
    MarkProtectedStageSpawnAttempt;
  ProtectedStageSpawner := TProtectedStageSpawner.Create;
  ProtectedStageSpawner.Start;
  if not WaitForSignal(ProtectedStageSpawnAttemptPath) then
    raise Exception.Create('timed out waiting for concurrent spawn attempt');
  Sleep(100);
  if FileExists(ProtectedStageChildReadyPath) then
    raise Exception.Create(
      'concurrent child escaped the stream-protection spawn guard');
end;
{$ENDIF}

procedure MarkChildPhase(const APhase: string);
begin
  WriteSignal(ChildPhasePrefix + '.phase-' + APhase);
end;

procedure PauseAfterStage(const APath: string);
begin
  MarkChildPhase('06-object-staged');
  WriteSignal(StageReadyPath);
  MarkChildPhase('07-stage-ready-signaled');
  if not WaitForSignal(StageReleasePath) then
    raise Exception.CreateFmt(
      'timed out waiting to release staged object %s', [APath]);
  MarkChildPhase('08-stage-release-observed');
end;

procedure ObserveAfterStage(const APath: string);
begin
  MarkChildPhase('06-object-staged');
end;

procedure BeforePublication(const AStaged, ADestination: string);
begin
  MarkChildPhase('09-publication-started');
  if InjectPublicationFailure then
  begin
    WriteLn(StringOfChar('o', DIAGNOSTIC_STREAM_BYTES));
    WriteLn(STDOUT_TAIL_MARKER);
    Flush(Output);
    WriteLn(ErrOutput, StringOfChar('e', DIAGNOSTIC_STREAM_BYTES));
    WriteLn(ErrOutput, STDERR_TAIL_MARKER);
    Flush(ErrOutput);
    raise Exception.Create('intentional object-store child failure');
  end;
end;

procedure AfterPublication(const AStaged, ADestination: string);
begin
  MarkChildPhase('10-publication-completed');
end;

procedure FailAfterPublication(const AStaged, ADestination: string);
begin
  raise Exception.Create('intentional after-publication failure');
end;

function WaitForSignal(const APath: string): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    if FileExists(APath) then Exit(True);
    Sleep(10);
  until GetTickCount64 - Started >= START_BARRIER_TIMEOUT_MS;
  Result := FileExists(APath);
end;

constructor TProcessStreamReader.Create(const AStream: TStream);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStream := AStream;
end;

procedure TProcessStreamReader.Execute;
const
  CHUNK_SIZE = 4096;
var
  Count, Total: Integer;
  Buffer: array[0..CHUNK_SIZE - 1] of Byte;
begin
  FOutput := '';
  FErrorMessage := '';
  Total := 0;
  try
    repeat
      Count := FStream.Read(Buffer[0], CHUNK_SIZE);
      if Count > 0 then
      begin
        SetLength(FOutput, Total + Count);
        Move(Buffer[0], FOutput[Total + 1], Count);
        Inc(Total, Count);
      end;
    until Count <= 0;
  except
    on E: Exception do FErrorMessage := E.Message;
  end;
end;

function CollectChildPhases(const APrefix: string): string; forward;

function ForceTerminateAdmitter(const AProcess: TProcess;
  out AErrorCode: Integer): Boolean;
begin
  AErrorCode := 0;
  {$IFDEF UNIX}
  Result := fpKill(AProcess.ProcessID, SIGKILL) = 0;
  if not Result then AErrorCode := fpgeterrno;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := Windows.TerminateProcess(AProcess.ProcessHandle, 1);
  if not Result then AErrorCode := Windows.GetLastError;
  {$ENDIF}
end;

procedure AbortForUnreapedAdmitter(const AProcess: TProcess;
  const APhasePrefix: string; const ATerminationSent: Boolean;
  const ATerminationError: Integer);
begin
  WriteLn('OBJECT STORE ADMITTER [unreaped child] process-id=',
    AProcess.ProcessID, ' status=unavailable termination-sent=',
    BoolToStr(ATerminationSent, True), ' termination-error=',
    ATerminationError, ' phases=', CollectChildPhases(APhasePrefix));
  { Reader destruction waits for EOF. If forced termination cannot be reaped,
    exiting the test process is the only bounded cleanup that cannot deadlock
    on pipe handles still owned by the child. }
  Halt(1);
end;

function CollectChildPhases(const APrefix: string): string;
var
  Phases: TStringList;
  Search: TSearchRec;
begin
  Phases := TStringList.Create;
  try
    if FindFirst(APrefix + '.phase-*', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Attr and faDirectory) = 0 then
          Phases.Add(Copy(Search.Name, Pos('.phase-', Search.Name) + 7,
            MaxInt));
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    Phases.Sort;
    Result := StringReplace(Trim(Phases.Text), LineEnding, ',',
      [rfReplaceAll]);
    if Result = '' then Result := '(none)';
  finally
    Phases.Free;
  end;
end;

function FinishAdmitter(const AProcess: TProcess;
  const APhasePrefix: string): TAdmitterResult;
var
  StderrReader, StdoutReader: TProcessStreamReader;
  StartedAt: QWord;
  TerminationError: Integer;
  TerminationSent: Boolean;
begin
  Result.TimedOut := False;
  Result.Stdout := '';
  Result.Stderr := '';
  StdoutReader := TProcessStreamReader.Create(AProcess.Output);
  StderrReader := TProcessStreamReader.Create(AProcess.Stderr);
  try
    { Windows anonymous pipes can block a large writer while a polling reader
      observes no complete write. Drain stdout and stderr independently until
      EOF so neither stream can prevent the deliberate child failure. }
    StdoutReader.Start;
    StderrReader.Start;
    StartedAt := GetTickCount64;
    while AProcess.Running
      and (GetTickCount64 - StartedAt < ADMIT_CHILD_TIMEOUT_MS) do
      Sleep(10);
    if AProcess.Running then
    begin
      Result.TimedOut := True;
      TerminationSent := ForceTerminateAdmitter(AProcess, TerminationError);
      if not AProcess.WaitOnExit(ADMIT_CHILD_TERMINATION_TIMEOUT_MS) then
        AbortForUnreapedAdmitter(AProcess, APhasePrefix, TerminationSent,
          TerminationError);
    end;
    if AProcess.Running then AProcess.WaitOnExit;
    StdoutReader.WaitFor;
    StderrReader.WaitFor;
    if StdoutReader.ErrorMessage <> '' then
      raise Exception.Create('could not read object-store admitter stdout: '
        + StdoutReader.ErrorMessage);
    if StderrReader.ErrorMessage <> '' then
      raise Exception.Create('could not read object-store admitter stderr: '
        + StderrReader.ErrorMessage);
    Result.Stdout := StdoutReader.Output;
    Result.Stderr := StderrReader.Output;
  finally
    StdoutReader.Free;
    StderrReader.Free;
  end;
  Result.ExitCode := AProcess.ExitCode;
  Result.RawExitStatus := AProcess.ExitStatus;
  Result.ExitStatus := Result.RawExitStatus;
  {$IFDEF UNIX}
  if (Result.ExitStatus > 255) and (Result.ExitStatus mod 256 = 0) then
    Result.ExitStatus := Result.ExitStatus div 256;
  {$ENDIF}
  Result.Phases := CollectChildPhases(APhasePrefix);
end;

function AdmitterDiagnostic(const ALabel: string;
  const AResult: TAdmitterResult): string;
begin
  Result := 'OBJECT STORE ADMITTER [' + ALabel + '] exit-status='
    + IntToStr(AResult.ExitStatus) + ' exit-code='
    + IntToStr(AResult.ExitCode) + ' raw-exit-status='
    + IntToStr(AResult.RawExitStatus) + ' timed-out='
    + BoolToStr(AResult.TimedOut, True) + ' phases=' + AResult.Phases
    + LineEnding + '--- stdout ---' + LineEnding + AResult.Stdout
    + LineEnding + '--- stderr ---' + LineEnding + AResult.Stderr
    + LineEnding + '--- end admitter ---';
end;

procedure DumpAdmitterFailure(const ALabel: string;
  const AResult: TAdmitterResult);
begin
  if AResult.TimedOut or (AResult.ExitStatus <> 0) then
    WriteLn(AdmitterDiagnostic(ALabel, AResult));
end;

function RunChildMode: Boolean;
var
  Store: TLWPTImmutableObjectStore;
begin
  Result := False;
  if (ParamCount <> 6) or ((ParamStr(1) <> ADMIT_CHILD_SWITCH)
     and (ParamStr(1) <> DIAGNOSTIC_ADMIT_CHILD_SWITCH)
     and (ParamStr(1) <> GUARDED_ADMIT_CHILD_SWITCH)) then Exit;
  ChildPhasePrefix := ParamStr(5);
  InjectPublicationFailure := ParamStr(1) = DIAGNOSTIC_ADMIT_CHILD_SWITCH;
  MarkChildPhase('01-child-started');
  Store := TLWPTImmutableObjectStore.Create(ParamStr(2),
    ExtractFileDir(ParamStr(2)), DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    MarkChildPhase('02-store-created');
    ObjectStoreBeforePublicationTestHook := BeforePublication;
    ObjectStoreAfterPublicationTestHook := AfterPublication;
    if ParamStr(1) = GUARDED_ADMIT_CHILD_SWITCH then
    begin
      StageReadyPath := ParamStr(5);
      StageReleasePath := ParamStr(6);
      ObjectStoreAfterStageTestHook := PauseAfterStage;
      MarkChildPhase('03-stage-hook-configured');
    end
    else
    begin
      ObjectStoreAfterStageTestHook := ObserveAfterStage;
      WriteSignal(ParamStr(5));
      MarkChildPhase('03-ready-signaled');
      if not WaitForSignal(ParamStr(6)) then
        raise Exception.Create(
          'timed out waiting for object-store start barrier');
      MarkChildPhase('04-release-observed');
    end;
    if ParamStr(1) = GUARDED_ADMIT_CHILD_SWITCH then
      MarkChildPhase('04-admission-started')
    else
      MarkChildPhase('05-admission-started');
    Store.Admit(ParamStr(3), ParamStr(4));
    MarkChildPhase('11-admission-completed');
  finally
    ObjectStoreAfterStageTestHook := nil;
    ObjectStoreBeforePublicationTestHook := nil;
    ObjectStoreAfterPublicationTestHook := nil;
    InjectPublicationFailure := False;
    Store.Free;
  end;
  MarkChildPhase('12-child-completed');
  Result := True;
end;

procedure PublishValidReplacement(const APath: string);
var
  Staged: string;
begin
  ObjectStoreBeforeQuarantineTestHook := nil;
  Staged := APath + '.replacement';
  if not CopyFileContent(ReplacementSource, Staged) then
    raise Exception.Create('failed to stage object-store test replacement');
  if not AtomicReplaceFile(Staged, APath) then
    raise Exception.Create('failed to publish object-store test replacement');
end;

procedure TObjectStoreContract.WriteBytes(const APath, AText: string);
var
  Stream: TFileStream;
  Raw: RawByteString;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    Raw := RawByteString(AText);
    if Length(Raw) > 0 then Stream.WriteBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
end;

function TObjectStoreContract.ReadBytes(const APath: string): string;
var
  Stream: TFileStream;
  Raw: RawByteString;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Raw, Stream.Size);
    if Length(Raw) > 0 then Stream.ReadBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
  Result := string(Raw);
end;

procedure TObjectStoreContract.ResetScratch;
begin
  ObjectStoreBeforeMaterializeCopyTestHook := nil;
  ObjectStoreAfterMaterializeCopyTestHook := nil;
  ObjectStoreBeforeStreamProtectionTestHook := nil;
  {$IFDEF UNIX}
  ProcessTreeBeforeUnmanagedSpawnLockTestHook := nil;
  ProtectedStageSpawnAttemptPath := '';
  ProtectedStageSpawner := nil;
  {$ENDIF}
  ProtectedStageChild := nil;
  ProtectedStageChildReadyPath := '';
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
  FStoreRoot := FScratch + '/cache/dependency-archives';
  FSource := FScratch + '/source/archive.tar.gz';
  WriteBytes(FSource, 'immutable archive bytes'#0'with binary tail');
  FDigest := 'sha256:' + SHA256File(FSource);
end;

{$IFDEF UNIX}
procedure TObjectStoreContract.
  TestMaterializeProtectsStageFromChildInheritance;
var
  Destination: string;
  ErrorCode: Integer;
  Handle: THandle;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Store.Admit(FSource, FDigest);
    ObjectStoreBeforeStreamProtectionTestHook :=
      AttemptSpawnBeforeStreamProtection;
    Destination := FScratch + '/project/materialized';
    Expect<Boolean>(Store.Materialize(FDigest, Destination,
      FScratch + '/project/tmp')).ToBe(True);
    Expect<Boolean>(WaitForSignal(ProtectedStageChildReadyPath)).ToBe(True);
    ProtectedStageSpawner.WaitFor;
    Expect<string>(ProtectedStageSpawner.ErrorMessage).ToBe('');
    Expect<Boolean>(Assigned(ProtectedStageChild)).ToBe(True);
    Expect<Boolean>(ProtectedStageChild.Running).ToBe(True);
    Handle := FileOpen(Destination, fmOpenRead or fmShareDenyNone);
    if Handle = THandle(-1) then ErrorCode := GetLastOSError
    else
    begin
      ErrorCode := 0;
      FileClose(Handle);
    end;
    Expect<Integer>(ErrorCode).ToBe(0);
  finally
    ObjectStoreBeforeStreamProtectionTestHook := nil;
    ProcessTreeBeforeUnmanagedSpawnLockTestHook := nil;
    if Assigned(ProtectedStageSpawner) then
    begin
      ProtectedStageSpawner.WaitFor;
      ProtectedStageSpawner.Free;
      ProtectedStageSpawner := nil;
    end;
    if Assigned(ProtectedStageChild) then
    begin
      if ProtectedStageChild.Running then
        ProtectedStageChild.Terminate(0);
      ProtectedStageChild.WaitOnExit(2000);
      ProtectedStageChild.Free;
      ProtectedStageChild := nil;
    end;
    if FileExists(ProtectedStageChildReadyPath) then
      SysUtils.DeleteFile(ProtectedStageChildReadyPath);
    if FileExists(ProtectedStageSpawnAttemptPath) then
      SysUtils.DeleteFile(ProtectedStageSpawnAttemptPath);
    ProtectedStageChildReadyPath := '';
    ProtectedStageSpawnAttemptPath := '';
    Store.Free;
  end;
  Expect<string>(ReadBytes(Destination)).ToBe(ReadBytes(FSource));
end;
{$ENDIF}

procedure TObjectStoreContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('object-store');
end;

procedure TObjectStoreContract.BeforeEach;
begin
  ResetScratch;
end;

procedure TObjectStoreContract.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

function TObjectStoreContract.StartAdmitter(const AReadyPath,
  AReleasePath, AChildSwitch: string): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ParamStr(0);
  Result.Parameters.Add(AChildSwitch);
  Result.Parameters.Add(FStoreRoot);
  Result.Parameters.Add(FSource);
  Result.Parameters.Add(FDigest);
  Result.Parameters.Add(AReadyPath);
  Result.Parameters.Add(AReleasePath);
  Result.Options := [poNoConsole, poUsePipes];
  Result.Execute;
end;

procedure TObjectStoreContract.TestRepairPreservesActiveCrossProcessAdmission;
var
  Admitter: TProcess;
  AdmitterFinished: Boolean;
  AdmitterResult: TAdmitterResult;
  ReadyPath, ReleasePath: string;
  Report: TLWPTCacheRepairReport;
  Store: TLWPTImmutableObjectStore;
begin
  ReadyPath := FScratch + '/staged-ready';
  ReleasePath := FScratch + '/release-staged';
  Admitter := StartAdmitter(ReadyPath, ReleasePath,
    GUARDED_ADMIT_CHILD_SWITCH);
  AdmitterFinished := False;
  try
    Expect<Boolean>(WaitForSignal(ReadyPath)).ToBe(True);
    Report := RepairSharedCache(FScratch + '/cache');
    Expect<Boolean>(Report.LiveObjectsPreserved >= 1).ToBe(True);
    WriteSignal(ReleasePath);
    AdmitterResult := FinishAdmitter(Admitter, ReadyPath);
    AdmitterFinished := True;
  finally
    if not FileExists(ReleasePath) then WriteSignal(ReleasePath);
    if not AdmitterFinished then
      AdmitterResult := FinishAdmitter(Admitter, ReadyPath);
    DumpAdmitterFailure('repair admission', AdmitterResult);
    Admitter.Free;
  end;
  Expect<Boolean>(AdmitterResult.TimedOut).ToBe(False);
  Expect<Integer>(AdmitterResult.ExitStatus).ToBe(0);
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Expect<Boolean>(FileExists(Store.ObjectPath(FDigest))).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestDigestAddressIsCanonicalAndSharded;
var
  Store: TLWPTImmutableObjectStore;
  Hex, Expected: string;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Hex := Copy(FDigest, 8, MaxInt);
    Expected := IncludeTrailingPathDelimiter(ExpandFileName(FStoreRoot))
      + 'sha256/' + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
    Expect<string>(Store.ObjectPath(UpperCase(FDigest))).ToBe(Expected);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestInvalidDigestIsRefused;
var
  Store: TLWPTImmutableObjectStore;
  Refused: Boolean;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Refused := False;
    try
      Store.ObjectPath('sha256:not-a-digest');
    except
      on E: ELWPTObjectStoreError do Refused := True;
    end;
    Expect<Boolean>(Refused).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestAdmitLookupAndMaterialize;
var
  Store: TLWPTImmutableObjectStore;
  ObjectPath, HitPath, Destination: string;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    ObjectPath := Store.Admit(FSource, FDigest);
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(True);
    Expect<string>(HitPath).ToBe(ObjectPath);
    Destination := FScratch + '/project/.lwpt/archives/dep-ref.tar.gz';
    Expect<Boolean>(Store.Materialize(FDigest, Destination,
      FScratch + '/project/.lwpt/tmp')).ToBe(True);
    Expect<string>(ReadBytes(Destination)).ToBe(ReadBytes(FSource));
    Expect<string>('sha256:' + SHA256File(Destination)).ToBe(FDigest);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestMaterializeReportsExactFailureStage;
var
  Destination, MissingDigest: string;
  Failure: TLWPTObjectMaterializeFailure;
  Store: TLWPTImmutableObjectStore;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    MissingDigest := 'sha256:' + StringOfChar('0', 64);
    Destination := FScratch + '/project/materialized';
    Expect<Boolean>(Store.Materialize(MissingDigest, Destination,
      FScratch + '/project/tmp', Failure)).ToBe(False);
    Expect<Integer>(Ord(Failure)).ToBe(Ord(omfObjectMissing));

    Store.Admit(FSource, FDigest);
    WriteBytes(Store.ObjectPath(FDigest), 'corrupt');
    Expect<Boolean>(Store.Materialize(FDigest, Destination,
      FScratch + '/project/tmp', Failure)).ToBe(False);
    Expect<Integer>(Ord(Failure)).ToBe(Ord(omfVerificationFailed));

    Store.Admit(FSource, FDigest);
    ObjectStoreBeforeMaterializeCopyTestHook := RemoveMaterializeSource;
    try
      Expect<Boolean>(Store.Materialize(FDigest, Destination,
        FScratch + '/project/tmp', Failure)).ToBe(False);
      Expect<Integer>(Ord(Failure)).ToBe(Ord(omfCopyFailed));
    finally
      ObjectStoreBeforeMaterializeCopyTestHook := nil;
    end;

    Store.Admit(FSource, FDigest);
    ObjectStoreBeforeMaterializeCopyTestHook := CorruptMaterializeSource;
    try
      Expect<Boolean>(Store.Materialize(FDigest, Destination,
        FScratch + '/project/tmp', Failure)).ToBe(False);
      Expect<Integer>(Ord(Failure)).ToBe(Ord(omfStagedHashMismatch));
    finally
      ObjectStoreBeforeMaterializeCopyTestHook := nil;
    end;
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestAdmissionHashMismatchPublishesNothing;
var
  Store: TLWPTImmutableObjectStore;
  Refused: Boolean;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Refused := False;
    try
      Store.Admit(FSource, 'sha256:' + StringOfChar('0', 64));
    except
      on E: ELWPTObjectStoreError do Refused := True;
    end;
    Expect<Boolean>(Refused).ToBe(True);
    Expect<Boolean>(DirectoryExists(FStoreRoot + '/sha256')).ToBe(False);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestCorruptObjectIsQuarantinedAndMisses;
var
  Store: TLWPTImmutableObjectStore;
  ObjectPath, HitPath: string;
  SR: TSearchRec;
  Quarantined: Boolean;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    ObjectPath := Store.Admit(FSource, FDigest);
    WriteBytes(ObjectPath, 'corrupt');
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(False);
    Expect<Boolean>(FileExists(ObjectPath)).ToBe(False);
    Quarantined := False;
    if FindFirst(FStoreRoot + '/quarantine/*', faAnyFile, SR) = 0 then
    try
      repeat
        Quarantined := Quarantined or ((SR.Name <> '.') and (SR.Name <> '..'));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Expect<Boolean>(Quarantined).ToBe(True);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.
  TestConcurrentValidReplacementIsRestoredAfterQuarantine;
var
  Store: TLWPTImmutableObjectStore;
  ObjectPath, HitPath: string;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    ObjectPath := Store.Admit(FSource, FDigest);
    WriteBytes(ObjectPath, 'corrupt');
    ReplacementSource := FSource;
    ObjectStoreBeforeQuarantineTestHook := @PublishValidReplacement;
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(True);
    Expect<string>(HitPath).ToBe(ObjectPath);
    Expect<string>('sha256:' + SHA256File(ObjectPath)).ToBe(FDigest);
  finally
    ObjectStoreBeforeQuarantineTestHook := nil;
    ReplacementSource := '';
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestInterruptedTemporaryObjectIsNeverVisible;
var
  Store: TLWPTImmutableObjectStore;
  HitPath: string;
begin
  WriteBytes(FStoreRoot + '/tmp/interrupted.tmp', ReadBytes(FSource));
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(False);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.
  TestAfterPublicationFailureRollsBackAndRecovers;
var
  Store: TLWPTImmutableObjectStore;
  ObjectPath, HitPath: string;
  Raised: Boolean;
begin
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    ObjectPath := Store.ObjectPath(FDigest);
    Raised := False;
    ObjectStoreAfterPublicationTestHook := FailAfterPublication;
    try
      try
        Store.Admit(FSource, FDigest);
      except
        on E: Exception do
          Raised := Pos('intentional after-publication failure',
            E.Message) > 0;
      end;
    finally
      ObjectStoreAfterPublicationTestHook := nil;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Boolean>(FileExists(ObjectPath)).ToBe(False);
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(False);
    Expect<string>(Store.Admit(FSource, FDigest)).ToBe(ObjectPath);
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(True);
    Expect<string>(HitPath).ToBe(ObjectPath);
    Expect<string>('sha256:' + SHA256File(HitPath)).ToBe(FDigest);
  finally
    ObjectStoreAfterPublicationTestHook := nil;
    Store.Free;
  end;
end;

procedure TObjectStoreContract.
  RunContentionIteration(const AIteration: Integer);
var
  Store: TLWPTImmutableObjectStore;
  First, Second: TProcess;
  FirstFinished, SecondFinished: Boolean;
  FirstResult, SecondResult: TAdmitterResult;
  FirstReady, SecondReady, ReleasePath, HitPath: string;
begin
  ResetScratch;
  FirstReady := FScratch + '/first-ready';
  SecondReady := FScratch + '/second-ready';
  ReleasePath := FScratch + '/release-admitters';
  First := nil;
  Second := nil;
  FirstFinished := False;
  SecondFinished := False;
  try
    First := StartAdmitter(FirstReady, ReleasePath);
    Second := StartAdmitter(SecondReady, ReleasePath);
    Expect<Boolean>(WaitForSignal(FirstReady)).ToBe(True);
    Expect<Boolean>(WaitForSignal(SecondReady)).ToBe(True);
    WriteSignal(ReleasePath);
    FirstResult := FinishAdmitter(First, FirstReady);
    FirstFinished := True;
    SecondResult := FinishAdmitter(Second, SecondReady);
    SecondFinished := True;
  finally
    if not FileExists(ReleasePath) then WriteSignal(ReleasePath);
    if First <> nil then
    begin
      if not FirstFinished then
        FirstResult := FinishAdmitter(First, FirstReady);
      DumpAdmitterFailure('iteration ' + IntToStr(AIteration) + ' first',
        FirstResult);
      First.Free;
    end;
    if Second <> nil then
    begin
      if not SecondFinished then
        SecondResult := FinishAdmitter(Second, SecondReady);
      DumpAdmitterFailure('iteration ' + IntToStr(AIteration) + ' second',
        SecondResult);
      Second.Free;
    end;
  end;
  Expect<Boolean>(FirstResult.TimedOut).ToBe(False);
  Expect<Boolean>(SecondResult.TimedOut).ToBe(False);
  Expect<Integer>(FirstResult.ExitStatus).ToBe(0);
  Expect<Integer>(SecondResult.ExitStatus).ToBe(0);
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(True);
    Expect<string>(ReadBytes(HitPath)).ToBe(ReadBytes(FSource));
    Expect<string>('sha256:' + SHA256File(HitPath)).ToBe(FDigest);
  finally
    Store.Free;
  end;
end;

procedure TObjectStoreContract.TestAdmitterFailurePreservesDiagnostics;
var
  Admitter: TProcess;
  AdmitterFinished: Boolean;
  AdmitterResult: TAdmitterResult;
  DiagnosticMatches: Boolean;
  Diagnostic, ExpectedPhases, ExpectedStderrPrefix, ExpectedStdout,
    ReadyPath, ReleasePath: string;
begin
  ReadyPath := FScratch + '/diagnostic-ready';
  ReleasePath := FScratch + '/diagnostic-release';
  Admitter := StartAdmitter(ReadyPath, ReleasePath,
    DIAGNOSTIC_ADMIT_CHILD_SWITCH);
  AdmitterFinished := False;
  try
    Expect<Boolean>(WaitForSignal(ReadyPath)).ToBe(True);
    WriteSignal(ReleasePath);
    AdmitterResult := FinishAdmitter(Admitter, ReadyPath);
    AdmitterFinished := True;
  finally
    if not FileExists(ReleasePath) then WriteSignal(ReleasePath);
    if not AdmitterFinished then
      AdmitterResult := FinishAdmitter(Admitter, ReadyPath);
    Admitter.Free;
  end;
  Diagnostic := AdmitterDiagnostic('intentional failure', AdmitterResult);
  ExpectedStdout := StringOfChar('o', DIAGNOSTIC_STREAM_BYTES)
    + LineEnding + STDOUT_TAIL_MARKER + LineEnding;
  ExpectedStderrPrefix := StringOfChar('e', DIAGNOSTIC_STREAM_BYTES)
    + LineEnding + STDERR_TAIL_MARKER + LineEnding;
  ExpectedPhases := '01-child-started,02-store-created,03-ready-signaled,'
    + '04-release-observed,05-admission-started,06-object-staged,'
    + '09-publication-started';
  DiagnosticMatches := (AdmitterResult.ExitStatus = 217)
    and not AdmitterResult.TimedOut
    and (Pos('exit-status=217', Diagnostic) > 0)
    and (AdmitterResult.Phases = ExpectedPhases)
    and (AdmitterResult.Stdout = ExpectedStdout)
    and (Pos(ExpectedStderrPrefix, AdmitterResult.Stderr) = 1)
    and (Pos(ExpectedStdout, Diagnostic) > 0)
    and (Pos(ExpectedStderrPrefix, Diagnostic) > 0)
    and (Pos('intentional object-store child failure',
      AdmitterResult.Stderr) > 0);
  if not DiagnosticMatches then WriteLn(Diagnostic);
  Expect<Integer>(AdmitterResult.ExitStatus).ToBe(217);
  Expect<Boolean>(AdmitterResult.TimedOut).ToBe(False);
  Expect<Boolean>(Pos('exit-status=217', Diagnostic) > 0).ToBe(True);
  Expect<string>(AdmitterResult.Phases).ToBe(ExpectedPhases);
  Expect<Boolean>(Pos('phases=' + ExpectedPhases, Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(AdmitterResult.Stdout = ExpectedStdout).ToBe(True);
  Expect<Boolean>(Pos(ExpectedStderrPrefix, AdmitterResult.Stderr) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(ExpectedStdout, Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos(ExpectedStderrPrefix, Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('intentional object-store child failure',
    AdmitterResult.Stderr) > 0).ToBe(True);
end;

procedure TObjectStoreContract.
  TestConcurrentSameKeyAdmissionPublishesOneCompleteObject;
var
  Iteration: Integer;
begin
  for Iteration := 1 to CONTENTION_ITERATIONS do
    RunContentionIteration(Iteration);
end;

procedure TObjectStoreContract.TestCacheRootOverrideIsAbsoluteAndNormalized;
var
  Resolved: string;
begin
  Resolved := ResolveCacheRootFromValues(FScratch + '/configured/../cache',
    '/unused-home', '/unused-xdg', '/unused-local');
  Expect<string>(Resolved).ToBe(ExpandFileName(FScratch + '/cache'));
end;

procedure TObjectStoreContract.TestPlatformDefaultUsesPerUserCacheLocation;
var
  Resolved: string;
begin
  Resolved := ResolveCacheRootFromValues('', '/users/test',
    '/var/cache/test', 'C:\Users\test\AppData\Local');
  {$IFDEF MSWINDOWS}
  Expect<Boolean>(Pos(LowerCase('AppData\Local\lwpt\cache'),
    LowerCase(NativePath(Resolved))) > 0).ToBe(True);
  {$ELSE}
  {$IFDEF DARWIN}
  Expect<string>(Resolved).ToBe('/users/test/Library/Caches/lwpt');
  {$ELSE}
  Expect<string>(Resolved).ToBe('/var/cache/test/lwpt');
  Expect<string>(ResolveCacheRootFromValues('', '/users/test',
    'relative-cache', '')).ToBe('/users/test/.cache/lwpt');
  {$ENDIF}
  {$ENDIF}
end;

procedure TObjectStoreContract.SetupTests;
begin
  Test('digest addresses are canonical and sharded',
    TestDigestAddressIsCanonicalAndSharded);
  Test('invalid digests are refused', TestInvalidDigestIsRefused);
  Test('admission, verified lookup, and materialization preserve bytes',
    TestAdmitLookupAndMaterialize);
  Test('materialization reports the exact failing object-store stage',
    TestMaterializeReportsExactFailureStage);
  {$IFDEF UNIX}
  Test('materialization protects its staged handle from child inheritance',
    TestMaterializeProtectsStageFromChildInheritance);
  {$ENDIF}
  Test('admission refuses a mismatched digest before publication',
    TestAdmissionHashMismatchPublishesNothing);
  Test('corrupt objects are quarantined and become misses',
    TestCorruptObjectIsQuarantinedAndMisses);
  Test('a valid replacement moved by stale quarantine is restored',
    TestConcurrentValidReplacementIsRestoredAfterQuarantine);
  Test('interrupted temporary objects are never visible',
    TestInterruptedTemporaryObjectIsNeverVisible);
  Test('after-publication failures roll back and allow recovery',
    TestAfterPublicationFailureRollsBackAndRecovers);
  Test('admitter failures preserve status, streams, and exact phases',
    TestAdmitterFailurePreservesDiagnostics);
  Test('concurrent same-key producers publish one complete object',
    TestConcurrentSameKeyAdmissionPublishesOneCompleteObject);
  Test('repair preserves a cross-process admission paused after staging',
    TestRepairPreservesActiveCrossProcessAdmission);
  Test('cache-root override is absolute and normalized',
    TestCacheRootOverrideIsAbsoluteAndNormalized);
  Test('platform default uses the per-user cache location',
    TestPlatformDefaultUsesPerUserCacheLocation);
end;

begin
  if RunChildMode then Halt(0);
  TestRunnerProgram.AddSuite(TObjectStoreContract.Create(
    PROJECT_NAME + '.ObjectStore: immutable SHA-256 objects'));
  TestRunnerProgram.Run;
end.
