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
              begin
                WriteLn(ErrOutput, '  clean: could not remove ',
                  Base + SR.Name);
                Inc(AFailed);
              end;
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

{ Root of one target's private artefact dir: build/targets/<name>.
  Target names are TOML keys, not validated path segments — sanitise
  separators defensively. Names that would resolve outside
  build/targets/ ("", ".", "..") are rejected at manifest load by
  ValidateTargetName; the raise here is the backstop for any future
  caller that bypasses the manifest. Sanitisation can collide two
  distinct names — CmdBuild rejects such manifests up front. }
function TargetBuildRoot(const ATargetName: string): string;
var Safe: string;
begin
  Safe := SanitisePathSegment(ATargetName);
  if (Safe = '') or (Safe = '.') or (Safe = '..') then
    raise ELWPTError.CreateFmt(
      'unsafe build target name "%s"', [ATargetName]);
  Result := 'build/targets/' + Safe;
end;

{ Compile one build target. Returns True on success. }
function BuildOneTarget(const AMan: TManifest; const T: TBuildTarget;
  ARelease, AClean: Boolean): Boolean;
var
  Args : TStringList;
  FpcArgs : TStringArray;
  Arch, OutBin, TargetRoot, UnitOutDir, OutText : string;
  i, FpcExit : Integer;

  { --clean delete that must not fail silently: a file that exists but
    cannot be removed raises, because proceeding would keep exactly
    the stale state --clean promised to remove (DeleteFile alone also
    returns False for a merely-missing file, which is fine). }
  procedure CleanDelete(const APath: string);
  begin
    if FileExists(APath) and (not SysUtils.DeleteFile(APath)) then
      raise ELWPTError.CreateFmt(
        'clean: could not remove stale "%s"', [APath]);
  end;
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

  { Per-target, per-mode unit-output dir. Units compiled for one target
    (or one mode of it) must never be reused by another: per-target
    prebuild hooks can regenerate shared sources between targets, and
    FPC does not re-check conditional defines when reusing a .ppu. }
  TargetRoot := TargetBuildRoot(T.Name);
  if ARelease then
    UnitOutDir := TargetRoot + '/release'
  else
    UnitOutDir := TargetRoot + '/dev';

  { clean build: remove the stale binary, the target's whole artefact
    dir (both modes), and source-adjacent FPC artefacts. The latter
    are load-bearing, not cosmetic: source dirs sit on -Fu, so a stale
    .ppu there (from a raw `fpc @lwpt.cfg` run) poisons rebuilds.
    Strays elsewhere under build/ (pre-isolation layout, bootstrap,
    per-test dirs) were already removed by CmdBuild's one whole-tree
    sweep before the target loop.
    A failed wipe or delete (locked file, permissions) raises; the
    per-target containment in CmdBuild's loop turns it into a failed
    target. }
  if AClean then
  begin
    CleanDelete(OutBin);
    WipeDir(TargetRoot);
    CleanDelete(ChangeFileExt(T.Source, '.o'));
    CleanDelete(ChangeFileExt(T.Source, '.ppu'));
  end;
  ForceDirectories(UnitOutDir);

  Write('  building ', T.Name, ' (', T.Source, ') ... ');

  Args := TStringList.Create;
  try
    { cross-compile target CPU via env var, same hook as build.pas }
    Arch := GetEnvironmentVariable('FPC_TARGET_CPU');
    if Arch <> '' then Args.Add('-P' + Arch);

    Args.Add('-Sh');
    { -FE is the exe fallback for outputs without a dir component;
      -FU overrides it for units only, isolating .ppu/.o per
      target + mode while -o keeps the binary at the manifest path. }
    Args.Add('-FEbuild');
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
    Args.Add('-o' + OutBin);
    Args.Add(T.Source);

    SetLength(FpcArgs, Args.Count);
    for i := 0 to Args.Count - 1 do
      FpcArgs[i] := Args[i];
  finally
    Args.Free;
  end;

  FpcExit := RunFPCEchoed(FpcArgs, OutText);
  Result := FpcExit = 0;

  { The streamed compiler output above follows fpc's own channel
    (fpc emits its messages on stdout); lwpt's own failure banner and
    hint are errors and belong on stderr. }
  if Result then
    WriteLn('ok -> ', OutBin)
  else
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

{ Two distinct target names that sanitise to the same artefact dir
  would silently share unit output — exactly the poisoning the
  per-target split exists to prevent. Rejected up front in CmdBuild.
  SameText: artefact dirs land on case-insensitive filesystems on
  Windows and macOS. }
function FindArtefactDirCollision(const ATargets: array of TBuildTarget;
  out AFirst, ASecond: string): Boolean;
var i, j: Integer;
begin
  for i := 0 to High(ATargets) do
    for j := i + 1 to High(ATargets) do
      if SameText(TargetBuildRoot(ATargets[i].Name),
                  TargetBuildRoot(ATargets[j].Name)) then
      begin
        AFirst  := ATargets[i].Name;
        ASecond := ATargets[j].Name;
        Exit(True);
      end;
  Result := False;
end;

{ Remove build/targets/ subdirs no current target owns — leftovers
  from renamed or deleted [build] entries. Best-effort: an
  undeletable orphan warns and stays; it is inert either way. }
procedure PruneOrphanTargetDirs(const ATargets: array of TBuildTarget);
var
  SR    : TSearchRec;
  i     : Integer;
  Full  : string;
  Owned : Boolean;
begin
  if FindFirst('build/targets/*', faDirectory, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) = 0 then Continue;
      Full := 'build/targets/' + SR.Name;
      Owned := False;
      for i := 0 to High(ATargets) do
        if SameText(TargetBuildRoot(ATargets[i].Name), Full) then
        begin
          Owned := True;
          Break;
        end;
      if Owned then Continue;
      try
        WipeDir(Full);
        WriteLn('  pruned ', Full, ' (no matching target)');
      except
        on E: Exception do
          WriteLn(ErrOutput, '  could not prune ', Full, ': ', E.Message);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
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
  ModeStr, CollA, CollB : string;
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

  if FindArtefactDirCollision(Man.Targets, CollA, CollB) then
  begin
    WriteLn(ErrOutput, 'targets "', CollA, '" and "', CollB,
      '" map to the same artefact dir ', TargetBuildRoot(CollA),
      ' — rename one');
    Exit(1);
  end;

  if ARelease then ModeStr := 'release' else ModeStr := 'dev';
  if AClean then ModeStr := ModeStr + ', clean';
  WriteLn('build mode: ', ModeStr);

  if AClean then
  begin
    { Renamed/deleted targets leave artefact dirs behind; a clean run
      is the natural moment to reclaim them. Prune before the sweep so
      orphan contents are reported as pruned dirs, not stray files. }
    PruneOrphanTargetDirs(Man.Targets);
    { One whole-tree sweep before anything compiles: catches strays
      the per-target wipes never see (pre-isolation layout, bootstrap
      output at the build/ root, per-test dirs). Runs ahead of the
      prebuild hooks so a hook output written this run is never swept
      away. }
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
    { Per-target failure containment: any exception out of the
      compile step — a failed clean wipe, a missing compiler
      (EProcess) — fails THIS target only, so postbuild hooks still
      fire and the remaining targets still build (ADR-0011). Hook
      failures above are deliberately NOT contained: hooks abort the
      run on first non-zero exit by design. }
    try
      if BuildOneTarget(Man, Man.Targets[i], ARelease, AClean) then
        Inc(Built)
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
