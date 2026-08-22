# Structured report schema

Use one flexible report schema. Callers select the fields they need and enforce
their own domain-specific requirements. The renderer enforces types, safe URLs,
consistent rubric scoring, valid diagrams, and known fields.

## Top-level object

```json
{
  "title": "Implementation impact review",
  "subtitle": "Options, evidence, and tradeoffs",
  "summary": "Choose an approach before implementation begins.",
  "itemLabel": "Option",
  "evidence": [
    {
      "label": "Issue 44 reproduction",
      "finding": "The fallback reports success when execCommand returns false.",
      "classification": "observed",
      "url": "https://example.test/issue/44"
    }
  ],
  "rubric": [
    { "id": "correctness", "label": "Correctness", "weight": 60 },
    { "id": "scope", "label": "Scope control", "weight": 40 }
  ],
  "items": [
    {
      "id": "direct-fix",
      "title": "Honor the fallback return value",
      "impact": "Copy status reflects whether the browser accepted the fallback command.",
      "scores": { "correctness": 5, "scope": 5 }
    }
  ],
  "recommendation": {
    "itemId": "direct-fix",
    "rationale": "It fixes the observed failure with the smallest verified change."
  }
}
```

`title` and a non-empty `items` array are required. `subtitle`, `summary`,
`itemLabel`, `evidence`, `rubric`, and `recommendation` are optional.

Evidence entries require `label`, `finding`, and `classification`.
Classification is `observed`, `proposed`, or `prototype`. `url` is optional and
must use HTTP or HTTPS.

Rubric entries require a unique identifier, label, and positive numeric weight.
Weights must total 100. When a rubric exists, every item must score every
criterion from 0 through 5 with no additional criteria.

## Item object

```json
{
  "id": "direct-fix",
  "title": "Honor the fallback return value",
  "impact": "Copy status reflects whether the browser accepted the fallback command.",
  "before": {
    "kind": "code",
    "content": "document.execCommand('copy'); return true;",
    "language": "javascript",
    "caption": "Observed fallback behavior"
  },
  "after": {
    "kind": "code",
    "content": "return document.execCommand('copy') === true;",
    "language": "javascript",
    "caption": "Proposed behavior"
  },
  "pros": ["Matches the browser contract", "Keeps the change local"],
  "cons": ["The fallback API remains deprecated"],
  "scores": { "correctness": 5, "scope": 5 },
  "uncertainty": "Host clipboard restrictions still vary by browser.",
  "evidence": [
    {
      "label": "Browser reproduction",
      "finding": "Forced fallback failure now displays Copy failed.",
      "classification": "prototype"
    }
  ],
  "deepDive": "Review the fallback contract and regression test.",
  "discussionPrompt": "Choose the direct fix and continue implementation.",
  "deepDiveUrl": "codex:thread/example"
}
```

Each item requires `title` and an impact summary of at most 300 Unicode
characters. `id` is optional and otherwise generated. All other fields are
optional at the renderer level.

`before` and `after` states use `kind` values `text`, `code`, or `image`:

- Every state requires `content`; `caption` is optional.
- Code may include `language`.
- Images require `alt`. Their content may be an HTTP URL, data URI, or local
  path relative to the JSON input. Local images are embedded in the HTML.
- Text cannot include `language` or `alt`; code cannot include `alt`; images
  cannot include `language`.

`pros` and `cons` are non-empty string arrays when present. `uncertainty`,
`deepDive`, and `discussionPrompt` are optional strings. `deepDiveUrl` may use
HTTP, HTTPS, or a host-supplied `codex:` route. Never invent a host route.

## Diagram object

Use a diagram only for a pattern, lifecycle, state flow, or interaction with at
least three meaningful elements.

```json
{
  "title": "Fallback copy flow",
  "nodes": [
    { "id": "modern", "label": "Clipboard API" },
    { "id": "legacy", "label": "Legacy command" },
    { "id": "status", "label": "Visible status" }
  ],
  "edges": [
    { "id": "fallback", "from": "modern", "to": "legacy", "label": "unavailable" },
    { "id": "result", "from": "legacy", "to": "status" }
  ],
  "steps": [
    { "label": "Try modern copy", "highlights": ["modern"] },
    { "label": "Use fallback", "highlights": ["fallback", "legacy"] },
    { "label": "Report result", "highlights": ["result", "status"] }
  ]
}
```

Node and edge identifiers must be unique within the diagram. Edges reference
known nodes. Step highlights reference known node or edge identifiers.

## Presentation contract

- Shared evidence and rubric appear before the items.
- Items are presented in source order without a preferred visual treatment.
- The optional recommendation appears only after all items.
- State controls expose Before, After, and Both with pressed-state semantics.
- Tables use semantic headings and remain readable at narrow widths.
- Copy actions announce `Copying...`, `Copied`, or `Copy failed` in a live
  status region. A false or throwing legacy copy command is a failure.
- Diagram controls support play, pause, step, and reset.
