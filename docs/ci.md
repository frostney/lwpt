# CI

Four GitHub Actions workflows, mirroring the GocciaScript pattern that LWPT's vendored units came from. The split is **build once on macOS / test natively on every target**.

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `toolchain.yml` | `workflow_call` (reusable), `workflow_dispatch` | Build + cache the cross-FPC toolchain |
| `ci.yml` | `push` to `main`, `workflow_dispatch` | Post-merge confirmation: full 6-target cross-build + native test matrix on the merged main tree |
| `pr.yml` | `pull_request` to `main`, `workflow_dispatch` | Pre-merge gate: fast single-runner Ubuntu (typical wall-clock < 5 min) |
| `release.yml` | tag push (`v?N.N.N`, `v?N.N.N-*`), `workflow_dispatch` | Cross-build → package → publish GitHub Release |

Trigger split, mirroring GocciaScript's CI shape:

- **PRs go through `pr.yml` only** — a single Ubuntu runner, no cross-build. Cheap signal so PR authors aren't blocked on a 30-minute matrix per push.
- **`ci.yml` runs only on `push` to `main`** — i.e. after merge. This is where the heavyweight 6-target cross-build + native test matrix lives. A PR that introduces a platform-specific regression (Windows path quirk, aarch64-only behaviour) will pass `pr.yml` and fail the post-merge `ci.yml` run; the maintainer then reverts or forwards-fixes from `main`. The trade-off is conscious: cheap PR feedback over pre-merge cross-platform certainty.
- **`release.yml` owns tag pushes** — `ci.yml` does not trigger on tags, so a tagged commit goes through a single cross-build pipeline (the release one) rather than two.

## Workflows

### `toolchain.yml` — cross-FPC toolchain build

Runs on `macos-latest`. Builds a full cross-compilation FPC 3.2.2 toolchain covering six targets:

| Target | CPU | OS |
| --- | --- | --- |
| `aarch64-darwin` | `aarch64` | `darwin` (native on macos-arm64) |
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
6. Build per-target cross-RTL + the packages LWPT needs: `rtl`, `rtl-objpas` (variants/strutils/dateutils), `rtl-generics` (Generics.Collections), `fcl-process` (Process), `paszlib` (ZStream), and the platform-appropriate socket unit (Sockets on Unix/Darwin, WinSock2 on Windows).
7. Save the lot — `fpc-cross/`, `cross-binutils/`, `cross-libs/` — under the cache key `lwpt-fpc-cross-3.2.2-macos-arm64-v2`.

The whole job is `if: steps.cache-check.outputs.cache-hit != 'true'`-gated. On a cache hit, the workflow exits in seconds with `Toolchain already cached — nothing to build.`.

### `ci.yml` — build + test

**Build stage** (`macos-latest`, six-target matrix): restores the cached toolchain via the `toolchain.outputs.cache-key` value, invokes the matched cross-FPC against `source/lwpt.pas` with the `-Fu` / `-Fi` paths LWPT needs (`source/`, `packages/httpclient/source/`, `packages/cli/source/`, `packages/semver/source/`, `packages/toml/source/`, `packages/testing/source/`, plus the cross-toolchain's RTL + packages, including `paszlib` for `ZStream`). Release flags `-O4 -dPRODUCTION -Xs -CX -XX -B` mirror `AddBuildModeFlags`' release branch. The resulting `lwpt` binary (or `lwpt.exe` for Windows targets) is `llvm-strip`-ped and uploaded as `lwpt-<target>`.

**Test stage** (per-platform native runners, six-target matrix → five runners):

| Target | Runner |
| --- | --- |
| `aarch64-darwin` | `macos-latest` |
| `x86_64-darwin` | `macos-15-intel` |
| `x86_64-linux` | `ubuntu-latest` |
| `aarch64-linux` | `ubuntu-24.04-arm` |
| `x86_64-win64` | `windows-latest` |
| `i386-win32` | `windows-latest` |

Each runner installs FPC natively (`brew` / `apt` / `choco`), downloads the cross-built `lwpt` binary, then runs the full pipeline:

1. **Sanity** — `lwpt --help` (does the binary even load?)
2. **`lwpt install`** — workspace auto-discovery + symlink/junction creation
3. **`lwpt format --check`** — only on `aarch64-darwin` runner (formatting is platform-independent; one check is enough)
4. **`lwpt test`** — default tier (unit + integration); compiles every `*.Test.pas` via the runner's native FPC, runs them
5. **`lwpt test --tier=e2e`** — live network tier (Q23 decision: run on every platform to surface platform-specific HTTP / TLS / wire-format regressions that offline mocking misses)

Per [Q22=b](./adr/0014-packages-extraction.md), the runner side compiles tests at runtime via `lwpt test` rather than pre-compiling them on the cross-build stage. This exercises the full LWPT pipeline natively — including the resolver, the per-target cfg emitter, FPC's per-platform `{$IFDEF}` paths, and the install loop's symlink-vs-copy decision (junctions on Windows, symlinks on Unix).

### `pr.yml` — pre-merge PR gate

A single Ubuntu runner. Mirrors GocciaScript's `pr.yml` shape, and is the **sole** pre-merge signal a PR sees (because `ci.yml` doesn't trigger on PRs):

