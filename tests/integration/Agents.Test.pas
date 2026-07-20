{ Agents.Test — pins lwpt agents subcommand semantics (ADR-0024).

  `lwpt agents` writes a marker-fenced, machine-generated command
  reference into the project's AGENTS.md; `--check` verifies the block
  byte-for-byte and exits 1 when stale. The block is rendered from the
  same registry that drives `--help`, so the two surfaces cannot
  drift — the last test asserts exactly that, by diffing the --help
  command list against the generated block.

  Coverage:

    1. Fresh project → AGENTS.md created with markers, subcommands,
       and the manifest's run-scripts.
    2. Second run is byte-idempotent and reports "up to date".
    3. --check on a fresh block exits 0; after an in-region edit it
       exits 1 and writes nothing.
    4. Regeneration replaces the region while preserving hand-written
       prose outside the markers.
    5. A manifest edit (run-script removed) makes the block stale;
       regeneration renders the no-run-scripts placeholder.
    6. Corrupt marker pair (begin removed) → exit non-zero, file
       untouched.
    7. Missing manifest → exit non-zero (agents is project-scoped).
    8. Every command listed by `lwpt --help` appears in the block.

  Scratch project: minimal manifest with one user-declared run-script
  section, wiped and re-seeded per run. }

program Agents.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.Scratch;

const
  MARKER_BEGIN = '<!-- lwpt:agents:begin -->';
  MARKER_END   = '<!-- lwpt:agents:end -->';

type
  TAgentsE2E = class(TTestSuite)
  private
    FOrigDir, FScratch: string;
    procedure SetupScratchProject;
    function AgentsPath: string;
    function ReadAgents: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestGenerateCreatesMarkerFencedReference;
    procedure TestSecondRunIsByteIdempotent;
    procedure TestCheckFreshExitsZero;
    procedure TestCheckStaleExitsOneAndWritesNothing;
    procedure TestRegenerateReplacesRegionPreservesProse;
    procedure TestManifestEditGoesStaleThenPlaceholder;
    procedure TestCorruptMarkersExitNonZero;
    procedure TestDuplicateMarkersExitNonZero;
    procedure TestInlineMarkerMentionIsProse;
    procedure TestMarkerlessCRLFAppendPreservesBytes;
    procedure TestPlatformPlaceholderScriptRendersVerbatim;
    procedure TestMixedCaseReservedScriptNameFailsAtLoad;
    procedure TestMissingManifestExitsNonZero;
    procedure TestHelpAndGeneratedBlockAgree;
  end;

procedure TAgentsE2E.SetupScratchProject;
begin
  ForceDirectories(FScratch + '/scripts');

  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "agents-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[hello]'#10 +
    'script = "scripts/hello.pas"'#10);

  WriteTextFile(FScratch + '/scripts/hello.pas',
    'begin'#10 +
    '  WriteLn(''hello'');'#10 +
    'end.'#10);
end;

{ Byte-exact fixture writer. Tests.Scratch's WriteTextFile round-trips
  through TStringList, which rewrites line endings to the platform
  default — unusable for fixtures whose exact bytes (LF vs CRLF) are
  the thing under test. }
procedure WriteBytesFile(const APath, AContent: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AContent <> '' then
      Stream.WriteBuffer(AContent[1], Length(AContent));
  finally
    Stream.Free;
  end;
end;

function TAgentsE2E.AgentsPath: string;
begin
  Result := FScratch + '/AGENTS.md';
end;

function TAgentsE2E.ReadAgents: string;
begin
  Result := ReadBinaryFile(AgentsPath);
end;

procedure TAgentsE2E.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := CreateScratchRoot('agents-e2e');
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));

  RecursiveDelete(FScratch);
  ForceDirectories(FScratch);
  SetupScratchProject;
end;

procedure TAgentsE2E.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TAgentsE2E.TestGenerateCreatesMarkerFencedReference;
var
  R: TLwptResult;
  Content: string;
