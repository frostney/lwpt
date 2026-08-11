{ LWPT.Command.Common — shared command helpers. }
unit LWPT.Command.Common;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  Process,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core,
  LWPT.Manifest;

{ Exit code of a finished TProcess, tolerant of which call reaped it.
  On Unix (FPC 3.2.2) WaitOnExit stores the already-decoded exit code,
  and ExitCode then re-applies wifexited/wexitstatus to that value —
  most nonzero exits (and every signal death) collapse to 0. When a
  Running poll reaps the child instead, the raw waitpid status is
  stored and ExitCode decodes correctly, so which value is trustworthy
  depends on a race. ExitStatus returns the stored word verbatim, so
  genuine failure is nonzero there on either path. Prefer ExitCode
  (correct on Windows and on the raw-status path), and trust ExitStatus
  whenever ExitCode claims success but the stored status disagrees. }
function  NormalisedExitCode(const AProcess: TProcess): Integer;

function  CreatePascalCompilerProcess(const ASrcFile: string;
  const AUnitPaths: array of string; out AOutBin: string;
  out ARequest: TLWPTBuildRequest; const ABuildRoot: string;
  const ADriver: TLWPTCompilerDriver): TProcess;
procedure AppendCompilerEnvironmentSearchPaths(
  var AUnitPaths, AIncludePaths: TStringArray);
function  RunUserTask(const ATask: THook; const AProjectRoot: string): Integer;
procedure RunHooks(const APhase: string; const AHooks: THookArray;
  const AProjectRoot: string);
procedure RunHooksWithEnvironment(const APhase: string;
  const AHooks: THookArray; const AProjectRoot: string;
  const AEnvironment: array of string);

implementation

uses
  LWPT.BuildSession,
  LWPT.CompilerDriver.FPC,
  LWPT.OutputRenderer,
  LWPT.ProcessRunner,
  LWPT.ProcessTree;

procedure CaptureSilentProcessChunk(const AData: RawByteString;
  const AStandardError: Boolean);
begin
  if AStandardError then CaptureSilentChildOutput('', AData)
  else CaptureSilentChildOutput(AData, '');
end;

function NormalisedExitCode(const AProcess: TProcess): Integer;
begin
  Result := AProcess.ExitCode;
  if (Result = 0) and (AProcess.ExitStatus <> 0) then
    Result := AProcess.ExitStatus;
end;

procedure AppendCompilerEnvironmentSearchPaths(
  var AUnitPaths, AIncludePaths: TStringArray);
var
  Raw, Part: string;
  StartAt, i, Count: Integer;
begin
  Raw := GetEnvironmentVariable(PROJECT_NAME + '_FPC_UNIT_PATHS');
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

function CreatePascalCompilerProcess(const ASrcFile: string;
  const AUnitPaths: array of string; out AOutBin: string;
  out ARequest: TLWPTBuildRequest; const ABuildRoot: string;
  const ADriver: TLWPTCompilerDriver): TProcess;
var
  Arguments: LWPT.Core.TStringArray;
  BuildDir: string;
  Capabilities: TLWPTCompilerCapabilities;
  ConfigurationUnitPaths: TStringArray;
  i, UnitPathCount: Integer;
  ScanDirs: TStringArray;

  function SourceBuildKey(const APath: string): string;
  begin
    { Keep compiler paths bounded while distinguishing equal basenames and
      sanitisation collisions by the canonical source path. }
    Result := BuildSessionPathKey(ExpandFileName(APath));
  end;

