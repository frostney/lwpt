{ LWPT.Command.Testing — test subcommand entrypoint. }
unit LWPT.Command.Testing;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,

  LWPT.BuildRequest,
  LWPT.CompilerRegistry;

function TestTargetRunsOnHost(const ATarget: TLWPTTarget;
  const AHostOS, AHostArchitecture: string): Boolean;
function CmdTest(const AManifestPath: string;
  const AJobs, ABail: Integer; const AVerbose, AInventory: Boolean;
  const ASelectors: TStrings; const AUseCache: Boolean = True): Integer;
  overload;
function CmdTest(const AManifestPath: string;
  const AJobs, ABail: Integer; const AVerbose, AInventory: Boolean;
  const ASelectors: TStrings;
  const ACompilerHost: TLWPTCompilerHost;
  const AUseCache: Boolean = True): Integer; overload;

implementation

uses
  Process,
  SysUtils,

  LWPT.Analysis.JSON,
  LWPT.BuildCache,
  LWPT.BuildSession,
  LWPT.Command.Common,
  LWPT.CompilerDriver,
  LWPT.Core,
  LWPT.Manifest,
  LWPT.Observability,
  LWPT.ProcessRunner,
  LWPT.ProcessTree,
  LWPT.ProducerLease,
  LWPT.ProgressReporter,
  LWPT.TestArtifactSet,
  LWPT.TestInventory,
  LWPT.WorkerBudget,
  Platform,
  TestingPascalLibrary.Protocol;

function TestTargetRunsOnHost(const ATarget: TLWPTTarget;
  const AHostOS, AHostArchitecture: string): Boolean;
var
  OSMatches, ArchitectureMatches: Boolean;
begin
  OSMatches := SameText(ATarget.OS, AHostOS)
    or (IsWindowsOperatingSystem(ATarget.OS)
        and IsWindowsOperatingSystem(AHostOS));
  ArchitectureMatches := SameText(ATarget.Architecture,
    AHostArchitecture)
    or ((SameText(ATarget.Architecture, 'i386')
         or SameText(ATarget.Architecture, 'x86'))
        and (SameText(AHostArchitecture, 'i386')
             or SameText(AHostArchitecture, 'x86')))
    { WOW64 makes a 32-bit Windows executable a native-runnable host
      artifact on 64-bit x86 Windows. }
    or (OSMatches and IsWindowsOperatingSystem(AHostOS)
        and (SameText(ATarget.Architecture, 'i386')
             or SameText(ATarget.Architecture, 'x86'))
        and SameText(AHostArchitecture, 'x86_64'));
  Result := OSMatches and ArchitectureMatches;
end;

function TestTargetIsHost(const ATarget: TLWPTTarget): Boolean;
begin
  Result := TestTargetRunsOnHost(ATarget, Platform.GetBuildOS,
    Platform.GetBuildArch);
end;

type
  TLWPTTestCacheContext = record
    Cache: TLWPTBuildCache;
    UseCache: Boolean;
    ManifestPath: string;
    ManifestContentHash: string;
    ConfigurationPath: string;
    ModulesPath: string;
    CompilerImplicitInputs: TStringArray;
    WorkspacePaths: TStringArray;
    ExcludedPaths: TStringArray;
  end;

  TTestJobStatus = (tjsPending, tjsCompiling, tjsRunning, tjsPassed,
    tjsCompileFailed, tjsRunFailed, tjsCancelled,
    tjsWorkerError);

  TTestJob = record
    Source: string;
    Binary: string;
    CompileOutput: string;
    RunOutput: string;
    ErrorMessage: string;
    ExitCode: Integer;
    Status: TTestJobStatus;
    StartedAt: QWord;
    ActiveProcessRunner: TLWPTDuplexProcessRunner;
    InventorySuites: Integer;
    InventoryCases: Integer;
  end;

  TTestProgressKind = (tpkStart, tpkTerminal);

  TTestProgressEvent = record
    Kind: TTestProgressKind;
    Source: string;
    CompileOutput: string;
    RunOutput: string;
    ErrorMessage: string;
    ExitCode: Integer;
    Status: TTestJobStatus;
    StartedAt: QWord;
  end;

  TTestScheduler = class;

  TTestWorker = class(TThread)
  private
    FScheduler: TTestScheduler;
  protected
    procedure Execute; override;
  public
    constructor Create(const AScheduler: TTestScheduler);
  end;

  TTestScheduler = class
  private
    FJobs: array of TTestJob;
    FUnitPaths: TStringArray;
    FCompilerArguments: TStringArray;
    FBuildRoot: string;
    FBail: Integer;
    FNextIndex: Integer;
    FFailureCount: Integer;
    FCancelled: Boolean;
    FInternalError: string;
    FCriticalSection: TRTLCriticalSection;
    FBudgetSession: TLWPTWorkerBudgetSession;
    FWorkers: TList;
    FSession: TLWPTBuildSession;
    FCompilerDriver: TLWPTCompilerDriver;
    FProjectRoot: string;
    FVerbose: Boolean;
    FInventory: Boolean;
    FExpectedInventory: TLWPTTestInventory;
    FCompleteDiscovery: Boolean;
    FReporter: TLWPTProgressReporter;
    FCacheContext: TLWPTTestCacheContext;
    FStartedReported: array of Boolean;
    FTerminalReported: array of Boolean;
    function ClaimJob(out AIndex: Integer): Boolean;
    function AcquireLease: TLWPTWorkerLease;
    function StartProcess(const AIndex: Integer;
      const AProcessRunner: TLWPTDuplexProcessRunner;
      const AOptions: TLWPTProcessRunOptions): Boolean;
    procedure FinishProcess(const AIndex: Integer;
      const AProcessRunner: TLWPTDuplexProcessRunner);
    function RunProcess(const AIndex: Integer; const AProcess: TProcess;
      const AStandardInput: string; const ASeparateStandardError: Boolean;
      const ATimeoutMilliseconds: QWord; const AOperationName: string;
      out AStandardOutput, AStandardError: string): Integer;
    procedure SetJobStage(const AIndex: Integer;
      const AStatus: TTestJobStatus;
      const ABinary: string = '');
    procedure SetJobOutput(const AIndex: Integer;
      const ACompileStage: Boolean;
      const AOutput: string);
    procedure CompleteJob(const AIndex: Integer;
      const AStatus: TTestJobStatus; const AExitCode: Integer = 0);
    procedure FailJob(const AIndex: Integer; const AStatus: TTestJobStatus;
      const AExitCode: Integer; const AMessage: string = '');
    procedure SetInventoryCounts(const AIndex, ASuites, ACases: Integer);
    procedure AbortWithError(const AIndex: Integer; const AMessage: string);
    procedure CancelPendingAndActiveLocked;
    function IsCancelled: Boolean;
    procedure RunOne(const AIndex: Integer;
      var ALease: TLWPTWorkerLease);
    function AllJobsTerminal: Boolean;
    function NextProgressEvent(out AEvent: TTestProgressEvent): Boolean;
    procedure PrintProgressEvent(const AEvent: TTestProgressEvent);
  public
    constructor Create(const ATests: TStringList;
      const AUnitPaths: TStringArray;
      const ACompilerArguments: TStringArray; const ABuildRoot: string;
      const AJobs, ABail: Integer;
      const ASession: TLWPTBuildSession; const AProjectRoot: string;
      const AVerbose, AInventory, ACompleteDiscovery: Boolean;
      const AInventoryPath: string;
      const ACompilerDriver: TLWPTCompilerDriver;
      const ACacheContext: TLWPTTestCacheContext);
    destructor Destroy; override;
    procedure Run;
    procedure PrintResults(const AProjectRoot: string; out APassed,
      AFailed, ACompileFailed, ACancelled: Integer);
    function InventoryJSON(const AProjectRoot: string): string;
    procedure ValidateInventory(const AProjectRoot: string);
    property InternalError: string read FInternalError;
    function EffectiveWorkerCount: Integer;
  end;

