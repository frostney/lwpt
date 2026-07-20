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

  LWPT.Core,
  LWPT.ProcessTree;

type
  { Public so the cross-platform cancellation/reaping contract can be tested
    directly without launching a full build scheduler. }
  TLWPTCompilerProcess = class
  private
    FExecutable: string;
    FProcess: TProcess;
    FProcessTree: TLWPTProcessTree;
    FCancelled: Boolean;
    FCriticalSection: TRTLCriticalSection;
  public
    constructor Create(const AExecutable: string = '');
    destructor Destroy; override;
    function Run(const AArgs: LWPT.Core.TStringArray;
      out AOutput: string): Integer;
    procedure Cancel;
  end;

function CmdBuild(const AManifestPath: string;
  const ATargetNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer): Integer; overload;
function CmdBuild(const AManifestPath: string;
  const ATargetNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose: Boolean): Integer; overload;

{ Exposed for unit tests: does this FPC failure output look like stale
  build artefacts (worth a --clean retry) rather than a source error? }
function HasStaleArtefactSignature(const AOutput: string): Boolean;

implementation

uses
  LWPT.BuildRequest,
  LWPT.BuildSession,
  LWPT.Command.Common,
  LWPT.Manifest,
  LWPT.WorkerBudget,
  Platform;

const
  BUILD_TARGET_ENV = PROJECT_NAME + '_BUILD_TARGET';
  BUILD_OUTPUT_ENV = PROJECT_NAME + '_BUILD_OUTPUT';
  BUILD_PUBLIC_OUTPUT_ENV = PROJECT_NAME + '_BUILD_PUBLIC_OUTPUT';

type
  TLWPTCompiledTarget = record
    Name: string;
    CandidateBin: string;
    OutBin: string;
    Fingerprint: string;
    ProjectRoot: string;
    CfgPath: string;
    ModulesPath: string;
    Request: TLWPTBuildPublicationRequest;
    PostBuild: THookArray;
  end;

  TLWPTCompiledTargetArray = array of TLWPTCompiledTarget;

  TLWPTBuildJob = class(TThread)
  private
    FManifestPath: string;
    FManifest: TManifest;
    FManifestContentHash: string;
    FTarget: TBuildTarget;
    FRelease: Boolean;
    FClean: Boolean;
    FSession: TLWPTBuildSession;
    FLease: TLWPTWorkerLease;
    FCompiler: TLWPTCompilerProcess;
    FCompiled: TLWPTCompiledTarget;
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
      const ATarget: TBuildTarget; const ARelease, AClean: Boolean;
      const ASession: TLWPTBuildSession; const ALease: TLWPTWorkerLease);
    destructor Destroy; override;
    procedure Cancel;
    function IsDone: Boolean;
    property Compiled: TLWPTCompiledTarget read FCompiled;
    property CapturedOutput: string read FOutput;
    property CancellationError: string read FCancellationError;
    property ErrorMessage: string read FError;
    property Succeeded: Boolean read FSucceeded;
  end;

  TLWPTTargetState = (tsUnselected, tsPending, tsRunning, tsCompiled,
    tsSucceeded, tsFailed, tsBlocked);

  TLWPTTargetStateArray = array of TLWPTTargetState;
  TLWPTBooleanArray = array of Boolean;
  TLWPTBuildJobArray = array of TLWPTBuildJob;
  TLWPTStringArray = array of string;

procedure AddBuildModeFlags(AArgs: TStrings; ARelease: Boolean);
begin
  { -Sh applies in both modes: ansistrings + H+ string default.
    Mode + nested-comment support are set per-file via directives. }
  AArgs.Add('-Sh');
  if ARelease then
  begin
    AArgs.Add('-O4'); AArgs.Add('-dPRODUCTION'); AArgs.Add('-Xs');
    AArgs.Add('-CX'); AArgs.Add('-XX');          AArgs.Add('-B');
  end
  else
  begin
    AArgs.Add('-O-');  AArgs.Add('-gw'); AArgs.Add('-godwarfsets');
    AArgs.Add('-gl');  AArgs.Add('-Ct'); AArgs.Add('-Cr'); AArgs.Add('-Sa');
  end;
end;

{ Byte-safe accumulator for pipe reads, mirroring HTTPClient's
  AppendRawBytes: append N raw bytes without a PAnsiChar round-trip, so
  large or non-text diagnostics grow the buffer in place. }
procedure AppendRawBytes(var ADest: string; const ABuf; const N: Integer);
var Old: Integer;
begin
  if N <= 0 then Exit;
  Old := Length(ADest);
  SetLength(ADest, Old + N);
  Move(ABuf, ADest[Old + 1], N);
end;

constructor TLWPTCompilerProcess.Create(const AExecutable: string);
begin
  inherited Create;
  FExecutable := AExecutable;
  FProcess := nil;
  FProcessTree := nil;
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
  P: TProcess;
  ProcessTree: TLWPTProcessTree;
  Buf: array[0..4095] of Byte;
  ArgumentIndex, N: Integer;
