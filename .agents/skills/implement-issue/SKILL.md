---
name: implement-issue
description: >-
  Validates a GitHub issue against the current codebase, reads the nearest
  AGENTS.md/CLAUDE.md and any area-specific agent context first, presents
  implementation options with tradeoffs, implements the chosen option, runs
  verification (UI/UX checks for user-facing changes; the project's full check
  gate before handoff), and prepares a draft PR via /create-pr. Use when the
  user runs /implement-issue with an issue number.
---

# Implement issue

## Instructions

Validate and implement a GitHub issue in the current repository.

### Use the grill skill for thoroughness (always when available)

Before forming a hypothesis or presenting implementation options, the agent **always invokes the grill skill** when it is registered in this environment — not only when something is ambiguous. The grill output is folded into the implementation plan and validation step so the result is more thorough than the raw issue text would produce.

- **`/grill-with-docs` is preferred.** Use `/grill-me` only when `/grill-with-docs` is not registered.
- Discovery hint: look for a skill or command named `grill-with-docs` or `grill-me` (e.g. `~/.cursor/skills/grill-with-docs/`, `~/.cursor/skills/grill-me/`, `.cursor/skills/...`, `.agents/skills/...`).
- If neither is registered, proceed with the workflow on the input as given.

### Steps

1. Parse the issue number. If missing or non-numeric, ask.
2. Fetch the issue with GraphQL first: title, body, state, labels, assignees, URL, comments, and whether the entity is actually a pull request.
3. Fall back to REST when GraphQL is unavailable:

```bash
gh api "repos/$OWNER/$REPO/issues/$ISSUE_NUMBER"
```

1. **Read the project's agent context before forming a hypothesis or editing.** In this order:
   - The **root** `AGENTS.md` (and `CLAUDE.md` if present — usually an alias).
   - The **nearest** `<area>/AGENTS.md` to the files the issue touches in a multi-area repo. Nested files override the root for that area.
   - `CONTRIBUTING.md` when it exists; treat it as authoritative for what may be merged.
   - The repo's `docs/` index (`docs/README.md`, `docs/architecture.md`, `docs/code-style.md`, or equivalent) for the area being changed.
   Do not skip this step even when the issue looks small — Hard Constraints sections (e.g. "Bun only, no npm/pnpm/yarn", "AI SDK via Vercel AI Gateway only") frequently change the implementation path.

2. Validate before coding:
   - The issue exists, is open, and is not a pull request.
   - No `blocked`, `duplicate`, `wontfix`, or equivalent label/comment.
   - Reproduce the reported behavior against current code; do not trust the issue text alone.
   - When the issue cites a reproduction command, test path, or external artifact (test262, Playwright run, etc.), fetch and run that exact artifact before forming a hypothesis. The title is a pointer, not a spec.
   - Expected behavior and acceptance criteria are clear enough to implement.
3. If validation fails or requirements are ambiguous, stop and ask.
4. Present implementation options with tradeoffs, a verification plan, and a recommendation. Do not code until the user picks one or asks you to proceed with the recommendation.
5. Branch / worktree:
   - Prefer reusing an existing focused branch or worktree for the issue.
   - If a branch exists without a worktree, use or create a worktree when that best isolates the work.
   - Otherwise create a focused branch named from the issue (e.g. `issue-123-short-slug`); use a worktree when practical.
6. Implement the smallest complete change that satisfies the chosen approach.
7. Update tests and documentation per the repository's contribution guidance (`CONTRIBUTING.md`, `AGENTS.md`, or equivalent) when present.
8. Run targeted verification first (focused tests, types, lint) on the changed area, then broader verification when the change has wider impact.
9. **If the change is UI/UX, also:**
    - Run the app (or Storybook / component sandbox) and load the affected screens or components.
    - Compare against the design or current state from the issue. Capture before/after screenshots or short recordings.
    - Verify accessibility: keyboard navigation and focus order, visible focus styles, ARIA roles/labels for new interactive elements, color contrast meeting WCAG AA (or the project's standard), and `prefers-reduced-motion` respected for animations.
    - Verify responsive behavior at the project's supported breakpoints and across light/dark/system themes when applicable.
    - Reuse existing design-system components and tokens; do not introduce one-off styles for primitives that already exist.
    - Attach before/after media and accessibility notes to the PR description so reviewers can evaluate without re-running the app.
10. **Run the project's full verification gate before invoking `/create-pr`.** Prefer the project's aggregator script when it exists (e.g. `bun run check`) — that's the canonical "ready to commit" signal. Otherwise run the per-step gate explicitly:

```bash
bun install --frozen-lockfile
bun run format:check   # or biome check
bun run lint           # or biome lint .
bun test
bun run typecheck      # or tsc --noEmit / bunx tsc --noEmit
bun run build
```

Do not skip steps because they "should pass." If any step fails, fix the cause; do not invoke `/create-pr` with a red gate.

1. Invoke `/create-pr` to commit, push, and open the draft pull request. Include `Closes #<issue>` in the PR body.
