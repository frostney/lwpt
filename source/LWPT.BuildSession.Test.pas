program LWPT.BuildSession.Test;

{$I Shared.inc}
{$J-}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  TestingPascalLibrary,

  LWPT.BuildRequest,
  LWPT.BuildSession,
  LWPT.CompilerDriver.FPC,
  LWPT.Core;

type
  TLWPTBuildSessionTests = class(TTestSuite)
  private
    FScratch: string;
    procedure ResetScratch;
    procedure WriteText(const APath, AText: string);
    function BasicRequest: TLWPTBuildPublicationRequest;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestSessionsAreUniqueAndPrivate;
    procedure TestPathKeysAreBoundedAndCollisionResistant;
    procedure TestSessionIDsStayCompact;
    procedure TestManifestSessionRootIsProjectRelative;
    procedure TestRelocatedSessionUsesOwnedProjectNamespace;
    procedure TestCompilerPathBudgetGuard;
    procedure TestSuccessfulSessionIsRemoved;
    procedure TestStaleCandidateDoesNotReplacePublicOutput;
    procedure TestCurrentCandidatePublishesAtomically;
    procedure TestCompetingCandidateLosesPublication;
    procedure TestParsedManifestChangeRefusesFingerprint;
    procedure TestRootUnitPathIgnoresSessionStaging;
    procedure TestRootUnitPathIgnoresDeclaredOutputs;
    procedure TestSearchPathContentChangeRefusesPublication;
    procedure TestSourceDirectoryChangeRefusesPublication;
    procedure TestExplicitExcludedResourceChangeRefusesPublication;
    procedure TestHookInputChangeRefusesPublication;
    procedure TestNativeDriverRequestPreservesPublicationFingerprint;
    procedure TestExtraArgumentsChangePublicationFingerprint;
    procedure TestCacheFingerprintIgnoresSessionAndPublicArtifactBytes;
    procedure TestCacheFingerprintCoversCompilerTargetInputsAndEnvironment;
    procedure TestCacheFingerprintCoversPrerequisiteOutputs;
    procedure TestCacheFingerprintSeparatesOperationIdentity;
    procedure TestPublicationLockUsesSessionsRoot;
    procedure TestInputSnapshotNamesChangedFiles;
    procedure TestCaptureInputFileMatchesSnapshot;
    {$IFDEF UNIX}
    procedure TestCaptureInputFileRefusesSpecialFiles;
    procedure TestInputSnapshotRecordsUnreadableFiles;
    procedure TestInputSnapshotNeverOpensSpecialFiles;
    procedure TestSymlinkedSearchRootChangeRefusesPublication;
    procedure TestDirectoryAliasesHaveDeterministicFingerprint;
    procedure TestPublicationLockUsesFilesystemIdentity;
    procedure TestProjectNamespaceUsesPhysicalDirectoryIdentity;
    procedure TestRepairRejectsLinkedRelocatedNamespace;
    {$ENDIF}
    procedure TestRepairRemovesInactiveAndKeepsLiveSessions;
    procedure TestRepairRemovesInterruptedSessionCreation;
    procedure TestRepairUsesHistoricalRelocatedRootsOnly;
  end;

const
  { Runs one input scan in a child process (see RunScanHelper):
    "snapshot <root> <path>..." takes a snapshot and rechecks it, and
    "capture <root> <path>" reads one file through CaptureInputFile. }
  SCAN_HELPER_ARGUMENT = '--input-scan-helper';

procedure RunScanHelperMode;
var
  Content, Outcome: string;
  Paths: TStringArray;
  Snapshot: TLWPTInputSnapshot;
  i: Integer;
begin
  try
    { Each result is complete before anything is printed, so a scan that
      raises prints only its error. }
    if ParamStr(2) = 'capture' then
    begin
      Outcome := CaptureInputFile(ParamStr(3), ParamStr(4), Content);
      WriteLn('state=', Outcome);
    end
    else
    begin
      SetLength(Paths, ParamCount - 3);
      for i := 4 to ParamCount do Paths[i - 4] := ParamStr(i);
      Snapshot := CaptureInputSnapshot(ParamStr(3), Paths, nil);
      Outcome := FirstChangedInput(ParamStr(3), Snapshot, nil);
      WriteLn('changed=', Outcome);
    end;
  except
    on E: Exception do WriteLn('error=', E.ClassName, ': ', E.Message);
  end;
  Halt(0);
end;

{$IFDEF UNIX}
{ Runs this program in scan-helper mode and returns its output. A scan that
  blocks, for example in open() on a FIFO, cannot be interrupted from a
  thread of this process, so the helper is a child that is killed and
  reaped at the deadline: ATimedOut then reports the block and the test
  fails instead of hanging. }
function RunScanHelper(const AArguments: array of string;
  out ATimedOut: Boolean): string;
const
  HELPER_DEADLINE_MILLISECONDS = 30000;
  { SIGKILL cannot be caught, so a killed helper is reaped at once. }
  HELPER_REAP_MILLISECONDS = 10000;
var
  Helper: TProcess;
  Output: TStringList;
  i: Integer;
begin
  Result := '';
  Helper := TProcess.Create(nil);
  try
    Helper.Executable := ParamStr(0);
    Helper.Parameters.Add(SCAN_HELPER_ARGUMENT);
    for i := 0 to High(AArguments) do Helper.Parameters.Add(AArguments[i]);
    Helper.Options := [poUsePipes, poStderrToOutPut];
    Helper.Execute;
    ATimedOut := not Helper.WaitOnExit(HELPER_DEADLINE_MILLISECONDS);
    if ATimedOut then
    begin
      FpKill(Helper.ProcessID, SIGKILL);
      if not Helper.WaitOnExit(HELPER_REAP_MILLISECONDS) then
        raise Exception.Create('input scan helper survived SIGKILL');
      Exit;
    end;
    Output := TStringList.Create;
    try
      Output.LoadFromStream(Helper.Output);
      Result := Trim(Output.Text);
    finally
      Output.Free;
    end;
  finally
    Helper.Free;
  end;
end;
{$ENDIF}

