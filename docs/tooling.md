# Tooling

Pinned tool versions, environment variables, lint/format/test commands, OpenSSL stories per platform, EXDEV fallback, and where each deferred stack-contract item lives.

## Executive Summary

- **FPC 3.2.2 is pinned for v1.** Verify live with `fpc -iV` before any change that depends on FPC behavior — memory and prior conversation are not acceptable sources.
- **Lefthook 2.x runs the pre-commit hook.** Local pre-commit runs `lwpt format` (auto-fix, with `stage_fixed: true`); the heavyweight gates (`lwpt build` + `lwpt test` + `lwpt format --check`) run on the PR workflow in CI. Install with `lefthook install`.
- **Three environment variables matter today.** `LWPT_CACHE_DIR` (reserved for opt-in global cache; not used in v1), `FPC_TARGET_CPU` (cross-compile via FPC's `-P` flag), and `PATH` (must contain `fpc`, `instantfpc`, `lefthook`).
- **TLS backend is platform-native.** SChannel on Windows, SecureTransport on macOS — both built into the OS, no DLLs to bundle. Linux uses the distro's libssl package (system OpenSSL via `dlopen`). Per [ADR-0016](./adr/0016-tls-backend-per-platform.md).
- **EXDEV-rename failures fall back to copy-then-delete.** When `.lwpt/tmp/` and `.lwpt/modules/` end up on different filesystems (Docker bind mounts, network drives), the atomic-rename helpers (`AtomicMoveFile`, `AtomicMoveDir`) automatically fall back to a copy followed by delete.
- **Four stack contracts are owed but deferred.** Per [ADR-0006](./adr/0006-stack-contracts-deferred-from-v1.md), the link-check, duplication, codebase-health, and architectural-drift contracts each have a follow-up workstream; the v1 pre-commit gate intentionally does not include them.

## Pinned versions

| Tool | Pinned for v1 | Verify with |
| --- | --- | --- |
| FreePascal | 3.2.2 | `fpc -iV` |
| InstantFPC | bundled with FPC | `instantfpc --help` |
| Lefthook | 2.x | `lefthook version` |
| git-cliff | (deferred to v1.x) | n/a — see "Deferred" below |
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
| `LWPT_CACHE_DIR` | (Reserved.) When the opt-in global cache lands post-v1, this overrides its location. Today: ignored. | `$XDG_CACHE_HOME/lwpt` on Unix, `%APPDATA%\lwpt\cache` on Windows |
| `FPC_TARGET_CPU` | When set, `lwpt build` passes `-P<value>` to FPC for cross-compilation | unset (host CPU) |
| `PATH` | Must contain `fpc`, `instantfpc`, `lefthook` | system default |

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

## Deferred from v1

The four stack contracts from `project-structure` beyond build-system and formatter:

| Contract | Workstream | Notes |
| --- | --- | --- |
| **Codebase-health** (`lwpt health`) | Separate workstream; existing prototype | Cyclomatic + cognitive complexity; non-zero exit on threshold breach. Per-file aggregate signal + hotspot detection from git churn. |
| **Duplication** (`lwpt duplication`) | Separate workstream; existing prototype | Cross-file and within-file copy-paste reporting. |
| **Link-check** | Graduates from GocciaScript as a standalone LWPT package | Markdown link validation; offline + online modes. |
| **Architectural-drift** | Defer to v2 | Docs-vs-code, claims-vs-reality across six surfaces. |

The v1 pre-commit gate excludes all four. Tracked in [ADR-0006](./adr/0006-stack-contracts-deferred-from-v1.md).

## Other deferrals

| Item | Status | Comes back in |
| --- | --- | --- |
| Changelog automation (`git-cliff` + `cliff.toml` + `CHANGELOG.md`) | Deferred per Q11 | v1.x, when release cadence + commit volume warrant it |
| Markdown linting (`markdownlint-cli2` + `.markdownlint-cli2.jsonc`) | Wired in `pr.yml` docs job | Keep blocking; fix Markdown drift rather than making the job advisory |
| HTTP registry source kind | Deferred to v2 per ADR-0004 | v2; spec lives in `docs/spikes/http-registry-spike.md` as starting point |
