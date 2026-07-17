# Agent Instructions

LWPT is a single-binary Pascal toolkit driven by a single `lwpt.toml` manifest. Nine subcommands (`init`, `install`, `add`, `remove`, `build`, `format`, `test`, `repair`, `run`) sit on top of a shared core that emits FPC response fragments the rest of the toolkit consumes.

This file is the operating manual for AI assistants and the canonical contract for what agents may not violate. Detailed how-to material lives under [`docs/`](./docs/); when this file mentions a topic in a sentence or two, the canonical home is one link away.

Product direction and delivery quality are defined separately in [`VISION.md`](./VISION.md), [`DEFINITION_OF_READY.md`](./DEFINITION_OF_READY.md), and [`DEFINITION_OF_DONE.md`](./DEFINITION_OF_DONE.md). Do not duplicate those documents here.

## Hard Constraints

These would silently corrupt the project if violated.

- **FreePascal only.** Do not introduce another compiled language. InstantFPC for one-off scripts (matches the `native-nostalgia-stack` scripts rule). Verify `fpc -iV` live before any change that depends on FPC behavior — memory is not an acceptable source.
- **LWPT builds LWPT.** Canonical build entry point is `./build/lwpt build`. Bootstrap once per fresh clone via `./bootstrap.sh` / `bootstrap.bat`. Do not introduce a Makefile, Justfile, or external build wrapper. See [ADR-0005](./docs/adr/0005-self-host-build.md).
- **The project name is a constant.** `PROGRAM_NAME = 'lwpt'` + `PROJECT_NAME = 'LWPT'` in `LWPT.Core`. Every literal use of the name in code derives from one of these. Never hardcode `'lwpt'` or `'LWPT'`. See [ADR-0001](./docs/adr/0001-program-name-as-constant.md).
- **Prose uppercases LWPT.** Industry-standard acronym treatment. Unit prefix `LWPT.<Subsys>.pas`; type prefix `TLWPT...`; exception prefix `ELWPT...`; environment variables uppercase (`LWPT_CACHE_DIR`). Binary, filenames, commands stay lowercase (`lwpt`, `lwpt.toml`).
- **Packages own their contents.** Per [ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md), the root LWPT manifest discovers `packages/<name>/` via `[workspaces]` and consumes each package's published API. Each package owns its versioning (semver 2.0.0), lifecycle hooks, test policy, and public surface. **Format scope follows the root-owns-by-default rule**: the root's `[format]` walks workspace packages too, and a package can opt out by declaring its own `[format]` section in `packages/<name>/lwpt.toml`. Cross-package edits go through the package's own contract (its `lwpt.toml`, its tests, its review process) even when the package happens to live in the same git repo. LWPT is the canonical source for the packages it ships; changes propagate to consumers (LWPT itself, GocciaScript via Path A adoption, third parties post-Phase-2 graduation) via `lwpt install`, not via side-channel edits. See [`docs/packages.md`](./docs/packages.md).
- **No patch markers.** Per ADR-0017 there is no upstream to mark deltas against; LWPT and GocciaScript are sister projects co-owned, with LWPT canonical. The `{ [gpm patch] }` and `{ [LWPT patch] }` markers are retired (their explanations were preserved as plain Pascal comments; git history carries the rest). New code does not get them.
- **HTTPS goes through the `HTTPClient` package** (raw sockets + per-platform TLS backend per [ADR-0016](./docs/adr/0016-tls-backend-per-platform.md): SChannel on Windows, SecureTransport on macOS, system OpenSSL on Linux). Do not switch to `fphttpclient`. The byte-safe `AppendRawBytes` accumulator that fixes the `Copy(PAnsiChar)` truncation bug is non-negotiable.
- **Git sources use HTTP archive endpoints**, not the git protocol. Tag listing uses git smart-HTTP `info/refs?service=git-upload-pack` (host-uniform, no JSON, no auth tokens for public repos). Source kinds: `skGitHost` (default `github`; `gitlab:` / `bitbucket:` prefixes for the others), `skURL` (any `https://...` tarball), `skLocal` (path or `local:` prefix). The bare-string shorthand `name = "<source>@<version>"` is the canonical form; the inline-table form is for advanced cases (`subdir`). The legacy `source = "github|gitlab|..." + repo/ref/tag/asset/path` shape is hard-errored. See [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md).
- **Zero-install by default.** `.lwpt/modules/` and `.lwpt/archives/` are committed (extracted + verification archives); `.lwpt/tmp/` is gitignored (install workspace). After `git clone`, `fpc @lwpt.cfg` builds the project without `lwpt install`. See [ADR-0002](./docs/adr/0002-lwpt-namespace-zero-install.md).
- **All multi-step file writes go through `.lwpt/tmp/`** with atomic rename to the committed path. The helpers `AtomicWriteText`, `AtomicWriteBytes`, `AtomicMoveFile`, `AtomicMoveDir` (in `LWPT.Core`) are the canonical entry points; every write to `.lwpt/modules/`, `.lwpt/archives/`, `lwpt.lock`, or `lwpt.cfg` must go through them. EXDEV-rename fallback is automatic (copy-then-delete). Adding a new committed-path write means using these helpers, not raw `TFileStream` or `SaveToFile`.
- **Compiler outputs are invocation-private.** `lwpt build` and `lwpt test` write executables, units, objects, resources, and compiled hooks only below their unique `.lwpt/sessions/<session-id>/` staging. A build may mutate its public manifest output only through fingerprint revalidation plus `AtomicReplaceFile`; `--clean` forces recompilation and never sweeps shared paths. See [ADR-0020](./docs/adr/0020-isolated-build-sessions.md).
- **`lwpt install` takes a cross-process lock** at `.lwpt/install.lock` (Unix: `O_CREAT|O_EXCL`; Windows: `LockFileEx`). Two concurrent installs in the same project fail fast with `EConcurrencyError` naming the holder's PID. A crashed install leaves the lock file behind; `lwpt repair` clears it. The lock encompasses the full pipeline: crash-recovery cleanup, resolve, fetch, extract, lockfile + cfg write — and, for the `add` / `remove` mutation flow ([ADR-0019](./docs/adr/0019-add-remove-subcommands.md)), the `lwpt.toml` commit + orphan pruning.
- **`lwpt.lock` is machine-written, schema v3.** Never hand-edit. The schema records the verbatim manifest source string, the resolver's chosen ref (tag/SHA), the actual archive URL, the extracted-tree sha256, and the cached-archive sha256. `--frozen` re-hashes the archive + tree and compares to both stored hashes. v1 and v2 lockfiles fail to load with a clear migration hint. Corrupt lockfile → delete + re-run `lwpt install` to regenerate. See [ADR-0008](./docs/adr/0008-lockfile-schema-v2-archive-hash.md) (v1→v2 archiveHash split) and [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md) (v2→v3 source-syntax refactor; the last lockfile schema break in v1).
- **Subcommand surface is frozen.** Adding a new subcommand requires an ADR. Current set: `install`, `add` + `remove` ([ADR-0019](./docs/adr/0019-add-remove-subcommands.md) — manifest-editing frontends to the install transaction; install-before-write ordering and lockfile-diff pruning are part of their contract), `build`, `format`, `test`, `repair`, `init` ([ADR-0010](./docs/adr/0010-init-subcommand.md)), `run` ([ADR-0013](./docs/adr/0013-run-subcommand-and-build-rename.md)). An earlier `export` subcommand was retired per [ADR-0015](./docs/adr/0015-drop-export-testing-becomes-workspace-package.md) when the testing framework graduated to `packages/testing/`. Two more (`lwpt health`, `lwpt duplication`) arrive from a separate workstream; both are pre-approved per [ADR-0006](./docs/adr/0006-stack-contracts-deferred-from-v1.md).
- **No new external dependencies** in the LWPT binary distribution. Contributor / CI tooling (when those workstreams land) is separate; documented in [`docs/tooling.md`](./docs/tooling.md).

