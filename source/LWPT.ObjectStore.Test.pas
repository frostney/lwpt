{ Cross-platform contract tests for per-user root addressing and the generic
  immutable object store. The same executable also acts as a child producer
  so same-key publication is exercised across processes on every CI target. }
program LWPT.ObjectStore.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.ObjectStore,
  TestingPascalLibrary,
  Tests.Scratch;

const
  ADMIT_CHILD_SWITCH = '--object-store-admit-child';
  GUARDED_ADMIT_CHILD_SWITCH = '--object-store-guarded-admit-child';
  START_BARRIER_TIMEOUT_MS = 10000;
  ADMIT_CHILD_TIMEOUT_MS = 5000;
  ADMIT_CHILD_TERMINATION_TIMEOUT_MS = 2000;

var
  ReplacementSource: string;
  StageReadyPath: string;
  StageReleasePath: string;

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
      const AGuarded: Boolean = False): TProcess;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestDigestAddressIsCanonicalAndSharded;
    procedure TestInvalidDigestIsRefused;
    procedure TestAdmitLookupAndMaterialize;
    procedure TestAdmissionHashMismatchPublishesNothing;
    procedure TestCorruptObjectIsQuarantinedAndMisses;
    procedure TestConcurrentValidReplacementIsRestoredAfterQuarantine;
    procedure TestInterruptedTemporaryObjectIsNeverVisible;
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

procedure PauseAfterStage(const APath: string);
begin
  WriteSignal(StageReadyPath);
  if not WaitForSignal(StageReleasePath) then
    raise Exception.CreateFmt(
      'timed out waiting to release staged object %s', [APath]);
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

procedure ReapAdmitter(const AProcess: TProcess);
begin
  if AProcess.WaitOnExit(ADMIT_CHILD_TERMINATION_TIMEOUT_MS)
     or not AProcess.Running then
  begin
    AProcess.WaitOnExit;
    Exit;
  end;
  raise Exception.Create('object-store admitter did not terminate');
end;

procedure StopAdmitter(const AProcess: TProcess);
begin
  if AProcess = nil then Exit;
  if AProcess.Running then AProcess.Terminate(1);
  ReapAdmitter(AProcess);
end;

procedure WaitForAdmitter(const AProcess: TProcess);
begin
  if AProcess.WaitOnExit(ADMIT_CHILD_TIMEOUT_MS)
     or not AProcess.Running then
  begin
    AProcess.WaitOnExit;
    Exit;
  end;
  AProcess.Terminate(1);
  ReapAdmitter(AProcess);
  raise Exception.CreateFmt('object-store admitter exceeded %d ms',
    [ADMIT_CHILD_TIMEOUT_MS]);
end;

function RunChildMode: Boolean;
var
  Store: TLWPTImmutableObjectStore;
