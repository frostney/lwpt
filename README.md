# LWPT — lightweight Pascal toolkit

A small, dependency-light toolkit for FreePascal / Delphi projects.
One executable, seven subcommands, driven by a single `lwpt.toml`
manifest. Zero-install by default — `git clone && fpc @lwpt.cfg`
builds a project without running `lwpt install` first.

```text
lwpt init      scaffold a new project (manifest + source dir + sample entry)
lwpt install   resolve + fetch dependencies, write lwpt.lock + lwpt.cfg
lwpt build     compile manifest targets   [--mode dev|release] [--clean]
lwpt format    format uses-clauses + identifiers   [--check]
lwpt test      discover, compile and run *.Test.pas files
lwpt repair    clean .lwpt/tmp/ and stale install lock; recover from crash
lwpt run       invoke a user-declared run-script (or alias a subcommand)
```

## Status

LWPT is pre-1.0. The package model, install pipeline, formatter, test
runner, and release flow are in place; the deferred contracts (link-check,
duplication, codebase-health, architectural-drift) are tracked separately
per [ADR-0006](./docs/adr/0006-stack-contracts-deferred-from-v1.md). See
[`AGENTS.md`](./AGENTS.md) for the full operating manual and
[`docs/adr/`](./docs/adr/) for the architectural decisions that shape
the v1 design.

## Quick start

```sh
# One-time bootstrap (produces the first build/lwpt binary)
./bootstrap.sh     # Unix
bootstrap.bat      # Windows

# Steady state — all driven by the LWPT binary
./build/lwpt build              # dev build, all manifest targets
./build/lwpt build --mode release
./build/lwpt build <target>     # single target
./build/lwpt format             # rewrite project sources to canonical style
./build/lwpt format --check     # exit non-zero on any deviation
./build/lwpt test               # discover/compile/run *.Test.pas
./build/lwpt install            # fetch any new deps
./build/lwpt install --frozen   # CI: verify, refuse to update
./build/lwpt repair             # recover from a crashed install
```

## Architecture

The package manager is the foundation. `install` resolves the
dependency graph and emits `lwpt.cfg` (an FPC response fragment of
`-Fu` search paths). Every other subcommand consumes that same cfg.
The manifest is the single source of truth. This through-line is
deliberate — see [`docs/adr/0002-lwpt-namespace-zero-install.md`](./docs/adr/0002-lwpt-namespace-zero-install.md)
for the full rationale.

| File | Origin | Role |
|------|--------|------|
| `source/lwpt.pas` | new | program entry: registers subcommands |
| `source/LWPT.Core.pas` | new | toolkit core — manifest, TOML, resolver, fetch/extract, build, test, repair |
| `source/LWPT.Format.pas` | converted from GocciaScript `format.pas` | formatter logic as a unit |
| `source/LWPT.GitProtocol.pas` | new | git smart-HTTP tag listing for `<source>@<spec>` resolution |
| `source/Platform.pas` | LWPT-canonical | host OS / CPU detection for `{platform.*}` placeholders (extraction candidate for `packages/platform/`) |
| `source/Shared.inc` | LWPT-canonical | include file (`{$mode delphi} {$H+}` baseline; each `packages/<name>/source/` has its own bundled copy) |
| `packages/httpclient/` | LWPT-canonical workspace package | HTTP/1.1 + HTTPS client + byte-safety accumulator |
| `packages/cli/` | LWPT-canonical workspace package | option parser + subcommand dispatch + interactive prompts |
| `packages/semver/` | LWPT-canonical workspace package | full node-semver port |
| `packages/toml/` | LWPT-canonical workspace package | TOML 1.1 parser |
| `packages/testing/` | LWPT-canonical workspace package | `TestingPascalLibrary` — assertion + suite + runner framework for `*.Test.pas` files |

