{ LWPT — lightweight Pascal toolkit.

  One executable, eleven subcommands sharing a common core (manifest,
  TOML, resolver, cfg emitter):
    init      scaffold a new project or adopt an existing manifest
    install   resolve + fetch dependencies, write lwpt.lock + lwpt.cfg
    add       add a dependency to lwpt.toml + install it (ADR-0019)
    remove    remove dependencies from lwpt.toml + prune their modules
    build     compile manifest [build] entries
    format    format uses-clauses and identifiers (--check to verify only)
    duplication report manifest-scoped Type-2 Pascal token clones
    test      discover + compile + run *.Test.pas files
    repair    reclaim install, build-session, and worker-lease residue
    run       invoke a user-declared run-script (or alias a subcommand)
    health    report Pascal complexity and optional Git hotspots
    agents    write/verify the agent-facing command reference in
              AGENTS.md (ADR-0027)

  earlier (ADR-0015) there was an eighth subcommand, `export`, which
  extruded the embedded TestingPascalLibrary blob into the consumer's
  modules dir. The testing framework now lives in the `testing`
  workspace package and is consumed via `lwpt install` like any other
  dep; the export subcommand + its embedded-blob plumbing are gone.

  CLI: the CLI namespace (CLI.Parser, CLI.Options, CLI.Help,
  CLI.Subcommands, CLI.Prompts) lives in the `cli` workspace package
  under packages/cli/source/. Per ADR-0017, LWPT is canonical for that
  package; the dispatch + prompts units are LWPT-original additions
  to the namespace. }
program lwpt;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  LWPT.Command.Add,
  LWPT.Command.Agents,
  LWPT.Command.Build,
  LWPT.Command.Duplication,
  LWPT.Command.Format,
  LWPT.Command.Health,
  LWPT.Command.Init,
  LWPT.Command.Install,
  LWPT.Command.Remove,
  LWPT.Command.Repair,
  LWPT.Command.Run,
  LWPT.Command.Testing,
  LWPT.Core,
  LWPT.ProcessTree;

const
  MILLISECONDS_PER_CENTISECOND = 10;
  CENTISECONDS_PER_SECOND = 100;

function FormatElapsedMilliseconds(const AMilliseconds: QWord): string;
var
  TotalCentiseconds, Seconds, Centiseconds : QWord;
  CentisecondsText : string;
begin
  TotalCentiseconds := (AMilliseconds
    + (MILLISECONDS_PER_CENTISECOND div 2))
    div MILLISECONDS_PER_CENTISECOND;
  Seconds := TotalCentiseconds div CENTISECONDS_PER_SECOND;
  Centiseconds := TotalCentiseconds mod CENTISECONDS_PER_SECOND;
  CentisecondsText := IntToStr(Centiseconds);
  if Length(CentisecondsText) = 1 then
    CentisecondsText := '0' + CentisecondsText;
  Result := IntToStr(Seconds) + '.' + CentisecondsText + 's';
end;

procedure ReportCommandCompletion(
  const ACompletion: TSubcommandCompletion);
var
  StatusText : string;
begin
  if ACompletion.ExitCode = 0 then
    StatusText := 'completed in '
  else
    StatusText := 'failed after ';
  Flush(Output);
  WriteLn(ErrOutput, PROGRAM_NAME, ' ', ACompletion.CommandName, ': ',
    StatusText, FormatElapsedMilliseconds(ACompletion.ElapsedMilliseconds));
end;

function ErrPrefix(const ASubcommand: string): string; inline;
begin
  Result := PROGRAM_NAME + ' ' + ASubcommand + ': ';
end;

{ Declared ahead of the handlers because HandleAgents renders the
  command surface from the live registry itself — the registry is the
  single source of truth for both `--help` and the agents block. }
var
  Registry : TSubcommandRegistry;

