# Agent Instructions

LWPT is a single-binary Pascal toolkit driven by a single `lwpt.toml` manifest. Fifteen command families (`init`, `install`, `add`, `remove`, `outdated`, `update`, `build`, `format`, `duplication`, `test`, `repair`, `registry`, `run`, `health`, `agents`) sit on top of a shared core that emits FPC response fragments the rest of the toolkit consumes.

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
- **HTTPS goes through the `HTTPClient` package** (raw sockets + per-platform client TLS per [ADR-0016](./docs/adr/0016-tls-backend-per-platform.md): SChannel on Windows, SecureTransport on macOS, system OpenSSL on Unix-not-Darwin). Server accept follows [ADR-0024](./docs/adr/0024-openssl-server-tls-accept.md) on Unix-not-Darwin, [ADR-0033](./docs/adr/0033-schannel-server-tls-accept-on-windows.md) (native SChannel) on Windows, and native Secure Transport at the package seam on macOS compatibility runtimes. The registry uses Network.framework by default on macOS 26 and newer, and the shared portable listener plus Secure Transport on macOS 15 and older; dispatch uses the structured runtime product-version major, never a localized display string or CPU architecture, and the compatibility listener accepts only `localhost` or canonical IPv4. Do not switch to `fphttpclient`. The byte-safe `AppendRawBytes` accumulator that fixes the `Copy(PAnsiChar)` truncation bug is non-negotiable.
- **Git sources use HTTP archive endpoints**, not the git protocol. Tag listing uses git smart-HTTP `info/refs?service=git-upload-pack` (host-uniform, no JSON, no auth tokens for public repos). Source kinds: `skGitHost` (default `github`; `gitlab:` / `bitbucket:` prefixes for the others), `skURL` (any `https://...` tarball), `skLocal` (path or `local:` prefix). The bare-string shorthand `name = "<source>@<version>"` is the canonical form; the inline-table form is for advanced cases (`include` / `exclude` globs). The legacy `source = "github|gitlab|..." + repo/ref/tag/asset/path` shape is hard-errored. See [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md).
- **Zero-install by default.** `.lwpt/modules/` and `.lwpt/archives/` are committed (extracted + verification archives); `.lwpt/tmp/` is gitignored (install workspace). After `git clone`, `fpc @lwpt.cfg` builds the project without `lwpt install`. See [ADR-0002](./docs/adr/0002-lwpt-namespace-zero-install.md).
- **All multi-step file writes go through `.lwpt/tmp/`** with atomic rename to the committed path. The helpers `AtomicWriteText`, `AtomicWriteBytes`, `AtomicMoveFile`, `AtomicMoveDir` (in `LWPT.Core`) are the canonical entry points; every write to `.lwpt/modules/`, `.lwpt/archives/`, `lwpt.lock`, or `lwpt.cfg` must go through them. EXDEV-rename fallback is automatic (copy-then-delete). Adding a new write to toolkit-owned committed state (`.lwpt/**`, `lwpt.lock`, `lwpt.cfg`, the generated `AGENTS.md` block) means using these helpers, not raw `TFileStream` or `SaveToFile`; commands that intentionally rewrite user project files in place (`lwpt format`, `lwpt init` scaffolding) and the pre-build generator scripts (`scripts/stamp-version.pas`) sit outside this rule.
- **Compiler outputs are invocation-private.** `lwpt build` and `lwpt test` write executables, units, objects, resources, and compiled hooks only below their unique project-owned build session (`.lwpt/sessions/<session-id>/` by default, or an identity-verified relocated root). A build may mutate its public manifest output only through fingerprint revalidation plus `AtomicReplaceFile`; `--clean` forces recompilation and never sweeps shared paths. See [ADR-0020](./docs/adr/0020-isolated-build-sessions.md).
- **`lwpt install` takes a cross-process lock** at `.lwpt/install.lock` (Unix: `O_CREAT|O_EXCL`; Windows: `LockFileEx`). Two concurrent installs in the same project fail fast with `EConcurrencyError` naming the holder's PID. A crashed install leaves the lock file behind; `lwpt repair` clears it. The lock encompasses the full pipeline: crash-recovery cleanup, resolve, fetch, extract, lockfile + cfg write — and, for the `add` / `remove` mutation flow ([ADR-0019](./docs/adr/0019-add-remove-subcommands.md)), the `lwpt.toml` commit + orphan pruning.
- **`lwpt.lock` is machine-written, schema v3.** Never hand-edit. The schema records the verbatim manifest source string, the resolver's chosen ref (tag/SHA), the actual archive URL, the extracted-tree sha256, and the cached-archive sha256. `--frozen` re-hashes the archive + tree and compares to both stored hashes. v1 and v2 lockfiles fail to load with a clear migration hint. Corrupt lockfile → delete + re-run `lwpt install` to regenerate. See [ADR-0008](./docs/adr/0008-lockfile-schema-v2-archive-hash.md) (v1→v2 archiveHash split) and [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md) (v2→v3 source-syntax refactor; the last lockfile schema break in v1).
- **Subcommand surface is frozen.** Adding a new subcommand requires an ADR. Current set: `install`, `add` + `remove` ([ADR-0019](./docs/adr/0019-add-remove-subcommands.md) — manifest-editing frontends to the install transaction; install-before-write ordering and lockfile-diff pruning are part of their contract), `outdated` + `update` ([ADR-0039](./docs/adr/0039-outdated-update-subcommands.md) — Dependabot-equivalent for git-host deps; `update` rewrites constraints then runs the install transaction), `build`, `format`, `duplication` and `health` ([ADR-0006](./docs/adr/0006-stack-contracts-deferred-from-v1.md), with health's shipped contract in [`docs/health.md`](./docs/health.md)), `test`, `repair`, `init` ([ADR-0010](./docs/adr/0010-init-subcommand.md)), the `registry init|serve` family ([ADR-0043](./docs/adr/0043-self-hosted-registry-origin.md)), `run` ([ADR-0013](./docs/adr/0013-run-subcommand-and-build-rename.md)), and `agents` ([ADR-0027](./docs/adr/0027-agents-subcommand.md) — writes/verifies the marker-fenced command reference in `AGENTS.md`; the generated block below is its dogfooded output). An earlier `export` subcommand was retired per [ADR-0015](./docs/adr/0015-drop-export-testing-becomes-workspace-package.md) when the testing framework graduated to `packages/testing/`.
- **No new external dependencies** in the LWPT binary distribution. Contributor / CI tooling (when those workstreams land) is separate; documented in [`docs/tooling.md`](./docs/tooling.md).

## Runtime / Commands

Daily-driver commands are in the [Quick Reference](#quick-reference) table below. The walkthrough lives in [`docs/quick-start.md`](./docs/quick-start.md); the build contract + flag sets + bootstrap pattern in [`docs/build-system.md`](./docs/build-system.md).

Pre-commit gate (`lefthook.yml`): `lwpt format` + `lwpt agents` (both with `stage_fixed`). The heavyweight checks (`lwpt build` + `lwpt agents --check` + `lwpt test`) run on the PR workflow rather than every local commit. Do not bypass with `--no-verify` unless explicitly asked.

## Agent Workflows

Repository-owned capability, context, token-intervention, and delivery endpoint
policy lives in [`ORCHESTRATION.md`](./ORCHESTRATION.md). Generic orchestrators
consume that policy; they do not infer or install LWPT-specific infrastructure.

Use the project-local [`/prepare-release`](./.agents/skills/prepare-release/SKILL.md) workflow before cutting a release. It reuses exact-main project and E2E CI evidence, runs release-specific checks, audits LWPT's architecture conformance, and previews the changelog. It stops before version selection, changelog generation, tagging, and publishing.

## Code Organization

[`docs/architecture.md`](./docs/architecture.md) is the canonical layout reference. Quick version:

- **`source/`** — Pascal sources. Project-owned units are `LWPT.<Subsys>.pas` (dotted, acronym uppercase); plus a handful of LWPT-internal utility units (`Platform.pas`, `Shared.inc`) that aren't (yet) extracted into `packages/`.
- **`packages/<name>/`** — LWPT-canonical workspace packages per [ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md). Each is a standalone Object Pascal project (own `lwpt.toml`, own `source/`, own tests, own version). Auto-discovered via `[workspaces]` glob in the root manifest.
- **`scripts/`** — InstantFPC scripts (`bootstrap.pas`).
- **`tests/`** — `integration/`, `e2e/`, `fixtures/`, `support/`. Unit tests are co-located in `source/` as `*.Test.pas`. See [`docs/testing.md`](./docs/testing.md).
- **`docs/`** — Authoritative documentation; one home per topic.
- **`.lwpt/`** — Toolkit state. `modules/` + `archives/` committed; `tmp/`, `sessions/`, and `install.lock` gitignored.
- **`build/`** — FPC output; never committed.

Unit-naming, formatter rules, package formatting policy, and line-ending conventions live in [`docs/code-style.md`](./docs/code-style.md).

## Testing

[`docs/testing.md`](./docs/testing.md) is the canonical policy. Short version:

- Test groups are repository policy, not runner semantics: co-located unit programs, `tests/integration/`, and `tests/e2e/` plus package-owned E2E paths. `lwpt test` runs all discovered programs or exactly the supplied selectors.
- The single most important test is the **HTTPClient binary-fetch regression** that pins the byte-safe `AppendRawBytes` accumulator's contract via a mock HTTP server. Lives in `packages/httpclient/source/HTTPClient.Test.pas`.
- Root CLI E2E tests do **not** `uses LWPT.Core` — they spawn the binary and check exit codes, stdout/stderr, and on-disk side effects. Package E2E tests exercise only that package's published surface against real operating-system resources.

## Safety / Boundaries

- **`.lwpt/modules/` and `.lwpt/archives/` are committed state.** Direct modification by anything other than `lwpt install` — or its `add` / `remove` frontends, whose lockfile-diff pruning is the one sanctioned cleanup path per [ADR-0019](./docs/adr/0019-add-remove-subcommands.md) — is a Hard Constraint violation. Use `lwpt install --frozen` to verify against the lockfile.
- **`lwpt.lock` is machine-only.** Hand-editing produces undefined behavior.
- **Formatter scope is manifest-declared, with toolkit state protected by default** per [ADR-0007](./docs/adr/0007-formatter-scope-manifest-declared.md) and [ADR-0028](./docs/adr/0028-default-toolkit-state-format-exclusion.md): `[package].units` seeds + `[format].include` adds + toolkit-state default exclusion (root `.lwpt/**`, redirected toolkit paths, and only the project-owned `p-<hash>` namespace below a shared `sessions-dir` base) unless explicitly included + `[format].exclude` final subtraction, all glob-aware, no implicit `tests/` walk. Root LWPT's `[format].include` covers tests + every workspace package (`packages/**/*.{pas,inc}`) so the canonical style applies across the monorepo by default. A workspace package opts out by declaring its own `[format]` section in `packages/<name>/lwpt.toml` (per ADR-0017's root-owns-unless-overridden model).
- **TLS is platform-native on Windows and macOS in both directions; Unix-not-Darwin uses OpenSSL.** Per [ADR-0016](./docs/adr/0016-tls-backend-per-platform.md), outbound `TransportSecurity.pas` clients use **SChannel on Windows**, **SecureTransport on macOS**, and runtime-loaded **OpenSSL** elsewhere. Per [ADR-0024](./docs/adr/0024-openssl-server-tls-accept.md), server contexts take size-capped caller-supplied **PKCS#12 bytes** as the primary input, strictly validate certificate policy and bundled-chain coherence by default without platform trust, and publish reloads as immutable reference-counted snapshots. The convenience path overload opens once without following links; permissive self-signed development is explicit. Server accept is **native SChannel** on Windows per [ADR-0033](./docs/adr/0033-schannel-server-tls-accept-on-windows.md) — no OpenSSL is linked or loaded anywhere on Windows, and `i386-win32` is supported — **Secure Transport** on macOS at the HTTPClient seam, and **OpenSSL 3 or newer** on Unix-not-Darwin. The registry keeps Network.framework as the macOS 26-and-newer default and selects the shared portable listener plus HTTPClient Secure Transport on macOS 15 and older, using the structured runtime macOS product version rather than a localized display string or architecture. The Secure Transport identity is imported into an isolated temporary keychain without changing the default keychain or search list, is removed when its last immutable snapshot is released, and is recovered after a hard kill only when its filename is exact, its file is same-user regular storage, and its owner PID is definitely dead; recovery is scan-capped. `Active` means the server handshake is authenticated, retained ciphertext must drain before another protocol operation, and consumers must enforce a handshake deadline and byte budget. Encrypted input and output capacities are independently configured per context (each 64 KiB by default, each valid from 17–256 KiB); input uses accepted-prefix feeds, cumulative counters, and high/low-watermark backpressure, while output exposes exact pending and remaining capacity. OpenSSL is never import-linked, statically linked, or shipped in LWPT release archives, and Windows and macOS binaries contain no OpenSSL relationship at all. The guards in `pr.yml`, `ci.yml`, and `release.yml` inspect PE imports, imported OpenSSL symbol families, and link inputs, with positive parser canaries. Full per-platform story in [`docs/deployment.md`](./docs/deployment.md).
- **No secrets in fixtures.** Test artefacts pin specific tagged releases of small public repos; never include credentials, tokens, or anything touching a private endpoint.
- **Network operations are explicit.** Outbound toolkit network access is limited to `lwpt install` and its manifest-editing frontends `lwpt add` / `lwpt remove` (both run the install transaction per [ADR-0019](./docs/adr/0019-add-remove-subcommands.md)) plus `lwpt outdated` / `lwpt update` ([ADR-0039](./docs/adr/0039-outdated-update-subcommands.md) — tag listing; `update` may also fetch archives). `lwpt registry serve` is the only toolkit-owned inbound listener and serves its configured origin until stopped. Test programs own their own network policy; LWPT's live-network programs require `LWPT_ENABLE_NETWORK=1`.

## Product and Roadmap Boundaries

[`VISION.md`](./VISION.md) is the canonical product direction. GitHub issues and milestones are the roadmap source of truth; do not duplicate their planned scope or scheduling in repository documentation. Current documentation describes shipped behavior and links to investigated issues where a known gap matters.

## Quick Reference

Workflow knowledge that is not derivable from the command surface. The generated command reference below (the `lwpt agents` block) is canonical for subcommands, usage, and options.

| Want to... | Run |
| --- | --- |
| First-time setup after clone | `./bootstrap.sh` then `./build/lwpt install` |
| Run LWPT's E2E paths offline | `./build/lwpt test 'tests/e2e/*.Test.pas' 'packages/*/tests/e2e/*.Test.pas'` |
| Add a dependency without `lwpt add` | edit `lwpt.toml`, then `./build/lwpt install` |
| See which git-host deps have newer tags | `./build/lwpt outdated` (`--json` for the machine report) |
| Initialize or run a self-hosted registry origin | `./build/lwpt registry init` then `./build/lwpt registry serve` |
| Update outdated git-host deps | `./build/lwpt update` or `./build/lwpt update <name>` |
| Update a dependency's version spec by hand | `./build/lwpt add <source@new-version>` (same name → entry updated, stale archive pruned) |
| Show the version | `./build/lwpt --version` |
| Report Pascal token clones | `./build/lwpt duplication` (`--json` for the machine envelope) |

<!-- lwpt:agents:begin -->

## `lwpt` command reference

Generated by `lwpt agents` from the toolkit's command registry and this project's manifest. Everything between the `lwpt:agents` markers is machine-written: edit outside the markers only, regenerate with `lwpt agents`, verify with `lwpt agents --check`. Run `lwpt <command> --help` for the same reference in a terminal.

### Subcommands

- `lwpt install [--frozen] [--offline] [--silent]` — Resolve and fetch dependencies
  - `--frozen` — CI mode: refuse to update the lockfile, refuse network, verify hashes
  - `--offline` — Restore locked dependency state without network access
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt add <source[@version]> [--name <name>] [--silent]` — Add a dependency to the manifest and install it
  - `--name=<value>` — Dependency name in the manifest (default: the source's last path segment)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt remove <name> [<name>...] [--silent]` — Remove dependencies from the manifest and prune their modules
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt outdated [--json] [--silent]` — Compare locked git-host dependencies to advertised tags
  - `--json` — Emit a machine-readable report of each compared dependency
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt update [name ...] [--silent]` — Bump constraints and reinstall newer git-host dependencies
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt build [entry...] [--mode dev|release] [--clean] [--jobs N] [--verbose] [--no-cache] [--silent]` — Compile manifest build entries
  - `--mode=<value>` — Build mode: dev (default) or release
  - `--clean` — Force a full rebuild in fresh private staging
  - `--jobs=<N>` — Maximum concurrent build entries (default: machine budget)
  - `--verbose` — Replay successful build-entry logs
  - `--no-cache` — Compile without reading or writing reusable build results
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt format [--check] [--silent]` — Format uses-clauses and identifiers
  - `--check` — Report files needing formatting without rewriting; exit 1 if any
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt duplication [--json] [--silent]` — Report manifest-scoped Pascal token clones
  - `--json` — Emit the deterministic machine-readable analysis envelope
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt test [selector...] [--jobs N] [--bail N] [--verbose] [--inventory] [--no-cache] [--silent]` — Discover and run *.Test.pas files
  - `--jobs=<N>` — Maximum concurrent test programs (default: shared machine budget)
  - `--bail=<N>` — Stop after N compile or runtime failures; 0 runs the full queue
  - `--verbose` — Replay successful test logs
  - `--inventory` — Emit registered suites and cases as deterministic JSON without running tests
  - `--no-cache` — Compile without reading or writing reusable test executables
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt repair [--silent]` — Recover project and shared-cache residue
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt registry <init|serve> [--data-dir <path>] [configuration options] [--silent]` — Initialize or serve a self-hosted registry origin
  - `--data-dir=<value>` — Origin data directory (default: .lwpt/registry)
  - `--identity=<value>` — Stable canonical HTTPS origin identity (init only)
  - `--base-url=<value>` — Canonical public base URL (init only; default: http://localhost:8080)
  - `--listen=<value>` — Listen address (init only; default: localhost)
  - `--port=<N>` — Listen port (init only; default: 8080)
  - `--tls-pkcs12=<value>` — PKCS#12 identity path required by HTTPS (init only)
  - `--tls-password-env=<value>` — Environment variable containing the PKCS#12 password (init only)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt init [--yes] [--force] [--adopt] [--silent]` — Scaffold a new LWPT project or adopt an existing manifest
  - `--yes` — Skip prompts and use defaults derived from the directory name
  - `--force` — Overwrite an existing lwpt.toml without asking
  - `--adopt` — Fill in missing scaffold around an existing manifest without modifying it
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt run <task-name> | <subcommand> [subcommand-args...] [--silent]` — Invoke a user-declared run task (or a built-in subcommand by name)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt health [--json] [--hotspots] [--silent]` — Report Pascal complexity and optional Git hotspots
  - `--json` — Write the deterministic machine-readable report
  - `--hotspots` — Enrich complexity with the latest 100 commits of local Git churn
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt agents [--check] [--silent]` — Write or verify the agent-facing command reference in AGENTS.md
  - `--check` — Verify the AGENTS.md block matches the current command surface; exit 1 when stale
  - `--silent` — Suppress ordinary output and emit only the final command result

### Run tasks

No run tasks declared in `lwpt.toml`.

### Manifest schema

Generated from the same immutable structural registry used by manifest validation. Domain-specific syntax and cross-field rules remain in the parser; see the project documentation for those details.

- `[package]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Package identity and Pascal unit roots.
  - `name`: string; optional; default: `unnamed`; invalid values are ignored as absent. Package name; the legacy root name fallback still warns.
  - `version`: string; optional; default: `0.0.0`; invalid values are ignored as absent. Package version.
  - `units`: array of strings; optional; default: `empty`; invalid values and items are skipped. Pascal unit-root paths.
- `[dependencies]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named dependency declarations.
  - `<name>`: string or table; optional; other values retain legacy handling. Bare `<source>@<version>` shorthand or an inline table.
- `[dependencies].<name>` — string or inline table; all manifests; other values retain legacy handling; unknown keys are ignored. A source shorthand or expanded dependency declaration.
  - `source`: string; required; invalid values are errors. `owner/repo` (GitHub), `<host>:owner/repo` (built-in or custom host), an HTTPS tarball, a local path, or `workspace:<version>`.
  - `version`: string; optional; default: `none`; invalid values are ignored as absent. Version range, exact version, SHA, or tag.
  - `include`: array of strings; optional; default: `all files`; invalid values and items are skipped. Post-extraction include globs.
  - `exclude`: array of strings; optional; default: `none`; invalid values and items are skipped. Post-extraction exclude globs.
  - `repo`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `ref`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `tag`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `asset`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `path`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `subdir`: retired; optional; invalid values are errors. Retired; use include globs.
- `[sources]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named custom Git-host URL templates.
  - `<name>`: table; optional; invalid values are ignored as absent. One custom source declaration.
- `[sources].<name>` — inline table; all manifests; invalid values are ignored as absent; unknown keys are ignored. One custom Git-host source.
  - `archive`: string; required; invalid values are errors. HTTPS archive template containing {user}, {repository}, and {ref}.
  - `git`: string; required; invalid values are errors. HTTPS smart-HTTP template containing {user} and {repository}.
- `[workspaces]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Workspace discovery globs.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace discovery globs.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace exclusion globs.
- `[build]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Single-entry shorthand or named build entries.
  - `<name>`: string or table; optional; other values retain legacy handling. Named entry; build.source enables single-entry shorthand.
- `[build].<name>` — string or table; all manifests; other values retain legacy handling; unknown keys are ignored. One compiler-neutral build entry.
  - `source`: string; conditional; invalid values are ignored as absent. Compiler entry-point path.
  - `output`: string; optional; default: `build/<name>`; invalid values are ignored as absent. Published executable path.
  - `depends`: array of strings; optional; default: `empty`; invalid values are errors. Prerequisite build-entry names.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered compiler-driver arguments.
  - `compiler`: string; optional; default: `[compiler].default`; root manifest only; invalid values are errors. Named compiler-profile override.
  - `target`: table; optional; default: `compiler native target`; root manifest only; invalid values are errors. Explicit target tuple.
  - `prebuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry prebuild command map.
  - `postbuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry postbuild command map.
- `[build].<name>.target` — table; root manifest only; invalid values are errors; unknown keys are errors. An explicit complete compiler target tuple.
  - `os`: string; required; invalid values are errors. Target operating system.
  - `architecture`: string; required; invalid values are errors. Target architecture.
  - `abi`: string; optional; default: `empty`; invalid values are errors. Optional target ABI.
  - `environment`: string; optional; default: `empty`; invalid values are errors. Optional target execution environment.
- `[compiler]` — table; root manifest only; invalid values are errors; unknown keys are ignored. Root-owned compiler profile selection.
  - `default`: string; optional; default: `host default`; invalid values are errors. Default profile name.
  - `profiles`: table; optional; default: `empty`; invalid values are errors. Named compiler-profile map.
- `[compiler.profiles].<name>` — table; root manifest only; invalid values are errors; unknown keys are ignored. One built-in or external compiler profile.
  - `driver`: string; required; invalid values are errors. Built-in or external driver identity.
  - `command`: string; optional; default: `driver default`; invalid values are errors. Direct compiler command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `version`: string; optional; default: `*`; invalid values are errors. Compiler version constraint.
  - `executable`: retired; optional; invalid values are errors. Retired; use command and args.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[version]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Generated version-include settings.
  - `output`: string; optional; default: `empty`; invalid values are ignored as absent. Generated include path.
  - `prefix`: string; optional; default: `BAKED`; invalid values are ignored as absent. Generated constant prefix.
- `[lwpt]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Toolkit-state path overrides.
  - `modules-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Installed-module directory override.
  - `archives-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Archive-cache directory override.
  - `tmp-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private temporary directory override.
  - `sessions-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private compiler-session directory override.
  - `cfg-file`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Compiler response-file override.
- `[format]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Formatter scope additions and subtractions.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope subtraction.
- `[analysis]` — table; all manifests; invalid values are errors; unknown keys are ignored. Shared Pascal analysis source scope.
  - `include`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope subtraction.
- `[health]` — table; all manifests; invalid values are errors; unknown keys are errors. Optional complexity and hotspot limits.
  - `max-routine-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cyclomatic limit.
  - `max-routine-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cognitive limit.
  - `max-file-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cyclomatic limit.
  - `max-file-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cognitive limit.
  - `max-hotspot-score`: integer; optional; default: `unset`; invalid values are errors. Integer hotspot limit from 0 to 100.
- `[duplication]` — table; all manifests; invalid values are errors; unknown keys are ignored. Token-clone floor and optional percentage limit.
  - `minimum-tokens`: integer; optional; default: `100`; invalid values are errors. Clone floor; minimum accepted value is 25.
  - `maximum-percent`: integer; optional; default: `unset`; invalid values are errors. Integer duplication limit from 0 to 100.
- `[test]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Test compiler and scheduler policy.
  - `bail`: integer; optional; default: `0`; invalid values are errors. Non-negative failure count; zero runs the full queue.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered test compiler arguments.
- `[preinstall] / [postinstall] / [prebuild] / [postbuild] / [pretest] / [posttest]` — table; root manifest only; invalid values are ignored as absent; unknown keys are ignored. Root lifecycle command maps.
  - `<name>`: string or table; optional; invalid values are errors. One lifecycle hook.
- `<hook entry>` — string or inline table; all manifests; invalid values are errors; unknown keys are errors. A direct command with optional staleness gating.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[<task-name>]` — table; root manifest only; invalid values are errors; unknown keys are errors. An otherwise-unknown top-level section carrying command.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.

<!-- lwpt:agents:end -->
