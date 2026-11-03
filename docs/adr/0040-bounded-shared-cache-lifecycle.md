# Bound the shared cache with one repair-driven lifecycle

> **Amended 2026-11-03 ([#405](https://github.com/frostney/lwpt/issues/405)), amortized budget enforcement:** Admission no longer walks the whole cache tree, and eviction no longer evicts only "enough unleased objects to fit". A guarded usage ledger (`lifecycle/usage`, padded to a fixed 256 bytes that the budget counts) records the total from the last walk plus every change a guarded writer made since. An admission trusts the ledger only while the index it was written against is current: the same sequence, byte size and last-write time at the filesystem's resolution. A writer that does not keep the ledger, such as an older LWPT sharing the cache (even one that deletes and recreates the index) or a crash between the index and ledger writes, therefore invalidates it. Ledger and control-file accounting never follows a link, and counts nothing below a linked directory, matching the walk. A missing or untrusted ledger, one without room for the admission, or one that has grown by more than one band since the last walk triggers authoritative enforcement. That enforcement measures the complete tree. When the cache is over budget, it evicts in the same deterministic LRU order down to a low-water mark one band below the budget. A band is a tenth of the budget. The walk, and the build-reference edges eviction needs, then run once per band of admissions instead of on every admission. Each eviction batch collects the reference edges in one walk; references change only under the mutation guard the batch holds. Bytes that no guarded writer reports, such as crash residue, are measured within one band of tracked growth. Repair drops the ledger, enforces the budget on the measured tree, and writes a fresh ledger. A budget smaller than the ledger itself, or a cache held over budget by live objects, keeps no ledger, so every admission measures.

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

LWPT applies one aggregate per-user byte budget across the complete shared
cache tree used by the dependency archive and build-result namespaces. Regular
file bytes for immutable objects, result references, lifecycle control state,
producer metadata, staging, and quarantine all count. The default is 10 GiB.
Only `LWPT_CACHE_MAX_BYTES`, expressed as a non-negative byte count, overrides it;
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

A build-result reference is one logical edge through two immutable objects:
the reference directly names a result manifest, and that manifest names its
artifact. Eviction and explicit removal resolve this edge while holding the
mutation guard. They invalidate every direct or transitive reference before
unlinking either object. A reader that acquired the reference earlier either
finishes while its artifact object guard prevents eviction, or observes the
invalidation as a miss; a reader arriving after invalidation cannot enter the
manifest-to-artifact window. Object-store materialization preserves whether a
miss came from an absent object, failed verification, a failed copy, or a
staged hash mismatch. Build-cache diagnostics prefix that exact stage with
`result-manifest-` or `artifact-` instead of collapsing all failures into an
artifact-missing report.

Each admitted object has an atomic control manifest recording its namespace,
digest, path, and byte size. `lwpt repair` is the only user-facing maintenance
path. It removes incomplete staging and quarantined bytes, verifies object
content, reconstructs corrupt or missing LRU entries from verified manifests,
reclaims producer metadata only after acquiring its released OS guard and
atomically detaching the guarded key directory before recursive removal, and
enforces the effective budget. Detachment moves a concurrently substituted
link itself, so repair never follows that link outside the cache. On Windows,
where an open child prevents the directory rename, the released guard and the
directory rename arbitrate the race: a new producer either blocks detachment
or starts against a newly created key after the old one has moved. It reports
the budget and remaining bytes,
bytes reclaimed, corruption and incomplete state removed, abandoned leases,
and live objects/leases preserved. Repeating repair is safe. Project-owned
committed `.lwpt/archives/`, `.lwpt/modules/`, lockfiles, and configuration are
outside this lifecycle. A repair may remain above budget only when counted
state is protected by a live operating-system guard; the report identifies
that preservation so a later repair can reclaim it after release.

Repair also validates build references transitively. The reference path must
be a canonical fingerprint, its contents must canonically name a present and
parseable result manifest, that manifest must bind the same fingerprint, and
its artifact digest must name an object that repair verified, or preserved
because its live object guard made verification nonblocking. Malformed,
unreadable, or incomplete logical results lose their disposable reference
conservatively; unreferenced immutable objects remain ordinary budget
candidates.

## Consequences

- Shared cache bytes have predictable aggregate disk use without making cache
  availability part of build or install correctness.
- Projects may bypass build caching but cannot raise, partition, or otherwise
  govern global eviction policy.
- Accesses perform one small atomic index update, while object copies and
  producers remain concurrent across keys.
- A crash can leave an unindexed object or incomplete control file, but repair
  verifies the content-addressed bytes before reconstructing metadata.
- Evicting an artifact may leave an unreferenced manifest object until later
  budget enforcement, but it cannot leave a fingerprint that resolves only
  part of a build result.
- No cache prune/clear subcommand, explicit offline-install mode, remote cache
  administration, or test-executable cache is introduced.
