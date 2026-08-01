---
name: resolve-reviews
description: >-
  Resolves all current pull-request review comments in place, validates and
  pushes scoped fixes, replies inline, and watches for follow-up findings.
license: MIT
compatibility: Requires git, gh (GitHub CLI), and Node.js installed.
allowed-tools: Bash(npx agent-reviews@1.0.2 *) Bash(pnpm dlx agent-reviews@1.0.2 *) Bash(yarn dlx agent-reviews@1.0.2 *) Bash(bunx agent-reviews@1.0.2 *) Bash(gh pr view --json *) Bash(git branch --show-current) Bash(git rev-parse HEAD) Bash(git status --short) Bash(git diff -- *) Bash(git diff --cached -- *) Bash(git add -p -- *)
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

Use `agent-reviews@1.0.2` for every invocation. The examples use
`npx agent-reviews@1.0.2`; substitute the same pinned package with
`pnpm dlx`, `yarn dlx`, or `bunx` when the project requires another runner.

## Phase 1: fetch and evaluate

1. Verify that `gh pr view` finds an open pull request for the current checkout,
   that `git branch --show-current` is not the PR base branch, and that
   `git rev-parse HEAD` equals the PR head SHA. Record that SHA.
2. Capture the pre-review index and worktree state with `git status --short`,
   `git diff --cached`, and `git diff`. Preserve every pre-existing change.
3. Run `npx agent-reviews@1.0.2 --unanswered --expanded`. In version 1.0.2,
   any reply marks a comment answered; treat that reply as completion for the
   initial filter even when GitHub still displays the thread as unresolved.
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

1. Compare each candidate hunk with the captured pre-review state.
2. Stage only review-generated hunks with `git add -p -- <review-fix-files>`.
   Never stage a whole touched path when it contained a pre-existing change.
   Stop if the relevant hunks cannot be separated unambiguously.
3. Use the project `update-pr` workflow to commit and push the staged review
   fixes. This skill deliberately grants no raw commit or push command.
4. Never amend, skip hooks, rebase, or force-push.
5. Capture the commit hash for inline replies.

If every finding was false positive or already addressed, skip staging,
commit, and push. Replies in that case must not claim a new commit exists.

## Phase 3: reply inline

Reply to every processed inline comment with
`npx agent-reviews@1.0.2 --reply <id> "<outcome>"`.

- Fresh fix: name the commit and summarize the fix; leave the thread open for
  reviewer verification.
- False positive, concluded discussion, already addressed, or user-approved
  skip: explain the outcome and use `--resolve`.
- If the tool reports that a comment is not threadable, record that result and
  do not replace the reply with a top-level pull-request comment.

## Phase 4: watch until quiet

Run:

```sh
npx agent-reviews@1.0.2 --watch --interval 30 --timeout 600
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
