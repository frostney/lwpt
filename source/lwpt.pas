{ LWPT — lightweight Pascal toolkit.

  One executable, fifteen command families sharing a common core (manifest,
  TOML, resolver, cfg emitter):
    init      scaffold a new project or adopt an existing manifest
    install   resolve + fetch dependencies, write lwpt.lock + lwpt.cfg
    add       add a dependency to lwpt.toml + install it (ADR-0019)
    remove    remove dependencies from lwpt.toml + prune their modules
    outdated  compare locked git-host deps to advertised tags (ADR-0039)
    update    bump constraints + reinstall newer git-host deps (ADR-0039)
    build     compile manifest [build] entries
    format    format uses-clauses and identifiers (--check to verify only)
    duplication report manifest-scoped Type-2 Pascal token clones
    test      discover + compile + run *.Test.pas files
    repair    recover project and shared-cache residue
    run       invoke a user-declared run task (or alias a subcommand)
    health    report Pascal complexity and optional Git hotspots
    agents    write/verify the agent-facing command reference in
              AGENTS.md (ADR-0027)
    registry  initialize or serve a self-hosted origin (ADR-0043)

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
  LWPT.Command.Outdated,
  LWPT.Command.Remove,
  LWPT.Command.Registry,
  LWPT.Command.Update,
  LWPT.Command.Repair,
  LWPT.Command.Run,
  LWPT.Command.Testing,
  LWPT.Core,
  LWPT.OutputRenderer,
  LWPT.ProcessTree,
  LWPT.Registry.Store;

const
  MILLISECONDS_PER_CENTISECOND = 10;
  CENTISECONDS_PER_SECOND = 100;

var
  OutputRenderer : TLWPTOutputRenderer;

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
  WasSilent : Boolean;
begin
  WasSilent := Assigned(OutputRenderer) and OutputRenderer.Capturing;
  if WasSilent then
    OutputRenderer.FinishSilent(ACompletion.ExitCode,
      ACompletion.ElapsedMilliseconds);
  Flush(Output);
  if ACompletion.ExitCode = 0 then
    StatusText := 'completed in '
  else
    StatusText := 'failed after ';
  if (ACompletion.ExitCode = 0) and WasSilent then
    WriteLn(Output, PROGRAM_NAME, ' ', ACompletion.CommandName, ': ',
      StatusText, FormatElapsedMilliseconds(ACompletion.ElapsedMilliseconds))
  else
    WriteLn(ErrOutput, PROGRAM_NAME, ' ', ACompletion.CommandName, ': ',
      StatusText, FormatElapsedMilliseconds(ACompletion.ElapsedMilliseconds));
end;

function ErrPrefix(const ASubcommand: string): string; inline;
begin
  Result := PROGRAM_NAME + ' ' + ASubcommand + ': ';
end;

function RejectUnexpectedPositionals(const ASubcommand: string;
  const APositionals: TStrings): Boolean;
begin
  Result := APositionals.Count > 0;
  if Result then
    WriteLn(ErrOutput, ErrPrefix(ASubcommand), 'unexpected argument "',
      APositionals[0], '" (', ASubcommand,
      ' takes no positional arguments)');
end;

{ Declared ahead of the handlers because HandleAgents renders the
  command surface from the live registry itself — the registry is the
  single source of truth for both `--help` and the agents block. }
var
  Registry : TSubcommandRegistry;

function PrepareCommandOutput(const ACommandName: string;
  const AOptions: TOptionArray): string;
var
  HasAdopt, HasSilent, HasVerbose, HasYes: Boolean;
  OptionIndex: Integer;
begin
  Result := '';
  HasSilent := False;
  HasVerbose := False;
  HasYes := False;
  HasAdopt := False;
  for OptionIndex := 0 to High(AOptions) do
    if AOptions[OptionIndex].Present then
      if SameText(AOptions[OptionIndex].LongName, 'silent') then
        HasSilent := True
      else if SameText(AOptions[OptionIndex].LongName, 'verbose') then
        HasVerbose := True
      else if SameText(AOptions[OptionIndex].LongName, 'yes') then
        HasYes := True
      else if SameText(AOptions[OptionIndex].LongName, 'adopt') then
        HasAdopt := True;
  if HasSilent and HasVerbose then
    Exit('--silent cannot be combined with --verbose');
  if not HasSilent then Exit;
  if SameText(ACommandName, 'init') and not (HasYes or HasAdopt) then
    Exit('--silent requires --yes or --adopt for non-interactive init');
  try
    OutputRenderer.BeginSilent(ACommandName);
  except
    on E: Exception do
      Result := 'cannot start silent mode: ' + E.Message;
  end;
end;

{ --- install ------------------------------------------------------------- }
function HandleInstall(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Frozen : Boolean;
  i : Integer;
begin
  if RejectUnexpectedPositionals('install', APositionals) then Exit(1);
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
  Release, Clean, JobsPresent, UseCache, Verbose : Boolean;
  Jobs : Integer;
  ModeVal : string;
  EntryNames : array of string;
  i : Integer;
begin
  Release := False;          { dev is the default }
  Clean   := False;
  Jobs    := 0;              { auto: bounded by graph + machine budget }
  JobsPresent := False;
  UseCache := True;
  Verbose := False;
  for i := 0 to High(AOptions) do
  begin
    if SameText(AOptions[i].LongName, 'clean') and AOptions[i].Present then
      Clean := True;
    if SameText(AOptions[i].LongName, 'verbose')
       and AOptions[i].Present then
      Verbose := True;
    if SameText(AOptions[i].LongName, 'no-cache')
       and AOptions[i].Present then
      UseCache := False;
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
      Verbose, UseCache, nil);
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
  if RejectUnexpectedPositionals('format', APositionals) then Exit(1);
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
  Inventory, UseCache, Verbose : Boolean;
  Jobs, Bail, i : Integer;
begin
  Inventory := False;
  UseCache := True;
  Verbose := False;
  Jobs := 0;
  Bail := -1;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'verbose')
       and AOptions[i].Present then
      Verbose := True
    else if SameText(AOptions[i].LongName, 'inventory')
       and AOptions[i].Present then
      Inventory := True
    else if SameText(AOptions[i].LongName, 'no-cache')
       and AOptions[i].Present then
      UseCache := False
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
    Result := CmdTest(MANIFEST_FILE, Jobs, Bail, Verbose, Inventory,
      APositionals, UseCache);
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
  if RejectUnexpectedPositionals('repair', APositionals) then Exit(1);
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