begin
  AOutput := '';
  P := TProcess.Create(nil);
  ProcessTree := nil;
  try
    if FExecutable <> '' then
      P.Executable := FExecutable
    else
      P.Executable := FPCExecutable;
    for ArgumentIndex := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[ArgumentIndex]);
    P.Options := [poUsePipes, poStderrToOutPut];
    ProcessTree := TLWPTProcessTree.Create(P);
    EnterCriticalSection(FCriticalSection);
    try
      if FCancelled then
        raise ELWPTError.Create('compiler process cancelled');
      FProcess := P;
      FProcessTree := ProcessTree;
      try
        ProcessTree.Execute;
      except
        FProcess := nil;
        FProcessTree := nil;
        raise;
      end;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    repeat
      N := P.Output.Read(Buf[0], SizeOf(Buf));
      if N > 0 then
        AppendRawBytes(AOutput, Buf[0], N);
    until N <= 0;
    P.WaitOnExit;
    { Not P.ExitCode directly: WaitOnExit just reaped the child, and on
      that path Unix ExitCode drops most nonzero exits (see
      NormalisedExitCode). A failed compile must never read as 0. }
    Result := NormalisedExitCode(P);
    EnterCriticalSection(FCriticalSection);
    try
      if FCancelled then Result := 1;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
  finally
    EnterCriticalSection(FCriticalSection);
    try
      if FProcess = P then
      begin
        FProcess := nil;
        FProcessTree := nil;
      end;
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    ProcessTree.Free;
    P.Free;
  end;
end;

procedure TLWPTCompilerProcess.Cancel;
begin
  EnterCriticalSection(FCriticalSection);
  try
    FCancelled := True;
    if Assigned(FProcessTree) then
      FProcessTree.Terminate;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

{ Read the consumer compiler version at build time. LWPT itself may have
  been compiled by a different FPC installation, so a compile-time
  constant is not a valid publication input. }
function QueryFPCVersion: string;
var
  P: TProcess;
  Buf: array[0..255] of Byte;
  Chunk, Captured: string;
  N: Integer;
begin
  Captured := '';
  P := TProcess.Create(nil);
  try
    P.Executable := FPCExecutable;
    P.Parameters.Add('-iV');
    P.Options := [poUsePipes, poStderrToOutPut];
    P.Execute;
    repeat
      N := P.Output.Read(Buf[0], SizeOf(Buf));
      if N > 0 then
      begin
        SetString(Chunk, PAnsiChar(@Buf[0]), N);
        Captured := Captured + Chunk;
      end;
    until N <= 0;
    P.WaitOnExit;
    if P.ExitStatus <> 0 then
      raise ELWPTError.CreateFmt(
        'could not query compiler version (exit %d)', [P.ExitStatus]);
    Result := Trim(Captured);
    if Result = '' then
      raise ELWPTError.Create('compiler returned an empty version');
  finally
    P.Free;
  end;
end;

procedure AppendEnvSearchPaths(var AUnitPaths, AIncludePaths: TStringArray);
var
  Raw, Part: string;
  StartAt, i, Count: Integer;
begin
  Raw := GetEnvironmentVariable('LWPT_FPC_UNIT_PATHS');
  if Raw = '' then Exit;
  StartAt := 1;
  for i := 1 to Length(Raw) + 1 do
    if (i > Length(Raw)) or (Raw[i] = PathSeparator) then
    begin
      Part := Copy(Raw, StartAt, i - StartAt);
      if Part <> '' then
      begin
        Count := Length(AUnitPaths);
        SetLength(AUnitPaths, Count + 1);
        AUnitPaths[Count] := Part;
        Count := Length(AIncludePaths);
        SetLength(AIncludePaths, Count + 1);
        AIncludePaths[Count] := Part;
      end;
      StartAt := i + 1;
    end;
end;

{ FPC failure output that points at stale build artefacts rather than a
  source error — the cases where a --clean retry actually helps. }
