# Machine-wide worker capacity uses reclaimable filesystem leases

LWPT coordinates compiler and test-process capacity through a per-user
filesystem coordinator rather than a daemon, named semaphore, or project-local
counter. Each invocation registers a request containing its session identity,
diagnostic PID, requested and granted capacity, FIFO wait ticket, per-lease
token hashes, pending delegation verifiers, start time, and heartbeat. Each
session also holds an OS-managed owner guard for its full lifetime (`fcntl` on
Unix and `LockFileEx` on Windows); short state transactions use a separate
lock. The default budget is the host's logical processor count and
`LWPT_WORKER_BUDGET` can override it; while requests are active, later
invocations adopt the already-active budget. Every acquisition receives a new
monotonic wait ticket, so an older session that releases and reacquires queues
behind requests already waiting. Owner death releases its guard and allows
immediate reclamation without trusting a PID. Heartbeat age is diagnostic
only. Unreadable, malformed, or unknown-schema requests fail closed while
their owner guard remains held and are removed only after that guard is absent.

A lease may be delegated explicitly to a nested LWPT subprocess through
`LWPT_WORKER_LEASE_TOKEN`. The token is 256 bits from the operating system's
cryptographic random source, is passed only through one child environment, and
must match a pending verifier in coordinator state. Consumption is atomic and
transfers one grant from the parent request to a new child-owned, owner-guarded
request and makes the parent lease locally unavailable. The parent reacquires
capacity through the normal FIFO after the child finishes. The raw token is
never written to disk or diagnostics, and the child removes the consumed token
from its process environment before running work so unrelated descendants do
not inherit it. A token cannot be reused and one lease cannot have two pending
child delegations. This avoids nested LWPT deadlock
when the machine budget is one while ensuring a child remains counted if its
parent exits.

## Considered Options

- **One advisory lock file per worker slot.** Process death would release the
  slot automatically, but coherent diagnostics, changing budget sizes, and
  invocation-level fairness would become distributed across unrelated files.
  Rejected because the interface would expose more coordination detail to every
  scheduler.
- **A named semaphore or shared counter.** Compact, but the cross-platform
  primitives do not provide the required portable owner diagnostics and
  reclaim semantics. A counter also leaks on crashes unless it recreates the
  lease protocol beside itself.
- **A permanently running coordinator daemon.** Centralises scheduling but
  violates LWPT's single-binary, no-background-service operating model.

## Consequences

- `LWPT.WorkerBudget` is the single seam future build and test schedulers use.
  This decision does not itself parallelise either command.
- State is shared between worktrees because it lives in the user's application
  configuration directory, not in a project's `.lwpt/` directory.
- `LWPT_WORKER_STATE_DIR` can relocate the state root for controlled
  environments and tests. `LWPT_WORKER_LEASE_STALE_SECONDS` adjusts the stale
  heartbeat threshold; the default is 30 seconds and values below three
  seconds are rejected. Crossing the threshold marks diagnostics as stale; it
  does not authorize reclamation because a live process could resume work.
- `lwpt repair` removes requests only after demonstrable owner death and reports
  the remaining owners, grants, lease ages, heartbeat ages, and state location.
  Owner guards make PID reuse irrelevant to reclamation. A malformed live
  request conservatively reserves the full active budget until its guard is
  released.
- Explicit lease release is retry-safe. Coordinator state is durably updated
  before the in-process lease list and counters change; retrying after a
  transaction or write failure completes the same release idempotently.
- A session supports concurrent scheduler threads. Acquisitions are serialized
  only while joining the FIFO queue, releases may proceed concurrently through
  the coordinator transaction, and every session-local lease/list/counter
  mutation is protected. The session must outlive and be destroyed after its
  scheduler threads have joined.
- The coordinator remains cooperative. Processes that do not acquire a lease
  are outside its authority; this is a worker budget for LWPT invocations, not
  an operating-system resource limit.
