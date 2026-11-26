{ LWPT.GitIgnore.Test — Git ignore rules read from the ignore files.

  Every rule is pinned by an expected table, so the suite needs no `git`.
  Where `git` is on PATH, each cross-checked table is also put to
  `git check-ignore --no-index` in a real repository, with the user's
  global excludes and case folding switched off, and git must agree. }
program LWPT.GitIgnore.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.Core,
  LWPT.GitIgnore,
  TestingPascalLibrary,
  Tests.ProcessSupport,
  Tests.Scratch;

type
  { Path is relative to the project root with `/` separators; a trailing
    `/` makes it a directory. }
  TIgnoreCase = record
    Path: string;
    Ignored: Boolean;
  end;

  TWildCase = record
    Pattern: string;
    Text: string;
    Matches: Boolean;
  end;

  TGitIgnoreTests = class(TTestSuite)
  private
    FRoot, FGit: string;
    function NewWorktree(const AName: string): string;
    function RunGit(const ADirectory: string;
      const AArguments: array of string; out AOutput: string): Integer;
    procedure CheckCases(const ATop, AProjectRoot: string;
      const ACases: array of TIgnoreCase; const ACrossCheck: Boolean);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestWildMatchFollowsGit;
    procedure TestCommentsBlanksEscapesAndTrailingSpaces;
    procedure TestNegationCannotReincludeBelowExcludedDirectory;
    procedure TestTrailingSlashAndAnchoring;
    procedure TestDoubleAsteriskPositions;
    procedure TestBracketExpressions;
    procedure TestNestedFilesAndPrecedence;
    procedure TestLineEndingsAndByteOrderMark;
    procedure TestSymlinkedOrNonRegularIgnoreFilesAreSkipped;
    procedure TestParentFilesApplyButProjectRootIsNeverIgnored;
    procedure TestSiblingUnitRootIsJudged;
    procedure TestWorktreeAndSubmoduleInfoExclude;
    procedure TestRealLinkedWorktreeReadsCommonInfoExclude;
    procedure TestProjectWithoutGitReadsItsOwnFiles;
    procedure TestReportsDecidingRule;
    procedure TestUnreadableIgnoreFileFails;
  end;

function C(const APath: string; const AIgnored: Boolean): TIgnoreCase;
begin
  Result.Path := APath;
  Result.Ignored := AIgnored;
end;

function W(const APattern, AText: string; const AMatches: Boolean): TWildCase;
begin
  Result.Pattern := APattern;
  Result.Text := AText;
  Result.Matches := AMatches;
end;

{$IFDEF MSWINDOWS}
function CreateSymbolicLinkW(ALink, ATarget: PWideChar; AFlags: DWORD): BOOLEAN;
  stdcall; external 'kernel32' name 'CreateSymbolicLinkW';
{$ENDIF}

function NativePath(const APath: string): string;
begin
  Result := StringReplace(APath, '/', PathDelim, [rfReplaceAll]);
end;

{ Writes AContent byte for byte, creating the parent directories. }
procedure WriteRaw(const APath, AContent: string);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AContent <> '' then Stream.WriteBuffer(AContent[1], Length(AContent));
  finally
    Stream.Free;
  end;
end;

function IsDirectoryCase(const ACase: TIgnoreCase): Boolean;
begin
  Result := (ACase.Path <> '') and (ACase.Path[Length(ACase.Path)] = '/');
end;

function CasePath(const ACase: TIgnoreCase): string;
begin
  Result := ACase.Path;
  if IsDirectoryCase(ACase) then SetLength(Result, Length(Result) - 1);
end;

{ The case's path as git takes it: relative to the worktree top, so a case
  outside the project root (`../shared/x`) names its real location. }
function TopRelative(const ATop, AProjectRoot: string;
  const ACase: TIgnoreCase): string;
begin
  Result := StringReplace(ExtractRelativePath(IncludeTrailingPathDelimiter(
    ATop), ExpandFileName(AProjectRoot + PathDelim
    + NativePath(CasePath(ACase)))), PathDelim, '/', [rfReplaceAll]);
end;

function YesNo(const AValue: Boolean): string;
begin
  if AValue then Result := 'ignored' else Result := 'not ignored';
end;