begin
  if not Assigned(ADriver) then
    raise ELWPTCompilerDriverError.Create('compiler driver is required');
  Result := TProcess.Create(nil);
  try
    if ABuildRoot <> '' then
      BuildDir := IncludeTrailingPathDelimiter(ABuildRoot)
        + SourceBuildKey(ASrcFile)
    else
      BuildDir := MakeTmpPath(TMP_DIR,
        'script-' + SourceBuildKey(ASrcFile));
    ForceDirectories(BuildDir);
    ForceDirectories(BuildDir + '/units');
    AOutBin := IncludeTrailingPathDelimiter(BuildDir)
             + ChangeFileExt(ExtractFileName(ASrcFile), '');

    { Describe the compilation before the selected driver adapts it. }
    ARequest := ADriver.CreateBuildRequest(ASrcFile, AOutBin);
    AOutBin := ARequest.Outputs.Artifact;
    SetLength(ConfigurationUnitPaths, 0);
    AppendUnitDirsFromCfg(CFG_FILE, ConfigurationUnitPaths);
    UnitPathCount := Length(AUnitPaths) + Length(ConfigurationUnitPaths);
    SetLength(ARequest.Inputs.UnitPaths, UnitPathCount);
    SetLength(ARequest.Inputs.IncludePaths, UnitPathCount);
    for i := 0 to High(AUnitPaths) do
    begin
      ARequest.Inputs.UnitPaths[i] := AUnitPaths[i];
      ARequest.Inputs.IncludePaths[i] := AUnitPaths[i];
    end;
    for i := 0 to High(ConfigurationUnitPaths) do
    begin
      ARequest.Inputs.UnitPaths[Length(AUnitPaths) + i] :=
        ConfigurationUnitPaths[i];
      ARequest.Inputs.IncludePaths[Length(AUnitPaths) + i] :=
        ConfigurationUnitPaths[i];
    end;
    AppendCompilerEnvironmentSearchPaths(ARequest.Inputs.UnitPaths,
      ARequest.Inputs.IncludePaths);
    ARequest.Outputs.ExecutableDirectory := BuildDir;
    ARequest.Outputs.UnitDirectory := BuildDir + '/units';
    ARequest.Outputs.ObjectDirectory := BuildDir + '/units';
    ValidateBuildRequest(ARequest);
    { A cached discovery result may shape the request, but every concrete
      compile revalidates live capabilities immediately before translation. }
    Capabilities := ADriver.ProbeCapabilities(ARequest.Target, True);
    EnsureBuildRequestCompatible(ARequest, Capabilities);
    ARequest.Compiler.VersionIdentity := Capabilities.VersionIdentity;

    Arguments := ADriver.InvocationArguments(ADriver.BuildArguments(ARequest,
      PascalSourceCompilerInvocationOptions(CFG_FILE)));
    Result.Executable := ADriver.ExecutableName;
    if ADriver.WorkingDirectory <> '' then
      Result.CurrentDirectory := ADriver.WorkingDirectory;
    for i := 0 to High(Arguments) do
      Result.Parameters.Add(Arguments[i]);

    { Every -Fu directory is now on the parameter list (explicit, cfg and
      environment additions alike), so the staging path budget can be
      checked against the real worst-case assembly file name. }
    SetLength(ScanDirs, 0);
    AppendUnitDirsFromOptions(Result.Parameters, ScanDirs);
    EnsureCompilerPathBudget(BuildDir + '/units', BuildDir,
      LongestCompiledBaseNameLength(ScanDirs, ASrcFile));
  except
    Result.Free;
    raise;
  end;
end;

function CompilePascal(const ASrcFile: string; const AUnitPaths: array of string;
  out AOutBin: string; out ABuildResult: TLWPTBuildResult;
  out ARawOutput: string; const ABuildRoot: string): Boolean;
var
  Buffer: array[0..PROCESS_OUTPUT_BUFFER_SIZE - 1] of Byte;
  BytesRead, ExitCode: Integer;
  Driver: TLWPTCompilerDriver;
  P: TProcess;
  Request: TLWPTBuildRequest;
begin
  ABuildResult := DefaultBuildResult;
  ARawOutput := '';
  Driver := TLWPTFPCCompilerDriver.Create;
  try
    P := CreatePascalCompilerProcess(ASrcFile, AUnitPaths, AOutBin,
      Request, ABuildRoot, Driver);
    try
      P.Options := [poUsePipes, poStderrToOutPut];
      ExecuteUnmanagedProcess(P);
      repeat
        BytesRead := P.Output.Read(Buffer[0], SizeOf(Buffer));
        if BytesRead > 0 then
          AppendRawBytes(ARawOutput, Buffer[0], BytesRead);
      until BytesRead <= 0;
      P.WaitOnExit;
      ExitCode := NormalisedExitCode(P);
      ABuildResult := Driver.NormalizeResult(Request, ExitCode, ARawOutput);
      Result := ABuildResult.Success;
    finally
      P.Free;
    end;
  finally
    Driver.Free;
  end;
