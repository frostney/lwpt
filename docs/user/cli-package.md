# Build a command line on the `cli` package

The `cli` package gives a program subcommands, options, help and usage errors
from one registry. `lwpt` builds its own command line on it, and so can any
other program: the registry carries no host's name, description or policy.

This page describes `cli` 0.7.0. LWPT 0.9.0 ships `cli` 0.6.0. LWPT 0.8.0
and 0.8.1 ship `cli` 0.5.1, and earlier releases ship older versions; none of
them has the host settings below. The [consumer guide](consumer-guide.md) shows how to add the package
to a project.

A host that moves from 0.6.0 to 0.7.0 without changing its code sees one
difference: a command option with a short name is listed with it in the
command's help and in `GenerateHelpText` (`-o, --output=<value>`).

A host that moves from 0.5.1 to 0.6.0 without changing its code sees three
differences:

- Top-level help no longer prints LWPT's tagline. Set `Description` to print
  the host's own.
- A command named `run` no longer dispatches the subcommand its first argument
  names. Set `AliasesSubcommands` on it to keep that.
- `--` ends option parsing; 0.5.1 rejected it as an unknown option.

## A complete host

```pascal
program Demo;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands;

const
  PROGRAM_NAME = 'demo';
  USAGE_EXIT_CODE = 2;

function HandleVersion: Integer;
begin
  WriteLn(PROGRAM_NAME, ' 1.0.0');
  Result := 0;
end;

function HandleRun(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Index: Integer;
begin
  if APositionals.Count = 0 then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: expected <file>');
    Exit(USAGE_EXIT_CODE);
  end;
  if AOptions[0].Present then
    WriteLn('runtime checks: off');
  WriteLn('file: ', APositionals[0]);
  for Index := 1 to APositionals.Count - 1 do
    WriteLn('argument: ', APositionals[Index]);
  Result := 0;
end;

function HandleCheck(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  if APositionals.Count <> 1 then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' check: expected one <file>');
    Exit(USAGE_EXIT_CODE);
  end;
  WriteLn('checked: ', APositionals[0]);
  Result := 0;
end;

var
  Registry: TSubcommandRegistry;
  RunCommand: TSubcommand;
  RunOptions, NoOptions: TOptionArray;
  VersionFlag: TTopLevelFlag;
begin
  Registry := TSubcommandRegistry.Create;
  try
    Registry.Description := 'run and check demo programs';
    Registry.UsageExitCode := USAGE_EXIT_CODE;
    Registry.UsageHelpToStandardError := True;
    Registry.BareInvocation := biUsageError;

    VersionFlag := TTopLevelFlag.Create('version', 'Print the version',
      @HandleVersion);
    VersionFlag.ShortName := 'V';
    Registry.AddTopLevelFlag(VersionFlag);

    SetLength(RunOptions, 1);
    RunOptions[0] := TFlagOption.Create('unchecked',
      'Remove the runtime checks');
    RunOptions[0].ShortName := 'u';
    RunCommand := TSubcommand.Create('run', 'Run a program',
      '[--unchecked] <file> [arguments]', @HandleRun, RunOptions);
    RunCommand.PassThrough := True;
    Registry.Add(RunCommand);

    SetLength(NoOptions, 0);
    Registry.Add(TSubcommand.Create('check', 'Check a program', '<file>',
      @HandleCheck, NoOptions));

    ExitCode := Registry.Run(PROGRAM_NAME);
  finally
    Registry.Free;
  end;
end.
```

The registry owns the subcommands, their option objects and the top-level
flags, and frees them.

```text
$ demo --help
demo — run and check demo programs

usage: demo <command> [options]

commands:
         run  Run a program
       check  Check a program

options:
  -V, --version   Print the version

run "demo <command> --help" for command options

$ demo run --unchecked main.x --port 80 -- --help
runtime checks: off
file: main.x
argument: --port
argument: 80
argument: --
argument: --help

$ demo run check
file: check
```

## What a host sets

Every setting is optional. A registry that sets none of them behaves as the
defaults column says.

| Setting | Default | Effect |
| --- | --- | --- |
| `Registry.Description` | empty | Printed after the program name on the first line of top-level help. When empty, the help starts at the `usage:` line. |
| `Registry.AddTopLevelFlag` | no flags | Registers a flag such as `--version` that runs a handler in place of a command. |
| `Registry.UsageExitCode` | 1 (`DEFAULT_USAGE_EXIT_CODE`) | The exit code of a usage error. |
| `Registry.UsageHelpToStandardError` | `False` | Sends the help that follows an unknown or missing command to standard error. |
| `Registry.BareInvocation` | `biShowHelp` | What the program does without arguments: print help and exit 0, or report a usage error (`biUsageError`). |
| `TSubcommand.PassThrough` | `False` | Stops option parsing at the command's first positional. |
| `TSubcommand.AliasesSubcommands` | `False` | Lets `<program> <command> <subcommand>` dispatch `<subcommand>`. |

Help is built in: `help`, `--help` and `-h` as the first argument print the
top-level help, and after a command name they print that command's help.

A command's help lists its options under `options:`. An option with a
`ShortName` is listed with it, the way top-level help lists a flag's short
name; the help texts start in one column after the widest entry:

