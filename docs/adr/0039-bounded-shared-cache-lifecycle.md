# Bound the shared cache with one repair-driven lifecycle

## Status

Accepted.

## Context

The per-user dependency archive and build-result stores are disposable but
previously unbounded. Their atomic publication and producer guards prevented
partial hits and duplicated known-key production, but did not provide a disk
budget, protect an object throughout materialization, or recover corrupt and
abandoned aggregate state. A project-local cache setting would also let one
checkout govern eviction of objects shared by unrelated projects.

## Decision

LWPT applies one aggregate per-user object budget across the dependency archive
and build-result namespaces. The default is 10 GiB. Only
`LWPT_CACHE_MAX_BYTES`, expressed as a non-negative byte count, overrides it;
there is no `lwpt.toml` setting. A zero budget disables new admissions and lets
repair remove every unleased object. `LWPT_CACHE_DIR` continues to relocate all
shared cache state. `lwpt build --no-cache` remains the invocation-level bypass,
and `--clean` continues to imply compilation rather than cache lookup.

Every verified admission or hit advances a cache-root monotonic sequence. The
aggregate index orders objects by that sequence and then by stable namespace
and digest, producing deterministic least-recently-used eviction. Admission
first evicts enough unleased objects to fit. An oversized object, or one that
cannot fit because the remaining candidates are live, is not admitted; the
project archive or completed build remains authoritative.

Admission and materialization hold a non-inherited per-object OS guard for the
complete shared-object interval. A short cache-root mutation guard serializes
index updates, publication decisions, repair, and eviction across processes.
Eviction never waits for an object guard: it preserves that live object and
continues with the next deterministic candidate. Existing producer-key guards
still own download/compile coalescing; the object guard covers the later
verified publication and consumption boundary.

Each admitted object has an atomic control manifest recording its namespace,
digest, path, and byte size. `lwpt repair` is the only user-facing maintenance
path. It removes incomplete staging and quarantined bytes, verifies object
content, reconstructs corrupt or missing LRU entries from verified manifests,
reclaims producer metadata only after acquiring its released OS guard, and
enforces the effective budget. It reports the budget and remaining bytes,
bytes reclaimed, corruption and incomplete state removed, abandoned leases,
and live objects/leases preserved. Repeating repair is safe. Project-owned
committed `.lwpt/archives/`, `.lwpt/modules/`, lockfiles, and configuration are
outside this lifecycle.

## Consequences

- Shared object bytes have predictable aggregate disk use without making cache
  availability part of build or install correctness.
- Projects may bypass build caching but cannot raise, partition, or otherwise
  govern global eviction policy.
- Accesses perform one small atomic index update, while object copies and
  producers remain concurrent across keys.
- A crash can leave an unindexed object or incomplete control file, but repair
  verifies the content-addressed bytes before reconstructing metadata.
- No cache prune/clear subcommand, explicit offline-install mode, remote cache
  administration, or test-executable cache is introduced.
