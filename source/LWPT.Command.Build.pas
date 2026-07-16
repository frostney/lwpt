{ LWPT.Command.Build — build subcommand entrypoint. }
unit LWPT.Command.Build;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

function CmdBuild(const AManifestPath: string;
  const ATargetNames: array of string; ARelease, AClean: Boolean): Integer;

{ Exposed for unit tests: does this FPC failure output look like stale
  build artefacts (worth a --clean retry) rather than a source error? }
function HasStaleArtefactSignature(const AOutput: string): Boolean;

implementation

uses
  Classes,
  Process,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest,
  Platform;

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

{ Run FPC with the given arguments, echoing its output live (chunk by
  chunk, as the old inherited-stdio path did) while also accumulating
  it for the stale-artefact inspection on failure. Returns the fpc
  exit code. A compiler that cannot be started raises (EProcess);
  CmdBuild's per-target containment turns that into a failed target.
  SetString carries an explicit length, so the accumulation is
  byte-safe regardless of chunk content. }
function RunFPCEchoed(const AArgs: TStringArray;
  out AOutput: string): Integer;
var
  P: TProcess;
  Buf: array[0..4095] of Byte;
  Chunk: string;
  i, N: Integer;
begin
  AOutput := '';
  P := TProcess.Create(nil);
  try
    P.Executable := FPCExecutable;
    for i := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes, poStderrToOutPut];
    P.Execute;
    { Blocking read until EOF: drains the pipe as FPC produces output,
      so large compiles can neither deadlock the pipe nor go silent. }
    repeat
      N := P.Output.Read(Buf[0], SizeOf(Buf));
      if N > 0 then
      begin
        SetString(Chunk, PAnsiChar(@Buf[0]), N);
        Write(Chunk);
        Flush(Output);
        AOutput := AOutput + Chunk;
      end;
    until N <= 0;
    P.WaitOnExit;
    Result := P.ExitStatus;
  finally
    P.Free;
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
  ASession: TLWPTBuildSession; out ACompiled: TLWPTCompiledTarget): Boolean;
var
  Args : TStringList;
  FpcArgs : TStringArray;
  Arch, OutBin, JobRoot, BinDir, CandidateBin, UnitOutDir, OutText,
    Fingerprint, ProjectRoot, CfgPath, ModulesPath : string;
  i, FpcExit : Integer;
  Request: TLWPTBuildPublicationRequest;
begin
  ACompiled := Default(TLWPTCompiledTarget);
  if T.Source = '' then
  begin
    WriteLn(ErrOutput, '  target "', T.Name, '" has no source — skipped');
    Exit(False);
  end;

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

  Write('  building ', T.Name, ' (', T.Source, ') ... ');

  ProjectRoot := ExtractFileDir(ExpandFileName(AManifestPath));
  CfgPath := ResolveCfgFile(AMan);
  ModulesPath := ResolveModulesDir(AMan);
  Request := Default(TLWPTBuildPublicationRequest);
  Request.CompilerID := 'fpc';
  Request.CompilerExecutable := FPCExecutable;
  Request.CompilerVersion := QueryFPCVersion;
  Request.ManifestContentHash := AManifestContentHash;
  Request.Source := T.Source;
  Request.Output := OutBin;
  Request.OutputKind := 'executable';
  if ARelease then Request.Mode := 'release' else Request.Mode := 'dev';
  Request.TargetOS := GetEnvironmentVariable('FPC_TARGET_OS');
  if Request.TargetOS = '' then Request.TargetOS := GetBuildOS;
  Request.TargetCPU := GetEnvironmentVariable('FPC_TARGET_CPU');
  if Request.TargetCPU = '' then Request.TargetCPU := GetBuildArch;
  SetLength(Request.Environment, 1);
  Request.Environment[0] := 'LWPT_FPC_UNIT_PATHS='
    + GetEnvironmentVariable('LWPT_FPC_UNIT_PATHS');
  Request.UnitPaths := Copy(AMan.Units, 0, Length(AMan.Units));
  Request.IncludePaths := Copy(AMan.Includes, 0, Length(AMan.Includes));
  SetLength(Request.WorkspacePaths, Length(AMan.Workspaces));
  for i := 0 to High(AMan.Workspaces) do
    Request.WorkspacePaths[i] := AMan.Workspaces[i].Path;
  AddHookPublicationInputs(T.PostBuild, Request);
  AddHookPublicationInputs(AMan.PostBuild, Request);
  ACompiled.PostBuild := RetargetPostBuildHooks(T.PostBuild,
    OutBin, CandidateBin);
  AppendEnvSearchPaths(Request.UnitPaths, Request.IncludePaths);
  AddDeclaredOutputs(AMan, Request.ExcludedPaths);
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
    AddEnvUnitPathParameters(Args);
    { manifest's own unit dirs — both as unit (-Fu) and include
      (-Fi) search paths. .inc files conventionally live next to
      .pas units, so the same dir serves both. }
    for i := 0 to High(AMan.Units) do
      if AMan.Units[i] <> '' then
      begin
        Args.Add('-Fu' + AMan.Units[i]);
        Args.Add('-Fi' + AMan.Units[i]);
      end;
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

  FpcExit := RunFPCEchoed(FpcArgs, OutText);
  Result := FpcExit = 0;

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

  { The streamed compiler output above follows fpc's own channel
    (fpc emits its messages on stdout); lwpt's own failure banner and
    hint are errors and belong on stderr. }
  if (not Result) and (FpcExit <> 0) then
    WriteLn(ErrOutput, 'FAILED (fpc exit ', FpcExit, ')');

  if (not Result) and (not AClean)
     and HasStaleArtefactSignature(OutText) then
  begin
    WriteLn(ErrOutput,
      '  hint: stale FPC build artefacts can cause this error.');
    WriteLn(ErrOutput,
      '  retry with: ', PROGRAM_NAME, ' build ', T.Name, ' --clean');
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

