# CI

Six GitHub Actions workflows provide the build-once/test-natively matrix, the
release pipeline, and the reusable LWPT dependency updater. Workflows that
execute pull-request code have read-only permissions. Delivery itself (waiting
for CI, converging review, merging, and verifying integration) belongs to the
known-good-route skills under [`ORCHESTRATION.md`](../ORCHESTRATION.md), per
[ADR-0046](./adr/0046-skill-owned-delivery.md).

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `toolchain.yml` | `workflow_call` (reusable), `workflow_dispatch`, weekly `schedule` | Build + cache the cross-FPC toolchain |
| `ci.yml` | `push` to `main`, `workflow_dispatch` | Full native matrix on `main` or any dispatched ref, or one allow-listed diagnostic slice |
| `pr.yml` | `pull_request` | Automatic native gate for every PR, whatever its base branch |
| `release.yml` | tag push (`v?N.N.N`, `v?N.N.N-*`) | Cross-build → protected approval → package → publish GitHub Release |
| `delphi-native.yml` | `workflow_dispatch` | Optional Delphi 12+ Win64 smoke on a licensed self-hosted runner; never a required gate |
| `lwpt-update.yml` | `workflow_call`, manual | Update git-host dependencies and open or refresh one bot-owned pull request |

Trigger split, mirroring GocciaScript's CI shape:

- **PR checks are automatic.** `pr.yml` runs its Ubuntu, native Darwin,
  documentation, and win64 legs on every PR, including native stacked PRs whose
  base is another branch. A superseded push cancels the older run.
- **`ci.yml` has three uses.** A push to `main` verifies the integrated tree;
  rapid main pushes cancel older integrated-main runs. `mode=manual` runs the
  same full matrix on any dispatched ref and is never coalesced. `mode=diagnostic`
  runs one allow-listed native target and test scope on any dispatched ref.
- **`release.yml` owns tag pushes** — `ci.yml` does not trigger on tags, so a tagged commit goes through a single cross-build pipeline (the release one) rather than two.

Repository rules make these contracts enforceable. The desired main ruleset is
versioned at `.github/rulesets/protect-main.json`: it allows only squash merges,
requires resolved review threads, and requires the native `delivery-admission`
job from GitHub Actions integration ID `15368`. The integration binding means a same-named status or check from
another user or app cannot satisfy the rule:

```sh
gh api --method PUT repos/frostney/lwpt/rulesets/18086289 \
  --input .github/rulesets/protect-main.json
```

A separate release-tag ruleset restricts SemVer tag creation to the maintainer
and rejects tag updates or deletion. The protected `release` environment owns
the approval gate between successful builds and publication.

## Workflows

### LWPT dependency updater

Consumers can schedule ADR-0039's Dependabot-equivalent without copying its
update and pull-request logic:

```yaml
name: lwpt-update

on:
  schedule:
    - cron: '17 6 * * 1'
  workflow_dispatch:

jobs:
  update:
    uses: frostney/lwpt/.github/workflows/lwpt-update.yml@main
    permissions:
      contents: write
      pull-requests: write
```

The reusable job prefers a compatible `build/lwpt`, then `lwpt` on `PATH`, and
otherwise bootstraps the selected `lwpt-ref` from source. It runs `lwpt
outdated --json`, exits without a branch when everything is current, and runs
`lwpt update` when a `newer` or `major` entry exists. Only `lwpt.toml`,
`lwpt.lock`, `lwpt.cfg`, `.lwpt/modules/`, and `.lwpt/archives/` are staged.
The fixed `lwpt/update-dependencies` branch is bot-owned and replaced with
`--force-with-lease`; do not put manual commits on it.

The pull-request body records the constraint, locked version, latest tag, and
status for every update. GitHub release titles are escaped and the first 40
lines of release notes are placed in a dynamically sized plain-text fence, so
upstream Markdown, HTML, issue-closing text, and mentions remain inert. GitLab,
Bitbucket, and custom-host entries are named but direct the reader to that host
for release notes.

By default the job authenticates with the caller's `GITHUB_TOKEN`. GitHub puts
the resulting pull-request checks in an approval-required state. Consumers that
want CI to start without that approval can pass a GitHub App installation token
or personal access token:

