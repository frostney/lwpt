# Release binaries stamp the version from the git tag; dev builds stamp from the manifest

`lwpt --version` reads a compile-time constant `PROGRAM_VERSION`, generated into [`source/Version.inc`](../../source/Version.inc) by [`scripts/stamp-version.pas`](../../scripts/stamp-version.pas). The stamp source is **deliberately different for dev builds vs release builds**: a dev/local build stamps `[package].version` from [`lwpt.toml`](../../lwpt.toml) (what the working tree *is* — typically the next, unreleased version), while a **release** build stamps the **git tag being cut** (what the artefact *is being shipped as*). The two intentionally diverge: a working tree at `[package].version = "0.1.0"` produces a local binary reporting `lwpt 0.1.0`, but the `0.1.0-rc.3` release tag produces a release binary reporting `lwpt 0.1.0-rc.3`. This ADR records why the divergence is intentional, how it is enforced, and the three-layer validation that keeps the tag, the archive name, and the binary's self-report in agreement.

This was surfaced by the install-script e2e test ([`tests/e2e/InstallScript.E2E.Test.pas`](../../tests/e2e/InstallScript.E2E.Test.pas)): the `0.1.0-rc.2` release archives reported `lwpt 0.1.0` (the manifest version at the time) rather than `lwpt 0.1.0-rc.2` (the tag), because `PROGRAM_VERSION` was derived from the manifest unconditionally. A user downloading `lwpt-0.1.0-rc.2-linux-x64.tar.gz` and running `lwpt --version` got `0.1.0` — a silent lie about which artefact they were holding.

## Considered Options

### How a release binary learns its version

- **Stamp from the git tag at release time.** *Chosen.* `release.yml`'s cross-build step, when `GITHUB_REF_TYPE == tag`, exports `LWPT_VERSION_OVERRIDE="${GITHUB_REF_NAME#v}"` and re-runs `stamp-version.pas` before compiling. The tag is the one authoritative name for a release (it names the archive, the GitHub Release, and the checksums file), so the binary's self-report keying off the same tag means all four agree by construction. The `#v` strip keeps the canonical no-`v` SemVer form (ADR-0009) regardless of whether the tag was `0.1.0` or `v0.1.0`.
- **Always stamp the manifest; bump `[package].version` before each tag.** Rejected: makes the manifest version and the tag two hand-maintained values that must be kept in lockstep, and the failure mode is silent (a forgotten bump ships a mislabelled binary — exactly the `0.1.0-rc.2` bug). Pre-release tags (`-rc.1`, `-rc.2`, `-rc.3`) would each need a manifest commit, polluting history with version churn that says nothing the tag doesn't.
- **Always stamp the manifest; accept the binary lagging the tag.** Rejected outright: a binary that misreports its own version is a correctness bug for a tool whose job is dependency/version management. "The thing that resolves versions can't report its own" is not a stance lwpt can take.

Dev builds keep stamping the manifest: a local `lwpt build` reflects the working tree's declared version (the in-progress, not-yet-tagged version), which is the honest answer for an unreleased build. `LWPT_VERSION_OVERRIDE` is the single seam — set only by `release.yml` on tag pushes; unset everywhere else.

### Why `release.yml` re-runs the stamp instead of relying on the `[prebuild]` hook

`lwpt.toml` wires `stamp-version.pas` as a `[prebuild]` hook, so `lwpt build` regenerates `Version.inc` automatically. But `release.yml` compiles the cross-FPC **directly** (`ppcrossx64 … source/lwpt.pas`) rather than going through `lwpt build`, because the cross-toolchain setup, unit-path wiring, and release flags (`-O4 -dPRODUCTION -Xs -CX -XX`) are workflow-managed. The `[prebuild]` hook therefore never fires in the release pipeline, so the workflow regenerates `Version.inc` explicitly with the override. A manual `workflow_dispatch` (no `GITHUB_REF_TYPE == tag`) keeps the committed manifest version — re-releasing an existing tag by hand is not the stamp path.

### How "latest" is validated without a brittle constant

