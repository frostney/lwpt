program InstallProducerLease.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.Install,
  LWPT.ObjectStore,
  TestingPascalLibrary,
  Tests.HTTPMockServer,
  Tests.LwptSubprocess,
  Tests.Scratch,
  Tests.TarSynth;

const
  SHARED_COMMIT = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  CRASH_PRODUCER_ENV = PROJECT_NAME
    + '_TEST_CRASH_DEPENDENCY_PRODUCER';
  REQUEST_TIMEOUT = '5000';
  PROCESS_TIMEOUT_MILLISECONDS = 10000;

type
  TInstallProducerLease = class(TTestSuite)
  private
    FOriginalDir, FScratch, FFixtureRoot, FCacheRoot: string;
    FArchiveBytes: TBytes;
    procedure PrepareLockedProjects(const AScenario: string;
      out AFirstRoot, ASecondRoot, AArchiveHash: string);
    function StartInstall(const ARoot: string; const APort: Word;
      const ACrashProducer: Boolean): TProcess;
    function FinishInstall(const AProcess: TProcess;
      out AOutput: string): Integer;
    function WaitForExit(const AProcess: TProcess): Boolean;
    procedure AssertMaterialized(const ARoot, AArchiveHash: string);
  protected
    procedure BeforeAll; override;
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestConcurrentLockedMissFetchesOnce;
    procedure TestCrashedProducerIsTakenOver;
  end;

function BytesAsString(const ABytes: TBytes): string;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then Move(ABytes[0], Result[1], Length(ABytes));
end;

function ReadStream(const AStream: TStream): string;
var
  Buffer: array[0..4095] of Byte;
  Count, Offset: Integer;
begin
  Result := '';
  Offset := 0;
  repeat
    Count := AStream.Read(Buffer, SizeOf(Buffer));
    if Count > 0 then
    begin
      SetLength(Result, Offset + Count);
      Move(Buffer[0], Result[Offset + 1], Count);
      Inc(Offset, Count);
    end;
  until Count <= 0;
end;

