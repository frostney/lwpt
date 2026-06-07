# Architecture

How LWPT is shaped: the through-line that ties every subcommand to the manifest, the on-disk layout that makes zero-install work, and the deliberate boundaries we drew during the spike-to-production grilling.

## Executive Summary

- **The package manager is the foundation.** `lwpt install` resolves the dependency graph and writes `lwpt.cfg`; every other subcommand consumes that same cfg. The manifest (`lwpt.toml`) is the single source of truth.
- **Zero-install by default.** `.lwpt/modules/` (extracted) and `.lwpt/archives/` (verification) are committed; a fresh clone is buildable with `fpc @lwpt.cfg` before `lwpt install` is ever run. See [ADR-0002](./adr/0002-lwpt-namespace-zero-install.md).
- **Self-hosting from day one.** LWPT builds LWPT through `lwpt build` against the repo's own manifest; the one-time `scripts/bootstrap.pas` resolves the chicken-and-egg. See [ADR-0005](./adr/0005-self-host-build.md).
- **RTL-only with LWPT-canonical packages.** No third-party FPC dependencies in the binary; HTTPS is `HTTPClient` from LWPT's `packages/httpclient/`. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT is the canonical source for HTTPClient, CLI, Semver, TOML, and TestingPascalLibrary — all consumed as workspace packages via the root manifest's `[workspaces]` glob (Phase 1 done per ADR-0014 + ADR-0015). GocciaScript is the first named consumer and commits to Path A adoption; Phase 2 graduates individual packages to standalone repos when warranted.
- **v1 ships with deliberate deferrals.** HTTP registry source kind (ADR-0004), and the link / duplication / codebase-health / architectural-drift stack contracts (ADR-0006) are each tracked on their own follow-up workstreams rather than shipped half-built.
- **Error handling is production-grade.** Every multi-step write goes through `.lwpt/tmp/` + atomic rename (EXDEV fallback to copy-then-delete), `lwpt install` takes a cross-process lock (`.lwpt/install.lock`, O_CREAT|O_EXCL), `--frozen` verifies both the archive hash and the extracted tree hash against the lockfile, and crash recovery wipes `.lwpt/tmp/` orphans on the next install. See ADR-0002 + ADR-0008.

## Tech stack

- **Compiler:** FreePascal 3.2.2 (`fpc -iV` verified live; see `tooling.md`).
- **Mode:** `delphi` everywhere. Project-owned units (`lwpt.pas`, the `LWPT.*` family, the `CLI.*` family) and the remaining vendored units (`Semver`, `HTTPClient`, etc) all flow through `{$I Shared.inc}` which sets `{$mode delphi} {$H+}`. Several LWPT units additionally enable `{$modeswitch nestedcomments+}` so documentation prose can contain literal placeholder strings (the `{user}` / `{repository}` / `{ref}` substrings) without prematurely closing the surrounding `{ ... }` block.
- **Runtime:** RTL only. No fcl-web, no fphttpclient, no third-party packages. HTTPS depends on system OpenSSL via the vendored `HTTPClient` + `TransportSecurity`.
- **Scripts:** Pascal via InstantFPC (`scripts/bootstrap.pas`). Shell wrappers (`bootstrap.sh`, `bootstrap.bat`) fall back to direct `fpc` when InstantFPC is absent.

## The package-manager-is-the-foundation through-line

```text
                  lwpt.toml  (manifest, hand-edited, single source of truth)
                      │
                      ▼
              ┌──────────────────┐
              │   lwpt install   │  ← resolves deps, fetches into .lwpt/archives/,
              │                  │     extracts into .lwpt/modules/, writes lwpt.lock
              └────┬─────────────┘
                   │
                   ▼
            lwpt.lock           lwpt.cfg     ← FPC response fragment
                                    │           (-Fu lines for every module)
                                    │
        ┌────────────────────┬──────┴──────┬────────────────┐
        ▼                    ▼             ▼                ▼
   lwpt build         lwpt test       lwpt format     lwpt run
   (fpc @lwpt.cfg)    (compile +      (rewrite or     (invoke a
                       run *.Test.pas) check sources)  user-defined
                                                       script)

   ↑ lwpt repair operates on .lwpt/tmp/ + .lwpt/install.lock orthogonally.
   ↑ lwpt init scaffolds a new project (manifest, source dir, optional install/build).
```

