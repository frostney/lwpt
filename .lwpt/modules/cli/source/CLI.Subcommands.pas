{ CLI.Subcommands — subcommand dispatch on top of CLI.Parser /
  CLI.Options.

  The parser ships option handling for ONE program. LWPT has several
  subcommands (install, build, test, format, repair, init, run),
  each with its own option set. This unit is the generalisation: a
  registry of named subcommands, each carrying a handler and its own
  TOptionArray. Run reads the first argument as the subcommand name, then
  hands the rest to that subcommand's options via CLI.Parser.

  The registry carries no host's identity or policy. A host sets its own
  description, top-level flags such as `--version`, usage-error exit code
  and bare-invocation behaviour, and opts individual subcommands in to
  subcommand aliasing or argument pass-through.

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

const
  { The exit code of a usage error unless the host sets another one: the
    code a failing handler conventionally returns. }
  DEFAULT_USAGE_EXIT_CODE = 1;

type
  { A subcommand handler receives the positional args (after the subcommand
    name) and its already-parsed option objects. Returns a process exit code. }
  TSubcommandHandler = function(const APositionals: TStringList;
    const AOptions: TOptionArray): Integer;

  { A top-level flag handler runs instead of a command. Returns a process
    exit code. }
  TTopLevelFlagHandler = function: Integer;

  { What Run does when the program is given no arguments at all. }
  TBareInvocation = (
    biShowHelp,     { top-level help on standard output, exit code 0 }
    biUsageError);  { a usage error, reported like an unknown command }

  { Neutral dispatch metadata for hosts that need completion reporting.
    The CLI package owns measurement and resolved command identity; the host
    decides whether and how to present the result. Completion callbacks are
    best-effort observers and cannot replace the command's dispatch result. }
  TSubcommandCompletion = record
    CommandName: string;
    ExitCode: Integer;
    ElapsedMilliseconds: QWord;
  end;
  TSubcommandCompletionHandler = procedure(
    const ACompletion: TSubcommandCompletion);

  { Neutral host hook after option parsing and alias resolution but before the
    handler runs. Returning a non-empty message rejects dispatch as a command
    usage error. Hosts may also install invocation-scoped observers here; the
    CLI package remains unaware of their output policy. }
  TSubcommandPreparedHandler = function(const ACommandName: string;
    const AOptions: TOptionArray): string;

  TSubcommandSharedFlag = record
    LongName: string;
    HelpText: string;
  end;

  TSubcommand = class
  private
    { Length of the shared-flag usage that leads UsageArg (PassThrough). }
    FSharedUsageLength : Integer;
  public
    Name     : string;
    Summary  : string;            { one-line description for top-level help }
    UsageArg : string;            { e.g. '[--offline]' shown after the name }
    Handler  : TSubcommandHandler;
    Options  : TOptionArray;
    { When True, `<program> <Name> <subcommand> [arguments]` dispatches
      <subcommand> with those arguments instead of this command. Only the
      argument directly after <Name> is looked up, so an option or `--`
      in that place keeps the line with this command. }
    AliasesSubcommands : Boolean;
    { When True, option parsing stops at the first positional: that
      argument and everything after it reach the handler untouched,
      including `--`, `--help`, `help` and options this command does not
      define. For a command that launches another program. Its own options
      and `--help` / `-h` are read before the first positional only. Set it
      before the command is added to a registry. }
    PassThrough : Boolean;
    constructor Create(const AName, ASummary, AUsageArg: string;
      AHandler: TSubcommandHandler; const AOptions: TOptionArray);
  end;

  { A flag the program accepts in place of a command, such as `--version`.
    It is matched against the first argument only, the way the built-in
    `--help` is; later arguments are ignored. Set its fields before it is
    added to a registry, which checks them once, on registration. }
  TTopLevelFlag = class
  public
    { Both names are given without their leading dashes. }
    LongName  : string;   { matched as --<LongName>, case-sensitively }
    ShortName : string;   { matched as -<ShortName> when not empty }
    { When True, <LongName> without dashes matches too, in any letter
      case, the way the built-in `help` word does. }
    BareWord  : Boolean;
    HelpText  : string;   { listed in top-level help; empty hides the flag }
    Handler   : TTopLevelFlagHandler;
    constructor Create(const ALongName, AHelpText: string;
      const AHandler: TTopLevelFlagHandler);
  end;

  TSubcommandRegistry = class
  private
    FItems : array of TSubcommand;
    FSharedFlags : array of TSubcommandSharedFlag;
    FTopLevelFlags : array of TTopLevelFlag;
    FDescription : string;
    FUsageExitCode : Integer;
    FUsageHelpToStandardError : Boolean;
    FBareInvocation : TBareInvocation;
    FStrictSingleDash : Boolean;
    FOnCommandCompleted : TSubcommandCompletionHandler;
    FOnCommandPrepared : TSubcommandPreparedHandler;
    function FindTopLevelFlag(const AArgument: string): TTopLevelFlag;
    function ReportUsageError(const AProgramName, AMessage: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddSharedFlag(const ALongName, AHelpText: string);
    procedure Add(ASub: TSubcommand);
    { Registers a top-level flag and takes ownership of it. Raises
      EArgumentException, leaving the registry unchanged and the flag with
      its caller, for an empty name, a name or short name that begins with
      a dash, a missing handler, a spelling the built-in help uses, a name
      or short name that is already registered, and a bare word that is
      also a subcommand name. }
    procedure AddTopLevelFlag(const AFlag: TTopLevelFlag);
    { Read iteration over the top-level flags, in registration order: the
      part of the command surface that Count and Item do not cover. }
    function TopLevelFlagCount: Integer;
    function TopLevelFlagItem(const AIndex: Integer): TTopLevelFlag;
    function Find(const AName: string): TSubcommand;
    { Read iteration over the registered subcommands, in registration
      order. The registry is the single source of truth for the
      program's command surface; consumers that render that surface
      (help printers here, agent-facing reference generators in the
      host program) iterate it rather than keeping their own list. }
    function Count: Integer;
    function Item(AIndex: Integer): TSubcommand;
    procedure PrintTopLevelHelp(const AProgramName: string); overload;
    procedure PrintTopLevelHelp(var AOutput: Text;
      const AProgramName: string); overload;
    procedure PrintSubcommandHelp(const AProgramName: string;
      ASub: TSubcommand);
    { Run the process's own arguments. Returns the process exit code. }
    function Run(const AProgramName: string): Integer; overload;
    { Run AArguments, the arguments after the program name. Reads nothing
      from the process's own command line. A dispatch applies options to
      the registered option objects, which keep that state: a second Run
      on the same registry starts from what the first one applied. }
    function Run(const AProgramName: string;
      const AArguments: array of string): Integer; overload;
    { Printed after the program name at the head of top-level help. When
      empty, that line is left out. }
    property Description: string read FDescription write FDescription;
    { Returned for a usage error: an unknown command, an option or value
      the parser rejects, a rejected preparation, and a bare invocation
      under biUsageError. A host that needs to tell a usage error from a
      failing handler sets a code its handlers do not return,
      conventionally 2. }
    property UsageExitCode: Integer read FUsageExitCode write FUsageExitCode;
    { When True, the top-level help that follows an unknown or missing
      command goes to standard error with the message, and standard output
      stays empty. When False it goes to standard output. }
    property UsageHelpToStandardError: Boolean
      read FUsageHelpToStandardError write FUsageHelpToStandardError;
    property BareInvocation: TBareInvocation
      read FBareInvocation write FBareInvocation;
    { When True, a single-dash argument read as an option that is neither a
      declared short option nor an opted-in attached short value is a usage
      error (`Unknown option: -verify`), whatever its length, instead of a
      positional. A negative number (`-5`, `-1.5`), a lone `-`, a value an
      option takes, everything after `--`, and everything from a
      pass-through command's first positional on are unaffected. False by
      default. }
    property StrictSingleDash: Boolean
      read FStrictSingleDash write FStrictSingleDash;
    property OnCommandCompleted: TSubcommandCompletionHandler
      read FOnCommandCompleted write FOnCommandCompleted;
    property OnCommandPrepared: TSubcommandPreparedHandler
      read FOnCommandPrepared write FOnCommandPrepared;
  end;

implementation

uses
  CLI.Parser;

const
  HELP_WORD = 'help';
  HELP_SHORT_NAME = 'h';
  HELP_LONG_FLAG = '--' + HELP_WORD;
  HELP_SHORT_FLAG = '-' + HELP_SHORT_NAME;

constructor TSubcommand.Create(const AName, ASummary, AUsageArg: string;
  AHandler: TSubcommandHandler; const AOptions: TOptionArray);
begin
  Name     := AName;
  Summary  := ASummary;
  UsageArg := AUsageArg;
  Handler  := AHandler;
  Options  := AOptions;
end;

constructor TTopLevelFlag.Create(const ALongName, AHelpText: string;
  const AHandler: TTopLevelFlagHandler);
begin
  LongName := ALongName;
  HelpText := AHelpText;
  Handler  := AHandler;
end;

{ Gives ASub its own instance of a shared flag and shows it in the usage
  line: after the command's own usage, or ahead of it for a pass-through
  command, which reads options before its first positional only. }
procedure AttachSharedFlag(const ASub: TSubcommand;
  const AFlag: TSubcommandSharedFlag);
var
  OptionIndex: Integer;
  Usage: string;
begin
  OptionIndex := Length(ASub.Options);
  SetLength(ASub.Options, OptionIndex + 1);
  ASub.Options[OptionIndex] := TFlagOption.Create(AFlag.LongName,
    AFlag.HelpText);
  Usage := '[--' + AFlag.LongName + ']';
  if not ASub.PassThrough then
  begin
    if ASub.UsageArg <> '' then ASub.UsageArg := ASub.UsageArg + ' ';
    ASub.UsageArg := ASub.UsageArg + Usage;
  end
  else if ASub.FSharedUsageLength = 0 then
  begin
    if ASub.UsageArg <> '' then ASub.UsageArg := ' ' + ASub.UsageArg;
    ASub.UsageArg := Usage + ASub.UsageArg;
    ASub.FSharedUsageLength := Length(Usage);
  end
  else
  begin
    { Later shared flags follow the earlier ones, in registration order. }
    Usage := ' ' + Usage;
    Insert(Usage, ASub.UsageArg, ASub.FSharedUsageLength + 1);
    Inc(ASub.FSharedUsageLength, Length(Usage));
  end;
end;

constructor TSubcommandRegistry.Create;
begin
  inherited Create;
  FUsageExitCode := DEFAULT_USAGE_EXIT_CODE;
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
  for i := 0 to High(FTopLevelFlags) do
    FTopLevelFlags[i].Free;
  inherited Destroy;
end;

procedure TSubcommandRegistry.Add(ASub: TSubcommand);
var
  ExistingOptionIndex, FlagIndex: Integer;
begin
  { Check the complete command surface before appending any shared option so a
    rejected command remains untouched and owned by its caller. }
  for FlagIndex := 0 to High(FTopLevelFlags) do
    if FTopLevelFlags[FlagIndex].BareWord
       and SameText(FTopLevelFlags[FlagIndex].LongName, ASub.Name) then
      raise EArgumentException.CreateFmt(
        'subcommand %s has the name of a top-level flag word', [ASub.Name]);
  for FlagIndex := 0 to High(FSharedFlags) do
    for ExistingOptionIndex := 0 to High(ASub.Options) do
      if SameText(ASub.Options[ExistingOptionIndex].LongName,
         FSharedFlags[FlagIndex].LongName) then
        raise EArgumentException.CreateFmt(
          'subcommand %s already defines shared flag --%s',
          [ASub.Name, FSharedFlags[FlagIndex].LongName]);

  for FlagIndex := 0 to High(FSharedFlags) do
    AttachSharedFlag(ASub, FSharedFlags[FlagIndex]);
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := ASub;
end;

procedure TSubcommandRegistry.AddSharedFlag(
  const ALongName, AHelpText: string);
var
  FlagIndex, ItemIndex, OptionIndex: Integer;
begin
  if ALongName = '' then
    raise EArgumentException.Create('shared flag name cannot be empty');
  for FlagIndex := 0 to High(FSharedFlags) do
    if SameText(FSharedFlags[FlagIndex].LongName, ALongName) then
      raise EArgumentException.CreateFmt(
        'shared flag --%s is already registered', [ALongName]);

  { Validate every existing command before mutating the registry. This keeps a
    rejected shared flag atomic and prevents ambiguous parser/help entries. }
  for ItemIndex := 0 to High(FItems) do
    for OptionIndex := 0 to High(FItems[ItemIndex].Options) do
      if SameText(FItems[ItemIndex].Options[OptionIndex].LongName,
         ALongName) then
        raise EArgumentException.CreateFmt(
          'subcommand %s already defines shared flag --%s',
          [FItems[ItemIndex].Name, ALongName]);

  FlagIndex := Length(FSharedFlags);
  SetLength(FSharedFlags, FlagIndex + 1);
  FSharedFlags[FlagIndex].LongName := ALongName;
  FSharedFlags[FlagIndex].HelpText := AHelpText;

  for ItemIndex := 0 to High(FItems) do
    AttachSharedFlag(FItems[ItemIndex], FSharedFlags[FlagIndex]);
end;

procedure TSubcommandRegistry.AddTopLevelFlag(const AFlag: TTopLevelFlag);
var
  FlagIndex: Integer;
begin
  if AFlag.LongName = '' then
    raise EArgumentException.Create('top-level flag name cannot be empty');
  { A name given with its dashes would never match what the user types. }
  if AFlag.LongName[1] = '-' then
    raise EArgumentException.CreateFmt(
      'top-level flag name "%s" must be given without its leading dashes',
      [AFlag.LongName]);
  if (AFlag.ShortName <> '') and (AFlag.ShortName[1] = '-') then
    raise EArgumentException.CreateFmt(
      'top-level flag short name "%s" must be given without its leading dash',
      [AFlag.ShortName]);
  if not Assigned(AFlag.Handler) then
    raise EArgumentException.CreateFmt(
      'top-level flag --%s has no handler', [AFlag.LongName]);
  { Help is matched in any letter case, so it owns every case of both. }
  if SameText(AFlag.LongName, HELP_WORD)
     or SameText(AFlag.ShortName, HELP_SHORT_NAME) then
    raise EArgumentException.CreateFmt(
      'top-level flag --%s uses a spelling reserved for help',
      [AFlag.LongName]);
  for FlagIndex := 0 to High(FTopLevelFlags) do
    if SameText(FTopLevelFlags[FlagIndex].LongName, AFlag.LongName)
       or ((AFlag.ShortName <> '')
         and (FTopLevelFlags[FlagIndex].ShortName = AFlag.ShortName)) then
      raise EArgumentException.CreateFmt(
        'top-level flag --%s is already registered', [AFlag.LongName]);
  if AFlag.BareWord and (Find(AFlag.LongName) <> nil) then
    raise EArgumentException.CreateFmt(
      'top-level flag word %s is already a subcommand', [AFlag.LongName]);

  SetLength(FTopLevelFlags, Length(FTopLevelFlags) + 1);
  FTopLevelFlags[High(FTopLevelFlags)] := AFlag;
end;

function TSubcommandRegistry.TopLevelFlagCount: Integer;
begin
  Result := Length(FTopLevelFlags);
end;

function TSubcommandRegistry.TopLevelFlagItem(
  const AIndex: Integer): TTopLevelFlag;
begin
  if (AIndex < 0) or (AIndex > High(FTopLevelFlags)) then
    raise EArgumentOutOfRangeException.CreateFmt(
      'top-level flag index %d out of range 0..%d',
      [AIndex, High(FTopLevelFlags)]);
  Result := FTopLevelFlags[AIndex];
end;

function TSubcommandRegistry.FindTopLevelFlag(
  const AArgument: string): TTopLevelFlag;
var
  FlagIndex: Integer;
begin
  for FlagIndex := 0 to High(FTopLevelFlags) do
  begin
    Result := FTopLevelFlags[FlagIndex];
    if (AArgument = '--' + Result.LongName)
       or ((Result.ShortName <> '') and (AArgument = '-' + Result.ShortName))
       or (Result.BareWord and SameText(AArgument, Result.LongName)) then
      Exit;
  end;
  Result := nil;
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

{ Writes an `options:` section: each name padded to the widest one, then
  its help text. Top-level help and subcommand help share it, so the two
  sections cannot drift apart. }
procedure WriteOptionRows(var AOutput: Text;
  const ANames, AHelpTexts: array of string);
var
  i, MaxWidth, W: Integer;
begin
  MaxWidth := 0;
  for i := 0 to High(ANames) do
    if Length(ANames[i]) > MaxWidth then MaxWidth := Length(ANames[i]);

  WriteLn(AOutput);
  WriteLn(AOutput, 'options:');
  for i := 0 to High(ANames) do
  begin
    Write(AOutput, '  ', ANames[i]);
    for W := Length(ANames[i]) to MaxWidth do Write(AOutput, ' ');
    WriteLn(AOutput, '  ', AHelpTexts[i]);
  end;
end;

procedure TSubcommandRegistry.PrintTopLevelHelp(const AProgramName: string);
begin
  PrintTopLevelHelp(Output, AProgramName);
end;

procedure TSubcommandRegistry.PrintTopLevelHelp(var AOutput: Text;
  const AProgramName: string);
var
  i, Listed: Integer;
  Names, HelpTexts: array of string;
begin
  if FDescription <> '' then
  begin
    WriteLn(AOutput, AProgramName, ' — ', FDescription);
    WriteLn(AOutput);
  end;
  WriteLn(AOutput, 'usage: ', AProgramName, ' <command> [options]');
  WriteLn(AOutput);
  WriteLn(AOutput, 'commands:');
  for i := 0 to High(FItems) do
    WriteLn(AOutput, '  ', FItems[i].Name:10, '  ', FItems[i].Summary);

  { A flag without help text is accepted but not listed. }
  SetLength(Names, Length(FTopLevelFlags));
  SetLength(HelpTexts, Length(FTopLevelFlags));
  Listed := 0;
  for i := 0 to High(FTopLevelFlags) do
    if FTopLevelFlags[i].HelpText <> '' then
    begin
      Names[Listed] := FormatHelpLabel(FTopLevelFlags[i].ShortName,
        '--' + FTopLevelFlags[i].LongName);
      HelpTexts[Listed] := FTopLevelFlags[i].HelpText;
      Inc(Listed);
    end;
  SetLength(Names, Listed);
  SetLength(HelpTexts, Listed);
  if Listed > 0 then
    WriteOptionRows(AOutput, Names, HelpTexts);

  WriteLn(AOutput);
  WriteLn(AOutput, 'run "', AProgramName,
    ' <command> --help" for command options');
end;

procedure TSubcommandRegistry.PrintSubcommandHelp(const AProgramName: string;
  ASub: TSubcommand);
var
  i: Integer;
  Names, HelpTexts: array of string;
begin
  WriteLn(AProgramName, ' ', ASub.Name, ' — ', ASub.Summary);
  WriteLn;
  Write('usage: ', AProgramName, ' ', ASub.Name);
  if ASub.UsageArg <> '' then
    Write(' ', ASub.UsageArg);
  WriteLn;

  if Length(ASub.Options) > 0 then
  begin
    { HelpLabel (see CLI.Options) shows the short name and value shape:
      -o, --name=<value>. }
    SetLength(Names, Length(ASub.Options));
    SetLength(HelpTexts, Length(ASub.Options));
    for i := 0 to High(ASub.Options) do
    begin
      Names[i] := ASub.Options[i].HelpLabel;
      HelpTexts[i] := ASub.Options[i].HelpText;
    end;
    WriteOptionRows(Output, Names, HelpTexts);
  end;

  WriteLn;
  WriteLn('run "', AProgramName, ' --help" to see all commands');
end;

{ Whether AArguments, the arguments after the command name, ask for the
  help of ASub. Checked before parsing, which would reject --help as an
  unknown option. Any argument that spells --help, -h or the word `help`
  asks for it, up to the end-of-options marker. A pass-through command
  reads only --help and -h, and only before its first positional: from
  there on every argument belongs to the program it launches. Both read
  the arguments the way the parser does, so a value that a valued option
  takes (`-o help`, a `--` after `-o`) is neither a help request nor the
  end of options. }
function HelpRequested(const ASub: TSubcommand;
  const AArguments: array of string;
  const AStrictSingleDash: Boolean): Boolean;
begin
  if ASub.PassThrough then
    Result := LeadingFlagGiven(AArguments, ASub.Options, HELP_WORD,
      HELP_SHORT_NAME, AStrictSingleDash)
  else
    Result := FlagGiven(AArguments, ASub.Options, HELP_WORD,
      HELP_SHORT_NAME, HELP_WORD);
end;

{ An unknown or missing command: the message on standard error, then the
  top-level help on the stream the host chose. On standard error a blank
  line sets the help apart from the message. }
function TSubcommandRegistry.ReportUsageError(
  const AProgramName, AMessage: string): Integer;
begin
  WriteLn(ErrOutput, AMessage);
  if FUsageHelpToStandardError then
  begin
    WriteLn(ErrOutput);
    PrintTopLevelHelp(ErrOutput, AProgramName);
  end
  else
    PrintTopLevelHelp(AProgramName);
  Result := FUsageExitCode;
end;

function TSubcommandRegistry.Run(const AProgramName: string): Integer;
begin
  Result := Run(AProgramName, GetCommandLineArguments);
end;

function TSubcommandRegistry.Run(const AProgramName: string;
  const AArguments: array of string): Integer;
var
  CmdName : string;
  Sub, AliasSub : TSubcommand;
  Flag : TTopLevelFlag;
  CommandArguments : TCommandLineArguments;
  Positionals : TStringList;
  FirstArgument, i : Integer;
  StartedAt : QWord;
  Completion : TSubcommandCompletion;
  PreparationError : string;
begin
  if Length(AArguments) < 1 then
  begin
    if FBareInvocation = biUsageError then
      Exit(ReportUsageError(AProgramName, 'missing command'));
    PrintTopLevelHelp(AProgramName);
    Exit(0);
  end;

  Flag := FindTopLevelFlag(AArguments[0]);
  if Flag <> nil then
    Exit(Flag.Handler());

  CmdName := LowerCase(AArguments[0]);
  if (CmdName = HELP_WORD) or (CmdName = HELP_LONG_FLAG)
     or (CmdName = HELP_SHORT_FLAG) then
  begin
    PrintTopLevelHelp(AProgramName);
    Exit(0);
  end;

  Sub := Find(CmdName);
  if Sub = nil then
    Exit(ReportUsageError(AProgramName, 'unknown command: ' + CmdName));

  StartedAt := GetTickCount64;
  Result := 1;
  try

    { Subcommand aliasing, as in `lwpt run <subcommand>` (ADR-0013). When
      the command opted in and its first argument names a registered
      subcommand, dispatch THAT subcommand with the arguments after its
      name. The aliasing command's own handler never sees this case. }
    FirstArgument := 1;
    if Sub.AliasesSubcommands and (Length(AArguments) >= 2) then
    begin
      AliasSub := Find(LowerCase(AArguments[1]));
      if AliasSub <> nil then
      begin
        Sub := AliasSub;
        FirstArgument := 2;
        CmdName := LowerCase(AArguments[1]);
      end;
    end;

    SetLength(CommandArguments, Length(AArguments) - FirstArgument);
    for i := FirstArgument to High(AArguments) do
      CommandArguments[i - FirstArgument] := AArguments[i];

    if HelpRequested(Sub, CommandArguments, FStrictSingleDash) then
    begin
      PrintSubcommandHelp(AProgramName, Sub);
      Exit(0);
    end;

    try
      Positionals := ParseArguments(CommandArguments, Sub.Options,
        Sub.PassThrough, FStrictSingleDash);
    except
      on E: TParseError do
      begin
        WriteLn(ErrOutput, AProgramName, ' ', CmdName, ': ', E.Message);
        Exit(FUsageExitCode);
      end;
    end;

    try
      PreparationError := '';
      if Assigned(FOnCommandPrepared) then
        PreparationError := FOnCommandPrepared(CmdName, Sub.Options);
      if PreparationError <> '' then
      begin
        WriteLn(ErrOutput, AProgramName, ' ', CmdName, ': ',
          PreparationError);
        Result := FUsageExitCode;
      end
      else
        Result := Sub.Handler(Positionals, Sub.Options);
    finally
      Positionals.Free;
    end;
  finally
    if Assigned(FOnCommandCompleted) then
    begin
      Completion.CommandName := CmdName;
      Completion.ExitCode := Result;
      Completion.ElapsedMilliseconds := GetTickCount64 - StartedAt;
      try
        FOnCommandCompleted(Completion);
      except
        { Completion observers must not replace the command's exit result. }
      end;
    end;
  end;
end;

end.