{ Writes AContent byte for byte, with no line-ending translation. }
procedure WriteBytes(const APath, AContent: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AContent <> '' then Stream.WriteBuffer(AContent[1], Length(AContent));
  finally
    Stream.Free;
  end;
end;

procedure TLWPTBuildSessionTests.ResetScratch;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TLWPTBuildSessionTests.
  TestNativeDriverRequestPreservesPublicationFingerprint;
var
  Capabilities: TLWPTCompilerCapabilities;
  Driver: TLWPTFPCCompilerDriver;
  DriverRequest, LegacyRequest: TLWPTBuildPublicationRequest;
  DriverFingerprint, LegacyFingerprint: string;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  Driver := TLWPTFPCCompilerDriver.Create;
  try
    DriverRequest := BasicRequest;
    DriverRequest.BuildRequest := CreateFPCBuildRequest(
      'source/app.pas', 'candidate/app', Driver);
    SetLength(DriverRequest.BuildRequest.Inputs.UnitPaths, 1);
    DriverRequest.BuildRequest.Inputs.UnitPaths[0] := 'source';
    Capabilities := Driver.ProbeCapabilities(DriverRequest.BuildRequest.Target);
    DriverRequest.BuildRequest.Compiler.VersionIdentity :=
      Capabilities.VersionIdentity;
    DriverRequest.CompilerExecutable := Driver.ExecutableName;

    LegacyRequest := BasicRequest;
    LegacyRequest.BuildRequest.Compiler.ID := FPC_COMPILER_ID;
    LegacyRequest.BuildRequest.Compiler.VersionConstraint := '*';
    LegacyRequest.BuildRequest.Compiler.VersionIdentity :=
      Capabilities.VersionIdentity;
    LegacyRequest.CompilerExecutable := Driver.ExecutableName;
    LegacyRequest.BuildRequest.Target := DriverRequest.BuildRequest.Target;
    LegacyRequest.BuildRequest.Outputs.Artifact :=
      DriverRequest.BuildRequest.Outputs.Artifact;

    DriverFingerprint := CaptureBuildPublicationFingerprint(FScratch,
      MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, DriverRequest);
    LegacyFingerprint := CaptureBuildPublicationFingerprint(FScratch,
      MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, LegacyRequest);
    Expect<string>(DriverFingerprint).ToBe(LegacyFingerprint);
  finally
    Driver.Free;
  end;
end;

procedure TLWPTBuildSessionTests.
  TestExtraArgumentsChangePublicationFingerprint;
var
  FirstFingerprint, SecondFingerprint: string;
  Request: TLWPTBuildPublicationRequest;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.ExtraArguments, 1);
  Request.BuildRequest.Inputs.ExtraArguments[0] := '-dFIRST';
  FirstFingerprint := CaptureBuildPublicationFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Request.BuildRequest.Inputs.ExtraArguments[0] := '-dSECOND';
  SecondFingerprint := CaptureBuildPublicationFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Boolean>(FirstFingerprint <> SecondFingerprint).ToBe(True);
end;

procedure TLWPTBuildSessionTests.
  TestCacheFingerprintIgnoresSessionAndPublicArtifactBytes;
var
  FirstFingerprint, SecondFingerprint: string;
  Request: TLWPTBuildPublicationRequest;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'first-public-generation');
  Request := BasicRequest;
  Request.BuildRequest.Outputs.Artifact :=
    FScratch + '/.lwpt/sessions/first/bin/app';
  Request.BuildRequest.Outputs.ExecutableDirectory :=
    FScratch + '/.lwpt/sessions/first/bin';
  Request.BuildRequest.Outputs.UnitDirectory :=
    FScratch + '/.lwpt/sessions/first/units';
  Request.BuildRequest.Outputs.ObjectDirectory :=
    FScratch + '/.lwpt/sessions/first/objects';
  FirstFingerprint := CaptureBuildCacheFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Request.BuildRequest.Outputs.Artifact :=
    FScratch + '/.lwpt/sessions/second/bin/app';
  Request.BuildRequest.Outputs.ExecutableDirectory :=
    FScratch + '/.lwpt/sessions/second/bin';
  Request.BuildRequest.Outputs.UnitDirectory :=
    FScratch + '/.lwpt/sessions/second/units';
  Request.BuildRequest.Outputs.ObjectDirectory :=
    FScratch + '/.lwpt/sessions/second/objects';
  WriteText(FScratch + '/build/app', 'second-public-generation');
  SecondFingerprint := CaptureBuildCacheFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<string>(SecondFingerprint).ToBe(FirstFingerprint);
end;

procedure TLWPTBuildSessionTests.
  TestCacheFingerprintCoversCompilerTargetInputsAndEnvironment;
var
  Baseline, Changed: string;
  Request: TLWPTBuildPublicationRequest;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  Request := BasicRequest;
  SetLength(Request.CompilerArguments, 1);
  Request.CompilerArguments[0] := '--effective-first';
  SetLength(Request.Environment, 1);
  Request.Environment[0] := 'CACHE_FIXTURE=first';
  Baseline := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Request.CompilerArguments[0] := '--effective-second';
  Changed := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Boolean>(Changed <> Baseline).ToBe(True);
  Request.CompilerArguments[0] := '--effective-first';

  Request.BuildRequest.Compiler.VersionIdentity := '2.0.0';
  Changed := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Boolean>(Changed <> Baseline).ToBe(True);
  Request.BuildRequest.Compiler.VersionIdentity := '1.0.0';

  Request.BuildRequest.Target.Architecture := 'other-arch';
  Changed := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Boolean>(Changed <> Baseline).ToBe(True);
  Request.BuildRequest.Target.Architecture := 'test-arch';

  WriteText(FScratch + '/source/app.pas', 'begin WriteLn; end.');
  Changed := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Boolean>(Changed <> Baseline).ToBe(True);
  WriteText(FScratch + '/source/app.pas', 'begin end.');

  Request.Environment[0] := 'CACHE_FIXTURE=second';
  Changed := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Boolean>(Changed <> Baseline).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestCacheFingerprintCoversPrerequisiteOutputs;
var
  Baseline, Changed: string;
  Request: TLWPTBuildPublicationRequest;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/generated.inc', 'const VALUE = ''first'';');
  Request := BasicRequest;
  SetLength(Request.PrerequisiteOutputs, 1);
  Request.PrerequisiteOutputs[0] := 'build/generated.inc';
  Baseline := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  WriteText(FScratch + '/build/generated.inc', 'const VALUE = ''second'';');
  Changed := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Boolean>(Changed <> Baseline).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestInputSnapshotNamesChangedFiles;
