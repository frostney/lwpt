{ LWPT.ManifestEdit.Test — unit-tier coverage for the comment-preserving
  [dependencies] editor behind `lwpt add` / `lwpt remove` (ADR-0019):
  section location + creation, key matching (bare and quoted, commented
  lines ignored), insert / replace / delete, the inline-table refusal,
  and default-name derivation from parsed sources. Pure in-memory
  TStringList work — no disk, no subprocess (those live in
  tests/integration/AddRemove.Test.pas). }

program LWPT.ManifestEdit.Test;

{$mode delphi}{$H+}
{$modeswitch nestedcomments+}

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Manifest,
  LWPT.ManifestEdit,
  TestingPascalLibrary;

type
  TSetDependencyLineSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCreatesSectionWhenAbsent;
    procedure TestCommentedHeaderIsNotASection;
    procedure TestInsertsBeforeNextSectionKeepingPadding;
    procedure TestReplacesExistingEntry;
    procedure TestMatchesQuotedKey;
    procedure TestRefusesInlineTableEntry;
    procedure TestRecognisesSpacedHeader;
    procedure TestRecognisesQuotedHeader;
    procedure TestEscapesBackslashesInSpec;
    procedure TestEscapesControlCharactersInSpec;
    procedure TestPreservesTrailingCommentOnReplace;
    procedure TestPreservesTrailingCommentPastEscapedQuote;
  end;

  TLoadManifestLinesSuite = class(TTestSuite)
  private
    function WriteRaw(const AName, AContent: string): string;
  public
    procedure SetupTests; override;
    procedure TestDetectsCrlfStyle;
    procedure TestDetectsLfStyle;
  end;

  TRemoveDependencyLineSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRemovesEntryAndKeepsNeighbours;
    procedure TestMissingNameReturnsFalse;
    procedure TestCommentedEntryIsNotRemovable;
  end;

  TDeriveDependencyNameSuite = class(TTestSuite)
  private
    function ParseDep(const ABare: string): TDependency;
  public
    procedure SetupTests; override;
    procedure TestGitHostSlugUsesRepoHalf;
    procedure TestPrefixedGitHostSlugUsesRepoHalf;
    procedure TestLocalPathUsesBasename;
    procedure TestLocalPathTrailingSlashStripped;
    procedure TestUrlIsNotDerivable;
    procedure TestInvalidBasenameIsNotDerivable;
  end;

{ --- SetDependencyLine ---------------------------------------------------- }