procedure TGitIgnoreTests.BeforeAll;
begin
  FRoot := CreateScratchRoot('gitignore');
  FGit := ExeSearch({$IFDEF MSWINDOWS}'git.exe'{$ELSE}'git'{$ENDIF},
    GetEnvironmentVariable('PATH'));
  if FGit = '' then
    WriteLn('git not found on PATH: checking the expected tables only')
  else
    WriteLn('cross-checking the tables against ', FGit);
end;

function TGitIgnoreTests.RunGit(const ADirectory: string;
  const AArguments: array of string; out AOutput: string): Integer;
var
  Process: TProcess;
  Name, Entry, Unused: string;
  I: Integer;
begin
  { No user or system configuration, hook, template or repository-selection
    variable reaches the repository under test: git reads no system or
    global file, every inherited GIT_* variable is dropped, and case
    folding, the default per-user excludes file and hooks are pinned off. }
  AOutput := '';
  Unused := '';
  Process := TProcess.Create(nil);
  try
    Process.Executable := FGit;
    for I := 1 to GetEnvironmentVariableCount do
    begin
      Entry := GetEnvironmentString(I);
      Name := Copy(Entry, 1, Pos('=', Entry) - 1);
      if (Name <> '') and not SameText(Copy(Name, 1, 4), 'GIT_') then
        Process.Environment.Add(Entry);
    end;
    Process.Environment.Add('GIT_CONFIG_NOSYSTEM=1');
    Process.Environment.Add('GIT_CONFIG_GLOBAL=' + FRoot + PathDelim
      + 'no-such-global-config');
    Process.Parameters.Add('-c');
    Process.Parameters.Add('core.ignorecase=false');
    Process.Parameters.Add('-c');
    Process.Parameters.Add('core.excludesFile=' + FRoot + PathDelim
      + 'no-such-global-excludes');
    Process.Parameters.Add('-c');
    Process.Parameters.Add('core.hooksPath=' + FRoot + PathDelim
      + 'no-such-hooks');
    Process.Parameters.Add('-c');
    Process.Parameters.Add('commit.gpgsign=false');
    for I := 0 to High(AArguments) do Process.Parameters.Add(AArguments[I]);
    Process.CurrentDirectory := ADirectory;
    Process.Options := [poUsePipes, poStderrToOutPut];
    Process.Execute;
    Result := FinishChild(Process, AOutput, Unused,
      CHILD_COMPLETION_TIMEOUT_MILLISECONDS, 'git');
  finally
    Process.Free;
  end;
end;

{ A directory with a `.git` of its own: a real repository when git is
  available, otherwise the bare `.git/info` the matcher reads. }
function TGitIgnoreTests.NewWorktree(const AName: string): string;
var
  Output: string;
begin
  Result := FRoot + PathDelim + AName;
  ForceDirectories(Result);
  if FGit <> '' then
  begin
    if RunGit(Result, ['init', '-q', '--template=', '.'], Output) <> 0 then
      raise Exception.Create('git init failed in ' + Result + ': ' + Output);
  end;
  ForceDirectories(Result + PathDelim + '.git' + PathDelim + 'info');
  { git init writes comment-only defaults; every case starts empty. }
  WriteRaw(Result + PathDelim + '.git' + PathDelim + 'info' + PathDelim
    + 'exclude', '');
end;

procedure TGitIgnoreTests.CheckCases(const ATop, AProjectRoot: string;
  const ACases: array of TIgnoreCase; const ACrossCheck: Boolean);
var
  Matcher: TLWPTGitIgnore;
  Mismatches, Output, Path: string;
  Arguments: array of string;
  GitIgnored: TStringList;
  I, ExitCode: Integer;
  Actual: Boolean;
