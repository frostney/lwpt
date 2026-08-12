---
name: status-report
description: >-
  Builds a read-only current-repository Kanban from live pull-request, CI,
  review, branch, and worktree evidence. Use when the user asks for a status
  report, PR board, review-readiness board, or local-work overview.
license: Unlicense OR MIT
compatibility: >-
  Requires git plus authenticated read-only forge access; GitHub repositories
  use gh and network access. Rich board rendering is optional.
---

# Status report

Return one snapshot-dated status board for the current repository and all of its
worktrees. Reconcile local and forge state before classifying anything.

## Read-only contract

- Inspect and report only. Never fetch, pull, switch, edit repository or
  worktree files, stage, commit, push, rerun CI, retrigger a reviewer, resolve a
  thread, post a comment, or change PR state.
- Include every open PR regardless of author, automation, or target branch.
- Treat CI and review evidence as valid only for the current PR head. Any head
  change resets both gates.
- Record the observation time and disclose unavailable, incomplete, stale, or
  permission-limited sources. Missing evidence is pending, never green.
- Inspect every worktree, but preserve one card per logical work item. Attach a
  linked worktree to its PR card; use `Local work` only when no open PR
  represents the work.

## Gather evidence

1. Resolve the repository, remote default branch, applicable instructions,
   review policy, branch protection, and merge requirements without changing
   local state. Distinguish live forge data from possibly stale remote-tracking
   refs.
2. Paginate every open PR and read its URL, author, base and head refs, head
   commit, draft and merge states, update time, review requests and decisions,
   commit statuses, and check runs.
3. For each current head, read inline review threads, top-level reviews,
   summaries, walkthroughs, suggestions, nitpicks, and reviewer status. Discover
   active review tools from repository configuration, protection rules, and
   current PR evidence; a disabled, historical, or merely installed tool is not
   a gate.
4. Enumerate all repository worktrees and inspect branch, HEAD, upstream,
   ahead/behind state, staged, unstaged, and untracked changes, recent commits,
   and a compact diff summary. Do not mutate a worktree to inspect it.
5. Map local branches and HEADs to PRs. A clean default checkout with no
   divergent work needs no card. Preserve separate cards for distinct detached
   or PR-less work.

When one read interface is unavailable or permission-limited, try another
configured authenticated read-only interface before declaring an evidence gap.
Current official forge and reviewer semantics override enumerated status names
when an API evolves; preserve the completion gates rather than guessing.

## Classify once

Render lanes in this visual order:

`Local work` → `Draft` → `CI running` → `CI failed` → `Active review` → `Ready`

Place each item in exactly one lane using this precedence:

1. **Local work**: meaningful dirty, unpushed, or divergent work with no open PR.
2. **Draft**: any draft PR. Show its CI and review condition on the card without
   moving it to another lane.
3. **CI failed**: a non-draft PR with any applicable current-head failure,
   timeout, cancellation, action-required result, stale result, or equivalent
   terminal failure. A failure outranks checks that are still running.
4. **CI running**: a non-draft PR with no failure but at least one applicable
   current-head check expected, queued, requested, pending, waiting, in progress,
   missing, or unavailable.
5. **Active review**: CI is terminal and green, but human review, an active
   review tool, mergeability, or another repository readiness requirement is
   incomplete or blocked.
6. **Ready**: the PR is non-draft and mergeable under repository policy; every
   applicable current-head check is terminal and accepted; required and
   explicitly requested human reviews are complete; every active review tool
   has a current-head terminal verdict; and no unresolved actionable finding
   remains.

Repository policy decides whether a non-required check is advisory and how
neutral, skipped, or intentionally absent results are treated. Without explicit
policy, never reinterpret a visible failure as green.

## Review completion

- Treat an explicitly requested human or automated reviewer as active. Pending
  review requests and `CHANGES_REQUESTED` remain open; apply the repository's
  current-head approval-dismissal policy.
- For every active review tool, inspect inline threads plus top-level status,
  summaries, suggestions, and nitpicks. A rate limit, quota response, error,
  incomplete run, missing verdict, or review against an older head is pending.
- For every active automation, include its current-head summary or walkthrough
  status and every unresolved inline or top-level nitpick. Apply the same
  evidence-based semantics without hardcoding a provider.
- Do not infer that source changes resolved a finding. Use the current forge
  resolution and verdict evidence; expose uncertainty as a blocker.

## Summarize local work

Write one short semantic sentence for each local or linked-worktree change.
Infer intent from the linked PR, current handoff when it matches the branch,
branch name, commit subjects, and diff together. Never guess: if intent remains
unclear, say so concisely.

Keep local metadata compact: branch, linked PR when present, dirty-state counts,
ahead/behind state, worktree identity, and short HEAD. Do not dump changed paths
or a full diff. Add one concise next action to every non-ready card; use
`Ready to merge` for ready cards.

## Present the board

Read [the rendering contract](references/rendering.md), then render all six
lanes even when empty. Order cards within a lane by oldest meaningful activity
first. Keep evidence and access warnings close to the affected card, and add a
short evidence-gap list only when the board cannot contain them cleanly.

Do not write a durable report or repository file unless the user separately
requests one.
