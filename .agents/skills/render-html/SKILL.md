---
name: render-html
description: >-
  Renders validated, self-contained interactive HTML reports from structured
  evidence. Use when a workflow needs an implementation option review,
  retrospective impact report, or another report that compares items, shows
  Before and After states, scores tradeoffs, or provides copyable discussion
  prompts.
license: Unlicense OR MIT
---

# Render HTML

Turn structured, evidence-backed report data into a readable local HTML artifact.
This skill owns generic validation, presentation, and interaction behavior. The
calling skill owns its domain requirements, artifact lifetime, and review flow.

## Requirements

- Require Python 3 and this skill's renderer. Stop when either is unavailable.
- Read [references/schema.md](references/schema.md) before creating or changing
  renderer input.
- Label evidence as `observed`, `proposed`, or `prototype`. Do not present a
  proposal or mockup as observed behavior.
- Keep the comparison neutral. Put an optional recommendation after every item.
- Use rubric weights totaling 100 and scores from 0 through 5. The renderer
  calculates weighted totals.
- Do not add unknown fields. Validation rejects them.

## Render and verify

1. Create a UTF-8 JSON input file that follows the schema.
2. Render it:

   ```bash
   python3 <render-html-skill-directory>/scripts/render_report.py \
     --input <report.json> \
     --output <report.html>
   ```

3. Open or render the HTML and verify headings, responsive layout, keyboard
   focus, state controls, tables, copy status, links, and diagrams when present.
4. Return the absolute artifact path to the calling skill.

The HTML is self-contained. Local state images are embedded as data URIs. If an
inline host preview is unavailable, provide the absolute path instead of
silently skipping review.