The everyday install-script test must assert *some* expected version. Two shapes:

- **Resolve "latest" at runtime + derive the expected from it.** *Chosen.* The test GETs `/releases/latest` (the same pipeline `install.sh` uses), passes the resolved tag explicitly to `install.sh`, and asserts the installed binary reports that exact tag. One source of truth (the resolved tag), zero version constant, zero manual bumps. The assertion is **relative** — "the install path works and the binary self-reports the tag it was installed as" — so it never breaks on version drift, only on a genuine `install.sh` defect or a stamp regression. `/releases/latest` returns the newest **non-prerelease-flagged** release (see CONTEXT.md *Prerelease*: orthogonal to pre-1.0 — `0.1.0` published without a hyphen IS returned), so the test self-skips until the first normal release exists.
- **Pin a fixed version constant + a separate expected-output constant.** Rejected: this is the shape that produced the original brittleness. The `0.1.0-rc.2` pin needed a *second* constant (`EXPECTED_REPORTED_VERSION = '0.1.0'`) precisely because the pinned release predated stamp-from-tag, and the two had to be hand-reconciled on every bump. The ecosystem pins install-script tests for *determinism* ([devcontainers/cli](https://github.com/devcontainers/cli/blob/da642b4d/scripts/install.test.sh) uses a fixed `cli_version`), but it asserts the binary reports *the version it asked to install* — never a separately-hardcoded string. The latest-resolving form captures that same "derive, don't double-declare" principle while also removing the bump.

### The three validation layers

Stamp-from-tag is only trustworthy if it is checked. Three independent layers, each catching what the others can't:

1. **Build-job native `--version` check (pre-publish gate).** `release.yml`'s build job runs the freshly cross-built *native* binary (`aarch64-darwin` on the macOS build host) and asserts `lwpt --version == lwpt <tag>`. `Version.inc` is shared across all matrix targets, so a correct native stamp proves it for the whole matrix. Runs **before** publish — a stamping failure fails the release with no artefact shipped.
2. **Post-publish install-smoke job.** Runs the real `install.sh` against the just-published tag (explicit `LWPT_VERSION`, so it covers prerelease-flagged `rc.x` too) and asserts the *installed* binary reports the tag. Validates what the build job can't: the uploaded assets are downloadable, correctly named (the macOS `.zip`-vs-`.tar.gz` class, PR #8), and checksum-valid.
3. **Everyday install-script e2e test.** Resolves non-prerelease "latest" + derives the expected (above). Runs on every push to `main` (the e2e tier), catching `install.sh` regressions *between* releases — the layers (1) and (2) only run at tag-cut time.

## Consequences

- **`lwpt --version` on a downloaded release == the release tag == the archive name**, by construction, for every stamp-from-tag release. The `0.1.0-rc.2`-era divergence is the last release that misreports; releases from the first stamp-from-tag tag onward converge.
- **Dev builds intentionally report the manifest version, not a tag** — a locally built `lwpt` reflects the working tree's in-progress version. This is the expected, correct asymmetry; it is documented in [`docs/ci.md`](../ci.md) so a contributor seeing `lwpt 0.1.0` locally next to a `0.1.0-rc.3` release does not file it as a bug.
- **`LWPT_VERSION_OVERRIDE` is the only seam.** Set by `release.yml` on tag pushes; unset for dev builds and manual dispatch. `stamp-version.pas` prefers it over the manifest when present.
- **No version constant in the everyday install-script test.** It tracks "latest" automatically; no maintenance bump on each release. It skips cleanly until the first non-prerelease release exists, with the per-release install-smoke job covering `rc.x` meanwhile.
- **Three CI gates touch the version story.** A stamping bug fails the build job (pre-publish); a packaging/asset bug fails the install-smoke job (post-publish); an `install.sh` logic regression fails the everyday e2e test (per push). All three are independent and must pass.
- **A future change to the dev-build stamp source** (e.g. stamping a `git describe` value into dev builds) earns an amendment here — the manifest-for-dev / tag-for-release split is the recorded baseline.
