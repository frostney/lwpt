# Quick start

The top-to-bottom walkthrough for getting from `git clone` to passing tests on a fresh machine.

## Executive Summary

- **Bootstrap is one command, run once.** `./bootstrap.sh` (or `bootstrap.bat` on Windows) produces `build/lwpt` from `source/lwpt.pas`. After that, `./build/lwpt build` is the canonical build entry point.
- **No `lwpt install` needed after clone.** Per [ADR-0002](./adr/0002-lwpt-namespace-zero-install.md) every LWPT project commits `.lwpt/modules/` and `.lwpt/archives/`; `fpc @lwpt.cfg` works without LWPT being involved.
- **Two prerequisites:** FPC 3.2.2 (with InstantFPC bundled) and Lefthook for pre-commit hooks. TLS is platform-native in both directions on Windows and macOS (SChannel per [ADR-0016](./adr/0016-tls-backend-per-platform.md) and [ADR-0033](./adr/0033-schannel-server-tls-accept-on-windows.md), SecureTransport on macOS, system OpenSSL on Linux); no DLLs to bundle.
- **A new test is one `.Test.pas` file.** Add `testing` to `[dependencies]` (or rely on workspace auto-discovery in a monorepo), run `lwpt install` once, then write `program <Name>.Test;` files using `TestingPascalLibrary`. `lwpt test` discovers and runs them.
- **Pre-commit auto-formats.** `lwpt format` and `lwpt agents` run on every commit via Lefthook and re-stage any rewrites (`stage_fixed: true`). The heavyweight gates (`lwpt build`, `lwpt test`, `lwpt format --check`, `lwpt agents --check`) run on the PR workflow in CI. Install the local hook once with `lefthook install`.

## Prerequisites

