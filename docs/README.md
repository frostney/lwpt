# LWPT documentation

**Using LWPT:** start with the [consumer guide](consumer-guide.md) for installation,
a working project, and capability selection. **Contributing to LWPT:** follow the
[contributor quick start](quick-start.md). [llms.txt](../llms.txt) provides a compact
index linking to the same canonical Markdown sources.

Index of the [`docs/`](.) folder. The root-level [`README.md`](../README.md), [`AGENTS.md`](../AGENTS.md), [`CONTRIBUTING.md`](../CONTRIBUTING.md), and [`CONTEXT.md`](../CONTEXT.md) are the entry points; everything below is the deep dive.

| File | Covers |
| --- | --- |
| [`consumer-guide.md`](./consumer-guide.md) | Released-tool installation, CLI and testing dependencies, runnable consumer example, tasks, and capability references |
| [`architecture.md`](./architecture.md) | Tech stack, the package-manager-is-the-foundation through-line, manifest model, resolver shape, fetch/extract/build/test pipeline, `.lwpt/` layout, error/idempotency model, deferred-contracts note |
| [`quick-start.md`](./quick-start.md) | Contributor setup: install FPC + InstantFPC + Lefthook, bootstrap LWPT itself, build, test, and common errors |
| [`tooling.md`](./tooling.md) | Pinned tool versions, environment variables, lint/format/test commands, per-platform TLS backend (SChannel / SecureTransport / OpenSSL), EXDEV fallback, where each deferred contract lives |
| [`code-style.md`](./code-style.md) | Naming, file layout, formatter rules, manifest scope with protected toolkit state, line-endings, design tokens |
| [`build-system.md`](./build-system.md) | Bootstrap pattern, `lwpt build` contract, `[build]` section + lifecycle hooks (`[prebuild]` / `[postbuild]` / `[pretest]` / etc.), `build/` output rules, cross-compile |
| [`deployment.md`](./deployment.md) | Platform tier matrix, release process, per-platform TLS backend (SChannel / SecureTransport / OpenSSL), macOS quarantine, codesigning policy |
| [`ci.md`](./ci.md) | CI workflow shape (`ci.yml` / `pr.yml` / `release.yml` / `toolchain.yml`), trigger split, cross-build toolchain cache, install scripts |
| [`testing.md`](./testing.md) | Repository-owned test groups, selector policy, fixture strategy, mock HTTP server, the binary-fetch regression, test inventory |
| [`health.md`](./health.md) | `lwpt health` scope, Pascal complexity scoring, thresholds, Git hotspot formula, and JSON schema |
| [`packages.md`](./packages.md) | The package set, divergence vs GocciaScript-older-copies, bootstrap chicken-and-egg, graduation roadmap (per [ADR-0017](./adr/0017-packages-lwpt-canonical.md)) |
| [`registry-spec.md`](./registry-spec.md) | Open origin-and-mirror HTTP registry protocol: stable identity, immutable records/objects, signed snapshots, publication, synchronization, and conformance fixtures |
| [`registry-deployment.md`](./registry-deployment.md) | Running a registry origin or mirror: the example container image in [`examples/registry/`](./examples/registry/), TLS and reverse-proxy shapes, secrets and tokens, graceful shutdown, backup and restore, upgrades, operational limits, portability assumptions, and the CI evidence |

## Decision records

[`adr/`](./adr/) holds Architectural Decision Records — short notes documenting non-obvious choices that future readers will wonder about. They're append-only: superseded decisions get new ADRs that reference the old, never edits-in-place.

