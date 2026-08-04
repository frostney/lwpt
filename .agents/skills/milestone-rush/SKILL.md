---
name: milestone-rush
description: >-
  Autonomously completes a confirmed milestone by reconciling existing work,
  parallelizing independent implementation, converging and merging pull
  requests, and closing the verified milestone. Use when the user runs
  /milestone-rush for an exact milestone or selects it after /roadmap-review.
license: Unlicense OR MIT
compatibility: >-
  Requires authenticated forge access, git worktrees, and a host that supports
  subagents; implementation, review, and validation use the project's installed
  workflow skills and declared gates.
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
  protection, review policy, and the remote default branch. Never amend,
  rebase, force-push, bypass a gate, or overwrite unrelated work.

## Reconcile and plan

1. Pull fresh milestone, issue, pull-request, review, check, default-branch,
   branch, worktree, and relevant local working-tree state. Read current project
   direction and completion contracts.
2. Classify every milestone item and related local change as delivered, open PR,
   active implementation, ready, blocked, or invalid. Reuse valid work instead
   of restarting it.
3. Verify closed items against source and merge evidence. When required work was
   closed without delivery, comment with the evidence, create a linked
   replacement through `/create-issue automatic`, add it to the milestone, and
   implement the replacement. Stop when the closure records a material rejected
   or deferred product decision.
4. Build a dependency and likely-conflict graph. Prioritize the longest pole and
   early risk reduction, then dispatch every independent ready node to isolated
   subagents and worktrees up to current platform capacity. Do not impose a
   separate issue, wave, review-round, or retry limit.
5. Maintain a resumable checkpoint in the ignored `.agent/HANDOFF.md` after each
   issue or PR transition. Record the milestone identity, graph, active
   worktrees, issue-to-PR state, blockers, and observed validation. Never stage
   or commit the checkpoint; reconcile it with live state when resuming.

## Execute and integrate

1. Give each worker one bounded node and its dependencies. Use
   `/implement-issue automatic` for an issue or `/implement-idea automatic` for
   a confirmed unfiled roadmap item. In either workflow, replace its required
   pre-PR review with `/code-review subagents fix-all`; this is a milestone-rush
   default, not a change to standalone implementation workflows. Automatic mode
   selects the evidence-backed recommendation but never resolves material
   ambiguity, risk, or vision conflict on the user's behalf.
2. Adopt an existing PR when it satisfies the issue and project gates. Adopt
   relevant local state only when its ownership and scope are clear; preserve
   ambiguous, dirty, pre-existing, or unrelated state and report it.
3. Let the implementation workflow validate, review, and hand off through
   `/create-pr`. As each PR becomes ready, run `/review-pr automatic-merge`.
4. Integrate continuously rather than waiting for a batch. After every squash
   merge, refresh milestone and default-branch state; merge the updated remote
   default into every affected remaining branch and rerun its applicable gates.
   Review and CI evidence is valid only for the current PR head.
5. Add newly discovered work to the milestone only when evidence shows it is
   required by an existing acceptance criterion, dependency, regression, or
   Definition of Done. Keep tightly coupled fixes in the current PR; create an
   issue for independently trackable required work. Record desirable follow-ups
   without expanding the milestone.
6. Re-pull scope after every merge. Absorb externally added issues only when
   they clearly fit the confirmed plan; stop for material scope expansion.
7. When a milestone merge causes an integrated regression, create and implement
   the required repair. Treat unrelated or materially ambiguous failures as
   blockers.

Manage implementation and review workers within the host's shared capacity.
Keep implementation nodes running while useful work remains, and queue review
perspective lanes until slots free up; temporary slot exhaustion is not
sub-agent unavailability. If review sub-agents are unsupported, remain
unavailable after bounded retry, or return incomplete evidence, the
implementation worker completes those lanes directly and records the fallback
for the milestone report.

## Blockers and completion

- Quarantine a blocked node and its dependents, then continue every independent
  runnable node. Pause only when no further safe progress remains. Never close
  a milestone with blocked or unverified work.
- Retry transient reviewer, CI, and forge states with bounded backoff under the
  host's platform limits. A rate limit or missing verdict is pending, not green.
- Before closure, re-fetch forge state and verify that every in-scope item is
  delivered and closed with evidence; no milestone PR, required check, review
  thread, or active review-tool pass remains pending; and the synced default
  branch passes the applicable full project gate. A failure resumes execution.
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
- validation and reviewer evidence for final PR heads and integrated default;
- required additions, deferred follow-ups, blockers, and remaining work;
- cleanup or preserved state and milestone closure status.

If the milestone closed, ask whether to run `/run-retro`. Do not invoke it
without explicit approval.
