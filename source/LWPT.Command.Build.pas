{ LWPT.Command.Build — build subcommand entrypoint. }
unit LWPT.Command.Build;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  Process,
  SysUtils,

  LWPT.CompilerRegistry,
  LWPT.Core,
  LWPT.ProcessRunner,
  LWPT.ProcessTree;

type
  { Public so the cross-platform cancellation/reaping contract can be tested
    directly without launching a full build scheduler. }
  TLWPTCompilerProcess = class
  private
    FExecutable: string;
    FWorkingDirectory: string;
    FRunner: TLWPTDuplexProcessRunner;
    FCancelled: Boolean;
    FCriticalSection: TRTLCriticalSection;
  public
    constructor Create(const AExecutable: string = '';
      const AWorkingDirectory: string = '');
    destructor Destroy; override;
    function Run(const AArgs: LWPT.Core.TStringArray;
      out AOutput: string): Integer; overload;
    function Run(const AArgs: LWPT.Core.TStringArray;
      const AStandardInput: string; const ASeparateStandardError: Boolean;
      out AStandardOutput, AStandardError: string): Integer; overload;
    function Run(const AArgs: LWPT.Core.TStringArray;
      const AStandardInput: string; const ASeparateStandardError: Boolean;
      const ATimeoutMilliseconds: QWord; const AOperationName: string;
      out AStandardOutput, AStandardError: string): Integer; overload;
    procedure BeginCancel(const ADescendantDeadline,
      AAcknowledgementDeadline: QWord);
    procedure Cancel;
    procedure CompleteCancel;
  end;

function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer): Integer; overload;
function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose: Boolean): Integer; overload;
function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose: Boolean;
  const ACompilerHost: TLWPTCompilerHost): Integer; overload;
function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose, AUseCache: Boolean;
  const ACompilerHost: TLWPTCompilerHost): Integer; overload;

implementation

uses
  LWPT.BuildCache,
  LWPT.BuildRequest,
  LWPT.BuildSession,
  LWPT.Command.Common,
  LWPT.CompilerDriver,
  LWPT.Manifest,
  LWPT.Observability,
  LWPT.ProgressReporter,
  LWPT.WorkerBudget;

const
  BUILD_ENTRY_ENV = PROJECT_NAME + '_BUILD_ENTRY';
  BUILD_OUTPUT_ENV = PROJECT_NAME + '_BUILD_OUTPUT';
  BUILD_PUBLIC_OUTPUT_ENV = PROJECT_NAME + '_BUILD_PUBLIC_OUTPUT';

type
  TLWPTCompiledEntry = record
    Name: string;
    CandidateBin: string;
    OutBin: string;
    Fingerprint: string;
    CacheFingerprint: string;
    CacheSnapshot: string;
    CacheDiagnostic: string;
    CacheUnixMode: Integer;
    ProjectRoot: string;
    CfgPath: string;
    ModulesPath: string;
    Request: TLWPTBuildPublicationRequest;
    PostBuild: THookArray;
  end;

  TLWPTCompiledEntryArray = array of TLWPTCompiledEntry;

  TLWPTBuildJob = class(TThread)
  private
    FManifestPath: string;
    FManifest: TManifest;
    FManifestContentHash: string;
    FEntry: TLWPTBuildEntry;
    FRelease: Boolean;
    FClean: Boolean;
    FSession: TLWPTBuildSession;
    FLease: TLWPTWorkerLease;
    FDriver: TLWPTCompilerDriver;
    FCompiler: TLWPTCompilerProcess;
    FCache: TLWPTBuildCache;
    FUseCache: Boolean;
    FCompiled: TLWPTCompiledEntry;
    FBuildResult: TLWPTBuildResult;
    FCompilerExitCode: Integer;
    FOutput: string;
    FError: string;
    FCancellationError: string;
    FSucceeded: Boolean;
    FDone: Boolean;
    FDoneCriticalSection: TRTLCriticalSection;
  protected
    procedure Execute; override;
  public
    constructor Create(const AManifestPath: string;
      const AManifest: TManifest; const AManifestContentHash: string;
      const AEntry: TLWPTBuildEntry; const ARelease, AClean: Boolean;
      const ASession: TLWPTBuildSession; const ALease: TLWPTWorkerLease;
      const ADriver: TLWPTCompilerDriver; const ACache: TLWPTBuildCache;
      const AUseCache: Boolean);
    destructor Destroy; override;
    procedure BeginCancel(const ADescendantDeadline,
      AAcknowledgementDeadline: QWord);
    procedure Cancel;
    procedure CompleteCancel;
    function IsDone: Boolean;
    property Compiled: TLWPTCompiledEntry read FCompiled;
    property BuildResult: TLWPTBuildResult read FBuildResult;
    property CompilerExitCode: Integer read FCompilerExitCode;
    property CapturedOutput: string read FOutput;
    property CancellationError: string read FCancellationError;
    property ErrorMessage: string read FError;
    property Succeeded: Boolean read FSucceeded;
  end;

  TLWPTBuildEntryState = (besUnselected, besPending, besRunning, besCompiled,
    besSucceeded, besFailed, besBlocked);

  TLWPTBuildEntryStateArray = array of TLWPTBuildEntryState;
  TLWPTBooleanArray = array of Boolean;
  TLWPTBuildJobArray = array of TLWPTBuildJob;
  TLWPTBuildResultArray = array of TLWPTBuildResult;
  TLWPTStringArray = array of string;

constructor TLWPTCompilerProcess.Create(const AExecutable,
  AWorkingDirectory: string);
begin
  inherited Create;
  FExecutable := AExecutable;
  FWorkingDirectory := AWorkingDirectory;
  FRunner := nil;
  FCancelled := False;
  InitCriticalSection(FCriticalSection);
end;

destructor TLWPTCompilerProcess.Destroy;
begin
  try
    Cancel;
  except
    { Destructors cannot surface cancellation errors safely. The scheduler's
      explicit Cancel path records them before ownership reaches this point. }
  end;
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

{ Each worker owns one compiler process tree. Output is drained while the
  direct process runs and retained by the worker so the scheduler can replay
  it in manifest order. Cancel terminates the whole tree; Run always waits
  before clearing FProcess, so both platforms reap the direct process before
  the worker ends. }
function TLWPTCompilerProcess.Run(const AArgs: LWPT.Core.TStringArray;
  out AOutput: string): Integer;
var
  StandardError: string;
begin
  Result := Run(AArgs, '', False, AOutput, StandardError);
end;

function TLWPTCompilerProcess.Run(const AArgs: LWPT.Core.TStringArray;
  const AStandardInput: string; const ASeparateStandardError: Boolean;
  out AStandardOutput, AStandardError: string): Integer;
begin
  Result := Run(AArgs, AStandardInput, ASeparateStandardError, 0,
    'compiler process', AStandardOutput, AStandardError);
end;

function TLWPTCompilerProcess.Run(const AArgs: LWPT.Core.TStringArray;
  const AStandardInput: string; const ASeparateStandardError: Boolean;
  const ATimeoutMilliseconds: QWord; const AOperationName: string;
  out AStandardOutput, AStandardError: string): Integer;
var
  P: TProcess;
  Runner: TLWPTDuplexProcessRunner;
  Options: TLWPTProcessRunOptions;
  ArgumentIndex: Integer;
