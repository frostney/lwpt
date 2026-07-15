---
name: prepare-release
description: >-
  Prepare LWPT for a release by running the full project and E2E gates,
  checking the latest cross-platform CI result, auditing architecture drift
  across source and documentation, previewing the changelog, applying approved
  truth-sync fixes, and opening a draft preparation PR. Stops before version
  selection, changelog generation, tagging, or publishing, which belong to
  /create-release. Use when the user runs /prepare-release or asks to prepare
  LWPT for a release.
---

# Prepare Release

Prepare the LWPT repository for `/create-release`. The deliverables are a
consolidated readiness report and, when fixes are approved, a draft preparation
PR opened through `/create-pr`.

This skill is project-local because the architecture audit is about LWPT's own
source, contracts, workflows, and documentation. It is not an LWPT customer
feature. Reuse [`DEFINITION_OF_DONE.md`](../../../DEFINITION_OF_DONE.md) rather
than weakening or duplicating its gates.

## Boundary

- **In scope:** read-only verification, local full E2E, latest-main CI status,
  architecture-drift findings, documentation and domain-language truth sync,
  release-mode smoke build, changelog preview, housekeeping, approved fixes,
  re-verification, and a draft preparation PR.
- **Out of scope:** choosing or bumping the version, writing the release
  changelog section, creating a release branch, tagging, publishing, or
  modifying the tag-triggered release pipeline. Those belong to
  `/create-release` and CI.

## Process safety before issue #28 lands

LWPT's build and test runners are not yet safe for concurrent agents in one
worktree. Until GitHub issue #28 is implemented:

- Only the root agent may invoke `fpc`, `bootstrap`, `lwpt build`, or
  `lwpt test` during release preparation.
- Run compiling commands sequentially, never concurrently.
- Subagents may perform read-only source, workflow, documentation, and ADR
  audits. Explicitly forbid them from compiling, testing, formatting, cleaning,
  or writing files.
- If another build or test process is already active in this worktree, wait for
  it to finish before starting the verification gate.

## Flow

Read-only first, then one approval checkpoint, then apply approved fixes:

1. Establish the release baseline and run all non-mutating checks.
2. Produce one readiness report with every architecture finding.
3. Stop for the user to approve fixes or explicitly waive individual findings.
4. Apply only approved fixes and record every waiver with its rationale.
5. Re-run the complete gate.
6. Open a draft preparation PR through `/create-pr`.
7. Stop. `/create-release` is a separate invocation after the preparation PR
   has merged and `main` is green.

## Hard blockers

Stop and report `BLOCKED` when any of these is true:

- The branch is not based on the current remote default branch, or the working
  tree contains unexpected changes.
- Any universal, release-mode, E2E, Markdown, frozen-install, or generated-data
  check fails.
- The latest completed `ci.yml` run for the base commit is not successful.
- An architecture-drift finding remains neither fixed nor explicitly waived
  with a rationale.
- The release workflows and documented target or artifact matrices disagree.
- The changelog preview cannot account for the commits since the last release.

## Steps

### 1. Establish the baseline

- Read `AGENTS.md`, `VISION.md`, `CONTEXT.md`,
  `DEFINITION_OF_READY.md`, `DEFINITION_OF_DONE.md`, `docs/architecture.md`,
  `docs/build-system.md`, `docs/deployment.md`, and `docs/ci.md`.
- Resolve the default branch through GitHub rather than assuming its name.
- Fetch the default branch and tags without switching away from the current
  preparation branch.
- Record the branch, HEAD, base SHA, last release tag, commits since that tag,
  working-tree state, and current `fpc -iV` result.
- Classify all existing changes as expected preparation work or unexpected.
  Stop on unexpected changes; do not discard or overwrite them.

### 2. Run the Definition of Done gate

Run these commands sequentially from the repository root:

```sh
./build/lwpt install --frozen
./build/lwpt format --check
./build/lwpt build --clean
./build/lwpt test
./build/lwpt test --tier=e2e
```

The E2E run must exercise the live network. Do not set `LWPT_SKIP_NETWORK`.
Then run the release-mode smoke build:

```sh
./build/lwpt build --clean --mode release
```

Lint the complete Markdown corpus with the same pinned CLI version used by the
repository's documentation workflow. Read `.markdownlint-cli2.jsonc` and the
workflow before selecting the command; verify the tool version live.

### 3. Check cross-platform evidence

- Inspect the latest completed `ci.yml` run for the base commit with `gh`.
- Require the six-target cross-build and native test matrix to be green.
- Confirm the target list, native-test policy, TLS backends, artifact names,
  and release version stamping agree between `ci.yml`, `release.yml`,
  `toolchain.yml`, `docs/ci.md`, and `docs/deployment.md`.
- Do not trigger or publish a release workflow during preparation.

### 4. Audit architecture drift

Compare documented claims with implemented reality. Every finding names the
claim, the source truth, both file locations with line numbers, and the
recommended resolution direction.

Cover every surface:

