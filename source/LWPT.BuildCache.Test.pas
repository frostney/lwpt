{ LWPT.BuildCache.Test — verified build-result manifests and concurrent
  same-fingerprint publication over the shared immutable object store. }
program LWPT.BuildCache.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  LWPT.BuildCache,
  LWPT.CacheLifecycle,
  LWPT.Core,
  LWPT.ObjectStore,
  TestingPascalLibrary,
  Tests.Scratch;

const
  STORE_CHILD_SWITCH = '--build-cache-store-child';
  MATERIALIZE_CHILD_SWITCH = '--build-cache-materialize-child';
  CHILD_TIMEOUT_MS = 10000;
  TEST_FINGERPRINT =
    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  SECOND_TEST_FINGERPRINT =
    'sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  TEST_ARTIFACT_KIND = 'executable';

type
  TBuildCacheContract = class(TTestSuite)
  private
    FScratch: string;
    FCacheRoot: string;
    FArtifact: string;
    FOriginalBudget: string;
    procedure ResetScratch;
    procedure WriteBytes(const APath, AText: string);
    function ReadBytes(const APath: string): string;
    function CacheBytes(const APath: string): Int64;
    function ObjectPath(const ADigest: string): string;
    function ReferencePath(const AFingerprint: string): string;
    function StartStoreChild(const AArtifact: string;
      const ABudget: string = ''): TProcess;
    function StartMaterializeChild(const AArtifactDigest,
      ADestination, AReadyPath, AReleasePath: string;
      const AAfterCopy: Boolean = False;
      const APauseBeforeInvalidation: Boolean = False;
      const AExpectedReason: string = 'no-result'): TProcess;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestStoreAndMaterializePreserveVerifiedResult;
    procedure TestArtifactKindRoundTripsTomlEscapes;
    procedure TestMaterializeAppliesZeroUnixMode;
    procedure TestMissingResultReportsDeterministicReason;
    procedure TestInvalidFingerprintIsRefused;
    procedure TestCorruptArtifactIsRejected;
    procedure TestMixedCaseReferenceIsInvalidated;
    procedure TestConcurrentStoresPublishOneMatchingCompleteResult;
    procedure TestConcurrentStoreInvalidatesBeforeLiveMaterializeCompletes;
    procedure TestReaderLosingEvictionRaceReturnsNoResult;
    procedure TestConcurrentRepublishSurvivesStaleInvalidation;
    procedure TestBudgetRefusalLeavesNoPartialResult;
    procedure TestLowBudgetArtifactEvictionInvalidatesResult;
  end;

{$IFDEF UNIX}
function CSetEnvironmentVariable(AName, AValue: PAnsiChar;
  AOverwrite: LongInt): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'setenv';
  {$ELSE}
  external name 'setenv';
  {$ENDIF}
function CUnsetEnvironmentVariable(AName: PAnsiChar): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'unsetenv';
  {$ELSE}
  external name 'unsetenv';
  {$ENDIF}
{$ENDIF}

var
  MaterializeArtifactDigest: string;
  MaterializeReadyPath: string;
  MaterializeReleasePath: string;

procedure WriteSignal(const APath: string);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  Stream.Free;
end;

procedure WriteChildText(const APath, AText: string);
var
  Raw: RawByteString;
  Stream: TFileStream;
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

function WaitForSignal(const APath: string): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    if FileExists(APath) then Exit(True);
    Sleep(5);
  until GetTickCount64 - Started >= CHILD_TIMEOUT_MS;
  Result := False;
end;

procedure PauseMaterializeAtDigest(const ADigest, APath: string);
begin
  if ADigest <> MaterializeArtifactDigest then Exit;
  WriteSignal(MaterializeReadyPath);
  if not WaitForSignal(MaterializeReleasePath) then
    raise Exception.Create('timed out waiting to resume cache materialize');
end;

procedure PauseBeforeReferenceInvalidation(const AFingerprint,
  AManifestDigest: string);
begin
  if AFingerprint <> TEST_FINGERPRINT then Exit;
  WriteSignal(MaterializeReadyPath);
  if not WaitForSignal(MaterializeReleasePath) then
    raise Exception.Create('timed out waiting to invalidate cache reference');
end;

