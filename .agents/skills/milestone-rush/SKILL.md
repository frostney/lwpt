---
name: milestone-rush
description: >-
  Autonomously completes a confirmed milestone by reconciling existing work,
  parallelizing independent implementation, converging and merging pull
  requests, and closing the verified milestone. Use when the user runs
  /milestone-rush for an exact milestone or selects it after /roadmap-review.
license: Unlicense OR MIT
compatibility: >-
  Requires authenticated forge access, git worktrees, the internal
  `delivery-wait` skill, and a host that supports subagents and passive
  foreground-process waiting; implementation, review, and validation use the
  project's installed workflow skills and declared gates.
---

# Milestone rush

Finish the named milestone from its actual current state. The run owns execution,
not release publication.

## Authority and gates

- Require an exact repository and milestone. An explicit invocation authorizes
  scoped issue comments and replacement issues, branches and worktrees,
  implementation, validation, commits, plain pushes, pull requests, review
  remediation, squash merges, branch cleanup, and closing that milestone.
- Never create a release. After completion, offer `/run-retro` and wait for
  explicit approval before invoking it.
- Accept either a confirmed `/roadmap-review` handoff or direct invocation. For
  direct invocation, verify current scope, direction, readiness, dependencies,
  and success criteria before executing. Stop for material replanning rather
  than silently changing the milestone.
- Treat a confirmed roadmap item as the mini-spec for `/implement-idea
  automatic` only when it states the outcome, scope and non-goals, and
  verifiable success criteria.
- Respect project instructions, Definitions of Ready and Done, branch
  protection, review policy, and the remote default branch. Never amend, bypass
  a gate, or overwrite unrelated work. Ordinary branches remain merge-only;
  only `git-workflow` may apply its guarded native-stack rewrite exception.
- Before planning or spawning, read and validate repository-root
  `ORCHESTRATION.md` under
  [references/orchestration.md](references/orchestration.md), then initialize the
  ignored event ledger under
  [references/event-ledger.md](references/event-ledger.md).

## Reconcile and plan

1. Pull fresh milestone, issue, pull-request, review, check, default-branch,
   branch, worktree, and relevant local working-tree state. Read current project
   direction, completion contracts, and the validated orchestration policy or
   reported provider-neutral fallback.
2. Run every repository-declared lane-admission preflight before adopting or
   creating a worktree. This includes path/toolchain/resource constraints when
   the repository declares them. Relocate or reject an unsafe worktree before
   implementation or a complete local gate; never learn a known environmental
   limit by burning the full suite.
3. Classify every milestone item and related local change as delivered, open PR,
   active implementation, ready, blocked, or invalid. Reuse valid work instead
   of restarting it.
4. Verify closed items against source and merge evidence. When required work was
   closed without delivery, comment with the evidence, create a linked
   replacement through `/create-issue automatic`, add it to the milestone, and
   implement the replacement. Stop when the closure records a material rejected
   or deferred product decision.
5. Inspect the current delivery surface and include the provider-neutral CI
   integration recommendation required by the orchestration reference. This is
   a plan artifact, not authority to change workflows, labels, rulesets,
   controllers, credentials, or provider configuration. Make a required missing
   capability an explicit repository-owned prerequisite; otherwise document the
   safe current-CI fallback and its cost.
6. Build a dependency and likely-conflict graph. A native stack may represent a
   true dependency chain or a confirmed logical decomposition of one large
   issue, provided each layer is independently reviewable. Prioritize the
   longest pole and early risk reduction, then dispatch every independent ready
   node to isolated subagents and worktrees up to current platform capacity. Do
   not impose a separate issue, wave, review-round, or retry limit.
7. Maintain the outer workflow's resumable state in the ignored
   `.agent/HANDOFF.md` after each
   issue or PR transition. Record the milestone identity, graph, active
   worktrees, issue-to-PR state, blockers, observed validation, and the stable
   decision registry. Never stage or commit the checkpoint; reconcile it with
   live state when resuming.

## Execute and integrate

1. Keep the coordinator thin: it owns confirmed decisions and provenance,
   graph state, worker admission and replacement, delivery-state promotion,
   integration, merge, and milestone closure. Detailed investigation,
   implementation, remediation, and validation belong to bounded workers.
2. Give each worker one context-isolated task packet and its dependencies. Use
   `/implement-issue automatic` for an issue or `/implement-idea automatic` for
   a confirmed unfiled roadmap item. In either workflow, replace its required
   pre-PR review with `/code-review subagents fix-all`; this is a milestone-rush
   default, not a change to standalone implementation workflows. Automatic mode
   selects the evidence-backed recommendation but never resolves material
   ambiguity, risk, or vision conflict on the user's behalf.