| ADR | Topic |
| --- | --- |
| [0001](./adr/0001-program-name-as-constant.md) | Project name expressed as a single constant, never hardcoded |
| [0002](./adr/0002-lwpt-namespace-zero-install.md) | `.lwpt/` namespace, zero-install by default (modules + archives committed) |
| [0003](./adr/0003-vendored-permanent-fork-graduation.md) | (Superseded by [0017](./adr/0017-packages-lwpt-canonical.md).) Vendored code is a permanent fork, with a graduation roadmap — kept as historical record |
| [0004](./adr/0004-http-registry-deferred-to-v2.md) | (Completed by [0051](./adr/0051-registry-dependency-sources.md).) HTTP registry source kind deferred to v2 — kept as historical record |
| [0005](./adr/0005-self-host-build.md) | LWPT builds LWPT (self-host) with a one-time bootstrap script |
| [0006](./adr/0006-stack-contracts-deferred-from-v1.md) | Four stack contracts (link, duplication, codebase-health, architectural-drift) deferred from v1 |
| [0007](./adr/0007-formatter-scope-manifest-declared.md) | Formatter scope is manifest-declared (`[package].units` + `[format].include` minus `[format].exclude`, globs + explicit recursion); toolkit-state exception added by ADR-0028 |
| [0008](./adr/0008-lockfile-schema-v2-archive-hash.md) | Lockfile schema v2 splits `archiveHash` from `computedHash` for two-hash `--frozen` verification |
| [0009](./adr/0009-source-syntax-and-tag-resolution.md) | Source syntax (`<source>@<spec>` shorthand; git-host / URL / local kinds) + git smart-HTTP tag resolution; lockfile schema v3 |
| [0010](./adr/0010-init-subcommand.md) | `lwpt init` interactive scaffold + npm-init-y semantics with `--yes` |
| [0011](./adr/0011-build-lifecycle-hooks.md) | Direct-command lifecycle hooks (`[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]` + per-build-entry inline hooks) with shared strict staleness evaluation |
| [0012](./adr/0012-manifest-placeholder-interpolation.md) | Manifest placeholder interpolation (`{package.*}`, `{item.*}`, `{platform.*}`) with two-pass resolution and strict unknown-name errors |
| [0013](./adr/0013-run-subcommand-and-build-rename.md) | `lwpt run` for user-declared run tasks + subcommand aliasing; `[build]` entries with optional independent target tuples |
| [0014](./adr/0014-packages-extraction.md) | Workspace packages under `packages/<name>/` for HTTPClient / CLI / Semver / TOML (extended by ADR-0015 to add `testing`); `[workspaces]` auto-discovery; monorepo symlink/junction install |
| [0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) | `lwpt export` retired; `TestingPascalLibrary` graduates to the `testing` workspace package; subcommand surface 8 → 7 |
| [0016](./adr/0016-tls-backend-per-platform.md) | TLS backend is platform-native (SChannel on Windows, SecureTransport on macOS, OpenSSL on Linux); CI guard prevents OpenSSL DLL dependency on Windows |
| [0017](./adr/0017-packages-lwpt-canonical.md) | Packages are LWPT-canonical workspace projects; GocciaScript is the first named adopter committed to Path A (full toolchain adoption); supersedes [0003](./adr/0003-vendored-permanent-fork-graduation.md) |
| [0018](./adr/0018-install-transaction-module.md) | Install transaction moves behind a dedicated `LWPT.Install` module; hooks stay outside, frozen remains verification-only, and lockfile/cfg commits are owned by the transaction seam; the install lock is shared with `lwpt repair` since [0053](./adr/0053-install-lock-ownership-and-reclamation.md) |
| [0019](./adr/0019-add-remove-subcommands.md) | `lwpt add` + `lwpt remove` as manifest-editing frontends to the install transaction; install-before-write ordering; lockfile-diff pruning of orphaned modules + archives; subcommand surface 7 → 9 |
| [0020](./adr/0020-isolated-build-sessions.md) | Invocation-private compiler staging, revalidated short-lock publication, session-safe clean, and repair reclamation |
| [0021](./adr/0021-machine-wide-worker-budget.md) | Per-user machine worker capacity coordinated through fair, reclaimable filesystem leases |
| [0022](./adr/0022-compiler-neutral-build-request.md) | Compiler-neutral versioned build requests, target tuples, capabilities, and normalized results; FPC was the only adapter at acceptance (Delphi, Blaise, and Lakon drivers have since shipped) |
| [0023](./adr/0023-parallel-build-target-scheduler.md) | Dependency-aware, bounded parallel target scheduling with deterministic reporting and publication |
| [0024](./adr/0024-openssl-server-tls-accept.md) | Server-side TLS accept via nonblocking memory-BIO OpenSSL 3 with PKCS#12 identities on Unix-not-Darwin (originally also Windows, superseded there by [0033](./adr/0033-schannel-server-tls-accept-on-windows.md)); on macOS the HTTPClient server context uses Secure Transport, and only the registry's HTTPS listener uses Network.framework, on Darwin kernel 25 and newer ([0043](./adr/0043-self-hosted-registry-origin.md)) |
| [0025](./adr/0025-cascading-process-tree-cancellation.md) | Cascading process-tree cancellation via Unix signal-forwarding and Windows nested Job Objects |
| [0026](./adr/0026-release-version-stamp-from-tag.md) | Release binaries stamp the version from the git tag; dev builds stamp from the manifest |
| [0027](./adr/0027-agents-subcommand.md) | `lwpt agents` writes/verifies the marker-fenced AGENTS.md command reference; subcommand surface 9 → 10 |
| [0028](./adr/0028-default-toolkit-state-format-exclusion.md) | Formatter excludes root `.lwpt/**` by default while explicit includes opt matching files back in |
| [0029](./adr/0029-fpc-compiler-driver.md) | Neutral compiler-driver seam with on-demand FPC target probes, unified argument translation, failure classification, and normalized diagnostics |
| [0030](./adr/0030-root-compiler-profiles.md) | Root-owned named compiler commands, out-of-process host registration, deterministic selection precedence, and the short-lived external-driver TOML protocol |
| [0031](./adr/0031-fixed-point-single-version-resolution.md) | Deterministic fixed-point dependency discovery, authoritative Git ref identity, graph-wide highest-version selection, and publish-after-validation |
| [0032](./adr/0032-managed-delivery-state-and-proof.md) | (Superseded by [0046](./adr/0046-skill-owned-delivery.md).) Managed delivery through an explicit transition endpoint, phase labels, and exact native-topology full-CI proofs — kept as historical record |
| [0033](./adr/0033-schannel-server-tls-accept-on-windows.md) | Windows server TLS accept moves to native SChannel + crypt32, removing OpenSSL from Windows entirely and giving `i386-win32` server accept; supersedes the Windows half of [0024](./adr/0024-openssl-server-tls-accept.md) |
| [0034](./adr/0034-freeze-test-selection-before-pretest.md) | Test discovery and file/directory/glob selection freeze before `pretest`; hooks may prepare inputs but cannot add programs to the invocation |
| [0035](./adr/0035-runtime-test-registration-inventory.md) | Runtime test-registration inventory: `lwpt test --inventory` reports registered suites and cases as deterministic JSON without running test bodies, and the committed `tests/test-inventory.tsv` verifies counts per platform and renders the `docs/testing.md` tables |
| [0036](./adr/0036-per-user-dependency-archive-cas.md) | Verified dependency archives reuse one per-user immutable SHA-256 object while project-owned archives and frozen verification remain authoritative |
| [0037](./adr/0037-verified-build-result-cache.md) | Verified compiler-neutral build-result reuse through per-user immutable manifests and artifacts, with explicit bypass |
| [0038](./adr/0038-local-producer-leases.md) | Local producer leases: one producer per cache object key, held by a non-inherited operating-system file lock, coalesces concurrent cache misses; waiters recheck before work, and a crashed producer's released guard is reclaimable |
| [0039](./adr/0039-outdated-update-subcommands.md) | `lwpt outdated` + `lwpt update` as the Dependabot-equivalent for git-host dependencies over smart-HTTP tag listing; `update` rewrites constraints in place and runs the install transaction; subcommand surface 12 → 14 |
| [0040](./adr/0040-bounded-shared-cache-lifecycle.md) | One aggregate per-user shared-cache byte budget (default 10 GiB, `LWPT_CACHE_MAX_BYTES`) with deterministic least-recently-used eviction, per-object guards, and `lwpt repair` as the only maintenance path |
| [0041](./adr/0041-verified-test-executable-cache.md) | Verified test executables are reused through the build-result cache under a distinct `test-program` identity; every hit still runs, and test results are never cached |
| [0042](./adr/0042-keep-test-grouping-in-userland.md) | Test grouping stays in userland: `lwpt test` runs every discovered program or exactly the selected ones, with no path-inferred tiers or `--tier`; inventory schema v2 drops the tier field |
| [0043](./adr/0043-self-hosted-registry-origin.md) | Self-hosted registry origin command family, content-addressed storage, atomic signed state, recovery, and native TLS lifecycle |
| [0044](./adr/0044-test-seams-only-in-test-builds.md) | `LWPT_TEST_*` fetch and fault seams compile only into the `lwpt-testing` build (`INSTALL_TESTING`); release binaries ignore them |
| [0045](./adr/0045-verified-registry-mirror.md) | Verified registry mirror: `registry init --role mirror`, `registry sync` as the mirror's only network operation, `registry verify`, local `registry rotate-key`, hash-bound accepted state, transfer and disk budgets, and the checkpoint lifetime ceiling and clock-rollback floor; extends [0043](./adr/0043-self-hosted-registry-origin.md) |
| [0046](./adr/0046-skill-owned-delivery.md) | Delivery is skill-owned: the repository keeps the `delivery-admission` PR gate, manual and diagnostic `ci.yml` dispatch, and a full-CI run on every PR's exact head; supersedes [0032](./adr/0032-managed-delivery-state-and-proof.md) |
| [0047](./adr/0047-commit-pins-must-be-reachable.md) | Commit-SHA pins must be full SHAs reachable from an advertised branch or tag, proven with a commits-only protocol v2 fetch; amends [0009](./adr/0009-source-syntax-and-tag-resolution.md) |
| [0048](./adr/0048-git-host-fetch-trust.md) | Dependency fetches require HTTPS and declared hosts on every hop, refuse every non-globally-reachable address (classified in binary against the IANA registries), and treat locked tags and archives as immutable unless `--accept-moved-tags` |
| [0049](./adr/0049-registry-remote-publication.md) | Remote registry publication: `registry publish` (tar.gz, or zip normalized to one deterministic tar.gz), `issue-token`, and `revoke-token`, expiring Bearer-scoped tokens, content-identity idempotency, lease-serialized commits, audit records, and post-publish inclusion and consistency verification; amends [0043](./adr/0043-self-hosted-registry-origin.md) |
| [0050](./adr/0050-outbound-tls-client-options.md) | Outbound TLS client options: per-backend trust-anchor semantics (anchors-only or system plus anchors), PKCS#12 client identities, an explicit `InsecureSkipVerify`, peer-certificate DER, and HTTPClient options confined to the request's origin; amends [0016](./adr/0016-tls-backend-per-platform.md) |
| [0051](./adr/0051-registry-dependency-sources.md) | Registry dependency sources: `registry:` source syntax and root-only `[registries]` declarations, default-origin precedence, manifest trust pins without trust on first use, contact failover under one origin pin, additive lock fields in schema v3 (since amended to v4 by [0052](./adr/0052-lockfile-schema-v4-framed-tree-digest.md), which leaves them unchanged) with committed selection proofs for network-free `--frozen` and `--offline`, and per-user accepted state; amends [0009](./adr/0009-source-syntax-and-tag-resolution.md), [0048](./adr/0048-git-host-fetch-trust.md), and [0049](./adr/0049-registry-remote-publication.md) |
| [0052](./adr/0052-lockfile-schema-v4-framed-tree-digest.md) | Lockfile schema v4: `computedHash` becomes a framed, streamed `sha256-tree2` digest (length-prefixed UTF-8 paths and per-file normalized-content SHA-256 in the existing order), links refused inside installed modules under `--frozen`, a v3 lock is a hard error for every lock reader, and `lwpt repair` is the only, network-free and version-stable, v3-to-v4 upgrade; amends [0008](./adr/0008-lockfile-schema-v2-archive-hash.md), [0009](./adr/0009-source-syntax-and-tag-resolution.md), and [0051](./adr/0051-registry-dependency-sources.md) |
| [0053](./adr/0053-install-lock-ownership-and-reclamation.md) | `LWPT.InstallLock` owns `.lwpt/install.lock`, shared by install and `lwpt repair`; a kernel record lock is the liveness signal, repair takes a lock over only when that lock proves the owner dead and otherwise fails without changes, and a filesystem without record locks or a 0.7.0 record needs manual recovery; amends [0018](./adr/0018-install-transaction-module.md) |

## Spikes

[`spikes/`](./spikes/) holds point-in-time investigation snapshots — written once, not updated. New decisions land as ADRs or as edits to the appropriate canonical document.

| Spike | Topic |
| --- | --- |
| [`http-registry-spike.md`](./spikes/http-registry-spike.md) | The removed spike consumer, preserved as prior art for the self-hosted registry that shipped under [issue #29](https://github.com/frostney/lwpt/issues/29) ([ADR-0043](./adr/0043-self-hosted-registry-origin.md), [ADR-0051](./adr/0051-registry-dependency-sources.md)) |

## Conventions

- **Each topic has one home.** If a topic appears in two files, one of them must be a one-liner link to the canonical.
- **Every `docs/` file (except `README.md`) opens with an `## Executive Summary`** of 3-6 bulleted key points.
- **ADRs are immutable** once accepted. Cross-links to other docs may be edited when a target is renamed, but the substance does not change.
- **Spikes are snapshots** — not updated after creation. A new investigation produces a new file.

## Planned documentation

- `docs/decision-log.md` — the optional append-only decision log; not needed yet
  (ADRs cover what we need).