procedure SetBudgetEnvironment(const AValue: string);
{$IFDEF UNIX}
var
  Name, Value: AnsiString;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Name, Value: UnicodeString;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Name := AnsiString(CACHE_MAX_BYTES_ENV);
  Value := AnsiString(AValue);
  if AValue = '' then CUnsetEnvironmentVariable(PAnsiChar(Name))
  else CSetEnvironmentVariable(PAnsiChar(Name), PAnsiChar(Value), 1);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Name := UnicodeString(CACHE_MAX_BYTES_ENV);
  Value := UnicodeString(AValue);
  if AValue = '' then Windows.SetEnvironmentVariableW(PWideChar(Name), nil)
  else Windows.SetEnvironmentVariableW(PWideChar(Name), PWideChar(Value));
  {$ENDIF}
end;

function TBuildCacheContract.CacheBytes(const APath: string): Int64;
var
  Child: string;
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile,
       Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Child := IncludeTrailingPathDelimiter(APath) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
        Inc(Result, CacheBytes(Child))
      else
        Inc(Result, Search.Size);
    until FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function RunChildMode(out AExitCode: Integer): Boolean;
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Reason: string;
  Stored: Boolean;
begin
  Result := False;
  AExitCode := 0;
  if (ParamStr(1) = MATERIALIZE_CHILD_SWITCH) and (ParamCount = 10) then
  begin
    MaterializeArtifactDigest := ParamStr(4);
    MaterializeReadyPath := ParamStr(6);
    MaterializeReleasePath := ParamStr(7);
    if ParamStr(8) = 'after-copy' then
      ObjectStoreAfterMaterializeCopyTestHook := PauseMaterializeAtDigest
    else
      ObjectStoreBeforeMaterializeCopyTestHook := PauseMaterializeAtDigest;
    if ParamStr(9) = 'before-invalidation' then
      BuildCacheBeforeReferenceInvalidationTestHook :=
        PauseBeforeReferenceInvalidation;
    Cache := TLWPTBuildCache.Create(ParamStr(2));
    try
      if not Cache.Materialize(ParamStr(3), ParamStr(5),
           ExtractFileDir(ParamStr(5)) + '/tmp', Cached, Reason) then
      begin
        WriteChildText(ParamStr(5) + '.reason', Reason);
        if Reason <> ParamStr(10) then AExitCode := 4;
      end;
    finally
      ObjectStoreAfterMaterializeCopyTestHook := nil;
      ObjectStoreBeforeMaterializeCopyTestHook := nil;
      BuildCacheBeforeReferenceInvalidationTestHook := nil;
      Cache.Free;
    end;
    Exit(True);
  end;
  if (ParamCount <> 4) or (ParamStr(1) <> STORE_CHILD_SWITCH) then Exit;
  Cache := TLWPTBuildCache.Create(ParamStr(2));
  try
    Stored := Cache.Store(TEST_FINGERPRINT, ParamStr(3), ParamStr(4));
  finally
    Cache.Free;
  end;
  if not Stored then AExitCode := 3;
  Result := True;
end;

function TBuildCacheContract.StartMaterializeChild(
  const AArtifactDigest, ADestination, AReadyPath,
  AReleasePath: string; const AAfterCopy,
  APauseBeforeInvalidation: Boolean; const AExpectedReason: string): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ParamStr(0);
  Result.Parameters.Add(MATERIALIZE_CHILD_SWITCH);
  Result.Parameters.Add(FCacheRoot);
  Result.Parameters.Add(TEST_FINGERPRINT);
  Result.Parameters.Add(AArtifactDigest);
  Result.Parameters.Add(ADestination);
  Result.Parameters.Add(AReadyPath);
  Result.Parameters.Add(AReleasePath);
  if AAfterCopy then Result.Parameters.Add('after-copy')
  else Result.Parameters.Add('before-copy');
  if APauseBeforeInvalidation then
    Result.Parameters.Add('before-invalidation')
  else
    Result.Parameters.Add('none');
  Result.Parameters.Add(AExpectedReason);
  Result.Options := [poNoConsole];
  Result.Execute;
end;

procedure TBuildCacheContract.WriteBytes(const APath, AText: string);
var
  Raw: RawByteString;
  Stream: TFileStream;
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

function TBuildCacheContract.ReadBytes(const APath: string): string;
var
  Raw: RawByteString;
  Stream: TFileStream;
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

