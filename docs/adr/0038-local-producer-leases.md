# Local producer leases coalesce verified cache misses

## Status

Accepted.

## Context

The dependency archive CAS and build-result cache publish immutable verified
objects atomically, so concurrent writers cannot expose partial bytes. They did
not prevent several LWPT processes on one machine from downloading or compiling
the same missing object. A crashed producer also needed a recovery contract
that did not mistake a delayed heartbeat for proof that a healthy long compile
was dead.

## Decision

`LWPT.ProducerLease` coordinates one producer per cache object key below the
per-user cache root. Build misses use the already captured neutral build
fingerprint. Dependency misses use the authoritative archive SHA-256 from a
prior matching lock entry; a first download whose content identity is not yet
known remains uncoordinated rather than inventing a mutable URL/ref identity.
Different keys use different guard files and never take a store-wide lock.

The producer holds a non-inherited operating-system file lock for its complete
production and verified publication path. Unix uses a `fcntl` write lock and
Windows uses `LockFileEx`; both are released by the operating system if the
process exits. Heartbeat metadata records the object description, owner PID,
start time, and latest progress time for bounded waiter diagnostics. The OS
guard is the liveness authority: stale metadata cannot displace a still-live
long-running owner, while a crashed owner's released guard is immediately
reclaimable. This matches the owner-guard safety model of the machine worker
budget without coupling object production to capacity scheduling.

Waiters poll only the named key, report the object and elapsed wait at bounded
intervals, and repeatedly attempt verified materialization. After taking over
an abandoned guard they recheck the desired fingerprint or hash before doing
work, because the prior producer may have published immediately before
releasing. Abandoning or cancelling a waiter owns no producer state and cannot
cancel or corrupt the producer. Failed, cancelled, stale, and hook-failed build
candidates still do not enter the cache; releasing their lease lets a waiter
take over normally.

## Consequences

- Concurrent identical normal misses run one local producer and consumers use
  the same verified immutable result.
- A crash cannot make partial content addressable and cannot permanently strand
  a key; the next contender takes the released OS guard.
- Healthy work is not stolen because a heartbeat thread was delayed.
- Cache availability remains optional. Lease failures retain the existing
  dependency-fetch or local-compilation fallback and never add network, daemon,
  authentication, or external-runtime requirements.
- First-time dependency downloads without an authoritative content hash can
  still duplicate work. Coalescing them by mutable provenance would weaken the
  content-addressed identity established by ADR-0036.