begin
  AStandardOutput := '';
  AStandardError := '';
  P := TProcess.Create(nil);
  Runner := nil;
  try
    if FExecutable <> '' then
      P.Executable := FExecutable
    else
      P.Executable := FPCExecutable;
    if FWorkingDirectory <> '' then
      P.CurrentDirectory := FWorkingDirectory;
    for ArgumentIndex := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[ArgumentIndex]);
    Options := DefaultProcessRunOptions(AOperationName);
    Options.SeparateStandardError := ASeparateStandardError;
    Options.TimeoutMilliseconds := ATimeoutMilliseconds;
    Runner := TLWPTDuplexProcessRunner.Create(P);
    EnterCriticalSection(FCriticalSection);
    try
      if FCancelled then
        raise ELWPTError.Create('compiler process cancelled');
      FRunner := Runner;
      try
        Runner.Start(Options);
      except
        FRunner := nil;
        raise;
      end;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    Result := Runner.Communicate(AStandardInput, Options,
      AStandardOutput, AStandardError);
    EnterCriticalSection(FCriticalSection);
    try
      if FCancelled then Result := 1;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
  finally
    EnterCriticalSection(FCriticalSection);
    try
      if FRunner = Runner then FRunner := nil;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    Runner.Free;
    P.Free;
  end;
end;

procedure TLWPTCompilerProcess.Cancel;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
begin
  TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
    AcknowledgementDeadline);
  BeginCancel(DescendantDeadline, AcknowledgementDeadline);
  CompleteCancel;
end;

procedure TLWPTCompilerProcess.BeginCancel(const ADescendantDeadline,
  AAcknowledgementDeadline: QWord);
begin
  EnterCriticalSection(FCriticalSection);
  try
    FCancelled := True;
    if Assigned(FRunner) then FRunner.BeginCancel(ADescendantDeadline,
      AAcknowledgementDeadline);
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TLWPTCompilerProcess.CompleteCancel;
begin
  EnterCriticalSection(FCriticalSection);
  try
    if Assigned(FRunner) then FRunner.CompleteCancel;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

{ Optional version-baking: write a generated .inc with the manifest version.
  Mirrors build.pas GenerateVersionInclude but path + constant prefix come
  from the [version] manifest section. }

procedure GenerateVersionInclude(const AProjectRoot: string;
  const AMan: TManifest);
var
  Lines: TStringList;
  Destination, Pfx, Tmp: string;
