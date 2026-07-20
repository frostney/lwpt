{ CLI.Subcommands — subcommand dispatch on top of CLI.Parser /
  CLI.Options.

  The parser ships option handling for ONE program. LWPT has several
  subcommands (install, build, test, format, repair, init, run),
  each with its own option set. This unit is the generalisation: a
  registry of named subcommands, each carrying a handler and its own
  TOptionArray. Run reads argv[1] as the subcommand name, then hands
  argv[2..] to that subcommand's options via the existing
  ParseCommandLine.

  Lives under the CLI namespace (no LWPT prefix) so it can graduate
  into a standalone package alongside CLI.Options / CLI.Parser /
  CLI.Prompts once the LWPT bootstrap arc lets us replace vendoring
  with a managed dep (see ADR-0006). }
unit CLI.Subcommands;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  CLI.Options;

type
  { A subcommand handler receives the positional args (after the subcommand
    name) and its already-parsed option objects. Returns a process exit code. }
  TSubcommandHandler = function(const APositionals: TStringList;
    const AOptions: TOptionArray): Integer;

  TSubcommand = class
  public
    Name     : string;
    Summary  : string;            { one-line description for top-level help }
    UsageArg : string;            { e.g. '[--offline]' shown after the name }
    Handler  : TSubcommandHandler;
    Options  : TOptionArray;
    constructor Create(const AName, ASummary, AUsageArg: string;
      AHandler: TSubcommandHandler; const AOptions: TOptionArray);
  end;

  TSubcommandRegistry = class
  private
    FItems : array of TSubcommand;
  public
    destructor Destroy; override;
    procedure Add(ASub: TSubcommand);
    function Find(const AName: string): TSubcommand;
    { Read iteration over the registered subcommands, in registration
      order. The registry is the single source of truth for the
      program's command surface; consumers that render that surface
      (help printers here, agent-facing reference generators in the
      host program) iterate it rather than keeping their own list. }
    function Count: Integer;
    function Item(AIndex: Integer): TSubcommand;
    procedure PrintTopLevelHelp(const AProgramName: string);
    procedure PrintSubcommandHelp(const AProgramName: string;
      ASub: TSubcommand);
    { Run argv. Returns the process exit code. }
    function Run(const AProgramName: string): Integer;
  end;

implementation

uses
  CLI.Parser;

constructor TSubcommand.Create(const AName, ASummary, AUsageArg: string;
  AHandler: TSubcommandHandler; const AOptions: TOptionArray);
begin
  Name     := AName;
  Summary  := ASummary;
  UsageArg := AUsageArg;
  Handler  := AHandler;
  Options  := AOptions;
end;

destructor TSubcommandRegistry.Destroy;
var i, j: Integer;
begin
  for i := 0 to High(FItems) do
  begin
    for j := 0 to High(FItems[i].Options) do
      FItems[i].Options[j].Free;
    FItems[i].Free;
  end;
  inherited Destroy;
end;

procedure TSubcommandRegistry.Add(ASub: TSubcommand);
begin
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := ASub;
end;

function TSubcommandRegistry.Find(const AName: string): TSubcommand;
var i: Integer;
begin
  Result := nil;
  for i := 0 to High(FItems) do
    if SameText(FItems[i].Name, AName) then
      Exit(FItems[i]);
end;

function TSubcommandRegistry.Count: Integer;
begin
  Result := Length(FItems);
end;

function TSubcommandRegistry.Item(AIndex: Integer): TSubcommand;
begin
  { Explicit bounds guard: production builds compile with range checks
    off (Shared.inc), so relying on compiler checking would let an
    out-of-range index return a garbage pointer instead of failing. }
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EArgumentOutOfRangeException.CreateFmt(
      'subcommand index %d out of range 0..%d', [AIndex, High(FItems)]);
  Result := FItems[AIndex];
end;

procedure TSubcommandRegistry.PrintTopLevelHelp(const AProgramName: string);
var i: Integer;
begin
  WriteLn(AProgramName, ' — lightweight Pascal toolkit');
  WriteLn;
  WriteLn('usage: ', AProgramName, ' <command> [options]');
  WriteLn;
  WriteLn('commands:');
  for i := 0 to High(FItems) do
    WriteLn('  ', FItems[i].Name:10, '  ', FItems[i].Summary);
  WriteLn;
  WriteLn('run "', AProgramName, ' <command> --help" for command options');
end;

