# Managed delivery uses explicit transitions and exact native-topology proofs

The 0.5.0 stack trial conflated delivery ownership with stack membership and
used an intentional failed first run as admission. LWPT now models those
concerns separately. `delivery:managed` opts a standalone or native-stack PR
into deferred delivery; `ci:ready`, `review:ready`, and `merge:ready` are its
ordered phase state; `ci:full-required` is independent applicability policy.
GitHub's native pull-request stack and ordered entries are the only topology
authority. A repository-owned `workflow_dispatch` endpoint accepts explicit
transitions, while default-branch observers invalidate head, base, order, or
prefix drift. Exact-head `delivery-admission` proves the PR matrix. Conditional
`full-ci` proves one singleton or the unchanged cumulative SHA at a frozen
native-prefix top. `merge:ready` remains the machine-validated final state and
is not duplicated by another merge-admission check. This decision was
investigated in [issues #159](https://github.com/frostney/lwpt/issues/159) and
[#160](https://github.com/frostney/lwpt/issues/160).

## Considered options

- **Use labels as event commands.** Rejected because a label would be both a
  request and accepted state, and retry/audit semantics would remain implicit.
- **Use one explicit repository endpoint.** Chosen. Milestone Rush reads its
  binding from `ORCHESTRATION.md`; maintainers can invoke the same endpoint in
  the Actions UI. Labels expose accepted phase state.
- **Run a separate external GitHub App service.** Rejected because LWPT does
  not need an always-on service to own a repository-local state machine.

## Consequences

- Workflows with write permission never check out or execute pull-request
  code. Read-only exact-head matrices are concluded by a trusted
  default-branch finalizer.
- Managed delivery, stack topology, and full-CI applicability can vary
  independently.
- A changed head or native topology creates a new pending proof and removes
  stale readiness. Cancellation, failure, and watchdog expiry are terminal
  failures.
- Ordinary PR CI stays automatic and is aggregated into the same app-owned
  `delivery-admission` required check.
- Main still runs integrated full CI after merge because squash and prefix
  integration rewrite SHAs; rapid main pushes coalesce to the latest commit.