{ Standard set of directories the discovery walks must NOT descend into. }
function IsExcludedDir(const AName: string): Boolean; inline;
begin
  Result := (AName = LWPT_DIR) or (AName = 'build') or (AName = '.git');
end;

function IsTestSourcePath(const APath: string): Boolean; inline;
begin
  Result := (Length(APath) > 9)
    and SameText(Copy(APath, Length(APath) - 8, 9), '.Test.pas');
end;

procedure CollectTestFiles(const ADir: string; AList: TStringList);
var
  Search: TSearchRec;
  Base: string;
begin
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        if not IsExcludedDir(Search.Name) then
          CollectTestFiles(Base + Search.Name, AList);
      end
      else if IsTestSourcePath(Search.Name) then
        AList.Add(Base + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function SelectorEscapesProject(const ASelector: string): Boolean; inline;
begin
  Result := Pos('/../', '/' + ASelector + '/') > 0;
end;

function TestRelativePath(const AProjectRoot, ATestPath: string): string;
begin
  Result := ExtractRelativePath(
    IncludeTrailingPathDelimiter(AProjectRoot), ATestPath);
  Result := CanonicalPathGlob(Result);
end;

procedure SelectTestFiles(const AProjectRoot: string;
  const ADiscovered: TStringList; const ASelectors: TStrings;
  const ASelected: TStringList);
var
  Canonical, FullPath, RelativePath, Selector: string;
  i, j, MatchCount: Integer;
  IsDirectory, IsFile, IsGlob: Boolean;
begin
  ASelected.CaseSensitive := True;
  if (ASelectors = nil) or (ASelectors.Count = 0) then
  begin
    ASelected.AddStrings(ADiscovered);
    Exit;
  end;

  for i := 0 to ASelectors.Count - 1 do
  begin
    Selector := ASelectors[i];
    Canonical := CanonicalPathGlob(Selector);
    while Copy(Canonical, 1, 2) = './' do Delete(Canonical, 1, 2);
    if Canonical = '' then
      raise ELWPTError.Create('test selector must not be empty');
    if IsAbsoluteFilesystemPath(Canonical)
       or SelectorEscapesProject(Canonical) then
      raise ELWPTError.CreateFmt(
        'test selector "%s" must be project-root-relative', [Selector]);

    IsGlob := PatternHasGlob(Canonical);
    IsDirectory := False;
    IsFile := False;
    FullPath := '';
    if not IsGlob then
    begin
      FullPath := ResolveProjectPath(AProjectRoot, Canonical);
      if not PathContains(AProjectRoot, FullPath) then
        raise ELWPTError.CreateFmt(
          'test selector "%s" must be project-root-relative', [Selector]);
      IsDirectory := DirectoryExists(FullPath);
      IsFile := FileExists(FullPath);
      if not IsDirectory and not IsFile then
        raise ELWPTError.CreateFmt(
          'test selector "%s" does not exist', [Selector]);
      if IsFile and not IsTestSourcePath(FullPath) then
        raise ELWPTError.CreateFmt(
          'test selector "%s" is not a *.Test.pas file', [Selector]);
    end;

    MatchCount := 0;
    for j := 0 to ADiscovered.Count - 1 do
    begin
      RelativePath := TestRelativePath(AProjectRoot, ADiscovered[j]);
      if (IsGlob and MatchPathGlob(RelativePath, Canonical))
         or (IsDirectory and PathContains(FullPath, ADiscovered[j]))
         or (IsFile and SameFileName(FullPath, ADiscovered[j])) then
      begin
        if ASelected.IndexOf(ADiscovered[j]) < 0 then
          ASelected.Add(ADiscovered[j]);
        Inc(MatchCount);
      end;
    end;
    if MatchCount = 0 then
    begin
      if IsGlob then
        raise ELWPTError.CreateFmt(
          'test selector "%s" matched no discovered test files', [Selector])
      else if IsDirectory then
        raise ELWPTError.CreateFmt(
          'test selector "%s" contains no discovered test files', [Selector])
      else
        raise ELWPTError.CreateFmt(
          'test selector "%s" is outside the discovered test inventory',
          [Selector]);
    end;
  end;
  { Match the complete-discovery path's established case-insensitive
    deterministic order after exact-path deduplication. }
  ASelected.CaseSensitive := False;
  ASelected.Sort;
end;

procedure CopyCurrentEnvironment(AEnvironment: TStrings);
begin
  { Concurrent scheduler workers copy here; a direct sweep raced the RTL's
    unsynchronised lazy env count and could hand a test binary a truncated
    environment (see LWPT.Core). }
  AppendProcessEnvironment(AEnvironment);
end;

function TestDisplayPath(const AProjectRoot, ASource: string): string;
  forward;

constructor TTestWorker.Create(const AScheduler: TTestScheduler);
begin
  FScheduler := AScheduler;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TTestWorker.Execute;
var
  Index: Integer;
  Lease: TLWPTWorkerLease;
begin
  Index := -1;
  try
    while FScheduler.ClaimJob(Index) do
    begin
      Lease := FScheduler.AcquireLease;
      if Lease = nil then
      begin
        FScheduler.CompleteJob(Index, tjsCancelled);
        Break;
      end;
      try
        FScheduler.RunOne(Index, Lease);
      finally
        Lease.Free;
      end;
      Index := -1;
    end;
  except
    on E: Exception do
      FScheduler.AbortWithError(Index, E.Message);
  end;
end;

constructor TTestScheduler.Create(const ATests: TStringList;
  const AUnitPaths: TStringArray;
  const ACompilerArguments: TStringArray; const ABuildRoot: string;
  const AJobs, ABail: Integer;
  const ASession: TLWPTBuildSession; const AProjectRoot: string;
  const AVerbose, AInventory, ACompleteDiscovery: Boolean;
  const AInventoryPath: string;
  const ACompilerDriver: TLWPTCompilerDriver;
  const ACacheContext: TLWPTTestCacheContext);
var
  i, Runnable, RequestedWorkers: Integer;
begin
  inherited Create;
  InitCriticalSection(FCriticalSection);
  FCompilerDriver := ACompilerDriver;
  FCacheContext := ACacheContext;
  FWorkers := TList.Create;
  FBuildRoot := ABuildRoot;
  FSession := ASession;
  FProjectRoot := AProjectRoot;
  FVerbose := AVerbose;
  FInventory := AInventory;
  FCompleteDiscovery := ACompleteDiscovery;
  if AInventoryPath <> '' then
    FExpectedInventory := TLWPTTestInventory.Create(AInventoryPath);
  FReporter := TLWPTProgressReporter.Create(ASession, lpsTest);
  FBail := ABail;
  FNextIndex := 0;
  FFailureCount := 0;
  FCancelled := False;
  SetLength(FUnitPaths, Length(AUnitPaths));
  for i := 0 to High(AUnitPaths) do FUnitPaths[i] := AUnitPaths[i];
  SetLength(FCompilerArguments, Length(ACompilerArguments));
  for i := 0 to High(ACompilerArguments) do
    FCompilerArguments[i] := ACompilerArguments[i];
  SetLength(FJobs, ATests.Count);
  SetLength(FStartedReported, ATests.Count);
  SetLength(FTerminalReported, ATests.Count);
  Runnable := 0;
  for i := 0 to ATests.Count - 1 do
  begin
    FJobs[i].Source := ATests[i];
    FReporter.RegisterJob(ObservabilityTestIdentityNamespace + ATests[i],
      TestDisplayPath(AProjectRoot, ATests[i]));
    FJobs[i].Status := tjsPending;
    Inc(Runnable);
  end;
  if Runnable = 0 then Exit;
  if AJobs = 0 then RequestedWorkers := Runnable
  else if AJobs < Runnable then RequestedWorkers := AJobs
  else RequestedWorkers := Runnable;
  FBudgetSession := TLWPTWorkerBudgetSession.Create(NewWorkerSessionId,
    RequestedWorkers);
  for i := 1 to FBudgetSession.RequestedWorkers do
    FWorkers.Add(TTestWorker.Create(Self));
end;

destructor TTestScheduler.Destroy;
var
  i: Integer;
begin
  FExpectedInventory.Free;
  FReporter.Free;
  for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).Free;
  FWorkers.Free;
  FBudgetSession.Free;
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

