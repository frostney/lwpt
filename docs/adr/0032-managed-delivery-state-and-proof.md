# Managed delivery uses explicit transitions and exact native-topology proofs

The 0.5.0 stack trial conflated delivery ownership with stack membership and
used an intentional failed first run as admission. LWPT now models those
concerns separately. `delivery:managed` opts a standalone or native-stack PR
into deferred delivery; `ci:ready`, `review:ready`, and `merge:ready` are its
ordered phase state; `ci:full-required` is independent applicability policy.
GitHub's native pull-request stack and ordered entries are the only topology
authority. A repository-owned `workflow_dispatch` endpoint accepts explicit
transitions, while default-branch observers invalidate head, base, order, or
prefix drift. A native GitHub Actions `delivery-admission` job aggregates the
exact-head PR jobs for ordinary and managed PRs alike. Conditional
`full-ci` proves one singleton or the unchanged cumulative SHA at a frozen
native-prefix top. `merge:ready` remains the machine-validated final state and
is not duplicated by another merge-admission check. This decision was
investigated in [issues #159](https://github.com/frostney/lwpt/issues/159) and
[#160](https://github.com/frostney/lwpt/issues/160). The provider-neutral
review adapter was completed in
[issue #188](https://github.com/frostney/lwpt/issues/188); progressive diagnostic
and terminal-promotion behavior was completed in
[issue #187](https://github.com/frostney/lwpt/issues/187).

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
  code. The automatic read-only PR workflow reports its native required jobs
  directly; the scheduled watchdog feeds terminal full-CI runs
  through that same finalizer when `GITHUB_TOKEN` event suppression prevents a
  `workflow_run` delivery.
- Managed delivery, stack topology, and full-CI applicability can vary
  independently.
- Native diagnostics are allow-listed, exact-head, non-proof runs. Full CI is
  reserved for terminal promotion after base, PR CI, and active review evidence
  converge; superseded runs are cancelled.
- A managed head's first PR attempt always defers; only its explicit rerun may
  execute PR code. Native PR jobs are bound to their exact PR and head;
  full-CI cancellation, failure, and watchdog expiry are terminal failures.
- Ordinary PR CI is automatic. Managed PRs retain a cheap automatic routing
  run; admission reruns that exact PR/head workflow so both routes use the same
  app-bound native aggregation job. Reset returns the PR to draft instead of
  rewriting immutable native checks. The controller does not synthesize
  another PR proof.
- Review automations are configured adapters. At least one must emit
  current-head evidence, every active adapter must reach its configured
  terminal state, and inactive configured adapters do not block delivery.
- Main still runs integrated full CI after merge because squash and prefix
  integration rewrite SHAs; rapid main pushes coalesce to the latest commit.