var
  Excluded, Paths: TStringArray;
  Snapshot: TLWPTInputSnapshot;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/a.pas', 'unit a; interface implementation end.');
  WriteText(FScratch + '/source/out/generated.txt', 'first');
  SetLength(Paths, 4);
  Paths[0] := 'source';
  Paths[1] := 'source/';
  Paths[2] := FScratch + '/source';
  Paths[3] := MANIFEST_FILE;
  SetLength(Excluded, 1);
  Excluded[0] := 'source/out';
  Snapshot := CaptureInputSnapshot(FScratch, Paths, Excluded);
  Expect<Integer>(Length(Snapshot.Paths)).ToBe(2);
  Expect<string>(FirstChangedInput(FScratch, Snapshot, Excluded)).ToBe('');

  WriteText(FScratch + '/source/a.pas', 'unit a; interface implementation end.');
  WriteText(FScratch + '/source/out/generated.txt', 'second');
  Expect<string>(FirstChangedInput(FScratch, Snapshot, Excluded)).ToBe('');

  WriteText(FScratch + '/source/a.pas', 'unit a; interface const V = 1; '
    + 'implementation end.');
  Expect<string>(FirstChangedInput(FScratch, Snapshot, Excluded))
    .ToBe(ExpandFileName(FScratch + '/source') + PathDelim + 'a.pas');

  WriteText(FScratch + '/source/a.pas', 'unit a; interface implementation end.');
  WriteText(FScratch + '/source/b.pas', 'unit b; interface implementation end.');
  Expect<string>(FirstChangedInput(FScratch, Snapshot, Excluded))
    .ToBe(ExpandFileName(FScratch + '/source') + PathDelim + 'b.pas');

  SysUtils.DeleteFile(FScratch + '/source/b.pas');
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "other"');
  Expect<string>(FirstChangedInput(FScratch, Snapshot, Excluded))
    .ToBe(ExpandFileName(FScratch + '/' + MANIFEST_FILE));
end;

procedure TLWPTBuildSessionTests.TestCaptureInputFileMatchesSnapshot;
var
  Content: string;
  Paths: TStringArray;
  Snapshot: TLWPTInputSnapshot;
  State: string;
begin
  ResetScratch;
  WriteBytes(FScratch + '/lwpt.cfg', '-Fuunits'#10'-Fiincs'#0'bytes'#10);
  SetLength(Paths, 2);
  Paths[0] := 'lwpt.cfg';
  Paths[1] := 'absent.cfg';
  Snapshot := CaptureInputSnapshot(FScratch, Paths, nil);
  { The bytes read once and the state they hash to are what the snapshot
    records for the same file. }
  State := CaptureInputFile(FScratch, 'lwpt.cfg', Content);
  Expect<string>(Content).ToBe('-Fuunits'#10'-Fiincs'#0'bytes'#10);
  Expect<string>(State).ToBe(InputSnapshotState(FScratch, Snapshot,
    'lwpt.cfg'));
  Expect<string>(State).ToBe(InputSnapshotState(FScratch, Snapshot,
    FScratch + '/lwpt.cfg'));
  Expect<string>(CaptureInputFile(FScratch, 'absent.cfg', Content))
    .ToBe('missing');
  Expect<string>(Content).ToBe('');
  Expect<string>(InputSnapshotState(FScratch, Snapshot, 'absent.cfg'))
    .ToBe('missing');
  Expect<string>(InputSnapshotState(FScratch, Snapshot, 'other.cfg'))
    .ToBe('');
  WriteBytes(FScratch + '/lwpt.cfg', '-Fuother'#10);
  Expect<Boolean>(CaptureInputFile(FScratch, 'lwpt.cfg', Content) = State)
    .ToBe(False);
end;

{$IFDEF UNIX}
procedure TLWPTBuildSessionTests.TestInputSnapshotRecordsUnreadableFiles;
var
  Descriptor: THandle;
  Paths: TStringArray;
  Request: TLWPTBuildPublicationRequest;
  Snapshot: TLWPTInputSnapshot;
  CacheRefused: Boolean;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/source/Unused.pas', 'unit Unused; interface '
    + 'implementation end.');
  Expect<Integer>(FpChmod(FScratch + '/source/Unused.pas', 0)).ToBe(0);
  try
    SetLength(Paths, 1);
    Paths[0] := 'source';
    Snapshot := CaptureInputSnapshot(FScratch, Paths, nil);
    Expect<string>(FirstChangedInput(FScratch, Snapshot, nil)).ToBe('');

    { The cache keeps failing on the same file, so its callers still fall
      back to an uncached compile; only the snapshot tolerates it. }
    Descriptor := FileOpen(FScratch + '/source/Unused.pas', fmOpenRead);
    if Descriptor <> THandle(-1) then FileClose(Descriptor)
    else
    begin
      Request := BasicRequest;
      CacheRefused := False;
      try
        CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE, CFG_FILE,
          LOCKFILE, LWPT_DIR + '/modules', Request,
          BUILD_CACHE_OPERATION_TEST_PROGRAM);
      except
        on E: Exception do CacheRefused := True;
      end;
      Expect<Boolean>(CacheRefused).ToBe(True);
    end;

    WriteText(FScratch + '/source/Later.pas', 'unit Later; interface '
      + 'implementation end.');
    Expect<string>(FirstChangedInput(FScratch, Snapshot, nil))
      .ToBe(ExpandFileName(FScratch + '/source') + PathDelim + 'Later.pas');
  finally
    FpChmod(FScratch + '/source/Unused.pas', &600);
  end;
end;

procedure TLWPTBuildSessionTests.TestInputSnapshotNeverOpensSpecialFiles;
var
  Output: string;
  Paths: TStringArray;
  Snapshot: TLWPTInputSnapshot;
  TimedOut: Boolean;
begin
  ResetScratch;
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  { Opening a FIFO with no writer blocks, so both scans run in a helper
    process that the deadline kills. }
  Expect<Integer>(FpMkfifo(FScratch + '/source/pipe', &600)).ToBe(0);
  Output := RunScanHelper(['snapshot', FScratch, 'source', 'source/pipe'],
    TimedOut);
  if TimedOut then Fail('input snapshot blocked opening a FIFO');
  Expect<string>(Output).ToBe('changed=');
  SetLength(Paths, 2);
  Paths[0] := 'source';
  Paths[1] := 'source/pipe';
  Snapshot := CaptureInputSnapshot(FScratch, Paths, nil);
  Expect<Integer>(Length(Snapshot.Paths)).ToBe(2);
  WriteText(FScratch + '/source/app.pas', 'begin WriteLn; end.');
  Expect<string>(FirstChangedInput(FScratch, Snapshot, nil))
    .ToBe(ExpandFileName(FScratch + '/source') + PathDelim + 'app.pas');
end;

procedure TLWPTBuildSessionTests.TestCaptureInputFileRefusesSpecialFiles;
var
  Output: string;
  TimedOut: Boolean;
begin
  ResetScratch;
  Expect<Integer>(FpMkfifo(FScratch + '/pipe.cfg', &600)).ToBe(0);
  Output := RunScanHelper(['capture', FScratch, 'pipe.cfg'], TimedOut);
  if TimedOut then Fail('reading one input file blocked opening a FIFO');
  Expect<string>(Output).ToBe('error=ELWPTError: pipe.cfg is not a '
    + 'regular file');
end;
{$ENDIF}

procedure TLWPTBuildSessionTests.TestCacheFingerprintSeparatesOperationIdentity;
var
  BuildFingerprint, TestFingerprint: string;
  Request: TLWPTBuildPublicationRequest;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  Request := BasicRequest;

  BuildFingerprint := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request,
    BUILD_CACHE_OPERATION_BUILD_ENTRY);
  TestFingerprint := CaptureBuildCacheFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request,
    BUILD_CACHE_OPERATION_TEST_PROGRAM);

  Expect<Boolean>(TestFingerprint <> BuildFingerprint).ToBe(True);
