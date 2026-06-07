{ LWPT — lightweight Pascal toolkit.

  One executable, seven subcommands sharing a common core (manifest,
  TOML, resolver, cfg emitter):
    init      scaffold a new project (manifest + source dir + sample entry)
    install   resolve + fetch dependencies, write lwpt.lock + lwpt.cfg
    build     compile manifest [build] entries
    format    format uses-clauses and identifiers (--check to verify only)
    test      discover + compile + run *.Test.pas files
    repair    clean .lwpt/tmp/ + stale install lock; recover from crash
    run       invoke a user-declared run-script (or alias a subcommand)

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
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  LWPT.Command.Build,
  LWPT.Command.Format,
  LWPT.Command.Init,
  LWPT.Command.Install,
  LWPT.Command.Repair,
  LWPT.Command.Run,
  LWPT.Command.Testing,
  LWPT.Core;

function ErrPrefix(const ASubcommand: string): string; inline;
begin
  Result := PROGRAM_NAME + ' ' + ASubcommand + ': ';
end;

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

{ --- build -------------------------------------------------------------- }
function HandleBuild(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Release, Clean : Boolean;
  TargetName, ModeVal : string;
  i : Integer;
begin
  Release := False;          { dev is the default }
  Clean   := False;
  for i := 0 to High(AOptions) do
  begin
    if SameText(AOptions[i].LongName, 'clean') and AOptions[i].Present then
      Clean := True;
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
  end;
  TargetName := '';
  if APositionals.Count > 0 then
    TargetName := APositionals[0];
  try
    Result := CmdBuild(MANIFEST_FILE, TargetName, Release, Clean);
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

{ --- test --------------------------------------------------------------- }
function HandleTest(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  IncludeE2E : Boolean;
  TierVal : string;
  i : Integer;
begin
  IncludeE2E := False;
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
    end;
  try
    Result := CmdTest(MANIFEST_FILE, IncludeE2E);
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
  Yes, Force : Boolean;
  i : Integer;
begin
  Yes := False;
  Force := False;
  for i := 0 to High(AOptions) do
  begin
    if (SameText(AOptions[i].LongName, 'yes')
        or SameText(AOptions[i].ShortName, 'y'))
       and AOptions[i].Present then Yes := True;
    if SameText(AOptions[i].LongName, 'force')
       and AOptions[i].Present then Force := True;
  end;
  try
    CmdInit(Yes, Force);
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
begin
  { Subcommand-aliasing (`lwpt run install`) is intercepted in
    CLI.Subcommands.Run BEFORE this handler is called. So when we
    arrive here, the name (if any) is always a user-declared script
    name — never a subcommand. Empty positionals = list mode. }
  if APositionals.Count = 0 then
    Name := ''
  else
    Name := APositionals[0];
  try
    Result := CmdRun(MANIFEST_FILE, Name);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, ErrPrefix('run'), E.Message);
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
  Registry : TSubcommandRegistry;
  InstallOpts, TestOpts, BuildOpts, InitOpts, RunOpts,
    FormatOpts, RepairOpts : TOptionArray;
begin
  if HandleTopLevelFlags then
  begin
    ExitCode := 0;
    Exit;
  end;

  Registry := TSubcommandRegistry.Create;
  try
    SetLength(InstallOpts, 1);
    InstallOpts[0] := TFlagOption.Create('frozen',
      'CI mode: refuse to update the lockfile, refuse network, verify hashes');
    Registry.Add(TSubcommand.Create('install',
      'Resolve and fetch dependencies', '[--frozen]',
      @HandleInstall, InstallOpts));

    SetLength(BuildOpts, 2);
    BuildOpts[0] := TStringOption.Create('mode',
      'Build mode: dev (default) or release');
    BuildOpts[1] := TFlagOption.Create('clean',
      'Remove prior build artefacts and force a full rebuild');
    Registry.Add(TSubcommand.Create('build',
      'Compile manifest targets', '[target] [--mode dev|release] [--clean]',
      @HandleBuild, BuildOpts));

    SetLength(FormatOpts, 1);
    FormatOpts[0] := TFlagOption.Create('check',
      'Report files needing formatting without rewriting; exit 1 if any');
    Registry.Add(TSubcommand.Create('format',
      'Format uses-clauses and identifiers', '[--check]',
      @HandleFormat, FormatOpts));

    SetLength(TestOpts, 1);
    TestOpts[0] := TStringOption.Create('tier',
      'Test tier to include: default (unit + integration) or e2e (adds network-touching tier)');
    Registry.Add(TSubcommand.Create('test',
      'Discover and run *.Test.pas files', '[--tier default|e2e]',
      @HandleTest, TestOpts));

    SetLength(RepairOpts, 0);
    Registry.Add(TSubcommand.Create('repair',
      'Clean .lwpt/tmp/ and stale install lock; recover from crash', '',
      @HandleRepair, RepairOpts));

    SetLength(InitOpts, 2);
    InitOpts[0] := TFlagOption.Create('yes',
      'Skip prompts and use defaults derived from the directory name');
    InitOpts[1] := TFlagOption.Create('force',
      'Overwrite an existing lwpt.toml without asking');
    Registry.Add(TSubcommand.Create('init',
      'Scaffold a new LWPT project (manifest + source dir + sample entry; optionally runs install + build)',
      '[--yes] [--force]',
      @HandleInit, InitOpts));

    SetLength(RunOpts, 0);
    Registry.Add(TSubcommand.Create('run',
      'Invoke a user-declared run-script (or a built-in subcommand by name)',
      '<script-name> | <subcommand> [subcommand-args...]',
      @HandleRun, RunOpts));

    ExitCode := Registry.Run(PROGRAM_NAME);
  finally
    Registry.Free;
  end;
end.
