# Definition of Done

A change is done only when every applicable requirement below is satisfied. A
requirement may be marked not applicable only with a recorded reason.

## Implementation

- The implementation matches its investigated issue or user-confirmed
  mini-spec, including non-goals and failure behavior.
- The change follows [`AGENTS.md`](./AGENTS.md), [`VISION.md`](./VISION.md),
  package ownership, atomic-write rules, and existing public contracts.
- The solution is the smallest complete change and introduces no unrelated
  refactoring or external runtime dependency.
- New terminology and architectural boundaries are reflected consistently in
  code, tests, help text, and documentation.
- An ADR is added in the implementation PR only when the implementation makes
  or reverses an architectural decision. Planned features do not receive ADRs.

## Tests and verification

- Focused tests covering the changed behavior pass, including negative and
  recovery paths where applicable.
- Every applicable delivery proof is successful for the exact final head or
  unchanged atomic native prefix. Any head, base, order, or prefix change
  invalidates prior CI, review, full-CI, and merge-readiness evidence.
- Managed completion includes terminal current-head evidence from every active
  inline review automation, zero unresolved threads, and a reply from an
  account with current maintainer authority on every automation thread,
  including resolved threads.
- Each delivery, full-CI, or review requirement marked not applicable has an
  explicit evidence-backed reason.
- FreePascal behavior relied upon by the change is checked against the live
  compiler rather than memory.
- No test is silently skipped, disabled, focused, or weakened to obtain a
  passing result.
- A change that edits any workspace package under `packages/` refreshes the
  lockfile in the same PR: run `./build/lwpt install` so the package's
  workspace `computedHash` in `lwpt.lock` matches the edited tree, and commit
  the updated `lwpt.lock`. A stale hash fails the `install --frozen` gate in
  CI, not locally, so this must not be left to the pipeline to discover.
- The universal project gate passes from the repository root:

  ```sh
  ./build/lwpt install --frozen
  ./build/lwpt format --check
  ./build/lwpt build --clean
  ./build/lwpt agents --check
  ./build/lwpt test
  ```

- E2E coverage is required for changes affecting networking, installation,
  CLI subprocess behavior, platform integration, or release behavior.
- Release preparation reuses a successful exact-main integrated CI run for the
  unchanged default and E2E suites. It does not repeat those complete suites
  locally merely to restate the same proof. Approved source fixes run their
  affected focused suites before the preparation PR; that PR's required CI and
  the resulting integrated-main CI become the final full-suite evidence.
- A change touching process management, concurrency, platform-specific code,
  or the CI workflows themselves dispatches the full CI workflow on the
  branch and watches it to completion before merge when the change targets
  platforms or tiers the PR gate does not cover. During remediation, use an
  allow-listed native diagnostic slice. Dispatch the full matrix only once the
  branch contains the current base and focused checks, required PR CI, and
  active review evidence have converged; a later change invalidates that proof
  (post-#102 the gate covers Linux default+e2e,
  aarch64-darwin default, and win64 offline; `x86_64-darwin`,
  `aarch64-linux`, `i386-win32`, and non-Linux e2e remain
  post-merge-only).
- An intermittent-failure fix names the pinned mechanism and its evidence;
  timeout bumps, retries, and quarantines are mitigations and link a
  tracking issue instead.

## Documentation and decisions

- User-facing documentation, examples, command help, and configuration
  references describe the implemented behavior.
- Documentation does not present planned work as shipped behavior.
- Links and examples affected by the change have been checked.
- Any implementation ADR explains the decision actually made and links to the
  implementation context; it is not a speculative feature specification.

## Review and handoff

- The diff has been self-reviewed for correctness, scope, security, failure
  handling, concurrency hazards, and accidental generated-file edits.
- An independent review has been performed where the workflow requires it.
- The draft pull request is focused and reports the validation commands and
  results.
- Required CI checks pass before merge, and deferred follow-up work is explicit
  rather than hidden in the implementation.

## Release readiness

A release is not ready until LWPT's project-local architecture drift check has
compared source, tests, manifests, workflows, documentation, ADRs, and domain
context. Every finding must be fixed or explicitly waived with a rationale.
This check belongs in LWPT's `/prepare-release` workflow and is not a customer
feature or a consumer-project responsibility.

Release preparation runs the release-specific local evidence that integrated
CI does not provide: frozen and generated-state verification, version
agreement, format and agent-reference checks, a release-mode build, Markdown
lint, architecture drift, and changelog preview. A complete local default/E2E
rerun does not substitute for absent or stale exact-main integrated evidence;
that state blocks preparation. After preparation changes, rerun only affected
focused suites locally and let the preparation PR plus integrated-main CI
provide the complete matrix.
