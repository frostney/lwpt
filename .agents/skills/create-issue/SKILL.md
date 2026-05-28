---
name: create-issue
description: >-
  Creates a well-structured GitHub issue from a tagline or short description in
  any repository, using the project's issue template and label conventions, and
  capturing UI/UX context (screenshots, design references, accessibility,
  responsive, theme) when the change is user-facing. Use when the user runs
  /create-issue or asks to file a GitHub issue.
---

# Create issue

## Instructions

Create a GitHub issue in the current repository from the user's tagline or short description.

### Use the grill skill for thoroughness (always when available)

Before drafting, the agent **always invokes the grill skill** when it is registered in this environment — not only when something is ambiguous. The grill output is folded into the issue body so the result is more thorough than the raw tagline would produce.

- **`/grill-with-docs` is preferred.** Use `/grill-me` only when `/grill-with-docs` is not registered.
- Discovery hint: look for a skill or command named `grill-with-docs` or `grill-me` (e.g. `~/.cursor/skills/grill-with-docs/`, `~/.cursor/skills/grill-me/`, `.cursor/skills/...`, `.agents/skills/...`).
- If neither is registered, proceed with the workflow on the input as given.

### Steps

1. Parse the tagline or short description. If missing, ask.
2. Resolve the issue template:
   - Prefer `.github/ISSUE_TEMPLATE/` (multiple templates); pick the one matching the issue type (bug, feature, chore, etc.).
   - Fall back to `.github/ISSUE_TEMPLATE/default.md` or `.github/ISSUE_TEMPLATE.md`.
   - If no template exists, use a minimal structure: Summary, Reproduction (bugs), Current vs Expected, Scope, Related.
3. Investigate before drafting:
   - Search code, docs, tests, and existing open/closed issues for duplicates and related work.
   - Read the implementation area the issue touches. Do not draft from the tagline alone.
   - If the tagline cannot become a concrete issue without guessing, stop and ask.
4. Draft the issue. A good issue typically includes:
   - A specific, plain-language title with no area prefix (use labels for area/type).
   - A short problem summary.
   - For bugs: reproduction command or minimal code/UI sample; current vs expected behavior.
   - Project context (spec, RFC, related issue) when relevant.
   - Test impact, user impact, or blocked work.
   - Likely fix area, scope notes, constraints, and related issues.
5. **If the change is UI/UX, also include:**
   - Affected screens, routes, or components.
   - Current visual state: screenshot, short recording, or precise description (layout, copy, state).
   - Expected visual state: screenshot, mock, design link (Figma, etc.), or precise description.
   - Accessibility expectations: keyboard navigation, focus order, visible focus, ARIA roles/labels, color contrast (target WCAG AA or the project's standard), motion / `prefers-reduced-motion`.
   - Responsive scope: which breakpoints and devices apply, and which themes (light/dark/system).
   - Design system or component library in use, and the specific tokens or components involved.
6. Choose labels by matching existing repo conventions. Use labels (not title prefixes) for area and type. Do not invent labels unless the user asks.
7. Show the title, labels, and body to the user before creating, unless the user asked to create without review.
8. Resolve the repository ID, then create the issue with GraphQL:

```bash
REPOSITORY_ID=$(gh api graphql \
  -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id}}' \
  -f owner="$OWNER" -f name="$REPO" --jq '.data.repository.id')

gh api graphql \
  -f query='mutation($repositoryId:ID!, $title:String!, $body:String!, $labelIds:[ID!]) {
    createIssue(input: {
      repositoryId: $repositoryId,
      title: $title,
      body: $body,
      labelIds: $labelIds
    }) {
      issue { url number }
    }
  }' \
  -F repositoryId="$REPOSITORY_ID" \
  -f title="$ISSUE_TITLE" \
  -f body="$ISSUE_BODY"
```

When labels were selected, append one `-F labelIds[]="$LABEL_ID"` argument per label ID.

1. If GraphQL is rate-limited or unavailable, fall back to REST:

```bash
gh api "repos/$OWNER/$REPO/issues" \
  -f title="$ISSUE_TITLE" \
  -f body="$ISSUE_BODY" \
  --jq '.html_url'
```

When labels were selected, append one `-f labels[]="$LABEL_NAME"` argument per label name.

1. Return the issue URL.
