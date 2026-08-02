# Tooling

Pinned tool versions, environment variables, lint/format/test commands, OpenSSL stories per platform, EXDEV fallback, and current stack-contract status.

## Executive Summary

- **FPC 3.2.2 is pinned for v1.** Verify live with `fpc -iV` before any change that depends on FPC behavior — memory and prior conversation are not acceptable sources.
- **Lefthook 2.x runs the pre-commit hook.** Local pre-commit runs `lwpt format` and `lwpt agents` with `stage_fixed: true`; the heavyweight gates (`lwpt format --check` + `lwpt build` + `lwpt agents --check` + `lwpt test`) run on the PR workflow in CI. Install with `lefthook install`.
- **Build configuration uses the worker-budget environment too.** Alongside
  `LWPT_CACHE_DIR`, `FPC_TARGET_CPU`, and `PATH`, builds consume the
  `LWPT_WORKER_*` settings below. `--jobs=<n>` is the invocation ceiling; the
  machine budget remains authoritative across processes and worktrees.
- **Worker capacity is coordinated across worktrees.** The internal worker-budget module uses per-user, reclaimable filesystem leases. Its default budget is the host's logical processor count; `LWPT_WORKER_BUDGET` overrides it.
- **TLS clients are platform-native; server accept is asymmetric.** Clients use SChannel on Windows, SecureTransport on macOS, and system OpenSSL on other Unix. The memory-BIO server API requires runtime-loaded OpenSSL 3 or newer on Windows and Unix-not-Darwin; Windows uses a restricted DLL search, and macOS servers use Network.framework. Per [ADR-0016](./adr/0016-tls-backend-per-platform.md) and [ADR-0024](./adr/0024-openssl-server-tls-accept.md).
- **EXDEV-rename failures fall back to copy-then-delete.** When `.lwpt/tmp/` and `.lwpt/modules/` end up on different filesystems (Docker bind mounts, network drives), the atomic-rename helpers (`AtomicMoveFile`, `AtomicMoveDir`) automatically fall back to a copy followed by delete.
- **Compiler outputs are session-private.** Build and test invocations write
  below `.lwpt/sessions/<session-id>/`; only a successful, revalidated build
  result is atomically published to its manifest output.
- **Every resolved subcommand reports completion.** A status-aware elapsed-time
  line is written to stderr after success or failure without changing stdout or
  the command's exit code.
- **Duplication analysis is Pascal-native and offline.** `lwpt duplication`
  reports deterministic Type-2 token clones in manifest-owned root and
  workspace sources. The remaining deferred stack contracts stay tracked
  separately. Architecture drift is a project-local release-preparation check
  for LWPT itself; it is not a customer feature.
- **Codebase health is shipped.** `lwpt health` is an offline Pascal complexity report with opt-in local Git hotspots; [`health.md`](./health.md) owns the scoring and configuration contract.

## Pinned versions

| Tool | Pinned for v1 | Verify with |
| --- | --- | --- |
| FreePascal | 3.2.2 | `fpc -iV` |
| InstantFPC | bundled with FPC | `instantfpc --help` |
| Lefthook | 2.x | `lefthook version` |
| git-cliff | Verify the installed release live | `git-cliff --version` |
| OpenSSL (Unix-not-Darwin and Windows server runtime) | 3.x | `openssl version` on Unix. The Windows server runtime is validated by the CI PE-import guard plus the runtime loadability probe (per [ADR-0024](./adr/0024-openssl-server-tls-accept.md)), not a version CLI. Windows clients and macOS use SChannel / SecureTransport. |

When you touch code that depends on the version, **verify it live, not from memory.** The Hard Constraint in `AGENTS.md` is explicit about this. If you bump a version, the new pin lives in this file and in the relevant CI workflow.

## Command completion timing

Every registered subcommand invocation ends with one status-aware line on
stderr:

```text
lwpt build: completed in 1.24s
lwpt build: failed after 0.03s
```