| Tool | Version | Where it comes from |
| --- | --- | --- |
| FreePascal | 3.2.2 (verified live with `fpc -iV`) | [freepascal.org/download](https://www.freepascal.org/download.html) or `fpcupdeluxe` |
| InstantFPC | bundled with FPC | `instantfpc --help` should work; if not, install FPC's `fcl-fpcunit` package |
| Lefthook | 2.x | `brew install lefthook` / `winget install evilmartians.lefthook` / `go install github.com/evilmartians/lefthook@latest` |
| TLS library | platform-native | Windows: SChannel (built-in). macOS: SecureTransport (built-in). Linux: distro libssl (`apt install libssl3` / `dnf install openssl-libs` / `apk add openssl3-libs`). See [`deployment.md`](./deployment.md) for the per-platform story. |

Verify the toolchain before continuing:

```sh
fpc -iV                # → 3.2.2
instantfpc --help      # → usage banner
lefthook version       # → 2.x
```

## First clone

```sh
git clone <repo-url>
cd <repo>
./bootstrap.sh         # Unix
# Windows: bootstrap.bat
```

What the bootstrap does:

1. If InstantFPC is on `PATH`, runs `scripts/bootstrap.pas`, which invokes `fpc` once to compile `source/lwpt.pas` → `build/lwpt`. The fpc invocation passes `-Fu` / `-Fi` for `source/` and for every workspace package under `packages/<name>/source/` (currently: `httpclient`, `cli`, `semver`, `toml`, `testing`).
2. If InstantFPC is not on `PATH`, falls back to a direct `fpc` invocation with the same flag set.

Both code paths are dev-mode only; release builds always go through `./build/lwpt build --mode release`.

After bootstrap:

```sh
./build/lwpt --help     # top-level help; lists the 14 subcommands
```

## Daily commands

```sh
./build/lwpt init --yes         # scaffold a fresh project
./build/lwpt init --adopt       # adopt an existing manifest

./build/lwpt build              # dev build, all manifest entries
./build/lwpt build --mode release
./build/lwpt build <entry>      # single build entry
./build/lwpt build --clean      # force a fresh private-session rebuild
./build/lwpt build --jobs=1     # force sequential entry execution
./build/lwpt build --no-cache   # compile without reusable build results

./build/lwpt format             # rewrite sources to canonical style
./build/lwpt format --check     # exit non-zero on any deviation

./build/lwpt duplication        # report manifest-scoped Pascal clones
./build/lwpt duplication --json # emit the deterministic analysis envelope

./build/lwpt test               # discover/compile/run *.Test.pas

./build/lwpt install            # fetch any new deps; rewrite lwpt.lock + lwpt.cfg
./build/lwpt install --frozen   # CI: verify, refuse to update
./build/lwpt install --offline  # restore exact locked state from local bytes
./build/lwpt add owner/repo@^1.0    # add a dependency + install it (ADR-0019)
./build/lwpt remove <name>      # remove a dependency + prune its modules
./build/lwpt outdated           # compare locked git-host deps to advertised tags
./build/lwpt update             # bump constraints + reinstall newer git-host deps
./build/lwpt repair             # recover project and shared-cache residue
```

[`build-system.md`](./build-system.md) covers each in depth.

`install --offline` requires an existing compatible `lwpt.lock`. It resolves
network-backed dependencies to the lockfile's exact identities without remote
discovery, verifies a committed `.lwpt/archives/` file or the shared
content-addressed cache, then atomically restores missing archives, modules,
and `lwpt.cfg`. Local and workspace dependencies are copied from their declared
paths. The lockfile remains byte-identical. A missing object, corrupt archive,
or manifest/lock mismatch fails without fetching around the problem. Offline
materialization and read-only `--frozen` verification are mutually exclusive.

## Start or adopt a project

From an empty project directory, `init --yes` writes a default manifest,
hello-world entry, and `.gitignore` without prompting:

```sh
./build/lwpt init --yes
```

When `lwpt.toml` already exists, adoption fills in only the missing standard
scaffold:

```sh
./build/lwpt init --adopt
```

Adoption parses the manifest without rewriting it, creates missing
project-local directories declared by `[package].units`, and appends missing
`.gitignore` entries for `.lwpt/tmp/`, `.lwpt/install.lock`,
`.lwpt/sessions/`, `.lwpt/session-roots`, `.lwpt/workers/`, and the project-local output directories
declared by `[build]` (`build/` when none is usable). It reports directories
as created or found and ignore entries as added or found. It does not create
a sample program, lockfile, cfg, dependency state, or build output.

`--adopt` requires an existing valid manifest and cannot be combined with
`--force`. A units path that is a file is a conflict. A missing units path
outside the project is also refused rather than creating directories beyond
the manifest's project root.

## Install the pre-commit hook

Lefthook runs `lwpt format` and `lwpt agents` on every `git commit` with `stage_fixed: true` — any files they rewrite (formatted sources, the refreshed AGENTS.md agents block) are auto-staged into the same commit, so the local hook never blocks. The heavyweight gates (`lwpt build`, `lwpt test`, `lwpt format --check`, `lwpt agents --check`) run on the PR workflow on every pull request. Install the local hook once per fresh clone:

```sh
lefthook install
```

If you genuinely need to bypass (rare), see [`tooling.md`](./tooling.md) — but `--no-verify` violates [`CONTRIBUTING.md`](../CONTRIBUTING.md) unless explicitly requested by a maintainer.

## Adding a dependency

```sh
./build/lwpt add HashLoad/horse@^4.0.0   # writes the [dependencies] entry + installs
git add .lwpt/ lwpt.lock lwpt.cfg lwpt.toml
git commit -m "feat: add horse v4.0.0"
```

To check and update git-host dependencies by hand, use `lwpt outdated` followed
by `lwpt update`. To schedule the same transaction and receive one pull request
with safely quoted release-note excerpts, call the reusable
[`lwpt-update.yml` workflow](./ci.md#lwpt-dependency-updater).

The dependency name defaults to the repo / path basename (`horse` here); pass `--name <name>` to override it (required for `https://` tarball sources). The manifest is only written after the install succeeded, so a typo'd repo or dead tag leaves `lwpt.toml` untouched. Equivalent manual path: edit `lwpt.toml` yourself —

```toml
[dependencies]
horse = "HashLoad/horse@^4.0.0"   # see ADR-0009 for the full source-spec syntax
```

— then run `./build/lwpt install`. The inverse is `./build/lwpt remove horse`, which deletes the manifest entry, regenerates `lwpt.lock` + `lwpt.cfg`, and prunes `.lwpt/modules/horse/` + its cached archive (see [ADR-0019](./adr/0019-add-remove-subcommands.md)).

`.lwpt/modules/horse/` and `.lwpt/archives/horse-v3.0.0.tar.gz` are committed because of zero-install (ADR-0002). The next contributor's `git clone` doesn't need to run `lwpt install` — `./build/lwpt build` reads the already-committed `lwpt.cfg` and compiles directly.

Source kinds for v1: `github`, `gitlab`, `bitbucket`, `release`, `local`. See [`code-style.md`](./code-style.md) for the manifest grammar.

## Writing a test

`TestingPascalLibrary` lives in the `testing` workspace package; add it to your manifest (or rely on the auto-discovery glob in a monorepo) and run install:

```toml
# lwpt.toml — non-monorepo consumer
[dependencies]
testing = "frostney/lwpt-testing@^1.0.0"   # Phase 2 form, post-graduation
# or, until Phase 2 lands:
testing = { source = "frostney/lwpt@^0.1.0", include = ["packages/testing/**"] }
```

Include filters keep the repo-relative path prefix, so the filtered tree lands at `.lwpt/modules/testing/packages/testing/…`. That's fine: the resolver finds the package's `lwpt.toml` wherever it sits in the module tree (the shallowest one wins; if two manifests tie at the same minimal depth there is no defensible winner, so the resolver falls back to manifest-less module-root behavior — `-Fu`/`-Fi` point at the module root and no transitive deps are walked), reads its `units` array, and emits `-Fu`/`-Fi` paths relative to the module root — no extra configuration in the consumer manifest.

```toml
# lwpt.toml — monorepo: packages/testing/ already discovered
[workspaces]
include = ["packages/*"]
```

```sh
./build/lwpt install
```

`lwpt install` publishes the package's validated snapshot into `.lwpt/modules/testing/`; commit that snapshot alongside the other deps (it's part of zero-install per ADR-0002). Re-run install after changing the workspace source.

Create a co-located test next to the unit it covers, e.g. `source/MyUnit.Test.pas`:

```pascal
program MyUnit.Test;
{$mode delphi}{$H+}
uses
  TestingPascalLibrary,
  MyUnit;

type
  TMyUnitTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAdds;
  end;

procedure TMyUnitTests.TestAdds;
begin
  Expect<Integer>(MyAdd(2, 2)).ToBe(4);
end;

procedure TMyUnitTests.SetupTests;
begin
  Test('addition works', TestAdds);
end;

begin
  TestRunnerProgram.AddSuite(TMyUnitTests.Create('MyUnit'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
```

Then:

```sh
./build/lwpt test           # discovers MyUnit.Test.pas, compiles, runs, reads exit code
```

The full test policy (unit, integration, E2E, and manual groups; fixture rules;
mock HTTP server; and the binary-fetch regression) is in
[`testing.md`](./testing.md).

## Common errors

**`bootstrap.sh: instantfpc not found; falling back to direct fpc`** — informational. Both code paths produce the same `build/lwpt`; the fallback just skips the InstantFPC wrapper.

**`lwpt install: dependency "<name>": the legacy manifest shape ... is no longer supported`** — per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md): no more `source = "github|gitlab|..."` selector, no separate `repo` / `ref` / `tag` / `path` keys. Rewrite as a bare-string shorthand or a slim inline table:

