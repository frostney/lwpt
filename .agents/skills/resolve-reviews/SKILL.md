---
name: resolve-reviews
description: >-
  Resolves all current pull-request review comments in place, validates and
  pushes scoped fixes, replies inline, and watches for follow-up findings.
license: MIT
compatibility: Requires git, gh (GitHub CLI), and Node.js installed.
allowed-tools: Bash(npx agent-reviews@1.0.2 *) Bash(pnpm dlx agent-reviews@1.0.2 *) Bash(yarn dlx agent-reviews@1.0.2 *) Bash(bunx agent-reviews@1.0.2 *) Bash(git config *) Bash(git status *) Bash(git diff *) Bash(git add -- *) Bash(git commit *) Bash(git push *)
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

1. Run `npx agent-reviews@1.0.2 --unanswered --expanded`.
2. Read the referenced code and repository contracts before judging each
   comment.
3. Classify bot comments as true positive, false positive, or uncertain.
   Classify human comments as actionable, discussion, or already addressed.
4. Fix every true positive and actionable comment minimally. Ask the user only
   when a material trade-off or genuinely uncertain intent remains.
5. Track each comment ID, its classification, and every file changed by this
   review pass. Do not reply until the fixes have been validated and, when
   needed, committed and pushed.

## Phase 2: validate and publish scoped fixes

Run the repository-declared validation for the changed files and behavior.
Then inspect `git status --short` and `git diff -- <review-fix-files>`.

If this review pass changed files:

1. Stage only those files with `git add -- <review-fix-files>`; never stage the
   entire worktree.
2. Commit with a concise Conventional Commit subject. Never amend and never
   skip hooks.
3. Push normally. Never rebase or force-push.
4. Capture the commit hash for inline replies.

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
bounded quiet period completes without new comments.

## Completion report

Report the counts fixed, already addressed, rejected as false positives, or
skipped; the commits pushed; validation results; and the final unanswered and
unresolved thread counts.
