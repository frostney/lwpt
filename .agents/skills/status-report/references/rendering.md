# Status board rendering

Use the richest presentation the current host can actually render:

1. a conversation-local rich card board;
2. Mermaid Kanban;
3. a compact Markdown board.

Never claim a richer surface rendered when it did not. Keep the underlying
classification and card content identical across fallbacks.

## Rich board

Use a responsive, theme-aware surface with three lanes per row at ordinary
desktop conversation width, two on narrow layouts, and one on mobile. Avoid
horizontal scrolling.

- Use neutral surfaces, system typography, restrained depth, and one slim
  semantic accent per status. Pair every color with a lane label and icon.
- Put repository identity and observation time in a quiet header.
- Give every lane a title and count, including empty lanes.
- Keep each card compact: PR or local identifier, one-sentence summary, status
  facts, branch, short current HEAD, and one next action.
- Link PR identifiers when the host supports safe links. Keep local paths
  secondary and concise.
- Support light and dark appearance, keyboard navigation, readable contrast,
  and reflow without clipping.
- Create any required rich fragment only in the host's conversation-local
  temporary artifact area. Never add it to the inspected repository.

## Mermaid fallback

Use Mermaid's native `kanban` syntax when supported. Prefer `theme: neo`,
`look: classic`, a system sans-serif font, approximately 210-pixel sections,
and restrained padding. Use unique safe identifiers and short labels; do not
embed detailed evidence in nodes.

Keep columns in this order:

`Local work` → `Draft` → `CI running` → `CI failed` → `Active review` → `Ready`

Follow the diagram with only the evidence gaps or next actions that could not
fit legibly on cards.

## Markdown fallback

Use a six-column table when it remains readable. On narrow or text-only hosts,
use six compact headed lane sections in the same order. Keep zero-count lanes
visible and preserve card ordering, links, status facts, and next actions.