begin
  for I := 0 to High(ACases) do
  begin
    Path := AProjectRoot + PathDelim + NativePath(CasePath(ACases[I]));
    if IsDirectoryCase(ACases[I]) then ForceDirectories(Path)
    else if not FileExists(Path) then WriteRaw(Path, '');
  end;

  Mismatches := '';
  Matcher := TLWPTGitIgnore.Create(AProjectRoot);
  try
    for I := 0 to High(ACases) do
    begin
      Actual := Matcher.IsIgnored(AProjectRoot + PathDelim
        + NativePath(CasePath(ACases[I])), IsDirectoryCase(ACases[I]));
      if Actual <> ACases[I].Ignored then
        Mismatches := Mismatches + Format('%s: LWPT says %s, expected %s; ',
          [ACases[I].Path, YesNo(Actual), YesNo(ACases[I].Ignored)]);
    end;
  finally
    Matcher.Free;
  end;

  if ACrossCheck and (FGit <> '') then
  begin
    SetLength(Arguments, 3 + Length(ACases));
    Arguments[0] := 'check-ignore';
    Arguments[1] := '--no-index';
    Arguments[2] := '--';
    for I := 0 to High(ACases) do
      Arguments[3 + I] := TopRelative(ATop, AProjectRoot, ACases[I]);
    ExitCode := RunGit(ATop, Arguments, Output);
    if not (ExitCode in [0, 1]) then
      Mismatches := Mismatches + Format('git check-ignore exited %d: %s; ',
        [ExitCode, Output]);
    GitIgnored := TStringList.Create;
    try
      GitIgnored.Text := Output;
      GitIgnored.CaseSensitive := True;
      for I := 0 to High(ACases) do
      begin
        Actual := GitIgnored.IndexOf(TopRelative(ATop, AProjectRoot,
          ACases[I])) >= 0;
        if Actual <> ACases[I].Ignored then
          Mismatches := Mismatches + Format('%s: git says %s, expected %s; ',
            [ACases[I].Path, YesNo(Actual), YesNo(ACases[I].Ignored)]);
      end;
    finally
      GitIgnored.Free;
    end;
  end;
  Expect<string>(Mismatches).ToBe('');
end;