function TBuildCacheContract.ObjectPath(const ADigest: string): string;
var
  Hex: string;
begin
  Hex := Copy(ADigest, 8, MaxInt);
  Result := BuildResultCacheRoot(FCacheRoot) + '/objects/sha256/'
    + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
end;

function TBuildCacheContract.ReferencePath(
  const AFingerprint: string): string;
var
  Hex: string;
begin
  Hex := Copy(AFingerprint, 8, MaxInt);
  Result := BuildResultCacheRoot(FCacheRoot) + '/refs/sha256/'
    + Copy(Hex, 1, 2) + '/' + Copy(Hex, 3, MaxInt);
end;

procedure TBuildCacheContract.
  TestLowBudgetArtifactEvictionInvalidatesResult;
var
  ArtifactA, ArtifactB, ArtifactDigestA, Destination, Reason: string;
  Budget: Int64;
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Report: TLWPTCacheRepairReport;
begin
  ArtifactA := FScratch + '/distinct/a';
  ArtifactB := FScratch + '/distinct/b';
  WriteBytes(ArtifactA, StringOfChar('a', 4096));
  WriteBytes(ArtifactB, StringOfChar('b', 4096));
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, ArtifactA,
      TEST_ARTIFACT_KIND)).ToBe(True);
    Expect<Boolean>(Cache.Store(SECOND_TEST_FINGERPRINT, ArtifactB,
      TEST_ARTIFACT_KIND)).ToBe(True);
    ArtifactDigestA := 'sha256:' + SHA256File(ArtifactA);
    Budget := CacheBytes(FCacheRoot) - 4096;
    SetBudgetEnvironment(IntToStr(Budget));
    Report := RepairSharedCache(FCacheRoot);
    Expect<Boolean>(Report.BytesAfter <= Budget).ToBe(True);
    Expect<Boolean>(FileExists(ObjectPath(ArtifactDigestA))).ToBe(False);
    Expect<Boolean>(FileExists(ReferencePath(TEST_FINGERPRINT))).ToBe(False);
    Destination := FScratch + '/evicted/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/evicted/tmp', Cached, Reason)).ToBe(False);
    Expect<string>(Reason).ToBe('no-result');
    Destination := FScratch + '/retained/bin/app';
    Expect<Boolean>(Cache.Materialize(SECOND_TEST_FINGERPRINT, Destination,
      FScratch + '/retained/tmp', Cached, Reason)).ToBe(True);
    Expect<string>(ReadBytes(Destination)).ToBe(ReadBytes(ArtifactB));
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.ResetScratch;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
  FCacheRoot := FScratch + '/cache';
  FArtifact := FScratch + '/input/app';
  WriteBytes(FArtifact, 'compiled bytes'#0'with binary tail');
  SetBudgetEnvironment('');
end;

procedure TBuildCacheContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('build-cache');
  FOriginalBudget := SysUtils.GetEnvironmentVariable(CACHE_MAX_BYTES_ENV);
end;

procedure TBuildCacheContract.BeforeEach;
begin
  ResetScratch;
end;

procedure TBuildCacheContract.AfterAll;
begin
  SetBudgetEnvironment(FOriginalBudget);
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TBuildCacheContract.TestBudgetRefusalLeavesNoPartialResult;
var
  ArtifactDigest: string;
  Child: TProcess;
begin
  ArtifactDigest := 'sha256:' + SHA256File(FArtifact);
  Child := StartStoreChild(FArtifact,
    IntToStr(Length(ReadBytes(FArtifact))));
  try
    Child.WaitOnExit;
    Expect<Integer>(Child.ExitStatus).ToBe(3);
    Expect<Boolean>(FileExists(ObjectPath(ArtifactDigest))).ToBe(False);
    Expect<Boolean>(FileExists(FCacheRoot + '/build-results/refs/sha256/'
      + Copy(TEST_FINGERPRINT, 8, 2) + '/'
      + Copy(TEST_FINGERPRINT, 10, MaxInt))).ToBe(False);
  finally
    Child.Free;
  end;
end;

function TBuildCacheContract.StartStoreChild(
  const AArtifact: string; const ABudget: string): TProcess;
var
  EnvironmentIndex: Integer;
  Prefix: string;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ParamStr(0);
  Result.Parameters.Add(STORE_CHILD_SWITCH);
  Result.Parameters.Add(FCacheRoot);
  Result.Parameters.Add(AArtifact);
  Result.Parameters.Add(TEST_ARTIFACT_KIND);
  if ABudget <> '' then
  begin
    AppendProcessEnvironment(Result.Environment);
    Prefix := CACHE_MAX_BYTES_ENV + '=';
    for EnvironmentIndex := Result.Environment.Count - 1 downto 0 do
      if Copy(Result.Environment[EnvironmentIndex], 1, Length(Prefix)) = Prefix
         then
        Result.Environment.Delete(EnvironmentIndex);
    Result.Environment.Add(Prefix + ABudget);
  end;
  Result.Options := [poNoConsole];
  Result.Execute;
end;

procedure TBuildCacheContract.TestStoreAndMaterializePreserveVerifiedResult;
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Destination, Reason: string;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Cache.Store(TEST_FINGERPRINT, FArtifact, TEST_ARTIFACT_KIND);
    Destination := FScratch + '/session/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/session/tmp', Cached, Reason)).ToBe(True);
    Expect<string>(Reason).ToBe('hit');
    Expect<string>(Cached.Fingerprint).ToBe(TEST_FINGERPRINT);
    Expect<string>(Cached.ArtifactKind).ToBe(TEST_ARTIFACT_KIND);
    Expect<string>(Cached.ArtifactDigest).ToBe(
      'sha256:' + SHA256File(FArtifact));
    Expect<string>(ReadBytes(Destination)).ToBe(ReadBytes(FArtifact));
    {$IFDEF UNIX}
    Expect<Integer>(BuildArtifactUnixMode(Destination)).ToBe(
      BuildArtifactUnixMode(FArtifact));
    {$ENDIF}
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestArtifactKindRoundTripsTomlEscapes;
const
  EscapedKind = 'exe"cutable\line'#10'next';
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Destination, Reason: string;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, FArtifact,
      EscapedKind)).ToBe(True);
    Destination := FScratch + '/escaped-kind/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/escaped-kind/tmp', Cached, Reason)).ToBe(True);
    Expect<string>(Reason).ToBe('hit');
    Expect<string>(Cached.ArtifactKind).ToBe(EscapedKind);
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestMaterializeAppliesZeroUnixMode;
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Destination, Reason: string;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Cache.Store(TEST_FINGERPRINT, FArtifact, TEST_ARTIFACT_KIND, 0);
    Destination := FScratch + '/session-zero-mode/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/session-zero-mode/tmp', Cached, Reason)).ToBe(True);
    Expect<string>(Reason).ToBe('hit');
    {$IFDEF UNIX}
    Expect<Integer>(BuildArtifactUnixMode(Destination)).ToBe(0);
    {$ELSE}
    Expect<Boolean>(FileExists(Destination)).ToBe(True);
    {$ENDIF}
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestMissingResultReportsDeterministicReason;
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Destination, Reason: string;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Destination := FScratch + '/session/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/session/tmp', Cached, Reason)).ToBe(False);
    Expect<string>(Reason).ToBe('no-result');
    Expect<Boolean>(FileExists(Destination)).ToBe(False);
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestInvalidFingerprintIsRefused;
var
  Cache: TLWPTBuildCache;
  Refused: Boolean;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Refused := False;
    try
      Cache.Store('sha256:not-a-fingerprint', FArtifact,
        TEST_ARTIFACT_KIND);
    except
      on E: ELWPTBuildCacheError do Refused := True;
    end;
    Expect<Boolean>(Refused).ToBe(True);
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestCorruptArtifactIsRejected;
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Destination, Digest, Reason: string;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Cache.Store(TEST_FINGERPRINT, FArtifact, TEST_ARTIFACT_KIND);
    Digest := 'sha256:' + SHA256File(FArtifact);
    WriteBytes(ObjectPath(Digest), 'corrupt');
    Destination := FScratch + '/session/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/session/tmp', Cached, Reason)).ToBe(False);
    Expect<string>(Reason).ToBe('artifact-verification-failed');
    Expect<Boolean>(FileExists(ReferencePath(TEST_FINGERPRINT))).ToBe(False);
    Expect<Boolean>(FileExists(Destination)).ToBe(False);
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestMixedCaseReferenceIsInvalidated;
var
  Destination, ManifestDigest, Reason: string;
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, FArtifact,
      TEST_ARTIFACT_KIND)).ToBe(True);
    ManifestDigest := Trim(ReadBytes(ReferencePath(TEST_FINGERPRINT)));
    WriteBytes(ReferencePath(TEST_FINGERPRINT), UpperCase(ManifestDigest) + #10);
    Destination := FScratch + '/mixed-case/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/mixed-case/tmp', Cached, Reason)).ToBe(False);
    Expect<string>(Reason).ToBe('invalid-reference');
    Expect<Boolean>(FileExists(ReferencePath(TEST_FINGERPRINT))).ToBe(False);
    Expect<Boolean>(FileExists(Destination)).ToBe(False);
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.
  TestConcurrentStoresPublishOneMatchingCompleteResult;
