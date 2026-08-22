# Repository Orchestration Policy

## Authority and fallback

This file is LWPT's authoritative repository policy for agent capability,
context, token intervention, and delivery endpoint bindings. It is subordinate
to [`AGENTS.md`](./AGENTS.md), repository security policy, and the safety gates
of the invoked workflow.

A generic orchestrator must classify this policy as exactly one of these
states before it plans or spawns work:

- **Valid:** every required heading, capability class, field, and threshold is
  supported and internally consistent. Apply this policy.
- **Missing:** use the consumer's conservative generic fallback and report the
  missing repository policy before work begins.
- **Invalid:** a required field or measurable threshold is malformed. Block
  spawning and request a policy correction.
- **Contradictory:** two applicable rules require incompatible behavior. Block
  spawning and name both rules.
- **Unsupported:** the consumer cannot implement a required capability,
  context mode, ledger field, endpoint, or intervention. Block spawning and
  report the unsupported requirement.

Missing policy is the only state that permits fallback. Invalid,
contradictory, and unsupported policy never silently degrades.

## Delivery integration endpoints

LWPT exposes one trusted transition endpoint:
`.github/workflows/delivery-transition.yml`. Invoke it from the repository's
default branch with
`gh workflow run delivery-transition.yml --ref <default-branch>` and the fields
below, or supply the same fields in the Actions UI. The workflow run is the
accepted/rejected transition audit. GitHub Actions' native
`delivery-admission` job aggregates the exact-head PR gate; `full-ci` is the
conditional exact-SHA promotion proof.

| Transition | Operation | Required inputs | Accepted state | Completion evidence |
| --- | --- | --- | --- | --- |
| Enrol managed delivery | `enrol` | `pr_number`, `expected_head` | `delivery:managed`; downstream readiness cleared | Cheap automatic PR routing run on the exact head |
| Admit PR CI | `ci` | `pr_number`, `expected_head` | `ci:ready`; the exact-head PR run is admitted/rerun when needed | Successful native exact-head `delivery-admission` job |
| Open review | `review` | `pr_number`, `expected_head` | `review:ready`; PR must already be ready | Provider-neutral review convergence remains external |
| Run a native diagnostic | `diagnostic` | `pr_number`, `expected_head`, `diagnostic_target`, `diagnostic_selector` | No readiness mutation | Non-proof `diagnostic/...` run for one allow-listed native slice |
| Prove full CI | `full-ci` | `pr_number` as candidate, `expected_head` | No readiness label; frozen singleton or prefix dispatched | Successful exact-head `full-ci` with topology digest |
| Admit merge | `merge` | `pr_number`, `expected_head`, `candidate_pr_number` | `merge:ready`; draft state is unchanged | Current CI, review, replies, threads, and applicable full-CI proof |
| Return to waiting | `reset` | `pr_number`, `expected_head` | Readiness labels cleared; PR returned to draft | Native check history remains immutable evidence |

`delivery:managed`, native stack membership, and `ci:full-required` are
independent dimensions. A managed PR may be standalone. A native stack may be
ordinary. Full CI may apply to either. GitHub's native `PullRequest.stack` and
ordered entries are the sole topology authority; labels and branch names never
declare stack membership.

Diagnostics are remediation tools, never delivery proof. The trusted endpoint
accepts only repository-declared targets and test selectors, refuses forks and
stale heads, and dispatches no arbitrary command. A new diagnostic for the same
PR cancels its superseded diagnostic run. The initial allow-list covers Windows
default, E2E, and TLS slices plus bounded Intel-Darwin selected-scheduling and
ordinary-path probes that capture a native process sample on timeout. `full-ci`
is a terminal promotion:
the candidate must be marked `ci:full-required`, integrated with its current
base, green in exact-head PR CI, and converged under the active review policy
before the matrix is dispatched. Head, topology, or later review change fails
its proof and cancels the run.

