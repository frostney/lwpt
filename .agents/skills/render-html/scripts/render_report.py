#!/usr/bin/env python3
"""Render a validated, self-contained HTML report from structured JSON."""

from __future__ import annotations

import argparse
import base64
import html
import json
import math
import mimetypes
import re
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
CLASSIFICATIONS = {"observed", "proposed", "prototype"}


def _reject_unknown(value: dict[str, Any], allowed: set[str], field: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ValueError(f"{field} contains unknown field {unknown[0]}")


def _required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def _optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    return value.strip() or None


def _identifier(value: Any, field: str) -> str:
    identifier = _required_text(value, field)
    if not IDENTIFIER.fullmatch(identifier):
        raise ValueError(
            f"{field} must start with a letter and use letters, numbers, _ or -"
        )
    return identifier


def _optional_text_list(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not value:
        raise ValueError(f"{field} must contain at least one item")
    return [
        _required_text(item, f"{field}[{index}]")
        for index, item in enumerate(value)
    ]


def _validated_url(value: Any, field: str, schemes: set[str]) -> str | None:
    url = _optional_text(value, field)
    if url is None:
        return None
    parsed = urlparse(url)
    if parsed.scheme not in schemes:
        allowed = ", ".join(sorted(schemes))
        raise ValueError(f"{field} must use {allowed}")
    return url


def _image_source(source: str, input_directory: Path) -> str:
    if source.startswith(("data:", "https://", "http://")):
        return source

    image_path = Path(source).expanduser()
    if not image_path.is_absolute():
        image_path = input_directory / image_path
    if not image_path.is_file():
        raise ValueError(f"image does not exist: {source}")

    mime_type = mimetypes.guess_type(image_path.name)[0] or "application/octet-stream"
    payload = base64.b64encode(image_path.read_bytes()).decode("ascii")
    return f"data:{mime_type};base64,{payload}"


def _render_state(state: Any, field: str, input_directory: Path) -> str:
    if not isinstance(state, dict):
        raise ValueError(f"{field} must be an object")
    _reject_unknown(
        state, {"kind", "content", "caption", "language", "alt"}, field
    )

    kind = _required_text(state.get("kind"), f"{field}.kind")
    content = _required_text(state.get("content"), f"{field}.content")
    caption = _optional_text(state.get("caption"), f"{field}.caption")

    if kind == "text":
        if state.get("language") is not None or state.get("alt") is not None:
            raise ValueError(f"{field} text state cannot define language or alt")
        body = f"<p>{html.escape(content)}</p>"
    elif kind == "code":
        if state.get("alt") is not None:
            raise ValueError(f"{field} code state cannot define alt")
        language = _optional_text(state.get("language"), f"{field}.language") or "text"
        body = (
            f'<pre><code class="language-{html.escape(language, quote=True)}">'
            f"{html.escape(content)}</code></pre>"
        )
    elif kind == "image":
        if state.get("language") is not None:
            raise ValueError(f"{field} image state cannot define language")
        alt = _required_text(state.get("alt"), f"{field}.alt")
        source = _image_source(content, input_directory)
        body = (
            f'<img src="{html.escape(source, quote=True)}" '
            f'alt="{html.escape(alt, quote=True)}">'
        )
    else:
        raise ValueError(f"{field}.kind must be text, code, or image")

    if caption:
        body += f'<p class="caption">{html.escape(caption)}</p>'
    return body


def _render_evidence(
    entries: Any, field: str, heading: str, heading_level: int = 3
) -> str:
    if entries is None:
        return ""
    if not isinstance(entries, list) or not entries:
        raise ValueError(f"{field} must contain at least one item")

    rendered: list[str] = []
    for index, entry in enumerate(entries):
        entry_field = f"{field}[{index}]"
        if not isinstance(entry, dict):
            raise ValueError(f"{entry_field} must be an object")
        _reject_unknown(
            entry, {"label", "finding", "classification", "url"}, entry_field
        )
        label = _required_text(entry.get("label"), f"{entry_field}.label")
        finding = _required_text(entry.get("finding"), f"{entry_field}.finding")
        classification = _required_text(
            entry.get("classification"), f"{entry_field}.classification"
        )
        if classification not in CLASSIFICATIONS:
            raise ValueError(
                f"{entry_field}.classification must be observed, proposed, or prototype"
            )
        url = _validated_url(
            entry.get("url"), f"{entry_field}.url", {"http", "https"}
        )
        label_html = html.escape(label)
        if url:
            label_html = (
                f'<a href="{html.escape(url, quote=True)}">{label_html}</a>'
            )
        rendered.append(
            '<li class="evidence-item">'
            f'<div><span class="classification classification-{classification}">'
            f"{html.escape(classification.title())}</span>{label_html}</div>"
            f"<p>{html.escape(finding)}</p></li>"
        )
    heading_tag = f"h{heading_level}"
    return (
        f'<section class="evidence"><{heading_tag}>{html.escape(heading)}'
        f'</{heading_tag}><ul>{"".join(rendered)}</ul></section>'
    )


def _normalize_rubric(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list) or not value:
        raise ValueError("rubric must contain at least one criterion")

    criteria: list[dict[str, Any]] = []
    criterion_ids: set[str] = set()
    total_weight = 0.0
    for index, criterion in enumerate(value):
        field = f"rubric[{index}]"
        if not isinstance(criterion, dict):
            raise ValueError(f"{field} must be an object")
        _reject_unknown(criterion, {"id", "label", "weight"}, field)
        criterion_id = _identifier(criterion.get("id"), f"{field}.id")
        if criterion_id in criterion_ids:
            raise ValueError(f"rubric contains duplicate id {criterion_id}")
        criterion_ids.add(criterion_id)
        label = _required_text(criterion.get("label"), f"{field}.label")
        weight = criterion.get("weight")
        if isinstance(weight, bool) or not isinstance(weight, (int, float)):
            raise ValueError(f"{field}.weight must be a positive number")
        weight = float(weight)
        if not math.isfinite(weight) or weight <= 0:
            raise ValueError(f"{field}.weight must be a positive number")
        total_weight += weight
        criteria.append({"id": criterion_id, "label": label, "weight": weight})

    if not math.isclose(total_weight, 100.0, abs_tol=1e-9):
        raise ValueError(f"rubric weights must total 100 (received {total_weight:g})")
    return criteria


def _render_rubric(criteria: list[dict[str, Any]]) -> str:
    if not criteria:
        return ""
    rows = "".join(
        f'<tr><th scope="row">{html.escape(criterion["label"])}</th>'
        f'<td>{criterion["weight"]:g}%</td></tr>'
        for criterion in criteria
    )
    return f"""
      <section class="shared-section" aria-labelledby="__report-rubric-heading">
        <h2 id="__report-rubric-heading">Comparison rubric</h2>
        <div class="table-wrap"><table><caption class="sr-only">Comparison criteria and weights</caption>
          <thead><tr><th scope="col">Criterion</th><th scope="col">Weight</th></tr></thead>
          <tbody>{rows}</tbody>
        </table></div>
      </section>"""


def _render_scores(value: Any, field: str, criteria: list[dict[str, Any]]) -> str:
    if not criteria:
        if value is not None:
            raise ValueError(f"{field} requires a top-level rubric")
        return ""
    if not isinstance(value, dict):
        raise ValueError(f"{field} must provide every rubric criterion")

    expected = {criterion["id"] for criterion in criteria}
    actual = set(value)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    if missing:
        raise ValueError(f"{field} is missing criterion {missing[0]}")
    if unknown:
        raise ValueError(f"{field} contains unknown criterion {unknown[0]}")

    rows: list[str] = []
    total = 0.0
    for criterion in criteria:
        score = value[criterion["id"]]
        if isinstance(score, bool) or not isinstance(score, (int, float)):
            raise ValueError(
                f'{field}.{criterion["id"]} must be a number from 0 to 5'
            )
        score = float(score)
        if not math.isfinite(score) or score < 0 or score > 5:
            raise ValueError(
                f'{field}.{criterion["id"]} must be a number from 0 to 5'
            )
        contribution = score / 5 * criterion["weight"]
        total += contribution
        rows.append(
            f'<tr><th scope="row">{html.escape(criterion["label"])}</th>'
            f'<td>{score:g}/5</td><td>{contribution:.1f}</td></tr>'
        )
    rows.append(
        '<tr class="score-total"><th scope="row">Weighted total</th><td></td>'
        f"<td>{total:.1f}/100</td></tr>"
    )
    return f"""
        <section class="scores"><h3>Scores</h3>
          <div class="table-wrap"><table><caption class="sr-only">Criterion scores and weighted total</caption>
            <thead><tr><th scope="col">Criterion</th><th scope="col">Score</th><th scope="col">Weighted</th></tr></thead>
            <tbody>{''.join(rows)}</tbody>
          </table></div>
        </section>"""


def _render_diagram(diagram: Any, field: str, diagram_index: int) -> str:
    if diagram is None:
        return ""
    if not isinstance(diagram, dict):
        raise ValueError(f"{field} must be an object")
    _reject_unknown(diagram, {"title", "nodes", "edges", "steps"}, field)

    title = _required_text(diagram.get("title"), f"{field}.title")
    nodes = diagram.get("nodes")
    edges = diagram.get("edges")
    steps = diagram.get("steps")
    if not isinstance(nodes, list) or len(nodes) < 3:
        raise ValueError(f"{field}.nodes must contain at least three items")
    if not isinstance(edges, list):
        raise ValueError(f"{field}.edges must be an array")
    if not isinstance(steps, list) or not steps:
        raise ValueError(f"{field}.steps must contain at least one item")

    node_ids: set[str] = set()
    rendered_nodes: list[str] = []
    positions: dict[str, tuple[int, int]] = {}
    columns = min(3, len(nodes))
    rows = (len(nodes) + columns - 1) // columns
    height = 90 + rows * 120
    for node_index, node in enumerate(nodes):
        node_field = f"{field}.nodes[{node_index}]"
        if not isinstance(node, dict):
            raise ValueError(f"{node_field} must be an object")
        _reject_unknown(node, {"id", "label"}, node_field)
        node_id = _identifier(node.get("id"), f"{node_field}.id")
        label = _required_text(node.get("label"), f"{node_field}.label")
        if node_id in node_ids:
            raise ValueError(f"{field}.nodes contains duplicate id {node_id}")
        node_ids.add(node_id)
        column = node_index % columns
        row = node_index // columns
        x = int((column + 0.5) * (720 / columns))
        y = 75 + row * 120
        positions[node_id] = (x, y)
        rendered_nodes.append(
            f'<g class="diagram-node" data-element-id="{html.escape(node_id, quote=True)}">'
            f'<rect x="{x - 88}" y="{y - 28}" width="176" height="56" rx="12" />'
            f'<text x="{x}" y="{y + 5}">{html.escape(label)}</text></g>'
        )

    element_ids = set(node_ids)
    rendered_edges: list[str] = []
    marker_id = f"__report-arrow-{diagram_index}"
    for edge_index, edge in enumerate(edges):
        edge_field = f"{field}.edges[{edge_index}]"
        if not isinstance(edge, dict):
            raise ValueError(f"{edge_field} must be an object")
        _reject_unknown(edge, {"id", "from", "to", "label"}, edge_field)
        edge_id = _identifier(edge.get("id"), f"{edge_field}.id")
        source = _identifier(edge.get("from"), f"{edge_field}.from")
        target = _identifier(edge.get("to"), f"{edge_field}.to")
        label = _optional_text(edge.get("label"), f"{edge_field}.label")
        if edge_id in element_ids:
            raise ValueError(f"{field}.edges contains duplicate id {edge_id}")
        if source not in positions or target not in positions:
            raise ValueError(f"{edge_field} references an unknown node")
        element_ids.add(edge_id)
        x1, y1 = positions[source]
        x2, y2 = positions[target]
        label_svg = ""
        if label:
            label_svg = (
                f'<text x="{(x1 + x2) // 2}" y="{(y1 + y2) // 2 - 8}">'
                f"{html.escape(label)}</text>"
            )
        rendered_edges.append(
            f'<g class="diagram-edge" data-element-id="{html.escape(edge_id, quote=True)}">'
            f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" '
            f'marker-end="url(#{marker_id})" />{label_svg}</g>'
        )

    normalized_steps: list[dict[str, Any]] = []
    for step_index, step in enumerate(steps):
        step_field = f"{field}.steps[{step_index}]"
        if not isinstance(step, dict):
            raise ValueError(f"{step_field} must be an object")
        _reject_unknown(step, {"label", "highlights"}, step_field)
        label = _required_text(step.get("label"), f"{step_field}.label")
        highlights = step.get("highlights")
        if not isinstance(highlights, list) or not highlights:
            raise ValueError(
                f"{step_field}.highlights must contain at least one id"
            )
        if not all(
            isinstance(item, str) and item in element_ids for item in highlights
        ):
            raise ValueError(f"{step_field} references an unknown id")
        normalized_steps.append({"label": label, "highlights": highlights})

    step_data = html.escape(json.dumps(normalized_steps), quote=True)
    return f"""
        <section class="mechanism-diagram" data-diagram data-steps="{step_data}">
          <h3>{html.escape(title)}</h3>
          <svg viewBox="0 0 720 {height}" role="img" aria-label="{html.escape(title, quote=True)}">
            <defs><marker id="{marker_id}" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto"><polygon points="0 0, 10 3.5, 0 7" /></marker></defs>
            {''.join(rendered_edges)}
            {''.join(rendered_nodes)}
          </svg>
          <div class="diagram-controls" aria-label="Diagram playback controls">
            <button type="button" data-diagram-action="play">Play</button>
            <button type="button" data-diagram-action="pause">Pause</button>
            <button type="button" data-diagram-action="step">Step</button>
            <button type="button" data-diagram-action="reset">Reset</button>
            <span data-diagram-status role="status">Ready</span>
          </div>
        </section>"""


def _render_tradeoffs(pros: list[str], cons: list[str]) -> str:
    if not pros and not cons:
        return ""
    sections: list[str] = []
    if pros:
        sections.append(
            '<section class="tradeoff tradeoff-pros"><h3>Pros</h3><ul>'
            + "".join(f"<li>{html.escape(item)}</li>" for item in pros)
            + "</ul></section>"
        )
    if cons:
        sections.append(
            '<section class="tradeoff tradeoff-cons"><h3>Cons</h3><ul>'
            + "".join(f"<li>{html.escape(item)}</li>" for item in cons)
            + "</ul></section>"
        )
    return f'<div class="tradeoffs">{"".join(sections)}</div>'


def _render_recommendation(value: Any, item_titles: dict[str, str]) -> str:
    if value is None:
        return ""
    if not isinstance(value, dict):
        raise ValueError("recommendation must be an object")
    _reject_unknown(value, {"itemId", "rationale"}, "recommendation")
    item_id = _identifier(value.get("itemId"), "recommendation.itemId")
    if item_id not in item_titles:
        raise ValueError("recommendation.itemId must reference an item id")
    rationale = _required_text(value.get("rationale"), "recommendation.rationale")
    return f"""
      <section class="recommendation" aria-labelledby="__report-recommendation-heading">
        <div class="recommendation-label">Recommendation</div>
        <h2 id="__report-recommendation-heading">{html.escape(item_titles[item_id])}</h2>
        <p>{html.escape(rationale)}</p>
      </section>"""


def render_report(data: Any, input_directory: Path) -> str:
    if not isinstance(data, dict):
        raise ValueError("report must be an object")
    _reject_unknown(
        data,
        {
            "title",
            "subtitle",
            "summary",
            "itemLabel",
            "evidence",
            "rubric",
            "items",
            "recommendation",
        },
        "report",
    )

    title = _required_text(data.get("title"), "title")
    subtitle = _optional_text(data.get("subtitle"), "subtitle")
    summary = _optional_text(data.get("summary"), "summary")
    item_label = _optional_text(data.get("itemLabel"), "itemLabel") or "Item"
    items = data.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("items must contain at least one item")

    criteria = _normalize_rubric(data.get("rubric"))
    shared_evidence = _render_evidence(
        data.get("evidence"), "evidence", "Shared evidence", heading_level=2
    )
    cards: list[str] = []
    item_titles: dict[str, str] = {}
    for index, item in enumerate(items, start=1):
        field = f"items[{index - 1}]"
        if not isinstance(item, dict):
            raise ValueError(f"{field} must be an object")
        _reject_unknown(
            item,
            {
                "id",
                "title",
                "impact",
                "before",
                "after",
                "pros",
                "cons",
                "scores",
                "uncertainty",
                "evidence",
                "deepDive",
                "discussionPrompt",
                "deepDiveUrl",
                "diagram",
            },
            field,
        )
        item_id = (
            _identifier(item.get("id"), f"{field}.id")
            if item.get("id") is not None
            else f"item-{index}"
        )
        if item_id in item_titles:
            raise ValueError(f"items contains duplicate id {item_id}")
        item_title = _required_text(item.get("title"), f"{field}.title")
        item_titles[item_id] = item_title
        impact = _required_text(item.get("impact"), f"{field}.impact")
        if len(impact) > 300:
            raise ValueError(
                f"{field}.impact exceeds 300 characters ({len(impact)})"
            )

        before_html = (
            _render_state(item.get("before"), f"{field}.before", input_directory)
            if item.get("before") is not None
            else ""
        )
        after_html = (
            _render_state(item.get("after"), f"{field}.after", input_directory)
            if item.get("after") is not None
            else ""
        )
        states_html = ""
        if before_html or after_html:
            state_id = f"__report-states-{index}"
            controls = ""
            if before_html and after_html:
                controls = f"""
        <div class="state-controls" aria-label="Before and After view">
          <button type="button" data-state-view="before" aria-controls="{state_id}" aria-pressed="false">Before</button>
          <button type="button" data-state-view="after" aria-controls="{state_id}" aria-pressed="false">After</button>
          <button type="button" data-state-view="both" aria-controls="{state_id}" aria-pressed="true">Both</button>
        </div>"""
            sections = ""
            if before_html:
                sections += (
                    f'<section data-state="before"><h3>Before</h3>{before_html}</section>'
                )
            if after_html:
                sections += (
                    f'<section data-state="after"><h3>After</h3>{after_html}</section>'
                )
            states_html = (
                f'{controls}<div class="states" id="{state_id}" data-states>'
                f"{sections}</div>"
            )

        pros = _optional_text_list(item.get("pros"), f"{field}.pros")
        cons = _optional_text_list(item.get("cons"), f"{field}.cons")
        tradeoffs = _render_tradeoffs(pros, cons)
        scores = _render_scores(item.get("scores"), f"{field}.scores", criteria)
        uncertainty = _optional_text(
            item.get("uncertainty"), f"{field}.uncertainty"
        )
        uncertainty_html = (
            '<section class="uncertainty"><h3>Remaining uncertainty</h3>'
            f"<p>{html.escape(uncertainty)}</p></section>"
            if uncertainty
            else ""
        )
        item_evidence = _render_evidence(
            item.get("evidence"), f"{field}.evidence", "Evidence"
        )
        diagram = _render_diagram(
            item.get("diagram"), f"{field}.diagram", index
        )

        deep_dive = _optional_text(item.get("deepDive"), f"{field}.deepDive")
        discussion_prompt = _optional_text(
            item.get("discussionPrompt"), f"{field}.discussionPrompt"
        )
        deep_dive_url = _validated_url(
            item.get("deepDiveUrl"),
            f"{field}.deepDiveUrl",
            {"codex", "http", "https"},
        )
        details_html = ""
        if deep_dive or discussion_prompt or deep_dive_url:
            details_body = (
                f"<p>{html.escape(deep_dive)}</p>" if deep_dive else ""
            )
            prompt_html = (
                '<p class="prompt"><strong>Continue with the user:</strong> '
                f"{html.escape(discussion_prompt)}</p>"
                if discussion_prompt
                else ""
            )
            actions: list[str] = []
            if deep_dive_url:
                actions.append(
                    f'<a class="button-link" href="{html.escape(deep_dive_url, quote=True)}">'
                    "Open deep-dive chat</a>"
                )
            if discussion_prompt:
                actions.append(
                    f'<button type="button" data-copy-prompt="{html.escape(discussion_prompt, quote=True)}">'
                    "Copy discussion prompt</button>"
                )
                actions.append('<span data-copy-status role="status"></span>')
            actions_html = (
                f'<div class="deep-actions">{"".join(actions)}</div>'
                if actions
                else ""
            )
            details_html = (
                f"<details><summary>Deep dive</summary>{details_body}{prompt_html}"
                f"{actions_html}</details>"
            )

        heading_id = f"__report-item-heading-{index}"
        cards.append(
            f"""
      <article class="report-card" id="{html.escape(item_id, quote=True)}" aria-labelledby="{heading_id}">
        <div class="item-number">{html.escape(item_label)} {index}</div>
        <h2 id="{heading_id}">{html.escape(item_title)}</h2>
        <p class="impact">{html.escape(impact)}</p>
        {states_html}
        {tradeoffs}
        {scores}
        {uncertainty_html}
        {item_evidence}
        {diagram}
        {details_html}
      </article>"""
        )

    recommendation = _render_recommendation(data.get("recommendation"), item_titles)
    subtitle_html = (
        f'<p class="subtitle">{html.escape(subtitle)}</p>' if subtitle else ""
    )
    summary_html = (
        f'<p class="summary">{html.escape(summary)}</p>' if summary else ""
    )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{
      color-scheme: light dark;
      font-family: Inter, ui-sans-serif, system-ui, sans-serif;
      --page: #f3f4f6;
      --surface: #ffffff;
      --surface-muted: #f7f8fb;
      --text: #172033;
      --muted: #526078;
      --border: #d9deea;
      --accent: #3659d9;
      --accent-soft: #eef2ff;
      --accent-text: #263b8f;
      --success: #17613a;
      --success-soft: #e7f6ec;
      --warning: #7a4b00;
      --warning-soft: #fff4d6;
      --prototype: #6b3ca0;
      --prototype-soft: #f3eafa;
      --code: #172033;
      --code-text: #f7f8fb;
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: var(--page); color: var(--text); line-height: 1.5; }}
    main {{ width: min(1120px, calc(100% - 32px)); margin: 48px auto; }}
    header {{ margin-bottom: 28px; }}
    h1 {{ margin: 0; font-size: clamp(2rem, 5vw, 4rem); letter-spacing: -0.04em; line-height: 1.05; }}
    h2, h3 {{ line-height: 1.25; }}
    .subtitle, .summary, .caption {{ color: var(--muted); }}
    .subtitle {{ font-size: 1.1rem; }}
    .summary {{ max-width: 76ch; }}
    .shared-section, .evidence, .recommendation, .report-card {{
      background: var(--surface); border: 1px solid var(--border); border-radius: 18px;
      box-shadow: 0 12px 36px rgb(41 53 78 / 10%); margin: 24px 0; padding: 28px;
    }}
    .report-card > .evidence {{ background: var(--surface-muted); box-shadow: none; padding: 18px; }}
    .report-card > h2, .recommendation h2 {{ margin: 8px 0; }}
    .item-number, .recommendation-label {{ color: var(--accent); font-size: .78rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }}
    .impact {{ max-width: 76ch; font-size: 1.08rem; }}
    button, .button-link {{
      align-items: center; background: var(--accent-soft); border: 1px solid #c7d2fe; border-radius: 8px;
      color: var(--accent-text); cursor: pointer; display: inline-flex; font: inherit; min-height: 44px;
      padding: 8px 12px; text-decoration: none;
    }}
    button:hover, .button-link:hover {{ filter: brightness(.97); }}
    button:focus-visible, .button-link:focus-visible, summary:focus-visible {{ outline: 3px solid var(--accent); outline-offset: 3px; }}
    button[aria-pressed="true"] {{ background: var(--accent); color: white; }}
    .state-controls, .deep-actions, .diagram-controls {{ align-items: center; display: flex; flex-wrap: wrap; gap: 8px; }}
    .states, .tradeoffs {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; margin: 16px 0 24px; }}
    .states section, .tradeoff, .scores, .uncertainty {{ background: var(--surface-muted); border-radius: 12px; min-width: 0; padding: 18px; }}
    .states h3, .tradeoff h3, .scores h3, .uncertainty h3, .evidence h2, .evidence h3 {{ margin-top: 0; }}
    pre {{ overflow: auto; background: var(--code); color: var(--code-text); border-radius: 9px; padding: 14px; }}
    img {{ display: block; max-width: 100%; border-radius: 9px; }}
    .caption {{ font-size: .86rem; }}
    .tradeoff ul, .evidence ul {{ margin-bottom: 0; padding-left: 1.25rem; }}
    .tradeoff li + li, .evidence-item + .evidence-item {{ margin-top: 8px; }}
    .tradeoff-pros {{ border-top: 4px solid var(--success); }}
    .tradeoff-cons {{ border-top: 4px solid var(--warning); }}
    .uncertainty {{ margin: 18px 0; border-left: 4px solid var(--warning); }}
    .evidence ul {{ list-style: none; padding: 0; }}
    .evidence-item {{ border-top: 1px solid var(--border); padding-top: 14px; }}
    .evidence-item:first-child {{ border-top: 0; padding-top: 0; }}
    .evidence-item p {{ margin-bottom: 0; }}
    .classification {{ border-radius: 999px; display: inline-block; font-size: .75rem; font-weight: 750; margin-right: 8px; padding: 3px 8px; }}
    .classification-observed {{ background: var(--success-soft); color: var(--success); }}
    .classification-proposed {{ background: var(--accent-soft); color: var(--accent-text); }}
    .classification-prototype {{ background: var(--prototype-soft); color: var(--prototype); }}
    .table-wrap {{ max-width: 100%; }}
    table {{ border-collapse: collapse; table-layout: fixed; width: 100%; }}
    th, td {{ border-bottom: 1px solid var(--border); overflow-wrap: anywhere; padding: 10px; text-align: left; vertical-align: top; }}
    th:first-child {{ width: 58%; }}
    .score-total th, .score-total td {{ border-top: 2px solid var(--text); font-weight: 800; }}
    details {{ border-top: 1px solid var(--border); margin-top: 20px; padding-top: 18px; }}
    summary {{ cursor: pointer; font-weight: 750; padding: 8px 0; }}
    .prompt {{ background: var(--accent-soft); border-radius: 9px; padding: 12px; }}
    .mechanism-diagram {{ margin: 24px 0; }}
    .mechanism-diagram svg {{ background: var(--surface-muted); border-radius: 12px; width: 100%; }}
    .diagram-node rect {{ fill: var(--surface); stroke: #7c8bb1; stroke-width: 2; transition: fill .2s, stroke .2s; }}
    .diagram-node text, .diagram-edge text {{ fill: currentColor; font-size: 14px; text-anchor: middle; }}
    .diagram-edge line {{ stroke: #7c8bb1; stroke-width: 2; }}
    .diagram-edge polygon {{ fill: #7c8bb1; }}
    .diagram-node.is-active rect {{ fill: #dbe4ff; stroke: var(--accent); stroke-width: 4; }}
    .diagram-edge.is-active line {{ stroke: var(--accent); stroke-width: 5; }}
    .diagram-controls {{ margin-top: 10px; }}
    .recommendation {{ border-top: 6px solid var(--accent); }}
    .sr-only {{ clip: rect(0, 0, 0, 0); clip-path: inset(50%); height: 1px; overflow: hidden; position: absolute; white-space: nowrap; width: 1px; }}
    [hidden] {{ display: none !important; }}
    @media (max-width: 720px) {{
      main {{ margin-top: 28px; }}
      .states, .tradeoffs {{ grid-template-columns: 1fr; }}
      .shared-section, .evidence, .recommendation, .report-card {{ padding: 20px; }}
      th, td {{ padding: 8px 5px; }}
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --page: #0d1320; --surface: #151d2d; --surface-muted: #101827; --text: #eef2ff;
        --muted: #aab6cf; --border: #2c3850; --accent: #8ea6ff; --accent-soft: #202c4b;
        --accent-text: #dbe4ff; --success: #8cd9a8; --success-soft: #173c2a;
        --warning: #f2c66d; --warning-soft: #453716; --prototype: #d8a9ff;
        --prototype-soft: #3a2850; --code: #080d17; --code-text: #f7f8fb;
      }}
      button, .button-link {{ border-color: #43537a; }}
      button[aria-pressed="true"] {{ color: #101827; }}
      .diagram-node.is-active rect {{ fill: #263b8f; }}
    }}
    @media (prefers-reduced-motion: reduce) {{ * {{ scroll-behavior: auto !important; transition: none !important; }} }}
  </style>
</head>
<body>
  <main>
    <header><h1>{html.escape(title)}</h1>{subtitle_html}{summary_html}</header>
    {shared_evidence}
    {_render_rubric(criteria)}
    {''.join(cards)}
    {recommendation}
  </main>
  <script>
    document.querySelectorAll('.report-card').forEach((card) => {{
      card.querySelectorAll('[data-state-view]').forEach((button) => {{
        button.addEventListener('click', () => {{
          const view = button.dataset.stateView;
          card.querySelectorAll('[data-state-view]').forEach((candidate) => {{
            candidate.setAttribute('aria-pressed', String(candidate === button));
          }});
          card.querySelectorAll('[data-state]').forEach((state) => {{
            state.hidden = view !== 'both' && state.dataset.state !== view;
          }});
        }});
      }});
    }});

    const copyPromptText = async (prompt) => {{
      try {{
        if (!navigator.clipboard) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(prompt);
        return true;
      }} catch (_) {{
        let area = null;
        try {{
          area = document.createElement('textarea');
          area.value = prompt;
          area.style.position = 'fixed';
          area.style.opacity = '0';
          area.setAttribute('aria-hidden', 'true');
          document.body.appendChild(area);
          area.select();
          return document.execCommand('copy') === true;
        }} catch (_) {{
          return false;
        }} finally {{
          if (area) area.remove();
        }}
      }}
    }};

    document.querySelectorAll('[data-copy-prompt]').forEach((copy) => {{
      copy.addEventListener('click', async () => {{
        const status = copy.parentElement.querySelector('[data-copy-status]');
        status.textContent = 'Copying…';
        const copied = await copyPromptText(copy.dataset.copyPrompt);
        status.textContent = copied ? 'Copied' : 'Copy failed';
      }});
    }});

    document.querySelectorAll('[data-diagram]').forEach((diagram) => {{
      const steps = JSON.parse(diagram.dataset.steps);
      const status = diagram.querySelector('[data-diagram-status]');
      let current = -1;
      let timer = null;
      const show = (index) => {{
        current = index;
        const step = current >= 0 ? steps[current] : null;
        diagram.querySelectorAll('[data-element-id]').forEach((element) => {{
          element.classList.toggle('is-active', Boolean(step && step.highlights.includes(element.dataset.elementId)));
        }});
        status.textContent = step ? `${{current + 1}}/${{steps.length}}: ${{step.label}}` : 'Ready';
      }};
      const pause = () => {{ if (timer) clearInterval(timer); timer = null; }};
      diagram.querySelector('[data-diagram-action="play"]').addEventListener('click', () => {{
        pause();
        show((current + 1) % steps.length);
        timer = setInterval(() => show((current + 1) % steps.length), 1200);
      }});
      diagram.querySelector('[data-diagram-action="pause"]').addEventListener('click', pause);
      diagram.querySelector('[data-diagram-action="step"]').addEventListener('click', () => {{ pause(); show((current + 1) % steps.length); }});
      diagram.querySelector('[data-diagram-action="reset"]').addEventListener('click', () => {{ pause(); show(-1); }});
    }});
  </script>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    input_path = arguments.input.resolve()
    data = json.loads(input_path.read_text(encoding="utf-8"))
    rendered = render_report(data, input_path.parent)
    output_path = arguments.output.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8")
    print(output_path)


if __name__ == "__main__":
    main()
