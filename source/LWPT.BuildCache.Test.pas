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

  LWPT.BuildCache,
  LWPT.Core,
  TestingPascalLibrary,
  Tests.Scratch;

const
  STORE_CHILD_SWITCH = '--build-cache-store-child';
  TEST_FINGERPRINT =
    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  TEST_ARTIFACT_KIND = 'executable';

type
  TBuildCacheContract = class(TTestSuite)
  private
    FScratch: string;
    FCacheRoot: string;
    FArtifact: string;
    procedure ResetScratch;
    procedure WriteBytes(const APath, AText: string);
    function ReadBytes(const APath: string): string;
    function ObjectPath(const ADigest: string): string;
    function StartStoreChild(const AArtifact: string): TProcess;
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestStoreAndMaterializePreserveVerifiedResult;
    procedure TestMissingResultReportsDeterministicReason;
    procedure TestInvalidFingerprintIsRefused;
    procedure TestCorruptArtifactIsRejected;
    procedure TestConcurrentStoresPublishOneMatchingCompleteResult;
  end;

function RunChildMode: Boolean;
var
  Cache: TLWPTBuildCache;
begin
  Result := False;
  if (ParamCount <> 4) or (ParamStr(1) <> STORE_CHILD_SWITCH) then Exit;
  Cache := TLWPTBuildCache.Create(ParamStr(2));
  try
    Cache.Store(TEST_FINGERPRINT, ParamStr(3), ParamStr(4));
  finally
    Cache.Free;
  end;
  Result := True;
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

procedure TBuildCacheContract.ResetScratch;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
  FCacheRoot := FScratch + '/cache';
  FArtifact := FScratch + '/input/app';
  WriteBytes(FArtifact, 'compiled bytes'#0'with binary tail');
end;

procedure TBuildCacheContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('build-cache');
end;

procedure TBuildCacheContract.BeforeEach;
begin
  ResetScratch;
end;

procedure TBuildCacheContract.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

function TBuildCacheContract.StartStoreChild(
  const AArtifact: string): TProcess;
begin
  Result := TProcess.Create(nil);
  Result.Executable := ParamStr(0);
  Result.Parameters.Add(STORE_CHILD_SWITCH);
  Result.Parameters.Add(FCacheRoot);
  Result.Parameters.Add(AArtifact);
  Result.Parameters.Add(TEST_ARTIFACT_KIND);
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
    Expect<string>(Reason).ToBe('artifact-missing');
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

procedure TBuildCacheContract.SetupTests;
begin
  Test('store and materialize preserve the verified result',
    TestStoreAndMaterializePreserveVerifiedResult);
  Test('missing results report a deterministic reason',
    TestMissingResultReportsDeterministicReason);
  Test('invalid fingerprints are refused', TestInvalidFingerprintIsRefused);
  Test('corrupt artifacts are rejected', TestCorruptArtifactIsRejected);
  Test('concurrent stores publish one matching complete result',
    TestConcurrentStoresPublishOneMatchingCompleteResult);
end;

begin
  if RunChildMode then Halt(0);
  TestRunnerProgram.AddSuite(TBuildCacheContract.Create(
    'build cache: verified result storage'));
  TestRunnerProgram.Run;
end.