function HasStaleArtefactSignature(const AOutput: string): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(AOutput);
  Result :=
    (Pos('compilation raised exception internally', Lower) > 0) or
    (Pos('error while compiling resources', Lower) > 0) or
    ((Pos('.reslst', Lower) > 0) and
     ((Pos('cannot open', Lower) > 0) or
      (Pos('not found', Lower) > 0) or
      (Pos('no such file', Lower) > 0)));
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
    Result[i].Script := ReplaceOutputReference(AHooks[i].Script,
      APublicOutput, ACandidateOutput);
    Result[i].Output := ReplaceOutputReference(AHooks[i].Output,
      APublicOutput, ACandidateOutput);
    Result[i].Args := Copy(AHooks[i].Args, 0, Length(AHooks[i].Args));
    for j := 0 to High(Result[i].Args) do
      Result[i].Args[j] := ReplaceOutputReference(Result[i].Args[j],
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
    AddDefinition(AHooks[i].Script);
    AddDefinition(AHooks[i].Output);
    AddInput(AHooks[i].Script);
    for j := 0 to High(AHooks[i].Args) do
      AddDefinition(AHooks[i].Args[j]);
    for j := 0 to High(AHooks[i].Inputs) do
    begin
      AddDefinition(AHooks[i].Inputs[j]);
      AddInput(AHooks[i].Inputs[j]);
    end;
  end;
end;

{ Target names become session job-directory segments. Reject traversal
  and detect collisions before creating a session. }
function TargetJobSegment(const ATargetName: string): string;
var Safe: string;
begin
  Safe := SanitisePathSegment(ATargetName);
  if (Safe = '') or (Safe = '.') or (Safe = '..') then
    raise ELWPTError.CreateFmt(
      'unsafe build target name "%s"', [ATargetName]);
  Result := BuildSessionPathKey(ATargetName);
end;

procedure AddDeclaredOutputs(const AMan: TManifest;
  var APaths: TStringArray);
var
  i, Count: Integer;
  OutputPath: string;
begin
  for i := 0 to High(AMan.Targets) do
  begin
    OutputPath := AMan.Targets[i].Output;
    if OutputPath = '' then
      OutputPath := ChangeFileExt(AMan.Targets[i].Source, '');
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

{ Compile one build target. Returns True on success. }
function BuildOneTarget(const AManifestPath: string; const AMan: TManifest;
  const AManifestContentHash: string;
  const T: TBuildTarget; ARelease, AClean: Boolean;
  ASession: TLWPTBuildSession; ACompiler: TLWPTCompilerProcess;
  out ACompiled: TLWPTCompiledTarget; out AOutput: string): Boolean;
var
  Args : TStringList;
  FpcArgs : TStringArray;
  Arch, OutBin, JobRoot, BinDir, CandidateBin, UnitOutDir, OutText,
    Fingerprint, ProjectRoot, CfgPath, ModulesPath : string;
  i, FpcExit : Integer;
  Request: TLWPTBuildPublicationRequest;
  ScanDirs: LWPT.Core.TStringArray;
begin
  ACompiled := Default(TLWPTCompiledTarget);
  AOutput := '';
  if T.Source = '' then
    Exit(False);

  OutBin := T.Output;
  if OutBin = '' then
    OutBin := ChangeFileExt(T.Source, '');
  {$IFDEF MSWINDOWS}
  if ExtractFileExt(OutBin) = '' then OutBin := OutBin + '.exe';
  {$ENDIF}
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
  Request := Default(TLWPTBuildPublicationRequest);
  Request.BuildRequest := DefaultBuildRequest;
  Request.BuildRequest.Compiler.ID := 'fpc';
  Request.BuildRequest.Compiler.VersionConstraint := '*';
  Request.BuildRequest.Compiler.VersionIdentity := QueryFPCVersion;
  Request.CompilerExecutable := FPCExecutable;
  Request.ManifestContentHash := AManifestContentHash;
  Request.PublicOutput := OutBin;
  Request.BuildRequest.OutputKind := BUILD_OUTPUT_EXECUTABLE;
  if ARelease then
  begin
    Request.BuildRequest.Mode := BUILD_MODE_RELEASE;
    SetLength(Request.BuildRequest.Inputs.Defines, 1);
    Request.BuildRequest.Inputs.Defines[0] := 'PRODUCTION';
  end
  else
    Request.BuildRequest.Mode := BUILD_MODE_DEV;
  Request.BuildRequest.Target.OS :=
    GetEnvironmentVariable('FPC_TARGET_OS');
  if Request.BuildRequest.Target.OS = '' then
    Request.BuildRequest.Target.OS := GetBuildOS;
  Request.BuildRequest.Target.Architecture :=
    GetEnvironmentVariable('FPC_TARGET_CPU');
  if Request.BuildRequest.Target.Architecture = '' then
    Request.BuildRequest.Target.Architecture := GetBuildArch;
  Request.BuildRequest.Inputs.EntryPoint := T.Source;
  SetLength(Request.BuildRequest.Inputs.Sources, 1);
  Request.BuildRequest.Inputs.Sources[0] := T.Source;
  Request.BuildRequest.Outputs.Artifact := CandidateBin;
  Request.BuildRequest.Outputs.ExecutableDirectory := BinDir;
  Request.BuildRequest.Outputs.UnitDirectory := UnitOutDir;
  Request.BuildRequest.Outputs.ObjectDirectory := UnitOutDir;
  SetLength(Request.Environment, 1);
  Request.Environment[0] := 'LWPT_FPC_UNIT_PATHS='
    + GetEnvironmentVariable('LWPT_FPC_UNIT_PATHS');
  Request.BuildRequest.Inputs.UnitPaths :=
    Copy(AMan.Units, 0, Length(AMan.Units));
  Request.BuildRequest.Inputs.IncludePaths :=
    Copy(AMan.Includes, 0, Length(AMan.Includes));
  SetLength(Request.WorkspacePaths, Length(AMan.Workspaces));
  for i := 0 to High(AMan.Workspaces) do
    Request.WorkspacePaths[i] := AMan.Workspaces[i].Path;
  AddHookPublicationInputs(T.PostBuild, Request);
  AddHookPublicationInputs(AMan.PostBuild, Request);
  ACompiled.PostBuild := RetargetPostBuildHooks(T.PostBuild,
    OutBin, CandidateBin);
  AppendEnvSearchPaths(Request.BuildRequest.Inputs.UnitPaths,
    Request.BuildRequest.Inputs.IncludePaths);
  AddDeclaredOutputs(AMan, Request.ExcludedPaths);
  ValidateBuildRequest(Request.BuildRequest);
  { The cfg reaches FPC unexpanded (@file), so its -Fu lines are read
    through the same shared extractor the test flow uses. }
  ScanDirs := Copy(Request.BuildRequest.Inputs.UnitPaths, 0,
    Length(Request.BuildRequest.Inputs.UnitPaths));
  AppendUnitDirsFromCfg(ResolveCfgFile(AMan), ScanDirs);
  EnsureCompilerPathBudget(UnitOutDir, BinDir,
    LongestCompiledBaseNameLength(ScanDirs, T.Source));
  Fingerprint := CaptureBuildPublicationFingerprint(ProjectRoot,
    AManifestPath, CfgPath, LOCKFILE, ModulesPath, Request);

  Args := TStringList.Create;
  try
    { cross-compile target CPU via env var, same hook as build.pas }
    Arch := GetEnvironmentVariable('FPC_TARGET_CPU');
    if Arch <> '' then Args.Add('-P' + Arch);

    Args.Add('-Sh');
    { -FE is the exe fallback for outputs without a dir component;
      -FU overrides it for units only, isolating .ppu/.o per
      target + mode while -o keeps the binary at the manifest path. }
    Args.Add('-FE' + BinDir);
    Args.Add('-FU' + UnitOutDir);
    { resolved dependency search paths: the manifest-resolved cfg path,
      if install has run (zero-install repos commit it, so this should
      almost always be present). }
    if FileExists(ResolveCfgFile(AMan)) then
      Args.Add('@' + ResolveCfgFile(AMan));
    { Adapt the neutral request's distinct search-path collections to FPC.
      Environment-provided paths were appended to both collections above. }
    for i := 0 to High(Request.BuildRequest.Inputs.UnitPaths) do
      if Request.BuildRequest.Inputs.UnitPaths[i] <> '' then
        Args.Add('-Fu' + Request.BuildRequest.Inputs.UnitPaths[i]);
    for i := 0 to High(Request.BuildRequest.Inputs.IncludePaths) do
      if Request.BuildRequest.Inputs.IncludePaths[i] <> '' then
        Args.Add('-Fi' + Request.BuildRequest.Inputs.IncludePaths[i]);
    AddBuildModeFlags(Args, ARelease);
    { -B forces a full rebuild, ignoring up-to-date units. Release mode
      already adds -B; only add it here for a clean dev build. }
    if AClean and (not ARelease) then
      Args.Add('-B');
    Args.Add('-o' + CandidateBin);
    Args.Add(T.Source);

    SetLength(FpcArgs, Args.Count);
    for i := 0 to Args.Count - 1 do
      FpcArgs[i] := Args[i];
  finally
    Args.Free;
  end;

  FpcExit := ACompiler.Run(FpcArgs, OutText);
  AOutput := OutText;
  Result := FpcExit = 0;

  if not Result then
    AOutput := AOutput + LineEnding + 'FAILED (fpc exit '
      + IntToStr(FpcExit) + ')' + LineEnding;

  if Result then
  begin
    ACompiled.Name := T.Name;
    ACompiled.CandidateBin := CandidateBin;
    ACompiled.OutBin := OutBin;
    ACompiled.Fingerprint := Fingerprint;
    ACompiled.ProjectRoot := ProjectRoot;
    ACompiled.CfgPath := CfgPath;
    ACompiled.ModulesPath := ModulesPath;
    ACompiled.Request := Request;
  end;

  if (not Result) and (not AClean)
     and HasStaleArtefactSignature(OutText) then
  begin
    AOutput := AOutput + LineEnding
      + '  hint: stale FPC build artefacts can cause this error.'
      + LineEnding + '  retry with: ' + PROGRAM_NAME + ' build '
      + T.Name + ' --clean' + LineEnding;
  end;
end;

constructor TLWPTBuildJob.Create(const AManifestPath: string;
  const AManifest: TManifest; const AManifestContentHash: string;
  const ATarget: TBuildTarget; const ARelease, AClean: Boolean;
  const ASession: TLWPTBuildSession; const ALease: TLWPTWorkerLease);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FManifestPath := AManifestPath;
  FManifest := AManifest;
  FManifestContentHash := AManifestContentHash;
  FTarget := ATarget;
  FRelease := ARelease;
  FClean := AClean;
  FSession := ASession;
  FLease := ALease;
  FCompiler := TLWPTCompilerProcess.Create;
  FCompiled := Default(TLWPTCompiledTarget);
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
      FSucceeded := BuildOneTarget(FManifestPath, FManifest,
        FManifestContentHash, FTarget, FRelease, FClean, FSession,
        FCompiler, FCompiled, FOutput);
      if (not FSucceeded) and (FError = '') then
        if FTarget.Source = '' then
          FError := 'target has no source'
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
  CancellationMessage: string;
begin
  Terminate;
  try
    FCompiler.Cancel;
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

{ Two target names that sanitise to the same session job segment would
  share private output within one invocation. }
function FindArtefactDirCollision(const ATargets: array of TBuildTarget;
  out AFirst, ASecond: string): Boolean;
var i, j: Integer;
begin
  for i := 0 to High(ATargets) do
    for j := i + 1 to High(ATargets) do
      if SameText(TargetJobSegment(ATargets[i].Name),
                  TargetJobSegment(ATargets[j].Name)) then
      begin
        AFirst  := ATargets[i].Name;
        ASecond := ATargets[j].Name;
        Exit(True);
      end;
  Result := False;
end;

function FindTargetIndex(const ATargets: array of TBuildTarget;
  const AName: string): Integer;
var i: Integer;
begin
  for i := 0 to High(ATargets) do
    if SameText(ATargets[i].Name, AName) then Exit(i);
  Result := -1;
end;

procedure ValidateBuildGraph(const ATargets: array of TBuildTarget);
var
  VisitState: array of Byte;
  i: Integer;

  procedure Visit(AIndex: Integer);
  var j, DependencyIndex: Integer;
  begin
    if VisitState[AIndex] = 2 then Exit;
    if VisitState[AIndex] = 1 then
      raise EManifestError.CreateFmt(
        '[build] dependency cycle reaches target "%s"',
        [ATargets[AIndex].Name]);
    VisitState[AIndex] := 1;
    for j := 0 to High(ATargets[AIndex].Depends) do
    begin
      DependencyIndex := FindTargetIndex(ATargets,
        ATargets[AIndex].Depends[j]);
      if DependencyIndex < 0 then
        raise EManifestError.CreateFmt(
          '[build] target "%s" depends on unknown target "%s"',
          [ATargets[AIndex].Name, ATargets[AIndex].Depends[j]]);
      Visit(DependencyIndex);
    end;
    VisitState[AIndex] := 2;
  end;

begin
  SetLength(VisitState, Length(ATargets));
  for i := 0 to High(ATargets) do Visit(i);
end;

procedure SelectTargetClosure(const ATargets: array of TBuildTarget;
  const ARequestedNames: array of string; var ASelected: TLWPTBooleanArray);
var i: Integer;

  procedure Select(AIndex: Integer);
  var j, DependencyIndex: Integer;
  begin
    if ASelected[AIndex] then Exit;
    ASelected[AIndex] := True;
    for j := 0 to High(ATargets[AIndex].Depends) do
    begin
      DependencyIndex := FindTargetIndex(ATargets,
        ATargets[AIndex].Depends[j]);
      Select(DependencyIndex);
    end;
  end;

begin
  SetLength(ASelected, Length(ATargets));
  if Length(ARequestedNames) = 0 then
    for i := 0 to High(ATargets) do Select(i)
  else
    for i := 0 to High(ARequestedNames) do
      Select(FindTargetIndex(ATargets, ARequestedNames[i]));
end;

function SelectedGraphHasEdges(const ATargets: array of TBuildTarget;
  const ASelected: TLWPTBooleanArray): Boolean;
var i: Integer;
begin
  for i := 0 to High(ATargets) do
    if ASelected[i] and (Length(ATargets[i].Depends) > 0) then Exit(True);
  Result := False;
end;

function DependenciesSucceeded(const ATarget: TBuildTarget;
  const ATargets: array of TBuildTarget;
  const AStates: TLWPTTargetStateArray): Boolean;
var i, DependencyIndex: Integer;
begin
  for i := 0 to High(ATarget.Depends) do
  begin
    DependencyIndex := FindTargetIndex(ATargets, ATarget.Depends[i]);
    if AStates[DependencyIndex] <> tsSucceeded then Exit(False);
  end;
  Result := True;
end;

function FailedDependency(const ATarget: TBuildTarget;
  const ATargets: array of TBuildTarget;
  const AStates: TLWPTTargetStateArray; out AName: string): Boolean;
var i, DependencyIndex: Integer;
begin
  for i := 0 to High(ATarget.Depends) do
  begin
    DependencyIndex := FindTargetIndex(ATargets, ATarget.Depends[i]);
    if AStates[DependencyIndex] in [tsFailed, tsBlocked] then
    begin
      AName := ATargets[DependencyIndex].Name;
      Exit(True);
    end;
  end;
  Result := False;
end;

function CmdBuild(const AManifestPath: string;
  const ATargetNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer): Integer;
begin
  Result := CmdBuild(AManifestPath, ATargetNames, ARelease, AClean,
    AJobs, False);
end;

function CmdBuild(const AManifestPath: string;
  const ATargetNames: array of string; const ARelease, AClean: Boolean;
  const AJobs: Integer; const AVerbose: Boolean): Integer;
var
  Man : TManifest;
  i, j, Built, Failed, Skipped, Unknown, SelectedCount, MaxJobs, Running,
    Completed : Integer;
  Matched : Boolean;
  ModeStr, CollA, CollB, DependencyName : string;
  ManifestContentHash: string;
  Session: TLWPTBuildSession;
  WorkerSession: TLWPTWorkerBudgetSession;
  Lease: TLWPTWorkerLease;
  Selected: TLWPTBooleanArray;
  States: TLWPTTargetStateArray;
  Jobs: TLWPTBuildJobArray;
  Compiled: TLWPTCompiledTargetArray;
  CapturedOutputs, Errors: TLWPTStringArray;
  PublicationRequest: TLWPTBuildPublicationRequest;
  PublicationResult: TLWPTBuildPublicationResult;
  WholePostBuild: THookArray;
  HookEnvironment: array of string;
  HasEdges, MadeProgress: Boolean;
  CurrentCompilerVersion: string;
  StartedAt, LastHeartbeatAt, HeartbeatInterval, NowTick: QWord;
  StartTicks: array of QWord;
  Reported: array of Boolean;

  procedure WriteCapturedOutput(const AOutput: string);
  begin
    if AOutput = '' then Exit;
    Write(AOutput);
    if not (AOutput[Length(AOutput)] in [#10, #13]) then WriteLn;
  end;

  function LogIdentity(const AIndex: Integer): string;
  begin
    Result := ObservabilityBuildIdentityNamespace + Man.Targets[AIndex].Name;
  end;

  procedure PrintStart(const AIndex: Integer);
  begin
    StartTicks[AIndex] := GetTickCount64;
    Session.WriteJobLog(LogIdentity(AIndex), '');
    WriteLn(ObservabilityStartEvent, Man.Targets[AIndex].Name, ' (',
      Man.Targets[AIndex].Source, '; log: ',
      Session.JobLogReference(LogIdentity(AIndex)), ')');
  end;

  procedure PrintTerminal(const AIndex: Integer);
  var
    LogOutput, Elapsed, LogReference: string;
  begin
    if Reported[AIndex] then Exit;
    if not (States[AIndex] in [tsSucceeded, tsFailed, tsBlocked]) then Exit;
    Reported[AIndex] := True;
    LogOutput := CapturedOutputs[AIndex];
    if (LogOutput = '') and (Errors[AIndex] <> '') then
      LogOutput := Errors[AIndex] + LineEnding;
    Session.WriteJobLog(LogIdentity(AIndex), LogOutput);
    LogReference := Session.JobLogReference(LogIdentity(AIndex));
    Elapsed := FormatElapsedMilliseconds(
      GetTickCount64 - StartTicks[AIndex]);
    case States[AIndex] of
      tsSucceeded:
        begin
          WriteLn(ObservabilityPassEvent, Man.Targets[AIndex].Name, ' -> ',
            Compiled[AIndex].OutBin, ' (', Elapsed, '; log: ',
            LogReference, ')');
          if AVerbose then WriteCapturedOutput(LogOutput);
        end;
      tsFailed:
        begin
          WriteLn(ObservabilityFailEvent, Man.Targets[AIndex].Name, ' (',
            Elapsed,
            '; log: ', LogReference, ')');
          WriteCapturedOutput(LogOutput);
          if (Errors[AIndex] <> '')
             and (Pos(Errors[AIndex], LogOutput) = 0) then
            WriteLn('  error: ', Errors[AIndex]);
          if Errors[AIndex] <> '' then
            WriteLn(ErrOutput, '  target "', Man.Targets[AIndex].Name,
              '" failed: ', Errors[AIndex]);
        end;
      tsBlocked:
        begin
          WriteLn(ObservabilitySkipEvent, Man.Targets[AIndex].Name, ' (',
            Errors[AIndex], '; ', Elapsed, '; log: ', LogReference, ')');
          WriteLn(ErrOutput, '  target "', Man.Targets[AIndex].Name,
            '" failed: ', Errors[AIndex]);
        end;
    end;
  end;

  function ActiveBuildSummary(const ATick: QWord): string;
  var
    TargetIndex: Integer;
  begin
    Result := '';
    for TargetIndex := 0 to High(Man.Targets) do
      if States[TargetIndex] in [tsPending, tsRunning] then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + Man.Targets[TargetIndex].Name;
        if States[TargetIndex] = tsRunning then
          Result := Result + ' (' + FormatElapsedMilliseconds(
            ATick - StartTicks[TargetIndex]) + ')'
        else
          Result := Result + ' (queued)';
      end;
  end;

  procedure RunTargetPostBuild(const AIndex: Integer);
  begin
    SetLength(HookEnvironment, 3);
    HookEnvironment[0] := BUILD_TARGET_ENV + '=' + Compiled[AIndex].Name;
    HookEnvironment[1] := BUILD_OUTPUT_ENV + '='
      + Compiled[AIndex].CandidateBin;
    HookEnvironment[2] := BUILD_PUBLIC_OUTPUT_ENV + '='
      + Compiled[AIndex].OutBin;
    RunHooksWithEnvironment('postbuild:' + Man.Targets[AIndex].Name,
      Compiled[AIndex].PostBuild, Session.HookRoot, HookEnvironment);
  end;

  procedure FinalizeTarget(const AIndex: Integer;
    const ARunPostBuild: Boolean);
  begin
    try
      if ARunPostBuild then RunTargetPostBuild(AIndex);
      PublicationRequest := Compiled[AIndex].Request;
      CurrentCompilerVersion := QueryFPCVersion;
      if CurrentCompilerVersion
        <> PublicationRequest.BuildRequest.Compiler.VersionIdentity then
        PublicationResult := bprStale
      else
        PublicationResult := PublishBuildArtifact(
          Compiled[AIndex].ProjectRoot, Compiled[AIndex].CandidateBin,
          Compiled[AIndex].OutBin, Compiled[AIndex].Fingerprint,
          AManifestPath, Compiled[AIndex].CfgPath, LOCKFILE,
          Compiled[AIndex].ModulesPath, PublicationRequest);
      if PublicationResult = bprStale then
      begin
        States[AIndex] := tsFailed;
        Errors[AIndex] := 'inputs changed during compilation; private '
          + 'result was not published';
        Inc(Failed);
      end
      else
      begin
        States[AIndex] := tsSucceeded;
        Inc(Built);
      end;
    except
      on E: Exception do
      begin
        States[AIndex] := tsFailed;
        Errors[AIndex] := E.Message;
        Inc(Failed);
      end;
    end;
  end;

  procedure StopAndFreeJobs;
  var
    CancellationFailure: string;
    JobIndex: Integer;
  begin
    CancellationFailure := '';
    for JobIndex := 0 to High(Jobs) do
      if Assigned(Jobs[JobIndex])
         and (not Jobs[JobIndex].IsDone) then
        Jobs[JobIndex].Cancel;
    for JobIndex := 0 to High(Jobs) do
      if Assigned(Jobs[JobIndex]) then
      begin
        Jobs[JobIndex].WaitFor;
        if Jobs[JobIndex].CancellationError <> '' then
        begin
          if States[JobIndex] <> tsFailed then Inc(Failed);
          States[JobIndex] := tsFailed;
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
  try
    try
      if not FileExists(AManifestPath) then
        raise EManifestError.CreateFmt(
          'manifest not found at %s', [AManifestPath]);
      Man := LoadManifestSnapshot(AManifestPath, ManifestContentHash);

      if Length(Man.Targets) = 0 then
      begin
        WriteLn('no [build] entries defined in ', AManifestPath);
        Inc(Failed);
        Exit(1);
      end;

  { Validate every requested name BEFORE any hook or compile runs —
    a typo in one of several names must not half-build the list. }
  Unknown := 0;
  for j := 0 to High(ATargetNames) do
  begin
    Matched := False;
    for i := 0 to High(Man.Targets) do
      if SameText(ATargetNames[j], Man.Targets[i].Name) then
      begin
        Matched := True;
        Break;
      end;
    if not Matched then
    begin
      WriteLn(ErrOutput, 'no target named "', ATargetNames[j], '" in ',
        AManifestPath);
      Inc(Unknown);
    end;
  end;
      if Unknown > 0 then
      begin
        Failed := Unknown;
        Exit(1);
      end;

  ValidateBuildGraph(Man.Targets);
  SelectTargetClosure(Man.Targets, ATargetNames, Selected);
  SelectedCount := 0;
  for i := 0 to High(Selected) do
    if Selected[i] then Inc(SelectedCount);
  WriteLn('discovered ', SelectedCount, ' build target(s)');

  if FindArtefactDirCollision(Man.Targets, CollA, CollB) then
  begin
    WriteLn(ErrOutput, 'targets "', CollA, '" and "', CollB,
      '" map to the same session job directory ', TargetJobSegment(CollA),
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
  Session := TLWPTBuildSession.Create(
    ExtractFileDir(ExpandFileName(AManifestPath)));
  try
    WriteLn('build session: ', Session.SessionID, ' (',
      Session.SessionReference, ')');
    { --clean means a forced compile in fresh private staging. It never
      deletes the last successful public output or another live session. }
    RunHooks('prebuild', Man.PreBuild, Session.HookRoot);
    GenerateVersionInclude(
      ExtractFileDir(ExpandFileName(AManifestPath)), Man);

    Running := 0;
    Completed := 0;
    HasEdges := SelectedGraphHasEdges(Man.Targets, Selected);
    SetLength(States, Length(Man.Targets));
    SetLength(Jobs, Length(Man.Targets));
    SetLength(Compiled, Length(Man.Targets));
    SetLength(CapturedOutputs, Length(Man.Targets));
    SetLength(Errors, Length(Man.Targets));
    SetLength(StartTicks, Length(Man.Targets));
    SetLength(Reported, Length(Man.Targets));
    HeartbeatInterval := ObservabilityHeartbeatIntervalMilliseconds;
    LastHeartbeatAt := GetTickCount64;
    for i := 0 to High(Man.Targets) do
      if Selected[i] then States[i] := tsPending
      else States[i] := tsUnselected;

    WorkerSession := TLWPTWorkerBudgetSession.Create(
      NewWorkerSessionId, MaxJobs);
    try
      { A delegated nested invocation owns exactly one transferred lease,
        regardless of its local --jobs ceiling. Honour the coordinator's
        effective request so a second ready target waits instead of trying
        to acquire beyond the inherited grant. }
      MaxJobs := WorkerSession.RequestedWorkers;
      WriteLn('build jobs: ', MaxJobs);
      WriteLn('effective workers: ', MaxJobs);
      try
        while Completed < SelectedCount do
        begin
          MadeProgress := False;

          for i := 0 to High(Man.Targets) do
            if (States[i] = tsPending)
               and FailedDependency(Man.Targets[i], Man.Targets, States,
                 DependencyName) then
            begin
              States[i] := tsBlocked;
              Errors[i] := 'blocked by failed prerequisite "'
                + DependencyName + '"';
              Inc(Skipped);
              Inc(Completed);
              StartTicks[i] := GetTickCount64;
              Session.WriteJobLog(LogIdentity(i), '');
              PrintTerminal(i);
              MadeProgress := True;
            end;

          for i := 0 to High(Man.Targets) do
          begin
            if Running >= MaxJobs then Break;
            if (States[i] <> tsPending)
               or not DependenciesSucceeded(Man.Targets[i], Man.Targets,
                 States) then Continue;
            { Never block the scheduler waiting for a machine slot: an
              already-running target may be the work that returns it. }
            Lease := WorkerSession.Acquire(0);
            if not Assigned(Lease) then Break;
            try
              try
                PrintStart(i);
                RunHooks('prebuild:' + Man.Targets[i].Name,
                  Man.Targets[i].PreBuild, Session.HookRoot);
                Jobs[i] := TLWPTBuildJob.Create(AManifestPath, Man,
                  ManifestContentHash, Man.Targets[i], ARelease, AClean,
                  Session, Lease);
                Lease := nil;
                States[i] := tsRunning;
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
                States[i] := tsFailed;
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
              if Jobs[i].Succeeded then
              begin
                Compiled[i] := Jobs[i].Compiled;
                States[i] := tsCompiled;
              end
              else
              begin
                States[i] := tsFailed;
                Errors[i] := Jobs[i].ErrorMessage;
                Inc(Failed);
              end;
              FreeAndNil(Jobs[i]);
              Dec(Running);
              Inc(Completed);
              if States[i] = tsCompiled then
                if HasEdges then
                begin
                  FinalizeTarget(i, True);
                  PrintTerminal(i);
                end
                else
                  try
                    RunTargetPostBuild(i);
                  except
                    on E: Exception do
                    begin
                      States[i] := tsFailed;
                      Errors[i] := E.Message;
                      Inc(Failed);
                      PrintTerminal(i);
                    end;
                  end;
              if States[i] = tsFailed then PrintTerminal(i);
              MadeProgress := True;
            end;

          NowTick := GetTickCount64;
          if NowTick - LastHeartbeatAt >= HeartbeatInterval then
          begin
            WriteLn(ObservabilityHeartbeatEvent, 'build elapsed ',
              FormatElapsedMilliseconds(NowTick - StartedAt),
              '; active: ', ActiveBuildSummary(NowTick));
            LastHeartbeatAt := NowTick;
          end;
          if not MadeProgress then Sleep(10);
        end;
      except
        StopAndFreeJobs;
        raise;
      end;

      { With no dependency edges, retain ADR-0020's all-target postbuild
        gate and publish only after every private candidate succeeds. }
      if (not HasEdges) and (Failed = 0) then
      begin
        WholePostBuild := Man.PostBuild;
        for i := 0 to High(Man.Targets) do
          if States[i] = tsCompiled then
            WholePostBuild := RetargetPostBuildHooks(WholePostBuild,
              Compiled[i].OutBin, Compiled[i].CandidateBin);
        RunHooks('postbuild', WholePostBuild, Session.HookRoot);
        for i := 0 to High(Man.Targets) do
          if States[i] = tsCompiled then
          begin
            FinalizeTarget(i, False);
            PrintTerminal(i);
          end;
      end
      else if HasEdges and (Failed = 0) then
        { Graph builds publish prerequisites before dependants start. The
          once-per-build posthook therefore observes the published outputs. }
        try
          RunHooks('postbuild', Man.PostBuild, Session.HookRoot);
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

    { Any candidate withheld by the all-target publication gate is a
      deterministic skip, not a second copy of the target that failed. }
    for i := 0 to High(Man.Targets) do
      if Selected[i] and (States[i] = tsCompiled) then
      begin
        States[i] := tsBlocked;
        Errors[i] := 'compiled; not published because the build failed';
        Inc(Skipped);
        PrintTerminal(i);
      end;
    Result := Ord(Failed <> 0);
    Session.Finish(Failed = 0,
      IntToStr(Failed) + ' target(s) failed or became stale');
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
    WriteLn('summary: ', Built, ' built, ', Failed, ' failed, ',
      Skipped, ' skipped; elapsed ',
      FormatElapsedMilliseconds(GetTickCount64 - StartedAt));
  end;
end;

end.
