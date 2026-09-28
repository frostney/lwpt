# Delivery is skill-owned; the repository keeps one gate

Supersedes [ADR-0032](./0032-managed-delivery-state-and-proof.md).

ADR-0032 gave LWPT a repository-owned delivery state machine. A
`workflow_dispatch` endpoint moved `delivery:managed` pull requests through
`ci:ready`, `review:ready`, and `merge:ready` labels. Observer, finalizer, and
watchdog workflows invalidated stale state and concluded exact-SHA full-CI
check runs. About 3,900 lines of workflow and Python supported it. Apart from
[PR #292](https://github.com/frostney/lwpt/pull/292), which was already managed
and finished under the old machinery, no pull request had used it since
2026-09-05. Meanwhile the refreshed known-good-route skills took over the same
work without repository-specific infrastructure. `/deliver` awaits CI,
converges feedback, merges, and verifies integration. `/address-feedback`
converges review threads under `.github/delivery/review-automations.json`.
`delivery-wait` provides deterministic, resumable waits on exact heads and
workflow runs. milestone-rush coordinates fan-out.

LWPT now keeps only what those skills cannot provide:

- `pr.yml` runs the native PR gate automatically for every pull request,
  whatever its base branch. Its `delivery-admission` job aggregates the native
  jobs, and the main ruleset requires only that job, bound to GitHub Actions.
- `ci.yml` verifies every push to `main`. On `workflow_dispatch` it runs either
  the full native matrix (`mode=manual`) on any ref or one allow-listed
  diagnostic slice (`mode=diagnostic`) on any ref.
- [`ORCHESTRATION.md`](../../ORCHESTRATION.md) declares the policy the skills
  consume: capability routing, context packets, token interventions, waits,
  escalation, the worktree path budget, the integration destination, and the
  full-CI rule. Every pull request needs a green `mode=manual` run on its
  exact head before a head-matched squash merge, and only while the current
  `main` commit has a successful push run.
  It also names the review evidence: an independent review the delivering
  agent runs on the exact head, currently Codex with `gpt-6-astra`.
- `.github/delivery/review-automations.json` stays at the path
  address-feedback reads by default. It lists no hosted automations, so
  address-feedback waits only on review threads.

## Considered options

- **Keep the ADR-0032 state machine.** Rejected. It duplicated what the skills
  now do, cost a controller, four workflows, and a 1,500-line model test to
  maintain, and nothing had used it for three weeks.
- **Keep full CI as a machine-checked proof with a finalizer.** Rejected.
  `delivery-wait wait workflow-terminal` binds a manual run to its exact head,
  and `gh pr merge --match-head-commit` refuses a head that moved after the
  proof. A required full-CI check would need the finalizer back to write it. The repository is
  user-owned, so merge queue is unavailable and cannot carry that proof either.
- **Replace the endpoint with labels that trigger workflows.** Rejected for the
  reason ADR-0032 gave: a label would be both the request and the accepted
  state.

## Consequences

- Pull requests no longer defer CI, and no workflow writes to pull requests.
  Every remaining workflow that runs pull-request code keeps read-only
  permissions.
- Native stacked pull requests get PR CI whatever their base branch is called.
  They are no longer limited to `codex/**` bases.
- Readiness is exact-head evidence that the skills observe: the required check,
  review convergence, resolved threads, and full CI. It is not a label.
  `delivery:managed`, `ci:ready`, `review:ready`, `merge:ready`,
  `stack:managed`, and `ci:full-required` retire. Full CI applies to every
  pull request, because the September 2026 flake work showed the PR gate
  alone repeatedly missing Intel-Darwin, i386 and cross-toolchain breaks.
- Macroscope, which had run out of credits, is no longer a review gate. An
  independent review run by the delivering agent replaces it: standards and
  specification axes, plus security for trust surfaces. CodeRabbit reviews
  non-draft pull requests automatically instead of waiting for
  `review:ready`, but it is advisory only.
- Diagnostics can target any branch. The target/selector allow-list still
  refuses arbitrary commands, and diagnostics are remediation, never proof.
- The scheduling diagnostic and Windows tooling move to `.github/ci/`.
  `.github/delivery/` now holds only the review policy.
- A push to `main` still runs the integrated full matrix on the squash commit.
  That run is the delivery's integration evidence.
