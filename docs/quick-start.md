# Quick start

The top-to-bottom walkthrough for getting from `git clone` to passing tests on a fresh machine.

## Executive Summary

- **Bootstrap is one command, run once.** `./bootstrap.sh` (or `bootstrap.bat` on Windows) produces `build/lwpt` from `source/lwpt.pas`. After that, `./build/lwpt build` is the canonical build entry point.
- **No `lwpt install` needed after clone.** Per [ADR-0002](./adr/0002-lwpt-namespace-zero-install.md) every LWPT project commits `.lwpt/modules/` and `.lwpt/archives/`; `fpc @lwpt.cfg` works without LWPT being involved.
- **Two prerequisites:** FPC 3.2.2 (with InstantFPC bundled) and Lefthook for pre-commit hooks. TLS is platform-native (SChannel on Windows, SecureTransport on macOS, system OpenSSL on Linux — per [ADR-0016](./adr/0016-tls-backend-per-platform.md)); no DLLs to bundle.
- **A new test is one `.Test.pas` file.** Add `testing` to `[dependencies]` (or rely on workspace auto-discovery in a monorepo), run `lwpt install` once, then write `program <Name>.Test;` files using `TestingPascalLibrary`. `lwpt test` discovers and runs them.
- **Pre-commit auto-formats.** `lwpt format` runs on every commit via Lefthook and re-stages any rewrites (`stage_fixed: true`). The heavyweight gates (`lwpt build`, `lwpt test`, `lwpt format --check`) run on the PR workflow in CI. Install the local hook once with `lefthook install`.

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
./build/lwpt --help     # top-level help; lists the 9 subcommands
```

## Daily commands

```sh
./build/lwpt build              # dev build, all manifest targets
./build/lwpt build --mode release
./build/lwpt build <target>     # single target
./build/lwpt build --clean      # remove artefacts first, then rebuild

./build/lwpt format             # rewrite sources to canonical style
./build/lwpt format --check     # exit non-zero on any deviation

./build/lwpt test               # discover/compile/run *.Test.pas

./build/lwpt install            # fetch any new deps; rewrite lwpt.lock + lwpt.cfg
./build/lwpt install --frozen   # CI: verify, refuse to update
./build/lwpt add owner/repo@^1.0    # add a dependency + install it (ADR-0019)
./build/lwpt remove <name>      # remove a dependency + prune its modules
./build/lwpt repair             # clean .lwpt/tmp/ + stale install lock
```

[`build-system.md`](./build-system.md) covers each in depth.

## Install the pre-commit hook

Lefthook runs `lwpt format` on every `git commit` with `stage_fixed: true` — any files the formatter rewrites are auto-staged into the same commit, so the local hook never blocks. The heavyweight gates (`lwpt build`, `lwpt test`, `lwpt format --check`) run on the PR workflow on every pull request. Install the local hook once per fresh clone:

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

`lwpt install` symlinks the package into `.lwpt/modules/testing/`; commit the symlink alongside the other deps (it's part of zero-install per ADR-0002).

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

The full test policy (unit / integration / e2e / manual tiers, fixture rules, mock HTTP server, the binary-fetch regression) is in [`testing.md`](./testing.md).

## Common errors

**`bootstrap.sh: instantfpc not found; falling back to direct fpc`** — informational. Both code paths produce the same `build/lwpt`; the fallback just skips the InstantFPC wrapper.

**`lwpt install: dependency "<name>": the legacy manifest shape ... is no longer supported`** — per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md): no more `source = "github|gitlab|..."` selector, no separate `repo` / `ref` / `tag` / `path` keys. Rewrite as a bare-string shorthand or a slim inline table:

```toml
[dependencies]
foo = "owner/foo@v1.2.3"                                           # bare-string
bar = { source = "owner/bar", version = "^1.0", subdir = "src" }   # inline-table
```

**`lwpt install: source = "http" is a legacy kind selector`** — same migration. The current syntax puts the locator in the source value: `"https://example.com/foo.tar.gz"` for an arbitrary tarball.

**`lwpt install: CONFLICT on package "X"`** — two requirers want incompatible versions of the same package; FPC's single global unit namespace forbids both. The output names both requirers — edit the manifest tree to align them.

**`HTTPS requires OpenSSL but it could not be loaded` (Linux only)** — install your distro's libssl package (`apt install libssl3` / `dnf install openssl-libs` / `apk add openssl3-libs`). LWPT loads it via `dlopen` at runtime. Windows + macOS do not hit this path (SChannel / SecureTransport are built into the OS — see [ADR-0016](./adr/0016-tls-backend-per-platform.md)).

**`[frozen] missing extracted module for "<name>"`** — `lwpt install --frozen` requires `.lwpt/modules/<name>/` to be present. Run `lwpt install` (without `--frozen`) to fetch.

**Pre-commit hook auto-formatted files unexpectedly** — the hook runs `lwpt format` with `stage_fixed: true`, so any drift gets rewritten + re-staged into the same commit. Review the staged diff before pushing.

**Recovery from a crashed install:**

```sh
./build/lwpt repair
```

Cleans `.lwpt/tmp/` and any stale install lock; never touches `.lwpt/modules/` or `.lwpt/archives/`.