function TTestScheduler.ClaimJob(out AIndex: Integer): Boolean;
begin
  Result := False;
  AIndex := -1;
  EnterCriticalSection(FCriticalSection);
  try
    if FCancelled then Exit;
    while FNextIndex <= High(FJobs) do
    begin
      AIndex := FNextIndex;
      Inc(FNextIndex);
      if FJobs[AIndex].Status = tjsPending then
      begin
        FJobs[AIndex].Status := tjsCompiling;
        FJobs[AIndex].StartedAt := GetTickCount64;
        Exit(True);
      end;
    end;
    AIndex := -1;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.AcquireLease: TLWPTWorkerLease;
begin
  Result := nil;
  while not IsCancelled do
  begin
    Result := FBudgetSession.Acquire(100);
    if Result <> nil then Exit;
  end;
end;

function TTestScheduler.StartProcess(const AIndex: Integer;
  const AProcessRunner: TLWPTDuplexProcessRunner;
  const AOptions: TLWPTProcessRunOptions): Boolean;
begin
  Result := False;
  EnterCriticalSection(FCriticalSection);
  try
    if FCancelled then Exit;
    FJobs[AIndex].ActiveProcessRunner := AProcessRunner;
    try
      AProcessRunner.Start(AOptions);
    except
      FJobs[AIndex].ActiveProcessRunner := nil;
      raise;
    end;
    Result := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.FinishProcess(const AIndex: Integer;
  const AProcessRunner: TLWPTDuplexProcessRunner);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if FJobs[AIndex].ActiveProcessRunner = AProcessRunner then
      FJobs[AIndex].ActiveProcessRunner := nil;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.RunProcess(const AIndex: Integer;
  const AProcess: TProcess; const AStandardInput: string;
  const ASeparateStandardError: Boolean; const ATimeoutMilliseconds: QWord;
  const AOperationName: string; out AStandardOutput, AStandardError: string):
  Integer;
var
  ProcessRunner: TLWPTDuplexProcessRunner;
  Options: TLWPTProcessRunOptions;
begin
  Result := 1;
  AStandardOutput := '';
  AStandardError := '';
  Options := DefaultProcessRunOptions(AOperationName);
  Options.SeparateStandardError := ASeparateStandardError;
  Options.TimeoutMilliseconds := ATimeoutMilliseconds;
  ProcessRunner := TLWPTDuplexProcessRunner.Create(AProcess);
  try
    if not StartProcess(AIndex, ProcessRunner, Options) then Exit;
    try
      Result := ProcessRunner.Communicate(AStandardInput, Options,
        AStandardOutput, AStandardError);
    finally
      FinishProcess(AIndex, ProcessRunner);
    end;
  finally
    ProcessRunner.Free;
  end;
end;