3. Adopt an existing PR when it satisfies the issue and project gates. Adopt
   relevant local state only when its ownership and scope are clear; preserve
   ambiguous, dirty, pre-existing, or unrelated state and report it.
4. Let the implementation workflow validate, review, and hand off through
   `/create-pr`. As each ordinary PR becomes ready, run `/review-pr
   automatic-merge`. For a native stack, collect each layer's `review-pr`
   exact-head `ready` result, then let the stack owner recheck and atomically
   merge the selected ready prefix through `git-workflow`.
5. Keep remediation validation focused on the changed behavior. Run the
   repository's complete local gate once only after implementation and bounded
   review fixes converge on the intended head, unless a new material source
   change invalidates it. Do not repeatedly use a complete suite as the
   diagnostic loop.
6. Treat heavyweight full CI as terminal promotion evidence, never as a remote
   debugger. Dispatch it only after the current base, required PR checks, and
   every active review tool have converged on the candidate head. Cancel
   superseded runs when the forge supports safe cancellation; record otherwise
   unavoidable waste. A later head, base, topology, or review change invalidates
   the proof.
7. Integrate continuously rather than waiting for a batch. After every squash
   merge, refresh milestone and default-branch state; merge the updated remote
   default into every affected remaining branch and rerun its applicable gates.
   Review and CI evidence is valid only for the current PR head.
8. Add newly discovered work to the milestone only when evidence shows it is
   required by an existing acceptance criterion, dependency, regression, or
   Definition of Done. Keep tightly coupled fixes in the current PR; create an
   issue for independently trackable required work. Record desirable follow-ups
   without expanding the milestone.
9. Re-pull scope after every merge. Absorb externally added issues only when
   they clearly fit the confirmed plan; stop for material scope expansion.
10. When a milestone merge causes an integrated regression, create and implement
   the required repair. Treat unrelated or materially ambiguous failures as
   blockers.

Manage implementation and review workers within the host's shared capacity.
Keep implementation nodes running while useful work remains, and queue review
perspective lanes until slots free up; temporary slot exhaustion is not
sub-agent unavailability. If review sub-agents are unsupported, remain
unavailable after bounded retry, or return incomplete evidence, the
implementation worker completes those lanes directly and records the fallback
for the milestone report.

Append every material lifecycle, decision, wait, gate, usage, retry, rework, and
integration transition to `.agent/milestone-rush-events.jsonl`. Inner delivery
and review loops launch the bundled deterministic foreground waits; the outer
milestone loop passively awaits worker or command completion and reconciles its
checkpoint after each returned transition. Notify the coordinator only on
changed, terminal, or exceptional state. Unsupported passive waiting required
by repository policy blocks spawning; never substitute model heartbeats.

## Blockers and completion

- Quarantine a blocked node and its dependents, then continue every independent
  runnable node. Pause only when no further safe progress remains. Never close
  a milestone with blocked or unverified work.
- Retry transient review, CI, and forge states through event-driven waits under
  the host's platform limits. Use an exact safe `retry_at` when available. A
  rate limit or missing verdict is pending, not green.
- Before closure, re-fetch forge state and verify that every in-scope item is
  delivered and closed with evidence; no milestone PR, required check, review
  thread, or active review-tool pass remains pending; and the synced default
  branch passes the applicable full project gate. A failure resumes execution.
- Validate the current run's event ledger against the event-ledger reference
  before closure. Missing required event classes, unclosed spans, silent null
  usage/resource fields, or absent command/CI identities block closure until
  corrected or explicitly marked unavailable under the schema.
- Close the milestone only after that integrated gate passes. Remove only clean,
  merged worktrees created by this run; preserve and report every other
  worktree.

## Report

Return one audit-style summary covering:

- initial and final scope, including scope drift;
- issue, worker/worktree, PR, and squash-merge mapping;
- each PR's review perspective-to-lane map, completed or incomplete lanes, and
  every single-agent fallback with its reason;
- reused local or PR state;
- orchestration policy status, decision IDs and conflicts, CI integration
  recommendation, prerequisites or fallback cost, worker context modes, and any
  monitoring fallback;
- event-ledger path and completeness, intervention checkpoints, and unavailable
  telemetry fields;
- validation and reviewer evidence for final PR heads and integrated default;
- required additions, deferred follow-ups, blockers, and remaining work;
- cleanup or preserved state and milestone closure status.

If the milestone closed, ask whether to run `/run-retro`. Do not invoke it
without explicit approval.