```toml
[dependencies]
foo = "owner/foo@v1.2.3"                                           # bare-string
bar = { source = "owner/bar", version = "^1.0", include = ["src/**"] } # inline-table
```

**`lwpt install: source = "http" is a legacy kind selector`** — same migration. The current syntax puts the locator in the source value: `"https://example.com/foo.tar.gz"` for an arbitrary tarball.

**`lwpt install: CONFLICT on package "X"`** — two requirers want incompatible versions of the same package; FPC's single global unit namespace forbids both. The output names both requirers — edit the manifest tree to align them.

**`HTTPS requires OpenSSL but it could not be loaded` (Linux only)** — install your distro's libssl package (`apt install libssl3` / `dnf install openssl-libs` / `apk add openssl3-libs`). LWPT loads it via `dlopen` at runtime. Windows + macOS do not hit this path (SChannel / SecureTransport are built into the OS — see [ADR-0016](./adr/0016-tls-backend-per-platform.md)).

**`[frozen] missing extracted module for "<name>"`** — `lwpt install --frozen` requires `.lwpt/modules/<name>/` to be present. Run `lwpt install` (without `--frozen`) to fetch.

**`[offline] verified archive for "<name>" is unavailable`** — neither the
committed project archive nor the shared content-addressed cache contains the
archive hash recorded in `lwpt.lock`. Restore the committed archive or run
`lwpt install` online once to seed verified content.

**Pre-commit hook auto-formatted files unexpectedly** — the hook runs `lwpt format` and `lwpt agents` with `stage_fixed: true`, so any drift (source formatting, the AGENTS.md agents block) gets rewritten + re-staged into the same commit. Review the staged diff before pushing.

**Recovery from a crashed install:**

```sh
./build/lwpt repair
```

Cleans `.lwpt/tmp/`, any stale install lock, and abandoned or failed sessions
from the default and identity-verified historical build-session roots, then
reclaims abandoned per-user worker requests and reports the remaining budget
state. Live build/test sessions are retained.
Repair never touches `.lwpt/modules/`, `.lwpt/archives/`, or the last
successfully published build output.
