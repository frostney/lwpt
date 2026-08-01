---
name: resolve-reviews
description: >-
  Resolves all current pull-request review comments in place, validates and
  pushes scoped fixes, replies inline, and watches for follow-up findings.
license: MIT
compatibility: Requires git, gh (GitHub CLI), and Node.js installed.
allowed-tools: Bash(.agents/skills/resolve-reviews/scripts/current-pr-reviews *) Bash(git status --short) Bash(git diff -- *) Bash(git diff --cached -- *) Bash(git add --intent-to-add -- *) Bash(git add -p -- *)
metadata:
  upstream: https://github.com/pbakaus/agent-reviews
  upstream-skill-version: "1.0.2"
  package-version: "1.0.2"
---

# Resolve reviews

Resolve every current review thread, then watch for follow-up comments until
the pull request is quiet. This repository-local adaptation pins the review
CLI and scopes every commit to files changed while addressing review findings.

## Package runner

Use `scripts/current-pr-reviews` for every invocation. The wrapper pins
`agent-reviews@1.0.2`, rejects arbitrary PR or repository targets, and verifies
the open PR, current branch, and exact head before the CLI can read or mutate a
review thread.

## Phase 1: fetch and evaluate

1. Run `scripts/current-pr-reviews unanswered`. Its identity guard verifies an
   open pull request for the current checkout, a non-base branch, and an exact
   PR-head match before returning comments. Record that head SHA.
2. Capture the pre-review index and worktree state with `git status --short`,
   `git diff --cached`, and `git diff`, including every untracked path. If the
   baseline is not clean, stop before editing and report the exact paths; never
   absorb pre-existing work into a review-fix commit.
3. Evaluate the expanded unanswered comments returned by the wrapper. In
   version 1.0.2, any reply marks a comment answered; treat that reply as
   completion for the initial filter even when GitHub still displays the
   thread as unresolved.
4. Read the referenced code and repository contracts before judging each
   comment.
5. Classify bot comments as true positive, false positive, or uncertain.
   Classify human comments as actionable, discussion, or already addressed.
6. Fix every true positive and actionable comment minimally. Ask the user only
   when a material trade-off or genuinely uncertain intent remains.
7. Track each comment ID, its classification, and every hunk changed by this
   review pass. Do not reply until the fixes have been validated and, when
   needed, committed and pushed.

Review and CI evidence is valid only for the recorded PR head. Invalidate it
after any new commit or base merge, then repeat the identity and head checks.

## Phase 2: validate and publish scoped fixes

Run the repository-declared validation for the changed files and behavior.
Then inspect `git status --short` and `git diff -- <review-fix-files>`.
If any declared check fails, stop. Do not stage, commit, push, or send a fresh-
fix reply; report the failed validation instead.

If this review pass changed files:

1. Compare both staged and unstaged candidate diffs with the captured baseline,
   and record every untracked path created by the review fix.
2. Stage only review-generated hunks with `git add -p -- <review-fix-files>`.
   Never stage a whole touched path when it contained a pre-existing change.
   Stop if the relevant hunks cannot be separated unambiguously.
3. For a verified new file created by the review fix, obtain explicit user
   approval, run `git add --intent-to-add -- <new-files>`, and then select its
   review-generated contents with `git add -p -- <new-files>`.
4. Inspect `git diff --cached -- <review-fix-files>` and `git status --short`.
   Proceed only when the index contains all and only verified review fixes and
   no unrelated staged or untracked path can enter the commit.
5. Use the project `update-pr` workflow to commit and push the staged review
   fixes. This skill deliberately grants no raw commit or push command.
6. Never amend, skip hooks, rebase, or force-push.
7. Capture the commit hash for inline replies.

If every finding was false positive or already addressed, skip staging,
commit, and push. Replies in that case must not claim a new commit exists.

## Phase 3: reply inline

Reply to every processed inline comment with
`scripts/current-pr-reviews reply <id> "<outcome>"`.

- Fresh fix: name the commit and summarize the fix; leave the thread open for
  reviewer verification.
- False positive, concluded discussion, already addressed, or user-approved
  skip: explain the outcome and use `--resolve`.
- If the tool reports that a comment is not threadable, record that result and
  do not replace the reply with a top-level pull-request comment.

## Phase 4: watch until quiet

Run:

```sh
scripts/current-pr-reviews watch
```

When the watcher finds new comments, repeat the evaluation, validation,
scoped-publish, and reply phases, then restart the watcher. Stop only when its
bounded quiet period completes without new comments. Version 1.0.2 measures
the timeout from watcher startup and exits on the first new comment; activity
does not reset that timer, so every detected batch requires a fresh invocation.

## Completion report

Report the counts fixed, already addressed, rejected as false positives, or
skipped; the commits pushed; validation results; and the final tool-reported
unanswered and unresolved counts under version 1.0.2 reply semantics.
