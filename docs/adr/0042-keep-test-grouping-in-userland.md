# Keep test grouping in userland

## Status

Accepted.

## Context

LWPT already discovers `*.Test.pas` programs and accepts exact file,
directory, and glob selectors. The runner also classified paths as unit,
integration, or E2E, hid programs behind `--tier`, and exposed that taxonomy
in inventory output. This coupled one repository's layout and network policy
to a generic test capability. Its additive E2E route also reran every ordinary
program in LWPT's own CI.

## Decision

`lwpt test` owns discovery, strict selection, compilation, execution,
inventory, scheduling, bail, and compilation caching. With no selector it runs
the complete discovered inventory; with selectors it runs exactly the matching
programs. It does not infer test groups from paths and has no `--tier` option.

Projects own their groups, CI routes, and network authorization through paths,
selectors, environment, and declared run tasks. LWPT's repository keeps its
unit, integration, and E2E names as userland policy. Its workflows invoke the
ordinary and E2E paths separately, and its live-network programs run only when
the repository sets `LWPT_ENABLE_NETWORK=1`.

Inventory schema v2 removes the semantic tier field from both JSON and the
committed TSV. It retains deterministic program paths, platform rules, suite
counts, and case counts.

## Consequences

- A selected program is never silently skipped because of its directory.
- A bare `lwpt test` is complete discovery, so projects that need offline
  defaults make network access opt-in in their own test programs.
- CI composes groups with the same public selectors available to users and
  does not repeat ordinary programs merely to add E2E coverage.
- LWPT does not replace tiers with named groups or another policy framework.