The five workspace packages live under `packages/<name>/` (per
[ADR-0014](./docs/adr/0014-packages-extraction.md) +
[ADR-0015](./docs/adr/0015-drop-export-testing-becomes-workspace-package.md));
the root manifest auto-discovers them via `[workspaces]
include = ["packages/*"]`. Per
[ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md), LWPT is the
canonical source for every package — and GocciaScript (a sister project
under the same owner) is the first named consumer, committed to Path A
adoption (full toolchain migration to `lwpt build / install / test /
format`). Phase 2 graduates individual packages to standalone repos
when warranted; the per-package roadmap lives in
[`docs/packages.md`](./docs/packages.md).

## On-disk layout

```text
my-project/
├── lwpt.toml                # manifest (single source of truth)
├── lwpt.lock                # lockfile (committed)
├── lwpt.cfg                 # FPC response fragment (committed)
├── .lwpt/                   # toolkit state
│   ├── modules/             # extracted deps — COMMITTED, source of truth
│   │   ├── horse/
│   │   └── jhonson/
│   ├── archives/            # *.tar.gz per dep — COMMITTED (verification)
│   └── tmp/                 # install workspace — GITIGNORED
├── build/                   # FPC output — GITIGNORED
└── src/
    └── main.pas
```

## Manifest

```toml
[package]
name = "myapp"
version = "1.4.2"
units = ["src"]

[dependencies]
# Bare-string shorthand: "<source>@<spec>" — see ADR-0009.
horse        = "HashLoad/horse@^4.0.0"                  # GitHub by default, SemVer range
hello        = "octocat/Hello-World@1.0.0"              # exact SemVer (matches tag `1.0.0` or `v1.0.0`)
release-cli  = "gitlab:gitlab-org/release-cli@v0.16.0"  # GitLab via prefix, literal Git tag
atlaskit     = "bitbucket:atlassian/atlaskit@d7ac1ac"   # Bitbucket via prefix, commit SHA
custom       = "https://example.com/custom-1.0.0.tar.gz" # arbitrary HTTPS tarball
leaf         = "../leaf"                                # local sibling path
# Inline-table form for advanced options (include / exclude filters,
# formatter-mirror semantics — see ADR-0009):
horse-mw     = { source = "HashLoad/horse", version = "^4.0.0", include = ["src/middleware/**"] }
horse-no-tests = { source = "HashLoad/horse", version = "^4.0.0", exclude = ["tests/**", "examples/**"] }
# Custom hosts via [sources.<name>] — gitea/forgejo/self-hosted/etc.
mylib        = "gitea:team/mylib@^1.0.0"                # uses the [sources.gitea] entry below

[sources]
# Per-project custom prefix definitions. Each entry is an inline
# table with `archive` + `git` URL templates. Placeholders are
# {user} / {repository} / {ref}. The smart-HTTP tag listing uses
# the `git` URL; the archive download uses `archive`.
# See ADR-0009 §"Custom hosts".
gitea = { archive = "https://git.example.com/{user}/{repository}/archive/{ref}.tar.gz", git = "https://git.example.com/{user}/{repository}.git" }

[build]
# Single-binary shorthand: `[build] source = "..."` defaults the
# entry name to [package].name and the output to build/<entry-name>.
# Multi-binary form (used here): one inline table per entry.
cli  = { source = "src/cli.pas",  output = "bin/cli" }
tool = { source = "src/tool.pas", output = "bin/tool" }

[version]
output = "src/Version.Generated.inc"
prefix = "APP"   # generates APP_VERSION, APP_BUILD_DATE

[lwpt]
# Toolkit-state overrides. Defaults shown; you almost never need these.
# modules-dir  = ".lwpt/modules"
# archives-dir = ".lwpt/archives"
# tmp-dir      = ".lwpt/tmp"
# cfg-file     = "lwpt.cfg"

[format]
# include = additive glob list on top of [package].units;
# exclude = glob list subtracted from the resolved set.
# Plain dir names are top-level shorthand; recursion via ** is explicit.
# See ADR-0007 + docs/code-style.md for the full algorithm.
include = ["tests/**/*.pas"]
exclude = ["src/legacy/Vendored.pas"]
```

