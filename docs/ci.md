# CI

Ten GitHub Actions workflows retain the existing build-once/test-natively
matrix and add a repository-owned managed-delivery adapter. Expensive workflows
that execute pull-request code have read-only permissions. Controllers and
finalizers with write permission always run trusted default-branch code.

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `toolchain.yml` | `workflow_call` (reusable), `workflow_dispatch`, weekly `schedule` | Build + cache the cross-FPC toolchain |
| `ci.yml` | `push` to `main`, `workflow_dispatch` | Full integrated-main/terminal promotion matrix or one allow-listed native diagnostic slice |
| `pr.yml` | `pull_request`, `workflow_call` | Automatic ordinary gate or reusable read-only managed PR matrix |
| `release.yml` | tag push (`v?N.N.N`, `v?N.N.N-*`) | Cross-build → protected approval → package → publish GitHub Release |
| `delphi-native.yml` | `workflow_dispatch` | Optional Delphi 12+ Win64 smoke on a licensed self-hosted runner; never a required gate |
| `delivery-transition.yml` | `workflow_dispatch` | Trusted explicit `enrol`, `ci`, `review`, `diagnostic`, `full-ci`, `merge`, or `reset` endpoint |
| `delivery-pr.yml` | controller `workflow_dispatch` | Run `pr.yml` read-only for one admitted exact head |
| `delivery-observer.yml` | PR metadata, schedule, manual | Create pending checks and invalidate stale head/base/topology evidence |
| `delivery-finalizer.yml` | `workflow_run` completion | Conclude ordinary, managed, cancelled, and full-CI exact checks when GitHub emits the event |
| `delivery-watchdog.yml` | 15-minute schedule, manual | Reconcile terminal full-CI runs, then fail proof checks left nonterminal for 120 minutes |

Trigger split, mirroring GocciaScript's CI shape:

- **Ordinary PRs remain automatic.** `pr.yml` runs its Ubuntu, native Darwin,
  documentation, and win64 legs. The trusted finalizer aggregates that exact
  workflow result into `delivery-admission`.
- **Managed PRs use explicit transitions.** Their automatic `pr.yml` run stops
  successfully at a cheap routing job. The `ci` operation dispatches
  `delivery-pr.yml`, which calls the same matrix for the exact current head.
  `delivery:managed` does not assert native stack membership.
- **`ci.yml` has three exact uses.** A push to `main` verifies the integrated tree;
  rapid main pushes cancel older integrated-main runs. The `full-ci` operation
  checks out one frozen singleton or cumulative native-prefix top SHA. Those
  promotion runs are never coalesced. The `diagnostic` operation selects one
  allow-listed Windows target and test scope and cannot produce a proof check.
- **`release.yml` owns tag pushes** — `ci.yml` does not trigger on tags, so a tagged commit goes through a single cross-build pipeline (the release one) rather than two.

Repository rules make these contracts enforceable. The desired main ruleset is
versioned at `.github/rulesets/protect-main.json`: it requires resolved review
threads and `delivery-admission` from GitHub Actions integration ID `15368`.
The integration binding means a same-named status or check from another user or
app cannot satisfy the rule. Activate that payload only after the producer and
finalizer exist on the default branch:

```sh
gh api --method PUT repos/frostney/lwpt/rulesets/18086289 \
  --input .github/rulesets/protect-main.json
```

