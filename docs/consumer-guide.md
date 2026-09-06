# Use LWPT in your project

LWPT provides dependency management, builds, testing, CLI libraries, formatting,
health and duplication checks, run tasks, lifecycle hooks, and agent reference
synchronization through one `lwpt.toml`. Start with `lwpt --help` to see the
installed commands, then `lwpt <command> --help` for their options. Subcommand
help links back to the complete command list.

This guide is for projects that **use** LWPT. To change LWPT itself, follow the
[contributor quick start](quick-start.md). Consumer projects use the installed
`lwpt` executable; LWPT's `bootstrap.sh` builds the toolkit from its source.

## Install the released toolkit

On macOS, install FreePascal and LWPT through Homebrew:

```sh
brew install fpc frostney/tap/lwpt
fpc -iV
lwpt --version
lwpt --help
```

The [Homebrew formula](https://github.com/frostney/homebrew-tap/blob/main/Formula/lwpt.rb)
installs the released binary. On other platforms, install FreePascal and use
the matching archive from [LWPT releases](https://github.com/frostney/lwpt/releases),
placing its executable on `PATH`. See the [platform support](deployment.md)
reference for supported targets.

The example below uses released **0.7.0** packages. Documentation on `main` can
describe newer commands; installed help and release tags identify the version
you are using. Update dependency pins deliberately and regenerate the lockfile.

## Scaffold a CLI with a native test

```sh
mkdir hello
cd hello
lwpt init --yes
```

Initialization creates a minimal program, manifest, and ignore rules. Add the
capabilities your project needs; initializing alone does not configure testing,
quality thresholds, or project hooks.

Replace `lwpt.toml` with:

```toml
[package]
name = "hello"
version = "0.1.0"
units = ["source"]

[dependencies]
cli = { source = "frostney/lwpt", version = "0.7.0", include = ["packages/cli/**"] }
testing = { source = "frostney/lwpt", version = "0.7.0", include = ["packages/testing/**"] }

[build]
hello = { source = "source/hello.pas", output = "build/hello" }

[smoke]
command = "build/hello"
args = ["greet", "--name", "LWPT"]
```

Both libraries ship inside the LWPT repository. The include filters select
their package trees; `lwpt install` resolves their unit paths automatically.
There is no need to copy library sources or add manual compiler search paths.

Create `source/Shared.inc`:

```pascal
{$mode delphi}{$H+}
```

Create `source/Greeting.pas`:

```pascal
unit Greeting;

{$I Shared.inc}

interface

function Greet(const AName: string): string;

implementation

uses
  SysUtils;

function Greet(const AName: string): string;
begin
  if Trim(AName) = '' then
    raise EArgumentException.Create('name must not be empty');
  Result := 'Hello, ' + Trim(AName) + '!';
end;

end.
```

Replace the generated `source/hello.pas`:

```pascal
program Hello;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,
  Greeting;

function HandleGreet(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
begin
  if APositionals.Count > 0 then
  begin
    WriteLn(ErrOutput, 'greet takes --name, not positional arguments');
    Exit(1);
  end;
  try
    WriteLn(Greet(TStringOption(AOptions[0]).ValueOr('world')));
    Result := 0;
  except
    on E: EArgumentException do
    begin
      WriteLn(ErrOutput, E.Message);
      Result := 1;
    end;
  end;
end;

var
  Registry: TSubcommandRegistry;
  Options: TOptionArray;
begin
  Registry := TSubcommandRegistry.Create;
  try
    SetLength(Options, 1);
    Options[0] := TStringOption.Create('name', 'Name to greet');
    Registry.Add(TSubcommand.Create('greet', 'Print a greeting',
      '[--name <name>]', @HandleGreet, Options));
    ExitCode := Registry.Run('hello');
  finally
    Registry.Free;
  end;
end.
```

Create `source/Greeting.Test.pas`:

```pascal
program Greeting.Test;

{$I Shared.inc}

uses
  SysUtils,

  Greeting,
  TestingPascalLibrary;

type
  TGreetingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestTrimsName;
    procedure TestRejectsBlankName;
  end;

procedure TGreetingTests.TestTrimsName;
begin
  Expect<string>(Greet('  Pascal  ')).ToBe('Hello, Pascal!');
end;

procedure TGreetingTests.TestRejectsBlankName;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    Greet('   ');
  except
    on E: EArgumentException do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TGreetingTests.SetupTests;
begin
  Test('trim surrounding whitespace', TestTrimsName);
  Test('reject a blank name', TestRejectsBlankName);
end;

begin
  TestRunnerProgram.AddSuite(TGreetingTests.Create('Greeting'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
```

Install dependencies, build, and exercise the example:

```sh
lwpt install
lwpt build
lwpt test source/Greeting.Test.pas
lwpt run smoke
lwpt format
lwpt format --check
lwpt health
lwpt duplication
lwpt agents
lwpt agents --check
```

The smoke task prints `Hello, LWPT!`; both native tests pass. `build/hello greet
--help` displays the application's options. `build/hello greet --name " "`
exits nonzero with `name must not be empty`.

Commit the manifest, generated lockfile/configuration, and dependency snapshots
according to the [dependency state contract](architecture.md#lwpt-layout).
Generated state belongs to `lwpt install`; do not hand-edit its contents.

## Choose the existing capability

| Need | LWPT capability | Reference |
| --- | --- | --- |
| Initialize or adopt a project | `lwpt init`, `lwpt init --adopt` | `lwpt init --help` |
| Resolve, add, or remove dependencies | `lwpt install`, `lwpt add`, `lwpt remove` | [Manifest and packages](../README.md#manifest) |
| Parse application arguments and provide help | `cli` package | [CLI public types](../packages/cli/source/CLI.Options.pas), [subcommands](../packages/cli/source/CLI.Subcommands.pas) |
| Build selected binaries | `lwpt build` | [Build system](build-system.md) |
| Run native tests | `testing` package and `lwpt test` | [Testing](testing.md) |
| Run a project-specific tool or oracle adapter | A manifest task and `lwpt run <task>` | [Run tasks](adr/0013-run-subcommand-and-build-rename.md) |
| Generate inputs or perform lifecycle actions | Manifest lifecycle hooks | [Hooks](adr/0011-build-lifecycle-hooks.md) |
| Format Pascal source | `lwpt format`, `lwpt format --check` | [Formatting scope and rules](code-style.md) |
| Check complexity and duplication | `lwpt health`, `lwpt duplication` | [Health thresholds](health.md), [duplication](tooling.md#duplication-analysis) |
| Keep agent commands current | `lwpt agents`, `lwpt agents --check` | [Generated reference](adr/0027-agents-subcommand.md) |

The formatter handles uses clauses and identifiers; it does not reflow arbitrary
procedure bodies. Write readable Pascal and configure health/duplication limits
appropriate to the project. Run the selected checks through your existing hooks
and CI. Keep focused tests available during development and use the full suite
at your project's acceptance points. Custom domain logic belongs behind these
entry points when the toolkit does not supply that behavior.

For larger consumer configurations, see [Wasmlight's manifest](https://github.com/frostney/wasmlight/blob/main/lwpt.toml)
and [Duetto's manifest](https://github.com/frostney/duetto/blob/main/lwpt.toml).
For a compact Markdown documentation index, see [llms.txt](../llms.txt).