procedure TSubcommandRegistry.PrintSubcommandHelp(const AProgramName: string;
  ASub: TSubcommand);
var
  i, MaxOptWidth, W: Integer;
  OptName: string;
begin
  WriteLn(AProgramName, ' ', ASub.Name, ' — ', ASub.Summary);
  WriteLn;
  Write('usage: ', AProgramName, ' ', ASub.Name);
  if ASub.UsageArg <> '' then
    Write(' ', ASub.UsageArg);
  WriteLn;

  if Length(ASub.Options) = 0 then Exit;

  WriteLn;
  WriteLn('options:');

  { compute max option-token width for aligned descriptions.
    FormatForHelp (not the bare long name) so valued options show
    their value shape (--name=<value>, --name=<N>, --name=a|b) and
    every surface rendered from the registry — this help text and the
    host program's agents block — stays identical by construction. }
  MaxOptWidth := 0;
  for i := 0 to High(ASub.Options) do
  begin
    W := Length(ASub.Options[i].FormatForHelp);
    if W > MaxOptWidth then MaxOptWidth := W;
  end;

  for i := 0 to High(ASub.Options) do
  begin
    OptName := ASub.Options[i].FormatForHelp;
    Write('  ', OptName);
    for W := Length(OptName) to MaxOptWidth do Write(' ');
    WriteLn('  ', ASub.Options[i].HelpText);
  end;
end;

{ Walk the real argv (positions 2..) looking for --help / -h / help.
  Done as a separate scan because ParseCommandLine would reject --help
  as "Unknown option" before we can intercept it. }
function WantsHelp: Boolean;
var i: Integer; A: string;
begin
  for i := 2 to ParamCount do
  begin
    A := ParamStr(i);
    if (A = '--help') or (A = '-h') or (LowerCase(A) = 'help') then
      Exit(True);
  end;
  Result := False;
end;

function TSubcommandRegistry.Run(const AProgramName: string): Integer;
var
  CmdName : string;
  Sub, AliasSub : TSubcommand;
  Positionals : TStringList;
  ParseStart : Integer;
begin
  if ParamCount < 1 then
  begin
    PrintTopLevelHelp(AProgramName);
    Exit(0);
  end;

  CmdName := LowerCase(ParamStr(1));
  if (CmdName = 'help') or (CmdName = '--help') or (CmdName = '-h') then
  begin
    PrintTopLevelHelp(AProgramName);
    Exit(0);
  end;

  Sub := Find(CmdName);
  if Sub = nil then
  begin
    WriteLn(ErrOutput, 'unknown command: ', CmdName);
    PrintTopLevelHelp(AProgramName);
    Exit(1);
  end;

  { `lwpt run <subcommand>` subcommand-aliasing (ADR-0013). If the
    second positional is a registered subcommand, dispatch to THAT
    subcommand directly with its args starting at argv[3]. The run
    handler never sees this case — it only fires for user-defined
    run-scripts (which are forbidden from shadowing subcommand names
    by the manifest-load guard, so there's no ambiguity here). }
  ParseStart := 1;
  if (CmdName = 'run') and (ParamCount >= 2) then
  begin
    AliasSub := Find(LowerCase(ParamStr(2)));
    if AliasSub <> nil then
    begin
      Sub := AliasSub;
      ParseStart := 2;
      CmdName := LowerCase(ParamStr(2));
    end;
  end;

  { Intercept per-subcommand --help / -h before ParseCommandLine sees
    them and reports "Unknown option". }
  if WantsHelp then
  begin
    PrintSubcommandHelp(AProgramName, Sub);
    Exit(0);
  end;

  { ParseCommandLine reads the real argv. We need it to see only argv[2..]
    for normal dispatch, or argv[3..] for `lwpt run <subcmd>` aliasing.
    The AStartArg parameter (added to CLI.Parser for this) gates that. }
  try
    Positionals := ParseCommandLine(Sub.Options, ParseStart);
  except
    on E: TParseError do
    begin
      WriteLn(ErrOutput, AProgramName, ' ', CmdName, ': ', E.Message);
      Exit(1);
    end;
  end;

  try
    { drop the leading positional (the subcommand name itself) }
    if (Positionals.Count > 0)
       and SameText(Positionals[0], CmdName) then
      Positionals.Delete(0);
    Result := Sub.Handler(Positionals, Sub.Options);
  finally
    Positionals.Free;
  end;
end;

end.