{ --- registry ---------------------------------------------------------- }
function HandleRegistry(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  BaseURL, DataDirectory, Identity, ListenAddress, TLSPKCS12,
    TLSPasswordEnvironment: string;
  Index, Port: Integer;
  ServeConfigurationPresent: Boolean;
begin
  if APositionals.Count <> 1 then
  begin
    WriteLn(ErrOutput, ErrPrefix('registry'),
      'expected exactly one operation: init or serve');
    Exit(1);
  end;
  DataDirectory := REGISTRY_DEFAULT_DATA_DIR;
  Identity := '';
  BaseURL := REGISTRY_DEFAULT_BASE_URL;
  ListenAddress := REGISTRY_DEFAULT_LISTEN_ADDRESS;
  Port := REGISTRY_DEFAULT_PORT;
  TLSPKCS12 := '';
  TLSPasswordEnvironment := '';
  ServeConfigurationPresent := False;
  for Index := 0 to High(AOptions) do
  begin
    if AOptions[Index].Present
      and not SameText(AOptions[Index].LongName, 'data-dir')
      and not SameText(AOptions[Index].LongName, 'silent') then
      ServeConfigurationPresent := True;
    if AOptions[Index] is TStringOption then
    begin
      if SameText(AOptions[Index].LongName, 'data-dir') then
        DataDirectory := TStringOption(AOptions[Index]).ValueOr(DataDirectory)
      else if SameText(AOptions[Index].LongName, 'identity') then
        Identity := TStringOption(AOptions[Index]).ValueOr(Identity)
      else if SameText(AOptions[Index].LongName, 'base-url') then
        BaseURL := TStringOption(AOptions[Index]).ValueOr(BaseURL)
      else if SameText(AOptions[Index].LongName, 'listen') then
        ListenAddress := TStringOption(AOptions[Index]).ValueOr(ListenAddress)
      else if SameText(AOptions[Index].LongName, 'tls-pkcs12') then
        TLSPKCS12 := TStringOption(AOptions[Index]).ValueOr(TLSPKCS12)
      else if SameText(AOptions[Index].LongName, 'tls-password-env') then
        TLSPasswordEnvironment := TStringOption(AOptions[Index]).ValueOr(
          TLSPasswordEnvironment);
    end
    else if SameText(AOptions[Index].LongName, 'port') then
      Port := TIntegerOption(AOptions[Index]).ValueOr(Port);
  end;
  try
    if SameText(APositionals[0], 'init') then
      Result := CmdRegistryInit(DataDirectory, Identity, BaseURL,
        ListenAddress, Port, TLSPKCS12, TLSPasswordEnvironment)
    else if SameText(APositionals[0], 'serve') then
    begin
      if ServeConfigurationPresent then
      begin
        WriteLn(ErrOutput, ErrPrefix('registry'),
          'serve accepts only --data-dir; change persisted configuration with init');
        Exit(1);
      end;
      Result := CmdRegistryServe(DataDirectory);
    end
    else
    begin
      WriteLn(ErrOutput, ErrPrefix('registry'), 'unknown operation "',
        APositionals[0], '"; expected init or serve');
      Result := 1;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('registry'), E.Message);
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
  if RejectUnexpectedPositionals('init', APositionals) then Exit(1);
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
    arrive here, the name (if any) is always a user-declared run task
    name — never a subcommand. Empty positionals = list mode. }
  if APositionals.Count = 0 then
    Name := ''
  else
    Name := APositionals[0];
  if APositionals.Count > 1 then
  begin
    WriteLn(ErrOutput, ErrPrefix('run'),
      'run tasks do not accept invocation-time arguments; declare args in ',
      MANIFEST_FILE);
    Exit(1);
  end;
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


