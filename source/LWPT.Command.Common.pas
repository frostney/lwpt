{ LWPT.Command.Common — shared command helpers. }
unit LWPT.Command.Common;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  LWPT.Manifest;

function  CompilePascal(const ASrcFile: string; const AUnitPaths: array of string;
  out AOutBin: string): Boolean;
function  RunPascalScript(const AHook: THook; out AError: string): Integer;
function  RunUserScript(const AHook: THook): Integer;
procedure RunHooks(const APhase: string; const AHooks: THookArray);

implementation

uses
  Process,

  LWPT.Core;

function TestBuildDir(const ASrcFile: string): string;
begin
  Result := 'build/tests/' + SanitisePathSegment(ChangeFileExt(ASrcFile, ''));
end;

function CompilePascal(const ASrcFile: string; const AUnitPaths: array of string;
  out AOutBin: string): Boolean;
var
  P : TProcess;
  BuildDir : string;
  i : Integer;

  procedure AddCfgParameters(const APath: string);
  var
    Lines : TStringList;
    Line : string;
    j : Integer;
  begin
    if not FileExists(APath) then
      Exit;

    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(APath);
      for j := 0 to Lines.Count - 1 do
      begin
        Line := Trim(Lines[j]);
        if Line = '' then
          Continue;
        if Line[1] = '#' then
          Continue;
        P.Parameters.Add(Line);
      end;
    finally
      Lines.Free;
    end;
  end;
begin
  BuildDir := TestBuildDir(ASrcFile);
  ForceDirectories(BuildDir);
  AOutBin := IncludeTrailingPathDelimiter(BuildDir)
           + ChangeFileExt(ExtractFileName(ASrcFile), '');

  P := TProcess.Create(nil);
  try
    P.Executable := FPCExecutable;
    (* Deliberately NOT forcing -M<mode>: each source sets its own mode
       via {$I Shared.inc} or an explicit {$mode delphi}{$H+} header.
       Forcing a mode here would conflict with future vendored test
       files that ship their own directives. -Sh stays — it is a
       delphi/objfpc-compatible string-handling switch, not a mode.
       (Nested-comment support is per-file via {$MODESWITCH
       NESTEDCOMMENTS+}; FPC has no command-line equivalent.) *)
    P.Parameters.Add('-Sh');
    P.Parameters.Add('-FE' + BuildDir);   { all intermediates land here }
    { Inherit dep search paths from lwpt.cfg when present. After
      ADR-0014 (packages extraction), deps' unit subdirs live at
      .lwpt/modules/<name>/source/ and CmdTest's per-test compile
      needs them on -Fu / -Fi — without this, every test that
      transitively uses HTTPClient / CLI / Semver / TOML fails to
      compile with "can't find unit". Expand the response fragment
      directly here so test compilation is independent of per-platform
      FPC response-file parsing. The explicit AUnitPaths
      additions stay for the AUnitPaths-driven callers (preserves
      backwards-compat with non-cfg-based invocations). }
    AddCfgParameters(CFG_FILE);
    AddEnvUnitPathParameters(P.Parameters);
    for i := 0 to High(AUnitPaths) do
      if AUnitPaths[i] <> '' then
      begin
        P.Parameters.Add('-Fu' + AUnitPaths[i]);
        P.Parameters.Add('-Fi' + AUnitPaths[i]);
      end;
    P.Parameters.Add('-o' + AOutBin);
    P.Parameters.Add(ASrcFile);
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
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

function RunPascalScript(const AHook: THook; out AError: string): Integer;
var
  P: TProcess;
  j: Integer;
  {$IFDEF MSWINDOWS}
  Bin: string;
  {$ENDIF}
begin
  AError := '';
  {$IFDEF MSWINDOWS}
  if not CompilePascal(AHook.Script, [], Bin) then
  begin
    AError := 'fpc failed to compile ' + AHook.Script;
    Exit(1);
  end;
  if (not FileExists(Bin)) and FileExists(Bin + '.exe') then
    Bin := Bin + '.exe';
  Bin := NativePath(ExpandFileName(Bin));
  {$ENDIF}

  P := TProcess.Create(nil);
  try
    {$IFDEF MSWINDOWS}
    P.Executable := Bin;
    {$ELSE}
    P.Executable := InstantFPCExecutable;
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

procedure RunHooks(const APhase: string; const AHooks: THookArray);
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

    Code := RunPascalScript(H, ScriptError);
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