The duration uses an increasing millisecond clock and is rendered in seconds to
two decimal places. Existing stdout, diagnostics, and exit codes are unchanged.
`lwpt run <subcommand>` reports the resolved subcommand name, so
`lwpt run build` ends with `lwpt build: ...`. Top-level help, version output,
and unknown command names are not resolved subcommand executions and do not get
a completion line. Output suppression is separate planned work tracked in
[issue #127](https://github.com/frostney/lwpt/issues/127).

## Pre-commit hook

Lefthook config (`lefthook.yml`):

```yaml
pre-commit:
  commands:
    format:
      glob: "*.{pas,inc,dpr,toml}"
      run: ./build/lwpt format
      stage_fixed: true
    agents:
      glob: "*.{pas,toml,md}"
      run: ./build/lwpt agents
      stage_fixed: true
```

The local hook refreshes formatting and the generated `AGENTS.md` command reference; both commands re-stage their changes. The heavyweight checks — `lwpt format --check` + `lwpt build` + `lwpt agents --check` + `lwpt test` — run on the PR workflow rather than every local commit, keeping local commits fast and the pre-merge gate strict.

Install once per fresh clone: `lefthook install`.

Do **not** use `--no-verify` unless a maintainer explicitly authorises it on the PR.

## Environment variables

| Variable | Effect | Default |
| --- | --- | --- |
| `LWPT_CACHE_DIR` | Reserved for [issue #30](https://github.com/frostney/lwpt/issues/30). Today: ignored. | n/a until the cache implementation lands |
| `LWPT_WORKER_BUDGET` | Maximum aggregate LWPT workers for this user and machine | logical processor count |
| `LWPT_WORKER_STATE_DIR` | Override the worker coordinator state root; an explicit unwritable path fails rather than falling back | the platform application-config directory's `workers/` subdirectory, with automatic fallback to the repository's `.lwpt/workers/` when that default is unwritable |
| `LWPT_WORKER_LEASE_STALE_SECONDS` | Mark heartbeat diagnostics stale after this interval; values below 3 are rejected. Heartbeat age never authorises reclamation by itself. | `30` |
| `LWPT_WORKER_LEASE_TOKEN` | One-shot opaque delegation token added to one nested LWPT subprocess by the worker-budget API; do not configure, reuse, or persist manually | unset |
| `FPC_TARGET_CPU` | Requested compiler target processor. A non-host value is probed and passed as `-P<value>`; unavailable dispatch fails without fallback. | unset (host CPU) |
| `FPC_TARGET_OS` | Requested compiler target operating system. A non-host value is probed and passed as `-T<value>`; unavailable targets fail without fallback. | unset (host OS) |
| `LWPT_FPC` | Path to the FPC binary; overrides `PATH` lookup. The bare `FPC` variable is honoured as a fallback. | unset (`fpc` on `PATH`) |
| `LWPT_INSTANTFPC` | Path to the InstantFPC binary; overrides `PATH` lookup. The bare `INSTANTFPC` variable is honoured as a fallback. | unset (`instantfpc` on `PATH`) |
| `LWPT_FPC_UNIT_PATHS` | Path-separator-delimited unit directories appended as `-Fu`/`-Fi` to every compile (CI uses it for non-standard FPC installs; see the prose below) | unset |
| `LWPT_HEARTBEAT_INTERVAL_MS` | Diagnostic tuning knob: build/test heartbeat interval; values are clamped to the default ceiling | `30000` |
| `PATH` | Must contain `fpc`, `instantfpc`, `lefthook` | system default |
| `LWPT_BUILD_ENTRY` | Per-entry postbuild hook context: selected build-entry name | supplied by LWPT |
| `LWPT_BUILD_OUTPUT` | Per-entry postbuild hook context: session-private candidate path; transform this file before publication | supplied by LWPT |
| `LWPT_BUILD_PUBLIC_OUTPUT` | Per-entry postbuild hook context: requested manifest output path | supplied by LWPT |

## Machine-wide worker budget

`LWPT.WorkerBudget` provides the capacity seam used by parallel schedulers.
`lwpt build` acquires one lease per actively compiling build entry, while `lwpt test`
requests up to one worker per runnable test. Both are capped by the effective
machine budget, and `--jobs=N` sets a smaller invocation request.

Each invocation registers a session request in a per-user state root shared by
all worktrees. LWPT resolves that root once per process. When the default
application-config path cannot create and remove a unique sentinel file, LWPT
applies the same probe to the current repository's `.lwpt/workers/` directory.
It prints the fallback notice only after that probe passes. If neither root is
writable, LWPT fails with an error directing the user to
`LWPT_WORKER_STATE_DIR`. A valid fallback keeps write-restricted sandboxes
working but forfeits cross-worktree budget sharing. An explicit
`LWPT_WORKER_STATE_DIR` remains authoritative and fails if unwritable. The
effective budget is the first invocation's configured `LWPT_WORKER_BUDGET`, or
the logical processor count when unset. Later invocations adopt that active
budget until all current requests finish. A request cannot hold more than its
own requested worker count or the effective machine budget.

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

- **Windows.** **SChannel** via `sspi.dll` / `secur32.dll` (Windows API; built into every Windows install since Windows 2000) for the client path. No DLLs to install, no DLLs in the release archive. Server accept requires OpenSSL 3 and loads it with `LoadLibraryEx` restricted to system/default directories, excluding the current directory and ordinary `PATH`. CI rejects normal, delay-loaded, renamed, legacy, and static OpenSSL linkage while permitting runtime-loader strings. See [ADR-0024](./adr/0024-openssl-server-tls-accept.md).
- **macOS.** **SecureTransport** via Apple's framework (built into every macOS install). No Homebrew dependency, no `DYLD_LIBRARY_PATH` setup.
- **Linux** (and other Unix-not-Darwin). **System OpenSSL** loaded at runtime via `DynLibs.LoadLibrary`. Install the distro's libssl package: `apt install libssl3` / `dnf install openssl-libs` / `apk add openssl3-libs` / equivalent. No special configuration beyond that — the library is usually already present (every distro pulls it in transitively via `curl`, `git`, `wget`, etc.).

The per-platform selection above is the **client** (outbound) story. The **server accept** path added per [ADR-0024](./adr/0024-openssl-server-tls-accept.md) is nonblocking memory-BIO OpenSSL on Unix-not-Darwin and Windows. It loads a maximum 16 MiB PKCS#12 identity once per listener context, converts passphrases to UTF-8 and wipes temporary copies, installs intermediate certificates, and exposes WANT states plus `tssPeerClosed`. `Active` becomes true only after authentication. Retained ciphertext drains before another protocol operation, its returned span stays stable until consumed, and WANT-write plaintext is retained internally for a nil, zero-length resume call. Consumers must enforce a handshake deadline and byte budget; broader flow control and concurrent context reload remain deferred. macOS servers use Network.framework.

If `lwpt install` fails on Linux with `HTTPS requires OpenSSL but it could not be loaded`, install the distro's libssl package. Windows + macOS never hit this path on the client side. Documented in [`quick-start.md`](./quick-start.md).

## Atomic writes + EXDEV rename fallback

Every committed-path write in LWPT goes through `.lwpt/tmp/` first. The helpers in `LWPT.Core` are:

| Helper | Used by |
| --- | --- |
| `AtomicWriteText(Dst, TmpRoot, StringList)` | `WriteLock`, `WriteCfg` |
| `AtomicWriteBytes(Dst, TmpRoot, Bytes)` | `FetchToCache` (network archive download) |
| `AtomicMoveFile(Src, Dst)` | The underlying rename for the two helpers above |
| `AtomicMoveDir(Src, Dst)` | fixed-point resolver plan publication |

On the same filesystem, `rename(2)` is one syscall. Across filesystems (a Docker bind mount of `.lwpt/` onto a different volume; a network drive; certain remote-pair-programming setups), `rename` fails with `EXDEV`. The helpers detect the failure and fall back to **copy-then-delete**: target copied byte-for-byte to its final location, source deleted. Slower, and the copy itself isn't atomic against crash, but the source remains intact until the copy completes — so a crash mid-copy leaves the source in `.lwpt/tmp/` (cleaned up by `lwpt repair` or the next install's startup pass) and never produces a half-written committed file.

If EXDEV failures are persistent and the fallback is too slow, ensure `.lwpt/` lives on the same filesystem as the project root (don't bind-mount it).

## Install lock + crash recovery

`lwpt install` acquires a cross-process lock at `.lwpt/install.lock` before doing any work. On Unix, the file is created with `O_CREAT|O_EXCL` — the kernel guarantees only one process wins the create. A second concurrent `lwpt install` fails fast with `EConcurrencyError` naming the lock holder's PID. The lock is deleted by the normally-completing install; a crashed install leaves the lock file behind, and `lwpt repair` clears it only after using the validated pending journal to restore pre-transaction committed state.

On Windows, LWPT opens the lock file and holds an exclusive `LockFileEx` byte-range lock for the transaction. A second concurrent install fails fast under the same `EConcurrencyError` contract; normal completion releases the OS lock and removes the file, while `lwpt repair` clears crash residue.

Before publication, old committed paths are copied and content-validated below one pending transaction directory in `.lwpt/tmp/`; they are not removed merely to create a backup. Retention preserves the exact object type, including raw symlink or junction target data instead of copying through links. Successful publication writes a committed marker before discarding those copies. After a crash, `lwpt repair` restores every pending entry before its ordinary tmp sweep. Rollback validates backups before touching the current path, catches each restore exception independently, attempts all later restores, retains failed evidence, and reports aggregate failures alongside the original error. Frozen verification neither performs recovery nor cleans tmp, keeping failure paths read-only for lockfile, cfg, and modules state.

## Build sessions and publication

Build and test sessions are project-local and process-owned. Each compiler
invocation receives private executable and unit-output directories. A build
captures a schema-versioned, compiler-neutral publication fingerprint covering
the selected compiler identity, executable, and live version; the requested
build-entry source/output/mode plus target-tuple dimensions; the previous public-output content; and
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

Per-entry postbuild hooks run before publication with the private candidate
in `LWPT_BUILD_OUTPUT`, the requested path in `LWPT_BUILD_PUBLIC_OUTPUT`, and
the entry name in `LWPT_BUILD_ENTRY`. Runtime retargeting also maps existing
`{item.output}`-expanded hook fields to the private candidate. Hook failure
keeps the candidate private, and hook definitions, scripts, and declared
inputs are revalidated before publication. For dependency-free manifests, the
whole-build postbuild hook runs against all staged outputs and gates batch
publication. A declared build-entry graph publishes prerequisites progressively;
its whole-build postbuild runs once after all selected outputs publish. Unix lifecycle
hooks use an InstantFPC cache below the owning session. Windows compiles those
hooks directly into the same private hook root. Compiler directories use
bounded readable prefixes plus hashes of their full source identities, so
different paths cannot collide after sanitisation.

Each session holds an OS owner guard from before it becomes visible until final
state is written. Successful completion removes compiler jobs and compiled hooks
but retains stable job logs; `lwpt repair` removes only unlocked sessions and
conservatively retains live guards even when their state file is malformed.

## Duplication analysis

`lwpt duplication [--json]` scans only the Pascal files resolved from the
manifest-owned analysis scope. It compares typed regions so a match never spans
a routine or unit-section boundary; executable regions compare only with other
executable regions, and declaration regions only with declarations. Whitespace,
comments, and Pascal letter case are ignored. Identifiers and literals may be
renamed when their token kinds and equality pattern remain consistent, which
makes the detector Type-2 rather than text-only.

Candidates are selected by descending normalized length and stable source
coordinates. The report retains maximal non-overlapping occurrences, including
same-file and cross-file groups, and verifies each new occurrence against every
member already accepted into its clone group. Aggregate duplication is duplicate
tokens beyond each group's first occurrence divided by all analyzed region tokens.
The default minimum is 100 normalized tokens:

```toml
[duplication]
minimum-tokens = 100
# maximum-percent = 5
```

`minimum-tokens` may be lowered to 25, but not below it. `maximum-percent` is
an optional integer from 0 through 100; the command fails only when the observed
percentage is strictly greater than that value. Without a maximum it is
report-only. Root settings are inherited by workspaces; a workspace's own
`[duplication]` table replaces them. The root maximum gates the complete scope,
while workspace maxima also gate duplication internal to that package.
`[analysis].include` and `[analysis].exclude` remain the single source-selection
policy shared with `lwpt health`.

Human output is the default. `--json` writes the versioned shared analysis
envelope plus a duplication-owned payload containing effective project policy,
token totals, clone groups, stable locations, and the threshold outcome. Both
forms are deterministic and the command performs no network operations.

## Analysis command status

ADR-0006 originally deferred several customer-facing stack contracts beyond the
build system and formatter. Duplication analysis and codebase health now ship:

| Contract | Workstream | Notes |
| --- | --- | --- |
| **Codebase-health** (`lwpt health`) | Delivered; see [`health.md`](./health.md) | Deterministic routine/file complexity, optional local Git hotspots, stable JSON, and strict opt-in thresholds. |
| **Duplication** (`lwpt duplication`) | Delivered from [issue #32](https://github.com/frostney/lwpt/issues/32) | Deterministic Type-2 clone reporting across manifest-owned source scope. |

The v1 pre-commit gate excludes these analysis commands; they run on demand or
through an explicit consumer gate. ADR-0006 records the original deferral.
Architecture drift is checked across LWPT's source, tests, manifests,
workflows, documentation, ADRs, and domain context during release preparation;
it is not exposed to consumer projects.

## Other deferrals

| Item | Status | Comes back in |
| --- | --- | --- |
| Markdown linting (`markdownlint-cli2` + `.markdownlint-cli2.jsonc`) | Wired in `pr.yml` docs job | Keep blocking; fix Markdown drift rather than making the job advisory |
| Self-hosted origin-and-mirror HTTP registry | Protocol specified in [`registry-spec.md`](./registry-spec.md); implementation tracked in [issue #29](https://github.com/frostney/lwpt/issues/29) | The archived `docs/spikes/http-registry-spike.md` is consumer prior art, not the current protocol |