The public
[`delivery-admission` sandbox](https://github.com/frostney/lwpt-delivery-admission-spike/pull/1)
exercised pending, duplicate, stale-head, failure, cancellation, watchdog, and
recovery behavior. Its app-identity probe at
[`9b3afd4`](https://github.com/frostney/lwpt-delivery-admission-spike/commit/9b3afd43f44fb8c90c1a72aec41deafc8f09e81e)
left the PR blocked when the
[app-owned check failed](https://github.com/frostney/lwpt-delivery-admission-spike/actions/runs/30938047359)
even though a separate same-named commit status reported success; the
[`af05968` recovery](https://github.com/frostney/lwpt-delivery-admission-spike/actions/runs/30938166552)
restored a successful app-owned proof.

A separate release-tag ruleset restricts SemVer tag creation to the maintainer
and rejects tag updates or deletion. The protected `release` environment owns
the approval gate between successful builds and publication.

## Workflows

### Managed-delivery proof lifecycle

`delivery-observer.yml` creates one pending `delivery-admission` for the exact
PR head and native topology. A new head, base, order, or prefix fails stale
pending proof, removes readiness labels, and creates a new pending proof.
Managed forks fail closed without dispatching their code. Duplicate events reuse
the same external proof identity. Trusted mutations share one short-lived
repository concurrency lane so schedule, transition, finalizer, and watchdog
events cannot create or conclude competing proofs concurrently.

The endpoint and finalizer communicate through a trusted workflow run name
containing PR, SHA, topology digest where applicable, and check-run ID. The
read-only workflow cannot conclude its check. The default-branch finalizer
re-fetches the PR and native topology, binds the workflow result to the current
check, and then records success or terminal failure. A full-CI run dispatched
by `delivery-transition.yml` inherits the repository `GITHUB_TOKEN`; GitHub
allows that explicit `workflow_dispatch` but suppresses its subsequent
`workflow_run` event. The trusted watchdog therefore discovers terminal
full-CI runs every 15 minutes and passes their bound identity through the same
finalizer before applying its 120-minute timeout. Creation-time queries are
split when GitHub's filtered 1,000-result cap is reached, so recovery cannot
silently lose the matching run. Cancelled runs are failures, and duplicate or
reordered observations are harmless because a completed check is terminal.

The `diagnostic` operation runs one allow-listed native remediation slice. The
initial surface covers Windows x86_64/i386 default, E2E, and TLS slices, plus an
Intel-Darwin scheduling slice that runs only `TestScheduling.Test.pas` with a
90-second ceiling. When isolation changes the symptom, the same target can run
its default tier with a seven-minute ceiling. Both capture a native process
sample instead of consuming a full matrix as a hang probe. Target and selector
combinations are allow-listed as pairs: Windows-only selectors cannot silently
run on Darwin, and the scheduling probe cannot run on Windows. The endpoint
checks out the exact current PR head,
cannot accept a shell command or fork, uses a `diagnostic/...` run identity, and
never creates or satisfies a `full-ci` proof. A later diagnostic for the same
PR cancels the prior run.

The `review` operation opens the repository's review lane after PR admission.
The controller discovers active review automations from configured check names
and current-head review actors. At least one configured automation must emit
current-head evidence. Every automation that does is active and must reach its
configured terminal check conclusion and review state; configured but inactive
adapters do not block. Before `merge`, the controller also requires no
unresolved thread and a reply from an account with current maintain or admin
permission on every automation thread. Provider identities and terminal states
are data in `.github/delivery/review-automations.json`; controller logic does
not name vendors, and retry and quota policy remain external.
An adapter may bind one or more check names to trusted GitHub App slugs, accept
provider-specific terminal check conclusions, require or omit a terminal review
event, and list review-body markers that mean "not terminal". Those fields are
enough to replace a hosted reviewer or add a check-only custom reviewer without
changing controller code.
`merge:ready` records that point-in-time acceptance, so the coordinator invokes
the idempotent `merge` operation immediately before a singleton merge. For a
native prefix it preflights each `delivery:managed` member against the same
candidate, then integrates the frozen prefix bottom to top without unrelated
work in between. An ordinary member never uses the endpoint; at its merge turn
it remains individually subject to current branch protection and the ordinary
review policy. The coordinator never treats labels left by an earlier preflight
as durable proof.

`full-ci` is dispatched only as terminal promotion for a `ci:full-required`
candidate after current-base integration, exact-head PR admission, and review
convergence. Its frozen topology digest separates it from diagnostics. A head,
base/topology, or review change fails the pending proof and the observer cancels
the superseded matrix. Ordinary changes covered by PR CI do not receive a
pre-merge full matrix.

### `toolchain.yml` — cross-FPC toolchain build

Runs on `macos-latest`. Seeds native `aarch64-darwin` from Homebrew's FPC 3.2.2 install, then builds the cross-compilation toolchain and FPC packages slice needed for the non-native build targets:

| Target | CPU | OS |
| --- | --- | --- |
| `aarch64-darwin` | `aarch64` | `darwin` (native Homebrew-seeded units on macos-arm64) |
| `x86_64-darwin` | `x86_64` | `darwin` |
| `x86_64-linux` | `x86_64` | `linux` |
| `aarch64-linux` | `aarch64` | `linux` |
| `x86_64-win64` | `x86_64` | `win64` |
| `i386-win32` | `i386` | `win32` |

The build steps:

1. Install native FPC via Homebrew (`brew install fpc`) — the seed compiler.
2. Build GNU binutils 2.44 for the two Linux targets (`x86_64-linux`, `aarch64-linux`).
3. Download Linux crosslibs from `LongDirtyAnimAlf/fpcupdeluxe` (Ubuntu 22.04 amd64, Ubuntu 18.04 aarch64).
4. Compile soft-float units (`softfpu`, `ufloatx80`, `sfpux80`) for the native RTL.
5. Build cross-compilers `ppcrossx64` (x86_64 → for x86_64-darwin and x86_64-linux) and `ppcross386` (i386 → for i386-win32) by compiling `pp.pas` directly with the native `ppca64`.
6. Build the per-target FPC packages slice LWPT needs for the non-native targets: `rtl`, `rtl-objpas` (variants/strutils/dateutils), `rtl-generics` (Generics.Collections), `fcl-process` (Process), `paszlib` (ZStream), and the platform-appropriate socket package coverage (Sockets on Unix/Darwin, WinSock2 on Windows). Native `aarch64-darwin` keeps Homebrew's package layout, including `hash/crc.ppu` for `ZStream`'s dependency closure and `rtl-extra/sockets.ppu` for socket APIs.
7. Save the lot — `fpc-cross/`, `cross-binutils/`, `cross-libs/` — under the cache key `lwpt-fpc-cross-3.2.2-macos-arm64-v5`.

The whole job is `if: steps.cache-check.outputs.cache-hit != 'true'`-gated. On a cache hit, the workflow exits in seconds with `Toolchain already cached — nothing to build.`.

### `ci.yml` — build + test

**Build stage** (`macos-latest`, six-target matrix): restores the cached toolchain via the `toolchain.outputs.cache-key` value, invokes the matched cross-FPC against `source/lwpt.pas` with the `-Fu` / `-Fi` paths LWPT needs (`source/`, `packages/httpclient/source/`, `packages/cli/source/`, `packages/semver/source/`, `packages/toml/source/`, `packages/testing/source/`, plus the target's FPC packages slice, including `paszlib` for `ZStream`). Release flags `-O4 -dPRODUCTION -Xs -CX -XX -B` mirror `TLWPTFPCCompilerDriver.BuildArguments`' release translation. The resulting `lwpt` binary (or `lwpt.exe` for Windows targets) is `llvm-strip`-ped and uploaded as `lwpt-<target>`. An explicit `full-ci` dispatch checks out its controller-validated SHA rather than the default-branch workflow SHA.

**Test stage** (per-platform native runners, six-target matrix → five runners):

| Target | Runner |
| --- | --- |
| `aarch64-darwin` | `macos-latest` |
| `x86_64-darwin` | `macos-15-intel` |
| `x86_64-linux` | `ubuntu-latest` |
| `aarch64-linux` | `ubuntu-24.04-arm` |
| `x86_64-win64` | `windows-latest` |
| `i386-win32` | `windows-latest` |

Each runner installs FPC natively (`brew` / `apt` / `choco`), then the `x86_64-win64` leg runs a one-off `bootstrap.bat` cold-build smoke and deletes `build/` again so the rest of the stage still validates the downloaded cross-built artefact. After that, every runner downloads the cross-built `lwpt` binary and runs the full pipeline:

1. **Sanity** — `lwpt --help` (does the binary even load?)
2. **`lwpt install`** — workspace auto-discovery + symlink/junction creation
3. **`lwpt format --check`** — only on `aarch64-darwin` runner (formatting is platform-independent; one check is enough)
4. **`lwpt test --bail=1`** — default tier (unit + integration); compiles every `*.Test.pas` via the runner's native FPC, runs them concurrently, and stops quickly on the first failure
5. **`lwpt test --tier=e2e --bail=1`** — live network tier (Q23 decision: run on every platform to surface platform-specific HTTP / TLS / wire-format regressions that offline mocking misses)

Per [Q22=b](./adr/0014-packages-extraction.md), the runner side compiles tests at runtime via `lwpt test` rather than pre-compiling them on the cross-build stage. This exercises the full LWPT pipeline natively — including the resolver, the per-target cfg emitter, FPC's per-platform `{$IFDEF}` paths, and the install loop's symlink-vs-copy decision (junctions on Windows, symlinks on Unix).

### `pr.yml` — pre-merge PR gate

Mirrors GocciaScript's `pr.yml` shape, and is the **sole** pre-merge signal a PR sees (because `ci.yml` doesn't trigger on PRs). The main `build-and-test` job is a single Ubuntu runner:

1. Install FPC via `apt`
2. `./bootstrap.sh` — cold build of `build/lwpt` from a freshly-cloned repo
3. `./build/lwpt --help` (does the binary even load?)
4. `./build/lwpt install --frozen` (committed lockfile matches committed trees — runs *before* plain install so lock drift cannot be masked by regeneration)
5. `./build/lwpt install` (workspace auto-discovery + symlinks)
6. `./build/lwpt format --check`
7. `./build/lwpt build` (manifest-target compile)
8. `./build/lwpt agents --check` (generated command-reference drift)
9. `./build/lwpt test --bail=1` (default tier — unit + integration)

The live-network e2e tier runs pre-merge on the Linux leg only — a dedicated step that overrides the job-level skip with `LWPT_SKIP_NETWORK: "0"` (the harness skips only on the exact value `1`), added per [issue #102](https://github.com/frostney/lwpt/issues/102) after the #84 TLS-close and #101 timing classes proved invisible to a default-tier-only gate; every platform still runs e2e post-merge via `ci.yml`. A second PR job, `darwin-test`, natively bootstraps on `macos-latest` (brew FPC, independent of the cross-toolchain cache) and runs the default tier — the #105 env-race family and its masks all first surfaced on darwin legs. Bounded cost: ~5–6 min warm (hard cap 20 min), parallel to `build-and-test`. The remaining `ci.yml`-only legs (`x86_64-darwin`, `aarch64-linux`, `i386-win32`) stay post-merge. A separate blocking `docs` job runs `markdownlint-cli2` against the Markdown corpus.

The PR workflow deliberately uses the distro FPC (same as the install instructions in `README.md`), so any regression that only shows up with the system FPC's slightly older RTL gets caught before merge.

#### Windows signal (`windows-cross-compile` + `windows-test`)

A second job reuses `toolchain.yml` (`workflow_call`, exactly like `ci.yml`) and cross-compiles `source/lwpt.pas` for **`x86_64-win64` only**, mirroring `ci.yml`'s build-stage flags and unit paths. It exists because `{$IFDEF WINDOWS}` codepaths never compile on the Ubuntu runner: PR #17 merged green while breaking `main` with a `SysUtils.FindClose` vs `Windows.FindClose` unit-shadowing error that PR #21 then had to fix. One target suffices — win32 and win64 share the same `{$IFDEF WINDOWS}` sources. The job also runs the no-OpenSSL guard (ADR-0016 for clients, ADR-0033 for servers — Windows must contain no OpenSSL linkage in either direction) against the produced `lwpt.exe`, surfacing that release-blocker on the PR instead of post-merge.

The produced `lwpt.exe` is then uploaded for **`windows-test`**, which mirrors `ci.yml`'s build-once / test-natively split on a `windows-latest` runner: install FPC via choco (a verbatim copy of `ci.yml`'s step — `lwpt test` compiles `*.Test.pas` with the native FPC at run time per Q22=b), download the binary, then `lwpt install` + `lwpt test --bail=1` (default tier, offline). This catches what a compile alone cannot: Windows-only runtime regressions in lwpt itself (junction-vs-symlink installs, path handling, subprocess environment handling), scheduler cancellation/reaping, and compile breaks in test sources.

Deliberate scope limits — still post-merge only (`ci.yml`):

- **The `i386-win32` leg** (win32 and win64 share `{$IFDEF WINDOWS}` sources; the 32-bit leg re-verifies, it rarely diverges).
- **The e2e tier on non-Linux platforms** and the `bootstrap.bat` cold-build smoke (the Linux e2e leg runs pre-merge per #102).
- **`x86_64-darwin` and `aarch64-linux` runtime.** The aarch64-darwin PR leg covers `{$IFDEF DARWIN}` compile + arm64 runtime pre-merge (added per #102 after the #105 env-race family surfaced on darwin legs first); the intel-mac and arm-linux permutations stay post-merge — their unique-catch rate has not justified per-PR cost.

Cache economics: the toolchain cache key (`lwpt-fpc-cross-<fpc>-macos-arm64-<n>`) has no branch component, and GitHub Actions lets PR runs restore caches created on the base branch — so PR runs hit the toolchain that `ci.yml` pushes to `main` keep warm, and the `toolchain` job is a seconds-long cache lookup. On eviction, the PR run rebuilds the toolchain (~30 min) into its own cache scope (not shared across PRs); a weekly `schedule` cron on `toolchain.yml` re-warms the default-branch copy so that window is bounded even when `main` is quiet. `pr.yml` also sets `concurrency` with `cancel-in-progress`, so a superseded push doesn't keep burning the macOS runner.

#### Why not fully cross-platform on PRs?

A 6-target cross-build matrix runs in ~10–15 min on cached toolchain (and ~45 min cold), per PR push. Multiplied across the typical commit-amend-push-amend-push PR cycle, that's an order of magnitude more CI minutes than a single Ubuntu run. GocciaScript made the same trade-off: cheap iteration on PRs, exhaustive verification on the merged main tree. Platform-specific *runtime* regressions that slip through pr.yml surface in the post-merge ci.yml run on `main`; the maintainer reverts the offending commit or rolls a forward-fix PR. The win64 leg (cross-compile + native offline test run, ~3 min total on a warm cache) was the first deliberate exception, buying back the most common post-merge breakage class without paying for the full matrix; #102 extended the same reasoning to the Linux e2e step and the aarch64-darwin leg once those classes had bitten too.

### `release.yml` — tag-triggered release pipeline

Triggers on tags matching `v?N.N.N` or `v?N.N.N-*` (e.g. `0.1.0`, `0.1.0-rc.1` — the canonical form per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md), which adopts SemVer 2.0.0; the `v`-prefixed form `v0.1.0` is also accepted as a courtesy but not the recommended shape). Pre-release detection: any version containing a hyphen is published as `prerelease: true`.

The pipeline runs:

1. **`toolchain`** — reuses `toolchain.yml` via `workflow_call`. Cache hit ⇒ instant; cold ⇒ ~30 min rebuild on `macos-latest`.
2. **`build`** — six-target matrix, identical to `ci.yml`'s `build` stage, so the tagged binary equals the CI-validated binary.
3. **`publish`** — waits for approval through the protected `release`
   environment, packages each target as an archive, generates SHA-256
   checksums, extracts that tag's notes from the committed `CHANGELOG.md`, and
   creates the GitHub Release with all archives + the checksums file attached.

#### Release artefact naming

| Target | Archive | Asset name (`<version>` = the tag value; if a `v` prefix was used, it's stripped) |
|--------|---------|--------------------------------------------------|
| `aarch64-darwin` | tar.gz | `lwpt-<version>-macos-arm64.tar.gz` |
| `x86_64-darwin` | tar.gz | `lwpt-<version>-macos-x64.tar.gz` |
| `x86_64-linux` | tar.gz | `lwpt-<version>-linux-x64.tar.gz` |
| `aarch64-linux` | tar.gz | `lwpt-<version>-linux-arm64.tar.gz` |
| `x86_64-win64` | zip | `lwpt-<version>-windows-x64.zip` |
| `i386-win32` | zip | `lwpt-<version>-windows-x86.zip` |
| — | text | `lwpt-<version>-checksums.txt` |

Each archive contains a single top-level directory `lwpt-<version>-<display>/` with:

- The `lwpt` binary (or `lwpt.exe` on Windows)
- `README.md`, `CONTEXT.md`, `CONTRIBUTING.md`, `AGENTS.md`
- `docs/{quick-start,architecture,build-system}.md`

#### Install scripts

The release ships matching install scripts at `scripts/install.sh` (macOS + Linux) and `scripts/install.ps1` (Windows). Both can be served via `raw.githubusercontent.com` and consumed with the one-liner idiom popularised by `rustup`, `brew`, and `bun`:

```sh
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/frostney/lwpt/main/scripts/install.sh | sh

# Windows (PowerShell)
irm https://raw.githubusercontent.com/frostney/lwpt/main/scripts/install.ps1 | iex
```

Honoured environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `INSTALL_DIR` / `LWPT_INSTALL_DIR` | `/usr/local/bin` / `$env:USERPROFILE\bin` | Where the binary lands |
| `LWPT_VERSION` | latest release | Specific tag to install |
| `LWPT_REPO` | `frostney/lwpt` | Override the source repo (fork) |

Both scripts download the per-platform archive + the checksums file, verify SHA-256, extract, and move the binary into the install dir. The Windows variant additionally appends the install dir to the user `Path` if it isn't already there.

The scripts mirror the shape of [GocciaScript's installers](https://gocciascript.dev/install.sh), adapted for LWPT's single-binary distribution.

## Triggers (summary)

- `ci.yml`: `push` to `main`, `workflow_dispatch`
- `pr.yml`: `pull_request`, `workflow_call` from `delivery-pr.yml`
- `release.yml`: `push` of a `v?N.N.N` or `v?N.N.N-*` tag
- `toolchain.yml`: invoked by `ci.yml`, `pr.yml`, and `release.yml` via `workflow_call`; also `workflow_dispatch` for manual cache warming and a weekly `schedule` cron (Mondays 05:00 UTC) that keeps the default-branch cache warm
- managed delivery: explicit transition dispatch, PR metadata observer,
  workflow-run finalizer, and scheduled watchdog as listed above

A given commit triggers at most one heavyweight cross-build pipeline (`ci.yml` after merge, OR `release.yml` after tag), not both. PRs trigger only the cheap `pr.yml` (whose single win64 cross-compile rides the cached toolchain).

### `delphi-native.yml` — licensed backend smoke

The Delphi driver is covered in ordinary CI by deterministic translation,
probing, target-matrix, diagnostic, and artifact-publication fixtures. A real
compiler invocation needs a licensed installation, so native execution is a
manual, non-required workflow on a maintainer-provisioned runner carrying the
`self-hosted`, `windows`, and `delphi` labels. The dispatcher supplies the
absolute `dcc64.exe` path. The workflow verifies FPC 3.2.2 for LWPT's own
bootstrap, builds a scratch Win64 console project through the `delphi` profile,
and runs the resulting executable. It does not run on pull requests, pushes,
tags, or schedules and cannot consume hosted-runner minutes while no licensed
runner is available.

## When to bump `CACHE_VERSION`

Bump `toolchain.yml`'s `CACHE_VERSION` env var (currently `v5`) when:

- FPC version changes (`FPC_VERSION` lives **only** in `toolchain.yml`; `ci.yml`, `pr.yml`, and `release.yml` consume it via the workflow's `fpc-version` output, so one edit covers all consumers)
- A new target is added to the matrix
- The FPC packages slice is rescoped (e.g. when a future LWPT change requires a package not in the current set)
- Toolchain scripts themselves change in a way that affects the binary content of the cache

A bump invalidates the cache on the next workflow run; the toolchain rebuild takes ~30 minutes on macos-latest. Pure consumer changes (LWPT source edits, package additions inside `packages/`, manifest tweaks) do not require a cache bump — the cached cross-toolchain is reused as-is.

## Adding a new target

1. Add the target to the matrix in `toolchain.yml`'s `build_target` invocations + `ci.yml`'s `build` matrix.
2. Map it to a GitHub Actions runner in `ci.yml`'s `test` matrix.
3. Bump `CACHE_VERSION` in `toolchain.yml`.
4. Update the targets table above.

## Live-network E2E exercise

The `test --tier=e2e` step runs three live fetches per platform:

- `octocat/Hello-World @ 7fd1a60b…` from GitHub (stable historical commit)
- `gitlab-examples/ci-debug-trace @ dd648b2e48ce6518303b0bb580b2ee32fadaf045` from GitLab
- `atlassian/atlaskit @ d7ac1acad54e…` from Bitbucket

Per Q23=c, these run on every platform (6 in total per push). Total network traffic per push: 18 archive fetches. If this becomes a rate-limit concern, the future fallback is `LWPT_SKIP_NETWORK=1` on N-1 of the 6 runners (the env var is respected by every E2E test).

### Transient host downtime skips, it does not fail

A live-network E2E test validates LWPT's fetch → extract → lockfile pipeline against a real host. When the *host* is unreachable — a TCP connect failure or DNS resolution failure to `github.com` / `gitlab.com` / `bitbucket.org` — that is third-party infrastructure flakiness, **not** an LWPT defect, so the affected suite **skips** rather than fails. The detection (`IsNetworkUnavailable` in `tests/support/Tests.LwptSubprocess.pas`) is deliberately narrow: it matches only HTTPClient's two clean pre-transfer errors — `Failed to connect to <host>:<port>` and `Failed to resolve host: <host>` — both of which fire before any byte is fetched or parsed.

Crucially, this is **not** a blanket "ignore e2e failures". An install that *connects* but then produces wrong output — a truncated chunked body, a missing header terminator, a hash mismatch, a missing extracted file — leaves the skip flag unset, so the assertions run and fail hard. That split is the whole point: third-party downtime is noise; an LWPT regression in the fetch/extract/verify path is a real failure that must turn the build red. (The `0.1.0-rc.1` cycle surfaced exactly this: an `i386-win32` runner intermittently failed to reach `bitbucket.org:443`, reddening an otherwise-green main for a reason that had nothing to do with LWPT.)

## What CI does NOT cover

- **`lwpt build` doesn't run on the test runner** — running it would rebuild `lwpt` with the runner's native FPC, defeating the cross-build verification. The pipeline tests the cross-built binary's *behavior* (install / format / test); the cross-build *itself* is verified by the build-stage compile.
- **No artefact retention beyond 7 days** — set in `upload-artifact`. CI artefacts are debugging aids, not release artefacts. The release artefacts published by `release.yml` are permanent (GitHub Releases).
- **No Pascal lint beyond `lwpt format --check`** — there's no `flake8`-style linter for FPC. Format check is the closest equivalent.
- **No post-tag changelog PR** — `CHANGELOG.md` is generated on the release branch before the tag exists, so the tag points at a commit that already contains its own changelog. `release.yml` publishes artifacts from that tag after protected-environment approval; it does not commit back to `main`.
- **No automatic version bump** — tagging is a manual maintainer step. The version embedded in archive names is the tag with any leading `v` stripped (the canonical form per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md) has no `v`; the strip handles the courtesy-accepted prefixed form).

## Release version stamping

`lwpt --version` reports `PROGRAM_VERSION`, a compile-time constant generated into `source/Version.inc` by `scripts/stamp-version.pas`. The value depends on *how* the binary was built:

- **Dev / local builds** (`./bootstrap.sh`, `lwpt build`): the constant is sourced from `[package].version` in `lwpt.toml`. `Version.Test.pas`'s drift guard asserts `lwpt --version` matches the manifest for these. There is no way for a locally-built binary to disagree with the manifest.
- **Release builds** (`release.yml`, tag push): the build step exports `LWPT_VERSION_OVERRIDE=<tag-without-v>` and re-runs `stamp-version.pas` before the cross-FPC compile, so the released binary reports **the git tag**. A 0.1.0-rc.3 release reports `lwpt 0.1.0-rc.3`.

This split keeps the tag, the archive name, and the binary's self-report consistent for anything a user downloads, while leaving local builds pinned to the manifest version (the dev/unreleased number). Release PRs still bump `[package].version` so local builds, `CHANGELOG.md`, and the eventual release tag move together, but the tag remains the source of truth for published binaries. The rationale and rejected alternatives live in [ADR-0026](./adr/0026-release-version-stamp-from-tag.md).

Three independent layers keep the tag, archive name, and binary self-report in agreement — each catches what the others can't:

1. **Build-job native check (pre-publish gate).** `release.yml` runs the freshly cross-built native (`aarch64-darwin`) binary and asserts `lwpt --version == lwpt <tag>`. `Version.inc` is shared across all six targets, so a correct native stamp proves it for the whole matrix. Runs before publish — a stamping failure ships nothing.
2. **Post-publish install-smoke job.** Runs the real `install.sh` against the just-published tag (explicit `LWPT_VERSION`, so it covers prerelease-flagged `rc.x`) and asserts the *installed* binary reports the tag. Validates the uploaded assets are downloadable, correctly named (the macOS `.zip`-vs-`.tar.gz` class, PR #8), and checksum-valid.
3. **Everyday install-script e2e test.** `tests/e2e/InstallScript.E2E.Test.pas` resolves non-prerelease "latest" and derives the expected version from it (no pinned constant), catching `install.sh` regressions between releases.

> Historical note: `0.1.0-rc.1` and `0.1.0-rc.2` were built before this stamping landed, so their binaries report `lwpt 0.1.0` (the manifest version at the time) rather than the tag. They are prerelease-flagged, so the everyday install-script test (which resolves non-prerelease "latest") never installs them; the per-release install-smoke job is what validated them at tag-cut time.