begin
  R := RunLwpt(['agents'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(FileExists(AgentsPath)).ToBe(True);

  Content := ReadAgents;
  Expect<Boolean>(Pos(MARKER_BEGIN, Content) > 0).ToBe(True);
  Expect<Boolean>(Pos(MARKER_END, Content) > 0).ToBe(True);
  { Representative built-ins with their usage + option detail. }
  Expect<Boolean>(Pos('- `lwpt install [--frozen]`', Content) > 0).ToBe(True);
  Expect<Boolean>(Pos('`--frozen`', Content) > 0).ToBe(True);
  Expect<Boolean>(Pos('- `lwpt agents [--check]`', Content) > 0).ToBe(True);
  { The manifest's run-script, addressable form. }
  Expect<Boolean>(Pos('- `lwpt run hello` — `scripts/hello.pas`', Content) > 0)
    .ToBe(True);
end;

procedure TAgentsE2E.TestSecondRunIsByteIdempotent;
var
  R: TLwptResult;
  Before, After: string;
begin
  RunLwpt(['agents'], FScratch);
  Before := ReadAgents;
  R := RunLwpt(['agents'], FScratch);
  After := ReadAgents;
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('up to date', R.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Before = After).ToBe(True);
end;

procedure TAgentsE2E.TestCheckFreshExitsZero;
var
  R: TLwptResult;
begin
  RunLwpt(['agents'], FScratch);
  R := RunLwpt(['agents', '--check'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TAgentsE2E.TestCheckStaleExitsOneAndWritesNothing;
var
  R: TLwptResult;
  Sabotaged: string;
begin
  RunLwpt(['agents'], FScratch);
  Sabotaged := StringReplace(ReadAgents, 'command reference',
    'command reference SABOTAGED', [rfReplaceAll]);
  WriteBytesFile(AgentsPath, Sabotaged);

  R := RunLwpt(['agents', '--check'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('stale', R.Stderr) > 0).ToBe(True);
  { --check must not have rewritten the file. }
  Expect<Boolean>(ReadAgents = Sabotaged).ToBe(True);
end;

procedure TAgentsE2E.TestRegenerateReplacesRegionPreservesProse;
var
  R: TLwptResult;
  Content: string;
begin
  RunLwpt(['agents'], FScratch);
  Content := 'Hand-written preamble.'#10#10 + ReadAgents
    + #10'Hand-written epilogue.'#10;
  WriteBytesFile(AgentsPath, StringReplace(Content, 'command reference',
    'command reference SABOTAGED', [rfReplaceAll]));

  R := RunLwpt(['agents'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  Content := ReadAgents;
  Expect<Boolean>(Pos('Hand-written preamble.', Content) > 0).ToBe(True);
  Expect<Boolean>(Pos('Hand-written epilogue.', Content) > 0).ToBe(True);
  Expect<Boolean>(Pos('SABOTAGED', Content) > 0).ToBe(False);
  { And the repaired file verifies fresh. }
  R := RunLwpt(['agents', '--check'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TAgentsE2E.TestManifestEditGoesStaleThenPlaceholder;
var
  R: TLwptResult;
begin
  RunLwpt(['agents'], FScratch);

  { Drop the run-script from the manifest: the committed block still
    lists it, so --check must flag drift. }
  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "agents-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10);
  R := RunLwpt(['agents', '--check'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(1);

  R := RunLwpt(['agents'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('No run-scripts declared', ReadAgents) > 0).ToBe(True);
  Expect<Boolean>(Pos('lwpt run hello', ReadAgents) > 0).ToBe(False);

  { Restore the original manifest + block for later tests. }
  SetupScratchProject;
  RunLwpt(['agents'], FScratch);
end;

procedure TAgentsE2E.TestCorruptMarkersExitNonZero;
var
  R: TLwptResult;
  Content, Corrupt: string;
begin
  RunLwpt(['agents'], FScratch);
  Content := ReadAgents;
  Corrupt := StringReplace(Content, MARKER_BEGIN, '', []);
  WriteBytesFile(AgentsPath, Corrupt);

  R := RunLwpt(['agents'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('marker', R.Stderr) > 0).ToBe(True);
  { The corrupt file must be left untouched for the user to repair. }
  Expect<Boolean>(ReadAgents = Corrupt).ToBe(True);

  { Repair for later tests. }
  WriteBytesFile(AgentsPath, Content);
end;

procedure TAgentsE2E.TestDuplicateMarkersExitNonZero;
var
  R: TLwptResult;
  Content, Doubled: string;
begin
  RunLwpt(['agents'], FScratch);
  Content := ReadAgents;
  { A second begin marker on its own line makes the pair ambiguous;
    splicing against a guessed pair could eat prose, so it must be a
    hard error that leaves the file untouched. }
  Doubled := Content + #10 + MARKER_BEGIN + #10;
  WriteBytesFile(AgentsPath, Doubled);

  R := RunLwpt(['agents'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('marker', R.Stderr) > 0).ToBe(True);
  Expect<Boolean>(ReadAgents = Doubled).ToBe(True);

  WriteBytesFile(AgentsPath, Content);
end;

procedure TAgentsE2E.TestInlineMarkerMentionIsProse;
var
  R: TLwptResult;
  Content, WithMention, Mention: string;
begin
  RunLwpt(['agents'], FScratch);
  { Marker text mid-line is prose, not a marker: it must neither trip
    the duplicate-marker guard nor shift the splice boundaries. }
  Mention := 'This doc mentions ' + MARKER_BEGIN + ' inline as prose.';
  WithMention := Mention + #10#10 + ReadAgents;
  WriteBytesFile(AgentsPath, WithMention);

  R := RunLwpt(['agents'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Content := ReadAgents;
  Expect<Boolean>(Pos(Mention, Content) > 0).ToBe(True);
  R := RunLwpt(['agents', '--check'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
end;

procedure TAgentsE2E.TestMarkerlessCRLFAppendPreservesBytes;
var
  R: TLwptResult;
  Original, Content: string;
begin
  DeleteFile(AgentsPath);
  { A hand-written CRLF file without markers: the append must keep the
    existing bytes as an exact prefix — no line-ending rewriting. }
  Original := '# My CRLF notes'#13#10#13#10'Hand-written.'#13#10;
  WriteBytesFile(AgentsPath, Original);

  R := RunLwpt(['agents'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Content := ReadAgents;
  Expect<Boolean>(Copy(Content, 1, Length(Original)) = Original).ToBe(True);
  Expect<Boolean>(Pos(MARKER_BEGIN, Content) > 0).ToBe(True);
  { And re-running stays idempotent. }
  R := RunLwpt(['agents', '--check'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);

  DeleteFile(AgentsPath);
  RunLwpt(['agents'], FScratch);
end;

procedure TAgentsE2E.TestPlatformPlaceholderScriptRendersVerbatim;
var
  R: TLwptResult;
begin
  { A platform-interpolated script path must render as declared —
    otherwise the committed block differs per platform and --check
    flips in cross-platform CI. }
  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "agents-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[native]'#10 +
    'script = "scripts/{platform.os}.pas"'#10);

  R := RunLwpt(['agents'], FScratch);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('`scripts/{platform.os}.pas`', ReadAgents) > 0)
    .ToBe(True);

  SetupScratchProject;
  RunLwpt(['agents'], FScratch);
end;

procedure TAgentsE2E.TestMixedCaseReservedScriptNameFailsAtLoad;
var
  R: TLwptResult;
begin
  { Dispatch is case-insensitive, so a case-variant section like
    [Agents] would list as a script yet be unreachable. The reserved-
    name guard must reject it at manifest load. }
  WriteTextFile(FScratch + '/lwpt.toml',
    '[package]'#10 +
    'name = "agents-e2e"'#10 +
    'version = "0.0.0"'#10 +
    'units = ["scripts"]'#10 +
    ''#10 +
    '[Agents]'#10 +
    'script = "scripts/hello.pas"'#10);

  R := RunLwpt(['agents'], FScratch);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(Pos('shadows', R.Stderr) > 0).ToBe(True);

  SetupScratchProject;
  RunLwpt(['agents'], FScratch);
end;

procedure TAgentsE2E.TestMissingManifestExitsNonZero;
var
  R: TLwptResult;
  Bare: string;
begin
  Bare := FScratch + '/no-manifest';
  ForceDirectories(Bare);
  R := RunLwpt(['agents'], Bare);
  Expect<Boolean>(R.ExitCode <> 0).ToBe(True);
  Expect<Boolean>(FileExists(Bare + '/AGENTS.md')).ToBe(False);
end;

{ Full-fidelity drift check for one subcommand: its `--help` usage
  line, every option name, and every option help text must appear in
  the generated block. Parsed from the live help output so a renderer
  regression (dropped usage, missing option bullet, truncated help
  text) fails here even though both surfaces share one registry. }
procedure ExpectCommandHelpInBlock(const AName, AContent: string);
var
  R: TLwptResult;
  Lines: TStringList;
  Line, Usage, OptName, OptHelp: string;
  i, InOptions, SpacePos: Integer;
begin
  R := RunLwpt([AName, '--help']);
  Expect<Integer>(R.ExitCode).ToBe(0);

  Lines := TStringList.Create;
  try
    Lines.Text := R.Stdout;
    InOptions := 0;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      if Pos('usage: ', Line) = 1 then
      begin
        { "usage: lwpt <name> <usage-args>" → the block bullet must
          carry the identical command string. }
        Usage := Copy(Line, Length('usage: ') + 1, MaxInt);
        Expect<Boolean>(Pos('- `' + Usage + '`', AContent) > 0).ToBe(True);
        Continue;
      end;
      if Trim(Line) = 'options:' then
      begin
        InOptions := 1;
        Continue;
      end;
      if (InOptions = 1) and (Pos('  --', Line) = 1) then
      begin
        OptName := Trim(Line);
        SpacePos := Pos(' ', OptName);
        OptHelp := Trim(Copy(OptName, SpacePos + 1, MaxInt));
        OptName := Copy(OptName, 1, SpacePos - 1);
        Expect<Boolean>(Pos(OptName, AContent) > 0).ToBe(True);
        Expect<Boolean>(Pos(OptHelp, AContent) > 0).ToBe(True);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TAgentsE2E.TestHelpAndGeneratedBlockAgree;
var
  R: TLwptResult;
  Help, Content, Line, Name: string;
  Lines: TStringList;
  i, InCommands, SpacePos: Integer;
begin
  RunLwpt(['agents'], FScratch);
  Content := ReadAgents;

  R := RunLwpt(['--help']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Help := R.Stdout;

  { Every name in --help's `commands:` section must have a bullet in
    the generated block — and its full per-command help projection
    (usage + options + help texts) must be present too. Parsed from
    the live help output, not a hardcoded list, so a newly registered
    subcommand can never appear in one surface and not the other. }
  Lines := TStringList.Create;
  try
    Lines.Text := Help;
    InCommands := 0;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      if Trim(Line) = 'commands:' then
      begin
        InCommands := 1;
        Continue;
      end;
      if InCommands = 0 then Continue;
      if Trim(Line) = '' then Break;

      Name := Trim(Line);
      SpacePos := Pos(' ', Name);
      if SpacePos > 0 then
        Name := Copy(Name, 1, SpacePos - 1);
      Expect<Boolean>(Pos('- `lwpt ' + Name, Content) > 0).ToBe(True);
      ExpectCommandHelpInBlock(Name, Content);
    end;
    { Sanity: the loop actually saw the commands section. }
    Expect<Integer>(InCommands).ToBe(1);
  finally
    Lines.Free;
  end;
end;

procedure TAgentsE2E.SetupTests;
begin
  Test('agents creates AGENTS.md with a marker-fenced command reference',
    TestGenerateCreatesMarkerFencedReference);
  Test('a second run is byte-idempotent and reports up to date',
    TestSecondRunIsByteIdempotent);
  Test('--check on a fresh block exits 0',
    TestCheckFreshExitsZero);
  Test('--check on an edited block exits 1 without writing',
    TestCheckStaleExitsOneAndWritesNothing);
  Test('regeneration replaces the region and preserves outside prose',
    TestRegenerateReplacesRegionPreservesProse);
  Test('a manifest edit goes stale; regeneration renders the placeholder',
    TestManifestEditGoesStaleThenPlaceholder);
  Test('a corrupt marker pair exits non-zero and leaves the file untouched',
    TestCorruptMarkersExitNonZero);
  Test('duplicate markers exit non-zero and leave the file untouched',
    TestDuplicateMarkersExitNonZero);
  Test('an inline marker mention is prose, not a marker',
    TestInlineMarkerMentionIsProse);
  Test('appending to a markerless CRLF file preserves its bytes exactly',
    TestMarkerlessCRLFAppendPreservesBytes);
  Test('a {platform.os} script path renders verbatim, not interpolated',
    TestPlatformPlaceholderScriptRendersVerbatim);
  Test('a case-variant reserved script name ([Agents]) fails at manifest load',
    TestMixedCaseReservedScriptNameFailsAtLoad);
  Test('missing lwpt.toml exits non-zero (agents is project-scoped)',
    TestMissingManifestExitsNonZero);
  Test('every --help command appears in the generated block',
    TestHelpAndGeneratedBlockAgree);
end;

begin
  TestRunnerProgram.AddSuite(TAgentsE2E.Create('lwpt agents: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
