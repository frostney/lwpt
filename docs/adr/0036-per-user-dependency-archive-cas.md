# Per-user immutable dependency archive CAS preserves project-owned state

Repeated worktrees currently download identical immutable dependency archives
into separate committed `.lwpt/archives/` directories. LWPT now admits each
verified archive into a per-user content-addressed store and may copy it back
into another project's private install plan when that project's existing
machine-written lockfile supplies the expected SHA-256 identity. This completes
[issue #48](https://github.com/frostney/lwpt/issues/48) without changing the
lockfile schema, the committed archive naming scheme, or zero-install builds.

`LWPT.ObjectStore` owns the generic immutable-object seam. A caller selects a
namespace root; objects are addressed only by raw bytes as
`sha256/<first-byte>/<remaining-hex>`. Dependency archives use the
`dependency-archives` namespace. Every lookup hashes the object before use,
corrupt objects move atomically to a quarantine name and become misses, and
admission copies and hashes bytes below the store's own filesystem before one
atomic publication. Concurrent same-key writers may duplicate the copy but can
publish only complete bytes that prove the same digest. Materialization copies
the object through the project's `.lwpt/tmp/`, re-hashes that copy, and then
uses the existing atomic project publication path. Writable hardlinks are never
used.

The cache is default-on and disposable. `LWPT_CACHE_DIR` selects an explicit
root; otherwise LWPT uses `%LOCALAPPDATA%\lwpt\cache` on Windows,
`~/Library/Caches/lwpt` on macOS, and `$XDG_CACHE_HOME/lwpt` (falling back to
`~/.cache/lwpt`) on other Unix systems. Store paths never enter `lwpt.lock` or
other committed project state. An unavailable cache emits a warning and the
install continues through its project-owned archive path, because cache
availability is not a correctness requirement.

A normal install uses a cached object only when a prior lock entry proves the
same canonical source, selected ref/commit, and archive digest. When Git ref
discovery is unavailable, a prior authoritative lock identity may select the
recorded ref only when it still satisfies every accumulated manifest
constraint; its verified cached archive then permits offline materialization.
`install --frozen` is deliberately unchanged: it remains read-only and verifies
the already committed archive plus tree without materializing either from the
project archive or the per-user store.

## Considered Options

- **Replace committed project archives with shared objects.** Rejected because
  fresh clones would lose zero-install verification and cache availability
  would become correctness-critical.
- **Key objects by URL, repository, or ref.** Rejected because provenance can
  change while bytes remain identical, and a mutable ref does not identify
  content. Those fields remain lockfile evidence, not object identity.
- **Use hardlinks into projects.** Rejected because a writable project archive
  could corrupt the supposedly immutable shared object.
- **Add producer leases here.** Rejected because issue #48 requires safe
  publication, not miss coalescing. The separate cache coordination work owns
  leases; redundant verified writers are safe in the meantime.
- **Let frozen install repair missing state from the cache.** Rejected because
  ADR-0018 defines frozen mode as verification-only. Cache-assisted recovery is
  a normal materializing install.

## Consequences

- Identical dependency bytes across projects occupy one shared immutable
  object while each project retains its own committed archive and module tree.
- Cache hits spend one SHA-256 pass before materialization and a second pass on
  the project-staged copy. Trust never derives from a filename alone.
- Interrupted store writes remain below the unaddressed `tmp/` namespace and
  cannot become hits; quarantined corruption remains available for later
  repair/budget policy.
- Build-result fingerprints, result manifests, eviction, producer leases,
  repair integration, and the unified `--no-cache` command contract remain
  separate work under issues #49 through #51; this ADR creates no rival build
  store.
