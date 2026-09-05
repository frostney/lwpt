# Verified registry mirror activation

[Issue #55](https://github.com/frostney/lwpt/issues/55) extends the existing
`registry` command family from [ADR-0043](0043-self-hosted-registry-origin.md).
`registry init --role mirror` requires an explicit origin identity, upstream
transport URL, root key ID, and root public key. `registry sync` is the only
mirror network operation. `registry verify` checks retained proof and archives
and reports freshness; `registry serve` uses the persisted role. The listener
does not contact the upstream while serving a request.

## Identity and storage

The existing origin configuration schema and bytes stay unchanged. A mirror
uses `lwpt-registry-mirror-config-v1` in the same `registry.toml` location,
adding `upstream`, `trust_key_id`, and `trust_public_key` to the operational
configuration. Reconfiguration cannot change an initialized role, origin
identity, or root pin. An upstream URL may move without changing identity.
Mirror initialization does not generate a private seed, and publication and
checkpoint renewal are disabled for the mirror role.

`LWPT.Registry.Verification` owns the signed read contract. Discovery and
capabilities use its bounded canonical parser; checkpoint inspection returns
explicitly untrusted retrieval hints. Successful proof verification binds
origin, root trust, snapshot history, records, and the same raw archive SHA-256
used by the content-addressed cache. A second attestation format is unnecessary.

Synchronization retains hash-verified metadata and archives at the existing
content-addressed paths. Cached objects are reverified before reuse. Exact
checkpoint and signature bytes use content-addressed renewal paths, so a
same-sequence renewal cannot overwrite an earlier accepted proof. One atomic
`state/current.toml` replacement activates the complete result. Its mirror
state schema includes the accepted signing key, checkpoint hash, and last
successful sync time. Files verified during an interrupted attempt remain
available to its retry; a failed attempt does not replace the active pointer.

The mirror serves only the current checkpoint/signature pair and snapshots in
that checkpoint's verified ancestry. Cached candidates are not published by
their hash paths. Optional historical checkpoint URLs are not supported;
previously accepted snapshot ancestors remain readable. The upstream key
document is fetched under the 1 MiB control-document limit, checked against the
immutable pin and checkpoint sequence, and retained byte-for-byte.

`state/sync-attempt.toml` records the most recent verification attempt or
failure separately. An attempt marked `verified` is not activation proof;
the current pointer and its successful sync time remain authoritative.
Writes use the existing atomic helpers. These provide process-interruption
recovery and atomic visibility, not a power-loss guarantee: ordinary resource
writes do not currently flush files and directory entries with `fsync` or its
platform equivalent.

## Transfer and freshness bounds

The current transfer path fetches one archive at a time through HTTPClient's
whole-body API. Archives are limited to 256 MiB; the response is also capped
at the signed archive size before body allocation. HTTP framing and conversion
can temporarily retain multiple copies, so 256 MiB is a payload cap, not a
total process-memory cap. Discovery and checkpoint control documents are
limited to 1 MiB, with the shared verifier's metadata limits applying to the
complete proof. Each request has a 120-second deadline. Redirects are not
followed, encoded response bodies are rejected, and discovery endpoints must
remain under the configured upstream base URL.

Synchronization checks current expiry before fetching content and again
immediately before activation. Local verification and serving retain exact
accepted proof without renewing or changing its timestamps. `verify` reports
`fresh`, `expired`, or `uninitialized`; an expired retained proof does not
authorize acquisition. The current transfer resumes at verified-object
boundaries, not at partial byte offsets. Rotation production and parallel
transfer remain outside this initial runnable implementation; unknown signing
keys fail closed through the shared verifier.

## Rejected alternatives

- Request-time proxy reads would retain the origin outage dependency and mix
  synchronization with client response deadlines.
- Re-signing or renewing a mirrored checkpoint would replace origin provenance
  with mirror authority and hide staleness.
- Independently replacing the latest checkpoint and signature would expose
  mixed publications. The accepted pointer selects their exact pair.
