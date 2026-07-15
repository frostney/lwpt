---
name: roadmap-review
description: >-
  Review a project's roadmap from freshly-pulled data — assess current state and
  release cadence, measure delivery velocity from history, and verify candidate
  work against the source — then produce a parallelized, throughput-anchored
  version plan, and (optionally, on confirmation) create the milestones and
  issues. Use when the user wants to review the roadmap, plan upcoming
  versions/releases, decide when to cut the next release, or sequence a backlog
  into a realistic plan.
license: Unlicense OR MIT
compatibility: >-
  Requires the GitHub CLI (gh) authenticated to the target repository and
  network access. The gates are forge-agnostic but the default data pulls are
  GitHub/gh. A CI-published progress metric (conformance/coverage/benchmark) is
  used when present but is optional.
---

# Roadmap review

## Instructions

Review a project's roadmap and produce a grounded, parallelized, throughput-anchored plan. The skill's whole value is that **every claim is grounded in fresh data and verified against the source** — never memory, estimates, or stale knowledge. Analysis and planning are the core deliverable; creating milestones and issues is an optional, confirmation-gated final phase.

Work in six phases: **Ground → Assess → Measure velocity → Verify against source → Plan → (optional) Execute.** Verify runs *before* Plan on purpose — proposing work that already exists is the most common failure this skill prevents.

Defer the general engineering discipline (ground-in-reality, the After-Correction Rule, recommend-and-wait under uncertainty) to `software-engineering-excellence`; this skill encodes only the four roadmap-specific gates below.

### Non-negotiable gates (do not skip, do not rationalize)

#### GATE A — Ground every claim in fresh data

Every quantitative or status claim must come from data pulled *this session* — never from memory, training data, or a previous session's numbers; re-pull if a number is reused across a long session. If something genuinely cannot be measured, say so explicitly — never substitute an estimate for a measurement.

- **Mandatory sources** (exist on any active repo): open issues (by milestone and label), releases with dates, milestones, merged-PR history, and `VISION.md` / docs (see `project-structure` for where these live).
- **Best-effort source** (auto-detect; may be absent): a domain progress metric published to CI artifacts — conformance, coverage, or benchmark results. If absent, state that and proceed without it; never fabricate one.

Forbidden rationalizations:

