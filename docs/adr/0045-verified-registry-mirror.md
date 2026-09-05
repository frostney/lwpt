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
checkpoint renewal and key rotation are disabled for the mirror role.

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
The same rule applies to rotated key documents and dual-signed rotation
triplets. Their HTTP routes expose only the accepted chain, not staged files.

Each metadata request owns one captured state and membership view. Mirrors
verify their complete retained proof once and reuse that result for routing.
Origins validate snapshot ancestry lazily, only for snapshot requests, using
the same bounded traversal and package-consistency checks as the shared
verifier. Pending origin snapshots remain hidden. The view never reloads the
current pointer, survives no later request, and does not replace the existing
serving-time resource hash checks.

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
total process-memory cap. Discovery, checkpoint, key, rotation, signature, and
rotation-page control documents are limited to 1 MiB. The shared verifier
limits a complete proof to 64 MiB, 10,000 documents, and 1,000 rotations;
content-addressed metadata also has a 4 MiB per-document limit. Acquisition
charges discovery, capabilities, key records, and pagination bytes against
that same budget before retention. These untrusted retrieval documents confer
no authority and are unnecessary for offline verification. Each request has a
120-second deadline. Redirects are not
followed, encoded response bodies are rejected, and discovery endpoints must
remain under the configured upstream base URL.

Synchronization checks current expiry before fetching content and again
immediately before activation. Local verification and serving retain exact
accepted proof without renewing or changing its timestamps. `verify` reports
`fresh`, `expired`, or `uninitialized`; an expired retained proof does not
authorize acquisition. The current transfer resumes at verified-object
boundaries, not at partial byte offsets. Parallel transfer remains outside
this implementation packet. Unknown signing keys require a complete verified
rotation chain from the immutable root pin.

## Local signing-key rotation

`registry rotate-key --data-dir <directory> --from-key <expected-key-id>` is an
operator-local origin command. It acquires the publication lease and compares
the expected key with the captured active checkpoint before writing. A retry
after activation fails that precondition instead of rotating again.

The origin generates a private seed at `keys/ed25519-<hash>.seed` using the
existing private-file helper. Publication and renewal select this seed from
the captured checkpoint. Legacy `keys/root.seed` is usable only when its
derived public key matches that checkpoint exactly. Old seeds and public
metadata remain retained; this operation does not import keys, revoke them,
or define retired-key deletion policy.

Rotation advances the sequence by one, writes the existing dual-signed
transition and public key record, and creates an unchanged-record snapshot
whose predecessor is the old snapshot. The new key signs the new checkpoint.
Only the existing atomic current-pointer replacement activates those files.
Recovery removes owned future rotation triplets and numeric checkpoints;
orphan candidate keys are retained but are not served. Numeric committed
checkpoint history remains readable; content-addressed renewal aliases are
served only when selected by the current pointer. The origin rejects rotation
at the shared verifier's 1,000-transition ceiling before creating a new key.

Origins and mirrors advertise `rotation-chain-v1`. Rotation pages contain at
most 100 ordered items and stay below 1 MiB. Their cursor binds the origin,
`after` sequence, and last item; it is a pagination selector, not authentication.
Mirrors follow bounded pages, verify both signatures for every transition,
and retain exact key and transition bytes for offline replay. Invalid pages,
missing signatures, or a chain that does not reach the checkpoint key leave
the accepted pointer unchanged. This uses the existing protocol schemas and
canonical Ed25519 implementation without a second provenance attestation.

## Rejected alternatives

- Request-time proxy reads would retain the origin outage dependency and mix
  synchronization with client response deadlines.
- Re-signing or renewing a mirrored checkpoint would replace origin provenance
  with mirror authority and hide staleness.
- Independently replacing the latest checkpoint and signature would expose
  mixed publications. The accepted pointer selects their exact pair.
