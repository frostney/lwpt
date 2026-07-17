# Tooling

Pinned tool versions, environment variables, lint/format/test commands, OpenSSL stories per platform, EXDEV fallback, and where each deferred stack-contract item lives.

## Executive Summary

- **FPC 3.2.2 is pinned for v1.** Verify live with `fpc -iV` before any change that depends on FPC behavior — memory and prior conversation are not acceptable sources.
- **Lefthook 2.x runs the pre-commit hook.** Local pre-commit runs `lwpt format` (auto-fix, with `stage_fixed: true`); the heavyweight gates (`lwpt build` + `lwpt test` + `lwpt format --check`) run on the PR workflow in CI. Install with `lefthook install`.
- **Build configuration uses the worker-budget environment too.** Alongside
  `LWPT_CACHE_DIR`, `FPC_TARGET_CPU`, and `PATH`, builds consume the
  `LWPT_WORKER_*` settings below. `--jobs=<n>` is the invocation ceiling; the
  machine budget remains authoritative across processes and worktrees.
- **Worker capacity is coordinated across worktrees.** The internal worker-budget module uses per-user, reclaimable filesystem leases. Its default budget is the host's logical processor count; `LWPT_WORKER_BUDGET` overrides it.
- **TLS backend is platform-native.** SChannel on Windows, SecureTransport on macOS — both built into the OS, no DLLs to bundle. Linux uses the distro's libssl package (system OpenSSL via `dlopen`). Per [ADR-0016](./adr/0016-tls-backend-per-platform.md).
- **EXDEV-rename failures fall back to copy-then-delete.** When `.lwpt/tmp/` and `.lwpt/modules/` end up on different filesystems (Docker bind mounts, network drives), the atomic-rename helpers (`AtomicMoveFile`, `AtomicMoveDir`) automatically fall back to a copy followed by delete.
- **Compiler outputs are session-private.** Build and test invocations write
  below `.lwpt/sessions/<session-id>/`; only a successful, revalidated build
  result is atomically published to its manifest output.
- **Three customer-facing stack contracts are owed but deferred.** Per [ADR-0006](./adr/0006-stack-contracts-deferred-from-v1.md), link-check, duplication, and codebase-health each have a follow-up workstream. Architecture drift is instead a project-local release-preparation check for LWPT itself; it is not a customer feature.

## Pinned versions

| Tool | Pinned for v1 | Verify with |
| --- | --- | --- |
| FreePascal | 3.2.2 | `fpc -iV` |
| InstantFPC | bundled with FPC | `instantfpc --help` |
| Lefthook | 2.x | `lefthook version` |
| git-cliff | Verify the installed release live | `git-cliff --version` |
| OpenSSL (Linux runtime only) | 3.x via distro libssl | `openssl version` (Windows + macOS use SChannel / SecureTransport instead) |

When you touch code that depends on the version, **verify it live, not from memory.** The Hard Constraint in `AGENTS.md` is explicit about this. If you bump a version, the new pin lives in this file and in the relevant CI workflow.

## Pre-commit hook

Lefthook config (`lefthook.yml`):

```yaml
pre-commit:
  commands:
    format:
      glob: "*.{pas,inc,dpr,toml}"
      run: ./build/lwpt format
      stage_fixed: true
```

The local hook runs only the formatter (with `stage_fixed: true` so any rewrite is re-staged into the same commit). The heavyweight checks — `lwpt build` + `lwpt test` — run on the PR workflow rather than every local commit, keeping local commits fast and the pre-merge gate strict.

Install once per fresh clone: `lefthook install`.

Do **not** use `--no-verify` unless a maintainer explicitly authorises it on the PR.

## Environment variables