Source kinds: `skGitHost` (default `github`, with `gitlab:` / `bitbucket:` / any user-declared `[sources.<name>]` prefix), `skURL` (any `https://...`), `skLocal` (any path or `local:` prefix). Version specs go through the `Semver` unit (vendored node-semver port, prefix-stripped from upstream) for ranges + exact matches, fall through to literal Git tag / commit-SHA lookup for everything else. Tag listing uses git smart-HTTP `info/refs?service=git-upload-pack` — works against any git host with one URL pattern, no JSON, no auth tokens. Custom hosts (Gitea, Forgejo, self-hosted GitHub Enterprise / GitLab / Bitbucket Server) plug in via the `[sources]` table — no code change needed. See [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md).

## Writing tests

`TestingPascalLibrary` lives in the `testing` workspace package and is
auto-discovered via `[workspaces] include = ["packages/*"]` in the
root manifest — `lwpt install` symlinks it into `.lwpt/modules/testing/`
on first run, and the cfg emitter wires the `-Fu` / `-Fi` paths so
every `*.Test.pas` file resolves `uses TestingPascalLibrary;` with no
further setup.

Then a `*.Test.pas` file is a self-contained program:

```pascal
program Math.Test;
{$mode delphi}{$H+}
uses TestingPascalLibrary;
type
  TMathTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAddition;
  end;
procedure TMathTests.TestAddition;
begin
  Expect<Integer>(2 + 2).ToBe(4);
end;
procedure TMathTests.SetupTests;
begin
  Test('addition works', TestAddition);
end;
begin
  TestRunnerProgram.AddSuite(TMathTests.Create('Math'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
```

`lwpt test` discovers `*.Test.pas` files, compiles each, runs it, and
reads the process exit code. Exits 1 if any test or compile fails.

## Notable canonical-version choices

Per [ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md), LWPT is
the canonical source for every workspace package; the older
GocciaScript copies of these units are frozen pending Path A
adoption. The places where the LWPT-canonical version meaningfully
differs from GocciaScript's older copy:

- **`packages/httpclient/source/HTTPClient.pas`** — byte-safe
  `AppendRawBytes` accumulator on the header-recv path and the
  chunked-body seed-buffer. `Copy(PAnsiChar(...))` truncates
  response bytes at the first `#0`, corrupting binary downloads;
  the byte-safe accumulator avoids the issue.
- **`packages/cli/source/CLI.Parser.pas`** — space-separated option
  values (`--mode release`) work for plain string/integer options,
  not only repeatable ones. Plus the `AStartArg` parameter for
  `lwpt run <subcommand>` aliasing.
- **`packages/cli/source/CLI.Options.pas`** — `TGoccia*` type-prefix
  stripped from every public type; GocciaScript-engine-specific
  option groups removed as dead code.
- **`packages/semver/source/Semver.pas`** — renamed from
  `Goccia.Semver`; `MAX_SAFE_INTEGER` inlined.
- **`packages/toml/source/TOML.pas`** — renamed from `Goccia.TOML`;
  parser refactored to a class-based AST shape.
- **`source/Platform.pas`** — renamed from `Goccia.Platform`.

See [`docs/packages.md`](./docs/packages.md) for the complete
package set + per-file divergence table + bootstrap chicken-and-egg
story.

## Documentation

- [`AGENTS.md`](./AGENTS.md) — operating manual for AI assistants (and
  the canonical source of truth while `docs/` is still being built out).
- [`docs/adr/`](./docs/adr/) — architectural decision records.
- [`docs/spikes/`](./docs/spikes/) — point-in-time snapshots of
  investigations (e.g. the deferred HTTP registry).

- [`docs/`](./docs/) — full set of canonical docs: `architecture.md`,
  `quick-start.md`, `tooling.md`, `code-style.md`, `build-system.md`,
  `deployment.md`, `testing.md`, `packages.md`, `ci.md`. Each opens
  with an Executive Summary.
