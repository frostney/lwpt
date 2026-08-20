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
function  SetDependencyVersionConstraint(ALines: TStringList;
  const AName, ANewConstraint: string): Boolean;
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

{ The [dependencies] header in any TOML-equivalent spelling the parser
  accepts: whitespace inside the brackets ("[ dependencies ]") and a
  quoted key ('["dependencies"]'), plus trailing whitespace + comment.
  Missing an equivalent form would make SetDependencyLine append a
  SECOND [dependencies] table — a duplicate definition the next parse
  hard-errors on. A commented-out header (init's "# [dependencies]"
  scaffold hint) is not a header — Trim leaves the '#' in front. A
  dotted header ([dependencies.x]) is not this section. }
function IsDependenciesHeader(const ALine: string): Boolean;
var
  T, Inner, Rest: string;
  CloseIdx: Integer;
begin
  Result := False;
  T := Trim(ALine);
  if (T = '') or (T[1] <> '[') then Exit;
  CloseIdx := Pos(']', T);
  if CloseIdx = 0 then Exit;
  Inner := Trim(Copy(T, 2, CloseIdx - 2));
  if (Length(Inner) >= 2)
     and (((Inner[1] = '"') and (Inner[Length(Inner)] = '"'))
          or ((Inner[1] = '''') and (Inner[Length(Inner)] = ''''))) then
    Inner := Copy(Inner, 2, Length(Inner) - 2);
  if Inner <> DEPENDENCIES_SECTION then Exit;
  Rest := Trim(Copy(T, CloseIdx + 1, MaxInt));
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

{ Rewrite only the version half of a [dependencies] entry so include /
  exclude globs on an inline table survive `lwpt update`. Bare
  `name = "source@spec"` lines get a new @spec; single-line inline
  tables get their version = "..." value replaced (or inserted).
  Returns False when the name has no editable line. }
function UnquoteTomlKey(const AKey: string): string;
begin
  Result := AKey;
  if (Length(Result) >= 2)
     and (((Result[1] = '"') and (Result[Length(Result)] = '"'))
          or ((Result[1] = #39) and (Result[Length(Result)] = #39))) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function ReplaceQuotedValueAt(const ALine: string; AQuoteStart: Integer;
  const ANewValue: string): string;
var
  i: Integer;
  Quote: Char;
begin
  Quote := ALine[AQuoteStart];
  i := AQuoteStart + 1;
  while i <= Length(ALine) do
  begin
    if (Quote = '"') and (ALine[i] = '\') then
      Inc(i, 2)
    else if ALine[i] = Quote then
    begin
      Result := Copy(ALine, 1, AQuoteStart) + TomlEscape(ANewValue)
        + Copy(ALine, i, MaxInt);
      Exit;
    end
    else
      Inc(i);
  end;
  Result := ALine;
end;

function ReplaceBareSpecVersion(const ALine, ANewConstraint: string;
  out ANewLine: string): Boolean;
var
  Eq, i, LastAt, QuoteStart: Integer;
  Quote: Char;
  Value: string;
begin
  Result := False;
  ANewLine := ALine;
  Eq := Pos('=', ALine);
  if Eq = 0 then Exit;
  i := Eq + 1;
  while (i <= Length(ALine)) and (ALine[i] in [' ', #9]) do Inc(i);
  if (i > Length(ALine)) or not (ALine[i] in ['"', #39]) then Exit;
  QuoteStart := i;
  Quote := ALine[i];
  if (i + 2 <= Length(ALine))
     and (ALine[i + 1] = Quote)
     and (ALine[i + 2] = Quote) then
    Exit;
  Inc(i);
  LastAt := 0;
  while i <= Length(ALine) do
  begin
    if (Quote = '"') and (ALine[i] = '\') then
      Inc(i, 2)
    else if ALine[i] = Quote then
      Break
    else
    begin
      if ALine[i] = '@' then LastAt := i;
      Inc(i);
    end;
  end;
  if i > Length(ALine) then Exit;
  if LastAt > QuoteStart then
    ANewLine := Copy(ALine, 1, LastAt) + TomlEscape(ANewConstraint)
      + Copy(ALine, i, MaxInt)
  else
  begin
    Value := Copy(ALine, QuoteStart + 1, i - QuoteStart - 1);
    ANewLine := ReplaceQuotedValueAt(ALine, QuoteStart,
      Value + '@' + ANewConstraint);
  end;
  Result := True;
end;

procedure SkipInlineTableValue(const ALine: string; var i: Integer;
  ALimit: Integer);
var
  Depth: Integer;
  Quote: Char;
begin
  if i >= ALimit then Exit;
  if ALine[i] in ['"', #39] then
  begin
    Quote := ALine[i];
    Inc(i);
    while i < ALimit do
    begin
      if (Quote = '"') and (ALine[i] = '\') then
        Inc(i, 2)
      else if ALine[i] = Quote then
      begin
        Inc(i);
        Exit;
      end
      else
        Inc(i);
    end;
    Exit;
  end;
  if ALine[i] = '[' then
  begin
    Depth := 1;
    Inc(i);
    while (i < ALimit) and (Depth > 0) do
    begin
      if ALine[i] in ['"', #39] then
      begin
        Quote := ALine[i];
        Inc(i);
        while i < ALimit do
        begin
          if (Quote = '"') and (ALine[i] = '\') then
            Inc(i, 2)
          else if ALine[i] = Quote then
          begin
            Inc(i);
            Break;
          end
          else
            Inc(i);
        end;
      end
      else
      begin
        if ALine[i] = '[' then Inc(Depth)
        else if ALine[i] = ']' then Dec(Depth);
        Inc(i);
      end;
    end;
    Exit;
  end;
  while (i < ALimit) and (ALine[i] <> ',') do Inc(i);
end;

function FindInlineTableClose(const ALine: string; AOpen: Integer): Integer;
var
  i: Integer;
  Quote: Char;
begin
  Result := 0;
  i := AOpen + 1;
  while i <= Length(ALine) do
  begin
    if ALine[i] = '#' then
      Exit;
    if ALine[i] in ['"', #39] then
    begin
      Quote := ALine[i];
      Inc(i);
      while i <= Length(ALine) do
      begin
        if (Quote = '"') and (ALine[i] = '\') then
          Inc(i, 2)
        else if ALine[i] = Quote then
        begin
          Inc(i);
          Break;
        end
        else
          Inc(i);
      end;
    end
    else if ALine[i] = '}' then
    begin
      Result := i;
      Exit;
    end
    else
      Inc(i);
  end;
end;

function ReplaceInlineTableVersion(const ALine, ANewConstraint: string;
  out ANewLine: string): Boolean;
var
  Brace, CloseBrace, i, KeyStart, KeyEnd: Integer;
  Key: string;
begin
  Result := False;
  ANewLine := ALine;
  Brace := Pos('{', ALine);
  if Brace = 0 then Exit;
  CloseBrace := FindInlineTableClose(ALine, Brace);
  if CloseBrace = 0 then Exit;

  i := Brace + 1;
  while i < CloseBrace do
  begin
    while (i < CloseBrace) and (ALine[i] in [' ', #9, ',']) do Inc(i);
    if i >= CloseBrace then Break;
    KeyStart := i;
    while (i < CloseBrace) and not (ALine[i] in ['=', ' ', #9]) do Inc(i);
    KeyEnd := i;
    Key := UnquoteTomlKey(Trim(Copy(ALine, KeyStart, KeyEnd - KeyStart)));
    while (i < CloseBrace) and (ALine[i] in [' ', #9]) do Inc(i);
    if (i >= CloseBrace) or (ALine[i] <> '=') then
    begin
      while (i < CloseBrace) and (ALine[i] <> ',') do Inc(i);
      Continue;
    end;
    Inc(i);
    while (i < CloseBrace) and (ALine[i] in [' ', #9]) do Inc(i);
    if SameText(Key, 'version') and (i < CloseBrace)
       and (ALine[i] in ['"', #39]) then
    begin
      ANewLine := ReplaceQuotedValueAt(ALine, i, ANewConstraint);
      Exit(True);
    end;
    SkipInlineTableValue(ALine, i, CloseBrace);
  end;

  ANewLine := TrimRight(Copy(ALine, 1, CloseBrace - 1));
  if (ANewLine <> '') and (ANewLine[Length(ANewLine)] <> '{') then
    ANewLine := ANewLine + ',';
  ANewLine := ANewLine + ' version = "' + TomlEscape(ANewConstraint) + '" '
    + Copy(ALine, CloseBrace, MaxInt);
  Result := True;
end;

function SetDependencyVersionConstraint(ALines: TStringList;
  const AName, ANewConstraint: string): Boolean;
var
  SecStart, SecEnd, i, Eq: Integer;
  ValuePart, NewLine: string;
begin
  Result := False;
  if not FindDependenciesSection(ALines, SecStart, SecEnd) then Exit;
  for i := SecStart + 1 to SecEnd - 1 do
    if LineDeclaresKey(ALines[i], AName) then
    begin
      Eq := Pos('=', ALines[i]);
      if Eq = 0 then Exit;
      ValuePart := Trim(Copy(ALines[i], Eq + 1, MaxInt));
      if (ValuePart <> '') and (ValuePart[1] = '{') then
      begin
        if not ReplaceInlineTableVersion(ALines[i], ANewConstraint, NewLine) then
          Exit;
      end
      else if not ReplaceBareSpecVersion(ALines[i], ANewConstraint, NewLine) then
        Exit;
      ALines[i] := NewLine;
      Exit(True);
    end;
end;

end.