var
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Destination, FirstArtifact, Materialized, Reason, SecondArtifact: string;
  First, Second: TProcess;
begin
  FirstArtifact := FScratch + '/producer-a/app';
  SecondArtifact := FScratch + '/producer-b/app';
  WriteBytes(FirstArtifact, 'complete producer A bytes');
  WriteBytes(SecondArtifact, 'complete producer B bytes');
  First := StartStoreChild(FirstArtifact);
  Second := StartStoreChild(SecondArtifact);
  try
    First.WaitOnExit;
    Second.WaitOnExit;
    Expect<Integer>(First.ExitStatus).ToBe(0);
    Expect<Integer>(Second.ExitStatus).ToBe(0);
  finally
    First.Free;
    Second.Free;
  end;

  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Destination := FScratch + '/session/bin/app';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/session/tmp', Cached, Reason)).ToBe(True);
    Materialized := ReadBytes(Destination);
    Expect<Boolean>((Materialized = ReadBytes(FirstArtifact))
      or (Materialized = ReadBytes(SecondArtifact))).ToBe(True);
    Expect<string>(Cached.ArtifactDigest).ToBe(
      'sha256:' + SHA256File(Destination));
  finally
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.
  TestConcurrentStoreInvalidatesBeforeLiveMaterializeCompletes;
