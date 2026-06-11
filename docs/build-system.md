# Build system

The contract LWPT's build system satisfies, the self-host pattern that makes `lwpt` build `lwpt`, the bootstrap that breaks the chicken-and-egg, and the `[build]` manifest shape that downstream consumers use.

## Executive Summary

- **The contract:** single entry point from repo root (`./build/lwpt build`), default target = clean dev build of every binary, named targets as positional args, `--mode dev` (default) / `--mode release`, `--clean` flag, single `build/` output directory.
- **Self-host.** LWPT's own `lwpt.toml` declares `lwpt` as a `[build]` entry; `lwpt build` rebuilds the binary that just ran. See [ADR-0005](./adr/0005-self-host-build.md).
- **Bootstrap once per fresh clone.** `scripts/bootstrap.pas` (via `bootstrap.sh` / `bootstrap.bat`) produces the first `build/lwpt`. The script's `fpc` flags must stay in sync with the dev branch of `AddBuildModeFlags` in `LWPT.Command.Build`.
- **Build outputs land under `build/`.** Gitignored. FPC intermediates (`.o`, `.ppu`) are isolated per target and mode under `build/targets/<name>/<mode>/` via `-FU`; binaries land at the manifest `output` path via `-o`.
- **Cross-compile via `FPC_TARGET_CPU`** env var; `lwpt build` translates this into FPC's `-P` flag.
- **Generator hooks** are declared in `[prebuild]` / `[postbuild]` / `[pretest]` per [ADR-0011](./adr/0011-build-lifecycle-hooks.md); each entry runs via InstantFPC with staleness gating (output older than any input → re-run). The earlier `[generated]` shape is no longer parsed.

## The contract

Every project on this stack satisfies the build-system contract from `native-nostalgia-stack`:

| Contract item | How LWPT satisfies it |
| --- | --- |
| Single entry point from repo root | `./build/lwpt build` |
| Default target = clean dev build of every binary | `lwpt build` (no args) builds every `[build]` entry in dev mode |
| Named targets, positional args | `lwpt build cli` builds only `cli`; multiple targets supported by passing more positionals |
| Dev / prod distinction | `--mode dev` (default) / `--mode release` |
| `clean` as a target | `--clean` flag; combined: `lwpt build --clean cli` cleans then builds `cli` |
| Single `build/` output directory | All binaries land at `<target>.output` which is conventionally under `build/`; intermediates per target + mode via `-FU build/targets/<name>/<mode>/` |

## Self-host

LWPT's own `lwpt.toml` registers itself:

```toml
[package]
name = "lwpt"
version = "0.1.0"
units = ["source"]

[build]
lwpt = { source = "source/lwpt.pas", output = "build/lwpt" }
```

`./build/lwpt build` invokes FPC with:

