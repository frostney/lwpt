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
- FreePascal behavior relied upon by the change is checked against the live
  compiler rather than memory.
- No test is silently skipped, disabled, focused, or weakened to obtain a
  passing result.
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
- The full E2E suite passes during release preparation.

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