var
  ArtifactA, ArtifactB, ArtifactDigestA, Destination, ReadyPath,
    Reason, ReleasePath: string;
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Child: TProcess;
  FullCacheBytes: Int64;
begin
  ArtifactA := FScratch + '/concurrent/a';
  ArtifactB := FScratch + '/concurrent/b';
  WriteBytes(ArtifactA, StringOfChar('a', 4096));
  WriteBytes(ArtifactB, StringOfChar('b', 4096));
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, ArtifactA,
      TEST_ARTIFACT_KIND)).ToBe(True);
    Expect<Boolean>(Cache.Store(SECOND_TEST_FINGERPRINT, ArtifactB,
      TEST_ARTIFACT_KIND)).ToBe(True);
    FullCacheBytes := CacheBytes(FCacheRoot);
  finally
    Cache.Free;
  end;

  ResetScratch;
  WriteBytes(ArtifactA, StringOfChar('a', 4096));
  WriteBytes(ArtifactB, StringOfChar('b', 4096));
  ArtifactDigestA := 'sha256:' + SHA256File(ArtifactA);
  Destination := FScratch + '/concurrent-reader/bin/app';
  ReadyPath := FScratch + '/concurrent-reader/ready';
  ReleasePath := FScratch + '/concurrent-reader/release';
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  Child := nil;
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, ArtifactA,
      TEST_ARTIFACT_KIND)).ToBe(True);
    Child := StartMaterializeChild(ArtifactDigestA, Destination,
      ReadyPath, ReleasePath);
    Expect<Boolean>(WaitForSignal(ReadyPath)).ToBe(True);
    SetBudgetEnvironment(IntToStr(FullCacheBytes - 1));
    Expect<Boolean>(Cache.Store(SECOND_TEST_FINGERPRINT, ArtifactB,
      TEST_ARTIFACT_KIND)).ToBe(True);
    Expect<Boolean>(FileExists(ReferencePath(TEST_FINGERPRINT))).ToBe(False);
    Expect<Boolean>(FileExists(ObjectPath(ArtifactDigestA))).ToBe(True);
    WriteSignal(ReleasePath);
    Expect<Boolean>(Child.WaitOnExit(CHILD_TIMEOUT_MS)).ToBe(True);
    Expect<Integer>(Child.ExitStatus).ToBe(0);
    Expect<string>(ReadBytes(Destination)).ToBe(ReadBytes(ArtifactA));
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT,
      FScratch + '/concurrent-reader/second',
      FScratch + '/concurrent-reader/tmp-second', Cached,
      Reason)).ToBe(False);
    Expect<string>(Reason).ToBe('no-result');
  finally
    if Assigned(Child) and Child.Running then
    begin
      WriteSignal(ReleasePath);
      if not Child.WaitOnExit(CHILD_TIMEOUT_MS) then
      begin
        Child.Terminate(1);
        Child.WaitOnExit(2000);
      end;
    end;
    Child.Free;
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.TestReaderLosingEvictionRaceReturnsNoResult;
var
  ArtifactA, ArtifactB, Destination, ManifestDigest, ReadyPath,
    ReleasePath: string;
  Cache: TLWPTBuildCache;
  Child: TProcess;
  FullCacheBytes: Int64;