- `-Sh` (Delphi-compatible string handling; objfpc/delphi-safe)
- `-FE build` (exe fallback for targets whose `output` has no dir component)
- `-FU build/targets/lwpt/<mode>` (per-target, per-mode unit output; overrides `-FE` for `.ppu`/`.o` only)
- `@lwpt.cfg` (the cfg emitted by `lwpt install`; lists `-Fu source` since `units = ["source"]`)
- `-Fu source` (also added explicitly from `Man.Units`; redundant with the cfg but harmless)
- The dev-mode flags from `AddBuildModeFlags` (or release flags when `--mode release`)
- `-o build/lwpt` (the target's output)
- `source/lwpt.pas`

The full mode-flag sets are in `LWPT.Command.Build.AddBuildModeFlags`:

| Mode | Flags |
| --- | --- |
| `dev` (default) | `-O- -gw -godwarfsets -gl -Ct -Cr -Sa` |
| `release` (`--mode release`) | `-O4 -dPRODUCTION -Xs -CX -XX -B` |

`--clean` deletes the prior binary, the target's whole artefact dir `build/targets/<name>/` (both modes), and the `.o` / `.ppu` next to the source before invoking FPC. It also prunes orphaned `build/targets/` subdirs left behind by renamed or deleted targets. Combined with dev mode it also adds `-B` to force a full rebuild (release mode includes `-B` already).

### The current-executable special-case

`lwpt build --clean lwpt` on Windows would try to delete the currently-running `build\lwpt.exe` before rebuilding. Windows file locks prevent that. **(Status: not yet handled; on Unix `unlink(2)` of the running binary works because the inode survives until close, so the rebuild produces a new inode at the same path.)** The special-case for Windows lives in `BuildOneTarget` when needed.

## Bootstrap

The chicken-and-egg: `lwpt build` requires `build/lwpt` to already exist, but `build/lwpt` is produced by `lwpt build`. The resolution is a one-time bootstrap step:

```sh
./bootstrap.sh         # Unix
bootstrap.bat          # Windows
```

Both wrappers:

1. Check whether `instantfpc` is on `PATH`.
2. If yes, run `scripts/bootstrap.pas`, which invokes `fpc -Mdelphi -Sh <dev-flags> -FE build -Fu source -Fi source -Fu packages/<name>/source -Fi packages/<name>/source ... -o build/lwpt source/lwpt.pas` (one `-Fu` / `-Fi` pair per workspace package: `httpclient`, `cli`, `semver`, `toml`, `testing`) to produce the binary.
3. If `instantfpc` is not found, the wrapper falls back to a direct `fpc` invocation with the same flag set.

Both code paths are dev-mode only; release builds always go through `./build/lwpt build --mode release`.

An earlier bootstrap script also regenerated `source/LWPT.Embedded.TestingLibrary.inc` when `TestingPascalLibrary.pas` or `Shared.inc` were newer than the embedded blob. [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) deleted the embed model — the testing framework now lives in `packages/testing/` and is consumed via workspace auto-discovery like every other dep, so the staleness check is gone and the bootstrap script does one thing.

### Why a Pascal bootstrap and not pure shell

Both code paths produce the same binary; the InstantFPC wrapper exists so the bootstrap stays in the project's primary language (per the scripts rule in `project-structure`). The shell + batch fallbacks are duplicates of the same `fpc` invocation, kept as a defensive measure for environments where InstantFPC is unavailable.

### Flag synchronisation

The dev-mode flags in `scripts/bootstrap.pas` are the same set as `AddBuildModeFlags`'s dev branch. They must stay in sync: when one changes, the other changes in the same commit. A future small refactor will lift them into a shared `scripts/bootstrap-flags.inc` `{$I}`-included from both sites; for now, a comment in `scripts/bootstrap.pas` names the requirement.

## `[build]` shape

```toml
[build]
mybin = { source = "src/app.pas",     output = "build/mybin" }
cli   = { source = "src/cli/main.pas" }           # output defaults to source path without ext
shortform = "src/quicktool.pas"                   # bare-string shorthand
```

- `source` (required): the program/`.dpr`/`.pas` file FPC compiles.
- `output` (optional): the binary path; defaults to `ChangeFileExt(source, '')`. On Windows, `.exe` is appended automatically when missing.
- Target names become path segments under `build/targets/`, so the names `""`, `"."`, and `".."` (expressible as quoted TOML keys) are rejected at manifest load — for the project's own manifest only; a dependency's `[build]` section is parse-and-dropped and never built, so it is not validated (a broken dep manifest must not block `lwpt install`). Path separators and `:` in a name are sanitised to `_` for the artefact dir, and two targets whose names sanitise to the same dir (e.g. `"a:b"` and `a_b`) are rejected before anything builds.

LWPT's own `lwpt.toml` is the reference: one `lwpt` target.

## `build/` output directory

Per the contract, everything generated by the build lands under `build/` and is gitignored. Compiled `.o` + `.ppu` files go to a **per-target, per-mode** unit-output dir, `build/targets/<name>/<mode>/`, via FPC's `-FU` flag (`<mode>` is `dev` or `release`). Binaries from `[build]` entries land at their `output` path via `-o`, which by convention is also under `build/`; `-FE build/` stays as the exe fallback for outputs without a directory component.

The isolation exists because FPC reuses a `.ppu` without re-checking the conditional defines it was compiled under: per-target `prebuild:<name>` hooks can regenerate shared sources between targets in one run, and a dev build must never silently link units compiled `-O4` by an earlier release build (or vice versa). One target/mode's artefacts are invisible to every other.

The trade-off is deliberate: shared units compile once per target instead of once per run. Correctness over warm-cache sharing — FPC is fast enough that this does not hurt.

When you run `lwpt build --clean`, the binary at `output` is deleted along with the target's whole `build/targets/<name>/` dir, and orphaned `build/targets/` subdirs (renamed or deleted targets) are pruned. The `.o` / `.ppu` next to the source are also deleted — that pair is load-bearing, not cosmetic: source dirs sit on `-Fu`, so a stale `.ppu` there (from a raw `fpc @lwpt.cfg` run) would poison rebuilds. Leftover artefacts in the `build/` root (pre-isolation layout, bootstrap) are deliberately *not* swept: `build/` is on no unit search path, so they are inert.

## Cross-compile

```sh
FPC_TARGET_CPU=aarch64 ./build/lwpt build --mode release
```

`BuildOneTarget` reads the env var and passes `-P<value>` to FPC. The standard FPC cross-CPU values apply (`x86_64`, `aarch64`, `i386`, `arm`, etc.). Cross-OS via `FPC_TARGET_OS` is **not** wired today; add it if a real use case emerges.

## Generator hooks (formerly `[generated]`)

An earlier `[generated]` section was replaced by the lifecycle-hook model in [ADR-0011](./adr/0011-build-lifecycle-hooks.md). Each entry is a named hook in `[prebuild]` / `[postbuild]` / `[pretest]` / etc. with explicit `script`, `inputs`, and `output` fields, and a staleness gate (run iff output is older than any input):

```toml
[prebuild]
build-foo = { script = "scripts/bar.pas",
              inputs = ["a.pas", "b.pas"],
              output = "source/Foo.inc" }
```

`lwpt build` (and `lwpt test`, for `[pretest]`) walks each hook before the phase runs. If the output is missing or any input is newer than the output, the script is re-run via InstantFPC. The generator consumes its inputs and rewrites its output; no arguments are passed unless the manifest declares them.

If `instantfpc` is not on `PATH`, the failure names the generator script and recommends installing InstantFPC (bundled with FPC).

LWPT's own root manifest previously carried a paired `[prebuild]` + `[pretest]` `embed-testing-library` hook that regenerated `source/LWPT.Embedded.TestingLibrary.inc`. [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) removed the embedded-blob model + the hook; today's root manifest declares no hooks at all.

## Pre-commit hook (Lefthook)

The pre-commit gate at the repo root in `lefthook.yml` runs one command:

| Command | Glob | Fires on |
| --- | --- | --- |
| `format` | `*.{pas,inc,dpr,toml}` | Any staged Pascal source or manifest |

The hook uses `stage_fixed: true`, so any file the formatter rewrites is auto-staged back into the same commit — local pre-commit never blocks unless the formatter cannot parse a file.

Install once per fresh clone:

```sh
lefthook install
```

The heavyweight gates — `lwpt format --check` + `lwpt build` + `lwpt test` — run on the PR workflow in CI (`.github/workflows/pr.yml`) rather than every local commit. This keeps local commits fast and the pre-merge gate strict.

Do **not** bypass with `git commit --no-verify` unless a maintainer explicitly authorises it on the PR.

The four deferred stack contracts (link-check, duplication, codebase-health, architectural-drift) are explicitly *not* in the v1 pre-commit gate per [ADR-0006](./adr/0006-stack-contracts-deferred-from-v1.md). They plug in as additional commands when their workstreams land.