{ Does any entry of ANames match AName (case-insensitive)? }
function NameListed(const AName: string;
  const ANames: array of string): Boolean;
var i: Integer;
begin
  for i := 0 to High(ANames) do
    if SameText(ANames[i], AName) then Exit(True);
  Result := False;
end;

function CmdBuild(const AManifestPath: string;
  const ATargetNames: array of string; ARelease, AClean: Boolean): Integer;
var
  Man : TManifest;
  i, j, Built, Failed, Unknown : Integer;
  Matched : Boolean;
  ModeStr, CollA, CollB : string;
  ManifestContentHash: string;
  Session: TLWPTBuildSession;
  Compiled: TLWPTCompiledTarget;
  Pending: TLWPTCompiledTargetArray;
  PublicationRequest: TLWPTBuildPublicationRequest;
  WholePostBuild: THookArray;
  HookEnvironment: array of string;
begin
  if not FileExists(AManifestPath) then
    raise EManifestError.CreateFmt(
      'manifest not found at %s', [AManifestPath]);
  Man := LoadManifestSnapshot(AManifestPath, ManifestContentHash);

  if Length(Man.Targets) = 0 then
  begin
    WriteLn('no [build] entries defined in ', AManifestPath);
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
  if Unknown > 0 then Exit(1);

  if FindArtefactDirCollision(Man.Targets, CollA, CollB) then
  begin
    WriteLn(ErrOutput, 'targets "', CollA, '" and "', CollB,
      '" map to the same session job directory ', TargetJobSegment(CollA),
      ' — rename one');
    Exit(1);
  end;

  if ARelease then ModeStr := 'release' else ModeStr := 'dev';
  if AClean then ModeStr := ModeStr + ', clean';
  WriteLn('build mode: ', ModeStr);
  Session := TLWPTBuildSession.Create(
    ExtractFileDir(ExpandFileName(AManifestPath)));
  try
    WriteLn('build session: ', Session.SessionID);
    { --clean means a forced compile in fresh private staging. It never
      deletes the last successful public output or another live session. }
    RunHooks('prebuild', Man.PreBuild, Session.HookRoot);
    GenerateVersionInclude(
      ExtractFileDir(ExpandFileName(AManifestPath)), Man);

    Built := 0; Failed := 0;
    SetLength(Pending, 0);
    for i := 0 to High(Man.Targets) do
    begin
      if (Length(ATargetNames) > 0)
         and (not NameListed(Man.Targets[i].Name, ATargetNames)) then
        Continue;
      RunHooks('prebuild:' + Man.Targets[i].Name,
        Man.Targets[i].PreBuild, Session.HookRoot);
      try
        if BuildOneTarget(AManifestPath, Man, ManifestContentHash,
          Man.Targets[i],
          ARelease, AClean, Session, Compiled) then
        begin
          SetLength(HookEnvironment, 3);
          HookEnvironment[0] := 'LWPT_BUILD_TARGET=' + Compiled.Name;
          HookEnvironment[1] := 'LWPT_BUILD_OUTPUT='
            + Compiled.CandidateBin;
          HookEnvironment[2] := 'LWPT_BUILD_PUBLIC_OUTPUT='
            + Compiled.OutBin;
          RunHooksWithEnvironment('postbuild:' + Man.Targets[i].Name,
            Compiled.PostBuild, Session.HookRoot, HookEnvironment);
          j := Length(Pending);
          SetLength(Pending, j + 1);
          Pending[j] := Compiled;
        end
        else
          Inc(Failed);
      except
        on E: Exception do
        begin
          WriteLn(ErrOutput, '  target "', Man.Targets[i].Name,
            '" failed: ', E.Message);
          Inc(Failed);
        end;
      end;
    end;

    if Failed = 0 then
    begin
      WholePostBuild := Man.PostBuild;
      for i := 0 to High(Pending) do
        WholePostBuild := RetargetPostBuildHooks(WholePostBuild,
          Pending[i].OutBin, Pending[i].CandidateBin);
      RunHooks('postbuild', WholePostBuild, Session.HookRoot);

      for i := 0 to High(Pending) do
      begin
        PublicationRequest := Pending[i].Request;
        PublicationRequest.CompilerVersion := QueryFPCVersion;
        if PublishBuildArtifact(Pending[i].ProjectRoot,
          Pending[i].CandidateBin, Pending[i].OutBin,
          Pending[i].Fingerprint, AManifestPath, Pending[i].CfgPath,
          LOCKFILE, Pending[i].ModulesPath,
          PublicationRequest) = bprStale then
        begin
          Inc(Failed);
          WriteLn(ErrOutput, 'STALE (inputs changed during compilation; ',
            'private result for ', Pending[i].Name,
            ' was not published)');
        end
        else
        begin
          Inc(Built);
          WriteLn('ok -> ', Pending[i].OutBin);
        end;
      end;
    end;
    WriteLn;
    WriteLn(Built, ' built, ', Failed, ' failed');
    Result := Ord(Failed <> 0);
    Session.Finish(Failed = 0,
      IntToStr(Failed) + ' target(s) failed or became stale');
  finally
    Session.Free;
  end;
end;

end.