begin
  Result := False;
  if (ParamCount <> 6) or ((ParamStr(1) <> ADMIT_CHILD_SWITCH)
     and (ParamStr(1) <> GUARDED_ADMIT_CHILD_SWITCH)) then Exit;
  Store := TLWPTImmutableObjectStore.Create(ParamStr(2),
    ExtractFileDir(ParamStr(2)), DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    if ParamStr(1) = GUARDED_ADMIT_CHILD_SWITCH then
    begin
      StageReadyPath := ParamStr(5);
      StageReleasePath := ParamStr(6);
      ObjectStoreAfterStageTestHook := PauseAfterStage;
    end
    else
    begin
      WriteSignal(ParamStr(5));
      if not WaitForSignal(ParamStr(6)) then
        raise Exception.Create(
          'timed out waiting for object-store start barrier');
    end;
    Store.Admit(ParamStr(3), ParamStr(4));
  finally
    ObjectStoreAfterStageTestHook := nil;
    Store.Free;
  end;
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
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
  FStoreRoot := FScratch + '/cache/dependency-archives';
  FSource := FScratch + '/source/archive.tar.gz';
  WriteBytes(FSource, 'immutable archive bytes'#0'with binary tail');
  FDigest := 'sha256:' + SHA256File(FSource);
end;

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
  AReleasePath: string; const AGuarded: Boolean): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ParamStr(0);
  if AGuarded then Result.Parameters.Add(GUARDED_ADMIT_CHILD_SWITCH)
  else Result.Parameters.Add(ADMIT_CHILD_SWITCH);
  Result.Parameters.Add(FStoreRoot);
  Result.Parameters.Add(FSource);
  Result.Parameters.Add(FDigest);
  Result.Parameters.Add(AReadyPath);
  Result.Parameters.Add(AReleasePath);
  Result.Options := [poNoConsole];
  Result.Execute;
end;

procedure TObjectStoreContract.TestRepairPreservesActiveCrossProcessAdmission;
var
  Admitter: TProcess;
  ReadyPath, ReleasePath: string;
  Report: TLWPTCacheRepairReport;
  Store: TLWPTImmutableObjectStore;
begin
  ReadyPath := FScratch + '/staged-ready';
  ReleasePath := FScratch + '/release-staged';
  Admitter := StartAdmitter(ReadyPath, ReleasePath, True);
  try
    Expect<Boolean>(WaitForSignal(ReadyPath)).ToBe(True);
    Report := RepairSharedCache(FScratch + '/cache');
    Expect<Boolean>(Report.LiveObjectsPreserved >= 1).ToBe(True);
    WriteSignal(ReleasePath);
    WaitForAdmitter(Admitter);
    Expect<Integer>(Admitter.ExitStatus).ToBe(0);
  finally
    if not FileExists(ReleasePath) then WriteSignal(ReleasePath);
    StopAdmitter(Admitter);
    Admitter.Free;
  end;
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
  TestConcurrentSameKeyAdmissionPublishesOneCompleteObject;
var
  Store: TLWPTImmutableObjectStore;
  First, Second: TProcess;
  FirstReady, SecondReady, ReleasePath, HitPath: string;
begin
  FirstReady := FScratch + '/first-ready';
  SecondReady := FScratch + '/second-ready';
  ReleasePath := FScratch + '/release-admitters';
  First := nil;
  Second := nil;
  try
    First := StartAdmitter(FirstReady, ReleasePath);
    Second := StartAdmitter(SecondReady, ReleasePath);
    Expect<Boolean>(WaitForSignal(FirstReady)).ToBe(True);
    Expect<Boolean>(WaitForSignal(SecondReady)).ToBe(True);
    WriteSignal(ReleasePath);
    WaitForAdmitter(First);
    WaitForAdmitter(Second);
    Expect<Integer>(First.ExitStatus).ToBe(0);
    Expect<Integer>(Second.ExitStatus).ToBe(0);
  finally
    if not FileExists(ReleasePath) then WriteSignal(ReleasePath);
    if First <> nil then
    begin
      StopAdmitter(First);
      First.Free;
    end;
    if Second <> nil then
    begin
      StopAdmitter(Second);
      Second.Free;
    end;
  end;
  Store := TLWPTImmutableObjectStore.Create(FStoreRoot,
    FScratch + '/cache', DEPENDENCY_ARCHIVE_NAMESPACE);
  try
    Expect<Boolean>(Store.Lookup(FDigest, HitPath)).ToBe(True);
    Expect<string>(ReadBytes(HitPath)).ToBe(ReadBytes(FSource));
  finally
    Store.Free;
  end;
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
  Test('admission refuses a mismatched digest before publication',
    TestAdmissionHashMismatchPublishesNothing);
  Test('corrupt objects are quarantined and become misses',
    TestCorruptObjectIsQuarantinedAndMisses);
  Test('a valid replacement moved by stale quarantine is restored',
    TestConcurrentValidReplacementIsRestoredAfterQuarantine);
  Test('interrupted temporary objects are never visible',
    TestInterruptedTemporaryObjectIsNeverVisible);
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
