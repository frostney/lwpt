{ LWPT.ManifestEdit — comment-preserving textual edits to the manifest's
  [dependencies] section (ADR-0019).

  `lwpt add` / `lwpt remove` edit exactly one `name = "<source>@<spec>"`
  line (plus the [dependencies] header when the section doesn't exist
  yet) and leave every other byte of lwpt.toml alone. This unit
  deliberately does NOT parse TOML — it operates on lines, with the
  real parser (LoadManifestContext) having validated the document
  moments earlier in the same command. Anything beyond the canonical
  single-line forms (a [dependencies.<name>] dotted table, a multi-line
  value) is out of scope; callers hard-error with a "edit by hand"
  pointer instead of guessing. }
unit LWPT.ManifestEdit;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Manifest;

function  DeriveDependencyName(const ADep: TDependency): string;
function  HasDirectDep(const AMan: TManifest; const AName: string): Boolean;
procedure RequireNotWorkspacePackage(const AMan: TManifest; const AName: string);
procedure LoadManifestLines(const APath: string; ALines: TStringList);
procedure SetDependencyLine(ALines: TStringList; const AName, ABareSpec: string; out AReplaced: Boolean);
function  RemoveDependencyLine(ALines: TStringList; const AName: string): Boolean;

implementation

const
  DEPENDENCIES_SECTION = 'dependencies';