```yaml
jobs:
  update:
    uses: frostney/lwpt/.github/workflows/lwpt-update.yml@main
    permissions:
      contents: write
      pull-requests: write
    secrets:
      update_token: ${{ secrets.LWPT_UPDATE_TOKEN }}
```

Optional inputs change `working-directory`, the bot `branch-name`, `pr-title`,
or the bootstrapped `lwpt-ref`. Concurrent runs targeting the same repository
and branch serialize rather than racing the fixed update branch.

### Manual and diagnostic dispatch

`ci.yml` accepts `workflow_dispatch` on any ref; dispatch already requires
write access. Every job checks out the run's own head SHA, so a run is
evidence for exactly that commit.

```sh
gh workflow run ci.yml --ref <branch> -f mode=manual
gh workflow run ci.yml --ref <branch> -f mode=diagnostic \
  -f diagnostic_target=<target> -f diagnostic_selector=<selector>
```

`mode=manual` runs the full six-target build and native test matrix. Every
PR needs one green manual run whose head is the PR's exact head before merge; [`ORCHESTRATION.md`](../ORCHESTRATION.md) owns that
rule. The run name shows the mode and ref (`CI / manual / <branch>`).

`mode=diagnostic` runs one allow-listed native remediation slice and is never
merge evidence. The surface covers Windows x86_64/i386 ordinary, E2E, and TLS
slices, plus ARM- and Intel-Darwin scheduling slices that run only
`TestScheduling.Test.pas` with a 150-second ceiling. ARM-Darwin captures the
active case and process state for
[issue #278](https://github.com/frostney/lwpt/issues/278). The focused Intel
inventory remained healthy past the earlier 90-second boundary in
[issue #260](https://github.com/frostney/lwpt/issues/260).
The x86_64 Linux scheduling slice runs the same test with a 90-second ceiling.
When isolation changes the Intel-Darwin symptom, that target can run its
ordinary project paths with a seven-minute ceiling. Both Darwin targets capture
a native process sample on timeout; Linux records the active test case and
captures `/proc` process and thread status, wait channels, syscalls, stacks, and
file descriptors. Target and selector combinations are allow-listed as pairs:
Windows-only selectors cannot silently run on Darwin or Linux, and the
scheduling probe cannot run on Windows. A diagnostic accepts no shell command,
its run name is `CI / diagnostic / <ref> / <target>/<selector>`, and a later
diagnostic on the same ref cancels the prior run. The scheduling probe lives at
`.github/ci/scheduling-diagnostic.sh`.

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

**Build stage** (`macos-latest`, six-target matrix): restores the cached toolchain via the `toolchain.outputs.cache-key` value, invokes the matched cross-FPC against `source/lwpt.pas` with the `-Fu` / `-Fi` paths LWPT needs (`source/`, `packages/httpclient/source/`, `packages/cli/source/`, `packages/semver/source/`, `packages/toml/source/`, `packages/testing/source/`, plus the target's FPC packages slice, including `paszlib` for `ZStream`). Release flags `-O4 -dPRODUCTION -Xs -CX -XX -B` mirror `TLWPTFPCCompilerDriver.BuildArguments`' release translation. The resulting `lwpt` binary (or `lwpt.exe` for Windows targets) is `llvm-strip`-ped and uploaded as `lwpt-<target>`.

**Test stage** (per-platform native runners, six-target matrix → five runners):

| Target | Runner |
| --- | --- |
| `aarch64-darwin` | `macos-latest` |
| `x86_64-darwin` | `macos-15-intel` |
| `x86_64-linux` | `ubuntu-latest` |
| `aarch64-linux` | `ubuntu-24.04-arm` |
| `x86_64-win64` | `windows-latest` |
| `i386-win32` | `windows-latest` |

Each runner installs FPC natively (`brew`, `apt`, or the pinned official Windows distribution through `.github/ci/install-windows-fpc.sh <target>`), then the `x86_64-win64` leg runs a one-off `bootstrap.bat` cold-build smoke through both the direct-`fpc` fallback and the InstantFPC path, rebuilds LWPT twice with the InstantFPC-bootstrapped `build\lwpt.exe` (each rebuild replaces the running image), and deletes `build/` again so the rest of the stage still validates the downloaded cross-built artefact. Every native test-matrix job has a 20-minute ceiling, containing a stalled test process without treating the bound as a root-cause fix. The Windows installer verifies the download's SHA-256 and retries only the download. Tests themselves are never retried. After setup, every runner downloads the cross-built `lwpt` binary and runs the full pipeline:

1. **Sanity** — `lwpt --help` (does the binary even load?)
2. **`lwpt install`** — workspace auto-discovery + symlink/junction creation
3. **`lwpt format --check`** — only on `aarch64-darwin` runner (formatting is platform-independent; one check is enough)
4. **`lwpt test <ordinary paths> --bail=0`** — the repository's co-located and integration programs; compiles them via the runner's FPC (on Windows, the leg's compiler from the table below), runs them concurrently, and runs the full queue so one run reports every failing program (a first-failure bail hid independent intermittent failures behind separate reruns, #299)
5. **`lwpt test <E2E paths> --bail=0`** — with `LWPT_ENABLE_NETWORK=1` set in the job environment, the repository's E2E programs run on every platform (Q23 decision: surface platform-specific HTTP / TLS / wire-format regressions that offline mocking misses)

The official FPC 3.2.2 Windows distribution's native compiler is i386, so both Windows legs install its `i386-win32` base and differ in the compiler that `LWPT_FPC` publishes for test programs:

| Leg | Test-program compiler (`LWPT_FPC`) | Units (`LWPT_FPC_UNIT_PATHS`) | Test programs run as |
| --- | --- | --- | --- |
| `x86_64-win64` | `ppcrossx64.exe` from the official `x86_64-win64` cross add-on | `units/x86_64-win64/` | 64-bit (`Target OS: Win64 for x64`) |
| `i386-win32` | the native i386 `fpc.exe` | `units/i386-win32/` | 32-bit (`Target OS: Win32 for i386`) |

Both installers are SHA-256-pinned. The setup script fails unless the selected compiler reports the leg's `-iTO -iTP` target, then compiles and runs a probe, so the setup log shows the compiler banner and the probe's pointer width. On the `x86_64-win64` leg the `bootstrap.bat` smoke uses the same `LWPT_FPC` and therefore builds a 64-bit `lwpt.exe`. The `fpc` and `instantfpc` on `PATH` remain the i386 host tools on both legs; they run host-side scripts, not test programs.

Per [Q22=b](./adr/0014-packages-extraction.md), the runner side compiles tests at runtime via `lwpt test` rather than pre-compiling them on the cross-build stage. This exercises the full LWPT pipeline natively — including the resolver, the per-target cfg emitter, FPC's per-platform `{$IFDEF}` paths, and the install loop's symlink-vs-copy decision (junctions on Windows, symlinks on Unix).

When a test step fails, the job uploads `registry-matrix-<target>`: the
scratch directory that [`RegistryMatrix.E2E.Test.pas`](../tests/e2e/RegistryMatrix.E2E.Test.pas)
keeps for a failing case, holding its data directories, consumer projects,
and command log. The registries in it are loopback-only test registries with
throwaway keys.

**Registry container stage** (`registry-container`, `ubuntu-latest`, 20-minute
ceiling, full matrix only, skipped in diagnostic mode): downloads the
`lwpt-x86_64-linux` artefact and runs
[`.github/ci/registry-container/smoke.sh`](../.github/ci/registry-container/smoke.sh)
`--binary build/lwpt`. The script packages the binary exactly like a release
archive, serves it on loopback, and builds the unchanged example image from
[`docs/examples/registry/`](./examples/registry/). It first proves that a
wrong SHA-256 pin fails the build. It then runs the registry as UID 10001 on
a read-only root file system with `registry.toml` exported and mounted
read-only, checks that the service account can modify neither the binary nor
the configuration, and waits for the image's health check. A token is issued
in the serving container, a `registry publish` from the runner commits while
the server runs, the record and archive are read back, and a graceful stop is
checked for exit status 0 within the stop timeout. The documented
reconfiguration procedure runs, a replacement container on the same volume
serves the same head, a key rotation in the serving container is followed by
a root-pinned publication, and the reverse-proxy example (nginx re-encrypting
to the registry) serves the same protocol. Every engine call goes through one
helper bounded by `timeout --foreground`, and the script itself runs under a
600-second `timeout` inside an 11-minute step. A separate bounded step,
`smoke.sh --collect`, then writes container logs, `docker inspect` output
including health history, and data-volume listings (never signing seeds or
tokens) even when the smoke was killed, and the job uploads them as
`registry-container-smoke`. The stage stays off `pr.yml` because it needs Docker and image
pulls. [`registry-deployment.md`](./registry-deployment.md) is the operator
guide.

### `pr.yml` — pre-merge PR gate

Mirrors GocciaScript's `pr.yml` shape, and is the only **automatic** pre-merge signal a PR sees (because `ci.yml` doesn't trigger on PRs); the required manual `ci.yml` run on the PR's exact head supplies the rest of the pre-merge coverage. The main `build-and-test` job is a single Ubuntu runner:

1. Install FPC via `apt`
2. `./bootstrap.sh` — cold build of `build/lwpt` from a freshly-cloned repo
3. `./build/lwpt --help` (does the binary even load?)
4. `./build/lwpt install --frozen` (committed lockfile matches committed trees, and every local and workspace module still matches the snapshot re-derived from its source — runs *before* plain install so lock drift cannot be masked by regeneration)
5. `./build/lwpt install` (workspace auto-discovery)
6. `git status --porcelain` over `lwpt.lock`, `lwpt.cfg`, `.lwpt/modules/`, and `.lwpt/archives/` (the plain install changed no committed toolkit state; defense in depth for [#370](https://github.com/frostney/lwpt/issues/370))
7. `./build/lwpt format --check`
8. `./build/lwpt build` (manifest build-entry compile)
9. `./build/lwpt agents --check` (generated command-reference drift)
10. `./build/lwpt test <ordinary paths> --bail=0`

In the automatic gate, the live-network E2E paths run on the Linux leg only. Their dedicated selector invocation sets the repository-owned `LWPT_ENABLE_NETWORK=1` opt-in, added per [issue #102](https://github.com/frostney/lwpt/issues/102) after the #84 TLS-close class proved invisible to the ordinary route. The ordinary pass still carries the concurrency suites which cover the #101 timing class; E2E does not rerun them as accidental stress. Every platform runs the E2E paths in the required manual `ci.yml` run on the PR's exact head, and again on the push to `main`. The native `build-and-test`, `darwin-test`, and `windows-test` jobs each have a 20-minute ceiling. The Windows job uses the same pinned installer as `ci.yml`. A second PR job, `darwin-test`, natively bootstraps on `macos-latest` (brew FPC, independent of the cross-toolchain cache) and runs the ordinary paths — the #105 env-race family and its masks all first surfaced on darwin legs. Bounded cost: ~5–6 min warm, parallel to `build-and-test`. The remaining `ci.yml`-only legs (`x86_64-darwin`, `aarch64-linux`, `i386-win32`) run in that required manual run rather than on every push. A separate blocking `docs` job runs `markdownlint-cli2` against the Markdown corpus.

The PR workflow deliberately uses the distro FPC (same as the install instructions in `README.md`), so any regression that only shows up with the system FPC's slightly older RTL gets caught before merge.

#### Windows signal (`windows-cross-compile` + `windows-test`)

A second job reuses `toolchain.yml` (`workflow_call`, exactly like `ci.yml`) and cross-compiles `source/lwpt.pas` for **`x86_64-win64` only**, mirroring `ci.yml`'s build-stage flags and unit paths. It exists because `{$IFDEF WINDOWS}` codepaths never compile on the Ubuntu runner: PR #17 merged green while breaking `main` with a `SysUtils.FindClose` vs `Windows.FindClose` unit-shadowing error that PR #21 then had to fix. One target suffices — win32 and win64 share the same `{$IFDEF WINDOWS}` sources. The job also runs the no-OpenSSL guard (ADR-0016 for clients, ADR-0033 for servers — Windows must contain no OpenSSL linkage in either direction) against the produced `lwpt.exe`, surfacing that release-blocker in the automatic gate instead of waiting for the full matrix.

The produced `lwpt.exe` is then uploaded for **`windows-test`**, which mirrors `ci.yml`'s build-once / test-natively split on a `windows-latest` runner: install FPC through the shared `.github/ci/install-windows-fpc.sh x86_64-win64` (`lwpt test` compiles `*.Test.pas` at run time per Q22=b, here with the x86_64 cross compiler `ppcrossx64.exe`, so the test programs run as 64-bit code like the `lwpt.exe` under test), download the binary, then `lwpt install` + `lwpt test <ordinary paths> --bail=0` (offline). This catches what a compile alone cannot: Windows-only runtime regressions in lwpt itself (junction-vs-symlink installs, path handling, subprocess environment handling), scheduler cancellation/reaping, and compile breaks in test sources.

Deliberately outside the automatic gate, and covered by the required manual `ci.yml` run before merge:

- **The `i386-win32` leg** (win32 and win64 share `{$IFDEF WINDOWS}` sources, but only this leg compiles its test programs as 32-bit code, whose pointer widths, structure layouts and native-integer arithmetic differ from the automatic win64 leg).
- **The E2E paths on non-Linux platforms** and the `bootstrap.bat` cold-build smoke (the Linux E2E leg runs pre-merge per #102).
- **`x86_64-darwin` and `aarch64-linux` runtime.** The aarch64-darwin PR leg covers `{$IFDEF DARWIN}` compile + arm64 runtime pre-merge (added per #102 after the #105 env-race family surfaced on darwin legs first); the intel-mac and arm-linux permutations run only in the manual and push matrices.

Cache economics: the toolchain cache key (`lwpt-fpc-cross-<fpc>-macos-arm64-<n>`) has no branch component, and GitHub Actions lets PR runs restore caches created on the base branch — so PR runs hit the toolchain that `ci.yml` pushes to `main` keep warm, and the `toolchain` job is a seconds-long cache lookup. On eviction, the PR run rebuilds the toolchain (~30 min) into its own cache scope (not shared across PRs); a weekly `schedule` cron on `toolchain.yml` re-warms the default-branch copy so that window is bounded even when `main` is quiet. `pr.yml` also sets `concurrency` with `cancel-in-progress`, so a superseded push doesn't keep burning the macOS runner.

#### Why not run the full matrix automatically on every push?

A 6-target cross-build matrix runs in ~10–15 min on cached toolchain (and ~45 min cold). Running it on every push of the typical commit-amend-push PR cycle costs an order of magnitude more CI minutes than the automatic gate, so `pr.yml` stays cheap for iteration. The full matrix is still required before merge, but only once, as a manual run on the PR's final exact head ([`ORCHESTRATION.md`](../ORCHESTRATION.md)). That rule replaced the earlier GocciaScript-style trade of verifying the other platforms only after merge: in September 2026 the automatic gate repeatedly let Intel-Darwin, i386 and cross-toolchain breaks reach `main`. The win64 leg (cross-compile + native offline test run, ~3 min total on a warm cache), the Linux e2e step and the aarch64-darwin leg remain in the automatic gate because they catch the most common breakage classes early.

### `release.yml` — tag-triggered release pipeline

Triggers on tags matching `v?N.N.N` or `v?N.N.N-*` (e.g. `0.1.0`, `0.1.0-rc.1` — the canonical form per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md), which adopts SemVer 2.0.0; the `v`-prefixed form `v0.1.0` is also accepted as a courtesy but not the recommended shape). Pre-release detection: any version containing a hyphen is published as `prerelease: true`.

The pipeline runs:

1. **`toolchain`** — reuses `toolchain.yml` via `workflow_call`. Cache hit ⇒ instant; cold ⇒ ~30 min rebuild on `macos-latest`.
2. **`build`** — six-target matrix, identical to `ci.yml`'s `build` stage, so the tagged binary equals the CI-validated binary.
3. **`publish`** — waits for approval through the protected `release`
   environment, packages each target as an archive, generates SHA-256
   checksums, extracts that tag's notes from the committed `CHANGELOG.md`, and
   creates the GitHub Release with all archives + the checksums file attached.
4. **`install-smoke`** — runs `scripts/install.sh` against the published
   release and checks the reported version.
5. **`registry-container-smoke`** — builds the example registry image from
   the published `linux-x64` archive, pinned to the digest in the release's
   checksums file, and runs the same container smoke as `ci.yml` with the
   released client.

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
- `pr.yml`: `pull_request`
- `release.yml`: `push` of a `v?N.N.N` or `v?N.N.N-*` tag
- `toolchain.yml`: invoked by `ci.yml`, `pr.yml`, and `release.yml` via `workflow_call`; also `workflow_dispatch` for manual cache warming and a weekly `schedule` cron (Mondays 05:00 UTC) that keeps the default-branch cache warm

A normal commit triggers one heavyweight cross-build pipeline through `ci.yml`
after merge. A release commit later triggers `release.yml` again when tagged:
that second cross-build stamps the tag version and produces the permanent
release artifacts, but does not repeat the native test matrix. PRs trigger only
the cheap `pr.yml` (whose single win64 cross-compile rides the cached toolchain).

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

The explicit E2E-path step runs three live fetches per platform:

- `octocat/Hello-World @ 7fd1a60b…` from GitHub (stable historical commit)
- `gitlab-examples/ci-debug-trace @ dd648b2e48ce6518303b0bb580b2ee32fadaf045` from GitLab
- `atlassian/atlaskit @ d7ac1acad54e…` from Bitbucket

Per Q23=c, these run on every platform (6 in total per push). Total network traffic per push: 18 archive fetches. The test programs require the repository-owned `LWPT_ENABLE_NETWORK=1` opt-in; omitting it keeps live access disabled.

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

Concurrent self-builds can run the hook at the same moment while another build compiles against `Version.inc`, so the script never rewrites the file in place ([#361](https://github.com/frostney/lwpt/issues/361)). When the file already holds exactly the text it would write, the script leaves it untouched, modification time included. Otherwise it writes a uniquely named, exclusively created temporary file in the project's own `.lwpt/tmp/` (beside `lwpt.toml`, created when missing) and replaces the destination atomically: `rename(2)` on Unix, `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING` and `MOVEFILE_WRITE_THROUGH` on Windows, where a destination held open is retried up to 40 times with configured sleeps totalling 3,555 ms; exhausting the attempts fails the run unless the destination already holds the expected text. Staging outside `source/` keeps the transient file out of the tree builds fingerprint. The script does not read an `[lwpt] tmp-dir` override: its naive manifest scan cannot parse TOML faithfully, and a misread path could point outside the project. There is no other staging place. When `.lwpt/tmp/` cannot be created or written, or the rename crosses file systems (`EXDEV`, `ERROR_NOT_SAME_DEVICE`), the run fails with a message naming the path and leaves `Version.inc` as it was. A temporary file removed under the script, as `lwpt install` does when it wipes `.lwpt/tmp/`, is written again, at most three times in all. A failed replacement whose destination already holds the expected text counts as success. Every temporary file that is not published is deleted, and one that cannot be deleted is reported on stderr. The bytes are unchanged: each line ends with the platform line ending. Because an unchanged file keeps its old modification time, a manifest edit that leaves the version alone makes the staleness-gated hook run again on later builds, each time as a no-op. `tests/integration/StampVersion.Test.pas` covers concurrent runs, an end-to-end smoke of concurrent `lwpt build` runs using the hook, and the failure paths.

This split keeps the tag, the archive name, and the binary's self-report consistent for anything a user downloads, while leaving local builds pinned to the manifest version (the dev/unreleased number). Release PRs still bump `[package].version` so local builds, `CHANGELOG.md`, and the eventual release tag move together, but the tag remains the source of truth for published binaries. The rationale and rejected alternatives live in [ADR-0026](./adr/0026-release-version-stamp-from-tag.md).

Three independent layers keep the tag, archive name, and binary self-report in agreement — each catches what the others can't:

1. **Build-job native check (pre-publish gate).** `release.yml` runs the freshly cross-built native (`aarch64-darwin`) binary and asserts `lwpt --version == lwpt <tag>`. `Version.inc` is shared across all six targets, so a correct native stamp proves it for the whole matrix. Runs before publish — a stamping failure ships nothing.
2. **Post-publish install-smoke job.** Runs the real `install.sh` against the just-published tag (explicit `LWPT_VERSION`, so it covers prerelease-flagged `rc.x`) and asserts the *installed* binary reports the tag. Validates the uploaded assets are downloadable, correctly named (the macOS `.zip`-vs-`.tar.gz` class, PR #8), and checksum-valid.
3. **Everyday install-script e2e test.** `tests/e2e/InstallScript.E2E.Test.pas` resolves non-prerelease "latest" and derives the expected version from it (no pinned constant), catching `install.sh` regressions between releases.

> Historical note: `0.1.0-rc.1` and `0.1.0-rc.2` were built before this stamping landed, so their binaries report `lwpt 0.1.0` (the manifest version at the time) rather than the tag. They are prerelease-flagged, so the everyday install-script test (which resolves non-prerelease "latest") never installs them; the per-release install-smoke job is what validated them at tag-cut time.