end;

procedure TLWPTBuildSessionTests.WriteText(const APath, AText: string);
var
  Lines: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

function TLWPTBuildSessionTests.BasicRequest: TLWPTBuildPublicationRequest;
begin
  Result := Default(TLWPTBuildPublicationRequest);
  Result.BuildRequest := DefaultBuildRequest;
  Result.BuildRequest.Compiler.ID := 'test-compiler';
  Result.BuildRequest.Compiler.VersionIdentity := '1.0.0';
  Result.CompilerExecutable := '/test/compiler';
  Result.ManifestContentHash := SHA256File(
    FScratch + '/' + MANIFEST_FILE);
  Result.PublicOutput := 'build/app';
  Result.BuildRequest.Target.OS := 'test-os';
  Result.BuildRequest.Target.Architecture := 'test-arch';
  Result.BuildRequest.Inputs.EntryPoint := 'source/app.pas';
  SetLength(Result.BuildRequest.Inputs.Sources, 1);
  Result.BuildRequest.Inputs.Sources[0] := 'source/app.pas';
  Result.BuildRequest.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  Result.BuildRequest.Mode := BUILD_MODE_DEV;
  Result.BuildRequest.Outputs.Artifact := 'candidate/app';
  SetLength(Result.BuildRequest.Inputs.UnitPaths, 1);
  Result.BuildRequest.Inputs.UnitPaths[0] := 'source';
end;

procedure TLWPTBuildSessionTests.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/build-session-unit');
end;

procedure TLWPTBuildSessionTests.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TLWPTBuildSessionTests.TestSessionsAreUniqueAndPrivate;
var
  First, Second: TLWPTBuildSession;
begin
  ResetScratch;
  First := TLWPTBuildSession.Create(FScratch);
  Second := TLWPTBuildSession.Create(FScratch);
  try
    Expect<Boolean>(First.SessionID <> Second.SessionID).ToBe(True);
    Expect<Boolean>(First.JobRoot('app') <> Second.JobRoot('app')).ToBe(True);
    Expect<Boolean>(First.JobRoot('one:two')
      <> First.JobRoot('one_two')).ToBe(True);
    Expect<Boolean>(DirectoryExists(First.SessionRoot)).ToBe(True);
    Expect<Boolean>(DirectoryExists(Second.SessionRoot)).ToBe(True);
  finally
    First.Finish(False, 'test');
    Second.Finish(False, 'test');
    First.Free;
    Second.Free;
  end;
end;

procedure TLWPTBuildSessionTests.TestManifestSessionRootIsProjectRelative;
var
  Resolved: string;
begin
  ResetScratch;
  Resolved := ResolveBuildSessionsRoot(FScratch, '../shallow-sessions',
    FScratch + '/invocation');
  Expect<string>(Resolved).ToBe(ExpandFileName(FScratch
    + '/../shallow-sessions'));
  Resolved := ResolveBuildSessionsRoot(FScratch, '',
    FScratch + '/invocation');
  Expect<string>(Resolved).ToBe(ExpandFileName(FScratch + '/'
    + BUILD_SESSIONS_DIR));
end;

procedure TLWPTBuildSessionTests.
  TestRelocatedSessionUsesOwnedProjectNamespace;
var
  Session: TLWPTBuildSession;
  ConfiguredRoot, Ledger: string;
begin
  ResetScratch;
  ConfiguredRoot := FScratch + '-shared';
  if DirectoryExists(ConfiguredRoot) then WipeDir(ConfiguredRoot);
  Session := TLWPTBuildSession.Create(FScratch, ConfiguredRoot);
  try
    Expect<Boolean>(Pos(IncludeTrailingPathDelimiter(ConfiguredRoot)
      + 'p-', Session.SessionsRoot) = 1).ToBe(True);
    Expect<Boolean>(FileExists(Session.SessionsRoot
      + '/project.identity')).ToBe(True);
    Expect<string>(Session.SessionReference).ToBe(Session.SessionRoot);
    Ledger := FScratch + '/' + BUILD_SESSION_ROOT_LEDGER;
    Expect<Boolean>(FileExists(Ledger)).ToBe(True);
  finally
    Session.Finish(True);
    Session.Free;
    if DirectoryExists(ConfiguredRoot) then WipeDir(ConfiguredRoot);
  end;
end;

{$IFDEF UNIX}
procedure TLWPTBuildSessionTests.
  TestProjectNamespaceUsesPhysicalDirectoryIdentity;
var
  ProjectPath, RenamedPath, AliasPath, SharedRoot: string;
  OriginalRoot, RenamedRoot, AliasRoot, UpperRoot, LowerRoot: string;
  UpperInfo, LowerInfo: BaseUnix.Stat;