```text
$ demo run --help
demo run — Run a program

usage: demo run [--unchecked] <file> [arguments]

options:
  -u, --unchecked   Remove the runtime checks

run "demo --help" to see all commands
```

`HelpLabel` returns the label an option is listed with (`-u, --unchecked`,
`-o, --output=<value>`, or `--release` without a short name).
`GenerateHelpText` lists options with it too, and a host that renders its own
command reference from the registry can use it to match the help.

Write a command option's `ShortName` without its dash, as for a top-level
flag. `h` is not available: `-h` after a command name always asks for help,
so an option with the short name `h` cannot be given as `-h`.

## Top-level flags

A top-level flag is read from the first argument only, the way `--help` is.
Its handler runs instead of a command, and the handler's result is the exit
code. Arguments after the flag are ignored.

- `LongName` matches `--<LongName>`, in that letter case.
- `ShortName`, when set, matches `-<ShortName>`, in that letter case.
- `BareWord`, when `True`, also matches `<LongName>` without dashes in any
  letter case, the way the built-in `help` word does. `lwpt` uses it for
  `lwpt version`.
- A flag with `HelpText` is listed under `options:` in top-level help, with
  its short name. A flag without help text is accepted but not listed.

Set a flag's fields before `AddTopLevelFlag`, which checks them once.
`AddTopLevelFlag` raises `EArgumentException`, and leaves the flag with the
caller, for an empty name, a name or short name written with its leading
dashes, a missing handler, the name `help` or the short name `h`, a name or
short name that is already registered, and a bare word that is also a
subcommand name. `Add` refuses a subcommand whose name is a registered bare
word. `TopLevelFlagCount` and `TopLevelFlagItem` iterate the registered flags,
as `Count` and `Item` iterate the subcommands.

An option that changes how a command runs belongs after the command name. Give
it to one command through its options, or to every command with
`AddSharedFlag`.

## End of options and pass-through

`--` ends option parsing for every command. The arguments after it reach the
handler as positionals, whatever they look like, and are not read as options
or as a request for help. The marker itself is not passed on.

```text
$ demo check -- --help
checked: --help
```

A command that launches another program sets `PassThrough` before it is added
to the registry. Option parsing then stops at the first positional:

- The command's own options, and `--help` or `-h`, are read before the first
  positional only.
- The first positional and everything after it reach the handler untouched:
  options the command does not define, `--help`, the word `help`, and a later
  `--`.
- A `--` before the first positional is consumed, so the first operand may
  begin with a hyphen: `demo run -- --unchecked` runs the file `--unchecked`.
- An unknown option before the first positional is still a usage error:
  `demo run --port 80` fails with `Unknown option: --port`.
- A single-dash argument of more than one character that matches no option is
  a positional, here as everywhere in the parser. `demo run -xyz main.x`
  therefore runs the file `-xyz` and hands it `main.x`.
- A flag added with `AddSharedFlag` is shown ahead of the command's own usage,
  because it counts only there. With a shared `--json`, the usage line of
  `demo run` reads `usage: demo run [--json] [--unchecked] <file> [arguments]`.

Outside pass-through commands, the word `help` anywhere before `--` asks for
the command's help, so `demo check a help` prints the help of `check`.

## Subcommand aliasing

A command that sets `AliasesSubcommands` hands its line to another subcommand
when its first argument names one: `lwpt run build --clean` dispatches `build`
with `--clean`, and reports completion as `build`. Only the argument directly
after the command is looked up. An option or `--` in that place keeps the line
with the command, so `lwpt run -- build` hands `build` to the handler of `run`.
Without the setting, a subcommand name after the command is an ordinary
positional, as `demo run check` shows above.

## Usage errors

A usage error is an unknown command, an option or value the parser rejects, a
dispatch that `OnCommandPrepared` rejects, and a bare invocation under
`biUsageError`. Each returns `UsageExitCode`. A failing handler's own exit code
is returned unchanged, so a host that sets a code its handlers never return can
tell the two apart. The conventional choice is 2. A handler that finds a usage
error of its own, such as a missing operand, returns the same code itself.

```text
$ demo frobnicate
unknown command: frobnicate

demo — run and check demo programs
...
$ echo $?
2
```

With `UsageHelpToStandardError` the message and the help both go to standard
error and standard output stays empty. Without it the message goes to standard
error and the help to standard output. A rejected option prints one line on
standard error in either case: `demo run: Unknown option: --port`.

## Test a command line in-process

`Run` has an overload that takes the arguments after the program name, and
`CLI.Parser` exposes the same for the parser, so a test does not need to
replace the process's own arguments:

```pascal
Expect<Integer>(Registry.Run('demo', ['run', 'main.x', '--port'])).ToBe(0);

Positionals := ParseArguments(['--unchecked', 'main.x'], RunOptions);
```

Option objects keep what a dispatch applied to them, and nothing resets them.
Build a fresh registry, or fresh options, for each dispatch a test asserts on;
a second `Run` on the same registry still sees the options of the first.

`ParseArguments` takes `AStopAtFirstPositional` as an optional third argument
for the pass-through rule. `Run(AProgramName)` and `ParseCommandLine` read the
process's arguments through `GetCommandLineArguments` and delegate to these
entry points.
