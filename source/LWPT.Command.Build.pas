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

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest;

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

{ --clean sweep: recursively remove FPC intermediate artefacts from the
  build output dir. Extension-based (.ppu/.o/.or/.res/.reslst) so target
  binaries and anything a postbuild hook placed under build/ survive.
  A stale dependency .ppu left by an older FPC run poisons every target
  that uses the unit — the per-target deletes only ever covered the
  target's own source, which is why this sweeps the whole tree once.
  ARemoved/AFailed accumulate across the recursion; a failed delete
  (locked file on Windows, permissions) must be surfaced, because a
  sweep that silently leaves the stale artefact behind makes the
  --clean retry hint a dead end. }
procedure SweepBuildArtefacts(const ADir: string;
  var ARemoved, AFailed: Integer);
const
  ARTEFACT_EXTS: array[0..4] of string
    = ('.ppu', '.o', '.or', '.res', '.reslst');
var
  SR: TSearchRec;
  Base, Ext: string;
  i: Integer;
begin
  if not DirectoryExists(ADir) then Exit;
  Base := IncludeTrailingPathDelimiter(ADir);
  { faSymLink in the mask makes FindFirst report links as links
    (lstat); without it a symlink-to-dir is indistinguishable from a
    real dir and the recursion would escape build/ — deleting
    artefacts outside the tree or looping forever on a cyclic link.
    Links are never followed; one whose own name matches an artefact
    extension is merely unlinked. }
  if SysUtils.FindFirst(Base + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if ((SR.Attr and faDirectory) <> 0)
           and ((SR.Attr and faSymLink) = 0) then
          SweepBuildArtefacts(Base + SR.Name, ARemoved, AFailed)
        else
        begin
          Ext := LowerCase(ExtractFileExt(SR.Name));
          for i := 0 to High(ARTEFACT_EXTS) do
            if Ext = ARTEFACT_EXTS[i] then
            begin
              if SysUtils.DeleteFile(Base + SR.Name) then
                Inc(ARemoved)
              else
                Inc(AFailed);
              Break;
            end;
        end;
      until FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
end;

{ Run FPC with the given arguments, echoing its output live (chunk by
  chunk, as the old inherited-stdio path did) while also accumulating
  it for the stale-artefact inspection on failure. Returns False only
  when the executable could not be started at all. SetString carries
  an explicit length, so the accumulation is byte-safe regardless of
  chunk content. }
function RunFPCEchoed(const AArgs: TStringArray; out AOutput: string;
  out AExitCode: Integer): Boolean;
var
  P: TProcess;
  Buf: array[0..4095] of Byte;
  Chunk: string;
  i, N: Integer;
begin
  AOutput := '';
  AExitCode := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := FPCExecutable;
    for i := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes, poStderrToOutPut];
    try
      P.Execute;
    except
      Exit(False);
    end;
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
    AExitCode := P.ExitStatus;
    Result := True;
  finally
    P.Free;
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

