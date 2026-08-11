# ADR-0035: runtime test-registration inventory

## Context

LWPT's test programs register suites and cases at runtime, including under
conditional compilation. `docs/testing.md` previously duplicated those counts
by hand. Source-text counting cannot distinguish active platform branches,
while reconstructing totals from CI logs made documentation drift expensive to
detect and easy to misdiagnose.

The inventory must cover discovered unit, integration, and E2E programs without
running network-touching bodies. It must also distinguish the native Darwin,
Linux, win64, and win32 registrations exercised by CI.

## Decision

`TestingPascalLibrary` exposes a versioned, tab-delimited registration record.
LWPT binds an inventory request to the exact top-level executable path so nested
test subprocesses cannot contribute records to their parent. In inventory-only
mode the framework emits its registered suite/case totals and exits before test
bodies; in verification mode it emits the same record and then runs normally.

`lwpt test --inventory [selector...]` discovers and compiles the selected test
programs, suppresses lifecycle hooks, requests inventory-only execution, and
prints one deterministic JSON value. E2E programs are enumerated regardless of
the ordinary tier because their bodies never run.

A project opts into continuous verification by committing
`tests/test-inventory.tsv`. Rules select by exact `os/architecture`, OS wildcard,
`unix/*`, or universal `*`, with the most specific match winning and ambiguity
failing closed. Ordinary successful test executions are checked against the
selected rule; full discovery also rejects removed programs still present in
the inventory. LWPT's own file declares every native CI platform.

The registered-count cells and aggregate table in `docs/testing.md` are rendered
from that same file by `scripts/update-test-inventory.pas`. The PR gate runs its
`--check` form, while the existing native test jobs verify runtime records. No
extra test-body or network pass is introduced.

## Alternatives

- **Count `Test(...)` calls in source.** Rejected: aliases, helper registration,
  and conditional compilation make syntax an unreliable proxy for executable
  registration.
- **Parse ordinary human test logs.** Rejected: formatting is not a stable
  machine protocol and nested subprocess output can be mistaken for the parent.
- **Run a second full inventory workflow.** Rejected: it duplicates compilation
  on every platform. Inventory records instead ride the existing normal test
  executions; `--inventory` remains the explicit regeneration/inspection path.
- **Store one unconditional count per program.** Rejected: current HTTP,
  scheduling, build-entry, and Linux socket suites have real platform-dependent
  registration.

## Consequences

- Registration drift fails with the program, platform, expected count, and
  observed count.
- Inventory-only enumeration is offline even when E2E programs are selected.
- The testing package's public protocol is versioned with the package and must
  remain backward-compatible or receive an explicit schema/version transition.
- Projects without `tests/test-inventory.tsv` retain their existing test
  behavior and pay no verification requirement.