| Variable | Effect | Default |
| --- | --- | --- |
| `LWPT_CACHE_DIR` | Reserved for [issue #30](https://github.com/frostney/lwpt/issues/30). Today: ignored. | n/a until the cache implementation lands |
| `LWPT_WORKER_BUDGET` | Maximum aggregate LWPT workers for this user and machine | logical processor count |
| `LWPT_WORKER_STATE_DIR` | Override the per-user coordinator state root | the platform application-config directory's `workers/` subdirectory |
| `LWPT_WORKER_LEASE_STALE_SECONDS` | Mark heartbeat diagnostics stale after this interval; values below 3 are rejected. Heartbeat age never authorises reclamation by itself. | `30` |
| `LWPT_WORKER_LEASE_TOKEN` | One-shot opaque delegation token added to one nested LWPT subprocess by the worker-budget API; do not configure, reuse, or persist manually | unset |
| `FPC_TARGET_CPU` | When set, `lwpt build` passes `-P<value>` to FPC for cross-compilation | unset (host CPU) |
| `PATH` | Must contain `fpc`, `instantfpc`, `lefthook` | system default |
| `LWPT_BUILD_TARGET` | Per-target postbuild hook context: selected target name | supplied by LWPT |
| `LWPT_BUILD_OUTPUT` | Per-target postbuild hook context: session-private candidate path; transform this file before publication | supplied by LWPT |
| `LWPT_BUILD_PUBLIC_OUTPUT` | Per-target postbuild hook context: requested manifest output path | supplied by LWPT |

## Machine-wide worker budget

`LWPT.WorkerBudget` provides the capacity seam used by parallel schedulers.
`lwpt build` acquires one lease per active target compiler, while `lwpt test`
requests up to one worker per runnable test. Both are capped by the effective
machine budget, and `--jobs=N` sets a smaller invocation request.

Each invocation registers a session request in a per-user state root shared by
all worktrees. The effective budget is the first invocation's configured
`LWPT_WORKER_BUDGET`, or the logical processor count when unset. Later
invocations adopt that active budget until all current requests finish. A
request cannot hold more than its own requested worker count or the effective
machine budget.

Short state transactions use `fcntl` on Unix and `LockFileEx` on Windows. Each
active request has a lifetime owner guard held by the operating system and
records its diagnostic PID, requested and granted workers, FIFO wait ticket,
lease-token hashes, pending delegation verifiers, start time, lease start, and
heartbeat. Each acquisition gets a new ticket, so releasing and reacquiring
never jumps ahead of an existing waiter. Owner death releases the guard and
allows immediate reclamation without relying on the PID, so PID reuse cannot
preserve a dead request. A stale heartbeat is reported but never authorises
reclamation while the owner guard remains held. Unreadable, malformed, and
unknown-schema requests with a live owner guard reserve capacity
conservatively rather than being deleted.

Nested LWPT subprocesses inherit capacity explicitly with
`AppendWorkerLeaseEnvironment`. It adds a cryptographically random,
one-shot `LWPT_WORKER_LEASE_TOKEN` to one child environment. The coordinator
stores only its verifier and atomically consumes it by transferring one grant
from the parent request to the child's own owner-guarded request. The parent
lease becomes locally unavailable and the parent reacquires through the FIFO
after the child finishes. Reuse and fan-out from one lease fail. The raw token
is never persisted or logged. The child clears the consumed token from its
process environment before running work, so unrelated descendants do not
inherit a dead delegation. The child remains counted independently if the
parent exits. Tokens are not command-line arguments, diagnostics, or project
configuration.

Session-local lease lists and counters are protected for concurrent scheduler
threads. Acquisitions join the FIFO queue serially and releases update durable
coordinator state before changing local state, so an explicit release can be
retried after a lock or atomic-write failure. Scheduler threads must join before
destroying their shared session.

`lwpt repair` now reclaims abandoned worker requests and prints diagnostics for
the remaining coordinator state. The report identifies session IDs, PIDs,
granted capacity, waiting state, lease age, heartbeat age, effective budget,
and state-root path.

## TLS backend per platform

Per [ADR-0016](./adr/0016-tls-backend-per-platform.md), the `TransportSecurity` unit (in `packages/httpclient/source/`) selects the TLS implementation by FPC conditional — each platform uses what ships with the OS:

- **Windows.** **SChannel** via `sspi.dll` / `secur32.dll` (Windows API; built into every Windows install since Windows 2000). No DLLs to install, no DLLs in the release archive. A CI guard (`pr.yml` windows-cross-compile job + `ci.yml` test job + `release.yml` build job) fails the build if `lwpt.exe` accidentally references `libssl` / `libcrypto`.
- **macOS.** **SecureTransport** via Apple's framework (built into every macOS install). No Homebrew dependency, no `DYLD_LIBRARY_PATH` setup.
- **Linux** (and other Unix-not-Darwin). **System OpenSSL** loaded at runtime via `DynLibs.LoadLibrary`. Install the distro's libssl package: `apt install libssl3` / `dnf install openssl-libs` / `apk add openssl3-libs` / equivalent. No special configuration beyond that — the library is usually already present (every distro pulls it in transitively via `curl`, `git`, `wget`, etc.).

If `lwpt install` fails on Linux with `HTTPS requires OpenSSL but it could not be loaded`, install the distro's libssl package. Windows + macOS never hit this path. Documented in [`quick-start.md`](./quick-start.md).

## Atomic writes + EXDEV rename fallback

Every committed-path write in LWPT goes through `.lwpt/tmp/` first. The helpers in `LWPT.Core` are:

| Helper | Used by |
| --- | --- |
| `AtomicWriteText(Dst, TmpRoot, StringList)` | `WriteLock`, `WriteCfg` |
| `AtomicWriteBytes(Dst, TmpRoot, Bytes)` | `FetchToCache` (network archive download) |
| `AtomicMoveFile(Src, Dst)` | The underlying rename for the two helpers above |
| `AtomicMoveDir(Src, Dst)` | `ResolveGraph` (extracted-tree commit) |

On the same filesystem, `rename(2)` is one syscall. Across filesystems (a Docker bind mount of `.lwpt/` onto a different volume; a network drive; certain remote-pair-programming setups), `rename` fails with `EXDEV`. The helpers detect the failure and fall back to **copy-then-delete**: target copied byte-for-byte to its final location, source deleted. Slower, and the copy itself isn't atomic against crash, but the source remains intact until the copy completes — so a crash mid-copy leaves the source in `.lwpt/tmp/` (cleaned up by `lwpt repair` or the next install's startup pass) and never produces a half-written committed file.