procedure TTestScheduler.SetJobStage(const AIndex: Integer;
  const AStatus: TTestJobStatus; const ABinary: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if FCancelled then
      FJobs[AIndex].Status := tjsCancelled
    else
    begin
      FJobs[AIndex].Status := AStatus;
      if ABinary <> '' then FJobs[AIndex].Binary := ABinary;
    end;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.SetJobOutput(const AIndex: Integer;
  const ACompileStage: Boolean; const AOutput: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if ACompileStage then FJobs[AIndex].CompileOutput := AOutput
    else FJobs[AIndex].RunOutput := AOutput;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.CompleteJob(const AIndex: Integer;
  const AStatus: TTestJobStatus; const AExitCode: Integer);
begin
  if AIndex < 0 then Exit;
  EnterCriticalSection(FCriticalSection);
  try
    { A real process-tree termination failure is a worker error, not a clean
      cancellation. Preserve it when the reaped worker unwinds afterward. }
    if FJobs[AIndex].Status <> tjsWorkerError then
    begin
      FJobs[AIndex].Status := AStatus;
      FJobs[AIndex].ExitCode := AExitCode;
    end;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.CancelPendingAndActiveLocked;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
  i: Integer;

  procedure RecordCancellationFailure(const AIndex: Integer;
    const AMessage: string);
  begin
    { BeginCancel can fail after forwarding termination. CompleteCancel must
      still run for that runner, but a secondary reap error must not replace
      the first failure that explains why cancellation became unhealthy. }
    if (FJobs[AIndex].Status <> tjsWorkerError)
       or (FJobs[AIndex].ErrorMessage = '') then
    begin
      FJobs[AIndex].Status := tjsWorkerError;
      FJobs[AIndex].ExitCode := ObservabilityInternalErrorExitCode;
      FJobs[AIndex].ErrorMessage := 'process-tree termination failed: '
        + AMessage;
    end;
    if FInternalError = '' then
      FInternalError := FJobs[AIndex].ErrorMessage;
  end;
begin
  FCancelled := True;
  TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
    AcknowledgementDeadline);
  for i := 0 to High(FJobs) do
  begin
    if FJobs[i].Status = tjsPending then
      FJobs[i].Status := tjsCancelled;
    if FJobs[i].ActiveProcessRunner <> nil then
      try
        FJobs[i].ActiveProcessRunner.BeginCancel(DescendantDeadline,
          AcknowledgementDeadline);
      except
        on E: Exception do RecordCancellationFailure(i, E.Message);
      end;
  end;
  for i := 0 to High(FJobs) do
    if FJobs[i].ActiveProcessRunner <> nil then
      try
        FJobs[i].ActiveProcessRunner.CompleteCancel;
      except
        on E: Exception do RecordCancellationFailure(i, E.Message);
      end;
end;

procedure TTestScheduler.FailJob(const AIndex: Integer;
  const AStatus: TTestJobStatus; const AExitCode: Integer;
  const AMessage: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    FJobs[AIndex].Status := AStatus;
    { A compiler driver can report a semantic failure after its process exits
      successfully, for example when the requested artifact is missing. Failed
      observability events require a nonzero code, so reserve the internal
      error code for that zero-exit failure while preserving real child exits. }
    FJobs[AIndex].ExitCode := NormalizeFailureExitCode(AExitCode);
    FJobs[AIndex].ErrorMessage := AMessage;
    Inc(FFailureCount);
    if (FBail > 0) and (FFailureCount >= FBail) then
      CancelPendingAndActiveLocked;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.SetInventoryCounts(const AIndex, ASuites,
  ACases: Integer);
begin
  EnterCriticalSection(FCriticalSection);
  try
    FJobs[AIndex].InventorySuites := ASuites;
    FJobs[AIndex].InventoryCases := ACases;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.AbortWithError(const AIndex: Integer;
  const AMessage: string);
begin
  EnterCriticalSection(FCriticalSection);
  try
    if (AIndex >= 0) and (AIndex <= High(FJobs)) then
    begin
      FJobs[AIndex].Status := tjsWorkerError;
      FJobs[AIndex].ExitCode := ObservabilityInternalErrorExitCode;
      FJobs[AIndex].ErrorMessage := AMessage;
    end;
    if FInternalError = '' then FInternalError := AMessage;
    CancelPendingAndActiveLocked;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.IsCancelled: Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FCancelled;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure SetChildEnvironmentEntry(const AEnvironment: TStrings;
  const AName, AValue: string);
var
  i, Separator: Integer;
  ExistingName: string;
begin
  for i := AEnvironment.Count - 1 downto 0 do
  begin
    Separator := Pos('=', AEnvironment[i]);
    if Separator = 0 then ExistingName := AEnvironment[i]
    else ExistingName := Copy(AEnvironment[i], 1, Separator - 1);
    {$IFDEF MSWINDOWS}
    if SameText(ExistingName, AName) then AEnvironment.Delete(i);
    {$ELSE}
    if ExistingName = AName then AEnvironment.Delete(i);
    {$ENDIF}
  end;
  AEnvironment.Add(AName + '=' + AValue);
end;

function ParseInventoryOutput(const AOutput: string; out ASuites,
  ACases: Integer): Boolean;
var
  Fields, Lines: TStringList;
  Found: Boolean;
  Cases, Suites, i: Integer;
begin
  Result := False;
  ASuites := 0;
  ACases := 0;
  Found := False;
  Fields := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := AOutput;
    Fields.StrictDelimiter := True;
    Fields.Delimiter := #9;
    for i := 0 to Lines.Count - 1 do
      if Copy(Lines[i], 1, Length(TEST_INVENTORY_PREFIX))
         = TEST_INVENTORY_PREFIX then
      begin
        Fields.DelimitedText := Copy(Lines[i],
          Length(TEST_INVENTORY_PREFIX) + 1, MaxInt);
        if (Fields.Count <> 2)
           or not TryStrToInt(Fields[0], Suites)
           or not TryStrToInt(Fields[1], Cases)
           or (Suites < 0) or (Cases < 0) then Exit;
        if Found and ((Suites <> ASuites) or (Cases <> ACases)) then Exit;
        ASuites := Suites;
        ACases := Cases;
        Found := True;
      end;
    Result := Found;
  finally
    Lines.Free;
    Fields.Free;
  end;
end;

function CacheMissDiagnostic(const AReason: string): string;
begin
  if (AReason = 'invalid-reference')
     or (AReason = 'result-manifest-missing')
     or (AReason = 'result-manifest-invalid')
     or (AReason = 'artifact-missing')
     or (AReason = 'artifact-mode-failed')
     or (AReason = 'artifact-set-invalid')
     or (AReason = 'result-kind-mismatch') then
    Result := 'cache corruption: ' + AReason
  else
    Result := 'cache miss: ' + AReason;
end;

procedure TTestScheduler.RunOne(const AIndex: Integer;
  var ALease: TLWPTWorkerLease);
var
  CompilerProcess, TestProcess: TProcess;
  ArtifactSetPath, Binary, CacheDiagnostic, CacheFingerprint, CacheReason,
    InventoryMode, Output, RelativeSource, StandardOutput,
    StandardError: string;
  BuildRequest, NeutralRequest: TLWPTBuildRequest;
  BuildResult: TLWPTBuildResult;
  CachedResult: TLWPTCachedBuildResult;
  ProducerLease: TLWPTProducerLease;
  ProducerSnapshot: TLWPTProducerLeaseSnapshot;
  PublicationRequest: TLWPTBuildPublicationRequest;
  Code, InventorySuites, InventoryCases: Integer;
  LastProgressAt, WaitNow, WaitStartedAt: QWord;
  ReleasingWorkerForWait: Boolean;

  function CaptureFingerprint: string;
  begin
    Result := CaptureBuildCacheFingerprint(FProjectRoot,
      FCacheContext.ManifestPath, FCacheContext.ConfigurationPath, LOCKFILE,
      FCacheContext.ModulesPath, PublicationRequest,
      BUILD_CACHE_OPERATION_TEST_PROGRAM);
  end;

  function ReacquireWorkerLease: Boolean;
  begin
    Result := False;
    while not Assigned(ALease) do
    begin
      if IsCancelled then Exit;
      ALease := AcquireLease;
    end;
    Result := True;
  end;

  function AcceptCachedResult(const ADiagnostic: string): Boolean;
  var
    i: Integer;
  begin
    Result := False;
    if CachedResult.ArtifactKind <> TEST_ARTIFACT_SET_KIND then
    begin
      SysUtils.DeleteFile(ArtifactSetPath);
      CacheReason := 'result-kind-mismatch';
      Exit;
    end;
    BuildResult := DefaultBuildResult;
    BuildResult.Success := True;
    if not MaterializeTestArtifactSet(ArtifactSetPath,
      ExtractFileDir(Binary), BuildResult.Artifacts, CacheReason) then
    begin
      SysUtils.DeleteFile(ArtifactSetPath);
      Exit;
    end;
    SysUtils.DeleteFile(ArtifactSetPath);
    try
      ValidateBuildResult(BuildResult);
      ValidateReportedArtifacts(FCompilerDriver.CompilerID, BuildRequest,
        BuildResult);
    except
      for i := 0 to High(BuildResult.Artifacts) do
        SysUtils.DeleteFile(BuildResult.Artifacts[i].Path);
      raise;
    end;
    CacheDiagnostic := ADiagnostic + ': ' + CacheFingerprint + LineEnding;
    Result := True;
  end;
begin
  ProducerLease := nil;
  ReleasingWorkerForWait := False;
  try
  try
    CompilerProcess := CreatePascalCompilerProcess(FJobs[AIndex].Source,
      FUnitPaths, FCompilerArguments, Binary, BuildRequest, FBuildRoot,
      FCompilerDriver, FCacheContext.ConfigurationPath);
  except
    { A staging path over the compiler's budget fails this one test with
      the explanatory message instead of aborting the whole scheduler. }
    on E: ELWPTError do
    begin
      SetJobOutput(AIndex, True, E.Message);
      FailJob(AIndex, tjsCompileFailed, 1, E.Message);
      Exit;
    end;
  end;

  RelativeSource := TestRelativePath(FProjectRoot, FJobs[AIndex].Source);
  ArtifactSetPath := ExtractFileDir(Binary) + '/cache-tmp/artifact-set';
  NeutralRequest := BuildRequest;
  NeutralRequest.Inputs.EntryPoint := RelativeSource;
  SetLength(NeutralRequest.Inputs.Sources, 1);
  NeutralRequest.Inputs.Sources[0] := RelativeSource;
  NeutralRequest := NeutralBuildCacheRequest(NeutralRequest,
    'test-programs/' + RelativeSource);
  PublicationRequest := Default(TLWPTBuildPublicationRequest);
  PublicationRequest.BuildRequest := NeutralRequest;
  PublicationRequest.CompilerExecutable := FCompilerDriver.ExecutableName;
  PublicationRequest.CompilerArguments := FCompilerDriver.InvocationArguments(
    FCompilerDriver.BuildArguments(NeutralRequest,
      PascalSourceCompilerInvocationOptions(
        FCacheContext.ConfigurationPath)));
  PublicationRequest.ManifestContentHash :=
    FCacheContext.ManifestContentHash;
  PublicationRequest.PublicOutput := 'test-programs/' + RelativeSource;
  PublicationRequest.CompilerImplicitInputs :=
    Copy(FCacheContext.CompilerImplicitInputs, 0,
      Length(FCacheContext.CompilerImplicitInputs));
  SetLength(PublicationRequest.Environment, 1);
  PublicationRequest.Environment[0] := PROJECT_NAME + '_FPC_UNIT_PATHS='
    + GetEnvironmentVariable(PROJECT_NAME + '_FPC_UNIT_PATHS');
  PublicationRequest.WorkspacePaths :=
    Copy(FCacheContext.WorkspacePaths, 0,
      Length(FCacheContext.WorkspacePaths));
  PublicationRequest.ExcludedPaths :=
    Copy(FCacheContext.ExcludedPaths, 0,
      Length(FCacheContext.ExcludedPaths));
  if not FCacheContext.UseCache then
    CacheDiagnostic := 'cache bypass: disabled' + LineEnding
  else if not Assigned(FCacheContext.Cache) then
    CacheDiagnostic := 'cache bypass: unavailable' + LineEnding
  else
  begin
    try
      CacheFingerprint := CaptureFingerprint;
      if FCacheContext.Cache.Materialize(CacheFingerprint, ArtifactSetPath,
           ExtractFileDir(Binary) + '/cache-tmp', CachedResult, CacheReason)
         and AcceptCachedResult('cache hit') then
      begin
        CompilerProcess.Free;
        CompilerProcess := nil;
      end
      else
      begin
        CacheDiagnostic := CacheMissDiagnostic(CacheReason) + ': '
          + CacheFingerprint + LineEnding;
        ProducerLease := FCacheContext.Cache.TryAcquireProducer(
          CacheFingerprint, 'test program "' + RelativeSource + '"');
        if not Assigned(ProducerLease) then
        begin
          ReleasingWorkerForWait := True;
          ALease.Release;
          ReleasingWorkerForWait := False;
          FreeAndNil(ALease);
          WaitStartedAt := GetTickCount64;
          LastProgressAt := WaitStartedAt;
          WriteLn('cache wait: test program "', RelativeSource, '" ',
            CacheFingerprint);
          repeat
            if IsCancelled then
            begin
              CompilerProcess.Free;
              CompleteJob(AIndex, tjsCancelled);
              Exit;
            end;
            Sleep(PRODUCER_LEASE_POLL_MILLISECONDS);
            if FCacheContext.Cache.Materialize(CacheFingerprint,
                 ArtifactSetPath,
                 ExtractFileDir(Binary) + '/cache-tmp', CachedResult, CacheReason) then
            begin
              if not ReacquireWorkerLease then
              begin
                CompilerProcess.Free;
                CompleteJob(AIndex, tjsCancelled);
                Exit;
              end;
              if CaptureFingerprint <> CacheFingerprint then
              begin
                CompilerProcess.Free;
                FailJob(AIndex, tjsCompileFailed, 1,
                  'inputs changed while waiting for cached test program');
                Exit;
              end;
              if AcceptCachedResult('cache wait hit') then
              begin
                CompilerProcess.Free;
                CompilerProcess := nil;
                Break;
              end;
            end;
            ProducerLease := FCacheContext.Cache.TryAcquireProducer(
              CacheFingerprint, 'test program "' + RelativeSource + '"');
            if Assigned(ProducerLease) then
            begin
              if not ReacquireWorkerLease then
              begin
                CompilerProcess.Free;
                FreeAndNil(ProducerLease);
                CompleteJob(AIndex, tjsCancelled);
                Exit;
              end;
              if CaptureFingerprint <> CacheFingerprint then
              begin
                CompilerProcess.Free;
                FreeAndNil(ProducerLease);
                FailJob(AIndex, tjsCompileFailed, 1,
                  'inputs changed while waiting for cached test program');
                Exit;
              end;
              if FCacheContext.Cache.Materialize(CacheFingerprint,
                   ArtifactSetPath,
                   ExtractFileDir(Binary) + '/cache-tmp', CachedResult, CacheReason)
                 and AcceptCachedResult('cache takeover hit') then
              begin
                CompilerProcess.Free;
                CompilerProcess := nil;
                FreeAndNil(ProducerLease);
              end;
              Break;
            end;
            WaitNow := GetTickCount64;
            if WaitNow - LastProgressAt >=
               PRODUCER_LEASE_PROGRESS_MILLISECONDS then
            begin
              if FCacheContext.Cache.ProducerSnapshot(CacheFingerprint,
                   ProducerSnapshot) then
                WriteLn('cache wait: ', ProducerSnapshot.Description,
                  ' (owner ', ProducerSnapshot.ProcessId, ', ',
                  WaitNow - WaitStartedAt, 'ms)')
              else
                WriteLn('cache wait: test program "', RelativeSource, '" (',
                  WaitNow - WaitStartedAt, 'ms)');
              LastProgressAt := WaitNow;
            end;
          until False;
        end;
      end;
    except
      on E: Exception do
      begin
        if ReleasingWorkerForWait then raise;
        FreeAndNil(ProducerLease);
        if not ReacquireWorkerLease then
        begin
          CompilerProcess.Free;
          CompleteJob(AIndex, tjsCancelled);
          Exit;
        end;
        CacheDiagnostic := 'cache bypass: unavailable' + LineEnding;
      end;
    end;
  end;

  if not Assigned(CompilerProcess) then
    SetJobOutput(AIndex, True, CacheDiagnostic)
  else
  try
    try
      Code := RunProcess(AIndex, CompilerProcess,
        FCompilerDriver.BuildStandardInput(BuildRequest),
        FCompilerDriver.SeparateStandardError,
        FCompilerDriver.CompilationTimeoutMilliseconds,
        'compiler "' + FCompilerDriver.CompilerID + '" compile',
        StandardOutput, StandardError);
    finally
      CompilerProcess.Free;
    end;
    Output := CacheDiagnostic
      + FCompilerDriver.DisplayOutput(StandardOutput, StandardError);
    SetJobOutput(AIndex, True, Output);
    BuildResult := FCompilerDriver.NormalizeExecutionResult(BuildRequest, Code,
      StandardOutput, StandardError);
    ValidateReportedArtifacts(FCompilerDriver.CompilerID, BuildRequest,
      BuildResult);
  except
    on E: ELWPTError do
    begin
      FreeAndNil(ProducerLease);
      SetJobOutput(AIndex, True, E.Message);
      FailJob(AIndex, tjsCompileFailed, 1, E.Message);
      Exit;
    end;
  end;
  if IsCancelled then
  begin
    FreeAndNil(ProducerLease);
    CompleteJob(AIndex, tjsCancelled);
    Exit;
  end;
  if not BuildResult.Success then
  begin
    FreeAndNil(ProducerLease);
    FailJob(AIndex, tjsCompileFailed, Code,
      BuildResultErrorMessage(BuildResult));
    Exit;
  end;

  if Assigned(ProducerLease) then
  begin
    try
      if CaptureFingerprint <> CacheFingerprint then
        SetJobOutput(AIndex, True, Output
          + 'cache store skipped: inputs changed during compilation'
          + LineEnding)
      else
      begin
        WriteTestArtifactSet(ExtractFileDir(Binary), ArtifactSetPath,
          BuildResult.Artifacts);
        if FCacheContext.Cache.Store(CacheFingerprint, ArtifactSetPath,
          TEST_ARTIFACT_SET_KIND, BuildArtifactUnixMode(ArtifactSetPath)) then
          SetJobOutput(AIndex, True, Output + 'cache stored: '
            + CacheFingerprint + LineEnding)
        else
          SetJobOutput(AIndex, True, Output
            + 'cache store skipped: shared cache budget cannot admit '
            + 'the complete result' + LineEnding);
        SysUtils.DeleteFile(ArtifactSetPath);
      end;
    except
      on E: Exception do
      begin
        SysUtils.DeleteFile(ArtifactSetPath);
        SetJobOutput(AIndex, True, Output
          + 'cache store skipped: unavailable' + LineEnding);
      end;
    end;
    FreeAndNil(ProducerLease);
  end;

  SetJobStage(AIndex, tjsRunning, Binary);
  if IsCancelled then
  begin
    CompleteJob(AIndex, tjsCancelled);
    Exit;
  end;
  TestProcess := TProcess.Create(nil);
  try
    TestProcess.Executable := Binary;
    CopyCurrentEnvironment(TestProcess.Environment);
    AppendWorkerLeaseEnvironment(TestProcess.Environment, ALease);
    if FInventory or (FExpectedInventory <> nil) then
    begin
      if FInventory then InventoryMode := TEST_INVENTORY_MODE_ONLY
      else InventoryMode := TEST_INVENTORY_MODE_REPORT;
      SetChildEnvironmentEntry(TestProcess.Environment,
        TEST_INVENTORY_ENVIRONMENT, InventoryMode);
      SetChildEnvironmentEntry(TestProcess.Environment,
        TEST_INVENTORY_EXECUTABLE_ENVIRONMENT, Binary);
    end;
    try
      Code := RunProcess(AIndex, TestProcess, '', False, 0,
        'test executable', Output, StandardError);
    except
      try
        ALease.CancelPendingDelegation;
      except
        { Preserve the process failure already unwinding this worker. Session
          teardown remains the bounded fallback for a failed cancellation. }
      end;
      raise;
    end;
    { A child normally consumes the one-shot token during startup. If it never
      does, return the still-pending grant before this live scheduler asks for
      another worker. On a normal process return, cancellation failure remains
      a worker error so a live session cannot strand its remaining queue. }
    ALease.CancelPendingDelegation;
  finally
    TestProcess.Free;
  end;
  SetJobOutput(AIndex, False, Output);
  if Code = 0 then
  begin
    if ParseInventoryOutput(Output, InventorySuites, InventoryCases) then
      SetInventoryCounts(AIndex, InventorySuites, InventoryCases)
    else if FInventory or (FExpectedInventory <> nil) then
    begin
      FailJob(AIndex, tjsRunFailed, 1,
        'test executable did not emit one valid inventory record');
      Exit;
    end;
  end;
  if IsCancelled then
    CompleteJob(AIndex, tjsCancelled)
  else if Code = 0 then
    CompleteJob(AIndex, tjsPassed)
  else
    FailJob(AIndex, tjsRunFailed, Code);
  finally
    FreeAndNil(ProducerLease);
  end;
end;

function TestDisplayPath(const AProjectRoot, ASource: string): string;
begin
  Result := ExtractRelativePath(
    IncludeTrailingPathDelimiter(AProjectRoot), ASource);
end;

function IsTerminalTestStatus(const AStatus: TTestJobStatus): Boolean; inline;
begin
  Result := AStatus in [tjsPassed, tjsCompileFailed, tjsRunFailed,
    tjsCancelled, tjsWorkerError];
end;

function TTestScheduler.AllJobsTerminal: Boolean;
var
  i: Integer;
begin
  Result := False;
  EnterCriticalSection(FCriticalSection);
  try
    for i := 0 to High(FJobs) do
      if not IsTerminalTestStatus(FJobs[i].Status) then Exit;
    Result := True;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

function TTestScheduler.NextProgressEvent(
  out AEvent: TTestProgressEvent): Boolean;
var
  i: Integer;
begin
  AEvent := Default(TTestProgressEvent);
  EnterCriticalSection(FCriticalSection);
  try
    for i := 0 to High(FJobs) do
      if (FJobs[i].StartedAt <> 0)
         and not FStartedReported[i] then
      begin
        FStartedReported[i] := True;
        AEvent.Kind := tpkStart;
        AEvent.Source := FJobs[i].Source;
        AEvent.StartedAt := FJobs[i].StartedAt;
        Exit(True);
      end;
    for i := 0 to High(FJobs) do
      if IsTerminalTestStatus(FJobs[i].Status)
         and not FTerminalReported[i] then
      begin
        FTerminalReported[i] := True;
        AEvent.Kind := tpkTerminal;
        AEvent.Source := FJobs[i].Source;
        AEvent.CompileOutput := FJobs[i].CompileOutput;
        AEvent.RunOutput := FJobs[i].RunOutput;
        AEvent.ErrorMessage := FJobs[i].ErrorMessage;
        AEvent.ExitCode := FJobs[i].ExitCode;
        AEvent.Status := FJobs[i].Status;
        AEvent.StartedAt := FJobs[i].StartedAt;
        Exit(True);
      end;
    Result := False;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTestScheduler.PrintProgressEvent(
  const AEvent: TTestProgressEvent);
var
  Detail, LogOutput, LogReference: string;
  JobEvent: TLWPTJobEvent;
  JobState: TLWPTJobState;
begin
  LogReference := FSession.JobLogReference(
    ObservabilityTestIdentityNamespace + AEvent.Source);
  if AEvent.Kind = tpkStart then
  begin
    JobEvent := TLWPTJobEvent.Create(
      ObservabilityTestIdentityNamespace + AEvent.Source,
      FSession.SessionID, ojsStarted, 0, 0, '', LogReference);
    try
      FReporter.ReportJob(JobEvent, '', '', FVerbose, AEvent.StartedAt);
    finally
      JobEvent.Free;
    end;
    Exit;
  end;
  if (AEvent.Status = tjsCancelled) and (AEvent.StartedAt = 0) then
  begin
    JobEvent := TLWPTJobEvent.Create(
      ObservabilityTestIdentityNamespace + AEvent.Source,
      FSession.SessionID, ojsSkipped, 0, 0,
      'bail threshold reached before start', '');
    try
      FReporter.ReportJob(JobEvent, '', '', FVerbose);
    finally
      JobEvent.Free;
    end;
    Exit;
  end;
  LogOutput := AEvent.CompileOutput + AEvent.RunOutput;
  case AEvent.Status of
    tjsPassed:
      begin
        JobState := ojsPassed;
        Detail := '';
      end;
    tjsCompileFailed:
      begin
        JobState := ojsFailed;
        Detail := 'compile exit ' + IntToStr(AEvent.ExitCode);
      end;
    tjsRunFailed:
      begin
        JobState := ojsFailed;
        Detail := 'exit ' + IntToStr(AEvent.ExitCode);
      end;
    tjsCancelled:
      begin
        JobState := ojsSkipped;
        Detail := 'bail threshold reached';
      end;
    tjsWorkerError:
      begin
        JobState := ojsFailed;
        Detail := 'scheduler error';
      end;
  end;
  JobEvent := TLWPTJobEvent.Create(
    ObservabilityTestIdentityNamespace + AEvent.Source,
    FSession.SessionID, JobState, GetTickCount64 - AEvent.StartedAt,
    AEvent.ExitCode, Detail, LogReference);
  try
    FReporter.ReportJob(JobEvent, LogOutput, AEvent.ErrorMessage, FVerbose);
  finally
    JobEvent.Free;
  end;
end;

function TTestScheduler.EffectiveWorkerCount: Integer;
begin
  Result := FWorkers.Count;
end;

procedure TTestScheduler.Run;
var
  i: Integer;
  Event: TTestProgressEvent;
  InvocationStartedAt, NowTick: QWord;
  HeartbeatEvent: TLWPTHeartbeatEvent;
begin
  InvocationStartedAt := GetTickCount64;
  FReporter.StartHeartbeatClock(InvocationStartedAt, InvocationStartedAt);
  for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).Start;
  try
    repeat
      while NextProgressEvent(Event) do
        if not FInventory then PrintProgressEvent(Event);
      if AllJobsTerminal then Break;
      NowTick := GetTickCount64;
      if (not FInventory) and FReporter.HeartbeatDue(NowTick) then
      begin
        HeartbeatEvent := TLWPTHeartbeatEvent.Create('test',
          FSession.SessionID, NowTick - InvocationStartedAt);
        try
          FReporter.ReportHeartbeat(HeartbeatEvent);
        finally
          HeartbeatEvent.Free;
        end;
      end;
      Sleep(10);
    until False;
  except
    EnterCriticalSection(FCriticalSection);
    try
      CancelPendingAndActiveLocked;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).WaitFor;
    raise;
  end;
  for i := 0 to FWorkers.Count - 1 do TTestWorker(FWorkers[i]).WaitFor;
  while NextProgressEvent(Event) do
    if not FInventory then PrintProgressEvent(Event);