begin
  ResetScratch;
  ProjectPath := FScratch + '/Project';
  RenamedPath := FScratch + '/Renamed';
  AliasPath := FScratch + '/Alias';
  SharedRoot := FScratch + '/shared';
  ForceDirectories(ProjectPath);
  OriginalRoot := BuildSessionsProjectRoot(ProjectPath, SharedRoot);
  if not RenameFile(ProjectPath, RenamedPath) then
    raise Exception.Create('fixture: could not rename project directory');
  RenamedRoot := BuildSessionsProjectRoot(RenamedPath, SharedRoot);
  Expect<string>(RenamedRoot).ToBe(OriginalRoot);
  if FpSymlink(PAnsiChar('Renamed'), PAnsiChar(AliasPath)) <> 0 then
    raise Exception.Create('fixture: could not create project alias');
  AliasRoot := BuildSessionsProjectRoot(AliasPath, SharedRoot);
  Expect<string>(AliasRoot).ToBe(OriginalRoot);

  ForceDirectories(FScratch + '/Foo');
  ForceDirectories(FScratch + '/foo');
  if (FpStat(FScratch + '/Foo', UpperInfo) = 0)
    and (FpStat(FScratch + '/foo', LowerInfo) = 0)
    and ((UpperInfo.st_dev <> LowerInfo.st_dev)
      or (UpperInfo.st_ino <> LowerInfo.st_ino)) then
  begin
    UpperRoot := BuildSessionsProjectRoot(FScratch + '/Foo', SharedRoot);
    LowerRoot := BuildSessionsProjectRoot(FScratch + '/foo', SharedRoot);
    Expect<Boolean>(UpperRoot <> LowerRoot).ToBe(True);
  end;
end;

procedure TLWPTBuildSessionTests.
  TestRepairRejectsLinkedRelocatedNamespace;
var
  Session: TLWPTBuildSession;
  ConfiguredRoot, NamespaceRoot, VictimSession: string;
  Removed, Retained: Integer;
begin
  ResetScratch;
  ConfiguredRoot := FScratch + '-shared';
  if DirectoryExists(ConfiguredRoot) then WipeDir(ConfiguredRoot);
  Session := TLWPTBuildSession.Create(FScratch, ConfiguredRoot);
  NamespaceRoot := Session.SessionsRoot;
  Session.Finish(False, 'failed');
  Session.Free;
  WipeDir(NamespaceRoot);
  VictimSession := FScratch + '/victim/s-foreign';
  WriteText(VictimSession + '/session.state',
    '999999999'#10'failed'#10'1');
  if FpSymlink(PAnsiChar(FScratch + '/victim'),
    PAnsiChar(NamespaceRoot)) <> 0 then
    raise Exception.Create('fixture: could not link session namespace');

  RepairBuildSessions(FScratch, Removed, Retained);

  Expect<Integer>(Removed).ToBe(0);
  Expect<Boolean>(DirectoryExists(VictimSession)).ToBe(True);
  if IsDirSymlinkOrJunction(NamespaceRoot) then
    FpUnlink(PAnsiChar(NamespaceRoot));
  if DirectoryExists(ConfiguredRoot) then WipeDir(ConfiguredRoot);
end;
{$ENDIF}

procedure TLWPTBuildSessionTests.TestPathKeysAreBoundedAndCollisionResistant;
var
  First, Second, LongKey: string;
begin
  First := BuildSessionPathKey('one:two.pas');
  Second := BuildSessionPathKey('one_two.pas');
  LongKey := BuildSessionPathKey(StringOfChar('a', 300) + '.pas');

  Expect<Boolean>(First <> Second).ToBe(True);
  Expect<Boolean>(Length(First) <= 29).ToBe(True);
  Expect<Boolean>(Length(Second) <= 29).ToBe(True);
  Expect<Boolean>(Length(LongKey) <= 29).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestSessionIDsStayCompact;
var
  Session: TLWPTBuildSession;
begin
  ResetScratch;
  Session := TLWPTBuildSession.Create(FScratch);
  try
    { The slug prefixes every compiler staging path; the compact form
      ('s-<pid36>-<ts36>-<n>-<m>') must stay far below the long
      pre-compaction 36+ characters. }
    Expect<string>(Copy(Session.SessionID, 1, 2)).ToBe('s-');
    Expect<Boolean>(Length(Session.SessionID) <= 28).ToBe(True);
  finally
    Session.Finish(False, 'test');
    Session.Free;
  end;
end;

procedure TLWPTBuildSessionTests.TestCompilerPathBudgetGuard;
var
  SourceDir, ShortStaging, LongStaging, Padding: string;
  Longest: Integer;
  Raised, MentionsTooLong, MentionsAssembly: Boolean;
  Dirs: TStringArray;
begin
  ResetScratch;
  SourceDir := FScratch + '/budget-src';
  ForceDirectories(SourceDir);
  WriteText(SourceDir + '/A.pas', 'unit A; interface implementation end.');
  WriteText(SourceDir + '/A.Very.Long.Unit.Name.pas',
    'unit A.Very.Long.Unit.Name; interface implementation end.');
  SetLength(Dirs, 1);
  Dirs[0] := SourceDir;

  { Longest name wins over the entry program's name. }
  Longest := LongestCompiledBaseNameLength(Dirs, SourceDir + '/App.pas');
  Expect<Integer>(Longest).ToBe(Length('A.Very.Long.Unit.Name'));

  { Missing directories are skipped; the entry name still counts. }
  Dirs[0] := FScratch + '/does-not-exist';
  Expect<Integer>(LongestCompiledBaseNameLength(
    Dirs, SourceDir + '/App.pas')).ToBe(Length('App'));

  { Within budget: '<staging>/<longest>.s' at exactly the limit passes. }
  Padding := StringOfChar('p',
    COMPILER_PATH_LIMIT - Length(ExpandFileName(FScratch)) - 1
      - (1 + Longest + 2));
  ShortStaging := ExpandFileName(FScratch) + '/' + Padding;
  EnsureCompilerPathBudget(ShortStaging, ShortStaging, Longest);

  { One character over the limit refuses the compile loudly. }
  LongStaging := ShortStaging + 'p';
  Raised := False;
  MentionsTooLong := False;
  MentionsAssembly := False;
  try
    EnsureCompilerPathBudget(LongStaging, LongStaging, Longest);
  except
    on E: ELWPTError do
    begin
      Raised := True;
      MentionsTooLong := Pos('too long', E.Message) > 0;
      MentionsAssembly := Pos('.s', E.Message) > 0;
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(MentionsTooLong).ToBe(True);
  Expect<Boolean>(MentionsAssembly).ToBe(True);

  { The executable directory's fixed link artefacts are budgeted too. }
  Raised := False;
  try
    EnsureCompilerPathBudget(FScratch,
      ShortStaging + StringOfChar('q', 24), 1);
  except
    on E: ELWPTError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestSuccessfulSessionIsRemoved;
var
  Session: TLWPTBuildSession;
  OwnerPath, Root: string;
begin
  ResetScratch;
  Session := TLWPTBuildSession.Create(FScratch);
  Root := Session.SessionRoot;
  OwnerPath := FScratch + '/' + BUILD_SESSIONS_DIR + '/locks/owners/'
    + Session.SessionID + '.lock';
  Expect<Boolean>(FileExists(OwnerPath)).ToBe(True);
  Session.Finish(True);
  Session.Free;
  Expect<Boolean>(DirectoryExists(Root)).ToBe(False);
  Expect<Boolean>(FileExists(OwnerPath)).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestStaleCandidateDoesNotReplacePublicOutput;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE,
    '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/source/app.pas', 'begin WriteLn; end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/build/app');
    Expect<string>(Trim(Lines.Text)).ToBe('old');
  finally
    Lines.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestCurrentCandidatePublishesAtomically;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/build/app');
    Expect<string>(Trim(Lines.Text)).ToBe('new');
  finally
    Lines.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestCompetingCandidateLosesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Lines: TStringList;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/app', 'old');
  WriteText(FScratch + '/candidate-first/app', 'winner');
  WriteText(FScratch + '/candidate-second/app', 'late');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate-first/app', 'build/app', Fingerprint,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate-second/app', 'build/app', Fingerprint,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FScratch + '/build/app');
    Expect<string>(Trim(Lines.Text)).ToBe('winner');
  finally
    Lines.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/candidate-second/app')).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestParsedManifestChangeRefusesFingerprint;
var
  Request: TLWPTBuildPublicationRequest;
  Raised: Boolean;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  Request := BasicRequest;
  WriteText(FScratch + '/' + MANIFEST_FILE,
    '[package]'#10'name = "changed-app"');
  Raised := False;
  try
    CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
      CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  except
    on E: ELWPTError do
      Raised := Pos('manifest changed after it was parsed', E.Message) > 0;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestRootUnitPathIgnoresSessionStaging;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
  Session: TLWPTBuildSession;
  Candidate: string;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/app.pas', 'begin end.');
  Request := BasicRequest;
  Request.BuildRequest.Inputs.EntryPoint := 'app.pas';
  Request.BuildRequest.Inputs.Sources[0] := 'app.pas';
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 1);
  Request.BuildRequest.Inputs.UnitPaths[0] := '.';
  Session := TLWPTBuildSession.Create(FScratch);
  try
    Candidate := Session.JobRoot('app') + '/app';
    WriteText(Candidate, 'new');
    Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
      CFG_FILE, LOCKFILE, MODULES_DIR, Request);
    WriteText(Session.JobRoot('app') + '/units/app.ppu', 'private');

    Publication := PublishBuildArtifact(FScratch, Candidate, 'build/app',
      Fingerprint, MANIFEST_FILE, CFG_FILE, LOCKFILE, MODULES_DIR,
      Request);

    Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
    Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(True);
    Session.Finish(True);
  finally
    Session.Free;
  end;