begin
  ArtifactA := FScratch + '/racing-reader/a';
  ArtifactB := FScratch + '/racing-reader/b';
  WriteBytes(ArtifactA, StringOfChar('a', 4096));
  WriteBytes(ArtifactB, StringOfChar('b', 4096));
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, ArtifactA,
      TEST_ARTIFACT_KIND)).ToBe(True);
    Expect<Boolean>(Cache.Store(SECOND_TEST_FINGERPRINT, ArtifactB,
      TEST_ARTIFACT_KIND)).ToBe(True);
    FullCacheBytes := CacheBytes(FCacheRoot);
  finally
    Cache.Free;
  end;

  ResetScratch;
  WriteBytes(ArtifactA, StringOfChar('a', 4096));
  WriteBytes(ArtifactB, StringOfChar('b', 4096));
  Destination := FScratch + '/racing-reader/bin/app';
  ReadyPath := FScratch + '/racing-reader/ready';
  ReleasePath := FScratch + '/racing-reader/release';
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  Child := nil;
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, ArtifactA,
      TEST_ARTIFACT_KIND)).ToBe(True);
    ManifestDigest := Trim(ReadBytes(ReferencePath(TEST_FINGERPRINT)));
    Child := StartMaterializeChild(ManifestDigest, Destination,
      ReadyPath, ReleasePath, True);
    Expect<Boolean>(WaitForSignal(ReadyPath)).ToBe(True);
    SetBudgetEnvironment(IntToStr(FullCacheBytes - 1));
    Expect<Boolean>(Cache.Store(SECOND_TEST_FINGERPRINT, ArtifactB,
      TEST_ARTIFACT_KIND)).ToBe(True);
    Expect<Boolean>(FileExists(ReferencePath(TEST_FINGERPRINT))).ToBe(False);
    WriteSignal(ReleasePath);
    Expect<Boolean>(Child.WaitOnExit(CHILD_TIMEOUT_MS)).ToBe(True);
    Expect<Integer>(Child.ExitStatus).ToBe(0);
    Expect<Boolean>(FileExists(Destination)).ToBe(False);
    Expect<string>(ReadBytes(Destination + '.reason')).ToBe('no-result');
  finally
    if Assigned(Child) and Child.Running then
    begin
      WriteSignal(ReleasePath);
      if not Child.WaitOnExit(CHILD_TIMEOUT_MS) then
      begin
        Child.Terminate(1);
        Child.WaitOnExit(2000);
      end;
    end;
    Child.Free;
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.
  TestConcurrentRepublishSurvivesStaleInvalidation;
var
  ArtifactDigest, Destination, ManifestDigest, ReadyPath, Reason,
    ReleasePath: string;
  Cache: TLWPTBuildCache;
  Cached: TLWPTCachedBuildResult;
  Materializer, StoreChild: TProcess;
