{ LWPT.GitIgnore — Git's ignore rules, read from the ignore files themselves.

  Decides whether a path below a project root is ignored the way Git's
  gitignore(5) rules decide it, without running `git` and without a Git
  index, so it works in a project that is not a checkout. It reads:

    - `info/exclude` of the enclosing Git directory, when a `.git`
      directory or `.git` file (a worktree or submodule) is found at or
      above the project root;
    - every `.gitignore` from the enclosing worktree root down to the
      directory that holds the path, each applying to its own subtree.

  Without a `.git` above it, the project root is the top and only the
  `.gitignore` files at and below it count. `core.excludesFile` and other
  per-user configuration are not read, so the answer depends only on the
  project's own files. Matching is case-sensitive (Git's default where
  `core.ignorecase` is false). A tracked file that matches a pattern is
  ignored too, because the index is never read.

  The project root itself, and every directory above it, is never ignored,
  and neither is a path outside the top. Every other path below the top,
  including one in a sibling of the project root such as a unit root
  declared as `../shared`, is judged against every pattern that applies to
  it. A directory that is ignored makes every
  path below it ignored, and the `.gitignore` files inside it are never
  read, so a negated pattern cannot re-include a file whose parent
  directory is excluded.

  Pattern syntax follows gitignore(5) and Git's wildmatch: blank lines and
  `#` comments, unescaped trailing spaces trimmed, `\` escapes, `!`
  negation, a trailing `/` for directories only, a leading or middle `/`
  anchoring the pattern to its file's directory, and `*`, `?`, `[...]`
  (with `!`/`^` negation, ranges and `[:class:]` names) and `**` in
  leading, trailing and middle positions. Decisions are last-match-wins,
  with deeper `.gitignore` files above shallower ones and `info/exclude`
  below them all. }
unit LWPT.GitIgnore;

{$I Shared.inc}
{$J-}

interface

uses
  Classes;

type
  { The pattern that ignores a path. }
  TLWPTIgnoreRule = record
    { The file that holds the pattern, relative to the project root, with
      `/` separators. }
    Source: string;
    { 1-based line of the pattern in Source. }
    Line: Integer;
    { The pattern as written, without unescaped trailing spaces. }
    Pattern: string;
  end;

  TLWPTGitIgnore = class
  private
    FProjectRoot: string;
    FTop: string;
    FProjectRelative: string;
    FExclude: TObject;
    FFiles: TStringList;
    FDirectories: TStringList;
    function DisplayPath(const APath: string): string;
    function FileFor(const ADirectory: string): TObject;
    function MatchOwn(const ARelative: string; const AIsDirectory: Boolean;
      out ARule: TLWPTIgnoreRule): Boolean;
    function DirectoryIgnored(const ARelative: string;
      out ARule: TLWPTIgnoreRule): Boolean;
    function RelativeToTop(const APath: string;
      out ARelative: string): Boolean;
    function IsProjectOrAbove(const ARelative: string): Boolean;
  public
    { Reads the ignore files that apply to AProjectRoot as they are needed.
      Raises ELWPTError when an ignore file exists but cannot be read. }
    constructor Create(const AProjectRoot: string);
    destructor Destroy; override;
    { True when APath (absolute or relative to the current directory) is
      ignored. The project root, its ancestors, and paths outside Top are
      never ignored. }
    function IsIgnored(const APath: string;
      const AIsDirectory: Boolean): Boolean;
    { IsIgnored that also returns the deciding pattern, which may belong to
      an ignored parent directory. }
    function FindRule(const APath: string; const AIsDirectory: Boolean;
      out ARule: TLWPTIgnoreRule): Boolean;
    { The directory whose `.gitignore` is the top of the rules: the
      enclosing Git worktree root, or the project root. }
    property Top: string read FTop;
  end;

{ Git's wildmatch: True when AText matches APattern. With APathname, `*`,
  `?` and `[...]` never match `/`, and only `**` bounded by `/` or the
  ends of the pattern crosses directories. }
function GitWildMatch(const APattern, AText: string;
  const APathname: Boolean = True): Boolean;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,

  LWPT.Core;

const
  WM_MATCH = 0;
  WM_NOMATCH = 1;
  WM_ABORT_ALL = -1;
  WM_ABORT_TO_STARSTAR = -2;
  IGNORE_FILE_NAME = '.gitignore';
  UTF8_BOM = #$EF#$BB#$BF;
  { Git skips a pattern file larger than this (PATTERN_MAX_FILE_SIZE). }
  MAX_IGNORE_FILE_BYTES = 100 * 1024 * 1024;
  GLOB_SPECIAL = ['*', '?', '[', '\'];

type
  TIgnorePattern = record
    Body: string;
    Negative: Boolean;
    MustBeDirectory: Boolean;
    BaseNameOnly: Boolean;
    Rule: TLWPTIgnoreRule;
  end;

  TIgnoreFile = class
  public
    Directory: string;
    Patterns: array of TIgnorePattern;
  end;

  TDirectoryDecision = class
  public
    Ignored: Boolean;
    Rule: TLWPTIgnoreRule;
  end;

function CharAt(const S: string; const AIndex: Integer): Char; inline;
begin
  { NUL ends a C string; Git's matcher sees nothing past it. }
  if (AIndex >= 1) and (AIndex <= Length(S)) then Result := S[AIndex]
  else Result := #0;
end;

{ Git's own ASCII classes (ctype.c), not the C library's: `space` is tab,
  line feed, carriage return and space only. }
function ClassMatches(const AName: string; const C: Char;
  out AKnown: Boolean): Boolean;
var
  IsUpper, IsLower, IsDigit: Boolean;
begin
  AKnown := True;
  IsUpper := C in ['A'..'Z'];
  IsLower := C in ['a'..'z'];
  IsDigit := C in ['0'..'9'];
  if AName = 'alnum' then Result := IsUpper or IsLower or IsDigit
  else if AName = 'alpha' then Result := IsUpper or IsLower
  else if AName = 'blank' then Result := C in [' ', #9]
  else if AName = 'cntrl' then Result := C in [#0..#31, #127]
  else if AName = 'digit' then Result := IsDigit
  else if AName = 'graph' then Result := C in [#33..#126]
  else if AName = 'lower' then Result := IsLower
  else if AName = 'print' then Result := C in [#32..#126]
  else if AName = 'punct' then
    Result := (C in [#33..#126]) and not (IsUpper or IsLower or IsDigit)
  else if AName = 'space' then Result := C in [' ', #9, #10, #13]
  else if AName = 'upper' then Result := IsUpper
  else if AName = 'xdigit' then
    Result := IsDigit or (C in ['a'..'f', 'A'..'F'])
  else
  begin
    AKnown := False;
    Result := False;
  end;
end;

{ A port of the matching rules of Git's wildmatch.c (WM_PATHNAME without
  WM_CASEFOLD), including its abort codes, which keep a failed `*` from
  retrying positions that cannot match. }
function DoWild(const P: string; APos: Integer; const T: string;
  ATextPos: Integer; const APathname: Boolean): Integer;
var
  PC, TC, PrevC: Char;
  MatchSlash, Negated, Matched, Known: Boolean;
  Before, ClassStart, ClassLength, Outcome, Slash, Start: Integer;
begin
  { Like wildmatch.c, each call treats its own first character as the
    start of the pattern when it judges whether `**` opens a component. }
  Start := APos;
  while CharAt(P, APos) <> #0 do
  begin
    PC := P[APos];
    TC := CharAt(T, ATextPos);
    if (TC = #0) and (PC <> '*') then Exit(WM_ABORT_ALL);
    case PC of
      '\':
        begin
          Inc(APos);
          if TC <> CharAt(P, APos) then Exit(WM_NOMATCH);
        end;
      '?':
        if APathname and (TC = '/') then Exit(WM_NOMATCH);
      '*':
        begin
          Inc(APos);
          if CharAt(P, APos) = '*' then
          begin
            Before := APos - 2;
            while CharAt(P, APos) = '*' do Inc(APos);
            if not APathname then
              MatchSlash := True
            else if ((Before < Start) or (P[Before] = '/'))
               and ((CharAt(P, APos) = #0) or (CharAt(P, APos) = '/')
                 or ((CharAt(P, APos) = '\')
                   and (CharAt(P, APos + 1) = '/'))) then
            begin
              { `**/` may match no directory at all. }
              if (CharAt(P, APos) = '/')
                 and (DoWild(P, APos + 1, T, ATextPos, APathname)
                   = WM_MATCH) then
                Exit(WM_MATCH);
              MatchSlash := True;
            end
            else
              MatchSlash := not APathname;
          end
          else
            MatchSlash := not APathname;

          if CharAt(P, APos) = #0 then
          begin
            { A trailing `**` matches everything; a trailing `*` only what
              holds no further `/`. }
            if not MatchSlash
               and (Pos('/', Copy(T, ATextPos, MaxInt)) > 0) then
              Exit(WM_ABORT_TO_STARSTAR);
            Exit(WM_MATCH);
          end;
          if not MatchSlash and (P[APos] = '/') then
          begin
            { One `*` before a `/` matches the rest of this directory. }
            Slash := Pos('/', Copy(T, ATextPos, MaxInt));
            if Slash = 0 then Exit(WM_ABORT_ALL);
            ATextPos := ATextPos + Slash - 1;
            Inc(APos);
            Inc(ATextPos);
            Continue;
          end;
          while True do
          begin
            TC := CharAt(T, ATextPos);
            if TC = #0 then Break;
            { A literal after the star must appear in the text: skip to it,
              never past a `/` the star cannot cross. }
            if not (P[APos] in GLOB_SPECIAL) then
            begin
              while (TC <> #0) and (MatchSlash or (TC <> '/'))
                and (TC <> P[APos]) do
              begin
                Inc(ATextPos);
                TC := CharAt(T, ATextPos);
              end;
              if TC <> P[APos] then
              begin
                if MatchSlash then Exit(WM_ABORT_ALL);
                Exit(WM_ABORT_TO_STARSTAR);
              end;
            end;
            Outcome := DoWild(P, APos, T, ATextPos, APathname);
            if Outcome <> WM_NOMATCH then
            begin
              if not MatchSlash or (Outcome <> WM_ABORT_TO_STARSTAR) then
                Exit(Outcome);
            end
            else if not MatchSlash and (TC = '/') then
              Exit(WM_ABORT_TO_STARSTAR);
            Inc(ATextPos);
          end;
          Exit(WM_ABORT_ALL);
        end;
      '[':
        begin
          Inc(APos);
          PC := CharAt(P, APos);
          if PC = '^' then PC := '!';
          Negated := PC = '!';
          if Negated then
          begin
            Inc(APos);
            PC := CharAt(P, APos);
          end;
          PrevC := #0;
          Matched := False;
          repeat
            if PC = #0 then Exit(WM_ABORT_ALL);
            if PC = '\' then
            begin
              Inc(APos);
              PC := CharAt(P, APos);
              if PC = #0 then Exit(WM_ABORT_ALL);
              if TC = PC then Matched := True;
            end
            else if (PC = '-') and (PrevC <> #0)
              and (CharAt(P, APos + 1) <> #0)
              and (CharAt(P, APos + 1) <> ']') then
            begin
              Inc(APos);
              PC := P[APos];
              if PC = '\' then
              begin
                Inc(APos);
                PC := CharAt(P, APos);
                if PC = #0 then Exit(WM_ABORT_ALL);
              end;
              if (TC <= PC) and (TC >= PrevC) then Matched := True;
              PC := #0;
            end
            else if (PC = '[') and (CharAt(P, APos + 1) = ':') then
            begin
              Inc(APos, 2);
              ClassStart := APos;
              while (CharAt(P, APos) <> #0) and (P[APos] <> ']') do Inc(APos);
              if CharAt(P, APos) = #0 then Exit(WM_ABORT_ALL);
              ClassLength := APos - ClassStart - 1;
              if (ClassLength < 0) or (P[APos - 1] <> ':') then
              begin
                { No `:]`: the `[` is an ordinary member of the set. }
                APos := ClassStart - 2;
                PC := '[';
                if TC = PC then Matched := True;
              end
              else
              begin
                if ClassMatches(Copy(P, ClassStart, ClassLength), TC,
                  Known) then
                  Matched := True;
                if not Known then Exit(WM_ABORT_ALL);
                PC := #0;
              end;
            end
            else if TC = PC then
              Matched := True;
            PrevC := PC;
            Inc(APos);
            PC := CharAt(P, APos);
          until PC = ']';
          if (Matched = Negated) or (APathname and (TC = '/')) then
            Exit(WM_NOMATCH);
        end;
    else
      if TC <> PC then Exit(WM_NOMATCH);
    end;
    Inc(APos);
    Inc(ATextPos);
  end;
  if CharAt(T, ATextPos) <> #0 then Result := WM_NOMATCH
  else Result := WM_MATCH;
end;

function GitWildMatch(const APattern, AText: string;
  const APathname: Boolean): Boolean;
begin
  Result := DoWild(APattern, 1, AText, 1, APathname) = WM_MATCH;
end;

{ Git's trim_trailing_spaces: drop unescaped trailing spaces only. }
function TrimTrailingSpaces(const ALine: string): string;
var
  I, LastSpace: Integer;
begin
  Result := ALine;
  LastSpace := 0;
  I := 1;
  while I <= Length(Result) do
  begin
    case Result[I] of
      ' ':
        if LastSpace = 0 then LastSpace := I;
      '\':
        begin
          Inc(I);
          if I > Length(Result) then Exit;
          LastSpace := 0;
        end;
    else
      LastSpace := 0;
    end;
    Inc(I);
  end;
  if LastSpace > 0 then SetLength(Result, LastSpace - 1);
end;

procedure ParseIgnoreText(const AText, ASource: string;
  const AFile: TIgnoreFile);
var
  Lines: TStringArray;
  Body, Line, Text: string;
  I, Count: Integer;
  Pattern: TIgnorePattern;
begin
  Text := AText;
  if Copy(Text, 1, Length(UTF8_BOM)) = UTF8_BOM then
    Delete(Text, 1, Length(UTF8_BOM));
  Lines := Text.Split([#10]);
  Count := Length(Lines);
  { A final newline ends the last line rather than starting another. }
  if (Count > 0) and (Text <> '') and (Text[Length(Text)] = #10) then
    Dec(Count);
  for I := 0 to Count - 1 do
  begin
    Line := Lines[I];
    if (Line = '') or (Line[1] = '#') then Continue;
    if Line[Length(Line)] = #13 then SetLength(Line, Length(Line) - 1);
    { Git handles each pattern as a C string, which ends at a NUL byte. }
    if Pos(#0, Line) > 0 then SetLength(Line, Pos(#0, Line) - 1);
    Line := TrimTrailingSpaces(Line);
    if Line = '' then Continue;

    Pattern := Default(TIgnorePattern);
    Pattern.Rule.Source := ASource;
    Pattern.Rule.Line := I + 1;
    Pattern.Rule.Pattern := Line;
    Body := Line;
    if Body[1] = '!' then
    begin
      Pattern.Negative := True;
      Delete(Body, 1, 1);
    end;
    if (Body <> '') and (Body[Length(Body)] = '/') then
    begin
      Pattern.MustBeDirectory := True;
      SetLength(Body, Length(Body) - 1);
    end;
    Pattern.BaseNameOnly := Pos('/', Body) = 0;
    if not Pattern.BaseNameOnly and (Body[1] = '/') then Delete(Body, 1, 1);
    Pattern.Body := Body;
    SetLength(AFile.Patterns, Length(AFile.Patterns) + 1);
    AFile.Patterns[High(AFile.Patterns)] := Pattern;
  end;
end;

{ Reads APath when it is a regular file. False when it is missing, is not
  a regular file (an in-tree `.gitignore` that is a symlink is skipped, as
  Git skips it, unless AFollowLinks), or is larger than Git reads. Raises
  when a regular file cannot be read, so an unreadable ignore file never
  silently stops applying. }
function ReadIgnoreFile(const APath: string; const AFollowLinks: Boolean;
  out AText: string): Boolean;
{$IFDEF UNIX}
var
  Info: Stat;
  Descriptor, Count, Previous, StatResult, Error: LongInt;
  Buffer: array[0..8191] of Byte;
begin
  AText := '';
  if AFollowLinks then StatResult := FpStat(APath, Info)
  else StatResult := FpLstat(APath, Info);
  if StatResult <> 0 then
  begin
    { Only a missing file means no rules; a file that cannot be inspected
      fails like one that cannot be read. }
    Error := FpGetErrNo;
    if (Error = ESysENOENT) or (Error = ESysENOTDIR) then Exit(False);
    raise ELWPTError.CreateFmt('cannot read ignore file "%s": %s',
      [APath, SysErrorMessage(Error)]);
  end;
  if not FpS_ISREG(Info.st_mode) then Exit(False);
  { Non-blocking, so a file swapped for a FIFO after the check fails the
    regular-file test below instead of blocking the open. }
  Descriptor := OpenProtectedDescriptor(APath, O_RDONLY or O_NONBLOCK, 0);
  if Descriptor < 0 then
    raise ELWPTError.CreateFmt('cannot read ignore file "%s": %s',
      [APath, SysErrorMessage(FpGetErrNo)]);
  try
    if (FpFStat(Descriptor, Info) <> 0) or not FpS_ISREG(Info.st_mode) then
      raise ELWPTError.CreateFmt(
        'cannot read ignore file "%s": not a regular file', [APath]);
    if Info.st_size > MAX_IGNORE_FILE_BYTES then Exit(False);
    repeat
      Count := FpRead(Descriptor, Buffer, SizeOf(Buffer));
      if Count < 0 then
      begin
        if FpGetErrNo = ESysEINTR then Continue;
        raise ELWPTError.CreateFmt('cannot read ignore file "%s": %s',
          [APath, SysErrorMessage(FpGetErrNo)]);
      end;
      if Count > 0 then
      begin
        Previous := Length(AText);
        SetLength(AText, Previous + Count);
        Move(Buffer[0], AText[Previous + 1], Count);
      end;
    until Count = 0;
  finally
    FpClose(Descriptor);
  end;
  Result := True;
end;
{$ELSE}
const
  IO_REPARSE_TAG_SYMLINK = DWORD($A000000C);
  FILE_ATTRIBUTE_REPARSE_POINT = $400;
var
  Stream: TLWPTProtectedFileStream;
  Data: TWin32FindDataW;
  Handle: THandle;
  Error: DWORD;
begin
  AText := '';
  { FindFirstFileW reports a reparse point's tag, which Git for Windows'
    lstat uses to tell a symlink from a regular file. }
  Handle := Windows.FindFirstFileW(PWideChar(WindowsExtendedPath(APath)),
    Data);
  if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    Error := Windows.GetLastError;
    if (Error = Windows.ERROR_FILE_NOT_FOUND)
       or (Error = Windows.ERROR_PATH_NOT_FOUND) then
      Exit(False);
    raise ELWPTError.CreateFmt('cannot read ignore file "%s": %s',
      [APath, SysErrorMessage(Error)]);
  end;
  Windows.FindClose(Handle);
  if (Data.dwFileAttributes and Windows.FILE_ATTRIBUTE_DIRECTORY) <> 0 then
    Exit(False);
  if not AFollowLinks
     and ((Data.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0)
     and (Data.dwReserved0 = IO_REPARSE_TAG_SYMLINK) then
    Exit(False);
  try
    Stream := OpenProtectedFileStream(APath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size > MAX_IGNORE_FILE_BYTES then Exit(False);
      SetLength(AText, Stream.Size);
      if AText <> '' then Stream.ReadBuffer(AText[1], Length(AText));
    finally
      Stream.Free;
    end;
  except
    on E: ELWPTError do raise;
    on E: Exception do
      raise ELWPTError.CreateFmt('cannot read ignore file "%s": %s',
        [APath, E.Message]);
  end;
  Result := True;
end;
{$ENDIF}

function NativePath(const ARelative: string): string;
begin
  Result := StringReplace(ARelative, '/', PathDelim, [rfReplaceAll]);
end;

function ParentOf(const ARelative: string): string;
var
  I: Integer;
begin
  I := Length(ARelative);
  while (I > 0) and (ARelative[I] <> '/') do Dec(I);
  if I = 0 then Result := '' else Result := Copy(ARelative, 1, I - 1);
end;

function BaseNameOf(const ARelative: string): string;
begin
  Result := Copy(ARelative, Length(ParentOf(ARelative)) + 1, MaxInt);
  if (Result <> '') and (Result[1] = '/') then Delete(Result, 1, 1);
end;

function FirstLine(const AText: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(AText)) and not (AText[I] in [#10, #13]) do Inc(I);
  Result := Copy(AText, 1, I - 1);
end;

function IsAbsolute(const APath: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := (Length(APath) >= 2) and ((APath[2] = ':')
    or ((APath[1] in ['\', '/']) and (APath[2] in ['\', '/'])));
  {$ELSE}
  Result := (APath <> '') and (APath[1] = '/');
  {$ENDIF}
end;

function ResolveFrom(const ADirectory, APath: string): string;
begin
  if IsAbsolute(APath) then Result := ExpandFileName(APath)
  else Result := ExpandFileName(IncludeTrailingPathDelimiter(ADirectory)
    + APath);
end;

{ Git's `$GIT_COMMON_DIR/info/exclude` for the worktree rooted at ATop:
  `.git` is the Git directory or a file naming it (`gitdir: <path>`), and a
  linked worktree's Git directory names the shared one in `commondir`. }
function InfoExcludePath(const ATop: string): string;
var
  GitDir, GitPath, Text: string;
begin
  Result := '';
  GitPath := IncludeTrailingPathDelimiter(ATop) + '.git';
  if DirectoryExists(GitPath) then GitDir := GitPath
  else
  begin
    if not ReadIgnoreFile(GitPath, True, Text) then Exit;
    Text := FirstLine(Text);
    if Copy(Text, 1, 8) <> 'gitdir: ' then Exit;
    GitDir := ResolveFrom(ATop, Trim(Copy(Text, 9, MaxInt)));
  end;
  if ReadIgnoreFile(IncludeTrailingPathDelimiter(GitDir) + 'commondir', True,
    Text) and (Trim(FirstLine(Text)) <> '') then
    GitDir := ResolveFrom(GitDir, Trim(FirstLine(Text)));
  Result := IncludeTrailingPathDelimiter(GitDir) + 'info' + PathDelim
    + 'exclude';
end;

function FindWorktreeTop(const AProjectRoot: string): string;
var
  Candidate, Parent: string;
begin
  Candidate := AProjectRoot;
  while True do
  begin
    if DirectoryExists(IncludeTrailingPathDelimiter(Candidate) + '.git')
       or FileExists(IncludeTrailingPathDelimiter(Candidate) + '.git') then
      Exit(Candidate);
    Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(Candidate));
    if (Parent = '') or (Parent = Candidate)
       or (Length(Parent) >= Length(Candidate)) then
      Exit(AProjectRoot);
    Candidate := Parent;
  end;
end;

function PatternMatches(const APattern: TIgnorePattern;
  const ADirectory, ARelative: string; const AIsDirectory: Boolean): Boolean;
var
  Name: string;
begin
  Result := False;
  if APattern.MustBeDirectory and not AIsDirectory then Exit;
  if APattern.BaseNameOnly then
  begin
    Result := GitWildMatch(APattern.Body, BaseNameOf(ARelative), False);
    Exit;
  end;

  { A file's patterns are only consulted for paths inside its directory,
    and a pattern with a `/` matches the path relative to that directory.
    Git's literal-prefix shortcut keeps the prefix's last character for
    wildmatch, so it decides exactly what the whole match decides. }
  if ADirectory = '' then Name := ARelative
  else Name := Copy(ARelative, Length(ADirectory) + 2, MaxInt);
  Result := GitWildMatch(APattern.Body, Name, True);
end;

{ TLWPTGitIgnore }

constructor TLWPTGitIgnore.Create(const AProjectRoot: string);
var
  ExcludePath, Text: string;
begin
  inherited Create;
  FProjectRoot := ExcludeTrailingPathDelimiter(ExpandFileName(AProjectRoot));
  FTop := FindWorktreeTop(FProjectRoot);
  FProjectRelative := StringReplace(Copy(FProjectRoot, Length(FTop) + 2,
    MaxInt), PathDelim, '/', [rfReplaceAll]);
  FFiles := TStringList.Create;
  FFiles.Sorted := True;
  FFiles.CaseSensitive := True;
  FFiles.OwnsObjects := True;
  FDirectories := TStringList.Create;
  FDirectories.Sorted := True;
  FDirectories.CaseSensitive := True;
  FDirectories.OwnsObjects := True;
  FExclude := TIgnoreFile.Create;
  ExcludePath := InfoExcludePath(FTop);
  if (ExcludePath <> '') and ReadIgnoreFile(ExcludePath, True, Text) then
    ParseIgnoreText(Text, DisplayPath(ExcludePath), TIgnoreFile(FExclude));
end;

destructor TLWPTGitIgnore.Destroy;
begin
  FExclude.Free;
  FFiles.Free;
  FDirectories.Free;
  inherited Destroy;
end;

function TLWPTGitIgnore.DisplayPath(const APath: string): string;
begin
  Result := StringReplace(ExtractRelativePath(
    IncludeTrailingPathDelimiter(FProjectRoot), APath), PathDelim, '/',
    [rfReplaceAll]);
end;

function TLWPTGitIgnore.FileFor(const ADirectory: string): TObject;
var
  Index: Integer;
  IgnoreFile: TIgnoreFile;
  Path, Text: string;
begin
  if FFiles.Find(ADirectory, Index) then Exit(FFiles.Objects[Index]);
  IgnoreFile := TIgnoreFile.Create;
  try
    IgnoreFile.Directory := ADirectory;
    Path := IncludeTrailingPathDelimiter(FTop);
    if ADirectory <> '' then
      Path := Path + NativePath(ADirectory) + PathDelim;
    Path := Path + IGNORE_FILE_NAME;
    if ReadIgnoreFile(Path, False, Text) then
      ParseIgnoreText(Text, DisplayPath(Path), IgnoreFile);
  except
    IgnoreFile.Free;
    raise;
  end;
  FFiles.AddObject(ADirectory, IgnoreFile);
  Result := IgnoreFile;
end;

function TLWPTGitIgnore.MatchOwn(const ARelative: string;
  const AIsDirectory: Boolean; out ARule: TLWPTIgnoreRule): Boolean;
var
  Directories: TStringArray;
  Directory: string;
  IgnoreFile: TIgnoreFile;
  Level, I: Integer;
begin
  ARule := Default(TLWPTIgnoreRule);
  { The directories whose `.gitignore` applies, deepest first. }
  SetLength(Directories, 0);
  Directory := ParentOf(ARelative);
  while True do
  begin
    SetLength(Directories, Length(Directories) + 1);
    Directories[High(Directories)] := Directory;
    if Directory = '' then Break;
    Directory := ParentOf(Directory);
  end;
  { Deeper files win over shallower ones, and info/exclude loses to all;
    inside a file the last matching pattern wins. }
  for Level := 0 to Length(Directories) do
  begin
    if Level < Length(Directories) then
      IgnoreFile := TIgnoreFile(FileFor(Directories[Level]))
    else
      IgnoreFile := TIgnoreFile(FExclude);
    for I := High(IgnoreFile.Patterns) downto 0 do
      if PatternMatches(IgnoreFile.Patterns[I], IgnoreFile.Directory,
        ARelative, AIsDirectory) then
      begin
        if IgnoreFile.Patterns[I].Negative then Exit(False);
        ARule := IgnoreFile.Patterns[I].Rule;
        Exit(True);
      end;
  end;
  Result := False;
end;

function TLWPTGitIgnore.DirectoryIgnored(const ARelative: string;
  out ARule: TLWPTIgnoreRule): Boolean;
var
  Index: Integer;
  Decision: TDirectoryDecision;
begin
  if not FDirectories.Find(ARelative, Index) then
  begin
    Decision := TDirectoryDecision.Create;
    try
      Decision.Ignored := MatchOwn(ARelative, True, Decision.Rule);
    except
      Decision.Free;
      raise;
    end;
    Index := FDirectories.AddObject(ARelative, Decision);
  end;
  Decision := TDirectoryDecision(FDirectories.Objects[Index]);
  ARule := Decision.Rule;
  Result := Decision.Ignored;
end;

function TLWPTGitIgnore.RelativeToTop(const APath: string;
  out ARelative: string): Boolean;
var
  Full: string;
begin
  ARelative := '';
  Full := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
  if (Length(Full) <= Length(FTop)) or not PathContains(FTop, Full) then
    Exit(False);
  ARelative := StringReplace(Copy(Full, Length(FTop) + 2, MaxInt),
    PathDelim, '/', [rfReplaceAll]);
  Result := ARelative <> '';
end;

function TLWPTGitIgnore.IsProjectOrAbove(const ARelative: string): Boolean;
begin
  Result := (ARelative = FProjectRelative)
    or (Copy(FProjectRelative, 1, Length(ARelative) + 1) = ARelative + '/');
end;

function TLWPTGitIgnore.IsIgnored(const APath: string;
  const AIsDirectory: Boolean): Boolean;
var
  Rule: TLWPTIgnoreRule;
begin
  Result := FindRule(APath, AIsDirectory, Rule);
end;

function TLWPTGitIgnore.FindRule(const APath: string;
  const AIsDirectory: Boolean; out ARule: TLWPTIgnoreRule): Boolean;
var
  Relative: string;
  I: Integer;
begin
  ARule := Default(TLWPTIgnoreRule);
  if not RelativeToTop(APath, Relative) or IsProjectOrAbove(Relative) then
    Exit(False);
  { Judge each directory above the path first, except the project root and
    its ancestors: an ignored one decides for everything below it. }
  for I := 1 to Length(Relative) do
    if (Relative[I] = '/')
       and not IsProjectOrAbove(Copy(Relative, 1, I - 1))
       and DirectoryIgnored(Copy(Relative, 1, I - 1), ARule) then
      Exit(True);
  Result := MatchOwn(Relative, AIsDirectory, ARule);
end;

end.
