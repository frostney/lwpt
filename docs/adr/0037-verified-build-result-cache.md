# Cache verified build results by neutral fingerprint

## Status

Accepted.

## Context

ADR-0020 made compiler staging invocation-private and publication atomic, but
equivalent builds still invoked the compiler. Reuse must not weaken session
isolation or assume that compiler versions, drivers, targets, flags, dependency
trees, or relevant environment values are interchangeable.

## Decision

Normal `lwpt build` invocations capture a schema-versioned, compiler-neutral
cache fingerprint before compilation. It includes the serialized neutral build
request; source, resource, workspace, lockfile, module, cfg, manifest, and hook
content; declared prerequisite outputs; the selected compiler driver,
executable, live version, target tuple,
and effective translated arguments; and compiler-relevant environment. Private
session paths and the previous public artifact bytes are excluded.

The fingerprint addresses an immutable result manifest in the per-user cache
root introduced by ADR-0036. The manifest identifies the output kind, artifact
SHA-256 digest, and Unix mode. The artifact and manifest are stored as immutable
objects; the fingerprint reference is published atomically. Concurrent
processes may race to publish the same fingerprint, but readers observe only a
complete manifest whose artifact digest matches the materialized bytes.

A hit is verified and materialized into the current private build session. It
then follows the ordinary postbuild, live compiler refresh, publication
fingerprint revalidation, and atomic public-output replacement path. A newly
compiled artifact is admitted only after those gates succeed. Failed,
cancelled, stale, and hook-failed candidates never enter the reusable store.
Corrupt or unavailable cache state becomes a deterministic miss and does not
prevent compilation.

`lwpt build --no-cache` performs neither lookup nor storage. `--clean` also
forces compilation, while retaining its existing stronger compiler rebuild
semantics. `LWPT_CACHE_DIR` relocates the shared cache root and therefore both
its dependency-archive and build-result namespaces.

## Consequences

- An unchanged request can publish a verified artifact without invoking the
  compiler.
- Compiler driver/version, target, flag, environment, dependency, source, or
  resource changes cannot collide under one fingerprint.
- Cache state remains disposable and never enters project manifests,
  lockfiles, or committed `.lwpt/` state.
- Cache hits still pay SHA-256 verification and the normal publication gates.
- There is no network sharing, eviction policy, or test-execution cache in this
  decision.