{ --- outdated (ADR-0039) ------------------------------------------------- }
function HandleOutdated(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  JSON: Boolean;
  i: Integer;
begin
  if RejectUnexpectedPositionals('outdated', APositionals) then Exit(1);
  JSON := False;
  for i := 0 to High(AOptions) do
    if SameText(AOptions[i].LongName, 'json') and AOptions[i].Present then
      JSON := True;
  try
    Result := CmdOutdated(MANIFEST_FILE, JSON);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('outdated'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- update (ADR-0039) --------------------------------------------------- }
function HandleUpdate(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Names: array of string;
  i: Integer;
begin
  SetLength(Names, APositionals.Count);
  for i := 0 to APositionals.Count - 1 do
    Names[i] := APositionals[i];
  try
    CmdUpdate(MANIFEST_FILE, Names);
    Result := 0;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('update'), E.Message);
      Result := 1;
    end;
  end;
end;

{ --- top-level flags ----------------------------------------------------- }
function HandleTopLevelFlags: Boolean;
var
  A : string;
begin
  Result := False;
  if ParamCount > 0 then
  begin
    A := ParamStr(1);
    if (A = '--version') or (A = '-v') or (LowerCase(A) = 'version') then
    begin
      WriteLn(PROGRAM_NAME, ' ', PROGRAM_VERSION);
      Result := True;
    end;
  end;
end;

{ --- registration -------------------------------------------------------- }
var
  InstallOpts, AddOpts, RemoveOpts, OutdatedOpts, UpdateOpts, TestOpts,
    BuildOpts, InitOpts, RunOpts, FormatOpts, HealthOpts, DuplicationOpts,
    RepairOpts, RegistryOpts, AgentsOpts : TOptionArray;
begin
  if HandleTopLevelFlags then
  begin
    ExitCode := 0;
    Exit;
  end;

  Registry := TSubcommandRegistry.Create;
  OutputRenderer := TLWPTOutputRenderer.Create;
  SetActiveOutputRenderer(OutputRenderer);
  try
    Registry.AddSharedFlag('silent',
      'Suppress ordinary output and emit only the final command result');
    Registry.OnCommandPrepared := @PrepareCommandOutput;
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


    SetLength(OutdatedOpts, 1);
    OutdatedOpts[0] := TFlagOption.Create('json',
      'Emit a machine-readable report of each compared dependency');
    Registry.Add(TSubcommand.Create('outdated',
      'Compare locked git-host dependencies to advertised tags',
      '[--json]',
      @HandleOutdated, OutdatedOpts));

    SetLength(UpdateOpts, 0);
    Registry.Add(TSubcommand.Create('update',
      'Bump constraints and reinstall newer git-host dependencies',
      '[name ...]',
      @HandleUpdate, UpdateOpts));

    SetLength(BuildOpts, 5);
    BuildOpts[0] := TStringOption.Create('mode',
      'Build mode: dev (default) or release');
    BuildOpts[1] := TFlagOption.Create('clean',
      'Force a full rebuild in fresh private staging');
    BuildOpts[2] := TIntegerOption.Create('jobs',
      'Maximum concurrent build entries (default: machine budget)');
    BuildOpts[3] := TFlagOption.Create('verbose',
      'Replay successful build-entry logs');
    BuildOpts[4] := TFlagOption.Create('no-cache',
      'Compile without reading or writing reusable build results');
    Registry.Add(TSubcommand.Create('build',
      'Compile manifest build entries',
      '[entry...] [--mode dev|release] [--clean] [--jobs N] [--verbose] '
        + '[--no-cache]',
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

    SetLength(TestOpts, 5);
    TestOpts[0] := TIntegerOption.Create('jobs',
      'Maximum concurrent test programs (default: shared machine budget)');
    TestOpts[1] := TIntegerOption.Create('bail',
      'Stop after N compile or runtime failures; 0 runs the full queue');
    TestOpts[2] := TFlagOption.Create('verbose',
      'Replay successful test logs');
    TestOpts[3] := TFlagOption.Create('inventory',
      'Emit registered suites and cases as deterministic JSON without running tests');
    TestOpts[4] := TFlagOption.Create('no-cache',
      'Compile without reading or writing reusable test executables');
    Registry.Add(TSubcommand.Create('test',
      'Discover and run *.Test.pas files',
      '[selector...] [--jobs N] [--bail N] [--verbose] '
        + '[--inventory] [--no-cache]',
      @HandleTest, TestOpts));

    SetLength(RepairOpts, 0);
    Registry.Add(TSubcommand.Create('repair',
      'Recover project and shared-cache residue', '',
      @HandleRepair, RepairOpts));

    SetLength(RegistryOpts, 7);
    RegistryOpts[0] := TStringOption.Create('data-dir',
      'Origin data directory (default: ' + REGISTRY_DEFAULT_DATA_DIR + ')');
    RegistryOpts[1] := TStringOption.Create('identity',
      'Stable canonical HTTPS origin identity (init only)');
    RegistryOpts[2] := TStringOption.Create('base-url',
      'Canonical public base URL (init only; default: http://localhost:8080)');
    RegistryOpts[3] := TStringOption.Create('listen',
      'Listen address (init only; default: localhost)');
    RegistryOpts[4] := TIntegerOption.Create('port',
      'Listen port (init only; default: 8080)');
    RegistryOpts[5] := TStringOption.Create('tls-pkcs12',
      'PKCS#12 identity path required by HTTPS (init only)');
    RegistryOpts[6] := TStringOption.Create('tls-password-env',
      'Environment variable containing the PKCS#12 password (init only)');
    Registry.Add(TSubcommand.Create('registry',
      'Initialize or serve a self-hosted registry origin',
      '<init|serve> [--data-dir <path>] [configuration options]',
      @HandleRegistry, RegistryOpts));

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
      'Invoke a user-declared run task (or a built-in subcommand by name)',
      '<task-name> | <subcommand> [subcommand-args...]',
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
    SetActiveOutputRenderer(nil);
    OutputRenderer.Free;
    Registry.Free;
  end;
end.
