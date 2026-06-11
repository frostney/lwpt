{ LWPT.Command.Format — format subcommand entrypoint and scope expansion. }
unit LWPT.Command.Format;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes;

function  CmdFormat(const AManifestPath: string; ACheckOnly: Boolean): Integer;
procedure ExpandFormatPattern(const APattern: string; AList: TStringList; AErrorOnMissingLiteral: Boolean);

implementation

uses
  SysUtils,

  LWPT.Core,
  LWPT.Formatter,
  LWPT.Manifest;

{ Wraps the LWPT.Formatter unit (converted from GocciaScript format.pas).
  `lwpt format`         rewrites files in place
  `lwpt format --check` reports files that need formatting, exits 1 if any
  =========================================================================== }

{ ===========================================================================
  Format scope resolution — ADR-0007.

  The scope is composed declaratively from the manifest:
    seed     = [package].units (each as plain dir, non-recursive)
    add      = [format].include (globs)
    subtract = [format].exclude (globs)

  Glob syntax:
    *   matches one path segment (no /)
    **  matches any depth (recursion is explicit)
    ?   matches one non-/ character
    literal (no glob chars) → either a file or a dir-shorthand expansion

  Plain dir shorthand: `tests` ≡ `tests/` ≡ `tests/*.{pas,inc,dpr,lpr}`
  (top-level only). Hidden files / dirs (leading `.`) are skipped by
  wildcard segments; a segment that itself starts with `.` names the
  hidden entry explicitly and matches it (shell glob convention —
  needed so `exclude = [".lwpt/**"]` can carve out units entries that
  point into .lwpt/).

  Missing literal paths → EManifestError. Missing glob matches → silent.
  =========================================================================== }
const
  FORMATTABLE_EXTS: array[0..3] of string = ('.pas', '.inc', '.dpr', '.lpr');

function IsFormattableExt(const AName: string): Boolean; inline;
var
  Ext: string;
  i: Integer;
begin
  Ext := LowerCase(ExtractFileExt(AName));
  for i := Low(FORMATTABLE_EXTS) to High(FORMATTABLE_EXTS) do
    if Ext = FORMATTABLE_EXTS[i] then Exit(True);
  Result := False;
end;

function IsHiddenName(const AName: string): Boolean; inline;
begin
  Result := (Length(AName) > 0) and (AName[1] = '.');
end;

function PatternHasGlobChars(const APattern: string): Boolean; inline;
begin
  Result := (Pos('*', APattern) > 0) or (Pos('?', APattern) > 0);
end;

{ Single-segment glob match: * matches any sequence of non-'/' chars,
  ? matches exactly one non-'/' char, anything else is literal. The
  segment has no '/' by construction (we split first). Case-sensitive
  per ADR-0007. Standard iterative-star-backtracking algorithm — no
  recursion, O(N*M) worst case but the M (pattern length) is tiny. }
function MatchSegment(const APattern, AName: string): Boolean;
var
  P, N, StarP, StarN: Integer;
begin
  P := 1; N := 1;
  StarP := 0; StarN := 0;
  while N <= Length(AName) do
  begin
    if (P <= Length(APattern)) and (APattern[P] = '?') then
    begin Inc(P); Inc(N); end
    else if (P <= Length(APattern)) and (APattern[P] = '*') then
    begin StarP := P; Inc(P); StarN := N; end
    else if (P <= Length(APattern)) and (APattern[P] = AName[N]) then
    begin Inc(P); Inc(N); end
    else if StarP <> 0 then
    begin P := StarP + 1; Inc(StarN); N := StarN; end
    else
      Exit(False);
  end;
  while (P <= Length(APattern)) and (APattern[P] = '*') do Inc(P);
  Result := P > Length(APattern);
end;

procedure SplitGlobSegments(const APattern: string; ASegments: TStringList);
var
  i, Start: Integer;