The arrow from `lwpt install` to `lwpt.cfg` is the through-line. Every other subcommand reads `lwpt.cfg` (or skips it cleanly if `lwpt install` hasn't run — which only happens during the bootstrap window, since zero-install means consumers commit `lwpt.cfg`). Adding a new subcommand should not require teaching it about every source kind; it just consumes the resolved cfg.

## Manifest model

`lwpt.toml` is partial-TOML — the reader consumed by `LWPT.Manifest` deliberately omits datetimes, multiline strings, and array-of-tables (which is why `[build]` is a table-of-inline-tables, not `[[build]]`). Every section is described in [`code-style.md`](./code-style.md) and the example in the root [`README.md`](../README.md).

Sections currently supported:

| Section | Purpose |
| --- | --- |
| `[package]` | name, version, units (`-Fu` roots from the project's own source) |
| `[dependencies]` | bare-string `"<source>@<version>"` shorthand or inline-table `{ source = "...", version = "...", subdir = "..." }` — see [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md) |
| `[sources]` | per-project custom git-host declarations. Each entry is an inline table mapping a prefix name to `archive` + `git` URL templates with `{user}` / `{repository}` / `{ref}` placeholders; enables prefixes like `gitea:owner/repo` against the user's self-hosted instance |
| `[build]` | one entry per binary; `lwpt build [<entry-name>]` consumes this. Single-binary shorthand: `[build] source = "..."` directly under `[build]` defaults the entry name to `[package].name` |
| `[workspaces]` | `include` / `exclude` glob arrays for monorepo workspace auto-discovery (each matched dir with its own `lwpt.toml` is installed as a local-path dep, symlinked or junctioned) |
| `[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]` | Lifecycle hooks per [ADR-0011](./adr/0011-build-lifecycle-hooks.md); each entry runs via InstantFPC with optional `inputs` / `output` staleness gating. Plus per-`[build]`-entry inline `prebuild` / `postbuild` fields for per-binary signing / packaging / etc. |
| Any other top-level section with a `script` field | A user-declared run-script callable via `lwpt run <name>` per [ADR-0013](./adr/0013-run-subcommand-and-build-rename.md) |
| `[version]` | optional version-baking: writes a generated `.inc` with `<prefix>_VERSION` + `<prefix>_BUILD_DATE` |
| `[lwpt]` | toolkit-state overrides (`modules-dir`, `archives-dir`, `tmp-dir`, `cfg-file`). Defaults match the constants in `LWPT.Core` |
| `[format]` | `exclude = [...]` — files `lwpt format` must not rewrite (vendored sources, generated files) |

Dependency source shapes (per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md)): bare `owner/repo` defaults to GitHub; `gitlab:owner/repo` and `bitbucket:owner/repo` prefixes route to those hosts; any `[sources.<name>]` table declares a custom prefix (Gitea, Forgejo, self-hosted GitHub Enterprise / GitLab / Bitbucket Server); `https://...` is an arbitrary tarball URL; paths (`./foo`, `../foo`, `/abs/foo`, `~/foo`, or `local:./foo`) are local sources. Version specs accept SemVer 2.0.0 ranges (`^1.0.0`, `>=1.0.0 <2.0.0`), exact SemVer versions (`1.0.0` — preferred per [semver.org](https://semver.org/#is-v123-a-semantic-version)), commit SHAs (7–40 hex), or arbitrary Git tag names (`v1.0.0`, `release-2024`). SemVer-shaped specs resolve through git smart-HTTP tag listing (uniform across GitHub / GitLab / Bitbucket / Gitea / Forgejo / self-hosted, no JSON, no auth). Explicitly *not* supported: `[[target]]` array-of-tables syntax, the legacy separate `source = "github|gitlab|..." + repo/ref/tag/asset/path` shape (hard-errored with a migration hint), and `git clone` (HTTP archives only — preserves the single-binary RTL-only constraint).

## Resolver shape

The resolver in `LWPT.Install` is a breadth-first walk starting at the root manifest's `[dependencies]`. For each dependency:

1. Look up the node in the resolution graph (`FindNode` + `TouchNode`).
2. If new, fetch into `.lwpt/archives/<dep>-<version>.tar.gz`, extract into `.lwpt/modules/<dep>/`, and read that dep's own `lwpt.toml`.
3. Enqueue every dep from the child manifest.
4. Record the constraint (range + requirer) on the node.

After the BFS finishes, `CheckNodeConstraints` walks each node and asserts that every accumulated range *pairwise intersects* via the vendored `Semver.RangeIntersects` (a full node-semver port that handles compound ranges and `||` unions). If any pair fails, the resolver hard-errors with both requirers named — the manifest tree is editable to resolve the conflict.

The flat-graph + hard-error policy is deliberate: FPC has one global unit namespace; two versions of the same package cannot coexist. There is no nested versioning to fall back on.

## Fetch / extract / build / test pipeline

- **Fetch:** HTTPS GET via the LWPT-canonical `HTTPClient` package (raw sockets + SChannel on Windows / SecureTransport on macOS / OpenSSL on Linux per [ADR-0016](./adr/0016-tls-backend-per-platform.md)). The byte-safe `AppendRawBytes` accumulator fixes a header-recv truncation bug that previously corrupted binary downloads. URL templates per source kind live in `FetchURL`.
- **Extract:** gunzip (zstream) + a direct ustar reader. The bundled FPC `libtar` has a bug — it ignores the 155-byte `prefix` field at offset 345, so paths longer than 100 bytes get silently dropped. LWPT's reader joins `prefix + '/' + name` correctly and also follows GNU `'L'`/`'K'` long-name entries.
- **Build:** `BuildOneTarget` invokes `fpc -Sh @lwpt.cfg <dev-or-release-flags> -o<target.output> <target.source>`. Mode flags come from `AddBuildModeFlags` (dev = `-O- -gw -godwarfsets -gl -Ct -Cr -Sa`; release = `-O4 -dPRODUCTION -Xs -CX -XX -B`). Cross-compile via the `FPC_TARGET_CPU` env var.
- **Test:** Each `*.Test.pas` is a self-contained program using `TestingPascalLibrary`. LWPT compiles each, runs it, and reads the process exit code. No output parsing — see [`testing.md`](./testing.md).

## `.lwpt/` layout

See [ADR-0002](./adr/0002-lwpt-namespace-zero-install.md) for the full design rationale.

| Path | Status | Purpose |
| --- | --- | --- |
| `.lwpt/modules/<dep>/` | **Committed** | Extracted / linked dependency trees. The thing `-Fu` paths point at. Per [ADR-0014](./adr/0014-packages-extraction.md): monorepo deps (resolved path inside the project root) appear as **symlinks** (Unix) or **NTFS junctions** (Windows native, no Developer Mode needed); external-path + network deps appear as regular copied directories. |
| `.lwpt/archives/<dep>-<version>.tar.gz` | **Committed** | Source-of-truth tarballs. Used for hash verification on `--frozen`. |
| `.lwpt/tmp/` | Gitignored | Install workspace. Every write to a committed path goes through here first; atomic rename moves the staged file/dir into place. EXDEV fallback (copy-then-delete) handles cross-filesystem renames. Wiped at the start of every `lwpt install` to reap crash orphans. |
| `.lwpt/install.lock` | Gitignored | Cross-process install lock. Created with O_CREAT\|O_EXCL by the first `lwpt install`; a second concurrent install fails with `EConcurrencyError` naming the lock holder's PID. Deleted by the normally-completing install; a crashed install leaves it for the user to clear via `lwpt repair`. Windows lock uses `LockFileEx`. |

### ⚠️ Windows safe-deletion warning

`.lwpt/modules/<name>/` is a **junction** on Windows when the dep is a monorepo dep (resolved inside the project root). Standard recursive-delete commands behave dangerously around junctions:

- **PowerShell** `Remove-Item -Recurse -Force` **follows the junction into the target** and deletes files outside the link. If you run this on `.lwpt/`, you can lose your `packages/<name>/source/*.pas` files. Documented Windows-platform behaviour, not an LWPT bug; bit pnpm hard enough to warrant a public incident report ([pnpm issue #10707](https://github.com/pnpm/pnpm/issues/10707)).
- **Git Bash / MSYS** `rm -rf` has the same behaviour.
- **Safe alternative on Windows**: `cmd.exe /c "rmdir /S /Q .lwpt"` — removes junction reparse points as links rather than traversing them.

LWPT's own internal cleanup (e.g. `WipeInstalledDep` during re-install) detects junctions and removes them safely (`RemoveDirectoryW` on the link itself). The hazard is only for *external* tools the user invokes on the `.lwpt/` tree. Unix users are unaffected — symlink-following deletion is a documented Windows quirk.

## Error model

`LWPT.Core` declares `ELWPTError` (base) + six subclasses:

| Class | Raised for |
| --- | --- |
| `EFetchError` | Network failures, HTTP non-2xx, local source dir missing |
| `EVerifyError` | `--frozen` archive-hash or tree-hash mismatch against the lockfile |
| `EExtractError` | Archive parse failures, tar corruption, missing archive, atomic-move failure |
| `ELockfileError` | Corrupt TOML in `lwpt.lock`, schema version mismatch (v1 → v2), missing lockfile when `--frozen` |
| `EManifestError` | TOML errors, missing required keys, unsatisfiable constraints, unknown source kinds |
| `EConcurrencyError` | Concurrent `lwpt install` — second process fails fast naming the first's PID |

Each error class carries an `Operation` and a `Recovery` field. The subcommand wrappers in `source/lwpt.pas` print `<program> <subcommand>: <message>` and the `Recovery` hint when set. Hash mismatches under `--frozen` print exactly which side mismatched (archive vs tree) and which dep is affected, so the recovery action is obvious from the message itself.

## Lockfile schema (v3)

`lwpt.lock` is machine-written; the `version = 3` header pins the schema. Each `[package.<name>]` table records:

| Key | Type | Notes |
| --- | --- | --- |
| `source` | string | The verbatim source string from the manifest (e.g. `"HashLoad/horse"`, `"gitlab:org/repo"`, `"../path"`). Host + kind are inferable by re-running `ParseDependencySource` on this value. |
| `resolvedRef` | string | The concrete tag name or commit SHA the resolver picked. Empty for `skLocal` + `skURL`. |
| `resolvedURL` | string | The actual archive URL fetched. Empty for `skLocal`. Self-documents the host: a `gitlab:` dep shows up as `https://gitlab.com/...`. |
| `computedHash` | string | `sha256:<hex>` of the extracted tree under `.lwpt/modules/<dep>/` |
| `archiveHash` | string | `sha256:<hex>` of the cached `.tar.gz` under `.lwpt/archives/`; empty for `skLocal` (no archive) |

Older lockfile schemas (v1 or v2) fail to load with a clear migration hint: delete `lwpt.lock` and re-run `lwpt install`. See [ADR-0008](./adr/0008-lockfile-schema-v2-archive-hash.md) for the archiveHash split (v1 → v2) and [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md) for the source-syntax + resolvedURL refactor (v2 → v3). v3 is the last lockfile schema break planned for v1.

## Self-host

LWPT's own `lwpt.toml` lists `lwpt` as a `[build]` entry with `source = "source/{item.name}.pas"` and `output = "build/{item.name}"` (placeholder interpolation per [ADR-0012](./adr/0012-manifest-placeholder-interpolation.md)). The pre-commit hook runs `./build/lwpt format`; `./build/lwpt build` recompiles LWPT against itself when needed. The bootstrap (`scripts/bootstrap.pas` + `bootstrap.sh` / `bootstrap.bat`) is the once-per-fresh-clone seed that produces the first `build/lwpt`. See [`build-system.md`](./build-system.md) and [ADR-0005](./adr/0005-self-host-build.md).

## Vendored code

`source/` carries LWPT-internal code (`lwpt.pas`, `LWPT.Core.pas`, `LWPT.Manifest.pas`, `LWPT.Install.pas`, `LWPT.Command.*.pas`, `LWPT.Formatter.pas`, `LWPT.GitProtocol.pas`) plus a small remainder of utility units (`Platform.pas`, `Shared.inc`) not yet extracted into `packages/`. The five LWPT-canonical packages — `httpclient`, `cli`, `semver`, `toml`, `testing` — live under `packages/<name>/` per [ADR-0014](./adr/0014-packages-extraction.md) + [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) + [ADR-0017](./adr/0017-packages-lwpt-canonical.md). Each is a standalone Pascal project with its own `lwpt.toml`, `source/`, tests, version, and bundled `Shared.inc`; LWPT's root manifest auto-discovers them via `[workspaces] include = ["packages/*"]`. [`packages.md`](./packages.md) is the table of the package set, the divergence vs GocciaScript's older copies, the bootstrap chicken-and-egg story, and the graduation roadmap. The Hard Constraint in `AGENTS.md` is "Packages own their contents" — the root LWPT manifest does not modify a package's source from outside, and each package owns its own versioning + format scope + lifecycle hooks + public surface.

## Deferred contracts

Per [ADR-0006](./adr/0006-stack-contracts-deferred-from-v1.md), the four `project-structure` contracts beyond build-system and formatter (codebase-health, duplication, link-check, architectural-drift) are deferred from v1:

- **link-check** — graduates from GocciaScript as a standalone LWPT package.
- **duplication** — becomes a `lwpt duplication` subcommand; prototype exists outside this workstream.
- **codebase-health** — becomes a `lwpt health` subcommand; prototype exists outside this workstream.
- **architectural-drift** — defer to v2.

The v1 pre-commit gate is `lwpt format --check` + `lwpt build` + `lwpt test` only. The longer-term hook is heavier.

## Production-readiness checklist (v1)

The production gaps the spike's handoff flagged + the current status of each:

| Gap | Status | Notes |
| --- | --- | --- |
| Self-test suite (HTTPClient regression first) | Done | The single most important test is the mock-server-based binary-fetch regression that pins HTTPClient's byte-safe `AppendRawBytes` contract |
| Live network tests against GitLab + Bitbucket + fetch-failure-mode tests | Done | Live GitHub (`octocat/Hello-World`), GitLab (`gitlab-examples/ci-debug-trace`), Bitbucket (`atlassian/atlaskit`) suites in the `tests/e2e/` tier. Fetch-failure E2E via missing-local-source; HTTP-500-via-mock-server pushed to v1.x (needs a URL-injection env-var hook). |
| Error handling hardened | Done | Atomic-via-`.lwpt/tmp/` for archive + tree + lockfile + cfg writes, EXDEV fallback, `O_CREAT\|O_EXCL` cross-process install lock, lockfile schema v2 with `archiveHash` sibling, `--frozen` two-hash verification, crash-recovery wipe of `.lwpt/tmp/` orphans at install startup. |
| CI on the platform tier matrix | Done | Tier 1: Linux x86_64 + aarch64, Windows x86_64, macOS arm64 (see [`deployment.md`](./deployment.md)). Windows install lock (`LockFileEx`), mock server (`WinSock`), and subprocess paths all ship; tests using them currently `{$IFDEF UNIX}` the substantive logic on non-Windows hosts. |
| Release artifacts | Done | Windows + macOS releases ship the binary alone; Linux relies on distro libssl per [ADR-0016](./adr/0016-tls-backend-per-platform.md). |
| Embedded testing library refresh wired into `lwpt build` | Retired per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) | The embedded blob is gone; the testing framework is the workspace `testing` package, consumed via `lwpt install` like any other dep. |
| GocciaScript adopts LWPT-canonical packages | Direction set per [ADR-0017](./adr/0017-packages-lwpt-canonical.md); migration on the GocciaScript side | LWPT is now canonical for the shared packages; GocciaScript commits to Path A (full toolchain adoption). Until adoption lands, GocciaScript's older copies are frozen; backports only for P0 bugs. |
