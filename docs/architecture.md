# Architecture

How LWPT is shaped: the through-line that ties every subcommand to the manifest, the on-disk layout that makes zero-install work, and the deliberate boundaries we drew during the spike-to-production grilling.

## Executive Summary

- **The package manager is the foundation.** `lwpt install` resolves the dependency graph and writes `lwpt.cfg`; every other subcommand consumes that same cfg. The manifest (`lwpt.toml`) is the single source of truth.
- **Zero-install by default.** `.lwpt/modules/` (extracted) and `.lwpt/archives/` (verification) are committed; a fresh clone is buildable with `fpc @lwpt.cfg` before `lwpt install` is ever run. See [ADR-0002](./adr/0002-lwpt-namespace-zero-install.md).
- **Self-hosting from day one.** LWPT builds LWPT through `lwpt build` against the repo's own manifest; the one-time `scripts/bootstrap.pas` resolves the chicken-and-egg. See [ADR-0005](./adr/0005-self-host-build.md).
- **RTL-only with LWPT-canonical packages.** No third-party FPC dependencies in the binary; HTTPS is `HTTPClient` from LWPT's `packages/httpclient/`. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT is the canonical source for HTTPClient, CLI, Semver, TOML, and TestingPascalLibrary — all consumed as workspace packages via the root manifest's `[workspaces]` glob (Phase 1 done per ADR-0014 + ADR-0015). GocciaScript is the first named consumer and commits to Path A adoption; Phase 2 graduates individual packages to standalone repos when warranted.
- **Pre-1.0 has deliberate gaps.** The self-hosted origin-and-mirror HTTP registry implementation is tracked in [issue #29](https://github.com/frostney/lwpt/issues/29); its interoperable wire contract is specified in [`registry-spec.md`](./registry-spec.md). Duplication analysis and codebase health have landed. Architecture drift is a project-local release check for LWPT itself, not a customer feature.
- **Error handling is production-grade.** Every multi-step install write goes through `.lwpt/tmp/` + atomic rename (EXDEV fallback to copy-then-delete), and `lwpt install` takes a cross-process lock (`.lwpt/install.lock`, O_CREAT|O_EXCL). See ADR-0002 and ADR-0008.
- **Compiler work is session-private.** Build/test compiler outputs stay below `.lwpt/sessions/<session-id>/`; successful build outputs are revalidated and atomically published, while completed-session logs remain available until `lwpt repair` reclaims the session. See ADR-0020.
- **Build scheduling follows the manifest DAG.** Ready build entries overlap within
  both the `--jobs` ceiling and machine-wide worker budget; dependants start
  only after prerequisites publish. See ADR-0023.
- **Build intent and compiler execution meet at one driver seam.**
  `LWPT.BuildRequest` owns the versioned request, target tuple, capability, and
  normalized result structures. `TLWPTCompilerDriver` owns capability probing,
  argument translation, executable naming, failure classification, and result
  normalization. Root-owned profiles select built-in FPC, the opt-in Lakon
  adapter, a short-lived external driver, or an embedding-host factory for
  build and test. A registered `lakon` host factory takes precedence over the
  external Lakon adapter so an embedding can replace the implicit FPC default;
  lifecycle hook compilation remains on FPC. See ADR-0022, ADR-0029, and
  ADR-0030.
- **Analysis commands share structure, not policy.** `LWPT.Analysis.Scope`
  resolves root/workspace ownership, `LWPT.Analysis.Pascal` exposes normalized
  tokens and typed declaration/executable regions, and `LWPT.Analysis.JSON`
  wraps command-owned payloads in a deterministic versioned envelope. Matching,
  scoring, thresholds, and payload schemas remain owned by their commands.

## Tech stack

- **Compiler:** FreePascal 3.2.2 (`fpc -iV` verified live; see `tooling.md`).
- **Mode:** `delphi` everywhere. Project-owned units (`lwpt.pas`, the `LWPT.*` family) and the package units (`CLI.*`, `Semver`, `HTTPClient`, etc) flow through `{$I Shared.inc}` which sets `{$mode delphi} {$H+}` (a few test-support units declare their own mode instead). Several LWPT units additionally enable `{$modeswitch nestedcomments+}` so documentation prose can contain literal placeholder strings (the `{user}` / `{repository}` / `{ref}` substrings) without prematurely closing the surrounding `{ ... }` block.
- **Runtime:** RTL only. No fcl-web, no fphttpclient, no third-party packages. HTTPS goes through the `HTTPClient` package's `TransportSecurity` with platform-native TLS per ADR-0016: SChannel on Windows, SecureTransport on macOS, runtime-loaded system OpenSSL on Unix-not-Darwin.
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

   ↑ lwpt repair operates on project residue, abandoned .lwpt/sessions/
     staging, and the per-user worker coordinator orthogonally.
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
| `[build]` | one entry per binary; `lwpt build [<entry-name>]` consumes this. Inline entries may declare `depends = ["prerequisite"]` and ordered `flags = ["-dFEATURE"]`. Single-binary shorthand: `[build] source = "..."` directly under `[build]` defaults the entry name to `[package].name` |
| `[compiler]` / `[compiler.profiles.<name>]` | root-owned compiler policy. `default` names the project profile; profiles select a driver plus optional `version` and either `executable` or `script`. Built-in IDs are `fpc` and opt-in `lakon`; other IDs resolve through an embedding factory or external protocol executable. An embedding host may register `lakon` explicitly and make it the host default. A build entry's `compiler` field overrides the project default. Dependency manifests cannot contribute this policy. |
| `[workspaces]` | `include` / `exclude` glob arrays for monorepo workspace auto-discovery (each matched dir with its own `lwpt.toml` is installed as a validated local snapshot) |
| `[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]` | Lifecycle hooks per [ADR-0011](./adr/0011-build-lifecycle-hooks.md); each entry runs via InstantFPC with optional `inputs` / `output` staleness gating. Plus per-`[build]`-entry inline `prebuild` / `postbuild` fields for per-binary signing / packaging / etc. |
| Any other top-level section with a `script` field | A user-declared run-script callable via `lwpt run <name>` per [ADR-0013](./adr/0013-run-subcommand-and-build-rename.md) |
| `[version]` | optional version-baking: writes a generated `.inc` with `<prefix>_VERSION` + `<prefix>_BUILD_DATE` |
| `[lwpt]` | toolkit-state overrides (`modules-dir`, `archives-dir`, `tmp-dir`, `cfg-file`). Defaults match the constants in `LWPT.Core` |
| `[format]` | `include = [...]` adds format-scope globs; `exclude = [...]` subtracts them. Toolkit state (root `.lwpt/**` plus any `[lwpt]` override paths) is excluded by default unless an explicit include matches it (ADR-0028). Workspace packages are included by the root walk by default and opt out via their own `[format]` section |
| `[analysis]` | shared analysis source scope only: `include = [...]` adds Pascal source globs on top of `[package].units` and exact `[build]` sources; `exclude = [...]` subtracts them. Workspaces inherit the root configuration unless they declare their own `[analysis]` table. Command-specific thresholds and policy do not live here. |
| `[health]` | optional strict maxima for routine/file cyclomatic and cognitive complexity plus the separate `0..100` hotspot score. Workspaces inherit root limits unless they declare their own table. See [`health.md`](./health.md). |
| `[duplication]` | command-owned clone policy: `minimum-tokens` defaults to 100 and must be at least 25; optional integer `maximum-percent` fails only when aggregate duplication is greater than the configured value. Workspaces inherit the root table unless they declare their own. |

Dependency source shapes (per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md)): bare `owner/repo` defaults to GitHub; `gitlab:owner/repo` and `bitbucket:owner/repo` prefixes route to those hosts; any `[sources.<name>]` table declares a custom prefix (Gitea, Forgejo, self-hosted GitHub Enterprise / GitLab / Bitbucket Server); `https://...` is an arbitrary tarball URL; paths (`./foo`, `../foo`, `/abs/foo`, `~/foo`, or `local:./foo`) are local sources. Version specs accept SemVer 2.0.0 ranges (`^1.0.0`, `>=1.0.0 <2.0.0`), exact SemVer versions (`1.0.0` — preferred per [semver.org](https://semver.org/#is-v123-a-semantic-version)), commit SHAs (7–40 hex), or arbitrary Git tag names (`v1.0.0`, `release-2024`). SemVer-shaped specs resolve through git smart-HTTP tag listing (uniform across GitHub / GitLab / Bitbucket / Gitea / Forgejo / self-hosted, no JSON, no auth). Explicitly *not* supported: `[[target]]` array-of-tables syntax, the legacy separate `source = "github|gitlab|..." + repo/ref/tag/asset/path` shape (hard-errored with a migration hint), and `git clone` (HTTP archives only — preserves the single-binary RTL-only constraint).

## Shared analysis foundation

The pre-approved duplication and health commands depend on three neutral deep
modules. `ResolveAnalysisScope` recursively resolves each declared workspace,
assigns every Pascal source to its globally deepest discovered project owner,
skips hidden and linked walks, and returns stable root-relative ordering.
Package unit roots and exact build entry sources seed the scope;
`[analysis].include` adds files and `[analysis].exclude` is the final
subtraction.

`AnalyzePascal` is an RTL-only lexical/structural pass. It strips whitespace and
comments, retains compiler directives, normalizes case-insensitive tokens, and
records zero-based byte offsets plus one-based line/column locations. Its typed
model keeps unit declarations, routine-local declarations, nested routines,
routine bodies, program bodies, initialization, and finalization separate.
Consumers therefore choose executable-versus-declaration comparisons explicitly
instead of inferring them from raw token positions.

`SerializeAnalysisEnvelope` writes a fixed-order LF-delimited JSON envelope with
an envelope schema/version, command name and independently versioned command
schema, LWPT name/version, project identity, sorted analyzed-file list, neutral
effective-configuration name/value entries, threshold outcome, and diagnostics.
The caller supplies one validated JSON object or array as its payload. Shared
code does not know duplication matches, health metrics, hotspot scores,
command-specific configuration schemas, or either command's presentation
policy.

`LWPT.Health` and `LWPT.Command.Health` consume that neutral foundation for the
shipped `lwpt health` command. The exact structural scoring table, threshold
contract, 100-commit rename-aware Git window, hotspot formula, and JSON payload
are documented once in [`health.md`](./health.md).

`LWPT.Duplication` consumes those neutral modules without feeding clone policy
back into them. It generates parameterized minimum-token fingerprints inside
each typed region, verifies candidates with a bidirectional identifier/literal
mapping, extends them to their maximal forward length, then selects
non-overlapping groups by descending length and stable coordinates. The command
owns its `[duplication]` inheritance, thresholds, human report, and versioned
JSON payload; `[analysis]` remains the only source-scope contract.

## Resolver shape

Materializing resolution in `LWPT.Install` is a breadth-first graph walk inside
deterministic fixed-point rounds ([ADR-0031](./adr/0031-fixed-point-single-version-resolution.md)).
Every candidate archive, extracted tree, and copied local source stays below a
private `.lwpt/tmp/resolver-plan-*` directory while LWPT:

1. accumulates all root and transitive requirements by package name;
2. rejects different canonical sources for the same name;
3. selects the highest advertised Git tag satisfying the node's complete
   SemVer constraint set;
4. uses lightweight or peeled annotated-tag SHAs to prove tag/SHA identity; and
5. repeats discovery when a selected candidate changes the transitive graph.

A repeated selection vector is an error: the resolver does not backtrack
through lower parent candidates. Once a round is stable, its exact filtered
module snapshots and archives are published, followed by `lwpt.lock` and
`lwpt.cfg`; mutable local/workspace sources are not reread during publication.
Failures before stability leave committed state untouched, and conflict
diagnostics list every requirer and constraint. The flat-graph hard error is
deliberate because FPC has one global unit namespace; nested multi-version
installs are not supported.

## Fetch / extract / build / test pipeline

- **Fetch:** HTTPS GET via the LWPT-canonical `HTTPClient` package (raw sockets + SChannel on Windows / SecureTransport on macOS / OpenSSL on Linux per [ADR-0016](./adr/0016-tls-backend-per-platform.md)). The byte-safe `AppendRawBytes` accumulator fixes a header-recv truncation bug that previously corrupted binary downloads. URL templates per source kind live in `FetchURL`.
- **Extract:** gunzip (zstream) + a direct ustar reader. The bundled FPC `libtar` has a bug — it ignores the 155-byte `prefix` field at offset 345, so paths longer than 100 bytes get silently dropped. LWPT's reader joins `prefix + '/' + name` correctly and also follows GNU `'L'`/`'K'` long-name entries.
- **Build:** `BuildOneEntry` creates a `TLWPTBuildRequest`, asks the selected driver
  to probe the requested target, validates the request against those
  capabilities, and obtains its invocation. Root-manifest per-entry flags
  become ordered neutral extra arguments before the driver translates them;
  dependency-manifest flags are dropped. `TLWPTCompilerProcess` executes
  them below the seam. The driver normalizes diagnostics while the scheduler
  retains raw output for ordered log replay. The publication fingerprint embeds
  the deterministic request serialization alongside the implicit source
  directory, declared inputs, and postbuild hook contributors. Per-entry
  postbuild hooks receive the private candidate through `LWPT_BUILD_OUTPUT`,
  and existing `{item.output}` references are retargeted to it; only after hooks
  succeed does LWPT take a short thread-and-process lock derived from the
  destination's filesystem identity, refresh the target probe, revalidate the
  snapshot, and atomically replace the public executable when it is still
  current. Search-root fingerprints follow workspace directory links with cycle
  protection and exclude unrelated declared outputs, while explicit file inputs
  remain hashed.
- **Test:** Each `*.Test.pas` is a self-contained program using
  `TestingPascalLibrary`. `lwpt test` resolves the project-scoped compiler
  driver once and shares it across every test worker; per-entry compiler
  profiles apply to `lwpt build`, not to individual test files. Workers validate
  each neutral request, compile into private session paths, retain raw compiler
  output, and store normalized build-result diagnostics before running a
  successful binary. See [`testing.md`](./testing.md).
- **Worker coordination:** `LWPT.WorkerBudget` owns the per-user machine-capacity seam. Invocations register owner-guarded requests and acquire FIFO, reclaimable leases under a short cross-platform transaction lock. Nested LWPT subprocesses consume a one-shot opaque delegation that transfers one grant to the child's own guarded request instead of consuming another slot. `lwpt repair` reclaims requests only when their OS-held owner guard is absent; stale heartbeats remain diagnostic. Build and test scheduling consume this module in their own workstreams.

## `.lwpt/` layout

See [ADR-0002](./adr/0002-lwpt-namespace-zero-install.md) for the full design rationale.

| Path | Status | Purpose |
| --- | --- | --- |
| `.lwpt/modules/<dep>/` | **Committed** | Exact extracted or copied dependency snapshots from the stable resolver plan. Include/exclude policy has already been applied; the thing `-Fu` paths point at is never a live reread of a mutable local/workspace source. ADR-0031 supersedes ADR-0014's earlier publication-time monorepo-link amendment for materializing installs. |
| `.lwpt/archives/<dep>-<version>.tar.gz` | **Committed** | Source-of-truth tarballs. Used for hash verification on `--frozen`. |
| `.lwpt/tmp/` | Gitignored | Install workspace and journaled rollback copies. A materializing install or `lwpt repair` recovers pending state before ordinary residue cleanup. Frozen verification does not mutate it. |
| `.lwpt/install.lock` | Gitignored | Cross-process install lock. Created with O_CREAT\|O_EXCL by the first `lwpt install`; a second concurrent install fails with `EConcurrencyError` naming the lock holder's PID. Deleted by the normally-completing install; a crashed install leaves it for the user to clear via `lwpt repair`. Windows lock uses `LockFileEx`. |
| `.lwpt/sessions/<session-id>/` | Gitignored | Build/test compiler staging. Every invocation owns distinct, bounded, hash-qualified job, unit, executable, and hook-compile paths. Completed sessions retain stable job logs until `lwpt repair`; failed/crashed sessions retain their private diagnostics. The sibling `locks/` directory contains stable publication-lock files and per-session owner guards. |

### ⚠️ Windows safe-deletion warning

Older zero-install trees may still contain a **junction** from the superseded
monorepo-link publication policy. Current materializing installs replace it
with a validated snapshot, but standard recursive-delete commands remain
dangerous until that happens:

- **PowerShell** `Remove-Item -Recurse -Force` **follows the junction into the target** and deletes files outside the link. If you run this on `.lwpt/`, you can lose your `packages/<name>/source/*.pas` files. Documented Windows-platform behaviour, not an LWPT bug; bit pnpm hard enough to warrant a public incident report ([pnpm issue #10707](https://github.com/pnpm/pnpm/issues/10707)).
- **Git Bash / MSYS** `rm -rf` has the same behaviour.
- **Safe alternative on Windows**: `cmd.exe /c "rmdir /S /Q .lwpt"` — removes junction reparse points as links rather than traversing them.

LWPT's own `AtomicRemovePath` cleanup detects junctions and removes them safely
(`RemoveDirectoryW` on the link itself). The hazard is only for *external*
tools the user invokes on the `.lwpt/` tree. Unix users are unaffected —
symlink-following deletion is a documented Windows quirk.

## Error model

`LWPT.Core` declares `ELWPTError` (base) + six subclasses; worker coordination
adds one module-specific subclass:

| Class | Raised for |
| --- | --- |
| `EFetchError` | Network failures, HTTP non-2xx, local source dir missing |
| `EVerifyError` | `--frozen` archive-hash or tree-hash mismatch against the lockfile |
| `EExtractError` | Archive parse failures, tar corruption, missing archive, atomic-move failure |
| `ELockfileError` | Corrupt TOML in `lwpt.lock`, schema version mismatch (v1 → v2), missing lockfile when `--frozen` |
| `EManifestError` | TOML errors, missing required keys, unsatisfiable constraints, unknown source kinds |
| `EConcurrencyError` | Concurrent `lwpt install` — second process fails fast naming the first's PID |
| `ELWPTWorkerBudgetError` | Invalid worker-budget configuration, ownership, lease, or delegation state |
| `ELWPTBuildRequestError` | Unsupported contract schemas, invalid build requests/results/capabilities, or invalid compiler compatibility constraints |
| `ELWPTCompilerDriverError` | Compiler probe, target dispatch, or request/capability mismatch failures |

Each error class carries an `Operation` and a `Recovery` field. The subcommand wrappers in `source/lwpt.pas` print `<program> <subcommand>: <message>` and the `Recovery` hint when set. Hash mismatches under `--frozen` print exactly which side mismatched (archive vs tree) and which dep is affected, so the recovery action is obvious from the message itself.

## Lockfile schema (v3)

`lwpt.lock` is machine-written; the `version = 3` header pins the schema. Each `[package.<name>]` table records:

| Key | Type | Notes |
| --- | --- | --- |
| `source` | string | The verbatim source string from the manifest (e.g. `"HashLoad/horse"`, `"gitlab:org/repo"`, `"../path"`). Host + kind are inferable by re-running `ParseDependencySource` on this value. |
| `resolvedRef` | string | The concrete tag name or commit SHA the resolver picked. Empty for `skLocal` + `skURL`. |
| `resolvedCommit` | string | The authoritative advertised commit fetched for a Git ref. Newly generated v3 entries record it; compatible early v3 entries remain frozen-verifiable when their existing fields prove an unambiguous identity. |
| `sourceIdentity` | string | Canonical source plus normalized include/exclude extraction policy. |
| `constraintFingerprint` | string | Digest of every accumulated requirement and requirer used to select this package. Missing additive evidence in an early v3 entry is accepted only when the remaining identity is unambiguous; mixed named-ref/SHA identity without an authoritative commit requires regeneration. |
| `resolvedURL` | string | The actual archive URL fetched. Empty for `skLocal`. Self-documents the host: a `gitlab:` dep shows up as `https://gitlab.com/...`. |
| `computedHash` | string | `sha256:<hex>` of the extracted tree under `.lwpt/modules/<dep>/` |
| `archiveHash` | string | `sha256:<hex>` of the cached `.tar.gz` under `.lwpt/archives/`; empty for `skLocal` (no archive) |

Older lockfile schemas (v1 or v2) fail to load with a clear migration hint: delete `lwpt.lock` and re-run `lwpt install`. See [ADR-0008](./adr/0008-lockfile-schema-v2-archive-hash.md) for the archiveHash split (v1 → v2) and [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md) for the source-syntax + resolvedURL refactor (v2 → v3). v3 is the last lockfile schema break planned for v1. Early v3 files without the additive authoritative identity fields remain frozen-verifiable when their existing source and ref fields prove an unambiguous identity. Ambiguous mixed named-ref/SHA entries fail with an instruction to run the machine writer; lockfiles must never be hand-edited.

## Self-host

LWPT's own `lwpt.toml` lists `lwpt` as a `[build]` entry with `source = "source/{item.name}.pas"` and `output = "build/{item.name}"` (placeholder interpolation per [ADR-0012](./adr/0012-manifest-placeholder-interpolation.md)). The pre-commit hook runs `./build/lwpt format` and `./build/lwpt agents`; `./build/lwpt build` recompiles LWPT against itself when needed. The bootstrap (`scripts/bootstrap.pas` + `bootstrap.sh` / `bootstrap.bat`) is the once-per-fresh-clone seed that produces the first `build/lwpt`. See [`build-system.md`](./build-system.md) and [ADR-0005](./adr/0005-self-host-build.md).

## Source layout and package code

`source/` carries LWPT-internal code (`lwpt.pas`, `LWPT.Core.pas`,
`LWPT.Manifest.pas`, `LWPT.Install.pas`, `LWPT.WorkerBudget.pas`,
`LWPT.Command.*.pas`, `LWPT.CompilerDriver.pas`,
`LWPT.CompilerDriver.FPC.pas`, `LWPT.CompilerDriver.External.pas`,
`LWPT.CompilerRegistry.pas`, `LWPT.ProcessRunner.pas`, `LWPT.Formatter.pas`,
`LWPT.GitProtocol.pas`) plus a small remainder of utility units
(`Platform.pas`, `Shared.inc`) not yet extracted into `packages/`. The five
LWPT-canonical packages — `httpclient`, `cli`, `semver`, `toml`, `testing` —
live under `packages/<name>/` per
[ADR-0014](./adr/0014-packages-extraction.md) +
[ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) +
[ADR-0017](./adr/0017-packages-lwpt-canonical.md). Each is a standalone Object
Pascal project with its own `lwpt.toml`, `source/`, tests, version, and bundled
`Shared.inc`; LWPT's root manifest auto-discovers them via `[workspaces]
include = ["packages/*"]`. [`packages.md`](./packages.md) is the table of the
package set, the divergence vs GocciaScript's older copies, the bootstrap
chicken-and-egg story, and the graduation roadmap. The Hard Constraint in
`AGENTS.md` is "Packages own their contents" — each package owns its versioning,
lifecycle hooks, tests, and public surface. Formatting is the explicit exception:
the root manifest formats workspace packages by default, and a package opts out
by declaring its own `[format]` section.

## ADR-0006 contract status

ADR-0006 originally deferred customer-facing `project-structure` contracts
beyond the build system and formatter. Duplication and codebase health have
since shipped:

- **duplication** — delivered as the Pascal-native `lwpt duplication`
  subcommand from [issue #32](https://github.com/frostney/lwpt/issues/32).
- **codebase-health** — delivered as `lwpt health` from [issue #33](https://github.com/frostney/lwpt/issues/33), with its current contract in [`health.md`](./health.md).

The pre-merge CI/PR gate is `lwpt format --check` + `lwpt build` + `lwpt agents --check` + `lwpt test`; the local pre-commit hook runs the formatter and the AGENTS.md agents-block refresh only. Architecture drift is checked across LWPT's own source, tests, manifests, workflows, documentation, ADRs, and domain context during release preparation. It is not a consumer-project responsibility or an LWPT subcommand.

## Production-readiness checklist (v1)

The production gaps the spike's handoff flagged + the current status of each:

| Gap | Status | Notes |
| --- | --- | --- |
| Self-test suite (HTTPClient regression first) | Done | The single most important test is the mock-server-based binary-fetch regression that pins HTTPClient's byte-safe `AppendRawBytes` contract |
| Live network tests against GitLab + Bitbucket + fetch-failure-mode tests | Partial | Live GitHub (`octocat/Hello-World`), GitLab (`gitlab-examples/ci-debug-trace`), Bitbucket (`atlassian/atlaskit`) suites ship in the `tests/e2e/` tier. Missing-local-source coverage exists; deterministic HTTP redirect, timeout, malformed-response, and status-failure coverage remains tracked in [issue #34](https://github.com/frostney/lwpt/issues/34). |
| Error handling hardened | Done | Validated journaled rollback under `.lwpt/tmp/`, stable-plan publication, recovery before tmp cleanup, aggregate rollback diagnostics, EXDEV fallback, `O_CREAT\|O_EXCL` cross-process install lock, lockfile schema v3 with `archiveHash` and `resolvedURL`, and read-only `--frozen` two-hash verification. |
| CI on the platform tier matrix | Partial | Tier 1 cross-build and native-test coverage ships for Linux, Windows, and macOS (see [`deployment.md`](./deployment.md)). Windows install locking (`LockFileEx`) and subprocess paths ship; the WinSock-backed HTTP mock server needed to remove Windows skips remains tracked in [issue #35](https://github.com/frostney/lwpt/issues/35). |
| Release artifacts | Done | Windows + macOS releases ship the binary alone; Linux relies on distro libssl per [ADR-0016](./adr/0016-tls-backend-per-platform.md). |
| Embedded testing library refresh wired into `lwpt build` | Retired per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) | The embedded blob is gone; the testing framework is the workspace `testing` package, consumed via `lwpt install` like any other dep. |
| GocciaScript adopts LWPT-canonical packages | Direction set per [ADR-0017](./adr/0017-packages-lwpt-canonical.md); migration on the GocciaScript side | LWPT is now canonical for the shared packages; GocciaScript commits to Path A (full toolchain adoption). Until adoption lands, GocciaScript's older copies are frozen; backports only for P0 bugs. |