begin
  ASegments.Clear;
  Start := 1;
  for i := 1 to Length(APattern) do
    if APattern[i] = '/' then
    begin
      if i > Start then
        ASegments.Add(Copy(APattern, Start, i - Start));
      Start := i + 1;
    end;
  if Start <= Length(APattern) then
    ASegments.Add(Copy(APattern, Start, MaxInt));
end;

{ Non-recursive walk: add formattable files at the top level of ADir.
  Used by the [package].units seed and by plain-dir-shorthand expansion. }
procedure CollectFormattableInDir(const ADir: string; AList: TStringList);
var SR: TSearchRec; Base: string;
begin
  if not DirectoryExists(ADir) then Exit;
  Base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if IsHiddenName(SR.Name) then Continue;
        if (SR.Attr and faDirectory) <> 0 then Continue;
        if IsFormattableExt(SR.Name) then
          AList.Add(ExpandFileName(Base + SR.Name));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
end;

{ Recursive glob walker. ASegments is the glob split on '/'. AIndex is
  the current segment index. ABase is the current directory. Adds every
  matching file to AList (only files, only formattable extensions).
  Handles `**` as zero-or-more directory levels. }
procedure WalkSegments(const ABase: string; ASegments: TStringList;
  AIndex: Integer; AList: TStringList);
var
  SR: TSearchRec;
  Seg, EntryPath: string;
  IsDir: Boolean;
