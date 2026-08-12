---
name: git-workflow
description: >-
  Applies the user's git defaults: branch from the remote default, merge rather
  than rebase for ordinary branches, use native GitHub stacks when selected,
  never amend, and squash-merge pull requests. Use when branching, syncing,
  committing, pushing, or merging in the user's repos.
license: Unlicense OR MIT
compatibility: >-
  Requires git; pull-request operations also require the GitHub CLI (gh) and
  network access.
---

# Git workflow

Apply these defaults unless the user explicitly overrides them in the same
turn. A git request authorizes only the repository and forge state required for
that operation.

- Resolve the base from the remote default; never hardcode `main`.
- Before the first edit in any newly selected, created, or reused branch or
  worktree, require a clean worktree and fetch the remote default branch. Stop
  and report dirty files; never stash, commit, or discard them automatically.
- Create focused branches and worktrees directly from the freshly fetched
  remote default tip. Do not configure a focused branch to track the remote
  default; set its upstream only when pushing that focused branch.
- When entering an existing focused branch or worktree, merge the freshly
  fetched remote default before editing.
- Merge the remote base to update a branch. Never rebase.
- Stop and report merge conflicts; do not bypass or rewrite them.
- Never amend commits. Add a new commit for every correction.
- Never force-push. Stop if a plain push is rejected by divergent history.
- Stage only relevant files and exclude secrets or unrelated local work.
- Use concise Conventional Commit subjects in imperative mood.
- Let hooks run unless the user explicitly asks otherwise.
- Squash-merge pull requests and delete the source branch afterward.
- Because the merge is a squash, the pull request **title** becomes the commit
  subject on the base branch — the branch's own commit subjects do not survive.
  Give the title a Conventional Commit subject describing the change as a whole,
  and pick its type from the net effect rather than from the most frequent
  commit under it. Where a project generates its changelog or version bump from
  commit history, a non-conforming title merges cleanly and is then silently
  absent from it.

## Native GitHub stacks

Use the official `gh stack` workflow when the user selects a stack, when work
has a real dependency chain, or when a confirmed large issue is deliberately
split into cumulative, independently reviewable layers. Do not stack unrelated
work. Each layer must have one clear claim, a bounded diff, its own validation,
and an explicit subset of the acceptance criteria.

Read [references/github-stacks.md](references/github-stacks.md) before creating,
syncing, pushing, submitting, reviewing, or merging a stack. That reference is
the only exception to the merge-only and never-force-push defaults above:
rebases and force-with-lease are permitted only when performed by verified
`gh stack` commands against a clean, confirmed native stack. Raw `git rebase`,
`git push --force`, and manual `git push --force-with-lease` remain forbidden.

After a squash merge, sync the local base and remove the merged local branch.