end;

procedure TTestScheduler.PrintResults(const AProjectRoot: string;
  out APassed, AFailed, ACompileFailed, ACancelled: Integer);
var
  i: Integer;
  DisplayPath: string;
begin
  APassed := 0;
  AFailed := 0;
  ACompileFailed := 0;
  ACancelled := 0;
  for i := 0 to High(FJobs) do
  begin
    DisplayPath := ExtractRelativePath(
      IncludeTrailingPathDelimiter(AProjectRoot), FJobs[i].Source);
    Write('  ', DisplayPath, ' ... ');
    case FJobs[i].Status of
      tjsPassed:
        begin
          WriteLn('pass');
          Inc(APassed);
        end;
      tjsCompileFailed:
        begin
          WriteLn('COMPILE FAILED');
          Inc(ACompileFailed);
        end;
      tjsRunFailed:
        begin
          WriteLn('FAIL (exit ', FJobs[i].ExitCode, ')');
          Inc(AFailed);
        end;
      tjsCancelled:
        begin
          WriteLn('cancelled (bail threshold reached)');
          Inc(ACancelled);
        end;
      tjsWorkerError:
        begin
          WriteLn('ERROR (', FJobs[i].ErrorMessage, ')');
          Inc(AFailed);
        end;
    else
      begin
        WriteLn('cancelled');
        Inc(ACancelled);
      end;
    end;
  end;