begin
  if AIndex >= ASegments.Count then
  begin
    { Pattern exhausted at ABase — add all formattable files at this
      level. Reached only via `tests/**` style patterns where the
      trailing ** has matched zero+ segments. }
    CollectFormattableInDir(ABase, AList);
    Exit;
  end;

  Seg := ASegments[AIndex];

  if Seg = '**' then
  begin
    { ** matches zero levels (advance to next segment at this base) ... }
    WalkSegments(ABase, ASegments, AIndex + 1, AList);
    { ... or one+ levels (descend into each subdir, ** still here). }
    if FindFirst(IncludeTrailingPathDelimiter(ABase) + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if IsHiddenName(SR.Name) then Continue;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            EntryPath := IncludeTrailingPathDelimiter(ABase) + SR.Name;
            WalkSegments(EntryPath, ASegments, AIndex, AList);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    Exit;
  end;

  { Plain segment (may contain * / ?). Match against entries at ABase.
    Hidden entries are skipped UNLESS the segment itself starts with
    '.' — naming the hidden dir/file explicitly opts in, matching
    shell glob convention (`*` hides dotfiles; `.lwpt/*` does not).
    This is what lets [format].exclude carve [package].units entries
    that point into .lwpt/ back out of the scope. }
  if FindFirst(IncludeTrailingPathDelimiter(ABase) + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if IsHiddenName(SR.Name) and not IsHiddenName(Seg) then Continue;
        if not MatchSegment(Seg, SR.Name) then Continue;
        EntryPath := IncludeTrailingPathDelimiter(ABase) + SR.Name;
        IsDir := (SR.Attr and faDirectory) <> 0;
        if AIndex = ASegments.Count - 1 then
        begin
          { Last segment — only files at this position contribute. }
          if not IsDir and IsFormattableExt(SR.Name) then
            AList.Add(ExpandFileName(EntryPath));
        end
        else if IsDir then
          WalkSegments(EntryPath, ASegments, AIndex + 1, AList);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
end;

{ Expand one [format] include/exclude entry into AList. Literal paths
  either resolve to a file (added if formattable) or a dir (expanded
  via the plain-dir shorthand). Glob patterns are walked via the
  algorithm above. AErrorOnMissingLiteral controls behavior when the
  entry has no glob chars and resolves to nothing (per ADR-0007:
  literals assert presence; globs are silent on zero match). }
procedure ExpandFormatPattern(const APattern: string; AList: TStringList;
  AErrorOnMissingLiteral: Boolean);
var
  Cleaned: string;
  Segments: TStringList;
begin
  if APattern = '' then Exit;

  Cleaned := APattern;
  if Cleaned[Length(Cleaned)] = '/' then
    Delete(Cleaned, Length(Cleaned), 1);
  if Cleaned = '' then Exit;

  if not PatternHasGlobChars(Cleaned) then
  begin
    if FileExists(Cleaned) then
    begin
      if IsFormattableExt(Cleaned) then
        AList.Add(ExpandFileName(Cleaned));
    end
    else if DirectoryExists(Cleaned) then
      CollectFormattableInDir(Cleaned, AList)
    else if AErrorOnMissingLiteral then
      raise EManifestError.CreateFmt(
        '[format] literal path "%s" does not exist', [APattern]);
    Exit;
  end;

  Segments := TStringList.Create;
  try
    SplitGlobSegments(Cleaned, Segments);
    if Segments.Count > 0 then
      WalkSegments('.', Segments, 0, AList);
  finally
    Segments.Free;
  end;
end;

procedure DedupAbsolutePaths(AList: TStringList);
var i: Integer;
begin
  AList.Sort;
  i := AList.Count - 1;
  while i > 0 do
  begin
    if AList[i] = AList[i - 1] then AList.Delete(i);
    Dec(i);
  end;
end;

function CmdFormat(const AManifestPath: string; ACheckOnly: Boolean): Integer;
var
  Man : TManifest;
  Files, ExcludeSet, FinalFiles : TStringList;
  i, Changed : Integer;
  Path : string;
  RunMode : TRunMode;
begin
  Man := LoadManifest(AManifestPath);

  if ACheckOnly then
    RunMode := rmCheck
  else
    RunMode := rmFormat;

  Files       := TStringList.Create;
  ExcludeSet  := TStringList.Create;
  FinalFiles  := TStringList.Create;
  try
    { Seed: [package].units (non-recursive — see ADR-0007). }
    for i := 0 to High(Man.Units) do
      CollectFormattableInDir(Man.Units[i], Files);

    { Add: [format].include. Literal-path-missing is a hard error. }
    for i := 0 to High(Man.FormatIncludes) do
      ExpandFormatPattern(Man.FormatIncludes[i], Files, True);

    { Fallback: both sources empty → walk cwd non-recursively. Lets
      single-file scripts work without manifest ceremony. }
    if (Length(Man.Units) = 0) and (Length(Man.FormatIncludes) = 0) then
      CollectFormattableInDir('.', Files);

    { Subtract: [format].exclude. Same expansion rules as include. }
    for i := 0 to High(Man.FormatExcludes) do
      ExpandFormatPattern(Man.FormatExcludes[i], ExcludeSet, True);

    DedupAbsolutePaths(Files);
    DedupAbsolutePaths(ExcludeSet);

    for i := 0 to Files.Count - 1 do
    begin
      Path := Files[i];
      if ExcludeSet.IndexOf(Path) < 0 then
        FinalFiles.Add(Path);
    end;

    if FinalFiles.Count = 0 then
    begin
      WriteLn('no source files in scope');
      Exit(0);
    end;

    Changed := 0;
    for i := 0 to FinalFiles.Count - 1 do
      if FormatFile(FinalFiles[i], RunMode) then
      begin
        Inc(Changed);
        if ACheckOnly then
          WriteLn('  needs formatting: ', ExtractFileName(FinalFiles[i]))
        else
          WriteLn('  formatted: ', ExtractFileName(FinalFiles[i]));
      end;

    WriteLn;
    if ExcludeSet.Count > 0 then
      WriteLn(ExcludeSet.Count, ' file(s) skipped via [format] exclude');
    if ACheckOnly then
    begin
      if Changed > 0 then
      begin
        WriteLn(Changed, ' of ', FinalFiles.Count,
                ' file(s) need formatting');
        Result := 1;
      end
      else
      begin
        WriteLn(FinalFiles.Count,
                ' file(s) checked — all correctly formatted');
        Result := 0;
      end;
    end
    else
    begin
      WriteLn(Changed, ' of ', FinalFiles.Count,
              ' file(s) formatted');
      Result := 0;
    end;
  finally
    Files.Free;
    ExcludeSet.Free;
    FinalFiles.Free;
  end;
end;

end.