procedure GenerateVersionInclude(const AMan: TManifest);
var F: TextFile; Pfx: string;
begin
  if AMan.VersionIncOut = '' then Exit;   { [version] not configured }
  Pfx := AMan.VersionPrefix;
  if Pfx = '' then Pfx := 'BAKED';
  ForceDirectories(ExtractFileDir(AMan.VersionIncOut));
  AssignFile(F, AMan.VersionIncOut);
  Rewrite(F);
  try
    WriteLn(F, '// Auto-generated by ', PROGRAM_NAME,
            ' build — do not edit');
    WriteLn(F, 'const');
    WriteLn(F, '  ', Pfx, '_VERSION = ''', AMan.Version, ''';');
    WriteLn(F, '  ', Pfx, '_BUILD_DATE = ''',
      FormatDateTime('yyyy-mm-dd', Now), ''';');
  finally
    CloseFile(F);
  end;
  WriteLn('  generated ', AMan.VersionIncOut);
end;

{ Compile one build target. Returns True on success. }
function BuildOneTarget(const AMan: TManifest; const T: TBuildTarget;
  ARelease, AClean: Boolean): Boolean;
var
  Args : TStringList;
  FpcArgs : TStringArray;
  Arch, OutBin, OutText : string;
  i, FpcExit : Integer;
  RanOk : Boolean;
begin
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
  if ExtractFileDir(OutBin) <> '' then
    ForceDirectories(ExtractFileDir(OutBin));
  ForceDirectories('build');

  { clean build: remove the stale binary plus the legacy source-adjacent
    artefacts (pre--FEbuild FPC defaults). build/ itself was already
    swept once by CmdBuild before the target loop. }
  if AClean then
  begin
    if FileExists(OutBin) then DeleteFile(OutBin);
    DeleteFile(ChangeFileExt(T.Source, '.o'));
    DeleteFile(ChangeFileExt(T.Source, '.ppu'));
  end;

  Write('  building ', T.Name, ' (', T.Source, ') ... ');

  Args := TStringList.Create;
  try
    { cross-compile target CPU via env var, same hook as build.pas }
    Arch := GetEnvironmentVariable('FPC_TARGET_CPU');
    if Arch <> '' then Args.Add('-P' + Arch);

    Args.Add('-Sh');
    Args.Add('-FEbuild');
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
    Args.Add('-o' + OutBin);
    Args.Add(T.Source);

    SetLength(FpcArgs, Args.Count);
    for i := 0 to Args.Count - 1 do
      FpcArgs[i] := Args[i];
  finally
    Args.Free;
  end;

  RanOk := RunFPCEchoed(FpcArgs, OutText, FpcExit);
  Result := RanOk and (FpcExit = 0);

  if Result then
    WriteLn('ok -> ', OutBin)
  else if RanOk then
    WriteLn('FAILED (fpc exit ', FpcExit, ')')
  else
    WriteLn('FAILED (could not run ', FPCExecutable, ')');

  if (not Result) and (not AClean)
     and HasStaleArtefactSignature(OutText) then
  begin
    WriteLn('  hint: stale FPC build artefacts can cause this error.');
    WriteLn('  retry with: ', PROGRAM_NAME, ' build ', T.Name, ' --clean');
  end;
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
  i, j, Built, Failed, Unknown, Swept, SweepFailed : Integer;
  Matched : Boolean;
  ModeStr : string;
begin
  Man := LoadManifest(AManifestPath);

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

  if ARelease then ModeStr := 'release' else ModeStr := 'dev';
  if AClean then ModeStr := ModeStr + ', clean';
  WriteLn('build mode: ', ModeStr);

  { --clean: one whole-tree sweep before anything compiles. Runs ahead
    of the prebuild hooks so a hook output written this run is never
    swept away. }
  if AClean then
  begin
    Swept := 0;
    SweepFailed := 0;
    SweepBuildArtefacts('build', Swept, SweepFailed);
    if (Swept = 0) and (SweepFailed = 0) then
      WriteLn('  clean: no FPC artefacts under build/')
    else
      WriteLn('  clean: removed ', Swept, ' FPC artefact file(s) from build/');
    if SweepFailed > 0 then
      WriteLn(ErrOutput, '  clean: ', SweepFailed, ' artefact file(s) could',
        ' not be removed (locked?) — stale state may persist');
  end;

  { Whole-build prebuild hooks (ADR-0011). Fires once before the
    target loop. Replaces the old RunGenerators call — staleness-
    gated entries fold in unchanged via the inputs/output pair. }
  RunHooks('prebuild', Man.PreBuild);

  GenerateVersionInclude(Man);

  Built := 0; Failed := 0;
  for i := 0 to High(Man.Targets) do
  begin
    { if target names were given, build only those (manifest order) }
    if (Length(ATargetNames) > 0)
       and (not NameListed(Man.Targets[i].Name, ATargetNames)) then
      Continue;
    { Per-target prebuild — fires immediately before this target's
      fpc invocation (e.g. version-stamp, codegen for this target). }
    RunHooks('prebuild:' + Man.Targets[i].Name,
      Man.Targets[i].PreBuild);
    if BuildOneTarget(Man, Man.Targets[i], ARelease, AClean) then
      Inc(Built)
    else
      Inc(Failed);
    { Per-target postbuild fires regardless of compile success;
      we want sign/strip/package even on a stale binary. }
    RunHooks('postbuild:' + Man.Targets[i].Name,
      Man.Targets[i].PostBuild);
  end;

  { Whole-build postbuild — last thing before we exit. Fires even
    if some targets failed (mirrors the per-target postbuild
    semantics; let users notify/upload regardless). }
  RunHooks('postbuild', Man.PostBuild);

  WriteLn;
  WriteLn(Built, ' built, ', Failed, ' failed');
  if Failed = 0 then Result := 0 else Result := 1;
end;

end.
