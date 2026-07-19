# Build system

The contract LWPT's build system satisfies, the self-host pattern that makes `lwpt` build `lwpt`, the bootstrap that breaks the chicken-and-egg, and the `[build]` manifest shape that downstream consumers use.

## Executive Summary

- **The contract:** single entry point from repo root (`./build/lwpt build`), default target = clean dev build of every binary, named targets as positional args, `--mode dev` (default) / `--mode release`, `--clean` flag, single `build/` output directory.
- **Self-host.** LWPT's own `lwpt.toml` declares `lwpt` as a `[build]` entry; `lwpt build` rebuilds the binary that just ran. See [ADR-0005](./adr/0005-self-host-build.md).
- **Bootstrap once per fresh clone.** `scripts/bootstrap.pas` (via `bootstrap.sh` / `bootstrap.bat`) produces the first `build/lwpt`. The script's `fpc` flags must stay in sync with the dev branch of `AddBuildModeFlags` in `LWPT.Command.Build`.
- **Compiler output is invocation-private.** FPC executables and intermediates
  first land under `.lwpt/sessions/<session-id>/`. A completed executable is
  atomically published to its manifest `output` only after its declared inputs
  are revalidated.
- **Cross-compile via `FPC_TARGET_CPU`** env var; `lwpt build` translates this into FPC's `-P` flag.
- **Compiler-neutral request first.** Build and test compilation validate a versioned request and target tuple before the current FPC-specific argument adapter runs. Unsupported schemas and capability combinations are hard errors, with no compiler or target fallback.
- **Dependency-aware parallel builds.** Independent ready targets run in
  parallel by default, bounded by `--jobs=<n>` and the machine-wide
  `LWPT.WorkerBudget`. `--jobs=1` is the sequential escape hatch. See
  [ADR-0023](./adr/0023-parallel-build-target-scheduler.md).
- **Generator hooks** are declared in `[prebuild]` / `[postbuild]` / `[pretest]` per [ADR-0011](./adr/0011-build-lifecycle-hooks.md); each entry runs via InstantFPC with staleness gating (output older than any input → re-run). The earlier `[generated]` shape is no longer parsed.

## The contract

Every project on this stack satisfies the build-system contract from `native-nostalgia-stack`:

| Contract item | How LWPT satisfies it |
| --- | --- |
| Single entry point from repo root | `./build/lwpt build` |
| Default target = clean dev build of every binary | `lwpt build` (no args) builds every `[build]` entry in dev mode |
| Named targets, positional args | `lwpt build cli` builds only `cli`; multiple targets supported by passing more positionals |
| Bounded parallelism | Ready targets overlap by default; `--jobs=<n>` sets the invocation ceiling and the machine worker budget may lower it |
| Dev / prod distinction | `--mode dev` (default) / `--mode release` |
| `clean` as a target | `--clean` flag; combined: `lwpt build --clean cli` forces a full compile in fresh private staging |
| Single public output directory | Completed binaries land at `<target>.output`, conventionally under `build/`; compiler intermediates remain session-private |

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
- `-FE .lwpt/sessions/<session>/jobs/lwpt-<mode>/bin`
- `-FU .lwpt/sessions/<session>/jobs/lwpt-<mode>/units`
- `@lwpt.cfg` (the cfg emitted by `lwpt install`; lists `-Fu source` since `units = ["source"]`)
- `-Fu source` (also added explicitly from `Man.Units`; redundant with the cfg but harmless)
- The dev-mode flags from `AddBuildModeFlags` (or release flags when `--mode release`)
- `-o .lwpt/sessions/<session>/jobs/lwpt-<mode>/bin/lwpt`
- `source/lwpt.pas`

After FPC exits successfully, LWPT revalidates the build publication
fingerprint under a short output-specific lock and atomically replaces
`build/lwpt`. The full mode-flag sets are in
`LWPT.Command.Build.AddBuildModeFlags`:

| Mode | Flags |
| --- | --- |
| `dev` (default) | `-O- -gw -godwarfsets -gl -Ct -Cr -Sa` |
| `release` (`--mode release`) | `-O4 -dPRODUCTION -Xs -CX -XX -B` |

`--clean` does not delete shared paths. Every invocation already begins with
empty private staging; clean additionally passes `-B` for dev mode (release
already includes it) to force recompilation. The last successful executable,
another live session, legacy `build/targets/` directories, source-adjacent
artefacts, and the currently running LWPT executable remain untouched.

When a build fails with output matching a stale-artefact signature (internal compiler exception, resource-compile errors, missing `.reslst`), `lwpt build` prints a hint to retry with `--clean`. The signature heuristic lives in `LWPT.Command.Build.HasStaleArtefactSignature`.

### The current executable