{ ValidPackageName lives in LWPT.Manifest — the name grammar is the
  manifest's, shared with init's prompts and install's prune guard. }

{ Default dependency name from a parsed source: the repo half of a
  git-host "owner/repo" slug, or the basename of a local path. URL and
  workspace sources have no usable basename — the caller must require
  --name for those. Returns '' (caller errors) when no segment survives
  or the segment fails the package-name grammar (e.g. "my.lib"). }
function DeriveDependencyName(const ADep: TDependency): string;
var
  L: string;
  i: Integer;
begin
  Result := '';
  if not (ADep.SrcKind in [skGitHost, skLocal]) then Exit;
  L := ADep.SrcLocator;
  while (L <> '') and (L[Length(L)] in ['/', '\']) do
    SetLength(L, Length(L) - 1);
  for i := Length(L) downto 1 do
    if L[i] in ['/', '\'] then
    begin
      L := Copy(L, i + 1, MaxInt);
      Break;
    end;
  if ValidPackageName(L) then
    Result := L;
end;

{ Direct-dep lookup by name (SameText, mirroring the lockfile's
  case-insensitive comparisons). Note Deps also carries auto-added
  workspace virtual entries — callers that must distinguish check
  RequireNotWorkspacePackage first. }
function HasDirectDep(const AMan: TManifest; const AName: string): Boolean;
var k: Integer;
begin
  for k := 0 to High(AMan.Deps) do
    if SameText(AMan.Deps[k].Name, AName) then Exit(True);
  Result := False;
end;

{ Shared add/remove guard: workspace packages are managed by
  [workspaces] discovery, never by a [dependencies] entry — both
  editing directions are nonsense for them. }
procedure RequireNotWorkspacePackage(const AMan: TManifest;
  const AName: string);
var k: Integer;
begin
  for k := 0 to High(AMan.Workspaces) do
    if SameText(AMan.Workspaces[k].Name, AName) then
      raise EManifestError.CreateFmt(
        '"%s" is a workspace package (discovered via [workspaces] at %s); '
        + 'workspace packages are managed by [workspaces], not by a '
        + '[dependencies] entry', [AName, AMan.Workspaces[k].Path]);
end;

{ Load the manifest for a textual round-trip, preserving the file's
  line-ending style. TStringList.SaveToFile writes TextLineBreakStyle's
  break for every line — left at the platform default, a one-line edit
  on Windows would rewrite an LF manifest wholesale to CRLF. Detect the
  authored style from the raw bytes and pin it for the write-back. }
procedure LoadManifestLines(const APath: string; ALines: TStringList);
var
  Stream: TFileStream;
  Raw: AnsiString;
begin
  ALines.LoadFromFile(APath);
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Raw, Stream.Size);
    if Length(Raw) > 0 then
      Stream.ReadBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
  if Pos(#13#10, Raw) > 0 then
    ALines.TextLineBreakStyle := tlbsCRLF
  else
    ALines.TextLineBreakStyle := tlbsLF;
end;

{ The [dependencies] header, allowing trailing whitespace + comment.
  A commented-out header (init's "# [dependencies]" scaffold hint) is
  not a header — Trim leaves the '#' in front. }
function IsDependenciesHeader(const ALine: string): Boolean;
var T, Rest: string;
begin
  T := Trim(ALine);
  Result := Copy(T, 1, Length(DEPENDENCIES_SECTION) + 2)
          = '[' + DEPENDENCIES_SECTION + ']';
  if not Result then Exit;
  Rest := Trim(Copy(T, Length(DEPENDENCIES_SECTION) + 3, MaxInt));
  Result := (Rest = '') or (Rest[1] = '#');
end;

function IsSectionHeader(const ALine: string): Boolean;
var T: string;
begin
  T := Trim(ALine);
  Result := (T <> '') and (T[1] = '[');
end;

{ Locate the [dependencies] section. AStart is the header's line index;
  AEnd is exclusive (the next section header, or Count). False when the
  manifest has no [dependencies] section. }
function FindDependenciesSection(ALines: TStringList;
  out AStart, AEnd: Integer): Boolean;
var i: Integer;
begin
  AStart := -1;
  AEnd := ALines.Count;
  for i := 0 to ALines.Count - 1 do
    if (AStart < 0) and IsDependenciesHeader(ALines[i]) then
      AStart := i
    else if (AStart >= 0) and IsSectionHeader(ALines[i]) then
    begin
      AEnd := i;
      Break;
    end;
  Result := AStart >= 0;
end;

{ Does this line declare key AName? Handles bare and quoted keys
  (names are validated to the bare-key grammar, but a user may have
  quoted theirs). SameText matching mirrors the lockfile's
  case-insensitive name comparisons. }
function LineDeclaresKey(const ALine, AName: string): Boolean;
var
  T, Key: string;
  Eq: Integer;
begin
  Result := False;
  T := Trim(ALine);
  if (T = '') or (T[1] = '#') or (T[1] = '[') then Exit;
  Eq := Pos('=', T);
  if Eq = 0 then Exit;
  Key := Trim(Copy(T, 1, Eq - 1));
  if (Length(Key) >= 2)
     and (((Key[1] = '"') and (Key[Length(Key)] = '"'))
          or ((Key[1] = '''') and (Key[Length(Key)] = ''''))) then
    Key := Copy(Key, 2, Length(Key) - 2);
  Result := SameText(Key, AName);
end;

{ Everything on the matched line after its value — whitespace plus a
  trailing `# comment` — survives a replacement. Scans past the quoted
  value (basic "..." with backslash escapes, or literal '...') starting
  at the '=' separator; a value that isn't a quoted string yields ''
  (the inline-table case is rejected before this runs). }
function ValueTail(const ALine: string; AEq: Integer): string;
var
  i: Integer;
  Quote: Char;
begin
  Result := '';
  i := AEq + 1;
  while (i <= Length(ALine)) and (ALine[i] in [' ', #9]) do Inc(i);
  if (i > Length(ALine)) or not (ALine[i] in ['"', '''']) then Exit;
  Quote := ALine[i];
  Inc(i);
  while i <= Length(ALine) do
  begin
    if (Quote = '"') and (ALine[i] = '\') then
      Inc(i, 2)             { skip the escaped character }
    else if ALine[i] = Quote then
    begin
      Result := Copy(ALine, i + 1, MaxInt);
      if Trim(Result) = '' then Result := '';
      Exit;
    end
    else
      Inc(i);
  end;
end;

procedure SetDependencyLine(ALines: TStringList;
  const AName, ABareSpec: string; out AReplaced: Boolean);
var
  SecStart, SecEnd, i, InsertAt, Eq: Integer;
  NewLine, ValuePart: string;
begin
  AReplaced := False;
  NewLine := AName + ' = "' + TomlEscape(ABareSpec) + '"';

  if not FindDependenciesSection(ALines, SecStart, SecEnd) then
  begin
    if (ALines.Count > 0) and (Trim(ALines[ALines.Count - 1]) <> '') then
      ALines.Add('');
    ALines.Add('[' + DEPENDENCIES_SECTION + ']');
    ALines.Add(NewLine);
    Exit;
  end;

  for i := SecStart + 1 to SecEnd - 1 do
    if LineDeclaresKey(ALines[i], AName) then
    begin
      { Replacing an inline table with a bare string would silently
        drop its include/exclude globs — refuse, point at the file. }
      Eq := Pos('=', ALines[i]);
      ValuePart := Trim(Copy(ALines[i], Eq + 1, MaxInt));
      if (ValuePart <> '') and (ValuePart[1] = '{') then
        raise EManifestError.CreateFmt(
          'dependency "%s" is declared as an inline table (it may carry '
          + 'include/exclude globs); edit %s manually to change it',
          [AName, MANIFEST_FILE]);
      ALines[i] := NewLine + ValueTail(ALines[i], Eq);
      AReplaced := True;
      Exit;
    end;

  { Append at the end of the section, before any blank-line padding
    that separates it from the next section. }
  InsertAt := SecEnd;
  while (InsertAt - 1 > SecStart)
        and (Trim(ALines[InsertAt - 1]) = '') do
    Dec(InsertAt);
  ALines.Insert(InsertAt, NewLine);
end;

function RemoveDependencyLine(ALines: TStringList;
  const AName: string): Boolean;
var
  SecStart, SecEnd, i: Integer;
begin
  Result := False;
  if not FindDependenciesSection(ALines, SecStart, SecEnd) then Exit;
  for i := SecStart + 1 to SecEnd - 1 do
    if LineDeclaresKey(ALines[i], AName) then
    begin
      ALines.Delete(i);
      Exit(True);
    end;
end;

end.