## Runtime / Commands

Daily-driver commands are in the [Quick Reference](#quick-reference) table below. The walkthrough lives in [`docs/quick-start.md`](./docs/quick-start.md); the build contract + flag sets + bootstrap pattern in [`docs/build-system.md`](./docs/build-system.md).

Pre-commit gate (`lefthook.yml`): `lwpt format` (with `stage_fixed`). The heavyweight checks (`lwpt build` + `lwpt test`) run on the PR workflow rather than every local commit. Do not bypass with `--no-verify` unless explicitly asked.

## Agent Workflows

Use the project-local [`/prepare-release`](./.agents/skills/prepare-release/SKILL.md) workflow before cutting a release. It runs the complete project and E2E gates, checks cross-platform CI evidence, audits LWPT's architecture conformance, and previews the changelog. It stops before version selection, changelog generation, tagging, and publishing.

## Code Organization

[`docs/architecture.md`](./docs/architecture.md) is the canonical layout reference. Quick version:

- **`source/`** — Pascal sources. Project-owned units are `LWPT.<Subsys>.pas` (dotted, acronym uppercase); plus a handful of LWPT-internal utility units (`Platform.pas`, `Shared.inc`) that aren't (yet) extracted into `packages/`.
- **`packages/<name>/`** — LWPT-canonical workspace packages per [ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md). Each is a standalone Object Pascal project (own `lwpt.toml`, own `source/`, own tests, own version). Auto-discovered via `[workspaces]` glob in the root manifest.
- **`scripts/`** — InstantFPC scripts (`bootstrap.pas`).
- **`tests/`** — `integration/`, `e2e/`, `fixtures/`, `support/`. Unit tests are co-located in `source/` as `*.Test.pas`. See [`docs/testing.md`](./docs/testing.md).
- **`docs/`** — Authoritative documentation; one home per topic.
- **`.lwpt/`** — Toolkit state. `modules/` + `archives/` committed; `tmp/`, `sessions/`, and `install.lock` gitignored.
- **`build/`** — FPC output; never committed.

Unit-naming, formatter rules, vendored exclusion policy, and line-ending conventions live in [`docs/code-style.md`](./docs/code-style.md).

## Testing

[`docs/testing.md`](./docs/testing.md) is the canonical policy. Short version:

- Four tiers: **Unit** (co-located, always), **Integration** (`tests/integration/`, always), **E2E** (`tests/e2e/`, spawns `./build/lwpt` as a subprocess; opt-in via `--tier=e2e`), **Manual** (never automatic).
- The single most important test is the **HTTPClient binary-fetch regression** that pins the byte-safe `AppendRawBytes` accumulator's contract via a mock HTTP server. Lives in `packages/httpclient/source/HTTPClient.Test.pas`.
- E2E tests do **not** `uses LWPT.Core` — they spawn the binary and check exit codes, stdout/stderr, and on-disk side effects.

## Safety / Boundaries

- **`.lwpt/modules/` and `.lwpt/archives/` are committed state.** Direct modification by anything other than `lwpt install` — or its `add` / `remove` frontends, whose lockfile-diff pruning is the one sanctioned cleanup path per [ADR-0019](./docs/adr/0019-add-remove-subcommands.md) — is a Hard Constraint violation. Use `lwpt install --frozen` to verify against the lockfile.
- **`lwpt.lock` is machine-only.** Hand-editing produces undefined behavior.
- **Formatter scope is manifest-declared** per [ADR-0007](./docs/adr/0007-formatter-scope-manifest-declared.md): `[package].units` seed + `[format].include` adds + `[format].exclude` subtracts, all glob-aware, no implicit `tests/` walk. Root LWPT's `[format].include` covers tests + every workspace package (`packages/**/*.{pas,inc}`) so the canonical style applies across the monorepo by default. A workspace package opts out by declaring its own `[format]` section in `packages/<name>/lwpt.toml` (per ADR-0017's root-owns-unless-overridden model).
- **TLS backend is platform-native; OpenSSL only on Linux/Unix-not-Darwin.** Per [ADR-0016](./docs/adr/0016-tls-backend-per-platform.md), `TransportSecurity.pas` uses **SChannel on Windows**, **SecureTransport on macOS**, and **OpenSSL** (runtime-loaded via the system shared object) elsewhere. Windows + macOS releases ship the binary alone — no OpenSSL DLLs, ever. A CI guard in `pr.yml` (windows-cross-compile job), `ci.yml` (test job, Windows runner), and `release.yml` (build job, Windows targets) fails the build if `lwpt.exe` ends up referencing `libssl` / `libcrypto`. Adding `uses OpenSSL` under a Windows-active codepath is a release-blocker. Full per-platform story in [`docs/deployment.md`](./docs/deployment.md).
- **No secrets in fixtures.** Test artefacts pin specific tagged releases of small public repos; never include credentials, tokens, or anything touching a private endpoint.
- **Network operations are explicit.** `lwpt install` and its manifest-editing frontends `lwpt add` / `lwpt remove` (both run the install transaction per [ADR-0019](./docs/adr/0019-add-remove-subcommands.md)) are the only subcommands that hit the network in the default install mode. All other subcommands (including `lwpt test` without `--tier=e2e`) are offline.

