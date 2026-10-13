# Codebase health

## Executive Summary

- `lwpt health` deterministically reports Pascal cyclomatic and cognitive
  complexity; configured maxima turn the report into a gate.
- `--hotspots` optionally combines raw complexity with rename-aware changed
  lines from the latest 100 local Git commits and remains offline.
- `--json` uses the shared versioned analysis envelope and a health-owned,
  fixed-order payload.

`lwpt health` is an offline Object Pascal complexity report. It analyzes the
root project and discovered workspace packages through the shared
[`[analysis]` scope](./architecture.md#shared-analysis-foundation), reports
every scored executable region and file in stable path order, and succeeds by
default. Limits are opt-in.

```sh
lwpt health
lwpt health --json
lwpt health --hotspots
lwpt health --hotspots --json
```

`--hotspots` asks LWPT to enrich the complexity report with local Git history.
It never contacts a remote. Outside a Git worktree, or when local Git history
cannot be read, the command succeeds in explicit `complexity-only` mode. A
configured hotspot limit implies hotspot enrichment; if Git is unavailable in
that case, LWPT fails because it cannot evaluate the requested gate.

## Scope and configuration

`[analysis].include` and `[analysis].exclude` select Pascal sources. Package
unit roots and exact build-entry sources seed the selection. Workspace packages
inherit the root `[analysis]` table unless they declare their own table.

`[health]` owns command-specific limits:

```toml
[health]
max-routine-cyclomatic = 15
max-routine-cognitive = 20
max-file-cyclomatic = 80
max-file-cognitive = 100
max-hotspot-score = 75
```

All values are optional non-negative integers. `max-hotspot-score` is bounded
to `0..100`; unknown keys are rejected so a misspelled gate cannot silently
become report-only. A workspace inherits the root health limits unless it declares its
own `[health]` table, in which case that table replaces the inherited limits.
A limit is violated only when the observed value is strictly greater than the
configured maximum. Equality passes. LWPT reports every violation and exits
nonzero when at least one is present. With no configured limits, health is a
report-only command.

The routine maxima apply to every independently scored executable region,
including synthetic program, initialization, and finalization regions. File
values are the sums of those independent regions; nested routines are scored
separately and are not folded into their parent's body.

## Pascal scoring table

Cyclomatic complexity starts at `1` for each routine body and each synthetic
program, initialization, or finalization section. It increments for:

- each `if`, `for`, `while`, or `repeat` decision;
- each non-default `case` arm;
- each `on ... do` exception handler (or one for a bare `except` handler); and
- each `and`, `or`, or `xor` decision boundary inside an `if`, `while`, or
  `until` condition.

The selector of a `case`, the range of a `for`, and an exception type clause
are not Boolean conditions. `try/finally` alone adds no decision.

Cognitive complexity starts at `0`. An `if`, loop, `case`, or exception
handler adds `1 + current control nesting`. `else` adds `1`. A Boolean condition
adds `1` for its first Boolean operator and another `1` whenever the operator
kind changes, so `A and B and C` adds one while `A and B or C` adds two. Each
`goto` adds `1`, and a syntactic direct recursive call adds `1` once per
routine. Nested routines reset both metrics and their nesting.

This is a documented structural adaptation of McCabe and Sonar-style scoring,
not a compiler control-flow graph. The shared Pascal tokenizer removes comments
and whitespace, normalizes Pascal letter case, and supplies typed routine and
unit-section boundaries before scoring.

## Git hotspots

Git enrichment sums added and deleted text lines for each analyzed file across
the latest 100 commits that touched its rename-followed history. Binary
`numstat` entries do not contribute changed lines. The report always exposes:

- raw file cyclomatic complexity;
- raw file cognitive complexity;
- raw changed-line count; and
- the combined hotspot score.

For every file, `raw complexity = cyclomatic + cognitive`. Complexity and
changed lines are each normalized by the largest corresponding value in the
current analysis scope. The score is:

```text
100 * normalized complexity * normalized changed lines
```

The result is in `0..100` and is informational unless
`max-hotspot-score` is configured. When no analyzed file has changed-line
history, every score is zero.

## JSON contract

`--json` uses the shared `lwpt.analysis` envelope. Envelope schema version `1`
contains fixed-order execution metadata, analyzed files, effective
configuration, threshold outcome, and diagnostics. The health command owns its
independently versioned payload schema (`command.schemaVersion = 1`). Its
payload contains:

- `mode`: `complexity-only` or `git-enriched`;
- `git.historyCommits`: the fixed history window;
- `files`: stable file records with project, path, file metrics, raw churn,
  hotspot score, and stable region records with source locations; and
- `violations`: every observed/maximum pair that breached a configured limit.

Serialization uses fixed field order, LF line endings, locale-independent
decimal points, and stable root-relative paths. Clone groups remain owned by
the separate duplication payload rather than being forced into this schema.