procedure WriteRoot(const ARoot: string);
begin
  ForceDirectories(ARoot + '/source');
  WriteTextFile(ARoot + '/source/main.pas',
    'program main;'#10 + '{$mode delphi}{$H+}'#10 + 'begin end.'#10);
  WriteTextFile(ARoot + '/lwpt.toml',
    '[package]'#10 + 'name = "producer-lease-project"'#10
    + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + '[dependencies]'#10
    + 'shared = "fixture/shared@^1.0.0"'#10);
end;

procedure TInstallProducerLease.PrepareLockedProjects(
  const AScenario: string; out AFirstRoot, ASecondRoot,
  AArchiveHash: string);
var
  ArchivePath, SeedRoot, SeedCache: string;
  Entries: TByteArrays;
  Run: TLwptResult;
begin
  SeedRoot := FScratch + '/' + AScenario + '-seed';
  SeedCache := FScratch + '/' + AScenario + '-seed-cache';
  AFirstRoot := FScratch + '/' + AScenario + '-first';
  ASecondRoot := FScratch + '/' + AScenario + '-second';
  WriteRoot(SeedRoot);
  ForceDirectories(FFixtureRoot + '/refs');
  WriteTextFile(FFixtureRoot + '/refs/shared.refs',
    'tag|v1.0.0|' + SHARED_COMMIT + '|'#10);
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry('shared-fixture/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "shared"'#10
      + 'version = "1.0.0"'#10 + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry(
    'shared-fixture/source/shared.pas',
    BytesOf('unit shared;'#10 + 'interface'#10
      + 'implementation'#10 + 'end.'#10));
  ArchivePath := FFixtureRoot + '/archives/shared/'
    + SHARED_COMMIT + '.tar.gz';
  ForceDirectories(ExtractFileDir(ArchivePath));
  FArchiveBytes := Gzip(BuildTar(Entries));
  WriteBytesToFile(ArchivePath, FArchiveBytes);

  Run := RunLwpt(['install'], SeedRoot,
    [PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot,
     CACHE_DIR_ENV + '=' + SeedCache]);
  DumpRunFailure('producer lease lock seed', Run, 0);
  Expect<Integer>(Run.ExitCode).ToBe(0);
  AArchiveHash := SHA256File(SeedRoot
    + '/.lwpt/archives/shared-v1.0.0.tar.gz');

  WriteRoot(AFirstRoot);
  WriteRoot(ASecondRoot);
  CopyFileContent(SeedRoot + '/lwpt.lock', AFirstRoot + '/lwpt.lock');
  CopyFileContent(SeedRoot + '/lwpt.lock', ASecondRoot + '/lwpt.lock');
  RecursiveDelete(FCacheRoot);
end;

function TInstallProducerLease.StartInstall(const ARoot: string;
  const APort: Word; const ACrashProducer: Boolean): TProcess;
var
  Environment: array of string;
begin
  SetLength(Environment, 5);
  Environment[0] := PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR=' + FFixtureRoot;
  Environment[1] := CACHE_DIR_ENV + '=' + FCacheRoot;
  Environment[2] := ARCHIVE_FETCH_ORIGIN_ENV + '=http://127.0.0.1:'
    + IntToStr(APort);
  Environment[3] := ARCHIVE_FETCH_TIMEOUT_ENV + '=' + REQUEST_TIMEOUT;
  if ACrashProducer then
    Environment[4] := CRASH_PRODUCER_ENV + '=1'
  else
    Environment[4] := CRASH_PRODUCER_ENV + '=';
  Result := TProcess.Create(nil);
  Result.Executable := LwptBinaryPath;
  Result.Parameters.Add('install');
  Result.CurrentDirectory := ARoot;
  Result.Options := [poUsePipes];
  ConfigureProcessEnvironment(Result, Environment);
  Result.Execute;
end;

function TInstallProducerLease.WaitForExit(const AProcess: TProcess): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while AProcess.Running do
  begin
    if GetTickCount64 - StartedAt >= PROCESS_TIMEOUT_MILLISECONDS then
      Exit(False);
    Sleep(10);
  end;
  Result := True;
end;

function TInstallProducerLease.FinishInstall(const AProcess: TProcess;
  out AOutput: string): Integer;
begin
  if not WaitForExit(AProcess) then
  begin
    AProcess.Terminate(1);
    AProcess.WaitOnExit;
    AOutput := 'install process timed out';
    Exit(-1);
  end;
  AProcess.WaitOnExit;
  AOutput := ReadStream(AProcess.Output) + ReadStream(AProcess.Stderr);
  Result := AProcess.ExitStatus;
  {$IFDEF UNIX}
  { TProcess can expose waitpid's raw status after a Running poll. }
  if (Result > 255) and (Result mod 256 = 0) then Result := Result div 256;
  {$ENDIF}
end;

procedure TInstallProducerLease.AssertMaterialized(const ARoot,
  AArchiveHash: string);
var
  ArchivePath: string;
begin
  ArchivePath := ARoot + '/.lwpt/archives/shared-v1.0.0.tar.gz';
  Expect<Boolean>(FileExists(ArchivePath)).ToBe(True);
  Expect<string>(SHA256File(ArchivePath)).ToBe(AArchiveHash);
  Expect<Boolean>(FileExists(ARoot
    + '/.lwpt/modules/shared/source/shared.pas')).ToBe(True);
end;

procedure TInstallProducerLease.BeforeAll;
begin
  FOriginalDir := GetCurrentDir;
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
  FScratch := CreateScratchRoot('install-producer-lease');
end;

procedure TInstallProducerLease.BeforeEach;
begin
  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  FFixtureRoot := FScratch + '/git-fixture';
  FCacheRoot := FScratch + '/shared-cache';
end;

procedure TInstallProducerLease.AfterAll;
begin
  SetCurrentDir(FOriginalDir);
end;

procedure TInstallProducerLease.TestConcurrentLockedMissFetchesOnce;
var
  ArchiveHash, FirstOutput, FirstRoot, SecondOutput, SecondRoot: string;
  First, Second: TProcess;
  FirstStatus, SecondStatus: Integer;
  Mock: TMockHTTPServer;
begin
  PrepareLockedProjects('contention', FirstRoot, SecondRoot, ArchiveHash);
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(FArchiveBytes),
    0, 0, 1000);
  First := nil;
  Second := nil;
  try
    Mock.Start;
    First := StartInstall(FirstRoot, Mock.Port, False);
    Mock.WaitForAccepted;
    Second := StartInstall(SecondRoot, Mock.Port, False);
    FirstStatus := FinishInstall(First, FirstOutput);
    SecondStatus := FinishInstall(Second, SecondOutput);
    Expect<Boolean>(Mock.WaitDone(5000)).ToBe(True);
    Expect<Integer>(FirstStatus).ToBe(0);
    Expect<Integer>(SecondStatus).ToBe(0);
    Expect<Boolean>(Pos('GET /fixture/shared/archive/' + SHARED_COMMIT
      + '.tar.gz ', BytesAsString(Mock.ReceivedRequest)) > 0).ToBe(True);
    Expect<Boolean>(Pos('waiting for dependency archive shared',
      SecondOutput) > 0).ToBe(True);
    Expect<Boolean>(Pos('reused verified archive for shared after waiting',
      SecondOutput) > 0).ToBe(True);
    AssertMaterialized(FirstRoot, ArchiveHash);
    AssertMaterialized(SecondRoot, ArchiveHash);
  finally
    Second.Free;
    First.Free;
    Mock.Free;
  end;
end;

procedure TInstallProducerLease.TestCrashedProducerIsTakenOver;
var
  ArchiveHash, CrashOutput, FirstRoot, SecondOutput, SecondRoot: string;
  Crashed, Takeover: TProcess;
  CrashStatus, TakeoverStatus: Integer;
  Mock: TMockHTTPServer;
begin
  PrepareLockedProjects('crash', FirstRoot, SecondRoot, ArchiveHash);
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(FArchiveBytes));
  Crashed := nil;
  Takeover := nil;
  try
    Crashed := StartInstall(FirstRoot, Mock.Port, True);
    CrashStatus := FinishInstall(Crashed, CrashOutput);
    Expect<Integer>(CrashStatus).ToBe(88);
    Expect<Boolean>(FileExists(FirstRoot
      + '/.lwpt/archives/shared-v1.0.0.tar.gz')).ToBe(False);

    Mock.Start;
    Takeover := StartInstall(SecondRoot, Mock.Port, False);
    TakeoverStatus := FinishInstall(Takeover, SecondOutput);
    Expect<Boolean>(Mock.WaitDone(5000)).ToBe(True);
    if TakeoverStatus <> 0 then WriteLn(SecondOutput);
    Expect<Integer>(TakeoverStatus).ToBe(0);
    AssertMaterialized(SecondRoot, ArchiveHash);
    Expect<Boolean>(Pos('GET /fixture/shared/archive/' + SHARED_COMMIT
      + '.tar.gz ', BytesAsString(Mock.ReceivedRequest)) > 0).ToBe(True);
  finally
    Takeover.Free;
    Crashed.Free;
    Mock.Free;
  end;
end;

procedure TInstallProducerLease.SetupTests;
begin
  Test('concurrent locked dependency misses fetch once and both materialize',
    TestConcurrentLockedMissFetchesOnce);
  Test('a crashed dependency producer is taken over through admission',
    TestCrashedProducerIsTakenOver);
end;

begin
  TestRunnerProgram.AddSuite(TInstallProducerLease.Create(
    'install: shared dependency producer leases'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