begin
  Cache := TLWPTBuildCache.Create(FCacheRoot);
  Materializer := nil;
  StoreChild := nil;
  ReadyPath := FScratch + '/republish/ready';
  ReleasePath := FScratch + '/republish/release';
  Destination := FScratch + '/republish/stale';
  try
    Expect<Boolean>(Cache.Store(TEST_FINGERPRINT, FArtifact,
      TEST_ARTIFACT_KIND)).ToBe(True);
    ManifestDigest := Trim(ReadBytes(ReferencePath(TEST_FINGERPRINT)));
    ArtifactDigest := 'sha256:' + SHA256File(FArtifact);
    Expect<Boolean>(SysUtils.DeleteFile(ObjectPath(ArtifactDigest))).ToBe(True);

    Materializer := StartMaterializeChild(ArtifactDigest, Destination,
      ReadyPath, ReleasePath, False, True, 'artifact-object-missing');
    Expect<Boolean>(WaitForSignal(ReadyPath)).ToBe(True);
    StoreChild := StartStoreChild(FArtifact);
    Expect<Boolean>(StoreChild.WaitOnExit(1000)).ToBe(False);

    WriteSignal(ReleasePath);
    Expect<Boolean>(Materializer.WaitOnExit(CHILD_TIMEOUT_MS)).ToBe(True);
    Expect<Integer>(Materializer.ExitStatus).ToBe(0);
    Expect<string>(ReadBytes(Destination + '.reason')).ToBe(
      'artifact-object-missing');
    Expect<Boolean>(StoreChild.WaitOnExit(CHILD_TIMEOUT_MS)).ToBe(True);
    Expect<Integer>(StoreChild.ExitStatus).ToBe(0);
    Expect<string>(Trim(ReadBytes(ReferencePath(TEST_FINGERPRINT)))).ToBe(
      ManifestDigest);

    Destination := FScratch + '/republish/final';
    Expect<Boolean>(Cache.Materialize(TEST_FINGERPRINT, Destination,
      FScratch + '/republish/tmp-final', Cached, Reason)).ToBe(True);
    Expect<string>(Reason).ToBe('hit');
    Expect<string>(ReadBytes(Destination)).ToBe(ReadBytes(FArtifact));
  finally
    if Assigned(Materializer) and Materializer.Running then
    begin
      WriteSignal(ReleasePath);
      if not Materializer.WaitOnExit(CHILD_TIMEOUT_MS) then
      begin
        Materializer.Terminate(1);
        Materializer.WaitOnExit(2000);
      end;
    end;
    if Assigned(StoreChild) and StoreChild.Running then
    begin
      if not StoreChild.WaitOnExit(CHILD_TIMEOUT_MS) then
      begin
        StoreChild.Terminate(1);
        StoreChild.WaitOnExit(2000);
      end;
    end;
    StoreChild.Free;
    Materializer.Free;
    Cache.Free;
  end;
end;

procedure TBuildCacheContract.SetupTests;
begin
  Test('store and materialize preserve the verified result',
    TestStoreAndMaterializePreserveVerifiedResult);
  Test('artifact kind round-trips TOML escapes',
    TestArtifactKindRoundTripsTomlEscapes);
  Test('materialize applies a recorded zero Unix mode',
    TestMaterializeAppliesZeroUnixMode);
  Test('missing results report a deterministic reason',
    TestMissingResultReportsDeterministicReason);
  Test('invalid fingerprints are refused', TestInvalidFingerprintIsRefused);
  Test('corrupt artifacts are rejected', TestCorruptArtifactIsRejected);
  Test('mixed-case references are invalidated',
    TestMixedCaseReferenceIsInvalidated);
  Test('concurrent stores publish one matching complete result',
    TestConcurrentStoresPublishOneMatchingCompleteResult);
  Test('a concurrent store invalidates before a live materialize completes',
    TestConcurrentStoreInvalidatesBeforeLiveMaterializeCompletes);
  Test('a reader losing the eviction race reports no result',
    TestReaderLosingEvictionRaceReturnsNoResult);
  Test('a concurrent republish survives stale invalidation',
    TestConcurrentRepublishSurvivesStaleInvalidation);
  Test('a budget refusal leaves no partial logical result',
    TestBudgetRefusalLeavesNoPartialResult);
  Test('low-budget artifact eviction invalidates its logical result',
    TestLowBudgetArtifactEvictionInvalidatesResult);
end;

var
  ChildExitCode: Integer;
begin
  if RunChildMode(ChildExitCode) then Halt(ChildExitCode);
  TestRunnerProgram.AddSuite(TBuildCacheContract.Create(
    'build cache: verified result storage'));
  TestRunnerProgram.Run;
end.
