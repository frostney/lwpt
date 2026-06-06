# LWPT documentation

Index of the [`docs/`](.) folder. The root-level [`README.md`](../README.md), [`AGENTS.md`](../AGENTS.md), [`CONTRIBUTING.md`](../CONTRIBUTING.md), and [`CONTEXT.md`](../CONTEXT.md) are the entry points; everything below is the deep dive.

| File | Covers |
| --- | --- |
| [`architecture.md`](./architecture.md) | Tech stack, the package-manager-is-the-foundation through-line, manifest model, resolver shape, fetch/extract/build/test pipeline, `.lwpt/` layout, error/idempotency model, deferred-contracts note |
| [`quick-start.md`](./quick-start.md) | Install FPC + InstantFPC + Lefthook, bootstrap, build, write a test, add a dependency, common errors |
| [`tooling.md`](./tooling.md) | Pinned tool versions, environment variables, lint/format/test commands, per-platform TLS backend (SChannel / SecureTransport / OpenSSL), EXDEV fallback, where each deferred contract lives |
| [`code-style.md`](./code-style.md) | Naming, file layout, formatter rules, manifest-declared formatter scope, line-endings, design tokens |
| [`build-system.md`](./build-system.md) | Bootstrap pattern, `lwpt build` contract, `[build]` section + lifecycle hooks (`[prebuild]` / `[postbuild]` / `[pretest]` / etc.), `build/` output rules, cross-compile |
| [`deployment.md`](./deployment.md) | Platform tier matrix, release process, per-platform TLS backend (SChannel / SecureTransport / OpenSSL), macOS quarantine, codesigning policy |
| [`ci.md`](./ci.md) | CI workflow shape (`ci.yml` / `pr.yml` / `release.yml` / `toolchain.yml`), trigger split, cross-build toolchain cache, install scripts |
| [`testing.md`](./testing.md) | Four-tier test policy, fixture strategy, mock HTTP server, the binary-fetch regression, test backlog |
| [`packages.md`](./packages.md) | The package set, divergence vs GocciaScript-older-copies, bootstrap chicken-and-egg, graduation roadmap (per [ADR-0017](./adr/0017-packages-lwpt-canonical.md)) |

## Decision records

[`adr/`](./adr/) holds Architectural Decision Records — short notes documenting non-obvious choices that future readers will wonder about. They're append-only: superseded decisions get new ADRs that reference the old, never edits-in-place.

| ADR | Topic |
| --- | --- |
| [0001](./adr/0001-program-name-as-constant.md) | Project name expressed as a single constant, never hardcoded |
| [0002](./adr/0002-lwpt-namespace-zero-install.md) | `.lwpt/` namespace, zero-install by default (modules + archives committed) |
| [0003](./adr/0003-vendored-permanent-fork-graduation.md) | (Superseded by [0017](./adr/0017-packages-lwpt-canonical.md).) Vendored code is a permanent fork, with a graduation roadmap — kept as historical record |
| [0004](./adr/0004-http-registry-deferred-to-v2.md) | HTTP registry source kind deferred to v2 |
| [0005](./adr/0005-self-host-build.md) | LWPT builds LWPT (self-host) with a one-time bootstrap script |
| [0006](./adr/0006-stack-contracts-deferred-from-v1.md) | Four stack contracts (link, duplication, codebase-health, architectural-drift) deferred from v1 |
| [0007](./adr/0007-formatter-scope-manifest-declared.md) | Formatter scope is manifest-declared (`[package].units` + `[format].include` minus `[format].exclude`, globs + explicit recursion), not convention-based |
| [0008](./adr/0008-lockfile-schema-v2-archive-hash.md) | Lockfile schema v2 splits `archiveHash` from `computedHash` for two-hash `--frozen` verification |
| [0009](./adr/0009-source-syntax-and-tag-resolution.md) | Source syntax (`<source>@<spec>` shorthand; git-host / URL / local kinds) + git smart-HTTP tag resolution; lockfile schema v3 |
| [0010](./adr/0010-init-subcommand.md) | `lwpt init` interactive scaffold + npm-init-y semantics with `--yes` |
| [0011](./adr/0011-build-lifecycle-hooks.md) | Lifecycle hooks (`[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]` + per-build-entry inline hooks) replacing the earlier `[generated]` section |
| [0012](./adr/0012-manifest-placeholder-interpolation.md) | Manifest placeholder interpolation (`{package.*}`, `{item.*}`, `{platform.*}`) with two-pass resolution and strict unknown-name errors |
| [0013](./adr/0013-run-subcommand-and-build-rename.md) | `lwpt run` subcommand for user-declared scripts + subcommand aliasing; `[targets]` renamed to `[build]` with single-entry shorthand |
| [0014](./adr/0014-packages-extraction.md) | Workspace packages under `packages/<name>/` for HTTPClient / CLI / Semver / TOML (extended by ADR-0015 to add `testing`); `[workspaces]` auto-discovery; monorepo symlink/junction install |
| [0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) | `lwpt export` retired; `TestingPascalLibrary` graduates to the `testing` workspace package; subcommand surface 8 → 7 |
| [0016](./adr/0016-tls-backend-per-platform.md) | TLS backend is platform-native (SChannel on Windows, SecureTransport on macOS, OpenSSL on Linux); CI guard prevents OpenSSL DLL dependency on Windows |
| [0017](./adr/0017-packages-lwpt-canonical.md) | Packages are LWPT-canonical workspace projects; GocciaScript is the first named adopter committed to Path A (full toolchain adoption); supersedes [0003](./adr/0003-vendored-permanent-fork-graduation.md) |
| [0018](./adr/0018-install-transaction-module.md) | Install transaction moves behind a dedicated `LWPT.Install` module; hooks stay outside, frozen remains verification-only, and lockfile/cfg commits are owned by the transaction seam |

## Spikes

[`spikes/`](./spikes/) holds point-in-time investigation snapshots — written once, not updated. New decisions land as ADRs or as edits to the appropriate canonical document.

| Spike | Topic |
| --- | --- |
| [`http-registry-spike.md`](./spikes/http-registry-spike.md) | The HTTP registry consumer that lived in the spike; removed from v1 per ADR-0004; v2 starting point |

## Conventions

- **Each topic has one home.** If a topic appears in two files, one of them must be a one-liner link to the canonical.
- **Every `docs/` file (except `README.md`) opens with an `## Executive Summary`** of 3-6 bulleted key points.
- **ADRs are immutable** once accepted. Cross-links to other docs may be edited when a target is renamed, but the substance does not change.
- **Spikes are snapshots** — not updated after creation. A new investigation produces a new file.

## Deferred from v1 documentation

These are *not* in v1's `docs/` set; each has a follow-up workstream:

- `CHANGELOG.md` + `cliff.toml` — changelog automation via `git-cliff` deferred per Q11.
- `docs/registry-spec.md` — the spec for a v2 HTTP registry, derived from `spikes/http-registry-spike.md`.
- `docs/decision-log.md` — the optional append-only decision log; not needed yet (ADRs cover what we need).