procedure TSetDependencyLineSuite.TestCreatesSectionWhenAbsent;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('# heading comment');
    SL.Add('[package]');
    SL.Add('name = "demo"');
    SetDependencyLine(SL, 'leaf', './vendor/leaf', Replaced);
    Expect<Boolean>(Replaced).ToBe(False);
    Expect<string>(SL[SL.Count - 2]).ToBe('[dependencies]');
    Expect<string>(SL[SL.Count - 1]).ToBe('leaf = "./vendor/leaf"');
    { the original lines survive untouched }
    Expect<string>(SL[0]).ToBe('# heading comment');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestCommentedHeaderIsNotASection;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    { init's scaffold hint — must not be mistaken for the section }
    SL.Add('[package]');
    SL.Add('name = "demo"');
    SL.Add('# [dependencies]');
    SL.Add('# leaf = "../leaf"');
    SetDependencyLine(SL, 'leaf', '../leaf', Replaced);
    Expect<Boolean>(Replaced).ToBe(False);
    Expect<string>(SL[SL.Count - 2]).ToBe('[dependencies]');
    Expect<string>(SL[SL.Count - 1]).ToBe('leaf = "../leaf"');
    Expect<string>(SL[2]).ToBe('# [dependencies]');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestInsertsBeforeNextSectionKeepingPadding;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('first = "a/b"');
    SL.Add('');
    SL.Add('[build]');
    SL.Add('x = { source = "source/x.pas" }');
    SetDependencyLine(SL, 'second', 'c/d@^1.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(False);
    Expect<string>(SL[1]).ToBe('first = "a/b"');
    Expect<string>(SL[2]).ToBe('second = "c/d@^1.0"');
    Expect<string>(SL[3]).ToBe('');
    Expect<string>(SL[4]).ToBe('[build]');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestReplacesExistingEntry;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('leaf = "a/leaf@^1.0"');
    SL.Add('other = "a/other"');
    SetDependencyLine(SL, 'leaf', 'a/leaf@^2.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(True);
    Expect<string>(SL[1]).ToBe('leaf = "a/leaf@^2.0"');
    Expect<string>(SL[2]).ToBe('other = "a/other"');
    Expect<Integer>(SL.Count).ToBe(3);
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestMatchesQuotedKey;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('"leaf" = "a/leaf@^1.0"');
    SetDependencyLine(SL, 'leaf', 'a/leaf@^2.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(True);
    Expect<string>(SL[1]).ToBe('leaf = "a/leaf@^2.0"');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestRefusesInlineTableEntry;
var
  SL: TStringList;
  Replaced: Boolean;
  Raised: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('leaf = { source = "a/leaf", include = ["src/**"] }');
    Raised := False;
    try
      SetDependencyLine(SL, 'leaf', 'a/leaf@^2.0', Replaced);
    except
      on EManifestError do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    { the entry survives the refused edit }
    Expect<string>(SL[1]).ToBe(
      'leaf = { source = "a/leaf", include = ["src/**"] }');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestEscapesBackslashesInSpec;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SetDependencyLine(SL, 'leaf', 'C:\deps\leaf', Replaced);
    Expect<string>(SL[1]).ToBe('leaf = "C:\\deps\\leaf"');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestRecognisesSpacedHeader;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  { "[ dependencies ]" is TOML-equivalent to "[dependencies]" — missing
    it would append a duplicate table the next parse rejects. }
  SL := TStringList.Create;
  try
    SL.Add('[ dependencies ]');
    SL.Add('leaf = "a/leaf@^1.0"');
    SetDependencyLine(SL, 'leaf', 'a/leaf@^2.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(True);
    Expect<Integer>(SL.Count).ToBe(2);
    Expect<string>(SL[1]).ToBe('leaf = "a/leaf@^2.0"');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestRecognisesQuotedHeader;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('["dependencies"]');
    SetDependencyLine(SL, 'leaf', 'a/leaf@^1.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(False);
    Expect<Integer>(SL.Count).ToBe(2);
    Expect<string>(SL[1]).ToBe('leaf = "a/leaf@^1.0"');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestEscapesControlCharactersInSpec;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  { A control character smuggled in via argv must not break the TOML
    string literal — same escaping rules as the lockfile writer. }
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SetDependencyLine(SL, 'leaf', 'bad'#10'spec', Replaced);
    Expect<string>(SL[1]).ToBe('leaf = "bad\nspec"');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestPreservesTrailingCommentOnReplace;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('leaf = "a/leaf@^1.0"  # pinned for v2.1 compat');
    SetDependencyLine(SL, 'leaf', 'a/leaf@^2.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(True);
    Expect<string>(SL[1])
      .ToBe('leaf = "a/leaf@^2.0"  # pinned for v2.1 compat');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.TestPreservesTrailingCommentPastEscapedQuote;
var
  SL: TStringList;
  Replaced: Boolean;
begin
  { The tail scan must not mistake an escaped quote inside the old
    value for the closing quote. }
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('leaf = "a\"b/leaf"  # keep me');
    SetDependencyLine(SL, 'leaf', 'a/leaf@^2.0', Replaced);
    Expect<Boolean>(Replaced).ToBe(True);
    Expect<string>(SL[1]).ToBe('leaf = "a/leaf@^2.0"  # keep me');
  finally
    SL.Free;
  end;
end;

procedure TSetDependencyLineSuite.SetupTests;
begin
  Test('creates the [dependencies] section when absent',
    TestCreatesSectionWhenAbsent);
  Test('a commented-out header is not a section',
    TestCommentedHeaderIsNotASection);
  Test('inserts at section end, before blank-line padding',
    TestInsertsBeforeNextSectionKeepingPadding);
  Test('replaces an existing bare entry in place',
    TestReplacesExistingEntry);
  Test('matches a quoted key', TestMatchesQuotedKey);
  Test('refuses to replace an inline-table entry',
    TestRefusesInlineTableEntry);
  Test('recognises the "[ dependencies ]" spelling',
    TestRecognisesSpacedHeader);
  Test('recognises the quoted-key header spelling',
    TestRecognisesQuotedHeader);
  Test('escapes backslashes in the written spec',
    TestEscapesBackslashesInSpec);
  Test('escapes control characters in the written spec',
    TestEscapesControlCharactersInSpec);
  Test('a trailing comment survives a replace',
    TestPreservesTrailingCommentOnReplace);
  Test('tail scan skips escaped quotes inside the old value',
    TestPreservesTrailingCommentPastEscapedQuote);
end;

{ --- LoadManifestLines ----------------------------------------------------- }

function TLoadManifestLinesSuite.WriteRaw(const AName,
  AContent: string): string;
var
  Stream: TFileStream;
begin
  Result := ExpandFileName('build/tests/tmp/manifestedit/' + AName);
  ForceDirectories(ExtractFileDir(Result));
  Stream := TFileStream.Create(Result, fmCreate);
  try
    if AContent <> '' then
      Stream.WriteBuffer(AContent[1], Length(AContent));
  finally
    Stream.Free;
  end;
end;

procedure TLoadManifestLinesSuite.TestDetectsCrlfStyle;
var
  SL: TStringList;
  Path: string;
begin
  Path := WriteRaw('crlf.toml',
    '[package]'#13#10'name = "x"'#13#10);
  SL := TStringList.Create;
  try
    LoadManifestLines(Path, SL);
    Expect<Boolean>(SL.TextLineBreakStyle = tlbsCRLF).ToBe(True);
    { the round-trip text carries the authored line breaks }
    Expect<Boolean>(Pos(#13#10, SL.Text) > 0).ToBe(True);
  finally
    SL.Free;
  end;
end;

procedure TLoadManifestLinesSuite.TestDetectsLfStyle;
var
  SL: TStringList;
  Path: string;
begin
  Path := WriteRaw('lf.toml',
    '[package]'#10'name = "x"'#10);
  SL := TStringList.Create;
  try
    LoadManifestLines(Path, SL);
    Expect<Boolean>(SL.TextLineBreakStyle = tlbsLF).ToBe(True);
    Expect<Integer>(Pos(#13, SL.Text)).ToBe(0);
  finally
    SL.Free;
  end;
end;

procedure TLoadManifestLinesSuite.SetupTests;
begin
  Test('a CRLF manifest round-trips as CRLF', TestDetectsCrlfStyle);
  Test('an LF manifest round-trips as LF', TestDetectsLfStyle);
end;

{ --- RemoveDependencyLine ------------------------------------------------- }

procedure TRemoveDependencyLineSuite.TestRemovesEntryAndKeepsNeighbours;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('first = "a/b"');
    SL.Add('leaf = "a/leaf@^1.0"  # pinned');
    SL.Add('last = "a/c"');
    Expect<Boolean>(RemoveDependencyLine(SL, 'leaf')).ToBe(True);
    Expect<Integer>(SL.Count).ToBe(3);
    Expect<string>(SL[1]).ToBe('first = "a/b"');
    Expect<string>(SL[2]).ToBe('last = "a/c"');
  finally
    SL.Free;
  end;
end;

procedure TRemoveDependencyLineSuite.TestMissingNameReturnsFalse;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('leaf = "a/leaf"');
    Expect<Boolean>(RemoveDependencyLine(SL, 'nope')).ToBe(False);
    Expect<Integer>(SL.Count).ToBe(2);
  finally
    SL.Free;
  end;
end;

procedure TRemoveDependencyLineSuite.TestCommentedEntryIsNotRemovable;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('[dependencies]');
    SL.Add('# leaf = "a/leaf"');
    Expect<Boolean>(RemoveDependencyLine(SL, 'leaf')).ToBe(False);
    Expect<Integer>(SL.Count).ToBe(2);
  finally
    SL.Free;
  end;
end;

procedure TRemoveDependencyLineSuite.SetupTests;
begin
  Test('removes the entry and keeps its neighbours',
    TestRemovesEntryAndKeepsNeighbours);
  Test('returns False for a missing name', TestMissingNameReturnsFalse);
  Test('a commented entry is not removable',
    TestCommentedEntryIsNotRemovable);
end;

{ --- DeriveDependencyName ------------------------------------------------- }

function TDeriveDependencyNameSuite.ParseDep(const ABare: string): TDependency;
begin
  Result := Default(TDependency);
  Result.Name := ABare;
  ParseBareDepString(ABare, nil, Result);
end;

procedure TDeriveDependencyNameSuite.TestGitHostSlugUsesRepoHalf;
begin
  Expect<string>(DeriveDependencyName(ParseDep('HashLoad/horse@^4.0.0')))
    .ToBe('horse');
end;

procedure TDeriveDependencyNameSuite.TestPrefixedGitHostSlugUsesRepoHalf;
begin
  Expect<string>(DeriveDependencyName(ParseDep('gitlab:org/widget@1.2.3')))
    .ToBe('widget');
end;

procedure TDeriveDependencyNameSuite.TestLocalPathUsesBasename;
begin
  Expect<string>(DeriveDependencyName(ParseDep('./vendor/leaf')))
    .ToBe('leaf');
  Expect<string>(DeriveDependencyName(ParseDep('../c'))).ToBe('c');
end;

procedure TDeriveDependencyNameSuite.TestLocalPathTrailingSlashStripped;
begin
  Expect<string>(DeriveDependencyName(ParseDep('./vendor/leaf/')))
    .ToBe('leaf');
end;

procedure TDeriveDependencyNameSuite.TestUrlIsNotDerivable;
begin
  Expect<string>(DeriveDependencyName(
    ParseDep('https://example.com/dist/leaf-1.0.tar.gz'))).ToBe('');
end;

procedure TDeriveDependencyNameSuite.TestInvalidBasenameIsNotDerivable;
begin
  { 'my.lib' fails the package-name grammar — caller must pass --name }
  Expect<string>(DeriveDependencyName(ParseDep('./vendor/my.lib'))).ToBe('');
end;

procedure TDeriveDependencyNameSuite.SetupTests;
begin
  Test('owner/repo derives the repo half', TestGitHostSlugUsesRepoHalf);
  Test('prefixed git-host slug derives the repo half',
    TestPrefixedGitHostSlugUsesRepoHalf);
  Test('local path derives its basename', TestLocalPathUsesBasename);
  Test('trailing path delimiter is stripped before deriving',
    TestLocalPathTrailingSlashStripped);
  Test('URL sources are not derivable (--name required)',
    TestUrlIsNotDerivable);
  Test('basename outside the name grammar is not derivable',
    TestInvalidBasenameIsNotDerivable);
end;

begin
  TestRunnerProgram.AddSuite(
    TSetDependencyLineSuite.Create('LWPT.ManifestEdit: SetDependencyLine'));
  TestRunnerProgram.AddSuite(
    TRemoveDependencyLineSuite.Create('LWPT.ManifestEdit: RemoveDependencyLine'));
  TestRunnerProgram.AddSuite(
    TDeriveDependencyNameSuite.Create('LWPT.ManifestEdit: DeriveDependencyName'));
  TestRunnerProgram.AddSuite(
    TLoadManifestLinesSuite.Create('LWPT.ManifestEdit: LoadManifestLines'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