The endpoint promotes state but never merges. Milestone Rush or a human
maintainer owns integration after `merge:ready`. `merge:ready` records the
point-in-time acceptance produced by the `merge` operation; it is not durable
proof by itself. For a singleton, the coordinator invokes `merge` immediately
before integration. For a native prefix, it invokes `merge` for each
`delivery:managed` member against the same candidate before the first merge,
then integrates that frozen prefix from bottom to top without interleaving
unrelated work. An ordinary member never uses the endpoint; at its merge turn
it remains individually subject to current branch protection and the ordinary
review policy. The coordinator must not infer current eligibility from labels
left by an earlier preflight. Reinvocation before integration is idempotent and
revalidates the current head, review, topology, and applicable full-CI evidence.
Ordinary and managed PRs use the same native PR workflow and required
`delivery-admission` job. The controller only advances a managed PR through its
phase labels and reruns its deferred exact-head workflow when admitted.

GitHub does not permit the workflow's `GITHUB_TOKEN` to invoke
`markPullRequestReadyForReview`. After a successful exact-head `ci` transition,
the coordinator uses its ordinary authenticated PR operation (`gh pr ready`
for CLI-capable harnesses), verifies the same head is still current, and then
invokes `review`. The review transition fails closed while the PR is draft.
Returning the PR to draft invalidates `review:ready` and `merge:ready`; merge
admission fails closed while it remains draft and never changes draft state.

## Capability decision tree

Use capability classes, never product model names.

1. Monitoring, timing, status collection, deterministic checks, mechanical
   evidence extraction, and unchanged-state reporting use the **efficient**
   capability class at its standard reasoning level.
2. Material design, implementation, security work, complex diagnosis, and
   independent review use the **frontier** capability class with **high**
   reasoning.
3. If a task spans both classes, split its deterministic portion when useful;
   the material decision owner remains frontier/high.
4. If classification is ambiguous, use frontier/high and record the reason in
   the lane ledger.

No token or context intervention may silently downgrade work below the class
required by this decision tree.

## Coordinator and lane responsibilities

The coordinator stays thin. It owns stable decisions, dependency topology,
lane packets, promotion, delivery transitions, integration, and merge. It does
not retain detailed implementation work that belongs to a bounded lane.

Lean lane agents own implementation, remediation, independent review, local
validation, exact-head reporting, and structured handoff for their assigned
node. A lane reports conflicting evidence instead of silently reopening a
stable decision.

External polling uses a non-LLM watcher wherever the host permits. A model is
invoked only for changed, terminal, or exceptional state. A known wait uses
the exact reported wake time.

## Context packets

Independent agents default to `fork_turns:none`. Each lane receives a compact
packet containing:

- applicable stable decision IDs and their settled text;
- issue number and exact head;
- owned file or behavior scope;
- dependencies and blockers;
- acceptance criteria; and
- required local, CI, review, and delivery gates.

Include only the most recent three to five turns when they are immediately
relevant. Full-history inheritance requires a recorded, scoped exception that
explains which missing context cannot be represented in the compact packet.

## Token ledger

Record these fields per lane and cumulatively by capability class:

- inference count;
- input, cached input, uncached input, output, and reasoning tokens;
- capability class and reasoning level;
- context mode (`none`, bounded recent turns, or full history);
- compaction count; and
- durable workflow transitions.

A durable transition is a settled decision, completed bounded packet, new
exact head, validation or review state change, PR state change, or merge. A
poll, repeated narration, or unchanged external state is not durable.

## Intervention thresholds

Context occupancy for one inference is input tokens divided by that model's
active context-window capacity. Compute the rolling median over the latest ten
inferences in the lane; before ten exist, use all completed inferences.

- When that median becomes greater than 40%, record a warning and choose
  whether to continue, checkpoint, split, replace, or escalate.
- When that median becomes greater than 55%, checkpoint durable state and
  split or replace the lane before another inference. Escalation is allowed
  only when neither action can preserve required capability or context.
- On the 25th consecutive model inference without a durable transition,
  record and execute an explicit continue, split, replace, or escalate
  decision before inference 26.
- A monitor may perform at most three model inferences without external state
  change. Before a fourth, move polling to a non-LLM watcher.

An intervention never silently downgrades capability, silently stops required
work, or ignores the threshold. The first lean Milestone Rush records totals
by capability class and produces a calibration follow-up. This policy sets no
hard cumulative run budget until that evidence exists.

## Unsupported or contradictory policy handling

Report the exact heading, rule, value, and consumer limitation. Preserve work
already made durable, do not spawn or replace lanes under guessed semantics,
and request correction from the repository owner. A consumer may resume only
after the policy is valid or the owner changes it explicitly.