Clean never deletes the current executable. Publication uses the platform's
atomic replacement operation (`rename(2)` on Unix and `MoveFileEx` with
replace/write-through on Windows), after the replacement candidate has
finished compiling in its session. If the operating system refuses the
replacement, LWPT reports publication failure and retains the completed
candidate for diagnosis rather than deleting the last successful executable.

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
app   = { source = "src/app/main.pas", depends = ["mybin", "cli"] }
shortform = "src/quicktool.pas"                   # bare-string shorthand
```

- `source` (required): the program/`.dpr`/`.pas` file FPC compiles.
- `output` (optional): the binary path; defaults to `ChangeFileExt(source, '')`. On Windows, `.exe` is appended automatically when missing.
- `depends` (optional): targets that must publish successfully before this
  target starts. Named builds include transitive prerequisites; unknown names
  and cycles fail before build work.
- Target names become job-directory path segments inside a session, so the
  names `""`, `"."`, and `".."` are rejected at manifest load. Each segment
  combines a bounded readable prefix with a hash of the full target identity,
  preventing sanitisation collisions without creating unbounded paths.

LWPT's own `lwpt.toml` is the reference: one `lwpt` target.

## Session staging and public outputs

Every `lwpt build` and `lwpt test` invocation creates a unique
`.lwpt/sessions/s-<pid>-<timestamp>-<counter>-<n>/` directory (PID and
timestamp base36-encoded — the slug prefixes every compiler staging path,
and FPC's file API silently truncates paths over 255 characters, so each
component stays short). Target job directories contain separate `bin/` and
`units/` children used for `-FE`, `-FU`, and `-o`. No two processes share
writable compiler paths, even when they build the same target and mode in
the same worktree. Before compiling, LWPT verifies the staging path plus
the longest reachable unit name fits the 255-character budget and refuses
the compile with an explanatory error when it cannot.

Before compiling, LWPT creates a schema-versioned `TLWPTBuildRequest` covering
the source set and entry point, output kind, mode, defines, search paths,
resources, private output locations, target OS/architecture, and requested
compiler identity/version. The canonical TOML serialization is embedded in a
separate publication fingerprint. That fingerprint also covers the selected
compiler executable/live version,
the previous public-output content, the implicit source directory, declared
unit/include/resource inputs,
manifest, cfg, lockfile, and installed module contents. After compilation it
takes a short output-specific lock, combining an in-process critical section
with an OS-held lock, and captures the same fingerprint again. Search-root
hashing excludes `.lwpt/sessions/` and all declared build outputs, so a project
that declares `units = ["."]` tracks compiler inputs without treating private
staging or another target's publication as an input. Explicit file inputs are
still hashed when they are also declared outputs. Workspace-package
symlinks and junctions are followed, with physical-directory cycle detection.
`LWPT_FPC_UNIT_PATHS` directories are content-hashed as both unit and include
inputs. Changed input, compiler version, or the requested public-output
generation means the result is stale: publication is refused and the candidate
stays private. Per-target postbuild hooks receive `LWPT_BUILD_OUTPUT` for the
private candidate, `LWPT_BUILD_PUBLIC_OUTPUT` for the requested manifest path,
and `LWPT_BUILD_TARGET` for the target name. Existing `{item.output}`
references in their script, arguments, inputs, and staleness output are
retargeted to the private candidate at execution time when the expanded path
is a complete path token. Related paths such as `build/app.json` are not
rewritten. Hook definitions,
scripts, and declared inputs participate in publication revalidation. A hook
failure prevents publication. Dependency-free builds retain whole-build
postbuild as the final gate before batch publication. A declared graph
publishes prerequisites progressively so dependants start only after successful
publication; its whole-build postbuild consequently runs once after all
selected outputs publish. Artifact transformations therefore belong in the
per-target hook. See ADR-0023.

Successful sessions are removed immediately. Failed, stale, or interrupted
sessions remain private and diagnosable. `lwpt repair` removes inactive
sessions only after their OS-held owner guard is absent; malformed state fails
closed while its guard remains held. Artifact reuse is deliberately absent
here and belongs to the content-addressed cache work.

`[version]` include files are staged beside their destination and generated
through true same-filesystem replacement before fingerprinting, so concurrent
builds never expose a missing or partially rewritten
compiler input.

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

`lwpt build` (and `lwpt test`, for `[pretest]`) walks each hook before the phase runs. If the output is missing or any input is newer than the output, the script is re-run via InstantFPC. On Unix, LWPT points InstantFPC at a cache below the owning build/test session; Windows compiles the hook directly into that session. The generator consumes its inputs and rewrites its output; no arguments are passed unless the manifest declares them.

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

The three deferred customer-facing stack contracts ([link-check #31](https://github.com/frostney/lwpt/issues/31), [duplication #32](https://github.com/frostney/lwpt/issues/32), and [codebase-health #33](https://github.com/frostney/lwpt/issues/33)) are explicitly *not* in the v1 pre-commit gate per [ADR-0006](./adr/0006-stack-contracts-deferred-from-v1.md). They plug in when their workstreams land. Architecture drift is instead checked for LWPT itself during release preparation; it is not a consumer command. Parallel, process-safe, observable builds and tests are tracked in [issue #28](https://github.com/frostney/lwpt/issues/28).

## Machine-wide worker capacity

The build scheduler acquires capacity from `LWPT.WorkerBudget` before starting
each compiler process and releases it when that process finishes. The
coordinator bounds aggregate work from several LWPT invocations and worktrees,
not just the `--jobs` value of one process.

The module uses reclaimable filesystem leases with a heartbeat rather than a
permanent counter. A crashed owner therefore cannot leak capacity
indefinitely. Heartbeat age is diagnostic only, so a healthy compiler that
runs longer than the stale threshold keeps its lease while its OS-held owner
guard remains live. FIFO acquisition tickets prevent release/reacquire loops
from jumping existing waiters, and nested LWPT subprocesses consume a one-shot
delegation that transfers one grant to their own guarded request instead of
consuming a second slot. The parent reacquires through the FIFO after the child
finishes. See
[`tooling.md`](./tooling.md#machine-wide-worker-budget) for configuration and
[ADR-0021](./adr/0021-machine-wide-worker-budget.md) for the decision.
