---
name: create-pr
description: >-
  Publishes a completed change as a templated draft pull request, reconciles
  PR-only metadata and readiness state, waits for CI, and marks it ready. Use
  when the user runs /create-pr.
license: Unlicense OR MIT
compatibility: >-
  Requires git, Python 3.11 or newer, the GitHub CLI (gh) authenticated to the
  target repository, the internal `delivery-wait` skill, and network access.
---

# Create PR

The request authorizes the repository's declared gates, relevant commits, PR
metadata updates, one ordinary draft pull request or the confirmed native stack
layers owned by the change, and their transitions to ready for review. It does
not authorize implementation fixes or unrelated changes.

When the branch belongs to a native GitHub stack, read
[../git-workflow/references/github-stacks.md](../git-workflow/references/github-stacks.md).
The request then authorizes submission and metadata reconciliation for the
confirmed stack layers owned by the current change, not unrelated branches.

1. Inspect the working tree, staged diff, recent commits, remote default branch,
   stack topology when applicable, and any existing remote head. Preserve
   unrelated local work.
2. Stop if there are no relevant changes or commits ahead of the remote base.
   Continue without an empty commit when the work is already committed.
3. If currently on the base branch, create a focused branch named from the issue
   or change.
4. Establish the PR claim and publication requirements before publishing
   anything. Read the explicit request, linked issue or confirmed mini-spec,
   applicable project instructions, product docs, ADRs or durable decisions,
   the nearest `DEFINITION_OF_READY.md`, and the completion evidence supplied by
   the implementation workflow. If no source states the claim, reconstruct the
   narrowest claim supported by the commits and diff and label it as inferred.
5. Verify that code review, observed behavior, and the repository's project gate
   all passed on the exact current change. An explicitly accepted limitation
   must name the unverified behavior. Reuse a current project-gate result rather
   than running it again. If the gate result is missing or stale, run the
   declared gate once without weakening it.
6. Stop when required review or behavior evidence is missing, stale, failed, or
   unverified without explicit acceptance. Stop when the project gate fails.
   Report the exact missing evidence or failure and return the change to its
   implementation workflow. Do not test delivered behavior, inspect source as a
   substitute, or fix implementation, test, documentation, generated-artifact,
   compatibility, or CI gaps in this workflow. The only publication exception
   is an explicit user request for a draft PR to obtain a preview environment
   that does not otherwise exist. That PR must remain draft until behavior is
   tested on a preview tied to its exact revision.
7. Stage only relevant files, excluding secrets and unrelated local work.
   Commit uncommitted work with a concise Conventional Commit subject. Never
   amend and never skip hooks. Preserve already-published history and add a new
   commit for any correction.
8. Title each pull request with a Conventional Commit subject covering the whole
   change, since the squash merge makes that title the commit subject on the
   base branch. Fill the matching PR template for each submitted layer and
   preserve its structure. If none exists, use Summary, Testing, and Linked
   issues. Keep the body proportional to the change. Before writing it, search
   open and closed issues and recent sibling sessions or adjacent branches when
   available for related findings and duplicates. Put each closing keyword on
   its own line as `Closes #N`, and only on the layer that completes that issue.
9. Only after the publication checks pass, push an ordinary branch normally and
   set its upstream when needed, then open one draft PR against the remote
   default. For a verified native stack, use `gh stack submit` only after every
   submitted layer has current completion evidence; only guarded official stack
   operations may rebase or push with force-with-lease. Preserve bottom-to-top
   topology and keep each layer draft.
10. Run the PR-specific phase. Compare the actual PR diff, body, links, metadata,
    committed tests and documentation, supplied completion evidence, and facts
    that exist only after publication. Correct metadata-only gaps without a
    commit.
11. If the PR-specific phase or CI exposes a repository, code, behavior, test,
    documentation, generated-artifact, or compatibility gap, keep the PR draft
    and return the exact failure to the implementation workflow. Do not fix it
    here. A later caller may update the PR after the appropriate implementation,
    review, behavior-testing, and project-gate loop passes.
12. Invoke `delivery-wait`'s foreground `wait checks-terminal` operation with
    the repository, exact head, checkpoint, absolute deadline, and `--json`; the
    harness passively awaits it without model heartbeats. When it returns,
    inspect unsuccessful logs. Report a validated code or behavior failure under
    step 11 rather than fixing it.
    If the host cannot passively await a subprocess, report the unsupported
    capability instead of polling through model turns.
13. Keep the PR in draft while any requirement for marking it ready or CI check
    is pending or failing. A PR opened to obtain a preview returns to the
    implementation workflow for black-box testing and cannot become ready in
    this run. If an expected pull-request workflow produces no run, read the PR's
    `mergeable_state` first: a dirty PR gets no pull-request runs, and no
    retrigger can help until the conflict is resolved. Continue monitoring
    pending checks; if they cannot reach a terminal result during the run,
    report their current state. Stop and report the exact blocker for a material
    decision, unrelated failure, unavailable external service, or validation
    that cannot be performed safely.
14. Once the PR is missing nothing required by the publication and PR-specific
    phases and all applicable CI is observed green for its exact head, mark it
    ready for review. Return every affected URL, native stack order when
    applicable, final states, metadata changes, supplied completion evidence,
    and observed readiness and CI evidence.