end;

function TTestScheduler.InventoryJSON(const AProjectRoot: string): string;
var
  i: Integer;
  DisplayPath, Separator: string;
begin
  Result := '{"schema":"' + PROGRAM_NAME
    + '.test-inventory","version":2,"platform":{"os":'
    + JSONString(Platform.GetBuildOS) + ',"architecture":'
    + JSONString(Platform.GetBuildArch) + '},"programs":[';
  Separator := '';
  for i := 0 to High(FJobs) do
  begin
    DisplayPath := CanonicalPathGlob(ExtractRelativePath(
      IncludeTrailingPathDelimiter(AProjectRoot), FJobs[i].Source));
    if FJobs[i].Status <> tjsPassed then
      raise ELWPTError.CreateFmt(
        'test inventory failed for "%s": %s',
        [DisplayPath, FJobs[i].ErrorMessage]);
    Result := Result + Separator + '{"path":' + JSONString(DisplayPath)
      + ',"suites":' + IntToStr(FJobs[i].InventorySuites)
      + ',"cases":' + IntToStr(FJobs[i].InventoryCases) + '}';
    Separator := ',';
  end;
  Result := Result + ']}';
end;

procedure TTestScheduler.ValidateInventory(const AProjectRoot: string);
var
  ExpectedPaths, SeenPaths: TStringList;
  Architecture, DisplayPath, OSName: string;
  ExpectedCases, ExpectedSuites, i: Integer;
