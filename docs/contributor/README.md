# LWPT contributor guide

Documentation for building, testing, and releasing LWPT itself. Start with the [contributor quick start](./quick-start.md) and [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

| File | Covers |
| --- | --- |
| [`architecture.md`](./architecture.md) | Tech stack, the package-manager-is-the-foundation through-line, manifest model, resolver shape, fetch/extract/build/test pipeline, `.lwpt/` layout, error/idempotency model, deferred-contracts note |
| [`quick-start.md`](./quick-start.md) | Contributor setup: install FPC + InstantFPC + Lefthook, bootstrap LWPT itself, build, test, and common errors |
| [`tooling.md`](./tooling.md) | Pinned tool versions, environment variables, lint/format/test commands, per-platform TLS backend (SChannel / SecureTransport / OpenSSL), EXDEV fallback, where each deferred contract lives |
| [`code-style.md`](./code-style.md) | Naming, file layout, formatter rules, manifest scope with protected toolkit state, line-endings, design tokens |
| [`deployment.md`](./deployment.md) | Platform tier matrix, release process, per-platform TLS backend (SChannel / SecureTransport / OpenSSL), macOS quarantine, codesigning policy |
| [`ci.md`](./ci.md) | CI workflow shape (`ci.yml` / `pr.yml` / `release.yml` / `toolchain.yml`), trigger split, cross-build toolchain cache, install scripts |
| [`testing.md`](./testing.md) | Repository-owned test groups, selector policy, fixture strategy, mock HTTP server, the binary-fetch regression, test inventory |
| [`packages.md`](./packages.md) | The package set, divergence vs GocciaScript-older-copies, bootstrap chicken-and-egg, graduation roadmap (per [ADR-0017](./adr/0017-packages-lwpt-canonical.md)) |

Using LWPT in your own project? See the [user guide](../user/README.md). Decision records live in [`docs/adr/`](../adr/).