## Product and Roadmap Boundaries

[`VISION.md`](./VISION.md) is the canonical product direction. GitHub issues and milestones are the roadmap source of truth; do not duplicate their planned scope or scheduling in repository documentation. Current documentation describes shipped behavior and links to investigated issues where a known gap matters.

## Quick Reference

| Want to... | Run |
| --- | --- |
| Scaffold a new project | `./build/lwpt init` (prompts for name / version / source / build / entry, then offers to run install + build) or `--yes` for npm-init-y defaults (scaffold only, no auto install/build) |
| First-time setup after clone | `./bootstrap.sh` then `./build/lwpt install` |
| Build everything (dev) | `./build/lwpt build` |
| Build one target (release) | `./build/lwpt build <target> --mode release` |
| Clean rebuild | `./build/lwpt build --clean` |
| Format the codebase | `./build/lwpt format` |
| Check formatting (CI) | `./build/lwpt format --check` |
| Run all tests | `./build/lwpt test` |
| Bound test concurrency / stop at first failure | `./build/lwpt test --jobs=4 --bail=1` |
| Run live-network + CLI-subprocess tests too | `./build/lwpt test --tier=e2e` |
| Run E2E tier offline (skip live-network tests) | `LWPT_SKIP_NETWORK=1 ./build/lwpt test --tier=e2e` |
| Add a new dependency | `./build/lwpt add <source[@version]>` (or edit `lwpt.toml`, then `./build/lwpt install`) |
| Update a dependency's version spec | `./build/lwpt add <source@new-version>` (same name → entry updated, stale archive pruned) |
| Remove dependencies (+ prune their modules) | `./build/lwpt remove <name> [<name>...]` |
| Verify project matches lockfile | `./build/lwpt install --frozen` |
| Recover install/build residue or abandoned worker leases | `./build/lwpt repair` |
| Invoke a user-declared run-script | `./build/lwpt run <script-name>` |
| Show the version | `./build/lwpt --version` |