end;

procedure TLWPTBuildSessionTests.TestRootUnitPathIgnoresDeclaredOutputs;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/app.pas', 'begin end.');
  WriteText(FScratch + '/other.pas', 'begin end.');
  WriteText(FScratch + '/candidate/other', 'new');
  Request := BasicRequest;
  Request.BuildRequest.Inputs.EntryPoint := 'other.pas';
  Request.BuildRequest.Inputs.Sources[0] := 'other.pas';
  Request.PublicOutput := 'build/other';
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 1);
  Request.BuildRequest.Inputs.UnitPaths[0] := '.';
  SetLength(Request.ExcludedPaths, 2);
  Request.ExcludedPaths[0] := 'build/app';
  Request.ExcludedPaths[1] := 'build/other';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/build/app', 'unrelated published output');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/other', 'build/other', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprPublished));
  Expect<Boolean>(FileExists(FScratch + '/build/other')).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestSearchPathContentChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/extra/SharedUnit.pas', 'unit SharedUnit; end.');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 2);
  Request.BuildRequest.Inputs.UnitPaths[0] := 'source';
  Request.BuildRequest.Inputs.UnitPaths[1] := 'extra';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/extra/SharedUnit.pas',
    'unit SharedUnit; interface implementation end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
  Expect<Boolean>(FileExists(FScratch + '/candidate/app')).ToBe(True);
end;

procedure TLWPTBuildSessionTests.TestSourceDirectoryChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas',
    'program app;'#10'{$I sibling.inc}'#10'begin end.');
  WriteText(FScratch + '/source/sibling.inc', 'const Value = 1;');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.UnitPaths, 0);
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/source/sibling.inc', 'const Value = 2;');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestExplicitExcludedResourceChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/build/generated.res', 'first');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.BuildRequest.Inputs.Resources, 1);
  Request.BuildRequest.Inputs.Resources[0] := 'build/generated.res';
  SetLength(Request.ExcludedPaths, 2);
  Request.ExcludedPaths[0] := 'build/generated.res';
  Request.ExcludedPaths[1] := 'build/app';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/build/generated.res', 'second');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestHookInputChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/scripts/sign.pas', 'program sign; begin end.');
  WriteText(FScratch + '/scripts/signing-key.txt', 'first');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  SetLength(Request.HookDefinition, 2);
  Request.HookDefinition[0] := 'sign';
  Request.HookDefinition[1] := 'scripts/sign.pas';
  SetLength(Request.HookInputs, 2);
  Request.HookInputs[0] := 'scripts/sign.pas';
  Request.HookInputs[1] := 'scripts/signing-key.txt';
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/scripts/signing-key.txt', 'second');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