- **Product boundary:** `VISION.md` and `AGENTS.md` against the implemented CLI,
  dependencies, network behavior, package ownership, and compiler behavior.
- **Command surface:** registered subcommands and options in `source/lwpt.pas`
  and `source/LWPT.Command.*.pas` against README, quick reference, build,
  testing, and deployment documentation.
- **Manifest and generated state:** parser/model fields in
  `source/LWPT.Manifest.pas`, `lwpt.toml`, `lwpt.lock`, and `lwpt.cfg` behavior
  against manifest examples, lockfile schema claims, and zero-install rules.
- **Packages and dependencies:** `[workspaces]`, package manifests, committed
  modules, lockfile entries, and package source ownership against
  `docs/packages.md` and architecture documentation.
- **Filesystem and concurrency:** actual writes, locks, temporary paths,
  cleanup, build outputs, and repair behavior against atomicity and safety
  claims. Planned behavior in GitHub issues must not be described as shipped.
- **Testing:** discovery, tiers, skips, network policy, subprocess boundaries,
  and test counts against `docs/testing.md` and CI workflows.
- **Platforms and transport:** source conditionals, TLS implementations,
  compiler targets, and artifact packaging against deployment claims.
- **Environment and configuration:** every environment-variable and manifest
  key read by source against `docs/tooling.md` and user documentation, in both
  directions.
- **ADRs:** verify implemented decisions still match source. Treat ADRs as
  historical records: never rewrite an old ADR to conceal drift. Fix the code
  or current documentation, or add a new implementation ADR when a decision is
  intentionally changed.
- **Domain language:** reconcile `CONTEXT.md` terms with source identifiers,
  public help, and current documentation through `domain-modeling`.

Planned roadmap features are not drift merely because they are absent. They
become findings only when current documentation claims they are already
supported.

### 5. Verify generated and release-sensitive state

- Copy `lwpt.toml` and `scripts/stamp-version.pas` into an isolated temporary
  directory with an empty `source/` directory, run the copied script there,
  and compare its generated `source/Version.inc` with the committed file. Do
  not run the generator against the working tree during the read-only phase.
- Confirm `lwpt.toml` is the version source for normal builds and that
  `release.yml` overrides it from the tag for release artifacts.
- Verify `lwpt --version`, the manifest version, and generated version include
  agree for the preparation branch.
- Verify committed `.lwpt/modules/`, `.lwpt/archives/`, `lwpt.lock`, and
  `lwpt.cfg` through `install --frozen`; never hand-edit them.

### 6. Preview the changelog

- Verify `git-cliff` live and dry-run the unreleased changelog from the last
  release tag.
- Report the computed conventional-commit bump only as context. Do not select
  or confirm a version here.
- Identify uncategorized, misleading, duplicated, or omitted commits. Fix
  `cliff.toml` during preparation when categorization is wrong; do not write the
  release changelog section.

### 7. Check housekeeping

- Confirm `skills-lock.json` matches provisioned curated skills.
- Treat this repo-native `prepare-release` skill as intentionally outside
  `skills-lock.json`, matching the project-local GocciaScript pattern.
- Confirm no generated build output, test binaries, credentials, local cache
  state, or unrelated changes would enter the PR.
- Ensure current docs link to `VISION.md`, `DEFINITION_OF_READY.md`, and
  `DEFINITION_OF_DONE.md` without duplicating them.

### 8. Report, approve, and apply

Emit one readiness report before writing fixes:

1. **Verdict:** `READY FOR FIX APPROVAL` or `BLOCKED`.
2. **Baseline:** branch, base SHA, last release, unreleased commits, FPC version.
3. **Gate results:** frozen install, format, clean build, default tests, live
   E2E, release-mode build, Markdown, and latest-main CI.
4. **Architecture drift:** findings grouped by the surfaces above.
5. **Generated and release state:** version, committed dependency state, target
   matrix, and artifact agreement.
6. **Changelog preview:** bump context and categorization findings.
7. **Proposed fixes and waivers:** each independently approvable; every waiver
   includes a rationale suitable for the preparation PR.
8. **Deferred follow-ups:** offer `/create-issue`; never silently create or
   discard them.

After approval, apply the selected fixes, show the resulting diff, and re-run
the complete verification gate. The final verdict is `READY FOR
/create-release` only when all checks pass and every finding is fixed or
explicitly waived.

### 9. Hand off

- Open a focused draft preparation PR through `/create-pr` using a
  content-reflecting conventional title, normally `docs:` or `chore:`. Never
  use `chore(release):`; that is reserved for `/create-release`.
- Record commands and results, architecture findings, fixes, and waivers in the
  PR body.
- Once the preparation PR is squash-merged and `main` CI is green, hand off to
  `/create-release` in a separate task.

## Notes

- This skill prepares; it never versions, tags, or publishes.
- `/create-release` owns changelog generation and the tag-triggered CI release.
- Defer to `/create-pr`, `/create-release`, `/create-issue`, `git-workflow`,
  `domain-modeling`, `native-nostalgia-stack`, and `project-structure` where
  their scopes apply.
