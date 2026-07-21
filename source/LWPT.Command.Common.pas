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
function  RunPascalScript(const AHook: THook; out AError: string;
  const ABuildRoot: string = ''): Integer;
function  RunUserScript(const AHook: THook): Integer;
procedure RunHooks(const APhase: string; const AHooks: THookArray;
  const ABuildRoot: string = '');
procedure RunHooksWithEnvironment(const APhase: string;
  const AHooks: THookArray; const ABuildRoot: string;
  const AEnvironment: array of string);

implementation

uses
  LWPT.BuildSession,
  LWPT.CompilerDriver.FPC,
  LWPT.Core;

function NormalisedExitCode(const AProcess: TProcess): Integer;
begin
  Result := AProcess.ExitCode;
  if (Result = 0) and (AProcess.ExitStatus <> 0) then
    Result := AProcess.ExitStatus;
end;

function CreatePascalCompilerProcess(const ASrcFile: string;
  const AUnitPaths: array of string; out AOutBin: string;
  out ARequest: TLWPTBuildRequest; const ABuildRoot: string;
  const ADriver: TLWPTCompilerDriver): TProcess;
var
  Arguments: LWPT.Core.TStringArray;
  BuildDir: string;
  Capabilities: TLWPTCompilerCapabilities;
  i: Integer;
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
    ARequest := CreateFPCBuildRequest(ASrcFile, AOutBin);
    AOutBin := ARequest.Outputs.Artifact;
    SetLength(ARequest.Inputs.UnitPaths, Length(AUnitPaths));
    SetLength(ARequest.Inputs.IncludePaths, Length(AUnitPaths));
    for i := 0 to High(AUnitPaths) do
    begin
      ARequest.Inputs.UnitPaths[i] := AUnitPaths[i];
      ARequest.Inputs.IncludePaths[i] := AUnitPaths[i];
    end;
    ARequest.Outputs.ExecutableDirectory := BuildDir;
    ARequest.Outputs.UnitDirectory := BuildDir + '/units';
    ARequest.Outputs.ObjectDirectory := BuildDir + '/units';
    ValidateBuildRequest(ARequest);
    Capabilities := ADriver.ProbeCapabilities(ARequest.Target);
    EnsureBuildRequestCompatible(ARequest, Capabilities);
    ARequest.Compiler.VersionIdentity := Capabilities.VersionIdentity;

    Arguments := ADriver.BuildArguments(ARequest,
      PascalSourceCompilerInvocationOptions(CFG_FILE));
    Result.Executable := ADriver.ExecutableName;
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
      P.Execute;
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

function HookIsStale(const AHook: THook): Boolean;
var
  OutputAge: LongInt;
  i: Integer;
begin
  { Always-run hooks (no inputs/output declared) never short-circuit. }
  if (AHook.Output = '') or (Length(AHook.Inputs) = 0) then Exit(True);
  if not FileExists(AHook.Output) then Exit(True);
  OutputAge := FileAge(AHook.Output);
  for i := 0 to High(AHook.Inputs) do
    if FileExists(AHook.Inputs[i])
       and (FileAge(AHook.Inputs[i]) > OutputAge) then
      Exit(True);
  Result := False;
end;

function RunPascalScriptWithEnvironment(const AHook: THook;
  out AError: string; const ABuildRoot: string;
  const AEnvironment: array of string): Integer;
var
  P: TProcess;
  InheritedEnvironment: TStringList;
  i, j, SeparatorAt: Integer;
  Existing, ExistingName, ExtraName: string;
  {$IFDEF UNIX}
  CacheRoot: string;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Bin, CompilerOutput, DiagnosticMessage: string;
  BuildResult: TLWPTBuildResult;
  {$ENDIF}
begin
  AError := '';
  {$IFDEF MSWINDOWS}
  if not CompilePascal(AHook.Script, [], Bin, BuildResult, CompilerOutput,
    ABuildRoot) then
  begin
    AError := 'fpc failed to compile ' + AHook.Script;
    DiagnosticMessage := BuildResultErrorMessage(BuildResult);
    if DiagnosticMessage <> '' then AError := AError + ': ' + DiagnosticMessage;
    if CompilerOutput <> '' then AError := AError + LineEnding + CompilerOutput;
    Exit(1);
  end;
  Bin := NativePath(ExpandFileName(Bin));
  {$ENDIF}

  P := TProcess.Create(nil);
  try
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
    {$IFDEF MSWINDOWS}
    P.Executable := Bin;
    {$ELSE}
    P.Executable := InstantFPCExecutable;
    if ABuildRoot <> '' then
    begin
      CacheRoot := IncludeTrailingPathDelimiter(ABuildRoot)
        + 'instantfpc/' + BuildSessionPathKey(ExpandFileName(AHook.Script));
      ForceDirectories(CacheRoot);
      P.Parameters.Add('--set-cache=' + CacheRoot);
    end;
    P.Parameters.Add(AHook.Script);
    {$ENDIF}
    for j := 0 to High(AHook.Args) do
      P.Parameters.Add(AHook.Args[j]);
    P.Options := [poWaitOnExit];
    try
      P.Execute;
    except
      on E: Exception do
      begin
        {$IFDEF MSWINDOWS}
        AError := 'compiled script unavailable (' + E.Message + ')';
        {$ELSE}
        AError := 'instantfpc unavailable (' + E.Message + ')';
        {$ENDIF}
        Exit(127);
      end;
    end;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

function RunPascalScript(const AHook: THook; out AError: string;
  const ABuildRoot: string): Integer;
begin
  Result := RunPascalScriptWithEnvironment(AHook, AError, ABuildRoot, []);
end;

procedure RunHooksWithEnvironment(const APhase: string;
  const AHooks: THookArray; const ABuildRoot: string;
  const AEnvironment: array of string);
var
  i, Code: Integer;
  H: THook;
  ScriptError: string;
begin
  if Length(AHooks) = 0 then Exit;
  for i := 0 to High(AHooks) do
  begin
    H := AHooks[i];

    if not HookIsStale(H) then
    begin
      WriteLn('  [', APhase, '] ', H.Name, ' (skipped — output fresh)');
      Continue;
    end;

    WriteLn('  [', APhase, '] ', H.Name);

    if not FileExists(H.Script) then
      raise EManifestError.CreateFmt(
        '[%s] %s: script not found at %s', [APhase, H.Name, H.Script]);

    Code := RunPascalScriptWithEnvironment(H, ScriptError, ABuildRoot,
      AEnvironment);
    if ScriptError <> '' then
      raise ELWPTError.CreateFmt(
        '[%s] %s: %s while running %s',
        [APhase, H.Name, ScriptError, H.Script]);

    if Code <> 0 then
      raise ELWPTError.CreateFmt(
        '[%s] %s: script exited %d while running %s',
        [APhase, H.Name, Code, H.Script]);
  end;
end;

procedure RunHooks(const APhase: string; const AHooks: THookArray;
  const ABuildRoot: string);
begin
  RunHooksWithEnvironment(APhase, AHooks, ABuildRoot, []);
end;

function RunUserScript(const AHook: THook): Integer;
var
  ScriptError: string;
begin
  if not FileExists(AHook.Script) then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: script not found at ',
      AHook.Script);
    Exit(127);
  end;
  Result := RunPascalScript(AHook, ScriptError);
  if ScriptError <> '' then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: ', ScriptError, '.');
    if Result = 0 then Result := 1;
  end;
end;

end.