{$IFDEF UNIX}
procedure TLWPTBuildSessionTests.TestSymlinkedSearchRootChangeRefusesPublication;
var
  Request: TLWPTBuildPublicationRequest;
  Fingerprint: string;
  Publication: TLWPTBuildPublicationResult;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/packages/shared/source/SharedUnit.pas',
    'unit SharedUnit; interface implementation end.');
  ForceDirectories(FScratch + '/' + MODULES_DIR);
  if FpSymlink(PAnsiChar('../../packages/shared'),
    PAnsiChar(FScratch + '/' + MODULES_DIR + '/shared')) <> 0 then
    raise Exception.Create('fixture: workspace symlink creation failed');
  if FpSymlink(PAnsiChar('.'),
    PAnsiChar(FScratch + '/packages/shared/loop')) <> 0 then
    raise Exception.Create('fixture: cycle symlink creation failed');
  WriteText(FScratch + '/candidate/app', 'new');
  Request := BasicRequest;
  Fingerprint := CaptureBuildPublicationFingerprint(FScratch, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);
  WriteText(FScratch + '/packages/shared/source/SharedUnit.pas',
    'unit SharedUnit; interface const Changed = True; implementation end.');

  Publication := PublishBuildArtifact(FScratch,
    FScratch + '/candidate/app', 'build/app', Fingerprint, MANIFEST_FILE,
    CFG_FILE, LOCKFILE, MODULES_DIR, Request);

  Expect<Integer>(Ord(Publication)).ToBe(Ord(bprStale));
  Expect<Boolean>(FileExists(FScratch + '/build/app')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.TestDirectoryAliasesHaveDeterministicFingerprint;
var
  FirstRequest: TLWPTBuildPublicationRequest;
  FirstFingerprint, SecondFingerprint: string;
begin
  ResetScratch;
  WriteText(FScratch + '/' + MANIFEST_FILE, '[package]'#10'name = "app"');
  WriteText(FScratch + '/source/app.pas', 'begin end.');
  WriteText(FScratch + '/modules/real/value.txt', 'same');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/z-alias')) <> 0 then
    raise Exception.Create('fixture: first z alias creation failed');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/a-alias')) <> 0 then
    raise Exception.Create('fixture: first a alias creation failed');
  FirstRequest := Default(TLWPTBuildPublicationRequest);
  FirstRequest.BuildRequest := DefaultBuildRequest;
  FirstRequest.BuildRequest.Compiler.ID := 'test-compiler';
  FirstRequest.BuildRequest.Compiler.VersionIdentity := '1.0.0';
  FirstRequest.CompilerExecutable := '/test/compiler';
  FirstRequest.ManifestContentHash := SHA256File(
    FScratch + '/' + MANIFEST_FILE);
  FirstRequest.PublicOutput := 'build/app';
  FirstRequest.BuildRequest.Target.OS := 'test-os';
  FirstRequest.BuildRequest.Target.Architecture := 'test-arch';
  FirstRequest.BuildRequest.Inputs.EntryPoint := 'source/app.pas';
  SetLength(FirstRequest.BuildRequest.Inputs.Sources, 1);
  FirstRequest.BuildRequest.Inputs.Sources[0] := 'source/app.pas';
  FirstRequest.BuildRequest.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  FirstRequest.BuildRequest.Mode := BUILD_MODE_DEV;
  FirstRequest.BuildRequest.Outputs.Artifact := 'candidate/app';
  SetLength(FirstRequest.BuildRequest.Inputs.UnitPaths, 1);
  FirstRequest.BuildRequest.Inputs.UnitPaths[0] := 'modules';
  FirstFingerprint := CaptureBuildPublicationFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, 'modules', FirstRequest);
  SysUtils.DeleteFile(FScratch + '/modules/a-alias');
  SysUtils.DeleteFile(FScratch + '/modules/z-alias');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/a-alias')) <> 0 then
    raise Exception.Create('fixture: second a alias creation failed');
  if FpSymlink(PAnsiChar('real'),
    PAnsiChar(FScratch + '/modules/z-alias')) <> 0 then
    raise Exception.Create('fixture: second z alias creation failed');
  SecondFingerprint := CaptureBuildPublicationFingerprint(FScratch,
    MANIFEST_FILE, CFG_FILE, LOCKFILE, 'modules', FirstRequest);

  Expect<string>(SecondFingerprint).ToBe(FirstFingerprint);
end;

procedure TLWPTBuildSessionTests.TestPublicationLockUsesFilesystemIdentity;
var
  PhysicalPath, AliasPath: string;
begin
  ResetScratch;
  ForceDirectories(FScratch + '/physical');
  if FpSymlink(PAnsiChar('physical'),
    PAnsiChar(FScratch + '/alias')) <> 0 then
    raise Exception.Create('fixture: output alias creation failed');

  PhysicalPath := BuildPublicationLockPath(FScratch,
    FScratch + '/physical/app');
  AliasPath := BuildPublicationLockPath(FScratch,
    FScratch + '/alias/app');

  Expect<string>(AliasPath).ToBe(PhysicalPath);
end;
{$ENDIF}

procedure TLWPTBuildSessionTests.TestPublicationLockUsesSessionsRoot;
var
  LockPath, SessionsRoot: string;
begin
  ResetScratch;
  SessionsRoot := FScratch + '/relocated/p-project';
  LockPath := BuildPublicationLockPath(SessionsRoot,
    FScratch + '/build/app');

  Expect<Boolean>(PathContains(SessionsRoot, LockPath)).ToBe(True);
  Expect<string>(ExtractFileDir(LockPath)).ToBe(SessionsRoot + '/locks');
end;

procedure TLWPTBuildSessionTests.TestRepairRemovesInactiveAndKeepsLiveSessions;
var
  LiveSession, FailedSession: TLWPTBuildSession;
  LiveRoot, FailedRoot, FailedOwnerPath: string;
  Removed, Retained: Integer;
begin
  ResetScratch;
  LiveSession := TLWPTBuildSession.Create(FScratch);
  FailedSession := TLWPTBuildSession.Create(FScratch);
  LiveRoot := LiveSession.SessionRoot;
  FailedRoot := FailedSession.SessionRoot;
  FailedOwnerPath := FScratch + '/' + BUILD_SESSIONS_DIR + '/locks/owners/'
    + FailedSession.SessionID + '.lock';
  FailedSession.Finish(False, 'failed');
  FailedSession.Free;
  Expect<Boolean>(FileExists(FailedOwnerPath)).ToBe(True);
  WriteText(LiveRoot + '/session.state', 'unreadable live state');

  RepairBuildSessions(IncludeTrailingPathDelimiter(FScratch), Removed,
    Retained);
  Expect<Integer>(Removed).ToBe(1);
  Expect<Integer>(Retained).ToBe(1);
  Expect<Boolean>(DirectoryExists(FailedRoot)).ToBe(False);
  Expect<Boolean>(FileExists(FailedOwnerPath)).ToBe(False);
  Expect<Boolean>(DirectoryExists(LiveRoot)).ToBe(True);

  LiveSession.Finish(True);
  LiveSession.Free;
end;

procedure TLWPTBuildSessionTests.TestRepairRemovesInterruptedSessionCreation;
var
  Removed, Retained: Integer;
begin
  ResetScratch;
  WriteText(FScratch
    + '/' + BUILD_SESSIONS_DIR
    + '/.creating-session-abandoned/session.state',
    '999999999'#10'active'#10'1');

  RepairBuildSessions(FScratch, Removed, Retained);

  Expect<Integer>(Removed).ToBe(1);
  Expect<Integer>(Retained).ToBe(0);
  Expect<Boolean>(DirectoryExists(FScratch
    + '/' + BUILD_SESSIONS_DIR
    + '/.creating-session-abandoned')).ToBe(False);
end;

procedure TLWPTBuildSessionTests.
  TestRepairUsesHistoricalRelocatedRootsOnly;
var
  FailedSession: TLWPTBuildSession;
  FailedRoot, ConfiguredRoot, UnownedRoot: string;
  Removed, Retained: Integer;
begin
  ResetScratch;
  ConfiguredRoot := FScratch + '-shared';
  UnownedRoot := ConfiguredRoot + '/other-project/s-orphan';
  if DirectoryExists(ConfiguredRoot) then WipeDir(ConfiguredRoot);
  FailedSession := TLWPTBuildSession.Create(FScratch, ConfiguredRoot);
  FailedRoot := FailedSession.SessionRoot;
  FailedSession.Finish(False, 'failed');
  FailedSession.Free;
  WriteText(UnownedRoot + '/session.state', '999999999'#10'failed'#10'1');

  RepairBuildSessions(IncludeTrailingPathDelimiter(FScratch), Removed,
    Retained);

  Expect<Integer>(Removed).ToBe(1);
  Expect<Boolean>(DirectoryExists(FailedRoot)).ToBe(False);
  Expect<Boolean>(DirectoryExists(UnownedRoot)).ToBe(True);
  if DirectoryExists(ConfiguredRoot) then WipeDir(ConfiguredRoot);
end;

procedure TLWPTBuildSessionTests.SetupTests;
begin
  Test('sessions have unique private job roots',
    TestSessionsAreUniqueAndPrivate);
  Test('session ids stay compact for path-budget headroom',
    TestSessionIDsStayCompact);
  Test('manifest session roots resolve from the project root',
    TestManifestSessionRootIsProjectRelative);
  Test('relocated sessions use an owned project namespace',
    TestRelocatedSessionUsesOwnedProjectNamespace);
  Test('compiler path budget guard refuses over-long staging',
    TestCompilerPathBudgetGuard);
  Test('path keys are bounded and resist sanitised collisions',
    TestPathKeysAreBoundedAndCollisionResistant);
  Test('successful sessions remove private staging',
    TestSuccessfulSessionIsRemoved);
  Test('stale candidate cannot replace public output',
    TestStaleCandidateDoesNotReplacePublicOutput);
  Test('current candidate atomically replaces public output',
    TestCurrentCandidatePublishesAtomically);
  Test('competing candidate loses publication to the winner',
    TestCompetingCandidateLosesPublication);
  Test('manifest changes after parsing refuse fingerprint capture',
    TestParsedManifestChangeRefusesFingerprint);
  Test('root unit path excludes changing session staging',
    TestRootUnitPathIgnoresSessionStaging);
  Test('root unit path excludes declared build outputs',
    TestRootUnitPathIgnoresDeclaredOutputs);
  Test('search-path content change refuses publication',
    TestSearchPathContentChangeRefusesPublication);
  Test('source-directory content change refuses publication',
    TestSourceDirectoryChangeRefusesPublication);
  Test('explicit resources remain inputs when also declared outputs',
    TestExplicitExcludedResourceChangeRefusesPublication);
  Test('postbuild hook input changes refuse publication',
    TestHookInputChangeRefusesPublication);
  Test('native driver request preserves the publication fingerprint',
    TestNativeDriverRequestPreservesPublicationFingerprint);
  Test('extra compiler arguments change the publication fingerprint',
    TestExtraArgumentsChangePublicationFingerprint);
  Test('cache fingerprints ignore sessions and prior public artifact bytes',
    TestCacheFingerprintIgnoresSessionAndPublicArtifactBytes);
  Test('cache fingerprints cover compiler target inputs and environment',
    TestCacheFingerprintCoversCompilerTargetInputsAndEnvironment);
  Test('cache fingerprints cover prerequisite outputs',
    TestCacheFingerprintCoversPrerequisiteOutputs);
  Test('cache fingerprints separate build and test operations',
    TestCacheFingerprintSeparatesOperationIdentity);
  Test('publication locks use the resolved sessions root',
    TestPublicationLockUsesSessionsRoot);
  Test('input snapshots hash each path once and name changed files',
    TestInputSnapshotNamesChangedFiles);
  Test('one read of an input file states what the snapshot records',
    TestCaptureInputFileMatchesSnapshot);
  {$IFDEF UNIX}
  Test('reading one input file refuses special files without blocking',
    TestCaptureInputFileRefusesSpecialFiles);
  Test('input snapshots record unreadable files without failing',
    TestInputSnapshotRecordsUnreadableFiles);
  Test('input snapshots never open special files',
    TestInputSnapshotNeverOpensSpecialFiles);
  Test('symlinked search roots detect changes and terminate cycles',
    TestSymlinkedSearchRootChangeRefusesPublication);
  Test('directory aliases produce deterministic fingerprints',
    TestDirectoryAliasesHaveDeterministicFingerprint);
  Test('publication locks use destination filesystem identity',
    TestPublicationLockUsesFilesystemIdentity);
  Test('project namespaces use physical directory identity',
    TestProjectNamespaceUsesPhysicalDirectoryIdentity);
  Test('repair rejects linked relocated namespaces',
    TestRepairRejectsLinkedRelocatedNamespace);
  {$ENDIF}
  Test('repair removes inactive sessions and retains live sessions',
    TestRepairRemovesInactiveAndKeepsLiveSessions);
  Test('repair removes interrupted session creation',
    TestRepairRemovesInterruptedSessionCreation);
  Test('repair uses historical relocated roots without scanning siblings',
    TestRepairUsesHistoricalRelocatedRootsOnly);
end;

begin
  if (ParamCount >= 3) and (ParamStr(1) = SCAN_HELPER_ARGUMENT) then
    RunScanHelperMode;
  TestRunnerProgram.AddSuite(TLWPTBuildSessionTests.Create(
    'build sessions and publication'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