end;

function IsAbsoluteFilesystemPath(const APath: string): Boolean;
begin
  Result := (APath <> '') and (APath[1] in ['/', '\']);
  if not Result then
    Result := (Length(APath) >= 3) and (APath[2] = ':')
      and (APath[3] in ['/', '\']);
end;

function ResolveProjectPath(const AProjectRoot, APath: string): string;
begin
  if IsAbsoluteFilesystemPath(APath) then Exit(ExpandFileName(APath));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjectRoot) + APath);
end;

function ResolveCommand(const AProjectRoot, ACommand: string): string;
{$IFDEF WINDOWS}
var
  SearchPath: string;
{$ENDIF}
begin
  if (Pos('/', ACommand) > 0) or (Pos('\', ACommand) > 0) then
  begin
    Result := ResolveProjectPath(AProjectRoot, ACommand);
    {$IFDEF WINDOWS}
    if (ExtractFileExt(Result) = '') and not FileExists(Result) then
    begin
      if FileExists(Result + '.exe') then Result := Result + '.exe'
      else if FileExists(Result + '.com') then Result := Result + '.com';
    end;
    {$ENDIF}
    Exit;
  end;

  {$IFDEF WINDOWS}
  { TProcess.Executable does not apply PATH or PATHEXT when it passes an
    application name directly to CreateProcess. Search only the inherited
    PATH (never the implicit current directory), without involving a shell. }
  SearchPath := GetEnvironmentVariable('PATH');
  Result := FileSearch(ACommand, SearchPath, [sfoStripQuotes]);
  if (Result = '') and (ExtractFileExt(ACommand) = '') then
  begin
    Result := FileSearch(ACommand + '.exe', SearchPath, [sfoStripQuotes]);
    if Result = '' then
      Result := FileSearch(ACommand + '.com', SearchPath, [sfoStripQuotes]);
  end;
  if Result = '' then Result := ACommand;
  {$ELSE}
  { Leave Unix lookup to execvp so a non-executable entry does not mask a
    later executable with the same name in PATH. }
  Result := ACommand;
  {$ENDIF}
end;

function PatternHasGlob(const APattern: string): Boolean;
begin
  Result := (Pos('*', APattern) > 0) or (Pos('?', APattern) > 0);
end;

function StaticGlobPrefix(const APattern: string): string;
var
  Segment: string;
  SlashAt, StartAt: Integer;
begin
  Result := '';
  StartAt := 1;
  while StartAt <= Length(APattern) do
  begin
    SlashAt := Pos('/', Copy(APattern, StartAt, MaxInt));
    if SlashAt = 0 then Segment := Copy(APattern, StartAt, MaxInt)
    else Segment := Copy(APattern, StartAt, SlashAt - 1);
    if PatternHasGlob(Segment) then Exit;
    if Result <> '' then Result := Result + '/';
    Result := Result + Segment;
    if SlashAt = 0 then Exit;
    Inc(StartAt, SlashAt);
  end;
end;

procedure CollectGlobFiles(const AProjectRoot, ADirectory, APattern: string;
  const AFiles: TStringList);
var
  Search: TSearchRec;
  FullPath, RelativePath: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
    faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Name <> '') and (Search.Name[1] = '.') then Continue;
      FullPath := IncludeTrailingPathDelimiter(ADirectory) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        if ((Search.Attr and faSymLink) = 0)
           and not IsDirSymlinkOrJunction(FullPath) then
          CollectGlobFiles(AProjectRoot, FullPath, APattern, AFiles);
      end
      else
      begin
        RelativePath := ExtractRelativePath(
          IncludeTrailingPathDelimiter(AProjectRoot), FullPath);
        RelativePath := StringReplace(RelativePath, '\', '/', [rfReplaceAll]);
        if MatchPathGlob(RelativePath, APattern) then AFiles.Add(FullPath);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure ResolveInputExpression(const AHook: THook;
  const AProjectRoot, AExpression: string; const AFiles: TStringList);
var
  i: Integer;
  Canonical, Prefix, SearchRoot: string;
  Matches: TStringList;
begin
  Matches := TStringList.Create;
  try
  Canonical := CanonicalPathGlob(AExpression);
  if IsAbsoluteFilesystemPath(Canonical) or (Canonical = '..')
     or (Copy(Canonical, 1, 3) = '../') then
    raise EManifestError.CreateFmt(
      'runnable "%s": input "%s" must be project-root-relative',
      [AHook.Name, AExpression]);
  if not PatternHasGlob(Canonical) then
  begin
    SearchRoot := ResolveProjectPath(AProjectRoot, Canonical);
    if not PathContains(AProjectRoot, SearchRoot) then
      raise EManifestError.CreateFmt(
        'runnable "%s": input "%s" must be project-root-relative',
        [AHook.Name, AExpression]);
    if FileExists(SearchRoot) then Matches.Add(SearchRoot);
  end
  else
  begin
    Prefix := StaticGlobPrefix(Canonical);
    if Prefix = '' then SearchRoot := AProjectRoot
    else
    begin
      SearchRoot := ResolveProjectPath(AProjectRoot, Prefix);
      if not PathContains(AProjectRoot, SearchRoot) then
        raise EManifestError.CreateFmt(
          'runnable "%s": input "%s" must be project-root-relative',
          [AHook.Name, AExpression]);
      if not DirectoryExists(SearchRoot) then
        SearchRoot := ExtractFileDir(SearchRoot);
    end;
    if DirectoryExists(SearchRoot) then
      CollectGlobFiles(AProjectRoot, SearchRoot, Canonical, Matches);
  end;
  if Matches.Count = 0 then
    raise EManifestError.CreateFmt(
      'runnable "%s": input expression "%s" matched no files',
      [AHook.Name, AExpression]);
  for i := 0 to Matches.Count - 1 do AFiles.Add(Matches[i]);
  finally
    Matches.Free;
  end;
end;

function HookIsStale(const AHook: THook;
  const AProjectRoot: string): Boolean;
var
  OutputAge: LongInt;
  i: Integer;
  Files: TStringList;
  OutputPath: string;
begin
  { Always-run hooks (no inputs/output declared) never short-circuit. }
  if (AHook.Output = '') or (Length(AHook.Inputs) = 0) then Exit(True);
  Files := TStringList.Create;
  try
    Files.Sorted := True;
    Files.Duplicates := dupIgnore;
    for i := 0 to High(AHook.Inputs) do
      ResolveInputExpression(AHook, AProjectRoot, AHook.Inputs[i], Files);
    OutputPath := ResolveProjectPath(AProjectRoot, AHook.Output);
    if not FileExists(OutputPath) then Exit(True);
    OutputAge := FileAge(OutputPath);
    for i := 0 to Files.Count - 1 do
      if FileAge(Files[i]) > OutputAge then Exit(True);
    Result := False;
  finally
    Files.Free;
  end;
end;

function RunRunnableWithEnvironment(const AHook: THook;
  out AError: string; const AProjectRoot: string;
  const AEnvironment: array of string): Integer;
var
  P: TProcess;
  InheritedEnvironment: TStringList;
  i, j, SeparatorAt: Integer;
  Existing, ExistingName, ExtraName: string;
  CapturedError, CapturedOutput: string;
  ChildFailed: Boolean;
  ProcessOptions: TLWPTProcessRunOptions;
  ProcessRunner: TLWPTDuplexProcessRunner;
begin
  AError := '';
  P := TProcess.Create(nil);
  try
    P.Executable := ResolveCommand(AProjectRoot, AHook.Runnable.Command);
    P.CurrentDirectory := AProjectRoot;
    if Length(AEnvironment) > 0 then
    begin
      { Hooks run on the scheduler thread while build jobs materialise
        their own child environments; sweep via the shared snapshot so
        this walk cannot race the RTL's lazy env count (see LWPT.Core). }
      InheritedEnvironment := TStringList.Create;
      try
        AppendProcessEnvironment(InheritedEnvironment);
        for i := 0 to InheritedEnvironment.Count - 1 do
        begin
          Existing := InheritedEnvironment[i];
          SeparatorAt := Pos('=', Existing);
          if SeparatorAt > 0 then
            ExistingName := Copy(Existing, 1, SeparatorAt - 1)
          else
            ExistingName := Existing;
          for j := 0 to High(AEnvironment) do
          begin
            SeparatorAt := Pos('=', AEnvironment[j]);
            if SeparatorAt > 0 then
              ExtraName := Copy(AEnvironment[j], 1, SeparatorAt - 1)
            else
              ExtraName := AEnvironment[j];
            if SameText(ExistingName, ExtraName) then
            begin
              Existing := '';
              Break;
            end;
          end;
          if Existing <> '' then P.Environment.Add(Existing);
        end;
      finally
        InheritedEnvironment.Free;
      end;
      for i := 0 to High(AEnvironment) do
        P.Environment.Add(AEnvironment[i]);
    end;
    for j := 0 to High(AHook.Runnable.Args) do
      P.Parameters.Add(AHook.Runnable.Args[j]);
    try
      if SilentOutputActive then
      begin
        ProcessRunner := TLWPTDuplexProcessRunner.Create(P);
        try
          ProcessOptions := DefaultProcessRunOptions(
            'runnable "' + AHook.Name + '"');
          ProcessOptions.SeparateStandardError := True;
          ProcessOptions.DiscardCapturedOutput := True;
          ProcessOptions.OnOutputChunk := @CaptureSilentProcessChunk;
          BeginSilentChildOperation;
          ChildFailed := True;
          try
            Result := ProcessRunner.Run('', ProcessOptions, CapturedOutput,
              CapturedError);
            ChildFailed := Result <> 0;
          finally
            FinishSilentChildOperation(ChildFailed);
          end;
        finally
          ProcessRunner.Free;
        end;
      end
      else
      begin
        ExecuteUnmanagedProcess(P);
        P.WaitOnExit;
        Result := NormalisedExitCode(P);
      end;
    except
      on E: Exception do
      begin
        AError := 'command unavailable (' + E.Message + ')';
        Exit(127);
      end;
    end;
  finally
    P.Free;
  end;
end;

procedure RunHooksWithEnvironment(const APhase: string;
  const AHooks: THookArray; const AProjectRoot: string;
  const AEnvironment: array of string);
var
  i, Code: Integer;
  H: THook;
  RunnableError: string;
begin
  if Length(AHooks) = 0 then Exit;
  for i := 0 to High(AHooks) do
  begin
    H := AHooks[i];

    if not HookIsStale(H, AProjectRoot) then
    begin
      WriteLn('  [', APhase, '] ', H.Name, ' (skipped — output fresh)');
      Continue;
    end;

    WriteLn('  [', APhase, '] ', H.Name);

    Code := RunRunnableWithEnvironment(H, RunnableError, AProjectRoot,
      AEnvironment);
    if RunnableError <> '' then
      raise ELWPTError.CreateFmt(
        '[%s] %s: %s while running %s',
        [APhase, H.Name, RunnableError, H.Runnable.Command]);

    if Code <> 0 then
      raise ELWPTError.CreateFmt(
        '[%s] %s: command exited %d while running %s',
        [APhase, H.Name, Code, H.Runnable.Command]);
  end;
end;

procedure RunHooks(const APhase: string; const AHooks: THookArray;
  const AProjectRoot: string);
begin
  RunHooksWithEnvironment(APhase, AHooks, AProjectRoot, []);
end;

function RunUserTask(const ATask: THook; const AProjectRoot: string): Integer;
var
  TaskError: string;
begin
  if not HookIsStale(ATask, AProjectRoot) then Exit(0);
  Result := RunRunnableWithEnvironment(ATask, TaskError, AProjectRoot, []);
  if TaskError <> '' then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: ', TaskError, '.');
    if Result = 0 then Result := 1;
  end;
end;

end.