begin
  if FExpectedInventory = nil then Exit;
  OSName := Platform.GetBuildOS;
  Architecture := Platform.GetBuildArch;
  FExpectedInventory.ValidatePlatform(OSName, Architecture);
  ExpectedPaths := TStringList.Create;
  SeenPaths := TStringList.Create;
  try
    SeenPaths.CaseSensitive := True;
    for i := 0 to High(FJobs) do
    begin
      DisplayPath := CanonicalPathGlob(ExtractRelativePath(
        IncludeTrailingPathDelimiter(AProjectRoot), FJobs[i].Source));
      SeenPaths.Add(DisplayPath);
      if not FExpectedInventory.Resolve(DisplayPath, OSName, Architecture,
        ExpectedSuites, ExpectedCases) then
        raise ELWPTError.CreateFmt(
          'test inventory is stale: add "%s" for platform %s/%s',
          [DisplayPath, OSName, Architecture]);
      if FJobs[i].Status = tjsPassed then
      begin
        if (FJobs[i].InventorySuites <> ExpectedSuites)
           or (FJobs[i].InventoryCases <> ExpectedCases) then
          raise ELWPTError.CreateFmt(
            'test inventory is stale for "%s" on %s/%s: expected %d '
            + 'suites/%d cases, got %d suites/%d cases; update %s',
            [DisplayPath, OSName, Architecture, ExpectedSuites,
             ExpectedCases, FJobs[i].InventorySuites,
             FJobs[i].InventoryCases, TEST_INVENTORY_PATH]);
      end;
    end;
    if FCompleteDiscovery then
    begin
      FExpectedInventory.Paths(ExpectedPaths);
      for i := 0 to ExpectedPaths.Count - 1 do
        if SeenPaths.IndexOf(ExpectedPaths[i]) < 0 then
          raise ELWPTError.CreateFmt(
            'test inventory is stale: "%s" is not a discovered test program',
            [ExpectedPaths[i]]);
    end;
  finally
    SeenPaths.Free;
    ExpectedPaths.Free;
  end;
end;