- ❌ "I recall the last release was…" → pull `releases`.
- ❌ "the baseline is probably…" → fetch the artifact, or say it's unavailable.
- ❌ "velocity is roughly…" → measure it (GATE B).
- ❌ "the milestones are likely…" → list them. (Note: the forge's open-issue count often includes PRs — reconcile it.)

#### GATE B — Derive timelines from measured rates, applied literally

Never pad. An estimate is a measured rate applied to a counted backlog, with a stated basis and confidence.

- **Throughput**: the merged-PR rate over a **90-day** window.
- **Lead time**: **issue-created → PR-merged** where the PR links an issue (the fuller signal); fall back to **PR-opened → merged** only when no issue exists, and flag that as a likely **outlier that understates lead time** (un-tracked work skews small and quick).
- **Exclude triage**: issues opened and closed **without an implementation** (invalid / duplicate / wontfix / answered / already-fixed — no linked PR or code change) are not delivery. Exclude them from throughput and lead time, and factor the historical no-implementation close rate into backlog sizing.
- **Domain burndown**: when a domain metric exists, **measure its slope from spaced historical CI artifacts** (download the metric artifact from several past runs and diff the counts) — do not estimate the slope.
- **Allocation ≠ capacity**: per-label or per-area rates show where effort *went*, not the ceiling — a focused milestone can draw most of total throughput.

Forbidden rationalizations:

- ❌ "to be safe, call it 2–3 weeks" (padding past the measured rate).
- ❌ "velocity's probably lower than measured."
- ❌ "treat that label's N/week as the cap" (allocation, not capacity).

#### GATE C — Verify before you propose or characterize

Before proposing any feature or work item, classify it against the **current source** as **Done / Partial / Absent** with file:line evidence — propose only Absent or Partial. Before asserting any characterization (what a test category is, what "best practice" is, what a flag does), confirm it against the **primary source** — the code, the actual tests, the official spec/docs — not memory or inference. Fan this verification out to subagents when the surface is large.

Forbidden rationalizations:

- ❌ "this is an obvious gap" (un-grepped).
- ❌ "the vision implies X is missing."
- ❌ "that category is probably <out of scope / engine-specific>" → read the actual tests.
- ❌ "the standard tool for this is <stale default>" → check current reality, and separate distinct concerns rather than conflating them (e.g. a measurement library vs. a workload corpus).

#### GATE D — Never mutate the forge without confirmation

The Execute phase is opt-in. Never create or re-theme milestones, file issues, set due-dates, or relabel without explicit confirmation of the **finalized** plan. Every issue created meets `/create-issue` quality — delegate to it.

Forbidden rationalizations:

- ❌ "I'll create thin issues now and flesh them out later."
- ❌ "this clearly needs a milestone, I'll just make it."
- ❌ mutating the forge before the plan is confirmed.

### Defer to sibling skills

- **`software-engineering-excellence`** — the general engineering bar (ground-in-reality, After-Correction Rule, recommend-and-wait). Not duplicated here.
- **`/create-issue`** — all issue creation in the Execute phase (mechanics and body quality).
- **`/create-release`** — this skill *recommends whether and when to cut the next release* but never cuts it; hand off to `/create-release`.
- **`project-structure`** — locating `VISION.md` / docs and the milestone & changelog conventions.
- **`git-workflow`** — any branch/PR mechanics during execution.

### Steps

1. **Ground** (GATE A). Pull repo metadata, open issues by milestone and label, releases with dates, milestones, and merged-PR history. Read `VISION.md` / docs for scope (in/out), the quality/conformance objective, and architectural boundaries. Auto-detect a domain progress metric and its CI artifacts. Reconcile the open-issue count against the forge's number (it may include PRs).

2. **Assess current state.** Time since the last release and the historical cadence; the volume of merged-but-unreleased work; **milestone-on-paper vs. work-in-commits drift** (what is actually being worked vs. what the milestones claim); the stated scope and non-goals. Produce a **release-cadence recommendation**: "N days since the last release with M unreleased commits → cut now / wait," plus a suggested cadence.

3. **Measure velocity** (GATE B). Throughput over 90 days; lead time (issue→merge, with the PR→merge fallback caveat and triage exclusion); the domain slope from historical artifacts; and the allocation-vs-capacity read. Attach a basis and confidence to every number.

4. **Verify against source** (GATE C). For every candidate feature or characterization, check the actual code/tests/spec; classify Done / Partial / Absent with evidence; drop anything already shipped. Fan out to subagents for breadth.

5. **Plan.** Produce the report (see Output). Group the verified work into **independent tracks that can progress in parallel**, using the project's own architectural seams as the axis (e.g. an engine/runtime split). Size each epic from counted work, sequence into **themed releases**, and anchor each release to the measured rates. Call out cross-track dependencies and the longest pole. Surface the **decisions that are genuinely the human's** (scope cuts, policy forks) with a recommendation each — then stop for those decisions; do not pre-decide them.

6. **Execute (optional, GATE D).** Only after the plan is confirmed and the human opts in. Ask whether the project uses **milestones**: if yes, default to **milestone → track parent issue → sub-issues**, with due-dates from the timeline; if not (smaller projects), use **track parent issues + labels** and no milestones. Create every issue through `/create-issue`. Report exactly what was created.

### Output

Default to an **in-chat markdown report**; offer to also write it to **`ROADMAP-YYMMDD.md`** (date-stamped with the run date, e.g. `ROADMAP-260626.md`) when the user wants a file. Required sections:

1. **Current state & drift** — cadence, unreleased work, milestone-vs-reality drift, scope, and the release-cadence recommendation.
2. **Measured velocity** — throughput, lead time, and the domain slope; each with its basis and confidence.
3. **Versioned plan** — themed releases, each a sized backlog grouped into independent parallel tracks, with cross-track dependencies marked.
4. **Throughput-anchored timeline** — per-release estimate and confidence, longest pole identified, rendered as a **mermaid `gantt`** diagram (portable; best-effort — omit only if mermaid is unavailable).
5. **Open decisions for the human** — each with a recommendation.

### Notes

- **No CI metric:** skip the domain-slope step, state it is unavailable, and size domain work from issue counts + lead time instead — flagged as lower-confidence.
- **New repo (few issues/releases):** fall back to commit history for cadence and throughput, and say the signal is thin.
- **Adapt the data pulls to the forge** — the defaults are GitHub/`gh`; the gates are forge-agnostic.
- **A report is a snapshot** of the data at run time; re-pull before acting on an old one.