If EXDEV failures are persistent and the fallback is too slow, ensure `.lwpt/` lives on the same filesystem as the project root (don't bind-mount it).

## Install lock + crash recovery

`lwpt install` acquires a cross-process lock at `.lwpt/install.lock` before doing any work. On Unix, the file is created with `O_CREAT|O_EXCL` — the kernel guarantees only one process wins the create. A second concurrent `lwpt install` fails fast with `EConcurrencyError` naming the lock holder's PID. The lock is deleted by the normally-completing install; a crashed install leaves the lock file behind, and `lwpt repair` clears it.

A Windows lock via `LockFileEx` lands alongside the Windows CI work. Until that ships, concurrent installs on Windows can race (the file is created but not enforced); the recommendation is to avoid concurrent installs in the same project.

At the start of every install, `.lwpt/tmp/` is wiped — any orphans from a previous interrupted run are reaped automatically. The orphans are never committed (`.lwpt/tmp/` is gitignored) so this is always safe.

## Build sessions and publication

Build and test sessions are project-local and process-owned. Each compiler
invocation receives private executable and unit-output directories. A build
captures a schema-versioned, compiler-neutral publication fingerprint covering
the selected compiler identity, executable, and live version; the requested
source/output/mode/target dimensions; the previous public-output content; and
the manifest, cfg, lockfile, implicit source directory,
source/include/resource paths, and installed modules.

After compilation succeeds, LWPT acquires a short lock derived from the public
output path. A keyed in-process critical section complements the OS-held
advisory byte-range lock on a stable file, so threads and processes both
serialize publication and process exit still releases OS ownership without a
stale-file unlink race. LWPT captures the fingerprint again and refuses
publication if any declared input changed. Search-root hashing excludes
`.lwpt/sessions/` and declared build outputs, follows workspace directory
links with physical cycle detection, and content-hashes directories from
`LWPT_FPC_UNIT_PATHS`; explicit file inputs remain hashed even if also listed
as outputs. A current candidate is replaced with one same-filesystem
atomic rename. Failed and stale candidates never become public and remain
below the session for diagnosis. `--clean` means fresh session staging plus a
forced compiler rebuild; it does not sweep `build/`, delete the running LWPT
executable, or remove another process's output.

Per-target postbuild hooks run before publication with the private candidate
in `LWPT_BUILD_OUTPUT`, the requested path in `LWPT_BUILD_PUBLIC_OUTPUT`, and
the target name in `LWPT_BUILD_TARGET`. Runtime retargeting also maps existing
`{item.output}`-expanded hook fields to the private candidate. Hook failure
keeps the candidate private, and hook definitions, scripts, and declared
inputs are revalidated before publication. For dependency-free manifests, the
whole-build postbuild hook runs against all staged outputs and gates batch
publication. A declared target graph publishes prerequisites progressively;
its whole-build postbuild runs once after all selected outputs publish. Unix lifecycle
hooks use an InstantFPC cache below the owning session. Windows compiles those
hooks directly into the same private hook root. Compiler directories use
bounded readable prefixes plus hashes of their full source identities, so
different paths cannot collide after sanitisation.

Each session holds an OS owner guard from before it becomes visible until its
final metadata and private contents are removed.
`lwpt repair` removes only unlocked sessions and conservatively retains live
guards even when their state file is malformed.

## Deferred from v1

The three customer-facing stack contracts from `project-structure` beyond build-system and formatter:

| Contract | Workstream | Notes |
| --- | --- | --- |
| **Codebase-health** (`lwpt health`) | [Issue #33](https://github.com/frostney/lwpt/issues/33) | Cyclomatic + cognitive complexity; non-zero exit on threshold breach. Per-file aggregate signal + hotspot detection from git churn. |
| **Duplication** (`lwpt duplication`) | [Issue #32](https://github.com/frostney/lwpt/issues/32) | Cross-file and within-file copy-paste reporting. |
| **Link-check** | [Issue #31](https://github.com/frostney/lwpt/issues/31) | Graduates from GocciaScript as a standalone LWPT package; offline + explicit online modes. |

The v1 pre-commit gate excludes all three. ADR-0006 records the original deferral. Architecture drift is checked across LWPT's source, tests, manifests, workflows, documentation, ADRs, and domain context during release preparation; it is not exposed to consumer projects.

## Other deferrals

| Item | Status | Comes back in |
| --- | --- | --- |
| Markdown linting (`markdownlint-cli2` + `.markdownlint-cli2.jsonc`) | Wired in `pr.yml` docs job | Keep blocking; fix Markdown drift rather than making the job advisory |
| Self-hosted origin-and-mirror HTTP registry | Protocol specified in [`registry-spec.md`](./registry-spec.md); implementation tracked in [issue #29](https://github.com/frostney/lwpt/issues/29) | The archived `docs/spikes/http-registry-spike.md` is consumer prior art, not the current protocol |