{ Test sources become session staging keys the same way build entries do.
  Distinct sources sharing one key would silently share compiler staging —
  the interference the private-session design exists to rule out — so the
  scheduler refuses the run before any worker starts, mirroring the build
  path's FindArtefactDirCollision. }
function FindTestStagingKeyCollision(const ATests: TStringList;
  out AFirst, ASecond: string): Boolean;
var
  i, j: Integer;
begin
  for i := 0 to ATests.Count - 1 do
    for j := i + 1 to ATests.Count - 1 do
      if SameText(BuildSessionPathKey(ATests[i]),
                  BuildSessionPathKey(ATests[j])) then
      begin
        AFirst := ATests[i];
        ASecond := ATests[j];
        Exit(True);
      end;
  Result := False;
end;

procedure AddTestCacheExcludedOutputs(const AMan: TManifest;
  var APaths: TStringArray);
var
  Count, i: Integer;
  OutputPath: string;
begin
  for i := 0 to High(AMan.BuildEntries) do
  begin
    OutputPath := AMan.BuildEntries[i].Output;
    if OutputPath = '' then
      OutputPath := ChangeFileExt(AMan.BuildEntries[i].Source, '');
    {$IFDEF MSWINDOWS}
    if (OutputPath <> '') and (ExtractFileExt(OutputPath) = '') then
      OutputPath := OutputPath + '.exe';
    {$ENDIF}
    if OutputPath = '' then Continue;
    Count := Length(APaths);
    SetLength(APaths, Count + 1);
    APaths[Count] := OutputPath;
  end;
end;

function NeutralProjectPath(const AProjectRoot, APath: string): string;
begin
  if PathContains(AProjectRoot, APath) then
    Result := CanonicalPathGlob(ExtractRelativePath(
      IncludeTrailingPathDelimiter(AProjectRoot), ExpandFileName(APath)))
  else
    Result := APath;
end;

procedure CaptureProjectRootCompilerInputs(const AProjectRoot: string;
  var APaths: TStringArray);
var
  Entries: TStringList;
  FullPath: string;
  Search: TSearchRec;
  i: Integer;
begin
  Entries := TStringList.Create;
  Entries.CaseSensitive := True;
  try
    if FindFirst(IncludeTrailingPathDelimiter(AProjectRoot) + '*',
      faAnyFile or faSymLink, Search) = 0 then
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..')
           or (Search.Name = '.git')
           or ((Search.Attr and faDirectory) <> 0) then Continue;
        FullPath := IncludeTrailingPathDelimiter(AProjectRoot) + Search.Name;
        if not FileExists(FullPath) then Continue;
        Entries.Add(Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    Entries.Sort;
    SetLength(APaths, Entries.Count);
    for i := 0 to Entries.Count - 1 do APaths[i] := Entries[i];
  finally
    Entries.Free;
  end;
end;

function CmdTest(const AManifestPath: string;
  const AJobs, ABail: Integer; const AVerbose, AInventory: Boolean;
  const ASelectors: TStrings; const AUseCache: Boolean): Integer;
begin
  Result := CmdTest(AManifestPath, AJobs, ABail, AVerbose,
    AInventory, ASelectors, nil, AUseCache);
end;

function CmdTest(const AManifestPath: string;
  const AJobs, ABail: Integer; const AVerbose, AInventory: Boolean;
  const ASelectors: TStrings;
  const ACompilerHost: TLWPTCompilerHost; const AUseCache: Boolean): Integer;
const
  TESTS_SUPPORT_DIR = 'tests/support';
var
  Man: TManifest;
  DiscoveredTests, Tests: TStringList;
  UnitPaths: TStringArray;
  ModulesRoot, ProjectRoot, CollisionFirst, CollisionSecond,
    InventoryPath, ManifestContentHash: string;
  i, n, Passed, Failed, CompileFailed, Cancelled,
    EffectiveBail: Integer;
  Session: TLWPTBuildSession;
  Scheduler: TTestScheduler;
  ExpectedInventory: TLWPTTestInventory;
  CompilerSelection: TLWPTCompilerSelection;
  CompilerDriver: TLWPTCompilerDriver;
  TestTarget: TLWPTTarget;
  StartedAt: QWord;
  Cache: TLWPTBuildCache;
  CacheContext: TLWPTTestCacheContext;
begin
  StartedAt := GetTickCount64;
  Passed := 0;
  Failed := 0;
  CompileFailed := 0;
  Cancelled := 0;
  CompilerSelection := nil;
  DiscoveredTests := nil;
  Tests := nil;
  Cache := nil;
  CacheContext := Default(TLWPTTestCacheContext);
  try
    try
      Result := 1;
      Man := LoadManifestSnapshot(AManifestPath, ManifestContentHash);
      if ABail < 0 then EffectiveBail := Man.TestBail
      else EffectiveBail := ABail;
      ProjectRoot := ExtractFileDir(ExpandFileName(AManifestPath));
      InventoryPath := IncludeTrailingPathDelimiter(ProjectRoot)
        + TEST_INVENTORY_PATH;
      if not FileExists(InventoryPath) then InventoryPath := '';

      { Freeze discovery and selection before pretest. A hook may prepare
        inputs for the selected programs, but cannot add programs to this
        invocation after the user-visible scope has been resolved. }
      DiscoveredTests := TStringList.Create;
      Tests := TStringList.Create;
      for i := 0 to High(Man.Units) do
        CollectTestFiles(Man.Units[i], DiscoveredTests);
      CollectTestFiles('.', DiscoveredTests);
      for i := 0 to DiscoveredTests.Count - 1 do
        DiscoveredTests[i] := ExpandFileName(DiscoveredTests[i]);
      DiscoveredTests.Sort;
      i := DiscoveredTests.Count - 1;
      while i > 0 do
      begin
        if DiscoveredTests[i] = DiscoveredTests[i - 1] then
          DiscoveredTests.Delete(i);
        Dec(i);
      end;
      SelectTestFiles(ProjectRoot, DiscoveredTests, ASelectors, Tests);

      CompilerSelection := TLWPTCompilerSelection.Create(Man, ProjectRoot,
        ACompilerHost);
      CompilerDriver := CompilerSelection.DriverFor('');
      TestTarget := CompilerDriver.DefaultTarget;
      if not TestTargetIsHost(TestTarget) then
        raise ELWPTError.CreateFmt(
          'generic test runner requires a host artifact; selected compiler '
          + 'target is "%s/%s" but host is "%s/%s"',
          [TestTarget.OS, TestTarget.Architecture, Platform.GetBuildOS,
           Platform.GetBuildArch]);
      Session := TLWPTBuildSession.Create(ProjectRoot,
        ResolveBuildSessionsRoot(ProjectRoot, ResolveSessionsDir(Man),
          GetCurrentDir));
      try
        if not AInventory then
        begin
          WriteLn('test session: ', Session.SessionID, ' (',
            Session.SessionReference, ')');
          RunHooks('pretest', Man.PreTest, ProjectRoot);
        end;

    ModulesRoot := ResolveModulesDir(Man);
    SetLength(UnitPaths, 0);
    for i := 0 to High(Man.Units) do
    begin
      n := Length(UnitPaths);
      SetLength(UnitPaths, n + 1);
      UnitPaths[n] := Man.Units[i];
    end;
    n := Length(UnitPaths);
    SetLength(UnitPaths, n + 1);
    UnitPaths[n] := ModulesRoot;
    if DirectoryExists(TESTS_SUPPORT_DIR) then
    begin
      n := Length(UnitPaths);
      SetLength(UnitPaths, n + 1);
      UnitPaths[n] := TESTS_SUPPORT_DIR;
    end;

      if Tests.Count = 0 then
      begin
        if InventoryPath <> '' then
        begin
          ExpectedInventory := TLWPTTestInventory.Create(InventoryPath);
          try
            ExpectedInventory.ValidatePlatform(Platform.GetBuildOS,
              Platform.GetBuildArch);
            ExpectedInventory.ValidateEmptyDiscovery;
          finally
            ExpectedInventory.Free;
          end;
        end;
        if AInventory then
          WriteLn('{"schema":"' + PROGRAM_NAME
            + '.test-inventory","version":2,"platform":{"os":'
            + JSONString(Platform.GetBuildOS) + ',"architecture":'
            + JSONString(Platform.GetBuildArch) + '},"programs":[]}')
        else
          WriteLn('no *.Test.pas files found');
        Result := 0;
        if not AInventory then
          RunHooks('posttest', Man.PostTest, ProjectRoot);
        Session.Finish(True);
        Exit;
      end;

      if FindTestStagingKeyCollision(Tests, CollisionFirst,
        CollisionSecond) then
      begin
        WriteLn(ErrOutput, PROGRAM_NAME, ' test: test sources "',
          CollisionFirst, '" and "', CollisionSecond,
          '" map to the same session staging key ',
          BuildSessionPathKey(CollisionFirst), ' — rename one');
        Result := 1;
        Inc(Failed);
        { Mirror the other exit paths: posttest cleanup/reporting hooks
          run even when the scheduler never starts. }
        if not AInventory then
          RunHooks('posttest', Man.PostTest, ProjectRoot);
        Session.Finish(False, 'test staging key collision');
        Exit;
      end;

      CacheContext.UseCache := AUseCache;
      CacheContext.ManifestPath := ExpandFileName(AManifestPath);
      CacheContext.ManifestContentHash := ManifestContentHash;
      CacheContext.ConfigurationPath := ResolveCfgFile(Man);
      CacheContext.ModulesPath := ModulesRoot;
      CaptureProjectRootCompilerInputs(ProjectRoot,
        CacheContext.CompilerImplicitInputs);
      SetLength(CacheContext.WorkspacePaths, Length(Man.Workspaces));
      for i := 0 to High(Man.Workspaces) do
        CacheContext.WorkspacePaths[i] := NeutralProjectPath(ProjectRoot,
          Man.Workspaces[i].Path);
      AddTestCacheExcludedOutputs(Man, CacheContext.ExcludedPaths);
      n := Length(CacheContext.ExcludedPaths);
      SetLength(CacheContext.ExcludedPaths, n + 1);
      CacheContext.ExcludedPaths[n] := Session.SessionsRoot;
      if AUseCache then
        try
          Cache := TLWPTBuildCache.CreateDefault;
        except
          on E: Exception do Cache := nil;
        end;
      CacheContext.Cache := Cache;

      if not AInventory then
      begin
        if (ASelectors <> nil) and (ASelectors.Count > 0) then
          WriteLn('selected ', Tests.Count, ' of ', DiscoveredTests.Count,
            ' discovered test file(s)')
        else
          WriteLn('discovered ', Tests.Count, ' test file(s)');
      end;
      Scheduler := TTestScheduler.Create(Tests, UnitPaths,
        Man.TestFlags, Session.JobRoot('tests'), AJobs, EffectiveBail, Session,
        ProjectRoot, AVerbose, AInventory,
        (ASelectors = nil) or (ASelectors.Count = 0), InventoryPath,
        CompilerDriver, CacheContext);
      try
        if not AInventory then
          WriteLn('effective workers: ', Scheduler.EffectiveWorkerCount);
        Scheduler.Run;
        Scheduler.ValidateInventory(ProjectRoot);
        if AInventory then
        begin
          WriteLn(Scheduler.InventoryJSON(ProjectRoot));
          Passed := Tests.Count;
        end
        else
          Scheduler.PrintResults(ProjectRoot, Passed, Failed, CompileFailed,
            Cancelled);
        if Scheduler.InternalError <> '' then
          WriteLn(ErrOutput, PROGRAM_NAME, ' test: scheduler error: ',
            Scheduler.InternalError);
      finally
        Scheduler.Free;
      end;

      if (Failed = 0) and (CompileFailed = 0) and (Cancelled = 0) then
        Result := 0
      else
        Result := 1;
    if not AInventory then RunHooks('posttest', Man.PostTest, ProjectRoot);
    Session.Finish(Result = 0, IntToStr(Failed) + ' failed, '
      + IntToStr(CompileFailed) + ' did not compile, '
      + IntToStr(Cancelled) + ' cancelled');
      finally
        Session.Free;
      end;
    except
      on E: Exception do
      begin
        Inc(Failed);
        raise;
      end;
    end;
  finally
    Tests.Free;
    DiscoveredTests.Free;
    Cache.Free;
    CompilerSelection.Free;
    if not AInventory then
      WriteLn('summary: ', Passed, ' passed, ', Failed, ' failed, ',
        CompileFailed, ' did not compile, ', Cancelled, ' cancelled; elapsed ',
        FormatElapsedMilliseconds(GetTickCount64 - StartedAt));
  end;
end;

end.