{ --- install ------------------------------------------------------------- }
function HandleInstall(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Frozen : Boolean;
  i : Integer;
begin
  Frozen := False;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'frozen')
       and AOptions[i].Present then
      Frozen := True;
  try
    CmdInstall(MANIFEST_FILE, Frozen);
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('install'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- add (ADR-0019) ------------------------------------------------------ }
function HandleAdd(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  NameOverride : string;
  i : Integer;
begin
  if APositionals.Count <> 1 then
  begin
    WriteLn(ErrOutput, ErrPrefix('add'),
      'expected exactly one <source[@version]> argument');
    Exit(1);
  end;
  NameOverride := '';
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'name')
       and (AOptions[i] is TStringOption) then
      NameOverride := TStringOption(AOptions[i]).ValueOr('');
  try
    CmdAdd(MANIFEST_FILE, APositionals[0], NameOverride);
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('add'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- remove (ADR-0019) --------------------------------------------------- }
function HandleRemove(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Names : array of string;
  i : Integer;
begin
  if APositionals.Count = 0 then
  begin
    WriteLn(ErrOutput, ErrPrefix('remove'),
      'expected at least one dependency name');
    Exit(1);
  end;
  SetLength(Names, APositionals.Count);
  for i := 0 to APositionals.Count - 1 do
    Names[i] := APositionals[i];
  try
    CmdRemove(MANIFEST_FILE, Names);
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('remove'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- build -------------------------------------------------------------- }
function HandleBuild(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Release, Clean, JobsPresent, Verbose : Boolean;
  Jobs : Integer;
  ModeVal : string;
  EntryNames : array of string;
  i : Integer;
begin
  Release := False;          { dev is the default }
  Clean   := False;
  Jobs    := 0;              { auto: bounded by graph + machine budget }
  JobsPresent := False;
  Verbose := False;
  for i := 0 to High(AOptions) do
  begin
    if SameText(AOptions[i].LongName, 'clean') and AOptions[i].Present then
      Clean := True;
    if SameText(AOptions[i].LongName, 'verbose')
       and AOptions[i].Present then
      Verbose := True;
    if SameText(AOptions[i].LongName, 'mode')
       and (AOptions[i] is TStringOption) then
    begin
      ModeVal := LowerCase(
        TStringOption(AOptions[i]).ValueOr('dev'));
      if ModeVal = 'release' then
        Release := True
      else if ModeVal <> 'dev' then
      begin
        WriteLn(ErrOutput, ErrPrefix('build'),
          '--mode must be "dev" or "release", got "', ModeVal, '"');
        Exit(1);
      end;
    end;
    if SameText(AOptions[i].LongName, 'jobs')
       and (AOptions[i] is TIntegerOption) then
    begin
      Jobs := TIntegerOption(AOptions[i]).ValueOr(0);
      JobsPresent := AOptions[i].Present;
    end;
  end;
  if JobsPresent and (Jobs < 1) then
  begin
    WriteLn(ErrOutput, ErrPrefix('build'),
      '--jobs must be a positive integer, got ', Jobs);
    Exit(1);
  end;
  SetLength(EntryNames, APositionals.Count);
  for i := 0 to APositionals.Count - 1 do
    EntryNames[i] := APositionals[i];
  try
    InstallProcessTreeSignalForwarding;
    Result := CmdBuild(MANIFEST_FILE, EntryNames, Release, Clean, Jobs,
      Verbose);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('build'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- format ------------------------------------------------------------- }
function HandleFormat(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  CheckOnly : Boolean;
  i : Integer;
begin
  CheckOnly := False;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'check')
       and AOptions[i].Present then
      CheckOnly := True;
  try
    Result := CmdFormat(MANIFEST_FILE, CheckOnly);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('format'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- duplication -------------------------------------------------------- }
function HandleDuplication(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  JSON: Boolean;
  i: Integer;
begin
  if APositionals.Count <> 0 then
  begin
    WriteLn(ErrOutput, ErrPrefix('duplication'),
      'unexpected argument "', APositionals[0],
      '" (duplication takes no positionals, only --json)');
    Exit(1);
  end;
  JSON := False;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'json') and AOptions[i].Present then
      JSON := True;
  try
    Result := CmdDuplication(MANIFEST_FILE, JSON);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('duplication'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- test --------------------------------------------------------------- }
function HandleTest(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  IncludeE2E, Verbose : Boolean;
  TierVal : string;
  Jobs, Bail, i : Integer;
begin
  IncludeE2E := False;
  Verbose := False;
  Jobs := 0;
  Bail := -1;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'tier')
       and (AOptions[i] is TStringOption) then
    begin
      TierVal := LowerCase(
        TStringOption(AOptions[i]).ValueOr('default'));
      if TierVal = 'e2e' then
        IncludeE2E := True
      else if TierVal <> 'default' then
      begin
        WriteLn(ErrOutput, ErrPrefix('test'),
          '--tier must be "default" or "e2e", got "', TierVal, '"');
        Exit(1);
      end;
    end
    else if SameText(AOptions[i].LongName, 'verbose')
       and AOptions[i].Present then
      Verbose := True
    else if SameText(AOptions[i].LongName, 'jobs')
       and (AOptions[i] is TIntegerOption) and AOptions[i].Present then
    begin
      Jobs := TIntegerOption(AOptions[i]).Value;
      if Jobs < 1 then
      begin
        WriteLn(ErrOutput, ErrPrefix('test'),
          '--jobs must be a positive integer');
        Exit(1);
      end;
    end
    else if SameText(AOptions[i].LongName, 'bail')
       and (AOptions[i] is TIntegerOption) and AOptions[i].Present then
    begin
      Bail := TIntegerOption(AOptions[i]).Value;
      if Bail < 0 then
      begin
        WriteLn(ErrOutput, ErrPrefix('test'),
          '--bail must be a non-negative integer');
        Exit(1);
      end;
    end;
  try
    InstallProcessTreeSignalForwarding;
    Result := CmdTest(MANIFEST_FILE, IncludeE2E, Jobs, Bail, Verbose);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('test'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- repair ------------------------------------------------------------- }
function HandleRepair(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  try
    CmdRepair(MANIFEST_FILE);
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('repair'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- init --------------------------------------------------------------- }
function HandleInit(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Yes, Force, Adopt : Boolean;
  i : Integer;
begin
  Yes := False;
  Force := False;
  Adopt := False;
  for i := 0 to High(AOptions) do
  begin
    if (SameText(AOptions[i].LongName, 'yes')
        or SameText(AOptions[i].ShortName, 'y'))
       and AOptions[i].Present then Yes := True;
    if SameText(AOptions[i].LongName, 'force')
       and AOptions[i].Present then Force := True;
    if SameText(AOptions[i].LongName, 'adopt')
       and AOptions[i].Present then Adopt := True;
  end;
  try
    CmdInit(Yes, Force, Adopt);
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('init'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- run (ADR-0013) ------------------------------------------------------ }

function HandleRun(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Name : string;
  Aliases : array of string;
  i, N : Integer;
begin
  { Subcommand-aliasing (`lwpt run install`) is intercepted in
    CLI.Subcommands.Run BEFORE this handler is called. So when we
    arrive here, the name (if any) is always a user-declared script
    name — never a subcommand. Empty positionals = list mode. }
  if APositionals.Count = 0 then
    Name := ''
  else
    Name := APositionals[0];
  { Every registered subcommand except run itself is a valid alias
    (`lwpt run run` would be dispatch recursion, not an alias). }
  SetLength(Aliases, Registry.Count);
  N := 0;
  for i := 0 to Registry.Count - 1 do
    if not SameText(Registry.Item(i).Name, 'run') then
    begin
      Aliases[N] := Registry.Item(i).Name;
      Inc(N);
    end;
  SetLength(Aliases, N);
  try
    Result := CmdRun(MANIFEST_FILE, Name, Aliases);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('run'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- health (ADR-0006) -------------------------------------------------- }

function HandleHealth(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  IncludeHotspots, JSON: Boolean;
  OptionIndex: Integer;
begin
  if APositionals.Count <> 0 then
  begin
    WriteLn(ErrOutput, ErrPrefix('health'),
      'health takes no positional arguments');
    Exit(1);
  end;
  IncludeHotspots := False;
  JSON := False;
  for OptionIndex := 0 to High(AOptions) do
    if AOptions[OptionIndex].Present then
    begin
      if SameText(AOptions[OptionIndex].LongName, 'json') then JSON := True
      else if SameText(AOptions[OptionIndex].LongName, 'hotspots') then
        IncludeHotspots := True;
    end;
  try
    Result := CmdHealth(MANIFEST_FILE, JSON, IncludeHotspots);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('health'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- agents (ADR-0027) --------------------------------------------------- }
function HandleAgents(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Check : Boolean;
  i : Integer;
begin
  if APositionals.Count <> 0 then
  begin
    WriteLn(ErrOutput, ErrPrefix('agents'),
      'unexpected argument "', APositionals[0],
      '" (agents takes no positionals, only --check)');
    Exit(1);
  end;
  Check := False;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'check')
       and AOptions[i].Present then
      Check := True;
  try
    Result := CmdAgents(MANIFEST_FILE, Registry, Check);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('agents'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- top-level flags ----------------------------------------------------- }
function HandleTopLevelFlags: Boolean;
var
  i : Integer;
  A : string;
begin
  Result := False;
  for i := 1 to ParamCount do
  begin
    A := ParamStr(i);
    if (A = '--version') or (A = '-v') or (LowerCase(A) = 'version') then
    begin
      WriteLn(PROGRAM_NAME, ' ', PROGRAM_VERSION);
      Result := True;
      Exit;
    end;
  end;
end;

{ --- registration -------------------------------------------------------- }
var
  InstallOpts, AddOpts, RemoveOpts, TestOpts, BuildOpts, InitOpts,
    RunOpts, FormatOpts, HealthOpts, DuplicationOpts, RepairOpts,
    AgentsOpts : TOptionArray;
begin
  if HandleTopLevelFlags then
  begin
    ExitCode := 0;
    Exit;
  end;

  Registry := TSubcommandRegistry.Create;
  try
    Registry.OnCommandCompleted := @ReportCommandCompletion;

    SetLength(InstallOpts, 1);
    InstallOpts[0] := TFlagOption.Create('frozen',
      'CI mode: refuse to update the lockfile, refuse network, verify hashes');
    Registry.Add(TSubcommand.Create('install',
      'Resolve and fetch dependencies', '[--frozen]',
      @HandleInstall, InstallOpts));

    SetLength(AddOpts, 1);
    AddOpts[0] := TStringOption.Create('name',
      'Dependency name in the manifest (default: the source''s last path segment)');
    Registry.Add(TSubcommand.Create('add',
      'Add a dependency to the manifest and install it',
      '<source[@version]> [--name <name>]',
      @HandleAdd, AddOpts));

    SetLength(RemoveOpts, 0);
    Registry.Add(TSubcommand.Create('remove',
      'Remove dependencies from the manifest and prune their modules',
      '<name> [<name>...]',
      @HandleRemove, RemoveOpts));

    SetLength(BuildOpts, 4);
    BuildOpts[0] := TStringOption.Create('mode',
      'Build mode: dev (default) or release');
    BuildOpts[1] := TFlagOption.Create('clean',
      'Force a full rebuild in fresh private staging');
    BuildOpts[2] := TIntegerOption.Create('jobs',
      'Maximum concurrent build entries (default: machine budget)');
    BuildOpts[3] := TFlagOption.Create('verbose',
      'Replay successful build-entry logs');
    Registry.Add(TSubcommand.Create('build',
      'Compile manifest build entries',
      '[entry...] [--mode dev|release] [--clean] [--jobs N] [--verbose]',
      @HandleBuild, BuildOpts));

    SetLength(FormatOpts, 1);
    FormatOpts[0] := TFlagOption.Create('check',
      'Report files needing formatting without rewriting; exit 1 if any');
    Registry.Add(TSubcommand.Create('format',
      'Format uses-clauses and identifiers', '[--check]',
      @HandleFormat, FormatOpts));

    SetLength(DuplicationOpts, 1);
    DuplicationOpts[0] := TFlagOption.Create('json',
      'Emit the deterministic machine-readable analysis envelope');
    Registry.Add(TSubcommand.Create('duplication',
      'Report manifest-scoped Pascal token clones', '[--json]',
      @HandleDuplication, DuplicationOpts));

    SetLength(TestOpts, 4);
    TestOpts[0] := TStringOption.Create('tier',
      'Test tier to include: default (unit + integration) or e2e (adds network-touching tier)');
    TestOpts[1] := TIntegerOption.Create('jobs',
      'Maximum concurrent test programs (default: shared machine budget)');
    TestOpts[2] := TIntegerOption.Create('bail',
      'Stop after N compile or runtime failures; 0 runs the full queue');
    TestOpts[3] := TFlagOption.Create('verbose',
      'Replay successful test logs');
    Registry.Add(TSubcommand.Create('test',
      'Discover and run *.Test.pas files',
      '[--tier default|e2e] [--jobs N] [--bail N] [--verbose]',
      @HandleTest, TestOpts));

    SetLength(RepairOpts, 0);
    Registry.Add(TSubcommand.Create('repair',
      'Reclaim install, build-session, and worker-lease residue', '',
      @HandleRepair, RepairOpts));

    SetLength(InitOpts, 3);
    InitOpts[0] := TFlagOption.Create('yes',
      'Skip prompts and use defaults derived from the directory name');
    InitOpts[1] := TFlagOption.Create('force',
      'Overwrite an existing lwpt.toml without asking');
    InitOpts[2] := TFlagOption.Create('adopt',
      'Fill in missing scaffold around an existing manifest without modifying it');
    Registry.Add(TSubcommand.Create('init',
      'Scaffold a new LWPT project or adopt an existing manifest',
      '[--yes] [--force] [--adopt]',
      @HandleInit, InitOpts));

    SetLength(RunOpts, 0);
    Registry.Add(TSubcommand.Create('run',
      'Invoke a user-declared run-script (or a built-in subcommand by name)',
      '<script-name> | <subcommand> [subcommand-args...]',
      @HandleRun, RunOpts));

    SetLength(HealthOpts, 2);
    HealthOpts[0] := TFlagOption.Create('json',
      'Write the deterministic machine-readable report');
    HealthOpts[1] := TFlagOption.Create('hotspots',
      'Enrich complexity with the latest 100 commits of local Git churn');
    Registry.Add(TSubcommand.Create('health',
      'Report Pascal complexity and optional Git hotspots',
      '[--json] [--hotspots]', @HandleHealth, HealthOpts));

    SetLength(AgentsOpts, 1);
    AgentsOpts[0] := TFlagOption.Create('check',
      'Verify the AGENTS.md block matches the current command surface; exit 1 when stale');
    Registry.Add(TSubcommand.Create('agents',
      'Write or verify the agent-facing command reference in AGENTS.md',
      '[--check]',
      @HandleAgents, AgentsOpts));

    ExitCode := Registry.Run(PROGRAM_NAME);
  finally
    Registry.Free;
  end;
end.