procedure TGitIgnoreTests.TestWildMatchFollowsGit;
const
  { Pathname-mode rows from Git's t3070-wildmatch.sh and gitignore(5). }
  Cases: array[0..47] of TWildCase = (
    (Pattern: 'foo'; Text: 'foo'; Matches: True),
    (Pattern: 'bar'; Text: 'foo'; Matches: False),
    (Pattern: '???'; Text: 'foo'; Matches: True),
    (Pattern: '??'; Text: 'foo'; Matches: False),
    (Pattern: '*'; Text: 'foo'; Matches: True),
    (Pattern: 'f*'; Text: 'foo'; Matches: True),
    (Pattern: '*f'; Text: 'foo'; Matches: False),
    (Pattern: '*foo*'; Text: 'foo'; Matches: True),
    (Pattern: '*ob*a*r*'; Text: 'foobar'; Matches: True),
    (Pattern: '*ab'; Text: 'aaaaaaabababab'; Matches: True),
    (Pattern: 'foo\*'; Text: 'foo*'; Matches: True),
    (Pattern: 'foo\*bar'; Text: 'foobar'; Matches: False),
    (Pattern: 'f\\oo'; Text: 'f\oo'; Matches: True),
    (Pattern: '\[ab]'; Text: '[ab]'; Matches: True),
    (Pattern: 'foo\'; Text: 'foo'; Matches: False),
    (Pattern: '*[al]?'; Text: 'ball'; Matches: True),
    (Pattern: '[ten]'; Text: 'ten'; Matches: False),
    (Pattern: '**[!te]'; Text: 'ten'; Matches: True),
    (Pattern: '**[!ten]'; Text: 'ten'; Matches: False),
    (Pattern: 't[a-g]n'; Text: 'ten'; Matches: True),
    (Pattern: 't[!a-g]n'; Text: 'ten'; Matches: False),
    (Pattern: 't[^a-g]n'; Text: 'ton'; Matches: True),
    (Pattern: 'a[]]b'; Text: 'a]b'; Matches: True),
    (Pattern: 'a[]-]b'; Text: 'a-b'; Matches: True),
    (Pattern: 'a[]a-]b'; Text: 'aab'; Matches: True),
    (Pattern: ']'; Text: ']'; Matches: True),
    (Pattern: '[!]-]'; Text: ']'; Matches: False),
    (Pattern: '[a-]'; Text: '-'; Matches: True),
    (Pattern: '[[:digit:][:upper:][:space:]]'; Text: 'A'; Matches: True),
    (Pattern: '[[:digit:][:upper:][:space:]]'; Text: 'a'; Matches: False),
    (Pattern: '[[:digit:]]'; Text: '1'; Matches: True),
    (Pattern: '[[:foo:]]'; Text: 'f'; Matches: False),
    (Pattern: '[[:xdigit:]]'; Text: 'f'; Matches: True),
    (Pattern: '[[:punct:]]'; Text: ','; Matches: True),
    (Pattern: '['; Text: '['; Matches: False),
    (Pattern: 'foo*bar'; Text: 'foo/baz/bar'; Matches: False),
    (Pattern: 'foo**bar'; Text: 'foo/baz/bar'; Matches: False),
    (Pattern: 'foo/**/bar'; Text: 'foo/bar'; Matches: True),
    (Pattern: 'foo/**/bar'; Text: 'foo/b/a/z/bar'; Matches: True),
    (Pattern: '**/foo'; Text: 'foo'; Matches: True),
    (Pattern: '**/foo'; Text: 'x/y/foo'; Matches: True),
    (Pattern: 'foo/**'; Text: 'foo/a/b'; Matches: True),
    (Pattern: 'foo/**'; Text: 'foo'; Matches: False),
    (Pattern: '*/foo'; Text: 'a/bar/foo'; Matches: False),
    (Pattern: 'foo?bar'; Text: 'foo/bar'; Matches: False),
    (Pattern: 'foo[/]bar'; Text: 'foo/bar'; Matches: False),
    (Pattern: '-*-*-*-*-*-*-12-*-*-*-m-*-*-*';
      Text: '-adobe-courier-bold-o-normal--12-120-75-75-m-70-iso8859-1';
      Matches: True),
    (Pattern: 'XXX/*/*/*/*/*/*/12/*/*/*/m/*/*/*';
      Text: 'XXX/adobe/courier/bold/o/normal//12/120/75/75/X/70/iso8859/1';
      Matches: False));
var
  Mismatches: string;
  I: Integer;
begin
  Mismatches := '';
  for I := Low(Cases) to High(Cases) do
    if GitWildMatch(Cases[I].Pattern, Cases[I].Text) <> Cases[I].Matches then
      Mismatches := Mismatches + Format('"%s" vs "%s"; ',
        [Cases[I].Pattern, Cases[I].Text]);
  { Without pathname mode a single `*` crosses directories. }
  if not GitWildMatch('foo*bar', 'foo/baz/bar', False) then
    Mismatches := Mismatches + 'non-pathname "foo*bar"; ';
  Expect<string>(Mismatches).ToBe('');
end;

procedure TGitIgnoreTests.TestCommentsBlanksEscapesAndTrailingSpaces;
var
  Top: string;
begin
  Top := NewWorktree('syntax');
  WriteRaw(Top + '/.gitignore',
    '# a comment'#10 +
    ''#10 +
    '   '#10 +
    '\#hash'#10 +
    '\!bang'#10 +
    'tsp   '#10 +
    {$IFNDEF MSWINDOWS}
    'sp\ '#10 +
    {$ENDIF}
    'fo?'#10);
  CheckCases(Top, Top, [
    C('# a comment', False),
    C('#hash', True),
    C('!bang', True),
    C('bang', False),
    C('tsp', True),
    {$IFNDEF MSWINDOWS}
    C('sp ', True),
    C('sp', False),
    {$ENDIF}
    C('fox', True),
    C('fo', False),
    C('foxy', False)], True);
end;

procedure TGitIgnoreTests.TestNegationCannotReincludeBelowExcludedDirectory;
var
  Top: string;
begin
  Top := NewWorktree('negation');
  WriteRaw(Top + '/.gitignore',
    '*.log'#10 +
    '!keep.log'#10 +
    'out/'#10 +
    '!out/keep.txt'#10 +
    'gen/*'#10 +
    '!gen/keep.txt'#10);
  CheckCases(Top, Top, [
    C('a.log', True),
    C('keep.log', False),
    C('sub/b.log', True),
    C('sub/keep.log', False),
    C('out/', True),
    C('out/keep.txt', True),
    C('out/deep/', True),
    C('out/deep/x.txt', True),
    C('gen/', False),
    C('gen/keep.txt', False),
    C('gen/other.txt', True)], True);
end;

procedure TGitIgnoreTests.TestTrailingSlashAndAnchoring;
var
  Top: string;
begin
  Top := NewWorktree('anchors');
  WriteRaw(Top + '/.gitignore',
    'onlydir/'#10 +
    '/anch'#10 +
    'mid/dle'#10 +
    'deep/er/'#10);
  CheckCases(Top, Top, [
    C('onlydir', False),
    C('sub/onlydir/', True),
    C('anch', True),
    C('sub/anch', False),
    C('mid/dle', True),
    C('sub/mid/dle', False),
    C('deep/er/', True),
    C('x/deep/er/', False)], True);
end;

procedure TGitIgnoreTests.TestDoubleAsteriskPositions;
var
  Top: string;
begin
  Top := NewWorktree('stars');
  WriteRaw(Top + '/.gitignore',
    '**/lead'#10 +
    'trail/**'#10 +
    'a/**/b'#10 +
    'foo**/bar'#10 +
    '*.o'#10 +
    'x*z/q'#10);
  CheckCases(Top, Top, [
    C('lead', True),
    C('x/y/lead', True),
    C('trail/', False),
    C('trail/q/f', True),
    C('trail/z', True),
    C('a/b', True),
    C('a/x/y/b', True),
    C('a/xb', False),
    C('foo/bar', True),
    C('fooz/bar', True),
    { `**` that does not open a component is an ordinary `*`. }
    C('foo/x/bar', False),
    C('sub/m.o', True),
    C('xyz/q', True),
    C('xy/z/q', False)], True);
end;

procedure TGitIgnoreTests.TestBracketExpressions;
var
  Top: string;
begin
  Top := NewWorktree('brackets');
  WriteRaw(Top + '/.gitignore',
    '[ab]rack'#10 +
    '[!x]neg'#10 +
    '[^y]hat'#10 +
    '[[:digit:]]num'#10 +
    '[a-c]range'#10 +
    'x['#10 +
    '\[lit]'#10);
  CheckCases(Top, Top, [
    C('arack', True),
    C('crack', False),
    C('yneg', True),
    C('xneg', False),
    C('zhat', True),
    C('yhat', False),
    C('7num', True),
    C('anum', False),
    C('brange', True),
    C('drange', False),
    C('x[', False),
    C('[lit]', True),
    C('l', False)], True);
end;

procedure TGitIgnoreTests.TestNestedFilesAndPrecedence;
var
  Top: string;
begin
  Top := NewWorktree('precedence');
  WriteRaw(Top + '/.gitignore',
    '*.tmp'#10 +
    '!wanted.dat'#10 +
    '*.bin'#10);
  WriteRaw(Top + '/sub/.gitignore',
    '!keep.tmp'#10 +
    'local'#10 +
    '/rooted'#10);
  WriteRaw(Top + '/.git/info/exclude',
    '*.dat'#10 +
    '!x.bin'#10);
  CheckCases(Top, Top, [
    C('keep.tmp', True),
    C('sub/keep.tmp', False),
    C('sub/deep/keep.tmp', False),
    C('sub/other.tmp', True),
    C('sub/local', True),
    C('sub/deep/local', True),
    C('local', False),
    C('sub/rooted', True),
    C('sub/deep/rooted', False),
    C('other.dat', True),
    C('wanted.dat', False),
    C('x.bin', True)], True);
end;

procedure TGitIgnoreTests.TestLineEndingsAndByteOrderMark;
var
  Top: string;
begin
  Top := NewWorktree('line-endings');
  WriteRaw(Top + '/.gitignore', #$EF#$BB#$BF'bom'#13#10'cr'#13#10'last');
  CheckCases(Top, Top, [
    C('bom', True),
    C('cr', True),
    C('last', True),
    C('other', False)], True);
end;

procedure TGitIgnoreTests.TestSymlinkedOrNonRegularIgnoreFilesAreSkipped;
var
  Top: string;
begin
  { Git refuses to follow an in-tree `.gitignore` symlink and cannot read
    a directory; neither contributes patterns. }
  Top := NewWorktree('non-regular');
  ForceDirectories(Top + '/dir/.gitignore');
  WriteRaw(Top + '/rules', 'linked'#10);
  {$IFDEF UNIX}
  Expect<Integer>(FpSymlink('rules', PChar(Top + '/.gitignore'))).ToBe(0);
  CheckCases(Top, Top, [
    C('linked', False),
    C('dir/x', False)], True);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  CheckCases(Top, Top, [C('dir/x', False)], True);
  { 2 = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE. Git for Windows'
    lstat reports the link as one, so it is not cross-checked here. }
  if CreateSymbolicLinkW(PWideChar(UnicodeString(NativePath(Top
       + '/.gitignore'))), PWideChar(UnicodeString('rules')), 2)
     and FileExists(Top + '/.gitignore') then
    CheckCases(Top, Top, [C('linked', False)], False)
  else
    WriteLn('file symbolic links unavailable: the Windows link case '
      + 'needs developer mode or the privilege');
  {$ENDIF}
end;

procedure TGitIgnoreTests.TestSiblingUnitRootIsJudged;
var
  Top, Project: string;
  Matcher: TLWPTGitIgnore;
begin
  { A unit root declared as `../shared` sits beside the project root in the
    same worktree; its paths are judged like any other. }
  Top := NewWorktree('sibling');
  Project := Top + PathDelim + 'app';
  WriteRaw(Top + '/.gitignore', 'shared/ignored/'#10'*.skip'#10);
  WriteRaw(Top + '/shared/.gitignore', 'local'#10);
  CheckCases(Top, Project, [
    C('a.txt', False),
    C('../shared/Kept.Test.pas', False),
    C('../shared/ignored/', True),
    C('../shared/ignored/Bad.Test.pas', True),
    C('../shared/x.skip', True),
    C('../shared/local', True)], True);
  { A path outside the worktree has no rules here at all. }
  Matcher := TLWPTGitIgnore.Create(Project);
  try
    Expect<Boolean>(Matcher.IsIgnored(FRoot + PathDelim + 'outside.skip',
      False)).ToBe(False);
  finally
    Matcher.Free;
  end;
end;

procedure TGitIgnoreTests.TestParentFilesApplyButProjectRootIsNeverIgnored;
var
  Top, Project: string;
  Matcher: TLWPTGitIgnore;
begin
  { A project in a subdirectory of a worktree gets the patterns of every
    `.gitignore` from the worktree root down, as Git applies them. }
  Top := NewWorktree('parent');
  Project := Top + PathDelim + 'proj';
  WriteRaw(Top + '/.gitignore',
    '*.skip'#10 +
    '/proj/anchored'#10);
  WriteRaw(Project + '/.gitignore', 'local-skip'#10);
  CheckCases(Top, Project, [
    C('a.txt', False),
    C('x.skip', True),
    C('sub/y.skip', True),
    C('anchored', True),
    C('sub/anchored', False),
    C('local-skip', True)], True);

  { Git would ignore everything below an excluded project directory, but
    LWPT judges only what is below the project root, so a project kept in
    an ignored scratch folder still discovers its own files. }
  Top := NewWorktree('ignored-project');
  Project := Top + PathDelim + 'scratch' + PathDelim + 'proj';
  WriteRaw(Top + '/.gitignore', 'scratch/'#10'*.skip'#10);
  CheckCases(Top, Project, [
    C('a.txt', False),
    C('tests/', False),
    C('x.skip', True)], False);
  Matcher := TLWPTGitIgnore.Create(Project);
  try
    Expect<string>(Matcher.Top).ToBe(Top);
    Expect<Boolean>(Matcher.IsIgnored(Project, True)).ToBe(False);
    { The project's ignored ancestor is exempt, but a sibling path in the
      worktree is judged like any other. }
    Expect<Boolean>(Matcher.IsIgnored(Top + PathDelim + 'scratch',
      True)).ToBe(False);
    Expect<Boolean>(Matcher.IsIgnored(Top + PathDelim + 'scratch' + PathDelim
      + 'outside.skip', False)).ToBe(True);
  finally
    Matcher.Free;
  end;
end;

procedure TGitIgnoreTests.TestWorktreeAndSubmoduleInfoExclude;
var
  Top, GitDirs: string;
begin
  { A linked worktree's `.git` file names its Git directory, whose
    `commondir` names the shared one that holds info/exclude. }
  GitDirs := FRoot + PathDelim + 'fabricated-gitdirs';
  Top := FRoot + PathDelim + 'fabricated-worktree';
  WriteRaw(Top + '/.git', 'gitdir: ../fabricated-gitdirs/worktrees/wt'#10);
  WriteRaw(GitDirs + '/worktrees/wt/commondir', '../..'#10);
  WriteRaw(GitDirs + '/worktrees/wt/info/exclude', 'from-worktree-dir'#10);
  WriteRaw(GitDirs + '/info/exclude', 'from-common-dir'#10);
  CheckCases(Top, Top, [
    C('from-common-dir', True),
    C('from-worktree-dir', False)], False);

  { A submodule's `.git` file names its own Git directory, absolutely. }
  Top := FRoot + PathDelim + 'fabricated-submodule';
  WriteRaw(Top + '/.git', 'gitdir: ' + GitDirs + PathDelim + 'modules'
    + PathDelim + 'sub'#10);
  WriteRaw(GitDirs + '/modules/sub/info/exclude', 'from-module-dir'#10);
  CheckCases(Top, Top, [
    C('from-module-dir', True),
    C('from-common-dir', False)], False);
end;

procedure TGitIgnoreTests.TestRealLinkedWorktreeReadsCommonInfoExclude;
var
  Main, Linked, Output: string;
begin
  if FGit = '' then
  begin
    { The fabricated layout above pins the same lookup without git. }
    WriteLn('git not found: the real linked worktree check needs git');
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  Main := NewWorktree('real-main');
  Linked := FRoot + PathDelim + 'real-linked';
  Expect<Integer>(RunGit(Main, ['-c', 'user.name=LWPT', '-c',
    'user.email=lwpt@example.invalid', 'commit', '-q', '--allow-empty', '-m',
    'init'], Output)).ToBe(0);
  Expect<Integer>(RunGit(Main, ['worktree', 'add', '-q', '--detach', Linked],
    Output)).ToBe(0);
  WriteRaw(Main + '/.git/info/exclude', 'shared-exclude'#10);
  CheckCases(Linked, Linked, [
    C('shared-exclude', True),
    C('kept', False)], True);
end;

procedure TGitIgnoreTests.TestProjectWithoutGitReadsItsOwnFiles;
var
  Project, Candidate, Expected: string;
begin
  { Outside any worktree the project root is the top, and its own ignore
    files still apply. The temporary directory normally has no `.git`
    above it; if it does, that directory is the expected top. }
  Project := ExpandFileName(IncludeTrailingPathDelimiter(GetTempDir(False))
    + 'lwpt-gitignore-' + IntToStr(GetProcessID));
  if DirectoryExists(Project) then RecursiveDelete(Project);
  try
    WriteRaw(Project + '/.gitignore', '*.skip'#10);
    Expected := ExcludeTrailingPathDelimiter(Project);
    Candidate := Expected;
    while True do
    begin
      if DirectoryExists(Candidate + PathDelim + '.git')
         or FileExists(Candidate + PathDelim + '.git') then
      begin
        Expected := Candidate;
        Break;
      end;
      if ExcludeTrailingPathDelimiter(ExtractFileDir(Candidate)) = '' then
        Break;
      if Length(ExcludeTrailingPathDelimiter(ExtractFileDir(Candidate)))
         >= Length(Candidate) then
        Break;
      Candidate := ExcludeTrailingPathDelimiter(ExtractFileDir(Candidate));
    end;
    with TLWPTGitIgnore.Create(Project) do
    try
      Expect<string>(Top).ToBe(Expected);
    finally
      Free;
    end;
    CheckCases(Project, Project, [
      C('x.skip', True),
      C('a.txt', False)], False);
  finally
    RecursiveDelete(Project);
  end;
end;

procedure TGitIgnoreTests.TestReportsDecidingRule;
var
  Top: string;
  Matcher: TLWPTGitIgnore;
  Rule: TLWPTIgnoreRule;
begin
  Top := NewWorktree('rules');
  WriteRaw(Top + '/.gitignore', '*.log'#10'# note'#10'out/  '#10);
  WriteRaw(Top + '/sub/.gitignore', 'local'#10);
  WriteRaw(Top + '/.git/info/exclude', 'excluded'#10);
  ForceDirectories(Top + '/out/deep');
  ForceDirectories(Top + '/sub');
  Matcher := TLWPTGitIgnore.Create(Top);
  try
    { A file below an ignored directory reports the directory's rule. }
    Expect<Boolean>(Matcher.FindRule(Top + '/out/deep/x.txt', False,
      Rule)).ToBe(True);
    Expect<string>(Format('%s:%d:%s', [Rule.Source, Rule.Line,
      Rule.Pattern])).ToBe('.gitignore:3:out/');
    Expect<Boolean>(Matcher.FindRule(Top + '/sub/local', False,
      Rule)).ToBe(True);
    Expect<string>(Format('%s:%d:%s', [Rule.Source, Rule.Line,
      Rule.Pattern])).ToBe('sub/.gitignore:1:local');
    Expect<Boolean>(Matcher.FindRule(Top + '/excluded', False,
      Rule)).ToBe(True);
    Expect<string>(Format('%s:%d:%s', [Rule.Source, Rule.Line,
      Rule.Pattern])).ToBe('.git/info/exclude:1:excluded');
    Expect<Boolean>(Matcher.FindRule(Top + '/kept.txt', False,
      Rule)).ToBe(False);
    Expect<string>(Rule.Source).ToBe('');
  finally
    Matcher.Free;
  end;
end;

procedure TGitIgnoreTests.TestUnreadableIgnoreFileFails;
{$IFDEF UNIX}
var
  Top, Message: string;
  Matcher: TLWPTGitIgnore;
begin
  { An ignore file that exists but cannot be read fails loudly, so its
    patterns never silently stop applying. Root reads every file, so the
    case needs an unprivileged user, as CI runners are. }
  if FpGetEUid = 0 then
  begin
    WriteLn('running as root: an unreadable file cannot be made');
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  Top := NewWorktree('unreadable');
  WriteRaw(Top + '/.gitignore', 'x'#10);
  Expect<Integer>(FpChmod(Top + '/.gitignore', 0)).ToBe(0);
  Message := '';
  Matcher := TLWPTGitIgnore.Create(Top);
  try
    try
      Matcher.IsIgnored(Top + '/x', False);
    except
      on E: ELWPTError do Message := E.Message;
    end;
  finally
    Matcher.Free;
    FpChmod(Top + '/.gitignore', &644);
  end;
  Expect<Boolean>(Pos('cannot read ignore file', Message) > 0).ToBe(True);

  { A directory that hides an ignore file fails the same way, rather than
    reading as a missing file. }
  Top := NewWorktree('unreadable-info');
  WriteRaw(Top + '/.git/info/exclude', 'x'#10);
  Expect<Integer>(FpChmod(Top + '/.git/info', 0)).ToBe(0);
  Message := '';
  try
    try
      TLWPTGitIgnore.Create(Top).Free;
    except
      on E: ELWPTError do Message := E.Message;
    end;
  finally
    FpChmod(Top + '/.git/info', &755);
  end;
  Expect<Boolean>(Pos('cannot read ignore file', Message) > 0).ToBe(True);
end;
{$ELSE}
begin
  { Windows has no permission bit that hides a file from its owner. }
  Expect<Boolean>(True).ToBe(True);
end;
{$ENDIF}

procedure TGitIgnoreTests.SetupTests;
begin
  Test('wildmatch follows Git''s pathname rules', TestWildMatchFollowsGit);
  Test('comments, blank lines, escapes and trailing spaces',
    TestCommentsBlanksEscapesAndTrailingSpaces);
  Test('negation cannot re-include below an excluded directory',
    TestNegationCannotReincludeBelowExcludedDirectory);
  Test('a trailing slash matches directories and a slash anchors',
    TestTrailingSlashAndAnchoring);
  Test('** in leading, trailing and middle positions',
    TestDoubleAsteriskPositions);
  Test('bracket expressions, ranges and classes', TestBracketExpressions);
  Test('nested files and info/exclude follow Git''s precedence',
    TestNestedFilesAndPrecedence);
  Test('CRLF line endings and a byte order mark',
    TestLineEndingsAndByteOrderMark);
  Test('symlinked or non-regular ignore files are skipped',
    TestSymlinkedOrNonRegularIgnoreFilesAreSkipped);
  Test('parent files apply but the project root is never ignored',
    TestParentFilesApplyButProjectRootIsNeverIgnored);
  Test('a sibling unit root inside the worktree is judged',
    TestSiblingUnitRootIsJudged);
  Test('worktree and submodule .git files locate info/exclude',
    TestWorktreeAndSubmoduleInfoExclude);
  Test('a real linked worktree reads the common info/exclude',
    TestRealLinkedWorktreeReadsCommonInfoExclude);
  Test('a project outside any worktree reads its own files',
    TestProjectWithoutGitReadsItsOwnFiles);
  Test('reports the deciding rule', TestReportsDecidingRule);
  Test('an ignore file that cannot be read or inspected fails',
    TestUnreadableIgnoreFileFails);
end;

begin
  TestRunnerProgram.AddSuite(TGitIgnoreTests.Create(
    PROJECT_NAME + '.GitIgnore'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