begin
  if AMan.VersionIncOut = '' then Exit;   { [version] not configured }
  Destination := AMan.VersionIncOut;
  if (Destination[1] <> '/') and (Destination[1] <> '\')
    and not ((Length(Destination) >= 2) and (Destination[2] = ':')) then
    Destination := ExpandFileName(
      IncludeTrailingPathDelimiter(AProjectRoot) + Destination);
  Pfx := AMan.VersionPrefix;
  if Pfx = '' then Pfx := 'BAKED';
  Lines := TStringList.Create;
  try
    Lines.Add('// Auto-generated by ' + PROGRAM_NAME
      + ' build — do not edit');
    Lines.Add('const');
    Lines.Add('  ' + Pfx + '_VERSION = ''' + AMan.Version + ''';');
    Lines.Add('  ' + Pfx + '_BUILD_DATE = '''
      + FormatDateTime('yyyy-mm-dd', Now) + ''';');
    { Stage beside the include so AtomicReplaceFile can replace it in one
      filesystem operation. Shared .lwpt/tmp is both potentially cross-device
      and may be reclaimed by a concurrent repair. }
    Tmp := MakeTmpPath(ExtractFileDir(Destination),
      '.' + ExtractFileName(Destination) + '-version');
    Lines.SaveToFile(Tmp);
    if not AtomicReplaceFile(Tmp, Destination) then
    begin
      SysUtils.DeleteFile(Tmp);
      raise ELWPTError.CreateFmt(
        'could not atomically generate version include "%s"',
        [Destination]);
    end;
  finally
    Lines.Free;
  end;
  WriteLn('  generated ', AMan.VersionIncOut);
end;

function IsPathReferenceCharacter(AValue: Char): Boolean;
begin
  Result := AValue in ['a'..'z', 'A'..'Z', '0'..'9',
    '_', '-', '.', '/', '\'];
end;

function ReplaceOneOutputReference(const AValue, APublicOutput,
  ACandidateOutput: string): string;
var
  AfterMatch, MatchAt, SearchAt: Integer;
  Prefix, Remaining: string;
begin
  Result := '';
  if (AValue = '') or (APublicOutput = '') then Exit(AValue);
  SearchAt := 1;
  while SearchAt <= Length(AValue) do
  begin
    Remaining := Copy(AValue, SearchAt, MaxInt);
    MatchAt := Pos(APublicOutput, Remaining);
    if MatchAt = 0 then
    begin
      Result := Result + Remaining;
      Exit;
    end;
    Inc(MatchAt, SearchAt - 1);
    AfterMatch := MatchAt + Length(APublicOutput);
    Prefix := Copy(AValue, SearchAt, MatchAt - SearchAt);
    Result := Result + Prefix;
    if ((MatchAt = 1)
        or not IsPathReferenceCharacter(AValue[MatchAt - 1]))
       and ((AfterMatch > Length(AValue))
        or not IsPathReferenceCharacter(AValue[AfterMatch])) then
      Result := Result + ACandidateOutput
    else
      Result := Result + APublicOutput;
    SearchAt := AfterMatch;
  end;
end;

function ReplaceOutputReference(const AValue, APublicOutput,
  ACandidateOutput: string): string;
{$IFDEF MSWINDOWS}
var
  PublicWithoutExtension: string;
{$ENDIF}
begin
  Result := ReplaceOneOutputReference(
    AValue, APublicOutput, ACandidateOutput);
  {$IFDEF MSWINDOWS}
  if SameText(ExtractFileExt(APublicOutput), '.exe') then
  begin
    PublicWithoutExtension := ChangeFileExt(APublicOutput, '');
    Result := ReplaceOneOutputReference(Result, PublicWithoutExtension,
      ACandidateOutput);
  end;
  {$ENDIF}
end;

function RetargetPostBuildHooks(const AHooks: THookArray;
  const APublicOutput, ACandidateOutput: string): THookArray;
var
  i, j: Integer;
begin
  SetLength(Result, Length(AHooks));
  for i := 0 to High(AHooks) do
  begin
    Result[i] := AHooks[i];
    Result[i].Runnable.Command := ReplaceOutputReference(
      AHooks[i].Runnable.Command,
      APublicOutput, ACandidateOutput);
    Result[i].Output := ReplaceOutputReference(AHooks[i].Output,
      APublicOutput, ACandidateOutput);
    Result[i].Runnable.Args := Copy(AHooks[i].Runnable.Args, 0,
      Length(AHooks[i].Runnable.Args));
    for j := 0 to High(Result[i].Runnable.Args) do
      Result[i].Runnable.Args[j] := ReplaceOutputReference(
        Result[i].Runnable.Args[j],
        APublicOutput, ACandidateOutput);
    Result[i].Inputs := Copy(AHooks[i].Inputs, 0, Length(AHooks[i].Inputs));
    for j := 0 to High(Result[i].Inputs) do
      Result[i].Inputs[j] := ReplaceOutputReference(Result[i].Inputs[j],
        APublicOutput, ACandidateOutput);
  end;
end;

procedure AddHookPublicationInputs(const AHooks: THookArray;
  var ARequest: TLWPTBuildPublicationRequest);
var
  i, j, Count: Integer;

  procedure AddDefinition(const AValue: string);
  begin
    Count := Length(ARequest.HookDefinition);
    SetLength(ARequest.HookDefinition, Count + 1);
    ARequest.HookDefinition[Count] := AValue;
  end;

  procedure AddInput(const AValue: string);
  begin
    if AValue = '' then Exit;
    Count := Length(ARequest.HookInputs);
    SetLength(ARequest.HookInputs, Count + 1);
    ARequest.HookInputs[Count] := AValue;
  end;

begin
  for i := 0 to High(AHooks) do
  begin
    AddDefinition(AHooks[i].Name);
    AddDefinition(AHooks[i].Runnable.Command);
    AddDefinition(AHooks[i].Output);
    AddInput(AHooks[i].Runnable.Command);
    for j := 0 to High(AHooks[i].Runnable.Args) do
      AddDefinition(AHooks[i].Runnable.Args[j]);
    for j := 0 to High(AHooks[i].Inputs) do
    begin
      AddDefinition(AHooks[i].Inputs[j]);
      AddInput(AHooks[i].Inputs[j]);
    end;
  end;
end;

{ Build-entry names become session job-directory segments. Reject traversal
  and detect collisions before creating a session. }
function BuildEntryJobSegment(const AEntryName: string): string;
var Safe: string;
begin
  Safe := SanitisePathSegment(AEntryName);
  if (Safe = '') or (Safe = '.') or (Safe = '..') then
    raise ELWPTError.CreateFmt(
      'unsafe build entry name "%s"', [AEntryName]);
  Result := BuildSessionPathKey(AEntryName);
end;

procedure AddDeclaredOutputs(const AMan: TManifest;
  var APaths: TStringArray);
var
  i, Count: Integer;
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

function FindBuildEntryIndex(const AEntries: array of TLWPTBuildEntry;
  const AName: string): Integer; forward;

procedure AddPrerequisiteOutputs(const AMan: TManifest;
  const AEntry: TLWPTBuildEntry; var APaths: TStringArray);
var
  DependencyIndex, i: Integer;
  OutputPath: string;
begin
  SetLength(APaths, Length(AEntry.Depends));
  for i := 0 to High(AEntry.Depends) do
  begin
    DependencyIndex := FindBuildEntryIndex(AMan.BuildEntries,
      AEntry.Depends[i]);
    if DependencyIndex < 0 then Continue;
    OutputPath := AMan.BuildEntries[DependencyIndex].Output;
    if OutputPath = '' then
      OutputPath := ChangeFileExt(
        AMan.BuildEntries[DependencyIndex].Source, '');
    {$IFDEF MSWINDOWS}
    if (OutputPath <> '') and (ExtractFileExt(OutputPath) = '') then
      OutputPath := OutputPath + '.exe';
    {$ENDIF}
    APaths[i] := OutputPath;
  end;
end;

{ Compile one build entry. Returns True on success. }
function BuildOneEntry(const AManifestPath: string; const AMan: TManifest;
  const AManifestContentHash: string;
  const T: TLWPTBuildEntry; ARelease, AClean: Boolean;
  ASession: TLWPTBuildSession; ACompiler: TLWPTCompilerProcess;
  ADriver: TLWPTCompilerDriver; ACache: TLWPTBuildCache;
  const AUseCache: Boolean; out ACompiled: TLWPTCompiledEntry;
  out ABuildResult: TLWPTBuildResult; out AOutput: string;
  out ACompilerExitCode: Integer): Boolean;
var
  FpcArgs : TStringArray;
  OutBin, JobRoot, BinDir, CandidateBin, UnitOutDir, StandardOutput,
    StandardError,
    CacheFingerprint, CacheReason, CacheSnapshot, CacheOutput,
    Fingerprint, ProjectRoot, CfgPath, ModulesPath : string;
  i, FpcExit : Integer;
  Capabilities: TLWPTCompilerCapabilities;
  CachedResult: TLWPTCachedBuildResult;
  Failure: TLWPTCompilerFailure;
  Request: TLWPTBuildPublicationRequest;
  CacheRequest: TLWPTBuildRequest;
  ScanDirs: LWPT.Core.TStringArray;
begin
  ACompiled := Default(TLWPTCompiledEntry);
  ABuildResult := DefaultBuildResult;
  AOutput := '';
  ACompilerExitCode := ObservabilityInternalErrorExitCode;
  if T.Source = '' then
    Exit(False);

  Request := Default(TLWPTBuildPublicationRequest);
  OutBin := T.Output;
  if OutBin = '' then
    OutBin := ChangeFileExt(T.Source, '');
  if T.HasTarget then
    Request.BuildRequest := ADriver.CreateBuildRequestForTarget(T.Source,
      OutBin, T.Target)
  else
    Request.BuildRequest := ADriver.CreateBuildRequest(T.Source, OutBin);
  OutBin := Request.BuildRequest.Outputs.Artifact;
  { Every invocation writes compiler outputs below its unique session.
    The public output path is touched only by PublishBuildArtifact after
    compilation succeeds and the input snapshot is revalidated. }
  if ARelease then
    JobRoot := ASession.JobRoot(T.Name + '-release')
  else
    JobRoot := ASession.JobRoot(T.Name + '-dev');
  BinDir := JobRoot + '/bin';
  UnitOutDir := JobRoot + '/units';
  CandidateBin := BinDir + '/' + ExtractFileName(OutBin);
  ForceDirectories(BinDir);
  ForceDirectories(UnitOutDir);

  ProjectRoot := ExtractFileDir(ExpandFileName(AManifestPath));
  CfgPath := ResolveCfgFile(AMan);
  ModulesPath := ResolveModulesDir(AMan);
  Request.CompilerExecutable := ADriver.ExecutableName;
  Request.CompilerArguments := ADriver.InvocationArguments([]);
  Request.ManifestContentHash := AManifestContentHash;
  Request.PublicOutput := OutBin;
  if ARelease then
  begin
    Request.BuildRequest.Mode := BUILD_MODE_RELEASE;
    SetLength(Request.BuildRequest.Inputs.Defines, 1);
    Request.BuildRequest.Inputs.Defines[0] := 'PRODUCTION';
  end
  else
    Request.BuildRequest.Mode := BUILD_MODE_DEV;
  Request.BuildRequest.Outputs.Artifact := CandidateBin;
  Request.BuildRequest.Outputs.ExecutableDirectory := BinDir;
  Request.BuildRequest.Outputs.UnitDirectory := UnitOutDir;
  Request.BuildRequest.Outputs.ObjectDirectory := UnitOutDir;
  { Only environment that changes the effective compiler request belongs in
    the reusable fingerprint. Scheduler leases, terminal state, temporary
    directories, and other inherited process state must not turn every build
    into a cache miss. Target selection is already represented by the neutral
    target tuple and compiler discovery by the executable plus live version. }
  SetLength(Request.Environment, 1);
  Request.Environment[0] := PROJECT_NAME + '_FPC_UNIT_PATHS='
    + GetEnvironmentVariable(PROJECT_NAME + '_FPC_UNIT_PATHS');
  Request.BuildRequest.Inputs.UnitPaths :=
    Copy(AMan.Units, 0, Length(AMan.Units));
  Request.BuildRequest.Inputs.IncludePaths :=
    Copy(AMan.Includes, 0, Length(AMan.Includes));
  Request.BuildRequest.Inputs.ExtraArguments :=
    Copy(T.Flags, 0, Length(T.Flags));
  SetLength(Request.WorkspacePaths, Length(AMan.Workspaces));
  for i := 0 to High(AMan.Workspaces) do
    Request.WorkspacePaths[i] := AMan.Workspaces[i].Path;
  AddPrerequisiteOutputs(AMan, T, Request.PrerequisiteOutputs);
  AddHookPublicationInputs(T.PostBuild, Request);
  AddHookPublicationInputs(AMan.PostBuild, Request);
  ACompiled.PostBuild := RetargetPostBuildHooks(T.PostBuild,
    OutBin, CandidateBin);
  AppendCompilerEnvironmentSearchPaths(Request.BuildRequest.Inputs.UnitPaths,
    Request.BuildRequest.Inputs.IncludePaths);
  AddDeclaredOutputs(AMan, Request.ExcludedPaths);
  i := Length(Request.ExcludedPaths);
  SetLength(Request.ExcludedPaths, i + 1);
  Request.ExcludedPaths[i] := ASession.SessionsRoot;
  ValidateBuildRequest(Request.BuildRequest);
  { A cached default-target discovery never substitutes for live validation
    of the concrete operation. }
  Capabilities := ADriver.ProbeCapabilities(Request.BuildRequest.Target, True);
  EnsureBuildRequestCompatible(Request.BuildRequest, Capabilities);
  Request.BuildRequest.Compiler.VersionIdentity :=
    Capabilities.VersionIdentity;
  CacheRequest := NeutralBuildCacheRequest(Request.BuildRequest, OutBin);
  Request.CompilerArguments := ADriver.InvocationArguments(
    ADriver.BuildArguments(CacheRequest,
      BuildCompilerInvocationOptions(CfgPath, False)));
  { The cfg reaches FPC unexpanded (@file), so its -Fu lines are read
    through the same shared extractor the test flow uses. }
  ScanDirs := Copy(Request.BuildRequest.Inputs.UnitPaths, 0,
    Length(Request.BuildRequest.Inputs.UnitPaths));
  AppendUnitDirsFromCfg(ResolveCfgFile(AMan), ScanDirs);
  EnsureCompilerPathBudget(UnitOutDir, BinDir,
    LongestCompiledBaseNameLength(ScanDirs, T.Source));
  Fingerprint := CaptureBuildPublicationFingerprint(ProjectRoot,
    AManifestPath, CfgPath, LOCKFILE, ModulesPath, Request);
  CacheFingerprint := CaptureBuildCacheFingerprint(ProjectRoot,
    AManifestPath, CfgPath, LOCKFILE, ModulesPath, Request);

  if not AUseCache then CacheReason := 'disabled'
  else if AClean then CacheReason := 'clean'
  else if AUseCache and Assigned(ACache) then
    try
      if ACache.Materialize(CacheFingerprint, CandidateBin,
        JobRoot + '/cache-tmp', CachedResult, CacheReason) then
      begin
        if CachedResult.ArtifactKind <> Request.BuildRequest.OutputKind then
        begin
          SysUtils.DeleteFile(CandidateBin);
          CacheReason := 'result-kind-mismatch';
        end
        else
        begin
          ABuildResult := DefaultBuildResult;
          ABuildResult.Success := True;
          SetLength(ABuildResult.Artifacts, 1);
          ABuildResult.Artifacts[0].Kind := CachedResult.ArtifactKind;
          ABuildResult.Artifacts[0].Path := CandidateBin;
          ABuildResult.Artifacts[0].Digest := CachedResult.ArtifactDigest;
          ValidateBuildResult(ABuildResult);
          ValidateReportedArtifacts(ADriver.CompilerID,
            Request.BuildRequest, ABuildResult);
          ACompilerExitCode := 0;
          AOutput := 'cache hit: ' + CacheFingerprint + LineEnding;
          ACompiled.Name := T.Name;
          ACompiled.CandidateBin := CandidateBin;
          ACompiled.OutBin := OutBin;
          ACompiled.Fingerprint := Fingerprint;
          ACompiled.CacheFingerprint := CacheFingerprint;
          ACompiled.CacheDiagnostic := 'cache hit';
          ACompiled.ProjectRoot := ProjectRoot;
          ACompiled.CfgPath := CfgPath;
          ACompiled.ModulesPath := ModulesPath;
          ACompiled.Request := Request;
          ACompiled.PostBuild := RetargetPostBuildHooks(T.PostBuild,
            OutBin, CandidateBin);
          Exit(True);
        end;
      end;
    except
      on E: Exception do CacheReason := 'unavailable';
    end
  else if AUseCache then CacheReason := 'unavailable';
  CacheOutput := 'cache miss: ' + CacheReason + LineEnding;

  FpcArgs := ADriver.InvocationArguments(ADriver.BuildArguments(
    Request.BuildRequest, BuildCompilerInvocationOptions(CfgPath, AClean)));

  FpcExit := ACompiler.Run(FpcArgs,
    ADriver.BuildStandardInput(Request.BuildRequest),
    ADriver.SeparateStandardError,
    ADriver.CompilationTimeoutMilliseconds,
    'compiler "' + ADriver.CompilerID + '" compile',
    StandardOutput, StandardError);
  ACompilerExitCode := FpcExit;
  AOutput := CacheOutput
    + ADriver.DisplayOutput(StandardOutput, StandardError);
  ABuildResult := ADriver.NormalizeExecutionResult(Request.BuildRequest,
    FpcExit, StandardOutput, StandardError);
  ValidateReportedArtifacts(ADriver.CompilerID, Request.BuildRequest,
    ABuildResult);
  Result := ABuildResult.Success;

  if not Result then
  begin
    Failure := ADriver.ClassifyFailure(FpcExit, AOutput);
    AOutput := AOutput + LineEnding + Failure.Summary + LineEnding;
  end;

  if Result then
  begin
    ACompiled.Name := T.Name;
    ACompiled.CandidateBin := CandidateBin;
    ACompiled.OutBin := OutBin;
    ACompiled.Fingerprint := Fingerprint;
    ACompiled.CacheFingerprint := CacheFingerprint;
    ACompiled.CacheDiagnostic := 'cache miss: ' + CacheReason;
    ACompiled.CacheUnixMode := BuildArtifactUnixMode(CandidateBin);
    CacheSnapshot := JobRoot + '/cache-artifact/'
      + ExtractFileName(CandidateBin);
    ForceDirectories(ExtractFileDir(CacheSnapshot));
    if CopyFileContent(CandidateBin, CacheSnapshot) then
      ACompiled.CacheSnapshot := CacheSnapshot;
    ACompiled.ProjectRoot := ProjectRoot;
    ACompiled.CfgPath := CfgPath;
    ACompiled.ModulesPath := ModulesPath;
    ACompiled.Request := Request;
  end;

  if (not Result) and (not AClean)
     and (Failure.Kind = cfkStaleArtefact) then
  begin
    AOutput := AOutput + LineEnding
      + '  ' + Failure.Recovery
      + LineEnding + '  retry with: ' + PROGRAM_NAME + ' build '
      + T.Name + ' --clean' + LineEnding;
  end;
end;

constructor TLWPTBuildJob.Create(const AManifestPath: string;
  const AManifest: TManifest; const AManifestContentHash: string;
  const AEntry: TLWPTBuildEntry; const ARelease, AClean: Boolean;
  const ASession: TLWPTBuildSession; const ALease: TLWPTWorkerLease;
  const ADriver: TLWPTCompilerDriver; const ACache: TLWPTBuildCache;
  const AUseCache: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FManifestPath := AManifestPath;
  FManifest := AManifest;
  FManifestContentHash := AManifestContentHash;
  FEntry := AEntry;
  FRelease := ARelease;
  FClean := AClean;
  FSession := ASession;
  FLease := ALease;
  FDriver := ADriver;
  FCache := ACache;
  FUseCache := AUseCache;
  FCompiler := TLWPTCompilerProcess.Create(FDriver.ExecutableName,
    FDriver.WorkingDirectory);
  FCompiled := Default(TLWPTCompiledEntry);
  FBuildResult := DefaultBuildResult;
  FCompilerExitCode := ObservabilityInternalErrorExitCode;
  FOutput := '';
  FError := '';
  FSucceeded := False;
  FDone := False;
  InitCriticalSection(FDoneCriticalSection);
end;

destructor TLWPTBuildJob.Destroy;
begin
  { Execute releases and nils FLease at the end of every run, so a lease
    still attached here belongs to a job whose thread never started.
    Destroying it returns the worker grant. }
  FLease.Free;
  FCompiler.Free;
  DoneCriticalSection(FDoneCriticalSection);
  inherited Destroy;
end;

procedure TLWPTBuildJob.Execute;
begin
  try
    try
      FSucceeded := BuildOneEntry(FManifestPath, FManifest,
        FManifestContentHash, FEntry, FRelease, FClean, FSession,
        FCompiler, FDriver, FCache, FUseCache, FCompiled, FBuildResult, FOutput,
        FCompilerExitCode);
      if (not FSucceeded) and (FError = '') then
        if FEntry.Source = '' then
          FError := 'build entry has no source'
        else
          FError := 'compiler failed';
    except
      on E: Exception do
      begin
        FSucceeded := False;
        FError := E.Message;
      end;
    end;
  finally
    if Assigned(FLease) then
    begin
      try
        try
          FLease.Release;
        except
          on E: Exception do
          begin
            FSucceeded := False;
            if FError = '' then
              FError := 'worker lease release failed: ' + E.Message;
          end;
        end;
        try
          FreeAndNil(FLease);
        except
          on E: Exception do
          begin
            FSucceeded := False;
            if FError = '' then
              FError := 'worker lease cleanup failed: ' + E.Message;
          end;
        end;
      finally
        FLease := nil;
      end;
    end;
    EnterCriticalSection(FDoneCriticalSection);
    try
      FDone := True;
    finally
      LeaveCriticalSection(FDoneCriticalSection);
    end;
  end;
end;

procedure TLWPTBuildJob.Cancel;
var
  AcknowledgementDeadline, DescendantDeadline: QWord;
begin
  TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
    AcknowledgementDeadline);
  BeginCancel(DescendantDeadline, AcknowledgementDeadline);
  CompleteCancel;
end;

procedure TLWPTBuildJob.BeginCancel(const ADescendantDeadline,
  AAcknowledgementDeadline: QWord);
var
  CancellationMessage: string;
begin
  Terminate;
  try
    FCompiler.BeginCancel(ADescendantDeadline, AAcknowledgementDeadline);
  except
    on E: Exception do
    begin
      CancellationMessage := 'process-tree termination failed: ' + E.Message;
      EnterCriticalSection(FDoneCriticalSection);
      try
        FCancellationError := CancellationMessage;
        FSucceeded := False;
        if FError = '' then FError := CancellationMessage;
      finally
        LeaveCriticalSection(FDoneCriticalSection);
      end;
    end;
  end;
end;

procedure TLWPTBuildJob.CompleteCancel;
var
  CancellationMessage: string;
begin
  try
    FCompiler.CompleteCancel;
  except
    on E: Exception do
    begin
      CancellationMessage := 'process-tree termination failed: ' + E.Message;
      EnterCriticalSection(FDoneCriticalSection);
      try
        FCancellationError := CancellationMessage;
        FSucceeded := False;
        if FError = '' then FError := CancellationMessage;
      finally
        LeaveCriticalSection(FDoneCriticalSection);
      end;
    end;
  end;
end;

function TLWPTBuildJob.IsDone: Boolean;
begin
  EnterCriticalSection(FDoneCriticalSection);
  try
    Result := FDone;
  finally
    LeaveCriticalSection(FDoneCriticalSection);
  end;
end;

{ Two build-entry names that sanitise to the same session job segment would
  share private output within one invocation. }
function FindArtefactDirCollision(const AEntries: array of TLWPTBuildEntry;
  out AFirst, ASecond: string): Boolean;
var i, j: Integer;
begin
  for i := 0 to High(AEntries) do
    for j := i + 1 to High(AEntries) do
      if SameText(BuildEntryJobSegment(AEntries[i].Name),
                  BuildEntryJobSegment(AEntries[j].Name)) then
      begin
        AFirst  := AEntries[i].Name;
        ASecond := AEntries[j].Name;
        Exit(True);
      end;
  Result := False;
end;

function FindBuildEntryIndex(const AEntries: array of TLWPTBuildEntry;
  const AName: string): Integer;
var i: Integer;
begin
  for i := 0 to High(AEntries) do
    if SameText(AEntries[i].Name, AName) then Exit(i);
  Result := -1;
end;

procedure ValidateBuildGraph(const AEntries: array of TLWPTBuildEntry);
var
  VisitState: array of Byte;
  i: Integer;

  procedure Visit(AIndex: Integer);
  var j, DependencyIndex: Integer;
  begin
    if VisitState[AIndex] = 2 then Exit;
    if VisitState[AIndex] = 1 then
      raise EManifestError.CreateFmt(
        '[build] dependency cycle reaches entry "%s"',
        [AEntries[AIndex].Name]);
    VisitState[AIndex] := 1;
    for j := 0 to High(AEntries[AIndex].Depends) do
    begin
      DependencyIndex := FindBuildEntryIndex(AEntries,
        AEntries[AIndex].Depends[j]);
      if DependencyIndex < 0 then
        raise EManifestError.CreateFmt(
          '[build] entry "%s" depends on unknown entry "%s"',
          [AEntries[AIndex].Name, AEntries[AIndex].Depends[j]]);
      Visit(DependencyIndex);
    end;
    VisitState[AIndex] := 2;
  end;

begin
  SetLength(VisitState, Length(AEntries));
  for i := 0 to High(AEntries) do Visit(i);
end;

procedure SelectBuildEntryClosure(const AEntries: array of TLWPTBuildEntry;
  const ARequestedNames: array of string; var ASelected: TLWPTBooleanArray);
var i: Integer;

  procedure Select(AIndex: Integer);
  var j, DependencyIndex: Integer;
  begin
    if ASelected[AIndex] then Exit;
    ASelected[AIndex] := True;
    for j := 0 to High(AEntries[AIndex].Depends) do
    begin
      DependencyIndex := FindBuildEntryIndex(AEntries,
        AEntries[AIndex].Depends[j]);
      Select(DependencyIndex);
    end;
  end;

begin
  SetLength(ASelected, Length(AEntries));
  if Length(ARequestedNames) = 0 then
    for i := 0 to High(AEntries) do Select(i)
  else
    for i := 0 to High(ARequestedNames) do
      Select(FindBuildEntryIndex(AEntries, ARequestedNames[i]));
end;

function SelectedGraphHasEdges(const AEntries: array of TLWPTBuildEntry;
  const ASelected: TLWPTBooleanArray): Boolean;
var i: Integer;
begin
  for i := 0 to High(AEntries) do
    if ASelected[i] and (Length(AEntries[i].Depends) > 0) then Exit(True);
  Result := False;
end;

function DependenciesSucceeded(const AEntry: TLWPTBuildEntry;
  const AEntries: array of TLWPTBuildEntry;
  const AStates: TLWPTBuildEntryStateArray): Boolean;
var i, DependencyIndex: Integer;
begin
  for i := 0 to High(AEntry.Depends) do
  begin
    DependencyIndex := FindBuildEntryIndex(AEntries, AEntry.Depends[i]);
    if AStates[DependencyIndex] <> besSucceeded then Exit(False);
  end;
  Result := True;
end;

function FailedDependency(const AEntry: TLWPTBuildEntry;
  const AEntries: array of TLWPTBuildEntry;
  const AStates: TLWPTBuildEntryStateArray; out AName: string): Boolean;
var i, DependencyIndex: Integer;
begin
  for i := 0 to High(AEntry.Depends) do
  begin
    DependencyIndex := FindBuildEntryIndex(AEntries, AEntry.Depends[i]);
    if AStates[DependencyIndex] in [besFailed, besBlocked] then
    begin
      AName := AEntries[DependencyIndex].Name;
      Exit(True);
    end;
  end;
  Result := False;
end;

function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer): Integer;
begin
  Result := CmdBuild(AManifestPath, AEntryNames, ARelease, AClean,
    AJobs, False);
end;

function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose: Boolean): Integer;
begin
  Result := CmdBuild(AManifestPath, AEntryNames, ARelease, AClean,
    AJobs, AVerbose, nil);
end;

function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose: Boolean;
  const ACompilerHost: TLWPTCompilerHost): Integer;
begin
  Result := CmdBuild(AManifestPath, AEntryNames, ARelease, AClean,
    AJobs, AVerbose, True, ACompilerHost);
end;

function CmdBuild(const AManifestPath: string;
  const AEntryNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose, AUseCache: Boolean;
  const ACompilerHost: TLWPTCompilerHost): Integer;
var
  Man : TManifest;
  i, j, Built, Failed, Skipped, Unknown, SelectedCount, MaxJobs, Running,
    Completed : Integer;
  Matched : Boolean;
  ModeStr, CollA, CollB, DependencyName, ProjectRoot : string;
  ManifestContentHash: string;
  Session: TLWPTBuildSession;
  WorkerSession: TLWPTWorkerBudgetSession;
  Lease: TLWPTWorkerLease;
  Selected: TLWPTBooleanArray;
  States: TLWPTBuildEntryStateArray;
  Jobs: TLWPTBuildJobArray;
  BuildResults: TLWPTBuildResultArray;
  CompilerExitCodes: array of Integer;
  Compiled: TLWPTCompiledEntryArray;
  CapturedOutputs, Errors: TLWPTStringArray;
  PublicationRequest: TLWPTBuildPublicationRequest;
  PublicationResult: TLWPTBuildPublicationResult;
  CompilerSelection: TLWPTCompilerSelection;
  EntryDrivers: array of TLWPTCompilerDriver;
  CurrentCompilerCapabilities: TLWPTCompilerCapabilities;
  WholePostBuild: THookArray;
  HookEnvironment: array of string;
  HasEdges, MadeProgress: Boolean;
  StartedAt, NowTick: QWord;
  StartTicks: array of QWord;
  Reported: array of Boolean;
  Reporter: TLWPTProgressReporter;
  HeartbeatEvent: TLWPTHeartbeatEvent;
  Cache: TLWPTBuildCache;

  function LogIdentity(const AIndex: Integer): string;
  begin
    Result := ObservabilityBuildIdentityNamespace + Man.BuildEntries[AIndex].Name;
  end;

  procedure PrintStart(const AIndex: Integer);
  var
    Event: TLWPTJobEvent;
  begin
    StartTicks[AIndex] := GetTickCount64;
    Event := TLWPTJobEvent.Create(LogIdentity(AIndex), Session.SessionID,
      ojsStarted, 0, 0, Man.BuildEntries[AIndex].Source,
      Session.JobLogReference(LogIdentity(AIndex)));
    try
      Reporter.ReportJob(Event, '', '', AVerbose, StartTicks[AIndex]);
    finally
      Event.Free;
    end;
  end;

  procedure PrintTerminal(const AIndex: Integer);
  var
    Detail, LogOutput, LogReference: string;
    Event: TLWPTJobEvent;
    EventState: TLWPTJobState;
    EventExitCode: Integer;
  begin
    if Reported[AIndex] then Exit;
    if not (States[AIndex] in [besSucceeded, besFailed, besBlocked]) then Exit;
    Reported[AIndex] := True;
    LogOutput := CapturedOutputs[AIndex];
    if (LogOutput = '') and (Errors[AIndex] <> '') then
      LogOutput := Errors[AIndex] + LineEnding;
    LogReference := Session.JobLogReference(LogIdentity(AIndex));
    case States[AIndex] of
      besSucceeded:
        begin
          EventState := ojsPassed;
          EventExitCode := 0;
          Detail := Compiled[AIndex].OutBin;
        end;
      besFailed:
        begin
          EventState := ojsFailed;
          EventExitCode := NormalizeFailureExitCode(
            CompilerExitCodes[AIndex]);
          Detail := '';
        end;
      besBlocked:
        begin
          EventState := ojsSkipped;
          EventExitCode := 0;
          Detail := Errors[AIndex];
        end;
    end;
    Event := TLWPTJobEvent.Create(LogIdentity(AIndex), Session.SessionID,
      EventState, GetTickCount64 - StartTicks[AIndex], EventExitCode, Detail,
      LogReference);
    try
      Reporter.ReportJob(Event, LogOutput, Errors[AIndex], AVerbose);
    finally
      Event.Free;
    end;
  end;

  procedure RunEntryPostBuild(const AIndex: Integer);
  begin
    SetLength(HookEnvironment, 3);
    HookEnvironment[0] := BUILD_ENTRY_ENV + '=' + Compiled[AIndex].Name;
    HookEnvironment[1] := BUILD_OUTPUT_ENV + '='
      + Compiled[AIndex].CandidateBin;
    HookEnvironment[2] := BUILD_PUBLIC_OUTPUT_ENV + '='
      + Compiled[AIndex].OutBin;
    RunHooksWithEnvironment('postbuild:' + Man.BuildEntries[AIndex].Name,
      Compiled[AIndex].PostBuild, ProjectRoot, HookEnvironment);
  end;

  function AcquireWorkerLease: TLWPTWorkerLease;
  var
    LastWaitReport, WaitStartedAt, WaitTick: QWord;
    WaitEvent: TLWPTHeartbeatEvent;
  begin
    Result := nil;
    WaitStartedAt := GetTickCount64;
    LastWaitReport := WaitStartedAt;
    while Result = nil do
    begin
      Result := WorkerSession.Acquire(100);
      if Assigned(Result) then Break;
      WaitTick := GetTickCount64;
      if WaitTick - LastWaitReport >=
         Reporter.HeartbeatIntervalMilliseconds then
      begin
        WaitEvent := TLWPTHeartbeatEvent.Create('build:postbuild-capacity',
          Session.SessionID, WaitTick - WaitStartedAt);
        try
          Reporter.ReportWaitHeartbeat(WaitEvent,
            'waiting for postbuild worker capacity', WaitTick);
        finally
          WaitEvent.Free;
        end;
        LastWaitReport := WaitTick;
      end;
    end;
  end;

  procedure RunEntryPostBuildWithLease(const AIndex: Integer);
  var
    PostBuildLease: TLWPTWorkerLease;
  begin
    if Length(Compiled[AIndex].PostBuild) = 0 then Exit;
    PostBuildLease := AcquireWorkerLease;
    try
      RunEntryPostBuild(AIndex);
    finally
      PostBuildLease.Free;
    end;
  end;

  procedure RunWholePostBuildWithLease(const AHooks: THookArray);
  var
    PostBuildLease: TLWPTWorkerLease;
  begin
    if Length(AHooks) = 0 then Exit;
    PostBuildLease := AcquireWorkerLease;
    try
      RunHooks('postbuild', AHooks, ProjectRoot);
    finally
      PostBuildLease.Free;
    end;
  end;

  procedure FinalizeEntry(const AIndex: Integer;
    const ARunPostBuild: Boolean);
  var
    FinalizationLease: TLWPTWorkerLease;
  begin
    FinalizationLease := nil;
    try
      FinalizationLease := AcquireWorkerLease;
      try
        if ARunPostBuild then RunEntryPostBuild(AIndex);
        PublicationRequest := Compiled[AIndex].Request;
        CurrentCompilerCapabilities := EntryDrivers[AIndex].ProbeCapabilities(
          PublicationRequest.BuildRequest.Target, True);
        EnsureBuildRequestCompatible(PublicationRequest.BuildRequest,
          CurrentCompilerCapabilities);
        PublicationResult := PublishBuildArtifact(
          Compiled[AIndex].ProjectRoot, Compiled[AIndex].CandidateBin,
          Compiled[AIndex].OutBin, Compiled[AIndex].Fingerprint,
          AManifestPath, Compiled[AIndex].CfgPath, LOCKFILE,
          Compiled[AIndex].ModulesPath, PublicationRequest,
          Session.SessionsRoot);
        if PublicationResult = bprStale then
        begin
          States[AIndex] := besFailed;
          Errors[AIndex] := 'inputs changed during compilation; private '
            + 'result was not published';
          Inc(Failed);
        end
        else
        begin
          if AUseCache and Assigned(Cache)
             and (Compiled[AIndex].CacheSnapshot <> '') then
            try
              Cache.Store(Compiled[AIndex].CacheFingerprint,
                Compiled[AIndex].CacheSnapshot,
                PublicationRequest.BuildRequest.OutputKind,
                Compiled[AIndex].CacheUnixMode);
              CapturedOutputs[AIndex] := CapturedOutputs[AIndex]
                + 'cache stored: ' + Compiled[AIndex].CacheFingerprint
                + LineEnding;
            except
              on E: Exception do
                CapturedOutputs[AIndex] := CapturedOutputs[AIndex]
                  + 'cache store skipped: unavailable' + LineEnding;
            end;
          States[AIndex] := besSucceeded;
          Inc(Built);
        end;
      except
        on E: Exception do
        begin
          States[AIndex] := besFailed;
          Errors[AIndex] := E.Message;
          Inc(Failed);
        end;
      end;
    finally
      FinalizationLease.Free;
    end;
  end;

  procedure StopAndFreeJobs;
  var
    AcknowledgementDeadline, DescendantDeadline: QWord;
    CancellationFailure: string;
    CancellationStarted: array of Boolean;
    JobIndex: Integer;
  begin
    CancellationFailure := '';
    SetLength(CancellationStarted, Length(Jobs));
    TLWPTProcessTree.NewTerminationDeadlines(DescendantDeadline,
      AcknowledgementDeadline);
    for JobIndex := 0 to High(Jobs) do
      if Assigned(Jobs[JobIndex])
         and (not Jobs[JobIndex].IsDone) then
      begin
        Jobs[JobIndex].BeginCancel(DescendantDeadline,
          AcknowledgementDeadline);
        CancellationStarted[JobIndex] := True;
      end;
    for JobIndex := 0 to High(Jobs) do
      if CancellationStarted[JobIndex] then
        Jobs[JobIndex].CompleteCancel;
    for JobIndex := 0 to High(Jobs) do
      if Assigned(Jobs[JobIndex]) then
      begin
        Jobs[JobIndex].WaitFor;
        if Jobs[JobIndex].CancellationError <> '' then
        begin
          if States[JobIndex] <> besFailed then Inc(Failed);
          States[JobIndex] := besFailed;
          Errors[JobIndex] := Jobs[JobIndex].CancellationError;
          if CancellationFailure = '' then
            CancellationFailure := Jobs[JobIndex].CancellationError;
        end;
        FreeAndNil(Jobs[JobIndex]);
      end;
    if CancellationFailure <> '' then
      raise ELWPTError.Create(CancellationFailure);
  end;
begin
  StartedAt := GetTickCount64;
  Built := 0;
  Failed := 0;
  Skipped := 0;
  Result := 1;
  CompilerSelection := nil;
  Reporter := nil;
  Cache := nil;
  try
    try
      if not FileExists(AManifestPath) then
        raise EManifestError.CreateFmt(
          'manifest not found at %s', [AManifestPath]);
      Man := LoadManifestSnapshot(AManifestPath, ManifestContentHash);
      ProjectRoot := ExtractFileDir(ExpandFileName(AManifestPath));
      if AUseCache then
        try
          Cache := TLWPTBuildCache.CreateDefault;
        except
          on E: Exception do Cache := nil;
        end;
      CompilerSelection := TLWPTCompilerSelection.Create(Man,
        ExtractFileDir(ExpandFileName(AManifestPath)), ACompilerHost);

      if Length(Man.BuildEntries) = 0 then
      begin
        WriteLn(ErrOutput, 'no [build] entries defined in ', AManifestPath);
        Inc(Failed);
        Exit(1);
      end;

  { Validate every requested name BEFORE any hook or compile runs —
    a typo in one of several names must not half-build the list. }
  Unknown := 0;
  for j := 0 to High(AEntryNames) do
  begin
    Matched := False;
    for i := 0 to High(Man.BuildEntries) do
      if SameText(AEntryNames[j], Man.BuildEntries[i].Name) then
      begin
        Matched := True;
        Break;
      end;
    if not Matched then
    begin
      WriteLn(ErrOutput, 'no build entry named "', AEntryNames[j], '" in ',
        AManifestPath);
      Inc(Unknown);
    end;
  end;
      if Unknown > 0 then
      begin
        Failed := Unknown;
        Exit(1);
      end;

  ValidateBuildGraph(Man.BuildEntries);
  SelectBuildEntryClosure(Man.BuildEntries, AEntryNames, Selected);
  SetLength(EntryDrivers, Length(Man.BuildEntries));
  for i := 0 to High(Man.BuildEntries) do
    if Selected[i] then
      EntryDrivers[i] := CompilerSelection.DriverFor(
        Man.BuildEntries[i].CompilerProfile);
  SelectedCount := 0;
  for i := 0 to High(Selected) do
    if Selected[i] then Inc(SelectedCount);
  WriteLn('discovered ', SelectedCount, ' build entry(s)');

  if FindArtefactDirCollision(Man.BuildEntries, CollA, CollB) then
  begin
    WriteLn(ErrOutput, 'build entries "', CollA, '" and "', CollB,
      '" map to the same session job directory ', BuildEntryJobSegment(CollA),
      ' — rename one');
    Inc(Failed);
    Exit(1);
  end;

  if ARelease then ModeStr := 'release' else ModeStr := 'dev';
  if AClean then ModeStr := ModeStr + ', clean';
  MaxJobs := SelectedCount;
  if (AJobs > 0) and (AJobs < MaxJobs) then MaxJobs := AJobs;
  if MaxJobs < 1 then MaxJobs := 1;
  WriteLn('build mode: ', ModeStr);
  Session := TLWPTBuildSession.Create(ProjectRoot,
    ResolveBuildSessionsRoot(ProjectRoot, ResolveSessionsDir(Man),
      GetCurrentDir));
  try
    Reporter := TLWPTProgressReporter.Create(Session, lpsBuild);
    WriteLn('build session: ', Session.SessionID, ' (',
      Session.SessionReference, ')');
    { --clean means a forced compile in fresh private staging. It never
      deletes the last successful public output or another live session. }
    RunHooks('prebuild', Man.PreBuild, ProjectRoot);
    GenerateVersionInclude(
      ExtractFileDir(ExpandFileName(AManifestPath)), Man);

    Running := 0;
    Completed := 0;
    HasEdges := SelectedGraphHasEdges(Man.BuildEntries, Selected);
    SetLength(States, Length(Man.BuildEntries));
    SetLength(Jobs, Length(Man.BuildEntries));
    SetLength(BuildResults, Length(Man.BuildEntries));
    SetLength(CompilerExitCodes, Length(Man.BuildEntries));
    SetLength(Compiled, Length(Man.BuildEntries));
    SetLength(CapturedOutputs, Length(Man.BuildEntries));
    SetLength(Errors, Length(Man.BuildEntries));
    SetLength(StartTicks, Length(Man.BuildEntries));
    SetLength(Reported, Length(Man.BuildEntries));
    Reporter.StartHeartbeatClock(StartedAt, GetTickCount64);
    for i := 0 to High(Man.BuildEntries) do
      if Selected[i] then States[i] := besPending
      else States[i] := besUnselected;
    for i := 0 to High(Man.BuildEntries) do
      if Selected[i] then Reporter.RegisterJob(LogIdentity(i),
        Man.BuildEntries[i].Name);

    WorkerSession := TLWPTWorkerBudgetSession.Create(
      NewWorkerSessionId, MaxJobs);
    try
      { A delegated nested invocation owns exactly one transferred lease,
        regardless of its local --jobs ceiling. Honour the coordinator's
        effective request so a second ready entry waits instead of trying
        to acquire beyond the inherited grant. }
      MaxJobs := WorkerSession.RequestedWorkers;
      WriteLn('build jobs: ', MaxJobs);
      WriteLn('effective workers: ', MaxJobs);
      try
        while Completed < SelectedCount do
        begin
          MadeProgress := False;

          for i := 0 to High(Man.BuildEntries) do
            if (States[i] = besPending)
               and FailedDependency(Man.BuildEntries[i], Man.BuildEntries, States,
                 DependencyName) then
            begin
              States[i] := besBlocked;
              Errors[i] := 'blocked by failed prerequisite "'
                + DependencyName + '"';
              Inc(Skipped);
              Inc(Completed);
              StartTicks[i] := GetTickCount64;
              PrintTerminal(i);
              MadeProgress := True;
            end;

          for i := 0 to High(Man.BuildEntries) do
          begin
            if Running >= MaxJobs then Break;
            if (States[i] <> besPending)
               or not DependenciesSucceeded(Man.BuildEntries[i], Man.BuildEntries,
                 States) then Continue;
            { Never block the scheduler waiting for a machine slot: an
              already-running entry may be the work that returns it. }
            Lease := WorkerSession.Acquire(0);
            if not Assigned(Lease) then Break;
            try
              try
                PrintStart(i);
                RunHooks('prebuild:' + Man.BuildEntries[i].Name,
                  Man.BuildEntries[i].PreBuild, ProjectRoot);
                Jobs[i] := TLWPTBuildJob.Create(AManifestPath, Man,
                  ManifestContentHash, Man.BuildEntries[i], ARelease, AClean,
                  Session, Lease, EntryDrivers[i], Cache, AUseCache);
                Lease := nil;
                States[i] := besRunning;
                Inc(Running);
                try
                  Jobs[i].Start;
                except
                  { A never-started thread cannot release its lease in
                    Execute or report through the IsDone poll. Return the
                    scheduler slot and free the job (its destructor frees
                    the still-attached lease); the outer handler records
                    the failure. }
                  Dec(Running);
                  FreeAndNil(Jobs[i]);
                  raise;
                end;
              finally
                Lease.Free;
              end;
            except
              on E: Exception do
              begin
                States[i] := besFailed;
                CompilerExitCodes[i] := ObservabilityInternalErrorExitCode;
                Errors[i] := E.Message;
                Inc(Failed);
                Inc(Completed);
                PrintTerminal(i);
              end;
            end;
            MadeProgress := True;
          end;

          for i := 0 to High(Jobs) do
            if Assigned(Jobs[i]) and Jobs[i].IsDone then
            begin
              Jobs[i].WaitFor;
              CapturedOutputs[i] := Jobs[i].CapturedOutput;
              BuildResults[i] := Jobs[i].BuildResult;
              CompilerExitCodes[i] := Jobs[i].CompilerExitCode;
              if Jobs[i].Succeeded then
              begin
                Compiled[i] := Jobs[i].Compiled;
                States[i] := besCompiled;
                Reporter.MarkJobInactive(LogIdentity(i));
              end
              else
              begin
                States[i] := besFailed;
                Errors[i] := BuildResultErrorMessage(BuildResults[i]);
                if Errors[i] = '' then Errors[i] := Jobs[i].ErrorMessage;
                Inc(Failed);
              end;
              FreeAndNil(Jobs[i]);
              Dec(Running);
              Inc(Completed);
              if States[i] = besCompiled then
                if HasEdges then
                begin
                  FinalizeEntry(i, True);
                  PrintTerminal(i);
                end
                else
                  try
                    RunEntryPostBuildWithLease(i);
                  except
                    on E: Exception do
                    begin
                      States[i] := besFailed;
                      Errors[i] := E.Message;
                      Inc(Failed);
                      PrintTerminal(i);
                    end;
                  end;
              if States[i] = besFailed then PrintTerminal(i);
              MadeProgress := True;
            end;

          NowTick := GetTickCount64;
          if Reporter.HeartbeatDue(NowTick) then
          begin
            HeartbeatEvent := TLWPTHeartbeatEvent.Create('build',
              Session.SessionID, NowTick - StartedAt);
            try
              Reporter.ReportHeartbeat(HeartbeatEvent);
            finally
              HeartbeatEvent.Free;
            end;
          end;
          if not MadeProgress then Sleep(10);
        end;
      except
        StopAndFreeJobs;
        raise;
      end;

      { With no dependency edges, retain ADR-0020's whole-build postbuild
        gate and publish only after every private candidate succeeds. }
      if (not HasEdges) and (Failed = 0) then
      begin
        WholePostBuild := Man.PostBuild;
        for i := 0 to High(Man.BuildEntries) do
          if States[i] = besCompiled then
            WholePostBuild := RetargetPostBuildHooks(WholePostBuild,
              Compiled[i].OutBin, Compiled[i].CandidateBin);
        RunWholePostBuildWithLease(WholePostBuild);
        for i := 0 to High(Man.BuildEntries) do
          if States[i] = besCompiled then
          begin
            FinalizeEntry(i, False);
            PrintTerminal(i);
          end;
      end
      else if HasEdges and (Failed = 0) then
        { Graph builds publish prerequisites before dependants start. The
          once-per-build posthook therefore observes the published outputs. }
        try
          RunWholePostBuildWithLease(Man.PostBuild);
        except
          on E: Exception do
          begin
            Inc(Failed);
            WriteLn(ErrOutput, '  whole-build postbuild failed after '
              + 'graph publication: ', E.Message);
          end;
        end;
    finally
      try
        StopAndFreeJobs;
      finally
        WorkerSession.Free;
      end;
    end;

    { Any candidate withheld by the whole-build publication gate is a
      deterministic skip, not a second copy of the entry that failed. }
    for i := 0 to High(Man.BuildEntries) do
      if Selected[i] and (States[i] = besCompiled) then
      begin
        States[i] := besBlocked;
        Errors[i] := 'compiled; not published because the build failed';
        Inc(Skipped);
        PrintTerminal(i);
      end;
    Result := Ord(Failed <> 0);
    Session.Finish(Failed = 0,
      IntToStr(Failed) + ' build entry(s) failed or became stale');
  finally
    Reporter.Free;
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
    Cache.Free;
    CompilerSelection.Free;
    WriteLn('summary: ', Built, ' built, ', Failed, ' failed, ',
      Skipped, ' skipped; elapsed ',
      FormatElapsedMilliseconds(GetTickCount64 - StartedAt));
  end;
end;

end.