1. Install FPC via `apt`
2. `./bootstrap.sh` — cold build of `build/lwpt` from a freshly-cloned repo
3. `./build/lwpt --help` (does the binary even load?)
4. `./build/lwpt install` (workspace auto-discovery + symlinks)
5. `./build/lwpt format --check`
6. `./build/lwpt test` (default tier — unit + integration)

E2E tests are skipped via `LWPT_SKIP_NETWORK=1`; they run on every platform post-merge via `ci.yml`. A separate blocking `docs` job runs `markdownlint-cli2` against the Markdown corpus.

The PR workflow deliberately uses the distro FPC (same as the install instructions in `README.md`), so any regression that only shows up with the system FPC's slightly older RTL gets caught before merge.

#### Why not cross-platform on PRs?

A 6-target cross-build matrix runs in ~10–15 min on cached toolchain (and ~45 min cold), per PR push. Multiplied across the typical commit-amend-push-amend-push PR cycle, that's an order of magnitude more CI minutes than a single Ubuntu run. GocciaScript made the same trade-off: cheap iteration on PRs, exhaustive verification on the merged main tree. Platform-specific regressions that slip through pr.yml surface in the post-merge ci.yml run on `main`; the maintainer reverts the offending commit or rolls a forward-fix PR.

### `release.yml` — tag-triggered release pipeline

Triggers on tags matching `v?N.N.N` or `v?N.N.N-*` (e.g. `v0.1.0`, `0.1.0`, `v0.1.0-rc.1`). The leading `v` is optional per [ADR-0009](./adr/0009-semver-source-syntax.md) (semver 2.0.0 form preferred). Pre-release detection: any version containing a hyphen is published as `prerelease: true`.

The pipeline runs:

1. **`toolchain`** — reuses `toolchain.yml` via `workflow_call`. Cache hit ⇒ instant; cold ⇒ ~30 min rebuild on `macos-latest`.
2. **`build`** — six-target matrix, identical to `ci.yml`'s `build` stage, so the tagged binary equals the CI-validated binary.
3. **`publish`** — packages each target as an archive, generates SHA-256 checksums, and creates the GitHub Release with auto-generated notes (see [`.github/release.yml`](../.github/release.yml) for the category config) plus all archives + the checksums file attached.

#### Release artefact naming

| Target | Archive | Asset name (`<version>` = tag with `v` stripped) |
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
- `pr.yml`: `pull_request` to `main`, `workflow_dispatch`
- `release.yml`: `push` of a `v?N.N.N` or `v?N.N.N-*` tag, `workflow_dispatch`
- `toolchain.yml`: invoked by `ci.yml` and `release.yml` via `workflow_call`; also `workflow_dispatch` for manual cache warming

A given commit triggers at most one heavyweight cross-build pipeline (`ci.yml` after merge, OR `release.yml` after tag), not both. PRs trigger only the cheap `pr.yml`.

## When to bump `CACHE_VERSION`

Bump `toolchain.yml`'s `CACHE_VERSION` env var (currently `v2`) when:

- FPC version changes
- A new target is added to the matrix
- A new RTL / package gets baked into the toolchain (e.g. when a future LWPT change requires a unit not in the current set)
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
- `gitlab-org/release-cli @ v0.16.0` from GitLab
- `atlassian/atlaskit @ d7ac1acad54e…` from Bitbucket

Per Q23=c, these run on every platform (6 in total per push). Total network traffic per push: 18 archive fetches. If this becomes a rate-limit concern, the future fallback is `LWPT_SKIP_NETWORK=1` on N-1 of the 6 runners (the env var is respected by every E2E test).

## What CI does NOT cover

- **`lwpt build` doesn't run on the test runner** — running it would rebuild `lwpt` with the runner's native FPC, defeating the cross-build verification. The pipeline tests the cross-built binary's *behavior* (install / format / test); the cross-build *itself* is verified by the build-stage compile.
- **No artefact retention beyond 7 days** — set in `upload-artifact`. CI artefacts are debugging aids, not release artefacts. The release artefacts published by `release.yml` are permanent (GitHub Releases).
- **No Pascal lint beyond `lwpt format --check`** — there's no `flake8`-style linter for FPC. Format check is the closest equivalent.
- **No `cliff.toml` / git-cliff integration yet** — release notes are GitHub's auto-generated form, binned per [`.github/release.yml`](../.github/release.yml). If a richer changelog is needed later, dropping in `cliff.toml` + swapping to `orhun/git-cliff-action@v4` is a single-commit change.
- **No automatic version bump** — tagging is a manual maintainer step. The version embedded in archive names is the tag with any leading `v` stripped; the manifest's `package.version` is independent (and not automatically kept in lockstep with the tag — there's no enforcement either way yet).
