# Four stack contracts deferred from v1 (link, duplication, codebase-health, architectural-drift)

The `project-structure` and `native-nostalgia-stack` skills mandate four contracts beyond build-system and formatter: a **codebase-health** check (cyclomatic + cognitive complexity, hotspots from git churn), a **duplication** check (cross-file and within-file copy-paste detection), a **link** check (verifies every link in committed markdown), and an **architectural-drift** check (surfaces mismatches between docs and code across six surfaces). None are implemented in LWPT today. We **defer all four from the v1 production sprint**, each to its own workstream: **link-check** graduates from GocciaScript as a standalone LWPT-managed Pascal package (parallel to the HTTPClient/CLI graduation in ADR-0003), **duplication** and **codebase-health** become LWPT subcommands (`lwpt duplication`, `lwpt health`) in a separate workstream that integrates an existing prototype, and **architectural-drift** defers to v2. The reason is straightforward: each is a real piece of work (collectively comparable in code size to LWPT itself today), v1 is already a substantial 8-12 week sprint covering rename + tests + hardening + CI, and adding four more weeks of tooling-contract work delays v1 without proportionate value. Defer-with-explicit-tracking is honest; pretending the contracts exist is worse than acknowledging the gap.

## Considered Options

- **Implement all four fully in v1** (CH-A Pascal-native analyzer + D-A PMD CPD wrapper + L-A lychee + AD-A full drift). 8-12 weeks added to the v1 sprint. Rejected because it squeezes out the self-test backlog and the hardening pass.
- **Minimal v1 implementations** (CH-C crude per-file metrics + D-A wrapper + L-A lychee + AD-B two-surface drift check). Earned a recommendation from the grill but was overruled by owner direction — the duplication and codebase-health pieces already have prototypes that deserve proper integration rather than thin substitutes, and the link check belongs in the GocciaScript graduation lane.
- **Defer all four with no tracking.** Same outcome as silent debt. Rejected: each deferral lives explicitly here (and in `docs/architecture.md`) so the workstream that owns the eventual implementation has a clear handoff.

## Consequences

- The v1 pre-commit hook is **format + build + test only**. The longer-term steady-state hook (covering all six contracts) is bigger; new contributors should not be surprised by the gap.
- The `docs/vendored.md` (now `docs/packages.md` per ADR-0017) graduation table grows by one entry (link-check from GocciaScript).
- LWPT's subcommand surface will grow by two (`lwpt health`, `lwpt duplication`) when those workstreams land. The "subcommand surface is frozen" rule in `AGENTS.md` is the gate — each of these two has an existing prototype and a designated workstream, so they're pre-approved; further additions require their own ADR.
- Architectural-drift gets no in-tree solution before v2. Until then, drift between `docs/` and code is caught by human review — a real cost the project accepts.
